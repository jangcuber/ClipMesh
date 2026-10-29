# Run on Windows after publishing the app/core. Uses a temporary install directory.
# Intended for the clean CI Windows profile, not a user's live clipboard session.
param([string]$Payload = (Join-Path $PSScriptRoot '../dist/windows'))
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -and $env:OS -ne 'Windows_NT') { throw 'Windows is required' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ClipMeshWindowCheck {
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
}
'@
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClipMesh upgrade test 한글 ' + [guid]::NewGuid())
$install = Join-Path $testRoot 'installed'; $helper = Join-Path $testRoot 'update helper'; $other = Join-Path $testRoot 'unrelated'
$processes = @()
$config = Join-Path $env:LOCALAPPDATA 'ClipMesh/config.json'
$before = if (Test-Path $config) { (Get-FileHash $config -Algorithm SHA256).Hash } else { $null }
function Start-TestProcess($file, $arguments = @()) {
 $p = Start-Process -FilePath $file -ArgumentList $arguments -PassThru
 $script:processes += $p
 return $p
}
try {
 foreach ($dir in @($install,$helper,$other)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null; Copy-Item (Join-Path $Payload '*') $dir -Recurse -Force }
 $app = Join-Path $install 'ClipMesh.exe'; $core = Join-Path $install 'clipmesh-core.exe'
 $first = Start-TestProcess $app @('--background')
 $deadline = (Get-Date).AddSeconds(20)
 do { Start-Sleep -Milliseconds 200; $first.Refresh() } while (!$first.HasExited -and $first.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)
 if ($first.HasExited -or $first.MainWindowHandle -eq [IntPtr]::Zero) { throw 'First app did not create its control window' }
 $second = Start-TestProcess $app; if (!$second.WaitForExit(5000) -or $second.ExitCode -ne 0) { throw 'Second launch did not activate and exit promptly' }
 $first.Refresh(); if (![ClipMeshWindowCheck]::IsWindowVisible($first.MainWindowHandle)) { throw 'Second launch did not show the first app window' }
 $orphan = Start-TestProcess $core @('relay','--listen','127.0.0.1:0')
 $unrelated = Start-TestProcess (Join-Path $other 'clipmesh-core.exe') @('relay','--listen','127.0.0.1:0')
 Start-Sleep -Milliseconds 500
 if ($orphan.HasExited -or $unrelated.HasExited) { throw 'Test relay processes failed to start' }
 $prepare = Start-TestProcess (Join-Path $helper 'ClipMesh.exe') @('--prepare-update','--install-dir',('"' + $install + '"'))
 if (!$prepare.WaitForExit(20000) -or $prepare.ExitCode -ne 0) { throw 'Update helper failed' }
 if (!$first.WaitForExit(5000) -or !$orphan.WaitForExit(5000)) { throw 'Installed app/core survived update preparation' }
 $unrelated.Refresh(); if ($unrelated.HasExited) { throw 'Unrelated same-name executable was terminated' }
 foreach ($file in @($app,$core)) { $lock = [IO.File]::Open($file,'Open','ReadWrite','None'); $lock.Dispose() }
 $after = if (Test-Path $config) { (Get-FileHash $config -Algorithm SHA256).Hash } else { $null }
 if ($before -ne $after) { throw 'Group configuration changed during lifecycle test' }
 Write-Output 'PASS second launch activates first window; update stops exact app + orphan core; unrelated process and config preserved; executable locks released'
} finally {
 foreach ($p in $processes) { try { if (!$p.HasExited) { Stop-Process -Id $p.Id -Force }; $p.Dispose() } catch {} }
 Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
