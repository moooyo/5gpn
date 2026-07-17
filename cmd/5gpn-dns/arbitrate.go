package main

import (
	"context"
	"time"

	"github.com/miekg/dns"
)

// chinaIsCN reports whether reply contains at least one A record whose IP
// is within the chnroute set.
func chinaIsCN(reply *dns.Msg, cn *Chnroute) bool {
	if reply == nil {
		return false
	}
	// A truncated china reply carries only a partial Answer set; deciding CN
	// membership on it could misclassify a CN domain as foreign (and funnel it
	// through the gateway). Treat truncated as non-authoritative and fall
	// through to the independently configured trust upstream.
	if reply.Truncated {
		return false
	}
	for _, rr := range reply.Answer {
		if a, ok := rr.(*dns.A); ok {
			if cn.Contains(a.A) {
				return true
			}
		}
	}
	return false
}

// Arbitrate runs china and trust concurrently and returns one reply according
// to the deterministic chnroute rule:
//
//   - Start both upstreams simultaneously.
//   - Wait for the china reply (bounded by ctx deadline set by the caller).
//   - If the china reply contains any A record ∈ cn → return the china reply.
//   - Otherwise (china foreign/error/timeout/NODATA) → return the trust reply.
//
// The decision is based solely on the chnroute membership of the china answer —
// NEVER on which upstream returned first.  Both upstreams are bounded by the
// caller's ctx deadline; no second timeout is added here, but Arbitrate derives
// a cancellable child ctx and cancels it on return so the abandoned upstream
// (trust, when china wins CN) is torn down immediately instead of lingering
// until the caller's ctx is cancelled/expires.
//
// stats (nil-safe) records upstream health: china is always awaited so its
// ok/err is always counted; trust is only counted when it is actually consulted
// (i.e. when china was not a CN answer) — when china wins, trust's result is
// never read so it is not counted.
func Arbitrate(ctx context.Context, q *dns.Msg, china, trust Exchanger, cn *Chnroute, stats *statsCounters) (*dns.Msg, error) {
	m, _, err := arbitrateSrc(ctx, q, china, trust, cn, stats)
	return m, err
}

// arbitrateSrc is Arbitrate plus which group's reply was adopted ("china" or
// "trust"; "" on error) — feeding the query log's upstream column without
// re-deriving the decision from the answer IPs.
func arbitrateSrc(ctx context.Context, q *dns.Msg, china, trust Exchanger, cn *Chnroute, stats *statsCounters) (*dns.Msg, string, error) {
	// Cancel the abandoned upstream as soon as we return. Inherits the caller's
	// deadline (adds no new timeout); combined with the buffered channels below,
	// this keeps the abandoned goroutine from lingering on a slow/hung upstream
	// even when the caller's ctx has no cancel of its own.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	type exchangeResult struct {
		msg *dns.Msg
		err error
	}

	chinaCh := make(chan exchangeResult, 1)
	trustCh := make(chan exchangeResult, 1)

	// Launch both concurrently on the caller's ctx.
	go func() {
		start := time.Now()
		m, err := china.Exchange(ctx, q)
		stats.recordChinaLatency(time.Since(start))
		chinaCh <- exchangeResult{m, err}
	}()
	go func() {
		start := time.Now()
		m, err := trust.Exchange(ctx, q)
		stats.recordTrustLatency(time.Since(start))
		trustCh <- exchangeResult{m, err}
	}()

	// Wait for the china result (bounded by ctx deadline).
	chinaRes := <-chinaCh
	stats.bumpChina(chinaRes.err == nil)

	// Deterministic decision: if china has a CN address, return it. This is by
	// chnroute MEMBERSHIP only — never by upstream health/speed. The china/trust
	// health counters bumped here are observability-only and deliberately do NOT
	// influence this choice (TestArbitrateDeterminism locks it: a slow CN answer
	// still wins over a fast trust one).
	if chinaRes.err == nil && chinaIsCN(chinaRes.msg, cn) {
		return chinaRes.msg, "china", nil
	}

	// Fall back to trust — await it unconditionally.
	trustRes := <-trustCh
	stats.bumpTrust(trustRes.err == nil)
	if trustRes.err != nil {
		return nil, "", trustRes.err
	}
	return trustRes.msg, "trust", nil
}
