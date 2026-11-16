# Cross-platform navigation and QR wallet review

## Dashboard density review: 2026-11-16

iOS build 73 groups the balance and fiat value, places account units beside their
amounts, and puts the activity link in the section heading. Smaller card insets
and gaps remove empty space without reducing action touch targets. The wallet
selector occupies the navigation bar; wallet management actions use a menu on
iOS and Android. Large accessibility text stacks Send and Receive vertically and
removes decorative picker icons so names remain readable.

Android cards and adaptive grids use smaller insets and gaps. The shared browser
UI used by desktop, Umbrel and StartOS removes forced metric-card heights and
reduces header, toolbar, card and wallet-selector padding.

Native Xcode dashboard portrait/landscape and navigation checks passed. Normal
and largest accessibility text previews were visually inspected; these are
synthetic simulator fixtures. The Release device build and Tor/framework signature
checks passed. Android debug and test APKs compile, but two local runtime attempts
were blocked before onboarding by a System UI ANR; the new menu runtime check is
not accepted. The attempted Duo run was interrupted during simulator startup and
does not establish Duo acceptance. All 16 browser suites passed; the bridge-send
suite needed one unchanged rerun after an initial page-load timeout under host
contention. Browser health screenshots were inspected at 390 and 1280 px.

These changes do not alter payment, wallet storage or network contracts. Package
installation, live-node behavior and the remaining coordinated release gates
require separate evidence.

This source pass covers iOS, Android, and the shared browser UI used by standalone,
Umbrel and StartOS packages. It does not certify deployed packages or a public
release. The product direction is one wallet for Ark, Lightning, JoinBlaket jars
and the bridge, with consistent review and navigation. Each balance and action
must identify the wallet that owns it.

## Navigation

- Keep Wallet, Lightning, Jars, Activity and Settings as the five primary destinations.
- Jars opens the independent JoinBlaket wallet directly. Legacy Kilojoin funds
  remain under Experimental; no new Kilojoin rounds are enabled. The desktop
  `coinjoin` URL remains compatible, but selects the Jars navigation item.
- Preserve each Android tab's nested history. Back returns to the immediate
  parent. Select the current tab again to return to its overview. Activity
  recreation preserves the selected destination. A wallet change clears paths.
- Retain connection drafts across tab changes without putting credentials in
  Android saved instance state.

The Jars navigation follow-up passed native iOS tab/back/Experimental UI checks,
Android unit tests (including restoration of older four-tab histories), Android
app/test APK builds, and browser navigation/Jars/activity flows at phone, tablet
and desktop widths. Android retains the Jam session in memory across tab switches;
returning requires refreshed maker status. Password entry and confirmation dialogs
are not retained across navigation. Native Android runtime acceptance of this
follow-up remains pending. Screenshots were inspected for the iOS Jars tab and
the shared browser's five-item phone navigation.
- Browser Back/Forward, selected-menu state and heading focus follow the visible
  destination. Locked browser history cannot reveal wallet panels.
- Separate desktop Settings into wallet tools, connections, backup/recovery and
  privacy. Keep extra connection instructions behind a disclosure.
- Use accessible touch targets, visible keyboard focus, large-text layouts and
  reduced-motion behavior. A pending payment must not show completion effects.

## Krux and wallet selection

iOS and Android retain their multiple hot, QR and watch-only wallet registries.
The dashboard exposes the active wallet and its type. The browser adds multiple
public QR accounts alongside its existing hot wallet. Each QR account has a
separate database, receive/change address state, history and signing request.
The browser switcher stays visible while the wallet is unlocked.

The browser remembers the selected public account in the current tab. It checks
that account against the authenticated server before it shows wallet controls.
If the account is unavailable, it stays locked and offers an explicit hot-wallet
choice. It does not silently select the hot wallet. Closing the tab clears this
selection. Renaming a QR account keeps its descriptors, addresses and history;
it cancels an unfinished signing request for that account.

Android presents each wallet as a card with its type, network and selected state.
Rename belongs to that card, separate from the add-wallet form. Wallet-type and
address-type choices wrap on small displays. The iOS picker exposes its selected
state to VoiceOver and gives rename/remove actions at least 44-point targets.

