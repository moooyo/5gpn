// CompilePolicy validates an ordered policy and derives its subscription
// fetch set. Inline matchers are materialized directly by CompileRuntimePolicy
// and do not need an intermediate category file.
package main

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// CompiledDNS is the set of policy-owned subscription caches to reconcile.
type CompiledDNS struct {
	Subs []Subscription
}

// intentCategory maps a PolicyRule's Intent to its subscription-cache
// directory: block→block, direct→direct, proxy→proxy.
// ok is false for any value outside the validated Intent enum (validIntents,
// policy_rules.go) — the compiler treats that as an error rather than
// silently dropping or miscategorizing the rule, since a model normally
// reaches CompilePolicy only after validation.
func intentCategory(i Intent) (string, bool) {
	switch i {
	case IntentBlock:
		return "block", true
	case IntentDirect:
		return "direct", true
	case IntentProxy:
		return "proxy", true
	}
	return "", false
}

// dnsValue returns the normalized value of an inline matcher. Domain and
// domain-suffix values are normalized FQDNs
// (normalizeDomain, parsers.go — lowercase, no trailing dot); domain-keyword
// is a lowercased, trimmed substring token (no FQDN shape required — mirrors
// validateMatcher's free-form keyword handling in policy_rules.go).
func dnsValue(k MatcherKind, raw string) string {
	if k == KindDomainKeyword {
		return strings.ToLower(strings.TrimSpace(raw))
	}
	return normalizeDomain(raw)
}

// providerName derives a stable, path-safe DNS subscription-cache basename
// from a rule ID: "pol_<id>". Rule IDs are minted by newPolicyID
// (policy_rules.go's AddRule) and are already path-safe.
func providerName(ruleID string) string { return "pol_" + ruleID }

// CompilePolicy is the policy compiler's single entry point: it turns an
// operator-authored PolicyModel into the DNS-side assignment (CompiledDNS).
// Pure and deterministic: given the same model and rulesDir it always
// returns the same result, with no file I/O — writing rulesDir and fetching
// subscriptions is the policy engine's job. Only Enabled rules compile, in
// Order (operator precedence).
func CompilePolicy(model PolicyModel) (CompiledDNS, error) {
	if err := validateFallback(model.Fallback); err != nil {
		return CompiledDNS{}, fmt.Errorf("policy compile: %w", err)
	}
	cdns := CompiledDNS{}

	rules := append([]PolicyRule(nil), model.Rules...)
	sort.SliceStable(rules, func(i, j int) bool { return rules[i].Order < rules[j].Order })

	for _, r := range rules {
		if err := validatePolicyRule(r); err != nil {
			return CompiledDNS{}, fmt.Errorf("policy compile: rule %s: %w", r.ID, err)
		}
		if !r.Enabled {
			continue
		}
		if r.Matcher.Kind == KindSubscription {
			cat, ok := intentCategory(r.Intent)
			if !ok {
				return CompiledDNS{}, fmt.Errorf("policy compile: rule %s has unknown intent %q", r.ID, r.Intent)
			}
			// A fetch descriptor assigned to this intent's category. Name =
			// providerName purely for a stable, path-safe cache basename.
			cdns.Subs = append(cdns.Subs, Subscription{
				ID:       r.ID,
				Category: cat,
				Name:     providerName(r.ID),
				URL:      r.Matcher.Value,
				Format:   r.Matcher.Format,
				Enabled:  true,
				Interval: r.Matcher.Interval,
			})
		}
	}

	return cdns, nil
}

// runtimePolicyRule is one fully materialized matcher in global evaluation
// order. Keeping one DomainSet per rule (rather than merging intents into
// category sets) is what makes cross-intent first-match semantics real.
type runtimePolicyRule struct {
	ID      string
	Intent  Intent
	Matcher *DomainSet
}

type runtimePolicySnapshot struct {
	Rules    []runtimePolicyRule
	Fallback FallbackPolicy
}

// CompileRuntimePolicy materializes the ordered runtime matcher snapshot.
// Inline rules are built directly; subscription rules load their own stable
// cache file, so overlapping subscriptions of different intents still obey
// the operator's global order. A missing cache is an empty matcher (offline-
// safe first fetch); a present but unreadable cache is a hard apply error.
func CompileRuntimePolicy(model PolicyModel, rulesDir string) (*runtimePolicySnapshot, error) {
	if err := validateFallback(model.Fallback); err != nil {
		return nil, fmt.Errorf("policy runtime: %w", err)
	}
	rules := append([]PolicyRule(nil), model.Rules...)
	sort.SliceStable(rules, func(i, j int) bool { return rules[i].Order < rules[j].Order })

	snap := &runtimePolicySnapshot{
		Rules:    make([]runtimePolicyRule, 0, len(rules)),
		Fallback: model.Fallback.Policy,
	}
	for _, r := range rules {
		if err := validatePolicyRule(r); err != nil {
			return nil, fmt.Errorf("policy runtime: rule %s: %w", r.ID, err)
		}
		if !r.Enabled {
			continue
		}

		var ds *DomainSet
		if r.Matcher.Kind == KindSubscription {
			cat, ok := intentCategory(r.Intent)
			if !ok {
				return nil, fmt.Errorf("policy runtime: rule %s has unknown intent %q", r.ID, r.Intent)
			}
			path := filepath.Join(rulesDir, cat, providerName(r.ID)+".txt")
			var err error
			ds, err = LoadDomainSet(path)
			if err != nil {
				return nil, fmt.Errorf("policy runtime: rule %s subscription cache: %w", r.ID, err)
			}
		} else {
			ds = &DomainSet{exact: map[string]struct{}{}, suffix: map[string]struct{}{}}
			value := dnsValue(r.Matcher.Kind, r.Matcher.Value)
			switch r.Matcher.Kind {
			case KindDomain:
				ds.exact[value] = struct{}{}
			case KindDomainSuffix:
				ds.suffix[value] = struct{}{}
			case KindDomainKeyword:
				ds.keyword = []string{value}
			}
		}
		snap.Rules = append(snap.Rules, runtimePolicyRule{ID: r.ID, Intent: r.Intent, Matcher: ds})
	}
	return snap, nil
}
