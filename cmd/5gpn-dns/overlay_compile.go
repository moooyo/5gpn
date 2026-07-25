package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
)

// Compiles the interception document into a typed overlay generation.
//
// It reuses interceptModuleCaptureSelectors / interceptModuleEgressSelectors —
// the same functions the legacy YAML renderer uses — on purpose. Those encode
// the product's actual policy: wildcard-plus-apex collapses to a suffix,
// bound-egress modules win over unbound ones, execution order breaks ties,
// first selector wins. A second implementation of that would be a second source
// of truth, and the two would drift exactly where it matters least visibly.
//
// What changes is only the output form: typed entries instead of
// `AND,((DOMAIN,x),(DST-PORT,443)),MODULE-INTERCEPT` strings.

// overlayCapabilityFor derives a stable capability id for one egress target.
//
// One capability per distinct egress group, not one per module: the capability
// is the authority to leave through a particular group, and two modules bound
// to the same group are asking for the same authority. The id is derived from
// the base credential so it is stable across generations that do not change the
// binding, and opaque so it carries no group name to the processor.
func overlayCapabilityFor(baseUser, group string) string {
	sum := sha256.Sum256([]byte(baseUser + "\x00" + group))
	return "cap-" + hex.EncodeToString(sum[:8])
}

// overlayGenerationID derives a deterministic generation id from the desired
// state's own digest.
//
// Deterministic rather than random so that re-preparing the same desired state
// after a crash produces the same id — which is what makes prepare idempotent
// and lets a lost response be recovered by readback instead of by guesswork.
func overlayGenerationID(documentRevision string, projection string) string {
	sum := sha256.Sum256([]byte(documentRevision + "\x00" + projection))
	return "g-" + hex.EncodeToString(sum[:12])
}

// overlayCompileInput is everything the compiler needs that is not in the
// interception document itself.
type overlayCompileInput struct {
	Document interceptConfigDocument
	// MatchTarget is the operator's terminal MATCH target, which is what an
	// unbound extension's egress resolves to. The overlay cannot use the
	// sentinel: a capability must name a real group.
	MatchTarget string
	// DocumentRevision is the sha256 of the sidecar document, used to make the
	// generation id deterministic.
	DocumentRevision string
	// ParentGeneration is the generation this one supersedes, if any.
	ParentGeneration string
	// Transition selects graceful drain or hard revoke.
	Transition overlayTransitionMode
	// CertificateHostSetDigest and SidecarBundleDigest are carried opaquely so
	// readback, the processor and the coordinator agree on which artifacts
	// belong to this generation.
	CertificateHostSetDigest string
	SidecarBundleDigest      string
}

