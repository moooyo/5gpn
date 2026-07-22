// Package main provides storage and infrastructure validation for the complete,
// operator-owned mihomo config. The API layer composes two building blocks:
//
//   - MihomoConfigStore: read the on-disk config, and render the install-time
//     seed default from the box's own dns.env-derived environment.
//   - ValidateInvariants: a structural YAML check that the submitted document
//     still contains the seven pieces of infrastructure the box's own lifelines
//     depend on, so an operator's edit can break their own routing rules but
//     cannot accidentally cut off the controller, the SNI-split panels, or the
//     egress DNS broker.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"unicode"

	"gopkg.in/yaml.v3"
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
// resolve the same way they do for the real running config. backupPath is the
// daemon-owned rollback copy in dir's parent. Keeping it outside dir prevents
// a mihomo-owned legacy config.yaml.bak from blocking atomic replacement under
// the sticky shared-directory boundary.
type MihomoConfigStore struct {
	path       string
	dir        string
	backupPath string

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
	dir := filepath.Dir(path)
	backupPath := filepath.Join(filepath.Dir(dir), ".mihomo-"+filepath.Base(path)+".bak")
	return &MihomoConfigStore{path: path, dir: dir, backupPath: backupPath}
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

// BackupPath returns the daemon-owned rollback backup path.
func (s *MihomoConfigStore) BackupPath() string { return s.backupPath }

// Read returns the current on-disk config text.
func (s *MihomoConfigStore) Read() (string, error) {
	b, err := os.ReadFile(s.path)
	if err != nil {
		return "", fmt.Errorf("mihomo config: read %s: %w", s.path, err)
	}
	return string(b), nil
}

// EnsurePrivateDir creates the config directory if needed. Production
// ownership and setgid permissions are installed out of process because the
// unprivileged daemon must not chown or chmod the shared mihomo directory.
func (s *MihomoConfigStore) EnsurePrivateDir() error {
	return os.MkdirAll(s.dir, 0o770)
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

func renderMihomoListeners(ips []string, consoleDomain string) string {
	var b strings.Builder
	for i, ip := range ips {
		suffix := ""
		if i > 0 {
			suffix = fmt.Sprintf("-%d", i+1)
		}
		fmt.Fprintf(&b, "  - {name: gateway%s, type: tunnel, listen: %s, port: 443, network: [tcp, udp], target: %s:443}\n", suffix, ip, consoleDomain)
		fmt.Fprintf(&b, "  - {name: gateway80%s, type: tunnel, listen: %s, port: 80, network: [tcp], target: %s:80}\n", suffix, ip, consoleDomain)
		fmt.Fprintf(&b, "  - {name: gateway8080%s, type: tunnel, listen: %s, port: 8080, network: [tcp], target: %s:8080}\n", suffix, ip, consoleDomain)
		fmt.Fprintf(&b, "  - {name: gateway8443%s, type: tunnel, listen: %s, port: 8443, network: [tcp], target: %s:8443}\n", suffix, ip, consoleDomain)
		fmt.Fprintf(&b, "  - {name: gateway5060%s, type: tunnel, listen: %s, port: 5060, network: [tcp, udp], target: %s:5060}\n", suffix, ip, consoleDomain)
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
// EnvironmentFile populates from /etc/5gpn/dns.env. It takes no arguments so
// the reset handler always renders from the daemon's current deployment identity.
func (s *MihomoConfigStore) Default() string {
	base := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(os.Getenv("DNS_BASE_DOMAIN"))), ".")
	consoleDomain, zashDomain := "", ""
	if isValidDomain(base) {
		consoleDomain = "console." + base
		zashDomain = "zash." + base
	}
	interceptInUser, interceptInPass := "interception-unavailable", "interception-unavailable-password"
	interceptUpUser, interceptUpPass := "interception-upstream-unavailable", "interception-upstream-unavailable-password"
	interceptPath := envOr("DNS_INTERCEPT_CONFIG", "/etc/5gpn/intercept/config.json")
	if body, err := os.ReadFile(interceptPath); err == nil {
		if document, err := decodeInterceptConfig(body); err == nil {
			interceptInUser, interceptInPass = document.Username, document.Password
			interceptUpUser, interceptUpPass = document.UpstreamProxy.Username, document.UpstreamProxy.Password
		}
	}
	r := strings.NewReplacer(
		"__CONSOLE_DOMAIN__", consoleDomain,
		"__ZASH_DOMAIN__", zashDomain,
		"__MIHOMO_LISTENERS__", renderMihomoListeners(mihomoSeedListenerIPs(), consoleDomain),
		"__GATEWAY_IP__", os.Getenv("DNS_GATEWAY_IP"),
		"__CONTROLLER_SECRET__", yamlSingleQuotedValue(os.Getenv("DNS_MIHOMO_SECRET")),
		"__INTERCEPT_INBOUND_USERNAME__", interceptInUser,
		"__INTERCEPT_INBOUND_PASSWORD__", interceptInPass,
		"__INTERCEPT_UPSTREAM_USERNAME__", interceptUpUser,
		"__INTERCEPT_UPSTREAM_PASSWORD__", interceptUpPass,
	)
	return r.Replace(mihomoConfigSeedTemplate)
}

func yamlSingleQuotedValue(value string) string {
	return strings.ReplaceAll(value, "'", "''")
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
secret: '__CONTROLLER_SECRET__'
tls:
  certificate: /etc/5gpn/cert/zash/current/fullchain.pem
  private-key: /etc/5gpn/cert/zash/current/privkey.pem
profile: { store-selected: true }
mode: rule
log-level: info

listeners:
__MIHOMO_LISTENERS__
  - name: intercept-egress
    type: mixed
    listen: 127.0.0.1
    port: 17890
    udp: true
    users:
      - {username: __INTERCEPT_UPSTREAM_USERNAME__, password: __INTERCEPT_UPSTREAM_PASSWORD__}

sniffer:
  enable: true
  parse-pure-ip: true
  override-destination: true
  force-domain: [__CONSOLE_DOMAIN__]
  sniff:
    TLS:  { ports: [443, 8080, 8443, 5060] }
    QUIC: { ports: [443, 5060] }
    HTTP: { ports: [80, 8080, 8443, 5060] }

dns:
  enable: true
  enhanced-mode: normal
  nameserver: ["udp://127.0.0.1:5354"]   # 5gpn-dns loopback selector: extension China/trust binding, otherwise trust

hosts:
  __CONSOLE_DOMAIN__: 127.0.0.1
  __ZASH_DOMAIN__:    127.0.0.2

rule-providers:
  whitelist: {type: file, behavior: ipcidr, format: text, path: ./whitelist.txt}

# Egress skeleton -- empty by default. Add proxy nodes (proxies:) and/or
# node-subscription providers (proxy-providers:), then wire them into
# proxy-groups as you like; the terminal MATCH rule below routes every
# gateway-bound query that reached this point to the Proxies group.
proxies:
  - name: MODULE-INTERCEPT
    type: socks5
    server: 127.0.0.1
    port: 18080
    username: __INTERCEPT_INBOUND_USERNAME__
    password: __INTERCEPT_INBOUND_PASSWORD__
    udp: true
proxy-providers: {}

proxy-groups:
  - {name: Proxies, type: select, proxies: [DIRECT]}

rules:
  - AND,((DOMAIN,__CONSOLE_DOMAIN__),(NETWORK,UDP)),REJECT
  - AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,80)),REJECT
  - AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,8080)),REJECT
  - AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,8443)),REJECT
  - AND,((DOMAIN,__ZASH_DOMAIN__),(NETWORK,UDP)),REJECT
  - AND,((DOMAIN,__ZASH_DOMAIN__),(DST-PORT,80)),REJECT
  - AND,((DOMAIN,__ZASH_DOMAIN__),(DST-PORT,8080)),REJECT
  - AND,((DOMAIN,__ZASH_DOMAIN__),(DST-PORT,8443)),REJECT
  - AND,((DOMAIN,__CONSOLE_DOMAIN__),(DST-PORT,5060)),REJECT
  - AND,((DOMAIN,__ZASH_DOMAIN__),(DST-PORT,5060)),REJECT
  - DOMAIN,__CONSOLE_DOMAIN__,DIRECT
  - AND,((DOMAIN,__ZASH_DOMAIN__),(RULE-SET,whitelist,DIRECT,src)),DIRECT
  - DOMAIN,__ZASH_DOMAIN__,REJECT
  - IP-CIDR,__GATEWAY_IP__/32,REJECT,no-resolve
  - IP-CIDR,127.0.0.0/8,REJECT,no-resolve
  - IP-CIDR,10.0.0.0/8,REJECT,no-resolve
  - IP-CIDR,172.16.0.0/12,REJECT,no-resolve
  - IP-CIDR,192.168.0.0/16,REJECT,no-resolve
  - IP-CIDR,100.64.0.0/10,REJECT,no-resolve
  - IP-CIDR,169.254.0.0/16,REJECT,no-resolve
  # Every sidecar egress selector is published immediately above this
  # fail-closed terminator. Unknown or stale sidecar traffic must never fall
  # through to the operator's terminal MATCH rule.
  - IN-NAME,intercept-egress,REJECT
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  - MATCH,Proxies
`

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
	literalControllerCert      = "/etc/5gpn/cert/zash/current/fullchain.pem"
	literalControllerKey       = "/etc/5gpn/cert/zash/current/privkey.pem"
	literalDNSBrokerNameserver = "udp://127.0.0.1:5354"
)

type mihomoInvariantDocument struct {
	ExternalController    *string                   `yaml:"external-controller"`
	ExternalControllerTLS *string                   `yaml:"external-controller-tls"`
	Secret                *string                   `yaml:"secret"`
	TLS                   *mihomoInvariantTLS       `yaml:"tls"`
	Listeners             []mihomoInvariantListener `yaml:"listeners"`
	Sniffer               *mihomoInvariantSniffer   `yaml:"sniffer"`
	DNS                   *mihomoInvariantDNS       `yaml:"dns"`
	Hosts                 map[string]string         `yaml:"hosts"`
	Rules                 []string                  `yaml:"rules"`
}

type mihomoInvariantTLS struct {
	Certificate *string `yaml:"certificate"`
	PrivateKey  *string `yaml:"private-key"`
}

type mihomoInvariantListener struct {
	Name    string   `yaml:"name"`
	Type    string   `yaml:"type"`
	Port    int      `yaml:"port"`
	Network []string `yaml:"network"`
	Target  string   `yaml:"target"`
}

type mihomoInvariantSniffer struct {
	Enable              *bool                                    `yaml:"enable"`
	OverrideDestination *bool                                    `yaml:"override-destination"`
	ForceDomain         []string                                 `yaml:"force-domain"`
	SkipSrcAddress      []string                                 `yaml:"skip-src-address"`
	SkipDomain          []string                                 `yaml:"skip-domain"`
	Sniff               map[string]mihomoInvariantSniffingConfig `yaml:"sniff"`
}

type mihomoInvariantSniffingConfig struct {
	Ports               []string `yaml:"ports"`
	OverrideDestination *bool    `yaml:"override-destination"`
}

type mihomoInvariantDNS struct {
	Nameserver []string `yaml:"nameserver"`
}

func parseMihomoInvariantDocument(text string) (*mihomoInvariantDocument, error) {
	dec := yaml.NewDecoder(strings.NewReader(text))
	var doc mihomoInvariantDocument
	if err := dec.Decode(&doc); err != nil {
		if err == io.EOF {
			return nil, fmt.Errorf("invalid mihomo YAML: empty document")
		}
		return nil, fmt.Errorf("invalid mihomo YAML: %w", err)
	}

	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		if err != nil {
			return nil, fmt.Errorf("invalid mihomo YAML: %w", err)
		}
		return nil, fmt.Errorf("invalid mihomo YAML: multiple documents are not allowed")
	}
	return &doc, nil
}

func exactScalar(got *string, want string) bool {
	return got != nil && *got == want
}

// hasControllerInvariant asserts plaintext control is disabled, the loopback
// TLS controller is fixed, and the zashboard cert/key paths stay exact.
func hasControllerInvariant(doc *mihomoInvariantDocument) bool {
	return exactScalar(doc.ExternalController, "") &&
		exactScalar(doc.ExternalControllerTLS, literalControllerTLSAddr) &&
		doc.TLS != nil &&
		exactScalar(doc.TLS.Certificate, literalControllerCert) &&
		exactScalar(doc.TLS.PrivateKey, literalControllerKey)
}

// hasControllerSecretInvariant requires the raw editor to preserve the
// daemon's configured controller secret. The daemon client and console proxy
// keep that secret in memory from dns.env; allowing config.yaml to change it
// would make the next hot-apply immediately lock both out. A dedicated secret
// rotation operation can coordinate those components in the future; raw YAML
// editing is intentionally not such an operation.
func hasControllerSecretInvariant(doc *mihomoInvariantDocument, want string) bool {
	return exactScalar(doc.Secret, want)
}

func hasForcedConsoleSniff(doc *mihomoInvariantDocument, domain string) bool {
	if strings.TrimSpace(domain) == "" || doc.Sniffer == nil ||
		doc.Sniffer.Enable == nil || !*doc.Sniffer.Enable ||
		len(doc.Sniffer.SkipSrcAddress) != 0 || len(doc.Sniffer.SkipDomain) != 0 {
		return false
	}
	for _, forced := range doc.Sniffer.ForceDomain {
		if forced == domain {
			return true
		}
	}
	return false
}

func portRangeContains(spec string, want int) bool {
	parts := strings.Split(strings.TrimSpace(spec), "-")
	if len(parts) < 1 || len(parts) > 2 {
		return false
	}
	parse := func(raw string) (int, bool) {
		port, err := strconv.Atoi(strings.Trim(raw, "[] "))
		return port, err == nil && port >= 0 && port <= 65535
	}
	start, ok := parse(parts[0])
	if !ok {
		return false
	}
	end := start
	if len(parts) == 2 {
		end, ok = parse(parts[1])
		if !ok {
			return false
		}
	}
	if start > end {
		start, end = end, start
	}
	return want >= start && want <= end
}

func snifferPortsContain(ports []string, want int) bool {
	// Mihomo treats an omitted/empty ports list as all ports.
	if len(ports) == 0 {
		return true
	}
	for _, spec := range ports {
		if portRangeContains(spec, want) {
			return true
		}
	}
	return false
}

func hasEffectiveSniffer(doc *mihomoInvariantDocument, protocol string, port int) bool {
	if doc.Sniffer == nil {
		return false
	}
	found := false
	valid := false
	for name, config := range doc.Sniffer.Sniff {
		if !strings.EqualFold(name, protocol) {
			continue
		}
		// Mihomo accepts protocol names case-insensitively. Multiple differently
		// cased entries collapse onto one runtime map key in iteration order, so
		// fail closed instead of accepting a nondeterministic effective value.
		if found {
			return false
		}
		found = true
		override := doc.Sniffer.OverrideDestination != nil && *doc.Sniffer.OverrideDestination
		if config.OverrideDestination != nil {
			override = *config.OverrideDestination
		}
		valid = override && snifferPortsContain(config.Ports, port)
	}
	return found && valid
}

func listenerSupportsNetwork(listener mihomoInvariantListener, network string) bool {
	for _, candidate := range listener.Network {
		if candidate == network {
			return true
		}
	}
	return false
}

func isGatewayListenerName(name string) bool {
	if name == "gateway" {
		return true
	}
	if !strings.HasPrefix(name, "gateway-") {
		return false
	}
	n, err := strconv.Atoi(strings.TrimPrefix(name, "gateway-"))
	return err == nil && n >= 2
}

func isValidGatewayListener(doc *mihomoInvariantDocument, listener mihomoInvariantListener, p InfraParams) bool {
	if listener.Type != "tunnel" || listener.Port != 443 {
		return false
	}
	if listener.Target == "127.0.0.1:443" {
		return true
	}
	if listener.Target != p.ConsoleDomain+":443" ||
		!hasForcedConsoleSniff(doc, p.ConsoleDomain) ||
		!listenerSupportsNetwork(listener, "tcp") ||
		!hasEffectiveSniffer(doc, "TLS", 443) {
		return false
	}
	if listenerSupportsNetwork(listener, "udp") && !hasEffectiveSniffer(doc, "QUIC", 443) {
		return false
	}
	return true
}

// hasGatewayInbound asserts an actual listeners entry is a tunnel on port 443.
// Existing operator-owned configs may keep the legacy loopback target. The
// hostname target used by new seeds is accepted only with forced destination
// sniffing, which prevents mihomo's target-keyed sniff failure cache from
// disabling hostname discovery for every gateway connection at once.
func hasGatewayInbound(doc *mihomoInvariantDocument, p InfraParams) bool {
	namedGateway := false
	for _, listener := range doc.Listeners {
		if !isGatewayListenerName(listener.Name) {
			continue
		}
		namedGateway = true
		if !isValidGatewayListener(doc, listener, p) {
			return false
		}
	}
	if namedGateway {
		return true
	}

	// Preserve structurally valid operator configs created before listener
	// names became part of the seed vocabulary. Additional custom listeners
	// remain operator-owned and are not mistaken for gateway infrastructure.
	for _, listener := range doc.Listeners {
		if isValidGatewayListener(doc, listener, p) {
			return true
		}
	}
	return false
}

// hasDNSBrokerInvariant asserts the actual dns.nameserver sequence includes
// the loopback origin resolver boundary.
func hasDNSBrokerInvariant(doc *mihomoInvariantDocument) bool {
	if doc.DNS == nil {
		return false
	}
	for _, nameserver := range doc.DNS.Nameserver {
		if nameserver == literalDNSBrokerNameserver {
			return true
		}
	}
	return false
}

func compactMihomoRule(rule string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return r
	}, rule)
}

func containsRule(rules []string, want string) bool {
	for _, rule := range rules {
		if compactMihomoRule(rule) == want {
			return true
		}
	}
	return false
}

func directDomainRule(domain string) string {
	return "DOMAIN," + domain + ",DIRECT"
}

func allowlistedDomainRule(domain string) string {
	return "AND,((DOMAIN," + domain + "),(RULE-SET,whitelist,DIRECT,src)),DIRECT"
}

func denyDomainRule(domain, action string) string {
	return "DOMAIN," + domain + "," + action
}

func hasDenyDomainRule(doc *mihomoInvariantDocument, domain string) bool {
	for _, action := range []string{"REJECT", "REJECT-DROP"} {
		if containsRule(doc.Rules, denyDomainRule(domain, action)) {
			return true
		}
	}
	return false
}

// hasAllowlistedSNISplit asserts the real hosts and rules collections contain
// the source-allowlisted zashboard split and its deny-by-default guard.
func hasAllowlistedSNISplit(doc *mihomoInvariantDocument, domain, hostsIP string) bool {
	if strings.TrimSpace(domain) == "" || doc.Hosts[domain] != hostsIP {
		return false
	}
	return containsRule(doc.Rules, allowlistedDomainRule(domain)) &&
		hasDenyDomainRule(doc, domain)
}

// hasPublicSNISplit checks that the console maps to its loopback backend and
// has an unconditional DIRECT rule without zashboard-style allowlist or drop
// rules for the same hostname.
func hasPublicSNISplit(doc *mihomoInvariantDocument, domain, hostsIP string) bool {
	if strings.TrimSpace(domain) == "" || doc.Hosts[domain] != hostsIP {
		return false
	}
	return containsRule(doc.Rules, directDomainRule(domain)) &&
		!containsRule(doc.Rules, allowlistedDomainRule(domain)) &&
		!hasDenyDomainRule(doc, domain)
}

// hasAntiLoopInvariant asserts an exact gateway /32 deny guard. The action is
// operator-owned; both mihomo reject actions preserve the required anti-loop
// boundary, while the seed uses REJECT to avoid REJECT-DROP's connection hold.
func hasAntiLoopInvariant(doc *mihomoInvariantDocument, p InfraParams) bool {
	if strings.TrimSpace(p.GatewayIP) == "" {
		return false
	}
	for _, action := range []string{"REJECT", "REJECT-DROP"} {
		base := "IP-CIDR," + p.GatewayIP + "/32," + action
		if containsRule(doc.Rules, base) || containsRule(doc.Rules, base+",no-resolve") {
			return true
		}
	}
	return false
}

// ValidateInvariants checks that text (a candidate mihomo config, about to
// be submitted to `mihomo -t` and then applied) still contains every one of
// the seven infrastructure invariants, matched against p (the box's own actual
// configuration — see InfraParamsFromConfig). It returns
// the FIRST missing invariant as *ErrMissingInfra (checked in the fixed order
// below), or nil when all seven are present.
//
// The YAML is decoded into a narrow structural view before checking. Unknown
// operator-owned fields remain accepted, while malformed input, duplicate
// keys, and additional YAML documents fail closed before `mihomo -t` runs.
func ValidateInvariants(text string, p InfraParams) error {
	doc, err := parseMihomoInvariantDocument(text)
	if err != nil {
		return err
	}

	switch {
	case !hasControllerInvariant(doc):
		return &ErrMissingInfra{Name: "controller"}
	case !hasGatewayInbound(doc, p):
		return &ErrMissingInfra{Name: "gateway-inbound"}
	case !hasDNSBrokerInvariant(doc):
		return &ErrMissingInfra{Name: "dns-broker"}
	case !hasPublicSNISplit(doc, p.ConsoleDomain, "127.0.0.1"):
		return &ErrMissingInfra{Name: "console-sni"}
	case !hasAllowlistedSNISplit(doc, p.ZashDomain, "127.0.0.2"):
		return &ErrMissingInfra{Name: "zash-sni"}
	case !hasAntiLoopInvariant(doc, p):
		return &ErrMissingInfra{Name: "anti-loop"}
	case !hasControllerSecretInvariant(doc, p.ControllerSecret):
		return &ErrMissingInfra{Name: "controller-secret"}
	}
	return nil
}
