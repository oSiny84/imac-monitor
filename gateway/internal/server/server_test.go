package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"macmonitor.local/gateway/internal/auth"
	"macmonitor.local/gateway/internal/config"
)

func TestRootPageAndEmbeddedAssets(t *testing.T) {
	server, err := New(config.Config{
		MediaMTXURL:         "http://127.0.0.1:8889",
		RecordingsDirectory: t.TempDir(),
	})
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	for _, test := range []struct {
		path        string
		contentType string
		contains    string
	}{
		{"/", "text/html", "id=\"login-form\""},
		{"/assets/app.js", "javascript", "showAuthenticated"},
		{"/assets/styles.css", "text/css", ".video-frame"},
	} {
		t.Run(test.path, func(t *testing.T) {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, test.path, nil))
			if response.Code != http.StatusOK {
				t.Fatalf("returned %d; Location=%q", response.Code, response.Header().Get("Location"))
			}
			if !strings.Contains(response.Header().Get("Content-Type"), test.contentType) ||
				!strings.Contains(response.Body.String(), test.contains) {
				t.Fatalf("unexpected page response: type=%q body=%q", response.Header().Get("Content-Type"), response.Body.String())
			}
		})
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/unknown", nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("unknown endpoint returned %d", response.Code)
	}
}

func TestAuthenticationAndProtectedRecordingRange(t *testing.T) {
	media := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/redirect" {
			writer.Header().Set("Location", "/live/whep/session-id")
			writer.WriteHeader(http.StatusCreated)
			return
		}
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer media.Close()
	directory := t.TempDir()
	name := "motion-20261007T140000-test.mp4"
	if err := os.WriteFile(filepath.Join(directory, name), []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	hash, err := auth.HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		PublicOrigin:        "https://camera.example",
		MediaMTXURL:         media.URL,
		RecordingsDirectory: directory,
		PasswordHash:        hash,
		SessionIdleMinutes:  30,
		SessionMaxHours:     24,
	}
	server, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()

	for _, protected := range []struct{ method, path string }{
		{http.MethodGet, "/api/status"},
		{http.MethodGet, "/api/recordings"},
		{http.MethodGet, "/recordings/" + name},
		{http.MethodHead, "/recordings/" + name},
		{http.MethodGet, "/live/live/"},
		{http.MethodPost, "/live/live/whep"},
		{http.MethodPatch, "/live/live/whep/session-id"},
		{http.MethodDelete, "/live/live/whep/session-id"},
		{http.MethodOptions, "/live/live/whep"},
	} {
		request := httptest.NewRequest(protected.method, protected.path, nil)
		request.Header.Set("Origin", cfg.PublicOrigin)
		unauthorized := httptest.NewRecorder()
		handler.ServeHTTP(unauthorized, request)
		if unauthorized.Code != http.StatusUnauthorized {
			t.Fatalf("protected %s %s returned %d", protected.method, protected.path, unauthorized.Code)
		}
	}

	loginBody, _ := json.Marshal(map[string]string{"password": "correct horse battery staple"})
	loginRequest := httptest.NewRequest(http.MethodPost, "/api/login", bytes.NewReader(loginBody))
	loginRequest.Header.Set("Origin", cfg.PublicOrigin)
	login := httptest.NewRecorder()
	handler.ServeHTTP(login, loginRequest)
	if login.Code != http.StatusOK {
		t.Fatalf("login returned %d: %s", login.Code, login.Body.String())
	}
	cookies := login.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].Secure || !cookies[0].HttpOnly {
		t.Fatalf("unexpected session cookie: %#v", cookies)
	}

	rangeRequest := httptest.NewRequest(http.MethodGet, "/recordings/"+name, nil)
	rangeRequest.AddCookie(cookies[0])
	rangeRequest.Header.Set("Range", "bytes=2-5")
	rangeResponse := httptest.NewRecorder()
	handler.ServeHTTP(rangeResponse, rangeRequest)
	if rangeResponse.Code != http.StatusPartialContent || rangeResponse.Body.String() != "2345" {
		t.Fatalf("range response: %d %q", rangeResponse.Code, rangeResponse.Body.String())
	}
	proxyRequest := httptest.NewRequest(http.MethodGet, "/live/redirect", nil)
	proxyRequest.AddCookie(cookies[0])
	proxyResponse := httptest.NewRecorder()
	handler.ServeHTTP(proxyResponse, proxyRequest)
	if proxyResponse.Code != http.StatusCreated || proxyResponse.Header().Get("Location") != "/live/live/whep/session-id" {
		t.Fatalf("proxy Location rewrite failed: %d %q", proxyResponse.Code, proxyResponse.Header().Get("Location"))
	}

	var loginResult struct {
		CSRFToken string `json:"csrfToken"`
	}
	if err := json.Unmarshal(login.Body.Bytes(), &loginResult); err != nil || loginResult.CSRFToken == "" {
		t.Fatalf("missing CSRF token: %v", err)
	}
	withoutCSRF := httptest.NewRequest(http.MethodPost, "/api/logout", nil)
	withoutCSRF.AddCookie(cookies[0])
	withoutCSRF.Header.Set("Origin", cfg.PublicOrigin)
	withoutCSRFResponse := httptest.NewRecorder()
	handler.ServeHTTP(withoutCSRFResponse, withoutCSRF)
	if withoutCSRFResponse.Code != http.StatusForbidden {
		t.Fatalf("logout without CSRF token returned %d", withoutCSRFResponse.Code)
	}
	logoutRequest := httptest.NewRequest(http.MethodPost, "/api/logout", nil)
	logoutRequest.AddCookie(cookies[0])
	logoutRequest.Header.Set("Origin", cfg.PublicOrigin)
	logoutRequest.Header.Set("X-CSRF-Token", loginResult.CSRFToken)
	logoutResponse := httptest.NewRecorder()
	handler.ServeHTTP(logoutResponse, logoutRequest)
	if logoutResponse.Code != http.StatusOK {
		t.Fatalf("logout returned %d", logoutResponse.Code)
	}

	afterLogout := httptest.NewRecorder()
	afterLogoutRequest := httptest.NewRequest(http.MethodGet, "/api/recordings", nil)
	afterLogoutRequest.AddCookie(cookies[0])
	handler.ServeHTTP(afterLogout, afterLogoutRequest)
	if afterLogout.Code != http.StatusUnauthorized {
		t.Fatalf("session survived logout: %d", afterLogout.Code)
	}
}

