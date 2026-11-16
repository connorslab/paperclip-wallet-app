# Paperclip Wallet on Umbrel and StartOS

Paperclip Wallet supports Linux x86-64 and ARM64. Install the published package
for your platform and back up your complete wallet before updating.

## Sign in

- **Umbrel:** use the app password displayed for Paperclip Wallet in Umbrel.
- **StartOS:** open Paperclip Wallet → Actions → Show wallet access token,
  then paste that token into the wallet.

These credentials grant wallet access. Do not enter your platform account password
or recovery phrase. Existing credentials are preserved during an update.

## Connect your node

New wallets default to `https://ark.paperclip-xbt.xyz`. Custom server settings are
preserved. Choose an XBT/Blake2b-compatible node; a Bitcoin SHA-256 node cannot be
used for this wallet.

On StartOS, the **Node connection** action can reuse the installed Knots Blake2b
companion's RPC connection and cookie. On Umbrel, **Use installed XBT node** uses
the connection exported by a compatible installed node app. If your app does not
provide that connection, select manual RPC setup. Provider compatibility depends
on the node package; not every community-store combination has been tested.

Use a synchronized transaction index, or configure the bundled private pruned-node
adapter as described in `BUNDLED-PRUNED.md`. Keep RPC on the private service network
or an authenticated encrypted connection. Do not expose RPC or wallet ports to the
public Internet.

## Sync and payment status

You can sign in while your node is syncing or unavailable. Unavailable balances
are labeled rather than shown as zero. Open **Settings → Check connections** for
connection information. A snapshot node may reach the current block while its
historical validation and transaction index are still catching up.

Result screens distinguish completed, failed, pending, and unknown payments.
On-chain submission still needs confirmations. After an interrupted payment,
check Activity and payment status before trying again; the wallet does not resend
a payment automatically.

Lightning uses the connected ASP's service. You do not need to install a local
Lightning node. Available features depend on the ASP's advertised capabilities.

## Keep the wallet online

Automatic VTXO maintenance runs while the wallet service is online, even after
you close the browser. Keep the blockchain backend and ASP reachable and allow
for refresh fees. Stopping the service stops maintenance and BOLT12 offer handling.
Existing manually configured wallets retain their maintenance settings.

## Backup and recovery

Back up the complete app data volume, including the mnemonic, database,
configuration, authentication token, and optional adapter data. Stop the wallet
before a manual file backup. Seed-only recovery does not preserve all Ark state.
Restore to a stopped service and preserve ownership (wallet uid/gid 1000).
Never run two wallet instances from the same backup.

The wallet generates its own keys; the Umbrel seed is not used as a wallet seed.
An authentication mismatch after restoration stops startup rather than silently
replacing the token. Do not downgrade a wallet with state newer binaries created.

## Coordinated release

The next major release targets iOS, Android (Google Play and signed APK), Umbrel,
StartOS, and signed Linux, macOS and Windows desktop packages together. The
desktop packages use the same frontend and wallet backend as the host packages,
including bundled Jam and mobile pairing. Native installation, signing,
data-preserving upgrades and recovery are required release gates; desktop
packages are not available yet. See [the release acceptance matrix](COORDINATED-RELEASE.md)
for the shared source freeze, remaining feature gaps and publication sequence.

## Package development

### Create and back up a Jars wallet

With bundled JoinBlaket enabled in the host settings, open **Jars → Create a
Jars wallet**. Choose a name and a separate Jam password of at least 12 characters,
review creation, then back up the recovery words. No funds move during setup.
Paperclip verifies the Jam password again before displaying the words. Write them
down privately and confirm the requested words; do not use a mobile or QR signer
seed. These Jars have their own keys.

If creation is interrupted, use **Check creation status** or find and unlock the
same named wallet. A retry requires a fresh review with the same filename; the
daemon refuses to overwrite an existing wallet. The browser keeps only the pending
filename in session storage. This reminder is not a server backup or a durable
cross-browser setup record. **Back up Jars wallet** remains available after unlock.

