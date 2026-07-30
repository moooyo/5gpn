package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// --- compiler ---------------------------------------------------------------

func overlayTestDocument() interceptConfigDocument {
	return interceptConfigDocument{
		Version:  interceptConfigVersion,
		Username: "module-in-abcdefghijklmno",
		Password: "module-in-password-abcdefghijklmnop",
		UpstreamProxy: interceptProxyConfig{
			Username: "module-up-abcdefghijklmno",
			Password: "module-up-password-abcdefghijklmnop",
		},
		MITM:           interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{"alpha", "beta"},
		Modules: []interceptModuleSnapshot{
			{
				ID:           "alpha",
				Enabled:      true,
				CaptureHosts: []string{"ads.example.test"},
				EgressGroup:  "Proxies",
				RoutingRules: interceptRoutingRuleList{
					{Action: "reject", Domain: "tracker.example.test"},
				},
			},
			{
				ID:           "beta",
				Enabled:      true,
				CaptureHosts: []string{"api.example.test"},
			},
		},
	}
}

func compileForTest(t *testing.T, doc interceptConfigDocument, transition overlayTransitionMode) overlayDocument {
	t.Helper()
	out, err := compileOverlayGeneration(overlayCompileInput{
		Document:         doc,
		MatchTarget:      "Proxies",
		DocumentRevision: "rev-1",
		Transition:       transition,
	})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	return out
}

// Extension deny rules must precede capture rules. Reversing the two would let
// a capture rule shadow a deny the operator explicitly reviewed and approved.
func TestOverlayCompilePutsPolicyBeforeCapture(t *testing.T) {
	doc := compileForTest(t, overlayTestDocument(), overlayTransitionRevoke)

	firstCapture := -1
	lastPolicy := -1
	for i, r := range doc.Client.Rules {
		if r.Action == overlayActionCapture && firstCapture < 0 {
			firstCapture = i
		}
		if r.Action != overlayActionCapture {
			lastPolicy = i
		}
	}
	if firstCapture < 0 || lastPolicy < 0 {
		t.Fatalf("expected both policy and capture rules, got %+v", doc.Client.Rules)
	}
	if lastPolicy > firstCapture {
		t.Fatalf("a policy rule at %d follows the first capture rule at %d", lastPolicy, firstCapture)
	}
}

// The capability id must be exactly the credential the processor authenticates
// with. Anything else authorizes nothing, and the failure is silent: every
// egress dial simply rejects, which looks like a network problem rather than a
// configuration one.
func TestOverlayCapabilityIsThePresentedCredential(t *testing.T) {
	src := overlayTestDocument()
	doc := compileForTest(t, src, overlayTransitionRevoke)

	// Both modules resolve to "Proxies" here — one by an explicit binding, the
	// other through the terminal MATCH target — so there is one group to mint
	// for.
	if len(doc.Egress.Capabilities) != 1 {
		t.Fatalf("got %d capabilities, want exactly 1: both modules resolve to one group", len(doc.Egress.Capabilities))
	}
	cap := doc.Egress.Capabilities[0]
	if cap.ID != src.UpstreamProxy.Username {
		t.Fatalf("capability id = %q, want the processor's credential %q", cap.ID, src.UpstreamProxy.Username)
	}
	if cap.Listener != interceptEgressListenerName {
		t.Fatalf("capability listener = %q, want %q", cap.Listener, interceptEgressListenerName)
	}
	if len(cap.Bindings) == 0 {
		t.Fatal("the capability carries no bindings; it would authorize nothing")
	}
	for _, bind := range cap.Bindings {
		if len(bind.Destinations) == 0 {
			t.Fatalf("binding for %q carries no destination allowlist; it would authorize any endpoint", bind.Group)
		}
	}
}

