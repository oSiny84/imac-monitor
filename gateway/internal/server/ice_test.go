package server

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"macmonitor.local/gateway/internal/config"
)

// Shaped like a MediaMTX (pion) WHEP answer: CRLF lines, bundled video and audio, component 1
// UDP and passive TCP host candidates on the shared port, an IPv6 candidate and
// end-of-candidates.
var mediaAnswer = strings.Join([]string{
	"v=0",
	"o=- 4215775240449105457 1731200000 IN IP4 0.0.0.0",
	"s=-",
	"t=0 0",
	"a=group:BUNDLE 0 1",
	"m=video 9 UDP/TLS/RTP/SAVPF 96",
	"c=IN IP4 0.0.0.0",
	"a=mid:0",
	"a=ice-ufrag:abcdEFGH",
	"a=ice-pwd:0123456789abcdef0123456789abcdef",
	"a=rtpmap:96 H264/90000",
	"a=sendonly",
	"a=candidate:1390596646 1 udp 2130706431 192.168.0.7 8189 typ host",
	"a=candidate:2471251001 1 tcp 1671430143 192.168.0.7 8189 typ host tcptype passive",
	"a=candidate:1390596647 1 udp 2130706431 10.211.55.2 8189 typ host",
	"a=candidate:3528925834 1 udp 2130706431 fe80::1 8189 typ host",
	"a=end-of-candidates",
	"m=audio 9 UDP/TLS/RTP/SAVPF 111",
	"c=IN IP4 0.0.0.0",
	"a=mid:1",
	"a=rtpmap:111 opus/48000/2",
	"a=sendonly",
	"a=candidate:1390596646 1 udp 2130706431 192.168.0.7 8189 typ host",
	"a=candidate:2471251001 1 tcp 1671430143 192.168.0.7 8189 typ host tcptype passive",
	"a=end-of-candidates",
}, "\r\n") + "\r\n"

func TestAddHostCandidatesCopiesEachTransportWithThePhonesAddress(t *testing.T) {
	got := addHostCandidates(mediaAnswer, []net.IP{net.ParseIP("203.0.113.5")})
	videoOld := "a=candidate:3528925834 1 udp 2130706431 fe80::1 8189 typ host\r\na=end-of-candidates\r\n"
	videoNew := "a=candidate:3528925834 1 udp 2130706431 fe80::1 8189 typ host\r\n" +
		"a=candidate:mmx1 1 udp 2130706430 203.0.113.5 8189 typ host\r\n" +
		"a=candidate:mmx2 1 tcp 1671430142 203.0.113.5 8189 typ host tcptype passive\r\n" +
		"a=end-of-candidates\r\n"
	audioOld := "a=candidate:2471251001 1 tcp 1671430143 192.168.0.7 8189 typ host tcptype passive\r\na=end-of-candidates\r\n"
	audioNew := "a=candidate:2471251001 1 tcp 1671430143 192.168.0.7 8189 typ host tcptype passive\r\n" +
		"a=candidate:mmx3 1 udp 2130706430 203.0.113.5 8189 typ host\r\n" +
		"a=candidate:mmx4 1 tcp 1671430142 203.0.113.5 8189 typ host tcptype passive\r\n" +
		"a=end-of-candidates\r\n"
	want := strings.Replace(mediaAnswer, videoOld, videoNew, 1)
	index := strings.LastIndex(want, audioOld)
	want = want[:index] + audioNew + want[index+len(audioOld):]
	if got != want {
		t.Fatalf("rewritten answer:\n%s\nwant:\n%s", got, want)
	}
}

func TestAddHostCandidatesLeavesAnswersAlone(t *testing.T) {
	// The home Wi-Fi address is already a candidate: nothing to add.
	if got := addHostCandidates(mediaAnswer, []net.IP{net.ParseIP("192.168.0.7")}); got != mediaAnswer {
		t.Fatalf("answer changed for an address it already lists:\n%s", got)
	}
	for _, body := range []string{
		"SDP answer",
		"v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:0\r\n",
		"v=0\na=candidate:1 1 udp 1 fe80::1 8189 typ host\n",
		"v=0\na=candidate:1 1 udp 1 192.168.0.7 8189 typ srflx raddr 0.0.0.0 rport 0\n",
		"v=0\na=candidate:1 1 udp notanumber 192.168.0.7 8189 typ host\n",
	} {
		if got := addHostCandidates(body, []net.IP{net.ParseIP("203.0.113.5")}); got != body {
			t.Fatalf("answer without usable IPv4 host candidates changed: %q -> %q", body, got)
		}
	}
	if got := addHostCandidates(mediaAnswer, nil); got != mediaAnswer {
		t.Fatal("answer changed without addresses")
	}
}

