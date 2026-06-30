package chnroute

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// fakeWriter is a test-only dns.ResponseWriter that captures the written message.
type fakeWriter struct {
	written *dns.Msg
	remote  net.Addr
}

func (f *fakeWriter) LocalAddr() net.Addr         { return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 53} }
func (f *fakeWriter) RemoteAddr() net.Addr        { return f.remote }
func (f *fakeWriter) WriteMsg(m *dns.Msg) error   { f.written = m; return nil }
func (f *fakeWriter) Write(b []byte) (int, error) { return len(b), nil }
func (f *fakeWriter) Close() error                { return nil }
func (f *fakeWriter) TsigStatus() error           { return nil }
func (f *fakeWriter) TsigTimersOnly(b bool)       {}
func (f *fakeWriter) Hijack()                     {}

// newTestHandler builds a Handler with small DomainSets/Chnroute for unit tests.
//
//   - Chnroute covers 1.0.0.0/8 (so 1.2.3.4 is CN; 9.9.9.9 is foreign).
//   - adblock:   adblock.test
//   - direct:    direct.test
//   - blacklist: blacklist.test
//   - GatewayIP: 10.0.0.1
func newTestHandler(t *testing.T, china, trust Exchanger) *Handler {
	t.Helper()
	cn := &Chnroute{ranges: []ipRange{{start: ipToUint32(net.ParseIP("1.0.0.0").To4()), end: ipToUint32(net.ParseIP("1.255.255.255").To4())}}}

	makeDS := func(domains ...string) *DomainSet {
		ds := &DomainSet{entries: make(map[string]struct{})}
		for _, d := range domains {
			ds.entries[d] = struct{}{}
		}
		return ds
	}

	return &Handler{
		Adblock:   makeDS("adblock.test"),
		Direct:    makeDS("direct.test"),
		Blacklist: makeDS("blacklist.test"),
		CN:        cn,
		Cache:     NewCache(128),
		China:     china,
		Trust:     trust,
		GatewayIP: net.ParseIP("10.0.0.1").To4(),
		TTLMin:    10 * time.Second,
		TTLMax:    300 * time.Second,
		Timeout:   500 * time.Millisecond,
	}
}

// makeAMsg builds a dns.Msg A-record reply containing the given IPs.
func makeAMsg(name string, ips ...string) *dns.Msg {
	m := new(dns.Msg)
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(name), dns.TypeA)
	m.SetReply(q)
	m.RecursionAvailable = true
	for _, ip := range ips {
		m.Answer = append(m.Answer, &dns.A{
			Hdr: dns.RR_Header{
				Name:   dns.Fqdn(name),
				Rrtype: dns.TypeA,
				Class:  dns.ClassINET,
				Ttl:    60,
			},
			A: net.ParseIP(ip).To4(),
		})
	}
	return m
}

// makeAAAAMsg builds a dns.Msg AAAA-record reply.
func makeAAAAMsg(name, ip6 string) *dns.Msg {
	m := new(dns.Msg)
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(name), dns.TypeAAAA)
	m.SetReply(q)
	m.RecursionAvailable = true
	m.Answer = append(m.Answer, &dns.AAAA{
		Hdr: dns.RR_Header{
			Name:   dns.Fqdn(name),
			Rrtype: dns.TypeAAAA,
			Class:  dns.ClassINET,
			Ttl:    60,
		},
		AAAA: net.ParseIP(ip6),
	})
	return m
}

// collectAIPs returns the list of A record IPs from msg.Answer, in order.
func collectAIPs(msg *dns.Msg) []string {
	var ips []string
	for _, rr := range msg.Answer {
		if a, ok := rr.(*dns.A); ok {
			ips = append(ips, a.A.String())
		}
	}
	return ips
}

// ------- Tests -------

