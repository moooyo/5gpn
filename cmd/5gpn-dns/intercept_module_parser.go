package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	defaultModuleReferer = "https://hub.kelee.one/"
	moduleLoonUserAgent  = "Loon/3.2.4 CFNetwork/3826.500.131 Darwin/24.5.0"
)

var loonScriptLine = regexp.MustCompile(`(?i)^(http-request|http-response)\s+(\S+)\s+(.+)$`)
var disabledScriptOption = regexp.MustCompile(`(?i)(?:^|,)\s*enabled?\s*=\s*(?:false|0|off|no)(?:\s*,|\s*$)`)

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
			return interceptModuleSnapshot{}, fmt.Errorf("fetch module: %w", err)
		}
	}
	if len(sourceBody) == 0 || len(sourceBody) > maxInterceptModuleSource {
		return interceptModuleSnapshot{}, fmt.Errorf("module source must contain 1 to %d bytes", maxInterceptModuleSource)
	}
	if bytes.IndexByte(sourceBody, 0) >= 0 {
		return interceptModuleSnapshot{}, errors.New("module source contains a NUL byte")
	}
	if !utf8.Valid(sourceBody) {
		return interceptModuleSnapshot{}, errors.New("module source must be valid UTF-8")
	}

	parsed, err := p.parse(ctx, sourceURL, sourceBody)
	if err != nil {
		return interceptModuleSnapshot{}, err
	}
	if p.now == nil {
		p.now = time.Now
	}
	digest := sha256Hex(sourceBody)
	parsed.ID = "mod-" + digest[:32]
	parsed.Enabled = false
	parsed.ImportedAt = p.now().UTC().Format(time.RFC3339)
	parsed.Source = interceptModuleSource{
		URL:    sourceURL,
		Digest: digest,
		Body:   string(sourceBody),
	}
	if err := validateInterceptModule(parsed); err != nil {
		return interceptModuleSnapshot{}, err
	}
	return parsed, nil
}

