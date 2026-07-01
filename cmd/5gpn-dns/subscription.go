package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// maxSubscriptionBodySize caps the number of bytes read from a subscription
// URL response, to bound memory use against a misbehaving/malicious server.
const maxSubscriptionBodySize = 32 << 20 // 32 MiB

// Floor guards: a fetch that parses to fewer than this many entries is
// treated as a failure (keep the old cache) rather than replacing a real
// rule set with a near-empty one. An empty chnroute set in particular would
// make every IP appear "foreign".
const (
	domainFloor   = 1
	chnrouteFloor = 100
)

// validCategories enumerates the four rule-set categories a subscription may
// target.
var validCategories = map[string]bool{
	"adblock":   true,
	"direct":    true,
	"blacklist": true,
	"chnroute":  true,
}

// Subscription describes one remote rule-list subscription.
type Subscription struct {
	ID       string
	Category string // adblock|direct|blacklist|chnroute
	Name     string
	URL      string
	Format   string // parser format; for chnroute use "cidr"
	Enabled  bool
	Interval time.Duration
}

// subscriptionJSON is the on-disk JSON shape for a Subscription: identical
// except Interval is a human-readable Go duration string (e.g. "24h")
// instead of a nanosecond count.
type subscriptionJSON struct {
	ID       string `json:"id"`
	Category string `json:"category"`
	Name     string `json:"name"`
	URL      string `json:"url"`
	Format   string `json:"format"`
	Enabled  bool   `json:"enabled"`
	Interval string `json:"interval"`
}

// MarshalJSON renders Interval as a Go duration string.
func (s Subscription) MarshalJSON() ([]byte, error) {
	return json.Marshal(subscriptionJSON{
		ID:       s.ID,
		Category: s.Category,
		Name:     s.Name,
		URL:      s.URL,
		Format:   s.Format,
		Enabled:  s.Enabled,
		Interval: s.Interval.String(),
	})
}

// UnmarshalJSON parses Interval from a Go duration string.
func (s *Subscription) UnmarshalJSON(data []byte) error {
	var raw subscriptionJSON
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	var interval time.Duration
	if raw.Interval != "" {
		d, err := time.ParseDuration(raw.Interval)
		if err != nil {
			return fmt.Errorf("subscription %s: invalid interval %q: %w", raw.ID, raw.Interval, err)
		}
		interval = d
	}
	s.ID = raw.ID
	s.Category = raw.Category
	s.Name = raw.Name
	s.URL = raw.URL
	s.Format = raw.Format
	s.Enabled = raw.Enabled
	s.Interval = interval
	return nil
}

// UpdateResult reports the outcome of updating a single subscription.
type UpdateResult struct {
	ID      string
	OK      bool
	Entries int
	Err     string
}

// subscriptionsFile is the top-level shape of subscriptions.json.
type subscriptionsFile struct {
	Subscriptions []Subscription `json:"subscriptions"`
}

// LoadSubscriptions reads and parses the subscriptions JSON file at path.
// A missing file is not an error: it returns (nil, nil), meaning "no
// subscriptions configured". A malformed file returns an error.
func LoadSubscriptions(path string) ([]Subscription, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("subscriptions: read %s: %w", path, err)
	}
	var doc subscriptionsFile
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("subscriptions: parse %s: %w", path, err)
	}
	return doc.Subscriptions, nil
}

// SubManager manages the set of configured subscriptions: it fetches,
// parses, caches, and periodically refreshes them, invoking reload whenever
// a category's cache changes on disk.
type SubManager struct {
	path     string // path to subscriptions.json
	rulesDir string // rules base directory (rulesDir/<category>/<name>.txt)
	subs     []Subscription
	http     *http.Client
	reload   func() error
	mu       sync.Mutex

	// runCtx is the context passed to Run, stored so a subscription added
	// later via Add (while Run is active) can launch its own ticker goroutine
	// instead of waiting for the process to restart. nil until Run is called;
	// guarded by mu like the rest of the manager's mutable state.
	runCtx context.Context
}

// NewSubManager constructs a SubManager, loading any existing subscriptions
// from path (missing file => empty list).
func NewSubManager(path, rulesDir string, reload func() error) (*SubManager, error) {
	subs, err := LoadSubscriptions(path)
	if err != nil {
		return nil, err
	}
	return &SubManager{
		path:     path,
		rulesDir: rulesDir,
		subs:     subs,
		http:     &http.Client{Timeout: 30 * time.Second},
		reload:   reload,
	}, nil
}

