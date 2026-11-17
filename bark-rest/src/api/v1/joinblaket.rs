//! Browser bridge to one administrator-configured JoinBlaket daemon.
//! Never accepts a browser-selected upstream or retries actions. Recovery words
//! require the owner's authenticated route and a fresh Jam password check.

use std::{sync::Arc, time::Duration};

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::State, http::{HeaderMap, StatusCode, header}, routing::{get, post}};
use reqwest::{Client, Url};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ServerState;
mod pairing;
pub use pairing::paired_router;

pub fn router() -> Router<Arc<ServerState>> {
	Router::new().route("/connection", get(connection)).route("/request", post(request)).merge(pairing::owner_router())
		.layer(axum::extract::DefaultBodyLimit::max(64 * 1024))
}

// Secrets intentionally have no Debug/Serialize implementation.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
	operation: Operation,
	#[serde(default)] wallet: String,
	#[serde(default)] token: String,
	#[serde(default)] password: String,
	#[serde(default)] bip39_passphrase: String,
	jar: Option<u8>,
	minimum_sat: Option<u64>,
	fee_sat: Option<u64>,
	relative_fee: Option<String>,
	comparison_sat: Option<u64>,
	lock_month: Option<String>,
	payment_id: Option<String>,
	approval: Option<String>,
	wallet_identity: Option<String>,
	send: Option<SendTerms>,
	#[serde(skip)] pairing_scope: pairing::Scope,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Operation { Wallets, CreateWallet, BackupWallet, Unlock, Status, Identity, Coins, Address, BondAddress, StartMaker, StopMaker, Payments, CheckPayment, CancelPayment, PreparePayment, CommitPayment, PaymentCapabilities, PaymentReview, Market, #[serde(skip)] PairingSession }

/// Fixed-amount sends bind the selected mode through review and commit.
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct SendTerms {
	jar: u8,
	destination: String,
	amount_sat: u64,
	fee_rate_millisat_vb: u64,
	max_fee_sat: u64,
	#[serde(default)] coinjoin: bool,
}
impl SendTerms {
	fn body(&self, id: &str) -> anyhow::Result<Value> {
		ensure!(payment_identifier(id) && self.jar < 5, "Invalid Jam payment reference or jar");
		ensure!((14..=90).contains(&self.destination.len()) && self.destination.bytes().all(|b| b.is_ascii_alphanumeric()), "Enter a valid XBT address");
		ensure!(self.amount_sat > 0 && self.max_fee_sat > 0 && self.amount_sat.checked_add(self.max_fee_sat).is_some_and(|v| v <= 2_100_000_000_000_000), "Review the payment amount and maximum mining fee");
		ensure!((1000..=10_000_000).contains(&self.fee_rate_millisat_vb), "Review the mining fee rate");
		Ok(json!({"id":id,"purpose":"send","jar":self.jar,"destination":self.destination,
			"amount_sat":self.amount_sat,"send_max":false,"fee_rate_millisat_vb":self.fee_rate_millisat_vb,
			"max_fee_sat":self.max_fee_sat,"max_total_sat":self.amount_sat+self.max_fee_sat,"rbf":!self.coinjoin,"coinjoin":self.coinjoin}))
	}
}

fn send_review(value: &Value, wallet: &str, identity: &str, now: i64) -> anyhow::Result<Value> {
	let mut result = recovery_payment(value, wallet)?;
	ensure!(result["state"] == "prepared", "This review cannot be submitted; check Jars payment activity");
	ensure!(pairing::valid_identity(identity) && value["quote"]["wallet_identity"] == identity, "Jam wallet identity changed");
	ensure!(value["quote"]["network"] == identity.split(':').next().unwrap() && value["quote"]["purpose"] == "send" && value["quote"]["rbf"] == (result["quote"]["coinjoin"] != true), "Unsupported Jam payment review");
	let expiry = value["expires"].as_i64().context("Missing Jam review expiry")?;
	ensure!(expiry > now && expiry <= now + 300, "Jam payment review expired; discard it before preparing another");
	ensure!(value["approval"].as_str().is_some_and(payment_identifier), "Invalid Jam payment approval");
	result["expires"] = expiry.into(); result["approval"] = value["approval"].clone();
	result["quote"]["wallet_identity"] = identity.into();
	result["quote"]["network"] = value["quote"]["network"].clone();
	result["quote"]["rbf"] = value["quote"]["rbf"].clone();
	Ok(result)
}

