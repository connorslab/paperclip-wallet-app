//! TLS-capable JSON-RPC transport with optional SOCKS5 routing.
//!
//! This implements the [`jsonrpc::Transport`] trait by routing connections
//! through a SOCKS5 proxy via ureq. This exists because the jsonrpc crate's
//! `proxy` feature flag changes `simple_http::fresh_socket` to **always** route
//! through a SOCKS5 proxy (defaulting to 127.0.0.1:9050), breaking all
//! non-proxied connections. By implementing the transport ourselves, we can
//! use proxy support only when explicitly configured.
//!
//! We use ureq rather than reqwest::blocking because ureq is a pure sync HTTP
//! client with no internal tokio runtime, which avoids panics when the
//! transport is used from within an async context (as bark does).

use std::fmt;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use ureq::{Agent, Proxy};

use crate::rpc::jsonrpc::{self, Request, Response};

/// A SOCKS5-proxied HTTP transport for JSON-RPC backed by ureq.
pub struct Socks5Transport {
	url: String,
	agent: Agent,
	basic_auth: Option<String>,
}

impl fmt::Debug for Socks5Transport {
	fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
		f.debug_struct("Socks5Transport")
			.field("url", &self.url)
			.field("has_auth", &self.basic_auth.is_some())
			.finish()
	}
}

impl Socks5Transport {
	/// Creates a new SOCKS5 transport.
	///
	/// * `url` — the target bitcoind RPC URL (e.g. `http://127.0.0.1:8332`)
	/// * `proxy_url` — an optional SOCKS5 proxy URL (e.g. `socks5h://127.0.0.1:9050`)
	/// * `auth` — optional (user, password) for HTTP Basic authentication
	pub fn new(
		url: &str,
		proxy_url: Option<&str>,
		auth: Option<(String, Option<String>)>,
	) -> Result<Self, Error> {
		let proxy = proxy_url.map(Proxy::new).transpose()
			.map_err(|e| Error::Proxy(e.to_string()))?;

		let agent = Agent::config_builder()
			.proxy(proxy)
			.max_redirects(0)
			.http_status_as_error(false)
			.timeout_global(Some(Duration::from_secs(60)))
			.build()
			.new_agent();

		let basic_auth = auth.map(|(user, pass)| {
			let credentials = format!("{}:{}", user, pass.unwrap_or_default());
			format!("Basic {}", BASE64.encode(&credentials))
		});

		Ok(Socks5Transport { url: url.to_owned(), agent, basic_auth })
	}

	fn request<R>(&self, req: impl serde::Serialize) -> Result<R, jsonrpc::Error>
	where
		R: for<'a> serde::de::Deserialize<'a>,
	{
		let body = serde_json::to_vec(&req)
			.map_err(|e| jsonrpc::Error::Transport(e.into()))?;

		let mut request = self.agent.post(&self.url)
			.header("Content-Type", "application/json");
		if let Some(ref auth) = self.basic_auth {
			request = request.header("Authorization", auth);
		}

		let resp = request
			.send(&body[..])
			.map_err(|e| jsonrpc::Error::Transport(e.into()))?;

		let status = resp.status().as_u16();
		if !(200..300).contains(&status) && status != 500 {
			return Err(jsonrpc::Error::Transport(
				Box::new(Error::Http(status)),
			));
		}

		let resp_body = resp.into_body().read_to_string()
			.map_err(|e| jsonrpc::Error::Transport(e.into()))?;

		serde_json::from_str(&resp_body)
			.map_err(|e| jsonrpc::Error::Transport(e.into()))
	}
}

impl jsonrpc::client::Transport for Socks5Transport {
	fn send_request(&self, req: Request) -> Result<Response, jsonrpc::Error> {
		self.request(req)
	}

	fn send_batch(&self, reqs: &[Request]) -> Result<Vec<Response>, jsonrpc::Error> {
		self.request(reqs)
	}

	fn fmt_target(&self, f: &mut fmt::Formatter) -> fmt::Result {
		write!(f, "{} (TLS-capable RPC transport)", self.url)
	}
}

#[derive(Debug)]
pub enum Error {
	Proxy(String),
	Http(u16),
}

impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
		match self {
			Error::Proxy(e) => write!(f, "invalid proxy URL: {}", e),
			Error::Http(code) => write!(f, "HTTP error {}", code),
		}
	}
}

impl std::error::Error for Error {}

#[cfg(test)]
mod tests {
	use super::*;
	use std::io::{Read, Write};
	use std::net::TcpListener;

	#[test]
	fn rpc_https_starts_with_tls_not_plaintext_credentials() {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let address = listener.local_addr().unwrap();
		let server = std::thread::spawn(move || {
			let (mut socket, _) = listener.accept().unwrap();
			socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
			let mut header = [0; 3];
			socket.read_exact(&mut header).unwrap();
			assert_eq!(header[0], 0x16); // TLS handshake record.
			assert_eq!(header[1], 0x03);
		});
		let transport = Socks5Transport::new(&format!("https://{address}"), None,
			Some(("wallet".into(), Some("secret".into())))).unwrap();
		assert!(transport.request::<serde_json::Value>(serde_json::json!({"method": "getblockcount"})).is_err());
		server.join().unwrap();
	}

	#[test]
	fn rpc_transport_rejects_redirects() {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let address = listener.local_addr().unwrap();
		let server = std::thread::spawn(move || {
			let (mut socket, _) = listener.accept().unwrap();
			socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
			let mut buffer = [0; 4096];
			let _ = socket.read(&mut buffer).unwrap();
			socket.write_all(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
		});
		let transport = Socks5Transport::new(&format!("http://{address}"), None, None).unwrap();
		let error = transport.request::<serde_json::Value>(serde_json::json!({})).unwrap_err();
		assert!(error.to_string().contains("302"));
		server.join().unwrap();
	}
}
