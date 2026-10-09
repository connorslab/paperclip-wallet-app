# Paperclip iOS wallet

Development branch: `feature/ios-wallet`.

The native SwiftUI app uses the Paperclip web colors (`#111c2e` navy and `#f56835`
orange), reduced-motion preferences, and Liquid Glass actions on iOS 26. Earlier
versions use system material. It contains an on-chain and Ark wallet, a remote
Lightning node client, transaction review, QR receive screens, activity, recovery,
and encrypted iCloud Drive export/import.

## Navigation and preferences

Wallet opens on-chain and Ark balance pages with focused payment and receive flows.
Lightning shows node capacity, with separate pages for pay, receive, connection settings,
and payment reconciliation. Ark boarding, seed recovery, and emergency exits are separate
pages; exit status explains whether exits are registered, waiting, or claimable.
Settings groups display preferences, connections, security, backups, and wallet tools.

Settings → Appearance & units selects System, Light, or Dark and sats or XBT. Amount
entry, balances, fee reviews, and activity use the selected unit. XBT conversion uses
integer sats, accepts at most eight decimal places, and never rounds a payment.
Changing units converts existing amount fields and invalidates pending reviews.

Send and node payment pages support camera QR scanning. Bitcoin URI amounts are decoded
without floating-point conversion; unsupported required URI parameters are rejected.
Scanning only fills the payment form. Native validation, review, and confirmation remain
required. Camera permission is requested only when opening the scanner.

Settings → Sign a message creates an offline BIP322-simple Taproot ownership proof for
an address owned by the on-chain wallet. Device authentication is required. Messages
retain exact UTF-8 bytes (up to 4096 bytes); the generated proof is verified before being
returned. This proof format does not change unified sighash for XBT transactions.

Ark withdrawal estimates validate recovery funding with the funded split builder before
allowing a review. A failed preflight is distinguished from a submitted or uncertain
payment; uncertain outcomes are never automatically retried.

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

## Multiple wallets and QR hardware signing

Open Settings → Your wallets to switch, rename,
or add a wallet. Existing installations migrate their catalog without moving the old
Keychain entry or database. Each new wallet gets a separate database, key/identity entry,
and on-chain/Ark connection settings. A switch closes the previous session and discards
unsubmitted signing requests. A wallet cannot switch while a native operation is active.
Only the selected mobile wallet receives Ark maintenance; open each mobile wallet regularly.
Remote Lightning node settings remain app-wide and are labeled accordingly.

Hardware and watch-only wallets import account-level XPUB/YPUB/ZPUB (or testnet variants),
`[fingerprint/path]` key expressions, or single-key public descriptors. Receive `/0/*`
and change `/1/*` are separate. Hardware imports require the master fingerprint and full
account path. Supported scripts are BIP44 P2PKH, BIP49 P2SH-P2WPKH, BIP84 P2WPKH, and
BIP86 key-path Taproot. Multisig and Taproot script trees are not supported. Watch-only
wallets cannot initiate payments, local signing, or Ark operations. Public descriptors
can be shared from Settings for monitoring backups; hardware seeds stay on the signer.
Compare the first receive address with the signer before funding an imported account.

Hardware payment flow: review recipient/amount/fee → show animated BBQr → approve and
sign on the hardware wallet → scan its response → verify → confirm broadcast. Every input
explicitly requests unified SIGHASH_ALL (`0x21`). The native engine verifies every returned
signature against trusted original prevouts and the exact reviewed transaction. Changed
outputs, amounts, fees, input order, sequences, locktime, or a BTC sighash are rejected.
Requests expire after 30 minutes. A broadcast attempt saves the exact transaction before
relay; an uncertain reply is not treated as permission to send a replacement payment.

### Ark transfers with a QR wallet

Select a mobile wallet in Settings → Your wallets, then open Ark → Add XBT from
on-chain → Board from a QR wallet. Choose a saved BIP84 or BIP86 hardware account,
review the deposit/network fee/recovery deduction, scan the request on Krux or SeedSigner,
scan the signed result back, and confirm boarding. The funding wallet keeps its own chain
connection and Tor settings. The Ark wallet retains its own server/backend and keys.
Funding is never sent through the ordinary on-chain broadcast path: the existing Ark
board action saves the cosigned recovery VTXO and funding PSBT before broadcast. A crash
or failed initial relay is resumed by the mobile Ark wallet's normal synchronization.

