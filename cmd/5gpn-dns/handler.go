package chnroute

import (
	"context"
	"net"
	"time"

	"github.com/miekg/dns"
)

// Handler is a dns.Handler that implements the 5gpn query dispatch policy:
// AAAA-block → HTTPS/SVCB-block → adblock → force-direct → blacklist → default-arbitrate.
type Handler struct {
	// Rule sets.
	Adblock   *DomainSet // NXDOMAIN for matched names.
	Direct    *DomainSet // Arbitrate but never rewrite IPs.
	Blacklist *DomainSet // Synthetic single-A = GatewayIP, no upstream.

	CN *Chnroute // IPv4 china ranges.

	Cache *Cache // DNS response cache (may be nil to disable).

	China Exchanger // China resolver (UDP to CN upstreams).
	Trust Exchanger // Trust resolver (DoT to trusted upstreams).

	GatewayIP net.IP // IP to substitute for foreign addresses.

	// Cache TTL clamping.
	TTLMin time.Duration
	TTLMax time.Duration

	Timeout time.Duration // Per-query arbitration timeout for china upstream.
}

// ServeDNS implements dns.Handler.  It unpacks the first question, calls
// resolve, and writes the result back to w.
func (h *Handler) ServeDNS(w dns.ResponseWriter, r *dns.Msg) {
	if len(r.Question) == 0 {
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeFormatError)
		_ = w.WriteMsg(m)
		return
	}
	q := r.Question[0]
	resp := h.resolve(context.Background(), q, r)
	_ = w.WriteMsg(resp)
}

// resolve is the testable inner implementation.  It receives the first
// question and the original request (used to set reply headers) and returns
// a fully-formed *dns.Msg.
//
// Precedence (applied in order):
//  1. TypeAAAA            → synthetic SOA / NOERROR (IPv4-only box).
//  2. TypeHTTPS / SVCB    → empty NOERROR.
//  3. adblock match       → NXDOMAIN.
//  4. direct match        → arbitrate, return IPs as-is (drop AAAA RRs, no rewrite).
//  5. blacklist match     → synthetic A = GatewayIP, no upstream.
//  6. default             → arbitrate, rewrite each A: CN.Contains→keep, else GatewayIP; dedup.
//
// For all other qtypes (MX/TXT/CNAME/NS/PTR/SOA/…) forward to Trust verbatim.
// Cache is consulted first for steps 4/6 and for the other-type forwarding path.
func (h *Handler) resolve(ctx context.Context, q dns.Question, r *dns.Msg) *dns.Msg {
	name := q.Name // already FQDN from the wire

	// ── Step 1: AAAA → synthetic SOA, NOERROR, empty Answer ─────────────────
	if q.Qtype == dns.TypeAAAA {
		return h.soaReply(r)
	}

	// ── Step 2: HTTPS / SVCB → empty NOERROR ────────────────────────────────
	if q.Qtype == dns.TypeHTTPS || q.Qtype == dns.TypeSVCB {
		m := new(dns.Msg)
		m.SetReply(r)
		m.RecursionAvailable = true
		return m
	}

	// ── Steps 3–6 apply to TypeA and all other query types ──────────────────

	isA := q.Qtype == dns.TypeA

	// normalised name (no trailing dot) for DomainSet matching.
	bare := stripDot(name)

	// ── Step 3: adblock ──────────────────────────────────────────────────────
	if h.Adblock != nil && h.Adblock.Match(bare) {
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeNameError)
		return m
	}

	// ── Step 4: force-direct ─────────────────────────────────────────────────
	if h.Direct != nil && h.Direct.Match(bare) {
		if isA {
			if cached, ok := h.cacheGet(name, q.Qtype); ok {
				return cached
			}
			resp, err := Arbitrate(ctx, r, h.China, h.Trust, h.CN, h.Timeout)
			if err != nil || resp == nil {
				return h.serverFail(r)
			}
			resp = filterAAAA(resp)
			h.cachePut(name, q.Qtype, resp)
			return resp
		}
		// Non-A direct → forward to Trust verbatim.
		return h.forwardTrust(ctx, r, name, q.Qtype)
	}

	// ── Step 5: blacklist ────────────────────────────────────────────────────
	if h.Blacklist != nil && h.Blacklist.Match(bare) {
		if isA {
			return h.gatewayReply(r)
		}
		// Non-A blacklist: forward to Trust (blacklist is A-specific semantics).
		return h.forwardTrust(ctx, r, name, q.Qtype)
	}

	// ── Step 6: default ──────────────────────────────────────────────────────
	if isA {
		if cached, ok := h.cacheGet(name, q.Qtype); ok {
			return cached
		}
		resp, err := Arbitrate(ctx, r, h.China, h.Trust, h.CN, h.Timeout)
		if err != nil || resp == nil {
			return h.serverFail(r)
		}
		resp = filterAAAA(resp)
		resp = h.rewriteA(resp, r)
		h.cachePut(name, q.Qtype, resp)
		return resp
	}

	// ── All other qtypes: forward to Trust verbatim ──────────────────────────
	return h.forwardTrust(ctx, r, name, q.Qtype)
}

// ── helpers ──────────────────────────────────────────────────────────────────

