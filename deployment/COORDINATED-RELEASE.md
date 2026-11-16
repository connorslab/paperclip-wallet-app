# Coordinated Paperclip release

The next major release includes iOS, Android, Umbrel and StartOS from one reviewed
source revision. Android distribution includes **Google Play and a signed APK
download**. Prepare candidates independently, then publish in one coordinated
release window after every platform meets the acceptance criteria below. Store
review and propagation can finish at different times; do not promise simultaneous
availability to the minute.

The release version and date are not assigned yet. The current version numbers
(Apple build 70, Android preview code 4, server 0.10.0) identify existing candidates,
not a completed unified release. Do not reuse an uploaded build number, rewrite an
existing release tag, or replace a published binary in place.

## Source and artifacts

- Freeze one source commit in `connorslab/paperclip-wallet-app`. Record the commit,
  dependency lockfiles, native toolchain versions and CI runs for every artifact.
- Build the Apple archive with the native Apple toolchain and existing signing
  identity. Preserve the production bundle ID, Keychain groups and wallet data.
- Build the Android App Bundle for Play and APK download from the same commit,
  version name, version code, resources and native libraries. Verify ARM64 and
  x86-64 packaging, release-only behavior and supported page sizes.
- Confirm the Android application ID and signing certificate against the installed
  app and Play Console before selecting the release identity. The current preview
  uses `xyz.paperclip.wallet.android.preview` and development signing. An app signed
  with a different certificate cannot update it in place. Do not uninstall a
  funded preview to work around a signing mismatch; validate full backup/restore
  and an explicit migration first.
- The Play upload key and installed-app signing key may differ. Sign a direct APK
  with the installed-app key, not merely the AAB upload key. If Google holds the
  app signing key, obtain the distributable signed APK from Play Console. Verify
  the certificate on both channels before claiming cross-channel updates work.
- Build and test Linux AMD64 and ARM64 images. Both platform wrappers must pin the
  same reviewed multi-architecture image digest. Record wrapper commits separately.
  StartOS 0.4 uses `paperclip-wallet-startos`, not the legacy 0.3.5 generator here.
- Publish checksums, immutable image digests and the existing Paperclip release
  signature described in `RELEASE-SIGNING.md`. Native signatures remain required.

