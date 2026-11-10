package chat

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"macmonitor.local/gateway/internal/health"
)

const testToken = "12345:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

type sentMessage struct {
	ChatID int64  `json:"chat_id"`
	Text   string `json:"text"`
}

// fakeTelegram answers like the Bot API: one queued batch per getUpdates, then empty batches.
type fakeTelegram struct {
	mu       sync.Mutex
	batches  []string
	offsets  []int64
	sent     []sentMessage
	conflict bool
}

func (f *fakeTelegram) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/bot"+testToken+"/") {
			t.Errorf("request without the bot token: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		f.mu.Lock()
		defer f.mu.Unlock()
		switch strings.TrimPrefix(r.URL.Path, "/bot"+testToken+"/") {
		case "getUpdates":
			var request struct {
				Offset  int64 `json:"offset"`
				Timeout int   `json:"timeout"`
			}
			_ = json.NewDecoder(r.Body).Decode(&request)
			f.offsets = append(f.offsets, request.Offset)
			if f.conflict {
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}`))
				return
			}
			batch := "[]"
			if len(f.batches) > 0 {
				batch, f.batches = f.batches[0], f.batches[1:]
			} else if request.Timeout > 0 {
				// Like Telegram, hold an empty long poll open; shortened so tests stay quick.
				f.mu.Unlock()
				time.Sleep(20 * time.Millisecond)
				f.mu.Lock()
			}
			_, _ = w.Write([]byte(`{"ok":true,"result":` + batch + `}`))
		case "sendMessage":
			var message sentMessage
			_ = json.NewDecoder(r.Body).Decode(&message)
			f.sent = append(f.sent, message)
			_, _ = w.Write([]byte(`{"ok":true,"result":{"message_id":1}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
}

func (f *fakeTelegram) texts(chatID int64) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var texts []string
	for _, message := range f.sent {
		if message.ChatID == chatID {
			texts = append(texts, message.Text)
		}
	}
	return texts
}

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

type harness struct {
	bot        *Bot
	api        *fakeTelegram
	clock      *fakeClock
	demandFile string
	statusFile string
	stateFile  string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	api := &fakeTelegram{}
	server := httptest.NewServer(api.handler(t))
	t.Cleanup(server.Close)
	directory := t.TempDir()
	clock := &fakeClock{now: time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)}
	h := &harness{
		api:        api,
		clock:      clock,
		demandFile: filepath.Join(directory, "Runtime", "live-demand.json"),
		statusFile: filepath.Join(directory, "Runtime", "monitoring-status.json"),
		stateFile:  filepath.Join(directory, "Runtime", "telegram-state.json"),
	}
	h.bot = h.newBot(t, server)
	return h
}

func (h *harness) newBot(t *testing.T, server *httptest.Server) *Bot {
	bot := New(Config{BotToken: testToken, ChatID: 42, ViewMinutes: 10}, "https://camera.example:8443",
		h.demandFile, h.statusFile, h.stateFile)
	bot.APIBase = server.URL
	bot.Client = server.Client()
	bot.PollTimeout = 0
	bot.Now = h.clock.Now
	bot.Sleep = func(_ context.Context, d time.Duration) { h.clock.Advance(d) }
	bot.Background = func(work func()) { work() }
	bot.Logf = t.Logf
	return bot
}

// message builds one Telegram update as the API would deliver it.
func (h *harness) message(id, chatID int64, text string, sentAt time.Time) string {
	payload, _ := json.Marshal(map[string]any{
		"update_id": id,
		"message": map[string]any{
			"message_id": id,
			"date":       sentAt.Unix(),
			"chat":       map[string]any{"id": chatID, "type": "private"},
			"text":       text,
		},
	})
	return string(payload)
}

func (h *harness) queue(updates ...string) {
	h.api.mu.Lock()
	h.api.batches = append(h.api.batches, "["+strings.Join(updates, ",")+"]")
	h.api.mu.Unlock()
}