For the browser, select **Manage wallets → Pair a Krux or QR wallet**. Scan or
import the public account, choose its address type, and compare the first receive
address with the signer before funding it. Select that wallet to receive or send.
Review the amount, recipient and fee, scan the unsigned PSBT on Krux, then scan or
import the signed response. Signature verification precedes the final broadcast
confirmation. Keys remain on the signer. Use XBT/BLAKE2b-compatible firmware;
ordinary BTC signatures do not satisfy the shared verifier.

All clients use `bark::onchain::qr` for public descriptor validation and signature
verification. This checks the exact reviewed transaction and trusted original
prevouts. It rejects changed outputs, fees, input order, locktime, sequences and
non-unified signatures. BIP44, BIP49, BIP84 and BIP86 single-key accounts are
supported. Multisig and Taproot script trees are not supported.

Switching wallets clears unfinished QR requests and stale receive codes. Browser
hot-wallet API operations are blocked while a QR account is selected. The wallet
switcher is disabled during a mutation. A broadcast saves the exact signed
transaction before relay. An uncertain result remains uncertain, survives a
server restart, and never triggers an automatic replacement payment.

Browser cameras require a secure context. QR image and PSBT file import provide a
fallback for local HTTP installations. QR codecs support BBQr, bounded raw-deflate
BBQr, signed `ur:crypto-psbt`, base64/hex and `pNofM`. Public account imports use
plain text or BBQr. The app never asks for the hardware wallet's seed words.

## Evidence and limits

The validation uses synthetic public signer fixtures and disposable test wallets.
It does not spend real sats. Tests cover the four signing script types, rejected
transaction changes, independent account databases, address persistence, stale
requests, QR codecs, wallet isolation, explicit broadcast review and uncertain
results. Browser flows run at phone and desktop widths. Navigation also runs at
tablet width. Native checks cover the iPhone simulator and Android fold emulator.

The local pass on 2026-11-15 completed the shared QR verifier (5 tests), mobile
Rust suite (25 passed, 1 ignored), public-account REST tests (2), Swift package
suite (98), and Android unit suite (69 tests, 3 live-only skips). The rebuilt
Android JNI bridge and navigation recreation checks passed on the fold emulator.
Nine adaptive iOS UI tests and the receive-address persistence test passed on the
iPhone simulator. Browser navigation ran at 390, 800 and 1280 pixels; the QR
flow ran at 390 and 1280 pixels, including decoding the rendered signing QR.
Existing browser, transport, receive QR, JoinBlaket and setup checks passed.
`just checks` and the shared-source checksum check also passed.

Follow-up checks covered Android's open fold display and narrow cover display
with 1.3x text. The JNI test switches between a generated disposable hot wallet
and all four public signer script types, for both QR and watch-only profiles.
It checks independent networks and receive-address sequences. The CI UI test
waits for Back to become enabled after recreation; restored content can appear
before wallet loading finishes. Each instrumentation class now retains its report
even if a later class fails. Browser tests cover rename/cancel, keyboard focus,
long names, reload/lock restoration, and a missing saved account. The iOS native
persistence test also checks the selected-wallet accessibility value.

Physical Krux optical scans, physical iPhone/Android round trips, signed production
archives, deployed Umbrel/StartOS upgrades and live hardware-wallet broadcasts
remain release acceptance checks. The browser still has one hot wallet per server;
multiple hot-wallet profiles, watch-only import and direct QR-funded Ark boarding
remain parity work. Mobile QR-funded Ark boarding remains available. Browser QR
accounts use the server's verified chain backend and network.

Back up the complete server data volume, including `qr-wallets`, to retain labels,
address state and uncertain broadcast records. Public accounts are scoped to the
server's hot-wallet fingerprint. Restore the complete backup when moving the
server; a new hot wallet does not automatically select the previous accounts.

## iOS bundle validation

The pinned upstream Tor artifact contains versioned iOS framework directories.
An app build phase that flattens that directory races Xcode's framework stub and
code-sign tasks. XcodeGen now verifies the upstream archive checksum and prepares
flat iOS slices before package resolution. The original downloaded archive stays
unchanged. Xcode then copies, signs and validates a normal shallow bundle.

