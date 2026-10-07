# 신뢰성 수정 기록 — 복구 예산·사후 구간 병합·인코딩 시간 드리프트

2026-10-07 코드 검토에서 찾은 세 가지 결함을 수정했다. 이어받는 작업자를 위한 인수인계 기록이다.

## 검증 상태를 먼저 읽을 것

수정 작업은 Windows에서 했고 그 환경에는 **Swift 툴체인도 ffmpeg 바이너리도 없다.** 아래 변경은
컴파일하지 않았고 `swift test`도 실행하지 않았다. 통과로 간주하지 말 것.

- 확인한 것: 변경한 파일의 괄호 균형, 모든 호출 지점의 일관성, 두 타이밍 식의 Go 수치 시뮬레이션.
- 확인하지 못한 것: Swift 컴파일, 실제 카메라와 VideoToolbox 동작, 실기에서의 드리프트.
- 다음 게이트: 대상 iMac에서 `swift test`, 그리고 `docs/MAC_VALIDATION.md`의 D·E·G 절.

## 1. 자동 복구 예산이 평생 누적되어 리셋되지 않았다

**증상.** 장기 무인 가동 중 산발적 장애가 누적되면 단 한 번의 일시 장애로도 감시가 영구 정지한다.
사용자가 직접 재시작할 때까지 복구하지 않는다.

**원인.** `MonitoringCoordinator`의 `recoveryAttempt`를 0으로 돌리는 곳이 수동 `start()`뿐이었다.
`.running` 진입 시에는 리셋하지 않으므로 `recoveryDelays.count`(3)가 세션 수명 전체의 상한이 되었다.
한 번 복구하고 몇 주 정상 동작한 뒤 다시 실패하면 남은 시도는 2회뿐이다.

**수정.** `recoveryResetInterval`(기본 300초) 초기화 인자를 추가하고, `.running`에 도달하면
`scheduleRecoveryBudgetReset(generation:)`이 작업 항목을 예약한다. 그 시간만큼 연속 가동이 유지되면
`recoveryAttempt`를 0으로 되돌린다.

- 기존 복구 로직과 같은 generation 가드를 쓴다. 중간에 상태가 바뀌면 되살아나지 않는다.
- `start`, `stop`, 런타임 실패, 복구 예약 네 경로에서 모두 취소한다.
- `recoveryAttempt`가 0일 때는 예약하지 않는다. 되돌릴 것이 없다.

**동작 변화.** 상한의 의미가 세션 수명 상한에서 플래핑 가드로 바뀐다. 짧은 간격의 연속 실패는
여전히 예산을 소진하고 `.failed`로 올라간다.

## 2. 사후 구간 마지막 세그먼트가 병합에서 빠졌다

**증상.** `motion-*.mp4` 사건 파일의 사후 구간이 최대 5초 짧다. 빠진 세그먼트는 뒤늦게
`recordings`로 옮겨진 뒤 어느 사건에도 속하지 못한 `segment-*.mp4` 고아 파일로 목록에 남는다.

**원인.** `RecordingRetentionManager`의 두 시점이 어긋났다.

| 시점 | 기존 식 | 5초/5초/15초 기본값 |
|---|---|---|
| 세그먼트 승격 | `segmentStart + segmentDuration + preRoll + 2` | `start + 12초` |
| 사건 병합 | `window.end + segmentDuration + 2` | `window.end + 7초` |

겹침 조건이 `file.start < window.end`이므로 `window.end`를 품은 마지막 세그먼트의 `start`는
`(window.end - 5, window.end]` 구간에 있다. 그 승격 시점은 `window.end + 7`보다 **항상** 늦다.
따라서 병합은 그 세그먼트가 아직 spool에 있는 상태에서 실행되고, 병합 성공 후 윈도를 제거하므로
그 세그먼트는 다시 병합될 기회를 잃는다.

**수정.** 승격 시점을 `promotionDecisionTime(segmentStart:)` 한 함수로 뽑고, 병합 게이트가
`promotionDecisionTime(segmentStart: window.end)`를 쓰게 했다. 겹치는 모든 세그먼트의 승격 시점이
이 값보다 엄격히 이르므로 필요한 세그먼트가 전부 도착한 뒤에만 병합한다. 두 시점이 다시 어긋날 수 없다.