func (p interceptModuleParser) parse(
	ctx context.Context,
	sourceURL string,
	sourceBody []byte,
) (interceptModuleSnapshot, error) {
	lines := moduleLogicalLines(sourceBody)
	metadata := map[string]string{}
	parameters := make([]interceptModuleParameter, 0)
	parameterKeys := make(map[string]struct{})
	var metadataIssues []string
	sections := make(map[string][]string)
	section := ""
	for _, original := range lines {
		line := strings.TrimSpace(original)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#!") {
			if key, value, ok := strings.Cut(strings.TrimPrefix(line, "#!"), "="); ok {
				key = strings.ToLower(strings.TrimSpace(key))
				value = strings.TrimSpace(value)
				switch key {
				case "input":
					if parameter, ok := parseLoonInputParameter(value); ok {
						if _, duplicate := parameterKeys[parameter.Key]; duplicate {
							metadataIssues = append(metadataIssues, summarizeUnsupported("Metadata", line, "duplicate plugin parameter"))
						} else {
							parameterKeys[parameter.Key] = struct{}{}
							parameters = append(parameters, parameter)
						}
					} else {
						metadataIssues = append(metadataIssues, summarizeUnsupported("Metadata", line, "invalid #!input declaration"))
					}
				case "select":
					if parameter, ok := parseLoonSelectParameter(value); ok {
						if _, duplicate := parameterKeys[parameter.Key]; duplicate {
							metadataIssues = append(metadataIssues, summarizeUnsupported("Metadata", line, "duplicate plugin parameter"))
						} else {
							parameterKeys[parameter.Key] = struct{}{}
							parameters = append(parameters, parameter)
						}
					} else {
						metadataIssues = append(metadataIssues, summarizeUnsupported("Metadata", line, "invalid #!select declaration"))
					}
				default:
					metadata[key] = value
				}
			}
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(line, "["), "]")))
			continue
		}
		if strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if section != "" {
			sections[section] = append(sections[section], line)
		}
	}

	module := interceptModuleSnapshot{
		Name:        firstNonEmpty(metadata["name"], metadata["title"], moduleNameFromURL(sourceURL), "Imported module"),
		Description: firstNonEmpty(metadata["desc"], metadata["description"]),
		Parameters:  parameters,
	}
	module.Unsupported = append(module.Unsupported, metadataIssues...)
	if len(module.Name) > maxInterceptModuleName {
		module.Name = truncateUTF8Bytes(module.Name, maxInterceptModuleName)
	}
	if len(module.Description) > maxInterceptModuleDesc {
		module.Description = truncateUTF8Bytes(module.Description, maxInterceptModuleDesc)
	}

	hosts, mitmUnsupported := parseMITMHosts(sections["mitm"])
	module.Hosts = hosts
	module.Unsupported = append(module.Unsupported, mitmUnsupported...)

	scriptCache := map[string][]byte{}
	totalScriptBytes := 0
	for index, line := range sections["script"] {
		if disabledScriptOption.MatchString(line) {
			continue
		}
		if index >= maxInterceptModuleRules {
			return interceptModuleSnapshot{}, fmt.Errorf("module exceeds %d Script entries", maxInterceptModuleRules)
		}
		rule, supported, optionWarnings, parseErr := parseModuleScriptLine(line, index)
		if parseErr != nil {
			module.Unsupported = append(module.Unsupported, summarizeUnsupported("Script", line, parseErr.Error()))
			continue
		}
		if !supported {
			module.Unsupported = append(module.Unsupported, summarizeUnsupported("Script", line, "unsupported script type"))
			continue
		}
		for _, warning := range optionWarnings {
			module.Unsupported = append(module.Unsupported, summarizeUnsupported("Script", line, warning))
		}
		scriptURL, resolveErr := resolveModuleResourceURL(sourceURL, rule.ScriptURL)
		if resolveErr != nil {
			module.Unsupported = append(module.Unsupported, summarizeUnsupported("Script", line, resolveErr.Error()))
			continue
		}
		scriptBody, cached := scriptCache[scriptURL]
		if !cached {
			scriptBody, parseErr = p.fetch(ctx, scriptURL, maxInterceptScriptSource)
			if parseErr != nil {
				return interceptModuleSnapshot{}, fmt.Errorf("fetch script %s: %w", scriptURL, parseErr)
			}
			scriptCache[scriptURL] = scriptBody
		}
		if !utf8.Valid(scriptBody) {
			return interceptModuleSnapshot{}, fmt.Errorf("script %s is not valid UTF-8", scriptURL)
		}
		totalScriptBytes += len(scriptBody)
		if totalScriptBytes > maxInterceptScriptTotal {
			return interceptModuleSnapshot{}, fmt.Errorf("module script snapshots exceed %d bytes", maxInterceptScriptTotal)
		}
		rule.ScriptURL = scriptURL
		rule.ScriptBody = string(scriptBody)
		rule.ScriptDigest = sha256Hex(scriptBody)
		for _, issue := range scriptIncompatibilities(rule.ScriptBody) {
			module.Incompatible = append(module.Incompatible, summarizeUnsupported("Script", scriptURL, issue))
		}
		for _, issue := range scriptCompatibilityWarnings(rule.ScriptBody) {
			module.Unsupported = append(module.Unsupported, summarizeUnsupported("Script", scriptURL, issue))
		}
		module.Scripts = append(module.Scripts, rule)
	}

	for index, line := range sections["rewrite"] {
		rewrite, header, err := parseLoonRewriteLine(line, index)
		if err != nil {
			module.Unsupported = append(module.Unsupported, summarizeUnsupported("Rewrite", line, err.Error()))
			continue
		}
		if rewrite != nil {
			module.Rewrites = append(module.Rewrites, *rewrite)
		}
		if header != nil {
			module.Headers = append(module.Headers, *header)
		}
	}
	hostMappings, hostIssues := parseLoonHostMappings(sections["host"])
	module.HostMappings = hostMappings
	module.Unsupported = append(module.Unsupported, hostIssues...)

	for sectionName, sectionLines := range sections {
		switch sectionName {
		case "mitm", "script", "rewrite", "host":
			continue
		case "general":
			for _, line := range sectionLines {
				module.Unsupported = append(module.Unsupported, summarizeUnsupported("General", line, "directive is not part of the interception runtime"))
			}
		default:
			for _, line := range sectionLines {
				module.Unsupported = append(module.Unsupported, summarizeUnsupported(sectionName, line, "section is not supported"))
			}
		}
	}
	if len(module.Hosts) == 0 {
		module.Incompatible = append(module.Incompatible, "[MITM] No supported hostname entries were found")
	}
	if len(module.Scripts)+len(module.Rewrites)+len(module.Headers) == 0 {
		module.Incompatible = append(module.Incompatible, "[Plugin] No supported HTTP actions were found")
	}
	module.Unsupported = uniqueSortedStrings(module.Unsupported)
	module.Incompatible = uniqueSortedStrings(module.Incompatible)
	if len(module.Unsupported) > 64 {
		module.Unsupported = append(module.Unsupported[:63], "Additional unsupported directives were omitted from this view")
	}
	if len(module.Incompatible) > 64 {
		module.Incompatible = append(module.Incompatible[:63], "Additional incompatible directives were omitted from this view")
	}
	return module, nil
}

