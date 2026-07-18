package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	interceptPhaseRequest  = "request"
	interceptPhaseResponse = "response"

	interceptModuleWLOCID = "builtin-wloc"
	builtInWLOCSource     = "Built into the 5gpn-intercept binary; no remote source is executed."

	maxInterceptModules       = 64
	maxInterceptModuleHosts   = 256
	maxInterceptModuleRules   = 256
	maxInterceptModuleName    = 128
	maxInterceptModuleDesc    = 1024
	maxInterceptModuleArg     = 4096
	maxInterceptModuleSource  = 2 << 20
	maxInterceptScriptSource  = 1 << 20
	maxInterceptScriptTotal   = 8 << 20
	maxInterceptModulePattern = 4096
	maxInterceptResourceURL   = 4096
)

var builtInWLOCHosts = []string{"gs-loc.apple.com", "gs-loc-cn.apple.com"}

type interceptModuleSource struct {
	URL    string `json:"url,omitempty"`
	Digest string `json:"digest"`
	Body   string `json:"body"`
}

type interceptScriptRule struct {
	ID           string `json:"id"`
	Phase        string `json:"phase"`
	Pattern      string `json:"pattern"`
	ScriptURL    string `json:"script_url,omitempty"`
	ScriptDigest string `json:"script_digest"`
	ScriptBody   string `json:"script_body"`
	RequiresBody bool   `json:"requires_body"`
	BinaryBody   bool   `json:"binary_body"`
	TimeoutMS    int    `json:"timeout_ms"`
	MaxBodyBytes int64  `json:"max_body_bytes"`
	Argument     string `json:"argument,omitempty"`
}

type interceptModuleParameter struct {
	Key     string   `json:"key"`
	Kind    string   `json:"kind"`
	Options []string `json:"options,omitempty"`
	Value   string   `json:"value,omitempty"`
}

type interceptHostMapping struct {
	Pattern string `json:"pattern"`
	Target  string `json:"target"`
}

type interceptRewriteRule struct {
	ID          string `json:"id"`
	Pattern     string `json:"pattern"`
	Replacement string `json:"replacement,omitempty"`
	Action      string `json:"action"`
}

type interceptHeaderRule struct {
	ID        string `json:"id"`
	Pattern   string `json:"pattern"`
	Operation string `json:"operation"`
	Header    string `json:"header"`
	Value     string `json:"value,omitempty"`
}

type interceptModuleSnapshot struct {
	ID             string                     `json:"id"`
	Name           string                     `json:"name"`
	Description    string                     `json:"description,omitempty"`
	Enabled        bool                       `json:"enabled"`
	Argument       string                     `json:"argument,omitempty"`
	ImportedAt     string                     `json:"imported_at"`
	Source         interceptModuleSource      `json:"source"`
	Hosts          []string                   `json:"hosts"`
	HostMappings   []interceptHostMapping     `json:"host_mappings,omitempty"`
	Parameters     []interceptModuleParameter `json:"parameters,omitempty"`
	Scripts        []interceptScriptRule      `json:"scripts,omitempty"`
	Rewrites       []interceptRewriteRule     `json:"rewrites,omitempty"`
	Headers        []interceptHeaderRule      `json:"headers,omitempty"`
	Unsupported    []string                   `json:"unsupported,omitempty"`
	Incompatible   []string                   `json:"incompatible,omitempty"`
	PartialAllowed bool                       `json:"partial_allowed"`
}

