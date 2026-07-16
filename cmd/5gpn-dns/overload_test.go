package main

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// #1: when the in-flight semaphore is full, a new query is shed with REFUSED
// (cheap) instead of running a full resolve — bounding concurrent work under
// overload. A freed slot resolves normally.
func TestServeDNSShedsWhenInflightFull(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("x.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("x.test", "1.2.3.4")}
	h := newTestHandler(t, china, trust)
	h.sem = make(chan struct{}, 1)

	req := new(dns.Msg)
	req.SetQuestion("x.test.", dns.TypeA)

	// Occupy the only slot → the next query must be REFUSED.
	h.sem <- struct{}{}
	w := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}}
	h.ServeDNS(w, req)
	if w.written == nil || w.written.Rcode != dns.RcodeRefused {
		t.Fatalf("want REFUSED when in-flight is full, got %+v", w.written)
	}

	// Free the slot → the next query resolves normally, and the slot is
	// released again afterward (defer in serveContext).
	<-h.sem
	w2 := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 2}}
	h.ServeDNS(w2, req)
	if w2.written == nil || w2.written.Rcode != dns.RcodeSuccess {
		t.Fatalf("want success when a slot is free, got %+v", w2.written)
	}
	if len(h.sem) != 0 {
		t.Errorf("semaphore slot not released after query: len=%d", len(h.sem))
	}
}

// #1: a nil semaphore (DNS_MAX_INFLIGHT=0 / test Handler) disables shedding —
// every query resolves.
func TestServeDNSNilSemDisablesShedding(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("x.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("x.test", "1.2.3.4")}
	h := newTestHandler(t, china, trust) // no sem
	req := new(dns.Msg)
	req.SetQuestion("x.test.", dns.TypeA)
	w := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}}
	h.ServeDNS(w, req)
	if w.written == nil || w.written.Rcode != dns.RcodeSuccess {
		t.Fatalf("nil sem should not shed, got %+v", w.written)
	}
}

// #0: serveContext honours the parent context's cancellation (the DoH path
// threads r.Context()), so a disconnected client's query aborts fast instead of
// running the full upstream fan-out to the per-query deadline.
func TestServeContextHonorsParentCancellation(t *testing.T) {
	// Upstreams that would take far longer than we're willing to wait — the
	// cancelled parent must short-circuit them.
	china := &fakeExchanger{reply: makeAMsg("x.test", "1.2.3.4"), delay: 3 * time.Second}
	trust := &fakeExchanger{reply: makeAMsg("x.test", "1.2.3.4"), delay: 3 * time.Second}
	h := newTestHandler(t, china, trust)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled, as if the client hung up

	req := new(dns.Msg)
	req.SetQuestion("x.test.", dns.TypeA)
	w := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}}

	start := time.Now()
	h.serveContext(ctx, w, req)
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Errorf("serveContext ignored parent cancellation: took %v (want fast abort)", elapsed)
	}
	if w.written == nil || w.written.Rcode != dns.RcodeServerFailure {
		t.Errorf("want SERVFAIL on a cancelled parent, got %+v", w.written)
	}
}
