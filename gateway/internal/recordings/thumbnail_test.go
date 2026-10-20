package recordings

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func thumbnailFixture(t *testing.T) (*Thumbnails, string, []byte) {
	t.Helper()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	id := "motion-20261020T120000-test.mp4"
	if err := os.WriteFile(filepath.Join(store.directory, id), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	var data bytes.Buffer
	if err := jpeg.Encode(&data, image.NewRGBA(image.Rect(0, 0, 32, 18)), nil); err != nil {
		t.Fatal(err)
	}
	return NewThumbnails(store), id, data.Bytes()
}

func TestThumbnailCacheInvalidatesChangedAndDeletedSources(t *testing.T) {
	thumbnails, id, jpegData := thumbnailFixture(t)
	calls := 0
	thumbnails.render = func(context.Context, *os.File) ([]byte, error) { calls++; return jpegData, nil }
	for i := 0; i < 2; i++ {
		data, err := thumbnails.Get(context.Background(), id)
		if err != nil || !bytes.Equal(data, jpegData) {
			t.Fatalf("thumbnail: %v", err)
		}
	}
	if calls != 1 {
		t.Fatalf("cache missed: %d", calls)
	}
	file := filepath.Join(thumbnails.store.directory, id)
	if err := os.WriteFile(file, []byte("changed video"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := thumbnails.Get(context.Background(), id); err != nil || calls != 2 {
		t.Fatalf("changed source was cached: %v, calls=%d", err, calls)
	}
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if _, err := thumbnails.Get(context.Background(), id); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("deleted thumbnail leaked: %v", err)
	}
	if _, err := thumbnails.Get(context.Background(), "../outside.mp4"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("unsafe path accepted")
	}
}

func TestThumbnailRejectsCorruptOversizedAndCachesFailure(t *testing.T) {
	for _, test := range []struct {
		name string
		data []byte
	}{
		{"corrupt", []byte("not jpeg")}, {"oversized", make([]byte, maxThumbnailBytes+1)},
	} {
		t.Run(test.name, func(t *testing.T) {
			thumbnails, id, _ := thumbnailFixture(t)
			calls := 0
			thumbnails.render = func(context.Context, *os.File) ([]byte, error) { calls++; return test.data, nil }
			for i := 0; i < 2; i++ {
				if _, err := thumbnails.Get(context.Background(), id); !errors.Is(err, ErrThumbnailUnavailable) {
					t.Fatal("bad image accepted")
				}
			}
			if calls != 1 {
				t.Fatalf("corrupt input repeatedly decoded: %d", calls)
			}
		})
	}
	var output limitedJPEG
	if _, err := output.Write(make([]byte, maxThumbnailBytes+1)); err == nil || output.Len() != 0 {
		t.Fatal("decoder output not bounded")
	}
}

func TestThumbnailSerializesWorkHonorsCancellationAndBoundsCache(t *testing.T) {
	thumbnails, id, jpegData := thumbnailFixture(t)
	var active, peak atomic.Int32
	thumbnails.render = func(context.Context, *os.File) ([]byte, error) {
		n := active.Add(1)
		if n > peak.Load() {
			peak.Store(n)
		}
		time.Sleep(time.Millisecond)
		active.Add(-1)
		return jpegData, nil
	}
	var group sync.WaitGroup
	for i := 0; i < 8; i++ {
		name := fmt.Sprintf("parallel-%d.mp4", i)
		if err := os.WriteFile(filepath.Join(thumbnails.store.directory, name), []byte("video"), 0o600); err != nil {
			t.Fatal(err)
		}
		group.Add(1)
		go func(source string) {
			defer group.Done()
			if _, err := thumbnails.Get(context.Background(), source); err != nil {
				t.Error(err)
			}
		}(name)
	}
	group.Wait()
	if peak.Load() != 1 {
		t.Fatal("multiple thumbnail decoders ran")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := thumbnails.Get(ctx, id); !errors.Is(err, ErrThumbnailUnavailable) {
		t.Fatal("canceled request served")
	}
	for i := 0; i < 130; i++ {
		name := fmt.Sprintf("event-%d.mp4", i)
		if err := os.WriteFile(filepath.Join(thumbnails.store.directory, name), []byte("video"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := thumbnails.Get(context.Background(), name); err != nil {
			t.Fatal(err)
		}
	}
	if len(thumbnails.cache) != 128 {
		t.Fatalf("cache grew beyond bound: %d", len(thumbnails.cache))
	}
}

func TestThumbnailRealFFmpegWithSeekableDescriptor(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("descriptor integration requires macOS/Linux")
	}
	executable := locateFFmpeg()
	if executable == "" {
		t.Skip("FFmpeg not installed")
	}
	thumbnails, id, _ := thumbnailFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	// Put moov at the end (no faststart) to verify that descriptor input can seek.
	command := exec.CommandContext(ctx, executable, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=64x48:d=0.2", "-c:v", "mpeg4", filepath.Join(thumbnails.store.directory, id))
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("fixture encoding: %v %s", err, output)
	}
	data, err := thumbnails.Get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := jpeg.Decode(bytes.NewReader(data)); err != nil {
		t.Fatal(err)
	}
}
