// Package speaker plays what the owner sends on the Mac's speakers: a clip recorded on the
// web page, or text that macOS reads aloud. One sound plays at a time.
package speaker

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

const (
	// MaxClipBytes bounds an upload. A minute of Opus or AAC from a phone is well under it.
	MaxClipBytes = 2 << 20
	// MaxClipSeconds bounds what is decoded and played from one clip.
	MaxClipSeconds = 60
	// MaxTextRunes bounds one message read aloud.
	MaxTextRunes = 300
	// DefaultVolume is the output volume used when the owner has not chosen one.
	DefaultVolume = 60

	afplayPath    = "/usr/bin/afplay"
	sayPath       = "/usr/bin/say"
	osascriptPath = "/usr/bin/osascript"
)

var (
	ErrBusy     = errors.New("다른 음성을 재생하고 있습니다. 끝난 뒤 다시 보내세요")
	ErrNoFFmpeg = errors.New("FFmpeg를 찾지 못해 녹음을 재생할 수 없습니다")
	ErrNoVoice  = errors.New("Mac에 한국어 목소리가 없습니다. 시스템 환경설정 → 손쉬운 사용 → 음성 콘텐츠 → 시스템 음성에서 Yuna를 내려받으세요")
)

// Runner runs one command with stdin and returns its combined output.
type Runner func(ctx context.Context, stdin, name string, args ...string) (string, error)

type Player struct {
	// FFmpeg decodes uploaded clips; empty when it was not found.
	FFmpeg  string
	TempDir string
	Run     Runner
	Logf    func(string, ...any)

	busy  atomic.Bool
	mu    sync.Mutex
	voice string
}

func New(ffmpeg string, logf func(string, ...any)) *Player {
	return &Player{FFmpeg: ffmpeg, TempDir: os.TempDir(), Run: runCommand, Logf: logf}
}

func ValidVolume(volume int) bool { return volume >= 1 && volume <= 100 }

// PlayClip decodes a recorded clip to WAV and plays it.
func (p *Player) PlayClip(ctx context.Context, data []byte, volume int) error {
	if !ValidVolume(volume) {
		return fmt.Errorf("음량은 1~100이어야 합니다")
	}
	if len(data) == 0 {
		return fmt.Errorf("녹음이 비어 있습니다")
	}
	if len(data) > MaxClipBytes {
		return fmt.Errorf("녹음이 너무 깁니다 (최대 %d초)", MaxClipSeconds)
	}
	if p.FFmpeg == "" {
		return ErrNoFFmpeg
	}
	if !p.busy.CompareAndSwap(false, true) {
		return ErrBusy
	}
	defer p.busy.Store(false)

	directory, err := os.MkdirTemp(p.TempDir, "macmonitor-talk-")
	if err != nil {
		return fmt.Errorf("임시 폴더를 만들지 못했습니다: %w", err)
	}
	defer os.RemoveAll(directory)
	input := filepath.Join(directory, "clip")
	output := filepath.Join(directory, "clip.wav")
	if err := os.WriteFile(input, data, 0o600); err != nil {
		return fmt.Errorf("녹음을 저장하지 못했습니다: %w", err)
	}
	if _, err := p.Run(ctx, "", p.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
		"-i", input, "-t", strconv.Itoa(MaxClipSeconds), "-vn", "-ac", "1", "-ar", "44100", output); err != nil {
		return fmt.Errorf("녹음을 변환하지 못했습니다: %w", err)
	}
	return p.withVolume(ctx, volume, func() error {
		_, err := p.Run(ctx, "", afplayPath, output)
		return err
	})
}

// Say reads text aloud with a Korean voice.
func (p *Player) Say(ctx context.Context, text string, volume int) error {
	text = strings.TrimSpace(text)
	if !ValidVolume(volume) {
		return fmt.Errorf("음량은 1~100이어야 합니다")
	}
	if text == "" {
		return fmt.Errorf("읽을 글이 비어 있습니다")
	}
	if utf8.RuneCountInString(text) > MaxTextRunes {
		return fmt.Errorf("글이 너무 깁니다 (최대 %d자)", MaxTextRunes)
	}
	if !p.busy.CompareAndSwap(false, true) {
		return ErrBusy
	}
	defer p.busy.Store(false)
	voice, err := p.koreanVoice(ctx)
	if err != nil {
		return err
	}
	return p.withVolume(ctx, volume, func() error {
		// The text goes in on stdin, so a message starting with "-" is never read as an option.
		_, err := p.Run(ctx, text, sayPath, "-v", voice, "-f", "-")
		return err
	})
}

