package main

import (
	"context"
	"testing"
)

// interceptAttributionFixture publishes a snapshot with one enabled extension
// declaring a wildcard capture host. mitm controls whether the capture is live,
// which is the whole point of the two-state test below.
func interceptAttributionFixture(t *testing.T, h *Handler, mitm bool) {
	t.Helper()
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: mitm},
		ExecutionOrder: []string{"io.example.fixture"},
		Modules: []interceptModuleSnapshot{{
			ID:           "io.example.fixture",
			Name:         "Fixture extension",
			Enabled:      true,
			CaptureHosts: []string{"*.example.com"},
			CaptureDNS:   interceptCaptureDNSTrust,
		}},
	}
	h.setInterceptDocument(&document)
}

// An extension capture and an operator proxy rule must keep producing the same
// Verdict/Reason — handler.go's force-proxy counter branch and the overview
// donut both depend on that — so the ONLY thing that may distinguish them is
// the attribution.
func TestDecideName_InterceptCaptureKeepsForceProxyAndNamesTheExtension(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	interceptAttributionFixture(t, h, true)

	got := h.decideName("api.example.com")
	if want := (Verdict{Verdict: "proxy", Reason: "force-proxy"}); got.Verdict != want {
		t.Fatalf("verdict = %+v, want %+v — observability keys off this exact pair", got.Verdict, want)
	}
	if got.Action != actionGateway {
		t.Fatalf("action = %v, want actionGateway", got.Action)
	}
	if got.intercept == nil {
		t.Fatal("no intercept attribution: the diagnostic cannot say which extension fired")
	}
	if got.intercept.moduleID != "io.example.fixture" || got.intercept.moduleName != "Fixture extension" {
		t.Errorf("attribution = %+v, want the fixture's id and name", got.intercept)
	}
	if got.intercept.pattern != "*.example.com" {
		t.Errorf("matched pattern = %q, want the declared wildcard form", got.intercept.pattern)
	}
	if !got.interceptReady {
		t.Error("interceptReady = false while MITM is on")
	}
	if got.interceptTotal != 1 {
		t.Errorf("enabled extension count = %d, want 1", got.interceptTotal)
	}
	if got.policyRule != nil {
		t.Errorf("policy rule = %+v, want none — the capture table decided first", got.policyRule)
	}
}

// With MITM off the sidecar cannot terminate TLS, so steering the name to the
// gateway would black-hole it. The capture must be inert — but the extension is
// still listed as enabled in the console, so the diagnostic has to be able to
// say "declared, not in effect" rather than go silent.
func TestDecideName_MITMDisabledMakesTheCaptureInertButStillAttributed(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	interceptAttributionFixture(t, h, false)

	got := h.decideName("api.example.com")
	if got.Action == actionGateway {
		t.Fatal("name was steered to the gateway with MITM off — no sidecar can terminate it")
	}
	if got.Verdict.Reason == "force-proxy" {
		t.Fatalf("verdict = %+v, want the policy path's outcome, not a capture", got.Verdict)
	}
	if got.intercept == nil {
		t.Fatal("no attribution: an operator seeing the extension enabled cannot tell why it did nothing")
	}
	if got.interceptReady {
		t.Error("interceptReady = true while MITM is off")
	}
	if got.intercept.pattern != "*.example.com" {
		t.Errorf("declared pattern = %q, want *.example.com", got.intercept.pattern)
	}
}

// The negative case is a finding, not an absence: the UI states "N enabled,
// none declared this name", which needs the count even when nothing matched.
func TestDecideName_PolicyRuleIsAttributedWithItsDeclaration(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	interceptAttributionFixture(t, h, true)

	got := h.decideName("host.proxy.test")
	if want := (Verdict{Verdict: "proxy", Reason: "force-proxy"}); got.Verdict != want {
		t.Fatalf("verdict = %+v, want %+v", got.Verdict, want)
	}
	if got.intercept != nil {
		t.Errorf("intercept attribution = %+v, want none — no extension declared this name", got.intercept)
	}
	if got.interceptTotal != 1 {
		t.Errorf("enabled extension count = %d, want 1 even though none matched", got.interceptTotal)
	}
	if got.policyRule == nil {
		t.Fatal("no policy attribution: the diagnostic cannot say which rule fired")
	}
	if got.policyRule.Order != 2 || got.policyRule.Source.Kind != KindDomainSuffix || got.policyRule.Source.Value != "proxy.test" {
		t.Errorf("policy attribution = order %d, %s %q; want order 2, domain-suffix proxy.test",
			got.policyRule.Order, got.policyRule.Source.Kind, got.policyRule.Source.Value)
	}
}