Recovery words require owner authentication and a fresh Jam password check. They
are cleared when their dialog closes, the page changes, the tab is hidden or the
wallet locks. Phone pairings cannot create wallets or view recovery words. Also
back up the complete host volumes: recovery words alone do not preserve all
wallet history, payment recovery records, pairing records or configuration.

### JoinBlaket connection in the next candidate

The new CoinJoin screen connects to a separate Kilombino JoinBlaket/Jam wallet.
Its five jars are the server's mixdepths, with confirmed, pending, frozen and
fidelity-bond funds shown separately. Paperclip does not import its seed into Jam
or rename an existing Kilojoin account. Existing Kilojoin recovery stays available.

Use the XBT service described in [Kilombino's guide](https://kilombino.com/joinblaket/),
currently JoinBlaket `0.43.0-xbt7` with Jam `v2.0.0-beta.4-xbt7`. The directory on
Tor matches makers with takers; it is not a wallet API or a place to send funds.
The integration needs the URL of your actual Jam service. Its `getinfo` version
alone does not prove that a deployment is the XBT fork; verify the package/image
and its node preflight before funding it.

For a custom deployment of this candidate, configure the wallet daemon with:

- `BARKD_JOINBLAKET_URL`: the Jam HTTPS origin, optionally with a base path.
- `BARKD_JOINBLAKET_CA_FILE`: optional PEM CA file mounted read-only for a private
  HTTPS service. Certificate and hostname validation remain enabled.
- `BARKD_JOINBLAKET_TOR_PROXY`: optional `socks5h://host:port`; required for onions.

Do not put credentials in the URL. Paperclip's normal API authentication is
required. The browser unlocks Jam with its separate password and optional BIP39
passphrase; its bearer token stays in memory and clears on locking Paperclip.
The bridge only contacts the administrator-configured upstream. Address
generation and maker actions are never automatically replayed, including Jam's
state-changing GET endpoints. After an uncertain maker action, refresh status
before another action. The maker continues on the Jam server when Paperclip closes.

This candidate has not been published in the platform stores. Platform-specific
service selection, live Jam verification, guided bond funding and taker/mixing
flows remain unfinished; the presence of the jars screen does not establish full
CoinJoin parity. No production maker has been started for these UI tests.

### Release validation

Build images from the reviewed source using `deployment/Dockerfile`, test both
architectures, then pin the multi-architecture digest. `deployment/package.py umbrel` generates Umbrel packaging. StartOS 0.4 packaging is maintained in
[paperclip-wallet-startos](https://github.com/connorslab/paperclip-wallet-startos).
The generator's `startos` mode is a legacy 0.3.5 wrapper, not a 0.4 release.

Build and unit-test results do not establish device installation, complete backup
restoration, or successful financial settlement. Release notes describe the
checks actually completed. This is beta software and has not been independently
audited.


## Pairing mobile Jars with a Paperclip host

The candidate's Jars page has **Pair a phone** after unlocking the separate Jam
wallet. Enter the Paperclip host's HTTPS or onion address and a verified certificate
fingerprint if its HTTPS certificate is not otherwise trusted. The private QR
grants balances, receive addresses, maker controls and payment-status access to
that Jam wallet for up to 30 days. It does not grant the main wallet, key export,
unlock, payments or delegation management. Scan it from mobile Jars, review the
server/wallet/scope, then verify and save. Never send pairing codes to support.

The host can revoke individual devices. A Jam lock/restart invalidates its
memory-only delegation; unlock Jam on the host and create a new phone pairing.
Forgetting the connection on a phone removes only its local encrypted copy;
revoke on the host to invalidate any other copy. The host's `jam-pairings`
directory is private and included in the main-volume backup, but restoring it
does not restore a restarted Jam daemon's delegation. Installed-host and full
restore tests remain required. The current candidate's paired send/bond-funding
flows are not complete and must not be advertised as release-ready.