// forwardTrust sends q to the Trust exchanger and returns the reply verbatim.
// The result is cached.
func (h *Handler) forwardTrust(ctx context.Context, r *dns.Msg, name string, qtype uint16) *dns.Msg {
	if cached, ok := h.cacheGet(name, qtype); ok {
		return cached
	}
	resp, err := h.Trust.Exchange(ctx, r)
	if err != nil || resp == nil {
		return h.serverFail(r)
	}
	h.cachePut(name, qtype, resp)
	return resp
}

// rewriteA rewrites A records in resp: IPs in CN are kept; foreign IPs are
// replaced with GatewayIP.  Multiple foreign IPs collapse to a single GatewayIP
// entry (dedup).  The reply headers are refreshed from r.
func (h *Handler) rewriteA(resp *dns.Msg, r *dns.Msg) *dns.Msg {
	out := resp.Copy()
	out.SetReply(r)
	out.RecursionAvailable = true

	var rewritten []dns.RR
	gatewayAdded := false

	for _, rr := range resp.Answer {
		a, ok := rr.(*dns.A)
		if !ok {
			// keep non-A records (e.g. CNAME) as-is
			rewritten = append(rewritten, rr)
			continue
		}
		if h.CN.Contains(a.A) {
			rewritten = append(rewritten, a)
		} else {
			if !gatewayAdded {
				gw := &dns.A{
					Hdr: a.Hdr,
					A:   h.GatewayIP,
				}
				rewritten = append(rewritten, gw)
				gatewayAdded = true
			}
			// additional foreign IPs: skip (collapsed to single GatewayIP)
		}
	}
	out.Answer = rewritten
	return out
}

// filterAAAA returns a copy of m with all AAAA records removed from Answer.
func filterAAAA(m *dns.Msg) *dns.Msg {
	cp := m.Copy()
	var kept []dns.RR
	for _, rr := range cp.Answer {
		if _, isAAAA := rr.(*dns.AAAA); !isAAAA {
			kept = append(kept, rr)
		}
	}
	cp.Answer = kept
	return cp
}

// soaReply returns a NOERROR reply with a synthetic SOA in the Authority section.
func (h *Handler) soaReply(r *dns.Msg) *dns.Msg {
	m := new(dns.Msg)
	m.SetReply(r)
	m.RecursionAvailable = true
	// Synthetic SOA to signal IPv4-only.
	soa := &dns.SOA{
		Hdr: dns.RR_Header{
			Name:   ".",
			Rrtype: dns.TypeSOA,
			Class:  dns.ClassINET,
			Ttl:    300,
		},
		Ns:      "ns.5gpn.",
		Mbox:    "hostmaster.5gpn.",
		Serial:  1,
		Refresh: 3600,
		Retry:   600,
		Expire:  86400,
		Minttl:  300,
	}
	m.Ns = []dns.RR{soa}
	return m
}

// gatewayReply returns a synthetic A reply containing only GatewayIP.
func (h *Handler) gatewayReply(r *dns.Msg) *dns.Msg {
	m := new(dns.Msg)
	m.SetReply(r)
	m.RecursionAvailable = true
	m.Answer = []dns.RR{&dns.A{
		Hdr: dns.RR_Header{
			Name:   r.Question[0].Name,
			Rrtype: dns.TypeA,
			Class:  dns.ClassINET,
			Ttl:    clampTTL(60, h.TTLMin, h.TTLMax),
		},
		A: h.GatewayIP,
	}}
	return m
}

// serverFail returns a SERVFAIL reply.
func (h *Handler) serverFail(r *dns.Msg) *dns.Msg {
	m := new(dns.Msg)
	m.SetRcode(r, dns.RcodeServerFailure)
	return m
}

// cacheGet looks up (name, qtype) in the cache.  Safe to call when h.Cache == nil.
func (h *Handler) cacheGet(name string, qtype uint16) (*dns.Msg, bool) {
	if h.Cache == nil {
		return nil, false
	}
	return h.Cache.Get(name, qtype)
}

// cachePut stores resp in the cache, clamping its answer TTLs to [TTLMin, TTLMax].
// Safe to call when h.Cache == nil.
func (h *Handler) cachePut(name string, qtype uint16, resp *dns.Msg) {
	if h.Cache == nil {
		return
	}
	ttl := minAnswerTTL(resp, h.TTLMin, h.TTLMax)
	h.Cache.Put(name, qtype, resp, ttl)
}

// minAnswerTTL returns the minimum TTL across all answer RRs, clamped to
// [ttlMin, ttlMax].  If there are no answer RRs, ttlMin is returned.
func minAnswerTTL(m *dns.Msg, ttlMin, ttlMax time.Duration) time.Duration {
	min := ttlMax
	for _, rr := range m.Answer {
		t := time.Duration(rr.Header().Ttl) * time.Second
		if t < min {
			min = t
		}
	}
	if min < ttlMin {
		return ttlMin
	}
	if min > ttlMax {
		return ttlMax
	}
	return min
}

// clampTTL clamps v to [lo, hi] (in seconds → uint32).
func clampTTL(v uint32, lo, hi time.Duration) uint32 {
	t := time.Duration(v) * time.Second
	if t < lo {
		return uint32(lo.Seconds())
	}
	if t > hi {
		return uint32(hi.Seconds())
	}
	return v
}

// stripDot removes a trailing '.' from an FQDN.
func stripDot(s string) string {
	if len(s) > 0 && s[len(s)-1] == '.' {
		return s[:len(s)-1]
	}
	return s
}
