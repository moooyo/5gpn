package main

import (
	"context"
	"log"
	"net"
	"strings"
	"sync/atomic"
	"time"

	"github.com/miekg/dns"
)

// ruleSnapshot is the reloadable portion of a Handler.
// SIGHUP replaces the whole snapshot atomically; in-flight queries
// that already loaded the old snapshot complete safely.
type ruleSnapshot struct {
	Block     *DomainSet
	Direct    *DomainSet
	Blacklist *DomainSet
	CN        *Chnroute
}

// statsCounters holds per-reason query counters, updated with atomics so
// they can be bumped from the hot query path without a mutex. All fields are
// accessed via sync/atomic; zero value is valid (all counters start at 0).
// A nil *statsCounters is valid too ? callers must guard increments (see
// Handler.bump*) so Handlers built without stats wiring (e.g. existing unit
// tests that construct a Handler literal) never panic.
//
// The five reason counters replace the earlier coarse direct/proxy/block
// verdict counters, which conflated distinct decisions the control console
// needs to tell apart:
//   - block:           step-3 block match (verdict "block").
//   - forceDirect:     step-4 name-only "always direct" match (verdict "direct").
//   - blacklist:       step-5 name-only sinkhole match (verdict "proxy").
//   - chnrouteCN:      step-6 default path, resolved IP is a CN address kept as-is (verdict "direct").
//   - chnrouteForeign: step-6 default path, resolved IP was foreign and rewritten to GatewayIP (verdict "proxy").
type statsCounters struct {
	total           atomic.Uint64
	block           atomic.Uint64
	forceDirect     atomic.Uint64
	blacklist       atomic.Uint64
	chnrouteCN      atomic.Uint64
	chnrouteForeign atomic.Uint64
	// china/trust ok/err are OBSERVABILITY-ONLY (see the note above the routing
	// decision in Arbitrate): exposed via /api/stats + dashboard/bot and persisted,
	// but they MUST NOT feed the china-vs-trust decision, which is deterministic by
	// chnroute membership ? never health/speed. They are also per-group and
	// asymmetric (trust counted only when consulted), so unfit to drive selection.
	chinaOK  atomic.Uint64
	chinaErr atomic.Uint64
	trustOK  atomic.Uint64
	trustErr atomic.Uint64

	// Observability-only (like the china/trust ok/err counters): cache
	// effectiveness and per-group upstream latency, exposed via /api/stats and
	// the dashboard so "why is resolution slow / is the cache working" is
	// answerable. cacheHits/Misses are bumped in Handler.cacheGet; the latency
	// sums (nanoseconds) + counts are bumped from Arbitrate's exchange
	// goroutines. None of these feed any routing decision.
	cacheHits     atomic.Uint64
	cacheMisses   atomic.Uint64
	chinaLatNanos atomic.Uint64
	chinaLatCount atomic.Uint64
	trustLatNanos atomic.Uint64
	trustLatCount atomic.Uint64
}

// Handler is a dns.Handler that implements the 5gpn query dispatch policy:
// AAAA-block ? HTTPS/SVCB-block ? block ? force-direct ? blacklist ? default-arbitrate.
type Handler struct {
	// rules is swapped atomically on SIGHUP.
	rules atomic.Pointer[ruleSnapshot]

	// ups is the hot-swappable upstream state (PUT /api/upstreams). Like
	// rules, a nil pointer falls back to the public China/Trust fields for
	// test-constructed Handlers; main publishes the initial snapshot at boot.
	ups atomic.Pointer[upstreamSnapshot]

	// orderedPolicy is the globally ordered first-match policy snapshot. A nil
	// pointer preserves the legacy category-set behavior for test/upgrade
	// construction; once a policy model is published, even an empty snapshot is
	// authoritative and unmatched names proceed to fallback.
	orderedPolicy       atomic.Pointer[runtimePolicySnapshot]
	policyPlan          atomic.Pointer[runtimePolicyPlan]
	policyRefreshPaused atomic.Bool

	// Rule sets ? public for test construction; use swapRuleSets after init.
	Block     *DomainSet // NXDOMAIN for matched names.
	Direct    *DomainSet // Arbitrate but never rewrite IPs.
	Blacklist *DomainSet // Synthetic single-A = GatewayIP, no upstream.
	CN        *Chnroute  // IPv4 china ranges.

	Cache *Cache // DNS response cache (may be nil to disable).

	China Exchanger // China resolver (UDP to CN upstreams).
	Trust Exchanger // Trust resolver (bare IP=UDP / host@IP=DoT entries).

	// qlog, when non-nil, records every answered query into the in-memory
	// 5-minute query log served at GET /api/querylog. nil disables logging
	// (zero-value/test Handlers).
	qlog *queryLog

	GatewayIP net.IP // IP to substitute for foreign addresses.

	// ConsoleDomain / ZashDomain are gateway self domains. A
	// client already using 5gpn DNS must receive GatewayIP locally so its TLS
	// connection lands on the mihomo SNI split. Empty ⇒ no override.
	// See isPanelDomain / the self-domain override in resolveTraced.
	ConsoleDomain string
	ZashDomain    string

	// Cache TTL clamping.
	TTLMin time.Duration
	TTLMax time.Duration

	Timeout time.Duration // Per-query arbitration timeout for china upstream.

	// stats holds per-verdict query counters. May be nil (disabled): all
	// bump* helpers guard against a nil stats pointer, so a zero-value or
	// test-constructed Handler never panics.
	stats *statsCounters

	// sem bounds concurrent in-flight resolutions (admission control). A
	// buffered channel sized to the configured ceiling: serveContext acquires a
	// slot on entry and releases it on return, shedding with REFUSED when full.
	// nil disables shedding (DNS_MAX_INFLIGHT=0, and every test-constructed
	// Handler), preserving the unbounded pre-#1 behaviour there.
	sem chan struct{}

	// fallback selects the step-6 (unmatched) behavior: auto|direct|gateway. A
	// nil pointer means auto — a zero-value/test Handler is byte-identical to
	// the pre-policy default path. Swapped atomically by the policy apply
	// (see setFallback), mirroring the rules/ups atomic-swap idiom above.
	fallback atomic.Pointer[FallbackPolicy]
}

