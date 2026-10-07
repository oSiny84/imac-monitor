package auth

import (
	"sync"
	"time"
)

type loginAttempt struct {
	windowStart time.Time
	failures    int
	blockedTill time.Time
}

type LoginLimiter struct {
	mu       sync.Mutex
	attempts map[string]loginAttempt
	now      func() time.Time
}

func NewLoginLimiter() *LoginLimiter {
	return &LoginLimiter{attempts: make(map[string]loginAttempt), now: time.Now}
}

func (l *LoginLimiter) Allow(key string) (bool, time.Duration) {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	attempt := l.attempts[key]
	if now.Before(attempt.blockedTill) {
		return false, attempt.blockedTill.Sub(now)
	}
	if now.Sub(attempt.windowStart) > time.Minute {
		attempt = loginAttempt{windowStart: now}
		l.attempts[key] = attempt
	}
	return true, 0
}

func (l *LoginLimiter) Failure(key string) {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	attempt := l.attempts[key]
	if attempt.windowStart.IsZero() || now.Sub(attempt.windowStart) > time.Minute {
		attempt = loginAttempt{windowStart: now}
	}
	attempt.failures++
	if attempt.failures >= 5 {
		exponent := attempt.failures - 5
		if exponent > 6 {
			exponent = 6
		}
		attempt.blockedTill = now.Add(time.Duration(1<<exponent) * time.Minute)
	}
	l.attempts[key] = attempt
}

func (l *LoginLimiter) Success(key string) {
	l.mu.Lock()
	delete(l.attempts, key)
	l.mu.Unlock()
}
