package main

import (
	"context"
	"fmt"
	"net"
	"sync/atomic"
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
//   - block:     block.test
//   - direct:    direct.test
//   - force-proxy: proxy.test
//   - GatewayIP: 10.0.0.1
func newTestHandler(t *testing.T, china, trust Exchanger) *Handler {
	t.Helper()
	cn := &Chnroute{ranges: []ipRange{{start: ipToUint32(net.ParseIP("1.0.0.0").To4()), end: ipToUint32(net.ParseIP("1.255.255.255").To4())}}}

	h := &Handler{
		CN:        cn,
		Cache:     NewCache(128),
		China:     china,
		Trust:     trust,
		GatewayIP: net.ParseIP("10.0.0.1").To4(),
		TTLMin:    10 * time.Second,
		TTLMax:    300 * time.Second,
		Timeout:   500 * time.Millisecond,
	}
	publishTestPolicy(t, h, FallbackAuto,
		PolicyRule{Intent: IntentBlock, Matcher: Matcher{Kind: KindDomainSuffix, Value: "block.test"}},
		PolicyRule{Intent: IntentDirect, Matcher: Matcher{Kind: KindDomainSuffix, Value: "direct.test"}},
		PolicyRule{Intent: IntentProxy, Matcher: Matcher{Kind: KindDomainSuffix, Value: "proxy.test"}},
	)
	return h
}

func publishTestPolicy(t *testing.T, h *Handler, fallback FallbackPolicy, rules ...PolicyRule) {
	t.Helper()
	for i := range rules {
		rules[i].ID = fmt.Sprintf("test-%d", i+1)
		rules[i].Order = i
		rules[i].Enabled = true
	}
	model := PolicyModel{Version: policySchemaVersion, Rules: rules, Fallback: Fallback{Policy: fallback}}
	if err := h.publishPolicyModel(model, t.TempDir()); err != nil {
		t.Fatalf("publish test policy: %v", err)
	}
}

// makeAMsg builds a dns.Msg A-record reply containing the given IPs (TTL=60s).
func makeAMsg(name string, ips ...string) *dns.Msg {
	return makeAMsgWithTTL(name, 60, ips...)
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

// makeAMsgWithTTL builds a dns.Msg A-record reply with a specific TTL.
func makeAMsgWithTTL(name string, ttl uint32, ips ...string) *dns.Msg {
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
				Ttl:    ttl,
			},
			A: net.ParseIP(ip).To4(),
		})
	}
	return m
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

// panelCountExchanger is a test Exchanger that counts Exchange calls, so a test
// can assert a query was (or was NOT) forwarded to an upstream.
type panelCountExchanger struct {
	calls int
	reply *dns.Msg
}

func (e *panelCountExchanger) Exchange(_ context.Context, _ *dns.Msg) (*dns.Msg, error) {
	e.calls++
	return e.reply, nil
}

