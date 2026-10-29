#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/HostModuleCache
xcrun --sdk macosx swiftc -swift-version 5 -module-cache-path "$PWD/build/HostModuleCache" Sources/Shared.swift Sources/Dashboard.swift Tests/DashboardCheck.swift -o build/dashboard-check
build/dashboard-check
