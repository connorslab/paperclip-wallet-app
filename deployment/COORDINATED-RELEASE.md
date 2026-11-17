# Coordinated Paperclip release

The next major release includes iOS, Android, Umbrel, StartOS and signed Linux,
macOS and Windows desktop packages from one reviewed source revision. Android distribution includes **Google Play and a signed APK
download**. Prepare candidates independently, then publish in one coordinated
release window after every platform meets the acceptance criteria below. Store
review and propagation can finish at different times; do not promise simultaneous
availability to the minute.

The release version and date are not assigned yet. The current version numbers
(Apple build 70, Android preview code 4, server 0.10.0) identify existing candidates,
not a completed unified release. Do not reuse an uploaded build number, rewrite an
existing release tag, or replace a published binary in place.

## Current acceptance summary: 2026-11-16

The coordinated release is not ready. The table separates completed automated
checks from the required implementation and acceptance work.

| Area | Verified in the current test pass | Still required |
| --- | --- | --- |
| iOS | 123 shared Swift tests; 17 safe UI cases on both regular-phone and open-Duo simulators | Physical signer, camera, accessibility and interrupted/folded payment acceptance; final signed candidate and upgrade |
| Android | 100 JVM tests (four live cases excluded); 16 isolated API 35 UI cases; 46 API 36 ARM64 cases (including one visibility negative control); authenticated CLN/LND reads and pin rejection; API 35/36 CI passed at `98a1116` | Final release identity, Play/APK upgrade compatibility and physical/foldable acceptance |
| Shared desktop UI | All 17 existing browser-flow suites plus entropy, transport and QR checks; phone, foldable and desktop widths where each suite defines them | Installed-host and native desktop acceptance; complete multiple-hot-wallet and hardware-funded Ark workflows |
| StartOS/Umbrel | Shared REST checks, authenticated CLN/LND reads; both StartOS candidate architectures built and source/checksums checked | Complete backup/restore, candidate installation, bundled Jam pairing/revocation/Tor and upgrades; matching frozen wrappers |
| Linux/macOS/Windows | Isolated Apple Silicon and Linux daemon authentication, duplicate-instance rejection and crash/restart checks | Native launchers and bundled service lifecycle, supported OS matrix, signed installers, notarization where applicable and clean install/upgrade tests |
| Jars | Reviewed direct/CoinJoin toggle and bond funding/withdrawal clients; pinned signer, API, bond and interrupted-submission checks; encrypted Jam volume restore on a synthetic chain | Live CoinJoin, direct-send and bond-funding/withdrawal acceptance, installed payment-pairing acceptance, live maker and physical QR signer acceptance |
| Payments and recovery | 291 shared wallet tests, exact-cost/RBF/unknown-outcome checks; unified-signature and Electrum-header checks | Live BOLT12/Ark/Bridge settlement, portable recovery/restore and current-source XBT consensus acceptance |

The saved uncertain Ark attempt remains reserved in the private payment ledger.
A failed sender plus an unavailable receiver record does not justify a retry or
release of that reservation. The upstream protocol suite still has its documented
36 failures against bitcoin fixtures/kernel; this result is not a passing XBT
consensus test. No candidate was installed or published in this test pass.

The additional support-crate suite passes 136 tests. RPC cookie rotation passes
in direct and SOCKS configurations; the transport tests reject redirects and
check that HTTPS starts with TLS rather than plaintext credentials. Two new Jam
tests terminate a writer without cleanup on either side of the durable submission
boundary. The copied pending journal cannot replay or cancel an uncertain payment.
The local Jam suite passes 45 cases with one container-only case skipped. Both
architectures also pass the bundled Jam CI run at `86c1245`. This does not establish full host-volume backup/restore or power-loss acceptance.

### Hot-wallet entropy choices

Paperclip hot-wallet creation now offers secure system randomness and physical
D6/D12/D20 dice with 12- or 24-word phrases in the shared StartOS/Umbrel/native
desktop UI. Secure random remains the default. The dice derivation and minimum
roll counts match iOS and Android; every supplied roll contributes, up to 1000.
Mobile also retains optional local sensor input mixed with system randomness.
Sensors never substitute for secure system randomness or claim extra entropy.

Desktop creation checks host support before submission and binds the selected
source and phrase length to the review. Its distinct creation route prevents an
older host from ignoring the selection, including during a version change. It
refuses ordinary plaintext LAN dice submission, invalid rolls and ambiguous
retries. Hidden-page and lock transitions
clear the private input. The native daemon rejects malformed choices before it
creates keys. Existing API clients without a selection retain their prior behavior.
The OpenAPI specification and client were regenerated. Shared source changes are
mirrored to the Android branch; installed packages still require a new candidate.

Validation includes matching mobile/Rust dice vectors, invalid-source rejection,
browser flows at 390/840/1280px, native daemon HTTP checks, 112 Swift tests, Android
JVM tests and an ARM64 iOS simulator build. iOS now rejects missing sensor input
instead of silently falling back to system randomness. Android also rejects an
unknown source and clears dice input on backgrounding. Generic Intel simulator
linking exposed the existing ARM64-only Rust library search path; it is not covered
by the successful ARM64 build and remains a native toolchain limitation.
Android, regular-phone and Duo preparation-screen checks verify source switching,
disabled generation without required input, and cancellation without creating seed
words. The test uses the sheet's own scroll view and scrolls toward each control.
Initial harness attempts selected the underlying view on Duo or dismissed the
compact sheet with a downward swipe; both test assumptions were corrected.
The corrected regular-phone test passes. A final Duo harness rerun stalled before
test execution during severe host CPU/memory pressure and was stopped. The earlier
Duo pass remains the available evidence; the final rerun is not counted as a pass.

Android CI at `7940fbd` passed API 35 but failed API 36 during the onboarding
capture: the emulator showed a System UI not-responding dialog. The app main
thread was idle, with no recorded app process exit. That run remains failed.
The later `7c97c3d` run `43981075219` passed Android CI, including both emulator
jobs. Backend run `43981075178` and browser run `43981075345` also passed at that
revision. These results precede the following Jars changes.

### Jars fees, market comparison and unsent review recovery

The Jars overview now separates four tasks: Maker settings, Market fees, Fidelity
bond, and How earning works. iOS opens native navigation pages; Android opens a
focused sheet; the shared desktop UI uses a keyboard-accessible dialog. The long
inline form no longer pushes market comparison and bond setup down the overview.
Maker settings keeps the next required step, expandable checks and review action
together. iOS amount inputs have persistent labels and a separate sats unit.
Fee drafts survive moving between these pages; comparison never changes the offer.
Changing the wallet/session closes the task screen and pending confirmations.
The existing readiness and review requirements remain in place.

Fixed-sat and percentage maker fees now use the pinned JoinBlaket grid on iOS,
Android and the shared desktop/StartOS/Umbrel UI. Percentages include a worked
example and stay exact through the restricted pairing proxy. Unsupported or
mixed fee modes fail before submission. Collapsed setup help explains jar coins,
bond coins, lock dates, backup, public funding traceability and server availability.
Default takers require a bond; funding and withdrawal are still separate gates.

