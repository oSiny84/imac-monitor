package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"macmonitor.local/gateway/internal/auth"
	"macmonitor.local/gateway/internal/config"
)

func TestRemoteRecordingStartsForTheRequestedHoursAndStopsOnDemand(t *testing.T) {
	directory := t.TempDir()
	demandFile := filepath.Join(directory, "Runtime", "recording-demand.json")
	hash, err := auth.HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{PublicOrigin: "https://camera.example", MediaMTXURL: "http://127.0.0.1:1",
		RecordingsDirectory: directory, PasswordHash: hash, RecordingDemandFile: demandFile,
		SessionIdleMinutes: 30, SessionMaxHours: 24}
	server, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()

	call := func(method, target, body string, cookie *http.Cookie, origin, csrf string) *httptest.ResponseRecorder {
		var reader *strings.Reader
		if body != "" {
			reader = strings.NewReader(body)
		} else {
			reader = strings.NewReader("")
		}
		request := httptest.NewRequest(method, target, reader)
		if origin != "" {
			request.Header.Set("Origin", origin)
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

	if code := call(http.MethodPost, "/api/recording/start", `{"hours":4}`, nil, cfg.PublicOrigin, "x").Code; code != http.StatusUnauthorized {
		t.Fatalf("anonymous start: %d", code)
	}
	if _, err := os.Stat(demandFile); !os.IsNotExist(err) {
		t.Fatal("an anonymous request must not be able to start recording")
	}

	login := call(http.MethodPost, "/api/login", `{"password":"correct horse battery staple"}`, nil, cfg.PublicOrigin, "")
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

	if code := call(http.MethodPost, "/api/recording/start", `{"hours":4}`, cookie, cfg.PublicOrigin, "wrong-token").Code; code != http.StatusForbidden {
		t.Fatalf("bad CSRF: %d", code)
	}
	for _, body := range []string{`{"hours":0}`, `{"hours":25}`, `{"hours":"4"}`, `not json`, ``} {
		if code := call(http.MethodPost, "/api/recording/start", body, cookie, cfg.PublicOrigin, session.CSRF).Code; code != http.StatusBadRequest {
			t.Fatalf("body %q: %d", body, code)
		}
	}
	if _, err := os.Stat(demandFile); !os.IsNotExist(err) {
		t.Fatal("a rejected request wrote the demand file")
	}

	before := time.Now()
	start := call(http.MethodPost, "/api/recording/start", `{"hours":4}`, cookie, cfg.PublicOrigin, session.CSRF)
	if start.Code != http.StatusOK {
		t.Fatalf("valid start: %d %s", start.Code, start.Body.String())
	}
	var started struct {
		Until time.Time `json:"until"`
		Hours int       `json:"hours"`
	}
	if err := json.Unmarshal(start.Body.Bytes(), &started); err != nil {
		t.Fatal(err)
	}
	expected := before.Add(4 * time.Hour)
	if started.Hours != 4 || started.Until.Before(expected.Add(-2*time.Second)) || started.Until.After(expected.Add(2*time.Second)) {
		t.Fatalf("start answered %#v", started)
	}
	raw, err := os.ReadFile(demandFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"schemaVersion":1`) || !strings.Contains(string(raw), `"hours":4`) {
		t.Fatalf("file content: %s", raw)
	}

	status := call(http.MethodGet, "/api/status", "", cookie, "", "")
	if status.Code != http.StatusOK {
		t.Fatalf("status: %d", status.Code)
	}
	var report struct {
		Recording *struct {
			Until time.Time `json:"until"`
			Hours int       `json:"hours"`
		} `json:"recording"`
	}
	if err := json.Unmarshal(status.Body.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if report.Recording == nil || report.Recording.Hours != 4 || !report.Recording.Until.Equal(started.Until) {
		t.Fatalf("status does not show the request: %s", status.Body.String())
	}

	if code := call(http.MethodPost, "/api/recording/stop", "", cookie, cfg.PublicOrigin, "wrong-token").Code; code != http.StatusForbidden {
		t.Fatalf("stop with bad CSRF: %d", code)
	}
	if _, err := os.Stat(demandFile); err != nil {
		t.Fatal("a rejected stop removed the request")
	}
	if code := call(http.MethodPost, "/api/recording/stop", "", cookie, cfg.PublicOrigin, session.CSRF).Code; code != http.StatusNoContent {
		t.Fatalf("stop: %d", code)
	}
	if _, err := os.Stat(demandFile); !os.IsNotExist(err) {
		t.Fatal("stop left the request in place")
	}
	if code := call(http.MethodPost, "/api/recording/stop", "", cookie, cfg.PublicOrigin, session.CSRF).Code; code != http.StatusNoContent {
		t.Fatalf("second stop: %d", code)
	}
	status = call(http.MethodGet, "/api/status", "", cookie, "", "")
	report.Recording = nil
	if err := json.Unmarshal(status.Body.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if report.Recording != nil {
		t.Fatalf("status still shows a stopped request: %s", status.Body.String())
	}
	entries, err := os.ReadDir(filepath.Dir(demandFile))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("files left in the runtime directory: %v", entries)
	}
}
