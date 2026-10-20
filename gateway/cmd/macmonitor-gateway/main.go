package main

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"

	"macmonitor.local/gateway/internal/auth"
	"macmonitor.local/gateway/internal/config"
	webserver "macmonitor.local/gateway/internal/server"
)

var passwordInput = bufio.NewReader(io.LimitReader(os.Stdin, 4098))

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "serve":
		serve(os.Args[2:])
	case "hash-password":
		hashPassword(os.Args[2:])
	case "init":
		initialize(os.Args[2:])
	case "check-config":
		checkConfig(os.Args[2:])
	default:
		usage()
	}
}

func serve(arguments []string) {
	flags := flag.NewFlagSet("serve", flag.ExitOnError)
	configPath := flags.String("config", "", "path to gateway JSON configuration")
	_ = flags.Parse(arguments)
	if *configPath == "" {
		log.Fatal("-config is required")
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}
	server, err := webserver.New(cfg)
	if err != nil {
		log.Fatalf("server initialization error: %v", err)
	}

	httpServer := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      0,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			NextProtos: []string{"h2", "http/1.1"},
		},
	}

	log.Printf("MacMonitor gateway listening on %s", cfg.ListenAddress)
	if err := httpServer.ListenAndServeTLS(cfg.TLSCertificateFile, cfg.TLSPrivateKeyFile); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func hashPassword(arguments []string) {
	flags := flag.NewFlagSet("hash-password", flag.ExitOnError)
	_ = flags.Parse(arguments)
	password := readPassword("Password")
	hash, err := auth.HashPassword(password)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(hash)
}

func initialize(arguments []string) {
	flags := flag.NewFlagSet("init", flag.ExitOnError)
	output := flags.String("output", "", "absolute output path")
	origin := flags.String("origin", "", "public HTTPS origin, for example https://camera.example:8443")
	listen := flags.String("listen", ":8443", "HTTPS listen address")
	certificate := flags.String("cert", "", "absolute TLS certificate path")
	privateKey := flags.String("key", "", "absolute TLS private key path")
	recordings := flags.String("recordings", "", "absolute recordings directory")
	_ = flags.Parse(arguments)
	if *output == "" || *origin == "" || *certificate == "" || *privateKey == "" || *recordings == "" {
		flags.Usage()
		os.Exit(2)
	}

	password := readPassword("New password")
	confirmation := readPassword("Confirm password")
	if password != confirmation {
		log.Fatal("passwords do not match")
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		log.Fatal(err)
	}
	cfg := config.Config{
		ListenAddress:       *listen,
		TLSCertificateFile:  *certificate,
		TLSPrivateKeyFile:   *privateKey,
		PublicOrigin:        *origin,
		MediaMTXURL:         "http://127.0.0.1:8889",
		RecordingsDirectory: *recordings,
		PasswordHash:        hash,
		SessionIdleMinutes:  30,
		SessionMaxHours:     24,
	}
	if err := config.Save(*output, cfg); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Wrote %s\n", *output)
}

func checkConfig(arguments []string) {
	flags := flag.NewFlagSet("check-config", flag.ExitOnError)
	configPath := flags.String("config", "", "path to gateway JSON configuration")
	_ = flags.Parse(arguments)
	if *configPath == "" {
		flags.Usage()
		os.Exit(2)
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}
	pair, err := tls.LoadX509KeyPair(cfg.TLSCertificateFile, cfg.TLSPrivateKeyFile)
	if err != nil {
		log.Fatalf("TLS certificate/key error: %v", err)
	}
	if len(pair.Certificate) == 0 {
		log.Fatal("TLS certificate/key error: certificate chain is empty")
	}
	certificate, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		log.Fatalf("TLS certificate error: %v", err)
	}
	now := time.Now()
	if now.Before(certificate.NotBefore) {
		log.Fatalf("TLS certificate is not valid before %s", certificate.NotBefore.Format(time.RFC3339))
	}
	if !now.Before(certificate.NotAfter) {
		log.Fatalf("TLS certificate expired at %s", certificate.NotAfter.Format(time.RFC3339))
	}
	origin, err := url.Parse(cfg.PublicOrigin)
	if err != nil {
		log.Fatalf("public origin error: %v", err)
	}
	if err := certificate.VerifyHostname(origin.Hostname()); err != nil {
		log.Fatalf("TLS certificate does not match %s: %v", origin.Hostname(), err)
	}
	privateKeyInfo, err := os.Stat(cfg.TLSPrivateKeyFile)
	if err != nil {
		log.Fatalf("private key error: %v", err)
	}
	if privateKeyInfo.Mode().Perm()&0o077 != 0 {
		log.Fatalf("private key permissions must deny group/other access; found %04o", privateKeyInfo.Mode().Perm())
	}
	recordingsInfo, err := os.Stat(cfg.RecordingsDirectory)
	if err != nil {
		log.Fatalf("recordings directory error: %v", err)
	}
	if !recordingsInfo.IsDir() {
		log.Fatal("recordingsDirectory is not a directory")
	}

	fmt.Printf("gateway configuration: OK\n")
	fmt.Printf("public origin: %s\n", cfg.PublicOrigin)
	fmt.Printf("listen address: %s\n", cfg.ListenAddress)
	fmt.Printf("certificate expires: %s\n", certificate.NotAfter.Format(time.RFC3339))
	fmt.Printf("recordings directory: %s\n", cfg.RecordingsDirectory)
}

func readPassword(prompt string) string {
	hidden := setTerminalEcho(false) == nil
	if hidden {
		defer func() {
			_ = setTerminalEcho(true)
			fmt.Fprintln(os.Stderr)
		}()
		fmt.Fprintf(os.Stderr, "%s: ", prompt)
	} else {
		fmt.Fprintf(os.Stderr, "%s (input is visible): ", prompt)
	}
	password, err := passwordInput.ReadString('\n')
	if err != nil && len(password) == 0 {
		log.Fatal(err)
	}
	return strings.TrimRight(password, "\r\n")
}

func setTerminalEcho(enabled bool) error {
	argument := "-echo"
	if enabled {
		argument = "echo"
	}
	command := exec.Command("stty", argument)
	command.Stdin = os.Stdin
	command.Stdout = os.Stderr
	command.Stderr = os.Stderr
	return command.Run()
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: macmonitor-gateway <serve|hash-password|init|check-config> [options]")
	os.Exit(2)
}
