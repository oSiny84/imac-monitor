package recordings

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestListAndOpenSafeRecordings(t *testing.T) {
	directory := t.TempDir()
	newer := "motion-20261007T140000-a.mp4"
	older := "motion-20261006T130000-b.mp4"
	for _, name := range []string{newer, older, "ignore.txt", ".hidden.mp4"} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte("video"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	store, err := NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	items, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || items[0].ID != newer || items[1].ID != older {
		t.Fatalf("unexpected recordings: %#v", items)
	}
	file, _, err := store.Open(newer)
	if err != nil {
		t.Fatal(err)
	}
	file.Close()
	if _, _, err := store.Open("../secret.mp4"); err == nil {
		t.Fatal("path traversal was accepted")
	}
}

func TestDateSearchInclusiveStartExclusiveEndAndPages(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"motion-20261020T000000-a.mp4", "motion-20261020T000000-b.mp4", "motion-20261020T235959.mp4", "motion-20261021T000000.mp4"} {
		if err := os.WriteFile(filepath.Join(store.directory, name), []byte("video"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	start := time.Date(2026, 10, 20, 0, 0, 0, 0, time.Local)
	query := Query{From: start, To: start.AddDate(0, 0, 1), Limit: 2}
	page, err := store.Search(query)
	if err != nil || page.Total != 3 || !page.HasMore || len(page.Recordings) != 2 || page.Recordings[1].ID != "motion-20261020T000000-a.mp4" {
		t.Fatalf("page: %#v %v", page, err)
	}
	if page.Recordings[0].ThumbnailURL == "" || page.Recordings[0].DownloadURL == "" {
		t.Fatal("missing archive links")
	}
	query.Offset = 2
	page, err = store.Search(query)
	if err != nil || page.HasMore || len(page.Recordings) != 1 || page.Recordings[0].ID != "motion-20261020T000000-b.mp4" {
		t.Fatalf("page 2: %#v %v", page, err)
	}
	query.Offset = 10000
	page, err = store.Search(query)
	if err != nil || page.Recordings == nil || len(page.Recordings) != 0 || page.Total != 3 {
		t.Fatal("empty page must return an array and total")
	}
}

func TestStoreRefusesOutsideSymlinks(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "private.mp4")
	if err := os.WriteFile(outside, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	id := "linked.mp4"
	if err := os.Symlink(outside, filepath.Join(store.directory, id)); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if _, _, err := store.Open(id); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("symlink was opened")
	}
	items, err := store.List()
	if err != nil || len(items) != 0 {
		t.Fatal("symlink was listed")
	}
}

func TestRecordingTimestampUsesMacLocalTime(t *testing.T) {
	previousLocation := time.Local
	time.Local = time.FixedZone("KST", 9*60*60)
	t.Cleanup(func() { time.Local = previousLocation })
	directory := t.TempDir()
	name := "motion-20261007T140000-a.mp4"
	if err := os.WriteFile(filepath.Join(directory, name), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	items, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	expected := time.Date(2026, 10, 7, 5, 0, 0, 0, time.UTC)
	if len(items) != 1 || !items[0].StartedAt.Equal(expected) {
		t.Fatalf("expected 14:00 KST (05:00 UTC), got %#v", items)
	}
}
