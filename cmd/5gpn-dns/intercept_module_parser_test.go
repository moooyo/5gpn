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
traffic:
  captureHosts:
    - api.example.com
    - "*.cdn.example.com"
  upstreamMappings:
    - host: api.example.com
      target: origin.example.net
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
	if got := strings.Join(module.CaptureHosts, ","); got != "*.cdn.example.com,api.example.com" {
		t.Fatalf("capture hosts = %q", got)
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

func TestRepositoryWLOCManifestIsInstallableFromURL(t *testing.T) {
	t.Parallel()
	manifest, err := os.ReadFile(filepath.Join("..", "..", "extensions", "apple-wloc", "extension.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	script, err := os.ReadFile(filepath.Join("..", "..", "extensions", "apple-wloc", "wloc.js"))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/extension.yaml":
			_, _ = w.Write(manifest)
		case "/wloc.js":
			_, _ = w.Write(script)
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()
	module, err := (interceptModuleParser{client: server.Client(), now: time.Now}).Import(context.Background(), interceptModuleImportRequest{URL: server.URL + "/extension.yaml"})
	if err != nil {
		t.Fatal(err)
	}
	if module.ID != "io.5gpn.apple-wloc" || len(module.Settings) != 2 || len(module.Scripts) != 1 || module.Enabled {
		t.Fatalf("repository WLOC extension = %+v", module)
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
