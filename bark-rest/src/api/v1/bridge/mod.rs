//! Server-owned bridge quotes. Funding and settlement remain separate states;
//! these routes never send funds or retry a wallet/node payment.
mod client;
mod protocol;
#[cfg(test)]
mod tests;

use std::{future::Future, io::Write, path::{Path, PathBuf}, sync::{Arc, OnceLock}, time::{Duration, SystemTime, UNIX_EPOCH}};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::{DefaultBodyLimit, Query, State}, http::{HeaderMap, StatusCode, header}, routing::{get, post}};
use bitcoin::{Network, hashes::{Hash, sha256}};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ServerState;
use protocol::{Direction, Invoice, Quote};
use super::remote_node::{self, BridgeReceipt};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DirectionQuery { direction: Direction }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct QuoteRequest { direction: Direction, invoice: String }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckRequest { direction: Direction, hash: String }
#[derive(Serialize, Deserialize)]
struct Record {
	direction: Direction,
	target: String,
	quote: Quote,
	created: u64,
	state: String,
	verified_settlement: bool,
	#[serde(default)] receive_node_id: Option<String>,
	#[serde(default)] verified_receipt: bool,
}

pub fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/info",get(info)).route("/quotes",get(list).post(quote))
		.route("/check",post(check)).layer(DefaultBodyLimit::max(8192))
}
fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() }
fn response(result: anyhow::Result<Value>) -> (StatusCode, HeaderMap, Json<Value>) {
	let mut headers = HeaderMap::new(); headers.insert(header::CACHE_CONTROL,"no-store".parse().unwrap());
	match result {
		Ok(value) => (StatusCode::OK,headers,Json(value)),
		Err(error) => (StatusCode::CONFLICT,headers,Json(json!({"message":error.to_string()}))),
	}
}
fn client() -> anyhow::Result<&'static client::Bridge> {
	static CLIENT: OnceLock<client::Bridge> = OnceLock::new();
	if CLIENT.get().is_none() { let _ = CLIENT.set(client::Bridge::new()?); }
	CLIENT.get().context("Bridge connection unavailable")
}
fn private_dir(path: &Path) -> anyhow::Result<()> {
	ensure!(!path.is_symlink(), "Bridge storage cannot be a symbolic link");
	std::fs::create_dir_all(path)?;
	#[cfg(unix)] std::fs::set_permissions(path,std::fs::Permissions::from_mode(0o700))?;
	Ok(())
}
async fn root(state: &ServerState) -> anyhow::Result<PathBuf> {
	ensure!(state.auth_token().is_some(), "Configure wallet authentication first");
	let wallet = state.require_wallet().map_err(|_|anyhow::anyhow!("Unlock your wallet first"))?;
	ensure!(wallet.network().await? == Network::Bitcoin, "The bridge supports mainnet wallets only");
	let base = state.web.as_ref().context("Bridge storage unavailable")?.datadir.join("bridge-quotes"); private_dir(&base)?;
	let identity = sha256::Hash::hash(format!("{}:{}",Network::Bitcoin,wallet.mailbox_identifier()).as_bytes()).to_string();
	let root = base.join(identity); private_dir(&root)?; Ok(root)
}
fn path(root: &Path, direction: Direction, hash: &str) -> anyhow::Result<PathBuf> {
	ensure!(hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)), "Invalid bridge reference");
	Ok(root.join(format!("{}-{hash}.json",direction.text())))
}
fn save(root: &Path, record: &Record) -> anyhow::Result<()> {
	let path = path(root,record.direction,&record.quote.hash)?;
	ensure!(!path.is_symlink(), "Bridge storage cannot be a symbolic link");
	let bytes = serde_json::to_vec(record)?;
	ensure!(bytes.len() <= 16384, "Invalid bridge record size");
	let mut file = tempfile::NamedTempFile::new_in(root)?;
	file.write_all(&bytes)?; file.as_file().sync_all()?;
	file.persist(path).map_err(|_|anyhow::anyhow!("Could not save bridge quote. Do not pay its invoice"))?;
	std::fs::File::open(root)?.sync_all()?; Ok(())
}
fn load(root: &Path, file: &Path) -> anyhow::Result<Record> {
	ensure!(!file.is_symlink() && std::fs::metadata(file)?.len() <= 16384, "Invalid bridge storage");
	let record: Record = serde_json::from_slice(&std::fs::read(file)?).ok().context("Saved bridge quote is invalid; restore its backup")?;
	ensure!(path(root,record.direction,&record.quote.hash)? == file, "Bridge reference differs from its file");
	record.quote.validate(&Invoice::parse(&record.target)?,record.direction,None)?;
	Ok(record)
}
fn records(root: &Path) -> anyhow::Result<Vec<Record>> {
	let mut result = Vec::new();
	for entry in std::fs::read_dir(root)? {
		let file = entry?.path();
		if file.extension().is_some_and(|v|v == "json") {
			ensure!(result.len() < 1000, "Bridge history needs archival before continuing");
			result.push(load(root,&file)?);
		}
	}
	result.sort_by_key(|v|std::cmp::Reverse(v.created)); Ok(result)
}
fn public(record: &Record) -> anyhow::Result<Value> {
	let target = Invoice::parse(&record.target)?;
	let hold = record.quote.validate(&target,record.direction,None)?;
	Ok(json!({"direction":record.direction,"hash":record.quote.hash,"target_invoice":record.target,
		"target_msat":target.msat.to_string(),"hold_invoice":record.quote.hold_invoice,"funding_msat":hold.msat.to_string(),
		"pay_sat":record.quote.pay_sat,"rate":record.quote.rate,"spread":record.quote.spread,
		"expires_at":record.quote.expires_at,"created":record.created,"state":record.state,
		"receive_node_id":record.receive_node_id,"bridge_settled":record.verified_settlement,
		"verified_settlement":settled(record)}))
}
fn settled(record: &Record) -> bool {
	if record.direction == Direction::ReceiveXbt { record.receive_node_id.is_some() && record.verified_receipt }
	else { record.verified_settlement }
}
fn match_receipt(target: &Invoice, node_id: Option<&str>, receipt: &BridgeReceipt) -> anyhow::Result<()> {
	ensure!(target.xbt && receipt.payment_hash == target.hash && receipt.invoice == target.text && receipt.amount_msat == target.msat,
		"Node receipt differs from this bridge request");
	ensure!(receipt.node_id.parse::<bitcoin::secp256k1::PublicKey>().is_ok() && node_id.is_none_or(|id|id == receipt.node_id),
		"Reconnect the node that owns this bridge request");
	Ok(())
}
async fn info(State(state): State<Arc<ServerState>>, Query(query): Query<DirectionQuery>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		ensure!(state.auth_token().is_some(), "Configure wallet authentication first");
		state.require_wallet().map_err(|_|anyhow::anyhow!("Unlock your wallet first"))?;
		let info = client()?.availability(query.direction).await?;
		Ok(json!({"direction":query.direction,"open":info.open,"min_sat":info.min_sat,"max_sat":info.max_sat,"checked_at":now()}))
	}.await)
}
async fn list(State(state): State<Arc<ServerState>>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		Ok(json!({"quotes":records(&root)?.iter().map(public).collect::<anyhow::Result<Vec<_>>>()?}))
	}.await)
}
async fn quote(State(state): State<Arc<ServerState>>, Json(input): Json<QuoteRequest>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let _session = state.bridge.try_lock().map_err(|_|anyhow::anyhow!("A bridge request is already running. Check saved quotes shortly"))?;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let _file_lock = bark::lock_manager::platform_default(Some(&root),None)?;
		let state_ref = &state;
		retain_quote(&root, input, |target, direction| async move {
			let client = client()?;
			ensure!(client.availability(direction).await?.open, "The bridge is paused for this direction");
			let node_id = if direction == Direction::ReceiveXbt {
				let receipt = remote_node::bridge_receipt(state_ref,&target.hash).await?;
				match_receipt(&target,None,&receipt)?;
				ensure!(!receipt.received, "This node invoice is already paid. Create a new receive request");
				Some(receipt.node_id)
			} else { None };
			let quote = tokio::time::timeout(Duration::from_secs(90),client.quote(&target,direction)).await
				.map_err(|_|anyhow::anyhow!("Bridge quote timed out. No wallet payment was submitted"))??;
			Ok((quote,node_id))
		}).await
	}.await)
}
// Caller holds the wallet lifecycle, bridge session and directory process locks.
async fn retain_quote<F, Fut>(root: &Path, input: QuoteRequest, create: F) -> anyhow::Result<Value>
where F: FnOnce(Invoice, Direction) -> Fut, Fut: Future<Output = anyhow::Result<(Quote, Option<String>)>> {
	let target = Invoice::parse(&input.invoice)?;
	let file = path(root,input.direction,&target.hash)?;
	// A timeout at the browser or a restart returns the original quote;
	// it cannot replace an invoice which might already have been funded.
	if file.exists() {
		let record = load(root,&file)?;
		ensure!(record.target == target.text, "This payment hash already belongs to another saved invoice");
		return public(&record);
	}
	target.target(input.direction,now())?;
	ensure!(records(root)?.len() < 1000, "Bridge history needs archival before continuing");
	let text = target.text.clone();
	let (quote,receive_node_id) = create(target,input.direction).await?;
	quote.validate(&Invoice::parse(&text)?,input.direction,Some(now()))?;
	let record = Record {direction:input.direction,target:text,quote,created:now(),state:"quoted".into(),verified_settlement:false,
		receive_node_id,verified_receipt:false};
	save(root,&record)?; public(&record)
}
async fn check(State(state): State<Arc<ServerState>>, Json(input): Json<CheckRequest>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(async {
		let _session = state.bridge.try_lock().map_err(|_|anyhow::anyhow!("A bridge request is already running. Check again shortly"))?;
		let _lifecycle = state.wallet_lifecycle.lock().await;
		let root = root(&state).await?;
		let _file_lock = bark::lock_manager::platform_default(Some(&root),None)?;
		let mut record = load(&root,&path(&root,input.direction,&input.hash)?)?;
		if settled(&record) { return public(&record); }
		// A bridge outage cannot prevent checking the receiving node. Neither
		// operation creates an invoice, quote, or replacement payment.
		let (bridge, receipt) = tokio::join!(async { client()?.status(&record.quote).await }, async {
			if record.direction == Direction::ReceiveXbt {
				Some(remote_node::bridge_receipt(&state,&record.quote.hash).await)
			} else { None }
		});
		let result = reconcile(&mut record,bridge,receipt)?;
		save(&root,&record)?; Ok(result)
	}.await)
}
fn reconcile(record: &mut Record, bridge: anyhow::Result<protocol::SwapStatus>, receipt: Option<anyhow::Result<BridgeReceipt>>) -> anyhow::Result<Value> {
	let bridge_checked = bridge.is_ok();
	if let Ok(status) = bridge {
		record.state = status.public_state().to_owned();
		record.verified_settlement |= status.verified_settlement(&record.quote.hash);
	}
	let mut node_checked = false;
	if record.direction == Direction::ReceiveXbt {
		if let Some(Ok(receipt)) = receipt {
			let target = Invoice::parse(&record.target)?;
			if match_receipt(&target,record.receive_node_id.as_deref(),&receipt).is_ok() {
				node_checked = true;
				record.receive_node_id = Some(receipt.node_id);
				record.verified_receipt |= receipt.received;
			}
		}
	}
	let mut value = public(record)?;
	value["bridge_checked"] = json!(bridge_checked); value["node_checked"] = json!(node_checked);
	Ok(value)
}
