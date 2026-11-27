# Paperclip Android

Development branch: `feature/android-wallet`, based on the iPhone branch at
`2dea92bb9e0962def9f7aed413a5cff19d260e45`. No changes to the iPhone app or production
services are required to use this branch.

This branch builds a **private mainnet candidate**, not a public Android release.
Normal authenticated setup creates an XBT mainnet wallet. Existing regtest wallets
keep their network, and full backups retain the network recorded in the archive.
The default servers are Paperclip's mainnet Electrs and Ark endpoints, through
built-in Tor. The coordinated release will ship Android as a direct signed APK download; see `deployment/COORDINATED-RELEASE.md`.
Public-release signing and physical-device acceptance are separate release gates; an APK signed with a development certificate is for private testing.

## Architecture

The Kotlin/Jetpack Compose app calls the existing `mobile/rust` static library
through a small JNI adapter. It does not embed a remote wallet daemon or fork
the Ark transaction implementation. The same Paperclip 0.10.0 / Bark 0.8.1 engine
provides address derivation, quoting, signing, database migrations and recovery.
Native calls run off the UI thread and are serialized. Sends require an unchanged,
unexpired quote. An intent is saved before submission; uncertain results are never
automatically retried or displayed as successful.

The UI follows iPhone's Wallet, Lightning, Activity and Settings tabs, navy/orange
palette, original orange Paperclip vector logo, rounded cards, balance visibility,
send review, receive QR codes and explicit payment-result states. Light, dark and
system appearance are supported. Navigation uses short fades between tabs and
directional transitions into task screens, following Android's system animation
scale. Balances use locale-aware digit grouping. Receive screens explain each
payment method and confirm when an address or invoice is copied. The Lightning
receive shortcut opens the invoice form directly. Switching receive methods
clears the old QR code; it is disabled while a request is running. Recovery words
switch to a single ordered column when screen width or text size requires it,
rather than shrinking or splitting words.

Cancelling a payment review retains the in-memory draft, which is discarded when
leaving the send screen or locking the app. Connection edits are labelled as
unsaved until applied. Submitted, pending and uncertain payments remain distinct
from confirmed success, and cannot be dismissed as completed.

## Build

Use JDK 17, Gradle 9.6.0 (included wrapper), Android SDK 37.1, build-tools 36.0.0,
CMake 3.22.1, NDK 28.0.13004108, Rust 1.91.0 and protobuf's `protoc`.
The existing Nix build shell supplies the host Rust build prerequisites.
Install Android SDK components using Android Studio or `sdkmanager`.

From the repository root with the native Android toolchain configured:

```sh
export ANDROID_HOME=/path/to/Android/Sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.0.13004108"
rustup toolchain install 1.91.0 --profile minimal
mobile/android/scripts/build-native.sh arm64-v8a x86_64
cd mobile/android
./gradlew testDebugUnitTest assembleDebug
```

`PAPERCLIP_RUST_PROFILE=dev CARGO_PROFILE_DEV_DEBUG=0` builds a faster development
library. The default is the release profile. `-Pabis=x86_64` or
`-Pabis=arm64-v8a` restricts Gradle to the ABI already built. The APK has a separate
preview application ID and debug signing key; do not publish it as a signed release.
`./gradlew assembleRelease` produces a non-debuggable, unsigned
release APK. Sign the final APK using the maintained Android application signing identity before
public distribution. Keep the same identity for updates; GPG does not replace
Android APK signing.
Keep keys, SDK installs and native build artifacts outside version control.

## Emulator and screenshots

CI checks API 35 and 36 x86_64 emulators with hardware acceleration. Build the
preview and test APKs before starting a disposable emulator (choose its ABI):

```sh
bash gradlew -Pabis=x86_64 assembleDebug assembleDebugAndroidTest
PAPERCLIP_TEST_SERIAL=emulator-5554 bash scripts/test-emulator.sh
```

CI prepares a fresh `Paperclip_CI_35` or `Paperclip_CI_36` AVD in its own temporary
AVD directory, then starts it with `scripts/run-emulator.py`. The launcher owns
that process and waits for boot completion, an unlocked user and three consecutive
focused-home observations before running the existing suite. It never injects
boot-time key events. Any recorded startup ANR rejects the boot immediately;
waiting for focus never erases or excuses an ANR. The emulator must exit on
cleanup, and an already-used serial is refused rather than adopted. Boot logs,
window/ANR evidence and screenshots go under `app/build/reports/emulator`.

