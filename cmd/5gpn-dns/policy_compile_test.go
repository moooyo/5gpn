package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestCompilePolicy_DNSProjection is the compiler's golden test: it asserts
// the intent→category DNS assignment and the inline-vs-subscription split
// (block→block, direct→direct, proxy→blacklist; only enabled rules
// compile, in Order).
func TestCompilePolicy_DNSProjection(t *testing.T) {
	model := PolicyModel{
		Version: 1,
		Rules: []PolicyRule{
			{ID: "r1", Order: 0, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "Ads.Example.com"}},
			{ID: "r2", Order: 1, Intent: IntentDirect, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "cn.example.com"}},
			{ID: "r3", Order: 2, Intent: IntentProxy, Enabled: true, Matcher: Matcher{Kind: KindDomainKeyword, Value: "google"}},
			{ID: "r4", Order: 3, Intent: IntentProxy, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "https://x/gfw.txt", Format: "plain", Interval: 24 * time.Hour}},
			{ID: "r5", Order: 4, Intent: IntentDirect, Enabled: false, Matcher: Matcher{Kind: KindDomain, Value: "disabled.example.com"}}, // disabled ⇒ skipped
		},
		Fallback: Fallback{Policy: FallbackAuto},
	}
	cdns, err := CompilePolicy(model, "/etc/5gpn/rules")
	if err != nil {
		t.Fatal(err)
	}

	if got := cdns.Manual["block"][MatchSuffix]; len(got) != 1 || got[0] != "ads.example.com" {
		t.Fatalf("block→block suffix (normalized) wrong: %v", got)
	}
	if got := cdns.Manual["direct"][MatchExact]; len(got) != 1 || got[0] != "cn.example.com" {
		t.Fatalf("direct→direct exact wrong: %v", got)
	}
	if got := cdns.Manual["blacklist"][MatchKeyword]; len(got) != 1 || got[0] != "google" {
		t.Fatalf("proxy keyword→blacklist keyword wrong: %v", got)
	}
	if len(cdns.Subs) != 1 || cdns.Subs[0].Category != "blacklist" || cdns.Subs[0].Format != "plain" {
		t.Fatalf("subscription→blacklist cache spec wrong: %+v", cdns.Subs)
	}
	for _, v := range cdns.Manual["direct"][MatchExact] {
		if v == "disabled.example.com" {
			t.Fatalf("disabled rule leaked into projection")
		}
	}
}

func TestRuntimePolicyGlobalOrderAcrossIntents(t *testing.T) {
	h := &Handler{Cache: NewCache(8)}
	model := PolicyModel{
		Rules: []PolicyRule{
			{ID: "direct-first", Order: 0, Intent: IntentDirect, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "example.com"}},
			{ID: "block-second", Order: 1, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "www.example.com"}},
		},
		Fallback: Fallback{Policy: FallbackAuto},
	}
	if err := h.publishPolicyModel(model, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if got := h.classifyName("www.example.com."); got.Reason != "force-direct" {
		t.Fatalf("first-match verdict = %+v, want direct rule at order 0", got)
	}

	model.Rules[0].Order, model.Rules[1].Order = 1, 0
	if err := h.publishPolicyModel(model, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if got := h.classifyName("www.example.com."); got.Reason != "block" {
		t.Fatalf("reordered first-match verdict = %+v, want block", got)
	}
}

func TestRuntimePolicySubscriptionKeepsRuleIdentityAndOrder(t *testing.T) {
	dir := t.TempDir()
	cache := filepath.Join(dir, "direct", providerName("sub-direct")+".txt")
	if err := os.MkdirAll(filepath.Dir(cache), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cache, []byte("example.com\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	model := PolicyModel{Rules: []PolicyRule{
		{ID: "sub-direct", Order: 0, Intent: IntentDirect, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "https://lists.example/direct", Format: "plain"}},
		{ID: "literal-block", Order: 1, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "example.com"}},
	}, Fallback: Fallback{Policy: FallbackAuto}}

	h := &Handler{Cache: NewCache(8)}
	if err := h.publishPolicyModel(model, dir); err != nil {
		t.Fatal(err)
	}
	if got := h.classifyName("www.example.com"); got.Reason != "force-direct" {
		t.Fatalf("subscription first-match = %+v, want direct", got)
	}
}

// TestIntentCategory covers intentCategory's exhaustive mapping plus the
// unknown-intent ok=false case (the compiler surfaces this as an error).
func TestIntentCategory(t *testing.T) {
	cases := []struct {
		in      Intent
		wantCat string
		wantOK  bool
	}{
		{IntentBlock, "block", true},
		{IntentDirect, "direct", true},
		{IntentProxy, "blacklist", true},
		{Intent("bogus"), "", false},
	}
	for _, c := range cases {
		cat, ok := intentCategory(c.in)
		if cat != c.wantCat || ok != c.wantOK {
			t.Errorf("intentCategory(%q) = (%q, %v), want (%q, %v)", c.in, cat, ok, c.wantCat, c.wantOK)
		}
	}
}

