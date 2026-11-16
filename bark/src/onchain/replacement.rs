//! Reviewed ordinary-payment replacements. Network history never grants authority to sign.
use std::time::{Duration, Instant};

use anyhow::{Context, ensure};
use bitcoin::{Address, Amount, Psbt, Transaction, TxOut, Txid};
use serde::{Deserialize, Serialize};

use super::{OnchainWallet, OnchainWalletTrait, qr};

#[derive(Clone, Serialize, Deserialize)]
pub struct AuthorizedSend {
	pub transaction: Transaction,
	pub change_index: Option<usize>,
	pub replaces: Option<Txid>,
	#[serde(default)] pub replaced_by: Option<Txid>,
}

#[derive(Clone, Serialize)]
pub struct ReplacementReview {
	pub original_txid: Txid,
	pub replacement_txid: Txid,
	pub old_fee_sat: u64,
	pub new_fee_sat: u64,
	pub additional_fee_sat: u64,
	pub recipients: Vec<Recipient>,
}
#[derive(Clone, Serialize)]
pub struct Recipient { pub address: String, pub amount_sat: u64 }

pub struct PreparedReplacement {
	psbt: Psbt,
	original: AuthorizedSend,
	created: Instant,
	pub review: ReplacementReview,
}

fn unsigned(tx: &Transaction) -> Transaction {
	let mut tx = tx.clone();
	for input in &mut tx.input { input.script_sig = bitcoin::ScriptBuf::new(); input.witness.clear(); }
	tx
}

impl OnchainWallet {
	/// Repair the crash window between recording a signed payment and BDK persistence.
	/// Existing graph entries retain their network observations; never revive an evicted tx.
	pub(super) async fn recover_authorized_sends(&mut self) -> anyhow::Result<()> {
		let records = self.db.pending_authorized_sends().await?;
		for record in records {
			if self.inner.tx_graph().get_tx(record.transaction.compute_txid()).is_none() {
				self.inner.apply_unconfirmed_txs([(record.transaction, bark_runtime::timestamp_secs())]);
			}
		}
		self.persist().await
	}

	/// Call only after the user approves an ordinary send. Board, exit and CoinJoin
	/// transactions must never acquire replacement authority through this entry point.
	pub async fn finish_reviewed_send(&mut self, psbt: Psbt, recipients: &[(Address, Amount)]) -> anyhow::Result<Transaction> {
		let mut remaining: Vec<TxOut> = recipients.iter().map(|(a, v)| TxOut { value: *v, script_pubkey: a.script_pubkey() }).collect();
		ensure!(!remaining.is_empty(), "Payment has no recipients");
		let mut change_index = None;
		for (index, output) in psbt.unsigned_tx.output.iter().enumerate() {
			if let Some(position) = remaining.iter().position(|wanted| wanted == output) { remaining.remove(position); }
			else {
				ensure!(change_index.is_none() && self.inner.is_mine(output.script_pubkey.clone()), "Unexpected payment output");
				change_index = Some(index);
			}
		}
		ensure!(remaining.is_empty(), "Payment recipient changed");
		let signed = OnchainWalletTrait::sign_psbt(self, psbt).await?.extract_tx()?;
		let record = AuthorizedSend { transaction: signed.clone(), change_index, replaces: None, replaced_by: None };
		self.db.store_authorized_send(&record).await?;
		self.register_tx(&signed).await?;
		Ok(signed)
	}

