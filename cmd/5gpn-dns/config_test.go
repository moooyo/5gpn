package main

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// allDNSEnvKeys is the complete list of env vars read by LoadConfig.
var allDNSEnvKeys = []string{
	"DNS_LISTEN_DOT", "DNS_LISTEN_DEBUG",
	"DNS_CERT", "DNS_KEY", "DNS_WEB_CERT", "DNS_WEB_KEY", "DNS_GATEWAY_IP",
	"DNS_CHINA", "DNS_TRUST", "DNS_UPSTREAMS", "DNS_RULES_DIR", "DNS_CHNROUTE",
	"DNS_CACHE_SIZE", "DNS_MAX_INFLIGHT", "DNS_TTL_MIN", "DNS_TTL_MAX", "DNS_QUERY_TIMEOUT",
	"DNS_HEARTBEAT_URL", "DNS_HEARTBEAT_INTERVAL",
	"DNS_SUBSCRIPTIONS",
	"DNS_LISTEN_API", "DNS_API_TOKEN",
	"DNS_STATS_FILE",
	"DNS_API_RATE", "DNS_API_BURST",
	"TGBOT_TOKEN", "TGBOT_ADMINS", "DNS_TGBOT_FILE", "TGBOT_PROXY_URL", "TGBOT_ALERTS",
	"WWW_DIR",
	"DNS_CHINA_ECS", "DNS_ECS_FILE",
	"DNS_EGRESS_BROKER",
	"DNS_EGRESS_RESOLVER",
	"DNS_BASE_DOMAIN",
	"DNS_MIHOMO_CONTROLLER", "DNS_MIHOMO_SECRET", "DNS_WHITELIST_FILE",
	"DNS_MIHOMO_CONFIG", "DNS_INTERCEPT_CONFIG", "DNS_MARKETPLACES_FILE",
	"DNS_ZASH_DIR", "DNS_ZASH_LISTEN", "DNS_ZASH_CERT", "DNS_ZASH_KEY",
}

// clearAllDNSEnv unsets all DNS_ vars and restores them on t.Cleanup.
func clearAllDNSEnv(t *testing.T) {
	t.Helper()
	for _, k := range allDNSEnvKeys {
		// t.Setenv saves the old value and restores it at cleanup.
		// We want to UNSET (not set-to-""), so we call os.Unsetenv manually
		// and register a cleanup that restores the original value or unsets again.
		old, wasSet := os.LookupEnv(k)
		if err := os.Unsetenv(k); err != nil {
			t.Fatalf("os.Unsetenv(%q): %v", k, err)
		}
		k, old, wasSet := k, old, wasSet // capture
		t.Cleanup(func() {
			if wasSet {
				_ = os.Setenv(k, old)
			} else {
				_ = os.Unsetenv(k)
			}
		})
	}
}

