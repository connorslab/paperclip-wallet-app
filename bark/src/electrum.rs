//! XBT Electrum transport. All blocking socket work runs outside the async executor.
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, ensure};
use bdk_electrum::electrum_client::Param;
use std::collections::{HashMap, HashSet};
use bdk_electrum::{BdkElectrumClient, electrum_client::{ElectrumApi, raw_client::RawClient}};
use bitcoin::{Network, OutPoint, Transaction, Txid, hashes::{Hash, sha256}};
use bitcoin_ext::{BlockRef, TxStatus};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};

pub trait Transport: Read + Write + Send {}
impl<T: Read + Write + Send> Transport for T {}
pub type Client = BdkElectrumClient<RawClient<Box<dyn Transport>>>;

#[derive(Clone)]
pub struct Electrum(pub Arc<Client>);

#[derive(Debug)]
struct CertificatePin(String);
impl ServerCertVerifier for CertificatePin {
	fn verify_server_cert(&self, cert: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: &ServerName<'_>, _: &[u8], _: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
		if sha256::Hash::hash(cert.as_ref()).to_string() != self.0 {
			return Err(rustls::Error::General("Electrum certificate pin mismatch".into()));
		}
		Ok(ServerCertVerified::assertion())
	}
	fn verify_tls12_signature(&self, message: &[u8], cert: &CertificateDer<'_>, signature: &rustls::DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
		rustls::crypto::verify_tls12_signature(message, cert, signature, &rustls::crypto::ring::default_provider().signature_verification_algorithms)
	}
	fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, signature: &rustls::DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
		rustls::crypto::verify_tls13_signature(message, cert, signature, &rustls::crypto::ring::default_provider().signature_verification_algorithms)
	}
	fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
		rustls::crypto::ring::default_provider().signature_verification_algorithms.supported_schemes()
	}
}