	async fn replacement_original(&self, txid: Txid) -> anyhow::Result<(AuthorizedSend, Psbt)> {
		let record = self.db.authorized_send(txid).await?.context("No local payment approval is available for this transaction. Older, received, Ark and collaborative transactions cannot be fee-bumped here.")?;
		if let Some(id) = record.replaced_by { anyhow::bail!("A replacement is already recorded: {id}. Refresh activity and check this transaction instead."); }
		ensure!(record.transaction.compute_txid() == txid, "Stored payment identity changed");
		let current = self.inner.get_tx(txid).context("Original transaction is not active; refresh its status")?;
		ensure!(!current.chain_position.is_confirmed(), "This transaction is already confirmed");
		ensure!(*current.tx_node.tx == record.transaction, "Network history differs from the authorized payment");
		ensure!(record.transaction.version == bitcoin::transaction::Version::TWO, "Only ordinary version 2 payments can be replaced");
		ensure!(record.transaction.input.iter().any(|i| i.sequence.is_rbf()), "This transaction does not signal replacement");
		ensure!(!self.inner.transactions().any(|tx| tx.tx_node.tx.input.iter().any(|i| i.previous_output.txid == txid)), "A transaction spends this payment's outputs; replacement is unavailable");
		let mut proof = Psbt::from_unsigned_tx(unsigned(&record.transaction))?;
		for (input, vin) in proof.inputs.iter_mut().zip(&record.transaction.input) {
			let parent = self.inner.tx_graph().get_tx(vin.previous_output.txid).context("Previous transaction is unavailable")?;
			let previous = parent.output.get(vin.previous_output.vout as usize).context("Previous output is unavailable")?;
			ensure!(self.inner.is_mine(previous.script_pubkey.clone()), "Replacement requires every input to belong to this wallet");
			ensure!(previous.script_pubkey.is_p2tr() || previous.script_pubkey.is_p2wpkh(), "Unsupported replacement input");
			input.witness_utxo = Some(previous.clone()); input.non_witness_utxo = Some((*parent).clone());
		}
		qr::prepare(&mut proof)?;
		qr::signed_transaction(&proof, &bitcoin::consensus::serialize(&record.transaction))
			.context("Original payment signatures are invalid; no replacement was signed")?;
		Ok((record, proof))
	}

	pub async fn prepare_replacement(&mut self, txid: Txid, new_fee_sat: u64) -> anyhow::Result<PreparedReplacement> {
		let (original, proof) = self.replacement_original(txid).await?;
		let old_fee_sat = proof.fee()?.to_sat();
		let new_fee_sat = if new_fee_sat == 0 { old_fee_sat.checked_mul(2).context("Fee overflow")? } else { new_fee_sat };
		ensure!(new_fee_sat > old_fee_sat && new_fee_sat <= 1_000_000, "Choose a higher total fee, up to 1,000,000 sats");
		let change_index = original.change_index.context("No change output is available to pay the extra fee")?;
		let change = original.transaction.output.get(change_index).context("Stored change output is missing")?;
		let recipients: Vec<TxOut> = original.transaction.output.iter().enumerate().filter(|(i, _)| *i != change_index).map(|(_, out)| out.clone()).collect();
		let paid = recipients.iter().try_fold(0u64, |sum, out| sum.checked_add(out.value.to_sat())).context("Payment amount overflow")?;
		ensure!(new_fee_sat <= paid, "The replacement fee must not exceed the recipient amount");
		ensure!(self.inner.is_mine(change.script_pubkey.clone()), "Change does not belong to this wallet");
		let sequence = original.transaction.input.first().context("Original inputs are missing")?.sequence;
		ensure!(original.transaction.input.iter().all(|input| input.sequence == sequence), "Mixed input sequences cannot be replaced here");
		let mut builder = self.inner.build_fee_bump(txid)?;
		builder.manually_selected_only().fee_absolute(Amount::from_sat(new_fee_sat))
			.drain_to(change.script_pubkey.clone()).ordering(bdk_wallet::TxOrdering::Untouched)
			.nlocktime(original.transaction.lock_time).set_exact_sequence(sequence);
		let psbt = builder.finish()?;
		validate_replacement(&original, &psbt, old_fee_sat, new_fee_sat)?;
		let recipients = recipients.into_iter().map(|out| Ok(Recipient {
			address: Address::from_script(&out.script_pubkey, self.inner.network())?.to_string(), amount_sat: out.value.to_sat(),
		})).collect::<anyhow::Result<Vec<_>>>()?;
		let review = ReplacementReview { original_txid: txid, replacement_txid: psbt.unsigned_tx.compute_txid(), old_fee_sat, new_fee_sat,
			additional_fee_sat: new_fee_sat - old_fee_sat, recipients };
		Ok(PreparedReplacement { psbt, original, created: Instant::now(), review })
	}

