package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPolicyModelJSONRoundTrip(t *testing.T) {
	in := PolicyModel{
		Version: 1,
		Rules: []PolicyRule{
			{ID: "r1", Order: 0, Intent: IntentBlock, Enabled: true,
				Matcher: Matcher{Kind: KindDomainSuffix, Value: "ads.example.com"}},
			{ID: "r2", Order: 1, Intent: IntentProxy, Enabled: true,
				Matcher: Matcher{Kind: KindSubscription, Value: "https://x/gfw.txt", Format: "plain", Interval: 24 * time.Hour}},
		},
		Fallback: Fallback{Policy: FallbackAuto},
	}
	data, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if want := `"interval":"24h0m0s"`; !containsJSON(data, want) {
		t.Fatalf("interval not rendered as duration string: %s", data)
	}
	if containsJSON(data, `"selector"`) || containsJSON(data, `"default_selector"`) {
		t.Fatalf("binary policy must never marshal a selector/default_selector field: %s", data)
	}
	var out PolicyModel
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Rules[1].Matcher.Interval != 24*time.Hour {
		t.Fatalf("interval round-trip lost: got %v", out.Rules[1].Matcher.Interval)
	}
	if out.Fallback.Policy != FallbackAuto {
		t.Fatalf("fallback lost: %+v", out.Fallback)
	}
}

