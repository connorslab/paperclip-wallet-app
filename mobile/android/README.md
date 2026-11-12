# Paperclip Android preview

Development branch: `feature/android-wallet`, based on the iPhone branch at
`2dea92bb9e0962def9f7aed413a5cff19d260e45`. No changes to the iPhone app or production
services are required to use this branch.

This is an initial **regtest-only development build**, not a mainnet release.
Do not import real recovery words. Mainnet creation and full-backup import are
disabled until Android recovery, payment and physical-device validation are complete.

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
system appearance are supported.

## Build

Use JDK 17, Gradle 8.11.1 (included wrapper), Android SDK 35, build-tools 35.0.0,
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
Keep keys, SDK installs and native build artifacts outside version control.

## Emulator and screenshots

Use an API 35 x86_64 emulator with hardware acceleration. Start from empty app
storage, set dark mode, then run:

```sh
adb shell cmd uimode night yes
./gradlew -Pabis=x86_64 connectedDebugAndroidTest
adb pull /sdcard/Android/data/xyz.paperclip.wallet.android.preview/files/screenshots ./screenshots
```

The navigation test creates a disposable wallet through the real Rust engine and
captures onboarding, wallet, send, receive QR, Lightning, activity, connections,
and light/dark settings. It never captures recovery words or recovery keys.
The native test rejects malformed JNI inputs and verifies a database backup/restore
preserves the next derived address. Clear app data before repeating the screenshot
test; never clear a funded wallet to run tests.

Normal launches require biometric or device-credential authentication and disable
screenshots. The debug-only `regtestScreenshots` intent extra permits emulator test
captures; it cannot enable mainnet or bypass locking in release builds.

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

## iPhone parity remaining before a mainnet preview

| Area | Android status |
| --- | --- |
| Navigation, branding, light/dark appearance | Implemented |
| Native wallet creation/import, local on-chain receive, QR display | Implemented; emulator validation required |
| On-chain / Ark / BOLT11 / BOLT12 sends | Shared native calls and review/result UI wired; funded Android tests required |
| Ark Lightning invoices | Shared native receive call wired; claim/status UX needs completion |
| Electrum, Esplora, Knots RPC, certificate pinning | Connection UI and shared transport wired; deployment tests required |
| Complete encrypted backup/restore | Implemented; funded Android/iPhone recovery tests required |
| Remote CLN/LND accounts | Not yet ported |
| Built-in Tor | Not yet ported; explicit external SOCKS5h route supported |
| Hardware accounts, animated QR scanner/signing, multiple wallets | Not yet ported |
| Boarding, refresh, unilateral-exit controls and background maintenance | Native core available; Android workflows not yet ported |
| Coinjoin, message signing, price display, advanced seed entropy | Not yet ported |

Do not enable mainnet merely because the APK builds. Complete funded regtest flows,
interrupted-send/restart tests, offline ASP exit/recovery, lifecycle and backup-picker
tests, scanner/device round trips, accessibility checks, and ARM64 physical-device
testing first. Validate 16 KB page-size loading before a public Android release.
