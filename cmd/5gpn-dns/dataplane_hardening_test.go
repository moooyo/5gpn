package main

import (
	"context"
	"net"
	"strings"
	"testing"

	"github.com/miekg/dns"
)

// aWithRRSIG builds an A-record reply for name→ip plus a (dummy) RRSIG covering
// the A RRset, mimicking a DNSSEC-signed upstream answer.
func aWithRRSIG(name, ip string) *dns.Msg {
	m := makeAMsg(name, ip)
	m.Answer = append(m.Answer, &dns.RRSIG{
		Hdr: dns.RR_Header{
			Name:   dns.Fqdn(name),
			Rrtype: dns.TypeRRSIG,
			Class:  dns.ClassINET,
			Ttl:    60,
		},
		TypeCovered: dns.TypeA,
		Algorithm:   dns.RSASHA256,
		Labels:      2,
		OrigTtl:     60,
		SignerName:  dns.Fqdn(name),
		Signature:   "AAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	})
	return m
}

func hasRRSIG(m *dns.Msg) bool {
	for _, rr := range m.Answer {
		if _, ok := rr.(*dns.RRSIG); ok {
			return true
		}
	}
	return false
}

// #23: a rewritten (foreign→gateway) answer must not carry the original RRSIG,
// which is provably bogus against the forged A and SERVFAILs validating stubs.
func TestRewriteStripsBogusRRSIGOnForeignRewrite(t *testing.T) {
	// china foreign (falls through to trust), trust foreign+RRSIG.
	china := &fakeExchanger{reply: aWithRRSIG("foreign.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: aWithRRSIG("foreign.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)

	q := dns.Question{Name: "foreign.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("foreign.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)

	if ips := collectAIPs(resp); len(ips) != 1 || ips[0] != "10.0.0.1" {
		t.Fatalf("expected [10.0.0.1] (gateway rewrite), got %v", ips)
	}
	if hasRRSIG(resp) {
		t.Errorf("rewritten answer must not retain the bogus RRSIG, got %v", resp.Answer)
	}
}

// #23: a CN-only answer is passed through unchanged (gatewayAdded == false), so
// its valid RRSIG is preserved rather than stripped.
func TestRewriteKeepsRRSIGOnCNOnlyAnswer(t *testing.T) {
	// china is CN (1.2.3.4 ∈ 1.0.0.0/8) → returned as-is, kept (not rewritten).
	china := &fakeExchanger{reply: aWithRRSIG("cn.test", "1.2.3.4")}
	trust := &fakeExchanger{reply: aWithRRSIG("cn.test", "1.2.3.4")}
	h := newTestHandler(t, china, trust)

	q := dns.Question{Name: "cn.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("cn.test.", dns.TypeA)

	resp := h.resolve(context.Background(), q, req)

	if ips := collectAIPs(resp); len(ips) != 1 || ips[0] != "1.2.3.4" {
		t.Fatalf("expected [1.2.3.4] (CN kept), got %v", ips)
	}
	if !hasRRSIG(resp) {
		t.Errorf("CN-only answer should keep its valid RRSIG (no rewrite occurred)")
	}
}

// bigTXTReply builds a TXT reply large enough to exceed the 512-byte UDP floor.
func bigTXTReply(name string) *dns.Msg {
	m := new(dns.Msg)
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(name), dns.TypeTXT)
	m.SetReply(q)
	m.RecursionAvailable = true
	for i := 0; i < 20; i++ {
		m.Answer = append(m.Answer, &dns.TXT{
			Hdr: dns.RR_Header{
				Name:   dns.Fqdn(name),
				Rrtype: dns.TypeTXT,
				Class:  dns.ClassINET,
				Ttl:    60,
			},
			Txt: []string{strings.Repeat("x", 200)},
		})
	}
	return m
}

// #31a: an oversized reply over UDP is truncated (TC=1) to the client budget so
// the client cleanly retries over TCP instead of getting an oversized datagram.
func TestServeDNSTruncatesOversizedUDP(t *testing.T) {
	trust := &fakeExchanger{reply: bigTXTReply("big.test")}
	h := newTestHandler(t, &fakeExchanger{reply: bigTXTReply("big.test")}, trust)

	req := new(dns.Msg)
	req.SetQuestion("big.test.", dns.TypeTXT) // other-qtype → forwardTrust verbatim

	w := &fakeWriter{remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1234}}
	h.ServeDNS(w, req)

	if w.written == nil {
		t.Fatal("no reply written")
	}
	if !w.written.Truncated {
		t.Errorf("expected TC=1 on an oversized UDP reply")
	}
	packed, err := w.written.Pack()
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	if len(packed) > dns.MinMsgSize {
		t.Errorf("truncated UDP reply is %d bytes, want ≤ %d", len(packed), dns.MinMsgSize)
	}
}

// #31a: the same oversized reply over TCP/DoT (Network()!="udp") is NOT truncated.
func TestServeDNSDoesNotTruncateTCP(t *testing.T) {
	trust := &fakeExchanger{reply: bigTXTReply("big.test")}
	h := newTestHandler(t, &fakeExchanger{reply: bigTXTReply("big.test")}, trust)

	req := new(dns.Msg)
	req.SetQuestion("big.test.", dns.TypeTXT)

	w := &fakeWriter{remote: &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1234}}
	h.ServeDNS(w, req)

	if w.written == nil {
		t.Fatal("no reply written")
	}
	if w.written.Truncated {
		t.Errorf("TCP reply must not be truncated")
	}
	if got := len(w.written.Answer); got != 20 {
		t.Errorf("expected all 20 TXT RRs over TCP, got %d", got)
	}
}

// #31a: a client advertising a larger EDNS UDP size is truncated to that budget,
// not the 512 floor.
func TestUDPBudgetHonorsClientEDNS(t *testing.T) {
	req := new(dns.Msg)
	req.SetQuestion("x.test.", dns.TypeA)
	req.SetEdns0(4096, false)
	if got := udpBudget(req); got != 4096 {
		t.Errorf("udpBudget with EDNS 4096 = %d, want 4096", got)
	}
	// sub-512 advertised size is floored to 512.
	req2 := new(dns.Msg)
	req2.SetQuestion("x.test.", dns.TypeA)
	req2.SetEdns0(200, false)
	if got := udpBudget(req2); got != dns.MinMsgSize {
		t.Errorf("udpBudget with EDNS 200 = %d, want %d", got, dns.MinMsgSize)
	}
	// no EDNS → 512.
	req3 := new(dns.Msg)
	req3.SetQuestion("x.test.", dns.TypeA)
	if got := udpBudget(req3); got != dns.MinMsgSize {
		t.Errorf("udpBudget without EDNS = %d, want %d", got, dns.MinMsgSize)
	}
}

// #31b: a truncated china reply must not be treated as a CN answer — chinaIsCN
// returns false so arbitration falls through to the TLS-framed trust upstream.
func TestChinaIsCNIgnoresTruncatedReply(t *testing.T) {
	cn := loadTestChnroute(t) // 1.0.0.0/8

	full := buildMsg("cn.test", "1.2.3.4")
	if !chinaIsCN(full, cn) {
		t.Fatal("sanity: a full CN reply should be CN")
	}

	trunc := buildMsg("cn.test", "1.2.3.4")
	trunc.Truncated = true
	if chinaIsCN(trunc, cn) {
		t.Errorf("a truncated china reply must not be treated as CN")
	}
}

// #31b: end-to-end through Arbitrate — a truncated CN china reply falls through
// to the trust upstream's answer.
func TestArbitrateFallsThroughOnTruncatedChina(t *testing.T) {
	cn := loadTestChnroute(t)

	chinaMsg := buildMsg("x.test", "1.2.3.4") // would be CN…
	chinaMsg.Truncated = true                 // …but truncated, so ignored
	china := &fakeExchanger{reply: chinaMsg}
	trust := &fakeExchanger{reply: buildMsg("x.test", "8.8.8.8")}

	q := new(dns.Msg)
	q.SetQuestion("x.test.", dns.TypeA)

	got, err := Arbitrate(context.Background(), q, china, trust, cn, nil)
	if err != nil {
		t.Fatalf("Arbitrate: %v", err)
	}
	ips := collectAIPs(got)
	if len(ips) != 1 || ips[0] != "8.8.8.8" {
		t.Errorf("expected trust answer [8.8.8.8] after truncated china, got %v", ips)
	}
}
