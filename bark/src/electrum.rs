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
pub struct Electrum(Arc<std::sync::Mutex<Connection>>);

struct Connection {
	client: Option<Client>,
	url: String,
	proxy: Option<String>,
	pin: Option<String>,
	network: Network,
}

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
			let client = Self::connect_blocking(url.clone(), proxy.clone(), pin.clone(), network)?;
			Ok(Self(Arc::new(std::sync::Mutex::new(Connection {
				client: Some(client), url, proxy, pin, network,
			}))))
		}).await?
	}

	fn connect_blocking(url: String, proxy: Option<String>, pin: Option<String>, network: Network) -> anyhow::Result<Client> {
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
		Ok(BdkElectrumClient::new(raw))
	}
	pub async fn run<T: Send + 'static>(&self, call: impl FnOnce(&Client) -> anyhow::Result<T> + Send + 'static) -> anyhow::Result<T> {
		let connection = self.0.clone();
		tokio::task::spawn_blocking(move || {
			let mut connection = connection.lock().map_err(|_| anyhow::anyhow!("Electrum connection lock poisoned"))?;
			// Probe before invoking an operation: reconnecting must never replay a
			// transaction broadcast whose response may have been lost.
			if connection.client.as_ref().is_some_and(|client| client.inner.ping().is_err()) {
				connection.client = None;
			}
			if connection.client.is_none() {
				connection.client = Some(Self::connect_blocking(connection.url.clone(),
					connection.proxy.clone(), connection.pin.clone(), connection.network)
					.context("reconnecting to Electrum")?);
			}
			let result = call(connection.client.as_ref().expect("connected above"));
			// Discard a potentially dead socket. The caller receives the original
			// failure; the next operation gets a freshly validated connection.
			if result.is_err() { connection.client = None; }
			result
		}).await?
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
			let tx = match c.inner.transaction_get(&txid) {
				Ok(tx) => tx,
				Err(err) if transaction_not_found(&err) => return Ok(TxStatus::NotFound),
				Err(err) => return Err(err.into()),
			};
			ensure!(tx.compute_txid() == txid, "Electrum transaction hash mismatch");
			for output in &tx.output {
				if let Some(entry) = c.inner.script_get_history(&output.script_pubkey)?.iter().find(|e| e.tx_hash == txid) {
					return if entry.height > 0 {
						let header = c.inner.block_header(entry.height as usize)?;
						let proof = c.inner.transaction_get_merkle(&txid, entry.height as usize)?;
						ensure!(proof.block_height == entry.height as usize && valid_inclusion_proof(txid, header.merkle_root, &proof), "invalid Electrum inclusion proof");
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

// Electrum encodes branch hashes in display byte order, unlike internal hash bytes.
fn valid_inclusion_proof(txid: Txid, root: bitcoin::TxMerkleNode, proof: &bdk_electrum::electrum_client::GetMerkleRes) -> bool {
	let mut position = proof.pos;
	for _ in &proof.merkle { position >>= 1; }
	position == 0 && bdk_electrum::electrum_client::utils::validate_merkle_proof(&txid, &root, proof)
}

#[cfg(test)]
mod inclusion_tests {
	use super::*;
	#[test]
	fn electrum_inclusion_display_order_and_tampering() {
		// Mainnet block 974884, independently retrieved from mempool.guide.
		let txid: Txid = "677351f04eb19472aab2bf82980d79bad19fe9c5c58ff334ad6f512a1b434bd8".parse().unwrap();
		let root = bitcoin::TxMerkleNode::from_byte_array([14, 36, 98, 252, 101, 240, 157, 10, 101, 243, 125, 123, 135, 117, 96, 185, 91, 191, 55, 6, 204, 248, 120, 45, 184, 93, 250, 155, 80, 236, 162, 152]);
		let mut proof: bdk_electrum::electrum_client::GetMerkleRes = serde_json::from_str(r#"{"block_height":974884,"merkle":["bc8d333b9c70a27042f4d2a896d82b44a3b7d3392af09c9181175a5c3cac04ec","935d885558681a2ee44b0f36f3070cc5138f661f6ab01c9617cc24dc81aadd94","dc4d4b832be415d59be3cd855296dbbe1da38ab6efca774854ca25a8e9357934","0293a9d58c5a4630e68cb9a7aa7ae75dd75cffa8a4c705be39b2e50fff808bca","db45cb9af204b29338649aad960a8ef6183e8ff32a713f2f55a6ad7ff3014e70","c05347b8054239f223d5d25e8ed518c1f9e37e88f45cfd16aebab002542e8d40","9ce77ca72431ead5dd906511b9558a0de296fbca8bcdefd2d9b21aef01ea3d97","d7508d7012813bc454450b37b1b3dd9d1a4a6d5e2d36b1783df0180597cc2f6f","35202aefa4590345d97b47c7d3d7b6e856449c331e5a043106c7f994c2887474"],"pos":470}"#).unwrap();
		assert!(valid_inclusion_proof(txid, root, &proof));
		proof.merkle[0][0] ^= 1;
		assert!(!valid_inclusion_proof(txid, root, &proof));
		proof.merkle[0][0] ^= 1;
		proof.pos += 1 << proof.merkle.len();
		assert!(!valid_inclusion_proof(txid, root, &proof));
	}
}

// Only an explicit missing-transaction response is absence, never a transport failure.
fn transaction_not_found(error: &bdk_electrum::electrum_client::Error) -> bool {
	match error {
		bdk_electrum::electrum_client::Error::Protocol(value) => {
			matches!(value["code"].as_i64(), Some(-5 | 2)) && matches!(value["message"].as_str(),
				Some("No such mempool or blockchain transaction. Use gettransaction for wallet transactions." | "No such mempool or blockchain transaction"))
		},
		_ => false,
	}
}

#[cfg(test)]
mod missing_transaction_tests {
	use super::*;
	use bdk_electrum::electrum_client::Error;
	#[test]
	fn explicit_absence_is_not_a_connection_or_server_failure() {
		for code in [-5, 2] {
			assert!(transaction_not_found(&Error::Protocol(serde_json::json!({"code":code,"message":"No such mempool or blockchain transaction. Use gettransaction for wallet transactions."}))));
		}
		assert!(!transaction_not_found(&Error::Protocol(serde_json::json!({"code":2,"message":"Transaction outputs already in utxo set"}))));
		assert!(!transaction_not_found(&Error::Protocol(serde_json::json!({"code":-32603,"message":"Internal error"}))));
		assert!(!transaction_not_found(&Error::IOError(std::io::Error::from(std::io::ErrorKind::TimedOut))));
	}
}
