package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	speedtestModuleID   = "speedtest-5060"
	speedtestModulePort = 5060
	mihomoRollbackLimit = 10 * time.Second
)

var canonicalGatewayName = regexp.MustCompile(`^gateway(?:-([2-9][0-9]*))?$`)

type mihomoIngressModuleView struct {
	ID         string   `json:"id"`
	Enabled    bool     `json:"enabled"`
	Manageable bool     `json:"manageable"`
	Reason     string   `json:"reason,omitempty"`
	Port       int      `json:"port"`
	Networks   []string `json:"networks"`
	Sniffers   []string `json:"sniffers"`
}

type mihomoIngressModulesResponse struct {
	Revision string                    `json:"revision"`
	Modules  []mihomoIngressModuleView `json:"modules"`
}

type mihomoIngressModuleUpdate struct {
	Enabled  *bool  `json:"enabled"`
	Revision string `json:"revision"`
}

type gatewayBind struct {
	Name   string
	Suffix string
	Listen string
}

type speedtestModuleAnalysis struct {
	View          mihomoIngressModuleView
	Document      *yaml.Node
	Listeners     *yaml.Node
	SniffPorts    map[string]*yaml.Node
	Rules         *yaml.Node
	GuardBoundary int
	ModuleRules   []string
	Gateways      []gatewayBind
}

func speedtestModuleView(enabled, manageable bool, reason string) mihomoIngressModuleView {
	return mihomoIngressModuleView{
		ID:         speedtestModuleID,
		Enabled:    enabled,
		Manageable: manageable,
		Reason:     reason,
		Port:       speedtestModulePort,
		Networks:   []string{"tcp", "udp"},
		Sniffers:   []string{"http", "tls", "quic"},
	}
}

func ingressModulesResponse(text string, infra InfraParams) mihomoIngressModulesResponse {
	analysis := analyzeSpeedtestModule(text, infra)
	return mihomoIngressModulesResponse{
		Revision: mihomoConfigRevision(text),
		Modules:  []mihomoIngressModuleView{analysis.View},
	}
}

func (s *ControlServer) handleMihomoIngressModulesGet(w http.ResponseWriter, _ *http.Request) {
	if s.mihomoStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo config management unavailable")
		return
	}
	s.mihomoStore.Lock()
	text, err := s.mihomoStore.Read()
	s.mihomoStore.Unlock()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, ingressModulesResponse(text, s.mihomoInfra))
}

