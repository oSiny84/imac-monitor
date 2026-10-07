package auth

import (
	"testing"
	"time"
)

func TestLoginLimiterBlocksAfterFiveFailures(t *testing.T) {
	base := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	limiter := NewLoginLimiter()
	limiter.now = func() time.Time { return base }
	for i := 0; i < 5; i++ {
		allowed, _ := limiter.Allow("client")
		if !allowed {
			t.Fatalf("blocked before failure %d", i+1)
		}
		limiter.Failure("client")
	}
	if allowed, retry := limiter.Allow("client"); allowed || retry < time.Minute-time.Second {
		t.Fatalf("expected one minute block, got allowed=%v retry=%v", allowed, retry)
	}
	limiter.now = func() time.Time { return base.Add(2 * time.Minute) }
	if allowed, _ := limiter.Allow("client"); !allowed {
		t.Fatal("client remained blocked after the window")
	}
}
