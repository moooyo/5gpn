package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// AddRule
// ---------------------------------------------------------------------------

func TestControllerAddRuleAppendsAndReloads(t *testing.T) {
	rulesDir := t.TempDir()
	reload, count := countingReload()
	stats, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	c := NewController(stats, reload, rulesDir, nil, nil, nil)

	if err := c.AddRule("blacklist", "x.com"); err != nil {
		t.Fatalf("AddRule: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(rulesDir, "blacklist.txt"))
	if err != nil {
		t.Fatalf("manual rule file not written: %v", err)
	}
	if !strings.Contains(string(data), "x.com") {
		t.Errorf("expected file to contain x.com, got %q", string(data))
	}
	if count() != 1 {
		t.Errorf("want reload called once, got %d", count())
	}
}

func TestControllerAddRuleInvalidDomainErrorsAndFileUnchanged(t *testing.T) {
	rulesDir := t.TempDir()
	reload, count := countingReload()
	stats, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	c := NewController(stats, reload, rulesDir, nil, nil, nil)

	if err := c.AddRule("blacklist", "not a domain"); err == nil {
		t.Fatal("expected error for invalid domain, got nil")
	}

	path := filepath.Join(rulesDir, "blacklist.txt")
	if _, err := os.Stat(path); err == nil {
		data, _ := os.ReadFile(path)
		if len(strings.TrimSpace(string(data))) != 0 {
			t.Errorf("expected file to remain empty/unwritten, got %q", string(data))
		}
	}
	if count() != 0 {
		t.Errorf("want reload NOT called on invalid entry, got %d", count())
	}
}

func TestControllerAddRuleInvalidCIDRErrors(t *testing.T) {
	rulesDir := t.TempDir()
	reload, count := countingReload()
	stats, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	c := NewController(stats, reload, rulesDir, nil, nil, nil)

	if err := c.AddRule("chnroute", "not-a-cidr"); err == nil {
		t.Fatal("expected error for invalid CIDR, got nil")
	}
	if count() != 0 {
		t.Errorf("want reload NOT called on invalid entry, got %d", count())
	}

	if err := c.AddRule("chnroute", "1.2.3.0/24"); err != nil {
		t.Fatalf("AddRule with valid CIDR: %v", err)
	}
	if count() != 1 {
		t.Errorf("want reload called once for valid CIDR, got %d", count())
	}
}

func TestControllerAddRuleInvalidCategoryErrors(t *testing.T) {
	rulesDir := t.TempDir()
	reload, _ := countingReload()
	stats, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	c := NewController(stats, reload, rulesDir, nil, nil, nil)

	if err := c.AddRule("bogus", "x.com"); err == nil {
		t.Fatal("expected error for invalid category, got nil")
	}
}

// ---------------------------------------------------------------------------
// RemoveRule
// ---------------------------------------------------------------------------

func TestControllerRemoveRuleRemovesLine(t *testing.T) {
	rulesDir := t.TempDir()
	reload, count := countingReload()
	stats, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	c := NewController(stats, reload, rulesDir, nil, nil, nil)

	if err := c.AddRule("adblock", "a.com"); err != nil {
		t.Fatalf("AddRule a.com: %v", err)
	}
	if err := c.AddRule("adblock", "b.com"); err != nil {
		t.Fatalf("AddRule b.com: %v", err)
	}

	if err := c.RemoveRule("adblock", "a.com"); err != nil {
		t.Fatalf("RemoveRule: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(rulesDir, "adblock.txt"))
	if err != nil {
		t.Fatalf("read after remove: %v", err)
	}
	content := string(data)
	if strings.Contains(content, "a.com") {
		t.Errorf("expected a.com removed, got %q", content)
	}
	if !strings.Contains(content, "b.com") {
		t.Errorf("expected b.com retained, got %q", content)
	}
	if count() != 3 { // 2 adds + 1 remove
		t.Errorf("want reload called 3 times total, got %d", count())
	}
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

func TestControllerUpdateEmptyIDDelegatesToUpdateAll(t *testing.T) {
	rulesDir := t.TempDir()
	reload, _ := countingReload()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	stats, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	c := NewController(stats, reload, rulesDir, nil, nil, nil)

	results := c.Update(context.Background(), "")
	if results == nil {
		t.Fatal("expected non-nil (possibly empty) results slice from UpdateAll delegation")
	}
	if len(results) != 0 {
		t.Errorf("expected 0 results (no subscriptions configured), got %d", len(results))
	}
}

// ---------------------------------------------------------------------------
// Subscriptions / AddSubscription / RemoveSubscription passthrough
// ---------------------------------------------------------------------------

func TestControllerSubscriptionsPassthrough(t *testing.T) {
	rulesDir := t.TempDir()
	reload, _ := countingReload()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	subs, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	c := NewController(subs, reload, rulesDir, nil, nil, nil)

	if got := c.Subscriptions(); len(got) != 0 {
		t.Fatalf("expected 0 subscriptions initially, got %d", len(got))
	}
}

func TestControllerReload(t *testing.T) {
	reload, count := countingReload()
	c := NewController(nil, reload, t.TempDir(), nil, nil, nil)
	if err := c.Reload(); err != nil {
		t.Fatalf("Reload: %v", err)
	}
	if count() != 1 {
		t.Errorf("want reload called once, got %d", count())
	}
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

func TestControllerStatsSnapshot(t *testing.T) {
	stats := &statsCounters{}
	stats.total.Store(10)
	stats.direct.Store(4)
	stats.proxy.Store(3)
	stats.block.Store(2)
	stats.chinaOK.Store(1)
	stats.chinaErr.Store(1)
	stats.trustOK.Store(1)
	stats.trustErr.Store(1)

	cacheLen := func() int { return 42 }

	c := NewController(nil, func() error { return nil }, t.TempDir(), stats, cacheLen, nil)
	got := c.Stats()

	want := Stats{
		Total: 10, Direct: 4, Proxy: 3, Block: 2,
		CacheEntries: 42,
		ChinaOK:      1, ChinaErr: 1, TrustOK: 1, TrustErr: 1,
	}
	if got != want {
		t.Errorf("Stats() = %+v, want %+v", got, want)
	}
}

func TestControllerStatsNilSafe(t *testing.T) {
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, nil)
	got := c.Stats()
	want := Stats{}
	if got != want {
		t.Errorf("Stats() with nil stats/cacheLen = %+v, want zero value %+v", got, want)
	}
}

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

func TestControllerLookupBlacklistNoUpstream(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, h)

	got := c.Lookup(context.Background(), "blacklist.test")
	if got.Name != "blacklist.test" || got.Verdict != "proxy" || got.Reason != "blacklist" {
		t.Errorf("Lookup(blacklist.test) = %+v, want Name=blacklist.test Verdict=proxy Reason=blacklist", got)
	}
	if len(got.IPs) != 0 {
		t.Errorf("Lookup(blacklist.test).IPs = %v, want empty (no upstream call)", got.IPs)
	}
}

func TestControllerLookupDefaultCNIP(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("example.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, h)

	got := c.Lookup(context.Background(), "example.test")
	if got.Verdict != "direct" || got.Reason != "chnroute-cn" {
		t.Errorf("Lookup(example.test) verdict/reason = %s/%s, want direct/chnroute-cn", got.Verdict, got.Reason)
	}
	if len(got.IPs) != 1 || got.IPs[0] != "1.2.3.4" {
		t.Errorf("Lookup(example.test).IPs = %v, want [1.2.3.4]", got.IPs)
	}
}

func TestControllerLookupDefaultForeignIP(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("foreign.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("foreign.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, h)

	got := c.Lookup(context.Background(), "foreign.test")
	if got.Verdict != "proxy" || got.Reason != "chnroute-foreign" {
		t.Errorf("Lookup(foreign.test) verdict/reason = %s/%s, want proxy/chnroute-foreign", got.Verdict, got.Reason)
	}
	if len(got.IPs) != 1 || got.IPs[0] != "9.9.9.9" {
		t.Errorf("Lookup(foreign.test).IPs = %v, want [9.9.9.9]", got.IPs)
	}
}

func TestControllerLookupAdblockNoUpstream(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, h)

	got := c.Lookup(context.Background(), "adblock.test")
	if got.Name != "adblock.test" || got.Verdict != "block" || got.Reason != "adblock" {
		t.Errorf("Lookup(adblock.test) = %+v, want Name=adblock.test Verdict=block Reason=adblock", got)
	}
	if len(got.IPs) != 0 {
		t.Errorf("Lookup(adblock.test).IPs = %v, want empty (no upstream call)", got.IPs)
	}
}

func TestControllerLookupForceDirect(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("direct.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("direct.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, h)

	got := c.Lookup(context.Background(), "direct.test")
	if got.Verdict != "direct" || got.Reason != "force-direct" {
		t.Errorf("Lookup(direct.test) verdict/reason = %s/%s, want direct/force-direct", got.Verdict, got.Reason)
	}
}

// ---------------------------------------------------------------------------
// ListRules
// ---------------------------------------------------------------------------

func TestControllerListRules_AddListRemoveRoundtrip(t *testing.T) {
	rulesDir := t.TempDir()
	reload, _ := countingReload()
	stats, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	c := NewController(stats, reload, rulesDir, nil, nil, nil)

	if err := c.AddRule("blacklist", "x.test"); err != nil {
		t.Fatalf("AddRule: %v", err)
	}

	got, err := c.ListRules("blacklist")
	if err != nil {
		t.Fatalf("ListRules: %v", err)
	}
	found := false
	for _, e := range got {
		if e == "x.test" {
			found = true
		}
	}
	if !found {
		t.Fatalf("ListRules(blacklist) = %v, want to contain x.test", got)
	}

	if err := c.RemoveRule("blacklist", "x.test"); err != nil {
		t.Fatalf("RemoveRule: %v", err)
	}

	got, err = c.ListRules("blacklist")
	if err != nil {
		t.Fatalf("ListRules after remove: %v", err)
	}
	for _, e := range got {
		if e == "x.test" {
			t.Fatalf("ListRules(blacklist) after remove = %v, still contains x.test", got)
		}
	}
}

func TestControllerListRules_InvalidCategoryErrors(t *testing.T) {
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, nil)

	if _, err := c.ListRules("bogus"); err == nil {
		t.Fatal("expected error for invalid category, got nil")
	}
}

func TestControllerListRules_AbsentFileReturnsEmptyNotError(t *testing.T) {
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, nil)

	got, err := c.ListRules("adblock")
	if err != nil {
		t.Fatalf("ListRules on absent file: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("ListRules on absent file = %v, want empty", got)
	}
	if got == nil {
		t.Errorf("ListRules on absent file returned nil, want non-nil empty slice")
	}
}
