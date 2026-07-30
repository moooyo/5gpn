package main

import (
	"strings"

	"gopkg.in/yaml.v3"
)

// Structural analysis of a mihomo config that delegates interception routing to
// the runtime overlay.
//
// There are no interception rules in the file to reconcile: it carries two
// anchors, and the rules themselves live in a typed, generation-versioned
// document committed over a machine-only socket. An empty file alongside a
// populated overlay is the correct steady state, not a fault.
//
// What still has to be checked is that the anchors are where they must be. The
// overlay only closes the bypass if every path that could reach the operator's
// terminal MATCH passes through a rule the overlay resolves, so the anchors'
// positions are the security property, not a formatting preference.

// The anchor rules, as mihomo parses them.
const (
	overlayClientAnchorRule = "RUNTIME-OVERLAY," + overlayOwner + ",client"
	overlayEgressAnchorRule = "RUNTIME-OVERLAY," + overlayOwner + ",egress"
	// overlayProcessorProxyKey marks an outbound as the overlay's processor.
	// The core will not stage a generation whose capture rules name an outbound
	// that has not declared this, so an overlay cannot be made to hand traffic
	// to an arbitrary proxy by naming it.
	overlayProcessorProxyKey = "runtime-overlay-processor"
	// overlayRuntimeBlockPlaceholder is the one line of the seed template that
	// the daemon still substitutes. The anchors are literal there; this is not,
	// because it names box-specific sockets and peer identities.
	overlayRuntimeBlockPlaceholder = "__OVERLAY_RUNTIME_BLOCK__"
)

// analyzeOverlayAnchoredDocument checks an anchored config and extracts what
// compiling a generation needs from it.
func analyzeOverlayAnchoredDocument(text string) interceptRoutingAnalysis {
	analysis := interceptRoutingAnalysis{Reason: "invalid-config"}
	document, err := parseMihomoNodeDocument(text)
	if err != nil || len(document.Content) != 1 || hasYAMLAliasOrMerge(document.Content[0]) {
		return analysis
	}
	root := document.Content[0]

	// The processor's inbound and outbound are still the gateway's own, and the
	// overlay does not create them. A capability names a listener; if that
	// listener is not the one this build expects, the capability authorises
	// traffic arriving somewhere else.
	if !hasExactInterceptListener(mappingNodeValue(root, "listeners")) {
		analysis.Reason = "interception-listener-missing"
		return analysis
	}
	if !hasExactModuleProxyOverlay(mappingNodeValue(root, "proxies")) {
		analysis.Reason = "interception-proxy-missing"
		return analysis
	}

	rules := mappingNodeValue(root, "rules")
	if rules == nil || rules.Kind != yaml.SequenceNode {
		analysis.Reason = "rules-structure-conflict"
		return analysis
	}
	matchIndex, matchTarget, ok := terminalMatchRule(rules)
	if !ok {
		analysis.Reason = "terminal-match-missing"
		return analysis
	}
	available, err := interceptAvailableEgressGroupsNode(root)
	if err != nil {
		analysis.Reason = "proxy-groups-structure-conflict"
		return analysis
	}

	clientIndex, egressIndex, rejectIndex := -1, -1, -1
	for index, item := range rules.Content {
		if item.Kind != yaml.ScalarNode {
			analysis.Reason = "rules-structure-conflict"
			return analysis
		}
		switch strings.TrimSpace(item.Value) {
		case overlayClientAnchorRule:
			if clientIndex != -1 {
				// Two anchors of the same stage would make "which one resolved
				// this connection" depend on rule order rather than on the
				// overlay, and the core refuses the config outright.
				analysis.Reason = "overlay-client-anchor-duplicate"
				return analysis
			}
			clientIndex = index
		case overlayEgressAnchorRule:
			if egressIndex != -1 {
				analysis.Reason = "overlay-egress-anchor-duplicate"
				return analysis
			}
			egressIndex = index
		case interceptEgressRejectRule:
			if rejectIndex != -1 {
				analysis.Reason = "interception-egress-terminator-duplicate"
				return analysis
			}
			rejectIndex = index
		}
	}

	if clientIndex < 0 {
		analysis.Reason = "overlay-client-anchor-missing"
		return analysis
	}
	if egressIndex < 0 {
		analysis.Reason = "overlay-egress-anchor-missing"
		return analysis
	}
	if rejectIndex < 0 {
		analysis.Reason = "interception-egress-terminator-missing"
		return analysis
	}

	// The egress anchor must sit immediately above the fail-closed terminator.
	// Anything between the two is a rule the processor's traffic reaches after
	// the overlay declined it and before the deny catches it — which is exactly
	// the fall-through the terminator exists to prevent.
	if egressIndex != rejectIndex-1 {
		analysis.Reason = "overlay-egress-anchor-misplaced"
		return analysis
	}
	// The client anchor must resolve before the operator's terminal MATCH,
	// otherwise captured traffic reaches the operator's rules and is never
	// steered at the processor.
	if clientIndex >= matchIndex {
		analysis.Reason = "overlay-client-anchor-after-match"
		return analysis
	}
	if rejectIndex >= matchIndex {
		analysis.Reason = "interception-egress-terminator-missing"
		return analysis
	}

	return interceptRoutingAnalysis{
		Manageable:    true,
		Reconcileable: true,
		Ready:         true,
		Document:      root,
		Rules:         rules,
		// The overlay carries the egress rules, so there is no insertion point
		// in the file. A negative offset makes a caller that reaches for one
		// fail rather than silently splice at the head of the rule list.
		EgressInsertAt:        -1,
		MatchTarget:           matchTarget,
		AvailableEgressGroups: available,
		PolicyStart:           -1,
	}
}

