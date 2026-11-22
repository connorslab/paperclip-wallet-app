mod host_wallets;

use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;

use anyhow::{anyhow, bail, ensure, Context};
use bitcoin::hex::FromHex;
use bitcoin::secp256k1::rand::{self, RngCore};
use clap::{Parser, Subcommand};
use clap::builder::BoolishValueParser;
use log::{info, warn};

use bark_json::web::{BarkNetwork, BitcoindAuth, ChainSourceConfig, CreateWalletRequest};
use bark_rest::{Config, OnGetMnemonic, OnWalletCreate, OnWalletDelete, RestServer, ServerState};
use bark_rest::http::HeaderValue;
use bark_rest::error::ContextExt;
use bark_rest::auth::AuthToken;

use bark::fs_perms;
use host_wallets::{HostWallets, Identity};

use bark_cli::VERSION_DEV_MARKER;
use bark_cli::connection;
use bark_cli::log::init_logging;
use bark_cli::wallet::{ConfigOpts, CreateOpts, create_wallet, open_wallet, read_mnemonic, AUTH_TOKEN_FILE};
use tokio_util::sync::CancellationToken;


/// The full version string we show in our binary.
/// (BARK_VERSION and GIT_HASH are set in build.rs)
const FULL_VERSION: &str = concat!(env!("BARK_VERSION"), " (", env!("GIT_HASH"), ")");

/// Wire-level client identity sent in `x-user-agent` on every RPC.
const USER_AGENT: &str = concat!("paperclip-walletd/", env!("BARK_VERSION"));


fn default_datadir() -> String {
	home::home_dir().or_else(|| {
		std::env::current_dir().ok()
	}).unwrap_or_else(|| {
		"./".into()
	}).join(".paperclip-wallet-regtest").display().to_string()
}

#[cfg(any(feature = "barkd-web-ui", test))]
fn ui_default_chain_source() -> String {
	"http://127.0.0.1:18443".to_owned()
}

#[cfg(any(feature = "barkd-web-ui", test))]
fn ui_default_ark_server() -> String {
	"https://ark.paperclip-xbt.xyz".to_owned()
}

#[derive(Parser)]
#[command(name = "paperclip-walletd", about = "Paperclip XBT wallet API", version = FULL_VERSION)]
struct Cli {
	/// Enable verbose logging
	#[arg(
		long,
		short = 'v',
		env = "BARK_VERBOSE",
		global = true,
		value_parser = BoolishValueParser::new(),
	)]
	verbose: bool,
	/// Disable all terminal logging
	#[arg(
		long,
		short = 'q',
		env = "BARK_QUIET",
		global = true,
		value_parser = BoolishValueParser::new(),
	)]
	quiet: bool,

	/// Write the debug log to this file instead of the default
	/// `<datadir>/debug.log`
	#[arg(long, env = "BARK_LOGFILE", global = true, conflicts_with = "no_logfile")]
	logfile: Option<PathBuf>,
	/// Disable the debug log file entirely
	#[arg(
		long,
		env = "BARK_NO_LOGFILE",
		global = true,
		conflicts_with = "logfile",
		value_parser = BoolishValueParser::new(),
	)]
	no_logfile: bool,

	/// The datadir of the bark wallet
	#[arg(long, env = "BARKD_DATADIR", global = true, default_value_t = default_datadir())]
	datadir: String,

	#[command(subcommand)]
	command: Option<Command>,

	/// Stop gracefully when the owning launcher's stdin pipe closes.
	/// Intended for managed desktop processes; no bytes are interpreted as commands.
	#[arg(long)]
	exit_on_stdin_close: bool,
	/// Enable single-use browser sign-in for an authenticated loopback desktop UI.
	#[arg(long, requires = "exit_on_stdin_close")]
	desktop_handoff: bool,

	/// The port to listen on. Zero lets the OS choose an available port.
	#[arg(long, env = "BARKD_BIND_PORT")]
	port: Option<u16>,
	/// The host to listen on. Defaults to loopback; any other value may expose
	/// the API to other machines on your network or the public internet.
	#[arg(long, env = "BARKD_BIND_HOST")]
	host: Option<String>,

	/// Comma-separated list of allowed CORS origins (e.g. "http://localhost:3001,https://myapp.example.com").
	/// Defaults to denying all cross-origin requests; any value may expose the
	/// API to browser clients on other origins.
	#[arg(long, env = "BARKD_ALLOWED_ORIGINS", value_delimiter = ',')]
	allowed_origins: Vec<String>,

	/// Expose `GET /api/v1/wallet/mnemonic`, which returns the wallet's BIP-39
	/// mnemonic phrase. Disabled by default; while disabled the endpoint
	/// responds with 404. Pass `--expose-mnemonic` (or set
	/// `BARKD_EXPOSE_MNEMONIC=true`) to enable it.
	#[arg(
		long,
		env = "BARKD_EXPOSE_MNEMONIC",
		default_value_t = false,
		value_parser = BoolishValueParser::new(),
	)]
	expose_mnemonic: bool,

	/// Disables all authentication.
	///
	/// Anyone who can access the HTTP port can create invoices, spend all coins
	/// and might retrieve the mnemonic.
	///
	/// This option is mainly useful for testing and development.
	///
	/// Deliberately has no environment variable. We don't want auth to be
	/// disabled by an inherited environment.
	#[arg(long)]
	no_auth: bool,

	/// Disables all authentication and permits a non-loopback bind.
	///
	/// Implies --no-auth, so it is passed on its own. Anything that can route
	/// to the bind address gets full wallet access, so only use this when
	/// something else restricts who can reach the port.
	#[arg(long)]
	dangerously_allow_remote_no_auth: bool,

	/// Don't serve the embedded bark-web wallet UI.
	#[cfg(feature = "barkd-web-ui")]
	#[arg(long, env = "BARKD_NO_UI", value_parser = BoolishValueParser::new())]
	no_ui: bool,

	/// Ark server URL the UI's create-wallet flow uses while no wallet is
	/// loaded
	#[cfg(feature = "barkd-web-ui")]
	#[arg(long, env = "BARKD_UI_DEFAULT_ARK_SERVER", default_value_t = ui_default_ark_server())]
	ui_default_ark_server: String,

	/// Chain source (esplora) URL the UI's create-wallet flow uses while no
	/// wallet is loaded
	#[cfg(feature = "barkd-web-ui")]
	#[arg(long, env = "BARKD_UI_DEFAULT_CHAIN_SOURCE", default_value_t = ui_default_chain_source())]
	ui_default_chain_source: String,

	/// Network the UI's create-wallet flow uses while no wallet is loaded
	#[cfg(feature = "barkd-web-ui")]
	#[arg(long, env = "BARKD_UI_DEFAULT_NETWORK", default_value = "regtest")]
	ui_default_network: String,
}

