package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	interceptPhaseRequest  = "request"
	interceptPhaseResponse = "response"

	maxInterceptModules     = 64
	maxInterceptModuleHosts = 512
	// maxInterceptHostMappingServers bounds one resolver-form mapping. A name
	// needs a primary and a spare; more is a group, which is the operator's to
	// configure and not an extension's to smuggle in one line.
	maxInterceptHostMappingServers = 4
	maxInterceptModuleRules        = 256
	maxInterceptSettings           = 128
	maxInterceptModuleName         = 128
	maxInterceptModuleDesc         = 1024
	maxInterceptModuleSource       = 2 << 20
	maxInterceptScriptSource       = 1 << 20
	maxInterceptJQProgram          = 32768
	maxInterceptMockBody           = 1 << 20
	maxInterceptMockHeaders        = 32
	maxInterceptRewriteTarget      = 4096
	maxInterceptReplacePattern     = 1024
	maxInterceptScriptTotal        = 8 << 20
	maxInterceptModulePattern      = 4096
	maxInterceptResourceURL        = 4096
	maxInterceptSettingValue       = 64 << 10
	maxInterceptEgressGroup        = 128
	maxInterceptRoutingRules       = 256
	maxInterceptActiveRoutes       = 2048
	maxInterceptRouteKeywords      = 8
)

// interceptScriptEntryProxyCompat runs a published proxy-client bundle instead
// of the native transform(context) entry point. The bundle signals completion
// by calling $done, so the sidecar waits on that rather than on a returned
// value; the mode is declared because it cannot be inferred from the source.
const interceptScriptEntryProxyCompat = "proxy-compat"

// Three declarative action kinds carry what the published modules declare --
// response-body-json-jq, reject, and mock-response-body -- instead of a script
// that reimplements them. None enters the JavaScript runtime.
//
// Base64Body exists because the published modules mock binary gRPC frames,
// which cannot survive a UTF-8 round trip through a manifest.
// interceptActionGate compiles an action only while one of the extension's own
// settings equals a declared value. Comparison is on rendered text, so a select
// gate names the option string an operator picks.
type interceptActionGate struct {
	Key    string `json:"key"`
	Equals string `json:"equals"`
}

type interceptHeaderEdits struct {
	Set    map[string]string `json:"set,omitempty" yaml:"set"`
	Remove []string          `json:"remove,omitempty" yaml:"remove"`
}

type interceptURLRewrite struct {
	Pattern string `json:"pattern,omitempty" yaml:"pattern"`
	To      string `json:"to" yaml:"to"`
	Status  int    `json:"status,omitempty" yaml:"status"`
}

// ValueMap resolves a setting's value to the substitution. A published module
// hard-codes its replacement; an operator here chooses among several.
type interceptBodyReplace struct {
	Pattern  string                       `json:"pattern" yaml:"pattern"`
	To       string                       `json:"to" yaml:"to"`
	ValueMap map[string]map[string]string `json:"value_map,omitempty" yaml:"valueMap"`
}

