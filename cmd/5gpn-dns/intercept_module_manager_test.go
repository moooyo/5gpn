package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testInterceptDocument(t testing.TB, modules ...interceptModuleSnapshot) (interceptConfigDocument, []byte) {
	t.Helper()
	executionOrder := make([]string, 0, len(modules))
	for _, module := range modules {
		executionOrder = append(executionOrder, module.ID)
	}
	document := interceptConfigDocument{
		Version:  interceptConfigVersion,
		Listen:   "127.0.0.1:18080",
		Username: "interception-unavailable",
		Password: "interception-unavailable-password",
		TLSCert:  "/etc/5gpn/intercept/tls/fullchain.pem",
		TLSKey:   "/etc/5gpn/intercept/tls/privkey.pem",
		UpstreamProxy: interceptProxyConfig{
			Address: "127.0.0.1:17890", Username: "interception-upstream-unavailable", Password: "interception-upstream-unavailable-password",
		},
		MITM:           interceptMITMSettings{Enabled: true, HTTP2: true, QUICFallbackProtection: true},
		ExecutionOrder: executionOrder,
		Modules:        modules,
	}
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	return document, body
}

// An ungranted extension must be distinguishable from one whose grant simply
// did not serialize. The field is omitempty, so its absence is the answer, and
// this pins that a granted one is present and true.
func TestInterceptModuleViewMarshalsTheNetworkGrant(t *testing.T) {
	body, err := json.Marshal(interceptModuleViewFromSnapshot(testModuleSnapshot(), true, ""))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), `"network"`) {
		t.Fatalf("an ungranted extension claimed the network permission: %s", body)
	}
	granted := testModuleSnapshot()
	granted.Network = true
	body, err = json.Marshal(interceptModuleViewFromSnapshot(granted, true, ""))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `"network":true`) {
		t.Fatalf("the network grant did not survive into the view: %s", body)
	}
}

func TestInterceptModuleViewExposesActionReviewWithoutScriptBody(t *testing.T) {
	module := testModuleSnapshot()
	view := interceptModuleViewFromSnapshot(module, true, "")
	if len(view.Actions) != 1 {
		t.Fatalf("action reviews = %+v", view.Actions)
	}
	action := view.Actions[0]
	if action.ID != module.Scripts[0].ID || action.Phase != interceptPhaseResponse ||
		action.ScriptDigest != module.Scripts[0].ScriptDigest || action.Match.PathRegex != "^/" {
		t.Fatalf("action review = %+v", action)
	}
	body, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), module.Scripts[0].ScriptBody) || !strings.Contains(string(body), `"actions":[`) {
		t.Fatalf("action review leaked or omitted script metadata: %s", body)
	}
}

