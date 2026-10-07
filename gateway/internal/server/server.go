package server

import (
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"macmonitor.local/gateway/internal/auth"
	"macmonitor.local/gateway/internal/config"
	"macmonitor.local/gateway/internal/recordings"
)

const sessionCookieName = "__Host-mm_session"

//go:embed web/*
var webFiles embed.FS

type Server struct {
	config       config.Config
	sessions     *auth.SessionStore
	loginLimiter *auth.LoginLimiter
	recordings   *recordings.Store
	mediaTarget  *url.URL
	mediaProxy   *httputil.ReverseProxy
	httpClient   *http.Client
	static       http.Handler
}

func New(cfg config.Config) (*Server, error) {
	store, err := recordings.NewStore(cfg.RecordingsDirectory)
	if err != nil {
		return nil, fmt.Errorf("initialize recordings: %w", err)
	}
	mediaTarget, err := url.Parse(cfg.MediaMTXURL)
	if err != nil {
		return nil, err
	}
	staticFS, err := fs.Sub(webFiles, "web")
	if err != nil {
		return nil, err
	}

	proxy := httputil.NewSingleHostReverseProxy(mediaTarget)
	originalDirector := proxy.Director
	proxy.Director = func(request *http.Request) {
		originalPath := strings.TrimPrefix(request.URL.Path, "/live")
		if originalPath == "" {
			originalPath = "/"
		}
		request.URL.Path = originalPath
		originalDirector(request)
		request.Host = mediaTarget.Host
		request.Header.Set("Origin", mediaTarget.Scheme+"://"+mediaTarget.Host)
		request.Header.Del("Forwarded")
		request.Header.Del("X-Forwarded-Host")
		request.Header.Del("X-Forwarded-Proto")
	}
	proxy.ErrorHandler = func(writer http.ResponseWriter, request *http.Request, err error) {
		log.Printf("MediaMTX proxy error: %v", err)
		http.Error(writer, "live stream is temporarily unavailable", http.StatusBadGateway)
	}
	proxy.ModifyResponse = func(response *http.Response) error {
		location := response.Header.Get("Location")
		if location == "" {
			return nil
		}
		parsed, err := url.Parse(location)
		if err != nil {
			return err
		}
		if parsed.IsAbs() && parsed.Host != mediaTarget.Host {
			return errors.New("MediaMTX returned a redirect to an unexpected host")
		}
		if parsed.Path == "" || !strings.HasPrefix(parsed.Path, "/") {
			return nil
		}
		parsed.Scheme = ""
		parsed.Host = ""
		parsed.Path = "/live" + parsed.Path
		response.Header.Set("Location", parsed.String())
		return nil
	}
	proxy.FlushInterval = -1

	return &Server{
		config:       cfg,
		sessions:     auth.NewSessionStore(cfg.SessionIdleTTL(), cfg.SessionMaxTTL()),
		loginLimiter: auth.NewLoginLimiter(),
		recordings:   store,
		mediaTarget:  mediaTarget,
		mediaProxy:   proxy,
		httpClient:   &http.Client{Timeout: 2 * time.Second},
		static:       http.FileServer(http.FS(staticFS)),
	}, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", s.serveIndex)
	mux.Handle("GET /assets/", s.static)
	mux.HandleFunc("POST /api/login", s.login)
	mux.HandleFunc("GET /api/session", s.sessionStatus)
	mux.Handle("POST /api/logout", s.requireSession(http.HandlerFunc(s.logout)))
	mux.Handle("GET /api/status", s.requireSession(http.HandlerFunc(s.status)))
	mux.Handle("GET /api/recordings", s.requireSession(http.HandlerFunc(s.listRecordings)))
	mux.Handle("GET /recordings/{id}", s.requireSession(http.HandlerFunc(s.serveRecording)))
	mux.Handle("HEAD /recordings/{id}", s.requireSession(http.HandlerFunc(s.serveRecording)))
	liveHandler := s.requireSession(http.HandlerFunc(s.proxyLive))
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodOptions, http.MethodPatch, http.MethodDelete} {
		mux.Handle(method+" /live/", liveHandler)
	}
	return s.securityHeaders(s.originProtection(mux))
}

func (s *Server) serveIndex(writer http.ResponseWriter, request *http.Request) {
	request.URL.Path = "/index.html"
	s.static.ServeHTTP(writer, request)
}

func (s *Server) login(writer http.ResponseWriter, request *http.Request) {
	client := clientIP(request.RemoteAddr)
	allowed, retryAfter := s.loginLimiter.Allow(client)
	if !allowed {
		writer.Header().Set("Retry-After", strconv.Itoa(max(1, int(retryAfter.Seconds()))))
		writeError(writer, http.StatusTooManyRequests, "로그인 시도가 너무 많습니다. 잠시 후 다시 시도하세요.")
		return
	}

	request.Body = http.MaxBytesReader(writer, request.Body, 4096)
	var input struct {
		Password string `json:"password"`
	}
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.Password == "" {
		writeError(writer, http.StatusBadRequest, "잘못된 로그인 요청입니다.")
		return
	}
	if !auth.VerifyPassword(s.config.PasswordHash, input.Password) {
		s.loginLimiter.Failure(client)
		writeError(writer, http.StatusUnauthorized, "비밀번호가 올바르지 않습니다.")
		return
	}

	token, session, err := s.sessions.Create()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "세션을 만들 수 없습니다.")
		return
	}
	s.loginLimiter.Success(client)
	http.SetCookie(writer, &http.Cookie{
		Name:     sessionCookieName,
		Value:    token,
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   int(s.config.SessionMaxTTL().Seconds()),
	})
	writeJSON(writer, http.StatusOK, map[string]any{"authenticated": true, "csrfToken": session.CSRF})
}

