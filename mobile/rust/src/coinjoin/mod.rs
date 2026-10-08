//! Experimental Kilojoin v1 account, isolated from ordinary wallet coin selection.
use paperclip_kilojoin::{crypto, protocol, round};
#[cfg(test)]
mod tests;

use anyhow::{Context, ensure};
use bark::{
	Wallet,
	onchain::{OnchainWallet, OnchainWalletTrait},
	persist::sqlite::SqliteClient,
};
use bdk_wallet::KeychainKind;
use bitcoin::{
	Amount, Network, OutPoint, Psbt, Transaction, TxOut,
	bip32::{DerivationPath, Xpriv},
	secp256k1::{Secp256k1, SecretKey},
};
use crypto::{Event, bytes, hex};
use protocol::{Coin, Seat, Terms};
use round::Round;
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::Path, str::FromStr, sync::Arc};

#[derive(Default, Serialize, Deserialize)]
struct State {
	rounds: Vec<Round>,
	labels: BTreeMap<String, String>,
	quote: Option<Quote>,
	pending: Vec<Transaction>,
}
#[derive(Serialize, Deserialize)]
struct Quote {
	id: String,
	psbt: String,
	action: String,
	at: u64,
	amount: u64,
	fee: u64,
	reserve: u64,
	key: Option<u32>,
	expiry: Option<bitcoin_ext::BlockHeight>,
}
pub(crate) fn legacy_account(path: &Path) -> anyhow::Result<bool> {
	let c = rusqlite::Connection::open(path)?;
	let exists: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='named_bdk_account')", [], |r| r.get(0))?;
	if !exists { return Ok(false); }
	Ok(c.query_row("SELECT EXISTS(SELECT 1 FROM named_bdk_account WHERE name='kilojoin-bip84')", [], |r| r.get(0))?)
}
fn now() -> u64 {
	std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.unwrap_or_default()
		.as_secs()
}
fn load(path: &Path) -> anyhow::Result<State> {
	let c = rusqlite::Connection::open(path)?;
	c.execute(
		"CREATE TABLE IF NOT EXISTS paperclip_coinjoin (id INTEGER PRIMARY KEY CHECK(id=1), state TEXT NOT NULL)",
		[],
	)?;
	let saved: Option<String> = c
		.query_row("SELECT state FROM paperclip_coinjoin WHERE id=1", [], |r| {
			r.get(0)
		})
		.optional()?;
	Ok(saved
		.map(|s| serde_json::from_str(&s))
		.transpose()?
		.unwrap_or_default())
}
fn save(path: &Path, s: &State) -> anyhow::Result<()> {
	rusqlite::Connection::open(path)?.execute(
		"INSERT OR REPLACE INTO paperclip_coinjoin VALUES(1,?1)",
		[serde_json::to_string(s)?],
	)?;
	Ok(())
}
fn derive(seed: &[u8; 64], network: Network, path: &str) -> anyhow::Result<SecretKey> {
	Ok(Xpriv::new_master(network, seed)?
		.derive_priv(&Secp256k1::new(), &DerivationPath::from_str(path)?)?
		.private_key)
}
fn coin(
	wallet: &OnchainWallet,
	out: OutPoint,
	seed: &[u8; 64],
	network: Network,
	account: u32,
) -> anyhow::Result<(Coin, String, SecretKey)> {
	let local = wallet
		.list_unspent()
		.into_iter()
		.find(|u| u.outpoint == out)
		.context("coin unavailable")?;
	let branch = if local.keychain == KeychainKind::External {
		0
	} else {
		1
	};
	let path = format!(
		"m/84'/{}'/{account}'/{branch}/{}",
		if network == Network::Bitcoin { 0 } else { 1 },
		local.derivation_index
	);
	let key = derive(seed, network, &path)?;
	let coin = Coin {
		txid: out.txid.to_string(),
		vout: out.vout,
		value: local.txout.value.to_sat(),
		pubkey: bitcoin::secp256k1::PublicKey::from_secret_key(&Secp256k1::new(), &key).to_string(),
	};
	ensure!(
		coin.script()? == local.txout.script_pubkey,
		"coin derivation mismatch"
	);
	Ok((coin, path, key))
}
fn available(s: &State, out: OutPoint) -> bool {
	!s.rounds
		.iter()
		.any(|r| r.locked() && r.mine.coin.name() == out.to_string())
		&& !s
			.pending
			.iter()
			.any(|t| t.input.iter().any(|i| i.previous_output == out))
}

