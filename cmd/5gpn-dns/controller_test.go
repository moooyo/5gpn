package main

import "testing"

func TestControllerReload(t *testing.T) {
	reload, count := countingReload()
	c := NewController(reload, nil, nil, nil)
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
	stats.block.Store(5)
	stats.forceDirect.Store(4)
	stats.forceProxy.Store(3)
	stats.chnrouteCN.Store(2)
	stats.chnrouteForeign.Store(1)
	stats.chinaOK.Store(1)
	stats.chinaErr.Store(1)
	stats.trustOK.Store(1)
	stats.trustErr.Store(1)

	cacheLen := func() int { return 42 }

	c := NewController(func() error { return nil }, stats, cacheLen, nil)
	got := c.Stats()

	want := Stats{
		Total: 10, Block: 5, ForceDirect: 4, ForceProxy: 3, ChnrouteCN: 2, ChnrouteForeign: 1,
		CacheEntries: 42,
		ChinaOK:      1, ChinaErr: 1, TrustOK: 1, TrustErr: 1,
	}
	if got != want {
		t.Errorf("Stats() = %+v, want %+v", got, want)
	}
}

func TestControllerStatsNilSafe(t *testing.T) {
	c := NewController(func() error { return nil }, nil, nil, nil)
	got := c.Stats()
	want := Stats{}
	if got != want {
		t.Errorf("Stats() with nil stats/cacheLen = %+v, want zero value %+v", got, want)
	}
}