To use the same launcher with an already prepared, unfunded test AVD:

```sh
python3 scripts/run-emulator.py Paperclip_CI_35 --sdk "$ANDROID_HOME" --reports app/build/reports/emulator
```

The launcher permits only the CI AVD names and the existing isolated local
`Paperclip_Recovery_20261117` fixture. It uses process-group ownership for cleanup;
it never kills an independently started emulator through its serial. A failed boot
or test is retained as a failure, with no automatic reboot or test retry.

The runner rejects physical-device serials, installs the APKs once and clears only
the two preview packages' data between classes. It runs each class directly and
verifies named test starts/completions, declared totals, class identity and a
successful final instrumentation result. Zero, skipped-only, partial, crashed or
failed runs cannot pass. Reports have a new directory per run under
`app/build/reports/instrumentation`; screenshots remain under `screenshots`.
The runner checks emulator ANR events before and after each class and saves failure
logs and a screenshot. It never clears ANR history, dismisses dialogs or retries a
failed class. These checks apply only to isolated synthetic test installations.

The navigation test creates a disposable wallet through the real Rust engine and
captures onboarding, wallet, send, receive QR, Lightning, activity, connections,
and light/dark settings. It also checks copy feedback, stale QR removal, the
Lightning invoice shortcut, and unsaved connection edits. The seed-layout capture uses only the disposable regtest
wallet created by the test; never use that photographed seed for funds. Recovery
keys and existing user wallets are not captured.
The native test rejects malformed JNI inputs and verifies a database backup/restore
preserves the next derived address. Clear app data before repeating the screenshot
test; never clear a funded wallet to run tests.

Normal launches require biometric or device-credential authentication and disable
screenshots. The debug-only `regtestScreenshots` intent extra permits emulator test
captures for empty installations or existing regtest wallets only. It refuses
mainnet wallets and mainnet backup imports, keeps screen capture protection on
for rejected launches, and is completely disabled in release builds.

## Tor and mainnet validation

