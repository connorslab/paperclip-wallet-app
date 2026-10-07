# Paperclip iOS wallet

Development branch: `feature/ios-wallet`.

The native SwiftUI app uses the Paperclip web colors (`#111c2e` navy and `#f56835`
orange), reduced-motion preferences, and Liquid Glass actions on iOS 26. Earlier
versions use system material. It contains an on-chain and Ark wallet, a remote
Lightning node client, transaction review, QR receive screens, activity, recovery,
and encrypted iCloud Drive export/import.

## Setup and storage

New wallets generate 24 BIP39 words with the Rust engine's secure random generator.
Setup hides the words and requires entry of all 24 words before creation. Import
accepts 12 or 24 words and validates the BIP39 checksum. BIP39 passphrases are not
supported. Seed import requires a recovery scan after connection. It cannot replace
an existing wallet.

The seed, optional seed phrase, and connection credentials use device-only Keychain
storage with `AfterFirstUnlockThisDeviceOnly`. This permits background Ark work after
the device's first unlock. The foreground app requires device authentication by
default. The app covers its contents when inactive and clears setup words on
background entry. Database directories use protected storage and are excluded from
normal device backups.

Encrypted backup files use AES-256-GCM with a separate random 256-bit recovery key.
They contain the seed, seed phrase when available, and a consistent SQLite snapshot
of the complete Ark state, including pending actions. Export requires re-entry of
the recovery key. Save the file to iCloud Drive through Files and keep the key
separate. Files manages upload; successful export does not prove upload completion.
Old version-one archives without a seed phrase remain readable. Restore validates
key/network association in a staging directory and refuses existing wallet data.
Remote Lightning nodes need their own channel backups; they are not part of an Ark
backup. A backup does not prevent Ark expiry.

## Connections

- Default: `ssl://pool.paperclippool.xyz:50002` (operator is preparing this endpoint).
- Custom Electrum TLS/TCP, Esplora HTTP(S), and authenticated XBT Knots RPC.
- Ark default: `https://ark.paperclippool.xyz`.
- Core Lightning CLNRest with a rune, or LND REST with a hex macaroon.

Electrum verifies the genesis network and an activated 164-byte XBT header before
use. The vendored Electrum client decodes variable-length headers, including mixed
pre-activation and post-activation batches. TLS uses public trust roots unless the
user supplies an exact SHA256 certificate pin. Pins must come from the operator
through a trusted channel. A changed certificate fails closed. Esplora also checks
network and extended headers, but still needs a compatible public deployment test.

Tor routing requires a reachable SOCKS proxy configured as `socks5h://host:port`.
The app does not embed a Tor daemon. Electrum sends the destination hostname through
SOCKS. CLN/LND use the OS SOCKS configuration with direct failover disabled. Ark uses
the engine's SOCKS transport. On-chain and separate Ark RPC each have their own
Tor switch and SOCKS proxy address. The separate Ark route also applies to its
Ark server connection. Both synchronous chain scanning and asynchronous RPC use
the selected proxy, including remote DNS; RPC proxy failures and redirects never
fall back to a direct connection. RPC preserves the proxy even for loopback target
addresses. The engine's other backends retain their loopback proxy bypass.
On-chain and separate Ark RPC accept explicit HTTP endpoints for local nodes and
testing, as well as HTTPS. HTTP sends RPC credentials without encryption, so use
it only on a trusted network. On an iPhone, use the node's LAN address; localhost
refers to the phone itself. RPC uses HTTP(S) transports for async operations and
synchronous chain scans, with redirects disabled. The upstream async client requires a username and
password; configure restricted gateway credentials rather than node admin access.

Ark can use an Electrum server with package-relay support. Before admitting new
funded positions, the wallet requires `server.features.broadcast_package = true`
and `mempool.get_info` to include `minrelaytxfee`, `mempoolminfee`, and
`dustrelayfee`. Missing fields or excessive fees fail closed. Exit packages use
`blockchain.transaction.broadcast_package`; ancestry fees are reconstructed from
hash-checked transactions and their prevouts. There is no general RPC passthrough.
See [the Electrum Ark contract](electrum-ark.md) for the operator requirements.