// One bound extension alongside one unbound one is the ordinary arrangement, and
// it resolves to two groups: the bound one and the operator's terminal MATCH
// target. Refusing it made enabling the MITM master impossible on any gateway
// whose extensions did not all agree on a single group.
//
// The credential does not select the group — the destination does. So there is
// one capability carrying the one credential the processor can present, and one
// binding per group inside it.
func TestOverlayMintsOneBindingPerEgressGroup(t *testing.T) {
	src := overlayTestDocument()
	src.Modules[1].EgressGroup = "SecondGroup"

	doc, err := compileOverlayGeneration(overlayCompileInput{
		Document: src, MatchTarget: "Proxies", DocumentRevision: "rev-1",
		Transition: overlayTransitionRevoke,
	})
	if err != nil {
		t.Fatalf("two egress groups were refused: %v", err)
	}

	// One credential means one capability, whatever the group count. Emitting
	// several that share an id is what the core refuses outright.
	if len(doc.Egress.Capabilities) != 1 {
		t.Fatalf("got %d capabilities for one credential, want exactly 1", len(doc.Egress.Capabilities))
	}
	capability := doc.Egress.Capabilities[0]
	if capability.ID != src.UpstreamProxy.Username {
		t.Errorf("capability has id %q, which the processor cannot present", capability.ID)
	}
	if capability.Listener != interceptEgressListenerName {
		t.Errorf("capability is valid on %q, not the egress listener", capability.Listener)
	}

	byGroup := map[string]overlayEgressBinding{}
	for _, bind := range capability.Bindings {
		if _, dup := byGroup[bind.Group]; dup {
			t.Fatalf("group %q got two bindings", bind.Group)
		}
		byGroup[bind.Group] = bind
		if len(bind.Destinations) == 0 {
			t.Errorf("binding for %q carries no destination allowlist", bind.Group)
		}
	}
	for _, group := range []string{"Proxies", "SecondGroup"} {
		if _, ok := byGroup[group]; !ok {
			t.Fatalf("no binding was minted for group %q; its extension has no egress at all", group)
		}
	}

	// Disjoint destination sets are the property that makes the capability set
	// unambiguous: no endpoint appears in two of them, so which group a
	// connection leaves through cannot depend on the order the core evaluates
	// capabilities in.
	owner := map[string]string{}
	for _, bind := range capability.Bindings {
		for _, d := range bind.Destinations {
			key := string(d.Kind) + "|" + d.Value + "|" + strconv.Itoa(int(d.Ports[0].From))
			if previous, dup := owner[key]; dup {
				t.Errorf("destination %s is claimed by both %q and %q", key, previous, bind.Group)
			}
			owner[key] = bind.Group
		}
	}
}

// An operator who binds an extension to the built-in DIRECT group has asked for
// unproxied egress in the one way the UI offers. A capability for that group
// that forbids DIRECT is self-contradictory, and the extension's upstream traffic
// simply stops.
func TestOverlayDirectBindingAllowsDirect(t *testing.T) {
	src := overlayTestDocument()
	src.Modules[0].EgressGroup = "DIRECT"

	doc, err := compileOverlayGeneration(overlayCompileInput{
		Document: src, MatchTarget: "Proxies", DocumentRevision: "rev-1",
		Transition: overlayTransitionRevoke,
	})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	for _, bind := range overlayBindingsOf(doc) {
		switch bind.Group {
		case "DIRECT":
			if !bind.AllowDirect {
				t.Error("the binding for an explicit DIRECT binding forbids DIRECT")
			}
		case "Proxies":
			// The terminal MATCH target; the operator's own global default may
			// legitimately resolve to DIRECT.
			if !bind.AllowDirect {
				t.Error("the binding for the terminal MATCH target forbids DIRECT")
			}
		}
	}

	// A named selector group is a different matter: it can be pointing anywhere
	// at any moment, so binding to it is not consent to unproxied egress.
	src.Modules[0].EgressGroup = "Japan"
	doc, err = compileOverlayGeneration(overlayCompileInput{
		Document: src, MatchTarget: "Proxies", DocumentRevision: "rev-1",
		Transition: overlayTransitionRevoke,
	})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	for _, bind := range overlayBindingsOf(doc) {
		if bind.Group == "Japan" && bind.AllowDirect {
			t.Error("a binding for an explicitly bound selector group allows DIRECT")
		}
	}
}

