package server

import (
	"context"
	"encoding/json"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"macmonitor.local/gateway/internal/config"
	"macmonitor.local/gateway/internal/recordings"
)

type stubThumbnails struct{ calls int }

func (s *stubThumbnails) Get(ctx context.Context, id string) ([]byte, error) {
	s.calls++
	if id == "missing.mp4" {
		return nil, fs.ErrNotExist
	}
	return []byte("test jpeg bytes"), nil
}

func TestArchiveSearchValidationDownloadAndProtectedThumbnails(t *testing.T) {
	dir := t.TempDir()
	id := "motion-20261020T000000.mp4"
	if err := os.WriteFile(filepath.Join(dir, id), []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	server, err := New(config.Config{RecordingsDirectory: dir, MediaMTXURL: "http://127.0.0.1:8889", SessionIdleMinutes: 30, SessionMaxHours: 24})
	if err != nil {
		t.Fatal(err)
	}
	thumbnails := &stubThumbnails{}
	server.thumbnails = thumbnails
	handler := server.Handler()
	token, _, err := server.sessions.Create()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: token}
	for _, path := range []string{"/api/recordings/" + id + "/thumbnail", "/recordings/" + id + "?download=1"} {
		for _, method := range []string{"GET", "HEAD"} {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(method, path, nil))
			if response.Code != http.StatusUnauthorized {
				t.Fatalf("unprotected %s %s", method, path)
			}
		}
	}
	if thumbnails.calls != 0 {
		t.Fatal("thumbnail processing ran before authentication")
	}
	for _, query := range []string{"from=garbage", "from=2026-10-21T00:00:00Z&to=2026-10-20T00:00:00Z", "limit=0", "limit=101", "offset=-1", "offset=9999999999999999999999999999999999", "limit=1&limit=2", "protected=no", "protected=1&protected=1"} {
		request := httptest.NewRequest("GET", "/api/recordings?"+query, nil)
		request.AddCookie(cookie)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusBadRequest {
			t.Fatalf("invalid query accepted: %s => %d", query, response.Code)
		}
	}
	request := httptest.NewRequest("GET", "/api/recordings?limit=1&offset=0", nil)
	request.AddCookie(cookie)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	var page struct {
		Total      int
		HasMore    bool
		Recordings []map[string]any
	}
	if err := json.Unmarshal(response.Body.Bytes(), &page); err != nil || page.Total != 1 || page.HasMore || len(page.Recordings) != 1 {
		t.Fatalf("page: %s", response.Body.String())
	}
	for _, test := range []struct {
		method, path, disposition, body string
		status                          int
	}{
		{"GET", "/recordings/" + id + "?download=1", "attachment; filename=\"" + id + "\"", "0123456789", 200},
		{"HEAD", "/recordings/" + id + "?download=1", "attachment; filename=\"" + id + "\"", "", 200},
		{"GET", "/api/recordings/" + id + "/thumbnail", "", "test jpeg bytes", 200},
		{"HEAD", "/api/recordings/" + id + "/thumbnail", "", "", 200},
		{"GET", "/api/recordings/missing.mp4/thumbnail", "", "", 404},
	} {
		request := httptest.NewRequest(test.method, test.path, nil)
		request.AddCookie(cookie)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != test.status {
			t.Fatalf("%s: %d %s", test.path, response.Code, response.Body.String())
		}
		if test.status == 200 && (response.Body.String() != test.body || response.Header().Get("Content-Disposition") != test.disposition) {
			t.Fatalf("bad response for %s: %#v %q", test.path, response.Header(), response.Body.String())
		}
		if strings.Contains(test.path, "thumbnail") && test.status == 200 && response.Header().Get("Content-Type") != "image/jpeg" {
			t.Fatal("wrong thumbnail MIME")
		}
		if response.Header().Get("Cache-Control") != "no-store" && response.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatal("private response cacheable")
		}
	}
	request = httptest.NewRequest("GET", "/recordings/"+id+"?download=1", nil)
	request.AddCookie(cookie)
	request.Header.Set("Range", "bytes=2-5")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusPartialContent || response.Body.String() != "2345" || !strings.HasPrefix(response.Header().Get("Content-Disposition"), "attachment;") {
		t.Fatal("download range not preserved")
	}
	server.thumbnails = recordings.NewThumbnails(server.recordings)
	request = httptest.NewRequest("GET", "/api/recordings/"+id+"/thumbnail", nil)
	request.AddCookie(cookie)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") != "30" || strings.Contains(response.Body.String(), dir) {
		t.Fatal("bad recording should fail thumbnail safely without exposing paths")
	}
	request = httptest.NewRequest("GET", "/recordings/"+id+"?download=1", nil)
	request.AddCookie(cookie)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || response.Body.String() != "0123456789" {
		t.Fatal("thumbnail failure disabled downloads")
	}
}