	/// Consume the prepared transaction once. Sync before calling while holding the wallet lock.
	pub async fn commit_replacement(&mut self, prepared: PreparedReplacement, replacement_txid: Txid, new_fee_sat: u64) -> anyhow::Result<Transaction> {
		self.commit_replacement_tracked(prepared, replacement_txid, new_fee_sat, || Ok(())).await
	}

	/// Save the submission receipt after validation, before persisting a signed spend.
	pub async fn commit_replacement_tracked<F>(&mut self, prepared: PreparedReplacement, replacement_txid: Txid, new_fee_sat: u64, before_submit: F) -> anyhow::Result<Transaction>
	where F: FnOnce() -> anyhow::Result<()> + Send {
		ensure!(prepared.created.elapsed() < Duration::from_secs(60), "Fee review expired; review again");
		ensure!(prepared.review.replacement_txid == replacement_txid && prepared.review.new_fee_sat == new_fee_sat, "Reviewed replacement changed");
		let (current, proof) = self.replacement_original(prepared.review.original_txid).await?;
		ensure!(current.transaction == prepared.original.transaction && current.change_index == prepared.original.change_index, "Original payment changed");
		validate_replacement(&current, &prepared.psbt, proof.fee()?.to_sat(), new_fee_sat)?;
		let tx = OnchainWalletTrait::sign_psbt(self, prepared.psbt).await?.extract_tx()?;
		ensure!(tx.compute_txid() == replacement_txid, "Signed replacement changed");
		let change_script = &current.transaction.output[current.change_index.context("Missing change")?].script_pubkey;
		let change_index = tx.output.iter().position(|out| &out.script_pubkey == change_script);
		before_submit()?;
		self.db.store_authorized_send(&AuthorizedSend { transaction: tx.clone(), change_index,
			replaces: Some(prepared.review.original_txid), replaced_by: None }).await?;
		self.register_tx(&tx).await?;
		Ok(tx)
	}
}

fn validate_replacement(original: &AuthorizedSend, psbt: &Psbt, old_fee: u64, new_fee: u64) -> anyhow::Result<()> {
	let tx = &psbt.unsigned_tx;
	let change_index = original.change_index.context("Missing original change")?;
	ensure!(tx.version == original.transaction.version && tx.lock_time == original.transaction.lock_time, "Replacement changed transaction constraints");
	ensure!(tx.input == unsigned(&original.transaction).input, "Replacement changed inputs or sequences");
	let change = original.transaction.output.get(change_index).context("Missing original change")?;
	let mut expected = original.transaction.output.clone(); expected.remove(change_index);
	let mut actual = tx.output.clone();
	let matching: Vec<usize> = actual.iter().enumerate().filter(|(_, out)| out.script_pubkey == change.script_pubkey).map(|(i, _)| i).collect();
	ensure!(matching.len() == 1, "Replacement must retain exactly one change output");
	let new_change = actual.remove(matching[0]);
	ensure!(actual == expected, "Replacement changed recipients or amounts");
	ensure!(new_fee > old_fee && new_change.value.to_sat().checked_add(new_fee - old_fee) == Some(change.value.to_sat()), "Replacement debit differs from the reviewed fee");
	ensure!(psbt.fee()?.to_sat() == new_fee, "Replacement fee differs from review");
	Ok(())
}

#[cfg(all(test, feature = "sqlite"))]
mod tests {
	use super::*;
	use std::sync::Arc;
	use bitcoin::{FeeRate, Network};
	use crate::persist::{BarkPersister, sqlite::SqliteClient};

