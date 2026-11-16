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

## Acceptance matrix

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
| Backups / upgrades | Encrypted full backups and scoped mobile wallet state | Complete volume backups | Restore tests, update migrations and desktop backup UX |
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
