package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	ListenAddress       string `json:"listenAddress"`
	TLSCertificateFile  string `json:"tlsCertificateFile"`
	TLSPrivateKeyFile   string `json:"tlsPrivateKeyFile"`
	PublicOrigin        string `json:"publicOrigin"`
	MediaMTXURL         string `json:"mediaMTXURL"`
	RecordingsDirectory string `json:"recordingsDirectory"`
	PasswordHash        string `json:"passwordHash"`
	SessionIdleMinutes  int    `json:"sessionIdleMinutes"`
	SessionMaxHours     int    `json:"sessionMaxHours"`
}

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	var cfg Config
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("decode config: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return Config{}, errors.New("decode config: exactly one JSON value is required")
	}
	if cfg.SessionIdleMinutes == 0 {
		cfg.SessionIdleMinutes = 30
	}
	if cfg.SessionMaxHours == 0 {
		cfg.SessionMaxHours = 24
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if c.ListenAddress == "" || c.TLSCertificateFile == "" || c.TLSPrivateKeyFile == "" {
		return errors.New("listenAddress, tlsCertificateFile and tlsPrivateKeyFile are required")
	}
	if !filepath.IsAbs(c.TLSCertificateFile) || !filepath.IsAbs(c.TLSPrivateKeyFile) {
		return errors.New("TLS certificate and private key paths must be absolute")
	}
	origin, err := url.Parse(c.PublicOrigin)
	if err != nil || origin.Scheme != "https" || origin.Host == "" || origin.Path != "" ||
		origin.RawQuery != "" || origin.Fragment != "" || origin.User != nil {
		return errors.New("publicOrigin must be an https origin without a path")
	}
	mediaURL, err := url.Parse(c.MediaMTXURL)
	if err != nil || mediaURL.Scheme != "http" || mediaURL.Hostname() != "127.0.0.1" {
		return errors.New("mediaMTXURL must use http and 127.0.0.1")
	}
	if c.RecordingsDirectory == "" || !filepath.IsAbs(c.RecordingsDirectory) {
		return errors.New("recordingsDirectory must be an absolute path")
	}
	if !strings.HasPrefix(c.PasswordHash, "pbkdf2_sha256$") {
		return errors.New("passwordHash is required")
	}
	if c.SessionIdleMinutes < 5 || c.SessionIdleMinutes > 1440 {
		return errors.New("sessionIdleMinutes must be between 5 and 1440")
	}
	if c.SessionMaxHours < 1 || c.SessionMaxHours > 168 {
		return errors.New("sessionMaxHours must be between 1 and 168")
	}
	return nil
}

func (c Config) SessionIdleTTL() time.Duration {
	return time.Duration(c.SessionIdleMinutes) * time.Minute
}

func (c Config) SessionMaxTTL() time.Duration {
	return time.Duration(c.SessionMaxHours) * time.Hour
}

func Save(path string, cfg Config) error {
	if err := cfg.Validate(); err != nil {
		return err
	}
	if !filepath.IsAbs(path) {
		return errors.New("configuration output path must be absolute")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create config directory: %w", err)
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	return os.Chmod(path, 0o600)
}