// overlayBindingsOf flattens every binding across every capability. There is
// only ever one capability, but reading them all keeps the helper honest if
// that ever stops being true.
func overlayBindingsOf(doc overlayDocument) []overlayEgressBinding {
	var out []overlayEgressBinding
	for _, c := range doc.Egress.Capabilities {
		out = append(out, c.Bindings...)
	}
	return out
}

// The allowlist must cover exactly the destinations the enabled extensions
// declare. One it omits is denied when it should be reachable; one it adds is
// reachable when it should be denied.
func TestOverlayDestinationAllowlistCoversDeclaredDestinations(t *testing.T) {
	src := overlayTestDocument()
	doc := compileForTest(t, src, overlayTransitionRevoke)

	want := map[string]struct{}{}
	for _, module := range orderedEnabledInterceptModules(src) {
		for _, sel := range interceptModuleEgressSelectors(module) {
			kind, ok := overlayKindFor(sel.Kind)
			if !ok {
				continue
			}
			want[string(kind)+"|"+sel.Value+"|"+strconv.Itoa(sel.Port)] = struct{}{}
		}
	}
	got := map[string]struct{}{}
	for _, bind := range overlayBindingsOf(doc) {
		for _, d := range bind.Destinations {
			got[string(d.Kind)+"|"+d.Value+"|"+strconv.Itoa(int(d.Ports[0].From))] = struct{}{}
		}
	}

	for k := range want {
		if _, ok := got[k]; !ok {
			t.Errorf("the allowlist omits %s, which the legacy path permitted", k)
		}
	}
	for k := range got {
		if _, ok := want[k]; !ok {
			t.Errorf("the allowlist adds %s, which the legacy path denied", k)
		}
	}
}

// An enabled master with nothing to capture must mint no capability at all.
//
// The alternative is a capability whose destination allowlist is present but
// empty, and "empty" and "absent" are the same JSON to a core that treats a
// missing allowlist as unrestricted — which would hand the processor the
// operator's egress group for any endpoint it cared to dial, at exactly the
// moment no extension has authorized a single one.
func TestOverlayEnabledMasterWithNoModulesMintsNoCapability(t *testing.T) {
	src := overlayTestDocument()
	for i := range src.Modules {
		src.Modules[i].Enabled = false
	}
	doc := compileForTest(t, src, overlayTransitionRevoke)

	if len(doc.Egress.Capabilities) != 0 {
		t.Fatalf("got %d capabilities with no enabled extension: %+v",
			len(doc.Egress.Capabilities), doc.Egress.Capabilities)
	}
}

// The generation id must be a function of the desired state, so that
// re-preparing after a crash produces the same id — which is what makes
// prepare idempotent and a lost response recoverable.
func TestOverlayGenerationIDIsDeterministic(t *testing.T) {
	a := compileForTest(t, overlayTestDocument(), overlayTransitionRevoke)
	b := compileForTest(t, overlayTestDocument(), overlayTransitionRevoke)
	if a.GenerationID != b.GenerationID {
		t.Fatalf("identical desired state produced %q and %q", a.GenerationID, b.GenerationID)
	}

	changed := overlayTestDocument()
	changed.Modules[0].CaptureHosts = []string{"other.example.test"}
	c, err := compileOverlayGeneration(overlayCompileInput{
		Document: changed, MatchTarget: "Proxies", DocumentRevision: "rev-1",
		Transition: overlayTransitionRevoke,
	})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	if c.GenerationID == a.GenerationID {
		t.Fatal("a changed capture host produced the same generation id")
	}
}

