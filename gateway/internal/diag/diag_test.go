package diag

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Shapes copied from pmset, ps, system_profiler and log on macOS 12; values are made up.
const pmsetLog = `2026-11-09 10:15:58 +0900 Assertions          	PID 456(MacMonitor) Released PreventUserIdleSystemSleep "MacMonitor" 00:10:00  id:0x0x5000123 [System: PrevIdle DeclUser kDisp]
2026-11-09 10:16:02 +0900 Sleep               	Entering Sleep state due to 'Software Sleep pid=789':TCPKeepAlive=active Using AC (Charge:100%) 3 secs
2026-11-09 10:16:02 +0900 Wake Requests       	[*process=MacMonitor request=Wake deltaSecs=300 wakeAt=2026-11-09 10:21:02]
2026-11-09 10:21:01 +0900 DarkWake            	DarkWake from Deep Idle [CDNP] : due to RTC/Maintenance Using AC (Charge:100%) 25 secs
2026-11-09 10:21:26 +0900 WakeDetails         	DriverReason:AppleRTC - DriverDetails:
2026-11-09 11:08:00 +0900 Wake                	DarkWake to FullWake from Deep Idle [CDNP] : due to HID Activity Using AC
`

func TestSleepWakeEventsKeepTheTypesThatTellTheStory(t *testing.T) {
	events := SleepWakeEvents([]byte(pmsetLog), 12)
	expected := []string{
		"11-09 10:16:02 Sleep · Entering Sleep state due to 'Software Sleep pid=789':TCPKeepAlive=active 3 secs",
		"11-09 10:16:02 Wake Requests · [*process=MacMonitor request=Wake deltaSecs=300 wakeAt=2026-11-09 10:21:02]",
		"11-09 10:21:01 DarkWake · DarkWake from Deep Idle [CDNP] : due to RTC/Maintenance 25 secs",
		"11-09 11:08:00 Wake · DarkWake to FullWake from Deep Idle [CDNP] : due to HID Activity",
	}
	if strings.Join(events, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("events:\n%s", strings.Join(events, "\n"))
	}
	if last := SleepWakeEvents([]byte(pmsetLog), 2); len(last) != 2 || !strings.Contains(last[1], "11:08:00") {
		t.Fatalf("only the most recent events must be kept: %v", last)
	}
	if none := SleepWakeEvents(nil, 12); len(none) != 1 || !strings.Contains(none[0], "없습니다") {
		t.Fatalf("an empty log must say so: %v", none)
	}
}

func TestScheduleAssertionsCamerasAndDaemons(t *testing.T) {
	sched := ScheduledEvents([]byte("Scheduled power events:\n [0]  wake at 11/09/2026 10:21:02 by 'pmset'\n"))
	if len(sched) != 1 || sched[0] != "[0] wake at 11/09/2026 10:21:02 by 'pmset'" {
		t.Fatalf("schedule: %v", sched)
	}
	if empty := ScheduledEvents([]byte("")); !strings.Contains(empty[0], "없습니다") {
		t.Fatalf("no schedule must say so: %v", empty)
	}

	assertions := Assertions([]byte(`Assertion status system-wide:
   PreventSystemSleep             1
Listed by owning process:
   pid 345(sharingd): [0x0000a1b2c3d4e5f6] 00:10:00 PreventUserIdleSystemSleep named: "Handoff"
   pid 456(MacMonitor): [0x0000a1b2c3d4e5f7] 00:00:30 PreventSystemSleep named: "MacMonitor 슬림 모드 확인 창"
Kernel Assertions: 0x4=USB
`))
	if len(assertions) != 2 || assertions[1] != `MacMonitor · PreventSystemSleep · 00:00:30 · "MacMonitor 슬림 모드 확인 창"` {
		t.Fatalf("assertions: %v", assertions)
	}

	cameras := Cameras([]byte("Camera:\n\n    FaceTime HD Camera (Built-in):\n\n      Model ID: UVC Camera VendorID_1452 ProductID_34068\n      Unique ID: 0x1a11000005ac8600\n"))
	if len(cameras) != 1 || cameras[0] != "보임: FaceTime HD Camera (Built-in)" {
		t.Fatalf("cameras: %v", cameras)
	}
	if none := Cameras([]byte("")); !strings.Contains(none[0], "보지 못합니다") {
		t.Fatalf("no camera must say so: %v", none)
	}

	daemons := CameraDaemons([]byte("    1 01-02:03:04 /sbin/launchd\n  612    15:02 /System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Resources/VDC.plugin/Contents/Resources/VDCAssistant\n"))
	if len(daemons) != 1 || daemons[0] != "VDCAssistant · pid 612 · 실행 15:02" {
		t.Fatalf("daemons: %v", daemons)
	}
	uvc := CameraDaemons([]byte("  733    02:10 /System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Resources/UVCAssistant\n"))
	if len(uvc) != 1 || uvc[0] != "UVCAssistant · pid 733 · 실행 02:10" {
		t.Fatalf("macOS 12.3+ camera service: %v", uvc)
	}
	if none := CameraDaemons([]byte("    1 01-02:03:04 /sbin/launchd\n")); !strings.Contains(none[0], "없음") {
		t.Fatalf("no daemon must say so: %v", none)
	}
}

