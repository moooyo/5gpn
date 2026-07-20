package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

type blockingInterceptConfigTester struct {
	entered chan struct{}
	release chan struct{}
}

func (tester blockingInterceptConfigTester) Test(ctx context.Context, _ string) error {
	close(tester.entered)
	select {
	case <-tester.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestControllerExtensionManagersDelegateSharedTransactions(t *testing.T) {
	ctx := context.Background()
	fixture := newMarketplaceFixture(t, nil)
	marketplaces, modules, _ := newMarketplaceManagerFixture(t, fixture)
	controller := NewController(func() error { return nil }, nil, nil, nil)
	controller.SetInterceptModuleManager(modules)
	controller.SetExtensionMarketplaceManager(marketplaces)

	marketplaceView, err := controller.ExtensionMarketplaces()
	if err != nil {
		t.Fatal(err)
	}
	marketplaceView, err = controller.AddExtensionMarketplace(ctx, marketplaceView.Revision, fixture.server.URL+"/index.json", "Bot catalog")
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	settingsView, err := controller.InterceptSettings()
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err = controller.UpdateInterceptSettings(ctx, settingsView.Revision, interceptMITMSettings{
		Enabled:                false,
		HTTP2:                  true,
		QUICFallbackProtection: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err = controller.InstallMarketplaceExtension(
		ctx,
		"io.example.marketplace",
		"io.example.fixture",
		marketplaceView.Revision,
		moduleView.Revision,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(moduleView.Modules) != 1 || moduleView.Modules[0].Enabled {
		t.Fatalf("installed modules = %+v", moduleView.Modules)
	}

	if _, err := controller.InterceptModuleSnapshot("io.example.fixture"); err != nil {
		t.Fatal(err)
	}
	moduleView, err = controller.UpdateInterceptModule(ctx, "io.example.fixture", interceptModuleUpdate{
		Revision: moduleView.Revision,
		Settings: map[string]json.RawMessage{},
	})
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err = controller.ReorderInterceptModules(ctx, moduleView.Revision, []string{"io.example.fixture"})
	if err != nil {
		t.Fatal(err)
	}

	fixture.mu.Lock()
	fixture.manifest = strings.Replace(fixture.manifest, "version: 1.0.0", "version: 1.0.1", 1)
	fixture.mu.Unlock()
	update, err := controller.CheckInterceptModuleUpdate(ctx, "io.example.fixture", moduleView.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if update.State != "available" || update.Candidate == nil {
		t.Fatalf("update check = %+v", update)
	}
	moduleView, err = controller.ApplyInterceptModuleUpdate(
		ctx,
		"io.example.fixture",
		moduleView.Revision,
		update.Candidate.SnapshotDigest,
	)
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err = controller.DeleteInterceptModule(ctx, "io.example.fixture", moduleView.Revision)
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err = controller.ImportInterceptModule(ctx, interceptModuleImportRequest{
		Revision: moduleView.Revision,
		URL:      fixture.server.URL + "/extension.yaml",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := controller.DeleteInterceptModule(ctx, "io.example.fixture", moduleView.Revision); err != nil {
		t.Fatal(err)
	}

	marketplaceView, err = controller.RefreshExtensionMarketplace(ctx, "io.example.marketplace", marketplaceView.Revision)
	if err != nil {
		t.Fatal(err)
	}
	marketplaceView, err = controller.DeleteExtensionMarketplace(ctx, "io.example.marketplace", marketplaceView.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if len(marketplaceView.Sources) != 0 {
		t.Fatalf("marketplaces after delete = %+v", marketplaceView.Sources)
	}
}

func TestControllerImportExpectedRejectsChangedPreviewWithoutWrite(t *testing.T) {
	ctx := context.Background()
	fixture := newMarketplaceFixture(t, nil)
	_, modules, _ := newMarketplaceManagerFixture(t, fixture)
	controller := NewController(func() error { return nil }, nil, nil, nil)
	controller.SetInterceptModuleManager(modules)

	before, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	request := interceptModuleImportRequest{
		Revision: before.Revision,
		URL:      fixture.server.URL + "/extension.yaml",
	}
	preview, err := controller.PreviewInterceptModuleImport(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	if preview.ExecutionOrder != 1 || !validSHA256(preview.SnapshotDigest) {
		t.Fatalf("preview = %+v", preview)
	}
	afterPreview, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if afterPreview.Revision != before.Revision || len(afterPreview.Modules) != 0 {
		t.Fatalf("preview changed modules: before=%+v after=%+v", before, afterPreview)
	}

	fixture.mu.Lock()
	fixture.manifest = strings.Replace(fixture.manifest, "version: 1.0.0", "version: 1.0.1", 1)
	fixture.mu.Unlock()
	if _, err := controller.ImportInterceptModuleExpected(ctx, request, preview.SnapshotDigest); !errors.Is(err, errInterceptRevisionConflict) {
		t.Fatalf("changed snapshot error = %v", err)
	}
	afterReject, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if afterReject.Revision != before.Revision || len(afterReject.Modules) != 0 {
		t.Fatalf("rejected import changed modules: before=%+v after=%+v", before, afterReject)
	}

	preview, err = controller.PreviewInterceptModuleImport(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	applied, err := controller.ImportInterceptModuleExpected(ctx, request, preview.SnapshotDigest)
	if err != nil {
		t.Fatal(err)
	}
	if len(applied.Modules) != 1 || applied.Modules[0].Version != "1.0.1" {
		t.Fatalf("applied modules = %+v", applied.Modules)
	}
}

func TestControllerPreviewImportRejectsDuplicateAndReportsRequiredEgress(t *testing.T) {
	ctx := context.Background()
	fixture := newMarketplaceFixture(t, nil)
	fixture.mu.Lock()
	fixture.manifest = strings.Replace(
		fixture.manifest,
		"traffic:\n",
		"requirements:\n  egressGroup:\n    required: true\ntraffic:\n",
		1,
	)
	fixture.mu.Unlock()
	_, modules, _ := newMarketplaceManagerFixture(t, fixture)
	controller := NewController(func() error { return nil }, nil, nil, nil)
	controller.SetInterceptModuleManager(modules)

	before, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	request := interceptModuleImportRequest{Revision: before.Revision, URL: fixture.server.URL + "/extension.yaml"}
	preview, err := controller.PreviewInterceptModuleImport(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	if preview.Ready || preview.Reason != "egress-group-required" || preview.ExecutionOrder != 1 {
		t.Fatalf("required-egress preview = %+v", preview)
	}
	applied, err := controller.ImportInterceptModuleExpected(ctx, request, preview.SnapshotDigest)
	if err != nil {
		t.Fatal(err)
	}
	request.Revision = applied.Revision
	if _, err := controller.PreviewInterceptModuleImport(ctx, request); !errors.Is(err, errInterceptModuleConflict) {
		t.Fatalf("duplicate preview error = %v", err)
	}
}

func TestControllerMarketplaceExpectedBindsNormalizedRedirectSnapshot(t *testing.T) {
	ctx := context.Background()
	fixture := newMarketplaceFixture(t, nil)
	marketplaces, _, _ := newMarketplaceManagerFixture(t, fixture)
	controller := NewController(func() error { return nil }, nil, nil, nil)
	controller.SetExtensionMarketplaceManager(marketplaces)

	empty, err := controller.ExtensionMarketplaces()
	if err != nil {
		t.Fatal(err)
	}
	fixture.mu.Lock()
	fixture.redirectTarget = "/a/index.json"
	fixture.mu.Unlock()
	previewA, err := controller.PreviewExtensionMarketplaceAdd(ctx, fixture.server.URL+"/redirect", "Catalog")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(previewA.FinalURL, "/a/index.json") || !validSHA256(previewA.SnapshotDigest) {
		t.Fatalf("preview A = %+v", previewA)
	}
	previewWithOtherName, err := controller.PreviewExtensionMarketplaceAdd(ctx, fixture.server.URL+"/redirect", "Other catalog")
	if err != nil {
		t.Fatal(err)
	}
	if previewWithOtherName.Digest != previewA.Digest || previewWithOtherName.SnapshotDigest == previewA.SnapshotDigest {
		t.Fatalf("display name was not bound to snapshot proof: A=%+v other=%+v", previewA, previewWithOtherName)
	}
	if _, err := controller.AddExtensionMarketplaceExpected(
		ctx,
		empty.Revision,
		fixture.server.URL+"/redirect",
		"Other catalog",
		previewA.SnapshotDigest,
	); !errors.Is(err, errMarketplaceRevision) {
		t.Fatalf("changed display name error = %v", err)
	}

	fixture.mu.Lock()
	fixture.redirectTarget = "/b/index.json"
	fixture.mu.Unlock()
	if _, err := controller.AddExtensionMarketplaceExpected(
		ctx,
		empty.Revision,
		fixture.server.URL+"/redirect",
		"Catalog",
		previewA.SnapshotDigest,
	); !errors.Is(err, errMarketplaceRevision) {
		t.Fatalf("changed add snapshot error = %v", err)
	}
	afterReject, err := controller.ExtensionMarketplaces()
	if err != nil {
		t.Fatal(err)
	}
	if afterReject.Revision != empty.Revision || len(afterReject.Sources) != 0 {
		t.Fatalf("rejected add changed marketplaces: before=%+v after=%+v", empty, afterReject)
	}
	previewB, err := controller.PreviewExtensionMarketplaceAdd(ctx, fixture.server.URL+"/redirect", "Catalog")
	if err != nil {
		t.Fatal(err)
	}
	if previewA.Digest != previewB.Digest || previewA.SnapshotDigest == previewB.SnapshotDigest {
		t.Fatalf("redirect proofs: A=%+v B=%+v", previewA, previewB)
	}

	fixture.mu.Lock()
	fixture.redirectTarget = "/a/index.json"
	fixture.mu.Unlock()
	previewA, err = controller.PreviewExtensionMarketplaceAdd(ctx, fixture.server.URL+"/redirect", "Catalog")
	if err != nil {
		t.Fatal(err)
	}
	added, err := controller.AddExtensionMarketplaceExpected(
		ctx,
		empty.Revision,
		fixture.server.URL+"/redirect",
		"Catalog",
		previewA.SnapshotDigest,
	)
	if err != nil {
		t.Fatal(err)
	}
	refreshA, err := controller.PreviewExtensionMarketplaceRefresh(ctx, "io.example.marketplace", added.Revision)
	if err != nil {
		t.Fatal(err)
	}
	fixture.mu.Lock()
	fixture.redirectTarget = "/b/index.json"
	fixture.mu.Unlock()
	if _, err := controller.RefreshExtensionMarketplaceExpected(
		ctx,
		"io.example.marketplace",
		added.Revision,
		refreshA.SnapshotDigest,
	); !errors.Is(err, errMarketplaceRevision) {
		t.Fatalf("changed refresh snapshot error = %v", err)
	}
	afterRefreshReject, err := controller.ExtensionMarketplaces()
	if err != nil {
		t.Fatal(err)
	}
	if afterRefreshReject.Revision != added.Revision || !strings.HasSuffix(afterRefreshReject.Sources[0].FinalURL, "/a/index.json") {
		t.Fatalf("rejected refresh changed marketplaces: before=%+v after=%+v", added, afterRefreshReject)
	}
	refreshB, err := controller.PreviewExtensionMarketplaceRefresh(ctx, "io.example.marketplace", added.Revision)
	if err != nil {
		t.Fatal(err)
	}
	refreshed, err := controller.RefreshExtensionMarketplaceExpected(
		ctx,
		"io.example.marketplace",
		added.Revision,
		refreshB.SnapshotDigest,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(refreshed.Sources[0].FinalURL, "/b/index.json") {
		t.Fatalf("refreshed marketplaces = %+v", refreshed.Sources)
	}
}

func TestMarketplaceSourceSnapshotDigestExcludesOnlyFetchTime(t *testing.T) {
	source := marketplaceSourceSnapshot{
		ID:          "io.example.marketplace",
		DisplayName: "Catalog",
		URL:         "https://catalog.example/index.json",
		FinalURL:    "https://catalog.example/index.json",
		IndexDigest: strings.Repeat("a", 64),
		FetchedAt:   "2026-07-20T00:00:00Z",
		Metadata:    marketplaceMetadata{ID: "io.example.marketplace", Name: "Example"},
		Entries:     []marketplaceEntry{},
	}
	digest := marketplaceSourceSnapshotDigest(source)
	source.FetchedAt = "2026-07-21T00:00:00Z"
	if got := marketplaceSourceSnapshotDigest(source); got != digest {
		t.Fatalf("fetch time changed snapshot digest: got %s want %s", got, digest)
	}
	source.DisplayName = "Other catalog"
	if got := marketplaceSourceSnapshotDigest(source); got == digest {
		t.Fatal("display name was omitted from snapshot digest")
	}
}

func TestControllerMarketplaceInstallExpectedRejectsChangedCandidateWithoutWrite(t *testing.T) {
	ctx := context.Background()
	fixture := newMarketplaceFixture(t, nil)
	marketplaces, modules, _ := newMarketplaceManagerFixture(t, fixture)
	controller := NewController(func() error { return nil }, nil, nil, nil)
	controller.SetInterceptModuleManager(modules)
	controller.SetExtensionMarketplaceManager(marketplaces)

	emptyMarketplaces, err := controller.ExtensionMarketplaces()
	if err != nil {
		t.Fatal(err)
	}
	sourcePreview, err := controller.PreviewExtensionMarketplaceAdd(ctx, fixture.server.URL+"/index.json", "")
	if err != nil {
		t.Fatal(err)
	}
	marketplaceView, err := controller.AddExtensionMarketplaceExpected(
		ctx,
		emptyMarketplaces.Revision,
		fixture.server.URL+"/index.json",
		"",
		sourcePreview.SnapshotDigest,
	)
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	candidate, err := controller.PreviewMarketplaceExtensionInstall(
		ctx,
		"io.example.marketplace",
		"io.example.fixture",
		marketplaceView.Revision,
		moduleView.Revision,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(moduleView.Modules) != 0 || !validSHA256(candidate.SnapshotDigest) {
		t.Fatalf("install preview changed modules or lacked proof: modules=%+v candidate=%+v", moduleView.Modules, candidate)
	}

	fixture.mu.Lock()
	originalManifest := fixture.manifest
	fixture.manifest = strings.Replace(fixture.manifest, "version: 1.0.0", "version: 1.0.1", 1)
	fixture.mu.Unlock()
	if _, err := controller.InstallMarketplaceExtensionExpected(
		ctx,
		"io.example.marketplace",
		"io.example.fixture",
		marketplaceView.Revision,
		moduleView.Revision,
		marketplaceView.Sources[0].SnapshotDigest,
		candidate.SnapshotDigest,
	); !errors.Is(err, errMarketplaceIntegrity) {
		t.Fatalf("changed marketplace candidate error = %v", err)
	}
	afterReject, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if afterReject.Revision != moduleView.Revision || len(afterReject.Modules) != 0 {
		t.Fatalf("rejected install changed modules: before=%+v after=%+v", moduleView, afterReject)
	}

	fixture.mu.Lock()
	fixture.manifest = originalManifest
	fixture.mu.Unlock()
	candidate, err = controller.PreviewMarketplaceExtensionInstall(
		ctx,
		"io.example.marketplace",
		"io.example.fixture",
		marketplaceView.Revision,
		moduleView.Revision,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := controller.InstallMarketplaceExtensionExpected(
		ctx,
		"io.example.marketplace",
		"io.example.fixture",
		marketplaceView.Revision,
		moduleView.Revision,
		strings.Repeat("f", 64),
		candidate.SnapshotDigest,
	); !errors.Is(err, errMarketplaceRevision) {
		t.Fatalf("wrong source proof error = %v", err)
	}
	applied, err := controller.InstallMarketplaceExtensionExpected(
		ctx,
		"io.example.marketplace",
		"io.example.fixture",
		marketplaceView.Revision,
		moduleView.Revision,
		marketplaceView.Sources[0].SnapshotDigest,
		candidate.SnapshotDigest,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(applied.Modules) != 1 || applied.Modules[0].Enabled {
		t.Fatalf("installed modules = %+v", applied.Modules)
	}
}

func TestMarketplaceInstallHoldsReviewedSourceThroughModuleCommit(t *testing.T) {
	ctx := context.Background()
	fixture := newMarketplaceFixture(t, nil)
	marketplaces, modules, _ := newMarketplaceManagerFixture(t, fixture)
	controller := NewController(func() error { return nil }, nil, nil, nil)
	controller.SetInterceptModuleManager(modules)
	controller.SetExtensionMarketplaceManager(marketplaces)

	empty, err := controller.ExtensionMarketplaces()
	if err != nil {
		t.Fatal(err)
	}
	preview, err := controller.PreviewExtensionMarketplaceAdd(ctx, fixture.server.URL+"/index.json", "")
	if err != nil {
		t.Fatal(err)
	}
	market, err := controller.AddExtensionMarketplaceExpected(
		ctx, empty.Revision, fixture.server.URL+"/index.json", "", preview.SnapshotDigest,
	)
	if err != nil {
		t.Fatal(err)
	}
	moduleView, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	candidate, err := controller.PreviewMarketplaceExtensionInstall(
		ctx,
		market.Sources[0].ID,
		market.Sources[0].Entries[0].ID,
		market.Revision,
		moduleView.Revision,
	)
	if err != nil {
		t.Fatal(err)
	}

	blocker := blockingInterceptConfigTester{entered: make(chan struct{}), release: make(chan struct{})}
	modules.SetSidecarTester(blocker)
	installDone := make(chan error, 1)
	go func() {
		_, installErr := controller.InstallMarketplaceExtensionExpected(
			ctx,
			market.Sources[0].ID,
			market.Sources[0].Entries[0].ID,
			market.Revision,
			moduleView.Revision,
			market.Sources[0].SnapshotDigest,
			candidate.SnapshotDigest,
		)
		installDone <- installErr
	}()

	select {
	case <-blocker.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("module commit did not reach the blocking validator")
	}

	deleteDone := make(chan error, 1)
	deleteStarted := make(chan struct{})
	go func() {
		close(deleteStarted)
		_, deleteErr := controller.DeleteExtensionMarketplace(ctx, market.Sources[0].ID, market.Revision)
		deleteDone <- deleteErr
	}()
	<-deleteStarted
	select {
	case err := <-deleteDone:
		t.Fatalf("marketplace source changed inside the reviewed module commit window: %v", err)
	case <-time.After(100 * time.Millisecond):
	}

	close(blocker.release)
	if err := <-installDone; err != nil {
		t.Fatal(err)
	}
	if err := <-deleteDone; err != nil {
		t.Fatal(err)
	}
	installed, err := controller.InterceptModules()
	if err != nil {
		t.Fatal(err)
	}
	if len(installed.Modules) != 1 || installed.Modules[0].SnapshotDigest != candidate.SnapshotDigest {
		t.Fatalf("installed modules = %+v", installed.Modules)
	}
}
