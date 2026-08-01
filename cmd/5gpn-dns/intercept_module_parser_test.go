package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
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
  network: true
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
	if !module.EgressGroupRequired || !module.Network {
		t.Fatalf("network capabilities = network=%v required=%v", module.Network, module.EgressGroupRequired)
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

// loadPublishedPolicyDigests reads the extension repository's generated
// marketplace index and returns the policy digest each entry published.
//
// Produce one with:
//
//	(cd /path/to/5gpn-extensions && node scripts/generate-marketplace.mjs \
//	   --revision "$(git rev-parse HEAD)" --output /tmp/index.json)
func loadPublishedPolicyDigests(t *testing.T, path string) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var index struct {
		Entries []struct {
			ID     string `json:"id"`
			Policy struct {
				Digest string `json:"digest"`
			} `json:"policy"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(raw, &index); err != nil {
		t.Fatal(err)
	}
	digests := make(map[string]string, len(index.Entries))
	for _, entry := range index.Entries {
		digests[entry.ID] = entry.Policy.Digest
	}
	if len(digests) == 0 {
		t.Fatal("the marketplace index carries no entries, so this proves nothing")
	}
	return digests
}

func TestExternalMaintainedExtensionsAreInstallableFromURL(t *testing.T) {
	root := strings.TrimSpace(os.Getenv("FIVEGPN_EXTENSIONS_ROOT"))
	if root == "" {
		t.Skip("FIVEGPN_EXTENSIONS_ROOT is not set")
	}
	// When a generated index is supplied, this also becomes the cross-
	// implementation agreement test the policy digest exists for: the publisher
	// compiles every manifest with typed-policy.mjs and the gateway compiles it
	// again here. validateMarketplaceInstall compares the two on every install,
	// so a divergence has to fail in CI rather than at an operator's gateway.
	var publishedPolicy map[string]string
	if indexPath := strings.TrimSpace(os.Getenv("FIVEGPN_MARKETPLACE_INDEX")); indexPath != "" {
		publishedPolicy = loadPublishedPolicyDigests(t, indexPath)
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
			// An extension may point an action at a published bundle on a real
			// host instead of shipping the script beside its manifest. The test
			// server's own client trusts only its self-signed certificate, so it
			// cannot verify that host and the import fails on the fetch rather
			// than on anything this test is checking. Trust both: the fixture
			// certificate for the manifest, and the system roots for whatever
			// external source the manifest names.
			module, importErr := (interceptModuleParser{client: externalAwareTestClient(t, server), now: time.Now}).Import(
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
			if publishedPolicy != nil {
				published, listed := publishedPolicy[module.ID]
				if !listed {
					t.Fatalf("extension %q is not in the generated marketplace index", module.ID)
				}
				projection, projectErr := overlayProjectModule(module)
				if projectErr != nil {
					t.Fatalf("this extension cannot be carried by a generation: %v", projectErr)
				}
				if got := overlayPolicyDigest(projection); got != published {
					t.Fatalf("policy digest %s does not match the published %s: the publisher's compiler and the gateway's disagree about what this manifest enforces", got, published)
				}
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

// ipASN was a primary selector no consumer could carry: the sidecar's strict
// decoder has no such field, overlayPolicyRule never reads it, and the extension
// repository's validator rejects the key. A manifest could declare it, the
// review would render it as an enforced deny, and the generation would not carry
// it. The project has one contract, so the field is gone rather than
// half-implemented, and an old manifest fails as an unknown field.
func TestNativeExtensionParserRejectsRetiredASNSelector(t *testing.T) {
	t.Parallel()
	parser := interceptModuleParser{now: time.Now}
	_, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: nativeRoutingManifest(`    - action: reject
      ipASN: 4808`)})
	if err == nil {
		t.Fatal("a routing rule selecting on ipASN was accepted; nothing downstream can enforce it")
	}
	if !strings.Contains(err.Error(), "ipASN") {
		t.Fatalf("rejection must name the field the manifest used, got %v", err)
	}
}

// yaml.v3 decodes .nan and .inf straight into a number setting's *float64
// bounds, and the ordering check catches neither: NaN > NaN is false, and so is
// 1 > +Inf. A non-finite bound reaching the snapshot makes
// interceptModuleSnapshotDigest panic -- by design, since encoding/json cannot
// represent it -- on a path that digests bytes fetched from the publisher's own
// URL.
func TestNativeExtensionParserRejectsNonFiniteNumberBounds(t *testing.T) {
	t.Parallel()
	parser := interceptModuleParser{now: time.Now}
	base := nativeRoutingManifest(`    - action: reject
      domain: ads.example.com`)
	for name, bound := range map[string]string{
		"nan minimum":       "    min: .nan",
		"nan maximum":       "    max: .nan",
		"positive infinity": "    max: .inf",
		"negative infinity": "    min: -.inf",
	} {
		name, bound := name, bound
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			manifest := base + `settings:
  - key: threshold
    type: number
    label: Threshold
` + bound + "\n"
			module, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: manifest})
			if err == nil {
				t.Fatalf("a non-finite bound was accepted: %+v", module.Settings)
			}
			if !strings.Contains(err.Error(), "finite") {
				t.Fatalf("rejection must say the bound is not finite, got %v", err)
			}
		})
	}
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

func TestNativeExtensionParserRejectsInvalidNetworkPermissionShape(t *testing.T) {
	t.Parallel()
	base := `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.network
  name: Network fixture
  version: 1.0.0
permissions:
  persistentStorage: false
  network: true
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
	// The permission is a boolean. Anything shaped like the old list is an
	// unknown field or a type error, and both are refused rather than ignored:
	// silently dropping one would import an extension whose author believed the
	// grant was narrower than it is.
	for name, content := range map[string]string{
		"origin list":     strings.Replace(base, "network: true", "network:\n    origins: [https://api.example.com]", 1),
		"any form":        strings.Replace(base, "network: true", "network:\n    any: true", 1),
		"wrong type":      strings.Replace(base, "network: true", "network: yes-please", 1),
		"nested unknowns": strings.Replace(base, "network: true", "network:\n    wildcard: true", 1),
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
	module.Network = true
	if got := interceptModuleSnapshotDigest(module); got == baseline {
		t.Fatal("immutable network capability did not change snapshot digest")
	}
	module.Network = false
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

func proxyCompatEntryManifest(entry string) string {
	return `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.compat
  name: Compat fixture
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
actions:
  - id: run-bundle
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      inline: "$done($response)"
      bodyMode: text
      entry: ` + entry + `
      timeoutMs: 1000
      maxBodyBytes: 1024
`
}

func TestNativeExtensionParserAcceptsProxyCompatEntry(t *testing.T) {
	t.Parallel()
	snapshot, err := (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: proxyCompatEntryManifest("proxy-compat")})
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Scripts) != 1 {
		t.Fatalf("scripts = %d, want 1", len(snapshot.Scripts))
	}
	if snapshot.Scripts[0].Entry != interceptScriptEntryProxyCompat {
		t.Fatalf("entry = %q, want %q", snapshot.Scripts[0].Entry, interceptScriptEntryProxyCompat)
	}
}

func TestNativeExtensionParserNormalizesTheDefaultEntry(t *testing.T) {
	t.Parallel()
	// An explicit "native" and an omitted entry are the same contract, so both
	// store the empty value and no snapshot digest depends on which was written.
	for _, entry := range []string{"native", `""`} {
		snapshot, err := (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: proxyCompatEntryManifest(entry)})
		if err != nil {
			t.Fatalf("entry %q: %v", entry, err)
		}
		if snapshot.Scripts[0].Entry != "" {
			t.Fatalf("entry %q stored %q, want the native default", entry, snapshot.Scripts[0].Entry)
		}
	}
}

func TestNativeExtensionParserRejectsAnUnknownEntry(t *testing.T) {
	t.Parallel()
	_, err := (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: proxyCompatEntryManifest("surge")})
	if err == nil || !strings.Contains(err.Error(), "entry") {
		t.Fatalf("err = %v, want an entry rejection", err)
	}
}

