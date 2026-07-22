package main

import (
	"errors"
	"fmt"
	"log"
	"math"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultChinaUpstreams = "223.5.5.5"
	defaultTrustUpstreams = "22.22.22.22"
	defaultChinaECS       = "112.96.32.0/24"
)

const (
	maxCacheEntries       = 1_000_000
	maxInflightQueries    = 65_536
	maxConfiguredTTL      = 30 * 24 * time.Hour
	minQueryTimeout       = 100 * time.Millisecond
	maxQueryTimeout       = time.Minute
	minHeartbeatInterval  = 10 * time.Second
	maxHeartbeatInterval  = 24 * time.Hour
	maxConfiguredAPIRate  = 100_000
	maxConfiguredAPIBurst = 10_000
)

// TrustEntry describes a single trust upstream. Two spec forms:
//
//   - "serverName@dialIP" → DoT: TLS-verified against ServerName, dialed at
//     DialAddr (port 853 default).
//   - bare "IP" → plain UDP (Plain=true, port 53 default): a trusted internal
//     resolver reachable over a clean path (e.g. the 22.22.22.22 default),
//     where demanding a DoT certificate would just break resolution.
type TrustEntry struct {
	ServerName string // TLS SNI / cert verification name (DoT entries only)
	DialAddr   string // host (or host:port) to dial
	Plain      bool   // true → plain UDP :53; false → DoT :853
}

