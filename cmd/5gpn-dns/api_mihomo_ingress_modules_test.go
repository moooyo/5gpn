package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
)

func getIngressModules(t *testing.T, fx *mihomoTestFixture) mihomoIngressModulesResponse {
	t.Helper()
	rec := doAPI(fx.cs, http.MethodGet, "/api/mihomo/ingress-modules", nil, fx.token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET ingress modules status=%d body=%s", rec.Code, rec.Body.String())
	}
	return decodeJSON[mihomoIngressModulesResponse](t, rec)
}

func requireIngressModule(t *testing.T, response mihomoIngressModulesResponse, id string) mihomoIngressModuleView {
	t.Helper()
	module := ingressModuleViewByID(response.Modules, id)
	if module == nil {
		t.Fatalf("module %q missing from catalog: %+v", id, response.Modules)
	}
	return *module
}

func TestMihomoIngressModules_EnableDisableRoundTrip(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	operatorText := "# operator-owned comment\ncustom-extension:\n  untouched: true\n" + fx.golden
	if err := os.WriteFile(fx.store.Path(), []byte(operatorText), 0o660); err != nil {
		t.Fatal(err)
	}

	before := getIngressModules(t, fx)
	if before.Revision != mihomoConfigRevision(operatorText) || len(before.Modules) != 2 {
		t.Fatalf("unexpected initial catalog: %+v", before)
	}
	module := before.Modules[0]
	if module.ID != speedtestModuleID || !module.Enabled || !module.Manageable {
		t.Fatalf("initial module = %+v, want enabled/manageable", module)
	}
	if module.Port != 5060 || strings.Join(module.Networks, ",") != "tcp,udp" || strings.Join(module.Sniffers, ",") != "http,tls,quic" {
		t.Fatalf("static module capabilities = %+v", module)
	}

	moduleRules := speedtestModuleGuardRules(fx.infra)
	disableBody, _ := json.Marshal(map[string]any{"enabled": false, "revision": before.Revision})
	disabledRec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, disableBody, fx.token, true)
	if disabledRec.Code != http.StatusOK {
		t.Fatalf("disable status=%d body=%s", disabledRec.Code, disabledRec.Body.String())
	}
	disabled := decodeJSON[mihomoIngressModulesResponse](t, disabledRec)
	if disabled.Modules[0].Enabled || !disabled.Modules[0].Manageable || disabled.Revision == before.Revision {
		t.Fatalf("disabled catalog = %+v", disabled)
	}
	if fx.tester.calls != 1 || fx.ctl.putCalls != 1 {
		t.Fatalf("disable validation/apply calls = %d/%d, want 1/1", fx.tester.calls, fx.ctl.putCalls)
	}
	disabledText, err := fx.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(disabledText, "# operator-owned comment") || !strings.Contains(disabledText, "custom-extension:") {
		t.Fatalf("operator comments/unknown fields were not preserved:\n%s", disabledText)
	}
	if view := analyzeSpeedtestModule(disabledText, fx.infra).View; view.Enabled || !view.Manageable {
		t.Fatalf("on-disk disabled module = %+v", view)
	}
	for _, rule := range moduleRules {
		if strings.Contains(disabledText, rule) {
			t.Fatalf("disabled module retained local-service guard %q", rule)
		}
	}
	backup, err := os.ReadFile(fx.store.BackupPath())
	if err != nil {
		t.Fatal(err)
	}
	if string(backup) != operatorText {
		t.Fatal("module disable backup does not contain the exact old bytes")
	}

	enableBody, _ := json.Marshal(map[string]any{"enabled": true, "revision": disabled.Revision})
	enabledRec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, enableBody, fx.token, true)
	if enabledRec.Code != http.StatusOK {
		t.Fatalf("enable status=%d body=%s", enabledRec.Code, enabledRec.Body.String())
	}
	enabled := decodeJSON[mihomoIngressModulesResponse](t, enabledRec)
	if !enabled.Modules[0].Enabled || !enabled.Modules[0].Manageable || enabled.Revision == disabled.Revision {
		t.Fatalf("enabled catalog = %+v", enabled)
	}
	if fx.tester.calls != 2 || fx.ctl.putCalls != 2 {
		t.Fatalf("round-trip validation/apply calls = %d/%d, want 2/2", fx.tester.calls, fx.ctl.putCalls)
	}
	onDisk, err := fx.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	analysis := analyzeSpeedtestModule(onDisk, fx.infra)
	if !analysis.View.Enabled || !analysis.View.Manageable {
		t.Fatalf("on-disk enabled module = %+v", analysis.View)
	}
	moduleTargetFound := false
	for _, listener := range analysis.Listeners.Content {
		name, _ := mappingScalar(listener, "name")
		target, _ := mappingScalar(listener, "target")
		if name == "gateway5060" && target == fx.infra.ConsoleDomain+":5060" {
			moduleTargetFound = true
		}
	}
	if !moduleTargetFound {
		t.Fatal("enabled module listener must use the same-port console hostname target")
	}
	for _, rule := range moduleRules {
		if !strings.Contains(onDisk, rule) {
			t.Fatalf("enabled module is missing local-service guard %q", rule)
		}
	}
	if strings.Index(onDisk, moduleRules[0]) > strings.Index(onDisk, "DOMAIN,"+fx.infra.ConsoleDomain+",DIRECT") {
		t.Fatal("module local-service guards must precede console/zash accepting rules")
	}
	backup, err = os.ReadFile(fx.store.BackupPath())
	if err != nil {
		t.Fatal(err)
	}
	if string(backup) != disabledText {
		t.Fatal("module enable backup does not contain the exact disabled bytes")
	}
}

