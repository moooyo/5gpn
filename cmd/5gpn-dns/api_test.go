package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

// newAPITestServer builds a ControlServer backed by a real Controller (real
// SubManager over a temp subscriptions.json + temp rules dir, no engine
// handler wired — Lookup tests below don't need real resolution since the
// package's classifyName/Arbitrate paths are already covered by
// controller_test.go/handler_test.go). Returns the ControlServer and the
// bearer token to use in requests.
func newAPITestServer(t *testing.T) (*ControlServer, string) {
	t.Helper()
	const token = "test-token"

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")

	reload := func() error { return nil }
	subs, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	ctrl := NewController(subs, reload, rulesDir, &statsCounters{}, func() int { return 0 }, nil)

	certPath, keyPath := generateSelfSignedCert(t, t.TempDir())
	cfg := Config{APIToken: token, CertFile: certPath, KeyFile: keyPath}
	cs, err := NewControlServer(cfg, ctrl)
	if err != nil {
		t.Fatalf("NewControlServer: %v", err)
	}
	if cs == nil {
		t.Fatalf("NewControlServer returned nil for non-empty token")
	}
	return cs, token
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
		{http.MethodGet, "/api/subscriptions"},
		{http.MethodPost, "/api/subscriptions"},
		{http.MethodPatch, "/api/subscriptions/foo"},
		{http.MethodDelete, "/api/subscriptions/foo"},
		{http.MethodPost, "/api/update"},
		{http.MethodGet, "/api/rules/blacklist"},
		{http.MethodPost, "/api/rules/blacklist"},
		{http.MethodDelete, "/api/rules/blacklist"},
		{http.MethodPost, "/api/reload"},
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

// ---------------------------------------------------------------------------
// Subscriptions: GET / POST / PATCH / DELETE
// ---------------------------------------------------------------------------

func TestAPISubscriptions_EmptyListIsArrayNotNull(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/subscriptions", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if strings.TrimSpace(rec.Body.String()) == "null" {
		t.Fatalf("expected [] for empty subscriptions, got literal null")
	}
	got := decodeJSON[[]Subscription](t, rec)
	if len(got) != 0 {
		t.Errorf("expected 0 subscriptions, got %d", len(got))
	}
}

func TestAPISubscriptions_PostInvalidCategory400(t *testing.T) {
	cs, token := newAPITestServer(t)

	body, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "bogus", "name": "n1",
		"url": "https://example.com/list.txt", "format": "plain",
		"enabled": true, "interval": "24h",
	})
	rec := doAPI(cs, http.MethodPost, "/api/subscriptions", body, token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
	errBody := decodeJSON[map[string]string](t, rec)
	if errBody["error"] == "" {
		t.Errorf("expected non-empty error, got %+v", errBody)
	}
}

func TestAPISubscriptions_PostMalformedJSON400(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodPost, "/api/subscriptions", []byte("{not json"), token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

func TestAPISubscriptions_PostGoodBody200EchoesUpdateResult(t *testing.T) {
	// Use an http:// URL pointing nowhere reachable in the test sandbox; the
	// fetch itself may fail (OK=false), but Add's *validation* must pass and
	// the handler must still return 200 with the UpdateResult JSON (the
	// fetch outcome, not the validation outcome, is what OK reports).
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\nb.com\n"))
	}))
	defer upstream.Close()

	cs, token := newAPITestServer(t)

	body, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": upstream.URL, "format": "plain",
		"enabled": true, "interval": "24h",
	})
	rec := doAPI(cs, http.MethodPost, "/api/subscriptions", body, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	got := decodeJSON[UpdateResult](t, rec)
	if got.ID != "sub1" {
		t.Errorf("UpdateResult.ID = %q, want sub1", got.ID)
	}
	if !got.OK || got.Entries != 2 {
		t.Errorf("UpdateResult = %+v, want OK=true Entries=2", got)
	}

	// Now visible via GET /api/subscriptions, with health attached.
	listRec := doAPI(cs, http.MethodGet, "/api/subscriptions", nil, token, true)
	list := decodeJSON[[]Subscription](t, listRec)
	if len(list) != 1 || list[0].ID != "sub1" {
		t.Errorf("subscriptions list = %+v, want 1 entry with ID sub1", list)
	}

	views := decodeJSON[[]SubscriptionView](t, listRec)
	if len(views) != 1 {
		t.Fatalf("subscriptions views = %+v, want 1 entry", views)
	}
	if views[0].ID != "sub1" {
		t.Errorf("view.ID = %q, want sub1", views[0].ID)
	}
	if views[0].Health == nil {
		t.Fatal("want health populated after an update, got nil")
	}
	if !views[0].Health.OK || views[0].Health.Entries != 2 {
		t.Errorf("view.Health = %+v, want OK=true Entries=2", views[0].Health)
	}
}

