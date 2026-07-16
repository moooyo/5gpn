package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/miekg/dns"
)

// ErrTGBotUnavailable is returned by GetTGBot/SetTGBot when no bot supervisor is
// wired (e.g. tests) so the HTTP layer maps it to a 503 rather than panicking.
var ErrTGBotUnavailable = errors.New("telegram bot management unavailable")

// ErrPolicyRulesUnavailable is returned by the policy-rule-facing Controller
// methods when no PolicyRuleManager is wired (a malformed policy.json at
// boot — see NewPolicyRuleManager in main.go — is warn-and-continue, like
// every other optional store). Mirrors ErrTGBotUnavailable: getters
// nil-degrade to an empty result instead, so only mutators/
// ApplyPolicy return this sentinel. ApplyPolicy also returns it when
// c.policyEngine specifically is nil (a PolicyRuleManager can be wired
// without an engine, e.g. before the boot-time engine construction step, or
// in tests exercising only CRUD).
var ErrPolicyRulesUnavailable = errors.New("policy rule management unavailable")

// Stats is a point-in-time snapshot of engine reason counters plus the
// current cache size. It is the read model the Phase-3 HTTP API will expose.
type Stats struct {
	Total           uint64 `json:"total"`
	Block           uint64 `json:"block"`
	ForceDirect     uint64 `json:"force_direct"`
	Blacklist       uint64 `json:"blacklist"`
	ChnrouteCN      uint64 `json:"chnroute_cn"`
	ChnrouteForeign uint64 `json:"chnroute_foreign"`
	CacheEntries    int    `json:"cache_entries"`
	ChinaOK         uint64 `json:"china_ok"`
	ChinaErr        uint64 `json:"china_err"`
	TrustOK         uint64 `json:"trust_ok"`
	TrustErr        uint64 `json:"trust_err"`
	// Observability: cache effectiveness + per-group upstream latency. Hits/
	// misses are cumulative; the *AvgMs are derived (latency-sum/count) so a
	// degraded china or trust leg is visible as a rising average.
	CacheHits   uint64  `json:"cache_hits"`
	CacheMisses uint64  `json:"cache_misses"`
	ChinaAvgMs  float64 `json:"china_avg_ms"`
	TrustAvgMs  float64 `json:"trust_avg_ms"`
}

// Controller is a thin facade over subscription management, manual rule-list
// editing, reload, and stats — the single surface the Phase-3 HTTP API (and
// tgbot) will call into. It holds no independent state of its own beyond what
// it needs to delegate: the SubManager, the reload callback, the manual rules
// directory, and read-only handles into the engine's live counters/cache.
type Controller struct {
	subs     *SubManager
	reload   func() error
	rulesDir string
	stats    *statsCounters
	cacheLen func() int

	// certStatusFn, when set, returns the TLS-cert expiry view for /status and
	// the bot status. nil when no TLS listener / cert monitor is wired.
	certStatusFn func() (CertStatus, bool)

	// handler gives Lookup access to the live engine (classifyName, the
	// China/Trust exchangers, CN, GatewayIP, Timeout) so a manual lookup can
	// reuse the exact same decision/arbitration path as the query pipeline.
	// May be nil (e.g. in tests exercising only subscription/rule-list
	// behavior); Lookup on a nil handler returns a zero-value LookupResult.
	handler *Handler

	// upstreamsApply, when set (SetUpstreamsApply, wired in main), rebuilds +
	// hot-swaps the live china/trust groups and persists them to
	// upstreams.json. nil means the upstream API is unavailable (tests).
	upstreamsApply func(china, trust []string) error

	// ecsFile, when set (SetECSFile, wired in main), is where SetChinaECS
	// persists the china-group ECS subnet (/etc/5gpn/ecs.json). Empty means
	// changes apply live but are not persisted (tests).
	ecsFile string

	// tgbot, when set (SetTGBotManager, wired in main), manages the in-process
	// Telegram bot's lifecycle so its token + admin set can be viewed and
	// hot-reloaded from the web console. nil means the tgbot API is unavailable
	// (tests / a build with the bot supervisor not wired).
	tgbot tgbotManager

	// policyRules/policyEngine, when set (SetPolicyEngine, wired in main),
	// hold the unified policy-rule store (policy_rules.go) and the engine
	// that compiles + applies it end-to-end (policy_engine.go). Both are nil
	// until wired; policyRules alone may be non-nil (a PolicyRuleManager can
	// exist before the engine that consumes it does, e.g. in tests exercising
	// only CRUD) — the CRUD facade methods below check policyRules,
	// ApplyPolicy checks policyEngine specifically.
	policyRules  *PolicyRuleManager
	policyEngine *PolicyEngine
}

