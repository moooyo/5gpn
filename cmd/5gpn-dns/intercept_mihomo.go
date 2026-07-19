package main

import (
	"errors"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

const interceptMihomoProxyName = "MODULE-MITM"

var safeInterceptCredential = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

type interceptRoutingAnalysis struct {
	Manageable    bool
	Reconcileable bool
	Ready         bool
	Reason        string
	Document      *yaml.Node
	Rules         *yaml.Node
	InsertAt      int
	Current       []string
}

func interceptMihomoRules(document interceptConfigDocument) []string {
	if !document.MITM.Enabled {
		return nil
	}
	rules := make([]string, 0, len(activeInterceptHosts(document))*2)
	appendRule := func(host, port string) {
		kind := "DOMAIN"
		if strings.HasPrefix(host, "*.") {
			kind = "DOMAIN-WILDCARD"
		}
		rules = append(rules, "AND,(("+kind+","+host+"),(DST-PORT,"+port+")),"+interceptMihomoProxyName)
	}
	if document.WLOC.Enabled {
		for _, host := range builtInWLOCHosts {
			appendRule(host, "443")
		}
	}
	for _, module := range document.Modules {
		if !module.Enabled {
			continue
		}
		for _, host := range module.Hosts {
			for _, port := range []string{"80", "443"} {
				appendRule(host, port)
			}
		}
	}
	sort.Strings(rules)
	return rules
}

func analyzeInterceptRouting(text string, expected []string) interceptRoutingAnalysis {
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
	bypass := "IN-NAME,intercept-egress," + matchTarget
	bypassIndex := -1
	current := make([]string, 0, len(expected))
	indices := make([]int, 0, len(expected))
	for index, item := range rules.Content {
		if item.Kind != yaml.ScalarNode {
			analysis.Reason = "rules-structure-conflict"
			return analysis
		}
		compact := compactMihomoRule(item.Value)
		if compact == bypass {
			if bypassIndex != -1 {
				analysis.Reason = "interception-bypass-duplicate"
				return analysis
			}
			bypassIndex = index
		}
		if strings.HasSuffix(compact, ","+interceptMihomoProxyName) {
			current = append(current, compact)
			indices = append(indices, index)
		}
	}
	if bypassIndex < 0 || bypassIndex >= matchIndex {
		analysis.Reason = "interception-bypass-missing"
		return analysis
	}
	moduleStart := bypassIndex + 1
	if moduleStart < matchIndex && rules.Content[moduleStart].Kind == yaml.ScalarNode &&
		matchesDenyRule(compactMihomoRule(rules.Content[moduleStart].Value), blockQUICRuleBase, false) {
		moduleStart++
	}
	expected = append([]string(nil), expected...)
	sort.Strings(expected)
	analysis.Document = document
	analysis.Rules = rules
	analysis.InsertAt = moduleStart
	analysis.Current = current
	seenCurrent := make(map[string]struct{}, len(current))
	for index, rule := range current {
		if indices[index] != moduleStart+index || !validCanonicalInterceptRule(rule) {
			analysis.Reason = "interception-rules-out-of-sync"
			return analysis
		}
		if _, duplicate := seenCurrent[rule]; duplicate {
			analysis.Reason = "interception-rules-out-of-sync"
			return analysis
		}
		seenCurrent[rule] = struct{}{}
		if index > 0 && current[index-1] > rule {
			analysis.Reason = "interception-rules-out-of-sync"
			return analysis
		}
	}
	analysis.Reconcileable = true
	if len(current) != len(expected) {
		analysis.Reason = "interception-rules-out-of-sync"
		return analysis
	}
	for index := range expected {
		if current[index] != expected[index] || indices[index] != moduleStart+index {
			analysis.Reason = "interception-rules-out-of-sync"
			return analysis
		}
	}
	analysis.Manageable = true
	analysis.Ready = true
	analysis.Reason = ""
	return analysis
}

func renderInterceptRouting(analysis interceptRoutingAnalysis, nextRules []string) (string, error) {
	if !analysis.Reconcileable || analysis.Document == nil || analysis.Rules == nil {
		return "", errors.New("interception routing is not manageable")
	}
	kept := analysis.Rules.Content[:0]
	for _, item := range analysis.Rules.Content {
		if strings.HasSuffix(compactMihomoRule(item.Value), ","+interceptMihomoProxyName) {
			continue
		}
		kept = append(kept, item)
	}
	analysis.Rules.Content = kept
	nextRules = append([]string(nil), nextRules...)
	sort.Strings(nextRules)
	nodes := make([]*yaml.Node, 0, len(nextRules))
	for _, rule := range nextRules {
		nodes = append(nodes, scalarNode(rule))
	}
	analysis.Rules.Content = insertNodes(analysis.Rules.Content, analysis.InsertAt, nodes...)
	return encodeMihomoNode(analysis.Document)
}

func validCanonicalInterceptRule(rule string) bool {
	for _, port := range []string{"80", "443"} {
		suffix := "),(DST-PORT," + port + "))," + interceptMihomoProxyName
		for kind, prefix := range map[string]string{
			"DOMAIN":          "AND,((DOMAIN,",
			"DOMAIN-WILDCARD": "AND,((DOMAIN-WILDCARD,",
		} {
			if !strings.HasPrefix(rule, prefix) || !strings.HasSuffix(rule, suffix) {
				continue
			}
			host := strings.TrimSuffix(strings.TrimPrefix(rule, prefix), suffix)
			if validateInterceptHostPattern(host) != nil {
				return false
			}
			return (kind == "DOMAIN-WILDCARD") == strings.HasPrefix(host, "*.")
		}
	}
	return false
}

func interceptRuleSubset(current, allowed []string) bool {
	set := make(map[string]struct{}, len(allowed))
	for _, rule := range allowed {
		set[rule] = struct{}{}
	}
	for _, rule := range current {
		if _, ok := set[rule]; !ok {
			return false
		}
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
		parts := strings.Split(compactMihomoRule(item.Value), ",")
		if len(parts) == 2 && parts[0] == "MATCH" {
			if matchIndex != -1 || index != len(rules.Content)-1 || parts[1] == "" {
				return 0, "", false
			}
			matchIndex, target = index, parts[1]
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
