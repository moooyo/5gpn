// Package main provides storage and infrastructure validation for the complete,
// operator-owned mihomo config. The API layer composes two building blocks:
//
//   - MihomoConfigStore: read the on-disk config, and render the install-time
//     seed default from the box's own dns.env-derived environment.
//   - ValidateInvariants: a text-pattern (regexp) check — NOT a YAML parse,
//     see the "no YAML library" module policy — that the submitted text still
//     contains the seven pieces of infrastructure the box's own lifelines
//     depend on, so an operator's edit can break their own
//     routing rules but can never accidentally cut off the controller, the
//     SNI-split panels, or the egress DNS broker.
package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// InfraParams is the set of box-specific values ValidateInvariants checks a
// submitted mihomo config against.
type InfraParams struct {
	ConsoleDomain    string // console.<DNS_BASE_DOMAIN>
	ZashDomain       string // zash.<DNS_BASE_DOMAIN>
	GatewayIP        string // env DNS_GATEWAY_IP (formatted, e.g. "10.0.1.20")
	ControllerSecret string // env DNS_MIHOMO_SECRET; immutable through the raw editor
}

// InfraParamsFromConfig builds InfraParams from the daemon's live Config —
// the actual console/zash domains, gateway IP, and controller secret.
func InfraParamsFromConfig(cfg Config) InfraParams {
	gw := ""
	if cfg.GatewayIP != nil {
		gw = cfg.GatewayIP.String()
	}
	return InfraParams{
		ConsoleDomain:    cfg.ConsoleDomain,
		ZashDomain:       cfg.ZashDomain,
		GatewayIP:        gw,
		ControllerSecret: cfg.MihomoSecret,
	}
}

// ErrMissingInfra reports that a submitted mihomo config is missing one of
// the seven required infrastructure invariants. Name is one of
// "controller", "gateway-inbound", "dns-broker", "console-sni", "zash-sni",
// "anti-loop", "controller-secret" — always the FIRST missing invariant in
// that fixed check order.
// The API layer (api_mihomo_config.go's applyMihomoConfig) maps this to an
// HTTP 400 directly via err.Error() — it does not need errors.As itself,
// since ValidateInvariants never wraps *ErrMissingInfra in another error;
// errors.As is used only by this package's own tests to assert on Name.
type ErrMissingInfra struct {
	Name string
}

func (e *ErrMissingInfra) Error() string {
	return fmt.Sprintf("missing required infrastructure: %s", e.Name)
}

// MihomoConfigStore is the on-disk mihomo config the console's raw editor
// reads and (via api_mihomo_config.go's apply pipeline) writes. path is the
// live config file (env DNS_MIHOMO_CONFIG, default /etc/5gpn/mihomo/config.yaml);
// dir is its parent directory, passed to `mihomo -t -d <dir>` so relative
// paths inside the config (e.g. the whitelist rule-provider's `./whitelist.txt`)
// resolve the same way they do for the real running config.
type MihomoConfigStore struct {
	path string
	dir  string

	// mu serializes the apply pipeline (validate -> mihomo -t -> atomic write
	// -> hot-apply, see api_mihomo_config.go's applyMihomoConfig), mirroring
	// PolicyRuleManager's mu (policy_rules.go): without it, two concurrent
	// PUT/reset calls could interleave their write+hot-apply steps, so the
	// file that ends up on disk and the config actually hot-applied to the
	// running controller could come from DIFFERENT submissions. Lock/Unlock
	// are exported so the API layer (a different file/package-internal
	// caller) can hold the lock across its whole multi-step pipeline, not
	// just around individual Store methods.
	mu sync.Mutex
}

// NewMihomoConfigStore builds a store rooted at path.
func NewMihomoConfigStore(path string) *MihomoConfigStore {
	return &MihomoConfigStore{path: path, dir: filepath.Dir(path)}
}

// Lock acquires the store's apply-pipeline mutex. Callers must Unlock when
// done; see the mu field doc for why this exists.
func (s *MihomoConfigStore) Lock() { s.mu.Lock() }

// Unlock releases the store's apply-pipeline mutex.
func (s *MihomoConfigStore) Unlock() { s.mu.Unlock() }

// Path returns the config file path.
func (s *MihomoConfigStore) Path() string { return s.path }

// Dir returns the config file's parent directory.
func (s *MihomoConfigStore) Dir() string { return s.dir }

// Read returns the current on-disk config text.
func (s *MihomoConfigStore) Read() (string, error) {
	b, err := os.ReadFile(s.path)
	if err != nil {
		return "", fmt.Errorf("mihomo config: read %s: %w", s.path, err)
	}
	return string(b), nil
}

