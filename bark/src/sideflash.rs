//! Opt-in Sideflash wallet integration. Remote delivery is deliberately unavailable
//! until the server protocol can prove and persist safe delivery preparation.

use std::time::{SystemTime, UNIX_EPOCH};
use anyhow::{Context, ensure, bail};
use bitcoin::{Amount, secp256k1::{PublicKey, schnorr::Signature}};
use ark::sideflash::{Binding, ChainContext, Route, SideflashAddress};
use ark::lightning::Offer;
use lightning::util::ser::Writeable;
use crate::Wallet;

fn now() -> anyhow::Result<u64> { Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs()) }

impl Wallet {
	/// Prepare a compact v1 recipient authorization for the current wallet-owned offer.
	/// This is not a usable receive address until the server acknowledges it.
	/// Keep one native destination per persistent offer by using its stored key index.
	pub async fn prepare_sideflash_receive(&self, revision: u64, expires: u64) -> anyhow::Result<(Binding, Signature)> {
		let time = now()?;
		ensure!(expires > time, "Sideflash expiry must be in the future");
		let offer = self.lightning_offer().await?.context("Create an active reusable offer first")?;
		ensure!(offer.active, "The reusable offer is disabled");
		let info = self.require_ark_info().await?;
		let address = self.peek_address(offer.key_index).await?;
		let binding = Binding { chain: ChainContext::xbt(self.properties().await?.network)?,
			server: info.server_pubkey, address, offer: offer.offer.parse::<Offer>().map_err(|e| anyhow::anyhow!("Invalid stored offer: {e:?}"))?.encode(),
			revision, not_before: time, expires };
		let signature = binding.authorize(&self.peek_keypair(offer.key_index).await?, time)?;
		Ok((binding, signature))
	}

	/// Accept v0 or v1 acknowledged addresses for this wallet's current native destination
	/// and active reusable offer. No secret key is given to the server.
	pub async fn validate_sideflash_receive(&self, text: &str) -> anyhow::Result<String> {
		let offer = self.lightning_offer().await?.context("No reusable offer")?;
		ensure!(offer.active, "The reusable offer is disabled");
		let info = self.require_ark_info().await?;
		let encoded = SideflashAddress::decode(text)?;
		let chain = ChainContext::xbt(self.properties().await?.network)?;
		ensure!(encoded.verified_offer(chain, info.server_pubkey, now()?)? == offer.offer.parse::<Offer>().map_err(|e| anyhow::anyhow!("Invalid stored offer: {e:?}"))?.encode(),
			"Sideflash offer does not belong to this wallet");
		ensure!(encoded.route(chain, info.server_pubkey, info.server_pubkey, now()?)? ==
			Route::NativeArk(self.peek_address(offer.key_index).await?.to_string()), "Sideflash recipient does not belong to this wallet");
		Ok(encoded.encode()?)
	}

	/// Send a same-server Sideflash payment through the existing persisted Ark path.
	/// The caller supplies an authenticated destination server key and explicit debit cap.
	/// Never downgrade remote Sideflash to an unprepared Lightning payment.
	pub async fn send_sideflash(&self, text: &str, destination_server: PublicKey, amount: Amount, max_total: Amount) -> anyhow::Result<()> {
		ensure!(amount > Amount::ZERO && max_total >= amount, "Invalid Sideflash amount or debit cap");
		let info = self.require_ark_info().await?;
		let address = SideflashAddress::decode(text)?;
		match address.route(ChainContext::xbt(self.properties().await?.network)?, destination_server, info.server_pubkey, now()?)? {
			Route::NativeArk(native) => self.send_arkoor_payment_with_max_cost(&native.parse()?, amount, Some(max_total)).await,
			Route::LightningOffer(_) => bail!("Cross-server Sideflash delivery is not enabled; no payment was initiated"),
		}
	}
}
