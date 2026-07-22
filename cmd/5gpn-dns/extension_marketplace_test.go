package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
)

type marketplaceFixture struct {
	server         *httptest.Server
	mu             sync.Mutex
	index          []byte
	manifest       string
	script         string
	fail           bool
	referer        string
	redirectTarget string
}

type marketplaceCancelOnEOFTransport struct {
	base   http.RoundTripper
	cancel context.CancelFunc
}

func (transport marketplaceCancelOnEOFTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := transport.base.RoundTrip(request)
	if err != nil {
		return nil, err
	}
	response.Body = &marketplaceCancelOnEOFBody{ReadCloser: response.Body, cancel: transport.cancel}
	return response, nil
}

type marketplaceCancelOnEOFBody struct {
	io.ReadCloser
	once   sync.Once
	cancel context.CancelFunc
}

type testSignalingContext struct {
	context.Context
	once    sync.Once
	checked chan struct{}
}

func (ctx *testSignalingContext) Err() error {
	err := ctx.Context.Err()
	ctx.once.Do(func() { close(ctx.checked) })
	return err
}

func (body *marketplaceCancelOnEOFBody) Read(buffer []byte) (int, error) {
	count, err := body.ReadCloser.Read(buffer)
	if errors.Is(err, io.EOF) {
		body.once.Do(body.cancel)
	}
	return count, err
}

func setMarketplaceCancelOnEOFClient(manager *ExtensionMarketplaceManager, fixture *marketplaceFixture, cancel context.CancelFunc) {
	client := *fixture.server.Client()
	client.Transport = marketplaceCancelOnEOFTransport{base: client.Transport, cancel: cancel}
	manager.parser.client = &client
}

func newMarketplaceFixture(t *testing.T, mutate func(*marketplaceIndex)) *marketplaceFixture {
	t.Helper()
	fixture := &marketplaceFixture{redirectTarget: "/index.json"}
	fixture.script = `function transform(context) { return { response: { body: context.response.body } } }`
	fixture.manifest = `apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: io.example.fixture
  name: Fixture extension
  version: 1.0.0
  description: Fixture description
permissions:
  persistentStorage: false
traffic:
  captureHosts: [api.example.com]
actions:
  - id: clean-response
    phase: response
    match:
      hosts: [api.example.com]
      schemes: [https]
      pathRegex: ^/
    script:
      source: ./clean.js
      bodyMode: text
      timeoutMs: 1000
      maxBodyBytes: 8388608
`
	fixture.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fixture.mu.Lock()
		defer fixture.mu.Unlock()
		switch r.URL.Path {
		case "/redirect":
			http.Redirect(w, r, fixture.redirectTarget, http.StatusFound)
		case "/unsafe-redirect":
			http.Redirect(w, r, "http://127.0.0.1/internal", http.StatusFound)
		case "/index.json", "/a/index.json", "/b/index.json":
			fixture.referer = r.Header.Get("Referer")
			if fixture.fail {
				http.Error(w, "failed", http.StatusBadGateway)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(fixture.index)
		case "/extension.yaml":
			_, _ = w.Write([]byte(fixture.manifest))
		case "/clean.js":
			_, _ = w.Write([]byte(fixture.script))
		default:
			http.NotFound(w, r)
		}
	}))
	routingRuleCount := 0
	index := marketplaceIndex{
		APIVersion: marketplaceAPIVersion,
		Kind:       marketplaceKind,
		Metadata: marketplaceMetadata{
			ID: "io.example.marketplace", Name: "Example marketplace", Description: "Example catalog",
			Homepage: "./", Source: marketplaceMetadataSource{Repository: "./repository", Revision: strings.Repeat("a", 40)},
		},
		Entries: []marketplaceEntry{{
			ID: "io.example.fixture", Name: "Fixture extension", Version: "1.0.0", Description: "Fixture description",
			Tags:    []string{"Utility", "utility"},
			License: marketplaceLicense{SPDX: "MIT", URL: "./LICENSE"}, DocumentationURL: "./README.md",
			Manifest:  marketplaceResource{URL: "./extension.yaml", SHA256: sha256Hex([]byte(fixture.manifest)), Size: int64(len(fixture.manifest))},
			Resources: []marketplaceResource{{Path: "clean.js", URL: "./clean.js", SHA256: sha256Hex([]byte(fixture.script)), Size: int64(len(fixture.script))}},
			Capabilities: marketplaceCapabilities{
				CaptureHostCount: 1, ActionCount: 1, SettingCount: 0, NetworkOrigins: []string{},
				PersistentStorage: false, UpstreamMappingCount: 0, RoutingRuleCount: &routingRuleCount, EgressGroupRequired: false,
			},
		}},
	}
	if mutate != nil {
		mutate(&index)
	}
	body, err := json.Marshal(index)
	if err != nil {
		fixture.server.Close()
		t.Fatal(err)
	}
	fixture.index = body
	t.Cleanup(fixture.server.Close)
	return fixture
}

