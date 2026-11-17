use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{ensure, Context};
use bark::actions::offboard::{Offboard, Progress as OffboardProgress};
use bark::movement::{Movement, MovementStatus};
use bark::subsystem::Subsystem;
use bark::OffboardResult;
use bitcoin::{Network, bip32::{Xpriv, Xpub}, hashes::{sha256, Hash}};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Display/recovery data only. It can never be converted back into a send quote.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Attempt {
	version: u32,
	pub attempt_id: String,
	pub state: String,
	pub source: String,
	pub destination: String,
	pub amount_sat: u64,
	pub total_sat: u64,
	pub created_at: u64,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub txid: Option<String>,
	/// The candidate actually observed confirmed, which may precede an RBF attempt.
	#[serde(skip_serializing_if = "Option::is_none")]
	pub confirmed_txid: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub payment_hash: Option<String>,
	/// Exact direct-Ark action, saved before the core can submit it.
	#[serde(skip_serializing_if = "Option::is_none")]
	pub ark_action_id: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub offboard_action_id: Option<String>,
	#[serde(default)]
	pub replacement_txids: Vec<String>,
}

impl Attempt {
	pub fn new(source: &str, destination: String, amount_sat: u64, total_sat: u64) -> Self {
		Self { version: 1, attempt_id: sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()).to_string(),
			state: "unknown".into(), source: source.into(), destination, amount_sat, total_sat,
			created_at: SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
			txid: None, confirmed_txid: None, payment_hash: None, ark_action_id: None, offboard_action_id: None, replacement_txids: Vec::new() }
	}
	pub fn unresolved(&self) -> bool { !matches!(self.state.as_str(), "completed" | "paid" | "not_sent") }
	fn validate(&self) -> anyhow::Result<()> {
		fn hash(text: &str) -> bool { text.len() == 64 && text.bytes().all(|b| b.is_ascii_hexdigit()) }
		ensure!(self.version == 1 && hash(&self.attempt_id) && matches!(self.source.as_str(), "onchain" | "ark")
			&& !self.destination.is_empty() && self.destination.len() <= 16384
			&& self.amount_sat > 0 && self.total_sat >= self.amount_sat
			&& matches!(self.state.as_str(), "unknown" | "pending" | "submitted" | "pending_broadcast" | "completed" | "paid" | "not_sent")
			&& self.txid.as_deref().is_none_or(hash) && self.payment_hash.as_deref().is_none_or(hash)
			&& self.replacement_txids.len() <= 16 && self.replacement_txids.iter().all(|v| hash(v)),
			"Saved payment needs recovery; no new payment was started");
		ensure!(self.ark_action_id.as_ref().is_none_or(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())
			&& self.source == "ark" && self.txid.is_none() && self.payment_hash.is_none() && self.offboard_action_id.is_none()
			&& self.replacement_txids.is_empty()),
			"Saved Ark action does not belong to this payment type");
		ensure!(self.offboard_action_id.as_ref().is_none_or(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())
			&& self.source == "ark" && self.payment_hash.is_none() && self.ark_action_id.is_none() && self.replacement_txids.is_empty()),
			"Saved withdrawal action does not belong to this payment type");
		ensure!(self.state != "not_sent" || (self.txid.is_none() && self.payment_hash.is_none()
			&& self.ark_action_id.is_none() && self.offboard_action_id.is_none() && self.replacement_txids.is_empty()),
			"A referenced payment cannot be restored as not submitted");
		ensure!(self.confirmed_txid.as_ref().is_none_or(|confirmed| self.txid.is_some() && self.state == "completed"
			&& (self.txid.as_ref() == Some(confirmed) || self.replacement_txids.contains(confirmed))),
			"Confirmed transaction does not belong to the saved payment");
		Ok(())
	}
}

/// Full public master-key identity, domain- and network-bound, not a short BIP32 fingerprint.
pub fn owner(network: Network, seed: &[u8;64]) -> String {
	let master = Xpriv::new_master(network, seed).expect("64-byte seed");
	let public = Xpub::from_priv(&bitcoin::secp256k1::Secp256k1::new(), &master);
	sha256::Hash::hash(format!("paperclip-payment-v1\n{network}\n{public}").as_bytes()).to_string()
}

