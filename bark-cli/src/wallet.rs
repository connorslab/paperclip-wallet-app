//! Wallet utilities
//!
//! Opens a Bark wallet and its on-chain companion from a data directory.
//!
//! ## Behavior
//! - Reads a BIP-39 `mnemonic` file from the provided directory
//! - Parses `config.toml` into a [`bark::Config`]
//! - Opens `db.sqlite` as a [`bark::persist::sqlite::SqliteClient`] and loads persisted properties
//! - Loads or creates the [`bark::onchain::OnchainWallet`], wraps it in
//!   `Arc<RwLock<_>>`, and stores it inside the [`bark::Wallet`] via
//!   [`bark::OpenWalletArgs::onchain`] - BDK-specific methods are accessed
//!   via downcasting through [`bark::Wallet::onchain`]
//! ## Errors
//! Returns an [`anyhow::Error`] with context describing the failing step (I/O, parsing,
//! database access, or wallet initialization).
//!
//! ## Example
//! Open a wallet from a data directory:
//!
//! ```rust,no_run
//! # use std::path::Path;
//! # use bark_cli::wallet::open_wallet;
//! # async fn example() -> anyhow::Result<()> {
//!     let datadir = Path::new("./bark_data");
//!     let bark_wallet = open_wallet(datadir, "myapp/1.0").await?.unwrap();
//!     // Use the wallet...
//!     Ok(())
//! # }
//! ```

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::str::FromStr;

use anyhow::{Context, bail};
use bark::chain::ChainSource;
use bark::fs_perms;
use bark::persist::adaptor::StorageAdaptorWrapper;
use bitcoin::Network;
use clap::Args;
use log::{debug, info, warn};
use tonic::transport::Uri;

use bark::{BarkNetwork, Config, OpenWalletArgs, Wallet as BarkWallet, WalletSeed};
use bark::lock_manager::{self, LockManager, PidLockError};
use bark::lock_manager::pid_flock::LOCK_FILE;
use bark::onchain::OnchainWallet;
use bark::persist::BarkPersister;
use bark::persist::sqlite::{SqliteClient, DEFAULT_DB_FILE};
use bark::persist::adaptor::filestore::FileStorageAdaptor;

use bitcoin_ext::BlockHeight;

use crate::connection::{self, BARKD_LOCK_FILE, BARKD_URL_FILE};
use crate::util;

/// File name of the mnemonic file.
const MNEMONIC_FILE: &str = "mnemonic";

/// File name of the database file.
const DB_FILE: &str = DEFAULT_DB_FILE;
/// File name of the filestore database file.
const FILESTORE_FILE: &str = "wallet.json";

/// File name of the config file.
const CONFIG_FILE: &str = "config.toml";

/// File name of the debug log file.
const DEBUG_LOG_FILE: &str = "debug.log";

/// File name used to persist the auth token in the datadir.
pub const AUTH_TOKEN_FILE: &str = "auth_token";

/// Process log files that may be written into the datadir by the daemon
/// framework during testing; they should be ignored like debug.log.
const STDOUT_LOG_FILE: &str = "stdout.log";
const STDERR_LOG_FILE: &str = "stderr.log";

/// Take the datadir lock via [`lock_manager::platform_default`], surfacing
/// the "already held" case as-is so the CLI prints a clean error.
fn open_lock_manager(datadir: &Path) -> anyhow::Result<Box<dyn LockManager>> {
	match lock_manager::platform_default(Some(datadir), None) {
		Ok(m) => Ok(m),
		Err(e) if e.is::<PidLockError>() => Err(e),
		Err(e) => Err(e.context("failed to acquire datadir lock")),
	}
}

/// Options to define the initial bark config
#[derive(Clone, PartialEq, Eq, Default, clap::Args)]
pub struct ConfigOpts {
	/// The address of your Ark server.
	#[arg(long)]
	pub ark: Option<String>,

	/// [DEPRECATED] The access token for a private server.
	/// Access tokens are no longer enforced by the server; this flag will be removed.
	#[arg(long, hide = true)]
	pub access_token: Option<String>,

