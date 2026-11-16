//! Synthetic TLS node fixtures only. No network node credentials or payments.
use super::*;
use std::{io::{Read, Write}, net::TcpListener, sync::{Mutex, atomic::{AtomicBool, Ordering}}, thread};
use bitcoin::secp256k1::{PublicKey, Secp256k1, SecretKey};
use bark::lightning_invoice::{InvoiceBuilder, Currency, PaymentSecret, TaggedField, RawTaggedField};
use transport::Implementation;
use axum::{body::Body, http::Request as HttpRequest};
use tower::ServiceExt;
use tokio_util::sync::CancellationToken;

// Scoped to one current-thread test, so parallel tests keep the real clock.
thread_local! {
	pub(super) static CLOCK: std::cell::RefCell<Option<Arc<std::sync::atomic::AtomicU64>>> = const { std::cell::RefCell::new(None) };
}

const CERT: &[u8] = include_bytes!("fixtures/node-cert.der");
// This generated fixture key has no purpose outside the local TLS test server.
const TEST_KEY: &[u8] = include_bytes!("fixtures/node-test-key.der");

struct Fixture {
	endpoint: String,
	requests: Arc<Mutex<Vec<String>>>,
	stop: Arc<AtomicBool>,
	thread: Option<thread::JoinHandle<()>>,
}
impl Fixture {
	fn new(reply: impl Fn(&str) -> Option<String> + Send + 'static) -> Self {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap(); listener.set_nonblocking(true).unwrap();
		let endpoint = format!("https://{}", listener.local_addr().unwrap());
		let stop = Arc::new(AtomicBool::new(false)); let child_stop = stop.clone();
		let requests = Arc::new(Mutex::new(Vec::new())); let child_requests = requests.clone();
		let config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
			.with_safe_default_protocol_versions().unwrap().with_no_client_auth()
			.with_single_cert(vec![rustls::pki_types::CertificateDer::from(CERT.to_vec())], rustls::pki_types::PrivatePkcs8KeyDer::from(TEST_KEY.to_vec()).into()).unwrap();
		let config = Arc::new(config);
		let thread = thread::spawn(move || {
			while !child_stop.load(Ordering::SeqCst) {
				let Ok((socket, _)) = listener.accept() else { thread::sleep(Duration::from_millis(5)); continue; };
				socket.set_nonblocking(false).unwrap();
				socket.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
				let session = rustls::ServerConnection::new(config.clone()).unwrap();
				let mut stream = rustls::StreamOwned::new(session, socket);
				let mut bytes = Vec::new(); let mut expected = None;
				loop {
					let mut buffer = [0;4096]; let Ok(count) = stream.read(&mut buffer) else { break; };
					if count == 0 { break; } bytes.extend_from_slice(&buffer[..count]);
					if expected.is_none() {
						if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
							let text = String::from_utf8_lossy(&bytes[..end]);
							let length = text.lines().find_map(|line|line.to_ascii_lowercase().strip_prefix("content-length:").and_then(|v|v.trim().parse::<usize>().ok())).unwrap_or(0);
							expected = Some(end + 4 + length);
						}
					}
					if expected.is_some_and(|length| bytes.len() >= length) { break; }
				}
				if bytes.is_empty() { continue; } // Rejected TLS must not send credentials.
				let text = String::from_utf8(bytes).unwrap(); child_requests.lock().unwrap().push(text.clone());
				if let Some(response) = reply(&text) { let _ = stream.write_all(response.as_bytes()); let _ = stream.flush(); }
			}
		});
		Self {endpoint, requests, stop, thread:Some(thread)}
	}
	fn connection(&self, implementation: Implementation) -> Connection {
		Connection { implementation,endpoint:self.endpoint.clone(),credential:"abab".into(),certificate_sha256:sha256::Hash::hash(CERT).to_string(),use_tor:false,receive_only:false,node_id:node_id() }
	}
}
impl Drop for Fixture {
	fn drop(&mut self) { self.stop.store(true,Ordering::SeqCst); self.thread.take().unwrap().join().unwrap(); }
}
fn json_response(value: Value) -> Option<String> {
	let body = value.to_string(); Some(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()))
}
fn node_id() -> String {
	PublicKey::from_secret_key(&Secp256k1::new(),&SecretKey::from_slice(&[2;32]).unwrap()).to_string()
}
fn test_invoice(xbt: bool) -> String {
	let mut raw = InvoiceBuilder::new(Currency::Regtest).description("synthetic fixture".into())
		.payment_hash(sha256::Hash::hash(&[3;32])).payment_secret(PaymentSecret([4;32]))
		.duration_since_epoch(model::now()).expiry_time(Duration::from_secs(3600)).amount_milli_satoshis(100000)
		.min_final_cltv_expiry_delta(80).build_raw().unwrap();
	if xbt {
		for tag in &mut raw.data.tagged_fields {
			if let RawTaggedField::KnownSemantics(TaggedField::Features(features)) = tag { features.set_blake2b_identity_required(); }
		}
	}
	raw.sign::<_,()>(|message|Ok(Secp256k1::new().sign_ecdsa_recoverable(message,&SecretKey::from_slice(&[2;32]).unwrap()))).unwrap().to_string()
}
fn input(value: Value) -> Request { serde_json::from_value(value).unwrap() }