func (s *ControlServer) handleMihomoIngressModulePut(w http.ResponseWriter, r *http.Request) {
	if s.mihomoStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo config management unavailable")
		return
	}
	if r.PathValue("id") != speedtestModuleID {
		writeErr(w, http.StatusNotFound, "unknown mihomo ingress module")
		return
	}

	var body mihomoIngressModuleUpdate
	if !decodeJSONBody(w, r, &body) {
		return
	}
	if body.Enabled == nil || !validMihomoConfigRevision(body.Revision) {
		writeErr(w, http.StatusBadRequest, "enabled and a valid revision are required")
		return
	}

	s.mihomoStore.Lock()
	defer s.mihomoStore.Unlock()

	oldText, err := s.mihomoStore.Read()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	current := ingressModulesResponse(oldText, s.mihomoInfra)
	if body.Revision != current.Revision {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":    "mihomo config revision changed",
			"revision": current.Revision,
			"modules":  current.Modules,
		})
		return
	}

	analysis := analyzeSpeedtestModule(oldText, s.mihomoInfra)
	if !analysis.View.Manageable {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":    "mihomo ingress module conflicts with the operator config",
			"revision": current.Revision,
			"modules":  current.Modules,
		})
		return
	}
	if analysis.View.Enabled == *body.Enabled {
		writeJSON(w, http.StatusOK, current)
		return
	}

	candidate, err := renderSpeedtestModule(analysis, *body.Enabled)
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":    err.Error(),
			"revision": current.Revision,
			"modules":  current.Modules,
		})
		return
	}
	candidateAnalysis := analyzeSpeedtestModule(candidate, s.mihomoInfra)
	if !candidateAnalysis.View.Manageable || candidateAnalysis.View.Enabled != *body.Enabled {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"error":    "rendered mihomo ingress module failed structural verification",
			"revision": current.Revision,
			"modules":  current.Modules,
		})
		return
	}

	status, resp, written := s.applyMihomoConfigLockedCAS(r.Context(), candidate, true, body.Revision)
	if status == http.StatusOK {
		writeJSON(w, status, ingressModulesResponse(candidate, s.mihomoInfra))
		return
	}
	if !written {
		writeJSON(w, status, resp)
		return
	}

	rollback := s.rollbackMihomoConfigLocked([]byte(oldText))
	latestText, readErr := s.mihomoStore.Read()
	if readErr != nil {
		latestText = candidate
	}
	errorText, _ := resp["error"].(string)
	diskRestored, _ := rollback["disk_restored"].(bool)
	controllerRestored, _ := rollback["controller_restored"].(bool)
	rollbackComplete := diskRestored && controllerRestored
	resultError := fmt.Sprintf("mihomo ingress module hot-apply failed; rollback incomplete: %s", errorText)
	if rollbackComplete {
		resultError = fmt.Sprintf("mihomo ingress module hot-apply failed; previous config restored: %s", errorText)
	}
	result := map[string]any{
		"error":               resultError,
		"candidate_published": true,
		"rollback_complete":   rollbackComplete,
		"rollback":            rollback,
		"revision":            mihomoConfigRevision(latestText),
		"modules":             ingressModulesResponse(latestText, s.mihomoInfra).Modules,
	}
	if readErr != nil {
		result["state_read_error"] = readErr.Error()
	}
	writeJSON(w, http.StatusBadGateway, result)
}

func (s *ControlServer) rollbackMihomoConfigLocked(oldBytes []byte) map[string]any {
	result := map[string]any{
		"disk_restored":                false,
		"controller_restore_attempted": false,
		"controller_restored":          false,
	}
	if err := atomicWriteFile(s.mihomoStore.Path(), oldBytes, 0o660); err != nil {
		result["error"] = fmt.Sprintf("restore previous config on disk: %v", err)
		return result
	}
	result["disk_restored"] = true
	if s.mihomoCtl == nil {
		result["controller_restored"] = true
		return result
	}
	result["controller_restore_attempted"] = true
	ctx, cancel := context.WithTimeout(context.Background(), mihomoRollbackLimit)
	defer cancel()
	if err := s.mihomoCtl.PutConfigs(ctx, s.mihomoStore.Path()); err != nil {
		result["error"] = fmt.Sprintf("previous config restored on disk but controller restore failed: %v", err)
		return result
	}
	result["controller_restored"] = true
	return result
}

