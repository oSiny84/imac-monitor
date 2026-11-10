package server

import (
	"bytes"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"macmonitor.local/gateway/internal/auth"
	"macmonitor.local/gateway/internal/config"
	"macmonitor.local/gateway/internal/health"
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
	thumbnails   thumbnailSource
	mediaTarget  *url.URL
	mediaProxy   *httputil.ReverseProxy
	httpClient   *http.Client
	static       http.Handler
	// The Origin header values accepted on state-changing requests, from config.AllowedOrigins.
	allowedOrigins map[string]bool
	// Unix nanoseconds of the last live-lease renewal by a web viewer; read by the chat bot.
	lastViewerDemand atomic.Int64
}

// LastViewerDemand is when a logged-in web viewer last asked for the camera, or zero.
func (s *Server) LastViewerDemand() time.Time {
	nanos := s.lastViewerDemand.Load()
	if nanos == 0 {
		return time.Time{}
	}
	return time.Unix(0, nanos)
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
		if err := addReachableCandidates(response); err != nil {
			return err
		}
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
		config:         cfg,
		sessions:       auth.NewSessionStore(cfg.SessionIdleTTL(), cfg.SessionMaxTTL()),
		loginLimiter:   auth.NewLoginLimiter(),
		recordings:     store,
		thumbnails:     recordings.NewThumbnails(store),
		mediaTarget:    mediaTarget,
		mediaProxy:     proxy,
		httpClient:     &http.Client{Timeout: 2 * time.Second},
		static:         http.FileServer(http.FS(staticFS)),
		allowedOrigins: originSet(cfg.AllowedOrigins()),
	}, nil
}

// originSet never holds the empty string, so a request without an Origin header is refused
// even when the configuration was never validated.
func originSet(origins []string) map[string]bool {
	set := make(map[string]bool, len(origins))
	for _, origin := range origins {
		if origin != "" {
			set[origin] = true
		}
	}
	return set
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.serveIndex)
	mux.Handle("GET /assets/", s.static)
	mux.HandleFunc("POST /api/login", s.login)
	mux.HandleFunc("GET /api/session", s.sessionStatus)
	mux.Handle("POST /api/logout", s.requireSession(http.HandlerFunc(s.logout)))
	mux.Handle("GET /api/status", s.requireSession(http.HandlerFunc(s.status)))
	mux.Handle("POST /api/live/demand", s.requireSession(http.HandlerFunc(s.recordLiveDemand)))
	mux.Handle("POST /api/recording/start", s.requireSession(http.HandlerFunc(s.startRecording)))
	mux.Handle("POST /api/recording/stop", s.requireSession(http.HandlerFunc(s.stopRecording)))
	mux.Handle("GET /api/recordings", s.requireSession(http.HandlerFunc(s.listRecordings)))
	mux.Handle("GET /api/recordings/{id}/thumbnail", s.requireSession(http.HandlerFunc(s.serveThumbnail)))
	mux.Handle("PUT /api/recordings/{id}/protection", s.requireSession(http.HandlerFunc(s.setRecordingProtection)))
	mux.Handle("DELETE /api/recordings/{id}", s.requireSession(http.HandlerFunc(s.deleteRecording)))
	mux.Handle("GET /recordings/{id}", s.requireSession(http.HandlerFunc(s.serveRecording)))
	mux.Handle("HEAD /recordings/{id}", s.requireSession(http.HandlerFunc(s.serveRecording)))
	liveHandler := s.requireSession(http.HandlerFunc(s.proxyLive))
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodOptions, http.MethodPatch, http.MethodDelete} {
		mux.Handle(method+" /live/", liveHandler)
	}
	return s.securityHeaders(s.originProtection(mux))
}

func (s *Server) serveIndex(writer http.ResponseWriter, request *http.Request) {
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
	// MediaMTX v1.21.1 answers its root with 404 while fully running, so any answer short
	// of a server error means it is up. Whether a stream exists is learned from WHEP.
	mediaReachable := err == nil && response != nil && response.StatusCode < 500
	if response != nil {
		response.Body.Close()
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"gateway":        "ok",
		"mediaReachable": mediaReachable,
		"checkedAt":      time.Now().UTC(),
		"monitoring":     health.Read(s.config.MonitoringStatusFile, time.Now()),
		"recording":      health.ReadRecordingDemand(s.config.RecordingDemandFile, time.Now()),
	})
}