// TestKindMatchType covers the matcher-kind→DNS-MatchType mapping table.
func TestKindMatchType(t *testing.T) {
	cases := []struct {
		in   MatcherKind
		want MatchType
	}{
		{KindDomain, MatchExact},
		{KindDomainSuffix, MatchSuffix},
		{KindDomainKeyword, MatchKeyword},
	}
	for _, c := range cases {
		if got := kindMatchType(c.in); got != c.want {
			t.Errorf("kindMatchType(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

// TestCompilePolicy_UnknownIntentErrors ensures a rule with an intent outside
// the validated enum (which should never happen post-validation, but the
// compiler must not silently mis-project it) surfaces as an error rather than
// being dropped or miscategorized.
func TestCompilePolicy_UnknownIntentErrors(t *testing.T) {
	model := PolicyModel{
		Version: 1,
		Rules: []PolicyRule{
			{ID: "bad", Order: 0, Intent: Intent("bogus"), Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "example.com"}},
		},
	}
	if _, err := CompilePolicy(model, ""); err == nil {
		t.Fatal("expected an error for an unknown intent, got nil")
	}
}

// TestCompilePolicy_DedupesManualEntries ensures two enabled rules that
// normalize to the same (category, matchtype, value) collapse to one entry —
// the manual file must not carry visible duplicate lines.
func TestCompilePolicy_DedupesManualEntries(t *testing.T) {
	model := PolicyModel{
		Version: 1,
		Rules: []PolicyRule{
			{ID: "a", Order: 0, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "ads.example.com"}},
			{ID: "b", Order: 1, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "Ads.Example.com."}},
		},
	}
	cdns, err := CompilePolicy(model, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := cdns.Manual["block"][MatchSuffix]; len(got) != 1 {
		t.Fatalf("expected exactly 1 deduped entry, got %v", got)
	}
}

// TestCompilePolicy_EmptyModelDNSSideEmpty covers the empty-model edge case:
// a model with zero rules must compile to an empty CompiledDNS.Manual and no
// Subs, not a nil-vs-empty-map footgun for a later writer that ranges over
// it.
func TestCompilePolicy_EmptyModelDNSSideEmpty(t *testing.T) {
	model := PolicyModel{Version: 1, Fallback: Fallback{Policy: FallbackAuto}}
	cdns, err := CompilePolicy(model, "/etc/5gpn/rules")
	if err != nil {
		t.Fatal(err)
	}
	if len(cdns.Manual) != 0 {
		t.Fatalf("empty model should produce no DNS Manual categories, got %+v", cdns.Manual)
	}
	if len(cdns.Subs) != 0 {
		t.Fatalf("empty model should produce no Subs descriptors, got %+v", cdns.Subs)
	}
}

// TestCompilePolicy_BlockDirectOnlyModel covers a model with ONLY
// block/direct rules (no proxy rule at all): the DNS side is still fully
// populated for both categories (there is no mihomo side to check anymore —
// binary policy compiles to DNS categories only).
func TestCompilePolicy_BlockDirectOnlyModel(t *testing.T) {
	model := PolicyModel{
		Version: 1,
		Rules: []PolicyRule{
			{ID: "b1", Order: 0, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "ads.example.com"}},
			{ID: "d1", Order: 1, Intent: IntentDirect, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "cn.example.com"}},
			{ID: "d2", Order: 2, Intent: IntentDirect, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "https://x/direct.txt", Format: "plain"}},
		},
		Fallback: Fallback{Policy: FallbackAuto},
	}
	cdns, err := CompilePolicy(model, "/etc/5gpn/rules")
	if err != nil {
		t.Fatal(err)
	}
	if got := cdns.Manual["block"][MatchSuffix]; len(got) != 1 || got[0] != "ads.example.com" {
		t.Fatalf("block rule should still populate DNS block suffix: %v", got)
	}
	if got := cdns.Manual["direct"][MatchExact]; len(got) != 1 || got[0] != "cn.example.com" {
		t.Fatalf("direct rule should still populate DNS direct exact: %v", got)
	}
	if len(cdns.Subs) != 1 || cdns.Subs[0].ID != "d2" || cdns.Subs[0].Category != "direct" {
		t.Fatalf("direct subscription should still produce a Subs descriptor: %+v", cdns.Subs)
	}
}

// TestCompilePolicy_ProxySubscriptionCategory proves a proxy-intent
// subscription rule contributes a Subs descriptor in the "blacklist"
// category (steer to the gateway) — the same category an inline proxy rule
// uses — with no other side effect (binary policy: proxy means only "reach
// the gateway", nothing about which mihomo egress it eventually takes).
func TestCompilePolicy_ProxySubscriptionCategory(t *testing.T) {
	model := PolicyModel{
		Version: 1,
		Rules: []PolicyRule{
			{ID: "bbbb2222", Order: 0, Intent: IntentProxy, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "https://x/gfw.txt", Format: "plain", Interval: time.Hour}},
		},
	}
	cdns, err := CompilePolicy(model, "/etc/5gpn/rules")
	if err != nil {
		t.Fatal(err)
	}
	if len(cdns.Subs) != 1 || cdns.Subs[0].Category != "blacklist" || cdns.Subs[0].Name != "pol_bbbb2222" {
		t.Fatalf("proxy subscription descriptor wrong: %+v", cdns.Subs)
	}
}