// List returns a snapshot copy of the currently configured subscriptions.
func (m *SubManager) List() []Subscription {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Subscription, len(m.subs))
	copy(out, m.subs)
	return out
}

// cachePath returns the on-disk cache file path for a subscription.
func (m *SubManager) cachePath(s Subscription) string {
	return filepath.Join(m.rulesDir, s.Category, s.Name+".txt")
}

// find returns the subscription with the given ID and its index, or
// ok=false if not found. Callers must hold m.mu.
func (m *SubManager) find(id string) (Subscription, int, bool) {
	for i, s := range m.subs {
		if s.ID == id {
			return s, i, true
		}
	}
	return Subscription{}, -1, false
}

// UpdateOne fetches, parses, and caches a single subscription by ID, then
// calls reload on success. On failure (fetch error, parse error, or the
// parsed entry count falling below the category's floor guard) the existing
// cache file is left untouched and reload is not called.
func (m *SubManager) UpdateOne(ctx context.Context, id string) UpdateResult {
	m.mu.Lock()
	sub, _, ok := m.find(id)
	m.mu.Unlock()
	if !ok {
		return UpdateResult{ID: id, OK: false, Err: fmt.Sprintf("subscription %q not found", id)}
	}
	return m.fetchAndCache(ctx, sub)
}

// UpdateAll updates every subscription (enabled or not) and returns one
// result per subscription, in configured order.
func (m *SubManager) UpdateAll(ctx context.Context) []UpdateResult {
	m.mu.Lock()
	subs := make([]Subscription, len(m.subs))
	copy(subs, m.subs)
	m.mu.Unlock()

	results := make([]UpdateResult, 0, len(subs))
	for _, s := range subs {
		results = append(results, m.fetchAndCache(ctx, s))
	}
	return results
}

// fetchAndCache performs the actual fetch -> parse -> floor-guard -> atomic
// write -> reload pipeline for one subscription.
func (m *SubManager) fetchAndCache(ctx context.Context, sub Subscription) UpdateResult {
	entries, err := m.fetchAndParse(ctx, sub)
	if err != nil {
		return UpdateResult{ID: sub.ID, OK: false, Err: err.Error()}
	}

	floor := domainFloor
	if sub.Category == "chnroute" {
		floor = chnrouteFloor
	}
	if len(entries) < floor {
		return UpdateResult{
			ID:  sub.ID,
			OK:  false,
			Err: fmt.Sprintf("parsed %d entries, below floor guard %d — keeping existing cache", len(entries), floor),
		}
	}

	path := m.cachePath(sub)
	if err := atomicWriteLines(path, entries); err != nil {
		return UpdateResult{ID: sub.ID, OK: false, Err: err.Error()}
	}

	if m.reload != nil {
		if err := m.reload(); err != nil {
			// The cache write already succeeded; report the reload failure but
			// do not attempt to roll back the just-written file.
			return UpdateResult{ID: sub.ID, OK: false, Entries: len(entries), Err: fmt.Sprintf("reload: %v", err)}
		}
	}

	return UpdateResult{ID: sub.ID, OK: true, Entries: len(entries)}
}

// fetchAndParse performs the HTTP GET (capped, timed-out) and parses the
// body according to the subscription's category/format.
func (m *SubManager) fetchAndParse(ctx context.Context, sub Subscription) ([]string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, sub.URL, nil)
	if err != nil {
		return nil, fmt.Errorf("subscription %s: build request: %w", sub.ID, err)
	}

	client := m.http
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("subscription %s: fetch: %w", sub.ID, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("subscription %s: fetch: unexpected status %s", sub.ID, resp.Status)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxSubscriptionBodySize))
	if err != nil {
		return nil, fmt.Errorf("subscription %s: read body: %w", sub.ID, err)
	}

	if sub.Category == "chnroute" {
		return ParseCIDRs(body)
	}
	entries, err := ParseDomains(sub.Format, body)
	if err != nil {
		return nil, fmt.Errorf("subscription %s: parse: %w", sub.ID, err)
	}
	return entries, nil
}