func TestLoadConfig_Defaults(t *testing.T) {
	// Wipe all DNS_ vars so we get pure defaults.  We also must supply cert/key
	// because the default DoT listener (:853) is TLS.
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}

	// Default listeners: DoT is the ONLY client-facing DNS transport (DoH and
	// client DNS is DoT-only; the debug listener is loopback-only.
	if cfg.ListenDoT != ":853" {
		t.Errorf("ListenDoT default = %q, want %q", cfg.ListenDoT, ":853")
	}
	if cfg.ListenDebug != "127.0.0.1:5353" {
		t.Errorf("ListenDebug default = %q, want %q", cfg.ListenDebug, "127.0.0.1:5353")
	}

	if cfg.WebCertFile != "" || cfg.WebKeyFile != "" || cfg.ZashCertFile != "" || cfg.ZashKeyFile != "" {
		t.Errorf("role certs must remain explicit, got web=%q/%q zash=%q/%q", cfg.WebCertFile, cfg.WebKeyFile, cfg.ZashCertFile, cfg.ZashKeyFile)
	}

	// Default upstream lists.
	wantChina := []string{"223.5.5.5"}
	if len(cfg.ChinaAddrs) != len(wantChina) {
		t.Errorf("ChinaAddrs len = %d, want %d", len(cfg.ChinaAddrs), len(wantChina))
	} else {
		for i, a := range cfg.ChinaAddrs {
			if a != wantChina[i] {
				t.Errorf("ChinaAddrs[%d] = %q, want %q", i, a, wantChina[i])
			}
		}
	}

	// Default trust upstream: 22.22.22.22, bare IP ⇒ plain UDP.
	wantTrust := []TrustEntry{
		{ServerName: "22.22.22.22", DialAddr: "22.22.22.22", Plain: true},
	}
	if len(cfg.TrustEntries) != len(wantTrust) {
		t.Fatalf("TrustEntries len = %d, want %d", len(cfg.TrustEntries), len(wantTrust))
	}
	for i, te := range cfg.TrustEntries {
		if te != wantTrust[i] {
			t.Errorf("TrustEntries[%d] = %+v, want %+v", i, te, wantTrust[i])
		}
	}
	if len(cfg.TrustRaw) != 1 || cfg.TrustRaw[0] != "22.22.22.22" {
		t.Errorf("TrustRaw = %v, want [22.22.22.22]", cfg.TrustRaw)
	}
	if cfg.UpstreamsFile != "/etc/5gpn/upstreams.json" {
		t.Errorf("UpstreamsFile = %q, want /etc/5gpn/upstreams.json", cfg.UpstreamsFile)
	}
	if got := ecsSubnetString(cfg.ChinaECS); got != "112.96.32.0/24" {
		t.Errorf("ChinaECS default = %q, want 112.96.32.0/24", got)
	}

	// Default durations.
	if cfg.TTLMin != 300*time.Second {
		t.Errorf("TTLMin = %v, want 300s", cfg.TTLMin)
	}
	if cfg.TTLMax != 86400*time.Second {
		t.Errorf("TTLMax = %v, want 86400s", cfg.TTLMax)
	}
	if cfg.QueryTimeout != 5*time.Second {
		t.Errorf("QueryTimeout = %v, want 5s", cfg.QueryTimeout)
	}

	// Default cache size.
	if cfg.CacheSize != 4096 {
		t.Errorf("CacheSize default = %d, want 4096", cfg.CacheSize)
	}

	// Default subscriptions file.
	if cfg.SubscriptionsFile != "/etc/5gpn/subscriptions.json" {
		t.Errorf("SubscriptionsFile default = %q, want %q", cfg.SubscriptionsFile, "/etc/5gpn/subscriptions.json")
	}

	// Default control-plane API listener; token has no default (empty). Binds
	// LOOPBACK :443 directly — the mihomo SNI split redirects panel traffic
	// straight there, so the daemon never needs a public listener.
	if cfg.ListenAPI != "127.0.0.1:443" {
		t.Errorf("ListenAPI default = %q, want %q", cfg.ListenAPI, "127.0.0.1:443")
	}
	if cfg.APIToken != "" {
		t.Errorf("APIToken default = %q, want empty", cfg.APIToken)
	}

	// Default stats persistence file.
	if cfg.StatsFile != "/etc/5gpn/stats.json" {
		t.Errorf("StatsFile default = %q, want %q", cfg.StatsFile, "/etc/5gpn/stats.json")
	}

	// Default control-plane API rate limit.
	if cfg.APIRate != 20 {
		t.Errorf("APIRate default = %v, want 20", cfg.APIRate)
	}
	if cfg.APIBurst != 40 {
		t.Errorf("APIBurst default = %d, want 40", cfg.APIBurst)
	}

	// Telegram bot: token has no default (empty ⇒ bot disabled);
	// admins parses to an empty (non-nil) set.
	if cfg.TGBotToken != "" {
		t.Errorf("TGBotToken default = %q, want empty", cfg.TGBotToken)
	}
	if len(cfg.TGBotAdmins) != 0 {
		t.Errorf("TGBotAdmins default = %v, want empty set", cfg.TGBotAdmins)
	}
	if cfg.TGBotProxyURL != "" {
		t.Errorf("TGBotProxyURL default = %q, want empty", cfg.TGBotProxyURL)
	}
	if cfg.TGBotFile != "/etc/5gpn/tgbot.json" {
		t.Errorf("TGBotFile default = %q", cfg.TGBotFile)
	}
	if cfg.TGBotAlerts {
		t.Error("TGBotAlerts default = true, want false")
	}

	// iOS profile files (served at the control server's public /ios/ path).
	if cfg.WWWDir != "/opt/5gpn/www" {
		t.Errorf("WWWDir default = %q, want %q", cfg.WWWDir, "/opt/5gpn/www")
	}
}

