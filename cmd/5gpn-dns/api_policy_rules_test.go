package main

import (
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

// newPolicyRulesTestServer builds a ControlServer whose Controller has a real
// PolicyRuleManager wired via SetPolicyEngine. No PolicyEngine is wired (nil)
// -- these tests exercise CRUD/fallback only; the apply tests below build
// their own fixture with a full PolicyEngine.
func newPolicyRulesTestServer(t *testing.T) (*ControlServer, string) {
	t.Helper()
	cs, token := newAPITestServer(t)
	dir := t.TempDir()
	polMgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatalf("NewPolicyRuleManager: %v", err)
	}
	cs.ctrl.SetPolicyEngine(polMgr, nil)
	return cs, token
}

// ---------------------------------------------------------------------------
// Auth coverage
// ---------------------------------------------------------------------------

func TestPolicyRulesAPI_RequireAuth(t *testing.T) {
	cs, _ := newPolicyRulesTestServer(t)
	routes := []struct{ method, path string }{
		{http.MethodGet, "/api/policy/rules"},
		{http.MethodPost, "/api/policy/rules"},
		{http.MethodPatch, "/api/policy/rules/foo"},
		{http.MethodDelete, "/api/policy/rules/foo"},
		{http.MethodPut, "/api/policy/rules/reorder"},
		{http.MethodGet, "/api/policy/fallback"},
		{http.MethodPut, "/api/policy/fallback"},
		{http.MethodPost, "/api/policy/apply"},
	}
	for _, rt := range routes {
		t.Run(rt.method+" "+rt.path, func(t *testing.T) {
			rec := doAPI(cs, rt.method, rt.path, nil, "", false)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401; body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Rule CRUD
// ---------------------------------------------------------------------------

func TestPolicyRulesAPI_CreateListPatchDeleteRoundtrip(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)

	// Empty list is a JSON array, never null.
	rec := doAuthReq(t, cs, token, http.MethodGet, "/api/policy/rules", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Fatalf("GET empty body = %q, want []", rec.Body.String())
	}

	// POST create — a block rule, id minted by the manager, never taken from
	// the body.
	body := `{"id":"client-supplied-ignored","matcher":{"kind":"domain-suffix","value":"ads.example.com"},"intent":"block","enabled":true}`
	rec = doAPI(cs, http.MethodPost, "/api/policy/rules", []byte(body), token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	created := decodeJSON[PolicyRule](t, rec)
	if created.ID == "" {
		t.Fatalf("created rule has empty ID")
	}
	if created.ID == "client-supplied-ignored" {
		t.Fatalf("created rule kept the client-supplied ID, want a freshly minted one")
	}

	// GET list includes it.
	rec = doAuthReq(t, cs, token, http.MethodGet, "/api/policy/rules", "")
	list := decodeJSON[[]PolicyRule](t, rec)
	if len(list) != 1 || list[0].ID != created.ID {
		t.Fatalf("list = %+v, want 1 entry with ID %q", list, created.ID)
	}

	// PATCH updates it; the URL id is authoritative over the body.
	patchBody := `{"id":"ignored","matcher":{"kind":"domain-suffix","value":"tracker.example.com"},"intent":"block","enabled":false}`
	rec = doAPI(cs, http.MethodPatch, "/api/policy/rules/"+created.ID, []byte(patchBody), token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	updated := decodeJSON[PolicyRule](t, rec)
	if updated.ID != created.ID {
		t.Fatalf("updated.ID = %q, want the path ID %q", updated.ID, created.ID)
	}
	if updated.Matcher.Value != "tracker.example.com" || updated.Enabled {
		t.Fatalf("updated = %+v, want value=tracker.example.com enabled=false", updated)
	}

	// DELETE removes it.
	rec = doAuthReq(t, cs, token, http.MethodDelete, "/api/policy/rules/"+created.ID, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("DELETE status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	rec = doAuthReq(t, cs, token, http.MethodGet, "/api/policy/rules", "")
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Fatalf("after DELETE = %s, want []", rec.Body.String())
	}
}

func TestPolicyRulesAPI_ReplaceNotFound404(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)
	body := `{"matcher":{"kind":"domain-suffix","value":"example.com"},"intent":"block","enabled":true}`
	rec := doAPI(cs, http.MethodPatch, "/api/policy/rules/does-not-exist", []byte(body), token, true)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404; body=%s", rec.Code, rec.Body.String())
	}
}

func TestPolicyRulesAPI_DeleteNotFound404(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)
	rec := doAuthReq(t, cs, token, http.MethodDelete, "/api/policy/rules/does-not-exist", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404; body=%s", rec.Code, rec.Body.String())
	}
}

func TestPolicyRulesAPI_MalformedBody400(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)
	rec := doAPI(cs, http.MethodPost, "/api/policy/rules", []byte("{not valid json"), token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

// TestPolicyRulesAPI_ProxyIntentNoSelectorNeeded200 proves a proxy-intent
// rule needs nothing beyond the intent enum + matcher shape (binary policy:
// no selector field exists, so there is no "unknown selector"/"egress
// unavailable" failure mode to test anymore).
func TestPolicyRulesAPI_ProxyIntentNoSelectorNeeded200(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)
	body := `{"matcher":{"kind":"domain-suffix","value":"netflix.com"},"intent":"proxy","enabled":true}`
	rec := doAPI(cs, http.MethodPost, "/api/policy/rules", []byte(body), token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Reorder
// ---------------------------------------------------------------------------

func TestPolicyRulesAPI_Reorder(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)

	rec := doAPI(cs, http.MethodPost, "/api/policy/rules",
		[]byte(`{"matcher":{"kind":"domain-suffix","value":"a.example.com"},"intent":"block","enabled":true}`), token, true)
	first := decodeJSON[PolicyRule](t, rec)
	rec = doAPI(cs, http.MethodPost, "/api/policy/rules",
		[]byte(`{"matcher":{"kind":"domain-suffix","value":"b.example.com"},"intent":"block","enabled":true}`), token, true)
	second := decodeJSON[PolicyRule](t, rec)

	reorderBody := `{"ids":["` + second.ID + `","` + first.ID + `"]}`
	rec = doAPI(cs, http.MethodPut, "/api/policy/rules/reorder", []byte(reorderBody), token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("reorder status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	rec = doAuthReq(t, cs, token, http.MethodGet, "/api/policy/rules", "")
	list := decodeJSON[[]PolicyRule](t, rec)
	if len(list) != 2 || list[0].ID != second.ID || list[1].ID != first.ID {
		t.Fatalf("list after reorder = %+v, want [%s, %s]", list, second.ID, first.ID)
	}
}

func TestPolicyRulesAPI_ReorderInvalidIDs400(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)
	rec := doAPI(cs, http.MethodPut, "/api/policy/rules/reorder", []byte(`{"ids":["does-not-exist"]}`), token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Fallback
// ---------------------------------------------------------------------------

func TestPolicyFallbackAPI_Roundtrip(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)

	rec := doAuthReq(t, cs, token, http.MethodGet, "/api/policy/fallback", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	got := decodeJSON[Fallback](t, rec)
	if got.Policy != FallbackAuto {
		t.Fatalf("default fallback policy = %q, want %q", got.Policy, FallbackAuto)
	}

	rec = doAPI(cs, http.MethodPut, "/api/policy/fallback", []byte(`{"policy":"direct"}`), token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	rec = doAuthReq(t, cs, token, http.MethodGet, "/api/policy/fallback", "")
	got = decodeJSON[Fallback](t, rec)
	if got.Policy != FallbackDirect {
		t.Fatalf("fallback policy after PUT = %q, want %q", got.Policy, FallbackDirect)
	}
}

func TestPolicyFallbackAPI_BadPolicyValue400(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)
	rec := doAPI(cs, http.MethodPut, "/api/policy/fallback", []byte(`{"policy":"not-a-policy"}`), token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

func TestPolicyFallbackAPI_GatewayOK200(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t)
	rec := doAPI(cs, http.MethodPut, "/api/policy/fallback", []byte(`{"policy":"gateway"}`), token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Unwired manager: everything nil-degrades / fails closed
// ---------------------------------------------------------------------------

func TestPolicyRulesAPI_UnwiredManagerFailsClosed(t *testing.T) {
	cs, token := newAPITestServer(t) // no SetPolicyEngine call at all

	rec := doAuthReq(t, cs, token, http.MethodGet, "/api/policy/rules", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Fatalf("GET body = %q, want []", rec.Body.String())
	}

	rec = doAuthReq(t, cs, token, http.MethodGet, "/api/policy/fallback", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET fallback status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	const wantStatus = http.StatusServiceUnavailable
	body := `{"matcher":{"kind":"domain-suffix","value":"example.com"},"intent":"block","enabled":true}`
	rec = doAPI(cs, http.MethodPost, "/api/policy/rules", []byte(body), token, true)
	if rec.Code != wantStatus {
		t.Fatalf("POST status = %d, want %d; body=%s", rec.Code, wantStatus, rec.Body.String())
	}
	rec = doAPI(cs, http.MethodPatch, "/api/policy/rules/foo", []byte(body), token, true)
	if rec.Code != wantStatus {
		t.Fatalf("PATCH status = %d, want %d; body=%s", rec.Code, wantStatus, rec.Body.String())
	}
	rec = doAuthReq(t, cs, token, http.MethodDelete, "/api/policy/rules/foo", "")
	if rec.Code != wantStatus {
		t.Fatalf("DELETE status = %d, want %d; body=%s", rec.Code, wantStatus, rec.Body.String())
	}
	rec = doAPI(cs, http.MethodPut, "/api/policy/rules/reorder", []byte(`{"ids":[]}`), token, true)
	if rec.Code != wantStatus {
		t.Fatalf("reorder status = %d, want %d; body=%s", rec.Code, wantStatus, rec.Body.String())
	}
	rec = doAPI(cs, http.MethodPut, "/api/policy/fallback", []byte(`{"policy":"direct"}`), token, true)
	if rec.Code != wantStatus {
		t.Fatalf("PUT fallback status = %d, want %d; body=%s", rec.Code, wantStatus, rec.Body.String())
	}
	rec = doAuthReq(t, cs, token, http.MethodPost, "/api/policy/apply", "")
	if rec.Code != wantStatus {
		t.Fatalf("apply status = %d, want %d; body=%s", rec.Code, wantStatus, rec.Body.String())
	}
}

// ---------------------------------------------------------------------------
// Apply
// ---------------------------------------------------------------------------

// TestPolicyApplyAPI_Success drives POST /api/policy/apply over a full
// PolicyEngine fixture (real PolicyRuleManager + SubManager), reached over
// HTTP through Controller.ApplyPolicy. There is no mihomo side to this apply
// anymore, so unlike the pre-decoupling version of this test, it needs no
// fake `mihomo` binary or base config fixture.
func TestPolicyApplyAPI_Success(t *testing.T) {
	cs, token := newAPITestServer(t)
	dir := t.TempDir()
	rulesDir := filepath.Join(dir, "rules")

	polMgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatalf("NewPolicyRuleManager: %v", err)
	}
	if _, err := polMgr.AddRule(PolicyRule{
		Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindDomainSuffix, Value: "ads.example.com"},
	}); err != nil {
		t.Fatalf("AddRule: %v", err)
	}

	reload := func() error { return nil }
	subMgr, err := NewSubManager(filepath.Join(dir, "subscriptions.json"), rulesDir, reload, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}

	h := &Handler{}
	engine := NewPolicyEngine(polMgr, subMgr, h, reload, rulesDir)
	cs.ctrl.SetPolicyEngine(polMgr, engine)

	rec := doAuthReq(t, cs, token, http.MethodPost, "/api/policy/apply", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	if got := h.decideName("x.ads.example.com").Verdict; got.Reason != "block" {
		t.Errorf("published policy verdict = %+v", got)
	}
}

// TestPolicyApplyAPI_NoEngineUnavailable503 confirms a PolicyRuleManager
// wired without a PolicyEngine (SetPolicyEngine(mgr, nil), e.g. a
// construction ordering where the engine wasn't built) reports apply as
// unavailable rather than panicking on a nil engine dereference.
func TestPolicyApplyAPI_NoEngineUnavailable503(t *testing.T) {
	cs, token := newPolicyRulesTestServer(t) // wires a manager, engine stays nil
	rec := doAuthReq(t, cs, token, http.MethodPost, "/api/policy/apply", "")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503; body=%s", rec.Code, rec.Body.String())
	}
}
