#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Native macOS .NET can fail under some unsupported security/JIT configurations.
# The official Linux SDK supports publishing self-contained Windows executables.
command -v docker >/dev/null
bash scripts/build-core-windows.sh
docker run --rm -v "$PWD:/work" -w /work \
  -e DOTNET_CLI_HOME=/tmp/clipmesh-dotnet -e DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  -e NUGET_PACKAGES=/work/.cache/nuget-linux mcr.microsoft.com/dotnet/sdk:8.0 \
  dotnet publish platforms/windows/ClipMesh.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist/windows
docker run --rm -v "$PWD:/work" -w /work mcr.microsoft.com/dotnet/sdk:8.0 \
  sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends nsis >/dev/null && makensis -V2 platforms/windows/installer.nsi'
shasum -a 256 dist/ClipMesh-Windows-Setup.exe > dist/ClipMesh-Windows-Setup.exe.sha256
