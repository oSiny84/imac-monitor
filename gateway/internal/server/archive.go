package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"strconv"
	"time"

	"macmonitor.local/gateway/internal/recordings"
)

type thumbnailSource interface {
	Get(context.Context, string) ([]byte, error)
}

func parseRecordingQuery(request *http.Request) (recordings.Query, error) {
	query := recordings.Query{Limit: 50}
	values := request.URL.Query()
	for _, key := range []string{"from", "to", "limit", "offset", "protected"} {
		if len(values[key]) > 1 {
			return query, errors.New("duplicate parameter")
		}
	}
	if value := values.Get("protected"); value != "" {
		if value != "1" {
			return query, errors.New("invalid protection filter")
		}
		query.ProtectedOnly = true
	}
	for key, target := range map[string]*time.Time{"from": &query.From, "to": &query.To} {
		if value := values.Get(key); value != "" {
			parsed, err := time.Parse(time.RFC3339, value)
			if err != nil {
				return query, err
			}
			*target = parsed
		}
	}
	if !query.From.IsZero() && !query.To.IsZero() && !query.From.Before(query.To) {
		return query, errors.New("invalid interval")
	}
	for key, target := range map[string]*int{"offset": &query.Offset, "limit": &query.Limit} {
		if value := values.Get(key); value != "" {
			number, err := strconv.Atoi(value)
			if err != nil || number < 0 || key == "limit" && (number < 1 || number > 100) {
				return query, errors.New("invalid page")
			}
			*target = number
		}
	}
	return query, nil
}

func (s *Server) setRecordingProtection(writer http.ResponseWriter, request *http.Request) {
	_, session, _ := s.requestSession(request)
	if !csrfMatches(request, session.CSRF) {
		writeError(writer, http.StatusForbidden, "CSRF 검증에 실패했습니다.")
		return
	}
	request.Body = http.MaxBytesReader(writer, request.Body, 1024)
	var input struct {
		Protected *bool `json:"protected"`
	}
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	var extra any
	if err := decoder.Decode(&input); err != nil || input.Protected == nil {
		writeError(writer, http.StatusBadRequest, "보호 상태를 true 또는 false로 지정하세요.")
		return
	}
	if err := decoder.Decode(&extra); err != io.EOF {
		writeError(writer, http.StatusBadRequest, "하나의 보호 설정만 지정하세요.")
		return
	}
	err := s.recordings.SetProtected(request.Context(), request.PathValue("id"), *input.Protected)
	if err != nil {
		switch {
		case errors.Is(err, fs.ErrNotExist):
			http.NotFound(writer, request)
		case errors.Is(err, recordings.ErrProtectionUnsupported):
			writeError(writer, http.StatusBadRequest, "정리 중인 임시 세그먼트는 보호할 수 없습니다. 완성된 녹화를 선택하세요.")
		default:
			writeError(writer, http.StatusServiceUnavailable, "보호 상태를 저장하지 못했습니다. 새로고침해 실제 상태를 확인한 뒤 다시 시도하세요.")
		}
		return
	}
	writeJSON(writer, http.StatusOK, map[string]bool{"protected": *input.Protected})
}

func (s *Server) serveThumbnail(writer http.ResponseWriter, request *http.Request) {
	data, err := s.thumbnails.Get(request.Context(), request.PathValue("id"))
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			http.NotFound(writer, request)
		} else {
			writer.Header().Set("Retry-After", "30")
			writeError(writer, http.StatusServiceUnavailable, "미리보기를 만들 수 없습니다. 영상 재생·다운로드는 사용할 수 있습니다.")
		}
		return
	}
	writer.Header().Set("Content-Type", "image/jpeg")
	writer.Header().Set("Cache-Control", "private, no-store")
	writer.Header().Set("Content-Length", strconv.Itoa(len(data)))
	writer.WriteHeader(http.StatusOK)
	if request.Method != http.MethodHead {
		_, _ = writer.Write(data)
	}
}
