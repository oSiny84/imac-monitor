package server

import (
	"context"
	"net"
	"strconv"
	"strings"
	"time"
)

// The phone tells the gateway which address it opened in the Host header. For live video the
// phone must also send its WebRTC traffic to an address it can reach. MediaMTX lists only this
// Mac's own interface addresses (plus the app's optional external hosts), which a phone on
// mobile data cannot reach. So the answer from MediaMTX gets a copy of each host candidate
// with the address the phone used; the router forwards that address's port to this Mac.

type clientHostKey struct{}

// withClientHost remembers the Host the phone sent, because the proxy rewrites it.
func withClientHost(ctx context.Context, host string) context.Context {
	return context.WithValue(ctx, clientHostKey{}, host)
}

func clientHostFrom(ctx context.Context) string {
	host, _ := ctx.Value(clientHostKey{}).(string)
	return host
}

// maxCandidateAddresses bounds how many addresses a DNS name may add to one answer.
const maxCandidateAddresses = 2

// lookupIPv4 resolves a name the phone used, such as a DDNS name. Replaced in tests.
var lookupIPv4 = func(ctx context.Context, name string) []net.IP {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupIPAddr(ctx, name)
	if err != nil {
		return nil
	}
	var found []net.IP
	for _, address := range addresses {
		if ip := address.IP.To4(); ip != nil {
			found = append(found, ip)
		}
	}
	return found
}

// candidateAddressesForHost returns the IPv4 addresses behind the Host header, or none when
// the host cannot carry video from outside (loopback, unspecified, IPv6, or unresolvable).
func candidateAddressesForHost(ctx context.Context, hostHeader string) []net.IP {
	host := hostHeader
	if splitHost, _, err := net.SplitHostPort(hostHeader); err == nil {
		host = splitHost
	}
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if host == "" || strings.ContainsAny(host, "[]:/@ ") {
		return nil
	}
	var addresses []net.IP
	if ip := net.ParseIP(host); ip != nil {
		addresses = []net.IP{ip}
	} else {
		addresses = lookupIPv4(ctx, host)
	}
	var usable []net.IP
	for _, ip := range addresses {
		ip4 := ip.To4()
		if ip4 == nil || ip4.IsLoopback() || ip4.IsUnspecified() || ip4.IsMulticast() {
			continue
		}
		usable = append(usable, ip4)
		if len(usable) == maxCandidateAddresses {
			break
		}
	}
	return usable
}

// addHostCandidates copies each distinct IPv4 host candidate (by transport, port and TCP type)
// of every media section with each given address, unless the section already lists that
// address. Anything that is not a candidate line is left exactly as it was.
func addHostCandidates(sdp string, addresses []net.IP) string {
	if len(addresses) == 0 || !strings.Contains(sdp, "a=candidate:") {
		return sdp
	}
	lineEnd := "\n"
	if strings.Contains(sdp, "\r\n") {
		lineEnd = "\r\n"
	}
	lines := strings.Split(strings.TrimSuffix(sdp, lineEnd), lineEnd)
	var output []string
	added := 0
	flush := func(section []string) {
		output = append(output, withCopiedCandidates(section, addresses, &added)...)
	}
	var section []string
	for _, line := range lines {
		if strings.HasPrefix(line, "m=") {
			flush(section)
			section = nil
		}
		section = append(section, line)
	}
	flush(section)
	return strings.Join(output, lineEnd) + lineEnd
}

type candidate struct {
	foundation, component, transport string
	priority                         uint64
	address, port                    string
	rest                             []string // after "typ host"
}

func parseHostCandidate(line string) (candidate, bool) {
	fields := strings.Fields(strings.TrimPrefix(line, "a=candidate:"))
	if len(fields) < 8 || fields[6] != "typ" || fields[7] != "host" {
		return candidate{}, false
	}
	priority, err := strconv.ParseUint(fields[3], 10, 32)
	if err != nil {
		return candidate{}, false
	}
	if ip := net.ParseIP(fields[4]); ip == nil || ip.To4() == nil {
		return candidate{}, false
	}
	return candidate{foundation: fields[0], component: fields[1], transport: strings.ToLower(fields[2]),
		priority: priority, address: fields[4], port: fields[5], rest: fields[8:]}, true
}

func withCopiedCandidates(section []string, addresses []net.IP, added *int) []string {
	present := map[string]bool{}
	var templates []candidate
	seen := map[string]bool{}
	// The copies go right after the last candidate, so before any a=end-of-candidates.
	insertAt := 0
	for index, line := range section {
		if !strings.HasPrefix(line, "a=candidate:") {
			continue
		}
		if fields := strings.Fields(line); len(fields) > 4 {
			present[fields[4]] = true
		}
		insertAt = index + 1
		parsed, ok := parseHostCandidate(line)
		if !ok {
			continue
		}
		key := parsed.component + " " + parsed.transport + " " + parsed.port + " " + strings.Join(parsed.rest, " ")
		if !seen[key] {
			seen[key] = true
			templates = append(templates, parsed)
		}
	}
	if len(templates) == 0 {
		return section
	}
	var copies []string
	for _, address := range addresses {
		if present[address.String()] {
			continue
		}
		for _, template := range templates {
			*added++
			priority := template.priority
			if priority > 0 {
				priority--
			}
			fields := []string{"mmx" + strconv.Itoa(*added), template.component, template.transport,
				strconv.FormatUint(priority, 10), address.String(), template.port, "typ", "host"}
			copies = append(copies, "a=candidate:"+strings.Join(append(fields, template.rest...), " "))
		}
	}
	if len(copies) == 0 {
		return section
	}
	result := make([]string, 0, len(section)+len(copies))
	result = append(result, section[:insertAt]...)
	result = append(result, copies...)
	return append(result, section[insertAt:]...)
}
