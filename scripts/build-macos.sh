#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --release -p clipmesh
mkdir -p .cache/swift
APP="$PWD/dist/ClipMesh.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp platforms/macos/Info.plist "$APP/Contents/Info.plist"
cp target/release/clipmesh "$APP/Contents/MacOS/clipmesh-core"
xcrun swiftc -module-cache-path .cache/swift -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework CryptoKit -framework ServiceManagement platforms/macos/ClipMesh.swift -o "$APP/Contents/MacOS/ClipMesh"
codesign --force --sign - "$APP/Contents/MacOS/clipmesh-core"
codesign --force --sign - "$APP"
pkgbuild --component "$APP" --install-location /Applications --identifier dev.clipmesh.desktop --version 0.3.0 dist/ClipMesh-macOS.pkg
codesign --verify --deep --strict "$APP"
pkgutil --payload-files dist/ClipMesh-macOS.pkg | /usr/bin/grep -q "clipmesh-core"
shasum -a 256 dist/ClipMesh-macOS.pkg > dist/ClipMesh-macOS.pkg.sha256
