package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/miekg/dns"
)

var errUpstreamDown = errors.New("upstream down")

// #3: the breaker opens after breakerThreshold consecutive failures, stays open
// through the cooldown, then half-opens and closes on a success. Driven by an
// injected clock so it's deterministic.
func TestBreakerOpensAndRecovers(t *testing.T) {
	clk := time.Unix(1_700_000_000, 0)
	b := &breaker{now: func() time.Time { return clk }}

	for i := 0; i < breakerThreshold-1; i++ {
		b.record(false)
	}
	if !b.allow() {
		t.Fatal("breaker should still be closed below the threshold")
	}
	b.record(false) // hits the threshold
	if b.allow() {
		t.Fatal("breaker should be open at the failure threshold")
	}
	clk = clk.Add(breakerCooldown - time.Second)
	if b.allow() {
		t.Fatal("breaker should stay open within the cooldown")
	}
	clk = clk.Add(2 * time.Second) // cooldown elapsed
	if !b.allow() {
		t.Fatal("breaker should allow a half-open probe after cooldown")
	}
	if b.allow() {
		t.Fatal("breaker must allow only one concurrent half-open probe")
	}
	b.record(true) // probe succeeds
	if !b.allow() {
		t.Fatal("breaker should be closed after a success")
	}
}

func TestBreakerCanceledHalfOpenProbeCanBeRetried(t *testing.T) {
	clk := time.Unix(1_700_000_000, 0)
	b := &breaker{now: func() time.Time { return clk }}
	for i := 0; i < breakerThreshold; i++ {
		b.record(false)
	}
	clk = clk.Add(breakerCooldown)
	if !b.allow() {
		t.Fatal("expected initial half-open probe")
	}
	b.recordCanceled()
	if !b.allow() {
		t.Fatal("caller cancellation must release the half-open probe slot")
	}
}

// #3: a group with a live breaker fails fast once open. Uses a stub Exchanger to
// avoid real dials — here we drive the breaker directly and assert Exchange
// short-circuits without consulting members.
func TestGroupExchangeShortCircuitsWhenBreakerOpen(t *testing.T) {
	clk := time.Unix(1_700_000_000, 0)
	g := &group{members: nil, label: "china", breaker: &breaker{now: func() time.Time { return clk }}}
	// Force the breaker open.
	for i := 0; i < breakerThreshold; i++ {
		g.breaker.record(false)
	}
	_, err := g.Exchange(context.Background(), new(dns.Msg))
	if err == nil {
		t.Fatal("expected a fast-fail error while the breaker is open")
	}
}

// #3: on a total upstream outage the resolver serves the last-known (expired)
// answer with a short TTL instead of SERVFAIL, until it ages past staleGrace.
func TestServeStaleOnUpstreamFailure(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("f.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("f.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	clk := time.Unix(1_700_000_000, 0)
	h.Cache.now = func() time.Time { return clk }

	q := dns.Question{Name: "f.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("f.test.", dns.TypeA)

	// 1) success populates the cache (foreign → rewritten to gateway 10.0.0.1).
	resp1 := h.resolve(context.Background(), q, req)
	if ips := collectAIPs(resp1); len(ips) != 1 || ips[0] != "10.0.0.1" {
		t.Fatalf("setup: expected gateway rewrite, got %v", ips)
	}

	// 2) upstreams die; the entry expires but is still within staleGrace.
	china.err, china.reply = errUpstreamDown, nil
	trust.err, trust.reply = errUpstreamDown, nil
	clk = clk.Add(120 * time.Second)

	resp2 := h.resolve(context.Background(), q, req)
	if resp2.Rcode != dns.RcodeSuccess {
		t.Fatalf("serve-stale should return NOERROR, got rcode %d", resp2.Rcode)
	}
	if ips := collectAIPs(resp2); len(ips) != 1 || ips[0] != "10.0.0.1" {
		t.Errorf("serve-stale should return the stale gateway answer, got %v", ips)
	}
	if len(resp2.Answer) > 0 && resp2.Answer[0].Header().Ttl != staleReplyTTLSecs {
		t.Errorf("stale reply TTL = %d, want %d", resp2.Answer[0].Header().Ttl, staleReplyTTLSecs)
	}

	// 3) beyond staleGrace → nothing to serve → SERVFAIL.
	clk = clk.Add(2 * staleGrace)
	resp3 := h.resolve(context.Background(), q, req)
	if resp3.Rcode != dns.RcodeServerFailure {
		t.Errorf("beyond staleGrace should be SERVFAIL, got rcode %d", resp3.Rcode)
	}
}
