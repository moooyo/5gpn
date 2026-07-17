package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/miekg/dns"
)

// maxSubscriptionBodySize caps the number of bytes read from a subscription
// URL response, to bound memory use against a misbehaving/malicious server.
const maxSubscriptionBodySize = 32 << 20 // 32 MiB

// Floor guards: a fetch that parses to fewer than this many entries is
// treated as a failure (keep the old cache) rather than replacing a real
// rule set with a near-empty one. An empty chnroute set in particular would
// make every IP appear "foreign".
const (
	domainFloor                   = 1
	chnrouteFloor                 = 100
	shrinkGuardMinimumExisting    = 20
	shrinkGuardMinimumRetainedPct = 20
)

// validCategories enumerates the four rule-set categories a subscription may
// target.
var validCategories = map[string]bool{
	"block":    true,
	"direct":   true,
	"proxy":    true,
	"chnroute": true,
}

// Subscription describes one remote rule-list subscription.
type Subscription struct {
	ID       string
	Category string // block|direct|proxy|chnroute
	Name     string
	URL      string
	Format   string // chnroute: cidr; block/direct/proxy: plain|gfwlist|dnsmasq|hosts
	Enabled  bool
	Interval time.Duration // must be positive when Enabled
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
	if err := unmarshalStrictJSON(data, &raw); err != nil {
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
	ID      string `json:"id"`
	OK      bool   `json:"ok"`
	Entries int    `json:"entries"`
	Err     string `json:"err"`
}

// SubHealth records the outcome of the most recent fetch attempt for a
// subscription: when it ran (RFC3339 UTC), whether it succeeded, how many
// entries it parsed, and its error message (empty on success). At is "" only
// in the zero value; once a fetch has ever run for a subscription its health
// entry always has a non-empty At.
type SubHealth struct {
	At      string `json:"at"`
	OK      bool   `json:"ok"`
	Entries int    `json:"entries"`
	Err     string `json:"err"`
}

// subscriptionsFile is the top-level shape of subscriptions.json.
type subscriptionsFile struct {
	Version       int            `json:"version"`
	Subscriptions []Subscription `json:"subscriptions"`
}

// subsSchemaVersion is the exact subscriptions.json schema version accepted.
const subsSchemaVersion = 1

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
	if err := unmarshalStrictJSON(data, &doc); err != nil {
		return nil, fmt.Errorf("subscriptions: parse %s: %w", path, err)
	}
	if doc.Version != subsSchemaVersion {
		return nil, fmt.Errorf("subscriptions: %s: unsupported schema version %d (want %d)", path, doc.Version, subsSchemaVersion)
	}
	seen := make(map[string]bool, len(doc.Subscriptions))
	for _, sub := range doc.Subscriptions {
		if err := validateSubscription(sub); err != nil {
			return nil, fmt.Errorf("subscriptions: %s: %w", path, err)
		}
		if seen[sub.ID] {
			return nil, fmt.Errorf("subscriptions: %s: duplicate id %q", path, sub.ID)
		}
		seen[sub.ID] = true
	}
	if err := validateUniqueSubscriptionCachePaths(doc.Subscriptions); err != nil {
		return nil, fmt.Errorf("subscriptions: %s: %w", path, err)
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
	health   map[string]SubHealth // per-subscription last-fetch health; guarded by mu
	http     *http.Client
	reload   func() error
	mu       sync.Mutex
	// txMu serializes cache-file writers against policy's two-phase generation
	// preparation/commit. A prepared generation holds txMu (then mu) until it is
	// published or aborted, so ticker fetches cannot leak partial cache state.
	txMu sync.Mutex

	// runCtx is the context passed to Run. Policy publication uses it to start
	// tickers for a newly published subscription set without restarting the
	// process. nil until Run is called; guarded by mu.
	runCtx context.Context

	// cancels holds, per subscription ID, the CancelFunc for its running ticker
	// goroutine while Run is active. Policy publication cancels the old
	// generation before scheduling the new one. Guarded by mu.
	cancels map[string]context.CancelFunc

	// workers keeps Run from returning while a cancelled ticker is still
	// finishing an in-flight cache transaction. New workers are registered only
	// while holding mu and while runCtx is live, so shutdown can close admission
	// under mu before waiting.
	workers sync.WaitGroup
}

// NewSubManager constructs a SubManager, loading any existing subscriptions
// from path (missing file => empty list). resolver, if non-nil, is used to
// resolve subscription URL hostnames (see HostResolver); a nil resolver falls
// back to the system resolver via the default dialer.
func NewSubManager(path, rulesDir string, reload func() error, resolver HostResolver) (*SubManager, error) {
	subs, err := LoadSubscriptions(path)
	if err != nil {
		return nil, err
	}
	return &SubManager{
		path:     path,
		rulesDir: rulesDir,
		subs:     subs,
		health:   make(map[string]SubHealth),
		http:     newSubHTTPClient(resolver),
		reload:   reload,
		cancels:  make(map[string]context.CancelFunc),
	}, nil
}

// HostResolver resolves a hostname to candidate IPs. Injected into the
// subscription fetcher so it resolves subscription URLs via the daemon's trust
// DoT upstream (real IPs) instead of the box's own resolver — which, on a 5gpn
// gateway, rewrites foreign hosts to the gateway IP and deadlocks the SSRF guard
// (the fetcher would refuse to dial its own gateway address forever).
type HostResolver func(ctx context.Context, host string) ([]net.IP, error)

// trustHostResolver builds a HostResolver backed by the trust Exchanger: it asks
// trust for the host's A records and returns the real addresses. A nil exchanger
// yields a nil resolver (fall back to the system resolver).
func trustHostResolver(x Exchanger) HostResolver {
	if x == nil {
		return nil
	}
	return func(ctx context.Context, host string) ([]net.IP, error) {
		q := new(dns.Msg)
		q.SetQuestion(dns.Fqdn(host), dns.TypeA)
		resp, err := x.Exchange(ctx, q)
		if err != nil {
			return nil, err
		}
		if resp == nil {
			return nil, fmt.Errorf("trust resolver: nil reply for %s", host)
		}
		var ips []net.IP
		for _, rr := range resp.Answer {
			if a, ok := rr.(*dns.A); ok {
				ips = append(ips, a.A)
			}
		}
		if len(ips) == 0 {
			return nil, fmt.Errorf("trust resolver: no A records for %s", host)
		}
		return ips, nil
	}
}

// newSubHTTPClient builds the HTTP client used to fetch subscription lists, with
// SSRF hardening: validateSubscriptionURLScheme only checks the initially-
// submitted URL, but a fetch can 30x-redirect to an internal target, and the
// daemon runs as root on a direct-egress gateway. So (1) a DialContext Control
// hook rejects any connection whose resolved destination IP is loopback/private/
// link-local/unspecified (blocks redirects AND DNS-rebinding to internal
// services or the cloud metadata endpoint 169.254.169.254 — the check runs on
// the actual dialed IP, post-resolution); (2) CheckRedirect re-validates every
// hop's scheme and caps redirects; (3) Proxy is nil so HTTP(S)_PROXY env can't
// redirect fetches through an attacker-influenced proxy.
//
// resolver, when non-nil, resolves the request hostname via the trust
// upstream (real IPs) instead of the box's own resolver — which, on a working
// 5gpn gateway, rewrites foreign hosts to the gateway IP and would otherwise
// deadlock the SSRF guard against the gateway's own address. Only the dialed
// TCP target IP is chosen this way; the request's Host/SNI is left untouched
// so TLS verification and virtual-hosting still see the original hostname.
func newSubHTTPClient(resolver HostResolver) *http.Client {
	base := &net.Dialer{
		Timeout: 10 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			ip := net.ParseIP(host)
			if ip == nil {
				return fmt.Errorf("subscription: refusing to dial non-IP address %q", host)
			}
			if !subDialAllowed(ip) {
				return fmt.Errorf("subscription: refusing to dial internal address %s (SSRF guard)", ip)
			}
			return nil
		},
	}
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		// A literal IP host: dial as-is (base.Control still SSRF-checks it).
		if net.ParseIP(host) != nil {
			return base.DialContext(ctx, network, address)
		}
		// Hostname: resolve via the injected trust resolver (real IPs), then dial
		// the first allowed IP directly. base.Control re-checks the dialed IP, so
		// a resolver that returns an internal IP is still refused.
		if resolver != nil {
			ips, rerr := resolver(ctx, host)
			if rerr == nil {
				for _, ip := range ips {
					if !subDialAllowed(ip) {
						continue
					}
					if conn, derr := base.DialContext(ctx, network, net.JoinHostPort(ip.String(), port)); derr == nil {
						return conn, nil
					}
				}
			}
			// Resolver failed or produced no dialable IP: fall through to the
			// system resolver below (offline-tolerant; e.g. tests without trust).
		}
		return base.DialContext(ctx, network, address)
	}
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			Proxy:       nil,
			DialContext: dial,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return fmt.Errorf("subscription: too many redirects (%d)", len(via))
			}
			if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
				return fmt.Errorf("subscription: refusing non-http(s) redirect to scheme %q", req.URL.Scheme)
			}
			return nil
		},
	}
}

