package speaker

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
)

type call struct {
	stdin string
	line  string
}

type fakeRunner struct {
	mu       sync.Mutex
	calls    []call
	settings string
	voices   string
	fail     map[string]error
	during   func()
}

func (f *fakeRunner) run(_ context.Context, stdin, name string, args ...string) (string, error) {
	f.mu.Lock()
	line := strings.Join(append([]string{name}, args...), " ")
	f.calls = append(f.calls, call{stdin: stdin, line: line})
	f.mu.Unlock()
	for key, err := range f.fail {
		if strings.Contains(line, key) {
			return "", err
		}
	}
	switch {
	case strings.Contains(line, "get volume settings"):
		return f.settings, nil
	case name == sayPath && strings.Join(args, " ") == "-v ?":
		return f.voices, nil
	case name == afplayPath || (name == sayPath && f.during != nil):
		if f.during != nil {
			f.during()
		}
	}
	return "", nil
}

func (f *fakeRunner) lines() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	lines := make([]string, len(f.calls))
	for i, c := range f.calls {
		lines[i] = c.line
	}
	return lines
}

const voiceList = `Alex                en_US    # Most people recognize me by my voice.
Kyoko               ja_JP    # こんにちは、私の名前はKyokoです。
Yuna                ko_KR    # 안녕하세요. 제 이름은 유나입니다.
`

func newPlayer(t *testing.T, runner *fakeRunner) *Player {
	player := New("/usr/local/bin/ffmpeg", t.Logf)
	player.TempDir = t.TempDir()
	player.Run = runner.run
	return player
}

func TestSayReadsTheTextOnStdinWithTheKoreanVoiceAndRestoresTheVolume(t *testing.T) {
	runner := &fakeRunner{settings: "35,true\n", voices: voiceList}
	player := newPlayer(t, runner)
	if err := player.Say(context.Background(), "  -rf 밥 먹었어?  ", 80); err != nil {
		t.Fatal(err)
	}
	lines := runner.lines()
	expected := []string{
		"/usr/bin/say -v ?",
		"/usr/bin/osascript -e set s to get volume settings -e return ((output volume of s) as text) & \",\" & ((output muted of s) as text)",
		"/usr/bin/osascript -e set volume output volume 80 without output muted",
		"/usr/bin/say -v Yuna -f -",
		"/usr/bin/osascript -e set volume output volume 35 with output muted",
	}
	if strings.Join(lines, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("commands:\n%s", strings.Join(lines, "\n"))
	}
	if runner.calls[3].stdin != "-rf 밥 먹었어?" {
		t.Fatalf("the text must go in on stdin, trimmed: %q", runner.calls[3].stdin)
	}
	// The voice is looked up once per process.
	if err := player.Say(context.Background(), "또", 80); err != nil {
		t.Fatal(err)
	}
	if count := strings.Count(strings.Join(runner.lines(), "\n"), "say -v ?"); count != 1 {
		t.Fatalf("voice lookups: %d", count)
	}
}

func TestSayWithoutAKoreanVoiceSaysWhereToGetOne(t *testing.T) {
	runner := &fakeRunner{settings: "50,false", voices: "Alex                en_US    # hi\n"}
	player := newPlayer(t, runner)
	if err := player.Say(context.Background(), "안녕", 50); !errors.Is(err, ErrNoVoice) {
		t.Fatalf("error: %v", err)
	}
	// Installed afterwards: found without a restart.
	runner.voices = voiceList
	if err := player.Say(context.Background(), "안녕", 50); err != nil {
		t.Fatal(err)
	}
}

func TestSayRejectsBadInput(t *testing.T) {
	player := newPlayer(t, &fakeRunner{settings: "50,false", voices: voiceList})
	for _, test := range []struct {
		text   string
		volume int
	}{{"", 50}, {"   ", 50}, {strings.Repeat("가", MaxTextRunes+1), 50}, {"안녕", 0}, {"안녕", 101}} {
		if err := player.Say(context.Background(), test.text, test.volume); err == nil {
			t.Fatalf("accepted %d runes at volume %d", len([]rune(test.text)), test.volume)
		}
	}
}

