#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/HostModuleCache
xcrun --sdk macosx clang -c Sources/TransportIPC.c -o build/TransportIPC-host.o
xcrun --sdk macosx swiftc -swift-version 5 -module-cache-path "$PWD/build/HostModuleCache" Sources/Shared.swift Sources/NativeTransport.swift Sources/Socket.swift Tests/TransportCheck.swift build/TransportIPC-host.o -o build/transport-check
build/transport-check "${1:-../../target/debug/clipmesh}"
