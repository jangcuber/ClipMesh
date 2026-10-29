#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p build
for ARCH in arm64 arm64e; do
  xcrun clang -Wall -Wextra -Werror -O2 -arch "$ARCH" -isysroot "$SDK" -miphoneos-version-min=15.0 -fobjc-arc -framework Foundation -framework UIKit -framework CoreGraphics -framework ImageIO Diagnostics/ImageProbe.m -o "build/image-probe-$ARCH"
done
xcrun lipo -create build/image-probe-arm64 build/image-probe-arm64e -output build/clipmesh-image-probe
ldid -SDiagnostics/ClipboardProbe.entitlements build/clipmesh-image-probe
printf 'Built bounded test-only probe: %s/build/clipmesh-image-probe\n' "$PWD"
