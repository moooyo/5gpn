package main

import (
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

func countString(values []string, want string) int {
	count := 0
	for _, value := range values {
		if value == want {
			count++
		}
	}
	return count
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
