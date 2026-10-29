# ClipMesh for Windows

Windows x64 tray client, distributed as one per-user setup EXE with the .NET runtime and Rust transport included. It does not require an administrator account or a separate runtime install.

Install `ClipMesh-Windows-Setup.exe` from [Releases](https://github.com/jangcuber/ClipMesh/releases/latest). Select/create a group, enable synchronization and invite other devices with its QR. New0.3 groups use saved endpoint IDs and do not need a Mac server. The advanced section provides optional legacy WebSocket settings.

Closing the settings window keeps the tray application running. Open it again through the tray or launch the app again; choose **완전히 종료** to stop it. The installer enables a current-user login entry so an enabled saved group reconnects after login; this is not a pre-login Windows service and can be disabled from settings.

The update installer stages the new app separately, stops processes from the exact installation path and checks executable locks before overwriting files. It preserves `%LOCALAPPDATA%\ClipMesh`, which contains config/group keys/history. If an older installer reports a file-write error, cancel rather than Ignore and use the current installer. See [troubleshooting](../../docs/TROUBLESHOOTING.md).

Native Win32 clipboard notifications are handled on the UI thread. The bundled core communicates through private process pipes. Clipboard payloads are not written as diagnostic logs. Local image data is normalized to PNG with native paste formats exposed to recipient apps.

The setup is unsigned; OS reputation prompts may appear. Source/build/payload checks and actual-device behavior are separate validation layers. For build instructions, see [BUILDING.md](../../docs/BUILDING.md).
