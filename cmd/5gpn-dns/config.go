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
	// DoT is the ONLY client-facing DNS transport (DoH/plain-:53 were removed
	// 2026-07-10); ListenDebug is a loopback-only plain-UDP listener kept for
	// on-box troubleshooting (dig @127.0.0.1 -p 5353), never public.
	ListenDoT   string // default :853   (TLS)
	ListenDebug string // default 127.0.0.1:5353 (plain UDP, debug)

	// TLS certificate files for the DoT listener (the DoT domain's cert).
	CertFile string
	KeyFile  string

	// TLS certificate files for the web console / control-plane listener (the
	// WEB domain's cert — a separate certbot lineage from the DoT domain).
	// Empty falls back to CertFile/KeyFile so a single-cert (debug) deployment
	// still works.
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
	// instead of near the gateway's own IP (env DNS_CHINA_ECS; default
	// 122.96.30.0/24; "off"/"none" disables; a bare IPv4 is normalised to its
	// /24). nil disables ECS. The web console overrides it at runtime via
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
	RulesDir     string // directory containing block/direct/blacklist sub-files
	ChnrouteFile string // path to china IP CIDR list

	// Phase 2 subscriptions.
	SubscriptionsFile string // path to subscriptions.json

	// Phase 3 control-plane API + web console.
	ListenAPI string // default 127.0.0.1:443 (TLS); control plane is disabled unless APIToken is set
	APIToken  string // bearer token for /api/*; no default — empty means disabled

	// Phase 4 Task C1: per-source rate limiting on the control-plane API.
	APIRate  float64 // requests/sec allowed per source IP; <= 0 disables rate limiting
	APIBurst int     // token-bucket capacity per source IP

	// Phase 4 Task A2: query-stat counter persistence.
	StatsFile string // path for cumulative stats snapshot; empty disables persistence

	// Phase 5: in-process Telegram bot.
	TGBotToken  string         // env TGBOT_TOKEN; empty ⇒ bot disabled
	TGBotAdmins map[int64]bool // env TGBOT_ADMINS; comma/space-separated int64 admin IDs
	// TGBotFile is the runtime tgbot-override file (env DNS_TGBOT_FILE, default
	// /etc/5gpn/tgbot.json). When present it overrides TGBOT_TOKEN/TGBOT_ADMINS
	// at startup and is rewritten by PUT /api/tgbot (web-console managed), so the
	// bot token + admin set can be changed without editing the read-only dns.env.
	TGBotFile string

	// XrayResolver is the sniffed-origin SNI re-resolver value (env
	// DNS_EGRESS_RESOLVER; back-compat fallback XRAY_RESOLVER, the pre-rename
	// name from the xray era -- an upgraded box's dns.env may still only carry
	// the old key, default 22.22.22.22 placeholder). It is CONSUMED by the
	// daemon: the loopback Egress DNS Broker's legacy fallback exchanger (used
	// when no shadow policy binding is published) queries this resolver with
	// the same semantics the old standalone Xray dns.servers[0] entry used --
	// a plain IPv4 over UDP (TC->TCP fallback) or an https://.../dns-query DoH
	// URL. Validated by ValidateResolver; the 22.22.22.22 sentinel is accepted
	// (non-functional placeholder) so a fresh box still boots. The field name
	// keeps the pre-rename "Xray" spelling for this task; a follow-up rename
	// is tracked separately (see the mihomo migration plan).
	XrayResolver string

	// Mihomo migration: the operator's base wildcard domain (env
	// DNS_BASE_DOMAIN) and the console/zash panel domains derived from it (env
	// DNS_CONSOLE_DOMAIN / DNS_ZASH_DOMAIN). install.sh persists all three, but
	// older configs may only have DNS_BASE_DOMAIN; LoadConfig therefore derives
	// zash.<base> and profile.<base> when those two explicit vars are empty.
	// Empty still means the value isn't known yet (e.g. a box not yet migrated to
	// the base-domain scheme); nothing in this task consumes ConsoleDomain beyond
	// storing it.
	BaseDomain    string
	ConsoleDomain string
	ZashDomain    string
	ProfileDomain string // public profile-only SNI host; defaults to profile.<base>

	// MihomoController is mihomo's loopback external-controller API address
	// (env DNS_MIHOMO_CONTROLLER, default 127.0.0.1:9090) and MihomoSecret is
	// its bearer secret (env DNS_MIHOMO_SECRET). install.sh generates the
	// controller secret, seds it into the rendered mihomo config.yaml, AND
	// persists it to DNS_MIHOMO_SECRET (write_dns_env / set_dns_env_kv), so this
	// knob carries the REAL secret at runtime: it authenticates BOTH the daemon's
	// own MihomoClient (apply calls) and the browser-facing /proxy/ reverse-proxy
	// against the same controller. (The still-open apply_whitelist TODO(Task 6)
	// in install.sh is a separate shell-side item: the TUI whitelist-refresh curl
	// doesn't yet send this secret.) WhitelistFile is the panel source-IP
	// allowlist mihomo's rule-provider reloads from (env DNS_WHITELIST_FILE,
	// default /etc/5gpn/mihomo/whitelist.txt).
	MihomoController string
	MihomoSecret     string
	WhitelistFile    string

	// MihomoConfigFile is the mihomo config the console's raw editor reads
	// and writes (env DNS_MIHOMO_CONFIG, default /etc/5gpn/mihomo/config.yaml)
	// — install.sh renders the initial seed (etc/mihomo/config.yaml.tmpl); the
	// daemon validates (`mihomo -t`) and hot-applies every subsequent PUT/reset
	// via api_mihomo_config.go, but owns no region of it (2026-07-15
	// policy/mihomo decoupling: the former structured egress model's
	// EgressFile/EgressNodesFile fields and the daemon-rendered dynamic tail
	// they backed are gone; this is now the operator's entire, single-source
	// config).
	MihomoConfigFile string

	// UP-1: the unified intent-based policy-rule model (policy_rules.go).
	// PolicyRulesFile is the console-managed plain-JSON rule list (env
	// DNS_POLICY_RULES, default /etc/5gpn/policy.json) — policy subscription
	// URLs are PUBLIC (unlike the former egress node-sub URLs), so this file
	// is plain JSON, never sealed. An explicit empty value disables the store
	// (matches UpstreamsFile's envListen convention).
	PolicyRulesFile string

	// SP-3 zashboard panel: ZashDir is the unzipped Zephyruso/zashboard dist
	// (env DNS_ZASH_DIR, default /opt/5gpn/zash) served by a SECOND loopback
	// HTTPS panel on ZashListen (env DNS_ZASH_LISTEN, default 127.0.0.2:443).
	// ZashCertFile/ZashKeyFile (env DNS_ZASH_CERT/DNS_ZASH_KEY) fall back to the
	// web cert → DoT cert: the one wildcard *.<base> covers console+zash+dot.
	ZashDir      string
	ZashListen   string
	ZashCertFile string
	ZashKeyFile  string

	// iOS DoT-profile distribution: the .mobileconfig under WWWDir is served by
	// the control server at the public (token-free) /ios/ path — there is no
	// separate iOS listener/port anymore (the old :8111 responder was removed).
	WWWDir string // env WWW_DIR; default /opt/5gpn/www; static-file root
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
	// lookup at config-load time). An explicitly-empty value disables the
	// broker, matching every other listener's empty-disables convention.
	EgressBrokerAddr string
}

