//! Browser submission receipts belong to the wallet, not a tab. An interrupted
//! operation is never executed again merely because the HTTP response was lost.
use std::{future::Future, io::Write, path::{Path, PathBuf}, sync::Arc, time::Duration};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::{DefaultBodyLimit, State}, http::{HeaderMap, StatusCode, header}, routing::{get, post}};
use bitcoin::hashes::{Hash, sha256};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ServerState;
use super::{boards, exits, lightning, onchain, wallet};

const MAX_RECORD_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request { id: String, operation: String, body: Value }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Check { id: String }
#[derive(Clone, Serialize, Deserialize)]
struct Record {
	id: String,
	operation: String,
	digest: String,
	created: i64,
	/// `received` describes the HTTP result, never final payment settlement.
	state: String,
	result: Option<Value>,
	initiated: bool,
	#[serde(default)] acknowledged: bool,
	#[serde(default)] movement_id: Option<bark::movement::MovementId>,
	#[serde(default)] exit_ids: Option<Vec<ark::VtxoId>>,
	#[serde(default)] action_id: Option<String>,
	#[serde(default)] txid: Option<String>,
	#[serde(default)] payment_hash: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Empty {}
#[derive(Deserialize)]
#[serde(tag = "operation", content = "body")]
enum Action {
	#[serde(rename = "wallet/send")] Ark(bark_json::web::SendRequest),
	#[serde(rename = "lightning/pay")] Lightning(bark_json::web::LightningPayRequest),
	#[serde(rename = "onchain/send/commit")] Onchain(onchain::SendApproval),
	#[serde(rename = "onchain/replacement/commit")] Replacement(onchain::ReplacementApproval),
	#[serde(rename = "boards/commit")] Board(boards::BoardApproval),
	#[serde(rename = "wallet/offboard/all")] Offboard(bark_json::web::OffboardAllRequest),
	#[serde(rename = "wallet/refresh/all")] Refresh(Empty),
	#[serde(rename = "exits/start/all")] Exit(Empty),
	#[serde(rename = "exits/progress")] Progress(bark_json::web::ExitProgressRequest),
	#[serde(rename = "exits/claim/all")] Claim(bark_json::web::ExitClaimAllRequest),
}
impl Action {
	fn parse(request: &Request) -> anyhow::Result<Self> {
		serde_json::from_value(json!({"operation": request.operation, "body": request.body}))
			.map_err(|_| anyhow::anyhow!("Invalid submission request"))
	}
	fn references(&self) -> (Option<String>, Option<String>) {
		let txid = match self {
			Self::Onchain(v) => Some(v.request_id.to_string()), Self::Replacement(v) => Some(v.replacement_txid.to_string()),
			Self::Board(v) => Some(v.request_id.to_string()), _ => None,
		};
		let destination = match self { Self::Lightning(v) => Some(&v.destination), _ => None };
		let hash = destination.and_then(|v| v.parse::<ark::lightning::Invoice>().ok()).map(|v| v.payment_hash().to_string());
		(txid, hash)
	}
	async fn execute(self, state: Arc<ServerState>, receipt: Receipt) -> anyhow::Result<Value> {
		macro_rules! call { ($result:expr) => { serde_json::to_value($result.map_err(|_| anyhow::anyhow!("The operation did not return a confirmed result"))?.0).context("Could not encode the operation result") }; }
		match self {
			Self::Ark(v) => {
				let _lifecycle = state.wallet_lifecycle.lock().await;
				let wallet = state.require_wallet().map_err(|_| anyhow::anyhow!("Unlock your wallet first"))?;
				let destination = v.destination.parse::<ark::Address>().context("Enter an Ark address")?;
				ensure!(v.method.as_ref().is_none_or(|m| matches!(m, bark_json::web::PaymentMethodKind::Ark)) && v.comment.is_none(), "Unsupported Ark payment options");
				let amount = v.amount_sat.context("Enter an amount")?;
				ensure!(amount > 0 && v.max_total_sat.is_some_and(|limit| limit >= amount), "Review the full payment cost first");
				wallet.send_arkoor_payment_tracked(&destination, bitcoin::Amount::from_sat(amount), v.max_total_sat.map(bitcoin::Amount::from_sat),
					|id| receipt.started(Some(id.to_owned()), None)).await?;
				let record = receipt.load()?;
				let movement = wallet.movement_for_action(record.action_id.as_deref().context("Missing action receipt")?).await?.context("Missing payment record")?;
				Ok(json!({"movement_id":movement.id,"state":movement.status}))
			},
			Self::Lightning(v) => {
				ensure!(v.max_total_sat.is_some(), "Review the full payment cost first");
				let options = bark::LightningSendOptions::default().before_submit(move |hash| receipt.started(None, Some(hash.to_string())));
				call!(lightning::pay_with_options(state, v, options).await)
			},
			Self::Onchain(v) => call!(onchain::send_commit_tracked(state, v, || receipt.started(None, None)).await),
			Self::Replacement(v) => call!(onchain::replacement_commit_tracked(state, v, || receipt.started(None, None)).await),
			Self::Board(v) => call!(boards::commit_review_tracked(state, v, || receipt.started(None, None)).await),
			Self::Offboard(v) => call!(wallet::offboard_all_tracked(state, v, |id| receipt.started(Some(id.to_owned()), None)).await),
			Self::Claim(v) => call!(exits::exit_claim_all_tracked(state, v, |txid| receipt.transaction(txid)).await),
			Self::Refresh(_) => call!(wallet::refresh_all_tracked(state, |id| receipt.movement(id)).await),
			Self::Exit(_) => call!(exits::exit_start_all_tracked(state, |ids| receipt.exits(ids)).await),
			Self::Progress(v) => {
				// Progress advances existing exit state machines; it does not create
				// a new recipient or duplicate an exit. Reconcile by observing them.
				receipt.started(None, None)?;
				call!(exits::exit_progress(State(state), Json(v)).await)
			},
		}
	}
}

#[derive(Clone)]
struct Receipt { root: PathBuf, id: String }
impl Receipt {
	fn movement(&self, id: Option<bark::movement::MovementId>) -> anyhow::Result<()> {
		let mut record = self.load()?; record.initiated = true; record.movement_id = Some(id.context("Missing movement reference")?);
		save(&self.root, &record)
	}
	fn exits(&self, ids: &[ark::VtxoId]) -> anyhow::Result<()> {
		let mut record = self.load()?; record.initiated = true; record.exit_ids = Some(ids.to_vec());
		save(&self.root, &record)
	}
	fn transaction(&self, txid: bitcoin::Txid) -> anyhow::Result<()> {
		let mut record = self.load()?; record.initiated = true; record.txid = Some(txid.to_string());
		save(&self.root, &record)
	}
	fn load(&self) -> anyhow::Result<Record> { load(&path(&self.root, &self.id)?) }
	fn started(&self, action: Option<String>, hash: Option<String>) -> anyhow::Result<()> {
		let mut record = self.load()?;
		record.initiated = true;
		if action.is_some() { record.action_id = action; }
		if hash.is_some() { record.payment_hash = hash; }
		save(&self.root, &record)
	}

}

pub fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/", get(list).post(submit)).route("/check", post(check)).route("/ack", post(acknowledge))
		.layer(DefaultBodyLimit::max(128 * 1024))
}
fn response(result: anyhow::Result<Value>) -> (StatusCode, HeaderMap, Json<Value>) {
	let mut headers = HeaderMap::new(); headers.insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
	match result {
		Ok(value) => (StatusCode::OK, headers, Json(value)),
		Err(error) => (StatusCode::CONFLICT, headers, Json(json!({"message": error.to_string()}))),
	}
}
fn private_dir(path: &Path) -> anyhow::Result<()> {
	ensure!(!path.is_symlink(), "Submission storage cannot be a symbolic link");
	std::fs::create_dir_all(path)?;
	#[cfg(unix)]
	std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
	Ok(())
}
fn path(root: &Path, id: &str) -> anyhow::Result<PathBuf> {
	ensure!(id.len() == 64 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)), "Invalid submission ID");
	Ok(root.join(format!("{id}.json")))
}
fn save(root: &Path, record: &Record) -> anyhow::Result<()> {
	let path = path(root, &record.id)?;
	ensure!(!path.is_symlink(), "Submission storage cannot be a symbolic link");
	let bytes = serde_json::to_vec(record)?;
	ensure!(bytes.len() as u64 <= MAX_RECORD_BYTES, "Submission receipt is too large");
	let mut file = tempfile::NamedTempFile::new_in(root)?;
	file.write_all(&bytes)?; file.as_file().sync_all()?;
	file.persist(path).map_err(|_| anyhow::anyhow!("Could not save submission receipt"))?;
	std::fs::File::open(root)?.sync_all()?;
	Ok(())
}
fn load(path: &Path) -> anyhow::Result<Record> {
	ensure!(!path.is_symlink() && std::fs::metadata(path)?.len() <= MAX_RECORD_BYTES, "Invalid submission storage");
	let record: Record = serde_json::from_slice(&std::fs::read(path)?).context("Could not read saved submission; restore its backup")?;
	ensure!(matches!(record.state.as_str(), "unconfirmed" | "received" | "recorded" | "rejected"), "Unknown submission state; restore its backup");
	ensure!(path.file_name().and_then(|v| v.to_str()) == Some(format!("{}.json",record.id).as_str()), "Submission identity does not match its file");
	Ok(record)
}
fn records(root: &Path) -> anyhow::Result<Vec<Record>> {
	let mut result = Vec::new();
	for entry in std::fs::read_dir(root)? {
		let path = entry?.path();
		if path.extension().is_some_and(|s| s == "json") {
			ensure!(result.len() < 10000, "Submission history needs archival before continuing");
			result.push(load(&path)?);
		}
	}
	result.sort_by(|a, b| b.created.cmp(&a.created));
	Ok(result)
}
async fn root(state: &ServerState) -> anyhow::Result<PathBuf> {
	ensure!(state.auth_token().is_some(), "Configure wallet authentication first");
	let wallet = state.require_wallet().map_err(|_| anyhow::anyhow!("Unlock your wallet first"))?;
	let base = state.web.as_ref().context("Submission storage is unavailable")?.datadir.join("submissions");
	private_dir(&base)?;
	// Scope receipts by a full public wallet identity, not a four-byte fingerprint.
	let identity = sha256::Hash::hash(format!("{}:{}",wallet.network().await?,wallet.mailbox_identifier()).as_bytes()).to_string();
	let root = base.join(identity); private_dir(&root)?;
	Ok(root)
}
fn needs_review(record: &Record) -> bool {
	record.state == "unconfirmed" || (!record.acknowledged && matches!(record.state.as_str(), "received" | "recorded"))
}