type interceptMockResponse struct {
	Status     int               `json:"status,omitempty" yaml:"status"`
	Headers    map[string]string `json:"headers,omitempty" yaml:"headers"`
	Body       string            `json:"body,omitempty" yaml:"body"`
	Base64Body string            `json:"base64_body,omitempty" yaml:"base64Body"`
}

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
	ID    string               `json:"id"`
	Phase string               `json:"phase"`
	Match interceptActionMatch `json:"match"`
	// EnabledWhen compares one of the extension's own settings against a value.
	// The sidecar does not compile the action when the comparison fails, so it
	// never matches. Upstream plugin formats gate a script entry from outside
	// the script, which is why a bundle never reads the key that switches it.
	EnabledWhen  *interceptActionGate   `json:"enabled_when,omitempty"`
	ScriptURL    string                 `json:"script_url,omitempty"`
	ScriptDigest string                 `json:"script_digest"`
	ScriptBody   string                 `json:"script_body"`
	BodyMode     string                 `json:"body_mode"`
	Entry        string                 `json:"entry,omitempty"`
	JQProgram    string                 `json:"jq_program,omitempty"`
	Reject       bool                   `json:"reject,omitempty"`
	Mock         *interceptMockResponse `json:"mock,omitempty"`
	Headers      *interceptHeaderEdits  `json:"headers,omitempty"`
	Rewrite      *interceptURLRewrite   `json:"rewrite,omitempty"`
	ReplaceBody  *interceptBodyReplace  `json:"replace_body,omitempty"`
	TimeoutMS    int                    `json:"timeout_ms"`
	MaxBodyBytes int64                  `json:"max_body_bytes"`
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
	ID    string `json:"id"`
	Phase string `json:"phase"`
	// Kind names which of the seven forms this action takes. It is derived
	// rather than stored, so a reviewer sees the same discriminant the executor
	// dispatches on instead of inferring it from which fields happen to be set.
	Kind  string               `json:"kind"`
	Match interceptActionMatch `json:"match"`
	// EnabledWhen lets the console say which setting value switched an action
	// off, rather than leaving an operator to wonder why a declared action does
	// nothing.
	EnabledWhen  *interceptActionGate   `json:"enabled_when,omitempty"`
	ScriptURL    string                 `json:"script_url,omitempty"`
	ScriptDigest string                 `json:"script_digest"`
	BodyMode     string                 `json:"body_mode"`
	Entry        string                 `json:"entry,omitempty"`
	JQProgram    string                 `json:"jq_program,omitempty"`
	Reject       bool                   `json:"reject,omitempty"`
	Mock         *interceptMockResponse `json:"mock,omitempty"`
	Headers      *interceptHeaderEdits  `json:"headers,omitempty"`
	Rewrite      *interceptURLRewrite   `json:"rewrite,omitempty"`
	ReplaceBody  *interceptBodyReplace  `json:"replace_body,omitempty"`
	TimeoutMS    int                    `json:"timeout_ms"`
	MaxBodyBytes int64                  `json:"max_body_bytes"`
}

// interceptHostMapping is one entry of the upstream plugin format's [Host]: a
// name, and what its
// address should be resolved from.
//
// Target carries the form in the upstream format's own encoding rather than in
// three typed
// fields, so a mapping lifted from an upstream plugin transcribes unchanged:
//
//	1.2.3.4            an address; the name resolves to it, full stop
//	other.example.com  an alias; the name resolves to whatever that name does
//	server:1.1.1.1     a resolver; the name is looked up through those servers
//
// Two of the three were already accepted and are already authorized as egress
// destinations. None of the three did anything: the mapping was parsed,
// conflict-checked, shown in the console and never consulted when a name was
// actually resolved.
type interceptHostMapping struct {
	Pattern string `json:"host"`
	Target  string `json:"target"`
}

// interceptHostMappingServerPrefix marks the resolver form. It is the upstream
// format's spelling, not ours.
const interceptHostMappingServerPrefix = "server:"

