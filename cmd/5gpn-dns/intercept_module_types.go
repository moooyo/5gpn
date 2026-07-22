package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	interceptPhaseRequest  = "request"
	interceptPhaseResponse = "response"

	maxInterceptModules        = 64
	maxInterceptModuleHosts    = 512
	maxInterceptNetworkOrigins = 256
	maxInterceptModuleRules    = 256
	maxInterceptSettings       = 128
	maxInterceptModuleName     = 128
	maxInterceptModuleDesc     = 1024
	maxInterceptModuleSource   = 2 << 20
	maxInterceptScriptSource   = 1 << 20
	maxInterceptScriptTotal    = 8 << 20
	maxInterceptModulePattern  = 4096
	maxInterceptResourceURL    = 4096
	maxInterceptSettingValue   = 64 << 10
	maxInterceptEgressGroup    = 128
	maxInterceptRoutingRules   = 256
	maxInterceptActiveRoutes   = 2048
	maxInterceptRouteKeywords  = 8
)

var nativeExtensionIDPattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9.-]{1,126}[a-z0-9])$`)
var nativeExtensionRouteKeywordPattern = regexp.MustCompile(`^[a-z0-9._-]+$`)

type interceptModuleSource struct {
	URL    string `json:"url,omitempty"`
	Digest string `json:"digest"`
	Body   string `json:"body"`
}

type interceptActionMatch struct {
	Hosts       []string `json:"hosts"`
	Schemes     []string `json:"schemes"`
	Methods     []string `json:"methods,omitempty"`
	PathRegex   string   `json:"path_regex"`
	StatusCodes []int    `json:"status_codes,omitempty"`
}

type interceptScriptRule struct {
	ID           string               `json:"id"`
	Phase        string               `json:"phase"`
	Match        interceptActionMatch `json:"match"`
	ScriptURL    string               `json:"script_url,omitempty"`
	ScriptDigest string               `json:"script_digest"`
	ScriptBody   string               `json:"script_body"`
	BodyMode     string               `json:"body_mode"`
	TimeoutMS    int                  `json:"timeout_ms"`
	MaxBodyBytes int64                `json:"max_body_bytes"`
}

type interceptLocationValue struct {
	Longitude *float64 `json:"longitude,omitempty"`
	Latitude  *float64 `json:"latitude,omitempty"`
	Accuracy  uint32   `json:"accuracy"`
}

type interceptModuleSetting struct {
	Key         string          `json:"key"`
	Type        string          `json:"type"`
	Label       string          `json:"label,omitempty"`
	Description string          `json:"description,omitempty"`
	Required    bool            `json:"required"`
	Options     []string        `json:"options,omitempty"`
	Min         *float64        `json:"min,omitempty"`
	Max         *float64        `json:"max,omitempty"`
	Default     json.RawMessage `json:"default,omitempty"`
	Value       json.RawMessage `json:"value,omitempty"`
}

// interceptModuleActionView exposes immutable action metadata for operator
// review without returning the potentially large stored script body.
type interceptModuleActionView struct {
	ID           string               `json:"id"`
	Phase        string               `json:"phase"`
	Match        interceptActionMatch `json:"match"`
	ScriptURL    string               `json:"script_url,omitempty"`
	ScriptDigest string               `json:"script_digest"`
	BodyMode     string               `json:"body_mode"`
	TimeoutMS    int                  `json:"timeout_ms"`
	MaxBodyBytes int64                `json:"max_body_bytes"`
}

type interceptHostMapping struct {
	Pattern string `json:"host"`
	Target  string `json:"target"`
}

// interceptRoutingRule is the normalized, reviewable subset of mihomo routing
// that an enabled extension may request. It deliberately cannot name a proxy
// group: activation can only reject matching traffic or bypass the operator's
// proxy selection with DIRECT after the operator confirms the impact.
type interceptRoutingRule struct {
	Action            string   `json:"action"`
	Domain            string   `json:"domain,omitempty"`
	DomainSuffix      string   `json:"domain_suffix,omitempty"`
	DomainKeywords    []string `json:"domain_keywords,omitempty"`
	AllDomainKeywords []string `json:"all_domain_keywords,omitempty"`
	IPCIDR            string   `json:"ip_cidr,omitempty"`
	Network           string   `json:"network,omitempty"`
	DestinationPort   int      `json:"destination_port,omitempty"`
}

type interceptRoutingRuleList []interceptRoutingRule

func (rules *interceptRoutingRuleList) UnmarshalJSON(body []byte) error {
	if isJSONNull(body) {
		return errors.New("routing_rules must not be null")
	}
	var decoded []interceptRoutingRule
	if err := decodeStrictJSON(bytes.NewReader(body), &decoded); err != nil {
		return err
	}
	*rules = decoded
	return nil
}

type rawInterceptRoutingRule struct {
	Action            json.RawMessage `json:"action"`
	Domain            json.RawMessage `json:"domain"`
	DomainSuffix      json.RawMessage `json:"domain_suffix"`
	DomainKeywords    json.RawMessage `json:"domain_keywords"`
	AllDomainKeywords json.RawMessage `json:"all_domain_keywords"`
	IPCIDR            json.RawMessage `json:"ip_cidr"`
	Network           json.RawMessage `json:"network"`
	DestinationPort   json.RawMessage `json:"destination_port"`
}

// UnmarshalJSON preserves the distinction between an omitted optional field
// and a declared null or empty value. The nested strict decode is intentional:
// implementing this method must not bypass unknown-field or duplicate-key
// rejection when a routing rule is decoded outside the complete document.
func (rule *interceptRoutingRule) UnmarshalJSON(body []byte) error {
	var raw rawInterceptRoutingRule
	if err := decodeStrictJSON(bytes.NewReader(body), &raw); err != nil {
		return err
	}

	var decoded interceptRoutingRule
	if err := decodeStoredRoutingString(raw.Action, "action", &decoded.Action, true); err != nil {
		return err
	}
	if err := decodeStoredRoutingString(raw.Domain, "domain", &decoded.Domain, false); err != nil {
		return err
	}
	if err := decodeStoredRoutingString(raw.DomainSuffix, "domain_suffix", &decoded.DomainSuffix, false); err != nil {
		return err
	}
	if err := decodeStoredRoutingStrings(raw.DomainKeywords, "domain_keywords", &decoded.DomainKeywords); err != nil {
		return err
	}
	if err := decodeStoredRoutingStrings(raw.AllDomainKeywords, "all_domain_keywords", &decoded.AllDomainKeywords); err != nil {
		return err
	}
	if err := decodeStoredRoutingString(raw.IPCIDR, "ip_cidr", &decoded.IPCIDR, false); err != nil {
		return err
	}
	if err := decodeStoredRoutingString(raw.Network, "network", &decoded.Network, false); err != nil {
		return err
	}
	if len(raw.DestinationPort) > 0 {
		if isJSONNull(raw.DestinationPort) {
			return errors.New("destination_port must not be null")
		}
		if err := json.Unmarshal(raw.DestinationPort, &decoded.DestinationPort); err != nil {
			return fmt.Errorf("destination_port must be an integer: %w", err)
		}
		if decoded.DestinationPort == 0 {
			return errors.New("destination_port must not be zero when declared")
		}
	}
	*rule = decoded
	return nil
}

func decodeStoredRoutingString(raw json.RawMessage, name string, target *string, required bool) error {
	if len(raw) == 0 {
		if required {
			return fmt.Errorf("%s is required", name)
		}
		return nil
	}
	if isJSONNull(raw) {
		return fmt.Errorf("%s must not be null", name)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("%s must be a string: %w", name, err)
	}
	if *target == "" {
		return fmt.Errorf("%s must not be empty when declared", name)
	}
	return nil
}

func decodeStoredRoutingStrings(raw json.RawMessage, name string, target *[]string) error {
	if len(raw) == 0 {
		return nil
	}
	if isJSONNull(raw) {
		return fmt.Errorf("%s must not be null", name)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("%s must be an array of strings: %w", name, err)
	}
	if len(*target) == 0 {
		return fmt.Errorf("%s must not be empty when declared", name)
	}
	return nil
}

func isJSONNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

type interceptModuleSnapshot struct {
	ID                  string                   `json:"id"`
	Version             string                   `json:"extension_version"`
	Name                string                   `json:"name"`
	Description         string                   `json:"description,omitempty"`
	Enabled             bool                     `json:"enabled"`
	ImportedAt          string                   `json:"imported_at"`
	Source              interceptModuleSource    `json:"source"`
	CaptureHosts        []string                 `json:"capture_hosts"`
	CaptureDNS          string                   `json:"capture_dns,omitempty"`
	HostMappings        []interceptHostMapping   `json:"upstream_mappings,omitempty"`
	RoutingRules        interceptRoutingRuleList `json:"routing_rules,omitempty"`
	Settings            []interceptModuleSetting `json:"settings,omitempty"`
	Scripts             []interceptScriptRule    `json:"actions,omitempty"`
	PersistentStorage   bool                     `json:"persistent_storage"`
	NetworkOrigins      []string                 `json:"network_origins"`
	EgressGroupRequired bool                     `json:"egress_group_required"`
	EgressGroup         string                   `json:"egress_group,omitempty"`
}

type interceptModuleView struct {
	ID                  string                      `json:"id"`
	Version             string                      `json:"extension_version"`
	Name                string                      `json:"name"`
	Description         string                      `json:"description,omitempty"`
	Enabled             bool                        `json:"enabled"`
	Ready               bool                        `json:"ready"`
	Reason              string                      `json:"reason,omitempty"`
	CaptureHosts        []string                    `json:"capture_hosts"`
	CaptureDNS          string                      `json:"capture_dns"`
	ScriptCount         int                         `json:"script_count"`
	Actions             []interceptModuleActionView `json:"actions"`
	Settings            []interceptModuleSetting    `json:"settings,omitempty"`
	HostMappings        []interceptHostMapping      `json:"upstream_mappings,omitempty"`
	RoutingRules        []interceptRoutingRule      `json:"routing_rules,omitempty"`
	PersistentStorage   bool                        `json:"persistent_storage"`
	ExecutionOrder      int                         `json:"execution_order"`
	NetworkOrigins      []string                    `json:"network_origins"`
	EgressGroupRequired bool                        `json:"egress_group_required"`
	EgressGroup         string                      `json:"egress_group,omitempty"`
	SourceURL           string                      `json:"source_url,omitempty"`
	SourceDigest        string                      `json:"source_digest"`
	SnapshotDigest      string                      `json:"snapshot_digest"`
	ImportedAt          string                      `json:"imported_at,omitempty"`
}

type interceptModulesView struct {
	Revision              string                `json:"revision"`
	CatalogURL            string                `json:"catalog_url"`
	ExecutionOrder        []string              `json:"execution_order"`
	AvailableEgressGroups []string              `json:"available_egress_groups"`
	Modules               []interceptModuleView `json:"modules"`
	ActiveCaptureHosts    []string              `json:"active_capture_hosts"`
}

type interceptModuleUpdateCheckView struct {
	Revision  string               `json:"revision"`
	State     string               `json:"state"`
	Candidate *interceptModuleView `json:"candidate,omitempty"`
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
		return fmt.Errorf("at most %d interception extensions are allowed", maxInterceptModules)
	}
	seen := make(map[string]struct{}, len(modules))
	activeMappings := make(map[string]string)
	activeRoutingRules := 0
	for index := range modules {
		module := &modules[index]
		if !validInterceptModuleID(module.ID) {
			return fmt.Errorf("extension %d has an invalid id", index)
		}
		if _, duplicate := seen[module.ID]; duplicate {
			return fmt.Errorf("duplicate interception extension id %q", module.ID)
		}
		seen[module.ID] = struct{}{}
		if err := validateInterceptModule(*module); err != nil {
			return fmt.Errorf("extension %q: %w", module.ID, err)
		}
		if module.Enabled {
			activeRoutingRules += len(module.RoutingRules)
			if activeRoutingRules > maxInterceptActiveRoutes {
				return fmt.Errorf("enabled extensions exceed %d declared routing rules", maxInterceptActiveRoutes)
			}
			for _, mapping := range module.HostMappings {
				if target, exists := activeMappings[mapping.Pattern]; exists && target != mapping.Target {
					return fmt.Errorf("enabled extensions conflict on upstream mapping %q", mapping.Pattern)
				}
				activeMappings[mapping.Pattern] = mapping.Target
			}
		}
	}
	return nil
}

func validateInterceptModule(module interceptModuleSnapshot) error {
	if !validInterceptModuleID(module.ID) {
		return errors.New("id must be a lowercase dotted extension identifier")
	}
	if strings.TrimSpace(module.Version) == "" || len(module.Version) > 64 {
		return errors.New("extension_version must contain 1 to 64 bytes")
	}
	if strings.TrimSpace(module.Name) == "" || len(module.Name) > maxInterceptModuleName {
		return fmt.Errorf("name must contain 1 to %d bytes", maxInterceptModuleName)
	}
	if len(module.Description) > maxInterceptModuleDesc {
		return fmt.Errorf("description exceeds %d bytes", maxInterceptModuleDesc)
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
		return errors.New("source digest does not match the immutable manifest snapshot")
	}
	if len(module.Source.Body) == 0 || len(module.Source.Body) > maxInterceptModuleSource {
		return fmt.Errorf("manifest snapshot must contain 1 to %d bytes", maxInterceptModuleSource)
	}
	if _, err := time.Parse(time.RFC3339, module.ImportedAt); err != nil {
		return errors.New("imported_at must be RFC3339")
	}
	if len(module.CaptureHosts) == 0 || len(module.CaptureHosts) > maxInterceptModuleHosts {
		return fmt.Errorf("capture_hosts must contain 1 to %d entries", maxInterceptModuleHosts)
	}
	if !sort.StringsAreSorted(module.CaptureHosts) {
		return errors.New("capture_hosts must be canonical and sorted")
	}
	for _, host := range module.CaptureHosts {
		if err := validateInterceptHostPattern(host); err != nil {
			return err
		}
	}
	if err := validateInterceptCaptureDNS(module.CaptureDNS); err != nil {
		return err
	}
	if err := validateInterceptNetworkOrigins(module.NetworkOrigins); err != nil {
		return err
	}
	if err := validateInterceptEgressGroupBinding(module.EgressGroup); err != nil {
		return err
	}
	if module.Enabled && module.EgressGroupRequired && module.EgressGroup == "" {
		return errors.New("egress_group is required before enable")
	}
	if len(module.Scripts)+len(module.HostMappings) == 0 {
		return errors.New("extension has no actions or upstream mappings")
	}
	if len(module.Scripts)+len(module.HostMappings) > maxInterceptModuleRules {
		return fmt.Errorf("extension exceeds %d actions and upstream mappings", maxInterceptModuleRules)
	}
	if err := validateInterceptModuleSettings(module.Settings, module.Enabled); err != nil {
		return err
	}
	if err := validateInterceptHostMappings(module.CaptureHosts, module.HostMappings); err != nil {
		return err
	}
	if err := validateInterceptRoutingRules(module.RoutingRules); err != nil {
		return err
	}
	totalScriptBytes := 0
	seenActions := make(map[string]struct{}, len(module.Scripts))
	for index, rule := range module.Scripts {
		if !validModuleSettingKey(rule.ID) {
			return fmt.Errorf("action %d has an invalid id", index)
		}
		if _, duplicate := seenActions[rule.ID]; duplicate {
			return fmt.Errorf("duplicate action id %q", rule.ID)
		}
		seenActions[rule.ID] = struct{}{}
		if rule.Phase != interceptPhaseRequest && rule.Phase != interceptPhaseResponse {
			return fmt.Errorf("action %q has an invalid phase", rule.ID)
		}
		if err := validateInterceptActionMatch(module.CaptureHosts, rule.Phase, rule.Match); err != nil {
			return fmt.Errorf("action %q: %w", rule.ID, err)
		}
		if len(rule.ScriptURL) > maxInterceptResourceURL {
			return fmt.Errorf("action %q URL exceeds %d bytes", rule.ID, maxInterceptResourceURL)
		}
		if rule.ScriptURL != "" {
			if err := validateRemoteModuleURL(rule.ScriptURL); err != nil {
				return fmt.Errorf("action %q URL is invalid: %w", rule.ID, err)
			}
		}
		if len(rule.ScriptBody) == 0 || len(rule.ScriptBody) > maxInterceptScriptSource {
			return fmt.Errorf("action %q source must contain 1 to %d bytes", rule.ID, maxInterceptScriptSource)
		}
		if !validSHA256(rule.ScriptDigest) || rule.ScriptDigest != sha256Hex([]byte(rule.ScriptBody)) {
			return fmt.Errorf("action %q digest does not match its immutable script snapshot", rule.ID)
		}
		if rule.BodyMode != "none" && rule.BodyMode != "text" && rule.BodyMode != "binary" {
			return fmt.Errorf("action %q body_mode must be none, text, or binary", rule.ID)
		}
		if rule.TimeoutMS < 50 || rule.TimeoutMS > 30000 {
			return fmt.Errorf("action %q timeout_ms must be between 50 and 30000", rule.ID)
		}
		if rule.MaxBodyBytes < 1024 || rule.MaxBodyBytes > 64<<20 {
			return fmt.Errorf("action %q max_body_bytes must be between 1024 and 67108864", rule.ID)
		}
		totalScriptBytes += len(rule.ScriptBody)
	}
	if totalScriptBytes > maxInterceptScriptTotal {
		return fmt.Errorf("extension script snapshots exceed %d bytes", maxInterceptScriptTotal)
	}
	if module.Enabled && !interceptModuleSettingsReady(module.Settings) {
		return errors.New("required extension settings must be configured before enable")
	}
	return nil
}

func validateInterceptRoutingRules(rules []interceptRoutingRule) error {
	if len(rules) > maxInterceptRoutingRules {
		return fmt.Errorf("routing_rules exceeds %d entries", maxInterceptRoutingRules)
	}
	seen := make(map[string]struct{}, len(rules))
	for index, rule := range rules {
		if err := validateInterceptRoutingRule(rule); err != nil {
			return fmt.Errorf("routing rule %d: %w", index, err)
		}
		body, _ := json.Marshal(rule)
		key := string(body)
		if _, duplicate := seen[key]; duplicate {
			return fmt.Errorf("routing rule %d duplicates an earlier rule", index)
		}
		seen[key] = struct{}{}
	}
	return nil
}

func validateInterceptRoutingRule(rule interceptRoutingRule) error {
	if rule.Action != "reject" && rule.Action != "direct" {
		return errors.New("action must be reject or direct")
	}
	primary := 0
	if rule.Domain != "" {
		primary++
		if !validCanonicalInterceptRouteDomain(rule.Domain) {
			return errors.New("domain must be one canonical exact hostname")
		}
	}
	if rule.DomainSuffix != "" {
		primary++
		if !validCanonicalInterceptRouteDomain(rule.DomainSuffix) {
			return errors.New("domain_suffix must be one canonical suffix")
		}
	}
	if rule.IPCIDR != "" {
		primary++
		_, network, err := net.ParseCIDR(rule.IPCIDR)
		if err != nil || network.String() != rule.IPCIDR {
			return errors.New("ip_cidr must be canonical")
		}
	}
	if primary > 1 || (primary == 0 && len(rule.DomainKeywords) == 0 && len(rule.AllDomainKeywords) == 0) {
		return errors.New("declare exactly one of domain, domain_suffix, or ip_cidr, or at least one domain keyword")
	}
	if rule.IPCIDR != "" && (len(rule.DomainKeywords) > 0 || len(rule.AllDomainKeywords) > 0) {
		return errors.New("ip_cidr cannot be combined with domain keywords")
	}
	if len(rule.DomainKeywords) > maxInterceptRouteKeywords || !sort.StringsAreSorted(rule.DomainKeywords) {
		return fmt.Errorf("domain_keywords must be canonical, sorted, and contain at most %d entries", maxInterceptRouteKeywords)
	}
	if len(rule.DomainKeywords) == 1 {
		return errors.New("a single domain keyword must use all_domain_keywords")
	}
	seenKeywords := make(map[string]struct{}, len(rule.DomainKeywords))
	for _, keyword := range rule.DomainKeywords {
		if keyword == "" || len(keyword) > 64 || keyword != strings.ToLower(strings.TrimSpace(keyword)) || !nativeExtensionRouteKeywordPattern.MatchString(keyword) {
			return errors.New("domain_keywords contains an unsafe entry")
		}
		if _, duplicate := seenKeywords[keyword]; duplicate {
			return errors.New("domain_keywords contains a duplicate")
		}
		seenKeywords[keyword] = struct{}{}
	}
	if len(rule.AllDomainKeywords) > maxInterceptRouteKeywords || !sort.StringsAreSorted(rule.AllDomainKeywords) {
		return fmt.Errorf("all_domain_keywords must be canonical, sorted, and contain at most %d entries", maxInterceptRouteKeywords)
	}
	for _, keyword := range rule.AllDomainKeywords {
		if keyword == "" || len(keyword) > 64 || keyword != strings.ToLower(strings.TrimSpace(keyword)) || !nativeExtensionRouteKeywordPattern.MatchString(keyword) {
			return errors.New("all_domain_keywords contains an unsafe entry")
		}
		if _, duplicate := seenKeywords[keyword]; duplicate {
			return errors.New("routing rule repeats a keyword across any/all groups")
		}
		seenKeywords[keyword] = struct{}{}
	}
	if rule.Network != "" && rule.Network != "tcp" && rule.Network != "udp" {
		return errors.New("network must be tcp or udp")
	}
	if rule.DestinationPort < 0 || rule.DestinationPort > 65535 {
		return errors.New("destination_port must be 1 to 65535 when set")
	}
	return nil
}

func validCanonicalInterceptRouteDomain(value string) bool {
	return value == strings.TrimSpace(value) &&
		value == strings.ToLower(value) &&
		!strings.HasSuffix(value, ".") &&
		isValidDomain(value)
}

func validateInterceptActionMatch(captureHosts []string, phase string, match interceptActionMatch) error {
	if len(match.Hosts) == 0 || len(match.Hosts) > maxInterceptModuleHosts {
		return errors.New("match.hosts must not be empty")
	}
	for _, host := range match.Hosts {
		if err := validateInterceptHostPattern(host); err != nil {
			return err
		}
		if !interceptHostCoveredBy(captureHosts, host) {
			return fmt.Errorf("match host %q is outside capture_hosts", host)
		}
	}
	if len(match.Schemes) == 0 || len(match.Schemes) > 2 {
		return errors.New("match.schemes must contain http or https")
	}
	for _, scheme := range match.Schemes {
		if scheme != "http" && scheme != "https" {
			return fmt.Errorf("unsupported scheme %q", scheme)
		}
	}
	for _, method := range match.Methods {
		if method == "" || method != strings.ToUpper(method) || strings.ContainsAny(method, " \t\r\n") {
			return fmt.Errorf("invalid HTTP method %q", method)
		}
	}
	if len(match.PathRegex) == 0 || len(match.PathRegex) > maxInterceptModulePattern {
		return errors.New("match.path_regex is required")
	}
	if _, err := regexp.Compile(match.PathRegex); err != nil {
		return fmt.Errorf("path_regex is outside the supported RE2 subset: %w", err)
	}
	if phase == interceptPhaseRequest && len(match.StatusCodes) > 0 {
		return errors.New("request actions cannot match response status codes")
	}
	for _, status := range match.StatusCodes {
		if status < 100 || status > 599 {
			return fmt.Errorf("invalid response status code %d", status)
		}
	}
	return nil
}

func validateInterceptModuleSettings(settings []interceptModuleSetting, requireReady bool) error {
	if len(settings) > maxInterceptSettings {
		return fmt.Errorf("extension exceeds %d settings", maxInterceptSettings)
	}
	seen := make(map[string]struct{}, len(settings))
	for index := range settings {
		setting := settings[index]
		if !validModuleSettingKey(setting.Key) {
			return fmt.Errorf("setting %d has an invalid key", index)
		}
		if _, duplicate := seen[setting.Key]; duplicate {
			return fmt.Errorf("duplicate setting %q", setting.Key)
		}
		seen[setting.Key] = struct{}{}
		if len(setting.Label) > 128 || len(setting.Description) > 512 {
			return fmt.Errorf("setting %q metadata exceeds its bounds", setting.Key)
		}
		if err := validateInterceptSettingDefinition(setting); err != nil {
			return fmt.Errorf("setting %q: %w", setting.Key, err)
		}
		if requireReady && setting.Required && !interceptSettingReady(setting) {
			return fmt.Errorf("required setting %q is not configured", setting.Key)
		}
	}
	return nil
}

func validateInterceptSettingDefinition(setting interceptModuleSetting) error {
	switch setting.Type {
	case "text":
		if len(setting.Options) > 0 || setting.Min != nil || setting.Max != nil {
			return errors.New("text settings cannot declare options or numeric bounds")
		}
	case "select":
		if len(setting.Options) == 0 || len(setting.Options) > 64 || setting.Min != nil || setting.Max != nil {
			return errors.New("select settings require 1 to 64 options and no numeric bounds")
		}
		seen := make(map[string]struct{}, len(setting.Options))
		for _, option := range setting.Options {
			if option == "" || len(option) > 256 {
				return errors.New("select setting contains an invalid option")
			}
			if _, duplicate := seen[option]; duplicate {
				return errors.New("select setting contains duplicate options")
			}
			seen[option] = struct{}{}
		}
	case "boolean", "location":
		if len(setting.Options) > 0 || setting.Min != nil || setting.Max != nil {
			return fmt.Errorf("%s settings cannot declare options or numeric bounds", setting.Type)
		}
	case "number":
		if len(setting.Options) > 0 {
			return errors.New("number settings cannot declare options")
		}
		if setting.Min != nil && setting.Max != nil && *setting.Min > *setting.Max {
			return errors.New("minimum exceeds maximum")
		}
	default:
		return fmt.Errorf("unsupported setting type %q", setting.Type)
	}
	if len(setting.Default) > 0 {
		if err := validateInterceptSettingValue(setting, setting.Default, false); err != nil {
			return fmt.Errorf("invalid default: %w", err)
		}
	}
	if len(setting.Value) > 0 {
		if err := validateInterceptSettingValue(setting, setting.Value, false); err != nil {
			return fmt.Errorf("invalid value: %w", err)
		}
	}
	return nil
}

func validateInterceptSettingValue(setting interceptModuleSetting, raw json.RawMessage, complete bool) error {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		if complete {
			return errors.New("value is required")
		}
		return nil
	}
	if len(raw) > maxInterceptSettingValue {
		return fmt.Errorf("value exceeds %d bytes", maxInterceptSettingValue)
	}
	switch setting.Type {
	case "text", "select":
		var value string
		if err := json.Unmarshal(raw, &value); err != nil {
			return errors.New("value must be a string")
		}
		if len(value) > 4096 {
			return errors.New("string value exceeds 4096 bytes")
		}
		if complete && strings.TrimSpace(value) == "" {
			return errors.New("value must not be empty")
		}
		if setting.Type == "select" && value != "" && !containsString(setting.Options, value) {
			return errors.New("value is not a declared option")
		}
	case "boolean":
		var value bool
		if err := json.Unmarshal(raw, &value); err != nil {
			return errors.New("value must be a boolean")
		}
	case "number":
		var value float64
		if err := json.Unmarshal(raw, &value); err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			return errors.New("value must be a finite number")
		}
		if setting.Min != nil && value < *setting.Min {
			return errors.New("value is below the minimum")
		}
		if setting.Max != nil && value > *setting.Max {
			return errors.New("value exceeds the maximum")
		}
	case "location":
		var value interceptLocationValue
		if err := unmarshalStrictJSON(raw, &value); err != nil {
			return fmt.Errorf("value must be a location object: %w", err)
		}
		if value.Accuracy == 0 || value.Accuracy > 100000 {
			return errors.New("accuracy must be between 1 and 100000")
		}
		if (value.Longitude == nil) != (value.Latitude == nil) {
			return errors.New("longitude and latitude must be set together")
		}
		if value.Longitude != nil && (math.IsNaN(*value.Longitude) || math.IsInf(*value.Longitude, 0) || *value.Longitude < -180 || *value.Longitude > 180) {
			return errors.New("longitude must be between -180 and 180")
		}
		if value.Latitude != nil && (math.IsNaN(*value.Latitude) || math.IsInf(*value.Latitude, 0) || *value.Latitude < -90 || *value.Latitude > 90) {
			return errors.New("latitude must be between -90 and 90")
		}
		if complete && value.Longitude == nil {
			return errors.New("coordinates are required")
		}
	}
	return nil
}

func interceptSettingReady(setting interceptModuleSetting) bool {
	return validateInterceptSettingValue(setting, setting.Value, true) == nil
}

func interceptModuleSettingsReady(settings []interceptModuleSetting) bool {
	for _, setting := range settings {
		if setting.Required && !interceptSettingReady(setting) {
			return false
		}
	}
	return true
}

func validModuleSettingKey(value string) bool {
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

func validateInterceptHostMappings(captureHosts []string, mappings []interceptHostMapping) error {
	seen := make(map[string]struct{}, len(mappings))
	for index, mapping := range mappings {
		pattern, err := normalizeInterceptHostPattern(mapping.Pattern)
		if err != nil || pattern != mapping.Pattern {
			return fmt.Errorf("upstream mapping %d has an invalid host", index)
		}
		if !interceptHostCoveredBy(captureHosts, pattern) {
			return fmt.Errorf("upstream mapping host %q is outside capture_hosts", pattern)
		}
		if _, duplicate := seen[pattern]; duplicate {
			return fmt.Errorf("duplicate upstream mapping %q", pattern)
		}
		seen[pattern] = struct{}{}
		if !validInterceptHostTarget(mapping.Target) {
			return fmt.Errorf("upstream mapping %q has an unsafe target", pattern)
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

type interceptNetworkOriginTarget struct {
	Host string
	Port int
}

func normalizeInterceptNetworkOrigins(raw []string) ([]string, error) {
	if len(raw) > maxInterceptNetworkOrigins {
		return nil, fmt.Errorf("at most %d network origins are allowed", maxInterceptNetworkOrigins)
	}
	origins := make([]string, 0, len(raw))
	for index, value := range raw {
		origin, err := normalizeInterceptNetworkOrigin(value)
		if err != nil {
			return nil, fmt.Errorf("origin %d: %w", index, err)
		}
		origins = append(origins, origin)
	}
	return uniqueSortedStrings(origins), nil
}

func validateInterceptNetworkOrigins(origins []string) error {
	if len(origins) > maxInterceptNetworkOrigins {
		return fmt.Errorf("network_origins exceeds %d entries", maxInterceptNetworkOrigins)
	}
	if !sort.StringsAreSorted(origins) {
		return errors.New("network_origins must be canonical and sorted")
	}
	for index, origin := range origins {
		canonical, err := normalizeInterceptNetworkOrigin(origin)
		if err != nil {
			return fmt.Errorf("network origin %d: %w", index, err)
		}
		if canonical != origin {
			return fmt.Errorf("network origin %d is not canonical", index)
		}
		if index > 0 && origins[index-1] == origin {
			return fmt.Errorf("duplicate network origin %q", origin)
		}
	}
	return nil
}

func normalizeInterceptNetworkOrigin(raw string) (string, error) {
	canonical, _, err := parseInterceptNetworkOrigin(raw)
	return canonical, err
}

func interceptNetworkOriginHostPort(origin string) (string, int, error) {
	canonical, target, err := parseInterceptNetworkOrigin(origin)
	if err != nil {
		return "", 0, err
	}
	if canonical != origin {
		return "", 0, errors.New("network origin is not canonical")
	}
	return target.Host, target.Port, nil
}

func parseInterceptNetworkOrigin(raw string) (string, interceptNetworkOriginTarget, error) {
	value := strings.TrimSpace(raw)
	if value == "" || len(value) > maxInterceptResourceURL {
		return "", interceptNetworkOriginTarget{}, fmt.Errorf("origin must contain 1 to %d bytes", maxInterceptResourceURL)
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return "", interceptNetworkOriginTarget{}, fmt.Errorf("invalid origin: %w", err)
	}
	scheme := strings.ToLower(parsed.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", interceptNetworkOriginTarget{}, errors.New("origin scheme must be http or https")
	}
	if parsed.Opaque != "" || parsed.User != nil || parsed.Hostname() == "" {
		return "", interceptNetworkOriginTarget{}, errors.New("origin must have a host and no userinfo")
	}
	if (parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" || strings.Contains(value, "#") {
		return "", interceptNetworkOriginTarget{}, errors.New("origin must not contain a path, query, or fragment")
	}
	host := strings.ToLower(strings.TrimSuffix(parsed.Hostname(), "."))
	if strings.Contains(host, "*") || net.ParseIP(host) != nil || !isValidDomain(host) || host == "localhost" || strings.HasSuffix(host, ".local") {
		return "", interceptNetworkOriginTarget{}, errors.New("origin host must be an exact public DNS hostname")
	}
	if strings.HasSuffix(parsed.Host, ":") {
		return "", interceptNetworkOriginTarget{}, errors.New("origin port is empty")
	}
	defaultPort := 80
	if scheme == "https" {
		defaultPort = 443
	}
	port := defaultPort
	if parsed.Port() != "" {
		port, err = strconv.Atoi(parsed.Port())
		if err != nil || port < 1 || port > 65535 {
			return "", interceptNetworkOriginTarget{}, errors.New("origin port must be between 1 and 65535")
		}
	}
	canonical := scheme + "://" + host
	if port != defaultPort {
		canonical += ":" + strconv.Itoa(port)
	}
	return canonical, interceptNetworkOriginTarget{Host: host, Port: port}, nil
}

func validateInterceptEgressGroupBinding(group string) error {
	if group == "" {
		return nil
	}
	if group == interceptTerminalMatchTarget {
		return errors.New("egress_group uses a reserved internal name")
	}
	if !utf8.ValidString(group) || strings.TrimSpace(group) != group || len(group) > maxInterceptEgressGroup {
		return fmt.Errorf("egress_group must contain 1 to %d canonical bytes", maxInterceptEgressGroup)
	}
	for _, r := range group {
		if r == ',' || unicode.IsControl(r) {
			return errors.New("egress_group must not contain commas or control characters")
		}
	}
	return nil
}

func validInterceptModuleID(id string) bool {
	return len(id) >= 3 && len(id) <= 40 && nativeExtensionIDPattern.MatchString(id)
}

func validateInterceptHostPattern(raw string) error {
	host := strings.ToLower(strings.TrimSpace(strings.TrimSuffix(raw, ".")))
	if strings.HasPrefix(host, "*.") {
		base := strings.TrimPrefix(host, "*.")
		if !isValidDomain(base) || strings.Count(base, ".") < 1 {
			return fmt.Errorf("invalid wildcard capture host %q", raw)
		}
		return nil
	}
	if strings.Contains(host, "*") || !isValidDomain(host) {
		return fmt.Errorf("invalid exact capture host %q", raw)
	}
	return nil
}

func normalizeInterceptHostPattern(raw string) (string, error) {
	host := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), ".")
	if err := validateInterceptHostPattern(host); err != nil {
		return "", err
	}
	return host, nil
}

func interceptHostPatternCovers(allowed, candidate string) bool {
	if allowed == candidate {
		return true
	}
	if !strings.HasPrefix(allowed, "*.") {
		return false
	}
	base := strings.TrimPrefix(allowed, "*.")
	candidateBase := strings.TrimPrefix(candidate, "*.")
	return strings.HasSuffix(candidateBase, "."+base)
}

func interceptHostCoveredBy(patterns []string, candidate string) bool {
	for _, pattern := range patterns {
		if interceptHostPatternCovers(pattern, candidate) {
			return true
		}
	}
	return false
}

func activeInterceptHosts(document interceptConfigDocument) []string {
	if !document.MITM.Enabled {
		return nil
	}
	hosts := make([]string, 0, 16)
	for _, module := range document.Modules {
		if module.Enabled {
			hosts = append(hosts, module.CaptureHosts...)
		}
	}
	return uniqueSortedStrings(hosts)
}

func certificateInterceptHosts(document interceptConfigDocument) []string {
	hosts := make([]string, 0, 16)
	for _, module := range document.Modules {
		if module.Enabled {
			hosts = append(hosts, module.CaptureHosts...)
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

func uniqueSortedInts(values []int) []int {
	seen := make(map[int]struct{}, len(values))
	out := make([]int, 0, len(values))
	for _, value := range values {
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	sort.Ints(out)
	return out
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func sha256Hex(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func interceptModuleSnapshotDigest(module interceptModuleSnapshot) string {
	canonical := module
	canonical.Enabled = false
	canonical.EgressGroup = ""
	canonical.CaptureDNS = ""
	canonical.ImportedAt = ""
	canonical.Source.Body = ""
	canonical.Settings = append([]interceptModuleSetting(nil), module.Settings...)
	for index := range canonical.Settings {
		canonical.Settings[index].Value = nil
	}
	canonical.Scripts = append([]interceptScriptRule(nil), module.Scripts...)
	for index := range canonical.Scripts {
		canonical.Scripts[index].ScriptBody = ""
	}
	body, err := json.Marshal(canonical)
	if err != nil {
		panic("interception snapshot digest contains an unsupported value: " + err.Error())
	}
	return sha256Hex(body)
}

const (
	interceptCaptureDNSTrust = "trust"
	interceptCaptureDNSChina = "china"
)

func validateInterceptCaptureDNS(value string) error {
	if value != interceptCaptureDNSTrust && value != interceptCaptureDNSChina {
		return errors.New("capture_dns must be trust or china")
	}
	return nil
}

func validSHA256(value string) bool {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}
