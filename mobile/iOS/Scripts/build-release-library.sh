#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
# C dependencies must use the same minimum iOS version as the Swift app.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export CARGO_INCREMENTAL=0
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-3}"
cargo +1.90.0 build --locked --release -p paperclip-mobile --target aarch64-apple-ios
