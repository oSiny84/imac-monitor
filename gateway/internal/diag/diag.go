// Package diag collects what the owner would otherwise have to type into Terminal on a Mac
// whose display is off: the sleep/wake history, the scheduled wakes, what holds the Mac
// awake, whether macOS still sees the camera, and the app's own camera and gateway logs.
// It only runs fixed, read-only commands with fixed arguments; nothing from the chat reaches
// a command line.
package diag

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Collector gathers one report. Production defaults come from New; tests replace Run and Now.
type Collector struct {
	// The app's Diagnostics directory (capture-probe.jsonl, gateway.log).
	Dir string
	// Runs one fixed command and returns its standard output.
	Run func(ctx context.Context, name string, args ...string) ([]byte, error)
	Now func() time.Time
	// Each section gets this long; the sections run at the same time.
	Timeout time.Duration
}

func New(dir string) *Collector {
	return &Collector{Dir: dir, Run: runCommand, Now: time.Now, Timeout: 40 * time.Second}
}

// DefaultDir is where the app keeps its diagnostics: the gateway runs as the same user.
func DefaultDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "MacMonitor", "Diagnostics")
}

type section struct {
	title string
	run   func(ctx context.Context) []string
}

// Report returns the sections as text, in a fixed order, each headed by its title.
func (c *Collector) Report(ctx context.Context) string {
	sections := []section{
		{"잠자기·깨어남 (pmset 로그, 최근 12건)", c.sleepWake},
		{"깨우기 예약", c.schedule},
		{"잠을 막는 요청", c.assertions},
		{"카메라 장치", c.cameras},
		{"카메라 서비스 프로세스", c.cameraDaemons},
		{"앱 카메라 기록 (최근 2시간)", c.captureProbe},
		{"게이트웨이 기록", c.gatewayLog},
		{"앱 로그 (최근 1시간, 마지막 12줄)", c.appLog},
	}
	results := make([][]string, len(sections))
	var wait sync.WaitGroup
	for index, item := range sections {
		wait.Add(1)
		go func() {
			defer wait.Done()
			sectionCtx, cancel := context.WithTimeout(ctx, c.Timeout)
			defer cancel()
			results[index] = item.run(sectionCtx)
		}()
	}
	wait.Wait()
	var out strings.Builder
	for index, item := range sections {
		if index > 0 {
			out.WriteString("\n")
		}
		out.WriteString("[" + item.title + "]\n")
		lines := results[index]
		if len(lines) == 0 {
			lines = []string{"(내용 없음)"}
		}
		for _, line := range lines {
			out.WriteString(line + "\n")
		}
	}
	return strings.TrimRight(out.String(), "\n")
}

func (c *Collector) command(ctx context.Context, name string, args ...string) ([]byte, []string) {
	output, err := c.Run(ctx, name, args...)
	if err != nil {
		if ctx.Err() != nil {
			seconds := int((c.Timeout + time.Second - 1) / time.Second)
			return nil, []string{fmt.Sprintf("%s: %d초 안에 끝나지 않았습니다", name, seconds)}
		}
		return nil, []string{name + " 실패: " + cut(err.Error(), 160)}
	}
	return output, nil
}

// pmset -g log lines look like
// "2026-11-09 10:21:01 +0900 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to RTC/Maintenance Using AC (Charge:100%) 25 secs".
var pmsetEvent = regexp.MustCompile(`^\d{4}-(\d\d-\d\d \d\d:\d\d:\d\d) [+-]\d{4} (Sleep|DarkWake|Wake Requests|Wake)\s+(.*)$`)
var pmsetPower = regexp.MustCompile(`\s*Using (AC|BATT|Batt)( \(Charge: ?\d+%\))?`)

func (c *Collector) sleepWake(ctx context.Context) []string {
	output, failure := c.command(ctx, "pmset", "-g", "log")
	if failure != nil {
		return failure
	}
	return SleepWakeEvents(output, 12)
}

// SleepWakeEvents keeps the last count sleep, wake, dark-wake and wake-request lines.
func SleepWakeEvents(output []byte, count int) []string {
	var events []string
	scanner := bufio.NewScanner(bytes.NewReader(output))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		match := pmsetEvent.FindStringSubmatch(scanner.Text())
		if match == nil {
			continue
		}
		detail := strings.Join(strings.Fields(pmsetPower.ReplaceAllString(match[3], "")), " ")
		events = append(events, cut(match[1]+" "+match[2]+" · "+detail, 170))
	}
	if len(events) > count {
		events = events[len(events)-count:]
	}
	if len(events) == 0 {
		return []string{"잠자기·깨어남 기록이 없습니다"}
	}
	return events
}