Run `mobile/iOS/Scripts/verify-ios-bundle.sh` on every candidate. Signed simulator
and clean unsigned simulator builds are checked locally. CI also checks unsigned device
packaging. Production archive/export verification remains required.

## Delayed-response and security pass — 2026-11-15

The browser pass reproduced and fixed these failures with controlled response
delays and synthetic public signer fixtures:

- Unlock during an old QR receive request could silently select the hot wallet.
  Account restoration now validates and restores the saved identity even while
  the earlier operation finishes. Ordinary wallet switching remains disabled.
- An old send or QR broadcast response could reopen a receipt or change the
  current screen after lock and unlock. Responses now belong to a wallet session.
- An old Activity load could block the next load or replace its records. Controls
  and results now belong to the specific operation and wallet generation.
- Cancelled signature verification and delayed file imports could update the
  cleared form. They now check the original signing request and input collector.
- An old camera permission response could replace a newly opened scanner. Each
  scanner session now owns its stream; discarded streams stop their tracks.

The regression suite also checks that a rejected signature stays visible, a new
file import can succeed, and camera verification errors remain visible after the
scanner closes. Camera streams and QR frames in these tests are synthetic. This
does not replace physical optical testing.

The manual security review covered REST authentication and notification tickets,
browser DOM insertion and framing, QR account paths and reviewed signatures,
JoinBlaket upstream restrictions, mobile node TLS/redirect/retry policy, and
device credential storage. It did not use Daybreak or a hosted scanner.

One concrete browser protection was missing: wallet responses did not restrict
framing. An unrelated site could embed the reachable wallet and mislead a user
who unlocks or interacts with that frame. The server now sends
`Content-Security-Policy: frame-ancestors 'self'`, `X-Frame-Options: SAMEORIGIN`
and `X-Content-Type-Options: nosniff`. The existing HTML content policy remains in
place. Same-origin shells remain permitted; cross-origin embedded shells must
open the wallet as a top-level page. Packaged shell compatibility still requires
the release tests. The regression checks the entry point, SPA fallback and
missing-asset response headers. No live clickjacking attempt was made.

No clear authentication or TLS bypass was found in the reviewed paths. This is
a scoped manual review, not an exhaustive audit or a dependency vulnerability
scan. Exact hot-wallet debit review and durable uncertain-operation recovery
remain open in `COORDINATED-RELEASE.md`; these fixes do not close those gaps.

Local validation passed all eight browser scripts, including nine delayed-response
and retry scenarios, 14 REST tests, five shared QR verifier tests, 14 Swift
connection/transport tests, and 16 Android connection/payment-policy tests.
`just checks` and the shared-source checksums passed. No live payments,
production restarts, device installs or release publication occurred in this pass.

## Shared Activity follow-up — 2026-11-15

Desktop, Umbrel and StartOS candidate source now shows normal on-chain transactions
in Activity. All / On-chain / Ark filters keep the ledgers distinct. A transfer
between ledgers can have a record in each; the screen does not add these amounts
into a synthetic payment total. On-chain records retain the server's observation
order, newest first. They show block height when confirmed, without invented dates
or confirmation counts. QR account history uses the same cards and a refresh action.

Amounts are signed wallet balance changes. An outgoing debit already includes the
fee paid by that wallet; the UI does not subtract it twice. Transaction fees appear
in Details and remain unavailable when the server cannot calculate them. Unknown
statuses do not become success or failure. A completed Ark movement does not claim
that a multi-step Lightning payment settled at the recipient.

Each ledger reports load failure separately and keeps the available ledger usable.
Malformed responses do not become empty history. Account changes and lock clear
records and filters. The first 25 cards per ledger render immediately. Show more
adds 25 without another API request, preserves expanded details, and moves keyboard
focus to the first added card. Technical records remain collapsed by default.

The browser regression checks phone, tablet and desktop widths (390, 800 and 1280),
expanded details without horizontal overflow, accessible filter targets, partial
failures, unknown fees/statuses, net debit, text-only untrusted values, pagination,
and hot/QR account isolation. Rendered phone and desktop screenshots were inspected
and narrow-screen spacing corrected. All nine browser scripts and `just checks`
passed locally. The preceding security/backend CI run `43776856932` also passed.
No native adapters changed; these UI changes close a shared browser parity gap.
Deployment, physical accessibility and live settlement tests remain outstanding.

