//! Reviewed whole-VTXO withdrawals to this wallet's onchain account.
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::State, routing::post};
use bitcoin::hashes::{Hash, sha256};
use bark::actions::offboard::{Offboard, OffboardKind, Progress};
use bark::movement::PaymentMethod;
use bark::onchain::OnchainWalletTrait;
use serde::{Deserialize, Serialize};
use utoipa::{OpenApi, ToSchema};

use crate::{ServerState, error::{ContextExt, HandlerResult}};

#[derive(OpenApi)]
#[openapi(paths(prepare, commit), components(schemas(WithdrawalPrepare, WithdrawalApproval, WithdrawalReview)),
	tags((name = "withdrawals", description = "Review Ark withdrawals before committing funds.")))]
pub struct WithdrawalsApiDoc;

pub fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/prepare", post(prepare)).route("/commit", post(commit))
}

#[derive(Serialize, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub struct WithdrawalPrepare {}

#[derive(Clone, Debug, Serialize, Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub struct WithdrawalApproval {
	pub request_id: String,
	pub net_sat: u64,
	pub total_sat: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, ToSchema)]
pub struct WithdrawalReview {
	pub request_id: String,
	pub destination: String,
	pub net_sat: u64,
	pub fee_sat: u64,
	pub total_sat: u64,
	pub input_count: usize,
}

pub(crate) struct PreparedWithdrawal {
	owner: Weak<tokio::sync::RwLock<dyn OnchainWalletTrait>>,
	terms: WithdrawalReview,
	inputs: Vec<ark::VtxoId>,
	created: Instant,
}

#[utoipa::path(post, path = "/prepare", tag = "withdrawals", request_body = WithdrawalPrepare,
	responses((status = 200, description = "A 60-second withdrawal review; no funds are committed", body = WithdrawalReview)))]
async fn prepare(State(state): State<Arc<ServerState>>, Json(_body): Json<WithdrawalPrepare>) -> HandlerResult<Json<WithdrawalReview>> {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let mut pending = state.withdrawal_review.lock().await; *pending = None;
	let wallet = state.require_wallet()?; let onchain = state.require_onchain()?;
	let result: anyhow::Result<PreparedWithdrawal> = async {
		wallet.chain().require_funded_policy().await?;
		let destination = onchain.write().await.address().await?;
		let estimate = wallet.estimate_max_address_payment(&PaymentMethod::Bitcoin(destination.clone().into_unchecked())).await?;
		let net = estimate.net_amount.to_sat(); let fee = estimate.fee.to_sat(); let total = estimate.gross_amount.to_sat();
		ensure!(net > 0 && net.checked_add(fee) == Some(total) && !estimate.vtxos_spent.is_empty(), "Invalid withdrawal estimate");
		ensure!(estimate.vtxos_spent.iter().collect::<std::collections::HashSet<_>>().len() == estimate.vtxos_spent.len(), "Duplicate withdrawal inputs");
		let terms = WithdrawalReview {
			request_id: sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()).to_string(),
			destination: destination.to_string(), net_sat: net, fee_sat: fee, total_sat: total, input_count: estimate.vtxos_spent.len(),
		};
		Ok(PreparedWithdrawal { owner: Arc::downgrade(&onchain), terms, inputs: estimate.vtxos_spent, created: Instant::now() })
	}.await;
	let prepared = result.badarg("Unable to prepare withdrawal")?;
	let review = prepared.terms.clone(); *pending = Some(prepared);
	Ok(Json(review))
}

#[utoipa::path(post, path = "/commit", tag = "withdrawals", request_body = WithdrawalApproval,
	description = "Consume a review once after checking wallet identity, expiry, exact inputs, recipient and costs. Browser clients use the durable submissions endpoint. After an uncertain response, check the saved submission; do not repeat with a new review.",
	responses((status = 200, description = "Withdrawal submitted; confirmation is still pending", body = serde_json::Value)))]
async fn commit(State(state): State<Arc<ServerState>>, Json(body): Json<WithdrawalApproval>) -> HandlerResult<Json<serde_json::Value>> {
	commit_tracked(state, body, |_| Ok(())).await
}

pub(super) async fn commit_tracked<F>(state: Arc<ServerState>, approval: WithdrawalApproval, before_submit: F) -> HandlerResult<Json<serde_json::Value>>
where F: FnOnce(&str) -> anyhow::Result<()> + Send {
	let _lifecycle = state.wallet_lifecycle.lock().await;
	let prepared = state.withdrawal_review.lock().await.take().badarg("Review the withdrawal first")?;
	let wallet = state.require_wallet()?; let onchain = state.require_onchain()?;
	let result: anyhow::Result<_> = async {
		ensure!(prepared.owner.ptr_eq(&Arc::downgrade(&onchain)), "Wallet changed; review again");
		validate_approval(&prepared.terms, prepared.created, &approval)?;
		wallet.chain().require_funded_policy().await?;
		let address = prepared.terms.destination.parse::<bitcoin::Address<_>>()?.require_network(wallet.network().await?)?;
		wallet.offboard_vtxos_tracked(prepared.inputs.clone(), address, |action| {
			// Fee calculation may have awaited a server response. Recheck expiry
			// and all constructed terms before even the initial checkpoint exists.
			validate_approval(&prepared.terms, prepared.created, &approval)?;
			validate_action(&prepared.terms, &prepared.inputs, action)?;
			before_submit(&action.id)
		}).await
	}.await;
	let offboard = result.badarg("Withdrawal did not return a confirmed result; check saved status before retrying")?;
	Ok(Json(serde_json::json!({"state":"submitted", "txid":offboard.txid, "movement_id":offboard.movement_id})))
}

