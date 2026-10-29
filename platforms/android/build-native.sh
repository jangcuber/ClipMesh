#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${SDK:+$SDK/ndk/27.3.13750724}}}"
if [[ -z "$NDK" || ! -d "$NDK/toolchains/llvm/prebuilt" ]]; then
  echo 'Set ANDROID_NDK_HOME to Android NDK r27d, or install ndk;27.3.13750724 under ANDROID_HOME.' >&2
  exit 1
fi
case "$(uname -s)" in
  Darwin) HOST=darwin-x86_64 ;;
  Linux) HOST=linux-x86_64 ;;
  *) echo 'Build the Android transport on macOS or Linux.' >&2; exit 1 ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN/aarch64-linux-android26-clang"
export CC_aarch64_linux_android="$CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"
export AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar"
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384"
rustup target add aarch64-linux-android
cargo build --manifest-path "$ROOT/Cargo.toml" --package clipmesh --target aarch64-linux-android --release --locked
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
DEST="$ROOT/platforms/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$DEST"
cp "$TARGET_DIR/aarch64-linux-android/release/clipmesh" "$DEST/libclipmesh_transport.so"
"$TOOLCHAIN/llvm-strip" --strip-unneeded "$DEST/libclipmesh_transport.so"
file "$DEST/libclipmesh_transport.so"
