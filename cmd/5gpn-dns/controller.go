package main

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
)

// Stats is a point-in-time snapshot of engine verdict counters plus the
// current cache size. It is the read model the Phase-3 HTTP API will expose.
type Stats struct {
	Total, Direct, Proxy, Block uint64
	CacheEntries                int
	ChinaOK, ChinaErr           uint64
	TrustOK, TrustErr           uint64
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
}

// NewController constructs a Controller. Any of subs, stats, or cacheLen may
// be nil (e.g. in tests exercising only a subset of behavior); nil subs makes
// Subscriptions/AddSubscription/RemoveSubscription/Update panic if actually
// called — callers wiring the real server must always pass a live SubManager.
func NewController(subs *SubManager, reload func() error, rulesDir string, stats *statsCounters, cacheLen func() int) *Controller {
	return &Controller{
		subs:     subs,
		reload:   reload,
		rulesDir: rulesDir,
		stats:    stats,
		cacheLen: cacheLen,
	}
}

// Subscriptions returns the currently configured subscriptions.
func (c *Controller) Subscriptions() []Subscription {
	return c.subs.List()
}

// AddSubscription validates, persists, and performs an initial fetch for a
// new subscription.
func (c *Controller) AddSubscription(s Subscription) error {
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

// Stats returns a snapshot of the engine's verdict counters and current cache
// size. Safe to call even when the Controller was constructed with nil
// stats/cacheLen (e.g. in tests) — the corresponding fields are left at zero.
func (c *Controller) Stats() Stats {
	var s Stats
	if c.stats != nil {
		s.Total = c.stats.total.Load()
		s.Direct = c.stats.direct.Load()
		s.Proxy = c.stats.proxy.Load()
		s.Block = c.stats.block.Load()
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

// AddRule validates entry against cat's expected shape (a CIDR for chnroute,
// a domain otherwise), appends it (de-duplicated) to the category's manual
// rule file, and reloads. The file and its parent directory are created if
// missing. An invalid cat or entry returns an error and leaves the file
// untouched.
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

	if err := os.MkdirAll(c.rulesDir, 0o755); err != nil {
		return fmt.Errorf("controller: mkdir %s: %w", c.rulesDir, err)
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("controller: open %s: %w", path, err)
	}
	_, werr := f.WriteString(norm + "\n")
	cerr := f.Close()
	if werr != nil {
		return fmt.Errorf("controller: write %s: %w", path, werr)
	}
	if cerr != nil {
		return fmt.Errorf("controller: close %s: %w", path, cerr)
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
		return "", fmt.Errorf("controller: invalid category %q", cat)
	}
	entry = strings.TrimSpace(entry)
	if cat == "chnroute" {
		if _, _, err := net.ParseCIDR(entry); err != nil {
			return "", fmt.Errorf("controller: invalid CIDR %q: %w", entry, err)
		}
		return strings.ToLower(entry), nil
	}
	if !isValidRuleDomain(entry) {
		return "", fmt.Errorf("controller: invalid domain %q", entry)
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