func TestMihomoIngressModules_BlockQUIC443RoundTrip(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	before := getIngressModules(t, fx)
	module := requireIngressModule(t, before, blockQUICModuleID)
	if !module.Enabled || !module.Manageable || module.Port != 443 || strings.Join(module.Networks, ",") != "udp" || len(module.Sniffers) != 0 {
		t.Fatalf("initial QUIC block module = %+v", module)
	}

	disableBody, _ := json.Marshal(map[string]any{"enabled": false, "revision": before.Revision})
	disabledRec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+blockQUICModuleID, disableBody, fx.token, true)
	if disabledRec.Code != http.StatusOK {
		t.Fatalf("disable status=%d body=%s", disabledRec.Code, disabledRec.Body.String())
	}
	disabled := decodeJSON[mihomoIngressModulesResponse](t, disabledRec)
	if module := requireIngressModule(t, disabled, blockQUICModuleID); module.Enabled || !module.Manageable {
		t.Fatalf("disabled QUIC block module = %+v", module)
	}
	disabledText, err := fx.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(disabledText, blockQUICRuleBase) {
		t.Fatalf("disabled QUIC block retained its rule:\n%s", disabledText)
	}

	enableBody, _ := json.Marshal(map[string]any{"enabled": true, "revision": disabled.Revision})
	enabledRec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+blockQUICModuleID, enableBody, fx.token, true)
	if enabledRec.Code != http.StatusOK {
		t.Fatalf("enable status=%d body=%s", enabledRec.Code, enabledRec.Body.String())
	}
	enabled := decodeJSON[mihomoIngressModulesResponse](t, enabledRec)
	if module := requireIngressModule(t, enabled, blockQUICModuleID); !module.Enabled || !module.Manageable {
		t.Fatalf("enabled QUIC block module = %+v", module)
	}
	onDisk, err := fx.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	egressTerminatorIndex := strings.Index(onDisk, interceptEgressRejectRule)
	blockIndex := strings.Index(onDisk, blockQUICRuleBase+",REJECT")
	matchIndex := strings.Index(onDisk, "MATCH,Proxies")
	if egressTerminatorIndex < 0 || blockIndex <= egressTerminatorIndex || matchIndex <= blockIndex || strings.Count(onDisk, blockQUICRuleBase) != 1 {
		t.Fatalf("QUIC block rule ordering is not canonical:\n%s", onDisk)
	}
	if fx.tester.calls != 2 || fx.ctl.putCalls != 2 {
		t.Fatalf("QUIC block validation/apply calls = %d/%d, want 2/2", fx.tester.calls, fx.ctl.putCalls)
	}
}