func (c *Collector) schedule(ctx context.Context) []string {
	output, failure := c.command(ctx, "pmset", "-g", "sched")
	if failure != nil {
		return failure
	}
	return ScheduledEvents(output)
}

// ScheduledEvents lists the scheduled power events without the header.
func ScheduledEvents(output []byte) []string {
	var events []string
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.Join(strings.Fields(line), " ")
		if line == "" || strings.HasPrefix(strings.ToLower(line), "scheduled power events") {
			continue
		}
		events = append(events, cut(line, 120))
	}
	if len(events) > 6 {
		events = events[:6]
	}
	if len(events) == 0 {
		return []string{"예약된 깨우기가 없습니다"}
	}
	return events
}

// "   pid 345(sharingd): [0x00001234] 00:10:00 PreventUserIdleSystemSleep named: \"Handoff\""
var assertionLine = regexp.MustCompile(`pid \d+\(([^)]*)\): \[[^\]]*\] (\S+) (\S+) named: "(.*)"`)

func (c *Collector) assertions(ctx context.Context) []string {
	output, failure := c.command(ctx, "pmset", "-g", "assertions")
	if failure != nil {
		return failure
	}
	return Assertions(output)
}

// Assertions lists who holds which power assertion, the owner first when it is the app.
func Assertions(output []byte) []string {
	var lines []string
	for _, line := range strings.Split(string(output), "\n") {
		match := assertionLine.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		lines = append(lines, cut(fmt.Sprintf("%s · %s · %s · %q", match[1], match[3], match[2], match[4]), 140))
	}
	if len(lines) > 10 {
		lines = append(lines[:10], fmt.Sprintf("외 %d개", len(lines)-10))
	}
	if len(lines) == 0 {
		return []string{"잠을 막는 요청이 없습니다"}
	}
	return lines
}

func (c *Collector) cameras(ctx context.Context) []string {
	output, failure := c.command(ctx, "system_profiler", "SPCameraDataType")
	if failure != nil {
		return failure
	}
	return Cameras(output)
}

// Cameras reads the device names system_profiler prints at the second indentation level.
func Cameras(output []byte) []string {
	var names []string
	for _, line := range strings.Split(string(output), "\n") {
		trimmed := strings.TrimSpace(line)
		indent := len(line) - len(strings.TrimLeft(line, " "))
		if indent == 4 && strings.HasSuffix(trimmed, ":") {
			names = append(names, "보임: "+strings.TrimSuffix(trimmed, ":"))
		}
	}
	if len(names) == 0 {
		return []string{"macOS가 카메라를 하나도 보지 못합니다"}
	}
	return names
}

// UVCAssistant serves USB cameras such as an Intel iMac's FaceTime HD camera from macOS 12.3;
// VDCAssistant did before that.
var cameraDaemons = map[string]bool{"UVCAssistant": true, "VDCAssistant": true, "AppleCameraAssistant": true, "appleh13camerad": true}

func (c *Collector) cameraDaemons(ctx context.Context) []string {
	output, failure := c.command(ctx, "ps", "-axo", "pid=,etime=,comm=")
	if failure != nil {
		return failure
	}
	return CameraDaemons(output)
}

// CameraDaemons finds the macOS camera services and how long each has run. They start on
// demand, so none running only means nobody is using the camera.
func CameraDaemons(output []byte) []string {
	var lines []string
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		name := filepath.Base(strings.Join(fields[2:], " "))
		if cameraDaemons[name] {
			lines = append(lines, fmt.Sprintf("%s · pid %s · 실행 %s", name, fields[0], fields[1]))
		}
	}
	if len(lines) == 0 {
		return []string{"실행 중인 카메라 서비스 없음 (카메라를 쓰지 않을 때는 정상)"}
	}
	return lines
}

type probeEvent struct {
	Timestamp   string `json:"timestamp"`
	Kind        string `json:"kind"`
	Device      string `json:"device"`
	TotalFrames uint64 `json:"totalFrames"`
}

