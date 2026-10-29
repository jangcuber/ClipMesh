# ClipMesh for rooted Android

**Automatic background clipboard capture requires a rooted device and a compatible Vector/LSPosed module loader.** An APK on an unrooted phone is a limited foreground client, not a fully supported background clipboard synchronizer.

ClipMesh 0.3.0 combines a settings app, foreground sync service, module and bundled Rust/iroh transport in one APK. The published Android build targets **arm64-v8a**, with Android 8 (API 26) as the installation minimum. The clipboard hook follows AOSP Android 13–16 layouts; that does not establish compatibility with every Samsung firmware or module loader.

[한국어 사용법](USAGE_KO.md) explains pairing, on/off controls, restart behavior and device checks. See the [project README](../../README.md) for the other platforms.

## Install and pair

1. Download `ClipMesh-Android.apk` from the project's release assets and install it. The 0.3.0 APK is **signed with a development/debug certificate**, not a production release identity. Install updates signed by the same certificate over the existing app to retain groups; uninstalling deletes app data.
2. In Vector or a compatible LSPosed build, enable ClipMesh and select **System Framework** (`android`) only. Reboot after enabling or updating the module. The module uses the classic Xposed API 82; a loader supporting only modern libxposed APIs is insufficient.
3. Open ClipMesh. Scan a trusted device's group QR, import a saved QR image, or create a group under **고급 설정**. A new P2P group needs no manually entered server address.
4. Tap **동기화 켜기**, allow notifications, select unrestricted battery usage and exclude ClipMesh from sleeping-app lists. Enable the device vendor's autostart setting where available.
5. Copy text or an image and paste it on another joined device. Image pasting requires an image-aware editor or message composer; copying a file path or using a Share action is not necessarily copying an image.

Without root/module injection, Android restricts background clipboard reads. Sending is limited to permitted foreground reads; incoming writes also depend on OS policy. Do not treat this mode as full background synchronization.

## Connection and restart behavior

New groups use public endpoint-ID seeds and prefer direct QUIC connections. When direct communication is unavailable, iroh can use an encrypted relay. A Mac or temporary WebSocket tunnel is not a mandatory hub, but internet discovery/relay services may still be needed across networks. This is not a guarantee of connectivity without any external infrastructure.

P2P QR sharing waits for the device's persistent endpoint identity, then shares an invitation with an empty WebSocket relay address and up to 16 seed IDs. Additional peers are learned through authenticated address-book exchange. The invitation retains the group key. Older WebSocket groups remain supported; migrate through a current P2P QR or the advanced controls instead of creating a different key accidentally.

The on/off choice persists. While enabled, the app requests foreground-service restart after boot/first unlock or an app update, and resumes when opened if the service is absent. Disabled or paused configurations are not enabled by boot handling. Force-stopping the app or vendor battery/autostart restrictions can prevent restart; open the app again and check its settings. Actual reboot, lock and power behavior must be verified on the target firmware.

The displayed peer count represents authenticated live transport sessions, not cached endpoint IDs or merely a connected WebSocket server. A successful build or a server connection does not prove another device's clipboard is working.

## Features and limits

- Text up to 1 MiB UTF-8, including Korean, emoji and empty text.
- PNG images up to 8 MiB / 40 megapixels, with width and height at most 16384. Other readable clipboard image formats are converted locally within these limits. Android image capture uses content URIs.
- Local QR generation, camera scanning and bounded QR-image import. No QR-generation website receives invitations.
- AES-256-GCM group events, deterministic conflict ordering, replay/echo suppression, reconnect backoff and a bounded latest offline state.
- Saved groups, one active group and a single visible synchronization on/off control.
- Owner-profile physical clipboard only. Work profiles and virtual-device clipboards are excluded.
- No file/HTML transfer, history browser or individual member revocation. Removing a member requires a new group key and re-pairing trusted devices.

Invitations contain a shared bearer secret: any holder can read and write group events. Group membership checks do not establish a human identity. Invitation text containing `clipmesh://join#` is excluded from automatic text sync.

Saved group secrets and latest event state are Android-Keystore encrypted, with OS backup disabled. The native helper uses app-private runtime configuration and endpoint cache files; the runtime configuration contains the group key and is removed on clean stop. Image pasting requires readable bytes: the private image provider retains up to 16 recent plaintext PNG cache files, at most 8 MiB each, and grants access to actual paste recipients. OS user isolation and device encryption remain relevant.

## Build

Use a current stable Rust toolchain, JDK 17+, Android SDK API 35, build tools and Android NDK r27d. Run from the repository root:

```sh
sdkmanager 'ndk;27.3.13750724'
bash platforms/android/build-native.sh
cd platforms/android
./gradlew --no-daemon testDebugUnitTest assembleDebug assembleRelease lintDebug
```

Set `ANDROID_HOME` to the SDK directory, or `ANDROID_NDK_HOME` to an existing NDK when needed. [build-native.sh](build-native.sh) builds the arm64 PIE transport from the repository sources and packages it as `lib/arm64-v8a/libclipmesh_transport.so`. The APK build fails if that payload is absent. The explicit developer-only property `-Pclipmesh.relayOnly=true` bypasses that guard; it must not be used for the P2P distribution APK.

The Gradle wrapper is pinned to 8.10.2. `assembleDebug` produces a debug-signed APK; `assembleRelease` remains unsigned unless a release signing configuration is supplied. Renaming the published debug APK to `ClipMesh-Android.apk` does not change its signing identity. Keep signing keys private and preserve a consistent certificate for updates.

Host tests cover cross-language text/PNG encryption vectors, payload bounds, conflict ordering, QR decoding, seed invitations, peer-count presentation and restart policy. They do not replace Android camera, URI permission, clipboard-hook, power or reboot tests.

## Module boundary and device checks

The module hooks `ClipboardService.setPrimaryClipInternalLocked(ClipData, uid, …)` after updates. Text crosses a bounded pipe into a provider restricted to system/app UID. Image capture reuses ClipboardService's clipboard-scoped read grant for ClipMesh, then reads/decodes in the app process. Incoming images are exposed through a separate nonexported grantable provider. No clipboard content is put in broadcasts, logs or notifications.

On a target device, verify module injection, text/image pasting in both directions, background/locked behavior, rapid image-to-text copies, echo suppression, camera permission denial, network changes, enabled reboot recovery and disabled reboot persistence. An unsupported private API layout must leave ordinary system clipboard operations usable. See the [Korean checklist](USAGE_KO.md) for a sequence that also checks communication after a device is turned off.

## References

[AOSP Android 16 ClipboardService](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r1/services/core/java/com/android/server/clipboard/ClipboardService.java) documents the hook and URI-grant layout. [LSPosed](https://github.com/LSPosed/LSPosed) provides the classic Xposed API contract. [ClipSync](https://github.com/lcebot/clipsync) describes the system-server hook approach. [ZXing Android Embedded](https://github.com/journeyapps/zxing-android-embedded) supplies the embedded camera/decoder integration. See the project's dependency notices for bundled third-party components.
