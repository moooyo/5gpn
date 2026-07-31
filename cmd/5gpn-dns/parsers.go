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

	"github.com/miekg/dns"
	"gopkg.in/yaml.v3"
)

const (
	maxSubscriptionEntries   = 500_000
	maxInvalidEntryPercent   = 40
	minDomainLabelsForPolicy = 2
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
// plain, gfwlist, dnsmasq, hosts, clash.
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
	case "clash":
		lines, err = parseClashProvider(raw)
	default:
		return nil, ErrUnknownFormat
	}
	if err != nil {
		return nil, err
	}
	return normalizeDomainList(lines)
}

// normalizeDomainList lowercases, validates, deduplicates, and sorts domain
// candidates. A response with too many malformed candidates is rejected as a
// partial/wrong-format parse instead of publishing the valid-looking residue.
func normalizeDomainList(lines []string) ([]string, error) {
	if len(lines) > maxSubscriptionEntries {
		return nil, fmt.Errorf("domain list has %d candidates, exceeds limit %d", len(lines), maxSubscriptionEntries)
	}
	set := make(map[string]struct{}, len(lines))
	invalid, valid := 0, 0
	for _, l := range lines {
		d := normalizeDomain(l)
		if d == "" {
			continue
		}
		if !validPolicyDomain(d) {
			invalid++
			continue
		}
		valid++
		set[d] = struct{}{}
	}
	considered := invalid + valid
	if considered > 0 && invalid*100 > considered*maxInvalidEntryPercent {
		return nil, fmt.Errorf("domain list rejected: %d of %d normalized entries are invalid", invalid, considered)
	}
	out := make([]string, 0, len(set))
	for d := range set {
		out = append(out, d)
	}
	sort.Strings(out)
	return out, nil
}

func validPolicyDomain(domain string) bool {
	if len(domain) > 253 || net.ParseIP(domain) != nil {
		return false
	}
	labels, ok := dns.IsDomainName(dns.Fqdn(domain))
	return ok && labels >= minDomainLabelsForPolicy
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

// parseClashProvider parses a Clash rule-provider document: a YAML mapping
// carrying a `payload` sequence of that provider's own rule grammar.
//
//	+.example.com              suffix marker (Clash)
//	.example.com               suffix marker (Surge-style)
//	example.com                bare name
//	DOMAIN-SUFFIX,example.com  tokenized suffix
//	DOMAIN,example.com         tokenized exact name
//
// Every cached subscription entry is loaded as a domain suffix (LoadDomainSet),
// so DOMAIN and DOMAIN-SUFFIX collapse to the same match here; an exact-only
// rule cannot be represented and is deliberately widened rather than dropped.
// Rule kinds that carry no domain at all — DOMAIN-KEYWORD, every IP-CIDR/GEOIP/
// IP-ASN form, process and port matchers — are dropped before normalization,
// the way parseDnsmasq and parseHosts drop their non-matching lines, so they
// never count toward the invalid-entry threshold.
func parseClashProvider(raw []byte) ([]string, error) {
	var doc struct {
		Payload []string `yaml:"payload"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("clash provider: %w", err)
	}
	out := make([]string, 0, len(doc.Payload))
	for _, entry := range doc.Payload {
		if d, ok := clashPayloadDomain(entry); ok {
			out = append(out, d)
		}
	}
	return out, nil
}

// clashPayloadDomain reduces one payload entry to a domain, reporting false
// when the entry names a rule kind this parser cannot represent as a name.
func clashPayloadDomain(entry string) (string, bool) {
	e := strings.TrimSpace(entry)
	if e == "" || strings.HasPrefix(e, "#") {
		return "", false
	}
	if kind, value, tokenized := strings.Cut(e, ","); tokenized {
		switch strings.ToUpper(strings.TrimSpace(kind)) {
		case "DOMAIN", "DOMAIN-SUFFIX":
			e = strings.TrimSpace(value)
		default:
			return "", false
		}
	}
	// Both suffix markers mean "this name and every subdomain", which is what
	// the cache already stores, so they are stripped rather than translated.
	e = strings.TrimPrefix(e, "+")
	e = strings.TrimPrefix(e, ".")
	if e == "" {
		return "", false
	}
	// A residual marker is a shape this parser does not model — a `*.` wildcard
	// matches exactly one label, which a suffix cache would over-match. Dropping
	// it here matters more than it looks: validPolicyDomain accepts '+' and ','
	// as legal hostname bytes, so an unstripped marker would pass validation and
	// be cached as a literal entry that silently never matches anything.
	if strings.ContainsAny(e, "+*,/ \t") {
		return "", false
	}
	return e, true
}

// ParseCIDRs parses one CIDR per line, skipping '#' comments and invalid
// entries, and returns a normalized, deduplicated, sorted slice.
func ParseCIDRs(raw []byte) ([]string, error) {
	set := make(map[string]struct{})
	total, invalid := 0, 0
	scanner := newRuleScanner(raw)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		total++
		if total > maxSubscriptionEntries {
			return nil, fmt.Errorf("CIDR list exceeds entry limit %d", maxSubscriptionEntries)
		}
		if _, _, err := net.ParseCIDR(line); err != nil {
			invalid++
			continue
		}
		set[strings.ToLower(line)] = struct{}{}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if total > 0 && invalid*100 > total*maxInvalidEntryPercent {
		return nil, fmt.Errorf("CIDR list rejected: %d of %d entries are invalid", invalid, total)
	}
	out := make([]string, 0, len(set))
	for c := range set {
		out = append(out, c)
	}
	sort.Strings(out)
	return out, nil
}
