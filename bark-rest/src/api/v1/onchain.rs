use std::str::FromStr;
use std::sync::Arc;

use anyhow::Context;
use axum::extract::State;
use axum::routing::{get, post};
use axum::{debug_handler, Json, Router};
use bitcoin::Amount;
use tracing::info;
use utoipa::OpenApi;

use bark::onchain::{OnchainWallet, OnchainWalletTrait};

use crate::ServerState;
use crate::error::{self, HandlerResult, ContextExt};

/// Cast an [OnchainWalletTrait] to an [OnchainWallet]
fn cast_bdk(w: &dyn OnchainWalletTrait) -> anyhow::Result<&OnchainWallet> {
	(w as &dyn std::any::Any).downcast_ref::<OnchainWallet>()
		.context("onchain wallet is not a BDK wallet")
}

/// Cast a mutable [OnchainWalletTrait] to an [OnchainWallet]
fn cast_bdk_mut(w: &mut dyn OnchainWalletTrait) -> anyhow::Result<&mut OnchainWallet> {
	(w as &mut dyn std::any::Any).downcast_mut::<OnchainWallet>()
		.context("onchain wallet is not a BDK wallet")
}

pub fn router() -> Router<Arc<ServerState>> {
	Router::new()
		.route("/message/sign", post(onchain_message_sign))
		.route("/message/verify", post(onchain_message_verify))
		.route("/replacement/prepare", post(replacement_prepare))
		.route("/replacement/commit", post(replacement_commit))
		.route("/balance", get(onchain_balance))
		.route("/addresses/next", post(onchain_address))
		.route("/send", post(onchain_send))
		.route("/send/prepare", post(send_prepare))
		.route("/send/commit", post(send_commit))
		.route("/send-many", post(onchain_send_many))
		.route("/drain", post(onchain_drain))
		.route("/utxos", get(onchain_utxos))
		.route("/transactions", get(onchain_transactions))
		.route("/sync", post(onchain_sync))
}

pub(crate) struct PreparedSend {
	owner: Arc<tokio::sync::RwLock<dyn OnchainWalletTrait>>,
	psbt: bitcoin::Psbt,
	destination: bitcoin::Address,
	amount: Amount,
	created: std::time::Instant,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, utoipa::ToSchema)]
pub struct SendApproval { #[schema(value_type = String)] pub request_id: bitcoin::Txid, pub total_sat: u64 }

#[utoipa::path(post, path = "/send/prepare", tag = "onchain", request_body = bark_json::web::OnchainSendRequest,
	responses((status = 200, description = "Review or submission result", body = serde_json::Value)),
	description = "Prepare an exact 60-second on-chain review; returns request_id, destination, amount_sat, fee_sat and total_sat. Does not sign or broadcast.")]
async fn send_prepare(State(state): State<Arc<ServerState>>, Json(body): Json<bark_json::web::OnchainSendRequest>) -> HandlerResult<Json<serde_json::Value>> {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let mut review = state.send_review.lock().await; *review = None;
	let wallet = state.require_wallet()?;
	let onchain = state.require_onchain()?;
	let address = body.destination.parse::<bitcoin::Address<_>>().badarg("Invalid destination")?.require_network(wallet.network().await?).badarg("Wrong network")?;
	if body.amount_sat == 0 { return Err(anyhow::anyhow!("Enter a positive amount").into()); }
	wallet.chain().update_fee_rates(wallet.config().fallback_fee_rate).await?;
	let mut guard = onchain.write().await;
	guard.sync(wallet.chain()).await?;
	let amount = Amount::from_sat(body.amount_sat);
	let psbt = guard.prepare_tx(&[(address.clone(), amount)], wallet.chain().fee_rates().await.regular).await?;
	let fee = psbt.fee().context("Unable to calculate payment fee")?.to_sat();
	let total = body.amount_sat.checked_add(fee).context("Payment total overflow")?;
	let result = serde_json::json!({"request_id": psbt.unsigned_tx.compute_txid(), "destination": address.to_string(), "amount_sat": body.amount_sat, "fee_sat": fee, "total_sat": total});
	*review = Some(PreparedSend { owner: onchain.clone(), psbt, destination: address, amount, created: std::time::Instant::now() });
	Ok(Json(result))
}

