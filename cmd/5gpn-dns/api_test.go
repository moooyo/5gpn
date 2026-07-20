package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestControlServer_PublicConsoleServesSPAAndIOSAndProtectsAPI(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	wwwDir, _ := writeIOSFixtures(t)
	webDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte("<html>private console</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	cs, err := NewControlServer(Config{
		APIToken:      "tok",
		WebCertFile:   certPath,
		WebKeyFile:    keyPath,
		WWWDir:        wwwDir,
		WebDir:        webDir,
		ConsoleDomain: "console.example.com",
		ZashListen:    "",
	}, &Controller{})
	if err != nil {
		t.Fatal(err)
	}

	do := func(path string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Host = "console.example.com"
		rec := httptest.NewRecorder()
		cs.srv.Handler.ServeHTTP(rec, req)
		return rec
	}

	if rec := do("/ios/ios-dot.mobileconfig"); rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/x-apple-aspen-config" {
		t.Fatalf("console mobileconfig status/type=%d/%q", rec.Code, rec.Header().Get("Content-Type"))
	}
	if rec := do("/ios/ios-intercept-ca.mobileconfig"); rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/x-apple-aspen-config" {
		t.Fatalf("console interception CA mobileconfig status/type=%d/%q", rec.Code, rec.Header().Get("Content-Type"))
	}
	if rec := do("/api/status"); rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated console API status=%d body=%s, want 401", rec.Code, rec.Body.String())
	}
	if rec := do("/"); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "private console") {
		t.Fatalf("public console SPA status=%d body=%s", rec.Code, rec.Body.String())
	}
}

// newTestControlServer builds a ControlServer with a fixed token for handler
// tests that only exercise the mux/middleware (not TLS listening). Uses a
// throwaway self-signed cert/key pair (via the cert_test.go helper) since
// NewControlServer requires CertFile/KeyFile whenever a token is set.
func newTestControlServer(t *testing.T, token string) *ControlServer {
	t.Helper()
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cfg := Config{
		APIToken: token, WebCertFile: certPath, WebKeyFile: keyPath,
	}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}
	if cs == nil {
		t.Fatalf("NewControlServer returned nil ControlServer for non-empty token")
	}
	return cs
}

func TestNewControlServer_MihomoTLSUnavailableFailsClosed(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cs, err := NewControlServer(Config{
		APIToken:         "tok",
		WebCertFile:      certPath,
		WebKeyFile:       keyPath,
		ZashCertFile:     certPath,
		ZashKeyFile:      keyPath,
		MihomoController: "127.0.0.1:9090",
	}, &Controller{})
	if err != nil {
		t.Fatalf("NewControlServer returned an unexpected constructor error: %v", err)
	}

	rec := doAPI(cs, http.MethodGet, "/api/mihomo/health", nil, "tok", true)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("mihomo health status=%d body=%s, want 503 when controller TLS is unavailable", rec.Code, rec.Body.String())
	}
	if rec := doAPI(cs, http.MethodGet, "/api/status", nil, "tok", true); rec.Code != http.StatusOK {
		t.Fatalf("status endpoint should stay available: code=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestWireMihomoConfigManagement_ClientFailureLeavesConfigAPIUnavailable(t *testing.T) {
	cs, token := newAPITestServer(t)
	certPath, _ := generateSelfSignedCert(t, t.TempDir())

	wireMihomoConfigManagement(cs, Config{
		MihomoController: "127.0.0.1:9090",
		ZashCertFile:     certPath,
	}, func(string, ...any) {})

	rec := doAPI(cs, http.MethodGet, "/api/mihomo/config", nil, token, true)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("config endpoint status=%d body=%s, want 503 when mihomo client wiring fails closed", rec.Code, rec.Body.String())
	}
	if rec := doAPI(cs, http.MethodGet, "/api/status", nil, token, true); rec.Code != http.StatusOK {
		t.Fatalf("status endpoint should stay available: code=%d body=%s", rec.Code, rec.Body.String())
	}
}

