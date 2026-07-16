package main

import (
	"bytes"
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// #12: cacheGet bumps the hit/miss observability counters, and Controller.Stats
// exposes them.
func TestCacheHitMissCounters(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("obs.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("obs.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	h.stats = &statsCounters{}

	q := dns.Question{Name: "obs.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("obs.test.", dns.TypeA)

	h.resolve(context.Background(), q, req) // miss → populates cache
	h.resolve(context.Background(), q, req) // hit

	if got := h.stats.cacheMisses.Load(); got != 1 {
		t.Errorf("cacheMisses = %d, want 1", got)
	}
	if got := h.stats.cacheHits.Load(); got != 1 {
		t.Errorf("cacheHits = %d, want 1", got)
	}

	c := NewController(func() error { return nil }, h.stats, h.Cache.Len, nil)
	st := c.Stats()
	if st.CacheHits != 1 || st.CacheMisses != 1 {
		t.Errorf("Stats cache = hits %d misses %d, want 1/1", st.CacheHits, st.CacheMisses)
	}
}

// #12: Arbitrate records per-group upstream latency samples for both legs it
// launches, and Stats derives an average.
func TestUpstreamLatencyRecorded(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("obs.test", "9.9.9.9")} // foreign → trust consulted
	trust := &fakeExchanger{reply: makeAMsg("obs.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	h.stats = &statsCounters{}

	q := dns.Question{Name: "obs.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("obs.test.", dns.TypeA)
	h.resolve(context.Background(), q, req)

	if got := h.stats.chinaLatCount.Load(); got < 1 {
		t.Errorf("chinaLatCount = %d, want >=1", got)
	}
	if got := h.stats.trustLatCount.Load(); got < 1 {
		t.Errorf("trustLatCount = %d, want >=1", got)
	}

	c := NewController(func() error { return nil }, h.stats, nil, nil)
	_ = c.Stats() // must not panic; avg may be ~0 with a no-delay fake exchanger
}

func TestAvgMs(t *testing.T) {
	if got := avgMs(0, 0); got != 0 {
		t.Errorf("avgMs(0,0) = %v, want 0", got)
	}
	if got := avgMs(3_000_000, 3); got != 1.0 { // 3ms over 3 samples = 1ms
		t.Errorf("avgMs(3e6,3) = %v, want 1.0", got)
	}
}

// #6: a failed subscription fetch is logged to the daemon's log sink (journald
// in prod) — the silent-failure class this subsystem exists to survive.
func TestSubscriptionFailureIsLogged(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr) // restore the default sink

	m, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), t.TempDir(), func() error { return nil }, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{{ID: "f1", Category: "direct", Name: "f1", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour}}

	res := m.updateOne(context.Background(), "f1")
	if res.OK {
		t.Fatal("expected the 500 fetch to fail")
	}
	if !strings.Contains(buf.String(), "update FAILED") || !strings.Contains(buf.String(), "f1") {
		t.Errorf("expected a logged failure for f1, got log: %q", buf.String())
	}
}