// Config holds the resolved configuration for 5gpn-dns.
type Config struct {
	// Listener addresses.  An empty string means the listener is disabled.
	// DoT is the ONLY client-facing DNS transport; ListenDebug is a loopback-only plain-UDP listener kept for
	// on-box troubleshooting (dig @127.0.0.1 -p 5353), never public.
	ListenDoT   string // default :853   (TLS)
	ListenDebug string // default 127.0.0.1:5353 (plain UDP, debug)

	// TLS certificate files for the DoT listener (the DoT domain's cert).
	CertFile string
	KeyFile  string

	// TLS certificate files for the web console role.
	WebCertFile string
	WebKeyFile  string

	// Networking.
	GatewayIP    net.IP       // foreign-address rewrite target
	ChinaAddrs   []string     // UDP upstream addresses (no port → :53 appended later)
	TrustEntries []TrustEntry // trust upstream entries (bare IP=UDP, host@IP=DoT)
	TrustRaw     []string     // the raw trust specs (for display/persistence)

	// UpstreamsFile is the runtime upstream-override file (env DNS_UPSTREAMS,
	// default /etc/5gpn/upstreams.json). Written by the web console via
	// PUT /api/upstreams; when present at startup its china/trust lists
	// override DNS_CHINA/DNS_TRUST. It lives beside subscriptions.json in the
	// daemon-writable part of /etc/5gpn — dns.env stays read-only to the
	// sandboxed daemon. Empty disables both the override and persistence.
	UpstreamsFile string

	// ChinaECS is the EDNS Client Subnet (RFC 7871) attached to china-group
	// queries so CN CDNs schedule answers near the CLIENTS' cellular egress
	// instead of near the gateway's own IP (env DNS_CHINA_ECS; empty or
	// "off"/"none" disables; a bare IPv4 is normalised to its /24). nil disables
	// ECS. The web console overrides it at runtime via
	// PUT /api/ecs, persisted to EcsFile (which wins over this at startup).
	ChinaECS *net.IPNet

	// EcsFile is the runtime ECS-override file (env DNS_ECS_FILE, default
	// /etc/5gpn/ecs.json). Written by the web console via PUT /api/ecs; when
	// present at startup its subnet overrides DNS_CHINA_ECS. Lives beside
	// subscriptions.json in the daemon-writable part of /etc/5gpn (dns.env is
	// read-only to the sandboxed daemon). Empty disables override+persistence.
	EcsFile string

	// China0x20 enables DNS 0x20 anti-spoof encoding on the plaintext-UDP china
	// group (env DNS_CHINA_0X20; default true). A startup self-probe
	// (StartChina0x20Probe) auto-disables it if a configured china upstream is
	// confirmed to normalise query-name case, so the default-on posture cannot
	// degrade CN resolution even against a normalising resolver.
	China0x20 bool

	// Rule file locations.
	RulesDir     string // directory containing subscription caches and chnroute
	ChnrouteFile string // path to china IP CIDR list

	// Subscriptions.
	SubscriptionsFile string // path to subscriptions.json

	// Control-plane API + web console.
	ListenAPI string // default 127.0.0.1:443 (TLS); control plane is disabled unless APIToken is set
	APIToken  string // bearer token for /api/*; no default — empty means disabled

	// Per-source rate limiting on the control-plane API.
	APIRate  float64 // requests/sec allowed per source IP; <= 0 disables rate limiting
	APIBurst int     // token-bucket capacity per source IP

	// Query-stat counter persistence.
	StatsFile string // path for cumulative stats snapshot; empty disables persistence

	// In-process Telegram bot.
	TGBotToken  string         // env TGBOT_TOKEN; empty ⇒ bot disabled
	TGBotAdmins map[int64]bool // env TGBOT_ADMINS; comma/space-separated int64 admin IDs
	// TGBotProxyURL is an optional HTTP/HTTPS CONNECT proxy used only for
	// Telegram Bot API traffic (env TGBOT_PROXY_URL). It lets an operator route
	// the bot through an explicitly configured loopback mihomo mixed/HTTP
	// listener without changing any other daemon egress. The installer never
	// mutates operator-owned mihomo config to create that listener.
	TGBotProxyURL string
	// TGBotAlerts enables transition-based Telegram notifications to configured
	// admins (env TGBOT_ALERTS, default false). It is opt-in because a bot can
	// message an admin only after that user has opened the private chat.
	TGBotAlerts bool
	// TGBotFile is the runtime tgbot-override file (env DNS_TGBOT_FILE, default
	// /etc/5gpn/tgbot.json). When present it overrides TGBOT_TOKEN/TGBOT_ADMINS
	// at startup and is rewritten by PUT /api/tgbot (web-console managed), so the
	// bot token + admin set can be changed without editing the read-only dns.env.
	TGBotFile string

	// The operator's base domain (env DNS_BASE_DOMAIN) and its derived service
	// names. DNS_BASE_DOMAIN is the only hostname identity read from the
	// environment.
	BaseDomain    string
	DotDomain     string
	ConsoleDomain string
	ZashDomain    string

	// MihomoController is mihomo's loopback external-controller API address
	// (env DNS_MIHOMO_CONTROLLER, default 127.0.0.1:9090) and MihomoSecret is
	// its bearer secret (env DNS_MIHOMO_SECRET). install.sh generates the
	// controller secret, seds it into the rendered mihomo config.yaml, AND
	// persists it to DNS_MIHOMO_SECRET (write_dns_env / set_dns_env_kv), so this
	// knob carries the REAL secret at runtime: it authenticates BOTH the daemon's
	// own MihomoClient (apply calls) and the browser-facing /proxy/ reverse-proxy
	// against the same controller. Installer-side controller calls use the same
	// secret through mihomo_controller_curl. WhitelistFile is the panel source-IP
	// allowlist mihomo's rule-provider reloads from (env DNS_WHITELIST_FILE,
	// default /etc/5gpn/mihomo/whitelist.txt).
	MihomoController string
	MihomoSecret     string
	WhitelistFile    string

	// MihomoConfigFile is the mihomo config the console's raw editor reads
	// and writes (env DNS_MIHOMO_CONFIG, default /etc/5gpn/mihomo/config.yaml)
	// — install.sh renders the initial seed (etc/mihomo/config.yaml.tmpl); the
	// daemon validates (`mihomo -t`) and hot-applies every subsequent PUT/reset
	// via api_mihomo_config.go, but owns no region of it.
	MihomoConfigFile string
	// InterceptConfigFile is the modular sidecar document managed by the
	// authenticated module API. It never contains a CA private key.
	InterceptConfigFile string
	// MarketplacesFile is the authenticated extension marketplace source
	// document. It is separate from the immutable extension snapshots.
	MarketplacesFile string

	// PolicyRulesFile is the console-managed plain-JSON rule list (env
	// DNS_POLICY_RULES, default /etc/5gpn/policy.json). An explicit empty value disables the store
	// (matches UpstreamsFile's envListen convention).
	PolicyRulesFile string

	// ZashDir is the unzipped zashboard dist
	// (env DNS_ZASH_DIR, default /opt/5gpn/zash) served by a SECOND loopback
	// HTTPS panel on ZashListen (env DNS_ZASH_LISTEN, default 127.0.0.2:443).
	ZashDir      string
	ZashListen   string
	ZashCertFile string
	ZashKeyFile  string

	// iOS DoT-profile distribution: the .mobileconfig under WWWDir is served by
	// the control server at the public (token-free) /ios/ path.
	WWWDir string // env WWW_DIR; default /opt/5gpn/www; profile root
	WebDir string // env DNS_WEB_DIR; default /opt/5gpn/web; control-console SPA static root

	// Cache.
	CacheSize int // max entries (0 → use default 4096)

	// Admission control: max concurrent in-flight resolutions. 0 disables
	// shedding (unbounded, the pre-#1 behaviour). env DNS_MAX_INFLIGHT.
	MaxInflight int

	// TTL clamping.
	TTLMin time.Duration
	TTLMax time.Duration

	// Per-query upstream timeout.
	QueryTimeout time.Duration

	// Outbound liveness heartbeat (dead-man's switch). When HeartbeatURL is set,
	// the daemon GETs it every HeartbeatInterval while alive; an external monitor
	// (healthchecks.io, Uptime Kuma push, self-hosted) alerts when the pings STOP
	// — the one signal that survives a box-down / crash-loop, which the CLIENT_NET-
	// only control plane and the die-with-the-daemon bot cannot report. Empty
	// disables it. env DNS_HEARTBEAT_URL / DNS_HEARTBEAT_INTERVAL (default 60s).
	HeartbeatURL      string
	HeartbeatInterval time.Duration

	// EgressBrokerAddr is mihomo's loopback DNS resolver for sniffed origins
	// (env DNS_EGRESS_BROKER, default 127.0.0.1:5354).
	// It must be a loopback IPv4 literal — LoadConfig rejects a routable
	// address, an IPv6 literal (this architecture has no IPv6 support yet),
	// or a bare hostname (the invariant must be checkable without a DNS
	// lookup at config-load time). The boundary is required and cannot be empty.
	EgressBrokerAddr string
}