func analyzeSpeedtestModule(text string, infra InfraParams) speedtestModuleAnalysis {
	analysis := speedtestModuleAnalysis{View: speedtestModuleView(false, false, "invalid-config")}
	if err := ValidateInvariants(text, infra); err != nil {
		return analysis
	}
	doc, err := parseMihomoNodeDocument(text)
	if err != nil {
		return analysis
	}
	analysis.Document = doc
	root := doc.Content[0]
	if hasYAMLAliasOrMerge(root) {
		analysis.View.Reason = "alias-or-merge-conflict"
		return analysis
	}

	listeners := mappingNodeValue(root, "listeners")
	if listeners == nil || listeners.Kind != yaml.SequenceNode {
		analysis.View.Reason = "listener-structure-conflict"
		return analysis
	}
	analysis.Listeners = listeners
	gateways, err := canonicalGatewayBinds(listeners)
	if err != nil {
		analysis.View.Reason = "canonical-gateway-conflict"
		return analysis
	}
	if len(gateways) == 0 {
		analysis.View.Reason = "canonical-gateway-missing"
		return analysis
	}
	analysis.Gateways = gateways

	sniffPorts, err := canonicalSniffPortNodes(root)
	if err != nil {
		analysis.View.Reason = "sniffer-structure-conflict"
		return analysis
	}
	analysis.SniffPorts = sniffPorts
	guardBoundary, ok := failClosedGuardBoundary(root, infra.GatewayIP)
	if !ok {
		analysis.View.Reason = "fail-closed-guards-missing"
		return analysis
	}
	analysis.Rules = mappingNodeValue(root, "rules")
	analysis.GuardBoundary = guardBoundary
	analysis.ModuleRules = speedtestModuleGuardRules(infra)

	listenerOccurrences := 0
	exactListeners := make(map[string]bool, len(gateways))
	for _, item := range listeners.Content {
		if listenerTouchesPort(item, speedtestModulePort) {
			listenerOccurrences++
			for _, gateway := range gateways {
				if exactModuleListener(item, gateway) {
					exactListeners[gateway.Name] = true
				}
			}
		}
	}

	sniffOccurrences := 0
	sniffComplete := true
	for _, protocol := range []string{"HTTP", "TLS", "QUIC"} {
		occurrences := sequencePortCount(sniffPorts[protocol], speedtestModulePort)
		sniffOccurrences += occurrences
		if occurrences != 1 || sequenceIntCount(sniffPorts[protocol], speedtestModulePort) != 1 {
			sniffComplete = false
		}
	}
	ruleOccurrences := 0
	rulesComplete := guardBoundary+len(analysis.ModuleRules) <= len(analysis.Rules.Content)
	for index, item := range analysis.Rules.Content {
		if item.Kind != yaml.ScalarNode {
			rulesComplete = false
			continue
		}
		rule := compactMihomoRule(item.Value)
		if strings.Contains(rule, "DST-PORT,5060") {
			ruleOccurrences++
		}
		if index >= guardBoundary && index < guardBoundary+len(analysis.ModuleRules) && rule != analysis.ModuleRules[index-guardBoundary] {
			rulesComplete = false
		}
	}
	if ruleOccurrences != len(analysis.ModuleRules) {
		rulesComplete = false
	}

	if listenerOccurrences == 0 && sniffOccurrences == 0 && ruleOccurrences == 0 {
		analysis.View = speedtestModuleView(false, true, "")
		return analysis
	}
	if listenerOccurrences == len(gateways) && len(exactListeners) == len(gateways) && sniffComplete && sniffOccurrences == 3 && rulesComplete {
		analysis.View = speedtestModuleView(true, true, "")
		return analysis
	}
	analysis.View.Reason = "partial-or-custom-5060"
	return analysis
}

func parseMihomoNodeDocument(text string) (*yaml.Node, error) {
	dec := yaml.NewDecoder(strings.NewReader(text))
	var doc yaml.Node
	if err := dec.Decode(&doc); err != nil {
		return nil, err
	}
	if len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("mihomo YAML root must be a mapping")
	}
	var extra yaml.Node
	if err := dec.Decode(&extra); err != io.EOF {
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("multiple YAML documents are not allowed")
	}
	return &doc, nil
}

func hasYAMLAliasOrMerge(node *yaml.Node) bool {
	if node == nil {
		return false
	}
	if node.Kind == yaml.AliasNode {
		return true
	}
	if node.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value == "<<" || hasYAMLAliasOrMerge(node.Content[i+1]) {
				return true
			}
		}
		return false
	}
	for _, child := range node.Content {
		if hasYAMLAliasOrMerge(child) {
			return true
		}
	}
	return false
}

func mappingNodeValue(node *yaml.Node, key string) *yaml.Node {
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Kind == yaml.ScalarNode && node.Content[i].Value == key {
			return node.Content[i+1]
		}
	}
	return nil
}

func mappingScalar(node *yaml.Node, key string) (string, bool) {
	value := mappingNodeValue(node, key)
	if value == nil || value.Kind != yaml.ScalarNode {
		return "", false
	}
	return value.Value, true
}

func yamlInteger(node *yaml.Node) (int, bool) {
	if node == nil || node.Kind != yaml.ScalarNode || node.Tag != "!!int" {
		return 0, false
	}
	var value int
	if err := node.Decode(&value); err != nil {
		return 0, false
	}
	return value, true
}