func TestLoadConfig_EnvOverride(t *testing.T) {
	clearAllDNSEnv(t)

	// Disable the DoT listener so no cert required.
	t.Setenv("DNS_LISTEN_DOT", "")
	t.Setenv("DNS_LISTEN_DEBUG", "127.0.0.1:1053")
	t.Setenv("DNS_GATEWAY_IP", "10.0.0.1")
	t.Setenv("DNS_CHINA", "8.8.8.8")
	t.Setenv("DNS_TRUST", "dns.google@8.8.8.8,one.one.one.one@1.1.1.1")
	t.Setenv("DNS_TTL_MIN", "60")
	t.Setenv("DNS_TTL_MAX", "3600")
	t.Setenv("DNS_QUERY_TIMEOUT", "3s")
	t.Setenv("DNS_CACHE_SIZE", "512")
	t.Setenv("DNS_SUBSCRIPTIONS", "/opt/5gpn/subs.json")
	t.Setenv("DNS_LISTEN_API", "127.0.0.1:9444")
	t.Setenv("DNS_API_TOKEN", "s3cr3t")
	t.Setenv("DNS_STATS_FILE", "/opt/5gpn/stats.json")
	t.Setenv("DNS_API_RATE", "5")
	t.Setenv("DNS_API_BURST", "10")
	t.Setenv("DNS_WEB_CERT", "/etc/5gpn/cert/web/current/fullchain.pem")
	t.Setenv("DNS_WEB_KEY", "/etc/5gpn/cert/web/current/privkey.pem")
	t.Setenv("DNS_ZASH_CERT", "/etc/5gpn/cert/zash/current/fullchain.pem")
	t.Setenv("DNS_ZASH_KEY", "/etc/5gpn/cert/zash/current/privkey.pem")
	t.Setenv("WWW_DIR", "/opt/5gpn/custom-www")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}

	if cfg.ListenDoT != "" {
		t.Errorf("ListenDoT = %q, want empty (disabled)", cfg.ListenDoT)
	}
	if cfg.ListenDebug != "127.0.0.1:1053" {
		t.Errorf("ListenDebug = %q, want %q", cfg.ListenDebug, "127.0.0.1:1053")
	}
	if cfg.GatewayIP.String() != "10.0.0.1" {
		t.Errorf("GatewayIP = %v, want 10.0.0.1", cfg.GatewayIP)
	}
	if len(cfg.ChinaAddrs) != 1 || cfg.ChinaAddrs[0] != "8.8.8.8" {
		t.Errorf("ChinaAddrs = %v, want [8.8.8.8]", cfg.ChinaAddrs)
	}
	if cfg.TTLMin != 60*time.Second {
		t.Errorf("TTLMin = %v, want 60s", cfg.TTLMin)
	}
	if cfg.TTLMax != 3600*time.Second {
		t.Errorf("TTLMax = %v, want 3600s", cfg.TTLMax)
	}
	if cfg.QueryTimeout != 3*time.Second {
		t.Errorf("QueryTimeout = %v, want 3s", cfg.QueryTimeout)
	}
	if cfg.CacheSize != 512 {
		t.Errorf("CacheSize = %d, want 512", cfg.CacheSize)
	}
	if cfg.SubscriptionsFile != "/opt/5gpn/subs.json" {
		t.Errorf("SubscriptionsFile = %q, want %q", cfg.SubscriptionsFile, "/opt/5gpn/subs.json")
	}
	if cfg.ListenAPI != "127.0.0.1:9444" {
		t.Errorf("ListenAPI = %q, want %q", cfg.ListenAPI, "127.0.0.1:9444")
	}
	if cfg.APIToken != "s3cr3t" {
		t.Errorf("APIToken = %q, want %q", cfg.APIToken, "s3cr3t")
	}
	if cfg.StatsFile != "/opt/5gpn/stats.json" {
		t.Errorf("StatsFile = %q, want %q", cfg.StatsFile, "/opt/5gpn/stats.json")
	}
	if cfg.APIRate != 5 {
		t.Errorf("APIRate = %v, want 5", cfg.APIRate)
	}
	if cfg.APIBurst != 10 {
		t.Errorf("APIBurst = %d, want 10", cfg.APIBurst)
	}
	if cfg.WebCertFile != "/etc/5gpn/cert/web/current/fullchain.pem" || cfg.WebKeyFile != "/etc/5gpn/cert/web/current/privkey.pem" {
		t.Errorf("WebCertFile/WebKeyFile = %q/%q, want the DNS_WEB_CERT/KEY overrides", cfg.WebCertFile, cfg.WebKeyFile)
	}
	if cfg.WWWDir != "/opt/5gpn/custom-www" {
		t.Errorf("WWWDir = %q, want %q", cfg.WWWDir, "/opt/5gpn/custom-www")
	}
}

func TestLoadConfig_DerivesZashDomainFromBaseDomain(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_LISTEN_DOT", "")
	t.Setenv("DNS_BASE_DOMAIN", "example.com.")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.ZashDomain != "zash.example.com" {
		t.Fatalf("ZashDomain = %q, want zash.example.com", cfg.ZashDomain)
	}
}

// TestLoadConfig_APITokenEmptyByDefault confirms DNS_API_TOKEN has no default:
// when unset the control plane is left disabled (empty token), distinct from
// the listener defaults which always resolve to a non-empty address.
func TestLoadConfig_APITokenEmptyByDefault(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	// DNS_API_TOKEN intentionally left unset.

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.APIToken != "" {
		t.Errorf("APIToken = %q, want empty when DNS_API_TOKEN unset", cfg.APIToken)
	}
	// ListenAPI still defaults even though the token is empty (NewControlServer
	// is what decides disablement, not LoadConfig).
	if cfg.ListenAPI != "127.0.0.1:443" {
		t.Errorf("ListenAPI = %q, want %q", cfg.ListenAPI, "127.0.0.1:443")
	}
}

func TestLoadConfig_TLSRequired_DoT(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_LISTEN_DOT", ":853")
	// DNS_CERT and DNS_KEY remain empty.

	_, err := LoadConfig()
	if err == nil {
		t.Fatal("expected error when DoT enabled but CERT/KEY missing, got nil")
	}
}

func TestLoadConfig_TLSNotRequired_NoTLSListeners(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_LISTEN_DOT", "")
	// DNS_CERT and DNS_KEY remain empty.

	_, err := LoadConfig()
	if err != nil {
		t.Fatalf("no TLS listeners → no cert error expected, got: %v", err)
	}
}