func TestResolveTest_ReportsInterceptAttribution(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	interceptAttributionFixture(t, h, true)
	ctrl := &Controller{handler: h}

	res := ctrl.ResolveTest(context.Background(), "api.example.com")
	if res.Reason != "force-proxy" {
		t.Fatalf("reason = %q, want force-proxy", res.Reason)
	}
	if res.Intercept == nil {
		t.Fatal("result carries no intercept attribution")
	}
	if res.Intercept.ModuleName != "Fixture extension" || res.Intercept.MatchedHost != "*.example.com" || !res.Intercept.Ready {
		t.Errorf("intercept = %+v, want the fixture named and ready", res.Intercept)
	}
	if res.Intercept.Reason != "" {
		t.Errorf("intercept reason = %q, want empty when ready", res.Intercept.Reason)
	}
	if res.Policy != nil {
		t.Errorf("policy = %+v, want none", res.Policy)
	}
	if res.InterceptModuleCount != 1 {
		t.Errorf("intercept_module_count = %d, want 1", res.InterceptModuleCount)
	}
}

func TestResolveTest_ReportsPolicyAttributionAndNoIntercept(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	interceptAttributionFixture(t, h, true)
	ctrl := &Controller{handler: h}

	res := ctrl.ResolveTest(context.Background(), "host.proxy.test")
	if res.Reason != "force-proxy" {
		t.Fatalf("reason = %q, want force-proxy", res.Reason)
	}
	if res.Intercept != nil {
		t.Errorf("intercept = %+v, want none — this is the contrast case", res.Intercept)
	}
	if res.Policy == nil {
		t.Fatal("result carries no policy attribution")
	}
	if res.Policy.Order != 2 || res.Policy.Kind != string(KindDomainSuffix) || res.Policy.Value != "proxy.test" {
		t.Errorf("policy = %+v, want order 2 domain-suffix proxy.test", res.Policy)
	}
	if res.InterceptModuleCount != 1 {
		t.Errorf("intercept_module_count = %d, want 1 so the UI can say 'none of 1 declared it'", res.InterceptModuleCount)
	}
}

func TestResolveTest_MITMDisabledIsReportedAsNotReady(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	interceptAttributionFixture(t, h, false)
	ctrl := &Controller{handler: h}

	res := ctrl.ResolveTest(context.Background(), "api.example.com")
	if res.Intercept == nil {
		t.Fatal("result carries no intercept attribution for a declared-but-inert capture")
	}
	if res.Intercept.Ready {
		t.Error("ready = true with MITM off")
	}
	if res.Intercept.Reason != "mitm-disabled" {
		t.Errorf("reason = %q, want mitm-disabled", res.Intercept.Reason)
	}
	if res.Reason == "force-proxy" {
		t.Errorf("reason = %q — an inert capture must not steer the name", res.Reason)
	}
}

// The gate lives in CaptureDNS alone; lookup is deliberately ungated so the
// diagnostic can see declarations MITM is suppressing. If a future edit moves
// the gate into lookup, the mitm-disabled reporting goes silent — this pins
// both halves.
func TestInterceptHostSnapshot_GateAppliesToCaptureDNSNotLookup(t *testing.T) {
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: false},
		ExecutionOrder: []string{"io.example.fixture"},
		Modules: []interceptModuleSnapshot{{
			ID:           "io.example.fixture",
			Name:         "Fixture extension",
			Enabled:      true,
			CaptureHosts: []string{"host.example.com"},
			CaptureDNS:   interceptCaptureDNSTrust,
		}},
	}
	snapshot := newInterceptHostSnapshot(document)

	if _, _, matched := snapshot.CaptureDNS("host.example.com"); matched {
		t.Error("CaptureDNS matched with MITM off — resolution would black-hole the name")
	}
	if snapshot.Match("host.example.com") {
		t.Error("Match matched with MITM off")
	}
	binding, ok := snapshot.lookup("host.example.com")
	if !ok {
		t.Fatal("lookup missed a declared host: the diagnostic loses the mitm-disabled case")
	}
	if binding.pattern != "host.example.com" || binding.moduleName != "Fixture extension" {
		t.Errorf("binding = %+v, want the exact pattern and the module name", binding)
	}
	if snapshot.moduleCount != 1 {
		t.Errorf("moduleCount = %d, want 1", snapshot.moduleCount)
	}
}