func TestCaptureSummaryShowsStartsThatNeverGotAFrame(t *testing.T) {
	now := time.Date(2026, 11, 9, 2, 28, 0, 0, time.UTC)
	log := strings.Join([]string{
		`{"timestamp":"2026-11-09T00:10:00Z","uptimeSeconds":1,"kind":"frame_heartbeat","totalFrames":900}`,
		`{"timestamp":"2026-11-09T02:08:00Z","uptimeSeconds":2,"kind":"capture_started","device":"FaceTime HD Camera (Built-in)","totalFrames":0}`,
		`{"timestamp":"2026-11-09T02:08:30Z","uptimeSeconds":3,"kind":"capture_stopped","totalFrames":0}`,
		`not json`,
		`{"timestamp":"2026-11-09T02:27:00Z","uptimeSeconds":4,"kind":"capture_started","device":"FaceTime HD Camera (Built-in)","totalFrames":0}`,
	}, "\n")
	lines := strings.Join(CaptureSummary([]byte(log), now, 2*time.Hour), "\n")
	for _, expected := range []string{
		"시작 2회 · 중지 1회 · 프레임 0개로 끝난 시작 1회",
		"마지막 시작 02:27:00 (1분 전) · FaceTime HD Camera (Built-in)",
		"마지막 중지 02:08:30 (19분 전) · 그동안 프레임 0개",
		"마지막 시작 뒤 프레임이 한 번도 오지 않았습니다 · 마지막 프레임 11-09 00:10:00",
	} {
		if !strings.Contains(lines, expected) {
			t.Fatalf("summary lacks %q:\n%s", expected, lines)
		}
	}

	healthy := `{"timestamp":"2026-11-09T02:27:00Z","kind":"capture_started","device":"Cam"}` + "\n" +
		`{"timestamp":"2026-11-09T02:27:50Z","kind":"frame_heartbeat","totalFrames":700}`
	if lines := strings.Join(CaptureSummary([]byte(healthy), now, 2*time.Hour), "\n"); !strings.Contains(lines, "마지막 프레임 02:27:50 (방금)") {
		t.Fatalf("a healthy start must show the latest frame:\n%s", lines)
	}
	if lines := CaptureSummary(nil, now, 2*time.Hour); !strings.Contains(lines[0], "켠 적이 없습니다") {
		t.Fatalf("an idle camera must say so: %v", lines)
	}

	short := `{"timestamp":"2026-11-09T02:20:00Z","kind":"capture_started","device":"Cam"}` + "\n" +
		`{"timestamp":"2026-11-09T02:20:08Z","kind":"capture_stopped","totalFrames":150}`
	if lines := strings.Join(CaptureSummary([]byte(short), now, 2*time.Hour), "\n"); !strings.Contains(lines, "프레임이 왔습니다") || strings.Contains(lines, "한 번도") {
		t.Fatalf("a capture shorter than the heartbeat interval still got frames:\n%s", lines)
	}

	justStarted := `{"timestamp":"2026-11-09T02:27:55Z","kind":"capture_started","device":"Cam"}`
	if lines := strings.Join(CaptureSummary([]byte(justStarted), now, 2*time.Hour), "\n"); !strings.Contains(lines, "확인하는 중") {
		t.Fatalf("a start five seconds ago has no heartbeat yet:\n%s", lines)
	}

	longRunning := `{"timestamp":"2026-11-08T23:00:00Z","kind":"capture_started","device":"Cam"}` + "\n" +
		`{"timestamp":"2026-11-09T02:27:58Z","kind":"frame_heartbeat","totalFrames":90000}`
	lines = strings.Join(CaptureSummary([]byte(longRunning), now, 2*time.Hour), "\n")
	if strings.Contains(lines, "켠 적이 없습니다") || !strings.Contains(lines, "지금 켜져 있음") || !strings.Contains(lines, "마지막 프레임 02:27:58") {
		t.Fatalf("a capture running longer than the window must show as running:\n%s", lines)
	}
}