// LoadConfig reads DNS_* environment variables and returns a validated Config.
//
// Defaults:
//
//	DNS_LISTEN_DOT      :853
//	DNS_LISTEN_DEBUG    127.0.0.1:5353
//	DNS_CHINA           223.5.5.5  (plain UDP)
//	DNS_TRUST           22.22.22.22  (bare IP=plain UDP; "host@IP"=DoT)
//	DNS_UPSTREAMS       /etc/5gpn/upstreams.json (web-console override; empty disables)
//	DNS_CHINA_ECS       112.96.32.0/24 (china-group EDNS Client Subnet; empty or "off" disables)
//	DNS_ECS_FILE        /etc/5gpn/ecs.json (web-console ECS override; empty disables)
//	DNS_RULES_DIR       /etc/5gpn/rules
//	DNS_CACHE_SIZE      4096
//	DNS_MAX_INFLIGHT    4096  (0 disables admission control)
//	DNS_TTL_MIN         300  (seconds)
//	DNS_TTL_MAX         86400 (seconds)
//	DNS_QUERY_TIMEOUT   5s
//	DNS_SUBSCRIPTIONS   /etc/5gpn/subscriptions.json
//	DNS_LISTEN_API      127.0.0.1:443
//	DNS_API_TOKEN       (none — control plane disabled unless set)
//	DNS_WEB_CERT/_KEY   (required when the control plane is enabled)
//	DNS_STATS_FILE      /etc/5gpn/stats.json (empty disables persistence)
//	DNS_API_RATE        20 (requests/sec per source IP; <= 0 disables rate limiting)
//	DNS_API_BURST       40 (token-bucket capacity per source IP)
//	TGBOT_PROXY_URL     (none — optional HTTP/HTTPS CONNECT proxy for Telegram only)
//	TGBOT_ALERTS        false (notify admins on cert/mihomo/upstream transitions)
//	WWW_DIR             /opt/5gpn/www (signed-profile root for the /ios/ download path)
//	DNS_WEB_DIR         /opt/5gpn/web (control-console SPA static root)
//	DNS_EGRESS_BROKER   127.0.0.1:5354 (mihomo sniffed-origin DNS resolver)
//	DNS_MIHOMO_CONTROLLER 127.0.0.1:9090 (mihomo's loopback external-controller API)
//	DNS_MIHOMO_SECRET   (none — mihomo controller bearer secret)
//	DNS_WHITELIST_FILE  /etc/5gpn/mihomo/whitelist.txt (panel source-IP allowlist)
//	DNS_BASE_DOMAIN     (none — dot/console/zash names derive from it)
//	DNS_MIHOMO_CONFIG   /etc/5gpn/mihomo/config.yaml (operator-owned mihomo config; console raw editor)
//	DNS_INTERCEPT_CONFIG /etc/5gpn/intercept/config.json (allowlisted module sidecar config)
//	DNS_MARKETPLACES_FILE /etc/5gpn/extension-marketplaces.json (extension marketplace sources)
//	DNS_POLICY_RULES    /etc/5gpn/policy.json (unified policy-rule model; plain JSON, public subscription URLs; empty disables)
//	DNS_ZASH_DIR        /opt/5gpn/zash (unzipped zashboard dist, served by the zash panel)
//	DNS_ZASH_LISTEN     127.0.0.2:443 (second loopback HTTPS listener for the zash panel)
//	DNS_ZASH_CERT/_KEY  (required when the zashboard listener is enabled)
//
// Empty listener strings disable that server.
// If the DoT listener has a non-empty address, DNS_CERT and DNS_KEY must also
// be non-empty, or an error is returned.
func LoadConfig() (Config, error) {
	if _, exists := os.LookupEnv("DNS_EGRESS_RESOLVER"); exists {
		return Config{}, errors.New("config: pre-v5 DNS_EGRESS_RESOLVER is retired; disable the old MITM master, then perform the documented credential-preserving v4-to-v5 rebuild before removing that exact key")
	}
	cfg := Config{
		ListenDoT:           envListen("DNS_LISTEN_DOT", ":853"),
		ListenDebug:         envListen("DNS_LISTEN_DEBUG", "127.0.0.1:5353"),
		CertFile:            os.Getenv("DNS_CERT"),
		KeyFile:             os.Getenv("DNS_KEY"),
		WebCertFile:         os.Getenv("DNS_WEB_CERT"),
		WebKeyFile:          os.Getenv("DNS_WEB_KEY"),
		RulesDir:            envOr("DNS_RULES_DIR", "/etc/5gpn/rules"),
		ChnrouteFile:        os.Getenv("DNS_CHNROUTE"),
		SubscriptionsFile:   envOr("DNS_SUBSCRIPTIONS", "/etc/5gpn/subscriptions.json"),
		ListenAPI:           envListen("DNS_LISTEN_API", "127.0.0.1:443"),
		APIToken:            os.Getenv("DNS_API_TOKEN"),
		StatsFile:           envListen("DNS_STATS_FILE", "/etc/5gpn/stats.json"),
		TGBotToken:          os.Getenv("TGBOT_TOKEN"),
		TGBotAdmins:         parseAdminIDs(os.Getenv("TGBOT_ADMINS")),
		TGBotProxyURL:       strings.TrimSpace(os.Getenv("TGBOT_PROXY_URL")),
		TGBotAlerts:         envBool("TGBOT_ALERTS", false),
		WWWDir:              envOr("WWW_DIR", "/opt/5gpn/www"),
		WebDir:              envOr("DNS_WEB_DIR", "/opt/5gpn/web"),
		BaseDomain:          envOr("DNS_BASE_DOMAIN", ""),
		MihomoController:    envOr("DNS_MIHOMO_CONTROLLER", "127.0.0.1:9090"),
		MihomoSecret:        envOr("DNS_MIHOMO_SECRET", ""),
		WhitelistFile:       envOr("DNS_WHITELIST_FILE", "/etc/5gpn/mihomo/whitelist.txt"),
		MihomoConfigFile:    envOr("DNS_MIHOMO_CONFIG", "/etc/5gpn/mihomo/config.yaml"),
		InterceptConfigFile: envOr("DNS_INTERCEPT_CONFIG", "/etc/5gpn/intercept/config.json"),
		MarketplacesFile:    envOr("DNS_MARKETPLACES_FILE", "/etc/5gpn/extension-marketplaces.json"),
		PolicyRulesFile:     envListen("DNS_POLICY_RULES", "/etc/5gpn/policy.json"),
		ZashDir:             envOr("DNS_ZASH_DIR", "/opt/5gpn/zash"),
		ZashListen:          envListen("DNS_ZASH_LISTEN", "127.0.0.2:443"),
		ZashCertFile:        os.Getenv("DNS_ZASH_CERT"),
		ZashKeyFile:         os.Getenv("DNS_ZASH_KEY"),
	}
	if err := validateTGBotProxyURL(cfg.TGBotProxyURL); err != nil {
		// The bot is optional. Keep the invalid value so a later runtime token
		// override still fails closed instead of silently bypassing the intended
		// proxy, but disable the bootstrap bot rather than crash-looping DNS.
		log.Printf("config: invalid TGBOT_PROXY_URL; disabling Telegram bot: %v", err)
		cfg.TGBotToken = ""
		cfg.TGBotAdmins = map[int64]bool{}
	}
	if cfg.InterceptConfigFile != "/etc/5gpn/intercept/config.json" {
		return Config{}, fmt.Errorf("DNS_INTERCEPT_CONFIG must be /etc/5gpn/intercept/config.json")
	}
	if cfg.MarketplacesFile != "/etc/5gpn/extension-marketplaces.json" {
		return Config{}, fmt.Errorf("DNS_MARKETPLACES_FILE must be /etc/5gpn/extension-marketplaces.json")
	}
	for key, addr := range map[string]string{
		"DNS_LISTEN_DEBUG": cfg.ListenDebug,
		"DNS_LISTEN_API":   cfg.ListenAPI,
		"DNS_ZASH_LISTEN":  cfg.ZashListen,
	} {
		if addr != "" {
			if err := validateLoopbackIPv4Addr(addr); err != nil {
				return Config{}, fmt.Errorf("config: invalid %s %q: must be loopback IPv4: %w", key, addr, err)
			}
		}
	}
	if cfg.ListenDoT != "" {
		if err := validateDoTAddr(cfg.ListenDoT); err != nil {
			return Config{}, fmt.Errorf("config: invalid DNS_LISTEN_DOT %q: %w", cfg.ListenDoT, err)
		}
	}
	cfg.BaseDomain = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(cfg.BaseDomain)), ".")
	if cfg.BaseDomain != "" {
		if !isValidDomain(cfg.BaseDomain) {
			return Config{}, fmt.Errorf("config: invalid DNS_BASE_DOMAIN %q", cfg.BaseDomain)
		}
		cfg.DotDomain = "dot." + cfg.BaseDomain
		cfg.ConsoleDomain = "console." + cfg.BaseDomain
		cfg.ZashDomain = "zash." + cfg.BaseDomain
	}

	// Gateway IP.
	if raw := os.Getenv("DNS_GATEWAY_IP"); raw != "" {
		ip := net.ParseIP(raw)
		if ip == nil || ip.To4() == nil {
			return Config{}, fmt.Errorf("config: invalid DNS_GATEWAY_IP %q (must be IPv4)", raw)
		}
		cfg.GatewayIP = ip.To4()
	}

	// China upstreams.
	chinaRaw := envOr("DNS_CHINA", defaultChinaUpstreams)
	cfg.ChinaAddrs = splitTrim(chinaRaw)

	// Trust upstreams. Default is 22.22.22.22, queried over plain UDP. Operators
	// can replace it through the web console (Settings → upstream DNS).
	trustRaw := envOr("DNS_TRUST", defaultTrustUpstreams)
	cfg.TrustRaw = splitTrim(trustRaw)
	cfg.TrustEntries = parseTrustEntryList(cfg.TrustRaw)
	if err := ValidateUpstreams(cfg.ChinaAddrs, cfg.TrustRaw); err != nil {
		return Config{}, fmt.Errorf("config: upstreams: %w", err)
	}

	// Runtime upstream-override file (web-console managed).
	cfg.UpstreamsFile = envListen("DNS_UPSTREAMS", "/etc/5gpn/upstreams.json")

	// Runtime tgbot-override file (web-console managed; overrides dns.env's
	// TGBOT_TOKEN/TGBOT_ADMINS at startup, rewritten by PUT /api/tgbot).
	cfg.TGBotFile = envListen("DNS_TGBOT_FILE", "/etc/5gpn/tgbot.json")

	// China-group EDNS Client Subnet. An unset environment uses the operational
	// default; an explicitly empty value or "off" disables it. A typo must never
	// crash-loop the sole resolver, so invalid values degrade to disabled.
	chinaECSRaw, chinaECSSet := os.LookupEnv("DNS_CHINA_ECS")
	if !chinaECSSet {
		chinaECSRaw = defaultChinaECS
	}
	switch raw := strings.ToLower(strings.TrimSpace(chinaECSRaw)); raw {
	case "", "off", "none", "disable", "0":
		cfg.ChinaECS = nil
	default:
		subnet, err := parseECS(raw)
		if err != nil {
			log.Printf("config: invalid DNS_CHINA_ECS %q, disabling ECS", raw)
			subnet = nil
		}
		cfg.ChinaECS = subnet
	}

	// Runtime ECS-override file (web-console managed, like UpstreamsFile).
	cfg.EcsFile = envListen("DNS_ECS_FILE", "/etc/5gpn/ecs.json")

	// China 0x20 anti-spoof (default on; a startup self-probe disables it if an
	// upstream normalises query-name case — see StartChina0x20Probe).
	cfg.China0x20 = envBool("DNS_CHINA_0X20", true)

	// Cache size.
	cfg.CacheSize = envIntOr("DNS_CACHE_SIZE", 4096)

	// Max concurrent in-flight resolutions (admission control). Default 4096; a
	// generous ceiling that only bites under overload, shedding excess with
	// REFUSED instead of letting goroutines/sockets grow to the fd/OOM wall.
	// 0 disables shedding entirely (unbounded).
	cfg.MaxInflight = envIntOr("DNS_MAX_INFLIGHT", 4096)

	// TTL clamping (seconds).
	cfg.TTLMin = envSecondsOr("DNS_TTL_MIN", 300)
	cfg.TTLMax = envSecondsOr("DNS_TTL_MAX", 86400)
	if cfg.TTLMin > cfg.TTLMax {
		log.Printf("config: DNS_TTL_MIN %s exceeds DNS_TTL_MAX %s, using defaults", cfg.TTLMin, cfg.TTLMax)
		cfg.TTLMin = 300 * time.Second
		cfg.TTLMax = 86400 * time.Second
	}

	// Query timeout (Go duration string).
	cfg.QueryTimeout = envDurationOr("DNS_QUERY_TIMEOUT", 5*time.Second)

	// Outbound liveness heartbeat (dead-man's switch; see Config.HeartbeatURL).
	// Only http/https URLs are honoured; anything else is warned + ignored.
	if raw := strings.TrimSpace(os.Getenv("DNS_HEARTBEAT_URL")); raw != "" {
		if err := validateHeartbeatURL(raw); err == nil {
			cfg.HeartbeatURL = raw
		} else {
			log.Printf("config: ignoring invalid DNS_HEARTBEAT_URL: %v", err)
		}
	}
	cfg.HeartbeatInterval = envDurationOr("DNS_HEARTBEAT_INTERVAL", 60*time.Second)

	// Loopback Egress DNS Broker. An explicit
	// empty value is invalid because mihomo depends on this boundary. The host
	// must be a loopback IPv4
	// literal (never IPv6, never a hostname) — see Config.EgressBrokerAddr.
	// Unlike the warn-and-fallback numeric knobs above, a bad value here is
	// FATAL: silently falling back to the default would mask an operator
	// mistake that could otherwise widen the broker onto a routable or
	// public address, which the spec forbids outright.
	brokerRaw := envListen("DNS_EGRESS_BROKER", "127.0.0.1:5354")
	if brokerRaw == "" {
		return Config{}, errors.New("config: DNS_EGRESS_BROKER is required for mihomo origin resolution")
	}
	if err := validateLoopbackIPv4Addr(brokerRaw); err != nil {
		return Config{}, fmt.Errorf("config: invalid DNS_EGRESS_BROKER %q: %w", brokerRaw, err)
	}
	cfg.EgressBrokerAddr = brokerRaw
	// Control-plane API rate limit (requests/sec per source IP). Tolerant
	// parse: a bad value falls back to the default rather than failing
	// LoadConfig outright (matches the other numeric-knob-with-fallback
	// pattern used here, since a malformed rate limit isn't worth crashing
	// the whole daemon over). <= 0 (explicitly, e.g. "0") disables limiting.
	const defaultAPIRate = 20
	cfg.APIRate = defaultAPIRate
	if raw := os.Getenv("DNS_API_RATE"); raw != "" {
		if n, err := strconv.ParseFloat(raw, 64); err == nil && !math.IsNaN(n) && !math.IsInf(n, 0) && n <= maxConfiguredAPIRate {
			cfg.APIRate = n
		} else {
			log.Printf("config: invalid DNS_API_RATE %q, using default %v", raw, defaultAPIRate)
		}
	}

	// Control-plane API token-bucket burst capacity per source IP.
	const defaultAPIBurst = 40
	cfg.APIBurst = defaultAPIBurst
	if raw := os.Getenv("DNS_API_BURST"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n <= maxConfiguredAPIBurst {
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

	// TLS validation: cert+key required when the DoT listener is enabled.
	if cfg.ListenDoT != "" {
		if cfg.CertFile == "" || cfg.KeyFile == "" {
			return Config{}, errors.New("config: DNS_CERT and DNS_KEY are required when the DoT listener is enabled")
		}
	}
	if cfg.APIToken != "" && cfg.ListenAPI != "" {
		if cfg.WebCertFile == "" || cfg.WebKeyFile == "" {
			return Config{}, errors.New("config: DNS_WEB_CERT and DNS_WEB_KEY are required when the control plane is enabled")
		}
		if cfg.ZashListen != "" && (cfg.ZashCertFile == "" || cfg.ZashKeyFile == "") {
			return Config{}, errors.New("config: DNS_ZASH_CERT and DNS_ZASH_KEY are required when the zashboard listener is enabled")
		}
	}

	return cfg, nil
}

// validateTGBotProxyURL accepts only an HTTP(S) forward/CONNECT proxy. SOCKS
// would require another direct dependency and is intentionally unsupported;
// mihomo's mixed-port accepts HTTP CONNECT already. Keeping this parser strict
// also prevents surprising path/query components from being silently ignored
// by net/http's proxy transport.
func validateTGBotProxyURL(raw string) error {
	if raw == "" {
		return nil
	}
	u, err := url.Parse(raw)
	if err != nil {
		return err
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("scheme must be http or https")
	}
	if u.Host == "" {
		return fmt.Errorf("host is required")
	}
	if u.Path != "" && u.Path != "/" {
		return fmt.Errorf("path is not allowed")
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("query and fragment are not allowed")
	}
	return nil
}

func validateHeartbeatURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return errors.New("URL cannot be parsed")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return errors.New("scheme must be http or https")
	}
	if u.Hostname() == "" {
		return errors.New("host is required")
	}
	if u.User != nil {
		return errors.New("userinfo is not allowed")
	}
	return nil
}

