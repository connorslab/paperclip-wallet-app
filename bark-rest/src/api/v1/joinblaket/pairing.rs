//! Revocable, wallet-bound mobile access. A Jars grant is never a barkd token.
//! Only the owner's authenticated UI can create or revoke grants. The raw Jam
//! credential stays in private host storage, and new operations default to denied.
use std::{io::Write, path::{Path, PathBuf}, sync::Arc};

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::{DefaultBodyLimit, Query, State}, http::{HeaderMap, StatusCode, header}, routing::{get, post}};
use bitcoin::hashes::{Hash, sha256};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{Operation, Request, execute_bound, wallet_path};
use crate::ServerState;

const LIFETIME: i64 = 30 * 24 * 60 * 60;
const LIMIT: usize = 16;

/// Existing saved grants stay management-only; spending always needs a new code.
#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) enum Scope {
	#[default]
	#[serde(rename = "jars_manage_v1")] Manage,
	#[serde(rename = "jars_pay_v1")] Pay,
}

// Contains an upstream bearer credential. Never derive Debug or return a Record.
#[derive(Clone, Serialize, Deserialize)]
struct Record { #[serde(default)] scope: Scope, id: String, label: String, wallet: String, identity: String, upstream: String, token: String, expires: i64 }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Create { label: String, wallet: String, token: String, #[serde(default)] scope: Scope }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Revoke { id: String }

pub(super) fn owner_router() -> Router<Arc<ServerState>> {
	Router::new().route("/pairings", get(list).post(create)).route("/pairings/revoke", post(revoke)).route("/pairings/connection", get(connection))
}
pub fn paired_router() -> Router<Arc<ServerState>> {
	Router::new().route("/request", post(request)).layer(DefaultBodyLimit::max(64 * 1024))
}
pub(super) fn valid_identity(value: &str) -> bool {
	value.split_once(':').is_some_and(|(network, key)|
		["xbt-mainnet", "xbt-testnet", "xbt-signet", "xbt-regtest"].contains(&network) && super::payment_identifier(key))
}
fn digest(value: &str) -> String { sha256::Hash::hash(value.as_bytes()).to_string() }
fn binding() -> anyhow::Result<String> {
	let address = std::env::var("BARKD_JOINBLAKET_URL").context("Configure bundled Jars first")?;
	let proxy = std::env::var("BARKD_JOINBLAKET_TOR_PROXY").ok();
	let endpoint = super::endpoint(&address, proxy.as_deref())?;
	Ok(digest(&format!("{}\n{}", endpoint, proxy.unwrap_or_default())))
}
fn root(state: &ServerState) -> anyhow::Result<PathBuf> {
	ensure!(state.auth_token().is_some(), "Configure wallet authentication first");
	let path = state.web.as_ref().context("Pairing storage unavailable")?.datadir.join("jam-pairings");
	ensure!(!path.is_symlink(), "Invalid pairing storage");
	std::fs::create_dir_all(&path).context("Could not open pairing storage")?;
	#[cfg(unix)] { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))?; }
	Ok(path)
}
fn load(root: &Path) -> anyhow::Result<Vec<Record>> {
	let path = root.join("grants.json");
	ensure!(!path.is_symlink(), "Invalid pairing storage");
	let metadata = match std::fs::metadata(&path) {
		Ok(value) => value,
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
		Err(_) => anyhow::bail!("Could not read pairings"),
	};
	ensure!(metadata.is_file() && metadata.len() <= 512 * 1024, "Invalid pairing storage");
	let records: Vec<Record> = serde_json::from_slice(&std::fs::read(path)?).map_err(|_| anyhow::anyhow!("Invalid pairing storage; restore its backup"))?;
	ensure!(records.len() <= LIMIT && records.iter().all(|row| super::payment_identifier(&row.id) && valid_identity(&row.identity)), "Invalid pairing storage");
	ensure!(records.iter().map(|r| &r.id).collect::<std::collections::HashSet<_>>().len() == records.len(), "Duplicate pairing record");
	Ok(records)
}
fn save(root: &Path, records: &[Record]) -> anyhow::Result<()> {
	let target = root.join("grants.json");
	ensure!(!target.is_symlink(), "Invalid pairing storage");
	let mut file = tempfile::NamedTempFile::new_in(root).context("Could not save pairing")?;
	file.write_all(&serde_json::to_vec(records)?)?;
	file.as_file().sync_all()?;
	file.persist(target).map_err(|_| anyhow::anyhow!("Could not save pairing"))?;
	std::fs::File::open(root)?.sync_all()?;
	Ok(())
}
fn credential(headers: &HeaderMap) -> anyhow::Result<String> {
	ensure!(headers.get_all(header::AUTHORIZATION).iter().count() == 1, "Pair this device again");
	let raw = headers.get(header::AUTHORIZATION).and_then(|h| h.to_str().ok()).and_then(|h| h.strip_prefix("Bearer pj1_"))
		.context("Pair this device again")?;
	ensure!(super::payment_identifier(raw), "Pair this device again");
	Ok(digest(&format!("pj1_{raw}")))
}
fn authorize(records: &[Record], id: &str, upstream: &str, now: i64, input: &Request) -> anyhow::Result<Record> {
	let record = records.iter().find(|r| r.id == id && r.expires > now && r.upstream == upstream).context("Pairing expired or revoked; pair this device again")?;
	ensure!(input.wallet == record.wallet && input.token.is_empty() && input.password.is_empty() && input.bip39_passphrase.is_empty(), "Pairing belongs to a different wallet");
	ensure!(matches!(input.operation, Operation::Status | Operation::Coins | Operation::Bonds | Operation::Address | Operation::BondAddress |
		Operation::StartMaker | Operation::StopMaker | Operation::Payments | Operation::CheckPayment | Operation::Market)
		|| (record.scope == Scope::Pay && matches!(input.operation, Operation::Identity | Operation::PaymentCapabilities | Operation::PaymentReview | Operation::PreparePayment | Operation::CommitPayment | Operation::CancelPayment)), "This pairing does not permit that operation");
	Ok(record.clone())
}
fn response(status: StatusCode, result: anyhow::Result<Value>) -> (StatusCode, HeaderMap, Json<Value>) {
	let mut headers = HeaderMap::new(); headers.insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
	match result { Ok(value) => (StatusCode::OK, headers, Json(value)), Err(error) => (status, headers, Json(json!({"message":error.to_string()}))) }
}
fn public(record: &Record) -> Value {
	json!({"id":record.id,"label":record.label,"wallet":record.wallet,"expires":record.expires,
		"scope":record.scope})
}
// Only trusted host configuration supplies this hint, never Host/Forwarded headers.
// This creates no listener, grant or outbound request.
fn onion_endpoint(value: &str) -> Option<String> {
	let value = value.trim();
	if value.is_empty() { return None; }
	let address = if value.contains("://") { value.to_owned() } else { format!("http://{value}") };
	let url = reqwest::Url::parse(&address).ok()?;
	let host = url.host_str()?.strip_suffix(".onion")?;
	if !["http", "https"].contains(&url.scheme()) || host.len() != 56 ||
		!host.bytes().all(|b| b.is_ascii_lowercase() || (b'2'..=b'7').contains(&b)) ||
		!url.username().is_empty() || url.password().is_some() || url.query().is_some() || url.fragment().is_some() ||
		url.path() != "/" { return None; }
	Some(url.to_string())
}
#[derive(Default, Deserialize)]
struct ConnectionQuery { endpoint: Option<String> }

// Discovery only contacts origins supplied by the package, not arbitrary URLs
// from the browser or proxy headers. No grant, cookie or Jam token is sent.
fn https_origin(value: &str) -> Option<reqwest::Url> {
	let url = reqwest::Url::parse(value).ok()?;
	if url.scheme() != "https" || url.host_str()?.ends_with(".onion") ||
		!url.username().is_empty() || url.password().is_some() || url.query().is_some() ||
		url.fragment().is_some() || url.path() != "/" { return None; }
	Some(url)
}
fn published_https(value: &str) -> Vec<reqwest::Url> {
	if value.len() > 16 * 1024 { return vec![]; }
	let addresses = serde_json::from_str::<Vec<String>>(value).unwrap_or_default();
	if addresses.len() > 32 { return vec![]; }
	addresses.iter().filter_map(|value| https_origin(value)).collect()
}
async fn verified_pairing_pin(endpoint: &str, published: &[reqwest::Url], ca: &str) -> anyhow::Result<String> {
	let url = https_origin(endpoint).context("Use a published HTTPS address")?;
	ensure!(published.contains(&url), "This address is not published by the host");
	ensure!(!ca.is_empty() && ca.len() <= 32 * 1024, "Host certificate trust is unavailable");
	let root = reqwest::Certificate::from_pem(ca.as_bytes()).context("Host certificate trust is unavailable")?;
	let mut client = reqwest::Client::builder().use_rustls_tls().no_proxy()
		.redirect(reqwest::redirect::Policy::none()).timeout(std::time::Duration::from_secs(8))
		.tls_built_in_root_certs(false).add_root_certificate(root).tls_info(true);
	// Minimal containers may have no mDNS resolver. StartOS publishes the LAN
	// addresses of this same interface; use those for transport while retaining
	// the requested hostname for SNI and certificate verification.
	if let Some(host) = url.host_str().filter(|host| host.ends_with(".local")) {
		let addresses: Vec<std::net::SocketAddr> = published.iter()
			.filter(|other| other.port_or_known_default() == url.port_or_known_default())
			.filter_map(|other| other.host_str()?.trim_matches(['[', ']']).parse::<std::net::IpAddr>().ok()
				.map(|ip| std::net::SocketAddr::new(ip, 0))).collect();
		if !addresses.is_empty() { client = client.resolve_to_addrs(host, &addresses); }
	}
	let client = client.build()?;
	// HEAD obtains the peer certificate without fetching a wallet page. HTTP
	// status does not affect TLS verification; redirects are never followed.
	let response = client.head(url).send().await.context("Could not verify the host certificate")?;
	ensure!(!response.status().is_redirection(), "Use the host's final HTTPS address");
	let certificate = response.extensions().get::<reqwest::tls::TlsInfo>()
		.and_then(|info| info.peer_certificate()).context("Host certificate unavailable")?;
	Ok(sha256::Hash::hash(certificate).to_string())
}
async fn connection(Query(query): Query<ConnectionQuery>) -> (StatusCode, HeaderMap, Json<Value>) {
	let onion = std::env::var("BARKD_JARS_PAIRING_ONION").ok().and_then(|value| onion_endpoint(&value));
	let published = published_https(&std::env::var("BARKD_JARS_PAIRING_HTTPS_ORIGINS").unwrap_or_default());
	let mut value = json!({"onion_endpoint":onion,"https_endpoints":published.iter().map(|url| url.as_str()).collect::<Vec<_>>()});
	if let Some(endpoint) = query.endpoint {
		let ca = std::env::var("BARKD_JARS_PAIRING_CA_PEM").unwrap_or_default();
		match verified_pairing_pin(&endpoint, &published, &ca).await {
			Ok(pin) => { value["https_endpoint"] = endpoint.into(); value["certificate_sha256"] = pin.into(); }
			Err(_) => { value["certificate_error"] = "Could not verify this host's HTTPS certificate. Use Tor pairing, or enter a fingerprint verified in your host settings.".into(); }
		}
	}
	response(StatusCode::BAD_REQUEST, Ok(value))
}
async fn list(State(state): State<Arc<ServerState>>) -> (StatusCode, HeaderMap, Json<Value>) {
	let _guard = state.jam_pairings.lock().await;
	response(StatusCode::BAD_REQUEST, (|| Ok(json!({"pairings":load(&root(&state)?)?.iter().map(public).collect::<Vec<_>>()})))())
}
async fn create(State(state): State<Arc<ServerState>>, Json(input): Json<Create>) -> (StatusCode, HeaderMap, Json<Value>) {
	response(StatusCode::BAD_REQUEST, async {
		let label = input.label.trim();
		ensure!(!label.is_empty() && label.chars().count() <= 48 && !label.chars().any(char::is_control), "Name this device using 1 to 48 characters");
		wallet_path(&input.wallet)?;
		let upstream = binding()?;
		let mut identity_request: Request = serde_json::from_value(json!({"operation":"identity","wallet":input.wallet,"token":input.token}))?;
		identity_request.operation = Operation::PairingSession;
		identity_request.pairing_scope = input.scope;
		let delegated = execute_bound(identity_request, None).await?;
		let identity = delegated["identity"].as_str().context("Jam identity unavailable")?.to_owned();
		let _guard = state.jam_pairings.lock().await;
		ensure!(binding()? == upstream, "Jam connection changed; try pairing again");
		let root = root(&state)?;
		let now = chrono::Utc::now().timestamp();
		let mut records = load(&root)?; records.retain(|r| r.expires > now);
		ensure!(records.len() < LIMIT, "Remove an old paired device first");
		let token = format!("pj1_{}", sha256::Hash::hash(&bitcoin::secp256k1::rand::random::<[u8;32]>()));
		let record = Record { scope:input.scope, id:digest(&token),label:label.into(),wallet:input.wallet,identity,upstream,
			token:delegated["token"].as_str().context("Jam pairing session unavailable")?.to_owned(),
			expires:delegated["expires"].as_i64().context("Jam pairing session expired")?.min(now+LIFETIME) };
		let mut result = public(&record); result["token"] = token.into();
		records.push(record); save(&root, &records)?;
		Ok(result)
	}.await)
}
async fn revoke(State(state): State<Arc<ServerState>>, Json(input): Json<Revoke>) -> (StatusCode, HeaderMap, Json<Value>) {
	let _guard = state.jam_pairings.lock().await;
	response(StatusCode::BAD_REQUEST, (|| {
		ensure!(super::payment_identifier(&input.id), "Select a paired device");
		let root = root(&state)?; let mut records = load(&root)?;
		records.retain(|r| r.id != input.id); save(&root, &records)?;
		Ok(json!({"revoked":true}))
	})())
}
async fn request(State(state): State<Arc<ServerState>>, headers: HeaderMap, Json(mut input): Json<Request>) -> (StatusCode, HeaderMap, Json<Value>) {
	// Authorize at dispatch. Revocation prevents new requests; it cannot undo an
	// action already accepted by Jam. No phone can unlock, export or switch wallets.
	let record = {
		let _guard = state.jam_pairings.lock().await;
		(|| authorize(&load(&root(&state)?)?, &credential(&headers)?, &binding()?, chrono::Utc::now().timestamp(), &input))()
	};
	let record = match record { Ok(record) => record, Err(error) => return response(StatusCode::UNAUTHORIZED, Err(error)) };
	input.token = record.token;
	response(StatusCode::BAD_REQUEST, execute_bound(input, Some(&record.identity)).await)
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::{io::Read, net::TcpListener, thread, time::Duration};
	use base64::Engine;
	const PAIRING_CA: &str = include_str!("fixtures/pairing-ca.pem");
	const PAIRING_CERT: &[u8] = include_bytes!("fixtures/pairing-leaf.der");
	// Synthetic localhost-only server key; never used for wallet data or release signing.
	const PAIRING_TEST_KEY: &[u8] = include_bytes!("fixtures/pairing-test-key.der");

	#[test]
	fn pairing_https_discovery_only_accepts_published_origins() {
		assert_eq!(published_https(r#"["https://start.local:123/","http://start.local/","https://[fe80::1%4]:123/","https://user@start.local/","https://start.local/path","https://start.local/?token=secret"]"#).len(), 1);
		assert!(published_https("not-json").is_empty());
		assert!(published_https(&serde_json::to_string(&vec!["https://start.local/";33]).unwrap()).is_empty());
		assert!(https_origin(&format!("https://{}.onion/", "a".repeat(56))).is_none());
	}

	async fn pairing_tls_probe(host: &str, ca: &str, status: &str) -> (anyhow::Result<String>, String) {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let url = format!("https://{}:{}/", host, listener.local_addr().unwrap().port());
		let config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
			.with_safe_default_protocol_versions().unwrap().with_no_client_auth()
			.with_single_cert(vec![PAIRING_CERT.to_vec().into()], rustls::pki_types::PrivatePkcs8KeyDer::from(PAIRING_TEST_KEY.to_vec()).into()).unwrap();
		let reply = format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nLocation: https://untrusted.invalid/\r\nConnection: close\r\n\r\n");
		let server = thread::spawn(move || {
			let (socket, _) = listener.accept().unwrap();
			socket.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
			let session = rustls::ServerConnection::new(Arc::new(config)).unwrap();
			let mut stream = rustls::StreamOwned::new(session, socket);
			let mut request = vec![];
			loop {
				let mut bytes = [0;1024];
				let Ok(count) = stream.read(&mut bytes) else { break; };
				if count == 0 { break; }
				request.extend_from_slice(&bytes[..count]);
				if request.windows(4).any(|b| b == b"\r\n\r\n") || request.len() > 4096 { break; }
			}
			let _ = stream.write_all(reply.as_bytes()); let _ = stream.flush();
			String::from_utf8(request).unwrap()
		});
		let published = [https_origin(&url).unwrap(), https_origin(&url.replace(host, "127.0.0.1")).unwrap()];
		let result = verified_pairing_pin(&url, &published, ca).await;
		(result, server.join().unwrap())
	}

	#[tokio::test]
	async fn pairing_https_verifies_chain_hostname_and_leaf_without_credentials() {
		let (pin, request) = pairing_tls_probe("localhost", PAIRING_CA, "401 Unauthorized").await;
		assert_eq!(pin.unwrap(), sha256::Hash::hash(PAIRING_CERT).to_string());
		assert!(request.starts_with("HEAD / HTTP/1.1"));
		assert!(!request.to_ascii_lowercase().contains("authorization:"));
		assert!(!request.to_ascii_lowercase().contains("cookie:"));
		let (mdns, _) = pairing_tls_probe("pairing-fixture.local", PAIRING_CA, "200 OK").await;
		assert_eq!(mdns.unwrap(), sha256::Hash::hash(PAIRING_CERT).to_string());
		let (wrong_name, request) = pairing_tls_probe("127.0.0.1", PAIRING_CA, "200 OK").await;
		assert!(wrong_name.is_err()); assert!(request.is_empty());
		let wrong_ca = format!("-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----", base64::engine::general_purpose::STANDARD.encode(include_bytes!("../remote_node/fixtures/node-cert.der")));
		let (wrong_root, request) = pairing_tls_probe("localhost", &wrong_ca, "200 OK").await;
		assert!(wrong_root.is_err()); assert!(request.is_empty());
		let (redirect, _) = pairing_tls_probe("localhost", PAIRING_CA, "302 Found").await;
		assert!(redirect.is_err());
		assert!(verified_pairing_pin("https://127.0.0.1:1/", &[], PAIRING_CA).await.unwrap_err().to_string().contains("not published"));
		assert!(verified_pairing_pin("https://localhost/", &[https_origin("https://localhost/").unwrap()], "").await.is_err());
	}

	fn record() -> Record { Record { scope:Scope::Manage, id:digest(&format!("pj1_{}", "a".repeat(64))),label:"Test phone".into(),wallet:"fixture.jmdat".into(),
		identity:format!("xbt-regtest:{}", "b".repeat(64)),upstream:"fixture-upstream".into(),token:"synthetic-jam-secret".into(),expires:100 } }
	fn input(operation: &str) -> Request { serde_json::from_value(json!({"operation":operation,"wallet":"fixture.jmdat"})).unwrap() }
	#[test]
	fn pairing_onion_hint_rejects_lan_credentials_and_ambiguous_addresses() {
		let host = format!("{}.onion", "a".repeat(56));
		assert_eq!(onion_endpoint(&host), Some(format!("http://{host}/")));
		assert_eq!(onion_endpoint(&format!("https://{host}:8443")), Some(format!("https://{host}:8443/")));
		for address in ["http://start.local".to_owned(), "http://short.onion".to_owned(), format!("http://user@{host}"),
			format!("http://{host}/other"), format!("http://{host}/?token=private"), format!("http://{host}/#fragment"), format!("ftp://{host}")] {
			assert!(onion_endpoint(&address).is_none());
		}
	}

	#[test]
	fn pairing_is_bound_expiring_and_defaults_to_deny() {
		let record = record(); let records = vec![record.clone()];
		for operation in ["status","coins","address","bond_address","start_maker","stop_maker","payments","check_payment","market"] {
			assert!(authorize(&records, &record.id, &record.upstream, 99, &input(operation)).is_ok());
		}
		for operation in ["wallets","unlock","identity","create_wallet","backup_wallet","cancel_payment","prepare_payment","commit_payment"] { assert!(authorize(&records,&record.id,&record.upstream,99,&input(operation)).is_err()); }
		assert!(authorize(&records,&record.id,&record.upstream,100,&input("status")).is_err());
		assert!(authorize(&records,&record.id,"other-upstream",99,&input("status")).is_err());
		assert!(authorize(&[],&record.id,&record.upstream,99,&input("status")).is_err());
		let mut request = input("status"); request.wallet = "other.jmdat".into();
		assert!(authorize(&records,&record.id,&record.upstream,99,&request).is_err());
		request.wallet = record.wallet.clone(); request.token = "injected-token".into();
		assert!(authorize(&records,&record.id,&record.upstream,99,&request).is_err());
		assert!(!public(&record).to_string().contains(&record.token));
	}
	#[test]
	fn bearer_is_not_a_main_wallet_token_and_duplicate_headers_fail() {
		let token = format!("pj1_{}", "a".repeat(64));
		assert!(crate::auth::AuthToken::decode(&token).is_err());
		let mut headers = HeaderMap::new(); headers.insert(header::AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
		assert_eq!(credential(&headers).unwrap(), digest(&token));
		headers.append(header::AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
		assert!(credential(&headers).is_err());
	}
	#[test]
	fn durable_revocation_and_failed_save_preserve_unrelated_data() {
		let dir = tempfile::tempdir().unwrap(); let records = vec![record()];
		save(dir.path(), &records).unwrap();
		assert_eq!(load(dir.path()).unwrap()[0].id, records[0].id);
		#[cfg(unix)] { use std::os::unix::fs::PermissionsExt; assert_eq!(std::fs::metadata(dir.path().join("grants.json")).unwrap().permissions().mode() & 0o777,0o600); }
		save(dir.path(), &[]).unwrap(); assert!(load(dir.path()).unwrap().is_empty());
		std::fs::remove_file(dir.path().join("grants.json")).unwrap();
		std::fs::create_dir(dir.path().join("grants.json")).unwrap();
		std::fs::write(dir.path().join("grants.json/keep"), "unrelated").unwrap();
		assert!(save(dir.path(), &records).is_err());
		assert_eq!(std::fs::read_to_string(dir.path().join("grants.json/keep")).unwrap(), "unrelated");
		assert!(load(dir.path()).is_err());
	}
	#[test]
	fn payment_pairings_are_explicit_and_cannot_escalate_legacy_grants() {
		let management = record();
		let mut encoded = serde_json::to_value(&management).unwrap();
		encoded.as_object_mut().unwrap().remove("scope");
		let legacy: Record = serde_json::from_value(encoded.clone()).unwrap();
		assert!(legacy.scope == Scope::Manage);
		encoded["scope"] = "all".into(); assert!(serde_json::from_value::<Record>(encoded).is_err());
		let mut pay = management.clone(); pay.scope = Scope::Pay;
		for operation in ["identity","payment_capabilities","payment_review","prepare_payment","commit_payment","cancel_payment"] {
			assert!(authorize(&[legacy.clone()], &legacy.id, &legacy.upstream, 99, &input(operation)).is_err());
			assert!(authorize(&[pay.clone()], &pay.id, &pay.upstream, 99, &input(operation)).is_ok());
			assert!(authorize(&[], &pay.id, &pay.upstream, 99, &input(operation)).is_err());
			assert!(authorize(&[pay.clone()], &pay.id, &pay.upstream, 100, &input(operation)).is_err());
		}
		for operation in ["wallets","unlock","create_wallet","backup_wallet"] {
			assert!(authorize(&[pay.clone()], &pay.id, &pay.upstream, 99, &input(operation)).is_err());
		}
		assert!(serde_json::from_value::<Request>(json!({"operation":"prepare_payment","wallet":"fixture.jmdat","pairing_scope":"jars_pay_v1"})).is_err());
		let create: Create = serde_json::from_value(json!({"label":"Phone","wallet":"fixture.jmdat","token":"synthetic"})).unwrap();
		assert!(create.scope == Scope::Manage);
		assert!(serde_json::from_value::<Create>(json!({"label":"Phone","wallet":"fixture.jmdat","token":"synthetic","scope":"all"})).is_err());
		let dir = tempfile::tempdir().unwrap(); save(dir.path(), &[pay]).unwrap();
		assert!(load(dir.path()).unwrap()[0].scope == Scope::Pay);
	}
	#[tokio::test]
	async fn paired_grant_never_authorizes_owner_or_main_wallet_routes() {
		use axum::{body::Body, http::Request as HttpRequest};
		use tower::ServiceExt;
		let state = Arc::new(ServerState::builder().auth_token(crate::auth::AuthToken::new([42;32]))
			.build(tokio_util::sync::CancellationToken::new()));
		let router = crate::api::v1::router(&state).with_state(state);
		for path in ["/joinblaket/pairings", "/wallet/balance", "/onchain/balance"] {
			let request = HttpRequest::builder().uri(path).header(header::AUTHORIZATION, format!("Bearer pj1_{}", "a".repeat(64))).body(Body::empty()).unwrap();
			assert_eq!(router.clone().oneshot(request).await.unwrap().status(), StatusCode::UNAUTHORIZED, "{path}");
		}
		let request = HttpRequest::builder().uri("/paired-jars/request").method("POST").header(header::CONTENT_TYPE,"application/json")
			.body(Body::from(r#"{"operation":"status","wallet":"fixture.jmdat"}"#)).unwrap();
		assert_eq!(router.oneshot(request).await.unwrap().status(), StatusCode::UNAUTHORIZED);
	}
}
