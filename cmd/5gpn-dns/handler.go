package main

import (
	"context"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/miekg/dns"
)

// ruleSnapshot is the reloadable portion of a Handler.
// SIGHUP replaces the whole snapshot atomically; in-flight queries
// that already loaded the old snapshot complete safely.
type ruleSnapshot struct {
	CN *Chnroute
}

// statsCounters holds per-reason query counters, updated with atomics so
// they can be bumped from the hot query path without a mutex. All fields are
// accessed via sync/atomic; zero value is valid (all counters start at 0).
// A nil *statsCounters is valid too ? callers must guard increments (see
// Handler.bump*) so Handlers built without stats wiring (e.g. existing unit
// tests that construct a Handler literal) never panic.
//
// Reason-level counters distinguish explicit policy decisions from automatic
// chnroute arbitration:
//   - block:           step-3 block match (verdict "block").
//   - forceDirect:     step-4 name-only "always direct" match (verdict "direct").
//   - forceProxy:      explicit proxy-intent match (verdict "proxy").
//   - chnrouteCN:      step-6 default path, resolved IP is a CN address kept as-is (verdict "direct").
//   - chnrouteForeign: step-6 default path, resolved IP was foreign and rewritten to GatewayIP (verdict "proxy").
type statsCounters struct {
	total           atomic.Uint64
	block           atomic.Uint64
	forceDirect     atomic.Uint64
	forceProxy      atomic.Uint64
	chnrouteCN      atomic.Uint64
	chnrouteForeign atomic.Uint64
	// china/trust ok/err are OBSERVABILITY-ONLY (see the note above the routing
	// decision in Arbitrate): exposed via status/dashboard/bot and persisted,
	// but they MUST NOT feed the china-vs-trust decision, which is deterministic by
	// chnroute membership ? never health/speed. They are also per-group and
	// asymmetric (trust counted only when consulted), so unfit to drive selection.
	chinaOK  atomic.Uint64
	chinaErr atomic.Uint64
	trustOK  atomic.Uint64
	trustErr atomic.Uint64

	// Observability-only (like the china/trust ok/err counters): cache
	// effectiveness and per-group upstream latency, exposed via status and
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

// Handler is a dns.Handler that implements the ordered 5gpn DNS policy.
type Handler struct {
	// rules is swapped atomically on SIGHUP.
	rules atomic.Pointer[ruleSnapshot]

	// ups is the hot-swappable upstream state (PUT /api/upstreams). Like
	// rules, a nil pointer falls back to the public China/Trust fields for
	// test-constructed Handlers; main publishes the initial snapshot at boot.
	ups atomic.Pointer[upstreamSnapshot]

	// orderedPolicy is the globally ordered first-match policy snapshot.
	orderedPolicy       atomic.Pointer[runtimePolicySnapshot]
	policyPlan          atomic.Pointer[runtimePolicyPlan]
	policyRefreshPaused atomic.Bool

	// interceptHosts is a system-owned overlay published only after an explicit
	// interception-module transaction has installed the matching certificate
	// and mihomo rules. It is evaluated before the operator policy so a module
	// cannot be enabled while its declared capture host still resolves directly.
	interceptHosts atomic.Pointer[interceptHostSnapshot]

	// CN is a construction-time test seam. Runtime publishes it through
	// swapRuleSets before serving.
	CN *Chnroute // IPv4 china ranges.

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

	// flights coalesces concurrent cache misses for the same request profile.
	// The map is capacity-bounded independently of admission control so a
	// random-name flood cannot turn request coalescing into an unbounded map.
	flightMu    sync.Mutex
	flights     map[dnsFlightKey]*dnsFlight
	flightLimit int

	// afterCacheEpoch is a test seam for changes that land after a resolver
	// captures the cache epoch but before it loads any runtime snapshots.
	afterCacheEpoch func()
}

const defaultDNSFlightLimit = 1024

// dnsFlightKey contains every request property that can affect the response,
// plus the exact runtime snapshots used by the leader. Snapshot identity keeps
// a reload boundary from coalescing an old-policy query with a new-policy one.
type dnsFlightKey struct {
	name             string
	qtype            uint16
	qclass           uint16
	dnssecOK         bool
	checkingDisabled bool
	epoch            uint64
	policy           *runtimePolicySnapshot
	rules            *ruleSnapshot
	upstreams        *upstreamSnapshot
	action           resolutionAction
}

type dnsFlightScope struct {
	epoch     uint64
	policy    *runtimePolicySnapshot
	rules     *ruleSnapshot
	upstreams *upstreamSnapshot
	action    resolutionAction
}

type dnsFlightResult struct {
	msg  *dns.Msg
	info resolveInfo
}

type dnsFlight struct {
	done   chan struct{}
	result dnsFlightResult
}

type runtimePolicyPlan struct {
	Model    PolicyModel
	RulesDir string
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

// bumpForceProxy increments the explicit proxy-reason counter.
func (h *Handler) bumpForceProxy() {
	if h.stats == nil {
		return
	}
	h.stats.forceProxy.Add(1)
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
// Every chnroute/subscription cache reload funnels through here, so this is the single
// point at which the response cache must be invalidated (see Cache.Flush): the
// cache holds fully-rewritten answers, so a rule change that is not accompanied
// by a flush would keep serving pre-change answers until TTL expiry (up to 24h).
// The initial publish at startup flushes an empty cache (a no-op).
func (h *Handler) swapRuleSets(cn *Chnroute) {
	snap := &ruleSnapshot{CN: cn}
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

// chnroute returns the live atomic snapshot, or the construction-time test
// seam when no snapshot was published.
func (h *Handler) chnroute() *Chnroute {
	if snap := h.rules.Load(); snap != nil {
		return snap.CN
	}
	return h.CN
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
// "block"|"force-direct"|"force-proxy"|"chnroute-cn"|"chnroute-foreign"|
// "fallback-direct"|"fallback-gateway" (the latter two are unmatched-name
// outcomes under the ordered snapshot's fallback policy).
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
	snap    *runtimePolicySnapshot
}

// decideName is the shared policy decision used by live resolution, Lookup,
// and ResolveTest. It folds the ordered name rule and the configured fallback
// into one executable action so diagnostics cannot silently ignore fallback.
func (h *Handler) decideName(name string) resolutionDecision {
	if snapshot := h.interceptHosts.Load(); snapshot != nil && snapshot.Match(name) {
		return resolutionDecision{
			Verdict: Verdict{Verdict: "proxy", Reason: "force-proxy"},
			Action:  actionGateway,
			snap:    h.orderedPolicy.Load(),
		}
	}
	snap := h.orderedPolicy.Load()
	v := classifyPolicySnapshot(snap, name)
	switch v.Reason {
	case "block":
		return resolutionDecision{Verdict: v, Action: actionBlock, snap: snap}
	case "force-direct":
		return resolutionDecision{Verdict: v, Action: actionDirect, snap: snap}
	case "force-proxy":
		return resolutionDecision{Verdict: v, Action: actionGateway, snap: snap}
	}
	fallback := FallbackAuto
	if snap != nil {
		fallback = snap.Fallback
	}
	switch fallback {
	case FallbackDirect:
		return resolutionDecision{Verdict: Verdict{Verdict: "direct", Reason: "fallback-direct"}, Action: actionDirect, snap: snap}
	case FallbackGateway:
		return resolutionDecision{Verdict: Verdict{Verdict: "proxy", Reason: "fallback-gateway"}, Action: actionGateway, snap: snap}
	default:
		return resolutionDecision{Action: actionAuto, snap: snap}
	}
}

type interceptHostSnapshot struct {
	exact    map[string]interceptHostBinding
	wildcard []interceptWildcardBinding
}

type interceptHostBinding struct {
	moduleID   string
	captureDNS string
	order      int
}

type interceptWildcardBinding struct {
	suffix  string
	binding interceptHostBinding
}

func newInterceptHostSnapshot(document interceptConfigDocument) *interceptHostSnapshot {
	snapshot := &interceptHostSnapshot{exact: make(map[string]interceptHostBinding)}
	if !document.MITM.Enabled {
		return snapshot
	}
	seenWildcard := make(map[string]struct{})
	for order, module := range orderedInterceptModules(document) {
		if !module.Enabled {
			continue
		}
		binding := interceptHostBinding{
			moduleID:   module.ID,
			captureDNS: module.CaptureDNS,
			order:      order,
		}
		for _, pattern := range module.CaptureHosts {
			pattern = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(pattern), "."))
			if strings.HasPrefix(pattern, "*.") {
				suffix := strings.TrimPrefix(pattern, "*.")
				if _, exists := seenWildcard[suffix]; !exists {
					seenWildcard[suffix] = struct{}{}
					snapshot.wildcard = append(snapshot.wildcard, interceptWildcardBinding{suffix: suffix, binding: binding})
				}
				continue
			}
			if pattern != "" {
				if _, exists := snapshot.exact[pattern]; !exists {
					snapshot.exact[pattern] = binding
				}
			}
		}
	}
	return snapshot
}

func (s *interceptHostSnapshot) Match(name string) bool {
	_, _, matched := s.CaptureDNS(name)
	return matched
}

// CaptureDNS returns the operator-selected resolver group and the owning
// extension for name. Bindings are evaluated in execution_order, so the first
// enabled extension that declared an overlapping capture host wins.
func (s *interceptHostSnapshot) CaptureDNS(name string) (resolver, moduleID string, matched bool) {
	if s == nil {
		return "", "", false
	}
	name = strings.ToLower(stripDot(name))
	exact, exactMatch := s.exact[name]
	for _, wildcard := range s.wildcard {
		if exactMatch && wildcard.binding.order >= exact.order {
			break
		}
		if len(name) > len(wildcard.suffix)+1 && strings.HasSuffix(name, "."+wildcard.suffix) {
			return wildcard.binding.captureDNS, wildcard.binding.moduleID, true
		}
	}
	if exactMatch {
		return exact.captureDNS, exact.moduleID, true
	}
	return "", "", false
}

func (h *Handler) setInterceptDocument(document *interceptConfigDocument) {
	if document == nil {
		h.interceptHosts.Store(&interceptHostSnapshot{})
	} else {
		h.interceptHosts.Store(newInterceptHostSnapshot(*document))
	}
	h.Cache.Flush()
}

func (h *Handler) captureDNSForName(name string) (resolver, moduleID string) {
	if snapshot := h.interceptHosts.Load(); snapshot != nil {
		if resolver, moduleID, matched := snapshot.CaptureDNS(name); matched {
			return resolver, moduleID
		}
	}
	return interceptCaptureDNSTrust, ""
}

func classifyPolicySnapshot(snap *runtimePolicySnapshot, name string) Verdict {
	if snap == nil {
		return Verdict{}
	}
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
			return Verdict{Verdict: "proxy", Reason: "force-proxy"}
		}
	}
	return Verdict{}
}

