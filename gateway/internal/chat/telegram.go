package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"macmonitor.local/gateway/internal/health"
)

// DefaultAPIBase is Telegram's Bot API host. Tests point APIBase at an httptest server.
const DefaultAPIBase = "https://api.telegram.org"

// ErrConflict is Telegram's 409: another process is long-polling the same bot token.
var ErrConflict = errors.New("another process is already polling this bot token")

const helpText = "명령: 카메라 (켜고 링크 받기) · 그만 (요청 끝내기) · 상태 (앱 상태 보기) · 진단 (잠자기·카메라 기록 보기) · 잠자기 (Mac 재우기)"

// Telegram refuses messages over 4096 characters; leave room for the part marker.
const maxMessageRunes = 3900

// Bot turns messages from one Telegram chat into the viewer lease the web page renews. The app
// only sees the lease change, so a chat request and a browser tab are the same thing to it.
type Bot struct {
	Config     Config
	Origin     string
	DemandFile string
	StatusFile string
	StateFile  string

	// Production defaults come from New; tests override them.
	APIBase string
	Client  *http.Client
	Now     func() time.Time
	Sleep   func(context.Context, time.Duration)
	Logf    func(string, ...any)
	// Reports when a web viewer last renewed the live lease; nil when the gateway has no server.
	ViewerSeen func() time.Time
	// Collects the sleep/wake and camera diagnostics; nil when the gateway has none.
	Diagnose func(context.Context) string
	// Puts the Mac to sleep; nil when the gateway cannot.
	SleepMac func(context.Context) error
	// The window closes this long after the last web viewer renewal, or this long after it
	// opened when no viewer ever came.
	ViewerGone      time.Duration
	NoViewerTimeout time.Duration
	Background      func(func())
	PollTimeout     time.Duration
	RenewEvery      time.Duration
	StartupTimeout  time.Duration
	StalenessLimit  time.Duration
	// A sleep request older than this was sent while the Mac slept and is dropped, so the
	// wake that delivers it does not send the Mac straight back to sleep.
	SleepStaleness time.Duration
	// Time between the reply and the sleep, so the reply and the update offset get out first.
	SleepDelay time.Duration

	mu     sync.Mutex
	loaded bool
	state  state
	// Set while one diagnostics report is being collected and sent.
	diagnosing atomic.Bool
}

// state survives the gateway restarts that every sleep/wake cycle causes. Without the offset
// each wake would replay the same commands; without the window a restart would drop the camera.
type state struct {
	Offset          int64      `json:"offset"`
	WindowUntil     *time.Time `json:"windowUntil,omitempty"`
	WindowStartedAt *time.Time `json:"windowStartedAt,omitempty"`
	// A 진단 request whose report was not fully sent: the app stops the gateway before every
	// sleep, so a report cut off by sleep is sent again after the next start.
	PendingDiagnose *time.Time `json:"pendingDiagnose,omitempty"`
}

type command int

const (
	commandHelp command = iota
	commandStart
	commandStop
	commandStatus
	commandDiagnose
	commandSleep
)

type update struct {
	ID      int64    `json:"update_id"`
	Message *message `json:"message"`
}

type message struct {
	Date int64 `json:"date"`
	Chat struct {
		ID int64 `json:"id"`
	} `json:"chat"`
	Text string `json:"text"`
}

type apiResponse struct {
	OK          bool            `json:"ok"`
	Result      json.RawMessage `json:"result"`
	ErrorCode   int             `json:"error_code"`
	Description string          `json:"description"`
}

