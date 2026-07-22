package main

import (
	"fmt"
	"sort"
	"strings"
	"testing"
)

func testInterceptMihomoYAML(rules []string, groups ...string) string {
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

func TestInterceptMihomoRoutingUsesExecutionOrderAndDeduplicatesSelectors(t *testing.T) {
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"io.example.second", "io.example.first"},
		Modules: []interceptModuleSnapshot{
			{
				ID: "io.example.first", Enabled: true, EgressGroup: "Japan",
				CaptureHosts:   []string{"api.example.com"},
				NetworkOrigins: []string{"https://assets.example.com:8443"},
				HostMappings:   []interceptHostMapping{{Pattern: "api.example.com", Target: "203.0.113.7"}},
			},
			{
				ID: "io.example.second", Enabled: true, EgressGroup: "Proxies",
				CaptureHosts: []string{"api.example.com", "*.example.net"},
			},
		},
	}

	routing := interceptMihomoRouting(document)
	shared := "AND,((IN-NAME,intercept-egress),(DOMAIN,api.example.com),(DST-PORT,443)),Proxies"
	if countString(routing.Egress, shared) != 1 {
		t.Fatalf("shared selector must be owned by the first module: %v", routing.Egress)
	}
	for _, rule := range routing.Egress {
		if strings.Contains(rule, "DOMAIN,api.example.com") && strings.HasSuffix(rule, ",Japan") {
			t.Fatalf("later module reclaimed a duplicate selector: %s", rule)
		}
	}
	wants := []string{
		"AND,((IN-NAME,intercept-egress),(DOMAIN,assets.example.com),(DST-PORT,8443)),Japan",
		"AND,((IN-NAME,intercept-egress),(IP-CIDR,203.0.113.7/32,no-resolve),(DST-PORT,80)),Japan",
		"AND,((IN-NAME,intercept-egress),(IP-CIDR,203.0.113.7/32,no-resolve),(DST-PORT,443)),Japan",
		"AND,((IN-NAME,intercept-egress),(DOMAIN-WILDCARD,*.example.net),(DST-PORT,443)),Proxies",
	}
	for _, want := range wants {
		if !containsString(routing.Egress, want) {
			t.Errorf("missing egress rule %q in %v", want, routing.Egress)
		}
	}
	if !sortStringsEqual(routing.Capture, uniqueSortedStrings(routing.Capture)) {
		t.Fatalf("capture block is not canonical: %v", routing.Capture)
	}
}

func TestInterceptMihomoRoutingCompactsSameOwnerApexWildcard(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	module.EgressGroup = "Japan"
	module.CaptureDNS = interceptCaptureDNSChina
	module.CaptureHosts = []string{"*.example.com", "example.com"}
	module.RoutingRules = []interceptRoutingRule{
		{Action: "reject", Domain: "example.com"},
		{Action: "reject", DomainSuffix: "example.com"},
	}
	document, _ := testInterceptDocument(t, module)
	routing := interceptMihomoRouting(document)

	for _, port := range []int{80, 443} {
		selector := interceptEgressSelector{Kind: "DOMAIN-SUFFIX", Value: "example.com", Port: port}
		if !containsString(routing.Capture, renderInterceptCaptureRule(selector)) {
			t.Errorf("missing compact capture selector for port %d: %v", port, routing.Capture)
		}
		if !containsString(routing.Egress, renderInterceptEgressRule(selector, "Japan")) {
			t.Errorf("missing compact egress selector for port %d: %v", port, routing.Egress)
		}
	}
	if len(routing.Capture) != 2 || len(routing.Egress) != 2 || strings.Contains(strings.Join(routing.Capture, "\n"), "DOMAIN-WILDCARD") || strings.Contains(strings.Join(routing.Egress, "\n"), "(DOMAIN,example.com)") {
		t.Fatalf("same-owner pair was not compacted exactly once per port: %+v", routing)
	}
	if !stringSlicesEqual(routing.Policy, []string{"DOMAIN,example.com,REJECT", "DOMAIN-SUFFIX,example.com,REJECT"}) {
		t.Fatalf("reviewed routing rules were incorrectly compacted: %v", routing.Policy)
	}
	if got := activeInterceptHosts(document); !stringSlicesEqual(got, []string{"*.example.com", "example.com"}) {
		t.Fatalf("DNS overlay hosts changed by mihomo compaction: %v", got)
	}
	if got := certificateInterceptHosts(document); !stringSlicesEqual(got, []string{"*.example.com", "example.com"}) {
		t.Fatalf("certificate hosts changed by mihomo compaction: %v", got)
	}
	snapshot := newInterceptHostSnapshot(document)
	for _, host := range []string{"example.com", "api.example.com"} {
		resolver, owner, matched := snapshot.CaptureDNS(host)
		if !matched || resolver != interceptCaptureDNSChina || owner != module.ID {
			t.Fatalf("DNS matcher changed for %s: matched=%t resolver=%s owner=%s", host, matched, resolver, owner)
		}
	}
}