// tgbotManager is the subset of the bot supervisor the Controller drives:
// read the current (token-redacted) config and apply a new one. Defined as an
// interface so controller_test.go can exercise the API without a live bot.
type tgbotManager interface {
	View() TGBotView
	Apply(tokenPtr *string, admins []int64) error
}

// NewController constructs a Controller. Any of subs, stats, or cacheLen may
// be nil (e.g. in tests exercising only a subset of behavior). subs/rulesDir
// are retained on the struct for construction compatibility (see the NOTE at
// the (now-removed) subscription facade above) but, since UP-1 Task D3, no
// Controller method reads either field — the policy engine drives the
// SubManager directly instead.
// handler wires Lookup to the live engine; it may be nil if Lookup is never
// called (e.g. in tests exercising only a subset of Controller's behavior).
func NewController(subs *SubManager, reload func() error, rulesDir string, stats *statsCounters, cacheLen func() int, handler *Handler) *Controller {
	return &Controller{
		subs:     subs,
		reload:   reload,
		rulesDir: rulesDir,
		stats:    stats,
		cacheLen: cacheLen,
		handler:  handler,
	}
}

// SetCertStatusFn wires the TLS-cert expiry source (the certMonitor). Optional;
// unset means CertStatus reports ok=false.
func (c *Controller) SetCertStatusFn(fn func() (CertStatus, bool)) {
	c.certStatusFn = fn
}

// CertStatus returns the current TLS-cert expiry view. ok is false when no cert
// monitor is wired or no cert has been read yet.
func (c *Controller) CertStatus() (CertStatus, bool) {
	if c.certStatusFn == nil {
		return CertStatus{}, false
	}
	return c.certStatusFn()
}

// SetUpstreamsApply wires the upstream hot-swap hook (build new groups → swap
// into the handler → persist to upstreams.json). Optional; unset means
// SetUpstreams returns an error.
func (c *Controller) SetUpstreamsApply(fn func(china, trust []string) error) {
	c.upstreamsApply = fn
}

// SetTGBotManager wires the Telegram-bot supervisor (main) so GetTGBot/SetTGBot
// have something to delegate to. Unset ⇒ the tgbot API reports unavailable.
func (c *Controller) SetTGBotManager(m tgbotManager) {
	c.tgbot = m
}

// GetTGBot returns the current (token-redacted) bot config for GET /api/tgbot.
// A Controller with no wired manager reports an empty, not-running view.
func (c *Controller) GetTGBot() TGBotView {
	if c.tgbot == nil {
		return TGBotView{AdminIDs: []int64{}, State: botStateDisabled}
	}
	v := c.tgbot.View()
	if v.AdminIDs == nil {
		v.AdminIDs = []int64{}
	}
	// Preserve compatibility with alternate/test managers written before the
	// explicit health state was added while keeping the API state non-empty.
	if v.State == "" {
		switch {
		case v.Running:
			v.State = botStateHealthy
		case v.TokenSet:
			v.State = botStateDegraded
		default:
			v.State = botStateDisabled
		}
	}
	return v
}

// SetTGBot applies a new bot config from PUT /api/tgbot: tokenPtr nil keeps the
// current token (admins-only edit), non-nil sets it ("" disables the bot). The
// supervisor validates the token (getMe), hot-restarts the bot, and persists to
// tgbot.json. A nil manager returns ErrTGBotUnavailable (mapped to 503).
func (c *Controller) SetTGBot(tokenPtr *string, admins []int64) error {
	if c.tgbot == nil {
		return ErrTGBotUnavailable
	}
	return c.tgbot.Apply(tokenPtr, admins)
}