fn validate_approval(terms: &WithdrawalReview, created: Instant, approval: &WithdrawalApproval) -> anyhow::Result<()> {
	ensure!(created.elapsed() < Duration::from_secs(60), "Withdrawal review expired; review again");
	ensure!(terms.request_id == approval.request_id && terms.net_sat == approval.net_sat && terms.total_sat == approval.total_sat,
		"Withdrawal approval changed; review again");
	Ok(())
}

fn validate_action(terms: &WithdrawalReview, inputs: &[ark::VtxoId], action: &Offboard) -> anyhow::Result<()> {
	let destination = terms.destination.parse::<bitcoin::Address<bitcoin::address::NetworkUnchecked>>()?;
	let total = action.onchain_output_amount.checked_add(action.committed_fee).and_then(|v| v.checked_add(action.recovery_reserve))
		.context("Withdrawal total overflow")?;
	ensure!(action.progress == Progress::Start && action.destination == destination
		&& action.onchain_output_amount.to_sat() == terms.net_sat && total.to_sat() == terms.total_sat
		&& action.committed_fee.to_sat() == terms.fee_sat && action.recovery_reserve == bitcoin::Amount::ZERO
		&& matches!(&action.kind, OffboardKind::OffboardWhole { input_vtxo_ids } if input_vtxo_ids == inputs),
		"Withdrawal inputs, amount or fees changed; review again");
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	use axum::{body::Body, http::{Request, StatusCode}};
	use tower::ServiceExt;
	use tokio_util::sync::CancellationToken;
	use crate::auth::AuthToken;

	#[tokio::test]
	async fn withdrawal_routes_require_auth_and_a_live_review() {
		let token = AuthToken::new([42;32]);
		let state = Arc::new(ServerState::builder().auth_token(token.clone()).build(CancellationToken::new()));
		let router = crate::api::v1::router(&state).with_state(state);
		for path in ["/withdrawals/prepare", "/withdrawals/commit"] {
			let request = Request::builder().method("POST").uri(path).header("content-type", "application/json").body(Body::from("{}")).unwrap();
			assert_eq!(router.clone().oneshot(request).await.unwrap().status(), StatusCode::UNAUTHORIZED);
		}
		let body = serde_json::json!({"request_id":"ab".repeat(32), "net_sat":1000, "total_sat":1100});
		for _ in 0..2 {
			let request = Request::builder().method("POST").uri("/withdrawals/commit").header("content-type", "application/json")
				.header("authorization", format!("Bearer {}", token.encode())).body(Body::from(body.to_string())).unwrap();
			assert_eq!(router.clone().oneshot(request).await.unwrap().status(), StatusCode::BAD_REQUEST);
		}
		assert!(serde_json::from_value::<WithdrawalApproval>(serde_json::json!({"request_id":"ab".repeat(32), "net_sat":1000, "total_sat":1100, "destination":"replacement"})).is_err());
	}
	#[test]
	fn approval_and_constructed_action_must_match_review() {
		let destination = bitcoin::Address::p2wsh(&bitcoin::ScriptBuf::new(), bitcoin::Network::Regtest);
		let inputs = vec![ark::VtxoId::from(bitcoin::OutPoint::null())];
		let terms = WithdrawalReview { request_id: "ab".repeat(32), destination: destination.to_string(), net_sat: 1000, fee_sat: 100, total_sat: 1100, input_count: 1 };
		let approval = WithdrawalApproval { request_id: terms.request_id.clone(), net_sat: 1000, total_sat: 1100 };
		assert!(validate_approval(&terms, Instant::now(), &approval).is_ok());
		assert!(validate_approval(&terms, Instant::now() - Duration::from_secs(60), &approval).is_err());
		for changed in [WithdrawalApproval { request_id: "cd".repeat(32), ..approval.clone() },
			WithdrawalApproval { net_sat: 999, ..approval.clone() }, WithdrawalApproval { total_sat: 1101, ..approval.clone() }] {
			assert!(validate_approval(&terms, Instant::now(), &changed).is_err());
		}
		let action = Offboard { id: "cd".repeat(16), destination: destination.into_unchecked(), onchain_output_amount: bitcoin::Amount::from_sat(1000),
			committed_fee: bitcoin::Amount::from_sat(100), recovery_reserve: bitcoin::Amount::ZERO,
			committed_fee_rate: bitcoin::FeeRate::from_sat_per_vb(1).unwrap(), kind: OffboardKind::OffboardWhole { input_vtxo_ids: inputs.clone() }, progress: Progress::Start };
		assert!(validate_action(&terms, &inputs, &action).is_ok());
		for field in ["recipient", "amount", "fee", "reserve", "inputs", "overflow", "progress"] {
			let mut changed = action.clone();
			match field {
				"recipient" => changed.destination = bitcoin::Address::p2wsh(&bitcoin::ScriptBuf::from_bytes(vec![0x51]), bitcoin::Network::Regtest).into_unchecked(),
				"amount" => changed.onchain_output_amount = bitcoin::Amount::from_sat(999),
				"fee" => changed.committed_fee = bitcoin::Amount::from_sat(101),
				"reserve" => changed.recovery_reserve = bitcoin::Amount::ONE_SAT,
				"inputs" => changed.kind = OffboardKind::OffboardWhole { input_vtxo_ids: vec![] },
				"overflow" => changed.committed_fee = bitcoin::Amount::from_sat(u64::MAX),
				_ => changed.progress = Progress::SplitWithArkoor,
			}
			assert!(validate_action(&terms, &inputs, &changed).is_err(), "{field}");
		}
	}
}
