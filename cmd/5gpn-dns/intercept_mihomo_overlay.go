package main

import (
	"strings"

	"gopkg.in/yaml.v3"
)

// Structural analysis of a mihomo config that delegates interception routing to
// the runtime overlay.
//
// The legacy analyser reconciles the rendered capture and egress rules it finds
// in the file against the rules the interception document implies. Under the
// overlay there are no such rules to find: the file carries two anchors, and
// the rules themselves live in a typed, generation-versioned document committed
// over a machine-only socket. Running the legacy analyser against an anchored
// config reports "out of sync" for the entirely correct state of an empty file
// and a populated overlay.
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
)

// analyzeOverlayAnchoredDocument checks an anchored config and extracts what
// compiling a generation needs from it.
//
// It deliberately reports the same shape as the legacy analyser so the apply
// path can hold one variable rather than branching on two types.
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
	return "\n" + strings.TrimRight(string(encoded), "\n")
}

// renderSeedOverlay expands the seed template's overlay placeholders.
//
// An empty block means the core does not implement the overlay, or this
// deployment has not adopted it; the anchors are then dropped rather than left
// inert, because an anchor mihomo cannot resolve makes the config unparseable.
func renderSeedOverlay(template, runtimeBlock string) string {
	anchors := map[string]string{
		"__OVERLAY_EGRESS_ANCHOR__": "",
		"__OVERLAY_CLIENT_ANCHOR__": "",
		"__OVERLAY_RUNTIME_BLOCK__": "",
	}
	if strings.TrimSpace(runtimeBlock) != "" {
		anchors["__OVERLAY_EGRESS_ANCHOR__"] = "  - " + overlayEgressAnchorRule
		anchors["__OVERLAY_CLIENT_ANCHOR__"] = "  - " + overlayClientAnchorRule
		anchors["__OVERLAY_RUNTIME_BLOCK__"] = runtimeBlock
	}
	lines := strings.Split(template, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		expansion, isPlaceholder := anchors[line]
		if !isPlaceholder {
			out = append(out, line)
			continue
		}
		if expansion != "" {
			out = append(out, expansion)
		}
	}
	return strings.Join(out, "\n")
}
