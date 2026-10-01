# Paperclip iPhone proof of concept

Development branch: `feature/ios-wallet`. Does not change public wallet releases.
This is an **unfunded prototype**, not an installable production wallet or TestFlight release.

The SwiftUI app includes Paperclip styling, reduced-motion support, automatic
refresh preferences, foreground checks, BGAppRefreshTask/BGProcessingTask registration,
cancellation, and local expiry reminders. The Rust bridge links the existing wallet
engine. The wallet lab creates and reopens a regtest wallet, persists on-chain address
indexes, and connects to an explicitly configured regtest ASP and indexed RPC backend.
Mainnet is rejected by the bridge. Keys and connection credentials use device-only
Keychain storage accessible after first unlock; database files use protected storage
and are excluded from automatic device backups.

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

## Encrypted iCloud Drive backup

The prototype includes AES-256-GCM authenticated backup encoding and a Files export/import
screen. Users choose iCloud Drive, save a separately generated recovery key outside iCloud,
and re-enter it before export. The archive contains the seed and complete Ark recovery
state, not just a mnemonic. Wrong keys and altered files are rejected before import.
Restore must target an empty wallet and validate native recovery state before committing.

This is manual file backup, not automatic cloud synchronization. Files manages upload;
saving a file does not confirm its upload completed. Backups do not prevent VTXO expiry.
Native export uses a SQLite snapshot that includes committed WAL state. Restore validates
the database and key/network association in a staging directory before renaming it into
an empty wallet location. A failed staging import is retained for diagnosis rather than
overwriting existing data. Physical-device iCloud round trips remain required before release.

## Build verification

GitHub workflow: `iOS proof of concept`. It compiles the native wallet for iPhone and
Apple-silicon simulator, runs Swift policy tests, builds the app, and runs a simulator
native-bridge smoke test. Artifacts are unsigned simulator apps, not device IPAs.
Local policy tests: `cd mobile && swift test`. Generate the project using XcodeGen.

## Still required before a funded mobile test

- Complete end-to-end regtest payment and recovery verification for the new native bridge.
- Add a polished wallet dashboard, activity reconciliation, and direct on-chain payment
  review. The current payment form spends Ark funds; on-chain destinations use offboarding.
- Add an optional biometric policy. The test wallet explicitly uses after-first-unlock
  access; biometric presence on every access prevents unattended refresh while locked.
- Add validated public chain-data access and embedded Tor routing.
  Do not ship an unrestricted public Bitcoin RPC endpoint or leak onion DNS requests.
- Verify kill/restart during every refresh phase, offline expiry handling, and backups on
  physical devices. Simulator tests cannot establish real background scheduling reliability.
- Add Apple organization signing credentials and provisioning for TestFlight.

The existing ASP and live wallet data are not touched by this prototype.