var voiceLine = regexp.MustCompile(`^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#`)

// koreanVoice finds an installed ko_KR voice, Yuna first. Only a success is kept, so a voice
// downloaded later is found without restarting.
func (p *Player) koreanVoice(ctx context.Context) (string, error) {
	p.mu.Lock()
	cached := p.voice
	p.mu.Unlock()
	if cached != "" {
		return cached, nil
	}
	output, err := p.Run(ctx, "", sayPath, "-v", "?")
	if err != nil {
		return "", fmt.Errorf("목소리 목록을 읽지 못했습니다: %w", err)
	}
	voice := PickKoreanVoice(output)
	if voice == "" {
		return "", ErrNoVoice
	}
	p.mu.Lock()
	p.voice = voice
	p.mu.Unlock()
	return voice, nil
}

// PickKoreanVoice returns the voice to use from `say -v ?` output, or "" when none is Korean.
func PickKoreanVoice(list string) string {
	found := ""
	for _, line := range strings.Split(list, "\n") {
		match := voiceLine.FindStringSubmatch(strings.TrimSpace(line))
		if match == nil || match[2] != "ko_KR" {
			continue
		}
		name := strings.TrimSpace(match[1])
		if name == "Yuna" {
			return name
		}
		if found == "" {
			found = name
		}
	}
	return found
}

// withVolume sets the Mac's output volume, unmuted, for the playback and puts the previous
// setting back afterwards. When the current setting cannot be read (some external outputs
// report no volume) it plays without touching it.
func (p *Player) withVolume(ctx context.Context, volume int, play func() error) error {
	output, err := p.Run(ctx, "", osascriptPath, "-e", "set s to get volume settings",
		"-e", `return ((output volume of s) as text) & "," & ((output muted of s) as text)`)
	previous, muted, ok := parseVolumeSettings(output)
	if err != nil || !ok {
		p.logf("speaker: output volume unreadable (%v, %q); playing without changing it", err, strings.TrimSpace(output))
		return play()
	}
	if _, err := p.Run(ctx, "", osascriptPath, "-e", fmt.Sprintf("set volume output volume %d without output muted", volume)); err != nil {
		p.logf("speaker: setting the output volume failed: %v", err)
	}
	defer func() {
		// Restore even when the request was cancelled mid-play.
		restoreCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		state := "without"
		if muted {
			state = "with"
		}
		if _, err := p.Run(restoreCtx, "", osascriptPath, "-e", fmt.Sprintf("set volume output volume %d %s output muted", previous, state)); err != nil {
			p.logf("speaker: restoring the output volume failed: %v", err)
		}
	}()
	return play()
}

func parseVolumeSettings(output string) (int, bool, bool) {
	parts := strings.Split(strings.TrimSpace(output), ",")
	if len(parts) != 2 {
		return 0, false, false
	}
	volume, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil || volume < 0 || volume > 100 {
		return 0, false, false
	}
	switch strings.TrimSpace(parts[1]) {
	case "true":
		return volume, true, true
	case "false":
		return volume, false, true
	}
	return 0, false, false
}

func (p *Player) logf(format string, args ...any) {
	if p.Logf != nil {
		p.Logf(format, args...)
	}
}

func runCommand(ctx context.Context, stdin, name string, args ...string) (string, error) {
	command := exec.CommandContext(ctx, name, args...)
	if stdin != "" {
		command.Stdin = strings.NewReader(stdin)
	}
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	err := command.Run()
	text := output.String()
	if err != nil {
		detail := strings.TrimSpace(text)
		if utf8.RuneCountInString(detail) > 200 {
			detail = string([]rune(detail)[:200]) + "…"
		}
		return text, fmt.Errorf("%s: %w: %s", filepath.Base(name), err, detail)
	}
	return text, nil
}