// ServeDNS implements dns.Handler. The miekg UDP/TCP/DoT path carries no client
// cancellation, so it dispatches with context.Background().
func (h *Handler) ServeDNS(w dns.ResponseWriter, r *dns.Msg) {
	h.serveContext(context.Background(), w, r)
}

// serveContext is the shared per-query entry for every transport. parent
// carries client cancellation where a caller provides it. It applies admission
// control, imposes the per-query deadline, resolves, and truncates UDP replies,
// then writes the result to w.
func (h *Handler) serveContext(parent context.Context, w dns.ResponseWriter, r *dns.Msg) {
	if len(r.Question) != 1 {
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeFormatError)
		_ = w.WriteMsg(m)
		return
	}
	if r.Question[0].Qclass != dns.ClassINET {
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeNotImplemented)
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
	// stream transports report Network()!="udp" and are left intact.
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

func newDNSFlightKey(q dns.Question, r *dns.Msg, scope dnsFlightScope) dnsFlightKey {
	opts := cacheOptionsFromMsg(r)
	return dnsFlightKey{
		name:             strings.ToLower(dns.Fqdn(q.Name)),
		qtype:            q.Qtype,
		qclass:           q.Qclass,
		dnssecOK:         opts.dnssecOK,
		checkingDisabled: opts.checkingDisabled,
		epoch:            scope.epoch,
		policy:           scope.policy,
		rules:            scope.rules,
		upstreams:        scope.upstreams,
		action:           scope.action,
	}
}