func TestPlayClipDecodesPlaysAndCleansUp(t *testing.T) {
	runner := &fakeRunner{settings: "20,false"}
	player := newPlayer(t, runner)
	if err := player.PlayClip(context.Background(), []byte("opus data"), 70); err != nil {
		t.Fatal(err)
	}
	lines := runner.lines()
	if len(lines) != 5 || !strings.HasPrefix(lines[0], "/usr/local/bin/ffmpeg -hide_banner -loglevel error -nostdin -y -i ") ||
		!strings.Contains(lines[0], " -t 60 -vn -ac 1 -ar 44100 ") || !strings.HasSuffix(lines[0], "clip.wav") ||
		lines[2] != "/usr/bin/osascript -e set volume output volume 70 without output muted" ||
		!strings.HasPrefix(lines[3], "/usr/bin/afplay ") || !strings.HasSuffix(lines[3], "clip.wav") ||
		lines[4] != "/usr/bin/osascript -e set volume output volume 20 without output muted" {
		t.Fatalf("commands:\n%s", strings.Join(lines, "\n"))
	}
	entries, err := os.ReadDir(player.TempDir)
	if err != nil || len(entries) != 0 {
		t.Fatalf("the clip was left behind: %v %v", entries, err)
	}
}

func TestPlayClipRejectsWhatItCannotPlay(t *testing.T) {
	player := newPlayer(t, &fakeRunner{settings: "50,false"})
	if err := player.PlayClip(context.Background(), nil, 50); err == nil {
		t.Fatal("an empty clip was accepted")
	}
	if err := player.PlayClip(context.Background(), make([]byte, MaxClipBytes+1), 50); err == nil {
		t.Fatal("an oversized clip was accepted")
	}
	player.FFmpeg = ""
	if err := player.PlayClip(context.Background(), []byte("x"), 50); !errors.Is(err, ErrNoFFmpeg) {
		t.Fatalf("error: %v", err)
	}
}

func TestOneSoundAtATime(t *testing.T) {
	runner := &fakeRunner{settings: "50,false", voices: voiceList}
	player := newPlayer(t, runner)
	var second error
	runner.during = func() {
		runner.during = nil
		second = player.Say(context.Background(), "끼어들기", 50)
	}
	if err := player.PlayClip(context.Background(), []byte("x"), 50); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(second, ErrBusy) {
		t.Fatalf("a second sound while playing: %v", second)
	}
	if err := player.Say(context.Background(), "이제 됨", 50); err != nil {
		t.Fatalf("after the first ended: %v", err)
	}
}

func TestUnreadableVolumePlaysWithoutTouchingIt(t *testing.T) {
	runner := &fakeRunner{settings: "missing value,false", voices: voiceList}
	player := newPlayer(t, runner)
	if err := player.Say(context.Background(), "안녕", 50); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.Join(runner.lines(), "\n"), "set volume") {
		t.Fatalf("the volume was changed although it could not be read back: %v", runner.lines())
	}
}

func TestPlaybackFailureStillRestoresTheVolume(t *testing.T) {
	runner := &fakeRunner{settings: "40,false", fail: map[string]error{"afplay": errors.New("afplay: exit status 1")}}
	player := newPlayer(t, runner)
	if err := player.PlayClip(context.Background(), []byte("x"), 90); err == nil {
		t.Fatal("the failure was not reported")
	}
	lines := runner.lines()
	if lines[len(lines)-1] != "/usr/bin/osascript -e set volume output volume 40 without output muted" {
		t.Fatalf("not restored: %v", lines)
	}
}

func TestPickKoreanVoice(t *testing.T) {
	if got := PickKoreanVoice(voiceList); got != "Yuna" {
		t.Fatalf("got %q", got)
	}
	if got := PickKoreanVoice("Siri Female        ko_KR    # 안녕\n"); got != "Siri Female" {
		t.Fatalf("a name with a space: %q", got)
	}
	if got := PickKoreanVoice(""); got != "" {
		t.Fatalf("got %q", got)
	}
}
