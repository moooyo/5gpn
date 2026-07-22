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

func TestInterceptionRoutingCheckClassifiesLegacyMainSeed(t *testing.T) {
	// This is the routing-significant shape of the main seed before the
	// interception listener, proxy, and fail-closed terminator were added.
	legacy := `listeners: []
proxies: []
proxy-groups:
  - {name: Proxies, type: select, proxies: [DIRECT]}
rules:
  - MATCH,Proxies
`
	code, stdout, stderr := runInstallerRoutingCheck(t, legacy, mustMarshalInstallerInterceptConfig(t, installerRoutingCheckDocument()))
	if code != 3 || stdout != "legacy-mihomo-boundary-missing-clean\n" || stderr != "" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestInterceptionRoutingCheckRejectsResidualManagedRulesWithDisabledMaster(t *testing.T) {
	document := installerRoutingCheckDocument()
	mihomo := currentInstallerRoutingSeed(t, document)
	residualEgress := "AND,((IN-NAME,intercept-egress),(DOMAIN,example.com),(DST-PORT,443)),Proxies"
	residualCapture := "AND,((DOMAIN,example.com),(DST-PORT,443)),MODULE-INTERCEPT"
	mihomo = strings.Replace(mihomo, "  - "+interceptEgressRejectRule, "  - "+residualEgress+"\n  - "+interceptEgressRejectRule, 1)
	mihomo = strings.Replace(mihomo, "  - MATCH,Proxies", "  - "+residualCapture+"\n  - MATCH,Proxies", 1)
	code, stdout, stderr := runInstallerRoutingCheck(t, mihomo, mustMarshalInstallerInterceptConfig(t, document))
	if code != 3 || stdout != "interception-egress-rules-out-of-sync\n" || stderr != "" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	legacyWithResidual := `listeners: []
proxies: []
proxy-groups:
  - {name: Proxies, type: select, proxies: [DIRECT]}
rules:
  - AND,((DOMAIN,example.com),(DST-PORT,443)),MODULE-INTERCEPT
  - MATCH,Proxies
`
	code, stdout, stderr = runInstallerRoutingCheck(t, legacyWithResidual, mustMarshalInstallerInterceptConfig(t, document))
	if code != 3 || stdout != "interception-listener-missing\n" || stderr != "" {
		t.Fatalf("legacy residual code=%d stdout=%q stderr=%q", code, stdout, stderr)
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
	legacy := "listeners: []\nproxies: []\nproxy-groups:\n  - {name: Proxies, type: select, proxies: [DIRECT]}\nrules:\n  - MATCH,Proxies\n"
	tests := []struct {
		name          string
		mihomo        string
		intercept     []byte
		wantCode      int
		wantStdout    string
		wantStderrSet bool
	}{
		{name: "ready", mihomo: ready, intercept: mustMarshalInstallerInterceptConfig(t, document), wantCode: 0, wantStdout: "ready\n"},
		{name: "legacy", mihomo: legacy, intercept: mustMarshalInstallerInterceptConfig(t, document), wantCode: 3, wantStdout: "legacy-mihomo-boundary-missing-clean\n"},
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
	text := string(body)
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