func TestMihomoIngressModules_BlockQUIC443RejectsCustomShape(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	custom := strings.Replace(fx.golden, blockQUICRuleBase+",REJECT", blockQUICRuleBase+",DIRECT", 1)
	if err := os.WriteFile(fx.store.Path(), []byte(custom), 0o660); err != nil {
		t.Fatal(err)
	}
	response := getIngressModules(t, fx)
	module := requireIngressModule(t, response, blockQUICModuleID)
	if module.Manageable || module.Reason != "partial-or-custom-quic-block" {
		t.Fatalf("custom QUIC block module = %+v", module)
	}
}

func TestMihomoIngressModules_MultipleCanonicalGatewayBinds(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	multi := strings.Replace(fx.golden,
		renderMihomoListeners([]string{"203.0.113.10"}, fx.infra.ConsoleDomain),
		renderMihomoListeners([]string{"203.0.113.10", "198.51.100.20"}, fx.infra.ConsoleDomain), 1)
	if err := os.WriteFile(fx.store.Path(), []byte(multi), 0o660); err != nil {
		t.Fatal(err)
	}
	text, err := fx.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	analysis := analyzeSpeedtestModule(text, fx.infra)
	if !analysis.View.Enabled || len(analysis.Gateways) != 2 {
		t.Fatalf("multi-bind analysis = %+v gateways=%+v", analysis.View, analysis.Gateways)
	}
	for _, want := range []string{"gateway5060", "gateway5060-2"} {
		found := false
		for _, listener := range analysis.Listeners.Content {
			if name, ok := mappingScalar(listener, "name"); ok && name == want {
				target, targetOK := mappingScalar(listener, "target")
				if !targetOK || target != fx.infra.ConsoleDomain+":5060" {
					t.Fatalf("generated listener %q target = %q", want, target)
				}
				found = true
			}
		}
		if !found {
			t.Fatalf("missing generated listener %q", want)
		}
	}
}

func TestMihomoIngressModules_LegacyLoopbackGatewayIsUnmanageable(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	legacy := fx.golden
	for _, port := range []string{"443", "80", "8080", "8443"} {
		oldTarget := "target: " + fx.infra.ConsoleDomain + ":" + port + "}"
		newTarget := "target: 127.0.0.1:" + port + "}"
		changed := strings.Replace(legacy, oldTarget, newTarget, 1)
		if changed == legacy {
			t.Fatalf("fixture does not contain %q", oldTarget)
		}
		legacy = changed
	}
	legacy = strings.Replace(legacy, "  force-domain: ["+fx.infra.ConsoleDomain+"]\n", "", 1)
	if err := ValidateInvariants(legacy, fx.infra); err != nil {
		t.Fatalf("legacy operator-owned loopback config should remain valid: %v", err)
	}
	view := analyzeSpeedtestModule(legacy, fx.infra).View
	if view.Manageable || view.Reason != "canonical-gateway-conflict" {
		t.Fatalf("legacy loopback config = %+v, want canonical gateway conflict", view)
	}
}

func TestMihomoIngressModules_RejectsStaleRevisionWithoutSideEffects(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	before := getIngressModules(t, fx)
	newText := fx.golden + "\n# concurrent operator edit\n"
	if err := os.WriteFile(fx.store.Path(), []byte(newText), 0o660); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]any{"enabled": false, "revision": before.Revision})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, body, fx.token, true)
	if rec.Code != http.StatusConflict {
		t.Fatalf("stale revision status=%d body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Revision string `json:"revision"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Revision != mihomoConfigRevision(newText) {
		t.Fatalf("conflict revision=%q want current revision", resp.Revision)
	}
	if fx.tester.calls != 0 || fx.ctl.putCalls != 0 {
		t.Fatalf("stale update reached validator/controller: %d/%d", fx.tester.calls, fx.ctl.putCalls)
	}
	if got, _ := fx.store.Read(); got != newText {
		t.Fatal("stale update changed the operator config")
	}
}

