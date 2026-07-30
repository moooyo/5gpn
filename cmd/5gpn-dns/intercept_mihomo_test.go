package main

import (
	"fmt"
	"sort"
	"strings"
	"testing"
)

func testInterceptMihomoYAML(rules []string, groups ...string) string {
	// Every config this build can manage is anchored: a client anchor above the
	// operator's rules, and an egress anchor immediately above the fail-closed
	// terminator. Fixtures carry that shape so they exercise what a real
	// deployment runs rather than an arrangement the installer refuses.
	anchored := make([]string, 0, len(rules)+2)
	anchored = append(anchored, overlayClientAnchorRule)
	for _, rule := range rules {
		if rule == interceptEgressRejectRule {
			anchored = append(anchored, overlayEgressAnchorRule)
		}
		anchored = append(anchored, rule)
	}
	rules = anchored

	var groupYAML strings.Builder
	for _, group := range groups {
		groupYAML.WriteString("  - name: " + group + "\n    type: select\n    proxies: [DIRECT]\n")
	}
	var ruleYAML strings.Builder
	for _, rule := range rules {
		ruleYAML.WriteString("  - " + rule + "\n")
	}
	return `listeners:
  - name: intercept-egress
    type: mixed
    listen: 127.0.0.1
    port: 17890
    udp: true
    users:
      - username: upstream-user-0123456789
        password: upstream-password-01234567890123456789
proxies:
  - name: MODULE-INTERCEPT
    type: socks5
    server: 127.0.0.1
    port: 18080
    username: sidecar-user-0123456789
    password: sidecar-password-01234567890123456789
    udp: true
proxy-groups:
` + groupYAML.String() + "rules:\n" + ruleYAML.String()
}

func TestInterceptAvailableEgressGroups(t *testing.T) {
	text := testInterceptMihomoYAML([]string{interceptEgressRejectRule, "MATCH,Proxies"}, "Proxies", "Japan Select")
	groups, err := interceptAvailableEgressGroups(text)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"DIRECT", "Japan Select", "Proxies"}
	if !sortStringsEqual(groups, want) {
		t.Fatalf("groups = %v, want %v", groups, want)
	}

	duplicate := testInterceptMihomoYAML([]string{interceptEgressRejectRule, "MATCH,Proxies"}, "Proxies", "Proxies")
	if _, err := interceptAvailableEgressGroups(duplicate); err == nil {
		t.Fatal("duplicate proxy-group name was accepted")
	}

	reserved := testInterceptMihomoYAML([]string{interceptEgressRejectRule, "MATCH,Proxies"}, "Proxies", interceptTerminalMatchTarget)
	if _, err := interceptAvailableEgressGroups(reserved); err == nil {
		t.Fatal("reserved proxy-group name was accepted")
	}
}

// The selector functions below are shared: the overlay compiler builds its
// capture and egress rules from exactly these (see overlay_compile.go), so the
// compaction and precedence they encode are product policy, not a detail of the
// renderer that used to consume them.

// An apex and its own wildcard collapse to one suffix selector per captured
// port. This is what keeps an ad-blocking extension from minting two rules per
// host per port.
func TestInterceptCaptureSelectorsCompactSameOwnerApexWildcard(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	module.CaptureHosts = []string{"*.example.com", "example.com"}

	selectors := interceptModuleCaptureSelectors(module)
	if len(selectors) == 0 {
		t.Fatal("no capture selectors were produced")
	}
	ports := map[int]int{}
	for _, selector := range selectors {
		if selector.Kind != "DOMAIN-SUFFIX" || selector.Value != "example.com" {
			t.Fatalf("apex+wildcard did not compact to a suffix: %+v", selectors)
		}
		ports[selector.Port]++
	}
	for port, count := range ports {
		if count != 1 {
			t.Fatalf("port %d carries %d selectors, want exactly one: %+v", port, count, selectors)
		}
	}
}

// An unpaired apex and an unpaired wildcard both stay expanded: there is no
// second host to merge with, and widening either one would capture traffic the
// operator never listed.
func TestInterceptCaptureSelectorsDoNotCompactUnpairedHosts(t *testing.T) {
	apexOnly := testModuleSnapshot()
	apexOnly.Enabled = true
	apexOnly.CaptureHosts = []string{"example.com"}
	for _, selector := range interceptModuleCaptureSelectors(apexOnly) {
		if selector.Kind != "DOMAIN" {
			t.Fatalf("unpaired apex widened to %+v", selector)
		}
	}

	wildcardOnly := testModuleSnapshot()
	wildcardOnly.Enabled = true
	wildcardOnly.CaptureHosts = []string{"*.example.com"}
	for _, selector := range interceptModuleCaptureSelectors(wildcardOnly) {
		if selector.Kind != "DOMAIN-WILDCARD" {
			t.Fatalf("unpaired wildcard changed to %+v", selector)
		}
	}
}