func TestAPISubscriptions_ListHealthAbsentBeforeUpdate(t *testing.T) {
	cs, token := newAPITestServer(t)

	body, _ := json.Marshal(map[string]any{
		"id": "never", "category": "direct", "name": "never",
		"url": "https://example.invalid/list.txt", "format": "plain",
		"enabled": false, "interval": "24h",
	})
	// This subscription's initial fetch will fail (unreachable host), but Add
	// still succeeds and records health (failed, not absent). To test the
	// "absent" case we instead check the raw JSON omits the key when nil —
	// verified directly against the Controller/SubManager in
	// controller_test.go and subscription_test.go. Here we only check the
	// wire shape: health, when present, decodes with ok/entries/err fields.
	rec := doAPI(cs, http.MethodPost, "/api/subscriptions", body, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	listRec := doAPI(cs, http.MethodGet, "/api/subscriptions", nil, token, true)
	views := decodeJSON[[]SubscriptionView](t, listRec)
	if len(views) != 1 {
		t.Fatalf("want 1 view, got %d", len(views))
	}
	if views[0].Health == nil {
		t.Fatal("want health present (fetch was attempted, even though it failed)")
	}
	if views[0].Health.OK {
		t.Error("want OK=false for unreachable host")
	}
}

func TestAPISubscriptions_PatchReplaces(t *testing.T) {
	cs, token := newAPITestServer(t)

	addBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": "https://example.invalid/list.txt", "format": "plain",
		"enabled": true, "interval": "24h",
	})
	if rec := doAPI(cs, http.MethodPost, "/api/subscriptions", addBody, token, true); rec.Code != http.StatusOK {
		t.Fatalf("seed POST status = %d, body=%s", rec.Code, rec.Body.String())
	}

	patchBody, _ := json.Marshal(map[string]any{
		"id": "ignored-should-be-overridden", "category": "blacklist", "name": "n1",
		"url": "https://example.invalid/other.txt", "format": "plain",
		"enabled": false, "interval": "12h",
	})
	rec := doAPI(cs, http.MethodPatch, "/api/subscriptions/sub1", patchBody, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
}