// TestLoadConfig_APIRateDisabled confirms DNS_API_RATE=0 disables rate
// limiting (APIRate <= 0 is the "allow all" sentinel consumed by
// newRateLimiter/the middleware).
func TestLoadConfig_APIRateDisabled(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_API_RATE", "0")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.APIRate != 0 {
		t.Errorf("APIRate = %v, want 0 (disabled)", cfg.APIRate)
	}
}

// TestLoadConfig_APIRateBadValueFallsBackToDefault confirms a malformed
// DNS_API_RATE doesn't crash LoadConfig -- it falls back to the default
// rather than propagating a parse error (tolerant-numeric-knob pattern).
func TestLoadConfig_APIRateBadValueFallsBackToDefault(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_API_RATE", "not-a-number")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.APIRate != 20 {
		t.Errorf("APIRate with bad env = %v, want default 20", cfg.APIRate)
	}
}

// TestLoadConfig_APIBurstBadValueFallsBackToDefault mirrors the rate case for
// DNS_API_BURST.
func TestLoadConfig_APIBurstBadValueFallsBackToDefault(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_API_BURST", "not-a-number")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.APIBurst != 40 {
		t.Errorf("APIBurst with bad env = %d, want default 40", cfg.APIBurst)
	}
}

// TestLoadConfig_APIBurstZeroOrNegativeFallsBackWhenRatePositive confirms
// that when APIRate is positive (rate limiting enabled) but APIBurst is
// given as <= 0, we fall back to the sane default rather than building a
// limiter that can never let a request through.
func TestLoadConfig_APIBurstZeroOrNegativeFallsBackWhenRatePositive(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_API_RATE", "5")
	t.Setenv("DNS_API_BURST", "0")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.APIBurst != 40 {
		t.Errorf("APIBurst = %d, want fallback default 40 when given 0 with rate>0", cfg.APIBurst)
	}
}

// TestLoadConfig_TGBot confirms TGBOT_TOKEN / TGBOT_ADMINS are read into the
// Config: token verbatim, admins parsed into an int64 set (mixed comma/space
// separators, garbage dropped).
func TestLoadConfig_TGBot(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("TGBOT_TOKEN", "12345:abcdef")
	t.Setenv("TGBOT_ADMINS", "111, 222 333")
	t.Setenv("DNS_TGBOT_FILE", "/tmp/test-tgbot.json")
	t.Setenv("TGBOT_PROXY_URL", "http://127.0.0.1:7890")
	t.Setenv("TGBOT_ALERTS", "true")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.TGBotToken != "12345:abcdef" {
		t.Errorf("TGBotToken = %q, want %q", cfg.TGBotToken, "12345:abcdef")
	}
	if cfg.TGBotProxyURL != "http://127.0.0.1:7890" {
		t.Errorf("TGBotProxyURL = %q", cfg.TGBotProxyURL)
	}
	if cfg.TGBotFile != "/tmp/test-tgbot.json" {
		t.Errorf("TGBotFile = %q", cfg.TGBotFile)
	}
	if !cfg.TGBotAlerts {
		t.Error("TGBotAlerts = false, want true")
	}
	want := map[int64]bool{111: true, 222: true, 333: true}
	if len(cfg.TGBotAdmins) != len(want) {
		t.Fatalf("TGBotAdmins = %v, want %v", cfg.TGBotAdmins, want)
	}
	for id := range want {
		if !cfg.TGBotAdmins[id] {
			t.Errorf("TGBotAdmins missing %d; got %v", id, cfg.TGBotAdmins)
		}
	}
}

func TestLoadConfig_TGBotProxyValidation(t *testing.T) {
	for _, tc := range []struct {
		name      string
		proxy     string
		wantToken bool
	}{
		{name: "http", proxy: "http://127.0.0.1:7890", wantToken: true},
		{name: "https with auth", proxy: "https://user:secret@proxy.example:8443", wantToken: true},
		{name: "socks rejected", proxy: "socks5://127.0.0.1:7890"},
		{name: "missing host", proxy: "http://"},
		{name: "path rejected", proxy: "http://proxy.example/not-a-proxy-path"},
		{name: "query rejected", proxy: "http://proxy.example?x=1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			clearAllDNSEnv(t)
			t.Setenv("DNS_LISTEN_DOT", "")
			t.Setenv("TGBOT_PROXY_URL", tc.proxy)
			t.Setenv("TGBOT_TOKEN", "123:token")
			cfg, err := LoadConfig()
			if err != nil {
				t.Fatalf("LoadConfig() must not fail DNS for optional proxy: %v", err)
			}
			if (cfg.TGBotToken != "") != tc.wantToken {
				t.Fatalf("TGBotToken retained = %v, want %v", cfg.TGBotToken != "", tc.wantToken)
			}
		})
	}
}

