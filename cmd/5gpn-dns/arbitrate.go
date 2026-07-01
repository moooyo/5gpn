package main

import (
	"context"

	"github.com/miekg/dns"
)

// chinaIsCN reports whether reply contains at least one A record whose IP
// is within the chnroute set.
func chinaIsCN(reply *dns.Msg, cn *Chnroute) bool {
	if reply == nil {
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
// caller's ctx deadline; no second timeout is created here.
//
// stats (nil-safe) records upstream health: china is always awaited so its
// ok/err is always counted; trust is only counted when it is actually consulted
// (i.e. when china was not a CN answer) — when china wins, trust's result is
// never read so it is not counted.
func Arbitrate(ctx context.Context, q *dns.Msg, china, trust Exchanger, cn *Chnroute, stats *statsCounters) (*dns.Msg, error) {
	type exchangeResult struct {
		msg *dns.Msg
		err error
	}

	chinaCh := make(chan exchangeResult, 1)
	trustCh := make(chan exchangeResult, 1)

	// Launch both concurrently on the caller's ctx.
	go func() {
		m, err := china.Exchange(ctx, q)
		chinaCh <- exchangeResult{m, err}
	}()
	go func() {
		m, err := trust.Exchange(ctx, q)
		trustCh <- exchangeResult{m, err}
	}()

	// Wait for the china result (bounded by ctx deadline).
	chinaRes := <-chinaCh
	stats.bumpChina(chinaRes.err == nil)

	// Deterministic decision: if china has a CN address, return it.
	if chinaRes.err == nil && chinaIsCN(chinaRes.msg, cn) {
		return chinaRes.msg, nil
	}

	// Fall back to trust — await it unconditionally.
	trustRes := <-trustCh
	stats.bumpTrust(trustRes.err == nil)
	if trustRes.err != nil {
		return nil, trustRes.err
	}
	return trustRes.msg, nil
}
