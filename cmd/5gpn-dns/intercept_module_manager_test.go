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
		WLOC:    interceptWLOCSettings{Accuracy: 25, FailClosed: true, MaxBodyBytes: 8 << 20},
		Modules: modules,
	}
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	return document, body
}

func testModuleSnapshot(partial bool) interceptModuleSnapshot {
	source := "#!name=Fixture\n[MITM]\nhostname=api.example.com\n"
	script := `$done({body: $response.body});`
	unsupported := []string(nil)
	if partial {
		unsupported = []string{"[Rule] DOMAIN,api.example.com,DIRECT (section is not supported)"}
	}
	return interceptModuleSnapshot{
		ID:          "mod-1234567890abcdef",
		Name:        "Fixture module",
		ImportedAt:  time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC).Format(time.RFC3339),
		Source:      interceptModuleSource{Digest: sha256Hex([]byte(source)), Body: source},
		Hosts:       []string{"api.example.com"},
		Unsupported: unsupported,
		Scripts: []interceptScriptRule{{
			ID: "script-001", Phase: interceptPhaseResponse, Pattern: `^https://api\.example\.com/`,
			ScriptURL: "https://modules.example.test/script.js", ScriptDigest: sha256Hex([]byte(script)), ScriptBody: script, TimeoutMS: 1000, MaxBodyBytes: 8 << 20,
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
	manager := NewInterceptModuleManager(
		NewInterceptConfigStore(interceptPath), handler, nil,
		NewMihomoConfigStore(mihomoPath), goldenInfraParams(), &fakeMihomoTester{}, controller,
	)
	return manager, controller, handler, interceptPath, mihomoPath
}

func TestInterceptModuleManagerEnableDisablePublishesOneTransaction(t *testing.T) {
	module := testModuleSnapshot(false)
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
	wantRule := "AND,((DOMAIN,api.example.com),(DST-PORT,443)),MODULE-MITM"
	wantHTTPRule := "AND,((DOMAIN,api.example.com),(DST-PORT,80)),MODULE-MITM"
	if !strings.Contains(string(mihomoBody), wantRule) {
		t.Fatalf("mihomo route missing:\n%s", mihomoBody)
	}
	if !strings.Contains(string(mihomoBody), wantHTTPRule) {
		t.Fatalf("mihomo HTTP route missing:\n%s", mihomoBody)
	}
	if blockIndex, moduleIndex := strings.Index(string(mihomoBody), blockQUICRuleBase+",REJECT"), strings.Index(string(mihomoBody), wantRule); blockIndex < 0 || moduleIndex <= blockIndex {
		t.Fatalf("global QUIC block must precede MITM host routes:\n%s", mihomoBody)
	}
	configBody, _ := os.ReadFile(interceptPath)
	var config interceptConfigDocument
	if err := json.Unmarshal(configBody, &config); err != nil || !config.Modules[0].Enabled {
		t.Fatalf("sidecar module not enabled: err=%v config=%+v", err, config)
	}

	disabled := false
	final, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: after.Revision, Enabled: &disabled})
	if err != nil {
		t.Fatal(err)
	}
	if final.Modules[1].Enabled || controller.putCalls != 2 || len(certificateDigests) != 1 {
		t.Fatalf("disabled view/calls = %+v %d/%d", final, controller.putCalls, len(certificateDigests))
	}
	if got := handler.decideName("api.example.com"); got.Action == actionGateway {
		t.Fatalf("disabled DNS overlay still routes to gateway: %+v", got)
	}
	mihomoBody, _ = os.ReadFile(mihomoPath)
	if strings.Contains(string(mihomoBody), wantRule) {
		t.Fatal("disabled module retained its mihomo rule")
	}
	if !strings.Contains(string(mihomoBody), blockQUICRuleBase+",REJECT") {
		t.Fatal("global QUIC block was removed with the MITM host routes")
	}
}

func TestInterceptMasterSwitchStopsAndRestoresArmedModules(t *testing.T) {
	module := testModuleSnapshot(false)
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
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

	disabledSettings := interceptMITMSettings{HTTP2: false, QUICFallbackProtection: true}
	view, err = manager.UpdateSettings(context.Background(), view.Revision, disabledSettings)
	if err != nil {
		t.Fatal(err)
	}
	if view.Modules[1].Enabled != true || view.Modules[1].Ready || view.Modules[1].Reason != "mitm-disabled" || len(view.ActiveHosts) != 0 {
		t.Fatalf("disabled master view = %+v", view)
	}
	if got := handler.decideName("api.example.com"); got.Action == actionGateway {
		t.Fatalf("disabled master retained DNS steering: %+v", got)
	}
	mihomoBody, _ := os.ReadFile(mihomoPath)
	if strings.Contains(string(mihomoBody), "MODULE-MITM") && strings.Contains(string(mihomoBody), "api.example.com") {
		t.Fatalf("disabled master retained module routing:\n%s", mihomoBody)
	}
	configBody, _ := os.ReadFile(interceptPath)
	document, err := decodeInterceptConfig(configBody)
	if err != nil || document.MITM.Enabled || document.MITM.HTTP2 || !document.MITM.QUICFallbackProtection || !document.Modules[0].Enabled {
		t.Fatalf("disabled master config = %+v err=%v", document, err)
	}

	enabledSettings := disabledSettings
	enabledSettings.Enabled = true
	view, err = manager.UpdateSettings(context.Background(), view.Revision, enabledSettings)
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[1].Ready || len(view.ActiveHosts) != 1 || handler.decideName("api.example.com").Action != actionGateway {
		t.Fatalf("re-enabled master view = %+v", view)
	}
	if controller.putCalls != 3 {
		t.Fatalf("mihomo apply calls = %d, want 3", controller.putCalls)
	}
}

