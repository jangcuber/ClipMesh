# ClipMesh for jailbroken iPhone and iPad

ClipMesh 0.3.0 synchronizes text and images with paired Mac, Windows and Android devices. The rootless `.deb` includes a setup app, a SpringBoard tweak and the native P2P transport. No Apple account is needed, and the setup app can be closed after configuration.

## Requirements

- **A rootless jailbreak is required.** The package targets iOS/iPadOS 15 or later on arm64 devices and includes arm64 and arm64e app/tweak slices.
- A working MobileSubstrate-compatible injection framework must load the tweak into SpringBoard.
- The jailbreak must support the `/var/jb` layout and ClipMesh's scoped clipboard-reader entitlements.
- Rootful and roothide layouts are not supported by this package. An ordinary, non-jailbroken iPhone cannot use this `.deb` as a sideloaded app.

The deployment minimum is a build target, not a claim that every iOS version or jailbreak is compatible. Clipboard access and background networking depend on the device's jailbreak environment.

## Install and connect

1. Download `ClipMesh-iOS-rootless.deb` from the project's GitHub release.
2. Install it with a package manager such as Sileo or Zebra, then **respring** to load the SpringBoard tweak. Installing the package refreshes its icon registration but does not automatically respring.
3. Open **ClipMesh**. To join an existing group, choose **QR 스캔해서 참여** and scan another device's ClipMesh QR.
4. Turn on **동기화 켜기**. New text and image copies will synchronize with the selected group.
5. To create a group, open **고급 설정 → 새 그룹 만들기** and enter a name. A new group starts enabled and prepares its QR automatically; no server address is required. Show that QR to the other devices.

The dashboard shows the selected group, connection route and authenticated online peers. Peer counts exclude this device. A connection to a legacy WebSocket relay alone does not establish how many other devices are online, so that count remains unknown.

Pairing QR codes contain the group's encryption key. Show them only to trusted devices. QR rendering and scanning happen locally; no QR service receives the invitation. The camera permission is used only for scanning. Removing a group from this device does not revoke another member: create a new group and pair the remaining trusted devices to replace the shared key.

## Connection and restart behavior

New P2P groups use persistent endpoint identities, public endpoint seeds and iroh discovery. Devices try direct QUIC connections and can use an encrypted iroh relay when a direct path is unavailable. A Mac, vendor account or temporary WebSocket tunnel is not a required server for these groups. Available paired devices can continue synchronizing while the Mac is off.

Public discovery and relay services still need to be reachable when the network requires them. At least one available paired peer is needed to receive a copy. Group keys and clipboard plaintext are not published to discovery services; public endpoint metadata, connection addresses and traffic timing can be visible to the relevant infrastructure.

Saved group settings, endpoint identity, peer information and the latest encrypted clipboard winner survive process restarts. The tweak starts the engine after SpringBoard launches and reconnects when synchronization is enabled. Unlock the device after boot so its protected saved state is available.

**An ordinary reboot can disable tweak injection on a semi-untethered jailbreak. Re-enable the jailbreak before expecting ClipMesh to resume.** ClipMesh does not recreate a jailbreak or bypass the device's boot security. Respringing within an active jailbreak and rebooting into a non-jailbroken state are different operations.

Existing WebSocket groups remain compatible. Their relay URL is available under advanced settings. P2P QR export includes public seeds and removes the legacy relay address from the exported invitation. If a configured legacy relay is available, the native wrapper can fall back to Network.framework WebSocket after a bounded native outage. A relay-free group keeps retrying native discovery instead of inventing a fallback URL.

## Clipboard behavior and limits

- Plain text: up to **1 MiB UTF-8**, including Korean, emoji and empty text.
- Images: normalized to **PNG**, up to **8 MiB**, **40 million pixels**, and **16384 pixels per dimension**. The receiving app must support pasting images. Copying a file path or using an app's Share action is not necessarily copying an image.
- One active group at a time, with a device-local on/off control and saved group selection.
- Deterministic logical-clock ordering resolves competing copies; native change tracking prevents received values from creating an echo loop.
- Startup and resume do not publish the pre-existing system clipboard. Reconnection can apply the group's latest saved winner, so it can change the local clipboard.
- Clipboard payloads use AES-256-GCM. One encrypted winning event per group is retained for reconnect; there is no browsable clipboard-history UI.
- File transfer and HTML/rich-text synchronization are not implemented.

## Helpers, permissions and local data

The SpringBoard engine watches pasteboard revisions on a serial worker queue. A separate bounded reader obtains changed text or images through an anonymous pipe. Only the reader receives `com.apple.Pasteboard.paste-unchecked` and `com.apple.Pasteboard.background-access`. It checks that its parent is SpringBoard and that synchronization is enabled; it does not provide a network service or persistent clipboard store.

A separate Rust helper handles P2P transport. It does not access the system clipboard and does not receive the reader's pasteboard entitlements. Clipboard payloads passed through its transport bridge are already encrypted. TLS certificate and hostname verification remain enabled.

The jailbreak executables have the platform/no-container/no-sandbox entitlements needed by this layout. ClipMesh does not modify a global paste-permission database or dismiss other apps' permission dialogs. A jailbreak that does not honor these entitlements may require a platform-specific adaptation.

Group configuration is stored owner-only and protected until the first unlock after boot. Native endpoint identity and peer metadata are also saved locally; the latest clipboard winner is encrypted with the group key. Privileged jailbreak processes can access local secrets, so OS isolation and device encryption remain part of the protection. Status files contain connection information and counters, not clipboard contents or group keys.

After removal, respring to unload the already-running tweak. Ordinary removal preserves settings for reinstallation. Purge removes the main configuration and engine-state files; native endpoint-cache files may remain and should be considered when manually clearing local state.

## Build and check

See [Building ClipMesh](../../docs/BUILDING.md) for toolchains, outputs and cross-platform checks. The iOS build requires macOS, the Xcode iPhoneOS SDK, Rust, `ldid`, `dpkg-deb` and `ripgrep`.

From the repository root:

```sh
bash platforms/ios/build-native.sh
bash platforms/ios/build.sh
bash platforms/ios/test-protocol.sh
bash platforms/ios/test-dashboard.sh
cargo build --locked -p clipmesh
bash platforms/ios/test-transport.sh
bash platforms/ios/test-fallback.sh
```

The package is generated at `platforms/ios/build/clipmesh_0.3.0_iphoneos-arm64.deb`. App/tweak entitlements are signed with `ldid`; this is jailbreak signing, not Apple distribution signing. The build uses native Xcode tools and does not require Theos.

Host tests check authenticated protocol compatibility, PNG bounds, encrypted-winner recovery, native transport bridging, dashboard states and bounded fallback. They do not replace actual-device clipboard, camera, locked-screen, battery or reboot checks.