// hostMappingServers returns the resolver specs of a server: mapping, or nil
// for the address and alias forms.
func (m interceptHostMapping) hostMappingServers() []string {
	rest, ok := strings.CutPrefix(m.Target, interceptHostMappingServerPrefix)
	if !ok {
		return nil
	}
	out := make([]string, 0, 2)
	for _, part := range strings.Split(rest, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
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
	ID                string                   `json:"id"`
	Version           string                   `json:"extension_version"`
	Name              string                   `json:"name"`
	Description       string                   `json:"description,omitempty"`
	Enabled           bool                     `json:"enabled"`
	ImportedAt        string                   `json:"imported_at"`
	Source            interceptModuleSource    `json:"source"`
	CaptureHosts      []string                 `json:"capture_hosts"`
	CaptureDNS        string                   `json:"capture_dns,omitempty"`
	HostMappings      []interceptHostMapping   `json:"upstream_mappings,omitempty"`
	RoutingRules      interceptRoutingRuleList `json:"routing_rules,omitempty"`
	Settings          []interceptModuleSetting `json:"settings,omitempty"`
	Scripts           []interceptScriptRule    `json:"actions,omitempty"`
	PersistentStorage bool                     `json:"persistent_storage"`
	// Network is the whole network permission: the script request API, and a
	// request-phase URL rewrite to any origin. There is no origin list beside
	// it, so a review can say that an extension may reach the network but not
	// where.
	Network             bool   `json:"network,omitempty"`
	EgressGroupRequired bool   `json:"egress_group_required"`
	EgressGroup         string `json:"egress_group,omitempty"`
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
	Network             bool                        `json:"network,omitempty"`
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
		// Canonical, not merely valid. validateInterceptHostPattern lowercases
		// into a local and validates *that*, discarding the result, so
		// "API.example.com" passed a check whose own error message on the line
		// above promises canonicality.
		//
		// It is the odd one out among its neighbours: a host mapping requires
		// pattern == normalized, and ip_cidr requires network.String() ==
		// rule.IPCIDR. What it cost is two divergences downstream. The gateway's
		// uniqueSortedStrings does not lowercase while the sidecar's uniqueSorted
		// does, so the certificate host-set digests disagree and every
		// enable that changes that set burns the full certificate wait and then
		// rolls back, blaming the certificate. And the data plane stores the
		// pattern verbatim while matching on a canonicalised request host, so
		// exact["API.example.com"] never matches anything and the extension
		// silently intercepts nothing.
		normalized, err := normalizeInterceptHostPattern(host)
		if err != nil {
			return err
		}
		if normalized != host {
			return fmt.Errorf("capture host %q is not canonical; store it as %q", host, normalized)
		}
	}
	if err := validateInterceptCaptureDNS(module.CaptureDNS); err != nil {
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
		// Exactly one kind applies to an action. Carrying two would leave which one
		// runs undefined.
		//
		// Counted before the per-kind branches below, which is the order the
		// sidecar uses. Doing it after them let a reject action carrying a second
		// kind pass here and be refused there, several layers later, by
		// `5gpn-intercept --check-config` — an opaque cross-process failure that
		// names no field, and one that gates every subsequent unrelated document
		// mutation because validateSidecarCandidate runs on all of them.
		kinds := 0
		for _, declared := range []bool{
			rule.JQProgram != "", rule.Reject, rule.Mock != nil, rule.Headers != nil,
			rule.Rewrite != nil, rule.ReplaceBody != nil,
			rule.ScriptBody != "" || rule.ScriptURL != "",
		} {
			if declared {
				kinds++
			}
		}
		if kinds > 1 {
			return fmt.Errorf("action %q declares more than one action kind", rule.ID)
		}
		if rule.Entry != "" && (rule.JQProgram != "" || rule.Reject || rule.Mock != nil ||
			rule.Headers != nil || rule.Rewrite != nil || rule.ReplaceBody != nil) {
			return fmt.Errorf("action %q declares an entry without a script", rule.ID)
		}
		// Every kind carries a body mode and the two limits, so all three are
		// checked once, here, above the branches. They used to sit below two
		// `continue`s -- one for reject and one for the four other declarative
		// kinds -- so five of the seven kinds were never bounds-checked at all,
		// by either component. The comment below about hoisting these above the
		// jq branch is the same lesson, learned once and not carried far enough.
		//
		// What that cost: `maxBodyBytes: 1024` on a mock whose body is 2 KiB is
		// an ordinary thing to copy from a neighbouring action, and it made
		// every matching request 502 -- because validateModuleResultBody sizes
		// the result against this field. `maxBodyBytes: -1` did it
		// unconditionally, for any body including an empty one. `bodyMode:
		// banana` survived to the sidecar and defeated the streaming fast path,
		// which requires every matched rule to be exactly "none".
		if rule.BodyMode != "none" && rule.BodyMode != "text" && rule.BodyMode != "binary" {
			return fmt.Errorf("action %q body_mode must be none, text, or binary", rule.ID)
		}
		// jq and script both run with a timeout and a body limit, and the sidecar
		// bounds them for both. These sat below the jq branch, so a manifest
		// declaring `timeoutMs: 20` on a jq action was accepted here and rejected
		// there. Two components disagreeing about the same document is the whole
		// failure; the bounds are the same numbers either way.
		if rule.TimeoutMS < 50 || rule.TimeoutMS > 30000 {
			return fmt.Errorf("action %q timeout_ms must be between 50 and 30000", rule.ID)
		}
		if rule.MaxBodyBytes < 1024 || rule.MaxBodyBytes > 64<<20 {
			return fmt.Errorf("action %q max_body_bytes must be between 1024 and 67108864", rule.ID)
		}
		// A rewrite reads the request URL and returns a changed one. It is the
		// one declarative kind that never looks at rule.Phase, so on the
		// response phase it still produced a URL change -- which the response
		// path refuses, correctly and fail-closed, by failing the exchange. The
		// upstream had already answered; the client got a 502 instead of a
		// response that was fine. Four validators accepted the shape and the
		// per-action log even recorded "action completed".
		if rule.Rewrite != nil && rule.Phase != interceptPhaseRequest {
			return fmt.Errorf("action %q rewrite requires phase request", rule.ID)
		}
		// replace_body edits a body, so it needs one delivered. It reads the
		// message body directly without consulting body_mode, and today that
		// works only because the response path buffers unconditionally. Pinning
		// the declaration means a streaming fast path cannot silently turn a
		// replacement into a no-op later.
		if rule.ReplaceBody != nil && rule.BodyMode == "none" {
			return fmt.Errorf("action %q replace_body requires body_mode text or binary", rule.ID)
		}
		// A declarative action has no script snapshot, so the body and digest
		// rules below do not apply to it.
		if rule.Reject {
			continue
		}
		if rule.Mock != nil || rule.Headers != nil || rule.Rewrite != nil || rule.ReplaceBody != nil {
			for _, validate := range []func() error{
				rule.Mock.validate, rule.Headers.validate,
				rule.Rewrite.validate, rule.ReplaceBody.validate,
			} {
				if err := validate(); err != nil {
					return fmt.Errorf("action %q %w", rule.ID, err)
				}
			}
			continue
		}
		if rule.JQProgram != "" {
			if len(rule.JQProgram) > maxInterceptJQProgram {
				return fmt.Errorf("action %q jq program exceeds %d bytes", rule.ID, maxInterceptJQProgram)
			}
			if rule.BodyMode != "text" {
				return fmt.Errorf("action %q jq program requires body_mode text", rule.ID)
			}
			continue
		}
		if len(rule.ScriptBody) == 0 || len(rule.ScriptBody) > maxInterceptScriptSource {
			return fmt.Errorf("action %q source must contain 1 to %d bytes", rule.ID, maxInterceptScriptSource)
		}
		if !validSHA256(rule.ScriptDigest) || rule.ScriptDigest != sha256Hex([]byte(rule.ScriptBody)) {
			return fmt.Errorf("action %q digest does not match its immutable script snapshot", rule.ID)
		}
		if rule.Entry != "" && rule.Entry != interceptScriptEntryProxyCompat {
			return fmt.Errorf("action %q entry must be empty or %s", rule.ID, interceptScriptEntryProxyCompat)
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
		return errors.New("an address selector cannot be combined with domain keywords")
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
		// Finiteness before ordering, and each bound independently. yaml.v3
		// decodes `.nan` and `.inf` straight into these *float64 fields, and the
		// ordering check below catches neither: NaN > NaN is false, and so is
		// 1 > +Inf. A non-finite bound then survives into the immutable snapshot,
		// where interceptModuleSnapshotDigest marshals it with encoding/json --
		// which cannot represent it and panics by design. That panic is reachable
		// from CheckUpdate, which computes the digest of a candidate refetched
		// from the publisher's own URL while holding the store mutex, so a
		// manifest carrying `min: .nan` turned one "check for updates" click into
		// a permanently held lock and an extensions subsystem that answers
		// nothing until the daemon restarts.
		if setting.Min != nil && (math.IsNaN(*setting.Min) || math.IsInf(*setting.Min, 0)) {
			return errors.New("minimum must be a finite number")
		}
		if setting.Max != nil && (math.IsNaN(*setting.Max) || math.IsInf(*setting.Max, 0)) {
			return errors.New("maximum must be a finite number")
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
	if rest, ok := strings.CutPrefix(value, interceptHostMappingServerPrefix); ok {
		return validInterceptHostMappingServers(rest)
	}
	if ip := net.ParseIP(value); ip != nil {
		return ip.To4() != nil && interceptHostTargetAddressAllowed(ip)
	}
	return isValidDomain(value) && value != "localhost" && !strings.HasSuffix(value, ".local")
}

// interceptHostTargetAddressAllowed is the scope check a static mapping makes
// possible.
//
// A mapping is the one way an extension could aim origin traffic at the
// gateway's own management plane: the private-range denies in the rendered rule
// list are all no-resolve, so they stop an IP-form target and nothing else, and
// the egress anchor resolves ahead of the rule list entirely. Refusing the
// address here, at compile time, is both the earliest and the only reliable
// place — and it is only possible because a static mapping's address is known
// before any traffic flows, which is exactly why the same intent (PublicOnly)
// cannot be enforced for a name.
//
// Carrier-grade NAT is refused alongside the private ranges. IsGlobalUnicast
// reports true for 100.64/10, but it is neither globally routable nor the
// operator's own network, and forbiddenEgressScope in the core already treats
// it as out of scope; disagreeing here would let a mapping reach an address the
// core would refuse to dial for any other reason.
func interceptHostTargetAddressAllowed(ip net.IP) bool {
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	if four := ip.To4(); four != nil && four[0] == 100 && four[1]&0xc0 == 64 {
		return false
	}
	return true
}

// validInterceptHostMappingServers checks the resolver form's specs.
//
// Every part runs through the operator's own upstream validator and then
// through the same address-range check the address form gets.
//
// It used to run neither. The comment here claimed these were "the same strings
// the operator's own upstream groups accept" -- they were not:
// parseUpstreamEntryList is a lenient parser, not a validator, and its default
// branch appends an entry for any non-empty string, so len(parsed) == len(parts)
// held for essentially any input. validateUpstreamEntry, which the operator's
// own path actually runs and which refuses a bare hostname by name as "the
// exact self-reference footgun", was never called here. And because
// validInterceptHostTarget returns on the server: prefix, the whole thing
// returned before interceptHostTargetAddressAllowed -- the check whose own
// comment calls it "both the earliest and the only reliable place" to stop a
// mapping aimed at the gateway's own management plane.
//
// So `server:127.0.0.1`, `server:169.254.169.254` and `server:ns@10.0.0.5:853`
// were all accepted, while the plain `127.0.0.1` address form was correctly
// refused. Each became a live resolver group inside the DNS daemon, dialled
// verbatim on every resolution of the mapped name. The plain UDP form is the
// strongest: an arbitrary address and port, an attacker-chosen QNAME in the
// payload, and the reply parsed and returned.
func validInterceptHostMappingServers(rest string) bool {
	parts := make([]string, 0, maxInterceptHostMappingServers)
	for _, part := range strings.Split(rest, ",") {
		if part = strings.TrimSpace(part); part != "" {
			parts = append(parts, part)
		}
	}
	if len(parts) == 0 || len(parts) > maxInterceptHostMappingServers {
		return false
	}
	for _, part := range parts {
		if err := validateUpstreamEntry("host-mapping", part); err != nil {
			return false
		}
	}
	entries := parseUpstreamEntryList(parts)
	if len(entries) != len(parts) {
		return false
	}
	for _, entry := range entries {
		// Only DialAddr is ever contacted. A DoH endpoint's hostname is never
		// resolved -- the pinned address is what gets dialled -- so the range
		// check belongs on the dial address and nowhere else.
		host := entry.DialAddr
		if bare, _, err := net.SplitHostPort(host); err == nil {
			host = bare
		}
		ip := net.ParseIP(host)
		if ip == nil || ip.To4() == nil || !interceptHostTargetAddressAllowed(ip) {
			return false
		}
	}
	return true
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

// validate mirrors the sidecar's bound on a mock reply. A header value with a
// newline in it would let a mock inject further headers or a second response
// onto the wire.
func (m *interceptMockResponse) validate() error {
	if m == nil {
		return nil
	}
	if m.Status != 0 && (m.Status < 100 || m.Status > 599) {
		return fmt.Errorf("mock status %d is not an HTTP status", m.Status)
	}
	if m.Body != "" && m.Base64Body != "" {
		return errors.New("mock declares both body and base64Body")
	}
	if len(m.Headers) > maxInterceptMockHeaders {
		return fmt.Errorf("mock declares more than %d headers", maxInterceptMockHeaders)
	}
	for name, value := range m.Headers {
		if strings.TrimSpace(name) == "" || strings.ContainsAny(name, " :\r\n\t") {
			return fmt.Errorf("mock header name %q is invalid", name)
		}
		if strings.ContainsAny(value, "\r\n") {
			return fmt.Errorf("mock header %q value contains a newline", name)
		}
	}
	if err := rejectCaseCollidingKeys(mapKeys(m.Headers), "mock header"); err != nil {
		return err
	}
	if m.Base64Body != "" {
		decoded, err := base64.StdEncoding.DecodeString(m.Base64Body)
		if err != nil {
			return fmt.Errorf("mock base64Body is not base64: %w", err)
		}
		if len(decoded) > maxInterceptMockBody {
			return fmt.Errorf("mock body exceeds %d bytes", maxInterceptMockBody)
		}
		return nil
	}
	if len(m.Body) > maxInterceptMockBody {
		return fmt.Errorf("mock body exceeds %d bytes", maxInterceptMockBody)
	}
	return nil
}

// The three validators below mirror the sidecar's bounds so a manifest is
// refused at import rather than at the first request that matches.
func (h *interceptHeaderEdits) validate() error {
	if h == nil {
		return nil
	}
	if len(h.Set)+len(h.Remove) == 0 {
		return errors.New("header edits declare neither set nor remove")
	}
	if len(h.Set)+len(h.Remove) > maxInterceptMockHeaders {
		return fmt.Errorf("header edits exceed %d fields", maxInterceptMockHeaders)
	}
	for name, value := range h.Set {
		if strings.TrimSpace(name) == "" || strings.ContainsAny(name, " :\r\n\t") {
			return fmt.Errorf("header name %q is invalid", name)
		}
		if strings.ContainsAny(value, "\r\n") {
			return fmt.Errorf("header %q value contains a newline", name)
		}
	}
	for _, name := range h.Remove {
		if strings.TrimSpace(name) == "" || strings.ContainsAny(name, " :\r\n\t") {
			return fmt.Errorf("header name %q is invalid", name)
		}
	}
	if err := rejectCaseCollidingKeys(mapKeys(h.Set), "header"); err != nil {
		return err
	}
	return nil
}

// mapKeys is the key set of a string-keyed map, in no particular order.
func mapKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	return keys
}

// rejectCaseCollidingKeys refuses a manifest-controlled key set whose members
// differ only in case.
//
// These maps are the only places a publisher's own strings become JSON object
// keys in the stored document, and rejectDuplicateJSONKeys — the strict decoder
// every read of that document goes through — collapses case, which is right for
// the daemon's struct-shaped documents because encoding/json matches fields
// case-insensitively. YAML does not: `X-Trace` and `x-trace` are distinct keys,
// every validator accepted both, and marshalInterceptDocument wrote them out.
// The result was a document the write path produced and the read path refused,
// which would have made /etc/5gpn/intercept/config.json permanently unreadable
// with no in-band recovery. Today the sidecar's identical scan happens to reject
// the candidate first, so the only visible symptom is an opaque
// `--check-config` failure instead of a precise parser error — but that is a
// coincidence of a separately versioned binary, not a guarantee.
//
// For header names it is independently correct: HTTP field names are
// case-insensitive, so two spellings are genuinely ambiguous.
func rejectCaseCollidingKeys(keys []string, what string) error {
	if len(keys) < 2 {
		return nil
	}
	seen := make(map[string]string, len(keys))
	sorted := append([]string(nil), keys...)
	sort.Strings(sorted)
	for _, key := range sorted {
		folded := strings.ToLower(key)
		if previous, collides := seen[folded]; collides {
			return fmt.Errorf("%s names %q and %q differ only in case", what, previous, key)
		}
		seen[folded] = key
	}
	return nil
}

func (r *interceptURLRewrite) validate() error {
	if r == nil {
		return nil
	}
	if r.Status != 0 && r.Status != 302 && r.Status != 307 {
		return fmt.Errorf("rewrite status %d must be omitted, 302, or 307", r.Status)
	}
	if strings.TrimSpace(r.To) == "" || len(r.To) > maxInterceptRewriteTarget {
		return fmt.Errorf("rewrite target must contain 1 to %d bytes", maxInterceptRewriteTarget)
	}
	if len(r.Pattern) > maxInterceptReplacePattern {
		return fmt.Errorf("rewrite pattern exceeds %d bytes", maxInterceptReplacePattern)
	}
	if _, err := regexp.Compile(r.Pattern); err != nil {
		return fmt.Errorf("rewrite pattern is invalid: %w", err)
	}
	return nil
}

func (b *interceptBodyReplace) validate() error {
	if b == nil {
		return nil
	}
	if b.Pattern == "" || len(b.Pattern) > maxInterceptReplacePattern {
		return fmt.Errorf("body replace pattern must contain 1 to %d bytes", maxInterceptReplacePattern)
	}
	// Bounded like a rewrite target, which it was not: the sibling field has
	// carried this limit all along and the omission here was an oversight, not a
	// distinction.
	if len(b.To) > maxInterceptRewriteTarget {
		return fmt.Errorf("body replace target exceeds %d bytes", maxInterceptRewriteTarget)
	}
	compiled, err := regexp.Compile(b.Pattern)
	if err != nil {
		return fmt.Errorf("body replace pattern is invalid: %w", err)
	}
	// A pattern matching the empty string substitutes at every byte offset, so
	// the sidecar would multiply a whole body by the length of `to` with no
	// deadline to stop it -- a declarative action is dispatched before any VM
	// exists. Refusing it at import keeps that snapshot from ever being stored.
	if compiled.MatchString("") {
		return errors.New("body replace pattern must not match the empty string")
	}
	// The outer keys name settings and the inner ones name that setting's values.
	// Both are publisher-controlled and both become JSON object keys in the
	// stored document.
	if err := rejectCaseCollidingKeys(mapKeys(b.ValueMap), "body replace value_map setting"); err != nil {
		return err
	}
	for setting, mapping := range b.ValueMap {
		if err := rejectCaseCollidingKeys(mapKeys(mapping), fmt.Sprintf("body replace value_map %q value", setting)); err != nil {
			return err
		}
	}
	return nil
}