impl Electrum {
	pub async fn connect(url: String, proxy: Option<String>, pin: Option<String>, network: Network) -> anyhow::Result<Self> {
		tokio::task::spawn_blocking(move || {
			let endpoint: url::Url = url.parse()?;
			let host = endpoint.host_str().context("Electrum host required")?;
			let port = endpoint.port().context("Electrum port required")?;
			ensure!(["ssl", "tcp"].contains(&endpoint.scheme()) && endpoint.username().is_empty() && endpoint.password().is_none(), "invalid Electrum endpoint");
			ensure!(!host.ends_with(".onion") || proxy.is_some(), "onion endpoint requires Tor");
			let timeout = Duration::from_secs(20);
			let stream = if let Some(proxy) = proxy {
				let proxy: url::Url = proxy.parse()?;
				ensure!(proxy.scheme() == "socks5h", "Tor requires proxy DNS");
				let proxy_host = proxy.host_str().context("proxy host required")?;
				let proxy_port = proxy.port().context("proxy port required")?;
				// The target hostname is passed to SOCKS. It is never resolved locally.
				bdk_electrum::electrum_client::socks::Socks5Stream::connect(
					(proxy_host, proxy_port), (host, port), Some(timeout))?.into_inner()
			} else {
				let addresses = (host, port).to_socket_addrs()?;
				let mut connected = None;
				for address in addresses {
					if let Ok(stream) = TcpStream::connect_timeout(&address, timeout) { connected = Some(stream); break; }
				}
				connected.context("could not connect to Electrum")?
			};
			stream.set_read_timeout(Some(timeout))?;
			stream.set_write_timeout(Some(timeout))?;
			let transport: Box<dyn Transport> = if endpoint.scheme() == "ssl" {
				let builder = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
					.with_safe_default_protocol_versions()?;
				let config = if let Some(pin) = pin.filter(|p| !p.is_empty()) {
					ensure!(pin.len() == 64 && pin.bytes().all(|c| c.is_ascii_hexdigit()), "invalid certificate SHA256");
					builder.dangerous().with_custom_certificate_verifier(Arc::new(CertificatePin(pin.to_lowercase()))).with_no_client_auth()
				} else {
					let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
					builder.with_root_certificates(roots).with_no_client_auth()
				};
				let connection = rustls::ClientConnection::new(Arc::new(config), ServerName::try_from(host.to_owned())?)?;
				Box::new(rustls::StreamOwned::new(connection, stream))
			} else { Box::new(stream) };
			let raw = RawClient::from(transport);
			raw.raw_call("server.version", [bdk_electrum::electrum_client::Param::String("paperclip-ios".into()), bdk_electrum::electrum_client::Param::Array(vec![Param::String("1.4".into()), Param::String("1.6".into())])])?;
			ensure!(raw.block_header(0)?.block_hash() == bitcoin::constants::genesis_block(network).block_hash(), "Electrum network mismatch");
			let tip = raw.block_headers_subscribe_raw()?;
			ensure!(tip.header.len() == 164, "Electrum must serve activated BLAKE2b XBT headers");
			Ok(Self(Arc::new(BdkElectrumClient::new(raw))))
		}).await?
	}
	pub async fn run<T: Send + 'static>(&self, call: impl FnOnce(&Client) -> anyhow::Result<T> + Send + 'static) -> anyhow::Result<T> {
		let client = self.0.clone();
		tokio::task::spawn_blocking(move || call(&client)).await?
	}
	/// Public Electrum metadata only; never calls daemon.passthrough.
	pub async fn ark_capabilities(&self) -> anyhow::Result<serde_json::Value> {
		self.run(|c| {
			let features = c.inner.raw_call("server.features", Vec::<Param>::new())?;
			let policy = c.inner.raw_call("mempool.get_info", Vec::<Param>::new())?;
			Ok(serde_json::json!({"features": features, "policy": policy}))
		}).await
	}

	pub async fn require_funded_policy(&self) -> anyhow::Result<()> {
		let data = self.ark_capabilities().await?;
		validate_ark_capabilities(&data)
	}

	pub async fn broadcast_package(&self, txs: Vec<Transaction>) -> anyhow::Result<serde_json::Value> {
		ensure!(!txs.is_empty() && txs.len() <= 25, "invalid package size");
		self.run(move |c| {
			let raw = txs.iter().map(|tx| Param::String(bitcoin::consensus::encode::serialize_hex(tx))).collect();
			Ok(c.inner.raw_call("blockchain.transaction.broadcast_package", [Param::Array(raw), Param::Bool(false)])?)
		}).await
	}

	/// Reconstruct fees from hash-checked transactions rather than trusting server totals.
	pub async fn mempool_ancestor_info(&self, txid: Txid) -> anyhow::Result<crate::chain::MempoolAncestorInfo> {
		ensure!(matches!(self.status(txid).await?, TxStatus::Mempool), "transaction is not in the mempool");
		let mut result = crate::chain::MempoolAncestorInfo::new(txid);
		let mut pending = vec![txid];
		let mut seen = HashSet::new();
		let mut transactions: HashMap<Txid, Transaction> = HashMap::new();
		while let Some(id) = pending.pop() {
			if !seen.insert(id) { continue; }
			ensure!(seen.len() <= 100, "mempool ancestry exceeds mobile limit");
			if !matches!(self.status(id).await?, TxStatus::Mempool) { continue; }
			let tx = match transactions.get(&id) { Some(tx) => tx.clone(), None => self.transaction(id).await? };
			let mut inputs = bitcoin::Amount::ZERO;
			for input in &tx.input {
				let prev = input.previous_output;
				if !transactions.contains_key(&prev.txid) {
					ensure!(transactions.len() < 1000, "ancestry input limit exceeded");
					transactions.insert(prev.txid, self.transaction(prev.txid).await?);
				}
				let parent: &Transaction = &transactions[&prev.txid];
				inputs = inputs.checked_add(parent.output.get(prev.vout as usize).context("invalid ancestor outpoint")?.value).context("input overflow")?;
				pending.push(prev.txid);
			}
			let outputs = tx.output.iter().try_fold(bitcoin::Amount::ZERO, |sum, out| sum.checked_add(out.value)).context("output overflow")?;
			let fee = inputs.checked_sub(outputs).context("negative ancestor fee")?;
			result.total_fee = result.total_fee.checked_add(fee).context("fee overflow")?;
			result.total_weight += tx.weight();
		}
		Ok(result)
	}

	pub async fn block_ref(&self, height: u32) -> anyhow::Result<BlockRef> {
		self.run(move |c| Ok(BlockRef { height: height.into(), hash: c.inner.block_header(height as usize)?.block_hash() })).await
	}
	pub async fn tip(&self) -> anyhow::Result<u32> {
		self.run(|c| Ok(u32::try_from(c.inner.block_headers_subscribe_raw()?.height)?)).await
	}
	pub async fn transaction(&self, txid: Txid) -> anyhow::Result<Transaction> {
		self.run(move |c| {
			let tx = c.inner.transaction_get(&txid)?;
			ensure!(tx.compute_txid() == txid, "Electrum transaction hash mismatch");
			Ok(tx)
		}).await
	}
	pub async fn status(&self, txid: Txid) -> anyhow::Result<TxStatus> {
		self.run(move |c| {
			if let Ok(height) = c.inner.raw_call("blockchain.transaction.get_height", [Param::String(txid.to_string())]) {
				if height.is_null() { return Ok(TxStatus::NotFound); }
			}
			let tx = c.inner.transaction_get(&txid)?;
			ensure!(tx.compute_txid() == txid, "Electrum transaction hash mismatch");
			for output in &tx.output {
				if let Some(entry) = c.inner.script_get_history(&output.script_pubkey)?.iter().find(|e| e.tx_hash == txid) {
					return if entry.height > 0 {
						let header = c.inner.block_header(entry.height as usize)?;
						let proof = c.inner.transaction_get_merkle(&txid, entry.height as usize)?;
						let mut root = txid.to_byte_array();
						let mut position = proof.pos;
						for sibling in proof.merkle {
							let pair = if position & 1 == 0 { [root, sibling] } else { [sibling, root] };
							root = bitcoin::hashes::sha256d::Hash::hash(&pair.concat()).to_byte_array();
							position >>= 1;
						}
						ensure!(position == 0 && root == header.merkle_root.to_byte_array(), "invalid Electrum inclusion proof");
						Ok(TxStatus::Confirmed(BlockRef { height: (entry.height as u32).into(), hash: header.block_hash() }))
					} else { Ok(TxStatus::Mempool) };
				}
			}
			Ok(TxStatus::NotFound)
		}).await
	}
	pub async fn spending(&self, outpoint: OutPoint) -> anyhow::Result<Option<(Txid, TxStatus)>> {
		let original = self.transaction(outpoint.txid).await?;
		let script = original.output.get(outpoint.vout as usize).context("invalid outpoint")?.script_pubkey.clone();
		let history = self.run(move |c| Ok(c.inner.script_get_history(&script)?)).await?;
		for entry in history {
			let tx = self.transaction(entry.tx_hash).await?;
			if tx.input.iter().any(|i| i.previous_output == outpoint) {
				return Ok(Some((entry.tx_hash, self.status(entry.tx_hash).await?)));
			}
		}
		Ok(None)
	}
}

/// Admission is fail-closed if any required policy or package capability is absent.
pub fn validate_ark_capabilities(data: &serde_json::Value) -> anyhow::Result<()> {
	ensure!(data["features"]["broadcast_package"].as_bool() == Some(true), "Electrum server must advertise package relay for funded Ark");
	for (field, ceiling) in [("minrelaytxfee", 0.00001000), ("mempoolminfee", 0.00001000), ("dustrelayfee", 0.00003000)] {
		let value = data["policy"][field].as_f64().with_context(|| format!("Electrum mempool.get_info must expose {field} for funded Ark"))?;
		ensure!(value.is_finite() && value >= 0.0 && value <= ceiling, "Electrum {field} exceeds the funded profile");
	}
	Ok(())
}