## Maker setup and wallet inspiration — 2026-11-15

The iOS, Android and shared browser CoinJoin screens now show the same five maker
setup checks. They distinguish valid terms, sufficient confirmed coins in one
jar, detected bond coins, an idle server and fresh status. Review remains required
before start. The checklist does not claim that detected bond coins prove an
active bond or guarantee earnings. The daemon performs final eligibility checks.
Kilombino's bonded-maker requirement remains in place.

A failed refresh now invalidates previous maker readiness on every platform.
The shared browser regression checks failure after an eligible snapshot, disables
maker action, then confirms that a successful refresh restores eligibility. It
also retains the uncertain-mutation guard with no automatic retry.

Validation passed: 17 shared eligibility cases in Swift, Kotlin and JavaScript;
six Swift JoinBlaket tests; six Android JoinBlaket tests; all nine browser scripts;
the native iOS simulator build; `just checks`; and shared-source checksums. Phone
and desktop browser screenshots were inspected. The Android test build compiled
the changed Compose screen. Native physical layout and live maker eligibility
were not tested. No production operation, payment, device install or release
publication occurred in this pass.

`WALLET-INSPIRATION.md` records the primary sources, implemented checklist and
remaining priorities from Bark, Zeus, Jam and Sparrow. These priorities do not
claim complete feature parity or close the release gaps.

## Transfer and recovery assistance — 2026-11-15

The recipient form now offers a saved-wallet destination without changing the
source wallet. Payment assistance stays behind a disclosure in browser/Android
Activity and inside the iOS transaction detail. Incoming payments do not show a
fee-increase action. Fee review names the recipients and separates original fee,
new total fee and additional debit. Unknown broadcast outcomes never celebrate.

Wallet health, backup check and report actions use existing cards, Settings
navigation and ordinary platform share/file dialogs. Reports are previewed first.
Backup dates are explicitly local observations rather than claims of cloud upload
or complete recovery. Advanced fee controls stay optional. A recipient typed while
an address lookup runs is preserved; account changes invalidate the old result.

Browser checks cover 390 px phone, 840 px foldable and 1280 px desktop health
layouts, report download allowlisting, failure states and nested back navigation.
Transfer and replacement checks cover 390/1280 px, exact cost review, cancellation,
malformed responses, manual edits, no mutation replay and lock/account isolation.
The browser tests use synthetic public fixtures, not funded wallets or real nodes.
Health cards reflow into two columns on wide screens and stack for larger text.
Android custom fee entry starts collapsed, and its approval dialog scrolls long
recipient details without hiding the confirmation controls.

Native build and simulator/emulator results are recorded in the completion notes;
physical-device and screen-reader acceptance remain separate release checks.

See `PAYMENT-ASSISTANCE.md` for the security boundaries, tests and remaining scope.

Local follow-up evidence: the four assistance flows passed interaction checks in
portrait and landscape on a fresh iPhone simulator, including the report share
action. Whole-application swipes failed to scroll after rotation; targeting the
actual scroll view resolved the automation failure. Element-cropped screenshots
also used stale portrait bounds, while the full screen recording showed correct
layout. Capture uses the full screen to avoid that artifact. This is not a
physical-device or unfolded-Duo acceptance result.

The rebuilt Android ARM64 emulator passed the real backup/destination checks and
health layout checks at narrow/wide widths, including larger text. Both packaged
ABIs' native libraries have 16 KB-compatible ELF segment alignment. Runtime
acceptance on a 16 KB-page device remains separate. Android unit tests passed
68 cases with three explicitly live-only skips; release lint reported no errors.
The target-SDK-36 rebuild passed six Android 15 emulator checks covering native
backup/destinations, health, Settings navigation, resize, separating hinges and
tabletop layout. Android 16 and 16 KB runtime checks remain separate.


## Compact pages and responsive motion: 2026-11-15

The wallet overview now keeps totals and Send/Receive together, removes repeated
branding and shortens the activity preview. Settings has six entry points with
focused subpages. Lightning balances, connection settings, payment status and
Bridge actions no longer compete in one long overview. Android retains each
screen's scroll state; opening a node subpage starts at the top and dismisses the
keyboard. Full invoices are expandable on the Android review, while amount and
fee remain visible.

