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
	root, err := os.OpenRoot(s.directory)
	if err != nil {
		return ErrProtectionUnavailable
	}
	defer root.Close()
	// Reject a substituted lock rather than following it. Root also confines the
	// open in the presence of a local path replacement race.
	if info, err := root.Lstat(protectionLock); err == nil && !info.Mode().IsRegular() || err != nil && !errors.Is(err, fs.ErrNotExist) {
		return ErrProtectionUnavailable
	}
	file, err := root.OpenFile(protectionLock, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return ErrProtectionUnavailable
	}
	defer file.Close() // Closing also releases the OS lock after a process exit.
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	for {
		locked, err := tryProtectionLock(file)
		if err != nil {
			return ErrProtectionUnavailable
		}
		if locked {
			break
		}
		select {
		case <-ctx.Done():
			return ErrProtectionUnavailable
		case <-time.After(10 * time.Millisecond):
		}
	}
	defer releaseProtectionLock(file)
	if ctx.Err() != nil {
		return ErrProtectionUnavailable
	}
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
