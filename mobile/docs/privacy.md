# Paperclip XBT Wallet privacy notice

Effective October 17, 2026. Paperclip XBT Wallet is provided by Paperclip Holdings LLC.
Contact [contact@paperclippool.xyz](mailto:contact@paperclippool.xyz) for support or
privacy requests. This notice describes the iOS wallet. The
[Paperclip service privacy notice](https://pool.paperclip-xbt.xyz/privacy) also
explains data handled by Paperclip-hosted infrastructure, retention, service
providers, and privacy requests.

## Your device and keys

The wallet stores its local wallet records, preferences, and protected signing
material on your device. It does not require a Paperclip account. Hardware-wallet
private keys remain on the signing device. Public descriptors and extended public
keys can reveal wallet activity even though they cannot sign payments.

Seed creation runs locally. Default generation uses Apple's secure random API.
Dice results contribute locally to seed generation. Optional camera, microphone,
and motion samples are processed locally, are not saved as recordings or uploaded,
and are discarded from the collection when it ends or is cancelled. Sensor
measurements are diagnostics, not a validated estimate of additional seed strength.

Camera access also supports QR scanning. Device authentication uses Apple's system
authentication; Paperclip does not receive your Face ID biometric template.

## Network connections and public transactions

The servers you choose receive requests needed to synchronize balances, obtain
transaction history, broadcast transactions, or perform Ark and Lightning operations.
Requests may include script hashes, transaction identifiers, public keys, invoices,
amounts, protocol messages, and connection metadata. Node credentials authorize
requests to the configured node. Do not configure servers you do not trust.

Paperclip-hosted services may retain operational logs and protocol, payment, and
recovery records as described in the service notice. Other Electrum, RPC, Ark,
Lightning, and relay operators have their own practices. Blockchain transactions
are public and cannot be deleted by removing a wallet.

Optional Tor routing applies to the connections configured to use it; it is not a
device-wide VPN or a promise of anonymity. USD estimates request a public price
from xbt.live without wallet balances or identifiers. That request uses a direct
HTTPS connection; the provider can receive connection metadata such as an IP
address. The app caches the public quote locally.

Experimental Coinjoin uses a Nostr relay, by default relay.kilombino.com. Relay and
round participants receive protocol data; encryption does not eliminate traffic
correlation or all transaction linkage. External exchange, referral, explorer,
GitHub, and other website links are handled by their respective providers. The
NeoxEx signup link includes a Paperclip referral code.

## Backups and sharing

Encrypted full-wallet backups are exported only when you choose to save them using
Files. Choosing iCloud Drive or another cloud provider sends the encrypted file to
that provider under its terms. Keep the backup recovery key separately. Paperclip
cannot recover a lost seed or backup key. Files, screenshots, clipboard contents,
and information you explicitly share may be accessible to their recipients or to
other services according to your device settings.

## Permissions, notifications, and choices

Camera and microphone permissions are requested when their features are used.
You can revoke permissions in iOS Settings, use system-random seed generation
without sensors, and enter payment requests without the camera. Optional local
notifications can remind you about Ark expiry; disable them in iOS Settings.

You can change backend servers, disable optional Tor routes, remove local wallets
through Settings > Your wallets, or delete exported backups through Files. Preserve
recovery information before removing anything. Removing a wallet does not erase
public blockchains, provider records, exported files, or every copy retained by
operating-system backup services.

## Support, retention, and requests

If you contact support, we receive your email address and what you choose to send.
Never send seed words, private keys, backup recovery keys, RPC passwords, Lightning
runes, or macaroons. Local wallet data remains until you remove it; exported backups
remain wherever you save them. Paperclip service retention varies by record type,
including longer retention needed for payment reconciliation, security, recovery,
and legal obligations; see the linked service notice.

Email contact@paperclippool.xyz to request access, correction, or deletion of
information associated with you, or to withdraw consent for optional information
you provided. Requests may require proportionate verification and are subject to
necessary legal, security, accounting, and recovery retention. We cannot erase
blockchain records or control independent providers' records.

This notice will be updated when app data practices change. Material changes will
be explained through the affected service as required by applicable law.
