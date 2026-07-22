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
		GatewayIP:        "10.0.1.20",
		ControllerSecret: "s3cr3t",
	}
}

// goldenMihomoConfig renders the seed template's tokens directly (bypassing
// MihomoConfigStore.Default's env-var indirection) so this test file's
// golden text and goldenInfraParams stay obviously in sync.
func goldenMihomoConfig() string {
	r := strings.NewReplacer(
		"__CONSOLE_DOMAIN__", "console.5gpn.test",
		"__ZASH_DOMAIN__", "zash.5gpn.test",
		"__MIHOMO_LISTENERS__", renderMihomoListeners([]string{"203.0.113.10"}, "console.5gpn.test"),
		"__GATEWAY_IP__", "10.0.1.20",
		"__CONTROLLER_SECRET__", "s3cr3t",
		"__INTERCEPT_INBOUND_USERNAME__", "interception-unavailable",
		"__INTERCEPT_INBOUND_PASSWORD__", "interception-unavailable-password",
		"__INTERCEPT_UPSTREAM_USERNAME__", "interception-upstream-unavailable",
		"__INTERCEPT_UPSTREAM_PASSWORD__", "interception-upstream-unavailable-password",
	)
	return r.Replace(mihomoConfigSeedTemplate)
}

func TestMihomoInvariants_GoldenPasses(t *testing.T) {
	if err := ValidateInvariants(goldenMihomoConfig(), goldenInfraParams()); err != nil {
		t.Fatalf("golden config should satisfy all invariants: %v", err)
	}
}

func TestMihomoSeedUsesForcedConsoleFallbackTargets(t *testing.T) {
	cfg := goldenMihomoConfig()
	for _, want := range []string{
		"target: console.5gpn.test:443}",
		"target: console.5gpn.test:80}",
		"target: console.5gpn.test:8080}",
		"target: console.5gpn.test:8443}",
		"target: console.5gpn.test:5060}",
		"force-domain: [console.5gpn.test]",
	} {
		if !strings.Contains(cfg, want) {
			t.Errorf("seed config is missing %q", want)
		}
	}
	if strings.Contains(cfg, "target: 127.0.0.1:") {
		t.Fatal("seed listener targets must not share the loopback sniff-failure cache key")
	}
}

func TestMihomoInvariants_HostnameGatewayRequiresForcedSniff(t *testing.T) {
	p := goldenInfraParams()
	valid := goldenMihomoConfig()

	extraForceDomain := strings.Replace(valid,
		"force-domain: [console.5gpn.test]",
		"force-domain: [example.test, console.5gpn.test]", 1)
	if err := ValidateInvariants(extraForceDomain, p); err != nil {
		t.Fatalf("extra operator-owned force-domain entries should remain valid: %v", err)
	}
	perProtocolOverride := strings.Replace(valid,
		"  override-destination: true\n", "  override-destination: false\n", 1)
	perProtocolOverride = strings.Replace(perProtocolOverride,
		"TLS:  { ports: [443, 8080, 8443, 5060] }", "TLS:  { ports: [443, 8080, 8443, 5060], override-destination: true }", 1)
	perProtocolOverride = strings.Replace(perProtocolOverride,
		"QUIC: { ports: [443, 5060] }", "QUIC: { ports: [443, 5060], override-destination: true }", 1)
	if err := ValidateInvariants(perProtocolOverride, p); err != nil {
		t.Fatalf("effective per-protocol destination overrides should remain valid: %v", err)
	}
	portRange := strings.Replace(valid, "TLS:  { ports: [443, 8080, 8443, 5060] }", "TLS:  { ports: [400-500, 8080, 8443, 5060] }", 1)
	if err := ValidateInvariants(portRange, p); err != nil {
		t.Fatalf("a TLS port range containing 443 should remain valid: %v", err)
	}

	brokenConfigs := []string{
		strings.Replace(valid, "  force-domain: [console.5gpn.test]\n", "", 1),
		strings.Replace(valid, "force-domain: [console.5gpn.test]", "force-domain: [+.console.5gpn.test]", 1),
		strings.Replace(valid, "  enable: true\n", "  enable: false\n", 1),
		strings.Replace(valid, "  override-destination: true\n", "  override-destination: false\n", 1),
		strings.Replace(valid, "  force-domain: [console.5gpn.test]\n", "  force-domain: [console.5gpn.test]\n  skip-src-address: [0.0.0.0/0]\n", 1),
		strings.Replace(valid, "  force-domain: [console.5gpn.test]\n", "  force-domain: [console.5gpn.test]\n  skip-domain: [+.example.test]\n", 1),
		strings.Replace(valid, "TLS:  { ports: [443, 8080, 8443, 5060] }", "TLS:  { ports: [8443, 5060] }", 1),
		strings.Replace(valid, "TLS:  { ports: [443, 8080, 8443, 5060] }", "TLS:  { ports: [443, 8080, 8443, 5060], override-destination: false }", 1),
		strings.Replace(valid, "QUIC: { ports: [443, 5060] }", "QUIC: { ports: [5060] }", 1),
		strings.Replace(valid, "QUIC: { ports: [443, 5060] }", "QUIC: { ports: [443, 5060], override-destination: false }", 1),
		strings.Replace(valid, "target: console.5gpn.test:443", "target: other.5gpn.test:443", 1),
	}
	for _, broken := range brokenConfigs {
		err := ValidateInvariants(broken, p)
		var missing *ErrMissingInfra
		if !errors.As(err, &missing) || missing.Name != "gateway-inbound" {
			t.Fatalf("unsafe hostname target error = %v, want gateway-inbound", err)
		}
	}
}

