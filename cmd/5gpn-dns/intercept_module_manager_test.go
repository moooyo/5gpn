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
	executionOrder := make([]string, 0, len(modules))
	for _, module := range modules {
		executionOrder = append(executionOrder, module.ID)
	}
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
		MITM:           interceptMITMSettings{Enabled: true, HTTP2: true, QUICFallbackProtection: true},
		ExecutionOrder: executionOrder,
		Modules:        modules,
	}
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	return document, body
}

func TestInterceptModuleViewAlwaysMarshalsNetworkOriginsAsArray(t *testing.T) {
	view := interceptModuleViewFromSnapshot(testModuleSnapshot(), true, "")
	view.NetworkOrigins = append([]string{}, view.NetworkOrigins...)
	body, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `"network_origins":[]`) {
		t.Fatalf("empty network origins were omitted or null: %s", body)
	}
}

func TestInterceptModuleViewExposesActionReviewWithoutScriptBody(t *testing.T) {
	module := testModuleSnapshot()
	view := interceptModuleViewFromSnapshot(module, true, "")
	if len(view.Actions) != 1 {
		t.Fatalf("action reviews = %+v", view.Actions)
	}
	action := view.Actions[0]
	if action.ID != module.Scripts[0].ID || action.Phase != interceptPhaseResponse ||
		action.ScriptDigest != module.Scripts[0].ScriptDigest || action.Match.PathRegex != "^/" {
		t.Fatalf("action review = %+v", action)
	}
	body, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), module.Scripts[0].ScriptBody) || !strings.Contains(string(body), `"actions":[`) {
		t.Fatalf("action review leaked or omitted script metadata: %s", body)
	}
}

