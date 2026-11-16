//! Public-only QR accounts. Each account has its own database and signing request.
//! All signatures use the same reviewed-transaction verifier as the mobile apps.
use std::{collections::HashMap, io::Write, path::{Path, PathBuf}, sync::Arc, time::{Duration, Instant}};

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::{DefaultBodyLimit, State}, http::StatusCode, routing::{get, post}};
use base64::{Engine, engine::general_purpose::STANDARD};
use bitcoin::{Amount, Network, Psbt, Transaction, hashes::{Hash, sha256}};
use bark::{onchain::{OnchainWallet, OnchainWalletTrait, qr}, persist::sqlite::SqliteClient};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ServerState;

#[derive(Default)]
pub(crate) struct Accounts { pending: HashMap<PathBuf, Pending> }
struct Pending { psbt: Psbt, signed: Option<Transaction>, created: Instant }

#[derive(Clone, Deserialize, Serialize)]
struct Account { id: String, label: String, receive: String, change: String, network: Network }

#[derive(Deserialize)]
struct Request {
	#[serde(default)] target_account: Option<String>,
	operation: Operation,
	#[serde(default)] account: String,
	#[serde(default)] label: String,
	#[serde(default)] public_key: String,
	#[serde(default)] script: String,
	#[serde(default)] origin: String,
	#[serde(default)] destination: String,
	amount_sat: Option<u64>,
	#[serde(default)] request_id: String,
	#[serde(default)] signed: String,
	#[serde(default)] txid: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Operation { Destination, Pair, Rename, Address, Refresh, Prepare, Verify, Broadcast, Cancel }

pub fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/accounts", get(accounts)).route("/request", post(request))
		.layer(DefaultBodyLimit::max(qr::MAX_TRANSFER * 2 + 8192))
}

fn wallet_label(label: &str) -> anyhow::Result<String> {
	let label = label.trim();
	ensure!(!label.is_empty() && label.chars().count() <= 64 && !label.chars().any(char::is_control), "Use a wallet name of 1 to 64 characters");
	Ok(label.to_owned())
}
fn rename(root: &Path, id: &str, network: Network, label: &str) -> anyhow::Result<Account> {
	let mut account = read_account(root, id, network)?;
	account.label = wallet_label(label)?;
	save(&account_dir(root, id)?.join("account.json"), &account)?;
	Ok(account)
}
fn account_id(receive: &str, network: Network) -> String {
	sha256::Hash::hash(format!("{network}:{receive}").as_bytes()).to_string()
}
fn account_dir(root: &Path, id: &str) -> anyhow::Result<PathBuf> {
	ensure!(id.len() == 64 && id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)), "Select a paired QR wallet");
	Ok(root.join(id))
}
fn private_dir(path: &Path) -> anyhow::Result<()> {
	std::fs::create_dir_all(path)?;
	#[cfg(unix)] { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?; }
	Ok(())
}
fn save(path: &Path, value: &impl Serialize) -> anyhow::Result<()> {
	let staging = path.with_extension("pending");
	let mut options = std::fs::OpenOptions::new(); options.create(true).truncate(true).write(true);
	#[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
	let mut file = options.open(&staging)?;
	file.write_all(&serde_json::to_vec(value)?)?; file.sync_all()?;
	std::fs::rename(staging, path)?;
	std::fs::File::open(path.parent().context("Account directory missing")?)?.sync_all()?;
	Ok(())
}
fn read_account(root: &Path, id: &str, network: Network) -> anyhow::Result<Account> {
	let account: Account = serde_json::from_slice(&std::fs::read(account_dir(root, id)?.join("account.json"))?)?;
	ensure!(account.id == id && account.network == network && account_id(&account.receive, network) == id, "QR wallet identity mismatch");
	let (receive, change) = qr::descriptors(&account.receive, "segwit", "", network, true)?;
	ensure!(receive.split('#').next() == account.receive.split('#').next() && change.split('#').next() == account.change.split('#').next(), "QR wallet descriptors changed");
	Ok(account)
}
async fn open(root: &Path, account: &Account) -> anyhow::Result<OnchainWallet> {
	let file = account_dir(root, &account.id)?.join("db.sqlite");
	let mut options = std::fs::OpenOptions::new(); options.create(true).append(true);
	#[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
	options.open(&file)?;
	OnchainWallet::load_or_create_public(account.network, &account.receive, &account.change, Arc::new(SqliteClient::open(file)?)).await
}
async fn context(state: &ServerState) -> anyhow::Result<(bark::Wallet, PathBuf, Network)> {
	ensure!(state.auth_token().is_some(), "Configure wallet authentication first");
	let wallet = state.require_wallet().map_err(|_| anyhow::anyhow!("Unlock your wallet first"))?;
	let web = state.web.as_ref().context("QR wallet storage is not configured")?;
	let properties = wallet.properties().await?;
	let root = web.datadir.join("qr-wallets").join(properties.fingerprint.to_string());
	private_dir(&root)?;
	Ok((wallet, root, properties.network))
}
fn response(result: anyhow::Result<Value>) -> (StatusCode, Json<Value>) {
	match result {
		Ok(value) => (StatusCode::OK, Json(value)),
		Err(error) => (StatusCode::BAD_REQUEST, Json(json!({"message": error.to_string()}))),
	}
}
async fn accounts(State(state): State<Arc<ServerState>>) -> (StatusCode, Json<Value>) {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let _guard = state.hardware.lock().await;
	response(async {
		let (_, root, network) = context(&state).await?;
		let mut accounts = Vec::new();
		for entry in std::fs::read_dir(&root)? {
			let entry = entry?;
			if entry.file_type()?.is_dir() && entry.path().join("account.json").exists() {
				let account = read_account(&root, &entry.file_name().to_string_lossy(), network)?;
				accounts.push(json!({"id": account.id, "label": account.label, "kind": "hardware"}));
			}
		}
		accounts.sort_by_key(|a| a["label"].as_str().unwrap_or_default().to_owned());
		Ok(json!({"accounts": accounts}))
	}.await)
}

