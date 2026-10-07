# 대상 iMac 설치와 외부 접속 설정

## 1. 개발 도구

대상 Mac에서 다음을 준비합니다.

- macOS Monterey 12.5 이상
- Xcode 14.2 및 해당 Command Line Tools
- Go 1.26.x Intel용
- FFmpeg와 `h264_videotoolbox` 인코더

```bash
xcode-select -p
swift --version
go version
ffmpeg -hide_banner -encoders | grep h264_videotoolbox
```

빌드 스크립트는 Monterey 호환성을 위해 Go 1.26.x만 허용합니다. FFmpeg는 Homebrew를 사용할 경우 `brew install ffmpeg`로 설치할 수 있지만, Monterey에서 실제 bottle 또는 소스 빌드 가능 여부는 현장에서 확인해야 합니다.

## 2. 의존성 및 앱 빌드

```bash
cd "/path/to/mac monitor"
chmod +x scripts/*.sh
./scripts/fetch-mediamtx.sh
./scripts/build-app.sh
open dist/MacMonitor.app
```

`fetch-mediamtx.sh`는 GitHub의 MediaMTX 1.21.1 Intel archive와 공식 `checksums.sha256`를 HTTPS로 받아 일치할 때만 설치합니다.

앱 메뉴에서 `감시 시작`을 누르고 카메라 권한을 승인합니다. 우선 외부 HTTPS 없이 로컬 캡처, 움직임 감지, 인코딩 및 녹화가 동작하는지 확인합니다.

진단 로그:

```text
~/Library/Application Support/MacMonitor/Diagnostics/
```

`capture-probe.jsonl`, `ffmpeg.log`, `mediamtx.log`, `gateway.log`를 순서대로 확인합니다.

## 3. 앱 설정

메뉴 막대에서 `설정…`을 열어 다음 값을 저장합니다.

- 외부 WebRTC 호스트: 휴대폰에서 도달할 DDNS 도메인 또는 공인 IP. 스킴과 포트 없이 입력합니다.
- 비트레이트: 초기값 1200kbps.
- 움직임 임계값: 초기값 18 / 변화 비율 0.025.
- 보관 기간·최대 용량·최소 디스크 여유.
- 로그인 시 앱 실행 및 감시 시작 여부. 먼저 수동 실행해 카메라 권한을 승인한 뒤 켭니다.

설정은 다음 감시 시작부터 적용됩니다.

자동 실행을 켜면 `~/Library/LaunchAgents/local.macmonitor.app.plist`가 생성되고 다음 로그인부터 LaunchServices를 통해 현재 앱 경로를 엽니다. 앱을 다른 폴더로 옮긴 경우 기존 앱에서 자동 실행을 끈 뒤 새 위치의 앱에서 다시 켜 경로를 갱신합니다.

## 4. HTTPS 인증서와 소유자 비밀번호

휴대폰이 신뢰하는 도메인 인증서의 full chain과 개인 키를 Mac에 둡니다. 개인 키 파일 권한은 소유자만 읽도록 제한합니다. 인증서 발급 방식은 사용하는 DDNS 및 DNS 사업자에 맞춰 결정하며, 앱이 임의로 인증서를 발급하거나 공유기 설정을 변경하지 않습니다.

앱을 한 번 빌드한 후 다음을 실행합니다.

```bash
./scripts/configure-gateway.sh \
  "https://camera.example.net:8443" \
  "/absolute/path/fullchain.pem" \
  "/absolute/path/privkey.pem"
```

12자 이상의 소유자 비밀번호를 두 번 입력합니다. macOS 터미널에서는 `stty`로 입력 표시를 잠시 끄며 셸 명령 기록에도 들어가지 않습니다. 저장 파일에는 원문이 아니라 600,000회 PBKDF2-SHA256 해시만 기록됩니다.

생성 파일:

```text
~/Library/Application Support/MacMonitor/gateway.json
```

비밀번호나 인증서를 바꾼 뒤에는 감시를 중지했다가 다시 시작합니다.

## 5. 공유기 포트포워딩

권장 초기 매핑:

| 외부 | iMac 내부 | 용도 |
|---|---|---|
| TCP 8443 | TCP 8443 | HTTPS 웹, 인증, WebRTC 협상, 녹화 재생 |
| UDP 8189 | UDP 8189 | WebRTC ICE 미디어 |
| TCP 8189 | TCP 8189 | UDP가 차단된 환경의 ICE fallback |

다음 포트는 외부로 열지 않습니다.

- TCP 8554: 내부 RTSP 게시
- TCP 8889: MediaMTX WebRTC HTTP listener
- MediaMTX API, metrics, playback 포트

iMac의 내부 주소가 바뀌지 않도록 공유기의 DHCP 예약을 설정합니다. 포트포워딩은 사용자가 필요할 때 직접 열고 닫습니다.

## 6. 외부망 확인

Wi-Fi를 끈 휴대폰 데이터망에서 다음 순서로 확인합니다.

1. `https://camera.example.net:8443` 접속.
2. 잘못된 비밀번호가 거절되고 반복 실패가 제한되는지 확인.
3. 로그인 후 실시간 영상 재생.
4. 움직임을 만든 뒤 약 25초 후 녹화 목록 갱신 및 사건별 MP4 탐색 재생. 병합 실패 시에는 안전하게 남은 5초 원본 세그먼트가 표시됩니다.
5. 로그아웃 후 영상·녹화 URL이 401로 거절되는지 확인.
6. 이 전 과정에서 iMac 화면이 켜지거나 잠금이 풀리지 않는지 직접 관찰.

연결이 되지 않으면 공인 주소와 공유기 WAN 주소를 비교해 CGNAT/이중 NAT 여부부터 확인합니다. TCP 8443은 되지만 영상만 안 나오면 UDP/TCP 8189 전달, 앱 설정의 외부 WebRTC 호스트, 통신사 NAT를 순서대로 확인합니다. 이 프로젝트는 중계 서버를 사용하지 않으므로 포트포워딩 가능한 공인 주소가 직접 연결의 전제입니다.