#[tokio::test]
async fn tls_pin_rejection_sends_no_credential_and_redirect_never_follows() {
	let fixture = Fixture::new(|_|Some("HTTP/1.1 302 Found\r\nLocation: https://example.com\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into()));
	let mut connection = fixture.connection(Implementation::Lnd); connection.certificate_sha256 = "00".repeat(32);
	assert!(Node::new(connection,None).unwrap().info().await.is_err());
	assert!(fixture.requests.lock().unwrap().is_empty());
	let mut connection = fixture.connection(Implementation::Lnd); connection.certificate_sha256.clear();
	assert!(Node::new(connection,None).unwrap().info().await.is_err()); // Self-signed is not system trusted.
	assert!(fixture.requests.lock().unwrap().is_empty());
	let result = Node::new(fixture.connection(Implementation::Lnd),None).unwrap().info().await;
	assert!(result.unwrap_err().to_string().contains("redirected"));
	assert_eq!(fixture.requests.lock().unwrap().len(),1);
}

#[tokio::test]
async fn cln_and_lnd_auth_headers_and_stream_framing() {
	let fixture = Fixture::new(|request| {
		if request.starts_with("POST /v2/router/send ") {
			let body = "{\"result\":{\"status\":\"IN_FLIGHT\"}}\n{\"result\":{\"status\":\"SUCCEEDED\"}}\n";
			Some(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()))
		} else { json_response(json!({"id":node_id()})) }
	});
	let cln = Node::new(fixture.connection(Implementation::Cln),None).unwrap(); cln.info().await.unwrap();
	let lnd = Node::new(fixture.connection(Implementation::Lnd),None).unwrap(); lnd.info().await.unwrap();
	let result = lnd.request("v2/router/send",Some(json!({"cancelable":false})),true).await.unwrap();
	assert_eq!(result["status"],"IN_FLIGHT");
	let requests = fixture.requests.lock().unwrap();
	assert!(requests[0].starts_with("POST /v1/getinfo ")); assert!(requests[0].contains("rune: abab"));
	assert!(requests[1].starts_with("GET /v1/getinfo ")); assert!(requests[1].contains("grpc-metadata-macaroon: abab"));
	assert_eq!(requests.len(),3);
}

#[tokio::test]
async fn interrupted_send_is_durable_and_cannot_replay_after_restart() {
	for kind in [Implementation::Cln,Implementation::Lnd] {
		let root = tempfile::tempdir().unwrap(); private_dir(&root.path().join("payments")).unwrap();
		let text = test_invoice(true); let parsed = invoice(&text,Network::Regtest).unwrap();
		let path = record_path(root.path(),&parsed.payment_hash().to_string(),false).unwrap();
		let at_send = path.clone();
		let fixture = Fixture::new(move |request| {
			if request.starts_with("POST /v1/pay ") || request.starts_with("POST /v2/router/send ") {
				let record: Record = load(&at_send).unwrap(); assert_eq!(record.state,"unknown");
				return None; // Connection lost after the node received the request.
			}
			json_response(if kind == Implementation::Cln {json!({"id":node_id(),"network":"regtest"})} else {json!({"identity_pubkey":node_id(),"chains":[{"chain":"bitcoin","network":"regtest"}]})})
		});
		save(&root.path().join("connection.json"),&fixture.connection(kind)).unwrap();
		let mut sessions = Sessions::default();
		let review = execute_at(root.path().into(),Network::Regtest,&mut sessions,input(json!({"operation":"prepare","destination":text,"maximum_fee_sat":10}))).await.unwrap();
		let approval = json!({"operation":"pay","request_id":review["request_id"],"payment_hash":review["payment_hash"],"maximum_fee_sat":10});
		let result = execute_at(root.path().into(),Network::Regtest,&mut sessions,input(approval.clone())).await.unwrap();
		assert_eq!(result["state"],"unknown"); assert!(path.exists());
		let mut restarted = Sessions::default();
		assert!(execute_at(root.path().into(),Network::Regtest,&mut restarted,input(approval)).await.is_err());
		assert!(execute_at(root.path().into(),Network::Regtest,&mut restarted,input(json!({"operation":"prepare","destination":text,"maximum_fee_sat":10}))).await.unwrap_err().to_string().contains("already has"));
		assert_eq!(fixture.requests.lock().unwrap().iter().filter(|r|r.starts_with("POST /v1/pay ")||r.starts_with("POST /v2/router/send ")).count(),1);
	}
}

#[test]
fn signed_invoice_requires_xbt_identity_and_matching_network() {
	assert!(invoice(&test_invoice(true),Network::Regtest).is_ok());
	assert!(invoice(&test_invoice(false),Network::Regtest).is_err());
	assert!(invoice(&test_invoice(true),Network::Bitcoin).is_err());
}

#[tokio::test]
async fn node_routes_require_authentication_and_a_loaded_wallet() {
	let token = crate::auth::AuthToken::new([42;32]);
	let state = Arc::new(ServerState::builder().auth_token(token.clone()).build(CancellationToken::new()));
	let router = crate::api::v1::router(&state).with_state(state);
	for (path,method,body) in [("/remote-node/connection","GET",""),("/remote-node/request","POST",r#"{"operation":"pay"}"#)] {
		let request = HttpRequest::builder().method(method).uri(path).header("content-type","application/json").body(Body::from(body)).unwrap();
		assert_eq!(router.clone().oneshot(request).await.unwrap().status(),StatusCode::UNAUTHORIZED);
		let request = HttpRequest::builder().method(method).uri(path).header("content-type","application/json").header("authorization",format!("Bearer {}",token.encode())).body(Body::from(body)).unwrap();
		let response = router.clone().oneshot(request).await.unwrap();
		assert_eq!(response.status(),StatusCode::BAD_REQUEST); assert_eq!(response.headers()[header::CACHE_CONTROL],"no-store");
	}
}

#[test]
fn review_cannot_change_hash_node_fee_expiry_or_receive_only_mode() {
	let fixture = Fixture::new(|_|None);
	let mut node = Node::new(fixture.connection(Implementation::Lnd),None).unwrap();
	let mut review = Review { id:"review".into(), invoice:"invoice".into(),hash:"01".repeat(32),node_id:node_id(),amount_msat:100000,fee_sat:10,created:Instant::now(),bridge:None };
	let approval = json!({"operation":"pay","request_id":"review","payment_hash":review.hash,"maximum_fee_sat":10});
	assert!(check_review(&review,&input(approval.clone()),&node).is_ok());
	for (field,value) in [("request_id",json!("other")),("payment_hash",json!("02".repeat(32))),("maximum_fee_sat",json!(11))] {
		let mut tampered = approval.clone(); tampered[field] = value;
		assert!(check_review(&review,&input(tampered),&node).is_err());
	}
	node.connection.receive_only = true; assert!(check_review(&review,&input(approval.clone()),&node).is_err());
	node.connection.receive_only = false; review.node_id = "other".into(); assert!(check_review(&review,&input(approval.clone()),&node).is_err());
	review.node_id = node_id(); review.created = Instant::now() - Duration::from_secs(61); assert!(check_review(&review,&input(approval),&node).is_err());
}

#[tokio::test]
async fn saved_credential_is_reused_only_for_the_same_endpoint_and_node() {
	let root = tempfile::tempdir().unwrap(); private_dir(&root.path().join("payments")).unwrap();
	let fixture = Fixture::new(|_| json_response(json!({"identity_pubkey":node_id(),"chains":[{"chain":"bitcoin","network":"regtest"}]})));
	let saved = fixture.connection(Implementation::Lnd);
	save(&root.path().join("connection.json"), &saved).unwrap();
	let mut connection = serde_json::to_value(&saved).unwrap(); connection["credential"] = json!("");
	let mut sessions = Sessions::default();
	let mut changed = connection.clone(); changed["endpoint"] = json!("https://another-node.invalid");
	assert!(execute_at(root.path().into(),Network::Regtest,&mut sessions,input(json!({"operation":"connect","connection":changed}))).await.is_err());
	let mut changed = connection.clone(); changed["implementation"] = json!("cln");
	assert!(execute_at(root.path().into(),Network::Regtest,&mut sessions,input(json!({"operation":"connect","connection":changed}))).await.is_err());
	assert!(fixture.requests.lock().unwrap().is_empty());
	connection["receive_only"] = json!(true);
	let result = execute_at(root.path().into(),Network::Regtest,&mut sessions,input(json!({"operation":"connect","connection":connection}))).await.unwrap();
	assert_eq!(result["receive_only"],true); assert!(result.get("credential").is_none());
	let retained: Connection = load(&root.path().join("connection.json")).unwrap();
	assert_eq!(retained.credential,saved.credential); assert_eq!(retained.node_id,saved.node_id);
	let mut wrong_identity = retained; wrong_identity.node_id = "02".repeat(33);
	save(&root.path().join("connection.json"),&wrong_identity).unwrap();
	assert!(execute_at(root.path().into(),Network::Regtest,&mut sessions,input(json!({"operation":"connect","connection":connection}))).await.unwrap_err().to_string().contains("another node"));
}

#[tokio::test]
async fn bridge_funding_uses_the_node_journal_and_never_replays_uncertain_results() {
	for kind in [Implementation::Cln,Implementation::Lnd] {
		let root = tempfile::tempdir().unwrap(); private_dir(&root.path().join("payments")).unwrap();
		let text = test_invoice(true); let hash = invoice(&text,Network::Regtest).unwrap().payment_hash().to_string();
		let journal = record_path(root.path(),&hash,false).unwrap();
		let binding = root.path().join("bridge-binding.json"); let at_send = journal.clone(); let at_binding = binding.clone();
		let fixture = Fixture::new(move |request| {
			if request.starts_with("POST /v1/pay ") || request.starts_with("POST /v2/router/send ") {
				assert!(at_binding.exists()); assert_eq!(load::<Record>(&at_send).unwrap().state,"unknown");
				return None;
			}
			if request.contains("/v1/listpays ") { return json_response(json!({"pays":[]})); }
			if request.contains("/v2/router/track/") { return json_response(json!({"result":{"status":"IN_FLIGHT","payment_hash":sha256::Hash::hash(&[3;32]).to_string()}})); }
			json_response(if kind == Implementation::Cln { json!({"id":node_id(),"network":"regtest"}) } else { json!({"identity_pubkey":node_id(),"chains":[{"chain":"bitcoin","network":"regtest"}]}) })
		});
		save(&root.path().join("connection.json"),&fixture.connection(kind)).unwrap();
		let mut sessions = Sessions::default(); let deadline = model::now().as_secs() + 300;
		let review = execute_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Prepare,&text,deadline,"",7,"")).await.unwrap();
		let id = review["request_id"].as_str().unwrap();
		// Failure to persist the Bridge binding must happen before any send.
		assert!(bridge::fund_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Pay,&text,deadline,&hash,7,id),|_|anyhow::bail!("disk unavailable")).await.is_err());
		assert!(!journal.exists());
		let result = bridge::fund_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Pay,&text,deadline,&hash,7,id),|id|save(&binding,&json!({"node_id":id}))).await.unwrap();
		assert_eq!(result["state"],"unknown");
		let mut restarted = Sessions::default();
		assert!(bridge::fund_at(root.path().into(),Network::Regtest,&mut restarted,bridge::request(Operation::Pay,&text,deadline,&hash,7,id),|_|panic!("must not retain another attempt")).await.is_err());
		assert!(execute_at(root.path().into(),Network::Regtest,&mut restarted,bridge::request(Operation::Prepare,&text,deadline,"",7,"")).await.is_err());
		assert!(bridge::status_at(root.path().into(),Network::Regtest,&mut restarted,&text,&hash,&node_id(),8).await.is_err());
		assert!(bridge::status_at(root.path().into(),Network::Regtest,&mut restarted,&text,&hash,"other-node",7).await.is_err());
		let status = bridge::status_at(root.path().into(),Network::Regtest,&mut restarted,&text,&hash,&node_id(),7).await.unwrap();
		assert!(matches!(status.as_deref(),Some("unknown" | "pending")));
		assert_eq!(fixture.requests.lock().unwrap().iter().filter(|r|r.starts_with("POST /v1/pay ")||r.starts_with("POST /v2/router/send ")).count(),1);
	}
}

