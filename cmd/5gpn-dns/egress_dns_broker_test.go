package main

import (
	"context"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/miekg/dns"
)

type brokerFakeExchanger struct {
	mu    sync.Mutex
	resp  *dns.Msg
	calls int
}

func (f *brokerFakeExchanger) Exchange(_ context.Context, m *dns.Msg) (*dns.Msg, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	out := f.resp.Copy()
	out.Id = m.Id
	return out, nil
}

func (f *brokerFakeExchanger) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func mkA(t *testing.T, name, ip string) *dns.Msg {
	t.Helper()
	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(name), dns.TypeA)
	m.Rcode = dns.RcodeSuccess
	m.RecursionAvailable = true
	m.Answer = append(m.Answer, &dns.A{
		Hdr: dns.RR_Header{Name: dns.Fqdn(name), Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 300},
		A:   net.ParseIP(ip).To4(),
	})
	return m
}

func exchangeUDP(t *testing.T, addr, name string) *dns.Msg {
	t.Helper()
	c := &dns.Client{Timeout: 2 * time.Second}
	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(name), dns.TypeA)
	resp, _, err := c.Exchange(m, addr)
	if err != nil {
		t.Fatalf("UDP exchange: %v", err)
	}
	return resp
}

func TestEgressDNSBroker_RejectsNonLoopback(t *testing.T) {
	b := NewEgressDNSBroker("0.0.0.0:0", nil)
	if err := b.Start(); err == nil {
		t.Fatal("Start must reject a non-loopback address")
	}
}

func TestEgressDNSBroker_UDPTCPParity(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.7")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())

	udp := exchangeUDP(t, b.UDPAddr().String(), "example.com")
	c := &dns.Client{Net: "tcp", Timeout: 2 * time.Second}
	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	tcp, _, err := c.Exchange(q, b.TCPAddr().String())
	if err != nil {
		t.Fatalf("TCP exchange: %v", err)
	}
	if udp.Rcode != tcp.Rcode || len(udp.Answer) != len(tcp.Answer) {
		t.Fatalf("UDP/TCP mismatch: udp=%v tcp=%v", udp, tcp)
	}
}

func TestEgressDNSBroker_MalformedQuestionIsFormerr(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.7")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	w := &captureDNSWriter{}
	b.ServeDNS(w, new(dns.Msg))
	if w.msg == nil || w.msg.Rcode != dns.RcodeFormatError {
		t.Fatalf("rcode=%v, want FORMERR", w.msg)
	}
}

func TestEgressDNSBroker_ShutdownIsIdempotent(t *testing.T) {
	b := NewEgressDNSBroker("127.0.0.1:0", nil)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	b.Shutdown(context.Background())
	b.Shutdown(context.Background())
}

// mkAAAA builds an upstream reply that DOES carry an IPv6 answer, so the tests
// below prove the broker suppresses it rather than merely never receiving one.
func mkAAAA(t *testing.T, name, ip string) *dns.Msg {
	t.Helper()
	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(name), dns.TypeAAAA)
	m.Rcode = dns.RcodeSuccess
	m.RecursionAvailable = true
	m.Answer = append(m.Answer, &dns.AAAA{
		Hdr:  dns.RR_Header{Name: dns.Fqdn(name), Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 300},
		AAAA: net.ParseIP(ip).To16(),
	})
	return m
}

func exchangeUDPType(t *testing.T, addr, name string, qtype uint16) *dns.Msg {
	t.Helper()
	c := &dns.Client{Timeout: 2 * time.Second}
	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(name), qtype)
	resp, _, err := c.Exchange(m, addr)
	if err != nil {
		t.Fatalf("UDP exchange: %v", err)
	}
	return resp
}

// The gateway is IPv4-only, and mihomo v1.19.28's Resolver.LookupIP fires an
// AAAA query for every sniffed origin unconditionally. If the broker forwarded
// it, mihomo would learn real IPv6 addresses and could pick an IPv6 egress whose
// TCP dial SUCCEEDS -- so no dual-stack fallback fires -- while the destination
// refuses the datacenter v6 prefix at the application layer. Not consulting the
// upstream at all is the property that makes that impossible.
func TestEgressDNSBroker_AAAAIsSyntheticNODATA(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkAAAA(t, "example.com", "2001:db8::1")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())

	resp := exchangeUDPType(t, b.UDPAddr().String(), "example.com", dns.TypeAAAA)
	if resp.Rcode != dns.RcodeSuccess {
		t.Fatalf("rcode=%s, want NOERROR (NODATA, not an error)", dns.RcodeToString[resp.Rcode])
	}
	if len(resp.Answer) != 0 {
		t.Fatalf("AAAA answer must be empty, got %v", resp.Answer)
	}
	if !resp.RecursionAvailable {
		t.Fatal("RecursionAvailable must be set")
	}
	if len(resp.Ns) != 1 {
		t.Fatalf("want exactly one authority RR (the synthetic SOA), got %v", resp.Ns)
	}
	if _, ok := resp.Ns[0].(*dns.SOA); !ok {
		t.Fatalf("authority RR = %T, want *dns.SOA so mihomo can negatively cache it", resp.Ns[0])
	}
	if n := fake.callCount(); n != 0 {
		t.Fatalf("upstream consulted %d time(s); the broker must never ask for AAAA at all", n)
	}
}