func TestMihomoInvariants_AllNamedGatewayListenersMustBeSafe(t *testing.T) {
	valid := goldenMihomoConfig()
	first := "  - {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.5gpn.test:443}\n"
	unsafeNamed := strings.Replace(valid, first, first+
		"  - {name: gateway-2, type: tunnel, listen: 203.0.113.11, port: 443, network: [tcp, udp], target: other.5gpn.test:443}\n", 1)
	err := ValidateInvariants(unsafeNamed, goldenInfraParams())
	var missing *ErrMissingInfra
	if !errors.As(err, &missing) || missing.Name != "gateway-inbound" {
		t.Fatalf("unsafe named gateway error = %v, want gateway-inbound", err)
	}

	custom := strings.Replace(valid, first, first+
		"  - {name: operator-tunnel, type: tunnel, listen: 203.0.113.11, port: 443, network: [tcp], target: other.example.test:443}\n", 1)
	if err := ValidateInvariants(custom, goldenInfraParams()); err != nil {
		t.Fatalf("an additional operator-owned non-gateway listener should remain valid: %v", err)
	}
}

func TestMihomoInvariants_LegacyLoopbackGatewayRemainsValid(t *testing.T) {
	legacy := goldenMihomoConfig()
	for _, port := range []string{"443", "80", "8080", "8443", "5060"} {
		legacy = strings.Replace(legacy, "target: console.5gpn.test:"+port+"}", "target: 127.0.0.1:"+port+"}", 1)
	}
	legacy = strings.Replace(legacy, "  force-domain: [console.5gpn.test]\n",
		"  skip-src-address: [0.0.0.0/0]\n  skip-domain: [+.example.test]\n", 1)
	if err := ValidateInvariants(legacy, goldenInfraParams()); err != nil {
		t.Fatalf("legacy operator-owned loopback listener should remain valid: %v", err)
	}
}

