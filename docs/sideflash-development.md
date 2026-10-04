# Experimental Sideflash wallet branch

The `feature/sideflash` branch adds the same address codec and frozen fixtures
as the server branch. Enable the wallet library feature `experimental-sideflash`
to compile its wallet methods. It is not enabled in normal app builds.

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

There is no completed receive-registration endpoint, app UI or remote payment
flow yet. These library methods are integration foundations, not a shipping
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
and all five shared Sideflash codec tests pass in the isolated Linux environment.
This is not evidence that the wallet methods have completed a monetary test.
