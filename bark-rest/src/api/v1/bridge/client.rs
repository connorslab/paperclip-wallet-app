//! One fixed HTTPS origin. Never forward wallet/node credentials or redirects.
use std::time::Duration;

use anyhow::{Context, ensure};
use reqwest::{Client, Response};
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::protocol::{Availability, Challenge, Direction, Invoice, Quote, SwapStatus};

pub(super) struct Bridge { client: Client }
impl Bridge {
	pub fn new() -> anyhow::Result<Self> {
		Ok(Self { client: Client::builder().https_only(true).redirect(reqwest::redirect::Policy::none()).retry(reqwest::retry::never())
			.no_proxy().connect_timeout(Duration::from_secs(8)).timeout(Duration::from_secs(35)).build()? })
	}
	async fn request<T: DeserializeOwned>(&self, path: &str, body: Option<Value>, timeout: u64) -> anyhow::Result<T> {
		let url = format!("https://lightning.paperclip-xbt.xyz/bridge/api/{path}");
		let request = if let Some(body) = body { self.client.post(url).json(&body) } else { self.client.get(url) };
		let response = request.timeout(Duration::from_secs(timeout)).send().await
			.map_err(|_| anyhow::anyhow!("Could not securely reach the bridge. Check again shortly"))?;
		decode(response).await
	}
	pub async fn reusable_info(&self) -> anyhow::Result<Value> {
		let result: Value = self.request("reusable/info",None,8).await?;
		ensure!(result["available"].is_boolean(), "Invalid bridge availability"); Ok(json!({"available":result["available"]}))
	}
	pub async fn reusable(&self, action: &str, body: Value) -> anyhow::Result<super::reusable::Binding> {
		ensure!(["register","lookup","revoke"].contains(&action), "Invalid offer operation");
		self.request(&format!("reusable/{action}"),Some(body),35).await
	}

	pub async fn availability(&self, direction: Direction) -> anyhow::Result<Availability> {
		let result: Availability = self.request(&format!("info?direction={}",direction.text()),None,8).await?;
		result.validate()?; Ok(result)
	}
	pub async fn quote(&self, target: &Invoice, direction: Direction) -> anyhow::Result<Quote> {
		let challenge: Challenge = self.request("pow",None,8).await?;
		let nonce = challenge.solve(&target.hash).await?;
		self.request("quote",Some(json!({"invoice":target.text,"direction":direction,"pow":{"challenge":challenge.challenge,"nonce":nonce}})),35).await
	}
	pub async fn status(&self, quote: &Quote) -> anyhow::Result<SwapStatus> {
		// Only quotes validated on creation and loading reach this method.
		self.request(&format!("swap/{}?t={}",quote.hash,quote.token),None,8).await
	}
}
async fn decode<T: DeserializeOwned>(mut response: Response) -> anyhow::Result<T> {
	ensure!(response.status() == reqwest::StatusCode::OK, "Bridge unavailable. Check again shortly");
	ensure!(response.content_length().is_none_or(|len| len <= 65536), "Invalid bridge response");
	let mut bytes = Vec::new();
	while let Some(chunk) = response.chunk().await.map_err(|_| anyhow::anyhow!("Bridge response interrupted"))? {
		ensure!(bytes.len() + chunk.len() <= 65536, "Invalid bridge response"); bytes.extend_from_slice(&chunk);
	}
	// Decode errors can contain remote values; return a fixed, private error.
	serde_json::from_slice(&bytes).ok().context("Bridge response is unavailable or invalid")
}

#[cfg(test)]
mod tests {
	use super::*;
	fn response(status: u16, body: impl Into<Vec<u8>>) -> Response {
		axum::http::Response::builder().status(status).body(body.into()).unwrap().into()
	}
	#[tokio::test]
	async fn response_is_bounded_and_never_exposes_remote_error_contents() {
		let result = decode::<Availability>(response(200,br#"{"open":true,"min_sat":1,"max_sat":100}"#)).await.unwrap();
		assert!(result.open);
		assert!(decode::<Availability>(response(302,b"redirect")).await.is_err());
		assert!(decode::<Availability>(response(200,vec![b' ';65537])).await.is_err());
		let error = decode::<Availability>(response(200,br#"{"open":"SENSITIVE_REMOTE_VALUE"}"#)).await.err().unwrap().to_string();
		assert!(!error.contains("SENSITIVE_REMOTE_VALUE"));
		assert!(decode::<Availability>(response(500,b"SENSITIVE_REMOTE_VALUE")).await.is_err());
	}
}