fn verify_send_terms(review: &Value, terms: &SendTerms) -> anyhow::Result<()> {
	let q = &review["quote"];
	ensure!(q["coinjoin"].as_bool().unwrap_or(false) == terms.coinjoin && q["jar"] == terms.jar && q["destination"] == terms.destination && q["amount_sat"] == terms.amount_sat
		&& q["fee_sat"].as_u64().is_some_and(|v| v <= terms.max_fee_sat), "Jam changed the recipient, jar, amount or fee limit; check the saved review");
	Ok(())
}

fn maker_body(input: &Request) -> anyhow::Result<Value> {
	let minimum = input.minimum_sat.context("Enter a minimum CoinJoin amount")?;
	ensure!((27_300..=2_100_000_000_000_000).contains(&minimum), "Review the minimum CoinJoin amount");
	let (kind, absolute, relative) = match (&input.relative_fee, input.fee_sat) {
		(Some(rate), None) if MAKER_RELATIVE_FEES.contains(&rate.as_str()) => ("sw0reloffer", 0, rate.as_str()),
		(None, Some(fee)) if MAKER_ABSOLUTE_FEES.contains(&fee) && fee < minimum => ("sw0absoffer", fee, "0"),
		_ => anyhow::bail!("Choose one supported fixed or percentage maker fee"),
	};
	Ok(json!({"txfee":"0", "cjfee_a":absolute.to_string(), "cjfee_r":relative, "ordertype":kind, "minsize":minimum.to_string()}))
}
const MAKER_ABSOLUTE_FEES: [u64; 8] = [0, 100, 200, 500, 1000, 2000, 5000, 10000];
const MAKER_RELATIVE_FEES: [&str; 12] = ["0.00002", "0.00005", "0.0001", "0.0002", "0.0005", "0.001", "0.002", "0.005", "0.01", "0.02", "0.05", "0.1"];