`scan`은 `now`를 주입받도록 바꿨고, 시간 게이트를 테스트에서 돌리기 위한 `runMaintenance(now:)`를 추가했다.

**수치 근거.** 5초 그리드에 대해 모션 타이밍 50개를 쓸어본 결과다.

| 게이트 | 필요한 세그먼트가 아직 spool에 있는 채 병합한 횟수 |
|---|---|
| 기존 | 50개 중 40개 (최대 3.0초 모자람) |
| 수정 후 | 50개 중 0개 |

희귀 경계 조건이 아니라 임의 모션 타이밍의 80%에서 발생했다. 그리드에 정확히 정렬된 경우만 우연히 무사했다.

**동작 변화 — 검증 절차에 영향.** 사건 파일 생성이 마지막 움직임 기준 약 22초 뒤에서 **약 27초 뒤**로
늦어진다. 보존 스캔 타이머가 2초 주기이므로 실제로는 최대 약 29초다. `docs/MAC_VALIDATION.md` E절의
대기 시간을 25초에서 30초로 함께 고쳤다. 기존 25초로 측정하면 정상 동작도 실패로 보인다.

## 3. 고정 15fps 가정으로 인코딩 시간이 드리프트했다

**증상.** 녹화가 실제보다 빠르게 재생된다. 세그먼트 파일이 이름이 뜻하는 5초보다 긴 벽시계 구간을
담으므로 보존 정책의 전후 구간 계산이 계속 틀어진다. 실시간 영상은 점점 뒤로 밀린다.

**원인.** FFmpeg `rawvideo` 파이프는 타임스탬프를 전달하지 못한다. FFmpeg는 읽은 모든 프레임을 정확히
`1/15`초 간격으로 배치한다. 캡처된 프레임마다 한 번 쓰는 구조에서는 카메라가 명목 속도에 못 미치거나
`pendingFrames < 2` 백프레셔가 프레임을 버릴 때마다 내용이 벽시계보다 짧아지고, 그 오차가 누적된다.

**수정 방향 선택.** 고치는 길은 두 가지뿐이다. FFmpeg에 실제 도착 시각을 알려주거나
(`-use_wallclock_as_timestamps` + CFR 변환), 아니면 가정을 사실로 만드는 것이다. 작업 환경에 ffmpeg가
없어 플래그 동작을 실험할 수 없었고, 검증 못 한 의미론에 기대면 이미 스모크 테스트를 통과한
`tee` + `segment` 호출이 조용히 깨질 위험이 있다. **그래서 두 번째 길을 택했다. FFmpeg 인자는 바꾸지 않았다.**

**수정.** 새 타입 `ConstantRateFramePacer`가 "지금 몇 프레임을 써야 하는가"를 시계에서만 계산한다.
카메라가 몇 장을 줬는지는 식에 들어가지 않으므로 오차가 누적될 수 없다. `FFmpegPipeline`의 프레임 경로를
다시 짰다.

- `consume`은 NV12 복사 후 최신 프레임을 넘기기만 한다. 캡처 스레드에서 블로킹 쓰기가 사라졌다.
- 파이프는 `writerQueue`의 15fps `DispatchSourceTimer`가 소유하고, 매 틱마다 pacer가 요구하는 수만큼 쓴다.
- 늦게 온 프레임은 타임라인에 구멍을 남기는 대신 직전 프레임을 반복한다. 동일 프레임은 H.264에서
  거의 비트를 쓰지 않아 대역폭 부담이 없다.
- 쓰기 대기열이 2초 넘게 막히면 밀린 빚을 메우지 않고 기준선을 재동기화한다. 그 구간에는 애초에
  프레임이 없었으므로 수백 장을 복제하는 것보다 정직한 불연속이 낫다.
- `pendingFrames` 백프레셔는 제거했다. 프레임당 큐 적재가 없어져 구조적으로 불필요해졌다.

**수치 근거.** pacer 산술을 그대로 옮겨 10분 구간을 시뮬레이션했다. 내용 길이가 벽시계를 따라가는지가 지표다.

