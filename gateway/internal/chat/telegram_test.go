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
		s.CaptureMode = "scheduled"
		s.Detail = "예약 녹화 중 — Test Camera"
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
	for _, expected := range []string{"상태: 카메라 켜짐 · 예약 녹화", "예약 녹화 중 — Test Camera", "디스크 여유 123.4GB"} {
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