func New(config Config, origin, demandFile, statusFile, stateFile string) *Bot {
	return &Bot{
		Config:     config,
		Origin:     origin,
		DemandFile: demandFile,
		StatusFile: statusFile,
		StateFile:  stateFile,
		APIBase:    DefaultAPIBase,
		// Longer than the long-poll wait, so a healthy poll never times out on the client side.
		Client:          &http.Client{Timeout: 40 * time.Second},
		Now:             time.Now,
		Sleep:           sleepContext,
		Logf:            log.Printf,
		ViewerGone:      90 * time.Second,
		NoViewerTimeout: 3 * time.Minute,
		Background:      func(work func()) { go work() },
		PollTimeout:     25 * time.Second,
		RenewEvery:      5 * time.Second,
		StartupTimeout:  60 * time.Second,
		StalenessLimit:  30 * time.Minute,
		SleepStaleness:  2 * time.Minute,
		SleepDelay:      3 * time.Second,
	}
}

// Run polls until the context ends. Network loss after a wake is normal, so errors back off
// instead of stopping the bot.
func (b *Bot) Run(ctx context.Context) {
	b.load()
	b.Logf("telegram: bot started for chat %d", b.Config.ChatID)
	b.resumeDiagnosis(ctx)
	go b.renewLoop(ctx)
	backoff := time.Second
	for ctx.Err() == nil {
		err := b.Poll(ctx)
		switch {
		case err == nil:
			backoff = time.Second
			// Telegram holds a long poll open; without one, pause so an idle bot cannot spin.
			if b.PollTimeout <= 0 {
				b.Sleep(ctx, time.Second)
			}
		case ctx.Err() != nil:
			return
		case errors.Is(err, ErrConflict):
			b.Logf("telegram: %v; retrying in 30s", err)
			b.Sleep(ctx, 30*time.Second)
		default:
			b.Logf("telegram: %v", err)
			b.Sleep(ctx, backoff)
			if backoff < time.Minute {
				backoff *= 2
			}
		}
	}
}

// Poll fetches one batch of updates and handles each. Run loops over it; tests call it directly.
func (b *Bot) Poll(ctx context.Context) error {
	b.load()
	b.mu.Lock()
	offset := b.state.Offset
	b.mu.Unlock()
	request := map[string]any{
		"offset":          offset,
		"timeout":         int(b.PollTimeout / time.Second),
		"allowed_updates": []string{"message"},
	}
	var updates []update
	if err := b.call(ctx, "getUpdates", request, &updates); err != nil {
		return err
	}
	for _, item := range updates {
		b.handle(ctx, item)
	}
	return nil
}

