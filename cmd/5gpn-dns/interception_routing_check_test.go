package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestInterceptionRoutingCheckAcceptsCurrentSeed(t *testing.T) {
	document := installerRoutingCheckDocument()
	mihomo := currentInstallerRoutingSeed(t, document)
	code, stdout, stderr := runInstallerRoutingCheck(t, mihomo, mustMarshalInstallerInterceptConfig(t, document))
	if code != 0 || stdout != "ready\n" || stderr != "" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

// Routing lives in the overlay, so a config carrying no anchors cannot be
// managed whatever else is wrong with it, and the check says exactly that
// rather than diagnosing a shape no longer worth telling apart.
func TestInterceptionRoutingCheckRejectsUnanchoredConfig(t *testing.T) {
	unanchored := `listeners: []
proxies: []
proxy-groups:
  - {name: Proxies, type: select, proxies: [DIRECT]}
rules:
  - MATCH,Proxies
`
	code, stdout, stderr := runInstallerRoutingCheck(t, unanchored, mustMarshalInstallerInterceptConfig(t, installerRoutingCheckDocument()))
	if code != 3 || stdout != "not-anchored\n" || stderr != "" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

// The fail-closed boundary is a position, not a rule set: the overlay carries
// every managed rule, so what the check still has to catch is an operator rule
// interposed where declined processor traffic would reach it.
func TestInterceptionRoutingCheckRejectsRulesInterposedAtTheBoundary(t *testing.T) {
	document := installerRoutingCheckDocument()
	mihomo := currentInstallerRoutingSeed(t, document)
	residualEgress := "AND,((IN-NAME,intercept-egress),(DOMAIN,example.com),(DST-PORT,443)),Proxies"
	interposed := strings.Replace(mihomo, "  - "+interceptEgressRejectRule, "  - "+residualEgress+"\n  - "+interceptEgressRejectRule, 1)
	if interposed == mihomo {
		t.Fatal("the egress terminator was not found, so this test proves nothing")
	}
	code, stdout, stderr := runInstallerRoutingCheck(t, interposed, mustMarshalInstallerInterceptConfig(t, document))
	if code != 3 || stdout != "overlay-egress-anchor-misplaced\n" || stderr != "" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	unanchoredWithResidual := `listeners: []
proxies: []
proxy-groups:
  - {name: Proxies, type: select, proxies: [DIRECT]}
rules:
  - AND,((DOMAIN,example.com),(DST-PORT,443)),MODULE-INTERCEPT
  - MATCH,Proxies
`
	code, stdout, stderr = runInstallerRoutingCheck(t, unanchoredWithResidual, mustMarshalInstallerInterceptConfig(t, document))
	if code != 3 || stdout != "not-anchored\n" || stderr != "" {
		t.Fatalf("unanchored residual code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestInterceptionRoutingCheckRejectsCredentialMismatch(t *testing.T) {
	document := installerRoutingCheckDocument()
	mihomo := currentInstallerRoutingSeed(t, document)
	mihomo = strings.Replace(mihomo, document.Password, "different-sidecar-password-012345678901234", 1)
	code, stdout, stderr := runInstallerRoutingCheck(t, mihomo, mustMarshalInstallerInterceptConfig(t, document))
	if code != 3 || stdout != "credential-mismatch\n" || stderr != "" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestInterceptionRoutingCheckRejectsInvalidFiles(t *testing.T) {
	validDocument := installerRoutingCheckDocument()
	validMihomo := currentInstallerRoutingSeed(t, validDocument)
	tests := []struct {
		name       string
		mihomo     string
		intercept  []byte
		wantReason string
	}{
		{
			name:       "invalid interception JSON",
			mihomo:     validMihomo,
			intercept:  []byte(`{"version":`),
			wantReason: "intercept-config-invalid\n",
		},
		{
			name:       "invalid mihomo YAML",
			mihomo:     "listeners: [",
			intercept:  mustMarshalInstallerInterceptConfig(t, validDocument),
			wantReason: "mihomo-config-invalid\n",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			code, stdout, stderr := runInstallerRoutingCheck(t, test.mihomo, test.intercept)
			if code != 1 || stdout != test.wantReason || stderr == "" {
				t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
			}
		})
	}
}

func TestInterceptionRoutingCheckCLIExitContract(t *testing.T) {
	executable := filepath.Join(t.TempDir(), "5gpn-dns-routing-check")
	if runtime.GOOS == "windows" {
		executable += ".exe"
	}
	build := exec.Command("go", "build", "-o", executable, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build command binary: %v: %s", err, output)
	}

	document := installerRoutingCheckDocument()
	ready := currentInstallerRoutingSeed(t, document)
	unanchored := "listeners: []\nproxies: []\nproxy-groups:\n  - {name: Proxies, type: select, proxies: [DIRECT]}\nrules:\n  - MATCH,Proxies\n"
	tests := []struct {
		name          string
		mihomo        string
		intercept     []byte
		wantCode      int
		wantStdout    string
		wantStderrSet bool
	}{
		{name: "ready", mihomo: ready, intercept: mustMarshalInstallerInterceptConfig(t, document), wantCode: 0, wantStdout: "ready\n"},
		{name: "not-anchored", mihomo: unanchored, intercept: mustMarshalInstallerInterceptConfig(t, document), wantCode: 3, wantStdout: "not-anchored\n"},
		{name: "invalid", mihomo: ready, intercept: []byte(`{"version":`), wantCode: 1, wantStdout: "intercept-config-invalid\n", wantStderrSet: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			mihomoPath := filepath.Join(dir, "config.yaml")
			interceptPath := filepath.Join(dir, "intercept.json")
			if err := os.WriteFile(mihomoPath, []byte(test.mihomo), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(interceptPath, test.intercept, 0o600); err != nil {
				t.Fatal(err)
			}
			command := exec.Command(executable, "--check-interception-routing",
				"--mihomo-config", mihomoPath, "--intercept-config", interceptPath)
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			command.Stdout = &stdout
			command.Stderr = &stderr
			err := command.Run()
			code := 0
			if err != nil {
				exitError, ok := err.(*exec.ExitError)
				if !ok {
					t.Fatalf("run command: %v", err)
				}
				code = exitError.ExitCode()
			}
			if code != test.wantCode || stdout.String() != test.wantStdout || (stderr.Len() > 0) != test.wantStderrSet {
				t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
		})
	}
}

func installerRoutingCheckDocument() interceptConfigDocument {
	return interceptConfigDocument{
		Version:        interceptConfigVersion,
		Listen:         "127.0.0.1:18080",
		Username:       "sidecar-user-0123456789",
		Password:       "sidecar-password-01234567890123456789",
		TLSCert:        "/etc/5gpn/intercept/tls/fullchain.pem",
		TLSKey:         "/etc/5gpn/intercept/tls/privkey.pem",
		UpstreamProxy:  interceptProxyConfig{Address: "127.0.0.1:17890", Username: "upstream-user-0123456789", Password: "upstream-password-01234567890123456789"},
		MITM:           interceptMITMSettings{HTTP2: true, QUICFallbackProtection: true},
		ExecutionOrder: []string{},
		Modules:        []interceptModuleSnapshot{},
	}
}

// currentInstallerRoutingSeed renders the one arrangement the installer
// produces: the template's literal anchors plus the runtime block that resolves
// them.
func currentInstallerRoutingSeed(t *testing.T, document interceptConfigDocument) string {
	t.Helper()
	body, err := os.ReadFile(filepath.Join("..", "..", "etc", "mihomo", "config.yaml.tmpl"))
	if err != nil {
		t.Fatal(err)
	}
	replacements := map[string]string{
		"__MIHOMO_LISTENERS__":            "",
		"__CONTROLLER_SECRET__":           "controller-secret",
		"__CONSOLE_DOMAIN__":              "console.example.com",
		"__ZASH_DOMAIN__":                 "zash.example.com",
		"__GATEWAY_IP__":                  "192.0.2.1",
		"__INTERCEPT_INBOUND_USERNAME__":  document.Username,
		"__INTERCEPT_INBOUND_PASSWORD__":  document.Password,
		"__INTERCEPT_UPSTREAM_USERNAME__": document.UpstreamProxy.Username,
		"__INTERCEPT_UPSTREAM_PASSWORD__": document.UpstreamProxy.Password,
	}
	text := renderSeedOverlayBlock(string(body), testOverlayRuntimeBlock())
	for from, to := range replacements {
		text = strings.ReplaceAll(text, from, to)
	}
	return text
}

func mustMarshalInstallerInterceptConfig(t *testing.T, document interceptConfigDocument) []byte {
	t.Helper()
	body, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func runInstallerRoutingCheck(t *testing.T, mihomo string, intercept []byte) (int, string, string) {
	t.Helper()
	dir := t.TempDir()
	mihomoPath := filepath.Join(dir, "config.yaml")
	interceptPath := filepath.Join(dir, "intercept.json")
	if err := os.WriteFile(mihomoPath, []byte(mihomo), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(interceptPath, intercept, 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := runInterceptionRoutingCheck([]string{
		"--mihomo-config", mihomoPath,
		"--intercept-config", interceptPath,
	}, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

// The CLI reports readiness; this pins what the analyser hands the manager
// behind it. Without a terminal MATCH target extracted from the operator's own
// rules there is no egress winner to mint a capability against.
func TestInterceptionRoutingCheckAcceptsAnchoredSeed(t *testing.T) {
	document := installerRoutingCheckDocument()
	seed := currentInstallerRoutingSeed(t, document)
	if !mihomoConfigIsOverlayAnchored(seed) {
		t.Fatal("the anchored seed does not read as anchored")
	}
	analysis := analyzeOverlayAnchoredDocument(seed)
	if !analysis.Manageable || !analysis.Ready {
		t.Fatalf("anchored seed rejected: %s", analysis.Reason)
	}
	if analysis.MatchTarget == "" {
		t.Fatal("no terminal MATCH target was extracted, so no capability could be minted")
	}
}

// Anchor placement is the security property, not formatting. An egress anchor
// separated from the fail-closed terminator leaves rules that processor traffic
// reaches after the overlay declines it and before the deny catches it — the
// fall-through the terminator exists to prevent.
func TestOverlayEgressAnchorMustAbutTheTerminator(t *testing.T) {
	document := installerRoutingCheckDocument()
	seed := currentInstallerRoutingSeed(t, document)

	moved := strings.Replace(seed,
		"  - "+overlayEgressAnchorRule+"\n  - "+interceptEgressRejectRule,
		"  - "+overlayEgressAnchorRule+"\n  - DOMAIN,interposed.example.com,DIRECT\n  - "+interceptEgressRejectRule,
		1)
	if moved == seed {
		t.Fatal("the anchor/terminator pair was not found, so this test proves nothing")
	}
	if analysis := analyzeOverlayAnchoredDocument(moved); analysis.Manageable {
		t.Fatal("a rule interposed between the egress anchor and the terminator was accepted")
	} else if analysis.Reason != "overlay-egress-anchor-misplaced" {
		t.Fatalf("reason = %q, want overlay-egress-anchor-misplaced", analysis.Reason)
	}
}

// A missing client anchor must not read as "no capture configured": under the
// overlay it means captured traffic reaches the operator's own routing instead
// of the processor.
func TestOverlayClientAnchorIsRequired(t *testing.T) {
	document := installerRoutingCheckDocument()
	seed := currentInstallerRoutingSeed(t, document)
	stripped := strings.Replace(seed, "  - "+overlayClientAnchorRule+"\n", "", 1)
	if stripped == seed {
		t.Fatal("the client anchor was not found, so this test proves nothing")
	}
	if analysis := analyzeOverlayAnchoredDocument(stripped); analysis.Manageable {
		t.Fatal("a config with no client anchor was accepted as manageable")
	} else if analysis.Reason != "overlay-client-anchor-missing" {
		t.Fatalf("reason = %q, want overlay-client-anchor-missing", analysis.Reason)
	}
}
