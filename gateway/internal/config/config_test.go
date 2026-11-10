package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidationRejectsUnsafeMediaTarget(t *testing.T) {
	config := Config{
		ListenAddress:       ":8443",
		TLSCertificateFile:  filepath.Join(t.TempDir(), "cert.pem"),
		TLSPrivateKeyFile:   filepath.Join(t.TempDir(), "key.pem"),
		PublicOrigin:        "https://camera.example",
		MediaMTXURL:         "http://camera.example:8889",
		RecordingsDirectory: filepath.Join(t.TempDir(), "recordings"),
		PasswordHash:        "pbkdf2_sha256$dummy",
		SessionIdleMinutes:  30,
		SessionMaxHours:     24,
	}
	if err := config.Validate(); err == nil {
		t.Fatal("expected non-loopback MediaMTX target to be rejected")
	}
	config.MediaMTXURL = "http://127.0.0.1:8889"
	if err := config.Validate(); err != nil {
		t.Fatalf("safe config failed: %v", err)
	}
}

func TestLegacyConfigDerivesPrivateStatusPathAndRejectsRelativeOverride(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{ListenAddress: ":8443", TLSCertificateFile: filepath.Join(dir, "cert.pem"),
		TLSPrivateKeyFile: filepath.Join(dir, "key.pem"), PublicOrigin: "https://camera.example",
		MediaMTXURL: "http://127.0.0.1:8889", RecordingsDirectory: filepath.Join(dir, "Recordings"),
		PasswordHash: "pbkdf2_sha256$dummy", SessionIdleMinutes: 30, SessionMaxHours: 24}
	file := filepath.Join(dir, "gateway.json")
	if err := Save(file, cfg); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(file)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.MonitoringStatusFile != filepath.Join(dir, "Runtime", "monitoring-status.json") {
		t.Fatalf("bad status path: %s", loaded.MonitoringStatusFile)
	}
	if loaded.LiveDemandFile != filepath.Join(dir, "Runtime", "live-demand.json") {
		t.Fatalf("bad live demand path: %s", loaded.LiveDemandFile)
	}
	if loaded.RecordingDemandFile != filepath.Join(dir, "Runtime", "recording-demand.json") {
		t.Fatalf("bad recording demand path: %s", loaded.RecordingDemandFile)
	}
	if loaded.TelegramFile != filepath.Join(dir, "telegram.json") {
		t.Fatalf("bad telegram path: %s", loaded.TelegramFile)
	}
	cfg.MonitoringStatusFile = "relative/status.json"
	if err := cfg.Validate(); err == nil {
		t.Fatal("relative status path accepted")
	}
	cfg.MonitoringStatusFile = ""
	cfg.LiveDemandFile = "relative/live-demand.json"
	if err := cfg.Validate(); err == nil {
		t.Fatal("relative live demand path accepted")
	}
	cfg.LiveDemandFile = ""
	cfg.RecordingDemandFile = "relative/recording-demand.json"
	if err := cfg.Validate(); err == nil {
		t.Fatal("relative recording demand path accepted")
	}
	cfg.RecordingDemandFile = ""
	cfg.LiveDemandFile = ""
	cfg.TelegramFile = "relative/telegram.json"
	if err := cfg.Validate(); err == nil {
		t.Fatal("relative telegram path accepted")
	}
}

func TestAdditionalOriginsAreValidatedSavedAndListedAfterThePublicOrigin(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{ListenAddress: ":8443", TLSCertificateFile: filepath.Join(dir, "cert.pem"),
		TLSPrivateKeyFile: filepath.Join(dir, "key.pem"), PublicOrigin: "https://192.168.0.7:8443",
		AdditionalOrigins: []string{"https://203.0.113.5:8443"},
		MediaMTXURL:       "http://127.0.0.1:8889", RecordingsDirectory: filepath.Join(dir, "Recordings"),
		PasswordHash: "pbkdf2_sha256$dummy", SessionIdleMinutes: 30, SessionMaxHours: 24}
	file := filepath.Join(dir, "gateway.json")
	if err := Save(file, cfg); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(file)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(loaded.AllowedOrigins(), " "); got != "https://192.168.0.7:8443 https://203.0.113.5:8443" {
		t.Fatalf("allowed origins: %s", got)
	}

	// Without extra origins the key is left out, so the file reads as before.
	cfg.AdditionalOrigins = nil
	if err := Save(file, cfg); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "additionalOrigins") {
		t.Fatalf("empty additionalOrigins written: %s", data)
	}

	for _, bad := range [][]string{
		{"http://203.0.113.5:8443"},
		{"https://203.0.113.5:8443/"},
		{"https://203.0.113.5:8443/live"},
		{"https://203.0.113.5:8443?x=1"},
		{"https://user@203.0.113.5:8443"},
		{"https://:8443"},
		{""},
		{"https://192.168.0.7:8443"},
		{"https://203.0.113.010:8443"},
		{"https://0xcb.0.113.10"},
		{"https://cam.example.123"},
		{"https://203.0.113.5:8443", "https://203.0.113.5:8443"},
		{"https://cam.example", "https://CAM.example:443"},
		{"https://a.example", "https://b.example", "https://c.example", "https://d.example", "https://e.example"},
	} {
		cfg.AdditionalOrigins = bad
		if err := cfg.Validate(); err == nil {
			t.Fatalf("additionalOrigins %q accepted", bad)
		}
	}
}

func TestCanonicalOriginMatchesWhatBrowsersSend(t *testing.T) {
	for raw, want := range map[string]string{
		"https://Camera.Example:443":   "https://camera.example",
		"https://camera.example":       "https://camera.example",
		"https://203.0.113.5:8443":     "https://203.0.113.5:8443",
		"https://[2001:db8::1]:8443":   "https://[2001:db8::1]:8443",
		"https://[2001:db8::1]:443":    "https://[2001:db8::1]",
		"https://CAM.example.net:8443": "https://cam.example.net:8443",
	} {
		if got := CanonicalOrigin(raw); got != want {
			t.Fatalf("CanonicalOrigin(%q) = %q, want %q", raw, got, want)
		}
	}
}