// UpstreamsView is the read model for GET /api/upstreams: the raw upstream
// specs the live groups were built from.
type UpstreamsView struct {
	China []string `json:"china"`
	Trust []string `json:"trust"`
}

// GetUpstreams returns the raw specs of the live upstream groups. Falls back
// to empty lists on a Controller without a live handler snapshot (tests).
func (c *Controller) GetUpstreams() UpstreamsView {
	v := UpstreamsView{China: []string{}, Trust: []string{}}
	if c.handler == nil {
		return v
	}
	if snap := c.handler.upstreamSnap(); snap != nil {
		v.China = append(v.China, snap.ChinaRaw...)
		v.Trust = append(v.Trust, snap.TrustRaw...)
	}
	return v
}

// SetUpstreams validates the given upstream spec lists and applies them via
// the wired hook: the live groups are rebuilt and hot-swapped (no restart) and
// the config is persisted to upstreams.json. Validation failures wrap
// ErrInvalidUpstream (a 400 at the HTTP layer).
func (c *Controller) SetUpstreams(china, trust []string) error {
	// Validate BEFORE the availability check so a caller mistake is always a
	// 400 at the HTTP layer, independent of how the server was wired.
	china = normalizeUpstreamList(china)
	trust = normalizeUpstreamList(trust)
	if err := ValidateUpstreams(china, trust); err != nil {
		return err
	}
	if c.upstreamsApply == nil {
		return errors.New("upstream management unavailable")
	}
	return c.upstreamsApply(china, trust)
}

// SetECSFile wires the ECS persistence path (main). Optional; unset means
// SetChinaECS applies live without persisting.
func (c *Controller) SetECSFile(path string) {
	c.ecsFile = path
}

// ChinaECS returns the CIDR the live china group currently attaches as EDNS
// Client Subnet ("" when disabled or no live handler).
func (c *Controller) ChinaECS() string {
	if c.handler == nil {
		return ""
	}
	china, _ := c.handler.exchangers()
	return ecsSubnetString(GetGroupECS(china))
}

// SetChinaECS validates + normalises raw (bare IPv4 → its /24; a CIDR is
// honoured as written; "" disables ECS), applies it to the LIVE china group,
// flushes the response cache (cached CN answers were CDN-scheduled against
// the old subnet), and persists it to the ecs override file. Returns the
// normalised CIDR ("" when disabled). Validation failures wrap ErrInvalidECS
// (a 400 at the HTTP layer); a persist failure leaves the change live and
// reports it — better applied-but-not-durable than silently ignored.
func (c *Controller) SetChinaECS(raw string) (string, error) {
	subnet, err := parseECS(raw)
	if err != nil {
		return "", err
	}
	if c.handler != nil {
		china, _ := c.handler.exchangers()
		SetGroupECS(china, subnet)
		c.handler.Cache.Flush() // nil-safe
	}
	s := ecsSubnetString(subnet)
	if err := SaveECSFile(c.ecsFile, s); err != nil {
		return s, fmt.Errorf("applied live, but persisting failed (will revert on restart): %w", err)
	}
	return s, nil
}

// QueryLog returns recent query-log entries (newest first) whose name/client
// matches q (empty q = all), capped at limit. Empty when no handler or no
// query log is wired.
func (c *Controller) QueryLog(q string, limit int) []QueryLogEntry {
	if c.handler == nil || c.handler.qlog == nil {
		return []QueryLogEntry{}
	}
	entries := c.handler.qlog.search(q, limit, time.Now())
	if entries == nil {
		entries = []QueryLogEntry{}
	}
	return entries
}

// NOTE (UP-1 Task D3): the operator-facing subscription facade
// (Subscriptions/SubscriptionHealth/SubscriptionsWithHealth/SubscriptionView/
// AddSubscription/RemoveSubscription/ReplaceSubscription/
// ValidateSubscription/GetSubscription/Update) was REMOVED here — the
// managed-DNS-subscription HTTP surface it backed (/api/subscriptions*,
// /api/update) is gone, absorbed by the unified policy-rule model
// (policy_rules.go/policy_engine.go). c.subs (the SubManager) is still held
// on Controller (kept for construction compatibility / a possible future
// read-only fetch-health view — see R3 in
// docs/superpowers/plans/2026-07-15-up1-policy-engine.md) but no Controller
// method reads it anymore: the policy engine drives the SAME SubManager
// directly (Sync/UpdateAll — see PolicyEngine.CompileAndApply in
// policy_engine.go and the subs field it holds independently), never
// through this facade.

