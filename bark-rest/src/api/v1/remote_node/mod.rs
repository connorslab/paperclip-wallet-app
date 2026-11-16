//! Direct CLN/XBT LND integration shared by the Umbrel and StartOS browser app.
//! Credentials never leave server storage after setup. A durable intent precedes
//! every payment; an unknown outcome can only be observed, never replayed.
mod model;
mod transport;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod live_tests;

use std::{collections::HashMap, io::Write, path::{Path, PathBuf}, sync::Arc, time::{Duration, Instant}};

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::{DefaultBodyLimit, State}, http::{HeaderMap, StatusCode, header}, routing::{get, post}};
use base64::{Engine, engine::general_purpose::URL_SAFE};
use bitcoin::{Network, hashes::{Hash, sha256}};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ServerState;
use model::{identity, invoice, msats};
use transport::{Connection, Node};

#[derive(Default)]
pub(crate) struct Sessions { reviews: HashMap<PathBuf, Review> }
struct Review { id: String, invoice: String, hash: String, node_id: String, amount_msat: u64, fee_sat: u64, created: Instant }

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
	operation: Operation,
	connection: Option<Connection>,
	#[serde(default)] destination: String,
	amount_sat: Option<u64>,
	maximum_fee_sat: Option<u64>,
	#[serde(default)] description: String,
	#[serde(default)] request_id: String,
	#[serde(default)] payment_hash: String,
	#[serde(default)] receive: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Operation { Connect, Refresh, Prepare, Pay, Invoice, Offer, Status }

#[derive(Serialize, Deserialize)]
struct Record {
	node_id: String,
	payment_hash: String,
	invoice: String,
	amount_msat: String,
	maximum_fee_sat: u64,
	receive: bool,
	state: String,
}

