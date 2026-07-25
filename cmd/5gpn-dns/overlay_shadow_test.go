package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// Shadow comparison between the legacy YAML renderer and the overlay compiler.
//
// Section 12.1 step 4 of the review makes this a prerequisite for switching
// drivers: the same desired state must compile to the same policy through both
// paths, and any place it does not has to be a known, stated difference rather
// than a surprise found in production.
//
// The comparison runs against a real interception document, not a fixture.
// Fixtures agree with the compiler that produced them; only real operator state
// exercises the combinations nobody thought to write down. Point
// SHADOW_INTERCEPT_CONFIG at an exported /etc/5gpn/intercept/config.json:
//
//	SHADOW_INTERCEPT_CONFIG=/path/to/config.json go test -run Shadow -v ./...
//
// The file carries live SOCKS credentials, so it is deliberately not committed.

const shadowConfigEnv = "SHADOW_INTERCEPT_CONFIG"

func loadShadowDocument(t *testing.T) interceptConfigDocument {
	t.Helper()
	path := os.Getenv(shadowConfigEnv)
	if path == "" {
		t.Skipf("set %s to an exported interception document to run the shadow comparison", shadowConfigEnv)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var doc interceptConfigDocument
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	return doc
}

// selectorKey is the comparable identity of one capture decision: which traffic
// is steered at the processor.
type selectorKey struct {
	Kind  string
	Value string
	Port  int
}

func (s selectorKey) String() string { return fmt.Sprintf("%s,%s:%d", s.Kind, s.Value, s.Port) }

// parseLegacyCaptureRule turns a rendered capture rule back into its selector.
//
//	AND,((DOMAIN,example.test),(DST-PORT,443)),MODULE-INTERCEPT
func parseLegacyCaptureRule(rule string) (selectorKey, bool) {
	suffix := "))," + interceptMihomoProxyName
	if !strings.HasSuffix(rule, suffix) || !strings.HasPrefix(rule, "AND,((") {
		return selectorKey{}, false
	}
	body := strings.TrimSuffix(strings.TrimPrefix(rule, "AND,(("), suffix)
	// body: DOMAIN,example.test),(DST-PORT,443
	parts := strings.Split(body, "),(")
	if len(parts) != 2 {
		return selectorKey{}, false
	}
	kindValue := strings.SplitN(parts[0], ",", 2)
	if len(kindValue) != 2 {
		return selectorKey{}, false
	}
	portPart := strings.TrimPrefix(parts[1], "DST-PORT,")
	port, err := strconv.Atoi(portPart)
	if err != nil {
		return selectorKey{}, false
	}
	return selectorKey{Kind: kindValue[0], Value: kindValue[1], Port: port}, true
}

// overlayKindToLegacy maps a typed selector kind back to the legacy spelling so
// the two sets are comparable.
func overlayKindToLegacy(kind overlaySelectorKind) string {
	switch kind {
	case overlaySelectorDomain:
		return "DOMAIN"
	case overlaySelectorDomainSuffix:
		return "DOMAIN-SUFFIX"
	case overlaySelectorDomainWildcard:
		return "DOMAIN-WILDCARD"
	case overlaySelectorDomainKeyword:
		return "DOMAIN-KEYWORD"
	case overlaySelectorIPCIDR:
		return "IP-CIDR"
	}
	return string(kind)
}

// The capture set is the security-relevant half: it decides which traffic is
// diverted to the processor at all. The two compilers must agree on it exactly.
// A host the overlay misses is silently un-intercepted; one it adds is traffic
// the operator never authorized for capture.
func TestShadowCaptureSetsAreIdentical(t *testing.T) {
	doc := loadShadowDocument(t)

	legacy := map[selectorKey]struct{}{}
	for _, rule := range interceptMihomoRouting(doc).Capture {
		key, ok := parseLegacyCaptureRule(rule)
		if !ok {
			t.Fatalf("could not parse a legacy capture rule: %q", rule)
		}
		legacy[key] = struct{}{}
	}

	compiled, err := compileOverlayGeneration(overlayCompileInput{
		Document: doc, MatchTarget: "Proxies", DocumentRevision: "shadow",
		Transition: overlayTransitionRevoke,
	})
	if err != nil {
		t.Fatalf("overlay compile: %v", err)
	}
	overlaySet := map[selectorKey]struct{}{}
	for _, rule := range compiled.Client.Rules {
		if rule.Action != overlayActionCapture {
			continue
		}
		if len(rule.Ports) != 1 || rule.Ports[0].From != rule.Ports[0].To {
			t.Fatalf("capture rule has a non-singular port range: %+v", rule)
		}
		overlaySet[selectorKey{
			Kind:  overlayKindToLegacy(rule.Kind),
			Value: rule.Value,
			Port:  int(rule.Ports[0].From),
		}] = struct{}{}
	}

	t.Logf("legacy capture selectors: %d, overlay capture selectors: %d", len(legacy), len(overlaySet))

	var missing, extra []string
	for k := range legacy {
		if _, ok := overlaySet[k]; !ok {
			missing = append(missing, k.String())
		}
	}
	for k := range overlaySet {
		if _, ok := legacy[k]; !ok {
			extra = append(extra, k.String())
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)

	if len(missing) > 0 {
		t.Errorf("the overlay does not capture %d selector(s) the legacy renderer does; first 10: %v",
			len(missing), firstN(missing, 10))
	}
	if len(extra) > 0 {
		t.Errorf("the overlay captures %d selector(s) the legacy renderer does not; first 10: %v",
			len(extra), firstN(extra, 10))
	}
}

// The typed client stage cannot express every rule the string renderer can.
// That is a real, bounded limitation and it must be measured rather than
// assumed away: a routing rule that silently disappears is a deny the operator
// reviewed and approved that stops being enforced.
func TestShadowPolicyRuleCoverage(t *testing.T) {
	doc := loadShadowDocument(t)

	total := 0
	dropped := map[string][]string{}
	for _, module := range orderedEnabledInterceptModules(doc) {
		for _, route := range module.RoutingRules {
			total++
			if _, ok := overlayPolicyRule(route, module.ID); !ok {
				dropped[module.ID] = append(dropped[module.ID], renderInterceptPolicyRule(route))
			}
		}
	}

	droppedCount := 0
	for _, list := range dropped {
		droppedCount += len(list)
	}
	t.Logf("routing rules: %d total, %d expressible in the typed overlay, %d not",
		total, total-droppedCount, droppedCount)
	for id, list := range dropped {
		t.Logf("  %s: %d inexpressible; e.g. %v", id, len(list), firstN(list, 3))
	}

	if droppedCount > 0 {
		t.Errorf("%d of %d reviewed routing rules cannot be expressed in the typed client stage; "+
			"committing this generation would stop enforcing them", droppedCount, total)
	}
}

// Every enabled module must end up with an egress capability whose group is the
// one the legacy renderer would have targeted. The enforcement point differs —
// legacy matches per selector, the overlay resolves a capability — but the
// group each module's traffic leaves through must not.
func TestShadowEgressGroupsAgree(t *testing.T) {
	doc := loadShadowDocument(t)
	const matchTarget = "Proxies"

	compiled, err := compileOverlayGeneration(overlayCompileInput{
		Document: doc, MatchTarget: matchTarget, DocumentRevision: "shadow",
		Transition: overlayTransitionRevoke,
	})
	if err != nil {
		t.Fatalf("overlay compile: %v", err)
	}

	byGroup := map[string]overlayEgressCapability{}
	for _, c := range compiled.Egress.Capabilities {
		byGroup[c.Group] = c
	}

	wanted := map[string][]string{}
	for _, module := range orderedEnabledInterceptModules(doc) {
		group := module.EgressGroup
		if group == "" {
			group = matchTarget
		}
		wanted[group] = append(wanted[group], module.ID)
	}

	t.Logf("egress groups in use: %d, capabilities minted: %d", len(wanted), len(byGroup))
	for group, modules := range wanted {
		cap, ok := byGroup[group]
		if !ok {
			t.Errorf("no capability was minted for group %q (needed by %v)", group, modules)
			continue
		}
		t.Logf("  %-24s -> %s (allowDirect=%v) for %v", group, cap.ID, cap.AllowDirect, modules)
		// A group the operator explicitly bound must not be allowed to resolve
		// to DIRECT behind their back.
		if group != matchTarget && cap.AllowDirect {
			t.Errorf("capability for explicitly bound group %q allows DIRECT", group)
		}
	}
	for group := range byGroup {
		if _, ok := wanted[group]; !ok {
			t.Errorf("a capability was minted for group %q, which no enabled module uses", group)
		}
	}
}

// The generation id must be a pure function of the desired state even on real
// input, or a coordinator restart mid-transaction cannot recognise its own
// prepared generation.
func TestShadowGenerationIDIsStableOnRealInput(t *testing.T) {
	doc := loadShadowDocument(t)
	in := overlayCompileInput{
		Document: doc, MatchTarget: "Proxies", DocumentRevision: "shadow",
		Transition: overlayTransitionRevoke,
	}
	a, err := compileOverlayGeneration(in)
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	for i := 0; i < 5; i++ {
		b, err := compileOverlayGeneration(in)
		if err != nil {
			t.Fatalf("compile %d: %v", i, err)
		}
		if a.GenerationID != b.GenerationID {
			t.Fatalf("generation id is unstable: %q vs %q", a.GenerationID, b.GenerationID)
		}
	}
	t.Logf("generation %s: %d client rules, %d capabilities",
		a.GenerationID, len(a.Client.Rules), len(a.Egress.Capabilities))
}

// The fork's fixed quotas have to be large enough for real operator state, or
// the first real commit is rejected.
func TestShadowFitsWithinCoreQuotas(t *testing.T) {
	doc := loadShadowDocument(t)
	compiled, err := compileOverlayGeneration(overlayCompileInput{
		Document: doc, MatchTarget: "Proxies", DocumentRevision: "shadow",
		Transition: overlayTransitionRevoke,
	})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	// Mirrors overlay.DefaultQuotas() in the mihomo fork.
	const (
		maxClientRules      = 4096
		maxCapabilities     = 64
		maxProcessorTargets = 8
	)
	t.Logf("client rules %d/%d, capabilities %d/%d, processor targets %d/%d",
		len(compiled.Client.Rules), maxClientRules,
		len(compiled.Egress.Capabilities), maxCapabilities,
		len(compiled.ProcessorTargets), maxProcessorTargets)

	if len(compiled.Client.Rules) > maxClientRules {
		t.Errorf("client rules %d exceed the core quota of %d", len(compiled.Client.Rules), maxClientRules)
	}
	if len(compiled.Egress.Capabilities) > maxCapabilities {
		t.Errorf("capabilities %d exceed the core quota of %d", len(compiled.Egress.Capabilities), maxCapabilities)
	}
}

func firstN(list []string, n int) []string {
	if len(list) <= n {
		return list
	}
	return list[:n]
}

// TestShadowEmitGeneration writes the compiled generation to disk so it can be
// committed to a real core.
//
// This is a tool, not an assertion: the point is to drive a live mihomo with a
// generation derived from actual operator state rather than from a fixture,
// which is the only way to find out whether the two ends really agree on the
// wire format.
func TestShadowEmitGeneration(t *testing.T) {
	out := os.Getenv("SHADOW_EMIT_GENERATION")
	if out == "" {
		t.Skip("set SHADOW_EMIT_GENERATION to write the compiled generation")
	}
	doc := loadShadowDocument(t)
	compiled, err := compileOverlayGeneration(overlayCompileInput{
		Document: doc, MatchTarget: "Proxies", DocumentRevision: "shadow",
		Transition: overlayTransitionRevoke,
	})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	raw, err := json.MarshalIndent(compiled, "", "  ")
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if err := os.WriteFile(out, raw, 0o600); err != nil {
		t.Fatalf("write %s: %v", out, err)
	}

	captureHosts := map[string]int{}
	for _, r := range compiled.Client.Rules {
		if r.Action == overlayActionCapture {
			captureHosts[r.Owner]++
		}
	}
	t.Logf("wrote %s: generation %s, %d rules", out, compiled.GenerationID, len(compiled.Client.Rules))
	for owner, n := range captureHosts {
		t.Logf("  capture rules from %s: %d", owner, n)
	}
}