type interceptModuleView struct {
	ID             string                            `json:"id"`
	Name           string                            `json:"name"`
	Description    string                            `json:"description,omitempty"`
	Enabled        bool                              `json:"enabled"`
	Ready          bool                              `json:"ready"`
	Reason         string                            `json:"reason,omitempty"`
	Compatibility  string                            `json:"compatibility"`
	PartialAllowed bool                              `json:"partial_allowed"`
	Hosts          []string                          `json:"hosts"`
	ScriptCount    int                               `json:"script_count"`
	RewriteCount   int                               `json:"rewrite_count"`
	Unsupported    []string                          `json:"unsupported,omitempty"`
	Incompatible   []string                          `json:"incompatible,omitempty"`
	Issues         []interceptCompatibilityIssueView `json:"issues,omitempty"`
	Parameters     []interceptModuleParameter        `json:"parameters,omitempty"`
	HostMappings   []interceptHostMapping            `json:"host_mappings,omitempty"`
	SourceURL      string                            `json:"source_url,omitempty"`
	SourceDigest   string                            `json:"source_digest"`
	ImportedAt     string                            `json:"imported_at,omitempty"`
	Argument       string                            `json:"argument,omitempty"`
}

type interceptCompatibilityIssueView struct {
	Severity string `json:"severity"`
	Message  string `json:"message"`
}

type interceptModulesView struct {
	Revision    string                `json:"revision"`
	CatalogURL  string                `json:"catalog_url"`
	Modules     []interceptModuleView `json:"modules"`
	ActiveHosts []string              `json:"active_hosts"`
}

type interceptScriptSnapshotView struct {
	ID     string `json:"id"`
	URL    string `json:"url,omitempty"`
	Digest string `json:"digest"`
	Body   string `json:"body"`
}

type interceptModuleSnapshotView struct {
	ID           string                        `json:"id"`
	Name         string                        `json:"name"`
	SourceURL    string                        `json:"source_url,omitempty"`
	SourceDigest string                        `json:"source_digest"`
	SourceBody   string                        `json:"source_body"`
	Scripts      []interceptScriptSnapshotView `json:"scripts"`
}

func validateInterceptModules(modules []interceptModuleSnapshot) error {
	if len(modules) > maxInterceptModules {
		return fmt.Errorf("at most %d interception modules are allowed", maxInterceptModules)
	}
	seen := make(map[string]struct{}, len(modules))
	activeMappings := make(map[string]string)
	for index := range modules {
		module := &modules[index]
		if module.ID == interceptModuleWLOCID || !validInterceptModuleID(module.ID) {
			return fmt.Errorf("module %d has an invalid id", index)
		}
		if _, duplicate := seen[module.ID]; duplicate {
			return fmt.Errorf("duplicate interception module id %q", module.ID)
		}
		seen[module.ID] = struct{}{}
		if err := validateInterceptModule(*module); err != nil {
			return fmt.Errorf("module %q: %w", module.ID, err)
		}
		if module.Enabled {
			for _, mapping := range module.HostMappings {
				if target, exists := activeMappings[mapping.Pattern]; exists && target != mapping.Target {
					return fmt.Errorf("enabled modules conflict on host mapping %q", mapping.Pattern)
				}
				activeMappings[mapping.Pattern] = mapping.Target
			}
		}
	}
	return nil
}