// Reload rebuilds the rule sets from disk and atomically swaps them into the
// live engine.
func (c *Controller) Reload() error {
	return c.reload()
}

// LookupResult is the outcome of a manual (control-plane) name lookup: the
// same verdict/reason vocabulary as the query pipeline (see Verdict), plus
// the IPs the lookup observed and which upstream group produced them (for
// the default/arbitrated case only).
type LookupResult struct {
	Name     string   `json:"name"`
	Verdict  string   `json:"verdict"`
	Reason   string   `json:"reason"`
	IPs      []string `json:"ips"`
	Upstream string   `json:"upstream"`
}

// Lookup runs the same classification the query pipeline uses for name, for
// operator/API introspection (e.g. "why would this domain resolve the way it
// does").  It never touches the cache and always performs a fresh lookup.
//
//   - block/force-direct/blacklist: classifyName's terminal verdict is
//     returned as-is; block and blacklist never call an upstream (IPs empty).
//     force-direct does need real IPs, so it arbitrates (as resolve does) and
//     reports them un-rewritten under reason "force-direct".
//   - default case (classifyName returns the zero Verdict): resolve the name
//     via Arbitrate (the same china/trust race resolve uses) and classify the
//     resulting IPs against CN: any CN-member IP → direct/chnroute-cn (IPs =
//     the resolved IPs, as the client would see them kept as-is); otherwise →
//     proxy/chnroute-foreign (IPs = the real resolved IPs, which is what a
//     live query would rewrite to GatewayIP — reported here unrewritten so an
//     operator can see the actual upstream answer being classified).
//
// Lookup on a Controller constructed with a nil handler (e.g. a test
// exercising only subscription/rule-list behavior) returns a zero-value
// LookupResult.
func (c *Controller) Lookup(ctx context.Context, name string) LookupResult {
	if c.handler == nil {
		return LookupResult{}
	}
	h := c.handler

	decision := h.decideName(name)
	verdict := decision.Verdict

	// Load the rule snapshot once (atomic; never the racy public h.CN field) and
	// thread cn through lookupArbitrate so a concurrent reload cannot race this
	// read. classifyName above loads its own snapshot, mirroring resolve().
	_, _, _, cn := h.ruleSnap()

	switch decision.Action {
	case actionBlock:
		return LookupResult{Name: name, Verdict: verdict.Verdict, Reason: verdict.Reason}
	case actionGateway:
		return LookupResult{Name: name, Verdict: verdict.Verdict, Reason: verdict.Reason}
	case actionDirect:
		ips, upstream := h.lookupArbitrate(ctx, name, cn)
		return LookupResult{Name: name, Verdict: verdict.Verdict, Reason: verdict.Reason, IPs: ips, Upstream: upstream}
	}

	// Default case: resolve via the engine and classify the IPs against CN.
	ips, upstream := h.lookupArbitrate(ctx, name, cn)
	if len(ips) == 0 {
		return LookupResult{Name: name, Verdict: "", Reason: "", Upstream: upstream}
	}

	for _, ipStr := range ips {
		if ip := net.ParseIP(ipStr); ip != nil && cn.Contains(ip) {
			return LookupResult{Name: name, Verdict: "direct", Reason: "chnroute-cn", IPs: ips, Upstream: upstream}
		}
	}
	return LookupResult{Name: name, Verdict: "proxy", Reason: "chnroute-foreign", IPs: ips, Upstream: upstream}
}