// recordLiveDemand renews the viewer lease that tells the app to keep the camera on. The app
// turns the camera off once renewals stop, so a closed tab needs no explicit release.
func (s *Server) recordLiveDemand(writer http.ResponseWriter, request *http.Request) {
	_, session, _ := s.requestSession(request)
	if !csrfMatches(request, session.CSRF) {
		writeError(writer, http.StatusForbidden, "CSRF 검증에 실패했습니다.")
		return
	}
	if s.config.LiveDemandFile == "" {
		writeError(writer, http.StatusServiceUnavailable, "실시간 요청 경로가 설정되지 않았습니다.")
		return
	}
	now := time.Now()
	if err := health.RecordLiveDemand(s.config.LiveDemandFile, now); err != nil {
		log.Printf("live demand write failed: %v", err)
		writeError(writer, http.StatusInternalServerError, "실시간 요청을 앱에 전달하지 못했습니다.")
		return
	}
	s.lastViewerDemand.Store(now.UnixNano())
	writer.WriteHeader(http.StatusNoContent)
}

// startRecording writes the request the app records against until its end time. Unlike the
// viewer lease it is never renewed: the owner asked for a number of hours and may close the
// page, so the camera stays on without them.
func (s *Server) startRecording(writer http.ResponseWriter, request *http.Request) {
	_, session, _ := s.requestSession(request)
	if !csrfMatches(request, session.CSRF) {
		writeError(writer, http.StatusForbidden, "CSRF 검증에 실패했습니다.")
		return
	}
	if s.config.RecordingDemandFile == "" {
		writeError(writer, http.StatusServiceUnavailable, "녹화 요청 경로가 설정되지 않았습니다.")
		return
	}
	var body struct {
		Hours int `json:"hours"`
	}
	if err := json.NewDecoder(io.LimitReader(request.Body, 1024)).Decode(&body); err != nil ||
		body.Hours < 1 || body.Hours > health.MaxRecordingHours {
		writeError(writer, http.StatusBadRequest, fmt.Sprintf("녹화 시간은 1~%d시간이어야 합니다.", health.MaxRecordingHours))
		return
	}
	demand, err := health.WriteRecordingDemand(s.config.RecordingDemandFile, time.Now(), body.Hours)
	if err != nil {
		log.Printf("recording demand write failed: %v", err)
		writeError(writer, http.StatusInternalServerError, "녹화 요청을 앱에 전달하지 못했습니다.")
		return
	}
	log.Printf("remote recording requested for %d hours until %s", demand.Hours, demand.Until.Format(time.RFC3339))
	writeJSON(writer, http.StatusOK, demand)
}

// stopRecording ends the request early. The app notices the missing file within seconds.
func (s *Server) stopRecording(writer http.ResponseWriter, request *http.Request) {
	_, session, _ := s.requestSession(request)
	if !csrfMatches(request, session.CSRF) {
		writeError(writer, http.StatusForbidden, "CSRF 검증에 실패했습니다.")
		return
	}
	if s.config.RecordingDemandFile == "" {
		writeError(writer, http.StatusServiceUnavailable, "녹화 요청 경로가 설정되지 않았습니다.")
		return
	}
	if err := health.ClearRecordingDemand(s.config.RecordingDemandFile); err != nil {
		log.Printf("recording demand clear failed: %v", err)
		writeError(writer, http.StatusInternalServerError, "녹화 요청을 지우지 못했습니다.")
		return
	}
	log.Printf("remote recording stopped")
	writer.WriteHeader(http.StatusNoContent)
}

func (s *Server) listRecordings(writer http.ResponseWriter, request *http.Request) {
	query, err := parseRecordingQuery(request)
	if err != nil {
		writeError(writer, http.StatusBadRequest, "날짜 또는 페이지 범위가 올바르지 않습니다.")
		return
	}
	page, err := s.recordings.Search(query)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "녹화 목록을 읽을 수 없습니다.")
		return
	}
	writeJSON(writer, http.StatusOK, page)
}

