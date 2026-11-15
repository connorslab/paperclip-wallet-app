# Cross-platform navigation and QR wallet review

This source pass covers iOS, Android, and the shared browser UI used by standalone,
Umbrel and StartOS packages. It does not certify deployed packages or a public
release. The product direction is one wallet for Ark, Lightning, JoinBlaket jars
and the bridge, with consistent review and navigation. Each balance and action
must identify the wallet that owns it.

## Navigation

- Keep Wallet, Lightning, Activity and Settings as the four primary destinations.
- Preserve each Android tab's nested history. Back returns to the immediate
  parent. Select the current tab again to return to its overview. Activity
  recreation preserves the selected destination. A wallet change clears paths.
- Retain connection drafts across tab changes without putting credentials in
  Android saved instance state.
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