// Compaction is per module, so a pair split across two extensions keeps each
// side with its own owner. Merging them would hand one extension traffic the
// operator assigned to another.
func TestInterceptCaptureSelectorsKeepCrossOwnerPairsSeparate(t *testing.T) {
	first := testModuleSnapshot()
	first.ID = "io.example.first"
	first.Enabled = true
	first.CaptureHosts = []string{"example.com"}
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Enabled = true
	second.CaptureHosts = []string{"*.example.com"}

	for _, selector := range interceptModuleCaptureSelectors(first) {
		if selector.Kind != "DOMAIN" {
			t.Fatalf("first owner compacted against another module: %+v", selector)
		}
	}
	for _, selector := range interceptModuleCaptureSelectors(second) {
		if selector.Kind != "DOMAIN-WILDCARD" {
			t.Fatalf("second owner compacted against another module: %+v", selector)
		}
	}
}

// Enabled modules reach the compiler in execution order; disabled ones do not.
func TestOrderedEnabledInterceptModulesFollowsExecutionOrder(t *testing.T) {
	first := testModuleSnapshot()
	first.ID = "io.example.first"
	first.Enabled = true
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Enabled = true
	disabled := testModuleSnapshot()
	disabled.ID = "io.example.disabled"
	disabled.Enabled = false

	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{second.ID, first.ID, disabled.ID},
		Modules:        []interceptModuleSnapshot{first, second, disabled},
	}
	ordered := orderedEnabledInterceptModules(document)
	if len(ordered) != 2 || ordered[0].ID != second.ID || ordered[1].ID != first.ID {
		t.Fatalf("ordered modules = %+v, want the execution order without the disabled one", ordered)
	}
}

var benchmarkInterceptCaptureSelectors []interceptEgressSelector

func BenchmarkInterceptCaptureSelectorsApexWildcardCompaction(b *testing.B) {
	document := apexWildcardPairDocument(101)
	module := document.Modules[0]
	b.ReportAllocs()
	for iteration := 0; iteration < b.N; iteration++ {
		benchmarkInterceptCaptureSelectors = interceptModuleCaptureSelectors(module)
	}
}

func apexWildcardPairDocument(pairCount int) interceptConfigDocument {
	hosts := make([]string, 0, pairCount*2)
	for index := 0; index < pairCount; index++ {
		base := fmt.Sprintf("ad%03d.example.com", index)
		hosts = append(hosts, base, "*."+base)
	}
	sort.Strings(hosts)
	module := interceptModuleSnapshot{ID: "io.example.ad-scale", Enabled: true, EgressGroup: "Proxies", CaptureHosts: hosts}
	return interceptConfigDocument{
		MITM: interceptMITMSettings{Enabled: true}, ExecutionOrder: []string{module.ID}, Modules: []interceptModuleSnapshot{module},
	}
}

func expandedPairRouting(module interceptModuleSnapshot, target string) interceptRoutingRules {
	routing := interceptRoutingRules{}
	for _, host := range module.CaptureHosts {
		kind := "DOMAIN"
		if strings.HasPrefix(host, "*.") {
			kind = "DOMAIN-WILDCARD"
		}
		for _, port := range []int{80, 443} {
			selector := interceptEgressSelector{Kind: kind, Value: host, Port: port}
			routing.Capture = append(routing.Capture, renderInterceptCaptureRule(selector))
			routing.Egress = append(routing.Egress, renderInterceptEgressRule(selector, target))
		}
	}
	sort.Strings(routing.Capture)
	sort.Strings(routing.Egress)
	return routing
}

func routingFixture(routing interceptRoutingRules, matchTarget string) string {
	rules := append([]string(nil), routing.Egress...)
	rules = append(rules, interceptEgressRejectRule)
	rules = append(rules, routing.Policy...)
	rules = append(rules, routing.Capture...)
	rules = append(rules, "MATCH,"+matchTarget)
	return testInterceptMihomoYAML(rules, matchTarget)
}

func explicitV5RebuildCandidate(legacy interceptConfigDocument) interceptConfigDocument {
	return interceptConfigDocument{
		Version: interceptConfigVersion,
		Listen:  legacy.Listen, Username: legacy.Username, Password: legacy.Password,
		TLSCert: legacy.TLSCert, TLSKey: legacy.TLSKey, UpstreamProxy: legacy.UpstreamProxy,
		MITM: interceptMITMSettings{
			Enabled: false, HTTP2: legacy.MITM.HTTP2, QUICFallbackProtection: legacy.MITM.QUICFallbackProtection,
		},
		ExecutionOrder: []string{}, Modules: []interceptModuleSnapshot{},
	}
}

func countString(values []string, want string) int {
	count := 0
	for _, value := range values {
		if value == want {
			count++
		}
	}
	return count
}

func stringIndex(values []string, want string) int {
	for index, value := range values {
		if value == want {
			return index
		}
	}
	return -1
}

func sortStringsEqual(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
