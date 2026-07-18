package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInterceptWLOCAPIUpdatePreservesSecretsAndUsesRevision(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "config.json")
	writeInterceptTestConfig(t, path)
	server := &ControlServer{interceptStore: NewInterceptConfigStore(path)}

	getRecorder := httptest.NewRecorder()
	server.handleInterceptWLOCGet(getRecorder, httptest.NewRequest(http.MethodGet, "/api/interception/wloc", nil))
	if getRecorder.Code != http.StatusOK {
		t.Fatalf("GET status=%d body=%s", getRecorder.Code, getRecorder.Body.String())
	}
	view := decodeJSON[interceptWLOCView](t, getRecorder)
	if view.Enabled || view.Revision == "" || len(view.Hosts) != 2 {
		t.Fatalf("unexpected view: %+v", view)
	}
	if strings.Contains(getRecorder.Body.String(), "inbound-password") || strings.Contains(getRecorder.Body.String(), "upstream-password") {
		t.Fatal("GET exposed SOCKS credentials")
	}

	update := `{"revision":"` + view.Revision + `","enabled":true,"longitude":113.9,"latitude":22.5,"accuracy":30,"fail_closed":true,"max_body_bytes":1048576}`
	putRecorder := httptest.NewRecorder()
	server.handleInterceptWLOCPut(putRecorder, httptest.NewRequest(http.MethodPut, "/api/interception/wloc", strings.NewReader(update)))
	if putRecorder.Code != http.StatusOK {
		t.Fatalf("PUT status=%d body=%s", putRecorder.Code, putRecorder.Body.String())
	}
	updated := decodeJSON[interceptWLOCView](t, putRecorder)
	if !updated.Enabled || updated.Longitude == nil || *updated.Longitude != 113.9 || updated.Revision == view.Revision {
		t.Fatalf("unexpected updated view: %+v", updated)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	document, err := decodeInterceptConfig(body)
	if err != nil {
		t.Fatal(err)
	}
	if document.Password != "inbound-password-123456789" || document.UpstreamProxy.Password != "upstream-password-12345678" {
		t.Fatal("PUT changed protected SOCKS credentials")
	}

	staleRecorder := httptest.NewRecorder()
	server.handleInterceptWLOCPut(staleRecorder, httptest.NewRequest(http.MethodPut, "/api/interception/wloc", strings.NewReader(update)))
	if staleRecorder.Code != http.StatusConflict {
		t.Fatalf("stale PUT status=%d body=%s", staleRecorder.Code, staleRecorder.Body.String())
	}
}

func TestInterceptWLOCAPIRejectsEnabledWithoutCoordinates(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "config.json")
	writeInterceptTestConfig(t, path)
	server := &ControlServer{interceptStore: NewInterceptConfigStore(path)}
	_, body, err := server.interceptStore.Read()
	if err != nil {
		t.Fatal(err)
	}
	update := `{"revision":"` + interceptRevision(body) + `","enabled":true,"longitude":null,"latitude":null,"accuracy":25,"fail_closed":true,"max_body_bytes":1048576}`
	recorder := httptest.NewRecorder()
	server.handleInterceptWLOCPut(recorder, httptest.NewRequest(http.MethodPut, "/api/interception/wloc", strings.NewReader(update)))
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestInterceptConfigRejectsDuplicateJSONKeys(t *testing.T) {
	_, body := testInterceptDocument(t)
	duplicate := strings.Replace(string(body), `"version": 1`, `"version": 1, "Version": 1`, 1)
	if _, err := decodeInterceptConfig([]byte(duplicate)); err == nil || !strings.Contains(err.Error(), "duplicate JSON key") {
		t.Fatalf("duplicate config error = %v", err)
	}
}

func writeInterceptTestConfig(t *testing.T, path string) {
	t.Helper()
	document := interceptConfigDocument{
		Version:  interceptConfigVersion,
		Listen:   "127.0.0.1:18080",
		Username: "inbound-username-123",
		Password: "inbound-password-123456789",
		TLSCert:  "/etc/5gpn/intercept/tls/fullchain.pem",
		TLSKey:   "/etc/5gpn/intercept/tls/privkey.pem",
		UpstreamProxy: interceptProxyConfig{
			Address:  "127.0.0.1:17890",
			Username: "upstream-username-123",
			Password: "upstream-password-12345678",
		},
		WLOC: interceptWLOCSettings{Accuracy: 25, FailClosed: true, MaxBodyBytes: 8388608},
	}
	body, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(body, '\n'), 0o660); err != nil {
		t.Fatal(err)
	}
}
