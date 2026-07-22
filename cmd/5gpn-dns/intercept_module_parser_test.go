package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNativeExtensionParserImportsStrictManifestAndRelativeScript(t *testing.T) {
	t.Parallel()
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Header.Get("User-Agent") != nativeExtensionUserAgent || request.Header.Get("Referer") != "" {
			t.Errorf("fetch headers = UA %q Referer %q", request.Header.Get("User-Agent"), request.Header.Get("Referer"))
		}
		switch request.URL.Path {
		case "/extension.yaml":
			fmt.Fprint(w, `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.cleaner
  name: Response Cleaner
  version: 1.2.0
  description: Native fixture
permissions:
  persistentStorage: true
  network:
    origins:
      - HTTPS://Assets.Example.COM:443/
      - http://assets.example.com:8080
requirements:
  egressGroup:
    required: true
traffic:
  captureHosts:
    - api.example.com
    - "*.cdn.example.com"
  upstreamMappings:
    - host: api.example.com
      target: origin.example.net
  routingRules:
    - action: reject
      domainSuffix: ads.example.com
      domainKeywords: [tracker, stun]
      network: udp
      destinationPort: 443
    - action: direct
      ipCIDR: 203.0.113.7/32
settings:
  - key: mode
    type: select
    label: Mode
    required: true
    options: [clean, full]
    default: clean
actions:
  - id: clean-response
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/v1/
      statusCodes: [200]
    script:
      source: ./clean.js
      bodyMode: text
      timeoutMs: 2000
      maxBodyBytes: 1048576
`)
		case "/clean.js":
			fmt.Fprint(w, `function transform(context) { return { response: { body: context.response.body } } }`)
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()

	parser := interceptModuleParser{client: server.Client(), now: func() time.Time { return time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC) }}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{URL: server.URL + "/extension.yaml"})
	if err != nil {
		t.Fatal(err)
	}
	if module.ID != "io.example.cleaner" || module.Version != "1.2.0" || !module.PersistentStorage || len(module.Scripts) != 1 {
		t.Fatalf("parsed extension = %+v", module)
	}
	if !module.EgressGroupRequired || strings.Join(module.NetworkOrigins, ",") != "http://assets.example.com:8080,https://assets.example.com" {
		t.Fatalf("network capabilities = origins=%v required=%v", module.NetworkOrigins, module.EgressGroupRequired)
	}
	if got := strings.Join(module.CaptureHosts, ","); got != "*.cdn.example.com,api.example.com" || module.CaptureDNS != interceptCaptureDNSTrust {
		t.Fatalf("capture hosts/default DNS = %q/%q", got, module.CaptureDNS)
	}
	if module.Scripts[0].ScriptURL != server.URL+"/clean.js" || module.Scripts[0].BodyMode != "text" {
		t.Fatalf("action snapshot = %+v", module.Scripts[0])
	}
	if len(module.Settings) != 1 || string(module.Settings[0].Value) != `"clean"` {
		t.Fatalf("settings = %+v", module.Settings)
	}
	if len(module.HostMappings) != 1 || module.HostMappings[0].Target != "origin.example.net" {
		t.Fatalf("upstream mappings = %+v", module.HostMappings)
	}
	if len(module.RoutingRules) != 2 || module.RoutingRules[0].Action != "reject" ||
		strings.Join(module.RoutingRules[0].DomainKeywords, ",") != "stun,tracker" || module.RoutingRules[1].IPCIDR != "203.0.113.7/32" {
		t.Fatalf("routing rules = %+v", module.RoutingRules)
	}
}

