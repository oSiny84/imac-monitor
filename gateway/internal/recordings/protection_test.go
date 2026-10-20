package recordings

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func protectionFixture(t *testing.T) (*Store, string) {
	t.Helper()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	id := "motion-20261020T130000-test.mp4"
	if err := os.WriteFile(filepath.Join(store.directory, id), []byte("original video"), 0o600); err != nil {
		t.Fatal(err)
	}
	return store, id
}

func TestProtectionPersistsIdempotentlyAndFiltersWithoutChangingVideo(t *testing.T) {
	store, id := protectionFixture(t)
	before, err := os.Stat(filepath.Join(store.directory, id))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := store.SetProtected(context.Background(), id, true); err != nil {
			t.Fatal(err)
		}
	}
	reopened, err := NewStore(store.directory)
	if err != nil {
		t.Fatal(err)
	}
	page, err := reopened.Search(Query{ProtectedOnly: true})
	if err != nil || page.Total != 1 || page.ProtectedCount != 1 || page.ProtectedBytes != 14 || !page.Recordings[0].Protected || !page.Recordings[0].ProtectionAvailable {
		t.Fatalf("protected page: %#v %v", page, err)
	}
	marker := filepath.Join(store.directory, protectionDirectory, id+".keep")
	if info, err := os.Stat(marker); err != nil || runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatal("marker missing or not private")
	}
	after, err := os.Stat(filepath.Join(store.directory, id))
	data, readErr := os.ReadFile(filepath.Join(store.directory, id))
	if err != nil || readErr != nil || !before.ModTime().Equal(after.ModTime()) || string(data) != "original video" {
		t.Fatal("protect changed the video")
	}
	for i := 0; i < 2; i++ {
		if err := reopened.SetProtected(context.Background(), id, false); err != nil {
			t.Fatal(err)
		}
	}
	page, err = store.Search(Query{ProtectedOnly: true})
	if err != nil || page.Total != 0 || page.ProtectedCount != 0 || page.Recordings == nil {
		t.Fatalf("unprotect: %#v %v", page, err)
	}
	if _, err := os.Stat(filepath.Join(store.directory, id)); err != nil {
		t.Fatal("unprotect deleted the original")
	}
}

func TestProtectionRejectsMissingAndPendingFilesAndFailsClosedOnMetadataDamage(t *testing.T) {
	store, id := protectionFixture(t)
	if err := store.SetProtected(context.Background(), "missing.mp4", true); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing file: %v", err)
	}
	for _, unsafe := range []string{"segment-20261020T130000.mp4", "../outside.mp4", "wrong.txt"} {
		if err := store.SetProtected(context.Background(), unsafe, true); !errors.Is(err, ErrProtectionUnsupported) {
			t.Fatalf("unsafe/pending file: %v", err)
		}
	}
	if err := os.WriteFile(filepath.Join(store.directory, protectionDirectory), []byte("damaged metadata"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.SetProtected(context.Background(), id, true); !errors.Is(err, ErrProtectionUnavailable) {
		t.Fatal("damaged metadata silently replaced")
	}
	page, err := store.Search(Query{})
	if err != nil || page.ProtectionWarning == "" || page.Recordings[0].ProtectionAvailable || !page.Recordings[0].Protected {
		t.Fatalf("unknown treated as unprotected: %#v %v", page, err)
	}
	data, err := os.ReadFile(filepath.Join(store.directory, protectionDirectory))
	if err != nil || string(data) != "damaged metadata" {
		t.Fatal("metadata was overwritten")
	}
}

func TestProtectionHonorsOSLockDeadlineAndReleasesOnClose(t *testing.T) {
	store, id := protectionFixture(t)
	file, err := os.OpenFile(filepath.Join(store.directory, protectionLock), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	locked, err := tryProtectionLock(file)
	if err != nil || !locked {
		t.Fatalf("lock: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	if err := store.SetProtected(ctx, id, true); !errors.Is(err, ErrProtectionUnavailable) {
		t.Fatalf("write bypassed another open handle's lock: %v", err)
	}
	if _, err := os.Stat(filepath.Join(store.directory, protectionDirectory)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("blocked writer created metadata")
	}
	// No explicit unlock: OS handle closure must release it after a crash too.
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := store.SetProtected(context.Background(), id, true); err != nil {
		t.Fatalf("permanent lock file incorrectly stayed locked: %v", err)
	}
}

func TestProtectionNeverFollowsMetadataOrMarkerSymlinks(t *testing.T) {
	store, id := protectionFixture(t)
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(store.directory, protectionDirectory)); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := store.SetProtected(context.Background(), id, true); !errors.Is(err, ErrProtectionUnavailable) {
		t.Fatal("metadata symlink followed")
	}
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatal("outside directory was modified")
	}
	if err := os.Remove(filepath.Join(store.directory, protectionDirectory)); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(store.directory, protectionDirectory), 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(store.directory, protectionDirectory, id+".keep")
	if err := os.Symlink(outside, marker); err != nil {
		t.Fatal(err)
	}
	if err := store.SetProtected(context.Background(), id, false); !errors.Is(err, ErrProtectionUnavailable) {
		t.Fatal("abnormal marker removed")
	}
	items, err := store.List()
	if err != nil || !items[0].Protected {
		t.Fatal("abnormal marker did not protect the source")
	}
}