// atomicWriteLines writes one entry per line to path via a temp file in the
// same directory, followed by an atomic rename. The parent (category)
// directory is created if missing.
func atomicWriteLines(path string, entries []string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}

	tmp, err := os.CreateTemp(dir, ".sub-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp file in %s: %w", dir, err)
	}
	tmpPath := tmp.Name()
	// Ensure the temp file never lingers, whatever happens below.
	succeeded := false
	defer func() {
		if !succeeded {
			os.Remove(tmpPath)
		}
	}()

	for _, e := range entries {
		if _, err := tmp.WriteString(e); err != nil {
			tmp.Close()
			return fmt.Errorf("write temp file: %w", err)
		}
		if _, err := tmp.WriteString("\n"); err != nil {
			tmp.Close()
			return fmt.Errorf("write temp file: %w", err)
		}
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("sync temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("rename %s -> %s: %w", tmpPath, path, err)
	}
	succeeded = true
	return nil
}

// Add validates, appends, and persists a new subscription, then performs an
// initial UpdateOne to populate its cache and returns that fetch's result. If
// Run is currently active (its ctx is stored in m.runCtx and not yet done),
// Add also launches a ticker goroutine for the new subscription so it
// auto-refreshes on its own Interval without requiring a process restart.
func (m *SubManager) Add(s Subscription) (UpdateResult, error) {
	if err := validateSubscription(s); err != nil {
		return UpdateResult{}, err
	}

	m.mu.Lock()
	if _, _, exists := m.find(s.ID); exists {
		m.mu.Unlock()
		return UpdateResult{}, fmt.Errorf("subscription: id %q already exists", s.ID)
	}
	m.subs = append(m.subs, s)
	err := m.persistLocked()
	runCtx := m.runCtx
	m.mu.Unlock()
	if err != nil {
		return UpdateResult{}, err
	}

	// The initial fetch is best-effort: a subscription is still validly
	// registered even if its first fetch fails (e.g. transient network
	// issue) — Run's ticker (or a later on-demand update) will retry.
	res := m.UpdateOne(context.Background(), s.ID)

	// Live reschedule: Run is already driving the ticker loop for the
	// existing subscriptions, so a sub added afterwards needs its own
	// goroutine — otherwise it would only ever refresh once (here) until the
	// next process restart.
	if runCtx != nil && runCtx.Err() == nil && s.Enabled && s.Interval > 0 {
		go m.runOne(runCtx, s)
	}

	return res, nil
}

// Remove drops a subscription by ID, persists the change, deletes its cache
// file (if any), and triggers a reload.
func (m *SubManager) Remove(id string) error {
	m.mu.Lock()
	sub, idx, ok := m.find(id)
	if !ok {
		m.mu.Unlock()
		return fmt.Errorf("subscription: id %q not found", id)
	}
	m.subs = append(m.subs[:idx], m.subs[idx+1:]...)
	err := m.persistLocked()
	m.mu.Unlock()
	if err != nil {
		return err
	}

	cachePath := m.cachePath(sub)
	if err := os.Remove(cachePath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("subscription %s: remove cache file: %w", id, err)
	}

	if m.reload != nil {
		if err := m.reload(); err != nil {
			return fmt.Errorf("subscription %s: reload after remove: %w", id, err)
		}
	}
	return nil
}

// validateSubscription checks the fields required before a subscription can
// be added.
func validateSubscription(s Subscription) error {
	if s.ID == "" {
		return errors.New("subscription: id must not be empty")
	}
	if !validCategories[s.Category] {
		return fmt.Errorf("subscription: invalid category %q", s.Category)
	}
	if err := validateSubscriptionName(s.Name); err != nil {
		return err
	}
	if s.Format == "" {
		return errors.New("subscription: format must not be empty")
	}
	if s.URL == "" {
		return errors.New("subscription: url must not be empty")
	}
	if err := validateSubscriptionURLScheme(s.URL); err != nil {
		return err
	}
	return nil
}

// validateSubscriptionURLScheme rejects any URL whose scheme is not http or
// https. Ahead of Task 1, Add was only reachable from trusted local config;
// now that Phase 3 exposes Add over HTTP, an unrestricted URL would let a
// caller point a subscription fetch at file:///etc/passwd (arbitrary local
// file disclosure into the rule-set cache) or other non-http(s) schemes
// intended for SSRF against internal services.
func validateSubscriptionURLScheme(rawURL string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("subscription: invalid url %q: %w", rawURL, err)
	}
	switch u.Scheme {
	case "http", "https":
		return nil
	default:
		return fmt.Errorf("subscription: invalid url scheme %q (must be http or https)", u.Scheme)
	}
}