#[utoipa::path(post, path = "/send/commit", tag = "onchain", request_body = SendApproval,
	responses((status = 200, description = "Review or submission result", body = serde_json::Value)),
	description = "Consume the prepared review once. Requires the same wallet, request ID, total cost and unspent inputs. Returns txid and submitted or pending_broadcast; neither means confirmed. Never retry an uncertain commit automatically.")]
pub(super) async fn send_commit(State(state): State<Arc<ServerState>>, Json(body): Json<SendApproval>) -> HandlerResult<Json<serde_json::Value>> {
	send_commit_tracked(state, body, || Ok(())).await
}

pub(super) async fn send_commit_tracked<F>(state: Arc<ServerState>, body: SendApproval, before_submit: F) -> HandlerResult<Json<serde_json::Value>>
where F: FnOnce() -> anyhow::Result<()> + Send {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let reviewed = state.send_review.lock().await.take().badarg("Review an on-chain payment first")?;
	let wallet = state.require_wallet()?; let onchain = state.require_onchain()?;
	let result: anyhow::Result<bitcoin::Transaction> = async {
		anyhow::ensure!(Arc::ptr_eq(&onchain, &reviewed.owner), "Wallet changed; review again");
		anyhow::ensure!(reviewed.created.elapsed() < std::time::Duration::from_secs(60), "Payment review expired");
		anyhow::ensure!(reviewed.psbt.unsigned_tx.compute_txid() == body.request_id && reviewed.amount.to_sat().checked_add(reviewed.psbt.fee()?.to_sat()) == Some(body.total_sat), "Reviewed payment changed");
		let mut guard = onchain.write().await;
		guard.sync(wallet.chain()).await?;
		anyhow::ensure!(reviewed.created.elapsed() < std::time::Duration::from_secs(60), "Payment review expired during refresh");
		let chain = cast_bdk_mut(&mut *guard)?;
		let unspent: std::collections::HashSet<_> = chain.list_unspent().iter().map(|u| u.outpoint).collect();
		anyhow::ensure!(reviewed.psbt.unsigned_tx.input.iter().all(|i| unspent.contains(&i.previous_output)), "Inputs changed; review again");
		before_submit()?;
		chain.finish_reviewed_send(reviewed.psbt, &[(reviewed.destination, reviewed.amount)]).await
	}.await;
	let tx = result.badarg("Unable to submit reviewed payment")?;
	let broadcast = wallet.chain().broadcast_tx(&tx).await.is_ok();
	Ok(Json(serde_json::json!({"state": if broadcast {"submitted"} else {"pending_broadcast"}, "txid": tx.compute_txid()})))
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, utoipa::ToSchema)]
pub struct ReplacementRequest { #[schema(value_type = String)] pub txid: bitcoin::Txid, pub new_fee_sat: u64 }
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, utoipa::ToSchema)]
pub struct ReplacementApproval { #[schema(value_type = String)] pub replacement_txid: bitcoin::Txid, pub new_fee_sat: u64 }

#[utoipa::path(post, path = "/replacement/prepare", tag = "onchain", request_body = ReplacementRequest,
	responses((status = 200, description = "Review or submission result", body = serde_json::Value)),
	description = "Review a replacement of a locally authorized ordinary outgoing payment. Zero new_fee_sat requests twice the original fee. Preserves all recipients, amounts and inputs; additional fee comes only from original change. Returns original_txid, replacement_txid, old_fee_sat, new_fee_sat, additional_fee_sat and recipients.")]
async fn replacement_prepare(State(state): State<Arc<ServerState>>, Json(body): Json<ReplacementRequest>) -> HandlerResult<Json<serde_json::Value>> {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let mut pending = state.replacement.lock().await;
	*pending = None;
	let wallet = state.require_wallet()?;
	let onchain = state.require_onchain()?;
	let mut guard = onchain.write().await;
	guard.sync(wallet.chain()).await?;
	let prepared = cast_bdk_mut(&mut *guard)?.prepare_replacement(body.txid, body.new_fee_sat).await.badarg("Unable to prepare fee replacement")?;
	let review = serde_json::to_value(&prepared.review).context("Unable to encode replacement review")?;
	*pending = Some((onchain.clone(), prepared));
	Ok(Json(review))
}

