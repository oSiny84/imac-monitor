package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"macmonitor.local/gateway/internal/config"
)

func TestDeleteRequiresSessionAndCSRFAndRefusesProtectedRecordings(t *testing.T) {
	dir := t.TempDir()
	id := "remote-20261108T090000.mp4"
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
	send := func(id, origin, csrf string, authenticated bool) int {
		request := httptest.NewRequest(http.MethodDelete, "/api/recordings/"+id, nil)
		request.Header.Set("Origin", origin)
		request.Header.Set("X-CSRF-Token", csrf)
		if authenticated {
			request.AddCookie(&http.Cookie{Name: sessionCookieName, Value: token})
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response.Code
	}
	exists := func() bool {
		_, err := os.Stat(filepath.Join(dir, id))
		return err == nil
	}

	if code := send(id, "https://camera.example", session.CSRF, false); code != http.StatusUnauthorized || !exists() {
		t.Fatalf("anonymous delete: %d, exists %v", code, exists())
	}
	if code := send(id, "https://evil.example", session.CSRF, true); code != http.StatusForbidden || !exists() {
		t.Fatalf("foreign origin: %d, exists %v", code, exists())
	}
	if code := send(id, "https://camera.example", "wrong", true); code != http.StatusForbidden || !exists() {
		t.Fatalf("bad CSRF: %d, exists %v", code, exists())
	}
	if code := send("segment-20261108T090000.mp4", "https://camera.example", session.CSRF, true); code != http.StatusBadRequest {
		t.Fatalf("spool segment: %d", code)
	}
	if err := server.recordings.SetProtected(context.Background(), id, true); err != nil {
		t.Fatal(err)
	}
	if code := send(id, "https://camera.example", session.CSRF, true); code != http.StatusConflict || !exists() {
		t.Fatalf("protected: %d, exists %v", code, exists())
	}
	if err := server.recordings.SetProtected(context.Background(), id, false); err != nil {
		t.Fatal(err)
	}
	if code := send(id, "https://camera.example", session.CSRF, true); code != http.StatusNoContent || exists() {
		t.Fatalf("valid delete: %d, exists %v", code, exists())
	}
	if code := send(id, "https://camera.example", session.CSRF, true); code != http.StatusNotFound {
		t.Fatalf("deleting again: %d", code)
	}
}
