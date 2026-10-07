package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"sync"
	"time"
)

type Session struct {
	CSRF      string
	CreatedAt time.Time
	LastSeen  time.Time
}

type SessionStore struct {
	mu       sync.Mutex
	sessions map[[sha256.Size]byte]Session
	idleTTL  time.Duration
	maxTTL   time.Duration
	now      func() time.Time
}

func NewSessionStore(idleTTL, maxTTL time.Duration) *SessionStore {
	return &SessionStore{
		sessions: make(map[[sha256.Size]byte]Session),
		idleTTL:  idleTTL,
		maxTTL:   maxTTL,
		now:      time.Now,
	}
}

func (s *SessionStore) Create() (token string, session Session, err error) {
	token, err = randomToken(32)
	if err != nil {
		return "", Session{}, err
	}
	csrf, err := randomToken(24)
	if err != nil {
		return "", Session{}, err
	}

	now := s.now()
	session = Session{CSRF: csrf, CreatedAt: now, LastSeen: now}
	hash := sha256.Sum256([]byte(token))
	s.mu.Lock()
	s.sessions[hash] = session
	s.pruneLocked(now)
	s.mu.Unlock()
	return token, session, nil
}

func (s *SessionStore) Validate(token string) (Session, bool) {
	if token == "" {
		return Session{}, false
	}
	now := s.now()
	hash := sha256.Sum256([]byte(token))

	s.mu.Lock()
	defer s.mu.Unlock()
	session, ok := s.sessions[hash]
	if !ok || s.expired(session, now) {
		delete(s.sessions, hash)
		return Session{}, false
	}
	session.LastSeen = now
	s.sessions[hash] = session
	return session, true
}

func (s *SessionStore) Delete(token string) {
	hash := sha256.Sum256([]byte(token))
	s.mu.Lock()
	delete(s.sessions, hash)
	s.mu.Unlock()
}

func (s *SessionStore) expired(session Session, now time.Time) bool {
	return now.Sub(session.LastSeen) > s.idleTTL || now.Sub(session.CreatedAt) > s.maxTTL
}

func (s *SessionStore) pruneLocked(now time.Time) {
	for hash, session := range s.sessions {
		if s.expired(session, now) {
			delete(s.sessions, hash)
		}
	}
}

func randomToken(size int) (string, error) {
	buffer := make([]byte, size)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}
