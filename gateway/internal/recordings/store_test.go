package recordings

import (
	"os"
	"path/filepath"
	"testing"
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