type runtimePolicyPlan struct {
	Model    PolicyModel
	RulesDir string
}

// setFallback installs the step-6 fallback mode. An empty string (the
// FallbackPolicy zero value) is treated as FallbackAuto, so a caller that
// passes through an unset config value never accidentally disables the
// default arbitration path.
func (h *Handler) setFallback(p FallbackPolicy) {
	if p == "" {
		p = FallbackAuto
	}
	h.fallback.Store(&p)
}

// fallbackMode returns the current step-6 fallback mode, defaulting to
// FallbackAuto when setFallback has never been called (nil pointer) — this is
// what makes a zero-value/test-constructed Handler behave exactly as the
// pre-policy code did.
func (h *Handler) fallbackMode() FallbackPolicy {
	if p := h.fallback.Load(); p != nil {
		return *p
	}
	return FallbackAuto
}

func (h *Handler) effectiveFallbackMode() FallbackPolicy {
	if snap := h.orderedPolicy.Load(); snap != nil {
		return snap.Fallback
	}
	return h.fallbackMode()
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

// recordChinaLatency adds one china-exchange duration to the cumulative sum +
// count (observability-only). Nil-safe.
func (s *statsCounters) recordChinaLatency(d time.Duration) {
	if s == nil {
		return
	}
	s.chinaLatNanos.Add(uint64(d.Nanoseconds()))
	s.chinaLatCount.Add(1)
}

// recordTrustLatency adds one trust-exchange duration to the cumulative sum +
// count (observability-only). Nil-safe.
func (s *statsCounters) recordTrustLatency(d time.Duration) {
	if s == nil {
		return
	}
	s.trustLatNanos.Add(uint64(d.Nanoseconds()))
	s.trustLatCount.Add(1)
}

// bumpBlock increments the block-reason counter. Safe to call when h.stats is nil.
func (h *Handler) bumpBlock() {
	if h.stats == nil {
		return
	}
	h.stats.block.Add(1)
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

// defaultVerdictOf classifies a step-6 (default-path) A response the way the
// counters and the query log report it: any A rewritten to GatewayIP ?
// proxy/chnroute-foreign; a non-empty all-kept answer ? direct/chnroute-cn;
// empty (NODATA) ? neither ("", "").
func (h *Handler) defaultVerdictOf(resp *dns.Msg) Verdict {
	if resp == nil {
		return Verdict{}
	}
	seenA := false
	for _, rr := range resp.Answer {
		a, ok := rr.(*dns.A)
		if !ok {
			continue
		}
		seenA = true
		if h.GatewayIP != nil && a.A.Equal(h.GatewayIP) {
			return Verdict{Verdict: "proxy", Reason: "chnroute-foreign"}
		}
	}
	if seenA {
		return Verdict{Verdict: "direct", Reason: "chnroute-cn"}
	}
	return Verdict{}
}

// bumpDefaultVerdict inspects a step-6 (default-path) A response and bumps
// ChnrouteCN if every A record is a kept CN address, or ChnrouteForeign if any
// A record was rewritten to GatewayIP. Safe to call when h.stats is nil or
// resp has no Answer (e.g. NODATA ? counted as neither, matching "no rewrite
// occurred").
func (h *Handler) bumpDefaultVerdict(resp *dns.Msg) {
	if h.stats == nil {
		return
	}
	switch h.defaultVerdictOf(resp).Reason {
	case "chnroute-foreign":
		h.bumpChnrouteForeign()
	case "chnroute-cn":
		h.bumpChnrouteCN()
	}
}

// swapRuleSets atomically replaces the reloadable rule-set fields and flushes
// the response cache. In-flight queries that have already loaded the old
// snapshot complete safely; new queries pick up the updated values.
//
// Every reload path ? SIGHUP, manual AddRule/RemoveRule via the Controller, and
// subscription-cache refreshes ? funnels through here, so this is the single
// point at which the response cache must be invalidated (see Cache.Flush): the
// cache holds fully-rewritten answers, so a rule change that is not accompanied
// by a flush would keep serving pre-change answers until TTL expiry (up to 24h).
// The initial publish at startup flushes an empty cache (a no-op).
//
// The public Block/Direct/Blacklist/CN fields are intentionally NOT written
// here. They are construction-only (set by a Handler literal in tests and in
// main before any goroutine starts) and read solely via ruleSnap's nil-fallback
// when swapRuleSets was never called. Writing them on every reload used to race
// concurrent readers (Controller.lookupArbitrate) and concurrent reloaders (two
// subscription tickers firing at once) with no lock ? a genuine data race. The
// atomic snapshot below is the single source of truth for the live query path.
func (h *Handler) swapRuleSets(block, direct, blacklist *DomainSet, cn *Chnroute) {
	snap := &ruleSnapshot{
		Block:     block,
		Direct:    direct,
		Blacklist: blacklist,
		CN:        cn,
	}
	h.rules.Store(snap)
	if !h.policyRefreshPaused.Load() {
		if err := h.refreshOrderedPolicy(); err != nil {
			// Keep the last known-good ordered snapshot. The caller's category/CN
			// reload still succeeds, while an unreadable policy subscription cache is
			// visible and cannot silently replace working policy with a partial one.
			log.Printf("policy runtime refresh: %v (keeping previous snapshot)", err)
		}
	}
	h.Cache.Flush() // nil-safe; invalidate so the rule change takes effect now
}

// publishPolicyModel compiles then atomically publishes an ordered snapshot and
// its refresh plan. Compilation happens first, so a malformed/unreadable model
// never disturbs the last known-good runtime state.
func (h *Handler) publishPolicyModel(model PolicyModel, rulesDir string) error {
	snap, err := CompileRuntimePolicy(model, rulesDir)
	if err != nil {
		return err
	}
	h.publishPreparedPolicy(model, rulesDir, snap)
	return nil
}

func (h *Handler) publishPreparedPolicy(model PolicyModel, rulesDir string, snap *runtimePolicySnapshot) {
	copyModel := model
	copyModel.Rules = append([]PolicyRule(nil), model.Rules...)
	plan := &runtimePolicyPlan{Model: copyModel, RulesDir: rulesDir}
	h.policyPlan.Store(plan)
	h.orderedPolicy.Store(snap)
	h.Cache.Flush()
}

// refreshOrderedPolicy rebuilds subscription-backed matchers after a generic
// rule reload. Pointer identity is a generation/CAS guard: a slow refresh of
// an old plan cannot overwrite a newer apply's snapshot.
func (h *Handler) refreshOrderedPolicy() error {
	plan := h.policyPlan.Load()
	if plan == nil {
		return nil
	}
	snap, err := CompileRuntimePolicy(plan.Model, plan.RulesDir)
	if err != nil {
		return err
	}
	if h.policyPlan.Load() == plan {
		h.orderedPolicy.Store(snap)
	}
	return nil
}

// ruleSnap returns the current rule snapshot.  If swapRuleSets has been called
// it returns the atomic snapshot; otherwise it falls back to the public fields
// (which is how the Handler is used in unit tests).
func (h *Handler) ruleSnap() (block, direct, blacklist *DomainSet, cn *Chnroute) {
	if snap := h.rules.Load(); snap != nil {
		return snap.Block, snap.Direct, snap.Blacklist, snap.CN
	}
	return h.Block, h.Direct, h.Blacklist, h.CN
}

// swapUpstreams atomically replaces the live china/trust exchanger groups and
// flushes the response cache ? cached answers were resolved (and possibly
// rewritten) against the OLD upstreams, so a swap that kept them could mask
// the change until TTL expiry, exactly like a rule reload would.
func (h *Handler) swapUpstreams(snap *upstreamSnapshot) {
	h.ups.Store(snap)
	h.Cache.Flush() // nil-safe
}

// exchangers returns the current china/trust exchangers: the atomic snapshot
// when one was published (main), else the public construction-time fields
// (unit tests).
func (h *Handler) exchangers() (china, trust Exchanger) {
	if snap := h.ups.Load(); snap != nil {
		return snap.China, snap.Trust
	}
	return h.China, h.Trust
}

// upstreamSnap returns the current upstream snapshot, or nil when none was
// published (test-constructed Handlers).
func (h *Handler) upstreamSnap() *upstreamSnapshot {
	return h.ups.Load()
}

// Verdict is the outcome of the shared name-only classification step:
// Verdict is one of "direct"|"proxy"|"block"; Reason is one of
// "block"|"force-direct"|"blacklist"|"chnroute-cn"|"chnroute-foreign"|
// "fallback-direct"|"fallback-gateway" (the latter two are step-6 outcomes
// under the FallbackDirect/FallbackGateway modes — see fallbackMode).
// A zero-value Verdict ("", "") means "no terminal name-only verdict ? the
// default case applies, and IP arbitration (chnroute-cn/chnroute-foreign)
// is needed to decide."
type Verdict struct {
	Verdict string
	Reason  string
}

type resolutionAction uint8

const (
	actionAuto resolutionAction = iota
	actionBlock
	actionDirect
	actionGateway
)

type resolutionDecision struct {
	Verdict Verdict
	Action  resolutionAction
}

// decideName is the shared policy decision used by live resolution, Lookup,
// and ResolveTest. It folds the ordered name rule and the configured fallback
// into one executable action so diagnostics cannot silently ignore fallback.
func (h *Handler) decideName(name string) resolutionDecision {
	v := h.classifyName(name)
	switch v.Reason {
	case "block":
		return resolutionDecision{Verdict: v, Action: actionBlock}
	case "force-direct":
		return resolutionDecision{Verdict: v, Action: actionDirect}
	case "blacklist":
		return resolutionDecision{Verdict: v, Action: actionGateway}
	}
	switch h.effectiveFallbackMode() {
	case FallbackDirect:
		return resolutionDecision{Verdict: Verdict{Verdict: "direct", Reason: "fallback-direct"}, Action: actionDirect}
	case FallbackGateway:
		return resolutionDecision{Verdict: Verdict{Verdict: "proxy", Reason: "fallback-gateway"}, Action: actionGateway}
	default:
		return resolutionDecision{Action: actionAuto}
	}
}

// classifyName applies the name-only precedence block > direct > blacklist
// and returns the corresponding terminal Verdict. It returns the zero Verdict
// for the default case, meaning the caller must arbitrate and inspect the
// resolved IPs (chnroute-cn / chnroute-foreign) to finish classifying.
//
// This mirrors resolve's steps 3?5 exactly (same precedence, same DomainSet
// snapshot access) so that resolve and Controller.Lookup can share one
// decision instead of drifting.
func (h *Handler) classifyName(name string) Verdict {
	if snap := h.orderedPolicy.Load(); snap != nil {
		bare := stripDot(name)
		for _, rule := range snap.Rules {
			if !rule.Matcher.Match(bare) {
				continue
			}
			switch rule.Intent {
			case IntentBlock:
				return Verdict{Verdict: "block", Reason: "block"}
			case IntentDirect:
				return Verdict{Verdict: "direct", Reason: "force-direct"}
			case IntentProxy:
				return Verdict{Verdict: "proxy", Reason: "blacklist"}
			}
		}
		return Verdict{}
	}
	block, direct, blacklist, _ := h.ruleSnap()
	bare := stripDot(name)

	if block != nil && block.Match(bare) {
		return Verdict{Verdict: "block", Reason: "block"}
	}
	if direct != nil && direct.Match(bare) {
		return Verdict{Verdict: "direct", Reason: "force-direct"}
	}
	if blacklist != nil && blacklist.Match(bare) {
		return Verdict{Verdict: "proxy", Reason: "blacklist"}
	}
	return Verdict{}
}

// ServeDNS implements dns.Handler.  The miekg UDP/TCP/DoT path carries no
// client cancellation, so it dispatches with context.Background(); the DoH
// front-end calls serveContext directly with the HTTP request context.
func (h *Handler) ServeDNS(w dns.ResponseWriter, r *dns.Msg) {
	h.serveContext(context.Background(), w, r)
}

// serveContext is the shared per-query entry for every transport. parent
// carries client cancellation where the transport provides it (DoH threads
// r.Context()). It applies admission control, imposes the per-query deadline,
// resolves, and truncates UDP replies, then writes the result to w.
func (h *Handler) serveContext(parent context.Context, w dns.ResponseWriter, r *dns.Msg) {
	if len(r.Question) == 0 {
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeFormatError)
		_ = w.WriteMsg(m)
		return
	}

	// Admission control: bound concurrent in-flight resolutions so an overload
	// (e.g. a random-subdomain flood whose latency pins at the query timeout)
	// sheds cheaply with REFUSED instead of accreting goroutines/sockets to the
	// LimitNOFILE / OOM wall. A nil sem (DNS_MAX_INFLIGHT=0, or a test Handler)
	// disables shedding.
	if h.sem != nil {
		select {
		case h.sem <- struct{}{}:
			defer func() { <-h.sem }()
		default:
			m := new(dns.Msg)
			m.SetRcode(r, dns.RcodeRefused)
			_ = w.WriteMsg(m)
			return
		}
	}

	// Impose an overall query deadline. Guard against zero/negative Timeout
	// (zero-value Handler) which would produce an already-expired context.
	to := h.Timeout
	if to <= 0 {
		to = 5 * time.Second
	}
	ctx, cancel := context.WithTimeout(parent, to)
	defer cancel()
	q := r.Question[0]
	start := time.Now()
	var ri resolveInfo
	resp := h.resolveTraced(ctx, q, r, &ri)
	if h.qlog != nil {
		h.qlog.add(QueryLogEntry{
			Time:       start,
			Client:     clientHost(w),
			Name:       stripDot(q.Name),
			Qtype:      dns.TypeToString[q.Qtype],
			Verdict:    ri.verdict,
			Reason:     ri.reason,
			Upstream:   ri.upstream,
			CacheHit:   ri.cacheHit,
			Rcode:      dns.RcodeToString[resp.Rcode],
			IPs:        answerIPs(resp, queryLogMaxIPs),
			DurationMs: float64(time.Since(start).Microseconds()) / 1000.0,
		})
	}
	// UDP responses must fit the client's advertised EDNS budget (512 without
	// EDNS). Truncate sets TC=1 when it drops RRs so the client cleanly retries
	// over TCP instead of receiving an oversized/malformed datagram. TCP/DoT and
	// the DoH shim report Network()!="udp" and are left intact (stream-framed).
	if isUDP(w) {
		resp.Truncate(udpBudget(r))
	}
	_ = w.WriteMsg(resp)
}

// isUDP reports whether w's transport is UDP (datagram), where responses must be
// size-bounded. TCP/DoT and the DoH writer shim report a non-"udp" Network().
func isUDP(w dns.ResponseWriter) bool {
	if w == nil {
		return false
	}
	ra := w.RemoteAddr()
	return ra != nil && ra.Network() == "udp"
}

// udpBudget returns the UDP payload size to truncate a reply to: the client's
// advertised EDNS0 UDP size when present (floored at 512), else the 512-byte
// non-EDNS limit.
func udpBudget(r *dns.Msg) int {
	if opt := r.IsEdns0(); opt != nil {
		if sz := int(opt.UDPSize()); sz >= dns.MinMsgSize {
			return sz
		}
	}
	return dns.MinMsgSize
}

// resolveInfo collects the per-query trace the query log records: the final
// verdict/reason, which upstream group's answer was adopted, and whether the
// answer came from the cache. A nil *resolveInfo disables tracing (the note*
// helpers are nil-safe), so resolve-path callers that don't log pay nothing.
type resolveInfo struct {
	verdict  string
	reason   string
	upstream string
	cacheHit bool
}

func (ri *resolveInfo) noteVerdict(v Verdict) {
	if ri != nil {
		ri.verdict, ri.reason = v.Verdict, v.Reason
	}
}

func (ri *resolveInfo) noteUpstream(src string) {
	if ri != nil {
		ri.upstream = src
	}
}

func (ri *resolveInfo) noteCacheHit() {
	if ri != nil {
		ri.cacheHit = true
	}
}

// resolve is the testable inner implementation, sans tracing ? the signature
// the existing unit tests exercise.
func (h *Handler) resolve(ctx context.Context, q dns.Question, r *dns.Msg) *dns.Msg {
	return h.resolveTraced(ctx, q, r, nil)
}

// resolveTraced receives the first question and the original request (used to
// set reply headers) and returns a fully-formed *dns.Msg, recording the
// decision trace into ri (nil-safe) for the query log.
//
// Precedence (applied in order):
//  1. TypeAAAA            ? synthetic SOA / NOERROR (IPv4-only box).
//  2. TypeHTTPS / SVCB    ? empty NOERROR.
//  3. block match         ? NXDOMAIN.
//  4. direct match        ? arbitrate, return IPs as-is (drop AAAA RRs, no rewrite).
//  5. blacklist match     ? synthetic A = GatewayIP, no upstream.
//  6. default             ? fallbackMode()-gated:
//     auto (default)   ? arbitrate, rewrite each A: CN.Contains?keep, else GatewayIP; dedup.
//     direct           ? arbitrate, return the real IPs as-is (never rewrite to GatewayIP).
//     gateway          ? synthetic A = GatewayIP for every name, no upstream consulted.
//
// For all other qtypes (MX/TXT/CNAME/NS/PTR/SOA/?) forward to Trust verbatim.
// Cache is consulted first for steps 4/6 and for the other-type forwarding path.
func (h *Handler) resolveTraced(ctx context.Context, q dns.Question, r *dns.Msg, ri *resolveInfo) *dns.Msg {
	name := q.Name // already FQDN from the wire

	h.bumpTotal()

	// Self-domain override: the mihomo panel domains (console.<base>/zash.<base>)
	// have NO public A record — the admin resolves them here, and we must answer
	// with GatewayIP so the browser's TLS lands on the gateway, where mihomo
	// SNI-splits it to the loopback panel. Intercept BEFORE any upstream lookup:
	// these names don't exist in public DNS, so forwarding them would only
	// NXDOMAIN and make the console unreachable. Only fires when the domain is
	// configured (non-empty) — never hijacks the empty name. A → synthetic
	// gateway A; every other qtype (AAAA in this IPv4-only design, HTTPS/SVCB,
	// …) → synthetic NODATA (NOERROR + SOA), matching the IPv4-only stance.
	if h.isPanelDomain(name) {
		if q.Qtype == dns.TypeA {
			ri.noteVerdict(Verdict{Verdict: "direct", Reason: "panel-self"})
			return h.gatewayReply(r)
		}
		ri.noteVerdict(Verdict{Reason: "panel-self"})
		return h.soaReply(r)
	}

	// The upstream groups are hot-swappable (PUT /api/upstreams); load the
	// current pair once so one query never mixes groups from two generations.
	china, trust := h.exchangers()

	// Capture the cache epoch BEFORE the rule snapshot: if a reload
	// (swapRuleSets = snapshot swap + cache flush + epoch bump) lands anywhere
	// between here and the final cachePut, the epoch mismatch discards the
	// write ? an answer computed under the pre-reload rules must not
	// repopulate the freshly flushed cache and re-mask the rule change.
	epoch := h.Cache.Epoch()

	// Load the current rule-set snapshot atomically. classifyName re-derives
	// block/direct/blacklist from the same snapshot mechanism (ruleSnap);
	// cn is still needed here directly for arbitration/rewrite.
	_, _, _, cn := h.ruleSnap()

	// ?? Step 1: AAAA ? synthetic SOA, NOERROR, empty Answer ?????????????????
	if q.Qtype == dns.TypeAAAA {
		ri.noteVerdict(Verdict{Reason: "aaaa-synthetic"})
		return h.soaReply(r)
	}

	// ?? Step 2: HTTPS / SVCB ? synthetic NODATA (NOERROR + SOA) ??????????????
	// We deliberately refuse to serve HTTPS/SVCB (RFC 9460) records. Two reasons,
	// both load-bearing for the SNI-steering data plane:
	//   1. ECH: the HTTPS RR's `ech` SvcParam lets the client encrypt the TLS
	//      ClientHello SNI. The xray sniproxy reads the PLAINTEXT SNI to recover
	//      the real destination; an encrypted SNI is unroutable and would be
	//      blackholed. Withholding the RR keeps the SNI in cleartext.
	//   2. ipv4hint/ipv6hint: the RR can hand the client the origin's real IPs
	//      directly, letting it bypass the A-record ? GatewayIP rewrite that
	//      steers foreign traffic through the gateway.
	// Returning NODATA WITH a synthetic SOA (not a bare empty NOERROR) lets the
	// client negatively cache the "no HTTPS record" and stop re-asking on every
	// connection; it degrades cleanly to plain A + Alt-Svc h3 upgrade.
	if q.Qtype == dns.TypeHTTPS || q.Qtype == dns.TypeSVCB {
		ri.noteVerdict(Verdict{Reason: "https-synthetic"})
		return h.soaReply(r)
	}

	// ?? Steps 3?6 apply to TypeA and all other query types ??????????????????

	isA := q.Qtype == dns.TypeA

	// verdict carries the name-only precedence decision (block > direct >
	// blacklist); a zero-value Verdict means "default case, arbitrate+rewrite".
	decision := h.decideName(name)
	verdict := decision.Verdict

	// ?? Step 3: block ??????????????????????????????????????????????????????
	if decision.Action == actionBlock {
		h.bumpBlock()
		ri.noteVerdict(verdict)
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeNameError)
		return m
	}

	// ?? Step 4: force-direct ?????????????????????????????????????????????????
	if decision.Action == actionDirect {
		ri.noteVerdict(verdict)
		if isA {
			h.bumpForceDirect()
			if cached, meta, ok := h.cacheGetWithMetadata(name, q.Qtype); ok {
				cached.Id = r.Id
				ri.noteUpstream(meta.Upstream)
				ri.noteCacheHit()
				return cached
			}
			// `direct` is transport-neutral policy: use the same china/trust
			// arbitration as the default path, then return the adopted answer
			// without gateway rewriting. A foreign domain explicitly marked direct
			// must therefore still work when china has no useful answer.
			resp, src, err := arbitrateSrc(ctx, r, china, trust, cn, h.stats)
			if err != nil || resp == nil {
				return h.staleOrServerFail(r, name, q.Qtype, ri)
			}
			ri.noteUpstream(src)
			resp = filterAAAA(resp)
			h.cachePutWithMetadata(name, q.Qtype, resp, epoch, cacheMetadata{
				Verdict: verdict.Verdict, Reason: verdict.Reason, Upstream: src,
			})
			return resp
		}
		// Non-A direct ? forward to Trust verbatim.
		return h.forwardTrust(ctx, trust, r, name, q.Qtype, epoch, ri)
	}

	// ?? Step 5: blacklist ????????????????????????????????????????????????????
	if decision.Action == actionGateway {
		ri.noteVerdict(verdict)
		if isA {
			if verdict.Reason == "blacklist" {
				h.bumpBlacklist()
			} else {
				h.bumpChnrouteForeign()
			}
			return h.gatewayReply(r)
		}
		// Non-A blacklist: forward to Trust (blacklist is A-specific semantics).
		return h.forwardTrust(ctx, trust, r, name, q.Qtype, epoch, ri)
	}

	// ?? Step 6: default ??????????????????????????????????????????????????????
	if isA {
		if cached, meta, ok := h.cacheGetWithMetadata(name, q.Qtype); ok {
			cached.Id = r.Id
			if meta.Reason != "" {
				ri.noteVerdict(Verdict{Verdict: meta.Verdict, Reason: meta.Reason})
				ri.noteUpstream(meta.Upstream)
				switch meta.Reason {
				case "fallback-direct":
					h.bumpForceDirect()
				case "chnroute-cn":
					h.bumpChnrouteCN()
				case "chnroute-foreign":
					h.bumpChnrouteForeign()
				}
			} else {
				h.bumpDefaultVerdict(cached)
				ri.noteVerdict(h.defaultVerdictOf(cached))
			}
			ri.noteCacheHit()
			return cached
		}
		// Auto fallback: arbitrate and rewrite only foreign answers.
		resp, src, err := arbitrateSrc(ctx, r, china, trust, cn, h.stats)
		if err != nil || resp == nil {
			return h.staleOrServerFail(r, name, q.Qtype, ri)
		}
		ri.noteUpstream(src)
		resp = filterAAAA(resp)
		resp = h.rewriteA(resp, r, cn)
		defaultVerdict := h.defaultVerdictOf(resp)
		ri.noteVerdict(defaultVerdict)
		h.cachePutWithMetadata(name, q.Qtype, resp, epoch, cacheMetadata{
			Verdict: defaultVerdict.Verdict, Reason: defaultVerdict.Reason, Upstream: src,
		})
		h.bumpDefaultVerdict(resp)
		return resp
	}

	// ?? All other qtypes: forward to Trust verbatim ??????????????????????????
	return h.forwardTrust(ctx, trust, r, name, q.Qtype, epoch, ri)
}

