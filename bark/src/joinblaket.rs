//! JoinBlaket/Jam account boundaries shared by mobile and server applications.
//!
//! Jar IDs are the daemon's mixdepths, never positions in a sorted UI. Existing
//! Paperclip/Kilojoin accounts must not be renamed or imported into these jars.

use std::collections::HashSet;

use anyhow::{ensure, Context};
use bitcoin::OutPoint;
use serde::{Deserialize, Serialize};

pub const JAR_NAMES: [&str; 5] = ["Apricot", "Blueberry", "Cherry", "Date", "Elderberry"];
const MAX_MONEY: u64 = 21_000_000 * 100_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u8", into = "u8")]
pub struct JarId(u8);

impl TryFrom<u8> for JarId {
	type Error = anyhow::Error;
	fn try_from(value: u8) -> Result<Self, Self::Error> {
		ensure!(value < 5, "Unknown JoinBlaket jar");
		Ok(Self(value))
	}
}

impl From<JarId> for u8 {
	fn from(value: JarId) -> Self { value.0 }
}

impl JarId {
	pub fn name(self) -> &'static str { JAR_NAMES[self.0 as usize] }
}

/// A daemon UTXO; keys, wallet passwords and tokens never enter this model.
#[derive(Debug, Clone, Deserialize)]
pub struct JarCoin {
	pub utxo: OutPoint,
	pub value: u64,
	pub mixdepth: JarId,
	pub confirmations: i64,
	pub frozen: bool,
	#[serde(default)]
	pub locktime: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct JarBalance {
	pub id: JarId,
	pub name: &'static str,
	pub total_sat: u64,
	/// Confirmed ordinary coins only. This is not a maker-capacity estimate.
	pub confirmed_sat: u64,
	pub pending_sat: u64,
	pub frozen_sat: u64,
	/// Bonds remain separate even after maturity; spending needs its own review.
	pub bond_sat: u64,
}

/// Use integer UTXOs, not the display API's floating-point formatted balances.
/// An invalid/incomplete response is an error, never a fabricated zero balance.
pub fn jar_balances(coins: &[JarCoin]) -> anyhow::Result<Vec<JarBalance>> {
	let mut jars: Vec<_> = (0..5).map(|id| JarBalance {
		id: JarId(id), name: JAR_NAMES[id as usize], total_sat: 0,
		confirmed_sat: 0, pending_sat: 0, frozen_sat: 0, bond_sat: 0,
	}).collect();
	let mut seen = HashSet::new();
	let mut total = 0u64;
	for coin in coins {
		ensure!(seen.insert(coin.utxo), "Duplicate JoinBlaket coin");
		ensure!(coin.value <= MAX_MONEY, "Invalid JoinBlaket amount");
		ensure!(coin.confirmations >= 0, "Conflicted JoinBlaket coin; refresh wallet state");
		total = total.checked_add(coin.value).context("JoinBlaket balance overflow")?;
		ensure!(total <= MAX_MONEY, "Invalid JoinBlaket wallet balance");
		let jar = &mut jars[coin.mixdepth.0 as usize];
		jar.total_sat += coin.value;
		if coin.locktime.as_ref().is_some_and(|s| !s.is_empty()) {
			jar.bond_sat += coin.value;
		} else if coin.frozen {
			jar.frozen_sat += coin.value;
		} else if coin.confirmations == 0 {
			jar.pending_sat += coin.value;
		} else {
			jar.confirmed_sat += coin.value;
		}
	}
	Ok(jars)
}

/// Coin control cannot silently merge jars or substitute another input.
pub fn validate_selection(jar: JarId, selected: &[OutPoint], coins: &[JarCoin]) -> anyhow::Result<()> {
	jar_balances(coins)?;
	ensure!(!selected.is_empty(), "Select coins from one jar");
	let mut seen = HashSet::new();
	for outpoint in selected {
		ensure!(seen.insert(*outpoint), "Duplicate selected coin");
		let coin = coins.iter().find(|coin| coin.utxo == *outpoint).context("Selected coin is unavailable")?;
		ensure!(coin.mixdepth == jar, "Coins from different jars cannot be combined");
		ensure!(!coin.frozen && coin.confirmations > 0, "Selected coin is frozen or unconfirmed");
		ensure!(coin.locktime.as_ref().is_none_or(|s| s.is_empty()), "Fidelity bonds require a separate spend review");
	}
	Ok(())
}

/// GET alone does not imply safety: address/new and maker/stop mutate state.
pub fn is_read_only_operation(operation: &str) -> bool {
	matches!(operation, "getinfo" | "session" | "wallet/all" | "display" | "utxos" | "history" | "taker/status")
}

#[cfg(test)]
mod tests {
	use super::*;
	use bitcoin::hashes::Hash;
	fn coin(index: u32, jar: u8, amount: u64) -> JarCoin {
		JarCoin { utxo: OutPoint::new(bitcoin::Txid::all_zeros(), index), value: amount,
			mixdepth: JarId::try_from(jar).unwrap(), confirmations: 6, frozen: false, locktime: None }
	}
	#[test]
	fn jars_preserve_accounts_and_separate_unavailable_balances() {
		let mut coins = vec![coin(0, 3, 100), coin(1, 0, 200), coin(2, 3, 300), coin(3, 3, 400)];
		coins[1].confirmations = 0;
		coins[2].frozen = true;
		coins[3].locktime = Some("2026-12-01 00:00:00".into());
		let jars = jar_balances(&coins).unwrap();
		assert_eq!(jars.len(), 5);
		assert_eq!(jars[0].pending_sat, 200);
		assert_eq!(jars[3].name, "Date");
		assert_eq!(jars[3].total_sat, 800);
		assert_eq!(jars[3].confirmed_sat, 100);
		assert_eq!(jars[3].frozen_sat, 300);
		assert_eq!(jars[3].bond_sat, 400);
	}
	#[test]
	fn selection_cannot_cross_jar_boundaries_or_spend_bonds() {
		let mut coins = vec![coin(0, 0, 100), coin(1, 1, 200)];
		assert!(validate_selection(JarId(0), &[coins[0].utxo], &coins).is_ok());
		assert!(validate_selection(JarId(0), &[coins[0].utxo, coins[1].utxo], &coins).is_err());
		coins[0].locktime = Some("2020-01-01 00:00:00".into());
		assert!(validate_selection(JarId(0), &[coins[0].utxo], &coins).is_err());
	}
	#[test]
	fn malformed_or_duplicate_coins_are_not_zero_balances() {
		assert!(serde_json::from_str::<JarId>("5").is_err());
		assert!(serde_json::from_str::<JarId>("-1").is_err());
		assert!(jar_balances(&[coin(0, 0, 1), coin(0, 1, 1)]).is_err());
		assert!(jar_balances(&[coin(0, 0, MAX_MONEY), coin(1, 1, 1)]).is_err());
	}
	#[test]
	fn mutations_are_not_observations_even_when_http_get() {
		for op in ["address/new/0", "maker/stop", "maker/start", "unlock", "configset", "unknown"] {
			assert!(!is_read_only_operation(op));
		}
		assert!(is_read_only_operation("session"));
		assert!(is_read_only_operation("utxos"));
	}
}