func validateInterceptModule(module interceptModuleSnapshot) error {
	if strings.TrimSpace(module.Name) == "" || len(module.Name) > maxInterceptModuleName {
		return fmt.Errorf("name must contain 1 to %d bytes", maxInterceptModuleName)
	}
	if len(module.Description) > maxInterceptModuleDesc {
		return fmt.Errorf("description exceeds %d bytes", maxInterceptModuleDesc)
	}
	if len(module.Argument) > maxInterceptModuleArg {
		return fmt.Errorf("argument exceeds %d bytes", maxInterceptModuleArg)
	}
	if len(module.Source.URL) > maxInterceptResourceURL {
		return fmt.Errorf("source URL exceeds %d bytes", maxInterceptResourceURL)
	}
	if module.Source.URL != "" {
		if err := validateRemoteModuleURL(module.Source.URL); err != nil {
			return fmt.Errorf("source URL is invalid: %w", err)
		}
	}
	if !validSHA256(module.Source.Digest) || module.Source.Digest != sha256Hex([]byte(module.Source.Body)) {
		return errors.New("source digest does not match the immutable source snapshot")
	}
	if len(module.Source.Body) == 0 || len(module.Source.Body) > maxInterceptModuleSource {
		return fmt.Errorf("source snapshot must contain 1 to %d bytes", maxInterceptModuleSource)
	}
	if _, err := time.Parse(time.RFC3339, module.ImportedAt); err != nil {
		return errors.New("imported_at must be RFC3339")
	}
	if len(module.Hosts) > maxInterceptModuleHosts {
		return fmt.Errorf("module exceeds %d MITM hosts", maxInterceptModuleHosts)
	}
	for _, host := range module.Hosts {
		if err := validateInterceptHostPattern(host); err != nil {
			return err
		}
	}
	if len(module.Scripts)+len(module.Rewrites)+len(module.Headers) > maxInterceptModuleRules {
		return fmt.Errorf("module exceeds %d supported actions", maxInterceptModuleRules)
	}
	if err := validateInterceptModuleParameters(module.Parameters); err != nil {
		return err
	}
	if err := validateInterceptHostMappings(module.HostMappings); err != nil {
		return err
	}
	if len(module.Unsupported) > 64 || len(module.Incompatible) > 64 {
		return errors.New("module compatibility report exceeds 64 entries")
	}
	if module.Enabled {
		if len(module.Hosts) == 0 {
			return errors.New("enabled module has no MITM hosts")
		}
		if len(module.Scripts)+len(module.Rewrites)+len(module.Headers) == 0 {
			return errors.New("enabled module has no supported request or response actions")
		}
		if len(module.Incompatible) > 0 {
			return errors.New("incompatible module cannot be enabled")
		}
		if !interceptModuleParametersReady(module.Parameters) {
			return errors.New("module parameters must be configured before enable")
		}
	}
	totalScriptBytes := 0
	for index, rule := range module.Scripts {
		if rule.Phase != interceptPhaseRequest && rule.Phase != interceptPhaseResponse {
			return fmt.Errorf("script %d has an invalid phase", index)
		}
		if rule.ID == "" || len(rule.Pattern) == 0 || len(rule.Pattern) > maxInterceptModulePattern {
			return fmt.Errorf("script %d has an invalid id or pattern", index)
		}
		if len(rule.ScriptURL) > maxInterceptResourceURL {
			return fmt.Errorf("script %d URL exceeds %d bytes", index, maxInterceptResourceURL)
		}
		if err := validateRemoteModuleURL(rule.ScriptURL); err != nil {
			return fmt.Errorf("script %d URL is invalid: %w", index, err)
		}
		if _, err := regexp.Compile(rule.Pattern); err != nil {
			return fmt.Errorf("script %d pattern is outside the supported RE2 subset: %w", index, err)
		}
		if len(rule.ScriptBody) == 0 || len(rule.ScriptBody) > maxInterceptScriptSource {
			return fmt.Errorf("script %d source must contain 1 to %d bytes", index, maxInterceptScriptSource)
		}
		if !validSHA256(rule.ScriptDigest) || rule.ScriptDigest != sha256Hex([]byte(rule.ScriptBody)) {
			return fmt.Errorf("script %d digest does not match its immutable snapshot", index)
		}
		if rule.TimeoutMS < 50 || rule.TimeoutMS > 30000 {
			return fmt.Errorf("script %d timeout_ms must be between 50 and 30000", index)
		}
		if rule.MaxBodyBytes < 1024 || rule.MaxBodyBytes > 64<<20 {
			return fmt.Errorf("script %d max_body_bytes must be between 1024 and 67108864", index)
		}
		if len(rule.Argument) > maxInterceptModuleArg {
			return fmt.Errorf("script %d argument exceeds %d bytes", index, maxInterceptModuleArg)
		}
		totalScriptBytes += len(rule.ScriptBody)
	}
	if totalScriptBytes > maxInterceptScriptTotal {
		return fmt.Errorf("module script snapshots exceed %d bytes", maxInterceptScriptTotal)
	}
	for index, rule := range module.Rewrites {
		if rule.ID == "" || len(rule.Pattern) == 0 || len(rule.Pattern) > maxInterceptModulePattern {
			return fmt.Errorf("rewrite %d has an invalid id or pattern", index)
		}
		if _, err := regexp.Compile(rule.Pattern); err != nil {
			return fmt.Errorf("rewrite %d pattern is outside the supported RE2 subset: %w", index, err)
		}
		switch rule.Action {
		case "reject", "reject-200", "reject-dict", "reject-array", "reject-img", "reject-drop":
		case "rewrite", "redirect-302", "redirect-307":
			if strings.TrimSpace(rule.Replacement) == "" {
				return fmt.Errorf("rewrite %d requires a replacement", index)
			}
		default:
			return fmt.Errorf("rewrite %d has an unsupported action", index)
		}
	}
	for index, rule := range module.Headers {
		if rule.ID == "" || len(rule.Pattern) == 0 || len(rule.Pattern) > maxInterceptModulePattern {
			return fmt.Errorf("header rewrite %d has an invalid id or pattern", index)
		}
		if _, err := regexp.Compile(rule.Pattern); err != nil {
			return fmt.Errorf("header rewrite %d pattern is outside the supported RE2 subset: %w", index, err)
		}
		if !validModuleHeaderName(rule.Header) {
			return fmt.Errorf("header rewrite %d has an invalid header name", index)
		}
		switch rule.Operation {
		case "delete":
		case "add", "replace":
			if strings.ContainsAny(rule.Value, "\r\n") {
				return fmt.Errorf("header rewrite %d contains a newline", index)
			}
		default:
			return fmt.Errorf("header rewrite %d has an unsupported operation", index)
		}
	}
	if module.Enabled && len(module.Unsupported) > 0 && !module.PartialAllowed {
		return errors.New("partially compatible module requires explicit partial_allowed acknowledgement")
	}
	return nil
}

