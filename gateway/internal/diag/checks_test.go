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

func TestPowerLogLinesKeepSleepWakeAndDisplayLines(t *testing.T) {
	log := strings.Join([]string{
		"2026-11-26 18:30:00 +0900 Sleep               \tEntering Sleep state due to 'Software Sleep pid=123': Using AC (Charge:100%)",
		"2026-11-26 18:30:01 +0900 Assertions          \tPID 1 Created something",
		"2026-11-26 18:41:00 +0900 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to RTC/Maintenance",
		"2026-11-26 18:41:05 +0900 Notification        \tDisplay is turned on",
		"2026-11-26 18:41:30 +0900 Notification        \tDisplay is turned off",
		"2026-11-26 18:41:31 +0900 Kernel Client Acks  \tunrelated",
	}, "\n")
	lines := PowerLogLines([]byte(log), 40)
	if len(lines) != 4 {
		t.Fatalf("lines: %q", lines)
	}
	if lines[2] != "2026-11-26 18:41:05 +0900 Notification Display is turned on" {
		t.Fatalf("display line: %q", lines[2])
	}
	if last := PowerLogLines([]byte(log), 1); len(last) != 1 || !strings.HasSuffix(last[0], "turned off") {
		t.Fatalf("last one: %q", last)
	}
	if empty := PowerLogLines([]byte("nothing"), 40); len(empty) != 1 || !strings.Contains(empty[0], "없습니다") {
		t.Fatalf("empty: %q", empty)
	}
}

func TestIdleTimeReadsNanoseconds(t *testing.T) {
	lines := IdleTime([]byte(`    | |   "HIDIdleTime" = 12500000000`))
	if len(lines) != 1 || !strings.Contains(lines[0], "13s") && !strings.Contains(lines[0], "12s") {
		t.Fatalf("idle: %q", lines)
	}
	if missing := IdleTime([]byte("nothing")); !strings.Contains(missing[0], "찾지 못했습니다") {
		t.Fatalf("missing: %q", missing)
	}
}

func TestRunCheckRunsOnlyFixedCommandsAndHidesTokens(t *testing.T) {
	dir := t.TempDir()
	token := "1234567890:" + strings.Repeat("A", 35)
	if err := os.WriteFile(filepath.Join(dir, "gateway.log"), []byte("2026/11/26 18:41:00 telegram: failed "+token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var calls []string
	collector := &Collector{Dir: dir, Now: time.Now, Timeout: time.Second,
		Run: func(_ context.Context, name string, args ...string) ([]byte, error) {
			calls = append(calls, strings.Join(append([]string{name}, args...), " "))
			if name == "pmset" && len(args) == 2 && args[1] == "sched" {
				return nil, errors.New("pmset: boom")
			}
			return []byte("output " + token + "\n"), nil
		}}
	for _, check := range collector.Checks() {
		if check.ID == "" || check.Title == "" || check.Command == "" {
			t.Fatalf("incomplete check: %+v", check)
		}
	}

	output, err := collector.RunCheck(context.Background(), "gateway-log")
	if err != nil || strings.Contains(output, token) || !strings.Contains(output, "<token>") {
		t.Fatalf("gateway log: %q %v", output, err)
	}
	output, err = collector.RunCheck(context.Background(), "assertions")
	if err != nil || output != "output <token>" {
		t.Fatalf("assertions: %q %v", output, err)
	}
	if _, err := collector.RunCheck(context.Background(), "sched"); err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("failed command: %v", err)
	}
	if _, err := collector.RunCheck(context.Background(), "rm -rf /"); !errors.Is(err, ErrUnknownCheck) {
		t.Fatalf("unknown id: %v", err)
	}
	want := []string{"pmset -g assertions", "pmset -g sched"}
	if strings.Join(calls, "|") != strings.Join(want, "|") {
		t.Fatalf("commands run: %q", calls)
	}
}

func TestRunCheckReportsATimeout(t *testing.T) {
	collector := &Collector{Now: time.Now, Timeout: time.Second,
		Run: func(ctx context.Context, _ string, _ ...string) ([]byte, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		}}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := collector.RunCheck(ctx, "settings"); err == nil || !strings.Contains(err.Error(), "끝나지 않았습니다") {
		t.Fatalf("timeout: %v", err)
	}
}

func TestLimitLinesKeepsTheEnd(t *testing.T) {
	lines := make([]string, maxCheckLines+5)
	for index := range lines {
		lines[index] = "line"
	}
	lines[len(lines)-1] = "last"
	text := limitLines(lines)
	if !strings.HasPrefix(text, "(앞 5줄 생략)\n") || !strings.HasSuffix(text, "last") {
		t.Fatalf("limited: %q…", text[:40])
	}
	long := []string{strings.Repeat("x", maxCheckBytes), "tail"}
	if text := limitLines(long); text != "(앞부분 생략)\ntail" {
		t.Fatalf("long: %q", text[:40])
	}
}
