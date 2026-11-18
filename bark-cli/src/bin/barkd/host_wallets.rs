//! One seed/network must not run with independent journals in two host profiles.
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::ensure;
use bip39::Mnemonic;
use bitcoin::Network;
use bitcoin::hashes::{Hash, sha256};

// Do not use the short wallet fingerprint for duplicate detection or log this value.
#[derive(PartialEq, Eq)]
pub(super) struct Identity { network: Network, seed: sha256::Hash }

impl Identity {
	pub(super) fn new(network: Network, mnemonic: &Mnemonic) -> Self {
		Self { network, seed: sha256::Hash::hash(&mnemonic.to_seed("")) }
	}
}

/// Hold the shared async mutex through creation/deletion. Claim before the first
/// creation await so cancellation cannot free a partially persisted identity.
#[derive(Default)]
pub(super) struct HostWallets { identities: HashMap<PathBuf, Identity> }

impl HostWallets {
	pub(super) fn claim(&mut self, path: &Path, identity: Identity) -> anyhow::Result<()> {
		ensure!(!self.identities.contains_key(path), "Wallet setup is already recorded. Reopen Paperclip and check this wallet before retrying");
		ensure!(!self.identities.values().any(|saved| *saved == identity),
			"This wallet is already present. Select its existing profile instead of importing it again");
		self.identities.insert(path.to_owned(), identity);
		Ok(())
	}

	/// Only release after a completed delete, or creation explicitly failed and
	/// its private mnemonic is confirmed absent. Ambiguous storage stays claimed.
	pub(super) fn release_if_absent(&mut self, path: &Path) {
		if matches!(std::fs::symlink_metadata(path.join("mnemonic")), Err(e) if e.kind() == std::io::ErrorKind::NotFound) {
			self.identities.remove(path);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::Arc;
	use tokio::sync::Mutex;

	fn identity(byte: u8, network: Network) -> Identity {
		Identity::new(network, &Mnemonic::from_entropy(&[byte; 16]).unwrap())
	}

	#[test]
	fn duplicate_imports_are_network_bound_and_cannot_replace_claims() {
		let mut host = HostWallets::default();
		host.claim(Path::new("main"), identity(1, Network::Regtest)).unwrap();
		assert!(host.claim(Path::new("other"), identity(1, Network::Regtest)).is_err());
		assert!(host.claim(Path::new("main"), identity(2, Network::Regtest)).is_err());
		host.claim(Path::new("mainnet"), identity(1, Network::Bitcoin)).unwrap();
		host.claim(Path::new("other"), identity(2, Network::Regtest)).unwrap();
	}

	#[test]
	fn failed_or_deleted_wallet_releases_only_when_storage_is_absent() {
		let directory = std::env::temp_dir().join(format!("paperclip-host-identity-{}-{}", std::process::id(),
			std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
		std::fs::create_dir(&directory).unwrap();
		let path = directory.as_path();
		let mut host = HostWallets::default();
		host.claim(path, identity(1, Network::Regtest)).unwrap();
		std::fs::write(path.join("mnemonic"), b"private fixture, not a seed").unwrap();
		host.release_if_absent(path);
		assert!(host.claim(Path::new("other"), identity(1, Network::Regtest)).is_err());
		std::fs::remove_file(path.join("mnemonic")).unwrap();
		host.release_if_absent(path);
		host.claim(Path::new("other"), identity(1, Network::Regtest)).unwrap();
		std::fs::remove_dir(directory).unwrap();
	}

	#[tokio::test]
	async fn cancelled_creation_retains_claim_after_releasing_the_mutex() {
		let host = Arc::new(Mutex::new(HostWallets::default()));
		let worker = host.clone();
		let (claimed, ready) = tokio::sync::oneshot::channel();
		let task = tokio::spawn(async move {
			let mut state = worker.lock().await;
			state.claim(Path::new("one"), identity(1, Network::Regtest)).unwrap();
			claimed.send(()).unwrap();
			std::future::pending::<()>().await;
		});
		ready.await.unwrap();
		task.abort(); let _ = task.await;
		let mut state = host.lock().await;
		assert!(state.claim(Path::new("two"), identity(1, Network::Regtest)).is_err());
		assert!(state.claim(Path::new("one"), identity(2, Network::Regtest)).is_err());
	}
}
