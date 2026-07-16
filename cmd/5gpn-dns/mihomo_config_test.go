package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// goldenInfraParams returns the InfraParams matching goldenMihomoConfig's
// substituted token values.
func goldenInfraParams() InfraParams {
	return InfraParams{
		ConsoleDomain:    "console.5gpn.test",
		ZashDomain:       "zash.5gpn.test",
		ProfileDomain:    "profile.5gpn.test",
		GatewayIP:        "10.0.1.20",
		Controller:       "127.0.0.1:9090",
		ControllerSecret: "s3cr3t",
		EgressBrokerDNS:  "udp://127.0.0.1:5354",
	}
}

// goldenMihomoConfig renders the seed template's tokens directly (bypassing
// MihomoConfigStore.Default's env-var indirection) so this test file's
// golden text and goldenInfraParams stay obviously in sync.
func goldenMihomoConfig() string {
	r := strings.NewReplacer(
		"__CONSOLE_DOMAIN__", "console.5gpn.test",
		"__ZASH_DOMAIN__", "zash.5gpn.test",
		"__PROFILE_DOMAIN__", "profile.5gpn.test",
		"__MIHOMO_LISTENERS__", renderMihomoListeners([]string{"203.0.113.10"}),
		"__GATEWAY_IP__", "10.0.1.20",
		"__CONTROLLER_SECRET__", "s3cr3t",
	)
	return r.Replace(mihomoConfigSeedTemplate)
}

func TestMihomoInvariants_GoldenPasses(t *testing.T) {
	if err := ValidateInvariants(goldenMihomoConfig(), goldenInfraParams()); err != nil {
		t.Fatalf("golden config should satisfy all invariants: %v", err)
	}
}

func TestMihomoInvariants_ProfileSNIMustStayPublicAndDirect(t *testing.T) {
	p := goldenInfraParams()
	withProfile := goldenMihomoConfig()
	if err := ValidateInvariants(withProfile, p); err != nil {
		t.Fatalf("valid public profile split rejected: %v", err)
	}

	for _, broken := range []string{
		strings.Replace(withProfile, "  profile.5gpn.test: 127.0.0.1\n", "", 1),
		strings.Replace(withProfile, "  - DOMAIN,profile.5gpn.test,DIRECT\n", "", 1),
		strings.Replace(withProfile, "  - DOMAIN,profile.5gpn.test,DIRECT\n",
			"  - AND,((DOMAIN,profile.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n", 1),
	} {
		err := ValidateInvariants(broken, p)
		var missing *ErrMissingInfra
		if !errors.As(err, &missing) || missing.Name != "profile-sni" {
			t.Fatalf("broken profile split error = %v, want profile-sni", err)
		}
	}
}

// TestMihomoInvariants_WhitespaceReformattedStillPasses locks in the
// "tolerant of whitespace" requirement (design §4.4): reflowing a listener
// entry from a single flow-style line into an indented block, and adding
// blank lines/extra spaces elsewhere, must not trip the checker.
func TestMihomoInvariants_WhitespaceReformattedStillPasses(t *testing.T) {
	cfg := goldenMihomoConfig()
	reformatted := strings.ReplaceAll(cfg,
		"- {name: sniproxy, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: 127.0.0.1:443}",
		"- name:    sniproxy\n    type: tunnel\n    listen: 203.0.113.10\n    port:   443\n    network: [tcp, udp]\n    target:      127.0.0.1:443",
	)
	// Extra blank lines and leading/trailing whitespace elsewhere.
	reformatted = strings.ReplaceAll(reformatted, `external-controller: ""`, `external-controller:    ""   `)
	reformatted = "\n\n" + reformatted + "\n\n"

	if err := ValidateInvariants(reformatted, goldenInfraParams()); err != nil {
		t.Fatalf("whitespace-reformatted-but-valid config should still pass: %v", err)
	}
}