#[derive(Subcommand)]
enum Command {
	/// Manage auth secrets
	Secret {
		#[command(subcommand)]
		action: SecretCommand,
	},
}

fn parse_hex_secret(s: &str) -> Result<[u8; 32], String> {
	<[u8; 32]>::from_hex(s)
		.map_err(|_| "must be exactly 64 hex characters (32 bytes)".to_string())
}

#[derive(Subcommand)]
enum SecretCommand {
	/// Print the current bearer token.
	Show,
	/// Regenerate the default auth secret and print the bearer token.
	/// If --secret is provided, use that instead of generating a random one.
	Refresh {
		/// Optional 32-byte hex secret to use instead of a random one
		#[arg(long, value_parser = parse_hex_secret)]
		secret: Option<[u8; 32]>,
	},
}

impl Cli {
	fn to_config(&self) -> anyhow::Result<Config> {
		let mut cfg = Config::default();
		if let Some(port) = &self.port {
			cfg.port = *port;
		}
		if let Some(host) = &self.host {
			cfg.host = host.parse()
				.with_context(|| format!("invalid bind host: {host}"))?;
		}
		// Validate that each origin is a well-formed origin (scheme://host[:port]).
		for origin in &self.allowed_origins {
			origin.parse::<HeaderValue>()
				.with_context(|| format!("invalid CORS origin: {origin}"))?;
			let valid = (origin.starts_with("http://") || origin.starts_with("https://"))
				&& !origin.ends_with('/')
				&& origin.matches("://").count() == 1;
			if !valid {
				bail!(
					"invalid CORS origin: {origin} \
					(expected format: http://host[:port] or https://host[:port])"
				);
			}
		}
		cfg.allowed_origins = self.allowed_origins.clone();
		if self.desktop_handoff && (self.auth_disabled() || !cfg.host.is_loopback()) {
			bail!("Desktop handoff requires authenticated loopback binding");
		}
		#[cfg(feature = "barkd-web-ui")]
		if self.desktop_handoff && self.no_ui {
			bail!("Desktop handoff requires the embedded wallet UI");
		}
		#[cfg(not(feature = "barkd-web-ui"))]
		if self.desktop_handoff {
			bail!("Desktop handoff requires the embedded wallet UI");
		}
		Ok(cfg)
	}

	/// Either flag disables auth; only the dangerous one also permits a
	/// non-loopback bind.
	fn auth_disabled(&self) -> bool {
		self.no_auth || self.dangerously_allow_remote_no_auth
	}
}