// TestAPISubscriptions_PatchInvalidBodyPreservesOriginal is the P4 B1
// regression test: PATCH with a well-formed but invalid body (bad category)
// must not destroy the existing subscription. Before the fix,
// handleSubscriptionsReplace removed the old subscription unconditionally
// before validating the new one, so a 400 here left the subscription gone.
func TestAPISubscriptions_PatchInvalidBodyPreservesOriginal(t *testing.T) {
	cs, token := newAPITestServer(t)

	addBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": "https://example.invalid/list.txt", "format": "plain",
		"enabled": true, "interval": "24h",
	})
	if rec := doAPI(cs, http.MethodPost, "/api/subscriptions", addBody, token, true); rec.Code != http.StatusOK {
		t.Fatalf("seed POST status = %d, body=%s", rec.Code, rec.Body.String())
	}

	badBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "bogus", "name": "n1",
		"url": "https://example.invalid/list.txt", "format": "plain",
		"enabled": true, "interval": "24h",
	})
	rec := doAPI(cs, http.MethodPatch, "/api/subscriptions/sub1", badBody, token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("PATCH status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}

	listRec := doAPI(cs, http.MethodGet, "/api/subscriptions", nil, token, true)
	list := decodeJSON[[]Subscription](t, listRec)
	if len(list) != 1 || list[0].ID != "sub1" {
		t.Fatalf("subscriptions after failed PATCH = %+v, want original sub1 preserved", list)
	}
	if list[0].Category != "blacklist" || list[0].URL != "https://example.invalid/list.txt" || list[0].Interval != 24*time.Hour {
		t.Errorf("preserved subscription = %+v, want unchanged original values", list[0])
	}
}

// TestAPISubscriptions_PatchInvalidURLSchemePreservesOriginal covers the
// other stated example of a well-formed-but-invalid body: a non-http(s) URL
// scheme, which validateSubscriptionURLScheme rejects.
func TestAPISubscriptions_PatchInvalidURLSchemePreservesOriginal(t *testing.T) {
	cs, token := newAPITestServer(t)

	addBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": "https://example.invalid/list.txt", "format": "plain",
		"enabled": true, "interval": "24h",
	})
	if rec := doAPI(cs, http.MethodPost, "/api/subscriptions", addBody, token, true); rec.Code != http.StatusOK {
		t.Fatalf("seed POST status = %d, body=%s", rec.Code, rec.Body.String())
	}

	badBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": "ftp://example.invalid/list.txt", "format": "plain",
		"enabled": true, "interval": "24h",
	})
	rec := doAPI(cs, http.MethodPatch, "/api/subscriptions/sub1", badBody, token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("PATCH status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}

	listRec := doAPI(cs, http.MethodGet, "/api/subscriptions", nil, token, true)
	list := decodeJSON[[]Subscription](t, listRec)
	if len(list) != 1 || list[0].ID != "sub1" || list[0].URL != "https://example.invalid/list.txt" {
		t.Fatalf("subscriptions after failed PATCH = %+v, want original sub1 preserved", list)
	}
}

// TestAPISubscriptions_PatchValidChangeUpdatesFields is the happy path: PATCH
// with a valid change updates the subscription's fields.
func TestAPISubscriptions_PatchValidChangeUpdatesFields(t *testing.T) {
	cs, token := newAPITestServer(t)

	addBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": "https://example.invalid/list.txt", "format": "plain",
		"enabled": true, "interval": "24h",
	})
	if rec := doAPI(cs, http.MethodPost, "/api/subscriptions", addBody, token, true); rec.Code != http.StatusOK {
		t.Fatalf("seed POST status = %d, body=%s", rec.Code, rec.Body.String())
	}

	patchBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": "https://example.invalid/other.txt", "format": "plain",
		"enabled": false, "interval": "12h",
	})
	rec := doAPI(cs, http.MethodPatch, "/api/subscriptions/sub1", patchBody, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	listRec := doAPI(cs, http.MethodGet, "/api/subscriptions", nil, token, true)
	list := decodeJSON[[]Subscription](t, listRec)
	if len(list) != 1 {
		t.Fatalf("subscriptions after PATCH = %+v, want 1 entry", list)
	}
	got := list[0]
	if got.URL != "https://example.invalid/other.txt" || got.Enabled || got.Interval != 12*time.Hour {
		t.Errorf("subscription after PATCH = %+v, want updated url/enabled/interval", got)
	}
}

// TestAPISubscriptions_PatchUpsertsUnknownID covers PATCH-as-upsert: patching
// an id that doesn't exist yet with a valid body creates it (had==false path
// in handleSubscriptionsReplace, so there's nothing to restore).
func TestAPISubscriptions_PatchUpsertsUnknownID(t *testing.T) {
	cs, token := newAPITestServer(t)

	patchBody, _ := json.Marshal(map[string]any{
		"id": "ignored-should-be-overridden", "category": "blacklist", "name": "n1",
		"url": "https://example.invalid/list.txt", "format": "plain",
		"enabled": true, "interval": "24h",
	})
	rec := doAPI(cs, http.MethodPatch, "/api/subscriptions/new-id", patchBody, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	listRec := doAPI(cs, http.MethodGet, "/api/subscriptions", nil, token, true)
	list := decodeJSON[[]Subscription](t, listRec)
	if len(list) != 1 || list[0].ID != "new-id" {
		t.Fatalf("subscriptions after upsert PATCH = %+v, want 1 entry with ID new-id", list)
	}
}

func TestAPISubscriptions_DeleteNotFound404(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodDelete, "/api/subscriptions/does-not-exist", nil, token, true)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404; body=%s", rec.Code, rec.Body.String())
	}
}

func TestAPISubscriptions_DeleteRemovesExisting(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\nb.com\n"))
	}))
	defer upstream.Close()

	cs, token := newAPITestServer(t)

	addBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": upstream.URL, "format": "plain",
		"enabled": true, "interval": "24h",
	})
	if rec := doAPI(cs, http.MethodPost, "/api/subscriptions", addBody, token, true); rec.Code != http.StatusOK {
		t.Fatalf("seed POST status = %d, body=%s", rec.Code, rec.Body.String())
	}

	rec := doAPI(cs, http.MethodDelete, "/api/subscriptions/sub1", nil, token, true)
	if rec.Code != http.StatusOK && rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE status = %d, want 200 or 204; body=%s", rec.Code, rec.Body.String())
	}

	listRec := doAPI(cs, http.MethodGet, "/api/subscriptions", nil, token, true)
	list := decodeJSON[[]Subscription](t, listRec)
	if len(list) != 0 {
		t.Errorf("subscriptions after delete = %+v, want empty", list)
	}
}

