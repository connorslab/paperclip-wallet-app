# iPhone Duo compatibility

Status: prepared for resizable layouts; not yet verified on iPhone Duo.

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

Local validation on 2026-10-08: the physical iPhone build passes. The installed
Xcode 27 simulator device set has no Duo entry. Simulator linking is blocked by
the missing target/aarch64-apple-ios-sim/debug/libpaperclip_mobile.a library.

Apple guidance:
https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo
https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