func scriptIncompatibilities(source string) []string {
	checks := []struct {
		needle  string
		message string
	}{
		{"$httpClient", "outbound script networking is disabled"},
		{"require(", "CommonJS require is unavailable"},
		{"setTimeout(", "asynchronous timers are unavailable"},
	}
	warnings := make([]string, 0, len(checks))
	for _, check := range checks {
		if strings.Contains(source, check.needle) {
			warnings = append(warnings, check.message)
		}
	}
	return uniqueSortedStrings(warnings)
}

func scriptCompatibilityWarnings(source string) []string {
	checks := []struct {
		needle  string
		message string
	}{
		{"$notification", "notifications are written to the gateway log instead of a device notification"},
		{"node:", "per-request node selection is ignored"},
	}
	var warnings []string
	for _, check := range checks {
		if strings.Contains(source, check.needle) {
			warnings = append(warnings, check.message)
		}
	}
	return uniqueSortedStrings(warnings)
}

func parseLoonInputParameter(raw string) (interceptModuleParameter, bool) {
	key := strings.TrimSpace(raw)
	if !validModuleParameterKey(key) {
		return interceptModuleParameter{}, false
	}
	return interceptModuleParameter{Key: key, Kind: "input"}, true
}

func parseLoonSelectParameter(raw string) (interceptModuleParameter, bool) {
	parts := strings.Split(raw, ",")
	if len(parts) < 2 {
		return interceptModuleParameter{}, false
	}
	key := strings.TrimSpace(parts[0])
	if !validModuleParameterKey(key) {
		return interceptModuleParameter{}, false
	}
	options := make([]string, 0, len(parts)-1)
	for _, value := range parts[1:] {
		value = strings.TrimSpace(value)
		if value == "" {
			return interceptModuleParameter{}, false
		}
		options = append(options, value)
	}
	return interceptModuleParameter{Key: key, Kind: "select", Options: options}, true
}

func parseLoonHostMappings(lines []string) ([]interceptHostMapping, []string) {
	mappings := make([]interceptHostMapping, 0, len(lines))
	seen := make(map[string]string)
	var issues []string
	for _, line := range lines {
		left, right, ok := strings.Cut(line, "=")
		if !ok {
			issues = append(issues, summarizeUnsupported("Host", line, "mapping must use host = target"))
			continue
		}
		pattern, err := normalizeInterceptHostPattern(left)
		target := strings.ToLower(strings.TrimSpace(strings.TrimSuffix(right, ".")))
		if err != nil || !validInterceptHostTarget(target) {
			issues = append(issues, summarizeUnsupported("Host", line, "only public IPv4 or domain targets are supported"))
			continue
		}
		if previous, duplicate := seen[pattern]; duplicate {
			if previous != target {
				issues = append(issues, summarizeUnsupported("Host", line, "conflicts with an earlier host mapping"))
			}
			continue
		}
		seen[pattern] = target
		mappings = append(mappings, interceptHostMapping{Pattern: pattern, Target: target})
	}
	return mappings, issues
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
		return nil, "", errors.New("refusing an HTML response instead of a module resource")
	}
	return body, resp.Request.URL.String(), nil
}