Each client can show a read-only median at the selected comparison amount.
The host compares one lowest supported offer per verified, current bonded maker.
It normalizes relative and fixed fees to sats and excludes mining contributions.
The comparison amount is independent of maker settings, including while the maker
runs. The comparison shows the maker count and fetch time. Stale, missing or malformed
snapshots cannot become a zero median. A refresh does not alter the user's fee.
This is a comparison of advertised fees, not an earnings forecast. The live
packaged watcher and maker have not been exercised in this pass.

The owner desktop UI and independently authorized mobile connections can discard
an unsent Jam review after confirmation. The companion still rejects cancellation
past the durable submission boundary. Restricted management pairings remain
unable to discard reviews and direct the user to the host. Unknown submissions
remain visible; a timeout never automatically repeats a request. Desktop maker
confirmation also rejects a review after the wallet session ends.

Local validation: 115 shared Swift tests; 91 Android JVM tests with four opt-in
live cases skipped; 11 targeted REST tests; 52 Jam companion tests with one
container-only test skipped; native Apple ARM64 simulator compilation; repository
prechecks and type checks. Phone/desktop browser coverage includes percentage
conversion, market states, unchanged fee selection and discard recovery. Synthetic
screenshots were inspected. Five Android API 35 Jars UI cases pass, including
market display and fee preservation. Two regular iPhone simulator cases verify the percentage example, expandable
checks, comparison controls and portrait/landscape bond guidance with network
actions disabled. These checks do not replace live host, physical signer, settlement,
fold transitions or signed-release acceptance.
Bundled Jam CI run `43987338446` at source `dc6b9e4` passes all 53 tests on both
Linux architectures, including the new order book reader in the pinned container.
Backend and full browser CI also pass at `dc6b9e4`; Android CI remains in progress
at this checkpoint. These runs precede the task-screen redesign.

The task-screen redesign passes three regular iPhone simulator UI cases and all
five Android API 35 Jars cases. Checks cover separate destinations, retained fee
drafts, canceled reviews and portrait/landscape bond guidance. Browser Jars tests
pass at 390/1280/1440px, interrupted setup/backup tests at 390/1280px, and the shared
web contract suite passes. Native screenshots were inspected. These are synthetic
checks, not live maker, payment or installed-host acceptance. No physical device,
funded host or published candidate was changed.

### Reviewed direct jar payments

The owner desktop UI and independently authorized mobile Jam connections now have
fixed-amount direct sends from the selected jar. Preparation returns an exact
recipient amount, fee, total debit, expiry and approval before the separate Send
button. All adapters bind the wallet identity, jar, destination, amount and fee
limit, check the saved approval again, and never automatically repeat a commit.
An interrupted response directs the user to saved payment activity. Node acceptance
is displayed as submitted, not confirmed. Unsent reviews can be discarded.

The jar send form now supports both direct and CoinJoin payments. The selected
mode is immutable through review and commit; unsupported servers are rejected
before preparation, and failed CoinJoins never fall back to direct sending.
Existing management-only phone pairings remain unable to prepare, commit or cancel
payments. Explicit spending grants are described below.

### Reviewed CoinJoin jar payments

Companion capability version 2 negotiates a fixed-amount CoinJoin using the pinned
Jam taker. Its final callback captures the signed transaction and always declines
automatic broadcast. The private journal saves those exact bytes; only a separate,
durable commit can broadcast them through the owner's Jam node. The install step
also verifies the taker source hash before enabling this integration.

Each client binds the mode, recipient, jar, amount, wallet identity and total fee
limit. Review shows maker fees, the owner's mining share, maker count and total
debit. CoinJoin transactions are non-RBF. Cancellation retains upstream input
safety reservations; it does not promise immediate reuse. Commit rechecks every
participant's unspent input and renews only the original wallet input leases.
Unknown submissions survive restart and cannot be sent again by another commit.
Preparation has a bounded three-minute window, with client timeouts long enough
to receive the result. Signed transaction bytes never leave the companion.

Validation: 118 Swift tests; 95 Android JVM tests passed with four live cases
skipped; 12 targeted REST tests; six synthetic Android Jars UI cases, including
CoinJoin review and lost-response recovery; regular iPhone toggle/preview test.
Browser direct and CoinJoin send tests pass at 390/1280px. The pinned local Jam
suite passes 64 tests with one container-only case skipped, including the actual
taker final-confirmation method, real XBT-signed fixture transactions, successful
single commit, interrupted commit/reopen and cancellation. Repository checks pass.
Visual inspection caught a retained Android keyboard covering review controls;
review now clears focus and closes the keyboard, and the test uses the actual
bottom-sheet container. Android initially lacked the SDK environment; rerunning with the existing SDK
resolved it. A REST compatibility assertion initially caught an added field in
legacy recovery records; preserving their original shape fixed it.

These are synthetic and local checks. Live CoinJoin/direct settlement, mobile
spending pairing, bond payment flows, installed-host acceptance and signed
packaging remain release gates. No payment, funded-device
installation, production service change or publication occurred in this pass.

Both Linux architectures subsequently passed all 65 companion cases in bundled
Jam CI run `43997362986` at `9031c81`, including the pinned taker source guard.
The follow-up client polish shows explicit preparation/submission progress and
resets the review to its top after leaving a scrolled form. These visual changes
do not alter the tested companion or submission contract.

## Source and artifacts

### Native desktop distribution gate: 2026-11-16

The owner added signed Linux/macOS/Windows releases to the coordinated release.
Reuse the shared StartOS/Umbrel frontend and wallet backend, including Jars,
CLN/LND, Bridge, recovery and QR signing. Do not introduce a reduced desktop fork.
Packaging must preserve private data and expose the local service only on loopback;
local authentication, browser-origin protections and secure launcher handoff remain
required. Bundled Jam must have an explicitly supported lifecycle on each OS;
a Docker prerequisite alone is not accepted as equivalent native packaging.

Required before release:
- Define and build the supported OS/architecture matrix from the frozen revision.
- macOS: Developer ID signed and notarized app/installer, stapled ticket, Gatekeeper
  acceptance on a clean supported Mac and verified in-place upgrades.
- Windows: signed executable and installer using the release publisher identity,
  signature-chain/timestamp verification, clean installation and in-place upgrades.
- Linux: distributable packages for the documented supported systems, release-key
  signatures over artifacts/checksums, and clean-install/upgrade validation.
- Verify daemon startup/shutdown, private file permissions, Tor/TLS, bundled Jam,
  full backup/restore and offline recovery on each OS. Never leave a second maker
  running after an upgrade, restore or launcher restart.
- Verify that uninstall/update preserves wallet data by default, existing keys and
  connection settings are retained, and failed updates can recover safely.
- Include immutable downloads, checksums, source/license notices and signing
  provenance alongside mobile and host-package artifacts. Do not publish until
  these gates and the existing payment/security gates pass.

Signing identities and actual supported OS versions remain to be verified. No
native desktop candidate has been accepted merely because the shared UI builds.

### Current release blockers and Jars scope: 2026-11-16

