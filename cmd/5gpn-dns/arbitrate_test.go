package main

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// fakeExchanger is a test-only Exchanger that returns a canned reply after an
// optional delay. It lets tests inject arbitrary timing without real network I/O.
type fakeExchanger struct {
	reply *dns.Msg
	err   error
	delay time.Duration
}

func (f *fakeExchanger) Exchange(ctx context.Context, _ *dns.Msg) (*dns.Msg, error) {
	if f.delay > 0 {
		select {
		case <-time.After(f.delay):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return f.reply, f.err
}

// buildMsg constructs a minimal A-record reply for testing.
// Pass ip="" to produce a NODATA reply (no A records).
func buildMsg(name, ip string) *dns.Msg {
	m := new(dns.Msg)
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(name), dns.TypeA)
	m.SetReply(q)
	m.RecursionAvailable = true
	if ip != "" {
		m.Answer = []dns.RR{&dns.A{
			Hdr: dns.RR_Header{
				Name:   dns.Fqdn(name),
				Rrtype: dns.TypeA,
				Class:  dns.ClassINET,
				Ttl:    60,
			},
			A: net.ParseIP(ip).To4(),
		}}
	}
	return m
}

// loadTestChnroute writes "1.0.0.0/8\n" to a temp file and loads it.
// 1.0.0.0/8 covers 1.2.3.4; 8.8.8.8 and 9.9.9.9 are outside.
func loadTestChnroute(t *testing.T) *Chnroute {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "cn.txt")
	if err := os.WriteFile(p, []byte("1.0.0.0/8\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cn, err := LoadChnroute(p)
	if err != nil {
		t.Fatal(err)
	}
	return cn
}

// TestArbitrateUpstreamHealthCounters verifies Arbitrate records china/trust
// exchange outcomes: china is always awaited (always counted); trust is counted
// only when actually consulted (i.e. when china is not a CN answer).
func TestArbitrateUpstreamHealthCounters(t *testing.T) {
	cn := loadTestChnroute(t)
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn("x.test"), dns.TypeA)

	t.Run("china CN wins → trust not counted", func(t *testing.T) {
		s := &statsCounters{}
		china := &fakeExchanger{reply: buildMsg("x.test", "1.2.3.4")} // CN
		trust := &fakeExchanger{reply: buildMsg("x.test", "9.9.9.9")}
		if _, err := Arbitrate(context.Background(), q, china, trust, cn, s); err != nil {
			t.Fatalf("Arbitrate: %v", err)
		}
		if got := s.chinaOK.Load(); got != 1 {
			t.Errorf("chinaOK = %d, want 1", got)
		}
		if got := s.trustOK.Load() + s.trustErr.Load(); got != 0 {
			t.Errorf("trust counted %d times, want 0 (not consulted)", got)
		}
	})

	t.Run("china foreign → both counted", func(t *testing.T) {
		s := &statsCounters{}
		china := &fakeExchanger{reply: buildMsg("x.test", "8.8.8.8")} // foreign
		trust := &fakeExchanger{reply: buildMsg("x.test", "9.9.9.9")}
		if _, err := Arbitrate(context.Background(), q, china, trust, cn, s); err != nil {
			t.Fatalf("Arbitrate: %v", err)
		}
		if s.chinaOK.Load() != 1 || s.trustOK.Load() != 1 {
			t.Errorf("chinaOK=%d trustOK=%d, want 1/1", s.chinaOK.Load(), s.trustOK.Load())
		}
	})

	t.Run("china error → chinaErr, trust consulted", func(t *testing.T) {
		s := &statsCounters{}
		china := &fakeExchanger{err: errors.New("boom")}
		trust := &fakeExchanger{reply: buildMsg("x.test", "9.9.9.9")}
		if _, err := Arbitrate(context.Background(), q, china, trust, cn, s); err != nil {
			t.Fatalf("Arbitrate: %v", err)
		}
		if s.chinaErr.Load() != 1 || s.chinaOK.Load() != 0 {
			t.Errorf("chinaErr=%d chinaOK=%d, want 1/0", s.chinaErr.Load(), s.chinaOK.Load())
		}
		if s.trustOK.Load() != 1 {
			t.Errorf("trustOK = %d, want 1", s.trustOK.Load())
		}
	})

	t.Run("nil stats does not panic", func(t *testing.T) {
		china := &fakeExchanger{reply: buildMsg("x.test", "1.2.3.4")}
		trust := &fakeExchanger{reply: buildMsg("x.test", "9.9.9.9")}
		if _, err := Arbitrate(context.Background(), q, china, trust, cn, nil); err != nil {
			t.Fatalf("Arbitrate with nil stats: %v", err)
		}
	})
}

// TestArbitrateDeterminism verifies that Arbitrate always returns the china reply when chinaIsCN,
// regardless of which upstream is faster (the anti-first-response guarantee).
func TestArbitrateDeterminism(t *testing.T) {
	cn := loadTestChnroute(t)

	chinaMsg := buildMsg("example.com", "1.2.3.4")   // ∈ cn
	trustMsg := buildMsg("example.com", "9.9.9.9")   // ∉ cn
	foreignMsg := buildMsg("example.com", "8.8.8.8") // ∉ cn

	const timeout = 500 * time.Millisecond
	const slowDelay = 200 * time.Millisecond

	tests := []struct {
		name       string
		china      Exchanger
		trust      Exchanger
		wantIP     string // empty = don't check specific IP, just "not error"
		wantSource string // "china" or "trust" — for description
	}{
		{
			// Core case: china is CN, both are fast. Must return china.
			name:       "china_CN_both_fast_returns_china",
			china:      &fakeExchanger{reply: chinaMsg},
			trust:      &fakeExchanger{reply: trustMsg},
			wantIP:     "1.2.3.4",
			wantSource: "china",
		},
		{
			// THE DETERMINISM CASE: china is CN but SLOW (200ms), trust is instant.
			// A first-response algorithm would return trust (9.9.9.9).
			// Correct arbitration MUST still return china (1.2.3.4).
			name:       "china_CN_slow_trust_fast_still_returns_china",
			china:      &fakeExchanger{reply: chinaMsg, delay: slowDelay},
			trust:      &fakeExchanger{reply: trustMsg},
			wantIP:     "1.2.3.4",
			wantSource: "china",
		},
		{
			// china returns a foreign IP → fall back to trust.
			name:       "china_foreign_returns_trust",
			china:      &fakeExchanger{reply: foreignMsg},
			trust:      &fakeExchanger{reply: trustMsg},
			wantIP:     "9.9.9.9",
			wantSource: "trust",
		},
		{
			// china errors → fall back to trust.
			name:       "china_error_returns_trust",
			china:      &fakeExchanger{err: errors.New("upstream unreachable")},
			trust:      &fakeExchanger{reply: trustMsg},
			wantIP:     "9.9.9.9",
			wantSource: "trust",
		},
		{
			// china NODATA (no A records) → fall back to trust.
			name:       "china_NODATA_returns_trust",
			china:      &fakeExchanger{reply: buildMsg("example.com", "")},
			trust:      &fakeExchanger{reply: trustMsg},
			wantIP:     "9.9.9.9",
			wantSource: "trust",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			q := new(dns.Msg)
			q.SetQuestion("example.com.", dns.TypeA)

			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			got, err := Arbitrate(ctx, q, tc.china, tc.trust, cn, nil)
			if err != nil {
				t.Fatalf("Arbitrate returned error: %v", err)
			}
			if got == nil {
				t.Fatal("Arbitrate returned nil message")
			}

			// Extract the first A record IP from the result.
			var gotIP string
			for _, rr := range got.Answer {
				if a, ok := rr.(*dns.A); ok {
					gotIP = a.A.String()
					break
				}
			}

			if gotIP != tc.wantIP {
				t.Errorf("case %q: got IP %q, want %q (expected %s reply)",
					tc.name, gotIP, tc.wantIP, tc.wantSource)
			}
		})
	}
}

