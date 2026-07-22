package main

import (
	"errors"
	"fmt"
	"net"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const interceptMihomoProxyName = "MODULE-INTERCEPT"
const interceptTerminalMatchTarget = "__5GPN_TERMINAL_MATCH__"

const interceptEgressRejectRule = "IN-NAME,intercept-egress,REJECT"

var safeInterceptCredential = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

type interceptRoutingAnalysis struct {
	Manageable            bool
	Reconcileable         bool
	Ready                 bool
	Reason                string
	Document              *yaml.Node
	Rules                 *yaml.Node
	EgressInsertAt        int
	MatchTarget           string
	AvailableEgressGroups []string
	PolicyStart           int
	PolicyCount           int
}

type interceptRoutingRules struct {
	Capture []string
	Egress  []string
	Policy  []string
}

type interceptEgressSelector struct {
	Kind  string
	Value string
	Port  int
}

func interceptMihomoRouting(document interceptConfigDocument) interceptRoutingRules {
	if !document.MITM.Enabled {
		return interceptRoutingRules{}
	}
	orderedModules := orderedEnabledInterceptModules(document)
	capture := make([]string, 0, len(activeInterceptHosts(document))*2)
	for _, module := range orderedModules {
		for _, selector := range interceptModuleCaptureSelectors(module) {
			capture = append(capture, renderInterceptCaptureRule(selector))
		}
	}
	capture = uniqueSortedStrings(capture)

	// Explicit operator bindings win over default terminal routing. Execution
	// order resolves conflicts among bound extensions and, separately, among
	// unbound extensions that share the terminal target.
	egress := make([]string, 0, len(capture))
	seenSelectors := make(map[string]struct{})
	appendSelectors := func(bound bool) {
		for _, module := range orderedModules {
			if (module.EgressGroup != "") != bound {
				continue
			}
			target := module.EgressGroup
			if target == "" {
				target = interceptTerminalMatchTarget
			}
			for _, selector := range interceptModuleEgressSelectors(module) {
				identity := selector.Kind + "\x00" + selector.Value + "\x00" + strconv.Itoa(selector.Port)
				if _, duplicate := seenSelectors[identity]; duplicate {
					continue
				}
				seenSelectors[identity] = struct{}{}
				egress = append(egress, renderInterceptEgressRule(selector, target))
			}
		}
	}
	appendSelectors(true)
	appendSelectors(false)

	policy := make([]string, 0)
	seenPolicy := make(map[string]struct{})
	for _, module := range orderedModules {
		for _, route := range module.RoutingRules {
			rule := renderInterceptPolicyRule(route)
			if _, duplicate := seenPolicy[rule]; duplicate {
				continue
			}
			seenPolicy[rule] = struct{}{}
			policy = append(policy, rule)
		}
	}
	return interceptRoutingRules{Capture: capture, Egress: egress, Policy: policy}
}

func orderedEnabledInterceptModules(document interceptConfigDocument) []interceptModuleSnapshot {
	moduleByID := make(map[string]interceptModuleSnapshot, len(document.Modules))
	for _, module := range document.Modules {
		moduleByID[module.ID] = module
	}
	order := append([]string(nil), document.ExecutionOrder...)
	seenModules := make(map[string]struct{}, len(order))
	for _, id := range order {
		seenModules[id] = struct{}{}
	}
	for _, module := range document.Modules {
		if _, exists := seenModules[module.ID]; !exists {
			order = append(order, module.ID)
		}
	}

	orderedModules := make([]interceptModuleSnapshot, 0, len(order))
	for _, id := range order {
		module, exists := moduleByID[id]
		if !exists || !module.Enabled {
			continue
		}
		orderedModules = append(orderedModules, module)
	}
	return orderedModules
}

func renderInterceptPolicyRule(rule interceptRoutingRule) string {
	matchers := make([]string, 0, 4)
	if rule.Domain != "" {
		matchers = append(matchers, "(DOMAIN,"+rule.Domain+")")
	}
	if rule.DomainSuffix != "" {
		matchers = append(matchers, "(DOMAIN-SUFFIX,"+rule.DomainSuffix+")")
	}
	if rule.IPCIDR != "" {
		kind := "IP-CIDR"
		if strings.Contains(rule.IPCIDR, ":") {
			kind = "IP-CIDR6"
		}
		matchers = append(matchers, "("+kind+","+rule.IPCIDR+",no-resolve)")
	}
	if len(rule.DomainKeywords) == 1 {
		matchers = append(matchers, "(DOMAIN-KEYWORD,"+rule.DomainKeywords[0]+")")
	} else if len(rule.DomainKeywords) > 1 {
		keywords := make([]string, 0, len(rule.DomainKeywords))
		for _, keyword := range rule.DomainKeywords {
			keywords = append(keywords, "(DOMAIN-KEYWORD,"+keyword+")")
		}
		matchers = append(matchers, "(OR,("+strings.Join(keywords, ",")+"))")
	}
	for _, keyword := range rule.AllDomainKeywords {
		matchers = append(matchers, "(DOMAIN-KEYWORD,"+keyword+")")
	}
	if rule.Network != "" {
		matchers = append(matchers, "(NETWORK,"+strings.ToUpper(rule.Network)+")")
	}
	if rule.DestinationPort != 0 {
		matchers = append(matchers, "(DST-PORT,"+strconv.Itoa(rule.DestinationPort)+")")
	}
	target := strings.ToUpper(rule.Action)
	if len(matchers) == 1 {
		matcher := strings.TrimSuffix(strings.TrimPrefix(matchers[0], "("), ")")
		parts := strings.Split(matcher, ",")
		if len(parts) >= 2 {
			if parts[0] == "OR" {
				return matcher + "," + target
			}
			if strings.HasPrefix(parts[0], "IP-CIDR") {
				return parts[0] + "," + parts[1] + "," + target + ",no-resolve"
			}
			return matcher + "," + target
		}
	}
	return "AND,(" + strings.Join(matchers, ",") + ")," + target
}

func interceptModuleEgressSelectors(module interceptModuleSnapshot) []interceptEgressSelector {
	selectors := make([]interceptEgressSelector, 0, len(module.CaptureHosts)*2+len(module.NetworkOrigins)+len(module.HostMappings)*2)
	selectors = append(selectors, interceptModuleCaptureSelectors(module)...)
	for _, origin := range module.NetworkOrigins {
		host, port, err := interceptNetworkOriginHostPort(origin)
		if err == nil {
			selectors = append(selectors, interceptEgressSelector{Kind: "DOMAIN", Value: host, Port: port})
		}
	}
	for _, mapping := range module.HostMappings {
		kind, target := "DOMAIN", strings.ToLower(strings.TrimSuffix(mapping.Target, "."))
		if ip := net.ParseIP(target); ip != nil && ip.To4() != nil {
			kind, target = "IP-CIDR", ip.To4().String()+"/32"
		}
		selectors = append(selectors,
			interceptEgressSelector{Kind: kind, Value: target, Port: 80},
			interceptEgressSelector{Kind: kind, Value: target, Port: 443},
		)
	}
	sort.Slice(selectors, func(i, j int) bool {
		left := selectors[i].Kind + "\x00" + selectors[i].Value + "\x00" + fmt.Sprintf("%05d", selectors[i].Port)
		right := selectors[j].Kind + "\x00" + selectors[j].Value + "\x00" + fmt.Sprintf("%05d", selectors[j].Port)
		return left < right
	})
	return selectors
}

// interceptModuleCaptureSelectors compacts only an apex and its wildcard when
// the same extension owns both. DOMAIN-SUFFIX is exactly their mihomo union;
// compacting before selectors from different modules are combined preserves
// execution-order ownership and distinct egress targets.
func interceptModuleCaptureSelectors(module interceptModuleSnapshot) []interceptEgressSelector {
	hosts := make(map[string]struct{}, len(module.CaptureHosts))
	for _, host := range module.CaptureHosts {
		hosts[host] = struct{}{}
	}
	handled := make(map[string]struct{}, len(module.CaptureHosts))
	selectors := make([]interceptEgressSelector, 0, len(module.CaptureHosts)*2)
	for _, host := range module.CaptureHosts {
		if _, done := handled[host]; done {
			continue
		}
		kind, value := "DOMAIN", host
		base := host
		if strings.HasPrefix(host, "*.") {
			base = strings.TrimPrefix(host, "*.")
			kind = "DOMAIN-WILDCARD"
		}
		wildcard := "*." + base
		if _, hasApex := hosts[base]; hasApex {
			if _, hasWildcard := hosts[wildcard]; hasWildcard {
				kind, value = "DOMAIN-SUFFIX", base
				handled[base] = struct{}{}
				handled[wildcard] = struct{}{}
			}
		}
		if kind != "DOMAIN-SUFFIX" {
			handled[host] = struct{}{}
		}
		selectors = append(selectors,
			interceptEgressSelector{Kind: kind, Value: value, Port: 80},
			interceptEgressSelector{Kind: kind, Value: value, Port: 443},
		)
	}
	return selectors
}

func renderInterceptCaptureRule(selector interceptEgressSelector) string {
	return "AND,((" + selector.Kind + "," + selector.Value + "),(DST-PORT," + strconv.Itoa(selector.Port) + "))," + interceptMihomoProxyName
}

func renderInterceptEgressRule(selector interceptEgressSelector, target string) string {
	matcher := "(" + selector.Kind + "," + selector.Value
	if selector.Kind == "IP-CIDR" {
		matcher += ",no-resolve"
	}
	matcher += ")"
	return "AND,((IN-NAME,intercept-egress)," + matcher + ",(DST-PORT," + strconv.Itoa(selector.Port) + "))," + target
}

func analyzeInterceptRoutingDocument(text string, document interceptConfigDocument) interceptRoutingAnalysis {
	return analyzeInterceptRoutingExpected(text, interceptMihomoRouting(document))
}

func analyzeInterceptRoutingExpected(text string, expected interceptRoutingRules) interceptRoutingAnalysis {
	analysis := interceptRoutingAnalysis{Reason: "invalid-config"}
	document, err := parseMihomoNodeDocument(text)
	if err != nil || len(document.Content) != 1 || hasYAMLAliasOrMerge(document.Content[0]) {
		return analysis
	}
	root := document.Content[0]
	if !hasExactInterceptListener(mappingNodeValue(root, "listeners")) {
		analysis.Reason = "interception-listener-missing"
		return analysis
	}
	if !hasExactModuleProxy(mappingNodeValue(root, "proxies")) {
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
	availableSet := make(map[string]struct{}, len(available))
	for _, group := range available {
		availableSet[group] = struct{}{}
	}
	for _, rule := range expected.Egress {
		target, ok := interceptRuleTarget(rule)
		if !ok || target == interceptTerminalMatchTarget {
			continue
		}
		if _, exists := availableSet[target]; !exists {
			analysis.Reason = "egress-group-missing"
			return analysis
		}
	}
	expected = materializeInterceptRoutingRules(expected, matchTarget)

	rejectIndex := -1
	currentCapture := make([]string, 0, len(expected.Capture))
	captureIndices := make([]int, 0, len(expected.Capture))
	currentEgress := make([]string, 0, len(expected.Egress))
	egressIndices := make([]int, 0, len(expected.Egress))
	for index, item := range rules.Content {
		if item.Kind != yaml.ScalarNode {
			analysis.Reason = "rules-structure-conflict"
			return analysis
		}
		rawRule := strings.TrimSpace(item.Value)
		compact := compactMihomoRule(item.Value)
		if rawRule == interceptEgressRejectRule {
			if rejectIndex != -1 {
				analysis.Reason = "interception-egress-terminator-duplicate"
				return analysis
			}
			rejectIndex = index
			continue
		}
		if ruleTouchesInterceptEgress(rawRule) {
			if _, _, ok := parseCanonicalInterceptEgressRule(rawRule); !ok {
				analysis.Reason = "interception-egress-rules-out-of-sync"
				return analysis
			}
			currentEgress = append(currentEgress, rawRule)
			egressIndices = append(egressIndices, index)
		}
		if strings.HasSuffix(compact, ","+interceptMihomoProxyName) {
			currentCapture = append(currentCapture, compact)
			captureIndices = append(captureIndices, index)
		}
	}
	if rejectIndex < 0 || rejectIndex >= matchIndex {
		analysis.Reason = "interception-egress-terminator-missing"
		return analysis
	}
	egressStart := rejectIndex - len(currentEgress)
	for index := range currentEgress {
		if egressIndices[index] != egressStart+index {
			analysis.Reason = "interception-egress-rules-out-of-sync"
			return analysis
		}
	}
	moduleStart := rejectIndex + 1
	if moduleStart < matchIndex && rules.Content[moduleStart].Kind == yaml.ScalarNode &&
		matchesDenyRule(compactMihomoRule(rules.Content[moduleStart].Value), blockQUICRuleBase, false) {
		moduleStart++
	}
	policyStart := moduleStart
	policyCount := matchIndex - policyStart - len(currentCapture)
	if policyCount < 0 || policyCount > len(expected.Policy) {
		analysis.Reason = "interception-policy-rules-out-of-sync"
		return analysis
	}
	currentPolicy := make([]string, 0, policyCount)
	for index := 0; index < policyCount; index++ {
		item := rules.Content[policyStart+index]
		if item.Kind != yaml.ScalarNode {
			analysis.Reason = "interception-policy-rules-out-of-sync"
			return analysis
		}
		currentPolicy = append(currentPolicy, compactMihomoRule(item.Value))
		if currentPolicy[index] != compactMihomoRule(expected.Policy[index]) {
			analysis.Reason = "interception-policy-rules-out-of-sync"
			return analysis
		}
	}
	moduleStart += policyCount
	analysis.Document = document
	analysis.Rules = rules
	analysis.EgressInsertAt = egressStart
	analysis.MatchTarget = matchTarget
	analysis.AvailableEgressGroups = available
	analysis.PolicyStart = policyStart
	analysis.PolicyCount = policyCount
	seenCurrent := make(map[string]struct{}, len(currentCapture))
	for index, rule := range currentCapture {
		if captureIndices[index] != moduleStart+index || !validCanonicalInterceptRule(rule) {
			analysis.Reason = "interception-rules-out-of-sync"
			return analysis
		}
		if _, duplicate := seenCurrent[rule]; duplicate {
			analysis.Reason = "interception-rules-out-of-sync"
			return analysis
		}
		seenCurrent[rule] = struct{}{}
		if index > 0 && currentCapture[index-1] > rule {
			analysis.Reason = "interception-rules-out-of-sync"
			return analysis
		}
	}
	if moduleStart+len(currentCapture) != matchIndex {
		analysis.Reason = "interception-rules-out-of-sync"
		return analysis
	}
	seenSelectors := make(map[string]struct{}, len(currentEgress))
	for _, rule := range currentEgress {
		selector, _, ok := parseCanonicalInterceptEgressRule(rule)
		if !ok {
			analysis.Reason = "interception-egress-rules-out-of-sync"
			return analysis
		}
		identity := selector.Kind + "\x00" + selector.Value + "\x00" + strconv.Itoa(selector.Port)
		if _, duplicate := seenSelectors[identity]; duplicate {
			analysis.Reason = "interception-egress-rules-out-of-sync"
			return analysis
		}
		seenSelectors[identity] = struct{}{}
	}
	if !interceptRuleOrderedSubset(currentEgress, expected.Egress) {
		analysis.Reason = "interception-egress-rules-out-of-sync"
		return analysis
	}
	if !interceptRuleOrderedSubset(currentCapture, expected.Capture) {
		analysis.Reason = "interception-rules-out-of-sync"
		return analysis
	}
	analysis.Reconcileable = true
	if len(currentCapture) != len(expected.Capture) {
		analysis.Reason = "interception-rules-out-of-sync"
		return analysis
	}
	for index := range expected.Capture {
		if currentCapture[index] != expected.Capture[index] || captureIndices[index] != moduleStart+index {
			analysis.Reason = "interception-rules-out-of-sync"
			return analysis
		}
	}
	if len(currentPolicy) != len(expected.Policy) {
		analysis.Reason = "interception-policy-rules-out-of-sync"
		return analysis
	}
	if len(currentEgress) != len(expected.Egress) {
		analysis.Reason = "interception-egress-rules-out-of-sync"
		return analysis
	}
	for index := range expected.Egress {
		if currentEgress[index] != expected.Egress[index] {
			analysis.Reason = "interception-egress-rules-out-of-sync"
			return analysis
		}
	}
	analysis.Manageable = true
	analysis.Ready = true
	analysis.Reason = ""
	return analysis
}

func renderInterceptRoutingDocument(analysis interceptRoutingAnalysis, document interceptConfigDocument) (string, error) {
	next := interceptMihomoRouting(document)
	available := make(map[string]struct{}, len(analysis.AvailableEgressGroups))
	for _, group := range analysis.AvailableEgressGroups {
		available[group] = struct{}{}
	}
	for _, rule := range next.Egress {
		target, ok := interceptRuleTarget(rule)
		if ok && target != interceptTerminalMatchTarget {
			if _, exists := available[target]; !exists {
				return "", fmt.Errorf("interception egress group %q does not exist", target)
			}
		}
	}
	return renderInterceptRoutingRules(analysis, materializeInterceptRoutingRules(next, analysis.MatchTarget))
}

func renderInterceptRoutingRules(analysis interceptRoutingAnalysis, next interceptRoutingRules) (string, error) {
	if !analysis.Reconcileable || analysis.Document == nil || analysis.Rules == nil {
		return "", errors.New("interception routing is not manageable")
	}
	kept := make([]*yaml.Node, 0, len(analysis.Rules.Content))
	for index, item := range analysis.Rules.Content {
		rawRule := strings.TrimSpace(item.Value)
		compact := compactMihomoRule(item.Value)
		if rawRule == interceptEgressRejectRule || ruleTouchesInterceptEgress(rawRule) || strings.HasSuffix(compact, ","+interceptMihomoProxyName) ||
			(index >= analysis.PolicyStart && index < analysis.PolicyStart+analysis.PolicyCount) {
			continue
		}
		kept = append(kept, item)
	}
	analysis.Rules.Content = kept
	egressNodes := make([]*yaml.Node, 0, len(next.Egress)+1)
	for _, rule := range next.Egress {
		egressNodes = append(egressNodes, scalarNode(rule))
	}
	egressNodes = append(egressNodes, scalarNode(interceptEgressRejectRule))
	analysis.Rules.Content = insertNodes(analysis.Rules.Content, analysis.EgressInsertAt, egressNodes...)

	captureInsertAt := analysis.EgressInsertAt + len(egressNodes)
	if captureInsertAt < len(analysis.Rules.Content) && matchesDenyRule(compactMihomoRule(analysis.Rules.Content[captureInsertAt].Value), blockQUICRuleBase, false) {
		captureInsertAt++
	}
	policyNodes := make([]*yaml.Node, 0, len(next.Policy))
	for _, rule := range next.Policy {
		policyNodes = append(policyNodes, scalarNode(rule))
	}
	analysis.Rules.Content = insertNodes(analysis.Rules.Content, captureInsertAt, policyNodes...)
	captureInsertAt += len(policyNodes)
	nodes := make([]*yaml.Node, 0, len(next.Capture))
	for _, rule := range uniqueSortedStrings(next.Capture) {
		nodes = append(nodes, scalarNode(rule))
	}
	analysis.Rules.Content = insertNodes(analysis.Rules.Content, captureInsertAt, nodes...)
	return encodeMihomoNode(analysis.Document)
}

func materializeInterceptRoutingRules(rules interceptRoutingRules, matchTarget string) interceptRoutingRules {
	out := interceptRoutingRules{Capture: append([]string(nil), rules.Capture...), Egress: append([]string(nil), rules.Egress...), Policy: append([]string(nil), rules.Policy...)}
	for index, rule := range out.Egress {
		if target, ok := interceptRuleTarget(rule); ok && target == interceptTerminalMatchTarget {
			out.Egress[index] = strings.TrimSuffix(rule, ","+interceptTerminalMatchTarget) + "," + matchTarget
		}
	}
	return out
}

func ruleTouchesInterceptEgress(rule string) bool {
	return strings.HasPrefix(rule, "IN-NAME,intercept-egress,") || strings.Contains(rule, "(IN-NAME,intercept-egress)")
}

func interceptRuleTarget(rule string) (string, bool) {
	index := strings.LastIndex(rule, ")),")
	if index < 0 || index+3 >= len(rule) {
		return "", false
	}
	target := rule[index+3:]
	if target != interceptTerminalMatchTarget && validateInterceptEgressGroupBinding(target) != nil {
		return "", false
	}
	return target, target != ""
}

func parseCanonicalInterceptEgressRule(rule string) (interceptEgressSelector, string, bool) {
	const prefix = "AND,((IN-NAME,intercept-egress),("
	if !strings.HasPrefix(rule, prefix) {
		return interceptEgressSelector{}, "", false
	}
	target, ok := interceptRuleTarget(rule)
	if !ok {
		return interceptEgressSelector{}, "", false
	}
	body := strings.TrimSuffix(strings.TrimPrefix(rule, prefix), ","+target)
	portMarker := "),(DST-PORT,"
	portAt := strings.LastIndex(body, portMarker)
	if portAt < 0 || !strings.HasSuffix(body, "))") {
		return interceptEgressSelector{}, "", false
	}
	matcher := body[:portAt]
	portText := strings.TrimSuffix(body[portAt+len(portMarker):], "))")
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 || strconv.Itoa(port) != portText {
		return interceptEgressSelector{}, "", false
	}
	selector := interceptEgressSelector{Port: port}
	switch {
	case strings.HasPrefix(matcher, "DOMAIN,"):
		selector.Kind, selector.Value = "DOMAIN", strings.TrimPrefix(matcher, "DOMAIN,")
		if strings.HasPrefix(selector.Value, "*.") || validateInterceptHostPattern(selector.Value) != nil {
			return interceptEgressSelector{}, "", false
		}
	case strings.HasPrefix(matcher, "DOMAIN-WILDCARD,"):
		selector.Kind, selector.Value = "DOMAIN-WILDCARD", strings.TrimPrefix(matcher, "DOMAIN-WILDCARD,")
		if !strings.HasPrefix(selector.Value, "*.") || validateInterceptHostPattern(selector.Value) != nil {
			return interceptEgressSelector{}, "", false
		}
	case strings.HasPrefix(matcher, "DOMAIN-SUFFIX,"):
		selector.Kind, selector.Value = "DOMAIN-SUFFIX", strings.TrimPrefix(matcher, "DOMAIN-SUFFIX,")
		if strings.HasPrefix(selector.Value, "*.") || validateInterceptHostPattern(selector.Value) != nil {
			return interceptEgressSelector{}, "", false
		}
	case strings.HasPrefix(matcher, "IP-CIDR,") && strings.HasSuffix(matcher, ",no-resolve"):
		selector.Kind = "IP-CIDR"
		selector.Value = strings.TrimSuffix(strings.TrimPrefix(matcher, "IP-CIDR,"), ",no-resolve")
		ipText := strings.TrimSuffix(selector.Value, "/32")
		ip := net.ParseIP(ipText)
		if !strings.HasSuffix(selector.Value, "/32") || ip == nil || ip.To4() == nil || ip.To4().String() != ipText {
			return interceptEgressSelector{}, "", false
		}
	default:
		return interceptEgressSelector{}, "", false
	}
	if renderInterceptEgressRule(selector, target) != rule {
		return interceptEgressSelector{}, "", false
	}
	return selector, target, true
}

func interceptAvailableEgressGroups(text string) ([]string, error) {
	document, err := parseMihomoNodeDocument(text)
	if err != nil || len(document.Content) != 1 || hasYAMLAliasOrMerge(document.Content[0]) {
		if err == nil {
			err = errors.New("mihomo YAML is not a canonical single document")
		}
		return nil, err
	}
	return interceptAvailableEgressGroupsNode(document.Content[0])
}

func interceptAvailableEgressGroupsNode(root *yaml.Node) ([]string, error) {
	groups := []string{"DIRECT"}
	seen := map[string]struct{}{"DIRECT": {}}
	node := mappingNodeValue(root, "proxy-groups")
	if node == nil {
		return groups, nil
	}
	if node.Kind != yaml.SequenceNode {
		return nil, errors.New("proxy-groups must be a sequence")
	}
	for index, item := range node.Content {
		name, ok := mappingScalar(item, "name")
		if !ok || validateInterceptEgressGroupBinding(name) != nil || name == "" {
			return nil, fmt.Errorf("proxy group %d has an invalid name", index)
		}
		if _, duplicate := seen[name]; duplicate {
			return nil, fmt.Errorf("duplicate proxy group name %q", name)
		}
		seen[name] = struct{}{}
		groups = append(groups, name)
	}
	sort.Strings(groups[1:])
	return groups, nil
}

func validCanonicalInterceptRule(rule string) bool {
	for _, port := range []string{"80", "443"} {
		suffix := "),(DST-PORT," + port + "))," + interceptMihomoProxyName
		for kind, prefix := range map[string]string{
			"DOMAIN":          "AND,((DOMAIN,",
			"DOMAIN-SUFFIX":   "AND,((DOMAIN-SUFFIX,",
			"DOMAIN-WILDCARD": "AND,((DOMAIN-WILDCARD,",
		} {
			if !strings.HasPrefix(rule, prefix) || !strings.HasSuffix(rule, suffix) {
				continue
			}
			host := strings.TrimSuffix(strings.TrimPrefix(rule, prefix), suffix)
			if validateInterceptHostPattern(host) != nil {
				return false
			}
			if kind == "DOMAIN-WILDCARD" {
				return strings.HasPrefix(host, "*.")
			}
			return !strings.HasPrefix(host, "*.")
		}
	}
	return false
}

func interceptRuleOrderedSubset(current, allowed []string) bool {
	allowedIndex := 0
	for _, rule := range current {
		for allowedIndex < len(allowed) && allowed[allowedIndex] != rule {
			allowedIndex++
		}
		if allowedIndex == len(allowed) {
			return false
		}
		allowedIndex++
	}
	return true
}

func hasExactInterceptListener(listeners *yaml.Node) bool {
	if listeners == nil || listeners.Kind != yaml.SequenceNode {
		return false
	}
	found := 0
	for _, item := range listeners.Content {
		name, _ := mappingScalar(item, "name")
		if name != "intercept-egress" {
			continue
		}
		found++
		if !exactMappingKeys(item, "name", "type", "listen", "port", "udp", "users") {
			return false
		}
		typeName, typeOK := mappingScalar(item, "type")
		listen, listenOK := mappingScalar(item, "listen")
		port, portOK := yamlInteger(mappingNodeValue(item, "port"))
		udp := mappingNodeValue(item, "udp")
		users := mappingNodeValue(item, "users")
		if !typeOK || typeName != "mixed" || !listenOK || listen != "127.0.0.1" || !portOK || port != 17890 ||
			udp == nil || udp.Kind != yaml.ScalarNode || udp.Tag != "!!bool" || udp.Value != "true" ||
			users == nil || users.Kind != yaml.SequenceNode || len(users.Content) != 1 {
			return false
		}
		user := users.Content[0]
		if !exactMappingKeys(user, "username", "password") || !validInterceptCredentials(user) {
			return false
		}
	}
	return found == 1
}

func hasExactModuleProxy(proxies *yaml.Node) bool {
	if proxies == nil || proxies.Kind != yaml.SequenceNode {
		return false
	}
	found := 0
	for _, item := range proxies.Content {
		name, _ := mappingScalar(item, "name")
		if name != interceptMihomoProxyName {
			continue
		}
		found++
		if !exactMappingKeys(item, "name", "type", "server", "port", "username", "password", "udp") {
			return false
		}
		typeName, typeOK := mappingScalar(item, "type")
		server, serverOK := mappingScalar(item, "server")
		port, portOK := yamlInteger(mappingNodeValue(item, "port"))
		udp := mappingNodeValue(item, "udp")
		if !typeOK || typeName != "socks5" || !serverOK || server != "127.0.0.1" || !portOK || port != 18080 ||
			udp == nil || udp.Kind != yaml.ScalarNode || udp.Tag != "!!bool" || udp.Value != "true" || !validInterceptCredentials(item) {
			return false
		}
	}
	return found == 1
}

func validInterceptCredentials(node *yaml.Node) bool {
	username, usernameOK := mappingScalar(node, "username")
	password, passwordOK := mappingScalar(node, "password")
	return usernameOK && passwordOK && len(username) >= 16 && len(username) <= 255 &&
		len(password) >= 24 && len(password) <= 255 && safeInterceptCredential.MatchString(username) && safeInterceptCredential.MatchString(password)
}

func terminalMatchRule(rules *yaml.Node) (int, string, bool) {
	matchIndex := -1
	target := ""
	for index, item := range rules.Content {
		if item.Kind != yaml.ScalarNode {
			return 0, "", false
		}
		raw := strings.TrimSpace(item.Value)
		kind, candidate, found := strings.Cut(raw, ",")
		if found && strings.TrimSpace(kind) == "MATCH" {
			candidate = strings.TrimSpace(candidate)
			if matchIndex != -1 || index != len(rules.Content)-1 || strings.Contains(candidate, ",") || validateInterceptEgressGroupBinding(candidate) != nil || candidate == "" {
				return 0, "", false
			}
			matchIndex, target = index, candidate
		}
	}
	return matchIndex, target, matchIndex >= 0
}

func interceptCredentialsMatch(text string, document interceptConfigDocument) bool {
	doc, err := parseMihomoNodeDocument(text)
	if err != nil || len(doc.Content) != 1 {
		return false
	}
	root := doc.Content[0]
	listenerUser, listenerPass := "", ""
	listeners := mappingNodeValue(root, "listeners")
	if listeners != nil && listeners.Kind == yaml.SequenceNode {
		for _, item := range listeners.Content {
			name, _ := mappingScalar(item, "name")
			if name != "intercept-egress" {
				continue
			}
			users := mappingNodeValue(item, "users")
			if users != nil && users.Kind == yaml.SequenceNode && len(users.Content) == 1 {
				listenerUser, _ = mappingScalar(users.Content[0], "username")
				listenerPass, _ = mappingScalar(users.Content[0], "password")
			}
		}
	}
	proxyUser, proxyPass := "", ""
	proxies := mappingNodeValue(root, "proxies")
	if proxies != nil && proxies.Kind == yaml.SequenceNode {
		for _, item := range proxies.Content {
			name, _ := mappingScalar(item, "name")
			if name == interceptMihomoProxyName {
				proxyUser, _ = mappingScalar(item, "username")
				proxyPass, _ = mappingScalar(item, "password")
			}
		}
	}
	return proxyUser == document.Username && proxyPass == document.Password &&
		listenerUser == document.UpstreamProxy.Username && listenerPass == document.UpstreamProxy.Password
}
