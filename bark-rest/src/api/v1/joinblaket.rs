//! Browser bridge to one administrator-configured JoinBlaket daemon.
//! Never accepts a browser-selected upstream, exports seeds, or retries actions.

use std::{sync::Arc, time::Duration};

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::State, http::{HeaderMap, StatusCode, header}, routing::{get, post}};
use reqwest::{Client, Url};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ServerState;

pub fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/connection", get(connection)).route("/request", post(request))
}

// Secrets intentionally have no Debug/Serialize implementation.
#[derive(Deserialize)]
pub struct Request {
	operation: Operation,
	#[serde(default)] wallet: String,
	#[serde(default)] token: String,
	#[serde(default)] password: String,
	#[serde(default)] bip39_passphrase: String,
	jar: Option<u8>,
	minimum_sat: Option<u64>,
	fee_sat: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Operation { Wallets, Unlock, Status, Coins, Address, StartMaker, StopMaker }

async fn connection(State(state): State<Arc<ServerState>>) -> (StatusCode, Json<Value>) {
	if state.auth_token().is_none() { return (StatusCode::FORBIDDEN, Json(json!({"message": "Configure wallet authentication first"}))); }
	(StatusCode::OK, Json(json!({"configured": std::env::var("BARKD_JOINBLAKET_URL").is_ok()})))
}

fn endpoint(text: &str, proxy: Option<&str>) -> anyhow::Result<Url> {
	let url: Url = text.parse().context("Invalid JoinBlaket server address")?;
	ensure!(url.username().is_empty() && url.password().is_none() && url.query().is_none() && url.fragment().is_none(), "JoinBlaket URL must not contain credentials or query parameters");
	let onion = url.host_str().is_some_and(|host| host.ends_with(".onion"));
	ensure!(url.scheme() == "https" || (url.scheme() == "http" && onion && proxy.is_some()), "JoinBlaket needs HTTPS or an onion through Tor");
	ensure!(!onion || proxy.is_some(), "JoinBlaket onion needs an explicit Tor proxy");
	ensure!(url.host_str().is_some(), "JoinBlaket needs a host");
	Ok(url)
}

fn wallet_path(wallet: &str) -> anyhow::Result<()> {
	ensure!(!wallet.is_empty() && wallet.len() <= 256 && !wallet.contains(['/', '\\']) && wallet != "." && wallet != "..", "Invalid Jam wallet name");
	Ok(())
}

async fn upstream(client: &Client, base: &Url, segments: &[&str], token: &str, body: Option<Value>) -> anyhow::Result<Value> {
	let mut url = base.clone();
	url.path_segments_mut().map_err(|_| anyhow::anyhow!("Invalid Jam URL"))?.pop_if_empty().extend(["api", "v1"]).extend(segments);
	let mut request = if let Some(body) = body { client.post(url).json(&body) } else { client.get(url) };
	if !token.is_empty() { request = request.bearer_auth(token); }
	let mut response = request.send().await.map_err(|_| anyhow::anyhow!("Could not reach JoinBlaket. Check its status before retrying an action."))?;
	ensure!(response.status().is_success(), "JoinBlaket returned HTTP {}; unlock again for 401, otherwise check status before retrying", response.status().as_u16());
	let mut bytes = Vec::new();
	while let Some(chunk) = response.chunk().await.map_err(|_| anyhow::anyhow!("JoinBlaket response was interrupted; check status before retrying"))? {
		ensure!(bytes.len() + chunk.len() <= 4 * 1024 * 1024, "JoinBlaket response too large");
		bytes.extend_from_slice(&chunk);
	}
	serde_json::from_slice(&bytes).map_err(|_| anyhow::anyhow!("Invalid JoinBlaket response"))
}

async fn execute(input: Request) -> anyhow::Result<Value> {
	let address = std::env::var("BARKD_JOINBLAKET_URL").context("Connect your JoinBlaket service in the wallet server settings")?;
	let proxy = std::env::var("BARKD_JOINBLAKET_TOR_PROXY").ok();
	let base = endpoint(&address, proxy.as_deref())?;
	let mut builder = Client::builder().redirect(reqwest::redirect::Policy::none()).retry(reqwest::retry::never())
		.no_proxy().timeout(Duration::from_secs(60)).connect_timeout(Duration::from_secs(15));
	if let Some(proxy) = proxy {
		let proxy_url: Url = proxy.parse().context("Invalid Jam Tor proxy")?;
		ensure!(proxy_url.scheme() == "socks5h" && proxy_url.host_str().is_some() && proxy_url.port().is_some()
			&& proxy_url.username().is_empty() && proxy_url.password().is_none() && proxy_url.query().is_none()
			&& proxy_url.fragment().is_none() && proxy_url.path().is_empty(), "Use socks5h://host:port for Jam Tor");
		builder = builder.proxy(reqwest::Proxy::all(proxy_url).context("Invalid Jam Tor proxy")?);
	}
	if let Ok(path) = std::env::var("BARKD_JOINBLAKET_CA_FILE") {
		let pem = tokio::fs::read(path).await.context("Could not read configured JoinBlaket CA")?;
		builder = builder.add_root_certificate(reqwest::Certificate::from_pem(&pem).context("Invalid JoinBlaket CA")?);
	}
	let client = builder.build().context("Could not initialize Jam transport")?;
	if matches!(input.operation, Operation::Wallets) { return upstream(&client, &base, &["wallet", "all"], "", None).await; }
	wallet_path(&input.wallet)?;
	if matches!(input.operation, Operation::Unlock) {
		ensure!(input.password.len() <= 16_384 && input.bip39_passphrase.len() <= 16_384, "Jam unlock input too long");
		let mut body = json!({"password": input.password});
		if !input.bip39_passphrase.is_empty() { body["bip39_passphrase"] = input.bip39_passphrase.into(); }
		let result = upstream(&client, &base, &["wallet", &input.wallet, "unlock"], "", Some(body)).await?;
		ensure!(result["walletname"] == input.wallet, "Jam wallet changed during unlock");
		// No seed or unrelated daemon response fields may cross this boundary.
		return Ok(json!({"walletname": result["walletname"], "token": result["token"]}));
	}
	ensure!(!input.token.is_empty() && input.token.len() < 16_384 && input.token.bytes().all(|b| (33..=126).contains(&b)), "Unlock your Jam wallet first");
	let session = upstream(&client, &base, &["session"], &input.token, None).await?;
	ensure!(session["session"] == true && session["wallet_name"] == input.wallet, "The active Jam wallet changed; reconnect");
	match input.operation {
		Operation::Status => Ok(session),
		Operation::Coins => {
			let result = upstream(&client, &base, &["wallet", &input.wallet, "utxos"], &input.token, None).await?;
			let coins: Vec<bark::joinblaket::JarCoin> = serde_json::from_value(result["utxos"].clone()).context("Invalid Jam coins")?;
			Ok(json!({"jars": bark::joinblaket::jar_balances(&coins)?}))
		},
		Operation::Address => {
			let jar = input.jar.context("Select a jar")?;
			bark::joinblaket::JarId::try_from(jar)?;
			upstream(&client, &base, &["wallet", &input.wallet, "address", "new", &jar.to_string()], &input.token, None).await
		},
		Operation::StartMaker => {
			let minimum = input.minimum_sat.context("Enter a minimum CoinJoin amount")?;
			let fee = input.fee_sat.context("Enter your maker fee")?;
			ensure!((27_300..=2_100_000_000_000_000).contains(&minimum) && fee < minimum, "Review maker amount and fee");
			ensure!(session["maker_running"] == false && session["coinjoin_in_process"] == false && session["rescanning"] == false, "Wait for the current Jam operation to finish");
			upstream(&client, &base, &["wallet", &input.wallet, "maker", "start"], &input.token, Some(json!({
				"txfee": "0", "cjfee_a": fee.to_string(), "cjfee_r": "0", "ordertype": "sw0absoffer", "minsize": minimum.to_string(),
			}))).await
		},
		Operation::StopMaker => upstream(&client, &base, &["wallet", &input.wallet, "maker", "stop"], &input.token, None).await,
		Operation::Wallets | Operation::Unlock => unreachable!("handled above"),
	}
}

async fn request(State(state): State<Arc<ServerState>>, Json(input): Json<Request>) -> (StatusCode, HeaderMap, Json<Value>) {
	let mut headers = HeaderMap::new(); headers.insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
	if state.auth_token().is_none() { return (StatusCode::FORBIDDEN, headers, Json(json!({"message": "Configure wallet authentication first"}))); }
	match execute(input).await {
		Ok(value) => (StatusCode::OK, headers, Json(value)),
		Err(error) => (StatusCode::BAD_REQUEST, headers, Json(json!({"message": error.to_string()}))),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn jam_requires_tls_or_explicit_onion_route_and_no_url_secrets() {
		assert!(endpoint("https://start.local:28183", None).is_ok());
		assert!(endpoint("http://example.onion", Some("socks5h://127.0.0.1:9050")).is_ok());
		for url in ["http://start.local", "https://example.onion", "https://user:pass@start.local", "https://start.local?token=x"] {
			assert!(endpoint(url, None).is_err());
		}
	}
	#[test]
	fn jam_wallet_cannot_escape_path() {
		for wallet in ["", "..", ".", "../other", "a/b", "a\\b"] { assert!(wallet_path(wallet).is_err()); }
		assert!(wallet_path("wallet.jmdat").is_ok());
	}
}