func validateInterceptModuleParameters(parameters []interceptModuleParameter) error {
	seen := make(map[string]struct{}, len(parameters))
	for index, parameter := range parameters {
		if !validModuleParameterKey(parameter.Key) {
			return fmt.Errorf("parameter %d has an invalid key", index)
		}
		if _, duplicate := seen[parameter.Key]; duplicate {
			return fmt.Errorf("duplicate module parameter %q", parameter.Key)
		}
		seen[parameter.Key] = struct{}{}
		if len(parameter.Value) > maxInterceptModuleArg {
			return fmt.Errorf("parameter %q value exceeds %d bytes", parameter.Key, maxInterceptModuleArg)
		}
		switch parameter.Kind {
		case "input":
			if len(parameter.Options) != 0 {
				return fmt.Errorf("input parameter %q cannot declare options", parameter.Key)
			}
		case "select":
			if len(parameter.Options) == 0 || len(parameter.Options) > 64 {
				return fmt.Errorf("select parameter %q must declare 1 to 64 options", parameter.Key)
			}
			optionSeen := make(map[string]struct{}, len(parameter.Options))
			for _, option := range parameter.Options {
				if option == "" || len(option) > 256 {
					return fmt.Errorf("select parameter %q has an invalid option", parameter.Key)
				}
				if _, duplicate := optionSeen[option]; duplicate {
					return fmt.Errorf("select parameter %q has duplicate options", parameter.Key)
				}
				optionSeen[option] = struct{}{}
			}
			if parameter.Value != "" {
				if _, ok := optionSeen[parameter.Value]; !ok {
					return fmt.Errorf("select parameter %q value is not an option", parameter.Key)
				}
			}
		default:
			return fmt.Errorf("parameter %q has an invalid kind", parameter.Key)
		}
	}
	return nil
}

func validModuleParameterKey(value string) bool {
	if len(value) == 0 || len(value) > 64 {
		return false
	}
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' || r == '.' {
			continue
		}
		return false
	}
	return true
}

