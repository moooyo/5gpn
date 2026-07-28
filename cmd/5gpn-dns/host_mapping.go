package main

import (
	"context"
	"errors"
	"net"
	"strings"

	"github.com/miekg/dns"
)

// Loon's [Host], enforced.
//
// A mapping says what a name's address should be resolved from. 5gpn has
// exactly two places where a name becomes an address, and this file is what
// both of them call:
//
//   - the client-facing resolver, where the answer decides where the client
//     connects;
//   - the egress broker on 127.0.0.1:5354, where mihomo re-resolves every
//     sniffed origin before dialing it.
//
// That second one is why nothing outside this package has to change. mihomo
// already routes all of its origin resolution back here, so substituting the
// answer substitutes the address mihomo dials — for a captured host's upstream
// leg and for an operator-steered one alike — with no mihomo change, no sidecar
// change, and no second copy of the table to drift.
//
// What a mapping does NOT do is decide routing. It supplies an address; whether
// that address is reached directly or through the gateway is still the ordinary
// ladder's decision, made on the address the mapping produced. That is what
// keeps a mapping from silently disabling the CN/foreign steering for a name:
// map a domestic name to a domestic address and it still goes direct, because
// direct-ness was never a property of the name.
//
// The one place a mapping cannot reach is an outbound that resolves remotely: a
// proxy node is handed the name, not the address, so the remote's resolver
// decides. That is Loon's behaviour too, and 5gpn's for every other name.

// hostMappingTTL bounds how long a client may cache a mapped answer.
//
// Short, because the mapping is a live policy object: it changes when an
// operator edits an extension, and a long TTL would leave clients on a
// superseded address well after the document that declared it was replaced. The
// alias and resolver forms carry the upstream's own TTLs instead — only the
// address form is synthesised here and needs a number chosen.
const hostMappingTTL = 60

// hostMappingAliasDepth bounds alias chasing. Chains beyond a couple of hops
// are a mistake rather than a configuration, and the bound is what makes a
// cycle (a → b → a) terminate rather than hang the resolver.
const hostMappingAliasDepth = 4

// answerHostMapping serves q from the [Host] table.
//
// The three returns are "reply", "this was a mapping", and "the mapping failed".
// A mapping that exists but could not be served returns (nil, true, err) so the
// caller can decide; a name with no mapping returns (nil, false, nil) and the
// caller resolves it normally.
func (h *Handler) answerHostMapping(ctx context.Context, q *dns.Msg) (*dns.Msg, bool, error) {
	if h == nil || q == nil || len(q.Question) != 1 {
		return nil, false, nil
	}
	return h.answerHostMappingDepth(ctx, q, q.Question[0].Name, hostMappingAliasDepth)
}

func (h *Handler) answerHostMappingDepth(ctx context.Context, q *dns.Msg, name string, depth int) (*dns.Msg, bool, error) {
	if depth <= 0 {
		return nil, true, errors.New("host mapping alias chain is too long")
	}
	binding, ok := h.hostMappingFor(name)
	if !ok {
		return nil, false, nil
	}

	if binding.servers != nil {
		reply, err := binding.servers.Exchange(ctx, q)
		return reply, true, err
	}

	if ip := net.ParseIP(binding.target); ip != nil {
		return hostMappingAddressReply(q, ip), true, nil
	}

	// Alias. The name resolves to whatever the target resolves to, so the
	// question is re-asked for the target — through this same table first, so
	// an alias whose target is itself mapped works, and through the ordinary
	// upstreams otherwise.
	alias := dns.Fqdn(binding.target)
	if strings.EqualFold(alias, dns.Fqdn(name)) {
		return nil, true, errors.New("host mapping alias points at itself")
	}
	aliased := q.Copy()
	aliased.Question[0].Name = alias
	if reply, mapped, err := h.answerHostMappingDepth(ctx, aliased, alias, depth-1); mapped {
		return hostMappingRestoreName(reply, q), true, err
	}
	_, trust := h.exchangers()
	if trust == nil {
		return nil, true, errors.New("host mapping alias cannot be resolved: no trust group")
	}
	reply, err := trust.Exchange(ctx, aliased)
	if err != nil {
		return nil, true, err
	}
	return hostMappingRestoreName(reply, q), true, nil
}

// arbitrateOrMap is what the client-facing resolution paths call instead of
// arbitrateSrc.
//
// A [Host] mapping replaces the upstream lookup and nothing else. Both callers
// go on to apply their own step of the ladder to whatever comes back — step 4
// returns it as-is, step 6 keeps a CN address and rewrites a foreign one to the
// gateway — and neither is told a mapping was involved. That is the whole
// contract: a mapping supplies an address, never a routing decision.
//
// The consequence worth stating, because it is the question a mapping raises:
// a domestic name mapped to a domestic address still goes direct, since
// directness was decided by the address's chnroute membership and not by the
// name. A name mapped to a foreign address is still steered to the gateway,
// rather than being handed to the client raw — which is what a mapping that
// bypassed the ladder would have done, silently disabling the steering that
// auto mode exists to provide.
//
// Captured names never arrive here: decideName steers them to the gateway
// before any of this runs, so capture beats a mapping by construction rather
// than by a rule someone has to remember.
func (h *Handler) arbitrateOrMap(
	ctx context.Context,
	q *dns.Msg,
	china, trust Exchanger,
	cn *Chnroute,
) (*dns.Msg, string, error) {
	if reply, mapped, err := h.answerHostMapping(ctx, q); mapped {
		if err != nil {
			return nil, "", err
		}
		return reply, "host-mapping", nil
	}
	return arbitrateSrc(ctx, q, china, trust, cn, h.stats)
}

//
// AAAA gets NODATA rather than an answer even when the mapping holds a v6
// address: 5gpn is IPv4-only end to end, and handing a client an AAAA it will
// prefer is how a name stops working. The v6 address is still usable by the
// egress broker, which asks for A only.
func hostMappingAddressReply(q *dns.Msg, ip net.IP) *dns.Msg {
	reply := new(dns.Msg)
	reply.SetReply(q)
	reply.Authoritative = true

	four := ip.To4()
	switch q.Question[0].Qtype {
	case dns.TypeA:
		if four == nil {
			return reply
		}
		reply.Answer = append(reply.Answer, &dns.A{
			Hdr: dns.RR_Header{
				Name: q.Question[0].Name, Rrtype: dns.TypeA,
				Class: dns.ClassINET, Ttl: hostMappingTTL,
			},
			A: four,
		})
	case dns.TypeAAAA:
		return reply
	}
	return reply
}

// hostMappingRestoreName rewrites an aliased reply back onto the question that
// was asked. Without it the client is answered for a name it never asked about,
// which every stub resolver treats as a failure.
func hostMappingRestoreName(reply *dns.Msg, original *dns.Msg) *dns.Msg {
	if reply == nil {
		return nil
	}
	out := reply.Copy()
	out.SetReply(original)
	out.Authoritative = true
	out.Rcode = reply.Rcode
	out.Answer = out.Answer[:0]
	for _, rr := range reply.Answer {
		record, ok := rr.(*dns.A)
		if !ok {
			continue
		}
		copied := *record
		copied.Hdr.Name = original.Question[0].Name
		out.Answer = append(out.Answer, &copied)
	}
	return out
}
