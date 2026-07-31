package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeSeed(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestBuildDefaultPolicyModel(t *testing.T) {
	dir := t.TempDir()
	keyword := writeSeed(t, dir, "kw.txt", "httpdns\nhttpsdns\n")
	proxy := writeSeed(t, dir, "proxy.txt", "# empty by default\n") // no entries

	in := seedInputs{
		KeywordPath: keyword, ProxyPath: proxy,
		BypassURL:    "https://x/bypass.txt",
		ChinaListURL: "https://x/china.yaml", GFWURL: "https://x/gfw.txt",
	}
	m, err := buildDefaultPolicyModel(in)
	if err != nil {
		t.Fatal(err)
	}

	// counts: 1 bypass subscription + 2 keyword blocks + 0 proxy + 2 subscriptions
	if len(m.Rules) != 5 {
		t.Fatalf("want 5 rules, got %d: %+v", len(m.Rules), m.Rules)
	}
	// fallback
	if m.Fallback.Policy != FallbackAuto {
		t.Fatalf("fallback: %+v", m.Fallback)
	}
	// every rule: non-empty unique ID, sequential Order
	seen := map[string]bool{}
	for i, r := range m.Rules {
		if r.ID == "" || r.Order != i || seen[r.ID] {
			t.Fatalf("rule %d malformed: %+v", i, r)
		}
		seen[r.ID] = true
	}
	// The bypass set must sort ahead of the china-direct list: a name in both
	// has to block rather than resolve direct once the operator enables it.
	if m.Rules[0].Matcher.Kind != KindSubscription || m.Rules[0].Intent != IntentBlock ||
		m.Rules[0].Matcher.Format != "plain" || m.Rules[0].Matcher.Value != "https://x/bypass.txt" {
		t.Fatalf("bypass sub: %+v", m.Rules[0])
	}
	// keyword blocks
	if m.Rules[1].Matcher.Kind != KindDomainKeyword || m.Rules[1].Matcher.Value != "httpdns" {
		t.Fatalf("keyword rule: %+v", m.Rules[1])
	}
	// The whole encrypted-DNS bypass set ships disabled; everything else is on.
	for i, r := range m.Rules[:3] {
		if r.Enabled {
			t.Fatalf("bypass rule %d must ship disabled: %+v", i, r)
		}
	}
	for i, r := range m.Rules[3:] {
		if !r.Enabled {
			t.Fatalf("subscription rule %d must ship enabled: %+v", i, r)
		}
	}
	// the two list subscriptions (last two), in direct/proxy order
	subs := m.Rules[len(m.Rules)-2:]
	if subs[0].Matcher.Kind != KindSubscription || subs[0].Intent != IntentDirect || subs[0].Matcher.Format != "clash" || subs[0].Matcher.Value != "https://x/china.yaml" {
		t.Fatalf("china-list sub: %+v", subs[0])
	}
	if subs[1].Intent != IntentProxy || subs[1].Matcher.Format != "plain" || subs[1].Matcher.Value != "https://x/gfw.txt" {
		t.Fatalf("gfw sub: %+v", subs[1])
	}
	if subs[0].Matcher.Interval != 24*time.Hour {
		t.Fatalf("sub interval: %v", subs[0].Matcher.Interval)
	}

	// interval serializes as a Go duration string, not nanoseconds
	data, _ := json.Marshal(m)
	if !containsSub(string(data), `"interval":"24h0m0s"`) {
		t.Fatalf("interval not a duration string: %s", data)
	}
}

func TestBuildDefaultPolicyModelMissingProxyFileNoError(t *testing.T) {
	dir := t.TempDir()
	in := seedInputs{
		KeywordPath:  writeSeed(t, dir, "k.txt", "httpdns\n"),
		ProxyPath:    filepath.Join(dir, "does-not-exist.txt"),
		BypassURL:    "https://x/b",
		ChinaListURL: "https://x/c", GFWURL: "https://x/g",
	}
	m, err := buildDefaultPolicyModel(in)
	if err != nil {
		t.Fatalf("missing proxy file must not error: %v", err)
	}
	if len(m.Rules) != 1+1+2 { // 1 bypass sub + 1 keyword + 2 subs
		t.Fatalf("want 4 rules, got %d", len(m.Rules))
	}
}

func TestDefaultModelRulesValidate(t *testing.T) {
	// The shipped model must pass the same complete validation used when
	// policy.json is loaded.
	dir := t.TempDir()
	in := seedInputs{
		KeywordPath:  writeSeed(t, dir, "k.txt", "httpdns\nhttpsdns\n"),
		ProxyPath:    writeSeed(t, dir, "p.txt", ""),
		BypassURL:    defaultBypassURL,
		ChinaListURL: defaultChinaListURL, GFWURL: defaultGFWURL,
	}
	m, err := buildDefaultPolicyModel(in)
	if err != nil {
		t.Fatal(err)
	}
	if err := validatePolicyModel(m); err != nil {
		t.Fatalf("shipped model fails validation: %v", err)
	}
}

func TestSeedDefaultsIdempotent(t *testing.T) {
	dir := t.TempDir()
	policy := filepath.Join(dir, "policy.json")
	in := seedInputs{
		KeywordPath:  writeSeed(t, dir, "k.txt", "httpdns\n"),
		ProxyPath:    filepath.Join(dir, "none.txt"),
		BypassURL:    defaultBypassURL,
		ChinaListURL: defaultChinaListURL, GFWURL: defaultGFWURL,
	}
	if err := seedDefaults(policy, in); err != nil {
		t.Fatal(err)
	}
	// policy.json parses to the model: 1 bypass sub + 1 keyword + 2 subs = 4 rules
	pm, err := LoadPolicyModel(policy)
	if err != nil || len(pm.Rules) != 4 {
		t.Fatalf("policy load: %v rules=%d", err, len(pm.Rules))
	}

	// second run: policy.json byte-identical (IDs preserved)
	p1, _ := os.ReadFile(policy)
	if err := seedDefaults(policy, in); err != nil {
		t.Fatal(err)
	}
	p2, _ := os.ReadFile(policy)
	if string(p1) != string(p2) {
		t.Fatalf("policy.json not idempotent")
	}
}

func TestSeedPreservesOperatorPolicy(t *testing.T) {
	dir := t.TempDir()
	policy := filepath.Join(dir, "policy.json")
	custom := `{"version":1,"rules":[],"fallback":{"policy":"direct"}}` + "\n"
	if err := os.WriteFile(policy, []byte(custom), 0o644); err != nil {
		t.Fatal(err)
	}
	in := seedInputs{BypassURL: defaultBypassURL, ChinaListURL: defaultChinaListURL, GFWURL: defaultGFWURL}
	if err := seedDefaults(policy, in); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(policy)
	if string(got) != custom {
		t.Fatalf("operator policy.json was clobbered:\n%s", got)
	}
}

func containsSub(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