func TestInterceptMihomoRoutingDoesNotCompactUnpairedOrCrossOwnerHosts(t *testing.T) {
	for _, test := range []struct {
		name      string
		host      string
		wantKind  string
		wantValue string
	}{
		{name: "exact only", host: "example.com", wantKind: "DOMAIN", wantValue: "example.com"},
		{name: "wildcard only", host: "*.example.com", wantKind: "DOMAIN-WILDCARD", wantValue: "*.example.com"},
	} {
		t.Run(test.name, func(t *testing.T) {
			module := testModuleSnapshot()
			module.Enabled = true
			module.CaptureHosts = []string{test.host}
			module.Scripts[0].Match.Hosts = []string{test.host}
			document, _ := testInterceptDocument(t, module)
			routing := interceptMihomoRouting(document)
			want := renderInterceptCaptureRule(interceptEgressSelector{Kind: test.wantKind, Value: test.wantValue, Port: 443})
			if len(routing.Capture) != 2 || !containsString(routing.Capture, want) || strings.Contains(strings.Join(routing.Capture, "\n"), "DOMAIN-SUFFIX") {
				t.Fatalf("unpaired host changed shape: %v", routing.Capture)
			}
		})
	}

	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"io.example.exact", "io.example.wildcard"},
		Modules: []interceptModuleSnapshot{
			{ID: "io.example.exact", Enabled: true, EgressGroup: "Japan", CaptureHosts: []string{"example.com"}},
			{ID: "io.example.wildcard", Enabled: true, EgressGroup: "Proxies", CaptureHosts: []string{"*.example.com"}},
		},
	}
	routing := interceptMihomoRouting(document)
	if strings.Contains(strings.Join(append(append([]string{}, routing.Egress...), routing.Capture...), "\n"), "DOMAIN-SUFFIX") {
		t.Fatalf("different owners were compacted: %+v", routing)
	}
	exact := renderInterceptEgressRule(interceptEgressSelector{Kind: "DOMAIN", Value: "example.com", Port: 443}, "Japan")
	wildcard := renderInterceptEgressRule(interceptEgressSelector{Kind: "DOMAIN-WILDCARD", Value: "*.example.com", Port: 443}, "Proxies")
	if !containsString(routing.Egress, exact) || !containsString(routing.Egress, wildcard) || stringIndex(routing.Egress, exact) >= stringIndex(routing.Egress, wildcard) {
		t.Fatalf("cross-owner target/order changed: %v", routing.Egress)
	}
}

