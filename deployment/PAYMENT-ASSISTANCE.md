# Reviewed transfers and payment assistance

Candidate source work, 2026-11-15. This does not change a published binary or
establish live StartOS/Umbrel, iPhone, or funded Lightning acceptance.

## Guided transfers

The recipient step offers **Move to my other wallet**. Mobile can select another
saved hot, hardware, or watch-only wallet on the same network. The browser can
transfer between its hot wallet and saved QR accounts. The source remains selected;
a temporary destination session derives and persists a fresh receiving address.
Missing databases, wrong keys, wrong networks and the same wallet are rejected.
Manual recipient edits invalidate the selected-wallet description. Delayed address
lookups cannot overwrite a newer edit or wallet session.

The ordinary payment review and signing path still applies. Hardware receiving
addresses should be compared on the signer. On-chain fees apply. Mobile Ark sends
can use the resulting on-chain address through the existing offboard review.
This is not an automatic bridge, asset conversion or fee-free internal transfer.

Browser hot-wallet sends now prepare an exact PSBT and return its request ID,
recipient amount, network fee and total debit. Commit consumes that review once,
checks its 60-second lifetime and source wallet, refreshes the inputs, and signs
only the same transaction. An older server without this contract fails closed.
The compatibility `/onchain/send` API still exists; the browser no longer uses it.

The server boarding flow also prepares and retains its exact funding transaction.
Review separates net Ark funds, recovery reserve (including the boarding fee),
network fee and total debit. Commit consumes a 60-second approval, checks the
wallet and unchanged recovery costs, synchronizes inputs, and signs the reviewed
PSBT. The existing board action persists recovery state before broadcast. A
pending result requires confirmations, and an uncertain response is never retried
automatically. Browser regressions reject incomplete or changed quotes, changed
amounts and stale sessions at phone, foldable and desktop widths. Live funded
boarding acceptance remains required.

## Durable server submission recovery

The browser uses authenticated `GET /api/v1/submissions`, `POST /api/v1/submissions`,
`POST /api/v1/submissions/check`, and `POST /api/v1/submissions/ack` when the wallet advertises
`submission_journal: 1`. Financial actions fail closed against an older server.
A random 256-bit submission ID binds the operation and complete reviewed body.
Repeating an ID never repeats the operation, including after the original response
was lost. A result remains discoverable and blocks a new submission until the
client acknowledges delivery, so another tab recovers a lost success reply too.
Acknowledging a result never changes its settlement state. Changed payloads are rejected. Checking an unseen ID closes it, so a
late request cannot send after the UI reported that it was not submitted.

Receipts are scoped to the hash of the wallet's network and full public mailbox identity.
Files are atomically replaced and synced with mode 0600, in mode 0700 directories;
a process lock and request mutex serialize dispatch. Request bodies, credentials,
seeds and private keys are not stored in these receipts. Include the complete
`submissions` directory in server volume backups. Wallet deletion refuses an
unresolved receipt. Corrupt or unrecognized receipts fail closed.

Ark, Lightning, offboarding, refresh, reviewed on-chain sends, replacements,
boarding and exit claims record an exact engine reference before committing funds.
Pre-submission rejection allows a newly reviewed request; an interrupted operation
that crossed the submission boundary remains uncertain until its own action,
movement, transaction or payment hash is found. Exit-start records its eligible
VTXO IDs. Exit-progress recovery observes the existing recovery state machines;
it does not assert that a particular CPFP transaction settled.

The read-only status check never broadcasts, pays, retries a send or matches by
amount and timestamp. `received` means an operation returned a result, and
`recorded` means its engine record was found. Neither means final settlement.
Ark success feedback uses the movement status, rather than an HTTP success code.
A new tab loads unresolved receipts before it permits another financial action.
A rejected request can be reviewed again; a pending payment must not be resent.

Submission work has a 180-second deadline. A concurrent submission or check gets
a busy response instead of waiting behind another payment. A crash between the
receipt marker and engine persistence can remain uncertain; the UI does not infer
failure from a missing engine record. Receipt archival after 10,000 entries is
not automated, and full-volume restore and process-kill tests on the packaged
Linux service remain required before release.

Local regression coverage includes cancellation on either side of submission,
lost replies, changed bodies, delayed requests after a status check, private file
permissions, symlink rejection, authentication, reopening in another tab, pending
versus successful feedback, older-server refusal, and wallet/session races.
Shared-engine tests check that receipt-storage failure does not drive an existing
Lightning payment or persist an RBF replacement. No live payment was made for
these tests.

