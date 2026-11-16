//! Ark funding keeps the original quote, an expiring review, and the shared
//! submission journal. A known funding result is not BTC settlement proof.
use super::*;
use std::time::Instant;
use bitcoin::Amount;
use super::super::submissions;

#[derive(Clone)]
pub(super) struct Review {
	id: String,
	root: PathBuf,
	hash: String,
	invoice: String,
	expires_at: u64,
	created_at: u64,
	created: Instant,
	total_sat: u64,
}
impl Review {
	fn valid(&self, root: &Path, record: &Record, input: &Approval) -> anyhow::Result<()> {
		ensure!(self.root == root && self.id == input.request_id && self.hash == input.hash && self.total_sat == input.maximum_total_sat
			&& self.invoice == record.quote.hold_invoice && self.hash == record.quote.hash && self.expires_at == record.quote.expires_at,
			"Ark funding review changed. Review this conversion again");
		self.before_submit(self.hash.parse()?)
	}
	fn before_submit(&self, hash: ark::lightning::PaymentHash) -> anyhow::Result<()> {
		ensure!(hash.to_string() == self.hash, "Ark funding hash differs from the conversion");
		ensure!(self.created.elapsed() < Duration::from_secs(60) && now() >= self.created_at && self.expires_at > now().saturating_add(5),
			"Ark funding review expired. Nothing was submitted");
		Ok(())
	}
}
#[derive(Serialize, Deserialize)]
pub(super) struct Funding {
	pub submission_id: String,
	pub maximum_total_sat: u64,
	pub state: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Prepare { hash: String }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Approval { hash: String, request_id: String, maximum_total_sat: u64 }

fn cost(hold: &Invoice, estimate: &bark::FeeEstimate) -> anyhow::Result<(u64,u64)> {
	let amount = Amount::from_sat(hold.msat.div_ceil(1000));
	ensure!(estimate.net_amount == amount && amount.checked_add(estimate.fee) == Some(estimate.gross_amount)
		&& estimate.gross_amount <= Amount::MAX_MONEY, "Ark funding estimate differs from the conversion");
	Ok((estimate.gross_amount.to_sat(),estimate.fee.to_sat()))
}
pub(super) async fn prepare(State(state): State<Arc<ServerState>>, Json(input): Json<Prepare>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let mut session = state.bridge.try_lock().map_err(|_|anyhow::anyhow!("A Bridge request is already running"))?;
		session.ark_review = None;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let _lock = bark::lock_manager::platform_default(Some(&root),None)?;
		let record = load(&root,&path(&root,Direction::PayBtc,&input.hash)?)?;
		let hold = funding::fundable(&record,now())?;
		ensure!(client()?.availability(Direction::PayBtc).await?.open, "The Bridge is paused. Nothing was submitted");
		let wallet = state.require_wallet().map_err(|_|anyhow::anyhow!("Unlock your wallet first"))?;
		let hash = hold.hash.parse()?;
		ensure!(matches!(wallet.lightning_send_state(hash).await?,bark::actions::lightning::pay::LightningSendState::Unknown),
			"This invoice already has an Ark payment. Check its saved status");
		let estimate = tokio::time::timeout(Duration::from_secs(90),wallet.estimate_lightning_send_fee(Amount::from_sat(hold.msat.div_ceil(1000))))
			.await.context("Ark cost review timed out. Nothing was submitted")??;
		let (total_sat,fee_sat) = cost(&hold,&estimate)?;
		funding::fundable(&record,now())?;
		let review = Review {id:sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()).to_string(),root,
			hash:hold.hash,invoice:hold.text,expires_at:record.quote.expires_at,created_at:now(),created:Instant::now(),total_sat};
		let result = json!({"quote":public(&record)?,"review":{"request_id":review.id,"payment_hash":review.hash,
			"funding_amount_sat":record.quote.pay_sat,"fees_and_reserves_sat":fee_sat,"maximum_total_sat":total_sat}});
		session.ark_review = Some(review); Ok(result)
	}.await)
}
pub(super) async fn fund(State(state): State<Arc<ServerState>>, Json(input): Json<Approval>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let mut session = state.bridge.try_lock().map_err(|_|anyhow::anyhow!("A Bridge request is already running. Check its status shortly"))?;
		let review = session.ark_review.take().context("Review this Ark payment again. Nothing was submitted")?;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let _lock = bark::lock_manager::platform_default(Some(&root),None)?;
		let mut record = load(&root,&path(&root,Direction::PayBtc,&input.hash)?)?;
		funding::fundable(&record,now())?; review.valid(&root,&record,&input)?;
		ensure!(client()?.availability(Direction::PayBtc).await?.open, "The Bridge is paused. Nothing was submitted");
		let wallet = state.require_wallet().map_err(|_|anyhow::anyhow!("Unlock your wallet first"))?;
		ensure!(matches!(wallet.lightning_send_state(input.hash.parse()?).await?,bark::actions::lightning::pay::LightningSendState::Unknown),
			"This invoice already has an Ark payment. Check its saved status");
		review.valid(&root,&record,&input)?;
		record.funding = None;
		record.ark_funding = Some(Funding {submission_id:review.id.clone(),maximum_total_sat:review.total_sat,state:"unknown".into()});
		save(&root,&record)?;
		let guard = review.clone();
		// The engine calls this guard after asynchronous input/fee preflight,
		// before its first persisted checkpoint. The exact total is also enforced
		// by the engine. No other code path automatically retries this submission.
		submissions::bridge::pay(state.clone(),&review.id,&review.invoice,review.total_sat,move |hash|guard.before_submit(hash)).await?;
		let status = check(&state,&record).await?;
		record.ark_funding.as_mut().context("Ark funding record unavailable")?.state = status;
		save(&root,&record)?; public(&record)
	}.await)
}
pub(super) async fn check(state: &ServerState, record: &Record) -> anyhow::Result<String> {
	let funding = record.ark_funding.as_ref().context("No saved Ark funding request")?;
	submissions::bridge::status(state,&funding.submission_id,&record.quote.hold_invoice,funding.maximum_total_sat).await
}