func (b *Bot) handle(ctx context.Context, item update) {
	// Confirm the update whatever it was, so an ignored message is never fetched again.
	defer b.advance(item.ID)
	msg := item.Message
	if msg == nil || msg.Text == "" {
		return
	}
	if msg.Chat.ID != b.Config.ChatID {
		// The id is what the owner needs to find in the log; the text is somebody else's.
		b.Logf("telegram: ignored a message from chat %d", msg.Chat.ID)
		return
	}
	now := b.Now()
	switch classify(msg.Text) {
	case commandStatus:
		b.reply(ctx, b.statusText(now))
	case commandDiagnose:
		// Read-only, so a request queued while the Mac slept is still worth answering on wake.
		if b.Diagnose == nil {
			b.reply(ctx, "이 게이트웨이에는 진단 기능이 없습니다.")
			return
		}
		// Several requests sent while the Mac slept arrive in one batch; collect once.
		if !b.diagnosing.CompareAndSwap(false, true) {
			b.reply(ctx, "진단을 이미 모으는 중입니다. 곧 답장이 갑니다.")
			return
		}
		b.setPendingDiagnose(&now)
		b.reply(ctx, "진단을 모읍니다 · 30초쯤 걸립니다. 그 전에 Mac이 잠들면 다음에 깨어날 때 보냅니다.")
		b.Background(func() { b.sendDiagnosis(ctx, "") })
	case commandSleep:
		if b.SleepMac == nil {
			b.reply(ctx, "이 게이트웨이에는 잠자기 기능이 없습니다.")
			return
		}
		if age := now.Sub(time.Unix(msg.Date, 0)); age > b.SleepStaleness {
			b.reply(ctx, fmt.Sprintf("%d분 전에 보낸 잠자기 요청이라 무시했습니다. 지금 재우려면 다시 보내세요.", int(age.Minutes())))
			return
		}
		// An open view window would keep the camera wanted, and the app holds the Mac awake for it.
		b.setWindow(nil)
		b.reply(ctx, "Mac을 재웁니다. 깨어날 때까지 명령에 답하지 못합니다. 슬림 모드가 꺼져 있으면 macOS가 스스로 깰 때(길게는 2시간 뒤) 답합니다.")
		b.Background(func() {
			b.Sleep(ctx, b.SleepDelay)
			if err := b.SleepMac(ctx); err != nil {
				b.Logf("telegram: sleep request failed: %v", err)
				b.reply(ctx, "Mac을 재우지 못했습니다: "+err.Error())
			}
		})
	case commandStop:
		b.setWindow(nil)
		b.reply(ctx, "카메라 요청을 끝냈습니다. 웹에서 보고 있는 사람이 없으면 약 20초 뒤 카메라가 꺼집니다.")
	case commandStart:
		// A Mac that was off for hours must not turn its camera on for a request from this morning.
		if age := now.Sub(time.Unix(msg.Date, 0)); age > b.StalenessLimit {
			b.reply(ctx, fmt.Sprintf("%d분 전에 보낸 요청이라 무시했습니다. 지금 보려면 다시 보내세요.", int(age.Minutes())))
			return
		}
		until := now.Add(b.Config.ViewWindow())
		b.setWindow(&until)
		b.renewOnce(now)
		b.reply(ctx, fmt.Sprintf("카메라를 켭니다 · %s · %d분 동안 유지합니다. 끄려면 '그만'이라고 보내세요.", b.Origin, b.Config.ViewMinutes))
		b.Background(func() { b.reply(ctx, b.confirmCameraStart(ctx, now)) })
	default:
		b.reply(ctx, helpText)
	}
}

// DescribeOrigins writes the web addresses for a reply. With more than one, each is labelled so
// the owner can tell the home Wi-Fi address from the one that works outside.
func DescribeOrigins(origins []string) string {
	if len(origins) == 1 {
		return origins[0]
	}
	parts := make([]string, 0, len(origins))
	for _, origin := range origins {
		label := "밖에서"
		if parsed, err := url.Parse(origin); err == nil && isHomeAddress(parsed.Hostname()) {
			label = "집 Wi-Fi"
		}
		parts = append(parts, label+" "+origin)
	}
	return strings.Join(parts, " · ")
}

func isHomeAddress(host string) bool {
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast()
	}
	return strings.HasSuffix(strings.ToLower(host), ".local")
}

// classify reads intent from a few words so the owner need not remember exact commands.
// Diagnose, status and stop are checked first: "카메라 진단" and "카메라 상태" ask, "카메라 꺼" ends.
// Sleep comes before stop and start so that "Mac 꺼" style words never decide it.
func classify(text string) command {
	lowered := strings.ToLower(strings.TrimSpace(text))
	has := func(words ...string) bool {
		for _, word := range words {
			if strings.Contains(lowered, word) {
				return true
			}
		}
		return false
	}
	switch {
	case has("진단", "diag"):
		return commandDiagnose
	case has("상태", "status"):
		return commandStatus
	case has("잠자", "재워", "재우", "sleep"):
		return commandSleep
	case has("그만", "꺼", "중지", "stop", "off", "끝"):
		return commandStop
	case has("카메라", "보여", "켜", "영상", "live", "cam", "video", "보고"):
		return commandStart
	}
	return commandHelp
}