// The id must be a function of the whole TRANSACTION, not just the desired
// state it lands on. mihomo's store keys generations by id and refuses to
// re-stage one whose stored digest differs — and that digest covers the parent,
// the transition, and the artifact digests, none of which the id used to.
//
// Turning the MITM master off and back on walks exactly this path: the enable
// reaches the same routing state the disable revoked, but from a different
// parent. With an id derived only from the desired state the two collided, the
// store rejected the second with "already exists with a different document",
// and the box was stuck — a revoked id can never be staged again, so there was
// no way forward without hand-editing mihomo's state directory.
func TestOverlayGenerationIDSeparatesTransactionsThatShareADesiredState(t *testing.T) {
	compile := func(parent string, transition overlayTransitionMode) overlayDocument {
		t.Helper()
		out, err := compileOverlayGeneration(overlayCompileInput{
			Document:         overlayTestDocument(),
			MatchTarget:      "Proxies",
			DocumentRevision: "rev-1",
			ParentGeneration: parent,
			Transition:       transition,
		})
		if err != nil {
			t.Fatalf("compile: %v", err)
		}
		return out
	}

	first := compile("", overlayTransitionRevoke)
	// The same desired state re-reached after a disable: identical rules and
	// capabilities, but superseding the generation the disable committed.
	afterDisable := compile("g-the-disable", overlayTransitionRevoke)
	if first.GenerationID == afterDisable.GenerationID {
		t.Fatalf("returning to a desired state from a different parent reused id %q; "+
			"the store would reject the re-stage and the master switch becomes a one-way door",
			first.GenerationID)
	}

	// Transition mode is likewise part of the transaction and part of the digest.
	graceful := compile("", overlayTransitionGraceful)
	if graceful.GenerationID == first.GenerationID {
		t.Fatal("graceful and revoke of the same desired state share a generation id")
	}

	// Determinism is preserved where it matters: the SAME transaction, re-prepared
	// after a crash, must produce the same id or recovery cannot use readback.
	if again := compile("g-the-disable", overlayTransitionRevoke); again.GenerationID != afterDisable.GenerationID {
		t.Fatalf("re-preparing one transaction produced %q then %q", afterDisable.GenerationID, again.GenerationID)
	}
}

// A disabled master and an enabled one must not share an id either: the empty
// generation the disable commits is a real, committable document.
func TestOverlayGenerationIDDistinguishesTheDisabledMaster(t *testing.T) {
	src := overlayTestDocument()
	enabled := compileForTest(t, src, overlayTransitionRevoke)
	src.MITM.Enabled = false
	disabled := compileForTest(t, src, overlayTransitionRevoke)

	if enabled.GenerationID == disabled.GenerationID {
		t.Fatal("the disabled master shares a generation id with the enabled one")
	}
	if disabled.GenerationID == "" {
		t.Fatal("the disabled master produced no generation id")
	}
}

// A disabled master is a real, committable generation — an empty one. Inferring
// "off" from an absent overlay instead would leave the transition unatomic.
func TestOverlayCompileDisabledMasterIsAnEmptyGeneration(t *testing.T) {
	src := overlayTestDocument()
	src.MITM.Enabled = false
	doc := compileForTest(t, src, overlayTransitionRevoke)

	if len(doc.Client.Rules) != 0 || len(doc.Egress.Capabilities) != 0 {
		t.Fatalf("a disabled master compiled to a non-empty generation: %+v", doc)
	}
	if doc.GenerationID == "" {
		t.Fatal("a disabled master produced no generation id")
	}
	if doc.TransitionMode != overlayTransitionRevoke {
		t.Fatalf("transition = %q, want revoke: turning the master off withdraws authority", doc.TransitionMode)
	}
}

