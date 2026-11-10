package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Config struct {
	ListenAddress      string `json:"listenAddress"`
	TLSCertificateFile string `json:"tlsCertificateFile"`
	TLSPrivateKeyFile  string `json:"tlsPrivateKeyFile"`
	PublicOrigin       string `json:"publicOrigin"`
	// AdditionalOrigins are other addresses of this same gateway, for example the external
	// address when publicOrigin is the home Wi-Fi one. Requests from any of them are accepted.
	AdditionalOrigins    []string `json:"additionalOrigins,omitempty"`
	MediaMTXURL          string   `json:"mediaMTXURL"`
	RecordingsDirectory  string   `json:"recordingsDirectory"`
	MonitoringStatusFile string   `json:"monitoringStatusFile,omitempty"`
	LiveDemandFile       string   `json:"liveDemandFile,omitempty"`
	RecordingDemandFile  string   `json:"recordingDemandFile,omitempty"`
	TelegramFile         string   `json:"telegramFile,omitempty"`
	PasswordHash         string   `json:"passwordHash"`
	SessionIdleMinutes   int      `json:"sessionIdleMinutes"`
	SessionMaxHours      int      `json:"sessionMaxHours"`
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
	if cfg.MonitoringStatusFile == "" || cfg.LiveDemandFile == "" || cfg.RecordingDemandFile == "" || cfg.TelegramFile == "" {
		directory, err := filepath.Abs(filepath.Dir(path))
		if err != nil {
			return Config{}, fmt.Errorf("resolve config directory: %w", err)
		}
		if cfg.MonitoringStatusFile == "" {
			cfg.MonitoringStatusFile = filepath.Join(directory, "Runtime", "monitoring-status.json")
		}
		if cfg.LiveDemandFile == "" {
			cfg.LiveDemandFile = filepath.Join(directory, "Runtime", "live-demand.json")
		}
		if cfg.RecordingDemandFile == "" {
			cfg.RecordingDemandFile = filepath.Join(directory, "Runtime", "recording-demand.json")
		}
		if cfg.TelegramFile == "" {
			cfg.TelegramFile = filepath.Join(directory, "telegram.json")
		}
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
	if !validOrigin(c.PublicOrigin) {
		return errors.New("publicOrigin must be an https origin without a path")
	}
	if len(c.AdditionalOrigins) > MaxAdditionalOrigins {
		return fmt.Errorf("additionalOrigins may hold at most %d origins", MaxAdditionalOrigins)
	}
	seen := map[string]bool{CanonicalOrigin(c.PublicOrigin): true}
	for _, origin := range c.AdditionalOrigins {
		if !validOrigin(origin) {
			return fmt.Errorf("additionalOrigins entry %q must be an https origin without a path", origin)
		}
		canonical := CanonicalOrigin(origin)
		if seen[canonical] {
			return fmt.Errorf("additionalOrigins entry %q repeats an origin already allowed", origin)
		}
		seen[canonical] = true
	}
	mediaURL, err := url.Parse(c.MediaMTXURL)
	if err != nil || mediaURL.Scheme != "http" || mediaURL.Hostname() != "127.0.0.1" {
		return errors.New("mediaMTXURL must use http and 127.0.0.1")
	}
	if c.RecordingsDirectory == "" || !filepath.IsAbs(c.RecordingsDirectory) {
		return errors.New("recordingsDirectory must be an absolute path")
	}
	if c.MonitoringStatusFile != "" && !filepath.IsAbs(c.MonitoringStatusFile) {
		return errors.New("monitoringStatusFile must be an absolute path")
	}
	if c.LiveDemandFile != "" && !filepath.IsAbs(c.LiveDemandFile) {
		return errors.New("liveDemandFile must be an absolute path")
	}
	if c.RecordingDemandFile != "" && !filepath.IsAbs(c.RecordingDemandFile) {
		return errors.New("recordingDemandFile must be an absolute path")
	}
	if c.TelegramFile != "" && !filepath.IsAbs(c.TelegramFile) {
		return errors.New("telegramFile must be an absolute path")
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

// MaxAdditionalOrigins bounds the list so a mistaken script cannot grow it without limit.
const MaxAdditionalOrigins = 4

// AllowedOrigins lists publicOrigin first and then additionalOrigins, each in the form a
// browser sends in its Origin header.
func (c Config) AllowedOrigins() []string {
	origins := make([]string, 0, 1+len(c.AdditionalOrigins))
	origins = append(origins, CanonicalOrigin(c.PublicOrigin))
	for _, origin := range c.AdditionalOrigins {
		origins = append(origins, CanonicalOrigin(origin))
	}
	return origins
}

// CanonicalOrigin writes an origin the way browsers send it: lower-case host and no :443.
// A configuration written as https://Camera.Example:443 then still matches.
func CanonicalOrigin(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Hostname() == "" {
		return raw
	}
	host := strings.ToLower(parsed.Hostname())
	port := parsed.Port()
	if port == "" || port == "443" {
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
		return "https://" + host
	}
	return "https://" + net.JoinHostPort(host, port)
}

func validOrigin(raw string) bool {
	origin, err := url.Parse(raw)
	return err == nil && origin.Scheme == "https" && origin.Host != "" && origin.Hostname() != "" &&
		origin.Path == "" && origin.RawQuery == "" && origin.Fragment == "" && origin.User == nil &&
		!origin.ForceQuery && origin.Opaque == "" && !ambiguousIPv4Host(origin.Hostname())
}

// ambiguousIPv4Host reports a host that browsers read as an IPv4 address (its last label is a
// number or 0x hex) but that is not plain dotted decimal, such as 203.0.113.010 (octal) or
// 0xcb.0.113.10. The browser would send a different Origin than the one written here.
func ambiguousIPv4Host(host string) bool {
	if strings.Contains(host, ":") {
		return false
	}
	last := host[strings.LastIndex(host, ".")+1:]
	numeric := last != "" && strings.Trim(last, "0123456789") == ""
	hex := strings.HasPrefix(last, "0x") || strings.HasPrefix(last, "0X")
	if !numeric && !hex {
		return false
	}
	ip := net.ParseIP(host)
	return ip == nil || ip.To4() == nil
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