// confirmCameraStart watches the app's status file so the owner learns whether the camera
// actually came on without opening the page.
func (b *Bot) confirmCameraStart(ctx context.Context, requestedAt time.Time) string {
	deadline := requestedAt.Add(b.StartupTimeout)
	for {
		now := b.Now()
		status := health.Read(b.StatusFile, now)
		if status.Fresh && status.State == "running" && status.FrameState == "receiving" {
			return fmt.Sprintf("카메라가 켜졌습니다 (%d초) · %s", int(now.Sub(requestedAt).Seconds()), b.Origin)
		}
		if status.Fresh && status.State == "failed" {
			return "카메라를 켜지 못했습니다 · " + status.Detail + " · 요청이 유지되는 동안 앱이 약 30초마다 다시 시도합니다."
		}
		if !now.Before(deadline) || ctx.Err() != nil {
			return fmt.Sprintf("%d초 안에 카메라가 켜지지 않았습니다 · 현재 상태: %s", int(b.StartupTimeout.Seconds()), describe(status))
		}
		b.Sleep(ctx, 2*time.Second)
	}
}

func (b *Bot) statusText(now time.Time) string {
	status := health.Read(b.StatusFile, now)
	label := describe(status)
	text := "상태: " + label
	if status.Available {
		// The app's detail often starts with the same words as the label; say them once.
		if detail := strings.TrimPrefix(status.Detail, stateLabel(status.State)+" · "); detail != "" && detail != stateLabel(status.State) {
			text += " · " + detail
		}
		if status.SlimDetail != "" {
			text += " · 슬림: " + status.SlimDetail
		}
		if status.Audio == "unavailable" {
			text += " · 소리 없음"
			if status.AudioDetail != "" {
				text += " (" + status.AudioDetail + ")"
			}
		}
		if status.DiskFreeBytes != nil {
			text += fmt.Sprintf(" · 디스크 여유 %.1fGB", float64(*status.DiskFreeBytes)/1e9)
		}
	}
	b.mu.Lock()
	until := b.state.WindowUntil
	b.mu.Unlock()
	if until != nil && now.Before(*until) {
		text += fmt.Sprintf(" · 채팅 시청 요청 %d분 남음", int(until.Sub(now).Minutes())+1)
	}
	return text
}

var stateLabels = map[string]string{
	"running": "카메라 켜짐", "starting": "카메라 시작 중", "stopped": "카메라 꺼짐", "stopping": "카메라 정리 중",
	"standby": "원격 대기 중", "scheduledRest": "예약 휴식 중", "sleeping": "시스템 잠자기",
	"recovering": "카메라 복구 중", "failed": "카메라 오류", "stale": "앱 상태 갱신 지연",
}

func stateLabel(state string) string {
	if label, ok := stateLabels[state]; ok {
		return label
	}
	return "상태 확인 불가"
}

// describe mirrors the labels the web page shows for the same states.
func describe(status health.Status) string {
	label := stateLabel(status.State)
	switch status.CaptureMode {
	case "timed":
		label += " · 원격 녹화"
	case "live":
		label += " · 실시간만"
	}
	return label
}

// sendDiagnosis collects one report and sends it in parts. The pending mark is cleared only
// when every part went out, so a report cut off by sleep or a network error is sent again.
func (b *Bot) sendDiagnosis(ctx context.Context, note string) {
	defer b.diagnosing.Store(false)
	report := "진단 · " + b.Now().Format("01-02 15:04:05") + " 기준\n"
	if note != "" {
		report += note + "\n"
	}
	report += b.statusText(b.Now()) + "\n\n" + b.Diagnose(ctx)
	parts := splitMessage(b.redact(report), maxMessageRunes)
	for index, part := range parts {
		if len(parts) > 1 {
			part = fmt.Sprintf("(%d/%d) ", index+1, len(parts)) + part
		}
		if err := b.send(ctx, part); err != nil {
			b.Logf("telegram: diagnostics reply failed, will resend after the next start: %v", err)
			return
		}
	}
	b.setPendingDiagnose(nil)
}

