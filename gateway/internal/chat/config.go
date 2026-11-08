package chat

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"time"
)

// Config is the owner's Telegram bot. The file lives beside gateway.json with mode 0600 and is
// written by scripts/configure-telegram.sh. It is a separate file so that re-running
// configure-gateway.sh, which regenerates gateway.json, leaves the bot alone.
type Config struct {
	BotToken    string `json:"botToken"`
	ChatID      int64  `json:"chatID"`
	ViewMinutes int    `json:"viewMinutes,omitempty"`
}

// Tokens from @BotFather look like "123456789:AAH...". The shape check keeps a pasted chat
// id or an empty string from being sent to the API as a token.
var tokenPattern = regexp.MustCompile(`^[0-9]{5,}:[A-Za-z0-9_-]{30,}$`)

// LoadConfig reads and validates the file. A missing file is reported with fs.ErrNotExist so
// callers can treat "no bot" as a normal state.
func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read telegram config: %w", err)
	}
	var cfg Config
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("decode telegram config: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return Config{}, errors.New("decode telegram config: exactly one JSON value is required")
	}
	if cfg.ViewMinutes == 0 {
		cfg.ViewMinutes = 10
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if !tokenPattern.MatchString(c.BotToken) {
		return errors.New("botToken must be the <bot id>:<secret> value from @BotFather")
	}
	if c.ChatID == 0 {
		return errors.New("chatID is required; scripts/configure-telegram.sh finds it")
	}
	if c.ViewMinutes < 1 || c.ViewMinutes > 120 {
		return errors.New("viewMinutes must be between 1 and 120")
	}
	return nil
}

// ViewWindow is how long one chat request keeps the camera on when nobody opens the page.
func (c Config) ViewWindow() time.Duration {
	return time.Duration(c.ViewMinutes) * time.Minute
}
