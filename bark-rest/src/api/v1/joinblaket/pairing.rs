//! Revocable, wallet-bound mobile access. A Jars grant is never a barkd token.
//! Only the owner's authenticated UI can create or revoke grants. The raw Jam
//! credential stays in private host storage, and new operations default to denied.
use std::{io::Write, path::{Path, PathBuf}, sync::Arc};

use anyhow::{Context, ensure};
use axum::{Json, Router, extract::{DefaultBodyLimit, State}, http::{HeaderMap, StatusCode, header}, routing::{get, post}};
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
	Router::new().route("/pairings", get(list).post(create)).route("/pairings/revoke", post(revoke))
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
	ensure!(matches!(input.operation, Operation::Status | Operation::Coins | Operation::Address | Operation::BondAddress |
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
	fn record() -> Record { Record { scope:Scope::Manage, id:digest(&format!("pj1_{}", "a".repeat(64))),label:"Test phone".into(),wallet:"fixture.jmdat".into(),
		identity:format!("xbt-regtest:{}", "b".repeat(64)),upstream:"fixture-upstream".into(),token:"synthetic-jam-secret".into(),expires:100 } }
	fn input(operation: &str) -> Request { serde_json::from_value(json!({"operation":operation,"wallet":"fixture.jmdat"})).unwrap() }
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
