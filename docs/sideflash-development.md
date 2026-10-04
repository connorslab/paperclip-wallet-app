# Experimental Sideflash wallet branch

The `feature/sideflash` branch adds the same address codec and frozen fixtures
as the server branch. Enable the wallet library feature `experimental-sideflash`
to compile its wallet methods. It is not enabled in normal app builds.

New receive preparation uses compact v1. Send and ownership validation accept
both v1 and legacy v0. The complete offer remains embedded; no lookup is needed.
See [the v1 wire profile](sideflash-wire-v1.md).

## Available library methods

- `prepare_sideflash_receive`: authorize a binding for the wallet's active
  reusable offer and its stored native receiving key. Returns a binding and
  recipient signature, not a payable address. The server must register and
  countersign it. It never receives the wallet secret key.
- `validate_sideflash_receive`: verify an acknowledged address against the
  current server, current wallet offer and native destination before display.
- `send_sideflash`: verify the destination and use the existing persisted native
  Ark send path for the same server, with an explicit maximum debit. Remote
  Sideflash sends fail before payment until safe server coordination exists.

The original feature branch has no receive-registration endpoint, app UI or remote
wallet payment flow. The local test additions below add receive acknowledgement
and its UI; remote wallet sends remain disabled. These library methods are integration foundations, not a shipping
Sideflash-enabled wallet. The caller must persist its registration request and
verify the server response against that exact request before display; the
ownership validator alone is not revision or request-response validation.

All amounts and network checks target bitcoin (XBT). No mainnet payments or
production app deployments are part of this branch.

## Validation

Compile with `cargo check --locked -p bark-wallet --features experimental-sideflash`
inside the Nix development environment. Run the shared codec tests with
`just unit sideflash`. Same-server monetary tests, receive registration and
cross-server recovery tests remain required before release.

Current validation: feature-enabled wallet compilation, default workspace checks
and all six shared Sideflash codec tests pass in the isolated Linux environment.
This is not evidence that the wallet methods have completed a monetary test.

## Local Umbrel test build

The local-only `test/sideflash-umbrel-local` branch adds authenticated receive
endpoints and a receive card. Build `bark-cli` with
`barkd-web-ui,experimental-sideflash`. Normal builds do not expose these endpoints.

1. Create a separate wallet against the local test server. Do not copy a live wallet.
2. Create its reusable offer and keep the daemon online.
3. `GET /api/v1/sideflash/info` returns the recipient key and server key.
4. Add the recipient key to the test server's `sideflash_recipient_allowlist`.
5. `POST /api/v1/sideflash/receive` requests and validates a compact binding.
   The wallet checks the complete destination and offer, both signatures, server
   identity, revision and validity against its request before display.
6. Share the address with the payer. Give the payer the trusted server key through
   a separate authenticated channel. FLYNN uses `sideflash-pay` with an amount,
   maximum fee and persistent payment ID.

This test uses revision 1 and a maximum 24-hour validity. The wallet saves a
successful address with the existing offer checkpoint and reuses it until expiry.
An acknowledgement is not a payment; a lost acknowledgement reply can be retried.
Disabling the underlying offer stops new invoice requests. It does not revoke an
already issued invoice. No address-revision registry or offline receive promise
is implemented. These remain test limitations.

Lightning receives use the existing wallet-owned preimage, durable invoice and
conditional claim flow. A payer's settled invoice alone is not evidence that the
wallet has claimed its Ark output. Check both sides during the funded test.

## Local verification (2026-10-04)

The isolated Umbrel build creates the Sideflash card under **Send & receive**.
The ASP and wallet use separate data and database state. The integration test
verified disabled-by-default registration, recipient allowlisting, a signed
820-character compact address, repeat retrieval of the saved address, and an
unauthenticated API rejection. FLYNN verified the binding and fetched a valid
10,000-sat BOLT12 invoice; no payment was sent in this preparation step.

A private test channel requires an explicit Askrene layer on the sender. Pass
`layers=["sideflash-local-test"]` to the test CLN plugin when using that topology.
This does not publish the private channel or change its gossip announcement.
Funded settlement, the recipient's Ark claim, and recovery remain to be verified.

### Funded delivery verification (2026-10-04)

FLYNN paid 10,000 sats through `sideflash-pay` to the separate Umbrel wallet's
compact Sideflash address. The local ASP delivered 5,880 spendable Ark sats:
120 sats were the receive service fee and 4,000 sats the recovery allocation.
The Lightning routing fee was 1.1 sats. Both payer and recipient recorded settlement.
Repeating the identical payment ID returned the same result without another
payment; restarting the wallet preserved its settled receive and spendable balance.

The private route overlay must use the forwarding peer's alias (the receiving
node's `alias.remote`), rather than the channel's real short-channel ID when
`option_scid_alias` is negotiated. The first attempt with the real ID failed
without sending funds. This test verifies delivery and persistence; it does not
constitute a new unilateral recovery test or authorize a production release.