// compileOverlayGeneration builds the typed generation.
func compileOverlayGeneration(in overlayCompileInput) (overlayDocument, error) {
	doc := overlayDocument{
		SchemaVersion:            overlaySchemaVersion,
		Owner:                    overlayOwner,
		ParentGenerationID:       in.ParentGeneration,
		TransitionMode:           in.Transition,
		CertificateHostSetDigest: in.CertificateHostSetDigest,
		SidecarBundleDigest:      in.SidecarBundleDigest,
		ProcessorTargets: []overlayProcessorTarget{
			{ID: overlayProcessorID, Name: interceptMihomoProxyName},
		},
	}
	if doc.TransitionMode == "" {
		doc.TransitionMode = overlayTransitionRevoke
	}

	// A disabled master is a real, committable generation: an empty client
	// stage with no capabilities. Publishing that is how the master switch
	// takes effect atomically, instead of being inferred from an absent
	// overlay.
	if !in.Document.MITM.Enabled {
		doc.GenerationID = overlayGenerationID(in.DocumentRevision, "disabled")
		return doc, nil
	}

	if in.MatchTarget == "" {
		return doc, fmt.Errorf("overlay: no terminal MATCH target to resolve unbound extensions against")
	}

	ordered := orderedEnabledInterceptModules(in.Document)
	baseUser := in.Document.UpstreamProxy.Username

	// --- egress capabilities -------------------------------------------------
	// Collect the distinct groups the enabled extensions bind to. An unbound
	// extension resolves to the operator's terminal target.
	groups := make(map[string]struct{}, len(ordered)+1)
	for _, module := range ordered {
		target := module.EgressGroup
		if target == "" {
			target = in.MatchTarget
		}
		groups[target] = struct{}{}
	}
	groupNames := make([]string, 0, len(groups))
	for g := range groups {
		groupNames = append(groupNames, g)
	}
	sort.Strings(groupNames)

	capabilities := make([]overlayEgressCapability, 0, len(groupNames))
	for _, group := range groupNames {
		capabilities = append(capabilities, overlayEgressCapability{
			ID:    overlayCapabilityFor(baseUser, group),
			Group: group,
			// The operator's terminal target may legitimately resolve to
			// DIRECT; a group the operator explicitly bound may not silently
			// become one.
			AllowDirect: group == in.MatchTarget,
		})
	}
	doc.Egress.Capabilities = capabilities

	// --- client stage --------------------------------------------------------
	// Order is the contract: the extensions' own reject/direct rules first,
	// then capture. Reversing it would let a capture rule shadow a deny the
	// operator explicitly reviewed.
	rules := make([]overlayClientRule, 0, 64)

	seenPolicy := make(map[string]struct{})
	for _, module := range ordered {
		for _, route := range module.RoutingRules {
			compiled, ok := overlayPolicyRule(route, module.ID)
			if !ok {
				continue
			}
			identity := overlayRuleIdentity(compiled)
			if _, dup := seenPolicy[identity]; dup {
				continue
			}
			seenPolicy[identity] = struct{}{}
			rules = append(rules, compiled)
		}
	}

	seenCapture := make(map[string]struct{})
	captureRules := make([]overlayClientRule, 0, 64)
	for _, module := range ordered {
		for _, selector := range interceptModuleCaptureSelectors(module) {
			compiled, ok := overlayCaptureRule(selector, module.ID)
			if !ok {
				continue
			}
			identity := overlayRuleIdentity(compiled)
			if _, dup := seenCapture[identity]; dup {
				continue
			}
			seenCapture[identity] = struct{}{}
			captureRules = append(captureRules, compiled)
		}
	}
	// Capture rules are order-insensitive among themselves — they all steer at
	// the same processor — so sort them for a stable digest.
	sort.SliceStable(captureRules, func(i, j int) bool {
		return overlayRuleIdentity(captureRules[i]) < overlayRuleIdentity(captureRules[j])
	})
	rules = append(rules, captureRules...)
	doc.Client.Rules = rules

	doc.GenerationID = overlayGenerationID(in.DocumentRevision, overlayProjection(doc))
	return doc, nil
}

// overlayCaptureRule converts one capture selector.
func overlayCaptureRule(selector interceptEgressSelector, owner string) (overlayClientRule, bool) {
	kind, ok := overlayKindFor(selector.Kind)
	if !ok {
		return overlayClientRule{}, false
	}
	return overlayClientRule{
		Kind:      kind,
		Value:     selector.Value,
		Ports:     []overlayPortRange{{From: uint16(selector.Port), To: uint16(selector.Port)}},
		Action:    overlayActionCapture,
		Processor: overlayProcessorID,
		Owner:     owner,
	}, true
}