// validateSubscriptionName rejects any Name that is not a single, safe path
// component. Name is free text (unlike Category, which is enum-guarded) and
// is used verbatim in cachePath via filepath.Join(rulesDir, category,
// name+".txt"). Without this guard, a Name such as "../../../etc/cron.d/evil"
// would let filepath.Join's path cleaning escape rulesDir entirely, giving an
// arbitrary-file write once Add is reachable over the Phase 3 HTTP API.
func validateSubscriptionName(name string) error {
	if name == "" {
		return errors.New("subscription: name must not be empty")
	}
	if name == "." || name == ".." {
		return fmt.Errorf("subscription: invalid name %q (must be a single path component)", name)
	}
	if strings.ContainsAny(name, `/\`) {
		return fmt.Errorf("subscription: invalid name %q (must be a single path component)", name)
	}
	if filepath.Base(name) != name {
		return fmt.Errorf("subscription: invalid name %q (must be a single path component)", name)
	}
	return nil
}

// persistLocked marshals m.subs to JSON and atomically writes it to m.path.
// Callers must hold m.mu.
func (m *SubManager) persistLocked() error {
	doc := subscriptionsFile{Subscriptions: m.subs}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return fmt.Errorf("subscriptions: marshal: %w", err)
	}

	dir := filepath.Dir(m.path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("subscriptions: mkdir %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".subscriptions-*.tmp")
	if err != nil {
		return fmt.Errorf("subscriptions: create temp file: %w", err)
	}
	tmpPath := tmp.Name()
	succeeded := false
	defer func() {
		if !succeeded {
			os.Remove(tmpPath)
		}
	}()

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("subscriptions: write temp file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("subscriptions: sync temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("subscriptions: close temp file: %w", err)
	}
	if err := os.Rename(tmpPath, m.path); err != nil {
		return fmt.Errorf("subscriptions: rename %s -> %s: %w", tmpPath, m.path, err)
	}
	succeeded = true
	return nil
}

// Run starts one goroutine per enabled subscription, ticking at its
// configured interval and calling UpdateOne on each tick. If a subscription's
// cache file is missing when Run starts, an immediate UpdateOne is performed
// before entering the ticker loop (so a fresh install populates its cache
// promptly rather than waiting a full interval). Run blocks until ctx is
// done, even when there are zero (or zero enabled) subscriptions to start
// with — see the runCtx doc below for why that matters.
//
// ctx is also stored on the manager (m.runCtx) for the duration of the call,
// so a subscription added afterwards via Add can detect that Run is active
// and launch its own ticker goroutine (live reschedule) instead of only
// refreshing once at Add time. Run must therefore stay "active" (block)
// until ctx is actually done, regardless of how many subscriptions it started
// with — otherwise a fresh install with no subscriptions yet configured
// would have Run return immediately, clear runCtx, and silently disable live
// reschedule for every subscription added afterwards.
func (m *SubManager) Run(ctx context.Context) {
	m.mu.Lock()
	subs := make([]Subscription, len(m.subs))
	copy(subs, m.subs)
	m.runCtx = ctx
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		m.runCtx = nil
		m.mu.Unlock()
	}()

	var wg sync.WaitGroup
	for _, sub := range subs {
		if !sub.Enabled {
			continue
		}
		if sub.Interval <= 0 {
			continue
		}
		wg.Add(1)
		go func(sub Subscription) {
			defer wg.Done()
			m.runOne(ctx, sub)
		}(sub)
	}

	// Block until ctx is cancelled, independent of the per-subscription
	// goroutines above (which themselves also block on ctx.Done() inside
	// runOne's select). This keeps runCtx valid for the whole Run lifetime.
	<-ctx.Done()
	wg.Wait()
}

// runOne drives the per-subscription ticker loop for Run.
func (m *SubManager) runOne(ctx context.Context, sub Subscription) {
	if _, err := os.Stat(m.cachePath(sub)); err != nil && os.IsNotExist(err) {
		m.UpdateOne(ctx, sub.ID)
	}

	ticker := time.NewTicker(sub.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.UpdateOne(ctx, sub.ID)
		}
	}
}