#[derive(Deserialize, Serialize)]
struct Relay { txid: String, transaction: String, state: String }
fn relay(path: &Path) -> anyhow::Result<Option<Relay>> {
	if !path.exists() { return Ok(None); }
	Ok(Some(serde_json::from_slice(&std::fs::read(path)?)?))
}
fn check_request(pending: &Pending, id: &str) -> anyhow::Result<()> {
	ensure!(pending.created.elapsed() < Duration::from_secs(1800), "Signing request expired. Review a new request");
	ensure!(pending.psbt.unsigned_tx.compute_txid().to_string() == id, "This response belongs to another signing request");
	Ok(())
}
async fn request(State(state): State<Arc<ServerState>>, Json(request): Json<Request>) -> (StatusCode, Json<Value>) {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let mut accounts = state.hardware.lock().await;
	response(async {
		let (main, root, network) = context(&state).await?;
		// Cross-process lock prevents a second wallet server from editing these accounts.
		let _lock = bark::lock_manager::platform_default(Some(&root), None)?;
		if matches!(request.operation, Operation::Destination) {
			let target = request.target_account.as_deref().context("Choose a destination wallet")?;
			ensure!(target != request.account, "Choose a different destination wallet");
			let (label, address) = if target.is_empty() {
				("Hot wallet".to_owned(), state.require_onchain().map_err(|_| anyhow::anyhow!("Hot wallet is unavailable"))?.write().await.address().await?)
			} else {
				let account = read_account(&root, target, network)?;
				ensure!(account_dir(&root, target)?.join("db.sqlite").is_file(), "Destination wallet database is missing; restore it first");
				let mut wallet = open(&root, &account).await?;
				(account.label, wallet.address().await?)
			};
			return Ok(json!({"account":target, "label":label, "address":address.to_string(), "network":network}));
		}
		if matches!(request.operation, Operation::Pair) {
			let label = wallet_label(&request.label)?;
			let (receive, change) = qr::descriptors(&request.public_key, &request.script, &request.origin, network, true)?;
			let id = account_id(&receive, network);
			let directory = account_dir(&root, &id)?;
			ensure!(directory.exists() || std::fs::read_dir(&root)?.count() < 32, "This server supports up to 32 QR wallets");
			private_dir(&directory)?;
			let account = Account { id, label, receive, change, network };
			let mut wallet = open(&root, &account).await?;
			// Pairing does not create a new receive address each time the same account is scanned.
			let first = wallet.address_page(0, false)?.0[0].1.clone();
			save(&directory.join("account.json"), &account)?;
			wallet.persist().await?;
			return Ok(json!({"id": account.id, "label": account.label, "receive": account.receive, "first_address": first}));
		}
		if matches!(request.operation, Operation::Rename) {
			let account = rename(&root, &request.account, network, &request.label)?;
			accounts.pending.remove(&account_dir(&root, &account.id)?);
			return Ok(json!({"id": account.id, "label": account.label}));
		}
		let account = read_account(&root, &request.account, network)?;
		let directory = account_dir(&root, &account.id)?;
		let mut wallet = open(&root, &account).await?;
		let relay_file = directory.join("broadcast.json");
		// Recover the exact pre-relay journal. Never automatically submit it again.
		if let Some(record) = relay(&relay_file)? {
			let tx: Transaction = bitcoin::consensus::deserialize(&STANDARD.decode(&record.transaction)?)?;
			ensure!(tx.compute_txid().to_string() == record.txid, "Saved transaction identity mismatch");
			if !wallet.list_transactions().iter().any(|item| item.compute_txid() == tx.compute_txid()) {
				wallet.register_tx(&tx).await?;
			}
		}
		match request.operation {
			Operation::Destination | Operation::Pair | Operation::Rename => unreachable!(),
			Operation::Cancel => { accounts.pending.remove(&directory); Ok(json!({})) },
			Operation::Address => Ok(json!({"address": wallet.address().await?.to_string()})),
			Operation::Refresh => {
				tokio::time::timeout(Duration::from_secs(90), wallet.sync(main.chain())).await.context("Refresh timed out. Your selected QR wallet did not change")??;
				let history = wallet.list_transaction_infos()?;
				let mut last = relay(&relay_file)?;
				if let Some(record) = last.as_mut() {
					if history.iter().any(|tx| tx.txid.to_string() == record.txid && tx.confirmation.is_some()) {
						record.state = "confirmed".into(); save(&relay_file, record)?;
					}
				}
				let balance = wallet.balance();
				Ok(json!({"confirmed_sat": balance.confirmed.to_sat(), "pending_sat": balance.trusted_pending.to_sat() + balance.untrusted_pending.to_sat(),
					"last_broadcast": last.map(|r| json!({"state": r.state, "txid": r.txid})),
					"transactions": history.into_iter().map(|tx| json!({"txid": tx.txid.to_string(), "amount_sat": tx.balance_change.to_sat(), "confirmed": tx.confirmation.is_some()})).collect::<Vec<_>>()}))
			},
			Operation::Prepare => {
				accounts.pending.remove(&directory);
				ensure!(!relay(&relay_file)?.is_some_and(|r| r.state == "pending_broadcast"), "A previous broadcast is uncertain. Reconcile that transaction before preparing another payment");
				let amount = request.amount_sat.context("Enter an amount in sats")?;
				ensure!(amount > 0 && amount <= Amount::MAX_MONEY.to_sat(), "Invalid amount");
				let address = request.destination.parse::<bitcoin::Address<_>>()?.require_network(network)?;
				tokio::time::timeout(Duration::from_secs(90), wallet.sync(main.chain())).await.context("Refresh timed out. No signing request was created")??;
				tokio::time::timeout(Duration::from_secs(15), main.chain().update_fee_rates(main.config().fallback_fee_rate)).await.context("Fee lookup timed out. No signing request was created")??;
				let fee_rate = main.chain().fee_rates().await.regular;
				let mut psbt = wallet.prepare_tx(&[(address, Amount::from_sat(amount))], fee_rate).await?;
				qr::prepare(&mut psbt)?;
				ensure!(psbt.serialize().len() <= qr::MAX_TRANSFER, "Transaction is too large for QR signing");
				// A prepared request reveals change to the signer. Preserve that address
				// index even if this request is cancelled or the service restarts.
				wallet.persist().await?;
				let fee = psbt.fee()?.to_sat();
				let result = json!({"request_id": psbt.unsigned_tx.compute_txid().to_string(), "account": account.id, "destination": request.destination,
					"amount_sat": amount, "fee_sat": fee, "total_sat": amount.checked_add(fee).context("Amount overflow")?, "psbt": STANDARD.encode(psbt.serialize())});
				accounts.pending.insert(directory, Pending { psbt, signed: None, created: Instant::now() });
				Ok(result)
			},
			Operation::Verify => {
				let pending = accounts.pending.get_mut(&directory).context("Review a signing request in this wallet first")?;
				check_request(pending, &request.request_id)?;
				ensure!(request.signed.len() <= qr::MAX_TRANSFER * 2, "Signed response is too large");
				let tx = qr::signed_transaction(&pending.psbt, &STANDARD.decode(&request.signed)?)?;
				let result = json!({"verified": true, "txid": tx.compute_txid().to_string(), "fee_sat": pending.psbt.fee()?.to_sat()});
				pending.signed = Some(tx); Ok(result)
			},
			Operation::Broadcast => {
				let pending = accounts.pending.get(&directory).context("Review and sign a request first")?;
				check_request(pending, &request.request_id)?;
				let tx = pending.signed.as_ref().context("Scan and verify the signed response first")?.clone();
				ensure!(tx.compute_txid().to_string() == request.txid, "Transaction changed");
				tokio::time::timeout(Duration::from_secs(90), wallet.sync(main.chain())).await.context("Refresh timed out. No transaction was broadcast")??;
				let unspent: std::collections::HashSet<_> = wallet.list_unspent().iter().map(|coin| coin.outpoint).collect();
				ensure!(tx.input.iter().all(|input| unspent.contains(&input.previous_output)), "An input is no longer unspent. Refresh and review your wallet");
				let mut record = Relay { txid: request.txid, transaction: STANDARD.encode(bitcoin::consensus::serialize(&tx)), state: "pending_broadcast".into() };
				save(&relay_file, &record)?;
				wallet.register_tx(&tx).await?;
				accounts.pending.remove(&directory);
				if matches!(tokio::time::timeout(Duration::from_secs(30), main.chain().broadcast_tx(&tx)).await, Ok(Ok(()))) {
					record.state = "submitted".into(); save(&relay_file, &record)?;
				}
				Ok(json!({"state": record.state, "txid": record.txid}))
			},
		}
	}.await)
}

