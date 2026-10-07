use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context};
use base64::{engine::general_purpose::STANDARD, Engine};
use bitcoin::{Amount, Network};
use serde_json::{json, Value};

use bark::{Config, OpenWalletArgs, Wallet, WalletSeed};
use bark::lock_manager::{LockManager, memory::MemoryLockManager};
use bark::onchain::{OnchainWallet, OnchainWalletTrait};
use bark::payment_request::PaymentInitOutput;
use bark::persist::{BarkPersister, sqlite::SqliteClient};

pub struct Session {
	offer_task: Option<tokio::task::JoinHandle<()>>,
	receive_task: Option<tokio::task::JoinHandle<()>>,
	runtime: tokio::runtime::Runtime,
	dir: PathBuf,
	db: Arc<SqliteClient>,
	onchain: Arc<tokio::sync::RwLock<OnchainWallet>>,
	wallet: Option<Wallet>,
	ark_wallet: Option<Wallet>,
	// Retained independently of the async wallet for its whole lifetime.
	_lock: Box<dyn LockManager>,
	fingerprint: String,
	network: Network,
	quote: Option<(String, u64, u64, Instant)>,
	onchain_quote: Option<(String, u64, bitcoin::Psbt, Instant)>,
	board_quote: Option<(u64, u64, u64, bitcoin::Psbt, bitcoin::secp256k1::Keypair, bitcoin_ext::BlockHeight, Instant)>,
}