	/// XBT Electrum or Fulcrum endpoint (ssl:// or tcp:// with port).
	#[arg(long, conflicts_with_all = ["esplora", "bitcoind"])]
	pub electrum: Option<String>,

	/// SHA256 of the Electrum server's TLS leaf certificate.
	#[arg(long, requires = "electrum")]
	pub electrum_certificate_sha256: Option<String>,

	/// Connect to Electrum through the host's managed Tor proxy.
	#[arg(long, requires = "electrum")]
	pub electrum_tor: bool,

	/// The address of the Esplora HTTP server to use.
	#[arg(long)]
	pub esplora: Option<String>,

	/// The address of the bitcoind RPC server to use.
	#[arg(long)]
	pub bitcoind: Option<String>,

	/// The path to the bitcoind rpc cookie file.
	///
	/// Only used with `bitcoind_address`.
	#[arg(long)]
	pub bitcoind_cookie: Option<String>,

	/// The bitcoind RPC username.
	///
	/// Only used with `bitcoind_address`.
	#[arg(long)]
	pub bitcoind_user: Option<String>,

	/// The bitcoind RPC password.
	///
	/// Only used with `bitcoind_address`.
	#[arg(long)]
	pub bitcoind_pass: Option<String>,

	/// SOCKS5 proxy URL (e.g. socks5h://127.0.0.1:9050 for Tor).
	/// Automatically bypassed for localhost connections.
	#[arg(long)]
	pub socks5_proxy: Option<String>,

	/// How many consecutive unused key indices a VTXO key scan may cross before
	/// it concludes the wallet doesn't own a recovered/imported VTXO.
	#[arg(long)]
	pub gap_limit: Option<u32>,
}

impl ConfigOpts {
	/// Fill the default required config fields based on network
	pub fn fill_network_defaults(&mut self, net: BarkNetwork) {
		// Fallback to our default mainnet
		if net == BarkNetwork::Mainnet {
			// Preserve an explicitly selected chain source.
			if self.esplora.is_none() && self.bitcoind.is_none() && self.electrum.is_none() {
				self.esplora = Some("https://mempool.second.tech/api".to_owned());
			}

			if self.ark.is_none() {
				self.ark = Some("https://ark.second.tech/".to_owned());
			}
		}

		// Fallback to our default signet
		if net == BarkNetwork::Signet {
			// Preserve an explicitly selected chain source.
			if self.esplora.is_none() && self.bitcoind.is_none() && self.electrum.is_none() {
				self.esplora = Some("https://esplora.signet.2nd.dev/".to_owned());
			}

			if self.ark.is_none() {
				self.ark = Some("https://ark.signet.2nd.dev/".to_owned());
			}
		}

		// Fallback to Mutinynet community Esplora
		// Preserve an explicitly selected chain source.
		if net == BarkNetwork::Mutinynet && self.esplora.is_none() && self.bitcoind.is_none() && self.electrum.is_none() {
			self.esplora = Some("https://mutinynet.com/api".to_owned());
		}
	}

