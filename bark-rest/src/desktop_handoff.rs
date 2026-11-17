//! Ephemeral browser handoff for explicitly managed, authenticated loopback apps.
//! Codes stay in memory, expire after one minute and can be redeemed only once.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::{Extension, Json, Router};
use axum::extract::{DefaultBodyLimit, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use bitcoin::secp256k1::rand::{rngs::OsRng, RngCore};
use parking_lot::Mutex;
use serde::Deserialize;
use serde_json::json;

use crate::ServerState;
use crate::auth::{AuthToken, authed_router};

const LIFETIME: Duration = Duration::from_secs(60);

struct Grant {
	code: AuthToken,
	expires: Instant,
}

struct Handoff {
	origin: String,
	host: String,
	grant: Mutex<Option<Grant>>,
}

impl Handoff {
	fn issue(&self) -> String {
		let mut secret = [0u8; 32];
		OsRng.fill_bytes(&mut secret);
		let code = AuthToken::new(secret);
		let encoded = code.encode();
		*self.grant.lock() = Some(Grant { code, expires: Instant::now() + LIFETIME });
		encoded
	}

	fn redeem(&self, encoded: &str, now: Instant) -> bool {
		if encoded.len() != 44 { return false; }
		let Ok(code) = AuthToken::decode(encoded) else { return false; };
		let mut pending = self.grant.lock();
		if pending.as_ref().is_some_and(|grant| grant.expires <= now) {
			*pending = None;
		}
		if pending.as_ref().is_some_and(|grant| grant.code == code) {
			*pending = None;
			return true;
		}
		false
	}

	fn headers_match(&self, headers: &HeaderMap, require_origin: bool) -> bool {
		let matches = |name, value: &str| {
			let mut entries = headers.get_all(name).iter();
			entries.next().is_some_and(|header| header.as_bytes() == value.as_bytes())
				&& entries.next().is_none()
		};
		matches(header::HOST, &self.host)
			&& ((!require_origin && !headers.contains_key(header::ORIGIN))
				|| matches(header::ORIGIN, &self.origin))
	}
}

fn secret_response(value: serde_json::Value) -> Response {
	([(header::CACHE_CONTROL, "no-store"), (header::REFERRER_POLICY, "no-referrer")], Json(value)).into_response()
}

async fn issue(Extension(handoff): Extension<Arc<Handoff>>, headers: HeaderMap) -> Response {
	if !handoff.headers_match(&headers, false) {
		return StatusCode::FORBIDDEN.into_response();
	}
	secret_response(json!({"code": handoff.issue(), "expires_in": LIFETIME.as_secs()}))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Redemption { code: String }

async fn redeem(
	State(state): State<Arc<ServerState>>,
	Extension(handoff): Extension<Arc<Handoff>>,
	headers: HeaderMap,
	Json(request): Json<Redemption>,
) -> Response {
	if !handoff.headers_match(&headers, true) {
		return StatusCode::FORBIDDEN.into_response();
	}
	let Some(owner) = state.auth_token() else { return StatusCode::FORBIDDEN.into_response(); };
	if !handoff.redeem(&request.code, Instant::now()) {
		return StatusCode::FORBIDDEN.into_response();
	}
	secret_response(json!({"token": owner.encode()}))
}

pub(crate) fn router(state: &Arc<ServerState>, host: String) -> Router<Arc<ServerState>> {
	let handoff = Arc::new(Handoff {
		origin: format!("http://{}", host), host, grant: Mutex::new(None),
	});
	authed_router(state, Router::new().route("/api/desktop/handoff/new", post(issue)))
		.route("/api/desktop/handoff/redeem", post(redeem))
		.layer(DefaultBodyLimit::max(256))
		.layer(Extension(handoff))
}

#[cfg(test)]
mod tests {
	use super::*;
	use axum::body::{Body, to_bytes};
	use axum::http::Request;
	use tokio_util::sync::CancellationToken;
	use tower::ServiceExt;

	fn handoff() -> Handoff {
		Handoff { origin: "http://127.0.0.1:3000".into(), host: "127.0.0.1:3000".into(), grant: Mutex::new(None) }
	}

	#[test]
	fn codes_expire_replace_and_cannot_be_replayed() {
		let state = handoff();
		let old = state.issue();
		let new = state.issue();
		assert!(!state.redeem(&old, Instant::now()));
		assert!(!state.redeem("malformed", Instant::now()));
		assert!(state.redeem(&new, Instant::now()));
		assert!(!state.redeem(&new, Instant::now()));
		let expired = state.issue();
		assert!(!state.redeem(&expired, Instant::now() + LIFETIME));
	}

	#[tokio::test]
	async fn desktop_mode_refuses_remote_or_unauthenticated_binding() {
		for (host, authenticated) in [("0.0.0.0", true), ("127.0.0.1", false)] {
			let config = crate::Config { host: host.parse().unwrap(), port: 0, ..Default::default() };
			let state = Arc::new(ServerState::builder().auth_token(authenticated.then(|| AuthToken::new([8; 32])))
				.build(CancellationToken::new()));
			let result = crate::RestServer::start_desktop(&config, state, CancellationToken::new()).await;
			assert!(matches!(result, Err(error) if error.to_string().contains("authenticated loopback")));
		}
	}

	#[test]
	fn concurrent_redemption_only_succeeds_once() {
		let state = Arc::new(handoff());
		let code = state.issue();
		let threads: Vec<_> = (0..8).map(|_| {
			let state = state.clone();
			let code = code.clone();
			std::thread::spawn(move || state.redeem(&code, Instant::now()) as usize)
		}).collect();
		assert_eq!(threads.into_iter().map(|thread| thread.join().unwrap()).sum::<usize>(), 1);
	}

	#[tokio::test]
	async fn routes_require_owner_to_issue_and_exact_browser_origin_to_redeem() {
		let owner = AuthToken::new([7; 32]);
		let state = Arc::new(ServerState::builder().auth_token(owner.clone()).build(CancellationToken::new()));
		let app = router(&state, "127.0.0.1:3000".into()).with_state(state);
		let request = || Request::builder().method("POST").uri("/api/desktop/handoff/new").header("host", "127.0.0.1:3000");
		assert_eq!(app.clone().oneshot(request().body(Body::empty()).unwrap()).await.unwrap().status(), StatusCode::UNAUTHORIZED);
		let response = app.clone().oneshot(request().header("authorization", format!("Bearer {}", owner.encode()))
			.body(Body::empty()).unwrap()).await.unwrap();
		assert_eq!(response.status(), StatusCode::OK);
		assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
		let result: serde_json::Value = serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap()).unwrap();
		let code = result["code"].as_str().unwrap();
		for (host, origin) in [("127.0.0.1:3000", "null"), ("evil.example", "http://127.0.0.1:3000"),
			("127.0.0.1:3000", "https://evil.example")] {
			let response = app.clone().oneshot(Request::builder().method("POST").uri("/api/desktop/handoff/redeem")
				.header("host", host).header("origin", origin).header("content-type", "application/json")
				.body(Body::from(json!({"code": code}).to_string())).unwrap()).await.unwrap();
			assert_eq!(response.status(), StatusCode::FORBIDDEN);
		}
		for expected in [StatusCode::OK, StatusCode::FORBIDDEN] {
			let response = app.clone().oneshot(Request::builder().method("POST").uri("/api/desktop/handoff/redeem")
				.header("host", "127.0.0.1:3000").header("origin", "http://127.0.0.1:3000").header("content-type", "application/json")
				.body(Body::from(json!({"code": code}).to_string())).unwrap()).await.unwrap();
			assert_eq!(response.status(), expected);
			if expected == StatusCode::OK {
				assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
				let result: serde_json::Value = serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap()).unwrap();
				assert!(result["token"].as_str() == Some(owner.encode().as_str()));
			}
		}
	}
}
