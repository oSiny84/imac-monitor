# 실제 iMac 검증 — 캡처·복구·녹화

이 절차는 첫 번째 위험 항목인 **화면 꺼짐·잠금 중 카메라 지속성**과 함께 자동 복구, 사건 녹화, 로그인 자동 시작까지 대상 Mac에서 판정합니다.

## 준비

1. iMac을 macOS Monterey 12.5 이상으로 업데이트하고 Xcode 14.2 Command Line Tools를 선택합니다.
2. `./scripts/build-app.sh`를 실행해 테스트와 앱 빌드를 마칩니다.
3. `open dist/MacMonitor.app`으로 실행하고 메뉴 막대에서 `감시 시작`을 누릅니다.
4. 카메라 권한을 승인하고 초록색 카메라 표시등이 켜지는지 확인합니다. 표시등은 정상이며 숨기지 않습니다.
5. 다음 명령에서 `PreventUserIdleSystemSleep` assertion의 소유자가 MacMonitor인지 기록합니다.

```bash
pmset -g assertions
```

## A. 디스플레이 꺼짐

1. 감시를 시작한 시각을 기록합니다.
2. 설정된 디스플레이 절전 시간이 지나 화면이 자연스럽게 꺼지게 둡니다. 키 입력이나 원격 명령으로 강제하지 않습니다.
3. 최소 2분 기다립니다.
4. 로컬 키보드 또는 마우스로 화면을 깨웁니다.
5. 로그 끝부분에 화면이 꺼져 있던 구간 동안 약 10초 간격의 `frame_heartbeat`가 이어졌는지 확인합니다.

```bash
tail -n 30 "$HOME/Library/Application Support/MacMonitor/Diagnostics/capture-probe.jsonl"
```

## B. 세션 잠금

1. 감시 실행 상태에서 Apple 메뉴의 화면 잠금을 사용합니다.
2. 디스플레이가 꺼진 뒤 최소 2분 기다립니다.
3. 로컬에서 잠금을 해제합니다.
4. 같은 로그에서 잠금 구간의 `timestamp`, `uptimeSeconds`, `totalFrames`가 중단 없이 증가했는지 확인합니다.

## C. 종료 복구

1. 메뉴에서 `감시 중지`를 선택합니다.
2. 카메라 표시등이 꺼지고 `capture_stopped`가 기록되는지 확인합니다.
3. `pmset -g assertions`에서 MacMonitor의 assertion이 사라졌는지 확인합니다.
4. 평소의 시스템 자동 잠자기와 디스플레이 절전이 다시 동작하는지 확인합니다.

## D. 비정상 종료 자동 복구

1. 감시 중 Activity Monitor에서 `mediamtx` 프로세스만 종료합니다.
2. 메뉴 상태가 `자동 복구 1/3`으로 바뀌고 약 2초 후 다시 `감시 중`이 되는지 확인합니다.
3. 한 번 더 종료해 5초 간격의 두 번째 복구를 확인합니다. 세 번째 간격은 15초이며 이후에도 계속 실패하면 오류 상태로 멈춰 무한 재시작하지 않아야 합니다.
4. 복구 대기 중 `감시 중지`를 눌러 예약된 재시작이 취소되는지 확인합니다.
5. 복구 예산이 세션 수명 상한이 아니라 플래핑 가드임을 확인합니다. 예산을 모두 소진해 오류 상태가 되기 전에, 복구 직후 상태로 5분 이상 연속 가동하고 다시 `mediamtx`를 종료합니다. 상태가 `자동 복구 1/3`부터 다시 시작해야 합니다. 2/3이나 3/3으로 올라가면 리셋이 동작하지 않는 것입니다.

## E. 사건별 녹화 파일

1. 감시 중 카메라 앞에서 5초 정도 움직인 뒤 정지합니다.
2. 마지막 움직임부터 약 30초 기다립니다. 병합은 마지막 움직임 기준 약 27초 뒤에 가능해지고, 보존 스캔이 2초 주기이므로 최대 약 29초까지 걸립니다.
3. `Recordings`에 `motion-*.mp4` 한 개가 생성되고 감지 전·후 구간까지 재생되는지 확인합니다.
4. 사후 구간이 끝까지 들어갔는지 확인합니다. `Recordings`에 사건에 속하지 못한 `segment-*.mp4`가 남아 있으면 안 됩니다. 병합이 꼬리 세그먼트보다 먼저 실행된 징후입니다.
5. 병합 오류가 발생했다면 `segment-*.mp4` 원본이 삭제되지 않고 모바일 목록에서 재생되는지 확인합니다.

## F. 로그인 자동 시작

1. 설정에서 `다음 로그인부터 앱 실행 및 감시 시작`을 켜고 저장합니다.
2. `~/Library/LaunchAgents/local.macmonitor.app.plist`가 생성됐는지 확인합니다.
3. 로그아웃 후 다시 로그인해 메뉴 막대 앱과 감시가 자동으로 시작되는지 확인합니다.
4. 앱 위치를 옮겼다면 자동 실행을 껐다가 새 위치의 앱에서 다시 켭니다.

## G. 인코딩 시간 드리프트

