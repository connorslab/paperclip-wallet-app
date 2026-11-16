# Coordinated Paperclip release

The next major release includes iOS, Android, Umbrel and StartOS from one reviewed
source revision. Android distribution includes **Google Play and a signed APK
download**. Prepare candidates independently, then publish in one coordinated
release window after every platform meets the acceptance criteria below. Store
review and propagation can finish at different times; do not promise simultaneous
availability to the minute.

The release version and date are not assigned yet. The current version numbers
(Apple build 70, Android preview code 4, server 0.10.0) identify existing candidates,
not a completed unified release. Do not reuse an uploaded build number, rewrite an
existing release tag, or replace a published binary in place.

## Source and artifacts

- Freeze one source commit in `connorslab/paperclip-wallet-app`. Record the commit,
  dependency lockfiles, native toolchain versions and CI runs for every artifact.
- Build the Apple archive with the native Apple toolchain and existing signing
  identity. Preserve the production bundle ID, Keychain groups and wallet data.
- Build the Android App Bundle for Play and APK download from the same commit,
  version name, version code, resources and native libraries. Verify ARM64 and
  x86-64 packaging, release-only behavior and supported page sizes.
- Confirm the Android application ID and signing certificate against the installed
  app and Play Console before selecting the release identity. The current preview
  uses `xyz.paperclip.wallet.android.preview` and development signing. An app signed
  with a different certificate cannot update it in place. Do not uninstall a
  funded preview to work around a signing mismatch; validate full backup/restore
  and an explicit migration first.
- The Play upload key and installed-app signing key may differ. Sign a direct APK
  with the installed-app key, not merely the AAB upload key. If Google holds the
  app signing key, obtain the distributable signed APK from Play Console. Verify
  the certificate on both channels before claiming cross-channel updates work.
- Build and test Linux AMD64 and ARM64 images. Both platform wrappers must pin the
  same reviewed multi-architecture image digest. Record wrapper commits separately.
  StartOS 0.4 uses `paperclip-wallet-startos`, not the legacy 0.3.5 generator here.
- Publish checksums, immutable image digests and the existing Paperclip release
  signature described in `RELEASE-SIGNING.md`. Native signatures remain required.