// specialFetchDenyPrefixes covers the IANA special-purpose ranges that must
// never be reachable through a user-controlled subscription URL. The stdlib
// IsPrivate/IsLoopback predicates intentionally do not include CGNAT,
// documentation, benchmarking, protocol-assignment, multicast, and reserved
// ranges, all of which are inappropriate HTTP subscription destinations.
var specialFetchDenyPrefixes = []netip.Prefix{
	// IPv4 special-purpose address registry.
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.31.196.0/24"),
	netip.MustParsePrefix("192.52.193.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("192.175.48.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("240.0.0.0/4"),
	// IPv6 special-purpose address registry.
	netip.MustParsePrefix("::/128"),
	netip.MustParsePrefix("::1/128"),
	netip.MustParsePrefix("64:ff9b::/96"),
	netip.MustParsePrefix("64:ff9b:1::/48"),
	netip.MustParsePrefix("100::/64"),
	netip.MustParsePrefix("2001::/23"),
	netip.MustParsePrefix("2001:db8::/32"),
	netip.MustParsePrefix("2002::/16"),
	netip.MustParsePrefix("2620:4f:8000::/48"),
	netip.MustParsePrefix("3fff::/20"),
	netip.MustParsePrefix("5f00::/16"),
	netip.MustParsePrefix("fc00::/7"),
	netip.MustParsePrefix("fe80::/10"),
	netip.MustParsePrefix("ff00::/8"),
}

// isInternalFetchIP reports whether ip is an internal or otherwise
// special-purpose address a subscription fetch must never reach.
func isInternalFetchIP(ip net.IP) bool {
	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return true
	}
	addr = addr.Unmap()
	for _, prefix := range specialFetchDenyPrefixes {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

// subDialAllowed decides whether the subscription fetcher may dial ip. It is a
// package var (not a bare call) purely so the test suite — which fetches from
// loopback httptest servers — can relax it via TestMain; production always uses
// the isInternalFetchIP guard.
var subDialAllowed = func(ip net.IP) bool { return !isInternalFetchIP(ip) }

// recordHealth stores res as the latest health entry for its subscription
// ID. Must NOT be called while already holding m.mu — it takes the lock
// itself.
func (m *SubManager) recordHealth(res UpdateResult) {
	m.mu.Lock()
	m.health[res.ID] = SubHealth{
		At:      time.Now().UTC().Format(time.RFC3339),
		OK:      res.OK,
		Entries: res.Entries,
		Err:     res.Err,
	}
	m.mu.Unlock()
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

// startTickerLocked launches a ticker goroutine for sub under a fresh per-sub
// cancellable context derived from runCtx, first cancelling any existing ticker
// for the same ID. No-op when Run is not active (runCtx nil/done), or sub is
// disabled / has a non-positive interval. Caller must hold m.mu.
func (m *SubManager) startTickerLocked(sub Subscription) {
	if m.runCtx == nil || m.runCtx.Err() != nil {
		return
	}
	if !sub.Enabled || sub.Interval <= 0 {
		return
	}
	// A prepared policy generation may have been superseded before scheduling.
	// Confirm the subscription is still part of the live snapshot.
	if _, _, ok := m.find(sub.ID); !ok {
		return
	}
	m.stopTickerLocked(sub.ID)
	cctx, cancel := context.WithCancel(m.runCtx)
	m.cancels[sub.ID] = cancel
	m.workers.Add(1)
	go func() {
		defer m.workers.Done()
		m.runOne(cctx, sub)
	}()
}

// stopTickerLocked cancels and deregisters the ticker goroutine for id, if one
// is running. Idempotent. Caller must hold m.mu.
func (m *SubManager) stopTickerLocked(id string) {
	if cancel, ok := m.cancels[id]; ok {
		cancel()
		delete(m.cancels, id)
	}
}

// updateOne fetches, parses, and caches a single subscription by ID, then
// calls reload on success. On failure (fetch error, parse error, or the
// parsed entry count falling below the category's floor guard) the existing
// cache file is left untouched and reload is not called.
func (m *SubManager) updateOne(ctx context.Context, id string) UpdateResult {
	m.mu.Lock()
	sub, _, ok := m.find(id)
	m.mu.Unlock()
	if !ok {
		return UpdateResult{ID: id, OK: false, Err: fmt.Sprintf("subscription %q not found", id)}
	}
	return m.fetchAndCache(ctx, sub)
}

// fetchAndCache performs the actual fetch -> parse -> floor-guard -> atomic
// write -> reload pipeline for one subscription, and records the outcome in
// m.health. This is the single canonical point for periodic subscription
// refreshes, so health is recorded here once rather than at each caller.
func (m *SubManager) fetchAndCache(ctx context.Context, sub Subscription) UpdateResult {
	m.txMu.Lock()
	defer m.txMu.Unlock()
	res := m.doFetchAndCache(ctx, sub)
	m.logResult(sub, res)
	m.recordHealth(res)
	return res
}

type subscriptionFileBackup struct {
	path   string
	data   []byte
	mode   os.FileMode
	exists bool
}

// preparedPolicySubscriptions is a two-phase, lock-held policy subscription
// generation. Prepare performs validation and network fetches without touching
// subscriptions.json or cache files. CommitFiles is called only inside the
// PolicyRuleManager revision CAS; Publish makes the in-memory/ticker state live.
type preparedPolicySubscriptions struct {
	m              *SubManager
	final          []Subscription
	writes         map[string][]string
	removes        map[string]bool
	results        []UpdateResult
	backups        []subscriptionFileBackup
	filesCommitted bool
	released       bool
}

func readSubscriptionBackup(path string) (subscriptionFileBackup, error) {
	b := subscriptionFileBackup{path: path, mode: 0o644}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return b, nil
		}
		return b, err
	}
	b.exists, b.data = true, data
	if info, err := os.Stat(path); err == nil {
		b.mode = info.Mode().Perm()
	}
	return b, nil
}

func cachedRuleLines(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			out = append(out, line)
		}
	}
	return out, nil
}