fn connection(dir: &Path) -> anyhow::Result<Connection> {
	let conn = Connection::open_with_flags(dir.join("db.sqlite"), rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)?;
	conn.busy_timeout(Duration::from_secs(5))?;
	conn.pragma_update(None, "synchronous", "FULL")?;
	Ok(conn)
}
fn read(conn: &Connection, owner: &str) -> anyhow::Result<Option<Attempt>> {
	let exists: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='paperclip_payment_attempt')", [], |r| r.get(0))?;
	if !exists { return Ok(None); }
	let row: Option<(String, String)> = conn.query_row("SELECT owner, body FROM paperclip_payment_attempt WHERE id=1", [], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
	let Some((saved_owner, body)) = row else { return Ok(None); };
	ensure!(saved_owner == owner && body.len() <= 32768, "Saved payment belongs to another wallet or is damaged");
	let attempt: Attempt = serde_json::from_str(&body).map_err(|_| anyhow::anyhow!("Saved payment could not be read; check its outcome before sending"))?;
	attempt.validate()?;
	Ok(Some(attempt))
}
pub fn load(dir: &Path, owner: &str) -> anyhow::Result<Option<Attempt>> { read(&connection(dir)?, owner) }
pub fn require_resolved(dir: &Path, owner: &str) -> anyhow::Result<()> {
	ensure!(!load(dir, owner)?.is_some_and(|a| a.unresolved()), "Check the previous payment before starting another send");
	Ok(())
}
/// The core calls this with the resolved invoice hash before checkpoint creation
/// or a resumed drive. Persist it even if the subsequent send reply is lost.
pub fn lightning_observer(dir: &Path, owner: &str, id: &str)
	-> impl Fn(ark::lightning::PaymentHash) -> anyhow::Result<()> + Send + Sync + 'static
{
	let dir = dir.to_path_buf(); let owner = owner.to_owned(); let id = id.to_owned();
	move |hash| {
		update(&dir, &owner, &id, &serde_json::json!({"state":"unknown", "payment_hash":hash.to_string()}))?;
		Ok(())
	}
}

pub fn ark_observer(dir: &Path, owner: &str, id: &str)
	-> impl FnOnce(&str) -> anyhow::Result<()> + Send + 'static
{
	let dir = dir.to_path_buf(); let owner = owner.to_owned(); let id = id.to_owned();
	move |action| {
		update(&dir, &owner, &id, &serde_json::json!({"state":"unknown", "ark_action_id":action}))?;
		Ok(())
	}
}

/// Recheck the constructed action after fee calculation and before the core can
/// create a checkpoint. Returning an error prevents locking or spending inputs.
pub fn offboard_observer(dir: &Path, owner: &str, id: &str, destination: &bitcoin::Address)
	-> impl FnOnce(&Offboard) -> anyhow::Result<()> + Send + 'static
{
	let dir = dir.to_path_buf(); let owner = owner.to_owned(); let id = id.to_owned();
	let destination = destination.clone().into_unchecked();
	move |action| {
		let attempt = load(&dir, &owner)?.context("Saved withdrawal is missing")?;
		let total = action.onchain_output_amount.checked_add(action.committed_fee)
			.and_then(|v| v.checked_add(action.recovery_reserve)).context("Withdrawal cost overflow")?;
		ensure!(attempt.attempt_id == id && action.progress == OffboardProgress::Start
			&& action.destination == destination && action.onchain_output_amount.to_sat() == attempt.amount_sat
			&& total.to_sat() <= attempt.total_sat, "Withdrawal changed; the reviewed payment was not submitted");
		update(&dir, &owner, &id, &serde_json::json!({"state":"unknown", "offboard_action_id":action.id}))?;
		Ok(())
	}
}

/// The caller must await the original tracked call to completion. `authorized`
/// is live evidence that its observer returned successfully, never restored data.
/// Cancellation or process death must leave the attempt unresolved.
pub fn finish_offboard(dir: &Path, owner: &str, id: &str, authorized: bool, outcome: anyhow::Result<OffboardResult>) -> anyhow::Result<Value> {
	let result = match outcome {
		Ok(result) => {
			ensure!(authorized, "Withdrawal completed without its submission observer");
			serde_json::json!({"state":"submitted", "txid":result.txid.to_string()})
		},
		Err(_) if !authorized => serde_json::json!({"state":"not_sent"}),
		Err(error) => return Err(error),
	};
	let mut saved = serde_json::to_value(update(dir, owner, id, &result)?)?;
	if !authorized {
		saved["reason"] = "Withdrawal was not submitted. Review the amount and fees again when ready.".into();
	}
	Ok(saved)
}

/// Recover only the signed/adopted transaction recorded under this exact action.
/// A movement's status alone does not establish confirmation or permit a retry.
pub fn offboard_txid(attempt: &Attempt, movement: Option<&Movement>) -> anyhow::Result<Option<bitcoin::Txid>> {
	attempt.validate()?;
	ensure!(attempt.offboard_action_id.is_some(), "Saved withdrawal action is missing");
	let Some(movement) = movement else { return Ok(None); };
	ensure!(movement.subsystem.is_subsystem(Subsystem::OFFBOARD)
		&& matches!(movement.subsystem.kind.as_str(), "offboard" | "send_onchain")
		&& movement.sent_to.len() == 1
		&& matches!(movement.sent_to[0].destination, bark::movement::PaymentMethod::Bitcoin(_))
		&& movement.sent_to[0].amount.to_sat() == attempt.amount_sat
		&& movement.offchain_fee.to_sat() <= attempt.total_sat - attempt.amount_sat,
		"Saved withdrawal has an unexpected movement; check the original payment");
	if matches!(movement.status, MovementStatus::Failed | MovementStatus::Canceled) { return Ok(None); }
	movement.metadata.get("offboard_txid").map(|v| {
		v.as_str().context("Withdrawal transaction reference is damaged")?.parse()
			.context("Withdrawal transaction reference is invalid")
	}).transpose()
}