func TestMihomoSeedPanelFallbackRejectsPrecedeDirect(t *testing.T) {
	cfg := goldenMihomoConfig()
	for _, tc := range []struct {
		name   string
		reject string
		direct string
	}{
		{
			name:   "console UDP",
			reject: "  - AND,((DOMAIN,console.5gpn.test),(NETWORK,UDP)),REJECT\n",
			direct: "  - DOMAIN,console.5gpn.test,DIRECT\n",
		},
		{
			name:   "console HTTP",
			reject: "  - AND,((DOMAIN,console.5gpn.test),(DST-PORT,80)),REJECT\n",
			direct: "  - DOMAIN,console.5gpn.test,DIRECT\n",
		},
		{
			name:   "console alternate HTTP",
			reject: "  - AND,((DOMAIN,console.5gpn.test),(DST-PORT,8080)),REJECT\n",
			direct: "  - DOMAIN,console.5gpn.test,DIRECT\n",
		},
		{
			name:   "console alternate HTTPS",
			reject: "  - AND,((DOMAIN,console.5gpn.test),(DST-PORT,8443)),REJECT\n",
			direct: "  - DOMAIN,console.5gpn.test,DIRECT\n",
		},
		{
			name:   "console speedtest",
			reject: "  - AND,((DOMAIN,console.5gpn.test),(DST-PORT,5060)),REJECT\n",
			direct: "  - DOMAIN,console.5gpn.test,DIRECT\n",
		},
		{
			name:   "zashboard UDP",
			reject: "  - AND,((DOMAIN,zash.5gpn.test),(NETWORK,UDP)),REJECT\n",
			direct: "  - AND,((DOMAIN,zash.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n",
		},
		{
			name:   "zashboard HTTP",
			reject: "  - AND,((DOMAIN,zash.5gpn.test),(DST-PORT,80)),REJECT\n",
			direct: "  - AND,((DOMAIN,zash.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n",
		},
		{
			name:   "zashboard alternate HTTP",
			reject: "  - AND,((DOMAIN,zash.5gpn.test),(DST-PORT,8080)),REJECT\n",
			direct: "  - AND,((DOMAIN,zash.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n",
		},
		{
			name:   "zashboard alternate HTTPS",
			reject: "  - AND,((DOMAIN,zash.5gpn.test),(DST-PORT,8443)),REJECT\n",
			direct: "  - AND,((DOMAIN,zash.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n",
		},
		{
			name:   "zashboard speedtest",
			reject: "  - AND,((DOMAIN,zash.5gpn.test),(DST-PORT,5060)),REJECT\n",
			direct: "  - AND,((DOMAIN,zash.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n",
		},
	} {
		rejectAt, directAt := strings.Index(cfg, tc.reject), strings.Index(cfg, tc.direct)
		if rejectAt < 0 || directAt < 0 || rejectAt >= directAt {
			t.Errorf("%s fallback reject must be present before its DIRECT rule", tc.name)
		}
	}
}

func TestMihomoSeedUsesFastRejectGuards(t *testing.T) {
	cfg := goldenMihomoConfig()
	if strings.Contains(cfg, "REJECT-DROP") {
		t.Fatal("seed config must not retain connections with REJECT-DROP")
	}
	for _, want := range []string{
		"DOMAIN,zash.5gpn.test,REJECT",
		"AND,((DOMAIN,console.5gpn.test),(DST-PORT,5060)),REJECT",
		"AND,((DOMAIN,zash.5gpn.test),(DST-PORT,5060)),REJECT",
		"AND,((NETWORK,UDP),(DST-PORT,443)),REJECT",
		"IP-CIDR,10.0.1.20/32,REJECT,no-resolve",
		"IP-CIDR,127.0.0.0/8,REJECT,no-resolve",
		"IP-CIDR,10.0.0.0/8,REJECT,no-resolve",
		"IP-CIDR,172.16.0.0/12,REJECT,no-resolve",
		"IP-CIDR,192.168.0.0/16,REJECT,no-resolve",
		"IP-CIDR,100.64.0.0/10,REJECT,no-resolve",
		"IP-CIDR,169.254.0.0/16,REJECT,no-resolve",
	} {
		if !strings.Contains(cfg, want) {
			t.Errorf("seed config is missing fast reject guard %q", want)
		}
	}
}

