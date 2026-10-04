# Sideflash validation

## Compact v1 migration — 2026-10-04

New authorizations and acknowledgments use v1. Legacy v0 decode, verification
and re-encoding remain supported. The Rust codec verifies the exact Python v1
fixtures. The examples measure 785 mainnet and 841 regtest characters.

- `just unit sideflash`: six passed in each repository.
- `just checks`: passed in each repository; existing warnings remain.
- Wallet `cargo check --locked -p bark-wallet --features experimental-sideflash`: passed.
- Shared codec and v1 fixture files match across the branches.

Tests cover both wire versions, complete offer extraction, native route selection,
wrong network and identity, malformed input, and copied legacy signatures. An
initial wallet test synchronization omitted the new fixture; after the fixture
was copied, the complete checks above passed. No production service changed.
Payment delivery and recovery are outside this codec migration.