/// Refuse to run without auth on a bind address other hosts can reach, unless
/// the operator asked for exactly that with the dangerous flag.
fn check_remote_no_auth(host: IpAddr, allow_remote: bool) -> anyhow::Result<()> {
	if host.is_loopback() || allow_remote {
		return Ok(());
	}

	bail!(
		"refusing to start: --no-auth with bind host {host} would give full wallet access \
		to every client that can reach the port. Bind a loopback address, or use \
		--dangerously-allow-remote-no-auth instead if reachability is restricted by other \
		means (and terminate TLS in front of barkd)",
	);
}

/// Watch launcher lifetime on a dedicated OS thread. Tokio's blocking stdin
/// task can hold runtime shutdown open while a healthy launcher keeps its pipe
/// open; this detached reader must not prevent other shutdown paths from exiting.
fn watch_launcher_pipe(shutdown: CancellationToken) -> anyhow::Result<()> {
	std::thread::Builder::new().name("launcher-lifetime".into()).spawn(move || {
		let stdin = std::io::stdin();
		let mut input = stdin.lock();
		let mut buffer = [0u8; 64];
		loop {
			match input.read(&mut buffer) {
				Ok(0) => break,
				Ok(_) => {},
				Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
				Err(_) => break,
			}
		}
		shutdown.cancel();
	}).context("Failed to watch launcher lifetime")?;
	Ok(())
}

/// Return on SIGTERM, Ctrl+C, or cancellation by the owning launcher.
async fn run_shutdown_signal_listener(shutdown: CancellationToken) {
	async fn signal_recv() {
		#[cfg(unix)]
		{
			let mut sigterm = tokio::signal::unix::signal(
				tokio::signal::unix::SignalKind::terminate()
			).expect("Failed to listen for SIGTERM");

			sigterm.recv().await;
			info!("SIGTERM received! Sending shutdown signal...");
			return;
		}

		#[cfg(windows)]
		{
			let mut ctrl_break = tokio::signal::windows::ctrl_break()
				.expect("Failed to listen for CTRL+BREAK");

			ctrl_break.recv().await;
			info!("CTRL+BREAK received! Sending shutdown signal...");
			return
		}

		#[cfg(not(any(unix, windows)))]
		{
			log::warn!("Unknown platform, not listening for shutdown signals");
			std::future::pending().await
		}
	}

	tokio::select! {
		_ = shutdown.cancelled() => {},
		_ = signal_recv() => {},
		r = tokio::signal::ctrl_c() => match r {
			Ok(()) => info!("Ctrl+C received! Sending shutdown signal..."),
			Err(e) => panic!("failed to listen to ctrl-c signal: {e}"),
		},
	}

	shutdown.cancel();
}

/// Load the auth token from the datadir. Returns `None` if the file
/// doesn't exist.
fn load_auth_token(datadir: &PathBuf) -> anyhow::Result<Option<AuthToken>> {
	let path = datadir.join(AUTH_TOKEN_FILE);
	// Base64url of one version byte plus 32 secret bytes, without whitespace.
	let bytes = match fs_perms::read_owner_only(&path, 44) {
		Ok(bytes) => bytes,
		Err(error) if error.downcast_ref::<std::io::Error>().is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) => return Ok(None),
		Err(error) => return Err(error.context("failed to read private authentication storage")),
	};
	// Do not include decoder details or credential contents in startup logs.
	let encoded = std::str::from_utf8(&bytes).map_err(|_| anyhow!("invalid authentication storage"))?;
	let token = AuthToken::decode(encoded).map_err(|_| anyhow!("invalid authentication storage"))?;
	ensure!(token.encode() == encoded, "invalid authentication storage");
	Ok(Some(token))
}

/// Write the auth token to the datadir.
fn store_auth_token(datadir: &PathBuf, token: &AuthToken) -> anyhow::Result<()> {
	let path = datadir.join(AUTH_TOKEN_FILE);
	// This also handles `secret refresh`, which overwrites an existing token.
	fs_perms::write_atomic_owner_only(&path, token.encode().as_bytes())
}

/// Generate a random auth token and persist it to the datadir.
fn generate_store_auth_token(datadir: &PathBuf) -> anyhow::Result<AuthToken> {
	let mut secret = [0u8; 32];
	rand::thread_rng().fill_bytes(&mut secret);
	let token = AuthToken::new(secret);
	store_auth_token(datadir, &token)?;
	Ok(token)
}