// EnsurePrivateDir creates the config directory if needed and forces it to
// owner-only access. config.yaml contains the mihomo controller bearer secret,
// so inheriting a world-readable 0755 directory is not acceptable.
func (s *MihomoConfigStore) EnsurePrivateDir() error {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(s.dir, 0o700)
}

// normalizeMihomoListenerIPs validates, de-duplicates, and preserves the
// configured listener order. Reset/default rendering must never fall back to
// 0.0.0.0: that would collide with the loopback panel listeners on :443.
func normalizeMihomoListenerIPs(raw string) ([]string, bool) {
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		ip := net.ParseIP(part)
		if ip == nil || ip.To4() == nil || ip.IsLoopback() || ip.IsUnspecified() {
			return nil, false
		}
		canonical := ip.To4().String()
		if _, ok := seen[canonical]; ok {
			continue
		}
		seen[canonical] = struct{}{}
		out = append(out, canonical)
		if len(out) > 16 {
			return nil, false
		}
	}
	return out, true
}

func renderMihomoListeners(ips []string) string {
	var b strings.Builder
	for i, ip := range ips {
		suffix := ""
		if i > 0 {
			suffix = fmt.Sprintf("-%d", i+1)
		}
		fmt.Fprintf(&b, "  - {name: gateway%s, type: tunnel, listen: %s, port: 443, network: [tcp, udp], target: 127.0.0.1:443}\n", suffix, ip)
		fmt.Fprintf(&b, "  - {name: gateway80%s, type: tunnel, listen: %s, port: 80, network: [tcp], target: 127.0.0.1:80}\n", suffix, ip)
	}
	return strings.TrimSuffix(b.String(), "\n")
}

func mihomoSeedListenerIPs() []string {
	raw := strings.TrimSpace(os.Getenv("DNS_MIHOMO_LISTEN_IPS"))
	if raw == "" {
		return nil
	}
	ips, ok := normalizeMihomoListenerIPs(raw)
	if !ok {
		return nil
	}
	return ips
}

// Default renders the install-time seed config (mihomoConfigSeedTemplate)
// against the process's OWN environment — the same DNS_* keys systemd's
// EnvironmentFile populates from /etc/5gpn/dns.env for the running daemon
// EnvironmentFile populates from /etc/5gpn/dns.env. It takes no arguments so
// the reset handler always renders from the daemon's current deployment identity.
func (s *MihomoConfigStore) Default() string {
	base := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(os.Getenv("DNS_BASE_DOMAIN"))), ".")
	consoleDomain, zashDomain := "", ""
	if isValidDomain(base) {
		consoleDomain = "console." + base
		zashDomain = "zash." + base
	}
	r := strings.NewReplacer(
		"__CONSOLE_DOMAIN__", consoleDomain,
		"__ZASH_DOMAIN__", zashDomain,
		"__MIHOMO_LISTENERS__", renderMihomoListeners(mihomoSeedListenerIPs()),
		"__GATEWAY_IP__", os.Getenv("DNS_GATEWAY_IP"),
		"__CONTROLLER_SECRET__", os.Getenv("DNS_MIHOMO_SECRET"),
	)
	return r.Replace(mihomoConfigSeedTemplate)
}