Android navigation uses 190 ms short slides and fades, with reversed motion on
Back and a lighter fade between primary tabs. Node subpages follow the same
motion. iOS retains native stack/swipe navigation and adds quick spring press
responses, 220 ms card entry and selection feedback on the new page choices.
iOS Reduce Motion, Android system animation duration and browser reduced-motion
preferences continue to apply. Payment completion effects remain tied to verified
completion; moving between pages does not mark a payment successful.

The shared server node wallet has separate overview, Send, Receive and Activity
routes with browser Back support. Its transitions use a short 180 ms fade/slide,
disabled for reduced motion. Browser checks passed at 390, 840 and 1280 px using
both CLN and LND fixtures across StartOS/Umbrel configurations. The existing browser
regression suites also passed, including wallet switching, late responses,
review cancellation and lock cleanup. No live node, payment or deployed wrapper
was involved. See REMOTE-LIGHTNING.md for transport and recovery validation.

Before this compact-layout change, the candidate passed eight Android 16/API 36
checks on a disposable emulator with an actual 16384-byte page size. These covered
native JNI, public wallet and backup/destination behavior, wallet health, Settings,
large text and hinge/tabletop geometry. This supersedes the earlier note that
16 KB runtime acceptance was entirely untested; embedded Tor and physical-device
acceptance remain separate.

The final iOS simulator run passed four tests covering immediate dashboard actions,
portrait/landscape reflow, accessibility-sized text and nested Settings Back/tab
restoration. Result: `Test-Paperclip-2026.11.15_19-49-01--0700.xcresult` in the local
parity derived-data folder. The final Android build completed with 68 passing unit
tests, three explicit live-only skips and release lint success. The first updated
Android interaction run was interrupted by an emulator System UI ANR; it is not
counted as a pass. Follow-up emulator results are recorded below.

The five final Android interaction/layout tests passed on a fresh API 35 Pixel
Fold-profile emulator: nested Settings navigation, immediate Send/Receive access,
large-text/resize preservation, separating-hinge/tabletop geometry and wallet
health. Local log: `/tmp/compact-qa35-host-tests.log`. A fresh ARM64 iOS test build
also passed the Tor framework/platform/signature bundle verifier after the final
connection-label correction.

The API 36/16 KB foldable image repeatedly encountered System UI/compositor
failures during the updated interaction runs, including missing UI hierarchies in
basic layout fixtures. These runs are not passes. Software-rendered API 35 runs
were also slow; the complete five-test pass used host rendering. Physical foldable
and Android 16 fold/unfold acceptance remain open, independently of the earlier
successful 16 KB native checks. Existing developer emulators and real devices were
not modified; only newly owned disposable test instances were restarted.

The opt-in API 35 fold workflow also passed: enter a setup draft, unfold, fold to
the cover, reopen, rotate and continue to public-wallet pairing. The activity and
draft were retained. The test now wakes the cover screen and waits for its resumed
UI instead of assuming it is ready immediately after the posture command. Local
log: `/tmp/compact-qa35-fold-final.log`.

The Settings/Send/Receive interaction test also passed on the API 35 folded cover
screen. Final cover screenshots were inspected: all six Settings categories fit
without scrolling, and Send/Receive remain visible on the wallet overview. Local
log: `/tmp/compact-qa35-cover-final.log`. No real device installation, live payment
or store submission was performed in this pass.


## Bridge navigation and Duo display evidence: 2026-11-16

The iOS Bridge menu now owns its nested selection state separately from the node
dashboard. Repeated iPhone simulator checks cover opening send, returning to the
menu, opening receive and rotation. The send-screen check also enforces a
30-second upper bound, catching the observed event-loop stall instead of accepting
a screen that eventually appears after nearly two minutes.

For Duo, select the owned QA simulator in Device Hub and press **Open** before
running the wide-layout test. Rotation alone does not unfold it. The layout check
now requires both measured elements to exist and have nonzero frames: a missing
element must not turn a geometry comparison into a pass. Back is located by its
accessibility identifier across the app because Duo places it in a separate
toolbar rather than inside the navigation bar.

