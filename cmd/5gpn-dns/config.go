package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// TrustEntry describes a single DoT upstream: the TLS ServerName to verify
// and the IP address (with optional port) to dial.
//
// Parsed from entries of the form "serverName@dialIP" or bare "IP" (where the
// ServerName is set equal to the IP, relying on the IP SAN in the cert).
type TrustEntry struct {
	ServerName string // TLS SNI / cert verification name
	DialAddr   string // host (or host:port) to dial
}

// Config holds the resolved configuration for 5gpn-dns.
type Config struct {
	// Listener addresses.  An empty string means the listener is disabled.
	ListenDoT   string // default :853   (TLS)
	ListenDoH   string // default :8443  (TLS)
	ListenPlain string // default :53    (UDP + TCP)
	ListenDebug string // default 127.0.0.1:5353 (plain UDP, debug)

	// TLS certificate files for DoT + DoH listeners.
	CertFile string
	KeyFile  string

	// Networking.
	GatewayIP    net.IP       // foreign-address rewrite target
	ChinaAddrs   []string     // UDP upstream addresses (no port → :53 appended later)
	TrustEntries []TrustEntry // DoT upstream entries

	// Rule file locations.
	RulesDir     string // directory containing adblock/direct/blacklist sub-files
	ChnrouteFile string // path to china IP CIDR list

	// Phase 2 subscriptions.
	SubscriptionsFile string // path to subscriptions.json

	// Cache.
	CacheSize int // max entries (0 → use default 4096)

	// TTL clamping.
	TTLMin time.Duration
	TTLMax time.Duration

	// Per-query upstream timeout.
	QueryTimeout time.Duration
}

// LoadConfig reads DNS_* environment variables and returns a validated Config.
//
// Defaults (spec §6 + §13):
//
//	DNS_LISTEN_DOT      :853
//	DNS_LISTEN_DOH      :8443
//	DNS_LISTEN_PLAIN    :53
//	DNS_LISTEN_DEBUG    127.0.0.1:5353
//	DNS_CHINA           223.5.5.5,119.29.29.29
//	DNS_TRUST           dns.google@8.8.8.8,one.one.one.one@1.1.1.1
//	DNS_RULES_DIR       /etc/5gpn/rules
//	DNS_CACHE_SIZE      4096
//	DNS_TTL_MIN         300  (seconds)
//	DNS_TTL_MAX         86400 (seconds)
//	DNS_QUERY_TIMEOUT   5s
//	DNS_SUBSCRIPTIONS   /etc/5gpn/subscriptions.json
//
// Empty listener strings disable that server.
// If any TLS listener (DoT or DoH) has a non-empty address, DNS_CERT and
// DNS_KEY must also be non-empty, or an error is returned.
func LoadConfig() (Config, error) {
	cfg := Config{
		ListenDoT:         envListen("DNS_LISTEN_DOT", ":853"),
		ListenDoH:         envListen("DNS_LISTEN_DOH", ":8443"),
		ListenPlain:       envListen("DNS_LISTEN_PLAIN", ":53"),
		ListenDebug:       envListen("DNS_LISTEN_DEBUG", "127.0.0.1:5353"),
		CertFile:          os.Getenv("DNS_CERT"),
		KeyFile:           os.Getenv("DNS_KEY"),
		RulesDir:          envOr("DNS_RULES_DIR", "/etc/5gpn/rules"),
		ChnrouteFile:      os.Getenv("DNS_CHNROUTE"),
		SubscriptionsFile: envOr("DNS_SUBSCRIPTIONS", "/etc/5gpn/subscriptions.json"),
	}

	// Gateway IP.
	if raw := os.Getenv("DNS_GATEWAY_IP"); raw != "" {
		ip := net.ParseIP(raw)
		if ip == nil {
			return Config{}, fmt.Errorf("config: invalid DNS_GATEWAY_IP %q", raw)
		}
		cfg.GatewayIP = ip.To4()
		if cfg.GatewayIP == nil {
			cfg.GatewayIP = ip
		}
	}

	// China upstreams.
	chinaRaw := envOr("DNS_CHINA", "223.5.5.5,119.29.29.29")
	cfg.ChinaAddrs = splitTrim(chinaRaw)

	// Trust upstreams.
	trustRaw := envOr("DNS_TRUST", "dns.google@8.8.8.8,one.one.one.one@1.1.1.1")
	cfg.TrustEntries = parseTrustEntries(trustRaw)

	// Cache size.
	cacheSizeStr := os.Getenv("DNS_CACHE_SIZE")
	if cacheSizeStr != "" {
		n, err := strconv.Atoi(cacheSizeStr)
		if err != nil || n < 0 {
			return Config{}, fmt.Errorf("config: invalid DNS_CACHE_SIZE %q", cacheSizeStr)
		}
		cfg.CacheSize = n
	} else {
		cfg.CacheSize = 4096
	}

	// TTL min (seconds).
	ttlMin, err := parseSeconds("DNS_TTL_MIN", "300")
	if err != nil {
		return Config{}, err
	}
	cfg.TTLMin = ttlMin

	// TTL max (seconds).
	ttlMax, err := parseSeconds("DNS_TTL_MAX", "86400")
	if err != nil {
		return Config{}, err
	}
	cfg.TTLMax = ttlMax

	// Query timeout (Go duration string).
	qtRaw := envOr("DNS_QUERY_TIMEOUT", "5s")
	qt, err := time.ParseDuration(qtRaw)
	if err != nil {
		return Config{}, fmt.Errorf("config: invalid DNS_QUERY_TIMEOUT %q: %w", qtRaw, err)
	}
	cfg.QueryTimeout = qt

	// TLS validation: cert+key required when any TLS listener is enabled.
	tlsEnabled := cfg.ListenDoT != "" || cfg.ListenDoH != ""
	if tlsEnabled {
		if cfg.CertFile == "" || cfg.KeyFile == "" {
			return Config{}, errors.New("config: DNS_CERT and DNS_KEY are required when DoT or DoH listeners are enabled")
		}
	}

	return cfg, nil
}