func TestInterceptModuleCanBeArmedWhileMasterIsOff(t *testing.T) {
	module := testModuleSnapshot(false)
	manager, controller, handler, _, _ := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	view, err = manager.UpdateSettings(context.Background(), view.Revision, interceptMITMSettings{HTTP2: true, QUICFallbackProtection: true})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[1].Enabled || view.Modules[1].Ready || len(view.ActiveHosts) != 0 || controller.putCalls != 0 {
		t.Fatalf("armed module changed runtime state: view=%+v calls=%d", view, controller.putCalls)
	}
	if handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("armed module published DNS steering while the master was off")
	}
	settings := interceptMITMSettings{Enabled: true, HTTP2: true, QUICFallbackProtection: true}
	view, err = manager.UpdateSettings(context.Background(), view.Revision, settings)
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[1].Ready || controller.putCalls != 1 || handler.decideName("api.example.com").Action != actionGateway {
		t.Fatalf("master enable did not activate armed module: view=%+v calls=%d", view, controller.putCalls)
	}
}

func TestInterceptModuleUpdateUsesReviewedImmutableCandidate(t *testing.T) {
	oldScript := `$done({body: "old"});`
	newScript := `$done({body: "reviewed"});`
	unreviewedScript := `$done({body: "changed-after-review"});`
	var script atomic.Value
	script.Store(oldScript)
	moduleSource := ""
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/extension.lpx":
			_, _ = w.Write([]byte(moduleSource))
		case "/extension.js":
			_, _ = w.Write([]byte(script.Load().(string)))
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()
	moduleSource = fmt.Sprintf("#!name=Fixture\n[Script]\nhttp-response ^https://api\\.example\\.com/ script-path=%s/extension.js,requires-body=true,tag=Cleaner\n[MITM]\nhostname=api.example.com\n", server.URL)
	parser := interceptModuleParser{
		client: server.Client(),
		now:    func() time.Time { return time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC) },
	}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{URL: server.URL + "/extension.lpx"})
	if err != nil {
		t.Fatal(err)
	}

	manager, _, _, interceptPath, _ := newInterceptManagerFixture(t, module)
	manager.parser = parser
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}

	unchanged, err := manager.CheckUpdate(context.Background(), module.ID, view.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if unchanged.State != "unchanged" || unchanged.Candidate != nil {
		t.Fatalf("unchanged update view = %+v", unchanged)
	}

	script.Store(newScript)
	available, err := manager.CheckUpdate(context.Background(), module.ID, view.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if available.State != "available" || available.Candidate == nil || available.Candidate.SourceDigest != module.Source.Digest || available.Candidate.SnapshotDigest == interceptModuleSnapshotDigest(module) || available.Candidate.Enabled {
		t.Fatalf("available update view = %+v", available)
	}
	wantDigest := available.Candidate.SnapshotDigest

	script.Store(unreviewedScript)
	if _, err := manager.ApplyUpdate(context.Background(), module.ID, view.Revision, wantDigest); !errors.Is(err, errInterceptRevisionConflict) {
		t.Fatalf("apply after referenced script changed = %v, want revision conflict", err)
	}
	body, err := os.ReadFile(interceptPath)
	if err != nil {
		t.Fatal(err)
	}
	document, err := decodeInterceptConfig(body)
	if err != nil || len(document.Modules) != 1 || interceptModuleSnapshotDigest(document.Modules[0]) != interceptModuleSnapshotDigest(module) {
		t.Fatalf("snapshot changed after rejected apply = %+v err=%v", document.Modules, err)
	}

	script.Store(newScript)
	replaced, err := manager.ApplyUpdate(context.Background(), module.ID, view.Revision, wantDigest)
	if err != nil {
		t.Fatal(err)
	}
	if len(replaced.Modules) != 2 || replaced.Modules[1].ID != module.ID || replaced.Modules[1].SourceDigest != module.Source.Digest || replaced.Modules[1].SnapshotDigest != wantDigest || replaced.Modules[1].Enabled {
		t.Fatalf("replacement view = %+v", replaced)
	}
	body, err = os.ReadFile(interceptPath)
	if err != nil {
		t.Fatal(err)
	}
	document, err = decodeInterceptConfig(body)
	if err != nil || len(document.Modules) != 1 || document.Modules[0].Source.Digest != module.Source.Digest || interceptModuleSnapshotDigest(document.Modules[0]) != wantDigest {
		t.Fatalf("stored replacement = %+v err=%v", document.Modules, err)
	}
}

func TestInterceptModuleManagerRollsBackWhenCertificatePublicationFails(t *testing.T) {
	module := testModuleSnapshot(false)
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	originalConfig, _ := os.ReadFile(interceptPath)
	originalMihomo, _ := os.ReadFile(mihomoPath)
	manager.certWait = func(context.Context, string) error { return errors.New("publisher failed") }
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil {
		t.Fatal("expected certificate failure")
	}
	configAfter, _ := os.ReadFile(interceptPath)
	mihomoAfter, _ := os.ReadFile(mihomoPath)
	if string(configAfter) != string(originalConfig) || string(mihomoAfter) != string(originalMihomo) {
		t.Fatal("failed transaction changed durable configuration")
	}
	if controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("failed transaction published routing state")
	}
}

