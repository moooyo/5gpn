package main

import (
	"strings"
	"sync"
	"time"

	"github.com/miekg/dns"
)

// cacheKey identifies a cached DNS response.
type cacheKey struct {
	name             string
	qtype            uint16
	dnssecOK         bool
	checkingDisabled bool
}

// cacheOptions are request properties that can change the upstream response.
// Client ECS is deliberately absent: it is stripped before every upstream
// exchange, so it can never be part of response selection or cache identity.
type cacheOptions struct {
	dnssecOK         bool
	checkingDisabled bool
}

func cacheOptionsFromMsg(m *dns.Msg) cacheOptions {
	if m == nil {
		return cacheOptions{}
	}
	opts := cacheOptions{checkingDisabled: m.CheckingDisabled}
	if opt := m.IsEdns0(); opt != nil {
		opts.dnssecOK = opt.Do()
	}
	return opts
}

func newCacheKey(name string, qtype uint16, opts cacheOptions) cacheKey {
	return cacheKey{
		name:             strings.ToLower(dns.Fqdn(name)),
		qtype:            qtype,
		dnssecOK:         opts.dnssecOK,
		checkingDisabled: opts.checkingDisabled,
	}
}

// entry holds a cached DNS message and its expiry timestamp.
type entry struct {
	msg    *dns.Msg  // deep copy of the original response
	expiry time.Time // time after which the entry is stale
	meta   cacheMetadata
}

// cacheMetadata preserves the decision that produced a cached response. The
// final DNS message alone cannot distinguish, for example, a fallback-direct
// foreign answer from a normal chnroute-CN answer.
type cacheMetadata struct {
	Verdict  string
	Reason   string
	Upstream string
}

// Cache is a concurrency-safe, capacity-bounded TTL cache for DNS responses,
// keyed by the canonical name, qtype, and DNSSEC request properties.
type Cache struct {
	mu  sync.Mutex
	m   map[cacheKey]entry
	max int
	now func() time.Time // injectable clock for deterministic tests

	// epoch increments on every Flush. Resolvers capture it BEFORE loading the
	// rule snapshot and pass it back via PutAtEpoch; a mismatch means a Flush
	// (rule reload) happened while the query was in flight, so the answer —
	// computed under the pre-reload rules — must not repopulate the freshly
	// flushed cache, where it would re-mask the rule change for up to its TTL.
	epoch uint64
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
	m, _, ok := c.GetWithMetadata(name, qtype)
	return m, ok
}

// GetWithMetadata is Get plus the decision metadata stored with the response.
func (c *Cache) GetWithMetadata(name string, qtype uint16) (*dns.Msg, cacheMetadata, bool) {
	return c.GetWithMetadataOptions(name, qtype, cacheOptions{})
}

// GetWithMetadataOptions is GetWithMetadata with response-varying request
// properties included in the cache identity.
func (c *Cache) GetWithMetadataOptions(name string, qtype uint16, opts cacheOptions) (*dns.Msg, cacheMetadata, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	k := newCacheKey(name, qtype, opts)
	e, ok := c.m[k]
	if !ok {
		return nil, cacheMetadata{}, false
	}

	now := c.now()
	if !now.Before(e.expiry) {
		// Expired: a normal miss — but DO NOT delete the entry. Keeping it lets
		// GetStale serve it as a last resort when every upstream fails (serve-
		// stale). Beyond-grace pruning happens in GetStale; capacity eviction
		// bounds accumulation.
		return nil, cacheMetadata{}, false
	}

	// Deep-copy the message so the caller cannot corrupt the cached value.
	cp := e.msg.Copy()

	// Adjust each answer RR's TTL to the remaining seconds.
	remaining := e.expiry.Sub(now)
	remainingSecs := uint32(remaining.Seconds())
	for _, rr := range cp.Answer {
		rr.Header().Ttl = remainingSecs
	}
	capSectionTTLs(cp.Ns, remainingSecs)
	capSectionTTLs(cp.Extra, remainingSecs)

	return cp, e.meta, true
}

// staleGrace bounds how long past its expiry a cached entry may still be served
// stale (serve-stale, RFC 8767 spirit): older than this and it's too stale to be
// trusted even as a last resort, and GetStale prunes it.
const staleGrace = 1 * time.Hour

// GetStale returns a cached response for (name, qtype) even if it has expired,
// as long as it is within staleGrace of its expiry, with every answer RR's TTL
// clamped to ttlSecs so clients re-query soon. It is the last-resort fallback
// when every upstream failed: serving a slightly-stale answer beats SERVFAIL.
// An entry older than staleGrace is pruned and reported as a miss.
func (c *Cache) GetStale(name string, qtype uint16, ttlSecs uint32) (*dns.Msg, bool) {
	m, _, ok := c.GetStaleWithMetadata(name, qtype, ttlSecs)
	return m, ok
}

func (c *Cache) GetStaleWithMetadata(name string, qtype uint16, ttlSecs uint32) (*dns.Msg, cacheMetadata, bool) {
	return c.GetStaleWithMetadataOptions(name, qtype, ttlSecs, cacheOptions{})
}

// GetStaleWithMetadataOptions is the request-profile-aware stale lookup.
func (c *Cache) GetStaleWithMetadataOptions(name string, qtype uint16, ttlSecs uint32, opts cacheOptions) (*dns.Msg, cacheMetadata, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	k := newCacheKey(name, qtype, opts)
	e, ok := c.m[k]
	if !ok {
		return nil, cacheMetadata{}, false
	}
	if c.now().Sub(e.expiry) > staleGrace {
		delete(c.m, k)
		return nil, cacheMetadata{}, false
	}
	cp := e.msg.Copy()
	for _, rr := range cp.Answer {
		rr.Header().Ttl = ttlSecs
	}
	capSectionTTLs(cp.Ns, ttlSecs)
	capSectionTTLs(cp.Extra, ttlSecs)
	return cp, e.meta, true
}

