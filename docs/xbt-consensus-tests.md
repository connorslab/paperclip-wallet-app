# XBT script consensus tests

The upstream Bitcoin kernel does not accept XBT unified signatures. Use the
explicit Knots oracle for the `ark-lib` script tests:

```sh
PAPERCLIP_XBT_CONSENSUS_LIBRARY=/absolute/path/to/libbitcoinconsensus.dylib just unit-xbt
```

The library must implement consensus API 2 and the unified-sighash flag. Use a
trusted, checksum-verified Knots release. The harness loads native code from the
specified path. It does not download a library or fall back to another verifier.
The feature and loader are test-only; applications do not load this library.

Reference: [Knots 29.4.3 release](https://bitcoinknots.org/files/29.x/29.4.3.knots20260508/)
and its [C API header](https://github.com/bitcoinknots/bitcoin/blob/v29.4.3.knots20260508/src/script/bitcoinconsensus.h).
The Apple Silicon archive `bitcoin-29.4.3.knots20260508-arm64-apple-darwin.tar.gz`
has published SHA256
`5c1a8a4df75acde2f15accc4358c678c3597b0244206ba472774e10cf9e86115`.
On Apple Silicon, the unsigned consensus dylib requires an ad-hoc signature for
local test use. Sign a separate extracted copy with `codesign --sign -`; retain
the original archive and checksum. This is not a distribution signature.

The harness supplies every prevout, enables all published verification flags,
and requires both a successful result and a zero API error. A positive unified
signature test also requires rejection of changed outputs, prevout amounts,
signature bytes and sighash type. A missing library, missing API or incompatible
verifier fails the test run.

These tests check scripts. They do not establish chain maturity, UTXO existence,
transaction value conservation, mempool policy, live settlement or installed
wallet recovery. Those release checks remain separate. `just unit` retains the
upstream Bitcoin kernel and must not be reported as XBT consensus acceptance.
