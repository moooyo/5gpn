package main

import (
	"context"
	"testing"
)

// ---------------------------------------------------------------------------
// Reload
// ---------------------------------------------------------------------------
//
// NOTE (UP-1 Task D3): the manual-rule facade (AddRule/RemoveRule/ListRules/
// ListAllRules), the subscription CRUD facade (AddSubscription/
// RemoveSubscription/ReplaceSubscription/ValidateSubscription/
// GetSubscription/Subscriptions/SubscriptionsWithHealth), and their
// coverage below were REMOVED here — absorbed by the unified policy-rule
// model (policy_rules.go/policy_engine.go), which is covered by
// policy_rules_test.go / policy_engine_test.go instead. The underlying
// SubManager fetch engine (subscription.go) is untouched and still tested
// by subscription_test.go.

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
	stats.block.Store(5)
	stats.forceDirect.Store(4)
	stats.blacklist.Store(3)
	stats.chnrouteCN.Store(2)
	stats.chnrouteForeign.Store(1)
	stats.chinaOK.Store(1)
	stats.chinaErr.Store(1)
	stats.trustOK.Store(1)
	stats.trustErr.Store(1)

	cacheLen := func() int { return 42 }

	c := NewController(nil, func() error { return nil }, t.TempDir(), stats, cacheLen, nil)
	got := c.Stats()

	want := Stats{
		Total: 10, Block: 5, ForceDirect: 4, Blacklist: 3, ChnrouteCN: 2, ChnrouteForeign: 1,
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

func TestControllerLookupBlockNoUpstream(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, h)

	got := c.Lookup(context.Background(), "block.test")
	if got.Name != "block.test" || got.Verdict != "block" || got.Reason != "block" {
		t.Errorf("Lookup(block.test) = %+v, want Name=block.test Verdict=block Reason=block", got)
	}
	if len(got.IPs) != 0 {
		t.Errorf("Lookup(block.test).IPs = %v, want empty (no upstream call)", got.IPs)
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

func TestControllerLookupHonorsFallbackModes(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("unmatched.test", "9.9.9.8")}
	trust := &fakeExchanger{reply: makeAMsg("unmatched.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	c := NewController(nil, func() error { return nil }, t.TempDir(), nil, nil, h)

	h.setFallback(FallbackDirect)
	got := c.Lookup(context.Background(), "unmatched.test")
	if got.Verdict != "direct" || got.Reason != "fallback-direct" || len(got.IPs) != 1 || got.IPs[0] != "9.9.9.9" {
		t.Fatalf("direct fallback lookup = %+v", got)
	}

	h.setFallback(FallbackGateway)
	got = c.Lookup(context.Background(), "unmatched.test")
	if got.Verdict != "proxy" || got.Reason != "fallback-gateway" || len(got.IPs) != 0 {
		t.Fatalf("gateway fallback lookup = %+v", got)
	}
}
