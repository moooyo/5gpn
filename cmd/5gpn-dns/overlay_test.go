package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
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

// One capability per distinct egress group, not per module: the capability is
// the authority to leave through a group, and two modules bound to the same
// group ask for the same authority.
func TestOverlayCompileMintsOneCapabilityPerGroup(t *testing.T) {
	src := overlayTestDocument()
	// alpha -> Proxies (explicit), beta -> Proxies (via the terminal target).
	doc := compileForTest(t, src, overlayTransitionRevoke)
	if len(doc.Egress.Capabilities) != 1 {
		t.Fatalf("got %d capabilities, want 1: %+v", len(doc.Egress.Capabilities), doc.Egress.Capabilities)
	}

	src.Modules[1].EgressGroup = "SecondGroup"
	doc = compileForTest(t, src, overlayTransitionRevoke)
	if len(doc.Egress.Capabilities) != 2 {
		t.Fatalf("got %d capabilities, want 2: %+v", len(doc.Egress.Capabilities), doc.Egress.Capabilities)
	}
	for _, c := range doc.Egress.Capabilities {
		if c.ID == "" || c.Group == "" {
			t.Fatalf("capability is incomplete: %+v", c)
		}
		// A group the operator explicitly bound must not silently become DIRECT.
		if c.Group == "SecondGroup" && c.AllowDirect {
			t.Fatal("an explicitly bound group was allowed to resolve to DIRECT")
		}
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

// A rule the typed model cannot express must be refused, not silently narrowed
// — narrowing changes what the operator approved.
func TestOverlayCompileRefusesInexpressibleRules(t *testing.T) {
	if _, ok := overlayPolicyRule(interceptRoutingRule{
		Action:         "reject",
		DomainKeywords: []string{"a", "b"},
	}, "m"); ok {
		t.Fatal("a multi-keyword rule was accepted")
	}
	if _, ok := overlayPolicyRule(interceptRoutingRule{
		Action: "reject",
		Domain: "a.test", DomainSuffix: "b.test",
	}, "m"); ok {
		t.Fatal("a rule with two primary selectors was accepted")
	}
	if rule, ok := overlayPolicyRule(interceptRoutingRule{
		Action: "direct", DomainSuffix: "b.test", DestinationPort: 443,
	}, "m"); !ok {
		t.Fatal("a single-selector rule was refused")
	} else if rule.Action != overlayActionDirect || len(rule.Ports) != 1 {
		t.Fatalf("unexpected compilation: %+v", rule)
	}
}

// --- journal ----------------------------------------------------------------

func TestOverlayJournalPersistsAcrossReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.json")
	j, err := NewOverlayJournal(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if j.Driver() != overlayDriverLegacy {
		t.Fatalf("default driver = %q, want the legacy one", j.Driver())
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

// The driver is persisted and never inferred. A coordinator that guesses would
// oscillate the first time a readback is ambiguous, rewriting routing each time.
func TestOverlayJournalDriverIsPersistedAndValidated(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.json")
	j, _ := NewOverlayJournal(path)
	if err := j.SetDriver(overlayDriverOverlay); err != nil {
		t.Fatalf("set driver: %v", err)
	}
	reopened, err := NewOverlayJournal(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if reopened.Driver() != overlayDriverOverlay {
		t.Fatalf("driver = %q, want the overlay one", reopened.Driver())
	}
	if err := j.SetDriver("something-else"); err == nil {
		t.Fatal("an unknown driver was accepted")
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
