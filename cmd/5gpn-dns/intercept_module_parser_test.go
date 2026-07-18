package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestInterceptModuleParserImportsLoonSnapshotWithAutomaticHeaders(t *testing.T) {
	t.Parallel()
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != moduleLoonUserAgent || r.Header.Get("Referer") != defaultModuleReferer {
			t.Errorf("fetch headers = UA %q Referer %q", r.Header.Get("User-Agent"), r.Header.Get("Referer"))
		}
		switch r.URL.Path {
		case "/module.lpx":
			fmt.Fprintf(w, `#!name=Response Cleaner
#!desc=synthetic parser fixture
[Script]
http-response ^https://api\.example\.com/v1 script-path=%s/clean.js,requires-body=true,timeout=2,tag=Cleaner
[Rewrite]
^https://api\.example\.com/old 302 https://api.example.com/new
[MITM]
hostname = api.example.com, *.cdn.example.com
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
		URL: server.URL + "/module.lpx",
	})
	if err != nil {
		t.Fatal(err)
	}
	if module.Name != "Response Cleaner" || len(module.Scripts) != 1 || len(module.Rewrites) != 1 {
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
#!input=appName
#!select=mode,clean,full
[Script]
http-request ^https://service\.example\.com/ script-path=%s/script.js, requires-body=true, binary-body-mode=true, timeout=1, tag=Request, enable=true, argument=[{player},{scheme}]
[Rewrite]
^https://service\.example\.com/old 302 https://service.example.com/new
^https://service\.example\.com/ header-del Cookie
^https://service\.example\.com/ header-add X-Module active
^https://service\.example\.com/ header-replace User-Agent Loon
[Host]
service.example.com = 8.8.8.8
[Rule]
DOMAIN,service.example.com,DIRECT
[MITM]
hostname = service.example.com
`, server.URL)
	parser := interceptModuleParser{client: server.Client(), now: time.Now}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{
		Content: content,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(module.Scripts) != 1 || len(module.Rewrites) != 1 || len(module.Headers) != 3 {
		t.Fatalf("parsed Loon module = %+v", module)
	}
	if module.Scripts[0].Argument != "[{player},{scheme}]" {
		t.Fatalf("script argument = %q", module.Scripts[0].Argument)
	}
	if !module.Scripts[0].BinaryBody {
		t.Fatal("binary-body-mode was not preserved")
	}
	if len(module.Parameters) != 2 || module.Parameters[0].Key != "appName" || module.Parameters[1].Key != "mode" || len(module.Parameters[1].Options) != 2 {
		t.Fatalf("parameters = %+v", module.Parameters)
	}
	if len(module.HostMappings) != 1 || module.HostMappings[0].Target != "8.8.8.8" {
		t.Fatalf("host mappings = %+v", module.HostMappings)
	}
	if len(module.Unsupported) != 1 || !strings.Contains(strings.ToLower(module.Unsupported[0]), "[rule]") {
		t.Fatalf("unsupported = %v", module.Unsupported)
	}
	if module.PartialAllowed {
		t.Fatal("partial compatibility must be acknowledged only after import")
	}
}

func TestInterceptModuleParserImportsLoonDeepLinkWithAutomaticHeaders(t *testing.T) {
	t.Parallel()
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != moduleLoonUserAgent || r.Header.Get("Referer") != defaultModuleReferer {
			t.Errorf("fetch headers = UA %q Referer %q", r.Header.Get("User-Agent"), r.Header.Get("Referer"))
			http.Error(w, "native Loon client required", http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/module.lpx":
			fmt.Fprintf(w, `#!name=Loon deep-link fixture
[Script]
http-response ^https://service\.example\.com/ script-path=%s/script.js,tag=Cleaner
[MITM]
hostname=service.example.com
`, server.URL)
		case "/script.js":
			_, _ = w.Write([]byte(`$done({body: $response.body});`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parser := interceptModuleParser{client: server.Client(), now: time.Now}
	nested := server.URL + "/module.lpx"
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{
		URL: "loon://import?plugin=" + url.QueryEscape(nested),
	})
	if err != nil {
		t.Fatal(err)
	}
	if module.Source.URL != nested || len(module.Scripts) != 1 {
		t.Fatalf("imported module = %+v", module)
	}
}

func TestInterceptModuleParserFlagsNetworkedScriptAsIncompatible(t *testing.T) {
	t.Parallel()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`$httpClient.get("https://example.com/", function() {});`))
	}))
	defer server.Close()
	content := fmt.Sprintf(`#!name=Networked fixture
[Script]
http-response ^https://api\.example\.com/ script-path=%s/script.js,tag=Networked
[MITM]
hostname=api.example.com
`, server.URL)
	parser := interceptModuleParser{client: server.Client(), now: time.Now}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: content})
	if err != nil {
		t.Fatal(err)
	}
	if len(module.Incompatible) != 1 || !strings.Contains(module.Incompatible[0], "networking is disabled") {
		t.Fatalf("incompatible report = %v", module.Incompatible)
	}
}

