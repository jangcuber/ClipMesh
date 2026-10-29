# ClipMesh

**macOS · Windows · 루팅 Android · 탈옥 iPhone 사이의 계정 없는 클립보드 동기화**

텍스트와 이미지를 복사하면 같은 Sync Group의 다른 기기로 전송합니다. Apple ID나 Microsoft 계정 없이 QR로 연결하며, Mac을 중앙 서버로 켜둘 필요가 없습니다.

[**0.3.0 다운로드**](https://github.com/jangcuber/ClipMesh/releases/tag/v0.3.0) · [사용 방법](docs/USAGE_KO.md) · [빌드](docs/BUILDING.md) · [문제 해결](docs/TROUBLESHOOTING.md)

> **Android는 루팅 및 Vector/LSPosed의 System Framework 후킹이 필요합니다. iPhone은 rootless 탈옥 상태가 필요합니다. 일반 비루팅 Android·일반 iPhone 앱으로 시스템 전체 백그라운드 동기화를 지원하지 않습니다.**

## 설치

[Releases](https://github.com/jangcuber/ClipMesh/releases/latest)에서 기기에 맞는 파일을 받으세요.

| 플랫폼 | 파일 | 요구 사항 |
|---|---|---|
| macOS | `ClipMesh-macOS.pkg` | macOS 13 이상, 현재 릴리스는 Apple Silicon |
| Windows | `ClipMesh-Windows-Setup.exe` | Windows x64, 런타임 포함, 사용자별 설치 |
| Android | `ClipMesh-Android.apk` | ARM64, Android 8/API 26 이상, **루팅 + Vector/LSPosed** |
| iPhone | `ClipMesh-iOS-rootless.deb` | iOS 15 이상 rootless 환경, **탈옥 + tweak loader** |

- **Android:** APK 설치 → Vector/LSPosed에서 ClipMesh 활성화 → **System Framework (`android`)** 범위 선택 → 재부팅 → 배터리 사용을 제한 없음으로 설정합니다. 앱에서 알림 권한을 허용하고 동기화를 켭니다. 루팅만으로 모듈 범위 설정이 생략되지는 않습니다.
- **iPhone:** 탈옥 패키지 관리자로 DEB를 설치하고 리스프링합니다. 설정 앱을 닫아도 SpringBoard 엔진이 동작합니다. rootful/roothide 및 일반 IPA 설치는 이 릴리스의 지원 대상이 아닙니다.
- **Mac·Windows:** 설치 후 ClipMesh를 실행합니다. 창을 닫아도 메뉴 막대/트레이에서 계속 실행됩니다. Rust/.NET을 별도로 설치할 필요가 없습니다.

현재 Mac 패키지는 ad-hoc 서명·미공증, Windows 설치 파일은 미서명, Android APK는 개발용 서명입니다. 운영체제에서 배포자 확인 경고가 나타날 수 있습니다. 배포 인증서로 서명된 패키지라고 표시하지 않습니다.

## 기기 연결

1. 첫 기기에서 새 그룹을 만들고 **동기화 켜기**를 켭니다. 별도 서버 주소는 필요 없습니다.
2. 기기 신원이 준비되면 **다른 기기에 보여줄 QR**을 엽니다.
3. 새 기기에서 QR을 스캔하거나 **QR 이미지로 참가**한 뒤 동기화를 켭니다. Windows/Mac은 QR 이미지 파일을 가져올 수 있습니다.
4. **연결된 다른 기기 수**와 직접/릴레이 경로를 확인하고 복사·붙여넣기를 사용합니다.

이미 연결된 기기 중 어느 기기에서든 새 기기를 초대할 수 있습니다. 처음 참가할 때는 QR에 포함된 기기 중 적어도 하나가 온라인이어야 합니다. **QR에는 그룹 비밀키가 들어 있으므로 공개 게시하지 마세요.**

이전 WebSocket 그룹은 고급 설정의 **Mac 없이 연결로 전환** 기능이나 0.3.0 기기의 새 QR로 같은 키를 다시 가져와 전환할 수 있습니다. 기존 앱을 삭제하거나 새 그룹을 만들 필요는 없습니다.

## 연결과 재부팅

- 영구 기기 ID와 공개 iroh 주소 탐색을 사용합니다. 직접 QUIC 연결이 어려우면 암호화된 iroh 릴레이를 이용합니다. **같은 Wi-Fi와 Mac 서버가 필요하지 않습니다.**
- 일부 기기가 꺼져 있어도 나머지 온라인 기기는 계속 동기화할 수 있습니다. 재접속하면 그룹의 최신 값으로 수렴하며, 오프라인 중 모든 중간 복사 기록을 전달하지는 않습니다.
- Mac·Windows는 로그인 자동 실행을 지원합니다. Windows 설치본은 로그인 항목을 등록하며 앱에서 끌 수 있습니다.
- Android는 저장된 켜짐 상태에 따라 부팅/잠금 해제 후 서비스를 복구합니다. 강제 종료·제조사 배터리 정책은 수동 앱 실행이 필요할 수 있습니다.
- **탈옥 iPhone은 완전 재부팅 후 탈옥 재활성화가 필요할 수 있습니다.** 탈옥 tweak injection이 활성화되면 저장된 설정으로 다시 연결합니다.

공개 iroh discovery/relay 인프라와 인터넷 접속에는 계속 의존합니다. 모든 방화벽·망에서 연결되거나 외부 서비스가 항상 가동된다고 보장하지 않습니다. 선택적인 이전 WebSocket 릴레이는 [별도 안내](docs/RELAY.md)를 참고하세요.

## 기능과 제한

- UTF-8 텍스트 최대 **1 MiB**, PNG 이미지 최대 **8 MiB / 4천만 픽셀**.
- AES-256-GCM 그룹 암호화, 기기별 켜기/끄기, 여러 그룹 저장·하나의 활성 그룹.
- QR 페어링, 저장된 기기 신원, 재연결, 결정적인 동시 복사 처리와 반향 억제.
- 데스크톱 코어의 암호화된 최신값/기록 저장. 앱 내 전체 히스토리 UI는 없습니다.
- 이미지 픽셀을 PNG로 전송합니다. 파일 경로 복사, 임의 파일 전송, HTML/rich text, 애니메이션 보존은 지원하지 않습니다.
- 기기별 키 폐기·추방은 없습니다. 초대 유출 시 새 그룹을 만들어 다시 연결해야 합니다.

실제 Mac·Windows·루팅 Galaxy·rootless iPhone 환경에서 연결 및 사용을 확인했습니다. 공개 주소 탐색을 사용하는 자동 재접속과 Mac 역할 종료 후 연결도 검증했습니다. 모든 OS 버전·ROM, 실제 재부팅 조합, 장기 부하 또는 정확한 지연을 전부 측정한 것은 아닙니다.

## 개발

프로토콜은 [docs/PROTOCOL.md](docs/PROTOCOL.md), 플랫폼 빌드는 [docs/BUILDING.md](docs/BUILDING.md)를 참고하세요.

```sh
cargo test --workspace --locked
cargo clippy --workspace --all-targets -- -D warnings
```

```text
crates/clipmesh/   Rust 암호화·상태·QUIC/relay 전송 엔진
platforms/macos/  AppKit 메뉴 막대 앱
platforms/windows/ WinForms 트레이 앱과 설치 정의
platforms/android/ Kotlin 앱·foreground service·Xposed 모듈
platforms/ios/    UIKit 설정 앱·SpringBoard 엔진·rootless 패키징
vendor/          iOS 호환 패치가 포함된 Rust 의존성
```

MIT 라이선스. 타사 구성 요소는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)와 각 라이선스를 따릅니다. 보안 특성과 비밀키 취급은 [docs/SECURITY.md](docs/SECURITY.md)를 확인하세요.