func newMarketplaceManagerFixture(t *testing.T, fixture *marketplaceFixture) (*ExtensionMarketplaceManager, *InterceptModuleManager, string) {
	t.Helper()
	moduleManager, _, _, _, _ := newInterceptManagerFixture(t)
	moduleManager.parser.client = fixture.server.Client()
	storePath := filepath.Join(t.TempDir(), "extension-marketplaces.json")
	manager := NewExtensionMarketplaceManager(NewExtensionMarketplaceStore(storePath), nil, moduleManager)
	manager.parser.client = fixture.server.Client()
	manager.now = func() time.Time { return time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC) }
	return manager, moduleManager, storePath
}

func TestMarketplaceMissingStoreIsCanonicalEmptyDocument(t *testing.T) {
	store := NewExtensionMarketplaceStore(filepath.Join(t.TempDir(), "missing.json"))
	document, body, err := store.Read()
	if err != nil {
		t.Fatal(err)
	}
	if document.Version != 1 || document.Sources == nil || len(document.Sources) != 0 || !validSHA256(marketplaceRevision(body)) {
		t.Fatalf("empty marketplace document = %+v body=%s", document, body)
	}
	var decoded marketplaceDocument
	if err := unmarshalStrictJSON(body, &decoded); err != nil {
		t.Fatal(err)
	}
}

func TestMarketplaceAddRefreshDeleteAndStaleFailure(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, _, storePath := newMarketplaceManagerFixture(t, fixture)
	empty, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	added, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/redirect", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(added.Sources) != 1 || added.Sources[0].ID != "io.example.marketplace" || fixture.referer != "" {
		t.Fatalf("added view = %+v referer=%q", added, fixture.referer)
	}
	persistedBefore := mustRead(t, storePath)
	fixture.mu.Lock()
	fixture.fail = true
	fixture.mu.Unlock()
	if _, err := manager.Refresh(context.Background(), added.Sources[0].ID, added.Revision); !errors.Is(err, errMarketplaceFetch) {
		t.Fatalf("refresh error = %v", err)
	}
	if got := mustRead(t, storePath); got != persistedBefore {
		t.Fatal("failed refresh changed the persisted snapshot")
	}
	if _, err := manager.Delete(context.Background(), added.Sources[0].ID, empty.Revision); !errors.Is(err, errMarketplaceRevision) {
		t.Fatalf("stale delete error = %v", err)
	}
	deleted, err := manager.Delete(context.Background(), added.Sources[0].ID, added.Revision)
	if err != nil || len(deleted.Sources) != 0 {
		t.Fatalf("deleted view = %+v err=%v", deleted, err)
	}
}

