package main

import (
	"os"
	"testing"
	"time"
)

// allDNSEnvKeys is the complete list of env vars read by LoadConfig.
var allDNSEnvKeys = []string{
	"DNS_LISTEN_DOT", "DNS_LISTEN_DOH", "DNS_LISTEN_PLAIN", "DNS_LISTEN_DEBUG",
	"DNS_CERT", "DNS_KEY", "DNS_GATEWAY_IP",
	"DNS_CHINA", "DNS_TRUST", "DNS_RULES_DIR", "DNS_CHNROUTE",
	"DNS_CACHE_SIZE", "DNS_TTL_MIN", "DNS_TTL_MAX", "DNS_QUERY_TIMEOUT",
	"DNS_SUBSCRIPTIONS",
	"DNS_LISTEN_API", "DNS_API_TOKEN",
	"DNS_STATS_FILE",
	"DNS_API_RATE", "DNS_API_BURST",
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
	// because the defaults enable TLS listeners (:853 / :8443).
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}

	// Default listeners (from spec §13).
	if cfg.ListenDoT != ":853" {
		t.Errorf("ListenDoT default = %q, want %q", cfg.ListenDoT, ":853")
	}
	if cfg.ListenDoH != ":8443" {
		t.Errorf("ListenDoH default = %q, want %q", cfg.ListenDoH, ":8443")
	}
	if cfg.ListenPlain != ":53" {
		t.Errorf("ListenPlain default = %q, want %q", cfg.ListenPlain, ":53")
	}
	if cfg.ListenDebug != "127.0.0.1:5353" {
		t.Errorf("ListenDebug default = %q, want %q", cfg.ListenDebug, "127.0.0.1:5353")
	}

	// Default upstream lists.
	wantChina := []string{"223.5.5.5", "119.29.29.29"}
	if len(cfg.ChinaAddrs) != len(wantChina) {
		t.Errorf("ChinaAddrs len = %d, want %d", len(cfg.ChinaAddrs), len(wantChina))
	} else {
		for i, a := range cfg.ChinaAddrs {
			if a != wantChina[i] {
				t.Errorf("ChinaAddrs[%d] = %q, want %q", i, a, wantChina[i])
			}
		}
	}

	wantTrust := []TrustEntry{
		{ServerName: "dns.google", DialAddr: "8.8.8.8"},
		{ServerName: "one.one.one.one", DialAddr: "1.1.1.1"},
	}
	if len(cfg.TrustEntries) != len(wantTrust) {
		t.Fatalf("TrustEntries len = %d, want %d", len(cfg.TrustEntries), len(wantTrust))
	}
	for i, te := range cfg.TrustEntries {
		if te.ServerName != wantTrust[i].ServerName || te.DialAddr != wantTrust[i].DialAddr {
			t.Errorf("TrustEntries[%d] = %+v, want %+v", i, te, wantTrust[i])
		}
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

	// Default control-plane API listener; token has no default (empty).
	if cfg.ListenAPI != ":9443" {
		t.Errorf("ListenAPI default = %q, want %q", cfg.ListenAPI, ":9443")
	}
	if cfg.APIToken != "" {
		t.Errorf("APIToken default = %q, want empty", cfg.APIToken)
	}

	// Default stats persistence file (Phase 4 Task A2).
	if cfg.StatsFile != "/etc/5gpn/stats.json" {
		t.Errorf("StatsFile default = %q, want %q", cfg.StatsFile, "/etc/5gpn/stats.json")
	}

	// Default control-plane API rate limit (Phase 4 Task C1).
	if cfg.APIRate != 20 {
		t.Errorf("APIRate default = %v, want 20", cfg.APIRate)
	}
	if cfg.APIBurst != 40 {
		t.Errorf("APIBurst default = %d, want 40", cfg.APIBurst)
	}
}

