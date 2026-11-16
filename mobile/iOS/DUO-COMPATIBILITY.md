# iPhone Duo compatibility

Status: the safe 17-case Duo simulator suite passes; physical-device acceptance remains open.

The app uses system TabView and NavigationStack containers, supports portrait and
landscape, and limits shared cards to a readable width. Payment/scanner toolbar
actions provide labels and symbols for adaptive system placement. Wallet and
payment state must survive display changes without submitting transactions.

Before claiming Duo support, test on a Duo simulator or device:

- Outer display, fully open, partially folded, rotation, and Split View.
- Rapid tab changes and navigation back gestures, preserving selected tab.
- Receive QR, hardware signing QR, and camera preview across display transitions.
- Payment review, confirmation, keyboard visibility, and large Dynamic Type.
- App locking/background privacy and pending payment reconciliation.
- Fold/camera reserved regions: no hidden approval controls or QR codes.

## Simulator acceptance

Xcode 27.2 and its Duo runtime are installed. Use an isolated simulator with no
real wallet data. Boot it and select **Open** in Device Hub before running the
wide-layout cases in `AdaptiveLayoutTests`. A new Duo starts closed; rotating its
cover screen does not exercise the inner display. Capture both XCUIScreen displays
because the inactive one can be black.

The tests use the active scroll viewport and native side-rail buttons rather than
assuming one application frame or a bottom tab bar. An open display can already
fit columns before rotation. Tests still require readable content, reachable
controls, selection/privacy preservation, and restoration of the initial layout.
Scrolling targets the content view rather than the multi-display application.

On 2026-11-16, the complete open-display suite passed all 17 cases, including
payment reviews, pairing, Bridge status, Jars selection, uncertain-payment recovery,
health/backup/assistance, large-text recovery, bond setup, dashboard layout and
nested tab navigation after correcting the test queries. These are synthetic
fixtures, not live node or payment acceptance. The full regular-phone suite also
passed all 17 cases on an isolated iPhone 15 Pro Max simulator. Separate
QR/camera, keyboard, locking and pending-payment fold transitions remain open.
A public synthetic node endpoint draft survived open → closed → partially open →
open transitions; the closed form scrolled to its confirmation control. No
connection verification or payment was submitted during this check.

Keep `testLiveStartOSLANConnections` excluded unless its private fixture and live
test authorization are available. Never capture credentials or recovery words.
The safe layout suite does not create wallet keys or submit payments.

Apple guidance:
https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo
https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
