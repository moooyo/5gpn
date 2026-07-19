package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
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
	sidecarTest   interceptConfigTester
	onApplied     func()
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
		parser:     interceptModuleParser{resolver: resolver},
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
	document, _, err := m.store.Read()
	m.store.mu.Unlock()
	if err != nil {
		return err
	}
	if !document.MITM.Enabled {
		m.publishHosts(nil)
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
	analysis := analyzeInterceptRouting(text, interceptMihomoRules(document))
	if !analysis.Manageable || !interceptCredentialsMatch(text, document) {
		m.publishHosts(nil)
		return fmt.Errorf("interception routing is not ready: %s", firstNonEmpty(analysis.Reason, "credential-mismatch"))
	}
	if len(activeInterceptHosts(document)) > 0 && !m.certificateReady(document) {
		m.publishHosts(nil)
		return errors.New("interception certificate state is not ready")
	}
	m.publishHosts(activeInterceptHosts(document))
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
		m.publishHosts(nil)
		return nil
	}
	analysis := analyzeInterceptRouting(text, interceptMihomoRules(document))
	if !analysis.Manageable || !interceptCredentialsMatch(text, document) {
		m.publishHosts(nil)
		return fmt.Errorf("interception routing is not ready: %s", firstNonEmpty(analysis.Reason, "credential-mismatch"))
	}
	if len(activeInterceptHosts(document)) > 0 && !m.certificateReady(document) {
		m.publishHosts(nil)
		return errors.New("interception certificate state is not ready")
	}
	m.publishHosts(activeInterceptHosts(document))
	return nil
}

func (m *InterceptModuleManager) View() (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.viewLocked()
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
	ready, reason := m.routingReadyLocked(document)
	view := interceptModulesView{
		Revision:           interceptRevision(body),
		CatalogURL:         nativeExtensionCatalogURL,
		ActiveCaptureHosts: activeInterceptHosts(document),
		Modules:            make([]interceptModuleView, 0, len(document.Modules)),
	}
	for _, module := range document.Modules {
		settingsReady := interceptModuleSettingsReady(module.Settings)
		moduleReady := ready && settingsReady
		moduleReason := reason
		if !settingsReady {
			moduleReason = "settings-required"
		}
		view.Modules = append(view.Modules, interceptModuleView{
			ID: module.ID, Version: module.Version, Name: module.Name, Description: module.Description,
			Enabled: module.Enabled, Ready: moduleReady, Reason: moduleRuntimeReason(moduleReady, moduleReason),
			CaptureHosts: append([]string(nil), module.CaptureHosts...), ScriptCount: len(module.Scripts),
			Settings: cloneInterceptSettings(module.Settings), HostMappings: append([]interceptHostMapping(nil), module.HostMappings...),
			PersistentStorage: module.PersistentStorage, SourceURL: module.Source.URL,
			SourceDigest: module.Source.Digest, SnapshotDigest: interceptModuleSnapshotDigest(module), ImportedAt: module.ImportedAt,
		})
	}
	return view, nil
}

func moduleRuntimeReason(ready bool, reason string) string {
	if !ready {
		return reason
	}
	return ""
}

func (m *InterceptModuleManager) routingReadyLocked(document interceptConfigDocument) (bool, string) {
	if !document.MITM.Enabled {
		return false, "mitm-disabled"
	}
	if m.mihomo == nil || m.controller == nil {
		return false, "mihomo-management-unavailable"
	}
	m.mihomo.Lock()
	text, err := m.mihomo.Read()
	m.mihomo.Unlock()
	if err != nil {
		return false, "mihomo-config-unreadable"
	}
	analysis := analyzeInterceptRouting(text, interceptMihomoRules(document))
	if !analysis.Manageable {
		return false, analysis.Reason
	}
	if !interceptCredentialsMatch(text, document) {
		return false, "credential-mismatch"
	}
	if len(activeInterceptHosts(document)) > 0 && !m.certificateReady(document) {
		return false, "certificate-not-ready"
	}
	return true, ""
}

