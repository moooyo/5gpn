package main

import (
	"context"
	"net"
	"sync/atomic"
	"time"

	"github.com/miekg/dns"
)

// ruleSnapshot is the reloadable portion of a Handler.
// SIGHUP replaces the whole snapshot atomically; in-flight queries
// that already loaded the old snapshot complete safely.
type ruleSnapshot struct {
	Adblock   *DomainSet
	Direct    *DomainSet
	Blacklist *DomainSet
	CN        *Chnroute
}

// statsCounters holds per-reason query counters, updated with atomics so
// they can be bumped from the hot query path without a mutex. All fields are
// accessed via sync/atomic; zero value is valid (all counters start at 0).
// A nil *statsCounters is valid too — callers must guard increments (see
// Handler.bump*) so Handlers built without stats wiring (e.g. existing unit
// tests that construct a Handler literal) never panic.
//
// The five reason counters replace the earlier coarse direct/proxy/block
// verdict counters, which conflated distinct decisions the control console
// needs to tell apart:
//   - adblock:         step-3 adblock match (verdict "block").
//   - forceDirect:     step-4 name-only "always direct" match (verdict "direct").
//   - blacklist:       step-5 name-only sinkhole match (verdict "proxy").
//   - chnrouteCN:      step-6 default path, resolved IP is a CN address kept as-is (verdict "direct").
//   - chnrouteForeign: step-6 default path, resolved IP was foreign and rewritten to GatewayIP (verdict "proxy").
type statsCounters struct {
	total           atomic.Uint64
	adblock         atomic.Uint64
	forceDirect     atomic.Uint64
	blacklist       atomic.Uint64
	chnrouteCN      atomic.Uint64
	chnrouteForeign atomic.Uint64
	// china/trust ok/err are OBSERVABILITY-ONLY (see the note above the routing
	// decision in Arbitrate): exposed via /api/stats + dashboard/bot and persisted,
	// but they MUST NOT feed the china-vs-trust decision, which is deterministic by
	// chnroute membership — never health/speed. They are also per-group and
	// asymmetric (trust counted only when consulted), so unfit to drive selection.
	chinaOK  atomic.Uint64
	chinaErr atomic.Uint64
	trustOK  atomic.Uint64
	trustErr atomic.Uint64
}

// Handler is a dns.Handler that implements the 5gpn query dispatch policy:
// AAAA-block → HTTPS/SVCB-block → adblock → force-direct → blacklist → default-arbitrate.
type Handler struct {
	// rules is swapped atomically on SIGHUP.
	rules atomic.Pointer[ruleSnapshot]

	// Rule sets — public for test construction; use swapRuleSets after init.
	Adblock   *DomainSet // NXDOMAIN for matched names.
	Direct    *DomainSet // Arbitrate but never rewrite IPs.
	Blacklist *DomainSet // Synthetic single-A = GatewayIP, no upstream.
	CN        *Chnroute  // IPv4 china ranges.

	Cache *Cache // DNS response cache (may be nil to disable).

	China Exchanger // China resolver (UDP to CN upstreams).
	Trust Exchanger // Trust resolver (DoT to trusted upstreams).

	GatewayIP net.IP // IP to substitute for foreign addresses.

	// Cache TTL clamping.
	TTLMin time.Duration
	TTLMax time.Duration

	Timeout time.Duration // Per-query arbitration timeout for china upstream.

	// stats holds per-verdict query counters. May be nil (disabled): all
	// bump* helpers guard against a nil stats pointer, so a zero-value or
	// test-constructed Handler never panics.
	stats *statsCounters
}

// bumpTotal increments the total-query counter. Safe to call when h.stats is nil.
func (h *Handler) bumpTotal() {
	if h.stats == nil {
		return
	}
	h.stats.total.Add(1)
}

// bumpChina records the outcome of a china-upstream exchange (ok = no error).
// A method on *statsCounters (not *Handler) so Arbitrate, which holds the
// counters directly, can call it. Nil-safe.
func (s *statsCounters) bumpChina(ok bool) {
	if s == nil {
		return
	}
	if ok {
		s.chinaOK.Add(1)
	} else {
		s.chinaErr.Add(1)
	}
}

// bumpTrust records the outcome of a trust-upstream exchange (ok = no error),
// counted only when trust was actually consulted. Nil-safe.
func (s *statsCounters) bumpTrust(ok bool) {
	if s == nil {
		return
	}
	if ok {
		s.trustOK.Add(1)
	} else {
		s.trustErr.Add(1)
	}
}

