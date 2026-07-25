package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

// The per-extension typed projection, and a digest of it that the publisher
// also computes.
//
// The marketplace publishes a policy digest for every extension, produced by a
// second implementation of this mapping in JavaScript. That second
// implementation exists because the publisher has to know, at review time,
// that a reviewed rule can actually be carried by the typed overlay — a rule
// that could not be was previously discovered only when a generation was
// compiled on a live gateway, and then by being silently dropped.
//
// Two implementations of one mapping is a real hazard, so rather than trust
// them to stay in step, the gateway reproduces the digest from its own parse
// and compares. Agreement means both compilers turned the same manifest into
// the same enforcement; disagreement is caught here, before a generation is
// committed, instead of surfacing as traffic behaving differently from the
// policy that was approved.

// overlayPolicyDigestDomain separates this digest's preimage from every other
// digest in the system, so a value that happens to collide in one cannot be
// replayed into another.
const overlayPolicyDigestDomain = "5gpn.policy/v1"

// overlayPolicyProjection is one extension's contribution to the client stage,
// before it is merged and de-duplicated with the other enabled extensions.
type overlayPolicyProjection struct {
	Owner        string
	Rules        []overlayClientRule
	PolicyRules  int
	CaptureRules int
}

// overlayProjectModule compiles one extension in isolation.
//
// Isolation is the point: the published digest describes what this extension
// declares, independent of which others happen to be installed alongside it.
// The merged generation de-duplicates across extensions, which would otherwise
// make an extension's digest depend on its neighbours.
//
// Rule order is the contract — the extension's own reject/direct rules first,
// then its capture rules — because reversing it would let a capture rule
// shadow a deny the operator reviewed.
func overlayProjectModule(module interceptModuleSnapshot) (overlayPolicyProjection, error) {
	out := overlayPolicyProjection{Owner: module.ID}

	for index, route := range module.RoutingRules {
		compiled, ok := overlayPolicyRule(route, module.ID)
		if !ok {
			// Refused rather than skipped. Skipping is exactly the failure this
			// whole mechanism exists to prevent: a reviewed decision quietly
			// ceasing to be enforced.
			return overlayPolicyProjection{}, fmt.Errorf(
				"%s: routingRules[%d] cannot be represented in the typed overlay", module.ID, index)
		}
		out.Rules = append(out.Rules, compiled)
		out.PolicyRules++
	}

	for _, selector := range interceptModuleCaptureSelectors(module) {
		compiled, ok := overlayCaptureRule(selector, module.ID)
		if !ok {
			return overlayPolicyProjection{}, fmt.Errorf(
				"%s: capture selector %s,%s cannot be represented in the typed overlay",
				module.ID, selector.Kind, selector.Value)
		}
		out.Rules = append(out.Rules, compiled)
		out.CaptureRules++
	}
	return out, nil
}

// overlayPolicyDigest fingerprints a projection.
//
// Every field is length-prefixed rather than joined by a separator: a joined
// encoding lets two different rule sets share a preimage whenever a value can
// contain the separator, and "a keyword never contains a space" is a property
// of today's validator rather than of the format. Length prefixes make the
// field boundaries unambiguous by construction, which is also what makes the
// encoding reproducible by an independent implementation.
func overlayPolicyDigest(projection overlayPolicyProjection) string {
	var b strings.Builder
	lp := func(value string) {
		b.WriteString(strconv.Itoa(len(value)))
		b.WriteByte(':')
		b.WriteString(value)
	}
	lpn := func(value int) { lp(strconv.Itoa(value)) }

	lp(overlayPolicyDigestDomain)
	lp(projection.Owner)
	lpn(len(projection.Rules))
	for _, rule := range projection.Rules {
		lp(string(rule.Kind))
		lp(rule.Value)
		lp(rule.Network)
		lp(string(rule.Action))
		lp(rule.Processor)
		lp(rule.Owner)
		lpn(len(rule.Ports))
		for _, port := range rule.Ports {
			lpn(int(port.From))
			lpn(int(port.To))
		}
		for _, group := range [][]string{rule.KeywordsAny, rule.KeywordsAll} {
			lpn(len(group))
			for _, keyword := range group {
				lp(keyword)
			}
		}
	}
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

// verifyOverlayPublishedPolicy checks an extension's compiled policy against
// the digest its publisher recorded.
//
// An empty published digest means the extension predates the marketplace
// carrying one; that is reported as unverified rather than treated as a
// mismatch, because refusing to install every previously-published extension
// is not a safety property, it is an outage.
func verifyOverlayPublishedPolicy(module interceptModuleSnapshot, published string) error {
	if strings.TrimSpace(published) == "" {
		return nil
	}
	projection, err := overlayProjectModule(module)
	if err != nil {
		return err
	}
	actual := overlayPolicyDigest(projection)
	if actual != published {
		return fmt.Errorf(
			"%s: compiled policy digest %s does not match the published %s; "+
				"the gateway would enforce something other than what was reviewed",
			module.ID, actual, published)
	}
	return nil
}