// TestArbitrateTimeout verifies that when china times out AND trust has a reply,
// Arbitrate returns the trust reply (not an error).
func TestArbitrateTimeout(t *testing.T) {
	cn := loadTestChnroute(t)
	trustMsg := buildMsg("example.com", "9.9.9.9")

	// china takes longer than the timeout.
	china := &fakeExchanger{reply: buildMsg("example.com", "1.2.3.4"), delay: 2 * time.Second}
	trust := &fakeExchanger{reply: trustMsg}

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	got, err := Arbitrate(ctx, q, china, trust, cn, nil)
	if err != nil {
		t.Fatalf("Arbitrate returned error on china timeout: %v", err)
	}
	var gotIP string
	for _, rr := range got.Answer {
		if a, ok := rr.(*dns.A); ok {
			gotIP = a.A.String()
			break
		}
	}
	if gotIP != "9.9.9.9" {
		t.Errorf("expected trust reply (9.9.9.9) after china timeout, got %q", gotIP)
	}
}

// blockingExchanger blocks in Exchange until ctx is cancelled, signalling entry
// and exit over channels. Used to prove Arbitrate releases the abandoned
// upstream instead of leaking its goroutine.
type blockingExchanger struct {
	entered, exited chan struct{}
}

func (b *blockingExchanger) Exchange(ctx context.Context, _ *dns.Msg) (*dns.Msg, error) {
	close(b.entered)
	<-ctx.Done()
	close(b.exited)
	return nil, ctx.Err()
}

// TestArbitrateReleasesAbandonedUpstream proves that when china wins (a CN
// answer), Arbitrate releases the still-running trust exchange as it returns —
// even when the caller's ctx is never cancelled — so a slow/hung trust upstream
// cannot accumulate goroutines under load. Arbitrate must self-cancel rather
// than rely on the caller to tear down the abandoned upstream.
func TestArbitrateReleasesAbandonedUpstream(t *testing.T) {
	cn := loadTestChnroute(t)
	q := new(dns.Msg)
	q.SetQuestion("x.test.", dns.TypeA)

	china := &fakeExchanger{reply: buildMsg("x.test", "1.2.3.4")} // CN, instant win
	entered := make(chan struct{})
	exited := make(chan struct{})
	trust := &blockingExchanger{entered: entered, exited: exited}

	// context.Background(): the caller provides NO deadline and NO cancel. If
	// Arbitrate relied on the caller to release abandoned upstreams, the trust
	// goroutine would block here forever.
	reply, err := Arbitrate(context.Background(), q, china, trust, cn, nil)
	if err != nil {
		t.Fatalf("Arbitrate: %v", err)
	}
	if len(reply.Answer) == 0 {
		t.Fatal("expected china CN answer")
	}

	<-entered // trust goroutine is running
	select {
	case <-exited: // released — no leak
	case <-time.After(2 * time.Second):
		t.Fatal("LEAK: abandoned trust goroutine not released after Arbitrate returned")
	}
}