	async fn funded(db: Arc<SqliteClient>, segwit: bool) -> OnchainWallet {
		let mut wallet = if segwit { OnchainWallet::load_coinjoin(Network::Regtest, [42;64], db).await.unwrap() }
			else { OnchainWallet::load_or_create(Network::Regtest, [42;64], db).await.unwrap() };
		bdk_wallet::test_utils::insert_checkpoint(&mut wallet.inner, bdk_wallet::chain::BlockId { height: 1000, hash: "00".repeat(32).parse().unwrap() });
		bdk_wallet::test_utils::receive_output_in_latest_block(&mut wallet.inner, Amount::from_sat(500_000));
		wallet.persist().await.unwrap();
		wallet
	}
	fn recipient() -> Address {
		let key = bitcoin::secp256k1::SecretKey::from_slice(&[31;32]).unwrap().public_key(&bitcoin::secp256k1::Secp256k1::new());
		Address::p2wpkh(&bitcoin::CompressedPublicKey(key), Network::Regtest)
	}
	async fn payment(wallet: &mut OnchainWallet) -> Transaction {
		let recipients = [(recipient(), Amount::from_sat(100_000))];
		let psbt = wallet.prepare_tx(&recipients, FeeRate::from_sat_per_vb(2).unwrap()).await.unwrap();
		wallet.finish_reviewed_send(psbt, &recipients).await.unwrap()
	}

	#[tokio::test]
	async fn replacement_preserves_payment_and_survives_restart() {
		for segwit in [false, true] {
			let directory = tempfile::tempdir().unwrap();
			let db = Arc::new(SqliteClient::open(directory.path().join("wallet.sqlite")).unwrap());
			let mut wallet = funded(db.clone(), segwit).await;
			let original = payment(&mut wallet).await;
			let prepared = wallet.prepare_replacement(original.compute_txid(), 2000).await.unwrap();
			assert_eq!(prepared.review.recipients[0].address, recipient().to_string());
			assert_eq!(prepared.review.recipients[0].amount_sat, 100_000);
			let id = prepared.review.replacement_txid;
			let replacement = wallet.commit_replacement(prepared, id, 2000).await.unwrap();
			assert_ne!(replacement.compute_txid(), original.compute_txid());
			// Model a later network observation of the replacement. A local signature
			// alone must not evict the original from canonical history.
			wallet.inner.apply_unconfirmed_txs([(replacement.clone(), bark_runtime::timestamp_secs() + 1)]);
			wallet.persist().await.unwrap();
			assert!(wallet.prepare_replacement(original.compute_txid(), 3000).await.is_err());
			drop(wallet);
			let mut wallet = if segwit { OnchainWallet::load_coinjoin(Network::Regtest, [42;64], db.clone()).await.unwrap() }
				else { OnchainWallet::load_or_create(Network::Regtest, [42;64], db.clone()).await.unwrap() };
			assert!(wallet.prepare_replacement(original.compute_txid(), 3000).await.is_err());
			let next = wallet.prepare_replacement(replacement.compute_txid(), 4000).await.unwrap();
			assert_eq!(next.review.old_fee_sat, 2000);
			assert_eq!(db.authorized_send(original.compute_txid()).await.unwrap().unwrap().replaced_by, Some(replacement.compute_txid()));
		}
	}

	#[tokio::test]
	async fn receipt_failure_never_persists_a_replacement() {
		let directory = tempfile::tempdir().unwrap();
		let db = Arc::new(SqliteClient::open(directory.path().join("wallet.sqlite")).unwrap());
		let mut wallet = funded(db.clone(), false).await;
		let original = payment(&mut wallet).await;
		let prepared = wallet.prepare_replacement(original.compute_txid(),2000).await.unwrap();
		let id = prepared.review.replacement_txid;
		let error = wallet.commit_replacement_tracked(prepared,id,2000,|| anyhow::bail!("receipt write failed")).await.unwrap_err();
		assert!(error.to_string().contains("receipt write failed"));
		assert!(db.authorized_send(id).await.unwrap().is_none());
		assert!(db.authorized_send(original.compute_txid()).await.unwrap().unwrap().replaced_by.is_none());
		assert!(wallet.prepare_replacement(original.compute_txid(),2000).await.is_ok());
	}