// coalesceResolution runs one detached, timeout-bounded resolution for all
// concurrent callers with the same key. A caller that is canceled stops
// waiting without canceling the shared resolution. When the distinct-key map
// is full, the caller resolves independently so capacity pressure cannot grow
// the map or block unrelated names.
func (h *Handler) coalesceResolution(
	ctx context.Context,
	q dns.Question,
	r *dns.Msg,
	scope dnsFlightScope,
	initial resolveInfo,
	resolve func(context.Context, *dns.Msg, *resolveInfo) *dns.Msg,
) (*dns.Msg, resolveInfo, bool) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, initial, false
	}

	template := new(dns.Msg)
	if r != nil {
		template = r.Copy()
	} else {
		template.Question = []dns.Question{q}
	}
	key := newDNSFlightKey(q, template, scope)
	limit := h.flightLimit
	if limit <= 0 {
		limit = defaultDNSFlightLimit
	}

	h.flightMu.Lock()
	flight := h.flights[key]
	leader := false
	if flight == nil && len(h.flights) < limit {
		if h.flights == nil {
			h.flights = make(map[dnsFlightKey]*dnsFlight)
		}
		flight = &dnsFlight{done: make(chan struct{})}
		h.flights[key] = flight
		leader = true
	}
	h.flightMu.Unlock()

	if flight == nil {
		info := initial
		msg := resolve(ctx, template, &info)
		return prepareFlightReply(msg, r), info, true
	}

	if leader {
		go func() {
			to := h.Timeout
			if to <= 0 {
				to = 5 * time.Second
			}
			runCtx, cancel := context.WithTimeout(context.Background(), to)
			defer cancel()

			info := initial
			flight.result = dnsFlightResult{
				msg:  resolve(runCtx, template, &info),
				info: info,
			}
			close(flight.done)

			h.flightMu.Lock()
			if h.flights[key] == flight {
				delete(h.flights, key)
			}
			h.flightMu.Unlock()
		}()
	}

	select {
	case <-flight.done:
		return prepareFlightReply(flight.result.msg, r), flight.result.info, true
	case <-ctx.Done():
		return nil, initial, false
	}
}

