//! Fixed REST methods only. No redirects, ambient proxies, or mutation retries.
use std::{sync::Arc, time::Duration};

use anyhow::{Context, ensure};
use bitcoin::hashes::{Hash, sha256};
use reqwest::{Client, Url};
use rustls::{DigitallySignedStruct, SignatureScheme, client::danger::{ServerCertVerifier, ServerCertVerified, HandshakeSignatureValid}, pki_types::{CertificateDer, ServerName, UnixTime}};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(super) enum Implementation { Cln, Lnd }

// Never derive Debug: this includes the node's spending credential.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Connection {
	pub implementation: Implementation,
	pub endpoint: String,
	pub credential: String,
	#[serde(default)] pub certificate_sha256: String,
	#[serde(default)] pub use_tor: bool,
	#[serde(default)] pub receive_only: bool,
	#[serde(default)] pub node_id: String,
}

pub(super) fn endpoint(text: &str, tor: bool) -> anyhow::Result<Url> {
	ensure!(text.len() <= 2048, "Node address is too long");
	let url: Url = text.parse().context("Enter the node’s REST address")?;
	let host = url.host_str().context("Enter the node’s REST host")?;
	let onion = host.ends_with(".onion");
	ensure!(url.username().is_empty() && url.password().is_none() && url.query().is_none() && url.fragment().is_none(), "Use a REST address without credentials, query, or fragment");
	ensure!(url.path() == "/" || url.path().is_empty(), "Use the REST root address, without an API path");
	ensure!(url.scheme() == "https" || (url.scheme() == "http" && onion && tor), "Use HTTPS, or an onion address through Tor");
	ensure!(!onion || tor, "Enable Tor for an onion address");
	if onion {
		let name = host.strip_suffix(".onion").unwrap();
		ensure!(name.len() == 56 && name.bytes().all(|b| b.is_ascii_lowercase() || (b'2'..=b'7').contains(&b)), "Enter a v3 onion address");
	}
	Ok(url)
}

fn pins(text: &str) -> anyhow::Result<Vec<sha256::Hash>> {
	if text.is_empty() { return Ok(Vec::new()); }
	let values = text.split(',').map(|s| s.trim().parse::<sha256::Hash>()).collect::<Result<Vec<_>, _>>()
		.context("Use SHA256 certificate fingerprints: 64 hexadecimal characters, separated by commas")?;
	ensure!(values.len() <= 4, "Use up to four certificate fingerprints");
	Ok(values)
}

#[derive(Debug)]
struct PinnedCertificate { pins: Vec<sha256::Hash>, algorithms: rustls::crypto::WebPkiSupportedAlgorithms }
impl ServerCertVerifier for PinnedCertificate {
	fn verify_server_cert(&self, leaf: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: &ServerName<'_>, _: &[u8], _: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
		// Exact user-verified DER leaf pins are the trust anchor for self-signed
		// nodes. TLS handshake signatures still prove possession of that key.
		if self.pins.contains(&sha256::Hash::hash(leaf.as_ref())) { Ok(ServerCertVerified::assertion()) }
		else { Err(rustls::Error::InvalidCertificate(rustls::CertificateError::ApplicationVerificationFailure)) }
	}
	fn verify_tls12_signature(&self, message: &[u8], cert: &CertificateDer<'_>, signature: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
		rustls::crypto::verify_tls12_signature(message, cert, signature, &self.algorithms)
	}
	fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, signature: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
		rustls::crypto::verify_tls13_signature(message, cert, signature, &self.algorithms)
	}
	fn supported_verify_schemes(&self) -> Vec<SignatureScheme> { self.algorithms.supported_schemes() }
}

