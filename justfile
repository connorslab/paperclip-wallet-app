set shell := ["bash", "-euo", "pipefail", "-c"]

checks:
	cargo check --locked --workspace --tests --examples

unit filter="":
	cargo test --locked -p ark-lib -p bark-bitcoin-ext --lib {{filter}}

unit-wallet filter="":
	cargo test --locked -p bark-wallet --features onchain-bdk --lib {{filter}}

unit-mobile filter="":
	cargo test --locked -p paperclip-mobile --lib {{filter}}

unit-rest filter="":
	cargo test --locked -p bark-rest --features web-ui --lib {{filter}}

unit-support filter="":
	cargo test --locked -p bark-common -p bark-json -p bark-runtime -p bip321 -p bark-nwc --lib {{filter}}

unit-creation:
	cargo test --locked -p bark-cli --lib seed::tests

unit-electrum:
	cargo test --locked -p electrum-client --lib xbt_header_tests

unit-unified:
	cargo test --locked -p bark-bitcoin-ext --lib unified_

unit-rpc-cookie:
	cargo test --locked -p bark-bitcoin-ext --lib cookie_tests
	cargo test --locked -p bark-bitcoin-ext --features rpc-socks5-proxy --lib cookie_tests
	cargo test --locked -p bark-wallet --features socks5-proxy --lib rpc_cookie_rotation

unit-rpc-transport:
	cargo test --locked -p bark-bitcoin-ext --features rpc-socks5-proxy --lib rpc::socks5_transport::tests

generate-bark-rest-client:
	bash scripts/generate-rest-client.sh