// ?? helpers ??????????????????????????????????????????????????????????????????

// forwardTrust sends q to the given trust exchanger and returns the reply
// verbatim. The result is cached.
func (h *Handler) forwardTrust(ctx context.Context, trust Exchanger, r *dns.Msg, name string, qtype uint16, epoch uint64, ri *resolveInfo) *dns.Msg {
	if ri != nil && ri.reason == "" {
		ri.reason = "forward-trust"
	}
	if cached, meta, ok := h.cacheGetWithMetadata(name, qtype); ok {
		cached.Id = r.Id
		if meta.Reason != "" {
			ri.noteVerdict(Verdict{Verdict: meta.Verdict, Reason: meta.Reason})
			ri.noteUpstream(meta.Upstream)
		}
		ri.noteCacheHit()
		return cached
	}
	resp, err := trust.Exchange(ctx, r)
	if err != nil || resp == nil {
		return h.staleOrServerFail(r, name, qtype, ri)
	}
	ri.noteUpstream("trust")
	meta := cacheMetadata{Upstream: "trust"}
	if ri != nil {
		meta.Verdict, meta.Reason = ri.verdict, ri.reason
	}
	h.cachePutWithMetadata(name, qtype, resp, epoch, meta)
	return resp
}

// rewriteA rewrites A records in resp: IPs in cn are kept; foreign IPs are
// replaced with GatewayIP.  Multiple foreign IPs collapse to a single GatewayIP
// entry (dedup).  The reply headers are refreshed from r.
func (h *Handler) rewriteA(resp *dns.Msg, r *dns.Msg, cn *Chnroute) *dns.Msg {
	out := new(dns.Msg)
	out.SetReply(r)
	out.RecursionAvailable = true
	// SetReply resets Rcode to NOERROR; carry the upstream verdict through.
	// Without this the default A path erases NXDOMAIN (clients get an
	// uncacheable NOERROR/NODATA with no SOA) and an upstream SERVFAIL is
	// laundered into a synthetic "no records" answer that slips past
	// cachePut's don't-cache-SERVFAIL guard and gets negative-cached for
	// TTLMin as if authoritative.
	out.Rcode = resp.Rcode

	// No gateway configured (DNS_GATEWAY_IP unset/unspecified) ? nothing to steer
	// foreign traffic to, so keep every A as-is (degrade to plain split-aware
	// resolution) instead of substituting an unroutable 0.0.0.0 for every non-CN
	// name ? which would silently blackhole all foreign destinations.
	gwUnset := h.GatewayIP == nil || h.GatewayIP.IsUnspecified()

	var rewritten []dns.RR
	gatewayAdded := false

	for _, rr := range resp.Answer {
		a, ok := rr.(*dns.A)
		if !ok {
			// keep non-A records (e.g. CNAME) as-is
			rewritten = append(rewritten, rr)
			continue
		}
		if gwUnset || cn.Contains(a.A) {
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
	// The Authority section carries the SOA that lets stubs negative-cache
	// NXDOMAIN/NODATA ? pass it through. (Extra/OPT is deliberately not
	// copied; EDNS is handled at the transport layer.)
	out.Ns = resp.Ns
	if gatewayAdded {
		// A foreign A was replaced by the gateway IP, so any RRSIG covering the
		// original A RRset is now provably bogus ? left in place it makes DO=1
		// validating stubs SERVFAIL on exactly the proxied set of domains (a
		// very confusing signature: CN domains validate, foreign ones fail).
		// Strip DNSSEC RRs from the modified answer and authority. AD is already
		// 0 here (out is a fresh reply from SetReply). CN-only answers keep
		// their signatures.
		out.Answer = stripDNSSECRRs(out.Answer)
		out.Ns = stripDNSSECRRs(out.Ns)
	}
	return out
}

// stripDNSSECRRs returns a copy of rrs with DNSSEC record types removed:
// RRSIG, NSEC, NSEC3, NSEC3PARAM, DNSKEY, DS, CDS, CDNSKEY, DLV. Applied to
// any section (Answer/Ns/Extra) whose covered data was rewritten, so a
// signature or delegation record that no longer matches the forged data is
// not left behind for a validating stub to choke on. OPT is deliberately
// NOT in this list ? it is the EDNS pseudo-RR handled at the transport
// layer, not a signature-bearing record, and must survive untouched.
func stripDNSSECRRs(rrs []dns.RR) []dns.RR {
	out := make([]dns.RR, 0, len(rrs))
	for _, rr := range rrs {
		switch rr.(type) {
		case *dns.RRSIG, *dns.NSEC, *dns.NSEC3, *dns.NSEC3PARAM, *dns.DNSKEY, *dns.DS, *dns.CDS, *dns.CDNSKEY, *dns.DLV:
			continue
		}
		out = append(out, rr)
	}
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

// gatewayReply returns a synthetic A reply containing only GatewayIP. When no
// gateway is configured (DNS_GATEWAY_IP unset/unspecified) it returns NXDOMAIN
// instead of a bogus 0.0.0.0 ? a blacklisted name should fail closed, not
// resolve to an unroutable address.
func (h *Handler) gatewayReply(r *dns.Msg) *dns.Msg {
	if h.GatewayIP == nil || h.GatewayIP.IsUnspecified() {
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeNameError)
		return m
	}
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

// staleOrServerFail is the upstream-failure fallback: return a served-stale
// cache entry (short TTL) if one exists, else SERVFAIL. Serving a slightly-stale
// answer during a total upstream outage beats handing every client a hard error
// while correct data sat in memory seconds ago.
func (h *Handler) staleOrServerFail(r *dns.Msg, name string, qtype uint16, ri *resolveInfo) *dns.Msg {
	if stale, meta, ok := h.cacheGetStaleWithMetadata(name, qtype); ok {
		stale.Id = r.Id
		if meta.Reason != "" {
			ri.noteVerdict(Verdict{Verdict: meta.Verdict, Reason: meta.Reason})
			ri.noteUpstream(meta.Upstream)
		}
		ri.noteCacheHit()
		return stale
	}
	return h.serverFail(r)
}

// cacheGetStale returns a last-resort stale cache entry for (name, qtype) when
// every upstream failed, with a short TTL so clients re-query soon. Safe to call
// when h.Cache == nil.
func (h *Handler) cacheGetStale(name string, qtype uint16) (*dns.Msg, bool) {
	msg, _, ok := h.cacheGetStaleWithMetadata(name, qtype)
	return msg, ok
}

func (h *Handler) cacheGetStaleWithMetadata(name string, qtype uint16) (*dns.Msg, cacheMetadata, bool) {
	if h.Cache == nil {
		return nil, cacheMetadata{}, false
	}
	return h.Cache.GetStaleWithMetadata(name, qtype, staleReplyTTLSecs)
}

// staleReplyTTLSecs is the TTL stamped on a served-stale answer: short, so a
// client re-queries soon once upstreams (may have) recovered.
const staleReplyTTLSecs = 30

// cacheGet looks up (name, qtype) in the cache.  Safe to call when h.Cache == nil.
// Bumps the observability-only cache hit/miss counters (nil-stats-safe).
func (h *Handler) cacheGet(name string, qtype uint16) (*dns.Msg, bool) {
	msg, _, ok := h.cacheGetWithMetadata(name, qtype)
	return msg, ok
}

func (h *Handler) cacheGetWithMetadata(name string, qtype uint16) (*dns.Msg, cacheMetadata, bool) {
	if h.Cache == nil {
		return nil, cacheMetadata{}, false
	}
	msg, meta, ok := h.Cache.GetWithMetadata(name, qtype)
	if h.stats != nil {
		if ok {
			h.stats.cacheHits.Add(1)
		} else {
			h.stats.cacheMisses.Add(1)
		}
	}
	return msg, meta, ok
}

// cachePut stores resp in the cache, clamping its answer TTLs to [TTLMin, TTLMax].
// Safe to call when h.Cache == nil.  Only caches successful (NOERROR) responses;
// SERVFAIL / REFUSED / etc. are not cached.
func (h *Handler) cachePut(name string, qtype uint16, resp *dns.Msg, epoch uint64) {
	h.cachePutWithMetadata(name, qtype, resp, epoch, cacheMetadata{})
}

func (h *Handler) cachePutWithMetadata(name string, qtype uint16, resp *dns.Msg, epoch uint64, meta cacheMetadata) {
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
		h.Cache.PutAtEpochWithMetadata(name, qtype, resp, h.TTLMin, epoch, meta)
		return
	}
	ttl := minAnswerTTL(resp, h.TTLMin, h.TTLMax)
	h.Cache.PutAtEpochWithMetadata(name, qtype, resp, ttl, epoch, meta)
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

// clampTTL clamps v to [lo, hi] (in seconds ? uint32).
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

// isPanelDomain reports whether name (an FQDN) is one of the configured mihomo
// panel domains (ConsoleDomain / ZashDomain), compared case-insensitively with
// trailing dots normalised away. An empty configured domain never matches, so a
// box with no panel domains set falls through to normal resolution.
func (h *Handler) isPanelDomain(name string) bool {
	bare := stripDot(name)
	if h.ConsoleDomain != "" && strings.EqualFold(bare, stripDot(h.ConsoleDomain)) {
		return true
	}
	if h.ZashDomain != "" && strings.EqualFold(bare, stripDot(h.ZashDomain)) {
		return true
	}
	return false
}