fn create_body(input: &Request) -> anyhow::Result<Value> {
	let name = input.wallet.strip_suffix(".jmdat").context("Use a .jmdat wallet filename")?;
	ensure!(!name.is_empty() && name.len() <= 48 && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'), "Use letters, numbers, hyphens or underscores for the wallet name");
	ensure!(input.password.chars().count() >= 12 && input.password.len() <= 16_384 && !input.password.trim().is_empty(), "Use a Jam wallet password of at least 12 characters");
	ensure!(input.bip39_passphrase.is_empty(), "New Jars wallets use recovery words without an extra BIP39 passphrase");
	Ok(json!({"walletname":input.wallet,"password":input.password,"wallettype":"sw-fb"}))
}

fn wallet_authorization(result: &Value, wallet: &str) -> anyhow::Result<Value> {
	ensure!(result["walletname"] == wallet, "Jam returned a different wallet");
	let token = result["token"].as_str().context("Jam returned no wallet authorization")?;
	ensure!(!token.is_empty() && token.len() < 16_384 && token.bytes().all(|b| (33..=126).contains(&b)), "Invalid Jam wallet authorization");
	// Creation can return recovery words and refresh tokens. Only the dedicated
	// password-verified backup operation may return recovery words to the owner.
	Ok(json!({"walletname":wallet,"token":token}))
}

fn bond_month(value: &str, now: chrono::DateTime<chrono::Utc>) -> anyhow::Result<()> {
	ensure!(value.len() == 7 && value.as_bytes()[4] == b'-'
		&& value.bytes().enumerate().all(|(i, b)| i == 4 || b.is_ascii_digit()), "Choose an unlock month in YYYY-MM format");
	let year: i32 = value[..4].parse()?;
	let month: u32 = value[5..].parse()?;
	ensure!((2020..=2099).contains(&year), "Choose an unlock year before 2100");
	let date = chrono::NaiveDate::from_ymd_opt(year, month, 1).context("Choose a valid unlock month")?;
	ensure!(date.and_hms_opt(0, 0, 0).unwrap().and_utc() > now, "Choose a future unlock month; bonds unlock on its first day at 00:00 UTC");
	Ok(())
}

async fn connection(State(state): State<Arc<ServerState>>) -> (StatusCode, Json<Value>) {
	if state.auth_token().is_none() { return (StatusCode::FORBIDDEN, Json(json!({"message": "Configure wallet authentication first"}))); }
	let proxy = std::env::var("BARKD_JOINBLAKET_TOR_PROXY").ok();
	let url = std::env::var("BARKD_JOINBLAKET_URL").ok().and_then(|value| endpoint(&value, proxy.as_deref()).ok());
	let ui_url = url.as_ref().filter(|url| browser_handoff(url));
	// Only expose a validated, credential-free HTTPS URL for browser handoff.
	(StatusCode::OK, Json(json!({"configured": url.is_some(), "ui_url": ui_url.map(Url::as_str)})))
}

fn browser_handoff(url: &Url) -> bool {
	let Some(host) = url.host_str() else { return false; };
	let ip = host.trim_start_matches('[').trim_end_matches(']').parse::<std::net::IpAddr>().ok();
	// A loopback API belongs to the host running Jam, not the user's browser.
	// Bundled wallets are managed inside Paperclip; never send users to their
	// own localhost when the daemon lives on a different machine.
	url.scheme() == "https" && host != "localhost" && !host.ends_with(".localhost")
		&& !host.ends_with(".onion") && !ip.is_some_and(|ip| ip.is_loopback() || ip.is_unspecified())
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
	execute_bound(input, None).await
}

async fn execute_bound(input: Request, expected_identity: Option<&str>) -> anyhow::Result<Value> {
	let address = std::env::var("BARKD_JOINBLAKET_URL").context("Connect your JoinBlaket service in the wallet server settings")?;
	let proxy = std::env::var("BARKD_JOINBLAKET_TOR_PROXY").ok();
	let base = endpoint(&address, proxy.as_deref())?;
	let preparing_coinjoin = matches!(input.operation, Operation::PreparePayment) && input.send.as_ref().is_some_and(|s| s.coinjoin);
	let mut builder = Client::builder().redirect(reqwest::redirect::Policy::none()).retry(reqwest::retry::never())
		.no_proxy().timeout(Duration::from_secs(if preparing_coinjoin { 190 } else { 60 })).connect_timeout(Duration::from_secs(15));
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
	if matches!(input.operation, Operation::CreateWallet) {
		let body = create_body(&input)?;
		// Jam serializes creation and refuses an existing filename. Never retry a
		// lost response; the owner can find and unlock the same wallet to back up.
		let result = upstream(&client, &base, &["wallet", "create"], "", Some(body)).await?;
		return wallet_authorization(&result, &input.wallet);
	}
	if matches!(input.operation, Operation::Unlock | Operation::BackupWallet) {
		ensure!(input.password.len() <= 16_384 && input.bip39_passphrase.len() <= 16_384, "Jam unlock input too long");
		if matches!(input.operation, Operation::BackupWallet) { ensure!(!input.password.is_empty(), "Enter the Jam wallet password to view recovery words"); }
		let mut body = json!({"password": input.password});
		if !input.bip39_passphrase.is_empty() { body["bip39_passphrase"] = input.bip39_passphrase.into(); }
		let result = upstream(&client, &base, &["wallet", &input.wallet, "unlock"], "", Some(body)).await?;
		let mut authorization = wallet_authorization(&result, &input.wallet)?;
		if matches!(input.operation, Operation::BackupWallet) {
			let result = upstream(&client, &base, &["wallet", &input.wallet, "getseed"], authorization["token"].as_str().unwrap(), None).await?;
			let phrase = result["seedphrase"].as_str().context("Jam recovery words are unavailable")?;
			ensure!(phrase.len() <= 512 && bark::bip39::Mnemonic::parse(phrase).is_ok(), "Jam returned invalid recovery words");
			authorization["seedphrase"] = phrase.into();
		}
		return Ok(authorization);
	}
	ensure!(!input.token.is_empty() && input.token.len() < 16_384 && input.token.bytes().all(|b| (33..=126).contains(&b)), "Unlock your Jam wallet first");
	let session = upstream(&client, &base, &["session"], &input.token, None).await?;
	ensure!(session["session"] == true && session["wallet_name"] == input.wallet, "The active Jam wallet changed; reconnect");
	if expected_identity.is_some() || matches!(input.operation, Operation::Identity | Operation::PairingSession) {
		let identity = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "identity"], &input.token, None).await?;
		ensure!(identity["wallet"] == input.wallet, "Jam wallet identity changed; pair again");
		let id = identity["identity"].as_str().context("Jam wallet identity unavailable")?;
		ensure!(pairing::valid_identity(id) && expected_identity.is_none_or(|expected| expected == id), "Jam wallet identity changed; pair again");
		if matches!(input.operation, Operation::Identity) { return Ok(json!({"wallet": input.wallet, "identity": id})); }
		if matches!(input.operation, Operation::PairingSession) {
			let delegated = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "pairing-session"], &input.token, Some(json!({"scope":input.pairing_scope}))).await?;
			ensure!(delegated.get("scope").cloned().unwrap_or(json!("jars_manage_v1")) == serde_json::to_value(input.pairing_scope)?, "Jam pairing permissions changed");
			ensure!(delegated["identity"] == id && delegated["wallet"] == input.wallet, "Jam pairing identity changed");
			let token = delegated["token"].as_str().context("Jam pairing session unavailable")?;
			ensure!(token.strip_prefix("pjh1_").is_some_and(payment_identifier), "Invalid Jam pairing session");
			let expires = delegated["expires"].as_i64().context("Invalid Jam pairing expiry")?;
			let now = chrono::Utc::now().timestamp();
			ensure!(expires > now && expires <= now + 30 * 86400 + 10, "Jam pairing session expired");
			return Ok(json!({"token":token,"identity":id,"expires":expires}));
		}
	}
	match input.operation {
		Operation::PreparePayment | Operation::CommitPayment => {
			let id = input.payment_id.as_deref().context("Missing Jam payment reference")?;
			ensure!(payment_identifier(id), "Invalid Jam payment reference");
			let identity = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "identity"], &input.token, None).await?;
			let key = identity["identity"].as_str().context("Jam wallet identity unavailable")?;
			ensure!(identity["wallet"] == input.wallet && pairing::valid_identity(key), "Jam wallet identity changed");
			if matches!(input.operation, Operation::PreparePayment) {
				let terms = input.send.as_ref().context("Review the payment details")?;
				let body = terms.body(id)?;
				let features = upstream(&client, &base, &["paperclip", "capabilities"], &input.token, None).await?;
				ensure!((features["version"] == 1 || features["version"] == 2) && features["reviewed_direct_send"] == true
					&& (!terms.coinjoin || (features["version"] == 2 && features["coinjoin_payments"] == true)), "Update the Jam companion before sending");
				let result = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "payments"], &input.token, Some(body)).await?;
				ensure!(result["id"] == id, "Jam returned a different payment");
				let review = send_review(&result, &input.wallet, key, chrono::Utc::now().timestamp())?;
				verify_send_terms(&review, terms)?;
				return Ok(review);
			}
			ensure!(input.wallet_identity.as_deref() == Some(key), "Jam wallet changed since review");
			let approval = input.approval.as_deref().context("Review the saved payment first")?;
			ensure!(payment_identifier(approval), "Invalid Jam payment approval");
			let current = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "payments", id], &input.token, None).await?;
			ensure!(current["id"] == id, "Jam returned a different payment");
			if matches!(current["state"].as_str(), Some("submitting" | "unknown" | "submitted")) {
				return recovery_payment(&current, &input.wallet);
			}
			let review = send_review(&current, &input.wallet, key, chrono::Utc::now().timestamp())?;
			ensure!(review["approval"] == approval, "Jam payment changed; review again");
			let result = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "payments", id, "commit"], &input.token, Some(json!({"approval":approval}))).await?;
			ensure!(result["id"] == id && matches!(result["state"].as_str(), Some("submitting" | "unknown" | "submitted")), "Check Jars payment activity before another action");
			recovery_payment(&result, &input.wallet)
		},
		Operation::PaymentCapabilities => {
			let result = upstream(&client, &base, &["paperclip", "capabilities"], &input.token, None).await?;
			Ok(json!({"version":result["version"],"reviewed_direct_send":result["reviewed_direct_send"],"coinjoin_payments":result["coinjoin_payments"]}))
		},
		Operation::PaymentReview => {
			let id = input.payment_id.as_deref().context("Select a saved payment")?;
			ensure!(payment_identifier(id), "Invalid Jam payment reference");
			let identity = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "identity"], &input.token, None).await?;
			let key = identity["identity"].as_str().context("Jam wallet identity unavailable")?;
			ensure!(identity["wallet"] == input.wallet && expected_identity.is_none_or(|expected| expected == key), "Jam wallet identity changed");
			let result = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "payments", id], &input.token, None).await?;
			ensure!(result["id"] == id, "Jam returned a different payment");
			if result["state"] == "prepared" { send_review(&result, &input.wallet, key, chrono::Utc::now().timestamp()) }
			else { recovery_payment(&result, &input.wallet) }
		},
		Operation::Status => Ok(json!({"session":true,"wallet_name":input.wallet,
			"maker_running":session["maker_running"],"coinjoin_in_process":session["coinjoin_in_process"],"rescanning":session["rescanning"]})),
		Operation::Market => {
			let amount = input.comparison_sat.context("Choose a CoinJoin comparison amount")?;
			ensure!((27_300..=2_100_000_000_000_000).contains(&amount), "Invalid comparison amount");
			upstream(&client, &base, &["paperclip", "market", &amount.to_string()], &input.token, None).await
		},
		Operation::Payments => {
			let result = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "payments"], &input.token, None).await?;
			let rows = result["payments"].as_array().context("Invalid Jam payment history")?;
			ensure!(rows.len() <= 100, "Jam payment history too large");
			let payments = rows.iter().map(|row| recovery_payment(row, &input.wallet)).collect::<anyhow::Result<Vec<_>>>()?;
			ensure!(payments.iter().map(|row| row["id"].as_str().unwrap()).collect::<std::collections::HashSet<_>>().len() == payments.len(), "Duplicate Jam payment reference");
			Ok(json!({"payments": payments}))
		},
		Operation::CheckPayment => {
			let id = input.payment_id.context("Select a saved Jam payment")?;
			ensure!(payment_identifier(&id), "Invalid Jam payment reference");
			// Observation only: no commit, cancellation or legacy send route is exposed.
			let result = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "payments", &id], &input.token, None).await?;
			ensure!(result["id"] == id, "Jam returned a different payment");
			recovery_payment(&result, &input.wallet)
		},
		Operation::CancelPayment => {
			let id = input.payment_id.context("Select an unsent Jam review")?;
			ensure!(payment_identifier(&id), "Invalid Jam payment reference");
			let current = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "payments", &id], &input.token, None).await?;
			ensure!(current["id"] == id, "Jam returned a different payment");
			let saved = recovery_payment(&current, &input.wallet)?;
			if saved["state"] == "cancelled" { return Ok(saved); }
			ensure!(matches!(saved["state"].as_str(), Some("preparing" | "prepared")), "Submission may have started; check status instead");
			// The companion rechecks the durable boundary atomically with cancellation.
			let result = upstream(&client, &base, &["wallet", &input.wallet, "paperclip", "payments", &id, "cancel"], &input.token, Some(json!({}))).await?;
			ensure!(result["id"] == id && result["state"] == "cancelled", "Could not confirm cancellation; refresh saved payments");
			recovery_payment(&result, &input.wallet)
		},
		Operation::Coins => {
			let result = upstream(&client, &base, &["wallet", &input.wallet, "utxos"], &input.token, None).await?;
			let coins: Vec<bark::joinblaket::JarCoin> = serde_json::from_value(result["utxos"].clone()).context("Invalid Jam coins")?;
			Ok(json!({"jars": bark::joinblaket::jar_balances(&coins)?, "utxos": coins.iter().map(|coin| json!({
				"utxo":coin.utxo,"value":coin.value,"mixdepth":coin.mixdepth,"confirmations":coin.confirmations,
				"frozen":coin.frozen,"locktime":coin.locktime})).collect::<Vec<_>>()}))
		},
		Operation::Address => {
			let jar = input.jar.context("Select a jar")?;
			bark::joinblaket::JarId::try_from(jar)?;
			let result = upstream(&client, &base, &["wallet", &input.wallet, "address", "new", &jar.to_string()], &input.token, None).await?;
			Ok(json!({"address":result["address"]}))
		},
		Operation::BondAddress => {
			let month = input.lock_month.context("Choose an unlock month")?;
			bond_month(&month, chrono::Utc::now())?;
			ensure!(session["coinjoin_in_process"] == false && session["rescanning"] == false, "Wait for the current Jam operation to finish");
			let result = upstream(&client, &base, &["wallet", &input.wallet, "address", "timelock", "new", &month], &input.token, None).await?;
			let address = result["address"].as_str().context("Jam returned no bond address")?;
			ensure!(!address.is_empty() && address.len() <= 128 && !address.chars().any(char::is_whitespace), "Jam returned an invalid bond address");
			// Address registration only. Funding/broadcast is deliberately not exposed.
			Ok(json!({"address": address, "wallet": input.wallet, "lock_month": month}))
		},
		Operation::StartMaker => {
			let terms = maker_body(&input)?;
			ensure!(session["maker_running"] == false && session["coinjoin_in_process"] == false && session["rescanning"] == false, "Wait for the current Jam operation to finish");
			upstream(&client, &base, &["wallet", &input.wallet, "maker", "start"], &input.token, Some(terms)).await?;
			Ok(json!({"requested":true}))
		},
		Operation::StopMaker => {
			upstream(&client, &base, &["wallet", &input.wallet, "maker", "stop"], &input.token, None).await?;
			Ok(json!({"requested":true}))
		},
		Operation::Wallets | Operation::CreateWallet | Operation::BackupWallet | Operation::Unlock | Operation::Identity | Operation::PairingSession => unreachable!("handled above"),
	}
}

