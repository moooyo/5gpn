package chnroute

import (
	"sync"
	"time"

	"github.com/miekg/dns"
)

// cacheKey identifies a cached DNS response.
type cacheKey struct {
	name  string
	qtype uint16
}

// entry holds a cached DNS message and its expiry timestamp.
type entry struct {
	msg    *dns.Msg  // deep copy of the original response
	expiry time.Time // time after which the entry is stale
}

// Cache is a concurrency-safe, capacity-bounded TTL cache for DNS responses,
// keyed by (name, qtype).
type Cache struct {
	mu  sync.Mutex
	m   map[cacheKey]entry
	max int
	now func() time.Time // injectable clock for deterministic tests
}

// NewCache creates a Cache that holds at most max entries.
// max must be > 0.
func NewCache(max int) *Cache {
	return &Cache{
		m:   make(map[cacheKey]entry),
		max: max,
		now: time.Now,
	}
}

// Get returns a deep copy of the cached response for (name, qtype) with each
// answer RR's TTL adjusted to the remaining time-to-live.
// Returns (nil, false) if the entry is absent or has expired.
func (c *Cache) Get(name string, qtype uint16) (*dns.Msg, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	k := cacheKey{name: name, qtype: qtype}
	e, ok := c.m[k]
	if !ok {
		return nil, false
	}

	now := c.now()
	if !now.Before(e.expiry) {
		// Entry has expired — evict it.
		delete(c.m, k)
		return nil, false
	}

	// Deep-copy the message so the caller cannot corrupt the cached value.
	cp := e.msg.Copy()

	// Adjust each answer RR's TTL to the remaining seconds.
	remaining := e.expiry.Sub(now)
	remainingSecs := uint32(remaining.Seconds())
	for _, rr := range cp.Answer {
		rr.Header().Ttl = remainingSecs
	}

	return cp, true
}

// Put stores a deep copy of m in the cache under (name, qtype) with the given
// TTL.  If adding the entry would exceed max, one arbitrary existing entry is
// evicted first.
func (c *Cache) Put(name string, qtype uint16, m *dns.Msg, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()

	k := cacheKey{name: name, qtype: qtype}

	// If we're at capacity and this is a new key, evict one arbitrary entry.
	if len(c.m) >= c.max {
		if _, exists := c.m[k]; !exists {
			// Evict the first key found (map iteration order is random,
			// giving us a simple "evict any" policy).
			for victim := range c.m {
				delete(c.m, victim)
				break
			}
		}
	}

	c.m[k] = entry{
		msg:    m.Copy(),
		expiry: c.now().Add(ttl),
	}
}