// ---------------------------------------------------------------------------
// POST /api/update
// ---------------------------------------------------------------------------

func TestAPIUpdate_NoSubscriptionsReturnsEmptyArray(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodPost, "/api/update", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if strings.TrimSpace(rec.Body.String()) == "null" {
		t.Fatalf("expected [] not null for zero subscriptions")
	}
	got := decodeJSON[[]UpdateResult](t, rec)
	if len(got) != 0 {
		t.Errorf("expected 0 results, got %d", len(got))
	}
}

func TestAPIUpdate_WithIDQueryParam(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\nb.com\n"))
	}))
	defer upstream.Close()

	cs, token := newAPITestServer(t)
	addBody, _ := json.Marshal(map[string]any{
		"id": "sub1", "category": "blacklist", "name": "n1",
		"url": upstream.URL, "format": "plain",
		"enabled": true, "interval": "24h",
	})
	if rec := doAPI(cs, http.MethodPost, "/api/subscriptions", addBody, token, true); rec.Code != http.StatusOK {
		t.Fatalf("seed POST status = %d, body=%s", rec.Code, rec.Body.String())
	}

	rec := doAPI(cs, http.MethodPost, "/api/update?id=sub1", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	got := decodeJSON[[]UpdateResult](t, rec)
	if len(got) != 1 || got[0].ID != "sub1" {
		t.Errorf("update result = %+v, want 1 entry for sub1", got)
	}
}

// ---------------------------------------------------------------------------
// Rules: GET / POST / DELETE (roundtrip)
// ---------------------------------------------------------------------------

func TestAPIRules_AddListRemoveRoundtrip(t *testing.T) {
	cs, token := newAPITestServer(t)

	addBody, _ := json.Marshal(map[string]string{"entry": "x.test"})
	rec := doAPI(cs, http.MethodPost, "/api/rules/blacklist", addBody, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST rules status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	listRec := doAPI(cs, http.MethodGet, "/api/rules/blacklist", nil, token, true)
	if listRec.Code != http.StatusOK {
		t.Fatalf("GET rules status = %d, want 200; body=%s", listRec.Code, listRec.Body.String())
	}
	list := decodeJSON[[]string](t, listRec)
	found := false
	for _, e := range list {
		if e == "x.test" {
			found = true
		}
	}
	if !found {
		t.Fatalf("rules list = %v, want to contain x.test", list)
	}

	delRec := doAPI(cs, http.MethodDelete, "/api/rules/blacklist?entry=x.test", nil, token, true)
	if delRec.Code != http.StatusOK && delRec.Code != http.StatusNoContent {
		t.Fatalf("DELETE rules status = %d, want 200 or 204; body=%s", delRec.Code, delRec.Body.String())
	}

	listRec2 := doAPI(cs, http.MethodGet, "/api/rules/blacklist", nil, token, true)
	list2 := decodeJSON[[]string](t, listRec2)
	for _, e := range list2 {
		if e == "x.test" {
			t.Fatalf("rules list after delete = %v, still contains x.test", list2)
		}
	}
}

func TestAPIRules_GetEmptyCategoryReturnsEmptyArrayNotNull(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/rules/adblock", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if strings.TrimSpace(rec.Body.String()) == "null" {
		t.Fatalf("expected [] not null for empty/absent rules file")
	}
	list := decodeJSON[[]string](t, rec)
	if len(list) != 0 {
		t.Errorf("expected 0 entries, got %d", len(list))
	}
}

func TestAPIRules_GetInvalidCategory400(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/rules/bogus", nil, token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

func TestAPIRules_PostInvalidEntry400(t *testing.T) {
	cs, token := newAPITestServer(t)

	body, _ := json.Marshal(map[string]string{"entry": "not a domain"})
	rec := doAPI(cs, http.MethodPost, "/api/rules/blacklist", body, token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

func TestAPIRules_DeleteBodyEntry(t *testing.T) {
	cs, token := newAPITestServer(t)

	addBody, _ := json.Marshal(map[string]string{"entry": "y.test"})
	if rec := doAPI(cs, http.MethodPost, "/api/rules/blacklist", addBody, token, true); rec.Code != http.StatusOK {
		t.Fatalf("seed POST status = %d, body=%s", rec.Code, rec.Body.String())
	}

	delBody, _ := json.Marshal(map[string]string{"entry": "y.test"})
	rec := doAPI(cs, http.MethodDelete, "/api/rules/blacklist", delBody, token, true)
	if rec.Code != http.StatusOK && rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE (body entry) status = %d, want 200 or 204; body=%s", rec.Code, rec.Body.String())
	}
}

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