#[utoipa::path(post, path = "/replacement/commit", tag = "onchain", request_body = ReplacementApproval,
	responses((status = 200, description = "Review or submission result", body = serde_json::Value)),
	description = "Consume a 60-second fee review once after refreshing and verifying the original signatures. Returns txid and submitted or pending_broadcast. Check transaction status before any further action.")]
pub(super) async fn replacement_commit(State(state): State<Arc<ServerState>>, Json(body): Json<ReplacementApproval>) -> HandlerResult<Json<serde_json::Value>> {
	replacement_commit_tracked(state, body, || Ok(())).await
}

pub(super) async fn replacement_commit_tracked<F>(state: Arc<ServerState>, body: ReplacementApproval, before_submit: F) -> HandlerResult<Json<serde_json::Value>>
where F: FnOnce() -> anyhow::Result<()> + Send {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let (owner, prepared) = state.replacement.lock().await.take().badarg("Review a fee replacement first")?;
	let wallet = state.require_wallet()?;
	let onchain = state.require_onchain()?;
	if !Arc::ptr_eq(&owner, &onchain) { return Err(anyhow::anyhow!("Wallet changed; review again").into()); }
	let mut guard = onchain.write().await;
	guard.sync(wallet.chain()).await?;
	let tx = cast_bdk_mut(&mut *guard)?.commit_replacement_tracked(prepared, body.replacement_txid, body.new_fee_sat, before_submit).await.badarg("Unable to replace payment")?;
	let broadcast = wallet.chain().broadcast_tx(&tx).await.is_ok();
	Ok(Json(serde_json::json!({"state": if broadcast {"submitted"} else {"pending_broadcast"}, "txid": tx.compute_txid()})))
}

#[derive(OpenApi)]
#[openapi(
	paths(
		send_prepare, send_commit, replacement_prepare, replacement_commit,
		onchain_message_sign,
		onchain_message_verify,
		onchain_balance,
		onchain_address,
		onchain_send,
		onchain_send_many,
		onchain_drain,
		onchain_utxos,
		onchain_transactions,
		onchain_sync,
	),
	components(schemas(
		SendApproval, ReplacementRequest, ReplacementApproval,
		bark_json::web::OnchainMessageRequest,
		bark_json::web::OnchainMessageProof,
		bark_json::web::OnchainMessageVerifyRequest,
		bark_json::web::OnchainMessageVerification,
		bark_json::cli::onchain::OnchainBalance,
		bark_json::cli::onchain::Address,
		bark_json::cli::onchain::Send,
		bark_json::web::OnchainSendRequest,
		bark_json::web::OnchainSendManyRequest,
		bark_json::web::OnchainDrainRequest,
		bark_json::primitives::UtxoInfo,
		bark_json::primitives::TransactionInfo,
		bark_json::primitives::WalletTxInfo,
		bark_json::primitives::BlockRef,
	)),
	tags((name = "onchain", description = "Manage barkd's on-chain bitcoin wallet."))
)]
pub struct OnchainApiDoc;

#[utoipa::path(post, path = "/message/sign", tag = "onchain",
	request_body = bark_json::web::OnchainMessageRequest,
	responses((status = 200, description = "Signed address ownership proof", body = bark_json::web::OnchainMessageProof)),
	summary = "Sign an on-chain Taproot address ownership message using BIP322-simple")]
pub async fn onchain_message_sign(
	State(state): State<Arc<ServerState>>,
	Json(body): Json<bark_json::web::OnchainMessageRequest>,
) -> HandlerResult<Json<bark_json::web::OnchainMessageProof>> {
	let network = state.require_wallet()?.network().await?;
	let address = bitcoin::Address::from_str(&body.address).badarg("Invalid address")?
		.require_network(network).badarg("Wrong address network")?;
	let onchain = state.require_onchain()?;
	let guard = onchain.read().await;
	let signature = cast_bdk(&*guard)?.sign_onchain_message(&address, &body.message)
		.badarg("Unable to sign on-chain message")?;
	Ok(Json(bark_json::web::OnchainMessageProof {
		address: address.to_string(), message: body.message, signature,
		scheme: "bip322-simple".into(),
	}))
}

#[utoipa::path(post, path = "/message/verify", tag = "onchain",
	request_body = bark_json::web::OnchainMessageVerifyRequest,
	responses((status = 200, description = "Address ownership proof verification result", body = bark_json::web::OnchainMessageVerification)),
	summary = "Verify a BIP322-simple Taproot address ownership message")]