// What the typed model must still refuse, and what it must now accept.
//
// The accept half is the regression guard for a real bug: these keyword shapes
// used to be refused, and refusing them meant the coordinator silently dropped
// 21 of 323 reviewed rules from a live deployment.
func TestOverlayPolicyRuleExpressiveness(t *testing.T) {
	t.Run("two primary selectors are refused", func(t *testing.T) {
		// The source model permits exactly one; more than one means the rule
		// came from something this compiler does not model, and narrowing it
		// would change what was approved.
		if _, ok := overlayPolicyRule(interceptRoutingRule{
			Action: "reject", Domain: "a.test", DomainSuffix: "b.test",
		}, "m"); ok {
			t.Fatal("a rule with two primary selectors was accepted")
		}
	})

	t.Run("a rule with no constraint at all is refused", func(t *testing.T) {
		if _, ok := overlayPolicyRule(interceptRoutingRule{Action: "reject"}, "m"); ok {
			t.Fatal("an unconstrained rule was accepted; it would match everything")
		}
	})

	t.Run("suffix narrowed by one keyword", func(t *testing.T) {
		rule, ok := overlayPolicyRule(interceptRoutingRule{
			Action: "direct", DomainSuffix: "capcutapi.com", DomainKeywords: []string{"tnc"},
		}, "m")
		if !ok {
			t.Fatal("suffix + keyword was refused; that drops a reviewed rule")
		}
		if rule.Kind != overlaySelectorDomainSuffix || rule.Value != "capcutapi.com" {
			t.Fatalf("primary selector lost: %+v", rule)
		}
		if len(rule.KeywordsAny) != 1 || rule.KeywordsAny[0] != "tnc" {
			t.Fatalf("keyword constraint lost: %+v", rule)
		}
	})

	t.Run("suffix narrowed by an any-of keyword set", func(t *testing.T) {
		rule, ok := overlayPolicyRule(interceptRoutingRule{
			Action: "reject", DomainSuffix: "chat.bilibili.com",
			DomainKeywords: []string{"p2p", "stun", "tracker"},
		}, "m")
		if !ok {
			t.Fatal("suffix + any-of keywords was refused")
		}
		if len(rule.KeywordsAny) != 3 || len(rule.KeywordsAll) != 0 {
			t.Fatalf("any-of set was not preserved as any-of: %+v", rule)
		}
	})

	t.Run("all-of keywords stay all-of", func(t *testing.T) {
		rule, ok := overlayPolicyRule(interceptRoutingRule{
			Action: "reject", AllDomainKeywords: []string{"tnc", "alisg"},
		}, "m")
		if !ok {
			t.Fatal("all-of keywords were refused")
		}
		// Conflating any-of with all-of would widen the rule, which for a
		// direct action means more traffic escaping interception.
		if len(rule.KeywordsAll) != 2 || len(rule.KeywordsAny) != 0 {
			t.Fatalf("all-of set was not preserved as all-of: %+v", rule)
		}
		if rule.Kind != overlaySelectorAny {
			t.Fatalf("a keyword-only rule should use the any selector: %+v", rule)
		}
	})

	t.Run("a lone keyword reads as a keyword selector", func(t *testing.T) {
		rule, ok := overlayPolicyRule(interceptRoutingRule{
			Action: "reject", DomainKeywords: []string{"tnc"},
		}, "m")
		if !ok {
			t.Fatal("a lone keyword was refused")
		}
		if rule.Kind != overlaySelectorDomainKeyword || rule.Value != "tnc" {
			t.Fatalf("expected a keyword selector, got %+v", rule)
		}
	})

	t.Run("network and port constraints survive", func(t *testing.T) {
		rule, ok := overlayPolicyRule(interceptRoutingRule{
			Action: "direct", DomainSuffix: "b.test", Network: "udp", DestinationPort: 443,
		}, "m")
		if !ok {
			t.Fatal("a constrained rule was refused")
		}
		if rule.Network != "udp" || len(rule.Ports) != 1 || rule.Ports[0].From != 443 {
			t.Fatalf("constraints lost: %+v", rule)
		}
	})
}

// --- journal ----------------------------------------------------------------

func TestOverlayJournalPersistsAcrossReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.json")
	j, err := NewOverlayJournal(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := j.Begin(overlayJournalEntry{
		OperationID: "op-1", BaseGeneration: "g0", TargetGeneration: "g1",
	}); err != nil {
		t.Fatalf("begin: %v", err)
	}
	if err := j.Advance(overlayPhaseCommitIntent, ""); err != nil {
		t.Fatalf("advance: %v", err)
	}

	reopened, err := NewOverlayJournal(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	entry := reopened.Current()
	if entry == nil {
		t.Fatal("the in-flight operation did not survive reopen")
	}
	if entry.Phase != overlayPhaseCommitIntent {
		t.Fatalf("phase = %q, want COMMIT_INTENT", entry.Phase)
	}
	if entry.TargetGeneration != "g1" {
		t.Fatalf("target = %q", entry.TargetGeneration)
	}
}

// A journal that cannot be read must not silently start over: that would
// discard the very evidence recovery depends on.
func TestOverlayJournalRefusesUnreadableState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := NewOverlayJournal(path); err == nil {
		t.Fatal("an unreadable journal was silently reset")
	}

	future := filepath.Join(t.TempDir(), "journal.json")
	raw, _ := json.Marshal(map[string]any{"version": 99, "driver": "overlay-socks"})
	if err := os.WriteFile(future, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := NewOverlayJournal(future); err == nil {
		t.Fatal("a journal from a newer version was accepted")
	}
}

// --- recovery ---------------------------------------------------------------

// stubOverlayCore serves a fixed readback over a unix socket, standing in for
// mihomo's control socket.
func stubOverlayCore(t *testing.T, readback overlayReadback) *OverlayClient {
	t.Helper()
	dir := t.TempDir()
	sock := filepath.Join(dir, "control.sock")

	mux := http.NewServeMux()
	mux.HandleFunc("/runtime-overlays/5gpn", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(readback)
	})
	mux.HandleFunc("/runtime-overlays/5gpn/generations/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Skipf("unix sockets unavailable here: %v", err)
	}
	srv := &http.Server{Handler: mux}
	go srv.Serve(l)
	t.Cleanup(func() { _ = srv.Close() })
	return NewOverlayClient(sock)
}

// After COMMIT_INTENT the coordinator must never assume failure. These three
// cases are the whole reason the intent record exists.
func TestRecoverAfterCommitIntent(t *testing.T) {
	cases := []struct {
		name   string
		active string
		want   overlayRecoveryAction
	}{
		{"commit landed", "g1", overlayRecoveryRollForward},
		{"commit did not land", "g0", overlayRecoveryRetry},
		{"a third party moved it", "g9", overlayRecoveryConflict},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			journal, err := NewOverlayJournal(filepath.Join(t.TempDir(), "journal.json"))
			if err != nil {
				t.Fatal(err)
			}
			if err := journal.Begin(overlayJournalEntry{
				OperationID: "op-1", BaseGeneration: "g0", TargetGeneration: "g1",
			}); err != nil {
				t.Fatal(err)
			}
			if err := journal.Advance(overlayPhaseCommitIntent, ""); err != nil {
				t.Fatal(err)
			}

			client := stubOverlayCore(t, overlayReadback{ActiveGeneration: tc.active})
			action, _, err := RecoverOverlayOperation(context.Background(), journal, client)
			if err != nil {
				t.Fatalf("recover: %v", err)
			}
			if action != tc.want {
				t.Fatalf("action = %q, want %q", action, tc.want)
			}
		})
	}
}