// deleteRecording drops one completed recording at the owner's request. Protected recordings
// are refused rather than silently unprotected, so a tap cannot undo a deliberate "keep".
func (s *Server) deleteRecording(writer http.ResponseWriter, request *http.Request) {
	_, session, _ := s.requestSession(request)
	if !csrfMatches(request, session.CSRF) {
		writeError(writer, http.StatusForbidden, "CSRF 검증에 실패했습니다.")
		return
	}
	id := request.PathValue("id")
	err := s.recordings.Delete(request.Context(), id)
	switch {
	case err == nil:
		log.Printf("recording deleted from the web: %s", id)
		writer.WriteHeader(http.StatusNoContent)
	case errors.Is(err, fs.ErrNotExist):
		http.NotFound(writer, request)
	case errors.Is(err, recordings.ErrProtected):
		writeError(writer, http.StatusConflict, "보호된 녹화는 삭제할 수 없습니다. 먼저 보호를 해제하세요.")
	case errors.Is(err, recordings.ErrProtectionUnsupported):
		writeError(writer, http.StatusBadRequest, "정리 중인 임시 세그먼트는 삭제할 수 없습니다. 완성된 녹화를 선택하세요.")
	default:
		log.Printf("recording delete failed for %s: %v", id, err)
		writeError(writer, http.StatusServiceUnavailable, "보호 상태를 확인할 수 없어 삭제하지 않았습니다. iMac 진단 로그를 확인하세요.")
	}
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
	if request.URL.Query().Get("download") == "1" {
		writer.Header().Set("Content-Disposition", `attachment; filename="`+path.Base(id)+`"`)
	}
	writer.Header().Set("Cache-Control", "private, no-store")
	http.ServeContent(writer, request, id, info.ModTime(), file)
}

func (s *Server) proxyLive(writer http.ResponseWriter, request *http.Request) {
	s.mediaProxy.ServeHTTP(writer, request.WithContext(withClientHost(request.Context(), request.Host)))
}

// maxSDPBytes bounds how much of a WHEP answer is read for rewriting; a larger body passes as is.
const maxSDPBytes = 1 << 20

// addReachableCandidates adds the address the phone used to a WHEP answer (see ice.go).
func addReachableCandidates(response *http.Response) error {
	if response.Request == nil || response.Request.Method != http.MethodPost || response.StatusCode != http.StatusCreated ||
		!strings.HasPrefix(strings.ToLower(response.Header.Get("Content-Type")), "application/sdp") {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxSDPBytes+1))
	if err != nil {
		return err
	}
	if len(body) > maxSDPBytes {
		response.Body = struct {
			io.Reader
			io.Closer
		}{io.MultiReader(bytes.NewReader(body), response.Body), response.Body}
		return nil
	}
	_ = response.Body.Close()
	rewritten := body
	if bytes.Contains(body, []byte("a=candidate:")) {
		addresses := candidateAddressesForHost(response.Request.Context(), clientHostFrom(response.Request.Context()))
		rewritten = []byte(addHostCandidates(string(body), addresses))
	}
	response.Body = io.NopCloser(bytes.NewReader(rewritten))
	response.ContentLength = int64(len(rewritten))
	response.Header.Set("Content-Length", strconv.Itoa(len(rewritten)))
	return nil
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
			origin := request.Header.Get("Origin")
			if !s.allowedOrigins[origin] && (origin == "" || origin != hostOrigin(request.Host)) {
				writeError(writer, http.StatusForbidden, "허용되지 않은 요청 출처입니다.")
				return
			}
		}
		next.ServeHTTP(writer, request)
	})
}

// hostOrigin is the origin of a page opened at the address in the Host header. A browser
// sends that origin only from a page it loaded from this gateway at that same address, so
// matching it lets the owner open any address that reaches the Mac (home Wi-Fi, public IP,
// DDNS, Tailscale) without listing it. Another site cannot pass: its pages carry its own
// origin, and a name that merely resolves here fails TLS unless the owner clicks through a
// certificate warning for that foreign name.
func hostOrigin(host string) string {
	if host == "" || strings.ContainsAny(host, "/@?#\\ ") {
		return ""
	}
	return config.CanonicalOrigin("https://" + host)
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
			writer.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; media-src 'self' blob:; frame-src 'self'; base-uri 'none'; form-action 'self'")
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
