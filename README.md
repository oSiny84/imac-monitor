# MacMonitor

2015 Intel iMac과 macOS 12 Monterey를 대상으로 하는 개인용 CCTV입니다. 메뉴 막대 앱이 카메라를 소유하고, 하나의 H.264 인코딩 결과를 로컬 움직임 녹화와 MediaMTX WebRTC에 함께 사용합니다.

## 구현된 수직 경로

```text
AVFoundation 720p/15fps
  ├─ 저해상도 luma 움직임 분석
  └─ FFmpeg h264_videotoolbox 단일 인코딩
       ├─ 5초 MP4 spool → 감지 전 5초/후 15초 선택 → 사건별 MP4 병합
       └─ loopback RTSP → MediaMTX → WebRTC

휴대폰 HTTPS
  → Go 인증 게이트웨이
      ├─ 로그인/세션/CSRF/시도 제한
      ├─ 인증된 MediaMTX WebRTC 프록시
      └─ 인증된 녹화 목록/Range 재생
```

구현 항목:

- macOS 12용 메뉴 막대 앱과 설정 창
- 사용자 선택형 LaunchAgent 로그인 자동 실행 및 감시 시작
- 카메라 권한·장치 선택, 720p/15fps NV12 캡처, 프레임 하트비트
- 화면 절전은 허용하고 시스템 자동 유휴 잠자기만 방지
- 전역 밝기 변화를 보정한 움직임 감지
- VideoToolbox H.264 단일 인코딩과 RTSP/MP4 tee
- 감지 전 5초·감지 후 15초 보존과 사건별 MP4 무재인코딩 병합(실패 시 원본 세그먼트 보존)
- 기간·용량·최소 여유 공간 보관 정책
- 진단 로그별 10MB 제한과 최근 3세대 자동 회전
- MediaMTX의 RTSP/HTTP listener를 loopback으로 제한
- 고정 UDP/TCP 8189 WebRTC ICE 포트
- PBKDF2-SHA256 비밀번호, Secure/HttpOnly/SameSite 세션, CSRF 및 로그인 제한
- HTTPS 뒤의 모바일 실시간 화면과 녹화 재생 화면
- 카메라 세션·FFmpeg·MediaMTX·HTTPS 게이트웨이 비정상 종료 감지, 2/5/15초 간격의 최대 3회 자동 복구 및 안전한 감시 종료
- 공식 체크섬을 검증하는 MediaMTX 설치 스크립트
- Swift 상태/움직임/보관 테스트와 Go 게이트웨이 테스트

## Mac에서 준비하고 실행

전체 순서는 [docs/SETUP_MAC.md](docs/SETUP_MAC.md)에 있습니다. 요약하면 다음과 같습니다.

```bash
chmod +x scripts/*.sh
./scripts/fetch-mediamtx.sh
./scripts/build-app.sh
open dist/MacMonitor.app
```

빌드에는 Xcode 14.2, Go 1.26.x, FFmpeg가 필요합니다. 빌드 스크립트는 Swift와 Go 테스트를 먼저 실행하고 Intel `x86_64` 앱을 만든 뒤 내부 helper까지 ad-hoc 서명합니다.

첫 실행 후 메뉴 막대의 `설정…`에서 외부 WebRTC 호스트와 움직임·보관 값을 저장하고 `감시 시작`을 선택합니다. 카메라 권한은 사용자가 직접 승인해야 합니다.

## 애플리케이션 데이터

```text
~/Library/Application Support/MacMonitor/
├── config.json
├── gateway.json
├── Diagnostics/
├── Recordings/
├── Runtime/
└── Spool/
```

앱은 `Spool`과 `Recordings`만 보관 정책에 따라 정리합니다. 다른 디렉터리는 삭제 대상으로 삼지 않습니다.

## 아직 실제 Mac 검증이 필요한 항목

이 Windows 환경에서는 Swift/macOS 프레임워크를 컴파일하거나 카메라·VideoToolbox·전원 동작을 실행할 수 없습니다. MediaMTX 1.21.1 설정 기동, Go 테스트 및 macOS/amd64 교차 빌드는 여기서 확인했지만 아래 항목은 대상 iMac에서 판정해야 합니다.

- Swift 패키지의 Xcode 14.2 컴파일
- 카메라 권한과 실제 720p/15fps 포맷
- `h264_videotoolbox` 인코더 및 FFmpeg tee 동작
- 화면 꺼짐·잠금 상태의 프레임/녹화 지속
- 휴대폰 데이터망 WebRTC와 공유기 NAT 후보
- TLS 인증서, DDNS, 포트포워딩
- 장시간 CPU·메모리·발열·디스크 사용
- 인코딩된 내용 길이가 벽시계 시간과 일치하는지 (세그먼트 간격 5초 유지)

검증 절차는 [docs/MAC_VALIDATION.md](docs/MAC_VALIDATION.md), 네트워크 경계는 [docs/NETWORK_SECURITY.md](docs/NETWORK_SECURITY.md)를 따릅니다. 2026-10-07 신뢰성 수정의 변경 내용과 미검증 범위는 [docs/RELIABILITY_FIXES.md](docs/RELIABILITY_FIXES.md)에 있습니다.