func TestMarketplaceAddAndRefreshRejectCancellationBeforeFinalCommit(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, _, _ := newMarketplaceManagerFixture(t, fixture)
	empty, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}

	addCtx, cancelAdd := context.WithCancel(context.Background())
	setMarketplaceCancelOnEOFClient(manager, fixture, cancelAdd)
	if _, err := manager.Add(addCtx, empty.Revision, fixture.server.URL+"/index.json", ""); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled add error = %v", err)
	}
	afterCancelledAdd, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if afterCancelledAdd.Revision != empty.Revision || len(afterCancelledAdd.Sources) != 0 {
		t.Fatalf("cancelled add committed state: %+v", afterCancelledAdd)
	}

	manager.parser.client = fixture.server.Client()
	added, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", "")
	if err != nil {
		t.Fatal(err)
	}
	fixture.mu.Lock()
	var updated marketplaceIndex
	if err := json.Unmarshal(fixture.index, &updated); err != nil {
		fixture.mu.Unlock()
		t.Fatal(err)
	}
	updated.Metadata.Description = "Changed description"
	fixture.index, err = json.Marshal(updated)
	fixture.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}

	refreshCtx, cancelRefresh := context.WithCancel(context.Background())
	setMarketplaceCancelOnEOFClient(manager, fixture, cancelRefresh)
	if _, err := manager.Refresh(refreshCtx, added.Sources[0].ID, added.Revision); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled refresh error = %v", err)
	}
	afterCancelledRefresh, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if afterCancelledRefresh.Revision != added.Revision || afterCancelledRefresh.Sources[0].Description != added.Sources[0].Description {
		t.Fatalf("cancelled refresh committed state: before=%+v after=%+v", added, afterCancelledRefresh)
	}

	manager.mu.Lock()
	deleteBaseCtx, cancelDelete := context.WithCancel(context.Background())
	deleteCtx := &testSignalingContext{Context: deleteBaseCtx, checked: make(chan struct{})}
	deleteDone := make(chan error, 1)
	go func() {
		_, deleteErr := manager.Delete(deleteCtx, added.Sources[0].ID, added.Revision)
		deleteDone <- deleteErr
	}()
	<-deleteCtx.checked
	cancelDelete()
	select {
	case err := <-deleteDone:
		if !errors.Is(err, context.Canceled) {
			manager.mu.Unlock()
			t.Fatalf("cancelled delete error = %v", err)
		}
	case <-time.After(time.Second):
		manager.mu.Unlock()
		t.Fatal("cancelled delete remained blocked on the marketplace lock")
	}
	manager.mu.Unlock()
	afterCancelledDelete, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if afterCancelledDelete.Revision != added.Revision || len(afterCancelledDelete.Sources) != 1 {
		t.Fatalf("cancelled delete committed state: before=%+v after=%+v", added, afterCancelledDelete)
	}
}

func TestMarketplaceDisplayNamePersistsAcrossRefresh(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, _, storePath := newMarketplaceManagerFixture(t, fixture)
	empty, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	added, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", "  Team catalog  ")
	if err != nil {
		t.Fatal(err)
	}
	if len(added.Sources) != 1 || added.Sources[0].Name != "Team catalog" || added.Sources[0].MetadataName != "Example marketplace" {
		t.Fatalf("added source = %+v", added.Sources)
	}
	if persisted := mustRead(t, storePath); !strings.Contains(persisted, `"display_name": "Team catalog"`) {
		t.Fatalf("persisted marketplace omitted display name: %s", persisted)
	}
	refreshed, err := manager.Refresh(context.Background(), added.Sources[0].ID, added.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if len(refreshed.Sources) != 1 || refreshed.Sources[0].Name != "Team catalog" || refreshed.Sources[0].MetadataName != "Example marketplace" {
		t.Fatalf("refreshed source = %+v", refreshed.Sources)
	}
}

func TestMarketplaceEmptyDisplayNameFallsBackToMetadata(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, _, storePath := newMarketplaceManagerFixture(t, fixture)
	empty, _ := manager.View()
	added, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", " \t ")
	if err != nil {
		t.Fatal(err)
	}
	if len(added.Sources) != 1 || added.Sources[0].Name != "Example marketplace" || added.Sources[0].MetadataName != "Example marketplace" {
		t.Fatalf("source without display name = %+v", added.Sources)
	}
	if persisted := mustRead(t, storePath); strings.Contains(persisted, `"display_name"`) {
		t.Fatalf("empty display name was persisted: %s", persisted)
	}
	if _, _, err := manager.store.Read(); err != nil {
		t.Fatalf("read snapshot without display_name: %v", err)
	}
}

func TestMarketplaceInvalidDisplayNameDoesNotWrite(t *testing.T) {
	for name, displayName := range map[string]string{
		"too long":      strings.Repeat("a", maxMarketplaceDisplayName+1),
		"control":       "bad\nname",
		"invalid UTF-8": string([]byte{0xff}),
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newMarketplaceFixture(t, nil)
			manager, _, storePath := newMarketplaceManagerFixture(t, fixture)
			empty, _ := manager.View()
			if _, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", displayName); err == nil {
				t.Fatal("invalid display name was accepted")
			}
			if _, err := os.Stat(storePath); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("invalid display name changed the store: %v", err)
			}
		})
	}
}

