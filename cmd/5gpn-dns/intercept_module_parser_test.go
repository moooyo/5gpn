package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestInterceptModuleParserImportsSurgeSnapshotWithQXHeaders(t *testing.T) {
	t.Parallel()
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "Quantumult X" || r.Header.Get("Referer") != defaultModuleReferer {
			t.Errorf("fetch headers = UA %q Referer %q", r.Header.Get("User-Agent"), r.Header.Get("Referer"))
		}
		switch r.URL.Path {
		case "/module.sgmodule":
			fmt.Fprintf(w, `#!name=Response Cleaner
#!desc=synthetic parser fixture
[Script]
clean = type=http-response,pattern=^https://api\.example\.com/v1,requires-body=1,script-path=%s/clean.js,timeout=2
[Header Rewrite]
^https://api\.example\.com/ header-del Cookie
[MITM]
hostname = %%APPEND%% api.example.com, *.cdn.example.com
`, server.URL)
		case "/clean.js":
			_, _ = w.Write([]byte(`$done({body: $response.body.replace("secret", "redacted")});`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parser := interceptModuleParser{
		client: server.Client(),
		now:    func() time.Time { return time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC) },
	}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{
		URL:          server.URL + "/module.sgmodule",
		Format:       "auto",
		FetchProfile: interceptFetchQuantumultX,
		Referer:      defaultModuleReferer,
	})
	if err != nil {
		t.Fatal(err)
	}
	if module.Format != interceptModuleFormatSurge || module.Name != "Response Cleaner" || len(module.Scripts) != 1 || len(module.Headers) != 1 {
		t.Fatalf("parsed module = %+v", module)
	}
	if len(module.ID) != len("mod-")+32 {
		t.Fatalf("module id = %q", module.ID)
	}
	if got := strings.Join(module.Hosts, ","); got != "*.cdn.example.com,api.example.com" {
		t.Fatalf("hosts = %q", got)
	}
	if module.Scripts[0].TimeoutMS != 2000 || !module.Scripts[0].RequiresBody || module.Scripts[0].ScriptDigest != sha256Hex([]byte(module.Scripts[0].ScriptBody)) {
		t.Fatalf("script snapshot = %+v", module.Scripts[0])
	}
	if module.Source.Digest != sha256Hex([]byte(module.Source.Body)) || module.ImportedAt != "2026-07-18T00:00:00Z" {
		t.Fatalf("source snapshot = %+v", module.Source)
	}
}

func TestInterceptModuleParserImportsLoonAndReportsUnsupportedSections(t *testing.T) {
	t.Parallel()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`$done({headers: $request.headers});`))
	}))
	defer server.Close()
	content := fmt.Sprintf(`#!name=Loon Fixture
[Script]
http-request ^https://service\.example\.com/ script-path=%s/script.js, requires-body=true, timeout=1, tag=Request, enable=true, argument=[{player},{scheme}]
[Rewrite]
^https://service\.example\.com/old https://service.example.com/new 302
[Rule]
DOMAIN,service.example.com,DIRECT
[MITM]
hostname = service.example.com
`, server.URL)
	parser := interceptModuleParser{client: server.Client(), now: time.Now}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{
		Content:        content,
		Format:         interceptModuleFormatLoon,
		FetchProfile:   interceptFetchStandard,
		PartialAllowed: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if module.Format != interceptModuleFormatLoon || len(module.Scripts) != 1 || len(module.Rewrites) != 1 {
		t.Fatalf("parsed Loon module = %+v", module)
	}
	if module.Scripts[0].Argument != "[{player},{scheme}]" {
		t.Fatalf("script argument = %q", module.Scripts[0].Argument)
	}
	if len(module.Unsupported) != 1 || !strings.Contains(strings.ToLower(module.Unsupported[0]), "[rule]") {
		t.Fatalf("unsupported = %v", module.Unsupported)
	}
}

func TestInterceptModuleParserRejectsUnsafeAndIncompleteModules(t *testing.T) {
	t.Parallel()
	parser := interceptModuleParser{now: time.Now}
	for name, request := range map[string]interceptModuleImportRequest{
		"non-https URL": {URL: "http://example.com/module.sgmodule", Format: "auto", FetchProfile: interceptFetchStandard},
		"missing MITM":  {Content: "#!name=Empty\n[Rule]\nDOMAIN,example.com,DIRECT\n", Format: "surge", FetchProfile: interceptFetchStandard},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parser.Import(context.Background(), request); err == nil {
				t.Fatal("expected import rejection")
			}
		})
	}
}
