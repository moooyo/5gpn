package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestInterceptSettingsAPIUpdatesCapabilitiesAndMasterState(t *testing.T) {
	manager, _, _, path, _ := newInterceptManagerFixture(t, testModuleSnapshot())
	server := &ControlServer{}
	server.SetInterceptModuleManager(manager)

	getRecorder := httptest.NewRecorder()
	server.handleInterceptSettingsGet(getRecorder, httptest.NewRequest(http.MethodGet, "/api/interception/settings", nil))
	if getRecorder.Code != http.StatusOK {
		t.Fatalf("GET status=%d body=%s", getRecorder.Code, getRecorder.Body.String())
	}
	view := decodeJSON[interceptSettingsView](t, getRecorder)
	if !view.Enabled || !view.HTTP2 || !view.QUICFallbackProtection || view.Revision == "" {
		t.Fatalf("unexpected settings view: %+v", view)
	}
	update := `{"revision":"` + view.Revision + `","enabled":false,"http2":false,"quic_fallback_protection":true}`
	putRecorder := httptest.NewRecorder()
	server.handleInterceptSettingsPut(putRecorder, httptest.NewRequest(http.MethodPut, "/api/interception/settings", strings.NewReader(update)))
	if putRecorder.Code != http.StatusOK {
		t.Fatalf("PUT status=%d body=%s", putRecorder.Code, putRecorder.Body.String())
	}
	updated := decodeJSON[interceptSettingsView](t, putRecorder)
	if updated.Enabled || updated.HTTP2 || !updated.QUICFallbackProtection || updated.Revision == view.Revision {
		t.Fatalf("unexpected updated settings: %+v", updated)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	document, err := decodeInterceptConfig(body)
	if err != nil || document.MITM != (interceptMITMSettings{QUICFallbackProtection: true}) {
		t.Fatalf("stored settings = %+v err=%v", document.MITM, err)
	}

	staleRecorder := httptest.NewRecorder()
	server.handleInterceptSettingsPut(staleRecorder, httptest.NewRequest(http.MethodPut, "/api/interception/settings", strings.NewReader(update)))
	if staleRecorder.Code != http.StatusConflict {
		t.Fatalf("stale PUT status=%d body=%s", staleRecorder.Code, staleRecorder.Body.String())
	}
}

func TestInterceptConfigRejectsDuplicateJSONKeys(t *testing.T) {
	_, body := testInterceptDocument(t)
	duplicate := strings.Replace(string(body), `"version": 6`, `"version": 6, "Version": 6`, 1)
	if _, err := decodeInterceptConfig([]byte(duplicate)); err == nil || !strings.Contains(err.Error(), "duplicate JSON key") {
		t.Fatalf("duplicate config error = %v", err)
	}
}

func TestInterceptConfigRequiresCurrentVersionAndCompleteExecutionOrder(t *testing.T) {
	module := testModuleSnapshot()
	_, body := testInterceptDocument(t, module)

	stale := strings.Replace(string(body), `"version": 6`, `"version": 4`, 1)
	if _, err := decodeInterceptConfig([]byte(stale)); err == nil || !strings.Contains(err.Error(), "version must be 6") {
		t.Fatalf("stale config error = %v", err)
	}

	// The immediately previous version is upgraded in place instead: a deployed
	// gateway keeps its extensions, settings, and bindings across this change.
	previous := strings.Replace(string(body), `"version": 6`, `"version": 5`, 1)
	previous = strings.Replace(previous, `"persistent_storage": false`, `"persistent_storage": false,
      "network_origins": [
        "https://api.example.net"
      ]`, 1)
	upgraded, err := decodeInterceptConfig([]byte(previous))
	if err != nil {
		t.Fatalf("previous version was refused rather than upgraded: %v", err)
	}
	if upgraded.Version != interceptConfigVersion || !upgraded.Modules[0].Network {
		t.Fatalf("upgraded document = %+v", upgraded)
	}

	missing := strings.Replace(string(body), `"execution_order": [
    "io.example.fixture"
  ]`, `"execution_order": []`, 1)
	if _, err := decodeInterceptConfig([]byte(missing)); err == nil || !strings.Contains(err.Error(), "execution_order") {
		t.Fatalf("missing execution order error = %v", err)
	}

	duplicateDocument := interceptConfigDocument{
		Version:  interceptConfigVersion,
		Listen:   "127.0.0.1:18080",
		Username: "interception-unavailable",
		Password: "interception-unavailable-password",
		TLSCert:  "/etc/5gpn/intercept/tls/fullchain.pem",
		TLSKey:   "/etc/5gpn/intercept/tls/privkey.pem",
		UpstreamProxy: interceptProxyConfig{
			Address: "127.0.0.1:17890", Username: "interception-upstream-unavailable", Password: "interception-upstream-unavailable-password",
		},
		ExecutionOrder: []string{module.ID, module.ID},
		Modules:        []interceptModuleSnapshot{module, withInterceptModuleID(module, "io.example.second")},
	}
	if err := validateInterceptDocument(duplicateDocument); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("duplicate execution order error = %v", err)
	}
}

func TestInterceptConfigRequiresExecutionOrderFieldWhenEmpty(t *testing.T) {
	_, body := testInterceptDocument(t)
	missing := strings.Replace(string(body), ",\n  \"execution_order\": []", "", 1)
	if _, err := decodeInterceptConfig([]byte(missing)); err == nil || !strings.Contains(err.Error(), "execution_order is required") {
		t.Fatalf("missing execution_order error = %v", err)
	}
}

func withInterceptModuleID(module interceptModuleSnapshot, id string) interceptModuleSnapshot {
	module.ID = id
	return module
}

func TestInterceptConfigValidatesNetworkAndEgressFields(t *testing.T) {
	module := testModuleSnapshot()
	document, _ := testInterceptDocument(t, module)

	document.Modules[0].Network = true
	document.Modules[0].EgressGroup = "bad,group"
	if err := validateInterceptDocument(document); err == nil || !strings.Contains(err.Error(), "commas") {
		t.Fatalf("unsafe egress group error = %v", err)
	}

	document.Modules[0].EgressGroup = ""
	document.Modules[0].EgressGroupRequired = true
	document.Modules[0].Enabled = true
	if err := validateInterceptDocument(document); err == nil || !strings.Contains(err.Error(), "required before enable") {
		t.Fatalf("required egress group error = %v", err)
	}
}