func TestMihomoInvariants_ControllerQuotedScalarsStillPass(t *testing.T) {
	cfg := goldenMihomoConfig()
	cfg = strings.Replace(cfg, `external-controller: ""`, `external-controller: ''`, 1)
	cfg = strings.Replace(cfg, "external-controller-tls: 127.0.0.1:9090", `external-controller-tls: "127.0.0.1:9090"`, 1)
	cfg = strings.Replace(cfg, "certificate: /etc/5gpn/cert/zash/fullchain.pem", "certificate: '/etc/5gpn/cert/zash/fullchain.pem'", 1)
	cfg = strings.Replace(cfg, "private-key: /etc/5gpn/cert/zash/privkey.pem", `private-key: "/etc/5gpn/cert/zash/privkey.pem"`, 1)

	if err := ValidateInvariants(cfg, goldenInfraParams()); err != nil {
		t.Fatalf("quoted controller scalars should still pass: %v", err)
	}
}

// TestMihomoInvariants_MissingElement removes one required element at a time
// and asserts ValidateInvariants names exactly that invariant.
func TestMihomoInvariants_MissingElement(t *testing.T) {
	cases := []struct {
		name     string
		mutate   func(cfg string) string
		wantName string
	}{
		{
			name: "plaintext controller enabled",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, `external-controller: ""`, "external-controller: 127.0.0.1:9090", 1)
			},
			wantName: "controller",
		},
		{
			name: "plaintext controller bare empty scalar rejected",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, `external-controller: ""`, "external-controller:", 1)
			},
			wantName: "controller",
		},
		{
			name: "plaintext controller continuation scalar rejected",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "external-controller: \"\"\n", "external-controller:\n  127.0.0.1:9091\n", 1)
			},
			wantName: "controller",
		},
		{
			name: "TLS controller removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "external-controller-tls: 127.0.0.1:9090\n", "", 1)
			},
			wantName: "controller",
		},
		{
			name: "controller certificate changed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "/etc/5gpn/cert/zash/fullchain.pem", "/tmp/controller.pem", 1)
			},
			wantName: "controller",
		},
		{
			name: "controller private key changed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "/etc/5gpn/cert/zash/privkey.pem", "/tmp/controller.key", 1)
			},
			wantName: "controller",
		},
		{
			name: "duplicate TLS controller key rejected",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "secret: s3cr3t\n", "external-controller-tls: 127.0.0.1:9090\nsecret: s3cr3t\n", 1)
			},
			wantName: "controller",
		},
		{
			name: "nested TLS decoy rejected",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					"tls:\n  certificate: /etc/5gpn/cert/zash/fullchain.pem\n  private-key: /etc/5gpn/cert/zash/privkey.pem\n",
					"tls:\n  nested:\n    certificate: /etc/5gpn/cert/zash/fullchain.pem\n    private-key: /etc/5gpn/cert/zash/privkey.pem\n", 1)
			},
			wantName: "controller",
		},
		{
			name: "flow-style TLS substitution rejected",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					"tls:\n  certificate: /etc/5gpn/cert/zash/fullchain.pem\n  private-key: /etc/5gpn/cert/zash/privkey.pem\n",
					"tls: { certificate: /etc/5gpn/cert/zash/fullchain.pem, private-key: /etc/5gpn/cert/zash/privkey.pem }\n", 1)
			},
			wantName: "controller",
		},
		{
			name: "sniproxy tunnel listener removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					"  - {name: sniproxy, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: 127.0.0.1:443}\n",
					"", 1)
			},
			wantName: "sniproxy-inbound",
		},
		{
			name: "dns nameserver missing the egress broker",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					`nameserver: ["udp://127.0.0.1:5354"]`,
					`nameserver: ["udp://8.8.8.8:53"]`, 1)
			},
			wantName: "dns-broker",
		},
		{
			name: "console hosts mapping removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "  console.5gpn.test: 127.0.0.1\n", "", 1)
			},
			wantName: "console-sni",
		},
		{
			name: "console REJECT-DROP guard removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "  - DOMAIN,console.5gpn.test,REJECT-DROP\n", "", 1)
			},
			wantName: "console-sni",
		},
		{
			name: "console whitelist-gated DIRECT rule removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					"  - AND,((DOMAIN,console.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n",
					"", 1)
			},
			wantName: "console-sni",
		},
		{
			name: "zash hosts mapping removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "  zash.5gpn.test:    127.0.0.2\n", "", 1)
			},
			wantName: "zash-sni",
		},
		{
			name: "zash REJECT-DROP guard removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "  - DOMAIN,zash.5gpn.test,REJECT-DROP\n", "", 1)
			},
			wantName: "zash-sni",
		},
		{
			// Symmetric to the "console whitelist-gated DIRECT rule removed"
			// case above (Unit-B review): the zash panel gets the exact same
			// AND(...)-shaped rule, and its removal must be caught the same way.
			name: "zash whitelist-gated DIRECT rule removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					"  - AND,((DOMAIN,zash.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n",
					"", 1)
			},
			wantName: "zash-sni",
		},
		{
			name: "controller secret changed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "secret: s3cr3t", "secret: attacker-controlled", 1)
			},
			wantName: "controller-secret",
		},
		{
			name: "anti-loop gateway guard removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "  - IP-CIDR,10.0.1.20/32,REJECT-DROP,no-resolve\n", "", 1)
			},
			wantName: "anti-loop",
		},
		{
			name: "invariant commented out still counts as missing",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, `external-controller: ""`, `# external-controller: ""`, 1)
			},
			wantName: "controller",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mutated := tc.mutate(goldenMihomoConfig())
			err := ValidateInvariants(mutated, goldenInfraParams())
			if err == nil {
				t.Fatalf("expected a missing-invariant error, got nil")
			}
			var mi *ErrMissingInfra
			if !errors.As(err, &mi) {
				t.Fatalf("expected *ErrMissingInfra, got %T: %v", err, err)
			}
			if mi.Name != tc.wantName {
				t.Fatalf("expected first missing invariant %q, got %q (err=%v)", tc.wantName, mi.Name, err)
			}
			if !strings.Contains(err.Error(), tc.wantName) {
				t.Fatalf("error message %q should contain invariant name %q", err.Error(), tc.wantName)
			}
			if !strings.Contains(err.Error(), "missing required infrastructure") {
				t.Fatalf("error message %q should contain the standard prefix", err.Error())
			}
		})
	}
}