	/// Validate the config options are sane
	fn validate(&self) -> anyhow::Result<()> {
		if self.esplora.is_none() && self.bitcoind.is_none() && self.electrum.is_none() {
			bail!("You need to provide a chain source using --electrum, --esplora or --bitcoind");
		}

		if let Some(url) = &self.electrum {
			anyhow::ensure!(self.esplora.is_none() && self.bitcoind.is_none(), "Select one chain backend");
			bark::electrum::validate_endpoint(url, self.electrum_certificate_sha256.as_deref(),
				self.electrum_tor || self.socks5_proxy.is_some())?;
		}
		match (
			self.bitcoind.is_some(),
			self.bitcoind_cookie.is_some(),
			self.bitcoind_user.is_some(),
			self.bitcoind_pass.is_some(),
		) {
			(false, false, false, false) => {},
			(false, _, _, _) => bail!("Provided bitcoind auth args without bitcoind address"),
			(_, true, false, false) => {},
			(_, true, _, _) => bail!("Bitcoind user/pass shouldn't be provided together with cookie file"),
			(_, _, true, true) => {},
			_ => bail!("When providing --bitcoind, you need to provide auth args as well."),
		}

		if let Some(gap_limit) = self.gap_limit {
			if gap_limit > bark::MAX_VTXO_KEY_GAP_LIMIT {
				bail!("--gap-limit {} is above the maximum of {}",
					gap_limit, bark::MAX_VTXO_KEY_GAP_LIMIT);
			}
		}

		if let Some(ref proxy) = self.socks5_proxy {
			let uri = proxy.parse::<Uri>().context("invalid socks5 proxy URI")?;
			let scheme = uri.scheme_str().context("invalid socks5 proxy URI scheme")?;
			if scheme != "socks5h" {
				bail!("Only socks5h:// proxies are supported");
			}
		}

		Ok(())
	}

	/// Will write the provided config options to the config
	///
	/// Will also load and return the config when loaded from the written file.
	fn write_to_file(&self, network: Network, path: impl AsRef<Path>) -> anyhow::Result<Config> {
		use std::fmt::Write;

		let mut conf = String::new();
		let ark = util::default_scheme("https", self.ark.as_ref().context("missing --ark arg")?)
			.context("invalid ark server URL")?;
		writeln!(conf, "server_address = \"{}\"", ark).unwrap();

		if let Some(ref v) = self.access_token {
			writeln!(conf, "server_access_token = \"{}\"", v).unwrap();
		}
		if let Some(url) = &self.electrum {
			writeln!(conf, "electrum_address = {}", toml::Value::String(url.clone()))?;
			writeln!(conf, "electrum_use_host_tor = {}", self.electrum_tor)?;
			if let Some(pin) = &self.electrum_certificate_sha256 {
				writeln!(conf, "electrum_certificate_sha256 = {}", toml::Value::String(pin.clone()))?;
			}
		}
		if let Some(ref v) = self.esplora {
			let url = util::default_scheme("https", v).context("invalid esplora URL")?;
			writeln!(conf, "esplora_address = \"{}\"", url).unwrap();
		}
		if let Some(ref v) = self.bitcoind {
			let url = util::default_scheme("http", v).context("invalid bitcoind URL")?;
			writeln!(conf, "bitcoind_address = \"{}\"", url).unwrap();
		}
		if let Some(ref v) = self.bitcoind_cookie {
			writeln!(conf, "bitcoind_cookiefile = \"{}\"", v).unwrap();
		}
		if let Some(ref v) = self.bitcoind_user {
			writeln!(conf, "bitcoind_user = \"{}\"", v).unwrap();
		}
		if let Some(ref v) = self.bitcoind_pass {
			writeln!(conf, "bitcoind_pass = \"{}\"", v).unwrap();
		}
		if let Some(ref v) = self.socks5_proxy {
			writeln!(conf, "socks5_proxy = \"{}\"", v).unwrap();
		}
		if let Some(v) = self.gap_limit {
			writeln!(conf, "vtxo_key_gap_limit = {}", v).unwrap();
		}

		let path = path.as_ref();

		fs_perms::write_atomic_owner_only(path, conf.as_bytes())?;

		// new let's try load it to make sure it's sane
		Ok(Config::load(network, path).context("problematic config flags provided")?)
	}
}

#[derive(Args)]
pub struct CreateOpts {
	/// Force re-create the wallet even if it already exists.
	/// Any funds in the old wallet will be lost
	#[arg(long)]
	pub force: bool,

	/// Use filestore (JSON file) persistence instead of SQLite.
	/// This creates a marker file so subsequent commands use the same backend.
	///
	/// Warning: do not use this for a production wallet.
	#[arg(long)]
	pub use_filestore: bool,