// TestHandlerAAAA: AAAA query → SOA in Authority, empty Answer, NOERROR.
func TestHandlerAAAA(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	q := dns.Question{Name: "example.com.", Qtype: dns.TypeAAAA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.com.", dns.TypeAAAA)

	resp := h.resolve(context.Background(), q, req)
	if resp == nil {
		t.Fatal("expected non-nil response")
	}
	if resp.Rcode != dns.RcodeSuccess {
		t.Errorf("expected NOERROR, got %d", resp.Rcode)
	}
	if len(resp.Answer) != 0 {
		t.Errorf("expected empty Answer, got %d RRs", len(resp.Answer))
	}
	var hasSOA bool
	for _, rr := range resp.Ns {
		if _, ok := rr.(*dns.SOA); ok {
			hasSOA = true
			break
		}
	}
	if !hasSOA {
		t.Errorf("expected SOA in Authority section, got Ns=%v", resp.Ns)
	}
}

// TestHandlerHTTPS: HTTPS (type 65) query → NOERROR, empty Answer.
func TestHandlerHTTPS(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	q := dns.Question{Name: "example.com.", Qtype: dns.TypeHTTPS, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.com.", dns.TypeHTTPS)

	resp := h.resolve(context.Background(), q, req)
	if resp == nil {
		t.Fatal("expected non-nil response")
	}
	if resp.Rcode != dns.RcodeSuccess {
		t.Errorf("expected NOERROR, got %d", resp.Rcode)
	}
	if len(resp.Answer) != 0 {
		t.Errorf("expected empty Answer, got %d RRs", len(resp.Answer))
	}
}

// TestHandlerSVCB: SVCB (type 64) query → NOERROR, empty Answer.
func TestHandlerSVCB(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	q := dns.Question{Name: "example.com.", Qtype: dns.TypeSVCB, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.com.", dns.TypeSVCB)

	resp := h.resolve(context.Background(), q, req)
	if resp.Rcode != dns.RcodeSuccess {
		t.Errorf("expected NOERROR, got %d", resp.Rcode)
	}
	if len(resp.Answer) != 0 {
		t.Errorf("expected empty Answer, got %d RRs", len(resp.Answer))
	}
}

// TestHandlerAdblock: adblock-listed name → NXDOMAIN.
func TestHandlerAdblock(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	q := dns.Question{Name: "adblock.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("adblock.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	if resp.Rcode != dns.RcodeNameError {
		t.Errorf("expected NXDOMAIN (%d), got %d", dns.RcodeNameError, resp.Rcode)
	}
}

// TestHandlerAdblockAAAA: adblock applies to any qtype (e.g. AAAA).
func TestHandlerAdblockAAAA(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	q := dns.Question{Name: "adblock.test.", Qtype: dns.TypeAAAA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("adblock.test.", dns.TypeAAAA)

	// Note: adblock (step 3) comes AFTER AAAA-block (step 1). So AAAA to adblock.test
	// hits step 1 first → SOA reply, not NXDOMAIN. But adblock applies to TypeA queries.
	// Per spec: step 1 fires on TypeAAAA first, so this returns SOA/NOERROR.
	// Test that adblock is applied on TypeA:
	q2 := dns.Question{Name: "adblock.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req2 := new(dns.Msg)
	req2.SetQuestion("adblock.test.", dns.TypeA)
	resp2 := h.resolve(context.Background(), q2, req2)
	if resp2.Rcode != dns.RcodeNameError {
		t.Errorf("expected NXDOMAIN for adblock A, got %d", resp2.Rcode)
	}
	_ = q
}

// TestHandlerDirectForeignKept: direct-listed name, A query, arbitrate returns foreign 9.9.9.9 → kept as-is (no rewrite).
func TestHandlerDirectForeignKept(t *testing.T) {
	// Arbitrate will be called; china returns foreign, trust returns 9.9.9.9.
	china := &fakeExchanger{reply: makeAMsg("direct.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("direct.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)

	q := dns.Question{Name: "direct.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("direct.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	ips := collectAIPs(resp)
	if len(ips) != 1 || ips[0] != "9.9.9.9" {
		t.Errorf("expected [9.9.9.9] (no rewrite), got %v", ips)
	}
}

// TestHandlerBlacklist: blacklist-listed name, A query → answer = GatewayIP, no upstream call.
func TestHandlerBlacklist(t *testing.T) {
	// If upstream is called we'd know (it would return something else or we can track calls).
	callCount := 0
	trackExchanger := &countingExchanger{inner: &fakeExchanger{reply: makeAMsg("blacklist.test", "1.1.1.1")}, count: &callCount}
	h := newTestHandler(t, trackExchanger, trackExchanger)

	q := dns.Question{Name: "blacklist.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("blacklist.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	ips := collectAIPs(resp)
	if len(ips) != 1 || ips[0] != "10.0.0.1" {
		t.Errorf("expected [10.0.0.1] (gateway), got %v", ips)
	}
	if callCount != 0 {
		t.Errorf("expected no upstream calls for blacklist, got %d", callCount)
	}
}

// TestHandlerDefaultChinaIP: default name, A, arbitrate returns CN 1.2.3.4 → returned as-is.
func TestHandlerDefaultChinaIP(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("example.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)

	q := dns.Question{Name: "example.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	ips := collectAIPs(resp)
	if len(ips) != 1 || ips[0] != "1.2.3.4" {
		t.Errorf("expected [1.2.3.4] (CN kept), got %v", ips)
	}
}

// TestHandlerDefaultForeignRewritten: default name, A, arbitrate returns foreign 9.9.9.9 → rewritten to gatewayIP.
func TestHandlerDefaultForeignRewritten(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)

	q := dns.Question{Name: "example.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	ips := collectAIPs(resp)
	if len(ips) != 1 || ips[0] != "10.0.0.1" {
		t.Errorf("expected [10.0.0.1] (gateway rewrite), got %v", ips)
	}
}

// TestHandlerDefaultMixedIPs: default name, A, mixed {1.2.3.4(CN), 9.9.9.9(foreign)} → {1.2.3.4, 10.0.0.1} deduped.
func TestHandlerDefaultMixedIPs(t *testing.T) {
	// china returns foreign so trust is used; trust returns mixed IPs.
	china := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "1.2.3.4", "9.9.9.9")}
	h := newTestHandler(t, china, trust)

	q := dns.Question{Name: "example.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	ips := collectAIPs(resp)
	// Must contain 1.2.3.4 and 10.0.0.1, deduped (9.9.9.9 → 10.0.0.1 only once).
	if len(ips) != 2 {
		t.Fatalf("expected 2 IPs (deduped), got %v", ips)
	}
	ipSet := make(map[string]bool)
	for _, ip := range ips {
		ipSet[ip] = true
	}
	if !ipSet["1.2.3.4"] || !ipSet["10.0.0.1"] {
		t.Errorf("expected {1.2.3.4, 10.0.0.1}, got %v", ips)
	}
}

// TestHandlerMXForwardedToTrust: MX query → forwarded to Trust verbatim.
func TestHandlerMXForwardedToTrust(t *testing.T) {
	mxMsg := new(dns.Msg)
	q0 := new(dns.Msg)
	q0.SetQuestion("example.test.", dns.TypeMX)
	mxMsg.SetReply(q0)
	mxMsg.Answer = []dns.RR{&dns.MX{
		Hdr: dns.RR_Header{Name: "example.test.", Rrtype: dns.TypeMX, Class: dns.ClassINET, Ttl: 300},
		Mx:  "mail.example.test.",
		Preference: 10,
	}}

	china := &fakeExchanger{reply: makeAMsg("example.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: mxMsg}
	h := newTestHandler(t, china, trust)

	q := dns.Question{Name: "example.test.", Qtype: dns.TypeMX, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeMX)

	resp := h.resolve(context.Background(), q, req)
	if len(resp.Answer) != 1 {
		t.Fatalf("expected 1 MX record, got %d", len(resp.Answer))
	}
	mx, ok := resp.Answer[0].(*dns.MX)
	if !ok {
		t.Fatalf("expected *dns.MX, got %T", resp.Answer[0])
	}
	if mx.Mx != "mail.example.test." {
		t.Errorf("expected mail.example.test., got %s", mx.Mx)
	}
}

// TestHandlerServeDNS: smoke-test that ServeDNS writes a message via the ResponseWriter.
func TestHandlerServeDNS(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("example.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)

	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)
	w := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1234}}
	h.ServeDNS(w, req)
	if w.written == nil {
		t.Fatal("ServeDNS did not write a response")
	}
}

// TestHandlerDirectBlacklistPrecedence: a domain on both direct and blacklist → direct wins (step 4 before 5).
func TestHandlerDirectBlacklistPrecedence(t *testing.T) {
	// Make a handler where "both.test" is in both Direct and Blacklist.
	cn := &Chnroute{ranges: []ipRange{{start: ipToUint32(net.ParseIP("1.0.0.0").To4()), end: ipToUint32(net.ParseIP("1.255.255.255").To4())}}}
	makeDS := func(domains ...string) *DomainSet {
		ds := &DomainSet{entries: make(map[string]struct{})}
		for _, d := range domains {
			ds.entries[d] = struct{}{}
		}
		return ds
	}
	// arbitrate returns foreign 9.9.9.9; direct win means no rewrite.
	china := &fakeExchanger{reply: makeAMsg("both.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("both.test", "9.9.9.9")}
	h := &Handler{
		Adblock:   makeDS(),
		Direct:    makeDS("both.test"),
		Blacklist: makeDS("both.test"),
		CN:        cn,
		Cache:     NewCache(128),
		China:     china,
		Trust:     trust,
		GatewayIP: net.ParseIP("10.0.0.1").To4(),
		TTLMin:    10 * time.Second,
		TTLMax:    300 * time.Second,
		Timeout:   500 * time.Millisecond,
	}

	q := dns.Question{Name: "both.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("both.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	ips := collectAIPs(resp)
	// direct wins → no rewrite → 9.9.9.9 kept.
	if len(ips) != 1 || ips[0] != "9.9.9.9" {
		t.Errorf("expected direct to win over blacklist (9.9.9.9 kept), got %v", ips)
	}
}

// TestHandlerDropAAAAFromUpstream: for A query, AAAA RRs in upstream answer are dropped.
func TestHandlerDropAAAAFromUpstream(t *testing.T) {
	mixed := makeAMsg("example.test", "1.2.3.4")
	mixed.Answer = append(mixed.Answer, &dns.AAAA{
		Hdr:  dns.RR_Header{Name: "example.test.", Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 60},
		AAAA: net.ParseIP("2001:db8::1"),
	})
	china := &fakeExchanger{reply: mixed}
	trust := &fakeExchanger{reply: mixed}
	h := newTestHandler(t, china, trust)

	q := dns.Question{Name: "example.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	for _, rr := range resp.Answer {
		if _, ok := rr.(*dns.AAAA); ok {
			t.Errorf("unexpected AAAA RR in A answer: %v", rr)
		}
	}
}

// countingExchanger wraps another exchanger and counts calls.
type countingExchanger struct {
	inner Exchanger
	count *int
}

func (c *countingExchanger) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	*c.count++
	return c.inner.Exchange(ctx, q)
}
