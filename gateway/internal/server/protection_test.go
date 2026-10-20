package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"macmonitor.local/gateway/internal/config"
)

func TestProtectionRequiresSessionOriginCSRFAndExplicitBoolean(t *testing.T) {
	dir := t.TempDir()
	id := "motion-20261020T140000.mp4"
	if err := os.WriteFile(filepath.Join(dir, id), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	server, err := New(config.Config{RecordingsDirectory: dir, MediaMTXURL: "http://127.0.0.1:8889", PublicOrigin: "https://camera.example", SessionIdleMinutes: 30, SessionMaxHours: 24})
	if err != nil {
		t.Fatal(err)
	}
	token, session, err := server.sessions.Create()
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	send := func(id, body, origin, csrf string, authenticated bool) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPut, "/api/recordings/"+id+"/protection", strings.NewReader(body))
		request.Header.Set("Origin", origin)
		request.Header.Set("X-CSRF-Token", csrf)
		if authenticated {
			request.AddCookie(&http.Cookie{Name: sessionCookieName, Value: token})
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	for _, test := range []struct {
		body, origin, csrf string
		authenticated      bool
		status             int
	}{
		{`{"protected":true}`, "https://camera.example", session.CSRF, false, 401},
		{`{"protected":true}`, "https://evil.example", session.CSRF, true, 403},
		{`{"protected":true}`, "https://camera.example", "", true, 403},
		{`{"protected":true}`, "https://camera.example", "bad token", true, 403},
		{`{}`, "https://camera.example", session.CSRF, true, 400},
		{`{"protected":null}`, "https://camera.example", session.CSRF, true, 400},
		{`{"protected":"true"}`, "https://camera.example", session.CSRF, true, 400},
		{`{"protected":true,"unknown":1}`, "https://camera.example", session.CSRF, true, 400},
		{`{"protected":true} {}`, "https://camera.example", session.CSRF, true, 400},
		{strings.Repeat(" ", 1025) + `{"protected":true}`, "https://camera.example", session.CSRF, true, 400},
	} {
		response := send(id, test.body, test.origin, test.csrf, test.authenticated)
		if response.Code != test.status {
			t.Fatalf("bad protection request returned %d, expected %d: %s", response.Code, test.status, response.Body.String())
		}
	}
	items, err := server.recordings.List()
	if err != nil || items[0].Protected {
		t.Fatal("rejected request changed protection")
	}
	for _, target := range []bool{true, true, false, false} {
		body, _ := json.Marshal(map[string]bool{"protected": target})
		response := send(id, string(body), "https://camera.example", session.CSRF, true)
		if response.Code != 200 {
			t.Fatalf("write failed: %d %s", response.Code, response.Body.String())
		}
		items, err := server.recordings.List()
		if err != nil || items[0].Protected != target {
			t.Fatal("response not reflected in stored state")
		}
		request := httptest.NewRequest("GET", "/api/recordings?protected=1", nil)
		request.AddCookie(&http.Cookie{Name: sessionCookieName, Value: token})
		filtered := httptest.NewRecorder()
		handler.ServeHTTP(filtered, request)
		var page struct{ Total, ProtectedCount int }
		expected := 0
		if target {
			expected = 1
		}
		if err := json.Unmarshal(filtered.Body.Bytes(), &page); err != nil || page.Total != expected || page.ProtectedCount != expected {
			t.Fatalf("protected filter: %s", filtered.Body.String())
		}
	}
	if response := send("missing.mp4", `{"protected":true}`, "https://camera.example", session.CSRF, true); response.Code != 404 {
		t.Fatal("missing source accepted")
	}
	if response := send("segment-20261020T120000.mp4", `{"protected":true}`, "https://camera.example", session.CSRF, true); response.Code != 400 {
		t.Fatal("pending segment accepted")
	}
	server.sessions.Delete(token)
	if response := send(id, `{"protected":true}`, "https://camera.example", session.CSRF, true); response.Code != 401 {
		t.Fatal("revoked session wrote protection")
	}
}