	/// Use bitcoin mainnet
	#[arg(long)]
	pub mainnet: bool,
	/// Use regtest network
	#[arg(long)]
	pub regtest: bool,
	/// Use the official signet network
	#[arg(long)]
	pub signet: bool,
	/// Use mutinynet
	#[arg(long)]
	pub mutinynet: bool,

	/// Recover a wallet with an existing mnemonic.
	/// This currently only works for on-chain funds.
	#[arg(long)]
	pub mnemonic: Option<bip39::Mnemonic>,

	/// The daemon resolved new system/dice entropy before calling creation.
	/// This is not a CLI option: supplied restore words must keep restore rules.
	#[arg(skip)]
	pub generated_mnemonic: bool,

	/// The wallet/mnemonic's birthday blockheight to start syncing when recovering.
	#[arg(long)]
	pub birthday_height: Option<BlockHeight>,

	#[command(flatten)]
	pub config: ConfigOpts,
}

/// Non-wallet files barkd leaves in the datadir; they must survive a wallet create.
const EXPECTED_DATADIR_FILES: [&str; 7] = [
	DEBUG_LOG_FILE,
	STDOUT_LOG_FILE,
	STDERR_LOG_FILE,
	LOCK_FILE,
	AUTH_TOKEN_FILE,
	BARKD_LOCK_FILE,
	BARKD_URL_FILE,
];

/// Whether `name` is an expected datadir file or an atomic-write temp
/// sibling of one (`.<name>.temp.<nanos>.<n>.tmp`).
fn is_expected_datadir_file(name: &str) -> bool {
	EXPECTED_DATADIR_FILES.iter().chain(&[CONFIG_FILE, "hot-wallets", "hot-wallet-profile"]).any(|expected| {
		name == *expected || name.strip_prefix('.')
			.and_then(|s| s.strip_prefix(expected))
			.and_then(|s| s.strip_prefix(".temp."))
			.is_some_and(|s| s.ends_with(".tmp"))
	})
}

/// Checks the config file and maybe cleans it
/// - returns whether a config file was present
/// - if clean is false, errors if any file not config or logs is present
/// - if clean is true, removes all files not config or logs
async fn check_clean_datadir(datadir: &Path, clean: bool) -> anyhow::Result<bool> {
	let mut has_config = false;
	if datadir.exists() {
		for item in datadir.read_dir().context("error accessing datadir")? {
			let item = item.context("error reading existing content of datadir")?;

			if item.file_name() == CONFIG_FILE {
				has_config = true;
				continue;
			}
			if is_expected_datadir_file(&item.file_name().to_string_lossy()) {
				continue;
			}

			if !clean {
				bail!("Datadir has unexpected contents: {}", item.path().display());
			}

			// otherwise try wipe
			let file_type = item.file_type().context("error accessing datadir content")?;
			if file_type.is_dir() {
				tokio::fs::remove_dir_all(item.path()).await.context("error deleting datadir content")?;
			} else if file_type.is_file() || file_type.is_symlink() {
				tokio::fs::remove_file(item.path()).await.context("error deleting datadir content")?;
			} else {
				// can't happen
				bail!("non-existent file type in ");
			}
		}
	}
	Ok(has_config)
}

pub async fn create_wallet(
	datadir: &Path,
	user_agent: &str,
	opts: CreateOpts,
) -> anyhow::Result<()> {
	debug!("Creating wallet in {}", datadir.display());

	let net = match (opts.mainnet, opts.signet, opts.regtest, opts.mutinynet) {
		(true,  false, false, false) => BarkNetwork::Mainnet,
		(false, true,  false, false) => BarkNetwork::Signet,
		(false, false, true,  false) => BarkNetwork::Regtest,
		(false, false, false, true ) => BarkNetwork::Mutinynet,
		_ => bail!("Specify exactly one of --mainnet, --signet, --regtest or --mutinynet"),
	};

	// check for non-config file contents in the datadir and wipe if force
	let config_existed = check_clean_datadir(datadir, opts.force).await?;

	// Everything that errors after this will wipe the datadir again.
	let result = try_create_wallet(datadir, net, user_agent, opts).await;
	if let Err(e) = result {
		if config_existed {
			if let Err(e) = check_clean_datadir(datadir, true).await {
				warn!("Error cleaning datadir after failure: {:#}", e);
			}
		} else {
			// A barkd serving this datadir must keep its lock and auth
			// token; drop the datadir itself only when nothing is left.
			if let Err(e) = connection::wipe_datadir_except_barkd_files(datadir) {
				warn!("Error cleaning datadir after failure: {:#}", e);
			}
			let _ = fs::remove_dir(datadir);
		}

		bail!("Error while creating wallet: {:#}", e);
	}
	Ok(())
}