func (c *Collector) captureProbe(context.Context) []string {
	data, err := readTail(filepath.Join(c.Dir, "capture-probe.jsonl"), 512*1024)
	if err != nil {
		return []string{"카메라 기록을 읽지 못했습니다: " + cut(err.Error(), 120)}
	}
	return CaptureSummary(data, c.Now(), 2*time.Hour)
}

// The app writes the first frame heartbeat 10 s after a start (CaptureProbeLogger).
const heartbeatGrace = 15 * time.Second

// CaptureSummary tells from the app's capture log whether frames arrived after each start.
// Counts cover the window; the newest start, stop and frame are taken from the whole tail so a
// capture running longer than the window is still reported as running.
func CaptureSummary(data []byte, now time.Time, window time.Duration) []string {
	since := now.Add(-window)
	var starts, stops, emptyStops int
	var lastStart, lastStop, lastFrame time.Time
	var lastStartDevice string
	var lastStopFrames uint64
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		var event probeEvent
		if json.Unmarshal(scanner.Bytes(), &event) != nil {
			continue
		}
		at, err := time.Parse(time.RFC3339, event.Timestamp)
		if err != nil {
			continue
		}
		inWindow := !at.Before(since)
		switch event.Kind {
		case "frame_heartbeat":
			if at.After(lastFrame) {
				lastFrame = at
			}
		case "capture_started":
			lastStart, lastStartDevice = at, event.Device
			if inWindow {
				starts++
			}
		case "capture_stopped":
			lastStop, lastStopFrames = at, event.TotalFrames
			if inWindow {
				stops++
				if event.TotalFrames == 0 {
					emptyStops++
				}
			}
		}
	}
	running := !lastStart.IsZero() && !lastStart.Before(lastStop)
	if starts == 0 && stops == 0 && !running {
		lines := []string{"최근 2시간 동안 카메라를 켠 적이 없습니다"}
		if !lastFrame.IsZero() {
			lines = append(lines, "마지막 프레임 "+clock(lastFrame, now))
		}
		return lines
	}
	lines := []string{fmt.Sprintf("시작 %d회 · 중지 %d회 · 프레임 0개로 끝난 시작 %d회", starts, stops, emptyStops)}
	if !lastStart.IsZero() {
		line := "마지막 시작 " + clock(lastStart, now)
		if lastStartDevice != "" {
			line += " · " + lastStartDevice
		}
		if running {
			line += " · 지금 켜져 있음"
		}
		lines = append(lines, line)
	}
	if !lastStop.IsZero() {
		lines = append(lines, fmt.Sprintf("마지막 중지 %s · 그동안 프레임 %d개", clock(lastStop, now), lastStopFrames))
	}
	heartbeatSinceStart := !lastFrame.IsZero() && !lastFrame.Before(lastStart)
	stoppedWithFrames := !running && lastStopFrames > 0
	switch {
	case heartbeatSinceStart:
		lines = append(lines, "마지막 프레임 "+clock(lastFrame, now))
	case stoppedWithFrames:
		// A capture shorter than the heartbeat interval: the stop's count is the evidence.
		lines = append(lines, "마지막 시작 뒤 프레임이 왔습니다 (짧게 켜져 프레임 시각 기록 없음)")
	case running && now.Sub(lastStart) < heartbeatGrace:
		lines = append(lines, "시작 직후라 프레임을 확인하는 중입니다 (첫 기록은 시작 10초 뒤)")
	default:
		line := "마지막 시작 뒤 프레임이 한 번도 오지 않았습니다"
		if !lastFrame.IsZero() {
			line += " · 마지막 프레임 " + clock(lastFrame, now)
		} else {
			line += " · 기록에 남은 프레임도 없습니다"
		}
		lines = append(lines, line)
	}
	return lines
}

// Go's log package prefixes "2026/11/09 10:21:05 ".
var gatewayStamp = regexp.MustCompile(`^\d{4}/(\d\d/\d\d \d\d:\d\d:\d\d) (.*)$`)

func (c *Collector) gatewayLog(context.Context) []string {
	data, err := readTail(filepath.Join(c.Dir, "gateway.log"), 256*1024)
	if err != nil {
		return []string{"게이트웨이 기록을 읽지 못했습니다: " + cut(err.Error(), 120)}
	}
	return GatewaySummary(data)
}

