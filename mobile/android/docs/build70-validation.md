# Android build 70 parity validation

Candidate: `0.2.0-parity.70` (version code 4), ARM64 private test APK.
Native Java 17 / SDK 37.1 / NDK 28.0.13004108; API 35 ARM64 emulators.
This is Android's build-70 parity candidate, not an iOS archive or Play release.

## Changes

- Build 70's CLN/LND read-only retry, cancellation, certificate alternatives,
  authenticated configuration validation, foreground balance refresh and stale
  balance/error handling are on the Android branch. Requests that can create an
  invoice or move funds are never automatically replayed. TLS verification and
  explicit Tor routing remain intact.
- Shared Tor startup now belongs to the runtime, not its first caller. Cancelling
  one waiter leaves other consumers running. Control reads have deadlines;
  failed attempts release their binding and can be retried.
- Setup, wallet dashboard, settings and node connection editor use two columns
  on sufficiently wide screens. Separating hinges determine actual column
  placement. Cover screens and large text stack the same composition. Single
  tasks avoid hinges, tabletop uses one unobstructed pane, and single forms have
  a comfortable maximum width.
- Fold and rotation changes preserve in-memory drafts without saving credentials
  in instance-state bundles. The app still locks when backgrounded.
- Setup includes the wallet name and a public/hardware-wallet entry point.
  Successful verified payments have a finite, optional particle celebration;
  pending, uncertain and funding-only outcomes do not trigger it.

## Checks

- Kotlin: 59 tests, 58 passed and the opt-in live-node test skipped. Includes
  CLN POST/LND GET retry bounds, no replay of mutations, authorization/TLS
  rejection, request cancellation, balances, BOLT12, Bridge validation and the
  new shared-startup cancellation/retry tests.
- Debug APK, Android test APK, unsigned release APK and Android lint pass.
  Lint still reports SDK/dependency advisories, ARM64-only packaging and the
  existing custom trust-manager advisory. TLS fixture tests exercise that
  trust manager's accepted and rejected pins.
- Three adaptive-layout Compose tests pass: draft preservation across compact,
  wide and large-font layouts; separating hinge geometry; tabletop avoidance.
- Pixel 9 Pro Fold emulator: actual setup draft survives cover/unfold/rotation
  without activity replacement. Hardware/public setup remains reachable.
- Real node-editor fixture: both CLN and LND selectors render and retain the
  public endpoint draft. The full app also preserves its node draft through
  cover/unfold/rotation without replacing the activity. No credentials were
  loaded and no connection submitted.
- Existing native wallet navigation and settings workflow tests pass. Screenshots
  were reviewed for the unfolded dashboard, settings, setup and cover setup.
- Embedded Tor lifecycle test passes: cancel one waiter, complete another, then
  reuse the ready runtime. The unfunded mainnet Tor test passes chain/Ark sync
  and dead-proxy rejection. No payment was made.

- `just checks` passes. `just unit-mobile` passes 29 tests with one explicitly
  ignored live-network case. Shared Rust production sources match the iOS build
  70 checkout; the existing Electrum protocol test fixture differs intentionally.

## Limits

No physical Android phone or foldable was connected. These checks do not establish
all manufacturer posture behavior, real biometric/sensor behavior, or funded
payment, hardware signing, Bridge, Coinjoin or cross-platform backup acceptance.
StartOS CLN/LND authentication was not repeated from Android in this pass; local
TLS/protocol fixtures and the actual embedded Tor runtime were tested separately.
The particle effect was reviewed in code; no production send was made to trigger it.

Test outputs, screenshots and source/APK hashes are kept locally in
`artifacts/android-build70/`. Build artifacts and credentials are not committed.