#[cfg(test)]
mod tests {
	use super::*;

	fn fixtures() -> Vec<Value> {
		serde_json::from_str(include_str!("../../../../mobile/Tests/PaperclipMobileTests/Fixtures/krux.json")).unwrap()
	}
	#[tokio::test]
	async fn paired_accounts_keep_separate_addresses_and_survive_reopen() {
		let root = std::env::temp_dir().join(format!("paperclip-qr-accounts-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
		private_dir(&root).unwrap();
		let mut saved = Vec::new();
		for fixture in fixtures().iter().take(2) {
			let (receive, change) = qr::descriptors(fixture["public_key"].as_str().unwrap(), fixture["script"].as_str().unwrap(), "", Network::Bitcoin, true).unwrap();
			let account = Account { id: account_id(&receive, Network::Bitcoin), label: "Test signer".into(), receive, change, network: Network::Bitcoin };
			let dir = account_dir(&root, &account.id).unwrap(); private_dir(&dir).unwrap();
			save(&dir.join("account.json"), &account).unwrap();
			let account = read_account(&root, &account.id, Network::Bitcoin).unwrap();
			let mut wallet = open(&root, &account).await.unwrap();
			let first = wallet.address().await.unwrap().to_string();
			assert_eq!(first, fixture["receive_address"]);
			assert!(wallet.balance().total() == Amount::ZERO);
			drop(wallet);
			let renamed = rename(&root, &account.id, Network::Bitcoin, "  Savings signer  ").unwrap();
			assert_eq!(renamed.label, "Savings signer");
			assert_eq!(renamed.receive, account.receive);
			assert_eq!(renamed.change, account.change);
			assert_eq!(read_account(&root, &account.id, Network::Bitcoin).unwrap().label, "Savings signer");
			assert!(rename(&root, &account.id, Network::Bitcoin, "   ").is_err());
			assert!(rename(&root, &account.id, Network::Bitcoin, "name\nchanged").is_err());
			assert!(rename(&root, &account.id, Network::Bitcoin, &"x".repeat(65)).is_err());
			let mut reopened = open(&root, &account).await.unwrap();
			assert_ne!(reopened.address().await.unwrap().to_string(), first, "receive index must survive reopen");
			assert!(read_account(&root, &account.id, Network::Regtest).is_err());
			saved.push((account.id, first));
		}
		assert_ne!(saved[0], saved[1]);
		for id in ["../db.sqlite", "hot", "", &"A".repeat(64)] { assert!(account_dir(&root, id).is_err()); }
		std::fs::remove_dir_all(root).unwrap();
	}
	#[test]
	fn stale_or_other_wallet_responses_cannot_use_a_signing_request() {
		let fixture = &fixtures()[0];
		let mut psbt = Psbt::deserialize(&STANDARD.decode(fixture["original"].as_str().unwrap()).unwrap()).unwrap();
		qr::prepare(&mut psbt).unwrap();
		let id = psbt.unsigned_tx.compute_txid().to_string();
		let mut pending = Pending { psbt, signed: None, created: Instant::now() };
		assert!(check_request(&pending, &id).is_ok());
		assert!(check_request(&pending, &"0".repeat(64)).is_err());
		pending.created -= Duration::from_secs(1801);
		assert!(check_request(&pending, &id).is_err());
		let mut accounts = Accounts::default();
		accounts.pending.insert(PathBuf::from("wallet-a"), pending);
		assert!(!accounts.pending.contains_key(Path::new("wallet-b")));
	}
}
