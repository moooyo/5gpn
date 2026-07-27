package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/miekg/dns"
)

// upstreamsSchemaVersion is the exact upstreams.json schema version accepted.
const upstreamsSchemaVersion = 1

// UpstreamsConfig is the on-disk shape of /etc/5gpn/upstreams.json — the
// web-console-managed runtime override for the china/trust upstream groups.
// dns.env's DNS_CHINA/DNS_TRUST stay the install-time defaults; this file,
// when present, wins at startup and is rewritten by PUT /api/upstreams. It
// lives in the daemon-writable part of /etc/5gpn (the systemd sandbox keeps
// dns.env itself read-only).
type UpstreamsConfig struct {
	Version int      `json:"version"`
	China   []string `json:"china"`
	Trust   []string `json:"trust"`
}

// LoadUpstreams reads the runtime upstream-override file. A missing file (or
// an empty path — the override disabled) returns (nil, nil): dns.env values
// apply. A malformed file is an error the caller should log and ignore, never
// a reason to crash the sole resolver.
func LoadUpstreams(path string) (*UpstreamsConfig, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("upstreams: read %s: %w", path, err)
	}
	var uc UpstreamsConfig
	if err := unmarshalStrictJSON(data, &uc); err != nil {
		return nil, fmt.Errorf("upstreams: parse %s: %w", path, err)
	}
	if uc.Version != upstreamsSchemaVersion {
		return nil, fmt.Errorf("upstreams: %s: unsupported schema version %d (want %d)", path, uc.Version, upstreamsSchemaVersion)
	}
	if err := ValidateUpstreams(uc.China, uc.Trust); err != nil {
		return nil, fmt.Errorf("upstreams: %s: %w", path, err)
	}
	return &uc, nil
}

