//! Per-request hot wallets. A browser selection never changes another client's wallet.
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::Context;
use axum::body::Body;
use axum::extract::{Path as RoutePath, State};
use axum::http::{Request, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use tower::ServiceExt;

use bark::lock_manager::pid_flock::FlockPidLockManager;

use crate::{BoxFuture, ServerState};
use crate::auth::authed_router;
use crate::error::{HandlerResult, badarg};

pub type OpenProfile = dyn Fn(PathBuf) -> BoxFuture<anyhow::Result<ServerState>> + Send + Sync;
const LIMIT: usize = 16;
const MARKER: &str = "hot-wallet-profile";

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
	id: String,
	label: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Catalog {
	version: u32,
	profiles: Vec<Profile>,
}

pub struct Profiles {
	directory: PathBuf,
	catalog: tokio::sync::Mutex<Catalog>,
	states: parking_lot::RwLock<HashMap<String, Arc<ServerState>>>,
	locks: parking_lot::Mutex<Vec<FlockPidLockManager>>,
	open: Arc<OpenProfile>,
}

fn valid_id(id: &str) -> bool {
	id.len() == 64 && id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

fn valid_label(label: &str) -> bool {
	!label.is_empty() && label == label.trim() && label.chars().count() <= 64
		&& !label.chars().any(char::is_control)
}

fn private_directory(path: &Path) -> anyhow::Result<()> {
	match std::fs::create_dir(path) {
		Ok(()) => bark::fs_perms::harden(path, 0o700)?,
		Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {},
		Err(e) => return Err(e.into()),
	}
	ensure!(std::fs::symlink_metadata(path)?.file_type().is_dir(), "Wallet directory must not be an alias");
	bark::fs_perms::refuse_if_loose(path, 0o700)
}

impl Profiles {
	/// Open all saved wallets so Ark maintenance does not depend on a browser tab.
	/// The caller owns the root daemon lock for this registry's entire lifetime.
	pub async fn open(datadir: &Path, open: Arc<OpenProfile>) -> anyhow::Result<Self> {
		let directory = datadir.join("hot-wallets");
		private_directory(&directory)?;
		let path = directory.join("profiles.json");
		let catalog = match std::fs::symlink_metadata(&path) {
			Ok(meta) => {
				ensure!(meta.is_file() && !meta.file_type().is_symlink() && meta.len() <= 65536, "Invalid wallet catalog");
				bark::fs_perms::refuse_if_loose(&path, 0o600)?;
				serde_json::from_slice::<Catalog>(&std::fs::read(&path)?)?
			},
			Err(e) if e.kind() == std::io::ErrorKind::NotFound => Catalog { version: 1, profiles: vec![] },
			Err(e) => return Err(e.into()),
		};
		ensure!(catalog.version == 1 && catalog.profiles.len() <= LIMIT, "Unsupported wallet catalog");
		let mut ids = HashSet::new();
		for profile in &catalog.profiles {
			ensure!(valid_id(&profile.id) && valid_label(&profile.label) && ids.insert(profile.id.clone()), "Invalid wallet catalog entry");
		}
		let registry = Self { directory, catalog: tokio::sync::Mutex::new(catalog), states: Default::default(), locks: Default::default(), open };
		let saved = registry.catalog.lock().await.profiles.clone();
		for profile in saved {
			// Never reconstruct a missing datadir: it could turn a lost wallet into an empty one.
			let path = registry.directory.join(&profile.id);
			ensure!(std::fs::symlink_metadata(&path)?.file_type().is_dir(), "Saved wallet directory is missing or an alias");
			bark::fs_perms::refuse_if_loose(&path, 0o700)?;
			let marker = path.join(MARKER);
			let meta = std::fs::symlink_metadata(&marker)?;
			ensure!(meta.file_type().is_file() && meta.len() == 64, "Invalid wallet directory identity");
			bark::fs_perms::refuse_if_loose(&marker, 0o600)?;
			ensure!(std::fs::read_to_string(marker)? == profile.id, "Wallet directory identity mismatch");
			registry.locks.lock().push(FlockPidLockManager::new_with_lock_file(&path, "barkd.lock")?);
			match (registry.open)(path).await {
				Ok(state) => { registry.states.write().insert(profile.id, Arc::new(state)); },
				Err(error) => {
					registry.stop_wait().await?;
					return Err(error.context("Could not open a saved hot wallet"));
				},
			}
		}
		Ok(registry)
	}

	async fn save(&self, profile: Profile, rename: bool) -> anyhow::Result<()> {
		ensure!(valid_id(&profile.id) && valid_label(&profile.label), "Enter a valid wallet ID and name");
		let mut catalog = self.catalog.lock().await;
		let mut next = catalog.clone();
		let mut created = None;
		if let Some(existing) = next.profiles.iter_mut().find(|p| p.id == profile.id) {
			if !rename {
				ensure!(existing.label == profile.label, "Wallet registration differs from the saved request");
				return Ok(()); // Exact registration retries are safe; they never create keys.
			}
			existing.label = profile.label.clone();
		} else {
			ensure!(!rename, "Wallet not found");
			ensure!(next.profiles.len() < LIMIT, "This host supports up to 16 additional hot wallets");
			let path = self.directory.join(&profile.id);
			// Refuse orphaned contents instead of importing or wiping them implicitly.
			std::fs::create_dir(&path).context("Wallet directory already exists; inspect recovery before retrying")?;
			bark::fs_perms::harden(&path, 0o700)?;
			bark::fs_perms::write_atomic_owner_only(&path.join(MARKER), profile.id.as_bytes())?;
			let lock = FlockPidLockManager::new_with_lock_file(&path, "barkd.lock")?;
			let state = (self.open)(path).await?;
			created = Some((Arc::new(state), lock));
			next.profiles.push(profile.clone());
		}
		if let Err(error) = bark::fs_perms::write_atomic_owner_only(
			&self.directory.join("profiles.json"), &serde_json::to_vec(&next)?,
		) {
			// Do not expose an unregistered state when persistence failed.
			if !rename {
				if let Some((state, _lock)) = created { state.stop_wallet_wait().await?; }
			}
			return Err(error);
		}
		if let Some((state, lock)) = created {
			self.states.write().insert(profile.id.clone(), state);
			self.locks.lock().push(lock);
		}
		*catalog = next;
		Ok(())
	}

	pub fn stop(&self) {
		for state in self.states.read().values() { state.stop_wallet(); }
	}

	pub async fn stop_wait(&self) -> anyhow::Result<()> {
		self.stop();
		let states: Vec<_> = self.states.read().values().cloned().collect();
		let mut failure = None;
		for state in states { if let Err(error) = state.stop_wallet_wait().await { failure = Some(error); } }
		match failure { Some(error) => Err(error), None => Ok(()) }
	}
}

impl Drop for Profiles {
	fn drop(&mut self) { self.stop(); }
}

pub(crate) fn router(state: &Arc<ServerState>) -> Router<Arc<ServerState>> {
	authed_router(state, Router::new()
		.route("/api/profiles", get(list).post(register))
		.route("/api/profiles/{id}/receive", axum::routing::post(receive))
		.route("/api/profiles/{id}/name", axum::routing::post(rename))
		.route("/api/profiles/{id}/v1/{*path}", any(dispatch)))
}

async fn list(State(state): State<Arc<ServerState>>) -> Response {
	let Some(profiles) = &state.profiles else { return StatusCode::NOT_FOUND.into_response(); };
	Json(profiles.catalog.lock().await.clone()).into_response()
}

async fn register(State(state): State<Arc<ServerState>>, Json(profile): Json<Profile>) -> Response {
	let Some(profiles) = &state.profiles else { return StatusCode::NOT_FOUND.into_response(); };
	match profiles.save(profile.clone(), false).await {
		Ok(()) => Json(profile).into_response(),
		Err(_) => (StatusCode::CONFLICT, Json(serde_json::json!({"message":"Could not register this wallet. Reload your wallet list before retrying."}))).into_response(),
	}
}

async fn rename(State(state): State<Arc<ServerState>>, RoutePath(id): RoutePath<String>, Json(profile): Json<Profile>) -> Response {
	let Some(profiles) = &state.profiles else { return StatusCode::NOT_FOUND.into_response(); };
	if profile.id != id { return StatusCode::BAD_REQUEST.into_response(); }
	match profiles.save(profile.clone(), true).await {
		Ok(()) => Json(profile).into_response(),
		Err(_) => StatusCode::CONFLICT.into_response(),
	}
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReceiveRequest { network: bitcoin::Network }

/// Generate a receiving address without changing the sending wallet's state.
async fn receive(State(state): State<Arc<ServerState>>, RoutePath(id): RoutePath<String>, Json(request): Json<ReceiveRequest>) -> HandlerResult<Json<serde_json::Value>> {
	let Some(profiles) = &state.profiles else { badarg!("Multiple wallets are unavailable"); };
	let (target, label) = if id == "main" {
		(state.clone(), "Main wallet".to_owned())
	} else {
		let catalog = profiles.catalog.lock().await;
		let Some(profile) = catalog.profiles.iter().find(|p| p.id == id) else { badarg!("Receiving wallet is unavailable"); };
		let Some(target) = profiles.states.read().get(&id).cloned() else { badarg!("Receiving wallet is unavailable"); };
		(target, profile.label.clone())
	};
	let _lifecycle = target.wallet_lifecycle.lock().await;
	let wallet = target.require_wallet()?;
	if wallet.properties().await?.network != request.network { badarg!("The receiving wallet uses a different network"); }
	let address = target.require_onchain()?.write().await.address().await?;
	Ok(Json(serde_json::json!({"account": format!("hot:{id}"), "label":label,
		"address":address.to_string(), "network":request.network})))
}

async fn dispatch(State(state): State<Arc<ServerState>>, RoutePath((id, path)): RoutePath<(String, String)>, mut request: Request<Body>) -> Response {
	let Some(profiles) = &state.profiles else { return StatusCode::NOT_FOUND.into_response(); };
	if !valid_id(&id) { return StatusCode::NOT_FOUND.into_response(); }
	let child = profiles.states.read().get(&id).cloned();
	let Some(child) = child else { return StatusCode::NOT_FOUND.into_response(); };
	// Jars belongs to the host, with a separate wallet and pairing authorization.
	if path.starts_with("joinblaket") || path.starts_with("paired-jars") {
		return StatusCode::NOT_FOUND.into_response();
	}
	let suffix = request.uri().query().map(|q| format!("?{q}")).unwrap_or_default();
	let Ok(uri) = format!("/{path}{suffix}").parse::<Uri>() else { return StatusCode::BAD_REQUEST.into_response(); };
	*request.uri_mut() = uri;
	// Remove outer route captures; child handlers must see only their own parameters.
	request.extensions_mut().clear();
	let router = crate::api::v1::router(&child).with_state(child);
	match router.oneshot(request).await { Ok(response) => response, Err(never) => match never {} }
}

#[cfg(test)]
mod tests {
	use super::*;
	use axum::body::to_bytes;
	use crate::auth::AuthToken;
	use tokio_util::sync::CancellationToken;

	fn factory() -> Arc<OpenProfile> {
		Arc::new(|path| Box::pin(async move {
			let id = path.file_name().unwrap().to_str().unwrap().to_owned();
			// Synthetic marker, not a wallet or real seed; identifies the selected state.
			let hook: Box<crate::OnGetMnemonic> = Box::new(move || {
				let id = id.clone(); Box::pin(async move { Ok(id) })
			});
			Ok(ServerState::builder().on_get_mnemonic(hook).auth_token(AuthToken::new([7; 32]))
				.build(CancellationToken::new()))
		}))
	}

	fn profile(byte: &str) -> Profile { Profile { id: byte.repeat(64), label: format!("Wallet {byte}") } }

	async fn request(state: Arc<ServerState>, path: &str, method: &str, body: &str, authorized: bool) -> Response {
		let mut builder = Request::builder().uri(path).method(method).header("content-type", "application/json");
		if authorized { builder = builder.header("authorization", format!("Bearer {}", AuthToken::new([7; 32]).encode())); }
		router(&state).with_state(state).oneshot(builder.body(Body::from(body.to_owned())).unwrap()).await.unwrap()
	}

	#[tokio::test]
	async fn profiles_route_to_independent_states_and_never_fall_back() {
		let directory = tempfile::tempdir().unwrap();
		let profiles = Arc::new(Profiles::open(directory.path(), factory()).await.unwrap());
		profiles.save(profile("a"), false).await.unwrap();
		profiles.save(profile("b"), false).await.unwrap();
		let state = Arc::new(ServerState::builder().profiles(profiles.clone()).auth_token(AuthToken::new([7; 32])).build(CancellationToken::new()));
		let a = format!("/api/profiles/{}/v1/wallet/mnemonic", "a".repeat(64));
		let b = format!("/api/profiles/{}/v1/wallet/mnemonic", "b".repeat(64));
		let (first, second) = tokio::join!(request(state.clone(), &a, "GET", "", true), request(state.clone(), &b, "GET", "", true));
		for (response, id) in [(first, "a"), (second, "b")] {
			assert_eq!(response.status(), StatusCode::OK);
			let value: serde_json::Value = serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap()).unwrap();
			assert_eq!(value["mnemonic"], id.repeat(64));
		}
		assert_eq!(request(state.clone(), &a, "GET", "", false).await.status(), StatusCode::UNAUTHORIZED);
		assert_eq!(request(state.clone(), &a.replace(&"a".repeat(64), &"c".repeat(64)), "GET", "", true).await.status(), StatusCode::NOT_FOUND);
		assert_eq!(request(state.clone(), &a.replace("wallet/mnemonic", "joinblaket/connection"), "GET", "", true).await.status(), StatusCode::NOT_FOUND);
		assert_eq!(request(state.clone(), "/api/profiles", "GET", "", false).await.status(), StatusCode::UNAUTHORIZED);
		let receive_path = format!("/api/profiles/{}/receive", "a".repeat(64));
		assert_eq!(request(state.clone(), &receive_path, "POST", r#"{"network":"regtest"}"#, false).await.status(), StatusCode::UNAUTHORIZED);
		assert_eq!(request(state.clone(), &receive_path, "POST", r#"{"network":"regtest"}"#, true).await.status(), StatusCode::UNPROCESSABLE_ENTITY);
		// Locking one wallet's mutation gate does not stop a different wallet.
		let first = profiles.states.read().get(&"a".repeat(64)).unwrap().clone();
		let second = profiles.states.read().get(&"b".repeat(64)).unwrap().clone();
		let _guard = first.wallet_lifecycle.lock().await;
		assert!(second.wallet_lifecycle.try_lock().is_ok());
		assert!(!Arc::ptr_eq(&first, &second));
		assert_eq!(request(state, &a.replace("wallet/mnemonic", "lightning/receives/test"), "GET", "", true).await.status(), StatusCode::UNPROCESSABLE_ENTITY);
	}

	#[tokio::test]
	async fn profiles_persist_names_and_registration_is_idempotent() {
		let directory = tempfile::tempdir().unwrap();
		let profiles = Profiles::open(directory.path(), factory()).await.unwrap();
		profiles.save(profile("a"), false).await.unwrap();
		profiles.save(profile("a"), false).await.unwrap();
		let renamed = Profile { label: "Savings".into(), ..profile("a") };
		assert!(profiles.save(renamed.clone(), false).await.is_err());
		profiles.save(renamed, true).await.unwrap();
		drop(profiles);
		let reopened = Profiles::open(directory.path(), factory()).await.unwrap();
		assert_eq!(reopened.catalog.lock().await.profiles.len(), 1);
		assert_eq!(reopened.catalog.lock().await.profiles[0].label, "Savings");
		assert_eq!(reopened.states.read().len(), 1);
		assert!(FlockPidLockManager::new_with_lock_file(directory.path().join("hot-wallets").join("a".repeat(64)), "barkd.lock").is_err());
	}

	#[tokio::test]
	async fn profiles_reject_aliases_missing_storage_corruption_and_orphans() {
		let directory = tempfile::tempdir().unwrap();
		let profiles = Profiles::open(directory.path(), factory()).await.unwrap();
		assert!(profiles.save(Profile { id: "../escape".into(), label: "Bad".into() }, false).await.is_err());
		assert!(profiles.save(Profile { id: "a".repeat(64), label: "bad\nname".into() }, false).await.is_err());
		std::fs::create_dir(directory.path().join("hot-wallets").join("b".repeat(64))).unwrap();
		assert!(profiles.save(profile("b"), false).await.is_err());
		profiles.save(profile("a"), false).await.unwrap();
		drop(profiles);
		std::fs::remove_dir_all(directory.path().join("hot-wallets").join("a".repeat(64))).unwrap();
		assert!(Profiles::open(directory.path(), factory()).await.is_err());
		assert!(!directory.path().join("hot-wallets").join("a".repeat(64)).exists());
		bark::fs_perms::write_atomic_owner_only(&directory.path().join("hot-wallets/profiles.json"), b"{}").unwrap();
		assert!(Profiles::open(directory.path(), factory()).await.is_err());
	}

	#[cfg(unix)]
	#[tokio::test]
	async fn profiles_never_follow_catalog_or_wallet_symlinks() {
		let directory = tempfile::tempdir().unwrap();
		let profiles = Profiles::open(directory.path(), factory()).await.unwrap();
		profiles.save(profile("a"), false).await.unwrap();
		drop(profiles);
		let saved = directory.path().join("hot-wallets").join("a".repeat(64));
		std::fs::remove_dir_all(&saved).unwrap();
		std::os::unix::fs::symlink(directory.path(), &saved).unwrap();
		assert!(Profiles::open(directory.path(), factory()).await.is_err());
		std::fs::remove_file(directory.path().join("hot-wallets/profiles.json")).unwrap();
		std::os::unix::fs::symlink("absent", directory.path().join("hot-wallets/profiles.json")).unwrap();
		assert!(Profiles::open(directory.path(), factory()).await.is_err());
	}
}
