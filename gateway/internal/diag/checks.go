package diag

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ErrUnknownCheck is returned for a check ID that is not in Checks.
var ErrUnknownCheck = errors.New("알 수 없는 진단 항목입니다")

// Check is one fixed, read-only diagnostic the web debug page can run. Command shows the owner
// what it is equivalent to in Terminal; nothing from the request reaches a command line.
type Check struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Command string `json:"command"`
}

// The most a check returns, so a large log cannot flood the page.
const (
	maxCheckLines = 400
	maxCheckBytes = 96 * 1024
)

type checkSpec struct {
	Check
	timeout time.Duration
	run     func(c *Collector, ctx context.Context) ([]string, error)
}

const appLogPredicate = `process == "MacMonitor" AND eventMessage BEGINSWITH "MacMonitor"`

var checkSpecs = []checkSpec{
	{Check{"power-log", "잠자기·깨어남·화면 켜짐/꺼짐 (최근 40건)",
		`pmset -g log | grep -E " Sleep | Wake | DarkWake |Display is turned" | tail -40`},
		40 * time.Second, (*Collector).powerLog},
	{Check{"app-log", "앱 로그 (최근 3시간, 마지막 80줄)",
		`log show --last 3h --style compact --predicate '` + appLogPredicate + `' | tail -80`},
		90 * time.Second, (*Collector).appLogLong},
	{Check{"gateway-log", "게이트웨이 기록 (마지막 80줄)", `tail -80 ~/Library/Application\ Support/MacMonitor/Diagnostics/gateway.log`},
		5 * time.Second, (*Collector).gatewayTail},
	{Check{"assertions", "잠을 막는 요청", "pmset -g assertions"}, 20 * time.Second, rawCommand("pmset", "-g", "assertions")},
	{Check{"sched", "깨우기 예약", "pmset -g sched"}, 20 * time.Second, rawCommand("pmset", "-g", "sched")},
	{Check{"settings", "전원 설정 (화면 끄기·잠자기 시간)", "pmset -g"}, 20 * time.Second, rawCommand("pmset", "-g")},
	{Check{"systemstate", "지금 전원 상태 (화면·소리 사용 가능 여부)", "pmset -g systemstate"}, 20 * time.Second, rawCommand("pmset", "-g", "systemstate")},
	{Check{"idle", "마지막 키보드·마우스 입력 뒤 지난 시간", `ioreg -c IOHIDSystem -d 4 | grep HIDIdleTime`}, 20 * time.Second, (*Collector).idleTime},
	{Check{"report", "전체 요약 (텔레그램 '진단'과 같음)", "(여러 명령 요약)"}, 60 * time.Second, (*Collector).fullReport},
}

// Checks lists what the web debug page offers, in display order.
func (*Collector) Checks() []Check {
	checks := make([]Check, len(checkSpecs))
	for index, spec := range checkSpecs {
		checks[index] = spec.Check
	}
	return checks
}

// Anything shaped like a Telegram bot token. The gateway redacts the token before logging, and
// this is the second guard so the page never shows one whatever a log holds.
var botTokenShape = regexp.MustCompile(`[0-9]{5,}:[A-Za-z0-9_-]{30,}`)

// RunCheck runs one check by ID and returns its text, cut to a size a page can show, with
// anything shaped like a bot token replaced.
func (c *Collector) RunCheck(ctx context.Context, id string) (string, error) {
	for _, spec := range checkSpecs {
		if spec.ID != id {
			continue
		}
		checkCtx, cancel := context.WithTimeout(ctx, spec.timeout)
		defer cancel()
		lines, err := spec.run(c, checkCtx)
		if err != nil {
			if checkCtx.Err() != nil {
				return "", fmt.Errorf("%d초 안에 끝나지 않았습니다", int(spec.timeout/time.Second))
			}
			return "", err
		}
		return botTokenShape.ReplaceAllString(limitLines(lines), "<token>"), nil
	}
	return "", ErrUnknownCheck
}