#[tokio::test(flavor = "current_thread")]
async fn bridge_expiry_during_node_preflight_leaves_no_payment_intent() {
	let seconds = Arc::new(std::sync::atomic::AtomicU64::new(model::now().as_secs()));
	CLOCK.with(|clock| assert!(clock.borrow_mut().replace(seconds.clone()).is_none()));
	struct ResetClock;
	impl Drop for ResetClock { fn drop(&mut self) { CLOCK.with(|clock| *clock.borrow_mut() = None); } }
	let _reset_clock = ResetClock;
	let deadline = model::now().as_secs() + 300;
	let root = tempfile::tempdir().unwrap(); private_dir(&root.path().join("payments")).unwrap();
	let delay = Arc::new(AtomicBool::new(false)); let wait = delay.clone();
	let fixture = Fixture::new(move |_| {
		// Expire precisely while the real TLS preflight is in progress, after
		// the initial review check and before its final pre-submission check.
		if wait.load(Ordering::SeqCst) { seconds.store(deadline, Ordering::SeqCst); }
		json_response(json!({"identity_pubkey":node_id(),"chains":[{"chain":"bitcoin","network":"regtest"}]}))
	});
	save(&root.path().join("connection.json"),&fixture.connection(Implementation::Lnd)).unwrap();
	let text = test_invoice(true); let hash = invoice(&text,Network::Regtest).unwrap().payment_hash().to_string();
	let mut sessions = Sessions::default();
	let review = execute_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Prepare,&text,deadline,"",1,"")).await.unwrap();
	delay.store(true,Ordering::SeqCst);
	let error = bridge::fund_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Pay,&text,deadline,&hash,1,review["request_id"].as_str().unwrap()),|_|Ok(())).await.unwrap_err();
	assert!(error.to_string().contains("expired"));
	assert!(!record_path(root.path(),&hash,false).unwrap().exists());
	assert_eq!(bridge::status_at(root.path().into(),Network::Regtest,&mut sessions,&text,&hash,&node_id(),1).await.unwrap(),None);
	assert_eq!(fixture.requests.lock().unwrap().len(),2, "Both review and send preflights must run");
	assert!(fixture.requests.lock().unwrap().iter().all(|r|r.starts_with("GET /v1/getinfo ")));
}