func TestInterceptMihomoRoutingCompactionPreservesCrossPluginPrecedence(t *testing.T) {
	pair := interceptModuleSnapshot{ID: "io.example.pair", Enabled: true, EgressGroup: "Proxies", CaptureHosts: []string{"*.example.com", "example.com"}}
	exact := interceptModuleSnapshot{ID: "io.example.api", Enabled: true, EgressGroup: "Japan", CaptureHosts: []string{"api.example.com"}}
	document := interceptConfigDocument{MITM: interceptMITMSettings{Enabled: true}, Modules: []interceptModuleSnapshot{pair, exact}}
	pairRule := renderInterceptEgressRule(interceptEgressSelector{Kind: "DOMAIN-SUFFIX", Value: "example.com", Port: 443}, "Proxies")
	exactRule := renderInterceptEgressRule(interceptEgressSelector{Kind: "DOMAIN", Value: "api.example.com", Port: 443}, "Japan")

	document.ExecutionOrder = []string{exact.ID, pair.ID}
	routing := interceptMihomoRouting(document)
	exactAt, pairAt := stringIndex(routing.Egress, exactRule), stringIndex(routing.Egress, pairRule)
	if exactAt < 0 || pairAt < 0 || exactAt >= pairAt {
		t.Fatalf("earlier exact owner no longer wins: %v", routing.Egress)
	}
	document.ExecutionOrder = []string{pair.ID, exact.ID}
	routing = interceptMihomoRouting(document)
	exactAt, pairAt = stringIndex(routing.Egress, exactRule), stringIndex(routing.Egress, pairRule)
	if exactAt < 0 || pairAt < 0 || pairAt >= exactAt {
		t.Fatalf("earlier compact suffix owner no longer wins: %v", routing.Egress)
	}

	// A bound exact selector still precedes an earlier unbound compact pair.
	pair.EgressGroup = ""
	document.Modules = []interceptModuleSnapshot{pair, exact}
	document.ExecutionOrder = []string{pair.ID, exact.ID}
	routing = interceptMihomoRouting(document)
	pairTerminal := renderInterceptEgressRule(interceptEgressSelector{Kind: "DOMAIN-SUFFIX", Value: "example.com", Port: 443}, interceptTerminalMatchTarget)
	exactAt, pairAt = stringIndex(routing.Egress, exactRule), stringIndex(routing.Egress, pairTerminal)
	if exactAt < 0 || pairAt < 0 || exactAt >= pairAt {
		t.Fatalf("explicit binding priority changed by compaction: %v", routing.Egress)
	}
}

func TestInterceptMihomoRoutingRendersReviewedPolicyRulesInExecutionOrder(t *testing.T) {
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"io.example.first", "io.example.second"},
		Modules: []interceptModuleSnapshot{
			{ID: "io.example.second", Enabled: true, CaptureHosts: []string{"two.example.com"}, RoutingRules: []interceptRoutingRule{
				{Action: "direct", IPCIDR: "203.0.113.7/32"},
			}},
			{ID: "io.example.first", Enabled: true, CaptureHosts: []string{"one.example.com"}, RoutingRules: []interceptRoutingRule{
				{Action: "reject", DomainSuffix: "chat.example.com", DomainKeywords: []string{"stun", "tracker"}, Network: "udp"},
				{Action: "reject", Domain: "ads.example.com"},
				{Action: "reject", DomainKeywords: []string{"ads", "tracker"}},
			}},
		},
	}
	routing := interceptMihomoRouting(document)
	want := []string{
		"AND,((DOMAIN-SUFFIX,chat.example.com),(OR,((DOMAIN-KEYWORD,stun),(DOMAIN-KEYWORD,tracker))),(NETWORK,UDP)),REJECT",
		"DOMAIN,ads.example.com,REJECT",
		"OR,((DOMAIN-KEYWORD,ads),(DOMAIN-KEYWORD,tracker)),REJECT",
		"IP-CIDR,203.0.113.7/32,DIRECT,no-resolve",
	}
	if strings.Join(routing.Policy, "\n") != strings.Join(want, "\n") {
		t.Fatalf("policy rules = %v, want %v", routing.Policy, want)
	}
	base := testInterceptMihomoYAML([]string{interceptEgressRejectRule, "MATCH,Proxies"}, "Proxies")
	analysis := analyzeInterceptRoutingDocument(base, document)
	if !analysis.Reconcileable {
		t.Fatalf("base routing is not reconcileable: %+v", analysis)
	}
	rendered, err := renderInterceptRoutingDocument(analysis, document)
	if err != nil {
		t.Fatal(err)
	}
	verified := analyzeInterceptRoutingDocument(rendered, document)
	if !verified.Manageable || !verified.Ready {
		t.Fatalf("rendered routing rejected: %+v\n%s", verified, rendered)
	}
	for _, rule := range want {
		if !strings.Contains(rendered, rule) {
			t.Errorf("rendered config is missing %q", rule)
		}
	}
}

