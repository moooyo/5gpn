package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCompilePolicySubscriptionProjection(t *testing.T) {
	model := PolicyModel{
		Version: policySchemaVersion,
		Rules: []PolicyRule{
			{ID: "r1", Order: 0, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "ads.example.com"}},
			{ID: "r2", Order: 1, Intent: IntentProxy, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "https://x/list.txt", Format: "plain", Interval: time.Hour}},
			{ID: "r3", Order: 2, Intent: IntentDirect, Enabled: false, Matcher: Matcher{Kind: KindSubscription, Value: "https://x/off.txt", Format: "plain", Interval: time.Hour}},
		},
		Fallback: Fallback{Policy: FallbackAuto},
	}
	got, err := CompilePolicy(model)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Subs) != 1 || got.Subs[0].Category != "proxy" || got.Subs[0].Name != "pol_r2" {
		t.Fatalf("compiled subscriptions = %+v", got.Subs)
	}
}

func TestRuntimePolicyGlobalOrderAcrossIntents(t *testing.T) {
	h := &Handler{Cache: NewCache(8)}
	model := PolicyModel{
		Version: policySchemaVersion,
		Rules: []PolicyRule{
			{ID: "direct-first", Order: 0, Intent: IntentDirect, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "example.com"}},
			{ID: "block-second", Order: 1, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "www.example.com"}},
		},
		Fallback: Fallback{Policy: FallbackAuto},
	}
	if err := h.publishPolicyModel(model, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if got := h.decideName("www.example.com.").Verdict; got.Reason != "force-direct" {
		t.Fatalf("first-match verdict = %+v", got)
	}
	model.Rules[0].Order, model.Rules[1].Order = 1, 0
	if err := h.publishPolicyModel(model, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if got := h.decideName("www.example.com.").Verdict; got.Reason != "block" {
		t.Fatalf("reordered verdict = %+v", got)
	}
}

func TestRuntimePolicySubscriptionKeepsOrder(t *testing.T) {
	dir := t.TempDir()
	cache := filepath.Join(dir, "direct", providerName("sub-direct")+".txt")
	if err := os.MkdirAll(filepath.Dir(cache), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cache, []byte("example.com\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	model := PolicyModel{Version: policySchemaVersion, Rules: []PolicyRule{
		{ID: "sub-direct", Order: 0, Intent: IntentDirect, Enabled: true, Matcher: Matcher{Kind: KindSubscription, Value: "https://lists.example/direct", Format: "plain", Interval: time.Hour}},
		{ID: "literal-block", Order: 1, Intent: IntentBlock, Enabled: true, Matcher: Matcher{Kind: KindDomainSuffix, Value: "example.com"}},
	}, Fallback: Fallback{Policy: FallbackAuto}}

	h := &Handler{Cache: NewCache(8)}
	if err := h.publishPolicyModel(model, dir); err != nil {
		t.Fatal(err)
	}
	if got := h.decideName("www.example.com").Verdict; got.Reason != "force-direct" {
		t.Fatalf("subscription first-match = %+v", got)
	}
}

func TestIntentCategory(t *testing.T) {
	cases := []struct {
		in      Intent
		wantCat string
		wantOK  bool
	}{
		{IntentBlock, "block", true},
		{IntentDirect, "direct", true},
		{IntentProxy, "proxy", true},
		{Intent("bogus"), "", false},
	}
	for _, tc := range cases {
		cat, ok := intentCategory(tc.in)
		if cat != tc.wantCat || ok != tc.wantOK {
			t.Errorf("intentCategory(%q) = (%q,%v)", tc.in, cat, ok)
		}
	}
}

func TestCompilePolicyRejectsInvalidModel(t *testing.T) {
	model := PolicyModel{Version: policySchemaVersion, Rules: []PolicyRule{
		{ID: "bad", Order: 0, Intent: Intent("bogus"), Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "example.com"}},
	}, Fallback: Fallback{Policy: FallbackAuto}}
	if _, err := CompilePolicy(model); err == nil {
		t.Fatal("invalid intent accepted")
	}
	model = PolicyModel{Version: policySchemaVersion}
	if _, err := CompilePolicy(model); err == nil {
		t.Fatal("missing fallback accepted")
	}
}
