use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{ensure, Context};
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
	#[serde(skip_serializing_if = "Option::is_none")]
	pub payment_hash: Option<String>,
	#[serde(default)]
	pub replacement_txids: Vec<String>,
}

impl Attempt {
	pub fn new(source: &str, destination: String, amount_sat: u64, total_sat: u64) -> Self {
		Self { version: 1, attempt_id: sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()).to_string(),
			state: "unknown".into(), source: source.into(), destination, amount_sat, total_sat,
			created_at: SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
			txid: None, payment_hash: None, replacement_txids: Vec::new() }
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
	for (key, saved) in [("txid", &mut attempt.txid), ("payment_hash", &mut attempt.payment_hash)] {
		if let Some(value) = result[key].as_str() {
			ensure!(saved.as_deref().is_none_or(|old| old == value), "Payment reference changed; keep checking the original attempt");
			*saved = Some(value.into());
		}
	}
	attempt.state = result["state"].as_str().context("Payment state is missing")?.into();
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
		update(dir.path(), &owner, &attempt.attempt_id, &json!({"state":"completed"})).unwrap();
		assert!(!load(dir.path(), &owner).unwrap().unwrap().unresolved());
		begin(dir.path(), &owner, &Attempt::new("ark", "next".into(), 2000, 2100)).unwrap();
	}
	#[test]
	fn absent_references_remain_absent_for_mobile_json_readers() {
		let attempt = Attempt::new("ark", "public fixture".into(), 1000, 1100);
		let value = serde_json::to_value(&attempt).unwrap();
		assert!(value.get("txid").is_none());
		assert!(value.get("payment_hash").is_none());
		let restored: Attempt = serde_json::from_value(value).unwrap();
		assert_eq!(restored.attempt_id, attempt.attempt_id);
		assert!(restored.txid.is_none() && restored.payment_hash.is_none());
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
			begin(Path::new(&path), &binding, &Attempt::new("ark", "public process fixture".into(), 1000, 1100)).unwrap();
			std::process::exit(0);
		}
		let (dir, binding) = setup();
		let status = std::process::Command::new(std::env::current_exe().unwrap())
			.args(["--exact", "payment_attempt::tests::durable_attempt_survives_process_exit_without_cleanup"])
			.env(CHILD, dir.path()).status().unwrap();
		assert!(status.success());
		assert_eq!(load(dir.path(), &binding).unwrap().unwrap().destination, "public process fixture");
		assert!(require_resolved(dir.path(), &binding).is_err());
	}
}