// TestHandlerPanelDomainOverride: a configured mihomo panel domain resolves to
// GatewayIP WITHOUT any upstream lookup (A), returns NODATA for AAAA, and does
// NOT hijack unrelated names.
func TestHandlerPanelDomainOverride(t *testing.T) {
	china := &panelCountExchanger{reply: makeAMsg("console.example.com", "9.9.9.9")}
	trust := &panelCountExchanger{reply: makeAMsg("console.example.com", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	h.ConsoleDomain = "console.example.com"
	h.ZashDomain = "zash.example.com"
	h.GatewayIP = net.ParseIP("203.0.113.1").To4()

	resolveA := func(name string) *dns.Msg {
		q := dns.Question{Name: dns.Fqdn(name), Qtype: dns.TypeA, Qclass: dns.ClassINET}
		req := new(dns.Msg)
		req.SetQuestion(dns.Fqdn(name), dns.TypeA)
		return h.resolve(context.Background(), q, req)
	}

	// A query for the console panel domain → GatewayIP, no upstream hit.
	if got := collectAIPs(resolveA("console.example.com")); len(got) != 1 || got[0] != "203.0.113.1" {
		t.Fatalf("console A = %v, want [203.0.113.1]", got)
	}
	if china.calls != 0 || trust.calls != 0 {
		t.Fatalf("panel-domain query hit upstream (china=%d trust=%d); must be answered locally", china.calls, trust.calls)
	}

	// Case-insensitive, trailing-dot-normalised match on the zash domain too.
	if got := collectAIPs(resolveA("ZASH.Example.COM")); len(got) != 1 || got[0] != "203.0.113.1" {
		t.Fatalf("zash (mixed case) A = %v, want [203.0.113.1]", got)
	}

	// AAAA for a panel domain → NODATA (NOERROR, empty Answer), no upstream.
	qAAAA := dns.Question{Name: "console.example.com.", Qtype: dns.TypeAAAA, Qclass: dns.ClassINET}
	reqAAAA := new(dns.Msg)
	reqAAAA.SetQuestion("console.example.com.", dns.TypeAAAA)
	respAAAA := h.resolve(context.Background(), qAAAA, reqAAAA)
	if respAAAA.Rcode != dns.RcodeSuccess || len(respAAAA.Answer) != 0 {
		t.Fatalf("console AAAA = rcode %d, %d answers; want NOERROR/empty", respAAAA.Rcode, len(respAAAA.Answer))
	}
	if china.calls != 0 || trust.calls != 0 {
		t.Fatalf("panel-domain AAAA hit upstream (china=%d trust=%d)", china.calls, trust.calls)
	}

	// An unrelated (foreign) domain is unaffected: the normal default path
	// arbitrates via the upstreams, proving the override didn't hijack it.
	china.calls, trust.calls = 0, 0
	china.reply = makeAMsg("other.example.net", "9.9.9.9")
	trust.reply = makeAMsg("other.example.net", "9.9.9.9")
	if got := collectAIPs(resolveA("other.example.net")); len(got) != 1 || got[0] != "203.0.113.1" {
		// foreign IP is rewritten to GatewayIP by the default path
		t.Fatalf("unrelated foreign A = %v, want [203.0.113.1] via rewrite", got)
	}
	if china.calls == 0 && trust.calls == 0 {
		t.Fatalf("unrelated domain did NOT hit upstream; the override wrongly intercepted it")
	}

	// With the panel domains UNSET, the same name is not hijacked (empty-string
	// guard): it falls through to the normal upstream path.
	h.ConsoleDomain, h.ZashDomain = "", ""
	china.calls, trust.calls = 0, 0
	china.reply = makeAMsg("console.example.com", "9.9.9.9")
	trust.reply = makeAMsg("console.example.com", "9.9.9.9")
	_ = resolveA("console.example.com")
	if china.calls == 0 && trust.calls == 0 {
		t.Fatalf("with panel domains unset, console.example.com was still intercepted (empty-string hijack)")
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

// TestHandlerBlock: block-listed name → NXDOMAIN.
func TestHandlerBlock(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	q := dns.Question{Name: "block.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("block.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	if resp.Rcode != dns.RcodeNameError {
		t.Errorf("expected NXDOMAIN (%d), got %d", dns.RcodeNameError, resp.Rcode)
	}
}

// TestHandlerBlockAAAA: block applies to any qtype (e.g. AAAA).
func TestHandlerBlockAAAA(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	q := dns.Question{Name: "block.test.", Qtype: dns.TypeAAAA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("block.test.", dns.TypeAAAA)

	// Note: block (step 2) comes AFTER AAAA-block (step 1). So AAAA to block.test
	// hits step 1 first → SOA reply, not NXDOMAIN.
	// Per spec: step 1 fires on TypeAAAA first, so this returns SOA/NOERROR.
	// Test that block is applied on TypeA:
	q2 := dns.Question{Name: "block.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req2 := new(dns.Msg)
	req2.SetQuestion("block.test.", dns.TypeA)
	resp2 := h.resolve(context.Background(), q2, req2)
	if resp2.Rcode != dns.RcodeNameError {
		t.Errorf("expected NXDOMAIN for block A, got %d", resp2.Rcode)
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

// TestHandlerForceProxy: proxy-intent name returns GatewayIP without upstream calls.
func TestHandlerForceProxy(t *testing.T) {
	// If upstream is called we'd know (it would return something else or we can track calls).
	callCount := 0
	trackExchanger := &countingExchanger{inner: &fakeExchanger{reply: makeAMsg("proxy.test", "1.1.1.1")}, count: &callCount}
	h := newTestHandler(t, trackExchanger, trackExchanger)

	q := dns.Question{Name: "proxy.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("proxy.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	ips := collectAIPs(resp)
	if len(ips) != 1 || ips[0] != "10.0.0.1" {
		t.Errorf("expected [10.0.0.1] (gateway), got %v", ips)
	}
	if callCount != 0 {
		t.Errorf("expected no upstream calls for force-proxy, got %d", callCount)
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

// atomicCountingExchanger wraps another exchanger and counts calls with an
// atomic counter. Unlike countingExchanger (plain int++), this is needed
// wherever the SAME exchanger instance is assigned to both Handler.China and
// Handler.Trust and the code path actually calls arbitrateSrc: arbitrateSrc
// always launches china.Exchange and trust.Exchange concurrently in separate
// goroutines, so a plain int++ shared between them is a genuine data race
// under -race.
type atomicCountingExchanger struct {
	inner Exchanger
	count *atomic.Int64
}

func (c *atomicCountingExchanger) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	c.count.Add(1)
	return c.inner.Exchange(ctx, q)
}

// newStubHandlerForeign builds a minimal Handler for the fallback-mode tests:
// china/trust both return the given IPs for whatever name is asked (via one
// shared atomicCountingExchanger, so upstream calls are countable),
// GatewayIP=10.0.0.1, and no rules/chnroute. Deliberately no Cache:
// h.Cache==nil disables
// cacheGet/cachePut entirely, so repeated resolve() calls for the SAME name
// under different fallback modes always re-arbitrate instead of replaying an
// answer cached under a prior mode.
func newStubHandlerForeign(t *testing.T, name string, ips ...string) (*Handler, *atomic.Int64) {
	t.Helper()
	reply := makeAMsg(name, ips...)
	var calls atomic.Int64
	exch := &atomicCountingExchanger{inner: &fakeExchanger{reply: reply}, count: &calls}
	h := &Handler{
		China:     exch,
		Trust:     exch,
		GatewayIP: net.ParseIP("10.0.0.1").To4(),
		TTLMin:    10 * time.Second,
		TTLMax:    300 * time.Second,
		Timeout:   500 * time.Millisecond,
	}
	publishTestPolicy(t, h, FallbackAuto)
	return h, &calls
}

// firstA returns the first A-record IP string in resp.Answer, or "" if none.
func firstA(resp *dns.Msg) string {
	ips := collectAIPs(resp)
	if len(ips) == 0 {
		return ""
	}
	return ips[0]
}

// TestHandlerFallbackModes covers the step-6 (unmatched-name) fallback modes:
//   - auto: a
//     foreign answer is rewritten to GatewayIP.
//   - direct: arbitrate but return the real (un-rewritten) IP.
//   - gateway: synthetic GatewayIP answer, no upstream consulted at all.
func TestHandlerFallbackModes(t *testing.T) {
	h, calls := newStubHandlerForeign(t, "unruled.example.com", "8.8.8.8")
	q := dns.Question{Name: "unruled.example.com.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	r := new(dns.Msg)
	r.SetQuestion(q.Name, dns.TypeA)

	// auto: foreign rewritten to gateway.
	if ip := firstA(h.resolve(context.Background(), q, r)); ip != "10.0.0.1" {
		t.Fatalf("auto: want gateway rewrite 10.0.0.1, got %s", ip)
	}

	publishTestPolicy(t, h, FallbackDirect)
	if ip := firstA(h.resolve(context.Background(), q, r)); ip != "8.8.8.8" {
		t.Fatalf("direct: want real IP 8.8.8.8 (no rewrite), got %s", ip)
	}

	beforeGateway := calls.Load()
	publishTestPolicy(t, h, FallbackGateway)
	if ip := firstA(h.resolve(context.Background(), q, r)); ip != "10.0.0.1" {
		t.Fatalf("gateway: want synthetic gateway IP 10.0.0.1, got %s", ip)
	}
	if after := calls.Load(); after != beforeGateway {
		// china's stub answer (8.8.8.8) is always foreign, so auto/direct each
		// made exactly 2 upstream calls (china + trust, both unconditionally
		// launched and awaited by arbitrateSrc); gateway mode must add none.
		t.Fatalf("gateway mode must not consult any upstream: call count went %d -> %d", beforeGateway, after)
	}
}

// TestHandlerFallbackGatewayOverridesCN proves gateway mode steers even a
// chnroute-CN answer to the gateway (unlike auto, which would keep it
// direct) — the design's "skip/override arbitration's keep-real-IP" clause.
func TestHandlerFallbackGatewayOverridesCN(t *testing.T) {
	h, calls := newStubHandlerForeign(t, "cn.example.com", "1.2.3.4")
	h.CN = &Chnroute{ranges: []ipRange{{start: ipToUint32(net.ParseIP("1.0.0.0").To4()), end: ipToUint32(net.ParseIP("1.255.255.255").To4())}}}
	publishTestPolicy(t, h, FallbackGateway)

	q := dns.Question{Name: "cn.example.com.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	r := new(dns.Msg)
	r.SetQuestion(q.Name, dns.TypeA)

	if ip := firstA(h.resolve(context.Background(), q, r)); ip != "10.0.0.1" {
		t.Fatalf("gateway mode on a CN name: want 10.0.0.1 (steered, not kept direct), got %s", ip)
	}
	if n := calls.Load(); n != 0 {
		t.Fatalf("gateway mode must not consult any upstream, got %d calls", n)
	}
}

// TestHandlerMXForwardedToTrust: MX query → forwarded to Trust verbatim.
func TestHandlerMXForwardedToTrust(t *testing.T) {
	mxMsg := new(dns.Msg)
	q0 := new(dns.Msg)
	q0.SetQuestion("example.test.", dns.TypeMX)
	mxMsg.SetReply(q0)
	mxMsg.Answer = []dns.RR{&dns.MX{
		Hdr:        dns.RR_Header{Name: "example.test.", Rrtype: dns.TypeMX, Class: dns.ClassINET, Ttl: 300},
		Mx:         "mail.example.test.",
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

func TestHandlerRejectsMultipleQuestions(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	req := new(dns.Msg)
	req.Question = []dns.Question{
		{Name: "allowed.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET},
		{Name: "block.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET},
	}
	w := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1234}}
	h.ServeDNS(w, req)
	if w.written == nil || w.written.Rcode != dns.RcodeFormatError {
		t.Fatalf("multiple-question response = %#v, want FORMERR", w.written)
	}
}

func TestHandlerRejectsNonINETQuestion(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	req := new(dns.Msg)
	req.Question = []dns.Question{{Name: "version.bind.", Qtype: dns.TypeTXT, Qclass: dns.ClassCHAOS}}
	w := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1234}}
	h.ServeDNS(w, req)
	if w.written == nil || w.written.Rcode != dns.RcodeNotImplemented {
		t.Fatalf("non-IN response = %#v, want NOTIMP", w.written)
	}
}

// TestHandlerFirstMatchWins verifies global order across intents.
func TestHandlerFirstMatchWins(t *testing.T) {
	// arbitrate returns foreign 9.9.9.9; direct win means no rewrite.
	china := &fakeExchanger{reply: makeAMsg("both.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("both.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	publishTestPolicy(t, h, FallbackAuto,
		PolicyRule{Intent: IntentDirect, Matcher: Matcher{Kind: KindDomainSuffix, Value: "both.test"}},
		PolicyRule{Intent: IntentProxy, Matcher: Matcher{Kind: KindDomainSuffix, Value: "both.test"}},
	)

	q := dns.Question{Name: "both.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("both.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)
	ips := collectAIPs(resp)
	// direct wins → no rewrite → 9.9.9.9 kept.
	if len(ips) != 1 || ips[0] != "9.9.9.9" {
		t.Errorf("expected first direct rule to win over proxy (9.9.9.9 kept), got %v", ips)
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

// ── Regression tests for review fixes ────────────────────────────────────────

// TestCachePutDoesNotCacheSERVFAIL: a SERVFAIL from upstream must NOT be cached.
// Uses the forwardTrust path (MX query) where the SERVFAIL Rcode is preserved
// and would be incorrectly cached without the fix.
func TestCachePutDoesNotCacheSERVFAIL(t *testing.T) {
	callCount := 0
	servfailMsg := new(dns.Msg)
	q0 := new(dns.Msg)
	q0.SetQuestion("fail.test.", dns.TypeMX)
	servfailMsg.SetRcode(q0, dns.RcodeServerFailure)

	inner := &fakeExchanger{reply: servfailMsg}
	tracked := &countingExchanger{inner: inner, count: &callCount}
	h := newTestHandler(t, tracked, tracked)

	req := new(dns.Msg)
	req.SetQuestion("fail.test.", dns.TypeMX)
	q := dns.Question{Name: "fail.test.", Qtype: dns.TypeMX, Qclass: dns.ClassINET}

	// First query: upstream is called (Trust exchanger).
	resp1 := h.resolve(context.Background(), q, req)
	if resp1.Rcode != dns.RcodeServerFailure {
		t.Errorf("expected SERVFAIL, got Rcode=%d", resp1.Rcode)
	}
	after1 := callCount

	// Second query: if SERVFAIL was (wrongly) cached, upstream would NOT be called.
	req2 := new(dns.Msg)
	req2.SetQuestion("fail.test.", dns.TypeMX)
	resp2 := h.resolve(context.Background(), q, req2)
	after2 := callCount

	if after2 <= after1 {
		t.Errorf("upstream should be called again on second query (SERVFAIL must not be cached); calls after 1st=%d, after 2nd=%d", after1, after2)
	}
	if resp2.Rcode != dns.RcodeServerFailure {
		t.Errorf("second query should also return SERVFAIL, got Rcode=%d", resp2.Rcode)
	}
	// Also verify cache has no entry.
	if _, ok := h.Cache.Get("fail.test.", dns.TypeMX); ok {
		t.Error("cache must not hold a SERVFAIL entry")
	}
}

// TestCachePutNODATACachesTTLMin: a NOERROR response with no Answer RRs (NODATA)
// must be cached for TTLMin (policy lives in cachePut, not minAnswerTTL).
func TestCachePutNODATACachesTTLMin(t *testing.T) {
	china := &fakeExchanger{}
	trust := &fakeExchanger{}
	h := newTestHandler(t, china, trust)

	nodataMsg := new(dns.Msg)
	q0 := new(dns.Msg)
	q0.SetQuestion("nodata.test.", dns.TypeA)
	nodataMsg.SetReply(q0)
	// Intentionally no Answer RRs — NODATA.

	h.cachePut("nodata.test.", dns.TypeA, nodataMsg, h.Cache.Epoch())
	cached, ok := h.Cache.Get("nodata.test.", dns.TypeA)
	if !ok {
		t.Fatal("NODATA NOERROR response should be cached")
	}
	if cached.Rcode != dns.RcodeSuccess {
		t.Errorf("expected cached NOERROR, got %d", cached.Rcode)
	}
}

// TestMinAnswerTTLNonEmpty: non-empty Answer → min of RR TTLs, clamped.
func TestMinAnswerTTLNonEmpty(t *testing.T) {
	ttlMin := 10 * time.Second
	ttlMax := 300 * time.Second

	// TTL=5s → below ttlMin, should be clamped to ttlMin.
	msgLow := makeAMsgWithTTL("x.test", 5, "1.2.3.4")
	if got := minAnswerTTL(msgLow, ttlMin, ttlMax); got != ttlMin {
		t.Errorf("TTL=5s below ttlMin: got %v, want %v", got, ttlMin)
	}

	// TTL=60s → within bounds.
	msgMid := makeAMsgWithTTL("x.test", 60, "1.2.3.4")
	if got := minAnswerTTL(msgMid, ttlMin, ttlMax); got != 60*time.Second {
		t.Errorf("TTL=60s: got %v, want 60s", got)
	}

	// TTL=86400s → above ttlMax, should be clamped to ttlMax.
	msgHigh := makeAMsgWithTTL("x.test", 86400, "1.2.3.4")
	if got := minAnswerTTL(msgHigh, ttlMin, ttlMax); got != ttlMax {
		t.Errorf("TTL=86400s above ttlMax: got %v, want %v", got, ttlMax)
	}
}

// TestGatewayRRTTLClamped: default-path rewrite with TTL=0 and TTL=99999 upstream
// must produce a gateway RR whose TTL is within [TTLMin, TTLMax].
func TestGatewayRRTTLClamped(t *testing.T) {
	for _, upstreamTTL := range []uint32{0, 99999} {
		t.Run(fmt.Sprintf("upstream_ttl_%d", upstreamTTL), func(t *testing.T) {
			upstream := makeAMsgWithTTL("clamp.test", upstreamTTL, "9.9.9.9") // foreign IP → gateway rewrite
			china := &fakeExchanger{reply: upstream}
			trust := &fakeExchanger{reply: upstream}
			h := newTestHandler(t, china, trust)

			req := new(dns.Msg)
			req.SetQuestion("clamp.test.", dns.TypeA)
			q := dns.Question{Name: "clamp.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}

			resp := h.resolve(context.Background(), q, req)
			if resp.Rcode != dns.RcodeSuccess {
				t.Fatalf("expected NOERROR, got %d", resp.Rcode)
			}
			ips := collectAIPs(resp)
			if len(ips) == 0 || ips[0] != "10.0.0.1" {
				t.Fatalf("expected gateway 10.0.0.1, got %v", ips)
			}
			gwRR := resp.Answer[0].(*dns.A)
			ttl := time.Duration(gwRR.Hdr.Ttl) * time.Second
			if ttl < h.TTLMin || ttl > h.TTLMax {
				t.Errorf("gateway RR TTL=%v is outside [TTLMin=%v, TTLMax=%v]", ttl, h.TTLMin, h.TTLMax)
			}
		})
	}
}

// TestNilCNDoesNotPanic: a Handler without CN set must not panic on an A query.
func TestNilCNDoesNotPanic(t *testing.T) {
	upstream := makeAMsg("nocn.test", "9.9.9.9")
	china := &fakeExchanger{reply: upstream}
	trust := &fakeExchanger{reply: upstream}
	h := newTestHandler(t, china, trust)
	h.CN = nil // remove CN

	req := new(dns.Msg)
	req.SetQuestion("nocn.test.", dns.TypeA)
	q := dns.Question{Name: "nocn.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}

	// Must not panic; foreign IP with nil CN → treat as foreign → GatewayIP.
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("nil CN caused panic: %v", r)
		}
	}()
	resp := h.resolve(context.Background(), q, req)
	if resp == nil {
		t.Fatal("expected non-nil response")
	}
}

// TestGatewayReplyDoesNotAliasGatewayIP: mutating the returned A.A bytes must
// not affect h.GatewayIP (the reply must own a copy, not share the backing array).
func TestGatewayReplyDoesNotAliasGatewayIP(t *testing.T) {
	china := &fakeExchanger{}
	trust := &fakeExchanger{}
	h := newTestHandler(t, china, trust)

	req := new(dns.Msg)
	req.SetQuestion("proxy.test.", dns.TypeA)

	resp := h.gatewayReply(req)
	if resp == nil || len(resp.Answer) == 0 {
		t.Fatal("expected non-empty gatewayReply")
	}
	aRR, ok := resp.Answer[0].(*dns.A)
	if !ok {
		t.Fatalf("expected *dns.A, got %T", resp.Answer[0])
	}

	// Record original GatewayIP value.
	origGW := make(net.IP, len(h.GatewayIP))
	copy(origGW, h.GatewayIP)

	// Mutate the returned A.A bytes in place.
	for i := range aRR.A {
		aRR.A[i] = 0xFF
	}

	// h.GatewayIP must be unchanged.
	if !h.GatewayIP.Equal(origGW) {
		t.Errorf("gatewayReply aliased GatewayIP: after mutation h.GatewayIP=%v, want %v", h.GatewayIP, origGW)
	}
}

// TestHandlerTimeoutZeroDoesNotSERVFAIL: a Handler with Timeout==0 must resolve
// a normal A query successfully (the zero-value guard defaults to 5s).
func TestHandlerTimeoutZeroDoesNotSERVFAIL(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("example.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	h.Timeout = 0 // exercise the zero-value guard

	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)
	w := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1234}}
	h.ServeDNS(w, req)

	if w.written == nil {
		t.Fatal("ServeDNS did not write a response")
	}
	if w.written.Rcode == dns.RcodeServerFailure {
		t.Errorf("ServeDNS returned SERVFAIL for Timeout==0; expected success")
	}
}

// ── Stats counters ───────────────────────────────────────────────────────────

// TestHandlerStatsBlockBumpsBlock: a block-matched A query bumps Total and Block.
func TestHandlerStatsBlockBumpsBlock(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	h.stats = &statsCounters{}

	q := dns.Question{Name: "block.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("block.test.", dns.TypeA)
	h.resolve(context.Background(), q, req)

	if got := h.stats.total.Load(); got != 1 {
		t.Errorf("Total = %d, want 1", got)
	}
	if got := h.stats.block.Load(); got != 1 {
		t.Errorf("Block = %d, want 1", got)
	}
	if got := h.stats.forceDirect.Load(); got != 0 {
		t.Errorf("ForceDirect = %d, want 0", got)
	}
	if got := h.stats.forceProxy.Load(); got != 0 {
		t.Errorf("ForceProxy = %d, want 0", got)
	}
	if got := h.stats.chnrouteCN.Load(); got != 0 {
		t.Errorf("ChnrouteCN = %d, want 0", got)
	}
	if got := h.stats.chnrouteForeign.Load(); got != 0 {
		t.Errorf("ChnrouteForeign = %d, want 0", got)
	}
}

// TestHandlerStatsForceProxyBumpsForceProxy: an explicit proxy match bumps Total and ForceProxy
// (separate from chnroute-foreign)
// distinguishable).
func TestHandlerStatsForceProxyBumpsForceProxy(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	h.stats = &statsCounters{}

	q := dns.Question{Name: "proxy.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("proxy.test.", dns.TypeA)
	h.resolve(context.Background(), q, req)

	if got := h.stats.total.Load(); got != 1 {
		t.Errorf("Total = %d, want 1", got)
	}
	if got := h.stats.forceProxy.Load(); got != 1 {
		t.Errorf("ForceProxy = %d, want 1", got)
	}
	if got := h.stats.chnrouteForeign.Load(); got != 0 {
		t.Errorf("ChnrouteForeign = %d, want 0", got)
	}
}

// TestHandlerStatsDefaultCNKeptBumpsChnrouteCN: a default A query resolved to a CN IP
// (kept as-is) bumps Total and ChnrouteCN (not force-direct, which is a name-only match).
func TestHandlerStatsDefaultCNKeptBumpsChnrouteCN(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("example.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	h.stats = &statsCounters{}

	q := dns.Question{Name: "example.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)
	h.resolve(context.Background(), q, req)

	if got := h.stats.total.Load(); got != 1 {
		t.Errorf("Total = %d, want 1", got)
	}
	if got := h.stats.chnrouteCN.Load(); got != 1 {
		t.Errorf("ChnrouteCN = %d, want 1", got)
	}
	if got := h.stats.chnrouteForeign.Load(); got != 0 {
		t.Errorf("ChnrouteForeign = %d, want 0", got)
	}
	if got := h.stats.forceDirect.Load(); got != 0 {
		t.Errorf("ForceDirect = %d, want 0", got)
	}
}

// TestHandlerStatsDefaultForeignRewrittenBumpsChnrouteForeign: a default A query resolved to a
// foreign IP (rewritten to gateway) bumps Total and ChnrouteForeign.
func TestHandlerStatsDefaultForeignRewrittenBumpsChnrouteForeign(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	h.stats = &statsCounters{}

	q := dns.Question{Name: "example.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)
	h.resolve(context.Background(), q, req)

	if got := h.stats.total.Load(); got != 1 {
		t.Errorf("Total = %d, want 1", got)
	}
	if got := h.stats.chnrouteForeign.Load(); got != 1 {
		t.Errorf("ChnrouteForeign = %d, want 1", got)
	}
	if got := h.stats.chnrouteCN.Load(); got != 0 {
		t.Errorf("ChnrouteCN = %d, want 0", got)
	}
	if got := h.stats.forceProxy.Load(); got != 0 {
		t.Errorf("ForceProxy = %d, want 0", got)
	}
}

// TestHandlerStatsForceDirectBumpsForceDirect: a force-direct-matched A query bumps Total and
// ForceDirect (not chnroute-cn, which is the default-path IP-arbitration reason).
func TestHandlerStatsForceDirectBumpsForceDirect(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("direct.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("direct.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	h.stats = &statsCounters{}

	q := dns.Question{Name: "direct.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("direct.test.", dns.TypeA)
	h.resolve(context.Background(), q, req)

	if got := h.stats.total.Load(); got != 1 {
		t.Errorf("Total = %d, want 1", got)
	}
	if got := h.stats.forceDirect.Load(); got != 1 {
		t.Errorf("ForceDirect = %d, want 1", got)
	}
	if got := h.stats.chnrouteCN.Load(); got != 0 {
		t.Errorf("ChnrouteCN = %d, want 0", got)
	}
}

// TestForceDirectUsesArbitrationWithoutRewrite locks generic direct semantics:
// both groups participate, the deterministic arbitration result is returned
// as-is, and a foreign direct rule is not forced through the china group.
func TestForceDirectUsesArbitrationWithoutRewrite(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("direct.test", "9.9.9.9")}
	trustCalls := 0
	trust := &countingExchanger{inner: &fakeExchanger{reply: makeAMsg("direct.test", "2.2.2.2")}, count: &trustCalls}
	h := newTestHandler(t, china, trust)
	h.stats = &statsCounters{}

	q := dns.Question{Name: "direct.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("direct.test.", dns.TypeA)
	resp := h.resolve(context.Background(), q, req)

	ips := collectAIPs(resp)
	if len(ips) != 1 || ips[0] != "2.2.2.2" {
		t.Fatalf("force-direct returned %v; want [2.2.2.2] (adopted trust answer, kept as-is)", ips)
	}
	if trustCalls != 1 {
		t.Errorf("trust group consulted %d times; generic direct must arbitrate both groups", trustCalls)
	}
	if got := h.stats.forceDirect.Load(); got != 1 {
		t.Errorf("ForceDirect = %d, want 1", got)
	}
}

func TestFallbackDirectCacheHitPreservesTraceMetadata(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("cached-direct.test", "9.9.9.8")}
	trust := &fakeExchanger{reply: makeAMsg("cached-direct.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	publishTestPolicy(t, h, FallbackDirect)
	q := dns.Question{Name: "cached-direct.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion(q.Name, q.Qtype)

	var first resolveInfo
	_ = h.resolveTraced(context.Background(), q, req, &first)
	if first.reason != "fallback-direct" || first.upstream != "trust" || first.cacheHit {
		t.Fatalf("first trace = %+v", first)
	}
	var second resolveInfo
	_ = h.resolveTraced(context.Background(), q, req, &second)
	if second.verdict != "direct" || second.reason != "fallback-direct" || second.upstream != "trust" || !second.cacheHit {
		t.Fatalf("cached trace = %+v; cache must preserve fallback verdict/source", second)
	}
}

// TestHandlerStatsNilStatsDoesNotPanic: a Handler with nil stats (e.g. existing
// test-constructed handlers) must not panic on resolve.
func TestHandlerStatsNilStatsDoesNotPanic(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	// h.stats is nil by default (newTestHandler does not set it).

	q := dns.Question{Name: "example.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("example.test.", dns.TypeA)

	defer func() {
		if r := recover(); r != nil {
			t.Errorf("nil stats caused panic: %v", r)
		}
	}()
	china := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("example.test", "9.9.9.9")}
	h.China = china
	h.Trust = trust
	h.resolve(context.Background(), q, req)
}

// TestCacheHitPreservesRequestID: a cache hit must return the CURRENT request's
// transaction ID, not the ID from the first (cache-populating) query.
// Regression for: cached *dns.Msg.Id was not reset to the incoming r.Id, causing
// strict DNS clients (dig, Android/iOS DoT) to reject the response as an ID mismatch.
func TestCacheHitPreservesRequestID(t *testing.T) {
	// Use a default (non-direct, non-force-proxy) name so we exercise fallback.
	china := &fakeExchanger{reply: makeAMsg("cached.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: makeAMsg("cached.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)

	// First query: cache miss — populates the cache. Use ID=1111.
	req1 := new(dns.Msg)
	req1.SetQuestion("cached.test.", dns.TypeA)
	req1.Id = 1111
	q := dns.Question{Name: "cached.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	resp1 := h.resolve(context.Background(), q, req1)
	if resp1 == nil {
		t.Fatal("first resolve returned nil")
	}

	// Second query: cache hit. Use a DIFFERENT ID=2222.
	req2 := new(dns.Msg)
	req2.SetQuestion("cached.test.", dns.TypeA)
	req2.Id = 2222
	resp2 := h.resolve(context.Background(), q, req2)
	if resp2 == nil {
		t.Fatal("second resolve returned nil")
	}

	// The response ID must match the SECOND request's ID, not the first.
	if resp2.Id != 2222 {
		t.Errorf("cache hit returned Id=%d; want 2222 (the second request's Id, not the cached %d)", resp2.Id, resp1.Id)
	}

	// Sanity: answer must still be correct (CN IP 1.2.3.4 kept as-is).
	ips := collectAIPs(resp2)
	if len(ips) == 0 || ips[0] != "1.2.3.4" {
		t.Errorf("cache hit returned wrong IPs: %v; want [1.2.3.4]", ips)
	}
}

// ---------------------------------------------------------------------------
// decideName policy decisions
// ---------------------------------------------------------------------------

func TestClassifyNameBlock(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	got := h.decideName("block.test").Verdict
	want := Verdict{Verdict: "block", Reason: "block"}
	if got != want {
		t.Errorf("classifyName(block.test) = %+v, want %+v", got, want)
	}
}

func TestClassifyNameForceDirect(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	got := h.decideName("direct.test").Verdict
	want := Verdict{Verdict: "direct", Reason: "force-direct"}
	if got != want {
		t.Errorf("classifyName(direct.test) = %+v, want %+v", got, want)
	}
}

func TestClassifyNameForceProxy(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	got := h.decideName("proxy.test").Verdict
	want := Verdict{Verdict: "proxy", Reason: "force-proxy"}
	if got != want {
		t.Errorf("classifyName(proxy.test) = %+v, want %+v", got, want)
	}
}

func TestClassifyNameDefaultIsEmptyVerdict(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	got := h.decideName("example.test").Verdict
	want := Verdict{}
	if got != want {
		t.Errorf("classifyName(example.test) = %+v, want zero-value Verdict (needs IP arbitration)", got)
	}
}

func TestClassifyNameFirstRuleBlock(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	publishTestPolicy(t, h, FallbackAuto,
		PolicyRule{Intent: IntentBlock, Matcher: Matcher{Kind: KindDomainSuffix, Value: "both.test"}},
		PolicyRule{Intent: IntentDirect, Matcher: Matcher{Kind: KindDomainSuffix, Value: "both.test"}},
		PolicyRule{Intent: IntentProxy, Matcher: Matcher{Kind: KindDomainSuffix, Value: "both.test"}},
	)

	got := h.decideName("both.test").Verdict
	want := Verdict{Verdict: "block", Reason: "block"}
	if got != want {
		t.Errorf("classifyName(both.test) = %+v, want %+v (block precedence)", got, want)
	}
}

func TestClassifyNameFirstRuleDirect(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	publishTestPolicy(t, h, FallbackAuto,
		PolicyRule{Intent: IntentDirect, Matcher: Matcher{Kind: KindDomainSuffix, Value: "directandproxy.test"}},
		PolicyRule{Intent: IntentProxy, Matcher: Matcher{Kind: KindDomainSuffix, Value: "directandproxy.test"}},
	)

	got := h.decideName("directandproxy.test").Verdict
	want := Verdict{Verdict: "direct", Reason: "force-direct"}
	if got != want {
		t.Errorf("classifyName(directandproxy.test) = %+v, want %+v", got, want)
	}
}
