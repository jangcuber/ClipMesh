#!/bin/bash
# Cross-compile the real Windows x64 core on macOS with isolated LLVM-MinGW.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION=20261020
ARCHIVE="llvm-mingw-${VERSION}-ucrt-macos-universal.tar.xz"
CACHE="$ROOT/.cache/toolchains"
TOOLCHAIN="$CACHE/llvm-mingw-${VERSION}-ucrt-macos-universal"
# Pinned release digest, also published by GitHub's release-assets API.
SHA256=e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e
if [ "$(uname -s)" != Darwin ]; then
  echo 'This cross-build helper requires macOS; use cargo build on Windows.' >&2
  exit 1
fi
if [ ! -x "$TOOLCHAIN/bin/x86_64-w64-mingw32-clang" ]; then
  mkdir -p "$CACHE"
  curl --fail --location --retry 2 "https://github.com/mstorsjo/llvm-mingw/releases/download/$VERSION/$ARCHIVE" -o "$CACHE/$ARCHIVE"
  echo "$SHA256  $CACHE/$ARCHIVE" | shasum -a 256 -c -
  tar -xJf "$CACHE/$ARCHIVE" -C "$CACHE"
fi
rustup target add x86_64-pc-windows-gnullvm
export PATH="$TOOLCHAIN/bin:$PATH"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER="$TOOLCHAIN/bin/x86_64-w64-mingw32-clang"
export CC_x86_64_pc_windows_gnullvm="$TOOLCHAIN/bin/x86_64-w64-mingw32-clang"
export AR_x86_64_pc_windows_gnullvm="$TOOLCHAIN/bin/x86_64-w64-mingw32-ar"
# UCRT exists on supported Windows 10/11; compiler support libraries remain static.
export CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_RUSTFLAGS='-C target-feature=+crt-static'
cargo build --locked --release -p clipmesh --target x86_64-pc-windows-gnullvm
mkdir -p dist/windows
cp target/x86_64-pc-windows-gnullvm/release/clipmesh.exe dist/windows/clipmesh-core.exe
file dist/windows/clipmesh-core.exe
shasum -a 256 dist/windows/clipmesh-core.exe
