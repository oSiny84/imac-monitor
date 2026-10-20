package recordings

import (
	"bytes"
	"context"
	"errors"
	"image/jpeg"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

var ErrThumbnailUnavailable = errors.New("thumbnail unavailable")

const maxThumbnailBytes = 256 * 1024

type thumbnailEntry struct {
	size        int64
	modified    time.Time
	data        []byte
	failedUntil time.Time
	used        uint64
}

// One decoder at a time; at most 128 small JPEGs are kept in memory. No disk
// sidecars can outlive the recording retention policy. Always open the source
// before a cache hit so a deleted recording's thumbnail cannot still be served.
type Thumbnails struct {
	store  *Store
	gate   chan struct{}
	cache  map[string]thumbnailEntry // gate-owned
	clock  uint64
	render func(context.Context, *os.File) ([]byte, error)
}

func NewThumbnails(store *Store) *Thumbnails {
	executable := locateFFmpeg()
	return &Thumbnails{store: store, gate: make(chan struct{}, 1), cache: make(map[string]thumbnailEntry),
		render: func(ctx context.Context, file *os.File) ([]byte, error) { return renderJPEG(ctx, executable, file) }}
}

func (t *Thumbnails) Get(ctx context.Context, id string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	select {
	case t.gate <- struct{}{}:
		defer func() { <-t.gate }()
	case <-ctx.Done():
		return nil, ErrThumbnailUnavailable
	}
	if ctx.Err() != nil {
		return nil, ErrThumbnailUnavailable
	}
	file, info, err := t.store.Open(id)
	if err != nil {
		delete(t.cache, id)
		return nil, err
	}
	defer file.Close()
	t.clock++
	if entry, ok := t.cache[id]; ok && entry.size == info.Size() && entry.modified.Equal(info.ModTime()) {
		entry.used = t.clock
		t.cache[id] = entry
		if entry.data != nil {
			return entry.data, nil
		}
		if time.Now().Before(entry.failedUntil) {
			return nil, ErrThumbnailUnavailable
		}
	}
	// Bound decoding separately from the wait for the single worker.
	decodeCtx, finish := context.WithTimeout(ctx, 8*time.Second)
	defer finish()
	data, err := t.render(decodeCtx, file)
	if err == nil {
		cfg, decodeErr := jpeg.DecodeConfig(bytes.NewReader(data))
		if decodeErr != nil || len(data) > maxThumbnailBytes || cfg.Width < 1 || cfg.Width > 320 || cfg.Height < 1 || cfg.Height > 180 {
			err = ErrThumbnailUnavailable
		}
	}
	entry := thumbnailEntry{size: info.Size(), modified: info.ModTime(), used: t.clock}
	if err == nil {
		entry.data = data
	} else {
		entry.failedUntil = time.Now().Add(30 * time.Second)
	}
	if len(t.cache) >= 128 {
		var oldest string
		var used uint64 = ^uint64(0)
		for key, value := range t.cache {
			if value.used < used {
				oldest, used = key, value.used
			}
		}
		delete(t.cache, oldest)
	}
	t.cache[id] = entry
	if err != nil {
		return nil, ErrThumbnailUnavailable
	}
	return data, nil
}

func locateFFmpeg() string {
	candidates := []string{"/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"}
	if executable, err := os.Executable(); err == nil {
		candidates = append([]string{filepath.Join(filepath.Dir(executable), "ffmpeg")}, candidates...)
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return candidate
		}
	}
	return ""
}

type limitedJPEG struct{ buffer bytes.Buffer }

func (b *limitedJPEG) Len() int      { return b.buffer.Len() }
func (b *limitedJPEG) Bytes() []byte { return b.buffer.Bytes() }
func (b *limitedJPEG) Write(data []byte) (int, error) {
	if b.Len()+len(data) > maxThumbnailBytes {
		return 0, ErrThumbnailUnavailable
	}
	return b.buffer.Write(data)
}

func renderJPEG(ctx context.Context, executable string, file *os.File) ([]byte, error) {
	if executable == "" {
		return nil, ErrThumbnailUnavailable
	}
	// The gateway runs on macOS. Pass an already checked, seekable file descriptor,
	// not a user-supplied path, so retention/symlink races cannot select another file.
	command := exec.CommandContext(ctx, executable, "-hide_banner", "-loglevel", "error", "-nostdin",
		"-threads", "1", "-filter_threads", "1", "-protocol_whitelist", "file,pipe", "-enable_drefs", "0", "-use_absolute_path", "0",
		"-f", "mov", "-i", "/dev/fd/3", "-map", "0:v:0", "-frames:v", "1",
		"-vf", "scale=320:180:force_original_aspect_ratio=decrease", "-threads", "1",
		"-c:v", "mjpeg", "-q:v", "5", "-f", "image2pipe", "pipe:1")
	command.ExtraFiles = []*os.File{file}
	var output limitedJPEG
	command.Stdout = &output
	command.Stderr = io.Discard
	command.WaitDelay = time.Second
	if err := command.Run(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}
