package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"gopkg.in/yaml.v3"
)

const (
	nativeExtensionAPIVersion = "5gpn.io/v1"
	nativeExtensionKind       = "Extension"
	nativeExtensionCatalogURL = "https://github.com/moooyo/5gpn-extensions"
	nativeExtensionUserAgent  = "5gpn-extension-fetch/1"
)

var nativeExtensionVersionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$`)

type interceptModuleImportRequest struct {
	Revision string `json:"revision"`
	URL      string `json:"url,omitempty"`
	Content  string `json:"content,omitempty"`
}

type interceptModuleParser struct {
	resolver HostResolver
	now      func() time.Time
	client   *http.Client
}

type nativeExtensionManifest struct {
	APIVersion   string                      `yaml:"apiVersion"`
	Kind         string                      `yaml:"kind"`
	Metadata     nativeExtensionMetadata     `yaml:"metadata"`
	Permissions  nativeExtensionPermission   `yaml:"permissions"`
	Requirements nativeExtensionRequirements `yaml:"requirements"`
	Traffic      nativeExtensionTraffic      `yaml:"traffic"`
	Settings     []nativeExtensionSetting    `yaml:"settings"`
	Actions      []nativeExtensionAction     `yaml:"actions"`
}

type nativeExtensionMetadata struct {
	ID          string `yaml:"id"`
	Name        string `yaml:"name"`
	Version     string `yaml:"version"`
	Description string `yaml:"description"`
}

type nativeExtensionPermission struct {
	PersistentStorage bool                             `yaml:"persistentStorage"`
	Network           nativeExtensionNetworkPermission `yaml:"network"`
}

type nativeExtensionNetworkPermission struct {
	Origins []string `yaml:"origins"`
}

type nativeExtensionRequirements struct {
	EgressGroup nativeExtensionEgressGroupRequirement `yaml:"egressGroup"`
}

type nativeExtensionEgressGroupRequirement struct {
	Required bool `yaml:"required"`
}

type nativeExtensionTraffic struct {
	CaptureHosts     []string                     `yaml:"captureHosts"`
	UpstreamMappings []nativeExtensionHostMapping `yaml:"upstreamMappings"`
	RoutingRules     []nativeExtensionRoutingRule `yaml:"routingRules"`
}

type nativeExtensionRoutingRule struct {
	Action            string    `yaml:"action"`
	Domain            *string   `yaml:"domain"`
	DomainSuffix      *string   `yaml:"domainSuffix"`
	DomainKeywords    *[]string `yaml:"domainKeywords"`
	AllDomainKeywords *[]string `yaml:"allDomainKeywords"`
	IPCIDR            *string   `yaml:"ipCIDR"`
	Network           *string   `yaml:"network"`
	DestinationPort   *int      `yaml:"destinationPort"`
}

type nativeExtensionHostMapping struct {
	Host   string `yaml:"host"`
	Target string `yaml:"target"`
}

type nativeExtensionSetting struct {
	Key         string    `yaml:"key"`
	Type        string    `yaml:"type"`
	Label       string    `yaml:"label"`
	Description string    `yaml:"description"`
	Required    bool      `yaml:"required"`
	Options     []string  `yaml:"options"`
	Min         *float64  `yaml:"min"`
	Max         *float64  `yaml:"max"`
	Default     yaml.Node `yaml:"default"`
}

type nativeExtensionAction struct {
	ID     string                     `yaml:"id"`
	Phase  string                     `yaml:"phase"`
	Match  nativeExtensionActionMatch `yaml:"match"`
	Script nativeExtensionScript      `yaml:"script"`
}

type nativeExtensionActionMatch struct {
	Hosts       []string `yaml:"hosts"`
	Schemes     []string `yaml:"schemes"`
	Methods     []string `yaml:"methods"`
	PathRegex   string   `yaml:"pathRegex"`
	StatusCodes []int    `yaml:"statusCodes"`
}

type nativeExtensionScript struct {
	Source       string `yaml:"source"`
	Inline       string `yaml:"inline"`
	BodyMode     string `yaml:"bodyMode"`
	TimeoutMS    int    `yaml:"timeoutMs"`
	MaxBodyBytes int64  `yaml:"maxBodyBytes"`
}

func (p interceptModuleParser) Import(ctx context.Context, request interceptModuleImportRequest) (interceptModuleSnapshot, error) {
	if len(request.URL) > maxInterceptResourceURL {
		return interceptModuleSnapshot{}, fmt.Errorf("URL exceeds %d bytes", maxInterceptResourceURL)
	}
	if strings.TrimSpace(request.URL) == "" && request.Content == "" {
		return interceptModuleSnapshot{}, errors.New("exactly one of url or content is required")
	}
	if strings.TrimSpace(request.URL) != "" && request.Content != "" {
		return interceptModuleSnapshot{}, errors.New("url and content are mutually exclusive")
	}
	sourceURL := strings.TrimSpace(request.URL)
	sourceBody := []byte(request.Content)
	if sourceURL != "" {
		var err error
		sourceURL, err = normalizeModuleImportURL(sourceURL)
		if err != nil {
			return interceptModuleSnapshot{}, err
		}
		sourceBody, sourceURL, err = p.fetchResource(ctx, sourceURL, maxInterceptModuleSource)
		if err != nil {
			return interceptModuleSnapshot{}, fmt.Errorf("fetch extension manifest: %w", err)
		}
	}
	if len(sourceBody) == 0 || len(sourceBody) > maxInterceptModuleSource {
		return interceptModuleSnapshot{}, fmt.Errorf("extension manifest must contain 1 to %d bytes", maxInterceptModuleSource)
	}
	if bytes.IndexByte(sourceBody, 0) >= 0 {
		return interceptModuleSnapshot{}, errors.New("extension manifest contains a NUL byte")
	}
	if !utf8.Valid(sourceBody) {
		return interceptModuleSnapshot{}, errors.New("extension manifest must be valid UTF-8")
	}

	parsed, err := p.parse(ctx, sourceURL, sourceBody)
	if err != nil {
		return interceptModuleSnapshot{}, err
	}
	if p.now == nil {
		p.now = time.Now
	}
	parsed.Enabled = false
	parsed.ImportedAt = p.now().UTC().Format(time.RFC3339)
	parsed.Source = interceptModuleSource{
		URL:    sourceURL,
		Digest: sha256Hex(sourceBody),
		Body:   string(sourceBody),
	}
	if err := validateInterceptModule(parsed); err != nil {
		return interceptModuleSnapshot{}, err
	}
	return parsed, nil
}

func (p interceptModuleParser) parse(ctx context.Context, sourceURL string, sourceBody []byte) (interceptModuleSnapshot, error) {
	manifest, err := decodeNativeExtensionManifest(sourceBody)
	if err != nil {
		return interceptModuleSnapshot{}, err
	}
	if manifest.APIVersion != nativeExtensionAPIVersion {
		return interceptModuleSnapshot{}, fmt.Errorf("apiVersion must be %q", nativeExtensionAPIVersion)
	}
	if manifest.Kind != nativeExtensionKind {
		return interceptModuleSnapshot{}, fmt.Errorf("kind must be %q", nativeExtensionKind)
	}
	if !validInterceptModuleID(manifest.Metadata.ID) {
		return interceptModuleSnapshot{}, errors.New("metadata.id must be a lowercase dotted identifier")
	}
	if !nativeExtensionVersionPattern.MatchString(manifest.Metadata.Version) {
		return interceptModuleSnapshot{}, errors.New("metadata.version must be a semantic version")
	}

	captureHosts, err := normalizeHostList(manifest.Traffic.CaptureHosts)
	if err != nil {
		return interceptModuleSnapshot{}, fmt.Errorf("traffic.captureHosts: %w", err)
	}
	networkOrigins, err := normalizeInterceptNetworkOrigins(manifest.Permissions.Network.Origins)
	if err != nil {
		return interceptModuleSnapshot{}, fmt.Errorf("permissions.network.origins: %w", err)
	}
	mappings := make([]interceptHostMapping, 0, len(manifest.Traffic.UpstreamMappings))
	for index, raw := range manifest.Traffic.UpstreamMappings {
		host, err := normalizeInterceptHostPattern(raw.Host)
		if err != nil {
			return interceptModuleSnapshot{}, fmt.Errorf("traffic.upstreamMappings[%d].host: %w", index, err)
		}
		target := strings.ToLower(strings.TrimSpace(strings.TrimSuffix(raw.Target, ".")))
		mappings = append(mappings, interceptHostMapping{Pattern: host, Target: target})
	}
	routingRules := make([]interceptRoutingRule, 0, len(manifest.Traffic.RoutingRules))
	for index, raw := range manifest.Traffic.RoutingRules {
		rule, err := normalizeNativeExtensionRoutingRule(raw)
		if err != nil {
			return interceptModuleSnapshot{}, fmt.Errorf("traffic.routingRules[%d]: %w", index, err)
		}
		routingRules = append(routingRules, rule)
	}
	settings := make([]interceptModuleSetting, 0, len(manifest.Settings))
	for index, raw := range manifest.Settings {
		defaultValue, err := yamlNodeToJSON(raw.Default)
		if err != nil {
			return interceptModuleSnapshot{}, fmt.Errorf("settings[%d].default: %w", index, err)
		}
		settings = append(settings, interceptModuleSetting{
			Key: raw.Key, Type: strings.ToLower(strings.TrimSpace(raw.Type)), Label: strings.TrimSpace(raw.Label),
			Description: strings.TrimSpace(raw.Description), Required: raw.Required,
			Options: append([]string(nil), raw.Options...), Min: raw.Min, Max: raw.Max,
			Default: append(json.RawMessage(nil), defaultValue...), Value: append(json.RawMessage(nil), defaultValue...),
		})
	}

	scripts := make([]interceptScriptRule, 0, len(manifest.Actions))
	totalScriptBytes := 0
	for index, raw := range manifest.Actions {
		hosts, err := normalizeHostList(raw.Match.Hosts)
		if err != nil {
			return interceptModuleSnapshot{}, fmt.Errorf("actions[%d].match.hosts: %w", index, err)
		}
		schemes := normalizeLowerList(raw.Match.Schemes)
		if len(schemes) == 0 {
			schemes = []string{"https"}
		}
		methods := normalizeUpperList(raw.Match.Methods)
		pathRegex := strings.TrimSpace(raw.Match.PathRegex)
		if pathRegex == "" {
			pathRegex = "^/"
		}
		bodyMode := strings.ToLower(strings.TrimSpace(raw.Script.BodyMode))
		if bodyMode == "" {
			bodyMode = "none"
		}
		timeoutMS := raw.Script.TimeoutMS
		if timeoutMS == 0 {
			timeoutMS = 1000
		}
		maxBodyBytes := raw.Script.MaxBodyBytes
		if maxBodyBytes == 0 {
			maxBodyBytes = 8 << 20
		}
		inline := raw.Script.Inline
		source := strings.TrimSpace(raw.Script.Source)
		if (source == "") == (inline == "") {
			return interceptModuleSnapshot{}, fmt.Errorf("action %q must declare exactly one of script.source or script.inline", raw.ID)
		}
		scriptURL := ""
		scriptBody := []byte(inline)
		if source != "" {
			scriptURL, err = resolveModuleResourceURL(sourceURL, source)
			if err != nil {
				return interceptModuleSnapshot{}, fmt.Errorf("action %q script source: %w", raw.ID, err)
			}
			scriptBody, err = p.fetch(ctx, scriptURL, maxInterceptScriptSource)
			if err != nil {
				return interceptModuleSnapshot{}, fmt.Errorf("fetch action %q script: %w", raw.ID, err)
			}
		}
		if !utf8.Valid(scriptBody) {
			return interceptModuleSnapshot{}, fmt.Errorf("action %q script must be valid UTF-8", raw.ID)
		}
		totalScriptBytes += len(scriptBody)
		if totalScriptBytes > maxInterceptScriptTotal {
			return interceptModuleSnapshot{}, fmt.Errorf("extension script snapshots exceed %d bytes", maxInterceptScriptTotal)
		}
		scripts = append(scripts, interceptScriptRule{
			ID: strings.TrimSpace(raw.ID), Phase: strings.ToLower(strings.TrimSpace(raw.Phase)),
			Match: interceptActionMatch{
				Hosts: hosts, Schemes: schemes, Methods: methods, PathRegex: pathRegex,
				StatusCodes: uniqueSortedInts(raw.Match.StatusCodes),
			},
			ScriptURL: scriptURL, ScriptDigest: sha256Hex(scriptBody), ScriptBody: string(scriptBody),
			BodyMode: bodyMode, TimeoutMS: timeoutMS, MaxBodyBytes: maxBodyBytes,
		})
	}

	module := interceptModuleSnapshot{
		ID: manifest.Metadata.ID, Version: manifest.Metadata.Version,
		Name: strings.TrimSpace(manifest.Metadata.Name), Description: strings.TrimSpace(manifest.Metadata.Description),
		CaptureHosts: captureHosts, CaptureDNS: interceptCaptureDNSTrust,
		HostMappings: mappings, RoutingRules: routingRules, Settings: settings, Scripts: scripts,
		PersistentStorage: manifest.Permissions.PersistentStorage, NetworkOrigins: networkOrigins,
		EgressGroupRequired: manifest.Requirements.EgressGroup.Required,
	}
	if err := validateInterceptModule(moduleWithSyntheticSource(module)); err != nil {
		return interceptModuleSnapshot{}, err
	}
	return module, nil
}

// moduleWithSyntheticSource lets the parser reuse structural validation before
// Import attaches the immutable manifest body and timestamp.
func moduleWithSyntheticSource(module interceptModuleSnapshot) interceptModuleSnapshot {
	module.Source.Body = "pending"
	module.Source.Digest = sha256Hex([]byte(module.Source.Body))
	module.ImportedAt = time.Unix(0, 0).UTC().Format(time.RFC3339)
	return module
}

func normalizeNativeExtensionRoutingRule(raw nativeExtensionRoutingRule) (interceptRoutingRule, error) {
	rule := interceptRoutingRule{
		Action: strings.ToLower(strings.TrimSpace(raw.Action)),
	}
	var err error
	if raw.Domain != nil {
		if strings.TrimSpace(*raw.Domain) == "" {
			return interceptRoutingRule{}, errors.New("domain must not be empty when declared")
		}
		rule.Domain, err = normalizeInterceptHostPattern(*raw.Domain)
		if err != nil || strings.HasPrefix(rule.Domain, "*.") {
			return interceptRoutingRule{}, errors.New("domain must be one canonical exact hostname")
		}
	}
	if raw.DomainSuffix != nil {
		if strings.TrimSpace(*raw.DomainSuffix) == "" {
			return interceptRoutingRule{}, errors.New("domainSuffix must not be empty when declared")
		}
		rule.DomainSuffix, err = normalizeInterceptHostPattern(*raw.DomainSuffix)
		if err != nil || strings.HasPrefix(rule.DomainSuffix, "*.") {
			return interceptRoutingRule{}, errors.New("domainSuffix must be one canonical suffix without '*.'")
		}
	}
	if raw.IPCIDR != nil {
		value := strings.TrimSpace(*raw.IPCIDR)
		if value == "" {
			return interceptRoutingRule{}, errors.New("ipCIDR must not be empty when declared")
		}
		_, network, parseErr := net.ParseCIDR(value)
		if parseErr != nil {
			return interceptRoutingRule{}, errors.New("ipCIDR must be one IPv4 or IPv6 CIDR")
		}
		rule.IPCIDR = network.String()
	}
	if raw.Network != nil {
		rule.Network = strings.ToLower(strings.TrimSpace(*raw.Network))
		if rule.Network == "" {
			return interceptRoutingRule{}, errors.New("network must not be empty when declared")
		}
	}
	if raw.DestinationPort != nil {
		if *raw.DestinationPort < 1 || *raw.DestinationPort > 65535 {
			return interceptRoutingRule{}, errors.New("destinationPort must be between 1 and 65535 when declared")
		}
		rule.DestinationPort = *raw.DestinationPort
	}
	if raw.DomainKeywords != nil && len(*raw.DomainKeywords) == 0 {
		return interceptRoutingRule{}, errors.New("domainKeywords must not be empty when declared")
	}
	domainKeywords := []string(nil)
	if raw.DomainKeywords != nil {
		domainKeywords = *raw.DomainKeywords
	}
	rule.DomainKeywords = make([]string, 0, len(domainKeywords))
	seenKeywords := make(map[string]struct{}, len(domainKeywords))
	for _, value := range domainKeywords {
		keyword := strings.ToLower(strings.TrimSpace(value))
		if keyword == "" || len(keyword) > 64 || !nativeExtensionRouteKeywordPattern.MatchString(keyword) {
			return interceptRoutingRule{}, errors.New("domainKeywords entries must contain 1 to 64 safe bytes")
		}
		if _, duplicate := seenKeywords[keyword]; duplicate {
			return interceptRoutingRule{}, fmt.Errorf("duplicate domain keyword %q", keyword)
		}
		seenKeywords[keyword] = struct{}{}
		rule.DomainKeywords = append(rule.DomainKeywords, keyword)
	}
	sort.Strings(rule.DomainKeywords)
	if raw.AllDomainKeywords != nil && len(*raw.AllDomainKeywords) == 0 {
		return interceptRoutingRule{}, errors.New("allDomainKeywords must not be empty when declared")
	}
	allDomainKeywords := []string(nil)
	if raw.AllDomainKeywords != nil {
		allDomainKeywords = *raw.AllDomainKeywords
	}
	rule.AllDomainKeywords = make([]string, 0, len(allDomainKeywords))
	for _, value := range allDomainKeywords {
		keyword := strings.ToLower(strings.TrimSpace(value))
		if keyword == "" || len(keyword) > 64 || !nativeExtensionRouteKeywordPattern.MatchString(keyword) {
			return interceptRoutingRule{}, errors.New("allDomainKeywords entries must contain 1 to 64 safe bytes")
		}
		rule.AllDomainKeywords = append(rule.AllDomainKeywords, keyword)
	}
	sort.Strings(rule.AllDomainKeywords)
	if len(rule.DomainKeywords) == 1 {
		rule.AllDomainKeywords = append(rule.AllDomainKeywords, rule.DomainKeywords[0])
		sort.Strings(rule.AllDomainKeywords)
		rule.DomainKeywords = nil
	}
	if err := validateInterceptRoutingRule(rule); err != nil {
		return interceptRoutingRule{}, err
	}
	return rule, nil
}

func decodeNativeExtensionManifest(body []byte) (nativeExtensionManifest, error) {
	body = bytes.TrimPrefix(body, []byte{0xef, 0xbb, 0xbf})
	var manifest nativeExtensionManifest
	decoder := yaml.NewDecoder(bytes.NewReader(body))
	decoder.KnownFields(true)
	if err := decoder.Decode(&manifest); err != nil {
		return nativeExtensionManifest{}, fmt.Errorf("decode native extension manifest: %w", err)
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return nativeExtensionManifest{}, errors.New("extension manifest must contain exactly one YAML document")
		}
		return nativeExtensionManifest{}, fmt.Errorf("decode trailing YAML document: %w", err)
	}
	var root yaml.Node
	if err := yaml.Unmarshal(body, &root); err != nil {
		return nativeExtensionManifest{}, fmt.Errorf("inspect native extension manifest: %w", err)
	}
	if err := rejectUnsafeYAML(&root); err != nil {
		return nativeExtensionManifest{}, err
	}
	if err := rejectNullNativeExtensionRoutingFields(&root); err != nil {
		return nativeExtensionManifest{}, err
	}
	return manifest, nil
}

func rejectNullNativeExtensionRoutingFields(root *yaml.Node) error {
	if root == nil || root.Kind != yaml.DocumentNode || len(root.Content) != 1 {
		return nil
	}
	traffic := yamlMappingValue(root.Content[0], "traffic")
	rules := yamlMappingValue(traffic, "routingRules")
	if rules == nil {
		return nil
	}
	if rules.Tag == "!!null" {
		return errors.New("traffic.routingRules must not be null")
	}
	if rules.Kind != yaml.SequenceNode {
		return nil
	}
	fields := map[string]struct{}{
		"action":            {},
		"domain":            {},
		"domainSuffix":      {},
		"domainKeywords":    {},
		"allDomainKeywords": {},
		"ipCIDR":            {},
		"network":           {},
		"destinationPort":   {},
	}
	for ruleIndex, rule := range rules.Content {
		if rule.Kind != yaml.MappingNode {
			continue
		}
		for index := 0; index+1 < len(rule.Content); index += 2 {
			name := rule.Content[index].Value
			if _, tracked := fields[name]; tracked && rule.Content[index+1].Tag == "!!null" {
				return fmt.Errorf("traffic.routingRules[%d].%s must not be null", ruleIndex, name)
			}
		}
	}
	return nil
}

func yamlMappingValue(node *yaml.Node, key string) *yaml.Node {
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for index := 0; index+1 < len(node.Content); index += 2 {
		if node.Content[index].Value == key {
			return node.Content[index+1]
		}
	}
	return nil
}

func rejectUnsafeYAML(node *yaml.Node) error {
	if node == nil {
		return nil
	}
	if node.Kind == yaml.AliasNode || node.Anchor != "" {
		return errors.New("extension manifest cannot use YAML aliases or anchors")
	}
	if node.Kind == yaml.MappingNode {
		for index := 0; index+1 < len(node.Content); index += 2 {
			if node.Content[index].Value == "<<" {
				return errors.New("extension manifest cannot use YAML merge keys")
			}
		}
	}
	for _, child := range node.Content {
		if err := rejectUnsafeYAML(child); err != nil {
			return err
		}
	}
	return nil
}

func yamlNodeToJSON(node yaml.Node) (json.RawMessage, error) {
	if node.Kind == 0 || (node.Kind == yaml.ScalarNode && node.Tag == "!!null") {
		return nil, nil
	}
	var value any
	if err := node.Decode(&value); err != nil {
		return nil, err
	}
	body, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	return body, nil
}

func normalizeHostList(raw []string) ([]string, error) {
	hosts := make([]string, 0, len(raw))
	for _, value := range raw {
		host, err := normalizeInterceptHostPattern(value)
		if err != nil {
			return nil, err
		}
		hosts = append(hosts, host)
	}
	hosts = uniqueSortedStrings(hosts)
	if len(hosts) == 0 {
		return nil, errors.New("at least one host is required")
	}
	return hosts, nil
}

func normalizeLowerList(raw []string) []string {
	out := make([]string, 0, len(raw))
	for _, value := range raw {
		value = strings.ToLower(strings.TrimSpace(value))
		if value != "" {
			out = append(out, value)
		}
	}
	return uniqueSortedStrings(out)
}

func normalizeUpperList(raw []string) []string {
	out := make([]string, 0, len(raw))
	for _, value := range raw {
		value = strings.ToUpper(strings.TrimSpace(value))
		if value != "" {
			out = append(out, value)
		}
	}
	return uniqueSortedStrings(out)
}

func (p interceptModuleParser) fetch(ctx context.Context, rawURL string, limit int64) ([]byte, error) {
	body, _, err := p.fetchResource(ctx, rawURL, limit)
	return body, err
}

func (p interceptModuleParser) fetchResource(ctx context.Context, rawURL string, limit int64) ([]byte, string, error) {
	if err := validateRemoteModuleURL(rawURL); err != nil {
		return nil, "", err
	}
	client := p.client
	if client == nil {
		client = newSubHTTPClient(p.resolver)
	} else {
		clone := *client
		client = &clone
	}
	if transport, ok := client.Transport.(*http.Transport); ok {
		transport = transport.Clone()
		transport.MaxResponseHeaderBytes = 64 << 10
		transport.ResponseHeaderTimeout = 15 * time.Second
		client.Transport = transport
	}
	client.Timeout = 30 * time.Second
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		if err := validateRemoteModuleURL(req.URL.String()); err != nil {
			return fmt.Errorf("unsafe redirect: %w", err)
		}
		setModuleFetchHeaders(req)
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, "", err
	}
	setModuleFetchHeaders(req)
	resp, err := client.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return nil, "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, "", err
	}
	if int64(len(body)) > limit {
		return nil, "", fmt.Errorf("response exceeds %d bytes", limit)
	}
	if len(body) == 0 {
		return nil, "", errors.New("empty response")
	}
	prefix := strings.ToLower(strings.TrimSpace(string(body[:min(len(body), 512)])))
	if strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "text/html") || strings.HasPrefix(prefix, "<!doctype html") || strings.HasPrefix(prefix, "<html") {
		return nil, "", errors.New("refusing an HTML response instead of an extension resource")
	}
	return body, resp.Request.URL.String(), nil
}

func setModuleFetchHeaders(request *http.Request) {
	// net/http may synthesize Referer while following a redirect. Extension and
	// marketplace URLs can contain opaque query data, so never disclose the
	// previous URL to another origin.
	request.Header.Del("Referer")
	request.Header.Set("Accept", "application/json, application/yaml, text/yaml, application/javascript, text/plain, */*;q=0.1")
	request.Header.Set("User-Agent", nativeExtensionUserAgent)
}

func normalizeModuleImportURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if len(raw) == 0 || len(raw) > maxInterceptResourceURL {
		return "", fmt.Errorf("URL must contain 1 to %d bytes", maxInterceptResourceURL)
	}
	if err := validateRemoteModuleURL(raw); err != nil {
		return "", err
	}
	return raw, nil
}

func validateRemoteModuleURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("invalid URL: %w", err)
	}
	if u.Scheme != "https" {
		return errors.New("extension resources must use https")
	}
	if u.Hostname() == "" || u.User != nil {
		return errors.New("extension resource URL must have a host and no userinfo")
	}
	if u.Fragment != "" {
		return errors.New("extension resource URL must not contain a fragment")
	}
	return nil
}

func resolveModuleResourceURL(manifestURL, resource string) (string, error) {
	resource = strings.TrimSpace(resource)
	if resource == "" {
		return "", errors.New("script source is empty")
	}
	u, err := url.Parse(resource)
	if err != nil {
		return "", err
	}
	if !u.IsAbs() {
		if manifestURL == "" {
			return "", errors.New("relative script source requires a URL-based extension import")
		}
		base, err := url.Parse(manifestURL)
		if err != nil {
			return "", err
		}
		u = base.ResolveReference(u)
	}
	if err := validateRemoteModuleURL(u.String()); err != nil {
		return "", err
	}
	return u.String(), nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
