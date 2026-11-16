use std::sync::Arc;

use axum::extract::State;
use axum::routing::{get, post};
use axum::{debug_handler, Json, Router};
use bitcoin::Amount;
use utoipa::OpenApi;

use crate::error::{self, HandlerResult, ContextExt};
use anyhow::{Context, ensure};
use bark::onchain::{OnchainWallet, OnchainWalletTrait};
use crate::ServerState;

#[derive(OpenApi)]
#[openapi(
	paths(
		prepare_review, commit_review,
		board_amount,
		board_all,
		get_pending_boards,
	),
	components(schemas(
		BoardApproval,
		bark_json::web::BoardRequest,
		bark_json::cli::PendingBoardInfo,
	)),
	tags((name = "boards", description = "Move on-chain bitcoin onto the Ark protocol."))
)]
pub struct BoardsApiDoc;

pub fn router() -> Router<Arc<ServerState>> {
	Router::new()
		.route("/prepare", post(prepare_review))
		.route("/commit", post(commit_review))
		.route("/board-amount", post(board_amount))
		.route("/board-all", post(board_all))
		.route("/pending", get(get_pending_boards))
}

#[utoipa::path(
	post,
	path = "/board-amount",
	summary = "Board a specific amount",
	request_body = bark_json::web::BoardRequest,
	responses(
		(status = 200, description = "Returns the board result", body = bark_json::cli::PendingBoardInfo),
		(status = 500, description = "Internal server error", body = error::InternalServerError)
	),
	description = "Moves the specified amount of bitcoin in the on-chain wallet onto the Ark \
		protocol. Creates and broadcasts a funding transaction, then returns the pending board \
		details. The resulting VTXO is not spendable off-chain until the funding transaction \
		reaches the number of on-chain confirmations required by the Ark server.",
	tag = "boards"
)]
#[debug_handler]
pub async fn board_amount(
	State(state): State<Arc<ServerState>>,
	Json(body): Json<bark_json::web::BoardRequest>,
) -> HandlerResult<Json<bark_json::cli::PendingBoardInfo>> {
	let wallet = state.require_wallet()?;
	let amount = Amount::from_sat(body.amount_sat);
	let board = wallet.board_amount(amount).await?;
	Ok(axum::Json(board.into()))
}

#[utoipa::path(
	post,
	path = "/board-all",
	summary = "Board all on-chain bitcoin",
	responses(
		(status = 200, description = "Returns the board result", body = bark_json::cli::PendingBoardInfo),
		(status = 500, description = "Internal server error", body = error::InternalServerError)
	),
	description = "Moves all bitcoin in the on-chain wallet onto the Ark protocol. Creates and \
		broadcasts a funding transaction that drains the on-chain balance into a single VTXO, \
		then returns the pending board details. The resulting VTXO is not spendable off-chain \
		until the funding transaction reaches the number of on-chain confirmations required by \
		the Ark server.",
	tag = "boards"
)]
#[debug_handler]
pub async fn board_all(
	State(state): State<Arc<ServerState>>,
) -> HandlerResult<Json<bark_json::cli::PendingBoardInfo>> {
	let wallet = state.require_wallet()?;
	let board = wallet.board_all().await?;
	Ok(axum::Json(board.into()))
}

#[utoipa::path(
	get,
	path = "/pending",
	summary = "List pending boards",
	responses(
		(status = 200, description = "Returns all pending boards", body = Vec<bark_json::cli::PendingBoardInfo>),
		(status = 500, description = "Internal server error")
	),
	description = "Returns all boards whose funding transactions have not yet reached the \
		number of on-chain confirmations required by the Ark server.",
	tag = "boards"
)]
#[debug_handler]
pub async fn get_pending_boards(
	State(state): State<Arc<ServerState>>,
) -> HandlerResult<Json<Vec<bark_json::cli::PendingBoardInfo>>> {
	let wallet = state.require_wallet()?;

	let boards = wallet.pending_boards().await?.into_iter()
		.map(bark_json::cli::PendingBoardInfo::from).collect();

	Ok(axum::Json(boards))
}