func TestMihomoIngressModules_RecognizesAlternateYAMLIntegerSpellings(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	enabledText, err := renderSpeedtestModule(analyzeSpeedtestModule(fx.golden, fx.infra), true)
	if err != nil {
		t.Fatal(err)
	}
	alternate := strings.ReplaceAll(enabledText, "port: 5060", "port: 0x13c4")
	alternate = strings.ReplaceAll(alternate, ", 5060]", ", 5_060]")
	if alternate == enabledText {
		t.Fatal("test fixture did not rewrite any 5060 integers")
	}
	analysis := analyzeSpeedtestModule(alternate, fx.infra)
	if !analysis.View.Enabled || !analysis.View.Manageable {
		t.Fatalf("alternate integer spellings were not recognized: %+v", analysis.View)
	}
	disabledText, err := renderSpeedtestModule(analysis, false)
	if err != nil {
		t.Fatal(err)
	}
	if view := analyzeSpeedtestModule(disabledText, fx.infra).View; view.Enabled || !view.Manageable {
		t.Fatalf("semantic 5060 entries were not removed cleanly: %+v", view)
	}
}

func TestMihomoIngressModules_DetectsExternalEditDuringValidation(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	before := getIngressModules(t, fx)
	externalText := fx.golden + "\n# external edit during validation\n"
	fx.tester.onTest = func() {
		if err := os.WriteFile(fx.store.Path(), []byte(externalText), 0o660); err != nil {
			t.Errorf("external edit: %v", err)
		}
	}
	body, _ := json.Marshal(map[string]any{"enabled": false, "revision": before.Revision})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, body, fx.token, true)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status=%d want 409 body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Revision string `json:"revision"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Revision != mihomoConfigRevision(externalText) {
		t.Fatalf("revision=%q want external edit revision", resp.Revision)
	}
	if got, _ := fx.store.Read(); got != externalText {
		t.Fatal("module candidate overwrote external edit made during validation")
	}
	if fx.tester.calls != 1 || fx.ctl.putCalls != 0 {
		t.Fatalf("validation/controller calls=%d/%d want 1/0", fx.tester.calls, fx.ctl.putCalls)
	}
}

func TestMihomoIngressModules_PartialCustomAndAliasAreUnmanageable(t *testing.T) {
	tests := []struct {
		name string
		edit func(string) string
	}{
		{
			name: "partial sniffer port",
			edit: func(text string) string {
				return strings.Replace(text, "HTTP: { ports: [80, 8080, 8443, 5060] }", "HTTP: { ports: [80, 8080, 8443] }", 1)
			},
		},
		{
			name: "custom listener",
			edit: func(text string) string {
				return strings.Replace(text, "listeners:\n", "listeners:\n  - {name: operator-5060, type: tunnel, listen: 203.0.113.10, port: 5060, network: [tcp], target: 127.0.0.1:9999}\n", 1)
			},
		},
		{
			name: "alias",
			edit: func(text string) string {
				text = strings.Replace(text, "log-level: info\n", "log-level: info\nx-gateway-network: &gateway-network [tcp, udp]\n", 1)
				return strings.Replace(text, "network: [tcp, udp]", "network: *gateway-network", 1)
			},
		},
		{
			name: "sniff port range",
			edit: func(text string) string {
				return strings.Replace(text, "TLS:  { ports: [443, 8080, 8443, 5060] }", `TLS:  { ports: [443, 8080, 8443, 5060, "5000-6000"] }`, 1)
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fx := newMihomoConfigTestFixture(t)
			changed := tc.edit(fx.golden)
			if err := os.WriteFile(fx.store.Path(), []byte(changed), 0o660); err != nil {
				t.Fatal(err)
			}
			catalog := getIngressModules(t, fx)
			if catalog.Modules[0].Manageable {
				t.Fatalf("conflicting config reported manageable: %+v", catalog.Modules[0])
			}
			body, _ := json.Marshal(map[string]any{"enabled": true, "revision": catalog.Revision})
			rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, body, fx.token, true)
			if rec.Code != http.StatusConflict {
				t.Fatalf("conflicting PUT status=%d body=%s", rec.Code, rec.Body.String())
			}
			if fx.tester.calls != 0 || fx.ctl.putCalls != 0 {
				t.Fatalf("conflicting PUT reached validator/controller: %d/%d", fx.tester.calls, fx.ctl.putCalls)
			}
		})
	}
}

func TestMihomoIngressModules_DisableRejectsCustomizedEnabledModule(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	initial := analyzeSpeedtestModule(fx.golden, fx.infra)
	enabledText, err := renderSpeedtestModule(initial, true)
	if err != nil {
		t.Fatal(err)
	}
	enabled := analyzeSpeedtestModule(enabledText, fx.infra)
	for _, listener := range enabled.Listeners.Content {
		name, _ := mappingScalar(listener, "name")
		if name == "gateway5060" {
			network := mappingNodeValue(listener, "network")
			network.Content = network.Content[:1]
		}
	}
	customized, err := encodeMihomoNode(enabled.Document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fx.store.Path(), []byte(customized), 0o660); err != nil {
		t.Fatal(err)
	}
	catalog := getIngressModules(t, fx)
	if catalog.Modules[0].Manageable || catalog.Modules[0].Enabled {
		t.Fatalf("customized enabled module = %+v, want conflict", catalog.Modules[0])
	}
	body, _ := json.Marshal(map[string]any{"enabled": false, "revision": catalog.Revision})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, body, fx.token, true)
	if rec.Code != http.StatusConflict {
		t.Fatalf("customized disable status=%d body=%s", rec.Code, rec.Body.String())
	}
	if got, _ := fx.store.Read(); got != customized {
		t.Fatal("conflicting disable changed the customized operator config")
	}
}

func TestMihomoIngressModules_PartialLocalServiceGuardIsUnmanageable(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	rules := speedtestModuleGuardRules(fx.infra)
	enabledText, err := renderSpeedtestModule(analyzeSpeedtestModule(fx.golden, fx.infra), true)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		edit func(string) string
	}{
		{
			name: "missing guard",
			edit: func(text string) string {
				return strings.Replace(text, "- "+rules[1]+"\n", "", 1)
			},
		},
		{
			name: "custom guard action",
			edit: func(text string) string {
				return strings.Replace(text, rules[1], strings.TrimSuffix(rules[1], "REJECT")+"DIRECT", 1)
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			changed := tc.edit(enabledText)
			if changed == enabledText {
				t.Fatal("enabled fixture did not change")
			}
			view := analyzeSpeedtestModule(changed, fx.infra).View
			if view.Manageable || view.Enabled {
				t.Fatalf("partial/custom local-service guard reported manageable: %+v", view)
			}
		})
	}
}

func TestMihomoIngressModules_RequiresAllFailClosedGuardsBeforeMatch(t *testing.T) {
	guards := []string{
		"  - IP-CIDR,10.0.1.20/32,REJECT,no-resolve\n",
		"  - IP-CIDR,127.0.0.0/8,REJECT,no-resolve\n",
		"  - IP-CIDR,10.0.0.0/8,REJECT,no-resolve\n",
		"  - IP-CIDR,172.16.0.0/12,REJECT,no-resolve\n",
		"  - IP-CIDR,192.168.0.0/16,REJECT,no-resolve\n",
		"  - IP-CIDR,100.64.0.0/10,REJECT,no-resolve\n",
		"  - IP-CIDR,169.254.0.0/16,REJECT,no-resolve\n",
	}
	for _, guard := range guards {
		t.Run(strings.TrimSpace(guard), func(t *testing.T) {
			fx := newMihomoConfigTestFixture(t)
			changed := strings.Replace(fx.golden, guard, "", 1)
			if changed == fx.golden {
				t.Fatalf("fixture does not contain guard %q", guard)
			}
			view := analyzeSpeedtestModule(changed, fx.infra).View
			if view.Manageable {
				t.Fatalf("config missing %q reported manageable", strings.TrimSpace(guard))
			}
		})
	}

	fx := newMihomoConfigTestFixture(t)
	guard := "  - IP-CIDR,127.0.0.0/8,REJECT,no-resolve\n"
	changed := strings.Replace(fx.golden, guard, "", 1)
	changed = strings.Replace(changed, "  - MATCH,Proxies\n", "  - MATCH,Proxies\n"+guard, 1)
	if analyzeSpeedtestModule(changed, fx.infra).View.Manageable {
		t.Fatal("guard after terminal MATCH must not satisfy the module safety gate")
	}

	fx = newMihomoConfigTestFixture(t)
	firstGuard := "  - IP-CIDR,10.0.1.20/32,REJECT,no-resolve\n"
	changed = strings.Replace(fx.golden, firstGuard, "  - DST-PORT,5060,DIRECT\n"+firstGuard, 1)
	if analyzeSpeedtestModule(changed, fx.infra).View.Manageable {
		t.Fatal("an accepting rule before the guards must make the module unmanageable")
	}
}

func TestMihomoIngressModules_RequiresCanonicalSnifferBooleans(t *testing.T) {
	for _, key := range []string{"enable", "parse-pure-ip", "override-destination"} {
		t.Run(key, func(t *testing.T) {
			fx := newMihomoConfigTestFixture(t)
			changed := strings.Replace(fx.golden, "  "+key+": true\n", "  "+key+": false\n", 1)
			if changed == fx.golden {
				t.Fatalf("fixture does not contain sniffer.%s", key)
			}
			if analyzeSpeedtestModule(changed, fx.infra).View.Manageable {
				t.Fatalf("sniffer.%s=false reported manageable", key)
			}
		})
	}

	for _, tc := range []struct {
		protocol string
		before   string
		after    string
	}{
		{
			protocol: "HTTP",
			before:   "HTTP: { ports: [80, 8080, 8443, 5060] }",
			after:    "HTTP: { ports: [80, 8080, 8443, 5060], override-destination: false }",
		},
		{
			protocol: "TLS",
			before:   "TLS:  { ports: [443, 8080, 8443, 5060] }",
			after:    "TLS:  { ports: [443, 8080, 8443, 5060], override-destination: false }",
		},
		{
			protocol: "QUIC",
			before:   "QUIC: { ports: [443, 5060] }",
			after:    "QUIC: { ports: [443, 5060], override-destination: false }",
		},
	} {
		t.Run(tc.protocol+" override-destination", func(t *testing.T) {
			fx := newMihomoConfigTestFixture(t)
			changed := strings.Replace(fx.golden, tc.before, tc.after, 1)
			if changed == fx.golden {
				t.Fatalf("fixture does not contain sniffer.sniff.%s", tc.protocol)
			}
			if analyzeSpeedtestModule(changed, fx.infra).View.Manageable {
				t.Fatalf("sniffer.sniff.%s.override-destination=false reported manageable", tc.protocol)
			}
		})
	}
}

type rollbackTestController struct {
	putCalls int
}

func (c *rollbackTestController) PutConfigs(_ context.Context, _ string) error {
	c.putCalls++
	if c.putCalls == 1 {
		return errors.New("candidate controller apply failed")
	}
	return nil
}

func (c *rollbackTestController) Status(_ context.Context) MihomoStatus {
	return MihomoStatus{Reachable: true, Authenticated: true}
}

func TestMihomoIngressModules_HotApplyFailureRollsBackDiskAndController(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	ctl := &rollbackTestController{}
	fx.cs.SetMihomoConfig(fx.store, fx.infra, fx.tester, ctl)
	before := getIngressModules(t, fx)
	body, _ := json.Marshal(map[string]any{"enabled": false, "revision": before.Revision})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, body, fx.token, true)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("hot-apply failure status=%d body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Revision           string `json:"revision"`
		Error              string `json:"error"`
		CandidatePublished bool   `json:"candidate_published"`
		RollbackComplete   bool   `json:"rollback_complete"`
		Written            *bool  `json:"written"`
		Rollback           struct {
			DiskRestored               bool `json:"disk_restored"`
			ControllerRestoreAttempted bool `json:"controller_restore_attempted"`
			ControllerRestored         bool `json:"controller_restored"`
		} `json:"rollback"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if !resp.Rollback.DiskRestored || !resp.Rollback.ControllerRestoreAttempted || !resp.Rollback.ControllerRestored {
		t.Fatalf("rollback response = %+v body=%s", resp.Rollback, rec.Body.String())
	}
	if !resp.CandidatePublished || !resp.RollbackComplete || resp.Written != nil || !strings.Contains(resp.Error, "previous config restored") {
		t.Fatalf("rollback summary is misleading: %+v body=%s", resp, rec.Body.String())
	}
	if ctl.putCalls != 2 {
		t.Fatalf("controller calls=%d, want candidate apply + old-config restore", ctl.putCalls)
	}
	if got, _ := fx.store.Read(); got != fx.golden {
		t.Fatalf("disk was not restored to exact old bytes:\n%s", got)
	}
	if resp.Revision != before.Revision {
		t.Fatalf("rollback revision=%q want old revision %q", resp.Revision, before.Revision)
	}
	backup, err := os.ReadFile(fx.store.BackupPath())
	if err != nil || string(backup) != fx.golden {
		t.Fatalf("backup missing or wrong after rollback: err=%v", err)
	}
}