func TestParseLoonRewriteActions(t *testing.T) {
	t.Parallel()
	lines := []string{
		`^http://example\.com/ header http://origin.example.com/`,
		`^https://example\.com/ 302 https://origin.example.com/`,
		`^https://example\.com/ 307 https://origin.example.com/`,
		`^https://example\.com/ad reject`,
		`^https://example\.com/ad reject-200`,
		`^https://example\.com/ad reject-img`,
		`^https://example\.com/ad reject-dict`,
		`^https://example\.com/ad reject-array`,
		`^https://example\.com/ header-del Cookie`,
		`^https://example\.com/ header-add X-Module active`,
		`^https://example\.com/ header-replace User-Agent Loon`,
	}
	for index, line := range lines {
		rewrite, header, err := parseLoonRewriteLine(line, index)
		if err != nil || (rewrite == nil) == (header == nil) {
			t.Fatalf("parse %q = rewrite=%+v header=%+v err=%v", line, rewrite, header, err)
		}
	}
}

func TestNormalizeModuleImportURL(t *testing.T) {
	t.Parallel()
	plugin := "https://kelee.one/Tool/Loon/Lpx/example.lpx"
	for _, raw := range []string{
		"loon://import?plugin=" + plugin,
		"loon:///import?plugin=" + url.QueryEscape(plugin),
	} {
		normalized, err := normalizeModuleImportURL(raw)
		if err != nil || normalized != plugin {
			t.Fatalf("normalize %q = %q, %v", raw, normalized, err)
		}
	}
	for _, raw := range []string{
		"loon://install?plugin=" + url.QueryEscape(plugin),
		"loon://import?plugin=http%3A%2F%2Fexample.com%2Fmodule.lpx",
		"loon://import?plugin=" + url.QueryEscape(plugin) + "&plugin=" + url.QueryEscape(plugin),
		"custom://install?url=" + url.QueryEscape(plugin),
	} {
		if _, err := normalizeModuleImportURL(raw); err == nil {
			t.Fatalf("unsafe import URL accepted: %q", raw)
		}
	}
}

func TestInterceptModuleImportRequestRejectsRetiredPreImportControls(t *testing.T) {
	t.Parallel()
	for _, retired := range []string{
		`"format":"loon"`,
		`"fetch_profile":"quantumult-x"`,
		`"referer":"https://hub.kelee.one/"`,
		`"argument":"value"`,
		`"partial_allowed":true`,
	} {
		body := []byte(`{"revision":"r1","url":"https://example.com/module.lpx",` + retired + `}`)
		var request interceptModuleImportRequest
		if err := unmarshalStrictJSON(body, &request); err == nil {
			t.Fatalf("retired import control accepted: %s", retired)
		}
	}
}

func TestInterceptModuleParserRejectsUnsafeAndIncompleteModules(t *testing.T) {
	t.Parallel()
	parser := interceptModuleParser{now: time.Now}
	if _, err := parser.Import(context.Background(), interceptModuleImportRequest{URL: "http://example.com/module.lpx"}); err == nil {
		t.Fatal("non-HTTPS URL was accepted")
	}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{Content: "#!name=Empty\n[Rule]\nDOMAIN,example.com,DIRECT\n"})
	if err != nil {
		t.Fatal(err)
	}
	if len(module.Incompatible) == 0 || module.Enabled {
		t.Fatalf("incomplete module was not retained as disabled incompatible state: %+v", module)
	}
}