func TestAnalyzeInterceptRoutingReconcilesMissingPolicyButRejectsExtraRules(t *testing.T) {
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"io.example.fixture"},
		Modules: []interceptModuleSnapshot{{
			ID: "io.example.fixture", Enabled: true, CaptureHosts: []string{"api.example.com"},
			RoutingRules: []interceptRoutingRule{{Action: "reject", Domain: "ads.example.com"}},
		}},
	}
	routing := materializeInterceptRoutingRules(interceptMihomoRouting(document), "Proxies")
	missingRules := append([]string(nil), routing.Egress...)
	missingRules = append(missingRules, interceptEgressRejectRule)
	missingRules = append(missingRules, routing.Capture...)
	missingRules = append(missingRules, "MATCH,Proxies")
	missing := testInterceptMihomoYAML(missingRules, "Proxies")
	missingAnalysis := analyzeInterceptRoutingDocument(missing, document)
	if !missingAnalysis.Reconcileable || missingAnalysis.Manageable || missingAnalysis.Reason != "interception-policy-rules-out-of-sync" {
		t.Fatalf("missing reviewed policy was not safely reconcileable: %+v", missingAnalysis)
	}
	restored, err := renderInterceptRoutingDocument(missingAnalysis, document)
	if err != nil {
		t.Fatal(err)
	}
	if analysis := analyzeInterceptRoutingDocument(restored, document); !analysis.Manageable || !analysis.Ready {
		t.Fatalf("restored routing did not verify: %+v\n%s", analysis, restored)
	}

	extraRules := append([]string(nil), routing.Egress...)
	extraRules = append(extraRules, interceptEgressRejectRule)
	extraRules = append(extraRules, routing.Policy...)
	extraRules = append(extraRules, "DOMAIN,operator.example,DIRECT")
	extraRules = append(extraRules, routing.Capture...)
	extraRules = append(extraRules, "MATCH,Proxies")
	extra := testInterceptMihomoYAML(extraRules, "Proxies")
	extraAnalysis := analyzeInterceptRoutingDocument(extra, document)
	if extraAnalysis.Reconcileable || extraAnalysis.Manageable || extraAnalysis.Reason != "interception-policy-rules-out-of-sync" {
		t.Fatalf("unexpected operator rule was claimed by the extension transaction: %+v", extraAnalysis)
	}
	if _, err := renderInterceptRoutingDocument(extraAnalysis, document); err == nil {
		t.Fatal("unexpected operator rule was removable by extension reconciliation")
	}

	extraEgressRules := append([]string{
		"AND,((IN-NAME,intercept-egress),(DOMAIN,operator.example),(DST-PORT,443)),Proxies",
	}, routing.Egress...)
	extraEgressRules = append(extraEgressRules, interceptEgressRejectRule)
	extraEgressRules = append(extraEgressRules, routing.Policy...)
	extraEgressRules = append(extraEgressRules, routing.Capture...)
	extraEgressRules = append(extraEgressRules, "MATCH,Proxies")
	extraEgress := testInterceptMihomoYAML(extraEgressRules, "Proxies")
	if analysis := analyzeInterceptRoutingDocument(extraEgress, document); analysis.Reconcileable || analysis.Reason != "interception-egress-rules-out-of-sync" {
		t.Fatalf("unexpected canonical egress rule was claimable: %+v", analysis)
	}

	extraCaptureRules := append([]string(nil), routing.Egress...)
	extraCaptureRules = append(extraCaptureRules, interceptEgressRejectRule)
	extraCaptureRules = append(extraCaptureRules, routing.Policy...)
	extraCaptureRules = append(extraCaptureRules, routing.Capture...)
	extraCaptureRules = append(extraCaptureRules, "AND,((DOMAIN,operator.example),(DST-PORT,443)),MODULE-INTERCEPT")
	extraCaptureRules = append(extraCaptureRules, "MATCH,Proxies")
	extraCapture := testInterceptMihomoYAML(extraCaptureRules, "Proxies")
	if analysis := analyzeInterceptRoutingDocument(extraCapture, document); analysis.Reconcileable || analysis.Reason != "interception-rules-out-of-sync" {
		t.Fatalf("unexpected canonical capture rule was claimable: %+v", analysis)
	}
}

