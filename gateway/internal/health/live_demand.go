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
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create live demand directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".live-demand-*")
	if err != nil {
		return fmt.Errorf("create live demand file: %w", err)
	}
	defer os.Remove(temporary.Name())
	if _, err := temporary.Write(payload); err != nil {
		temporary.Close()
		return fmt.Errorf("write live demand file: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close live demand file: %w", err)
	}
	if err := os.Chmod(temporary.Name(), 0o600); err != nil {
		return fmt.Errorf("protect live demand file: %w", err)
	}
	if err := os.Rename(temporary.Name(), path); err != nil {
		return fmt.Errorf("publish live demand file: %w", err)
	}
	return nil
}