The owner requested bundled JoinBlaket hosting in Paperclip's StartOS and Umbrel
packages. A separate Kilombino app must not be required. Desktop Paperclip must
manage all five jars, receiving, fidelity bonds and maker activity itself; mobile
Paperclip pairs with that same hosted wallet. JoinBlaket retains separate keys,
wallet files and backup state from Paperclip's hot wallet. The older remote-Jam
client and proxy are useful foundations, not completion of this requirement.

Before a coordinated release, complete and accept:

- Bundled, pinned JoinBlaket runtime on both server architectures, restricted
  node RPC access, TLS, complete-volume backups, and authenticated mobile pairing.
- Consistent desktop/mobile Jars setup, bond review and funding, maker controls
  and uncertain-action recovery. Creating a bond address must never fund it.
  Bond setup must identify the wallet, amount, unlock date and fees explicitly.
- Payments from Jam, including exact-cost direct-send review, bond withdrawal,
  CoinJoin payment limits and durable recovery, are required before release.
  Bundled hosting, mobile pairing and bond management have priority over optional
  polish. Remote-Jam support alone does not satisfy these requirements.
- Each jar send has a Direct/CoinJoin slider on every platform. Its choice is
  bound to the reviewed intent, fees and recovery record. A failed/unavailable
  CoinJoin must never fall back to a direct transaction without a new review.
- QR signing targets both privkeyio's XBT SeedSigner and Paperclip's XBT Krux.
  It must overlap safely with Jars: deposits from selected hardware
  wallets, all five account paths, and separately verified bond registration,
  certificate and matured-withdrawal support. Never import a cold seed into Jam
  to make a missing hardware flow appear supported. Automated makers still need
  online signing for their active jar coins; cold bonds have a separate role.
- Portable mobile pending-payment and Bridge recovery records; migration,
  interrupted-restore and full backup/restore acceptance on both host platforms.
- Remaining desktop multiple-hot-wallet and hardware/QR-funded Ark workflows;
  physical Krux signing, device accessibility and foldable/Duo acceptance.
- Live CLN/LND, BOLT12, Ark and both Bridge directions, including failed/unknown
  outcome reconciliation. Read-only node probes do not establish settlement.
- One frozen source revision and matching wrappers, final security/regression
  checks, Android Play/APK signing identities, Apple eligibility and signed
  candidates, clean installs and in-place upgrades. Passing builds are insufficient.

Build 73 is a locally installed iPhone test candidate. The StartOS test package
has not been installed; its complete backup is awaiting local authentication.
The latest UI source adds Jars as the fifth primary destination, after Lightning,
and retains Kilojoin recovery under Experimental on mobile. The server bundling,
bond wizard and mobile pairing requirements above remain open.

Desktop Jars remains accessible when a hot, QR or watch-only account is selected.
It identifies the separately authorized Jam wallet and preserves its session when
the main account changes. Only the two fixed JoinBlaket routes bypass the public
account's hot-wallet restriction; hot-wallet sends remain blocked. Browser
fixtures verify receiving into every jar for all three account types, maker
eligibility and uncertain-action handling. These checks do not establish live
Jam connectivity, bond funding or bundled-service acceptance.

The next Jars increment implements reviewed bond-address registration on iOS,
Android and the shared desktop UI. Users select an unlock month, review the Jam
wallet and first-of-month UTC lock date, then generate/share the address. The
operation registers an address only; it cannot fund a bond, start a maker or
broadcast a payment. All adapters reject past/unsupported months, check the
active Jam wallet and avoid automatic replay. Editing the date clears the old
address. Amount/fee review and funding remain in the sending wallet; guided
in-app funding, confirmed bond eligibility and live maker acceptance remain open.

Validation: eight Swift adapter tests, eight Kotlin adapter tests, the Rust UTC
month-boundary test, browser review/cancel/timeout checks at phone and desktop
widths, native iOS portrait/landscape UI tests and Android APK/test-APK compilation
passed. The Android bond layout test has since passed on the emulator, including
the review/cancel/date checks. No live bond was registered or funded.

The Kilombino runtime index was independently fetched from GHCR on 2026-11-16:
`ghcr.io/kilombino/jam-xbt:0.43.0-xbt7@sha256:f6f4a194a6f20ac56949b02f2a92032bad29dc5e466a4938838951a2960a217d`.
Its content hash matches and it contains linux/amd64 and linux/arm64 manifests.
This closes image identification only. The host package still needs separate
Jam data/backups, a restricted RPC filter, verified internal TLS trust, runtime
health, mobile pairing, licensing/source distribution and installation tests.

The unshipped companion now has a hash-guarded extension for reviewed direct sends
and bond funding/withdrawal. Twenty-five tests pass locally and in both AMD64 and
ARM64 Linux containers ([run 43924197397](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43924197397)),
including real pinned Jam signing and HTTP routes against a synthetic chain,
wrong-wallet/session rejection, stale/frozen coins, mutation exclusion and
uncertain-broadcast lookup. The journal records the submission boundary durably
and never replays it. The optional Umbrel generator isolates Jam data, filtered
node credentials and public TLS trust; its three package tests pass. StartOS
bundling, installed host backup/restore, pairing, client flows and live acceptance
remain open. No real funds or production services were touched for these tests.

QR Signer setup and payment instructions name both privkeyio XBT SeedSigner and
Paperclip XBT Krux across the mobile and shared desktop clients. Actual signer
source generates the public test vectors for all five jar paths and bond funding;
seven shared verification tests pass. The verifier also checks Jam's exact CLTV
bond witness, including dates after 2038. This does not establish hardware bond
withdrawal support: SeedSigner's pinned review parser rejects that script, and
Krux's complete descriptor/review workflow remains unaccepted. Physical camera
round trips and cold-bond registration/certificate delegation remain release gates.

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

The Jars recovery layout now emphasizes the amount, separates mining fee and total
debit, uses compact status badges and groups long references behind labelled
details. Mobile status checks use a full-width primary button; Android has a
stable-height navy sheet with an explicit Done action. Status transitions respect
system motion preferences. The shorter Submitted badge retains the explicit
"Confirmation has not been checked" explanation. Native UI and browser regression
checks preserve unknown outcomes after lookup failures and never resend payments.


Jars now has a separate payment-recovery view in iOS, Android and the shared
StartOS/Umbrel browser UI. It loads this Jam wallet's saved Paperclip payment
records and checks the exact transaction after an uncertain submission. These
operations cannot prepare, commit, cancel or replay a payment. Node observation
is labelled separately from confirmation; a lookup failure retains the saved
unknown outcome. All clients validate wallet, payment ID, known states, jar,
purpose, destination, transaction reference and exact integer amounts. The browser
proxy strips approval digests, inputs and private wallet-identity fields.

This closes the read-only recovery-view increment, not the Jam payment release
gate. Direct/CoinJoin send review, cancellation of unused reviews, bond funding
and withdrawal flows, scoped pairing, host install/backup/restore and live
settlement remain unaccepted. The history requires the Paperclip Jam companion;
a missing companion is an error, never an empty history or a legacy-send fallback.

