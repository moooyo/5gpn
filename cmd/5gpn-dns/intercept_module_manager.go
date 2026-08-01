package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	errInterceptModulesUnavailable = errors.New("interception module management unavailable")
	errInterceptRevisionConflict   = errors.New("interception module revision changed")
	errInterceptModuleConflict     = errors.New("interception module conflicts with the current runtime")
	errInterceptModuleNotFound     = errors.New("interception module not found")
	errInterceptApplyFailed        = errors.New("interception module apply failed")

	errInterceptRoutingDriverUnavailable = errors.New("interception routing driver unavailable; run '5gpn mihomo-reset' if the mihomo config lost its overlay anchors")
)

const (
	interceptCertificatePollInterval      = 100 * time.Millisecond
	interceptCertificateRetriggerInterval = 500 * time.Millisecond
	interceptCertificateWaitLimit         = 15 * time.Second
)

type InterceptModuleManager struct {
	mu sync.Mutex

	store      *InterceptConfigStore
	handler    *Handler
	parser     interceptModuleParser
	mihomo     *MihomoConfigStore
	infra      InfraParams
	tester     mihomoTester
	controller mihomoController

	certStatePath string
	certWait      func(context.Context, string) error
	certRepublish func(context.Context, string, []byte) error
	sidecarTest   interceptConfigTester
	onApplied     func()
	// sidecar, when set, is the sidecar's control API. Publishing through it
	// replaces writing the sidecar's private file: the file made this package
	// responsible for the sidecar's on-disk layout, and neither side could name
	// a version or say which state the other believed was live.
	sidecar *SidecarClient
	// sidecarStart bounds how long a master enable waits for the sidecar to
	// come up after the configuration file is written. Zero means the default;
	// tests shorten it so they do not sleep through a real start-up window.
	sidecarStart time.Duration
	// overlay, when set, publishes routing as typed generations instead of
	// rewriting the operator's mihomo YAML. Selecting it is a startup decision
	// recorded in the overlay journal, not a per-call one: the anchored config
	// and the typed generation are two halves of one arrangement, and a gateway
	// that changed its mind mid-run would leave the file describing one policy
	// and the core enforcing another.
	overlay *OverlayDriver
}

type interceptConfigTester interface {
	Test(context.Context, string) error
}

type realInterceptConfigTester struct{}

