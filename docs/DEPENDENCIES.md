# 의존성 고정 및 호환성 상태

기준일: 2026-10-07

| 항목 | 고정/후보 버전 | 상태 | 근거 및 남은 확인 |
|---|---:|---|---|
| 배포 대상 | macOS 12.0+ / x86_64 | 고정 | `Package.swift`, `Info.plist`, 빌드 스크립트에 반영 |
| 빌드 도구 | Xcode 14.2 / Swift 5.7 | 고정 | Apple은 Xcode 14.2가 Monterey 12.5 이상에서 실행되고 macOS 10.13~13.1 배포 대상을 지원한다고 명시 |
| 촬영 | AVFoundation (OS 제공) | 고정 | 별도 런타임 의존성 없음. 실제 2015 iMac 카메라 검증 대기 |
| 전원 assertion | IOKit (OS 제공) | 고정 | `PreventUserIdleSystemSleep` 사용. 디스플레이 절전을 허용하는 assertion |
| H.264/분할 | FFmpeg 8.x + `h264_videotoolbox` | 런타임 후보 | tee muxer로 한 번 인코딩해 RTSP와 MP4에 동시 출력. Monterey Intel 실기 확인 대기 |
| 영상 엔진 | MediaMTX 1.21.1, darwin/amd64 | 버전 고정 | 공식 archive/checksum 설치 스크립트 작성. 동일 버전 Windows 바이너리로 최소 설정 기동 확인, Monterey 실행 대기 |
| HTTPS 게이트웨이 | Go 1.26.x, 표준 라이브러리만 사용 | 고정 | Go 1.27부터 macOS 13 이상이므로 Monterey 빌드는 1.26으로 제한. Windows 테스트와 darwin/amd64 교차 빌드 통과 |

`scripts/build-app.sh`는 위 고정을 빌드 전에 강제하고 검증을 마친 임시 앱 번들만 결과 경로로 승격한다. `scripts/diagnose.sh`는 설치된 FFmpeg의 VideoToolbox 실제 인코딩, 번들 아키텍처·서명, MediaMTX 1.21.1과 런타임 설정, 선택적 HTTPS 게이트웨이 TLS 구성을 실행 전에 검사한다.

## MediaMTX 채택 게이트

다음 조건을 대상 아이맥에서 모두 확인한 뒤 `통합 후보`를 `채택`으로 변경합니다.

1. `mediamtx_v1.21.1_darwin_amd64.tar.gz`와 공식 `checksums.sha256`를 GitHub 릴리스에서 내려받아 체크섬을 검증한다.
2. Monterey 12에서 바이너리가 시작되고 WebRTC 및 RTSP listener를 로컬 인터페이스에 열 수 있다.
3. H.264 720p/15fps 스트림을 장시간 받아 WebRTC로 재생할 때 CPU·메모리 증가가 안정적이다.
4. 관리 API와 원시 RTSP listener를 외부 인터페이스에 노출하지 않는 최소 설정을 확인한다.
5. 프로젝트가 번들/재배포하려는 방식과 MediaMTX MIT 라이선스 고지 방식을 확정한다.

빌드 시 검증된 MediaMTX 바이너리와 라이선스를 앱에 포함합니다. macOS에서 실행 결과를 확인하기 전까지 호환성 검증 완료로 표기하지 않습니다.

## 공식 자료

- Apple Xcode 요구사항: https://developer.apple.com/xcode/system-requirements/
- Apple 카메라 권한: https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media
- Apple 유휴 잠자기 assertion: https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep
- MediaMTX 설치: https://mediamtx.org/docs/kickoff/install
- MediaMTX 릴리스: https://github.com/bluenviron/mediamtx/releases/tag/v1.21.1