// TestPolicyModelJSONIgnoresStraySelectorFields proves a policy.json/wire
// payload written by an older (pre-decoupling) client — which still carries
// a "selector" on a rule and a "default_selector" on the fallback — round-
// trips cleanly: encoding/json silently drops fields the target struct no
// longer declares, so the binary-policy model is unaffected by leftover keys
// rather than erroring or resurrecting the field.
func TestPolicyModelJSONIgnoresStraySelectorFields(t *testing.T) {
	raw := `{
		"version": 1,
		"rules": [
			{"id":"r1","order":0,"intent":"proxy","selector":"Proxies","enabled":true,
			 "matcher":{"kind":"domain","value":"example.com"}}
		],
		"fallback": {"policy":"auto","default_selector":"Proxies"}
	}`
	var m PolicyModel
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(m.Rules) != 1 || m.Rules[0].Intent != IntentProxy || m.Rules[0].Matcher.Value != "example.com" {
		t.Fatalf("rule round-trip: %+v", m.Rules)
	}
	if m.Fallback.Policy != FallbackAuto {
		t.Fatalf("fallback round-trip: %+v", m.Fallback)
	}

	// Re-marshal must produce exactly {"policy":"auto"} for fallback — no
	// default_selector key resurrected.
	data, err := json.Marshal(m.Fallback)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"policy":"auto"}` {
		t.Fatalf("re-marshaled fallback = %s, want {\"policy\":\"auto\"}", data)
	}
}

func containsJSON(b []byte, sub string) bool { return string(b) != "" && indexOf(string(b), sub) >= 0 }
func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func TestLoadPolicyModelMissingFileIsEmpty(t *testing.T) {
	m, err := LoadPolicyModel(t.TempDir() + "/nope.json")
	if err != nil {
		t.Fatalf("missing file must not error: %v", err)
	}
	if m.Fallback.Policy != FallbackAuto {
		t.Fatalf("missing file must default to auto: %+v", m.Fallback)
	}
}

// ---------------------------------------------------------------------------
// PolicyRuleManager
// ---------------------------------------------------------------------------

func TestPolicyManagerCRUDReorder(t *testing.T) {
	path := t.TempDir() + "/policy.json"
	m, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}

	a, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "a.com"}})
	if err != nil {
		t.Fatal(err)
	}
	b, err := m.AddRule(PolicyRule{Intent: IntentProxy, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "b.com"}})
	if err != nil {
		t.Fatal(err)
	}
	if a.ID == "" || a.Order != 0 || b.Order != 1 {
		t.Fatalf("orders: %+v %+v", a, b)
	}
	if b.ID == "" || a.ID == b.ID {
		t.Fatalf("each rule must get a distinct minted ID: %+v %+v", a, b)
	}

	if err := m.Reorder([]string{b.ID, a.ID}); err != nil {
		t.Fatal(err)
	}
	if got := m.Rules(); got[0].ID != b.ID || got[0].Order != 0 || got[1].ID != a.ID || got[1].Order != 1 {
		t.Fatalf("reorder: %+v", got)
	}

	// persisted round-trip
	m2, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := m2.Rules(); len(got) != 2 || got[0].ID != b.ID {
		t.Fatalf("reload: %+v", got)
	}

	if err := m.DeleteRule(a.ID); err != nil {
		t.Fatal(err)
	}
	if len(m.Rules()) != 1 {
		t.Fatalf("delete failed")
	}
}

func TestPolicyManagerUpdateRulePreservesOrderAndID(t *testing.T) {
	path := t.TempDir() + "/policy.json"
	m, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}
	a, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "a.com"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "b.com"}}); err != nil {
		t.Fatal(err)
	}

	// Update by path-id: even if the caller's payload carries a different
	// (or empty) ID/Order, the id parameter and the original Order win.
	updated, err := m.UpdateRule(a.ID, PolicyRule{ID: "bogus", Order: 99, Intent: IntentDirect, Enabled: false,
		Matcher: Matcher{Kind: KindDomainKeyword, Value: "ads"}})
	if err != nil {
		t.Fatal(err)
	}
	if updated.ID != a.ID {
		t.Fatalf("UpdateRule must keep the path id, got %q want %q", updated.ID, a.ID)
	}
	if updated.Order != 0 {
		t.Fatalf("UpdateRule must preserve the existing Order, got %d want 0", updated.Order)
	}
	if updated.Intent != IntentDirect || updated.Matcher.Value != "ads" {
		t.Fatalf("update did not apply new fields: %+v", updated)
	}

	if _, err := m.UpdateRule("does-not-exist", PolicyRule{Intent: IntentBlock}); !errors.Is(err, ErrPolicyNotFound) {
		t.Fatalf("update of unknown id: got %v, want ErrPolicyNotFound", err)
	}
}

func TestPolicyManagerReorderRejectsMismatchedIDSet(t *testing.T) {
	path := t.TempDir() + "/policy.json"
	m, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}
	a, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "a.com"}})
	if err != nil {
		t.Fatal(err)
	}
	b, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "b.com"}})
	if err != nil {
		t.Fatal(err)
	}

	if err := m.Reorder([]string{a.ID}); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("too-few ids: got %v, want ErrInvalidPolicy", err)
	}
	if err := m.Reorder([]string{a.ID, b.ID, "ghost"}); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("too-many/unknown ids: got %v, want ErrInvalidPolicy", err)
	}
	if err := m.Reorder([]string{a.ID, a.ID}); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("duplicate id: got %v, want ErrInvalidPolicy", err)
	}

	// A rejected reorder must not have mutated the stored order.
	got := m.Rules()
	if got[0].ID != a.ID || got[1].ID != b.ID {
		t.Fatalf("rejected reorder must leave order untouched: %+v", got)
	}
}

func TestPolicyManagerFallbackGetSet(t *testing.T) {
	path := t.TempDir() + "/policy.json"
	m, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}
	if fb := m.GetFallback(); fb.Policy != FallbackAuto {
		t.Fatalf("default fallback: %+v", fb)
	}

	if err := m.SetFallback(Fallback{Policy: FallbackGateway}); err != nil {
		t.Fatal(err)
	}
	if fb := m.GetFallback(); fb.Policy != FallbackGateway {
		t.Fatalf("fallback not updated: %+v", fb)
	}

	// persisted round-trip
	m2, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}
	if fb := m2.GetFallback(); fb.Policy != FallbackGateway {
		t.Fatalf("fallback not persisted: %+v", fb)
	}
}

// TestPolicyManagerDefensiveCopy proves Model()/Rules() return copies: a
// caller mutating the returned PolicyModel/[]PolicyRule must never be able
// to corrupt the manager's internal state.
func TestPolicyManagerDefensiveCopy(t *testing.T) {
	path := t.TempDir() + "/policy.json"
	m, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "a.com"}}); err != nil {
		t.Fatal(err)
	}

	rules := m.Rules()
	rules[0].Intent = IntentDirect
	rules[0].Matcher.Value = "corrupted"
	if got := m.Rules(); got[0].Intent != IntentBlock || got[0].Matcher.Value != "a.com" {
		t.Fatalf("mutating the slice returned by Rules() leaked into the store: %+v", got)
	}

	model := m.Model()
	model.Rules[0].Intent = IntentProxy
	model.Fallback.Policy = FallbackDirect
	if got := m.Model(); got.Rules[0].Intent != IntentBlock || got.Fallback.Policy != FallbackAuto {
		t.Fatalf("mutating the value returned by Model() leaked into the store: %+v", got)
	}
}

// TestPolicyManagerDeleteRollsBackOnSaveFailure covers the same class of bug
// as the deleted egress model's delete-rollback tests: a save failure must
// restore the removed rule at its ORIGINAL index, not silently drop it or
// append it at the end.
func TestPolicyManagerDeleteRollsBackOnSaveFailure(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: directory write permissions are not enforced")
	}

	dir := t.TempDir()
	path := filepath.Join(dir, "policy.json")
	m, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}

	first, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "a.com"}})
	if err != nil {
		t.Fatal(err)
	}
	middle, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "b.com"}})
	if err != nil {
		t.Fatal(err)
	}
	last, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "c.com"}})
	if err != nil {
		t.Fatal(err)
	}

	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatalf("chmod dir: %v", err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })

	if err := m.DeleteRule(middle.ID); err == nil {
		t.Fatal("DeleteRule must fail when the model directory is unwritable")
	}

	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatalf("restore dir perms: %v", err)
	}

	got := m.Rules()
	if len(got) != 3 {
		t.Fatalf("want all 3 rules restored after the failed delete, got %d: %+v", len(got), got)
	}
	if got[0].ID != first.ID || got[1].ID != middle.ID || got[2].ID != last.ID {
		t.Fatalf("rollback must restore the removed entry at its ORIGINAL index: got [%s %s %s], want [%s %s %s]",
			got[0].ID, got[1].ID, got[2].ID, first.ID, middle.ID, last.ID)
	}
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

// TestPolicyValidation covers the baseline cases: rule-grammar comma (now
// allowed everywhere — binary policy compiles to DNS-only output, never a
// comma-delimited mihomo rule), subscription URL scheme, and a valid proxy
// rule passing.
func TestPolicyValidation(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}

	sub := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "ftp://x/list", Format: "plain"}}
	if _, err := m.AddRule(sub); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("non-http(s) subscription url must be rejected, got %v", err)
	}

	ok := PolicyRule{Intent: IntentProxy, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "good.example.com"}}
	if _, err := m.AddRule(ok); err != nil {
		t.Fatalf("valid proxy rule rejected: %v", err)
	}
}

// TestPolicyValidationCommaAllowedEverywhere proves the comma rule is gone
// entirely: binary policy's matcher values only ever populate a DNS
// DomainSet line, never a comma-delimited mihomo rule grammar, so a comma is
// legal for every intent (not just non-proxy, as it used to be).
func TestPolicyValidationCommaAllowedEverywhere(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}
	r := PolicyRule{Intent: IntentProxy, Enabled: true, Matcher: Matcher{Kind: KindDomainKeyword, Value: "ads,tracker"}}
	if _, err := m.AddRule(r); err != nil {
		t.Fatalf("comma in a proxy-intent keyword matcher must be allowed, got %v", err)
	}
}

// TestPolicyValidationInjectionMarkerAndNewline is the CRITICAL security
// case: a matcher value carrying an embedded newline plus a reserved marker
// sentinel (">>>5gpn:") must be rejected — an embedded newline could
// otherwise inject an extra line into the manual rule file the compiler
// writes one-value-per-line.
func TestPolicyValidationInjectionMarkerAndNewline(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}

	newlineMarker := PolicyRule{
		Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindDomainSuffix, Value: "evil.com\n>>>5gpn:forged\nDOMAIN,injected.example,REJECT"},
	}
	if _, err := m.AddRule(newlineMarker); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("embedded newline + forged marker sentinel must be ErrInvalidPolicy, got %v", err)
	}

	crOnly := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainKeyword, Value: "ads\rinjected"}}
	if _, err := m.AddRule(crOnly); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("embedded carriage return must be ErrInvalidPolicy, got %v", err)
	}

	markerOnly := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainKeyword, Value: "<<<5gpn:end"}}
	if _, err := m.AddRule(markerOnly); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("bare marker sentinel must be ErrInvalidPolicy, got %v", err)
	}

	ctrlByte := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainKeyword, Value: "ads\x00null"}}
	if _, err := m.AddRule(ctrlByte); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("embedded control byte must be ErrInvalidPolicy, got %v", err)
	}
}

// TestPolicyValidationUnknownMatcherKind covers R2: MatcherKind is closed to
// exactly the four MVP kinds (domain/domain-suffix/domain-keyword/
// subscription) — no wildcard/regex, and no typo'd/forged kind string.
func TestPolicyValidationUnknownMatcherKind(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}
	r := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: MatcherKind("domain-wildcard"), Value: "*.example.com"}}
	if _, err := m.AddRule(r); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("unknown matcher kind must be ErrInvalidPolicy, got %v", err)
	}
}

// TestPolicyValidationEmptyMatcherValue covers the empty-Value guard,
// independent of Kind.
func TestPolicyValidationEmptyMatcherValue(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}
	r := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: ""}}
	if _, err := m.AddRule(r); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("empty matcher value must be ErrInvalidPolicy, got %v", err)
	}
}

// TestPolicyValidationDomainShape covers the "domain"/"domain-suffix" FQDN
// plausibility check (isValidRuleDomain, controller.go): a value with no dot
// or embedded whitespace is rejected, while KindDomainKeyword (no FQDN shape
// requirement) accepts the same bare token.
func TestPolicyValidationDomainShape(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}
	bad := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "not a domain"}}
	if _, err := m.AddRule(bad); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("implausible domain-suffix value must be ErrInvalidPolicy, got %v", err)
	}
	noDot := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "localhost"}}
	if _, err := m.AddRule(noDot); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("dot-less domain value must be ErrInvalidPolicy, got %v", err)
	}
	kw := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainKeyword, Value: "localhost"}}
	if _, err := m.AddRule(kw); err != nil {
		t.Fatalf("dot-less value is fine for domain-keyword: %v", err)
	}
}

// TestPolicyValidationSubscriptionUnknownFormat covers the format-enum guard,
// separate from the URL-scheme guard already covered by TestPolicyValidation.
func TestPolicyValidationSubscriptionUnknownFormat(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}
	r := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "https://x/list.txt", Format: "cidr"}}
	if _, err := m.AddRule(r); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("unknown subscription format must be ErrInvalidPolicy, got %v", err)
	}
	ok := PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "https://x/list.txt", Format: "gfwlist"}}
	if _, err := m.AddRule(ok); err != nil {
		t.Fatalf("valid subscription format rejected: %v", err)
	}
}

// TestPolicyValidationUnknownIntent covers the Intent enum guard.
func TestPolicyValidationUnknownIntent(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}
	r := PolicyRule{Intent: Intent("allow"), Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "x.com"}}
	if _, err := m.AddRule(r); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("unknown intent must be ErrInvalidPolicy, got %v", err)
	}
}

// TestPolicyValidationUpdateRuleRejectsInvalid proves UpdateRule (not just
// AddRule) runs the same validation and leaves the stored rule untouched.
func TestPolicyValidationUpdateRuleRejectsInvalid(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}
	a, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "a.com"}})
	if err != nil {
		t.Fatal(err)
	}
	_, err = m.UpdateRule(a.ID, PolicyRule{Intent: Intent("bogus"), Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "b.com"}})
	if !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("UpdateRule must reject an unknown intent too, got %v", err)
	}
	if got := m.Rules(); got[0].Matcher.Value != "a.com" {
		t.Fatalf("rejected update must leave the stored rule untouched: %+v", got)
	}
}

// TestPolicyRuleManagerValidatePublic covers the public, side-effect-free
// Validate pre-check the API/bot layer will use.
func TestPolicyRuleManagerValidatePublic(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}
	bad := PolicyRule{Intent: Intent("bogus"), Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "x.com"}}
	if err := m.Validate(bad); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("Validate must reject an unknown intent, got %v", err)
	}
	if len(m.Rules()) != 0 {
		t.Fatalf("Validate must not mutate the model: %+v", m.Rules())
	}
	good := PolicyRule{Intent: IntentProxy, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "x.com"}}
	if err := m.Validate(good); err != nil {
		t.Fatalf("Validate rejected a valid rule: %v", err)
	}
	if len(m.Rules()) != 0 {
		t.Fatalf("Validate must not mutate the model even for a valid rule: %+v", m.Rules())
	}
}

// ---------------------------------------------------------------------------
// Fallback validation
// ---------------------------------------------------------------------------

func TestPolicyFallbackValidation(t *testing.T) {
	m, err := NewPolicyRuleManager(t.TempDir() + "/p.json")
	if err != nil {
		t.Fatal(err)
	}

	if err := m.SetFallback(Fallback{Policy: FallbackPolicy("allow-all")}); !errors.Is(err, ErrInvalidPolicy) {
		t.Fatalf("unknown fallback policy must be ErrInvalidPolicy, got %v", err)
	}
	if err := m.SetFallback(Fallback{Policy: FallbackDirect}); err != nil {
		t.Fatalf("valid direct fallback rejected: %v", err)
	}
	if err := m.SetFallback(Fallback{Policy: FallbackGateway}); err != nil {
		t.Fatalf("valid gateway fallback rejected: %v", err)
	}
}

func TestPolicyManagerAtomicWriteRoundTrip(t *testing.T) {
	path := t.TempDir() + "/policy.json"
	m, err := NewPolicyRuleManager(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "a.com"}}); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("policy.json must exist after AddRule: %v", err)
	}
	var onDisk PolicyModel
	if err := json.Unmarshal(data, &onDisk); err != nil {
		t.Fatalf("policy.json must be valid JSON: %v", err)
	}
	if len(onDisk.Rules) != 1 || onDisk.Rules[0].Matcher.Value != "a.com" {
		t.Fatalf("on-disk model: %+v", onDisk)
	}

	// No stray temp files should survive a successful save.
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.Name() != filepath.Base(path) {
			t.Fatalf("stray file left behind after save: %s", e.Name())
		}
	}
}
