//! Stop incomplete uploads on shutdown without canceling dispatched operations.
use std::io;

use axum::{body::Body, extract::{Request, State}, middleware::Next, response::Response};
use futures::{stream, StreamExt};
use tokio_util::sync::CancellationToken;

pub(crate) async fn interrupt_on_shutdown(
	State(shutdown): State<CancellationToken>, request: Request, next: Next,
) -> Response {
	let request = request.map(|body| {
		Body::from_stream(stream::unfold((body.into_data_stream(), shutdown, false),
			|(mut body, shutdown, failed)| async move {
				if failed { return None; }
				let item = tokio::select! {
					biased;
					_ = shutdown.cancelled() => {
						// Never turn interruption into EOF: a valid JSON prefix of
						// an unfinished HTTP body must not reach the handler.
						return Some((Err(io::Error::new(io::ErrorKind::Interrupted, "Server is shutting down")), (body, shutdown, true)));
					},
					item = body.next() => item?,
				};
				Some((item.map_err(io::Error::other), (body, shutdown, false)))
			}))
	});
	// Only body reads observe cancellation. An operation that has consumed its
	// request keeps running under the server's existing graceful shutdown.
	next.run(request).await
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
	use std::time::Duration;
	use axum::{Json, Router, body::Bytes, extract::DefaultBodyLimit, http::{Request as HttpRequest, StatusCode}, routing::post};
	use serde_json::Value;
	use tokio::sync::Notify;
	use tower::ServiceExt;

	#[tokio::test]
	async fn incomplete_valid_json_is_rejected_on_shutdown_before_handler() {
		let shutdown = CancellationToken::new();
		let calls = Arc::new(AtomicUsize::new(0)); let called = calls.clone();
		let router = Router::new().route("/", post(move |Json(_): Json<Value>| async move {
			called.fetch_add(1, Ordering::SeqCst);
			StatusCode::OK
		})).layer(axum::middleware::from_fn_with_state(shutdown.clone(), interrupt_on_shutdown));
		let reading = Arc::new(Notify::new()); let notify = reading.clone();
		let body = stream::once(async { Ok::<_, io::Error>(Bytes::from_static(b"{}")) })
			.chain(stream::once(async move { notify.notify_one(); std::future::pending::<Result<Bytes, io::Error>>().await }));
		let request = HttpRequest::post("/").header("content-type", "application/json")
			.header("content-length", "100").body(Body::from_stream(body)).unwrap();
		let pending = tokio::spawn(router.oneshot(request));
		tokio::time::timeout(Duration::from_secs(2), reading.notified()).await.unwrap();
		assert_eq!(calls.load(Ordering::SeqCst), 0);
		shutdown.cancel();
		let response = tokio::time::timeout(Duration::from_secs(2), pending).await.unwrap().unwrap().unwrap();
		assert_eq!(response.status(), StatusCode::BAD_REQUEST);
		assert_eq!(calls.load(Ordering::SeqCst), 0);
	}

	#[tokio::test]
	async fn shutdown_does_not_cancel_a_handler_that_already_consumed_its_body() {
		let shutdown = CancellationToken::new();
		let entered = Arc::new(Notify::new()); let started = entered.clone();
		let finish = Arc::new(Notify::new()); let release = finish.clone();
		let router = Router::new().route("/", post(move |Json(value): Json<Value>| async move {
			started.notify_one(); release.notified().await; Json(value)
		})).layer(axum::middleware::from_fn_with_state(shutdown.clone(), interrupt_on_shutdown));
		let request = HttpRequest::post("/").header("content-type", "application/json").body(Body::from("{}")).unwrap();
		let pending = tokio::spawn(router.oneshot(request));
		tokio::time::timeout(Duration::from_secs(2), entered.notified()).await.unwrap();
		shutdown.cancel();
		tokio::task::yield_now().await;
		assert!(!pending.is_finished());
		finish.notify_one();
		let response = tokio::time::timeout(Duration::from_secs(2), pending).await.unwrap().unwrap().unwrap();
		assert_eq!(response.status(), StatusCode::OK);
	}

	#[tokio::test]
	async fn existing_request_size_limits_still_apply() {
		let router = Router::new().route("/", post(|Json(_): Json<Value>| async { StatusCode::OK }))
			.layer(DefaultBodyLimit::max(8))
			.layer(axum::middleware::from_fn_with_state(CancellationToken::new(), interrupt_on_shutdown));
		let request = HttpRequest::post("/").header("content-type", "application/json")
			.body(Body::from(r#"{"value":"too long"}"#)).unwrap();
		assert_eq!(router.oneshot(request).await.unwrap().status(), StatusCode::PAYLOAD_TOO_LARGE);
	}
}