func TestAnalyzeInterceptRoutingParsesAndRebuildsCompactSuffixRules(t *testing.T) {
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"io.example.pair"},
		Modules: []interceptModuleSnapshot{{
			ID: "io.example.pair", Enabled: true, EgressGroup: "Proxies", CaptureHosts: []string{"*.example.com", "example.com"},
		}},
	}
	routing := materializeInterceptRoutingRules(interceptMihomoRouting(document), "Proxies")
	if len(routing.Egress) != 2 || len(routing.Capture) != 2 {
		t.Fatalf("compact routing size = egress:%d capture:%d", len(routing.Egress), len(routing.Capture))
	}
	selector, target, ok := parseCanonicalInterceptEgressRule(routing.Egress[0])
	if !ok || selector.Kind != "DOMAIN-SUFFIX" || selector.Value != "example.com" || target != "Proxies" {
		t.Fatalf("compact egress parser = %+v/%q/%t", selector, target, ok)
	}
	if !validCanonicalInterceptRule(routing.Capture[0]) {
		t.Fatalf("compact capture rule is not canonical: %s", routing.Capture[0])
	}

	partialRules := []string{routing.Egress[0], interceptEgressRejectRule, routing.Capture[0], "MATCH,Proxies"}
	partial := testInterceptMihomoYAML(partialRules, "Proxies")
	analysis := analyzeInterceptRoutingDocument(partial, document)
	if !analysis.Reconcileable || analysis.Manageable || analysis.Reason == "" {
		t.Fatalf("partial compact block was not safely reconcileable: %+v", analysis)
	}
	rebuilt, err := renderInterceptRoutingDocument(analysis, document)
	if err != nil {
		t.Fatal(err)
	}
	if verified := analyzeInterceptRoutingDocument(rebuilt, document); !verified.Manageable || !verified.Ready {
		t.Fatalf("rebuilt compact block rejected: %+v\n%s", verified, rebuilt)
	}
	for _, rule := range append(append([]string{}, routing.Egress...), routing.Capture...) {
		if !strings.Contains(rebuilt, rule) {
			t.Errorf("rebuilt config is missing %q", rule)
		}
	}

	extraRules := append([]string(nil), routing.Egress...)
	extraRules = append(extraRules,
		"AND,((IN-NAME,intercept-egress),(DOMAIN-SUFFIX,operator.example),(DST-PORT,443)),Proxies",
		interceptEgressRejectRule,
	)
	extraRules = append(extraRules, routing.Capture...)
	extraRules = append(extraRules, "MATCH,Proxies")
	if extra := analyzeInterceptRoutingDocument(testInterceptMihomoYAML(extraRules, "Proxies"), document); extra.Reconcileable || extra.Reason != "interception-egress-rules-out-of-sync" {
		t.Fatalf("unexpected compact egress selector was claimable: %+v", extra)
	}
	if _, _, ok := parseCanonicalInterceptEgressRule("AND,((IN-NAME,intercept-egress),(DOMAIN-SUFFIX,*.example.com),(DST-PORT,443)),Proxies"); ok {
		t.Fatal("wildcard value was accepted inside DOMAIN-SUFFIX")
	}
	expanded := expandedPairRouting(document.Modules[0], "Proxies")
	if legacy := analyzeInterceptRoutingDocument(routingFixture(expanded, "Proxies"), document); legacy.Reconcileable || legacy.Manageable {
		t.Fatalf("expanded pre-compaction blocks were silently migrated: %+v", legacy)
	}
}

func TestInterceptMihomoRoutingPolicyRequiresEnabledModuleAndMaster(t *testing.T) {
	document := interceptConfigDocument{
		ExecutionOrder: []string{"io.example.fixture"},
		Modules: []interceptModuleSnapshot{{
			ID: "io.example.fixture", Enabled: true, CaptureHosts: []string{"api.example.com"},
			RoutingRules: []interceptRoutingRule{{Action: "reject", Domain: "ads.example.com"}},
		}},
	}
	if routing := interceptMihomoRouting(document); len(routing.Policy) != 0 {
		t.Fatalf("policy activated while MITM was disabled: %v", routing.Policy)
	}
	document.MITM.Enabled = true
	document.Modules[0].Enabled = false
	if routing := interceptMihomoRouting(document); len(routing.Policy) != 0 {
		t.Fatalf("policy activated while extension was disabled: %v", routing.Policy)
	}
}