func TestMarketplaceStrictSchemaAndBounds(t *testing.T) {
	for name, mutateBody := range map[string]func([]byte) []byte{
		"unknown field": func(body []byte) []byte {
			return []byte(strings.Replace(string(body), `"kind":"ExtensionMarketplace"`, `"kind":"ExtensionMarketplace","unknown":true`, 1))
		},
		"duplicate key": func(body []byte) []byte {
			return []byte(strings.Replace(string(body), `"kind":"ExtensionMarketplace"`, `"kind":"ExtensionMarketplace","Kind":"ExtensionMarketplace"`, 1))
		},
		"missing routing rule count": func(body []byte) []byte {
			return []byte(strings.Replace(string(body), `,"routingRuleCount":0`, "", 1))
		},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newMarketplaceFixture(t, nil)
			fixture.index = mutateBody(fixture.index)
			manager, _, _ := newMarketplaceManagerFixture(t, fixture)
			view, _ := manager.View()
			if _, err := manager.Add(context.Background(), view.Revision, fixture.server.URL+"/index.json", ""); !errors.Is(err, errMarketplaceFetch) {
				t.Fatalf("strict schema error = %v", err)
			}
		})
	}
	for name, mutate := range map[string]func(*marketplaceIndex){
		"control character": func(index *marketplaceIndex) { index.Metadata.Name = "bad\nname" },
		"invalid tag":       func(index *marketplaceIndex) { index.Entries[0].Tags = []string{"bad tag"} },
		"invalid SPDX":      func(index *marketplaceIndex) { index.Entries[0].License.SPDX = "MIT OR Apache-2.0" },
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newMarketplaceFixture(t, mutate)
			manager, _, _ := newMarketplaceManagerFixture(t, fixture)
			view, _ := manager.View()
			if _, err := manager.Add(context.Background(), view.Revision, fixture.server.URL+"/index.json", ""); !errors.Is(err, errMarketplaceFetch) {
				t.Fatalf("strict value error = %v", err)
			}
		})
	}
	t.Run("invalid UTF-8", func(t *testing.T) {
		fixture := newMarketplaceFixture(t, nil)
		fixture.index = append([]byte(nil), fixture.index...)
		for i := range fixture.index {
			if fixture.index[i] == 'E' {
				fixture.index[i] = 0xff
				break
			}
		}
		manager, _, _ := newMarketplaceManagerFixture(t, fixture)
		view, _ := manager.View()
		if _, err := manager.Add(context.Background(), view.Revision, fixture.server.URL+"/index.json", ""); !errors.Is(err, errMarketplaceFetch) {
			t.Fatalf("invalid UTF-8 error = %v", err)
		}
	})
	t.Run("entry limit", func(t *testing.T) {
		fixture := newMarketplaceFixture(t, func(index *marketplaceIndex) {
			base := index.Entries[0]
			index.Entries = make([]marketplaceEntry, maxMarketplaceEntries+1)
			for i := range index.Entries {
				entry := base
				entry.ID = fmt.Sprintf("io.example.extension-%d", i)
				index.Entries[i] = entry
			}
		})
		manager, _, _ := newMarketplaceManagerFixture(t, fixture)
		view, _ := manager.View()
		if _, err := manager.Add(context.Background(), view.Revision, fixture.server.URL+"/index.json", ""); !errors.Is(err, errMarketplaceFetch) {
			t.Fatalf("entry limit error = %v", err)
		}
	})
	t.Run("source limit", func(t *testing.T) {
		fixture := newMarketplaceFixture(t, nil)
		manager, _, _ := newMarketplaceManagerFixture(t, fixture)
		empty, _ := manager.View()
		added, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", "")
		if err != nil {
			t.Fatal(err)
		}
		manager.store.mu.Lock()
		document, _, err := manager.store.Read()
		manager.store.mu.Unlock()
		if err != nil {
			t.Fatal(err)
		}
		base := document.Sources[0]
		document.Sources = make([]marketplaceSourceSnapshot, maxMarketplaceSources+1)
		for i := range document.Sources {
			source := base
			source.ID = fmt.Sprintf("io.example.marketplace-%d", i)
			source.Metadata.ID = source.ID
			source.URL = fmt.Sprintf("https://market-%d.example.com/index.json", i)
			source.FinalURL = source.URL
			document.Sources[i] = source
		}
		if _, err := marshalMarketplaceDocument(document); err == nil {
			t.Fatalf("more than %d sources were accepted; initial revision=%s", maxMarketplaceSources, added.Revision)
		}
	})
}

func TestMarketplaceCaptureHostCapabilityBoundIs512(t *testing.T) {
	for _, test := range []struct {
		name    string
		count   int
		wantErr bool
	}{
		{name: "maximum", count: 512},
		{name: "over maximum", count: 513, wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newMarketplaceFixture(t, func(index *marketplaceIndex) {
				index.Entries[0].Capabilities.CaptureHostCount = test.count
			})
			manager, _, _ := newMarketplaceManagerFixture(t, fixture)
			view, err := manager.View()
			if err != nil {
				t.Fatal(err)
			}
			_, err = manager.Add(context.Background(), view.Revision, fixture.server.URL+"/index.json", "")
			if test.wantErr && !errors.Is(err, errMarketplaceFetch) {
				t.Fatalf("513 capability hosts error = %v", err)
			}
			if !test.wantErr && err != nil {
				t.Fatalf("512 capability hosts rejected: %v", err)
			}
		})
	}
}

