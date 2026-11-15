//! Mobile storage adapter for the shared public-only QR signing engine.
use anyhow::{Context, ensure};
use base64::Engine;
use bitcoin::Network;
use bark::persist::BarkPersister;
pub use bark::onchain::qr::*;

/// Keep the funding wallet's database lock while an Ark QR request is pending.
/// Ark keys and recovery state remain in the selected mobile wallet.
pub struct PublicFundingWallet {
	pub onchain: std::sync::Arc<tokio::sync::RwLock<bark::onchain::OnchainWallet>>,
	_lock: Box<dyn bark::lock_manager::LockManager>,
}

pub async fn open_funding_wallet(request: &serde_json::Value, network: Network) -> anyhow::Result<PublicFundingWallet> {
	let directory = std::path::PathBuf::from(request["directory"].as_str().context("funding wallet directory required")?);
	ensure!(directory.is_absolute() && directory.join("db.sqlite").is_file(), "funding wallet database missing");
	let descriptor = request["descriptor"].as_str().context("funding descriptor required")?;
	let (receive, change) = descriptors(descriptor, "segwit", "", network, true)?;
	let marker: serde_json::Value = serde_json::from_slice(&std::fs::read(directory.join("public-wallet.json"))?)?;
	ensure!(marker == serde_json::json!({"kind": "hardware", "receive": receive, "change": change}), "funding wallet descriptor mismatch");
	let identity = base64::engine::general_purpose::STANDARD.decode(request["identity"].as_str().context("funding wallet identity required")?)?;
	let identity: [u8; 64] = identity.try_into().map_err(|_| anyhow::anyhow!("invalid funding wallet identity"))?;
	let seed = bark::WalletSeed::new_from_seed(network, &identity);
	let lock = bark::lock_manager::platform_default(Some(&directory), Some(seed.fingerprint()))?;
	let db = std::sync::Arc::new(bark::persist::sqlite::SqliteClient::open(directory.join("db.sqlite"))?);
	let properties = db.read_properties().await?.context("funding wallet not initialized")?;
	ensure!(properties.network == network && properties.fingerprint == seed.fingerprint(), "funding wallet identity or network mismatch");
	let onchain = bark::onchain::OnchainWallet::load_or_create_public(network, &receive, &change, db.clone()).await?;
	Ok(PublicFundingWallet { onchain: std::sync::Arc::new(tokio::sync::RwLock::new(onchain)), _lock: lock })
}
