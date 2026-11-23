package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"macmonitor.local/gateway/internal/auth"
	"macmonitor.local/gateway/internal/config"
	"macmonitor.local/gateway/internal/speaker"
)

type fakeTalker struct {
	clips   [][]byte
	volumes []int
	err     error
}

func (f *fakeTalker) PlayClip(_ context.Context, data []byte, volume int) error {
	if f.err != nil {
		return f.err
	}
	f.clips = append(f.clips, data)
	f.volumes = append(f.volumes, volume)
	return nil
}

func TestTalkPlaysAnAuthenticatedClipAtTheChosenVolume(t *testing.T) {
	directory := t.TempDir()
	hash, err := auth.HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{PublicOrigin: "https://camera.example", MediaMTXURL: "http://127.0.0.1:1",
		RecordingsDirectory: directory, PasswordHash: hash, SessionIdleMinutes: 30, SessionMaxHours: 24}
	server, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	call := func(target, contentType, body string, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, target, strings.NewReader(body))
		request.Header.Set("Origin", cfg.PublicOrigin)
		if contentType != "" {
			request.Header.Set("Content-Type", contentType)
		}
		if csrf != "" {
			request.Header.Set("X-CSRF-Token", csrf)
		}
		if cookie != nil {
			request.AddCookie(cookie)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}

	if code := call("/api/talk?volume=50", "audio/webm", "clip", nil, "x").Code; code != http.StatusUnauthorized {
		t.Fatalf("anonymous: %d", code)
	}
	login := call("/api/login", "application/json", `{"password":"correct horse battery staple"}`, nil, "")
	if login.Code != http.StatusOK {
		t.Fatalf("login: %d", login.Code)
	}
	cookie := login.Result().Cookies()[0]
	var session struct {
		CSRF string `json:"csrfToken"`
	}
	if err := json.Unmarshal(login.Body.Bytes(), &session); err != nil {
		t.Fatal(err)
	}

	if code := call("/api/talk?volume=50", "audio/webm", "clip", cookie, session.CSRF).Code; code != http.StatusServiceUnavailable {
		t.Fatalf("without a player: %d", code)
	}
	talker := &fakeTalker{}
	server.SetTalker(talker)
	if code := call("/api/talk?volume=50", "audio/webm", "clip", cookie, "wrong").Code; code != http.StatusForbidden {
		t.Fatalf("bad CSRF: %d", code)
	}
	for _, test := range []struct {
		target, contentType, body string
		code                      int
	}{
		{"/api/talk?volume=50", "application/json", "clip", http.StatusUnsupportedMediaType},
		{"/api/talk?volume=50", "", "clip", http.StatusUnsupportedMediaType},
		{"/api/talk", "audio/webm", "clip", http.StatusBadRequest},
		{"/api/talk?volume=0", "audio/webm", "clip", http.StatusBadRequest},
		{"/api/talk?volume=101", "audio/webm", "clip", http.StatusBadRequest},
		{"/api/talk?volume=50", "audio/webm", "", http.StatusBadRequest},
		{"/api/talk?volume=50", "audio/webm", strings.Repeat("x", speaker.MaxClipBytes+1), http.StatusRequestEntityTooLarge},
	} {
		if code := call(test.target, test.contentType, test.body, cookie, session.CSRF).Code; code != test.code {
			t.Fatalf("%s %q (%d bytes): %d, want %d", test.target, test.contentType, len(test.body), code, test.code)
		}
	}
	if len(talker.clips) != 0 {
		t.Fatal("a rejected request reached the speaker")
	}

	for _, contentType := range []string{"audio/webm;codecs=opus", "audio/mp4", "video/webm"} {
		if response := call("/api/talk?volume=75", contentType, "clip", cookie, session.CSRF); response.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", contentType, response.Code, response.Body.String())
		}
	}
	if len(talker.clips) != 3 || string(talker.clips[0]) != "clip" || talker.volumes[2] != 75 {
		t.Fatalf("played: %q %v", talker.clips, talker.volumes)
	}

	talker.err = speaker.ErrBusy
	if code := call("/api/talk?volume=75", "audio/mp4", "clip", cookie, session.CSRF).Code; code != http.StatusConflict {
		t.Fatalf("busy: %d", code)
	}
	talker.err = speaker.ErrNoFFmpeg
	if code := call("/api/talk?volume=75", "audio/mp4", "clip", cookie, session.CSRF).Code; code != http.StatusServiceUnavailable {
		t.Fatalf("no FFmpeg: %d", code)
	}
}

func TestOnlyThePageMayUseTheMicrophone(t *testing.T) {
	hash, err := auth.HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	server, err := New(config.Config{PublicOrigin: "https://camera.example", MediaMTXURL: "http://127.0.0.1:1",
		RecordingsDirectory: t.TempDir(), PasswordHash: hash, SessionIdleMinutes: 30, SessionMaxHours: 24})
	if err != nil {
		t.Fatal(err)
	}
	for path, expected := range map[string]string{
		"/":                     "camera=(), microphone=(self), geolocation=()",
		"/live/live/whep":       "camera=(), microphone=(), geolocation=()",
		"/assets/live.html":     "camera=(), microphone=(self), geolocation=()",
		"/api/session":          "camera=(), microphone=(self), geolocation=()",
		"/live/live-balanced/x": "camera=(), microphone=(), geolocation=()",
	} {
		response := httptest.NewRecorder()
		server.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if got := response.Header().Get("Permissions-Policy"); got != expected {
			t.Fatalf("%s: %q", path, got)
		}
	}
}