func (h *harness) writeStatus(t *testing.T, change func(*health.Snapshot)) {
	t.Helper()
	now := h.clock.Now()
	started := now.Add(-30 * time.Second)
	frame := now.Add(-time.Second)
	snapshot := health.Snapshot{SchemaVersion: 1, UpdatedAt: &now, State: "running", Detail: "원격 시청 중 — Test Camera · 녹화 안 함",
		ExpectingFrames: true, CaptureStartedAt: &started, LastFrameAt: &frame, CaptureFPS: 15, TotalFrames: 20,
		LiveStandby: true, CaptureMode: "live"}
	change(&snapshot)
	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(h.statusFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(h.statusFile, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func (h *harness) demand(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(h.demandFile)
	if err != nil {
		t.Fatalf("lease file: %v", err)
	}
	return string(data)
}

func TestOnlyTheConfiguredChatTurnsTheCameraOnAndEveryUpdateIsConfirmed(t *testing.T) {
	h := newHarness(t)
	h.writeStatus(t, func(*health.Snapshot) {})
	now := h.clock.Now()
	h.queue(h.message(7, 99, "카메라", now), h.message(8, 42, "카메라 보여줘", now))

	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(h.demandFile); err != nil {
		t.Fatal("the owner's request did not write the lease")
	}
	if texts := h.api.texts(99); len(texts) != 0 {
		t.Fatalf("a stranger got replies: %v", texts)
	}
	texts := h.api.texts(42)
	if len(texts) != 2 || !strings.Contains(texts[0], "https://camera.example:8443") || !strings.Contains(texts[0], "10분") {
		t.Fatalf("unexpected replies: %v", texts)
	}
	if !strings.Contains(texts[1], "카메라가 켜졌습니다") {
		t.Fatalf("the camera coming on was not confirmed: %v", texts)
	}

	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(h.api.offsets) != 2 || h.api.offsets[0] != 0 || h.api.offsets[1] != 9 {
		t.Fatalf("the stranger's and the owner's updates must both be confirmed: offsets %v", h.api.offsets)
	}
	saved, err := os.ReadFile(h.stateFile)
	if err != nil || !strings.Contains(string(saved), `"offset":9`) {
		t.Fatalf("offset not persisted: %s %v", saved, err)
	}
}

func TestStopEndsTheRequestAndRenewalsStop(t *testing.T) {
	h := newHarness(t)
	now := h.clock.Now()
	h.queue(h.message(1, 42, "카메라", now))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	first := h.demand(t)
	h.clock.Advance(5 * time.Second)
	h.bot.renewOnce(h.clock.Now())
	second := h.demand(t)
	if first == second {
		t.Fatal("the app detects a viewer by content change, so each renewal must change the file")
	}

	h.queue(h.message(2, 42, "그만", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	h.clock.Advance(5 * time.Second)
	h.bot.renewOnce(h.clock.Now())
	if h.demand(t) != second {
		t.Fatal("renewals continued after the owner ended the request")
	}
	texts := h.api.texts(42)
	if !strings.Contains(texts[len(texts)-1], "끝냈습니다") {
		t.Fatalf("stop was not acknowledged: %v", texts)
	}
}

func TestTheRequestExpiresOnItsOwn(t *testing.T) {
	h := newHarness(t)
	h.queue(h.message(1, 42, "live", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	h.clock.Advance(9*time.Minute + 55*time.Second)
	h.bot.renewOnce(h.clock.Now())
	before := h.demand(t)
	h.clock.Advance(10 * time.Second)
	h.bot.renewOnce(h.clock.Now())
	if h.demand(t) != before {
		t.Fatal("the lease was renewed after the viewing window ended")
	}
	h.bot.mu.Lock()
	until := h.bot.state.WindowUntil
	h.bot.mu.Unlock()
	if until != nil {
		t.Fatal("an expired window must be cleared so a restart does not resume it")
	}
}

func TestAStaleStartRequestIsRefused(t *testing.T) {
	h := newHarness(t)
	h.queue(h.message(1, 42, "카메라", h.clock.Now().Add(-31*time.Minute)))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(h.demandFile); !os.IsNotExist(err) {
		t.Fatal("a request from before the Mac slept turned the camera on")
	}
	texts := h.api.texts(42)
	if len(texts) != 1 || !strings.Contains(texts[0], "31분 전") || !strings.Contains(texts[0], "다시 보내세요") {
		t.Fatalf("unexpected reply: %v", texts)
	}
}

func TestStateSurvivesAGatewayRestart(t *testing.T) {
	h := newHarness(t)
	h.queue(h.message(5, 42, "카메라", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	before := h.demand(t)

	server := httptest.NewServer(h.api.handler(t))
	defer server.Close()
	restarted := h.newBot(t, server)
	if err := restarted.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if last := h.api.offsets[len(h.api.offsets)-1]; last != 6 {
		t.Fatalf("the restarted bot replayed from offset %d", last)
	}
	h.clock.Advance(5 * time.Second)
	restarted.renewOnce(h.clock.Now())
	if h.demand(t) == before {
		t.Fatal("the restarted bot dropped the open viewing request")
	}
}

func TestACameraFailureIsReportedBackToTheChat(t *testing.T) {
	h := newHarness(t)
	h.writeStatus(t, func(s *health.Snapshot) {
		s.State = "failed"
		s.Detail = "오류 — 카메라 권한이 필요합니다."
		s.ExpectingFrames = false
		s.CaptureMode = "off"
	})
	h.queue(h.message(1, 42, "카메라", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	texts := h.api.texts(42)
	if len(texts) != 2 || !strings.Contains(texts[1], "켜지 못했습니다 · 오류 — 카메라 권한이 필요합니다.") {
		t.Fatalf("unexpected replies: %v", texts)
	}
}

func TestTheViewingWindowEndsWhenTheViewerLeavesOrNeverComes(t *testing.T) {
	h := newHarness(t)
	h.bot.StartupTimeout = 0 // the start confirmation would otherwise advance the fake clock
	var seen time.Time
	h.bot.ViewerSeen = func() time.Time { return seen }
	start := h.clock.Now()
	h.queue(h.message(1, 42, "카메라", start))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Nobody opens the link: the window ends after NoViewerTimeout instead of ten minutes.
	h.clock.Advance(2*time.Minute + 59*time.Second)
	if !h.renews() {
		t.Fatal("the window ended before the no-viewer timeout")
	}
	h.clock.Advance(2 * time.Second)
	if h.renews() {
		t.Fatal("the window stayed open although nobody opened the link for three minutes")
	}
	texts := h.api.texts(42)
	if !strings.Contains(texts[len(texts)-1], "아무도 열지 않아") {
		t.Fatalf("the owner was not told why the request ended: %v", texts)
	}

	// A viewer comes and goes: the window ends ViewerGone after their last renewal.
	h.queue(h.message(2, 42, "카메라", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	h.clock.Advance(30 * time.Second)
	seen = h.clock.Now()
	h.clock.Advance(4 * time.Minute)
	seen = h.clock.Now() // still watching four minutes in
	if !h.renews() {
		t.Fatal("a watching viewer must keep the window open past the no-viewer timeout")
	}
	h.clock.Advance(91 * time.Second)
	if h.renews() {
		t.Fatal("the window stayed open 91 s after the viewer left")
	}
	texts = h.api.texts(42)
	if !strings.Contains(texts[len(texts)-1], "웹 시청이 끝나") {
		t.Fatalf("the owner was not told the viewer left: %v", texts)
	}
}

// renews reports whether one renewal tick at the fake clock's time still rewrites the lease.
func (h *harness) renews() bool {
	before, _ := os.ReadFile(h.demandFile)
	h.bot.renewOnce(h.clock.Now())
	after, _ := os.ReadFile(h.demandFile)
	return string(before) != string(after)
}

func TestASilentAppIsReportedAfterTheStartupTimeout(t *testing.T) {
	h := newHarness(t)
	h.queue(h.message(1, 42, "카메라", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	texts := h.api.texts(42)
	if len(texts) != 2 || !strings.Contains(texts[1], "60초 안에 카메라가 켜지지 않았습니다") || !strings.Contains(texts[1], "상태 확인 불가") {
		t.Fatalf("unexpected replies: %v", texts)
	}
}

func TestStatusAndHelpReplies(t *testing.T) {
	h := newHarness(t)
	h.writeStatus(t, func(s *health.Snapshot) {
		s.CaptureMode = "timed"
		s.Detail = "원격 녹화 중 — Test Camera"
		s.Audio = "unavailable"
		s.AudioDetail = "마이크 권한 필요"
		s.SlimDetail = "카메라 사용 중 · 깨어 있음"
		free := int64(123_400_000_000)
		s.DiskFreeBytes = &free
	})
	now := h.clock.Now()
	h.queue(h.message(1, 42, "상태", now), h.message(2, 42, "안녕", now))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	texts := h.api.texts(42)
	if len(texts) != 2 {
		t.Fatalf("unexpected replies: %v", texts)
	}
	for _, expected := range []string{"상태: 카메라 켜짐 · 원격 녹화", "원격 녹화 중 — Test Camera", "소리 없음 (마이크 권한 필요)", "슬림: 카메라 사용 중 · 깨어 있음", "디스크 여유 123.4GB"} {
		if !strings.Contains(texts[0], expected) {
			t.Fatalf("status reply %q lacks %q", texts[0], expected)
		}
	}
	if texts[1] != helpText {
		t.Fatalf("unknown text must get the command list, got %q", texts[1])
	}
}

func TestAnotherPollerIsReportedAsConflict(t *testing.T) {
	h := newHarness(t)
	h.api.conflict = true
	if err := h.bot.Poll(context.Background()); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected ErrConflict, got %v", err)
	}
}

func TestErrorsNeverQuoteTheToken(t *testing.T) {
	h := newHarness(t)
	h.bot.APIBase = "http://127.0.0.1:1"
	h.bot.Client = &http.Client{Timeout: time.Second}
	err := h.bot.Poll(context.Background())
	if err == nil {
		t.Fatal("an unreachable API must fail")
	}
	if strings.Contains(err.Error(), testToken) {
		t.Fatalf("the token leaked into an error: %v", err)
	}
	if !strings.Contains(err.Error(), "<token>") {
		t.Fatalf("the URL was expected in redacted form: %v", err)
	}
}

func TestLoadConfigDefaultsTheWindowAndRejectsBadFiles(t *testing.T) {
	directory := t.TempDir()
	write := func(content string) string {
		path := filepath.Join(directory, "telegram.json")
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	cfg, err := LoadConfig(write(`{"botToken":"` + testToken + `","chatID":42}`))
	if err != nil || cfg.ViewMinutes != 10 || cfg.ViewWindow() != 10*time.Minute {
		t.Fatalf("defaults: %+v %v", cfg, err)
	}
	for name, content := range map[string]string{
		"chat id pasted as token": `{"botToken":"42","chatID":42}`,
		"missing chat":            `{"botToken":"` + testToken + `"}`,
		"unknown field":           `{"botToken":"` + testToken + `","chatID":42,"webhook":"x"}`,
		"window too long":         `{"botToken":"` + testToken + `","chatID":42,"viewMinutes":121}`,
		"two documents":           `{"botToken":"` + testToken + `","chatID":42} {}`,
	} {
		if _, err := LoadConfig(write(content)); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
	if _, err := LoadConfig(filepath.Join(directory, "missing.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a missing file must be reported as not existing, got %v", err)
	}
}

func TestSuperviseFollowsTheConfigurationFile(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "telegram.json")
	var mu sync.Mutex
	var built []Config
	api := &fakeTelegram{}
	server := httptest.NewServer(api.handler(t))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		Supervise(ctx, path, 10*time.Millisecond, func(cfg Config) *Bot {
			mu.Lock()
			built = append(built, cfg)
			mu.Unlock()
			bot := New(cfg, "https://camera.example", filepath.Join(directory, "demand.json"), "", "")
			bot.APIBase = server.URL
			bot.Client = server.Client()
			bot.PollTimeout = time.Second
			bot.Sleep = func(_ context.Context, d time.Duration) { time.Sleep(min(d, 20*time.Millisecond)) }
			bot.Logf = func(string, ...any) {}
			return bot
		}, func(string, ...any) {})
		close(done)
	}()
	snapshot := func() []Config {
		mu.Lock()
		defer mu.Unlock()
		return append([]Config(nil), built...)
	}
	waitFor := func(chatID int64) []Config {
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			if configs := snapshot(); len(configs) > 0 && configs[len(configs)-1].ChatID == chatID {
				return configs
			}
			time.Sleep(10 * time.Millisecond)
		}
		return snapshot()
	}
	time.Sleep(50 * time.Millisecond)
	if len(snapshot()) != 0 {
		t.Fatal("a bot was built without a configuration file")
	}
	if err := os.WriteFile(path, []byte(`{"botToken":"`+testToken+`","chatID":42}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if first := waitFor(42); len(first) != 1 {
		t.Fatalf("expected exactly one bot for the new file, got %v", first)
	}
	// Touching the file without changing it must not restart the bot.
	time.Sleep(50 * time.Millisecond)
	if err := os.Chtimes(path, time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}
	time.Sleep(60 * time.Millisecond)
	if touched := snapshot(); len(touched) != 1 {
		t.Fatalf("an unchanged file restarted the bot: %v", touched)
	}
	if err := os.WriteFile(path, []byte(`{"botToken":"`+testToken+`","chatID":43}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if second := waitFor(43); len(second) != 2 || second[0].ChatID != 42 {
		t.Fatalf("expected the bot rebuilt once for the changed file, got %v", second)
	}
	cancel()
	<-done
}

func TestDiagnoseRepliesInPartsWithoutTheTokenEvenWhenQueuedDuringSleep(t *testing.T) {
	h := newHarness(t)
	h.writeStatus(t, func(*health.Snapshot) {})
	var long strings.Builder
	long.WriteString("[잠자기·깨어남]\nleaked " + testToken + "\n")
	for i := 0; i < 120; i++ {
		long.WriteString(strings.Repeat("가", 60) + "\n")
	}
	h.bot.Diagnose = func(context.Context) string { return long.String() }
	queuedAt := h.clock.Now().Add(-40 * time.Minute) // sent while the Mac slept
	h.queue(h.message(1, 42, "카메라 진단", queuedAt))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	texts := h.api.texts(42)
	if len(texts) < 3 || !strings.Contains(texts[0], "진단을 모읍니다") {
		t.Fatalf("expected an acknowledgement and a report in parts: %v", texts)
	}
	if !strings.HasPrefix(texts[1], "(1/") || !strings.Contains(texts[1], "상태: 카메라 켜짐") {
		t.Fatalf("the first part must carry the app status: %q", texts[1])
	}
	for _, text := range texts {
		if strings.Contains(text, testToken) {
			t.Fatal("the token leaked into a diagnostics reply")
		}
		if n := len([]rune(text)); n > 4096 {
			t.Fatalf("a part has %d characters, over Telegram's limit", n)
		}
	}
	if !strings.Contains(strings.Join(texts, ""), "leaked <token>") {
		t.Fatal("the token must be replaced, not dropped with its line")
	}
	if h.demandFileContent() != "" {
		t.Fatal("diagnostics must not turn the camera on")
	}
}

func TestDiagnoseWithoutACollectorSaysSo(t *testing.T) {
	h := newHarness(t)
	h.queue(h.message(1, 42, "진단", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if texts := h.api.texts(42); len(texts) != 1 || !strings.Contains(texts[0], "진단 기능이 없습니다") {
		t.Fatalf("unexpected replies: %v", texts)
	}
}

func TestSleepClosesTheWindowRepliesAndSleepsOnce(t *testing.T) {
	h := newHarness(t)
	calls := 0
	h.bot.SleepMac = func(context.Context) error { calls++; return nil }
	h.queue(h.message(1, 42, "카메라", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	before := len(h.api.texts(42))
	h.queue(h.message(2, 42, "잠자기", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("sleep calls: %d", calls)
	}
	texts := h.api.texts(42)[before:]
	if len(texts) != 1 || !strings.Contains(texts[0], "Mac을 재웁니다") {
		t.Fatalf("unexpected replies: %v", texts)
	}
	h.bot.mu.Lock()
	window := h.bot.state.WindowUntil
	h.bot.mu.Unlock()
	if window != nil {
		t.Fatal("an open view window would keep the camera on and the Mac awake")
	}
}

func TestSleepSentWhileTheMacSleptIsDropped(t *testing.T) {
	h := newHarness(t)
	calls := 0
	h.bot.SleepMac = func(context.Context) error { calls++; return nil }
	h.queue(h.message(1, 42, "잠자기", h.clock.Now().Add(-3*time.Minute)))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls != 0 {
		t.Fatal("a wake must not be ended by a sleep request from before it")
	}
	if texts := h.api.texts(42); len(texts) != 1 || !strings.Contains(texts[0], "무시했습니다") {
		t.Fatalf("unexpected replies: %v", texts)
	}
}

func TestSleepFailureAndMissingSleeperAreReported(t *testing.T) {
	h := newHarness(t)
	h.queue(h.message(1, 42, "잠자기", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	h.bot.SleepMac = func(context.Context) error { return errors.New("pmset sleepnow: exit status 1") }
	h.queue(h.message(2, 42, "sleep", h.clock.Now()))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	texts := h.api.texts(42)
	if len(texts) != 3 || !strings.Contains(texts[0], "잠자기 기능이 없습니다") || !strings.Contains(texts[2], "재우지 못했습니다") {
		t.Fatalf("unexpected replies: %v", texts)
	}
}

func TestSplitMessageKeepsLinesWhole(t *testing.T) {
	parts := splitMessage("aaaa\nbbbb\ncc\n"+strings.Repeat("x", 11), 10)
	expected := []string{"aaaa\nbbbb", "cc", "xxxxxxxxxx", "x"}
	if strings.Join(parts, "|") != strings.Join(expected, "|") {
		t.Fatalf("parts: %q", parts)
	}
	if parts := splitMessage("", 10); len(parts) != 0 {
		t.Fatalf("empty text must give no parts: %q", parts)
	}
}

// demandFileContent is the lease file, or "" when the bot never wrote one.
func (h *harness) demandFileContent() string {
	data, _ := os.ReadFile(h.demandFile)
	return string(data)
}

func TestADiagnosisCutOffBySleepIsSentAfterTheNextStart(t *testing.T) {
	h := newHarness(t)
	h.writeStatus(t, func(*health.Snapshot) {})
	ctx, cancel := context.WithCancel(context.Background())
	// The app stops the gateway before the Mac sleeps: the collection is cut off mid-way.
	h.bot.Diagnose = func(context.Context) string { cancel(); return "[잠자기·깨어남]\n…" }
	h.queue(h.message(1, 42, "진단", h.clock.Now()))
	if err := h.bot.Poll(ctx); err != nil {
		t.Fatal(err)
	}
	if texts := h.api.texts(42); len(texts) != 1 || !strings.Contains(texts[0], "다음에 깨어날 때") {
		t.Fatalf("only the acknowledgement can have gone out: %v", texts)
	}
	saved, _ := os.ReadFile(h.stateFile)
	if !strings.Contains(string(saved), "pendingDiagnose") {
		t.Fatalf("the unfinished request must survive the restart: %s", saved)
	}

	h.clock.Advance(5 * time.Minute) // asleep, then the scheduled wake starts a new gateway
	server := httptest.NewServer(h.api.handler(t))
	t.Cleanup(server.Close)
	restarted := h.newBot(t, server)
	restarted.Diagnose = func(context.Context) string { return "[잠자기·깨어남]\nDarkWake" }
	restarted.load()
	restarted.resumeDiagnosis(context.Background())
	texts := h.api.texts(42)
	if len(texts) != 2 || !strings.Contains(texts[1], "그 사이 Mac이 잠들어 지금 보냅니다") || !strings.Contains(texts[1], "DarkWake") {
		t.Fatalf("the report must follow after the restart: %v", texts)
	}
	saved, _ = os.ReadFile(h.stateFile)
	if strings.Contains(string(saved), "pendingDiagnose") {
		t.Fatalf("a sent report must clear the mark: %s", saved)
	}
	restarted.resumeDiagnosis(context.Background())
	if len(h.api.texts(42)) != 2 {
		t.Fatal("a sent report must not be sent again")
	}
}

func TestAnOldUnfinishedDiagnosisIsDropped(t *testing.T) {
	h := newHarness(t)
	old := h.clock.Now().Add(-31 * time.Minute)
	h.bot.Diagnose = func(context.Context) string { return "report" }
	h.bot.load()
	h.bot.setPendingDiagnose(&old)
	h.bot.resumeDiagnosis(context.Background())
	if texts := h.api.texts(42); len(texts) != 0 {
		t.Fatalf("a request older than the staleness limit must not be answered: %v", texts)
	}
	saved, _ := os.ReadFile(h.stateFile)
	if strings.Contains(string(saved), "pendingDiagnose") {
		t.Fatalf("the old mark must be cleared: %s", saved)
	}
}

func TestRepeatedDiagnoseRequestsCollectOnce(t *testing.T) {
	h := newHarness(t)
	h.writeStatus(t, func(*health.Snapshot) {})
	collections := 0
	h.bot.Diagnose = func(context.Context) string { collections++; return "report" }
	var deferred []func()
	h.bot.Background = func(work func()) { deferred = append(deferred, work) }
	now := h.clock.Now()
	h.queue(h.message(1, 42, "진단", now), h.message(2, 42, "진단", now), h.message(3, 42, "diag", now))
	if err := h.bot.Poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, work := range deferred {
		work()
	}
	texts := h.api.texts(42)
	if collections != 1 || len(deferred) != 1 {
		t.Fatalf("three requests in one batch must collect once, got %d: %v", collections, texts)
	}
	if !strings.Contains(texts[1], "이미 모으는 중") || !strings.Contains(texts[2], "이미 모으는 중") {
		t.Fatalf("the later requests must be told one is under way: %v", texts)
	}
	if !h.bot.diagnosing.CompareAndSwap(false, true) {
		t.Fatal("the guard must be released after the report")
	}
}

func TestClassifyKeepsDiagnoseApartFromOtherWords(t *testing.T) {
	cases := map[string]command{
		"진단": commandDiagnose, "카메라 진단": commandDiagnose, "diag": commandDiagnose,
		"프로그램 꺼": commandStop, "프로그램 상태": commandStatus, "로그인": commandHelp, "카메라": commandStart,
		"잠자기": commandSleep, "Mac 재워": commandSleep, "sleep": commandSleep, "잠자기 상태": commandStatus,
	}
	for text, expected := range cases {
		if got := classify(text); got != expected {
			t.Errorf("classify(%q) = %d, want %d", text, got, expected)
		}
	}
}

func TestDescribeOriginsLabelsTheHomeAndTheOutsideAddress(t *testing.T) {
	if got := DescribeOrigins([]string{"https://192.168.0.7:8443"}); got != "https://192.168.0.7:8443" {
		t.Fatalf("one origin: %s", got)
	}
	got := DescribeOrigins([]string{"https://192.168.0.7:8443", "https://203.0.113.5:8443", "https://imac.local:8443", "https://cam.example.net"})
	want := "집 Wi-Fi https://192.168.0.7:8443 · 밖에서 https://203.0.113.5:8443 · 집 Wi-Fi https://imac.local:8443 · 밖에서 https://cam.example.net"
	if got != want {
		t.Fatalf("labels:\n got %s\nwant %s", got, want)
	}
}