fn public(record: &Record) -> Value {
	json!({"id":record.id,"operation":record.operation,"created":record.created,"state":record.state,
		"result":record.result,"txid":record.txid,"payment_hash":record.payment_hash,"action_id":record.action_id,"acknowledged":record.acknowledged})
}
async fn list(State(state): State<Arc<ServerState>>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let records = records(&root)?;
		Ok(json!({"version":1,"pending":records.iter().filter(|r|needs_review(r)).map(public).collect::<Vec<_>>(),
			"recent":records.iter().take(20).map(public).collect::<Vec<_>>()}))
	}.await)
}

/// The caller serializes submission dispatch and wallet deletion. The file lock
/// also excludes another daemon process using this same wallet directory.
async fn once<F, Fut>(root: &Path, request: &Request, references: (Option<String>, Option<String>), operation: F) -> anyhow::Result<Value>
where F: FnOnce(Receipt) -> Fut, Fut: Future<Output = anyhow::Result<Value>> {
	let _lock = bark::lock_manager::platform_default(Some(root), None)?;
	let file = path(root, &request.id)?;
	let digest = sha256::Hash::hash(&serde_json::to_vec(&json!([request.operation,request.body]))?).to_string();
	if file.exists() {
		let record = load(&file)?;
		ensure!(record.digest == digest && record.operation == request.operation, "Submission ID belongs to another request");
		ensure!(record.state != "unconfirmed", "This submission is unconfirmed. Check its saved status; it will not be sent again");
		return Ok(public(&record));
	}
	let previous = records(root)?;
	ensure!(previous.len() < 10000, "Submission history needs archival before continuing");
	ensure!(!previous.iter().any(needs_review), "A previous submission needs checking before another wallet action");
	let mut record = Record { id: request.id.clone(), operation: request.operation.clone(), digest,
		created: chrono::Utc::now().timestamp_millis(), state: "unconfirmed".into(), result: None, initiated: false, acknowledged: false, movement_id: None, exit_ids: None, action_id: None, txid: references.0, payment_hash: references.1 };
	save(root, &record)?;
	let receipt = Receipt { root: root.to_owned(), id: request.id.clone() };
	let result = tokio::time::timeout(Duration::from_secs(180), operation(receipt)).await;
	record = load(&file)?;
	match result {
		Ok(Ok(value)) => { record.state = "received".into(); record.result = Some(value); },
		_ if !record.initiated => {
			record.state = "rejected".into();
			record.result = Some(json!({"message":"This attempt did not submit a payment. Check the amount, available funds and connection, then review again."}));
		},
		_ => return Err(anyhow::anyhow!("Submission result is unknown. Check its saved status before another payment")),
	}
	save(root, &record)?;
	Ok(public(&record))
}
async fn submit(State(state): State<Arc<ServerState>>, Json(request): Json<Request>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let action = Action::parse(&request)?;
		let _session = state.submissions.try_lock().map_err(|_| anyhow::anyhow!("A wallet action is still running. Check saved status shortly"))?;
		let root = root(&state).await?;
		once(&root, &request, action.references(), |receipt| action.execute(state.clone(), receipt)).await
	}.await)
}

