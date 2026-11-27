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
	"macmonitor.local/gateway/internal/diag"
)

type fakeDiagnostics struct {
	ran     []string
	release chan struct{}
}

func (f *fakeDiagnostics) Checks() []diag.Check {
	return []diag.Check{{ID: "idle", Title: "입력", Command: "ioreg"}}
}

func (f *fakeDiagnostics) RunCheck(_ context.Context, id string) (string, error) {
	if f.release != nil {
		<-f.release
	}
	if id != "idle" {
		return "", diag.ErrUnknownCheck
	}
	f.ran = append(f.ran, id)
	return "마지막 입력 뒤 3s", nil
}

func TestDiagnosticsNeedALoginCSRFAndAKnownID(t *testing.T) {
	hash, err := auth.HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{PublicOrigin: "https://camera.example", MediaMTXURL: "http://127.0.0.1:1",
		RecordingsDirectory: t.TempDir(), PasswordHash: hash, SessionIdleMinutes: 30, SessionMaxHours: 24}
	server, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	call := func(method, target, body string, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, target, strings.NewReader(body))
		request.Header.Set("Origin", cfg.PublicOrigin)
		if body != "" {
			request.Header.Set("Content-Type", "application/json")
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

	if code := call(http.MethodGet, "/api/diag/checks", "", nil, "").Code; code != http.StatusUnauthorized {
		t.Fatalf("anonymous list: %d", code)
	}
	if code := call(http.MethodPost, "/api/diag/run?id=idle", "", nil, "x").Code; code != http.StatusUnauthorized {
		t.Fatalf("anonymous run: %d", code)
	}
	login := call(http.MethodPost, "/api/login", `{"password":"correct horse battery staple"}`, nil, "")
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

	list := call(http.MethodGet, "/api/diag/checks", "", cookie, "")
	if list.Code != http.StatusOK || !strings.Contains(list.Body.String(), `"available":false`) {
		t.Fatalf("list without diagnostics: %d %s", list.Code, list.Body)
	}
	if code := call(http.MethodPost, "/api/diag/run?id=idle", "", cookie, session.CSRF).Code; code != http.StatusServiceUnavailable {
		t.Fatalf("run without diagnostics: %d", code)
	}

	fake := &fakeDiagnostics{}
	server.SetDiagnostics(fake)
	list = call(http.MethodGet, "/api/diag/checks", "", cookie, "")
	if list.Code != http.StatusOK || !strings.Contains(list.Body.String(), `"id":"idle"`) {
		t.Fatalf("list: %d %s", list.Code, list.Body)
	}
	if code := call(http.MethodPost, "/api/diag/run?id=idle", "", cookie, "wrong").Code; code != http.StatusForbidden {
		t.Fatalf("bad CSRF: %d", code)
	}
	if code := call(http.MethodPost, "/api/diag/run?id=unknown", "", cookie, session.CSRF).Code; code != http.StatusNotFound {
		t.Fatalf("unknown id: %d", code)
	}
	run := call(http.MethodPost, "/api/diag/run?id=idle", "", cookie, session.CSRF)
	var result struct {
		ID     string `json:"id"`
		Output string `json:"output"`
	}
	if run.Code != http.StatusOK || json.Unmarshal(run.Body.Bytes(), &result) != nil || result.Output != "마지막 입력 뒤 3s" {
		t.Fatalf("run: %d %s", run.Code, run.Body)
	}

	// A second check while one runs is refused, not queued.
	fake.release = make(chan struct{})
	done := make(chan int)
	go func() { done <- call(http.MethodPost, "/api/diag/run?id=idle", "", cookie, session.CSRF).Code }()
	for !server.diagnosing.Load() {
		// wait for the first run to take the slot
	}
	if code := call(http.MethodPost, "/api/diag/run?id=idle", "", cookie, session.CSRF).Code; code != http.StatusConflict {
		t.Fatalf("concurrent run: %d", code)
	}
	close(fake.release)
	if code := <-done; code != http.StatusOK {
		t.Fatalf("first run: %d", code)
	}
}