/// A review owns the exact funding transaction. Nothing is signed at preparation.
pub(crate) struct PreparedBoard {
	owner: Arc<tokio::sync::RwLock<dyn OnchainWalletTrait>>,
	psbt: bitcoin::Psbt,
	key: bitcoin::secp256k1::Keypair,
	expiry: bitcoin_ext::BlockHeight,
	amount: u64,
	total: u64,
	reserve: u64,
	created: std::time::Instant,
}
#[derive(serde::Deserialize, utoipa::ToSchema)]
struct BoardApproval {
	#[schema(value_type = String)] request_id: bitcoin::Txid,
	amount_sat: u64,
	total_sat: u64,
}

#[utoipa::path(post, path = "/prepare", tag = "boards", request_body = bark_json::web::BoardRequest,
	responses((status = 200, description = "Exact funding and recovery cost review", body = serde_json::Value)),
	description = "Prepare an unsigned funding transaction. Returns a 60-second request ID, board amount, net Ark amount, network fee, boarding fee and recovery reserve. Does not sign or broadcast.")]
async fn prepare_review(State(state): State<Arc<ServerState>>, Json(body): Json<bark_json::web::BoardRequest>) -> HandlerResult<Json<serde_json::Value>> {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let mut pending = state.board_review.lock().await; *pending = None;
	let wallet = state.require_wallet()?; let onchain = state.require_onchain()?;
	let result: anyhow::Result<(PreparedBoard, serde_json::Value)> = async {
		ensure!(body.amount_sat > 0, "Board amount must be positive");
		wallet.chain().require_funded_policy().await?;
		wallet.chain().update_fee_rates(wallet.config().fallback_fee_rate).await?;
		let estimate = wallet.estimate_board_offchain_fee(Amount::from_sat(body.amount_sat)).await?;
		let policy = ark::exit_policy::paperclip_funding();
		let anchor = estimate.fee.max(policy.anchor()).to_sat();
		let miner = policy.miner_fee().to_sat();
		let reserve = anchor.checked_add(miner).context("Recovery reserve overflow")?;
		let net = body.amount_sat.checked_sub(reserve).filter(|net| *net > 0).context("Board amount is below the recovery reserve")?;
		let (key, _) = wallet.derive_store_next_keypair().await?;
		let (address, expiry) = wallet.board_funding_address(&key).await?;
		let mut guard = onchain.write().await;
		guard.sync(wallet.chain()).await?;
		let psbt = guard.prepare_tx(&[(address, Amount::from_sat(body.amount_sat))], wallet.chain().fee_rates().await.regular).await?;
		let fee = psbt.fee()?.to_sat();
		let total = body.amount_sat.checked_add(fee).context("Board total overflow")?;
		let review = serde_json::json!({"request_id": psbt.unsigned_tx.compute_txid(), "board_amount_sat": body.amount_sat,
			"total_sat": total, "net_sat": net, "reserve_sat": reserve, "network_fee_sat": fee,
			"boarding_fee_sat": estimate.fee.to_sat(), "recovery_anchor_sat": anchor, "recovery_miner_fee_sat": miner});
		Ok((PreparedBoard { owner: onchain.clone(), psbt, key, expiry, amount: body.amount_sat, total, reserve, created: std::time::Instant::now() }, review))
	}.await;
	let (prepared, review) = result.badarg("Unable to prepare boarding review")?;
	*pending = Some(prepared);
	Ok(Json(review))
}

#[utoipa::path(post, path = "/commit", tag = "boards", request_body = BoardApproval,
	responses((status = 200, description = "Durably accepted board awaiting confirmations", body = serde_json::Value)),
	description = "Consume the exact reviewed funding transaction once after checking wallet identity, expiry, recovery costs and unspent inputs. Pending does not mean spendable. Check status after an uncertain response; never automatically submit a new board.")]
