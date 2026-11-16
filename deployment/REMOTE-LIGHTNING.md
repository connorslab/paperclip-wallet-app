# Remote CLN and XBT LND

The `web-ui` server candidate provides a direct-node wallet in addition to
Lightning through Ark. Desktop, Umbrel and StartOS use the same adapter and browser
pages. This source implementation has not yet been accepted against the live
StartOS nodes or packaged and installed on either server platform.

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

Credentials are stored in the private server wallet data directory, scoped by the
wallet fingerprint. Directories use mode 0700 and atomic credential/record files
use mode 0600. Credentials are omitted from browser responses and cleared from the
form after submission or locking. Re-verification can reuse a saved credential only
for the same endpoint and implementation; the saved node identity must still match.
The browser does not persist credentials. Receive-only mode also blocks sends on
the server; it does not create a restricted rune or macaroon on the node.

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