func setModuleFetchHeaders(request *http.Request) {
	request.Header.Set("Accept", "text/plain, application/javascript, */*;q=0.1")
	// Loon-only imports always use a stable native client shape. Callers cannot
	// provide or override request headers.
	request.Header.Set("User-Agent", moduleLoonUserAgent)
	request.Header.Set("Referer", defaultModuleReferer)
}

func normalizeModuleImportURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if len(raw) == 0 || len(raw) > maxInterceptResourceURL {
		return "", fmt.Errorf("URL must contain 1 to %d bytes", maxInterceptResourceURL)
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("invalid URL: %w", err)
	}
	if strings.EqualFold(u.Scheme, "https") {
		if err := validateRemoteModuleURL(raw); err != nil {
			return "", err
		}
		return raw, nil
	}
	if !strings.EqualFold(u.Scheme, "loon") {
		return "", errors.New("module imports must use https or loon://import?plugin=<https-url>")
	}
	if u.User != nil || u.Fragment != "" || u.Port() != "" || u.Opaque != "" {
		return "", errors.New("invalid Loon import URL")
	}
	host := strings.ToLower(u.Hostname())
	pathValue := strings.ToLower(strings.TrimSuffix(u.Path, "/"))
	if !((host == "import" && pathValue == "") || (host == "" && pathValue == "/import")) {
		return "", errors.New("Loon import URL must target the import action")
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return "", errors.New("Loon import URL has an invalid query")
	}
	plugins := query["plugin"]
	if len(plugins) != 1 || strings.TrimSpace(plugins[0]) == "" {
		return "", errors.New("Loon import URL must contain exactly one plugin URL")
	}
	pluginURL := strings.TrimSpace(plugins[0])
	if len(pluginURL) > maxInterceptResourceURL {
		return "", fmt.Errorf("plugin URL exceeds %d bytes", maxInterceptResourceURL)
	}
	if err := validateRemoteModuleURL(pluginURL); err != nil {
		return "", fmt.Errorf("Loon plugin URL is invalid: %w", err)
	}
	return pluginURL, nil
}

func validateRemoteModuleURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("invalid URL: %w", err)
	}
	if u.Scheme != "https" {
		return errors.New("module resources must use https")
	}
	if u.Hostname() == "" || u.User != nil {
		return errors.New("module resource URL must have a host and no userinfo")
	}
	if u.Fragment != "" {
		return errors.New("module resource URL must not contain a fragment")
	}
	return nil
}

func moduleLogicalLines(body []byte) []string {
	scanner := bufio.NewScanner(bytes.NewReader(bytes.TrimPrefix(body, []byte{0xef, 0xbb, 0xbf})))
	scanner.Buffer(make([]byte, 4096), maxInterceptModuleSource)
	var lines []string
	var pending strings.Builder
	for scanner.Scan() {
		line := strings.TrimSuffix(scanner.Text(), "\r")
		trimmed := strings.TrimRight(line, " \t")
		continued := strings.HasSuffix(trimmed, "\\")
		if continued {
			trimmed = strings.TrimSuffix(trimmed, "\\")
		}
		pending.WriteString(trimmed)
		if continued {
			pending.WriteByte(' ')
			continue
		}
		lines = append(lines, pending.String())
		pending.Reset()
	}
	if pending.Len() > 0 {
		lines = append(lines, pending.String())
	}
	return lines
}

func parseMITMHosts(lines []string) ([]string, []string) {
	positive := map[string]struct{}{}
	negative := map[string]struct{}{}
	var unsupported []string
	for _, line := range lines {
		key, value, ok := strings.Cut(line, "=")
		if !ok || !strings.EqualFold(strings.TrimSpace(key), "hostname") {
			unsupported = append(unsupported, summarizeUnsupported("MITM", line, "only hostname is supported"))
			continue
		}
		for _, rawHost := range strings.Split(value, ",") {
			rawHost = strings.TrimSpace(rawHost)
			if rawHost == "" {
				continue
			}
			remove := strings.HasPrefix(rawHost, "-")
			rawHost = strings.TrimPrefix(rawHost, "-")
			host, err := normalizeInterceptHostPattern(rawHost)
			if err != nil {
				if remove {
					continue
				}
				unsupported = append(unsupported, summarizeUnsupported("MITM", rawHost, err.Error()))
				continue
			}
			if remove {
				negative[host] = struct{}{}
				continue
			}
			positive[host] = struct{}{}
		}
	}
	for host := range negative {
		delete(positive, host)
	}
	hosts := make([]string, 0, len(positive))
	for host := range positive {
		hosts = append(hosts, host)
	}
	return uniqueSortedStrings(hosts), unsupported
}