func TestLoadConfig_EnvOverride(t *testing.T) {
	clearAllDNSEnv(t)

	// Disable TLS listeners so no cert required.
	t.Setenv("DNS_LISTEN_DOT", "")
	t.Setenv("DNS_LISTEN_DOH", "")
	t.Setenv("DNS_LISTEN_PLAIN", ":1053")
	t.Setenv("DNS_LISTEN_DEBUG", "")
	t.Setenv("DNS_GATEWAY_IP", "10.0.0.1")
	t.Setenv("DNS_CHINA", "8.8.8.8")
	t.Setenv("DNS_TRUST", "dns.google@8.8.8.8,one.one.one.one@1.1.1.1")
	t.Setenv("DNS_TTL_MIN", "60")
	t.Setenv("DNS_TTL_MAX", "3600")
	t.Setenv("DNS_QUERY_TIMEOUT", "3s")
	t.Setenv("DNS_CACHE_SIZE", "512")
	t.Setenv("DNS_SUBSCRIPTIONS", "/opt/5gpn/subs.json")
	t.Setenv("DNS_LISTEN_API", ":9444")
	t.Setenv("DNS_API_TOKEN", "s3cr3t")
	t.Setenv("DNS_STATS_FILE", "/opt/5gpn/stats.json")
	t.Setenv("DNS_API_RATE", "5")
	t.Setenv("DNS_API_BURST", "10")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig() unexpected error: %v", err)
	}

	if cfg.ListenDoT != "" {
		t.Errorf("ListenDoT = %q, want empty (disabled)", cfg.ListenDoT)
	}
	if cfg.ListenPlain != ":1053" {
		t.Errorf("ListenPlain = %q, want %q", cfg.ListenPlain, ":1053")
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
	if cfg.ListenAPI != ":9444" {
		t.Errorf("ListenAPI = %q, want %q", cfg.ListenAPI, ":9444")
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
	if cfg.ListenAPI != ":9443" {
		t.Errorf("ListenAPI = %q, want %q", cfg.ListenAPI, ":9443")
	}
}

func TestLoadConfig_TLSRequired_DoT(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_LISTEN_DOT", ":853")
	t.Setenv("DNS_LISTEN_DOH", "") // disable DoH to isolate
	// DNS_CERT and DNS_KEY remain empty.

	_, err := LoadConfig()
	if err == nil {
		t.Fatal("expected error when DoT enabled but CERT/KEY missing, got nil")
	}
}

func TestLoadConfig_TLSRequired_DoH(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_LISTEN_DOT", "")
	t.Setenv("DNS_LISTEN_DOH", ":8443")
	// DNS_CERT and DNS_KEY remain empty.

	_, err := LoadConfig()
	if err == nil {
		t.Fatal("expected error when DoH enabled but CERT/KEY missing, got nil")
	}
}

func TestLoadConfig_TLSNotRequired_NoTLSListeners(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_LISTEN_DOT", "")
	t.Setenv("DNS_LISTEN_DOH", "")
	t.Setenv("DNS_LISTEN_PLAIN", ":53")
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

func TestParseTrustEntries(t *testing.T) {
	tests := []struct {
		input string
		want  []TrustEntry
	}{
		{
			input: "dns.google@8.8.8.8",
			want:  []TrustEntry{{ServerName: "dns.google", DialAddr: "8.8.8.8"}},
		},
		{
			input: "1.1.1.1",
			want:  []TrustEntry{{ServerName: "1.1.1.1", DialAddr: "1.1.1.1"}},
		},
		{
			input: "dns.google@8.8.8.8,one.one.one.one@1.1.1.1",
			want: []TrustEntry{
				{ServerName: "dns.google", DialAddr: "8.8.8.8"},
				{ServerName: "one.one.one.one", DialAddr: "1.1.1.1"},
			},
		},
	}
	for _, tc := range tests {
		got := parseTrustEntries(tc.input)
		if len(got) != len(tc.want) {
			t.Errorf("parseTrustEntries(%q): len=%d, want %d", tc.input, len(got), len(tc.want))
			continue
		}
		for i, te := range got {
			if te != tc.want[i] {
				t.Errorf("parseTrustEntries(%q)[%d] = %+v, want %+v", tc.input, i, te, tc.want[i])
			}
		}
	}
}
