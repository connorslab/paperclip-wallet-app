
use anyhow::Context;
use bitcoin::{Amount, Txid};
use log::{info, warn};

use ark::vtxo::VtxoRef;

use crate::Wallet;
use crate::actions::{DriveMode, WalletActionId};
use crate::actions::offboard::{Offboard, Progress, StartOffboardSpec, start_offboard};
use crate::movement::MovementId;

/// What an offboard call broadcast, and where it shows up in history.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OffboardResult {
	/// The offboard transaction the server built and we broadcast.
	pub txid: Txid,
	/// The movement that records this offboard. A caller can attach its own
	/// data to the right history entry with it.
	pub movement_id: MovementId,
}

impl Wallet {
	/// Returns every in-progress offboard checkpoint.
	pub async fn pending_offboards(&self) -> anyhow::Result<Vec<Offboard>> {
		let mut result = Vec::new();
		for cp in self.inner.db.get_all_wallet_action_checkpoints().await? {
			if let Some(o) = cp.into_offboard() {
				result.push(o);
			}
		}
		Ok(result)
	}

	/// Drives every pending offboard forward by one step (or to completion
	/// if it's ready). Each action runs to its next park independently;
	/// errors on one don't stop the others.
	pub async fn sync_pending_offboards(&self) -> anyhow::Result<()> {
		let pending = self.pending_offboards().await?;
		if pending.is_empty() {
			return Ok(());
		}
		info!("Syncing {} pending offboard(s)", pending.len());
		for action in pending {
			let id = action.id();
			if let Err(e) = self.drive_action::<Offboard>(&id, DriveMode::UntilParkOrDone).await {
				warn!("Failed to sync offboard {}: {:#}", id, e);
			}
		}
		Ok(())
	}

	/// Fetches the current checkpoint for the given action id, if any.
	pub async fn offboard_checkpoint(&self, id: &WalletActionId)
		-> anyhow::Result<Option<Offboard>>
	{
		Ok(self.inner.db.get_wallet_action_checkpoint(id).await?
			.and_then(|cp| cp.into_offboard()))
	}

	/// Send to an onchain address using your offchain balance.
	///
	/// We can only offboard whole VTXOs, so this kicks off an arkoor
	/// split first to produce an exact-sized vtxo plus change, then
	/// offboards the new vtxo.
	pub async fn send_onchain(
		&self,
		destination: bitcoin::Address,
		amount: Amount,
	) -> anyhow::Result<OffboardResult> {
		self.send_onchain_tracked(destination, amount, |_| Ok(())).await
	}

	/// Validate and persist a caller's review before the initial checkpoint can commit funds.
	pub async fn send_onchain_tracked<F>(
		&self, destination: bitcoin::Address, amount: Amount, before_submit: F,
	) -> anyhow::Result<OffboardResult>
	where F: FnOnce(&Offboard) -> anyhow::Result<()> + Send {
		let action = start_offboard(
			self, destination, StartOffboardSpec::SendOnchain { amount },
		).await?;
		self.run_offboard_tracked(action, before_submit).await
	}

	/// Offboard all VTXOs to a given [bitcoin::Address].
	pub async fn offboard_all(&self, address: bitcoin::Address) -> anyhow::Result<OffboardResult> {
		self.offboard_all_tracked(address, |_| Ok(())).await
	}

	/// Persist a caller's receipt before the offboard checkpoint can commit funds.
	pub async fn offboard_all_tracked<F>(&self, address: bitcoin::Address, before_submit: F) -> anyhow::Result<OffboardResult>
	where F: FnOnce(&str) -> anyhow::Result<()> + Send {
		let input_vtxos = self.spendable_vtxos().await?;
		let action = start_offboard(
			self, address, StartOffboardSpec::OffboardWhole { vtxos: input_vtxos },
		).await?;
		self.run_offboard_tracked(action, |action| before_submit(&action.id)).await
	}

	/// Offboard the given VTXOs to a given [bitcoin::Address].
	pub async fn offboard_vtxos<V: VtxoRef>(
		&self,
		vtxos: impl IntoIterator<Item = V>,
		address: bitcoin::Address,
	) -> anyhow::Result<OffboardResult> {
		self.offboard_vtxos_tracked(vtxos, address, |_| Ok(())).await
	}

