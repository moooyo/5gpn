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

func interceptModuleEgressSelectors(module interceptModuleSnapshot) []interceptEgressSelector {
	// Capture hosts and mappings are the whole selector set. The network grant
	// used to contribute one DOMAIN selector per declared origin; it names no
	// origins now, so it contributes nothing here -- and the transport layer
	// still needs an enumerated allowlist, which is the open problem recorded in
	// docs/native-extensions.md.
	selectors := make([]interceptEgressSelector, 0, len(module.CaptureHosts)*2+len(module.HostMappings)*2)
	selectors = append(selectors, interceptModuleCaptureSelectors(module)...)
	for _, mapping := range module.HostMappings {
		// The resolver form names nameservers, not a destination. 5gpn-dns
		// dials those itself; the extension's egress never reaches them, and
		// turning "server:1.1.1.1" into a domain selector would authorize a
		// destination that does not exist.
		if len(mapping.hostMappingServers()) > 0 {
			continue
		}
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

// ruleTouchesInterceptEgress reports whether a rule belongs to the reserved
// egress block.
//
// The negative form is deliberately excluded. A panel guard qualified as
// `AND,((NOT,((IN-NAME,intercept-egress))),…)` mentions the listener precisely
// in order to keep processor traffic away from itself — it is the opposite of
// an owned egress rule, and classifying it as one would make the manager filter
// out the operator's own console and dashboard routes on every routing change.
func ruleTouchesInterceptEgress(rule string) bool {
	if strings.Contains(rule, interceptEgressNegativeQualifier) {
		return false
	}
	return strings.HasPrefix(rule, "IN-NAME,intercept-egress,") || strings.Contains(rule, "(IN-NAME,intercept-egress)")
}

// interceptEgressNegativeQualifier is the exact compacted spelling of the
// exclusion a panel guard carries.
const interceptEgressNegativeQualifier = "(NOT,((IN-NAME,intercept-egress)))"

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
	return hasExactModuleProxyForm(proxies, false)
}

// hasExactModuleProxyOverlay additionally requires the processor declaration.
//
// Under the overlay that key is not decoration: a generation's capture rules
// name a processor target, and the core refuses to stage one naming an outbound
// that has not declared itself as such. Accepting a config without it here
// would let the gateway believe it is managing an arrangement that can never
// commit anything.
func hasExactModuleProxyOverlay(proxies *yaml.Node) bool {
	return hasExactModuleProxyForm(proxies, true)
}

func hasExactModuleProxyForm(proxies *yaml.Node, overlay bool) bool {
	if proxies == nil || proxies.Kind != yaml.SequenceNode {
		return false
	}
	base := []string{"name", "type", "server", "port", "username", "password", "udp"}
	withProcessor := append(append([]string(nil), base...), overlayProcessorProxyKey)
	found := 0
	for _, item := range proxies.Content {
		name, _ := mappingScalar(item, "name")
		if name != interceptMihomoProxyName {
			continue
		}
		found++
		// The processor declaration is required under the overlay and merely
		// tolerated without it: a core with no overlay configured ignores the
		// key, so rejecting a config that carries it would break a gateway that
		// is simply prepared to migrate.
		if overlay {
			if !exactMappingKeys(item, withProcessor...) {
				return false
			}
		} else if !exactMappingKeys(item, base...) && !exactMappingKeys(item, withProcessor...) {
			return false
		}
		if overlay {
			flag := mappingNodeValue(item, overlayProcessorProxyKey)
			if flag == nil || flag.Kind != yaml.ScalarNode || flag.Tag != "!!bool" || flag.Value != "true" {
				return false
			}
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
