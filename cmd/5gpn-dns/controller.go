package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/miekg/dns"
)

// ErrInvalidRule wraps every client-caused rule/category validation failure
// (bad category, malformed CIDR/domain) so the HTTP layer can distinguish a
// 400 (caller sent something invalid) from a 500 (a disk/reload failure while
// applying an otherwise-valid entry). Wrapped, not returned bare, so the
// descriptive message is preserved: errors.Is(err, ErrInvalidRule) still holds.
var ErrInvalidRule = errors.New("invalid rule")

// Stats is a point-in-time snapshot of engine reason counters plus the
// current cache size. It is the read model the Phase-3 HTTP API will expose.
type Stats struct {
	Total           uint64 `json:"total"`
	Adblock         uint64 `json:"adblock"`
	ForceDirect     uint64 `json:"force_direct"`
	Blacklist       uint64 `json:"blacklist"`
	ChnrouteCN      uint64 `json:"chnroute_cn"`
	ChnrouteForeign uint64 `json:"chnroute_foreign"`
	CacheEntries    int    `json:"cache_entries"`
	ChinaOK         uint64 `json:"china_ok"`
	ChinaErr        uint64 `json:"china_err"`
	TrustOK         uint64 `json:"trust_ok"`
	TrustErr        uint64 `json:"trust_err"`
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

	// handler gives Lookup access to the live engine (classifyName, the
	// China/Trust exchangers, CN, GatewayIP, Timeout) so a manual lookup can
	// reuse the exact same decision/arbitration path as the query pipeline.
	// May be nil (e.g. in tests exercising only subscription/rule-list
	// behavior); Lookup on a nil handler returns a zero-value LookupResult.
	handler *Handler
}

// NewController constructs a Controller. Any of subs, stats, or cacheLen may
// be nil (e.g. in tests exercising only a subset of behavior); nil subs makes
// Subscriptions/AddSubscription/RemoveSubscription/Update panic if actually
// called — callers wiring the real server must always pass a live SubManager.
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

// Subscriptions returns the currently configured subscriptions.
func (c *Controller) Subscriptions() []Subscription {
	return c.subs.List()
}

// AddSubscription validates, persists, and performs an initial fetch for a
// new subscription, returning the initial fetch's UpdateResult alongside any
// validation/persistence error.
func (c *Controller) AddSubscription(s Subscription) (UpdateResult, error) {
	return c.subs.Add(s)
}

// RemoveSubscription drops a subscription by ID, deletes its cache file, and
// reloads.
func (c *Controller) RemoveSubscription(id string) error {
	return c.subs.Remove(id)
}

// Update refreshes one subscription by ID, or every subscription when id=="".
func (c *Controller) Update(ctx context.Context, id string) []UpdateResult {
	if id == "" {
		return c.subs.UpdateAll(ctx)
	}
	return []UpdateResult{c.subs.UpdateOne(ctx, id)}
}

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
//   - adblock/force-direct/blacklist: classifyName's terminal verdict is
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

	verdict := h.classifyName(name)

	switch verdict.Reason {
	case "adblock":
		return LookupResult{Name: name, Verdict: verdict.Verdict, Reason: verdict.Reason}
	case "blacklist":
		return LookupResult{Name: name, Verdict: verdict.Verdict, Reason: verdict.Reason}
	case "force-direct":
		ips, upstream := h.lookupArbitrate(ctx, name)
		return LookupResult{Name: name, Verdict: verdict.Verdict, Reason: verdict.Reason, IPs: ips, Upstream: upstream}
	}

	// Default case: resolve via the engine and classify the IPs against CN.
	ips, upstream := h.lookupArbitrate(ctx, name)
	if len(ips) == 0 {
		return LookupResult{Name: name, Verdict: "", Reason: "", Upstream: upstream}
	}

	_, _, _, cn := h.ruleSnap()
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
// reply/empty answer.
func (h *Handler) lookupArbitrate(ctx context.Context, name string) ([]string, string) {
	fqdn := dns.Fqdn(name)
	q := new(dns.Msg)
	q.SetQuestion(fqdn, dns.TypeA)

	resp, err := Arbitrate(ctx, q, h.China, h.Trust, h.CN)
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
		return nil, ""
	}

	upstream := "trust"
	for _, ipStr := range ips {
		if ip := net.ParseIP(ipStr); ip != nil && h.CN.Contains(ip) {
			upstream = "china"
			break
		}
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
		s.Adblock = c.stats.adblock.Load()
		s.ForceDirect = c.stats.forceDirect.Load()
		s.Blacklist = c.stats.blacklist.Load()
		s.ChnrouteCN = c.stats.chnrouteCN.Load()
		s.ChnrouteForeign = c.stats.chnrouteForeign.Load()
		s.ChinaOK = c.stats.chinaOK.Load()
		s.ChinaErr = c.stats.chinaErr.Load()
		s.TrustOK = c.stats.trustOK.Load()
		s.TrustErr = c.stats.trustErr.Load()
	}
	if c.cacheLen != nil {
		s.CacheEntries = c.cacheLen()
	}
	return s
}