pub fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/connection", get(connection)).route("/request", post(request))
		.layer(DefaultBodyLimit::max(320 * 1024))
}
fn headers() -> HeaderMap {
	let mut result = HeaderMap::new(); result.insert(header::CACHE_CONTROL, "no-store".parse().unwrap()); result
}
fn response(result: anyhow::Result<Value>) -> (StatusCode, HeaderMap, Json<Value>) {
	match result {
		Ok(value) => (StatusCode::OK, headers(), Json(value)),
		Err(error) => (StatusCode::BAD_REQUEST, headers(), Json(json!({"message":error.to_string()}))),
	}
}
fn private_dir(path: &Path) -> anyhow::Result<()> {
	ensure!(!path.is_symlink(), "Node storage must not be a symbolic link");
	std::fs::create_dir_all(path).context("Could not create private node storage")?;
	#[cfg(unix)] { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?; }
	Ok(())
}
fn save(path: &Path, value: &impl Serialize) -> anyhow::Result<()> {
	ensure!(!path.is_symlink(), "Node storage must not be a symbolic link");
	let parent = path.parent().context("Node storage unavailable")?;
	let mut file = tempfile::NamedTempFile::new_in(parent).context("Could not save node state")?;
	file.write_all(&serde_json::to_vec(value)?)?; file.as_file().sync_all()?;
	file.persist(path).map_err(|_| anyhow::anyhow!("Could not commit node state"))?;
	std::fs::File::open(parent)?.sync_all()?;
	Ok(())
}
fn load<T: serde::de::DeserializeOwned>(path: &Path) -> anyhow::Result<T> {
	ensure!(!path.is_symlink(), "Node storage must not be a symbolic link");
	let data = std::fs::read(path).context("Saved node state is unavailable")?;
	serde_json::from_slice(&data).map_err(|_| anyhow::anyhow!("Saved node state is invalid; restore its backup"))
}
async fn context(state: &ServerState) -> anyhow::Result<(PathBuf, Network)> {
	ensure!(state.auth_token().is_some(), "Configure wallet authentication first");
	let wallet = state.require_wallet().map_err(|_| anyhow::anyhow!("Unlock your wallet first"))?;
	let web = state.web.as_ref().context("Node storage is not configured")?;
	let properties = wallet.properties().await?;
	let base = web.datadir.join("lightning-nodes"); private_dir(&base)?;
	let root = base.join(properties.fingerprint.to_string()); private_dir(&root)?;
	private_dir(&root.join("payments"))?;
	Ok((root, properties.network))
}
fn node(root: &Path) -> anyhow::Result<Node> {
	Node::new(load(&root.join("connection.json"))?, std::env::var("BARKD_LIGHTNING_TOR_PROXY").ok().as_deref())
}
fn records(root: &Path) -> anyhow::Result<Vec<Record>> {
	let mut records = Vec::new();
	for entry in std::fs::read_dir(root.join("payments"))? {
		let path = entry?.path();
		if path.extension().is_some_and(|extension| extension == "json") { records.push(load::<Record>(&path)?); }
	}
	Ok(records)
}
fn record_path(root: &Path, hash: &str, receive: bool) -> anyhow::Result<PathBuf> {
	let hash: sha256::Hash = hash.parse().context("Use a 64-character payment hash")?;
	Ok(root.join("payments").join(format!("{}-{hash}.json", if receive { "receive" } else { "send" })))
}
fn public_connection(connection: &Connection) -> Value {
	json!({"configured":true,"implementation":connection.implementation,"endpoint":connection.endpoint,
		"certificate_sha256":connection.certificate_sha256,"use_tor":connection.use_tor,"receive_only":connection.receive_only,"node_id":connection.node_id})
}
async fn connection(State(state): State<Arc<ServerState>>) -> (StatusCode, HeaderMap, Json<Value>) {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let _session = state.remote_node.lock().await;
	response(async {
		let (root, _) = context(&state).await?;
		if !root.join("connection.json").exists() { return Ok(json!({"configured":false})); }
		let saved: Connection = load(&root.join("connection.json"))?;
		let mut value = public_connection(&saved);
		value["payments"] = serde_json::to_value(records(&root)?.into_iter().filter(|r| r.node_id == saved.node_id).collect::<Vec<_>>())?;
		if root.join("offer.json").exists() {
			let offer: Value = load(&root.join("offer.json"))?;
			if offer["node_id"] == saved.node_id { value["offer"] = offer["offer"].clone(); }
		}
		Ok(value)
	}.await)
}
async fn verified(node: &Node, network: Network) -> anyhow::Result<String> {
	let (id, alias) = identity(&node.info().await?, node.connection.implementation, network)?;
	ensure!(id == node.connection.node_id, "The connected node’s identity changed. Verify its connection again");
	Ok(alias)
}
fn review_value(review: &Review) -> Value {
	json!({"request_id":review.id,"payment_hash":review.hash,"node_id":review.node_id,
		"amount_msat":review.amount_msat.to_string(),"maximum_fee_sat":review.fee_sat,
		"maximum_total_msat":(review.amount_msat + review.fee_sat * 1000).to_string()})
}
fn check_review(review: &Review, input: &Request, node: &Node) -> anyhow::Result<()> {
	ensure!(review.id == input.request_id && review.hash == input.payment_hash && input.maximum_fee_sat == Some(review.fee_sat)
		&& review.node_id == node.connection.node_id && review.created.elapsed() < Duration::from_secs(60), "Payment review changed or expired. Review again; nothing was submitted");
	ensure!(!node.connection.receive_only, "This connection is set to receive only");
	Ok(())
}
async fn execute(state: &ServerState, sessions: &mut Sessions, input: Request) -> anyhow::Result<Value> {
	let (root, network) = context(state).await?;
	execute_at(root, network, sessions, input).await
}
// Narrow read-only interface for Bridge reconciliation. The caller holds the
// wallet lifecycle lock; status reads the original durable receive record and
// checks the current node's identity, invoice, hash and paid amount.
pub(super) struct BridgeReceipt {
	pub node_id: String,
	pub payment_hash: String,
	pub invoice: String,
	pub amount_msat: u64,
	pub received: bool,
}
pub(super) async fn bridge_receipt(state: &ServerState, hash: &str) -> anyhow::Result<BridgeReceipt> {
	tokio::time::timeout(Duration::from_secs(45), async {
		let mut sessions = state.remote_node.lock().await;
		let input = Request { operation:Operation::Status, connection:None, destination:String::new(), amount_sat:None,
			maximum_fee_sat:None, description:String::new(), request_id:String::new(), payment_hash:hash.into(), receive:true };
		let record: Record = serde_json::from_value(execute(state, &mut sessions, input).await?)?;
		ensure!(record.receive && record.payment_hash == hash, "Node returned another receive request");
		Ok(BridgeReceipt {node_id:record.node_id,payment_hash:record.payment_hash,invoice:record.invoice,
			amount_msat:record.amount_msat.parse()?,received:record.state == "succeeded"})
	}).await.map_err(|_|anyhow::anyhow!("Node receipt check timed out. Check this saved request again"))?
}
async fn execute_at(root: PathBuf, network: Network, sessions: &mut Sessions, input: Request) -> anyhow::Result<Value> {
	// Also exclude a second daemon process writing the same saved connection.
	let _lock = bark::lock_manager::platform_default(Some(&root), None)?;
	if matches!(input.operation, Operation::Connect) {
		let mut connection = input.connection.context("Enter a node connection")?;
		if connection.credential.is_empty() {
			let saved: Connection = load(&root.join("connection.json"))?;
			ensure!(connection.implementation == saved.implementation && connection.endpoint == saved.endpoint,
				"Enter the credential again when changing the REST address or node software");
			connection.credential = saved.credential;
			connection.node_id = saved.node_id;
		}
		let mut node = Node::new(connection, std::env::var("BARKD_LIGHTNING_TOR_PROXY").ok().as_deref())?;
		let (id, alias) = identity(&node.info().await?, node.connection.implementation, network)?;
		if !node.connection.node_id.is_empty() { ensure!(node.connection.node_id == id, "This address serves another node"); }
		ensure!(records(&root)?.iter().all(|r| r.receive || matches!(r.state.as_str(), "failed" | "succeeded") || r.node_id == id), "Check the current node’s pending payments before switching nodes");
		node.connection.node_id = id;
		save(&root.join("connection.json"), &node.connection)?;
		sessions.reviews.remove(&root);
		let mut value = public_connection(&node.connection); value["alias"] = json!(alias);
		return Ok(value);
	}
	let node = node(&root)?;
	match input.operation {
		Operation::Refresh => {
			let alias = verified(&node, network).await?;
			let result = node.request(if node.cln() { "v1/listpeerchannels" } else { "v1/channels" }, node.cln().then(||json!({})), false).await?;
			Ok(json!({"alias":alias,"node_id":node.connection.node_id,"balance":model::balance(&result, node.connection.implementation)?}))
		},
		Operation::Prepare => {
			ensure!(!node.connection.receive_only, "This connection is set to receive only");
			sessions.reviews.remove(&root);
			verified(&node, network).await?;
			let fee = input.maximum_fee_sat.context("Enter a maximum routing fee")?;
			ensure!(fee <= 1_000_000, "Maximum routing fee exceeds the supported limit");
			let mut text = input.destination;
			if text.to_ascii_lowercase().starts_with("lno1") {
				let (offer, amount) = model::offer(&text, network, input.amount_sat)?;
				let result = node.request(if node.cln() { "v1/fetchinvoice" } else { "v2/offers/fetchinvoice" }, Some(if node.cln() {
					json!({"offer":text,"amount_msat":format!("{amount}msat"),"timeout":30})
				} else { json!({"offer":text,"amount_msat":amount.to_string(),"timeout_seconds":30}) }), false).await?;
				text = result[if node.cln() { "invoice" } else { "bolt12" }].as_str().context("Node returned no offer invoice")?.to_owned();
				model::issued(&invoice(&text, network)?, &offer, amount)?;
			}
			let parsed = invoice(&text, network)?;
			let amount = parsed.amount_msat().context("Invoice amount missing")?;
			if let Some(entered) = input.amount_sat { ensure!(msats(entered)? == amount, "Entered amount differs from the invoice"); }
			ensure!(node.cln() || !text.to_ascii_lowercase().starts_with("lni1") || fee > 0, "XBT LND BOLT12 needs a positive fee cap; zero would use the node’s default");
			let hash = parsed.payment_hash().to_string();
			ensure!(!record_path(&root, &hash, false)?.exists(), "This invoice already has a payment attempt. Check its status; it will not be resent");
			let review = Review { id: sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()).to_string(), invoice:text, hash,
				node_id:node.connection.node_id.clone(), amount_msat:amount, fee_sat:fee, created:Instant::now() };
			let result = review_value(&review); sessions.reviews.insert(root, review); Ok(result)
		},
		Operation::Pay => {
			let review = sessions.reviews.remove(&root).context("Review this payment first. Expired reviews are never submitted")?;
			check_review(&review, &input, &node)?;
			verified(&node, network).await?;
			check_review(&review, &input, &node)?;
			invoice(&review.invoice, network)?;
			let path = record_path(&root, &review.hash, false)?;
			ensure!(!path.exists(), "This invoice already has a payment attempt. Check its status");
			let mut record = Record { node_id:review.node_id, payment_hash:review.hash, invoice:review.invoice,
				amount_msat:review.amount_msat.to_string(), maximum_fee_sat:review.fee_sat, receive:false, state:"unknown".into() };
			// Crash, cancellation, timeout, and invalid responses all leave this
			// intent intact. No error path deletes it or reissues the payment.
			save(&path, &record)?;
			let result = if node.cln() {
				node.request("v1/pay", Some(json!({"bolt11":record.invoice,"maxfee":format!("{}msat",msats(record.maximum_fee_sat)?),"retry_for":30})), false).await
			} else if record.invoice.to_ascii_lowercase().starts_with("lni1") {
				node.request("v2/offers/pay", Some(json!({"invoice":record.invoice,"fee_limit_msat":msats(record.maximum_fee_sat)?.to_string(),"timeout_seconds":30})), false).await
			} else {
				node.request("v2/router/send", Some(json!({"payment_request":record.invoice,"fee_limit_sat":record.maximum_fee_sat.to_string(),"timeout_seconds":30,"no_inflight_updates":false,"cancelable":false})), true).await
			};
			if let Ok(result) = result {
				if !node.cln() && record.invoice.to_ascii_lowercase().starts_with("lni1") {
					if result["bolt12"] == record.invoice && model::hash(&result["payment_hash"]).is_ok_and(|v|v.to_string() == record.payment_hash)
						&& model::hash(&result["payment_preimage"]).is_ok_and(|v|sha256::Hash::hash(v.as_ref()).to_string() == record.payment_hash) {
						record.state = "succeeded".into();
					}
				} else { record.state = model::payment_state(&[result], &record.payment_hash).into(); }
				save(&path, &record)?;
			}
			Ok(serde_json::to_value(record)?)
		},
		Operation::Invoice | Operation::Offer => {
			verified(&node, network).await?;
			let description = if input.description.trim().is_empty() { "Paperclip wallet" } else { input.description.trim() };
			ensure!(description.len() <= 256 && !description.chars().any(char::is_control), "Use a description up to 256 characters");
			let label = sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()).to_string();
			let amount = input.amount_sat.map(msats).transpose()?;
			ensure!(amount.is_none_or(|v|v > 0), "Enter a positive amount");
			if matches!(input.operation, Operation::Offer) {
				let result = node.request(if node.cln() { "v1/offer" } else { "v2/offers" }, Some(if node.cln() {
					json!({"amount":amount.map(|v|format!("{v}msat")).unwrap_or("any".into()),"description":description,"label":label})
				} else { json!({"amount_msat":amount.unwrap_or(0).to_string(),"description":description,"label":label}) }), false).await?;
				let fields = if node.cln() { &result } else { &result["offer"] };
				ensure!(fields["active"] == true, "The node returned an inactive offer");
				let text = fields["bolt12"].as_str().context("Node returned no offer")?;
				model::offer(text, network, input.amount_sat.or(Some(1)))?;
				let saved = json!({"node_id":node.connection.node_id,"offer":text}); save(&root.join("offer.json"), &saved)?;
				Ok(saved)
			} else {
				let amount = amount.context("Enter an invoice amount")?;
				let result = node.request(if node.cln() { "v1/invoice" } else { "v1/invoices" }, Some(if node.cln() {
					json!({"amount_msat":format!("{amount}msat"),"label":label,"description":description})
				} else { json!({"value":(amount/1000).to_string(),"memo":description,"expiry":"3600"}) }), false).await?;
				let text = result[if node.cln() { "bolt11" } else { "payment_request" }].as_str().context("Node returned no invoice")?;
				let parsed = invoice(text, network)?;
				ensure!(parsed.amount_msat() == Some(amount), "Node returned a different invoice amount");
				let record = Record { node_id:node.connection.node_id.clone(),payment_hash:parsed.payment_hash().to_string(),invoice:text.into(),amount_msat:amount.to_string(),maximum_fee_sat:0,receive:true,state:"pending".into() };
				save(&record_path(&root, &record.payment_hash, true)?, &record)?;
				Ok(serde_json::to_value(record)?)
			}
		},
		Operation::Status => {
			let path = record_path(&root, &input.payment_hash, input.receive)?;
			let mut record: Record = load(&path)?;
			ensure!(record.node_id == node.connection.node_id, "Reconnect the node that owns this payment");
			verified(&node, network).await?;
			if input.receive && record.state != "succeeded" {
				let result = node.request(if node.cln() { "v1/listinvoices".into() } else { format!("v1/invoice/{}",record.payment_hash) }.as_str(), node.cln().then(||json!({"payment_hash":record.payment_hash})), false).await?;
				record.state = model::invoice_receipt(&result,node.cln(),&record.payment_hash,&record.invoice,record.amount_msat.parse()?)?.into();
			} else if !input.receive && !matches!(record.state.as_str(), "succeeded" | "failed") {
				let rows = if node.cln() {
					let result = node.request("v1/listpays", Some(json!({"payment_hash":record.payment_hash})), false).await?;
					result["pays"].as_array().context("Invalid node payment status")?.clone()
				} else {
					let hash: sha256::Hash = record.payment_hash.parse()?;
					vec![node.request(&format!("v2/router/track/{}?no_inflight_updates=false", URL_SAFE.encode(hash.to_byte_array())), None, true).await?]
				};
				record.state = model::payment_state(&rows, &record.payment_hash).into();
			}
			save(&path, &record)?; Ok(serde_json::to_value(record)?)
		},
		Operation::Connect => unreachable!("handled above"),
	}
}
async fn request(State(state): State<Arc<ServerState>>, Json(input): Json<Request>) -> (StatusCode, HeaderMap, Json<Value>) {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let mut sessions = state.remote_node.lock().await;
	response(tokio::time::timeout(Duration::from_secs(180), execute(&state, &mut sessions, input)).await
		.unwrap_or_else(|_| Err(anyhow::anyhow!("Node operation timed out. Check its saved payment status before trying again"))))
}