func networkCapabilityManifest(permission string) string {
	return `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.capability
  name: Capability fixture
  version: 1.0.0
permissions:
  persistentStorage: false
  network: ` + permission + `
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
}

func TestNativeExtensionParserAcceptsTheNetworkCapability(t *testing.T) {
	t.Parallel()
	// One boolean. Reachable hosts are not enumerable -- an operator configures
	// some of them at runtime -- so the manifest no longer pretends to list them.
	snapshot, err := (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: networkCapabilityManifest("true")})
	if err != nil {
		t.Fatal(err)
	}
	if !snapshot.Network {
		t.Fatal("network capability was not snapshotted")
	}
}

func TestNativeExtensionParserRejectsANetworkOriginList(t *testing.T) {
	t.Parallel()
	// The list is gone from the schema, and an unknown field is refused rather
	// than ignored: a manifest still carrying one would otherwise import with a
	// grant broader than the origins it thought it was asking for.
	_, err := (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: strings.Replace(
		networkCapabilityManifest("true"), "  network: true", "  network:\n    origins: [https://api.example.net]", 1)})
	if err == nil {
		t.Fatal("err = nil, want an origin list to be refused")
	}
}

// externalAwareTestClient trusts the fixture server's certificate alongside the
// system roots, so a manifest that names an external script source is fetched
// for real instead of failing certificate verification against a pool that only
// contains the test server.
func externalAwareTestClient(t *testing.T, server *httptest.Server) *http.Client {
	t.Helper()
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	if certificate := server.Certificate(); certificate != nil {
		pool.AddCert(certificate)
	}
	return &http.Client{
		Timeout:   30 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool}},
	}
}

func jqActionManifest(program, bodyMode, extra string) string {
	return `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.jq
  name: JQ fixture
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
actions:
  - id: clean-json
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      jq: '` + program + `'
      bodyMode: ` + bodyMode + `
      timeoutMs: 1000
      maxBodyBytes: 1024
` + extra
}

func TestNativeExtensionParserCarriesAJQProgram(t *testing.T) {
	t.Parallel()
	// The upstream expression is the implementation. Carrying it verbatim is the
	// point: translating each published rule into JavaScript produced code this
	// repository then owned and re-derived on every upstream revision.
	program := "del(.data.payment)"
	snapshot, err := (interceptModuleParser{now: time.Now}).Import(
		context.Background(),
		interceptModuleImportRequest{Content: jqActionManifest(program, "text", "")},
	)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Scripts[0].JQProgram != program {
		t.Fatalf("jq program = %q, want %q", snapshot.Scripts[0].JQProgram, program)
	}
	if snapshot.Scripts[0].ScriptBody != "" || snapshot.Scripts[0].ScriptDigest != "" {
		t.Fatal("a jq action must carry no script snapshot")
	}
}

func TestNativeExtensionParserRejectsAJQProgramWithAScript(t *testing.T) {
	t.Parallel()
	// Carrying both would leave which one runs undefined.
	extra := "      inline: \"function transform(context) { return null }\"\n"
	_, err := (interceptModuleParser{now: time.Now}).Import(
		context.Background(),
		interceptModuleImportRequest{Content: jqActionManifest("del(.a)", "text", extra)},
	)
	if err == nil || !strings.Contains(err.Error(), "more than one action kind") {
		t.Fatalf("err = %v, want the pairing refused", err)
	}
}

func TestNativeExtensionParserRejectsAJQProgramOnABinaryBody(t *testing.T) {
	t.Parallel()
	// jq transforms a JSON document; a binary body has none to transform.
	_, err := (interceptModuleParser{now: time.Now}).Import(
		context.Background(),
		interceptModuleImportRequest{Content: jqActionManifest("del(.a)", "binary", "")},
	)
	if err == nil || !strings.Contains(err.Error(), "bodyMode") {
		t.Fatalf("err = %v, want a text body required", err)
	}
}

func declarativeActionManifest(scriptBlock string) string {
	return `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.declarative
  name: Declarative fixture
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
actions:
  - id: act
    phase: request
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
` + scriptBlock
}

func TestNativeExtensionParserCarriesRejectAndMock(t *testing.T) {
	t.Parallel()
	// Both carry what the published modules declare -- reject-dict and
	// mock-response-body -- and neither ships a script snapshot for review.
	reject, err := (interceptModuleParser{now: time.Now}).Import(
		context.Background(),
		interceptModuleImportRequest{Content: declarativeActionManifest("      reject: true\n      bodyMode: none\n")},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !reject.Scripts[0].Reject || reject.Scripts[0].ScriptBody != "" {
		t.Fatalf("reject action = %+v, want a reject carrying no script", reject.Scripts[0])
	}

	mock, err := (interceptModuleParser{now: time.Now}).Import(
		context.Background(),
		interceptModuleImportRequest{Content: declarativeActionManifest(
			"      mock:\n        status: 200\n        headers:\n          Content-Type: application/json\n        body: '{}'\n      bodyMode: none\n")},
	)
	if err != nil {
		t.Fatal(err)
	}
	if mock.Scripts[0].Mock == nil || mock.Scripts[0].Mock.Body != "{}" || mock.Scripts[0].Mock.Status != 200 {
		t.Fatalf("mock action = %+v", mock.Scripts[0].Mock)
	}
	if mock.Scripts[0].Mock.Headers["Content-Type"] != "application/json" {
		t.Fatalf("mock headers = %v", mock.Scripts[0].Mock.Headers)
	}
}

func TestNativeExtensionParserRejectsMoreThanOneActionKind(t *testing.T) {
	t.Parallel()
	// Carrying two would leave which one runs undefined.
	_, err := (interceptModuleParser{now: time.Now}).Import(
		context.Background(),
		interceptModuleImportRequest{Content: declarativeActionManifest("      reject: true\n      jq: 'del(.a)'\n      bodyMode: text\n")},
	)
	if err == nil || !strings.Contains(err.Error(), "more than one") {
		t.Fatalf("err = %v, want the pairing refused", err)
	}
}

func TestNativeExtensionParserRefusesAMockThatCouldInjectHeaders(t *testing.T) {
	t.Parallel()
	// A newline in a header value would let a mock put further headers, or a
	// second response, onto the wire. A raw newline is folded away by YAML
	// itself; the vector that survives is a double-quoted escape, so that is
	// what is tested. The fragment is a raw literal so the backslashes reach
	// the YAML parser rather than the Go one.
	fragment := "      mock:\n        headers:\n          X-Bad: " + `"a\r\nY: b"` + "\n        body: '{}'\n      bodyMode: none\n"
	_, err := (interceptModuleParser{now: time.Now}).Import(
		context.Background(),
		interceptModuleImportRequest{Content: declarativeActionManifest(fragment)},
	)
	if err == nil || !strings.Contains(err.Error(), "newline") {
		t.Fatalf("err = %v, want the header refused", err)
	}
}

func TestNativeExtensionParserCarriesTheDeclarativeRewriteKinds(t *testing.T) {
	t.Parallel()
	// Header edits, rewrites, and regex body replacement all reach the sidecar
	// without a script snapshot. The camelCase manifest key has to survive into
	// the snake_case wire field, which is the join a typo would break silently.
	cases := []struct {
		name  string
		block string
		check func(*testing.T, interceptScriptRule)
	}{
		{"headers", "      headers:\n        set:\n          Grpc-Status: '0'\n        remove: [Content-Encoding]\n      bodyMode: none\n",
			func(t *testing.T, rule interceptScriptRule) {
				if rule.Headers.Set["Grpc-Status"] != "0" || len(rule.Headers.Remove) != 1 {
					t.Fatalf("headers = %+v", rule.Headers)
				}
			}},
		{"rewrite", "      rewrite:\n        pattern: '^https://a[.]example[.]com/(.*)$'\n        to: 'https://b.example.net/$1'\n        status: 307\n      bodyMode: none\n",
			func(t *testing.T, rule interceptScriptRule) {
				if rule.Rewrite.Status != 307 || rule.Rewrite.To != "https://b.example.net/$1" {
					t.Fatalf("rewrite = %+v", rule.Rewrite)
				}
			}},
		{"replaceBody", "      replaceBody:\n        pattern: 'x'\n        to: 'y{{settings.k}}'\n        valueMap:\n          k:\n            a: 'b'\n      bodyMode: text\n",
			func(t *testing.T, rule interceptScriptRule) {
				if rule.ReplaceBody.ValueMap["k"]["a"] != "b" {
					t.Fatalf("valueMap = %+v", rule.ReplaceBody.ValueMap)
				}
			}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			snapshot, err := (interceptModuleParser{now: time.Now}).Import(
				context.Background(),
				interceptModuleImportRequest{Content: declarativeActionManifest(testCase.block)},
			)
			if err != nil {
				t.Fatal(err)
			}
			if snapshot.Scripts[0].ScriptBody != "" {
				t.Fatal("a declarative action must carry no script snapshot")
			}
			testCase.check(t, snapshot.Scripts[0])
		})
	}
}

func TestNativeExtensionParserRefusesAnInvalidRewriteStatus(t *testing.T) {
	t.Parallel()
	_, err := (interceptModuleParser{now: time.Now}).Import(
		context.Background(),
		interceptModuleImportRequest{Content: declarativeActionManifest(
			"      rewrite:\n        to: 'https://b.example.net/'\n        status: 301\n      bodyMode: none\n")},
	)
	if err == nil || !strings.Contains(err.Error(), "302") {
		t.Fatalf("err = %v, want 301 refused", err)
	}
}

// An upstream plugin format switches a script entry on and off from outside the
// script, so a bundle never reads the key that gates it. Carrying that key as an
// ordinary setting gave an extension a switch that did nothing at all. These
// cases hold the contract that makes it mean something on import.
func TestNativeExtensionParserBindsActionGateToARequiredBooleanSetting(t *testing.T) {
	t.Parallel()
	manifest := func(gate string, settings string) string {
		return `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.gate
  name: Gate fixture
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
settings:
` + settings + `actions:
  - id: gated
    phase: response
` + gate + `    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      jq: .
      bodyMode: text
      timeoutMs: 1000
      maxBodyBytes: 1024
`
	}
	booleanSetting := func(required bool) string {
		return "  - key: airborne\n    type: boolean\n    required: " +
			map[bool]string{true: "true", false: "false"}[required] + "\n    default: true\n"
	}
	importManifest := func(t *testing.T, body string) (interceptModuleSnapshot, error) {
		t.Helper()
		return (interceptModuleParser{now: time.Now}).Import(context.Background(), interceptModuleImportRequest{Content: body})
	}

	for _, testCase := range []struct {
		name     string
		gate     string
		settings string
		want     string
	}{
		{"undeclared", "    enabledWhen:\n      key: airborne\n      equals: \"true\"\n", "", "not a setting this extension declares"},
		{"malformed key", "    enabledWhen:\n      key: not a key\n      equals: \"true\"\n", booleanSetting(true), "not a valid setting key"},
		{"valueless", "    enabledWhen:\n      key: airborne\n", booleanSetting(true), "no value to compare against"},
		{"unreachable boolean", "    enabledWhen:\n      key: airborne\n      equals: maybe\n", booleanSetting(true), "cannot equal"},
		{
			"unreachable option", "    enabledWhen:\n      key: mode\n      equals: Cloud\n",
			"  - key: mode\n    type: select\n    required: true\n    options: [Script, Worker]\n    default: Script\n",
			"has no option",
		},
		{"optional", "    enabledWhen:\n      key: airborne\n      equals: \"true\"\n", booleanSetting(false), "must name a required setting"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			if _, err := importManifest(t, manifest(testCase.gate, testCase.settings)); err == nil || !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("error = %v, want %q", err, testCase.want)
			}
		})
	}

	snapshot, err := importManifest(t, manifest("    enabledWhen:\n      key: airborne\n      equals: \"true\"\n", booleanSetting(true)))
	if err != nil {
		t.Fatalf("valid gate rejected: %v", err)
	}
	if got := snapshot.Scripts[0].EnabledWhen; got == nil || got.Key != "airborne" || got.Equals != "true" {
		t.Fatalf("stored gate = %+v; it must reach the sidecar document", got)
	}
	body, err := json.Marshal(snapshot.Scripts[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `"enabled_when":{"key":"airborne","equals":"true"}`) {
		t.Fatalf("published action = %s", body)
	}

	ungated, err := importManifest(t, manifest("", booleanSetting(true)))
	if err != nil {
		t.Fatal(err)
	}
	body, err = json.Marshal(ungated.Scripts[0])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), "enabled_when") {
		t.Fatalf("ungated action carried the field to a sidecar that may not know it: %s", body)
	}
}