func exactMappingKeys(node *yaml.Node, keys ...string) bool {
	if node == nil || node.Kind != yaml.MappingNode || len(node.Content) != len(keys)*2 {
		return false
	}
	want := make(map[string]bool, len(keys))
	for _, key := range keys {
		want[key] = true
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Kind != yaml.ScalarNode || !want[node.Content[i].Value] {
			return false
		}
		delete(want, node.Content[i].Value)
	}
	return len(want) == 0
}

func exactStringSequence(node *yaml.Node, values ...string) bool {
	if node == nil || node.Kind != yaml.SequenceNode || len(node.Content) != len(values) {
		return false
	}
	for i, value := range values {
		if node.Content[i].Kind != yaml.ScalarNode || node.Content[i].Value != value {
			return false
		}
	}
	return true
}

func canonicalGatewayBinds(listeners *yaml.Node) ([]gatewayBind, error) {
	var gateways []gatewayBind
	seenNames := make(map[string]bool)
	seenListen := make(map[string]bool)
	for _, item := range listeners.Content {
		name, ok := mappingScalar(item, "name")
		if !ok {
			continue
		}
		match := canonicalGatewayName.FindStringSubmatch(name)
		if match == nil {
			continue
		}
		if !exactMappingKeys(item, "name", "type", "listen", "port", "network", "target") {
			return nil, fmt.Errorf("canonical gateway listener %q has custom fields", name)
		}
		typeName, typeOK := mappingScalar(item, "type")
		listen, listenOK := mappingScalar(item, "listen")
		port, portOK := yamlInteger(mappingNodeValue(item, "port"))
		target, targetOK := mappingScalar(item, "target")
		ip := net.ParseIP(listen)
		if !typeOK || typeName != "tunnel" || !listenOK || ip == nil || ip.To4() == nil || ip.IsLoopback() || ip.IsUnspecified() || ip.To4().String() != listen || !portOK || port != 443 || !targetOK || target != "127.0.0.1:443" || !exactStringSequence(mappingNodeValue(item, "network"), "tcp", "udp") {
			return nil, fmt.Errorf("canonical gateway listener %q is not exact", name)
		}
		if seenNames[name] || seenListen[listen] {
			return nil, fmt.Errorf("duplicate canonical gateway listener")
		}
		seenNames[name] = true
		seenListen[listen] = true
		gateways = append(gateways, gatewayBind{Name: name, Suffix: match[1], Listen: listen})
	}
	return gateways, nil
}

func canonicalSniffPortNodes(root *yaml.Node) (map[string]*yaml.Node, error) {
	sniffer := mappingNodeValue(root, "sniffer")
	if sniffer == nil || sniffer.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("sniffer is missing")
	}
	for _, key := range []string{"enable", "parse-pure-ip", "override-destination"} {
		value := mappingNodeValue(sniffer, key)
		if value == nil || value.Kind != yaml.ScalarNode || value.Tag != "!!bool" || value.Value != "true" {
			return nil, fmt.Errorf("sniffer.%s must be true", key)
		}
	}
	sniff := mappingNodeValue(sniffer, "sniff")
	if sniff == nil || sniff.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("sniffer.sniff is missing")
	}
	result := make(map[string]*yaml.Node, 3)
	for _, protocol := range []string{"HTTP", "TLS", "QUIC"} {
		config := mappingNodeValue(sniff, protocol)
		if config == nil || config.Kind != yaml.MappingNode {
			return nil, fmt.Errorf("sniffer.sniff.%s is missing", protocol)
		}
		ports := mappingNodeValue(config, "ports")
		if ports == nil || ports.Kind != yaml.SequenceNode {
			return nil, fmt.Errorf("sniffer.sniff.%s.ports is not a sequence", protocol)
		}
		for _, port := range ports.Content {
			value, ok := yamlInteger(port)
			if !ok || value < 1 || value > 65535 {
				return nil, fmt.Errorf("sniffer.sniff.%s.ports contains a non-integer entry", protocol)
			}
		}
		result[protocol] = ports
	}
	return result, nil
}