func TestLoginRequiresConfiguredOrigin(t *testing.T) {
	hash, err := auth.HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	server, err := New(config.Config{
		PublicOrigin:        "https://camera.example",
		MediaMTXURL:         "http://127.0.0.1:8889",
		RecordingsDirectory: t.TempDir(),
		PasswordHash:        hash,
		SessionIdleMinutes:  30,
		SessionMaxHours:     24,
	})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/api/login", bytes.NewBufferString(`{"password":"correct horse battery staple"}`))
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("login without origin returned %d", response.Code)
	}
}

func TestArchiveRemainsAuthenticatedAndPlayableWhenMediaStops(t *testing.T) {
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer media.Close()
	directory := t.TempDir()
	name := "motion-20261020T120000.mp4"
	if err := os.WriteFile(filepath.Join(directory, name), []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	hash, err := auth.HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		PublicOrigin: "https://camera.example", MediaMTXURL: media.URL,
		RecordingsDirectory: directory, PasswordHash: hash,
		SessionIdleMinutes: 30, SessionMaxHours: 24,
	}
	server, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	loginRequest := httptest.NewRequest(http.MethodPost, "/api/login",
		strings.NewReader(`{"password":"correct horse battery staple"}`))
	loginRequest.Header.Set("Origin", cfg.PublicOrigin)
	login := httptest.NewRecorder()
	handler.ServeHTTP(login, loginRequest)
	if login.Code != http.StatusOK {
		t.Fatalf("login: %d", login.Code)
	}
	cookie := login.Result().Cookies()[0]

	for _, mediaRunning := range []bool{true, false} {
		if !mediaRunning {
			media.Close()
		} // Simulate a capture stop or display-only rest.
		for _, endpoint := range []string{"/api/status", "/api/session", "/api/recordings", "/recordings/" + name} {
			request := httptest.NewRequest(http.MethodGet, endpoint, nil)
			request.AddCookie(cookie)
			if strings.HasPrefix(endpoint, "/recordings/") {
				request.Header.Set("Range", "bytes=2-5")
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if strings.HasPrefix(endpoint, "/recordings/") {
				if response.Code != http.StatusPartialContent || response.Body.String() != "2345" {
					t.Fatalf("archive playback with media running=%v: %d %q", mediaRunning, response.Code, response.Body.String())
				}
				continue
			}
			if response.Code != http.StatusOK {
				t.Fatalf("%s: %d", endpoint, response.Code)
			}
			var result map[string]any
			if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if endpoint == "/api/status" && result["mediaReachable"] != mediaRunning {
				t.Fatalf("wrong live availability: %v", result)
			}
			if endpoint == "/api/session" && result["authenticated"] != true {
				t.Fatal("capture stop invalidated the web session")
			}
			if endpoint == "/api/recordings" && !strings.Contains(response.Body.String(), name) {
				t.Fatal("recording missing during capture rest")
			}
		}
	}
	unauthenticated := httptest.NewRecorder()
	handler.ServeHTTP(unauthenticated, httptest.NewRequest(http.MethodGet, "/recordings/"+name, nil))
	if unauthenticated.Code != http.StatusUnauthorized {
		t.Fatal("archive lost authentication during rest")
	}
}

func TestMediaHTTPFailureIsNotReportedAsLiveAvailable(t *testing.T) {
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
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
	if result.MediaReachable {
		t.Fatal("HTTP 503 must not launch the live player")
	}
}
