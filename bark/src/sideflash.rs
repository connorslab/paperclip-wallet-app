//! Opt-in Sideflash wallet integration. Remote delivery is deliberately unavailable
//! until the server protocol can prove and persist safe delivery preparation.

use std::time::{SystemTime, UNIX_EPOCH};
use anyhow::{Context, ensure, bail};
use bitcoin::{Amount, secp256k1::{PublicKey, schnorr::Signature}};
use ark::sideflash::{Binding, ChainContext, Route, SideflashAddress};
use ark::lightning::Offer;
use lightning::util::ser::Writeable;
use crate::Wallet;
use crate::actions::WalletActionCheckpoint;
use crate::lightning::offers::OFFER_CHECKPOINT;
use server_rpc::protos;

fn now() -> anyhow::Result<u64> { Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs()) }

impl Wallet {
	/// Create or reuse a short-lived test binding. Uses the existing offer receive flow.
	pub async fn sideflash_receive(&self) -> anyhow::Result<String> {
		self.ensure_sideflash_offer().await?;
		let _guard = self.inner.lock_manager.try_lock(OFFER_CHECKPOINT).await.context("offer update in progress")?;
		let mut offer = self.lightning_offer().await?.context("Create a reusable offer first")?;
		ensure!(offer.active, "The reusable offer is disabled");
		if let Some(text) = &offer.sideflash {
			if let Ok(validated) = self.validate_sideflash_receive(text).await { return Ok(validated); }
		}
		let (binding, signature) = self.prepare_sideflash_receive(1, now()?.checked_add(86400).context("expiry overflow")?).await?;
		let (mut srv, _) = self.require_server().await?;
		let response = srv.client.acknowledge_sideflash(protos::SideflashBindingRequest {
			native_address: binding.address.to_string(), offer: binding.offer.clone(), revision: binding.revision,
			not_before: binding.not_before, expires: binding.expires, recipient_signature: signature.as_ref().to_vec(),
		}).await?.into_inner();
		let verified = self.validate_sideflash_receive(&response.address).await?;
		let received = SideflashAddress::decode(&verified)?;
		ensure!(received.version() == 1 && received.binding().revision == binding.revision
			&& received.binding().not_before == binding.not_before && received.binding().expires == binding.expires,
			"Server changed the binding request");
		offer.sideflash = Some(verified.clone());
		self.inner.db.upsert_wallet_action_checkpoint(&OFFER_CHECKPOINT.into(), &WalletActionCheckpoint::LightningOffer(offer)).await?;
		Ok(verified)
	}

	pub async fn sideflash_receive_info(&self) -> anyhow::Result<(String, String)> {
		let offer = self.ensure_sideflash_offer().await?;
		let recipient = self.peek_keypair(offer.key_index).await?.public_key();
		let server = self.require_ark_info().await?.server_pubkey;
		Ok((recipient.to_string(), server.to_string()))
	}

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
