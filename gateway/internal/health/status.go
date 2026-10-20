package health

import (
	"encoding/json"
	"io"
	"math"
	"os"
	"time"
)

type Snapshot struct {
	SchemaVersion      int        `json:"schemaVersion"`
	UpdatedAt          *time.Time `json:"updatedAt,omitempty"`
	State              string     `json:"state"`
	Detail             string     `json:"detail"`
	ExpectingFrames    bool       `json:"expectingFrames"`
	CaptureStartedAt   *time.Time `json:"captureStartedAt,omitempty"`
	LastFrameAt        *time.Time `json:"lastFrameAt,omitempty"`
	CaptureFPS         float64    `json:"captureFPS"`
	TotalFrames        uint64     `json:"totalFrames"`
	LastMotionAt       *time.Time `json:"lastMotionAt,omitempty"`
	LastRecordingAt    *time.Time `json:"lastRecordingAt,omitempty"`
	LastRecordingName  string     `json:"lastRecordingName,omitempty"`
	DiskFreeBytes      *int64     `json:"diskFreeBytes,omitempty"`
	WatchdogRecoveries int        `json:"watchdogRecoveries"`
	LastRecoveryAt     *time.Time `json:"lastRecoveryAt,omitempty"`
	RetentionWarning   string     `json:"retentionWarning,omitempty"`
}

type Status struct {
	Snapshot
	Available  bool   `json:"available"`
	Fresh      bool   `json:"fresh"`
	FrameState string `json:"frameState"`
}

// Read a bounded, private app snapshot. A missing, malformed or old status file
// never disables archive access and never implies the camera is working.
func Read(path string, now time.Time) Status {
	unknown := Status{Snapshot: Snapshot{State: "unknown", Detail: "감시 상태를 확인할 수 없습니다."}, FrameState: "unknown"}
	if path == "" {
		return unknown
	}
	file, err := os.Open(path)
	if err != nil {
		return unknown
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 64*1024 {
		return unknown
	}
	decoder := json.NewDecoder(io.LimitReader(file, 64*1024+1))
	var snapshot Snapshot
	if err := decoder.Decode(&snapshot); err != nil {
		return unknown
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return unknown
	}
	if snapshot.SchemaVersion != 1 || snapshot.UpdatedAt == nil || snapshot.UpdatedAt.IsZero() ||
		math.IsNaN(snapshot.CaptureFPS) || math.IsInf(snapshot.CaptureFPS, 0) || snapshot.CaptureFPS < 0 ||
		snapshot.WatchdogRecoveries < 0 || (snapshot.DiskFreeBytes != nil && *snapshot.DiskFreeBytes < 0) {
		return unknown
	}
	switch snapshot.State {
	case "running", "starting", "stopped", "stopping", "recovering", "failed", "scheduledRest", "sleeping":
	default:
		return unknown
	}
	if (snapshot.State == "running") != snapshot.ExpectingFrames {
		return unknown
	}
	status := Status{Snapshot: snapshot, Available: true, Fresh: true, FrameState: "inactive"}
	age := now.Sub(*snapshot.UpdatedAt)
	if age > 15*time.Second || age < -5*time.Second {
		status.Fresh = false
		status.State = "stale"
		status.Detail = "앱 상태 갱신이 지연되었습니다. 실제 촬영을 확인하세요."
		status.FrameState = "unknown"
		status.CaptureFPS = 0
		return status
	}
	if !snapshot.ExpectingFrames {
		status.CaptureFPS = 0
		return status
	}
	if snapshot.CaptureStartedAt == nil || snapshot.CaptureStartedAt.After(now.Add(5*time.Second)) {
		return unknown
	}
	if snapshot.TotalFrames == 0 {
		status.FrameState = "waiting"
		if now.Sub(*snapshot.CaptureStartedAt) >= 15*time.Second {
			status.FrameState = "stalled"
		}
	} else if snapshot.LastFrameAt == nil || now.Sub(*snapshot.LastFrameAt) >= 10*time.Second {
		status.FrameState = "stalled"
	} else if snapshot.LastFrameAt.After(now.Add(5 * time.Second)) {
		return unknown
	} else {
		status.FrameState = "receiving"
	}
	return status
}