/// Only classify a movement looked up by the saved action, never by recipient
/// or amount. A failed movement is not evidence that funds are safe to resend.
pub fn ark_result(attempt: &Attempt, movement: Option<&Movement>) -> anyhow::Result<Value> {
	attempt.validate()?;
	ensure!(attempt.ark_action_id.is_some(), "Saved Ark action is missing");
	let Some(movement) = movement else { return Ok(serde_json::json!({"state":"unknown"})); };
	ensure!(movement.subsystem.is_subsystem(Subsystem::ARKOOR) && movement.subsystem.kind == "send"
		&& movement.intended_balance.to_sat().checked_neg().and_then(|v| u64::try_from(v).ok()) == Some(attempt.amount_sat)
		&& movement.sent_to.len() == 1 && movement.sent_to[0].destination.is_ark()
		&& movement.sent_to[0].amount.to_sat() == attempt.amount_sat,
		"Saved Ark action has an unexpected movement; keep checking the original payment");
	Ok(serde_json::json!({"state":match movement.status {
		MovementStatus::Successful => "completed",
		MovementStatus::Pending => "pending",
		MovementStatus::Failed | MovementStatus::Canceled => "unknown",
	}, "movement_id":movement.id}))
}
pub fn begin(dir: &Path, owner: &str, attempt: &Attempt) -> anyhow::Result<()> {
	attempt.validate()?;
	ensure!(attempt.state == "unknown", "New payment must start unresolved");
	let mut conn = connection(dir)?;
	let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
	tx.execute_batch(include_str!("payment-schema.sql"))?;
	ensure!(!read(&tx, owner)?.is_some_and(|a| a.unresolved()), "Check the previous payment before starting another send");
	let body = serde_json::to_string(attempt)?;
	ensure!(body.len() <= 32000, "Payment request is too large to save safely");
	tx.execute("INSERT INTO paperclip_payment_attempt (id, owner, body) VALUES (1, ?1, ?2) ON CONFLICT(id) DO UPDATE SET owner=excluded.owner, body=excluded.body",
		rusqlite::params![owner, body])?;
	tx.commit()?;
	Ok(())
}
/// Only called with an internal native result, never with caller-supplied state.
pub fn update(dir: &Path, owner: &str, id: &str, result: &Value) -> anyhow::Result<Attempt> {
	let mut conn = connection(dir)?;
	let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
	let mut attempt = read(&tx, owner)?.context("Saved payment is missing")?;
	ensure!(attempt.attempt_id == id, "Saved payment changed; check the current attempt");
	let state = result["state"].as_str().context("Payment state is missing")?;
	ensure!(attempt.unresolved() || attempt.state == state,
		"A verified payment outcome cannot be replaced by a delayed result");
	for (key, saved) in [("txid", &mut attempt.txid), ("payment_hash", &mut attempt.payment_hash),
		("confirmed_txid", &mut attempt.confirmed_txid), ("ark_action_id", &mut attempt.ark_action_id),
		("offboard_action_id", &mut attempt.offboard_action_id)] {
		if let Some(value) = result[key].as_str() {
			ensure!(saved.as_deref().is_none_or(|old| old == value), "Payment reference changed; keep checking the original attempt");
			*saved = Some(value.into());
		}
	}
	// Only a completed call that never authorized submission may resolve this
	// way. Existing references or a later state keep recovery conservative.
	ensure!(state != "not_sent" || (matches!(attempt.state.as_str(), "unknown" | "not_sent")
		&& attempt.txid.is_none() && attempt.payment_hash.is_none() && attempt.ark_action_id.is_none()
		&& attempt.offboard_action_id.is_none() && attempt.replacement_txids.is_empty()),
		"A referenced payment cannot be classified as not submitted");
	attempt.state = state.into();
	ensure!(attempt.state != "completed" || attempt.txid.is_none() || attempt.confirmed_txid.is_some(),
		"A completed on-chain payment must identify its confirmed transaction");
	attempt.validate()?;
	let body = serde_json::to_string(&attempt)?;
	ensure!(body.len() <= 32768, "Payment result is too large to save safely");
	tx.execute("UPDATE paperclip_payment_attempt SET body=?1 WHERE id=1", [body])?;
	tx.commit()?;
	Ok(attempt)
}