func TestInterceptMihomoRoutingBoundExtensionWinsOverEarlierUnboundExtension(t *testing.T) {
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"io.example.default", "io.example.bound"},
		Modules: []interceptModuleSnapshot{
			{ID: "io.example.default", Enabled: true, CaptureHosts: []string{"api.example.com"}},
			{ID: "io.example.bound", Enabled: true, EgressGroup: "Japan", CaptureHosts: []string{"api.example.com"}},
		},
	}
	routing := interceptMihomoRouting(document)
	want := "AND,((IN-NAME,intercept-egress),(DOMAIN,api.example.com),(DST-PORT,443)),Japan"
	if countString(routing.Egress, want) != 1 {
		t.Fatalf("bound route did not win: %v", routing.Egress)
	}
	for _, rule := range routing.Egress {
		if strings.Contains(rule, "api.example.com") && strings.HasSuffix(rule, ","+interceptTerminalMatchTarget) {
			t.Fatalf("default route shadowed an explicit binding: %s", rule)
		}
	}
}

func TestInterceptMihomoRoutingFallsBackToTerminalMatch(t *testing.T) {
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"io.example.fixture"},
		Modules: []interceptModuleSnapshot{{
			ID: "io.example.fixture", Enabled: true, CaptureHosts: []string{"api.example.com"},
		}},
	}
	routing := interceptMihomoRouting(document)
	for _, rule := range routing.Egress {
		if !strings.HasSuffix(rule, ","+interceptTerminalMatchTarget) {
			t.Fatalf("unbound selector did not retain the terminal MATCH placeholder: %s", rule)
		}
	}

	base := testInterceptMihomoYAML([]string{interceptEgressRejectRule, "MATCH,Japan Select"}, "Japan Select")
	analysis := analyzeInterceptRoutingDocument(base, document)
	if !analysis.Reconcileable || analysis.Manageable || analysis.MatchTarget != "Japan Select" {
		t.Fatalf("unexpected base analysis: %+v", analysis)
	}
	rendered, err := renderInterceptRoutingDocument(analysis, document)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(rendered, interceptTerminalMatchTarget) || !strings.Contains(rendered, "),Japan Select") {
		t.Fatalf("terminal target was not materialized:\n%s", rendered)
	}
	verified := analyzeInterceptRoutingDocument(rendered, document)
	if !verified.Manageable || !verified.Ready {
		t.Fatalf("rendered routing did not verify: %+v\n%s", verified, rendered)
	}
}

func TestAnalyzeInterceptRoutingRejectsWrongEgressOrderAndMissingGroup(t *testing.T) {
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"io.example.first", "io.example.second"},
		Modules: []interceptModuleSnapshot{
			{ID: "io.example.first", Enabled: true, EgressGroup: "Japan Select", CaptureHosts: []string{"a.example.com"}},
			{ID: "io.example.second", Enabled: true, EgressGroup: "Proxies", CaptureHosts: []string{"b.example.com"}},
		},
	}
	routing := materializeInterceptRoutingRules(interceptMihomoRouting(document), "Proxies")
	rules := append([]string(nil), routing.Egress...)
	rules = append(rules, interceptEgressRejectRule)
	rules = append(rules, routing.Capture...)
	rules = append(rules, "MATCH,Proxies")
	valid := testInterceptMihomoYAML(rules, "Japan Select", "Proxies")
	if analysis := analyzeInterceptRoutingDocument(valid, document); !analysis.Manageable {
		t.Fatalf("valid ordered routing rejected: %+v", analysis)
	}

	tamperedRules := append([]string(nil), rules...)
	tamperedRules[0], tamperedRules[2] = tamperedRules[2], tamperedRules[0]
	tampered := testInterceptMihomoYAML(tamperedRules, "Japan Select", "Proxies")
	if analysis := analyzeInterceptRoutingDocument(tampered, document); analysis.Manageable || analysis.Reason != "interception-egress-rules-out-of-sync" {
		t.Fatalf("wrong egress order was accepted: %+v", analysis)
	}

	missing := testInterceptMihomoYAML(rules, "Proxies")
	if analysis := analyzeInterceptRoutingDocument(missing, document); analysis.Manageable || analysis.Reason != "egress-group-missing" {
		t.Fatalf("missing explicit group was accepted: %+v", analysis)
	}
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

