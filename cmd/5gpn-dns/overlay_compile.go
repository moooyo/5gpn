package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
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

// interceptEgressListenerName is the inbound the processor's upstream traffic
// arrives on. It is fixed by the mihomo boundary check, which validates that
// exactly one listener with this name exists and carries exactly one user.
const interceptEgressListenerName = "intercept-egress"

// interceptDirectEgressGroup is the built-in group an operator binds an
// extension to when they want its upstream traffic to leave unproxied. It is
// always offered in the binding list, so it is a choice they can actually make.
const interceptDirectEgressGroup = "DIRECT"

// overlayGenerationID derives a deterministic generation id for one whole
// transaction: the desired state AND the transition that reaches it.
//
// Deterministic rather than random so that re-preparing the same transaction
// after a crash produces the same id — which is what makes prepare idempotent
// and lets a lost response be recovered by readback instead of by guesswork.
//
// It hashes the complete document with the id field zeroed, rather than a
// hand-picked subset of it. The subset this used to hash — the sidecar document
// revision plus the routing projection — omitted ParentGenerationID,
// TransitionMode, and the two artifact digests, every one of which the store's
// record digest DOES cover. Two transactions that reach the same routing state
// from different parents therefore landed on one id carrying two different
// digests, and the store refused the second with "already exists with a
// different document".
//
// Turning the MITM master off and back on is exactly that shape, and it was a
// one-way door: the enable recomputed the id of the generation the disable had
// just revoked, and a revoked id can never be staged again. Hashing the whole
// document makes "same id" imply "same document" by construction, so the
// derivation cannot drift from the digest again as fields are added.
func overlayGenerationID(documentRevision string, doc overlayDocument) (string, error) {
	doc.GenerationID = ""
	body, err := json.Marshal(doc)
	if err != nil {
		return "", fmt.Errorf("overlay: derive generation id: %w", err)
	}
	sum := sha256.Sum256(append([]byte(documentRevision+"\x00"), body...))
	return "g-" + hex.EncodeToString(sum[:12]), nil
}

