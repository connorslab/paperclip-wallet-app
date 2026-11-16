# Paperclip's bundled Jam runtime

This companion extends Kilombino's JoinBlaket runtime. It is not yet a release
package. Installed host wiring, mobile pairing acceptance, client payment flows, CoinJoin payments,
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
on failure and never present node acceptance as confirmation. They cannot prepare,
commit or cancel a payment. Direct/CoinJoin review, bond funding/withdrawal and
payment-capable mobile pairing remain unfinished; these API foundations and recovery views
do not constitute a completed bond or payment UI.

The shared owner UI now creates separate Jam wallets and guides password-verified
recovery-word backup. Creation responses expose only wallet authorization, not
recovery words or refresh tokens. An interrupted creation is checked by filename
before a manually reviewed retry, and the pinned daemon refuses overwrites.
Read-only backup remains available during a pending payment. Restricted phone
grants cannot create/unlock wallets or export recovery words; their delegation
guard runs before the upstream route, including `/getseed`.

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