// mihomoConfigSeedTemplate is a Go-side copy of etc/mihomo/config.yaml.tmpl,
// kept BYTE-IDENTICAL to it (locked by TestMihomoConfigSeedTemplate_MatchesRepoFile
// in mihomo_config_test.go). install.sh renders the repo file at install time
// via sed; go:embed cannot reach it directly from this package (it lives
// outside cmd/5gpn-dns/, and embed forbids ".." paths), so this is a
// deliberate duplication that lets the daemon regenerate the exact same seed
// for POST .../reset without
// needing the source-tree etc/ directory to exist on the box. Whenever
// etc/mihomo/config.yaml.tmpl changes, update this const identically.
const mihomoConfigSeedTemplate = `# 5gpn mihomo data plane — install-time seed (rendered by install.sh). This
# file is fully operator-owned from here on: no region of it is daemon-
# managed by the daemon -- edit it via the
# console's mihomo config editor (GET/PUT /api/mihomo/config), '5gpn
# mihomo-reset' to restore this seed, or by hand. The console's policy
# engine only ever decides "gateway or not" (DNS layer); everything below
# about what happens to gateway-bound traffic is yours to shape.
external-controller: ""
external-controller-tls: 127.0.0.1:9090
secret: __CONTROLLER_SECRET__
tls:
  certificate: /etc/5gpn/cert/zash/fullchain.pem
  private-key: /etc/5gpn/cert/zash/privkey.pem
profile: { store-selected: true }
mode: rule
log-level: info

listeners:
__MIHOMO_LISTENERS__

sniffer:
  enable: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    TLS:  { ports: [443] }
    QUIC: { ports: [443] }
    HTTP: { ports: [80] }

dns:
  enable: true
  enhanced-mode: normal
  nameserver: ["udp://127.0.0.1:5354"]   # 5gpn-dns egress broker: returns REAL upstream IPs

hosts:
  __CONSOLE_DOMAIN__: 127.0.0.1
  __ZASH_DOMAIN__:    127.0.0.2

rule-providers:
  whitelist: {type: file, behavior: ipcidr, format: text, path: ./whitelist.txt}

# Egress skeleton -- empty by default. Add proxy nodes (proxies:) and/or
# node-subscription providers (proxy-providers:), then wire them into
# proxy-groups as you like; the terminal MATCH rule below routes every
# gateway-bound query that reached this point to the Proxies group.
proxies: []
proxy-providers: {}

proxy-groups:
  - {name: Proxies, type: select, proxies: [DIRECT]}

rules:
  - DOMAIN,__CONSOLE_DOMAIN__,DIRECT
  - AND,((DOMAIN,__ZASH_DOMAIN__),(RULE-SET,whitelist,DIRECT,src)),DIRECT
  - DOMAIN,__ZASH_DOMAIN__,REJECT-DROP
  - IP-CIDR,__GATEWAY_IP__/32,REJECT-DROP,no-resolve
  - IP-CIDR,127.0.0.0/8,REJECT-DROP,no-resolve
  - IP-CIDR,10.0.0.0/8,REJECT-DROP,no-resolve
  - IP-CIDR,172.16.0.0/12,REJECT-DROP,no-resolve
  - IP-CIDR,192.168.0.0/16,REJECT-DROP,no-resolve
  - IP-CIDR,100.64.0.0/10,REJECT-DROP,no-resolve
  - IP-CIDR,169.254.0.0/16,REJECT-DROP,no-resolve
  - MATCH,Proxies
`

// whitespaceRunRE collapses any run of whitespace (spaces, tabs, newlines) to
// a single space, so ValidateInvariants's regexes are indifferent to
// reformatting (different indentation, wrapped lines, a flow map turned into
// block style) — only the token PATTERNS matter, never the literal layout.
var whitespaceRunRE = regexp.MustCompile(`\s+`)

// stripYAMLComments drops everything from the first `#` to end-of-line, on
// every line. Naive (doesn't understand quoted strings containing `#`), but
// this is a hand-edited operator config, not arbitrary YAML — it is enough to
// stop an invariant from being satisfied by a COMMENTED-OUT line (e.g.
// `# external-controller: 127.0.0.1:9090`), which a bare substring/regex
// check would otherwise treat as "present".
func stripYAMLComments(text string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		if idx := strings.IndexByte(l, '#'); idx >= 0 {
			lines[i] = l[:idx]
		}
	}
	return strings.Join(lines, "\n")
}

// normalizeForMatch prepares text for invariant matching: strip comments (so
// a disabled line can't satisfy a check), then collapse all whitespace to
// single spaces (so reformatting can't defeat a check either).
func normalizeForMatch(text string) string {
	return whitespaceRunRE.ReplaceAllString(stripYAMLComments(text), " ")
}

// proximityWindow bounds how far apart two required substrings may be within
// the same logical config entry (e.g. a flow-style listener map, or a rules
// list that got reformatted) for a combined pattern to still count as one
// unit — generous enough to survive reformatting, small enough that two
// invariants' near-identical tokens (e.g. the two `tunnel` listeners) don't
// bleed into each other.
const proximityWindow = `.{0,200}?`

// literalControllerTLSAddr, literalControllerCert, literalControllerKey, and
// literalDNSBrokerNameserver are the box's fixed loopback controller TLS
// listener, zashboard cert/key paths, and egress DNS broker nameserver URL.
// These are fixed seed-template literals:
// (mihomoConfigSeedTemplate / etc/mihomo/config.yaml.tmpl) hardcodes them
// unconditionally, unlike the console/zash domains or gateway IP. Checking
// against runtime dial settings would be incorrect because these seed values
// never vary with the controller client's connection target.
const (
	literalControllerTLSAddr   = "127.0.0.1:9090"
	literalControllerCert      = "/etc/5gpn/cert/zash/fullchain.pem"
	literalControllerKey       = "/etc/5gpn/cert/zash/privkey.pem"
	literalDNSBrokerNameserver = "udp://127.0.0.1:5354"
)

