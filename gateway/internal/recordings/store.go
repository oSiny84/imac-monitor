package recordings

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var safeRecordingID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,199}\.mp4$`)

type Recording struct {
	ID           string    `json:"id"`
	StartedAt    time.Time `json:"startedAt"`
	SizeBytes    int64     `json:"sizeBytes"`
	URL          string    `json:"url"`
	ThumbnailURL string    `json:"thumbnailURL"`
	DownloadURL  string    `json:"downloadURL"`
}

type Store struct {
	directory string
}

func NewStore(directory string) (*Store, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("recordings directory must be absolute")
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return nil, err
	}
	return &Store{directory: filepath.Clean(directory)}, nil
}

func (s *Store) List() ([]Recording, error) {
	entries, err := os.ReadDir(s.directory)
	if err != nil {
		return nil, err
	}
	recordings := make([]Recording, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 || !safeRecordingID.MatchString(entry.Name()) {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		recordings = append(recordings, Recording{
			ID:           entry.Name(),
			StartedAt:    recordingTime(entry.Name(), info),
			SizeBytes:    info.Size(),
			URL:          "/recordings/" + entry.Name(),
			ThumbnailURL: "/api/recordings/" + entry.Name() + "/thumbnail",
			DownloadURL:  "/recordings/" + entry.Name() + "?download=1",
		})
	}
	sort.Slice(recordings, func(i, j int) bool {
		if recordings[i].StartedAt.Equal(recordings[j].StartedAt) {
			return recordings[i].ID < recordings[j].ID
		}
		return recordings[i].StartedAt.After(recordings[j].StartedAt)
	})
	return recordings, nil
}

func (s *Store) Open(id string) (*os.File, fs.FileInfo, error) {
	if !safeRecordingID.MatchString(id) || filepath.Base(id) != id {
		return nil, nil, fs.ErrNotExist
	}
	path := filepath.Join(s.directory, id)
	linkInfo, err := os.Lstat(path)
	if err != nil || !linkInfo.Mode().IsRegular() {
		return nil, nil, fs.ErrNotExist
	}
	// Root.Open prevents an outside-directory escape even if a symlink replaces
	// the checked entry between Lstat and Open.
	root, err := os.OpenRoot(s.directory)
	if err != nil {
		return nil, nil, err
	}
	defer root.Close()
	file, err := root.Open(id)
	if err != nil {
		return nil, nil, err
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		file.Close()
		if err != nil {
			return nil, nil, err
		}
		return nil, nil, fs.ErrNotExist
	}
	return file, info, nil
}

type Query struct {
	From, To      time.Time // Inclusive from, exclusive to; zero means unbounded.
	Offset, Limit int
}

type Page struct {
	Recordings []Recording `json:"recordings"`
	Total      int         `json:"total"`
	HasMore    bool        `json:"hasMore"`
}

func (s *Store) Search(query Query) (Page, error) {
	items, err := s.List()
	if err != nil {
		return Page{}, err
	}
	filtered := make([]Recording, 0)
	for _, item := range items {
		if !query.From.IsZero() && item.StartedAt.Before(query.From) {
			continue
		}
		if !query.To.IsZero() && !item.StartedAt.Before(query.To) {
			continue
		}
		filtered = append(filtered, item)
	}
	limit := query.Limit
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	start := min(max(query.Offset, 0), len(filtered))
	end := start + min(limit, len(filtered)-start)
	return Page{Recordings: filtered[start:end], Total: len(filtered), HasMore: end < len(filtered)}, nil
}

func recordingTime(name string, fallback fs.FileInfo) time.Time {
	trimmed := strings.TrimSuffix(name, ".mp4")
	for _, prefix := range []string{"motion-", "segment-"} {
		if strings.HasPrefix(trimmed, prefix) {
			value := strings.TrimPrefix(trimmed, prefix)
			if separator := strings.IndexByte(value, '-'); separator > 0 {
				value = value[:separator]
			}
			// FFmpeg strftime and the Swift event merger name files in the Mac's
			// local time zone. Parsing as UTC shifts the browser's displayed time.
			if parsed, err := time.ParseInLocation("20060102T150405", value, time.Local); err == nil {
				return parsed
			}
		}
	}
	return fallback.ModTime()
}
