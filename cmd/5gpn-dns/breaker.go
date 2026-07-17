package main

import (
	"sync"
	"time"
)

const (
	// breakerThreshold is the consecutive-failure count that opens a group's
	// breaker; breakerCooldown is how long it stays open before a half-open probe.
	breakerThreshold = 5
	breakerCooldown  = 10 * time.Second
)

// breaker is a per-upstream-group circuit breaker. After breakerThreshold
// consecutive Exchange failures it opens for breakerCooldown, during which
// Exchange fails fast (no dial, no waiting on the query timeout) — so a
// blackholed upstream (RST'd or, worse, silently dropped) stops adding the
// library's ~2s read timeout to EVERY uncached query.
//
// The decision is by breaker STATE (a consecutive-failure count), never by
// latency, so it does NOT weaken the deterministic chnroute-membership
// arbitration: whenever the china group is actually answering, its answer is
// still honoured by membership; the breaker only short-circuits a group that has
// already failed repeatedly (where there is no answer to honour anyway).
type breaker struct {
	mu            sync.Mutex
	failures      int
	openUntil     time.Time
	probeInFlight bool
	now           func() time.Time // injectable clock for tests
}

func newBreaker() *breaker { return &breaker{now: time.Now} }

// allow reports whether a call may proceed. Open (still within cooldown) →
// false; otherwise true, including the single half-open probe once cooldown has
// elapsed. Nil-safe (a nil breaker always allows).
func (b *breaker) allow() bool {
	if b == nil {
		return true
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.openUntil.IsZero() {
		return true
	}
	if b.clock().Before(b.openUntil) || b.probeInFlight {
		return false
	}
	b.probeInFlight = true
	return true
}

// record folds one call outcome into the breaker: a success closes it (resets
// the count); a failure increments the count and opens the breaker once the
// threshold is reached (a failed half-open probe re-opens it, since failures is
// already at/over the threshold). Nil-safe.
func (b *breaker) record(ok bool) {
	if b == nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.probeInFlight = false
	if ok {
		b.failures = 0
		b.openUntil = time.Time{}
		return
	}
	b.failures++
	if b.failures >= breakerThreshold {
		b.openUntil = b.clock().Add(breakerCooldown)
	}
}

// recordCanceled releases a half-open probe slot without treating caller
// cancellation as upstream success or failure. A later request may probe again.
func (b *breaker) recordCanceled() {
	if b == nil {
		return
	}
	b.mu.Lock()
	b.probeInFlight = false
	b.mu.Unlock()
}

func (b *breaker) clock() time.Time {
	if b.now != nil {
		return b.now()
	}
	return time.Now()
}