// resumeDiagnosis sends a report that the previous gateway accepted but did not finish.
func (b *Bot) resumeDiagnosis(ctx context.Context) {
	b.mu.Lock()
	pending := b.state.PendingDiagnose
	b.mu.Unlock()
	if pending == nil || b.Diagnose == nil {
		return
	}
	if b.Now().Sub(*pending) > b.StalenessLimit {
		b.setPendingDiagnose(nil)
		return
	}
	if !b.diagnosing.CompareAndSwap(false, true) {
		return
	}
	note := pending.Format("15:04") + "에 받은 진단 요청입니다. 그 사이 Mac이 잠들어 지금 보냅니다."
	b.Background(func() { b.sendDiagnosis(ctx, note) })
}

func (b *Bot) setPendingDiagnose(at *time.Time) {
	b.mu.Lock()
	b.state.PendingDiagnose = at
	b.persistLocked()
	b.mu.Unlock()
}

// splitMessage cuts text into parts of at most limit runes, at line ends where it can.
func splitMessage(text string, limit int) []string {
	var parts []string
	var current []rune
	for _, line := range strings.SplitAfter(text, "\n") {
		runes := []rune(line)
		for len(runes) > limit {
			if len(current) > 0 {
				parts = append(parts, strings.TrimRight(string(current), "\n"))
				current = nil
			}
			parts = append(parts, string(runes[:limit]))
			runes = runes[limit:]
		}
		if len(current)+len(runes) > limit {
			if flushed := strings.TrimRight(string(current), "\n"); flushed != "" {
				parts = append(parts, flushed)
			}
			current = nil
		}
		current = append(current, runes...)
	}
	if rest := strings.TrimRight(string(current), "\n"); rest != "" {
		parts = append(parts, rest)
	}
	return parts
}

func (b *Bot) reply(ctx context.Context, text string) {
	if err := b.send(ctx, text); err != nil {
		b.Logf("telegram: reply failed: %v", err)
	}
}

func (b *Bot) send(ctx context.Context, text string) error {
	payload := map[string]any{"chat_id": b.Config.ChatID, "text": text, "disable_web_page_preview": true}
	return b.call(ctx, "sendMessage", payload, nil)
}

func (b *Bot) call(ctx context.Context, method string, payload any, result any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, b.APIBase+"/bot"+b.Config.BotToken+"/"+method, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("telegram %s: %s", method, b.redact(err.Error()))
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := b.Client.Do(request)
	if err != nil {
		// Transport errors quote the URL, and the URL carries the token.
		return fmt.Errorf("telegram %s: %s", method, b.redact(err.Error()))
	}
	defer response.Body.Close()
	var envelope apiResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&envelope); err != nil {
		return fmt.Errorf("telegram %s: unreadable response (HTTP %d)", method, response.StatusCode)
	}
	if !envelope.OK {
		if envelope.ErrorCode == http.StatusConflict {
			return ErrConflict
		}
		return fmt.Errorf("telegram %s: %d %s", method, envelope.ErrorCode, b.redact(envelope.Description))
	}
	if result != nil && len(envelope.Result) > 0 {
		return json.Unmarshal(envelope.Result, result)
	}
	return nil
}

func (b *Bot) redact(text string) string {
	if b.Config.BotToken == "" {
		return text
	}
	return strings.ReplaceAll(text, b.Config.BotToken, "<token>")
}

func (b *Bot) renewLoop(ctx context.Context) {
	ticker := time.NewTicker(b.RenewEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			b.renewOnce(b.Now())
		}
	}
}

