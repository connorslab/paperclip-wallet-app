# Reusable BOLT12 bridging

The public Paperclip Bridge deployed on November 18, 2026 supports reusable,
amountless BOLT12 receiving offers in both directions. This is separate from the
existing fixed-amount BOLT11 quote API. Do not send an offer to `/quote` or treat
registration as payment settlement.

## Service contract

Verified against the deployed public frontend and read-only server source:

- `GET https://lightning.paperclip-xbt.xyz/bridge/api/reusable/info` returns
  `{ "available": true | false }`.
- `POST .../reusable/register` accepts a cryptographically random, nonzero
  32-byte lowercase hexadecimal `token`, `destination_offer` (at most 16,384
  characters), and Boolean `destination_xbt`.
- `POST .../reusable/lookup` and `POST .../reusable/revoke` accept only `token`.
- Responses contain `offer`, `direction` (`toBLAKE2b` or `toSHA256`, identifying
  the **receiving** network), and Boolean `revoked`.
- The issued offer belongs to the opposite, paying network. The recipient's
  offer is immutable for a management token. Reuse the same token and recipient
  when explicitly retrying registration; never generate a replacement after an
  uncertain outcome.
- A management key can inspect/revoke the binding. It cannot spend funds or
  replace the receiving offer. Revocation prevents new payments; existing
  payments can still settle or refund.

Sources: [public bridge](https://lightning.paperclip-xbt.xyz/bridge/),
[deployed frontend](https://lightning.paperclip-xbt.xyz/bridge/reusable.js),
[availability](https://lightning.paperclip-xbt.xyz/bridge/api/reusable/info).
The deployed gateway's `web/reusable.js` was inspected read-only. Kilombino's
public repository does not yet document this deployed extension.

## App behavior

- iOS and Android have matching create → review → share/manage flows. They use
  existing wallet cards, status badges, payment controls and QR rendering.
- StartOS, Umbrel and the Linux/macOS/Windows desktop shells share the same web
  UI and authenticated REST integration. The REST routes are `/bridge/reusable`
  (list and explicit actions) and `/bridge/reusable/info`.
- Users can supply an amountless BTC or XBT offer or generate one using their
  connected mainnet CLN/XBT LND node. Ark receiving offers remain unsupported.
- A BTC offer entered in the outgoing bridge form opens the reusable flow.
  An XBT bridge offer can be handed to the existing node or Ark send screen.
  The sender enters an XBT amount and explicitly reviews the resolved invoice,
  routing/Ark fees and debit limit there. Navigation never authorizes funding.
- Rates, fees and limits apply to each payment. An offer is not a fixed-rate quote
  or a receipt. Confirm receipt through the receiving wallet/node.
- Management keys and immutable registration inputs are saved **before** the
  network call, in iOS Keychain, Android encrypted storage or per-wallet private
  server files. Server files use atomic writes and directory sync. Normal REST
  responses do not include management keys. Explicit recovery-key display/copy
  is separate from the offer QR. No key is placed in a URL or browser storage.
- A pending revocation is persisted before the request. Its offer stays hidden
  even if a later lookup reports it active; users can explicitly retry revocation.
- Keep management keys separately for app/host recovery. Do not claim the older
  seed/native-database backup includes this new journal.

## Validation and release evidence

Shared fixtures exercise currency identity, fixed amounts, quantity, expiry,
case, malformed encodings and size limits. Rust additionally uses the full BOLT12
parser. Swift/Kotlin perform bounded structural/network checks; the bridge
validates registration and the existing funding engines validate payment offers
and resolved invoices before explicit authorization.

Run `just unit-rest bridge`, Swift `Bridge` tests, Android `ReusableOfferTest` and
`ReusableBridgeLayoutTest`, and `scripts/test-bridge-reusable-browser.cjs`.
Browser tests cover cancellation, interrupted registration, lookup recovery,
uncertain revocation, private-key clearing, payment-screen handoff and responsive
host layouts without issuing any payment. Keep live settlement and final signed
package acceptance separate from these tests. No live swap was sent for this
integration; no production service was restarted or changed.
