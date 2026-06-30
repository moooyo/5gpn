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
