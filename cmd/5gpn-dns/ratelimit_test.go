package main

import (
	"testing"
	"time"
)

// TestRateLimiter_AllowsBurstThenDenies confirms the classic token-bucket
// shape: rate=1/s, burst=3 allows 3 immediate calls at the same instant, then
// denies the 4th; after advancing the clock by 1s exactly one more token has
// refilled, so exactly one more call is allowed.
func TestRateLimiter_AllowsBurstThenDenies(t *testing.T) {
	rl := newRateLimiter(1, 3)
	if rl == nil {
		t.Fatal("newRateLimiter(1, 3) = nil, want a live limiter")
	}

	now := time.Now()
	for i := 0; i < 3; i++ {
		if !rl.allow("1.2.3.4", now) {
			t.Fatalf("call %d at t0 denied, want allowed (within burst)", i+1)
		}
	}
	if rl.allow("1.2.3.4", now) {
		t.Fatal("4th call at t0 allowed, want denied (burst exhausted)")
	}

	// Advance by 1s: exactly 1 token refills (rate=1/s).
	later := now.Add(1 * time.Second)
	if !rl.allow("1.2.3.4", later) {
		t.Fatal("call after 1s refill denied, want allowed")
	}
	if rl.allow("1.2.3.4", later) {
		t.Fatal("second call after only 1 token refilled allowed, want denied")
	}
}

// TestRateLimiter_IndependentKeys confirms different keys (source IPs) get
// independent buckets -- exhausting one key's burst must not affect another.
func TestRateLimiter_IndependentKeys(t *testing.T) {
	rl := newRateLimiter(1, 2)
	now := time.Now()

	if !rl.allow("1.1.1.1", now) || !rl.allow("1.1.1.1", now) {
		t.Fatal("first key: first 2 calls should be allowed")
	}
	if rl.allow("1.1.1.1", now) {
		t.Fatal("first key: 3rd call should be denied")
	}

	// A different key must still have its own full bucket.
	if !rl.allow("2.2.2.2", now) || !rl.allow("2.2.2.2", now) {
		t.Fatal("second key: first 2 calls should be allowed independently")
	}
}

// TestRateLimiter_DisabledAllowsEverything confirms rate<=0 disables limiting
// entirely: newRateLimiter returns something whose allow() always says yes
// (or nil, and callers must treat nil as "allow all" -- this test exercises
// whichever contract the implementation chooses by calling allow() only when
// non-nil).
func TestRateLimiter_DisabledAllowsEverything(t *testing.T) {
	rl := newRateLimiter(0, 40)
	if rl == nil {
		return // nil is an acceptable "disabled" sentinel.
	}
	now := time.Now()
	for i := 0; i < 1000; i++ {
		if !rl.allow("3.3.3.3", now) {
			t.Fatalf("call %d denied with rate<=0, want always allowed", i+1)
		}
	}
}

// TestRateLimiter_NegativeRateAlsoDisables mirrors the zero case for a
// negative rate, since Config treats "<=0" as the disable sentinel.
func TestRateLimiter_NegativeRateAlsoDisables(t *testing.T) {
	rl := newRateLimiter(-5, 40)
	if rl == nil {
		return
	}
	now := time.Now()
	if !rl.allow("4.4.4.4", now) {
		t.Fatal("negative rate should disable limiting (always allow)")
	}
}

// TestRateLimiter_TokensCapAtBurst confirms tokens don't accumulate past
// burst even after a long idle period -- i.e. refill is capped, not
// unbounded.
func TestRateLimiter_TokensCapAtBurst(t *testing.T) {
	rl := newRateLimiter(10, 3)
	now := time.Now()

	// Prime the bucket, then let a long time pass (would refill way more
	// than 3 tokens at rate=10/s if uncapped).
	rl.allow("5.5.5.5", now)
	muchLater := now.Add(1 * time.Hour)

	// Only 3 calls should succeed even though "elapsed*rate" is enormous.
	allowed := 0
	for i := 0; i < 5; i++ {
		if rl.allow("5.5.5.5", muchLater) {
			allowed++
		}
	}
	if allowed != 3 {
		t.Fatalf("allowed = %d calls after long idle, want exactly burst=3 (capped refill)", allowed)
	}
}

// TestRateLimiter_StaleEvictionBoundsMapGrowth confirms bucket entries for
// keys that have gone idle well beyond the eviction window are eventually
// removed, so a flood of one-off source IPs doesn't grow the map forever.
func TestRateLimiter_StaleEvictionBoundsMapGrowth(t *testing.T) {
	rl := newRateLimiter(1, 3)
	now := time.Now()

	// Touch a large number of distinct keys at t0.
	const n = 500
	for i := 0; i < n; i++ {
		rl.allow(keyFor(i), now)
	}
	rl.mu.Lock()
	before := len(rl.buckets)
	rl.mu.Unlock()
	if before != n {
		t.Fatalf("buckets after seeding = %d, want %d", before, n)
	}

	// Jump far into the future (well past any reasonable idle window) and
	// touch one more key -- this should trigger eviction of the stale
	// entries, whether via a periodic sweep or opportunistic cleanup on
	// access.
	farFuture := now.Add(24 * time.Hour)
	rl.allow("trigger-sweep", farFuture)

	rl.mu.Lock()
	after := len(rl.buckets)
	rl.mu.Unlock()
	if after >= before {
		t.Fatalf("buckets after long idle + touch = %d, want fewer than %d (stale entries evicted)", after, before)
	}
}

func keyFor(i int) string {
	// Cheap distinct-key generator without importing fmt/strconv into the
	// test just for this.
	b := []byte("key-0000000000")
	for p := len(b) - 1; i > 0 && p >= 4; p-- {
		b[p] = byte('0' + i%10)
		i /= 10
	}
	return string(b)
}