impl Drop for Session {
	fn drop(&mut self) {
		if let Some(task) = self.offer_task.take() { task.abort(); }
		if let Some(task) = self.receive_task.take() { task.abort(); }
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn electrum_ark_admission_requires_complete_safe_policy_and_package_relay() {
		let good = json!({"features": {"broadcast_package": true}, "policy": {
			"minrelaytxfee": 0.00001000, "mempoolminfee": 0.00001000, "dustrelayfee": 0.00003000,
		}});
		assert!(bark::electrum::validate_ark_capabilities(&good).is_ok());
		for field in ["minrelaytxfee", "mempoolminfee", "dustrelayfee"] {
			let mut missing = good.clone(); missing["policy"].as_object_mut().unwrap().remove(field);
			assert!(bark::electrum::validate_ark_capabilities(&missing).is_err());
			for bad in [json!(-1), json!(0.1), json!("0.000001"), Value::Null] {
				let mut policy = good.clone(); policy["policy"][field] = bad;
				assert!(bark::electrum::validate_ark_capabilities(&policy).is_err());
			}
		}
		let mut unsupported = good.clone(); unsupported["features"] = json!({});
		assert!(bark::electrum::validate_ark_capabilities(&unsupported).is_err());
	}

	#[test]
	fn electrum_package_errors_preserve_recovery_classification() {
		use bark::chain::{parse_electrum_package_result, BroadcastError};
		let parent: bitcoin::Txid = "11".repeat(32).parse().unwrap();
		let child: bitcoin::Txid = "22".repeat(32).parse().unwrap();
		let order = [parent, child];
		assert!(parse_electrum_package_result(&json!({"success": true}), &order).is_ok());
		assert!(parse_electrum_package_result(&json!({}), &order).is_err());
		let rejected = json!({"success": false, "errors": [
			{"txid": child, "error": "bad-txns-inputs-missingorspent"},
			{"txid": parent, "error": "insufficient fee, rejecting replacement"},
		]});
		assert_eq!(parse_electrum_package_result(&rejected, &order), Err(BroadcastError::InsufficientReplacementFee));
		assert!(parse_electrum_package_result(&json!({"success": true, "errors": [{}]}), &order).is_err());
	}

	#[test]
	fn mobile_seed_import_checks_length_checksum_and_derivation() {
		let mut state = None;
		let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
		let result = dispatch(&mut state, json!({"op": "seed_derive", "phrase": phrase}), [0; 64]).unwrap();
		let seed = STANDARD.decode(result["seed"].as_str().unwrap()).unwrap();
		let expected = "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4";
		assert_eq!(seed.iter().map(|b| format!("{b:02x}")).collect::<String>(), expected);
		let generated = dispatch(&mut state, json!({"op": "seed_generate"}), [0; 64]).unwrap();
		assert_eq!(generated["phrase"].as_str().unwrap().split_whitespace().count(), 24);
		assert!(dispatch(&mut state, json!({"op": "seed_derive", "phrase": generated["phrase"]}), [0; 64]).is_ok());
		assert!(dispatch(&mut state, json!({"op": "seed_derive", "phrase": vec!["abandon"; 12].join(" ")}), [0; 64]).is_err());
		let fifteen = bip39::Mnemonic::from_entropy(&[0; 20]).unwrap();
		assert!(dispatch(&mut state, json!({"op": "seed_derive", "phrase": fifteen.to_string()}), [0; 64]).is_err());
	}

	#[test]
	fn mobile_persistence_and_complete_backup_roundtrip() {
		let base = std::env::temp_dir().join(format!("paperclip-mobile-{}-{}", std::process::id(),
			std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
		std::fs::create_dir(&base).unwrap();
		let original = base.join("original");
		let restored = base.join("restored");
		let seed = [42; 64];
		let mut state = None;
		let create = json!({"op": "create", "network": "xbt-regtest", "directory": original});
		dispatch(&mut state, create.clone(), seed).unwrap();
		assert!(dispatch(&mut state, json!({"op": "chain_health"}), seed).is_err());
		let overview = dispatch(&mut state, json!({"op": "overview_onchain"}), seed).unwrap();
		assert_eq!(overview["confirmed_sat"], 0);
		assert_eq!(overview["unconfirmed_sat"], 0);
		assert_eq!(overview["immature_sat"], 0);
		assert_eq!(overview["transactions"], json!([]));
		let first = dispatch(&mut state, json!({"op": "address_onchain"}), seed).unwrap();
		assert!(first["address"].as_str().unwrap().starts_with("bcrt1"));
		let proof = dispatch(&mut state, json!({"op": "sign_message_onchain", "address": first["address"], "message": "Exact message\n"}), seed).unwrap();
		let address = first["address"].as_str().unwrap().parse::<bitcoin::Address<_>>().unwrap().require_network(Network::Regtest).unwrap();
		assert!(bark::onchain::message::verify_onchain_message(&address, "Exact message\n", proof["signature"].as_str().unwrap()).unwrap());
		assert!(!bark::onchain::message::verify_onchain_message(&address, "Exact message", proof["signature"].as_str().unwrap()).unwrap());
		assert!(dispatch(&mut state, json!({"op": "sign_message_onchain", "address": first["address"], "message": "x".repeat(4097)}), seed).is_err());
		let page = dispatch(&mut state, json!({"op": "addresses_onchain"}), seed).unwrap();
		assert_eq!(page["addresses"][0]["address"], first["address"]);
		assert_eq!(page["addresses"][0]["revealed"], true);
		assert_eq!(page["addresses"][1]["revealed"], false);
		assert_eq!(page["has_more"], true);
		let last_page = dispatch(&mut state, json!({"op": "addresses_onchain", "start": 20}), seed).unwrap();
		assert_eq!(last_page["addresses"].as_array().unwrap().len(), 1);
		assert_eq!(last_page["has_more"], false);
		assert!(dispatch(&mut state, json!({"op": "addresses_onchain", "start": 21}), seed).is_err());
		assert!(dispatch(&mut state, json!({"op": "addresses_onchain", "start": 2147483648u64}), seed).is_err());
		let backup = dispatch(&mut state, json!({"op": "backup"}), seed).unwrap();
		dispatch(&mut state, json!({"op": "close"}), seed).unwrap();
		assert!(dispatch(&mut state, create, seed).is_err());
		let open = json!({"op": "open", "network": "xbt-regtest", "directory": original});
		assert!(dispatch(&mut state, open.clone(), [43; 64]).is_err());
		dispatch(&mut state, open, seed).unwrap();
		let second = dispatch(&mut state, json!({"op": "address_onchain"}), seed).unwrap();
		assert_ne!(first, second);
		assert_eq!(page["addresses"][1]["address"], second["address"]);
		let mut other = None;
		let restore = json!({"op": "restore", "network": "xbt-regtest", "directory": restored, "database": backup["database"]});
		dispatch(&mut other, restore.clone(), seed).unwrap();
		assert!(dispatch(&mut other, restore, seed).is_err());
		dispatch(&mut other, json!({"op": "open", "network": "xbt-regtest", "directory": restored}), seed).unwrap();
		assert_eq!(dispatch(&mut other, json!({"op": "address_onchain"}), seed).unwrap(), second);
		assert!(dispatch(&mut state, json!({"op": "send"}), seed).is_err());
		drop(state); drop(other);
		std::fs::remove_dir_all(base).unwrap();
	}
}

fn text<'a>(v: &'a Value, key: &str) -> anyhow::Result<&'a str> {
	v[key].as_str().with_context(|| format!("missing {key}"))
}

pub fn dispatch(state: &mut Option<Session>, request: Value, seed: [u8; 64]) -> anyhow::Result<Value> {
	let op = text(&request, "op")?;
	if op == "seed_generate" {
		let phrase = bip39::Mnemonic::generate(24)?;
		return Ok(json!({"phrase": phrase.to_string()}));
	}
	if op == "seed_derive" {
		let phrase = bip39::Mnemonic::parse(text(&request, "phrase")?)?;
		ensure!([12, 24].contains(&phrase.word_count()), "use a 12 or 24 word seed phrase");
		return Ok(json!({"seed": STANDARD.encode(phrase.to_seed(""))}));
	}
	let requested_network = || -> anyhow::Result<Network> {
		match text(&request, "network")? {
			"xbt-mainnet" => Ok(Network::Bitcoin),
			"xbt-regtest" => Ok(Network::Regtest),
			_ => bail!("unsupported XBT network"),
		}
	};
	if op == "close" { *state = None; return Ok(json!({})); }
	if op == "restore" {
		ensure!(state.is_none(), "restore requires an empty session");
		let network = requested_network()?;
		let dir = PathBuf::from(text(&request, "directory")?);
		ensure!(dir.is_absolute() && !dir.exists(), "restore destination must not exist");
		let data = STANDARD.decode(text(&request, "database")?)?;
		ensure!(data.len() < 32 * 1024 * 1024, "backup too large");
		let staging = dir.with_extension("restore-staging");
		std::fs::create_dir(&staging)?;
		#[cfg(unix)] {
			use std::os::unix::fs::PermissionsExt;
			std::fs::set_permissions(&staging, std::fs::Permissions::from_mode(0o700))?;
		}
		let dbpath = staging.join("db.sqlite");
		std::fs::write(&dbpath, data)?;
		let conn = rusqlite::Connection::open(&dbpath)?;
		let integrity: String = conn.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
		ensure!(integrity == "ok", "damaged recovery database");
		drop(conn);
		let db = Arc::new(SqliteClient::open(&dbpath)?);
		let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
		runtime.block_on(async {
			let properties = db.read_properties().await?.context("missing recovery properties")?;
			ensure!(properties.network == network && properties.fingerprint == WalletSeed::new_from_seed(network, &seed).fingerprint(),
				"backup key or network mismatch");
			OnchainWallet::load_or_create(network, seed, db.clone()).await?;
			anyhow::Ok(())
		})?;
		drop(db);
		std::fs::File::open(&dbpath)?.sync_all()?;
		std::fs::rename(staging, dir)?;
		return Ok(json!({"restored": true}));
	}
	if op == "create" || op == "open" {
		ensure!(state.is_none(), "close the active wallet before opening another");
		let network = requested_network()?;
		let dir = PathBuf::from(text(&request, "directory")?);
		ensure!(dir.is_absolute(), "wallet path must be absolute");
		let dbpath = dir.join("db.sqlite");
		if op == "create" { ensure!(!dbpath.exists(), "wallet already exists; reopen it"); }
		else { ensure!(dbpath.is_file(), "wallet database is missing; restore a backup"); }
		std::fs::create_dir_all(&dir)?;
		#[cfg(unix)] {
			use std::os::unix::fs::PermissionsExt;
			std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
		}
		let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()?;
		let wallet_seed = WalletSeed::new_from_seed(network, &seed);
		let fingerprint = wallet_seed.fingerprint();
		let lock = bark::lock_manager::platform_default(Some(&dir), Some(fingerprint))?;
		let db = Arc::new(SqliteClient::open(&dbpath)?);
		#[cfg(unix)] {
			use std::os::unix::fs::PermissionsExt;
			std::fs::set_permissions(&dbpath, std::fs::Permissions::from_mode(0o600))?;
		}
		let onchain = runtime.block_on(async {
			if op == "create" {
				let mut config = Config::network_default(network);
				config.server_address = "http://127.0.0.1:1".into();
				Wallet::create(network, &wallet_seed, &config, &*db, &*lock, true).await?;
			}
			let properties = db.read_properties().await?.context("wallet not initialized")?;
			ensure!(properties.network == network && properties.fingerprint == fingerprint,
				"recovery key or network does not match the wallet");
			OnchainWallet::load_or_create(network, seed, db.clone()).await
		})?;
		*state = Some(Session { offer_task: None, receive_task: None, runtime, dir, db, onchain: Arc::new(tokio::sync::RwLock::new(onchain)),
			wallet: None, ark_wallet: None, _lock: lock, fingerprint: fingerprint.to_string(), network, quote: None, onchain_quote: None, board_quote: None });
		return Ok(json!({"fingerprint": fingerprint.to_string()}));
	}
	let session = state.as_mut().context("open a wallet first")?;
	ensure!(WalletSeed::new_from_seed(session.network, &seed).fingerprint().to_string() == session.fingerprint,
		"wallet key mismatch");
	if op == "backup" {
		let path = session.dir.join("snapshot.sqlite");
		ensure!(!path.exists(), "a previous snapshot needs recovery before export");
		let conn = rusqlite::Connection::open(session.dir.join("db.sqlite"))?;
		conn.execute("VACUUM INTO ?1", [path.to_str().context("invalid path")?])?;
		let result = (|| {
			ensure!(std::fs::metadata(&path)?.len() < 32 * 1024 * 1024, "backup exceeds mobile size limit");
			Ok(json!({"database": STANDARD.encode(std::fs::read(&path)?), "fingerprint": session.fingerprint}))
		})();
		std::fs::remove_file(path)?;
		return result;
	}
	let network = session.network;
	let Session { runtime, wallet, ark_wallet, db, onchain, quote, onchain_quote, board_quote, offer_task, receive_task, .. } = session;
	runtime.block_on(async {
		if op == "sign_message_onchain" {
			let address = text(&request, "address")?.parse::<bitcoin::Address<_>>()?.require_network(network)?;
			let signature = onchain.read().await.sign_onchain_message(&address, text(&request, "message")?)?;
			return Ok(json!({"signature": signature, "format": "BIP322-simple"}));
		}
		if op == "overview_onchain" {
			let chain = onchain.read().await;
			let balance = chain.balance();
			return Ok(json!({"confirmed_sat": balance.confirmed.to_sat(),
				"unconfirmed_sat": (balance.trusted_pending + balance.untrusted_pending).to_sat(),
				"immature_sat": balance.immature.to_sat(), "total_sat": balance.total().to_sat(),
				"transactions": chain.list_transaction_infos()?.iter().map(|tx| json!({
					"txid": tx.txid.to_string(), "change_sat": tx.balance_change.to_sat(),
					"confirmed": tx.confirmation.is_some()
				})).collect::<Vec<_>>() }));
		}
		if op == "addresses_onchain" {
			let start = request["start"].as_u64().unwrap_or(0);
			ensure!(start < 0x80000000, "invalid address index");
			let (entries, has_more) = onchain.read().await.address_page(start as u32)?;
			return Ok(json!({"shared_change_branch": true, "has_more": has_more, "addresses": entries.into_iter().map(|(index, address, revealed)|
				json!({"index": index, "address": address, "revealed": revealed})).collect::<Vec<_>>()}));
		}
		if op == "address_onchain" {
			return Ok(json!({"address": OnchainWalletTrait::address(&mut *onchain.write().await).await?.to_string()}));
		}
		if op == "connect" {
			if let Some(task) = offer_task.take() { task.abort(); let _ = task.await; }
			if let Some(task) = receive_task.take() { task.abort(); let _ = task.await; }
			*quote = None;
			*onchain_quote = None;
			*board_quote = None;
			*wallet = None;
			*ark_wallet = None;
			let config: Config = serde_json::from_value(request["config"].clone())?;
			*wallet = Some(Wallet::open(network, WalletSeed::new_from_seed(network, &seed), config,
				OpenWalletArgs { persister: Some(db.clone()), onchain: Some(onchain.clone()),
					lock_manager: Some(Box::new(MemoryLockManager::new())), run_daemon: false,
					create_if_not_exists: false, ..Default::default() }).await?);
			if !request["ark_config"].is_null() {
				let config: Config = serde_json::from_value(request["ark_config"].clone())?;
				*ark_wallet = Some(Wallet::open(network, WalletSeed::new_from_seed(network, &seed), config,
					OpenWalletArgs { persister: Some(db.clone()), onchain: Some(onchain.clone()),
						lock_manager: Some(Box::new(MemoryLockManager::new())), run_daemon: false,
						create_if_not_exists: false, ..Default::default() }).await?);
			}
			return Ok(json!({"connected": true}));
		}
		if op == "config_template" { return Ok(serde_json::to_value(Config::network_default(network))?); }
		let chain_wallet = wallet.as_ref().context("connect to a backend first")?;
		let w = if matches!(op, "chain_health" | "sync_onchain" | "quote_onchain" | "send_onchain" | "activity") {
			chain_wallet
		} else { ark_wallet.as_ref().unwrap_or(chain_wallet) };
		if op == "receive_listen" {
			if let Some(task) = offer_task.take() { task.abort(); let _ = task.await; }
			if let Some(task) = receive_task.take() { task.abort(); let _ = task.await; }
			if request["enabled"] == true {
				let offers = w.clone();
				*offer_task = Some(tokio::spawn(async move {
					loop {
						let _ = offers.serve_lightning_offer_requests().await;
						tokio::time::sleep(Duration::from_secs(5)).await;
					}
				}));
				let receives = w.clone();
				*receive_task = Some(tokio::spawn(async move {
					loop {
						let _ = receives.sync_pending_lightning_receives().await;
						let _ = receives.try_claim_all_lightning_receives(false).await;
						tokio::time::sleep(Duration::from_secs(5)).await;
					}
				}));
			}
			return Ok(json!({"listening_requested": request["enabled"] == true}));
		}
		match op {
			"balance_cached" => {
				let balance = w.balance().await?;
				Ok(json!({"ark_sat": balance.spendable.to_sat(), "pending_sat": balance.pending().to_sat()}))
			},
			"ark_backend_check" => { w.chain().require_funded_policy().await?; Ok(json!({"compatible": true})) },
			"check_payment" => {
				use bark::actions::lightning::pay::LightningSendState;
				let state = w.check_lightning_payment(text(&request, "payment_hash")?.parse()?, false).await?;
				Ok(json!({"state": match state {
					LightningSendState::Unknown => "unknown", LightningSendState::InProgress(_) => "pending",
					LightningSendState::Paid(_) => "paid",
				}}))
			},
			"activity" => Ok(json!({"movements": db.get_all_movements().await?,
				"onchain": onchain.read().await.list_transaction_infos()?.iter().map(|tx| json!({
					"txid": tx.txid.to_string(), "change_sat": tx.balance_change.to_sat(),
					"confirmed": tx.confirmation.is_some()
				})).collect::<Vec<_>>() })),
			"sync" | "sync_ark" => {
				w.chain().invalidate_caches().await;
				w.refresh_server().await.context("connecting to Ark server")?;
				w.chain().update_fee_rates(w.config().fallback_fee_rate).await.context("reading chain backend fee rates")?;
				if op == "sync" { chain_wallet.sync_onchain().await.context("synchronizing on-chain backend")?; }
				w.sync_pending_rounds().await?;
				w.sync_pending_arkoor_sends().await?;
				w.sync_pending_lightning_send_vtxos().await?;
				w.sync_pending_lightning_receives().await?;
				let receive_warning = w.try_claim_all_lightning_receives(false).await.err().map(|error| format!("{error:#}"));
				w.sync_pending_boards().await?;
				w.sync_pending_offboards().await?;
				w.sync_mailbox().await?;
				let balance = w.balance().await?;
				let tip = w.chain().tip().await?;
				let vtxos = w.vtxos().await?;
				Ok(json!({"receive_warning": receive_warning, "tip": tip, "ark_sat": balance.spendable.to_sat(), "pending_sat": balance.pending().to_sat(),
					"onchain_sat": onchain.read().await.balance().total().to_sat(),
					"vtxos": vtxos.iter().map(|v| json!({"id": v.id().to_string(), "expiryHeight": v.expiry_height(),
						"spendable": v.state.kind() == bark::vtxo::VtxoStateKind::Spendable})).collect::<Vec<_>>() }))
			},
			"chain_health" => {
				// Force a live backend read; cached balances must not imply connectivity.
				chain_wallet.chain().invalidate_caches().await;
				let tip = chain_wallet.chain().tip().await?;
				Ok(json!({"connected": true, "tip": tip}))
			},
			"sync_onchain" => {
				w.chain().invalidate_caches().await;
				chain_wallet.sync_onchain().await.context("synchronizing on-chain backend")?;
				Ok(json!({"onchain_sat": onchain.read().await.balance().total().to_sat(), "tip": w.chain().tip().await?}))
			},
			"quote_board" => {
				*board_quote = None;
				let amount = request["amount_sat"].as_u64().context("amount required")?;
				ensure!(amount > 0, "amount must be positive");
				w.chain().require_funded_policy().await?;
				w.chain().update_fee_rates(w.config().fallback_fee_rate).await.context("reading chain backend fee rates")?;
				let estimate = w.estimate_board_offchain_fee(Amount::from_sat(amount)).await?;
				let reserve = estimate.fee.max(ark::exit_policy::paperclip_funding().anchor())
					.checked_add(ark::exit_policy::paperclip_funding().miner_fee()).context("reserve overflow")?.to_sat();
				let net = amount.checked_sub(reserve).context("board amount below recovery reserve")?;
				let (key, _) = w.derive_store_next_keypair().await?;
				let (address, expiry) = w.board_funding_address(&key).await?;
				let psbt = onchain.write().await.prepare_tx(&[(address, Amount::from_sat(amount))], w.chain().fee_rates().await.regular).await?;
				let total = amount.checked_add(psbt.fee()?.to_sat()).context("amount overflow")?;
				*board_quote = Some((amount, total, reserve, psbt, key, expiry, Instant::now()));
				Ok(json!({"total_sat": total, "net_sat": net, "reserve_sat": reserve, "network_fee_sat": total - amount,
					"board_amount_sat": amount, "boarding_fee_sat": estimate.fee.to_sat(),
					"recovery_anchor_sat": estimate.fee.max(ark::exit_policy::paperclip_funding().anchor()).to_sat(),
					"recovery_miner_fee_sat": ark::exit_policy::paperclip_funding().miner_fee().to_sat()}))
			},
			"board" => {
				let (amount, total, reserve, psbt, key, expiry, time) = board_quote.take().context("review a board first")?;
				ensure!(time.elapsed() < Duration::from_secs(60), "board quote expired");
				ensure!(request["amount_sat"].as_u64() == Some(amount) && request["total_sat"].as_u64() == Some(total), "board changed");
				let current = w.estimate_board_offchain_fee(Amount::from_sat(amount)).await?;
				ensure!(current.fee.max(ark::exit_policy::paperclip_funding().anchor()).checked_add(ark::exit_policy::paperclip_funding().miner_fee()).context("reserve overflow")?.to_sat() == reserve, "board fee changed");
				let signed = {
					let mut wallet = onchain.write().await;
					let unspent: std::collections::HashSet<_> = wallet.list_unspent().iter().map(|u| u.outpoint).collect();
					ensure!(psbt.unsigned_tx.input.iter().all(|i| unspent.contains(&i.previous_output)), "inputs changed; review again");
					wallet.finish_psbt(psbt).await?
				};
				let board = w.board_psbt(signed, key, expiry).await?;
				Ok(json!({"state": "pending", "amount_sat": board.amount.to_sat(), "txid": board.funding_tx.compute_txid().to_string()}))
			},
			"offer_create" => {
				let description = text(&request, "description")?;
				ensure!(description.len() <= 256, "description too long");
				let offer = w.create_lightning_offer(description.into(), request["amount_sat"].as_u64()).await?;
				Ok(json!({"offer": offer.offer, "active": offer.active, "amount_sat": offer.amount_sat, "description": offer.description}))
			},
			"offer_status" => Ok(match w.lightning_offer().await? {
				Some(offer) => json!({"offer": offer.offer, "active": offer.active, "amount_sat": offer.amount_sat, "description": offer.description}),
				None => json!({"active": false}),
			}),
			"offer_disable" => { w.disable_lightning_offer().await?; Ok(json!({"active": false})) },
			"receive_status" | "receive_claim" => {
				use bark::actions::lightning::receive::{LightningReceiveState, Progress};
				let hash = text(&request, "payment_hash")?.parse()?;
				let state = if op == "receive_claim" {
					w.try_claim_lightning_receive(hash, false).await?
				} else { w.lightning_receive_state(hash).await? };
				Ok(json!({"state": match state {
					LightningReceiveState::Settled(_) => "settled",
					LightningReceiveState::InProgress(recv) => match recv.progress {
						Progress::AwaitingPayment => "awaiting_payment",
						Progress::HtlcsReady(_) => "ready_to_claim",
						Progress::PreimageRevealed(_) => "claim_pending",
						Progress::Delivering(_) => "delivery_pending",
					},
				}}))
			},
			"receive_pending" => Ok(json!({"receives": w.pending_lightning_receives().await?.iter().map(|r| json!({
				"payment_hash": r.payment_hash.to_string(), "invoice": r.invoice.to_string()
			})).collect::<Vec<_>>()})),
			"receive_lightning" => {
				let amount = request["amount_sat"].as_u64().context("amount required")?;
				ensure!(amount > 0, "amount must be positive");
				let invoice = w.bolt11_invoice(Amount::from_sat(amount), Some("Paperclip wallet".into()), None).await?;
				Ok(json!({"invoice": invoice.to_string(), "payment_hash": invoice.payment_hash().to_string()}))
			},
			"exit_status" => Ok(json!({"pending": w.exit_mgr().has_pending_exits().await,
				"claimable_height": w.exit_mgr().all_claimable_at_height().await,
				"claimable_count": w.exit_mgr().list_claimable().await.len(),
				"exits": w.exit_mgr().get_exit_vtxo_ids().await.iter().map(ToString::to_string).collect::<Vec<_>>()})),
			"exit_start" => {
				ensure!(request["confirmed"] == true, "confirm emergency exit first");
				w.exit_mgr().start_exit_for_entire_wallet().await?;
				Ok(json!({"state": "registered"}))
			},
			"exit_progress" => {
				chain_wallet.sync_onchain().await.context("synchronizing on-chain backend")?;
				w.exit_mgr().progress_exits_with_cpfp(w, None).await?;
				Ok(json!({"pending": w.exit_mgr().has_pending_exits().await,
					"claimable_height": w.exit_mgr().all_claimable_at_height().await}))
			},
			"exit_claim" => {
				ensure!(request["confirmed"] == true, "confirm exit claim first");
				let address = text(&request, "destination")?.parse::<bitcoin::Address<_>>()?.require_network(network)?;
				let claimable = w.exit_mgr().list_claimable().await;
				ensure!(!claimable.is_empty(), "no claimable exits");
				let tx = w.exit_mgr().drain_exits(&claimable, w, address, None).await?.extract_tx()?;
				onchain.write().await.register_tx(&tx).await?;
				let submitted = w.chain().broadcast_tx(&tx).await.is_ok();
				Ok(json!({"state": if submitted { "submitted" } else { "pending_broadcast" }, "txid": tx.compute_txid().to_string()}))
			},
			"recover" => {
				let balance = onchain.write().await.initial_wallet_scan(chain_wallet.chain(), None).await?;
				match w.recover_from_mailbox().await {
					Ok(report) => Ok(json!({"state": "recovered", "onchain_sat": balance.to_sat(), "report": format!("{report:?}")})),
					Err(_) => Ok(json!({"state": "partial", "onchain_sat": balance.to_sat(),
						"report": "On-chain scan completed. Ark mailbox recovery is unavailable; retry with the Ark server online or restore a full backup."})),
				}
			},
			"address_ark" => Ok(json!({"address": w.new_address().await?.to_string()})),
			"refresh" => {
				w.sync_pending_rounds().await?;
				let scheduled = w.maybe_schedule_maintenance_refresh_delegated().await?.is_some();
				Ok(json!({"scheduled": scheduled}))
			},
			"quote_onchain" => {
				*onchain_quote = None;
				let destination = text(&request, "destination")?;
				let address = destination.parse::<bitcoin::Address<_>>()?.require_network(network)?;
				let amount = request["amount_sat"].as_u64().context("amount required")?;
				ensure!(amount > 0, "amount must be positive");
				w.chain().update_fee_rates(w.config().fallback_fee_rate).await.context("reading chain backend fee rates")?;
				let rate = w.chain().fee_rates().await.regular;
				let psbt = onchain.write().await.prepare_tx(&[(address, Amount::from_sat(amount))], rate).await?;
				let fee = psbt.fee()?.to_sat();
				*onchain_quote = Some((destination.into(), amount, psbt, Instant::now()));
				Ok(json!({"amount_sat": amount, "fee_sat": fee, "total_sat": amount.checked_add(fee).context("amount overflow")?}))
			},
			"send_onchain" => {
				let (destination, amount, psbt, time) = onchain_quote.take().context("review a new on-chain quote")?;
				ensure!(time.elapsed() < Duration::from_secs(60), "quote expired");
				ensure!(text(&request, "destination")? == destination && request["amount_sat"].as_u64() == Some(amount)
					&& request["total_sat"].as_u64() == amount.checked_add(psbt.fee()?.to_sat()), "payment changed");
				let mut onchain = onchain.write().await;
				let unspent: std::collections::HashSet<_> = onchain.list_unspent().iter().map(|u| u.outpoint).collect();
				ensure!(psbt.unsigned_tx.input.iter().all(|input| unspent.contains(&input.previous_output)), "inputs changed; review a new quote");
				let tx = onchain.finish_psbt(psbt).await?.extract_tx()?;
				let txid = tx.compute_txid();
				let broadcast = w.chain().broadcast_tx(&tx).await.is_ok();
				Ok(json!({"state": if broadcast {"submitted"} else {"pending_broadcast"}, "txid": txid.to_string()}))
			},
			"inspect_payment" => {
				let payment = w.parse_payment_request(text(&request, "destination")?).await?;
				ensure!(payment.default_option().is_some(), "invalid payment destination");
				Ok(json!({"amount_sat": payment.amount.map(|a| a.to_sat())}))
			},
			"quote" => {
				*quote = None;
				let destination = text(&request, "destination")?;
				let payment = w.parse_payment_request(destination).await?;
				let amount = request["amount_sat"].as_u64().map(Amount::from_sat).or(payment.amount).context("amount required")?;
				ensure!(amount > Amount::ZERO, "amount must be positive");
				if let Some(fixed) = payment.amount { ensure!(fixed == amount, "invoice amount mismatch"); }
				let option = payment.default_option().context("invalid payment destination")?;
				let estimate = w.estimate_payment_fee(option, amount).await?;
				*quote = Some((destination.into(), amount.to_sat(), estimate.gross_amount.to_sat(), Instant::now()));
				Ok(json!({"amount_sat": amount.to_sat(), "total_sat": estimate.gross_amount.to_sat(), "fee_sat": estimate.fee.to_sat()}))
			},
			"send" => {
				let (destination, amount, total, time) = quote.take().context("review a new quote before sending")?;
				ensure!(time.elapsed() < Duration::from_secs(60), "quote expired");
				ensure!(text(&request, "destination")? == destination && request["amount_sat"].as_u64() == Some(amount)
					&& request["total_sat"].as_u64() == Some(total), "payment changed; review a new quote");
				// Nothing has been submitted during this preflight. Return a distinct
				// outcome so the UI can safely allow a new review after rejection.
				let preflight = async {
					let payment = w.parse_payment_request(&destination).await?;
					let option = payment.default_option().context("invalid destination")?;
					let estimate = w.estimate_payment_fee(option, Amount::from_sat(amount)).await?;
					ensure!(estimate.gross_amount.to_sat() == total, "cost changed; review a new quote");
					Ok::<_, anyhow::Error>(option.method.clone())
				}.await;
				let method = match preflight {
					Ok(method) => method,
					Err(error) => return Ok(json!({"state": "not_sent", "reason": format!("{error:#}")})),
				};
				let result = w.send_payment(&method, Some(Amount::from_sat(amount)), None::<&str>, false).await?;
				Ok(match result {
					PaymentInitOutput::Ark => json!({"state": "completed"}),
					PaymentInitOutput::Lightning(invoice) => json!({"state": "pending", "invoice": invoice.to_string(), "payment_hash": invoice.payment_hash().to_string()}),
					PaymentInitOutput::Onchain(txid) => json!({"state": "submitted", "txid": txid.to_string()}),
				})
			},
			_ => bail!("unknown operation"),
		}
	})
}