pub async fn onchain_message_verify(
	State(state): State<Arc<ServerState>>,
	Json(body): Json<bark_json::web::OnchainMessageVerifyRequest>,
) -> HandlerResult<Json<bark_json::web::OnchainMessageVerification>> {
	let network = state.require_wallet()?.network().await?;
	let address = bitcoin::Address::from_str(&body.address).badarg("Invalid address")?
		.require_network(network).badarg("Wrong address network")?;
	let valid = bark::onchain::message::verify_onchain_message(&address, &body.message, &body.signature)
		.badarg("Invalid or unsupported message proof")?;
	Ok(Json(bark_json::web::OnchainMessageVerification { valid }))
}

#[utoipa::path(
	get,
	path = "/balance",
	summary = "Get on-chain balance",
	responses(
		(status = 200, description = "Returns the on-chain balance", body = bark_json::cli::onchain::OnchainBalance),
	),
	description = "Returns the current on-chain wallet balance, broken down by confirmation \
		status. The `trusted_spendable_sat` field is the sum of `confirmed_sat` and \
		`trusted_pending_sat`—the balance that can be safely spent without risk of \
		double-spend.",
	tag = "onchain"
)]
#[debug_handler]
pub async fn onchain_balance(
	State(state): State<Arc<ServerState>>,
) -> HandlerResult<Json<bark_json::cli::onchain::OnchainBalance>> {
	let onchain = state.require_onchain()?;
	let guard = onchain.read().await;
	let balance = cast_bdk(&*guard)?.balance();
	let onchain_balance = bark_json::cli::onchain::OnchainBalance {
		total: balance.total(),
		trusted_spendable: balance.trusted_spendable(),
		immature: balance.immature,
		trusted_pending: balance.trusted_pending,
		untrusted_pending: balance.untrusted_pending,
		confirmed: balance.confirmed,
	};

	Ok(axum::Json(onchain_balance))
}

#[utoipa::path(
	post,
	path = "/addresses/next",
	summary = "Generate on-chain address",
	responses(
		(status = 200, description = "Returns the on-chain address", body = bark_json::cli::onchain::Address),
		(status = 500, description = "Internal server error", body = error::InternalServerError)
	),
	description = "Generates a new on-chain receiving address. Each call returns the next \
		unused address from the wallet's HD keychain.",
	tag = "onchain"
)]
#[debug_handler]
pub async fn onchain_address(
	State(state): State<Arc<ServerState>>,
) -> HandlerResult<Json<bark_json::cli::onchain::Address>> {
	let onchain = state.require_onchain()?;

	let address = onchain.write().await.address().await
		.context("Wallet failed to generate address")?;

	Ok(axum::Json(bark_json::cli::onchain::Address {
		address: address.into_unchecked()
	}))
}

#[utoipa::path(
	post,
	path = "/send",
	summary = "Send on-chain payment",
	request_body = bark_json::web::OnchainSendRequest,
	responses(
		(status = 200, description = "Returns the send result", body = bark_json::cli::onchain::Send),
		(status = 400, description = "The provided destination address is invalid", body = error::BadRequestError),
		(status = 500, description = "Internal server error", body = error::InternalServerError)
	),
	description = "Sends the specified amount to an on-chain address. Broadcasts the \
		transaction immediately at a fee rate targeting confirmation within three blocks \
		and returns the transaction ID.",
	tag = "onchain"
)]
#[debug_handler]
pub async fn onchain_send(
	State(state): State<Arc<ServerState>>,
	Json(body): Json<bark_json::web::OnchainSendRequest>,
) -> HandlerResult<Json<bark_json::cli::onchain::Send>> {
	let wallet = state.require_wallet()?;
	let onchain = state.require_onchain()?;

	let net = wallet.network().await?;
	let addr = bitcoin::Address::from_str	(&body.destination)
		.badarg("Invalid destination address")?
		.require_network(net)
		.badarg("Address is not valid for configured network")?;

	let fee_rate = wallet.chain().fee_rates().await.regular;
	let amount = Amount::from_sat(body.amount_sat);
	let mut guard = onchain.write().await;
	let chain = cast_bdk_mut(&mut *guard)?;
	let psbt = chain.prepare_tx(&[(addr.clone(), amount)], fee_rate).await?;
	let tx = chain.finish_reviewed_send(psbt, &[(addr, amount)]).await?;
	let txid = tx.compute_txid();
	// Keep the durable signed transaction on an ambiguous network response.
	let _ = wallet.chain().broadcast_tx(&tx).await;

	Ok(axum::Json(bark_json::cli::onchain::Send { txid }))
}

