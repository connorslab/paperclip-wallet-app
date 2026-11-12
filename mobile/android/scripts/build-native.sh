#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
android="$root/mobile/android"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to NDK 28.0.13004108}"
host=linux-x86_64
[[ $(uname -s) != Darwin ]] || host=darwin-x86_64
toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin"
export PATH="$toolchain:$PATH"
export RUSTC=$(rustup which --toolchain 1.91.0 rustc)
export RUSTDOC=$(rustup which --toolchain 1.91.0 rustdoc)
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-2}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$root/target/android"}
profile=${PAPERCLIP_RUST_PROFILE:-release}
case "$profile" in release) output=release ;; dev) output=debug ;; *) echo "Unsupported build profile" >&2; exit 1 ;; esac
cd "$root"
for abi in "${@:-arm64-v8a}"; do
    case "$abi" in
        arm64-v8a) target=aarch64-linux-android; cc=aarch64-linux-android28-clang ;;
        x86_64) target=x86_64-linux-android; cc=x86_64-linux-android28-clang ;;
        *) echo "Unsupported ABI: $abi" >&2; exit 1 ;;
    esac
    rustup target add --toolchain 1.91.0 "$target"
    variable=${target//-/_}
    export "CC_$variable=$cc" "AR_$variable=llvm-ar"
    target_env=$(printf '%s' "$variable" | tr '[:lower:]' '[:upper:]')
    export "CARGO_TARGET_${target_env}_LINKER=$cc"
    rustup run 1.91.0 cargo build --locked --profile "$profile" -p paperclip-mobile --lib --target "$target"
    mkdir -p "$android/native/$abi"
    cp "$CARGO_TARGET_DIR/$target/$output/libpaperclip_mobile.a" "$android/native/$abi/"
done
