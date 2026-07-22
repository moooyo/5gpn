package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	marketplaceDocumentVersion = 1
	marketplaceAPIVersion      = "5gpn.io/marketplace/v1"
	marketplaceKind            = "ExtensionMarketplace"

	recommendedMarketplaceURL = "https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json"

	maxMarketplaceSources     = 16
	maxMarketplaceEntries     = 512
	maxMarketplaceIndexBytes  = 2 << 20
	maxMarketplaceConfigBytes = 32 << 20
	maxMarketplaceTags        = 16
	maxMarketplaceTagBytes    = 64
	maxMarketplaceResources   = 256
	maxMarketplaceLicense     = 64
	maxMarketplaceDisplayName = 128
)

var (
	errMarketplaceUnavailable = errors.New("extension marketplace management unavailable")
	errMarketplaceRevision    = errors.New("extension marketplace revision changed")
	errMarketplaceConflict    = errors.New("extension marketplace conflicts with the current state")
	errMarketplaceNotFound    = errors.New("extension marketplace or entry not found")
	errMarketplaceFetch       = errors.New("extension marketplace fetch failed")
	errMarketplaceIntegrity   = errors.New("extension marketplace entry does not match the fetched extension")
	marketplaceTagPattern     = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)
	marketplaceSPDXPattern    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.+-]*$`)
)

type marketplaceDocument struct {
	Version int                         `json:"version"`
	Sources []marketplaceSourceSnapshot `json:"sources"`
}

type marketplaceIndex struct {
	APIVersion string              `json:"apiVersion"`
	Kind       string              `json:"kind"`
	Metadata   marketplaceMetadata `json:"metadata"`
	Entries    []marketplaceEntry  `json:"entries"`
}

type marketplaceMetadata struct {
	ID          string                    `json:"id"`
	Name        string                    `json:"name"`
	Description string                    `json:"description"`
	Homepage    string                    `json:"homepage"`
	Source      marketplaceMetadataSource `json:"source"`
}

type marketplaceMetadataSource struct {
	Repository string `json:"repository"`
	Revision   string `json:"revision"`
}

type marketplaceEntry struct {
	ID               string                  `json:"id"`
	Name             string                  `json:"name"`
	Version          string                  `json:"version"`
	Description      string                  `json:"description"`
	Tags             []string                `json:"tags"`
	License          marketplaceLicense      `json:"license"`
	DocumentationURL string                  `json:"documentationUrl"`
	Manifest         marketplaceResource     `json:"manifest"`
	Resources        []marketplaceResource   `json:"resources"`
	Capabilities     marketplaceCapabilities `json:"capabilities"`
}

type marketplaceLicense struct {
	SPDX string `json:"spdx"`
	URL  string `json:"url"`
}

type marketplaceResource struct {
	Path   string `json:"path,omitempty"`
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type marketplaceCapabilities struct {
	CaptureHostCount     int      `json:"captureHostCount"`
	ActionCount          int      `json:"actionCount"`
	SettingCount         int      `json:"settingCount"`
	NetworkOrigins       []string `json:"networkOrigins"`
	PersistentStorage    bool     `json:"persistentStorage"`
	UpstreamMappingCount int      `json:"upstreamMappingCount"`
	EgressGroupRequired  bool     `json:"egressGroupRequired"`
	RoutingRuleCount     *int     `json:"routingRuleCount"`
}

type marketplaceSourceSnapshot struct {
	ID          string              `json:"id"`
	DisplayName string              `json:"display_name,omitempty"`
	URL         string              `json:"url"`
	FinalURL    string              `json:"final_url"`
	IndexDigest string              `json:"index_digest"`
	FetchedAt   string              `json:"fetched_at"`
	Metadata    marketplaceMetadata `json:"metadata"`
	Entries     []marketplaceEntry  `json:"entries"`
}

type marketplaceView struct {
	RecommendedURL string                  `json:"recommended_url"`
	Revision       string                  `json:"revision"`
	Sources        []marketplaceSourceView `json:"sources"`
}

type marketplaceSourceView struct {
	ID             string                 `json:"id"`
	Name           string                 `json:"name"`
	DisplayName    string                 `json:"display_name,omitempty"`
	MetadataName   string                 `json:"metadata_name"`
	Description    string                 `json:"description"`
	Homepage       string                 `json:"homepage"`
	URL            string                 `json:"url"`
	FinalURL       string                 `json:"final_url"`
	Digest         string                 `json:"digest"`
	SnapshotDigest string                 `json:"snapshot_digest"`
	FetchedAt      string                 `json:"fetched_at"`
	Entries        []marketplaceEntryView `json:"entries"`
}

type marketplaceEntryView struct {
	ID               string                      `json:"id"`
	Name             string                      `json:"name"`
	Version          string                      `json:"version"`
	Description      string                      `json:"description"`
	Tags             []string                    `json:"tags"`
	License          marketplaceLicense          `json:"license"`
	DocumentationURL string                      `json:"documentation_url"`
	ManifestURL      string                      `json:"manifest_url"`
	ManifestDigest   string                      `json:"manifest_digest"`
	Capabilities     marketplaceCapabilitiesView `json:"capabilities"`
}

type marketplaceCapabilitiesView struct {
	CaptureHostCount     int      `json:"capture_host_count"`
	ActionCount          int      `json:"action_count"`
	SettingCount         int      `json:"setting_count"`
	NetworkOrigins       []string `json:"network_origins"`
	PersistentStorage    bool     `json:"persistent_storage"`
	UpstreamMappingCount int      `json:"upstream_mapping_count"`
	EgressGroupRequired  bool     `json:"egress_group_required"`
	RoutingRuleCount     int      `json:"routing_rule_count"`
}

type ExtensionMarketplaceStore struct {
	Path string
	mu   sync.Mutex
}

func NewExtensionMarketplaceStore(path string) *ExtensionMarketplaceStore {
	return &ExtensionMarketplaceStore{Path: path}
}

func emptyMarketplaceDocument() marketplaceDocument {
	return marketplaceDocument{Version: marketplaceDocumentVersion, Sources: []marketplaceSourceSnapshot{}}
}

func (s *ExtensionMarketplaceStore) Read() (marketplaceDocument, []byte, error) {
	if s == nil || strings.TrimSpace(s.Path) == "" {
		return marketplaceDocument{}, nil, errMarketplaceUnavailable
	}
	body, err := os.ReadFile(s.Path)
	if errors.Is(err, os.ErrNotExist) {
		empty := emptyMarketplaceDocument()
		body, marshalErr := marshalMarketplaceDocument(empty)
		return empty, body, marshalErr
	}
	if err != nil {
		return marketplaceDocument{}, nil, fmt.Errorf("read extension marketplaces: %w", err)
	}
	if len(body) > maxMarketplaceConfigBytes {
		return marketplaceDocument{}, nil, fmt.Errorf("extension marketplace config exceeds %d bytes", maxMarketplaceConfigBytes)
	}
	if !utf8.Valid(body) {
		return marketplaceDocument{}, nil, errors.New("extension marketplace config must be valid UTF-8")
	}
	var document marketplaceDocument
	if err := unmarshalStrictJSON(body, &document); err != nil {
		return marketplaceDocument{}, nil, fmt.Errorf("decode extension marketplaces: %w", err)
	}
	if err := validateMarketplaceDocument(document); err != nil {
		return marketplaceDocument{}, nil, err
	}
	return document, body, nil
}

func marshalMarketplaceDocument(document marketplaceDocument) ([]byte, error) {
	if document.Sources == nil {
		document.Sources = []marketplaceSourceSnapshot{}
	}
	if err := validateMarketplaceDocument(document); err != nil {
		return nil, err
	}
	body, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return nil, err
	}
	if len(body)+1 > maxMarketplaceConfigBytes {
		return nil, fmt.Errorf("extension marketplace config exceeds %d bytes", maxMarketplaceConfigBytes)
	}
	return append(body, '\n'), nil
}

func marketplaceRevision(body []byte) string { return sha256Hex(body) }

func marketplaceSourceSnapshotDigest(source marketplaceSourceSnapshot) string {
	canonical := source
	canonical.FetchedAt = ""
	body, err := json.Marshal(canonical)
	if err != nil {
		panic("marketplace snapshot digest contains an unsupported value: " + err.Error())
	}
	return sha256Hex(body)
}

type ExtensionMarketplaceManager struct {
	mu      sync.Mutex
	store   *ExtensionMarketplaceStore
	parser  interceptModuleParser
	modules *InterceptModuleManager
	now     func() time.Time
}

func NewExtensionMarketplaceManager(store *ExtensionMarketplaceStore, resolver HostResolver, modules *InterceptModuleManager) *ExtensionMarketplaceManager {
	return &ExtensionMarketplaceManager{
		store: store, parser: interceptModuleParser{resolver: resolver}, modules: modules, now: time.Now,
	}
}

func (m *ExtensionMarketplaceManager) View() (marketplaceView, error) {
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	defer m.store.mu.Unlock()
	document, body, err := m.store.Read()
	if err != nil {
		return marketplaceView{}, err
	}
	return marketplaceViewFromDocument(document, body), nil
}

func (m *ExtensionMarketplaceManager) Add(ctx context.Context, revision, rawURL, rawDisplayName string) (marketplaceView, error) {
	return m.addWithExpected(ctx, revision, rawURL, rawDisplayName, "")
}

// PreviewAdd fetches and normalizes a marketplace without changing the
// configured source document. The returned snapshot digest can be confirmed
// and passed to AddExpected.
func (m *ExtensionMarketplaceManager) PreviewAdd(ctx context.Context, rawURL, rawDisplayName string) (marketplaceSourceView, error) {
	if m == nil || m.store == nil {
		return marketplaceSourceView{}, errMarketplaceUnavailable
	}
	source, err := m.fetchAddCandidate(ctx, rawURL, rawDisplayName)
	if err != nil {
		return marketplaceSourceView{}, err
	}
	if err := m.validateAddCandidate(source); err != nil {
		return marketplaceSourceView{}, err
	}
	return marketplaceSourceViewFromSnapshot(source), nil
}

// AddExpected refetches the marketplace and verifies the exact normalized
// source snapshot selected during preview before the existing marketplace
// revision CAS writes it. Legacy callers use Add.
func (m *ExtensionMarketplaceManager) AddExpected(
	ctx context.Context,
	revision, rawURL, rawDisplayName, expectedSnapshotDigest string,
) (marketplaceView, error) {
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(expectedSnapshotDigest) {
		return marketplaceView{}, errors.New("a valid expected marketplace snapshot digest is required")
	}
	return m.addWithExpected(ctx, revision, rawURL, rawDisplayName, expectedSnapshotDigest)
}

func (m *ExtensionMarketplaceManager) addWithExpected(
	ctx context.Context,
	revision, rawURL, rawDisplayName, expectedSnapshotDigest string,
) (marketplaceView, error) {
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(revision) {
		return marketplaceView{}, errors.New("a valid marketplace revision is required")
	}
	if ctx == nil {
		return marketplaceView{}, errors.New("a marketplace operation context is required")
	}
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	if err := m.preflightRevision(ctx, revision); err != nil {
		return marketplaceView{}, err
	}
	source, err := m.fetchAddCandidate(ctx, rawURL, rawDisplayName)
	if err != nil {
		return marketplaceView{}, err
	}
	if expectedSnapshotDigest != "" && marketplaceSourceSnapshotDigest(source) != expectedSnapshotDigest {
		return marketplaceView{}, fmt.Errorf("%w: marketplace snapshot changed since preview", errMarketplaceRevision)
	}

	if err := lockMutexContext(ctx, &m.mu); err != nil {
		return marketplaceView{}, err
	}
	defer m.mu.Unlock()
	if err := lockMutexContext(ctx, &m.store.mu); err != nil {
		return marketplaceView{}, err
	}
	defer m.store.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	document, body, err := m.store.Read()
	if err != nil {
		return marketplaceView{}, err
	}
	if marketplaceRevision(body) != revision {
		return marketplaceView{}, errMarketplaceRevision
	}
	for _, existing := range document.Sources {
		if existing.ID == source.ID || existing.URL == source.URL || existing.URL == source.FinalURL || existing.FinalURL == source.URL || existing.FinalURL == source.FinalURL {
			return marketplaceView{}, fmt.Errorf("%w: marketplace id or URL is already configured", errMarketplaceConflict)
		}
	}
	document.Sources = append(document.Sources, source)
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	return m.writeLocked(ctx, document)
}

func (m *ExtensionMarketplaceManager) fetchAddCandidate(ctx context.Context, rawURL, rawDisplayName string) (marketplaceSourceSnapshot, error) {
	configuredURL, err := normalizeModuleImportURL(rawURL)
	if err != nil {
		return marketplaceSourceSnapshot{}, err
	}
	displayName, err := normalizeMarketplaceDisplayName(rawDisplayName)
	if err != nil {
		return marketplaceSourceSnapshot{}, err
	}
	source, err := m.fetch(ctx, configuredURL)
	if err != nil {
		return marketplaceSourceSnapshot{}, err
	}
	source.DisplayName = displayName
	return source, nil
}

func (m *ExtensionMarketplaceManager) validateAddCandidate(source marketplaceSourceSnapshot) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	defer m.store.mu.Unlock()
	document, _, err := m.store.Read()
	if err != nil {
		return err
	}
	for _, existing := range document.Sources {
		if existing.ID == source.ID || existing.URL == source.URL || existing.URL == source.FinalURL || existing.FinalURL == source.URL || existing.FinalURL == source.FinalURL {
			return fmt.Errorf("%w: marketplace id or URL is already configured", errMarketplaceConflict)
		}
	}
	document.Sources = append(document.Sources, source)
	_, err = marshalMarketplaceDocument(document)
	return err
}

func (m *ExtensionMarketplaceManager) Refresh(ctx context.Context, id, revision string) (marketplaceView, error) {
	return m.refreshWithExpected(ctx, id, revision, "")
}

// PreviewRefresh fetches and normalizes a replacement snapshot without
// changing the configured marketplace. The caller's revision must remain
// current for the preview to be returned.
func (m *ExtensionMarketplaceManager) PreviewRefresh(ctx context.Context, id, revision string) (marketplaceSourceView, error) {
	if m == nil || m.store == nil {
		return marketplaceSourceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(revision) {
		return marketplaceSourceView{}, errors.New("a valid marketplace revision is required")
	}
	current, refreshed, err := m.fetchRefreshCandidate(ctx, id, revision)
	if err != nil {
		return marketplaceSourceView{}, err
	}
	latest, err := m.sourceAtRevision(ctx, id, revision)
	if err != nil {
		return marketplaceSourceView{}, err
	}
	if latest.URL != current.URL || latest.IndexDigest != current.IndexDigest {
		return marketplaceSourceView{}, errMarketplaceRevision
	}
	return marketplaceSourceViewFromSnapshot(refreshed), nil
}

// RefreshExpected refetches a marketplace and verifies the previewed normalized
// source snapshot before the existing revision and source-identity checks
// commit it. Legacy callers use Refresh.
func (m *ExtensionMarketplaceManager) RefreshExpected(
	ctx context.Context,
	id, revision, expectedSnapshotDigest string,
) (marketplaceView, error) {
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(expectedSnapshotDigest) {
		return marketplaceView{}, errors.New("a valid expected marketplace snapshot digest is required")
	}
	return m.refreshWithExpected(ctx, id, revision, expectedSnapshotDigest)
}

func (m *ExtensionMarketplaceManager) refreshWithExpected(
	ctx context.Context,
	id, revision, expectedSnapshotDigest string,
) (marketplaceView, error) {
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(revision) {
		return marketplaceView{}, errors.New("a valid marketplace revision is required")
	}
	if ctx == nil {
		return marketplaceView{}, errors.New("a marketplace operation context is required")
	}
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	current, refreshed, err := m.fetchRefreshCandidate(ctx, id, revision)
	if err != nil {
		return marketplaceView{}, err
	}
	if expectedSnapshotDigest != "" && marketplaceSourceSnapshotDigest(refreshed) != expectedSnapshotDigest {
		return marketplaceView{}, fmt.Errorf("%w: marketplace snapshot changed since preview", errMarketplaceRevision)
	}

	if err := lockMutexContext(ctx, &m.mu); err != nil {
		return marketplaceView{}, err
	}
	defer m.mu.Unlock()
	if err := lockMutexContext(ctx, &m.store.mu); err != nil {
		return marketplaceView{}, err
	}
	defer m.store.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	document, body, err := m.store.Read()
	if err != nil {
		return marketplaceView{}, err
	}
	if marketplaceRevision(body) != revision {
		return marketplaceView{}, errMarketplaceRevision
	}
	index := marketplaceSourceIndex(document.Sources, id)
	if index < 0 || document.Sources[index].URL != current.URL || document.Sources[index].IndexDigest != current.IndexDigest {
		return marketplaceView{}, errMarketplaceRevision
	}
	for otherIndex, other := range document.Sources {
		if otherIndex != index && (other.URL == refreshed.FinalURL || other.FinalURL == refreshed.FinalURL) {
			return marketplaceView{}, fmt.Errorf("%w: refreshed marketplace final URL conflicts with another source", errMarketplaceConflict)
		}
	}
	document.Sources[index] = refreshed
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	return m.writeLocked(ctx, document)
}

func (m *ExtensionMarketplaceManager) fetchRefreshCandidate(
	ctx context.Context,
	id, revision string,
) (marketplaceSourceSnapshot, marketplaceSourceSnapshot, error) {
	current, err := m.sourceAtRevision(ctx, id, revision)
	if err != nil {
		return marketplaceSourceSnapshot{}, marketplaceSourceSnapshot{}, err
	}
	refreshed, err := m.fetch(ctx, current.URL)
	if err != nil {
		return marketplaceSourceSnapshot{}, marketplaceSourceSnapshot{}, err
	}
	if refreshed.ID != current.ID {
		return marketplaceSourceSnapshot{}, marketplaceSourceSnapshot{}, fmt.Errorf("%w: refreshed marketplace changed metadata.id", errMarketplaceConflict)
	}
	refreshed.DisplayName = current.DisplayName
	return current, refreshed, nil
}

func (m *ExtensionMarketplaceManager) Delete(ctx context.Context, id, revision string) (marketplaceView, error) {
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(revision) {
		return marketplaceView{}, errors.New("a valid marketplace revision is required")
	}
	if ctx == nil {
		return marketplaceView{}, errors.New("a marketplace operation context is required")
	}
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	if err := lockMutexContext(ctx, &m.mu); err != nil {
		return marketplaceView{}, err
	}
	defer m.mu.Unlock()
	if err := lockMutexContext(ctx, &m.store.mu); err != nil {
		return marketplaceView{}, err
	}
	defer m.store.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	document, body, err := m.store.Read()
	if err != nil {
		return marketplaceView{}, err
	}
	if marketplaceRevision(body) != revision {
		return marketplaceView{}, errMarketplaceRevision
	}
	index := marketplaceSourceIndex(document.Sources, id)
	if index < 0 {
		return marketplaceView{}, errMarketplaceNotFound
	}
	document.Sources = append(document.Sources[:index], document.Sources[index+1:]...)
	if err := ctx.Err(); err != nil {
		return marketplaceView{}, err
	}
	return m.writeLocked(ctx, document)
}

func (m *ExtensionMarketplaceManager) Install(ctx context.Context, marketplaceID, extensionID, marketplaceRev, moduleRev string) (interceptModulesView, error) {
	return m.installWithExpected(ctx, marketplaceID, extensionID, marketplaceRev, moduleRev, "", "")
}

// PreviewInstall fetches and verifies the selected marketplace entry without
// changing the installed module document. Both marketplace and module
// revisions must remain current while the candidate is prepared.
func (m *ExtensionMarketplaceManager) PreviewInstall(
	ctx context.Context,
	marketplaceID, extensionID, marketplaceRev, moduleRev string,
) (interceptModuleView, error) {
	if m == nil || m.store == nil || m.modules == nil {
		return interceptModuleView{}, errMarketplaceUnavailable
	}
	if !validSHA256(marketplaceRev) || !validSHA256(moduleRev) {
		return interceptModuleView{}, errors.New("valid marketplace_revision and module_revision are required")
	}
	source, module, err := m.fetchInstallCandidate(ctx, marketplaceID, extensionID, marketplaceRev)
	if err != nil {
		return interceptModuleView{}, err
	}
	candidate, err := m.modules.previewSnapshot(ctx, moduleRev, module)
	if err != nil {
		return interceptModuleView{}, err
	}
	latestSource, _, err := m.entryAtRevision(ctx, marketplaceID, extensionID, marketplaceRev)
	if err != nil {
		return interceptModuleView{}, err
	}
	if marketplaceSourceSnapshotDigest(latestSource) != marketplaceSourceSnapshotDigest(source) {
		return interceptModuleView{}, errMarketplaceRevision
	}
	return candidate, nil
}

// InstallExpected refetches and verifies the selected entry, then requires the
// confirmed normalized marketplace source and immutable extension snapshot
// digests before entering the existing module revision CAS.
func (m *ExtensionMarketplaceManager) InstallExpected(
	ctx context.Context,
	marketplaceID, extensionID, marketplaceRev, moduleRev string,
	expectedSourceSnapshotDigest, expectedCandidateSnapshotDigest string,
) (interceptModulesView, error) {
	if m == nil || m.store == nil || m.modules == nil {
		return interceptModulesView{}, errMarketplaceUnavailable
	}
	if !validSHA256(expectedSourceSnapshotDigest) || !validSHA256(expectedCandidateSnapshotDigest) {
		return interceptModulesView{}, errors.New("valid expected source and extension snapshot digests are required")
	}
	return m.installWithExpected(
		ctx,
		marketplaceID,
		extensionID,
		marketplaceRev,
		moduleRev,
		expectedSourceSnapshotDigest,
		expectedCandidateSnapshotDigest,
	)
}

func (m *ExtensionMarketplaceManager) installWithExpected(
	ctx context.Context,
	marketplaceID, extensionID, marketplaceRev, moduleRev string,
	expectedSourceSnapshotDigest, expectedCandidateSnapshotDigest string,
) (interceptModulesView, error) {
	if m == nil || m.store == nil || m.modules == nil {
		return interceptModulesView{}, errMarketplaceUnavailable
	}
	if !validSHA256(marketplaceRev) || !validSHA256(moduleRev) {
		return interceptModulesView{}, errors.New("valid marketplace_revision and module_revision are required")
	}
	if expectedSourceSnapshotDigest != "" {
		confirmedSource, err := m.sourceAtRevision(ctx, marketplaceID, marketplaceRev)
		if err != nil {
			return interceptModulesView{}, err
		}
		if marketplaceSourceSnapshotDigest(confirmedSource) != expectedSourceSnapshotDigest {
			return interceptModulesView{}, fmt.Errorf("%w: marketplace source changed since preview", errMarketplaceRevision)
		}
	}
	source, module, err := m.fetchInstallCandidate(ctx, marketplaceID, extensionID, marketplaceRev)
	if err != nil {
		return interceptModulesView{}, err
	}
	if expectedCandidateSnapshotDigest != "" && interceptModuleSnapshotDigest(module) != expectedCandidateSnapshotDigest {
		return interceptModulesView{}, fmt.Errorf("%w: extension snapshot changed since preview", errInterceptRevisionConflict)
	}

	if err := lockMutexContext(ctx, &m.mu); err != nil {
		return interceptModulesView{}, err
	}
	defer m.mu.Unlock()
	if err := lockMutexContext(ctx, &m.store.mu); err != nil {
		return interceptModulesView{}, err
	}
	defer m.store.mu.Unlock()
	document, body, err := m.store.Read()
	if err != nil {
		return interceptModulesView{}, err
	}
	if marketplaceRevision(body) != marketplaceRev {
		return interceptModulesView{}, errMarketplaceRevision
	}
	latestSourceIndex := marketplaceSourceIndex(document.Sources, marketplaceID)
	if latestSourceIndex < 0 ||
		marketplaceSourceSnapshotDigest(document.Sources[latestSourceIndex]) != marketplaceSourceSnapshotDigest(source) ||
		marketplaceEntryIndex(document.Sources[latestSourceIndex].Entries, extensionID) < 0 {
		return interceptModulesView{}, errMarketplaceRevision
	}
	// Keep the marketplace proof locked through the module CAS. Marketplace
	// operations never acquire the module store first, so this fixed
	// marketplace-to-module order prevents the reviewed source revision from
	// changing in the final commit window without introducing a lock cycle.
	return m.modules.importSnapshot(ctx, moduleRev, module)
}

func (m *ExtensionMarketplaceManager) fetchInstallCandidate(
	ctx context.Context,
	marketplaceID, extensionID, marketplaceRev string,
) (marketplaceSourceSnapshot, interceptModuleSnapshot, error) {
	source, entry, err := m.entryAtRevision(ctx, marketplaceID, extensionID, marketplaceRev)
	if err != nil {
		return marketplaceSourceSnapshot{}, interceptModuleSnapshot{}, err
	}
	module, err := m.modules.parser.Import(ctx, interceptModuleImportRequest{URL: entry.Manifest.URL})
	if err != nil {
		return marketplaceSourceSnapshot{}, interceptModuleSnapshot{}, err
	}
	if err := validateMarketplaceInstall(source, entry, module); err != nil {
		return marketplaceSourceSnapshot{}, interceptModuleSnapshot{}, fmt.Errorf("%w: %v", errMarketplaceIntegrity, err)
	}
	return source, module, nil
}

func (m *ExtensionMarketplaceManager) preflightRevision(ctx context.Context, revision string) error {
	if err := lockMutexContext(ctx, &m.store.mu); err != nil {
		return err
	}
	defer m.store.mu.Unlock()
	_, body, err := m.store.Read()
	if err != nil {
		return err
	}
	if marketplaceRevision(body) != revision {
		return errMarketplaceRevision
	}
	return nil
}

func (m *ExtensionMarketplaceManager) sourceAtRevision(ctx context.Context, id, revision string) (marketplaceSourceSnapshot, error) {
	if err := lockMutexContext(ctx, &m.store.mu); err != nil {
		return marketplaceSourceSnapshot{}, err
	}
	defer m.store.mu.Unlock()
	document, body, err := m.store.Read()
	if err != nil {
		return marketplaceSourceSnapshot{}, err
	}
	if marketplaceRevision(body) != revision {
		return marketplaceSourceSnapshot{}, errMarketplaceRevision
	}
	index := marketplaceSourceIndex(document.Sources, id)
	if index < 0 {
		return marketplaceSourceSnapshot{}, errMarketplaceNotFound
	}
	return document.Sources[index], nil
}

func (m *ExtensionMarketplaceManager) entryAtRevision(ctx context.Context, marketplaceID, extensionID, revision string) (marketplaceSourceSnapshot, marketplaceEntry, error) {
	source, err := m.sourceAtRevision(ctx, marketplaceID, revision)
	if err != nil {
		return marketplaceSourceSnapshot{}, marketplaceEntry{}, err
	}
	index := marketplaceEntryIndex(source.Entries, extensionID)
	if index < 0 {
		return marketplaceSourceSnapshot{}, marketplaceEntry{}, errMarketplaceNotFound
	}
	return source, source.Entries[index], nil
}

func (m *ExtensionMarketplaceManager) fetch(ctx context.Context, configuredURL string) (marketplaceSourceSnapshot, error) {
	body, finalURL, err := m.parser.fetchResource(ctx, configuredURL, maxMarketplaceIndexBytes)
	if err != nil {
		return marketplaceSourceSnapshot{}, fmt.Errorf("%w: %v", errMarketplaceFetch, err)
	}
	if !utf8.Valid(body) {
		return marketplaceSourceSnapshot{}, fmt.Errorf("%w: index must be valid UTF-8", errMarketplaceFetch)
	}
	var index marketplaceIndex
	if err := unmarshalStrictJSON(body, &index); err != nil {
		return marketplaceSourceSnapshot{}, fmt.Errorf("%w: decode index: %v", errMarketplaceFetch, err)
	}
	if err := normalizeAndValidateMarketplaceIndex(&index, finalURL); err != nil {
		return marketplaceSourceSnapshot{}, fmt.Errorf("%w: %v", errMarketplaceFetch, err)
	}
	now := time.Now
	if m.now != nil {
		now = m.now
	}
	return marketplaceSourceSnapshot{
		ID: index.Metadata.ID, URL: configuredURL, FinalURL: finalURL,
		IndexDigest: sha256Hex(body), FetchedAt: now().UTC().Format(time.RFC3339),
		Metadata: index.Metadata, Entries: index.Entries,
	}, nil
}

func (m *ExtensionMarketplaceManager) writeLocked(ctx context.Context, document marketplaceDocument) (marketplaceView, error) {
	body, err := marshalMarketplaceDocument(document)
	if err != nil {
		return marketplaceView{}, err
	}
	if err := atomicWriteFileContext(ctx, m.store.Path, body, 0o640); err != nil {
		return marketplaceView{}, err
	}
	return marketplaceViewFromDocument(document, body), nil
}

func marketplaceViewFromDocument(document marketplaceDocument, body []byte) marketplaceView {
	view := marketplaceView{
		RecommendedURL: recommendedMarketplaceURL,
		Revision:       marketplaceRevision(body),
		Sources:        make([]marketplaceSourceView, 0, len(document.Sources)),
	}
	for _, source := range document.Sources {
		view.Sources = append(view.Sources, marketplaceSourceViewFromSnapshot(source))
	}
	return view
}

func marketplaceSourceViewFromSnapshot(source marketplaceSourceSnapshot) marketplaceSourceView {
	name := source.Metadata.Name
	if source.DisplayName != "" {
		name = source.DisplayName
	}
	view := marketplaceSourceView{
		ID: source.ID, Name: name, DisplayName: source.DisplayName, MetadataName: source.Metadata.Name, Description: source.Metadata.Description,
		Homepage: source.Metadata.Homepage, URL: source.URL, FinalURL: source.FinalURL,
		Digest: source.IndexDigest, SnapshotDigest: marketplaceSourceSnapshotDigest(source), FetchedAt: source.FetchedAt,
		Entries: make([]marketplaceEntryView, 0, len(source.Entries)),
	}
	for _, entry := range source.Entries {
		capabilities := marketplaceCapabilitiesView{
			CaptureHostCount: entry.Capabilities.CaptureHostCount, ActionCount: entry.Capabilities.ActionCount,
			SettingCount: entry.Capabilities.SettingCount, NetworkOrigins: append([]string{}, entry.Capabilities.NetworkOrigins...),
			PersistentStorage: entry.Capabilities.PersistentStorage, UpstreamMappingCount: entry.Capabilities.UpstreamMappingCount,
			EgressGroupRequired: entry.Capabilities.EgressGroupRequired,
			RoutingRuleCount:    *entry.Capabilities.RoutingRuleCount,
		}
		view.Entries = append(view.Entries, marketplaceEntryView{
			ID: entry.ID, Name: entry.Name, Version: entry.Version, Description: entry.Description,
			Tags: append([]string(nil), entry.Tags...), License: entry.License,
			DocumentationURL: entry.DocumentationURL, ManifestURL: entry.Manifest.URL,
			ManifestDigest: entry.Manifest.SHA256, Capabilities: capabilities,
		})
	}
	return view
}

func marketplaceSourceIndex(sources []marketplaceSourceSnapshot, id string) int {
	for index := range sources {
		if sources[index].ID == id {
			return index
		}
	}
	return -1
}

func marketplaceEntryIndex(entries []marketplaceEntry, id string) int {
	for index := range entries {
		if entries[index].ID == id {
			return index
		}
	}
	return -1
}

func validateMarketplaceDocument(document marketplaceDocument) error {
	if document.Version != marketplaceDocumentVersion {
		return fmt.Errorf("extension marketplace config version must be %d", marketplaceDocumentVersion)
	}
	if document.Sources == nil {
		return errors.New("extension marketplace sources must be an array")
	}
	if len(document.Sources) > maxMarketplaceSources {
		return fmt.Errorf("at most %d extension marketplace sources are allowed", maxMarketplaceSources)
	}
	ids := make(map[string]struct{}, len(document.Sources))
	urls := make(map[string]struct{}, len(document.Sources)*2)
	for _, source := range document.Sources {
		if err := validateMarketplaceSourceSnapshot(source); err != nil {
			return fmt.Errorf("marketplace %q: %w", source.ID, err)
		}
		if _, duplicate := ids[source.ID]; duplicate {
			return fmt.Errorf("duplicate extension marketplace id %q", source.ID)
		}
		ids[source.ID] = struct{}{}
		sourceURLs := uniqueSortedStrings([]string{source.URL, source.FinalURL})
		for _, rawURL := range sourceURLs {
			if _, duplicate := urls[rawURL]; duplicate {
				return fmt.Errorf("duplicate extension marketplace URL %q", rawURL)
			}
			urls[rawURL] = struct{}{}
		}
	}
	return nil
}

func validateMarketplaceSourceSnapshot(source marketplaceSourceSnapshot) error {
	if source.ID != source.Metadata.ID || !validInterceptModuleID(source.ID) {
		return errors.New("source id must match a lowercase dotted metadata id")
	}
	if source.DisplayName != "" {
		if err := validateMarketplaceText("display_name", source.DisplayName, 1, maxMarketplaceDisplayName); err != nil {
			return err
		}
	}
	if err := validateRemoteModuleURL(source.URL); err != nil {
		return fmt.Errorf("invalid configured URL: %w", err)
	}
	if err := validateRemoteModuleURL(source.FinalURL); err != nil {
		return fmt.Errorf("invalid final URL: %w", err)
	}
	if !validSHA256(source.IndexDigest) {
		return errors.New("index_digest must be a lowercase SHA-256 digest")
	}
	if _, err := time.Parse(time.RFC3339, source.FetchedAt); err != nil {
		return errors.New("fetched_at must be RFC3339")
	}
	copyIndex := marketplaceIndex{APIVersion: marketplaceAPIVersion, Kind: marketplaceKind, Metadata: source.Metadata, Entries: source.Entries}
	return validateNormalizedMarketplaceIndex(copyIndex)
}

func normalizeMarketplaceDisplayName(raw string) (string, error) {
	name := strings.TrimSpace(raw)
	if name == "" {
		return "", nil
	}
	if err := validateMarketplaceText("marketplace name", name, 1, maxMarketplaceDisplayName); err != nil {
		return "", err
	}
	return name, nil
}

func normalizeAndValidateMarketplaceIndex(index *marketplaceIndex, baseURL string) error {
	if index.APIVersion != marketplaceAPIVersion {
		return fmt.Errorf("apiVersion must be %q", marketplaceAPIVersion)
	}
	if index.Kind != marketplaceKind {
		return fmt.Errorf("kind must be %q", marketplaceKind)
	}
	index.Metadata.ID = strings.TrimSpace(index.Metadata.ID)
	index.Metadata.Name = strings.TrimSpace(index.Metadata.Name)
	index.Metadata.Description = strings.TrimSpace(index.Metadata.Description)
	var err error
	if index.Metadata.Homepage, err = resolveMarketplaceURL(baseURL, index.Metadata.Homepage, false); err != nil {
		return fmt.Errorf("metadata.homepage: %w", err)
	}
	if index.Metadata.Source.Repository, err = resolveMarketplaceURL(baseURL, index.Metadata.Source.Repository, false); err != nil {
		return fmt.Errorf("metadata.source.repository: %w", err)
	}
	index.Metadata.Source.Revision = strings.TrimSpace(index.Metadata.Source.Revision)
	for entryIndex := range index.Entries {
		entry := &index.Entries[entryIndex]
		entry.ID = strings.TrimSpace(entry.ID)
		entry.Name = strings.TrimSpace(entry.Name)
		entry.Version = strings.TrimSpace(entry.Version)
		entry.Description = strings.TrimSpace(entry.Description)
		entry.License.SPDX = strings.TrimSpace(entry.License.SPDX)
		entry.Tags = normalizeMarketplaceTags(entry.Tags)
		entry.Capabilities.NetworkOrigins, err = normalizeInterceptNetworkOrigins(entry.Capabilities.NetworkOrigins)
		if err != nil {
			return fmt.Errorf("entries[%d].capabilities.networkOrigins: %w", entryIndex, err)
		}
		if entry.License.URL, err = resolveMarketplaceURL(baseURL, entry.License.URL, true); err != nil {
			return fmt.Errorf("entries[%d].license.url: %w", entryIndex, err)
		}
		if entry.DocumentationURL, err = resolveMarketplaceURL(baseURL, entry.DocumentationURL, true); err != nil {
			return fmt.Errorf("entries[%d].documentationUrl: %w", entryIndex, err)
		}
		if entry.Manifest.URL, err = resolveMarketplaceURL(baseURL, entry.Manifest.URL, false); err != nil {
			return fmt.Errorf("entries[%d].manifest.url: %w", entryIndex, err)
		}
		entry.Manifest.SHA256 = strings.ToLower(strings.TrimSpace(entry.Manifest.SHA256))
		for resourceIndex := range entry.Resources {
			resource := &entry.Resources[resourceIndex]
			resource.Path = strings.TrimSpace(resource.Path)
			resource.SHA256 = strings.ToLower(strings.TrimSpace(resource.SHA256))
			if resource.URL, err = resolveMarketplaceURL(baseURL, resource.URL, false); err != nil {
				return fmt.Errorf("entries[%d].resources[%d].url: %w", entryIndex, resourceIndex, err)
			}
		}
		sort.Slice(entry.Resources, func(i, j int) bool {
			if entry.Resources[i].Path == entry.Resources[j].Path {
				return entry.Resources[i].URL < entry.Resources[j].URL
			}
			return entry.Resources[i].Path < entry.Resources[j].Path
		})
	}
	sort.Slice(index.Entries, func(i, j int) bool { return index.Entries[i].ID < index.Entries[j].ID })
	return validateNormalizedMarketplaceIndex(*index)
}

func validateNormalizedMarketplaceIndex(index marketplaceIndex) error {
	if index.APIVersion != marketplaceAPIVersion || index.Kind != marketplaceKind {
		return errors.New("invalid marketplace apiVersion or kind")
	}
	if !validInterceptModuleID(index.Metadata.ID) {
		return errors.New("metadata.id must be a lowercase dotted identifier")
	}
	if err := validateMarketplaceText("metadata.name", index.Metadata.Name, 1, maxInterceptModuleName); err != nil {
		return err
	}
	if err := validateMarketplaceText("metadata.description", index.Metadata.Description, 0, maxInterceptModuleDesc); err != nil {
		return err
	}
	for field, rawURL := range map[string]string{"metadata.homepage": index.Metadata.Homepage, "metadata.source.repository": index.Metadata.Source.Repository} {
		if rawURL != "" {
			if err := validateRemoteModuleURL(rawURL); err != nil {
				return fmt.Errorf("%s: %w", field, err)
			}
		}
	}
	if len(index.Metadata.Source.Revision) != 40 || index.Metadata.Source.Revision != strings.ToLower(index.Metadata.Source.Revision) {
		return errors.New("metadata.source.revision must be 40 lowercase hexadecimal characters")
	}
	for _, r := range index.Metadata.Source.Revision {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return errors.New("metadata.source.revision must be 40 lowercase hexadecimal characters")
		}
	}
	if index.Entries == nil || len(index.Entries) > maxMarketplaceEntries {
		return fmt.Errorf("entries must be an array with at most %d items", maxMarketplaceEntries)
	}
	seenEntries := make(map[string]struct{}, len(index.Entries))
	seenManifestURLs := make(map[string]struct{}, len(index.Entries))
	for entryIndex, entry := range index.Entries {
		if entryIndex > 0 && index.Entries[entryIndex-1].ID > entry.ID {
			return errors.New("marketplace entries must be sorted by id")
		}
		if !validInterceptModuleID(entry.ID) {
			return fmt.Errorf("entries[%d].id is invalid", entryIndex)
		}
		if _, duplicate := seenEntries[entry.ID]; duplicate {
			return fmt.Errorf("duplicate marketplace entry id %q", entry.ID)
		}
		seenEntries[entry.ID] = struct{}{}
		if !nativeExtensionVersionPattern.MatchString(entry.Version) {
			return fmt.Errorf("entry %q version must be semantic", entry.ID)
		}
		if err := validateMarketplaceText("entry name", entry.Name, 1, maxInterceptModuleName); err != nil {
			return err
		}
		if err := validateMarketplaceText("entry description", entry.Description, 0, maxInterceptModuleDesc); err != nil {
			return err
		}
		if len(entry.Tags) > maxMarketplaceTags {
			return fmt.Errorf("entry %q has too many tags", entry.ID)
		}
		for tagIndex, tag := range entry.Tags {
			if tag == "" || len(tag) > maxMarketplaceTagBytes || !marketplaceTagPattern.MatchString(tag) {
				return fmt.Errorf("entry %q has an invalid tag", entry.ID)
			}
			if tag != strings.ToLower(strings.TrimSpace(tag)) || (tagIndex > 0 && entry.Tags[tagIndex-1] >= tag) {
				return fmt.Errorf("entry %q tags must be canonical, unique, and sorted", entry.ID)
			}
		}
		if len(entry.License.SPDX) > maxMarketplaceLicense || !marketplaceSPDXPattern.MatchString(entry.License.SPDX) {
			return fmt.Errorf("entry %q SPDX license is invalid", entry.ID)
		}
		for field, rawURL := range map[string]string{"license URL": entry.License.URL, "documentation URL": entry.DocumentationURL} {
			if rawURL != "" {
				if err := validateRemoteModuleURL(rawURL); err != nil {
					return fmt.Errorf("entry %q %s: %w", entry.ID, field, err)
				}
			}
		}
		if err := validateMarketplaceResource(entry.Manifest, false, maxInterceptModuleSource); err != nil {
			return fmt.Errorf("entry %q manifest: %w", entry.ID, err)
		}
		if _, duplicate := seenManifestURLs[entry.Manifest.URL]; duplicate {
			return fmt.Errorf("duplicate marketplace manifest URL %q", entry.Manifest.URL)
		}
		seenManifestURLs[entry.Manifest.URL] = struct{}{}
		if len(entry.Resources) > maxMarketplaceResources {
			return fmt.Errorf("entry %q has too many resources", entry.ID)
		}
		resourceURLs := make(map[string]struct{}, len(entry.Resources))
		resourcePaths := make(map[string]struct{}, len(entry.Resources))
		var total int64
		for resourceIndex, resource := range entry.Resources {
			if resourceIndex > 0 {
				previous := entry.Resources[resourceIndex-1]
				if previous.Path > resource.Path || (previous.Path == resource.Path && previous.URL > resource.URL) {
					return fmt.Errorf("entry %q resources must be sorted by path and URL", entry.ID)
				}
			}
			if err := validateMarketplaceResource(resource, true, maxInterceptScriptSource); err != nil {
				return fmt.Errorf("entry %q resource: %w", entry.ID, err)
			}
			if _, duplicate := resourceURLs[resource.URL]; duplicate {
				return fmt.Errorf("entry %q has duplicate resource URL %q", entry.ID, resource.URL)
			}
			if _, duplicate := resourcePaths[resource.Path]; duplicate {
				return fmt.Errorf("entry %q has duplicate resource path %q", entry.ID, resource.Path)
			}
			resourceURLs[resource.URL] = struct{}{}
			resourcePaths[resource.Path] = struct{}{}
			total += resource.Size
		}
		if total > maxInterceptScriptTotal {
			return fmt.Errorf("entry %q resources exceed %d bytes", entry.ID, maxInterceptScriptTotal)
		}
		capabilities := entry.Capabilities
		if capabilities.RoutingRuleCount == nil || capabilities.CaptureHostCount < 1 || capabilities.CaptureHostCount > maxInterceptModuleHosts ||
			capabilities.ActionCount < 0 || capabilities.ActionCount > maxInterceptModuleRules ||
			capabilities.SettingCount < 0 || capabilities.SettingCount > maxInterceptSettings ||
			capabilities.UpstreamMappingCount < 0 || capabilities.UpstreamMappingCount > maxInterceptModuleRules ||
			*capabilities.RoutingRuleCount < 0 || *capabilities.RoutingRuleCount > maxInterceptRoutingRules ||
			capabilities.ActionCount+capabilities.UpstreamMappingCount < 1 ||
			capabilities.ActionCount+capabilities.UpstreamMappingCount > maxInterceptModuleRules {
			return fmt.Errorf("entry %q has invalid capability counts", entry.ID)
		}
		if err := validateInterceptNetworkOrigins(capabilities.NetworkOrigins); err != nil {
			return fmt.Errorf("entry %q capabilities: %w", entry.ID, err)
		}
	}
	return nil
}

func validateMarketplaceText(field, value string, minLength, maxLength int) error {
	if !utf8.ValidString(value) || len(value) < minLength || len(value) > maxLength || value != strings.TrimSpace(value) {
		return fmt.Errorf("%s must contain %d to %d bytes", field, minLength, maxLength)
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return fmt.Errorf("%s must not contain control characters", field)
		}
	}
	return nil
}

func validateMarketplaceResource(resource marketplaceResource, requirePath bool, maxSize int64) error {
	if requirePath {
		cleaned := path.Clean(resource.Path)
		if resource.Path == "" || cleaned != resource.Path || cleaned == "." || strings.HasPrefix(cleaned, "../") || path.IsAbs(cleaned) || strings.Contains(resource.Path, "\\") {
			return errors.New("path must be a canonical relative path")
		}
	} else if resource.Path != "" {
		return errors.New("manifest path must be empty")
	}
	if err := validateRemoteModuleURL(resource.URL); err != nil {
		return err
	}
	if !validSHA256(resource.SHA256) {
		return errors.New("sha256 must be a lowercase SHA-256 digest")
	}
	if resource.Size < 1 || resource.Size > maxSize {
		return fmt.Errorf("size must be between 1 and %d", maxSize)
	}
	return nil
}

func resolveMarketplaceURL(baseURL, raw string, optional bool) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" && optional {
		return "", nil
	}
	if raw == "" || len(raw) > maxInterceptResourceURL {
		return "", fmt.Errorf("URL must contain 1 to %d bytes", maxInterceptResourceURL)
	}
	reference, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if !reference.IsAbs() {
		base, err := url.Parse(baseURL)
		if err != nil {
			return "", err
		}
		reference = base.ResolveReference(reference)
	}
	resolved := reference.String()
	if err := validateRemoteModuleURL(resolved); err != nil {
		return "", err
	}
	return resolved, nil
}

func normalizeMarketplaceTags(tags []string) []string {
	result := make([]string, 0, len(tags))
	for _, tag := range tags {
		tag = strings.ToLower(strings.TrimSpace(tag))
		if tag != "" {
			result = append(result, tag)
		}
	}
	return uniqueSortedStrings(result)
}

func validateMarketplaceInstall(_ marketplaceSourceSnapshot, entry marketplaceEntry, module interceptModuleSnapshot) error {
	if entry.Manifest.SHA256 != module.Source.Digest || entry.Manifest.Size != int64(len(module.Source.Body)) {
		return errors.New("manifest digest or size mismatch")
	}
	if entry.ID != module.ID || entry.Name != module.Name || entry.Version != module.Version || entry.Description != module.Description {
		return errors.New("manifest identity or descriptive metadata mismatch")
	}
	capabilities := entry.Capabilities
	if capabilities.CaptureHostCount != len(module.CaptureHosts) ||
		capabilities.ActionCount != len(module.Scripts) ||
		capabilities.SettingCount != len(module.Settings) ||
		capabilities.PersistentStorage != module.PersistentStorage ||
		capabilities.UpstreamMappingCount != len(module.HostMappings) ||
		capabilities.RoutingRuleCount == nil || *capabilities.RoutingRuleCount != len(module.RoutingRules) ||
		capabilities.EgressGroupRequired != module.EgressGroupRequired ||
		!stringSlicesEqual(capabilities.NetworkOrigins, module.NetworkOrigins) {
		return errors.New("manifest capabilities mismatch")
	}
	actualResources, err := marketplaceResourcesFromModule(module)
	if err != nil {
		return err
	}
	expected := append([]marketplaceResource(nil), entry.Resources...)
	sort.Slice(expected, func(i, j int) bool { return expected[i].URL < expected[j].URL })
	sort.Slice(actualResources, func(i, j int) bool { return actualResources[i].URL < actualResources[j].URL })
	if len(expected) != len(actualResources) {
		return errors.New("remote script resource count mismatch")
	}
	for index := range expected {
		if expected[index] != actualResources[index] {
			return fmt.Errorf("remote script resource mismatch for %q", expected[index].URL)
		}
	}
	return nil
}

func marketplaceResourcesFromModule(module interceptModuleSnapshot) ([]marketplaceResource, error) {
	manifest, err := decodeNativeExtensionManifest([]byte(module.Source.Body))
	if err != nil {
		return nil, err
	}
	if len(manifest.Actions) != len(module.Scripts) {
		return nil, errors.New("manifest action count changed after parsing")
	}
	byURL := make(map[string]marketplaceResource)
	for index, rawAction := range manifest.Actions {
		source := strings.TrimSpace(rawAction.Script.Source)
		if source == "" {
			continue
		}
		script := module.Scripts[index]
		resourcePath := path.Clean(source)
		if parsed, parseErr := url.Parse(source); parseErr == nil && parsed.IsAbs() {
			resourcePath = strings.TrimPrefix(path.Clean(parsed.Path), "/")
		}
		resource := marketplaceResource{
			Path: resourcePath, URL: script.ScriptURL, SHA256: script.ScriptDigest, Size: int64(len(script.ScriptBody)),
		}
		if existing, ok := byURL[resource.URL]; ok {
			if existing != resource {
				return nil, fmt.Errorf("remote script URL %q has inconsistent snapshots", resource.URL)
			}
			continue
		}
		byURL[resource.URL] = resource
	}
	resources := make([]marketplaceResource, 0, len(byURL))
	for _, resource := range byURL {
		resources = append(resources, resource)
	}
	return resources, nil
}