func TestMihomoInvariants_DenyActionRemainsOperatorOwned(t *testing.T) {
	cfg := goldenMihomoConfig()
	cfg = strings.Replace(cfg,
		"  - DOMAIN,zash.5gpn.test,REJECT\n",
		"  - DOMAIN,zash.5gpn.test,REJECT-DROP\n", 1)
	cfg = strings.Replace(cfg,
		"  - IP-CIDR,10.0.1.20/32,REJECT,no-resolve\n",
		"  - IP-CIDR,10.0.1.20/32,REJECT-DROP,no-resolve\n", 1)
	if err := ValidateInvariants(cfg, goldenInfraParams()); err != nil {
		t.Fatalf("operator-owned REJECT-DROP guards should remain structurally valid: %v", err)
	}
}

func TestMihomoInvariants_ConsoleSNIMustStayPublicAndDirect(t *testing.T) {
	p := goldenInfraParams()
	withConsole := goldenMihomoConfig()
	if err := ValidateInvariants(withConsole, p); err != nil {
		t.Fatalf("valid public console split rejected: %v", err)
	}

	for _, broken := range []string{
		strings.Replace(withConsole, "  console.5gpn.test: 127.0.0.1\n", "", 1),
		strings.Replace(withConsole, "  - DOMAIN,console.5gpn.test,DIRECT\n", "", 1),
		strings.Replace(withConsole, "  - DOMAIN,console.5gpn.test,DIRECT\n",
			"  - AND,((DOMAIN,console.5gpn.test),(RULE-SET,whitelist,DIRECT,src)),DIRECT\n", 1),
		strings.Replace(withConsole, "  - DOMAIN,console.5gpn.test,DIRECT\n",
			"  - DOMAIN,console.5gpn.test,DIRECT\n  - DOMAIN,console.5gpn.test,REJECT\n", 1),
		strings.Replace(withConsole, "  - DOMAIN,console.5gpn.test,DIRECT\n",
			"  - DOMAIN,console.5gpn.test,DIRECT\n  - DOMAIN,console.5gpn.test,REJECT-DROP\n", 1),
	} {
		err := ValidateInvariants(broken, p)
		var missing *ErrMissingInfra
		if !errors.As(err, &missing) || missing.Name != "console-sni" {
			t.Fatalf("broken console split error = %v, want console-sni", err)
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
		"- {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.5gpn.test:443}",
		"- name:    gateway\n    type: tunnel\n    listen: 203.0.113.10\n    port:   443\n    network: [tcp, udp]\n    target:      console.5gpn.test:443",
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
	cfg = strings.Replace(cfg, "certificate: /etc/5gpn/cert/zash/current/fullchain.pem", "certificate: '/etc/5gpn/cert/zash/current/fullchain.pem'", 1)
	cfg = strings.Replace(cfg, "private-key: /etc/5gpn/cert/zash/current/privkey.pem", `private-key: "/etc/5gpn/cert/zash/current/privkey.pem"`, 1)

	if err := ValidateInvariants(cfg, goldenInfraParams()); err != nil {
		t.Fatalf("quoted controller scalars should still pass: %v", err)
	}
}

func TestMihomoInvariants_FlowStyleTLSStillPasses(t *testing.T) {
	cfg := strings.Replace(goldenMihomoConfig(),
		"tls:\n  certificate: /etc/5gpn/cert/zash/current/fullchain.pem\n  private-key: /etc/5gpn/cert/zash/current/privkey.pem\n",
		"tls: {certificate: /etc/5gpn/cert/zash/current/fullchain.pem, private-key: /etc/5gpn/cert/zash/current/privkey.pem}\n", 1)
	if err := ValidateInvariants(cfg, goldenInfraParams()); err != nil {
		t.Fatalf("flow-style TLS map should remain valid: %v", err)
	}
}

func TestMihomoInvariants_RejectsStructuralDecoys(t *testing.T) {
	cfg := strings.Replace(goldenMihomoConfig(),
		"  - {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.5gpn.test:443}\n",
		"", 1)
	cfg += "\ndecoy:\n  type: tunnel\n  port: 443\n  target: 127.0.0.1:443\n"

	err := ValidateInvariants(cfg, goldenInfraParams())
	var missing *ErrMissingInfra
	if !errors.As(err, &missing) || missing.Name != "gateway-inbound" {
		t.Fatalf("nested listener decoy error = %v, want gateway-inbound", err)
	}
}

func TestMihomoInvariants_RejectsInvalidYAMLDocuments(t *testing.T) {
	for _, tc := range []struct {
		name string
		text string
	}{
		{
			name: "duplicate top-level key",
			text: strings.Replace(goldenMihomoConfig(), "secret: 's3cr3t'\n", "secret: 's3cr3t'\nsecret: attacker\n", 1),
		},
		{
			name: "duplicate nested key",
			text: strings.Replace(goldenMihomoConfig(),
				"  certificate: /etc/5gpn/cert/zash/current/fullchain.pem\n",
				"  certificate: /etc/5gpn/cert/zash/current/fullchain.pem\n  certificate: /tmp/decoy.pem\n", 1),
		},
		{
			name: "multiple documents",
			text: goldenMihomoConfig() + "\n---\nsecret: attacker\n",
		},
		{
			name: "malformed yaml",
			text: goldenMihomoConfig() + "\nbroken: [\n",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateInvariants(tc.text, goldenInfraParams())
			if err == nil || !strings.Contains(err.Error(), "invalid mihomo YAML") {
				t.Fatalf("error = %v, want invalid mihomo YAML", err)
			}
		})
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
				return strings.Replace(cfg, "/etc/5gpn/cert/zash/current/fullchain.pem", "/tmp/controller.pem", 1)
			},
			wantName: "controller",
		},
		{
			name: "controller private key changed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "/etc/5gpn/cert/zash/current/privkey.pem", "/tmp/controller.key", 1)
			},
			wantName: "controller",
		},
		{
			name: "nested TLS decoy rejected",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					"tls:\n  certificate: /etc/5gpn/cert/zash/current/fullchain.pem\n  private-key: /etc/5gpn/cert/zash/current/privkey.pem\n",
					"tls:\n  nested:\n    certificate: /etc/5gpn/cert/zash/current/fullchain.pem\n    private-key: /etc/5gpn/cert/zash/current/privkey.pem\n", 1)
			},
			wantName: "controller",
		},
		{
			name: "gateway tunnel listener removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					"  - {name: gateway, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.5gpn.test:443}\n",
					"", 1)
			},
			wantName: "gateway-inbound",
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
			name: "console public DIRECT rule removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg,
					"  - DOMAIN,console.5gpn.test,DIRECT\n",
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
			name: "zash deny guard removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "  - DOMAIN,zash.5gpn.test,REJECT\n", "", 1)
			},
			wantName: "zash-sni",
		},
		{
			// Zashboard remains source-allowlisted, so its AND(...)-shaped rule
			// is still a required invariant.
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
				return strings.Replace(cfg, "secret: 's3cr3t'", "secret: 'attacker-controlled'", 1)
			},
			wantName: "controller-secret",
		},
		{
			name: "anti-loop gateway guard removed",
			mutate: func(cfg string) string {
				return strings.Replace(cfg, "  - IP-CIDR,10.0.1.20/32,REJECT,no-resolve\n", "", 1)
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
// and so are satisfied by the golden config regardless of InfraParams. The
// hostname-targeted gateway check now depends on the exact console domain, so
// it is the first parameter-dependent check to fail against empty parameters.
func TestMihomoInvariants_EmptyInfraParamsFailClosed(t *testing.T) {
	err := ValidateInvariants(goldenMihomoConfig(), InfraParams{})
	if err == nil {
		t.Fatalf("expected an error for a wholly-empty InfraParams")
	}
	var mi *ErrMissingInfra
	if !errors.As(err, &mi) {
		t.Fatalf("expected *ErrMissingInfra, got %T: %v", err, err)
	}
	if mi.Name != "gateway-inbound" {
		t.Fatalf("expected the first param-dependent check (gateway-inbound) to fail first, got %q", mi.Name)
	}
}

func TestMihomoConfigStore_ReadAndDefault(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "mihomo")
	if err := os.Mkdir(dir, 0o770); err != nil {
		t.Fatalf("create config directory: %v", err)
	}
	path := filepath.Join(dir, "config.yaml")
	store := NewMihomoConfigStore(path)

	if store.Path() != path {
		t.Fatalf("Path() = %q, want %q", store.Path(), path)
	}
	if store.Dir() != dir {
		t.Fatalf("Dir() = %q, want %q", store.Dir(), dir)
	}
	wantBackupPath := filepath.Join(root, ".mihomo-config.yaml.bak")
	if store.BackupPath() != wantBackupPath {
		t.Fatalf("BackupPath() = %q, want %q", store.BackupPath(), wantBackupPath)
	}
	if store.BackupPath() == store.Path()+".bak" {
		t.Fatal("daemon backup must not reuse the legacy config-directory path")
	}
	productionStore := NewMihomoConfigStore(filepath.FromSlash("/etc/5gpn/mihomo/config.yaml"))
	wantProductionBackup := filepath.FromSlash("/etc/5gpn/.mihomo-config.yaml.bak")
	if productionStore.BackupPath() != wantProductionBackup {
		t.Fatalf("production BackupPath() = %q, want %q", productionStore.BackupPath(), wantProductionBackup)
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

	t.Setenv("DNS_BASE_DOMAIN", "5gpn.test")
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

func TestMihomoConfigDefaultPreservesSpecialControllerSecrets(t *testing.T) {
	for _, secret := range []string{
		"actual # secret",
		`controller"secret`,
		`controller\secret`,
		"controller'secret",
		"12345",
	} {
		t.Run(secret, func(t *testing.T) {
			t.Setenv("DNS_BASE_DOMAIN", "5gpn.test")
			t.Setenv("DNS_MIHOMO_LISTEN_IPS", "203.0.113.10")
			t.Setenv("DNS_GATEWAY_IP", "10.0.1.20")
			t.Setenv("DNS_MIHOMO_SECRET", secret)
			got := NewMihomoConfigStore(filepath.Join(t.TempDir(), "config.yaml")).Default()
			parsed, err := parseMihomoRootSecret([]byte(got))
			if err != nil {
				t.Fatalf("parse rendered secret: %v", err)
			}
			if parsed != secret {
				t.Fatalf("rendered secret = %q, want %q", parsed, secret)
			}
			infra := goldenInfraParams()
			infra.ControllerSecret = secret
			if err := ValidateInvariants(got, infra); err != nil {
				t.Fatalf("special-secret seed violates invariants: %v", err)
			}
		})
	}
}

func TestInfraParamsFromConfig(t *testing.T) {
	cfg := Config{
		ConsoleDomain:    "console.5gpn.test",
		ZashDomain:       "zash.5gpn.test",
		MihomoController: "127.0.0.1:9090",
		EgressBrokerAddr: "127.0.0.1:5354",
	}
	cfg.GatewayIP = net.ParseIP("10.0.1.20")
	p := InfraParamsFromConfig(cfg)
	want := InfraParams{
		ConsoleDomain: "console.5gpn.test",
		ZashDomain:    "zash.5gpn.test",
		GatewayIP:     "10.0.1.20",
	}
	if p != want {
		t.Fatalf("InfraParamsFromConfig = %+v, want %+v", p, want)
	}
}

func TestInfraParamsFromConfig_EmptyGateway(t *testing.T) {
	p := InfraParamsFromConfig(Config{})
	if p.GatewayIP != "" {
		t.Fatalf("GatewayIP = %q, want empty", p.GatewayIP)
	}
}

func TestMihomoConfigDefaultRendersPluralListeners(t *testing.T) {
	t.Setenv("DNS_BASE_DOMAIN", "5gpn.test")
	t.Setenv("DNS_GATEWAY_IP", "10.0.1.20")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "10.0.1.20, 203.0.113.10,10.0.1.20")
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")

	got := NewMihomoConfigStore(filepath.Join(t.TempDir(), "config.yaml")).Default()
	for _, want := range []string{
		"name: gateway, type: tunnel, listen: 10.0.1.20, port: 443, network: [tcp, udp], target: console.5gpn.test:443",
		"name: gateway80, type: tunnel, listen: 10.0.1.20, port: 80, network: [tcp], target: console.5gpn.test:80",
		"name: gateway8080, type: tunnel, listen: 10.0.1.20, port: 8080, network: [tcp], target: console.5gpn.test:8080",
		"name: gateway8443, type: tunnel, listen: 10.0.1.20, port: 8443, network: [tcp], target: console.5gpn.test:8443",
		"name: gateway5060, type: tunnel, listen: 10.0.1.20, port: 5060, network: [tcp, udp], target: console.5gpn.test:5060",
		"name: gateway-2, type: tunnel, listen: 203.0.113.10, port: 443, network: [tcp, udp], target: console.5gpn.test:443",
		"name: gateway80-2, type: tunnel, listen: 203.0.113.10, port: 80, network: [tcp], target: console.5gpn.test:80",
		"name: gateway8080-2, type: tunnel, listen: 203.0.113.10, port: 8080, network: [tcp], target: console.5gpn.test:8080",
		"name: gateway8443-2, type: tunnel, listen: 203.0.113.10, port: 8443, network: [tcp], target: console.5gpn.test:8443",
		"name: gateway5060-2, type: tunnel, listen: 203.0.113.10, port: 5060, network: [tcp, udp], target: console.5gpn.test:5060",
		"TLS:  { ports: [443, 8080, 8443, 5060] }",
		"QUIC: { ports: [443, 5060] }",
		"HTTP: { ports: [80, 8080, 8443, 5060] }",
		"AND,((DOMAIN,console.5gpn.test),(DST-PORT,8080)),REJECT",
		"AND,((DOMAIN,console.5gpn.test),(DST-PORT,8443)),REJECT",
		"AND,((DOMAIN,zash.5gpn.test),(DST-PORT,8080)),REJECT",
		"AND,((DOMAIN,zash.5gpn.test),(DST-PORT,8443)),REJECT",
		"AND,((DOMAIN,console.5gpn.test),(DST-PORT,5060)),REJECT",
		"AND,((DOMAIN,zash.5gpn.test),(DST-PORT,5060)),REJECT",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("Default() missing %q", want)
		}
	}
	if strings.Contains(got, "__MIHOMO_LISTENERS__") || strings.Contains(got, "__PUBLIC_IP__") {
		t.Fatal("Default() left an unresolved listener token")
	}
	for _, forbidden := range []string{
		"port: 8080, network: [tcp, udp]",
		"port: 8443, network: [tcp, udp]",
	} {
		if strings.Contains(got, forbidden) {
			t.Errorf("Default() unexpectedly enables UDP in %q", forbidden)
		}
	}
}

func TestMihomoConfigDefaultRequiresExplicitSafeListeners(t *testing.T) {
	setInfra := func() InfraParams {
		t.Setenv("DNS_BASE_DOMAIN", "5gpn.test")
		t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
		return goldenInfraParams()
	}
	p := setInfra()
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "")
	t.Setenv("DNS_GATEWAY_IP", "10.0.1.20")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")
	def := NewMihomoConfigStore(filepath.Join(t.TempDir(), "config.yaml")).Default()
	err := ValidateInvariants(def, p)
	var missing *ErrMissingInfra
	if !errors.As(err, &missing) || missing.Name != "gateway-inbound" {
		t.Fatalf("empty explicit listener error = %v, want gateway-inbound", err)
	}
	if strings.Contains(def, "listen: 203.0.113.10") {
		t.Fatal("DNS_PUBLIC_IP must not be used as an implicit listener")
	}

	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "0.0.0.0")
	def = NewMihomoConfigStore(filepath.Join(t.TempDir(), "config.yaml")).Default()
	err = ValidateInvariants(def, p)
	if !errors.As(err, &missing) || missing.Name != "gateway-inbound" {
		t.Fatalf("unsafe explicit listener error = %v, want gateway-inbound", err)
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
