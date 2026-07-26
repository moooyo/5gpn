package main

import (
	"context"
	"log"
	"net"
	"time"

	"github.com/miekg/dns"
)

// trustProbeName is the control name the trust sanity probe resolves. A
// long-lived, globally-resolvable name reserved for exactly this purpose by
// RFC 2606, so the probe cannot be mistaken for real traffic and does not
// depend on any one operator's domain.
const trustProbeName = "example.com."

// trustProbeTimeout bounds the probe. Generous, because it runs once at
// startup and a slow-but-working resolver must not be reported as broken.
const trustProbeTimeout = 8 * time.Second

// StartTrustProbe checks, once and in the background, that the trust group is
// answering plausibly — and only logs.
//
// Nothing else in the daemon can tell a working trust resolver from a hostile
// or placeholder one. ValidateUpstreams checks that a spec is syntactically an
// IPv4 address, which the shipped 22.22.22.22 default satisfies perfectly, and
// the only other startup probe (StartChina0x20Probe) targets the china group.
// A trust leg answering "example.com. 10 IN A 22.22.22.18" in under a
// millisecond is, to every other part of this system, indistinguishable from a
// healthy one — and the gateway rewrite hides it downstream, because a foreign
// address is replaced by GatewayIP before the client ever sees it. The
// operator's browsing keeps working while trust silently resolves nothing.
//
// Warn-only, never fatal, and never a breaker input. This is the sole resolver:
// a probe that could stop it from serving would be a worse bug than the one it
// detects, and a false positive on a legitimately fast local resolver must cost
// nothing but a log line.
func StartTrustProbe(ctx context.Context, ex Exchanger, entries []TrustEntry) {
	g, ok := ex.(*group)
	if !ok || len(g.members) == 0 {
		return
	}
	go probeTrust(ctx, g, entries)
}

func probeTrust(ctx context.Context, g *group, entries []TrustEntry) {
	ctx, cancel := context.WithTimeout(ctx, trustProbeTimeout)
	defer cancel()

	q := new(dns.Msg)
	q.SetQuestion(trustProbeName, dns.TypeA)

	reply, err := g.Exchange(ctx, q)
	if err != nil {
		log.Printf("warning: trust upstream probe: %s did not resolve: %v — foreign names may not be resolving; check Settings → upstream DNS", trustProbeName, err)
		return
	}
	ips := answerIPs(reply, queryLogMaxIPs)
	if len(ips) == 0 {
		log.Printf("warning: trust upstream probe: %s returned no address (rcode %s) — foreign names may not be resolving; check Settings → upstream DNS", trustProbeName, dns.RcodeToString[reply.Rcode])
		return
	}

	if why := implausibleTrustAnswer(ips, entries); why != "" {
		log.Printf("warning: trust upstream probe: %s resolved to %v — %s. Foreign names are not being resolved by a real recursive resolver; the gateway rewrite hides this from clients, so browsing may look fine while trust returns nothing useful. Set a real resolver in Settings → upstream DNS.", trustProbeName, ips, why)
		return
	}
	log.Printf("trust upstream probe: %s resolved to %v", trustProbeName, ips)
}

// implausibleTrustAnswer reports why an answer looks fabricated, or "" when it
// looks like a genuine recursive answer.
//
// Two signals, both chosen because a real resolver essentially never produces
// them for a public name, so false positives are rare enough that a log line
// is the right cost:
//
//   - an address inside a configured member's own /24, which is what a
//     placeholder or captive resolver returns when it answers everything with
//     itself;
//   - a private, loopback, or link-local address for a public name.
func implausibleTrustAnswer(ips []string, entries []TrustEntry) string {
	for _, raw := range ips {
		ip := net.ParseIP(raw)
		if ip == nil {
			continue
		}
		if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
			return "that is a private or loopback address for a public name, which means the answer is fabricated"
		}
		for _, e := range entries {
			host := e.DialAddr
			if h, _, err := net.SplitHostPort(e.DialAddr); err == nil {
				host = h
			}
			server := net.ParseIP(host)
			if server == nil || server.To4() == nil || ip.To4() == nil {
				continue
			}
			// Same /24 as the resolver being queried.
			if server.Mask(net.CIDRMask(24, 32)).Equal(ip.Mask(net.CIDRMask(24, 32))) {
				return "that is inside the resolver's own /24 (" + host + "), the signature of a placeholder or hijacking resolver"
			}
		}
	}
	return ""
}
