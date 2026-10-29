#!/bin/bash
# Build the bundled network transport for physical arm64 iPhones (including arm64e devices).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The iOS transport build requires macOS and the Xcode iPhoneOS SDK.' >&2
  exit 1
fi
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$(xcrun --sdk iphoneos --find clang)"
export CC_aarch64_apple_ios="$CARGO_TARGET_AARCH64_APPLE_IOS_LINKER"
export AR_aarch64_apple_ios="$(xcrun --sdk iphoneos --find ar)"
if ! rustup target list --installed | rg -qx 'aarch64-apple-ios'; then
  rustup target add aarch64-apple-ios
fi
# The workspace carries narrow iOS-only netdev/netwatch compatibility patches.
# --locked pins the full transport dependency graph used by desktop and Android.
cargo build --locked --release -p clipmesh --bin clipmesh --target aarch64-apple-ios
file target/aarch64-apple-ios/release/clipmesh
printf 'Built iOS transport: %s/target/aarch64-apple-ios/release/clipmesh\n' "$ROOT"