func parseYAMLScalar(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", false
	}
	switch {
	case len(raw) >= 2 && raw[0] == '\'' && raw[len(raw)-1] == '\'':
		return strings.ReplaceAll(raw[1:len(raw)-1], "''", "'"), true
	case len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"':
		value, err := strconv.Unquote(raw)
		return value, err == nil
	default:
		return raw, true
	}
}

func topLevelYAMLScalar(text, key string) (string, bool) {
	var value string
	found := false
	prefix := key + ":"
	for _, raw := range strings.Split(stripYAMLComments(text), "\n") {
		if raw != strings.TrimLeft(raw, " \t") || !strings.HasPrefix(raw, prefix) {
			continue
		}
		if found {
			return "", false
		}
		var ok bool
		value, ok = parseYAMLScalar(strings.TrimPrefix(raw, prefix))
		if !ok {
			return "", false
		}
		found = true
	}
	return value, found
}

func topLevelYAMLMapScalar(text, mapKey, key string) (string, bool) {
	lines := strings.Split(stripYAMLComments(text), "\n")
	inMap := false
	mapFound := false
	childIndent := -1
	var value string
	valueFound := false
	for _, raw := range lines {
		if strings.TrimSpace(raw) == "" {
			continue
		}
		trimmed := strings.TrimLeft(raw, " \t")
		indent := len(raw) - len(trimmed)
		if indent == 0 {
			if inMap {
				inMap = false
			}
			if !strings.HasPrefix(trimmed, mapKey+":") {
				continue
			}
			if mapFound || strings.TrimSpace(strings.TrimPrefix(trimmed, mapKey+":")) != "" {
				return "", false
			}
			mapFound = true
			inMap = true
			childIndent = -1
			continue
		}
		if !inMap {
			continue
		}
		if childIndent == -1 {
			childIndent = indent
		}
		if indent != childIndent || !strings.HasPrefix(trimmed, key+":") {
			continue
		}
		if valueFound {
			return "", false
		}
		var ok bool
		value, ok = parseYAMLScalar(strings.TrimPrefix(trimmed, key+":"))
		if !ok {
			return "", false
		}
		valueFound = true
	}
	return value, mapFound && valueFound
}

// hasControllerInvariant asserts plaintext control is disabled, the loopback
// TLS controller is fixed, and the zashboard cert/key paths stay exact.
func hasControllerInvariant(text string) bool {
	plain, plainOK := topLevelYAMLScalar(text, "external-controller")
	tlsAddr, tlsOK := topLevelYAMLScalar(text, "external-controller-tls")
	cert, certOK := topLevelYAMLMapScalar(text, "tls", "certificate")
	key, keyOK := topLevelYAMLMapScalar(text, "tls", "private-key")
	return plainOK && plain == "" &&
		tlsOK && tlsAddr == literalControllerTLSAddr &&
		certOK && cert == literalControllerCert &&
		keyOK && key == literalControllerKey
}

// hasControllerSecretInvariant requires the raw editor to preserve the
// daemon's configured controller secret. The daemon client and console proxy
// keep that secret in memory from dns.env; allowing config.yaml to change it
// would make the next hot-apply immediately lock both out. A dedicated secret
// rotation operation can coordinate those components in the future; raw YAML
// editing is intentionally not such an operation.
func hasControllerSecretInvariant(text, want string) bool {
	got, ok := topLevelYAMLScalar(text, "secret")
	return ok && got == want
}

// hasGatewayInbound asserts a `tunnel` listener on port 443 targeting
// 127.0.0.1:443.
func hasGatewayInbound(norm string) bool {
	pat := regexp.MustCompile(`type\s*:\s*tunnel` + proximityWindow + `port\s*:\s*443` + proximityWindow + `target\s*:\s*"?127\.0\.0\.1:443"?`)
	return pat.MatchString(norm)
}

// hasDNSBrokerInvariant asserts the dns: nameserver list includes the egress
// broker.
func hasDNSBrokerInvariant(norm string) bool {
	pat := regexp.MustCompile(`nameserver` + proximityWindow + regexp.QuoteMeta(literalDNSBrokerNameserver))
	return pat.MatchString(norm)
}