func TestMihomoIngressModules_ValidationFailureLeavesLiveConfigUntouched(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	fx.tester.err = errors.New("mihomo -t rejected candidate")
	before := getIngressModules(t, fx)
	body, _ := json.Marshal(map[string]any{"enabled": false, "revision": before.Revision})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, body, fx.token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("validation failure status=%d body=%s", rec.Code, rec.Body.String())
	}
	if fx.tester.calls != 1 || fx.ctl.putCalls != 0 {
		t.Fatalf("validation/controller calls=%d/%d, want 1/0", fx.tester.calls, fx.ctl.putCalls)
	}
	if got, _ := fx.store.Read(); got != fx.golden {
		t.Fatal("validation failure changed the live config")
	}
	if _, err := os.Stat(fx.store.BackupPath()); !os.IsNotExist(err) {
		t.Fatalf("validation failure unexpectedly wrote backup: %v", err)
	}
}

func TestMihomoIngressModules_StrictBodyAndUnknownModule(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	revision := getIngressModules(t, fx).Revision
	tests := []struct {
		name string
		path string
		body string
		want int
	}{
		{"missing enabled", speedtestModuleID, `{"revision":"` + revision + `"}`, http.StatusBadRequest},
		{"missing revision", speedtestModuleID, `{"enabled":true}`, http.StatusBadRequest},
		{"unknown field", speedtestModuleID, `{"enabled":true,"revision":"` + revision + `","extra":1}`, http.StatusBadRequest},
		{"unknown module", "other", `{"enabled":true,"revision":"` + revision + `"}`, http.StatusNotFound},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+tc.path, []byte(tc.body), fx.token, true)
			if rec.Code != tc.want {
				t.Fatalf("status=%d want=%d body=%s", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
	if fx.tester.calls != 0 || fx.ctl.putCalls != 0 {
		t.Fatalf("invalid requests reached validator/controller: %d/%d", fx.tester.calls, fx.ctl.putCalls)
	}
}