// parseTrustEntries parses a comma-separated list of trust upstream specs.
// Each spec is either "serverName@dialAddr" or a bare IP (serverName = dialAddr).
func parseTrustEntries(raw string) []TrustEntry {
	parts := splitTrim(raw)
	entries := make([]TrustEntry, 0, len(parts))
	for _, p := range parts {
		if p == "" {
			continue
		}
		if at := strings.LastIndex(p, "@"); at > 0 {
			entries = append(entries, TrustEntry{
				ServerName: p[:at],
				DialAddr:   p[at+1:],
			})
		} else {
			// Bare IP or hostname — ServerName equals DialAddr (relies on IP SAN).
			entries = append(entries, TrustEntry{
				ServerName: p,
				DialAddr:   p,
			})
		}
	}
	return entries
}

// envListen reads a listener address from key.  An explicitly-empty value
// disables the listener.  If the variable is not set at all the default is used.
func envListen(key, def string) string {
	v, ok := os.LookupEnv(key)
	if !ok {
		return def
	}
	return v // "" means disabled; non-empty means the provided address
}

// envOr returns os.Getenv(key) when non-empty, otherwise def.
// For non-listener settings: empty and unset are both treated as "use default".
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// splitTrim splits a comma-separated string and trims each element.
func splitTrim(s string) []string {
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// parseSeconds parses an environment variable that holds an integer number of
// seconds.  def is used when the variable is unset/empty.
func parseSeconds(envKey, def string) (time.Duration, error) {
	raw := os.Getenv(envKey)
	if raw == "" {
		raw = def
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("config: invalid %s %q: must be a non-negative integer (seconds)", envKey, raw)
	}
	return time.Duration(n) * time.Second, nil
}