// GatewaySummary lists when the gateway last started (it restarts after every wake) and the
// bot's last errors, which tell whether Telegram was reachable after a wake.
func GatewaySummary(data []byte) []string {
	var starts, errorsSeen []string
	for _, line := range strings.Split(string(data), "\n") {
		match := gatewayStamp.FindStringSubmatch(strings.TrimRight(line, "\r"))
		if match == nil {
			continue
		}
		switch {
		case strings.Contains(match[2], "gateway listening"):
			starts = append(starts, match[1])
		case strings.HasPrefix(match[2], "telegram: ") && !routineBotLine(match[2]):
			errorsSeen = append(errorsSeen, cut(match[1]+" "+strings.TrimPrefix(match[2], "telegram: "), 150))
		}
	}
	if len(starts) > 6 {
		starts = starts[len(starts)-6:]
	}
	if len(errorsSeen) > 4 {
		errorsSeen = errorsSeen[len(errorsSeen)-4:]
	}
	lines := []string{}
	if len(starts) > 0 {
		lines = append(lines, "시작: "+strings.Join(starts, ", "))
	} else {
		lines = append(lines, "시작 기록이 없습니다")
	}
	if len(errorsSeen) > 0 {
		lines = append(lines, "텔레그램 오류:")
		lines = append(lines, errorsSeen...)
	} else {
		lines = append(lines, "텔레그램 오류 없음")
	}
	return lines
}

// routineBotLine is a bot log line that reports normal operation, not a failure.
func routineBotLine(line string) bool {
	for _, prefix := range []string{"bot started", "bot stopped", "viewing request ended", "ignored a message"} {
		if strings.HasPrefix(line, "telegram: "+prefix) {
			return true
		}
	}
	return false
}

func (c *Collector) appLog(ctx context.Context) []string {
	output, failure := c.command(ctx, "log", "show", "--last", "1h", "--style", "compact",
		"--predicate", `process == "MacMonitor" AND eventMessage BEGINSWITH "MacMonitor"`)
	if failure != nil {
		return failure
	}
	return AppLogLines(output, 12)
}

// "2026-11-09 10:16:02.123 Df MacMonitor[123:4567] (CoreFoundation) MacMonitor slim: requesting sleep".
// NSLog writes through Foundation, so a sender in parentheses (and for os_log a subsystem in
// brackets) can sit between the process and the message.
var compactLine = regexp.MustCompile(`^\d{4}-(\d\d-\d\d \d\d:\d\d:\d\d)\.\d+\s+\S+\s+[^\s\[]+\[[^\]]*\]\s+(?:\([^)]*\)\s+)?(?:\[[^\]]*\]\s+)?MacMonitor:?\s?(.*)$`)

// AppLogLines keeps the app's own NSLog lines, shortened to time and message.
func AppLogLines(output []byte, count int) []string {
	var lines []string
	for _, line := range strings.Split(string(output), "\n") {
		match := compactLine.FindStringSubmatch(strings.TrimRight(line, "\r"))
		if match == nil {
			continue
		}
		lines = append(lines, cut(match[1]+" "+match[2], 170))
	}
	if len(lines) > count {
		lines = lines[len(lines)-count:]
	}
	if len(lines) == 0 {
		return []string{"최근 1시간 앱 로그가 없습니다"}
	}
	return lines
}

func clock(at, now time.Time) string {
	local := at.In(now.Location())
	age := now.Sub(at)
	switch {
	case age < time.Minute:
		return local.Format("15:04:05") + " (방금)"
	case age < 2*time.Hour:
		return fmt.Sprintf("%s (%d분 전)", local.Format("15:04:05"), int(age.Minutes()))
	default:
		return local.Format("01-02 15:04:05")
	}
}

// readTail returns at most max bytes from the end of the file, starting at a whole line.
func readTail(path string, max int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	offset := info.Size() - max
	if offset < 0 {
		offset = 0
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return nil, err
	}
	if offset > 0 {
		if newline := bytes.IndexByte(data, '\n'); newline >= 0 {
			data = data[newline+1:]
		}
	}
	return data, nil
}

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil {
		if message := strings.TrimSpace(stderr.String()); message != "" {
			return nil, errors.New(strings.SplitN(message, "\n", 2)[0])
		}
		return nil, err
	}
	return output, nil
}

func cut(text string, limit int) string {
	runes := []rune(text)
	if len(runes) <= limit {
		return text
	}
	return string(runes[:limit-1]) + "…"
}