func TestInterceptModuleManagerCanDisableAfterRawMihomoReset(t *testing.T) {
	module := testModuleSnapshot(false)
	manager, _, handler, _, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	enabledView, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: before.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	reset := goldenMihomoConfig()
	if err := os.WriteFile(mihomoPath, []byte(reset), 0o660); err != nil {
		t.Fatal(err)
	}
	if err := manager.ReconcileMihomoText(reset); err == nil {
		t.Fatal("raw reset unexpectedly remained ready for an enabled module")
	}
	if handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("raw reset did not remove the DNS interception overlay")
	}
	disabled := false
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: enabledView.Revision, Enabled: &disabled}); err != nil {
		t.Fatalf("disable could not reconcile an empty reserved rule block: %v", err)
	}
}

func TestInterceptModuleManagerRequiresPartialAcknowledgement(t *testing.T) {
	module := testModuleSnapshot(true)
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil || !strings.Contains(err.Error(), "partially compatible") {
		t.Fatalf("partial enable error = %v", err)
	}
	acknowledged := true
	view, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, PartialAllowed: &acknowledged})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err != nil {
		t.Fatalf("acknowledged partial module did not enable: %v", err)
	}
}

func TestInterceptModuleManagerRequiresParametersBeforeEnable(t *testing.T) {
	module := testModuleSnapshot(false)
	module.Parameters = []interceptModuleParameter{
		{Key: "appName", Kind: "input"},
		{Key: "mode", Kind: "select", Options: []string{"clean", "full"}},
	}
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil || !strings.Contains(err.Error(), "parameter") {
		t.Fatalf("unconfigured enable error = %v", err)
	}
	view, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision:   view.Revision,
		Parameters: map[string]string{"appName": "Drive", "mode": "clean"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if view.Modules[1].Compatibility != "full" || view.Modules[1].Parameters[0].Value != "Drive" {
		t.Fatalf("configured view = %+v", view.Modules[1])
	}
}

func TestInterceptModulesAPIListsAndTogglesThroughSharedManager(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	module := testModuleSnapshot(false)
	interceptPath := filepath.Join(t.TempDir(), "config.json")
	_, body := testInterceptDocument(t, module)
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}
	handler := &Handler{}
	manager := NewInterceptModuleManager(
		NewInterceptConfigStore(interceptPath), handler, nil,
		fx.store, fx.infra, fx.tester, fx.ctl,
	)
	manager.certWait = func(context.Context, string) error { return nil }
	fx.cs.SetInterceptModuleManager(manager)

	get := doAPI(fx.cs, http.MethodGet, "/api/interception/modules", nil, fx.token, true)
	if get.Code != http.StatusOK {
		t.Fatalf("GET status=%d body=%s", get.Code, get.Body.String())
	}
	view := decodeJSON[interceptModulesView](t, get)
	if len(view.Modules) != 2 || view.Modules[1].ID != module.ID {
		t.Fatalf("module view = %+v", view)
	}
	snapshotRecorder := doAPI(fx.cs, http.MethodGet, "/api/interception/modules/"+module.ID, nil, fx.token, true)
	if snapshotRecorder.Code != http.StatusOK {
		t.Fatalf("snapshot status=%d body=%s", snapshotRecorder.Code, snapshotRecorder.Body.String())
	}
	snapshot := decodeJSON[interceptModuleSnapshotView](t, snapshotRecorder)
	if snapshot.SourceBody != module.Source.Body || len(snapshot.Scripts) != 1 || snapshot.Scripts[0].Body != module.Scripts[0].ScriptBody {
		t.Fatalf("snapshot = %+v", snapshot)
	}
	update := []byte(fmt.Sprintf(`{"revision":%q,"enabled":true}`, view.Revision))
	put := doAPI(fx.cs, http.MethodPut, "/api/interception/modules/"+module.ID, update, fx.token, true)
	if put.Code != http.StatusOK {
		t.Fatalf("PUT status=%d body=%s", put.Code, put.Body.String())
	}
	updated := decodeJSON[interceptModulesView](t, put)
	if !updated.Modules[1].Enabled || handler.decideName("api.example.com").Action != actionGateway {
		t.Fatalf("updated modules = %+v", updated)
	}
}