func (s *Server) sessionStatus(writer http.ResponseWriter, request *http.Request) {
	_, session, ok := s.requestSession(request)
	if !ok {
		writeJSON(writer, http.StatusOK, map[string]any{"authenticated": false})
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{"authenticated": true, "csrfToken": session.CSRF})
}

func (s *Server) logout(writer http.ResponseWriter, request *http.Request) {
	token, session, _ := s.requestSession(request)
	if !csrfMatches(request, session.CSRF) {
		writeError(writer, http.StatusForbidden, "CSRF 검증에 실패했습니다.")
		return
	}
	s.sessions.Delete(token)
	http.SetCookie(writer, &http.Cookie{
		Name:     sessionCookieName,
		Value:    "",
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
	})
	writeJSON(writer, http.StatusOK, map[string]any{"authenticated": false})
}

func (s *Server) status(writer http.ResponseWriter, request *http.Request) {
	probeURL := *s.mediaTarget
	probeURL.Path = "/"
	probeRequest, _ := http.NewRequestWithContext(request.Context(), http.MethodGet, probeURL.String(), nil)
	response, err := s.httpClient.Do(probeRequest)
	mediaReachable := err == nil
	if response != nil {
		response.Body.Close()
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"gateway":        "ok",
		"mediaReachable": mediaReachable,
		"checkedAt":      time.Now().UTC(),
	})
}

func (s *Server) listRecordings(writer http.ResponseWriter, request *http.Request) {
	items, err := s.recordings.List()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "녹화 목록을 읽을 수 없습니다.")
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{"recordings": items})
}

func (s *Server) serveRecording(writer http.ResponseWriter, request *http.Request) {
	id := request.PathValue("id")
	file, info, err := s.recordings.Open(id)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			http.NotFound(writer, request)
		} else {
			writeError(writer, http.StatusInternalServerError, "녹화를 열 수 없습니다.")
		}
		return
	}
	defer file.Close()
	writer.Header().Set("Content-Type", "video/mp4")
	writer.Header().Set("Content-Disposition", `inline; filename="`+path.Base(id)+`"`)
	writer.Header().Set("Cache-Control", "private, no-store")
	http.ServeContent(writer, request, id, info.ModTime(), file)
}

func (s *Server) proxyLive(writer http.ResponseWriter, request *http.Request) {
	s.mediaProxy.ServeHTTP(writer, request)
}

func (s *Server) requireSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		_, _, ok := s.requestSession(request)
		if !ok {
			writeError(writer, http.StatusUnauthorized, "로그인이 필요합니다.")
			return
		}
		next.ServeHTTP(writer, request)
	})
}

func (s *Server) requestSession(request *http.Request) (string, auth.Session, bool) {
	cookie, err := request.Cookie(sessionCookieName)
	if err != nil {
		return "", auth.Session{}, false
	}
	session, ok := s.sessions.Validate(cookie.Value)
	return cookie.Value, session, ok
}

func (s *Server) originProtection(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet && request.Method != http.MethodHead && request.Method != http.MethodOptions {
			if request.Header.Get("Origin") != s.config.PublicOrigin {
				writeError(writer, http.StatusForbidden, "허용되지 않은 요청 출처입니다.")
				return
			}
		}
		next.ServeHTTP(writer, request)
	})
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Strict-Transport-Security", "max-age=31536000")
		writer.Header().Set("X-Content-Type-Options", "nosniff")
		writer.Header().Set("Referrer-Policy", "no-referrer")
		writer.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		writer.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
		writer.Header().Set("X-Frame-Options", "SAMEORIGIN")
		writer.Header().Set("Cache-Control", "no-store")
		if strings.HasPrefix(request.URL.Path, "/live/") {
			writer.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self' blob:; media-src 'self' blob:")
		} else {
			writer.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; media-src 'self'; frame-src 'self'; base-uri 'none'; form-action 'self'")
		}
		next.ServeHTTP(writer, request)
	})
}

func csrfMatches(request *http.Request, expected string) bool {
	actual := request.Header.Get("X-CSRF-Token")
	if actual == "" || len(actual) != len(expected) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(actual), []byte(expected)) == 1
}

func clientIP(remoteAddress string) string {
	host, _, err := net.SplitHostPort(remoteAddress)
	if err != nil {
		return remoteAddress
	}
	return host
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func writeError(writer http.ResponseWriter, status int, message string) {
	writeJSON(writer, status, map[string]string{"error": message})
}