pub(super) struct Node { pub connection: Connection, client: Client, base: Url }
impl Node {
	pub fn new(connection: Connection, proxy: Option<&str>) -> anyhow::Result<Self> {
		let base = endpoint(&connection.endpoint, connection.use_tor)?;
		let credential = &connection.credential;
		ensure!(!credential.is_empty() && credential.len() < 16384, "Enter the node’s access credential");
		ensure!(match connection.implementation {
			Implementation::Cln => credential.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_=".contains(&b)),
			Implementation::Lnd => credential.len() % 2 == 0 && credential.bytes().all(|b| b.is_ascii_hexdigit()),
		}, "Invalid rune or hexadecimal macaroon");
		let mut builder = Client::builder().no_proxy().redirect(reqwest::redirect::Policy::none())
			.retry(reqwest::retry::never()).timeout(Duration::from_secs(75)).connect_timeout(Duration::from_secs(30));
		if connection.use_tor {
			let proxy: Url = proxy.context("Tor is not configured on this wallet server")?.parse().context("Invalid server Tor proxy")?;
			ensure!(proxy.scheme() == "socks5h" && proxy.host_str().is_some() && proxy.port().is_some()
				&& proxy.username().is_empty() && proxy.password().is_none() && proxy.query().is_none()
				&& proxy.fragment().is_none() && proxy.path().is_empty(), "Configure a socks5h://host:port Tor proxy on the server");
			builder = builder.proxy(reqwest::Proxy::all(proxy).context("Invalid server Tor proxy")?);
		}
		let pins = pins(&connection.certificate_sha256)?;
		if !pins.is_empty() {
			ensure!(base.scheme() == "https", "Certificate fingerprints require HTTPS");
			let provider = Arc::new(rustls::crypto::ring::default_provider());
			let verifier = PinnedCertificate { pins, algorithms: provider.signature_verification_algorithms };
			let tls = rustls::ClientConfig::builder_with_provider(provider).with_safe_default_protocol_versions()?
				.dangerous().with_custom_certificate_verifier(Arc::new(verifier)).with_no_client_auth();
			builder = builder.use_preconfigured_tls(tls);
		}
		Ok(Self { connection, base, client: builder.build().context("Could not initialize node transport")? })
	}
	pub fn cln(&self) -> bool { self.connection.implementation == Implementation::Cln }
	pub async fn request(&self, path: &str, body: Option<Value>, stream: bool) -> anyhow::Result<Value> {
		// Path is constructed only by this module's typed operations, never a
		// browser-supplied URL. reqwest must not expose credentials in errors.
		let url = self.base.join(path).context("Invalid node REST method")?;
		let mut request = if body.is_some() { self.client.post(url) } else { self.client.get(url) };
		request = request.header(if self.cln() { "Rune" } else { "Grpc-Metadata-macaroon" }, &self.connection.credential);
		if let Some(body) = body { request = request.json(&body); }
		let mut response = request.send().await.map_err(|e| anyhow::anyhow!(if e.is_timeout() {
			"Node request timed out. Check payment status before sending again."
		} else { "Could not reach the node securely. Check its address, Tor route, and certificate fingerprints." }))?;
		let status = response.status().as_u16();
		ensure!(!(300..400).contains(&status), "The node redirected the request; use its direct REST address");
		match status {
			401 => bail!("The node rejected this access credential"),
			403 => bail!("This credential does not permit the operation. Check its node permissions"),
			404 | 501 if path.starts_with("v2/offers") => bail!("This LND node does not expose XBT BOLT12 offersrpc. Check its version and configuration"),
			_ => {},
		}
		ensure!((200..300).contains(&status), "Node REST request failed (HTTP {status}). Check payment status before retrying");
		let maximum = if stream { 256 * 1024 } else { 8 * 1024 * 1024 };
		let mut bytes = Vec::new();
		while let Some(chunk) = response.chunk().await.map_err(|_| anyhow::anyhow!("Node response interrupted. Check payment status before retrying"))? {
			// Consume only the first JSON line; dropping a stream is not a payment cancellation.
			for byte in chunk {
				if stream && byte == b'\n' && !bytes.is_empty() { return decode(&bytes, true); }
				ensure!(bytes.len() < maximum, "Node response exceeded the size limit");
				if !bytes.is_empty() || byte != b'\n' { bytes.push(byte); }
			}
		}
		decode(&bytes, stream)
	}
	pub async fn info(&self) -> anyhow::Result<Value> {
		self.request("v1/getinfo", self.cln().then(|| json!({})), false).await
	}
}
fn decode(bytes: &[u8], stream: bool) -> anyhow::Result<Value> {
	let value: Value = serde_json::from_slice(bytes).map_err(|_| anyhow::anyhow!("Invalid JSON response from the node"))?;
	ensure!(value.is_object(), "Invalid node response");
	if stream {
		ensure!(value.get("error").is_none(), "The node could not report a final payment result. Check payment status");
		ensure!(value["result"].is_object(), "Invalid node payment stream");
		Ok(value["result"].clone())
	} else { Ok(value) }
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn endpoint_and_credential_boundaries() {
		for bad in ["http://start.local", "https://user:secret@host", "https://host/v1", "https://host?token=x", "https://host/#x", "https://abc.onion"] {
			assert!(endpoint(bad, false).is_err());
		}
		assert!(endpoint("https://start.local:8180", false).is_ok());
		assert!(endpoint(&format!("http://{}.onion", "a".repeat(56)), true).is_ok());
		assert!(pins(" ").is_err()); assert!(pins(&"01".repeat(32)).is_ok());
	}
	#[test]
	fn pin_requires_exact_leaf() {
		let leaf = CertificateDer::from(vec![1,2,3]);
		let verifier = PinnedCertificate { pins: vec![sha256::Hash::hash(leaf.as_ref())], algorithms: rustls::crypto::ring::default_provider().signature_verification_algorithms };
		let name = ServerName::try_from("node.local").unwrap();
		assert!(verifier.verify_server_cert(&leaf, &[], &name, &[], UnixTime::since_unix_epoch(Duration::ZERO)).is_ok());
		assert!(verifier.verify_server_cert(&CertificateDer::from(vec![1,2,4]), &[], &name, &[], UnixTime::since_unix_epoch(Duration::ZERO)).is_err());
		assert!(!verifier.supported_verify_schemes().is_empty());
	}
	#[test]
	fn stream_errors_never_become_success() {
		assert!(decode(br#"{"error":{"code":5,"message":"secret"}}"#, true).is_err());
		assert!(decode(br#"{"status":"SUCCEEDED"}"#, true).is_err());
		assert_eq!(decode(br#"{"result":{"status":"IN_FLIGHT"}}"#, true).unwrap()["status"], "IN_FLIGHT");
	}
}
