package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newTestControlServer builds a ControlServer with a fixed token for handler
// tests that only exercise the mux/middleware (not TLS listening). Uses a
// throwaway self-signed cert/key pair (via the cert_test.go helper) since
// NewControlServer requires CertFile/KeyFile whenever a token is set.
func newTestControlServer(t *testing.T, token string) *ControlServer {
	t.Helper()
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cfg := Config{APIToken: token, CertFile: certPath, KeyFile: keyPath}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}
	if cs == nil {
		t.Fatalf("NewControlServer returned nil ControlServer for non-empty token")
	}
	return cs
}

func TestNewControlServer_EmptyToken_Disabled(t *testing.T) {
	cfg := Config{APIToken: ""}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatalf("NewControlServer: unexpected error: %v", err)
	}
	if cs != nil {
		t.Fatalf("NewControlServer with empty APIToken = %+v, want nil (disabled)", cs)
	}
}

func TestControlServer_APIStatus_Unauthorized(t *testing.T) {
	cs := newTestControlServer(t, "correct-token")

	tests := []struct {
		name   string
		header string
	}{
		{"no header", ""},
		{"blank bearer", "Bearer "},
		{"wrong token", "Bearer wrong-token"},
		{"missing bearer prefix", "correct-token"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			cs.srv.Handler.ServeHTTP(rec, req)

			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
			}
			var body map[string]string
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("response body not JSON: %v (%s)", err, rec.Body.String())
			}
			if body["error"] != "unauthorized" {
				t.Errorf("body error = %q, want %q", body["error"], "unauthorized")
			}
		})
	}
}

func TestControlServer_APIStatus_Authorized(t *testing.T) {
	cs := newTestControlServer(t, "correct-token")

	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	req.Header.Set("Authorization", "Bearer correct-token")
	rec := httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	var body map[string]bool
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("response body not JSON: %v (%s)", err, rec.Body.String())
	}
	if !body["ok"] {
		t.Errorf("body ok = %v, want true", body["ok"])
	}
}

// TestControlServer_WebUI_ServesIndex confirms the SPA placeholder is served
// at "/" (via the embedded web/dist).
func TestControlServer_WebUI_ServesIndex(t *testing.T) {
	cs := newTestControlServer(t, "correct-token")

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "" && !strings.Contains(ct, "text/html") {
		t.Errorf("Content-Type = %q, want text/html", ct)
	}
	if !strings.Contains(rec.Body.String(), "5gpn-dns") {
		t.Errorf("body does not look like the placeholder index.html: %s", rec.Body.String())
	}
}

// TestControlServer_WebUI_SPAFallback confirms an unknown non-/api/ path
// falls back to index.html rather than a bare 404, so client-side routing
// in the eventual SPA works on a hard refresh / deep link.
func TestControlServer_WebUI_SPAFallback(t *testing.T) {
	cs := newTestControlServer(t, "correct-token")

	req := httptest.NewRequest(http.MethodGet, "/dashboard/subscriptions", nil)
	rec := httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d (SPA fallback); body=%s", rec.Code, http.StatusOK, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "5gpn-dns") {
		t.Errorf("SPA fallback body does not look like index.html: %s", rec.Body.String())
	}
}

// TestControlServer_WebUI_UnknownAPIPath confirms unknown /api/ paths are
// NOT swallowed by the SPA fallback (they still require auth / get a
// non-SPA response) — the auth middleware wraps the whole /api/ subtree.
func TestControlServer_WebUI_UnknownAPIPath(t *testing.T) {
	cs := newTestControlServer(t, "correct-token")

	req := httptest.NewRequest(http.MethodGet, "/api/does-not-exist", nil)
	rec := httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)

	if rec.Code == http.StatusOK && strings.Contains(rec.Body.String(), "5gpn-dns") {
		t.Fatalf("unknown /api/ path fell back to SPA index.html, want it to stay under /api/ handling")
	}
}

func TestNewControlServer_RequiresCertWhenEnabled(t *testing.T) {
	cfg := Config{APIToken: "tok"} // no CertFile/KeyFile
	_, err := NewControlServer(cfg, &Controller{})
	if err == nil {
		t.Fatal("expected error when APIToken set but CertFile/KeyFile missing, got nil")
	}
}
