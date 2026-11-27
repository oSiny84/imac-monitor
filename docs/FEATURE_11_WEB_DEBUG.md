# 기능 11: 웹 진단 탭과 백그라운드 시청 유지

2026-11-27 사용자의 요청으로 추가했습니다. Windows에서 Go 테스트, Node 화면 검사, 데스크톱 브라우저 미리보기(가짜 진단 결과)로 확인했습니다. Mac에서 실제 명령이 도는지와 휴대폰 브라우저의 백그라운드 동작은 아래 §4에서 확인해야 합니다.

## 1. 웹 진단 탭

원격에서는 Mac 터미널을 열 수 없어, 웹 화면의 `진단` 탭에서 정해 둔 확인 명령을 실행하고 결과를 봅니다. 읽기만 하고 아무것도 바꾸지 않습니다. 브라우저는 항목의 ID만 보내고, 명령과 인자는 게이트웨이에 고정돼 있습니다(`gateway/internal/diag/checks.go`).

| 버튼 | 같은 터미널 명령 |
| --- | --- |
| 잠자기·깨어남·화면 켜짐/꺼짐 (최근 40건) | `pmset -g log` 중 Sleep·Wake·DarkWake·`Display is turned` 줄 |
| 앱 로그 (최근 3시간, 마지막 80줄) | `log show --last 3h --style compact --predicate 'process == "MacMonitor" AND eventMessage BEGINSWITH "MacMonitor"'` |
| 게이트웨이 기록 (마지막 80줄) | `tail -80 …/Diagnostics/gateway.log` |
| 잠을 막는 요청 | `pmset -g assertions` |
| 깨우기 예약 | `pmset -g sched` |
| 전원 설정 | `pmset -g` |
| 지금 전원 상태 | `pmset -g systemstate` |
| 마지막 키보드·마우스 입력 뒤 지난 시간 | `ioreg -c IOHIDSystem -d 4`의 `HIDIdleTime` |
| 전체 요약 | 텔레그램 `진단`과 같은 보고서 |

- 로그인과 CSRF 토큰이 필요합니다(`GET /api/diag/checks`, `POST /api/diag/run?id=…`).
- 한 번에 하나만 실행합니다. 실행 중에 다른 버튼을 누르면 "다른 진단이 실행 중입니다"(409)로 거절합니다.
- 결과는 400줄·96 KB까지 보여 주고, 넘치면 앞부분을 생략합니다. 텔레그램 봇 토큰 모양의 글자는 `<token>`으로 가립니다.
- 항목마다 시간 제한이 있습니다(앱 로그 90초, 전체 요약 60초, 나머지 40초 이하).

## 2. 백그라운드에서도 시청 유지

이전에는 브라우저 창을 최소화하거나 다른 탭으로 옮기면 영상 연결을 끊고 시청 요청도 멈춰, 약 20초 뒤 카메라가 꺼졌습니다. 사용자 요청으로 바꿨습니다.

- 창을 최소화하거나 다른 탭·`진단` 탭으로 옮겨도 영상 연결과 5초마다의 시청 요청을 유지합니다.
- 카메라가 꺼지는 경우: 이 탭을 닫을 때, `녹화` 탭으로 옮길 때, 로그아웃할 때, Safari 뒤로가기 등으로 페이지를 떠날 때(돌아오면 다시 연결).
- Chrome은 몇 분 이상 숨겨진 페이지의 타이머를 1분에 한 번으로 늦춥니다. 시청 요청이 20초 제한을 넘기지 않도록 5초 간격은 전용 Worker(`assets/ticker.js`)의 타이머로 셉니다. Worker를 못 쓰는 브라우저에서는 일반 타이머로 돌아갑니다.
- 숨겨 둔 탭을 잊으면 카메라와 휴대폰 데이터가 계속 쓰입니다. 시간 상한은 두지 않았습니다(사용자 결정).

## 3. 바꾼 파일

- `gateway/internal/diag/checks.go`(새 파일), `checks_test.go`
- `gateway/internal/server/server.go`: `SetDiagnostics`, `GET /api/diag/checks`, `POST /api/diag/run`. 테스트 `diag_test.go`
- `gateway/cmd/macmonitor-gateway/main.go`: 진단 수집기 연결
- `gateway/internal/server/web/index.html`, `assets/app.js`, `assets/styles.css`, `assets/ticker.js`(새 파일): 진단 탭, 백그라운드 시청 요청
- `gateway/internal/server/web/assets/live-player.js`: 숨겨져도 연결을 끊지 않음
- `scripts/test-web-archive.js`, `scripts/test-live-player.js`: 새 동작 검사. `test-web-archive.js`는 2026-11-23 누르고 말하기 추가 뒤 화면 요소가 빠져 모든 검사가 실패하던 것을 함께 고쳤습니다.

## 4. Mac과 휴대폰에서 확인할 것

1. `진단` 탭의 각 버튼이 Mac에서 결과를 보여 주는지. 특히 앱 로그(`log show`)가 90초 안에 끝나는지.
2. `마지막 키보드·마우스 입력 뒤 지난 시간`이 Mac을 만지지 않는 동안 늘어나는지.
3. PC 브라우저 창을 최소화한 채 10분 넘게 두었다가 열었을 때 영상이 끊기지 않았는지, Mac의 초록 표시등이 계속 켜져 있었는지.
4. 휴대폰 브라우저를 홈 화면으로 보냈다 돌아왔을 때의 동작. iPhone Safari는 페이지 자체를 멈출 수 있어 끊길 수 있습니다.
