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
	runtime: tokio::runtime::Runtime,
	dir: PathBuf,
	db: Arc<SqliteClient>,
	onchain: Arc<tokio::sync::RwLock<OnchainWallet>>,
	wallet: Option<Wallet>,
	// Retained independently of the async wallet for its whole lifetime.
	_lock: Box<dyn LockManager>,
	fingerprint: String,
	quote: Option<(String, u64, u64, Instant)>,
	onchain_quote: Option<(String, u64, bitcoin::Psbt, Instant)>,
}

#[cfg(test)]
mod tests {
	use super::*;

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
		let first = dispatch(&mut state, json!({"op": "address_onchain"}), seed).unwrap();
		assert!(first["address"].as_str().unwrap().starts_with("bcrt1"));
		let backup = dispatch(&mut state, json!({"op": "backup"}), seed).unwrap();
		dispatch(&mut state, json!({"op": "close"}), seed).unwrap();
		assert!(dispatch(&mut state, create, seed).is_err());
		let open = json!({"op": "open", "network": "xbt-regtest", "directory": original});
		assert!(dispatch(&mut state, open.clone(), [43; 64]).is_err());
		dispatch(&mut state, open, seed).unwrap();
		let second = dispatch(&mut state, json!({"op": "address_onchain"}), seed).unwrap();
		assert_ne!(first, second);
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
	if op == "close" { *state = None; return Ok(json!({})); }
	if op == "restore" {
		ensure!(state.is_none() && request["network"] == "xbt-regtest", "restore requires an empty regtest session");
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
			ensure!(properties.network == Network::Regtest && properties.fingerprint == WalletSeed::new_from_seed(Network::Regtest, &seed).fingerprint(),
				"backup key or network mismatch");
			OnchainWallet::load_or_create(Network::Regtest, seed, db.clone()).await?;
			anyhow::Ok(())
		})?;
		drop(db);
		std::fs::File::open(&dbpath)?.sync_all()?;
		std::fs::rename(staging, dir)?;
		return Ok(json!({"restored": true}));
	}
	if op == "create" || op == "open" {
		ensure!(state.is_none(), "close the active wallet before opening another");
		ensure!(request["network"] == "xbt-regtest", "this test build supports regtest only");
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
		let wallet_seed = WalletSeed::new_from_seed(Network::Regtest, &seed);
		let fingerprint = wallet_seed.fingerprint();
		let lock = bark::lock_manager::platform_default(Some(&dir), Some(fingerprint))?;
		let db = Arc::new(SqliteClient::open(&dbpath)?);
		#[cfg(unix)] {
			use std::os::unix::fs::PermissionsExt;
			std::fs::set_permissions(&dbpath, std::fs::Permissions::from_mode(0o600))?;
		}
		let onchain = runtime.block_on(async {
			if op == "create" {
				let mut config = Config::network_default(Network::Regtest);
				config.server_address = "http://127.0.0.1:1".into();
				Wallet::create(Network::Regtest, &wallet_seed, &config, &*db, &*lock, true).await?;
			}
			let properties = db.read_properties().await?.context("wallet not initialized")?;
			ensure!(properties.network == Network::Regtest && properties.fingerprint == fingerprint,
				"recovery key or network does not match the wallet");
			OnchainWallet::load_or_create(Network::Regtest, seed, db.clone()).await
		})?;
		*state = Some(Session { runtime, dir, db, onchain: Arc::new(tokio::sync::RwLock::new(onchain)),
			wallet: None, _lock: lock, fingerprint: fingerprint.to_string(), quote: None, onchain_quote: None });
		return Ok(json!({"fingerprint": fingerprint.to_string()}));
	}
	let session = state.as_mut().context("open a wallet first")?;
	ensure!(WalletSeed::new_from_seed(Network::Regtest, &seed).fingerprint().to_string() == session.fingerprint,
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
	let Session { runtime, wallet, db, onchain, quote, onchain_quote, .. } = session;
	runtime.block_on(async {
		if op == "address_onchain" {
			return Ok(json!({"address": OnchainWalletTrait::address(&mut *onchain.write().await).await?.to_string()}));
		}
		if op == "connect" {
			ensure!(wallet.is_none(), "restart the session to change connections");
			let config: Config = serde_json::from_value(request["config"].clone())?;
			*wallet = Some(Wallet::open(Network::Regtest, WalletSeed::new_from_seed(Network::Regtest, &seed), config,
				OpenWalletArgs { persister: Some(db.clone()), onchain: Some(onchain.clone()),
					lock_manager: Some(Box::new(MemoryLockManager::new())), run_daemon: false,
					create_if_not_exists: false, ..Default::default() }).await?);
			return Ok(json!({"connected": true}));
		}
		if op == "config_template" { return Ok(serde_json::to_value(Config::network_default(Network::Regtest))?); }
		let w = wallet.as_ref().context("connect to the test backend first")?;
		match op {
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
			"sync" => {
				w.chain().invalidate_caches().await;
				w.refresh_server().await?;
				w.chain().update_fee_rates(w.config().fallback_fee_rate).await?;
				w.sync_onchain().await?;
				w.sync_pending_rounds().await?;
				w.sync_pending_arkoor_sends().await?;
				w.sync_pending_lightning_send_vtxos().await?;
				w.sync_pending_boards().await?;
				w.sync_pending_offboards().await?;
				w.sync_mailbox().await?;
				let balance = w.balance().await?;
				let tip = w.chain().tip().await?;
				let vtxos = w.vtxos().await?;
				Ok(json!({"tip": tip, "ark_sat": balance.spendable.to_sat(), "pending_sat": balance.pending().to_sat(),
					"onchain_sat": onchain.read().await.balance().total().to_sat(),
					"vtxos": vtxos.iter().map(|v| json!({"id": v.id().to_string(), "expiryHeight": v.expiry_height(),
						"spendable": v.state.kind() == bark::vtxo::VtxoStateKind::Spendable})).collect::<Vec<_>>() }))
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
				let address = destination.parse::<bitcoin::Address<_>>()?.require_network(Network::Regtest)?;
				let amount = request["amount_sat"].as_u64().context("amount required")?;
				ensure!(amount > 0, "amount must be positive");
				w.chain().update_fee_rates(w.config().fallback_fee_rate).await?;
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
				let payment = w.parse_payment_request(&destination).await?;
				let option = payment.default_option().context("invalid destination")?;
				let estimate = w.estimate_payment_fee(option, Amount::from_sat(amount)).await?;
				ensure!(estimate.gross_amount.to_sat() == total, "cost changed; review a new quote");
				let result = w.send_payment(&option.method, Some(Amount::from_sat(amount)), None::<&str>, false).await?;
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
