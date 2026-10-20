package config

import (
	"path/filepath"
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
	cfg.MonitoringStatusFile = "relative/status.json"
	if err := cfg.Validate(); err == nil {
		t.Fatal("relative status path accepted")
	}
}