// TestParseAdminIDs exercises the separator handling and garbage rejection of
// the TGBOT_ADMINS parser directly.
func TestParseAdminIDs(t *testing.T) {
	tests := []struct {
		input string
		want  map[int64]bool
	}{
		{"", map[int64]bool{}},
		{"   ", map[int64]bool{}},
		{"111, 222 333", map[int64]bool{111: true, 222: true, 333: true}},
		{"111,222,333", map[int64]bool{111: true, 222: true, 333: true}},
		{"111\t222\n333", map[int64]bool{111: true, 222: true, 333: true}},
		{"x", map[int64]bool{}},                               // pure garbage dropped
		{"111, x, 222", map[int64]bool{111: true, 222: true}}, // garbage skipped, rest kept
		{"-5", map[int64]bool{-5: true}},                      // negative IDs are valid int64
		{",,111,,", map[int64]bool{111: true}},                // empty tokens ignored
	}
	for _, tc := range tests {
		got := parseAdminIDs(tc.input)
		if len(got) != len(tc.want) {
			t.Errorf("parseAdminIDs(%q) = %v, want %v", tc.input, got, tc.want)
			continue
		}
		for id := range tc.want {
			if !got[id] {
				t.Errorf("parseAdminIDs(%q) = %v, missing %d", tc.input, got, id)
			}
		}
	}
}

func TestParseTrustEntryList(t *testing.T) {
	tests := []struct {
		input []string
		want  []TrustEntry
	}{
		{
			input: []string{"dns.google@8.8.8.8"},
			want:  []TrustEntry{{ServerName: "dns.google", DialAddr: "8.8.8.8"}},
		},
		{
			// Bare IP ⇒ plain UDP (deliberate reversal 2026-07-10: it used to
			// mean DoT-with-IP-SAN, which made an internal-resolver default
			// like 22.22.22.22 unusable).
			input: []string{"1.1.1.1"},
			want:  []TrustEntry{{ServerName: "1.1.1.1", DialAddr: "1.1.1.1", Plain: true}},
		},
		{
			input: []string{"dns.google@8.8.8.8", "one.one.one.one@1.1.1.1"},
			want: []TrustEntry{
				{ServerName: "dns.google", DialAddr: "8.8.8.8"},
				{ServerName: "one.one.one.one", DialAddr: "1.1.1.1"},
			},
		},
	}
	for _, tc := range tests {
		got := parseTrustEntryList(tc.input)
		if len(got) != len(tc.want) {
			t.Errorf("parseTrustEntryList(%q): len=%d, want %d", tc.input, len(got), len(tc.want))
			continue
		}
		for i, te := range got {
			if te != tc.want[i] {
				t.Errorf("parseTrustEntryList(%q)[%d] = %+v, want %+v", tc.input, i, te, tc.want[i])
			}
		}
	}
}

// B4: numeric tuning knobs (CACHE_SIZE / MAX_INFLIGHT / TTL_MIN / TTL_MAX /
// QUERY_TIMEOUT) must fall back to their defaults on a malformed value rather
// than making LoadConfig fatal — a single mistyped knob must never crash the
// network's only resolver into a restart loop. This unifies their behaviour with
// the DNS_API_RATE/BURST knobs (which already tolerated bad values).
func TestLoadConfig_NumericKnobsBadValueFallBack(t *testing.T) {
	cases := []struct {
		key    string
		bad    string
		check  func(Config) bool
		wantSt string
	}{
		{"DNS_CACHE_SIZE", "not-a-number", func(c Config) bool { return c.CacheSize == 4096 }, "CacheSize=4096"},
		{"DNS_CACHE_SIZE", "-5", func(c Config) bool { return c.CacheSize == 4096 }, "CacheSize=4096"},
		{"DNS_MAX_INFLIGHT", "xyz", func(c Config) bool { return c.MaxInflight == 4096 }, "MaxInflight=4096"},
		{"DNS_TTL_MIN", "bad", func(c Config) bool { return c.TTLMin == 300*time.Second }, "TTLMin=300s"},
		{"DNS_TTL_MAX", "bad", func(c Config) bool { return c.TTLMax == 86400*time.Second }, "TTLMax=86400s"},
		{"DNS_QUERY_TIMEOUT", "not-a-duration", func(c Config) bool { return c.QueryTimeout == 5*time.Second }, "QueryTimeout=5s"},
	}
	for _, tc := range cases {
		t.Run(tc.key+"="+tc.bad, func(t *testing.T) {
			clearAllDNSEnv(t)
			t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
			t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
			t.Setenv(tc.key, tc.bad)

			cfg, err := LoadConfig()
			if err != nil {
				t.Fatalf("LoadConfig() with bad %s should not error, got: %v", tc.key, err)
			}
			if !tc.check(cfg) {
				t.Errorf("bad %s=%q did not fall back to default (%s)", tc.key, tc.bad, tc.wantSt)
			}
		})
	}
}

func TestLoadConfig_EgressBroker_Default(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.EgressBrokerAddr != "127.0.0.1:5354" {
		t.Errorf("EgressBrokerAddr default = %q, want 127.0.0.1:5354", cfg.EgressBrokerAddr)
	}
}

// TestLoadConfig_EgressBroker_EmptyRejected verifies mihomo's resolver
// boundary cannot be disabled.
func TestLoadConfig_EgressBroker_EmptyRejected(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_EGRESS_BROKER", "")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig accepted an empty DNS_EGRESS_BROKER")
	}
}

