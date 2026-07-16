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
	bypass := writeSeed(t, dir, "bypass.txt", "# comment\ncloudflare-dns.com\ndns.google\n\ndoh.pub\n")
	keyword := writeSeed(t, dir, "kw.txt", "httpdns\nhttpsdns\n")
	proxy := writeSeed(t, dir, "proxy.txt", "# empty by default\n") // no entries

	in := seedInputs{
		BypassPath: bypass, KeywordPath: keyword, ProxyPath: proxy,
		ChinaListURL: "https://x/china.conf", GFWURL: "https://x/gfw.txt",
	}
	m, err := buildDefaultPolicyModel(in)
	if err != nil {
		t.Fatal(err)
	}

	// counts: 3 suffix blocks + 2 keyword blocks + 0 proxy + 2 subscription rules
	if len(m.Rules) != 7 {
		t.Fatalf("want 7 rules, got %d: %+v", len(m.Rules), m.Rules)
	}
	// fallback
	if m.Fallback.Policy != FallbackAuto {
		t.Fatalf("fallback: %+v", m.Fallback)
	}
	// every rule: enabled, non-empty unique ID, sequential Order
	seen := map[string]bool{}
	for i, r := range m.Rules {
		if !r.Enabled || r.ID == "" || r.Order != i || seen[r.ID] {
			t.Fatalf("rule %d malformed: %+v", i, r)
		}
		seen[r.ID] = true
	}
	// suffix blocks are lowercased FQDNs, comment/blank stripped
	if m.Rules[0].Matcher.Kind != KindDomainSuffix || m.Rules[0].Intent != IntentBlock || m.Rules[0].Matcher.Value != "cloudflare-dns.com" {
		t.Fatalf("first bypass rule: %+v", m.Rules[0])
	}
	// keyword blocks
	if m.Rules[3].Matcher.Kind != KindDomainKeyword || m.Rules[3].Matcher.Value != "httpdns" {
		t.Fatalf("keyword rule: %+v", m.Rules[3])
	}
	// the two subscription rules (last two), in direct/proxy order
	subs := m.Rules[len(m.Rules)-2:]
	if subs[0].Matcher.Kind != KindSubscription || subs[0].Intent != IntentDirect || subs[0].Matcher.Format != "dnsmasq" || subs[0].Matcher.Value != "https://x/china.conf" {
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
		BypassPath: writeSeed(t, dir, "b.txt", "a.com\n"), KeywordPath: writeSeed(t, dir, "k.txt", "httpdns\n"),
		ProxyPath:    filepath.Join(dir, "does-not-exist.txt"),
		ChinaListURL: "https://x/c", GFWURL: "https://x/g",
	}
	m, err := buildDefaultPolicyModel(in)
	if err != nil {
		t.Fatalf("missing proxy file must not error: %v", err)
	}
	if len(m.Rules) != 1+1+2 { // 1 suffix + 1 keyword + 2 subs
		t.Fatalf("want 4 rules, got %d", len(m.Rules))
	}
}

func TestDefaultModelRulesValidate(t *testing.T) {
	// The shipped model must pass the same complete validation used when
	// policy.json is loaded.
	dir := t.TempDir()
	in := seedInputs{
		BypassPath:   writeSeed(t, dir, "b.txt", "cloudflare-dns.com\nuse-application-dns.net\n"),
		KeywordPath:  writeSeed(t, dir, "k.txt", "httpdns\nhttpsdns\n"),
		ProxyPath:    writeSeed(t, dir, "p.txt", ""),
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
		BypassPath:   writeSeed(t, dir, "b.txt", "cloudflare-dns.com\n"),
		KeywordPath:  writeSeed(t, dir, "k.txt", "httpdns\n"),
		ProxyPath:    filepath.Join(dir, "none.txt"),
		ChinaListURL: defaultChinaListURL, GFWURL: defaultGFWURL,
	}
	if err := seedDefaults(policy, in); err != nil {
		t.Fatal(err)
	}
	// policy.json parses to the model: 1 suffix + 1 keyword + 2 subs = 4 rules
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
	in := seedInputs{ChinaListURL: defaultChinaListURL, GFWURL: defaultGFWURL}
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
