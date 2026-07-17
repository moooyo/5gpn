package main

import (
	"testing"
	"time"

	"github.com/miekg/dns"
)

// makeMsg builds a minimal *dns.Msg with one A RR whose TTL is set to ttl.
func makeMsg(name string, ttl uint32) *dns.Msg {
	m := new(dns.Msg)
	m.SetReply(new(dns.Msg))
	rr := &dns.A{
		Hdr: dns.RR_Header{
			Name:   dns.Fqdn(name),
			Rrtype: dns.TypeA,
			Class:  dns.ClassINET,
			Ttl:    ttl,
		},
	}
	m.Answer = []dns.RR{rr}
	return m
}

// TestCachePutGetCopy verifies that Put→Get returns an independent copy:
// mutating the returned message must not corrupt the cached entry.
func TestCachePutGetCopy(t *testing.T) {
	c := NewCache(10)

	original := makeMsg("example.com.", 300)
	c.Put("example.com.", dns.TypeA, original, 5*time.Minute)

	got, ok := c.Get("example.com.", dns.TypeA)
	if !ok {
		t.Fatal("expected cache hit, got miss")
	}
	if got == nil {
		t.Fatal("got nil message from cache hit")
	}

	// Mutate the returned copy.
	got.Answer[0].(*dns.A).Hdr.Ttl = 9999

	// A second Get must still return the un-mutated TTL (modulo clock adjustment).
	got2, ok2 := c.Get("example.com.", dns.TypeA)
	if !ok2 {
		t.Fatal("expected second cache hit")
	}
	if got2.Answer[0].(*dns.A).Hdr.Ttl == 9999 {
		t.Error("mutating returned copy corrupted the cache entry")
	}
}

func TestCachePreservesDecisionMetadata(t *testing.T) {
	c := NewCache(2)
	m := makeMsg("foreign.example.", 300)
	want := cacheMetadata{Verdict: "direct", Reason: "fallback-direct", Upstream: "trust"}
	c.PutWithMetadata("foreign.example.", dns.TypeA, m, time.Minute, want)
	_, got, ok := c.GetWithMetadata("foreign.example.", dns.TypeA)
	if !ok || got != want {
		t.Fatalf("metadata = %+v, %v; want %+v, true", got, ok, want)
	}
}

func TestCacheCanonicalizesQuestionName(t *testing.T) {
	c := NewCache(2)
	c.Put("MiXeD.Example.", dns.TypeA, makeMsg("mixed.example.", 300), time.Minute)
	if _, ok := c.Get("mixed.example.", dns.TypeA); !ok {
		t.Fatal("DNS name casing created a distinct cache key")
	}
	if c.Len() != 1 {
		t.Fatalf("cache length = %d, want one canonical entry", c.Len())
	}
}

func TestCacheSeparatesDNSSECRequestProfiles(t *testing.T) {
	c := NewCache(4)
	epoch := c.Epoch()
	plain := cacheOptions{}
	do := cacheOptions{dnssecOK: true}
	cd := cacheOptions{checkingDisabled: true}
	c.PutAtEpochWithMetadataOptions("example.com.", dns.TypeA, do, makeMsg("example.com.", 300), time.Minute, epoch, cacheMetadata{})
	if _, _, ok := c.GetWithMetadataOptions("example.com.", dns.TypeA, plain); ok {
		t.Fatal("plain query reused a DO=1 response")
	}
	if _, _, ok := c.GetWithMetadataOptions("example.com.", dns.TypeA, cd); ok {
		t.Fatal("CD=1 query reused a DO=1 response")
	}
	if _, _, ok := c.GetWithMetadataOptions("example.com.", dns.TypeA, do); !ok {
		t.Fatal("matching DO=1 query missed its cache entry")
	}
}

// TestCacheExpiry verifies that an entry whose TTL has elapsed returns false.
func TestCacheExpiry(t *testing.T) {
	now := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	c := NewCache(10)
	c.now = func() time.Time { return now }

	m := makeMsg("example.com.", 10)
	c.Put("example.com.", dns.TypeA, m, 10*time.Second)

	// Advance clock past expiry.
	now = now.Add(11 * time.Second)

	got, ok := c.Get("example.com.", dns.TypeA)
	if ok || got != nil {
		t.Errorf("expected expired entry to return nil,false; got ok=%v msg=%v", ok, got)
	}
}