func failClosedGuardBoundary(root *yaml.Node, gatewayIP string) (int, bool) {
	rules := mappingNodeValue(root, "rules")
	if rules == nil || rules.Kind != yaml.SequenceNode || strings.TrimSpace(gatewayIP) == "" {
		return 0, false
	}
	wanted := map[string]bool{
		gatewayIP + "/32": false,
		"127.0.0.0/8":     false,
		"10.0.0.0/8":      false,
		"172.16.0.0/12":   false,
		"192.168.0.0/16":  false,
		"100.64.0.0/10":   false,
		"169.254.0.0/16":  false,
	}
	guardsComplete := false
	matchSeen := false
	guardBoundary := 0
	for index, item := range rules.Content {
		if item.Kind != yaml.ScalarNode {
			return 0, false
		}
		rule := compactMihomoRule(item.Value)
		if guardsComplete && strings.HasPrefix(rule, "MATCH,") {
			matchSeen = true
			break
		}
		parts := strings.Split(rule, ",")
		isGuard := (len(parts) == 3 || len(parts) == 4) &&
			parts[0] == "IP-CIDR" &&
			parts[2] == "REJECT-DROP" &&
			(len(parts) == 3 || parts[3] == "no-resolve")
		if isGuard {
			_, isGuard = wanted[parts[1]]
		}
		if isGuard {
			wanted[parts[1]] = true
			guardsComplete = true
			for _, found := range wanted {
				if !found {
					guardsComplete = false
					break
				}
			}
			if guardsComplete && guardBoundary == 0 {
				guardBoundary = index + 1
			}
			continue
		}
		if !guardsComplete {
			// Before every required destination guard is established, any
			// unfamiliar rule could accept traffic. Refuse to manage the module
			// instead of trying to interpret mihomo's complete rule grammar.
			return 0, false
		}
	}
	return guardBoundary, guardsComplete && matchSeen
}

func speedtestModuleGuardRules(infra InfraParams) []string {
	return []string{
		"AND,((DOMAIN," + infra.ConsoleDomain + "),(DST-PORT,5060)),REJECT-DROP",
		"AND,((DOMAIN," + infra.ZashDomain + "),(DST-PORT,5060)),REJECT-DROP",
	}
}

func listenerTouchesPort(node *yaml.Node, port int) bool {
	want := fmt.Sprintf("%d", port)
	if name, ok := mappingScalar(node, "name"); ok && (name == "gateway5060" || strings.HasPrefix(name, "gateway5060-")) {
		return true
	}
	if value, ok := yamlInteger(mappingNodeValue(node, "port")); ok && value == port {
		return true
	}
	if value, ok := mappingScalar(node, "target"); ok {
		_, targetPort, err := net.SplitHostPort(value)
		return err == nil && targetPort == want
	}
	return false
}

func moduleListenerName(gateway gatewayBind) string {
	if gateway.Suffix == "" {
		return "gateway5060"
	}
	return "gateway5060-" + gateway.Suffix
}

func exactModuleListener(node *yaml.Node, gateway gatewayBind) bool {
	if !exactMappingKeys(node, "name", "type", "listen", "port", "network", "target") {
		return false
	}
	name, nameOK := mappingScalar(node, "name")
	typeName, typeOK := mappingScalar(node, "type")
	listen, listenOK := mappingScalar(node, "listen")
	port, portOK := yamlInteger(mappingNodeValue(node, "port"))
	target, targetOK := mappingScalar(node, "target")
	return nameOK && name == moduleListenerName(gateway) && typeOK && typeName == "tunnel" && listenOK && listen == gateway.Listen && portOK && port == speedtestModulePort && targetOK && target == "127.0.0.1:5060" && exactStringSequence(mappingNodeValue(node, "network"), "tcp", "udp")
}

func sequenceIntCount(node *yaml.Node, value int) int {
	count := 0
	for _, item := range node.Content {
		if got, ok := yamlInteger(item); ok && got == value {
			count++
		}
	}
	return count
}

func sequencePortCount(node *yaml.Node, value int) int {
	count := 0
	for _, item := range node.Content {
		if got, ok := yamlInteger(item); ok && got == value {
			count++
		}
	}
	return count
}