## RBF security review

The review considered the October 2026
[Electrum fee-bumping advisory](https://github.com/spesmilo/electrum/security/advisories/GHSA-6jp4-8v48-cc5v).
A malicious server can inject an invalid conflicting transaction into history and
try to turn a user's fee increase into authorization for changed recipients.
Paperclip must never derive spending authority from network history alone.

The implemented policy is deliberately narrow:

- Only ordinary sends recorded by the reviewed send path are eligible. An immutable,
  account-scoped SQLite journal stores the signed original before BDK persistence
  or broadcast. Older, received, Ark-protocol, CoinJoin, QR-signed and other
  unrecorded transactions do not gain authority by appearing in Activity.
- The current unconfirmed transaction must exactly equal that local record. All
  inputs must belong to the wallet and be supported native SegWit or Taproot
  outputs. Original signatures are verified against full parent transactions
  using the XBT unified signature rules before preparing or committing.
- Replacement keeps every original input, sequence, locktime, recipient script and
  recipient amount. It takes the additional fee only from the original change
  output, preserves that output, and cannot add inputs. No-change sends cannot
  be bumped through this feature. Known descendants and confirmed payments fail.
- A fresh, single-use review binds transaction ID and fee. Additional debit must
  equal the fee increase, both in the engine and each UI. The total fee cannot
  exceed 1,000,000 sats or the original recipient amount. The optional default is
  twice the original fee, explicitly not a confirmation-time estimate.
- Unique `(account, replaces)` prevents a second child of one original payment,
  including after a crash. Missing signed graph records are recovered from the
  journal on open. Existing evicted graph records are not revived. A saved local
  replacement is not evidence of network acceptance or final settlement.
- Commit broadcasts once. `submitted` means the backend accepted the request;
  `pending_broadcast` means its result was not confirmed. Neither is a confirmed
  payment. The UI directs users to status checks and never automatically resends
  a timed-out mutation.

Unit regressions exercise valid Taproot and SegWit replacements, recipient/input/
fee tampering, forged unsigned history, protocol/no-change exclusions, confirmation
and descendant rejection, expired/changed approval, namespace isolation,
single-child persistence, and the journal-before-BDK crash window. REST tests
exercise authentication and rejection of unprepared commits. Browser regressions
exercise exact reviews, cancellation, malformed responses, lock races and uncertain
submission. Native review validators have equivalent malformed-response tests.

No live RBF was broadcast. Mempool acceptance, relay fee policy, backend reorg and
eviction behavior, long replacement chains, and process interruption during real
network broadcast still require controlled-node testing before release. Hardware
RBF and CPFP are not implemented. Non-SQLite persistence adapters do not implement
this authorization journal and cannot use this feature.

## Health, backups and support

Wallet health uses the existing visual components and Settings navigation. It
separates a recently verified connection from cached balance data, links to
recovery, and offers a preview before sharing or downloading a support report.
Reports use an explicit field allowlist. They exclude wallet names and IDs,
addresses, amounts, payment references, server URLs, raw errors and credentials.
Lock or account changes clear browser report state. No report is sent automatically.

Mobile backup centers record a successful file save against its originating wallet
and offer a check of a saved encrypted archive. The check authenticates/decrypts
the archive, verifies any stored seed words against its seed, and runs the real
restore validator in a private temporary directory. It checks SQLite integrity,
engine migration, key and network ownership, and on-chain wallet loading. Temporary
files are removed on success and failure; existing wallets and selection remain
unchanged. Only a matching wallet receives a local check timestamp.

The shared mobile restore path also cleans its private staging directory after a
rejected archive. A damaged database, wrong key or wrong network does not block a
corrected retry at the same destination. Staging data left by an older interrupted
attempt is preserved separately and is never reused. Existing wallet destinations
remain protected from replacement.

Backup export likewise uses a private temporary snapshot for each attempt. An
older interrupted snapshot is preserved without blocking a fresh export. Normal
completion and errors clean the current attempt's temporary files.

A local save timestamp is not proof of cloud upload. A restore check is not a live
fund-recovery test and does not establish that an older archive contains recent
Ark activity. Server editions retain host-managed complete-volume backups; the
browser states that host backup/restore completion cannot be verified there.

## Remaining product work

The broader accepted roadmap remains open: a complete payment-request manager,
portable labels/contacts, and receive-only connections enforced by restricted
credentials. Existing monitoring wallets and hidden send controls must not be
presented as a restricted-credential receive-only mode. This candidate does not
claim to complete those features or the larger coordinated release matrix.