// TestAuthMiddleware_EmptyTokenFailsClosed locks the F2 guard: even if a
// ControlServer were constructed with an empty token (NewControlServer refuses
// to, so this builds the struct directly), a request must be REJECTED and never
// slip through via ConstantTimeCompare([]byte{}, []byte{}) == 1 on an empty
// presented value. The middleware must fail closed, never open.
func TestAuthMiddleware_EmptyTokenFailsClosed(t *testing.T) {
	cs := &ControlServer{
		token: "",
	}
	called := false
	h := cs.authMiddleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}))
	cases := []struct {
		name, auth string
		setHeader  bool
	}{
		{"no header", "", false},
		{"empty bearer value", "Bearer ", true},
	}
	for _, tc := range cases {
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
		if tc.setHeader {
			req.Header.Set("Authorization", tc.auth)
		}
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized {
			t.Errorf("%s: status = %d, want 401 (empty configured token must fail closed)", tc.name, rr.Code)
		}
	}
	if called {
		t.Error("next handler was reached with an empty configured token")
	}
}

// Repeated invalid bearer tokens remain authentication failures.
func TestAuthRepeatedFailuresStayUnauthorized(t *testing.T) {
	cs, _ := newAPITestServer(t)
	for i := 0; i < 10; i++ {
		rec := doAPI(cs, http.MethodGet, "/api/status", nil, "wrong-token", true)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("iter %d: code=%d want 401 (no 403 lockout); body=%s", i, rec.Code, rec.Body.String())
		}
	}
}

// newAPITestServer builds an authenticated control server for API tests.
func newAPITestServer(t *testing.T) (*ControlServer, string) {
	t.Helper()
	const token = "test-token"

	reload := func() error { return nil }
	ctrl := NewController(reload, &statsCounters{}, func() int { return 0 }, nil)

	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cfg := Config{
		APIToken: token, WebCertFile: certPath, WebKeyFile: keyPath,
	}
	cs, err := NewControlServer(cfg, ctrl)
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}
	if cs == nil {
		t.Fatalf("NewControlServer returned nil for non-empty token")
	}
	return cs, token
}

// doAuthReq issues a bearer-authenticated request against srv and returns the
// recorder. body is passed as a string for test readability (empty ⇒ no
// body), thinly wrapping doAPI's []byte-or-nil convention.
func doAuthReq(t *testing.T, srv *ControlServer, token, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	var b []byte
	if body != "" {
		b = []byte(body)
	}
	return doAPI(srv, method, path, b, token, true)
}

// doAPI issues req against cs (bearer-authenticated unless auth==false) and
// returns the recorder.
func doAPI(cs *ControlServer, method, path string, body []byte, token string, auth bool) *httptest.ResponseRecorder {
	var r *http.Request
	if body != nil {
		r = httptest.NewRequest(method, path, bytes.NewReader(body))
	} else {
		r = httptest.NewRequest(method, path, nil)
	}
	if auth {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, r)
	return rec
}

func decodeJSON[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("response not JSON: %v (body=%s)", err, rec.Body.String())
	}
	return v
}

// ---------------------------------------------------------------------------
// Auth coverage across every /api/* route
// ---------------------------------------------------------------------------

