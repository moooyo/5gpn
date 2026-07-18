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

const defaultModuleReferer = "https://hub.kelee.one/"

var loonScriptLine = regexp.MustCompile(`(?i)^(http-request|http-response)\s+(\S+)\s+(.+)$`)
var headerRewriteLine = regexp.MustCompile(`(?i)^(\S+)\s+(header-del|header-replace|header-replace-regex)\s+(\S+)(?:\s+(.+))?$`)
var disabledScriptOption = regexp.MustCompile(`(?i)(?:^|,)\s*enabled?\s*=\s*(?:false|0|off|no)(?:\s*,|\s*$)`)

type interceptModuleImportRequest struct {
	Revision       string `json:"revision"`
	URL            string `json:"url,omitempty"`
	Content        string `json:"content,omitempty"`
	Format         string `json:"format,omitempty"`
	FetchProfile   string `json:"fetch_profile,omitempty"`
	Referer        string `json:"referer,omitempty"`
	Argument       string `json:"argument,omitempty"`
	PartialAllowed bool   `json:"partial_allowed"`
}

type interceptModuleParser struct {
	resolver HostResolver
	now      func() time.Time
	client   *http.Client
}

func (p interceptModuleParser) Import(ctx context.Context, request interceptModuleImportRequest) (interceptModuleSnapshot, error) {
	if request.Format == "" {
		request.Format = "auto"
	}
	if request.Format != "auto" && request.Format != interceptModuleFormatSurge && request.Format != interceptModuleFormatLoon {
		return interceptModuleSnapshot{}, errors.New("format must be auto, surge, or loon")
	}
	if request.FetchProfile == "" {
		request.FetchProfile = interceptFetchStandard
	}
	if request.FetchProfile != interceptFetchStandard && request.FetchProfile != interceptFetchQuantumultX {
		return interceptModuleSnapshot{}, errors.New("fetch_profile must be standard or quantumult-x")
	}
	if len(request.Argument) > maxInterceptModuleArg {
		return interceptModuleSnapshot{}, fmt.Errorf("argument exceeds %d bytes", maxInterceptModuleArg)
	}
	if len(request.URL) > maxInterceptResourceURL || len(request.Referer) > maxInterceptResourceURL {
		return interceptModuleSnapshot{}, fmt.Errorf("URL or Referer exceeds %d bytes", maxInterceptResourceURL)
	}
	if strings.TrimSpace(request.URL) == "" && request.Content == "" {
		return interceptModuleSnapshot{}, errors.New("exactly one of url or content is required")
	}
	if strings.TrimSpace(request.URL) != "" && request.Content != "" {
		return interceptModuleSnapshot{}, errors.New("url and content are mutually exclusive")
	}
	if request.FetchProfile == interceptFetchQuantumultX && strings.TrimSpace(request.Referer) == "" {
		request.Referer = defaultModuleReferer
	}
	if request.Referer != "" {
		if err := validateModuleReferer(request.Referer); err != nil {
			return interceptModuleSnapshot{}, err
		}
	}

	sourceURL := strings.TrimSpace(request.URL)
	sourceBody := []byte(request.Content)
	if sourceURL != "" {
		var err error
		sourceBody, sourceURL, err = p.fetchResource(ctx, sourceURL, request.FetchProfile, request.Referer, maxInterceptModuleSource)
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

	format := detectModuleFormat(request.Format, sourceURL, sourceBody)
	parsed, err := p.parse(ctx, format, sourceURL, sourceBody, request)
	if err != nil {
		return interceptModuleSnapshot{}, err
	}
	if p.now == nil {
		p.now = time.Now
	}
	digest := sha256Hex(sourceBody)
	parsed.ID = "mod-" + digest[:32]
	parsed.Format = format
	parsed.Enabled = false
	parsed.Argument = request.Argument
	parsed.ImportedAt = p.now().UTC().Format(time.RFC3339)
	parsed.Source = interceptModuleSource{
		URL:          sourceURL,
		Digest:       digest,
		Body:         string(sourceBody),
		FetchProfile: request.FetchProfile,
		Referer:      request.Referer,
	}
	parsed.PartialAllowed = request.PartialAllowed
	if err := validateInterceptModule(parsed); err != nil {
		return interceptModuleSnapshot{}, err
	}
	return parsed, nil
}

func (p interceptModuleParser) parse(
	ctx context.Context,
	format, sourceURL string,
	sourceBody []byte,
	request interceptModuleImportRequest,
) (interceptModuleSnapshot, error) {
	lines := moduleLogicalLines(sourceBody)
	metadata := map[string]string{}
	sections := make(map[string][]string)
	section := ""
	for _, original := range lines {
		line := strings.TrimSpace(original)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#!") {
			if key, value, ok := strings.Cut(strings.TrimPrefix(line, "#!"), "="); ok {
				metadata[strings.ToLower(strings.TrimSpace(key))] = strings.TrimSpace(value)
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
	}
	if arguments := metadata["arguments"]; arguments != "" {
		module.Unsupported = append(module.Unsupported, summarizeUnsupported("Metadata", "#!arguments="+arguments, "template argument schemas are not expanded; scripts receive the configured raw $argument"))
	}
	if strings.Contains(string(sourceBody), "{{{") {
		module.Unsupported = append(module.Unsupported, "[Template] Triple-brace module placeholders are not expanded")
	}
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
		rule, supported, optionWarnings, parseErr := parseModuleScriptLine(format, line, index)
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
			scriptBody, parseErr = p.fetch(ctx, scriptURL, request.FetchProfile, request.Referer, maxInterceptScriptSource)
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
		for _, warning := range scriptCompatibilityWarnings(rule.ScriptBody) {
			module.Unsupported = append(module.Unsupported, summarizeUnsupported("Script", scriptURL, warning))
		}
		if rule.Argument == "" {
			rule.Argument = request.Argument
		}
		module.Scripts = append(module.Scripts, rule)
	}

	for _, sectionName := range []string{"url rewrite", "rewrite"} {
		for index, line := range sections[sectionName] {
			rule, err := parseModuleRewriteLine(line, len(module.Rewrites)+index)
			if err != nil {
				module.Unsupported = append(module.Unsupported, summarizeUnsupported(sectionName, line, err.Error()))
				continue
			}
			module.Rewrites = append(module.Rewrites, rule)
		}
	}
	for index, line := range sections["header rewrite"] {
		rule, err := parseModuleHeaderLine(line, index)
		if err != nil {
			module.Unsupported = append(module.Unsupported, summarizeUnsupported("Header Rewrite", line, err.Error()))
			continue
		}
		module.Headers = append(module.Headers, rule)
	}

	for sectionName, sectionLines := range sections {
		switch sectionName {
		case "mitm", "script", "url rewrite", "rewrite", "header rewrite":
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
	module.Unsupported = uniqueSortedStrings(module.Unsupported)
	if len(module.Unsupported) > 64 {
		module.Unsupported = append(module.Unsupported[:63], "Additional unsupported directives were omitted from this view")
	}
	return module, nil
}

func parseModuleHeaderLine(line string, index int) (interceptHeaderRule, error) {
	match := headerRewriteLine.FindStringSubmatch(line)
	if len(match) != 5 {
		return interceptHeaderRule{}, errors.New("unrecognized Header Rewrite syntax")
	}
	rule := interceptHeaderRule{
		ID:      fmt.Sprintf("header-%03d", index+1),
		Pattern: match[1],
		Header:  match[3],
	}
	if _, err := regexp.Compile(rule.Pattern); err != nil {
		return interceptHeaderRule{}, fmt.Errorf("pattern is outside the supported RE2 subset: %w", err)
	}
	if !validModuleHeaderName(rule.Header) {
		return interceptHeaderRule{}, errors.New("header name is invalid")
	}
	remainder := strings.TrimSpace(match[4])
	switch strings.ToLower(match[2]) {
	case "header-del":
		if remainder != "" {
			return interceptHeaderRule{}, errors.New("header-del accepts no value")
		}
		rule.Operation = "delete"
	case "header-replace":
		if remainder == "" {
			return interceptHeaderRule{}, errors.New("header-replace requires a value")
		}
		rule.Operation = "replace"
		rule.Value = strings.Trim(remainder, `"'`)
	case "header-replace-regex":
		valuePattern, replacement, ok := strings.Cut(remainder, " ")
		if !ok || strings.TrimSpace(valuePattern) == "" || strings.TrimSpace(replacement) == "" {
			return interceptHeaderRule{}, errors.New("header-replace-regex requires a value pattern and replacement")
		}
		if _, err := regexp.Compile(valuePattern); err != nil {
			return interceptHeaderRule{}, fmt.Errorf("value pattern is outside the supported RE2 subset: %w", err)
		}
		rule.Operation = "replace-regex"
		rule.ValuePattern = valuePattern
		rule.Replacement = strings.Trim(strings.TrimSpace(replacement), `"'`)
	}
	return rule, nil
}

func scriptCompatibilityWarnings(source string) []string {
	checks := []struct {
		needle  string
		message string
	}{
		{"$httpClient", "outbound script networking is disabled"},
		{"$task.fetch", "outbound script networking is disabled"},
		{"require(", "CommonJS require is unavailable"},
		{"setTimeout(", "asynchronous timers are unavailable"},
		{"bodyBytes", "binary body compatibility is unavailable"},
	}
	warnings := make([]string, 0, len(checks))
	for _, check := range checks {
		if strings.Contains(source, check.needle) {
			warnings = append(warnings, check.message)
		}
	}
	return uniqueSortedStrings(warnings)
}

func (p interceptModuleParser) fetch(ctx context.Context, rawURL, profile, referer string, limit int64) ([]byte, error) {
	body, _, err := p.fetchResource(ctx, rawURL, profile, referer, limit)
	return body, err
}

func (p interceptModuleParser) fetchResource(ctx context.Context, rawURL, profile, referer string, limit int64) ([]byte, string, error) {
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
		setModuleFetchHeaders(req, profile, referer)
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, "", err
	}
	setModuleFetchHeaders(req, profile, referer)
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

func setModuleFetchHeaders(request *http.Request, profile, referer string) {
	request.Header.Set("Accept", "text/plain, application/javascript, */*;q=0.1")
	if profile == interceptFetchQuantumultX {
		request.Header.Set("User-Agent", "Quantumult X")
	} else {
		request.Header.Set("User-Agent", "5gpn-module-import/1")
	}
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
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

func validateModuleReferer(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		return errors.New("referer must be an https URL with a host and no userinfo or fragment")
	}
	if strings.ContainsAny(raw, "\r\n") {
		return errors.New("referer contains a newline")
	}
	return nil
}

func detectModuleFormat(requested, sourceURL string, body []byte) string {
	if requested == interceptModuleFormatSurge || requested == interceptModuleFormatLoon {
		return requested
	}
	lowerURL := strings.ToLower(sourceURL)
	if strings.HasSuffix(lowerURL, ".lpx") || bytes.Contains(bytes.ToLower(body), []byte("script-path=")) && bytes.Contains(bytes.ToLower(body), []byte("tag=")) {
		return interceptModuleFormatLoon
	}
	return interceptModuleFormatSurge
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
		value = strings.ReplaceAll(value, "%APPEND%", "")
		value = strings.ReplaceAll(value, "%append%", "")
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

func parseModuleScriptLine(format, line string, index int) (interceptScriptRule, bool, []string, error) {
	values := map[string]string{}
	phase := ""
	pattern := ""
	if left, right, ok := strings.Cut(line, "="); ok && strings.Contains(strings.ToLower(right), "type=") {
		values = parseCommaKeyValues(right)
		phase = normalizeModulePhase(values["type"])
		pattern = values["pattern"]
		if values["name"] == "" {
			values["name"] = strings.TrimSpace(left)
		}
	} else if match := loonScriptLine.FindStringSubmatch(line); len(match) == 4 {
		phase = normalizeModulePhase(match[1])
		pattern = match[2]
		values = parseCommaKeyValues(match[3])
	} else {
		return interceptScriptRule{}, false, nil, errors.New("unrecognized Script syntax")
	}
	if phase == "" {
		return interceptScriptRule{}, false, nil, nil
	}
	if pattern == "" {
		return interceptScriptRule{}, false, nil, errors.New("pattern is required")
	}
	if _, err := regexp.Compile(pattern); err != nil {
		return interceptScriptRule{}, false, nil, fmt.Errorf("pattern is outside the supported RE2 subset: %w", err)
	}
	scriptURL := firstNonEmpty(values["script-path"], values["script_path"], values["script"])
	if scriptURL == "" {
		return interceptScriptRule{}, false, nil, errors.New("script-path is required")
	}
	timeoutMS := 5000
	if raw := firstNonEmpty(values["timeout"], values["script-timeout"]); raw != "" {
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
	if raw := firstNonEmpty(values["max-size"], values["max_size"]); raw != "" && raw != "0" {
		if raw == "-1" {
			maxBody = 64 << 20
		} else {
			parsed, err := strconv.ParseInt(raw, 10, 64)
			if err != nil || parsed < 1 {
				return interceptScriptRule{}, false, nil, errors.New("max-size must be a positive byte count, zero, or -1")
			}
			maxBody = min(parsed, int64(64<<20))
		}
	}
	requiresBody := parseModuleBool(firstNonEmpty(values["requires-body"], values["requires_body"]))
	warnings := moduleScriptOptionWarnings(values)
	if raw := firstNonEmpty(values["timeout"], values["script-timeout"]); raw != "" {
		if seconds, err := strconv.ParseFloat(raw, 64); err == nil && seconds > 30 {
			warnings = append(warnings, "script timeout is capped at 30 seconds")
		}
	}
	if raw := firstNonEmpty(values["max-size"], values["max_size"]); raw == "-1" {
		warnings = append(warnings, "unlimited max-size is capped at 67108864 bytes")
	} else if parsed, err := strconv.ParseInt(raw, 10, 64); err == nil && parsed > 64<<20 {
		warnings = append(warnings, "max-size is capped at 67108864 bytes")
	}
	warnings = uniqueSortedStrings(warnings)
	return interceptScriptRule{
		ID:           fmt.Sprintf("script-%03d", index+1),
		Phase:        phase,
		Pattern:      pattern,
		ScriptURL:    scriptURL,
		RequiresBody: requiresBody,
		TimeoutMS:    timeoutMS,
		MaxBodyBytes: maxBody,
		Argument:     firstNonEmpty(values["argument"], values["args"]),
	}, true, warnings, nil
}

func moduleScriptOptionWarnings(values map[string]string) []string {
	allowed := map[string]struct{}{
		"type": {}, "pattern": {}, "name": {}, "script-path": {}, "script_path": {}, "script": {},
		"requires-body": {}, "requires_body": {}, "timeout": {}, "script-timeout": {}, "max-size": {}, "max_size": {},
		"argument": {}, "args": {}, "tag": {}, "debug": {}, "enable": {}, "enabled": {}, "update-interval": {}, "script-update-interval": {},
		"binary-body-mode": {}, "binary_body_mode": {}, "engine": {},
	}
	var warnings []string
	for key := range values {
		if _, ok := allowed[key]; !ok {
			warnings = append(warnings, fmt.Sprintf("script option %q is unsupported", key))
		}
	}
	if parseModuleBool(firstNonEmpty(values["binary-body-mode"], values["binary_body_mode"])) {
		warnings = append(warnings, "binary body mode is unavailable")
	}
	if engine := strings.TrimSpace(values["engine"]); engine != "" && !strings.EqualFold(engine, "auto") {
		warnings = append(warnings, fmt.Sprintf("script engine %q is unavailable", engine))
	}
	return uniqueSortedStrings(warnings)
}

func parseModuleRewriteLine(line string, index int) (interceptRewriteRule, error) {
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return interceptRewriteRule{}, errors.New("rewrite requires a pattern and action")
	}
	pattern := fields[0]
	if _, err := regexp.Compile(pattern); err != nil {
		return interceptRewriteRule{}, fmt.Errorf("pattern is outside the supported RE2 subset: %w", err)
	}
	action := strings.ToLower(fields[len(fields)-1])
	rule := interceptRewriteRule{ID: fmt.Sprintf("rewrite-%03d", index+1), Pattern: pattern}
	switch action {
	case "reject", "reject-dict", "reject-array", "reject-200":
		rule.Action = action
	case "302", "307":
		if len(fields) < 3 || fields[1] == "-" {
			return interceptRewriteRule{}, errors.New("redirect rewrite requires a replacement")
		}
		rule.Action = "redirect-" + action
		rule.Replacement = fields[1]
	default:
		return interceptRewriteRule{}, fmt.Errorf("rewrite action %q is unsupported", action)
	}
	return rule, nil
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
	for _, suffix := range []string{".sgmodule", ".lpx", ".plugin", ".conf"} {
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
