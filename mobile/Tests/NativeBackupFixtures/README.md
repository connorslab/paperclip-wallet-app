# Native mobile backup interoperability fixtures

These are public, synthetic **XBT regtest** wallets. They have no funds or node
credentials. Their fixed test seed and recovery key are deliberately public;
never use them for a real wallet.

The JSON fixture contains a native version-2 database snapshot, one issued address
in each of the Taproot and SegWit accounts, and an unresolved synthetic payment.
SegWit is selected. Expected next addresses and payment references live beside
the archive. No transaction was submitted to produce these fixtures.

The Android archive was restored and re-exported through the Android JNI engine,
then encrypted by `BackupCodec` on an isolated API 35 ARM64 emulator. The iOS
archive was restored from that Android export through the iOS C ABI and
re-encrypted with `EncryptedBackup`/CryptoKit on an isolated ARM64 iOS simulator.
Both use the same public recovery key. Generated on 2026-11-18 with native runtime
source at `047dfa5739e1e88a440fe7013c4929eb4090a5da`; this change adds the tests
and generator without changing that runtime.

`BackupInteropTest` must import the iOS archive, and `BackupInteropTests` must
import the Android archive. Both verify seed/network rejection, account selection,
next-address cursors, the unresolved payment reference and rejection of a new
quote or send. Missing fixtures fail the test. These checks do not establish
legacy app-profile migration, portability of node/Bridge records or credentials, live
payment reconciliation, or physical-device acceptance.

The app-adapter tests additionally restore these archives beside an existing
hot wallet. They verify that a wrong-seed archive preserves the current profile,
a valid restore creates a separate selected profile, and a duplicate restore
leaves both profiles intact. The original receive address and restored payment
warning survive switching in both directions. Android closes/reopens its engine;
iOS reads the committed selection through a fresh Keychain-backed adapter.

## Regeneration

1. In the repository development environment, set `PAPERCLIP_BACKUP_FIXTURE` to
   an explicit temporary output file and run
   `just unit-mobile native_backup_interop_fixture`. Copy that output to
   `native-v2-regtest.json` here. The generator does not write files without this
   explicit environment variable.
2. Build and run Android `BackupInteropTest.nativeArchivePreservesAccountsAndPendingAttempt`
   on an owned disposable emulator. Copy
   `files/backup-fixtures/android-v2-regtest.pcbackup` from the preview app's
   external-files directory into this folder.
3. Generate the iOS project with XcodeGen and run native
   `BackupInteropTests.testAndroidArchivePreservesAccountsAndPendingAttempt`
   using a current simulator Rust library. Copy
   `Documents/backup-fixtures/ios-v2-regtest.pcbackup` from the isolated
   `xyz.paperclippool.wallet.native-test-host` container into this folder.
4. Rebuild test assets and run both Android tests and the iOS test. Record the
   new runtime revision and hashes. Do not copy fixtures from a funded app or
   include its logs, seed, credentials or private archive.

Exports are written before consuming the expected next addresses. Encryption
uses fresh nonces, so regeneration changes archive hashes. Check semantic test
results instead of expecting byte-for-byte deterministic ciphertext.

## Checked fixture SHA-256

- `native-v2-regtest.json`: `0916665bbff1d87d88907524630374a5835f1536a1a313d654353202e081c042`
- `android-v2-regtest.pcbackup`: `5f99f0718fde7ae96e59385bf14ded74ec24fb2b91e325bf871acf31b3ea4bba`
- `ios-v2-regtest.pcbackup`: `27c30976024c32505f4d8e6a5da006e1eb2d6850f259cdf5caa92ac400a625d0`