func TestMarketplaceFetchRejectsUnsafeRedirect(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, _, _ := newMarketplaceManagerFixture(t, fixture)
	view, _ := manager.View()
	if _, err := manager.Add(context.Background(), view.Revision, fixture.server.URL+"/unsafe-redirect", ""); !errors.Is(err, errMarketplaceFetch) || !strings.Contains(err.Error(), "https") {
		t.Fatalf("unsafe redirect error = %v", err)
	}
}

func TestMarketplaceInstallVerifiesSnapshotAndLeavesModuleDisabled(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, moduleManager, _ := newMarketplaceManagerFixture(t, fixture)
	empty, _ := manager.View()
	marketplaces, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", "")
	if err != nil {
		t.Fatal(err)
	}
	modules, err := moduleManager.View()
	if err != nil {
		t.Fatal(err)
	}
	installed, err := manager.Install(context.Background(), "io.example.marketplace", "io.example.fixture", marketplaces.Revision, modules.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if len(installed.Modules) != 1 || installed.Modules[0].Enabled || installed.Modules[0].ID != "io.example.fixture" {
		t.Fatalf("installed modules = %+v", installed.Modules)
	}
	snapshot, err := moduleManager.Snapshot("io.example.fixture")
	if err != nil || len(snapshot.Scripts) != 1 || snapshot.Scripts[0].Digest != sha256Hex([]byte(fixture.script)) {
		t.Fatalf("installed snapshot = %+v err=%v", snapshot, err)
	}
}

func TestMarketplaceInstallRejectsManifestAndResourceMismatch(t *testing.T) {
	for name, mutate := range map[string]func(*marketplaceIndex){
		"manifest digest": func(index *marketplaceIndex) { index.Entries[0].Manifest.SHA256 = strings.Repeat("b", 64) },
		"resource digest": func(index *marketplaceIndex) { index.Entries[0].Resources[0].SHA256 = strings.Repeat("c", 64) },
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newMarketplaceFixture(t, mutate)
			manager, moduleManager, _ := newMarketplaceManagerFixture(t, fixture)
			empty, _ := manager.View()
			marketplaces, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", "")
			if err != nil {
				t.Fatal(err)
			}
			modules, _ := moduleManager.View()
			if _, err := manager.Install(context.Background(), "io.example.marketplace", "io.example.fixture", marketplaces.Revision, modules.Revision); !errors.Is(err, errMarketplaceIntegrity) {
				t.Fatalf("integrity error = %v", err)
			}
			view, _ := moduleManager.View()
			if len(view.Modules) != 0 {
				t.Fatal("integrity failure installed a module")
			}
		})
	}
}

func TestMarketplaceAPIViewOmitsInstallationInternals(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, _, _ := newMarketplaceManagerFixture(t, fixture)
	empty, _ := manager.View()
	view, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", "")
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	encoded := string(body)
	for _, forbidden := range []string{`"resources"`, `"repository"`, `"revision":"` + strings.Repeat("a", 40), `"size"`} {
		if strings.Contains(encoded, forbidden) {
			t.Fatalf("API view leaked internal field %s: %s", forbidden, encoded)
		}
	}
	for _, required := range []string{`"recommended_url"`, `"metadata_name"`, `"snapshot_digest"`, `"manifest_url"`, `"manifest_digest"`, `"documentation_url"`, `"capture_host_count"`, `"network_origins"`, `"routing_rule_count"`} {
		if !strings.Contains(encoded, required) {
			t.Fatalf("API view omitted %s: %s", required, encoded)
		}
	}
}

func TestMarketplaceAPIRequiresAuthAndMapsUnavailable(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	unauthorized := doAPI(fx.cs, http.MethodGet, "/api/interception/marketplaces", nil, "", false)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}
	unavailable := doAPI(fx.cs, http.MethodGet, "/api/interception/marketplaces", nil, fx.token, true)
	if unavailable.Code != http.StatusServiceUnavailable {
		t.Fatalf("unavailable status=%d body=%s", unavailable.Code, unavailable.Body.String())
	}
}