Ark requires an unchanged funding txid, so direct hardware boarding supports native
SegWit and Taproot only. Legacy and nested SegWit remain supported for ordinary hardware
payments and as offboarding destinations. QR requests expire after 30 minutes; current
boarding fees, funded relay policy, and unspent inputs are checked before submission.
Leaving the boarding page cancels its unfinished request. Switching wallets or reconnecting
also invalidates it. Save an updated encrypted backup of the mobile wallet after boarding.

In Pay from Ark, choose Withdraw to a saved QR wallet to derive and save a fresh address
in that hardware wallet's database. Verify it on the signer, enter the amount, review the
fees, and confirm. Receiving an offboard does not require a hardware signature. Watch-only
wallets are excluded from this shortcut; ordinary address entry remains available.

Ark keys remain on the iPhone: QR signers sign the funding transaction, not Ark's
interactive off-chain operations. Keep on-chain funds in the mobile wallet for unilateral
recovery fees. The hardware wallet's seed alone cannot recover this mobile Ark balance.

Compatibility checked against:

- `privkeyio/seedsigner` at `e135132033412901a957ddf5e6fea4883186a36b`, with its pinned
  `privkeyio/embit` at `5f700aa3222da65c27331df50b9a899236cb5461`. Choose **Specter** for
  public-key export, then **Scan** for signing. SeedSigner accepts BBQr requests and always
  returns signed PSBTs as `ur:crypto-psbt`; the app decodes that animated fountain format.
  `crypto-account` public-key UR import is not supported; use the Specter export instead.
- `connorslab/krux-blake2b` at `820367495ef72a4544557c9f0b47a92984fb6fe1`, with embit
  `087d020fbfb66fc2e0eab88fb948269e1da28e95`. Export a plain public-key expression or descriptor,
  choose **Sign PSBT**, and return BBQr or UR. Legacy requests include the complete previous
  transaction without a witness-only hint, as required by Krux's policy.
- Shrike's reviewed implementation at `45a3943307cb0d1dda2e94a4e1c049af3621dcca` provides
  the reference review/export/import flow. This does not claim device-to-device testing.

QR imports accept BBQr `H`, `2`, and raw-deflate `Z`, animated UR PSBTs, base64/hex,
and `pNofM` responses. Transfers, fountain metadata, and decompression are bounded.
`Tests/PaperclipMobileTests/Fixtures` contains only public BIP39 test-key data; never fund
those keys. `integration/hardware-fixtures.py` regenerates SeedSigner signature/UR fixtures
using its actual parser, signing policy, trimming, and QR encoder. Rust tests verify both
SeedSigner and Krux signatures for all four scripts, and Swift tests decode SeedSigner's
UR output. Optical scanning on physical hardware still requires a device round trip.

Do not leave Xcode Device Hub open during camera testing: its remote interaction can
make physical camera capture unavailable. Test the scanner directly on the iPhone.

## Connections

- Default: `ssl://pool.paperclip-xbt.xyz:50002` (operator is preparing this endpoint).
- Custom Electrum TLS/TCP, Esplora HTTP(S), and authenticated XBT Knots RPC.
- Ark default: `https://ark.paperclip-xbt.xyz`.
- Core Lightning CLNRest with a rune, or LND REST with a hex macaroon.

Electrum verifies the genesis network and an activated 164-byte XBT header before
use. The vendored Electrum client decodes variable-length headers, including mixed
pre-activation and post-activation batches. TLS uses public trust roots unless the
user supplies an exact SHA256 certificate pin. Pins must come from the operator
through a trusted channel. A changed certificate fails closed. Esplora also checks
network and extended headers, but still needs a compatible public deployment test.

Tor routing defaults to the built-in iCepa Tor 0.4.9.13 runtime. The native iOS
app starts one client with loopback-only, dynamically assigned SOCKS and cookie-authenticated
control ports, and waits for a circuit before using it. Keep the app open while
connecting; iOS can suspend Tor in the background. Startup times out without a direct
fallback. Each connection can instead use an external `socks5h://host:port` proxy.
Onion node URLs belong in the node endpoint field, not the external proxy field.
Electrum sends the destination hostname through SOCKS. CLN/LND use the OS SOCKS configuration with direct failover disabled. Ark uses
the engine's SOCKS transport. On-chain and separate Ark RPC each have their own
Tor switch and built-in/external proxy selection. The separate Ark route also applies to its
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
for on-chain payments. RPC credentials are stored in Keychain. Both RPC routes support
built-in Tor and external proxies independently.