// manualRulePath returns the path to the manual (non-subscription) rule file
// for a category: rulesDir/<cat>.txt.
func (c *Controller) manualRulePath(cat string) string {
	return filepath.Join(c.rulesDir, cat+".txt")
}

// ListRules returns the manual (non-subscription) rule entries currently
// persisted for cat, in file order. An invalid cat returns an error. A
// missing rule file is not an error: it returns an empty (non-nil) slice, so
// callers (notably the HTTP API) can serialize it as JSON "[]" rather than
// "null".
func (c *Controller) ListRules(cat string) ([]string, error) {
	if !validCategories[cat] {
		return nil, fmt.Errorf("controller: invalid category %q: %w", cat, ErrInvalidRule)
	}
	lines, err := readRuleLines(c.manualRulePath(cat))
	if err != nil {
		return nil, err
	}
	return append([]string{}, lines...), nil
}

// AddRule validates entry against cat's expected shape (a CIDR for chnroute,
// a domain otherwise), appends it (de-duplicated) to the category's manual
// rule file, and reloads. The file and its parent directory are created if
// missing. An invalid cat or entry returns an error and leaves the file
// untouched. Uses the same read-modify-write-via-atomicWriteLines path as
// RemoveRule for consistency (no partial-write window from a plain append).
func (c *Controller) AddRule(cat, entry string) error {
	norm, err := normalizeRuleEntry(cat, entry)
	if err != nil {
		return err
	}

	path := c.manualRulePath(cat)
	existing, err := readRuleLines(path)
	if err != nil {
		return err
	}
	for _, e := range existing {
		if e == norm {
			// Already present: nothing to do, but still succeed idempotently.
			return c.reload()
		}
	}

	out := append(existing[:len(existing):len(existing)], norm)

	if err := atomicWriteLines(path, out); err != nil {
		return err
	}

	return c.reload()
}

// RemoveRule rewrites the category's manual rule file without entry, then
// reloads. A missing file or a not-present entry is not an error (idempotent
// remove); reload still runs so callers observe a consistent state.
func (c *Controller) RemoveRule(cat, entry string) error {
	norm, err := normalizeRuleEntry(cat, entry)
	if err != nil {
		return err
	}

	path := c.manualRulePath(cat)
	existing, err := readRuleLines(path)
	if err != nil {
		return err
	}

	out := existing[:0:0]
	for _, e := range existing {
		if e != norm {
			out = append(out, e)
		}
	}

	if err := atomicWriteLines(path, out); err != nil {
		return err
	}

	return c.reload()
}

// readRuleLines reads a manual rule file's non-blank lines. A missing file
// returns an empty slice, not an error.
func readRuleLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("controller: open %s: %w", path, err)
	}
	defer f.Close()

	var out []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		out = append(out, line)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("controller: scan %s: %w", path, err)
	}
	return out, nil
}

// normalizeRuleEntry validates entry against cat's expected shape and returns
// its normalized (lowercase, trimmed) form. cat must be one of the four
// known rule categories.
func normalizeRuleEntry(cat, entry string) (string, error) {
	if !validCategories[cat] {
		return "", fmt.Errorf("controller: invalid category %q: %w", cat, ErrInvalidRule)
	}
	entry = strings.TrimSpace(entry)
	if cat == "chnroute" {
		if _, _, err := net.ParseCIDR(entry); err != nil {
			return "", fmt.Errorf("controller: invalid CIDR %q: %v: %w", entry, err, ErrInvalidRule)
		}
		return strings.ToLower(entry), nil
	}
	if !isValidRuleDomain(entry) {
		return "", fmt.Errorf("controller: invalid domain %q: %w", entry, ErrInvalidRule)
	}
	return normalizeDomain(entry), nil
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
