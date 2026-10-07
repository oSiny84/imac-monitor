package main

import (
	"bufio"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
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
	fmt.Fprintln(os.Stderr, "usage: macmonitor-gateway <serve|hash-password|init> [options]")
	os.Exit(2)
}