// PreparePolicyGeneration validates desired, fetches each list into memory,
// and captures rollback backups while holding txMu+mu. Fetch failures are
// offline-safe: an existing cache remains untouched; when only the category
// moved and the URL/format are unchanged, its last-good entries are staged at
// the new path. No durable or live state changes in this phase.
func (m *SubManager) PreparePolicyGeneration(ctx context.Context, desired []Subscription) (*preparedPolicySubscriptions, error) {
	m.txMu.Lock()
	m.mu.Lock()
	ok := false
	defer func() {
		if !ok {
			m.mu.Unlock()
			m.txMu.Unlock()
		}
	}()

	seen := make(map[string]bool, len(desired))
	for _, s := range desired {
		if err := validateSubscription(s); err != nil {
			return nil, fmt.Errorf("prepare policy subscriptions: %w", err)
		}
		if !policyOwnedCategory(s.Category) {
			return nil, fmt.Errorf("prepare policy subscriptions: category %q is not policy-owned", s.Category)
		}
		if seen[s.ID] {
			return nil, fmt.Errorf("prepare policy subscriptions: duplicate id %q", s.ID)
		}
		seen[s.ID] = true
	}
	if err := validateUniqueSubscriptionCachePaths(desired); err != nil {
		return nil, fmt.Errorf("prepare policy subscriptions: %w", err)
	}

	current := append([]Subscription(nil), m.subs...)
	oldByID := make(map[string]Subscription, len(current))
	final := make([]Subscription, 0, len(current)+len(desired))
	for _, s := range current {
		oldByID[s.ID] = s
		if !policyOwnedCategory(s.Category) {
			final = append(final, s)
		}
	}
	final = append(final, desired...)
	if err := validateUniqueSubscriptionCachePaths(final); err != nil {
		return nil, fmt.Errorf("prepare policy subscriptions: final set: %w", err)
	}

	p := &preparedPolicySubscriptions{
		m:       m,
		final:   final,
		writes:  make(map[string][]string),
		removes: make(map[string]bool),
	}
	desiredPaths := make(map[string]bool, len(desired))
	for _, s := range desired {
		target := m.cachePath(s)
		desiredPaths[target] = true
		entries, err := m.fetchAndParse(ctx, s)
		if err != nil && ctx.Err() != nil {
			return nil, fmt.Errorf("prepare policy subscriptions: %w", ctx.Err())
		}
		if err == nil && len(entries) < domainFloor {
			err = fmt.Errorf("parsed %d entries, below floor guard %d", len(entries), domainFloor)
		}
		if err == nil {
			err = validateSubscriptionShrink(target, len(entries))
		}
		if err == nil {
			p.writes[target] = entries
			p.results = append(p.results, UpdateResult{ID: s.ID, OK: true, Entries: len(entries)})
			continue
		}
		p.results = append(p.results, UpdateResult{ID: s.ID, OK: false, Err: err.Error()})
		if _, statErr := os.Stat(target); statErr == nil {
			continue // keep last-good cache at the unchanged target
		}
		if old, exists := oldByID[s.ID]; exists && old.URL == s.URL && old.Format == s.Format {
			oldPath := m.cachePath(old)
			if oldPath != target {
				if oldEntries, readErr := cachedRuleLines(oldPath); readErr == nil {
					p.writes[target] = oldEntries
				}
			}
		}
	}
	for _, s := range current {
		if policyOwnedCategory(s.Category) {
			path := m.cachePath(s)
			if !desiredPaths[path] {
				p.removes[path] = true
			}
		}
	}

	paths := map[string]bool{m.path: true}
	for path := range p.writes {
		paths[path] = true
	}
	for path := range p.removes {
		paths[path] = true
	}
	for path := range paths {
		b, err := readSubscriptionBackup(path)
		if err != nil {
			return nil, fmt.Errorf("prepare policy subscriptions: backup %s: %w", path, err)
		}
		p.backups = append(p.backups, b)
	}
	ok = true
	return p, nil
}

