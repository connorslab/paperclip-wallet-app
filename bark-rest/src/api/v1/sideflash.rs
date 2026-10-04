//! Authenticated, explicitly compiled local test endpoints.
use std::sync::Arc;
use anyhow::Context;
use axum::{extract::State, routing::{get, post}, Json, Router};
use crate::{ServerState, error::HandlerResult};

pub fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/info", get(info)).route("/receive", post(receive))
}

async fn info(State(state): State<Arc<ServerState>>) -> HandlerResult<Json<serde_json::Value>> {
	let (recipient, server) = state.require_wallet()?.sideflash_receive_info().await?;
	Ok(Json(serde_json::json!({"recipient_pubkey": recipient, "server_pubkey": server, "experimental": true})))
}

async fn receive(State(state): State<Arc<ServerState>>) -> HandlerResult<Json<serde_json::Value>> {
	let address = state.require_wallet()?.sideflash_receive().await?;
	let decoded = ark::sideflash::SideflashAddress::decode(&address).context("Invalid acknowledged address")?;
	Ok(Json(serde_json::json!({"address": address, "expires": decoded.binding().expires, "server_pubkey": decoded.binding().server.to_string()})))
}