pub(crate) async fn ensure_resolved(state: &ServerState) -> anyhow::Result<()> {
	if state.require_wallet().is_err() || state.web.is_none() { return Ok(()); }
	ensure!(!records(&root(state).await?)?.iter().any(needs_review), "Resolve saved submissions before deleting this wallet");
	Ok(())
}
async fn acknowledge(State(state): State<Arc<ServerState>>, Json(request): Json<Check>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let _session = state.submissions.try_lock().map_err(|_| anyhow::anyhow!("A wallet action is still running. Check saved status shortly"))?;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let _file_lock = bark::lock_manager::platform_default(Some(&root), None)?;
		let mut record = load(&path(&root, &request.id)?)?;
		ensure!(record.state != "unconfirmed", "Check the uncertain submission before acknowledging it");
		record.acknowledged = true; save(&root, &record)?;
		Ok(public(&record))
	}.await)
}

// Caller must hold both the submission mutex and directory process lock.
fn load_or_close_unused(root: &Path, id: &str) -> anyhow::Result<Record> {
	let file = path(root, id)?;
	if file.exists() { return load(&file); }
	// Closing an unseen ID prevents a delayed HTTP request from sending later.
	ensure!(records(root)?.len() < 10000, "Submission history needs archival before continuing");
	let tombstone = Record { id: id.to_owned(), operation: String::new(), digest: String::new(),
		created: chrono::Utc::now().timestamp_millis(), state: "rejected".into(), result: None,
		initiated:false, acknowledged:false, movement_id:None, exit_ids:None, action_id:None, txid:None, payment_hash:None };
	save(root, &tombstone)?;
	Ok(tombstone)
}