Both checks passed on the opened iOS 27.2 Duo simulator. A direct capture of its
`primary-1` display showed the Lightning balance and action cards in two columns.
The outer `primary` display was inactive; capturing only `XCUIScreen.main` produced
black attachments even though the inner display was rendering normally. The
capture helper now enumerates active screens using Apple's
[XCUIScreen API](https://developer.apple.com/documentation/xcuiautomation/xcuiscreen).
For independent capture, use `xcrun simctl io <QA-device> enumerate` to identify the
active display, then `screenshot --display=<display-name> <output.png>`.

Local evidence: `/tmp/bridge-review-item-navigation.log` (two iPhone passes),
`/tmp/bridge-review-duo-open.log` (Bridge navigation and Lightning layout), and
`/tmp/bridge-review-duo-open-display.png` (the actual inner-display capture).
The final run `/tmp/bridge-review-duo-screens.log` passed both tests and produced
inner-display attachments for the send, receive and two-column Lightning screens;
those attachments were inspected.
These checks use synthetic balances and do not verify a physical Duo, screen-reader
interaction or a live payment. The full release acceptance matrix remains open.

## Browser outgoing Bridge review: 2026-11-16

StartOS and Umbrel share the new node-funded BTC conversion flow. Entry, exact
cost review and pages of ten saved conversions keep actions separated. Each
applicable entry/review/history page has an XBT-to-BTC live-status badge, separate
from the BTC-to-XBT badge and from settlement. The cost panel uses side-by-side
amounts on wider screens and stacked amounts on narrow screens. Fee input and
secondary status actions remain reachable by scrolling; no horizontal overflow
was observed at the tested widths.

The outgoing browser regression passed with CLN/LND fixtures at 390, 840 and
1280 pixels across both platform skins. It covers amount mismatch, cancellation,
expiry while reviewing, lost funding responses, reload recovery, funding success
without settlement, direction-specific malformed availability, delayed approval
after navigation, and lock clearing. The complete 19-script browser regression
suite passed, including existing incoming Bridge, navigation, wallet-switch races,
remote-node and durable-submission recovery. These are synthetic browser checks,
not live swaps or physical-device accessibility acceptance.

Inspected screenshots: `/tmp/bridge-outgoing-screens/bridge-send-startos-390.png`
and `/tmp/bridge-outgoing-screens/bridge-send-umbrel-1280.png`. Full test output is
in `/tmp/bridge-outgoing-web-suite.log`. Browser Ark funding remains a parity gap.


## Browser Ark Bridge source selection: 2026-11-16

Outgoing conversion review now has an explicit Ark/node selector. Ark hides the
node routing-fee field and reviews funding plus fees/recovery reserves with an
enforced maximum total. It can be used without a configured node. Saved history
restores the funding source and never interprets funding success as BTC settlement.
The Bridge entry presents pay and receive as two choices, stacked on narrow screens
and side by side on wide screens, with an independent status badge on each.

The complete 19-script browser suite passed. The outgoing test covers CLN/LND node
funding at 390, 840 and 1280 pixels and Ark funding at 390 and 1280 pixels, including
the no-node case. Synthetic requests verify exact total arithmetic, expiration,
cancel, lost response/reload, stale preparation and clearing private UI on lock.
Inspected screenshots are under `/tmp/bridge-ark-screens/`, including
`bridge-send-ark-startos-390.png` and `bridge-send-ark-umbrel-1280.png`.
This is browser fixture acceptance; live swaps and physical accessibility tests
remain separate release gates.


## Backup task navigation: 2026-11-16

The mobile recovery hub now shows local save/check dates and three task links:
Save, Check and Restore. Wider screens place the summary and actions in separate
columns; compact screens retain all choices on one short page. Detailed archive
scope is disclosed on the Save page. It accurately excludes separate app payment
warnings, Bridge history and node connections; complete portable recovery remains
an acceptance gate in COORDINATED-RELEASE.md.

Android's existing Settings navigation test now exercises the hub, every task and
Back navigation. It passed on both the actual opened Pixel Fold emulator and its
cover display. Both hub screenshots and the expanded Save page were inspected.
No encryption key was generated and no backup was imported in these UI checks.
A separate run using forced size/density overrides timed out on pending Compose
layout before Settings; it is not counted as a compact-screen pass. No test
assertion or timeout was weakened to obtain the actual fold-state passes.

The native iPhone simulator test passed the compact/landscape health, backup,
transaction-assistance and owned-wallet-transfer fixtures. Backup navigation now
opens all three tasks and returns to the hub. The first run used a title-only
selector for a combined navigation row and was stopped; stable link identifiers
fixed the test query, and the hub links must now be hittable in both orientations.
This is synthetic navigation evidence, not Files import or funded restore proof.


## Bridge navigation and API 36 follow-up: 2026-11-16

The Bridge status/navigation test passes locally on the iPhone simulator. It
checks the entry, outgoing and incoming badges, return navigation and the incoming
landscape layout. The older CI runtime exposes Back with the preceding page label;
the captured CI hierarchy confirms that label. The test now supports this label
and the separate Duo toolbar identifier. Hittability and return-navigation checks
remain required. The older runtime still needs a new CI pass.

At `861acae`, all 15 cases in the ten Android CI test classes pass on an isolated ARM64 API 36
emulator with a verified 16 KB page size. They include native wallet screens,
Settings, adaptive layouts, Bridge status and flows, and backup/recovery cases.
The full sequence used explicit device selection and no funded wallet. API 36
x86-64 CI still has an intermittent system ANR dialog; the local pass does not
resolve it. Physical-device and screen-reader acceptance remain open.

Local logs: `/tmp/ios-bridge-selector-test.log` and
`/tmp/overnight-api36-*Test.log`. CI evidence and remaining gates are recorded in
COORDINATED-RELEASE.md.

After the profile-registration fix, native onboarding and wallet navigation pass
on a fresh API 36/16 KB emulator (117.837 seconds). This exercises wallet creation,
rename, send/receive navigation, Lightning, CoinJoin recovery, public-wallet entry,
alerts, connections and display settings. A prior attempt used an emulator with
an existing test wallet and timed out waiting for onboarding. That wallet remains
intact. The test now rejects a nonempty QA app with a clear precondition error;
assertions and timeouts remain unchanged. Evidence:
`/tmp/android-create-fresh-ui.log`.


## Wallet identity after selection: 2026-11-16

Android now applies the selected wallet's balance, network, connection and saved
payment warning together. Unreadable metadata prevents selection instead of leaving
the previous wallet name above the newly active native wallet. A successful switch
also clears the previous wallet's fee-review, exit and expiry display state.

The model/storage regression verifies failure and retry without a payment. Both
Settings UI cases pass on an isolated API 36/16 KB emulator (17.296 seconds),
including source-to-target and target-to-source switching. Each switch returns to
the correct dashboard; Send and Receive remain visible, and the native identity
matches the displayed wallet. The light-theme screenshot
`/tmp/selection-state-dashboard.png` was inspected. The wallet name, navigation and
primary actions fit without clipping. The unsynced total remains unknown while
the known local on-chain balance appears separately. These are unfunded emulator
checks, not physical-device, screen-reader or live-node acceptance.

## Receive draft consistency: 2026-11-16

Desktop receive amount and description edits remove the previous QR and sharing
controls. A delayed response cannot display an invoice for the old draft beside
new details. Its invoice stays available for status lookup; replacement requires
an explicit request. Unrelated payment summaries stay visible. Synthetic browser
regressions cover StartOS at 390 px and Umbrel at 1280 px, explicit retries and
viewport overflow. All 16 browser workflow suites passed, and the receive cards
were inspected at both widths.

Android similarly clears the displayed request when its amount changes and
invalidates queued/late receive results after leaving the page. A real regtest
model test failed before the queued-request fix, then passed with explicit retry.
The 19-case native/model/storage/Settings suite passed on API 36. Both mobile
platforms disable receive amount inputs during creation; iOS also disables its
offer description. Native Xcode receive/persistence navigation and bundle checks
passed. These tests do not cover a live Lightning invoice or physical devices.

Evidence: `/tmp/receive-draft-suite.log`, `/tmp/receive-draft-final-races.log`,
`/tmp/receive-draft-screens/`, `/tmp/receive-queue-before-runtime.log`,
`/tmp/receive-draft-android-final-runtime.log` and `/tmp/receive-draft-ios.log`.
