package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
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
	domainFloor   = 1
	chnrouteFloor = 100
)

// validCategories enumerates the four rule-set categories a subscription may
// target.
var validCategories = map[string]bool{
	"block":     true,
	"direct":    true,
	"blacklist": true,
	"chnroute":  true,
}

// ErrSubNotFound is wrapped by every "no subscription with this ID" error so the
// HTTP/bot layers can map it precisely (errors.Is) instead of substring-matching
// "not found" — which would also catch an unrelated file-not-found and silently
// change API status codes.
var ErrSubNotFound = errors.New("subscription not found")

// Subscription describes one remote rule-list subscription.
type Subscription struct {
	ID       string
	Category string // block|direct|blacklist|chnroute
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

// subsSchemaVersion is the current subscriptions.json schema version. A missing
// "version" (0) is treated as this version (pre-versioning files). A file whose
// version is HIGHER than this was written by a newer binary — we log and still
// parse the fields we understand, so a downgrade degrades rather than looking
// like corruption (a bare json error).
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
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("subscriptions: parse %s: %w", path, err)
	}
	if doc.Version > subsSchemaVersion {
		log.Printf("warning: %s is schema version %d, newer than this binary understands (%d) — parsing known fields only",
			path, doc.Version, subsSchemaVersion)
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

	// runCtx is the context passed to Run, stored so a subscription added
	// later via Add (while Run is active) can launch its own ticker goroutine
	// instead of waiting for the process to restart. nil until Run is called;
	// guarded by mu like the rest of the manager's mutable state.
	runCtx context.Context

	// cancels holds, per subscription ID, the CancelFunc for its running ticker
	// goroutine (only while Run is active). It lets Remove/Replace stop exactly
	// one subscription's ticker instead of leaking it, and lets Add/Replace
	// cancel a stale ticker before spawning a fresh one — without it, Remove
	// leaked the goroutine forever and every edit (Remove+Add) double-scheduled
	// the fetch. Guarded by mu.
	cancels map[string]context.CancelFunc
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
// resolver, when non-nil, resolves the request hostname via the trust DoT
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

// List returns a snapshot copy of the currently configured subscriptions.
func (m *SubManager) List() []Subscription {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Subscription, len(m.subs))
	copy(out, m.subs)
	return out
}

// Health returns a copy of the current per-subscription fetch health map,
// keyed by subscription ID. A subscription that has never been fetched has
// no entry. Safe for concurrent use; the returned map is independent of the
// manager's internal state (mutating it has no effect on future Health()
// calls).
func (m *SubManager) Health() map[string]SubHealth {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]SubHealth, len(m.health))
	for id, h := range m.health {
		out[id] = h
	}
	return out
}

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
// disabled / has a non-positive interval. Caller must hold m.mu. The goroutine
// is spawned while holding the lock, which is safe: the `go` statement does not
// block, and runOne only takes m.mu after this method has returned.
func (m *SubManager) startTickerLocked(sub Subscription) {
	if m.runCtx == nil || m.runCtx.Err() != nil {
		return
	}
	if !sub.Enabled || sub.Interval <= 0 {
		return
	}
	// Guard against a ghost ticker: Add releases m.mu for its best-effort initial
	// fetch, then re-acquires it to call this. If a concurrent Remove(sub.ID) ran
	// in that window it found no ticker yet (stopTickerLocked was a no-op) and
	// dropped the sub from m.subs — so spawning now would leave a ticker fetching
	// a subscription that no longer exists. Confirm it's still present first.
	if _, _, ok := m.find(sub.ID); !ok {
		return
	}
	m.stopTickerLocked(sub.ID)
	cctx, cancel := context.WithCancel(m.runCtx)
	m.cancels[sub.ID] = cancel
	go m.runOne(cctx, sub)
}

// stopTickerLocked cancels and deregisters the ticker goroutine for id, if one
// is running. Idempotent. Caller must hold m.mu.
func (m *SubManager) stopTickerLocked(id string) {
	if cancel, ok := m.cancels[id]; ok {
		cancel()
		delete(m.cancels, id)
	}
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
// write -> reload pipeline for one subscription, and records the outcome in
// m.health. This is the single canonical point every real-subscription
// update path (UpdateOne, UpdateAll, and transitively Add's initial fetch and
// Run's ticker) funnels through, so health is recorded here once rather than
// at each caller.
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

// Abort closes a generation that never reached CommitFiles.
func (p *preparedPolicySubscriptions) Abort() { p.release() }

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
	// Steady-state ticks usually re-download identical content. Skipping the
	// write+reload then matters: every reload flushes the whole response cache
	// (swapRuleSets), so an unconditional reload per subscription interval
	// cold-starts the cache — and, with no singleflight, turns the miss storm
	// into a full china+trust upstream fan-out — even when nothing changed.
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

// Validate runs the same field checks Add does (bad ID/category/name/format/
// url-scheme), WITHOUT the duplicate-ID check and without any state change,
// fetch, or persist. The duplicate-ID check is skipped deliberately: Validate
// is used by the bot's add-subscription wizard to pre-check a draft whose ID
// may already exist under the target being edited, so rejecting on "ID already
// exists" would make a legitimate re-check fail. Pure and lock-free (it only
// calls validateSubscription, reading no manager state), hence safe to call
// concurrently.
func (m *SubManager) Validate(s Subscription) error {
	return validateSubscription(s)
}

// Get returns a copy of the subscription with the given ID, or ok=false if no
// subscription with that ID is configured. The returned value is independent
// of the manager's internal state — mutating it has no effect on subsequent
// Get/List calls.
func (m *SubManager) Get(id string) (Subscription, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	sub, _, ok := m.find(id)
	return sub, ok
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
	m.mu.Unlock()
	if err != nil {
		return UpdateResult{}, err
	}

	// The initial fetch is best-effort: a subscription is still validly
	// registered even if its first fetch fails (e.g. transient network
	// issue) — Run's ticker (or a later on-demand update) will retry.
	res := m.UpdateOne(context.Background(), s.ID)

	// Live reschedule: if Run is active, spawn this sub's ticker (registered by
	// ID so Remove/Replace can later stop exactly it). No-op when Run isn't
	// running or the sub is disabled/interval<=0.
	m.mu.Lock()
	m.startTickerLocked(s)
	m.mu.Unlock()

	return res, nil
}

// Remove drops a subscription by ID, stops its ticker goroutine, persists the
// change, deletes its cache file (if any), and triggers a reload.
func (m *SubManager) Remove(id string) error {
	m.mu.Lock()
	sub, idx, ok := m.find(id)
	if !ok {
		m.mu.Unlock()
		return fmt.Errorf("subscription: id %q: %w", id, ErrSubNotFound)
	}
	m.stopTickerLocked(id) // stop its ticker before dropping the sub (no leak)
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

// Replace updates the subscription with id in place: it validates s, swaps the
// slice entry (persisting), reschedules the ticker (cancel old, start new), and
// re-fetches. s.ID must equal id. Unlike the old Remove+Add dance the API PATCH
// and bot toggle used, there is never a window in which the subscription exists
// under neither definition, and the ticker is neither leaked nor double-
// scheduled. Returns the re-fetch's UpdateResult.
func (m *SubManager) Replace(id string, s Subscription) (UpdateResult, error) {
	if s.ID != id {
		return UpdateResult{}, fmt.Errorf("subscription: replace id mismatch (%q != %q)", s.ID, id)
	}
	if err := validateSubscription(s); err != nil {
		return UpdateResult{}, err
	}

	m.mu.Lock()
	old, idx, ok := m.find(id)
	if !ok {
		m.mu.Unlock()
		return UpdateResult{}, fmt.Errorf("subscription: id %q: %w", id, ErrSubNotFound)
	}
	m.subs[idx] = s
	if err := m.persistLocked(); err != nil {
		m.subs[idx] = old // roll back the in-memory swap on persist failure
		m.mu.Unlock()
		return UpdateResult{}, err
	}
	m.stopTickerLocked(id) // stop the old-interval ticker before re-fetch
	m.mu.Unlock()

	// If the category or name changed, the old cache file is now orphaned (it
	// would keep merging into its old category's rules); remove it and reload so
	// the stale entries drop even if the new fetch below fails.
	pathChanged := m.cachePath(old) != m.cachePath(s)
	if pathChanged {
		_ = os.Remove(m.cachePath(old))
		if m.reload != nil {
			_ = m.reload()
		}
	}

	// Re-fetch under the new definition (writes the new cache + reloads on
	// success; keeps the old cache on failure, as UpdateOne always does).
	res := m.UpdateOne(context.Background(), s.ID)

	// Start the ticker on the new interval/enabled state.
	m.mu.Lock()
	m.startTickerLocked(s)
	m.mu.Unlock()

	return res, nil
}

// Sync reconciles the manager's tracked subscription set to desired — the
// policy compiler's `CompiledDNS.Subs` (see policy_compile.go), which is the
// sole source of truth for what gets fetched once the policy engine is fully
// wired (C4/D3) — but ONLY within the policy-owned categories
// (policyOwnedCategory/policyManualCategories, policy_engine.go:
// block/direct/blacklist). It adds every subscription in desired that
// isn't currently tracked, removes every POLICY-OWNED tracked subscription
// absent from desired, and replaces any tracked subscription whose
// definition (Category/Name/URL/Format/Enabled/Interval) differs from its
// desired counterpart — Subscription has no slice/map fields, so a plain
// `!=` comparison is exact. It is idempotent: a Sync call whose desired set
// exactly matches the current one performs no Add/Remove/Replace at all (and
// hence no re-fetch, ticker churn, or reload).
//
// A tracked subscription in a category the policy compiler never produces —
// chiefly chnroute, the install-seeded CN-IP-list arbitration input
// (intentCategory, policy_compile.go, never maps any Intent to "chnroute";
// spec §13 keeps chnroute a system arbitration input, not a policy rule) —
// is NEVER in CompiledDNS.Subs and must not be treated as "no longer
// desired": Sync leaves it fully alone (tracked, cached, still ticking)
// regardless of what the passed-in desired set contains. Without this
// carve-out, the first policy CompileAndApply on a fresh daemon would delete
// the chnroute subscription and its cache, permanently killing CN-IP-list
// auto-refresh (the bundled ChnrouteFile snapshot survives, so there is no
// immediate outage — but the list would never refresh again).
//
// Sync itself takes no lock — it drives the manager purely through the
// already-locked public CRUD methods (Add/Remove/Replace/List), so it
// composes correctly with any concurrent caller of those methods (the old
// managed HTTP/bot subscription surface, kept alongside Sync until Task D3
// retires it). Every per-subscription failure is collected and returned
// together via errors.Join rather than aborting the reconcile on the first
// one, so one bad subscription in the desired set doesn't block the rest from
// converging.
func (m *SubManager) Sync(desired []Subscription) error {
	current := m.List()
	have := make(map[string]Subscription, len(current))
	for _, s := range current {
		have[s.ID] = s
	}

	want := make(map[string]bool, len(desired))
	var errs []error
	for _, s := range desired {
		want[s.ID] = true
		old, exists := have[s.ID]
		switch {
		case !exists:
			if _, err := m.Add(s); err != nil {
				errs = append(errs, fmt.Errorf("sync: add %s: %w", s.ID, err))
			}
		case old != s:
			if _, err := m.Replace(s.ID, s); err != nil {
				errs = append(errs, fmt.Errorf("sync: replace %s: %w", s.ID, err))
			}
		}
	}

	for id, s := range have {
		if want[id] {
			continue
		}
		if !policyOwnedCategory(s.Category) {
			// Not a policy-rule category (e.g. chnroute) — the desired set
			// (CompiledDNS.Subs) never carries these, so absence here means
			// nothing; leave it tracked. See the Sync doc comment above.
			continue
		}
		if err := m.Remove(id); err != nil {
			errs = append(errs, fmt.Errorf("sync: remove %s: %w", id, err))
		}
	}

	return errors.Join(errs...)
}

// policyOwnedCategory reports whether cat is one of the policy-compiler-owned
// DNS categories (policyManualCategories, policy_engine.go) — the only
// categories that can ever appear in a policy compile's desired subscription
// set (CompiledDNS.Subs). Reused here (rather than duplicating the list) so
// the two can never drift apart. Note this is deliberately narrower than
// validCategories above, which also allows "chnroute" — chnroute is a valid
// subscription category but not a policy-owned one; see Sync's doc comment.
func policyOwnedCategory(cat string) bool {
	for _, c := range policyManualCategories {
		if c == cat {
			return true
		}
	}
	return false
}

// maxSubscriptionIDLen bounds a subscription ID's byte length. The ID is
// embedded in Telegram inline-keyboard callback_data as "subview:<id>" (and
// subref/subtog/subdel), and Telegram hard-caps callback_data at 64 bytes; the
// longest prefix is 8 bytes, so an ID over ~56 bytes makes the whole keyboard
// invalid and the bot's subscription menu silently stops rendering. 48 leaves
// comfortable margin. The bot wizard sets Name == ID, so validateSubscriptionName
// enforces the same bound (a multibyte name is measured in BYTES, not runes).
const maxSubscriptionIDLen = 48

// validateSubscription checks the fields required before a subscription can
// be added.
func validateSubscription(s Subscription) error {
	if s.ID == "" {
		return errors.New("subscription: id must not be empty")
	}
	if len(s.ID) > maxSubscriptionIDLen {
		return fmt.Errorf("subscription: id %q too long (%d bytes; max %d — it is embedded in Telegram callback_data, capped at 64)", s.ID, len(s.ID), maxSubscriptionIDLen)
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
	if len(name) > maxSubscriptionIDLen {
		return fmt.Errorf("subscription: name %q too long (%d bytes; max %d)", name, len(name), maxSubscriptionIDLen)
	}
	return nil
}

// persistLocked marshals m.subs to JSON and atomically writes it to m.path.
// Callers must hold m.mu.
func (m *SubManager) persistLocked() error {
	doc := subscriptionsFile{Version: subsSchemaVersion, Subscriptions: m.subs}
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
	m.runCtx = ctx
	subs := make([]Subscription, len(m.subs))
	copy(subs, m.subs)
	for _, sub := range subs {
		// startTickerLocked registers a per-sub cancel derived from ctx (and
		// skips disabled / interval<=0 subs), so Remove/Replace can later stop
		// exactly one ticker.
		m.startTickerLocked(sub)
	}
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		m.runCtx = nil
		// Cancel and drop every remaining ticker so none outlives Run.
		for id := range m.cancels {
			m.cancels[id]()
			delete(m.cancels, id)
		}
		m.mu.Unlock()
	}()

	// Block until ctx is cancelled. The per-subscription ticker goroutines run
	// on child contexts of ctx, so they observe the same cancellation; keeping
	// runCtx valid for the whole Run lifetime is what lets Add/Replace live-
	// reschedule (see the runCtx doc above).
	<-ctx.Done()
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
		res := m.UpdateOne(ctx, sub.ID)
		next = schedule(res.OK)
	}

	timer := time.NewTimer(next)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			res := m.UpdateOne(ctx, sub.ID)
			timer.Reset(schedule(res.OK))
		}
	}
}
