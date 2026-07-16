// Package main (this file): the DNS-side policy compiler. CompilePolicy
// turns a PolicyModel (policy_rules.go) into the concrete DNS-side rule-file
// assignment (CompiledDNS): which category (block/direct/blacklist — the
// existing DomainSet categories rules.go/main.go already load) each enabled
// rule's matcher contributes to, split into inline manual-file entries
// (grouped by MatchType, so the caller can write them straight to the
// existing "<category>[.<matchtype>].txt" convention — see main.go's
// globPattern) versus subscription fetch specs (a category cache directory,
// "<category>/<name>.txt", always MatchSuffix).
//
// Binary policy / DNS-only compile (2026-07-15 policy/mihomo decoupling
// design, §2.4): this is the compiler's ONLY output now. There used to be a
// second, mihomo-side projection (CompiledMihomo: split-rules/rule-providers/
// a local file rule-provider per subscription) rendered by the same walk —
// that whole projection is REMOVED. A proxy-intent rule means only "steer to
// the gateway" (DNS category "blacklist"); what mihomo does with gateway-
// bound traffic afterwards is the operator's own mihomo config, never
// something this compiler renders. Do not reintroduce a mihomo-side return
// value here — see the design doc's §3 removals list.
//
// This is pure/deterministic: no file I/O happens here (that is a later
// engine's job — policy_engine.go writes rulesDir and fetches
// subscriptions).
package main

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// CompiledDNS is the output of CompilePolicy: Manual[category][matchType]
// holds the inline (non-subscription) entries destined for the manual
// "<category>[.<matchtype>].txt" files; Subs holds one Subscription fetch
// descriptor per subscription-kind rule, Category set from the rule's
// Intent. Both are computed fresh on every compile — the caller (the policy
// engine) diffs/writes them, this type carries no I/O state of its own.
type CompiledDNS struct {
	Manual map[string]map[MatchType][]string
	Subs   []Subscription
}

// intentCategory maps a PolicyRule's Intent to the DNS-side DomainSet
// category it compiles into: block→block, direct→direct, proxy→blacklist.
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
		return "blacklist", true
	}
	return "", false
}

// kindMatchType maps a matcher kind to the DNS DomainSet MatchType (rules.go)
// its inline entries are written as: domain→exact (whole-name), domain-suffix
// →suffix (parent-domain/self), domain-keyword→keyword (substring). The MVP
// matcher surface is exactly these plus subscription (policy_rules.go);
// subscription never reaches this function directly (CompilePolicy branches
// on KindSubscription before calling it) — its cache file is always suffix
// per main.go's globPattern, which is why the default case documents that
// rather than requiring a KindSubscription arm.
func kindMatchType(k MatcherKind) MatchType {
	switch k {
	case KindDomain:
		return MatchExact
	case KindDomainKeyword:
		return MatchKeyword
	default: // KindDomainSuffix (and KindSubscription's cache file: always suffix)
		return MatchSuffix
	}
}

// dnsValue returns the string an inline matcher contributes to a DNS
// DomainSet file for its kind: domain/domain-suffix are normalized FQDNs
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
func CompilePolicy(model PolicyModel, rulesDir string) (CompiledDNS, error) {
	if model.Fallback.Policy == "" {
		model.Fallback.Policy = FallbackAuto
	}
	if err := validateFallback(model.Fallback); err != nil {
		return CompiledDNS{}, fmt.Errorf("policy compile: %w", err)
	}
	cdns := CompiledDNS{Manual: map[string]map[MatchType][]string{}}

	rules := append([]PolicyRule(nil), model.Rules...)
	sort.SliceStable(rules, func(i, j int) bool { return rules[i].Order < rules[j].Order })

	// seen dedupes (category, matchType, value) so a manual file never gets a
	// visible duplicate line, even if two enabled rules normalize to the same
	// entry.
	seen := map[string]map[MatchType]map[string]bool{}
	addManual := func(cat string, mt MatchType, val string) {
		if val == "" {
			return
		}
		if cdns.Manual[cat] == nil {
			cdns.Manual[cat] = map[MatchType][]string{}
			seen[cat] = map[MatchType]map[string]bool{}
		}
		if seen[cat][mt] == nil {
			seen[cat][mt] = map[string]bool{}
		}
		if seen[cat][mt][val] {
			return
		}
		seen[cat][mt][val] = true
		cdns.Manual[cat][mt] = append(cdns.Manual[cat][mt], val)
	}

	for _, r := range rules {
		if err := validatePolicyRule(r); err != nil {
			return CompiledDNS{}, fmt.Errorf("policy compile: rule %s: %w", r.ID, err)
		}
		if !r.Enabled {
			continue
		}
		cat, ok := intentCategory(r.Intent)
		if !ok {
			return CompiledDNS{}, fmt.Errorf("policy compile: rule %s has unknown intent %q", r.ID, r.Intent)
		}

		if r.Matcher.Kind == KindSubscription {
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
			continue
		}

		// Inline (literal) matcher: domain / domain-suffix / domain-keyword
		// (the only remaining valid kinds) all contribute to a DomainSet.
		val := dnsValue(r.Matcher.Kind, r.Matcher.Value)
		addManual(cat, kindMatchType(r.Matcher.Kind), val)
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
	if model.Fallback.Policy == "" {
		model.Fallback.Policy = FallbackAuto
	}
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
