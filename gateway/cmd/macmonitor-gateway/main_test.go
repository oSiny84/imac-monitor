package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"
)

func TestUncoveredOriginsNamesOnlyAddressesTheCertificateLacks(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "MacMonitor"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IPAddresses:  []net.IP{net.ParseIP("192.168.0.7"), net.ParseIP("203.0.113.5")},
		DNSNames:     []string{"cam.example.net"},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	got := uncoveredOrigins(certificate, []string{
		"https://203.0.113.5:8443", "https://cam.example.net", "https://198.51.100.9:8443", "https://other.example",
	})
	if strings.Join(got, " ") != "https://198.51.100.9:8443 https://other.example" {
		t.Fatalf("uncovered: %v", got)
	}
}
