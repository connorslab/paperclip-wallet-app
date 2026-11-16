use std::{str::FromStr, time::{Duration, SystemTime, UNIX_EPOCH}};

use anyhow::{Context, ensure};
use ark::lightning::{Invoice, Offer, OfferAmount, Bolt12InvoiceExt};
use base64::{Engine, engine::general_purpose::STANDARD};
use bitcoin::{Amount, Network, constants::ChainHash, hashes::{Hash, sha256}};
use serde_json::{Value, json};

use super::transport::Implementation;

pub(super) fn now() -> Duration { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default() }
pub(super) fn number(value: &Value) -> anyhow::Result<u64> {
	value.as_u64().or_else(|| value.as_str().and_then(|s| s.strip_suffix("msat").unwrap_or(s).parse().ok()))
		.context("Invalid node amount")
}
pub(super) fn msats(sats: u64) -> anyhow::Result<u64> {
	ensure!(sats <= 2_100_000_000_000_000, "Amount is outside the supported range");
	sats.checked_mul(1000).context("Amount overflow")
}
pub(super) fn hash(value: &Value) -> anyhow::Result<sha256::Hash> {
	let text = value.as_str().context("Missing payment hash")?;
	if let Ok(hash) = text.parse() { return Ok(hash); }
	sha256::Hash::from_slice(&STANDARD.decode(text).context("Invalid payment hash")?).context("Invalid payment hash")
}
pub(super) fn identity(info: &Value, implementation: Implementation, network: Network) -> anyhow::Result<(String, String)> {
	let cln = implementation == Implementation::Cln;
	let id = info[if cln { "id" } else { "identity_pubkey" }].as_str().context("Node identity is missing")?;
	let key = bitcoin::secp256k1::PublicKey::from_str(id).context("Invalid node identity")?;
	let expected = match network { Network::Bitcoin => if cln { "bitcoin" } else { "mainnet" }, Network::Regtest => "regtest", _ => bail!("Connect an XBT mainnet or regtest node") };
	if cln { ensure!(info["network"] == expected, "Node network differs from this wallet"); }
	else {
		let chains = info["chains"].as_array().context("Node network is missing")?;
		ensure!(chains.len() == 1 && chains[0]["chain"] == "bitcoin" && chains[0]["network"] == expected, "Node network differs from this wallet");
	}
	let alias = info["alias"].as_str().unwrap_or("Lightning node").chars().filter(|c| !c.is_control()).take(64).collect();
	Ok((key.to_string(), alias))
}
pub(super) fn balance(value: &Value, implementation: Implementation) -> anyhow::Result<Value> {
	let channels = value["channels"].as_array().context("Missing node channels")?;
	let (mut send, mut receive, mut local, mut reserve, mut active) = (0u64, 0u64, 0u64, 0u64, 0u64);
	for channel in channels {
		let (outgoing, incoming) = if implementation == Implementation::Cln {
			if channel["state"] != "CHANNELD_NORMAL" || channel["peer_connected"] != true { continue; }
			(number(&channel["spendable_msat"])? , number(&channel["receivable_msat"])?)
		} else {
			if channel["active"] != true { continue; }
			let own = number(&channel["local_balance"])?;
			let peer = number(&channel["remote_balance"])?;
			let own_reserve = number(channel["local_constraints"].get("chan_reserve_sat").unwrap_or(&channel["local_chan_reserve_sat"]))?;
			let peer_reserve = number(channel["remote_constraints"].get("chan_reserve_sat").unwrap_or(&channel["remote_chan_reserve_sat"]))?;
			local = local.checked_add(msats(own)?).context("Balance overflow")?;
			reserve = reserve.checked_add(msats(own_reserve)?).context("Balance overflow")?;
			(msats(own.saturating_sub(own_reserve))?, msats(peer.saturating_sub(peer_reserve))?)
		};
		send = send.checked_add(outgoing).context("Balance overflow")?;
		receive = receive.checked_add(incoming).context("Balance overflow")?;
		active += 1;
	}
	Ok(json!({"sendable_msat":send.to_string(), "receivable_msat":receive.to_string(), "active_channels":active,
		"local_msat":(implementation == Implementation::Lnd).then(||local.to_string()),
		"reserve_msat":(implementation == Implementation::Lnd).then(||reserve.to_string())}))
}
pub(super) fn invoice(text: &str, network: Network) -> anyhow::Result<Invoice> {
	ensure!(text.len() <= 256 * 1024 && !text.chars().any(char::is_whitespace), "Invalid invoice");
	let invoice: Invoice = text.parse().context("Enter an XBT Lightning invoice or offer")?;
	invoice.require_xbt().context("This invoice does not identify the XBT network")?;
	invoice.check_signature().context("Invalid invoice signature")?;
	let correct_network = match &invoice {
		Invoice::Bolt11(value) => value.network() == network,
		Invoice::Bolt12(value) => value.chain() == ChainHash::using_genesis_block(network),
	};
	ensure!(correct_network, "Invoice belongs to another network");
	ensure!(invoice.has_send_lifetime(now()), "Invoice expired or expires too soon");
	ensure!(invoice.amount_msat().is_some_and(|n| n > 0 && n <= 2_100_000_000_000_000_000), "Use an invoice with a positive fixed amount");
	Ok(invoice)
}
pub(super) fn offer(text: &str, network: Network, amount_sat: Option<u64>) -> anyhow::Result<(Offer, u64)> {
	ensure!(text.len() <= 256 * 1024 && !text.chars().any(char::is_whitespace), "Invalid offer");
	let offer: Offer = text.parse().map_err(|_| anyhow::anyhow!("Invalid BOLT12 offer"))?;
	ensure!(offer.offer_features().requires_blake2b_identity() && offer.supports_chain(ChainHash::using_genesis_block(network)), "Offer belongs to another network");
	ensure!(!offer.expects_quantity() && offer.absolute_expiry().is_none_or(|expiry| expiry > now()), "Offer expired or requires an unsupported quantity");
	let fixed = match offer.amount() {
		Some(OfferAmount::Bitcoin { amount_msats }) => Some(amount_msats),
		Some(_) => bail!("Currency-priced offers are not supported"),
		None => None,
	};
	let entered = amount_sat.map(msats).transpose()?;
	ensure!(entered.is_none() || fixed.is_none() || entered == fixed, "Entered amount differs from the offer’s fixed amount");
	let amount = fixed.or(entered).context("Enter an amount for this offer")?;
	ensure!(amount > 0 && amount % 1000 == 0, "Use a positive whole-satoshi offer amount");
	Ok((offer, amount))
}
pub(super) fn issued(invoice: &Invoice, offer: &Offer, amount_msat: u64) -> anyhow::Result<()> {
	let Invoice::Bolt12(invoice) = invoice else { bail!("The offer returned a different invoice format"); };
	invoice.validate_issuance(offer, Amount::from_sat(amount_msat / 1000)).context("Invoice does not match the requested offer")?;
	ensure!(invoice.offer_id() == Some(offer.id()), "Invoice belongs to a different offer");
	Ok(())
}
pub(super) fn payment_state(rows: &[Value], expected: &str) -> &'static str {
	let rows: Vec<_> = rows.iter().filter(|row| hash(&row["payment_hash"]).is_ok_and(|hash| hash.to_string() == expected)).collect();
	if rows.is_empty() { return "unknown"; }
	// An earlier failure must never clear a newer pending attempt.
	if rows.iter().any(|r| !matches!(r["status"].as_str().unwrap_or("").to_ascii_lowercase().as_str(), "complete" | "succeeded" | "failed")) { return "pending"; }
	if rows.iter().any(|r| matches!(r["status"].as_str().unwrap_or("").to_ascii_lowercase().as_str(), "complete" | "succeeded")) { "succeeded" } else { "failed" }
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn reserves_are_not_spendable_and_missing_is_not_zero() {
		let row = json!({"active":true,"local_balance":"230000","remote_balance":"1000000","local_constraints":{"chan_reserve_sat":"250000"},"remote_constraints":{"chan_reserve_sat":"10000"}});
		let result = balance(&json!({"channels":[row.clone()]}), Implementation::Lnd).unwrap();
		assert_eq!(result["sendable_msat"], "0"); assert_eq!(result["local_msat"], "230000000");
		let mut invalid = row; invalid.as_object_mut().unwrap().remove("local_constraints");
		assert!(balance(&json!({"channels":[invalid]}), Implementation::Lnd).is_err());
		assert!(number(&json!(true)).is_err()); assert!(number(&json!(-1)).is_err()); assert!(number(&json!(1.5)).is_err());
	}
	#[test]
	fn status_is_exact_hash_and_pending_wins() {
		let hash = "01".repeat(32);
		assert_eq!(payment_state(&[], &hash), "unknown");
		assert_eq!(payment_state(&[json!({"payment_hash":"02".repeat(32),"status":"SUCCEEDED"})], &hash), "unknown");
		assert_eq!(payment_state(&[json!({"payment_hash":hash,"status":"FAILED"}),json!({"payment_hash":hash,"status":"IN_FLIGHT"})], &hash), "pending");
		assert_eq!(payment_state(&[json!({"payment_hash":hash,"status":"SUCCEEDED"})], &hash), "succeeded");
	}
}