| 시나리오 | 기존 드리프트 | 수정 후 드리프트 |
|---|---|---|
| 카메라 정상 15fps | +0.9초 | 0.0초 |
| 카메라 12fps로 저하 | −119.1초 | 0.0초 |
| 15fps, 부하로 10% 드롭 | −57.1초 | 0.0초 |
| 12fps + 30초 완전 정지 | −143.1초 | −30.0초 (정지 구간 그대로) |

최대 버스트는 네 시나리오 모두 2프레임, 재동기화는 실제 정지가 있던 경우에만 1회였다. 12fps 사례에서
기존 코드는 600초를 481초 분량으로 인코딩했다. 녹화가 1.25배로 빨리 재생되는 상태다.

## 변경 파일

| 파일 | 내용 |
|---|---|
| `Sources/MacMonitorCore/MonitoringCoordinator.swift` | 1번. 복구 예산 리셋 |
| `Sources/MacMonitorCore/RecordingRetentionManager.swift` | 2번. 승격·병합 게이트 통합, `scan(now:)` |
| `Sources/MacMonitorCore/ConstantRateFramePacer.swift` | 3번. 신규 |
| `Sources/MacMonitorCore/FFmpegPipeline.swift` | 3번. 시계 기반 쓰기, `pendingFrames` 제거 |
| `Tests/.../MonitoringCoordinatorTests.swift` | 1번 테스트 2개 추가 |
| `Tests/.../RecordingRetentionManagerTests.swift` | 2번 테스트 1개 추가, 스텁에 호출 기록 추가 |
| `Tests/.../ConstantRateFramePacerTests.swift` | 3번 테스트 7개. 신규 |
| `docs/MAC_VALIDATION.md` | D절 보강, E절 대기 25→30초, G절 신규 |

`Package.swift`는 소스를 글롭하므로 새 파일 추가에 수정이 필요 없다. 공개 API와
`MonitoringPipelineControlling` 요구 시그니처는 바뀌지 않았다.

## 핵심 회귀 테스트

기존 보존 테스트 3개는 모두 `stopAndFinalize()` 경로여서 시간 게이트를 우회했고 2번 결함을 잡지 못했다.
새로 추가한 것은 다음 세 개다.

- `testTimedMergeWaitsForTheSegmentHoldingTheEndOfThePostRoll` — 2단계로 검증한다. `base+25`에서는
  병합이 아직 없고 꼬리 세그먼트가 spool에 남아야 하며, `base+30`에서 5개 전부가 한 번에 병합되고
  고아가 없어야 한다. 기존 코드에서는 1단계가 실패한다.
- `testRecoveryBudgetIsRestoredAfterASustainedRun` — 예산 1회 구성에서 연속 가동 후 재실패도 복구되는지.
- `testEmittedContentTracksWallClockWhenTheCameraRunsBelowItsNominalRate` — 느린 카메라 주기로만
  폴링하는 최악 조건에서 내용 길이가 벽시계를 따라가는지.

pacer 테스트는 프레임 경계의 부동소수점 반올림에 의존하지 않도록 폴링 시각을 경계에서 1ms 비켜 두었다.

## 손대지 않은 기존 지적 사항

검토에서 함께 보고했으나 수정하지 않았다. 판단은 이어받는 쪽에 맡긴다.

- `LocalMonitoringPipeline.consume`이 `started`만 잠금으로 읽고 `detector`/`encoder`/`retention`은
  잠금 밖에서 접근한다. 옵셔널이라 nil 역참조는 안전하지만 Swift 클래스 참조의 교차 스레드 접근은
  원자성이 보장되지 않는다.
- `RecordingRetentionManager`의 디스크 여유 공간 계산이 `.systemFreeSize`를 쓴다. APFS에서는
  `volumeAvailableCapacityForImportantUsage`가 더 정확하다.
- 게이트웨이 `WriteTimeout: 0`은 스트리밍과 Range 재생을 위한 의도된 설정이지만 쓰기측
  slow-loris에 노출된다. 개인용 범위에서는 수용 가능하다.
- MediaMTX 설정 키(`moq`, `rtspTransports`, `webrtcLocalUDPAddress`)는 버전에 민감하다.
  1.21.1 기동 테스트로 고정 확인이 필요하다.
