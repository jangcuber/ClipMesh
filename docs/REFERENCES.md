# References and dependencies

ClipMesh implements its own application clipboard protocol and native clients. Architecture references do not imply that third-party application source was copied or that the projects endorse this release.

- [iroh](https://github.com/n0-computer/iroh): the bundled Rust QUIC endpoint, address lookup and encrypted relay transport.
- [Continuity](https://github.com/hardope/continuity): shared-core/native-host architecture reference.
- [ClipSync](https://github.com/lcebot/clipsync): Android system ClipboardService observation reference.
- [ioscpy](https://github.com/lautarovculic/ioscpy): SpringBoard and jailbreak packaging reference.
- [Apple NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard): native Mac clipboard APIs.
- [Microsoft clipboard APIs](https://learn.microsoft.com/en-us/windows/win32/dataxchg/using-the-clipboard): Windows notifications and ownership.

Vendored Rust compatibility patches and dependency licenses are listed in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), [vendor/README.md](../vendor/README.md), and the accompanying license inventory. The iOS patches preserve mobile interface monitoring without relying on macOS-only libc declarations.
