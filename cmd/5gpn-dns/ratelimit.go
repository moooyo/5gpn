package main

import (
	"math"
	"sync"
	"time"
)

// rateLimiter is a hand-rolled per-source token-bucket limiter (stdlib only —
// see CLAUDE.md: no new third-party dependency, so no golang.org/x/time/rate).
//
// Each distinct key (a source IP, in api.go's usage) gets its own bucket that
// refills at rate tokens/sec up to a cap of burst tokens. allow consumes one
// token per call; when the bucket only holds a fractional token, the caller
// is denied.
//
// A rateLimiter is safe for concurrent use.
type rateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*tokenBucket
	rate    float64 // tokens per second; <= 0 means "disabled" (see newRateLimiter)
	burst   float64 // max tokens a bucket can hold

	calls     int       // opportunistic-eviction call counter (guarded by mu)
	lastSweep time.Time // wall-clock time of the last eviction sweep (guarded by mu)
}

// tokenBucket is one source's bucket: the current token count as of last,
// the last time it was refilled/consumed.
type tokenBucket struct {
	tokens float64
	last   time.Time
}

// evictSweepEvery controls how often (in allow() calls) the opportunistic
// stale-bucket sweep runs, as a fallback in case evictSweepInterval hasn't
// elapsed yet but the map is growing fast from call volume alone.
const evictSweepEvery = 256

// evictSweepInterval is the minimum wall-clock gap between eviction sweeps,
// measured against the now passed into allow(). This is what actually
// bounds map growth under a bursty-then-idle access pattern (e.g. a flood of
// one-off source IPs followed by a long quiet period): the very next call
// after the interval has elapsed triggers a sweep, regardless of how many
// calls happened in between.
const evictSweepInterval = 1 * time.Minute

// staleIdleFactor sets the eviction window as a multiple of the time it'd
// take to refill an empty bucket to full (burst/rate seconds). A bucket that
// has been idle that many multiples of its own refill time is long done
// being relevant and is safe to drop -- the next request from that source
// just starts a fresh, full bucket, which is the same behavior as if the
// entry had never been evicted (a bucket that's been idle this long is full
// again anyway).
const staleIdleFactor = 10

// newRateLimiter builds a rateLimiter for the given rate (tokens/sec) and
// burst (bucket capacity). A rate <= 0 disables rate limiting: the returned
// limiter's allow() always returns true, so callers don't need to special-
// case a nil limiter (though nil would also be a valid "disabled" sentinel —
// this implementation chooses a non-nil always-allow limiter instead, since
// it keeps the middleware wiring in api.go uniform).
func newRateLimiter(rate float64, burst int) *rateLimiter {
	b := burst
	if rate > 0 && b <= 0 {
		b = 40 // sane fallback; LoadConfig already guards this, but be defensive.
	}
	return &rateLimiter{
		buckets: make(map[string]*tokenBucket),
		rate:    rate,
		burst:   float64(b),
	}
}

// allow reports whether a request from key is allowed at time now, consuming
// one token from key's bucket if so. now is passed in (rather than read via
// time.Now() internally) so tests can drive the clock deterministically.
func (rl *rateLimiter) allow(key string, now time.Time) bool {
	if rl.rate <= 0 {
		return true // disabled: allow everything, no bucket bookkeeping at all.
	}

	rl.mu.Lock()
	defer rl.mu.Unlock()

	rl.calls++
	if rl.calls%evictSweepEvery == 0 || (rl.lastSweep.IsZero() && rl.calls == 1) || now.Sub(rl.lastSweep) >= evictSweepInterval {
		rl.evictLocked(now)
	}

	b, ok := rl.buckets[key]
	if !ok {
		// New key starts with a full bucket, minus the token this call
		// consumes.
		b = &tokenBucket{tokens: rl.burst, last: now}
		rl.buckets[key] = b
	} else {
		elapsed := now.Sub(b.last).Seconds()
		if elapsed > 0 {
			b.tokens = math.Min(rl.burst, b.tokens+elapsed*rl.rate)
			b.last = now
		}
	}

	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

// evictLocked removes buckets that have been idle long enough that they've
// long since refilled to full and are no longer worth tracking. Caller must
// hold rl.mu. This bounds map growth from a flood of one-off source IPs
// without needing a background goroutine.
func (rl *rateLimiter) evictLocked(now time.Time) {
	rl.lastSweep = now
	// Idle window in seconds: how long a bucket must sit untouched before it's
	// guaranteed refilled to full and no longer worth tracking. Computed in
	// float seconds and clamped to a sane ceiling so an extreme (mis)configured
	// burst/rate can't overflow the int64 nanosecond Duration below.
	secs := staleIdleFactor * rl.burst / rl.rate
	if secs <= 0 {
		return
	}
	if secs > 3600 {
		secs = 3600 // never track a bucket idle more than an hour
	}
	staleAfter := time.Duration(secs * float64(time.Second))
	for k, b := range rl.buckets {
		if now.Sub(b.last) > staleAfter {
			delete(rl.buckets, k)
		}
	}
}
