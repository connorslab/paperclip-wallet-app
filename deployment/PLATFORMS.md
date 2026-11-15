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

## Package development

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