fn wallet_create_request_to_create_opts(req: CreateWalletRequest) -> anyhow::Result<CreateOpts> {
	let generated_mnemonic = req.mnemonic.is_none();
	let generation = req.seed_generation.or_else(|| generated_mnemonic.then_some(bark_json::web::SeedGeneration::System { words: 12 }));
	let mnemonic = bark_cli::seed::resolve(req.mnemonic, generation)
		.badarg("Invalid wallet entropy selection")?;

	#[allow(deprecated)]
	let mut config = ConfigOpts {
		ark: req.ark_server,
		access_token: req.ark_server_access_token,
		electrum: None,
		electrum_certificate_sha256: None,
		electrum_tor: false,
		esplora: None,
		bitcoind: None,
		bitcoind_cookie: None,
		bitcoind_user: None,
		bitcoind_pass: None,
		socks5_proxy: None,
		gap_limit: req.gap_limit,
	};

	if let Some(chain_source) = req.chain_source {
		let chain_source = match chain_source {
			ChainSourceConfig::Platform => {
				let path = std::env::var("PAPERCLIP_PLATFORM_CONNECTION")
					.context("No installed node connection is configured; use manual setup")?;
				let bytes = std::fs::read(path).context("Installed node connection is not ready")?;
				serde_json::from_slice::<ChainSourceConfig>(&bytes)
					.context("Invalid installed node connection")?
			},
			other => other,
		};
		match chain_source {
			ChainSourceConfig::Platform => anyhow::bail!("Invalid recursive installed node connection"),
			ChainSourceConfig::Electrum { url, certificate_sha256, use_tor } => {
				config.electrum = Some(url);
				config.electrum_certificate_sha256 = certificate_sha256;
				config.electrum_tor = use_tor;
			},
			ChainSourceConfig::Esplora { url } => {
				config.esplora = Some(url);
			},
			ChainSourceConfig::Bitcoind { bitcoind, bitcoind_auth } => {
				config.bitcoind = Some(bitcoind);
				match bitcoind_auth {
					BitcoindAuth::Cookie { cookie } => {
						config.bitcoind_cookie = Some(cookie);
					},
					BitcoindAuth::UserPass { user, pass } => {
						config.bitcoind_user = Some(user);
						config.bitcoind_pass = Some(pass);
					},
				}
			},
		}
	}

	Ok(CreateOpts {
		force: req.force,
		use_filestore: false,
		mainnet: req.network == BarkNetwork::Mainnet,
		regtest: req.network == BarkNetwork::Regtest,
		signet: req.network == BarkNetwork::Signet,
		mutinynet: req.network == BarkNetwork::Mutinynet,
		mnemonic: mnemonic,
		generated_mnemonic,
		birthday_height: req.birthday_height.map(Into::into),
		config: config,
	})
}

async fn wallet_state(
	datadir: PathBuf, auth_token: Option<AuthToken>, expose_mnemonic: bool, shutdown: CancellationToken,
	host_wallets: Arc<tokio::sync::Mutex<HostWallets>>,
) -> anyhow::Result<bark_rest::ServerStateBuilder> {
	let opened_wallet = tokio::select! {
		_ = shutdown.cancelled() => anyhow::bail!("Wallet startup cancelled"),
		result = open_wallet(&datadir, USER_AGENT) => result?,
	};
	if shutdown.is_cancelled() {
		anyhow::bail!("Wallet startup cancelled");
	}
	let wallet_opt = if let Some(wallet) = opened_wallet {
		let mnemonic = bip39::Mnemonic::from_str(&read_mnemonic(&datadir).await?)?;
		let identity = Identity::new(wallet.properties().await?.network, &mnemonic);
		host_wallets.lock().await.claim(&datadir, identity)?;
		wallet.start_daemon()?;
		info!("Wallet loaded and daemon started");
		Some(wallet)
	} else {
		warn!("No wallet found. Starting rest server without daemon");
		None
	};

	let on_wallet_create: Box<OnWalletCreate> = Box::new({
		let datadir = datadir.clone();
		let host_wallets = host_wallets.clone();

		move |req: CreateWalletRequest| {
			let datadir = datadir.clone();
			let host_wallets = host_wallets.clone();

			Box::pin(async move {
				let network = match req.network {
					BarkNetwork::Mainnet => bitcoin::Network::Bitcoin,
					BarkNetwork::Regtest => bitcoin::Network::Regtest,
					BarkNetwork::Signet | BarkNetwork::Mutinynet => bitcoin::Network::Signet,
				};
				let create_opts = wallet_create_request_to_create_opts(req)?;
				let mnemonic = create_opts.mnemonic.as_ref().context("Wallet entropy was not resolved")?;
				let mut identities = host_wallets.lock().await;
				identities.claim(&datadir, Identity::new(network, mnemonic))
					.badarg("This wallet is already present or its setup needs recovery. Reopen Paperclip and select its existing profile before retrying")?;
				if let Err(error) = create_wallet(&datadir, USER_AGENT, create_opts).await {
					identities.release_if_absent(&datadir);
					return Err(error);
				}
				let wallet = open_wallet(&datadir, USER_AGENT).await?
					.expect("Wallet should exist");

				// Warm up `wallet.server` before spawning the daemon so
				// that subsequent REST requests don't race with the daemon's
				// first connection check.
				if let Err(e) = wallet.refresh_server().await {
					warn!("Ark server handshake failed on wallet creation: {:#}", e);
				}

				wallet.start_daemon()?;
				Ok::<_, anyhow::Error>(wallet)
			})
		}
	});

	let on_wallet_delete: Box<OnWalletDelete> = Box::new({
		let datadir = datadir.clone();
		let host_wallets = host_wallets.clone();
		move || {
			let datadir = datadir.clone();
			let host_wallets = host_wallets.clone();

			// NB: No need to stop the daemon here, it will be stopped when the wallet is removed from the server state

			Box::pin(async move {
				let mut identities = host_wallets.lock().await;
				connection::wipe_datadir_except_barkd_files(&datadir)?;
				identities.release_if_absent(&datadir);
				Ok(())
			})
		}
	});

	let on_get_mnemonic: Option<Box<OnGetMnemonic>> = if expose_mnemonic {
		let datadir = datadir.clone();
		Some(Box::new(move || {
			let datadir = datadir.clone();
			Box::pin(async move { read_mnemonic(&datadir).await })
		}))
	} else {
		None
	};

	Ok(ServerState::builder()
		.wallet(wallet_opt)
		.auth_token(auth_token)
		.on_wallet_create(on_wallet_create)
		.on_wallet_delete(on_wallet_delete)
		.on_get_mnemonic(on_get_mnemonic))

}

