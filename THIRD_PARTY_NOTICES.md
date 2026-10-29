# Third-party notices

ClipMesh's own source is covered by the root `LICENSE`. Third-party projects retain their respective copyrights and licenses. This document identifies the principal components used by the source and release builds; it is not a claim that every resolved dependency is present in every platform binary.

## Vendored source

| Component | Version | License and source |
| --- | --- | --- |
| netdev | 0.46.3 | MIT; [upstream](https://github.com/shellrow/netdev), original text in `vendor/netdev/LICENSE` |
| netwatch | 0.19.3 | MIT OR Apache-2.0; [upstream](https://github.com/n0-computer/net-tools), original texts in `vendor/netwatch/LICENSE-MIT` and `vendor/netwatch/LICENSE-APACHE` |

The exact upstream revisions and narrow iOS compatibility changes are recorded in `vendor/README.md`. Those patches do not replace upstream authorship or license terms.

## Rust transport and cryptography

The release transport is built from the dependency versions locked in `Cargo.lock`. The principal components include:

| Component | License declared by its package | Upstream |
| --- | --- | --- |
| iroh 1.4.1 and its related transport crates | MIT OR Apache-2.0 | https://github.com/n0-computer/iroh |
| RustCrypto aes-gcm 0.10.3 | Apache-2.0 OR MIT | https://github.com/RustCrypto/AEADs |
| RustCrypto sha2 0.10.9 | MIT OR Apache-2.0 | https://github.com/RustCrypto/hashes |
| rustls 0.23.46 | Apache-2.0 OR ISC OR MIT | https://github.com/rustls/rustls |
| ring 0.17.14 | Apache-2.0 AND ISC; additional upstream notices retained | https://github.com/briansmith/ring |
| tokio 1.54.1 | MIT | https://github.com/tokio-rs/tokio |
| tokio-tungstenite 0.26.2 | MIT | https://github.com/snapview/tokio-tungstenite |
| serde | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| clap | MIT OR Apache-2.0 | https://github.com/clap-rs/clap |

`licenses/RUST_DEPENDENCIES.json` inventories all resolved registry packages, including platform-specific, build and test dependencies. `licenses/rust/` preserves license/notice texts from those package distributions or their recorded upstream commits. The inventory links to the original repositories and identifies the files collected. It is broader than an exact per-platform binary SBOM.

## Windows runtime and QR components

| Component | License/source |
| --- | --- |
| Microsoft .NET 8 runtime and Windows Desktop runtime | MIT and third-party notices; https://github.com/dotnet/runtime and https://github.com/dotnet/wpf |
| QRCoder 1.8.1 | MIT; https://github.com/Shane32/QRCoder |
| ZXing.Net 0.16.11 | Apache-2.0; https://github.com/micjahn/ZXing.Net |

The self-contained Windows app includes .NET runtime components. The runtime package license and third-party notice texts, together with QRCoder's license, are preserved under `licenses/windows/`. Build dependencies may appear there even when a particular runtime package file is not used in the final app.

## Android components

| Component | License/source |
| --- | --- |
| OkHttp 4.12.0 | Apache-2.0; https://github.com/square/okhttp |
| ZXing core 3.5.3 | Apache-2.0; https://github.com/zxing/zxing |
| ZXing Android Embedded 4.3.0 | Apache-2.0; https://github.com/journeyapps/zxing-android-embedded |
| Kotlin standard library | Apache-2.0; https://github.com/JetBrains/kotlin |
| AndroidX/Android support libraries resolved by Gradle | Apache-2.0 unless their package notices state otherwise; https://android.googlesource.com/platform/frameworks/support |

The project references Xposed API 82 with Gradle `compileOnly`. Its API/framework implementation is **not bundled as an Xposed runtime in the APK**; the user installs a compatible hooking framework separately. Upstream XposedBridge's [notice](https://github.com/rovo89/XposedBridge/blob/art/NOTICE.txt) declares Apache-2.0 for that API project. This does not assign that license to independently distributed LSPosed/Vector or other framework implementations.

The APK's existing signatures and runtime artifacts are preserved. License text copies under `licenses/android/` accompany the release rather than modifying or re-signing the APK. Gradle's resolved transitive dependency metadata remains authoritative for exact Android package versions.

## System APIs and distribution tools

AppKit, UIKit, Foundation, CryptoKit, Network and other Apple frameworks are provided by the operating system and are not copied into this repository. Windows operating-system APIs are likewise provided by Windows. NSIS, Inno Setup, Android/Rust/.NET SDKs and packaging tools are build/distribution tools with their own upstream licenses; installing ClipMesh does not transfer ownership of those tools.

Release downloads should be accompanied by the `ClipMesh-v0.3.0-licenses.zip` archive or this repository's `licenses/`, `vendor/` license files, and this notice. This companion preserves notices without changing previously tested installer, APK or DEB bytes or signing identities.
