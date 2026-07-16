package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
)

// parserMaxTokenSize matches the fetcher's maximum accepted body. A valid
// subscription may legitimately contain a generated line larger than
// bufio.Scanner's 64 KiB default; anything larger than the already-enforced
// body cap is rejected instead of being silently parsed as a prefix.
const parserMaxTokenSize = maxSubscriptionBodySize

func newRuleScanner(raw []byte) *bufio.Scanner {
	s := bufio.NewScanner(bytes.NewReader(raw))
	s.Buffer(make([]byte, 64*1024), parserMaxTokenSize)
	return s
}

// ErrUnknownFormat is returned by ParseDomains when the requested format is
// not one of the supported rule-list formats.
var ErrUnknownFormat = errors.New("unknown format")

// ParseDomains parses raw rule-list bytes in the given format into a
// normalized, deduplicated, sorted slice of domains. Supported formats:
// plain, gfwlist, dnsmasq, hosts.
func ParseDomains(format string, raw []byte) ([]string, error) {
	var lines []string
	var err error
	switch format {
	case "plain":
		lines, err = parsePlainDomains(raw)
	case "gfwlist":
		lines, err = parseGFWList(raw)
	case "dnsmasq":
		lines, err = parseDnsmasq(raw)
	case "hosts":
		lines, err = parseHosts(raw)
	default:
		return nil, ErrUnknownFormat
	}
	if err != nil {
		return nil, err
	}
	return normalizeDomainList(lines), nil
}

// normalizeDomainList lowercases, trims trailing dots, dedups, and sorts.
func normalizeDomainList(lines []string) []string {
	set := make(map[string]struct{}, len(lines))
	for _, l := range lines {
		d := normalizeDomain(l)
		if d == "" {
			continue
		}
		set[d] = struct{}{}
	}
	out := make([]string, 0, len(set))
	for d := range set {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}

// normalizeDomain lowercases a domain and trims a trailing dot.
func normalizeDomain(d string) string {
	d = strings.ToLower(strings.TrimSpace(d))
	d = strings.TrimRight(d, ".")
	return d
}

// parsePlainDomains parses one domain per line; '#' full-line comments and
// blank lines are skipped.
func parsePlainDomains(raw []byte) ([]string, error) {
	var out []string
	scanner := newRuleScanner(raw)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	return out, scanner.Err()
}

// parseGFWList decodes the whole body as base64, then per line:
//   - drops blank lines
//   - drops '@@'-prefixed whitelist lines
//   - drops '!'-prefixed comment lines
//   - strips leading '||', leading '|http://' / '|https://'
//   - strips a trailing '^'
//   - extracts the host part (drops any '/path')
func parseGFWList(raw []byte) ([]string, error) {
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil {
		return nil, fmt.Errorf("decode gfwlist base64: %w", err)
	}
	var out []string
	scanner := newRuleScanner(decoded)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "@@") {
			continue // whitelist
		}
		if strings.HasPrefix(line, "!") {
			continue // comment
		}
		switch {
		case strings.HasPrefix(line, "||"):
			line = line[2:]
		case strings.HasPrefix(line, "|https://"):
			line = line[len("|https://"):]
		case strings.HasPrefix(line, "|http://"):
			line = line[len("|http://"):]
		case strings.HasPrefix(line, "|"):
			line = line[1:]
		}
		line = strings.TrimSuffix(line, "^")
		// Take only the host part: strip any path/query.
		if idx := strings.IndexAny(line, "/^*"); idx >= 0 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		out = append(out, line)
	}
	return out, scanner.Err()
}

// parseDnsmasq parses "server=/DOMAIN/IP" and "address=/DOMAIN/IP" lines,
// extracting DOMAIN. Other lines are ignored.
func parseDnsmasq(raw []byte) ([]string, error) {
	var out []string
	scanner := newRuleScanner(raw)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var rest string
		switch {
		case strings.HasPrefix(line, "server=/"):
			rest = line[len("server=/"):]
		case strings.HasPrefix(line, "address=/"):
			rest = line[len("address=/"):]
		default:
			continue
		}
		// rest is "DOMAIN/IP..." — take up to the next '/'.
		idx := strings.IndexByte(rest, '/')
		if idx < 0 {
			continue
		}
		domain := rest[:idx]
		if domain == "" {
			continue
		}
		out = append(out, domain)
	}
	return out, scanner.Err()
}

// parseHosts parses "IP DOMAIN [DOMAIN2 ...]" lines, taking the first
// hostname after the IP address. '#' starts a comment.
func parseHosts(raw []byte) ([]string, error) {
	var out []string
	scanner := newRuleScanner(raw)
	for scanner.Scan() {
		line := scanner.Text()
		if idx := strings.IndexByte(line, '#'); idx >= 0 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		// fields[0] is the IP; fields[1] is the first hostname.
		host := fields[1]
		if host == "localhost" {
			continue
		}
		out = append(out, host)
	}
	return out, scanner.Err()
}

// ParseCIDRs parses one CIDR per line, skipping '#' comments and invalid
// entries, and returns a normalized, deduplicated, sorted slice.
func ParseCIDRs(raw []byte) ([]string, error) {
	set := make(map[string]struct{})
	scanner := newRuleScanner(raw)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if _, _, err := net.ParseCIDR(line); err != nil {
			continue // skip invalid
		}
		set[strings.ToLower(line)] = struct{}{}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	out := make([]string, 0, len(set))
	for c := range set {
		out = append(out, c)
	}
	sort.Strings(out)
	return out, nil
}