func TestNativeExtensionParserAcceptsInlineLocalScriptAndLocationSetting(t *testing.T) {
	t.Parallel()
	content := `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.location
  name: Location fixture
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [location.example.com]
settings:
  - key: location
    type: location
    required: true
    default:
      accuracy: 25
actions:
  - id: patch
    phase: response
    match:
      hosts: [location.example.com]
      schemes: [https]
      pathRegex: ^/location$
    script:
      inline: |
        function transform(context) {
          return { response: { body: context.response.body } }
        }
      bodyMode: binary
      timeoutMs: 1000
      maxBodyBytes: 8388608
`
	module, err := (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: content})
	if err != nil {
		t.Fatal(err)
	}
	if module.Source.URL != "" || module.Scripts[0].ScriptURL != "" || module.Scripts[0].BodyMode != "binary" {
		t.Fatalf("local extension = %+v", module)
	}
	if interceptModuleSettingsReady(module.Settings) {
		t.Fatal("required location without coordinates was marked ready")
	}
}

func TestExternalMaintainedExtensionsAreInstallableFromURL(t *testing.T) {
	root := strings.TrimSpace(os.Getenv("FIVEGPN_EXTENSIONS_ROOT"))
	if root == "" {
		t.Skip("FIVEGPN_EXTENSIONS_ROOT is not set")
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	seenIDs := make(map[string]string)
	validated := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		directory := filepath.Join(root, entry.Name())
		if _, err := os.Stat(filepath.Join(directory, "extension.yaml")); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			t.Fatal(err)
		}
		t.Run(entry.Name(), func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
				requested := strings.TrimPrefix(request.URL.Path, "/")
				if requested == "" || filepath.Base(requested) != requested || strings.Contains(requested, "..") {
					http.NotFound(w, request)
					return
				}
				body, readErr := os.ReadFile(filepath.Join(directory, requested))
				if readErr != nil {
					http.NotFound(w, request)
					return
				}
				_, _ = w.Write(body)
			}))
			defer server.Close()
			module, importErr := (interceptModuleParser{client: server.Client(), now: time.Now}).Import(
				context.Background(),
				interceptModuleImportRequest{URL: server.URL + "/extension.yaml"},
			)
			if importErr != nil {
				t.Fatal(importErr)
			}
			if previous, duplicate := seenIDs[module.ID]; duplicate {
				t.Fatalf("extension id %q is also used by %s", module.ID, previous)
			}
			seenIDs[module.ID] = entry.Name()
			if module.Enabled || len(module.CaptureHosts) == 0 || len(module.Scripts)+len(module.HostMappings) == 0 {
				t.Fatalf("invalid maintained extension snapshot: %+v", module)
			}
			validated++
		})
	}
	if validated == 0 {
		t.Fatal("no maintained extensions were found")
	}
}

func TestNativeExtensionParserRejectsUnknownFieldsAndUnsafeYAML(t *testing.T) {
	t.Parallel()
	base := `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.fixture
  name: Fixture
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
actions:
  - id: pass
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      inline: "function transform() { return null }"
      bodyMode: none
      timeoutMs: 1000
      maxBodyBytes: 1024
`
	parser := interceptModuleParser{now: time.Now}
	for name, content := range map[string]string{
		"unknown field":      strings.Replace(base, "kind: Extension", "kind: Extension\nlegacy: true", 1),
		"multiple documents": base + "---\n{}\n",
		"anchor":             strings.Replace(base, "captureHosts: [api.example.com]", "captureHosts: &hosts [api.example.com]", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: content}); err == nil {
				t.Fatalf("%s was accepted", name)
			}
		})
	}
}

func TestNativeExtensionParserRejectsExplicitNullRoutingFields(t *testing.T) {
	t.Parallel()
	parser := interceptModuleParser{now: time.Now}
	nullRules := map[string]string{
		"action":            "    - action: null\n      domain: ads.example.com",
		"domain":            "    - action: reject\n      domain: null\n      allDomainKeywords: [ads]",
		"domainSuffix":      "    - action: reject\n      domainSuffix: null\n      allDomainKeywords: [ads]",
		"domainKeywords":    "    - action: reject\n      domain: ads.example.com\n      domainKeywords: null",
		"allDomainKeywords": "    - action: reject\n      domain: ads.example.com\n      allDomainKeywords: null",
		"ipCIDR":            "    - action: reject\n      domain: ads.example.com\n      ipCIDR: null",
		"network":           "    - action: reject\n      domain: ads.example.com\n      network: null",
		"destinationPort":   "    - action: reject\n      domain: ads.example.com\n      destinationPort: null",
	}
	for field, routingRule := range nullRules {
		field, routingRule := field, routingRule
		t.Run(field, func(t *testing.T) {
			t.Parallel()
			_, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: nativeRoutingManifest(routingRule)})
			if err == nil || !strings.Contains(err.Error(), field+" must not be null") {
				t.Fatalf("explicit null %s error = %v", field, err)
			}
		})
	}
}

