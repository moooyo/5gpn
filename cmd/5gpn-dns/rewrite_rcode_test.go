package main

import (
	"context"
	"testing"

	"github.com/miekg/dns"
)

// makeRcodeMsg builds a reply with the given rcode and an SOA in the
// Authority section (as real upstreams attach for NXDOMAIN/NODATA).
func makeRcodeMsg(name string, rcode int, withSOA bool) *dns.Msg {
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(name), dns.TypeA)
	m := new(dns.Msg)
	m.SetRcode(q, rcode)
	m.RecursionAvailable = true
	if withSOA {
		m.Ns = []dns.RR{&dns.SOA{
			Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeSOA, Class: dns.ClassINET, Ttl: 300},
			Ns:  "ns.test.", Mbox: "hostmaster.test.",
			Serial: 1, Refresh: 3600, Retry: 600, Expire: 86400, Minttl: 300,
		}}
	}
	return m
}

// The default A path rebuilds the reply via rewriteA, and SetReply used to
// reset the rcode to NOERROR — erasing NXDOMAIN (no negative caching for
// stubs, and the empty NOERROR got cached for TTLMin) and laundering an
// upstream SERVFAIL past cachePut's don't-cache-SERVFAIL guard. These lock
// the rcode/authority pass-through.
func TestDefaultPathPreservesNXDOMAIN(t *testing.T) {
	name := "nonexistent.test."
	nx := makeRcodeMsg(name, dns.RcodeNameError, true)
	h := newTestHandler(t, &fakeExchanger{reply: nx}, &fakeExchanger{reply: nx})

	q := new(dns.Msg)
	q.SetQuestion(name, dns.TypeA)
	resp := h.resolve(context.Background(), q.Question[0], q)

	if resp.Rcode != dns.RcodeNameError {
		t.Fatalf("NXDOMAIN was rewritten to rcode %d", resp.Rcode)
	}
	soaSeen := false
	for _, rr := range resp.Ns {
		if _, ok := rr.(*dns.SOA); ok {
			soaSeen = true
		}
	}
	if !soaSeen {
		t.Fatal("the authority SOA must survive rewriteA — stubs need it to negative-cache NXDOMAIN")
	}
	if n := h.Cache.Len(); n != 0 {
		t.Fatalf("NXDOMAIN must not be cached as a success, cache has %d entries", n)
	}
}

func TestDefaultPathPreservesSERVFAIL(t *testing.T) {
	name := "bogus-dnssec.test."
	sf := makeRcodeMsg(name, dns.RcodeServerFailure, false)
	h := newTestHandler(t, &fakeExchanger{reply: sf}, &fakeExchanger{reply: sf})

	q := new(dns.Msg)
	q.SetQuestion(name, dns.TypeA)
	resp := h.resolve(context.Background(), q.Question[0], q)

	if resp.Rcode != dns.RcodeServerFailure {
		t.Fatalf("upstream SERVFAIL was laundered to rcode %d", resp.Rcode)
	}
	if n := h.Cache.Len(); n != 0 {
		t.Fatalf("SERVFAIL must never be cached, cache has %d entries", n)
	}
}

// When a foreign A is rewritten to the gateway IP, DNSSEC RRs must be
// stripped from the authority as well (the signatures cover the original
// data), while ordinary authority records survive.
func TestRewriteStripsAuthorityDNSSEC(t *testing.T) {
	name := "foreign.test."
	reply := makeAMsg(name, "9.9.9.9") // foreign → rewritten to gateway
	reply.Ns = []dns.RR{
		&dns.NS{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeNS, Class: dns.ClassINET, Ttl: 300}, Ns: "ns.test."},
		&dns.RRSIG{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeRRSIG, Class: dns.ClassINET, Ttl: 300}, TypeCovered: dns.TypeNS, SignerName: "test.", Signature: "AAAA"},
	}
	h := newTestHandler(t, &fakeExchanger{reply: reply}, &fakeExchanger{reply: reply})

	q := new(dns.Msg)
	q.SetQuestion(name, dns.TypeA)
	resp := h.resolve(context.Background(), q.Question[0], q)

	if ips := collectAIPs(resp); len(ips) != 1 || ips[0] != "10.0.0.1" {
		t.Fatalf("expected the gateway rewrite, got %v", ips)
	}
	for _, rr := range resp.Ns {
		if _, ok := rr.(*dns.RRSIG); ok {
			t.Fatal("RRSIG in authority must be stripped after the answer was rewritten")
		}
	}
	nsSeen := false
	for _, rr := range resp.Ns {
		if _, ok := rr.(*dns.NS); ok {
			nsSeen = true
		}
	}
	if !nsSeen {
		t.Fatal("ordinary authority records must survive the rewrite")
	}
}