// overlayDesiredFingerprint identifies a desired state independently of which
// generation it supersedes.
//
// The generation id deliberately covers ParentGenerationID — two transactions
// that reach the same routing state from different parents must be distinct
// records, or the store refuses the second with "already exists with a different
// document". That is exactly what made the id useless for answering "is this
// already live": equality would have required a SHA-256 fixed point, so the
// check never fired once, and every daemon start and every unrelated document
// write committed a fresh generation with a revoke transition — hard-cutting
// in-flight capture for a change that altered no routing, and walking the core's
// generation quota.
//
// So zero the parent too and compare content. It hashes the whole document
// rather than reusing overlayProjection, which is deliberately lossy: that
// summary omits Destinations, AllowDirect and Unbounded, so a publication
// removing egress authority would compare equal to one granting it, and
// "missing and removed required bindings fail closed without fallback" would
// stop being true. The domain separator keeps this out of the generation id
// space so the two can never be confused for one another.
func overlayDesiredFingerprint(documentRevision string, doc overlayDocument) (string, error) {
	doc.GenerationID = ""
	doc.ParentGenerationID = ""
	body, err := json.Marshal(doc)
	if err != nil {
		return "", fmt.Errorf("overlay: derive desired fingerprint: %w", err)
	}
	sum := sha256.Sum256(append([]byte("overlay-desired\x00"+documentRevision+"\x00"), body...))
	return hex.EncodeToString(sum[:]), nil
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
		id, err := overlayGenerationID(in.DocumentRevision, doc)
		if err != nil {
			return doc, err
		}
		doc.GenerationID = id
		return doc, nil
	}

	if in.MatchTarget == "" {
		return doc, fmt.Errorf("overlay: no terminal MATCH target to resolve unbound extensions against")
	}

	ordered := orderedEnabledInterceptModules(in.Document)

	// --- egress capabilities -------------------------------------------------
	// Every capability carries the credential the processor actually presents.
	// The egress listener is validated to carry exactly one user, so there is
	// exactly one credential — but the credential is not what selects the group.
	// The destination does.
	//
	// This used to refuse any document whose enabled extensions resolved to more
	// than one group, on the reasoning that one credential can present one
	// capability. That reasoning conflated the two: it made the ordinary
	// arrangement of one bound extension alongside one unbound one — two groups,
	// the second being the operator's terminal MATCH target — impossible to
	// enable at all.
	credential := in.Document.UpstreamProxy.Username
	if credential == "" {
		return doc, fmt.Errorf("overlay: the interception document carries no upstream credential to mint a capability from")
	}
	doc.Egress.Capabilities = overlayEgressCapabilities(ordered, credential, in.MatchTarget)

	// --- client stage --------------------------------------------------------
	// Order is the contract: the extensions' own reject/direct rules first,
	// then capture. Reversing it would let a capture rule shadow a deny the
	// operator explicitly reviewed.
	rules := make([]overlayClientRule, 0, 64)

	// A rule this compiler cannot represent must block the commit, not be skipped.
	//
	// Skipping is the failure the header above records: a reviewed deny or direct
	// simply stops being enforced, with nothing anywhere reporting it. The
	// operator confirmed it, the console and the Telegram review render it, and
	// interceptModuleView still lists it -- while doc.Client.Rules contains no
	// corresponding entry. Refusing turns that class of drift into a failed apply
	// with a name attached, which is the only outcome that cannot enforce
	// something other than what was approved. overlayProjectModule, the digest
	// path, has always refused; this is the path that decides what runs.
	seenPolicy := make(map[string]struct{})
	for _, module := range ordered {
		for index, route := range module.RoutingRules {
			compiled, ok := overlayPolicyRule(route, module.ID)
			if !ok {
				return doc, fmt.Errorf("overlay: extension %s routing rule %d cannot be represented in a generation", module.ID, index)
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
				// Same reasoning, and worse consequences: a dropped capture rule
				// leaves a declared host running unintercepted through the
				// operator's own rules while every surface says it is captured.
				return doc, fmt.Errorf("overlay: extension %s capture selector %q cannot be represented in a generation", module.ID, selector.Value)
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

	id, err := overlayGenerationID(in.DocumentRevision, doc)
	if err != nil {
		return doc, err
	}
	doc.GenerationID = id
	return doc, nil
}

// overlayEgressCapabilities partitions the processor's endpoint allowlist
// across the egress groups the enabled extensions resolve to, and mints one
// capability whose policy is that partition.
//
// There is exactly one capability because there is exactly one credential: the
// processor authenticates with a single username on the egress listener, and a
// capability it cannot present authorizes nothing. What decides which group a
// connection leaves through is the destination.
//
// Minting a credential per group was the obvious alternative and is wrong twice
// over. It would let the processor choose its own egress by choosing which
// credential to present, when the whole point of the capability model is that
// the processor never names a group. And it would tie the credential set to the
// operator's group list, so adding a proxy group would require rewriting the
// listener's users — the configuration rewrite the overlay exists to avoid.
//
// The partition rule: an explicitly bound extension claims a selector before an
// unbound one, execution order breaks ties within each pass, and a selector is
// claimed only once. That last property is what makes the destination sets
// disjoint, so which group a connection leaves through does not depend on the
// order bindings are evaluated in.
//
// A group whose extensions had every selector claimed by an earlier one gets no
// binding rather than an empty one — such a module confers no authority, and
// this keeps an allowlist that is empty from ever being handed to the core in
// place of one that is absent. A processor with no bindings at all gets no
// capability, for the same reason.
func overlayEgressCapabilities(ordered []interceptModuleSnapshot, credential, matchTarget string) []overlayEgressCapability {
	groups := make([]string, 0, 4)
	destinations := make(map[string][]overlayDestinationRule, 4)
	claimed := make(map[string]struct{})
	// The first grant-holding module in execution order owns unmatched egress.
	// The permission names no host, so its binding cannot either, and two of
	// them would leave which group unmatched traffic leaves through undecided --
	// the same first-match ownership every other selector here already has.
	unboundedGroup := ""

	claim := func(bound bool) {
		for _, module := range ordered {
			if (module.EgressGroup != "") != bound {
				continue
			}
			group := module.EgressGroup
			if group == "" {
				group = matchTarget
			}
			if module.Network && unboundedGroup == "" {
				unboundedGroup = group
			}
			for _, selector := range interceptModuleEgressSelectors(module) {
				kind, ok := overlayKindFor(selector.Kind)
				if !ok {
					continue
				}
				identity := string(kind) + "\x00" + selector.Value + "\x00" + strconv.Itoa(selector.Port)
				if _, dup := claimed[identity]; dup {
					continue
				}
				claimed[identity] = struct{}{}
				if _, seen := destinations[group]; !seen {
					groups = append(groups, group)
				}
				destinations[group] = append(destinations[group], overlayDestinationRule{
					Kind:  kind,
					Value: selector.Value,
					Ports: []overlayPortRange{{From: uint16(selector.Port), To: uint16(selector.Port)}},
				})
			}
		}
	}
	claim(true)
	claim(false)

	capabilities := make([]overlayEgressCapability, 0, 1)
	bindings := make([]overlayEgressBinding, 0, len(groups))
	for _, group := range groups {
		rules := destinations[group]
		sort.SliceStable(rules, func(i, j int) bool {
			a, b := rules[i], rules[j]
			if a.Kind != b.Kind {
				return a.Kind < b.Kind
			}
			if a.Value != b.Value {
				return a.Value < b.Value
			}
			return a.Ports[0].From < b.Ports[0].From
		})
		bindings = append(bindings, overlayEgressBinding{
			Group:        group,
			Destinations: rules,
			AllowDirect:  overlayCapabilityAllowsDirect(group, matchTarget),
		})
	}
	// Appended last, which the overlay requires: it matches everything, so any
	// earlier position would shadow the destination-scoped bindings above it.
	if unboundedGroup != "" {
		bindings = append(bindings, overlayEgressBinding{
			Group:       unboundedGroup,
			Unbounded:   true,
			AllowDirect: overlayCapabilityAllowsDirect(unboundedGroup, matchTarget),
		})
	}
	if len(bindings) == 0 {
		// No enabled extension conferred any egress authority. An empty
		// capability would authorize nothing while looking like it authorizes
		// something; the core refuses one, and rightly.
		return capabilities
	}
	return append(capabilities, overlayEgressCapability{
		ID:       credential,
		Listener: interceptEgressListenerName,
		Bindings: bindings,
	})
}

// overlayCapabilityAllowsDirect reports whether a capability for this group may
// resolve to the DIRECT outbound.
//
// A named selector group can be pointing anywhere at any moment, so an operator
// who bound an extension to one has not thereby consented to unproxied egress;
// that capability fails closed instead. Two groups are consent. The operator's
// terminal MATCH target is the global default they already chose for everything
// else. The built-in DIRECT group cannot resolve to anything but DIRECT and is
// offered in the binding list precisely so an extension can be sent out
// unproxied on purpose — refusing it there would make the one binding whose
// meaning is unambiguous the one binding that never works.
func overlayCapabilityAllowsDirect(group, matchTarget string) bool {
	return group == matchTarget || group == interceptDirectEgressGroup
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

// overlayProjection is a stable fingerprint of the compiled policy, recorded in
// the journal as the target document digest so an interrupted operation can be
// recognised by what it was publishing rather than only by its id. The core
// computes its own authoritative digests; the generation id covers the whole
// document, including the destination allowlists this summary leaves out.
func overlayProjection(doc overlayDocument) string {
	var b strings.Builder
	for _, r := range doc.Client.Rules {
		b.WriteString(overlayRuleIdentity(r))
		b.WriteByte('\n')
	}
	b.WriteByte('|')
	for _, c := range doc.Egress.Capabilities {
		b.WriteString(c.ID)
		for _, bind := range c.Bindings {
			b.WriteByte(0)
			b.WriteString(bind.Group)
		}
		b.WriteByte('\n')
	}
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}