// TestMihomoInvariants_EmptyInfraParamsFailClosed asserts an unconfigured
// invariant value (e.g. no console domain known yet) is treated as
// "cannot be satisfied", never as a wildcard that matches anything. The
// controller/dns-broker checks (design §4.4 rows #1/#3) are literal-based
// (see literalControllerAddr/literalDNSBrokerNameserver in mihomo_config.go)
// and so are satisfied by the golden config regardless of InfraParams —
// console-sni is therefore the first PARAM-dependent check to fail against a
// wholly-empty InfraParams.
func TestMihomoInvariants_EmptyInfraParamsFailClosed(t *testing.T) {
	err := ValidateInvariants(goldenMihomoConfig(), InfraParams{})
	if err == nil {
		t.Fatalf("expected an error for a wholly-empty InfraParams")
	}
	var mi *ErrMissingInfra
	if !errors.As(err, &mi) {
		t.Fatalf("expected *ErrMissingInfra, got %T: %v", err, err)
	}
	if mi.Name != "console-sni" {
		t.Fatalf("expected the first param-dependent check (console-sni) to fail first, got %q", mi.Name)
	}
}

// TestMihomoInvariants_ControllerAndDNSBrokerAreLiteral is the Unit-B-review
// regression lock: hasControllerInvariant/hasDNSBrokerInvariant must match
// the FIXED literal values the seed template hardcodes (design §4.4 rows
// #1/#3), never InfraParams.Controller/.EgressBrokerDNS — Default()'s output
// must satisfy ValidateInvariants even when those two fields are populated
// with values that do NOT appear anywhere in the config text, proving the
// check does not consult them.
func TestMihomoInvariants_ControllerAndDNSBrokerAreLiteral(t *testing.T) {
	dir := t.TempDir()
	store := NewMihomoConfigStore(filepath.Join(dir, "config.yaml"))

	t.Setenv("DNS_CONSOLE_DOMAIN", "console.5gpn.test")
	t.Setenv("DNS_ZASH_DOMAIN", "zash.5gpn.test")
	t.Setenv("DNS_PROFILE_DOMAIN", "profile.5gpn.test")
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "203.0.113.10")
	t.Setenv("DNS_GATEWAY_IP", "10.0.1.20")
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")

	def := store.Default()

	p := goldenInfraParams()
	p.Controller = "10.9.9.9:1234"          // does NOT appear in the seed text
	p.EgressBrokerDNS = "udp://10.9.9.9:53" // does NOT appear in the seed text

	if err := ValidateInvariants(def, p); err != nil {
		t.Fatalf("Default() should satisfy all invariants even with non-default InfraParams.Controller/.EgressBrokerDNS: %v", err)
	}
}