#[cfg(test)]
mod storage_tests {
	use super::*;
	use super::transport::Implementation;
	#[test]
	fn durable_intent_is_private_and_reloaded_after_restart() {
		let dir = tempfile::tempdir().unwrap(); private_dir(&dir.path().join("payments")).unwrap();
		let hash = "01".repeat(32);
		let path = record_path(dir.path(), &hash, false).unwrap();
		let record = Record { node_id:"node".into(),payment_hash:hash,invoice:"invoice".into(),amount_msat:"1000".into(),maximum_fee_sat:1,receive:false,state:"unknown".into() };
		save(&path,&record).unwrap();
		assert_eq!(records(dir.path()).unwrap()[0].state,"unknown");
		assert!(record_path(dir.path(),"../connection",false).is_err());
		#[cfg(unix)] { use std::os::unix::fs::PermissionsExt; assert_eq!(std::fs::metadata(path).unwrap().permissions().mode() & 0o777,0o600); }
	}
	#[test]
	fn credentials_are_omitted_from_browser_response() {
		let connection = Connection { implementation:Implementation::Lnd, endpoint:"https://node.local".into(),credential:"SECRET".into(),certificate_sha256:String::new(),use_tor:false,receive_only:true,node_id:"node".into() };
		let value = public_connection(&connection).to_string(); assert!(!value.contains("SECRET")); assert!(!value.contains("credential"));
	}
}
