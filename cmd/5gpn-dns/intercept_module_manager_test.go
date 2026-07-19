package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testInterceptDocument(t *testing.T, modules ...interceptModuleSnapshot) (interceptConfigDocument, []byte) {
	t.Helper()
	document := interceptConfigDocument{
		Version:  interceptConfigVersion,
		Listen:   "127.0.0.1:18080",
		Username: "interception-unavailable",
		Password: "interception-unavailable-password",
		TLSCert:  "/etc/5gpn/intercept/tls/fullchain.pem",
		TLSKey:   "/etc/5gpn/intercept/tls/privkey.pem",
		UpstreamProxy: interceptProxyConfig{
			Address: "127.0.0.1:17890", Username: "interception-upstream-unavailable", Password: "interception-upstream-unavailable-password",
		},
		MITM:    interceptMITMSettings{Enabled: true, HTTP2: true, QUICFallbackProtection: true},
		Modules: modules,
	}
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	return document, body
}

func testModuleSnapshot() interceptModuleSnapshot {
	manifest := "apiVersion: 5gpn.io/v1\nkind: Extension\n"
	script := `function transform(context) { return { response: { body: context.response.body } } }`
	return interceptModuleSnapshot{
		ID: "io.example.fixture", Version: "1.0.0", Name: "Fixture extension",
		ImportedAt:   time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC).Format(time.RFC3339),
		Source:       interceptModuleSource{Digest: sha256Hex([]byte(manifest)), Body: manifest},
		CaptureHosts: []string{"api.example.com"},
		Scripts: []interceptScriptRule{{
			ID: "clean-response", Phase: interceptPhaseResponse,
			Match:     interceptActionMatch{Hosts: []string{"api.example.com"}, Schemes: []string{"https"}, PathRegex: "^/"},
			ScriptURL: "https://extensions.example.test/script.js", ScriptDigest: sha256Hex([]byte(script)), ScriptBody: script,
			BodyMode: "text", TimeoutMS: 1000, MaxBodyBytes: 8 << 20,
		}},
	}
}

func newInterceptManagerFixture(t *testing.T, module interceptModuleSnapshot) (*InterceptModuleManager, *fakeMihomoController, *Handler, string, string) {
	t.Helper()
	dir := t.TempDir()
	interceptPath := filepath.Join(dir, "config.json")
	_, body := testInterceptDocument(t, module)
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}
	mihomoDir := filepath.Join(dir, "mihomo")
	if err := os.Mkdir(mihomoDir, 0o770); err != nil {
		t.Fatal(err)
	}
	mihomoPath := filepath.Join(mihomoDir, "config.yaml")
	golden := goldenMihomoConfig()
	if err := os.WriteFile(mihomoPath, []byte(golden), 0o660); err != nil {
		t.Fatal(err)
	}
	handler := &Handler{}
	controller := &fakeMihomoController{reachable: true, authenticated: true}
	manager := NewInterceptModuleManager(NewInterceptConfigStore(interceptPath), handler, nil, NewMihomoConfigStore(mihomoPath), goldenInfraParams(), &fakeMihomoTester{}, controller)
	return manager, controller, handler, interceptPath, mihomoPath
}

func TestInterceptModuleManagerEnableDisablePublishesOneTransaction(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	var certificateDigests []string
	manager.certWait = func(_ context.Context, digest string) error {
		certificateDigests = append(certificateDigests, digest)
		return nil
	}
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	after, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: before.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	if len(certificateDigests) != 1 || controller.putCalls != 1 {
		t.Fatalf("certificate/apply calls = %d/%d", len(certificateDigests), controller.putCalls)
	}
	if got := handler.decideName("api.example.com"); got.Action != actionGateway || got.Verdict.Reason != "force-proxy" {
		t.Fatalf("DNS overlay = %+v", got)
	}
	mihomoBody, _ := os.ReadFile(mihomoPath)
	wantRule := "AND,((DOMAIN,api.example.com),(DST-PORT,443)),MODULE-INTERCEPT"
	wantHTTPRule := "AND,((DOMAIN,api.example.com),(DST-PORT,80)),MODULE-INTERCEPT"
	if !strings.Contains(string(mihomoBody), wantRule) || !strings.Contains(string(mihomoBody), wantHTTPRule) {
		t.Fatalf("mihomo capture routes missing:\n%s", mihomoBody)
	}
	configBody, _ := os.ReadFile(interceptPath)
	document, err := decodeInterceptConfig(configBody)
	if err != nil || !document.Modules[0].Enabled {
		t.Fatalf("sidecar extension not enabled: err=%v document=%+v", err, document)
	}

	disabled := false
	final, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: after.Revision, Enabled: &disabled})
	if err != nil {
		t.Fatal(err)
	}
	if final.Modules[0].Enabled || controller.putCalls != 2 || len(final.ActiveCaptureHosts) != 0 {
		t.Fatalf("disabled view/calls = %+v %d", final, controller.putCalls)
	}
}