func TestNativeExtensionParserRoutingRulesCollectionPresence(t *testing.T) {
	t.Parallel()
	parser := interceptModuleParser{now: time.Now}
	base := nativeRoutingManifest(`    - action: reject
      domain: ads.example.com`)
	block := `  routingRules:
    - action: reject
      domain: ads.example.com
`
	for name, replacement := range map[string]string{
		"omitted": "",
		"empty":   "  routingRules: []\n",
	} {
		name, replacement := name, replacement
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			module, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: strings.Replace(base, block, replacement, 1)})
			if err != nil {
				t.Fatal(err)
			}
			if len(module.RoutingRules) != 0 {
				t.Fatalf("routing rules = %+v", module.RoutingRules)
			}
		})
	}

	nullManifest := strings.Replace(base, block, "  routingRules: null\n", 1)
	if _, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: nullManifest}); err == nil || !strings.Contains(err.Error(), "traffic.routingRules must not be null") {
		t.Fatalf("null routingRules error = %v", err)
	}
}

func TestNativeExtensionParserNormalizesRoutingDomainsBeforeStorage(t *testing.T) {
	t.Parallel()
	parser := interceptModuleParser{now: time.Now}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: nativeRoutingManifest(`    - action: REJECT
      domain: " Ads.Example.COM. "
      network: UDP`)})
	if err != nil {
		t.Fatal(err)
	}
	if len(module.RoutingRules) != 1 || module.RoutingRules[0].Domain != "ads.example.com" || module.RoutingRules[0].Network != "udp" {
		t.Fatalf("normalized routing rules = %+v", module.RoutingRules)
	}

	_, err = parser.Import(context.Background(), interceptModuleImportRequest{Content: nativeRoutingManifest(`    - action: reject
      domain: ads.example.123`)})
	if err == nil || !strings.Contains(err.Error(), "canonical exact hostname") {
		t.Fatalf("numeric TLD error = %v", err)
	}
}

func nativeRoutingManifest(routingRule string) string {
	return `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.routing
  name: Routing fixture
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
  routingRules:
` + routingRule + `
actions:
  - id: pass
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      inline: "function transform() { return null }"
      bodyMode: none
      timeoutMs: 1000
      maxBodyBytes: 1024
`
}

func TestNativeExtensionParserEnforcesCaptureBoundary(t *testing.T) {
	t.Parallel()
	manifest := `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.boundary
  name: Boundary fixture
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
actions:
  - id: escape
    phase: response
    match:
      hosts: [other.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      inline: "function transform() { return null }"
      bodyMode: none
      timeoutMs: 1000
      maxBodyBytes: 1024
`
	if _, err := (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: manifest}); err == nil || !strings.Contains(err.Error(), "outside capture_hosts") {
		t.Fatalf("capture boundary error = %v", err)
	}
}

func TestNativeExtensionAllowsMappingOnlyAction(t *testing.T) {
	t.Parallel()
	manifest := `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.upstream
  name: Upstream override
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
  upstreamMappings:
    - host: api.example.com
      target: origin.example.net
`
	module, err := (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: manifest})
	if err != nil {
		t.Fatal(err)
	}
	if len(module.Scripts) != 0 || len(module.HostMappings) != 1 {
		t.Fatalf("mapping-only extension = %+v", module)
	}
}

func TestNativeExtensionImportURLRequiresHTTPS(t *testing.T) {
	t.Parallel()
	for _, raw := range []string{"http://example.com/extension.yaml", "file:///tmp/extension.yaml", "not-a-url"} {
		if _, err := normalizeModuleImportURL(raw); err == nil {
			t.Fatalf("unsafe URL %q was accepted", raw)
		}
	}
}