// SaveUpstreams atomically writes the runtime upstream-override file
// (create-temp + rename, like subscriptions.json / stats.json). An empty path
// means persistence is disabled and the save is a silent no-op.
func SaveUpstreams(path string, uc UpstreamsConfig) error {
	if path == "" {
		return nil
	}
	uc.Version = upstreamsSchemaVersion
	data, err := json.MarshalIndent(uc, "", "  ")
	if err != nil {
		return fmt.Errorf("upstreams: marshal: %w", err)
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".upstreams-*.tmp")
	if err != nil {
		return fmt.Errorf("upstreams: create temp in %s: %w", dir, err)
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("upstreams: write %s: %w", tmpPath, err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("upstreams: close %s: %w", tmpPath, err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("upstreams: rename to %s: %w", path, err)
	}
	return nil
}

// ErrInvalidUpstream wraps every caller-caused upstream-spec validation
// failure so the HTTP layer can map it to a 400 (vs a 500 for a disk failure
// while persisting an otherwise-valid config).
var ErrInvalidUpstream = errors.New("invalid upstream")

// hostnameRE matches a plausible DNS hostname (for the DoT ServerName part):
// dot-separated LDH labels. Deliberately simple — it only has to reject
// obvious garbage before it becomes a TLS SNI, not fully validate RFC 1035.
var hostnameRE = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$`)

// validIPPort reports whether s is an IPv4 address with an optional port.
// The DNS daemon's systemd sandbox intentionally excludes AF_INET6.
func validIPPort(s string) bool {
	if ip := net.ParseIP(s); ip != nil && ip.To4() != nil {
		return true
	}
	host, port, err := net.SplitHostPort(s)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil {
		return false
	}
	// SplitHostPort validates only the shape. Parse the value as an unsigned
	// 16-bit integer so both zero and values above 65535 are rejected.
	p, err := strconv.ParseUint(port, 10, 16)
	return err == nil && p != 0
}

// ValidateUpstreams checks china/trust upstream spec lists as accepted by
// PUT /api/upstreams (and re-checked when loading upstreams.json). Both groups
// share one grammar — see validateUpstreamEntry — and each needs at least one
// entry.
func ValidateUpstreams(china, trust []string) error {
	if len(china) == 0 {
		return fmt.Errorf("%w: china list is empty", ErrInvalidUpstream)
	}
	if len(trust) == 0 {
		return fmt.Errorf("%w: trust list is empty", ErrInvalidUpstream)
	}
	for _, c := range china {
		if err := validateUpstreamEntry("china", strings.TrimSpace(c)); err != nil {
			return err
		}
	}
	for _, t := range trust {
		if err := validateUpstreamEntry("trust", strings.TrimSpace(t)); err != nil {
			return err
		}
	}
	return nil
}

// validateUpstreamEntry checks one spec against the grammar both groups share:
//
//   - bare "IP[:port]"                  plain UDP :53
//   - "serverName@IP[:port]"            DoT :853, TLS-verified against serverName
//   - "https://host/path@IP[:port]"     DoH :443 over pooled HTTP/2
//
// A bare hostname (no '@') is rejected rather than parsed: it would be dialed
// through the box's own resolve path — the exact self-reference footgun the
// subscription fetcher had to work around. That is also why the dial part after
// '@' is mandatory for DoT and DoH.
//
// group appears only in the error text, so a 400 still names which list the
// operator got wrong.
func validateUpstreamEntry(group, spec string) error {
	at := strings.LastIndex(spec, "@")
	switch {
	case strings.HasPrefix(spec, "https://"):
		if at <= 0 {
			return fmt.Errorf("%w: %s entry %q (DoH needs a pinned address, e.g. https://dns.google/dns-query@8.8.8.8)", ErrInvalidUpstream, group, spec)
		}
		endpoint, dial := spec[:at], spec[at+1:]
		u, err := url.Parse(endpoint)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" {
			return fmt.Errorf("%w: %s entry %q (bad DoH endpoint %q)", ErrInvalidUpstream, group, spec, endpoint)
		}
		if u.Path == "" || u.Path == "/" {
			return fmt.Errorf("%w: %s entry %q (DoH endpoint needs a path, e.g. /dns-query)", ErrInvalidUpstream, group, spec)
		}
		if !hostnameRE.MatchString(u.Hostname()) && net.ParseIP(u.Hostname()) == nil {
			return fmt.Errorf("%w: %s entry %q (bad DoH host %q)", ErrInvalidUpstream, group, spec, u.Hostname())
		}
		if !validIPPort(dial) {
			return fmt.Errorf("%w: %s entry %q (dial part %q must be IP or IP:port)", ErrInvalidUpstream, group, spec, dial)
		}
	case at > 0:
		name, dial := spec[:at], spec[at+1:]
		if !hostnameRE.MatchString(name) && net.ParseIP(name) == nil {
			return fmt.Errorf("%w: %s entry %q (bad server name %q)", ErrInvalidUpstream, group, spec, name)
		}
		if !validIPPort(dial) {
			return fmt.Errorf("%w: %s entry %q (dial part %q must be IP or IP:port)", ErrInvalidUpstream, group, spec, dial)
		}
	default:
		if !validIPPort(spec) {
			return fmt.Errorf("%w: %s entry %q (want IP[:port] for plain UDP, serverName@IP for DoT, or https://host/path@IP for DoH)", ErrInvalidUpstream, group, spec)
		}
	}
	return nil
}

// normalizeUpstreamList trims whitespace and drops empty elements, so the API
// tolerates ", "-joined input from the console.
func normalizeUpstreamList(in []string) []string {
	out := make([]string, 0, len(in))
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

// upstreamSnapshot is the hot-swappable upstream state of a Handler: the two
// live exchanger groups plus the raw specs they were built from (kept for
// GET /api/upstreams and the resolve-test's per-server probes). Swapped
// atomically by Handler.swapUpstreams; in-flight queries holding the old
// snapshot finish against the old groups safely.
type upstreamSnapshot struct {
	China        Exchanger
	Trust        Exchanger
	ChinaRaw     []string
	ChinaEntries []UpstreamEntry
	TrustRaw     []string
	TrustEntries []UpstreamEntry
}

// exchangerFunc adapts a function to the Exchanger interface — used to hand
// long-lived consumers (the subscription fetcher's trust-host resolver) a
// handle that always delegates to the CURRENT trust group, so a hot upstream
// swap is picked up without re-wiring them.
type exchangerFunc func(ctx context.Context, q *dns.Msg) (*dns.Msg, error)

// Exchange implements Exchanger.
func (f exchangerFunc) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	return f(ctx, q)
}
