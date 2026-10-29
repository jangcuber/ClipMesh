$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
cargo build --release -p clipmesh
if ($LASTEXITCODE) { throw 'Rust build failed' }
dotnet publish platforms/windows/ClipMesh.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist/windows
if ($LASTEXITCODE) { throw '.NET publish failed' }
Copy-Item target/release/clipmesh.exe dist/windows/clipmesh-core.exe
$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
    $candidate = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
    if (Test-Path $candidate) { $iscc = $candidate } else { throw 'Install Inno Setup 6, then re-run this script to create the single setup EXE.' }
}
& $iscc platforms/windows/installer.iss
if ($LASTEXITCODE) { throw 'Installer build failed' }
Get-FileHash dist/ClipMesh-Windows-Setup.exe -Algorithm SHA256 | Format-List | Out-File dist/ClipMesh-Windows-Setup.exe.sha256