// LoadConfig reads DNS_* environment variables and returns a validated Config.
//
// Defaults (spec §6 + §13):
//
//	DNS_LISTEN_DOT      :853
//	DNS_LISTEN_DEBUG    127.0.0.1:5353
//	DNS_CHINA           223.5.5.5,119.29.29.29
//	DNS_TRUST           22.22.22.22  (bare IP=plain UDP; "host@IP"=DoT)
//	DNS_UPSTREAMS       /etc/5gpn/upstreams.json (web-console override; empty disables)
//	DNS_CHINA_ECS       122.96.30.0/24 (china-group EDNS Client Subnet; "off" disables)
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
//	DNS_WEB_CERT/_KEY   (empty — fall back to DNS_CERT/DNS_KEY)
//	DNS_STATS_FILE      /etc/5gpn/stats.json (empty disables persistence)
//	DNS_API_RATE        20 (requests/sec per source IP; <= 0 disables rate limiting)
//	DNS_API_BURST       40 (token-bucket capacity per source IP)
//	WWW_DIR             /opt/5gpn/www (static-file root for the /ios/ profile path)
//	DNS_WEB_DIR         /opt/5gpn/web (control-console SPA static root)
//	DNS_EGRESS_BROKER   127.0.0.1:5354 (mihomo sniffed-origin DNS resolver)
//	DNS_MIHOMO_CONTROLLER 127.0.0.1:9090 (mihomo's loopback external-controller API)
//	DNS_MIHOMO_SECRET   (none — mihomo controller bearer secret)
//	DNS_WHITELIST_FILE  /etc/5gpn/mihomo/whitelist.txt (panel source-IP allowlist)
//	DNS_BASE_DOMAIN / DNS_CONSOLE_DOMAIN / DNS_ZASH_DOMAIN / DNS_PROFILE_DOMAIN (none — older configs derive zash/profile from base when empty)
//	DNS_MIHOMO_CONFIG   /etc/5gpn/mihomo/config.yaml (operator-owned mihomo config; console raw editor)
//	DNS_POLICY_RULES    /etc/5gpn/policy.json (unified policy-rule model; plain JSON, public subscription URLs; empty disables)
//	DNS_ZASH_DIR        /opt/5gpn/zash (unzipped zashboard dist, served by the zash panel)
//	DNS_ZASH_LISTEN     127.0.0.2:443 (second loopback HTTPS listener for the zash panel)
//	DNS_ZASH_CERT/_KEY  (empty — fall back to DNS_WEB_CERT/_KEY, then DNS_CERT/DNS_KEY)
//
// Empty listener strings disable that server.
// If the DoT listener has a non-empty address, DNS_CERT and DNS_KEY must also
// be non-empty, or an error is returned.
func LoadConfig() (Config, error) {
	cfg := Config{
		ListenDoT:         envListen("DNS_LISTEN_DOT", ":853"),
		ListenDebug:       envListen("DNS_LISTEN_DEBUG", "127.0.0.1:5353"),
		CertFile:          os.Getenv("DNS_CERT"),
		KeyFile:           os.Getenv("DNS_KEY"),
		WebCertFile:       os.Getenv("DNS_WEB_CERT"),
		WebKeyFile:        os.Getenv("DNS_WEB_KEY"),
		RulesDir:          envOr("DNS_RULES_DIR", "/etc/5gpn/rules"),
		ChnrouteFile:      os.Getenv("DNS_CHNROUTE"),
		SubscriptionsFile: envOr("DNS_SUBSCRIPTIONS", "/etc/5gpn/subscriptions.json"),
		ListenAPI:         envListen("DNS_LISTEN_API", "127.0.0.1:443"),
		APIToken:          os.Getenv("DNS_API_TOKEN"),
		StatsFile:         envListen("DNS_STATS_FILE", "/etc/5gpn/stats.json"),
		TGBotToken:        os.Getenv("TGBOT_TOKEN"),
		TGBotAdmins:       parseAdminIDs(os.Getenv("TGBOT_ADMINS")),
		WWWDir:            envOr("WWW_DIR", "/opt/5gpn/www"),
		WebDir:            envOr("DNS_WEB_DIR", "/opt/5gpn/web"),
		BaseDomain:        envOr("DNS_BASE_DOMAIN", ""),
		ConsoleDomain:     envOr("DNS_CONSOLE_DOMAIN", ""),
		ZashDomain:        envOr("DNS_ZASH_DOMAIN", ""),
		ProfileDomain:     envOr("DNS_PROFILE_DOMAIN", ""),
		MihomoController:  envOr("DNS_MIHOMO_CONTROLLER", "127.0.0.1:9090"),
		MihomoSecret:      envOr("DNS_MIHOMO_SECRET", ""),
		WhitelistFile:     envOr("DNS_WHITELIST_FILE", "/etc/5gpn/mihomo/whitelist.txt"),
		MihomoConfigFile:  envOr("DNS_MIHOMO_CONFIG", "/etc/5gpn/mihomo/config.yaml"),
		PolicyRulesFile:   envListen("DNS_POLICY_RULES", "/etc/5gpn/policy.json"),
		ZashDir:           envOr("DNS_ZASH_DIR", "/opt/5gpn/zash"),
		ZashListen:        envListen("DNS_ZASH_LISTEN", "127.0.0.2:443"),
		ZashCertFile:      os.Getenv("DNS_ZASH_CERT"),
		ZashKeyFile:       os.Getenv("DNS_ZASH_KEY"),
	}
	trimmedBaseDomain := strings.TrimSuffix(cfg.BaseDomain, ".")
	if cfg.ZashDomain == "" && trimmedBaseDomain != "" {
		cfg.ZashDomain = "zash." + trimmedBaseDomain
	}
	if cfg.ProfileDomain == "" && trimmedBaseDomain != "" {
		cfg.ProfileDomain = "profile." + trimmedBaseDomain
	}
	// Web-console cert falls back to the DoT cert so a single-cert deployment
	// (CERT_MODE=debug, or a dev box) still serves loopback :443.
	if cfg.WebCertFile == "" || cfg.WebKeyFile == "" {
		cfg.WebCertFile = cfg.CertFile
		cfg.WebKeyFile = cfg.KeyFile
	}

	// zash panel cert reuses the web cert (itself already fell back to the DoT
	// cert) — the single wildcard lineage serves all three domains.
	if cfg.ZashCertFile == "" || cfg.ZashKeyFile == "" {
		cfg.ZashCertFile = cfg.WebCertFile
		cfg.ZashKeyFile = cfg.WebKeyFile
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

	// Trust upstreams. Default is the 22.22.22.22 sentinel (same convention as
	// XRAY_RESOLVER): a bare IP queried over plain UDP, meant to be replaced by
	// the operator via the web console (Settings → upstream DNS).
	trustRaw := envOr("DNS_TRUST", "22.22.22.22")
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

	// Egress SNI re-resolver (env DNS_EGRESS_RESOLVER; back-compat fallback
	// XRAY_RESOLVER for a box whose dns.env predates the mihomo-migration
	// rename). Consumed by the broker's legacy fallback exchanger. Default is
	// the 22.22.22.22 placeholder; a malformed value is FATAL (ValidateResolver):
	// a broken resolver would silently break the sniffed-origin data path, so
	// surface it at load time. The 22.22.22.22 sentinel passes ValidateResolver
	// as a plain IPv4.
	egressResolver := strings.TrimSpace(os.Getenv("DNS_EGRESS_RESOLVER"))
	if egressResolver == "" {
		egressResolver = strings.TrimSpace(os.Getenv("XRAY_RESOLVER"))
	}
	if egressResolver == "" {
		egressResolver = "22.22.22.22"
	}
	cfg.XrayResolver = egressResolver
	if err := ValidateResolver(cfg.XrayResolver); err != nil {
		return Config{}, fmt.Errorf("config: invalid DNS_EGRESS_RESOLVER/XRAY_RESOLVER: %w", err)
	}

	// China-group EDNS Client Subnet. Warn-not-fatal like every tuning knob: a
	// typo'd subnet must never crash-loop the sole resolver — fall back to the
	// default. "off"/"none"/"disable"/"0" explicitly disables ECS.
	const defaultChinaECS = "122.96.30.0/24"
	switch raw := strings.ToLower(strings.TrimSpace(os.Getenv("DNS_CHINA_ECS"))); raw {
	case "":
		cfg.ChinaECS, _ = parseECS(defaultChinaECS)
	case "off", "none", "disable", "0":
		cfg.ChinaECS = nil
	default:
		subnet, err := parseECS(raw)
		if err != nil {
			log.Printf("config: invalid DNS_CHINA_ECS %q, using default %s", raw, defaultChinaECS)
			subnet, _ = parseECS(defaultChinaECS)
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

	// Query timeout (Go duration string).
	cfg.QueryTimeout = envDurationOr("DNS_QUERY_TIMEOUT", 5*time.Second)

	// Outbound liveness heartbeat (dead-man's switch; see Config.HeartbeatURL).
	// Only http/https URLs are honoured; anything else is warned + ignored.
	if raw := os.Getenv("DNS_HEARTBEAT_URL"); raw != "" {
		if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
			cfg.HeartbeatURL = raw
		} else {
			log.Printf("config: ignoring DNS_HEARTBEAT_URL %q (must start with http:// or https://)", raw)
		}
	}
	cfg.HeartbeatInterval = envDurationOr("DNS_HEARTBEAT_INTERVAL", 60*time.Second)

	// Loopback Egress DNS Broker. An explicit
	// empty value disables it; otherwise the host must be a loopback IPv4
	// literal (never IPv6, never a hostname) — see Config.EgressBrokerAddr.
	// Unlike the warn-and-fallback numeric knobs above, a bad value here is
	// FATAL: silently falling back to the default would mask an operator
	// mistake that could otherwise widen the broker onto a routable or
	// public address, which the spec forbids outright.
	brokerRaw := envListen("DNS_EGRESS_BROKER", "127.0.0.1:5354")
	if brokerRaw != "" {
		if err := validateLoopbackIPv4Addr(brokerRaw); err != nil {
			return Config{}, fmt.Errorf("config: invalid DNS_EGRESS_BROKER %q: %w", brokerRaw, err)
		}
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

	// TLS validation: cert+key required when the DoT listener is enabled.
	if cfg.ListenDoT != "" {
		if cfg.CertFile == "" || cfg.KeyFile == "" {
			return Config{}, errors.New("config: DNS_CERT and DNS_KEY are required when the DoT listener is enabled")
		}
	}

	return cfg, nil
}

// parseTrustEntries parses a comma-separated list of trust upstream specs.
// Each spec is either "serverName@dialAddr" (DoT) or a bare IP (plain UDP).
func parseTrustEntries(raw string) []TrustEntry {
	return parseTrustEntryList(splitTrim(raw))
}

// parseTrustEntryList parses trust upstream specs, one per element:
// "serverName@dialAddr" → DoT; bare "IP" → plain UDP (Plain=true). The bare
// form deliberately means plaintext (deliberate reversal 2026-07-10 — it used
// to mean DoT-with-IP-SAN, which made the 22.22.22.22-style internal-resolver
// default impossible to use).
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
// splitCommaList splits a comma-separated env value into a trimmed,
// empty-filtered slice. Returns nil for an all-empty input.
func splitCommaList(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

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
	if err != nil || n < 0 {
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
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		log.Printf("config: invalid %s %q, using default %ds", key, raw, def)
		n = def
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
	if err != nil || d < 0 {
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