func TestLoadConfigRejectsRetiredEgressResolver(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_EGRESS_RESOLVER", "203.0.113.53")
	if _, err := LoadConfig(); err == nil || !strings.Contains(err.Error(), "retired") {
		t.Fatalf("retired resolver error = %v", err)
	}
}

// TestLoadConfig_EgressBroker_AcceptsLoopbackOverride verifies a
// non-default loopback IPv4 literal (with a custom port) is accepted.
func TestLoadConfig_EgressBroker_AcceptsLoopbackOverride(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_EGRESS_BROKER", "127.0.0.5:6000")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}
	if cfg.EgressBrokerAddr != "127.0.0.5:6000" {
		t.Errorf("EgressBrokerAddr = %q, want 127.0.0.5:6000", cfg.EgressBrokerAddr)
	}
}

// TestLoadConfig_EgressBroker_RejectsNonLoopback verifies a routable (or
// non-loopback loopback-adjacent) address is rejected — the broker must
// never be reachable off-box (spec 6.5: loopback-only, never DNS_GATEWAY_IP,
// never a public surface).
func TestLoadConfig_EgressBroker_RejectsNonLoopback(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_EGRESS_BROKER", "0.0.0.0:5354")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig must reject a non-loopback DNS_EGRESS_BROKER")
	}
}

// TestLoadConfig_EgressBroker_RejectsIPv6 verifies an IPv6 loopback literal
// is rejected: RestrictAF-style IPv4-only handling has no IPv6 support in
// this architecture yet, so accepting ::1 would produce an unreachable broker.
func TestLoadConfig_EgressBroker_RejectsIPv6(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_EGRESS_BROKER", "[::1]:5354")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig must reject an IPv6 DNS_EGRESS_BROKER (IPv4-only architecture)")
	}
}

// TestLoadConfig_EgressBroker_RejectsHostname verifies a bare hostname
// (not an IP literal) is rejected — the broker's loopback invariant must be
// checkable without a DNS lookup at config-load time.
func TestLoadConfig_EgressBroker_RejectsHostname(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	t.Setenv("DNS_EGRESS_BROKER", "localhost:5354")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig must reject a non-IP-literal DNS_EGRESS_BROKER host")
	}
}

// TestLoadConfig_EgressBroker_RejectsBadPort verifies the port portion of
// DNS_EGRESS_BROKER is validated explicitly (strconv.ParseUint, 1..65535) at
// LoadConfig time rather than deferred to the eventual net.Listen bind
// failure — a non-numeric, zero, or out-of-range port is a config error the
// operator should see immediately.
func TestLoadConfig_EgressBroker_RejectsBadPort(t *testing.T) {
	for _, addr := range []string{
		"127.0.0.1:abc",
		"127.0.0.1:0",
		"127.0.0.1:65536",
	} {
		t.Run(addr, func(t *testing.T) {
			clearAllDNSEnv(t)
			t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
			t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
			t.Setenv("DNS_EGRESS_BROKER", addr)

			if _, err := LoadConfig(); err == nil {
				t.Fatalf("LoadConfig must reject DNS_EGRESS_BROKER=%q", addr)
			}
		})
	}
}

// TestLoadConfig_ConsoleLoopback443 verifies the loopback control-plane default.
func TestLoadConfig_ConsoleLoopback443(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_GATEWAY_IP", "203.0.113.1")
	t.Setenv("DNS_CERT", "/x/c")
	t.Setenv("DNS_KEY", "/x/k")
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ListenAPI != "127.0.0.1:443" {
		t.Fatalf("ListenAPI=%q want 127.0.0.1:443", cfg.ListenAPI)
	}
}