// lookupArbitrate builds a synthetic A query for name, runs it through the
// same Arbitrate race resolve uses, and returns the resolved IPv4 addresses
// (as dotted strings, in Answer order) plus which upstream group's answer was
// used ("china" if the china reply's IPs were returned, "trust" otherwise —
// mirroring Arbitrate's decision rule). Returns (nil, "") on any error/nil
// reply/empty answer. cn is the chnroute snapshot the caller loaded (never the
// mutable public h.CN field) so this cannot race a concurrent reload; the
// upstream pair is loaded via the same atomic snapshot the query path uses
// (exchangers), so a concurrent hot swap cannot race this either.
func (h *Handler) lookupArbitrate(ctx context.Context, name string, cn *Chnroute) ([]string, string) {
	fqdn := dns.Fqdn(name)
	q := new(dns.Msg)
	q.SetQuestion(fqdn, dns.TypeA)

	china, trust := h.exchangers()
	resp, upstream, err := arbitrateSrc(ctx, q, china, trust, cn, h.stats)
	if err != nil || resp == nil {
		return nil, ""
	}

	var ips []string
	for _, rr := range resp.Answer {
		if a, ok := rr.(*dns.A); ok {
			ips = append(ips, a.A.String())
		}
	}
	if len(ips) == 0 {
		return nil, upstream
	}
	return ips, upstream
}

// Stats returns a snapshot of the engine's reason counters and current cache
// size. Safe to call even when the Controller was constructed with nil
// stats/cacheLen (e.g. in tests) — the corresponding fields are left at zero.
func (c *Controller) Stats() Stats {
	var s Stats
	if c.stats != nil {
		s.Total = c.stats.total.Load()
		s.Block = c.stats.block.Load()
		s.ForceDirect = c.stats.forceDirect.Load()
		s.Blacklist = c.stats.blacklist.Load()
		s.ChnrouteCN = c.stats.chnrouteCN.Load()
		s.ChnrouteForeign = c.stats.chnrouteForeign.Load()
		s.ChinaOK = c.stats.chinaOK.Load()
		s.ChinaErr = c.stats.chinaErr.Load()
		s.TrustOK = c.stats.trustOK.Load()
		s.TrustErr = c.stats.trustErr.Load()
		s.CacheHits = c.stats.cacheHits.Load()
		s.CacheMisses = c.stats.cacheMisses.Load()
		s.ChinaAvgMs = avgMs(c.stats.chinaLatNanos.Load(), c.stats.chinaLatCount.Load())
		s.TrustAvgMs = avgMs(c.stats.trustLatNanos.Load(), c.stats.trustLatCount.Load())
	}
	if c.cacheLen != nil {
		s.CacheEntries = c.cacheLen()
	}
	return s
}

// avgMs returns the mean of a nanosecond sum over count, in milliseconds, or 0
// when count is 0 (no samples yet).
func avgMs(sumNanos, count uint64) float64 {
	if count == 0 {
		return 0
	}
	return float64(sumNanos) / float64(count) / 1e6
}

// NOTE (UP-1 Task D3): the manual-rule facade (manualRulePath/ListRules/
// ListAllRules/AddRule/RemoveRule/readRuleLines/normalizeRuleEntry) was
// REMOVED here — the /api/rules/{cat} HTTP surface it backed is gone,
// absorbed by the unified policy-rule model (policy_rules.go's
// PolicyRuleManager + policy_engine.go's writeManualFiles, which now OWNS
// the manual "<category>[.<matchtype>].txt" files as compiled artifacts).
// isValidRuleDomain is KEPT below — policy_rules.go's validateMatcher still
// calls it directly for domain-shaped matcher validation.

