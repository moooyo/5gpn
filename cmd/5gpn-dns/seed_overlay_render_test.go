package main

import "strings"

// The installer's seed template carries the runtime-overlay anchors as
// placeholder lines, expanded only when the mihomo being installed has been
// shown to parse them. Tests that render the template have to do the same
// expansion, or they check a document that is not YAML at all.
//
// Both forms are real deployments and both are exercised: anchored is what a
// current core gets, unanchored is what a core without the overlay gets and the
// rollback position for one that has it.
func renderSeedOverlayPlaceholders(text string, overlay bool) string {
	expansions := map[string]string{
		"__OVERLAY_EGRESS_ANCHOR__": "",
		"__OVERLAY_CLIENT_ANCHOR__": "",
		"__OVERLAY_RUNTIME_BLOCK__": "",
	}
	if overlay {
		expansions["__OVERLAY_EGRESS_ANCHOR__"] = "  - " + overlayEgressAnchorRule
		expansions["__OVERLAY_CLIENT_ANCHOR__"] = "  - " + overlayClientAnchorRule
		expansions["__OVERLAY_RUNTIME_BLOCK__"] = strings.Join([]string{
			"",
			"runtime-overlay:",
			"  owner: " + overlayOwner,
			"  control-socket: /run/mihomo/overlay-control.sock",
			"  generation-socket: /run/mihomo/overlay-generation.sock",
			"  control-peer-uid: 991",
			"  control-peer-gid: 991",
			"  generation-peer-uid: 992",
			"  generation-peer-gid: 992",
		}, "\n")
	}

	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		expansion, isPlaceholder := expansions[strings.TrimRight(line, "\r")]
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
