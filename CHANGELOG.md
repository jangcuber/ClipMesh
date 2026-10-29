# Changelog

## 0.3.0 — 2026-10-29

- Public release for macOS, Windows x64, rooted Android and rootless-jailbroken iOS.
- Account-free QR pairing with persistent endpoint IDs; new groups do not require a Mac server or an ephemeral WebSocket tunnel.
- Authenticated peer exchange, public iroh address lookup, direct QUIC and encrypted relay fallback.
- Text and PNG clipboard synchronization with deterministic conflict handling, reconnect recovery and echo suppression.
- Korean connection dashboard, per-device synchronization controls and live peer counts.
- Windows update preparation closes the exact installed UI/core before file replacement; duplicate launches activate the existing window.
- Android dedicated QR scanner, local QR-image import, restricted clipboard image URI bridge and saved-enabled boot recovery.
- iOS verified mobile CA bundle, rootless SpringBoard engine, scoped clipboard helper and native transport process.

Requirements and current signing properties are documented in the root README and platform guides. Android system-wide background synchronization requires rooting and Vector/LSPosed System Framework scope. iOS requires an active compatible rootless jailbreak; a full reboot may require reactivating that jailbreak.