// Before COMMIT_INTENT nothing was published, so prepared artifacts can simply
// be dropped — they carry no capability.
func TestRecoverBeforeCommitIntentAbandons(t *testing.T) {
	journal, err := NewOverlayJournal(filepath.Join(t.TempDir(), "journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Begin(overlayJournalEntry{
		OperationID: "op-1", BaseGeneration: "g0", TargetGeneration: "g1",
	}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Advance(overlayPhasePrepared, ""); err != nil {
		t.Fatal(err)
	}

	client := stubOverlayCore(t, overlayReadback{ActiveGeneration: "g0"})
	action, _, err := RecoverOverlayOperation(context.Background(), journal, client)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if action != overlayRecoveryAbandon {
		t.Fatalf("action = %q, want abandon", action)
	}
}

func TestRecoverWithNothingInFlight(t *testing.T) {
	journal, err := NewOverlayJournal(filepath.Join(t.TempDir(), "journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	client := stubOverlayCore(t, overlayReadback{})
	action, _, err := RecoverOverlayOperation(context.Background(), journal, client)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if action != overlayRecoveryNone {
		t.Fatalf("action = %q, want none", action)
	}
}

// --- error classification ---------------------------------------------------

// The three outcomes drive different recovery, so the mapping is part of the
// contract rather than an implementation detail.
func TestOverlayErrorClassification(t *testing.T) {
	cases := []struct {
		code string
		want error
	}{
		{"cas_conflict", errOverlayConflict},
		{"wrong_state", errOverlayConflict},
		{"dependency_missing", errOverlayRetryable},
		{"not_ready", errOverlayRetryable},
		{"invalid_document", errOverlayTerminal},
		{"anchor_invalid", errOverlayTerminal},
		{"mode_conflict", errOverlayTerminal},
		{"unsupported_schema", errOverlayUnsupported},
		{"disabled", errOverlayUnsupported},
	}
	for _, tc := range cases {
		t.Run(tc.code, func(t *testing.T) {
			raw, _ := json.Marshal(overlayErrorBody{Code: tc.code, Message: "detail"})
			err := classifyOverlayError(http.StatusConflict, raw)
			if !errors.Is(err, tc.want) {
				t.Fatalf("code %q classified as %v, want %v", tc.code, err, tc.want)
			}
		})
	}
}

// A stage that fails must not keep its journal entry in flight. Begin refuses
// while one is unfinished, so a single rejected document wedged every later
// apply until the daemon restarted and recovery ran -- which is what a
// duplicate-capability document did on a real gateway.
func TestJournalEntryIsAbandonedWhenStagingFails(t *testing.T) {
	t.Parallel()
	journal, err := NewOverlayJournal(filepath.Join(t.TempDir(), "journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Begin(overlayJournalEntry{
		OperationID: "op-failed", BaseGeneration: "g0", TargetGeneration: "g1",
	}); err != nil {
		t.Fatal(err)
	}
	// What the driver does when client.Stage returns an error.
	_ = journal.Advance(overlayPhaseStaged, "overlay: invalid document")
	_ = journal.Finish()

	if entry := journal.Current(); entry != nil {
		t.Fatalf("entry still in flight at %s; the next apply would be refused", entry.Phase)
	}
	if err := journal.Begin(overlayJournalEntry{
		OperationID: "op-next", BaseGeneration: "g0", TargetGeneration: "g2",
	}); err != nil {
		t.Fatalf("a later apply was refused after a failed stage: %v", err)
	}
}

// A commit the core refuses outright publishes nothing, so its entry describes
// no capability and repeating it cannot help. Keeping it in flight is what
// wedged a real gateway: Begin refuses while one is unfinished, so the operator
// saw every later enable fail with "is still at COMMIT_INTENT" and had no way
// to clear it short of restarting the daemon.
func TestJournalEntryIsClearedWhenCommitIsRefused(t *testing.T) {
	t.Parallel()
	journal, client := journalAtCommitIntent(t, "g0")
	driver := NewOverlayDriver(client, journal)

	refusal := fmt.Errorf("%w: invalid_document", errOverlayTerminal)
	if _, err := driver.recoverAfterCommit(context.Background(), "g1", "g0", refusal); !errors.Is(err, errOverlayTerminal) {
		t.Fatalf("error = %v, want the terminal refusal to surface", err)
	}
	assertJournalAcceptsNextApply(t, journal)
}

// The base generation is still live, so the commit provably did not land.
// Recovery would classify exactly this as a retry and clear it; doing it here
// means the driver does not stay wedged until a restart.
func TestJournalEntryIsClearedWhenCommitDidNotLand(t *testing.T) {
	t.Parallel()
	journal, client := journalAtCommitIntent(t, "g0")
	driver := NewOverlayDriver(client, journal)

	lost := errors.New("overlay: connection reset")
	if _, err := driver.recoverAfterCommit(context.Background(), "g1", "g0", lost); err == nil {
		t.Fatal("a commit that did not take effect must still report an error")
	}
	assertJournalAcceptsNextApply(t, journal)
}

// The opposite guard. Neither the base nor the target is live, so something
// outside this coordinator moved the generation. That is the one case recovery
// refuses to resolve on its own, and the entry has to survive for an operator.
func TestJournalEntrySurvivesGenerationMove(t *testing.T) {
	t.Parallel()
	journal, client := journalAtCommitIntent(t, "g9")
	driver := NewOverlayDriver(client, journal)

	lost := errors.New("overlay: connection reset")
	if _, err := driver.recoverAfterCommit(context.Background(), "g1", "g0", lost); err == nil {
		t.Fatal("a conflicting active generation must report an error")
	}
	entry := journal.Current()
	if entry == nil {
		t.Fatal("the entry was cleared; an operator has nothing left to resolve")
	}
	if entry.Phase != overlayPhaseCommitIntent {
		t.Fatalf("phase = %s, want COMMIT_INTENT", entry.Phase)
	}
}

// journalAtCommitIntent returns a journal holding one operation at
// COMMIT_INTENT (base g0, target g1) and a core reporting active as given.
func journalAtCommitIntent(t *testing.T, active string) (*OverlayJournal, *OverlayClient) {
	t.Helper()
	journal, err := NewOverlayJournal(filepath.Join(t.TempDir(), "journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := journal.Begin(overlayJournalEntry{
		OperationID: "op-1", BaseGeneration: "g0", TargetGeneration: "g1",
	}); err != nil {
		t.Fatal(err)
	}
	if err := journal.Advance(overlayPhaseCommitIntent, ""); err != nil {
		t.Fatal(err)
	}
	return journal, stubOverlayCore(t, overlayReadback{ActiveGeneration: active})
}

func assertJournalAcceptsNextApply(t *testing.T, journal *OverlayJournal) {
	t.Helper()
	if entry := journal.Current(); entry != nil {
		t.Fatalf("entry still in flight at %s; the next apply would be refused", entry.Phase)
	}
	if err := journal.Begin(overlayJournalEntry{
		OperationID: "op-next", BaseGeneration: "g0", TargetGeneration: "g2",
	}); err != nil {
		t.Fatalf("a later apply was refused: %v", err)
	}
}

// An extension holding the network permission must reach the network. The
// permission names no host, so the transport half of it cannot be an allowlist:
// the overlay's binding for it is unbounded, and the interception listener's
// deny terminator is what everything else still falls to.
func TestOverlayGrantHolderGetsExactlyOneUnboundedBindingLast(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	module.Network = true
	module.EgressGroup = "Japan"
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Enabled = true
	second.Network = true
	second.EgressGroup = "Proxies"
	second.CaptureHosts = []string{"second.example.com"}

	document := interceptConfigDocument{
		Version: interceptConfigVersion, MITM: interceptMITMSettings{Enabled: true},
		ExecutionOrder: []string{module.ID, second.ID},
		Modules:        []interceptModuleSnapshot{module, second},
	}
	capabilities := overlayEgressCapabilities(orderedEnabledInterceptModules(document), "cred", "Proxies")
	if len(capabilities) != 1 {
		t.Fatalf("got %d capabilities, want 1", len(capabilities))
	}
	bindings := capabilities[0].Bindings
	unbounded := 0
	for index, bind := range bindings {
		if !bind.Unbounded {
			continue
		}
		unbounded++
		if index != len(bindings)-1 {
			t.Errorf("the unbounded binding is at %d of %d and would shadow the rest", index, len(bindings))
		}
		if len(bind.Destinations) != 0 {
			t.Errorf("the unbounded binding also carries %d destinations", len(bind.Destinations))
		}
		// Execution order decides it, the same way it decides every other
		// overlapping claim in this projection.
		if bind.Group != "Japan" {
			t.Errorf("unmatched egress went to %q, not the first bound grant holder", bind.Group)
		}
	}
	if unbounded != 1 {
		t.Fatalf("got %d unbounded bindings, want exactly 1", unbounded)
	}

	// Without the grant there is nothing to widen, and the allowlist stands.
	module.Network, second.Network = false, false
	document.Modules = []interceptModuleSnapshot{module, second}
	for _, bind := range overlayEgressCapabilities(orderedEnabledInterceptModules(document), "cred", "Proxies")[0].Bindings {
		if bind.Unbounded {
			t.Fatal("an extension without the network permission got unbounded egress")
		}
	}
}