func TestMarketplaceAPIRoundTripAndInstall(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, moduleManager, _ := newMarketplaceManagerFixture(t, fixture)
	fx := newMihomoConfigTestFixture(t)
	fx.cs.SetInterceptModuleManager(moduleManager)
	fx.cs.SetExtensionMarketplaceManager(manager)

	get := doAPI(fx.cs, http.MethodGet, "/api/interception/marketplaces", nil, fx.token, true)
	view := decodeJSON[marketplaceView](t, get)
	if get.Code != http.StatusOK || len(view.Sources) != 0 {
		t.Fatalf("initial marketplace view = %+v status=%d", view, get.Code)
	}
	addBody, _ := json.Marshal(map[string]string{"revision": view.Revision, "url": fixture.server.URL + "/index.json", "name": "API catalog"})
	add := doAPI(fx.cs, http.MethodPost, "/api/interception/marketplaces", addBody, fx.token, true)
	view = decodeJSON[marketplaceView](t, add)
	if add.Code != http.StatusCreated || len(view.Sources) != 1 || view.Sources[0].Name != "API catalog" {
		t.Fatalf("added marketplace view = %+v status=%d body=%s", view, add.Code, add.Body.String())
	}
	refreshBody, _ := json.Marshal(map[string]string{"revision": view.Revision})
	refresh := doAPI(fx.cs, http.MethodPost, "/api/interception/marketplaces/io.example.marketplace/refresh", refreshBody, fx.token, true)
	view = decodeJSON[marketplaceView](t, refresh)
	if refresh.Code != http.StatusOK {
		t.Fatalf("refresh status=%d body=%s", refresh.Code, refresh.Body.String())
	}
	modules, _ := moduleManager.View()
	installBody, _ := json.Marshal(map[string]string{"marketplace_revision": view.Revision, "module_revision": modules.Revision})
	install := doAPI(fx.cs, http.MethodPost, "/api/interception/marketplaces/io.example.marketplace/entries/io.example.fixture/install", installBody, fx.token, true)
	installed := decodeJSON[interceptModulesView](t, install)
	if install.Code != http.StatusCreated || len(installed.Modules) != 1 || installed.Modules[0].Enabled {
		t.Fatalf("install status=%d modules=%+v body=%s", install.Code, installed.Modules, install.Body.String())
	}
	deleteBody, _ := json.Marshal(map[string]string{"revision": view.Revision})
	deleted := doAPI(fx.cs, http.MethodDelete, "/api/interception/marketplaces/io.example.marketplace", deleteBody, fx.token, true)
	view = decodeJSON[marketplaceView](t, deleted)
	if deleted.Code != http.StatusOK || len(view.Sources) != 0 {
		t.Fatalf("delete status=%d view=%+v body=%s", deleted.Code, view, deleted.Body.String())
	}
}

func TestMarketplaceStoreRejectsDuplicateSourcesAndURLs(t *testing.T) {
	fixture := newMarketplaceFixture(t, nil)
	manager, _, storePath := newMarketplaceManagerFixture(t, fixture)
	empty, _ := manager.View()
	added, err := manager.Add(context.Background(), empty.Revision, fixture.server.URL+"/index.json", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Add(context.Background(), added.Revision, fixture.server.URL+"/index.json", ""); !errors.Is(err, errMarketplaceConflict) {
		t.Fatalf("duplicate source error = %v", err)
	}
	if _, err := os.Stat(storePath); err != nil {
		t.Fatal(err)
	}
}

func TestExternalMaintainedMarketplaceMatchesCoreContract(t *testing.T) {
	indexPath := strings.TrimSpace(os.Getenv("FIVEGPN_MARKETPLACE_INDEX"))
	if indexPath == "" {
		t.Skip("FIVEGPN_MARKETPLACE_INDEX is not configured")
	}
	body, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatalf("read maintained marketplace index: %v", err)
	}
	if !utf8.Valid(body) {
		t.Fatal("maintained marketplace index is not valid UTF-8")
	}
	var index marketplaceIndex
	if err := unmarshalStrictJSON(body, &index); err != nil {
		t.Fatalf("decode maintained marketplace index: %v", err)
	}
	if err := normalizeAndValidateMarketplaceIndex(&index, recommendedMarketplaceURL); err != nil {
		t.Fatalf("validate maintained marketplace index: %v", err)
	}
	if index.Metadata.ID != "io.5gpn.official" || len(index.Entries) == 0 {
		t.Fatalf("unexpected maintained marketplace identity or entries: id=%q entries=%d", index.Metadata.ID, len(index.Entries))
	}
}