	/// Keep the caller's selected inputs and validate its review before committing funds.
	pub async fn offboard_vtxos_tracked<V: VtxoRef, F>(
		&self, vtxos: impl IntoIterator<Item = V>, address: bitcoin::Address, before_submit: F,
	) -> anyhow::Result<OffboardResult>
	where F: FnOnce(&Offboard) -> anyhow::Result<()> + Send {
		let mut input_vtxos = vec![];
		for v in vtxos {
			let id = v.vtxo_id();
			let vtxo = match self.inner.db.get_wallet_vtxo(id).await? {
				Some(vtxo) => vtxo,
				_ => bail!("cannot find requested vtxo: {}", id),
			};
			input_vtxos.push(vtxo);
		}
		let action = start_offboard(
			self, address, StartOffboardSpec::OffboardWhole { vtxos: input_vtxos },
		).await?;
		self.run_offboard_tracked(action, before_submit).await
	}

	async fn run_offboard_tracked<F>(&self, action: Offboard, before_submit: F) -> anyhow::Result<OffboardResult>
	where F: FnOnce(&Offboard) -> anyhow::Result<()> + Send {
		let offboard_id = action.id();
		let mut checkpoint = self.try_lock_action::<Offboard>(&offboard_id).await?
			.context("offboard action already in progress")?;

		before_submit(&action)?;
		checkpoint.create(self, action).await
			.context("failed to persist initial offboard checkpoint")?;

		// Drive once synchronously to get past the server interaction; the
		// rest (confirmation polling) is left to sync_pending_offboards.
		self.drive_checkpoint(checkpoint, DriveMode::UntilParkOrDone).await?;

		match self.offboard_checkpoint(&offboard_id).await? {
			Some(o) => match o.progress {
				Progress::AwaitingConfirmations { offboard_txid, movement_id, .. } => {
					Ok(OffboardResult { txid: offboard_txid, movement_id })
				},
				// A transient error parked the action before broadcast (the
				// executor logged the error itself). The checkpoint
				// survives, so the next wallet sync re-drives it.
				other => bail!(
					"offboard {} could not complete yet (parked in {:?}); \
					it remains pending and will be retried on wallet sync",
					offboard_id, other,
				),
			},
			None => bail!("offboard {} finished without producing a txid", offboard_id),
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::actions::offboard::OffboardKind;

	#[tokio::test]
	async fn receipt_failure_prevents_offboard_checkpoint_creation_and_releases_lock() {
		let (wallet, _conn) = Wallet::offline_for_test().await;
		let action = Offboard {
			id: "ab".repeat(16),
			destination: bitcoin::Address::p2wsh(&bitcoin::ScriptBuf::new(), bitcoin::Network::Regtest).into_unchecked(),
			onchain_output_amount: Amount::from_sat(1000), committed_fee: Amount::from_sat(100), recovery_reserve: Amount::ZERO,
			committed_fee_rate: bitcoin::FeeRate::from_sat_per_vb(1).unwrap(),
			kind: OffboardKind::OffboardWhole { input_vtxo_ids: vec![] }, progress: Progress::Start,
		};
		let mut other = action.clone(); other.id = "cd".repeat(16);
		wallet.inner.db.upsert_wallet_action_checkpoint(&other.id, &other.clone().into()).await.unwrap();
		let mut observed = false;
		let error = wallet.run_offboard_tracked(action.clone(), |review| {
			assert_eq!(review, &action);
			observed = true;
			anyhow::bail!("synthetic receipt storage failure")
		}).await.unwrap_err();
		assert!(observed && error.to_string().contains("receipt storage failure"));
		assert!(wallet.offboard_checkpoint(&action.id).await.unwrap().is_none());
		assert!(wallet.movement_for_action(&action.id).await.unwrap().is_none());
		assert_eq!(wallet.offboard_checkpoint(&other.id).await.unwrap(), Some(other));
		assert!(wallet.try_lock_action::<Offboard>(&action.id).await.unwrap().is_some());
	}
}
