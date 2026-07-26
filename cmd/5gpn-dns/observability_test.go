package main

import (
	"bytes"
	"context"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
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
	h.stats = newStatsCounters()

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
	h.stats = newStatsCounters()

	q := dns.Question{Name: "obs.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("obs.test.", dns.TypeA)
	h.resolve(context.Background(), q, req)

	if _, _, n := h.stats.chinaLatency.stats(); n < 1 {
		t.Errorf("china latency samples = %d, want >=1", n)
	}
	if _, _, n := h.stats.trustLatency.stats(); n < 1 {
		t.Errorf("trust latency samples = %d, want >=1", n)
	}

	c := NewController(func() error { return nil }, h.stats, nil, nil)
	_ = c.Stats() // must not panic; avg may be ~0 with a no-delay fake exchanger
}

// A failed exchange is NOT a latency sample. Timing failures lets a 5s timeout
// and a ~0ms circuit-breaker fast-fail land in the same mean, so an unhealthy
// group can display a lower average than a healthy one; and a trust exchange
// aborted by the china-CN-win cancellation would record "how long until china
// answered" as trust's round trip.
func TestUpstreamLatencyExcludesFailedExchanges(t *testing.T) {
	cn := loadTestChnroute(t)
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn("obs.test"), dns.TypeA)

	t.Run("errored leg records no sample", func(t *testing.T) {
		s := newStatsCounters()
		china := &fakeExchanger{err: errors.New("boom")}
		trust := &fakeExchanger{reply: buildMsg("obs.test", "9.9.9.9")}
		if _, err := Arbitrate(context.Background(), q, china, trust, cn, s); err != nil {
			t.Fatalf("Arbitrate: %v", err)
		}
		if _, _, n := s.chinaLatency.stats(); n != 0 {
			t.Errorf("china latency samples = %d, want 0 (exchange failed)", n)
		}
		if got := s.chinaErr.Load(); got != 1 {
			t.Errorf("chinaErr = %d, want 1 — health is still counted", got)
		}
		if _, _, n := s.trustLatency.stats(); n != 1 {
			t.Errorf("trust latency samples = %d, want 1 (exchange succeeded)", n)
		}
	})

	t.Run("trust aborted by a china CN win records no sample", func(t *testing.T) {
		s := newStatsCounters()
		china := &fakeExchanger{reply: buildMsg("obs.test", "1.2.3.4")} // CN → china wins
		// Outlives the china win, so the deferred cancel aborts it mid-flight.
		trust := &ctxAwareExchanger{delay: 2 * time.Second, reply: buildMsg("obs.test", "9.9.9.9")}
		if _, err := Arbitrate(context.Background(), q, china, trust, cn, s); err != nil {
			t.Fatalf("Arbitrate: %v", err)
		}
		if _, _, n := s.chinaLatency.stats(); n != 1 {
			t.Errorf("china latency samples = %d, want 1", n)
		}
		// Wait for the abandoned goroutine to unwind before asserting on it.
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) && trust.finished.Load() == 0 {
			time.Sleep(time.Millisecond)
		}
		if trust.finished.Load() == 0 {
			t.Fatal("trust exchange never returned; cancellation did not propagate")
		}
		if _, _, n := s.trustLatency.stats(); n != 0 {
			t.Errorf("trust latency samples = %d, want 0 — a cancelled dial is not a latency sample", n)
		}
	})
}

// ctxAwareExchanger blocks until its delay elapses or ctx is cancelled,
// modelling an upstream that is still dialing when arbitration abandons it.
type ctxAwareExchanger struct {
	delay    time.Duration
	reply    *dns.Msg
	finished atomic.Uint32
}

func (e *ctxAwareExchanger) Exchange(ctx context.Context, _ *dns.Msg) (*dns.Msg, error) {
	defer e.finished.Store(1)
	select {
	case <-time.After(e.delay):
		return e.reply.Copy(), nil
	case <-ctx.Done():
		return nil, ctx.Err()
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