/// Called by the reviewed RBF commit's durable boundary, before persistence or broadcast.
pub fn replacement(dir: &Path, owner: &str, original: &str, replacement: &str, fee_sat: u64) -> anyhow::Result<()> {
	let mut conn = connection(dir)?;
	let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
	let Some(mut attempt) = read(&tx, owner)? else { return Ok(()); };
	if attempt.source != "onchain" || (attempt.txid.as_deref() != Some(original) && !attempt.replacement_txids.iter().any(|v| v == original)) { return Ok(()); }
	if !attempt.replacement_txids.iter().any(|v| v == replacement) { attempt.replacement_txids.push(replacement.into()); }
	attempt.total_sat = attempt.amount_sat.checked_add(fee_sat).context("Replacement amount overflow")?;
	attempt.state = "unknown".into();
	attempt.validate()?;
	let body = serde_json::to_string(&attempt)?;
	ensure!(body.len() <= 32768, "Payment result is too large to save safely");
	tx.execute("UPDATE paperclip_payment_attempt SET body=?1 WHERE id=1", [body])?;
	tx.commit()?;
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	use serde_json::json;

	fn setup() -> (tempfile::TempDir, String) {
		let dir = tempfile::tempdir().unwrap();
		Connection::open(dir.path().join("db.sqlite")).unwrap();
		(dir, owner(Network::Regtest, &[21;64]))
	}
	#[test]
	fn unresolved_attempt_survives_reopen_and_cannot_be_replaced() {
		let (dir, owner) = setup();
		assert!(load(dir.path(), &owner).unwrap().is_none());
		let mut attempt = Attempt::new("onchain", "public fixture".into(), 1000, 1100);
		attempt.txid = Some("ab".repeat(32));
		begin(dir.path(), &owner, &attempt).unwrap();
		let restored = load(dir.path(), &owner).unwrap().unwrap();
		assert_eq!(restored.attempt_id, attempt.attempt_id);
		assert_eq!(restored.txid, attempt.txid);
		assert!(restored.unresolved());
		assert!(begin(dir.path(), &owner, &Attempt::new("ark", "other".into(), 2000, 2100)).is_err());
		assert!(update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"completed", "txid":"cd".repeat(32)})).is_err());
		assert!(update(dir.path(), &owner, &"00".repeat(32), &json!({"state":"paid"})).is_err());
		assert_eq!(load(dir.path(), &owner).unwrap().unwrap().state, "unknown");
		update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"completed", "confirmed_txid":attempt.txid})).unwrap();
		assert!(!load(dir.path(), &owner).unwrap().unwrap().unresolved());
		begin(dir.path(), &owner, &Attempt::new("ark", "next".into(), 2000, 2100)).unwrap();
	}
	#[test]
	fn absent_references_remain_absent_for_mobile_json_readers() {
		let attempt = Attempt::new("ark", "public fixture".into(), 1000, 1100);
		let value = serde_json::to_value(&attempt).unwrap();
		assert!(value.get("txid").is_none());
		assert!(value.get("confirmed_txid").is_none());
		assert!(value.get("payment_hash").is_none());
		assert!(value.get("ark_action_id").is_none());
		assert!(value.get("offboard_action_id").is_none());
		let restored: Attempt = serde_json::from_value(value).unwrap();
		assert_eq!(restored.attempt_id, attempt.attempt_id);
		assert!(restored.txid.is_none() && restored.payment_hash.is_none());
	}
	#[test]
	fn withdrawal_guard_binds_recipient_net_amount_and_total_before_recording_action() {
		let (dir, owner) = setup();
		let destination = bitcoin::Address::p2wsh(&bitcoin::ScriptBuf::from_bytes(vec![0x51]), Network::Regtest);
		let attempt = Attempt::new("ark", destination.to_string(), 1000, 1100);
		begin(dir.path(), &owner, &attempt).unwrap();
		let mut action = Offboard {
			id: "ab".repeat(16), destination: destination.clone().into_unchecked(),
			onchain_output_amount: bitcoin::Amount::from_sat(1000), committed_fee: bitcoin::Amount::from_sat(80),
			recovery_reserve: bitcoin::Amount::from_sat(20), committed_fee_rate: bitcoin::FeeRate::from_sat_per_vb(1).unwrap(),
			kind: bark::actions::offboard::OffboardKind::OffboardWhole { input_vtxo_ids: vec![] }, progress: OffboardProgress::Start,
		};
		let observe = |id: &str, action: &Offboard| offboard_observer(dir.path(), &owner, id, &destination)(action);
		for field in ["recipient", "amount", "fee", "reserve", "overflow", "progress"] {
			let mut changed = action.clone();
			match field {
				"recipient" => changed.destination = bitcoin::Address::p2wsh(&bitcoin::ScriptBuf::from_bytes(vec![0x52]), Network::Regtest).into_unchecked(),
				"amount" => changed.onchain_output_amount = bitcoin::Amount::from_sat(999),
				"fee" => changed.committed_fee = bitcoin::Amount::from_sat(81),
				"reserve" => changed.recovery_reserve = bitcoin::Amount::from_sat(21),
				"overflow" => changed.committed_fee = bitcoin::Amount::from_sat(u64::MAX),
				_ => changed.progress = OffboardProgress::SplitWithArkoor,
			}
			assert!(observe(&attempt.attempt_id, &changed).is_err(), "{field}");
			assert!(load(dir.path(), &owner).unwrap().unwrap().offboard_action_id.is_none());
		}
		assert!(observe(&"00".repeat(32), &action).is_err());
		let conn = connection(dir.path()).unwrap();
		conn.execute_batch("CREATE TRIGGER reject_withdrawal_reference BEFORE UPDATE ON paperclip_payment_attempt BEGIN SELECT RAISE(FAIL, 'fixture failure'); END;").unwrap();
		assert!(observe(&attempt.attempt_id, &action).is_err());
		conn.execute_batch("DROP TRIGGER reject_withdrawal_reference;").unwrap();
		observe(&attempt.attempt_id, &action).unwrap();
		assert_eq!(load(dir.path(), &owner).unwrap().unwrap().offboard_action_id.as_deref(), Some(action.id.as_str()));
		assert!(update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"unknown", "ark_action_id":action.id})).is_err());
		assert!(update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"unknown", "payment_hash":"ab".repeat(32)})).is_err());
		action.id = "cd".repeat(16);
		assert!(observe(&attempt.attempt_id, &action).is_err());
		assert!(require_resolved(dir.path(), &owner).is_err());
	}
	#[test]
	fn rejected_withdrawal_allows_new_review_only_after_durable_resolution() {
		let (dir, owner) = setup();
		let destination = bitcoin::Address::p2wsh(&bitcoin::ScriptBuf::from_bytes(vec![0x51]), Network::Regtest);
		let attempt = Attempt::new("ark", destination.to_string(), 1000, 1100);
		begin(dir.path(), &owner, &attempt).unwrap();
		let action = Offboard {
			id: "ab".repeat(16), destination: destination.clone().into_unchecked(),
			onchain_output_amount: bitcoin::Amount::from_sat(1000), committed_fee: bitcoin::Amount::from_sat(101),
			recovery_reserve: bitcoin::Amount::ZERO, committed_fee_rate: bitcoin::FeeRate::from_sat_per_vb(1).unwrap(),
			kind: bark::actions::offboard::OffboardKind::OffboardWhole { input_vtxo_ids: vec![] }, progress: OffboardProgress::Start,
		};
		let rejected = offboard_observer(dir.path(), &owner, &attempt.attempt_id, &destination)(&action).unwrap_err();
		assert!(require_resolved(dir.path(), &owner).is_err(), "An absent action alone is not proof of failure");
		let conn = connection(dir.path()).unwrap();
		conn.execute_batch("CREATE TRIGGER reject_resolution BEFORE UPDATE ON paperclip_payment_attempt BEGIN SELECT RAISE(FAIL, 'fixture failure'); END;").unwrap();
		assert!(finish_offboard(dir.path(), &owner, &attempt.attempt_id, false, Err(rejected)).is_err());
		assert!(require_resolved(dir.path(), &owner).is_err());
		conn.execute_batch("DROP TRIGGER reject_resolution;").unwrap();
		let result = finish_offboard(dir.path(), &owner, &attempt.attempt_id, false, Err(anyhow::anyhow!("synthetic pre-submit error"))).unwrap();
		assert_eq!(result["state"], "not_sent");
		assert!(require_resolved(dir.path(), &owner).is_ok());
		let next = Attempt::new("ark", destination.to_string(), 900, 1000);
		begin(dir.path(), &owner, &next).unwrap();
		assert!(finish_offboard(dir.path(), &owner, &attempt.attempt_id, false, Err(anyhow::anyhow!("delayed error"))).is_err());
		assert_eq!(load(dir.path(), &owner).unwrap().unwrap().attempt_id, next.attempt_id);
		assert!(require_resolved(dir.path(), &owner).is_err());
	}

	#[test]
	fn authorized_or_referenced_withdrawal_error_never_allows_retry() {
		for reference in ["none", "offboard_action_id", "ark_action_id", "payment_hash", "txid"] {
			let (dir, owner) = setup();
			let attempt = Attempt::new("ark", "synthetic-destination".into(), 1000, 1100);
			begin(dir.path(), &owner, &attempt).unwrap();
			if reference != "none" {
				let value = if reference.ends_with("action_id") { "ab".repeat(16) } else { "ab".repeat(32) };
				update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"unknown", reference:value})).unwrap();
			}
			assert!(finish_offboard(dir.path(), &owner, &attempt.attempt_id, true, Err(anyhow::anyhow!("lost reply"))).is_err());
			assert!(require_resolved(dir.path(), &owner).is_err());
			if reference != "none" {
				assert!(finish_offboard(dir.path(), &owner, &attempt.attempt_id, false, Err(anyhow::anyhow!("ambiguous storage failure"))).is_err());
				assert!(require_resolved(dir.path(), &owner).is_err());
			}
			// Backup/restore preserves unknown; lack of a reference cannot restore
			// the in-memory proof that a particular call finished before submission.
			let restored: Attempt = serde_json::from_value(serde_json::to_value(load(dir.path(), &owner).unwrap().unwrap()).unwrap()).unwrap();
			assert!(restored.unresolved());
			if reference != "none" {
				let mut contradictory = restored;
				contradictory.state = "not_sent".into();
				assert!(contradictory.validate().is_err());
			}
		}
	}

	#[test]
	fn successful_withdrawal_stays_submitted_until_chain_confirmation() {
		let (dir, owner) = setup();
		let mut attempt = Attempt::new("ark", "synthetic-destination".into(), 1000, 1100);
		attempt.offboard_action_id = Some("ab".repeat(16));
		begin(dir.path(), &owner, &attempt).unwrap();
		let outcome = OffboardResult { txid: "cd".repeat(32).parse().unwrap(), movement_id: bark::movement::MovementId(1) };
		let result = finish_offboard(dir.path(), &owner, &attempt.attempt_id, true, Ok(outcome)).unwrap();
		assert_eq!(result["state"], "submitted");
		assert_eq!(result["txid"], "cd".repeat(32));
		assert_eq!(result["offboard_action_id"], "ab".repeat(16));
		assert!(require_resolved(dir.path(), &owner).is_err());
	}

	#[test]
	fn withdrawal_reference_is_not_proof_of_confirmation_or_safe_retry() {
		let (dir, owner) = setup();
		let destination = bitcoin::Address::p2wsh(&bitcoin::ScriptBuf::from_bytes(vec![0x51]), Network::Regtest);
		let mut attempt = Attempt::new("ark", destination.to_string(), 1000, 1100);
		attempt.offboard_action_id = Some("ab".repeat(16));
		begin(dir.path(), &owner, &attempt).unwrap();
		let subsystem = bark::movement::MovementSubsystem { name: Subsystem::OFFBOARD.as_name().into(), kind: "offboard".into() };
		let mut movement = Movement::new(bark::movement::MovementId(1), MovementStatus::Pending, &subsystem,
			"2026-11-17T00:00:00+00:00".parse().unwrap());
		movement.sent_to = vec![bark::movement::MovementDestination::bitcoin(destination, bitcoin::Amount::from_sat(1000))];
		movement.offchain_fee = bitcoin::Amount::from_sat(100);
		assert!(offboard_txid(&attempt, None).unwrap().is_none());
		assert!(offboard_txid(&attempt, Some(&movement)).unwrap().is_none());
		let txid = "ab".repeat(32);
		movement.metadata.insert("offboard_txid".into(), json!(txid));
		for kind in ["offboard", "send_onchain"] {
			movement.subsystem.kind = kind.into();
			for status in [MovementStatus::Pending, MovementStatus::Successful] {
				movement.status = status;
				assert_eq!(offboard_txid(&attempt, Some(&movement)).unwrap(), Some(txid.parse().unwrap()));
				let saved = update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"unknown", "txid":txid})).unwrap();
				assert!(saved.unresolved(), "A recorded transaction still needs chain evidence");
			}
		}
		for status in [MovementStatus::Failed, MovementStatus::Canceled] {
			movement.status = status;
			assert!(offboard_txid(&attempt, Some(&movement)).unwrap().is_none());
			assert!(require_resolved(dir.path(), &owner).is_err());
		}
		movement.status = MovementStatus::Pending;
		movement.metadata.insert("offboard_txid".into(), json!("broken"));
		assert!(offboard_txid(&attempt, Some(&movement)).is_err());
		movement.metadata.insert("offboard_txid".into(), json!(txid));
		movement.subsystem.name = Subsystem::ARKOOR.as_name().into();
		assert!(offboard_txid(&attempt, Some(&movement)).is_err());
		movement.subsystem = subsystem;
		movement.sent_to[0].amount = bitcoin::Amount::from_sat(999);
		assert!(offboard_txid(&attempt, Some(&movement)).is_err());
		movement.sent_to[0].amount = bitcoin::Amount::from_sat(1000);
		movement.offchain_fee = bitcoin::Amount::from_sat(101);
		assert!(offboard_txid(&attempt, Some(&movement)).is_err());
		assert!(update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"completed"})).is_err());
		update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"completed", "confirmed_txid":txid})).unwrap();
		assert!(!load(dir.path(), &owner).unwrap().unwrap().unresolved());
	}
	#[test]
	fn ark_action_is_durable_immutable_and_fails_closed_before_submission() {
		let (dir, owner) = setup();
		let attempt = Attempt::new("ark", "public Ark fixture".into(), 1000, 1100);
		begin(dir.path(), &owner, &attempt).unwrap();
		let action = "ab".repeat(16);
		let observe = |id: &str, action: &str| ark_observer(dir.path(), &owner, id)(action);
		assert!(observe(&attempt.attempt_id, "invalid").is_err());
		observe(&attempt.attempt_id, &action).unwrap();
		assert_eq!(load(dir.path(), &owner).unwrap().unwrap().ark_action_id.as_deref(), Some(action.as_str()));
		assert!(observe(&attempt.attempt_id, &"cd".repeat(16)).is_err());
		assert!(observe(&"00".repeat(32), &action).is_err());
		assert!(update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"unknown", "payment_hash":"ab".repeat(32)})).is_err());
		assert!(update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"unknown", "txid":"ab".repeat(32)})).is_err());
		let conn = connection(dir.path()).unwrap();
		conn.execute_batch("CREATE TRIGGER reject_ark_reference BEFORE UPDATE ON paperclip_payment_attempt BEGIN SELECT RAISE(FAIL, 'fixture failure'); END;").unwrap();
		assert!(observe(&attempt.attempt_id, &action).is_err());
		assert!(require_resolved(dir.path(), &owner).is_err());
		conn.execute_batch("DROP TRIGGER reject_ark_reference;").unwrap();
		update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"completed"})).unwrap();
		assert!(observe(&attempt.attempt_id, &action).is_err());
		let next = Attempt::new("onchain", "public chain fixture".into(), 1000, 1100);
		begin(dir.path(), &owner, &next).unwrap();
		assert!(observe(&next.attempt_id, &action).is_err());
	}
	#[test]
	fn ark_recovery_needs_the_exact_send_outcome_not_just_a_movement_id() {
		let (dir, owner) = setup();
		let mut attempt = Attempt::new("ark", "public Ark fixture".into(), 1000, 1100);
		attempt.ark_action_id = Some("ab".repeat(16));
		begin(dir.path(), &owner, &attempt).unwrap();
		let subsystem = bark::movement::MovementSubsystem { name: Subsystem::ARKOOR.as_name().into(), kind: "send".into() };
		let mut movement = Movement::new(bark::movement::MovementId(1), MovementStatus::Pending, &subsystem,
			"2026-11-17T00:00:00+00:00".parse().unwrap());
		movement.intended_balance = bitcoin::SignedAmount::from_sat(-1000);
		movement.sent_to = vec![bark::movement::MovementDestination::ark(
			"tark1pwh9vsmezqqpharv69q4z8m6x364d5m5prnmcalcalq9pdmzw0y7mpveck4pcfhezqypczkrrj3lkx5ue4qrf4jc7ztpt9htdttmh2judhqnu7aue8p0y9mq47jn9z".parse().unwrap(),
			bitcoin::Amount::from_sat(1000))];
		assert_eq!(ark_result(&attempt, None).unwrap()["state"], "unknown");
		for (status, expected) in [(MovementStatus::Pending, "pending"), (MovementStatus::Failed, "unknown"), (MovementStatus::Canceled, "unknown")] {
			movement.status = status;
			let result = ark_result(&attempt, Some(&movement)).unwrap();
			assert_eq!(result["state"], expected);
			assert!(update(dir.path(), &owner, &attempt.attempt_id, &result).unwrap().unresolved());
			assert!(require_resolved(dir.path(), &owner).is_err());
		}
		movement.status = MovementStatus::Successful;
		movement.subsystem.kind = "receive".into();
		assert!(ark_result(&attempt, Some(&movement)).is_err());
		movement.subsystem.kind = "send".into();
		movement.subsystem.name = "bark.lightning".into();
		assert!(ark_result(&attempt, Some(&movement)).is_err());
		movement.subsystem = subsystem;
		movement.sent_to[0].amount = bitcoin::Amount::from_sat(999);
		assert!(ark_result(&attempt, Some(&movement)).is_err());
		movement.sent_to[0].amount = bitcoin::Amount::from_sat(1000);
		let result = ark_result(&attempt, Some(&movement)).unwrap();
		assert_eq!(result["state"], "completed");
		assert_eq!(result["movement_id"], 1);
		update(dir.path(), &owner, &attempt.attempt_id, &result).unwrap();
		assert!(!load(dir.path(), &owner).unwrap().unwrap().unresolved());
	}
	#[test]
	fn resolved_invoice_hash_is_durable_before_a_send_can_continue() {
		let (dir, owner) = setup();
		let attempt = Attempt::new("ark", "public offer fixture".into(), 1000, 1100);
		begin(dir.path(), &owner, &attempt).unwrap();
		let hash = "ab".repeat(32);
		let observer = lightning_observer(dir.path(), &owner, &attempt.attempt_id);
		observer(hash.parse().unwrap()).unwrap();
		drop(observer);
		let reopened = load(dir.path(), &owner).unwrap().unwrap();
		assert_eq!(reopened.payment_hash.as_deref(), Some(hash.as_str()));
		assert_eq!(reopened.state, "unknown");
		assert!(require_resolved(dir.path(), &owner).is_err());
		let observer = lightning_observer(dir.path(), &owner, &attempt.attempt_id);
		observer(hash.parse().unwrap()).unwrap(); // Same callback can be observed again.
		assert!(observer("cd".repeat(32).parse().unwrap()).is_err());
		assert!(lightning_observer(dir.path(), &owner, &"00".repeat(32))(hash.parse().unwrap()).is_err());
		let conn = connection(dir.path()).unwrap();
		conn.execute_batch("CREATE TRIGGER reject_payment_reference BEFORE UPDATE ON paperclip_payment_attempt BEGIN SELECT RAISE(FAIL, 'fixture failure'); END;").unwrap();
		assert!(observer(hash.parse().unwrap()).is_err(), "Storage failure must reach the core submission guard");
		assert_eq!(load(dir.path(), &owner).unwrap().unwrap().payment_hash, reopened.payment_hash);
		conn.execute_batch("DROP TRIGGER reject_payment_reference;").unwrap();
		update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"paid"})).unwrap();
		assert!(observer(hash.parse().unwrap()).is_err(), "A delayed observer cannot regress a verified payment");
		assert_eq!(load(dir.path(), &owner).unwrap().unwrap().state, "paid");
	}
	#[test]
	fn replacement_keeps_original_and_candidate_references_until_reconciliation() {
		let (dir, owner) = setup();
		let mut attempt = Attempt::new("onchain", "public RBF fixture".into(), 1000, 1100);
		let original = "ab".repeat(32); let first = "cd".repeat(32); let second = "ef".repeat(32);
		attempt.txid = Some(original.clone());
		begin(dir.path(), &owner, &attempt).unwrap();
		replacement(dir.path(), &owner, &first, &second, 200).unwrap();
		assert!(load(dir.path(), &owner).unwrap().unwrap().replacement_txids.is_empty());
		replacement(dir.path(), &owner, &original, &first, 200).unwrap();
		replacement(dir.path(), &owner, &first, &second, 300).unwrap();
		let saved = load(dir.path(), &owner).unwrap().unwrap();
		assert_eq!(saved.txid, Some(original));
		assert_eq!(saved.replacement_txids, vec![first, second]);
		assert_eq!(saved.total_sat, 1300);
		assert!(saved.unresolved());
		assert!(require_resolved(dir.path(), &owner).is_err());
	}
	#[test]
	fn confirmation_preserves_the_candidate_that_actually_settled() {
		for confirmed_is_original in [true, false] {
			let (dir, owner) = setup();
			let original = "ab".repeat(32); let candidate = "cd".repeat(32);
			let mut attempt = Attempt::new("onchain", "public RBF fixture".into(), 1000, 1100);
			attempt.txid = Some(original.clone());
			begin(dir.path(), &owner, &attempt).unwrap();
			replacement(dir.path(), &owner, &original, &candidate, 200).unwrap();
			assert!(update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"completed"})).is_err());
			assert!(update(dir.path(), &owner, &attempt.attempt_id,
				&json!({"state":"completed", "confirmed_txid":"ef".repeat(32)})).is_err());
			assert!(require_resolved(dir.path(), &owner).is_err());
			let confirmed = if confirmed_is_original { &original } else { &candidate };
			update(dir.path(), &owner, &attempt.attempt_id,
				&json!({"state":"completed", "confirmed_txid":confirmed})).unwrap();
			let reopened = load(dir.path(), &owner).unwrap().unwrap();
			assert_eq!(reopened.txid.as_ref(), Some(&original));
			assert_eq!(reopened.confirmed_txid.as_ref(), Some(confirmed));
			assert_eq!(reopened.replacement_txids, vec![candidate.clone()]);
			require_resolved(dir.path(), &owner).unwrap();
			let other = if confirmed_is_original { &candidate } else { &original };
			assert!(update(dir.path(), &owner, &attempt.attempt_id,
				&json!({"state":"completed", "confirmed_txid":other})).is_err());
			assert!(update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"pending"})).is_err());
			// Older snapshots retain completion but lack a selected candidate.
			// Readers must not invent which replacement confirmed.
			let mut legacy = serde_json::to_value(&reopened).unwrap();
			legacy.as_object_mut().unwrap().remove("confirmed_txid");
			connection(dir.path()).unwrap().execute("UPDATE paperclip_payment_attempt SET body=?1 WHERE id=1", [legacy.to_string()]).unwrap();
			let restored = load(dir.path(), &owner).unwrap().unwrap();
			assert!(restored.confirmed_txid.is_none());
			assert!(!restored.unresolved());
		}
	}
	#[test]
	fn wrong_owner_corruption_and_failed_storage_never_release_an_attempt() {
		let (dir, binding) = setup();
		let attempt = Attempt::new("ark", "public fixture".into(), 1000, 1100);
		begin(dir.path(), &binding, &attempt).unwrap();
		assert!(load(dir.path(), &owner(Network::Regtest, &[22;64])).is_err());
		assert!(load(dir.path(), &owner(Network::Bitcoin, &[21;64])).is_err());
		let conn = connection(dir.path()).unwrap();
		conn.execute_batch("CREATE TRIGGER reject_payment_update BEFORE UPDATE ON paperclip_payment_attempt BEGIN SELECT RAISE(FAIL, 'fixture failure'); END;").unwrap();
		assert!(update(dir.path(), &binding, &attempt.attempt_id, &json!({"state":"completed"})).is_err());
		assert!(require_resolved(dir.path(), &binding).is_err());
		conn.execute_batch("DROP TRIGGER reject_payment_update; UPDATE paperclip_payment_attempt SET body='invalid';").unwrap();
		assert!(load(dir.path(), &binding).is_err());
		assert!(begin(dir.path(), &binding, &attempt).is_err());
	}
	#[test]
	fn durable_attempt_survives_process_exit_without_cleanup() {
		const CHILD: &str = "PAPERCLIP_ATTEMPT_TEST_CHILD";
		if let Some(path) = std::env::var_os(CHILD) {
			let binding = owner(Network::Regtest, &[21;64]);
			let attempt = Attempt::new("ark", "public process fixture".into(), 1000, 1100);
			begin(Path::new(&path), &binding, &attempt).unwrap();
			ark_observer(Path::new(&path), &binding, &attempt.attempt_id)(&"ab".repeat(16)).unwrap();
			std::process::exit(0);
		}
		let (dir, binding) = setup();
		let status = std::process::Command::new(std::env::current_exe().unwrap())
			.args(["--exact", "payment_attempt::tests::durable_attempt_survives_process_exit_without_cleanup"])
			.env(CHILD, dir.path()).status().unwrap();
		assert!(status.success());
		assert_eq!(load(dir.path(), &binding).unwrap().unwrap().destination, "public process fixture");
		assert_eq!(load(dir.path(), &binding).unwrap().unwrap().ark_action_id, Some("ab".repeat(16)));
		assert!(require_resolved(dir.path(), &binding).is_err());
	}
}