Tap the on-chain balance to view confirmed, unconfirmed, and immature balances plus
on-chain transactions. This view opens saved wallet state offline; Refresh synchronizes
only the on-chain wallet. Receive/change address previews do not advance derivation.

The Tor runtime package pins the upstream binary checksum and vendors its MIT-licensed
Objective-C wrapper. The iOS build flattens the upstream versioned framework layout
and signs the copied framework. Debug builds support `-tor-probe`, which starts Tor
without opening a wallet and verifies a proxied request with Tor Project's check service;
only the pass/fail result is written to `Documents/tor-probe.txt`.

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

## Lightning node dashboard

The Lightning tab shows active-channel send and receive estimates. CLN uses
`listpeerchannels` spendable/receivable amounts; LND uses active `listchannels`
balances minus reserves. Routing, HTLC limits and fees can reduce usable amounts.
Missing or denied channel data is shown as unavailable rather than a zero balance.

CLN nodes can create reusable BOLT12 offers with `offer`; leave the amount blank
for an amount chosen by the payer. The node retains and serves the offer. The rune
needs `listpeerchannels` and `offer` permissions in addition to existing methods.
LND offer creation is not implemented through its standard REST API.

Ark tools opens BOLT11-to-Ark receive and Ark offboarding with the correct source
selected. Pending receives expose their state and a manual claim retry. An all-failed
claim batch now retains the underlying error, and that warning does not suppress
otherwise successful balance synchronization. Claim errors still need investigation;
this UI change does not prove that a pending payment settled.

### Connection recovery and balance updates

Electrum probes its socket before each operation and rebuilds closed connections
with the same Tor routing, TLS verification, and XBT header checks. A failed
operation is not replayed; the next request receives a fresh connection. The iOS
bridge also invalidates its connection after a broken-pipe failure.

The homepage reads cached Ark balances every five seconds while displayed, so
foreground receive claims appear without a manual network sync. Manual refresh
updates on-chain and Ark independently and retains prior balances on failure.
Cached balance reads do not claim to establish fresh chain or server status.

### Ark payment screens

Tap the Ark balance to view available/pending funds, Ark activity, and payment,
receive, boarding, and recovery entry points. Payment review uses the native
request parser's fixed invoice amount; BOLT11 amount entry appears only when the
validated request has no amount. The confirmation uses the reviewed amount and
retains the engine's quote expiry and fee-change checks.

Boarding review separates the network fee added to the debit from the combined
boarding/recovery deduction. The app currently uses the regular backend fee
estimate, without a custom boarding fee-rate control. Small boards may incur a
large relative cost; the net Ark amount is shown before confirmation.

## BOLT12 payments from a Lightning node

