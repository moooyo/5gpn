package main

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// captureAuditLog redirects the standard logger's output to a buffer for the
// duration of the test, restoring it on cleanup. Returns the buffer.
func captureAuditLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	orig := log.Writer()
	origFlags := log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(orig)
		log.SetFlags(origFlags)
	})
	return &buf
}

// auditLines returns only the lines in buf that look like audit records
// (contain "audit "), so assertions aren't tripped up by unrelated log
// output from the same run.
func auditLines(buf *bytes.Buffer) []string {
	var out []string
	for _, line := range strings.Split(buf.String(), "\n") {
		if strings.Contains(line, "audit ") {
			out = append(out, line)
		}
	}
	return out
}

// TestAuditMiddleware_MutatingRequestIsLogged confirms a POST to an /api/*
// route emits exactly one audit line with method/path/src/status populated
// from the real request.
func TestAuditMiddleware_MutatingRequestIsLogged(t *testing.T) {
	cs, token := newAPITestServer(t)
	buf := captureAuditLog(t)

	rec := doAPIFrom(cs, http.MethodPost, "/api/policy/apply", "203.0.113.5:5555", token, true)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("POST /api/policy/apply status = %d, want 503; body=%s", rec.Code, rec.Body.String())
	}

	lines := auditLines(buf)
	if len(lines) != 1 {
		t.Fatalf("audit lines = %d, want 1; log=%q", len(lines), buf.String())
	}
	line := lines[0]
	for _, want := range []string{"method=POST", "path=/api/policy/apply", "src=203.0.113.5", "status=503"} {
		if !strings.Contains(line, want) {
			t.Errorf("audit line %q missing %q", line, want)
		}
	}
}

// TestAuditMiddleware_GETIsNotLogged confirms a read-only GET produces no
// audit line at all.
func TestAuditMiddleware_GETIsNotLogged(t *testing.T) {
	cs, token := newAPITestServer(t)
	buf := captureAuditLog(t)

	rec := doAPI(cs, http.MethodGet, "/api/status", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/status status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	if lines := auditLines(buf); len(lines) != 0 {
		t.Fatalf("audit lines = %d, want 0 for GET; log=%q", len(lines), buf.String())
	}
}

// TestAuditMiddleware_UnauthenticatedMutationIsLogged proves the audit
// middleware wraps auth: a mutating request with no bearer token is still
// recorded, with status=401, since a rejected mutation attempt is itself a
// security-relevant signal.
func TestAuditMiddleware_UnauthenticatedMutationIsLogged(t *testing.T) {
	cs, _ := newAPITestServer(t)
	buf := captureAuditLog(t)

	rec := doAPIFrom(cs, http.MethodDelete, "/api/policy/rules/gfwlist", "198.51.100.9:1", "", false)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated DELETE status = %d, want 401; body=%s", rec.Code, rec.Body.String())
	}

	lines := auditLines(buf)
	if len(lines) != 1 {
		t.Fatalf("audit lines = %d, want 1; log=%q", len(lines), buf.String())
	}
	for _, want := range []string{"method=DELETE", "path=/api/policy/rules/gfwlist", "src=198.51.100.9", "status=401"} {
		if !strings.Contains(lines[0], want) {
			t.Errorf("audit line %q missing %q", lines[0], want)
		}
	}
}

// TestAuditMiddleware_CapturesRealStatus confirms the recorder captures the
// actual response status (not a hardcoded 200) — a DELETE against an unknown
// policy-rule ID that 404s should be logged as status=404.
func TestAuditMiddleware_CapturesRealStatus(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)
	buf := captureAuditLog(t)

	rec := doAPIFrom(cs, http.MethodDelete, "/api/policy/rules/does-not-exist", "203.0.113.5:1", token, true)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("DELETE unknown policy rule status = %d, want 404; body=%s", rec.Code, rec.Body.String())
	}

	lines := auditLines(buf)
	if len(lines) != 1 {
		t.Fatalf("audit lines = %d, want 1; log=%q", len(lines), buf.String())
	}
	if !strings.Contains(lines[0], "status=404") {
		t.Errorf("audit line %q missing status=404", lines[0])
	}
}

// TestAuditMiddleware_RemoteAddrWithoutPortFallsBack confirms that when
// RemoteAddr has no port (so net.SplitHostPort fails), src falls back to the
// raw RemoteAddr value rather than being empty.
func TestAuditMiddleware_RemoteAddrWithoutPortFallsBack(t *testing.T) {
	cs, token := newAPITestServer(t)
	buf := captureAuditLog(t)

	r := httptest.NewRequest(http.MethodPost, "/api/policy/apply", nil)
	r.RemoteAddr = "no-port-host"
	r.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	cs.srv.Handler.ServeHTTP(rec, r)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("POST /api/policy/apply status = %d, want 503; body=%s", rec.Code, rec.Body.String())
	}

	lines := auditLines(buf)
	if len(lines) != 1 {
		t.Fatalf("audit lines = %d, want 1; log=%q", len(lines), buf.String())
	}
	if !strings.Contains(lines[0], "src=no-port-host") {
		t.Errorf("audit line %q missing fallback src=no-port-host", lines[0])
	}
}

// TestAuditMiddleware_DoesNotLogRequestBody proves the audit line never
// contains request-body content (e.g. a subscription URL) or the bearer
// token value — only method/path/src/status.
func TestAuditMiddleware_DoesNotLogRequestBody(t *testing.T) {
	cs, token := newAPITestServer(t)
	buf := captureAuditLog(t)

	body := []byte(`{"id":"secret-sub","matcher":{"kind":"subscription","value":"https://example.com/super-secret-list?token=hunter2","format":"plain","interval":"1h"},"intent":"block","enabled":true}`)
	rec := doAPI(cs, http.MethodPost, "/api/policy/rules", body, token, true)
	_ = rec // status not the point of this test

	lines := auditLines(buf)
	if len(lines) != 1 {
		t.Fatalf("audit lines = %d, want 1; log=%q", len(lines), buf.String())
	}
	if strings.Contains(lines[0], "secret-sub") || strings.Contains(lines[0], "super-secret-list") {
		t.Errorf("audit line leaked request body content: %q", lines[0])
	}
	if strings.Contains(lines[0], token) {
		t.Errorf("audit line leaked bearer token: %q", lines[0])
	}
}