#[tokio::test]
async fn bridge_approval_cannot_be_used_by_the_direct_payment_route() {
	let root = tempfile::tempdir().unwrap(); private_dir(&root.path().join("payments")).unwrap();
	let fixture = Fixture::new(|_|json_response(json!({"identity_pubkey":node_id(),"chains":[{"chain":"bitcoin","network":"regtest"}]})));
	save(&root.path().join("connection.json"),&fixture.connection(Implementation::Lnd)).unwrap();
	let text = test_invoice(true); let mut sessions = Sessions::default();
	let review = execute_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Prepare,&text,model::now().as_secs()+300,"",1,"")).await.unwrap();
	let request = input(json!({"operation":"pay","request_id":review["request_id"],"payment_hash":review["payment_hash"],"maximum_fee_sat":1}));
	assert!(execute_at(root.path().into(),Network::Regtest,&mut sessions,request).await.unwrap_err().to_string().contains("another flow"));
	assert!(records(root.path()).unwrap().is_empty());
	assert_eq!(fixture.requests.lock().unwrap().len(),1);
	assert!(serde_json::from_value::<Request>(json!({"operation":"pay","bridge":{"invoice":text,"expires_at":9999999999u64}})).is_err());
}

#[tokio::test]
async fn bridge_node_funding_enforces_the_reviewed_fee_and_retains_success() {
	for kind in [Implementation::Cln,Implementation::Lnd] {
		let root = tempfile::tempdir().unwrap(); private_dir(&root.path().join("payments")).unwrap();
		let text = test_invoice(true); let hash = invoice(&text,Network::Regtest).unwrap().payment_hash().to_string();
		let journal = record_path(root.path(),&hash,false).unwrap(); let at_send = journal.clone();
		let fixture = Fixture::new(move |request| {
			if request.starts_with("POST /v1/pay ") || request.starts_with("POST /v2/router/send ") {
				let body: Value = serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
				assert_eq!(load::<Record>(&at_send).unwrap().maximum_fee_sat,7);
				if kind == Implementation::Cln { assert_eq!(body["maxfee"],"7000msat"); }
				else { assert_eq!(body["fee_limit_sat"],"7"); assert_eq!(body["cancelable"],false); }
				let result = json!({"payment_hash":sha256::Hash::hash(&[3;32]).to_string(),"status":if kind == Implementation::Cln {"complete"} else {"SUCCEEDED"}});
				return json_response(if kind == Implementation::Cln {result} else {json!({"result":result})});
			}
			json_response(if kind == Implementation::Cln {json!({"id":node_id(),"network":"regtest"})} else {json!({"identity_pubkey":node_id(),"chains":[{"chain":"bitcoin","network":"regtest"}]})})
		});
		save(&root.path().join("connection.json"),&fixture.connection(kind)).unwrap();
		let mut sessions = Sessions::default(); let deadline = model::now().as_secs()+300;
		let review = execute_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Prepare,&text,deadline,"",7,"")).await.unwrap();
		let id = review["request_id"].as_str().unwrap();
		for (invoice,expiry,fee) in [(text.as_str(),deadline+1,7),(text.as_str(),deadline,8),("different-invoice",deadline,7)] {
			assert!(bridge::fund_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Pay,invoice,expiry,&hash,fee,id),|_|panic!("must reject changed terms before retaining intent")).await.is_err());
		}
		let result = bridge::fund_at(root.path().into(),Network::Regtest,&mut sessions,bridge::request(Operation::Pay,&text,deadline,&hash,7,id),|_|Ok(())).await.unwrap();
		assert_eq!(result["state"],"succeeded"); assert_eq!(load::<Record>(&journal).unwrap().state,"succeeded");
		assert_eq!(bridge::status_at(root.path().into(),Network::Regtest,&mut sessions,&text,&hash,&node_id(),7).await.unwrap().as_deref(),Some("succeeded"));
		let mut damaged: Record = load(&journal).unwrap(); damaged.amount_msat = "100001".into(); save(&journal,&damaged).unwrap();
		assert!(bridge::status_at(root.path().into(),Network::Regtest,&mut sessions,&text,&hash,&node_id(),7).await.is_err());
		assert_eq!(fixture.requests.lock().unwrap().iter().filter(|r|r.starts_with("POST /v1/pay ")||r.starts_with("POST /v2/router/send ")).count(),1);
	}
}
