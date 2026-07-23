package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestInterceptHealthProjectionCacheHitAvoidsDiskReadAndParse(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	store := writeInterceptHealthStore(t, true, module)

	for attempt := 0; attempt < 2; attempt++ {
		projection, err := store.HealthProjection()
		if err != nil {
			t.Fatal(err)
		}
		if projection != (interceptHealthProjection{InstalledPlugins: 1, ActivePlugins: 1}) {
			t.Fatalf("health projection = %+v", projection)
		}
	}
	reads, parses := interceptHealthCacheCounts(store)
	if reads != 1 || parses != 1 {
		t.Fatalf("unchanged health cache reads/parses = %d/%d, want 1/1", reads, parses)
	}
}

func TestInterceptHealthProjectionMissingFileFailsClosedAndRecovers(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	document, body := testInterceptDocument(t, module)
	document.MITM.Enabled = true
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	store := NewInterceptConfigStore(path)
	if _, err := store.HealthProjection(); err == nil {
		t.Fatal("missing interception config returned a health projection")
	}

	baseTime := time.Now().Add(-time.Minute).Truncate(time.Second)
	writeInterceptHealthConfigAt(t, path, body, baseTime)
	projection, err := store.HealthProjection()
	if err != nil || projection.ActivePlugins != 1 {
		t.Fatalf("created projection = %+v err=%v", projection, err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := store.HealthProjection(); err == nil {
		t.Fatal("removed interception config reused the cached projection")
	}

	writeInterceptHealthConfigAt(t, path, body, baseTime.Add(time.Second))
	projection, err = store.HealthProjection()
	if err != nil || projection.ActivePlugins != 1 {
		t.Fatalf("repaired missing projection = %+v err=%v", projection, err)
	}
}

func TestInterceptHealthProjectionNonRegularFileFailsClosedAndRecovers(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	document, body := testInterceptDocument(t, module)
	document.MITM.Enabled = true
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	baseTime := time.Now().Add(-time.Minute).Truncate(time.Second)
	writeInterceptHealthConfigAt(t, path, body, baseTime)
	store := NewInterceptConfigStore(path)
	if _, err := store.HealthProjection(); err != nil {
		t.Fatal(err)
	}

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := store.HealthProjection(); err == nil {
		t.Fatal("non-regular interception config reused the cached projection")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	writeInterceptHealthConfigAt(t, path, body, baseTime.Add(time.Second))
	projection, err := store.HealthProjection()
	if err != nil || projection.ActivePlugins != 1 {
		t.Fatalf("repaired non-regular projection = %+v err=%v", projection, err)
	}
}

func TestInterceptHealthProjectionOversizeNegativeCacheAndRecovery(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	baseTime := time.Now().Add(-time.Minute).Truncate(time.Second)
	writeInterceptHealthConfigAt(t, path, make([]byte, maxInterceptConfigBytes+1), baseTime)
	store := NewInterceptConfigStore(path)
	for attempt := 0; attempt < 2; attempt++ {
		if _, err := store.HealthProjection(); err == nil {
			t.Fatal("oversized interception config returned a health projection")
		}
	}
	store.healthMu.Lock()
	negativeCached := store.healthCache.valid && store.healthCache.info != nil && store.healthCache.err != nil
	reads, parses := store.healthReads, store.healthParses
	store.healthMu.Unlock()
	if !negativeCached || reads != 0 || parses != 0 {
		t.Fatalf("oversize negative cache valid=%t reads/parses=%d/%d", negativeCached, reads, parses)
	}

	module := testModuleSnapshot()
	module.Enabled = true
	document, body := testInterceptDocument(t, module)
	document.MITM.Enabled = true
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	replaceInterceptHealthConfigAt(t, path, body, baseTime)
	projection, err := store.HealthProjection()
	if err != nil || projection.ActivePlugins != 1 {
		t.Fatalf("repaired oversized projection = %+v err=%v", projection, err)
	}
	reads, parses = interceptHealthCacheCounts(store)
	if reads != 1 || parses != 1 {
		t.Fatalf("oversize recovery reads/parses=%d/%d, want 1/1", reads, parses)
	}
}

func TestInterceptHealthProjectionReusesValidatedIdenticalReplacement(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	document, body := testInterceptDocument(t, module)
	document.MITM.Enabled = true
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	baseTime := time.Now().Add(-time.Minute).Truncate(time.Second)
	writeInterceptHealthConfigAt(t, path, body, baseTime)
	store := NewInterceptConfigStore(path)
	if _, err := store.HealthProjection(); err != nil {
		t.Fatal(err)
	}
	initialInfo := pinnedInterceptHealthFileInfo(t, path)

	replaceInterceptHealthConfigAt(t, path, body, baseTime)
	replacementInfo := pinnedInterceptHealthFileInfo(t, path)
	assertInterceptHealthReplacementMetadata(t, initialInfo, replacementInfo)
	projection, err := store.HealthProjection()
	if err != nil {
		t.Fatal(err)
	}
	if projection.ActivePlugins != 1 {
		t.Fatalf("identical replacement projection = %+v", projection)
	}
	reads, parses := interceptHealthCacheCounts(store)
	if reads != 2 || parses != 1 {
		t.Fatalf("identical replacement reads/parses = %d/%d, want 2/1", reads, parses)
	}
}

func TestInterceptHealthProjectionReloadsSameMetadataNewIdentity(t *testing.T) {
	module := testModuleSnapshot()
	document, oldBody := testInterceptDocument(t, module)
	document.MITM.Enabled = true
	oldBody, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	module.Enabled = true
	document, newBody := testInterceptDocument(t, module)
	document.MITM.Enabled = true
	newBody, err = marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	oldBody, newBody = equalLengthInterceptHealthBodies(oldBody, newBody)

	path := filepath.Join(t.TempDir(), "config.json")
	baseTime := time.Now().Add(-time.Minute).Truncate(time.Second)
	writeInterceptHealthConfigAt(t, path, oldBody, baseTime)
	store := NewInterceptConfigStore(path)
	initial, err := store.HealthProjection()
	if err != nil || initial.ActivePlugins != 0 {
		t.Fatalf("initial projection = %+v err=%v", initial, err)
	}
	initialInfo := pinnedInterceptHealthFileInfo(t, path)

	replaceInterceptHealthConfigAt(t, path, newBody, baseTime)
	replacementInfo := pinnedInterceptHealthFileInfo(t, path)
	assertInterceptHealthReplacementMetadata(t, initialInfo, replacementInfo)
	reloaded, err := store.HealthProjection()
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.ActivePlugins != 1 {
		t.Fatalf("changed replacement projection = %+v", reloaded)
	}
	reads, parses := interceptHealthCacheCounts(store)
	if reads != 2 || parses != 2 {
		t.Fatalf("changed replacement reads/parses = %d/%d, want 2/2", reads, parses)
	}
}

func TestInterceptHealthProjectionReloadsChangedContentOnSameFile(t *testing.T) {
	module := testModuleSnapshot()
	document, oldBody := testInterceptDocument(t, module)
	document.MITM.Enabled = true
	oldBody, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	module.Enabled = true
	document, newBody := testInterceptDocument(t, module)
	document.MITM.Enabled = true
	newBody, err = marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(t.TempDir(), "config.json")
	baseTime := time.Now().Add(-time.Minute).Truncate(time.Second)
	writeInterceptHealthConfigAt(t, path, oldBody, baseTime)
	store := NewInterceptConfigStore(path)
	if _, err := store.HealthProjection(); err != nil {
		t.Fatal(err)
	}
	initialInfo := pinnedInterceptHealthFileInfo(t, path)
	writeInterceptHealthConfigAt(t, path, newBody, baseTime.Add(2*time.Second))
	changedInfo := pinnedInterceptHealthFileInfo(t, path)
	if !os.SameFile(initialInfo, changedInfo) {
		t.Fatal("in-place health config update changed file identity")
	}

	projection, err := store.HealthProjection()
	if err != nil {
		t.Fatal(err)
	}
	if projection.ActivePlugins != 1 {
		t.Fatalf("in-place content projection = %+v", projection)
	}
	reads, parses := interceptHealthCacheCounts(store)
	if reads != 2 || parses != 2 {
		t.Fatalf("in-place content reads/parses = %d/%d, want 2/2", reads, parses)
	}
}

func TestInterceptHealthProjectionInvalidReplacementFailsClosed(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	store := writeInterceptHealthStore(t, true, module)
	if _, err := store.HealthProjection(); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(store.Path)
	if err != nil {
		t.Fatal(err)
	}
	invalid := append([]byte(nil), body...)
	invalid[0] = '!'
	info := pinnedInterceptHealthFileInfo(t, store.Path)
	replaceInterceptHealthConfigAt(t, store.Path, invalid, info.ModTime())

	var probes atomic.Int32
	server := &ControlServer{
		interceptStore: store,
		interceptLogs: &interceptLogUpstream{healthClient: interceptLogDoerFunc(func(*http.Request) (*http.Response, error) {
			probes.Add(1)
			return nil, fmt.Errorf("invalid config must not probe the sidecar")
		})},
	}
	for attempt := 0; attempt < 2; attempt++ {
		recorder := httptest.NewRecorder()
		server.handleInterceptHealth(recorder, httptest.NewRequest(http.MethodGet, "/api/intercept/health", nil))
		if recorder.Code != http.StatusServiceUnavailable {
			t.Fatalf("invalid replacement health status=%d body=%s", recorder.Code, recorder.Body.String())
		}
	}
	if probes.Load() != 0 {
		t.Fatalf("invalid replacement sidecar probes = %d", probes.Load())
	}
	reads, parses := interceptHealthCacheCounts(store)
	if reads != 2 || parses != 2 {
		t.Fatalf("negative cache reads/parses = %d/%d, want 2/2", reads, parses)
	}

	replaceInterceptHealthConfigAt(t, store.Path, body, info.ModTime())
	projection, err := store.HealthProjection()
	if err != nil || projection.ActivePlugins != 1 {
		t.Fatalf("repaired projection = %+v err=%v", projection, err)
	}
}

func TestInterceptHealthProjectionTransactionInvalidationIsPrecise(t *testing.T) {
	manager, _, _, _, _ := newInterceptManagerFixture(t, testModuleSnapshot())
	store := manager.store
	if _, err := store.HealthProjection(); err != nil {
		t.Fatal(err)
	}
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}

	view, err = manager.UpdateSettings(context.Background(), view.Revision, interceptMITMSettings{
		Enabled: true, HTTP2: true, QUICFallbackProtection: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.HealthProjection(); err != nil {
		t.Fatal(err)
	}
	reads, parses := interceptHealthCacheCounts(store)
	if reads != 1 || parses != 1 {
		t.Fatalf("no-op transaction invalidated health cache: reads/parses=%d/%d", reads, parses)
	}

	if _, err := manager.UpdateSettings(context.Background(), view.Revision, interceptMITMSettings{
		Enabled: true, HTTP2: false, QUICFallbackProtection: true,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.HealthProjection(); err != nil {
		t.Fatal(err)
	}
	reads, parses = interceptHealthCacheCounts(store)
	if reads != 2 || parses != 2 {
		t.Fatalf("committed transaction did not invalidate health cache: reads/parses=%d/%d", reads, parses)
	}
}

func TestInterceptHealthProjectionConcurrentHealthAndMutation(t *testing.T) {
	manager, _, _, _, _ := newInterceptManagerFixture(t, testModuleSnapshot())
	server := &ControlServer{interceptStore: manager.store}
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}

	start := make(chan struct{})
	errorsFound := make(chan error, 1)
	var workers sync.WaitGroup
	for worker := 0; worker < 8; worker++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			for request := 0; request < 100; request++ {
				recorder := httptest.NewRecorder()
				server.handleInterceptHealth(recorder, httptest.NewRequest(http.MethodGet, "/api/intercept/health", nil))
				if recorder.Code != http.StatusOK {
					select {
					case errorsFound <- fmt.Errorf("concurrent health status=%d body=%s", recorder.Code, recorder.Body.String()):
					default:
					}
					return
				}
			}
		}()
	}
	close(start)
	for mutation := 0; mutation < 25; mutation++ {
		view, err = manager.UpdateSettings(context.Background(), view.Revision, interceptMITMSettings{
			Enabled: true, HTTP2: mutation%2 == 0, QUICFallbackProtection: true,
		})
		if err != nil {
			t.Fatalf("mutation %d: %v", mutation, err)
		}
	}
	workers.Wait()
	select {
	case err := <-errorsFound:
		t.Fatal(err)
	default:
	}
	projection, err := manager.store.HealthProjection()
	if err != nil {
		t.Fatal(err)
	}
	if projection != (interceptHealthProjection{InstalledPlugins: 1}) {
		t.Fatalf("final concurrent projection = %+v", projection)
	}
}

func BenchmarkInterceptHealthProjectionCacheHit(b *testing.B) {
	module := testModuleSnapshot()
	module.Enabled = true
	store := writeInterceptHealthStore(b, true, module)
	if _, err := store.HealthProjection(); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for index := 0; index < b.N; index++ {
		if _, err := store.HealthProjection(); err != nil {
			b.Fatal(err)
		}
	}
}

func interceptHealthCacheCounts(store *InterceptConfigStore) (uint64, uint64) {
	store.healthMu.Lock()
	defer store.healthMu.Unlock()
	return store.healthReads, store.healthParses
}

func writeInterceptHealthConfigAt(t testing.TB, path string, body []byte, modTime time.Time) {
	t.Helper()
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modTime, modTime); err != nil {
		t.Fatal(err)
	}
}

func replaceInterceptHealthConfigAt(t testing.TB, path string, body []byte, modTime time.Time) {
	t.Helper()
	replacement := filepath.Join(filepath.Dir(path), "health-replacement.json")
	writeInterceptHealthConfigAt(t, replacement, body, modTime)
	if err := os.Rename(replacement, path); err != nil {
		t.Fatal(err)
	}
}

func pinnedInterceptHealthFileInfo(t testing.TB, path string) os.FileInfo {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(info, info) {
		t.Fatal("could not pin health config file identity")
	}
	return info
}

func assertInterceptHealthReplacementMetadata(t testing.TB, oldInfo, replacementInfo os.FileInfo) {
	t.Helper()
	if os.SameFile(oldInfo, replacementInfo) || oldInfo.Size() != replacementInfo.Size() ||
		!oldInfo.ModTime().Equal(replacementInfo.ModTime()) {
		t.Fatal("replacement did not preserve size and mtime while changing file identity")
	}
}

func equalLengthInterceptHealthBodies(left, right []byte) ([]byte, []byte) {
	if len(left) < len(right) {
		left = append(left, make([]byte, len(right)-len(left))...)
	}
	if len(right) < len(left) {
		right = append(right, make([]byte, len(left)-len(right))...)
	}
	for index := range left {
		if left[index] == 0 {
			left[index] = ' '
		}
	}
	for index := range right {
		if right[index] == 0 {
			right[index] = ' '
		}
	}
	return left, right
}