func writeSubscriptionsFile(path string, subs []Subscription) error {
	doc := subscriptionsFile{Version: subsSchemaVersion, Subscriptions: subs}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return fmt.Errorf("subscriptions: marshal: %w", err)
	}
	return atomicWriteFile(path, append(data, '\n'), 0o644)
}

func (p *preparedPolicySubscriptions) CommitFiles() error {
	if p == nil || p.released {
		return errors.New("policy subscriptions: prepared generation is closed")
	}
	// Mark before the first mutation so a mid-commit error restores the prefix
	// already written, not just fully completed commits.
	p.filesCommitted = true
	for path, entries := range p.writes {
		if err := atomicWriteLines(path, entries); err != nil {
			return err
		}
	}
	for path := range p.removes {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := writeSubscriptionsFile(p.m.path, p.final); err != nil {
		return err
	}
	return nil
}

func (p *preparedPolicySubscriptions) restoreFiles() error {
	var errs []error
	for _, b := range p.backups {
		if !b.exists {
			if err := os.Remove(b.path); err != nil && !errors.Is(err, os.ErrNotExist) {
				errs = append(errs, err)
			}
			continue
		}
		if err := atomicWriteFile(b.path, b.data, b.mode); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (p *preparedPolicySubscriptions) release() {
	if p == nil || p.released {
		return
	}
	p.released = true
	p.m.mu.Unlock()
	p.m.txMu.Unlock()
}

// Rollback restores every durable file touched by CommitFiles and leaves the
// old in-memory subscriptions/tickers intact.
func (p *preparedPolicySubscriptions) Rollback() error {
	if p == nil || p.released {
		return nil
	}
	var err error
	if p.filesCommitted {
		err = p.restoreFiles()
	}
	p.release()
	return err
}

// Publish installs the already-committed subscription model and reschedules
// policy tickers, then releases the transaction locks.
func (p *preparedPolicySubscriptions) Publish() {
	if p == nil || p.released {
		return
	}
	for _, s := range p.m.subs {
		if policyOwnedCategory(s.Category) {
			p.m.stopTickerLocked(s.ID)
			delete(p.m.health, s.ID)
		}
	}
	p.m.subs = append([]Subscription(nil), p.final...)
	for _, res := range p.results {
		p.m.health[res.ID] = SubHealth{
			At: time.Now().UTC().Format(time.RFC3339), OK: res.OK, Entries: res.Entries, Err: res.Err,
		}
	}
	for _, s := range p.m.subs {
		if policyOwnedCategory(s.Category) {
			p.m.startTickerLocked(s)
		}
	}
	p.release()
}

// logResult emits a journald line for a fetch outcome. Failures are always
// logged (the slow-burn class this subsystem exists to survive: a subscription
// — e.g. chnroute, the arbitration core — can silently stop updating for weeks,
// and journald is the daemon's only log sink). Successes are logged only when
// the parsed entry count changed since the last fetch, to keep steady-state
// ticks quiet. Must be called BEFORE recordHealth so it sees the prior count.
func (m *SubManager) logResult(sub Subscription, res UpdateResult) {
	host := sub.URL
	if u, err := url.Parse(sub.URL); err == nil && u.Host != "" {
		host = u.Host
	}
	if !res.OK {
		log.Printf("subscription %s [%s/%s @ %s]: update FAILED: %s",
			sub.ID, sub.Category, sub.Name, host, res.Err)
		return
	}
	m.mu.Lock()
	prev, had := m.health[sub.ID]
	m.mu.Unlock()
	if !had || prev.Entries != res.Entries {
		log.Printf("subscription %s [%s/%s @ %s]: updated, %d entries",
			sub.ID, sub.Category, sub.Name, host, res.Entries)
	}
}

// doFetchAndCache is the actual fetch -> parse -> floor-guard -> atomic
// write -> reload pipeline, split out from fetchAndCache purely so every
// return path funnels through fetchAndCache's single recordHealth call.
func (m *SubManager) doFetchAndCache(ctx context.Context, sub Subscription) UpdateResult {
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
	if err := validateSubscriptionShrink(path, len(entries)); err != nil {
		return UpdateResult{ID: sub.ID, OK: false, Err: err.Error()}
	}
	// Steady-state ticks usually re-download identical content. Skipping the
	// write+reload then matters: every reload flushes the whole response cache
	// (swapRuleSets), so an unconditional reload per subscription interval
	// cold-starts the cache and creates avoidable upstream work even though
	// concurrent identical misses are coalesced.
	if linesUnchangedOnDisk(path, entries) {
		return UpdateResult{ID: sub.ID, OK: true, Entries: len(entries)}
	}
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
	if mediaType, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type")); err == nil {
		switch strings.ToLower(mediaType) {
		case "text/html", "application/xhtml+xml":
			return nil, fmt.Errorf("subscription %s: refusing HTML response", sub.ID)
		}
	}

	// Read one byte past the cap so an oversized body is DETECTED, not silently
	// truncated: io.LimitReader(cap) returns exactly cap bytes with err==nil on
	// overflow, and a mid-line truncated list would then flow into the parser and
	// (if it still clears the floor guard) atomically replace the good cache with
	// a corrupt one. Bailing here keeps the old cache instead.
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxSubscriptionBodySize+1))
	if err != nil {
		return nil, fmt.Errorf("subscription %s: read body: %w", sub.ID, err)
	}
	if len(body) > maxSubscriptionBodySize {
		return nil, fmt.Errorf("subscription %s: body exceeds %d bytes (refusing to cache a truncated list)", sub.ID, maxSubscriptionBodySize)
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

func validateSubscriptionShrink(path string, newCount int) error {
	oldEntries, err := cachedRuleLines(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("read existing cache for shrink guard: %w", err)
	}
	oldCount := len(oldEntries)
	if oldCount < shrinkGuardMinimumExisting {
		return nil
	}
	if newCount*100 < oldCount*shrinkGuardMinimumRetainedPct {
		return fmt.Errorf(
			"parsed %d entries versus previous %d (below %d%% shrink guard) — keeping existing cache",
			newCount, oldCount, shrinkGuardMinimumRetainedPct,
		)
	}
	return nil
}

// atomicWriteLines writes one entry per line to path via a temp file in the
// same directory, followed by an atomic rename. The parent (category)
// directory is created if missing.
// linesUnchangedOnDisk reports whether path already holds exactly entries in
// atomicWriteLines' output format (one entry per line, trailing newline).
// Any read error (including "file does not exist") counts as changed.
func linesUnchangedOnDisk(path string, entries []string) bool {
	existing, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	want := len(entries) // one newline per entry
	for _, e := range entries {
		want += len(e)
	}
	if len(existing) != want {
		return false
	}
	var b strings.Builder
	b.Grow(want)
	for _, e := range entries {
		b.WriteString(e)
		b.WriteByte('\n')
	}
	return string(existing) == b.String()
}

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

// policyOwnedCategory reports whether cat is one of the policy-compiler-owned
// DNS categories. It is deliberately narrower than validCategories, which
// also allows the system-owned chnroute subscription.
func policyOwnedCategory(cat string) bool {
	return cat == "block" || cat == "direct" || cat == "proxy"
}

const (
	// maxSubscriptionIDLen matches the current policy rule ID schema.
	maxSubscriptionIDLen = 64
	// maxSubscriptionNameLen leaves room for generated provider prefixes while
	// keeping the cache basename well below common filesystem limits.
	maxSubscriptionNameLen = 128
)

// validateSubscription checks one current-schema subscription definition.
func validateSubscription(s Subscription) error {
	if s.ID == "" {
		return errors.New("subscription: id must not be empty")
	}
	if len(s.ID) > maxSubscriptionIDLen {
		return fmt.Errorf("subscription: id %q too long (%d bytes; max %d)", s.ID, len(s.ID), maxSubscriptionIDLen)
	}
	if !validCategories[s.Category] {
		return fmt.Errorf("subscription: invalid category %q", s.Category)
	}
	if err := validateSubscriptionName(s.Name); err != nil {
		return err
	}
	switch s.Category {
	case "chnroute":
		if s.Format != "cidr" {
			return fmt.Errorf("subscription: chnroute format %q must be cidr", s.Format)
		}
	default: // block, direct, proxy
		if !validSubscriptionFormats[s.Format] {
			return fmt.Errorf("subscription: %s format %q must be plain|gfwlist|dnsmasq|hosts", s.Category, s.Format)
		}
	}
	if s.Enabled && s.Interval <= 0 {
		return errors.New("subscription: enabled interval must be positive")
	}
	if s.URL == "" {
		return errors.New("subscription: url must not be empty")
	}
	if err := validateSubscriptionURLScheme(s.URL); err != nil {
		return err
	}
	return nil
}

type subscriptionCacheKey struct {
	category string
	name     string
}

// validateUniqueSubscriptionCachePaths prevents two definitions from owning
// the same rulesDir/<category>/<name>.txt file. IDs identify subscriptions,
// but the category/name pair identifies the durable cache they mutate.
func validateUniqueSubscriptionCachePaths(subs []Subscription) error {
	seen := make(map[subscriptionCacheKey]string, len(subs))
	for _, sub := range subs {
		key := subscriptionCacheKey{category: sub.Category, name: sub.Name}
		if previousID, ok := seen[key]; ok {
			return fmt.Errorf(
				"subscription: duplicate cache path for category %q and name %q (ids %q and %q)",
				sub.Category, sub.Name, previousID, sub.ID,
			)
		}
		seen[key] = sub.ID
	}
	return nil
}

// validateSubscriptionURLScheme rejects non-HTTP(S) fetch targets.
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
// component because cachePath uses it as a file name below rulesDir.
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
	if len(name) > maxSubscriptionNameLen {
		return fmt.Errorf("subscription: name %q too long (%d bytes; max %d)", name, len(name), maxSubscriptionNameLen)
	}
	return nil
}

// Run starts one goroutine per enabled subscription, ticking at its
// configured interval and refreshing it on each tick. If a subscription's
// cache file is missing when Run starts, an immediate refresh is performed
// before entering the ticker loop (so a fresh install populates its cache
// promptly rather than waiting a full interval). Run blocks until ctx is
// done, even when there are zero (or zero enabled) subscriptions to start
// with, allowing a later policy publication to schedule its subscriptions.
//
// ctx is also stored on the manager (m.runCtx) for the duration of the call,
// so Publish can schedule a newly committed policy generation without a
// process restart.
func (m *SubManager) Run(ctx context.Context) {
	m.mu.Lock()
	m.runCtx = ctx
	subs := make([]Subscription, len(m.subs))
	copy(subs, m.subs)
	for _, sub := range subs {
		// startTickerLocked registers a per-sub cancel derived from ctx and
		// skips disabled or non-positive-interval subscriptions.
		m.startTickerLocked(sub)
	}
	m.mu.Unlock()

	// The per-subscription ticker goroutines run on child contexts of ctx, so
	// they observe the same cancellation.
	<-ctx.Done()

	// Close worker admission before waiting. Every startTickerLocked call holds
	// mu and checks runCtx, so no WaitGroup Add can race with Wait after this
	// point. Waiting also prevents callers from tearing down rulesDir while an
	// in-flight atomic cache write is still completing.
	m.mu.Lock()
	m.runCtx = nil
	for id := range m.cancels {
		m.cancels[id]()
		delete(m.cancels, id)
	}
	m.mu.Unlock()
	m.workers.Wait()
}

// nextBackoff returns the next retry delay for a failed subscription fetch:
// starts at 1m, doubles, caps at 30m. This bounds the "failed initial fetch
// waits a whole interval" gap while not hammering a persistently-down source.
func nextBackoff(cur time.Duration) time.Duration {
	const min, max = time.Minute, 30 * time.Minute
	if cur < min {
		return min
	}
	next := cur * 2
	if next > max {
		return max
	}
	return next
}

// runOne drives the per-subscription loop for Run. It fetches immediately when
// the cache file is missing, then schedules the next fetch: the configured
// interval after a success, or a growing backoff (nextBackoff) after a failure —
// so a failed fetch is retried within minutes instead of a full interval later.
func (m *SubManager) runOne(ctx context.Context, sub Subscription) {
	var backoff time.Duration

	schedule := func(ok bool) time.Duration {
		if ok {
			backoff = 0
			return sub.Interval
		}
		backoff = nextBackoff(backoff)
		return backoff
	}

	// Immediate fetch when the cache is absent (fresh install / first run).
	next := sub.Interval
	if _, err := os.Stat(m.cachePath(sub)); err != nil && os.IsNotExist(err) {
		res := m.updateOne(ctx, sub.ID)
		next = schedule(res.OK)
	}

	timer := time.NewTimer(next)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			res := m.updateOne(ctx, sub.ID)
			timer.Reset(schedule(res.OK))
		}
	}
}