func TestAPIRoutes_RequireAuth(t *testing.T) {
	cs, _ := newAPITestServer(t)

	routes := []struct {
		method, path string
	}{
		{http.MethodGet, "/api/status"},
		{http.MethodGet, "/api/resolve-test?domain=example.com"},
		{http.MethodGet, "/api/querylog"},
		{http.MethodGet, "/api/upstreams"},
		{http.MethodPut, "/api/upstreams"},
		{http.MethodGet, "/api/ecs"},
		{http.MethodPut, "/api/ecs"},
		{http.MethodGet, "/api/tgbot"},
		{http.MethodPut, "/api/tgbot"},
		{http.MethodGet, "/api/mihomo/ingress-modules"},
		{http.MethodPut, "/api/mihomo/ingress-modules/speedtest-5060"},
		{http.MethodPut, "/api/mihomo/ingress-modules/block-quic-443"},
		{http.MethodGet, "/api/interception/settings"},
		{http.MethodPut, "/api/interception/settings"},
		{http.MethodGet, "/api/interception/modules"},
		{http.MethodPut, "/api/interception/modules/reorder"},
		{http.MethodGet, "/api/interception/modules/io.example.fixture"},
		{http.MethodPost, "/api/interception/modules/import"},
		{http.MethodPost, "/api/interception/modules/io.example.fixture/update-check"},
		{http.MethodPost, "/api/interception/modules/io.example.fixture/update-apply"},
		{http.MethodPut, "/api/interception/modules/io.example.fixture"},
		{http.MethodDelete, "/api/interception/modules/io.example.fixture"},
		{http.MethodGet, "/api/interception/marketplaces"},
		{http.MethodPost, "/api/interception/marketplaces"},
		{http.MethodPost, "/api/interception/marketplaces/io.example.marketplace/refresh"},
		{http.MethodDelete, "/api/interception/marketplaces/io.example.marketplace"},
		{http.MethodPost, "/api/interception/marketplaces/io.example.marketplace/entries/io.example.fixture/install"},
		{http.MethodGet, "/api/geocode/cities?q=Shenzhen"},
	}

	for _, rt := range routes {
		t.Run(rt.method+" "+rt.path, func(t *testing.T) {
			rec := doAPI(cs, rt.method, rt.path, nil, "", false)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401 (no auth); body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

// ---------------------------------------------------------------------------
// GET /api/status
// ---------------------------------------------------------------------------

func TestAPIStatus(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/status", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Version       string `json:"version"`
		UptimeSeconds int    `json:"uptime_seconds"`
		Stats         Stats  `json:"stats"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("response not JSON: %v (%s)", err, rec.Body.String())
	}
	if body.Version == "" {
		t.Errorf("version = %q, want non-empty", body.Version)
	}
	if body.UptimeSeconds < 0 {
		t.Errorf("uptime_seconds = %d, want >= 0", body.UptimeSeconds)
	}
}

// TestAPIStatus_ZashDomain verifies the derived zashboard domain is surfaced
// for the console deep link.
func TestAPIStatus_ZashDomain(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	const token = "test-token"
	cfg := Config{
		APIToken: token, WebCertFile: certPath, WebKeyFile: keyPath,
		ZashDomain: "zash.5gpn.example.com",
	}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]any](t, rec)
	if got := body["zash_domain"]; got != "zash.5gpn.example.com" {
		t.Errorf("zash_domain = %v, want %q", got, "zash.5gpn.example.com")
	}
}

// TestAPIStatus_ZashDomainOmittedWhenUnset asserts the omitempty contract:
// no derived zash domain means the key is absent, not an empty string
// (the frontend treats presence as "zashboard panel available").
func TestAPIStatus_ZashDomainOmittedWhenUnset(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/status", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]any](t, rec)
	if _, ok := body["zash_domain"]; ok {
		t.Errorf("zash_domain present without a configured base domain: %v", body["zash_domain"])
	}
}

// TestAPIStatus_DotDomain locks the setup-guide contract: authenticated
// clients receive the DoT identity derived from DNS_BASE_DOMAIN rather than
// guessing it from the console hostname.
func TestAPIStatus_DotDomain(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	const token = "test-token"
	cfg := Config{
		APIToken: token, WebCertFile: certPath, WebKeyFile: keyPath,
		DotDomain: "dot.5gpn.example.com",
	}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}

	rec := doAPI(cs, http.MethodGet, "/api/status", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]any](t, rec)
	if got := body["dot_domain"]; got != "dot.5gpn.example.com" {
		t.Errorf("dot_domain = %v, want %q", got, "dot.5gpn.example.com")
	}
}

// TestAPIStatus_NeverExposesMihomoSecret verifies the long-lived controller
// credential is not serialized even to an authenticated console client.
func TestAPIStatus_NeverExposesMihomoSecret(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	const token = "test-token"
	cfg := Config{
		APIToken: token, WebCertFile: certPath, WebKeyFile: keyPath,
		MihomoSecret: "controller-s3cr3t",
	}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}

	rec := doAPI(cs, http.MethodGet, "/api/status", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]any](t, rec)
	if got, ok := body["mihomo_secret"]; ok {
		t.Errorf("mihomo_secret leaked in status response: %v", got)
	}
}

func TestAPIStatus_MihomoSecretAbsentWhenUnset(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/status", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]any](t, rec)
	if _, ok := body["mihomo_secret"]; ok {
		t.Errorf("mihomo_secret present with no DNS_MIHOMO_SECRET configured: %v", body["mihomo_secret"])
	}
}

// ---------------------------------------------------------------------------
// Unknown route
// ---------------------------------------------------------------------------

func TestAPIUnknownRoute404(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/nope", nil, token, true)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404; body=%s", rec.Code, rec.Body.String())
	}
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
	var body struct {
		Version       string `json:"version"`
		UptimeSeconds int    `json:"uptime_seconds"`
		Stats         Stats  `json:"stats"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("response body not JSON: %v (%s)", err, rec.Body.String())
	}
	if body.Version == "" {
		t.Errorf("version = %q, want non-empty", body.Version)
	}
	if body.UptimeSeconds < 0 {
		t.Errorf("uptime_seconds = %d, want >= 0", body.UptimeSeconds)
	}
}

// TestControlServer_APIJSON_NoStore asserts control-plane JSON is served with
// Cache-Control: no-store so a private browser cache never persists the
// client-IP/qname PII (/api/querylog) to disk past logout. writeJSON sets it
// centrally, so every /api/* JSON is covered — spot-check status/querylog plus the
// unauthorized 401 (which also flows through writeJSON).
func TestControlServer_APIJSON_NoStore(t *testing.T) {
	cs := newTestControlServer(t, "correct-token")

	for _, tc := range []struct {
		name, path string
		auth       bool
	}{
		{"status", "/api/status", true},
		{"querylog", "/api/querylog", true},
		{"unauthorized", "/api/status", false},
	} {
		rec := doAPI(cs, http.MethodGet, tc.path, nil, "correct-token", tc.auth)
		if got := rec.Header().Get("Cache-Control"); got != "no-store" {
			t.Errorf("%s (%s): Cache-Control = %q, want %q (code=%d)", tc.name, tc.path, got, "no-store", rec.Code)
		}
	}
}

// TestControlServer_WebUI_ServesIndex confirms the SPA placeholder is served at
// "/" when no SPA is deployed (WebDir empty in tests → built-in placeholder).
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

// ---------------------------------------------------------------------------
// Per-source rate limiting
// ---------------------------------------------------------------------------

// newRateLimitedTestServer builds a ControlServer with a tight rate/burst so
// tests can trip the limiter deterministically within a handful of calls.
func newRateLimitedTestServer(t *testing.T, rate float64, burst int) (*ControlServer, string) {
	t.Helper()
	const token = "test-token"
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cfg := Config{
		APIToken: token, WebCertFile: certPath, WebKeyFile: keyPath,
		APIRate: rate, APIBurst: burst,
	}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}
	if cs == nil {
		t.Fatalf("NewControlServer returned nil for non-empty token")
	}
	return cs, token
}

// doAPIFrom is doAPI but with an explicit RemoteAddr, so tests can simulate
// distinct source IPs against the per-source limiter.
func doAPIFrom(cs *ControlServer, method, path, remoteAddr, token string, auth bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, nil)
	r.RemoteAddr = remoteAddr
	if auth {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, r)
	return rec
}

// TestRateLimitMiddleware_TripsAfterBurst confirms repeated hits from the
// same source IP get 429 once the burst is exhausted.
func TestRateLimitMiddleware_TripsAfterBurst(t *testing.T) {
	cs, token := newRateLimitedTestServer(t, 1, 2)
	const addr = "203.0.113.5:5555"

	for i := 0; i < 2; i++ {
		rec := doAPIFrom(cs, http.MethodGet, "/api/status", addr, token, true)
		if rec.Code != http.StatusOK {
			t.Fatalf("call %d status = %d, want 200; body=%s", i+1, rec.Code, rec.Body.String())
		}
	}

	rec := doAPIFrom(cs, http.MethodGet, "/api/status", addr, token, true)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("3rd rapid call status = %d, want 429; body=%s", rec.Code, rec.Body.String())
	}
	if ra := rec.Header().Get("Retry-After"); ra == "" {
		t.Errorf("Retry-After header missing on 429 response")
	}
	body := decodeJSON[map[string]string](t, rec)
	if body["error"] == "" {
		t.Errorf("expected non-empty error message on 429, got %+v", body)
	}
}