func TestInterceptModulesViewAlwaysMarshalsCollectionFieldsAsArrays(t *testing.T) {
	document, body := testInterceptDocument(t)
	view := modulesViewFromDocument(document, body, false, "mitm-disabled", []string{"DIRECT"})
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"execution_order":[]`, `"modules":[]`, `"active_capture_hosts":[]`} {
		if !strings.Contains(string(encoded), field) {
			t.Fatalf("empty collection %s was omitted or null: %s", field, encoded)
		}
	}
}

func testModuleSnapshot() interceptModuleSnapshot {
	manifest := "apiVersion: 5gpn.io/v1\nkind: Extension\n"
	script := `function transform(context) { return { response: { body: context.response.body } } }`
	return interceptModuleSnapshot{
		ID: "io.example.fixture", Version: "1.0.0", Name: "Fixture extension",
		ImportedAt:   time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC).Format(time.RFC3339),
		Source:       interceptModuleSource{Digest: sha256Hex([]byte(manifest)), Body: manifest},
		CaptureHosts: []string{"api.example.com"}, CaptureDNS: interceptCaptureDNSTrust,
		Scripts: []interceptScriptRule{{
			ID: "clean-response", Phase: interceptPhaseResponse,
			Match:     interceptActionMatch{Hosts: []string{"api.example.com"}, Schemes: []string{"https"}, PathRegex: "^/"},
			ScriptURL: "https://extensions.example.test/script.js", ScriptDigest: sha256Hex([]byte(script)), ScriptBody: script,
			BodyMode: "text", TimeoutMS: 1000, MaxBodyBytes: 8 << 20,
		}},
	}
}

// With the master off the table is built but inert, and inert is not empty.
// PrepareRuntime and ReconcileMihomoText published nil, which discards the
// [Host] mappings -- ungated by design, because a mapping says where a name
// lives whether or not anything is intercepting it -- and the attribution the
// resolve test needs to report "this extension declared the name, and it is
// inert because the master is off". The apply path publishes the document
// unconditionally, so the same document produced two different overlays
// depending on which path last published it: right after the toggle, silently
// empty after the next daemon start or mihomo config PUT.
func TestInterceptMasterOffPublishesTheDeclaredTableRatherThanNothing(t *testing.T) {
	t.Parallel()
	module := testModuleSnapshot()
	module.Enabled = true
	module.HostMappings = []interceptHostMapping{{Pattern: "api.example.com", Target: "origin.example.net"}}
	manager, _, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)

	document, _ := testInterceptDocument(t, module)
	document.MITM.Enabled = false
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}

	mihomoText, err := os.ReadFile(mihomoPath)
	if err != nil {
		t.Fatal(err)
	}
	for name, publish := range map[string]func() error{
		"PrepareRuntime":      manager.PrepareRuntime,
		"ReconcileMihomoText": func() error { return manager.ReconcileMihomoText(string(mihomoText)) },
	} {
		name, publish := name, publish
		t.Run(name, func(t *testing.T) {
			if err := publish(); err != nil {
				t.Fatal(err)
			}
			snapshot := handler.interceptHosts.Load()
			if snapshot == nil {
				t.Fatal("no snapshot was published at all")
			}
			if snapshot.moduleCount != 1 {
				t.Fatalf("enabled extensions in the table = %d, want 1: the extensions page still shows it enabled", snapshot.moduleCount)
			}
			binding, ok := snapshot.lookup("api.example.com")
			if !ok || binding.moduleID != module.ID {
				t.Fatalf("attribution lost: lookup = %+v ok=%t", binding, ok)
			}
			mapping, ok := snapshot.HostMapping("api.example.com")
			if !ok || mapping.target != "origin.example.net" {
				t.Fatalf("[Host] mapping lost: %+v ok=%t", mapping, ok)
			}
			// The gate still holds: capture must stay fail-closed, because the
			// sidecar cannot terminate TLS with the master off.
			if _, _, matched := snapshot.CaptureDNS("api.example.com"); matched {
				t.Fatal("capture matched while the master is off; that would black-hole the name")
			}
		})
	}
}

func newInterceptManagerFixture(t *testing.T, modules ...interceptModuleSnapshot) (*InterceptModuleManager, *fakeMihomoController, *Handler, string, string) {
	t.Helper()
	dir := t.TempDir()
	interceptPath := filepath.Join(dir, "config.json")
	_, body := testInterceptDocument(t, modules...)
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}
	mihomoDir := filepath.Join(dir, "mihomo")
	if err := os.Mkdir(mihomoDir, 0o770); err != nil {
		t.Fatal(err)
	}
	mihomoPath := filepath.Join(mihomoDir, "config.yaml")
	golden := goldenMihomoConfig()
	if err := os.WriteFile(mihomoPath, []byte(golden), 0o660); err != nil {
		t.Fatal(err)
	}
	handler := &Handler{}
	controller := &fakeMihomoController{reachable: true, authenticated: true}
	manager := NewInterceptModuleManager(NewInterceptConfigStore(interceptPath), handler, nil, NewMihomoConfigStore(mihomoPath), goldenInfraParams(), &fakeMihomoTester{}, controller)
	// The overlay driver is the only publication path, so a manager without one
	// refuses every routing change. Fixtures get a core that accepts a stage and
	// a commit; tests that need a failing driver install their own.
	manager.SetOverlayDriver(NewOverlayDriver(stubCommittingOverlayCore(t).client, newTestOverlayJournal(t)))
	return manager, controller, handler, interceptPath, mihomoPath
}

// newInterceptManagerFixtureWithCore is newInterceptManagerFixture for tests
// that have to look at what was published. Routing no longer reaches the mihomo
// file, so the committed generation is the only place it can be seen.
func newInterceptManagerFixtureWithCore(t *testing.T, modules ...interceptModuleSnapshot) (*InterceptModuleManager, *recordingOverlayCore, *fakeMihomoController, *Handler, string, string) {
	t.Helper()
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, modules...)
	core := stubCommittingOverlayCore(t)
	manager.SetOverlayDriver(NewOverlayDriver(core.client, newTestOverlayJournal(t)))
	return manager, core, controller, handler, interceptPath, mihomoPath
}

func newTestOverlayJournal(t *testing.T) *OverlayJournal {
	t.Helper()
	journal, err := NewOverlayJournal(filepath.Join(t.TempDir(), "overlay-journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	return journal
}

// recordingOverlayCore is a control socket that carries a generation all the way
// through: it stages what it is given and makes it active on commit, so a
// readback afterwards reports the generation the driver just published. That
// round trip is what the manager's publish path depends on.
//
// It keeps every staged document as well. The mihomo file is no longer
// rewritten for a routing change, so the committed generation is where a test
// looks to see what was published.
type recordingOverlayCore struct {
	client *OverlayClient

	mu      sync.Mutex
	staged  map[string]overlayDocument
	active  string
	commits int

	// afterCommit runs on the server, after the generation is active and before
	// the success response is written. It is how a test arranges the one state
	// the failure matrix could not otherwise reach: the commit landed, and the
	// bookkeeping that records it then failed.
	afterCommit func()
}

// committed returns the generation the core last made active.
func (c *recordingOverlayCore) committed(t *testing.T) overlayDocument {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.active == "" {
		t.Fatal("no generation was committed")
	}
	doc, ok := c.staged[c.active]
	if !ok {
		t.Fatalf("the active generation %q was never staged", c.active)
	}
	return doc
}

// commitCount reports how many generations were made active. Publishing the
// generation that is already live is a no-op, so this counts real transitions.
func (c *recordingOverlayCore) commitCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.commits
}

// overlayCaptureSelectors renders a committed generation's capture rules as
// "<kind>:<value>:<port>", the form a test can compare against.
func overlayCaptureSelectors(doc overlayDocument) []string {
	out := []string{}
	for _, rule := range doc.Client.Rules {
		if rule.Action != overlayActionCapture {
			continue
		}
		for _, port := range rule.Ports {
			out = append(out, fmt.Sprintf("%s:%s:%d", rule.Kind, rule.Value, port.From))
		}
	}
	return out
}

// overlayEgressGroupFor reports the group a committed generation authorises for
// one destination and port, or "" for none. The destination sets are disjoint by
// construction, so this is a lookup rather than a first-match scan.
func overlayEgressGroupFor(doc overlayDocument, kind overlaySelectorKind, value string, port uint16) string {
	for _, capability := range doc.Egress.Capabilities {
		for _, binding := range capability.Bindings {
			for _, destination := range binding.Destinations {
				if destination.Kind != kind || destination.Value != value {
					continue
				}
				for _, allowed := range destination.Ports {
					if port >= allowed.From && port <= allowed.To {
						return binding.Group
					}
				}
			}
		}
	}
	return ""
}

func stubCommittingOverlayCore(t *testing.T) *recordingOverlayCore {
	t.Helper()
	return newRecordingOverlayCore(t, false)
}

// stubRefusingOverlayCore stages a generation and then refuses to commit it,
// with a code the client classifies as terminal so the outcome is unambiguous.
// A publication fails this way now: the commit does not land. The mihomo
// controller is no longer in the publish path and cannot fail it.
func stubRefusingOverlayCore(t *testing.T) *recordingOverlayCore {
	t.Helper()
	return newRecordingOverlayCore(t, true)
}

func newRecordingOverlayCore(t *testing.T, refuseCommit bool) *recordingOverlayCore {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "control.sock")

	core := &recordingOverlayCore{staged: map[string]overlayDocument{}}
	revision := uint64(1)

	mux := http.NewServeMux()
	mux.HandleFunc("/capabilities", func(w http.ResponseWriter, r *http.Request) {
		out := overlayCapabilities{ControllerAPI: "1"}
		out.Features = map[string]struct {
			Version int    `json:"version"`
			Owner   string `json:"owner"`
		}{"runtime-overlay": {Version: 1, Owner: overlayOwner}}
		_ = json.NewEncoder(w).Encode(out)
	})
	base := "/runtime-overlays/" + overlayOwner
	mux.HandleFunc(base+"/readiness", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc(base+"/generations/", func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, base+"/generations/")
		core.mu.Lock()
		defer core.mu.Unlock()
		switch {
		case strings.HasSuffix(id, "/commit"):
			if refuseCommit {
				w.WriteHeader(http.StatusBadRequest)
				_ = json.NewEncoder(w).Encode(overlayErrorBody{
					Code: "invalid_document", Message: "stub core refuses this generation",
				})
				return
			}
			core.active = strings.TrimSuffix(id, "/commit")
			core.commits++
			revision++
			if core.afterCommit != nil {
				core.afterCommit()
			}
			_ = json.NewEncoder(w).Encode(overlayCommitResult{
				ActiveGeneration: core.active,
				ActiveDigest:     "digest-" + core.active,
				CoreRevision:     revision,
				ResolverEpoch:    revision,
			})
		case strings.HasSuffix(id, "/abort"):
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodDelete:
			w.WriteHeader(http.StatusNoContent)
		default:
			var doc overlayDocument
			if err := json.NewDecoder(r.Body).Decode(&doc); err == nil {
				core.staged[id] = doc
			}
			out := overlayStageResult{GenerationID: id, CoreRevision: revision}
			out.Digests.Overall = "digest-" + id
			out.Digests.Projection = "projection-" + id
			_ = json.NewEncoder(w).Encode(out)
		}
	})
	mux.HandleFunc(base, func(w http.ResponseWriter, r *http.Request) {
		core.mu.Lock()
		defer core.mu.Unlock()
		_ = json.NewEncoder(w).Encode(overlayReadback{
			Enabled:          true,
			ActiveGeneration: core.active,
			ActiveDigest:     "digest-" + core.active,
			CoreRevision:     revision,
			ResolverEpoch:    revision,
			ProcessorState:   "ready",
			SchemaVersion:    overlaySchemaVersion,
		})
	})

	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Skipf("unix sockets unavailable here: %v", err)
	}
	srv := &http.Server{Handler: mux}
	go srv.Serve(l)
	t.Cleanup(func() { _ = srv.Close() })
	core.client = NewOverlayClient(sock)
	return core
}

type countingInterceptConfigTester struct {
	calls int
}

func (t *countingInterceptConfigTester) Test(context.Context, string) error {
	t.calls++
	return nil
}

func TestInterceptModuleManagerNoOpSkipsSidecarAndMihomoWork(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroup = "Proxies"
	manager, controller, _, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	mihomoTester := manager.tester.(*fakeMihomoTester)
	initial, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	before, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision: initial.Revision, Enabled: &enabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	controller.putCalls = 0
	mihomoTester.calls = 0
	sidecarTester := &countingInterceptConfigTester{}
	manager.SetSidecarTester(sidecarTester)

	beforeConfig := mustRead(t, interceptPath)
	beforeMihomo := mustRead(t, mihomoPath)
	group := module.EgressGroup
	after, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision: before.Revision, EgressGroup: &group,
	})
	if err != nil {
		t.Fatal(err)
	}
	after, err = manager.Reorder(context.Background(), after.Revision, []string{module.ID})
	if err != nil {
		t.Fatal(err)
	}
	after, err = manager.UpdateSettings(context.Background(), after.Revision, interceptMITMSettings{
		Enabled: true, HTTP2: true, QUICFallbackProtection: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision != before.Revision {
		t.Fatalf("no-op revision changed: before=%s after=%s", before.Revision, after.Revision)
	}
	if sidecarTester.calls != 0 || mihomoTester.calls != 0 || controller.putCalls != 0 {
		t.Fatalf("no-op work calls: sidecar=%d mihomo-test=%d apply=%d", sidecarTester.calls, mihomoTester.calls, controller.putCalls)
	}
	if mustRead(t, interceptPath) != beforeConfig || mustRead(t, mihomoPath) != beforeMihomo {
		t.Fatal("no-op update changed durable configuration")
	}
}

func TestInterceptModuleManagerSameMissingEgressBindingStillFails(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroup = "Missing"
	manager, controller, _, interceptPath, _ := newInterceptManagerFixture(t, module)
	sidecarTester := &countingInterceptConfigTester{}
	manager.SetSidecarTester(sidecarTester)
	mihomoTester := manager.tester.(*fakeMihomoTester)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	beforeConfig := mustRead(t, interceptPath)
	group := module.EgressGroup
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision: before.Revision, EgressGroup: &group,
	}); !errors.Is(err, errInterceptModuleConflict) {
		t.Fatalf("same missing egress binding error = %v", err)
	}
	if sidecarTester.calls != 0 || mihomoTester.calls != 0 || controller.putCalls != 0 {
		t.Fatalf("missing binding work calls: sidecar=%d mihomo-test=%d apply=%d", sidecarTester.calls, mihomoTester.calls, controller.putCalls)
	}
	if mustRead(t, interceptPath) != beforeConfig {
		t.Fatal("rejected missing binding changed the sidecar document")
	}
}

func TestInterceptModuleManagerDisabledEgressBindingSkipsMihomoApply(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, _, _, mihomoPath := newInterceptManagerFixture(t, module)
	sidecarTester := &countingInterceptConfigTester{}
	manager.SetSidecarTester(sidecarTester)
	mihomoTester := manager.tester.(*fakeMihomoTester)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	beforeMihomo := mustRead(t, mihomoPath)
	group := "Proxies"
	after, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision: before.Revision, EgressGroup: &group,
	})
	if err != nil {
		t.Fatal(err)
	}
	if after.Modules[0].EgressGroup != group || after.Revision == before.Revision {
		t.Fatalf("disabled binding update = %+v", after.Modules[0])
	}
	if sidecarTester.calls != 1 || mihomoTester.calls != 0 || controller.putCalls != 0 {
		t.Fatalf("disabled binding work calls: sidecar=%d mihomo-test=%d apply=%d", sidecarTester.calls, mihomoTester.calls, controller.putCalls)
	}
	if mustRead(t, mihomoPath) != beforeMihomo {
		t.Fatal("disabled binding update changed mihomo configuration")
	}
}

func TestInterceptModuleManagerMasterOffReorderSkipsMihomoApply(t *testing.T) {
	first := testModuleSnapshot()
	first.Enabled = true
	first.EgressGroup = "Proxies"
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	second.Enabled = true
	manager, controller, _, interceptPath, mihomoPath := newInterceptManagerFixture(t, first, second)
	document, _, err := manager.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	document.MITM.Enabled = false
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}
	sidecarTester := &countingInterceptConfigTester{}
	manager.SetSidecarTester(sidecarTester)
	mihomoTester := manager.tester.(*fakeMihomoTester)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	beforeMihomo := mustRead(t, mihomoPath)
	after, err := manager.Reorder(context.Background(), before.Revision, []string{second.ID, first.ID})
	if err != nil {
		t.Fatal(err)
	}
	if !stringSlicesEqual(after.ExecutionOrder, []string{second.ID, first.ID}) || after.Revision == before.Revision {
		t.Fatalf("master-off reorder = %+v", after.ExecutionOrder)
	}
	if sidecarTester.calls != 1 || mihomoTester.calls != 0 || controller.putCalls != 0 {
		t.Fatalf("master-off reorder work calls: sidecar=%d mihomo-test=%d apply=%d", sidecarTester.calls, mihomoTester.calls, controller.putCalls)
	}
	if mustRead(t, mihomoPath) != beforeMihomo {
		t.Fatal("master-off reorder changed mihomo configuration")
	}
}

func TestInterceptModuleManagerMasterOffReorderRejectsMissingBinding(t *testing.T) {
	first := testModuleSnapshot()
	first.Enabled = true
	first.EgressGroup = "Missing"
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	second.Enabled = true
	manager, controller, _, interceptPath, _ := newInterceptManagerFixture(t, first, second)
	document, _, err := manager.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	document.MITM.Enabled = false
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}
	sidecarTester := &countingInterceptConfigTester{}
	manager.SetSidecarTester(sidecarTester)
	mihomoTester := manager.tester.(*fakeMihomoTester)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Reorder(context.Background(), before.Revision, []string{second.ID, first.ID}); !errors.Is(err, errInterceptModuleConflict) {
		t.Fatalf("master-off missing binding reorder error = %v", err)
	}
	if sidecarTester.calls != 0 || mihomoTester.calls != 0 || controller.putCalls != 0 {
		t.Fatalf("missing reorder work calls: sidecar=%d mihomo-test=%d apply=%d", sidecarTester.calls, mihomoTester.calls, controller.putCalls)
	}
}

func TestInterceptModuleManagerInactiveOnlyReorderSkipsMihomoApply(t *testing.T) {
	first := testModuleSnapshot()
	first.ID = "io.example.first"
	first.EgressGroup = "Proxies"
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	manager, controller, _, _, mihomoPath := newInterceptManagerFixture(t, first, second)
	manager.certWait = func(context.Context, string) error { return nil }
	initial, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	before, err := manager.Update(context.Background(), first.ID, interceptModuleUpdate{
		Revision: initial.Revision, Enabled: &enabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	controller.putCalls = 0
	mihomoTester := manager.tester.(*fakeMihomoTester)
	mihomoTester.calls = 0
	sidecarTester := &countingInterceptConfigTester{}
	manager.SetSidecarTester(sidecarTester)
	beforeMihomo := mustRead(t, mihomoPath)
	after, err := manager.Reorder(context.Background(), before.Revision, []string{second.ID, first.ID})
	if err != nil {
		t.Fatal(err)
	}
	if !stringSlicesEqual(after.ExecutionOrder, []string{second.ID, first.ID}) || after.Revision == before.Revision {
		t.Fatalf("inactive-only reorder = %+v", after.ExecutionOrder)
	}
	if sidecarTester.calls != 1 || mihomoTester.calls != 0 || controller.putCalls != 0 {
		t.Fatalf("inactive-only reorder work calls: sidecar=%d mihomo-test=%d apply=%d", sidecarTester.calls, mihomoTester.calls, controller.putCalls)
	}
	if mustRead(t, mihomoPath) != beforeMihomo {
		t.Fatal("inactive-only reorder changed mihomo configuration")
	}
}

func TestInterceptModuleManagerEnableDisablePublishesOneTransaction(t *testing.T) {
	module := testModuleSnapshot()
	manager, core, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixtureWithCore(t, module)
	var certificateDigests []string
	manager.certWait = func(_ context.Context, digest string) error {
		certificateDigests = append(certificateDigests, digest)
		return nil
	}
	beforeMihomo := mustRead(t, mihomoPath)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	after, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: before.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	// One transaction is now one committed generation. The operator's mihomo
	// file is not rewritten and mihomo is not reloaded for it, so a controller
	// call here would mean routing had leaked back into the YAML.
	if len(certificateDigests) != 1 || core.commitCount() != 1 || controller.putCalls != 0 {
		t.Fatalf("certificate/commit/apply calls = %d/%d/%d", len(certificateDigests), core.commitCount(), controller.putCalls)
	}
	if got := handler.decideName("api.example.com"); got.Action != actionGateway || got.Verdict.Reason != "force-proxy" {
		t.Fatalf("DNS overlay = %+v", got)
	}
	if got := mustRead(t, mihomoPath); got != beforeMihomo {
		t.Fatalf("enabling an extension rewrote the operator's mihomo config:\n%s", got)
	}
	selectors := overlayCaptureSelectors(core.committed(t))
	for _, want := range []string{"domain:api.example.com:443", "domain:api.example.com:80"} {
		if !containsString(selectors, want) {
			t.Fatalf("committed generation is missing capture selector %q: %v", want, selectors)
		}
	}
	configBody, _ := os.ReadFile(interceptPath)
	document, err := decodeInterceptConfig(configBody)
	if err != nil || !document.Modules[0].Enabled {
		t.Fatalf("sidecar extension not enabled: err=%v document=%+v", err, document)
	}

	disabled := false
	final, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: after.Revision, Enabled: &disabled})
	if err != nil {
		t.Fatal(err)
	}
	if final.Modules[0].Enabled || core.commitCount() != 2 || len(final.ActiveCaptureHosts) != 0 {
		t.Fatalf("disabled view/commits = %+v %d", final, core.commitCount())
	}
	if len(overlayCaptureSelectors(core.committed(t))) != 0 {
		t.Fatal("disabling the extension left capture selectors in the committed generation")
	}
}

// A failed publication must leave both files exactly as it found them. The
// mihomo config is no longer one of the things a routing change writes, so what
// this pins is that a refused generation still rolls the sidecar document back
// and still does not touch the operator's config or either backup.
func TestInterceptModuleManagerRestoresExactFilesWhenPublicationFails(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, _, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.SetOverlayDriver(NewOverlayDriver(stubRefusingOverlayCore(t).client, newTestOverlayJournal(t)))
	legacyBackupPath, legacyBackupBody := seedLegacyMihomoBackup(t, manager.mihomo)
	originalIntercept := mustRead(t, interceptPath)
	originalMihomo := mustRead(t, mihomoPath)
	manager.certWait = func(context.Context, string) error { return nil }

	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); !errors.Is(err, errInterceptApplyFailed) {
		t.Fatalf("refused publication error = %v, want an apply failure", err)
	}
	if mustRead(t, mihomoPath) != originalMihomo || mustRead(t, interceptPath) != originalIntercept {
		t.Fatal("failed extension transaction did not restore the exact old files")
	}
	if controller.putCalls != 0 {
		t.Fatalf("failed publication reloaded mihomo: %d controller calls", controller.putCalls)
	}
	// The daemon backup belongs to the mihomo config editor, which is the only
	// writer of that file. A routing change must not create one.
	if _, err := os.Stat(manager.mihomo.BackupPath()); !os.IsNotExist(err) {
		t.Fatalf("a routing change wrote a mihomo backup: %v", err)
	}
	if legacyBackup, err := os.ReadFile(legacyBackupPath); err != nil || string(legacyBackup) != legacyBackupBody {
		t.Fatalf("extension transaction changed legacy backup: body=%q err=%v", legacyBackup, err)
	}
}

// A capture-host set that compacts to a suffix is the case most likely to be
// mangled by a partial rollback. The generation carries it as two selectors;
// after a refused publication both the sidecar document and the live generation
// must be exactly what they were.
func TestInterceptModuleManagerRollsBackCompactSuffixBlockOnPublicationFailure(t *testing.T) {
	module := testModuleSnapshot()
	module.CaptureHosts = []string{"*.example.com", "example.com"}
	manager, core, _, handler, interceptPath, mihomoPath := newInterceptManagerFixtureWithCore(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	activeIntercept, activeMihomo := mustRead(t, interceptPath), mustRead(t, mihomoPath)
	activeGeneration := core.committed(t)
	for _, want := range []string{"domain-suffix:example.com:443", "domain-suffix:example.com:80"} {
		if !containsString(overlayCaptureSelectors(activeGeneration), want) {
			t.Fatalf("active generation is missing compacted selector %q: %v", want, overlayCaptureSelectors(activeGeneration))
		}
	}

	manager.SetOverlayDriver(NewOverlayDriver(stubRefusingOverlayCore(t).client, newTestOverlayJournal(t)))
	disabled := false
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &disabled}); !errors.Is(err, errInterceptApplyFailed) {
		t.Fatalf("disable error = %v, want a publication failure", err)
	}
	if got := mustRead(t, interceptPath); got != activeIntercept {
		t.Fatal("sidecar document was not restored exactly")
	}
	if got := mustRead(t, mihomoPath); got != activeMihomo {
		t.Fatal("a failed publication rewrote the operator's mihomo config")
	}
	if decision := handler.decideName("api.example.com"); decision.Action != actionGateway {
		t.Fatalf("DNS overlay changed after rollback: %+v", decision)
	}
}

// Disabling an extension has to withdraw the reviewed reject/direct rules it
// owns, not just its capture hosts. Those rules only ever existed because both
// the extension and the MITM master were enabled.
func TestInterceptModuleDisableWithdrawsReviewedRoutingRules(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	module.RoutingRules = []interceptRoutingRule{{Action: "reject", Domain: "ads.example.com"}}
	manager, core, controller, _, _, mihomoPath := newInterceptManagerFixtureWithCore(t, module)
	beforeMihomo := mustRead(t, mihomoPath)
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	disabled := false
	updated, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &disabled})
	if err != nil {
		t.Fatal(err)
	}
	if updated.Modules[0].Enabled || core.commitCount() != 1 || controller.putCalls != 0 {
		t.Fatalf("disable result = %+v, commits=%d apply=%d", updated.Modules[0], core.commitCount(), controller.putCalls)
	}
	// The withdrawal is a generation carrying nothing this extension owned, not
	// an edit to the operator's file — which must come back byte-identical.
	committed := core.committed(t)
	if len(committed.Client.Rules) != 0 || len(committed.Egress.Capabilities) != 0 {
		t.Fatalf("disabled extension retained owned routing: %+v", committed)
	}
	if got := mustRead(t, mihomoPath); got != beforeMihomo {
		t.Fatalf("the disable rewrote the operator's mihomo config:\n%s", got)
	}
}

func TestInterceptModuleManagerRefusesToClaimUnexpectedPolicyRule(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	module.RoutingRules = []interceptRoutingRule{{Action: "reject", Domain: "ads.example.com"}}
	manager, core, controller, _, interceptPath, mihomoPath := newInterceptManagerFixtureWithCore(t, module)
	// An operator rule interposed between the egress anchor and the fail-closed
	// terminator is the placement the analyser refuses: declined processor
	// traffic would reach it before the deny.
	tampered := strings.Replace(mustRead(t, mihomoPath),
		"  - "+interceptEgressRejectRule+"\n",
		"  - DOMAIN,operator.example,DIRECT\n  - "+interceptEgressRejectRule+"\n", 1)
	if tampered == mustRead(t, mihomoPath) {
		t.Fatal("the egress terminator was not found, so this test proves nothing")
	}
	if err := os.WriteFile(mihomoPath, []byte(tampered), 0o660); err != nil {
		t.Fatal(err)
	}
	beforeConfig := mustRead(t, interceptPath)
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	disabled := false
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &disabled}); !errors.Is(err, errInterceptModuleConflict) {
		t.Fatalf("unexpected operator rule conflict = %v", err)
	}
	if core.commitCount() != 0 || controller.putCalls != 0 || mustRead(t, interceptPath) != beforeConfig || mustRead(t, mihomoPath) != tampered {
		t.Fatal("failed reconciliation mutated operator or extension state")
	}
}

func TestInterceptModuleManagerWaitsForCertificateWhenEnabledHostSetShrinks(t *testing.T) {
	first := testModuleSnapshot()
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	second.CaptureHosts = []string{"second.example.com"}
	second.Scripts[0].Match.Hosts = []string{"second.example.com"}
	manager, _, _, _, _ := newInterceptManagerFixture(t, first, second)
	var certificateDigests []string
	manager.certWait = func(_ context.Context, digest string) error {
		certificateDigests = append(certificateDigests, digest)
		return nil
	}
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), first.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	view, err = manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	disabled := false
	if _, err := manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &disabled}); err != nil {
		t.Fatal(err)
	}
	want := interceptCertificateDigest([]string{"api.example.com"})
	if len(certificateDigests) != 3 || certificateDigests[2] != want {
		t.Fatalf("certificate waits = %v, want final digest %s", certificateDigests, want)
	}
}

func TestInterceptMasterSwitchStopsAndRestoresArmedExtensions(t *testing.T) {
	module := testModuleSnapshot()
	manager, core, _, handler, _, mihomoPath := newInterceptManagerFixtureWithCore(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	beforeMihomo := mustRead(t, mihomoPath)
	view, _ := manager.View()
	enabled := true
	view, _ = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	disabledSettings := interceptMITMSettings{HTTP2: false, QUICFallbackProtection: true}
	view, err := manager.UpdateSettings(context.Background(), view.Revision, disabledSettings)
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[0].Enabled || view.Modules[0].Ready || view.Modules[0].Reason != "mitm-disabled" || len(view.ActiveCaptureHosts) != 0 {
		t.Fatalf("disabled master view = %+v", view)
	}
	// A disabled master is a committed generation with an empty client stage,
	// not an absent overlay -- that is what makes the switch atomic.
	if handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("disabled master retained an interception route")
	}
	if len(overlayCaptureSelectors(core.committed(t))) != 0 {
		t.Fatal("disabled master left capture selectors in the committed generation")
	}
	if got := mustRead(t, mihomoPath); got != beforeMihomo {
		t.Fatalf("the master switch rewrote the operator's mihomo config:\n%s", got)
	}
	disabledSettings.Enabled = true
	view, err = manager.UpdateSettings(context.Background(), view.Revision, disabledSettings)
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[0].Ready || len(view.ActiveCaptureHosts) != 1 || core.commitCount() != 3 {
		t.Fatalf("re-enabled master view = %+v commits=%d", view, core.commitCount())
	}
	if !containsString(overlayCaptureSelectors(core.committed(t)), "domain:api.example.com:443") {
		t.Fatal("re-enabling the master did not restore the capture selectors")
	}
}

func TestInterceptExtensionCanBeArmedWhileMasterIsOff(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, _, _ := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, _ := manager.View()
	view, err := manager.UpdateSettings(context.Background(), view.Revision, interceptMITMSettings{HTTP2: true, QUICFallbackProtection: true})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	if !view.Modules[0].Enabled || view.Modules[0].Ready || len(view.ActiveCaptureHosts) != 0 || controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatalf("armed extension changed runtime state: view=%+v calls=%d", view, controller.putCalls)
	}
}

func TestInterceptExtensionRequiresTypedSettingsBeforeEnable(t *testing.T) {
	module := testModuleSnapshot()
	module.Settings = []interceptModuleSetting{{
		Key: "location", Type: "location", Required: true,
		Default: json.RawMessage(`{"accuracy":25}`), Value: json.RawMessage(`{"accuracy":25}`),
	}}
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	view, _ := manager.View()
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil || !strings.Contains(err.Error(), "required") {
		t.Fatalf("unconfigured enable error = %v", err)
	}
	view, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision: view.Revision,
		Settings: map[string]json.RawMessage{"location": json.RawMessage(`{"longitude":113.9,"latitude":22.5,"accuracy":25}`)},
	})
	if err != nil || view.Modules[0].Reason != "" {
		t.Fatalf("configured view = %+v err=%v", view.Modules[0], err)
	}
}

func TestInterceptExtensionUpdateUsesReviewedNativeCandidate(t *testing.T) {
	oldScript := `function transform() { return null }`
	newScript := `function transform(context) { return { response: { body: context.response.body } } }`
	unreviewedScript := `function transform() { throw new Error('changed') }`
	var script atomic.Value
	script.Store(oldScript)
	manifest := ""
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/extension.yaml":
			_, _ = w.Write([]byte(manifest))
		case "/extension.js":
			_, _ = w.Write([]byte(script.Load().(string)))
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()
	manifest = fmt.Sprintf(`apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.fixture
  name: Fixture extension
  version: 1.0.0
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
actions:
  - id: clean
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      source: %s/extension.js
      bodyMode: text
      timeoutMs: 1000
      maxBodyBytes: 8388608
`, server.URL)
	parser := interceptModuleParser{client: server.Client(), now: func() time.Time { return time.Date(2026, 7, 18, 0, 0, 0, 0, time.UTC) }}
	module, err := parser.Import(context.Background(), interceptModuleImportRequest{URL: server.URL + "/extension.yaml"})
	if err != nil {
		t.Fatal(err)
	}
	module.CaptureDNS = interceptCaptureDNSChina
	manager, _, _, interceptPath, _ := newInterceptManagerFixture(t, module)
	manager.parser = parser
	view, _ := manager.View()
	unchanged, err := manager.CheckUpdate(context.Background(), module.ID, view.Revision)
	if err != nil || unchanged.State != "unchanged" {
		t.Fatalf("unchanged update = %+v err=%v", unchanged, err)
	}
	script.Store(newScript)
	available, err := manager.CheckUpdate(context.Background(), module.ID, view.Revision)
	if err != nil || available.Candidate == nil {
		t.Fatalf("available update = %+v err=%v", available, err)
	}
	if available.Candidate.ExecutionOrder != 1 || available.Candidate.CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("candidate order/capture DNS = %d/%s, want 1/china", available.Candidate.ExecutionOrder, available.Candidate.CaptureDNS)
	}
	wantDigest := available.Candidate.SnapshotDigest
	script.Store(unreviewedScript)
	if _, err := manager.ApplyUpdate(context.Background(), module.ID, view.Revision, wantDigest); !errors.Is(err, errInterceptRevisionConflict) {
		t.Fatalf("changed candidate apply error = %v", err)
	}
	script.Store(newScript)
	replaced, err := manager.ApplyUpdate(context.Background(), module.ID, view.Revision, wantDigest)
	if err != nil || len(replaced.Modules) != 1 || replaced.Modules[0].SnapshotDigest != wantDigest || replaced.Modules[0].CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("replacement = %+v err=%v", replaced, err)
	}
	document, err := decodeInterceptConfig([]byte(mustRead(t, interceptPath)))
	if err != nil || interceptModuleSnapshotDigest(document.Modules[0]) != wantDigest || document.Modules[0].CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("stored replacement = %+v err=%v", document.Modules, err)
	}
}

func TestInterceptModuleManagerRollsBackWhenCertificatePublicationFails(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	originalConfig := mustRead(t, interceptPath)
	originalMihomo := mustRead(t, mihomoPath)
	manager.certWait = func(context.Context, string) error { return errors.New("publisher failed") }
	view, _ := manager.View()
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil {
		t.Fatal("expected certificate failure")
	}
	if mustRead(t, interceptPath) != originalConfig || mustRead(t, mihomoPath) != originalMihomo || controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("failed transaction changed durable or published state")
	}
}

func TestInterceptModuleManagerRetriggersMissedCertificatePathEvent(t *testing.T) {
	module := testModuleSnapshot()
	manager, core, controller, _, interceptPath, _ := newInterceptManagerFixtureWithCore(t, module)
	manager.certStatePath = filepath.Join(t.TempDir(), "cert-state")
	wantDigest := interceptCertificateDigest(module.CaptureHosts)
	var republishCalls atomic.Int32
	var publishedCandidate string
	manager.certRepublish = func(ctx context.Context, path string, candidate []byte) error {
		if path != interceptPath {
			t.Fatalf("republish path = %q, want %q", path, interceptPath)
		}
		if current := mustRead(t, path); current != string(candidate) {
			t.Fatalf("republished candidate changed after the initial publication:\ncurrent=%s\ncandidate=%s", current, candidate)
		}
		if call := republishCalls.Add(1); call != 1 {
			t.Fatalf("republish calls = %d, want 1", call)
		}
		publishedCandidate = string(candidate)
		if err := writeInterceptConfigAtomicContext(ctx, path, candidate); err != nil {
			return err
		}
		return os.WriteFile(manager.certStatePath, []byte(wantDigest+"\n"), 0o640)
	}

	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	after, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: before.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	if republishCalls.Load() != 1 || core.commitCount() != 1 || controller.putCalls != 0 {
		t.Fatalf("republish/commit/apply calls = %d/%d/%d", republishCalls.Load(), core.commitCount(), controller.putCalls)
	}
	if publishedCandidate == "" || mustRead(t, interceptPath) != publishedCandidate {
		t.Fatal("successful certificate retry did not preserve the exact candidate bytes")
	}
	if after.Revision != interceptRevision([]byte(publishedCandidate)) || after.Revision == before.Revision {
		t.Fatalf("revision after retry = %q, before = %q", after.Revision, before.Revision)
	}
}

func TestInterceptModuleManagerRollsBackWhenCertificateRetriggerFails(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certStatePath = filepath.Join(t.TempDir(), "cert-state")
	originalConfig := mustRead(t, interceptPath)
	originalMihomo := mustRead(t, mihomoPath)
	manager.certRepublish = func(context.Context, string, []byte) error {
		return errors.New("retry write failed")
	}

	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	_, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if !errors.Is(err, errInterceptApplyFailed) || !strings.Contains(err.Error(), "retry write failed") {
		t.Fatalf("certificate retrigger error = %v", err)
	}
	if mustRead(t, interceptPath) != originalConfig || mustRead(t, mihomoPath) != originalMihomo || controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("failed certificate retrigger changed durable or published state")
	}
}

func TestInterceptModuleManagerRollsBackWhenCertificateRetryTimesOut(t *testing.T) {
	module := testModuleSnapshot()
	manager, controller, handler, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certStatePath = filepath.Join(t.TempDir(), "cert-state")
	originalConfig := mustRead(t, interceptPath)
	originalMihomo := mustRead(t, mihomoPath)
	var republishCalls atomic.Int32
	manager.certRepublish = func(ctx context.Context, path string, candidate []byte) error {
		republishCalls.Add(1)
		return writeInterceptConfigAtomicContext(ctx, path, candidate)
	}

	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1100*time.Millisecond)
	defer cancel()
	enabled := true
	_, err = manager.Update(ctx, module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if !errors.Is(err, errInterceptApplyFailed) || !strings.Contains(err.Error(), context.DeadlineExceeded.Error()) {
		t.Fatalf("certificate retry timeout error = %v", err)
	}
	if republishCalls.Load() == 0 {
		t.Fatal("certificate wait timed out without retrying the missed path event")
	}
	if mustRead(t, interceptPath) != originalConfig || mustRead(t, mihomoPath) != originalMihomo || controller.putCalls != 0 || handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("timed-out certificate retry changed durable or published state")
	}
}

func TestInterceptModuleDeleteHonorsCancellationDuringValidation(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = false
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	tester := blockingInterceptConfigTester{entered: make(chan struct{}), release: make(chan struct{})}
	manager.SetSidecarTester(tester)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, deleteErr := manager.Delete(ctx, module.ID, before.Revision)
		done <- deleteErr
	}()
	select {
	case <-tester.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("delete did not reach sidecar validation")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled delete error = %v", err)
		}
	case <-time.After(2 * time.Second):
		close(tester.release)
		t.Fatal("cancelled delete did not stop validation")
	}
	after, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision != before.Revision || len(after.Modules) != 1 || after.Modules[0].ID != module.ID {
		t.Fatalf("cancelled delete committed state: before=%+v after=%+v", before, after)
	}
}

func TestInterceptModuleDeleteRejectsCancellationAfterLockWait(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = false
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	before, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	manager.mu.Lock()
	baseCtx, cancel := context.WithCancel(context.Background())
	ctx := &testSignalingContext{Context: baseCtx, checked: make(chan struct{})}
	done := make(chan error, 1)
	go func() {
		_, deleteErr := manager.Delete(ctx, module.ID, before.Revision)
		done <- deleteErr
	}()
	<-ctx.checked
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			manager.mu.Unlock()
			t.Fatalf("cancelled delete error = %v", err)
		}
	case <-time.After(time.Second):
		manager.mu.Unlock()
		t.Fatal("cancelled delete remained blocked on the module lock")
	}
	manager.mu.Unlock()
	after, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision != before.Revision || len(after.Modules) != 1 || after.Modules[0].ID != module.ID {
		t.Fatalf("cancelled delete committed state: before=%+v after=%+v", before, after)
	}
}

func TestInterceptModulesAPIListsAndTogglesThroughSharedManager(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	module := testModuleSnapshot()
	interceptPath := filepath.Join(t.TempDir(), "config.json")
	_, body := testInterceptDocument(t, module)
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}
	handler := &Handler{}
	manager := NewInterceptModuleManager(NewInterceptConfigStore(interceptPath), handler, nil, fx.store, fx.infra, fx.tester, fx.ctl)
	manager.SetOverlayDriver(NewOverlayDriver(stubCommittingOverlayCore(t).client, newTestOverlayJournal(t)))
	manager.certWait = func(context.Context, string) error { return nil }
	fx.cs.SetInterceptModuleManager(manager)

	get := doAPI(fx.cs, http.MethodGet, "/api/interception/modules", nil, fx.token, true)
	view := decodeJSON[interceptModulesView](t, get)
	if get.Code != http.StatusOK || len(view.Modules) != 1 || view.Modules[0].ID != module.ID {
		t.Fatalf("module view = %+v status=%d", view, get.Code)
	}
	reorderBody, _ := json.Marshal(map[string]any{
		"revision": view.Revision, "execution_order": []string{module.ID},
	})
	reorder := doAPI(fx.cs, http.MethodPut, "/api/interception/modules/reorder", reorderBody, fx.token, true)
	view = decodeJSON[interceptModulesView](t, reorder)
	if reorder.Code != http.StatusOK || !stringSlicesEqual(view.ExecutionOrder, []string{module.ID}) || view.Modules[0].ExecutionOrder != 1 {
		t.Fatalf("reorder view = %+v status=%d", view, reorder.Code)
	}
	badReorderBody, _ := json.Marshal(map[string]any{
		"revision": view.Revision, "execution_order": []string{"io.example.unknown"},
	})
	badReorder := doAPI(fx.cs, http.MethodPut, "/api/interception/modules/reorder", badReorderBody, fx.token, true)
	if badReorder.Code != http.StatusBadRequest {
		t.Fatalf("invalid reorder status=%d body=%s", badReorder.Code, badReorder.Body.String())
	}
	snapshotRecorder := doAPI(fx.cs, http.MethodGet, "/api/interception/modules/"+module.ID, nil, fx.token, true)
	snapshot := decodeJSON[interceptModuleSnapshotView](t, snapshotRecorder)
	if snapshot.SourceBody != module.Source.Body || len(snapshot.Scripts) != 1 {
		t.Fatalf("snapshot = %+v", snapshot)
	}
	update := []byte(fmt.Sprintf(`{"revision":%q,"enabled":true}`, view.Revision))
	put := doAPI(fx.cs, http.MethodPut, "/api/interception/modules/"+module.ID, update, fx.token, true)
	updated := decodeJSON[interceptModulesView](t, put)
	if put.Code != http.StatusOK || !updated.Modules[0].Enabled || handler.decideName("api.example.com").Action != actionGateway {
		t.Fatalf("updated modules = %+v status=%d", updated, put.Code)
	}
}

func TestInterceptModuleRequiresExistingEgressGroupBeforeEnable(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroupRequired = true
	manager, core, _, _, _, _ := newInterceptManagerFixtureWithCore(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if len(view.AvailableEgressGroups) != 2 || !containsString(view.AvailableEgressGroups, "DIRECT") || !containsString(view.AvailableEgressGroups, "Proxies") {
		t.Fatalf("available egress groups = %v", view.AvailableEgressGroups)
	}
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err == nil || !strings.Contains(err.Error(), "egress group") {
		t.Fatalf("required egress group error = %v", err)
	}
	missing := "Missing"
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, EgressGroup: &missing}); !errors.Is(err, errInterceptModuleConflict) {
		t.Fatalf("missing egress group error = %v", err)
	}
	group := "Proxies"
	updated, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{
		Revision: view.Revision, Enabled: &enabled, EgressGroup: &group,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !updated.Modules[0].Ready || updated.Modules[0].EgressGroup != group || updated.Modules[0].ExecutionOrder != 1 {
		t.Fatalf("updated module = %+v", updated.Modules[0])
	}
	if got := overlayEgressGroupFor(core.committed(t), overlaySelectorDomain, "api.example.com", 443); got != group {
		t.Fatalf("committed generation binds api.example.com:443 to %q, want %q", got, group)
	}
}

func TestInterceptModuleReorderChangesFirstMatchingEgress(t *testing.T) {
	first := testModuleSnapshot()
	first.EgressGroup = "Proxies"
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	second.EgressGroup = "DIRECT"
	manager, core, _, _, _, _ := newInterceptManagerFixtureWithCore(t, first, second)
	manager.certWait = func(context.Context, string) error { return nil }
	view, _ := manager.View()
	enabled := true
	view, err := manager.Update(context.Background(), first.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	view, err = manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	// Both extensions claim the same destination; execution order decides which
	// group gets it, and the selector is claimed exactly once so the two groups'
	// destination sets stay disjoint.
	if got := overlayEgressGroupFor(core.committed(t), overlaySelectorDomain, "api.example.com", 443); got != "Proxies" {
		t.Fatalf("initial egress winner = %q, want Proxies", got)
	}
	view, err = manager.Reorder(context.Background(), view.Revision, []string{second.ID, first.ID})
	if err != nil {
		t.Fatal(err)
	}
	if got := overlayEgressGroupFor(core.committed(t), overlaySelectorDomain, "api.example.com", 443); got != "DIRECT" {
		t.Fatalf("reordered egress winner = %q, want DIRECT", got)
	}
	if !stringSlicesEqual(view.ExecutionOrder, []string{second.ID, first.ID}) || view.Modules[0].ExecutionOrder != 1 || view.Modules[1].ExecutionOrder != 2 {
		t.Fatalf("reordered view = %+v", view)
	}
}

func TestInterceptModuleCaptureDNSBindingUsesExecutionOrder(t *testing.T) {
	first := testModuleSnapshot()
	first.ID = "io.example.first"
	first.CaptureDNS = interceptCaptureDNSChina
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Name = "Second extension"
	manager, _, handler, _, _ := newInterceptManagerFixture(t, first, second)
	manager.certWait = func(context.Context, string) error { return nil }
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	view, err = manager.Update(context.Background(), first.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	view, err = manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	if resolver, owner := handler.captureDNSForName("api.example.com"); resolver != interceptCaptureDNSChina || owner != first.ID {
		t.Fatalf("initial binding = %s/%s, want china/%s", resolver, owner, first.ID)
	}
	view, err = manager.Reorder(context.Background(), view.Revision, []string{second.ID, first.ID})
	if err != nil {
		t.Fatal(err)
	}
	if resolver, owner := handler.captureDNSForName("api.example.com"); resolver != interceptCaptureDNSTrust || owner != second.ID {
		t.Fatalf("reordered binding = %s/%s, want trust/%s", resolver, owner, second.ID)
	}
	china := interceptCaptureDNSChina
	view, err = manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, CaptureDNS: &china})
	if err != nil {
		t.Fatal(err)
	}
	if view.Modules[0].CaptureDNS != interceptCaptureDNSChina {
		t.Fatalf("module view capture_dns = %q", view.Modules[0].CaptureDNS)
	}
	if resolver, owner := handler.captureDNSForName("api.example.com"); resolver != interceptCaptureDNSChina || owner != second.ID {
		t.Fatalf("updated binding = %s/%s, want china/%s", resolver, owner, second.ID)
	}
	invalid := "automatic"
	if _, err := manager.Update(context.Background(), second.ID, interceptModuleUpdate{Revision: view.Revision, CaptureDNS: &invalid}); err == nil || !strings.Contains(err.Error(), "capture_dns") {
		t.Fatalf("invalid capture_dns error = %v", err)
	}
}

func TestInterceptExternalEgressGroupLossFailsClosed(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroupRequired = true
	module.EgressGroup = "Proxies"
	manager, _, handler, _, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }
	view, _ := manager.View()
	enabled := true
	view, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err != nil {
		t.Fatal(err)
	}
	external := strings.Replace(mustRead(t, mihomoPath), "name: Proxies", "name: Other", 1)
	if err := os.WriteFile(mihomoPath, []byte(external), 0o660); err != nil {
		t.Fatal(err)
	}
	if err := manager.ReconcileMihomoText(external); err == nil || !strings.Contains(err.Error(), "egress-group-missing") {
		t.Fatalf("external reconcile error = %v", err)
	}
	if handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("DNS overlay remained active after its egress group disappeared")
	}
	view, err = manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if view.Modules[0].Ready || view.Modules[0].Reason != "egress-group-missing" || len(view.ActiveCaptureHosts) != 0 {
		t.Fatalf("failed-closed view = %+v", view)
	}
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

// A generation that went live must never be compensated.
//
// The apply used to restore the previous sidecar bundle on any error from
// publishOverlayGeneration, and the driver returns an error for three different
// situations: the commit did not land, it did land but the journal write
// recording it failed, and nothing could be determined. Compensating the last
// two produced exactly the mismatch the compensation exists to prevent -- the
// sidecar serving one bundle while the live generation names another -- which
// withholds the readiness lease and REJECTs every captured connection. Both
// pointers are durable, so it survived a restart of either process and only an
// unrelated successful transaction or a daemon restart repaired it.
//
// The reachable trigger is a journal write failing once, which the driver's own
// comments already call a realistic partition symptom.
func TestApplyDoesNotCompensateAGenerationThatWentLive(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroup = "Proxies"
	manager, controller, _, interceptPath, _ := newInterceptManagerFixture(t, module)
	core := stubCommittingOverlayCore(t)
	journalDir := t.TempDir()
	journal, err := NewOverlayJournal(filepath.Join(journalDir, "overlay-journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	manager.SetOverlayDriver(NewOverlayDriver(core.client, journal))
	manager.certWait = func(context.Context, string) error { return nil }

	// The commit lands, and then the journal cannot record that it did.
	core.afterCommit = func() {
		_ = os.RemoveAll(journalDir)
		_ = os.WriteFile(journalDir, []byte("not a directory"), 0o600)
	}

	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	before := mustRead(t, interceptPath)
	enabled := true
	_, err = manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled})
	if err == nil {
		t.Fatal("a journal write failure after a successful commit was not reported at all")
	}
	if !errors.Is(err, errInterceptApplyUnresolved) {
		t.Fatalf("error = %v, want errInterceptApplyUnresolved: reporting this as a plain apply failure tells the operator the change did not happen, and it did", err)
	}
	if errors.Is(err, errInterceptApplyFailed) {
		t.Fatalf("error = %v, must not also be an apply failure: the two mean opposite things to the console", err)
	}
	if core.commitCount() != 1 {
		t.Fatalf("commits = %d, want 1", core.commitCount())
	}
	after := mustRead(t, interceptPath)
	if after == before {
		t.Fatal("the sidecar document was rolled back underneath a generation that is live; that is the mismatch this exists to prevent")
	}
	if controller.putCalls != 0 {
		t.Fatalf("a routing change reloaded mihomo: %d controller calls", controller.putCalls)
	}
}

// The compensation still runs for everything between the first publication and
// the end of the transaction. The certificate wait is the step in the middle,
// and it used to be the only one with a compensation at all.
func TestApplyCompensatesWhenTheCertificateNeverArrives(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroup = "Proxies"
	manager, _, _, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error {
		return errors.New("the certificate publisher never acknowledged this host set")
	}
	originalIntercept := mustRead(t, interceptPath)
	originalMihomo := mustRead(t, mihomoPath)

	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); !errors.Is(err, errInterceptApplyFailed) {
		t.Fatalf("certificate failure error = %v, want an apply failure", err)
	}
	if mustRead(t, interceptPath) != originalIntercept {
		t.Fatal("the sidecar document was not restored after the certificate wait failed")
	}
	if mustRead(t, mihomoPath) != originalMihomo {
		t.Fatal("a failed transaction touched the operator's mihomo file")
	}
}