// TestLoadConfig_MihomoKnobs verifies base/console/zash domains, the loopback mihomo controller address +
// secret, and the panel allowlist file -- all resolved via the standard
// envOr-default pattern.
func TestLoadConfig_MihomoKnobs(t *testing.T) {
	t.Run("defaults", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")

		cfg, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		if cfg.BaseDomain != "" {
			t.Errorf("BaseDomain default = %q, want empty", cfg.BaseDomain)
		}
		if cfg.DotDomain != "" {
			t.Errorf("DotDomain default = %q, want empty", cfg.DotDomain)
		}
		if cfg.ConsoleDomain != "" {
			t.Errorf("ConsoleDomain default = %q, want empty", cfg.ConsoleDomain)
		}
		if cfg.ZashDomain != "" {
			t.Errorf("ZashDomain default = %q, want empty", cfg.ZashDomain)
		}
		if cfg.MihomoController != "127.0.0.1:9090" {
			t.Errorf("MihomoController default = %q, want 127.0.0.1:9090", cfg.MihomoController)
		}
		if cfg.MihomoSecret != "" {
			t.Errorf("MihomoSecret default = %q, want empty", cfg.MihomoSecret)
		}
		if cfg.WhitelistFile != "/etc/5gpn/mihomo/whitelist.txt" {
			t.Errorf("WhitelistFile default = %q, want /etc/5gpn/mihomo/whitelist.txt", cfg.WhitelistFile)
		}
	})

	t.Run("overrides", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")
		t.Setenv("DNS_BASE_DOMAIN", "5gpn.example.com")
		t.Setenv("DNS_MIHOMO_CONTROLLER", "127.0.0.1:9999")
		t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
		t.Setenv("DNS_WHITELIST_FILE", "/opt/5gpn/whitelist.txt")

		cfg, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		if cfg.BaseDomain != "5gpn.example.com" {
			t.Errorf("BaseDomain = %q, want 5gpn.example.com", cfg.BaseDomain)
		}
		if cfg.DotDomain != "dot.5gpn.example.com" {
			t.Errorf("DotDomain = %q, want dot.5gpn.example.com", cfg.DotDomain)
		}
		if cfg.ConsoleDomain != "console.5gpn.example.com" {
			t.Errorf("ConsoleDomain = %q, want console.5gpn.example.com", cfg.ConsoleDomain)
		}
		if cfg.ZashDomain != "zash.5gpn.example.com" {
			t.Errorf("ZashDomain = %q, want zash.5gpn.example.com", cfg.ZashDomain)
		}
		if cfg.MihomoController != "127.0.0.1:9999" {
			t.Errorf("MihomoController = %q, want 127.0.0.1:9999", cfg.MihomoController)
		}
		if cfg.MihomoSecret != "s3cr3t" {
			t.Errorf("MihomoSecret = %q, want s3cr3t", cfg.MihomoSecret)
		}
		if cfg.WhitelistFile != "/opt/5gpn/whitelist.txt" {
			t.Errorf("WhitelistFile = %q, want /opt/5gpn/whitelist.txt", cfg.WhitelistFile)
		}
	})

}

func TestLoadConfigRejectsOutOfRangeUpstreamPorts(t *testing.T) {
	for _, tc := range []struct {
		key, value string
	}{
		{"DNS_CHINA", "223.5.5.5:0"},
		{"DNS_TRUST", "1.1.1.1:99999"},
		{"DNS_CHINA", "[2001:db8::1]:53"},
		{"DNS_TRUST", "dns.example@[2001:db8::1]:853"},
	} {
		t.Run(tc.key, func(t *testing.T) {
			clearAllDNSEnv(t)
			t.Setenv("DNS_CERT", "/c")
			t.Setenv("DNS_KEY", "/k")
			t.Setenv(tc.key, tc.value)
			if _, err := LoadConfig(); !errors.Is(err, ErrInvalidUpstream) {
				t.Fatalf("LoadConfig error = %v, want ErrInvalidUpstream", err)
			}
		})
	}
}

func TestLoadConfigRejectsUnsafeListenerBindings(t *testing.T) {
	for _, tc := range []struct {
		key, value string
	}{
		{"DNS_LISTEN_DEBUG", "0.0.0.0:5353"},
		{"DNS_LISTEN_API", "192.0.2.10:443"},
		{"DNS_ZASH_LISTEN", "[::1]:443"},
		{"DNS_LISTEN_DOT", ":8853"},
	} {
		t.Run(tc.key, func(t *testing.T) {
			clearAllDNSEnv(t)
			t.Setenv("DNS_LISTEN_DOT", "")
			t.Setenv(tc.key, tc.value)
			if _, err := LoadConfig(); err == nil {
				t.Fatalf("LoadConfig accepted %s=%q", tc.key, tc.value)
			}
		})
	}
}

func TestLoadConfigRejectsIPv6Gateway(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_LISTEN_DOT", "")
	t.Setenv("DNS_GATEWAY_IP", "2001:db8::1")
	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig accepted an IPv6 gateway in the IPv4 architecture")
	}
}

func TestLoadConfigBoundsNumericKnobs(t *testing.T) {
	for _, tc := range []struct {
		key, value string
		check      func(Config) bool
	}{
		{"DNS_CACHE_SIZE", "1000000000", func(c Config) bool { return c.CacheSize == 4096 }},
		{"DNS_MAX_INFLIGHT", "1000000000", func(c Config) bool { return c.MaxInflight == 4096 }},
		{"DNS_TTL_MAX", "9223372036854775807", func(c Config) bool { return c.TTLMax == 86400*time.Second }},
		{"DNS_QUERY_TIMEOUT", "0s", func(c Config) bool { return c.QueryTimeout == 5*time.Second }},
		{"DNS_HEARTBEAT_INTERVAL", "1ms", func(c Config) bool { return c.HeartbeatInterval == 60*time.Second }},
		{"DNS_API_RATE", "NaN", func(c Config) bool { return c.APIRate == 20 }},
		{"DNS_API_RATE", "+Inf", func(c Config) bool { return c.APIRate == 20 }},
		{"DNS_API_BURST", "1000000000", func(c Config) bool { return c.APIBurst == 40 }},
	} {
		t.Run(tc.key+"="+tc.value, func(t *testing.T) {
			clearAllDNSEnv(t)
			t.Setenv("DNS_LISTEN_DOT", "")
			t.Setenv(tc.key, tc.value)
			cfg, err := LoadConfig()
			if err != nil {
				t.Fatal(err)
			}
			if !tc.check(cfg) {
				t.Fatalf("%s=%q was not bounded: %+v", tc.key, tc.value, cfg)
			}
		})
	}
}