fn sign_single_coin(psbt: &mut Psbt, coin: &Coin, key: &SecretKey) -> anyhow::Result<()> {
	ensure!(
		psbt.inputs.len() == 1
			&& psbt.unsigned_tx.input.len() == 1
			&& psbt.unsigned_tx.input[0].previous_output == coin.outpoint()?,
		"single known input required"
	);
	ensure!(
		coin.key()?.inner == bitcoin::secp256k1::PublicKey::from_secret_key(&Secp256k1::new(), key),
		"coin key mismatch"
	);
	let previous = TxOut {
		value: Amount::from_sat(coin.value),
		script_pubkey: coin.script()?,
	};
	ensure!(
		psbt.inputs[0].witness_utxo.as_ref() == Some(&previous),
		"previous output mismatch"
	);
	if let Some(parent) = &psbt.inputs[0].non_witness_utxo {
		ensure!(
			parent.compute_txid().to_string() == coin.txid
				&& parent.output.get(coin.vout as usize) == Some(&previous),
			"funding transaction mismatch"
		);
	}
	ensure!(
		psbt.inputs[0].sighash_type.is_none_or(|s| s.to_u32() == 0x21)
			&& psbt.inputs[0].final_script_witness.is_none()
			&& psbt.inputs[0].final_script_sig.is_none(),
		"unsupported existing signature"
	);
	let code = previous
		.script_pubkey
		.p2wpkh_script_code()
		.context("P2WPKH input required")?;
	let hash = bitcoin_ext::unified::digest(
		&psbt.unsigned_tx,
		0,
		&[previous.clone()],
		0x21,
		bitcoin_ext::unified::Execution {
			script_type: 1,
			script_code: Some(&code),
			annex: None,
			leaf: None,
		},
	)?;
	let signature = Secp256k1::new().sign_ecdsa_low_r(&hash.into(), key);
	let mut encoded = signature.serialize_der().to_vec();
	encoded.push(0x21);
	psbt.inputs[0].sighash_type = Some(bitcoin::psbt::PsbtSighashType::from_u32(0x21));
	psbt.inputs[0].final_script_witness =
		Some(bitcoin::Witness::from_slice(&[encoded, coin.key()?.to_bytes()]));
	Ok(())
}
fn single_coin_tx(
	wallet: &mut bdk_wallet::Wallet,
	out: OutPoint,
	destination: bitcoin::ScriptBuf,
	amount: Option<u64>,
	rate: bitcoin::FeeRate,
) -> anyhow::Result<Psbt> {
	let mut builder = wallet.build_tx();
	builder.add_utxo(out)?.manually_selected_only().fee_rate(rate);
	if let Some(amount) = amount {
		builder.add_recipient(destination, Amount::from_sat(amount));
	} else {
		builder.drain_wallet().drain_to(destination);
	}
	let psbt = builder.finish()?;
	ensure!(
		psbt.unsigned_tx.input.len() == 1 && psbt.unsigned_tx.input[0].previous_output == out,
		"single coin selection failed"
	);
	Ok(psbt)
}
async fn check(chain: &bark::chain::ChainSource, coin: &Coin) -> anyhow::Result<bool> {
	chain
		.unspent_output(
			coin.outpoint()?,
			&TxOut {
				value: Amount::from_sat(coin.value),
				script_pubkey: coin.script()?,
			},
		)
		.await
}
fn text<'a>(r: &'a Value, k: &str) -> anyhow::Result<&'a str> {
	r[k].as_str().with_context(|| format!("missing {k}"))
}
fn round_mut<'a>(s: &'a mut State, r: &Value) -> anyhow::Result<&'a mut Round> {
	let id = text(r, "id")?;
	s.rounds
		.iter_mut()
		.find(|x| x.terms.id == id)
		.context("round not found")
}
fn summary(s: &State, w: &OnchainWallet) -> Value {
	let coins:Vec<_>=w.list_unspent().iter().map(|c|json!({"outpoint":c.outpoint.to_string(),"amount_sat":c.txout.value.to_sat(),"confirmed":matches!(c.chain_position,bdk_wallet::chain::ChainPosition::Confirmed{..}),"label":s.labels.get(&c.txout.script_pubkey.to_hex_string()).map(String::as_str).unwrap_or("unclassified"),"available":available(s,c.outpoint)})).collect();
	let activity:Vec<_>=w.list_transaction_infos().unwrap_or_default().iter().map(|t|json!({"txid":t.txid.to_string(),"change_sat":t.balance_change.to_sat(),"confirmed":t.confirmation.is_some(),"timestamp":t.timestamp})).collect();
	let rounds:Vec<_>=s.rounds.iter().rev().map(|r| {
		let plan=r.plan().ok();
		json!({"id":r.terms.id,"phase":r.phase,"reason":r.reason,"terms":r.terms,"creator":r.creator,"relay":r.relay,"tor":r.tor,"peers":r.seats.len(),"deadline":r.deadline,"signed":r.signed,"voted":r.voted==r.vote,"txid":r.txid,"input":r.mine.coin.value,"amount_sat":r.terms.denomination,"change_sat":r.mine.change_value,"fee_sat":r.mine.coin.value-r.terms.denomination-r.mine.change_value,"total_fee_sat":plan.as_ref().map(|p|p.fee),"plan_id":plan.as_ref().map(|p|p.tx.compute_txid().to_string()),"mix_script":r.mix,"subscriptions":[crypto::public(&r.join_secret).unwrap_or_default(),r.terms.public_key.clone()],"outbox":r.outbox,"active":!r.terminal(),"can_broadcast":r.signed&&r.signatures.len()==r.round.len()&&r.phase!="confirmed"})
	}).collect();
	json!({"balance_sat":w.inner.balance().total().to_sat(),"coins":coins,"rounds":rounds,"activity":activity,"address":w.peek_address(KeychainKind::External,w.derivation_index(KeychainKind::External).unwrap_or(0)).address.to_string()})
}
pub async fn dispatch(
	dir: &Path,
	seed: [u8; 64],
	network: Network,
	chain_wallet: Option<&Wallet>,
	ark: Option<&Wallet>,
	request: &Value,
) -> anyhow::Result<Value> {
	ensure!(
		network == Network::Bitcoin,
		"Kilojoin relay pools are enabled only for XBT mainnet"
	);
	let op = text(request, "op")?;
	if op == "coinjoin_pool" {
		let e: Event = serde_json::from_value(request["event"].clone())?;
		let t = Terms::event(&e)?;
		ensure!(e.created_at <= now() + 120, "future pool event");
		return Ok(json!({"terms":t,"created_at":e.created_at,"event_id":e.id}));
	}
	let path = dir.join("db.sqlite");
	let mut s = load(&path)?;
	let legacy = legacy_account(&path)?;
	let db = Arc::new(SqliteClient::open(&path)?.with_bdk_namespace(if legacy { "kilojoin-bip84" } else { "kilojoin-bip84-v2" }));
	let mut w = if legacy { OnchainWallet::load_coinjoin(network, seed, db).await? }
		else { OnchainWallet::load_segwit_account(network, seed, db, 1).await? };
	// Revealing the first address is durable, including on an empty account.
	if w.derivation_index(KeychainKind::External).is_none() {
		w.address().await?;
	}
	let time = now();
	match op {
		"coinjoin_status" => {}
		"coinjoin_migrate" => {
			ensure!(legacy, "Coinjoin already uses its separate account");
			ensure!(s.rounds.iter().all(|r| !r.locked()) && s.pending.is_empty(), "Finish and refresh all rounds and transfers before upgrading");
			let mut c = rusqlite::Connection::open(&path)?;
			let tx = c.transaction()?;
			let exists: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM named_bdk_account WHERE name='main-bip84')", [], |r| r.get(0))?;
			ensure!(!exists, "Main SegWit account already exists; do not overwrite it");
			tx.execute("CREATE TABLE IF NOT EXISTS paperclip_coinjoin_legacy (id INTEGER PRIMARY KEY, state TEXT NOT NULL)", [])?;
			tx.execute("INSERT INTO paperclip_coinjoin_legacy VALUES(1,?1)", [serde_json::to_string(&s)?])?;
			tx.execute("UPDATE named_bdk_account SET name='main-bip84' WHERE name='kilojoin-bip84'", [])?;
			tx.execute("DELETE FROM paperclip_coinjoin", [])?;
			tx.commit()?;
			return Ok(json!({"migrated":true}));
		}
		"coinjoin_address" => {
			w.address().await?;
		}
		"coinjoin_sync" | "coinjoin_recover" => {
			let chain = chain_wallet.context("connect a chain backend")?.chain();
			chain.invalidate_caches().await;
			if op == "coinjoin_recover" {
				w.initial_wallet_scan(chain, None).await?;
			} else {
				w.sync(chain).await?;
			}
			for r in &mut s.rounds {
				if let Ok(plan) = r.plan() {
					let txid = plan.tx.compute_txid();
					if chain.tx_confirmed(txid).await?.is_some() {
						r.phase = "confirmed".into();
						r.txid = Some(txid.to_string());
						s.labels.insert(r.mix.clone(), "mixed".into());
					}
				}
				// A conflicting confirmed spend proves the released signature unusable.
				if r.locked()
					&& r.phase != "confirmed"
					&& chain.tx_confirmed(r.mine.coin.outpoint()?.txid).await?.is_some()
					&& chain.outpoint_spent_confirmed(r.mine.coin.outpoint()?).await?
				{
					r.signed = false;
					r.phase = "aborted".into();
					r.reason = "Input spent by a confirmed transaction".into();
				}
			}
			for tx in s.pending.clone() {
				if chain.tx_confirmed(tx.compute_txid()).await?.is_some() {
					s.pending.retain(|p| p.compute_txid() != tx.compute_txid());
				} else {
					let _ = chain.broadcast_tx(&tx).await;
				}
			}
		}
		"coinjoin_create" | "coinjoin_join" => {
			ensure!(
				!s.rounds.iter().any(|r| r.locked()),
				"Finish or reconcile the active round first"
			);
			ensure!(
				s.rounds.len() < 100,
				"Coinjoin history limit reached; export backup before further rounds"
			);
			let creator = op == "coinjoin_create";
			let poolsecret = if creator { Some(crypto::secret()) } else { None };
			let terms = if let Some(secret) = &poolsecret {
				let hours = request["hours"].as_u64().unwrap_or(24);
				ensure!((1..=168).contains(&hours), "duration must be 1–168 hours");
				Terms {
					v: 1,
					network: "blake2b".into(),
					id: hex(&crypto::random(8)),
					public_key: crypto::public(secret)?,
					denomination: request["amount_sat"].as_u64().context("amount required")?,
					fee_rate: request["fee_rate"].as_f64().context("fee rate required")?,
					min_peers: request["min_peers"].as_u64().context("minimum required")? as usize,
					max_peers: request["max_peers"].as_u64().context("maximum required")? as usize,
					private: request["private"].as_bool().unwrap_or(false),
					timeout: time + hours * 3600,
					state: "open".into(),
					peers: 1,
				}
			} else {
				Terms::event(&serde_json::from_value(request["event"].clone())?)?
			};
			terms.validate()?;
			ensure!(
				terms.state == "open" && terms.timeout > time && terms.peers < terms.max_peers,
				"pool is unavailable"
			);
			let relay = text(request, "relay")?;
			ensure!(
				relay.starts_with("wss://") && relay.len() < 2048,
				"secure WebSocket relay required"
			);
			let out: OutPoint = text(request, "outpoint")?.parse()?;
			ensure!(available(&s, out), "coin reserved");
			let chain = chain_wallet.context("connect a chain backend")?.chain();
			w.sync(chain).await?;
			let (coin, path, key) = coin(&w, out, &seed, network, if legacy { 0 } else { 1 })?;
			ensure!(check(chain, &coin).await?, "coin is not unspent");
			let change = protocol::change(coin.value, terms.denomination, terms.fee_rate)?;
			let mix = w.address().await?.script_pubkey().to_hex_string();
			let change_script = if change > 0 {
				w.address().await?.script_pubkey().to_hex_string()
			} else {
				String::new()
			};
			let mut r = Round::new(
				round::RoundConfig {
					terms,
					relay: relay.into(),
					tor: request["tor"].as_bool().unwrap_or(true),
					pool_secret: poolsecret,
					coin,
					coin_path: path,
					mix_script: mix,
					change_script: change_script.clone(),
					password: request["password"].as_str().map(String::from),
				},
				&key,
				time,
			)?;
			r.start(time)?;
			if !change_script.is_empty() {
				s.labels.insert(change_script, "change".into());
			}
			s.rounds.push(r);
		}
		"coinjoin_event" => {
			let e: Event = serde_json::from_value(request["event"].clone())?;
			let r = round_mut(&mut s, request)?;
			// Invalid relay traffic cannot mutate the durable round.
			if let Ok(m) = r.decode(&e) {
				// Reject malformed/replayed requests before performing chain I/O.
				let candidate = (|| -> anyhow::Result<Seat> {
					ensure!(
						r.creator
							&& r.phase == "open" && m["type"] == "join"
							&& !r.seen.contains(&e.id)
							&& !r.joins.contains_key(&e.pubkey),
						"not a new join"
					);
					let seat: Seat = serde_json::from_value(m["seat"].clone())?;
					seat.validate(&r.terms)?;
					ensure!(
						!r.seats.iter().any(|s| s.coin.name() == seat.coin.name()),
						"duplicate coin"
					);
					protocol::verify_proof(
						&seat.coin,
						protocol::ownership(&r.terms.id, &e.pubkey, &seat.coin),
						text(&m, "proof")?,
					)?;
					protocol::verify_proof(
						&seat.coin,
						protocol::change_hash(&r.terms.id, &seat),
						text(&m, "change_sig")?,
					)?;
					Ok(seat)
				})();
				let unspent = match (candidate, chain_wallet) {
					(Ok(seat), Some(chain)) => check(chain.chain(), &seat.coin).await.unwrap_or(false),
					_ => false,
				};
				let mut next = r.clone();
				if next.handle(&e, time, unspent).is_ok() {
					*r = next;
				}
			}
		}
		"coinjoin_ack" => {
			let r = round_mut(&mut s, request)?;
			let id = text(request, "event_id")?;
			if let Some(item) = r.outbox.iter().find(|o| o.event.id == id).cloned() {
				if r.decode(&item.event).is_ok() {
					let mut next = r.clone();
					if next.handle(&item.event, time, false).is_ok() {
						*r = next;
					}
				}
				r.outbox.retain(|o| o.event.id != id);
			}
		}
		"coinjoin_tick" => {
			for r in &mut s.rounds {
				r.tick(time)?;
			}
		}
		"coinjoin_close" => round_mut(&mut s, request)?.request_close(time)?,
		"coinjoin_vote" => {
			round_mut(&mut s, request)?.vote(request["accept"].as_bool().context("vote required")?, time)?
		}
		"coinjoin_leave" => round_mut(&mut s, request)?.leave(time)?,
		"coinjoin_sign" => {
			let r = round_mut(&mut s, request)?;
			let plan = r.plan()?;
			ensure!(
				request["plan_id"] == plan.tx.compute_txid().to_string(),
				"reviewed plan changed"
			);
			let chain = chain_wallet.context("connect a chain backend")?.chain();
			chain.invalidate_caches().await;
			for c in &plan.coins {
				ensure!(
					check(chain, c).await?,
					"a round input is spent or has incorrect value"
				);
			}
			let signature = plan.sign(&r.mine.coin, &derive(&seed, network, &r.path)?)?;
			r.signed_message(signature, time)?;
		}
		"coinjoin_broadcast" => {
			let r = round_mut(&mut s, request)?;
			ensure!(r.signed, "approve your signature first");
			let plan = r.plan()?;
			ensure!(
				r.signatures.len() == plan.coins.len(),
				"waiting for participant signatures"
			);
			let mut tx = plan.tx.clone();
			for (name, sig) in &r.signatures {
				let i = plan.verify(name, sig)?;
				tx.input[i].witness =
					bitcoin::Witness::from_slice(&[bytes(sig)?, bytes(&plan.coins[i].pubkey)?]);
			}
			let chain = chain_wallet.context("connect a chain backend")?.chain();
			chain.invalidate_caches().await;
			if chain.tx_confirmed(tx.compute_txid()).await?.is_some() {
				r.txid = Some(tx.compute_txid().to_string());
				r.phase = "confirmed".into();
				let mixed_script = r.mix.clone();
				s.labels.insert(mixed_script, "mixed".into());
				save(&path, &s)?;
				w.sync(chain).await?;
				return Ok(summary(&s, &w));
			}
			r.txid = Some(tx.compute_txid().to_string());
			r.phase = "broadcast".into();
			r.announce(time)?;
			let mixed_script = r.mix.clone();
			s.labels.insert(mixed_script, "mixed".into());
			save(&path, &s)?;
			w.register_tx(&tx).await?;
			chain_wallet
				.context("connect a chain backend")?
				.chain()
				.broadcast_tx(&tx)
				.await
				.context("Transaction saved; broadcast uncertain. Reconnect to reconcile.")?;
		}
		"coinjoin_quote" => {
			let chain = chain_wallet.context("connect a chain backend")?.chain();
			w.sync(chain).await?;
			chain.update_fee_rates(None).await?;
			let out: OutPoint = text(request, "outpoint")?.parse()?;
			ensure!(available(&s, out), "coin reserved");
			let local = w
				.list_unspent()
				.into_iter()
				.find(|u| u.outpoint == out)
				.context("coin unavailable")?;
			let action = text(request, "action")?;
			ensure!(
				["exact", "withdraw", "board"].contains(&action),
				"invalid transfer"
			);
			let mut key = None;
			let mut expiry = None;
			let destination =
				if action == "board" {
					ensure!(
						s.labels
							.get(&local.txout.script_pubkey.to_hex_string())
							.map(String::as_str) == Some("mixed"),
						"select one mixed coin"
					);
					let ark = ark.context("connect Ark first")?;
					ark.chain().require_funded_policy().await?;
					let (k, i) = ark.derive_store_next_keypair().await?;
					let (a, e) = ark.board_funding_address(&k).await?;
					key = Some(i);
					expiry = Some(e);
					a
				} else if action == "exact" {
					ensure!(
						s.labels
							.get(&local.txout.script_pubkey.to_hex_string())
							.map(String::as_str) != Some("mixed"),
						"prepare exact coins using unmixed funds"
					);
					ensure!(
						request["unmixed_confirmed"] == true,
						"confirm the source coin is unmixed"
					);
					w.address().await?
				} else {
					bitcoin::Address::from_str(text(request, "destination")?)?.require_network(network)?
				};
			let exact = if action == "exact" {
				let amount = request["amount_sat"].as_u64().context("exact amount required")?;
				ensure!((10000..=100100000).contains(&amount), "exact amount out of range");
				Some(amount)
			} else {
				None
			};
			let psbt = single_coin_tx(
				&mut w.inner,
				out,
				destination.script_pubkey(),
				exact,
				chain.fee_rates().await.regular,
			)?;
			w.persist().await?;
			let amount = psbt
				.unsigned_tx
				.output
				.iter()
				.find(|o| o.script_pubkey == destination.script_pubkey())
				.context("missing output")?
				.value
				.to_sat();
			let reserve = if action == "board" {
				let estimate = ark
					.unwrap()
					.estimate_board_offchain_fee(Amount::from_sat(amount))
					.await?;
				estimate
					.fee
					.max(ark::exit_policy::paperclip_funding().anchor())
					.checked_add(ark::exit_policy::paperclip_funding().miner_fee())
					.context("reserve overflow")?
					.to_sat()
			} else {
				0
			};
			ensure!(amount > reserve, "coin too small after recovery funding");
			let q = Quote {
				id: psbt.unsigned_tx.compute_txid().to_string(),
				psbt: hex(&psbt.serialize()),
				action: action.into(),
				at: time,
				amount,
				fee: psbt.fee()?.to_sat(),
				reserve,
				key,
				expiry,
			};
			let result = json!({"quote_id":q.id,"amount_sat":amount,"fee_sat":q.fee,"reserve_sat":reserve,"net_sat":amount-reserve,"input_sat":local.txout.value.to_sat(),"change_sat":local.txout.value.to_sat()-amount-q.fee,"destination":destination.to_string()});
			s.quote = Some(q);
			save(&path, &s)?;
			return Ok(result);
		}
		"coinjoin_transfer" => {
			let q = s.quote.take().context("review a transfer first")?;
			ensure!(
				request["quote_id"] == q.id && time < q.at + 120,
				"quote changed or expired"
			);
			let mut psbt = Psbt::deserialize(&bytes(&q.psbt)?)?;
			let out = psbt.unsigned_tx.input[0].previous_output;
			ensure!(available(&s, out), "coin reserved");
			let chain = chain_wallet.context("connect a chain backend")?.chain();
			w.sync(chain).await?;
			let (coin, _, key) = coin(&w, out, &seed, network, if legacy { 0 } else { 1 })?;
			ensure!(check(chain, &coin).await?, "coin already spent");
			sign_single_coin(&mut psbt, &coin, &key)?;
			let tx = psbt.clone().extract_tx()?;
			if q.action == "board" {
				let ark = ark.context("connect Ark first")?;
				let estimate = ark
					.estimate_board_offchain_fee(Amount::from_sat(q.amount))
					.await?;
				let reserve = estimate
					.fee
					.max(ark::exit_policy::paperclip_funding().anchor())
					.checked_add(ark::exit_policy::paperclip_funding().miner_fee())
					.context("reserve overflow")?
					.to_sat();
				ensure!(reserve == q.reserve, "Ark fee changed; review again");
				// Ark persists its complete recovery path before the funding transaction can relay.
				ark.board_psbt(
					psbt,
					ark.peek_keypair(q.key.context("missing Ark key")?).await?,
					q.expiry.context("missing expiry")?,
				)
				.await?;
			} else {
				for output in &tx.output {
					if w.inner.is_mine(output.script_pubkey.clone()) {
						s.labels.insert(
							output.script_pubkey.to_hex_string(),
							if q.action == "exact" && output.value.to_sat() == q.amount {
								"exact"
							} else {
								"change"
							}
							.into(),
						);
					}
				}
			}
			s.pending.push(tx.clone());
			save(&path, &s)?;
			w.register_tx(&tx).await?;
			if q.action != "board" {
				chain
					.broadcast_tx(&tx)
					.await
					.context("Transaction saved; broadcast uncertain. Check Coinjoin activity.")?;
			}
		}
		_ => anyhow::bail!("unknown Coinjoin operation"),
	}
	save(&path, &s)?;
	let mut result = summary(&s, &w);
	let c = rusqlite::Connection::open(&path)?;
	let archived: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='paperclip_coinjoin_legacy')", [], |r| r.get(0))?;
	if archived {
		let raw: String = c.query_row("SELECT state FROM paperclip_coinjoin_legacy WHERE id=1", [], |r| r.get(0))?;
		let old: State = serde_json::from_str(&raw)?;
		if let (Some(current), Some(previous)) = (result["rounds"].as_array_mut(), summary(&old, &w)["rounds"].as_array()) {
			current.extend(previous.iter().cloned());
		}
	}
	result["legacy_account"] = json!(legacy);
	result["account_path"] = json!(if legacy { "m/84h/0h/0h" } else { "m/84h/0h/1h" });
	Ok(result)
}