func validateDoTAddr(addr string) error {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("must be host:port: %w", err)
	}
	if port != "853" {
		return fmt.Errorf("port must be 853")
	}
	if host == "" {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil {
		return errors.New("host must be an IPv4 literal or empty wildcard")
	}
	return nil
}

// parseTrustEntryList parses trust upstream specs, one per element:
// "serverName@dialAddr" → DoT; bare "IP" → plain UDP (Plain=true).
func parseTrustEntryList(parts []string) []TrustEntry {
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
			// Bare IP (or hostname) — plain UDP to that address.
			entries = append(entries, TrustEntry{
				ServerName: p,
				DialAddr:   p,
				Plain:      true,
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
// separated by commas and/or whitespace (e.g. "111, 222 333"). Blank tokens are
// skipped; a NON-numeric token is skipped WITH a warning, because a typo'd admin
// ID silently dropped would fail-closed and lock the operator out of their own
// (admin-gated) bot with no hint why. Returns a set; an empty/unset input yields
// an empty (non-nil) map.
func parseAdminIDs(raw string) map[int64]bool {
	admins := make(map[int64]bool)
	for _, tok := range strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n' || r == '\r'
	}) {
		id, err := strconv.ParseInt(tok, 10, 64)
		if err != nil {
			log.Printf("warning: TGBOT_ADMINS: ignoring non-numeric admin ID %q (expected a Telegram numeric user ID)", tok)
			continue
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

// envIntOr reads a non-negative integer tuning knob. A malformed or negative
// value logs a warning and returns def rather than failing LoadConfig — a single
// mistyped knob must never crash the network's only resolver into a restart loop
// (this matches the DNS_API_RATE / DNS_API_BURST fallback policy and unifies the
// behaviour across all numeric knobs). An unset/empty value silently uses def.
func envIntOr(key string, def int) int {
	raw := os.Getenv(key)
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	max := maxCacheEntries
	if key == "DNS_MAX_INFLIGHT" {
		max = maxInflightQueries
	}
	if err != nil || n < 0 || n > max {
		log.Printf("config: invalid %s %q, using default %d", key, raw, def)
		return def
	}
	return n
}

// envSecondsOr reads an integer number of seconds as a Duration. A malformed or
// negative value logs a warning and falls back to def seconds (never fatal — see
// envIntOr). An unset/empty value silently uses def.
func envSecondsOr(key string, def int) time.Duration {
	raw := os.Getenv(key)
	if raw == "" {
		return time.Duration(def) * time.Second
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	maxSeconds := int64(maxConfiguredTTL / time.Second)
	if err != nil || n < 0 || n > maxSeconds {
		log.Printf("config: invalid %s %q, using default %ds", key, raw, def)
		return time.Duration(def) * time.Second
	}
	return time.Duration(n) * time.Second
}

// envDurationOr reads a Go duration string (e.g. "5s"). A malformed or negative
// value logs a warning and falls back to def (never fatal — see envIntOr). An
// unset/empty value silently uses def.
func envDurationOr(key string, def time.Duration) time.Duration {
	raw := os.Getenv(key)
	if raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	min, max := time.Duration(0), time.Duration(1<<63-1)
	switch key {
	case "DNS_QUERY_TIMEOUT":
		min, max = minQueryTimeout, maxQueryTimeout
	case "DNS_HEARTBEAT_INTERVAL":
		min, max = minHeartbeatInterval, maxHeartbeatInterval
	}
	if err != nil || d < min || d > max {
		log.Printf("config: invalid %s %q, using default %s", key, raw, def)
		return def
	}
	return d
}

// envBool reads a boolean knob (1/0/true/false/…, per strconv.ParseBool). A
// malformed value logs a warning and returns def (never fatal). An unset/empty
// value silently uses def.
func envBool(key string, def bool) bool {
	raw := os.Getenv(key)
	if raw == "" {
		return def
	}
	b, err := strconv.ParseBool(raw)
	if err != nil {
		log.Printf("config: invalid %s %q, using default %v", key, raw, def)
		return def
	}
	return b
}

// validateLoopbackIPv4Addr checks that addr's host portion is a loopback
// IPv4 literal (e.g. "127.0.0.1", never a hostname and never an IPv6
// literal like "::1"). Used to enforce the Egress DNS Broker's
// loopback-only invariant (design spec section 6.5) at config-load time,
// before any network syscall — a hostname would need a DNS lookup to
// resolve, which this check deliberately avoids.
func validateLoopbackIPv4Host(host string) error {
	ip := net.ParseIP(host)
	if ip == nil {
		return fmt.Errorf("host %q is not an IP literal", host)
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return fmt.Errorf("host %q is not an IPv4 address (IPv6 unsupported)", host)
	}
	if !ip4.IsLoopback() {
		return fmt.Errorf("host %q is not a loopback address (127.0.0.0/8)", host)
	}
	return nil
}

// validateLoopbackIPv4Addr checks that addr's host portion is a loopback
// IPv4 literal (see validateLoopbackIPv4Host) AND that its port is an
// explicit, in-range (1-65535) number — a typo'd or out-of-range port
// should surface as an immediate LoadConfig error the operator sees at
// startup, not a later "address already in use"-style bind failure with no
// hint what went wrong. This full (host+port) check is deliberately used
// only at config-load time: EgressDNSBroker.Start's own defensive re-check
// validates the host only, so a caller-chosen ":0" (OS-assigned ephemeral
// port — the standard Go convention for "any free port", used throughout
// this package's tests) remains a legal listen address to Start even
// though DNS_EGRESS_BROKER itself must always name a real port.
func validateLoopbackIPv4Addr(addr string) error {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("must be host:port (%w)", err)
	}
	if err := validateLoopbackIPv4Host(host); err != nil {
		return err
	}
	port, err := strconv.ParseUint(portStr, 10, 16)
	if err != nil {
		return fmt.Errorf("port %q is invalid: %w", portStr, err)
	}
	if port < 1 {
		return fmt.Errorf("port %q out of range (must be 1-65535)", portStr)
	}
	return nil
}