/// Return whether creation can start at the current tip. Restore words must keep
/// their explicit RPC rescan birthday; generated words must not require one.
fn validate_creation_birthday(opts: &CreateOpts, config: &Config) -> anyhow::Result<bool> {
	// Explicit new-wallet entropy is already a mnemonic, but is not a restore.
	let is_new_wallet = opts.mnemonic.is_none() || opts.generated_mnemonic;
	if !is_new_wallet {
		if opts.birthday_height.is_none() {
			// Only Bitcoin Core requires a birthday height to avoid syncing the entire chain.
			if config.bitcoind_address.is_some() {
				bail!("You need to set the --birthday-height field when recovering from mnemonic.");
			}
		} else if config.esplora_address.is_some() {
			warn!("The given --birthday-height will be ignored because you're using Esplora.");
		}
	} else {
		if opts.birthday_height.is_some() {
			bail!("A birthday height is only valid when restoring existing words.");
		}
	}

	Ok(is_new_wallet)
}

/// In this method we create the wallet and if it fails, the datadir will be wiped again.
async fn try_create_wallet(
	datadir: &Path,
	net: BarkNetwork,
	user_agent: &str,
	mut opts: CreateOpts,
) -> anyhow::Result<()> {
	info!("Creating new bark Wallet at {}", datadir.display());

	tokio::fs::create_dir_all(datadir).await.context("can't create dir")?;

	fs_perms::harden(datadir, 0o700)?;

	let config_path = datadir.join(CONFIG_FILE);
	let has_config_args = opts.config != ConfigOpts::default();
	let mut config = match (config_path.exists(), has_config_args) {
		(true, false) => {
			Config::load(net.as_bitcoin(), &config_path).with_context(|| format!(
				"error loading existing config file at {}", config_path.display(),
			))?
		},
		// Without config args the network defaults alone can suffice;
		// validate rejects networks that lack a default chain source
		// (e.g. regtest).
		(false, _) => {
			opts.config.fill_network_defaults(net);
			opts.config.validate().context("invalid config options")?;
			opts.config.write_to_file(net.as_bitcoin(), config_path)?
		},
		(true, true) => bail!("Cannot provide an existing config file and config flags"),
	};

	// Default the wire-level client identity to the calling binary unless the
	// operator pinned one in config.toml.
	if config.user_agent.is_none() {
		config.user_agent = Some(user_agent.to_owned());
	}

	let is_new_wallet = validate_creation_birthday(&opts, &config)?;

	// chain source client
	let chain_spec = config.chain_source()
		.context("failed to create a chain source client with the config")?;
	let proxy = chain_spec.proxy_for_connection(&config.socks5_proxy)?;
	let chain = ChainSource::new(chain_spec, net.as_bitcoin(), None, proxy.as_deref()).await
		.context("failed to create a chain source client with the config")?;
	chain.require_version().await.context("chain source version check failed")?;

	// generate seed
	let mnemonic = opts.mnemonic.unwrap_or_else(|| bip39::Mnemonic::generate(12).expect("12 is valid"));
	let seed = mnemonic.to_seed("");

	fs_perms::create_new_owner_only(
		&datadir.join(MNEMONIC_FILE), mnemonic.to_string().as_bytes(),
	)?;

	// open db
	let db: Arc<dyn BarkPersister + Send + Sync> = if opts.use_filestore {
		debug!("Using filestore backend");
		let adaptor = FileStorageAdaptor::open(datadir.join(FILESTORE_FILE)).await?;
		Arc::new(StorageAdaptorWrapper::new(adaptor))
	} else {
		debug!("Using sqlite backend");
		let db = SqliteClient::open(datadir.join(DB_FILE))?;
		fs_perms::harden(&datadir.join(DB_FILE), 0o600)?;
		Arc::new(db)
	};

	let mut onchain = OnchainWallet::load_or_create(net.as_bitcoin(), seed, db.clone()).await?;
	let lock_manager = open_lock_manager(&datadir)?;

	// Skip initial block sync if we generated a new wallet.
	let birthday_height = if is_new_wallet {
		Some(chain.tip().await?)
	} else {
		opts.birthday_height
	};
	onchain.initial_wallet_scan(&chain, birthday_height).await?;

	// Create the wallet by opening with `create_if_not_exists` rather than
	// calling `Wallet::create` directly: opening is what runs seed recovery, so
	// a wallet restored from a mnemonic rebuilds its spendable VTXO set from the
	// recovery mailbox. The on-chain scan above has already run, so recovery can
	// validate recovered VTXOs against their chain anchors. `run_daemon` stays
	// off - this only needs to create and recover.
	BarkWallet::open(
		net.as_bitcoin(),
		WalletSeed::new_from_mnemonic(net.as_bitcoin(), &mnemonic),
		config,
		OpenWalletArgs {
			persister: Some(db),
			lock_manager: Some(lock_manager),
			create_if_not_exists: true,
			create_without_server: opts.force,
			run_daemon: false,
			..Default::default()
		},
	).await.context("error creating wallet")?;
	Ok(())
}

