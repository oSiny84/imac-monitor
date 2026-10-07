package auth

import (
	"testing"
	"time"
)

func TestSessionIdleAndAbsoluteExpiry(t *testing.T) {
	base := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	store := NewSessionStore(30*time.Minute, 2*time.Hour)
	store.now = func() time.Time { return base }
	token, original, err := store.Create()
	if err != nil {
		t.Fatal(err)
	}
	if token == "" || original.CSRF == "" {
		t.Fatal("session secrets must not be empty")
	}

	store.now = func() time.Time { return base.Add(20 * time.Minute) }
	if _, ok := store.Validate(token); !ok {
		t.Fatal("session expired before idle timeout")
	}
	store.now = func() time.Time { return base.Add(49 * time.Minute) }
	if _, ok := store.Validate(token); !ok {
		t.Fatal("validation should have refreshed the idle timeout")
	}
	store.now = func() time.Time { return base.Add(2*time.Hour + time.Second) }
	if _, ok := store.Validate(token); ok {
		t.Fatal("session survived absolute timeout")
	}
}

func TestDeleteSession(t *testing.T) {
	store := NewSessionStore(time.Hour, time.Hour)
	token, _, err := store.Create()
	if err != nil {
		t.Fatal(err)
	}
	store.Delete(token)
	if _, ok := store.Validate(token); ok {
		t.Fatal("deleted session validated")
	}
}