func TestInterceptMasterSwitchStopsAndRestoresArmedExtensions(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, _, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, _ := manager.View()
	enabled := true
	view, _ = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	disabledSettings := interceptMITMSettings{HTTP2: false, QUICFallbackProtection: true}
	view, err := manager.UpdateSettings(context.Background(), view.Revision, disabledSettings)
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[0].Enabled || view.Modules[0].Ready || view.Modules[0].Reason != "mitm-disabled" || len(view.ActiveCaptureHosts) != 0 {
		t.Fatalf("disabled master view = %+v", view)
	}
	if handler.decideName("api.example.com").Action == actionGateway || strings.Contains(mustRead(t, mihomoPath), "api.example.com),(DST-PORT") {
		t.Fatal("disabled master retained an interception route")
	}
	disabledSettings.Enabled = true
	view, err = manager.UpdateSettings(context.Background(), view.Revision, disabledSettings)
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[0].Ready || len(view.ActiveCaptureHosts) != 1 || controller.putCalls != 3 {
		t.Fatalf("re-enabled master view = %+v calls=%d", view, controller.putCalls)
	}
}

func TestInterceptExtensionCanBeArmedWhileMasterIsOff(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, _, _ := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, _ := manager.View()
	view, err := manager.UpdateSettings(context.Background(), view.Revision, interceptMITMSettings{HTTP2: true, QUICFallbackProtection: true})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[0].Enabled || view.Modules[0].Ready || len(view.ActiveCaptureHosts) != 0 || controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatalf("armed extension changed runtime state: view=%+v calls=%d", view, controller.putCalls)
	}
}

func TestInterceptExtensionRequiresTypedSettingsBeforeEnable(t *testing.T) {
	module := testModuleSnapshot()
	module.Settings = []interceptModuleSetting{{
		Key: "location", Type: "location", Required: true,
		Default: json.RawMessage(`{"accuracy":25}`), Value: json.RawMessage(`{"accuracy":25}`),
	}}
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	view, _ := manager.View()
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil || !strings.Contains(err.Error(), "required") {
		t.Fatalf("unconfigured enable error = %v", err)
	}
	view, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision: view.Revision,
		Settings: map[string]json.RawMessage{"location": json.RawMessage(`{"longitude":113.9,"latitude":22.5,"accuracy":25}`)},
	})
	if err != nil || view.Modules[0].Reason != "" {
		t.Fatalf("configured view = %+v err=%v", view.Modules[0], err)
	}
}

