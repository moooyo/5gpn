package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
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
