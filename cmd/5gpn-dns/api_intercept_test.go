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
	duplicate := strings.Replace(string(body), `"version": 3`, `"version": 3, "Version": 3`, 1)
	if _, err := decodeInterceptConfig([]byte(duplicate)); err == nil || !strings.Contains(err.Error(), "duplicate JSON key") {
		t.Fatalf("duplicate config error = %v", err)
	}
}