// bumpAdblock increments the adblock-reason counter. Safe to call when h.stats is nil.
func (h *Handler) bumpAdblock() {
	if h.stats == nil {
		return
	}
	h.stats.adblock.Add(1)
}

// bumpForceDirect increments the force-direct-reason counter. Safe to call when h.stats is nil.
func (h *Handler) bumpForceDirect() {
	if h.stats == nil {
		return
	}
	h.stats.forceDirect.Add(1)
}

// bumpBlacklist increments the blacklist-reason counter. Safe to call when h.stats is nil.
func (h *Handler) bumpBlacklist() {
	if h.stats == nil {
		return
	}
	h.stats.blacklist.Add(1)
}

// bumpChnrouteCN increments the chnroute-cn-reason counter. Safe to call when h.stats is nil.
func (h *Handler) bumpChnrouteCN() {
	if h.stats == nil {
		return
	}
	h.stats.chnrouteCN.Add(1)
}

// bumpChnrouteForeign increments the chnroute-foreign-reason counter. Safe to call when h.stats is nil.
func (h *Handler) bumpChnrouteForeign() {
	if h.stats == nil {
		return
	}
	h.stats.chnrouteForeign.Add(1)
}

// bumpDefaultVerdict inspects a step-6 (default-path) A response and bumps
// ChnrouteCN if every A record is a kept CN address, or ChnrouteForeign if any
// A record was rewritten to GatewayIP. Safe to call when h.stats is nil or
// resp has no Answer (e.g. NODATA — counted as neither, matching "no rewrite
// occurred").
func (h *Handler) bumpDefaultVerdict(resp *dns.Msg) {
	if h.stats == nil || resp == nil {
		return
	}
	for _, rr := range resp.Answer {
		a, ok := rr.(*dns.A)
		if !ok {
			continue
		}
		if h.GatewayIP != nil && a.A.Equal(h.GatewayIP) {
			h.bumpChnrouteForeign()
			return
		}
	}
	if len(resp.Answer) > 0 {
		h.bumpChnrouteCN()
	}
}

// swapRuleSets atomically replaces the reloadable rule-set fields.
// In-flight queries that have already loaded the old snapshot complete safely.
// After a swap, new queries will pick up the updated values.
func (h *Handler) swapRuleSets(adblock, direct, blacklist *DomainSet, cn *Chnroute) {
	snap := &ruleSnapshot{
		Adblock:   adblock,
		Direct:    direct,
		Blacklist: blacklist,
		CN:        cn,
	}
	h.rules.Store(snap)
	// Also update the public fields so that tests constructing a Handler directly
	// and calling resolve() without going through swapRuleSets continue to work.
	h.Adblock = adblock
	h.Direct = direct
	h.Blacklist = blacklist
	h.CN = cn
}

// ruleSnap returns the current rule snapshot.  If swapRuleSets has been called
// it returns the atomic snapshot; otherwise it falls back to the public fields
// (which is how the Handler is used in unit tests).
func (h *Handler) ruleSnap() (adblock, direct, blacklist *DomainSet, cn *Chnroute) {
	if snap := h.rules.Load(); snap != nil {
		return snap.Adblock, snap.Direct, snap.Blacklist, snap.CN
	}
	return h.Adblock, h.Direct, h.Blacklist, h.CN
}

// Verdict is the outcome of the shared name-only classification step:
// Verdict is one of "direct"|"proxy"|"block"; Reason is one of
// "adblock"|"force-direct"|"blacklist"|"chnroute-cn"|"chnroute-foreign".
// A zero-value Verdict ("", "") means "no terminal name-only verdict — the
// default case applies, and IP arbitration (chnroute-cn/chnroute-foreign)
// is needed to decide."
type Verdict struct {
	Verdict string
	Reason  string
}