#[tokio::main]
async fn main() -> anyhow::Result<()>{
	let cli = Cli::parse();

	let datadir = PathBuf::from_str(&cli.datadir).unwrap();
	connection::require_standalone_datadir(&datadir)?;

	let datadir_existed = datadir.exists();
	std::fs::create_dir_all(&datadir)
		.with_context(|| format!("failed to create datadir {}", datadir.display()))?;
	if !datadir_existed {
		fs_perms::harden(&datadir, 0o700)?;
	}

	init_logging(cli.verbose, cli.quiet, &datadir, cli.logfile.clone(), cli.no_logfile);

	if datadir_existed {
		fs_perms::warn_if_loose(&datadir, 0o700);
	}

	// Handle subcommands that don't start the daemon.
	if let Some(command) = &cli.command {
		if cli.port.is_some() || cli.host.is_some() {
			warn!("--port and --host are only used when running the daemon, ignoring");
		}

		match command {
			Command::Secret { action: SecretCommand::Show } => {
				let token = load_auth_token(&datadir)?
					.context("no auth token found - run `barkd secret refresh` to generate one")?;
				println!("{}", token.encode());
				return Ok(());
			},
			Command::Secret { action: SecretCommand::Refresh { secret: user_secret } } => {
				let token = if let Some(bytes) = user_secret {
					let token = AuthToken::new(*bytes);
					store_auth_token(&datadir, &token)?;
					token
				} else {
					generate_store_auth_token(&datadir)?
				};
				info!("Restart barkd for the new token to take effect.");
				println!("{}", token.encode());
				return Ok(());
			},
		}
	}

	let config = cli.to_config()?;

	let shutdown = CancellationToken::new();
	if cli.exit_on_stdin_close {
		watch_launcher_pipe(shutdown.clone())?;
	}

	info!("Starting barkd version {} with datadir {}", FULL_VERSION, datadir.display());

	if env!("BARK_VERSION").contains(VERSION_DEV_MARKER) {
		warn!("You're running a custom build of barkd, which might cause unexpected issues. \
			Consider building at one of the tagged versions or using the release builds.");
	}

	let _barkd_lock = connection::acquire_barkd_lock(&datadir)?;

	let auth_token = if cli.auth_disabled() {
		check_remote_no_auth(config.host, cli.dangerously_allow_remote_no_auth)?;
		if cli.allowed_origins.is_empty() {
			warn!("Auth is disabled and no CORS origins are configured - \
				any client that can reach this port has full API access.");
		}
		None
	} else {
		let token = match load_auth_token(&datadir)? {
			Some(token) => token,
			None => {
				let token = generate_store_auth_token(&datadir)?;
				info!("No auth token found - generated a new one. Use `barkd secret show` to view it.");
				token
			},
		};
		Some(token)
	};

	let host_wallets = Arc::new(tokio::sync::Mutex::new(HostWallets::default()));
	let builder = wallet_state(datadir.clone(), auth_token.clone(), cli.expose_mnemonic, shutdown.clone(), host_wallets.clone()).await?;

	// Serve the embedded bark-web SPA from the same origin as the REST API.
	#[cfg(feature = "barkd-web-ui")]
	let builder = builder.web(if cli.no_ui {
		None
	} else {
		Some(bark_rest::web::WebConfig {
			ark_server: cli.ui_default_ark_server.clone(),
			chain_source: cli.ui_default_chain_source.clone(),
			network: cli.ui_default_network.clone(),
			wallet_data_path: cli.datadir.clone(),
			datadir: datadir.clone(),
		})
	});

	#[cfg(feature = "barkd-web-ui")]
	let builder = if !cli.no_ui {
		let defaults = bark_rest::web::WebConfig {
			ark_server: cli.ui_default_ark_server.clone(), chain_source: cli.ui_default_chain_source.clone(),
			network: cli.ui_default_network.clone(), wallet_data_path: String::new(), datadir: PathBuf::new(),
		};
		let shutdown = shutdown.clone();
		let expose_mnemonic = cli.expose_mnemonic;
		let open: Arc<bark_rest::profiles::OpenProfile> = Arc::new(move |path| {
			let auth = auth_token.clone();
			let host_wallets = host_wallets.clone();
			let shutdown = shutdown.clone();
			let mut web = defaults.clone();
			web.wallet_data_path = path.display().to_string(); web.datadir = path.clone();
			Box::pin(async move {
				Ok(wallet_state(path, auth, expose_mnemonic, shutdown.clone(), host_wallets).await?.web(web).build(shutdown))
			})
		});
		builder.profiles(Arc::new(bark_rest::profiles::Profiles::open(&datadir, open).await?))
	} else { builder };

	let state = builder.build(shutdown.clone());
	let server = if cli.desktop_handoff {
		RestServer::start_desktop(&config, Arc::new(state), shutdown.clone()).await?
	} else {
		RestServer::start(&config, Arc::new(state), shutdown.clone()).await?
	};

	// Publish discovery only after a successful bind; failed starts must not
	// replace an existing address or advertise an unusable port zero.
	// Map an unspecified listener address to loopback for local clients.
	let mut connect_addr = server.local_addr();
	if connect_addr.ip().is_unspecified() {
		connect_addr.set_ip(match connect_addr.ip() {
			IpAddr::V4(_) => IpAddr::V4(Ipv4Addr::LOCALHOST),
			IpAddr::V6(_) => IpAddr::V6(Ipv6Addr::LOCALHOST),
		});
	}
	if let Err(error) = connection::store_barkd_url(&datadir, &format!("http://{}", connect_addr)) {
		let _ = server.stop_wait().await;
		return Err(error.context("Failed to publish the listener address"));
	}

	run_shutdown_signal_listener(shutdown.clone()).await;


	if let Err(e) = server.stop_wait().await {
		warn!("Error while stopping REST server: {:#}", e);
	}

	Ok(())
}