#[utoipa::path(
	post,
	path = "/send-many",
	summary = "Send to multiple addresses",
	request_body = bark_json::web::OnchainSendManyRequest,
	responses(
		(status = 200, description = "Returns the send result", body = bark_json::cli::onchain::Send),
		(status = 400, description = "One of the provided destinations is invalid", body = error::BadRequestError),
		(status = 500, description = "Internal server error", body = error::InternalServerError)
	),
	description = "Batches multiple payments into a single on-chain transaction. Each \
		destination is formatted as `address:amount`. Broadcasts the transaction immediately \
		at a fee rate targeting confirmation within three blocks and returns the transaction \
		ID.",
	tag = "onchain"
)]
#[debug_handler]
pub async fn onchain_send_many(
	State(state): State<Arc<ServerState>>,
	Json(body): Json<bark_json::web::OnchainSendManyRequest>,
) -> HandlerResult<Json<bark_json::cli::onchain::Send>> {
	let onchain = state.require_onchain()?;
	let wallet = state.require_wallet()?;

	let net = wallet.network().await?;
	let outputs = body.destinations
		.iter()
		.map(|dest| {
			let mut parts = dest.splitn(2, ':');
			let addr = {
				let s = parts.next()
					.badarg("invalid destination format, expected address:amount")?;
				bitcoin::Address::from_str(s)
					.badarg("invalid address")?
					.require_network(net)
					.badarg("address is not valid for configured network")?
			};
			let amount = {
				let s = parts.next()
					.badarg("invalid destination format, expected address:amount")?;
				Amount::from_str(s)
					.badarg("invalid amount")?
			};
			Ok((addr, amount))
		})
		.collect::<Result<Vec<_>, error::ErrorResponse>>()?;

	info!("Attempting to send the following:");
	for (address, amount) in &outputs {
		info!("{} to {}", amount, address);
	}

	let fee_rate = wallet.chain().fee_rates().await.regular;
	let txid = cast_bdk_mut(&mut *onchain.write().await)?.send_many(wallet.chain(), &outputs, fee_rate).await
		.context("Failed to send many onchain payments")?;

	Ok(axum::Json(bark_json::cli::onchain::Send { txid }))
}

#[utoipa::path(
	post,
	path = "/drain",
	summary = "Drain on-chain wallet",
	request_body = bark_json::web::OnchainDrainRequest,
	responses(
		(status = 200, description = "Returns the drain result", body = bark_json::cli::onchain::Send),
		(status = 400, description = "The provided destination address is invalid", body = error::BadRequestError),
		(status = 500, description = "Internal server error", body = error::InternalServerError)
	),
	description = "Sends the entire on-chain wallet balance to the specified address. The \
		recipient receives the full balance minus transaction fees. Broadcasts immediately \
		at a fee rate targeting confirmation within three blocks and returns the transaction \
		ID.",
	tag = "onchain"
)]
#[debug_handler]
pub async fn onchain_drain(
	State(state): State<Arc<ServerState>>,
	Json(body): Json<bark_json::web::OnchainDrainRequest>,
) -> HandlerResult<Json<bark_json::cli::onchain::Send>> {
	let onchain = state.require_onchain()?;
	let wallet = state.require_wallet()?;

	let net = wallet.network().await?;
	let addr = bitcoin::Address::from_str(&body.destination)
		.badarg("Invalid destination address")?
		.require_network(net)
		.badarg("Address is not valid for configured network")?;

	let fee_rate = wallet.chain().fee_rates().await.regular;
	let txid = cast_bdk_mut(&mut *onchain.write().await)?.drain(wallet.chain(), addr, fee_rate).await
		.context("Failed to drain onchain wallet")?;

	Ok(axum::Json(bark_json::cli::onchain::Send { txid }))
}

