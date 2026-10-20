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
	ID        string    `json:"id"`
	StartedAt time.Time `json:"startedAt"`
	SizeBytes int64     `json:"sizeBytes"`
	URL       string    `json:"url"`
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
			ID:        entry.Name(),
			StartedAt: recordingTime(entry.Name(), info),
			SizeBytes: info.Size(),
			URL:       "/recordings/" + entry.Name(),
		})
	}
	sort.Slice(recordings, func(i, j int) bool {
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
	if err != nil || linkInfo.Mode()&os.ModeSymlink != 0 {
		return nil, nil, fs.ErrNotExist
	}
	file, err := os.Open(path)
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
