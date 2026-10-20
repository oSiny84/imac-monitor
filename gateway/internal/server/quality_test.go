package server

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"macmonitor.local/gateway/internal/config"
)

func TestQualityWHEPProxyPreservesSDPAuthenticationAndSessionLocations(t *testing.T) {
	var media *httptest.Server
	media = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Origin") != media.URL {
			t.Error("backend Origin not normalized")
		}
		if r.Method == "POST" {
			body, _ := io.ReadAll(r.Body)
			if string(body) != "SDP offer" || r.Header.Get("Content-Type") != "application/sdp" {
				t.Error("SDP modified")
			}
			location := media.URL + r.URL.Path + "/session-123"
			if r.URL.Query().Get("bad") == "1" {
				location = "https://outside.example/session"
			}
			w.Header().Set("Location", location)
			w.Header().Set("Content-Type", "application/sdp")
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte("SDP answer"))
		} else {
			w.WriteHeader(http.StatusNoContent)
		}
	}))
	defer media.Close()
	server, err := New(config.Config{MediaMTXURL: media.URL, RecordingsDirectory: t.TempDir(), PublicOrigin: "https://camera.example", SessionIdleMinutes: 30, SessionMaxHours: 24})
	if err != nil {
		t.Fatal(err)
	}
	token, _, err := server.sessions.Create()
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	for _, profile := range []string{"live", "live-balanced", "live-low"} {
		endpoint := "/live/" + profile + "/whep"
		request := httptest.NewRequest("POST", endpoint, strings.NewReader("SDP offer"))
		request.Header.Set("Origin", "https://camera.example")
		request.Header.Set("Content-Type", "application/sdp")
		request.AddCookie(&http.Cookie{Name: sessionCookieName, Value: token})
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != 201 || response.Body.String() != "SDP answer" || response.Header().Get("Location") != endpoint+"/session-123" {
			t.Fatalf("profile %s: %d %#v %s", profile, response.Code, response.Header(), response.Body.String())
		}
		request = httptest.NewRequest("DELETE", response.Header().Get("Location"), nil)
		request.Header.Set("Origin", "https://camera.example")
		request.AddCookie(&http.Cookie{Name: sessionCookieName, Value: token})
		response = httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != 204 {
			t.Fatal("session cleanup not proxied")
		}
	}
	request := httptest.NewRequest("POST", "/live/live-low/whep?bad=1", strings.NewReader("SDP offer"))
	request.Header.Set("Origin", "https://camera.example")
	request.Header.Set("Content-Type", "application/sdp")
	request.AddCookie(&http.Cookie{Name: sessionCookieName, Value: token})
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != 502 || response.Header().Get("Location") != "" {
		t.Fatal("foreign session Location escaped the proxy")
	}
}