func parseModuleScriptLine(line string, index int) (interceptScriptRule, bool, []string, error) {
	match := loonScriptLine.FindStringSubmatch(line)
	if len(match) != 4 {
		return interceptScriptRule{}, false, nil, errors.New("unrecognized Script syntax")
	}
	phase := normalizeModulePhase(match[1])
	pattern := match[2]
	values := parseCommaKeyValues(match[3])
	if phase == "" {
		return interceptScriptRule{}, false, nil, nil
	}
	if pattern == "" {
		return interceptScriptRule{}, false, nil, errors.New("pattern is required")
	}
	if _, err := regexp.Compile(pattern); err != nil {
		return interceptScriptRule{}, false, nil, fmt.Errorf("pattern is outside the supported RE2 subset: %w", err)
	}
	scriptURL := values["script-path"]
	if scriptURL == "" {
		return interceptScriptRule{}, false, nil, errors.New("script-path is required")
	}
	timeoutMS := 5000
	if raw := values["timeout"]; raw != "" {
		seconds, err := strconv.ParseFloat(raw, 64)
		if err != nil || seconds <= 0 {
			return interceptScriptRule{}, false, nil, errors.New("timeout must be a positive number of seconds")
		}
		timeoutMS = int(seconds * 1000)
		if timeoutMS < 50 {
			timeoutMS = 50
		}
		if timeoutMS > 30000 {
			timeoutMS = 30000
		}
	}
	maxBody := int64(8 << 20)
	requiresBody := parseModuleBool(values["requires-body"])
	warnings := moduleScriptOptionWarnings(values)
	if raw := values["timeout"]; raw != "" {
		if seconds, err := strconv.ParseFloat(raw, 64); err == nil && seconds > 30 {
			warnings = append(warnings, "script timeout is capped at 30 seconds")
		}
	}
	warnings = uniqueSortedStrings(warnings)
	return interceptScriptRule{
		ID:           fmt.Sprintf("script-%03d", index+1),
		Phase:        phase,
		Pattern:      pattern,
		ScriptURL:    scriptURL,
		RequiresBody: requiresBody,
		BinaryBody:   parseModuleBool(values["binary-body-mode"]),
		TimeoutMS:    timeoutMS,
		MaxBodyBytes: maxBody,
		Argument:     values["argument"],
	}, true, warnings, nil
}

func moduleScriptOptionWarnings(values map[string]string) []string {
	allowed := map[string]struct{}{
		"script-path": {}, "requires-body": {}, "timeout": {}, "argument": {}, "tag": {},
		"enable": {}, "enabled": {}, "binary-body-mode": {},
	}
	var warnings []string
	for key := range values {
		if _, ok := allowed[key]; !ok {
			warnings = append(warnings, fmt.Sprintf("script option %q is unsupported", key))
		}
	}
	return uniqueSortedStrings(warnings)
}

