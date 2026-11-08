package health

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"time"
)

// MaxRecordingHours bounds a remote recording request. A day at 1,200 kbps is about 13 GB,
// which fits under the app's default 20 GB cap.
const MaxRecordingHours = 24

// RecordingDemand is the remote "record for N hours" request. The web writes it, the app
// records until Until, and the web shows the remaining time from the same file.
type RecordingDemand struct {
	Until       time.Time `json:"until"`
	Hours       int       `json:"hours"`
	RequestedAt time.Time `json:"requestedAt"`
}

// recordingDemandFile is the on-disk form. Times are RFC 3339 in UTC without fractional
// seconds: the app parses them with Foundation's default ISO 8601 parser, which rejects
// fractions. Go's time.Time would add them whenever the clock is not on a whole second.
type recordingDemandFile struct {
	SchemaVersion int    `json:"schemaVersion"`
	Until         string `json:"until"`
	Hours         int    `json:"hours"`
	RequestedAt   string `json:"requestedAt"`
}

// WriteRecordingDemand publishes a request ending hours after now.
func WriteRecordingDemand(path string, now time.Time, hours int) (RecordingDemand, error) {
	if hours < 1 || hours > MaxRecordingHours {
		return RecordingDemand{}, fmt.Errorf("recording hours must be between 1 and %d", MaxRecordingHours)
	}
	requestedAt := now.UTC().Truncate(time.Second)
	demand := RecordingDemand{Until: requestedAt.Add(time.Duration(hours) * time.Hour), Hours: hours, RequestedAt: requestedAt}
	payload, err := json.Marshal(recordingDemandFile{
		SchemaVersion: 1,
		Until:         demand.Until.Format(time.RFC3339),
		Hours:         hours,
		RequestedAt:   requestedAt.Format(time.RFC3339),
	})
	if err != nil {
		return RecordingDemand{}, err
	}
	if err := publish(path, payload, ".recording-demand-*", "recording demand"); err != nil {
		return RecordingDemand{}, err
	}
	return demand, nil
}

// ClearRecordingDemand ends the request. A request that is already gone is not an error, so
// pressing stop twice, or after the app's own menu item, is harmless.
func ClearRecordingDemand(path string) error {
	err := os.Remove(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("remove recording demand file: %w", err)
	}
	return nil
}

// ReadRecordingDemand returns the active request, or nil when the file is missing, malformed
// or already past its end time. It mirrors the app's reading so both sides agree.
func ReadRecordingDemand(path string, now time.Time) *RecordingDemand {
	if path == "" {
		return nil
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 4096 {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var file recordingDemandFile
	if err := json.Unmarshal(data, &file); err != nil || file.SchemaVersion != 1 ||
		file.Hours < 1 || file.Hours > MaxRecordingHours {
		return nil
	}
	until, err := time.Parse(time.RFC3339, file.Until)
	if err != nil || !until.After(now) {
		return nil
	}
	requestedAt, err := time.Parse(time.RFC3339, file.RequestedAt)
	if err != nil {
		requestedAt = until.Add(-time.Duration(file.Hours) * time.Hour)
	}
	return &RecordingDemand{Until: until, Hours: file.Hours, RequestedAt: requestedAt}
}