Validation: ten Swift and ten Kotlin adapter tests, shared Rust contract cases,
three Android Jars emulator tests, iOS simulator recovery and compact-grid tests,
and browser Jars/navigation fixtures passed. The pinned runtime's 25 synthetic
signer/journal/HTTP tests passed. These do not establish live settlement or an
installed StartOS/Umbrel package. No funds or production services were touched.

The shared UI pass extends the amount-first review to mobile Lightning and QR
signer payments, preserves invoice/fee drafts when editing, and keeps confirmation
guards intact. Android receive/signing QR display is capped on wide screens.
Shared card spacing, menu feedback, and server Settings columns are consistent;
server recovery guidance now follows the selected hot or QR account correctly.
Native simulator/emulator checks and mocked browser workflows passed. These are
presentation checks, not installed-host, physical-signer or live-payment acceptance.


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


## Shared payment and page styling: 2026-11-16

Jars recovery now reuses the native payment amount headers and fee rows already
used for hot-wallet, Lightning and QR-signer reviews. Its caption is “Payment
amount”, not a claim that the recipient received funds. Unknown and submitted
states retain their recovery warnings and never display a confirmed receipt.
The shared server UI uses the same visual hierarchy and review/receipt surfaces.

Common cards use consistent corners, lighter shadows and tighter insets across
iOS, Android and the shared StartOS/Umbrel frontend. iOS primary buttons use a
deeper orange behind white labels. Desktop grid children no longer add their own
vertical margins on top of the grid gap. Existing native text scaling, touch
targets, keyboard navigation and reduced-motion behavior are preserved.

This is presentation work, not acceptance of bundled hosting, payments or signed
release packages. The release blockers above remain open. Runtime evidence and
synthetic preview provenance are recorded with the working-state artifacts.

The follow-up alignment pass also uses the shared wrapping fee rows for main
wallet sends, groups Android Lightning review details consistently, centers its
edit action, and gives iOS receive Copy/Share equal-width actions that stack at
accessibility text sizes. The receive preview is simulator-only and synthetic.

Validation: 14 Android UI cases passed, followed by all three payment-flow cases
after the final review alignment. iOS initially passed 14 cases and skipped the
opt-in live-node case; two onboarding cases could not find the creation page on
the retained QA simulator. Both onboarding cases passed on a fresh simulator,
along with three review/recovery cases. The final two review cases passed again
after fee alignment. Receive actions were visually checked at standard and
accessibility XXXL sizes. Browser navigation, Jars, CLN/LND, Bridge receive and
between-wallet transfer fixture suites passed; `just checks` passed. This is
simulator/emulator/browser evidence, not physical-device or live-node acceptance.


## Bundled Jars host isolation increment: 2026-11-16

The Umbrel candidate now keeps the wallet as the network-namespace owner. Jam
joins that namespace; the wallet and its app proxy no longer depend on Jam's
container. Failed Jam startup leaves wallet recovery/settings reachable.

The StartOS RPC supervisor copies the dependency's rotating credential into a
private filter-only directory. The HTTP listener drops to uid/gid1001 with no
new privileges and no Linux capabilities; Jam receives only the separate filter
client cookie. The listener is loopback-only and enforces the pinned RPC allowlist.
Read/rotation failures stop the listener rather than keeping stale credentials
in use. Public TLS certificate handoff and separate runtime data remain intact.

The native StartOS wrapper is being updated to include the companion with its
own data, filter-cookie and public-certificate volumes, a disabled-by-default
setup action, and complete-volume backups. This does not close installed-host,
mobile pairing, backup/restore, Jam send/bond or live payment acceptance gates.


## Activity receipts and bundled-runtime checks: 2026-11-16

Activity details now share the payment-review amount hierarchy and wrapping
detail rows on iOS and Android. Android replaces its plain-text receipt dialog
with a scrollable receipt sheet; Done remains fixed, sharing stays available,
and explorer links require a valid on-chain transaction ID. The server Activity
cards use the same surfaces and spacing. Amounts are labeled Balance change;
unknown and pending records retain recovery guidance and never imply settlement.

Validation: three selected native iOS UI cases passed (assistance/health/backup,
send review and Jam recovery). Seven Android receipt/payment/Jars cases passed,
then the four payment-flow cases passed after adding a synthetic receipt capture.
The receipt case checks a maximum-sized amount, doubled text size and reachable
Share/Done controls. Browser Activity fixtures passed at 390, 800 and 1280px.
Native builds, visual review and just checks passed. This is isolated UI evidence.

The pinned Jam container suite now passes all 30 cases on AMD64 and ARM64:
[run 43950368119](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43950368119).
It includes the real restricted RPC listener, atomic dependency-cookie rotation,
uid/capability isolation and child shutdown. A first test run failed because it
tried to read the protected child environment; the corrected test requires that
access to be denied. No runtime security restriction was relaxed. Installed
StartOS/Umbrel acceptance and the other release gates remain open.


## Scoped Jars phone pairing: 2026-11-16

The shared desktop UI can issue, list and revoke wallet-bound phone pairings.
iOS and Android review the server, wallet and scope before verifying and storing
the private code in Keychain/device-bound encrypted storage. QR codes stay local,
are hidden on navigation/background/lock, and are never put into a URL. The
separate Jam-server connection remains available. Restoring onto another phone
requires a new pairing; these grants are deliberately not portable seed backups.

The host stores only hashes of phone bearer tokens plus its private upstream
credential in a 0600 file. Each grant binds the configured upstream and the Jam
wallet's full public-key/chain-code commitment, expires within 30 days, and is
checked on every dispatch. Revocation prevents new requests; it cannot undo an
action already accepted upstream. A phone grant is not a main-wallet credential.

The first draft reused Jam's ordinary access JWT. Inspection of the pinned runtime
showed a 30-minute expiry, so it was replaced before committing. The companion
now issues a separate memory-only host delegation with an explicit route allowlist.
It mints an ordinary short JWT only inside an allowed request; original JWT
lifetimes stay unchanged. Wallet lock, generation/key change, daemon restart and
expiry invalidate delegation. The opaque host credential never reaches a phone.

This scope permits balances, receiving, bond-address registration, reviewed maker
controls and saved-payment observation. It cannot create/unlock/export wallets,
prepare/commit/cancel payments, or acquire another delegation. Paired payments
and bond funding/withdrawal still require their own reviewed integration before
release. Bundled first-run wallet creation and installed-host pairing/Tor/TLS,
revocation, restart and backup/restore acceptance remain open.

