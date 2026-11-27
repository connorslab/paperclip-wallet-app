//! Synthetic, unfunded invoices. These checks never contact a bridge or node.
use super::*;
use bark::lightning_invoice::{Currency, InvoiceBuilder, PaymentSecret, RawTaggedField, TaggedField};
use bitcoin::secp256k1::{Secp256k1, SecretKey};
use protocol::{Availability, Challenge, SwapStatus};
use axum::{body::Body,http::Request};
use tokio_util::sync::CancellationToken;
use tower::ServiceExt;

fn invoice(xbt: bool, amount: u64, hash: &[u8], currency: Currency, expiry: u64) -> String {
	let mut raw = InvoiceBuilder::new(currency).description("bridge test fixture".into())
		.payment_hash(sha256::Hash::hash(hash)).payment_secret(PaymentSecret([4;32]))
		.duration_since_epoch(Duration::from_secs(1_000_000)).expiry_time(Duration::from_secs(expiry))
		.amount_milli_satoshis(amount).min_final_cltv_expiry_delta(80).build_raw().unwrap();
	if xbt {
		for tag in &mut raw.data.tagged_fields {
			if let RawTaggedField::KnownSemantics(TaggedField::Features(features)) = tag { features.set_blake2b_identity_required(); }
		}
	}
	raw.sign::<_,()>(|message|Ok(Secp256k1::new().sign_ecdsa_recoverable(message,&SecretKey::from_slice(&[2;32]).unwrap()))).unwrap().to_string()
}
pub(super) fn fixture(direction: Direction) -> Record {
	let target = invoice(direction == Direction::ReceiveXbt,100_000,&[3;32],Currency::Bitcoin,3600);
	let hold = invoice(direction != Direction::ReceiveXbt,200_001,&[3;32],Currency::Bitcoin,1800);
	let quote = Quote { hold_invoice:hold,hash:sha256::Hash::hash(&[3;32]).to_string(),sat:100.0,pay_sat:201,rate:2.0,spread:0.01,expires_at:1_001_800,token:"ab".repeat(16) };
	Record {direction,target,quote,created:1_000_001,state:"quoted".into(),verified_settlement:false,receive_node_id:None,verified_receipt:false,funding:None,ark_funding:None}
}
#[test]
fn quote_binds_both_networks_amounts_hash_and_expiry() {
	for direction in [Direction::PayBtc,Direction::ReceiveXbt] {
		let record = fixture(direction); let target = Invoice::parse(&record.target).unwrap();
		target.target(direction,1_000_001).unwrap(); record.quote.validate(&target,direction,Some(1_000_001)).unwrap();
		let other = if direction == Direction::PayBtc {Direction::ReceiveXbt} else {Direction::PayBtc};
		assert!(target.target(other,1_000_001).is_err());
		for field in ["hash","sat","pay_sat","rate","spread","token","expires_at"] {
			let mut value = serde_json::to_value(&record.quote).unwrap();
			value[field] = match field {
				"hash" => json!("00".repeat(32)),"sat" => json!(101.0),"pay_sat" => json!(200),"rate" => json!(0),
				"spread" => json!(-1),"token" => json!("../not-a-token"),_ => json!(1_001_801),
			};
			let quote: Quote = serde_json::from_value(value).unwrap();
			assert!(quote.validate(&target,direction,Some(1_000_001)).is_err(),"accepted altered {field}");
		}
		let mut quote = record.quote.clone();
		quote.hold_invoice = invoice(target.xbt,200_001,&[3;32],Currency::Bitcoin,1800);
		assert!(quote.validate(&target,direction,None).is_err());
		quote.hold_invoice = invoice(!target.xbt,200_001,&[9;32],Currency::Bitcoin,1800);
		assert!(quote.validate(&target,direction,None).is_err());
		assert!(record.quote.validate(&target,direction,Some(1_001_795)).is_err());
		// Old records remain inspectable after their funding deadline.
		assert!(record.quote.validate(&target,direction,None).is_ok());
	}
}
#[test]
fn mainnet_fixed_amount_and_lifetime_are_required() {
	assert!(Invoice::parse(&invoice(true,1000,&[3;32],Currency::Regtest,3600)).is_err());
	assert!(Invoice::parse(&invoice(true,0,&[3;32],Currency::Bitcoin,3600)).is_err());
	assert!(Invoice::parse(&invoice(true,9_007_199_254_740_992,&[3;32],Currency::Bitcoin,3600)).is_err());
	let target = Invoice::parse(&fixture(Direction::ReceiveXbt).target).unwrap();
	assert!(target.target(Direction::ReceiveXbt,1_003_600).is_err());
	let merchant = Invoice::parse(&invoice(false,1_649_000,&[4;32],Currency::Bitcoin,300)).unwrap();
	assert!(merchant.target(Direction::PayBtc,1_000_003).is_ok());
	assert!(merchant.target(Direction::PayBtc,1_000_300).is_err());
	assert!(Invoice::parse(&format!("{} ",target.text)).is_err());
	let mut invalid = target.text.into_bytes(); invalid[10] = if invalid[10] == b'q' { b'p' } else { b'q' };
	assert!(Invoice::parse(&String::from_utf8(invalid).unwrap()).is_err());
}
#[test]
fn only_a_settled_matching_proof_establishes_settlement() {
	let hash = sha256::Hash::hash(&[3;32]).to_string();
	for state in ["quoted","funded","paid","paying","failed","lost","invented"] {
		assert!(!SwapStatus {state:state.into(),preimage:Some("03".repeat(32))}.verified_settlement(&hash));
	}
	for preimage in [None,Some("04".repeat(32)),Some("not-hex".into()),Some("03".repeat(31))] {
		assert!(!SwapStatus {state:"settled".into(),preimage}.verified_settlement(&hash));
	}
	assert!(SwapStatus {state:"settled".into(),preimage:Some("03".repeat(32))}.verified_settlement(&hash));
	assert_eq!(SwapStatus {state:"remote arbitrary text".into(),preimage:None}.public_state(),"unknown");
}
#[test]
fn availability_is_strict_and_cannot_coerce_missing_or_string_open() {
	for value in [json!({}),json!({"open":"true"}),json!({"open":1})] { assert!(serde_json::from_value::<Availability>(value).is_err()); }
	let info: Availability = serde_json::from_value(json!({"open":false})).unwrap(); assert!(!info.open); info.validate().unwrap();
	assert!(Availability {open:true,min_sat:Some(-1.0),max_sat:None}.validate().is_err());
	assert!(Availability {open:true,min_sat:Some(2.0),max_sat:Some(1.0)}.validate().is_err());
}
#[test]
fn quotes_survive_restart_with_private_tokens_and_no_payment_claim() {
	let dir = tempfile::tempdir().unwrap(); private_dir(dir.path()).unwrap();
	let record = fixture(Direction::PayBtc); save(dir.path(),&record).unwrap();
	let loaded = records(dir.path()).unwrap(); assert_eq!(loaded.len(),1);
	let public = public(&loaded[0]).unwrap();
	assert!(public.get("token").is_none() && public.get("preimage").is_none());
	assert_eq!(public["verified_settlement"],false); assert_eq!(public["funding_msat"],"200001");
	assert_eq!(public["target_msat"],"100000");
	let file = path(dir.path(),record.direction,&record.quote.hash).unwrap();
	#[cfg(unix)] assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,0o600);
	assert!(path(dir.path(),record.direction,"../not-a-hash").is_err());
	let mut corrupt = serde_json::to_value(&record).unwrap(); corrupt["quote"]["hash"] = json!("00".repeat(32));
	std::fs::write(&file,serde_json::to_vec(&corrupt).unwrap()).unwrap(); assert!(records(dir.path()).is_err());
}
#[cfg(unix)]
#[test]
fn symlinked_quotes_cannot_read_or_overwrite_other_files() {
	let dir = tempfile::tempdir().unwrap(); let elsewhere = tempfile::tempdir().unwrap();
	let record = fixture(Direction::PayBtc); let file = path(dir.path(),record.direction,&record.quote.hash).unwrap();
	let target = elsewhere.path().join("private.json"); std::fs::write(&target,b"unchanged").unwrap();
	std::os::unix::fs::symlink(&target,&file).unwrap();
	assert!(save(dir.path(),&record).is_err()); assert!(records(dir.path()).is_err());
	assert_eq!(std::fs::read(target).unwrap(),b"unchanged");
}
#[tokio::test]
async fn challenge_is_bounded_and_uses_service_nonce_format() {
	let hash = "01".repeat(32);
	assert!(Challenge {challenge:"test".into(),bits:23}.solve(&hash).await.is_err());
	assert!(Challenge {challenge:"x".repeat(201),bits:0}.solve(&hash).await.is_err());
	let challenge = Challenge {challenge:"fixture".into(),bits:8};
	let nonce = challenge.solve(&hash).await.unwrap();
	assert!(nonce.bytes().all(|b|b.is_ascii_digit() || b.is_ascii_lowercase()));
	assert_eq!(sha256::Hash::hash(format!("fixture:{hash}:{nonce}").as_bytes()).as_byte_array()[0],0);
}