func (m *InterceptModuleManager) Import(ctx context.Context, request interceptModuleImportRequest) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(request.Revision) {
		return interceptModulesView{}, errors.New("a valid revision is required")
	}
	module, err := m.parser.Import(ctx, request)
	if err != nil {
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
	if interceptRevision(oldBody) != request.Revision {
		return interceptModulesView{}, errInterceptRevisionConflict
	}
	for _, existing := range document.Modules {
		if existing.ID == module.ID {
			return interceptModulesView{}, fmt.Errorf("%w: extension id %q is already installed", errInterceptModuleConflict, module.ID)
		}
	}
	document.Modules = append(document.Modules, module)
	newBody, err := marshalInterceptDocument(document)
	if err != nil {
		return interceptModulesView{}, err
	}
	if err := m.validateSidecarCandidate(ctx, newBody); err != nil {
		return interceptModulesView{}, err
	}
	if err := writeInterceptConfigAtomic(m.store.Path, newBody); err != nil {
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
	if interceptModuleSnapshotDigest(candidate) == interceptModuleSnapshotDigest(current) {
		m.store.mu.Unlock()
		return interceptModuleUpdateCheckView{Revision: revision, State: "unchanged"}, nil
	}
	candidate.Settings = mergeInterceptSettingValues(current.Settings, candidate.Settings)
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
	latest.Modules[index] = candidate
	newBody, err := marshalInterceptDocument(latest)
	if err == nil {
		err = m.validateSidecarCandidate(ctx, newBody)
	}
	if err == nil {
		err = writeInterceptConfigAtomic(m.store.Path, newBody)
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

func (m *InterceptModuleManager) Delete(id, revision string) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
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
	newBody, err := marshalInterceptDocument(document)
	if err == nil {
		err = m.validateSidecarCandidate(context.Background(), newBody)
	}
	if err == nil {
		err = writeInterceptConfigAtomic(m.store.Path, newBody)
	}
	m.store.mu.Unlock()
	if err != nil {
		return interceptModulesView{}, err
	}
	return m.viewLocked()
}

type interceptModuleUpdate struct {
	Revision string                     `json:"revision"`
	Enabled  *bool                      `json:"enabled,omitempty"`
	Settings map[string]json.RawMessage `json:"settings,omitempty"`
}

func (m *InterceptModuleManager) Update(ctx context.Context, id string, update interceptModuleUpdate) (interceptModulesView, error) {
	if m == nil || m.store == nil {
		return interceptModulesView{}, errInterceptModulesUnavailable
	}
	if !validMihomoConfigRevision(update.Revision) || (update.Enabled == nil && update.Settings == nil) {
		return interceptModulesView{}, errors.New("revision and at least one update field are required")
	}
	return m.mutate(ctx, update.Revision, func(document *interceptConfigDocument) (bool, error) {
		for index := range document.Modules {
			module := &document.Modules[index]
			if module.ID != id {
				continue
			}
			routingChanged := false
			if update.Enabled != nil {
				if *update.Enabled && !interceptModuleSettingsReady(module.Settings) {
					return false, errors.New("configure every required extension setting before enable")
				}
				routingChanged = document.MITM.Enabled && module.Enabled != *update.Enabled
				module.Enabled = *update.Enabled
			}
			if update.Settings != nil {
				if err := updateInterceptModuleSettings(module, update.Settings); err != nil {
					return false, err
				}
			}
			return routingChanged, nil
		}
		return false, errInterceptModuleNotFound
	})
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
	return m.mutate(ctx, revision, func(document *interceptConfigDocument) (bool, error) {
		hadActiveHosts := len(activeInterceptHosts(*document)) > 0
		document.MITM = settings
		return hadActiveHosts != (len(activeInterceptHosts(*document)) > 0), nil
	})
}

func (m *InterceptModuleManager) mutate(
	ctx context.Context,
	revision string,
	mutator func(*interceptConfigDocument) (bool, error),
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
	nextDocument.Modules = append([]interceptModuleSnapshot(nil), oldDocument.Modules...)
	for index := range nextDocument.Modules {
		nextDocument.Modules[index].Settings = cloneInterceptSettings(oldDocument.Modules[index].Settings)
		nextDocument.Modules[index].HostMappings = append([]interceptHostMapping(nil), oldDocument.Modules[index].HostMappings...)
	}
	routingChanged, err := mutator(&nextDocument)
	if err != nil {
		return interceptModulesView{}, err
	}
	newBody, err := marshalInterceptDocument(nextDocument)
	if err != nil {
		return interceptModulesView{}, err
	}
	if err := m.validateSidecarCandidate(ctx, newBody); err != nil {
		return interceptModulesView{}, err
	}
	if bytesEqual(oldBody, newBody) {
		m.store.mu.Unlock()
		view, viewErr := m.viewLocked()
		m.store.mu.Lock()
		return view, viewErr
	}
	if !routingChanged {
		if err := writeInterceptConfigAtomic(m.store.Path, newBody); err != nil {
			return interceptModulesView{}, err
		}
		m.store.mu.Unlock()
		view, viewErr := m.viewLocked()
		m.store.mu.Lock()
		return view, viewErr
	}
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
	oldRules := interceptMihomoRules(oldDocument)
	nextRules := interceptMihomoRules(nextDocument)
	analysis := analyzeInterceptRouting(oldMihomo, oldRules)
	if !analysis.Reconcileable || !interceptRuleSubset(analysis.Current, append(append([]string(nil), oldRules...), nextRules...)) {
		return interceptModulesView{}, fmt.Errorf("%w: %s", errInterceptModuleConflict, analysis.Reason)
	}
	nextMihomo, err := renderInterceptRouting(analysis, nextRules)
	if err != nil {
		return interceptModulesView{}, err
	}
	verification := analyzeInterceptRouting(nextMihomo, nextRules)
	if !verification.Manageable {
		return interceptModulesView{}, errors.New("rendered interception routing failed structural verification")
	}
	if err := m.validateMihomoCandidateLocked(ctx, nextMihomo); err != nil {
		return interceptModulesView{}, err
	}
	if err := writeInterceptConfigAtomic(m.store.Path, newBody); err != nil {
		return interceptModulesView{}, err
	}
	oldCertificateHosts := certificateInterceptHosts(oldDocument)
	nextCertificateHosts := certificateInterceptHosts(nextDocument)
	firstActivation := len(activeInterceptHosts(oldDocument)) == 0 && len(activeInterceptHosts(nextDocument)) > 0
	if containsNewStrings(oldCertificateHosts, nextCertificateHosts) || (firstActivation && !m.certificateReady(nextDocument)) {
		if err := m.waitForCertificate(ctx, interceptCertificateDigest(nextCertificateHosts)); err != nil {
			rollbackErr := writeInterceptConfigAtomic(m.store.Path, oldBody)
			return interceptModulesView{}, fmt.Errorf("%w: certificate publication: %v; sidecar rollback: %v", errInterceptApplyFailed, err, rollbackErr)
		}
	}
	if err := m.publishMihomoLocked(ctx, oldMihomo, nextMihomo); err != nil {
		rollbackErr := writeInterceptConfigAtomic(m.store.Path, oldBody)
		return interceptModulesView{}, fmt.Errorf("%w: %v; sidecar rollback: %v", errInterceptApplyFailed, err, rollbackErr)
	}
	m.publishHosts(activeInterceptHosts(nextDocument))
	if m.onApplied != nil {
		m.onApplied()
	}
	certificateReady := m.certificateReady(nextDocument) || !containsNewStrings(oldCertificateHosts, nextCertificateHosts)
	reason := ""
	if !certificateReady {
		reason = "certificate-not-ready"
	}
	return modulesViewFromDocument(nextDocument, newBody, certificateReady, reason), nil
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

func (m *InterceptModuleManager) validateMihomoCandidateLocked(ctx context.Context, text string) error {
	if err := ValidateInvariants(text, m.infra); err != nil {
		return err
	}
	if err := m.mihomo.EnsurePrivateDir(); err != nil {
		return err
	}
	temp, err := os.CreateTemp(m.mihomo.Dir(), ".intercept-test-*.yaml")
	if err != nil {
		return err
	}
	path := temp.Name()
	defer os.Remove(path)
	if _, err := temp.WriteString(text); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if m.tester != nil {
		testCtx, cancel := context.WithTimeout(ctx, mihomoTestTimeout)
		defer cancel()
		if err := m.tester.Test(testCtx, path, m.mihomo.Dir()); err != nil {
			return err
		}
	}
	return nil
}

func (m *InterceptModuleManager) publishMihomoLocked(ctx context.Context, oldText, nextText string) error {
	if err := atomicWriteFile(m.mihomo.Path()+".bak", []byte(oldText), 0o660); err != nil {
		return fmt.Errorf("write mihomo backup: %w", err)
	}
	if err := atomicWriteFile(m.mihomo.Path(), []byte(nextText), 0o660); err != nil {
		return fmt.Errorf("write mihomo config: %w", err)
	}
	if err := m.controller.PutConfigs(ctx, m.mihomo.Path()); err == nil {
		return nil
	} else {
		applyErr := err
		rollbackDiskErr := atomicWriteFile(m.mihomo.Path(), []byte(oldText), 0o660)
		var rollbackApplyErr error
		if rollbackDiskErr == nil {
			rollbackCtx, cancel := context.WithTimeout(context.Background(), mihomoRollbackLimit)
			rollbackApplyErr = m.controller.PutConfigs(rollbackCtx, m.mihomo.Path())
			cancel()
		}
		return fmt.Errorf("mihomo hot-apply failed: %v; rollback disk=%v apply=%v", applyErr, rollbackDiskErr, rollbackApplyErr)
	}
}

func (m *InterceptModuleManager) waitForCertificate(ctx context.Context, digest string) error {
	if m.certWait != nil {
		return m.certWait(ctx, digest)
	}
	if m.certStatePath == "" {
		return nil
	}
	deadline := time.NewTimer(15 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
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
		case <-ticker.C:
		}
	}
}

func (m *InterceptModuleManager) publishHosts(hosts []string) {
	if m.handler != nil {
		m.handler.setInterceptHosts(hosts)
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

func modulesViewFromDocument(document interceptConfigDocument, body []byte, ready bool, reason string) interceptModulesView {
	if !document.MITM.Enabled {
		ready = false
		reason = "mitm-disabled"
	}
	view := interceptModulesView{
		Revision:           interceptRevision(body),
		CatalogURL:         nativeExtensionCatalogURL,
		ActiveCaptureHosts: activeInterceptHosts(document),
		Modules:            make([]interceptModuleView, 0, len(document.Modules)),
	}
	for _, module := range document.Modules {
		settingsReady := interceptModuleSettingsReady(module.Settings)
		moduleReady := ready && settingsReady
		moduleReason := reason
		if !settingsReady {
			moduleReason = "settings-required"
		}
		view.Modules = append(view.Modules, interceptModuleViewFromSnapshot(module, moduleReady, moduleReason))
	}
	return view
}

func interceptCandidateView(module interceptModuleSnapshot) interceptModuleView {
	ready := interceptModuleSettingsReady(module.Settings)
	reason := ""
	if !ready {
		reason = "settings-required"
	}
	return interceptModuleViewFromSnapshot(module, ready, reason)
}

func interceptModuleViewFromSnapshot(module interceptModuleSnapshot, ready bool, reason string) interceptModuleView {
	return interceptModuleView{
		ID: module.ID, Version: module.Version, Name: module.Name, Description: module.Description,
		Enabled: module.Enabled, Ready: ready, Reason: moduleRuntimeReason(ready, reason),
		CaptureHosts: append([]string(nil), module.CaptureHosts...), ScriptCount: len(module.Scripts),
		Settings: cloneInterceptSettings(module.Settings), HostMappings: append([]interceptHostMapping(nil), module.HostMappings...),
		PersistentStorage: module.PersistentStorage, SourceURL: module.Source.URL,
		SourceDigest: module.Source.Digest, SnapshotDigest: interceptModuleSnapshotDigest(module), ImportedAt: module.ImportedAt,
	}
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

func containsNewStrings(oldValues, nextValues []string) bool {
	old := make(map[string]struct{}, len(oldValues))
	for _, value := range oldValues {
		old[value] = struct{}{}
	}
	for _, value := range nextValues {
		if _, ok := old[value]; !ok {
			return true
		}
	}
	return false
}

func bytesEqual(left, right []byte) bool {
	return string(left) == string(right)
}

func sortedModuleIDs(modules []interceptModuleSnapshot) []string {
	ids := make([]string, 0, len(modules))
	for _, module := range modules {
		ids = append(ids, module.ID)
	}
	sort.Strings(ids)
	return ids
}

func interceptCertStatePath(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), "cert-state")
}
