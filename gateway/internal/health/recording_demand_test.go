package health

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestRecordingDemandRoundTripUsesWholeSecondsAndEndsOnTime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "Runtime", "recording-demand.json")
	now := time.Date(2026, 11, 8, 9, 0, 0, 123_456_789, time.FixedZone("KST", 9*3600))
	demand, err := WriteRecordingDemand(path, now, 4)
	if err != nil {
		t.Fatal(err)
	}
	if !demand.Until.Equal(time.Date(2026, 11, 8, 4, 0, 0, 0, time.UTC)) {
		t.Fatalf("until: %v", demand.Until)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	// The app's ISO 8601 parser rejects fractional seconds, so the file must never carry them.
	for _, field := range []string{`"until":"2026-11-08T04:00:00Z"`, `"requestedAt":"2026-11-08T00:00:00Z"`, `"schemaVersion":1`, `"hours":4`} {
		if !strings.Contains(string(raw), field) {
			t.Fatalf("file %s lacks %s", raw, field)
		}
	}
	if regexp.MustCompile(`\d{2}:\d{2}:\d{2}\.\d`).Match(raw) {
		t.Fatalf("fractional seconds written: %s", raw)
	}
	read := ReadRecordingDemand(path, demand.Until.Add(-time.Second))
	if read == nil || !read.Until.Equal(demand.Until) || read.Hours != 4 {
		t.Fatalf("read back: %#v", read)
	}
	if ReadRecordingDemand(path, demand.Until) != nil {
		t.Fatal("a request is over at its end time")
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("temporary files left beside the request: %v", entries)
	}
	if err := ClearRecordingDemand(path); err != nil {
		t.Fatal(err)
	}
	if ReadRecordingDemand(path, now) != nil {
		t.Fatal("a cleared request still reads as active")
	}
	if err := ClearRecordingDemand(path); err != nil {
		t.Fatalf("clearing twice must be harmless: %v", err)
	}
}

func TestRecordingDemandRejectsBadHoursAndIgnoresWrongFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "recording-demand.json")
	for _, hours := range []int{0, 25, -1} {
		if _, err := WriteRecordingDemand(path, time.Now(), hours); err == nil {
			t.Fatalf("%d hours accepted", hours)
		}
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("a rejected request wrote a file")
	}
	for name, content := range map[string]string{
		"not json":      "nope",
		"wrong schema":  `{"schemaVersion":2,"until":"2999-01-01T00:00:00Z","hours":2}`,
		"zero hours":    `{"schemaVersion":1,"until":"2999-01-01T00:00:00Z","hours":0}`,
		"too many":      `{"schemaVersion":1,"until":"2999-01-01T00:00:00Z","hours":25}`,
		"bad time":      `{"schemaVersion":1,"until":"tomorrow","hours":2}`,
		"already ended": `{"schemaVersion":1,"until":"2000-01-01T00:00:00Z","hours":2}`,
	} {
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if ReadRecordingDemand(path, time.Now()) != nil {
			t.Fatalf("%s read as an active request", name)
		}
	}
	if ReadRecordingDemand("", time.Now()) != nil {
		t.Fatal("an unconfigured path read as a request")
	}
}
