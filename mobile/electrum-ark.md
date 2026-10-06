# Electrum backend requirements for Ark

The app defaults to `ssl://pool.paperclippool.xyz:50002`. Keep the backing Knots
RPC private. The wallet needs only the following public Electrum methods, over
TLS or its configured Tor SOCKS transport.

- Standard script history, transaction, merkle proof, header, fee estimate, and
  transaction broadcast methods used for on-chain synchronization.
- `blockchain.transaction.get_height` for absent/mempool/confirmed status.
- `mempool.get_info`, including the backing node's current `minrelaytxfee`,
  `mempoolminfee`, and `dustrelayfee` values in XBT per 1,000 virtual bytes.
- `blockchain.transaction.broadcast_package(raw_txs, false)` with the standard
  `success` and per-transaction `errors` response.
- `server.features` with `broadcast_package: true` only when package submission
  is actually enabled and supported by the backing XBT node.

The client negotiates protocols 1.4 through 1.6. Servers lacking Ark capabilities
remain usable for ordinary on-chain operations. New funded Ark operations are
blocked if capability or policy information is missing; recovery does not require
the current fee-policy admission check.

The tested funded profile requires minimum relay and dynamic mempool minimum fees
no higher than 1 sat/vB, and a dust relay rate no higher than 3 sats/vB. Do not
hard-code these values into Electrum metadata: forward the current node policy so
the wallet stops admitting new positions when conditions change.

Fulcrum protocol 1.6 defines the mempool and package methods. Some servers or
proxies filter metadata. Ensure `dustrelayfee` survives the mempool response and
`broadcast_package` survives the features response. This is a narrow metadata
extension when the server does not already forward the Knots dust field. Do not
enable `daemon.passthrough` or expose node administration methods.

On October 6, 2026, the Kilombino endpoint negotiated protocol 1.6 and returned
`mempool.get_info`, but its response omitted `dustrelayfee` and its features did
not advertise package relay. The app consequently refuses funded Ark admission
there. This read-only probe did not broadcast a package or transfer funds. The
Pool endpoint still needs deployment and funded recovery testing.

Run the read-only diagnostic with `cargo run -p paperclip-mobile --example
electrum_probe -- ssl://host:50002`. For a self-signed server, append its
operator-verified SHA256 certificate fingerprint. The diagnostic reports the
network tip, public capability metadata, and admission result without a wallet.

Protocol reference:
https://electrum-cash-protocol.readthedocs.io/en/latest/protocol-methods.html
