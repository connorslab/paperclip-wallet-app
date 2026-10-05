set shell := ["bash", "-euo", "pipefail", "-c"]

checks:
	cargo check --locked --workspace --tests --examples

unit filter="":
	cargo test --locked -p ark-lib -p bark-bitcoin-ext --lib {{filter}}

unit-wallet filter="":
	cargo test --locked -p bark-wallet --features onchain-bdk --lib {{filter}}

covenant-unit:
	cargo test --locked -p bark-bitcoin-ext --no-default-features --features experimental-covenants --lib covenant

covenant-int:
	cargo build --locked -p bark-bitcoin-ext --no-default-features --features experimental-covenants --examples
	bash experiments/covenants/test.sh