func TestMihomoConfigStore_ReadAndDefault(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	store := NewMihomoConfigStore(path)

	if store.Path() != path {
		t.Fatalf("Path() = %q, want %q", store.Path(), path)
	}
	if store.Dir() != dir {
		t.Fatalf("Dir() = %q, want %q", store.Dir(), dir)
	}

	if _, err := store.Read(); err == nil {
		t.Fatalf("expected Read() to fail before the file exists")
	}

	if err := os.WriteFile(path, []byte("hello: world\n"), 0o644); err != nil {
		t.Fatalf("seed file: %v", err)
	}
	got, err := store.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got != "hello: world\n" {
		t.Fatalf("Read() = %q, want %q", got, "hello: world\n")
	}

	t.Setenv("DNS_CONSOLE_DOMAIN", "console.5gpn.test")
	t.Setenv("DNS_ZASH_DOMAIN", "zash.5gpn.test")
	t.Setenv("DNS_PROFILE_DOMAIN", "profile.5gpn.test")
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "203.0.113.10")
	t.Setenv("DNS_GATEWAY_IP", "10.0.1.20")
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")

	def := store.Default()
	if def != goldenMihomoConfig() {
		t.Fatalf("Default() did not match the expected rendering:\n--- got ---\n%s\n--- want ---\n%s", def, goldenMihomoConfig())
	}
	if err := ValidateInvariants(def, goldenInfraParams()); err != nil {
		t.Fatalf("Default() output should satisfy all invariants: %v", err)
	}
}

func TestInfraParamsFromConfig(t *testing.T) {
	cfg := Config{
		ConsoleDomain:    "console.5gpn.test",
		ZashDomain:       "zash.5gpn.test",
		ProfileDomain:    "profile.5gpn.test",
		MihomoController: "127.0.0.1:9090",
		EgressBrokerAddr: "127.0.0.1:5354",
	}
	cfg.GatewayIP = net.ParseIP("10.0.1.20")
	p := InfraParamsFromConfig(cfg)
	want := InfraParams{
		ConsoleDomain:   "console.5gpn.test",
		ZashDomain:      "zash.5gpn.test",
		ProfileDomain:   "profile.5gpn.test",
		GatewayIP:       "10.0.1.20",
		Controller:      "127.0.0.1:9090",
		EgressBrokerDNS: "udp://127.0.0.1:5354",
	}
	if p != want {
		t.Fatalf("InfraParamsFromConfig = %+v, want %+v", p, want)
	}
}

// TestInfraParamsFromConfig_EmptyGatewayAndBroker asserts a nil GatewayIP /
// empty EgressBrokerAddr yield empty fields (fail-closed), not a placeholder.
func TestInfraParamsFromConfig_EmptyGatewayAndBroker(t *testing.T) {
	p := InfraParamsFromConfig(Config{})
	if p.GatewayIP != "" {
		t.Fatalf("GatewayIP = %q, want empty", p.GatewayIP)
	}
	if p.EgressBrokerDNS != "" {
		t.Fatalf("EgressBrokerDNS = %q, want empty", p.EgressBrokerDNS)
	}
}