func prepareFlightReply(msg, request *dns.Msg) *dns.Msg {
	if msg == nil {
		return nil
	}
	reply := msg.Copy()
	prepareCachedReply(reply, request)
	return reply
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
//  5. force-proxy match   ? synthetic A = GatewayIP, no upstream.
//  6. default             ? ordered-policy fallback:
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

	// Capture the cache epoch BEFORE every runtime snapshot. If an upstream,
	// rule, or policy swap lands anywhere between here and the final cachePut,
	// the epoch mismatch discards the write. Loading any snapshot before the
	// epoch would let a request combine old runtime state with a post-flush
	// epoch and repopulate the new cache generation with a stale answer.
	epoch := h.Cache.Epoch()
	if h.afterCacheEpoch != nil {
		h.afterCacheEpoch()
	}

	// The upstream groups are hot-swappable (PUT /api/upstreams); load the
	// current pair and its identity once so one query never mixes groups from
	// two generations or shares a flight across a swap.
	upstreamGeneration := h.ups.Load()
	china, trust := h.China, h.Trust
	if upstreamGeneration != nil {
		china, trust = upstreamGeneration.China, upstreamGeneration.Trust
	}

	// Capture the current chnroute snapshot and identity once for
	// arbitration/rewrite and flight generation isolation.
	ruleGeneration := h.rules.Load()
	cn := h.CN
	if ruleGeneration != nil {
		cn = ruleGeneration.CN
	}

	// ?? Step 1: AAAA ? synthetic SOA, NOERROR, empty Answer ?????????????????
	if q.Qtype == dns.TypeAAAA {
		ri.noteVerdict(Verdict{Reason: "aaaa-synthetic"})
		return h.soaReply(r)
	}

	// ?? Step 2: HTTPS / SVCB ? synthetic NODATA (NOERROR + SOA) ??????????????
	// We deliberately refuse to serve HTTPS/SVCB (RFC 9460) records. Two reasons,
	// both load-bearing for the SNI-steering data plane:
	//   1. ECH: the HTTPS RR's `ech` SvcParam lets the client encrypt the TLS
	//      ClientHello SNI. Mihomo reads the plaintext hostname to recover
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

	// verdict carries the ordered name-only decision; a zero-value Verdict means
	// "default case, arbitrate+rewrite".
	decision := h.decideName(name)
	verdict := decision.Verdict
	flightScope := dnsFlightScope{
		epoch:     epoch,
		policy:    decision.snap,
		rules:     ruleGeneration,
		upstreams: upstreamGeneration,
		action:    decision.Action,
	}

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
			if cached, meta, ok := h.cacheGetForRequest(r, name, q.Qtype); ok {
				ri.noteUpstream(meta.Upstream)
				ri.noteCacheHit()
				return cached
			}
			// `direct` is transport-neutral policy: use the same china/trust
			// arbitration as the default path, then return the adopted answer
			// without gateway rewriting. A foreign domain explicitly marked direct
			// must therefore still work when china has no useful answer.
			initial := resolveInfo{}
			if ri != nil {
				initial = *ri
			}
			resp, info, ok := h.coalesceResolution(ctx, q, r, flightScope, initial, func(runCtx context.Context, flightReq *dns.Msg, flightInfo *resolveInfo) *dns.Msg {
				resolved, src, err := arbitrateSrc(runCtx, flightReq, china, trust, cn, h.stats)
				if err != nil || resolved == nil {
					return h.staleOrServerFail(flightReq, name, q.Qtype, flightInfo)
				}
				flightInfo.noteUpstream(src)
				resolved = filterAAAA(resolved)
				h.cachePutForRequest(flightReq, name, q.Qtype, resolved, flightScope.epoch, cacheMetadata{
					Verdict: verdict.Verdict, Reason: verdict.Reason, Upstream: src,
				})
				return resolved
			})
			if !ok || resp == nil {
				return h.serverFail(r)
			}
			if ri != nil {
				*ri = info
			}
			return resp
		}
		// Non-A direct ? forward to Trust verbatim.
		return h.forwardTrust(ctx, trust, q, r, flightScope, ri)
	}

	// Explicit proxy intent.
	if decision.Action == actionGateway {
		ri.noteVerdict(verdict)
		if isA {
			if verdict.Reason == "force-proxy" {
				h.bumpForceProxy()
			} else {
				h.bumpChnrouteForeign()
			}
			return h.gatewayReply(r)
		}
		// Non-A proxy intent: forward to Trust (steering is A-specific).
		return h.forwardTrust(ctx, trust, q, r, flightScope, ri)
	}

	// ?? Step 6: default ??????????????????????????????????????????????????????
	if isA {
		if cached, meta, ok := h.cacheGetForRequest(r, name, q.Qtype); ok {
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
		initial := resolveInfo{}
		if ri != nil {
			initial = *ri
		}
		resp, info, ok := h.coalesceResolution(ctx, q, r, flightScope, initial, func(runCtx context.Context, flightReq *dns.Msg, flightInfo *resolveInfo) *dns.Msg {
			resolved, src, err := arbitrateSrc(runCtx, flightReq, china, trust, cn, h.stats)
			if err != nil || resolved == nil {
				return h.staleOrServerFail(flightReq, name, q.Qtype, flightInfo)
			}
			flightInfo.noteUpstream(src)
			resolved = filterAAAA(resolved)
			resolved = h.rewriteA(resolved, flightReq, cn)
			resolvedVerdict := h.defaultVerdictOf(resolved)
			flightInfo.noteVerdict(resolvedVerdict)
			h.cachePutForRequest(flightReq, name, q.Qtype, resolved, flightScope.epoch, cacheMetadata{
				Verdict: resolvedVerdict.Verdict, Reason: resolvedVerdict.Reason, Upstream: src,
			})
			return resolved
		})
		if !ok || resp == nil {
			return h.serverFail(r)
		}
		if ri != nil {
			*ri = info
		}
		h.bumpDefaultVerdict(resp)
		return resp
	}

	// ?? All other qtypes: forward to Trust verbatim ??????????????????????????
	return h.forwardTrust(ctx, trust, q, r, flightScope, ri)
}