// TestCacheAdjustedTTL verifies that Get returns a copy with remaining TTL
// (not the original TTL).
func TestCacheAdjustedTTL(t *testing.T) {
	now := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	c := NewCache(10)
	c.now = func() time.Time { return now }

	m := makeMsg("example.com.", 100)
	c.Put("example.com.", dns.TypeA, m, 100*time.Second)

	// Advance clock by 40 seconds — remaining TTL should be ~60s.
	now = now.Add(40 * time.Second)

	got, ok := c.Get("example.com.", dns.TypeA)
	if !ok {
		t.Fatal("expected cache hit")
	}
	remaining := got.Answer[0].(*dns.A).Hdr.Ttl
	if remaining > 60 || remaining < 59 {
		t.Errorf("expected remaining TTL ~60, got %d", remaining)
	}
}

// TestCacheCapacityEviction verifies that inserting more than max entries
// does not grow the cache beyond max.
func TestCacheCapacityEviction(t *testing.T) {
	const max = 3
	c := NewCache(max)

	for i := uint16(0); i < max+2; i++ {
		// Use distinct qtypes as the key discriminator (name constant, qtype varies).
		m := makeMsg("example.com.", 300)
		c.Put("example.com.", i, m, 5*time.Minute)
	}

	c.mu.Lock()
	size := len(c.m)
	c.mu.Unlock()

	if size > max {
		t.Errorf("cache size %d exceeds max %d after overflow inserts", size, max)
	}
}

// TestCacheMiss verifies that a Get for an unknown key returns nil,false.
func TestCacheMiss(t *testing.T) {
	c := NewCache(10)
	got, ok := c.Get("missing.example.", dns.TypeA)
	if ok || got != nil {
		t.Errorf("expected miss, got ok=%v msg=%v", ok, got)
	}
}

// TestCacheFlushPreservesServeStale locks the L3 fix: Flush must expire entries
// in place (Get miss so the reload takes effect) yet keep them serveable via
// GetStale within staleGrace, so a rule reload during a full upstream outage
// does not wipe the serve-stale safety net.
func TestCacheFlushPreservesServeStale(t *testing.T) {
	now := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	c := NewCache(10)
	c.now = func() time.Time { return now }

	c.Put("example.com.", dns.TypeA, makeMsg("example.com.", 300), 5*time.Minute)
	if _, ok := c.Get("example.com.", dns.TypeA); !ok {
		t.Fatal("pre-flush: expected a fresh hit")
	}

	c.Flush()

	// Get is now a miss (the name must re-resolve under the reloaded rules)...
	if _, ok := c.Get("example.com.", dns.TypeA); ok {
		t.Error("post-flush: Get must be a miss (entry expired in place)")
	}
	// ...but the serve-stale fallback still has it (within staleGrace).
	if _, ok := c.GetStale("example.com.", dns.TypeA, 30); !ok {
		t.Error("post-flush: GetStale must still serve the entry (serve-stale survives reload)")
	}
	// Beyond staleGrace it is gone.
	now = now.Add(staleGrace + time.Minute)
	if _, ok := c.GetStale("example.com.", dns.TypeA, 30); ok {
		t.Error("beyond staleGrace: GetStale must prune the entry")
	}
	// The cache is still usable after a flush (map not broken).
	c.Put("fresh.com.", dns.TypeA, makeMsg("fresh.com.", 300), 5*time.Minute)
	if _, ok := c.Get("fresh.com.", dns.TypeA); !ok {
		t.Error("post-flush: a fresh Put/Get must work")
	}
}

// TestCacheEvictionPrefersExpired locks the L6 fix: at capacity, eviction must
// prefer an already-expired (zombie) entry over a hot live one.
func TestCacheEvictionPrefersExpired(t *testing.T) {
	now := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	c := NewCache(2)
	c.now = func() time.Time { return now }

	c.Put("expired.com.", dns.TypeA, makeMsg("expired.com.", 1), 1*time.Second)
	c.Put("live.com.", dns.TypeA, makeMsg("live.com.", 3600), 1*time.Hour)

	now = now.Add(2 * time.Second) // expired.com is now past its TTL; live.com still live
	// Inserting a third (new) key is at capacity → must evict the expired one.
	c.Put("new.com.", dns.TypeA, makeMsg("new.com.", 300), 5*time.Minute)

	if _, ok := c.Get("live.com.", dns.TypeA); !ok {
		t.Error("live entry was evicted while an expired one survived")
	}
	if _, ok := c.GetStale("expired.com.", dns.TypeA, 30); ok {
		t.Error("expired entry should have been the eviction victim (gone entirely)")
	}
	if _, ok := c.Get("new.com.", dns.TypeA); !ok {
		t.Error("newly inserted entry missing")
	}
}
