# Android parity with iOS build 70

Android now implements the iOS feature set in the Android UI, Kotlin adapters,
JNI boundary and shared Rust engine. The platform interfaces differ; the money,
validation and recovery rules are shared. No production payment, channel opening,
or service restart was used to validate this work.

| iOS capability | Android implementation | Evidence |
| --- | --- | --- |
| Ark fees, Send Max and recovery suggestions | Shared fee/selection fixes, reviewed maximum, durable pending state, separate funding/settlement status | Rust mobile tests; Kotlin payment policy tests |
| On-chain and Ark connections | Electrum, Esplora and RPC; certificate pin; independently routed Ark RPC; saved per-wallet settings | Connection round-trip tests; live unfunded Electrum/Ark synchronization over embedded Tor |
| Embedded Tor | Shared bootstrap, independent waiter cancellation, control-reply deadlines, stage errors, retry, explicit SOCKS route, no direct fallback | Shared-startup unit tests; opt-in runtime lifecycle test; mainnet/dead-proxy test |
| Remote CLN and LND | Encrypted credentials, HTTPS/pinned certificates, mainnet/regtest validation, channel balances, invoices, reviewed sends and persistent outgoing status | Authenticated local TLS fixture; pin/redirect rejection; status and balance regression tests |
| XBT LND BOLT12 | Native offers API, offer fetch, exact invoice/amount/expiry/chain/fee validation and preimage checks | BOLT12 policy tests; no live payment |
| Lightning balance display | Active channel funds headline; separate spendable funds, reserves and receive capacity | 230,000-sat balance/500,000-sat reserve regression |
| Paperclip Bridge | Both directions, Ark or node funding, reviewed fees, persisted intent, read-only reconciliation and settlement proof | Invoice/quote binding tests; no live swap |
| Multiple wallets | Generate/import/select/rename/remove, legacy migration, scoped connections and pending records, interrupted removal recovery | Emulator native removal/recovery test |
| Hardware and watch-only wallets | Four script types, public QR/descriptor review, receive/change derivation, public export, QR signing and hardware-funded boarding | iOS public signer fixtures pass on Android native engine; animated QR unit tests |
| Coinjoin | Separate account, v4 backend, pools, multi-output review, signing, transfer, migration and recovery; isolated Tor output connections | Native account persistence/isolation; fee review, TLS hostname, SOCKS isolation and relay resource-limit tests |
| Ark receives and offers | Invoice/offer creation and status, receive claim recovery, foreground listener | Shared backend tests and adapter review; no funded receive |
| Ark maintenance and exits | Boarding review, refresh, seed recovery, emergency exit progression and claims; optional foreground/background maintenance | Native build and emulator navigation; no exit broadcast |
| Expiry reminders | Block-based windows, estimated timing, offline recheck, wallet-scoped cancellation | Policy tests matching iOS windows |
| Seed generation | 12/24 words, secure system RNG, D6/D12/D20, optional camera/audio/motion mixing, full-word confirmation | iOS entropy vectors and sensor diagnostic tests; onboarding emulator test |
| Backups | Encrypted complete backup/restore, recovery key kept separately, public-only export for public wallets | Native unfunded recovery test; public exports contain no seed or identity |
| On-chain tools and messages | Account selection, receive/change pagination and address QR; authenticated exact-message BIP322 signing | Shared native tests and emulator navigation |
| Display and activity | Sats/XBT inputs and balances, exact conversion, USD estimate/cache, hidden wallet balances, appearance, activity details/receipts/share | Amount/price/activity tests; emulator screenshots and navigation |
| Notifications | Opt-in private payment status alerts and baseline reset; selected-wallet maintenance | Baseline tests; notification delivery still depends on Android permissions/scheduling |
| Connections and security UI | Built-in/external Tor, device authentication preference, protected local storage | Emulator build/navigation; default authentication remains enabled |
| Foldable and wide layouts | Two-column setup/dashboard/settings/node editor, real hinge bounds, one-pane tasks/tabletop, large-text stacking, preserved resize drafts | Adaptive Compose geometry and draft tests; Pixel Fold emulator review |
| Verified success feedback | Finite particle animation only for terminal success; system animation preference respected | Source review and emulator rendering |
| Help and buy links | iOS support/privacy/recovery and external exchange links; bundled dependency notices | Source comparison and APK packaging |

## Validation limits

- Tests use an API 35 ARM64 emulator, local protocol fixtures, and temporary
  unfunded wallets. No physical Android phone was available.
- No hardware signer was used to approve a new transaction, and no funded
  Lightning payment, bridge swap, Coinjoin round, boarding or exit was executed.
  Public signer fixture compatibility and shared native verification tests do
  not replace those live checks.
- Camera/audio/motion capture requires real-device sensor and permission testing.
  Diagnostics do not establish an entropy estimate; sensor material supplements
  secure system randomness.
- Unknown payment outcomes remain recorded and block automatic resending.
  Network outages do not establish payment failure.
- HTTP Lightning endpoints are supported only for an explicitly configured Tor
  onion route with no TLS pin. HTTPS never downgrades and retains certificate
  validation. Public RPC endpoints require TLS; LAN RPC remains configurable.
- Android's background timing differs from iOS. Neither platform guarantees that
  background refresh or a reminder runs before an Ark expiry height.

## Reproducible checks

Use native Java 17, the Android SDK and NDK 28.0.13004108:

```
./mobile/android/gradlew -p mobile/android testDebugUnitTest assembleDebug -Pabis=arm64-v8a
./mobile/android/gradlew -p mobile/android assembleDebugAndroidTest -Pabis=arm64-v8a
```

Run instrumentation classes individually and check `OK (1 test)` rather than
assuming a successful Gradle invocation executed every requested class:
`WalletScreensTest`, `WalletProfilesNativeTest`, `PublicWalletNativeTest`,
`CoinjoinAccountNativeTest`, `WalletSettingsScreensTest`, and `NativeBridgeTest`. `MainnetTorTest` requires
explicit `liveTor=true` and uses a newly created unfunded directory.
Do not run funded recovery tests as part of this suite.

The earlier feature-parity baseline built both ARM64 and x86-64 native release
libraries, passed six emulator workflow tests and the live unfunded Tor check.
The build 70 validation record is in [build70-validation.md](build70-validation.md).

The shared backend port is commit `8524397` on `codex/android-backend-parity`,
based on `feature/android-wallet` at `e17f2508fb2faf0448129e945ae82d41c5152b78`.
The Android candidate is version `0.2.0-parity.70` (4). It is a test APK, not a Play
Store release. iOS build 70 is distributed separately through TestFlight and was
submitted for App Store review.