func (realInterceptConfigTester) Test(ctx context.Context, path string) error {
	output, err := exec.CommandContext(ctx, "/opt/5gpn/bin/5gpn-intercept", "--config", path, "--check-config").CombinedOutput()
	if err != nil {
		return fmt.Errorf("5gpn-intercept --check-config: %v: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func NewInterceptModuleManager(
	store *InterceptConfigStore,
	handler *Handler,
	resolver HostResolver,
	mihomo *MihomoConfigStore,
	infra InfraParams,
	tester mihomoTester,
	controller mihomoController,
) *InterceptModuleManager {
	manager := &InterceptModuleManager{
		store:      store,
		handler:    handler,
		parser:     newInterceptModuleParser(resolver),
		mihomo:     mihomo,
		infra:      infra,
		tester:     tester,
		controller: controller,
	}
	if store != nil && store.Path == "/etc/5gpn/intercept/config.json" {
		manager.certStatePath = "/etc/5gpn/intercept/cert-state"
	}
	return manager
}

func (m *InterceptModuleManager) SetAppliedHook(hook func()) {
	m.mu.Lock()
	m.onApplied = hook
	m.mu.Unlock()
}

// SetSidecarClient installs the sidecar control API client. Without one the
// manager keeps writing the sidecar's file, which is the rollback position and
// the state of a deployment that has not migrated yet.
func (m *InterceptModuleManager) SetSidecarClient(client *SidecarClient) {
	m.mu.Lock()
	m.sidecar = client
	m.mu.Unlock()
}

// sidecarStartWait bounds how long a master enable waits for the sidecar to
// come up after the configuration file is written. Short enough that the
// manager lock is not held for long, long enough for the path unit to start a
// process that takes about a second.
const sidecarStartWait = 6 * time.Second

// interceptRollbackTimeout bounds an undo. It is generous because the undo runs
// detached from the caller's context on purpose, and stingy because the
// transaction still holds three locks while it happens.
const interceptRollbackTimeout = 20 * time.Second

// rollbackSidecarDocument undoes publishSidecarDocument.
//
// Rewriting the file is not an undo once a bundle has been pushed. PublishBundle
// stages *and* commits, and configStore.Current latches onto the bundle source
// permanently the first time one goes live -- so the sidecar keeps serving the
// candidate while the still-live generation names the old bundle. Readiness then
// stops being asserted, the lease lapses, and every captured connection REJECTs.
// The sidecar's pointer is durable across its own restart, so nothing repairs
// that until an unrelated transaction succeeds or the core process restarts and
// PrepareRuntime republishes. The error string said "sidecar rollback" for an
// operation that never happened.
//
// Detached from the caller's context, because a cancelled request is one of the
// ways the certificate wait ends, and an undo skipped for that reason leaves
// exactly the state this exists to prevent.
func (m *InterceptModuleManager) rollbackSidecarDocument(ctx context.Context, body []byte) error {
	rollback, cancel := context.WithTimeout(context.WithoutCancel(ctx), interceptRollbackTimeout)
	defer cancel()
	client := m.sidecar
	if client != nil && sidecarSocketPresent(client) {
		if _, err := client.PublishBundle(rollback, interceptBundleID(body), body); err != nil {
			// Surfaced rather than swallowed: the processor is now serving a
			// bundle no generation names, which an operator has to know about.
			documentErr := m.store.writeAtomicContext(rollback, body)
			return fmt.Errorf("restore bundle: %w (document: %v)", err, documentErr)
		}
	}
	return m.store.writeAtomicContext(rollback, body)
}

// publishSidecarDocument puts the candidate document into effect in the sidecar.
//
// The ordering the transaction depends on is that the sidecar holds the new
// document before the certificate wait and before mihomo publishes, so capture
// traffic never arrives at a processor that cannot serve it.
//
// Which channel carries it is decided per call rather than once at startup. The
// sidecar's unit refuses to run while the MITM master is off, so its socket is
// always gone by the time an operator turns the master back on — a client
// installed at boot failed every such enable for want of the very process the
// enable exists to start, which made the master switch a one-way door.
//
// Called with m.mu held (see mutate), so the client is read without taking it.
func (m *InterceptModuleManager) publishSidecarDocument(ctx context.Context, body []byte) error {
	client := m.sidecar
	if client == nil {
		return m.store.writeAtomicContext(ctx, body)
	}
	if sidecarSocketPresent(client) {
		if _, err := client.PublishBundle(ctx, interceptBundleID(body), body); err != nil {
			return err
		}
		// The file is still written while both paths are supported, so a
		// downgrade to a build without the API finds the state it expects. It is
		// no longer what the sidecar reads.
		return m.store.writeAtomicContext(ctx, body)
	}

	// No socket: write the file first, because that is what the runtime path
	// unit watches and what the sidecar cold starts from, then push once it is
	// listening. Writing alone is not enough — a sidecar serving the file has no
	// bundle live, so readiness is never asserted and capture stays fail-closed
	// indefinitely even though every step reported success.
	if err := m.store.writeAtomicContext(ctx, body); err != nil {
		return err
	}
	wait := m.sidecarStart
	if wait <= 0 {
		wait = sidecarStartWait
	}
	if !waitForSidecarSocket(ctx, client, wait) {
		log.Printf("intercept: sidecar did not start within %s; it serves the configuration file until the next transaction", wait)
		return nil
	}
	if _, err := client.PublishBundle(ctx, interceptBundleID(body), body); err != nil {
		// The document is already durable and correct, so the transaction
		// stands. The overlay generation published next asserts processor
		// readiness and stays fail-closed on its own if the sidecar never
		// adopts the bundle, which is the safe direction to fail.
		log.Printf("intercept: sidecar started but did not adopt the bundle (%v); it serves the configuration file", err)
	}
	return nil
}

// sidecarSocketPresent reports whether the control API is there to talk to right
// now. A socket that vanishes between this check and the call only costs the
// transaction the error it would have had anyway.
func sidecarSocketPresent(client *SidecarClient) bool {
	path := client.SocketPath()
	if path == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil
}

// waitForSidecarSocket polls until the control socket appears, the deadline
// passes, or the caller gives up. Polling rather than watching: the wait is
// seconds long and only happens on a master enable.
func waitForSidecarSocket(ctx context.Context, client *SidecarClient, within time.Duration) bool {
	deadline := time.Now().Add(within)
	for {
		if sidecarSocketPresent(client) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(150 * time.Millisecond):
		}
	}
}

// interceptBundleID derives a stable bundle identity from the document itself,
// so re-publishing identical desired state addresses the same bundle rather
// than accumulating one per attempt.
func interceptBundleID(body []byte) string {
	return "b-" + interceptRevision(body)[:24]
}

// SetOverlayDriver installs the runtime-overlay driver. It is required: the
// manager has no other way to publish routing, and selectInterceptRoutingDriver
// refuses to start without one.
func (m *InterceptModuleManager) SetOverlayDriver(driver *OverlayDriver) {
	m.mu.Lock()
	m.overlay = driver
	m.mu.Unlock()
}

// analyzeInterceptRouting reads the anchored document. Under the overlay a
// mihomo config carrying no rendered interception rules is the correct steady
// state, not a fault. Callers already hold m.mu.
func (m *InterceptModuleManager) analyzeInterceptRouting(text string) interceptRoutingAnalysis {
	return analyzeOverlayAnchoredDocument(text)
}

// publishOverlayGeneration commits the desired routing as a typed generation.
//
// The certificate wait stays in the caller rather than moving into the driver's
// hook, so "the certificate is in place before capture traffic can arrive"
// remains one implementation on the path every mutation takes.
func (m *InterceptModuleManager) publishOverlayGeneration(
	ctx context.Context,
	document interceptConfigDocument,
	matchTarget string,
	documentRevision string,
	certificateHostSetDigest string,
	sidecarBundleDigest string,
) error {
	// The driver is installed at startup and is the only publication path. If
	// its probe failed, every routing change has to say so rather than dereference
	// a nil driver -- a gateway that accepts toggles and applies none of them is
	// worse than one that refuses them.
	if m.overlay == nil {
		return errInterceptRoutingDriverUnavailable
	}
	_, err := m.overlay.Publish(ctx, overlayCompileInput{
		Document:                 document,
		MatchTarget:              matchTarget,
		DocumentRevision:         documentRevision,
		Transition:               overlayTransitionRevoke,
		CertificateHostSetDigest: certificateHostSetDigest,
		SidecarBundleDigest:      sidecarBundleDigest,
	})
	return err
}

func (m *InterceptModuleManager) SetSidecarTester(tester interceptConfigTester) {
	m.mu.Lock()
	m.sidecarTest = tester
	m.mu.Unlock()
}

func (m *InterceptModuleManager) PrepareRuntime() error {
	if m == nil || m.store == nil {
		return errInterceptModulesUnavailable
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	document, body, err := m.store.Read()
	m.store.mu.Unlock()
	if err != nil {
		return err
	}
	if !document.MITM.Enabled {
		// The real document, not nil. "Inert" is not "empty": the snapshot records
		// mitmEnabled and CaptureDNS refuses to match while it is false, so capture
		// stays fail-closed either way -- but publishing nil also discards the
		// [Host] mappings, which carry no MITM gate by design, and the attribution
		// the resolve test needs to say "this extension declared the name, and it
		// is inert because the master is off". The apply path publishes the
		// document unconditionally, so nil here meant the same document produced
		// two different overlays depending on which path last published it: correct
		// right after the toggle, silently empty after the next daemon start or
		// mihomo config PUT.
		m.publishHosts(&document)
		return nil
	}
	if m.mihomo == nil || m.controller == nil {
		if len(activeInterceptHosts(document)) > 0 {
			return errors.New("enabled interception modules cannot be reconciled without mihomo management")
		}
		m.publishHosts(nil)
		return nil
	}
	m.mihomo.Lock()
	text, err := m.mihomo.Read()
	m.mihomo.Unlock()
	if err != nil {
		return err
	}
	gate := m.routingGateFor(document, text)
	if !gate.ready {
		m.publishHosts(nil)
		return fmt.Errorf("interception routing is not ready: %s", gate.reason)
	}
	analysis := gate.analysis
	// Republish the generation from the document, which is the authority.
	//
	// Startup used to trust whatever the core had recovered from its own store.
	// That holds while the store is intact and fails silently when it is not: a
	// core with no active generation does not reject captured traffic, it stops
	// matching it, so every captured host falls through to the operator's own
	// rules and leaves unintercepted. The gateway looks healthy while the thing
	// it exists to do is not happening.
	//
	// An upgrade that changes the document shape is one way to arrive there --
	// the installer discards generations it may be unable to reconstruct -- but
	// it is not the only one, and none of them should depend on someone noticing.
	// Publishing here makes the coordinator authoritative at every start: the
	// driver short-circuits when the recomputed generation is already live, so a
	// healthy boot pays a readback and nothing else.
	// Both halves, in the order the apply path uses: the processor holds the
	// document before mihomo publishes a generation naming it. Republishing
	// only the generation is worse than republishing neither -- the sidecar
	// goes on serving whatever its own store cold started from, the
	// generation names the document's bundle, and readiness is refused for
	// the mismatch, which fails every captured connection closed.
	if err := m.publishSidecarDocument(context.Background(), body); err != nil {
		m.publishHosts(nil)
		return fmt.Errorf("the interception document could not be republished: %w", err)
	}
	if err := m.publishOverlayGeneration(context.Background(), document, analysis.MatchTarget,
		interceptRevision(body), interceptCertificateDigest(certificateInterceptHosts(document)),
		interceptBundleID(body)); err != nil {
		m.publishHosts(nil)
		return fmt.Errorf("interception routing could not be republished: %w", err)
	}
	m.publishHosts(&document)
	return nil
}

func (m *InterceptModuleManager) ReconcileMihomoText(text string) error {
	if m == nil || m.store == nil {
		return errInterceptModulesUnavailable
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	document, _, err := m.store.Read()
	m.store.mu.Unlock()
	if err != nil {
		m.publishHosts(nil)
		return err
	}
	if !document.MITM.Enabled {
		// See PrepareRuntime: inert is not empty, and the apply path publishes the
		// document unconditionally. These three publications have to agree.
		m.publishHosts(&document)
		return nil
	}
	if gate := m.routingGateFor(document, text); !gate.ready {
		m.publishHosts(nil)
		return fmt.Errorf("interception routing is not ready: %s", gate.reason)
	}
	m.publishHosts(&document)
	return nil
}

// LockMihomoCandidate prevents an interception mutation from racing a raw
// mihomo config apply. The caller must invoke the returned unlock function
// after the candidate has either been rejected or fully applied.
func (m *InterceptModuleManager) LockMihomoCandidate(text string) (func(), error) {
	if m == nil || m.store == nil {
		return func() {}, nil
	}
	m.mu.Lock()
	unlock := func() { m.mu.Unlock() }
	m.store.mu.Lock()
	document, _, err := m.store.Read()
	m.store.mu.Unlock()
	if err != nil {
		unlock()
		return nil, err
	}
	available, err := interceptAvailableEgressGroups(text)
	if err != nil {
		unlock()
		return nil, err
	}
	if err := validateInterceptEgressBindings(document, available); err != nil {
		unlock()
		return nil, fmt.Errorf("%w: %v", errInterceptModuleConflict, err)
	}
	return unlock, nil
}

func (m *InterceptModuleManager) View() (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.viewLocked()
}

func (m *InterceptModuleManager) SettingsView() (interceptSettingsView, error) {
	if m == nil || m.store == nil {
		return interceptSettingsView{}, errInterceptModulesUnavailable
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	defer m.store.mu.Unlock()
	document, body, err := m.store.Read()
	if err != nil {
		return interceptSettingsView{}, err
	}
	return interceptSettings(document, body), nil
}

func (m *InterceptModuleManager) Snapshot(id string) (interceptModuleSnapshotView, error) {
	if m == nil || m.store == nil {
		return interceptModuleSnapshotView{}, errInterceptModulesUnavailable
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	document, _, err := m.store.Read()
	m.store.mu.Unlock()
	if err != nil {
		return interceptModuleSnapshotView{}, err
	}
	for _, module := range document.Modules {
		if module.ID != id {
			continue
		}
		view := interceptModuleSnapshotView{
			ID: module.ID, Name: module.Name,
			SourceURL: module.Source.URL, SourceDigest: module.Source.Digest, SourceBody: module.Source.Body,
			Scripts: make([]interceptScriptSnapshotView, 0, len(module.Scripts)),
		}
		for _, script := range module.Scripts {
			view.Scripts = append(view.Scripts, interceptScriptSnapshotView{
				ID: script.ID, URL: script.ScriptURL, Digest: script.ScriptDigest, Body: script.ScriptBody,
			})
		}
		return view, nil
	}
	return interceptModuleSnapshotView{}, errInterceptModuleNotFound
}

func (m *InterceptModuleManager) viewLocked() (interceptModulesView, error) {
	m.store.mu.Lock()
	document, body, err := m.store.Read()
	m.store.mu.Unlock()
	if err != nil {
		return interceptModulesView{}, err
	}
	ready, reason, availableGroups := m.routingReadyLocked(document)
	// modulesViewFromDocument is the same assembly, and it used to be written out
	// here a second time -- including the egress-group-required /
	// egress-group-missing precedence and the settings-required override. Two
	// copies of a per-module verdict means a change to that precedence lands in
	// the list endpoint and not in the response returned straight from a
	// mutation, so the console shows one answer on refresh and another right
	// after a toggle, with no test comparing them.
	//
	// The one difference was modulesViewFromDocument's !MITM.Enabled guard, which
	// routingReadyLocked already produces as (false, "mitm-disabled", groups).
	return modulesViewFromDocument(document, body, ready, reason, availableGroups), nil
}

func moduleRuntimeReason(ready bool, reason string) string {
	if !ready {
		return reason
	}
	return ""
}

// interceptRoutingGate is the one answer to "can routing be published for this
// document against this mihomo config, and if not, why".
//
// It exists because that question was answered in three places with two
// different orderings, and they had already drifted: routingReadyLocked checked
// the egress bindings before the credentials, while PrepareRuntime and
// ReconcileMihomoText folded credentials into the manageability branch ahead of
// them. A document with both a renamed egress group and mismatched credentials
// therefore reported "egress-group-missing" to the console and
// "credential-mismatch" to the log, for the same state. The console's ordering
// wins: a missing group is the more actionable of the two.
type interceptRoutingGate struct {
	ready    bool
	reason   string
	groups   []string
	analysis interceptRoutingAnalysis
}

func (m *InterceptModuleManager) routingGateFor(document interceptConfigDocument, text string) interceptRoutingGate {
	gate := interceptRoutingGate{}
	availableGroups, groupErr := interceptAvailableEgressGroups(text)
	if groupErr != nil {
		gate.reason = "proxy-groups-structure-conflict"
		return gate
	}
	gate.groups = availableGroups
	if !document.MITM.Enabled {
		gate.reason = "mitm-disabled"
		return gate
	}
	gate.analysis = m.analyzeInterceptRouting(text)
	if !gate.analysis.Manageable {
		gate.reason = gate.analysis.Reason
		return gate
	}
	// The anchored analysis judges positions, not bindings: the egress groups
	// live in the operator's own proxy-groups and an extension names one by
	// string. An operator who renamed or deleted a bound group leaves a
	// generation authorising a group that no longer exists, so this has to fail
	// closed here rather than wait for the next publication to notice.
	if err := validateInterceptEgressBindings(document, gate.analysis.AvailableEgressGroups); err != nil {
		gate.reason = "egress-group-missing"
		return gate
	}
	if !interceptCredentialsMatch(text, document) {
		gate.reason = "credential-mismatch"
		return gate
	}
	if len(activeInterceptHosts(document)) > 0 && !m.certificateReady(document) {
		gate.reason = "certificate-not-ready"
		return gate
	}
	gate.ready = true
	return gate
}

func (m *InterceptModuleManager) routingReadyLocked(document interceptConfigDocument) (bool, string, []string) {
	if m.mihomo == nil || m.controller == nil {
		return false, "mihomo-management-unavailable", nil
	}
	m.mihomo.Lock()
	text, err := m.mihomo.Read()
	m.mihomo.Unlock()
	if err != nil {
		return false, "mihomo-config-unreadable", nil
	}
	gate := m.routingGateFor(document, text)
	return gate.ready, gate.reason, gate.groups
}

func interceptExecutionOrderIndex(order []string) map[string]int {
	indices := make(map[string]int, len(order))
	for index, id := range order {
		indices[id] = index + 1
	}
	return indices
}

func validateInterceptEgressBindings(document interceptConfigDocument, available []string) error {
	groups := make(map[string]struct{}, len(available))
	for _, group := range available {
		groups[group] = struct{}{}
	}
	for _, module := range document.Modules {
		if module.EgressGroup == "" {
			continue
		}
		if _, exists := groups[module.EgressGroup]; !exists {
			return fmt.Errorf("egress group %q selected by extension %q does not exist", module.EgressGroup, module.ID)
		}
	}
	return nil
}

func (m *InterceptModuleManager) Import(ctx context.Context, request interceptModuleImportRequest) (interceptModulesView, error) {
	return m.importWithExpected(ctx, request, "")
}

// PreviewImport fetches and validates an extension without changing the
// persisted module document. The returned snapshot digest can be bound to an
// explicit confirmation and supplied to ImportExpected.
func (m *InterceptModuleManager) PreviewImport(ctx context.Context, request interceptModuleImportRequest) (interceptModuleView, error) {
	if m == nil || m.store == nil {
		return interceptModuleView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(request.Revision) {
		return interceptModuleView{}, errors.New("a valid revision is required")
	}
	module, err := m.parser.Import(ctx, request)
	if err != nil {
		return interceptModuleView{}, err
	}
	return m.previewSnapshot(ctx, request.Revision, module)
}

// ImportExpected refetches or reparses the requested extension and verifies
// that its immutable snapshot still matches the confirmed preview before the
// existing module revision CAS commits it. Legacy callers use Import, while
// confirmation workflows must supply a non-empty expected digest here.
func (m *InterceptModuleManager) ImportExpected(
	ctx context.Context,
	request interceptModuleImportRequest,
	expectedSnapshotDigest string,
) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if !validSHA256(expectedSnapshotDigest) {
		return interceptModulesView{}, errors.New("a valid expected snapshot digest is required")
	}
	return m.importWithExpected(ctx, request, expectedSnapshotDigest)
}

func (m *InterceptModuleManager) importWithExpected(
	ctx context.Context,
	request interceptModuleImportRequest,
	expectedSnapshotDigest string,
) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(request.Revision) {
		return interceptModulesView{}, errors.New("a valid revision is required")
	}
	if expectedSnapshotDigest != "" && !validSHA256(expectedSnapshotDigest) {
		return interceptModulesView{}, errors.New("a valid expected snapshot digest is required")
	}
	module, err := m.parser.Import(ctx, request)
	if err != nil {
		return interceptModulesView{}, err
	}
	if expectedSnapshotDigest != "" && interceptModuleSnapshotDigest(module) != expectedSnapshotDigest {
		return interceptModulesView{}, fmt.Errorf("%w: extension snapshot changed since preview", errInterceptRevisionConflict)
	}
	return m.importSnapshot(ctx, request.Revision, module)
}

func (m *InterceptModuleManager) previewSnapshot(
	ctx context.Context,
	revision string,
	module interceptModuleSnapshot,
) (interceptModuleView, error) {
	if m == nil || m.store == nil {
		return interceptModuleView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(revision) {
		return interceptModuleView{}, errors.New("a valid revision is required")
	}
	if err := validateInterceptModule(module); err != nil {
		return interceptModuleView{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	document, body, err := m.store.Read()
	if err != nil {
		m.store.mu.Unlock()
		return interceptModuleView{}, err
	}
	if interceptRevision(body) != revision {
		m.store.mu.Unlock()
		return interceptModuleView{}, errInterceptRevisionConflict
	}
	for _, existing := range document.Modules {
		if existing.ID == module.ID {
			m.store.mu.Unlock()
			return interceptModuleView{}, fmt.Errorf("%w: extension id %q is already installed", errInterceptModuleConflict, module.ID)
		}
	}
	document.Modules = append(document.Modules, module)
	document.ExecutionOrder = append(document.ExecutionOrder, module.ID)
	candidateBody, err := marshalInterceptDocument(document)
	m.store.mu.Unlock()
	if err != nil {
		return interceptModuleView{}, err
	}
	if err := m.validateSidecarCandidate(ctx, candidateBody); err != nil {
		return interceptModuleView{}, err
	}
	view := interceptCandidateView(module)
	view.ExecutionOrder = len(document.ExecutionOrder)
	return view, nil
}

// importSnapshot publishes a module that has already been fetched and parsed by
// the native extension parser. Marketplace installation uses this path so the
// manifest and scripts are fetched exactly once before catalog integrity checks
// and the normal module revision CAS.
func (m *InterceptModuleManager) importSnapshot(ctx context.Context, revision string, module interceptModuleSnapshot) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(revision) {
		return interceptModulesView{}, errors.New("a valid revision is required")
	}
	if err := validateInterceptModule(module); err != nil {
		return interceptModulesView{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	defer m.store.mu.Unlock()
	document, oldBody, err := m.store.Read()
	if err != nil {
		return interceptModulesView{}, err
	}
	if interceptRevision(oldBody) != revision {
		return interceptModulesView{}, errInterceptRevisionConflict
	}
	for _, existing := range document.Modules {
		if existing.ID == module.ID {
			return interceptModulesView{}, fmt.Errorf("%w: extension id %q is already installed", errInterceptModuleConflict, module.ID)
		}
	}
	document.Modules = append(document.Modules, module)
	document.ExecutionOrder = append(document.ExecutionOrder, module.ID)
	newBody, err := marshalInterceptDocument(document)
	if err != nil {
		return interceptModulesView{}, err
	}
	if err := m.validateSidecarCandidate(ctx, newBody); err != nil {
		return interceptModulesView{}, err
	}
	if err := m.store.writeAtomicContext(ctx, newBody); err != nil {
		return interceptModulesView{}, err
	}
	// viewLocked takes the store mutex, so release it before composing the view.
	m.store.mu.Unlock()
	view, viewErr := m.viewLocked()
	m.store.mu.Lock()
	return view, viewErr
}

func (m *InterceptModuleManager) CheckUpdate(ctx context.Context, id, revision string) (interceptModuleUpdateCheckView, error) {
	if m == nil || m.store == nil {
		return interceptModuleUpdateCheckView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(revision) {
		return interceptModuleUpdateCheckView{}, errors.New("a valid revision is required")
	}
	m.store.mu.Lock()
	document, body, err := m.store.Read()
	if err != nil {
		m.store.mu.Unlock()
		return interceptModuleUpdateCheckView{}, err
	}
	if interceptRevision(body) != revision {
		m.store.mu.Unlock()
		return interceptModuleUpdateCheckView{}, errInterceptRevisionConflict
	}
	var current interceptModuleSnapshot
	found := false
	for _, module := range document.Modules {
		if module.ID == id {
			current = module
			found = true
			break
		}
	}
	m.store.mu.Unlock()
	if !found {
		return interceptModuleUpdateCheckView{}, errInterceptModuleNotFound
	}
	if strings.TrimSpace(current.Source.URL) == "" {
		return interceptModuleUpdateCheckView{}, errors.New("only URL-sourced extensions can check for updates")
	}
	candidate, err := m.parser.Import(ctx, interceptModuleImportRequest{URL: current.Source.URL})
	if err != nil {
		return interceptModuleUpdateCheckView{}, err
	}
	if candidate.ID != current.ID {
		return interceptModuleUpdateCheckView{}, errors.New("updated manifest changed metadata.id")
	}
	// Digest both snapshots before taking the lock. interceptModuleSnapshotDigest
	// panics by design on a value encoding/json cannot represent, and this
	// function releases m.store.mu by hand on every branch rather than with a
	// defer -- so a panic under it stranded the mutex and left every later View,
	// enable, import and delete blocked until the daemon restarted. The candidate
	// is bytes a publisher controls, refetched from their own URL, which is
	// exactly the input that should not be digested inside a critical section.
	candidateDigest := interceptModuleSnapshotDigest(candidate)
	currentDigest := interceptModuleSnapshotDigest(current)

	m.store.mu.Lock()
	latest, latestBody, err := m.store.Read()
	if err != nil {
		m.store.mu.Unlock()
		return interceptModuleUpdateCheckView{}, err
	}
	if interceptRevision(latestBody) != revision || !interceptModuleSourceUnchanged(latest, id, current.Source.URL, current.Source.Digest) {
		m.store.mu.Unlock()
		return interceptModuleUpdateCheckView{}, errInterceptRevisionConflict
	}
	if candidateDigest == currentDigest {
		m.store.mu.Unlock()
		return interceptModuleUpdateCheckView{Revision: revision, State: "unchanged"}, nil
	}
	candidate.Settings = mergeInterceptSettingValues(current.Settings, candidate.Settings)
	candidate.EgressGroup = current.EgressGroup
	candidate.CaptureDNS = current.CaptureDNS
	candidateDocument := latest
	candidateDocument.Modules = append([]interceptModuleSnapshot(nil), latest.Modules...)
	found = false
	for index := range candidateDocument.Modules {
		if candidateDocument.Modules[index].ID == id {
			candidateDocument.Modules[index] = candidate
			found = true
			break
		}
	}
	if !found {
		m.store.mu.Unlock()
		return interceptModuleUpdateCheckView{}, errInterceptModuleNotFound
	}
	candidateBody, err := marshalInterceptDocument(candidateDocument)
	m.store.mu.Unlock()
	if err != nil {
		return interceptModuleUpdateCheckView{}, err
	}
	if err := m.validateSidecarCandidate(ctx, candidateBody); err != nil {
		return interceptModuleUpdateCheckView{}, err
	}
	view := interceptCandidateView(candidate)
	view.ExecutionOrder = interceptExecutionOrderIndex(latest.ExecutionOrder)[id]
	return interceptModuleUpdateCheckView{Revision: revision, State: "available", Candidate: &view}, nil
}

func (m *InterceptModuleManager) ApplyUpdate(ctx context.Context, id, revision, digest string) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(revision) || !validSHA256(digest) {
		return interceptModulesView{}, errors.New("a valid revision and candidate digest are required")
	}
	m.store.mu.Lock()
	document, body, err := m.store.Read()
	if err != nil {
		m.store.mu.Unlock()
		return interceptModulesView{}, err
	}
	if interceptRevision(body) != revision {
		m.store.mu.Unlock()
		return interceptModulesView{}, errInterceptRevisionConflict
	}
	var current interceptModuleSnapshot
	found := false
	for _, module := range document.Modules {
		if module.ID == id {
			current = module
			found = true
			break
		}
	}
	m.store.mu.Unlock()
	if !found {
		return interceptModulesView{}, errInterceptModuleNotFound
	}
	if current.Enabled {
		return interceptModulesView{}, errors.New("disable the extension before replacing its immutable snapshot")
	}
	if strings.TrimSpace(current.Source.URL) == "" {
		return interceptModulesView{}, errors.New("only URL-sourced extensions can be updated")
	}
	candidate, err := m.parser.Import(ctx, interceptModuleImportRequest{URL: current.Source.URL})
	if err != nil {
		return interceptModulesView{}, err
	}
	if candidate.ID != current.ID {
		return interceptModulesView{}, errors.New("updated manifest changed metadata.id")
	}
	if interceptModuleSnapshotDigest(candidate) != digest {
		return interceptModulesView{}, errInterceptRevisionConflict
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	latest, latestBody, err := m.store.Read()
	if err != nil {
		m.store.mu.Unlock()
		return interceptModulesView{}, err
	}
	if interceptRevision(latestBody) != revision || !interceptModuleSourceUnchanged(latest, id, current.Source.URL, current.Source.Digest) {
		m.store.mu.Unlock()
		return interceptModulesView{}, errInterceptRevisionConflict
	}
	index := -1
	for i, module := range latest.Modules {
		if module.ID == id {
			index = i
		}
	}
	if index < 0 {
		m.store.mu.Unlock()
		return interceptModulesView{}, errInterceptModuleNotFound
	}
	candidate.Settings = mergeInterceptSettingValues(latest.Modules[index].Settings, candidate.Settings)
	candidate.EgressGroup = latest.Modules[index].EgressGroup
	candidate.CaptureDNS = latest.Modules[index].CaptureDNS
	latest.Modules[index] = candidate
	newBody, err := marshalInterceptDocument(latest)
	if err == nil {
		err = m.validateSidecarCandidate(ctx, newBody)
	}
	if err == nil {
		err = m.store.writeAtomicContext(ctx, newBody)
	}
	m.store.mu.Unlock()
	if err != nil {
		return interceptModulesView{}, err
	}
	return m.viewLocked()
}

func interceptModuleSourceUnchanged(document interceptConfigDocument, id, sourceURL, digest string) bool {
	for _, module := range document.Modules {
		if module.ID == id {
			return module.Source.URL == sourceURL && module.Source.Digest == digest
		}
	}
	return false
}

func (m *InterceptModuleManager) Delete(ctx context.Context, id, revision string) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if ctx == nil {
		return interceptModulesView{}, errors.New("an interception operation context is required")
	}
	if err := ctx.Err(); err != nil {
		return interceptModulesView{}, err
	}
	if err := lockMutexContext(ctx, &m.mu); err != nil {
		return interceptModulesView{}, err
	}
	defer m.mu.Unlock()
	if err := lockMutexContext(ctx, &m.store.mu); err != nil {
		return interceptModulesView{}, err
	}
	if err := ctx.Err(); err != nil {
		m.store.mu.Unlock()
		return interceptModulesView{}, err
	}
	document, oldBody, err := m.store.Read()
	if err != nil {
		m.store.mu.Unlock()
		return interceptModulesView{}, err
	}
	if interceptRevision(oldBody) != revision {
		m.store.mu.Unlock()
		return interceptModulesView{}, errInterceptRevisionConflict
	}
	index := -1
	for i, module := range document.Modules {
		if module.ID == id {
			index = i
			if module.Enabled {
				m.store.mu.Unlock()
				return interceptModulesView{}, errors.New("disable the module before deleting it")
			}
			break
		}
	}
	if index < 0 {
		m.store.mu.Unlock()
		return interceptModulesView{}, errInterceptModuleNotFound
	}
	document.Modules = append(document.Modules[:index], document.Modules[index+1:]...)
	document.ExecutionOrder = removeInterceptModuleID(document.ExecutionOrder, id)
	newBody, err := marshalInterceptDocument(document)
	if err == nil {
		err = m.validateSidecarCandidate(ctx, newBody)
	}
	if err == nil {
		err = ctx.Err()
	}
	if err == nil {
		err = m.store.writeAtomicContext(ctx, newBody)
	}
	m.store.mu.Unlock()
	if err != nil {
		return interceptModulesView{}, err
	}
	return m.viewLocked()
}

type interceptModuleUpdate struct {
	Revision    string                     `json:"revision"`
	Enabled     *bool                      `json:"enabled,omitempty"`
	EgressGroup *string                    `json:"egress_group,omitempty"`
	CaptureDNS  *string                    `json:"capture_dns,omitempty"`
	Settings    map[string]json.RawMessage `json:"settings,omitempty"`
}

type interceptMutationEffects struct {
	routingChanged         bool
	validateEgressBindings bool
}

func (m *InterceptModuleManager) Update(ctx context.Context, id string, update interceptModuleUpdate) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(update.Revision) || (update.Enabled == nil && update.EgressGroup == nil && update.CaptureDNS == nil && update.Settings == nil) {
		return interceptModulesView{}, errors.New("revision and at least one update field are required")
	}
	return m.mutate(ctx, update.Revision, func(document *interceptConfigDocument) (interceptMutationEffects, error) {
		for index := range document.Modules {
			module := &document.Modules[index]
			if module.ID != id {
				continue
			}
			effects := interceptMutationEffects{}
			if update.Settings != nil {
				if err := updateInterceptModuleSettings(module, update.Settings); err != nil {
					return interceptMutationEffects{}, err
				}
			}
			if update.EgressGroup != nil {
				group := *update.EgressGroup
				if err := validateInterceptEgressGroupBinding(group); err != nil {
					return interceptMutationEffects{}, err
				}
				// A non-empty binding must still exist even when this update is a
				// byte-for-byte no-op or the extension is not currently active.
				effects.validateEgressBindings = group != ""
				effects.routingChanged = document.MITM.Enabled && module.Enabled && module.EgressGroup != group
				module.EgressGroup = group
			}
			if update.CaptureDNS != nil {
				if err := validateInterceptCaptureDNS(*update.CaptureDNS); err != nil {
					return interceptMutationEffects{}, err
				}
				effects.routingChanged = effects.routingChanged ||
					(document.MITM.Enabled && module.Enabled && module.CaptureDNS != *update.CaptureDNS)
				module.CaptureDNS = *update.CaptureDNS
			}
			if update.Enabled != nil {
				if *update.Enabled && !interceptModuleSettingsReady(module.Settings) {
					return interceptMutationEffects{}, errors.New("configure every required extension setting before enable")
				}
				if *update.Enabled && module.EgressGroupRequired && module.EgressGroup == "" {
					return interceptMutationEffects{}, errors.New("select an egress group before enabling this extension")
				}
				effects.routingChanged = effects.routingChanged ||
					(document.MITM.Enabled && module.Enabled != *update.Enabled)
				module.Enabled = *update.Enabled
			}
			return effects, nil
		}
		return interceptMutationEffects{}, errInterceptModuleNotFound
	})
}

func (m *InterceptModuleManager) Reorder(ctx context.Context, revision string, executionOrder []string) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(revision) {
		return interceptModulesView{}, errors.New("a valid revision is required")
	}
	requested := append([]string(nil), executionOrder...)
	return m.mutate(ctx, revision, func(document *interceptConfigDocument) (interceptMutationEffects, error) {
		if err := validateInterceptExecutionOrder(document.Modules, requested); err != nil {
			return interceptMutationEffects{}, err
		}
		effects := interceptMutationEffects{}
		changed := !stringSlicesEqual(document.ExecutionOrder, requested)
		if changed {
			// Reordering an inactive document does not require a mihomo apply, but
			// it must preserve the existing contract that every stored binding
			// names a currently available group.
			for _, module := range document.Modules {
				if module.EgressGroup != "" {
					effects.validateEgressBindings = true
					break
				}
			}
			if document.MITM.Enabled {
				oldActive := enabledInterceptExecutionOrder(document.Modules, document.ExecutionOrder)
				nextActive := enabledInterceptExecutionOrder(document.Modules, requested)
				effects.routingChanged = !stringSlicesEqual(oldActive, nextActive)
			}
		}
		document.ExecutionOrder = requested
		return effects, nil
	})
}

func enabledInterceptExecutionOrder(modules []interceptModuleSnapshot, order []string) []string {
	enabled := make(map[string]struct{}, len(modules))
	for _, module := range modules {
		if module.Enabled {
			enabled[module.ID] = struct{}{}
		}
	}
	result := make([]string, 0, len(enabled))
	for _, id := range order {
		if _, exists := enabled[id]; exists {
			result = append(result, id)
		}
	}
	return result
}

func updateInterceptModuleSettings(module *interceptModuleSnapshot, values map[string]json.RawMessage) error {
	if len(values) != len(module.Settings) {
		return errors.New("submit exactly one value for every extension setting")
	}
	for index := range module.Settings {
		value, ok := values[module.Settings[index].Key]
		if !ok {
			return fmt.Errorf("missing extension setting %q", module.Settings[index].Key)
		}
		module.Settings[index].Value = append(json.RawMessage(nil), value...)
	}
	return validateInterceptModuleSettings(module.Settings, module.Enabled)
}

func (m *InterceptModuleManager) UpdateSettings(ctx context.Context, revision string, settings interceptMITMSettings) (interceptModulesView, error) {
	return m.mutate(ctx, revision, func(document *interceptConfigDocument) (interceptMutationEffects, error) {
		hadActiveHosts := len(activeInterceptHosts(*document)) > 0
		document.MITM = settings
		return interceptMutationEffects{routingChanged: hadActiveHosts != (len(activeInterceptHosts(*document)) > 0)}, nil
	})
}

func (m *InterceptModuleManager) mutate(
	ctx context.Context,
	revision string,
	mutator func(*interceptConfigDocument) (interceptMutationEffects, error),
) (interceptModulesView, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	defer m.store.mu.Unlock()
	oldDocument, oldBody, err := m.store.Read()
	if err != nil {
		return interceptModulesView{}, err
	}
	if interceptRevision(oldBody) != revision {
		return interceptModulesView{}, errInterceptRevisionConflict
	}
	nextDocument := oldDocument
	nextDocument.ExecutionOrder = append([]string{}, oldDocument.ExecutionOrder...)
	nextDocument.Modules = append([]interceptModuleSnapshot(nil), oldDocument.Modules...)
	for index := range nextDocument.Modules {
		nextDocument.Modules[index].RoutingRules = cloneInterceptRoutingRules(oldDocument.Modules[index].RoutingRules)
		nextDocument.Modules[index].Settings = cloneInterceptSettings(oldDocument.Modules[index].Settings)
		nextDocument.Modules[index].HostMappings = append([]interceptHostMapping(nil), oldDocument.Modules[index].HostMappings...)
	}
	effects, err := mutator(&nextDocument)
	if err != nil {
		return interceptModulesView{}, err
	}
	newBody, err := marshalInterceptDocument(nextDocument)
	if err != nil {
		return interceptModulesView{}, err
	}
	if effects.validateEgressBindings && !effects.routingChanged {
		if err := m.validateEgressBindingsOnly(nextDocument); err != nil {
			return interceptModulesView{}, err
		}
	}
	if bytesEqual(oldBody, newBody) && !effects.routingChanged {
		m.store.mu.Unlock()
		view, viewErr := m.viewLocked()
		m.store.mu.Lock()
		return view, viewErr
	}
	if err := m.validateSidecarCandidate(ctx, newBody); err != nil {
		return interceptModulesView{}, err
	}
	// A change that leaves routing alone -- a settings edit, say -- still has to
	// reach the processor, and it also has to reach the generation.
	//
	// Writing the document and returning was right when the file was the whole
	// contract. The overlay adds a second copy: each generation names the bundle
	// it was compiled against, and mihomo refuses to treat the processor as
	// ready while it serves a different one -- correctly, because the traffic it
	// is about to steer would then meet a policy other than the one in the
	// generation. So a settings-only change that stopped here would leave the
	// sidecar on a new bundle, the live generation naming the old one, and every
	// captured connection rejecting until some unrelated routing change happened
	// to resynchronise them.
	//
	// Every change therefore takes the full path below, which publishes the
	// bundle and commits a generation naming it. The mihomo file is still not
	// rewritten for it: that is gated on routingChanged separately, further
	// down, and stays gated.
	if m.mihomo == nil || m.controller == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	m.mihomo.Lock()
	defer m.mihomo.Unlock()
	oldMihomo, err := m.mihomo.Read()
	if err != nil {
		return interceptModulesView{}, err
	}
	if !interceptCredentialsMatch(oldMihomo, oldDocument) {
		return interceptModulesView{}, fmt.Errorf("%w: mihomo and sidecar credentials differ", errInterceptModuleConflict)
	}
	// Under the overlay the mihomo file carries two anchors and no interception
	// rules at all; the rules live in a typed generation committed over a
	// machine-only socket. Reconciling the file against the document would
	// report "out of sync" for the entirely correct state of an empty file and
	// a populated overlay, so the anchored config gets its own analysis.
	analysis := m.analyzeInterceptRouting(oldMihomo)
	if !analysis.Reconcileable {
		return interceptModulesView{}, fmt.Errorf("%w: %s", errInterceptModuleConflict, analysis.Reason)
	}
	if err := validateInterceptEgressBindings(nextDocument, analysis.AvailableEgressGroups); err != nil {
		return interceptModulesView{}, fmt.Errorf("%w: %v", errInterceptModuleConflict, err)
	}
	if err := m.publishSidecarDocument(ctx, newBody); err != nil {
		return interceptModulesView{}, err
	}
	oldCertificateHosts := certificateInterceptHosts(oldDocument)
	nextCertificateHosts := certificateInterceptHosts(nextDocument)
	firstActivation := len(activeInterceptHosts(oldDocument)) == 0 && len(activeInterceptHosts(nextDocument)) > 0
	certificateHostsChanged := !stringSlicesEqual(oldCertificateHosts, nextCertificateHosts)
	if len(nextCertificateHosts) > 0 && (certificateHostsChanged || (firstActivation && !m.certificateReady(nextDocument))) {
		if err := m.waitForCertificate(ctx, interceptCertificateDigest(nextCertificateHosts), newBody); err != nil {
			rollbackErr := m.rollbackSidecarDocument(ctx, oldBody)
			return interceptModulesView{}, fmt.Errorf("%w: certificate publication: %v; sidecar rollback: %v", errInterceptApplyFailed, err, rollbackErr)
		}
	}
	// The mihomo file is not rewritten and mihomo is not reloaded. What changes
	// is a typed generation, committed transactionally; the operator's own rules
	// are never re-serialised, so a change to routing can no longer perturb them.
	if err := m.publishOverlayGeneration(ctx, nextDocument, analysis.MatchTarget,
		interceptRevision(newBody), interceptCertificateDigest(nextCertificateHosts),
		interceptBundleID(newBody)); err != nil {
		rollbackErr := m.rollbackSidecarDocument(ctx, oldBody)
		return interceptModulesView{}, fmt.Errorf("%w: %v; sidecar rollback: %v", errInterceptApplyFailed, err, rollbackErr)
	}
	m.publishHosts(&nextDocument)
	if m.onApplied != nil {
		m.onApplied()
	}
	certificateReady := len(activeInterceptHosts(nextDocument)) == 0 || m.certificateReady(nextDocument)
	reason := ""
	if !certificateReady {
		reason = "certificate-not-ready"
	}
	return modulesViewFromDocument(nextDocument, newBody, certificateReady, reason, analysis.AvailableEgressGroups), nil
}

func (m *InterceptModuleManager) validateEgressBindingsOnly(document interceptConfigDocument) error {
	if m.mihomo == nil {
		return errInterceptModulesUnavailable
	}
	m.mihomo.Lock()
	defer m.mihomo.Unlock()
	text, err := m.mihomo.Read()
	if err != nil {
		return err
	}
	available, err := interceptAvailableEgressGroups(text)
	if err != nil {
		return fmt.Errorf("%w: %v", errInterceptModuleConflict, err)
	}
	if err := validateInterceptEgressBindings(document, available); err != nil {
		return fmt.Errorf("%w: %v", errInterceptModuleConflict, err)
	}
	return nil
}

func (m *InterceptModuleManager) certificateReady(document interceptConfigDocument) bool {
	if m.certStatePath == "" {
		return true
	}
	body, err := os.ReadFile(m.certStatePath)
	return err == nil && strings.TrimSpace(string(body)) == interceptCertificateDigest(certificateInterceptHosts(document))
}

func (m *InterceptModuleManager) validateSidecarCandidate(ctx context.Context, body []byte) error {
	if m.sidecarTest == nil {
		return nil
	}
	dir := filepath.Dir(m.store.Path)
	temp, err := os.CreateTemp(dir, ".intercept-test-*.json")
	if err != nil {
		return err
	}
	path := temp.Name()
	defer os.Remove(path)
	if _, err := temp.Write(body); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	testCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return m.sidecarTest.Test(testCtx, path)
}

func (m *InterceptModuleManager) waitForCertificate(ctx context.Context, digest string, candidate []byte) error {
	if m.certWait != nil {
		return m.certWait(ctx, digest)
	}
	if m.certStatePath == "" {
		return nil
	}
	deadline := time.NewTimer(interceptCertificateWaitLimit)
	defer deadline.Stop()
	poll := time.NewTicker(interceptCertificatePollInterval)
	defer poll.Stop()
	retrigger := time.NewTicker(interceptCertificateRetriggerInterval)
	defer retrigger.Stop()
	for {
		body, err := os.ReadFile(m.certStatePath)
		if err == nil && strings.TrimSpace(string(body)) == digest {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errors.New("timed out waiting for the root-owned certificate publisher")
		case <-poll.C:
		case <-retrigger.C:
			if err := m.republishCertificateCandidate(ctx, candidate); err != nil {
				return fmt.Errorf("retrigger root-owned certificate publisher: %w", err)
			}
		}
	}
}

func (m *InterceptModuleManager) republishCertificateCandidate(ctx context.Context, candidate []byte) error {
	current, err := os.ReadFile(m.store.Path)
	if err != nil {
		return fmt.Errorf("read certificate candidate: %w", err)
	}
	if !bytesEqual(current, candidate) {
		return errors.New("certificate candidate changed during publication")
	}
	if m.certRepublish != nil {
		if err := m.certRepublish(ctx, m.store.Path, candidate); err != nil {
			return err
		}
		m.store.invalidateHealthCache()
		return nil
	}
	return m.store.writeAtomicContext(ctx, candidate)
}

func (m *InterceptModuleManager) publishHosts(document *interceptConfigDocument) {
	if m.handler != nil {
		m.handler.setInterceptDocument(document)
	}
}

func marshalInterceptDocument(document interceptConfigDocument) ([]byte, error) {
	if err := validateInterceptDocument(document); err != nil {
		return nil, err
	}
	body, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return nil, err
	}
	if len(body)+1 > maxInterceptConfigBytes {
		return nil, fmt.Errorf("interception config exceeds %d bytes", maxInterceptConfigBytes)
	}
	return append(body, '\n'), nil
}

func modulesViewFromDocument(document interceptConfigDocument, body []byte, ready bool, reason string, availableGroups []string) interceptModulesView {
	if !document.MITM.Enabled {
		ready = false
		reason = "mitm-disabled"
	}
	view := interceptModulesView{
		Revision:              interceptRevision(body),
		CatalogURL:            nativeExtensionCatalogURL,
		ExecutionOrder:        append([]string{}, document.ExecutionOrder...),
		AvailableEgressGroups: append([]string(nil), availableGroups...),
		Modules:               make([]interceptModuleView, 0, len(document.Modules)),
		ActiveCaptureHosts:    []string{},
	}
	if ready {
		view.ActiveCaptureHosts = append([]string{}, activeInterceptHosts(document)...)
	}
	orderByID := interceptExecutionOrderIndex(document.ExecutionOrder)
	availableSet := make(map[string]struct{}, len(availableGroups))
	for _, group := range availableGroups {
		availableSet[group] = struct{}{}
	}
	for _, module := range orderedInterceptModules(document) {
		settingsReady := interceptModuleSettingsReady(module.Settings)
		moduleReady := ready && settingsReady
		moduleReason := reason
		if !settingsReady {
			moduleReason = "settings-required"
		}
		if module.EgressGroupRequired && module.EgressGroup == "" {
			moduleReady = false
			moduleReason = "egress-group-required"
		} else if module.EgressGroup != "" {
			if _, exists := availableSet[module.EgressGroup]; !exists {
				moduleReady = false
				moduleReason = "egress-group-missing"
			}
		}
		moduleView := interceptModuleViewFromSnapshot(module, moduleReady, moduleReason)
		moduleView.ExecutionOrder = orderByID[module.ID]
		view.Modules = append(view.Modules, moduleView)
	}
	return view
}

func interceptCandidateView(module interceptModuleSnapshot) interceptModuleView {
	ready := interceptModuleSettingsReady(module.Settings)
	reason := ""
	if !ready {
		reason = "settings-required"
	} else if module.EgressGroupRequired && module.EgressGroup == "" {
		ready = false
		reason = "egress-group-required"
	}
	return interceptModuleViewFromSnapshot(module, ready, reason)
}

func interceptModuleViewFromSnapshot(module interceptModuleSnapshot, ready bool, reason string) interceptModuleView {
	return interceptModuleView{
		ID: module.ID, Version: module.Version, Name: module.Name, Description: module.Description,
		Enabled: module.Enabled, Ready: ready, Reason: moduleRuntimeReason(ready, reason),
		CaptureHosts: append([]string(nil), module.CaptureHosts...), CaptureDNS: module.CaptureDNS, ScriptCount: len(module.Scripts),
		Actions:  interceptModuleActionViews(module.Scripts),
		Settings: cloneInterceptSettings(module.Settings), HostMappings: append([]interceptHostMapping(nil), module.HostMappings...),
		RoutingRules:      cloneInterceptRoutingRules(module.RoutingRules),
		PersistentStorage: module.PersistentStorage, Network: module.Network,
		EgressGroupRequired: module.EgressGroupRequired, EgressGroup: module.EgressGroup, SourceURL: module.Source.URL,
		SourceDigest: module.Source.Digest, SnapshotDigest: interceptModuleSnapshotDigest(module), ImportedAt: module.ImportedAt,
	}
}

func cloneInterceptRoutingRules(rules []interceptRoutingRule) []interceptRoutingRule {
	cloned := append([]interceptRoutingRule(nil), rules...)
	for index := range cloned {
		cloned[index].DomainKeywords = append([]string(nil), rules[index].DomainKeywords...)
		cloned[index].AllDomainKeywords = append([]string(nil), rules[index].AllDomainKeywords...)
	}
	return cloned
}

func interceptModuleActionViews(actions []interceptScriptRule) []interceptModuleActionView {
	views := make([]interceptModuleActionView, 0, len(actions))
	for _, action := range actions {
		match := action.Match
		match.Hosts = append([]string{}, action.Match.Hosts...)
		match.Schemes = append([]string{}, action.Match.Schemes...)
		match.Methods = append([]string{}, action.Match.Methods...)
		match.StatusCodes = append([]int{}, action.Match.StatusCodes...)
		views = append(views, interceptModuleActionView{
			ID: action.ID, Phase: action.Phase, Match: match,
			EnabledWhen: action.EnabledWhen,
			ScriptURL:   action.ScriptURL, ScriptDigest: action.ScriptDigest,
			BodyMode: action.BodyMode, Entry: action.Entry, JQProgram: action.JQProgram,
			TimeoutMS: action.TimeoutMS, MaxBodyBytes: action.MaxBodyBytes,
		})
	}
	return views
}

func cloneInterceptSettings(settings []interceptModuleSetting) []interceptModuleSetting {
	cloned := append([]interceptModuleSetting(nil), settings...)
	for index := range cloned {
		cloned[index].Options = append([]string(nil), settings[index].Options...)
		cloned[index].Default = append(json.RawMessage(nil), settings[index].Default...)
		cloned[index].Value = append(json.RawMessage(nil), settings[index].Value...)
	}
	return cloned
}

func mergeInterceptSettingValues(current, candidate []interceptModuleSetting) []interceptModuleSetting {
	values := make(map[string]interceptModuleSetting, len(current))
	for _, setting := range current {
		values[setting.Key] = setting
	}
	merged := cloneInterceptSettings(candidate)
	for index := range merged {
		previous, ok := values[merged[index].Key]
		if !ok || previous.Type != merged[index].Type {
			continue
		}
		if validateInterceptSettingValue(merged[index], previous.Value, false) == nil {
			merged[index].Value = append(json.RawMessage(nil), previous.Value...)
		}
	}
	return merged
}

func bytesEqual(left, right []byte) bool {
	return string(left) == string(right)
}