func limitLines(lines []string) string {
	if len(lines) == 0 {
		return "(내용 없음)"
	}
	dropped := 0
	if len(lines) > maxCheckLines {
		dropped = len(lines) - maxCheckLines
		lines = lines[dropped:]
	}
	text := strings.Join(lines, "\n")
	if len(text) > maxCheckBytes {
		text = text[len(text)-maxCheckBytes:]
		if newline := strings.IndexByte(text, '\n'); newline >= 0 {
			text = text[newline+1:]
		}
		dropped = -1
	}
	switch {
	case dropped > 0:
		text = fmt.Sprintf("(앞 %d줄 생략)\n", dropped) + text
	case dropped < 0:
		text = "(앞부분 생략)\n" + text
	}
	return text
}

func rawCommand(name string, args ...string) func(c *Collector, ctx context.Context) ([]string, error) {
	return func(c *Collector, ctx context.Context) ([]string, error) {
		output, err := c.Run(ctx, name, args...)
		if err != nil {
			return nil, err
		}
		return strings.Split(strings.TrimRight(string(output), "\n"), "\n"), nil
	}
}

func (c *Collector) powerLog(ctx context.Context) ([]string, error) {
	output, err := c.Run(ctx, "pmset", "-g", "log")
	if err != nil {
		return nil, err
	}
	return PowerLogLines(output, 40), nil
}

// "2026-11-26 18:41:05 +0900 Notification        \tDisplay is turned on" and the sleep and
// wake lines SleepWakeEvents reads.
var powerLogLine = regexp.MustCompile(`^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4} (Sleep|DarkWake|Wake Requests|Wake)\s|Display is turned (on|off)`)

// PowerLogLines keeps the last count sleep, wake, dark-wake and display on/off lines of
// pmset -g log, with runs of spaces and tabs collapsed.
func PowerLogLines(output []byte, count int) []string {
	var lines []string
	scanner := bufio.NewScanner(bytes.NewReader(output))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !powerLogLine.MatchString(line) {
			continue
		}
		lines = append(lines, cut(strings.Join(strings.Fields(line), " "), 220))
	}
	if len(lines) > count {
		lines = lines[len(lines)-count:]
	}
	if len(lines) == 0 {
		return []string{"잠자기·깨어남·화면 기록이 없습니다"}
	}
	return lines
}

func (c *Collector) appLogLong(ctx context.Context) ([]string, error) {
	output, err := c.Run(ctx, "log", "show", "--last", "3h", "--style", "compact", "--predicate", appLogPredicate)
	if err != nil {
		return nil, err
	}
	lines := AppLogLines(output, 80)
	if len(lines) == 1 && strings.HasPrefix(lines[0], "최근 1시간") {
		return []string{"최근 3시간 앱 로그가 없습니다"}, nil
	}
	return lines, nil
}

func (c *Collector) gatewayTail(context.Context) ([]string, error) {
	data, err := readTail(filepath.Join(c.Dir, "gateway.log"), 64*1024)
	if err != nil {
		return nil, fmt.Errorf("게이트웨이 기록을 읽지 못했습니다: %s", cut(err.Error(), 120))
	}
	lines := strings.Split(strings.TrimRight(strings.ReplaceAll(string(data), "\r", ""), "\n"), "\n")
	if len(lines) > 80 {
		lines = lines[len(lines)-80:]
	}
	return lines, nil
}

var hidIdle = regexp.MustCompile(`"HIDIdleTime" = (\d+)`)

func (c *Collector) idleTime(ctx context.Context) ([]string, error) {
	output, err := c.Run(ctx, "ioreg", "-c", "IOHIDSystem", "-d", "4")
	if err != nil {
		return nil, err
	}
	return IdleTime(output), nil
}

// IdleTime reads HIDIdleTime (nanoseconds since the last keyboard or mouse input).
func IdleTime(output []byte) []string {
	match := hidIdle.FindSubmatch(output)
	if match == nil {
		return []string{"HIDIdleTime을 찾지 못했습니다"}
	}
	nanos, err := strconv.ParseUint(string(match[1]), 10, 64)
	if err != nil {
		return []string{"HIDIdleTime을 읽지 못했습니다: " + string(match[1])}
	}
	idle := time.Duration(nanos)
	return []string{fmt.Sprintf("마지막 입력 뒤 %s 지났습니다 (HIDIdleTime %d)", idle.Round(time.Second), nanos)}
}

func (c *Collector) fullReport(ctx context.Context) ([]string, error) {
	return strings.Split(c.Report(ctx), "\n"), nil
}