// TCP must not be a way around the guard: mihomo retries over TCP on truncation.
func TestEgressDNSBroker_AAAABlockedOverTCP(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkAAAA(t, "example.com", "2001:db8::1")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())

	c := &dns.Client{Net: "tcp", Timeout: 2 * time.Second}
	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeAAAA)
	resp, _, err := c.Exchange(q, b.TCPAddr().String())
	if err != nil {
		t.Fatalf("TCP exchange: %v", err)
	}
	if resp.Rcode != dns.RcodeSuccess || len(resp.Answer) != 0 {
		t.Fatalf("TCP AAAA must also be synthetic NODATA, got rcode=%s answer=%v",
			dns.RcodeToString[resp.Rcode], resp.Answer)
	}
	if n := fake.callCount(); n != 0 {
		t.Fatalf("upstream consulted %d time(s) over TCP", n)
	}
}

// The AAAA decision is policy, not a consequence of upstream availability: it
// must be reached before the nil-upstream SERVFAIL guard. Locking the order
// keeps a later refactor from reintroducing the leak for a configured broker.
func TestEgressDNSBroker_AAAABlockedBeforeUpstreamCheck(t *testing.T) {
	b := NewEgressDNSBroker("127.0.0.1:0", nil)
	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeAAAA)
	w := &captureDNSWriter{}
	b.ServeDNS(w, q)
	if w.msg == nil || w.msg.Rcode != dns.RcodeSuccess || len(w.msg.Answer) != 0 {
		t.Fatalf("nil-upstream AAAA must still be synthetic NODATA, got %v", w.msg)
	}
}

// A must keep flowing to the selected group untouched -- the guard is scoped to
// AAAA, not a general filter that would break origin resolution.
func TestEgressDNSBroker_AForwardsUnchanged(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.7")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())

	resp := exchangeUDPType(t, b.UDPAddr().String(), "example.com", dns.TypeA)
	if len(resp.Answer) != 1 {
		t.Fatalf("A answer = %v, want the upstream record forwarded verbatim", resp.Answer)
	}
	if a, ok := resp.Answer[0].(*dns.A); !ok || !a.A.Equal(net.ParseIP("203.0.113.7")) {
		t.Fatalf("A answer = %v, want 203.0.113.7", resp.Answer[0])
	}
	if n := fake.callCount(); n != 1 {
		t.Fatalf("upstream consulted %d time(s), want exactly 1", n)
	}
}

// Both resolver boundaries 5gpn owns must hand out the SAME synthetic answer, so
// a client asking over DoT and mihomo asking over the broker cannot disagree
// about whether a name has IPv6.
func TestEgressDNSBrokerAAAAMatchesClientHandler(t *testing.T) {
	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeAAAA)

	h := &Handler{}
	client := h.soaReply(q)

	b := NewEgressDNSBroker("127.0.0.1:0", &brokerFakeExchanger{resp: mkAAAA(t, "example.com", "2001:db8::1")})
	w := &captureDNSWriter{}
	b.ServeDNS(w, q)

	if w.msg == nil {
		t.Fatal("broker wrote no reply")
	}
	if client.Rcode != w.msg.Rcode || len(client.Answer) != len(w.msg.Answer) || len(client.Ns) != len(w.msg.Ns) {
		t.Fatalf("shape mismatch: client=%v broker=%v", client, w.msg)
	}
	if client.Ns[0].String() != w.msg.Ns[0].String() {
		t.Fatalf("synthetic SOA differs:\n client=%s\n broker=%s", client.Ns[0], w.msg.Ns[0])
	}
}

type captureDNSWriter struct{ msg *dns.Msg }

func (w *captureDNSWriter) LocalAddr() net.Addr         { return &net.UDPAddr{} }
func (w *captureDNSWriter) RemoteAddr() net.Addr        { return &net.UDPAddr{} }
func (w *captureDNSWriter) WriteMsg(m *dns.Msg) error   { w.msg = m; return nil }
func (w *captureDNSWriter) Write(p []byte) (int, error) { return len(p), nil }
func (w *captureDNSWriter) Close() error                { return nil }
func (w *captureDNSWriter) TsigStatus() error           { return nil }
func (w *captureDNSWriter) TsigTimersOnly(bool)         {}
func (w *captureDNSWriter) Hijack()                     {}

func TestEgressDNSBroker_LogsNoQueryData(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkA(t, "secret.example", "203.0.113.7")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	var logs strings.Builder
	b.logf = func(format string, args ...interface{}) { logs.WriteString(format) }
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())
	_ = exchangeUDP(t, b.UDPAddr().String(), "secret.example")
	if strings.Contains(logs.String(), "secret.example") {
		t.Fatal("broker log leaked a query name")
	}
}