/// Read the raw mnemonic phrase from the wallet datadir.
pub async fn read_mnemonic(datadir: &Path) -> anyhow::Result<String> {
	let path = datadir.join(MNEMONIC_FILE);
	let s = tokio::fs::read_to_string(&path).await
		.with_context(|| format!("failed to read mnemonic file at {}", path.display()))?;
	Ok(s.trim().to_string())
}

pub async fn open_wallet(datadir: &Path, user_agent: &str) -> anyhow::Result<Option<BarkWallet>> {
	debug!("Opening bark wallet in {}", datadir.display());

	// read mnemonic file
	let mnemonic_path = datadir.join(MNEMONIC_FILE);

	if !tokio::fs::try_exists(datadir).await? {
		return Ok(None);
	}

	if !tokio::fs::try_exists(&mnemonic_path).await? {
		return Ok(None);
	}

	// The backend db (sqlite or filestore) is checked by its adaptor on open.
	fs_perms::warn_if_loose(datadir, 0o700);
	fs_perms::warn_if_loose(&mnemonic_path, 0o600);
	fs_perms::warn_if_loose(&datadir.join(CONFIG_FILE), 0o600);

	let mnemonic_str = tokio::fs::read_to_string(&mnemonic_path).await
		.with_context(|| format!("failed to read mnemonic file at {}", mnemonic_path.display()))?;
	let mnemonic = bip39::Mnemonic::from_str(&mnemonic_str).context("broken mnemonic")?;
	let seed = mnemonic.to_seed("");

	let use_filestore = datadir.join(FILESTORE_FILE).exists();
	let db: Arc<dyn BarkPersister + Send + Sync> = if use_filestore {
		debug!("Using filestore backend");
		let adaptor = FileStorageAdaptor::open(datadir.join(FILESTORE_FILE)).await?;
		Arc::new(StorageAdaptorWrapper::new(adaptor))
	} else {
		debug!("Using sqlite backend");
		Arc::new(SqliteClient::open(datadir.join(DB_FILE))?)
	};
	let properties = db.read_properties().await?.context("failed to read properties")?;

	// Read the config
	let config_path = datadir.join("config.toml");
	let mut config = Config::load(properties.network, config_path)
		.context("error loading bark config file")?;

	// Default the wire-level client identity to the calling binary unless the
	// operator pinned one in config.toml.
	if config.user_agent.is_none() {
		config.user_agent = Some(user_agent.to_owned());
	}

	let bdk_wallet = OnchainWallet::load_or_create(properties.network, seed, db.clone()).await?;
	let onchain = Arc::new(tokio::sync::RwLock::new(bdk_wallet));
	let lock_manager = open_lock_manager(datadir)?;
	let bark_wallet = BarkWallet::open(
		properties.network,
		WalletSeed::new_from_mnemonic(properties.network, &mnemonic),
		config,
		OpenWalletArgs {
			persister: Some(db),
			lock_manager: Some(lock_manager),
			onchain: Some(onchain.clone()),
			run_daemon: false,
			..Default::default()
		},
	).await?;

	Ok(Some(bark_wallet))
}