	#[tokio::test]
	async fn replacement_recovers_signed_payment_after_journal_only_crash() {
		let directory = tempfile::tempdir().unwrap();
		let db = Arc::new(SqliteClient::open(directory.path().join("wallet.sqlite")).unwrap());
		let mut wallet = funded(db.clone(), false).await;
		let recipients = [(recipient(), Amount::from_sat(100_000))];
		let psbt = wallet.prepare_tx(&recipients, FeeRate::from_sat_per_vb(2).unwrap()).await.unwrap();
		let change_index = psbt.unsigned_tx.output.iter().position(|out| wallet.inner.is_mine(out.script_pubkey.clone()));
		let tx = OnchainWalletTrait::sign_psbt(&mut wallet, psbt).await.unwrap().extract_tx().unwrap();
		let id = tx.compute_txid();
		db.store_authorized_send(&AuthorizedSend { transaction: tx.clone(), change_index, replaces: None, replaced_by: None }).await.unwrap();
		assert!(wallet.inner.tx_graph().get_tx(id).is_none());
		drop(wallet);
		let mut wallet = OnchainWallet::load_or_create(Network::Regtest, [42;64], db.clone()).await.unwrap();
		assert_eq!(*wallet.inner.tx_graph().get_tx(id).unwrap(), tx);
		assert!(wallet.prepare_replacement(id, 2000).await.is_ok());
		// Reopening an already persisted record must not duplicate or change it.
		drop(wallet);
		let wallet = OnchainWallet::load_or_create(Network::Regtest, [42;64], db).await.unwrap();
		assert_eq!(*wallet.inner.tx_graph().get_tx(id).unwrap(), tx);
	}

	#[tokio::test]
	async fn replacement_rejects_changed_review_and_expired_approval() {
		let directory = tempfile::tempdir().unwrap();
		let db = Arc::new(SqliteClient::open(directory.path().join("wallet.sqlite")).unwrap());
		let mut wallet = funded(db, false).await;
		let original = payment(&mut wallet).await;
		let mut prepared = wallet.prepare_replacement(original.compute_txid(), 2000).await.unwrap();
		let id = prepared.review.replacement_txid;
		assert!(wallet.commit_replacement(prepared, id, 2001).await.is_err());
		prepared = wallet.prepare_replacement(original.compute_txid(), 2000).await.unwrap();
		prepared.created = Instant::now() - Duration::from_secs(61);
		assert!(wallet.commit_replacement(prepared, id, 2000).await.is_err());
		assert!(wallet.prepare_replacement(original.compute_txid(), 1).await.is_err());
		assert!(wallet.prepare_replacement(original.compute_txid(), 100_001).await.is_err());
	}

	#[tokio::test]
	async fn replacement_rejects_unsigned_history_injection_and_protocol_transactions() {
		let directory = tempfile::tempdir().unwrap();
		let db = Arc::new(SqliteClient::open(directory.path().join("wallet.sqlite")).unwrap());
		let mut wallet = funded(db.clone(), false).await;
		let recipients = [(recipient(), Amount::from_sat(100_000))];
		let psbt = wallet.prepare_tx(&recipients, FeeRate::from_sat_per_vb(2).unwrap()).await.unwrap();
		let forged = psbt.unsigned_tx.clone();
		wallet.register_tx(&forged).await.unwrap();
		assert!(wallet.prepare_replacement(forged.compute_txid(), 2000).await.is_err());
		// Even an invalid local approval record cannot bypass signature verification.
		db.store_authorized_send(&AuthorizedSend { transaction: forged.clone(), change_index: Some(1), replaces: None, replaced_by: None }).await.unwrap();
		assert!(wallet.prepare_replacement(forged.compute_txid(), 2000).await.err().unwrap().to_string().contains("signatures"));
	}

