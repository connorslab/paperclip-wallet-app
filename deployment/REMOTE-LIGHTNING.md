# Remote CLN and XBT LND

The `web-ui` server candidate provides a direct-node wallet in addition to
Lightning through Ark. Desktop, Umbrel and StartOS use the same adapter and browser
pages. Read-only live acceptance of the candidate adapter has passed against both
StartOS nodes. Funded operations and installation on either server platform have
not yet been accepted.

## Connection and transport

Connect with a REST root, CLN rune or LND hex macaroon, and an optional exact
SHA-256 fingerprint of the DER leaf certificate. Without a pin, the normal system
trust store applies. Explicit pins replace the trust anchor, while TLS handshake
signatures remain verified. Redirects, ambient proxies and automatic HTTP retries
are disabled. An onion address requires Tor. HTTPS is required except for a v3
onion address explicitly routed through Tor. Network and node public identity are
checked before balances or payment operations proceed.

The container source installs and supervises a local Tor client with loopback-only
SOCKS access. Administrators can instead set `BARKD_LIGHTNING_TOR_PROXY` to a
`socks5h://host:port` proxy. The adapter never falls back to a direct connection.
Container build/startup and host packaging remain separate acceptance checks.

Credentials are stored in the private server wallet data directory, scoped by a
domain-bound SHA-256 digest of the full public mailbox identity and network.
The four-byte display fingerprint does not select credentials, reviews or payment
history. Directories use mode 0700 and atomic credential/record files
use mode 0600. Credentials are omitted from browser responses and cleared from the
form after submission or locking. Re-verification can reuse a saved credential only
for the same endpoint and implementation; the saved node identity must still match.
The browser does not persist credentials. Receive-only mode also blocks sends on
the server; it does not create a restricted rune or macaroon on the node.

Older candidates used only the short fingerprint for storage. Those directories
do not prove ownership and are never automatically adopted or hidden behind an
empty history. Until explicitly assigned, node operations, including Bridge
funding and reconciliation, stop with an ownership-verification error. Do not
delete or manually rename the directory to dismiss the error.

On the node page, **Recover an older node connection** opens a read-only review.
It shows the current wallet's full identity and network, the saved node identity,
record count and number of unresolved sends. The owner must confirm both the
original wallet and a complete host backup. This is an authenticated owner's
explicit assignment, not cryptographic proof of the old records' original owner
or automatic verification that a backup exists. If uncertain, cancel and check
the original node and backup first.

A two-minute, single-use review binds the exact connection and payment files to
that wallet. Assignment rechecks those bytes under the node's process lock and
publishes a private owner manifest atomically without replacing an existing one.
The old files remain in place, unchanged. Subsequent access requires the full
identity in the manifest; a colliding fingerprint or different network is refused.
No network request, payment, credential export or outcome change occurs during
assignment. Two separate histories, incomplete records, unexpected files and
linked records block recovery rather than being merged or skipped.

If the reply is lost, use **Check saved connection** to read the binding and
original history. Assignment is never retried automatically. Cancellation or
restart before assignment requires a new review. Interrupted filesystem writes
that leave unexpected files require recovery from the complete host backup;
the app does not guess that these files are safe to delete. Older binaries do
not enforce the new manifest: do not downgrade to an earlier candidate. Complete
installed-host backup/restore, interrupted-write and upgrade/downgrade acceptance
remain release gates before deploying this change to existing funded hosts.

## Payment review and recovery

Signed XBT BOLT11 invoices and BOLT12 offers/invoices are validated locally for
network, identity feature, amount and expiry. Fetched invoices must match the
original offer. A send review binds the exact invoice, hash, node, amount and
maximum routing fee for 60 seconds. Approval is consumed once. The server writes a
durable `unknown` intent before contacting the node. Losing the response, closing
the browser or restarting the server cannot silently replay that payment.

The activity page reconciles the exact hash through the selected node. Missing or
inconclusive results remain unknown. A new send is not a status check. Failed TLS,
authentication and transport operations expose bounded messages rather than raw
upstream bodies. Balances distinguish channel funds, spendable funds and reserves;
missing fields are errors, not zero balances.