// renewOnce rewrites the lease while a chat request is open. The app reacts to the content
// changing, so each write carries the current time.
func (b *Bot) renewOnce(now time.Time) {
	b.mu.Lock()
	until := b.state.WindowUntil
	started := b.state.WindowStartedAt
	expired := until != nil && !now.Before(*until)
	if expired {
		b.state.WindowUntil = nil
		b.persistLocked()
	}
	b.mu.Unlock()
	if until == nil {
		return
	}
	if expired {
		b.Logf("telegram: viewing request ended")
		return
	}
	// The window exists to bring the camera up until the owner opens the link. Once a web
	// viewer has renewed the lease and then left, or when nobody opened it at all, the
	// window has done its job; keeping the camera on would also keep a slim-mode Mac awake.
	if b.ViewerSeen != nil && started != nil {
		seen := b.ViewerSeen()
		viewerCame := !seen.IsZero() && seen.After(*started)
		if viewerCame && now.Sub(seen) > b.ViewerGone {
			b.setWindow(nil)
			b.Logf("telegram: viewing request ended, the web viewer left")
			b.reply(context.Background(), "웹 시청이 끝나 카메라 요청을 끝냈습니다. 다시 보려면 '카메라'라고 보내세요.")
			return
		}
		if !viewerCame && now.Sub(*started) > b.NoViewerTimeout {
			b.setWindow(nil)
			b.Logf("telegram: viewing request ended, nobody opened the link")
			b.reply(context.Background(), fmt.Sprintf("%d분 동안 아무도 열지 않아 카메라 요청을 끝냈습니다. 다시 보려면 '카메라'라고 보내세요.", int(b.NoViewerTimeout.Minutes())))
			return
		}
	}
	if err := health.RecordLiveDemand(b.DemandFile, now); err != nil {
		b.Logf("telegram: lease write failed: %v", err)
	}
}

func (b *Bot) setWindow(until *time.Time) {
	b.mu.Lock()
	b.state.WindowUntil = until
	b.state.WindowStartedAt = nil
	if until != nil {
		started := b.Now()
		b.state.WindowStartedAt = &started
	}
	b.persistLocked()
	b.mu.Unlock()
}

func (b *Bot) advance(id int64) {
	b.mu.Lock()
	if id+1 > b.state.Offset {
		b.state.Offset = id + 1
		b.persistLocked()
	}
	b.mu.Unlock()
}

func (b *Bot) load() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.loaded {
		return
	}
	b.loaded = true
	if b.StateFile == "" {
		return
	}
	data, err := os.ReadFile(b.StateFile)
	if err != nil {
		return
	}
	var saved state
	if json.Unmarshal(data, &saved) == nil {
		b.state = saved
	}
}

// Called with the lock held.
func (b *Bot) persistLocked() {
	if b.StateFile == "" {
		return
	}
	data, err := json.Marshal(b.state)
	if err != nil {
		return
	}
	if err := writeAtomic(b.StateFile, data); err != nil {
		b.Logf("telegram: state write failed: %v", err)
	}
}

func writeAtomic(path string, data []byte) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".telegram-state-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Chmod(temporary.Name(), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), path)
}

func sleepContext(ctx context.Context, duration time.Duration) {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
}

// Supervise keeps one bot running for the configuration file at path, restarting it when the
// file appears, changes or disappears. The setup script therefore needs no gateway restart,
// and a removed file stops the bot. The file is small, so its content is the change key; a
// modification time can move without the content changing and must not restart the bot.
func Supervise(ctx context.Context, path string, interval time.Duration, build func(Config) *Bot, logf func(string, ...any)) {
	var cancel context.CancelFunc
	var lastKey, lastError string
	check := func() {
		key := ""
		if data, err := os.ReadFile(path); err == nil {
			key = "file:" + string(data)
		}
		if key == lastKey {
			return
		}
		lastKey = key
		if cancel != nil {
			cancel()
			cancel = nil
			logf("telegram: bot stopped")
		}
		if key == "" {
			lastError = ""
			return
		}
		cfg, err := LoadConfig(path)
		if err != nil {
			if err.Error() != lastError {
				lastError = err.Error()
				logf("telegram: configuration not used: %v", err)
			}
			return
		}
		lastError = ""
		var child context.Context
		child, cancel = context.WithCancel(ctx)
		go build(cfg).Run(child)
	}
	check()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			if cancel != nil {
				cancel()
			}
			return
		case <-ticker.C:
			check()
		}
	}
}