	#[tokio::test]
	async fn replacement_rejects_output_input_and_fee_tampering() {
		let directory = tempfile::tempdir().unwrap();
		let db = Arc::new(SqliteClient::open(directory.path().join("wallet.sqlite")).unwrap());
		let mut wallet = funded(db, false).await;
		let original = payment(&mut wallet).await;
		let prepared = wallet.prepare_replacement(original.compute_txid(), 2000).await.unwrap();
		let check = |psbt: &Psbt| validate_replacement(&prepared.original, psbt, prepared.review.old_fee_sat, 2000);
		let mut altered = prepared.psbt.clone(); altered.unsigned_tx.output[0].value = Amount::from_sat(1);
		assert!(check(&altered).is_err());
		let mut altered = prepared.psbt.clone(); altered.unsigned_tx.output[0].script_pubkey = bitcoin::ScriptBuf::new();
		assert!(check(&altered).is_err());
		let mut altered = prepared.psbt.clone(); altered.unsigned_tx.input[0].previous_output.vout += 1;
		assert!(check(&altered).is_err());
		let mut altered = prepared.psbt.clone(); altered.inputs[0].witness_utxo.as_mut().unwrap().value = Amount::from_sat(500_001);
		assert!(check(&altered).is_err());
	}
	#[tokio::test]
	async fn replacement_rejects_confirmed_spent_and_drain_payments() {
		let directory = tempfile::tempdir().unwrap();
		let db = Arc::new(SqliteClient::open(directory.path().join("wallet.sqlite")).unwrap());
		let mut wallet = funded(db.clone(), false).await;
		let original = payment(&mut wallet).await;
		// A signed child makes replacing its parent unavailable.
		let child = payment(&mut wallet).await;
		assert!(child.input.iter().any(|i| i.previous_output.txid == original.compute_txid()));
		assert!(wallet.prepare_replacement(original.compute_txid(), 2000).await.err().unwrap().to_string().contains("spends"));
		let anchor = bdk_wallet::chain::ConfirmationBlockTime { block_id: wallet.inner.latest_checkpoint().block_id(), confirmation_time: 1 };
		let mut update = bdk_wallet::Update::default();
		update.tx_update.anchors.insert((anchor, child.compute_txid()));
		wallet.inner.apply_update(update).unwrap();
		assert!(wallet.prepare_replacement(child.compute_txid(), 2000).await.err().unwrap().to_string().contains("confirmed"));
		let psbt = wallet.prepare_drain_tx(recipient(), FeeRate::from_sat_per_vb(2).unwrap()).await.unwrap();
		let amount = psbt.unsigned_tx.output[0].value;
		let drain = wallet.finish_reviewed_send(psbt, &[(recipient(), amount)]).await.unwrap();
		assert!(wallet.prepare_replacement(drain.compute_txid(), 2000).await.err().unwrap().to_string().contains("change"));
	}

	#[tokio::test]
	async fn replacement_authority_is_account_scoped_and_single_use() {
		let directory = tempfile::tempdir().unwrap();
		let db = Arc::new(SqliteClient::open(directory.path().join("wallet.sqlite")).unwrap());
		let mut wallet = funded(db.clone(), false).await;
		let original = payment(&mut wallet).await;
		let other = db.as_ref().clone().with_bdk_namespace("other-account");
		assert!(other.authorized_send(original.compute_txid()).await.unwrap().is_none());
		let first = wallet.prepare_replacement(original.compute_txid(), 2000).await.unwrap();
		let second = wallet.prepare_replacement(original.compute_txid(), 3000).await.unwrap();
		let first_id = first.review.replacement_txid; let second_id = second.review.replacement_txid;
		wallet.commit_replacement(first, first_id, 2000).await.unwrap();
		assert!(wallet.commit_replacement(second, second_id, 3000).await.is_err());
		// The database also enforces this when two processes try to reserve a replacement.
		let mut duplicate = db.authorized_send(first_id).await.unwrap().unwrap();
		duplicate.transaction.output[0].value = Amount::from_sat(99999);
		assert!(db.store_authorized_send(&duplicate).await.is_err());
	}

}