#[tokio::test]
async fn routes_require_authentication_and_an_unlocked_wallet() {
	let token = crate::auth::AuthToken::new([42;32]);
	let state = Arc::new(ServerState::builder().auth_token(token.clone()).build(CancellationToken::new()));
	let router = crate::api::v1::router(&state).with_state(state);
	for (path,method,body) in [
		("/bridge/reusable","GET",""),("/bridge/reusable/info","GET",""),
		("/bridge/reusable","POST",r#"{"action":"lookup","id":"fixture"}"#),
		("/bridge/info?direction=toSHA256","GET",""),("/bridge/quotes","GET",""),
		("/bridge/quotes","POST",r#"{"direction":"toSHA256","invoice":"fixture"}"#),
		("/bridge/prepare-ark-funding","POST",r#"{"hash":"fixture"}"#),
		("/bridge/fund-ark","POST",r#"{"hash":"fixture","request_id":"fixture","maximum_total_sat":1000}"#),
		("/bridge/prepare-funding","POST",r#"{"hash":"fixture","maximum_fee_sat":10}"#),
		("/bridge/fund","POST",r#"{"hash":"fixture","maximum_fee_sat":10,"request_id":"fixture"}"#),
		("/bridge/check","POST",r#"{"direction":"toSHA256","hash":"fixture"}"#),
	] {
		let request = Request::builder().method(method).uri(path).header("content-type","application/json").body(Body::from(body)).unwrap();
		assert_eq!(router.clone().oneshot(request).await.unwrap().status(),StatusCode::UNAUTHORIZED);
		let request = Request::builder().method(method).uri(path).header("content-type","application/json").header("authorization",format!("Bearer {}",token.encode())).body(Body::from(body)).unwrap();
		let response = router.clone().oneshot(request).await.unwrap();
		assert_eq!(response.status(),StatusCode::CONFLICT); assert_eq!(response.headers()[header::CACHE_CONTROL],"no-store");
	}
}

#[tokio::test]
async fn repeated_quote_returns_original_without_contacting_service() {
	let dir = tempfile::tempdir().unwrap(); let record = fixture(Direction::PayBtc); save(dir.path(),&record).unwrap();
	// Even an expired quote remains the same saved payment after a restart.
	let input = QuoteRequest {direction:record.direction,invoice:record.target.clone()};
	let result = retain_quote(dir.path(),input,|_,_|async { panic!("must not request a replacement quote") }).await.unwrap();
	assert_eq!(result["hash"],record.quote.hash); assert_eq!(result["hold_invoice"],record.quote.hold_invoice);
	let input = QuoteRequest {direction:record.direction,invoice:invoice(false,101_000,&[3;32],Currency::Bitcoin,3600)};
	assert!(retain_quote(dir.path(),input,|_,_|async { panic!("must reject reused payment hash") }).await.is_err());
	assert_eq!(records(dir.path()).unwrap().len(),1);
}

fn receipt(record: &Record) -> BridgeReceipt {
	BridgeReceipt {node_id:bitcoin::secp256k1::PublicKey::from_secret_key(&Secp256k1::new(),&SecretKey::from_slice(&[2;32]).unwrap()).to_string(),
		payment_hash:record.quote.hash.clone(),invoice:record.target.clone(),amount_msat:100_000,received:true}
}
#[test]
fn incoming_success_requires_exact_node_receipt_even_with_bridge_proof() {
	let mut record = fixture(Direction::ReceiveXbt);
	let proof = || Ok(SwapStatus {state:"settled".into(),preimage:Some("03".repeat(32))});
	let result = reconcile(&mut record,proof(),Some(Err(anyhow::anyhow!("node unavailable")))).unwrap();
	assert_eq!(result["bridge_settled"],true); assert_eq!(result["verified_settlement"],false);
	assert_eq!(result["node_checked"],false);
	for field in ["node","hash","invoice","amount"] {
		let mut row = receipt(&record); record.receive_node_id = Some(row.node_id.clone());
		match field {
			"node" => row.node_id = bitcoin::secp256k1::PublicKey::from_secret_key(&Secp256k1::new(),&SecretKey::from_slice(&[9;32]).unwrap()).to_string(),
			"hash" => row.payment_hash = "00".repeat(32), "invoice" => row.invoice = fixture(Direction::PayBtc).target,
			_ => row.amount_msat += 1,
		}
		let result = reconcile(&mut record,proof(),Some(Ok(row))).unwrap();
		assert_eq!(result["verified_settlement"],false,"accepted changed {field}"); assert_eq!(result["node_checked"],false);
	}
	let mut row = receipt(&record); row.received = false;
	let result = reconcile(&mut record,proof(),Some(Ok(row))).unwrap();
	assert_eq!(result["node_checked"],true); assert_eq!(result["verified_settlement"],false);
}
#[test]
fn receiving_node_settlement_survives_bridge_outage_and_restart() {
	let dir = tempfile::tempdir().unwrap(); let mut record = fixture(Direction::ReceiveXbt);
	let row = receipt(&record);
	let result = reconcile(&mut record,Err(anyhow::anyhow!("bridge unavailable")),Some(Ok(row))).unwrap();
	assert_eq!(result["verified_settlement"],true); assert_eq!(result["bridge_checked"],false);
	assert_eq!(result["bridge_settled"],false); assert_eq!(result["node_checked"],true);
	save(dir.path(),&record).unwrap();
	let restored = records(dir.path()).unwrap().remove(0);
	assert!(settled(&restored)); assert_eq!(public(&restored).unwrap()["verified_settlement"],true);
}
#[test]
fn legacy_incoming_proof_is_not_mistaken_for_node_receipt() {
	let mut legacy = serde_json::to_value(fixture(Direction::ReceiveXbt)).unwrap();
	legacy.as_object_mut().unwrap().remove("receive_node_id"); legacy.as_object_mut().unwrap().remove("verified_receipt");
	legacy["verified_settlement"] = json!(true);
	let record: Record = serde_json::from_value(legacy).unwrap(); assert!(!settled(&record));
	assert_eq!(public(&record).unwrap()["verified_settlement"],false);
	let mut outgoing = fixture(Direction::PayBtc);
	let result = reconcile(&mut outgoing,Ok(SwapStatus {state:"settled".into(),preimage:Some("03".repeat(32))}),None).unwrap();
	assert_eq!(result["verified_settlement"],true);
}