FFmpeg `rawvideo` 입력은 타임스탬프를 전달하지 못하므로 `-framerate 15`가 그대로 믿어집니다. 실제로 15fps가 들어가지 않으면 인코딩된 내용이 벽시계보다 짧아지고 오차가 누적됩니다. 녹화가 빠르게 재생되고, 세그먼트가 이름이 뜻하는 5초보다 긴 구간을 담아 보존 정책의 전후 구간 계산이 틀어지며, 실시간 영상이 점점 밀립니다. `ConstantRateFramePacer`가 이를 보정하는데, 실제 보정 여부는 이 절에서만 판정할 수 있습니다.

### G-1. 실제 캡처 프레임레이트

드리프트 압력이 존재하는지 먼저 확인합니다. 감시를 2분 이상 돌린 뒤 실행합니다.

```bash
grep frame_heartbeat "$HOME/Library/Application Support/MacMonitor/Diagnostics/capture-probe.jsonl" | tail -n 2 | awk '{ if (match($0, /"uptimeSeconds":[0-9.]+/)) { u = substr($0, RSTART+16, RLENGTH-16) } if (match($0, /"totalFrames":[0-9]+/)) { f = substr($0, RSTART+14, RLENGTH-14) } if (NR==1) { u0=u; f0=f } else { printf "capture %.2f fps over %.1f s\n", (f-f0)/(u-u0), u-u0 } }'
```

15에 가까우면 드리프트 압력이 없는 카메라입니다. 12~13이 나오면 보정 없이는 드리프트가 발생하는 조건이므로 G-2가 특히 중요합니다. 어느 쪽이든 측정값을 기록합니다.

### G-2. 세그먼트 벽시계 간격 (핵심 판정)

세그먼트 파일 이름은 ffmpeg가 그 파일을 연 실제 시각입니다. 내용 5초가 벽시계 5초에 만들어졌다면 연속한 이름의 간격이 5초입니다. 간격이 6초 이상이면 내용이 벽시계보다 느리게 쌓이는 것, 즉 드리프트입니다.

세그먼트는 움직임이 없으면 약 12초 후 삭제되므로 90초 동안 수집합니다. 감시 중에 실행합니다.

```bash
SPOOL="$HOME/Library/Application Support/MacMonitor/Spool"; for _ in $(seq 1 90); do ls "$SPOOL" 2>/dev/null; sleep 1; done | grep -o 'segment-[0-9]\{8\}T[0-9]\{6\}\.mp4' | sort -u | sed -e 's/^segment-//' -e 's/\.mp4$//' | awk '{ h=substr($0,10,2); mi=substr($0,12,2); s=substr($0,14,2); t=h*3600+mi*60+s; if (NR>1) print t-prev; prev=t }'
```

출력은 간격의 목록입니다. **모두 5가 나와야 합니다.** 6이나 7이 섞여 나오면 드리프트가 남아 있습니다. 자정을 넘기면 계산이 틀어지므로 그때는 다시 측정합니다.

### G-3. 병합 파일이 CFR 15fps인지

E절에서 만든 사건 파일 하나를 확인합니다.

```bash
ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=avg_frame_rate,nb_read_frames,duration -of default=noprint_wrappers=1 "$HOME/Library/Application Support/MacMonitor/Recordings/motion-"*.mp4
```

`avg_frame_rate`가 `15/1`이고 `nb_read_frames`가 `duration × 15`에 거의 일치해야 합니다. 크게 어긋나면 인코딩 단계에서 프레임레이트가 유지되지 않은 것입니다.

### G-4. 장시간 누적 확인

드리프트는 누적되는 성질이므로 짧은 측정으로는 놓칠 수 있습니다. 1시간 이상 연속 가동한 뒤 G-2를 다시 측정해 간격이 여전히 5초인지 확인합니다.

## 판정 기록

아래 항목과 실제 OS 빌드, iMac 모델 식별자, 카메라 이름을 함께 기록합니다.

- [ ] 화면 꺼짐 2분 동안 하트비트 지속
- [ ] 잠금 2분 동안 하트비트 지속
- [ ] 감시 중 디스플레이 자동 꺼짐 유지
- [ ] 감시 중 시스템 자동 유휴 잠자기 방지
- [ ] 감시 중지 후 assertion 해제
- [ ] 수동 시스템 잠자기 시 감시 중단(설계 범위와 일치)
- [ ] helper 종료 후 제한된 자동 복구
- [ ] 복구 대기 중 수동 중지 시 재시작 취소
- [ ] 5분 연속 가동 후 복구 예산이 1/3부터 다시 시작
- [ ] 움직임 세그먼트가 사건별 MP4로 병합되고 재생됨
- [ ] 사후 구간이 끝까지 포함되고 고아 `segment-*.mp4`가 남지 않음
- [ ] 실제 캡처 프레임레이트 측정값 기록 (G-1): ______ fps
- [ ] 세그먼트 벽시계 간격이 모두 5초 (G-2)
- [ ] 병합 파일이 CFR 15fps (G-3)
- [ ] 1시간 가동 후에도 간격이 5초 유지 (G-4)
- [ ] 로그인 후 앱과 감시 자동 시작

실패 시 로그 원본과 `pmset -g assertions` 출력을 보존하고 다음 구현 단계로 넘어가지 않습니다.