No public RPC endpoint is configured. Users can select their own Knots RPC for
on-chain and Ark, or enable a separate Ark RPC backend while retaining Electrum
for on-chain payments. RPC credentials are stored in Keychain. Separate RPC with
Tor is currently rejected rather than bypassing Tor.

## Payments and recovery

On-chain payments and Ark funding use the existing unified signer (`0x21`). There is
no legacy SHA256 BTC signing fallback. A regression test verifies that signatures
validate under the unified digest and fail under the BTC BIP341 digest.

On-chain, Ark, and board payments require a fresh review. Quotes expire after 60
seconds and are consumed once. Board review includes the funding transaction fee
and the funded profile's recovery reserves. Native operations use the engine's
persistent checkpoints. Lightning node attempts are recorded in Keychain before
submission; another attempt is blocked until node history gives a terminal result.
A timeout is not proof of failure.

Ark tools expose BOLT11 invoices, reusable BOLT12 offers, receive status and claims,
offboarding, seed/mailbox recovery,
emergency-exit registration, progress, status, and claims. The app serves BOLT12 invoice requests while in the foreground and processes
persistent BOLT11/BOLT12 claims. Background entry stops the listener; iOS does not
guarantee always-on receipt. Disabling an offer preserves already issued invoices.
Chain-only recovery does
not require the Ark server to be online. Emergency exits require fee liquidity,
confirmations, and timelocks. Background execution is opportunistic; open the app
regularly. Expiry reminders never include balances, addresses, or VTXO IDs.

## Build and verification

- Install Rust 1.90, protobuf, CMake, XcodeGen, and full Xcode.
- `cd mobile && swift test` tests policies, endpoint validation, and encrypted backups.
- `just unit-mobile` tests the C ABI's persistence, seed derivation, and recovery.
- `just unit-unified` tests unified sighash reference vectors and signer behavior.
- `just checks` checks workspace targets.
- Generate the app with `cd mobile/iOS && xcodegen generate`.
- Build the native library for `aarch64-apple-ios-sim` before the simulator app.
- The `iOS proof of concept` GitHub workflow builds device and simulator libraries,
  runs tests, builds the app, and captures a simulator screenshot.

Full Xcode is needed for XCTest and simulator execution. The command-line Swift
installation can compile the shared library but does not include XCTest here.
A device release still needs Apple signing/provisioning, physical-device Tor/iCloud
and background tests, and funded integration tests against the deployed XBT services.
The simulator artifact is not a signed device IPA or a TestFlight release.

## Test on your iPhone

Install full Xcode and its iOS platform support, then select it in Xcode Settings
under Locations > Command Line Tools. The standalone Command Line Tools package
cannot build or install an iPhone app.

From this repository's root:

```sh
rustup target add --toolchain 1.90.0 aarch64-apple-ios
cargo +1.90.0 build --locked -p paperclip-mobile --target aarch64-apple-ios
(cd mobile/iOS && xcodegen generate)
```

Open `mobile/iOS/Paperclip.xcodeproj` in Xcode. Add your Apple Account under Xcode
Settings > Apple Accounts. In the Paperclip target's Signing & Capabilities tab,
enable automatic signing and choose your team. If Xcode reports a bundle ID
conflict, use a unique bundle identifier for your personal test build. Connect
and trust your iPhone, enable Developer Mode when prompted, select the phone as
the run destination, and run the Paperclip scheme.

A personal Apple Account supports direct device testing. TestFlight distribution
requires Apple Developer Program membership and an App Store Connect app record.
CI simulator artifacts cannot be installed on a physical iPhone. Unsigned device
artifacts also require your development signing and provisioning before install.

Apple's instructions:
https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices
