// Package main implements the console-managed, ordered DNS policy model. Each
// rule matches a name (or a subscription of names) and maps it to a
// block/direct/proxy intent. The policy layer decides only DNS steering:
// IntentProxy means
// "steer to the gateway" and nothing more — it carries no selector/target.
// Once traffic reaches the box, whether it egresses direct or through a node
// is entirely the operator's mihomo config (edited as raw text, see the
// raw mihomo config editor), never a per-rule field here. A
// PolicyRule therefore never references a mihomo proxy-group.
//
// Matcher kinds are deliberately narrow: domain, domain-suffix,
// domain-keyword, and subscription.
package main

import (
	"context"
	crand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"sync"
	"time"
)

// MatcherKind is how a PolicyRule's Matcher.Value is interpreted.
type MatcherKind string

const (
	// KindDomain matches the exact FQDN only.
	KindDomain MatcherKind = "domain"
	// KindDomainSuffix matches the FQDN itself or any subdomain of it
	// (label-bounded — mirrors the existing rules.go suffix DomainSet).
	KindDomainSuffix MatcherKind = "domain-suffix"
	// KindDomainKeyword matches any FQDN containing Value as a substring.
	KindDomainKeyword MatcherKind = "domain-keyword"
	// KindSubscription expands to many domain-suffix-style matches fetched
	// from a remote list at Value (a URL); Format/Interval govern the fetch.
	KindSubscription MatcherKind = "subscription"
)

// Intent is what a matching query should be resolved as.
type Intent string

const (
	// IntentBlock answers the query with NXDOMAIN (no upstream resolution).
	IntentBlock Intent = "block"
	// IntentDirect resolves the query directly (china/trust arbitration),
	// bypassing the gateway.
	IntentDirect Intent = "direct"
	// IntentProxy steers the resolved/rewritten answer to the gateway IP —
	// "walk through the box" and nothing more. What mihomo does with that
	// traffic once it arrives (direct-from-box or via a proxy node) is
	// entirely the operator's mihomo config; IntentProxy carries no target.
	IntentProxy Intent = "proxy"
)

// FallbackPolicy governs how a query that matches no PolicyRule is handled.
type FallbackPolicy string

const (
	// FallbackAuto keeps the existing china/trust Arbitrate behavior (CN
	// answer wins, else trust) for anything not covered by an explicit rule.
	FallbackAuto FallbackPolicy = "auto"
	// FallbackDirect resolves every unmatched query directly, never proxied.
	FallbackDirect FallbackPolicy = "direct"
	// FallbackGateway steers every unmatched query to the gateway IP.
	FallbackGateway FallbackPolicy = "gateway"
)

// Matcher is a name-based match spec. Format and a positive Interval are
// required when Kind == KindSubscription (Value is then the list URL); both
// fields must be the zero value otherwise.
type Matcher struct {
	Kind     MatcherKind
	Value    string
	Format   string        // subscription parser: plain|gfwlist|dnsmasq|hosts
	Interval time.Duration // subscription refresh interval
}

// matcherJSON is Matcher's on-disk/wire JSON shape: identical except
// Interval is a human-readable Go duration string (e.g. "24h0m0s") instead
// of a nanosecond count.
type matcherJSON struct {
	Kind     MatcherKind `json:"kind"`
	Value    string      `json:"value"`
	Format   string      `json:"format,omitempty"`
	Interval string      `json:"interval,omitempty"`
}

// MarshalJSON renders Interval as a Go duration string.
func (m Matcher) MarshalJSON() ([]byte, error) {
	mj := matcherJSON{Kind: m.Kind, Value: m.Value, Format: m.Format}
	if m.Interval > 0 {
		mj.Interval = m.Interval.String()
	}
	return json.Marshal(mj)
}

// UnmarshalJSON parses Interval from a Go duration string.
func (m *Matcher) UnmarshalJSON(data []byte) error {
	var raw matcherJSON
	if err := unmarshalStrictJSON(data, &raw); err != nil {
		return err
	}
	d, err := parseOptionalDuration(raw.Interval)
	if err != nil {
		return fmt.Errorf("matcher %q: %w", raw.Value, err)
	}
	m.Kind, m.Value, m.Format, m.Interval = raw.Kind, raw.Value, raw.Format, d
	return nil
}

// PolicyRule is one ordered entry in the unified rule list: Matcher decides
// which queries it covers and Intent decides how they're resolved. Order is
// the rule's position in evaluation order (lowest first); disabled rules
// (Enabled == false) are kept in the model but never matched. A PolicyRule
// carries no selector/target — see the package doc comment's "binary
// policy" note.
type PolicyRule struct {
	ID      string  `json:"id"`
	Order   int     `json:"order"`
	Matcher Matcher `json:"matcher"`
	Intent  Intent  `json:"intent"`
	Enabled bool    `json:"enabled"`
}

// Fallback governs unmatched-query handling: Policy selects the strategy
// (see FallbackPolicy). A gateway fallback steers to the gateway IP; it
// carries no selector/target (see the package doc comment).
type Fallback struct {
	Policy FallbackPolicy `json:"policy"`
}

// PolicyModel is the top-level, console-managed shape of policy.json: an
// ordered rule list plus the fallback strategy for anything unmatched.
type PolicyModel struct {
	Version  int          `json:"version"`
	Rules    []PolicyRule `json:"rules"`
	Fallback Fallback     `json:"fallback"`
}

// policySchemaVersion is the exact policy.json schema version accepted.
const policySchemaVersion = 1

// LoadPolicyModel reads policy.json. A missing file is not an error: it
// returns an empty, version-stamped model with the default auto fallback.
func LoadPolicyModel(path string) (PolicyModel, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return PolicyModel{
				Version:  policySchemaVersion,
				Fallback: Fallback{Policy: FallbackAuto},
			}, nil
		}
		return PolicyModel{}, fmt.Errorf("policy: read %s: %w", path, err)
	}
	var m PolicyModel
	if err := unmarshalStrictJSON(data, &m); err != nil {
		return PolicyModel{}, fmt.Errorf("policy: parse %s: %w", path, err)
	}
	if m.Version != policySchemaVersion {
		return PolicyModel{}, fmt.Errorf("policy: %s: unsupported schema version %d (want %d)", path, m.Version, policySchemaVersion)
	}
	if err := validatePolicyModel(m); err != nil {
		return PolicyModel{}, fmt.Errorf("policy: %s: %w", path, err)
	}
	return m, nil
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

// ErrInvalidPolicy wraps every caller-caused validation failure for a
// PolicyRule/Fallback, so the console HTTP layer can map it to 400 (vs 500
// for a disk failure while persisting an otherwise-valid entry).
var ErrInvalidPolicy = errors.New("invalid policy rule")

// ErrPolicyNotFound is wrapped by every "no rule with this ID" error.
var ErrPolicyNotFound = errors.New("policy rule not found")

// ErrPolicyRevisionChanged means the policy model changed while an apply was
// preparing external state. The prepared generation is discarded; the caller
// can retry against the new revision rather than publishing stale policy.
var ErrPolicyRevisionChanged = errors.New("policy model changed during apply")

// ---------------------------------------------------------------------------
// Shared store-boundary helpers.
// ---------------------------------------------------------------------------

// atomicWriteFile writes data to path via a same-directory temp file +
// rename (create-temp + rename), so a reader never observes a partially
// written file. The parent directory is created if missing.
func atomicWriteFile(path string, data []byte, mode os.FileMode) error {
	return atomicWriteFileContext(context.Background(), path, data, mode)
}

func atomicWriteFileContext(ctx context.Context, path string, data []byte, mode os.FileMode) error {
	if ctx == nil {
		return errors.New("policy: write context is required")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("policy: mkdir %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".policy-*.tmp")
	if err != nil {
		return fmt.Errorf("policy: create temp in %s: %w", dir, err)
	}
	tmpPath := tmp.Name()
	succeeded := false
	defer func() {
		if !succeeded {
			os.Remove(tmpPath)
		}
	}()
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return fmt.Errorf("policy: chmod %s: %w", tmpPath, err)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("policy: write %s: %w", tmpPath, err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("policy: sync %s: %w", tmpPath, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("policy: close %s: %w", tmpPath, err)
	}
	// Enter the non-interruptible atomic rename only while the caller still
	// owns a live operation. Cancellation after this check races with a commit
	// already in progress and is handled as normal commit-point semantics.
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("policy: rename to %s: %w", path, err)
	}
	succeeded = true
	return nil
}

// newPolicyID mints a random ID for a new PolicyRule, prefixed for
// readability (e.g. "prule-a1b2c3d4"). Falls back to a timestamp-derived ID
// on an exhausted entropy source rather than failing the mutation outright.
func newPolicyID(prefix string) string {
	var b [8]byte
	if _, err := crand.Read(b[:]); err != nil {
		return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
	}
	return prefix + "-" + hex.EncodeToString(b[:])
}

// parseOptionalDuration parses a Go duration string, treating "" as zero.
// Validation then requires a positive value for subscription matchers and the
// zero value for every inline matcher kind.
func parseOptionalDuration(raw string) (time.Duration, error) {
	if raw == "" {
		return 0, nil
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("invalid interval %q: %w", raw, err)
	}
	return d, nil
}

// validatePolicyField is the shared store-boundary guard for every
// user-supplied policy-model field: it rejects, before the value is ever
// persisted, a newline/carriage-return/other ASCII control byte (< 0x20).
func validatePolicyField(field, s string) error {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c == '\n' || c == '\r' || c < 0x20 {
			return fmt.Errorf("%w: %s must not contain a newline, carriage return, or other control character", ErrInvalidPolicy, field)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// PolicyRuleManager
// ---------------------------------------------------------------------------

// PolicyRuleManager holds the in-memory, mutex-guarded PolicyModel and
// persists every mutation to policy.json before returning. policy.json
// carries no secrets (a policy subscription's Matcher.Value is a PUBLIC list
// URL) so the whole model is plain JSON on disk — no sealed side-store.
type PolicyRuleManager struct {
	path string

	mu       sync.Mutex
	model    PolicyModel
	revision uint64
}

// NewPolicyRuleManager loads (or initializes) the policy model from path. A
// missing file is not an error (LoadPolicyModel starts an empty,
// default-fallback model).
func NewPolicyRuleManager(path string) (*PolicyRuleManager, error) {
	model, err := LoadPolicyModel(path)
	if err != nil {
		return nil, err
	}
	return &PolicyRuleManager{path: path, model: model, revision: 1}, nil
}

// saveLocked marshals the current model (Version-stamped, Rules
// defensively copied so a concurrent caller mutating m.model.Rules after
// unlock can't race the encoder) and writes it via atomicWriteFile — a
// same-directory temp file + rename, so a reader never observes a
// partially-written policy.json. Callers must hold m.mu.
func (m *PolicyRuleManager) saveLocked() error {
	diskModel := m.model
	diskModel.Rules = append([]PolicyRule(nil), m.model.Rules...)
	diskModel.Version = policySchemaVersion

	data, err := json.MarshalIndent(diskModel, "", "  ")
	if err != nil {
		return fmt.Errorf("policy: marshal: %w", err)
	}
	return atomicWriteFile(m.path, append(data, '\n'), 0o644)
}

// validSubscriptionFormats enumerates the ParseDomains (parsers.go) formats
// accepted by policy matchers and block/direct/proxy Subscription definitions.
// It deliberately excludes "cidr", which is reserved for chnroute.
var validSubscriptionFormats = map[string]bool{
	"plain": true, "gfwlist": true, "dnsmasq": true, "hosts": true,
}

// validMatcherKinds enumerates the supported matcher surface.
var validMatcherKinds = map[MatcherKind]bool{
	KindDomain: true, KindDomainSuffix: true, KindDomainKeyword: true, KindSubscription: true,
}

// validIntents enumerates the only three legal Intent values.
var validIntents = map[Intent]bool{IntentBlock: true, IntentDirect: true, IntentProxy: true}

// validFallbackPolicies enumerates the only three legal FallbackPolicy values.
var validFallbackPolicies = map[FallbackPolicy]bool{FallbackAuto: true, FallbackDirect: true, FallbackGateway: true}

var policyIDRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

func validatePolicyModel(model PolicyModel) error {
	if err := validateFallback(model.Fallback); err != nil {
		return err
	}
	seen := make(map[string]bool, len(model.Rules))
	for i, rule := range model.Rules {
		if !policyIDRE.MatchString(rule.ID) {
			return fmt.Errorf("%w: rule id %q must be a path-safe identifier", ErrInvalidPolicy, rule.ID)
		}
		if seen[rule.ID] {
			return fmt.Errorf("%w: duplicate rule id %q", ErrInvalidPolicy, rule.ID)
		}
		seen[rule.ID] = true
		if rule.Order != i {
			return fmt.Errorf("%w: rule %q order is %d, want %d", ErrInvalidPolicy, rule.ID, rule.Order, i)
		}
		if err := validatePolicyRule(rule); err != nil {
			return fmt.Errorf("rule %q: %w", rule.ID, err)
		}
	}
	return nil
}

// validateMatcher checks a Matcher's structural + injection-safety rules.
// Every kind rejects newlines, control bytes, and the reserved marker
// sentinels via validatePolicyField; a matcher value now only ever reaches
// the in-process DomainSet (never a comma-delimited rule grammar — the
// policy compiler emits DNS-only output), so a comma is legal in every kind.
func validateMatcher(mm Matcher) error {
	if !validMatcherKinds[mm.Kind] {
		return fmt.Errorf("%w: matcher kind %q unknown", ErrInvalidPolicy, mm.Kind)
	}
	if mm.Value == "" {
		return fmt.Errorf("%w: matcher value must not be empty", ErrInvalidPolicy)
	}
	switch mm.Kind {
	case KindSubscription:
		if err := validatePolicyField("matcher.value", mm.Value); err != nil {
			return err
		}
		if err := validateSubscriptionURLScheme(mm.Value); err != nil {
			return fmt.Errorf("%w: %v", ErrInvalidPolicy, err)
		}
		if !validSubscriptionFormats[mm.Format] {
			return fmt.Errorf("%w: subscription format %q must be plain|gfwlist|dnsmasq|hosts", ErrInvalidPolicy, mm.Format)
		}
		if mm.Interval <= 0 {
			return fmt.Errorf("%w: subscription interval must be positive", ErrInvalidPolicy)
		}
	case KindDomain, KindDomainSuffix:
		if mm.Format != "" || mm.Interval != 0 {
			return fmt.Errorf("%w: matcher kind %q must not set format or interval", ErrInvalidPolicy, mm.Kind)
		}
		if err := validatePolicyField("matcher.value", mm.Value); err != nil {
			return err
		}
		if !isValidRuleDomain(mm.Value) {
			return fmt.Errorf("%w: %q is not a valid domain", ErrInvalidPolicy, mm.Value)
		}
	default: // KindDomainKeyword: a free-form substring, no dot/FQDN shape required.
		if mm.Format != "" || mm.Interval != 0 {
			return fmt.Errorf("%w: matcher kind %q must not set format or interval", ErrInvalidPolicy, mm.Kind)
		}
		if err := validatePolicyField("matcher.value", mm.Value); err != nil {
			return err
		}
	}
	return nil
}

// validateFallback checks Fallback's structural rules (just the policy enum
// now — a gateway fallback carries no selector/target to validate).
func validateFallback(f Fallback) error {
	if !validFallbackPolicies[f.Policy] {
		return fmt.Errorf("%w: fallback policy %q must be auto|direct|gateway", ErrInvalidPolicy, f.Policy)
	}
	return nil
}

// validatePolicyRule validates a PolicyRule's full structural + injection
// surface: intent enum and matcher shape (validateMatcher above). Binary
// policy carries no selector, so there is no existence check layered on top.
func validatePolicyRule(r PolicyRule) error {
	if !validIntents[r.Intent] {
		return fmt.Errorf("%w: intent %q must be block|direct|proxy", ErrInvalidPolicy, r.Intent)
	}
	return validateMatcher(r.Matcher)
}

// ruleIndex returns the index of the rule with the given ID in rules, or -1.
func ruleIndex(rules []PolicyRule, id string) int {
	for i, r := range rules {
		if r.ID == id {
			return i
		}
	}
	return -1
}

// Snapshot returns a defensive model copy and its in-memory revision for an
// optimistic apply transaction.
func (m *PolicyRuleManager) Snapshot() (PolicyModel, uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := m.model
	out.Rules = append([]PolicyRule(nil), m.model.Rules...)
	return out, m.revision
}

// CommitIfRevision holds the model lock while fn publishes a prepared
// generation, but only if no CRUD mutation occurred since Snapshot.
func (m *PolicyRuleManager) CommitIfRevision(revision uint64, fn func() error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.revision != revision {
		return fmt.Errorf("%w: prepared %d, current %d", ErrPolicyRevisionChanged, revision, m.revision)
	}
	return fn()
}

// Rules returns a defensive copy of the current rules, sorted by Order
// (ascending — evaluation order). The internal slice is already maintained
// in Order-matching position by every mutator below, so this sort is a
// belt-and-braces guarantee rather than load-bearing.
func (m *PolicyRuleManager) Rules() []PolicyRule {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := append([]PolicyRule(nil), m.model.Rules...)
	sort.SliceStable(out, func(i, j int) bool { return out[i].Order < out[j].Order })
	return out
}

// AddRule mints a fresh ID, appends r at the end of the evaluation order
// (Order = current rule count), validates, and persists. On a save failure
// the appended entry is rolled back and the model is left exactly as it was
// before the call.
func (m *PolicyRuleManager) AddRule(r PolicyRule) (PolicyRule, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r.ID = newPolicyID("prule")
	r.Order = len(m.model.Rules)
	if err := validatePolicyRule(r); err != nil {
		return PolicyRule{}, err
	}
	m.model.Rules = append(m.model.Rules, r)
	if err := m.saveLocked(); err != nil {
		m.model.Rules = m.model.Rules[:len(m.model.Rules)-1]
		return PolicyRule{}, err
	}
	m.revision++
	return r, nil
}

// UpdateRule replaces the rule with the given id: id is authoritative over
// r.ID, and the rule's existing Order is preserved regardless of what r.Order
// carries (a caller updates a rule's content, not its position — Reorder is
// the only way to change Order). On a save failure the model is rolled back.
func (m *PolicyRuleManager) UpdateRule(id string, r PolicyRule) (PolicyRule, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	idx := ruleIndex(m.model.Rules, id)
	if idx < 0 {
		return PolicyRule{}, fmt.Errorf("%w: policy rule %q", ErrPolicyNotFound, id)
	}
	r.ID = id
	r.Order = m.model.Rules[idx].Order
	if err := validatePolicyRule(r); err != nil {
		return PolicyRule{}, err
	}
	old := m.model.Rules[idx]
	m.model.Rules[idx] = r
	if err := m.saveLocked(); err != nil {
		m.model.Rules[idx] = old
		return PolicyRule{}, err
	}
	m.revision++
	return r, nil
}

// DeleteRule removes the rule with the given id and renumbers the remaining
// rules' Order to their new (post-removal) index — keeping the slice
// position / Order invariant every other mutator relies on, and avoiding an
// Order collision the next time AddRule computes Order = len(Rules). On a
// save failure the entire pre-delete model (original entries AND original
// Order values) is restored verbatim.
func (m *PolicyRuleManager) DeleteRule(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	idx := ruleIndex(m.model.Rules, id)
	if idx < 0 {
		return fmt.Errorf("%w: policy rule %q", ErrPolicyNotFound, id)
	}
	old := append([]PolicyRule(nil), m.model.Rules...)
	next := append(m.model.Rules[:idx:idx], m.model.Rules[idx+1:]...)
	for i := range next {
		next[i].Order = i
	}
	m.model.Rules = next
	if err := m.saveLocked(); err != nil {
		m.model.Rules = old
		return err
	}
	m.revision++
	return nil
}

// Reorder rewrites the evaluation order to match ids exactly: ids must be
// the full current set of rule IDs (no more, no fewer, no duplicates) in the
// desired new order, otherwise ErrInvalidPolicy is returned and the model is
// left untouched.
func (m *PolicyRuleManager) Reorder(ids []string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(ids) != len(m.model.Rules) {
		return fmt.Errorf("%w: reorder id set has %d ids, model has %d rules", ErrInvalidPolicy, len(ids), len(m.model.Rules))
	}
	byID := make(map[string]PolicyRule, len(m.model.Rules))
	for _, r := range m.model.Rules {
		byID[r.ID] = r
	}
	next := make([]PolicyRule, 0, len(ids))
	for order, id := range ids {
		r, ok := byID[id]
		if !ok {
			return fmt.Errorf("%w: reorder references unknown id %q", ErrInvalidPolicy, id)
		}
		delete(byID, id) // reject duplicates
		r.Order = order
		next = append(next, r)
	}
	old := m.model.Rules
	m.model.Rules = next
	if err := m.saveLocked(); err != nil {
		m.model.Rules = old
		return err
	}
	m.revision++
	return nil
}

// GetFallback returns the current fallback policy (a plain value type — no
// defensive copy needed).
func (m *PolicyRuleManager) GetFallback() Fallback {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.model.Fallback
}

// SetFallback validates and persists a new fallback policy. On a save
// failure the previous fallback is restored.
func (m *PolicyRuleManager) SetFallback(f Fallback) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := validateFallback(f); err != nil {
		return err
	}
	old := m.model.Fallback
	m.model.Fallback = f
	if err := m.saveLocked(); err != nil {
		m.model.Fallback = old
		return err
	}
	m.revision++
	return nil
}