// classifyName applies the name-only precedence adblock > direct > blacklist
// and returns the corresponding terminal Verdict. It returns the zero Verdict
// for the default case, meaning the caller must arbitrate and inspect the
// resolved IPs (chnroute-cn / chnroute-foreign) to finish classifying.
//
// This mirrors resolve's steps 3–5 exactly (same precedence, same DomainSet
// snapshot access) so that resolve and Controller.Lookup can share one
// decision instead of drifting.
func (h *Handler) classifyName(name string) Verdict {
	adblock, direct, blacklist, _ := h.ruleSnap()
	bare := stripDot(name)

	if adblock != nil && adblock.Match(bare) {
		return Verdict{Verdict: "block", Reason: "adblock"}
	}
	if direct != nil && direct.Match(bare) {
		return Verdict{Verdict: "direct", Reason: "force-direct"}
	}
	if blacklist != nil && blacklist.Match(bare) {
		return Verdict{Verdict: "proxy", Reason: "blacklist"}
	}
	return Verdict{}
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
	// Impose an overall query deadline. Guard against zero/negative Timeout
	// (zero-value Handler) which would produce an already-expired context.
	to := h.Timeout
	if to <= 0 {
		to = 5 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), to)
	defer cancel()
	q := r.Question[0]
	resp := h.resolve(ctx, q, r)
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

	h.bumpTotal()

	// Load the current rule-set snapshot atomically. classifyName re-derives
	// adblock/direct/blacklist from the same snapshot mechanism (ruleSnap);
	// cn is still needed here directly for arbitration/rewrite.
	_, _, _, cn := h.ruleSnap()

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

	// verdict carries the name-only precedence decision (adblock > direct >
	// blacklist); a zero-value Verdict means "default case, arbitrate+rewrite".
	verdict := h.classifyName(name)

	// ── Step 3: adblock ──────────────────────────────────────────────────────
	if verdict.Reason == "adblock" {
		h.bumpAdblock()
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeNameError)
		return m
	}

	// ── Step 4: force-direct ─────────────────────────────────────────────────
	if verdict.Reason == "force-direct" {
		if isA {
			h.bumpForceDirect()
			if cached, ok := h.cacheGet(name, q.Qtype); ok {
				cached.Id = r.Id
				return cached
			}
			resp, err := Arbitrate(ctx, r, h.China, h.Trust, cn, h.stats)
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
	if verdict.Reason == "blacklist" {
		if isA {
			h.bumpBlacklist()
			return h.gatewayReply(r)
		}
		// Non-A blacklist: forward to Trust (blacklist is A-specific semantics).
		return h.forwardTrust(ctx, r, name, q.Qtype)
	}

	// ── Step 6: default ──────────────────────────────────────────────────────
	if isA {
		if cached, ok := h.cacheGet(name, q.Qtype); ok {
			cached.Id = r.Id
			h.bumpDefaultVerdict(cached)
			return cached
		}
		resp, err := Arbitrate(ctx, r, h.China, h.Trust, cn, h.stats)
		if err != nil || resp == nil {
			return h.serverFail(r)
		}
		resp = filterAAAA(resp)
		resp = h.rewriteA(resp, r, cn)
		h.cachePut(name, q.Qtype, resp)
		h.bumpDefaultVerdict(resp)
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
		cached.Id = r.Id
		return cached
	}
	resp, err := h.Trust.Exchange(ctx, r)
	if err != nil || resp == nil {
		return h.serverFail(r)
	}
	h.cachePut(name, qtype, resp)
	return resp
}

// rewriteA rewrites A records in resp: IPs in cn are kept; foreign IPs are
// replaced with GatewayIP.  Multiple foreign IPs collapse to a single GatewayIP
// entry (dedup).  The reply headers are refreshed from r.
func (h *Handler) rewriteA(resp *dns.Msg, r *dns.Msg, cn *Chnroute) *dns.Msg {
	out := new(dns.Msg)
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
		if cn.Contains(a.A) {
			rewritten = append(rewritten, a)
		} else {
			if !gatewayAdded {
				gw := &dns.A{
					// Copy all Hdr fields from the upstream RR (preserves Rdlength
					// and any future fields), then clamp only the TTL.
					Hdr: a.Hdr,
					A:   append(net.IP(nil), h.GatewayIP...),
				}
				gw.Hdr.Ttl = clampTTL(a.Hdr.Ttl, h.TTLMin, h.TTLMax)
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
		A: append(net.IP(nil), h.GatewayIP...),
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
// Safe to call when h.Cache == nil.  Only caches successful (NOERROR) responses;
// SERVFAIL / REFUSED / etc. are not cached.
func (h *Handler) cachePut(name string, qtype uint16, resp *dns.Msg) {
	if h.Cache == nil {
		return
	}
	// Fix #1: don't cache non-success rcodes (e.g. SERVFAIL).
	if resp.Rcode != dns.RcodeSuccess {
		return
	}
	// NODATA (NOERROR with empty Answer): cache for TTLMin so the negative result
	// is not stored indefinitely.
	if len(resp.Answer) == 0 {
		h.Cache.Put(name, qtype, resp, h.TTLMin)
		return
	}
	ttl := minAnswerTTL(resp, h.TTLMin, h.TTLMax)
	h.Cache.Put(name, qtype, resp, ttl)
}

// minAnswerTTL returns the minimum TTL across all answer RRs, clamped to
// [ttlMin, ttlMax].  Caller must ensure m.Answer is non-empty.
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