Google documents the distinction between upload and app-signing keys in
[Sign your app](https://developer.android.com/studio/publish/app-signing) and the
Play-signed download option in its
[App Bundle FAQ](https://developer.android.com/guide/app-bundle/faq).

## Latest verification: 2026-11-16

- Android CI [43864731284](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43864731284)
  at `76abe02` passed both native architectures and API 35/36 emulator jobs,
  including the selection-metadata and profile-removal regressions. The preceding
  `4882d13` and `768a98e` runs also passed. The earlier intermittent system ANR did not
  recur; its cause remains unconfirmed.
- iOS CI [43859699438](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43859699438)
  at `2c75741` passed Swift/native tests, device and simulator builds, bundle checks
  and UI tests, including the wallet-switch regression.
- Android CI [43872328985](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43872328985)
  at `40a855a` passed both native architectures and the complete API 36 job. The
  corrected storage fixture also passed API 35. That job later failed onboarding
  because a system ANR dialog covered the app. The dialog did not match the app
  label, the app had no recorded process exit, and its main thread was idle. The
  affected system component and root cause remain unknown. Bounded diagnostics
  now classify known system component labels without printing dialog contents.
  Assertions and timeouts are unchanged.
- Android CI [43873204870](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43873204870)
  at `046dcf7` passed native builds and API 36 storage/profile tests, then hit the
  same system ANR obstruction at the first onboarding capture. The complete API 35
  job passed. This API 36 recurrence remains unresolved. These checks do not
  close live, physical-device or distribution gates.
- Android CI [43878107381](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43878107381)
  at `6c4a1d0` passed both native architectures and the complete API 35/36 jobs,
  including deletion failures and alert reset/retry. The system ANR did not recur;
  the new diagnostic categories have not identified its source.
- Shared desktop receive UI now discards an invoice QR when its amount or description
  changes, including edits during a delayed response. The issued invoice remains
  available for status lookup; creating a replacement requires an explicit action.
  All 16 browser workflow suites passed. Focused delayed-response regressions pass
  at StartOS phone width (390) and Umbrel desktop width (1280); neither overflows.
- iOS receive amount/description fields are disabled while a request is running.
  Native Xcode simulator receive/persistence navigation and bundle verification
  passed. That existing test does not exercise a live Lightning invoice.
- Android now invalidates queued or late receive results when leaving the page,
  changing the receive method or editing the invoice amount. The amount field is
  disabled during request creation. A real regtest model regression reproduced
  the queued result returning after navigation; it passes after the fix and
  verifies an explicit new request succeeds. All 19 local API 36 native/model/
  storage/Settings cases pass, plus 81 unit tests (3 opt-in skips). This does not
  establish live Lightning or physical-device acceptance.
- Repository `just checks` passed with the existing local Boost MultiIndex
  compatibility-header configuration. A fresh native cache without that setting
  failed in unchanged `libbitcoinkernel-sys` against Homebrew Boost 1.92. Native
  dependency configuration still needs a reproducible release-toolchain definition;
  the local workaround is not evidence of a clean-machine release build.
- Android CI [43885819059](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43885819059)
  at `95626fa` passed both native architectures and complete API 35/36 emulator
  jobs, including the queued-receive regression. Browser CI
  [43885818832](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43885818832)
  passed for that revision. iOS CI `43885819065` remains queued.
- A fresh read-only inspection of `start.local` found Paperclip `0.10.0:0`, CLN
  and LND running. The installed wallet loads activity and reports the Ark server
  reachable, but its XBT node connection check fails. That installed package still
  exposes the older Ark-only Lightning page. This is not acceptance of the newer
  direct-node candidate, and the backend failure has not been diagnosed anew.
- Current Android and native iOS simulator adapters passed authenticated CLN/LND
  identity, three balance reads, deliberate wrong-pin rejection and reconnection
  against StartOS LAN endpoints. Credentials remained private; no payments or
  service changes were made. The iOS UI test runner initially crashed while
  preparing tests (`XCTWaiter` stalled). A subsequent native Xcode run passed the
  actual connection screens for both nodes: verify, connected indicator and
  balance refresh. The original runner stall remains unexplained; no UI assertion
  or timeout was weakened.
- The current Rust server adapter also passed fresh authenticated CLN/LND LAN
  identity, repeated balances, wrong-pin rejection and reconnection. A separate
  native iOS embedded-Tor probe returned promptly after cancellation, authenticated
  its control connection and reached 30% bootstrap, then failed before contacting
  LND. An independent local controller timed out; the Tor thread remained in its
  event loop. The precise failure remains under investigation. Subsequent cached
  and fresh-cache native simulator runs passed authenticated LND onion identity,
  three balance reads, wrong-pin rejection and reconnection. First reads took
  21 and 107 seconds respectively. A separate injected startup failure recovered
  in the same process and verified HTTPS traffic through Tor; that does not
  reproduce or resolve the original spontaneous timeout.
- Android's native API 36 emulator also passed three authenticated LND onion
  reads, balances, wrong-pin rejection and recovery through embedded Tor. Startup
  took about 7 seconds and the first node read about 8 seconds. This read-only
  opt-in test never opened a wallet session or created an invoice. It does not
  establish physical-device, funded-payment or package acceptance.
- Both CLN and LND passed the Android emulator's LAN adapter checks with a
  test-only DNS address supplied for `start.local`, preserving the HTTPS authority
  and verified certificate pins. Automatic resolution failed with UnknownHost;
  a bare-IP endpoint failed the TLS handshake. Those failures remain recorded.
  The passing fixture is not evidence of automatic LAN discovery on Android.
- All 33 deployment Python unit tests passed using Python 3.13. The separate Linux
  daemon smoke script requires its built container and was not accepted on macOS.
  Linux CI [43891347530](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43891347530)
  at `b00ee675` subsequently passed both AMD64 and ARM64 builds and authenticated
  container/daemon smoke checks with `publish=false`. No image or manifest was
  published. This does not establish an installed StartOS/Umbrel upgrade.
- All 106 Swift policy tests and 70 server adapter/recovery tests passed locally.
  The server's opt-in live test was ignored in that default suite and passed in
  the separate authenticated StartOS run described above.
- Manual desktop balance refresh now reports partial failures instead of claiming
  success. Invalid/negative balances display as unavailable, including the recovery
  summary. A late refresh cannot overwrite the locked status. Browser regressions
  cover failure, explicit recovery, and lock races at phone/tablet/desktop widths.
  All 16 browser workflow suites passed with these changes.

## Acceptance matrix

### Native key binding follow-up: 2026-11-16

Two deterministic, unfunded regtest wallets with the same four-byte Ark fingerprint
reproduced a native mobile session-binding failure. The dispatcher accepted the
other seed for operations on an already-open session, and backup verification
reported the other wallet's valid archive as matching the active wallet.
[BIP32](https://bips.dev/32/#key-identifiers) defines this fingerprint as a short
identifier and explicitly requires implementations to handle collisions.

The shared iOS/Android dispatcher now checks a 256-bit seed commitment retained
only in memory. Backup matching also uses that binding plus the network and wallet
kind. Displayed fingerprints, stored files, backups and ABI contracts are unchanged;
the commitment is never returned by the API. Both collision regressions failed
before the change and pass afterward. Full on-chain descriptor validation still
rejects a backup supplied with the wrong colliding seed. All 31 active native
mobile unit tests pass; one opt-in live Electrum test remains ignored.

This is a local session identity check, not evidence of a remote unauthenticated
attack. It does not complete portable payment/Bridge recovery archives or prove
funded upgrade acceptance. The Android ARM64 native library, app and test APKs
built successfully. Five JNI/native/profile tests passed on the isolated API 36
emulator, including the same collision and preservation of the original session.
The native Apple simulator library and app built successfully, bundle verification
passed, and all five native XCTest cases passed in the isolated test host,
including the collision through FFI. No funded physical device was changed.
`just checks` passed. Device-signing and x86-64 release acceptance remain separate.

### Release gates

A feature is complete only when users can perform the same task with equivalent
validation, recovery and error handling. A shared library or visible menu alone
does not establish parity. Native UI and background scheduling can differ.

| Area | Mobile candidate | Desktop / Umbrel / StartOS candidate | Remaining acceptance |
| --- | --- | --- | --- |
| Ark payments and recovery | Shared engine, durable payment status, cost review | Shared engine, cost review, status UI | Deploy cookie-rotation fix, verify failed receive recovery and both-direction settlement |
| Lightning through Ark | Shared BOLT11/BOLT12 engine and enforced reviewed debit | Same engine, fixed-amount review and debit capability | Verify live against corrected service; keep unknown outcomes from being resent |
| Remote CLN and XBT LND | Both adapters, Tor, TLS, BOLT12, balances and status | Direct-node adapters, private credential storage, reviewed sends and durable status implemented | Live node, container Tor and platform package acceptance pending; see REMOTE-LIGHTNING.md |
| Multiple / hardware / watch-only wallets | Implemented in mobile candidate, visible wallet switcher | Hot/public-account switcher, QR and watch-only pairing, public export/removal, verified signing and durable broadcast journal | Physical Krux round trips, desktop multiple hot profiles, QR-funded Ark boarding and full recovery |
| Paperclip Bridge | Both mobile directions implemented, with separate availability and payment status | Outgoing Ark/CLN/LND funding, incoming node receipt, quote review and recovery history implemented | Live swaps and funded recovery/upgrade acceptance remain |
| JoinBlaket / Jam | Five jars, remote session, receive, reviewed maker controls | Same tasks through authenticated fixed-upstream proxy | Actual Kilombino XBT Jam endpoint, live validation, bond setup and taker flows |
| Existing Kilojoin funds | Recovery UI retained; new rounds rejected before database access | No new Kilojoin entry point | Verify existing-round completion and withdrawal on upgraded wallets |
| Backups / upgrades | Encrypted seed/database backups and scoped mobile wallet state | Complete volume backups | Preserve separate mobile payment/Bridge recovery records, restore tests, update migrations and desktop backup UX |
| UI and accessibility | Phone / Duo / foldable adaptive layout, nested tab histories | Four primary menus, browser history/focus, responsive account switcher | Physical-device and screen-reader checks; see UI-UX-VALIDATION.md for local simulator/emulator/browser evidence |
| Distribution | Apple build 70 remains existing release; Android development builds | Existing packages predate current fixes | Signed candidates, store eligibility, clean-install and update tests |

## Feature audit: 2026-11-15

This audit inspected candidate `8d2fdfc2648ee407c750d3a11689e4436206f810`.
Implementation, local tests and published delivery are separate states. Neither
matching menus nor a passing build establishes live feature parity.

### Source and package alignment

| Surface | Inspected revision | Result |
| --- | --- | --- |
| Shared candidate and Android branch | `8d2fdfc` on both branches | Aligned candidate source |
| Default `main` branch | `69eb582` | 107 commits behind the inspected candidate; no mobile tree |
| Remote iOS release branch | `2dea92b` | 31 commits behind the candidate; local build 70 changes were imported separately into the candidate |
| StartOS 0.4 wrapper | `a396d8cf9dd3150cd42f02d56d0f3737628769cf` | Pins the November 11 image below |
| Umbrel wrapper | `80a91ad5acd3abc764f82d92758b6b7d40e1cd65` | Pins the same image |

Both wrapper manifests pin
`beta-42930294633@sha256:94df29f5c78a4e9319c0d2695831ce35ac0cb9e528092a898a1fc46028d2613b`.
They do not yet deliver the current candidate. This is a manifest inspection,
not a fresh inspection of the running services or App Store/TestFlight state.
The original iOS worktree and its uncommitted changes remain untouched.

### Task-level comparison

“Implemented” below describes the candidate source, not production acceptance.
Standalone desktop, Umbrel and StartOS use the shared browser/server implementation;
the wrappers still require platform-specific configuration and upgrade tests.

| User task | iOS candidate | Android candidate | Shared browser/server candidate |
| --- | --- | --- | --- |
| Send/receive Ark, BOLT11 and BOLT12 through Ark | Implemented | Implemented | Implemented; live receive/recovery still needs verification |
| Review Ark/Lightning total debit | Enforced shared-engine cap | Enforced shared-engine cap | Enforced cap for these two paths |
| Review a hot-wallet on-chain send | Exact PSBT, fee/total, expiry and input checks | Same shared transaction review | Amount-only confirmation; miner fee is additional, without matching reviewed-total enforcement |
| Review boarding cost | Prepared transaction and reviewed breakdown | Same shared review | Generic amount confirmation; detailed fee/recovery review is missing |
| Recover an uncertain send after closing the client | Durable mobile intent/status | Durable mobile intent/status | Hot-wallet warning is tab-scoped; QR broadcast journal is durable |
| Use Send Max | Implemented for supported Ark/on-chain routes | Implemented | REST has drain operations, but the browser has no equivalent reviewed Send Max flow |
| Connect directly to CLN/XBT LND, including BOLT12 | Implemented | Implemented | Direct-node adapters, credential storage and UI missing; existing Lightning UI uses Ark |
| Use Paperclip Bridge in both directions | Implemented | Implemented | Missing browser/server flows |
| Switch multiple hot wallets | Implemented | Implemented | One hot wallet per server |
| Pair/switch/sign with multiple Krux wallets | Implemented | Implemented | Public QR accounts and shared verifier implemented; physical signer round trip pending everywhere |
| Import a watch-only wallet | Implemented | Implemented | Separate watch-only account kind missing |
| Rename/remove/export a public wallet | Implemented | Implemented | Rename implemented; remove/public-export management missing |
| Fund Ark from a QR signer | Implemented | Implemented | Missing browser flow |
| Use five JoinBlaket jars and maker controls | Implemented adapter/UI | Implemented adapter/UI | Implemented adapter/UI; actual service connection unverified |
| Set up fidelity bonds, taker mixing and full Jam jar management | Incomplete | Incomplete | Incomplete |
| Recover previous Kilojoin funds | Recovery paths retained | Recovery paths retained | No equivalent browser recovery workflow; never enable new Kilojoin rounds |
| Create/import and back up wallets | Seed creation/import and encrypted complete backup/restore | Same major tasks | Creation and platform volume backups; matching encrypted import/export/restore UI missing |
| View normal on-chain transaction history | Implemented | Implemented | Hot-wallet records are fetched into technical details, while the normal Activity list renders Ark movements only; QR accounts have their own history |
| Select XBT/sats, hide balances, see cached fiat estimates | Implemented | Implemented | Browser uses sats and lacks matching privacy/display controls |
| Sign/verify address ownership messages | Implemented | Implemented | Implemented for the hot wallet |
| Maintain Ark funds and progress emergency exits | Implemented, subject to mobile scheduling | Implemented, subject to mobile scheduling | Service-side maintenance and exit actions implemented; funded upgrade/recovery acceptance pending |
| Navigate on phone, wide and foldable screens | Simulator-tested adaptive layouts | Open/cover emulator tests, including larger text | Browser tests at phone/tablet/desktop widths; physical accessibility checks pending |

### Newly confirmed release gaps

1. **Exact debit review:** `web/app.js` sends hot on-chain payments directly to
   `onchain/send`. `bark-rest/src/api/v1/onchain.rs` selects a fee rate at execution.
   In contrast, `mobile/rust/src/session.rs` retains the reviewed PSBT and checks
   its amount, total, expiry and inputs before signing. Boarding has a similar
   browser/mobile review gap. Extend the server contracts before adding a visual
   fee estimate; a display-only estimate does not establish parity.
2. **Durable uncertain outcomes:** browser `mutate()` stores its warning in
   `sessionStorage`. A new tab does not inherit that warning. Core payment records
   may survive, but the browser does not reconstruct the same wallet-scoped intent
   and reconciliation gate as mobile. The newer QR broadcast journal does not
   close this gap for hot-wallet operations.
3. **Activity completeness — closed in the candidate follow-up:** normal deposits
   and on-chain sends now have readable Activity cards, alongside Ark movements.
   All / On-chain / Ark filters, confirmation state, honest unknown fees, partial
   failure notices and bounded rendering also cover QR account history. The old
   comparison table above describes the original audit revision. This follow-up
   does not change the versions currently delivered by either platform wrapper.
4. **Packaged JoinBlaket configuration:** the server proxy requires
   `BARKD_JOINBLAKET_URL` and optional Tor/CA settings. Neither inspected wrapper
   supplies those settings. A working jar screen in local fixtures does not mean
   users of either package can connect Kilombino's service through platform setup.
5. **Default-server documentation:** `deployment/PLATFORMS.md` and the legacy
   package generator name `ark.paperclip-xbt.xyz`; the active wrappers inject
   `ark.paperclippool.xyz`. Confirm the intended service and align release docs
   and packaging without overwriting saved connections.

The audit also found and fixed a browser receipt navigation regression:
**View activity** referenced the removed `showView()` function. It now uses
`PaperclipNavigation.show()`. The browser regression verifies the receipt closes,
Activity opens, and the selected menu updates at 390, 800 and 1280 pixels, without
submitting a wallet action.

### Implementation order

First close exact-review and durable-status gaps. Then complete direct
CLN/LND and Bridge on the shared server/browser, followed by multi-wallet,
watch-only, backup and QR boarding workflows. Complete Jam service configuration
and remaining maker/taker tasks before treating that feature as finished. Finally
validate one frozen revision in signed mobile candidates and both platform
packages, including upgrade/restore tests. Do not merge or deploy merely to make
branch names match while these acceptance gaps remain.

## Production-readiness follow-up: 2026-11-15

The requested finish line is production readiness on all four platforms, not
just matching source branches. The original comparison above remains an audit of
its named revision. The following candidate changes supersede specific gaps:

- Exact hot-wallet on-chain review now uses prepare/commit with a retained PSBT,
  wallet binding, expiry, cost and input checks.
- Server boarding now has the same review categories as mobile: net Ark funds,
  recovery reserve, included boarding fee, network fee and total debit. It retains
  and consumes the exact funding transaction. Live funded acceptance is pending.
- Ordinary-send fee replacement, owned-wallet destinations, mobile restore checks,
  health and allowlisted support reports are implemented. See PAYMENT-ASSISTANCE.md
  for the limits; RBF is not a generic retry or a protocol-funding fee bump.
- Android targets API 36 for the candidate. Google requires API 36 or higher for
  phone app submissions from August 31, 2026. Edge-to-edge, supported BackHandler
  navigation and foldable layouts must remain verified after this change.
  [Target requirements](https://developer.android.com/google/play/requirements/target-sdk)
  and [Android 16 behavior changes](https://developer.android.com/about/versions/16/behavior-changes-16).

The direct CLN/LND server and browser candidate now includes TLS/Tor transport,
BOLT11/BOLT12, reviewed sends and durable unknown-payment reconciliation. Local
synthetic-node tests cover both adapters; live node and installed-package acceptance
remain pending. See REMOTE-LIGHTNING.md.

The server hot-wallet candidate now includes durable submission receipts and exact
status recovery across browser restarts, including interrupted on-chain, Ark,
Lightning, withdrawal and recovery operations. Older-server financial submission
fails closed. See PAYMENT-ASSISTANCE.md for the remaining crash-window, archival
and installed-package acceptance limits.

Invoice receipts on iOS, Android and the shared server now require the original
invoice, payment hash and amount to agree. LND settlement also requires its
settled flag, and CLN must return exactly one matching invoice. Android Bridge
checks the receiving node independently of bridge-service availability, and
requires a matching, unpaid node invoice before quoting a receive. An outgoing
bridge status alone cannot establish settlement without valid payment proof.
Synthetic regression checks passed: 40 REST tests, 9 Swift bridge tests and 75
Android unit tests (3 skipped). These checks do not establish live bridge or
installed-package acceptance.

The browser/server public-wallet candidate now supports watch-only accounts,
public descriptor exports and removal from the wallet list. Signing and broadcast
are rejected by the server for watch-only accounts. Removal requires the exact
wallet name and backup acknowledgement, and is blocked while the saved broadcast
has not confirmed. It archives the account instead of deleting the database:
importing the same public account restores address indexes and history. A missing
database is an error, never an invitation to create a fresh address history.
Existing QR accounts retain their signing type when loading the older schema.
Public exports contain no spending keys, but reveal wallet addresses and activity;
the export review explains that privacy consequence.

Synthetic tests cover archive/restore index continuity, missing-database refusal,
watch-only signing refusal, public export, active-account removal and uncertain
broadcast blocking. Browser flows pass at 390 and 1280 pixels. The Android compact
menu smoke test and separate settings test pass on an unfunded API 35 emulator;
the CI test now follows the nested menu routes introduced by the compact layout.

The hot on-chain browser send now offers Send Max. It prepares a single-recipient
drain to an external account, shows the exact recipient amount after miner fees,
and uses the existing retained-transaction approval and durable submission journal.
An amount cannot be combined with Send Max; older servers that do not confirm that
mode are refused. Editing the destination or mode invalidates review, and locking
or switching accounts clears the mode. QR signing wallets use the same unsigned
transaction preparation, with signature
verification and the saved broadcast journal still required. Watch-only accounts
remain unable to prepare or send. Ark Send Max uses the shared mobile engine's
eligible-input calculation, displays recovery reserves and the remaining balance,
and submits the exact reviewed recipient amount with a maximum debit. Changes in
available inputs or cost require a new review; newly arrived funds are not silently
included. Synthetic server tests verify a public-wallet drain creates no signature
or spend, while browser tests cover exact amounts, old-server refusal, altered
quotes, edited forms and cleanup at phone, foldable and desktop widths.

Current native read-only acceptance covers CLN and LND with the Android Kotlin
adapter, the shared server adapter, and the newly built iOS simulator app. Each
passed repeated identity/balance reads, deliberate wrong-pin rejection and recovery.
The iOS connection UI also passed its live CLN/LND verify-and-refresh test after an
initial test-runner crash before execution. No payment was made. Android CI passed
both native architectures and API 35/36 emulator checks. The Linux image
workflow now defaults to build-only validation; publishing beta images requires
its explicit `publish` option.

The broader gaps remain open: Bridge browser flows, full server wallet management and recovery,
Jam service acceptance, payment requests, portable contacts/labels and restricted
receive-only credentials. Public signing identities, coherent release versions,
physical signer tests, funded recovery and both host upgrade paths remain release
gates. Existing uploaded build 70 is not replaced by these source changes.

## Live verification and budget

Use the existing authenticated LND and CLN on StartOS. Preserve TLS verification
and imported credentials. Record identity, network, balances, invoice/offer chain,
amount, fee cap, payment hash and terminal status without secrets or preimages in
logs. Test network interruption, retry after a failed connection, foreground /
background transitions and recovery of an uncertain payment.

The authorized total is **25,000 sats**, including routing fees and Ark recovery
costs. The private ledger currently conservatively reserves **10,110 sats**. A
100-sat CLN-to-LND BOLT12 transfer settled. LND has no spendable funds after channel
reserves. The 10,000-sat CLN-to-Ark attempt failed at the sender, with no receiver
settlement; Ark fee accounting remains unresolved. Do not release its reservation
or submit a replacement based on a timeout or missing receive record alone.

No production service is restarted by this checklist. Deployment timing and any
required service interruption must respect the existing no-restart constraint.

## Release sequence

1. Complete the acceptance matrix and record actual evidence, including physical
   device and both server-platform update tests. Choose the public version.
2. Build immutable candidates from the source freeze; validate signatures,
   checksums, wallet preservation and restore procedures. Do not downgrade a wallet
   database that a newer build has migrated.
3. Submit Apple for review with manual release. Stage Google Play testing/review
   and managed publishing where available. A first Play publication needs its own
   supported release path; managed publishing does not cover first publication.
4. Prepare the signed APK release and both wrapper updates with matching notes,
   support information and artifact provenance. Keep candidates unpublished until
   the four platforms are ready.
5. Release the approved versions within the coordinated window. Verify each store
   listing/download, package digest and post-upgrade health. If a platform fails,
   report that clearly instead of declaring full parity or a completed release.

Apple's [manual release controls](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option)
and Google's [managed publishing rules](https://support.google.com/googleplay/android-developer/answer/9859654)
govern the store portion of this sequence.

## Bridge service status and build evidence: 2026-11-15

The mobile candidate adds a compact bridge-service indicator to the Ark and node
entry points, outgoing and incoming bridge forms, and their activity/connection
screens. Availability is checked separately for XBT-to-BTC and BTC-to-XBT. Live
requires a valid `open: true` response; `open: false` is Paused. A combined entry
shows Limited when only one direction is open. Transport, TLS, malformed-response
and authentication errors are Status unknown, not proof of an outage or settlement.
Visible foreground screens refresh at most once per direction per 30 seconds;
observations older than 90 seconds cannot remain Live. Changing bridge access
clears observations. Checks use the existing fixed HTTPS service and never create
quotes, invoices or payment attempts. Payment recovery remains independent.

Both public availability endpoints returned HTTP 200 and `open: true` during the
read-only check. The iOS simulator showed Live on both direction screens, and the
entry/send/receive navigation test passed. Swift bridge tests passed (10 tests),
and Android unit tests passed (77 executed, three live opt-in tests skipped).
The Android status-label layout test also passed at 2× text size on an unfunded
API 35 emulator, and release lint completed without errors. The bridge headers
now use a short explanation instead of repeating the page title in a large banner.
Browser Bridge flows remain a parity gap; add the same directional status contract
when those flows are implemented rather than showing an unsupported bridge menu.

Linux build-only run `43807411593` passed AMD64 and ARM64 container checks at
`2fa221e`; publication was skipped. This verifies that revision, not the subsequent
Send Max changes or a deployed Umbrel/StartOS upgrade. Android run `43806295576`
passed ARM64/x86-64 builds and API 35/36 emulator checks at `c3c9738`. Re-run the
candidate matrix after the final source freeze.

## Server Bridge foundation: 2026-11-15

The authenticated server API now retains public-service quotes for both Bridge
directions. It verifies signed mainnet BOLT11 invoices, required XBT identity,
the shared payment hash, exact recipient and funding amounts, conversion fields,
and both invoice deadlines. Quote files use the full wallet identity and private,
atomic storage. A repeated request returns the original saved quote, including
after expiry or restart; it cannot silently replace a possibly funded invoice.
Status tokens and settlement preimages are not returned to the browser. A remote
`settled` string alone is insufficient: a matching preimage must verify first.

The client permits only the fixed HTTPS bridge origin, system TLS validation,
bounded responses and deadlines, and no redirects or automatic retries. Public
proof-of-work is bounded and yields to cancellation. These endpoints create no
wallet payments or node invoices. Browser funding/review, receiving-node receipt
reconciliation and the complete browser UI remain required before claiming
Bridge parity. No unsupported Bridge menu has been exposed.

Synthetic REST tests passed: 54 executed and one live opt-in test ignored. Ten
Bridge checks cover quote tampering, networks, expiry, settlement proof,
availability decoding, bounded responses, private persistence, symlinks,
authentication, and duplicate quote recovery. These tests made no live payments
and do not establish successful production swaps.

## Android Bridge navigation: 2026-11-15

Android now separates Bridge entry, conversion review, payment detail, activity
and connection settings. All saved records are accessible in pages of ten.
Selecting history clears in-memory funding approvals; a historical quote cannot
restore authorization to send. Incoming or expired quotes do not offer a funding
action, and expired incoming invoices are not presented as payable QR codes.
Wide screens place direction choices side by side; large text uses stacked rows.
The live-service indicator remains separate from the payment result on each page.

Two UI-only navigation tests passed on API 35, and the final layout and the
Android unit suite passed on API 36 with 16 KB memory pages. The final wide-screen
and 2× text screenshots were inspected. The tests use synthetic callbacks and
never fund a payment. Release lint passed with no errors, and all 77 executed
Android unit tests passed (three live opt-in tests skipped). The full native wallet screen flow also passed on the local
API 36 emulator after an initial startup wait timed out.

Linux build-only run `43812021957` passed AMD64 and ARM64 at `4dde5dd`, with
publication skipped. Server regression run `43813156807` passed at `87ccf5d`.
Android run `43811981065` passed both native architectures and API 35; its first
API 36 run timed out while identifying the onboarding screenshot window. The
failed job was rerun without weakening the capture check. Its final result and
the next candidate's complete matrix must be checked before release.


## Browser Bridge receive and exact node receipt: 2026-11-15

The shared StartOS/Umbrel browser app now receives XBT into a saved CLN or LND
node through the Bridge. The entry, conversion review and activity pages show
a compact BTC-to-XBT availability indicator. A fresh availability check precedes
node invoice creation. Users review the XBT receive amount and BTC funding amount
before they reveal the BTC invoice. Expired invoices cannot be shared. History
uses pages of ten, and an interrupted quote can resume from the saved node invoice.
No browser route in this change sends or automatically retries a payment.

The server binds an incoming quote to the saved receiving node, signed invoice,
payment hash and exact amount. Bridge settlement proof alone cannot mark a receive
successful. Status checks read the receiving node independently of Bridge status;
an exact settled node receipt can succeed during a Bridge outage. That receipt
survives restart. Older records with Bridge proof need a verified node receipt
before they can claim receipt. The browser clears invoice and amount details on
lock or wallet change and ignores delayed responses from an old session.

Synthetic REST tests passed: 57 executed and one live opt-in test ignored. Browser
checks passed for both hosts and both node adapters at 390, 840 and 1280 pixels.
They cover conversion mismatch, explicit BTC sharing, stale/malformed availability,
a paused service, Bridge proof without node receipt, receipt during a Bridge outage,
history reload, expiry, interrupted quote recovery and locking during a request.
Existing navigation, wallet-race, CLN/LND, setup, QR and transport checks also passed.
The compact and desktop review screenshots were inspected. These tests use no
live payments and do not establish a successful production swap. Outgoing browser
Bridge funding and live service acceptance remain release gates.

The API specification/client generation and `just checks` passed. The earlier
Android run `43811981065` now passes both native architectures and API 35/36;
the API 36 rerun used the unchanged onboarding check. This does not verify later
candidate revisions or a physical-device upgrade.

## Mobile Bridge review lifetime: 2026-11-16

The iOS and Android candidates now invalidate unsubmitted Bridge reviews when
the app locks or the Bridge screen closes. A delayed network response cannot
restore funding approval. Android captures the review session before it waits
for the shared payment gate, and publishes fee approval only after it saves the
quote. Both implementations recheck that session immediately before they record
submission intent. Once an attempt is journaled, locking does not discard its
result or automatically submit another payment. iOS also rejects a review whose
wall-clock age is negative.

Matching asynchronous tests cover delayed responses, a lock during the final
node check, queued reviews and reviews from another screen. The 14 selected Swift
tests passed. Android unit tests passed: 81 executed, three live opt-in tests
skipped. The Android ARM64 debug build and release lint passed, with no lint
errors. `just checks` passed. No live payment was made for these tests.

Repeated iPhone simulator navigation exposed a long SwiftUI destination-update
stall in the existing Bridge entry flow. The Bridge menu now owns its nested
navigation state independently of the node dashboard. Two consecutive tests pass
through send, Back, receive and rotation, including a 30-second navigation limit.
The opened Duo simulator also passed Bridge navigation and the strengthened
Lightning layout check. These are synthetic UI checks, not physical-device or
funded payment acceptance; capture details are in `UI-UX-VALIDATION.md`.

Previous candidate CI is complete: browser run `43818026894` and Lightning
regression run `43818026844` passed at `a7439f1`. Android run `43815916922` passed
both native architectures and API 35/36 at `fd966a6`. Linux build-only run
`43815931641` passed AMD64 and ARM64 at that revision; publication was skipped.
These results are not production upgrades or acceptance of later source changes.

Linux build-only run `43825088026` passed AMD64 and ARM64 at `a7439f1`, including
the latest server Bridge receive changes. The publishing job was skipped.

## Browser Bridge outgoing node payments: 2026-11-16

The shared desktop/StartOS/Umbrel candidate now has an outgoing conversion flow
for BTC BOLT11 invoices funded by the saved XBT CLN or LND node. Separate entry,
review and paginated activity pages show direction-specific live availability.
The review distinguishes the BTC recipient amount, XBT funding, routing fee cap
and maximum XBT total. Node funding alone never displays BTC settlement success.

The backend reuses the node's durable send journal and consumes an exact review
once. Quote expiry is rechecked after the final asynchronous node preflight.
Interrupted funding stays visible after reload/restart and cannot be replayed.
Only a journal check proving that preflight never submitted can permit a fresh
review. Delayed browser responses cannot restore approval after lock, navigation
or a visibility change. Waiting `offered` quotes remain reviewable, matching the
existing mobile Bridge state mapping.

Validation passed: 63 REST unit tests (one live opt-in test skipped), all 19
browser regression scripts, API/client regeneration and `just checks`. New browser
checks cover both hosts and both node adapters at 390, 840 and 1280 pixels,
including expiry during review, lost responses, restart recovery, changed amounts,
lock/navigation cancellation and the distinction between funding and settlement.
Synthetic TLS node tests cover exact fee enforcement, changed quote terms, a
failed durable write, expiry during node preflight and no replay after restart.
Compact and wide screenshots were inspected. This implementation is not a live
swap, deployment or funded upgrade acceptance. Outgoing **Ark** funding in the browser, live Bridge tests,
container/platform acceptance, device recovery, signing and the other open matrix
gates remain unfinished. No live funds were used for this change.

Android CI run `43829075539` passed both native architectures and API 35/36 at
`47ec7dc`. This verifies the preceding mobile review-lifetime/navigation revision,
not a physical-device upgrade or the newer browser Bridge changes.


## Browser Bridge Ark funding: 2026-11-16

The shared browser/server candidate now funds outgoing BTC conversions from Ark,
as well as the existing CLN/LND node sources. Users choose the source explicitly.
Ark works without a saved node when the server supports Lightning and enforced
debit limits. Review includes whole-satoshi funding, fees and recovery reserves,
and the maximum total debit. Both conversion directions are presented as separate
choices with direction-specific availability indicators.

The server retains the quote and a single-use, wallet-bound review. It checks
expiry before dispatch and again in the shared engine's final submission callback,
after asynchronous input and fee preflight. The engine enforces the reviewed debit
cap. The existing wallet submission journal prevents duplicate dispatch and blocks
another wallet action while a result is uncertain. A status check closes an unseen
submission ID before reporting it unsubmitted, so a delayed request cannot spend
later. An initiated payment with no current engine checkpoint remains unknown;
it is never treated as safe to repeat. Recovery phases stay visible, and Ark
funding proof remains separate from verified BTC settlement.

Local validation passed: 70 REST unit tests (one live opt-in test skipped), 27
wallet Lightning tests, 27 mobile-engine tests (one opt-in test skipped), and all
19 browser regression scripts. `just checks` also passed. The outgoing
browser tests cover both funding sources, both platform skins, phone/desktop
widths, Ark without a saved node, changed totals, expiration, cancellation, lost
responses, reload recovery and session/navigation changes. The compact and wide
screenshots were inspected. Public API/client regeneration was completed; these
Bridge routes remain internal web-ui routes. No live funds were used.

This closes the browser Ark-funding implementation gap, not live swap acceptance.
Funded failure recovery, both-direction live settlement, actual package upgrades,
physical device/signer tests, full backups, the remaining wallet/Jam tasks and
release identity/signing gates are still open. Previous revision `26ce04d` passed
browser CI `43832426585` and Lightning regression `43832426691`. Its Linux build-only
run `43832451307` passed AMD64 and ARM64, with manifest publication skipped.


The shared engine also now compares the signed invoice and any explicitly supplied
amount against an existing Lightning checkpoint before a caller can resume it.
The regression uses a different signed invoice with the same payment hash, then a
changed amount. Both are rejected before the submission callback or drive; the
original checkpoint and locked funds remain available for recovery. This shared
Rust guard applies to mobile and server builds without changing the FFI contract.
New mobile artifacts must include it before release; existing installed builds
have not been changed.

At `f8bcbb0`, the local native Apple simulator Rust build, Xcode app link and bundle
verification passed, including Tor framework metadata and signatures. Browser CI
`43837023562` passed. Android run `43837023567`, Lightning regression run
`43837023612`, Linux build-only run `43837079138` and iOS run `43837081855` were
still running when recorded. Linux publication is disabled. These are candidate
checks, not physical-device installs or release acceptance.

## Mobile restore retry: 2026-11-16

The shared iOS/Android engine now removes staging files when restore rejects an
archive. Previously, a rejected database left a fixed staging directory that
blocked a corrected retry. Restore now uses a unique private sibling directory
with automatic cleanup. Older interrupted staging data is preserved, and an
existing wallet destination still cannot be restored over.

A new regression first reproduced the failure, then passed for damaged databases,
wrong keys, wrong networks, a corrected retry and preservation of older staging
data. All 28 mobile-engine tests passed (one live opt-in test skipped), and
`just checks` passed. No production wallet or physical device was changed. This
fix does not close funded backup/restore or platform-upgrade acceptance.

The local iPhone simulator build at `a18742b` also passed native Rust compilation,
Xcode linking and bundle verification. Its unfunded persistence UI test verified
seed import, wallet switching, receive-address continuity after relaunch and the
wallet security page. The first run exposed an outdated test route after Settings
was condensed; the test now enters Security & recovery before Wallet security.
The corrected test passed. Server Lightning CI `43837023612` passed at `f8bcbb0`.
Later CI builds remain separate evidence and must be checked before release.

## Mobile export retry: 2026-11-16

The shared iOS/Android backup exporter now uses a unique private directory for
each SQLite snapshot. An older interrupted `snapshot.sqlite` no longer blocks
all later exports, and remains untouched for recovery. Temporary files from the
current attempt are cleaned on success or error.

The regression reproduced the old export refusal, then verified export with a
leftover snapshot, preservation of that file, cleanup of the new snapshot and
receive-address continuity after restoring the new archive. All 29 mobile-engine
tests passed (one live opt-in test skipped), and `just checks` passed.

Android CI `43837023567` passed both native architectures and API 35/36 at
`f8bcbb0`. This confirms the Ark Bridge/shared invoice guard revision, not the
later restore/export changes or a physical-device upgrade.

### Backup scope still needs completion

The current mobile archive contains the seed, network and native SQLite snapshot.
It does not include separate app recovery records. Android keeps its wallet-scoped
pending-payment warning in `wallet-pending` in SecureStore; both mobile apps keep
Bridge quote/history state outside the native database. The iOS archive exporter
and Android exporter currently serialize only the native snapshot and seed data.
A successful SQLite restore therefore does not establish complete recovery of an
uncertain app submission or Bridge conversion.

Before release, define and test a versioned, cross-platform recovery envelope for
these records, bound to the restored wallet's identity. Preserve unknown outcomes
and original payment references without turning saved reviews into new spending
approval. Import must never automatically repeat a payment. Test old archives,
wrong-wallet records, interrupted import and status recovery after restoration.
Node credentials intentionally stored only on-device require a separate policy;
do not silently add them to portable backups. This gap remains open alongside
funded recovery and platform upgrade/restore acceptance.

## Restore validation before wallet changes: 2026-11-16

Android now decrypts and validates an archive before closing the active wallet.
Both mobile adapters run the shared temporary database restore validator before
profile installation. A bad key, unsupported archive, duplicate wallet or damaged
database therefore cannot discard Android's current native session as part of
preflight. Later storage/installation failures still require separate recovery
handling; this does not make import atomic across every storage failure.

Validation passed: 81 Android unit tests (three opt-in tests skipped), native ARM64
build, APK/test APK assembly, and two AssistanceNativeTest cases on an unfunded
API 35 emulator. The new case calls JNI directly after rejected restores, so an
automatic reopen cannot conceal a closed session. It covers wrong keys, duplicate
wallets and damaged databases, while preserving wallet selection. The native iOS
simulator app compiles and its bundle verifies; the new Swift preflight path has
not yet been exercised through Files on a physical device. `just checks` passed.

Linux build-only CI `43837079138` passed AMD64 and ARM64 at `f8bcbb0`; the manifest
publishing job was skipped. iOS CI `43837081855` failed in the Lightning screen's
SwiftUI type checking during the unsigned device build. Its Rust device/simulator
and Swift unit-test jobs passed. The compiler failure remains a release gate until
the smaller-view follow-up passes that CI toolchain.

The Lightning dashboard and action sections are now separate SwiftUI view
properties, reducing the expression the compiler must infer. The native local
simulator build and bundle verification pass. Both the Lightning layout test and
Bridge entry/send/receive status-navigation test pass on the unfunded iPhone
simulator. The older CI compiler still needs to validate this follow-up; local
Xcode success alone does not close that failure.

Android run `43837871210` at `a18742b` passed both native builds but failed the
onboarding screenshot's active-window check on both API 35 and API 36. Compose
found the onboarding control; the accessibility root did not match the app within
ten seconds. The full wallet-navigation test passed locally on an unfunded API 35
ARM64 emulator. This is not enough to dismiss the CI failures. One API 35 job rerun
was requested, and capture failures now report only the observed package name,
without logging wallet text. The same active-window assertion and timeout remain.
CI emulator acceptance is still open; investigate repeated failures before release.


## Mobile backup navigation and CI follow-up: 2026-11-16

The mobile backup center now separates Save, Check and Restore into task pages.
The hub shows local backup/check dates and reflows into two columns on wider
screens. Copy describes the archive as wallet keys and native Ark recovery data;
it no longer promises complete app recovery. App payment warnings, Bridge history
and node connections remain outside the archive. The portable recovery-envelope
and funded restore gates above are still open.

Android unit tests and ARM64 APK/test APK assembly pass. The Settings navigation
regression passes on the opened foldable and its compact cover display, including
all three backup tasks, Back navigation and disabled import controls without a
key. Screenshots were inspected. A forced size/density override on the opened
foldable caused a Compose layout-idle timeout before reaching Settings; the actual
fold states pass with unchanged assertions. No real wallet was used.

Android CI `43841741884` passes both native architectures and API 35/36 at
`c2f6ce9`, which includes the earlier restore preflight fixes. This is separate
from validation of these newer UI changes. iOS CI `43841772329` still failed
SwiftUI type checking in `LightningView.body`. The next change separates the
navigation destination and dashboard from lifecycle modifiers; its older-CI
compiler validation is still pending. No release has been published.

Android CI `43842873294` also passes both native architectures and API 35/36 at
`9dee1c0`, with the unchanged active-window assertion and added package-only
failure diagnostics. This provides later CI passes without proving the cause of
the earlier two-platform capture failure. The new backup UI still needs its own
CI run. Local Android unit results are 81 passed and three opt-in skipped.

The native Apple simulator build, Tor/bundle/signature verification and three
selected UI tests pass locally: compact/landscape assistance and backup navigation,
Bridge entry and both directions, and Lightning layout. Backup screenshots were
inspected in compact and landscape layouts. `just checks` passes. This validates
the smaller Lightning view expressions with local Xcode, while a fresh iOS CI run
must still verify the compiler that failed previously. No physical device, live
payment, production service or store submission was changed.


## Android restore registration failure: 2026-11-16

Android now opens a restored database before committing its profile and selection,
matching iOS's installation order. If installation fails, it closes the attempted
session, confirms that registration did not commit, removes only that attempt's
new directory, and reopens the previously open wallet. An uncertain close or
unreadable registry preserves data and asks the user to restart. Restoring does
not automatically reconnect the node or chain backend.

A real AtomicFile write failure reproduced the previous bug: selection remained
unchanged while the native session was closed. The regression now passes, checking
JNI directly, profile/selection preservation, directory cleanup and successful
retry with receive-address continuity. All three AssistanceNativeTest cases pass
on an unfunded Android API 35 emulator, as do 81 unit tests (three opt-in skipped),
ARM64 APK/test APK assembly and `just checks`. Existing iOS code already reopens
the previous profile; no Swift/backend contract changed in this follow-up.

This covers a synchronous registration-write failure. It does not prove process-
death atomicity, cleanup when storage remains unreadable, iOS orphan cleanup, or
funded restore acceptance. Portable app payment/Bridge recovery records remain
missing from archives. No live funds or physical device was used.


## Backup preparation lifetime: 2026-11-16

Android now discards an export that finishes after lock, wallet change or backup
page cancellation. Discarded encrypted bytes are cleared; a late result cannot
restore its recovery key into UI state. Explicit navigation away from Save clears
the prepared export. A completed encrypted export still survives lock for Android's
document picker, while its displayed key is cleared. iOS now also checks an export
session token, so backgrounding and returning before an export finishes cannot
revive an invalidated key. Stale failures cannot clear a later preparation.

The delayed-export regression fails without Android's session check, then passes
for lock, cancellation, a fresh retry and the document-picker retention policy.
It uses an unfunded local profile and an injected exporter, with no payment or
file sharing. All four backup/assistance instrumentation cases and the Settings
navigation test pass on the unfunded API 35 emulator. Android unit tests, APK/test
APK assembly, the native iOS simulator build/bundle verification and `just checks`
pass. The Swift lifecycle race itself has not been driven through a UI test or a
physical device; native compilation is not evidence of that acceptance.

Android CI `43846778476` at `5d838fc` passes both native builds and API 35, but API
36 again fails the first onboarding capture. The new diagnostic reports active
accessibility package `android`, identifying a system window instead of a missing
root. It does not yet identify the dialog or its cause. Capture diagnostics now
classify known system dialogs and report only process-exit reason codes; no dialog
text, wallet content or traces are logged. The same assertion and timeout remain.
This failure remains unresolved. iOS CI `43846799937` is still running its native
build prerequisites; the older compiler follow-up is not yet verified.


## Native installation cleanup and current CI: 2026-11-16

A real filesystem failure reproduced orphaned iOS Keychain records after profile
installation failed. The adapter now confirms that the native session closed and
that the persistent catalog did not register the profile before cleanup. It removes
only records inserted by that attempt and a directory that did not exist before
it. Existing records and files remain intact. An unreadable catalog or uncertain
close preserves data and reports the need to restart. Connection insertion no
longer replaces an existing record. Validation occurs before the previous session
closes.

Three native XCTest cases pass in a minimal, isolated simulator host with real
Keychain access. The filesystem regression failed before the fix, then passed
cleanup, same-profile retry and a regtest receive address. The other case verifies
both key and connection collisions. A third case checks the previously open
native session directly and confirms its receive-address history survives. The
test host does not start the app, Tor or
network activity. An earlier standalone test target lacked Keychain entitlements;
its permission failure was not evidence of the application bug. Android stores
profile secrets and settings together in its registry; its corresponding restore
cleanup/reopen behavior was implemented in `646eaf3` and remains regression-tested.
Process death, persistent storage failure and funded recovery remain acceptance
gates. No shared Rust or REST contract changed in this follow-up.

At `861acae`, all 15 instrumentation cases across the ten CI test classes passed
locally on an
isolated ARM64 API 36 emulator. Its page size was verified as 16,384 bytes. This
includes native persistence, public wallets, restore failure/retry, backup
lifecycle, Bridge flows, adaptive layouts and actual wallet/settings screens.
This does not establish physical-device update acceptance or resolve intermittent
x86-64 CI failures.

Android CI `43849249118` passed both native architectures and both emulator jobs.
The later run `43850267919` at `861acae` passed API 35 and both native builds, but
API 36 failed with a confirmed system “not responding” dialog. The affected
process and cause are not yet known. The next diagnostic checks whether the dialog
mentions the app and records at most 16 main-thread method names and line numbers.
It does not log dialog text, arguments, local values or full system traces. The
active-window assertion and timeout remain unchanged. The diagnostic test APK
compiles; the failure branch has not been forced locally.

The old-compiler iOS follow-up is now verified by CI `43846799937` at `5d838fc`:
Swift tests, both Rust targets, device and simulator app builds, and bundle checks
passed. The workflow failed only because a Bridge UI test queried a Back-button
identifier absent from that runtime. The captured hierarchy shows the native
button with the preceding page label. The test now supports that observed label
and retains its hittability and return-navigation assertions. Verification on the
older CI runtime is still required. Passing local tests does not close live,
physical-device, signing, package-upgrade or coordinated release gates.


## New-profile registration parity: 2026-11-16

The follow-up also found Android creation/import paths that closed the previous
native wallet before a registry write, without recovery if that write failed.
Hot-wallet creation and public hardware/watch-only import now open the new database
before committing the profile, as iOS does. A failed operation closes the attempt,
confirms that registration did not commit, removes only its new directory, and
reopens the previous active session. An uncertain close or unreadable registry
preserves the attempted data. Legacy registered provisioning records still retain
their existing completion path.

A real AtomicFile failure reproduces the old bug with a direct JNI check. After
the fix, the same test passes for hot-wallet creation and hardware-wallet import,
including profile/selection preservation, directory cleanup and successful retry.
All six native assistance, public-wallet and backup-lifecycle cases pass on the
isolated API 36/16 KB emulator. Android unit tests pass (81 run, three opt-in
skipped), both APK targets build, and `just checks` passes. The iOS native tests
also pass all three cases, including a direct FFI check of the previous session.
An initial address-continuity test incorrectly requested a new address; the final
test checks persisted address history instead. It was a test error, not a wallet
identity regression.

No live payment, production service change, funded physical-device installation,
TLS policy change, release publication or additional usage reset occurred. Process
termination during installation and funded backup/upgrade tests remain open.

The complete native onboarding/navigation UI test also passes on a separate fresh
API 36/16 KB emulator after the creation change. An earlier run on the already-used
QA emulator could not find onboarding because its prior test wallet still existed.
That data was preserved. The UI test now checks that its QA app is empty and gives
a clear precondition error otherwise. No existing wallet is deleted to make the
test pass. Logs: `/tmp/android-create-after-runtime.log` and
`/tmp/android-create-fresh-ui.log`.


## Wallet-switch failure parity: 2026-11-16

Android now opens the selected wallet and reads its on-chain overview before it
commits the new selection. A missing database or failed registry write preserves
the prior selection and reopens its native session. No wallet directory is removed
by this recovery. Legacy provisioning completion commits with the successful
selection. iOS already opens before commit; its failure path now checks native
close and persistent selection, and reports prior-wallet reopen failures instead
of ignoring them. Both adapters preserve data and request a restart if the
selection commit or close is uncertain.

The Android regression reproduced the old bug: selection changed to a wallet with
an unavailable database. After the fix it passes both missing-database and real
AtomicFile write failures, verifies the previous session directly through JNI,
and successfully retries with the target address history intact. All seven
assistance/public-wallet/backup-lifecycle cases pass on the isolated API 36/16 KB
emulator. Android unit tests pass (81 run, three opt-in skipped); debug and test
APK assembly and `just checks` pass.

The iOS native suite passes all four cases. Its new switch regression temporarily
moves only its own unfunded fixture database, confirms both saved selection and
the already-open native session remain the original wallet, restores the file,
and verifies retry and target address history. Bundle verification passes. These
tests do not simulate process termination, an unreadable persistent catalog during
commit, a native close failure, or a funded physical-device upgrade. They do not
establish production readiness.


## Android committed-storage recovery: 2026-11-16

SecureStore no longer treats an absent base file as proof that a record is absent.
It first lets AtomicFile read and recover a committed legacy backup. This matters
for interrupted writes on supported older Android releases and for their upgrade
path. File-not-found returns no record only when neither the base nor backup
exists. Authentication failures and damaged storage still propagate as errors.
The encryption format, key policy and authenticated record names are unchanged.

The [Android 9 AtomicFile implementation](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/android-9.0.0_r1/core/java/android/util/AtomicFile.java)
uses the backup during write recovery. The
[current implementation](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/master/core/java/android/util/AtomicFile.java)
also handles that legacy backup. The prior base-file check bypassed this behavior.
A non-secret encrypted fixture reproduced the bug: its committed backup returned
no record. After the fix, recovery and a repeated read succeed; a modified GCM tag
still fails authentication. Both cases now run in the Android CI sequence.

All nine secure-storage, assistance, public-wallet and backup-lifecycle cases pass
on the isolated ARM64 API 36/16 KB emulator. Unit tests pass (81 run, three opt-in
skipped), debug and test APK assembly passes, and `just checks` passes. This is a
real AtomicFile/Keystore test with a simulated legacy interrupted-file state, not
an Android 9 runtime or physical power-loss test. iOS uses Keychain for these app
records and does not use this Android wrapper. Both development branches receive
the Android fix; no shared Rust/REST or iOS storage format changes are needed.
The separate uncertain-commit, process-death and funded-upgrade gates remain open.


## Wallet selection and saved payment status: 2026-11-16

Android previously committed a wallet switch, then read its payment journal and
connection settings through separate calls. A failed journal read could leave the
screen on the previous wallet while the native session used the target wallet.
Selection now prepares balance, network, connection and pending-payment state
before commit and returns them together. The screen applies that snapshot in one
state update. Invalid journal entries, including explicit nulls, are errors rather
than evidence that no payment exists. Invalid connection record types also stop
selection. Wallet-specific fee-review and recovery display state clears on a
successful switch.

The model regression reproduces the previous UI/native identity mismatch using
only unfunded profiles and encrypted test metadata. After the fix, malformed JSON,
invalid/null payment entries and an invalid connection record leave the original
wallet selected in both layers. Restoring the fixture metadata permits retry and
preserves the target wallet's unknown-payment warning. All 11 storage, native
assistance, profile removal, public-wallet, selection and backup-lifecycle cases
pass on the isolated ARM64 API 36/16 KB emulator. The existing interrupted-removal
test and the new selection test are now in the CI class list.

Both Settings UI tests pass, including switching between two owned fixtures and
returning to the correct dashboard with Send and Receive visible. The captured
screen was inspected. Android unit tests pass (81 run, three opt-in skipped), debug
and test APK assembly passes, and `just checks` passes. Logs:
`/tmp/selection-state-before-runtime.log`, `/tmp/selection-state-after-runtime.log`
and `/tmp/selection-state-ui-runtime.log`.

This change is specific to Android's combined screen/payment-journal loading path.
iOS publishes the selected profile before loading its balance and does not use
this Android journal. No shared Rust, JNI, REST or encrypted-record format changed.
The fix is mirrored to both development branches. Portable payment/Bridge recovery
archives and process-death/uncertain-commit acceptance remain separate open gates.


## Android failed storage commits: 2026-11-16

SecureStore now explicitly syncs staged data and verifies the committed ciphertext
before reporting a successful write. AtomicFile can log sync or replacement errors
without throwing. A nonempty fixture directory at the destination reproduced a
false success in the previous implementation. The updated code reports the failed
replacement, preserves the directory's unrelated contents, and permits a successful
retry after the test removes its blocker. Normal replacement also passes.

The process-wide storage lock covers reads, writes, deletes and key creation across
separate model instances. AtomicFile provides no locking itself; concurrent reads
can otherwise remove a staged write. Three concurrent test callers complete 36
replacements and reads without observing incomplete or unauthenticated records.
This serializes individual storage calls, not multi-call application transactions.
It does not provide cross-process locking; the app currently has one process.

All 13 storage, assistance, public-wallet, profile-removal, selection and backup
lifecycle cases pass on the isolated ARM64 API 36/16 KB emulator. Both Settings UI
cases pass. Unit tests pass (81 passed, three opt-in skipped), debug/test APK builds
and `just checks` pass. Before/after fault evidence is in
`/tmp/secure-commit-before-runtime.log` and `/tmp/secure-commit-after-runtime.log`.

This does not prove crash or power-loss durability. A failed confirmation can still
have an uncertain outcome; callers must preserve data and reconcile it. No automatic
payment retry was added. iOS already checks Keychain return codes and does not use
AtomicFile. The Android fix is mirrored to both development branches; encryption,
key policy, native engine and backup formats are unchanged. Actual Android 9,
process-death, storage exhaustion and funded-upgrade acceptance remain open.

The clean-install storage regression uses a new isolated AVD with no existing app
or device key. The corrected fixture provisions its key with a normal encrypted
write before creating the replacement blocker. All four cases pass in 0.416s
(`/tmp/clean-storage-runtime.log`). This changes test setup only; lost-key
protection remains enforced. API 35 and 36 CI artifacts confirmed the same setup
failure, rather than a sync/rename regression.


## Profile connection inheritance: 2026-11-16

Android hot-wallet creation, public-account import and encrypted restore now copy
and validate the selected profile's connection settings before changing sessions.
Previously a new profile fell back to the last global connection, which could
belong to a different wallet. The screen retained the selected profile's settings,
so its displayed server could differ from the backend's saved server. iOS already
copies the selected connection during profile installation. Existing Android
profiles and their settings are not rewritten.

Successful add/import/restore also clears the previous receive address, fee-review
issue and exit/expiry display state. Public import and full restore clear any
previously displayed recovery phrase. Connection credentials remain in encrypted
device storage; the archive format is unchanged and does not gain credentials.
No connection, sync or payment is initiated by copying these settings.

The model/native regression reproduced the old mismatch using distinct reserved
`.example` endpoints for the selected and legacy connections. With the fix, hot
creation, encrypted restore and public signer import agree with the screen,
retain the copied settings after native close/reopen, and clear the old receive
address. Switching back preserves the source settings. The public signer case
uses a testnet serialization of the existing public fixture and does not sign or
broadcast. The regression is included in the existing CI selection-test class.

All 14 storage/native/model/recovery cases pass locally. Fresh-install onboarding
and both Settings UI tests also pass. Android unit tests pass (81 passed, three
opt-in skipped), debug/test APK builds and `just checks` pass. Evidence:
`/tmp/profile-connection-before-runtime.log`,
`/tmp/profile-connection-final-runtime.log`,
`/tmp/profile-connection-ui-runtime.log` and
`/tmp/profile-connection-final-all-runtime.log`.

The Android change is mirrored to both development branches. iOS behavior was
checked in source and its existing native/UI CI passed at `2c75741`; there is no
new iOS inheritance-specific runtime test in this change. This does not resolve
portable payment/Bridge archives, cross-network server setup, post-commit metadata
read failures, uncertain commits or funded device acceptance. Those gates stay open.


## Failed storage deletion and alert settings: 2026-11-16

Android SecureStore now reports failed deletion instead of accepting AtomicFile's
silent failure. It removes backup and staging paths before the base record, so a
failed backup deletion cannot restore a supposedly removed record. Missing paths
are an idempotent success; nonempty directories and unrelated contents are never
removed recursively. Failures propagate to wallet-removal recovery instead of
reporting completed cleanup. This does not provide secure erasure or prove
power-loss durability. iOS already checks Keychain deletion return codes.

A real filesystem fault reproduced the old false success. Tests now block each
of the base, backup and staging paths in turn, check that failure is reported,
preserve marker contents and the base record when a sidecar cannot be removed,
then remove only the fixture blocker and verify successful, idempotent retry.

Payment alert settings also handle reset failure: the stored preference and toggle
remain unchanged, a short error appears, and retry can succeed after the storage
fault is resolved. A Compose test exercises this with a real blocked staging path,
restores prior alert preferences/state, and never requests notification permission.
The new test is included in CI. No payment, network or wallet-signing operation is
part of these tests.

All 18 storage, native, model and Settings UI cases pass on the isolated ARM64
API 36/16 KB emulator, including interrupted wallet removal and the new alert
reset/retry case. Unit tests pass (81 passed, three opt-in skipped), debug/test APK
builds and `just checks` pass. Evidence: `/tmp/storage-delete-before-runtime.log`
and `/tmp/storage-delete-final-runtime.log`. Both development branches receive the
fix. Broader process-death, uncertain-commit and funded-upgrade gates remain open.

The local release lint check first failed with unresolved references to unchanged
Kotlin declarations. A full non-incremental compile passed without source changes;
the normal `lintRelease` command then passed too. The lint report has zero errors,
41 warnings and two hints; this is not a clean-warning or release acceptance claim.
Logs: `/tmp/storage-delete-lint.log`, `/tmp/storage-delete-lint-full-compile.log`
and `/tmp/storage-delete-lint-recheck.log`. Build settings were not changed to
permanently disable incremental compilation.