Lightning → Pay offers an Invoice / BOLT12 offer selector for Core Lightning.
The client uses [`fetchinvoice`](https://docs.corelightning.org/reference/fetchinvoice)
to obtain a single-payment invoice, checks its decoded amount and expiry, and shows
its description for review. Fixed amounts come from the offer; an amountless offer
requires user input. The app rechecks the invoice before saving a pending attempt,
then uses CLN [`pay`](https://docs.corelightning.org/reference/pay) with a maximum
routing fee. Only the fetched invoice is paid; the offer is never automatically
resolved again during submission or reconciliation. Existing Tor routing applies.
The node credential needs `decode`, `fetchinvoice`, `pay`, and `listpays` permission.
LND offer payments and currency-priced, quantity, and recurring offers are not
supported in this app. The UI reports these limitations before payment.

Boarding review also exposes the deposit, network fee, actual funded anchor,
reserved recovery miner fee, and server boarding-fee threshold. The deduction is
`max(server boarding fee, minimum recovery anchor) + recovery miner fee`, not the
sum of all three. The screen explains that recovery funding is not spendable Ark
balance, not entirely operator revenue, and not a guaranteed refund. It shows the
total on-chain debit and spendable Ark separately, including the percentage consumed
by network fees and reserved funding. Later transfers can require additional funds.

The app checks the configured on-chain backend every 30 seconds while the wallet
screen is active. The network dot turns green only after a successful live read;
failures or a result older than 75 seconds return it to neutral. Cached Ark balances
do not establish on-chain connectivity.

Lightning payment reconciliation runs app-wide every ten seconds while foregrounded,
resumes saved attempts after restart, and checks immediately after submission. It
never calls `pay` or resolves an offer again. Pending, missing, malformed, or failed
network responses retain the durable attempt. A terminal node result clears it and
refreshes the displayed capacity. CLN queries the exact payment hash; LND includes
incomplete payments and scans up to twenty backwards pages of 100 payments. Older
missing records remain uncertain and require node inspection. Background suspension
pauses checking until Paperclip becomes active again.

### Mobile on-chain address accounts

Open On-chain and select Taproot or SegWit. Both use the same seed, with separate
balances and transaction histories. Selection is saved inside the wallet database
and its encrypted backup. Switching does not move coins and invalidates pending
on-chain payment and boarding quotes. Send, receive, and Ark boarding use the selected
account. Ark's off-chain balance remains shared. Message signing currently supports
Taproot addresses only.

Mainnet paths are `m/86h/0h/0h` for the existing Taproot account and `m/84h/0h/0h`
for main SegWit, with SegWit receive/change branches 0 and 1. New Coinjoin accounts
use `m/84h/0h/1h`. A first SegWit refresh scans that account's history. After a
seed-only import, refresh each address account and scan Coinjoin separately.

Older Coinjoin installations used SegWit account 0. Until upgraded, they remain
accessible from Coinjoin and the main SegWit selector refuses to open that same
account. The explicit Coinjoin upgrade requires all reservations and pending
transfers to be resolved. It atomically moves account-0 bookkeeping to main SegWit
without spending coins, archives round state and labels in the same backup, and
starts new Coinjoin activity in account 1. Archived rounds remain visible in
Coinjoin history. Save an updated encrypted backup after upgrading. Old mixed coins
are now in main SegWit; combining them with other funds can link their histories.

### Experimental Coinjoin

Settings → Wallet tools → Coinjoin opens the separate BIP84 account. The homepage
has no Coinjoin balance, card, or entry. All pool controls, account history, coin labels,
and single-coin transfers stay on the Coinjoin page. The account uses the selected mobile
wallet's seed and chain connection. Hardware and watch-only profiles cannot join pools.

The protocol core is the public [paperclip-kilojoin-rs](https://github.com/connorslab/paperclip-kilojoin-rs)
crate, pinned to an immutable commit in Cargo.toml/Cargo.lock. Paperclip contributions are
MIT licensed. The adapted Kilombino code and fixtures retain Apache-2.0 notices.

The relay defaults to `wss://relay.kilombino.com`; a custom secure WebSocket URL is allowed.
Tor is on by default. Output posts use a separate ephemeral URLSession and separate
SOCKS-auth credentials. The embedded Tor listener enables IsolateSOCKSAuth. Tor does not
remove timing correlation or guarantee anonymity. Discovery uses only indexed `#t` tags;
the client validates the signed announcement's network, version, identity, and limits.
No signatures, pool announcements, or other events are published merely to browse pools.

Receive into the displayed address, then refresh to select a coin. Creating a pool supports
a denomination of 10,000–100,000,000 sats, fee rate 1–500 sat/vB, 2–20 participants,
1–168-hour open duration, and optional password protection. Joining reserves one input.
A separate review is required before its transaction signature can leave the device.
The page must remain open during a round; return and reconnect to replay saved state.

Coinjoin account changes, rounds, outbox events, reservations, and coin labels are in the
same SQLite database as the mobile wallet, so a full encrypted backup includes them.
The seed recovers the BIP84 account through Scan account from seed, but cannot recover
privacy labels or an in-progress round's complete state. Unlabelled coins are shown as
unclassified. Exact-coin preparation requires confirmation that the source is unmixed;
known mixed outputs are rejected for that operation.

Exact preparation, withdrawal, and boarding manually select one input and reject any
transaction with additional inputs. Withdrawals drain that coin after the network fee.
A mixed output can be boarded separately into the selected mobile Ark wallet; the review
shows its network fee, recovery deduction, and net Ark amount. Ark recovery is persisted
before funding broadcast. Direct Ark outputs inside Kilojoin v1 are not supported.

A signed round is never unlocked just because it is aborted or times out. Reconciliation
needs confirmation of the expected transaction or evidence of a conflicting confirmed
spend. Relay transaction claims are not confirmation evidence. The saved transaction and
outbox are retried without creating a replacement payment. There is no automatic remix.

Validation covers the upstream production vectors in the standalone library, simulated
round replay/restart/vote/sign/timeout behavior, the named-account backup round trip,
single-coin selection and unified signing, and read-only live relay discovery. This does
not constitute a live funded Paperclip ↔ Kilowallet/StartOS round or an independent audit.
