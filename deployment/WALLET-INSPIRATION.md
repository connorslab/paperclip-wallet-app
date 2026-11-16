# Wallet feature inspiration

Reviewed on 2026-11-15. These are product priorities, not a claim that Paperclip
implements each feature. Candidate source serves iOS, Android and the shared
browser UI used by the desktop, Umbrel and StartOS packages. Package release
validation remains separate.

## Implemented in this pass

Jam's maker workflow informs a common setup checklist: valid offer terms,
confirmed coins in one jar, detected bond coins, an idle server and fresh status.
The checklist explains why Review maker setup is unavailable. It does not start
a maker automatically. The existing review dialog remains required.

Kilombino's [JoinBlaket service](https://kilombino.com/joinblaket/) requires bonded
makers. Generic JoinMarket guidance must not weaken this fork requirement.
Detected bond coins do not prove that a bond is active or accepted. The daemon
performs the final eligibility checks. The UI states that earnings are not
guaranteed and that bond coins stay locked until the selected date.

The same policy runs on all three UI surfaces. A failed status refresh invalidates
previous readiness. A successful refresh is required before another maker action.
The shared fixture covers 17 cases, including locked or pending coins, separate
jars, invalid amounts, busy servers and stale authorization. No live maker was
started for this work.

## Priorities for the coordinated release

| Inspiration | Useful Paperclip adaptation | Acceptance criteria and remaining work |
| --- | --- | --- |
| [Bark: unified payments](https://second.tech/blog/bark-wallet-now-on-umbrel/) | One paste or scan entry for on-chain, Ark, Lightning invoices and offers. Explain the available route before payment. | Validate XBT network and format first. Show the selected wallet, recipient and bounded cost. Never choose a bridge or a different asset silently. Existing parsers and send paths are a base; unified routing remains open. |
| [Sparrow: transaction review and coin control](https://www.sparrowwallet.com/features/) | Show recipient amount, fee, total debit and selected coins together. Keep technical details expandable. | Exact hot-wallet on-chain and board review needs a server contract that binds approval to execution. Do not display an estimate as a guaranteed final fee. Preserve Krux signature verification and wallet isolation. This is the highest payment-review priority. |
| [Zeus: wallet connections](https://docs.zeusln.app/for-users/using-zeus/wallets/) | Named node profiles with clear active-wallet and connection state. Switch profiles without recreating setup. | Keep credentials and pending work scoped to each profile. Distinguish offline, Tor startup, authentication and stale data. Existing hot/QR wallet selection does not by itself provide complete node-profile parity. |
| [Zeus: activity tools](https://docs.zeusln.app/for-users/using-zeus/menu/) | Searchable payment details, user labels and account-scoped CSV export. | Export amounts, fees and observed states without secrets. Unknown settlement stays unknown. Partial ledger failure must remain visible. The improved shared Activity screen is the base; export and full search parity remain open. |
| [Jam: Earn](https://jamdocs.org/interface/03-earn/) and [fidelity bonds](https://jamdocs.org/interface/fidelity-bonds/) | A clear progression from jars to maker readiness, offer review and server operation. | The readiness checklist is implemented. Bond creation and collaborative sends still use Jam. A future in-app flow must disclose lock date, cost and server eligibility before authorization. Do not promise earnings or automatic privacy gains. |
| [Bark: unified mailbox](https://second.tech/blog/unified-mailbox/) | A durable activity inbox for received payments and operations that need attention. | Reconcile after reconnect or process death. Deduplicate events and distinguish accepted, pending, settled and recoverable outcomes. An event alone is not settlement proof. Durable uncertain-operation recovery remains a release gap. |

## Design principles

Keep simple actions prominent and advanced details available on demand. Use the
same state names on every platform. Treat desktop and foldable layouts as room
for useful details, not duplicated controls. Celebrate only verified completion.
Keep balance, spendable amount and receive capacity distinct.

Adapt the workflows rather than copy branding. Bark, Zeus, Jam and Sparrow target
different networks and server contracts. Their fees, supported formats and
security assumptions do not automatically apply to XBT or Paperclip Bridge.