// isValidRuleDomain reports whether entry looks like a plausible FQDN: after
// trimming whitespace, non-empty, no internal whitespace, contains at least
// one '.', and every label is non-empty (rejects "..", leading/trailing dot
// once trimmed of a single trailing "." per normalizeDomain semantics).
func isValidRuleDomain(entry string) bool {
	entry = strings.TrimSpace(entry)
	if entry == "" {
		return false
	}
	if strings.ContainsAny(entry, " \t\r\n") {
		return false
	}
	d := normalizeDomain(entry)
	if d == "" || !strings.Contains(d, ".") {
		return false
	}
	for _, label := range strings.Split(d, ".") {
		if label == "" {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Policy rules (the unified policy-rule engine's console facade)
// ---------------------------------------------------------------------------

// SetPolicyEngine wires the unified policy-rule store (policy_rules.go's
// PolicyRuleManager) and the engine that compiles + applies it end-to-end
// (policy_engine.go's PolicyEngine). Unset (or eng left nil) means:
// GetPolicyRules/GetPolicyFallback nil-degrade to an empty/zero result,
// every mutator returns ErrPolicyRulesUnavailable, and ApplyPolicy returns
// ErrPolicyRulesUnavailable too — mirroring SetTGBotManager's nil-degrade
// convention. mgr and eng are independent: a manager can be wired with a nil
// engine (e.g. tests exercising only CRUD, or a boot ordering where the
// engine hasn't been constructed yet) — only ApplyPolicy requires the engine
// specifically.
func (c *Controller) SetPolicyEngine(mgr *PolicyRuleManager, eng *PolicyEngine) {
	c.policyRules = mgr
	c.policyEngine = eng
}

// PolicyRules returns the current policy rules in evaluation order. Empty
// (never nil) when no PolicyRuleManager is wired.
func (c *Controller) PolicyRules() []PolicyRule {
	if c.policyRules == nil {
		return []PolicyRule{}
	}
	return c.policyRules.Rules()
}

// AddPolicyRule validates, persists, and returns the created rule (with its
// minted ID). Returns ErrPolicyRulesUnavailable when no PolicyRuleManager is
// wired. Binary policy carries no selector, so (unlike the pre-decoupling
// design) there is no separate "egress unavailable" gate here anymore — a
// proxy-intent rule needs nothing beyond the intent enum + matcher shape.
func (c *Controller) AddPolicyRule(r PolicyRule) (PolicyRule, error) {
	if c.policyRules == nil {
		return PolicyRule{}, ErrPolicyRulesUnavailable
	}
	return c.policyRules.AddRule(r)
}

// UpdatePolicyRule replaces the rule with the given id. Returns
// ErrPolicyRulesUnavailable when no PolicyRuleManager is wired.
func (c *Controller) UpdatePolicyRule(id string, r PolicyRule) (PolicyRule, error) {
	if c.policyRules == nil {
		return PolicyRule{}, ErrPolicyRulesUnavailable
	}
	return c.policyRules.UpdateRule(id, r)
}

// DeletePolicyRule removes the rule with the given id. Returns
// ErrPolicyRulesUnavailable when no PolicyRuleManager is wired.
func (c *Controller) DeletePolicyRule(id string) error {
	if c.policyRules == nil {
		return ErrPolicyRulesUnavailable
	}
	return c.policyRules.DeleteRule(id)
}

// ReorderPolicyRules rewrites the evaluation order to match ids exactly.
// Returns ErrPolicyRulesUnavailable when no PolicyRuleManager is wired.
func (c *Controller) ReorderPolicyRules(ids []string) error {
	if c.policyRules == nil {
		return ErrPolicyRulesUnavailable
	}
	return c.policyRules.Reorder(ids)
}

// GetPolicyFallback returns the current fallback policy. Zero value when no
// PolicyRuleManager is wired.
func (c *Controller) GetPolicyFallback() Fallback {
	if c.policyRules == nil {
		return Fallback{}
	}
	return c.policyRules.GetFallback()
}

// SetPolicyFallback validates and persists a new fallback policy. Returns
// ErrPolicyRulesUnavailable when no PolicyRuleManager is wired.
func (c *Controller) SetPolicyFallback(f Fallback) error {
	if c.policyRules == nil {
		return ErrPolicyRulesUnavailable
	}
	return c.policyRules.SetFallback(f)
}

// ApplyPolicy compiles the current PolicyModel and applies it end-to-end
// (manual rule files, subscriptions, the fallback switch — see
// PolicyEngine.CompileAndApply). There is no mihomo side to this apply
// anymore (2026-07-15 policy/mihomo decoupling). Returns
// ErrPolicyRulesUnavailable when no PolicyEngine is wired (a PolicyRuleManager
// alone is not enough — CompileAndApply is a PolicyEngine method).
func (c *Controller) ApplyPolicy(ctx context.Context) error {
	if c.policyEngine == nil {
		return ErrPolicyRulesUnavailable
	}
	return c.policyEngine.CompileAndApply(ctx)
}
