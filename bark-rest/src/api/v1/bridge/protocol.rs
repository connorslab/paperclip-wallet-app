//! Validate both sides before exposing a quote to any funding path.
use std::time::{Duration, Instant};

use anyhow::{Context, ensure};
use bark::lightning_invoice::Bolt11Invoice;
use bitcoin::{Network, hashes::{Hash, sha256}};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(super) enum Direction {
	#[serde(rename = "toSHA256")] PayBtc,
	#[serde(rename = "toBLAKE2b")] ReceiveXbt,
}
impl Direction {
	pub(super) fn text(self) -> &'static str { match self { Self::PayBtc => "toSHA256", Self::ReceiveXbt => "toBLAKE2b" } }
}

pub(super) struct Invoice {
	pub text: String,
	pub hash: String,
	pub msat: u64,
	pub expires: u64,
	pub xbt: bool,
}
impl Invoice {
	pub fn parse(text: &str) -> anyhow::Result<Self> {
		ensure!(text.len() <= 2000 && !text.chars().any(char::is_whitespace), "Use a fixed-amount mainnet BOLT11 invoice");
		let invoice: Bolt11Invoice = text.parse().context("Invalid bridge invoice")?;
		ensure!(invoice.network() == Network::Bitcoin, "The bridge supports mainnet invoices only");
		let msat = invoice.amount_milli_satoshis().context("Use a fixed-amount invoice")?;
		// The service uses JSON decimal sats. Restrict to exactly representable
		// millisatoshi integers before comparing its decimal amount commitment.
		ensure!(msat > 0 && msat <= 9_007_199_254_740_991, "Invoice amount is outside the supported range");
		let expires = invoice.duration_since_epoch().as_secs().checked_add(invoice.expiry_time().as_secs()).context("Invalid invoice expiry")?;
		let features = invoice.features();
		let xbt = features.is_some_and(|f| f.supports_blake2b_identity());
		ensure!(!xbt || features.is_some_and(|f| f.requires_blake2b_identity()), "XBT invoices must require their network identity");
		Ok(Self { text:invoice.to_string(),hash:invoice.payment_hash().to_string(),msat,expires,xbt })
	}
	pub fn target(&self, direction: Direction, now: u64) -> anyhow::Result<()> {
		ensure!(self.xbt == (direction == Direction::ReceiveXbt), "Invoice belongs to the wrong receiving network");
		ensure!(self.expires > now.saturating_add(300), "Use a new invoice with at least five minutes remaining");
		Ok(())
	}
}
#[derive(Serialize, Deserialize)]
pub(super) struct Availability { pub open: bool, pub min_sat: Option<f64>, pub max_sat: Option<f64> }
impl Availability {
	pub fn validate(&self) -> anyhow::Result<()> {
		ensure!(self.min_sat.is_none_or(|v| v.is_finite() && v >= 0.0) && self.max_sat.is_none_or(|v| v.is_finite() && v >= 0.0), "Invalid bridge limits");
		ensure!(self.min_sat.zip(self.max_sat).is_none_or(|(min,max)| min <= max), "Invalid bridge limits");
		Ok(())
	}
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Quote {
	pub hold_invoice: String,
	pub hash: String,
	pub sat: f64,
	pub pay_sat: u64,
	pub rate: f64,
	pub spread: f64,
	pub expires_at: u64,
	pub token: String,
}
impl Quote {
	pub fn validate(&self, target: &Invoice, direction: Direction, now: Option<u64>) -> anyhow::Result<Invoice> {
		let hold = Invoice::parse(&self.hold_invoice)?;
		ensure!(target.xbt == (direction == Direction::ReceiveXbt) && hold.xbt != target.xbt, "Bridge invoice has the wrong network");
		ensure!(self.hash == target.hash && hold.hash == target.hash, "Bridge invoice has a different payment hash");
		ensure!(self.sat.is_finite() && (self.sat * 1000.0 - target.msat as f64).abs() < 0.01, "Bridge quote changed the recipient amount");
		ensure!(self.pay_sat > 0 && self.pay_sat == hold.msat.div_ceil(1000), "Bridge quote changed the funding amount");
		ensure!(self.rate.is_finite() && self.rate > 0.0 && self.spread.is_finite() && self.spread >= 0.0, "Invalid bridge conversion");
		ensure!(self.token.len() == 32 && self.token.bytes().all(|b| b.is_ascii_hexdigit()), "Invalid bridge quote reference");
		ensure!(self.expires_at <= hold.expires && self.expires_at <= target.expires, "Bridge quote outlives its invoices");
		ensure!(now.is_none_or(|now| self.expires_at > now.saturating_add(5)), "Bridge quote expired. Review again before paying");
		Ok(hold)
	}
}
#[derive(Deserialize)]
pub(super) struct SwapStatus { pub state: String, pub preimage: Option<String> }
impl SwapStatus {
	pub fn verified_settlement(&self, hash: &str) -> bool {
		self.state == "settled" && self.preimage.as_ref().is_some_and(|text| {
			// Decode without ever formatting or returning a real preimage.
			let Ok(bytes) = text.parse::<sha256::Hash>() else { return false; };
			sha256::Hash::hash(bytes.as_ref()).to_string() == hash
		})
	}
	pub fn public_state(&self) -> &str {
		match self.state.as_str() {
			"quoted" | "offered" | "funded" | "paid" | "paying" | "settled" | "failing" | "aborting" | "expiring" | "failed" | "aborted" | "expired" | "lost" => &self.state,
			_ => "unknown",
		}
	}
}
#[derive(Deserialize)]
pub(super) struct Challenge { pub challenge: String, pub bits: u32 }
impl Challenge {
	pub async fn solve(&self, hash: &str) -> anyhow::Result<String> {
		ensure!(self.bits <= 22 && self.challenge.len() <= 200 && hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()), "Unsupported bridge verification challenge");
		let start = Instant::now();
		for n in 0..16_777_216 {
			if n % 4096 == 0 {
				ensure!(start.elapsed() < Duration::from_secs(45), "Bridge verification timed out");
				// Bounded batches yield to cancellation and other wallet work.
				tokio::task::yield_now().await;
			}
			let nonce = base36(n);
			let hash = sha256::Hash::hash(format!("{}:{hash}:{nonce}", self.challenge).as_bytes());
			let mut bits = 0;
			for byte in hash.as_byte_array() { bits += byte.leading_zeros(); if *byte != 0 { break; } }
			if bits >= self.bits { return Ok(nonce); }
		}
		bail!("Bridge verification timed out")
	}
}
fn base36(mut value: u32) -> String {
	let mut digits = Vec::new();
	loop {
		digits.push(b"0123456789abcdefghijklmnopqrstuvwxyz"[(value % 36) as usize]); value /= 36;
		if value == 0 { break; }
	}
	digits.reverse(); String::from_utf8(digits).expect("base36 is ASCII")
}
