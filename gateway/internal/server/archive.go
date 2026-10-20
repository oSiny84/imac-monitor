package server

import (
	"context"
	"errors"
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
	for _, key := range []string{"from", "to", "limit", "offset"} {
		if len(values[key]) > 1 {
			return query, errors.New("duplicate parameter")
		}
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
