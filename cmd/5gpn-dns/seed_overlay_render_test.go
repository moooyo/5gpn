package main

import "strings"

// The installer's seed template carries the runtime-overlay anchors literally
// and its runtime block as a placeholder, because the block names sockets and
// peer uids only the installing box knows. Tests that render the template have
// to substitute it, or they check a document whose anchors resolve to nothing.
//
// These are the values a real install writes, with the identities fixed so the
// rendered text is stable.
func testOverlayRuntimeBlock() string {
	return strings.Join([]string{
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

// renderSeedOverlayBlock expands the template's one remaining placeholder,
// tolerating the CRLF a checked-out template can carry on Windows.
func renderSeedOverlayBlock(text, runtimeBlock string) string {
	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.TrimRight(line, "\r") == overlayRuntimeBlockPlaceholder {
			if strings.TrimSpace(runtimeBlock) != "" {
				out = append(out, runtimeBlock)
			}
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}