func TestMihomoConfigDefaultRendersPluralListeners(t *testing.T) {
	t.Setenv("DNS_CONSOLE_DOMAIN", "console.5gpn.test")
	t.Setenv("DNS_ZASH_DOMAIN", "zash.5gpn.test")
	t.Setenv("DNS_PROFILE_DOMAIN", "profile.5gpn.test")
	t.Setenv("DNS_GATEWAY_IP", "10.0.1.20")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "10.0.1.20, 203.0.113.10,10.0.1.20")
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")

	got := NewMihomoConfigStore(filepath.Join(t.TempDir(), "config.yaml")).Default()
	for _, want := range []string{
		"name: sniproxy, type: tunnel, listen: 10.0.1.20, port: 443",
		"name: sniproxy80, type: tunnel, listen: 10.0.1.20, port: 80",
		"name: sniproxy-2, type: tunnel, listen: 203.0.113.10, port: 443",
		"name: sniproxy80-2, type: tunnel, listen: 203.0.113.10, port: 80",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("Default() missing %q", want)
		}
	}
	if strings.Contains(got, "__MIHOMO_LISTENERS__") || strings.Contains(got, "__PUBLIC_IP__") {
		t.Fatal("Default() left an unresolved listener token")
	}
}

func TestMihomoConfigDefaultLegacyFallbackAndFailClosed(t *testing.T) {
	setInfra := func() InfraParams {
		t.Setenv("DNS_CONSOLE_DOMAIN", "console.5gpn.test")
		t.Setenv("DNS_ZASH_DOMAIN", "zash.5gpn.test")
		t.Setenv("DNS_BASE_DOMAIN", "5gpn.test.")
		t.Setenv("DNS_PROFILE_DOMAIN", "")
		t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
		return goldenInfraParams()
	}
	p := setInfra()
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "")
	t.Setenv("DNS_GATEWAY_IP", "127.0.0.1")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")
	p.GatewayIP = "127.0.0.1"
	def := NewMihomoConfigStore(filepath.Join(t.TempDir(), "config.yaml")).Default()
	if !strings.Contains(def, "listen: 203.0.113.10") || !strings.Contains(def, "profile.5gpn.test: 127.0.0.1") {
		t.Fatalf("legacy/default derivation missing from:\n%s", def)
	}
	if err := ValidateInvariants(def, p); err != nil {
		t.Fatalf("legacy public-IP fallback should remain resettable: %v", err)
	}

	t.Setenv("DNS_GATEWAY_IP", "")
	t.Setenv("DNS_PUBLIC_IP", "")
	def = NewMihomoConfigStore(filepath.Join(t.TempDir(), "config.yaml")).Default()
	err := ValidateInvariants(def, p)
	var missing *ErrMissingInfra
	if !errors.As(err, &missing) || missing.Name != "sniproxy-inbound" {
		t.Fatalf("empty legacy listener inputs error = %v, want sniproxy-inbound", err)
	}

	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "0.0.0.0")
	def = NewMihomoConfigStore(filepath.Join(t.TempDir(), "config.yaml")).Default()
	err = ValidateInvariants(def, p)
	if !errors.As(err, &missing) || missing.Name != "sniproxy-inbound" {
		t.Fatalf("unsafe explicit listener error = %v, want sniproxy-inbound", err)
	}
}

// TestMihomoConfigSeedTemplate_MatchesRepoFile locks mihomoConfigSeedTemplate
// (this package's copy, used by MihomoConfigStore.Default so the daemon can
// regenerate the seed without the source-tree etc/ directory) BYTE-IDENTICAL
// to the repo's etc/mihomo/config.yaml.tmpl (what install.sh actually
// renders at install time via sed). Without this lock the two copies drift
// silently: a template edit in one place would leave the console's
// GET/PUT /api/mihomo/config default, POST /api/mihomo/config/reset, and
// `5gpn mihomo-reset` recovery path serving a stale seed.
func TestMihomoConfigSeedTemplate_MatchesRepoFile(t *testing.T) {
	const repoRelPath = "../../etc/mihomo/config.yaml.tmpl"
	want, err := os.ReadFile(repoRelPath)
	if err != nil {
		t.Fatalf("read %s (path must resolve from the package dir go test runs in): %v", repoRelPath, err)
	}
	if mihomoConfigSeedTemplate != string(want) {
		t.Fatalf("mihomoConfigSeedTemplate (mihomo_config.go) has drifted from %s -- update both in lockstep.\n--- Go copy ---\n%s\n--- repo file ---\n%s",
			repoRelPath, mihomoConfigSeedTemplate, string(want))
	}
}