func capSectionTTLs(rrs []dns.RR, max uint32) {
	for _, rr := range rrs {
		if _, ok := rr.(*dns.OPT); ok {
			continue
		}
		if rr.Header().Ttl > max {
			rr.Header().Ttl = max
		}
	}
}

// Put stores a deep copy of m in the cache under (name, qtype) with the given
// TTL.  If adding the entry would exceed max, one arbitrary existing entry is
// evicted first.
func (c *Cache) Put(name string, qtype uint16, m *dns.Msg, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.putLocked(name, qtype, cacheOptions{}, m, ttl, cacheMetadata{})
}

// PutWithMetadata stores a response and the decision that produced it.
func (c *Cache) PutWithMetadata(name string, qtype uint16, m *dns.Msg, ttl time.Duration, meta cacheMetadata) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.putLocked(name, qtype, cacheOptions{}, m, ttl, meta)
}

// Epoch returns the current flush epoch (see the epoch field). Nil-safe.
func (c *Cache) Epoch() uint64 {
	if c == nil {
		return 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.epoch
}

// PutAtEpoch stores like Put, but only if no Flush has happened since the
// caller captured epoch — the guard that keeps an in-flight query from writing
// a pre-reload answer into the freshly flushed cache. The answer is still
// returned to the client; it just doesn't populate the cache.
func (c *Cache) PutAtEpoch(name string, qtype uint16, m *dns.Msg, ttl time.Duration, epoch uint64) {
	c.PutAtEpochWithMetadata(name, qtype, m, ttl, epoch, cacheMetadata{})
}

// PutAtEpochWithMetadata is PutAtEpoch plus decision metadata.
func (c *Cache) PutAtEpochWithMetadata(name string, qtype uint16, m *dns.Msg, ttl time.Duration, epoch uint64, meta cacheMetadata) {
	c.PutAtEpochWithMetadataOptions(name, qtype, cacheOptions{}, m, ttl, epoch, meta)
}

// PutAtEpochWithMetadataOptions stores a response under its complete request
// profile while retaining the flush-epoch safety check.
func (c *Cache) PutAtEpochWithMetadataOptions(name string, qtype uint16, opts cacheOptions, m *dns.Msg, ttl time.Duration, epoch uint64, meta cacheMetadata) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if epoch != c.epoch {
		return
	}
	c.putLocked(name, qtype, opts, m, ttl, meta)
}

// putLocked is the shared Put body. Caller must hold c.mu.
func (c *Cache) putLocked(name string, qtype uint16, opts cacheOptions, m *dns.Msg, ttl time.Duration, meta cacheMetadata) {
	k := newCacheKey(name, qtype, opts)

	// If we're at capacity and this is a new key, evict one entry (preferring
	// an already-expired zombie over a hot live entry).
	if len(c.m) >= c.max {
		if _, exists := c.m[k]; !exists {
			c.evictOneLocked()
		}
	}

	c.m[k] = entry{
		msg:    m.Copy(),
		expiry: c.now().Add(ttl),
		meta:   meta,
	}
}

// evictOneLocked removes one entry, preferring an already-expired one so a hot
// live entry is not dropped while an expired (post-Flush or beyond-TTL) zombie
// survives. To keep eviction O(1)-ish even for a large cache under a flood, it
// samples a bounded number of entries rather than scanning the whole map:
// map order is random, so a small sample reliably surfaces an expired entry when
// many exist (e.g. right after Flush marks everything expired), and falls back to
// evicting the first sampled key when none in the sample are expired. Caller must
// hold c.mu and must only call this when len(c.m) > 0.
func (c *Cache) evictOneLocked() {
	const sample = 8
	now := c.now()
	var first cacheKey
	i := 0
	for k, e := range c.m {
		if i == 0 {
			first = k // arbitrary fallback if the sample has no expired entry
		}
		if !now.Before(e.expiry) { // expired (stale/zombie): evict this one
			delete(c.m, k)
			return
		}
		if i++; i >= sample {
			break
		}
	}
	delete(c.m, first)
}

// Len returns the current number of entries in the cache (including any not
// yet lazily evicted on expiry).
func (c *Cache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.m)
}

// Flush invalidates every cached entry after a rule-set reload (see
// Handler.swapRuleSets) so a rule change takes effect immediately instead of
// being masked by already-cached responses. Cached values are the *final,
// rewritten* answers (rewriteA / force-direct / forwardTrust output), so a
// domain moved into force-proxy, out of force-direct, or reclassified by a
// chnroute update would otherwise keep serving its pre-change answer until the
// entry's TTL expires — up to DNS_TTL_MAX (default 24h) — turning an API/bot/
// SIGHUP "reload" into a silent no-op for already-cached names.
//
// It EXPIRES every entry in place (sets expiry to now) rather than dropping the
// map: Get then treats them as misses (the name re-resolves under the new
// rules), but GetStale can still serve them within staleGrace. That preserves
// the serve-stale safety net if a reload lands during a full upstream outage —
// dropping the map outright would wipe the last-known answers and turn every
// name into SERVFAIL until an upstream recovers. Capacity eviction (which now
// prefers expired entries) reclaims the space. A nil *Cache is a no-op.
func (c *Cache) Flush() {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	past := c.now()
	for k, e := range c.m {
		e.expiry = past
		c.m[k] = e
	}
	c.epoch++ // invalidate in-flight PutAtEpoch writers (pre-reload answers)
}