#[cfg(test)]
mod test {
	use super::*;

	fn tmp_dir() -> std::path::PathBuf {
		let dir = std::env::temp_dir()
			.join(format!("bark-wallet-{}", std::process::id()))
			.join(format!("{}", std::time::SystemTime::now()
				.duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
		fs::create_dir_all(&dir).unwrap();
		dir
	}

	/// Options that fail wallet creation with "provide config flags or a
	/// config file", after the datadir checks.
	fn failing_create_opts() -> CreateOpts {
		CreateOpts {
			force: false,
			use_filestore: false,
			mainnet: false,
			regtest: false,
			signet: true,
			mutinynet: false,
			mnemonic: None,
			generated_mnemonic: false,
			birthday_height: None,
			config: ConfigOpts::default(),
		}
	}

	#[test]
	fn electrum_host_setup_preserves_endpoint_pin_and_tor_route() {
		let dir = tmp_dir();
		let mut opts = ConfigOpts {
			electrum: Some("ssl://example.onion:50002".into()),
			electrum_certificate_sha256: Some("ab".repeat(32)),
			electrum_tor: true, ..Default::default()
		};
		opts.fill_network_defaults(BarkNetwork::Mainnet);
		assert!(opts.esplora.is_none());
		opts.validate().unwrap();
		let config = opts.write_to_file(Network::Bitcoin, dir.join(CONFIG_FILE)).unwrap();
		assert_eq!(config.electrum_address, opts.electrum);
		assert_eq!(config.electrum_certificate_sha256, opts.electrum_certificate_sha256);
		assert!(config.electrum_use_host_tor);
		opts.electrum_tor = false;
		assert!(opts.validate().is_err());
		opts.electrum = Some("tcp://localhost:50001".into());
		assert!(opts.validate().is_err());
		fs::remove_dir_all(dir).unwrap();
	}

	#[test]
	fn generated_mnemonic_does_not_turn_rpc_creation_into_a_restore() {
		let dir = tmp_dir();
		let mut opts = failing_create_opts();
		opts.config = ConfigOpts { ark: Some("http://127.0.0.1:1".into()),
			bitcoind: Some("http://127.0.0.1:1".into()), bitcoind_user: Some("fixture".into()),
			bitcoind_pass: Some("fixture".into()), ..Default::default() };
		let config = opts.config.write_to_file(Network::Regtest, dir.join("config.toml")).unwrap();
		assert!(validate_creation_birthday(&opts, &config).unwrap());
		opts.mnemonic = Some(bip39::Mnemonic::from_entropy(&[3;16]).unwrap());
		assert!(validate_creation_birthday(&opts, &config).is_err());
		opts.generated_mnemonic = true;
		assert!(validate_creation_birthday(&opts, &config).unwrap());
		opts.birthday_height = Some(0.into());
		assert!(validate_creation_birthday(&opts, &config).is_err());
		opts.generated_mnemonic = false;
		assert!(!validate_creation_birthday(&opts, &config).unwrap());
		fs::remove_dir_all(dir).unwrap();
	}

	/// --gap-limit is config, not a one-shot: it must land in config.toml so
	/// later commands (imports, a re-created wallet) see the same limit.
	#[test]
	fn gap_limit_is_written_to_config() {
		let dir = tmp_dir();
		let path = dir.join(CONFIG_FILE);
		let opts = ConfigOpts {
			ark: Some("http://127.0.0.1:3535".into()),
			esplora: Some("http://127.0.0.1:3002".into()),
			gap_limit: Some(10_000),
			..ConfigOpts::default()
		};

		let config = opts.write_to_file(Network::Signet, &path)
			.expect("writing the config should succeed");

		assert_eq!(config.vtxo_key_gap_limit, 10_000, "the written config should carry the limit");
		let written = fs::read_to_string(&path).expect("config file should exist");
		assert!(written.contains("vtxo_key_gap_limit = 10000"), "unexpected config: {written}");

		// Omitting the flag leaves the network default in place.
		let bare_path = dir.join("bare.toml");
		let bare = ConfigOpts { gap_limit: None, ..opts }
			.write_to_file(Network::Signet, &bare_path)
			.expect("writing the config should succeed");
		assert_eq!(bare.vtxo_key_gap_limit, bark::DEFAULT_VTXO_KEY_GAP_LIMIT,
			"without the flag the default should stand");
	}

	#[tokio::test]
	async fn failed_create_keeps_barkd_files() {
		let dir = tmp_dir();
		fs::write(dir.join(AUTH_TOKEN_FILE), "tok").unwrap();
		fs::write(dir.join(BARKD_LOCK_FILE), "42").unwrap();

		create_wallet(&dir, "test", failing_create_opts()).await.unwrap_err();

		assert!(dir.join(AUTH_TOKEN_FILE).exists());
		assert!(dir.join(BARKD_LOCK_FILE).exists());

		let _ = fs::remove_dir_all(&dir);
	}

	#[tokio::test]
	async fn failed_create_removes_empty_datadir() {
		let dir = tmp_dir();

		create_wallet(&dir, "test", failing_create_opts()).await.unwrap_err();

		assert!(!dir.exists());
	}

	#[tokio::test]
	async fn profile_storage_survives_failed_creation_and_force_cleanup() {
		let dir = tmp_dir();
		fs::create_dir(dir.join("hot-wallets")).unwrap();
		fs::write(dir.join("hot-wallets/profiles.json"), "other wallets").unwrap();
		fs::write(dir.join("hot-wallet-profile"), "profile identity").unwrap();
		create_wallet(&dir, "test", failing_create_opts()).await.unwrap_err();
		assert_eq!(fs::read_to_string(dir.join("hot-wallets/profiles.json")).unwrap(), "other wallets");
		assert_eq!(fs::read_to_string(dir.join("hot-wallet-profile")).unwrap(), "profile identity");
		fs::write(dir.join("db.sqlite"), "old wallet").unwrap();
		check_clean_datadir(&dir, true).await.unwrap();
		assert!(dir.join("hot-wallets/profiles.json").exists());
		assert!(dir.join("hot-wallet-profile").exists());
		assert!(!dir.join("db.sqlite").exists());
		let _ = fs::remove_dir_all(dir);
	}

	#[test]
	fn expected_datadir_files_and_their_temps() {
		assert!(is_expected_datadir_file("auth_token"));
		assert!(is_expected_datadir_file("hot-wallets"));
		assert!(is_expected_datadir_file("barkd.lock"));
		assert!(is_expected_datadir_file("barkd.url"));
		// Atomic-write temp siblings, mid-write or left by a crash.
		assert!(is_expected_datadir_file(".auth_token.temp.42.3.tmp"));
		assert!(is_expected_datadir_file(".config.toml.temp.42.0.tmp"));

		assert!(!is_expected_datadir_file("mnemonic"));
		assert!(!is_expected_datadir_file("db.sqlite"));
		assert!(!is_expected_datadir_file(".mnemonic.temp.42.0.tmp"));
		assert!(!is_expected_datadir_file("barkd.lock.bak"));
	}
}