Umbrel keeps app login enabled and exempts only `/api/v1/paired-jars/request`
from its additional browser-cookie login; that route enforces the scoped bearer
itself. The setting was checked against the official
[app gateway source](https://github.com/getumbrel/umbrel/blob/master/packages/umbreld/source/modules/app-gateway/app-gateway.ts).
Owner APIs and raw Jam endpoints are not exempted. Actual Umbrel proxy acceptance
remains required. Native StartOS exposes no new Jam interface.

Validation so far: the complete shared REST suite passed 76 cases with one live
case ignored. Swift passed 12 Jam adapter cases; Kotlin adapter tests and APK
builds passed. Four Android Jars UI cases and native iOS pairing review/cancel
and recovery cases passed. Browser fixtures passed at 390/1280/1440px, including
HTTP rejection, private QR hiding and grant revocation. The pinned runtime suite
passed 32 cases locally with one Linux-only case skipped; it covers delegation
expiry/lock, denied export/unlock/send routes and independent ordinary JWT expiry.
Three package-generator cases passed. Container CI and installed-host acceptance
are separate checks, not implied by these results.

The scoped pairing container suite subsequently passed all 33 cases on AMD64 and
ARM64 ([run 43956779853](https://github.com/connorslab/paperclip-wallet-app/actions/runs/43956779853)),
and browser CI passed at source `c70ab3061cf1d64ee6fe894489a897062f0a72f2`.
The StartOS test wrapper `09b86708f2caa412f40a024d4536c270035db4ef` pins that
source as candidate `0.10.0:3`. Its package workflow and installed-host acceptance
are not covered by the container-suite result.

## Bundled Jars first-run setup: 2026-11-16

The shared owner UI can create a separate Jam wallet, then guide password-verified
recovery-word backup and confirmation. No creation or backup action sends funds.
Normal creation/unlock replies strip recovery words and refresh tokens. The
explicit backup operation checks the Jam password again and projects only the
selected wallet's validated phrase and authorization. Responses are not cached.
Phone grants continue to deny creation, unlock and backup; no new mobile privilege
was silently added.

After interrupted creation, the browser retains only the filename, checks whether
that wallet exists, and requires a fresh review with the same filename before
retrying. The pinned daemon refuses overwrites. Recovery words stay in memory and
are removed on close, navigation, tab hiding and lock; late hidden-page responses
are discarded. The pending filename is a session reminder, not a server-side
backup record. Full-volume backup/restore and installed-host acceptance remain
required. Sending from paired Jars and CoinJoin payment reviews remain open.

The real pinned-runtime suite passes 34 cases locally with one Linux-only case
skipped, including encrypted creation, 0600 wallet files, password checks, backup
during a pending payment, denied delegated `/getseed` and preservation of existing
wallet files. No live wallets or payments were used. Browser fixtures pass at
390/1280px for interrupted creation, same-name retry, backup verification and
secret clearing. Existing Jars and CLN/LND browser cases also pass. The broader
web suite covers navigation, hardware wallets, payment review, RBF, Bridge and
uncertain-send recovery. Swift's 12 Jars adapter tests and Kotlin adapter tests pass.

The complete REST suite passes 77 cases with one live case ignored. Its first run
exposed a wall-clock-sensitive Bridge-expiry fixture; a test-only thread-local
clock now expires the quote during the actual TLS preflight. The test asserts both
preflights occurred and no payment intent/send was created. Production clock and
expiry behavior are unchanged. Container CI and installed-platform acceptance
must still verify this source revision before release.

## Native desktop prerequisites: 2026-11-16

The shared daemon builds natively on this Apple Silicon Mac with the current web
UI embedded. A fresh, unfunded native smoke test verifies owner authentication,
denied unauthenticated access and cross-origin preflights, 0700/0600 files,
graceful shutdown and authentication preservation across restart. It creates no
wallet keys or payments. The reusable check is in
`deployment/desktop/test_native_daemon.py` and is included in the Linux candidate
image workflow with networking disabled. This is daemon evidence, not a signed
macOS app, installer, launcher or upgrade/restore acceptance.

Windows Jam portability remains an explicit blocker: the pinned runtime and
companion use POSIX fcntl locks. Windows needs reviewed equivalent locking or a
managed bundled runtime; removing locking is not an acceptable substitute.
Linux/macOS/Windows signing, native packaging and the other desktop gates above
remain open. A separate regression test also prevents the bundled host's loopback
Jam API address from becoming a broken browser handoff link.

## Regression and source-provenance checkpoint: 2026-11-16

At shared source `69c0cd8ae058dd1684139579ba888d305f53f8aa`, the complete REST
suite passes 78 cases with one live case excluded; the mobile Rust suite passes
31 with one excluded. Shared Swift tests pass all 112 cases. Android JVM tests
pass 88 cases with four explicitly opt-in live node/payment/reconciliation cases excluded.
Android CI at `f217f63` passed both emulator API levels and native architectures;
Jam CI at `168a247` passed both Linux architectures. These results do not replace
live settlement, physical signer, host restore or signed desktop acceptance.

A StartOS provenance defect was found before installation: candidate `0.10.0:4`
named a newer source in its manifest while the test workflow still checked out an
older revision. Its run was cancelled; do not accept its artifacts. Wrapper
`4126111c70b8954888be18c639550430b99f0f6a` derives the checkout directly from the
manifest, rejects mismatched or modified source, checks the compiled daemon's
revision and retains provenance beside the package. Candidate `0.10.0:5` pins
`69c0cd8`; its packaging and installed-host gates remain pending.

Local desktop builds also now watch Git refs, including linked-worktree refs, so
cached Cargo builds do not report an earlier commit. Rebuilding after a commit
without another source edit was verified to update the binary's reported hash.

Duo UI tests exposed incorrect single-display and bottom-tab-bar assumptions in
the test harness. Corrected checks target the active viewport, content scrolling,
side-rail controls and native Back controls. Previously failing health/backup,
large-text recovery, bond, dashboard and tab-navigation checks pass in targeted
reruns. A fresh iPhone 15 Pro Max simulator subsequently passed all 17 safe UI
cases. Its first XCTest run aborted while loading accessibility before Paperclip
launched; an isolated reboot, app launch check and retry resolved the runner issue.
The failure record is retained. Physical-device and fold-transition acceptance
remain separate from these UI tests.

The current Android and shared server adapters also passed authenticated CLN/LND
identity and repeated balance reads against the authorized StartOS fixtures,
including rejection of wrong certificate pins and successful recovery afterward.
The Android live harness now rejects fixtures missing either LAN node; an empty
fixture was verified to fail before network access. These are read-only checks,
not settlement acceptance. No live payments, physical-device updates or funded
service changes were made.

A synthetic node endpoint draft survived open → closed → partially open → open
transitions on the Duo simulator. The closed form remained scrollable to its
confirmation control. No verification or payment was submitted. QR/camera,
keyboard, locking and live pending-payment transitions still require acceptance.
Read-only reconciliation of the saved Ark attempt found a failed sender and an
unavailable receiver record (HTTP 404). This does not establish settlement or
fee recovery; the existing budget reservation remains unchanged.

The pinned Jam runtime now has six real-signer bond cases: exact registered
funding output, wrong date/destination and ordinary-send rejection, date expiry
between review and commit, chain-time maturity, actual CLTV witness, and post-review
maturity/freeze revalidation. Three additional recovery cases cover task
cancellation on either side of submission and disk failure after broadcast,
including reopen of the durable journal and proof of no second broadcast.
The local companion suite passes 43 tests with one container-only test skipped.
Both Linux architectures passed all 44 cases at `336a24e` in CI run
`43971866514`; live bonds, client payment flows and physical signer acceptance
remain open.

## Device UI and candidate evidence: 2026-11-16

- A complete open-Duo run passed all 17 safe UI cases; the regular-phone run
  separately passed all 17. Android API 35 passed four payment UI cases and all
  twelve additional Jars, CLN/LND editor, health, Bridge and adaptive-layout cases.
  These used isolated/synthetic fixtures and do not replace live or physical-device
  acceptance.
- Android's multi-class Gradle invocation executed only its first requested class
  despite reporting success. The remaining classes were run explicitly and all
  passed. CI already runs one class at a time; it now also rejects missing, stale,
  skipped-only, failed or wrong-class XML evidence and includes the CLN/LND editor.
- All 291 shared wallet unit tests passed, including RBF recipient preservation,
  authority scoping, restart, stale input and receipt-persistence failure cases.
  Jars setup/recovery, fee replacement, durable submissions and wallet-race browser
  suites passed at phone and desktop widths with the installed Chrome channel.
- StartOS run `43965162919` produced both candidate `0.10.0:5` architectures.
  Downloaded checksums and source records match wallet `69c0cd8` and wrapper
  `4126111`. Neither artifact has been installed or accepted for release. They
  precede the test-only additions at `336a24e`; final frozen-source rebuild,
  installed backup/restore and payment acceptance remain required.
- Local Apple signing inventory contains Apple Development and Apple Distribution
  identities, but no Developer ID identity for the new macOS distribution gate.
  This inventory does not establish signing or store eligibility on other systems.

The broader `just unit` run reproduced the already documented upstream Ark harness
limitation in `docs/upgrade-0.10.0.md`: 134 pass, 36 fail, one ignored. Its Bitcoin
kernel/fixtures cannot serve as XBT consensus acceptance; no signature check was
disabled and the result remains failed. Current frozen-source XBT Knots acceptance
and migration of the upstream fixtures remain required. Native compilation needed
the existing Boost.MultiIndex 1.85 compatibility headers; neither a forced header
nor the Homebrew 1.92 MPL option alone worked. This reinforces the open reproducible
native toolchain gate rather than closing it with a local workaround.

### Explicit payment-enabled phone pairing

The host now offers Manage only (default) or Manage and send when creating a new
Jars pairing. Existing stored grants retain management-only access. Both mobile
apps explain spending permission before saving the code. A payment grant allows
spending from that Jars wallet; it has no per-device amount limit. It cannot export
keys, unlock wallets, access the main wallet or invoke legacy immediate-send APIs.
The host and Jam independently enforce the permission with separate credentials.
Changing the code's scope does not change the saved host grant.

Paired direct and CoinJoin sends use the same immutable terms, saved-review
preflight and explicit commit. A lost reply enters recovery; it never triggers
an automatic retry. Revocation prevents new dispatches, while an already accepted
request may finish. Wallet changes, Jam restart and expiry invalidate delegation.
This completes the client/proxy implementation; installed-host TLS/Tor, revocation,
backup/restore and live settlement acceptance remain open.

Validation for payment pairing: 119 Swift tests; 96 Android JVM tests with four
opt-in live cases skipped; 13 targeted REST tests; 66 local companion tests with
one container-only case skipped; shared web contracts; Jars browser flows at
390/1280/1440px; direct and CoinJoin browser flows at 390/1280px. Two regular iPhone
simulator tests verify management/payment permission wording and canceled pairing.
All seven Android API 35 Jars UI cases pass, including both permission reviews,
CoinJoin selection, recovery, maker fees and bond guidance. Native device testing
here uses synthetic fixtures and makes no payments.

### Bond and CoinJoin recovery details

Saved bond payments now retain their unlock date through the host proxy and
display it in UTC on iOS, Android and the shared desktop UI. Older saved records
without a date remain readable and explicitly direct the user to the Jam host.
Malformed dates and a bond date attached to an ordinary send are rejected. The
calendar display does not establish chain maturity or enable withdrawal.

CoinJoin history now labels the combined fee as Total fees and separates maker
fees from the owner's mining fee in payment details. The browser validates these
components before display, matching native and host validation. Shared fixtures
cover date preservation, legacy records, incorrect types/ranges and inconsistent
CoinJoin fees. The same 119 Swift, 96 Android JVM and 13 targeted REST cases pass
with the expanded fixtures; native ARM64 Apple and Android debug builds pass.
The expanded browser history checks pass at 390/1280/1440px; screenshots were
inspected. Bond funding and withdrawal client workflows remain open.

### Reviewed bond funding from jars

After creating a registered bond address, iOS, Android and the shared desktop UI
can fund it from the selected jar. The funding sheet fixes the registered address
and UTC unlock date, accepts a fixed amount and fee limit, and shows a separate
review before Fund bond. Bond funding cannot use CoinJoin. Existing ordinary jar
sends retain their CoinJoin toggle. The UI explains that the coins become locked,
funding is public and earnings are not guaranteed.

The draft, host proxy, native adapters and saved review bind the funding purpose
and unlock date. Old companions without the funding capability are refused before
preparation. The pinned Jam signer independently checks the wallet's registered
address and date, rechecks the future lock date before commit, and retains the
existing one-shot submission journal. Payment-enabled pairings support this flow;
management-only pairings remain unable to spend. A timeout opens payment recovery,
not an automatic retry. Bond withdrawal and live funding acceptance remain open.

Validation: 119 Swift tests, 96 Android JVM tests (four opt-in live cases skipped),
13 targeted REST tests, and 67 local pinned-Jam tests (one container-only case
skipped) pass. Shared fixtures reject a changed or missing bond date, changed
purpose and CoinJoin funding. The delegated signer test checks lost-response
recovery with one broadcast. Browser direct, CoinJoin and bond flows pass at
390/1280px; general Jars flows pass at 390/1280/1440px. Web contracts and native
Apple/Android builds pass. These use synthetic payments, not live settlement.

The regular iPhone simulator passed both funding entry and ordinary CoinJoin
selection checks with a finalized successful Xcode result. This caught and fixed
an initial sheet-state bug that opened an ordinary send form for bond funding.
All nine local Android API 35 Jars cases passed. Screenshot inspection then found
a Digital Wellbeing error dialog in a separate capture; Jars captures now require
the app to own the active accessibility window. Android CI at `e855ad7` remains
failed on API 36 because a System UI not-responding dialog covered onboarding;
the app thread was idle and no app exit was recorded. This does not establish
current Android 16 acceptance; a complete clean run is still required.
After rebooting only the isolated local emulator, all nine Jars tests passed
again with the active-window capture guard. The clean bond review was inspected.

### QR signer consistency across clients

The iOS, Android and shared desktop collectors now deliver a completed scan only
once and bind a scan to either public-account import or signed-transaction input.
Switching that purpose requires a fresh collector. All three reject malformed
BBQr headers, base64 disguised as hexadecimal, lowercase hexadecimal and partial
hexadecimal bytes. Desktop decodes each BBQr fragment at its byte boundary, as
the native clients do, and applies the same 4096-byte frame limit. Empty binary
input is rejected on iOS as well. These checks do not replace PSBT validation.

Fourteen shared transport fixtures exercise valid, compressed, mixed, malformed
and conflicting inputs. The source-generated Krux and SeedSigner vectors now
also exercise each client's transport for all five Jars paths and bond funding.
The shared Rust verifier continues to enforce the reviewed transaction, change
and unified signatures. Physical camera/signing acceptance and hardware bond
withdrawal remain open; a supported QR encoding alone does not establish signer
support for a bond script. Jam's server wallet and a selected Krux wallet retain
separate keys, balances and authorization.

Validation passes: 121 Swift tests plus the final eight QR cases after adding the
unpadded-base64 rejection; 98 Android JVM tests with four live cases skipped;
seven shared Rust signer checks; and the hardware browser suite at 390/840/1280px.
The browser suite includes 22 source-generated signer/transport vectors and the
shared malformed-input cases. This pass made no physical-device or live-payment
claim. `just checks` also passes.

## Reviewed bond withdrawals — 2026-11-16

The client implementation gate is closed for the server-owned Jam wallet. iOS,
Android and the shared desktop/StartOS/Umbrel UI can read a bounded bond inventory,
select one eligible bond, enter a destination and review the net recipient amount
and exact mining fee. The selected outpoint, whole input value and UTC unlock date
remain bound through pairing, preparation, approval, commit and recovery. A
withdrawal is a single-input sweep, with no change and no CoinJoin fallback.

Maturity comes from node median-time-past, not the phone or desktop clock. Frozen,
unconfirmed, immature and unsignable coins remain unavailable. The companion
rechecks ownership, maturity, confirmation, freeze state and the node's unspent
output before broadcast. Management-only pairings can inspect bonds but cannot
prepare or commit payments. A lost submission stays unresolved and is observed
through payment activity; a second commit cannot broadcast again.

Validation in this pass:

- 123 Swift tests and 100 Android JVM tests passed; four live Android cases were
  excluded. Eighteen shared inventory cases and forty payment-review cases cover
  eligibility, malformed data and changed review terms across native clients,
  Rust and browser validation.
- Fourteen REST tests passed, including exact withdrawal request mapping and
  pairing permissions. The pinned Jam suite passed 70 tests with one container-only
  test skipped. It exercises real CLTV signing against a synthetic chain, the
  exact maturity boundary, changed value/confirmation/freeze/spent state and a
  lost delegated submission with one broadcast.
- The browser payment suite passed direct, CoinJoin, bond funding and withdrawal
  flows at 390 and 1280 pixels, plus the broader Jars browser regression suite.
  Native iPhone and Duo active-display entry checks, plus Android funding/withdrawal
  review checks, cover fixed
  bond values, no CoinJoin switch and interrupted submission handling where the
  test supplies a transport. iOS entry previews deliberately cannot send. The Duo capture shows its compact
  display with the second display black; this run does not establish unfolded
  or hinge-transition visual acceptance.
- Native iOS/Android builds, three package-generator checks and `just checks`
  passed. Initial native UI assertions were corrected to select the merged iOS
  accessibility value and the Android button rather than its matching title;
  the screenshots did not show a payment-state or value defect.

This is not live withdrawal acceptance or production readiness. Installed-host
pairing, a live matured-bond withdrawal and confirmation/recovery acceptance remain
open. No production wallet was changed and no test payment was made. Krux and
SeedSigner remain separate signing wallets: this flow neither imports their keys
nor claims support for their unresolved CLTV withdrawal review/signing gates.


## Native daemon lifecycle prerequisite — 2026-11-16

The current native Apple Silicon binary was rebuilt with the shared embedded web
UI and bundled SQLite. Its unfunded acceptance harness now rejects a competing
instance on a different port, verifies that the live instance's discovery address
and owner authentication remain intact, kills only the test child, and restarts
without deleting stale lock files. A malformed saved credential fails closed and
is not silently regenerated. The expanded checks passed, together with shared UI
asset/entropy checks and `just checks`. No wallet keys or payments were created.

The Linux backend workflow now builds and runs this same prerequisite; run
`44013947112` passed at `ab609bc`, including the new native daemon smoke test. This does not close native launcher, bundled
Jam/Tor lifecycle, Windows ACL/runtime, signing, installer, upgrade or funded
backup/recovery gates. The earlier bond-withdrawal revision b1a92db also passed
bundled Jam CI on AMD64 and ARM64, the full browser workflow and backend CI.
Android API 35 passed, while API 36 failed as detailed below.


## Android API 36 visibility evidence — 2026-11-16

Android run `44013095502` at `b1a92db` passed native builds for both architectures
and the API 35 app job. API 36 failed nine Jars cases at the active-window check,
after their Compose assertions. The available artifacts do not establish which
window covered the fixture. This is an unresolved failed gate, not evidence of
successful visible UI or a confirmed app crash.

The Jars screenshot helper previously wrote to app-specific storage, which the
Gradle runner removes and the CI artifact collector does not retrieve. Fixture
screenshots now use the existing public test-image directory. A blocked capture
records the screen plus package/window metadata and fixed system-dialog categories,
then fails with the original timeout as its cause. It does not dismiss dialogs,
retry cases or accept hidden Compose content. A negative-control test covers the
fixture with the launcher and verifies that capture fails and preserves evidence.

The ten existing Jars cases passed on the local ARM64 API 36 emulator; all eleven
cases passed after adding the negative control. The successful Gradle run retained
funding, withdrawal and maker screenshots after app cleanup. This does not replace
the failed x86_64 CI result or physical-device acceptance. No live payment or
production app change occurred.

The complete local API 36 ARM64 class sequence subsequently passed all 46 cases
across 18 classes, including the one negative control. This exercises Jars after
the preceding recovery and bridge cases, matching the CI ordering. The app was
absent after Gradle cleanup and fixture images remained available. The x86_64 CI
run `44017675684` is pending; no failure was retried into a passing result.


## Android launcher failure identified — 2026-11-16

Run `44017675684` at `0cf65d0` completed: native builds for both architectures and
the API 36 app job passed. API 35 failed nine Jars capture checks. The newly retained
screenshots show **Quickstep isn't responding** over the app; privacy-safe metadata
also identifies an Android not-responding dialog. The negative control passed. This
identifies the obstructing process in this run; it does not prove the cause of the
earlier API 36 failure or establish emulator stability.

The workflow inherited `-gpu swiftshader_indirect` from the emulator action while
running emulator 37.2.13. Android's [graphics acceleration documentation](https://developer.android.com/studio/run/emulator-acceleration)
lists that mode as deprecated since 36.4.9. The workflow now explicitly selects
supported `-gpu swiftshader`, keeping the same API matrix, cold boot and test order.
Quickstep is also a named diagnostic category. No ANR dialog is dismissed, test
failure ignored, assertion removed or failed case automatically retried. This is
a renderer compatibility change to validate, not a confirmed launcher-ANR cure.

The supported renderer booted on native macOS with emulator 37.2.13; its log
selected ANGLE/SwiftShader, unlike the earlier legacy GLES path. All eleven Jars
cases passed on the isolated ARM64 API 36 emulator, including the blocked-window
negative control. Kotlin compilation, workflow YAML parsing and `just checks`
passed. The new Linux x86_64 API 35/36 CI run is still required.


## Bond withdrawal confirmation race — 2026-11-16

A new real-signer/API regression reproduced a validation gap: the wallet cache
could retain a confirmed bond while the final node UTXO read reported it as
unconfirmed. Commit checked the cached confirmation count but only compared value
and script in the node result, so the synthetic request was submitted.

Commit now also requires a positive integer confirmation count in that final node
result. Zero, negative and malformed counts reject before the journal's submission
boundary and before broadcast. The review remains prepared; once the node confirms
the input, a separate explicit commit of an otherwise valid review can proceed.
This applies to the shared Jam host used by every client and is mirrored to the
Android branch. It does not enable an automatic payment retry.

The regression failed before the fix and passes afterward. The complete pinned
Jam suite passes 71 tests with one container-only skip (72 total), using synthetic
chain data and the real signer. Live chain reorganization, installed-host withdrawal
and confirmed settlement acceptance remain open; no funds were moved.


## Encrypted Jam volume restore prerequisite — 2026-11-16

A new pinned-runtime test copies a quiescent Jam data directory containing a real
encrypted wallet, registered fidelity bond, TLS files, wallet history and SQLite
payment journal into a fresh directory. The original wallet and journal are closed
before the copy. The restored daemon rejects the original owner token and phone
payment delegation, checks the wallet password, and derives the same wallet
identity by decrypting the saved file rather than injecting a wallet object.

An uncertain bond withdrawal survives the restore with the same reviewed outpoint
and wallet identity. Repeated commit remains observation-only; cancellation and a
replacement preparation are rejected. Observing the exact original transaction
resolves the record to submitted without a second broadcast. The encrypted file
remains unchanged, the bond registry and TLS certificate survive, and private key
and wallet file modes remain restricted. Old pairing credentials remain invalid
after unlocking. No secret values are printed by test assertions.

All 73 Jam cases completed locally: 72 passed and one container-only case was
skipped. `just checks` passed. Chain reads/broadcasts and background sync are
synthetic; wallet encryption, file loading, signer, HTTP authorization and journal
persistence are real. This is a Jam component prerequisite, not full StartOS/Umbrel
four-volume backup, live chain rescan, power-loss or installed-package acceptance.


## CI acceptance follow-up — 2026-11-16

Android run `44020561208` at `98a1116` passed both native architectures and the
complete API 35/36 app jobs with the supported renderer. The earlier Quickstep
failure remains in the evidence; no assertions or failure dialogs were suppressed.
This resolves the outstanding CI run failure, not physical/foldable or sustained
emulator reliability acceptance.

Bundled Jam run `44023055068` at `2d43c43` passed on Linux AMD64 and ARM64,
including the encrypted-volume restore regression. No package was deployed or
published. The live, installed-host, physical signer, backup/rescan and signed
native distribution gates listed above remain open.


## Packaged supervisor shutdown prerequisite — 2026-11-16

The managed-chain supervisor now has unfunded process-level tests for normal
SIGTERM shutdown and unexpected wallet exit. Each starts the real supervisor with
three isolated Python child processes standing in for the wallet, chain adapter
and Tor. No node or network is contacted. The checks verify that all owned children
receive termination, are reaped, and leave no live PIDs; an unexpected wallet exit
preserves its failure status. Failure cleanup is restricted to the test's separate
process group.

Four supervisor tests and three existing Tor policy tests passed on native macOS,
along with `just checks` and workflow YAML parsing. The backend CI now runs these
checks without invoking package publication. This does not establish installed
StartOS/Umbrel upgrade behavior, actual Tor recovery, Jam service lifecycle or
Windows supervisor support; those acceptance gates remain open.

## Native desktop listener discovery prerequisite — 2026-11-16

The daemon now accepts `--port 0` (or `BARKD_BIND_PORT=0`) and reports the actual
OS-assigned listener address. This lets a future native launcher avoid reserving
and releasing a port before starting its child. Fixed ports remain supported.
The local discovery file is published only after binding succeeds; a bind failure
preserves the previous address and authentication. Unix updates replace that file
atomically, so a restarting daemon does not expose partial discovery contents.

The unfunded native harness exercises this through real HTTP requests across
graceful and forced restarts, plus a deliberately occupied fixed port. It retains
authentication, origin and duplicate-instance checks. The native Apple Silicon
harness, five daemon and four connection tests, and 82 REST tests passed (one
existing REST test ignored), along with `just checks`. The connection test fixtures
now distinguish concurrent calls within a clock tick after their previous
timestamp-only names collided during validation. Native launcher/browser
handoff, Windows atomic discovery/ACLs, bundled runtimes and signed OS installers
remain required; this prerequisite does not close those gates.

## Desktop daemon ownership layer — 2026-11-17

The Linux/macOS runner module now owns one daemon process under a private
application root. Its launcher lock lives outside the wallet directory, so wallet
deletion cannot remove it. Startup uses an OS-assigned loopback port, drops
inherited service/proxy/loader overrides, and requires fresh discovery plus the
owned child's PID before sending authenticated readiness requests. It rejects
redirects, shared or symlinked storage and duplicate launchers. Startup failures
and normal close reap only its own child; independently started daemons are left
running. A required forced shutdown returns a recovery warning.

Eight policy and real-child tests pass on native Apple Silicon, along with
`just checks`, workflow parsing and whitespace checks. The tests use empty
temporary storage and no node calls or payments. Linux backend CI now runs them
against its built daemon; the preceding listener-discovery revision passed CI
run `44028126712`. This does not establish Windows support or OS ACL acceptance.

The module is not yet a visible desktop application. Browser authentication,
first-run network/service configuration, packaged interpreter delivery, abrupt
shell-death recovery, bundled Tor/Jam and signed installers remain open. No
installed wallet, production service or funded device was modified.

## Desktop launcher crash cleanup — 2026-11-17

Managed desktop daemons now opt in to `--exit-on-stdin-close`. The launcher keeps
an otherwise unused pipe open; closing the app or killing the launcher closes
that pipe and requests graceful daemon shutdown. A dedicated OS reader avoids
holding Tokio runtime shutdown open while a live launcher still owns its pipe.
Wallet opening can be cancelled, and the main signal listener also responds to
launcher cancellation. Server-package and manual launches retain the default
behavior because the flag has no environment-variable equivalent and is off by
default.

Eleven runner checks pass on native Apple Silicon, including a real launcher
SIGKILL followed by daemon-lock release and authenticated restart, SIGTERM while
the lifetime pipe remains open, and explicit recovery errors for an unresponsive
owned child. Seven daemon unit tests, four connection tests, the existing native
HTTP/authentication smoke test and `just checks` pass. All data was temporary and
unfunded. The previous ownership-layer CI run `44031612614` passed on Linux.

This verifies idle-daemon crash cleanup, not active payment/request draining or
bundled Tor/Jam shutdown. Those checks, the visible desktop shell and browser
handoff, Windows support, signed installers and other platform acceptance gates
remain open. No funded wallet, installed service or payment was changed.
