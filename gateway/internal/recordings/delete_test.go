package recordings

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func TestDeleteRemovesOnlyUnprotectedCompletedRecordingsAndFailsClosed(t *testing.T) {
	store, id := protectionFixture(t)
	ctx := context.Background()
	if err := store.Delete(ctx, "segment-20261020T130000.mp4"); !errors.Is(err, ErrProtectionUnsupported) {
		t.Fatalf("a spool segment must not be deletable from the web: %v", err)
	}
	if err := store.Delete(ctx, "motion-20261020T000000-missing.mp4"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing recording: %v", err)
	}
	if err := store.SetProtected(ctx, id, true); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete(ctx, id); !errors.Is(err, ErrProtected) {
		t.Fatalf("protected recording: %v", err)
	}
	if _, err := os.Stat(filepath.Join(store.directory, id)); err != nil {
		t.Fatal("a protected recording was deleted")
	}
	if err := store.SetProtected(ctx, id, false); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete(ctx, id); err != nil {
		t.Fatalf("delete after unprotecting: %v", err)
	}
	if _, err := os.Stat(filepath.Join(store.directory, id)); !os.IsNotExist(err) {
		t.Fatal("the recording is still there after Delete")
	}
	if err := store.Delete(ctx, id); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("second delete: %v", err)
	}

	// An unreadable protection state might hide a "keep" marker, so nothing is deleted.
	other := "remote-20261108T090000.mp4"
	if err := os.WriteFile(filepath.Join(store.directory, other), []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(store.directory, protectionDirectory)); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store.directory, protectionDirectory), []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete(ctx, other); !errors.Is(err, ErrProtectionUnavailable) {
		t.Fatalf("damaged metadata: %v", err)
	}
	if _, err := os.Stat(filepath.Join(store.directory, other)); err != nil {
		t.Fatal("deleted although the protection state was unknown")
	}
}
