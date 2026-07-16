package main

import (
	"context"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// B1: Cache.Flush invalidates every entry (Get miss) and is nil-safe. Flush now
// expires entries in place rather than dropping them (so serve-stale survives a
// reload — see TestCacheFlushPreservesServeStale), so the invariant is "Get is a
// miss for every previously-cached name", not "Len()==0".
func TestCacheFlush(t *testing.T) {
	c := NewCache(8)
	c.Put("a.test", dns.TypeA, makeAMsg("a.test", "1.2.3.4"), time.Minute)
	c.Put("b.test", dns.TypeA, makeAMsg("b.test", "5.6.7.8"), time.Minute)
	if _, ok := c.Get("a.test", dns.TypeA); !ok {
		t.Fatal("precondition: a.test should be cached")
	}
	c.Flush()
	if _, ok := c.Get("a.test", dns.TypeA); ok {
		t.Error("after Flush: a.test must be a miss (invalidated)")
	}
	if _, ok := c.Get("b.test", dns.TypeA); ok {
		t.Error("after Flush: b.test must be a miss (invalidated)")
	}
	// A nil *Cache must be a no-op, not a panic (callers rely on this).
	var nilCache *Cache
	nilCache.Flush()
}

// B1: a rule-set reload (swapRuleSets) must invalidate the response cache, so a
// rule change takes effect immediately instead of being masked by an already-
// cached rewritten answer until TTL expiry (up to DNS_TTL_MAX, default 24h).
func TestSwapRuleSetsFlushesCache(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	h.Cache.Put("cached.test", dns.TypeA, makeAMsg("cached.test", "1.2.3.4"), time.Minute)
	if _, ok := h.Cache.Get("cached.test", dns.TypeA); !ok {
		t.Fatal("precondition: expected a cached entry")
	}
	h.swapRuleSets(h.CN)
	if _, ok := h.Cache.Get("cached.test", dns.TypeA); ok {
		t.Fatal("swapRuleSets did not invalidate the cache: cached.test still a hit")
	}
}

// B2: concurrent diagnostics and chnroute reloads must not race.
func TestControllerResolveTestRaceWithReload(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("x.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("x.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	c := NewController(func() error { return nil }, nil, nil, h)

	// Two distinct chnroute snapshots the reloader alternates between, so the
	// atomic pointer genuinely changes on each swap.
	cnA := &Chnroute{ranges: []ipRange{{start: ipToUint32(net.ParseIP("1.0.0.0").To4()), end: ipToUint32(net.ParseIP("1.255.255.255").To4())}}}
	cnB := &Chnroute{ranges: []ipRange{{start: ipToUint32(net.ParseIP("2.0.0.0").To4()), end: ipToUint32(net.ParseIP("2.255.255.255").To4())}}}

	var wg sync.WaitGroup
	stop := make(chan struct{})

	// Reloader: hammer swapRuleSets (the reload path) from two goroutines at once
	// (mimicking two subscription tickers firing together).
	for r := 0; r < 2; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; ; i++ {
				select {
				case <-stop:
					return
				default:
				}
				cn := cnA
				if i%2 == 1 {
					cn = cnB
				}
				h.swapRuleSets(cn)
			}
		}()
	}

	// Run diagnostics concurrently with reloads.
	for r := 0; r < 3; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				_ = c.ResolveTest(context.Background(), "x.test")
			}
		}()
	}

	time.Sleep(150 * time.Millisecond)
	close(stop)
	wg.Wait()
}