async fn check(State(state): State<Arc<ServerState>>, Json(request): Json<Check>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let _session = state.submissions.try_lock().map_err(|_| anyhow::anyhow!("A wallet action is still running. Check saved status shortly"))?;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let _file_lock = bark::lock_manager::platform_default(Some(&root), None)?;
		let mut record = load_or_close_unused(&root, &request.id)?;
		if record.state == "unconfirmed" {
			if !record.initiated {
				// The submission mutex excludes a still-running handler. Without the
				// pre-submit marker, this operation never reached a spending checkpoint.
				record.state = "rejected".into();
				record.result = Some(json!({"message":"The interrupted request was not submitted. Review again when ready."}));
			} else if let Some(id) = record.movement_id {
				let wallet = state.require_wallet().map_err(|_| anyhow::anyhow!("Unlock your wallet first"))?;
				let movement = wallet.movement(id).await?;
				record.state = "recorded".into(); record.result = Some(json!({"movement_id":movement.id,"state":movement.status}));
			} else if let Some(ids) = &record.exit_ids {
				let wallet = state.require_wallet().map_err(|_| anyhow::anyhow!("Unlock your wallet first"))?;
				let mut complete = true;
				for id in ids { complete &= wallet.exit_mgr().get_exit_vtxo(*id).await.is_some(); }
				if complete { record.state = "recorded".into(); record.result = Some(json!({"state":"pending","message":"The requested exits are recorded. Check Recovery for progress."})); }
			} else if record.operation == "exits/progress" {
				let status = exits::get_all_exit_status(State(state.clone()), axum::extract::Query(bark_json::web::ExitStatusRequest { history: Some(false), transactions: Some(false) })).await.map_err(|_| anyhow::anyhow!("Could not read exit status"))?.0;
				record.state = "recorded".into(); record.result = Some(json!({"state":"pending","exits":status}));
			} else if let Some(action) = &record.action_id {
				let wallet = state.require_wallet().map_err(|_| anyhow::anyhow!("Unlock your wallet first"))?;
				if let Some(movement) = wallet.movement_for_action(action).await? {
					record.state = "recorded".into(); record.result = Some(json!({"movement_id":movement.id,"state":movement.status}));
				}
			} else if let Some(txid) = &record.txid {
				let transactions = onchain::onchain_transactions(State(state.clone())).await.map_err(|_| anyhow::anyhow!("Could not read wallet transactions"))?.0;
				let known = transactions.iter().any(|tx| tx.txid.to_string() == *txid);
				let wallet = state.require_wallet().map_err(|_| anyhow::anyhow!("Unlock your wallet first"))?;
				let expected = txid.parse::<bitcoin::Txid>()?;
				let observed = if known { true } else {
					tokio::time::timeout(Duration::from_secs(15), wallet.chain().get_tx(&expected)).await
						.ok().and_then(Result::ok).flatten().is_some_and(|tx| tx.compute_txid() == expected)
				};
				if observed {
					record.state = "recorded".into(); record.result = Some(json!({"txid":txid,"state":"recorded"}));
				}
			} else if let Some(hash) = &record.payment_hash {
				let status = lightning::get_send_status(State(state.clone()), axum::extract::Path(hash.clone())).await
					.map_err(|_| anyhow::anyhow!("Could not read the saved Lightning payment"))?.0;
				let value = serde_json::to_value(status)?;
				if value["state"].as_str().is_some_and(|s| s != "unknown") {
					record.state = "recorded".into(); record.result = Some(value);
				}
			}
			save(&root, &record)?;
		}
		Ok(public(&record))
	}.await)
}