fn payment_identifier(value: &str) -> bool {
	value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Only the fields needed for recovery cross the browser boundary. No approval
/// token, inputs, wallet identity, signed bytes or future upstream fields escape.
fn recovery_payment(value: &Value, wallet: &str) -> anyhow::Result<Value> {
	let id = value["id"].as_str().context("Missing Jam payment reference")?;
	ensure!(payment_identifier(id), "Invalid Jam payment reference");
	let state = value["state"].as_str().context("Missing Jam payment state")?;
	ensure!(["preparing", "prepared", "submitting", "unknown", "submitted", "cancelled"].contains(&state), "Unknown Jam payment state");
	let quote = &value["quote"];
	let quote = if quote.is_null() {
		ensure!(["preparing", "cancelled"].contains(&state), "Missing Jam payment details");
		Value::Null
	} else {
		ensure!(quote["wallet"] == wallet, "Jam payment belongs to a different wallet");
		ensure!(quote["jar"].as_u64().is_some_and(|jar| jar < 5), "Invalid Jam payment jar");
		ensure!(quote["purpose"].as_str().is_some_and(|purpose| ["send", "fund_bond", "withdraw_bond"].contains(&purpose)), "Unknown Jam payment purpose");
		ensure!(quote["txid"].as_str().is_some_and(payment_identifier), "Invalid Jam transaction reference");
		let destination = quote["destination"].as_str().context("Missing Jam destination")?;
		ensure!((14..=90).contains(&destination.len()) && destination.bytes().all(|b| b.is_ascii_alphanumeric()), "Invalid Jam destination");
		let amounts: Vec<u64> = ["amount_sat", "fee_sat", "total_sat"].iter().map(|key| {
			quote[key].as_u64().filter(|n| *n <= 2_100_000_000_000_000).context("Invalid Jam payment amount")
		}).collect::<anyhow::Result<_>>()?;
		ensure!(amounts[0] > 0 && amounts[0] + amounts[1] == amounts[2], "Inconsistent Jam payment total");
		let mode = quote.get("coinjoin").map(|v| v.as_bool().context("Invalid Jam payment mode")).transpose()?.unwrap_or(false);
		let mut clean = json!({"wallet": wallet, "jar": quote["jar"], "purpose": quote["purpose"],
			"destination": destination, "txid": quote["txid"], "amount_sat": amounts[0],
			"fee_sat": amounts[1], "total_sat": amounts[2]});
		if quote.get("coinjoin").is_some() { clean["coinjoin"] = mode.into(); }
		if let Some(stamp) = quote.get("bond_locktime").filter(|value| !value.is_null()) {
			ensure!(quote["purpose"] != "send" && stamp.as_i64().is_some_and(|v| (1_577_836_800..=4_099_766_400).contains(&v)), "Invalid saved bond unlock date");
			clean["bond_locktime"] = stamp.clone();
		}
		if mode {
			let fees: Vec<u64> = ["maker_fee_sat", "mining_fee_sat", "network_fee_sat"].iter().map(|key| {
				quote[key].as_u64().filter(|n| *n <= 2_100_000_000_000_000).context("Invalid CoinJoin fees")
			}).collect::<anyhow::Result<_>>()?;
			ensure!(quote["purpose"] == "send" && fees[0]+fees[1] == amounts[1] && fees[1] <= fees[2]
				&& quote["maker_count"].as_u64().is_some_and(|n| (2..=20).contains(&n)) && quote["broadcast_policy"] == "self", "Invalid CoinJoin review");
			for key in ["maker_fee_sat", "mining_fee_sat", "network_fee_sat", "maker_count", "broadcast_policy"] { clean[key] = quote[key].clone(); }
		}
		clean
	};
	Ok(json!({"id": id, "state": state, "quote": quote}))
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
	fn jam_send_reviews_bind_wallet_recipient_cost_and_expiry() {
		let cases: Vec<Value> = serde_json::from_str(include_str!("../../../../mobile/Tests/PaperclipMobileTests/Fixtures/jam-send-review.json")).unwrap();
		let terms = SendTerms { jar:0, destination:"bcrt1qsyntheticrecipient".into(), amount_sat:20000, fee_rate_millisat_vb:1000, max_fee_sat:500, coinjoin:false };
		let identity = format!("xbt-regtest:{}", "c".repeat(64));
		for case in cases {
			let result = send_review(&case["review"], "fixture.jmdat", &identity, 2000000000).and_then(|review| {
				ensure!(review["id"] == "a".repeat(64), "Changed id"); verify_send_terms(&review, &SendTerms { coinjoin:case["coinjoin"].as_bool().unwrap_or(false), ..terms.clone() })
			});
			assert_eq!(result.is_ok(), case["valid"].as_bool().unwrap(), "{}", case["name"]);
		}
		let body = terms.body(&"a".repeat(64)).unwrap();
		assert_eq!(body["max_total_sat"], 20500); assert_eq!(body["send_max"], false);
		let excessive = SendTerms { amount_sat:u64::MAX, ..terms };
		assert!(excessive.body(&"a".repeat(64)).is_err());
	}
	#[test]
	fn maker_fee_modes_bind_exact_supported_grid_values() {
		for fee in MAKER_ABSOLUTE_FEES {
			let input: Request = serde_json::from_value(json!({"operation":"start_maker","minimum_sat":100000,"fee_sat":fee})).unwrap();
			assert_eq!(maker_body(&input).unwrap()["cjfee_a"], fee.to_string());
		}
		for rate in MAKER_RELATIVE_FEES {
			let input: Request = serde_json::from_value(json!({"operation":"start_maker","minimum_sat":100000,"relative_fee":rate})).unwrap();
			let body = maker_body(&input).unwrap();
			assert_eq!(body["cjfee_r"], rate); assert_eq!(body["ordertype"], "sw0reloffer"); assert_eq!(body["cjfee_a"], "0");
		}
		for value in [json!({"fee_sat":123}), json!({"relative_fee":"0.005%"}), json!({"relative_fee":"NaN"}), json!({"relative_fee":"0.00005","fee_sat":100}), json!({})] {
			let mut value = value; value["operation"] = "start_maker".into(); value["minimum_sat"] = 100000.into();
			assert!(maker_body(&serde_json::from_value(value).unwrap()).is_err());
		}
	}
	#[test]
	fn jam_browser_handoff_never_points_to_host_loopback() {
		for url in ["https://localhost:28183", "https://jam.localhost", "https://127.0.0.1:28183", "https://127.1.2.3", "https://[::1]", "https://0.0.0.0", "https://[::]", "http://jam.example", "https://example.onion"] {
			assert!(!browser_handoff(&url.parse().unwrap()));
		}
		for url in ["https://jam.example", "https://192.168.1.23:28183"] { assert!(browser_handoff(&url.parse().unwrap())); }
	}
	#[test]
	fn jam_creation_validates_filename_and_keeps_secrets_out_of_normal_responses() {
		let mut input: Request = serde_json::from_value(json!({"operation":"create_wallet","wallet":"My-Jars.jmdat","password":"synthetic-password"})).unwrap();
		assert!(create_body(&input).is_ok());
		for name in ["../wallet.jmdat", "wallet", ".jmdat", "a/b.jmdat", "a\\b.jmdat", "a\0.jmdat", "a b.jmdat"] {
			input.wallet = name.into(); assert!(create_body(&input).is_err());
		}
		input.wallet = "My-Jars.jmdat".into(); input.password = "short".into(); assert!(create_body(&input).is_err());
		input.password = "synthetic-password".into(); input.bip39_passphrase = "unexpected-passphrase".into(); assert!(create_body(&input).is_err());
		let result = wallet_authorization(&json!({"walletname":"My-Jars.jmdat","token":"synthetic-token",
			"seedphrase":"must-not-escape","refresh_token":"must-not-escape"}), "My-Jars.jmdat").unwrap();
		assert!(result.get("seedphrase").is_none() && result.get("refresh_token").is_none());
		assert!(wallet_authorization(&json!({"walletname":"other.jmdat","token":"synthetic-token"}), "My-Jars.jmdat").is_err());
		assert!(wallet_authorization(&json!({"walletname":"My-Jars.jmdat","token":""}), "My-Jars.jmdat").is_err());
	}
	#[test]
	fn jam_recovery_matches_shared_cases_and_strips_private_fields() {
		let cases: Value = serde_json::from_str(include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../mobile/Tests/PaperclipMobileTests/Fixtures/jam-recovery.json"))).unwrap();
		for case in cases.as_array().unwrap() {
			assert_eq!(recovery_payment(&case["payment"], "fixture.jmdat").is_ok(), case["valid"].as_bool().unwrap(), "{}", case["name"]);
			if case["valid"] == true {
				let clean = recovery_payment(&case["payment"], "fixture.jmdat").unwrap();
				assert_eq!(clean["quote"]["bond_locktime"], case["payment"]["quote"]["bond_locktime"]);
			}
		}
		let mut record = cases[0]["payment"].clone();
		record["approval"] = "synthetic-approval".into();
		record["signed_tx"] = "synthetic-private-bytes".into();
		record["quote"]["wallet_identity"] = "synthetic-identity".into();
		record["quote"]["inputs"] = json!(["synthetic-input"]);
		let result = recovery_payment(&record, "fixture.jmdat").unwrap();
		assert_eq!(result, cases[0]["payment"]);
	}

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
	#[test]
	fn bond_month_uses_future_utc_month_and_supported_derivation_range() {
		let now = chrono::DateTime::parse_from_rfc3339("2030-05-01T00:00:00Z").unwrap().to_utc();
		for invalid in ["2030-05", "2030-04", "2030-00", "2030-13", "2030-6", "2100-01", "2019-12", "2031-01/other", "２０３１-01"] {
			assert!(bond_month(invalid, now).is_err(), "{invalid}");
		}
		for valid in ["2030-06", "2032-02", "2099-12"] { assert!(bond_month(valid, now).is_ok()); }
	}
}