// mihomoConfigIsOverlayAnchored reports whether a config delegates interception
// routing to the overlay, without judging whether it does so correctly.
//
// Used to choose the driver for a config the gateway did not write — an
// operator who added the anchors by hand has asked for the overlay, and the
// misplacement diagnostics belong to the analyser rather than to the choice of
// which analyser to run.
func mihomoConfigIsOverlayAnchored(text string) bool {
	document, err := parseMihomoNodeDocument(text)
	if err != nil || len(document.Content) != 1 {
		return false
	}
	rules := mappingNodeValue(document.Content[0], "rules")
	if rules == nil || rules.Kind != yaml.SequenceNode {
		return false
	}
	for _, item := range rules.Content {
		if item.Kind != yaml.ScalarNode {
			continue
		}
		switch strings.TrimSpace(item.Value) {
		case overlayClientAnchorRule, overlayEgressAnchorRule:
			return true
		}
	}
	return false
}

// extractOverlayRuntimeBlock returns the `runtime-overlay:` mapping from a
// config, re-serialised, or "" when there is none.
//
// Restoring the install-time seed has to reproduce the arrangement this box is
// actually running. The overlay block names sockets and the uids permitted to
// use them — box-specific infrastructure, like the listeners and the controller
// secret, not policy. Re-deriving it would mean guessing values the installer
// chose; carrying it across keeps the restored seed truthful about the machine
// it is restored onto.
func extractOverlayRuntimeBlock(text string) string {
	document, err := parseMihomoNodeDocument(text)
	if err != nil || len(document.Content) != 1 {
		return ""
	}
	block := mappingNodeValue(document.Content[0], "runtime-overlay")
	if block == nil {
		return ""
	}
	wrapper := &yaml.Node{
		Kind: yaml.MappingNode,
		Content: []*yaml.Node{
			{Kind: yaml.ScalarNode, Value: "runtime-overlay"},
			block,
		},
	}
	encoded, err := yaml.Marshal(wrapper)
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(encoded), "\n")
}

// renderSeedOverlay substitutes the seed template's runtime-overlay block.
//
// The two anchors are inline in the template: the overlay is the only routing
// driver, so a seed without them describes a gateway that cannot carry
// interception at all. The block stays a placeholder because it names this
// box's sockets and the peer uids permitted to open them — infrastructure only
// the installer knows, like the listeners and the controller secret.
//
// An empty block leaves anchors mihomo cannot resolve, which makes the config
// unparseable rather than merely inert. Callers establish that they have one
// before rendering; MihomoConfigStore.Default refuses instead of guessing.
func renderSeedOverlay(template, runtimeBlock string) string {
	lines := strings.Split(template, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if line == overlayRuntimeBlockPlaceholder {
			if strings.TrimSpace(runtimeBlock) != "" {
				out = append(out, runtimeBlock)
			}
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}