func TestLoadConfigRepairsInvertedTTLRange(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_LISTEN_DOT", "")
	t.Setenv("DNS_TTL_MIN", "3600")
	t.Setenv("DNS_TTL_MAX", "60")
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TTLMin != 300*time.Second || cfg.TTLMax != 86400*time.Second {
		t.Fatalf("TTL range = %s..%s, want defaults", cfg.TTLMin, cfg.TTLMax)
	}
}

// The raw-config editor file knob follows the standard envOr-default pattern.
func TestLoadConfig_MihomoConfigFileKnob(t *testing.T) {
	t.Run("defaults", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")

		cfg, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		if cfg.MihomoConfigFile != "/etc/5gpn/mihomo/config.yaml" {
			t.Errorf("MihomoConfigFile default = %q, want /etc/5gpn/mihomo/config.yaml", cfg.MihomoConfigFile)
		}
		if cfg.InterceptConfigFile != "/etc/5gpn/intercept/config.json" {
			t.Errorf("InterceptConfigFile default = %q", cfg.InterceptConfigFile)
		}
		if cfg.MarketplacesFile != "/etc/5gpn/extension-marketplaces.json" {
			t.Errorf("MarketplacesFile default = %q", cfg.MarketplacesFile)
		}
	})

	t.Run("override", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")
		t.Setenv("DNS_MIHOMO_CONFIG", "/opt/5gpn/mihomo/config.yaml")

		cfg, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		if cfg.MihomoConfigFile != "/opt/5gpn/mihomo/config.yaml" {
			t.Errorf("MihomoConfigFile = %q, want /opt/5gpn/mihomo/config.yaml", cfg.MihomoConfigFile)
		}
	})

	t.Run("reject interception path override", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")
		t.Setenv("DNS_INTERCEPT_CONFIG", "/opt/5gpn/intercept/config.json")
		if _, err := LoadConfig(); err == nil {
			t.Fatal("LoadConfig accepted a non-canonical interception config path")
		}
	})

	t.Run("reject marketplace path override", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")
		t.Setenv("DNS_MARKETPLACES_FILE", "/opt/5gpn/extension-marketplaces.json")
		if _, err := LoadConfig(); err == nil {
			t.Fatal("LoadConfig accepted a non-canonical marketplace config path")
		}
	})
}

func TestLoadConfig_ZashDefaults(t *testing.T) {
	t.Run("defaults", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")

		cfg, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		if cfg.ZashDir != "/opt/5gpn/zash" {
			t.Errorf("ZashDir default = %q, want /opt/5gpn/zash", cfg.ZashDir)
		}
		if cfg.ZashListen != "127.0.0.2:443" {
			t.Errorf("ZashListen default = %q, want 127.0.0.2:443", cfg.ZashListen)
		}
		if cfg.ZashCertFile != "" || cfg.ZashKeyFile != "" {
			t.Errorf("ZashCertFile/KeyFile = %q/%q, want explicit empty defaults", cfg.ZashCertFile, cfg.ZashKeyFile)
		}
	})

	t.Run("overrides", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")
		t.Setenv("DNS_ZASH_DIR", "/opt/5gpn/custom-zash")
		t.Setenv("DNS_ZASH_LISTEN", "127.0.0.2:10443")

		cfg, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		if cfg.ZashDir != "/opt/5gpn/custom-zash" {
			t.Errorf("ZashDir = %q, want /opt/5gpn/custom-zash", cfg.ZashDir)
		}
		if cfg.ZashListen != "127.0.0.2:10443" {
			t.Errorf("ZashListen = %q, want 127.0.0.2:10443", cfg.ZashListen)
		}
	})
}

func TestLoadConfig_ZashCertExplicit(t *testing.T) {
	t.Run("explicit zash cert", func(t *testing.T) {
		clearAllDNSEnv(t)
		t.Setenv("DNS_CERT", "/c")
		t.Setenv("DNS_KEY", "/k")
		t.Setenv("DNS_WEB_CERT", "/etc/5gpn/cert/web/current/fullchain.pem")
		t.Setenv("DNS_WEB_KEY", "/etc/5gpn/cert/web/current/privkey.pem")
		t.Setenv("DNS_ZASH_CERT", "/etc/5gpn/cert/zash/current/fullchain.pem")
		t.Setenv("DNS_ZASH_KEY", "/etc/5gpn/cert/zash/current/privkey.pem")

		cfg, err := LoadConfig()
		if err != nil {
			t.Fatalf("LoadConfig: %v", err)
		}
		if cfg.ZashCertFile != "/etc/5gpn/cert/zash/current/fullchain.pem" || cfg.ZashKeyFile != "/etc/5gpn/cert/zash/current/privkey.pem" {
			t.Errorf("ZashCertFile/KeyFile = %q/%q, want explicit override", cfg.ZashCertFile, cfg.ZashKeyFile)
		}
	})
}
