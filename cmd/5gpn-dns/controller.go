package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
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
	ForceProxy      uint64 `json:"force_proxy"`
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

// Controller is the in-process facade used by the HTTP API and Telegram bot.
type Controller struct {
	reload   func() error
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

	// interceptModules is the single transactional module registry shared by
	// the Web console and Telegram. Both control surfaces therefore publish the
	// same sidecar snapshot, certificate request, mihomo rules, and DNS overlay.
	interceptModules *InterceptModuleManager

	// extensionMarketplaces is the shared marketplace registry used by the Web
	// console and Telegram. Marketplace installation delegates to the same
	// InterceptModuleManager, preserving both marketplace and module CAS checks.
	extensionMarketplaces *ExtensionMarketplaceManager
}

// tgbotManager is the subset of the bot supervisor the Controller drives:
// read the current (token-redacted) config and apply a new one. Defined as an
// interface so controller_test.go can exercise the API without a live bot.
type tgbotManager interface {
	View() TGBotView
	Apply(tokenPtr *string, admins []int64) error
}

// NewController constructs a Controller. stats, cacheLen, and handler may be
// nil when the corresponding read surface is unavailable.
func NewController(reload func() error, stats *statsCounters, cacheLen func() int, handler *Handler) *Controller {
	return &Controller{
		reload:   reload,
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

// Reload rebuilds the rule sets from disk and atomically swaps them into the
// live engine.
func (c *Controller) Reload() error {
	return c.reload()
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
		s.ForceProxy = c.stats.forceProxy.Load()
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

func (c *Controller) SetInterceptModuleManager(manager *InterceptModuleManager) {
	c.interceptModules = manager
}

func (c *Controller) SetExtensionMarketplaceManager(manager *ExtensionMarketplaceManager) {
	c.extensionMarketplaces = manager
}

func (c *Controller) InterceptModules() (interceptModulesView, error) {
	if c.interceptModules == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.View()
}

func (c *Controller) InterceptSettings() (interceptSettingsView, error) {
	if c.interceptModules == nil {
		return interceptSettingsView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.SettingsView()
}

func (c *Controller) UpdateInterceptSettings(ctx context.Context, revision string, settings interceptMITMSettings) (interceptModulesView, error) {
	if c.interceptModules == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.UpdateSettings(ctx, revision, settings)
}

func (c *Controller) SetInterceptModuleEnabled(ctx context.Context, id, revision string, enabled bool) (interceptModulesView, error) {
	return c.UpdateInterceptModule(ctx, id, interceptModuleUpdate{Revision: revision, Enabled: &enabled})
}

func (c *Controller) InterceptModuleSnapshot(id string) (interceptModuleSnapshotView, error) {
	if c.interceptModules == nil {
		return interceptModuleSnapshotView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.Snapshot(id)
}

func (c *Controller) ImportInterceptModule(ctx context.Context, request interceptModuleImportRequest) (interceptModulesView, error) {
	if c.interceptModules == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.Import(ctx, request)
}

func (c *Controller) PreviewInterceptModuleImport(ctx context.Context, request interceptModuleImportRequest) (interceptModuleView, error) {
	if c.interceptModules == nil {
		return interceptModuleView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.PreviewImport(ctx, request)
}

func (c *Controller) ImportInterceptModuleExpected(
	ctx context.Context,
	request interceptModuleImportRequest,
	expectedSnapshotDigest string,
) (interceptModulesView, error) {
	if c.interceptModules == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.ImportExpected(ctx, request, expectedSnapshotDigest)
}

func (c *Controller) CheckInterceptModuleUpdate(ctx context.Context, id, revision string) (interceptModuleUpdateCheckView, error) {
	if c.interceptModules == nil {
		return interceptModuleUpdateCheckView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.CheckUpdate(ctx, id, revision)
}

func (c *Controller) ApplyInterceptModuleUpdate(ctx context.Context, id, revision, digest string) (interceptModulesView, error) {
	if c.interceptModules == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.ApplyUpdate(ctx, id, revision, digest)
}

func (c *Controller) DeleteInterceptModule(ctx context.Context, id, revision string) (interceptModulesView, error) {
	if c.interceptModules == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.Delete(ctx, id, revision)
}

func (c *Controller) UpdateInterceptModule(ctx context.Context, id string, update interceptModuleUpdate) (interceptModulesView, error) {
	if c.interceptModules == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.Update(ctx, id, update)
}

func (c *Controller) ReorderInterceptModules(ctx context.Context, revision string, executionOrder []string) (interceptModulesView, error) {
	if c.interceptModules == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	return c.interceptModules.Reorder(ctx, revision, executionOrder)
}

func (c *Controller) ExtensionMarketplaces() (marketplaceView, error) {
	if c.extensionMarketplaces == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.View()
}

func (c *Controller) AddExtensionMarketplace(ctx context.Context, revision, rawURL, rawDisplayName string) (marketplaceView, error) {
	if c.extensionMarketplaces == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.Add(ctx, revision, rawURL, rawDisplayName)
}

func (c *Controller) PreviewExtensionMarketplaceAdd(ctx context.Context, rawURL, rawDisplayName string) (marketplaceSourceView, error) {
	if c.extensionMarketplaces == nil {
		return marketplaceSourceView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.PreviewAdd(ctx, rawURL, rawDisplayName)
}

func (c *Controller) AddExtensionMarketplaceExpected(
	ctx context.Context,
	revision, rawURL, rawDisplayName, expectedSnapshotDigest string,
) (marketplaceView, error) {
	if c.extensionMarketplaces == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.AddExpected(ctx, revision, rawURL, rawDisplayName, expectedSnapshotDigest)
}

func (c *Controller) RefreshExtensionMarketplace(ctx context.Context, id, revision string) (marketplaceView, error) {
	if c.extensionMarketplaces == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.Refresh(ctx, id, revision)
}

func (c *Controller) PreviewExtensionMarketplaceRefresh(ctx context.Context, id, revision string) (marketplaceSourceView, error) {
	if c.extensionMarketplaces == nil {
		return marketplaceSourceView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.PreviewRefresh(ctx, id, revision)
}

func (c *Controller) RefreshExtensionMarketplaceExpected(
	ctx context.Context,
	id, revision, expectedSnapshotDigest string,
) (marketplaceView, error) {
	if c.extensionMarketplaces == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.RefreshExpected(ctx, id, revision, expectedSnapshotDigest)
}

func (c *Controller) DeleteExtensionMarketplace(ctx context.Context, id, revision string) (marketplaceView, error) {
	if c.extensionMarketplaces == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.Delete(ctx, id, revision)
}

func (c *Controller) InstallMarketplaceExtension(
	ctx context.Context,
	marketplaceID, extensionID, marketplaceRevision, moduleRevision string,
) (interceptModulesView, error) {
	if c.extensionMarketplaces == nil {
		return interceptModulesView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.Install(ctx, marketplaceID, extensionID, marketplaceRevision, moduleRevision)
}

func (c *Controller) PreviewMarketplaceExtensionInstall(
	ctx context.Context,
	marketplaceID, extensionID, marketplaceRevision, moduleRevision string,
) (interceptModuleView, error) {
	if c.extensionMarketplaces == nil {
		return interceptModuleView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.PreviewInstall(ctx, marketplaceID, extensionID, marketplaceRevision, moduleRevision)
}

func (c *Controller) InstallMarketplaceExtensionExpected(
	ctx context.Context,
	marketplaceID, extensionID, marketplaceRevision, moduleRevision string,
	expectedSourceSnapshotDigest, expectedCandidateSnapshotDigest string,
) (interceptModulesView, error) {
	if c.extensionMarketplaces == nil {
		return interceptModulesView{}, errMarketplaceUnavailable
	}
	return c.extensionMarketplaces.InstallExpected(
		ctx,
		marketplaceID,
		extensionID,
		marketplaceRevision,
		moduleRevision,
		expectedSourceSnapshotDigest,
		expectedCandidateSnapshotDigest,
	)
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

// ApplyPolicy compiles the current PolicyModel, reconciles its subscriptions,
// and publishes the live DNS snapshot. It never mutates mihomo. Returns
// ErrPolicyRulesUnavailable when no PolicyEngine is wired (a PolicyRuleManager
// alone is not enough — CompileAndApply is a PolicyEngine method).
func (c *Controller) ApplyPolicy(ctx context.Context) error {
	if c.policyEngine == nil {
		return ErrPolicyRulesUnavailable
	}
	return c.policyEngine.CompileAndApply(ctx)
}