// TestRateLimitMiddleware_DifferentSourceStillSucceeds confirms the limiter
// is keyed per-source: a different RemoteAddr is unaffected by another
// source's exhausted bucket.
func TestRateLimitMiddleware_DifferentSourceStillSucceeds(t *testing.T) {
	cs, token := newRateLimitedTestServer(t, 1, 2)

	// Exhaust source A.
	for i := 0; i < 2; i++ {
		doAPIFrom(cs, http.MethodGet, "/api/status", "203.0.113.5:1", token, true)
	}
	if rec := doAPIFrom(cs, http.MethodGet, "/api/status", "203.0.113.5:1", token, true); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("source A 3rd call status = %d, want 429", rec.Code)
	}

	// Source B, brand new bucket, should still succeed.
	rec := doAPIFrom(cs, http.MethodGet, "/api/status", "198.51.100.9:1", token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("source B status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
}

// TestUnauthenticatedRequestsDoNotConsumeAdminRateLimit proves a public caller
// cannot drain the shared loopback bucket before presenting a valid token.
func TestUnauthenticatedRequestsDoNotConsumeAdminRateLimit(t *testing.T) {
	cs, token := newRateLimitedTestServer(t, 1, 1)
	const addr = "203.0.113.7:1"

	rec1 := doAPIFrom(cs, http.MethodGet, "/api/status", addr, "", false)
	if rec1.Code != http.StatusUnauthorized {
		t.Fatalf("1st unauthenticated call status = %d, want 401; body=%s", rec1.Code, rec1.Body.String())
	}
	rec2 := doAPIFrom(cs, http.MethodGet, "/api/status", addr, "", false)
	if rec2.Code != http.StatusUnauthorized {
		t.Fatalf("2nd unauthenticated call status = %d, want 401; body=%s", rec2.Code, rec2.Body.String())
	}
	rec3 := doAPIFrom(cs, http.MethodGet, "/api/status", addr, token, true)
	if rec3.Code != http.StatusOK {
		t.Fatalf("authenticated call after public failures status = %d, want 200; body=%s", rec3.Code, rec3.Body.String())
	}
}

func TestBuildPanelServerHasConnectionLimits(t *testing.T) {
	srv := buildPanelServer("127.0.0.1:443", http.NotFoundHandler(), "cert", "key")
	if srv.ReadHeaderTimeout != panelReadHeaderTimeout || srv.IdleTimeout != panelIdleTimeout {
		t.Fatalf("panel timeouts = (%s, %s)", srv.ReadHeaderTimeout, srv.IdleTimeout)
	}
	if srv.MaxHeaderBytes != panelMaxHeaderBytes {
		t.Fatalf("MaxHeaderBytes = %d, want %d", srv.MaxHeaderBytes, panelMaxHeaderBytes)
	}
	if srv.WriteTimeout != 0 {
		t.Fatalf("WriteTimeout = %s, want zero for WebSocket compatibility", srv.WriteTimeout)
	}
}

// TestRateLimitMiddleware_DisabledNeverLimits confirms APIRate<=0 disables
// rate limiting entirely: many rapid calls from the same source never get
// 429.
func TestRateLimitMiddleware_DisabledNeverLimits(t *testing.T) {
	cs, token := newRateLimitedTestServer(t, 0, 40)
	const addr = "203.0.113.9:1"

	for i := 0; i < 50; i++ {
		rec := doAPIFrom(cs, http.MethodGet, "/api/status", addr, token, true)
		if rec.Code != http.StatusOK {
			t.Fatalf("call %d with rate limiting disabled status = %d, want 200; body=%s", i+1, rec.Code, rec.Body.String())
		}
	}
}

// ---------------------------------------------------------------------------
// Security headers (CSP)
// ---------------------------------------------------------------------------

// TestSecurityHeaders_CSPStyleSplit asserts the defense-in-depth headers on
// both the SPA and API surfaces, including the split style policy:
// style-src-elem locked to 'self' (the production Vite build emits no inline
// <style> elements), style-src-attr 'unsafe-inline' (the SPA's dynamic React
// style={} attributes need it), and the plain style-src kept only as the
// fallback for browsers without the -elem/-attr split.
func TestSecurityHeaders_CSPStyleSplit(t *testing.T) {
	cs := newTestControlServer(t, "correct-token")

	for _, path := range []string{"/", "/api/status"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		cs.srv.Handler.ServeHTTP(rec, req)

		csp := rec.Header().Get("Content-Security-Policy")
		if csp == "" {
			t.Fatalf("%s: Content-Security-Policy header missing", path)
		}
		for _, directive := range []string{
			"default-src 'self'",
			"img-src 'self' data: https://tile.openstreetmap.org",
			"font-src 'self'",                  // bundled MiSans-VF, explicit same-origin allowance
			"style-src 'self' 'unsafe-inline'", // baseline browser fallback
			"style-src-elem 'self'",            // no inline <style> elements in the built SPA
			"style-src-attr 'unsafe-inline'",   // React dynamic style={} attributes
			"worker-src 'self'",                // PWA service worker (vite-plugin-pwa /sw.js)
			"connect-src 'self'",               // same-origin control plane, city search, and wss logs
			"object-src 'none'",
			"base-uri 'self'",
			"frame-ancestors 'none'",
		} {
			if !strings.Contains(csp, directive) {
				t.Errorf("%s: CSP %q missing directive %q", path, csp, directive)
			}
		}
		if got := rec.Header().Get("X-Content-Type-Options"); got != "nosniff" {
			t.Errorf("%s: X-Content-Type-Options = %q, want nosniff", path, got)
		}
		if got := rec.Header().Get("X-Frame-Options"); got != "DENY" {
			t.Errorf("%s: X-Frame-Options = %q, want DENY", path, got)
		}
	}
}

// TestRateLimitMiddleware_DoesNotApplyToSPA confirms only /api/* is
// rate-limited -- the SPA at "/" is unaffected even after the API bucket for
// that source is exhausted.
func TestRateLimitMiddleware_DoesNotApplyToSPA(t *testing.T) {
	cs, token := newRateLimitedTestServer(t, 1, 1)
	const addr = "203.0.113.11:1"

	// Exhaust the API bucket for this source.
	doAPIFrom(cs, http.MethodGet, "/api/status", addr, token, true)
	if rec := doAPIFrom(cs, http.MethodGet, "/api/status", addr, token, true); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("API call over limit status = %d, want 429", rec.Code)
	}

	// The SPA route must still serve normally from the same source.
	rec := doAPIFrom(cs, http.MethodGet, "/", addr, token, false)
	if rec.Code != http.StatusOK {
		t.Fatalf("SPA status = %d, want 200 (not rate-limited); body=%s", rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Second zashboard panel + separated console/zash proxy auth
// ---------------------------------------------------------------------------

// TestControlServer_BothPanelsAndProxy confirms NewControlServer builds a
// second (zash) panel server when cfg.ZashListen is set. The zash /proxy/ is
// gated by an HttpOnly session obtained from a one-use console handoff, while
// the console exposes only health and a one-use-ticket log stream.
func TestControlServer_BothPanelsAndProxy(t *testing.T) {
	const controllerBody = "mihomo-controller-ok"
	var gotAuth, gotPath, gotQuery string
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	mihomo := newMihomoTLSTestServerWithCert(t, certPath, keyPath, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		_, _ = w.Write([]byte(controllerBody))
	}))
	zashDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(zashDir, "index.html"), []byte("<html>zash</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := Config{
		APIToken: "tok", WebCertFile: certPath, WebKeyFile: keyPath,
		ZashCertFile: certPath, ZashKeyFile: keyPath,
		ZashDir: zashDir, ZashListen: "127.0.0.2:0",
		ZashDomain:       mihomo.serverName,
		MihomoController: mihomo.controller, MihomoSecret: "sec",
	}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatal(err)
	}
	if cs.zashSrv == nil {
		t.Fatal("zashSrv not built despite ZashListen set")
	}

	req := httptest.NewRequest(http.MethodGet, "/#/proxies", nil)
	rec := httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "zash") {
		t.Fatalf("zash panel index: status=%d body=%s, want 200 with the zashboard index", rec.Code, rec.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("zash /proxy/ without session status=%d, want 401", rec.Code)
	}
	if gotPath != "" {
		t.Fatalf("zash /proxy/ without session reached controller path %q", gotPath)
	}

	req = httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.Header.Set("Authorization", "Bearer browser-secret")
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("browser Authorization bypass status=%d, want 401", rec.Code)
	}

	// Mint the short-lived handoff through the bearer-authenticated console.
	req = httptest.NewRequest(http.MethodPost, "/api/mihomo/zashboard-handoff", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec = httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("mint zashboard handoff status=%d body=%s", rec.Code, rec.Body.String())
	}
	var handoff struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &handoff); err != nil || handoff.URL == "" {
		t.Fatalf("decode zashboard handoff: err=%v body=%s", err, rec.Body.String())
	}
	handoffURL, err := url.Parse(handoff.URL)
	if err != nil || handoffURL.Path != "/handoff" || handoffURL.Query().Get("ticket") == "" || handoffURL.Query().Get("secret") != "" {
		t.Fatalf("invalid handoff URL %q: %v", handoff.URL, err)
	}

	// The zash origin consumes the ticket once and issues a secure HttpOnly
	// host cookie before redirecting to a setup URL with only a fixed placeholder.
	// GET is deliberately not accepted: zashboard's root-scoped Workbox
	// navigation fallback consumes GET navigations before they reach the
	// daemon. The browser submits this URL as a top-level POST instead.
	req = httptest.NewRequest(http.MethodGet, handoffURL.RequestURI(), nil)
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET handoff status=%d, want 405", rec.Code)
	}

	req = httptest.NewRequest(http.MethodPost, handoffURL.RequestURI(), nil)
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("consume handoff status=%d body=%s", rec.Code, rec.Body.String())
	}
	location := rec.Header().Get("Location")
	if strings.Contains(location, "secret=sec&") || !strings.Contains(location, "secret=5gpn-session") {
		t.Fatalf("handoff redirect contains unsafe or missing setup state: %q", location)
	}
	setupURL, err := url.Parse(location)
	if err != nil || setupURL.Path != "/" {
		t.Fatalf("handoff redirect URL = %q, err=%v; want root path with setup fragment", location, err)
	}
	setupFragment, err := url.Parse(setupURL.Fragment)
	if err != nil || setupFragment.Path != "/setup" {
		t.Fatalf("handoff redirect fragment = %q, err=%v; want /setup", setupURL.Fragment, err)
	}
	setupQuery := setupFragment.Query()
	if setupQuery.Get("hostname") != cfg.ZashDomain || setupQuery.Get("port") != "443" ||
		setupQuery.Get("secret") != "5gpn-session" || setupQuery.Get("secondaryPath") != "/proxy" {
		t.Fatalf("handoff setup query = %v, want fixed zashboard proxy settings", setupQuery)
	}
	cookies := rec.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != zashSessionCookie || !cookies[0].HttpOnly || !cookies[0].Secure || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("zash session cookie = %+v, want one Secure HttpOnly SameSite=Strict cookie", cookies)
	}
	sessionCookie := cookies[0]

	req = httptest.NewRequest(http.MethodPost, handoffURL.RequestURI(), nil)
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("replayed zashboard handoff status=%d, want 401", rec.Code)
	}

	gotPath = ""
	req = httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.AddCookie(sessionCookie)
	req.Header.Set("Authorization", "Bearer attacker-value")
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), controllerBody) {
		t.Fatalf("session zash proxy: status=%d body=%q", rec.Code, rec.Body.String())
	}
	if gotAuth != "Bearer sec" {
		t.Fatalf("zash proxy auth=%q, want daemon-injected controller secret", gotAuth)
	}

	req = httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.AddCookie(sessionCookie)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("cross-site zash proxy status=%d, want 401", rec.Code)
	}

	digest, ok := browserCredentialDigest(sessionCookie.Value)
	if !ok {
		t.Fatal("issued zash session cookie is not canonical")
	}
	cs.zashAuthMu.Lock()
	cs.zashSessions[digest] = time.Now().Add(-time.Second)
	cs.zashAuthMu.Unlock()
	req = httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.AddCookie(sessionCookie)
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expired zash session status=%d, want 401", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec = httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("raw console /proxy/version status=%d, want 404", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/api/mihomo/health", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec = httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), controllerBody) {
		t.Fatalf("/api/mihomo/health: status=%d body=%q", rec.Code, rec.Body.String())
	}
	if gotAuth != "Bearer sec" {
		t.Fatalf("console health proxy auth = %q, want injected controller secret", gotAuth)
	}
	if gotPath != "/version" {
		t.Fatalf("console health upstream path=%q, want /version", gotPath)
	}

	req = httptest.NewRequest(http.MethodPost, "/api/mihomo/log-ticket", nil)
	req.Header.Set("Authorization", "Bearer tok")
	rec = httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("mint log ticket status=%d body=%s", rec.Code, rec.Body.String())
	}
	var ticketResp struct {
		Ticket string `json:"ticket"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &ticketResp); err != nil || ticketResp.Ticket == "" {
		t.Fatalf("decode log ticket: err=%v body=%s", err, rec.Body.String())
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("log ticket Cache-Control=%q, want no-store", got)
	}

	req = httptest.NewRequest(http.MethodGet, "/proxy/logs?level=info&ticket="+ticketResp.Ticket, nil)
	rec = httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), controllerBody) {
		t.Fatalf("ticketed log proxy: status=%d body=%q", rec.Code, rec.Body.String())
	}
	if gotPath != "/logs" || gotQuery != "level=info" {
		t.Fatalf("log upstream path/query=%q?%s, want /logs?level=info", gotPath, gotQuery)
	}
	if gotAuth != "Bearer sec" {
		t.Fatalf("log proxy auth=%q, want injected controller secret", gotAuth)
	}

	req = httptest.NewRequest(http.MethodGet, "/proxy/logs?ticket="+ticketResp.Ticket, nil)
	rec = httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("replayed log ticket status=%d, want 401", rec.Code)
	}
}

// TestControlServer_NoZashWhenListenEmpty confirms zashSrv stays nil when
// cfg.ZashListen is explicitly disabled ("").
func TestControlServer_NoZashWhenListenEmpty(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cfg := Config{
		APIToken: "tok", WebCertFile: certPath, WebKeyFile: keyPath,
		ZashListen: "",
	}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatal(err)
	}
	if cs.zashSrv != nil {
		t.Fatal("zashSrv built despite empty ZashListen")
	}
}

// TestZashSecurityHeaders asserts the zash panel's deliberately permissive CSP
// (zashboard needs inline styles/scripts + blob: workers + wasm eval) plus the
// still-strict clickjacking/MIME-sniffing headers.
func TestZashSecurityHeaders(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	zashDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(zashDir, "index.html"), []byte("<html>zash</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := Config{
		APIToken: "tok", WebCertFile: certPath, WebKeyFile: keyPath,
		ZashCertFile: certPath, ZashKeyFile: keyPath,
		ZashDir: zashDir, ZashListen: "127.0.0.2:0",
		ZashDomain:       "test.local",
		MihomoController: "127.0.0.1:9090", MihomoSecret: "sec",
	}
	cs, err := NewControlServer(cfg, &Controller{})
	if err != nil {
		t.Fatal(err)
	}
	if cs.zashSrv == nil {
		t.Fatal("zashSrv not built")
	}

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)

	csp := rec.Header().Get("Content-Security-Policy")
	if csp == "" {
		t.Fatal("zash panel: Content-Security-Policy header missing")
	}
	for _, directive := range []string{
		"default-src 'self'",
		"img-src 'self' data: blob:",
		"style-src 'self' 'unsafe-inline'",
		"script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'",
		"connect-src 'self'",
		"worker-src 'self' blob:",
		"font-src 'self' data:",
		"object-src 'none'",
		"base-uri 'self'",
	} {
		if !strings.Contains(csp, directive) {
			t.Errorf("zash CSP %q missing directive %q", csp, directive)
		}
	}
	if got := rec.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Errorf("zash X-Content-Type-Options = %q, want nosniff", got)
	}
	if got := rec.Header().Get("X-Frame-Options"); got != "DENY" {
		t.Errorf("zash X-Frame-Options = %q, want DENY", got)
	}
}