BOLT11 requests and reusable BOLT12 offers have local QR/copy controls. The node's
BOLT12 service must be available; unsupported endpoints report that requirement.
The new pages do not establish full payment-request manager, contact, Bridge or
multi-hot-wallet parity.

## Internal browser API

Both routes require the wallet's bearer authentication and a loaded wallet, and
return `Cache-Control: no-store`:

- `GET /api/v1/remote-node/connection`: public saved configuration and payment records.
- `POST /api/v1/remote-node/request`: typed `operation` of `connect`, `refresh`,
  `prepare`, `pay`, `invoice`, `offer` or `status`. Fields and responses are defined
  in `bark-rest/src/api/v1/remote_node/mod.rs`. The browser uses these fixed
  operations rather than an arbitrary RPC proxy.

Like the hardware and JoinBlaket browser APIs, these routes are gated by `web-ui`
and are not in the default public OpenAPI schema. The generated public REST client
has also been refreshed for the exact on-chain/boarding and replacement approvals.

## Verification

Rust tests use a local synthetic TLS node and generated signed invoices. They
exercise both adapters, credential headers, stream framing, certificate rejection
before HTTP credentials, redirects, review tampering, and a dropped payment
response after durable intent creation. Reloading state must not submit again.
Browser tests cover phone, tablet and desktop widths, focused Send/Receive/Activity
pages, exact review, cancellation, lock races, QR generation and unknown status.
The test certificate and private key in `remote_node/fixtures` belong only to the
local synthetic server; they are not wallet or deployed-service keys.

Run `just unit-rest`, `scripts/test-remote-node-browser.cjs`, the deployment Python
unit suite and `just checks`. Live node testing, Tor bootstrap inside the Linux
container, signed mobile releases and StartOS/Umbrel upgrade/restore checks remain
required. No funded payment was made for these tests.

On November 15 (local time), the Rust server adapter and Android Kotlin adapter
each passed authenticated identity verification, three balance reads, deliberate
wrong-certificate rejection and subsequent recovery against the current StartOS
CLN and LND LAN endpoints. This used protected existing credentials and certificate
pins independently verified on StartOS, with no payments or service changes. The
JVM negotiated the server's Ed25519 certificate; its ECDSA and Ed25519 leaf pins
must be independently verified before including both in a connection.

The server live check is ignored by default. With a mode-0600 file using the
existing mobile probe's `cases` schema, explicitly run:

```sh
PAPERCLIP_LIVE_CONFIG=/private/path/connections.json \
  just unit-rest 'live_startos_reads -- --ignored --nocapture'
```

The harness performs only connect/refresh/read operations, stores its temporary
connection under a private test directory, and prints no credentials or remote
response payloads. It requires both CLN and LND cases and does not run onion cases.

On November 16, the current Android adapter and native iOS simulator read probe
repeated the authenticated CLN and LND LAN checks successfully: trusted public
identity and network, three balance reads, rejection of an incorrect certificate
pin, and reconnection afterward. No invoice or payment was created. The separate
iOS live UI test runner initially stalled before executing its checks. A subsequent
native Xcode run passed both real connection screens, including verification,
the connected indicator and balance refresh. The earlier runner failure remains
unexplained; assertions and timeouts were not relaxed. The installed StartOS
`0.10.0:0` package still has the older Ark-only
Lightning page and an unavailable XBT node check, so these adapter results do not
establish package upgrade or live-payment acceptance.

The Rust server adapter passed the same live LAN checks on November 16. A new
native embedded-Tor probe failed after controller authentication and 30% bootstrap,
before contacting LND. Cancellation returned within the probe's 300 ms window,
and the cause of that spontaneous control timeout remains unconfirmed. Subsequent
cached and fresh-cache native simulator runs passed three authenticated LND onion
reads, balance decoding, wrong-pin rejection and reconnection. The first read took
21 seconds with the cache and 107 seconds from fresh Tor state. An explicitly
injected startup failure also recovered in the same process and verified an HTTPS
request through Tor. That controlled retry does not prove the original failure is
fixed. The original simulator cache and private inputs were restored afterward.