func TestInterceptExtensionUpdateUsesReviewedNativeCandidate(t *testing.T) {
	oldScript := `function transform() { return null }`
	newScript := `function transform(context) { return { response: { body: context.response.body } } }`
	unreviewedScript := `function transform() { throw new Error('changed') }`
	var script atomic.Value
	script.Store(oldScript)
	manifest := ""
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/extension.yaml":
			_, _ = w.Write([]byte(manifest))
		case "/extension.js":
			_, _ = w.Write([]byte(script.Load().(string)))
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()
	manifest = fmt.Sprintf(`apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.fixture
  name: Fixture extension
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
actions:
  - id: clean
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      source: %s/extension.js
      bodyMode: text
      timeoutMs: 1000
      maxBodyBytes: 8388608
`, server.URL)
	parser := interceptModuleParser{client: server.Client(), now: func() time.Time { return time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC) }}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{URL: server.URL + "/extension.yaml"})
	if err != nil {
		t.Fatal(err)
	}
	manager, _, _, interceptPath, _ := newInterceptManagerFixture(t, module)
	manager.parser = parser
	view, _ := manager.View()
	unchanged, err := manager.CheckUpdate(context.Background(), module.ID, view.Revision)
	if err != nil || unchanged.State != "unchanged" {
		t.Fatalf("unchanged update = %+v err=%v", unchanged, err)
	}
	script.Store(newScript)
	available, err := manager.CheckUpdate(context.Background(), module.ID, view.Revision)
	if err != nil || available.Candidate == nil {
		t.Fatalf("available update = %+v err=%v", available, err)
	}
	wantDigest := available.Candidate.SnapshotDigest
	script.Store(unreviewedScript)
	if _, err := manager.ApplyUpdate(context.Background(), module.ID, view.Revision, wantDigest); !errors.Is(err, errInterceptRevisionConflict) {
		t.Fatalf("changed candidate apply error = %v", err)
	}
	script.Store(newScript)
	replaced, err := manager.ApplyUpdate(context.Background(), module.ID, view.Revision, wantDigest)
	if err != nil || len(replaced.Modules) != 1 || replaced.Modules[0].SnapshotDigest != wantDigest {
		t.Fatalf("replacement = %+v err=%v", replaced, err)
	}
	document, err := decodeInterceptConfig([]byte(mustRead(t, interceptPath)))
	if err != nil || interceptModuleSnapshotDigest(document.Modules[0]) != wantDigest {
		t.Fatalf("stored replacement = %+v err=%v", document.Modules, err)
	}
}

func TestInterceptModuleManagerRollsBackWhenCertificatePublicationFails(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	originalConfig := mustRead(t, interceptPath)
	originalMihomo := mustRead(t, mihomoPath)
	manager.certWait = func(context.Context, string) error { return errors.New("publisher failed") }
	view, _ := manager.View()
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil {
		t.Fatal("expected certificate failure")
	}
	if mustRead(t, interceptPath) != originalConfig || mustRead(t, mihomoPath) != originalMihomo || controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("failed transaction changed durable or published state")
	}
}

func TestInterceptModulesAPIListsAndTogglesThroughSharedManager(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	module := testModuleSnapshot()
	interceptPath := filepath.Join(t.TempDir(), "config.json")
	_, body := testInterceptDocument(t, module)
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}
	handler := &Handler{}
	manager := NewInterceptModuleManager(NewInterceptConfigStore(interceptPath), handler, nil, fx.store, fx.infra, fx.tester, fx.ctl)
	manager.certWait = func(context.Context, string) error { return nil }
	fx.cs.SetInterceptModuleManager(manager)

	get := doAPI(fx.cs, http.MethodGet, "/api/interception/modules", nil, fx.token, true)
	view := decodeJSON[interceptModulesView](t, get)
	if get.Code != http.StatusOK || len(view.Modules) != 1 || view.Modules[0].ID != module.ID {
		t.Fatalf("module view = %+v status=%d", view, get.Code)
	}
	snapshotRecorder := doAPI(fx.cs, http.MethodGet, "/api/interception/modules/"+module.ID, nil, fx.token, true)
	snapshot := decodeJSON[interceptModuleSnapshotView](t, snapshotRecorder)
	if snapshot.SourceBody != module.Source.Body || len(snapshot.Scripts) != 1 {
		t.Fatalf("snapshot = %+v", snapshot)
	}
	update := []byte(fmt.Sprintf(`{"revision":%q,"enabled":true}`, view.Revision))
	put := doAPI(fx.cs, http.MethodPut, "/api/interception/modules/"+module.ID, update, fx.token, true)
	updated := decodeJSON[interceptModulesView](t, put)
	if put.Code != http.StatusOK || !updated.Modules[0].Enabled || handler.decideName("api.example.com").Action != actionGateway {
		t.Fatalf("updated modules = %+v status=%d", updated, put.Code)
	}
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}