// ?? helpers ??????????????????????????????????????????????????????????????????

// forwardTrust sends q to the given trust exchanger and returns the reply
// verbatim. The result is cached.
func (h *Handler) forwardTrust(ctx context.Context, trust Exchanger, q dns.Question, r *dns.Msg, scope dnsFlightScope, ri *resolveInfo) *dns.Msg {
	name, qtype := q.Name, q.Qtype
	if ri != nil && ri.reason == "" {
		ri.reason = "forward-trust"
	}
	if cached, meta, ok := h.cacheGetForRequest(r, name, qtype); ok {
		if meta.Reason != "" {
			ri.noteVerdict(Verdict{Verdict: meta.Verdict, Reason: meta.Reason})
			ri.noteUpstream(meta.Upstream)
		}
		ri.noteCacheHit()
		return cached
	}
	initial := resolveInfo{}
	if ri != nil {
		initial = *ri
	}
	resp, info, ok := h.coalesceResolution(ctx, q, r, scope, initial, func(runCtx context.Context, flightReq *dns.Msg, flightInfo *resolveInfo) *dns.Msg {
		resolved, err := trust.Exchange(runCtx, flightReq)
		if err != nil || resolved == nil {
			return h.staleOrServerFail(flightReq, name, qtype, flightInfo)
		}
		flightInfo.noteUpstream("trust")
		meta := cacheMetadata{Upstream: "trust", Verdict: flightInfo.verdict, Reason: flightInfo.reason}
		h.cachePutForRequest(flightReq, name, qtype, resolved, scope.epoch, meta)
		return resolved
	})
	if !ok || resp == nil {
		return h.serverFail(r)
	}
	if ri != nil {
		*ri = info
	}
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
// instead of a bogus 0.0.0.0; an explicit proxy-intent name should fail closed, not
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
	if stale, meta, ok := h.cacheGetStaleForRequest(r, name, qtype); ok {
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
	return h.cacheGetStaleWithMetadataOptions(name, qtype, cacheOptions{})
}

func (h *Handler) cacheGetStaleWithMetadataOptions(name string, qtype uint16, opts cacheOptions) (*dns.Msg, cacheMetadata, bool) {
	if h.Cache == nil {
		return nil, cacheMetadata{}, false
	}
	return h.Cache.GetStaleWithMetadataOptions(name, qtype, staleReplyTTLSecs, opts)
}

func (h *Handler) cacheGetStaleForRequest(r *dns.Msg, name string, qtype uint16) (*dns.Msg, cacheMetadata, bool) {
	msg, meta, ok := h.cacheGetStaleWithMetadataOptions(name, qtype, cacheOptionsFromMsg(r))
	if ok {
		prepareCachedReply(msg, r)
	}
	return msg, meta, ok
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
	return h.cacheGetWithMetadataOptions(name, qtype, cacheOptions{})
}

func (h *Handler) cacheGetWithMetadataOptions(name string, qtype uint16, opts cacheOptions) (*dns.Msg, cacheMetadata, bool) {
	if h.Cache == nil {
		return nil, cacheMetadata{}, false
	}
	msg, meta, ok := h.Cache.GetWithMetadataOptions(name, qtype, opts)
	if h.stats != nil {
		if ok {
			h.stats.cacheHits.Add(1)
		} else {
			h.stats.cacheMisses.Add(1)
		}
	}
	return msg, meta, ok
}

func (h *Handler) cacheGetForRequest(r *dns.Msg, name string, qtype uint16) (*dns.Msg, cacheMetadata, bool) {
	msg, meta, ok := h.cacheGetWithMetadataOptions(name, qtype, cacheOptionsFromMsg(r))
	if ok {
		prepareCachedReply(msg, r)
	}
	return msg, meta, ok
}

func prepareCachedReply(cached, request *dns.Msg) {
	if cached == nil || request == nil {
		return
	}
	cached.Id = request.Id
	cached.Question = append(cached.Question[:0], request.Question...)
}

// cachePut stores resp in the cache, clamping its answer TTLs to [TTLMin, TTLMax].
// Safe to call when h.Cache == nil.  Only caches successful (NOERROR) responses;
// SERVFAIL / REFUSED / etc. are not cached.
func (h *Handler) cachePut(name string, qtype uint16, resp *dns.Msg, epoch uint64) {
	h.cachePutWithMetadata(name, qtype, resp, epoch, cacheMetadata{})
}

func (h *Handler) cachePutWithMetadata(name string, qtype uint16, resp *dns.Msg, epoch uint64, meta cacheMetadata) {
	h.cachePutWithMetadataOptions(name, qtype, cacheOptions{}, resp, epoch, meta)
}

func (h *Handler) cachePutForRequest(r *dns.Msg, name string, qtype uint16, resp *dns.Msg, epoch uint64, meta cacheMetadata) {
	h.cachePutWithMetadataOptions(name, qtype, cacheOptionsFromMsg(r), resp, epoch, meta)
}

func (h *Handler) cachePutWithMetadataOptions(name string, qtype uint16, opts cacheOptions, resp *dns.Msg, epoch uint64, meta cacheMetadata) {
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
		h.Cache.PutAtEpochWithMetadataOptions(name, qtype, opts, resp, h.TTLMin, epoch, meta)
		return
	}
	ttl := minAnswerTTL(resp, h.TTLMin, h.TTLMax)
	h.Cache.PutAtEpochWithMetadataOptions(name, qtype, opts, resp, ttl, epoch, meta)
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