func TestNormalizeInterceptNetworkOrigin(t *testing.T) {
	t.Parallel()
	for raw, want := range map[string]string{
		"HTTPS://API.Example.COM:443/": "https://api.example.com",
		"http://api.example.com:80":    "http://api.example.com",
		"https://api.example.com:8443": "https://api.example.com:8443",
		"http://api.example.com./":     "http://api.example.com",
	} {
		got, err := normalizeInterceptNetworkOrigin(raw)
		if err != nil || got != want {
			t.Errorf("normalize origin %q = %q, %v; want %q", raw, got, err, want)
		}
	}

	for _, raw := range []string{
		"ftp://api.example.com",
		"https://user@api.example.com",
		"https://api.example.com/path",
		"https://api.example.com?query",
		"https://api.example.com#fragment",
		"https://*.example.com",
		"https://127.0.0.1",
		"https://[2001:db8::1]",
		"https://localhost",
		"https://api.example.com:0",
		"https://api.example.com:65536",
	} {
		if got, err := normalizeInterceptNetworkOrigin(raw); err == nil {
			t.Errorf("unsafe origin %q normalized to %q", raw, got)
		}
	}
}

func TestNativeExtensionParserRejectsInvalidNetworkOriginShape(t *testing.T) {
	t.Parallel()
	base := `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.network
  name: Network fixture
  version: 1.0.0
permissions:
  persistentStorage: false
  network:
    origins: [https://api.example.com]
traffic:
  captureHosts: [api.example.com]
actions:
  - id: pass
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      inline: "function transform() { return null }"
      bodyMode: none
      timeoutMs: 1000
      maxBodyBytes: 1024
`
	parser := interceptModuleParser{now: time.Now}
	for name, content := range map[string]string{
		"unknown network field": strings.Replace(base, "origins: [https://api.example.com]", "origins: [https://api.example.com]\n    wildcard: true", 1),
		"wrong origins type":    strings.Replace(base, "origins: [https://api.example.com]", "origins: https://api.example.com", 1),
		"path is not origin":    strings.Replace(base, "https://api.example.com]", "https://api.example.com/path]", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: content}); err == nil {
				t.Fatalf("%s was accepted", name)
			}
		})
	}
}

func TestNativeExtensionParserRejectsInvalidEgressRequirementShape(t *testing.T) {
	t.Parallel()
	base := `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.requirement
  name: Requirement fixture
  version: 1.0.0
permissions:
  persistentStorage: false
requirements:
  egressGroup:
    required: true
traffic:
  captureHosts: [api.example.com]
actions:
  - id: pass
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      inline: "function transform() { return null }"
      bodyMode: none
      timeoutMs: 1000
      maxBodyBytes: 1024
`
	parser := interceptModuleParser{now: time.Now}
	for name, content := range map[string]string{
		"unknown requirement": strings.Replace(base, "required: true", "required: true\n    selector: Japan", 1),
		"wrong required type": strings.Replace(base, "required: true", "required: selected", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: content}); err == nil {
				t.Fatalf("%s was accepted", name)
			}
		})
	}
}