func TestGatewaySummaryListsRestartsAndBotErrors(t *testing.T) {
	log := strings.Join([]string{
		"2026/11/09 10:21:05 MacMonitor gateway listening on :8443",
		"2026/11/09 10:21:05 telegram: bot started for chat 42",
		"2026/11/09 10:21:06 telegram: telegram getUpdates: dial tcp: lookup api.telegram.org: no such host",
		"2026/11/09 10:30:00 telegram: viewing request ended, nobody opened the link",
		"2026/11/09 10:30:01 telegram: ignored a message from chat 7",
		"2026/11/09 10:31:00 telegram: bot stopped",
		"2026/11/09 11:08:02 MacMonitor gateway listening on :8443",
	}, "\r\n")
	lines := GatewaySummary([]byte(log))
	expected := []string{"시작: 11/09 10:21:05, 11/09 11:08:02", "텔레그램 오류:", "11/09 10:21:06 telegram getUpdates: dial tcp: lookup api.telegram.org: no such host"}
	if strings.Join(lines, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("gateway summary:\n%s", strings.Join(lines, "\n"))
	}
}

func TestAppLogLinesKeepTimeAndMessage(t *testing.T) {
	output := "Timestamp               Ty Process[PID:TID]\n" +
		"2026-11-09 10:16:01.512 Df MacMonitor[456:9a1b] MacMonitor slim: requesting sleep (pmset sleepnow)\n" +
		"2026-11-09 10:16:02.001 Df MacMonitor[456:9a1b] (CoreFoundation) MacMonitor slim: wake scheduled for 11/09/26 10:21:02\n" +
		"2026-11-09 10:16:03.001 E  MacMonitor[456:9a1b] (Foundation) [com.example:app] MacMonitor: wake scheduling failed: sudo: a password is required\n"
	lines := AppLogLines([]byte(output), 2)
	expected := []string{"11-09 10:16:02 slim: wake scheduled for 11/09/26 10:21:02", "11-09 10:16:03 wake scheduling failed: sudo: a password is required"}
	if strings.Join(lines, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("app log:\n%s", strings.Join(lines, "\n"))
	}
}

func TestReportRunsOnlyFixedCommandsAndSurvivesFailures(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "gateway.log"), []byte("2026/11/09 11:08:02 MacMonitor gateway listening on :8443\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	collector := &Collector{
		Dir: directory,
		Now: func() time.Time { return time.Date(2026, 11, 9, 2, 28, 0, 0, time.UTC) },
		Run: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			switch name {
			case "pmset":
				if args[1] == "log" {
					return []byte(pmsetLog), nil
				}
				return nil, errors.New("pmset: boom")
			case "log":
				<-ctx.Done() // a log show that never finishes
				return nil, ctx.Err()
			}
			return []byte(""), nil
		},
		Timeout: 50 * time.Millisecond,
	}
	report := collector.Report(context.Background())
	for _, expected := range []string{
		"[잠자기·깨어남 (pmset 로그, 최근 12건)]\n11-09 10:16:02 Sleep",
		"[깨우기 예약]\npmset 실패: pmset: boom",
		"[앱 카메라 기록 (최근 2시간)]\n카메라 기록을 읽지 못했습니다",
		"[게이트웨이 기록]\n시작: 11/09 11:08:02",
		"[앱 로그 (최근 1시간, 마지막 12줄)]\nlog: 1초 안에 끝나지 않았습니다",
	} {
		if !strings.Contains(report, expected) {
			t.Fatalf("report lacks %q:\n%s", expected, report)
		}
	}
}