func interceptModuleParametersReady(parameters []interceptModuleParameter) bool {
	for _, parameter := range parameters {
		if strings.TrimSpace(parameter.Value) == "" {
			return false
		}
	}
	return true
}

func validateInterceptHostMappings(mappings []interceptHostMapping) error {
	seen := make(map[string]struct{}, len(mappings))
	for index, mapping := range mappings {
		pattern, err := normalizeInterceptHostPattern(mapping.Pattern)
		if err != nil || pattern != mapping.Pattern {
			return fmt.Errorf("host mapping %d has an invalid pattern", index)
		}
		if _, duplicate := seen[pattern]; duplicate {
			return fmt.Errorf("duplicate host mapping %q", pattern)
		}
		seen[pattern] = struct{}{}
		if !validInterceptHostTarget(mapping.Target) {
			return fmt.Errorf("host mapping %q has an unsafe target", pattern)
		}
	}
	return nil
}

func validInterceptHostTarget(value string) bool {
	value = strings.ToLower(strings.TrimSpace(strings.TrimSuffix(value, ".")))
	if ip := net.ParseIP(value); ip != nil {
		return ip.To4() != nil && ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast()
	}
	return isValidDomain(value) && value != "localhost" && !strings.HasSuffix(value, ".local")
}

func validModuleHeaderName(name string) bool {
	if name == "" {
		return false
	}
	for _, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || strings.ContainsRune("!#$%&'*+-.^_`|~", r) {
			continue
		}
		return false
	}
	return true
}

func validInterceptModuleID(id string) bool {
	if len(id) < 20 || len(id) > 36 || !strings.HasPrefix(id, "mod-") {
		return false
	}
	suffix := id[4:]
	if suffix[0] == '-' || suffix[len(suffix)-1] == '-' {
		return false
	}
	for _, r := range suffix {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '-' {
			return false
		}
	}
	return true
}

func validateInterceptHostPattern(raw string) error {
	host := strings.ToLower(strings.TrimSpace(strings.TrimSuffix(raw, ".")))
	if strings.HasPrefix(host, "*.") {
		base := strings.TrimPrefix(host, "*.")
		if !isValidDomain(base) || strings.Count(base, ".") < 1 {
			return fmt.Errorf("invalid wildcard MITM host %q", raw)
		}
		return nil
	}
	if strings.Contains(host, "*") || !isValidDomain(host) {
		return fmt.Errorf("invalid exact MITM host %q", raw)
	}
	return nil
}

func normalizeInterceptHostPattern(raw string) (string, error) {
	host := strings.ToLower(strings.TrimSpace(strings.TrimSuffix(raw, ".")))
	if err := validateInterceptHostPattern(host); err != nil {
		return "", err
	}
	return host, nil
}

func activeInterceptHosts(document interceptConfigDocument) []string {
	hosts := make([]string, 0, len(builtInWLOCHosts)+16)
	if document.WLOC.Enabled {
		hosts = append(hosts, builtInWLOCHosts...)
	}
	for _, module := range document.Modules {
		if module.Enabled {
			hosts = append(hosts, module.Hosts...)
		}
	}
	return uniqueSortedStrings(hosts)
}

// certificateInterceptHosts retains the two built-in WLOC SANs even while the
// module is disabled. This gives a fresh install a stable, non-empty leaf while
// the runtime allowlist still rejects WLOC until the operator enables it.
func certificateInterceptHosts(document interceptConfigDocument) []string {
	hosts := append([]string(nil), builtInWLOCHosts...)
	for _, module := range document.Modules {
		if module.Enabled {
			hosts = append(hosts, module.Hosts...)
		}
	}
	return uniqueSortedStrings(hosts)
}

func interceptCertificateDigest(hosts []string) string {
	canonical := uniqueSortedStrings(hosts)
	return sha256Hex([]byte(strings.Join(canonical, "\n") + "\n"))
}

func uniqueSortedStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}

func sha256Hex(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func validSHA256(value string) bool {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}
