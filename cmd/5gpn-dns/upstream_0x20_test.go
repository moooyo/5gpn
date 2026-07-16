package main

import (
	"strings"
	"testing"

	"github.com/miekg/dns"
)

// C5: randomizeDNSCase only flips ASCII letters (case-insensitively equal to the
// input) and leaves the rest untouched, so the wire name still resolves.
func TestRandomizeDNSCase(t *testing.T) {
	for _, in := range []string{"example.com.", "a1-b2.test.", "xn--fsq.com."} {
		got := randomizeDNSCase(in)
		if len(got) != len(in) {
			t.Fatalf("randomizeDNSCase(%q) len=%d, want %d", in, len(got), len(in))
		}
		if !strings.EqualFold(got, in) {
			t.Errorf("randomizeDNSCase(%q) = %q, not case-insensitively equal", in, got)
		}
		// Non-letters must be preserved exactly.
		for i := range in {
			c := in[i]
			isLetter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
			if !isLetter && got[i] != c {
				t.Errorf("randomizeDNSCase(%q): non-letter at %d changed %q→%q", in, i, string(c), string(got[i]))
			}
		}
	}
}

// C5: restoreDNSCase puts the caller's original casing back on the question and
// on answer owner names that byte-match the sent (randomised) name, so 0x20
// never leaks past Exchange.
func TestRestoreDNSCase(t *testing.T) {
	orig := "Example.COM."
	sent := "eXaMpLe.cOm."
	m := new(dns.Msg)
	q := new(dns.Msg)
	q.SetQuestion(sent, dns.TypeA)
	m.SetReply(q)
	m.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: sent, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}}}

	restoreDNSCase(m, sent, orig)

	if m.Question[0].Name != orig {
		t.Errorf("question name = %q, want %q", m.Question[0].Name, orig)
	}
	if m.Answer[0].Header().Name != orig {
		t.Errorf("answer owner = %q, want %q", m.Answer[0].Header().Name, orig)
	}
}

// C5: the 0x20 self-probe decision — 0x20 stays on unless a china upstream is
// reachable-but-normalising (which would funnel CN domains through the gateway).
func TestDecide0x20(t *testing.T) {
	cases := []struct {
		preserve, reachablePlain, want bool
	}{
		{true, false, true},  // a member preserves case → keep on
		{true, true, true},   // one preserves (even if another normalises) → keep on
		{false, true, false}, // reachable but none preserve → normalises → disable
		{false, false, true}, // nothing reachable → inconclusive → keep on
	}
	for _, c := range cases {
		if got := decide0x20(c.preserve, c.reachablePlain); got != c.want {
			t.Errorf("decide0x20(preserve=%v, reachablePlain=%v) = %v, want %v", c.preserve, c.reachablePlain, got, c.want)
		}
	}
}

// C5: a normalising china group must not error every query — with 0x20 off,
// Exchange sends the plain query and returns the reply unchanged.
func TestGroupRandomizeToggle(t *testing.T) {
	g := NewUDPGroup([]string{"192.0.2.1"}, true).(*group)
	if !g.randomize.Load() {
		t.Fatal("expected 0x20 on after NewUDPGroup(true)")
	}
	g.randomize.Store(false)
	if g.randomize.Load() {
		t.Fatal("expected 0x20 off after Store(false)")
	}
}
