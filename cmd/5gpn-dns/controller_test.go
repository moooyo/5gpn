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
	c := NewController(stats, reload, rulesDir, nil, nil)

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
	c := NewController(stats, reload, rulesDir, nil, nil)

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
	c := NewController(stats, reload, rulesDir, nil, nil)

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
	c := NewController(stats, reload, rulesDir, nil, nil)

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
	c := NewController(stats, reload, rulesDir, nil, nil)

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
	c := NewController(stats, reload, rulesDir, nil, nil)

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
	c := NewController(subs, reload, rulesDir, nil, nil)

	if got := c.Subscriptions(); len(got) != 0 {
		t.Fatalf("expected 0 subscriptions initially, got %d", len(got))
	}
}

func TestControllerReload(t *testing.T) {
	reload, count := countingReload()
	c := NewController(nil, reload, t.TempDir(), nil, nil)
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

	c := NewController(nil, func() error { return nil }, t.TempDir(), stats, cacheLen)
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
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil)
	got := c.Stats()
	want := Stats{}
	if got != want {
		t.Errorf("Stats() with nil stats/cacheLen = %+v, want zero value %+v", got, want)
	}
}