Google documents the distinction between upload and app-signing keys in
[Sign your app](https://developer.android.com/studio/publish/app-signing) and the
Play-signed download option in its
[App Bundle FAQ](https://developer.android.com/guide/app-bundle/faq).

## Acceptance matrix

A feature is complete only when users can perform the same task with equivalent
validation, recovery and error handling. A shared library or visible menu alone
does not establish parity. Native UI and background scheduling can differ.

| Area | Mobile candidate | Desktop / Umbrel / StartOS candidate | Remaining acceptance |
| --- | --- | --- | --- |
| Ark payments and recovery | Shared engine, durable payment status, cost review | Shared engine, cost review, status UI | Deploy cookie-rotation fix, verify failed receive recovery and both-direction settlement |
| Lightning through Ark | Shared BOLT11/BOLT12 engine and enforced reviewed debit | Same engine, fixed-amount review and debit capability | Verify live against corrected service; keep unknown outcomes from being resent |
| Remote CLN and XBT LND | Both adapters, Tor, TLS, BOLT12, balances and status | Direct-node adapters, private credential storage, reviewed sends and durable status implemented | Live node, container Tor and platform package acceptance pending; see REMOTE-LIGHTNING.md |
| Multiple / hardware / watch-only wallets | Implemented in mobile candidate, visible wallet switcher | Hot/public-account switcher, QR and watch-only pairing, public export/removal, verified signing and durable broadcast journal | Physical Krux round trips, desktop multiple hot profiles, QR-funded Ark boarding and full recovery |
| Paperclip Bridge | Both mobile directions implemented | Browser flows still missing | Matching quote validation and durable reconciliation; live swap not verified |
| JoinBlaket / Jam | Five jars, remote session, receive, reviewed maker controls | Same tasks through authenticated fixed-upstream proxy | Actual Kilombino XBT Jam endpoint, live validation, bond setup and taker flows |
| Existing Kilojoin funds | Recovery UI retained; new rounds rejected before database access | No new Kilojoin entry point | Verify existing-round completion and withdrawal on upgraded wallets |
| Backups / upgrades | Encrypted full backups and scoped mobile wallet state | Complete volume backups | Restore tests, update migrations and desktop backup UX |
| UI and accessibility | Phone / Duo / foldable adaptive layout, nested tab histories | Four primary menus, browser history/focus, responsive account switcher | Physical-device and screen-reader checks; see UI-UX-VALIDATION.md for local simulator/emulator/browser evidence |
| Distribution | Apple build 70 remains existing release; Android development builds | Existing packages predate current fixes | Signed candidates, store eligibility, clean-install and update tests |

## Feature audit: 2026-11-15

This audit inspected candidate `8d2fdfc2648ee407c750d3a11689e4436206f810`.
Implementation, local tests and published delivery are separate states. Neither
matching menus nor a passing build establishes live feature parity.

### Source and package alignment

| Surface | Inspected revision | Result |
| --- | --- | --- |
| Shared candidate and Android branch | `8d2fdfc` on both branches | Aligned candidate source |
| Default `main` branch | `69eb582` | 107 commits behind the inspected candidate; no mobile tree |
| Remote iOS release branch | `2dea92b` | 31 commits behind the candidate; local build 70 changes were imported separately into the candidate |
| StartOS 0.4 wrapper | `a396d8cf9dd3150cd42f02d56d0f3737628769cf` | Pins the November 11 image below |
| Umbrel wrapper | `80a91ad5acd3abc764f82d92758b6b7d40e1cd65` | Pins the same image |

Both wrapper manifests pin
`beta-42930294633@sha256:94df29f5c78a4e9319c0d2695831ce35ac0cb9e528092a898a1fc46028d2613b`.
They do not yet deliver the current candidate. This is a manifest inspection,
not a fresh inspection of the running services or App Store/TestFlight state.
The original iOS worktree and its uncommitted changes remain untouched.

### Task-level comparison

“Implemented” below describes the candidate source, not production acceptance.
Standalone desktop, Umbrel and StartOS use the shared browser/server implementation;
the wrappers still require platform-specific configuration and upgrade tests.

| User task | iOS candidate | Android candidate | Shared browser/server candidate |
| --- | --- | --- | --- |
| Send/receive Ark, BOLT11 and BOLT12 through Ark | Implemented | Implemented | Implemented; live receive/recovery still needs verification |
| Review Ark/Lightning total debit | Enforced shared-engine cap | Enforced shared-engine cap | Enforced cap for these two paths |
| Review a hot-wallet on-chain send | Exact PSBT, fee/total, expiry and input checks | Same shared transaction review | Amount-only confirmation; miner fee is additional, without matching reviewed-total enforcement |
| Review boarding cost | Prepared transaction and reviewed breakdown | Same shared review | Generic amount confirmation; detailed fee/recovery review is missing |
| Recover an uncertain send after closing the client | Durable mobile intent/status | Durable mobile intent/status | Hot-wallet warning is tab-scoped; QR broadcast journal is durable |
| Use Send Max | Implemented for supported Ark/on-chain routes | Implemented | REST has drain operations, but the browser has no equivalent reviewed Send Max flow |
| Connect directly to CLN/XBT LND, including BOLT12 | Implemented | Implemented | Direct-node adapters, credential storage and UI missing; existing Lightning UI uses Ark |
| Use Paperclip Bridge in both directions | Implemented | Implemented | Missing browser/server flows |
| Switch multiple hot wallets | Implemented | Implemented | One hot wallet per server |
| Pair/switch/sign with multiple Krux wallets | Implemented | Implemented | Public QR accounts and shared verifier implemented; physical signer round trip pending everywhere |
| Import a watch-only wallet | Implemented | Implemented | Separate watch-only account kind missing |
| Rename/remove/export a public wallet | Implemented | Implemented | Rename implemented; remove/public-export management missing |
| Fund Ark from a QR signer | Implemented | Implemented | Missing browser flow |
| Use five JoinBlaket jars and maker controls | Implemented adapter/UI | Implemented adapter/UI | Implemented adapter/UI; actual service connection unverified |
| Set up fidelity bonds, taker mixing and full Jam jar management | Incomplete | Incomplete | Incomplete |
| Recover previous Kilojoin funds | Recovery paths retained | Recovery paths retained | No equivalent browser recovery workflow; never enable new Kilojoin rounds |
| Create/import and back up wallets | Seed creation/import and encrypted complete backup/restore | Same major tasks | Creation and platform volume backups; matching encrypted import/export/restore UI missing |
| View normal on-chain transaction history | Implemented | Implemented | Hot-wallet records are fetched into technical details, while the normal Activity list renders Ark movements only; QR accounts have their own history |
| Select XBT/sats, hide balances, see cached fiat estimates | Implemented | Implemented | Browser uses sats and lacks matching privacy/display controls |
| Sign/verify address ownership messages | Implemented | Implemented | Implemented for the hot wallet |
| Maintain Ark funds and progress emergency exits | Implemented, subject to mobile scheduling | Implemented, subject to mobile scheduling | Service-side maintenance and exit actions implemented; funded upgrade/recovery acceptance pending |
| Navigate on phone, wide and foldable screens | Simulator-tested adaptive layouts | Open/cover emulator tests, including larger text | Browser tests at phone/tablet/desktop widths; physical accessibility checks pending |

### Newly confirmed release gaps

1. **Exact debit review:** `web/app.js` sends hot on-chain payments directly to
   `onchain/send`. `bark-rest/src/api/v1/onchain.rs` selects a fee rate at execution.
   In contrast, `mobile/rust/src/session.rs` retains the reviewed PSBT and checks
   its amount, total, expiry and inputs before signing. Boarding has a similar
   browser/mobile review gap. Extend the server contracts before adding a visual
   fee estimate; a display-only estimate does not establish parity.
2. **Durable uncertain outcomes:** browser `mutate()` stores its warning in
   `sessionStorage`. A new tab does not inherit that warning. Core payment records
   may survive, but the browser does not reconstruct the same wallet-scoped intent
   and reconciliation gate as mobile. The newer QR broadcast journal does not
   close this gap for hot-wallet operations.
3. **Activity completeness — closed in the candidate follow-up:** normal deposits
   and on-chain sends now have readable Activity cards, alongside Ark movements.
   All / On-chain / Ark filters, confirmation state, honest unknown fees, partial
   failure notices and bounded rendering also cover QR account history. The old
   comparison table above describes the original audit revision. This follow-up
   does not change the versions currently delivered by either platform wrapper.
4. **Packaged JoinBlaket configuration:** the server proxy requires
   `BARKD_JOINBLAKET_URL` and optional Tor/CA settings. Neither inspected wrapper
   supplies those settings. A working jar screen in local fixtures does not mean
   users of either package can connect Kilombino's service through platform setup.
5. **Default-server documentation:** `deployment/PLATFORMS.md` and the legacy
   package generator name `ark.paperclip-xbt.xyz`; the active wrappers inject
   `ark.paperclippool.xyz`. Confirm the intended service and align release docs
   and packaging without overwriting saved connections.

The audit also found and fixed a browser receipt navigation regression:
**View activity** referenced the removed `showView()` function. It now uses
`PaperclipNavigation.show()`. The browser regression verifies the receipt closes,
Activity opens, and the selected menu updates at 390, 800 and 1280 pixels, without
submitting a wallet action.

### Implementation order

First close exact-review and durable-status gaps. Then complete direct
CLN/LND and Bridge on the shared server/browser, followed by multi-wallet,
watch-only, backup and QR boarding workflows. Complete Jam service configuration
and remaining maker/taker tasks before treating that feature as finished. Finally
validate one frozen revision in signed mobile candidates and both platform
packages, including upgrade/restore tests. Do not merge or deploy merely to make
branch names match while these acceptance gaps remain.

## Production-readiness follow-up: 2026-11-15

The requested finish line is production readiness on all four platforms, not
just matching source branches. The original comparison above remains an audit of
its named revision. The following candidate changes supersede specific gaps:

- Exact hot-wallet on-chain review now uses prepare/commit with a retained PSBT,
  wallet binding, expiry, cost and input checks.
- Server boarding now has the same review categories as mobile: net Ark funds,
  recovery reserve, included boarding fee, network fee and total debit. It retains
  and consumes the exact funding transaction. Live funded acceptance is pending.
- Ordinary-send fee replacement, owned-wallet destinations, mobile restore checks,
  health and allowlisted support reports are implemented. See PAYMENT-ASSISTANCE.md
  for the limits; RBF is not a generic retry or a protocol-funding fee bump.
- Android targets API 36 for the candidate. Google requires API 36 or higher for
  phone app submissions from August 31, 2026. Edge-to-edge, supported BackHandler
  navigation and foldable layouts must remain verified after this change.
  [Target requirements](https://developer.android.com/google/play/requirements/target-sdk)
  and [Android 16 behavior changes](https://developer.android.com/about/versions/16/behavior-changes-16).

The direct CLN/LND server and browser candidate now includes TLS/Tor transport,
BOLT11/BOLT12, reviewed sends and durable unknown-payment reconciliation. Local
synthetic-node tests cover both adapters; live node and installed-package acceptance
remain pending. See REMOTE-LIGHTNING.md.

The server hot-wallet candidate now includes durable submission receipts and exact
status recovery across browser restarts, including interrupted on-chain, Ark,
Lightning, withdrawal and recovery operations. Older-server financial submission
fails closed. See PAYMENT-ASSISTANCE.md for the remaining crash-window, archival
and installed-package acceptance limits.

Invoice receipts on iOS, Android and the shared server now require the original
invoice, payment hash and amount to agree. LND settlement also requires its
settled flag, and CLN must return exactly one matching invoice. Android Bridge
checks the receiving node independently of bridge-service availability, and
requires a matching, unpaid node invoice before quoting a receive. An outgoing
bridge status alone cannot establish settlement without valid payment proof.
Synthetic regression checks passed: 40 REST tests, 9 Swift bridge tests and 75
Android unit tests (3 skipped). These checks do not establish live bridge or
installed-package acceptance.

The browser/server public-wallet candidate now supports watch-only accounts,
public descriptor exports and removal from the wallet list. Signing and broadcast
are rejected by the server for watch-only accounts. Removal requires the exact
wallet name and backup acknowledgement, and is blocked while the saved broadcast
has not confirmed. It archives the account instead of deleting the database:
importing the same public account restores address indexes and history. A missing
database is an error, never an invitation to create a fresh address history.
Existing QR accounts retain their signing type when loading the older schema.
Public exports contain no spending keys, but reveal wallet addresses and activity;
the export review explains that privacy consequence.

Synthetic tests cover archive/restore index continuity, missing-database refusal,
watch-only signing refusal, public export, active-account removal and uncertain
broadcast blocking. Browser flows pass at 390 and 1280 pixels. The Android compact
menu smoke test and separate settings test pass on an unfunded API 35 emulator;
the CI test now follows the nested menu routes introduced by the compact layout.

The broader gaps remain open: Bridge browser flows, full server wallet management and recovery,
Jam service acceptance, payment requests, portable contacts/labels and restricted
receive-only credentials. Public signing identities, coherent release versions,
physical signer tests, funded recovery and both host upgrade paths remain release
gates. Existing uploaded build 70 is not replaced by these source changes.

## Live verification and budget

Use the existing authenticated LND and CLN on StartOS. Preserve TLS verification
and imported credentials. Record identity, network, balances, invoice/offer chain,
amount, fee cap, payment hash and terminal status without secrets or preimages in
logs. Test network interruption, retry after a failed connection, foreground /
background transitions and recovery of an uncertain payment.

The authorized total is **25,000 sats**, including routing fees and Ark recovery
costs. The private ledger currently conservatively reserves **10,110 sats**. A
100-sat CLN-to-LND BOLT12 transfer settled. LND has no spendable funds after channel
reserves. The 10,000-sat CLN-to-Ark attempt failed at the sender, with no receiver
settlement; Ark fee accounting remains unresolved. Do not release its reservation
or submit a replacement based on a timeout or missing receive record alone.

No production service is restarted by this checklist. Deployment timing and any
required service interruption must respect the existing no-restart constraint.

## Release sequence

1. Complete the acceptance matrix and record actual evidence, including physical
   device and both server-platform update tests. Choose the public version.
2. Build immutable candidates from the source freeze; validate signatures,
   checksums, wallet preservation and restore procedures. Do not downgrade a wallet
   database that a newer build has migrated.
3. Submit Apple for review with manual release. Stage Google Play testing/review
   and managed publishing where available. A first Play publication needs its own
   supported release path; managed publishing does not cover first publication.
4. Prepare the signed APK release and both wrapper updates with matching notes,
   support information and artifact provenance. Keep candidates unpublished until
   the four platforms are ready.
5. Release the approved versions within the coordinated window. Verify each store
   listing/download, package digest and post-upgrade health. If a platform fails,
   report that clearly instead of declaring full parity or a completed release.

Apple's [manual release controls](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option)
and Google's [managed publishing rules](https://support.google.com/googleplay/android-developer/answer/9859654)
govern the store portion of this sequence.