// overlayPolicyRule converts one reviewed extension routing rule.
//
// A reviewed rule is a conjunction: at most one primary selector (domain,
// suffix or CIDR) narrowed by optional keyword, network and port constraints.
// The typed overlay mirrors that shape exactly, so every rule the operator
// approved survives the translation.
//
// This used to accept only a single selector and silently refuse anything
// combining one with keywords. Shadow comparison against real operator state
// found 21 of 323 reviewed rules being dropped that way — each one a deny or
// direct decision that would simply have stopped being enforced.
func overlayPolicyRule(rule interceptRoutingRule, owner string) (overlayClientRule, bool) {
	out := overlayClientRule{Action: overlayActionReject, Owner: owner}
	if strings.EqualFold(rule.Action, "direct") {
		out.Action = overlayActionDirect
	}

	primaries := 0
	if rule.Domain != "" {
		out.Kind, out.Value = overlaySelectorDomain, rule.Domain
		primaries++
	}
	if rule.DomainSuffix != "" {
		out.Kind, out.Value = overlaySelectorDomainSuffix, rule.DomainSuffix
		primaries++
	}
	if rule.IPCIDR != "" {
		out.Kind, out.Value = overlaySelectorIPCIDR, rule.IPCIDR
		primaries++
	}
	if primaries > 1 {
		// The source model permits exactly one primary selector; more than one
		// means the rule was built by something this compiler does not model,
		// and narrowing it would change what was approved.
		return overlayClientRule{}, false
	}

	// DomainKeywords is an any-of set; AllDomainKeywords is an all-of set.
	out.KeywordsAny = append([]string(nil), rule.DomainKeywords...)
	out.KeywordsAll = append([]string(nil), rule.AllDomainKeywords...)

	if primaries == 0 {
		if len(out.KeywordsAny) == 0 && len(out.KeywordsAll) == 0 {
			return overlayClientRule{}, false
		}
		// A lone any-of keyword is more precisely a keyword selector than an
		// unconstrained rule with one constraint; both match identically, but
		// the former reads correctly in readback and diagnostics.
		if len(out.KeywordsAny) == 1 && len(out.KeywordsAll) == 0 {
			out.Kind, out.Value = overlaySelectorDomainKeyword, out.KeywordsAny[0]
			out.KeywordsAny = nil
		} else {
			out.Kind, out.Value = overlaySelectorAny, ""
		}
	}

	if rule.Network != "" {
		out.Network = strings.ToLower(rule.Network)
	}
	if rule.DestinationPort != 0 {
		p := uint16(rule.DestinationPort)
		out.Ports = []overlayPortRange{{From: p, To: p}}
	}
	return out, true
}

func overlayKindFor(kind string) (overlaySelectorKind, bool) {
	switch kind {
	case "DOMAIN":
		return overlaySelectorDomain, true
	case "DOMAIN-SUFFIX":
		return overlaySelectorDomainSuffix, true
	case "DOMAIN-WILDCARD":
		return overlaySelectorDomainWildcard, true
	case "DOMAIN-KEYWORD":
		return overlaySelectorDomainKeyword, true
	case "IP-CIDR", "IP-CIDR6":
		return overlaySelectorIPCIDR, true
	}
	return "", false
}

func overlayRuleIdentity(rule overlayClientRule) string {
	var b strings.Builder
	b.WriteString(string(rule.Kind))
	b.WriteByte(0)
	b.WriteString(rule.Value)
	b.WriteByte(0)
	b.WriteString(rule.Network)
	b.WriteByte(0)
	for _, p := range rule.Ports {
		fmt.Fprintf(&b, "%05d-%05d,", p.From, p.To)
	}
	b.WriteByte(0)
	for _, kw := range rule.KeywordsAny {
		b.WriteString(kw)
		b.WriteByte(1)
	}
	b.WriteByte(0)
	for _, kw := range rule.KeywordsAll {
		b.WriteString(kw)
		b.WriteByte(1)
	}
	b.WriteByte(0)
	b.WriteString(string(rule.Action))
	b.WriteByte(0)
	b.WriteString(rule.Processor)
	return b.String()
}

// overlayProjection is a stable fingerprint of the compiled policy, used only to
// derive the generation id. The core computes its own authoritative digests; this
// one exists so the same desired state always yields the same generation id.
func overlayProjection(doc overlayDocument) string {
	var b strings.Builder
	for _, r := range doc.Client.Rules {
		b.WriteString(overlayRuleIdentity(r))
		b.WriteByte('\n')
	}
	b.WriteByte('|')
	for _, c := range doc.Egress.Capabilities {
		b.WriteString(c.ID)
		b.WriteByte(0)
		b.WriteString(c.Group)
		b.WriteByte('\n')
	}
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}