func parseLoonRewriteLine(line string, index int) (*interceptRewriteRule, *interceptHeaderRule, error) {
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return nil, nil, errors.New("rewrite requires a pattern and action")
	}
	pattern := fields[0]
	if _, err := regexp.Compile(pattern); err != nil {
		return nil, nil, fmt.Errorf("pattern is outside the supported RE2 subset: %w", err)
	}
	action := strings.ReplaceAll(strings.ToLower(fields[1]), "_", "-")
	rule := interceptRewriteRule{ID: fmt.Sprintf("rewrite-%03d", index+1), Pattern: pattern}
	switch action {
	case "reject", "reject-dict", "reject-array", "reject-200", "reject-img", "reject-drop":
		if len(fields) != 2 {
			return nil, nil, fmt.Errorf("%s accepts no replacement", action)
		}
		rule.Action = action
	case "302", "307":
		if len(fields) != 3 || fields[2] == "-" {
			return nil, nil, errors.New("redirect rewrite requires one replacement")
		}
		rule.Action = "redirect-" + action
		rule.Replacement = fields[2]
	case "header":
		if len(fields) != 3 {
			return nil, nil, errors.New("header URL rewrite requires one replacement")
		}
		rule.Action = "rewrite"
		rule.Replacement = fields[2]
	case "header-del":
		if len(fields) != 3 || !validModuleHeaderName(fields[2]) {
			return nil, nil, errors.New("header-del requires one valid header name")
		}
		header := interceptHeaderRule{ID: fmt.Sprintf("header-%03d", index+1), Pattern: pattern, Operation: "delete", Header: fields[2]}
		return nil, &header, nil
	case "header-add", "header-replace":
		if len(fields) < 4 || !validModuleHeaderName(fields[2]) {
			return nil, nil, fmt.Errorf("%s requires a valid header name and value", action)
		}
		value := strings.Join(fields[3:], " ")
		if strings.ContainsAny(value, "\r\n") {
			return nil, nil, errors.New("header value contains a newline")
		}
		operation := "replace"
		if action == "header-add" {
			operation = "add"
		}
		header := interceptHeaderRule{ID: fmt.Sprintf("header-%03d", index+1), Pattern: pattern, Operation: operation, Header: fields[2], Value: value}
		return nil, &header, nil
	default:
		return nil, nil, fmt.Errorf("rewrite action %q is unsupported", action)
	}
	return &rule, nil, nil
}

func parseCommaKeyValues(raw string) map[string]string {
	result := make(map[string]string)
	for _, field := range splitModuleCSV(raw) {
		key, value, ok := strings.Cut(field, "=")
		if !ok {
			continue
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		if key != "" {
			result[key] = value
		}
	}
	return result
}

func splitModuleCSV(raw string) []string {
	var fields []string
	start := 0
	quote := rune(0)
	depth := 0
	escaped := false
	for index, r := range raw {
		if escaped {
			escaped = false
			continue
		}
		if r == '\\' && quote != 0 {
			escaped = true
			continue
		}
		if r == '\'' || r == '"' {
			if quote == 0 {
				quote = r
			} else if quote == r {
				quote = 0
			}
			continue
		}
		if quote == 0 {
			switch r {
			case '(', '[', '{':
				depth++
			case ')', ']', '}':
				if depth > 0 {
					depth--
				}
			}
		}
		if r == ',' && quote == 0 && depth == 0 {
			fields = append(fields, strings.TrimSpace(raw[start:index]))
			start = index + 1
		}
	}
	fields = append(fields, strings.TrimSpace(raw[start:]))
	return fields
}

func resolveModuleResourceURL(moduleURL, resource string) (string, error) {
	resource = strings.TrimSpace(strings.Trim(resource, `"'`))
	if resource == "" {
		return "", errors.New("script-path is empty")
	}
	u, err := url.Parse(resource)
	if err != nil {
		return "", err
	}
	if !u.IsAbs() {
		if moduleURL == "" {
			return "", errors.New("relative script-path requires a URL-based module import")
		}
		base, err := url.Parse(moduleURL)
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

func normalizeModulePhase(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "http-request":
		return interceptPhaseRequest
	case "http-response":
		return interceptPhaseResponse
	default:
		return ""
	}
}

func parseModuleBool(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func summarizeUnsupported(section, line, reason string) string {
	line = strings.TrimSpace(line)
	if len(line) > 160 {
		line = line[:157] + "..."
	}
	return fmt.Sprintf("[%s] %s (%s)", section, line, reason)
}

func moduleNameFromURL(raw string) string {
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	name := path.Base(u.Path)
	for _, suffix := range []string{".lpx", ".plugin", ".conf"} {
		name = strings.TrimSuffix(name, suffix)
	}
	return strings.TrimSpace(name)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func truncateUTF8Bytes(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	value = value[:limit]
	for !utf8.ValidString(value) {
		value = value[:len(value)-1]
	}
	return value
}