#[cfg(test)]
mod tests {
	use super::*;
	fn review(record: &Record, root: &Path) -> Review {
		Review {id:"01".repeat(32),root:root.into(),hash:record.quote.hash.clone(),invoice:record.quote.hold_invoice.clone(),
			expires_at:now()+600,created_at:now(),created:Instant::now(),total_sat:1201}
	}
	#[test]
	fn ark_review_binds_wallet_invoice_hash_total_and_deadline() {
		let root = tempfile::tempdir().unwrap(); let mut record = super::super::tests::fixture(Direction::PayBtc);
		let review = review(&record,root.path()); record.quote.expires_at = review.expires_at;
		let mut input = Approval {hash:review.hash.clone(),request_id:review.id.clone(),maximum_total_sat:review.total_sat};
		assert!(review.valid(root.path(),&record,&input).is_ok());
		input.maximum_total_sat += 1; assert!(review.valid(root.path(),&record,&input).is_err()); input.maximum_total_sat -= 1;
		assert!(review.valid(Path::new("another-wallet"),&record,&input).is_err());
		input.request_id = "02".repeat(32); assert!(review.valid(root.path(),&record,&input).is_err()); input.request_id = review.id.clone();
		record.quote.hold_invoice.push('x'); assert!(review.valid(root.path(),&record,&input).is_err()); record.quote.hold_invoice.pop();
		record.quote.expires_at += 1; assert!(review.valid(root.path(),&record,&input).is_err());
		assert!(review.before_submit("02".repeat(32).parse().unwrap()).is_err());
	}
	#[tokio::test]
	async fn asynchronous_preflight_cannot_use_an_expired_ark_approval() {
		let record = super::super::tests::fixture(Direction::PayBtc);
		let mut review = review(&record,Path::new("wallet")); let hash = record.quote.hash.parse().unwrap();
		assert!(review.before_submit(hash).is_ok());
		tokio::task::yield_now().await;
		review.created = Instant::now()-Duration::from_secs(61);
		assert!(review.before_submit(hash).is_err());
		review.created = Instant::now(); review.expires_at = now()+5;
		assert!(review.before_submit(hash).is_err());
		review.expires_at = now()+600; review.created_at = now()+60;
		assert!(review.before_submit(hash).is_err());
	}
	#[test]
	fn cost_uses_whole_satoshi_ark_funding_and_includes_recovery_reserves() {
		let record = super::super::tests::fixture(Direction::PayBtc);
		let hold = Invoice::parse(&record.quote.hold_invoice).unwrap(); assert_eq!(hold.msat,200001);
		let mut estimate = bark::FeeEstimate::new(Amount::from_sat(1201),Amount::from_sat(1000),Amount::from_sat(201),vec![]);
		assert_eq!(cost(&hold,&estimate).unwrap(),(1201,1000));
		estimate.net_amount = Amount::from_sat(200); assert!(cost(&hold,&estimate).is_err());
		estimate.net_amount = Amount::from_sat(201); estimate.gross_amount = Amount::from_sat(1200); assert!(cost(&hold,&estimate).is_err());
		estimate.gross_amount = Amount::from_sat(u64::MAX); estimate.fee = Amount::from_sat(u64::MAX); assert!(cost(&hold,&estimate).is_err());
	}
	#[test]
	fn ark_intent_blocks_other_funding_and_survives_without_claiming_settlement() {
		let root = tempfile::tempdir().unwrap(); let mut record = super::super::tests::fixture(Direction::PayBtc);
		for state in ["unknown","pending","succeeded","recovery"] {
			record.ark_funding = Some(Funding {submission_id:"01".repeat(32),maximum_total_sat:1201,state:state.into()});
			assert!(funding::fundable(&record,1_000_001).is_err());
			save(root.path(),&record).unwrap(); let restored = records(root.path()).unwrap().remove(0);
			let value = public(&restored).unwrap(); assert_eq!(value["funding"]["source"],"ark"); assert_eq!(value["verified_settlement"],false);
			assert!(value["funding"].get("submission_id").is_none());
		}
		record.ark_funding.as_mut().unwrap().state = "not_submitted".into(); assert!(funding::fundable(&record,1_000_001).is_ok());
		record.funding = Some(funding::Funding {node_id:"node".into(),maximum_fee_sat:10,state:"unknown".into()});
		save(root.path(),&record).unwrap(); assert!(records(root.path()).is_err());
	}
}