func TestInterceptModulesViewAlwaysMarshalsCollectionFieldsAsArrays(t *testing.T) {
	document, body := testInterceptDocument(t)
	view := modulesViewFromDocument(document, body, false, "mitm-disabled", []string{"DIRECT"})
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"execution_order":[]`, `"modules":[]`, `"active_capture_hosts":[]`} {
		if !strings.Contains(string(encoded), field) {
			t.Fatalf("empty collection %s was omitted or null: %s", field, encoded)
		}
	}
}

func testModuleSnapshot() interceptModuleSnapshot {
	manifest := "apiVersion: 5gpn.io/v1\nkind: Extension\n"
	script := `function transform(context) { return { response: { body: context.response.body } } }`
	return interceptModuleSnapshot{
		ID: "io.example.fixture", Version: "1.0.0", Name: "Fixture extension",
		ImportedAt:   time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC).Format(time.RFC3339),
		Source:       interceptModuleSource{Digest: sha256Hex([]byte(manifest)), Body: manifest},
		CaptureHosts: []string{"api.example.com"}, CaptureDNS: interceptCaptureDNSTrust,
		Scripts: []interceptScriptRule{{
			ID: "clean-response", Phase: interceptPhaseResponse,
			Match:     interceptActionMatch{Hosts: []string{"api.example.com"}, Schemes: []string{"https"}, PathRegex: "^/"},
			ScriptURL: "https://extensions.example.test/script.js", ScriptDigest: sha256Hex([]byte(script)), ScriptBody: script,
			BodyMode: "text", TimeoutMS: 1000, MaxBodyBytes: 8 << 20,
		}},
	}
}

func newInterceptManagerFixture(t *testing.T, modules ...interceptModuleSnapshot) (*InterceptModuleManager, *fakeMihomoController, *Handler, string, string) {
	t.Helper()
	dir := t.TempDir()
	interceptPath := filepath.Join(dir, "config.json")
	_, body := testInterceptDocument(t, modules...)
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

func TestInterceptModuleManagerUsesDaemonBackupOutsideStickyMihomoDir(t *testing.T) {
	module := testModuleSnapshot()
	for _, tc := range []struct {
		name         string
		rollback     bool
		wantPutCalls int
	}{
		{name: "publish", wantPutCalls: 1},
		{name: "controller rollback", rollback: true, wantPutCalls: 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			manager, controller, _, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
			legacyBackupPath, legacyBackupBody := seedLegacyMihomoBackup(t, manager.mihomo)
			originalIntercept := mustRead(t, interceptPath)
			originalMihomo := mustRead(t, mihomoPath)
			manager.certWait = func(context.Context, string) error { return nil }
			var rollbackController *rollbackTestController
			if tc.rollback {
				rollbackController = &rollbackTestController{}
				manager.controller = rollbackController
			}

			view, err := manager.View()
			if err != nil {
				t.Fatal(err)
			}
			enabled := true
			_, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
			if tc.rollback {
				if !errors.Is(err, errInterceptApplyFailed) {
					t.Fatalf("rollback update error = %v", err)
				}
				if rollbackController.putCalls != tc.wantPutCalls {
					t.Fatalf("rollback controller calls = %d, want %d", rollbackController.putCalls, tc.wantPutCalls)
				}
				if mustRead(t, mihomoPath) != originalMihomo || mustRead(t, interceptPath) != originalIntercept {
					t.Fatal("failed extension transaction did not restore the exact old files")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				if controller.putCalls != tc.wantPutCalls {
					t.Fatalf("controller calls = %d, want %d", controller.putCalls, tc.wantPutCalls)
				}
				if !strings.Contains(mustRead(t, mihomoPath), "DOMAIN,api.example.com") {
					t.Fatal("successful extension transaction did not publish its mihomo rule")
				}
			}

			backup, err := os.ReadFile(manager.mihomo.BackupPath())
			if err != nil || string(backup) != originalMihomo {
				t.Fatalf("daemon backup = %q, %v", backup, err)
			}
			if info, err := os.Stat(manager.mihomo.BackupPath()); err != nil || filesystemSupportsPOSIXModes(t, filepath.Dir(manager.mihomo.BackupPath())) && info.Mode().Perm() != 0o640 {
				t.Fatalf("daemon backup mode: info=%v err=%v", info, err)
			}
			legacyBackup, err := os.ReadFile(legacyBackupPath)
			if err != nil || string(legacyBackup) != legacyBackupBody {
				t.Fatalf("extension transaction changed legacy backup: body=%q err=%v", legacyBackup, err)
			}
		})
	}
}

func TestInterceptModuleManagerRollsBackCompactSuffixBlockOnControllerFailure(t *testing.T) {
	module := testModuleSnapshot()
	module.CaptureHosts = []string{"*.example.com", "example.com"}
	manager, _, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	activeIntercept, activeMihomo := mustRead(t, interceptPath), mustRead(t, mihomoPath)
	if strings.Count(activeMihomo, "DOMAIN-SUFFIX,example.com") != 4 {
		t.Fatalf("active compact block does not contain two egress and two capture rules:\n%s", activeMihomo)
	}

	controller := &rollbackTestController{}
	manager.controller = controller
	disabled := false
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &disabled}); !errors.Is(err, errInterceptApplyFailed) {
		t.Fatalf("disable error = %v, want controller apply failure", err)
	}
	if controller.putCalls != 2 {
		t.Fatalf("controller calls = %d, want candidate + rollback", controller.putCalls)
	}
	if got := mustRead(t, interceptPath); got != activeIntercept {
		t.Fatal("sidecar document was not restored exactly")
	}
	if got := mustRead(t, mihomoPath); got != activeMihomo {
		t.Fatal("compact suffix mihomo block was not restored exactly")
	}
	if decision := handler.decideName("api.example.com"); decision.Action != actionGateway {
		t.Fatalf("DNS overlay changed after rollback: %+v", decision)
	}
}

func TestInterceptModuleManagerExplicitToggleRepairsMissingOwnedRouting(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	module.RoutingRules = []interceptRoutingRule{{Action: "reject", Domain: "ads.example.com"}}
	manager, controller, _, _, mihomoPath := newInterceptManagerFixture(t, module)
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if view.Modules[0].Ready || view.Modules[0].Reason == "" {
		t.Fatalf("missing routing was not reported as degraded: %+v", view.Modules[0])
	}
	disabled := false
	updated, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &disabled})
	if err != nil {
		t.Fatal(err)
	}
	if updated.Modules[0].Enabled || controller.putCalls != 1 {
		t.Fatalf("explicit repair result = %+v, apply calls=%d", updated.Modules[0], controller.putCalls)
	}
	mihomo := mustRead(t, mihomoPath)
	if strings.Contains(mihomo, "ads.example.com") || strings.Contains(mihomo, "api.example.com),(DST-PORT") {
		t.Fatalf("disabled repair retained extension-owned routing:\n%s", mihomo)
	}
}

func TestInterceptModuleManagerRefusesToClaimUnexpectedPolicyRule(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	module.RoutingRules = []interceptRoutingRule{{Action: "reject", Domain: "ads.example.com"}}
	manager, controller, _, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	tampered := strings.Replace(mustRead(t, mihomoPath), "  - MATCH,Proxies\n", "  - DOMAIN,operator.example,DIRECT\n  - MATCH,Proxies\n", 1)
	if err := os.WriteFile(mihomoPath, []byte(tampered), 0o660); err != nil {
		t.Fatal(err)
	}
	beforeConfig := mustRead(t, interceptPath)
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	disabled := false
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &disabled}); !errors.Is(err, errInterceptModuleConflict) {
		t.Fatalf("unexpected operator rule conflict = %v", err)
	}
	if controller.putCalls != 0 || mustRead(t, interceptPath) != beforeConfig || mustRead(t, mihomoPath) != tampered {
		t.Fatal("failed reconciliation mutated operator or extension state")
	}
}

func TestInterceptModuleManagerWaitsForCertificateWhenEnabledHostSetShrinks(t *testing.T) {
	first := testModuleSnapshot()
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	second.CaptureHosts = []string{"second.example.com"}
	second.Scripts[0].Match.Hosts = []string{"second.example.com"}
	manager, _, _, _, _ := newInterceptManagerFixture(t, first, second)
	var certificateDigests []string
	manager.certWait = func(_ context.Context, digest string) error {
		certificateDigests = append(certificateDigests, digest)
		return nil
	}
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), first.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	view, err = manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	disabled := false
	if _, err := manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &disabled}); err != nil {
		t.Fatal(err)
	}
	want := interceptCertificateDigest([]string{"api.example.com"})
	if len(certificateDigests) != 3 || certificateDigests[2] != want {
		t.Fatalf("certificate waits = %v, want final digest %s", certificateDigests, want)
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
	module.CaptureDNS = interceptCaptureDNSChina
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
	if available.Candidate.ExecutionOrder != 1 || available.Candidate.CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("candidate order/capture DNS = %d/%s, want 1/china", available.Candidate.ExecutionOrder, available.Candidate.CaptureDNS)
	}
	wantDigest := available.Candidate.SnapshotDigest
	script.Store(unreviewedScript)
	if _, err := manager.ApplyUpdate(context.Background(), module.ID, view.Revision, wantDigest); !errors.Is(err, errInterceptRevisionConflict) {
		t.Fatalf("changed candidate apply error = %v", err)
	}
	script.Store(newScript)
	replaced, err := manager.ApplyUpdate(context.Background(), module.ID, view.Revision, wantDigest)
	if err != nil || len(replaced.Modules) != 1 || replaced.Modules[0].SnapshotDigest != wantDigest || replaced.Modules[0].CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("replacement = %+v err=%v", replaced, err)
	}
	document, err := decodeInterceptConfig([]byte(mustRead(t, interceptPath)))
	if err != nil || interceptModuleSnapshotDigest(document.Modules[0]) != wantDigest || document.Modules[0].CaptureDNS != interceptCaptureDNSChina {
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

func TestInterceptModuleManagerRetriggersMissedCertificatePathEvent(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, _, interceptPath, _ := newInterceptManagerFixture(t, module)
	manager.certStatePath = filepath.Join(t.TempDir(), "cert-state")
	wantDigest := interceptCertificateDigest(module.CaptureHosts)
	var republishCalls atomic.Int32
	var publishedCandidate string
	manager.certRepublish = func(ctx context.Context, path string, candidate []byte) error {
		if path != interceptPath {
			t.Fatalf("republish path = %q, want %q", path, interceptPath)
		}
		if current := mustRead(t, path); current != string(candidate) {
			t.Fatalf("republished candidate changed after the initial publication:\ncurrent=%s\ncandidate=%s", current, candidate)
		}
		if call := republishCalls.Add(1); call != 1 {
			t.Fatalf("republish calls = %d, want 1", call)
		}
		publishedCandidate = string(candidate)
		if err := writeInterceptConfigAtomicContext(ctx, path, candidate); err != nil {
			return err
		}
		return os.WriteFile(manager.certStatePath, []byte(wantDigest+"\n"), 0o640)
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
	if republishCalls.Load() != 1 || controller.putCalls != 1 {
		t.Fatalf("republish/controller calls = %d/%d", republishCalls.Load(), controller.putCalls)
	}
	if publishedCandidate == "" || mustRead(t, interceptPath) != publishedCandidate {
		t.Fatal("successful certificate retry did not preserve the exact candidate bytes")
	}
	if after.Revision != interceptRevision([]byte(publishedCandidate)) || after.Revision == before.Revision {
		t.Fatalf("revision after retry = %q, before = %q", after.Revision, before.Revision)
	}
}

func TestInterceptModuleManagerRollsBackWhenCertificateRetriggerFails(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certStatePath = filepath.Join(t.TempDir(), "cert-state")
	originalConfig := mustRead(t, interceptPath)
	originalMihomo := mustRead(t, mihomoPath)
	manager.certRepublish = func(context.Context, string, []byte) error {
		return errors.New("retry write failed")
	}

	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	_, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if !errors.Is(err, errInterceptApplyFailed) || !strings.Contains(err.Error(), "retry write failed") {
		t.Fatalf("certificate retrigger error = %v", err)
	}
	if mustRead(t, interceptPath) != originalConfig || mustRead(t, mihomoPath) != originalMihomo || controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("failed certificate retrigger changed durable or published state")
	}
}

func TestInterceptModuleManagerRollsBackWhenCertificateRetryTimesOut(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certStatePath = filepath.Join(t.TempDir(), "cert-state")
	originalConfig := mustRead(t, interceptPath)
	originalMihomo := mustRead(t, mihomoPath)
	var republishCalls atomic.Int32
	manager.certRepublish = func(ctx context.Context, path string, candidate []byte) error {
		republishCalls.Add(1)
		return writeInterceptConfigAtomicContext(ctx, path, candidate)
	}

	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1100*time.Millisecond)
	defer cancel()
	enabled := true
	_, err = manager.Update(ctx, module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if !errors.Is(err, errInterceptApplyFailed) || !strings.Contains(err.Error(), context.DeadlineExceeded.Error()) {
		t.Fatalf("certificate retry timeout error = %v", err)
	}
	if republishCalls.Load() == 0 {
		t.Fatal("certificate wait timed out without retrying the missed path event")
	}
	if mustRead(t, interceptPath) != originalConfig || mustRead(t, mihomoPath) != originalMihomo || controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("timed-out certificate retry changed durable or published state")
	}
}

func TestInterceptModuleDeleteHonorsCancellationDuringValidation(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = false
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	tester := blockingInterceptConfigTester{entered: make(chan struct{}), release: make(chan struct{})}
	manager.SetSidecarTester(tester)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, deleteErr := manager.Delete(ctx, module.ID, before.Revision)
		done <- deleteErr
	}()
	select {
	case <-tester.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("delete did not reach sidecar validation")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled delete error = %v", err)
		}
	case <-time.After(2 * time.Second):
		close(tester.release)
		t.Fatal("cancelled delete did not stop validation")
	}
	after, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision != before.Revision || len(after.Modules) != 1 || after.Modules[0].ID != module.ID {
		t.Fatalf("cancelled delete committed state: before=%+v after=%+v", before, after)
	}
}

func TestInterceptModuleDeleteRejectsCancellationAfterLockWait(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = false
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	manager.mu.Lock()
	baseCtx, cancel := context.WithCancel(context.Background())
	ctx := &testSignalingContext{Context: baseCtx, checked: make(chan struct{})}
	done := make(chan error, 1)
	go func() {
		_, deleteErr := manager.Delete(ctx, module.ID, before.Revision)
		done <- deleteErr
	}()
	<-ctx.checked
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			manager.mu.Unlock()
			t.Fatalf("cancelled delete error = %v", err)
		}
	case <-time.After(time.Second):
		manager.mu.Unlock()
		t.Fatal("cancelled delete remained blocked on the module lock")
	}
	manager.mu.Unlock()
	after, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision != before.Revision || len(after.Modules) != 1 || after.Modules[0].ID != module.ID {
		t.Fatalf("cancelled delete committed state: before=%+v after=%+v", before, after)
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
	reorderBody, _ := json.Marshal(map[string]any{
		"revision": view.Revision, "execution_order": []string{module.ID},
	})
	reorder := doAPI(fx.cs, http.MethodPut, "/api/interception/modules/reorder", reorderBody, fx.token, true)
	view = decodeJSON[interceptModulesView](t, reorder)
	if reorder.Code != http.StatusOK || !stringSlicesEqual(view.ExecutionOrder, []string{module.ID}) || view.Modules[0].ExecutionOrder != 1 {
		t.Fatalf("reorder view = %+v status=%d", view, reorder.Code)
	}
	badReorderBody, _ := json.Marshal(map[string]any{
		"revision": view.Revision, "execution_order": []string{"io.example.unknown"},
	})
	badReorder := doAPI(fx.cs, http.MethodPut, "/api/interception/modules/reorder", badReorderBody, fx.token, true)
	if badReorder.Code != http.StatusBadRequest {
		t.Fatalf("invalid reorder status=%d body=%s", badReorder.Code, badReorder.Body.String())
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

func TestInterceptModuleRequiresExistingEgressGroupBeforeEnable(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroupRequired = true
	manager, _, _, _, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if len(view.AvailableEgressGroups) != 2 || !containsString(view.AvailableEgressGroups, "DIRECT") || !containsString(view.AvailableEgressGroups, "Proxies") {
		t.Fatalf("available egress groups = %v", view.AvailableEgressGroups)
	}
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil || !strings.Contains(err.Error(), "egress group") {
		t.Fatalf("required egress group error = %v", err)
	}
	missing := "Missing"
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, EgressGroup: &missing}); !errors.Is(err, errInterceptModuleConflict) {
		t.Fatalf("missing egress group error = %v", err)
	}
	group := "Proxies"
	updated, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision: view.Revision, Enabled: &enabled, EgressGroup: &group,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !updated.Modules[0].Ready || updated.Modules[0].EgressGroup != group || updated.Modules[0].ExecutionOrder != 1 {
		t.Fatalf("updated module = %+v", updated.Modules[0])
	}
	if !strings.Contains(mustRead(t, mihomoPath), "(IN-NAME,intercept-egress),(DOMAIN,api.example.com),(DST-PORT,443)),Proxies") {
		t.Fatal("selected egress group rule was not published")
	}
}

func TestInterceptModuleReorderChangesFirstMatchingEgress(t *testing.T) {
	first := testModuleSnapshot()
	first.EgressGroup = "Proxies"
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	second.EgressGroup = "DIRECT"
	manager, _, _, _, mihomoPath := newInterceptManagerFixture(t, first, second)
	manager.certWait = func(context.Context, string) error { return nil }
	view, _ := manager.View()
	enabled := true
	view, err := manager.Update(context.Background(), first.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	view, err = manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	before := mustRead(t, mihomoPath)
	selector := "(IN-NAME,intercept-egress),(DOMAIN,api.example.com),(DST-PORT,443))"
	if strings.Count(before, selector) != 1 || !strings.Contains(before, selector+",Proxies") {
		t.Fatalf("initial first-match rule is wrong:\n%s", before)
	}
	view, err = manager.Reorder(context.Background(), view.Revision, []string{second.ID, first.ID})
	if err != nil {
		t.Fatal(err)
	}
	after := mustRead(t, mihomoPath)
	if strings.Count(after, selector) != 1 || !strings.Contains(after, selector+",DIRECT") {
		t.Fatalf("reordered first-match rule is wrong:\n%s", after)
	}
	if !stringSlicesEqual(view.ExecutionOrder, []string{second.ID, first.ID}) || view.Modules[0].ExecutionOrder != 1 || view.Modules[1].ExecutionOrder != 2 {
		t.Fatalf("reordered view = %+v", view)
	}
}

func TestInterceptModuleCaptureDNSBindingUsesExecutionOrder(t *testing.T) {
	first := testModuleSnapshot()
	first.ID = "io.example.first"
	first.CaptureDNS = interceptCaptureDNSChina
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	manager, _, handler, _, _ := newInterceptManagerFixture(t, first, second)
	manager.certWait = func(context.Context, string) error { return nil }
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), first.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	view, err = manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	if resolver, owner := handler.captureDNSForName("api.example.com"); resolver != interceptCaptureDNSChina || owner != first.ID {
		t.Fatalf("initial binding = %s/%s, want china/%s", resolver, owner, first.ID)
	}
	view, err = manager.Reorder(context.Background(), view.Revision, []string{second.ID, first.ID})
	if err != nil {
		t.Fatal(err)
	}
	if resolver, owner := handler.captureDNSForName("api.example.com"); resolver != interceptCaptureDNSTrust || owner != second.ID {
		t.Fatalf("reordered binding = %s/%s, want trust/%s", resolver, owner, second.ID)
	}
	china := interceptCaptureDNSChina
	view, err = manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, CaptureDNS: &china})
	if err != nil {
		t.Fatal(err)
	}
	if view.Modules[0].CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("module view capture_dns = %q", view.Modules[0].CaptureDNS)
	}
	if resolver, owner := handler.captureDNSForName("api.example.com"); resolver != interceptCaptureDNSChina || owner != second.ID {
		t.Fatalf("updated binding = %s/%s, want china/%s", resolver, owner, second.ID)
	}
	invalid := "automatic"
	if _, err := manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, CaptureDNS: &invalid}); err == nil || !strings.Contains(err.Error(), "capture_dns") {
		t.Fatalf("invalid capture_dns error = %v", err)
	}
}

func TestInterceptExternalEgressGroupLossFailsClosed(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroupRequired = true
	module.EgressGroup = "Proxies"
	manager, _, handler, _, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, _ := manager.View()
	enabled := true
	view, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	external := strings.Replace(mustRead(t, mihomoPath), "name: Proxies", "name: Other", 1)
	if err := os.WriteFile(mihomoPath, []byte(external), 0o660); err != nil {
		t.Fatal(err)
	}
	if err := manager.ReconcileMihomoText(external); err == nil || !strings.Contains(err.Error(), "egress-group-missing") {
		t.Fatalf("external reconcile error = %v", err)
	}
	if handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("DNS overlay remained active after its egress group disappeared")
	}
	view, err = manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if view.Modules[0].Ready || view.Modules[0].Reason != "egress-group-missing" || len(view.ActiveCaptureHosts) != 0 {
		t.Fatalf("failed-closed view = %+v", view)
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