// hasAllowlistedSNISplit asserts domain is mapped to hostsIP in hosts:, AND has a
// whitelist-gated DIRECT rule, AND has a same-domain REJECT-DROP guard
// for the source-allowlisted zashboard surface.
func hasAllowlistedSNISplit(norm, domain, hostsIP string) bool {
	if strings.TrimSpace(domain) == "" {
		return false
	}
	d := regexp.QuoteMeta(domain)

	hostsPat := regexp.MustCompile(d + `\s*:\s*` + regexp.QuoteMeta(hostsIP) + `\b`)
	// directPat is anchored to the exact AND(...) rule SHAPE — not a loose
	// proximity window — so it can't be satisfied by a DIFFERENT domain's
	// whitelist-gated rule sitting a few tokens away in the same rules list.
	// Still whitespace-tolerant (\s* at every punctuation boundary) so
	// reformatting alone doesn't trip it.
	directPat := regexp.MustCompile(`AND,\s*\(\s*\(\s*DOMAIN,\s*` + d +
		`\s*\)\s*,\s*\(\s*RULE-SET,\s*whitelist,\s*DIRECT,\s*src\s*\)\s*\)\s*,\s*DIRECT`)
	dropPat := regexp.MustCompile(`DOMAIN,\s*` + d + `\s*,\s*REJECT-DROP`)

	return hostsPat.MatchString(norm) && directPat.MatchString(norm) && dropPat.MatchString(norm)
}

// hasPublicSNISplit checks a public panel mapping: the hostname must resolve to
// the expected loopback backend and route DIRECT without a source allowlist.
func hasPublicSNISplit(norm, domain, hostsIP string) bool {
	if strings.TrimSpace(domain) == "" {
		return false
	}
	d := regexp.QuoteMeta(domain)
	hostsPat := regexp.MustCompile(d + `\s*:\s*` + regexp.QuoteMeta(hostsIP) + `\b`)
	directPat := regexp.MustCompile(`(?:^|\s)-\s*DOMAIN,\s*` + d + `\s*,\s*DIRECT(?:\s|$)`)
	allowlistedPat := regexp.MustCompile(`AND,\s*\(\s*\(\s*DOMAIN,\s*` + d +
		`\s*\)\s*,\s*\(\s*RULE-SET,\s*whitelist,\s*DIRECT,\s*src\s*\)\s*\)\s*,\s*DIRECT`)
	dropPat := regexp.MustCompile(`DOMAIN,\s*` + d + `\s*,\s*REJECT-DROP`)
	return hostsPat.MatchString(norm) && directPat.MatchString(norm) &&
		!allowlistedPat.MatchString(norm) && !dropPat.MatchString(norm)
}

// hasAntiLoopInvariant asserts an exact gateway /32 REJECT-DROP guard.
func hasAntiLoopInvariant(norm string, p InfraParams) bool {
	if strings.TrimSpace(p.GatewayIP) == "" {
		return false
	}
	pat := regexp.MustCompile(`IP-CIDR,\s*` + regexp.QuoteMeta(p.GatewayIP) + `/32,\s*REJECT-DROP`)
	return pat.MatchString(norm)
}

// ValidateInvariants checks that text (a candidate mihomo config, about to
// be submitted to `mihomo -t` and then applied) still contains every one of
// the seven infrastructure invariants, matched against p (the box's own actual
// configuration — see InfraParamsFromConfig). It returns
// the FIRST missing invariant as *ErrMissingInfra (checked in the fixed order
// below), or nil when all seven are present.
//
// This is a text-pattern check (regexp), not a structural YAML parse — the
// module's no-YAML-library policy (miekg/dns + go-telegram/bot only) rules
// that out. `mihomo -t` (run separately, after this check — see
// api_mihomo_config.go) already guarantees the text parses as YAML mihomo
// accepts; this check adds the semantic guarantee that the box's own
// lifelines (controller, SNI-split panels, egress DNS broker, anti-loop
// guard) cannot be edited away.
func ValidateInvariants(text string, p InfraParams) error {
	norm := normalizeForMatch(text)

	switch {
	case !hasControllerInvariant(text):
		return &ErrMissingInfra{Name: "controller"}
	case !hasGatewayInbound(norm):
		return &ErrMissingInfra{Name: "gateway-inbound"}
	case !hasDNSBrokerInvariant(norm):
		return &ErrMissingInfra{Name: "dns-broker"}
	case !hasPublicSNISplit(norm, p.ConsoleDomain, "127.0.0.1"):
		return &ErrMissingInfra{Name: "console-sni"}
	case !hasAllowlistedSNISplit(norm, p.ZashDomain, "127.0.0.2"):
		return &ErrMissingInfra{Name: "zash-sni"}
	case !hasAntiLoopInvariant(norm, p):
		return &ErrMissingInfra{Name: "anti-loop"}
	case !hasControllerSecretInvariant(text, p.ControllerSecret):
		return &ErrMissingInfra{Name: "controller-secret"}
	}
	return nil
}
