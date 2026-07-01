package main

import (
	"errors"
	"fmt"
	"log"
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

	// Phase 3 control-plane API.
	ListenAPI string // default :9443 (TLS); control plane is disabled unless APIToken is set
	APIToken  string // bearer token for /api/*; no default — empty means disabled

	// Phase 4 Task C1: per-source rate limiting on the control-plane API.
	APIRate  float64 // requests/sec allowed per source IP; <= 0 disables rate limiting
	APIBurst int     // token-bucket capacity per source IP

	// Phase 4 Task A2: query-stat counter persistence.
	StatsFile string // path for cumulative stats snapshot; empty disables persistence

	// Phase 5: in-process Telegram bot.
	TGBotToken  string         // env TGBOT_TOKEN; empty ⇒ bot disabled
	TGBotAdmins map[int64]bool // env TGBOT_ADMINS; comma/space-separated int64 admin IDs

	// Phase 5 Task 4: in-process iOS DoT-profile server (replaces src/ios-http.py).
	IOSListen string // env DNS_IOS_LISTEN; default :8111; empty ⇒ server disabled
	WWWDir    string // env WWW_DIR; default /opt/5gpn/www; static-file root

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
//	DNS_LISTEN_API      :9443
//	DNS_API_TOKEN       (none — control plane disabled unless set)
//	DNS_STATS_FILE      /etc/5gpn/stats.json (empty disables persistence)
//	DNS_API_RATE        20 (requests/sec per source IP; <= 0 disables rate limiting)
//	DNS_API_BURST       40 (token-bucket capacity per source IP)
//	DNS_IOS_LISTEN      :8111 (iOS DoT-profile HTTP server; empty disables)
//	WWW_DIR             /opt/5gpn/www (static-file root for the iOS server)
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
		ListenAPI:         envListen("DNS_LISTEN_API", ":9443"),
		APIToken:          os.Getenv("DNS_API_TOKEN"),
		StatsFile:         envListen("DNS_STATS_FILE", "/etc/5gpn/stats.json"),
		TGBotToken:        os.Getenv("TGBOT_TOKEN"),
		TGBotAdmins:       parseAdminIDs(os.Getenv("TGBOT_ADMINS")),
		IOSListen:         envListen("DNS_IOS_LISTEN", ":8111"),
		WWWDir:            envOr("WWW_DIR", "/opt/5gpn/www"),
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

	// Control-plane API rate limit (requests/sec per source IP). Tolerant
	// parse: a bad value falls back to the default rather than failing
	// LoadConfig outright (matches the other numeric-knob-with-fallback
	// pattern used here, since a malformed rate limit isn't worth crashing
	// the whole daemon over). <= 0 (explicitly, e.g. "0") disables limiting.
	const defaultAPIRate = 20
	cfg.APIRate = defaultAPIRate
	if raw := os.Getenv("DNS_API_RATE"); raw != "" {
		if n, err := strconv.ParseFloat(raw, 64); err == nil {
			cfg.APIRate = n
		} else {
			log.Printf("config: invalid DNS_API_RATE %q, using default %v", raw, defaultAPIRate)
		}
	}

	// Control-plane API token-bucket burst capacity per source IP.
	const defaultAPIBurst = 40
	cfg.APIBurst = defaultAPIBurst
	if raw := os.Getenv("DNS_API_BURST"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			cfg.APIBurst = n
		} else {
			log.Printf("config: invalid DNS_API_BURST %q, using default %d", raw, defaultAPIBurst)
		}
	}
	// A burst <= 0 while rate limiting is enabled would make the limiter
	// unusable (never lets a request through), so fall back to the sane
	// default in that case too.
	if cfg.APIRate > 0 && cfg.APIBurst <= 0 {
		cfg.APIBurst = defaultAPIBurst
	}

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

// parseAdminIDs parses TGBOT_ADMINS: a list of Telegram numeric user IDs
// separated by commas and/or whitespace (e.g. "111, 222 333"). Blank and
// non-numeric ("garbage") tokens are silently skipped. Returns a set; an
// empty/unset input yields an empty (non-nil) map.
func parseAdminIDs(raw string) map[int64]bool {
	admins := make(map[int64]bool)
	for _, tok := range strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n' || r == '\r'
	}) {
		id, err := strconv.ParseInt(tok, 10, 64)
		if err != nil {
			continue // ignore blanks/garbage
		}
		admins[id] = true
	}
	return admins
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