func TestCandidateAddressesForHostUsesOnlyAddressesAPhoneCanReach(t *testing.T) {
	original := lookupIPv4
	defer func() { lookupIPv4 = original }()
	lookups := 0
	lookupIPv4 = func(_ context.Context, name string) []net.IP {
		lookups++
		if name != "cam.example.net" {
			return nil
		}
		return []net.IP{net.ParseIP("198.51.100.7"), net.ParseIP("127.0.0.1"), net.ParseIP("198.51.100.8"), net.ParseIP("198.51.100.9")}
	}
	for host, want := range map[string]string{
		"203.0.113.5:8443":      "203.0.113.5",
		"203.0.113.5":           "203.0.113.5",
		"192.168.0.7:8443":      "192.168.0.7",
		"CAM.example.net.:8443": "198.51.100.7 198.51.100.8",
		"cam.example.net":       "198.51.100.7 198.51.100.8",
		"127.0.0.1:8443":        "",
		"0.0.0.0:8443":          "",
		"[2001:db8::1]:8443":    "",
		"unknown.example":       "",
		"":                      "",
		"a@b:8443":              "",
	} {
		var got []string
		for _, ip := range candidateAddressesForHost(context.Background(), host) {
			got = append(got, ip.String())
		}
		if strings.Join(got, " ") != want {
			t.Fatalf("host %q: got %v, want %q", host, got, want)
		}
	}
	if lookups != 3 {
		t.Fatalf("expected 3 DNS lookups (two DDNS forms and the unknown name), got %d", lookups)
	}
}

func TestWHEPAnswerThroughTheProxyGetsTheAddressThePhoneOpened(t *testing.T) {
	original := lookupIPv4
	defer func() { lookupIPv4 = original }()
	lookupIPv4 = func(context.Context, string) []net.IP { t.Error("unexpected DNS lookup"); return nil }
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", r.URL.Path+"/session-1")
		w.Header().Set("Content-Type", "application/sdp")
		w.Header().Set("Content-Length", strconv.Itoa(len(mediaAnswer)))
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, mediaAnswer)
	}))
	defer media.Close()
	server, err := New(config.Config{MediaMTXURL: media.URL, RecordingsDirectory: t.TempDir(),
		PublicOrigin: "https://192.168.0.7:8443", SessionIdleMinutes: 30, SessionMaxHours: 24})
	if err != nil {
		t.Fatal(err)
	}
	token, _, err := server.sessions.Create()
	if err != nil {
		t.Fatal(err)
	}
	post := func(host string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, "https://"+host+"/live/live/whep", strings.NewReader("offer"))
		request.Host = host
		request.Header.Set("Origin", "https://"+host)
		request.Header.Set("Content-Type", "application/sdp")
		request.AddCookie(&http.Cookie{Name: sessionCookieName, Value: token})
		response := httptest.NewRecorder()
		server.Handler().ServeHTTP(response, request)
		return response
	}
	outside := post("203.0.113.5:8443")
	if outside.Code != http.StatusCreated || !strings.Contains(outside.Body.String(), " 203.0.113.5 8189 typ host") ||
		outside.Header().Get("Content-Length") != strconv.Itoa(outside.Body.Len()) ||
		outside.Header().Get("Location") != "/live/live/whep/session-1" {
		t.Fatalf("outside answer: %d %v\n%s", outside.Code, outside.Header(), outside.Body.String())
	}
	home := post("192.168.0.7:8443")
	if home.Code != http.StatusCreated || home.Body.String() != mediaAnswer {
		t.Fatalf("home answer changed: %d\n%s", home.Code, home.Body.String())
	}
}
