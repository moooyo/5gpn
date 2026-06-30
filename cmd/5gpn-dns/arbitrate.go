package chnroute

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
//   - Wait for the china reply (up to timeout).
//   - If the china reply contains any A record ∈ cn → return the china reply.
//   - Otherwise (china foreign/error/timeout/NODATA) → return the trust reply.
//
// The decision is based solely on the chnroute membership of the china answer —
// NEVER on which upstream returned first.
func Arbitrate(ctx context.Context, q *dns.Msg, china, trust Exchanger, cn *Chnroute, timeout time.Duration) (*dns.Msg, error) {
	// Each upstream runs in its own goroutine; we give china a bounded deadline.
	chinaCtx, chinaCancel := context.WithTimeout(ctx, timeout)
	defer chinaCancel()

	type exchangeResult struct {
		msg *dns.Msg
		err error
	}

	chinaCh := make(chan exchangeResult, 1)
	trustCh := make(chan exchangeResult, 1)

	// Launch both concurrently.
	go func() {
		m, err := china.Exchange(chinaCtx, q)
		chinaCh <- exchangeResult{m, err}
	}()
	go func() {
		m, err := trust.Exchange(ctx, q)
		trustCh <- exchangeResult{m, err}
	}()

	// Wait for the china result (bounded by chinaCtx timeout).
	chinaRes := <-chinaCh

	// Deterministic decision: if china has a CN address, return it.
	if chinaRes.err == nil && chinaIsCN(chinaRes.msg, cn) {
		return chinaRes.msg, nil
	}

	// Fall back to trust — await it unconditionally.
	trustRes := <-trustCh
	if trustRes.err != nil {
		return nil, trustRes.err
	}
	return trustRes.msg, nil
}