async fn commit_review(State(state): State<Arc<ServerState>>, Json(body): Json<BoardApproval>) -> HandlerResult<Json<serde_json::Value>> {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let prepared = state.board_review.lock().await.take().badarg("Review boarding first")?;
	let wallet = state.require_wallet()?; let onchain = state.require_onchain()?;
	let signed: anyhow::Result<bitcoin::Psbt> = async {
		ensure!(Arc::ptr_eq(&prepared.owner, &onchain), "Wallet changed; review again");
		prepared.validate_approval(&body)?;
		wallet.chain().require_funded_policy().await?;
		let fee = wallet.estimate_board_offchain_fee(Amount::from_sat(prepared.amount)).await?.fee;
		let policy = ark::exit_policy::paperclip_funding();
		let reserve = fee.max(policy.anchor()).checked_add(policy.miner_fee()).context("Recovery reserve overflow")?;
		ensure!(reserve.to_sat() == prepared.reserve, "Boarding costs changed; review again");
		let mut guard = onchain.write().await;
		guard.sync(wallet.chain()).await?;
		prepared.validate_approval(&body)?;
		let bdk = (&*guard as &dyn std::any::Any).downcast_ref::<OnchainWallet>().context("Unsupported on-chain wallet")?;
		let unspent: std::collections::HashSet<_> = bdk.list_unspent().iter().map(|u| u.outpoint).collect();
		ensure!(prepared.psbt.unsigned_tx.input.iter().all(|i| unspent.contains(&i.previous_output)), "Funding inputs changed; review again");
		// Like Wallet::board, sign without registering a spend before server cosigning.
		// The board action persists recovery state before broadcasting and records funding.
		guard.sign_psbt(prepared.psbt.clone()).await
	}.await;
	let signed = signed.badarg("Unable to approve boarding")?;
	let board = wallet.board_psbt(signed, prepared.key, prepared.expiry).await?;
	Ok(Json(serde_json::json!({"state": "pending", "amount_sat": board.amount.to_sat(), "txid": board.funding_tx.compute_txid()})))
}

impl PreparedBoard {
	fn validate_approval(&self, approval: &BoardApproval) -> anyhow::Result<()> {
		validate_approval(&self.psbt, self.amount, self.total, self.created, approval)
	}
}

fn validate_approval(psbt: &bitcoin::Psbt, amount: u64, total: u64, created: std::time::Instant, approval: &BoardApproval) -> anyhow::Result<()> {
	ensure!(created.elapsed() < std::time::Duration::from_secs(60), "Boarding review expired; review again");
	ensure!(psbt.unsigned_tx.compute_txid() == approval.request_id && amount == approval.amount_sat
		&& total == approval.total_sat && amount.checked_add(psbt.fee()?.to_sat()) == Some(total), "Reviewed boarding changed");
	Ok(())
}

#[cfg(test)]
mod review_tests {
	use super::*;
	#[test]
	fn boarding_approval_binds_exact_transaction_cost_and_expiry() {
		let tx = bitcoin::Transaction { version: bitcoin::transaction::Version::TWO, lock_time: bitcoin::absolute::LockTime::ZERO,
			input: vec![bitcoin::TxIn::default()], output: vec![bitcoin::TxOut { value: Amount::from_sat(25_000), script_pubkey: bitcoin::ScriptBuf::new() }] };
		let mut psbt = bitcoin::Psbt::from_unsigned_tx(tx).unwrap();
		psbt.inputs[0].witness_utxo = Some(bitcoin::TxOut { value: Amount::from_sat(26_000), script_pubkey: bitcoin::ScriptBuf::new() });
		let now = std::time::Instant::now();
		let mut approval = BoardApproval { request_id: psbt.unsigned_tx.compute_txid(), amount_sat: 25_000, total_sat: 26_000 };
		assert!(validate_approval(&psbt, 25_000, 26_000, now, &approval).is_ok());
		approval.total_sat = 25_999;
		assert!(validate_approval(&psbt, 25_000, 26_000, now, &approval).is_err());
		approval.total_sat = 26_000; approval.amount_sat = 25_001;
		assert!(validate_approval(&psbt, 25_000, 26_000, now, &approval).is_err());
		approval.amount_sat = 25_000;
		assert!(validate_approval(&psbt, 25_000, 26_000, now - std::time::Duration::from_secs(61), &approval).is_err());
		psbt.unsigned_tx.output[0].script_pubkey = bitcoin::ScriptBuf::from_bytes(vec![0x51]);
		assert!(validate_approval(&psbt, 25_000, 26_000, now, &approval).is_err());
		approval.request_id = psbt.unsigned_tx.compute_txid();
		psbt.inputs[0].witness_utxo.as_mut().unwrap().value = Amount::from_sat(27_000);
		assert!(validate_approval(&psbt, 25_000, 26_000, now, &approval).is_err());
	}
}
