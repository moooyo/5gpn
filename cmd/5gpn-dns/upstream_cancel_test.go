package main

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// startLocalUDPDNS runs a real miekg/dns UDP server on 127.0.0.1:0 and returns
// its address. Unlike the fakeExchanger-based tests, exercising the real
// group.Exchange path (goroutine fan-out, ctx cancellation, breaker recording)
// requires an actual socket on the other end.
func startLocalUDPDNS(t *testing.T, handler dns.HandlerFunc) string {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &dns.Server{PacketConn: pc, Handler: handler}
	go func() { _ = srv.ActivateAndServe() }()
	t.Cleanup(func() { _ = srv.Shutdown() })
	return pc.LocalAddr().String()
}

// answerA replies to any A query with the given IP after an optional delay.
func answerA(ip string, delay time.Duration) dns.HandlerFunc {
	return func(w dns.ResponseWriter, r *dns.Msg) {
		if delay > 0 {
			time.Sleep(delay)
		}
		m := new(dns.Msg)
		m.SetReply(r)
		m.Answer = []dns.RR{&dns.A{
			Hdr: dns.RR_Header{Name: r.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
			A:   net.ParseIP(ip).To4(),
		}}
		_ = w.WriteMsg(m)
	}
}

// holdTCPListener accepts TCP connections and holds them open without ever
// completing a TLS handshake — from a tcp-tls group's point of view this is an
// upstream whose dial (TCP+TLS handshake) is still in flight, which is exactly
// where a real trust DoT exchange sits when a fast china UDP answer wins the
// arbitration and cancels it (miekg's ExchangeWithConnContext only honours the
// ctx deadline; cancellation is only observed by DialContext).
func holdTCPListener(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		var held []net.Conn
		defer func() {
			for _, c := range held {
				_ = c.Close()
			}
		}()
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			held = append(held, c) // never speak TLS; the client handshake blocks
			select {
			case <-done:
				return
			default:
			}
		}
	}()
	t.Cleanup(func() { close(done); _ = ln.Close() })
	return ln.Addr().String()
}

// The combination bug this locks against: Arbitrate cancels the abandoned
// trust exchange on every china-CN win, and group.Exchange used to record that
// cancellation as a breaker failure — so breakerThreshold consecutive CN
// answers opened the trust breaker even though the trust upstream was healthy,
// SERVFAILing uncached foreign domains and all non-A forwards for the cooldown
// (and the half-open probe could be re-cancelled the same way, latching it).
// Uses real groups, real breakers, and real sockets end-to-end through
// Arbitrate — the isolated fakeExchanger tests cannot see this interaction.
// The trust side is tcp-tls against a handshake-holding listener because that
// is the only phase where miekg observes cancellation (see holdTCPListener).
func TestArbitrateChinaWinsDoNotTripTrustBreaker(t *testing.T) {
	cn := loadTestChnroute(t) // 1.0.0.0/8 is CN

	chinaAddr := startLocalUDPDNS(t, answerA("1.2.3.4", 0)) // fast CN answer
	trustAddr := holdTCPListener(t)                         // trust: forever mid-handshake

	china := NewUDPGroup([]string{chinaAddr}, false)
	trust := NewTrustGroup([]TrustEntry{{ServerName: "trust.test", DialAddr: trustAddr}})

	q := new(dns.Msg)
	q.SetQuestion("cn-domain.example.", dns.TypeA)

	for i := 0; i < breakerThreshold+3; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		resp, err := Arbitrate(ctx, q, china, trust, cn, &statsCounters{})
		cancel()
		if err != nil {
			t.Fatalf("round %d: Arbitrate failed: %v", i, err)
		}
		if len(resp.Answer) == 0 {
			t.Fatalf("round %d: expected the china CN answer", i)
		}
	}

	// Let the abandoned trust goroutines observe their cancellation and finish.
	time.Sleep(300 * time.Millisecond)

	tg := trust.(*group)
	if !tg.breaker.allow() {
		t.Fatal("trust breaker opened from caller-side cancellations: CN-heavy traffic must not poison the trust circuit")
	}

	// And a foreign lookup right after the CN streak must reach the dial (i.e.
	// fail on the deadline against our handshake-holding listener) — never
	// fast-fail with the breaker's "circuit open".
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err := trust.Exchange(ctx, q); err == nil {
		t.Fatal("expected a deadline error against the handshake-holding listener")
	} else if strings.Contains(err.Error(), "circuit open") {
		t.Fatalf("trust breaker must be closed after the CN streak, got: %v", err)
	}
}

// A pre-cancelled context must not feed the breaker either (the DoH path
// cancels both groups when the HTTP client disconnects).
func TestCancelledExchangeDoesNotRecordBreakerFailure(t *testing.T) {
	addr := startLocalUDPDNS(t, answerA("1.2.3.4", 0))
	g := NewUDPGroup([]string{addr}, false).(*group)

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled

	for i := 0; i < breakerThreshold+2; i++ {
		if _, err := g.Exchange(ctx, q); err == nil {
			t.Fatal("expected an error from a cancelled exchange")
		}
	}
	if !g.breaker.allow() {
		t.Fatal("cancelled exchanges must not open the breaker")
	}
}

// Deadline expiry is a genuine health signal (the upstream had the full budget
// and did not answer) and must still open the breaker — the Canceled carve-out
// must not swallow it.
func TestDeadlineExpiryStillRecordsBreakerFailure(t *testing.T) {
	addr := startLocalUDPDNS(t, answerA("1.2.3.4", 500*time.Millisecond)) // slower than the deadline
	g := NewUDPGroup([]string{addr}, false).(*group)

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)

	for i := 0; i < breakerThreshold; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		_, err := g.Exchange(ctx, q)
		cancel()
		if err == nil {
			t.Fatal("expected a deadline error")
		}
	}
	if g.breaker.allow() {
		t.Fatal("deadline-expired exchanges must still open the breaker")
	}
}