func renderSpeedtestModule(analysis speedtestModuleAnalysis, enabled bool) (string, error) {
	if !analysis.View.Manageable || analysis.Document == nil {
		return "", fmt.Errorf("mihomo ingress module is not manageable")
	}
	if enabled {
		if analysis.View.Enabled {
			return encodeMihomoNode(analysis.Document)
		}
		for _, gateway := range analysis.Gateways {
			analysis.Listeners.Content = append(analysis.Listeners.Content, newModuleListenerNode(gateway))
		}
		for _, protocol := range []string{"HTTP", "TLS", "QUIC"} {
			analysis.SniffPorts[protocol].Content = append(analysis.SniffPorts[protocol].Content, intScalarNode(speedtestModulePort))
		}
		moduleRules := make([]*yaml.Node, 0, len(analysis.ModuleRules))
		for _, rule := range analysis.ModuleRules {
			moduleRules = append(moduleRules, scalarNode(rule))
		}
		analysis.Rules.Content = insertNodes(analysis.Rules.Content, analysis.GuardBoundary, moduleRules...)
	} else {
		if !analysis.View.Enabled {
			return encodeMihomoNode(analysis.Document)
		}
		kept := analysis.Listeners.Content[:0]
		for _, item := range analysis.Listeners.Content {
			remove := false
			for _, gateway := range analysis.Gateways {
				if exactModuleListener(item, gateway) {
					remove = true
					break
				}
			}
			if !remove {
				kept = append(kept, item)
			}
		}
		analysis.Listeners.Content = kept
		for _, protocol := range []string{"HTTP", "TLS", "QUIC"} {
			ports := analysis.SniffPorts[protocol]
			filtered := ports.Content[:0]
			for _, item := range ports.Content {
				if value, ok := yamlInteger(item); ok && value == speedtestModulePort {
					continue
				}
				filtered = append(filtered, item)
			}
			ports.Content = filtered
		}
		moduleRuleSet := make(map[string]bool, len(analysis.ModuleRules))
		for _, rule := range analysis.ModuleRules {
			moduleRuleSet[rule] = true
		}
		filteredRules := analysis.Rules.Content[:0]
		for _, item := range analysis.Rules.Content {
			if item.Kind == yaml.ScalarNode && moduleRuleSet[compactMihomoRule(item.Value)] {
				continue
			}
			filteredRules = append(filteredRules, item)
		}
		analysis.Rules.Content = filteredRules
	}
	return encodeMihomoNode(analysis.Document)
}

func insertNodes(nodes []*yaml.Node, index int, inserted ...*yaml.Node) []*yaml.Node {
	result := make([]*yaml.Node, 0, len(nodes)+len(inserted))
	result = append(result, nodes[:index]...)
	result = append(result, inserted...)
	result = append(result, nodes[index:]...)
	return result
}

func scalarNode(value string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value}
}

func intScalarNode(value int) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!int", Value: fmt.Sprintf("%d", value)}
}

func newModuleListenerNode(gateway gatewayBind) *yaml.Node {
	network := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Style: yaml.FlowStyle, Content: []*yaml.Node{scalarNode("tcp"), scalarNode("udp")}}
	return &yaml.Node{
		Kind:  yaml.MappingNode,
		Tag:   "!!map",
		Style: yaml.FlowStyle,
		Content: []*yaml.Node{
			scalarNode("name"), scalarNode(moduleListenerName(gateway)),
			scalarNode("type"), scalarNode("tunnel"),
			scalarNode("listen"), scalarNode(gateway.Listen),
			scalarNode("port"), intScalarNode(speedtestModulePort),
			scalarNode("network"), network,
			scalarNode("target"), scalarNode("127.0.0.1:5060"),
		},
	}
}

func encodeMihomoNode(doc *yaml.Node) (string, error) {
	var out bytes.Buffer
	enc := yaml.NewEncoder(&out)
	enc.SetIndent(2)
	if err := enc.Encode(doc); err != nil {
		return "", fmt.Errorf("encode mihomo YAML: %w", err)
	}
	if err := enc.Close(); err != nil {
		return "", fmt.Errorf("close mihomo YAML encoder: %w", err)
	}
	return out.String(), nil
}
