#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/HostModuleCache
xcrun --sdk macosx swiftc -swift-version 5 -module-cache-path "$PWD/build/HostModuleCache" Sources/Shared.swift Tests/ProtocolCheck.swift -o build/protocol-check
build/protocol-check ../../crates/clipmesh/tests/v1-vector.json
