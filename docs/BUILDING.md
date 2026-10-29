# Building ClipMesh 0.3.0

Run these commands from the repository root unless a section says otherwise. The desktop installers and mobile packages include their native transport; end users do not need a Rust or .NET installation to use the packaged clients.

## Common requirements

- Rust **1.91 or later**, Cargo and `rustup`; a current stable toolchain is recommended.
- Git and the platform's native compiler/linker.
- Network access for Cargo, NuGet, Gradle and SDK dependencies on the initial build.
- Keep `Cargo.lock` and the vendored compatibility patches when building this release. Use `--locked` for reproducible dependency resolution.

The Rust core uses iroh for P2P QUIC, public endpoint discovery and encrypted relay fallback. New groups can operate with no legacy WebSocket URL. No cloud account, API token, hosted ClipMesh server or release credential is required to build or use that mode. Networking tests that use public discovery need access to the corresponding infrastructure; direct connectivity is network-dependent.

For a release checkout, use the `v0.3.0` tag. Generated outputs belong in ignored build directories; do not commit local invitations, configuration files, private signing material or device-test data.

## Rust core and tests

```sh
cargo build --locked --release -p clipmesh
cargo fmt --all --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --workspace --locked
```

The CLI is generated at `target/release/clipmesh` (`clipmesh.exe` on Windows). It supplies the desktop host bridge, mobile transport bridge and optional legacy WebSocket relay.

The public-network restart test is explicitly ignored by the default suite. To exercise seed-based joining, removal of the creator peer, and restart of the remaining peers on new ports:

```sh
cargo test --locked -p clipmesh \
  serverless_three_peer_seed_join_mac_off_and_all_peer_restart_new_ports \
  -- --ignored --nocapture
```

This test uses isolated synthetic groups and public iroh networking. It does not access OS clipboards or prove every native client behaves correctly on a physical device.

## macOS

Requirements: macOS with Xcode command-line tools, Rust and the Apple SDKs. The app targets macOS 13 or later; the script builds for the build machine's architecture.

```sh
bash scripts/build-macos.sh
```

Outputs:

- `dist/ClipMesh.app`
- `dist/ClipMesh-macOS.pkg`
- `dist/ClipMesh-macOS.pkg.sha256`

The script compiles the AppKit shell, bundles the Rust core, applies ad-hoc signatures and creates the installer. This does not produce a Developer ID-signed or notarized distribution. Those require the distributor's own Apple signing identity and notarization process.

## Windows

Requirements on Windows: Rust with a working native Windows linker, .NET 8 SDK, PowerShell and Inno Setup 6. The supplied script creates a self-contained Windows x64 application and a single setup executable.

```powershell
./scripts/build-windows.ps1
./dist/windows/ClipMesh.exe --protocol-self-test
./scripts/test-windows-lifecycle.ps1
```

Outputs:

- `dist/windows/ClipMesh.exe` and `clipmesh-core.exe`
- `dist/ClipMesh-Windows-Setup.exe`
- `dist/ClipMesh-Windows-Setup.exe.sha256`

The lifecycle test checks the native host's process-handling behavior. Packaging does not by itself prove clipboard interoperability with another physical device. The build does not apply an Authenticode signature; distributors can sign with their own certificate.

An alternative macOS-hosted cross-build uses Docker, a pinned LLVM-MinGW download and NSIS:

```sh
bash scripts/build-windows-container.sh
```

That script builds the Rust Windows core, publishes the UI using Microsoft's .NET SDK container, and produces the same setup filename. The native Windows script uses Inno Setup; the container path uses NSIS.

## Android

Requirements: macOS or Linux for the Rust cross-build, JDK 17, Android SDK platform 35, the Android SDK command-line tools, Rust and NDK **27.3.13750724**. Set `ANDROID_HOME` to the SDK location; `ANDROID_NDK_HOME` can override the NDK location.

```sh
sdkmanager 'platforms;android-35' 'ndk;27.3.13750724'
bash platforms/android/build-native.sh
cd platforms/android
./gradlew --no-daemon :app:testDebugUnitTest :app:lintDebug \
  :app:assembleDebug :app:assembleRelease
```

The wrapper pins Gradle 8.10.2. The native build targets `aarch64-linux-android` and bundles an arm64 executable in the APK. The app's build minimum is Android 8/API 26; full background clipboard capture requires a rooted environment with compatible classic Xposed/LSPosed injection into **System Framework**. Build compatibility is separate from a specific ROM's clipboard-hook compatibility.

Outputs:

- `platforms/android/app/build/outputs/apk/debug/app-debug.apk`
- The unsigned release APK under `platforms/android/app/build/outputs/apk/release/`

Debug APKs use a development signing identity. Configure a stable private release-signing key before distributing signed release upgrades, and retain that identity for future updates. Never commit the key. The normal build checks that the native P2P transport exists; the explicit `-Pclipmesh.relayOnly=true` developer option skips that guard and must not be used for the P2P distribution APK.

See [Android requirements and usage](../platforms/android/README.md) for module scope, battery settings and image-provider behavior.

## Jailbroken iOS/iPadOS

Requirements: macOS, the Xcode iPhoneOS SDK, Rust, `ldid`, `dpkg-deb` and `ripgrep`. For example, Homebrew can supply the latter three tools:

```sh
brew install ldid dpkg ripgrep
rustup target add aarch64-apple-ios
bash platforms/ios/build-native.sh
bash platforms/ios/build.sh
```

The Rust transport targets physical arm64 iOS with a deployment minimum of iOS 15. The setup app, SpringBoard tweak and clipboard reader contain arm64 and arm64e slices. The build validates the transport's iPhoneOS platform before packaging it; a macOS or simulator executable is not interchangeable.

Output: `platforms/ios/build/clipmesh_0.3.0_iphoneos-arm64.deb`.

Host checks:

```sh
bash platforms/ios/test-protocol.sh
bash platforms/ios/test-dashboard.sh
cargo build --locked -p clipmesh
bash platforms/ios/test-transport.sh
bash platforms/ios/test-fallback.sh
```

The package uses the rootless `/var/jb` layout and requires a jailbreak with compatible SpringBoard injection and scoped helper entitlements. It cannot be installed as a normal non-jailbroken app. Package installation and respring, re-enabling a semi-untethered jailbreak after reboot, and actual clipboard behavior are separate from successful compilation. See [iOS installation and permissions](../platforms/ios/README.md).

## Dependencies and release checks

The workspace includes narrow iOS compatibility patches for `netdev` and `netwatch`; [vendor/README.md](../vendor/README.md) describes them. Preserve upstream copyright and license notices when distributing the patched sources. Dependencies retain their own licenses; the ClipMesh project license does not replace them.

Before distributing a build:

1. Run the relevant core and platform checks above.
2. Inspect the generated package's version, bundled native transport and target architecture.
3. Produce SHA-256 checksums for the actual final files.
4. Verify installation and the intended text/image flows on the target platforms. Report source/build, installation and physical interoperability evidence separately.

The GitHub Actions workflow in [`.github/workflows/build.yml`](../.github/workflows/build.yml) builds the core and platform artifacts. A workflow build is not a substitute for device testing or a distributor's signing configuration.
