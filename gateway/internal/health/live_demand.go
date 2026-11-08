package health

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// RecordLiveDemand atomically replaces the viewer lease the app polls. The app reacts to the
// content changing and never compares this timestamp with its own clock, so a wall-clock
// change cannot keep the camera on or turn it off.
func RecordLiveDemand(path string, now time.Time) error {
	payload, err := json.Marshal(struct {
		RequestedAt string `json:"requestedAt"`
	}{now.UTC().Format(time.RFC3339Nano)})
	if err != nil {
		return err
	}
	return publish(path, payload, ".live-demand-*", "live demand")
}

// publish replaces path with payload atomically, so the app never reads a half-written file.
func publish(path string, payload []byte, temporaryPattern, label string) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create %s directory: %w", label, err)
	}
	temporary, err := os.CreateTemp(directory, temporaryPattern)
	if err != nil {
		return fmt.Errorf("create %s file: %w", label, err)
	}
	defer os.Remove(temporary.Name())
	if _, err := temporary.Write(payload); err != nil {
		temporary.Close()
		return fmt.Errorf("write %s file: %w", label, err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close %s file: %w", label, err)
	}
	if err := os.Chmod(temporary.Name(), 0o600); err != nil {
		return fmt.Errorf("protect %s file: %w", label, err)
	}
	if err := os.Rename(temporary.Name(), path); err != nil {
		return fmt.Errorf("publish %s file: %w", label, err)
	}
	return nil
}
