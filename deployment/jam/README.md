# Paperclip's bundled Jam runtime

This companion extends Kilombino's JoinBlaket runtime. It is not yet a release
package. Installed host wiring, mobile pairing acceptance, live payment acceptance,
backup/restore and installed-package acceptance remain release blockers.

The base is `ghcr.io/kilombino/jam-xbt:0.43.0-xbt7`, pinned in `Dockerfile` to its
multi-architecture digest. Reviewed upstream source revisions:

- [JoinBlaket](https://github.com/Kilombino/joinblaket) at
  `40a29ae4f34930687f0c6be3e9e5bf14a44cc0f3`.
- [Jam](https://github.com/Kilombino/jam) at
  `3cc28ed04b90513bbdcdb6b8500a8af7e5837ac7`.

`install.py` checks the complete pinned `jmwalletd/app.py` hash before registering
the extension. An upstream change must be reviewed and tested before updating
that hash. The original TLS, Tor and restricted RPC-filter entrypoint stays in use.
The companion must retain private `/data` separately from Paperclip wallet data;
backups must include it, including `paperclip/payments.sqlite`.

The Umbrel generator accepts `--jam-image` with an independently tested immutable
companion image. It creates separate `jam`, `jam-rpc` and `jam-public` volumes.
Only the RPC filter receives the selected node's credentials. Jam shares
Paperclip's network namespace for verified loopback HTTPS; the wallet reads only its exported
public certificate. Neither Jam keys nor the TLS private key are mounted into
Paperclip. All four persistent directories must be backed up together. The
companion refuses a second API process because the upstream maker state is
process-local. Native StartOS 0.4 wrapper wiring is implemented in the test branch;
installed-package lifecycle and full backup/restore acceptance remain open.

## Payment contract

The versioned API prepares a signed transaction without broadcasting. It returns
the exact recipient amount, fee, total debit, selected jar, bond date where
applicable, transaction ID, expiry and approval digest. It never returns signed
bytes or keys. Amounts and fee limits use bounded integers; the fee rate is in
millisatoshis per virtual byte, not Jam's overloaded block-target/fee parameter.

The user reviews those details before a separate commit. Commit checks the active
session, coin ownership, freeze state, chain unspent outputs and bond maturity.
The durable journal records `submitting` before broadcast. Timeout, cancellation,
lost response, restart and repeated commit cannot cause another broadcast.
Status checking resolves an uncertain result only by observing the exact
transaction. Node acceptance is `submitted`, not confirmed settlement.

One unresolved payment blocks new preparations and legacy Jam mutations. Users
can still lock/unlock and inspect their saved payment. Lock revokes the original
session; another wallet cannot access it, even with a colliding BIP32 fingerprint.
Unused reviews can be cancelled. Uncertain submissions cannot be dismissed as
failed to permit a replacement spend.

Bond funding requires this wallet's registered address and matching future date.
Bond withdrawal requires one explicitly selected, chain-matured bond. Ordinary
jar sends cannot consume bond coins.

The native clients and desktop proxy now expose read-only saved-payment history
and exact-transaction status checks. Their recovery views retain unknown outcomes
on failure and never present node acceptance as confirmation. Owner desktop and
independently authorized mobile connections can discard an unsent review after
confirmation. The companion atomically refuses cancellation once submission
starts. A lost reply must be checked, not automatically retried. Existing
management-only phone pairings cannot cancel; they direct the user to the host.
Owner desktop and independently authorized mobile connections can now prepare
and commit fixed-amount direct or CoinJoin sends through this contract. They bind the wallet
identity, recipient, jar, amount, maximum fee, approval and expiry. An interrupted
commit opens recovery rather than a retry. The CoinJoin toggle requires companion
capability version 2. Its pinned taker callback always refuses automatic broadcast;
the exact signed transaction is journaled for separate review/commit. The review
includes maker fees, the owner's mining share, total debit and maker count.
Broadcast uses the owner's Jam node and is non-RBF. No direct-send fallback exists.
Commit rechecks every prevout and the original owner-qualified input leases;
cancelling a signed review can leave coins reserved until the upstream safety
window ends. Live CoinJoin settlement, live bond funding, bond withdrawal client flows and
installed-host pairing acceptance remain release gates.

The host can issue either a management-only phone pairing (the default) or an
explicit manage-and-send pairing. Existing grants remain management-only; choosing
a new permission never upgrades an existing device. Both native apps review the
permission before saving it. Payment grants use the same direct/CoinJoin review,
wallet identity, fee limits and one-shot submission contract as owner connections.
They permit spending from this Jars wallet, without a per-device amount limit.
They cannot unlock or create wallets, export keys, access the main wallet, or use
legacy immediate-send endpoints. The host and companion enforce separate scopes;
editing the QR payload cannot change the host grant. Revocation prevents new
requests, not completion of a request already accepted by Jam. Locking, changing
wallets, restarting Jam or expiry requires a new pairing.

The shared owner UI now creates separate Jam wallets and guides password-verified
recovery-word backup. Creation responses expose only wallet authorization, not
recovery words or refresh tokens. An interrupted creation is checked by filename
before a manually reviewed retry, and the pinned daemon refuses overwrites.
Read-only backup remains available during a pending payment. Restricted phone
grants cannot create/unlock wallets or export recovery words; their delegation
guard runs before the upstream route, including `/getseed`.

## Maker fees and order book comparison

All clients offer fixed-sat or percentage fees from the pinned JoinBlaket grid.
The UI shows percentages, while the API transmits an exact decimal fraction:
0.005% is `0.00005`, or 50 sats for a 1,000,000-sat CoinJoin. Mixed modes and
unsupported values fail before submission. Refreshing market data does not
change the selected fee or start a maker. The comparison amount is separate from
the maker minimum, so an active maker can be compared without reconfiguration.

`GET /api/v1/paperclip/market/{amount}` reads the host-configured order book watcher.
The comparison uses each verified, current bonded maker's lowest supported offer
that covers the amount. Fixed and relative offers are compared in sats, with the
same rounding as the pinned Jam fee calculation. The median excludes mining
contributions and is not the taker's total cost or a prediction of earnings.
It does not publish maker identifiers or wallet information.

Snapshots older than 120 seconds are stale. Missing, disconnected, malformed or
unverified data does not become a zero median. The reader has a ten-second limit,
a two-megabyte response bound and no redirects. Clients validate the amount,
timestamps and result bounds, and age out a displayed snapshot. The management
pairing grants only read access to this route; its spending restrictions remain.

The setup guide explains server availability, separate jar and bond coins, the
lock date, backup and public funding traceability. JoinBlaket's default takers
require a fidelity bond. Registering an address does not fund it. The fee grid and
bond policy follow the pinned upstream implementation and
[Kilombino's JoinBlaket documentation](https://kilombino.com/joinblaket/).
Live watcher, maker and bond acceptance remains required on the packaged host.

## Validation and distribution

The `Bundled Jam integration` workflow builds both native Linux architectures
without publication and runs the journal, real signer and HTTP API tests with
network access disabled. Synthetic chain tests do not establish live settlement.

For a native development run, install the pinned upstream requirements with
`--require-hashes`, install its source packages without resolving new dependencies,
apply `install.py` to that disposable environment, then run:

```
PYTHONPATH=deployment/jam python -m unittest discover -s deployment/jam -p 'test_*.py'
```

The JoinBlaket daemon is GPL-3.0-only and Jam's UI has its own license. Before
distribution, package the license notices and complete corresponding source for
the pinned runtime and modifications alongside the image. This remains a release
gate; the main wallet's MIT license alone does not cover this companion image.

## Funding a registered bond

Paperclip can fund a newly registered bond from its selected jar through the
reviewed payment API. The client binds `fund_bond`, address, UTC locktime, jar,
fixed amount and fee cap. It negotiates `bond_funding` before preparation and
never substitutes an ordinary send or CoinJoin. The companion's existing address
ownership, registry, future-date and one-shot broadcast checks remain authoritative.
The funding UI does not start the maker or claim confirmation.

## Withdrawing a matured bond

In Jars → Fidelity bond, **Check existing bonds** reads the selected Jam wallet's
bond outpoints, values, unlock dates, confirmation/freeze state, signing support
and node median-time-past. This read is available to management-only pairings;
preparing or committing a withdrawal requires payment permission.

Choose **Review withdrawal**, enter an XBT destination and fee limit, then review
the net recipient amount and exact mining fee. One selected bond is withdrawn in
full, less that fee. The request binds `withdraw_bond`, jar 0, the exact outpoint,
input value and unlock date; it cannot substitute another coin or use CoinJoin.
Stop the maker before sending. Maturity uses chain time, never the device clock.
The companion rechecks maturity, confirmation, freeze state, ownership and the
node's unspent output before its one permitted broadcast. Unknown submission
outcomes must be checked in Jars payment activity, never automatically retried.

The same client contract is implemented in iOS, Android and the shared desktop
interface used by StartOS/Umbrel and standalone packaging. Automated tests use
synthetic chain data and the real pinned signer; installed-host/live acceptance
remains separate. This spends from the server's Jam wallet. It does not enable
Krux/SeedSigner CLTV signing or import a QR signer's seed into Jam.