func TestInterceptMihomoRoutingAdScaleCompactionSaves404RulesAndConfigBytes(t *testing.T) {
	document := apexWildcardPairDocument(101)
	compact := materializeInterceptRoutingRules(interceptMihomoRouting(document), "Proxies")
	expanded := expandedPairRouting(document.Modules[0], "Proxies")
	compactCount := len(compact.Egress) + len(compact.Capture)
	expandedCount := len(expanded.Egress) + len(expanded.Capture)
	if compactCount != 404 || expandedCount != 808 || expandedCount-compactCount != 404 {
		t.Fatalf("managed rule counts compact=%d expanded=%d saved=%d, want 404/808/404", compactCount, expandedCount, expandedCount-compactCount)
	}
	compactConfig := routingFixture(compact, "Proxies")
	expandedConfig := routingFixture(expanded, "Proxies")
	if len(compactConfig) >= len(expandedConfig) {
		t.Fatalf("compact config bytes=%d, expanded=%d", len(compactConfig), len(expandedConfig))
	}
	t.Logf("101 apex/wildcard pairs: managed rules %d -> %d (saved %d); mihomo YAML %d -> %d bytes (saved %d)",
		expandedCount, compactCount, expandedCount-compactCount, len(expandedConfig), len(compactConfig), len(expandedConfig)-len(compactConfig))
}

func TestPreV5ExplicitRebuildPreservesBoundaryAndRejectsResidualExpandedRules(t *testing.T) {
	legacyModule := testModuleSnapshot()
	legacyModule.Enabled = true
	legacyModule.CaptureHosts = []string{"*.example.com", "example.com"}
	legacy := interceptConfigDocument{
		Version: 4,
		Listen:  "127.0.0.1:18080", Username: "interception-unavailable", Password: "interception-unavailable-password",
		TLSCert: "/etc/5gpn/intercept/tls/fullchain.pem", TLSKey: "/etc/5gpn/intercept/tls/privkey.pem",
		UpstreamProxy: interceptProxyConfig{
			Address: "127.0.0.1:17890", Username: "interception-upstream-unavailable", Password: "interception-upstream-unavailable-password",
		},
		MITM:           interceptMITMSettings{Enabled: true, HTTP2: false, QUICFallbackProtection: true},
		ExecutionOrder: []string{legacyModule.ID}, Modules: []interceptModuleSnapshot{legacyModule},
	}
	candidate := explicitV5RebuildCandidate(legacy)
	if err := validateInterceptDocument(candidate); err != nil {
		t.Fatalf("explicit v5 candidate rejected: %v", err)
	}
	if candidate.Listen != legacy.Listen || candidate.Username != legacy.Username || candidate.Password != legacy.Password ||
		candidate.TLSCert != legacy.TLSCert || candidate.TLSKey != legacy.TLSKey || candidate.UpstreamProxy != legacy.UpstreamProxy ||
		candidate.MITM.Enabled || candidate.MITM.HTTP2 != legacy.MITM.HTTP2 || candidate.MITM.QUICFallbackProtection != legacy.MITM.QUICFallbackProtection ||
		len(candidate.Modules) != 0 || len(candidate.ExecutionOrder) != 0 {
		t.Fatalf("explicit rebuild did not preserve infrastructure and clear plugin state: %+v", candidate)
	}
	clean := goldenMihomoConfig()
	if !interceptCredentialsMatch(clean, candidate) {
		t.Fatal("credential-preserving v5 candidate no longer matches the preserved mihomo boundary")
	}
	if analysis := analyzeInterceptRoutingDocument(clean, candidate); !analysis.Manageable || !analysis.Ready {
		t.Fatalf("clean old-master-disable output is not manageable by empty v5: %+v", analysis)
	}

	expandedDocument := apexWildcardPairDocument(1)
	expanded := expandedPairRouting(expandedDocument.Modules[0], "Proxies")
	residual := routingFixture(expanded, "Proxies")
	if residual == clean {
		t.Fatal("old master disable did not change the mihomo bytes")
	}
	if analysis := analyzeInterceptRoutingDocument(residual, candidate); analysis.Reconcileable || analysis.Manageable {
		t.Fatalf("empty v5 candidate claimed residual expanded v4 rules: %+v", analysis)
	}
}

var benchmarkInterceptMihomoRouting interceptRoutingRules

func BenchmarkInterceptMihomoRoutingApexWildcardCompaction(b *testing.B) {
	document := apexWildcardPairDocument(101)
	b.ReportAllocs()
	for iteration := 0; iteration < b.N; iteration++ {
		benchmarkInterceptMihomoRouting = interceptMihomoRouting(document)
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