#[utoipa::path(
	get,
	path = "/utxos",
	summary = "List on-chain UTXOs",
	responses(
		(status = 200, description = "Returns the on-chain UTXOs", body = Vec<bark_json::primitives::UtxoInfo>),
	),
	description = "Returns all UTXOs in the on-chain wallet. Each entry includes the outpoint, \
		amount, and confirmation height (if confirmed).",
	tag = "onchain"
)]
#[debug_handler]
pub async fn onchain_utxos(
	State(state): State<Arc<ServerState>>,
) -> HandlerResult<Json<Vec<bark_json::primitives::UtxoInfo>>> {
	let onchain = state.require_onchain()?;

	let guard = onchain.read().await;
	let utxos = cast_bdk(&*guard)?.utxos()
		.into_iter()
		.map(bark_json::primitives::UtxoInfo::from)
		.collect::<Vec<_>>();

	Ok(axum::Json(utxos))
}

#[utoipa::path(
	get,
	path = "/transactions",
	summary = "List on-chain transactions",
	responses(
		(status = 200, description = "Returns the on-chain transactions", body = Vec<bark_json::primitives::WalletTxInfo>),
	),
	description = "Returns all on-chain wallet transactions, ordered from oldest to newest. \
		Each entry includes the raw transaction, its fee (when known), the wallet's net balance \
		change, and confirmation status. The fee is `null` for inbound or collaboratively-funded \
		transactions whose foreign prevouts BDK has not indexed.",
	tag = "onchain"
)]
#[debug_handler]
pub async fn onchain_transactions(
	State(state): State<Arc<ServerState>>,
) -> HandlerResult<Json<Vec<bark_json::primitives::WalletTxInfo>>> {
	let onchain = state.require_onchain()?;

	let guard = onchain.read().await;
	let mut transactions = cast_bdk(&*guard)?.list_transaction_infos()?;
	// transactions are ordered from newest to oldest, so we reverse them so last terminal item is newest
	transactions.reverse();

	let transactions = transactions.into_iter()
		.map(bark_json::primitives::WalletTxInfo::from)
		.collect::<Vec<_>>();

	Ok(axum::Json(transactions))
}

#[utoipa::path(
	post,
	path = "/sync",
	summary = "Sync on-chain wallet",
	responses(
		(status = 200, description = "Synced on-chain wallet"),
		(status = 500, description = "Internal server error", body = error::InternalServerError)
	),
	description = "Syncs the on-chain wallet state with the chain source. Fetches new blocks \
		and transactions, updates the UTXO set, and re-submits any stale unconfirmed \
		transactions to the mempool.",
	tag = "onchain"
)]
#[debug_handler]
pub async fn onchain_sync(
	State(state): State<Arc<ServerState>>,
) -> HandlerResult<()> {
	let onchain = state.require_onchain()?;
	let wallet = state.require_wallet()?;

	onchain.write().await.sync(wallet.chain()).await?;
	Ok(())
}

#[cfg(test)]
mod assistance_tests {
	use super::*;
	use axum::{body::Body, http::{Request, StatusCode}};
	use tower::ServiceExt;
	use tokio_util::sync::CancellationToken;
	use crate::auth::AuthToken;

	#[tokio::test]
	async fn assistance_routes_require_authentication_and_reject_unprepared_commits() {
		let token = AuthToken::new([42;32]);
		let state = Arc::new(ServerState::builder().auth_token(token.clone()).build(CancellationToken::new()));
		let router = crate::api::v1::router(&state).with_state(state);
		for path in ["/boards/prepare", "/boards/commit", "/onchain/send/prepare", "/onchain/send/commit", "/onchain/replacement/prepare", "/onchain/replacement/commit"] {
			let request = Request::builder().method("POST").uri(path).header("content-type", "application/json").body(Body::from("{}")).unwrap();
			assert_eq!(router.clone().oneshot(request).await.unwrap().status(), StatusCode::UNAUTHORIZED, "{path}");
		}
		for (path, field) in [("/boards/commit", "request_id"), ("/onchain/send/commit", "request_id"), ("/onchain/replacement/commit", "replacement_txid")] {
			let body = serde_json::json!({field: "ab".repeat(32), "total_sat":1000, "new_fee_sat":1000, "amount_sat":500});
			let request = Request::builder().method("POST").uri(path).header("content-type", "application/json")
				.header("authorization", format!("Bearer {}", token.encode())).body(Body::from(body.to_string())).unwrap();
			assert_eq!(router.clone().oneshot(request).await.unwrap().status(), StatusCode::BAD_REQUEST, "Unprepared approval must fail before reaching a wallet");
		}
	}
}
