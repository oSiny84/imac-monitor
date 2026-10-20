package health

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReadFramesGracePauseStaleAndUnknownStates(t *testing.T) {
	now := time.Date(2026, 10, 20, 5, 0, 0, 0, time.UTC)
	ago := func(seconds int) *time.Time { value := now.Add(-time.Duration(seconds) * time.Second); return &value }
	base := Snapshot{SchemaVersion: 1, UpdatedAt: &now, State: "running", ExpectingFrames: true,
		CaptureStartedAt: ago(30), LastFrameAt: ago(1), CaptureFPS: 15, TotalFrames: 20, RetentionWarning: "disk pressure; protected files retained"}
	for _, tc := range []struct {
		name          string
		change        func(*Snapshot)
		state, frames string
		fresh         bool
	}{
		{"receiving", func(*Snapshot) {}, "running", "receiving", true},
		{"stalled camera", func(s *Snapshot) { s.LastFrameAt = ago(10) }, "running", "stalled", true},
		{"first frame grace", func(s *Snapshot) { s.TotalFrames = 0; s.LastFrameAt = nil; s.CaptureStartedAt = ago(14) }, "running", "waiting", true},
		{"first frame timeout", func(s *Snapshot) { s.TotalFrames = 0; s.CaptureStartedAt = ago(15) }, "running", "stalled", true},
		{"manual stop", func(s *Snapshot) { s.State = "stopped"; s.ExpectingFrames = false; s.LastFrameAt = ago(3600) }, "stopped", "inactive", true},
		{"scheduled rest", func(s *Snapshot) { s.State = "scheduledRest"; s.ExpectingFrames = false; s.LastFrameAt = ago(3600) }, "scheduledRest", "inactive", true},
		{"recovering", func(s *Snapshot) { s.State = "recovering"; s.ExpectingFrames = false }, "recovering", "inactive", true},
		{"stale app", func(s *Snapshot) { s.UpdatedAt = ago(16) }, "stale", "unknown", false},
		{"future clock", func(s *Snapshot) { s.UpdatedAt = ago(-6) }, "stale", "unknown", false},
		{"future frame", func(s *Snapshot) { s.LastFrameAt = ago(-6) }, "unknown", "unknown", false},
		{"invalid schema", func(s *Snapshot) { s.SchemaVersion = 9 }, "unknown", "unknown", false},
		{"invalid state", func(s *Snapshot) { s.State = "anything" }, "unknown", "unknown", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			snapshot := base
			tc.change(&snapshot)
			file := filepath.Join(t.TempDir(), "status.json")
			data, err := json.Marshal(snapshot)
			if err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(file, data, 0o600); err != nil {
				t.Fatal(err)
			}
			result := Read(file, now)
			if result.State != tc.state || result.FrameState != tc.frames || result.Fresh != tc.fresh {
				t.Fatalf("unexpected status: %+v", result)
			}
			if result.FrameState == "inactive" && result.CaptureFPS != 0 {
				t.Fatal("paused FPS must be zero")
			}
			if result.Available && result.RetentionWarning != base.RetentionWarning {
				t.Fatal("retention warning was discarded")
			}
		})
	}
}

func TestUnreadableMalformedAndOversizedStatusAreUnavailable(t *testing.T) {
	file := filepath.Join(t.TempDir(), "status.json")
	if Read(file, time.Now()).Available {
		t.Fatal("missing file cannot be healthy")
	}
	for _, data := range []string{`{`, `{}`, `{} {}`, strings.Repeat("x", 65537)} {
		if err := os.WriteFile(file, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
		if result := Read(file, time.Now()); result.Available || result.State != "unknown" {
			t.Fatalf("invalid status accepted: %+v", result)
		}
	}
}
