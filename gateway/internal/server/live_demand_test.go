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

// MediaMTX v1.21.1 answers its root with 404 while fully running. Confirmed against the
// pinned binary; a server that answers at all must count as reachable.
func TestRunningMediaMTXRootNotFoundIsReportedAsLiveAvailable(t *testing.T) {
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer media.Close()
	server, err := New(config.Config{MediaMTXURL: media.URL, RecordingsDirectory: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	server.status(response, httptest.NewRequest(http.MethodGet, "/api/status", nil))
	var result struct {
		MediaReachable bool `json:"mediaReachable"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if !result.MediaReachable {
		t.Fatal("a running MediaMTX answering 404 was reported as unavailable")
	}
}

func TestLiveDemandRequiresSessionOriginAndCSRFAndRenewsTheLease(t *testing.T) {
	directory := t.TempDir()
	demandFile := filepath.Join(directory, "Runtime", "live-demand.json")
	hash, err := auth.HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{PublicOrigin: "https://camera.example", MediaMTXURL: "http://127.0.0.1:1",
		RecordingsDirectory: directory, PasswordHash: hash, LiveDemandFile: demandFile,
		SessionIdleMinutes: 30, SessionMaxHours: 24}
	server, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()

	post := func(cookie *http.Cookie, origin, csrf string) int {
		request := httptest.NewRequest(http.MethodPost, "/api/live/demand", nil)
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
		return response.Code
	}

	if code := post(nil, cfg.PublicOrigin, "x"); code != http.StatusUnauthorized {
		t.Fatalf("anonymous demand: %d", code)
	}
	if _, err := os.Stat(demandFile); !os.IsNotExist(err) {
		t.Fatal("an anonymous request must not be able to turn the camera on")
	}

	loginRequest := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"password":"correct horse battery staple"}`))
	loginRequest.Header.Set("Origin", cfg.PublicOrigin)
	login := httptest.NewRecorder()
	handler.ServeHTTP(login, loginRequest)
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

	if code := post(cookie, "https://evil.example", session.CSRF); code != http.StatusForbidden {
		t.Fatalf("foreign origin: %d", code)
	}
	if code := post(cookie, cfg.PublicOrigin, "wrong-token"); code != http.StatusForbidden {
		t.Fatalf("bad CSRF: %d", code)
	}
	if _, err := os.Stat(demandFile); !os.IsNotExist(err) {
		t.Fatal("a rejected request wrote the lease")
	}

	if code := post(cookie, cfg.PublicOrigin, session.CSRF); code != http.StatusNoContent {
		t.Fatalf("valid demand: %d", code)
	}
	first, err := os.ReadFile(demandFile)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond)
	if code := post(cookie, cfg.PublicOrigin, session.CSRF); code != http.StatusNoContent {
		t.Fatalf("renewal: %d", code)
	}
	second, err := os.ReadFile(demandFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(first) == string(second) {
		t.Fatal("the app detects a viewer by content change, so each renewal must change the file")
	}
	entries, err := os.ReadDir(filepath.Dir(demandFile))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("temporary files left beside the lease: %v", entries)
	}
}
