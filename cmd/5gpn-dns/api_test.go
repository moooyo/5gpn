package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestControlServer_ProfileSNIServesOnlyIOS(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	wwwDir, _ := writeIOSFixtures(t)
	webDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(webDir, "index.html"), []byte("<html>private console</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	cs, err := NewControlServer(Config{
		APIToken:      "tok",
		CertFile:      certPath,
		KeyFile:       keyPath,
		WWWDir:        wwwDir,
		WebDir:        webDir,
		ProfileDomain: "profile.example.com",
		ConsoleDomain: "console.example.com",
		ZashListen:    "",
	}, &Controller{})
	if err != nil {
		t.Fatal(err)
	}

	do := func(path, sni, host string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Host = host
		req.TLS = &tls.ConnectionState{ServerName: sni}
		rec := httptest.NewRecorder()
		cs.srv.Handler.ServeHTTP(rec, req)
		return rec
	}

	if rec := do("/ios/ios-dot.mobileconfig", "profile.example.com", "profile.example.com:443"); rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/x-apple-aspen-config" {
		t.Fatalf("profile SNI mobileconfig status/type=%d/%q", rec.Code, rec.Header().Get("Content-Type"))
	}
	if rec := do("/api/status", "profile.example.com", "profile.example.com"); rec.Code != http.StatusNotFound {
		t.Fatalf("profile SNI reached console API: status=%d body=%s", rec.Code, rec.Body.String())
	}
	if rec := do("/", "profile.example.com", "profile.example.com"); rec.Code != http.StatusTemporaryRedirect || rec.Header().Get("Location") != "/ios/" {
		t.Fatalf("profile root status/location=%d/%q, want 307 /ios/", rec.Code, rec.Header().Get("Location"))
	}
	if rec := do("/", "profile.example.com", "console.example.com"); rec.Code != http.StatusMisdirectedRequest {
		t.Fatalf("profile SNI with spoofed console Host status=%d, want 421", rec.Code)
	}
	if rec := do("/", "console.example.com", "console.example.com"); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "private console") {
		t.Fatalf("console SNI no longer reaches console SPA: status=%d body=%s", rec.Code, rec.Body.String())
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
		APIToken: token, CertFile: certPath, KeyFile: keyPath,
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

// TestAuth_NoIPLockout locks the Task 7 reversal: the control plane now binds
// loopback and is IP-gated by mihomo (source-IP allowlisting happens at the
// proxy layer, before a connection ever reaches this listener), so the
// in-process fail2ban-style IP lockout (authBlocker) is gone. Presenting a
// wrong bearer token any number of times must always return 401 — never a
// 403 lockout, regardless of how many consecutive failures precede it.
func TestAuth_NoIPLockout(t *testing.T) {
	cs, _ := newAPITestServer(t)
	for i := 0; i < 10; i++ {
		rec := doAPI(cs, http.MethodGet, "/api/status", nil, "wrong-token", true)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("iter %d: code=%d want 401 (no 403 lockout); body=%s", i, rec.Code, rec.Body.String())
		}
	}
}

// newAPITestServerWithDir is the shared builder behind newAPITestServer: a
// ControlServer backed by a real Controller (real SubManager over a temp
// subscriptions.json + temp rules dir, no engine handler wired — Lookup
// tests below don't need real resolution since the package's
// classifyName/Arbitrate paths are already covered by
// controller_test.go/handler_test.go). Returns the ControlServer, the bearer
// token to use in requests, and the temp rules directory.
func newAPITestServerWithDir(t *testing.T) (*ControlServer, string, string) {
	t.Helper()
	const token = "test-token"

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")

	reload := func() error { return nil }
	subs, err := NewSubManager(subPath, rulesDir, reload, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	ctrl := NewController(subs, reload, rulesDir, &statsCounters{}, func() int { return 0 }, nil)

	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cfg := Config{
		APIToken: token, CertFile: certPath, KeyFile: keyPath,
	}
	cs, err := NewControlServer(cfg, ctrl)
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}
	if cs == nil {
		t.Fatalf("NewControlServer returned nil for non-empty token")
	}
	return cs, token, rulesDir
}

// newAPITestServer is newAPITestServerWithDir without the rules dir, for the
// majority of tests that don't need to touch rule files on disk directly.
func newAPITestServer(t *testing.T) (*ControlServer, string) {
	t.Helper()
	cs, token, _ := newAPITestServerWithDir(t)
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
		{http.MethodGet, "/api/stats"},
		{http.MethodGet, "/api/lookup?domain=example.com"},
		{http.MethodGet, "/api/resolve-test?domain=example.com"},
		{http.MethodGet, "/api/querylog"},
		{http.MethodGet, "/api/upstreams"},
		{http.MethodPut, "/api/upstreams"},
		{http.MethodPost, "/api/reload"},
		{http.MethodGet, "/api/ecs"},
		{http.MethodPut, "/api/ecs"},
		{http.MethodGet, "/api/tgbot"},
		{http.MethodPut, "/api/tgbot"},
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

func TestAPILegacyDraftRoutesGone(t *testing.T) {
	cs, token := newAPITestServer(t)
	for _, rt := range []struct{ method, path string }{
		{http.MethodGet, "/api/capabilities"},
		{http.MethodGet, "/api/drafts"},
		{http.MethodPost, "/api/drafts/example/validate"},
		{http.MethodPost, "/api/drafts/example/resolve-test"},
	} {
		rec := doAPI(cs, rt.method, rt.path, nil, token, true)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("%s %s status = %d, want 404; body=%s", rt.method, rt.path, rec.Code, rec.Body.String())
		}
	}
}