#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::atomic::{AtomicUsize, Ordering};
	use axum::{body::Body, http::Request as HttpRequest};
	use tower::ServiceExt;
	use tokio_util::sync::CancellationToken;

	fn request(n: u8) -> Request {
		Request { id: format!("{n:064x}"), operation: "wallet/send".into(), body: json!({"destination":"public-fixture","amount_sat":1000}) }
	}

	#[tokio::test]
	async fn lost_success_reply_recovers_without_executing_again() {
		let dir = tempfile::tempdir().unwrap();
		private_dir(dir.path()).unwrap();
		let counter = AtomicUsize::new(0);
		let calls = &counter;
		let req = request(1);
		let result = once(dir.path(), &req, (None,None), |receipt| async move {
			assert_eq!(receipt.load().unwrap().state, "unconfirmed");
			receipt.started(Some("exact-action".into()), None).unwrap();
			calls.fetch_add(1, Ordering::SeqCst);
			Ok(json!({"state":"pending","movement_id":42}))
		}).await.unwrap();
		let recovered = once(dir.path(), &req, (None,None), |_| async {
			calls.fetch_add(1, Ordering::SeqCst); Ok(json!({}))
		}).await.unwrap();
		assert_eq!(result, recovered);
		assert_eq!(result["action_id"], "exact-action");
		assert_eq!(calls.load(Ordering::SeqCst), 1);
		assert_eq!(result["state"], "received");
		assert_eq!(result["result"]["state"], "pending");
		assert!(once(dir.path(), &request(2), (None,None), |_| async { panic!("deliver the original result before another send") }).await.is_err());
		let mut delivered = records(dir.path()).unwrap().remove(0); delivered.acknowledged = true; save(dir.path(), &delivered).unwrap();
		assert!(once(dir.path(), &request(2), (None,None), |_| async { Ok(json!({})) }).await.is_ok());
		let mut changed = request(1); changed.body["amount_sat"] = json!(2000);
		assert!(once(dir.path(), &changed, (None,None), |_| async { panic!("must not execute") }).await.is_err());
	}

	#[tokio::test]
	async fn error_after_submission_never_replays_or_allows_another_send() {
		let dir = tempfile::tempdir().unwrap();
		assert!(once(dir.path(), &request(1), (None,None), |receipt| async move {
			receipt.started(None, Some("exact-hash".into()))?;
			anyhow::bail!("lost response")
		}).await.is_err());
		assert_eq!(records(dir.path()).unwrap()[0].payment_hash.as_deref(), Some("exact-hash"));
		for n in [1,2] {
			assert!(once(dir.path(), &request(n), (None,None), |_| async { panic!("must not replay") }).await.is_err());
		}
	}

	#[tokio::test]
	async fn rejected_before_submission_allows_new_review_but_never_replays_old_id() {
		let dir = tempfile::tempdir().unwrap();
		let result = once(dir.path(), &request(1), (None,None), |_| async { anyhow::bail!("expired review") }).await.unwrap();
		assert_eq!(result["state"], "rejected");
		assert_eq!(once(dir.path(), &request(1), (None,None), |_| async { panic!("must not replay") }).await.unwrap(), result);
		assert!(once(dir.path(), &request(2), (None,None), |_| async { Ok(json!({})) }).await.is_ok());
	}

	#[tokio::test]
	async fn cancelled_operation_keeps_durable_pre_submit_marker() {
		for started in [false,true] {
			let dir = tempfile::tempdir().unwrap();
			let req = request(1);
			let future = once(dir.path(), &req, (None,None), |receipt| async move {
				if started { receipt.started(Some("exact-action".into()), None)?; }
				std::future::pending::<anyhow::Result<Value>>().await
			});
			assert!(tokio::time::timeout(Duration::from_millis(10), future).await.is_err());
			let saved = records(dir.path()).unwrap();
			assert_eq!(saved.len(),1); assert_eq!(saved[0].initiated,started);
			assert_eq!(saved[0].state,"unconfirmed");
		}
	}

	#[tokio::test]
	async fn receipts_are_private_and_do_not_store_request_bodies() {
		let dir = tempfile::tempdir().unwrap(); private_dir(dir.path()).unwrap();
		let req = request(1);
		once(dir.path(), &req, (None,None), |_| async { Ok(json!({"state":"pending"})) }).await.unwrap();
		let file = path(dir.path(), &req.id).unwrap();
		assert!(!std::fs::read_to_string(&file).unwrap().contains("public-fixture"));
		#[cfg(unix)] {
			assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,0o600);
			assert_eq!(std::fs::metadata(dir.path()).unwrap().permissions().mode() & 0o777,0o700);
		}
		for id in ["../escape", "", &"F".repeat(64)] { assert!(path(dir.path(),id).is_err()); }
		assert!(Action::parse(&Request { id:req.id, operation:"wallet/delete".into(),body:json!({}) }).is_err());
	}

	#[tokio::test]
	async fn checking_an_unseen_id_blocks_a_delayed_payment_request() {
		let directory = tempfile::tempdir().unwrap();
		let request = request(1);
		assert_eq!(load_or_close_unused(directory.path(),&request.id).unwrap().state,"rejected");
		assert!(once(directory.path(),&request,(None,None),|_| async { panic!("delayed request must not execute") }).await.is_err());
		assert_eq!(records(directory.path()).unwrap().len(),1);
	}

	#[tokio::test]
	async fn submission_routes_require_authentication_and_loaded_wallet() {
		let token = crate::auth::AuthToken::new([42;32]);
		let state = Arc::new(ServerState::builder().auth_token(token.clone()).build(CancellationToken::new()));
		let router = crate::api::v1::router(&state).with_state(state);
		for (url,method,body) in [("/submissions","GET",String::new()),
			("/submissions","POST",json!({"id":"01".repeat(32),"operation":"wallet/send","body":{"destination":"fixture","amount_sat":1000}}).to_string()),
			("/submissions/check","POST",json!({"id":"01".repeat(32)}).to_string()),
			("/submissions/ack","POST",json!({"id":"01".repeat(32)}).to_string())] {
			let request = HttpRequest::builder().method(method).uri(url).header("content-type","application/json").body(Body::from(body.clone())).unwrap();
			assert_eq!(router.clone().oneshot(request).await.unwrap().status(),StatusCode::UNAUTHORIZED);
			let request = HttpRequest::builder().method(method).uri(url).header("content-type","application/json").header("authorization",format!("Bearer {}",token.encode())).body(Body::from(body)).unwrap();
			let response = router.clone().oneshot(request).await.unwrap();
			assert_eq!(response.status(),StatusCode::CONFLICT);
			assert_eq!(response.headers()[header::CACHE_CONTROL],"no-store");
		}
	}

	#[cfg(unix)]
	#[test]
	fn symlink_storage_is_rejected() {
		let dir = tempfile::tempdir().unwrap();
		let target = dir.path().join("target"); std::fs::write(&target,b"private").unwrap();
		let linked = dir.path().join("linked"); std::os::unix::fs::symlink(&target,&linked).unwrap();
		assert!(load(&linked).is_err()); assert!(private_dir(&linked).is_err());
		assert_eq!(std::fs::read(&target).unwrap(),b"private");
	}
}
