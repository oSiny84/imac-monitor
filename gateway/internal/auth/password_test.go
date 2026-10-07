package auth

import (
	"strings"
	"testing"
)

func TestHashAndVerifyPassword(t *testing.T) {
	hash, err := HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyPassword(hash, "correct horse battery staple") {
		t.Fatal("expected password to verify")
	}
	if VerifyPassword(hash, "incorrect password") {
		t.Fatal("incorrect password verified")
	}
}

func TestRejectsShortPasswordAndMalformedHashes(t *testing.T) {
	if _, err := HashPassword("too-short"); err == nil {
		t.Fatal("expected short password to fail")
	}
	for _, value := range []string{"", "pbkdf2_sha256$1$x$y", strings.Repeat("x", 200)} {
		if VerifyPassword(value, "anything") {
			t.Fatalf("malformed hash verified: %q", value)
		}
	}
}
