# Paperclip Wallet 0.10.0

This update integrates upstream Bark 0.8.1, commit
`303682063ed7559b06dcf37c5cb37bb7037b943f`. Paperclip version numbers are separate
from upstream Bark versions.

## Changes

- Lightning sends can finish from a saved payment preimage instead of remaining
  pending after payment succeeded.
- Expired WebSocket authentication tickets are rejected.
- Payment-URI parsing handles multibyte input safely. BOLT12 offers with fiat
  amounts no longer cause a parser panic.
- Lightning receive invoices support an optional expiry within the server's limit.
- On-chain signing uses explicitly owned signers with BDK 3.2.0, including after
  reopening a wallet. XBT transaction signatures retain their network protection.
- The REST API and generated client include the updated payment and recovery
  interfaces. Payment limits still include fees and recovery reserves.

The packaged browser interface retains the Paperclip ASP default for new wallets,
platform-specific sign-in, payment review, and explicit transaction results.
Saved connection settings and custom ASP addresses are preserved.

## Updating

Back up the **complete wallet** before updating. A seed alone does not contain
every piece of Ark recovery data. Upgrade the ASP first, then update the wallet
in place through its platform. Do not create a new wallet to replace an existing
installation, and do not delete its data volume.

Local state can be migrated by the new wallet. Do not downgrade while payments,
rounds, reimbursements, or exits are pending. Keep the pre-upgrade backup, but do
not restore stale state over a wallet that has since accepted new transactions.

## Fees and recovery

This update does not enable P2A or reduce the XBT funded-exit reserves. Existing
signed recovery histories remain valid. Ordinary sends continue to negotiate
the economical profile supported by the ASP; Lightning routing fees and recovery
allocations still apply. Review the quoted total before paying.

Older wallets can continue using the upgraded ASP. Compatibility testing includes
the released 0.9.3 wallet, Ark transfers, BOLT11 and BOLT12 sends and receives,
and a confirmed unilateral exit with the ASP offline. This is functional testing,
not an independent security audit.

## Test harness limitations

Use `just unit-xbt` with the explicitly selected, checksum-verified Knots library
for XBT script acceptance. The native run passes 173 protocol tests and 38 support
tests, including the slow dust-placement case when `--include-ignored` is set.
Historical Bitcoin fixtures remain encoding/rejection tests, rather than valid
XBT authorizations. The upstream `just unit` Bitcoin kernel is not an XBT oracle.
See [XBT script consensus tests](xbt-consensus-tests.md) for setup and limitations.
Full-node transaction policy, live settlement and installed recovery still need
their separate acceptance evidence.