// TestAPIEgressRoutesGone locks the 2026-07-15 policy/mihomo decoupling
// removal: /api/egress/* (node-subs, rule-subs, split-rules, selectors,
// selectors/{id}/select, apply) no longer exists -- egress routing is now
// the operator's raw mihomo config (GET/PUT /api/mihomo/config), not a
// daemon-managed structured model. Uses a VALID token so a 404 actually
// proves "no such route" rather than being masked by the 401 auth gate
// TestAPIRoutes_RequireAuth exercises above.
func TestAPIEgressRoutesGone(t *testing.T) {
	cs, token := newAPITestServer(t)

	routes := []struct {
		method, path string
	}{
		{http.MethodGet, "/api/egress/node-subs"},
		{http.MethodGet, "/api/egress/rule-subs"},
		{http.MethodGet, "/api/egress/split-rules"},
		{http.MethodGet, "/api/egress/selectors"},
		{http.MethodPut, "/api/egress/selectors/foo/select"},
		{http.MethodPost, "/api/egress/apply"},
	}

	for _, rt := range routes {
		t.Run(rt.method+" "+rt.path, func(t *testing.T) {
			rec := doAPI(cs, rt.method, rt.path, nil, token, true)
			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404 (route removed); body=%s", rec.Code, rec.Body.String())
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

// TestAPIStatus_ZashDomain locks the A5 addition: /api/status surfaces the
// configured zashboard panel domain (DNS_ZASH_DOMAIN) so the mihomo console
// page (C3) can deep-link into zashboard without scraping location.host.
func TestAPIStatus_ZashDomain(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	const token = "test-token"
	cfg := Config{
		APIToken: token, CertFile: certPath, KeyFile: keyPath,
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
// no DNS_ZASH_DOMAIN configured means the key is absent, not an empty string
// (the frontend treats presence as "zashboard panel available").
func TestAPIStatus_ZashDomainOmittedWhenUnset(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/status", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]any](t, rec)
	if _, ok := body["zash_domain"]; ok {
		t.Errorf("zash_domain present with no DNS_ZASH_DOMAIN configured: %v", body["zash_domain"])
	}
}

// TestAPIStatus_MihomoSecret locks the Task 7 addition (design §5.3): the
// TOKEN-GATED GET /api/status includes mihomo_secret so an authenticated
// console admin's "前往 zash" deep-link can carry it (URL-encoded) and
// auto-auth into zashboard's pass-through /proxy/ mount.
func TestAPIStatus_MihomoSecret(t *testing.T) {
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	const token = "test-token"
	cfg := Config{
		APIToken: token, CertFile: certPath, KeyFile: keyPath,
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
	if got := body["mihomo_secret"]; got != "controller-s3cr3t" {
		t.Errorf("mihomo_secret = %v, want %q", got, "controller-s3cr3t")
	}
}

// TestAPIStatus_MihomoSecretOmittedWhenUnset mirrors the zash_domain
// omitempty contract: no DNS_MIHOMO_SECRET configured means the key is
// absent, not an empty string.
func TestAPIStatus_MihomoSecretOmittedWhenUnset(t *testing.T) {
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
// GET /api/stats
// ---------------------------------------------------------------------------

func TestAPIStats(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/stats", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	got := decodeJSON[Stats](t, rec)
	want := Stats{}
	if got != want {
		t.Errorf("Stats = %+v, want zero value %+v", got, want)
	}
}

// ---------------------------------------------------------------------------
// GET /api/lookup
// ---------------------------------------------------------------------------

func TestAPILookup_MissingDomain(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/lookup", nil, token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]string](t, rec)
	if body["error"] == "" {
		t.Errorf("expected non-empty error message, got %+v", body)
	}
}

func TestAPILookup_NilHandlerZeroValue(t *testing.T) {
	// newAPITestServer's Controller has a nil engine handler, so Lookup
	// returns a zero-value LookupResult -- this test only asserts the HTTP
	// plumbing (200 + well-formed JSON), not resolution behavior (that's
	// controller_test.go's job).
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/lookup?domain=example.com", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	got := decodeJSON[LookupResult](t, rec)
	if got.Name != "" {
		t.Errorf("Name = %q, want empty (nil-handler zero value)", got.Name)
	}
}

// NOTE (UP-1 Task D3): the managed DNS-subscription (GET/POST/PATCH/DELETE
// /api/subscriptions*), manual per-category rules (GET/POST/DELETE
// /api/rules/{cat}), and manual refresh (POST /api/update) endpoint tests
// were REMOVED here — the HTTP surface they covered is gone, absorbed by the
// unified policy-rule model (see api_policy_rules_test.go for
// /api/policy/rules + /api/policy/fallback + /api/policy/apply coverage).
// newRuleTestServer (the rules-dir-exposing test server variant those tests
// used) was removed alongside them as now-unused.

// ---------------------------------------------------------------------------
// POST /api/reload
// ---------------------------------------------------------------------------

func TestAPIReload(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodPost, "/api/reload", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]bool](t, rec)
	if !body["ok"] {
		t.Errorf("body = %+v, want ok=true", body)
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
// mihomo_secret (/api/status, polled every 5s) or client-IP/qname PII
// (/api/querylog) to disk past logout. writeJSON sets it centrally, so every
// /api/* JSON is covered — spot-check the two most sensitive endpoints plus the
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
// Phase 4 Task C1: per-source rate limiting
// ---------------------------------------------------------------------------

// newRateLimitedTestServer builds a ControlServer with a tight rate/burst so
// tests can trip the limiter deterministically within a handful of calls.
func newRateLimitedTestServer(t *testing.T, rate float64, burst int) (*ControlServer, string) {
	t.Helper()
	const token = "test-token"
	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cfg := Config{
		APIToken: token,
		CertFile: certPath,
		KeyFile:  keyPath,
		APIRate:  rate,
		APIBurst: burst,
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

// TestRateLimitMiddleware_FiresBeforeAuth proves the rate limiter wraps the
// auth middleware: a request over the limit with NO bearer token still gets
// 429 (not 401), because the limiter runs first.
func TestRateLimitMiddleware_FiresBeforeAuth(t *testing.T) {
	cs, _ := newRateLimitedTestServer(t, 1, 1)
	const addr = "203.0.113.7:1"

	// First call (unauthenticated) consumes the single token and gets 401.
	rec1 := doAPIFrom(cs, http.MethodGet, "/api/status", addr, "", false)
	if rec1.Code != http.StatusUnauthorized {
		t.Fatalf("1st unauthenticated call status = %d, want 401; body=%s", rec1.Code, rec1.Body.String())
	}

	// Second call, still unauthenticated and still over the (now exhausted)
	// limit, must get 429 -- proving the limiter fired before auth even ran
	// (an auth-first order would yield 401 again here).
	rec2 := doAPIFrom(cs, http.MethodGet, "/api/status", addr, "", false)
	if rec2.Code != http.StatusTooManyRequests {
		t.Fatalf("2nd unauthenticated call over limit status = %d, want 429; body=%s", rec2.Code, rec2.Body.String())
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
			"img-src 'self' data:",
			"font-src 'self'",                  // bundled MiSans-VF, explicit same-origin allowance
			"style-src 'self' 'unsafe-inline'", // legacy fallback only
			"style-src-elem 'self'",            // no inline <style> elements in the built SPA
			"style-src-attr 'unsafe-inline'",   // React dynamic style={} attributes
			"worker-src 'self'",                // PWA service worker (vite-plugin-pwa /sw.js)
			"connect-src 'self'",               // same-origin /proxy/* mihomo REST + wss logs
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
// SP-3 Task A3: second zashboard panel + separated console/zash proxy auth
// ---------------------------------------------------------------------------

// TestControlServer_BothPanelsAndProxy confirms NewControlServer builds a
// second (zash) panel server when cfg.ZashListen is set. The zash /proxy/
// remains controller-secret pass-through, while the console exposes only an
// authenticated health endpoint and a one-use-ticket log stream.
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
		APIToken: "tok", CertFile: certPath, KeyFile: keyPath,
		WebCertFile: certPath, WebKeyFile: keyPath,
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
	if !strings.Contains(rec.Body.String(), controllerBody) {
		t.Fatalf("/proxy/ on the zash mux: body=%q, want it to reach the fake mihomo controller (%q)", rec.Body.String(), controllerBody)
	}
	if gotAuth != "" {
		t.Fatalf("zash /proxy/ mount injected Authorization %q for a request with none; must pass through unchanged", gotAuth)
	}

	req = httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.Header.Set("Authorization", "Bearer browser-secret")
	rec = httptest.NewRecorder()
	cs.zashSrv.Handler.ServeHTTP(rec, req)
	if gotAuth != "Bearer browser-secret" {
		t.Fatalf("zash /proxy/ mount auth = %q, want the browser's own Authorization forwarded unchanged", gotAuth)
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
		APIToken: "tok", CertFile: certPath, KeyFile: keyPath,
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
		APIToken: "tok", CertFile: certPath, KeyFile: keyPath,
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
