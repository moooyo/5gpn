package main

import (
	"testing"

	"github.com/miekg/dns"
)

// TestStripDNSSECRRs_FullTypeSet locks the complete set of DNSSEC RR types
// stripDNSSECRRs must remove (RRSIG, NSEC, NSEC3, NSEC3PARAM, DNSKEY, DS,
// CDS, CDNSKEY, DLV) across all three message sections, while leaving
// ordinary records and OPT (EDNS pseudo-RR, handled at the transport layer,
// not a signature-bearing record) untouched.
func TestStripDNSSECRRs_FullTypeSet(t *testing.T) {
	ordinary := []dns.RR{
		&dns.NS{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeNS, Class: dns.ClassINET, Ttl: 300}, Ns: "ns.test."},
	}
	dnssec := []dns.RR{
		&dns.RRSIG{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeRRSIG, Class: dns.ClassINET, Ttl: 300}},
		&dns.NSEC{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeNSEC, Class: dns.ClassINET, Ttl: 300}},
		&dns.NSEC3{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeNSEC3, Class: dns.ClassINET, Ttl: 300}},
		&dns.NSEC3PARAM{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeNSEC3PARAM, Class: dns.ClassINET, Ttl: 300}},
		&dns.DNSKEY{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeDNSKEY, Class: dns.ClassINET, Ttl: 300}},
		&dns.DS{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeDS, Class: dns.ClassINET, Ttl: 300}},
		&dns.CDS{DS: dns.DS{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeCDS, Class: dns.ClassINET, Ttl: 300}}},
		&dns.CDNSKEY{DNSKEY: dns.DNSKEY{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeCDNSKEY, Class: dns.ClassINET, Ttl: 300}}},
		&dns.DLV{DS: dns.DS{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeDLV, Class: dns.ClassINET, Ttl: 300}}},
	}
	opt := &dns.OPT{Hdr: dns.RR_Header{Name: ".", Rrtype: dns.TypeOPT}}

	all := append(append(append([]dns.RR{}, ordinary...), dnssec...), opt)
	out := stripDNSSECRRs(all)

	if len(out) != len(ordinary)+1 {
		t.Fatalf("expected %d survivors (ordinary + OPT), got %d: %+v", len(ordinary)+1, len(out), out)
	}
	sawOPT := false
	sawNS := false
	for _, rr := range out {
		switch rr.(type) {
		case *dns.OPT:
			sawOPT = true
		case *dns.NS:
			sawNS = true
		case *dns.RRSIG, *dns.NSEC, *dns.NSEC3, *dns.NSEC3PARAM, *dns.DNSKEY, *dns.DS, *dns.CDS, *dns.CDNSKEY, *dns.DLV:
			t.Fatalf("DNSSEC RR type leaked through: %T", rr)
		}
	}
	if !sawOPT {
		t.Fatal("OPT must be preserved, not treated as a DNSSEC RR")
	}
	if !sawNS {
		t.Fatal("ordinary NS record must be preserved")
	}
}

// TestStripDNSSECRRs_AllThreeSections mirrors the real rewriteA usage: DS in
// Ns and CDS in Extra must be stripped too, not only RRSIG in Answer.
func TestStripDNSSECRRs_AllThreeSections(t *testing.T) {
	answer := []dns.RR{
		&dns.A{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 300}},
		&dns.RRSIG{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeRRSIG, Class: dns.ClassINET, Ttl: 300}},
	}
	ns := []dns.RR{
		&dns.NS{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeNS, Class: dns.ClassINET, Ttl: 300}, Ns: "ns.test."},
		&dns.DS{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeDS, Class: dns.ClassINET, Ttl: 300}},
	}
	extra := []dns.RR{
		&dns.CDS{DS: dns.DS{Hdr: dns.RR_Header{Name: "test.", Rrtype: dns.TypeCDS, Class: dns.ClassINET, Ttl: 300}}},
	}

	outAnswer := stripDNSSECRRs(answer)
	outNs := stripDNSSECRRs(ns)
	outExtra := stripDNSSECRRs(extra)

	if len(outAnswer) != 1 {
		t.Fatalf("Answer: expected RRSIG stripped, got %d rrs", len(outAnswer))
	}
	if len(outNs) != 1 {
		t.Fatalf("Ns: expected DS stripped, got %d rrs", len(outNs))
	}
	if len(outExtra) != 0 {
		t.Fatalf("Extra: expected CDS stripped, got %d rrs", len(outExtra))
	}
}
