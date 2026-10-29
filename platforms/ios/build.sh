#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="$SDK"
BUILD="$PWD/build"
STAGE="$BUILD/package"
export CLANG_MODULE_CACHE_PATH="$BUILD/ModuleCache"
export SWIFT_MODULECACHE_PATH="$BUILD/ModuleCache"
TRANSPORT="${CLIPMESH_IOS_TRANSPORT:-$PWD/../../target/aarch64-apple-ios/release/clipmesh}"
if [[ ! -f "$TRANSPORT" ]]; then
  echo "Missing iOS transport binary: $TRANSPORT. Build the Rust aarch64-apple-ios release target first." >&2
  exit 1
fi
xcrun lipo "$TRANSPORT" -verify_arch arm64
if ! xcrun vtool -show-build "$TRANSPORT" | rg -q 'platform IOS$'; then
  echo "Transport must be an iPhoneOS executable, not a macOS or simulator binary." >&2
  exit 1
fi
mkdir -p "$BUILD" "$STAGE/DEBIAN" "$STAGE/var/jb/Applications/ClipMesh.app" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries" "$STAGE/var/jb/usr/libexec"
for ARCH in arm64 arm64e; do
  xcrun clang -arch "$ARCH" -isysroot "$SDK" -miphoneos-version-min=15.0 -c Sources/Bootstrap.c -o "$BUILD/Bootstrap-$ARCH.o"
  xcrun clang -arch "$ARCH" -isysroot "$SDK" -miphoneos-version-min=15.0 -c Sources/TransportIPC.c -o "$BUILD/TransportIPC-$ARCH.o"
  xcrun clang -arch "$ARCH" -isysroot "$SDK" -miphoneos-version-min=15.0 -c Sources/ClipboardIPC.c -o "$BUILD/ClipboardIPC-$ARCH.o"
  xcrun clang -arch "$ARCH" -isysroot "$SDK" -miphoneos-version-min=15.0 -fobjc-arc -framework Foundation -framework UIKit Sources/ClipboardReader.m -o "$BUILD/clipmesh-reader-$ARCH"
  xcrun swiftc -module-cache-path "$BUILD/ModuleCache" -swift-version 5 -O -sdk "$SDK" -target "$ARCH-apple-ios15.0" -emit-library -module-name ClipMeshEngine Sources/Shared.swift Sources/NativeTransport.swift Sources/Socket.swift Sources/Engine.swift "$BUILD/Bootstrap-$ARCH.o" "$BUILD/ClipboardIPC-$ARCH.o" "$BUILD/TransportIPC-$ARCH.o" -Xlinker -install_name -Xlinker /var/jb/Library/MobileSubstrate/DynamicLibraries/ClipMesh.dylib -o "$BUILD/ClipMesh-$ARCH.dylib"
  xcrun swiftc -module-cache-path "$BUILD/ModuleCache" -swift-version 5 -O -sdk "$SDK" -target "$ARCH-apple-ios15.0" Sources/Shared.swift Sources/Dashboard.swift Sources/PairingQR.swift Sources/main.swift -o "$BUILD/ClipMesh-$ARCH"
done
xcrun lipo -create "$BUILD/ClipMesh-arm64.dylib" "$BUILD/ClipMesh-arm64e.dylib" -output "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/ClipMesh.dylib"
xcrun lipo -create "$BUILD/ClipMesh-arm64" "$BUILD/ClipMesh-arm64e" -output "$STAGE/var/jb/Applications/ClipMesh.app/ClipMesh"
xcrun lipo -create "$BUILD/clipmesh-reader-arm64" "$BUILD/clipmesh-reader-arm64e" -output "$STAGE/var/jb/usr/libexec/clipmesh-reader"
ldid -Spackaging/reader-entitlements.plist "$STAGE/var/jb/usr/libexec/clipmesh-reader"
cp "$TRANSPORT" "$STAGE/var/jb/usr/libexec/clipmesh-transport"
chmod 0755 "$STAGE/var/jb/usr/libexec/clipmesh-transport"
ldid -Spackaging/transport-entitlements.plist "$STAGE/var/jb/usr/libexec/clipmesh-transport"
cp packaging/Info.plist "$STAGE/var/jb/Applications/ClipMesh.app/Info.plist"
cp packaging/ClipMesh.plist "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/ClipMesh.plist"
cp packaging/control packaging/postinst packaging/postrm "$STAGE/DEBIAN/"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
ldid -Spackaging/entitlements.plist "$STAGE/var/jb/Applications/ClipMesh.app/ClipMesh"
ldid -S "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/ClipMesh.dylib"
dpkg-deb --root-owner-group -Zgzip --build "$STAGE" "$BUILD/clipmesh_0.3.0_iphoneos-arm64.deb"
echo "Built: $BUILD/clipmesh_0.3.0_iphoneos-arm64.deb"