Android's `NodeLiveDeviceTest` is an explicit opt-in instrumentation check of the
embedded service and real node transport. On an unfunded QA emulator, provision
`cache/node-live-read.json` through `adb run-as` standard input using the existing
`cases` schema, independently verified pins and expected public identities. Every
case must use HTTPS; onion endpoints must use embedded Tor. Run the test class
with instrumentation argument `liveNodes=true`. It only reads identity/network
and balances, rejects a deliberate wrong pin, and checks recovery. It never opens the wallet engine or
creates an invoice. Reports contain fixed stages and timings; exception messages
and node responses are omitted. Restore any previous fixture or remove the
temporary input immediately afterward. A skipped/default test is not acceptance.

The opt-in Android check passed on the isolated API 36 emulator for LND over
embedded Tor, and for both CLN and LND over LAN. The emulator failed to resolve
`start.local`; replacing the HTTPS hostname with the server IP then failed the
TLS handshake. The passing LAN run used an explicit `resolvedAddress` test fixture
with the Mac-resolved IPv4 address while retaining `start.local` as the HTTPS
authority, the independently verified pins and the expected identities. This
fixture is refused for Tor routes. It verifies the adapter with that DNS input,
not automatic mDNS discovery or physical-device acceptance. No production DNS or
TLS policy changed. The private fixture was removed afterward.

## Browser Bridge node funding

The browser candidate can quote a fixed-amount BTC BOLT11 invoice and fund the
conversion from its saved XBT CLN or LND node. Incoming conversions remain bound
to an exact node receive request. Ark funding is now also implemented in the browser candidate, as described below.
These implementations do not close the live-payment or platform acceptance gates.

Outgoing review shows the BTC recipient amount, XBT funding amount, maximum
routing fee and maximum total. The server binds the review to the original saved
hold invoice, payment hash, node identity, fee cap and Bridge deadline. It checks
the deadline again after the asynchronous node identity check. The direct-node
payment route cannot consume a Bridge review without its server-owned quote terms.

The server retains the Bridge/node binding before starting payment, then reuses
the existing node journal before network submission. A failed or uncertain attempt
cannot be resubmitted. A status check may establish that an interrupted preflight
created no node intent; only that case can return to a fresh explicit review.
Funding success and BTC settlement are separate. Only verified Bridge settlement
proof marks the BTC payment settled, and an outage does not clear saved funding.

Internal authenticated, unlocked-wallet routes, with `Cache-Control: no-store`:

- `POST /api/v1/bridge/prepare-funding`: saved outgoing `hash` and
  `maximum_fee_sat`; returns the conversion and exact single-use node review.
- `POST /api/v1/bridge/fund`: the same hash/fee plus `request_id`; submits once.
- `POST /api/v1/bridge/check`: direction/hash; reconciles the original node journal
  independently from Bridge status, without sending another payment.

These are internal `web-ui` routes, outside the default public OpenAPI schema.
No credential, private Bridge token or settlement preimage is returned to the UI.

### Ark funding and recovery

`POST /api/v1/bridge/prepare-ark-funding` takes a saved outgoing hash and returns
an exact cost review. `POST /api/v1/bridge/fund-ark` requires that hash, request ID
and maximum total. The server binds approval to the wallet, signed funding invoice,
payment hash, total and quote deadline, and checks it at the shared engine's final
submission callback. The reviewed total includes recovery reserves and is enforced
inside the engine. The callback must write the submission receipt before the engine
persists or drives its payment checkpoint.

Bridge Ark funding uses the normal browser submission journal. Status checks never
send or resume a payment. A missing submission ID is closed durably before it can
be reported unsubmitted. Once initiated, an unknown engine state stays unknown,
even if an earlier failed payment may have completed recovery. A matching paid
proof establishes Ark funding, while BTC settlement still needs Bridge proof.
Unresolved results block another submission and remain available in recovery.
Conclusive no-submission or paid checks acknowledge their journal warning without
claiming BTC settlement. The existing failed-payment recovery acceptance gate
remains open; no live conversion was made for this implementation.