Built-in Tor uses [Guardian Project TorService](https://github.com/guardianproject/tor-android)
0.4.9.14, a loopback-only dynamically allocated SOCKS port, and remote DNS
(`socks5h`). Both public chain and Ark connections use this route. Localhost
services remain local. For a LAN node, explicitly select Direct. There is no
automatic direct fallback when a proxy is unavailable. Bootstrap failure releases
the service binding so a later connection attempt can start again. Concurrent
callers share startup; cancelling one waiter does not cancel another consumer.
Control replies have a deadline within the overall bootstrap timeout.

The XBT Electrum transport explicitly negotiates protocols 1.4 through 1.8 and validates the
network genesis and 164-byte BLAKE2b headers. A reachable socket alone does not
count as a healthy connection. The opt-in test below uses a fresh, unfunded mainnet
wallet and makes no payments:

```sh
./gradlew -Pabis=x86_64 \
  -Pandroid.testInstrumentationRunnerArguments.class=xyz.paperclip.wallet.MainnetTorTest \
  -Pandroid.testInstrumentationRunnerArguments.liveTor=true connectedDebugAndroidTest
```

It bootstraps actual embedded Tor, connects to `ssl://pool.paperclip-xbt.xyz:50002`,
synchronizes the empty wallet and Ark state, then verifies that an unavailable
proxy cannot silently reconnect directly. `MainnetSafetyTest`, invoked separately
with `mainnetSafety=true`, checks mainnet creation and screenshot/restore isolation
in a fresh test installation. Keep the emulator clock synchronized:
mailbox authorization and TLS both depend on accurate time.

`FundedRecoveryTest` is separately opt-in (`fundedRecovery=true`). It requires an
isolated local regtest controller at emulator host port 39444 and an ASP at 39535.
The controller must refuse non-regtest chains. The test funds a disposable wallet,
exercises native sends and boarding, encrypts and restores its database, stops the
lab ASP, and mines an offline exit through confirmation. Never point this harness
at a production service. These network tests are skipped by the ordinary CI suite.

## Storage and recovery

Secrets and saved connection credentials use AES-GCM with a device-bound Android
Keystore key. App data lives in `noBackupFilesDir`; Android cloud backups are disabled.
If that key is missing, encrypted records are preserved and access fails closed.
Configure a device screen lock before ordinary use. The app locks on backgrounding.

Full backups use the iPhone `PAPERCLIP-BACKUP-1` envelope: AES-256-GCM, 12-byte nonce,
16-byte authentication tag and the header as authenticated data. The payload includes
the seed and a consistent SQLite export containing Ark recovery state. Keep the random
recovery key separately. Restore accepts an empty wallet only, validates the database
and seed ownership, and stages it in a new directory. Seed-only import is not an
offline Ark recovery backup. Cross-platform funded recovery still requires testing.

## iOS build 70 parity

The [parity matrix](docs/ios-parity.md) records the implemented features and their
validation limits. Android includes CLN/LND nodes, XBT LND BOLT12, both Bridge
directions, hardware/watch-only and multiple wallets, Coinjoin, message signing,
price display, advanced seed generation, maintenance and expiry reminders.
Payment uncertainty, fee review, certificate validation and recovery rules match
the iOS backend; platform adapters remain native Kotlin/JNI.

### Foldable and large-screen layouts

Wallet setup, dashboard, settings and the node connection editor reflow into two
columns when space permits. Cover screens and large accessibility text use a
single column. Jetpack WindowManager supplies actual separating fold/hinge bounds:
columns avoid the hinge, individual actions stay within one pane, and tabletop
posture uses the larger unobstructed pane. Payment and recovery forms remain in
one pane. Rotation and fold resizing preserve the live composition and drafts;
secrets are not added to saved-instance state. Backgrounding still locks the app.
Verified successful sends have a finite particle animation that respects disabled
system animations. Pending or uncertain payments do not show a success effect.

Before public distribution, complete physical-device lifecycle, sensor,
backup-picker, accessibility and 16 KB page-size runtime validation. Emulator
checks do not establish compatibility with every manufacturer's foldable.
Background work is opt-in and best effort: keep a current full backup and open
and synchronize the wallet regularly before Ark expiry.

### Lightning connection recovery (build 70 parity)

CLN read RPCs and LND read endpoints retry once after a transient transport
failure. The allowlist is explicit because CLN uses POST for observations too.
Payments, invoice/offer creation, authorization failures, and TLS failures are
never automatically retried. Cancelling a coroutine closes its OkHttp request.
Tor routing, redirect refusal, and exact certificate pin checks are unchanged.

Replacement settings are saved only after authenticated node identity/network
verification. The connection card shows progress, cancellation, reconnect, and
last-verification time. Failed balance refreshes retain a labelled last-known
balance. A foreground-only refresh checks balances every minute. Pending payment
tracking remains independent of whether the balance query has permission.

`NodeRetryTest` covers bounded reads, mutation/auth/TLS exclusion, and active
request cancellation. `LightningTransportTest` checks a local HTTPS server with
matching/mismatched certificate pins and no direct fallback for Tor. These are
synthetic/local checks; they do not claim live CLN/LND validation on Android.

## Optional live node verification

`NodeLiveTest` uses the real Kotlin/OkHttp adapter for read-only LAN `getinfo`
and channel reads, verifies the expected node identity, rejects an incorrect
certificate pin, and checks recovery. It is skipped unless
`PAPERCLIP_LIVE_CONFIG` names a protected local JSON input. Input format matches
the iOS simulator probe: `cases` containing `label`, `expectedIdentity`, and
`connection` (`implementation`, `endpoint`, `credential`, `certificateSHA256`,
`useTor`, `torProxy`). It does not test Android embedded Tor or a handset.
Never commit this input or print credentials; remove temporary copies afterward.

Both adapters accept up to four explicitly trusted SHA256 leaf fingerprints,
separated by commas. This accommodates servers such as StartOS that negotiate
different certificate algorithms with different clients. Every supplied pin
must come from a trusted source; a mismatch never adds a new pin automatically.
Malformed CLN rune characters fail before a request. Authentication errors,
permission errors, missing REST methods and connection timeouts have distinct
user-facing guidance. Cancelling Android Tor startup is labelled as cancellation.
