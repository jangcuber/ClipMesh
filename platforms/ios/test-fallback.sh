#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/HostModuleCache
xcrun --sdk macosx clang -Wall -Wextra -Werror Tests/OfflineTransport.c -o build/offline-transport
xcrun --sdk macosx clang -Wall -Wextra -Werror -c Sources/TransportIPC.c -o build/TransportIPC-host.o
xcrun --sdk macosx swiftc -swift-version 5 -module-cache-path "$PWD/build/HostModuleCache" Sources/Shared.swift Sources/NativeTransport.swift Sources/Socket.swift Tests/FallbackCheck.swift build/TransportIPC-host.o -o build/fallback-check
build/fallback-check "${1:-../../target/debug/clipmesh}" "$PWD/build/offline-transport"
