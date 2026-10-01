# Paperclip iPhone proof of concept

Development branch: `feature/ios-wallet`. Does not change public wallet releases.
This is an **unfunded prototype**, not an installable production wallet or TestFlight release.

The SwiftUI app includes Paperclip styling, reduced-motion support, automatic
refresh preferences, foreground checks, BGAppRefreshTask/BGProcessingTask registration,
cancellation, and local expiry reminders. The Rust bridge links the existing wallet
engine and tests ephemeral regtest key derivation. It exports no payment, address,
or seed-import interface. The preview's wallet engine is deliberately unconnected;
it never represents a failed check as a successful refresh.

## Refresh design

- iOS chooses whether and when background tasks run. Foreground entry also requests a check.
- Automatic renewal is enabled by default in the preview settings; users may turn it off.
- Check fresh chain state before renewal. Do not refresh expired or locked inputs.
- Production integration must use Bark's checkpointed round machinery, reconcile pending
  work before resubmission, and report a scheduled round separately from confirmed renewal.
- A canceled request may already have reached the ASP. Never infer failure or release
  locked inputs merely because iOS ended the background task.
- Reminder thresholds are estimated 432/144/72 blocks before expiry, plus a stale-data
  check after six hours. These are reminders, not guaranteed deadlines. The engine must
  supply the correct network block interval. Recompute after every successful sync.
- Coalesce notifications by wallet urgency; never include balances, addresses, or VTXO IDs.
- Retain existing OS-scheduled reminders on network failure. Only remove obsolete reminders
  after successfully scheduling replacements from current state.
- Denied notification permission must remain visible. Opening a reminder opens the app,
  which performs the same foreground check. No background-mode workaround is used.

## Build and test

GitHub workflow: `iOS proof of concept`. It compiles the native wallet for iPhone and
Apple-silicon simulator, runs Swift policy tests, builds the app, and runs a simulator
native-bridge smoke test. Artifacts are unsigned simulator apps, not device IPAs.
Local policy tests: `cd mobile && swift test`. Generate the project using XcodeGen.

## Still required before a funded mobile test

- Wire a native session/FFI adapter for wallet creation, sync, refresh, and payment operations.
- Store keys in Keychain and wallet/Ark recovery data in protected persistent storage;
  implement full recovery export and restore. A mnemonic alone is insufficient.
- Decide whether background key access after first unlock is enabled. Requiring biometric
  presence for every key access prevents unattended signing while locked; never silently
  weaken that preference to make background refresh work.
- Add validated public chain-data access, custom RPC credentials, and embedded Tor routing.
  Do not ship an unrestricted public Bitcoin RPC endpoint or leak onion DNS requests.
- Verify kill/restart during every refresh phase, offline expiry handling, and backups on
  physical devices. Simulator tests cannot establish real background scheduling reliability.
- Add Apple organization signing credentials and provisioning for TestFlight.

The existing ASP and live wallet data are not touched by this prototype.
