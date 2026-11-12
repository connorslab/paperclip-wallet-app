# Paperclip Android

Development branch: `feature/android-wallet`, based on the iPhone branch at
`2dea92bb9e0962def9f7aed413a5cff19d260e45`. No changes to the iPhone app or production
services are required to use this branch.

This branch builds a **private mainnet candidate**, not a public Android release.
Normal authenticated setup creates an XBT mainnet wallet. Existing regtest wallets
keep their network, and full backups retain the network recorded in the archive.
The default servers are Paperclip's mainnet Electrs and Ark endpoints, through
built-in Tor. Public-release signing and physical-device acceptance are separate
release gates; an APK signed with a development certificate is for private testing.

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

From the repository root, in a Linux/WSL shell:

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
`./gradlew assembleRelease` produces a non-debuggable, unsigned release APK. Sign
the final APK using the maintained Android application signing identity before
public distribution. Keep the same identity for updates; GPG does not replace
Android APK signing.
Keep keys, SDK installs and native build artifacts outside version control.

## Emulator and screenshots

Use an API 35 x86_64 emulator with hardware acceleration. Start from empty app
storage, set dark mode, then run:

```sh
adb shell cmd uimode night yes
for test in NativeBridgeTest WalletScreensTest; do
  ./gradlew -Pabis=x86_64 \
    "-Pandroid.testInstrumentationRunnerArguments.class=xyz.paperclip.wallet.$test" \
    connectedDebugAndroidTest
done
adb pull /sdcard/Pictures/PaperclipPreview ./screenshots
```

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
the service binding so a later connection attempt can start again.

The XBT Electrum transport explicitly negotiates protocol 1.8 and validates the
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

## Coverage and remaining iPhone parity

| Area | Android status |
| --- | --- |
| Navigation, branding, light/dark appearance | Implemented |
| Native wallet creation, seed confirmation, local on-chain receive, QR display | Validated in the API 35 emulator; physical-device validation remaining |
| On-chain / Ark sends | Funded native send paths validated in the Android regtest emulator |
| BOLT11 / BOLT12 sends | Shared native calls and review/result UI wired; funded Android end-to-end tests remaining |
| Ark Lightning invoices | Shared native receive call wired; claim/status UX needs completion |
| Electrum, Esplora, Knots RPC, certificate pinning | Mainnet Electrs/Tor and regtest RPC exercised; Esplora deployment testing remaining |
| Complete encrypted backup/restore | Funded native database recovery passed on Android; iPhone-to-Android funded archive testing remaining |
| Remote CLN/LND accounts | Not yet ported |
| Built-in Tor | Embedded bootstrap and mainnet Electrs connection validated; dead proxy fails closed |
| Hardware accounts, animated QR scanner/signing, multiple wallets | Not yet ported |
| Unilateral exit | Start, progress and claim controls wired; encrypted database restored and funded exit confirmed with lab ASP offline |
| Boarding, refresh and background maintenance | Native boarding available; manual refresh and expiry information in UI; background maintenance and boarding UI not yet ported |
| Coinjoin, message signing, price display, advanced seed entropy | Not yet ported |

Do not treat a successful build or a mainnet connection as full iPhone parity.
Before public distribution, finish physical-device lifecycle and backup-picker
checks, accessibility checks, ARM64 device testing, and 16 KB page-size runtime
loading. Keep a current full backup and open/sync regularly: Android does not yet
refresh expiring Ark funds in the background. The emergency-exit screen supports
starting, progressing and claiming exits without an online ASP; on-chain fees and
the chain's waiting periods still apply.