#[cfg(test)]
mod test {
	use super::*;

	#[test]
	fn auth_storage_requires_canonical_private_token_and_preserves_failures() {
		let root = std::env::temp_dir().join(format!("paperclip-auth-read-{}-{}", std::process::id(),
			std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
		std::fs::create_dir(&root).unwrap();
		fs_perms::harden(&root, 0o700).unwrap();
		assert!(load_auth_token(&root).unwrap().is_none());
		assert_eq!(std::fs::read_dir(&root).unwrap().count(), 0);
		let token = AuthToken::new([7;32]);
		store_auth_token(&root, &token).unwrap();
		assert!(load_auth_token(&root).unwrap().unwrap() == token);
		let path = root.join(AUTH_TOKEN_FILE);
		for corrupt in [b"invalid synthetic credential".to_vec(), vec![0xff;44], vec![b'A';45],
			format!("{}\n", token.encode()).into_bytes(), AuthToken::new([2;32]).encode().replacen('A', "B", 1).into_bytes()] {
			fs_perms::write_atomic_owner_only(&path, &corrupt).unwrap();
			let error = load_auth_token(&root).err().expect("corrupt token must fail");
			assert!(!format!("{error:#}").contains("invalid synthetic credential"));
			assert_eq!(std::fs::read(&path).unwrap(), corrupt);
		}
		store_auth_token(&root, &token).unwrap();
		let alias = root.join("alias");
		std::fs::hard_link(&path, &alias).unwrap();
		assert!(load_auth_token(&root).is_err());
		assert!(std::fs::read(&alias).unwrap() == token.encode().as_bytes());
		std::fs::remove_file(alias).unwrap();
		assert!(load_auth_token(&root).unwrap().unwrap() == token);
		std::fs::remove_dir_all(root).unwrap();
	}

	#[cfg(feature = "barkd-web-ui")]
	#[tokio::test]
	async fn duplicate_seed_is_rejected_by_main_and_profile_routes_before_creation() {
		let root = std::env::temp_dir().join(format!("paperclip-duplicate-route-{}-{}", std::process::id(),
			std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
		std::fs::create_dir(&root).unwrap();
		fs_perms::harden(&root, 0o700).unwrap();
		let phrase = bip39::Mnemonic::from_entropy(&[3;16]).unwrap();
		let identities = Arc::new(tokio::sync::Mutex::new(HostWallets::default()));
		identities.lock().await.claim(&root.join("existing"), Identity::new(bitcoin::Network::Regtest, &phrase)).unwrap();
		let shutdown = CancellationToken::new();
		let auth = AuthToken::new([9;32]);
		let builder = wallet_state(root.clone(), Some(auth.clone()), false, shutdown.clone(), identities.clone()).await.unwrap();
		let open: Arc<bark_rest::profiles::OpenProfile> = Arc::new({
			let shutdown = shutdown.clone(); let identities = identities.clone(); let auth = auth.clone();
			move |path| {
				let shutdown = shutdown.clone(); let identities = identities.clone(); let auth = auth.clone();
				Box::pin(async move {
					Ok(wallet_state(path, Some(auth), false, shutdown.clone(), identities).await?.build(shutdown))
				})
			}
		});
		let profiles = Arc::new(bark_rest::profiles::Profiles::open(&root, open).await.unwrap());
		let server = RestServer::start(&Config { port:0, ..Default::default() },
			Arc::new(builder.profiles(profiles).build(shutdown.clone())), shutdown).await.unwrap();
		#[cfg(any(feature = "tls-native-roots", feature = "tls-webpki-roots"))]
		let _ = rustls::crypto::ring::default_provider().install_default();
		let client = reqwest::Client::builder().no_proxy().timeout(std::time::Duration::from_secs(5)).build().unwrap();
		let url = format!("http://{}", server.local_addr());
		let id = "a".repeat(64);
		let registered = client.post(format!("{url}/api/profiles")).bearer_auth(auth.encode())
			.json(&serde_json::json!({"id":id,"label":"Synthetic"})).send().await.unwrap();
		assert_eq!(registered.status(), reqwest::StatusCode::OK);
		for route in ["/api/v1/wallet/create".to_owned(), format!("/api/profiles/{id}/v1/wallet/create")] {
			let response = client.post(format!("{url}{route}")).bearer_auth(auth.encode())
				.json(&serde_json::json!({"network":"regtest","mnemonic":phrase.to_string(),"birthday_height":0}))
				.send().await.unwrap();
			assert_eq!(response.status(), reqwest::StatusCode::BAD_REQUEST);
			let body = response.text().await.unwrap();
			assert!(body.contains("existing profile"));
			assert!(!body.contains(&phrase.to_string()));
		}
		// A completed failure before key persistence may retry; it must preserve
		// the other profile's catalog and must not retain a stale reservation.
		let different = bip39::Mnemonic::from_entropy(&[4;16]).unwrap();
		for _ in 0..2 {
			let response = client.post(format!("{url}/api/v1/wallet/create")).bearer_auth(auth.encode())
				.json(&serde_json::json!({"network":"regtest","mnemonic":different.to_string(),"birthday_height":0}))
				.send().await.unwrap();
			assert_eq!(response.status(), reqwest::StatusCode::INTERNAL_SERVER_ERROR);
			assert!(root.join("hot-wallets/profiles.json").is_file());
		}
		for path in [root.clone(), root.join("hot-wallets").join(id)] {
			assert!(!path.join("mnemonic").exists());
			assert!(!path.join("config.toml").exists());
		}
		server.stop_wait().await.unwrap();
		std::fs::remove_dir_all(root).unwrap();
	}

	#[test]
	fn generated_entropy_keeps_new_wallet_birthday_rules() {
		for generation in [serde_json::Value::Null, serde_json::json!({"method":"system","words":24}),
			serde_json::json!({"method":"dice","words":12,"sides":6,"rolls":vec![1;50],"fair_dice_acknowledged":true})] {
			let request = serde_json::from_value(serde_json::json!({"network":"regtest","seed_generation":generation})).unwrap();
			let opts = wallet_create_request_to_create_opts(request).unwrap();
			assert!(opts.generated_mnemonic);
			assert!(opts.mnemonic.is_some());
			assert!(opts.birthday_height.is_none());
		}
		let phrase = bip39::Mnemonic::from_entropy(&[3;16]).unwrap();
		let request = serde_json::from_value(serde_json::json!({"network":"regtest","mnemonic":phrase.to_string(),"birthday_height":0})).unwrap();
		let restored = wallet_create_request_to_create_opts(request).unwrap();
		assert!(!restored.generated_mnemonic);
		assert!(restored.mnemonic.unwrap() == phrase);
		assert_eq!(restored.birthday_height, Some(0.into()));
	}

	#[test]
	fn launcher_lifetime_is_explicitly_opt_in() {
		let normal = Cli::try_parse_from(["barkd"]).unwrap();
		assert!(!normal.exit_on_stdin_close);
		assert!(!normal.desktop_handoff);
		assert!(Cli::try_parse_from(["barkd", "--desktop-handoff"]).is_err());
		for extra in [vec!["--no-auth"], vec!["--host", "0.0.0.0"]] {
			let mut args = vec!["barkd", "--desktop-handoff", "--exit-on-stdin-close"];
			args.extend(extra);
			assert!(Cli::try_parse_from(args).unwrap().to_config().is_err());
		}
		let managed = Cli::try_parse_from(["barkd", "--exit-on-stdin-close"]).unwrap();
		assert!(managed.exit_on_stdin_close);
	}

	#[tokio::test]
	async fn launcher_cancellation_unblocks_shutdown_listener() {
		let shutdown = CancellationToken::new();
		shutdown.cancel();
		tokio::time::timeout(
			std::time::Duration::from_secs(1), run_shutdown_signal_listener(shutdown),
		).await.expect("launcher closure must not wait for a second signal");
	}

	#[test]
	fn defaults_dont_panic() {
		// assert that mainnet_default_chain_source does not panic
		let _ = ui_default_chain_source();
		// assert that mainnet_default_ark_server does not panic
		let _ = ui_default_ark_server();
	}

	/// `--expose-mnemonic` is a bare presence flag: absent means the mnemonic
	/// endpoint is disabled, present means enabled. This guards both the
	/// disabled-by-default behavior and the flag form; the env-var value form
	/// (`BARKD_EXPOSE_MNEMONIC=true`) is covered by the barkd integration tests.
	#[test]
	fn expose_mnemonic_flag_parsing() {
		let cli = Cli::try_parse_from(["barkd"])
			.expect("bare invocation should parse");
		assert!(!cli.expose_mnemonic, "mnemonic exposure must be off by default");

		let cli = Cli::try_parse_from(["barkd", "--expose-mnemonic"])
			.expect("--expose-mnemonic should parse");
		assert!(cli.expose_mnemonic, "--expose-mnemonic must enable exposure");
	}

	#[test]
	fn to_config_supports_os_assigned_and_fixed_ports() {
		let cli = Cli::try_parse_from(["barkd", "--port", "0"])
			.expect("--port 0 should parse");
		assert_eq!(cli.to_config().unwrap().port, 0);

		let cli = Cli::try_parse_from(["barkd", "--port", "3001"])
			.expect("--port 3001 should parse");
		assert_eq!(cli.to_config().unwrap().port, 3001);
	}

	/// Both flags are bare presence flags with no env-var form; that auth can't
	/// be disabled through the environment is covered by the barkd integration
	/// tests.
	#[test]
	fn no_auth_flag_parsing() {
		let cli = Cli::try_parse_from(["barkd"])
			.expect("bare invocation should parse");
		assert!(!cli.auth_disabled(), "auth must be required by default");
		assert!(!cli.dangerously_allow_remote_no_auth, "remote must be off by default");

		let cli = Cli::try_parse_from(["barkd", "--no-auth"])
			.expect("--no-auth should parse");
		assert!(cli.auth_disabled(), "--no-auth must disable auth");
		assert!(!cli.dangerously_allow_remote_no_auth, "--no-auth must not permit remote binds");

		// The dangerous flag stands on its own: it disables auth too.
		let cli = Cli::try_parse_from(["barkd", "--dangerously-allow-remote-no-auth"])
			.expect("--dangerously-allow-remote-no-auth should parse");
		assert!(cli.auth_disabled(), "the dangerous flag must disable auth on its own");
		assert!(cli.dangerously_allow_remote_no_auth, "the dangerous flag must permit remote binds");
	}

	#[test]
	fn remote_no_auth_needs_dangerous_flag() {
		let addr = |s: &str| s.parse::<IpAddr>().unwrap();

		check_remote_no_auth(addr("127.0.0.1"), false).expect("IPv4 loopback");
		check_remote_no_auth(addr("::1"), false).expect("IPv6 loopback");

		for host in ["0.0.0.0", "192.168.1.10", "::"] {
			check_remote_no_auth(addr(host), false)
				.expect_err(&format!("{host} is reachable from other hosts"));
			check_remote_no_auth(addr(host), true)
				.unwrap_or_else(|e| panic!("{host} should be allowed by the flag: {e:#}"));
		}
	}
}