func TestNormalizeNativeExtensionRoutingRuleRejectsUnsafeShapes(t *testing.T) {
	t.Parallel()
	textValue := func(value string) *string { return &value }
	intValue := func(value int) *int { return &value }
	keywords := func(values ...string) *[]string { return &values }
	valid, err := normalizeNativeExtensionRoutingRule(nativeExtensionRoutingRule{
		Action: " REJECT ", DomainSuffix: textValue("Example.COM."), AllDomainKeywords: keywords("tracker", "-ad-"), Network: textValue(" UDP "), DestinationPort: intValue(443),
	})
	if err != nil {
		t.Fatal(err)
	}
	if valid.Action != "reject" || valid.DomainSuffix != "example.com" || strings.Join(valid.AllDomainKeywords, ",") != "-ad-,tracker" || valid.Network != "udp" {
		t.Fatalf("normalized routing rule = %+v", valid)
	}
	normalizedCIDR, err := normalizeNativeExtensionRoutingRule(nativeExtensionRoutingRule{Action: "reject", IPCIDR: textValue("118.89.204.198/23")})
	if err != nil || normalizedCIDR.IPCIDR != "118.89.204.0/23" {
		t.Fatalf("normalized CIDR = %+v, %v", normalizedCIDR, err)
	}
	singleKeyword, err := normalizeNativeExtensionRoutingRule(nativeExtensionRoutingRule{Action: "reject", DomainKeywords: keywords("ads")})
	if err != nil || len(singleKeyword.DomainKeywords) != 0 || strings.Join(singleKeyword.AllDomainKeywords, ",") != "ads" {
		t.Fatalf("normalized single keyword = %+v, %v", singleKeyword, err)
	}
	if err := validateInterceptRoutingRules([]interceptRoutingRule{
		singleKeyword,
		{Action: "reject", AllDomainKeywords: []string{"ads"}},
	}); err == nil || !strings.Contains(err.Error(), "duplicates") {
		t.Fatalf("semantic duplicate routing rules error = %v", err)
	}

	for name, raw := range map[string]nativeExtensionRoutingRule{
		"missing selector":        {Action: "reject"},
		"multiple primary":        {Action: "reject", Domain: textValue("api.example.com"), DomainSuffix: textValue("example.com")},
		"wildcard exact domain":   {Action: "reject", Domain: textValue("*.example.com")},
		"CIDR with keyword":       {Action: "reject", IPCIDR: textValue("203.0.113.0/24"), DomainKeywords: keywords("ads")},
		"invalid CIDR":            {Action: "reject", IPCIDR: textValue("203.0.113.7/99")},
		"matcher injection":       {Action: "reject", DomainKeywords: keywords("ads),MATCH")},
		"duplicate keyword group": {Action: "reject", DomainKeywords: keywords("ads"), AllDomainKeywords: keywords("ads")},
		"invalid action":          {Action: "proxy", Domain: textValue("api.example.com")},
		"invalid network":         {Action: "reject", Domain: textValue("api.example.com"), Network: textValue("quic")},
		"invalid port":            {Action: "reject", Domain: textValue("api.example.com"), DestinationPort: intValue(65536)},
		"explicit zero port":      {Action: "reject", Domain: textValue("api.example.com"), DestinationPort: intValue(0)},
		"explicit empty domain":   {Action: "reject", Domain: textValue("")},
		"explicit empty network":  {Action: "reject", Domain: textValue("api.example.com"), Network: textValue("")},
		"explicit empty keywords": {Action: "reject", Domain: textValue("api.example.com"), DomainKeywords: keywords()},
	} {
		t.Run(name, func(t *testing.T) {
			if got, err := normalizeNativeExtensionRoutingRule(raw); err == nil {
				t.Fatalf("unsafe routing rule was accepted: %+v", got)
			}
		})
	}
}

func TestInterceptNetworkOriginHostPortRequiresCanonicalOrigin(t *testing.T) {
	t.Parallel()
	host, port, err := interceptNetworkOriginHostPort("https://api.example.com:8443")
	if err != nil || host != "api.example.com" || port != 8443 {
		t.Fatalf("origin target = %q:%d, %v", host, port, err)
	}
	if _, _, err := interceptNetworkOriginHostPort("HTTPS://API.EXAMPLE.COM:443/"); err == nil {
		t.Fatal("non-canonical stored origin was accepted")
	}
}

