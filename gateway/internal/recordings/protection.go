package recordings

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Shared on-disk contract with RecordingProtectionStore.swift. Never replace or
// unlink the lock file: flock users must keep referring to the same inode.
const protectionDirectory = ".recording-protection"
const protectionLock = ".recording-protection.lock"

var ErrProtectionUnavailable = errors.New("recording protection unavailable")
var ErrProtectionUnsupported = errors.New("only completed recordings can be protected")
var ErrProtected = errors.New("recording is protected")

func supportsProtection(id string) bool {
	return safeRecordingID.MatchString(id) && !strings.HasPrefix(id, "segment-")
}

// Any existing marker means protected, even a malformed one. An unreadable or
// substituted metadata directory is unknown, not evidence of being unprotected.
func protectionState(root *os.Root, id string) (bool, error) {
	info, err := root.Lstat(protectionDirectory)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return true, ErrProtectionUnavailable
	}
	_, err = root.Lstat(filepath.Join(protectionDirectory, id+".keep"))
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return true, ErrProtectionUnavailable
	}
	return true, nil
}

func (s *Store) SetProtected(ctx context.Context, id string, protected bool) error {
	if !supportsProtection(id) {
		return ErrProtectionUnsupported
	}
	root, release, err := s.lockedRoot(ctx)
	if err != nil {
		return err
	}
	defer release()
	// Retention uses the same exclusive lock, so a positive response cannot race
	// a delete already committed by retention: it either wins or returns 404.
	source, _, err := s.Open(id)
	if err != nil {
		return err
	}
	source.Close()
	current, err := protectionState(root, id)
	if err != nil {
		return err
	}
	if protected == current {
		// Also verify an existing marker can be removed before claiming it's a
		// normally managed entry. Weird markers stay protected and require repair.
		if !current {
			return nil
		}
		info, err := root.Lstat(filepath.Join(protectionDirectory, id+".keep"))
		if err != nil || !info.Mode().IsRegular() {
			return ErrProtectionUnavailable
		}
		return nil
	}
	marker := filepath.Join(protectionDirectory, id+".keep")
	if !protected {
		info, err := root.Lstat(marker)
		if err != nil || !info.Mode().IsRegular() {
			return ErrProtectionUnavailable
		}
		if err := root.Remove(marker); err != nil {
			return ErrProtectionUnavailable
		}
		return nil
	}
	if err := root.Mkdir(protectionDirectory, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return ErrProtectionUnavailable
	}
	if info, err := root.Lstat(protectionDirectory); err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return ErrProtectionUnavailable
	}
	markerFile, err := root.OpenFile(marker, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return ErrProtectionUnavailable
	}
	// Existence is the complete marker format, so an interrupted write still
	// protects the recording. No partial JSON can silently discard protection.
	err = markerFile.Sync()
	closeErr := markerFile.Close()
	if err != nil || closeErr != nil {
		return ErrProtectionUnavailable
	}
	return nil
}

// lockedRoot opens the recordings directory and takes the exclusive lock that protection
// writers and the app's retention pass share. The caller must call release.
func (s *Store) lockedRoot(ctx context.Context) (*os.Root, func(), error) {
	root, err := os.OpenRoot(s.directory)
	if err != nil {
		return nil, nil, ErrProtectionUnavailable
	}
	// Reject a substituted lock rather than following it. Root also confines the
	// open in the presence of a local path replacement race.
	if info, err := root.Lstat(protectionLock); err == nil && !info.Mode().IsRegular() || err != nil && !errors.Is(err, fs.ErrNotExist) {
		root.Close()
		return nil, nil, ErrProtectionUnavailable
	}
	file, err := root.OpenFile(protectionLock, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		root.Close()
		return nil, nil, ErrProtectionUnavailable
	}
	fail := func() (*os.Root, func(), error) {
		file.Close() // Closing also releases the OS lock after a process exit.
		root.Close()
		return nil, nil, ErrProtectionUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	for {
		locked, err := tryProtectionLock(file)
		if err != nil {
			return fail()
		}
		if locked {
			break
		}
		select {
		case <-ctx.Done():
			return fail()
		case <-time.After(10 * time.Millisecond):
		}
	}
	release := func() {
		releaseProtectionLock(file)
		file.Close()
		root.Close()
	}
	return root, release, nil
}

// Delete removes a completed recording the owner chose to drop from the web. It holds the
// same lock as retention, so it cannot interleave with the app's own cleanup, and it fails
// closed when the protection state cannot be read: an unreadable marker might mean "keep".
// A protected recording is refused; the owner unprotects it first, as a second look.
func (s *Store) Delete(ctx context.Context, id string) error {
	if !supportsProtection(id) {
		return ErrProtectionUnsupported
	}
	root, release, err := s.lockedRoot(ctx)
	if err != nil {
		return err
	}
	defer release()
	source, _, err := s.Open(id)
	if err != nil {
		return err
	}
	source.Close()
	protected, err := protectionState(root, id)
	if err != nil {
		return err
	}
	if protected {
		return ErrProtected
	}
	if err := root.Remove(id); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return fs.ErrNotExist
		}
		return err
	}
	return nil
}
