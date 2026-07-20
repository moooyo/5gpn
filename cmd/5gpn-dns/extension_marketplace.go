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
	ID           string                 `json:"id"`
	Name         string                 `json:"name"`
	MetadataName string                 `json:"metadata_name"`
	Description  string                 `json:"description"`
	Homepage     string                 `json:"homepage"`
	URL          string                 `json:"url"`
	FinalURL     string                 `json:"final_url"`
	Digest       string                 `json:"digest"`
	FetchedAt    string                 `json:"fetched_at"`
	Entries      []marketplaceEntryView `json:"entries"`
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
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(revision) {
		return marketplaceView{}, errors.New("a valid marketplace revision is required")
	}
	configuredURL, err := normalizeModuleImportURL(rawURL)
	if err != nil {
		return marketplaceView{}, err
	}
	displayName, err := normalizeMarketplaceDisplayName(rawDisplayName)
	if err != nil {
		return marketplaceView{}, err
	}
	if err := m.preflightRevision(revision); err != nil {
		return marketplaceView{}, err
	}
	source, err := m.fetch(ctx, configuredURL)
	if err != nil {
		return marketplaceView{}, err
	}
	source.DisplayName = displayName

	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	defer m.store.mu.Unlock()
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
	return m.writeLocked(document)
}

func (m *ExtensionMarketplaceManager) Refresh(ctx context.Context, id, revision string) (marketplaceView, error) {
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(revision) {
		return marketplaceView{}, errors.New("a valid marketplace revision is required")
	}
	current, err := m.sourceAtRevision(id, revision)
	if err != nil {
		return marketplaceView{}, err
	}
	refreshed, err := m.fetch(ctx, current.URL)
	if err != nil {
		return marketplaceView{}, err
	}
	if refreshed.ID != current.ID {
		return marketplaceView{}, fmt.Errorf("%w: refreshed marketplace changed metadata.id", errMarketplaceConflict)
	}
	refreshed.DisplayName = current.DisplayName

	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	defer m.store.mu.Unlock()
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
	return m.writeLocked(document)
}

func (m *ExtensionMarketplaceManager) Delete(id, revision string) (marketplaceView, error) {
	if m == nil || m.store == nil {
		return marketplaceView{}, errMarketplaceUnavailable
	}
	if !validSHA256(revision) {
		return marketplaceView{}, errors.New("a valid marketplace revision is required")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.store.mu.Lock()
	defer m.store.mu.Unlock()
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
	return m.writeLocked(document)
}

func (m *ExtensionMarketplaceManager) Install(ctx context.Context, marketplaceID, extensionID, marketplaceRev, moduleRev string) (interceptModulesView, error) {
	if m == nil || m.store == nil || m.modules == nil {
		return interceptModulesView{}, errMarketplaceUnavailable
	}
	if !validSHA256(marketplaceRev) || !validSHA256(moduleRev) {
		return interceptModulesView{}, errors.New("valid marketplace_revision and module_revision are required")
	}
	source, entry, err := m.entryAtRevision(marketplaceID, extensionID, marketplaceRev)
	if err != nil {
		return interceptModulesView{}, err
	}
	module, err := m.modules.parser.Import(ctx, interceptModuleImportRequest{URL: entry.Manifest.URL})
	if err != nil {
		return interceptModulesView{}, err
	}
	if err := validateMarketplaceInstall(source, entry, module); err != nil {
		return interceptModulesView{}, fmt.Errorf("%w: %v", errMarketplaceIntegrity, err)
	}

	m.mu.Lock()
	m.store.mu.Lock()
	document, body, err := m.store.Read()
	if err != nil {
		m.store.mu.Unlock()
		m.mu.Unlock()
		return interceptModulesView{}, err
	}
	if marketplaceRevision(body) != marketplaceRev {
		m.store.mu.Unlock()
		m.mu.Unlock()
		return interceptModulesView{}, errMarketplaceRevision
	}
	latestSourceIndex := marketplaceSourceIndex(document.Sources, marketplaceID)
	if latestSourceIndex < 0 || marketplaceEntryIndex(document.Sources[latestSourceIndex].Entries, extensionID) < 0 {
		m.store.mu.Unlock()
		m.mu.Unlock()
		return interceptModulesView{}, errMarketplaceRevision
	}
	// The exact persisted entry has now been revalidated. Release marketplace
	// locks before entering the independent module transaction; the module CAS
	// protects its own document while the already fetched snapshot remains bound
	// to the caller's explicit marketplace revision.
	m.store.mu.Unlock()
	m.mu.Unlock()
	return m.modules.importSnapshot(ctx, moduleRev, module)
}

func (m *ExtensionMarketplaceManager) preflightRevision(revision string) error {
	m.store.mu.Lock()
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

func (m *ExtensionMarketplaceManager) sourceAtRevision(id, revision string) (marketplaceSourceSnapshot, error) {
	m.store.mu.Lock()
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

func (m *ExtensionMarketplaceManager) entryAtRevision(marketplaceID, extensionID, revision string) (marketplaceSourceSnapshot, marketplaceEntry, error) {
	source, err := m.sourceAtRevision(marketplaceID, revision)
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

func (m *ExtensionMarketplaceManager) writeLocked(document marketplaceDocument) (marketplaceView, error) {
	body, err := marshalMarketplaceDocument(document)
	if err != nil {
		return marketplaceView{}, err
	}
	if err := atomicWriteFile(m.store.Path, body, 0o640); err != nil {
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
		name := source.Metadata.Name
		if source.DisplayName != "" {
			name = source.DisplayName
		}
		sourceView := marketplaceSourceView{
			ID: source.ID, Name: name, MetadataName: source.Metadata.Name, Description: source.Metadata.Description,
			Homepage: source.Metadata.Homepage, URL: source.URL, FinalURL: source.FinalURL,
			Digest: source.IndexDigest, FetchedAt: source.FetchedAt,
			Entries: make([]marketplaceEntryView, 0, len(source.Entries)),
		}
		for _, entry := range source.Entries {
			capabilities := marketplaceCapabilitiesView{
				CaptureHostCount: entry.Capabilities.CaptureHostCount, ActionCount: entry.Capabilities.ActionCount,
				SettingCount: entry.Capabilities.SettingCount, NetworkOrigins: append([]string{}, entry.Capabilities.NetworkOrigins...),
				PersistentStorage: entry.Capabilities.PersistentStorage, UpstreamMappingCount: entry.Capabilities.UpstreamMappingCount,
				EgressGroupRequired: entry.Capabilities.EgressGroupRequired,
			}
			sourceView.Entries = append(sourceView.Entries, marketplaceEntryView{
				ID: entry.ID, Name: entry.Name, Version: entry.Version, Description: entry.Description,
				Tags: append([]string(nil), entry.Tags...), License: entry.License,
				DocumentationURL: entry.DocumentationURL, ManifestURL: entry.Manifest.URL,
				ManifestDigest: entry.Manifest.SHA256, Capabilities: capabilities,
			})
		}
		view.Sources = append(view.Sources, sourceView)
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
		if capabilities.CaptureHostCount < 1 || capabilities.CaptureHostCount > maxInterceptModuleHosts ||
			capabilities.ActionCount < 0 || capabilities.ActionCount > maxInterceptModuleRules ||
			capabilities.SettingCount < 0 || capabilities.SettingCount > maxInterceptSettings ||
			capabilities.UpstreamMappingCount < 0 || capabilities.UpstreamMappingCount > maxInterceptModuleRules ||
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
