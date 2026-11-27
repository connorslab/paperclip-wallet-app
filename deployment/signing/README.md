# Release signing identities

Created on 2026-11-19 for the first Android and native desktop releases.
Only public certificates and the public release key belong in this directory.
Signing is separate from release acceptance and publication.

## Android

Production application ID: `xyz.paperclip.wallet.android`.
Development builds retain `xyz.paperclip.wallet.android.preview`; installing the
production app does not replace the preview or copy its wallets implicitly.
Use an encrypted wallet export and verified restore to migrate between them.

The app signing certificate is `android-app.pem` (RSA 4096):
`5BD144687BB47A210F8462F8B0FA1D6DB2EBFC06DBE5425A0F63566D4FADE189` (SHA-256).
The separate Play upload certificate is `android-upload.pem` (RSA 4096):
`AB16A0F072F6777B2A5534A19342225FD222F6E69607D923204061C78E362BC1`.

If Google Play is added later, during first Play App Signing enrollment, import the **app** key using Google's
PEPK procedure, and register the separate upload certificate. Direct APKs and
Play-delivered APKs must use the same app signing certificate to permit updates
between channels. The AAB upload signature uses the separate upload key.
Never substitute the development certificate or regenerate an identity for an
update. See [Android app signing](https://developer.android.com/studio/publish/app-signing).

Build native libraries with the release profile for both ABIs, then run Gradle
`assembleRelease`. Sign the initial release APK locally:

```
python3 deployment/signing/sign_android.py \
  --apk /absolute/path/app-release-unsigned.apk \
  --output /absolute/path/new-candidate-directory \
  --sdk /absolute/path/android-sdk --java-home /absolute/path/jdk
```

The script obtains passwords through the local no-prompt Keychain helper, uses
private temporary password files, checks the public identities, signs, verifies
the APK signature and alignment, and signs the checksum manifest. It never
publishes. Keep the exact native/source hashes with each candidate. The script
does not turn a development native library into a release library or certify
payment, restore or upgrade acceptance.

## Linux and release manifests

The Ed25519 release key is `linux-release-public.asc`.
Fingerprint: `EA034CC6E0E048811266E8E9D95A43AAA5171575`.
The signing identity is `Paperclip Wallet Releases`, with a two-year expiration.
Verify detached signatures and checksums against this reviewed public key.
Renew the existing identity before expiry; do not silently replace it.

## Private storage and recovery

On the release Mac, private encrypted keystores and the GnuPG home are under
`~/Library/Application Support/Paperclip Release Signing` (owner-only directory).
Passwords are generic-password items in the login Keychain service
`xyz.paperclip.release-signing`: `android-app`, `android-upload`, `linux-release`,
`macos-developer-id`, and `recovery-bundle`. The helper explicitly disables
interactive authentication; a locked or inaccessible Keychain fails the step.
No passwords or private keys are stored in Git or CI secrets.

`keychain.swift` is the source of the local helper. On a replacement Mac, compile
it with `swiftc deployment/signing/keychain.swift -o /private/path/keychain-helper`
and restrict the executable to its owner. Its `read` and `open` actions return
secrets over stdout: use them only from a process that captures the output.
Do not invoke these actions in a terminal or paste their output into chat.
The helper fails when the Keychain requires user interaction. Do not replace the
current executable or change Keychain access policy as part of an unattended build.

An AES-256-GCM recovery archive contains the encrypted private keys, their
passwords, public certificates, and the GPG revocation certificate. Its random
recovery key is the `recovery-bundle` Keychain item. Authenticated decryption was
verified. An isolated restore also verified both Android certificates and a new
signature made with the restored Linux private key. Two encrypted local copies exist: in the private signing directory and
`~/Paperclip Backups/Release Signing`. These are on the same Mac and are **not**
an independent disaster-recovery backup. The owner must retain an off-device
copy and store its recovery key separately before relying on it for recovery.
Never include this signing archive in a wallet release or support attachment.

## Issuer and account requirements

An encrypted macOS RSA key and verified CSR are prepared locally. An Apple-issued
Developer ID Application certificate and notarization are still required.
The existing iOS distribution certificate does not replace Developer ID.
See [Apple Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

For Windows public signing, the owner must arrange [Microsoft Artifact Signing](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)
or another trusted Windows signing provider. Artifact Signing manages its key;
a locally generated self-signed certificate does not satisfy public trust.
No enrollment fee or subscription has been purchased.

Windows distribution is MSI or EXE through GitHub Releases only. Do not use the
Microsoft Store. A self-signed Windows certificate can identify a test artifact,
but it does not meet the publicly trusted publisher-signing requirement.

Microsoft Artifact Signing can sign a GitHub-distributed installer without a
Store listing. The owner must complete its identity verification before public
trusted signatures can be produced.