func TestInterceptModuleSnapshotDigestExcludesOperatorBindings(t *testing.T) {
	t.Parallel()
	module := testModuleSnapshot()
	baseline := interceptModuleSnapshotDigest(module)
	module.EgressGroup = "Japan"
	if got := interceptModuleSnapshotDigest(module); got != baseline {
		t.Fatalf("operator egress binding changed snapshot digest: %s != %s", got, baseline)
	}
	module.CaptureDNS = interceptCaptureDNSChina
	if got := interceptModuleSnapshotDigest(module); got != baseline {
		t.Fatalf("operator capture DNS binding changed snapshot digest: %s != %s", got, baseline)
	}
	module.CaptureDNS = interceptCaptureDNSTrust
	module.NetworkOrigins = []string{"https://api.example.com"}
	if got := interceptModuleSnapshotDigest(module); got == baseline {
		t.Fatal("immutable network capability did not change snapshot digest")
	}
	module.NetworkOrigins = nil
	module.EgressGroupRequired = true
	if got := interceptModuleSnapshotDigest(module); got == baseline {
		t.Fatal("immutable egress requirement did not change snapshot digest")
	}
	module.EgressGroupRequired = false
	module.RoutingRules = []interceptRoutingRule{{Action: "reject", Domain: "ads.example.com"}}
	if got := interceptModuleSnapshotDigest(module); got == baseline {
		t.Fatal("immutable routing capability did not change snapshot digest")
	}
}

func TestValidateInterceptModulesBoundsEnabledRoutingRules(t *testing.T) {
	t.Parallel()
	modules := make([]interceptModuleSnapshot, 0, 33)
	for moduleIndex := 0; moduleIndex < 33; moduleIndex++ {
		module := testModuleSnapshot()
		module.ID = fmt.Sprintf("io.example.route%02d", moduleIndex)
		module.Enabled = true
		module.RoutingRules = make([]interceptRoutingRule, 0, 64)
		for ruleIndex := 0; ruleIndex < 64; ruleIndex++ {
			module.RoutingRules = append(module.RoutingRules, interceptRoutingRule{
				Action: "reject", Domain: fmt.Sprintf("r%d-%d.example.com", moduleIndex, ruleIndex),
			})
		}
		modules = append(modules, module)
	}
	if err := validateInterceptModules(modules[:32]); err != nil {
		t.Fatalf("exact active routing limit was rejected: %v", err)
	}
	if err := validateInterceptModules(modules); err == nil || !strings.Contains(err.Error(), "declared routing rules") {
		t.Fatalf("active routing overflow error = %v", err)
	}
}

func TestInterceptCaptureHostBoundsAre512(t *testing.T) {
	t.Parallel()
	hosts := make([]string, maxInterceptModuleHosts)
	for index := range hosts {
		hosts[index] = fmt.Sprintf("h%03d.example.com", index)
	}
	module := testModuleSnapshot()
	module.CaptureHosts = hosts
	module.Scripts[0].Match.Hosts = append([]string(nil), hosts...)
	if err := validateInterceptModule(module); err != nil {
		t.Fatalf("512 capture/action hosts rejected: %v", err)
	}
	module.CaptureHosts = append(module.CaptureHosts, "h512.example.com")
	module.Scripts[0].Match.Hosts = append(module.Scripts[0].Match.Hosts, "h512.example.com")
	if err := validateInterceptModule(module); err == nil || !strings.Contains(err.Error(), "512") {
		t.Fatalf("513 capture/action hosts error = %v", err)
	}
}

func TestInterceptGlobalCertificateHostBoundIs512(t *testing.T) {
	t.Parallel()
	makeModule := func(id, prefix string, count int) interceptModuleSnapshot {
		module := testModuleSnapshot()
		module.ID = id
		module.Enabled = true
		module.CaptureHosts = make([]string, count)
		for index := range module.CaptureHosts {
			module.CaptureHosts[index] = fmt.Sprintf("%s%03d.example.com", prefix, index)
		}
		module.Scripts[0].Match.Hosts = []string{module.CaptureHosts[0]}
		return module
	}
	first := makeModule("io.example.first", "a", 256)
	second := makeModule("io.example.second", "b", 256)
	document, _ := testInterceptDocument(t, first, second)
	if err := validateInterceptDocument(document); err != nil {
		t.Fatalf("512 certificate hosts rejected: %v", err)
	}
	second = makeModule("io.example.second", "b", 257)
	document.Modules[1] = second
	if err := validateInterceptDocument(document); err == nil || !strings.Contains(err.Error(), "512") {
		t.Fatalf("513 certificate hosts error = %v", err)
	}
}
