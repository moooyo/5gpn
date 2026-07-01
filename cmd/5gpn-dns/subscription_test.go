package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// countingReload returns a reload func() error that increments a counter
// each time it is invoked, plus a getter for the current count.
func countingReload() (reload func() error, count func() int) {
	var mu sync.Mutex
	n := 0
	reload = func() error {
		mu.Lock()
		n++
		mu.Unlock()
		return nil
	}
	count = func() int {
		mu.Lock()
		defer mu.Unlock()
		return n
	}
	return reload, count
}

// ---------------------------------------------------------------------------
// LoadSubscriptions
// ---------------------------------------------------------------------------

func TestLoadSubscriptionsGoodJSON(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "subscriptions.json")
	body := `{"subscriptions":[
		{"id":"gfwlist","category":"blacklist","name":"gfwlist","url":"https://example.com/gfwlist.txt","format":"gfwlist","enabled":true,"interval":"24h"}
	]}`
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	subs, err := LoadSubscriptions(p)
	if err != nil {
		t.Fatalf("LoadSubscriptions: %v", err)
	}
	if len(subs) != 1 {
		t.Fatalf("want 1 subscription, got %d", len(subs))
	}
	s := subs[0]
	if s.ID != "gfwlist" || s.Category != "blacklist" || s.Name != "gfwlist" ||
		s.URL != "https://example.com/gfwlist.txt" || s.Format != "gfwlist" || !s.Enabled {
		t.Errorf("unexpected subscription fields: %+v", s)
	}
	if s.Interval != 24*time.Hour {
		t.Errorf("want Interval 24h, got %v", s.Interval)
	}
}

func TestLoadSubscriptionsMissingFile(t *testing.T) {
	subs, err := LoadSubscriptions(filepath.Join(t.TempDir(), "does-not-exist.json"))
	if err != nil {
		t.Fatalf("missing file must not error, got: %v", err)
	}
	if subs != nil {
		t.Errorf("missing file: want nil slice, got %+v", subs)
	}
}

func TestLoadSubscriptionsBadJSON(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "subscriptions.json")
	if err := os.WriteFile(p, []byte("{not valid json"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := LoadSubscriptions(p)
	if err == nil {
		t.Fatal("bad JSON: want error, got nil")
	}
}

// ---------------------------------------------------------------------------
// UpdateOne — success path
// ---------------------------------------------------------------------------

func TestUpdateOneSuccessWritesCacheAndReloads(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\nb.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, count := countingReload()

	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{
		ID: "blk1", Category: "blacklist", Name: "blk1",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}

	if count() != 1 {
		t.Fatalf("want reload called once after Add (which UpdateOne's), got %d", count())
	}

	cachePath := filepath.Join(rulesDir, "blacklist", "blk1.txt")
	data, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatalf("cache file not written: %v", err)
	}
	content := string(data)
	if !strings.Contains(content, "a.com") || !strings.Contains(content, "b.com") {
		t.Errorf("cache content missing expected domains: %q", content)
	}

	res := m.UpdateOne(context.Background(), "blk1")
	if !res.OK {
		t.Errorf("want OK true, got false (err=%s)", res.Err)
	}
	if res.Entries != 2 {
		t.Errorf("want Entries 2, got %d", res.Entries)
	}
	if res.ID != "blk1" {
		t.Errorf("want ID blk1, got %s", res.ID)
	}

	if count() != 2 {
		t.Errorf("want reload called twice total, got %d", count())
	}

	// No .tmp files left behind.
	assertNoTmpFiles(t, rulesDir)
}

// ---------------------------------------------------------------------------
// UpdateOne — keep-old-on-failure (HTTP 500)
// ---------------------------------------------------------------------------

func TestUpdateOneKeepsOldCacheOn500(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	catDir := filepath.Join(rulesDir, "blacklist")
	if err := os.MkdirAll(catDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cachePath := filepath.Join(catDir, "blk1.txt")
	const oldContent = "old.example.com\n"
	if err := os.WriteFile(cachePath, []byte(oldContent), 0o644); err != nil {
		t.Fatal(err)
	}

	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, count := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{{
		ID: "blk1", Category: "blacklist", Name: "blk1",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}}

	res := m.UpdateOne(context.Background(), "blk1")
	if res.OK {
		t.Error("want OK false for HTTP 500")
	}
	if res.Err == "" {
		t.Error("want non-empty Err for HTTP 500")
	}
	if count() != 0 {
		t.Errorf("reload must NOT be called on failure, got count=%d", count())
	}

	data, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatalf("cache file must remain: %v", err)
	}
	if string(data) != oldContent {
		t.Errorf("cache content must be unchanged, got %q want %q", string(data), oldContent)
	}

	assertNoTmpFiles(t, rulesDir)
}

// ---------------------------------------------------------------------------
// UpdateOne — keep-old-on-failure (under floor guard)
// ---------------------------------------------------------------------------

func TestUpdateOneKeepsOldCacheUnderDomainFloor(t *testing.T) {
	// Domain floor is 1: a body that parses to 0 entries must be treated as failure.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("# only a comment\n\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	catDir := filepath.Join(rulesDir, "blacklist")
	if err := os.MkdirAll(catDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cachePath := filepath.Join(catDir, "blk1.txt")
	const oldContent = "old.example.com\n"
	if err := os.WriteFile(cachePath, []byte(oldContent), 0o644); err != nil {
		t.Fatal(err)
	}

	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, count := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{{
		ID: "blk1", Category: "blacklist", Name: "blk1",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}}

	res := m.UpdateOne(context.Background(), "blk1")
	if res.OK {
		t.Error("want OK false when entries fall below the floor guard")
	}
	if count() != 0 {
		t.Errorf("reload must NOT be called when under floor, got count=%d", count())
	}
	data, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatalf("cache file must remain: %v", err)
	}
	if string(data) != oldContent {
		t.Errorf("cache content must be unchanged, got %q", string(data))
	}
}

func TestUpdateOneKeepsOldCacheUnderChnrouteFloor(t *testing.T) {
	// Chnroute floor is 100: a body with fewer valid CIDRs must be treated as failure.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("1.0.0.0/8\n2.0.0.0/8\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	catDir := filepath.Join(rulesDir, "chnroute")
	if err := os.MkdirAll(catDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cachePath := filepath.Join(catDir, "cn.txt")
	const oldContent = "3.0.0.0/8\n"
	if err := os.WriteFile(cachePath, []byte(oldContent), 0o644); err != nil {
		t.Fatal(err)
	}

	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, count := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{{
		ID: "cn", Category: "chnroute", Name: "cn",
		URL: srv.URL, Format: "cidr", Enabled: true, Interval: time.Hour,
	}}

	res := m.UpdateOne(context.Background(), "cn")
	if res.OK {
		t.Error("want OK false when CIDR entries fall below the chnroute floor (100)")
	}
	if count() != 0 {
		t.Errorf("reload must NOT be called when under floor, got count=%d", count())
	}
	data, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatalf("cache file must remain: %v", err)
	}
	if string(data) != oldContent {
		t.Errorf("cache content must be unchanged, got %q", string(data))
	}
}

// ---------------------------------------------------------------------------
// Add / Remove
// ---------------------------------------------------------------------------

func TestAddPersistsAndCaches(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}

	sub := Subscription{
		ID: "s1", Category: "direct", Name: "s1",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}
	res, err := m.Add(sub)
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if !res.OK {
		t.Errorf("Add result OK = false, want true; err=%s", res.Err)
	}
	if res.ID != "s1" {
		t.Errorf("Add result ID = %q, want %q", res.ID, "s1")
	}
	if res.Entries != 1 {
		t.Errorf("Add result Entries = %d, want 1", res.Entries)
	}

	// Re-load from disk to verify persistence.
	reloaded, err := LoadSubscriptions(subPath)
	if err != nil {
		t.Fatalf("LoadSubscriptions after Add: %v", err)
	}
	if len(reloaded) != 1 || reloaded[0].ID != "s1" {
		t.Fatalf("persisted subscriptions unexpected: %+v", reloaded)
	}
	if reloaded[0].Interval != time.Hour {
		t.Errorf("want persisted Interval 1h, got %v", reloaded[0].Interval)
	}

	cachePath := filepath.Join(rulesDir, "direct", "s1.txt")
	if _, err := os.Stat(cachePath); err != nil {
		t.Errorf("cache file not created by Add: %v", err)
	}

	assertNoTmpFiles(t, rulesDir)
	assertNoTmpFiles(t, filepath.Dir(subPath))
}

func TestAddRejectsDuplicateID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{ID: "dup", Category: "direct", Name: "dup", URL: srv.URL, Format: "plain", Enabled: false, Interval: time.Hour}
	// Add's initial fetch is best-effort (does not fail Add), so this succeeds
	// regardless of Enabled.
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("first Add: %v", err)
	}
	if _, err := m.Add(sub); err == nil {
		t.Fatal("want error adding duplicate ID, got nil")
	}
}

func TestAddRejectsInvalidCategory(t *testing.T) {
	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{ID: "bad", Category: "not-a-category", Name: "bad", URL: "https://example.com/x", Format: "plain", Enabled: false, Interval: time.Hour}
	if _, err := m.Add(sub); err == nil {
		t.Fatal("want error for invalid category, got nil")
	}
}

func TestAddRejectsNonHTTPURLScheme(t *testing.T) {
	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}

	badURLs := []string{
		"file:///etc/passwd",
		"ftp://example.com/list.txt",
		"not-a-url-at-all",
	}
	for _, url := range badURLs {
		t.Run(url, func(t *testing.T) {
			sub := Subscription{
				ID: "scheme-" + url, Category: "direct", Name: "scheme-" + t.Name(),
				URL: url, Format: "plain", Enabled: false, Interval: time.Hour,
			}
			if _, err := m.Add(sub); err == nil {
				t.Fatalf("want error adding subscription with URL %q, got nil", url)
			}
		})
	}
}

func TestAddRejectsPathTraversalName(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	badNames := []string{
		"../../evil",
		"a/b",
		"..",
		"../evil",
		`a\b`,
	}

	for _, name := range badNames {
		t.Run(name, func(t *testing.T) {
			parent := t.TempDir()
			rulesDir := filepath.Join(parent, "rules")
			subPath := filepath.Join(t.TempDir(), "subscriptions.json")
			reload, _ := countingReload()
			m, err := NewSubManager(subPath, rulesDir, reload)
			if err != nil {
				t.Fatalf("NewSubManager: %v", err)
			}
			sub := Subscription{
				ID: "bad-" + t.Name(), Category: "blacklist", Name: name,
				URL: srv.URL, Format: "plain", Enabled: false, Interval: time.Hour,
			}
			if _, err := m.Add(sub); err == nil {
				t.Fatalf("want error adding subscription with Name %q, got nil", name)
			}

			// No file must have been written anywhere outside rulesDir, and in
			// particular not in rulesDir's parent (where "../evil.txt" etc. would
			// land).
			assertNoStrayFiles(t, parent, "evil")
		})
	}
}

func TestAddAcceptsValidName(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{
		ID: "gfw", Category: "blacklist", Name: "gfwlist",
		URL: srv.URL, Format: "plain", Enabled: false, Interval: time.Hour,
	}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add with valid name: want nil error, got %v", err)
	}

	cachePath := filepath.Join(rulesDir, "blacklist", "gfwlist.txt")
	if _, err := os.Stat(cachePath); err != nil {
		t.Errorf("cache file not created for valid name: %v", err)
	}
}

func TestRemoveDeletesCacheAndJSONEntry(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, count := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{
		ID: "rm1", Category: "adblock", Name: "rm1",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}
	cachePath := filepath.Join(rulesDir, "adblock", "rm1.txt")
	if _, err := os.Stat(cachePath); err != nil {
		t.Fatalf("precondition: cache file must exist: %v", err)
	}
	beforeRemove := count()

	if err := m.Remove("rm1"); err != nil {
		t.Fatalf("Remove: %v", err)
	}

	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Errorf("cache file must be deleted by Remove, stat err=%v", err)
	}
	reloaded, err := LoadSubscriptions(subPath)
	if err != nil {
		t.Fatalf("LoadSubscriptions after Remove: %v", err)
	}
	for _, s := range reloaded {
		if s.ID == "rm1" {
			t.Fatal("removed subscription still present in persisted JSON")
		}
	}
	if count() <= beforeRemove {
		t.Error("want reload called by Remove")
	}
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

func TestListReturnsSubscriptions(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{ID: "l1", Category: "direct", Name: "l1", URL: srv.URL, Format: "plain", Enabled: false, Interval: time.Hour}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}
	list := m.List()
	if len(list) != 1 || list[0].ID != "l1" {
		t.Fatalf("List: unexpected result %+v", list)
	}
}

// ---------------------------------------------------------------------------
// UpdateAll
// ---------------------------------------------------------------------------

func TestUpdateAllUpdatesEveryEnabledSubscription(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\nb.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{
		{ID: "u1", Category: "direct", Name: "u1", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour},
		{ID: "u2", Category: "adblock", Name: "u2", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour},
	}

	results := m.UpdateAll(context.Background())
	if len(results) != 2 {
		t.Fatalf("want 2 results, got %d", len(results))
	}
	for _, r := range results {
		if !r.OK {
			t.Errorf("result for %s: want OK, got Err=%s", r.ID, r.Err)
		}
	}
}

// ---------------------------------------------------------------------------
// Interval JSON round-trip via persisted file content
// ---------------------------------------------------------------------------

func TestPersistedJSONHasHumanReadableInterval(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{ID: "j1", Category: "direct", Name: "j1", URL: srv.URL, Format: "plain", Enabled: false, Interval: 24 * time.Hour}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}

	raw, err := os.ReadFile(subPath)
	if err != nil {
		t.Fatalf("read persisted json: %v", err)
	}
	var doc struct {
		Subscriptions []map[string]json.RawMessage `json:"subscriptions"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("unmarshal persisted json: %v", err)
	}
	if len(doc.Subscriptions) != 1 {
		t.Fatalf("want 1 persisted subscription, got %d", len(doc.Subscriptions))
	}
	intervalRaw := string(doc.Subscriptions[0]["interval"])
	if intervalRaw != `"24h0m0s"` && intervalRaw != `"24h"` {
		t.Errorf("want interval persisted as human-readable duration string, got %s", intervalRaw)
	}
}

// ---------------------------------------------------------------------------
// Run: initial UpdateOne when cache missing, none when cache present
// ---------------------------------------------------------------------------

func TestRunPerformsInitialUpdateWhenCacheMissing(t *testing.T) {
	var hits int32
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits++
		mu.Unlock()
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{
		{ID: "run1", Category: "direct", Name: "run1", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	done := make(chan struct{})
	go func() {
		m.Run(ctx)
		close(done)
	}()

	// Wait for the initial fetch (cache was missing) to happen, then let ctx expire.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		h := hits
		mu.Unlock()
		if h >= 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	<-done

	mu.Lock()
	h := hits
	mu.Unlock()
	if h < 1 {
		t.Error("want at least one fetch when cache file is missing at Run startup")
	}

	cachePath := filepath.Join(rulesDir, "direct", "run1.txt")
	if _, err := os.Stat(cachePath); err != nil {
		t.Errorf("want cache file created by initial Run update: %v", err)
	}
}

func TestRunSkipsInitialUpdateWhenCachePresent(t *testing.T) {
	var hits int32
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits++
		mu.Unlock()
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	catDir := filepath.Join(rulesDir, "direct")
	if err := os.MkdirAll(catDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(catDir, "run2.txt"), []byte("existing.com\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	// Long interval so the ticker itself won't fire during the test window.
	m.subs = []Subscription{
		{ID: "run2", Category: "direct", Name: "run2", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	done := make(chan struct{})
	go func() {
		m.Run(ctx)
		close(done)
	}()
	<-done

	mu.Lock()
	h := hits
	mu.Unlock()
	if h != 0 {
		t.Errorf("want no fetch when cache already present at Run startup, got %d hits", h)
	}
}

// ---------------------------------------------------------------------------
// Live reschedule: Add while Run is active starts a ticker for the new sub
// ---------------------------------------------------------------------------

func TestAddWhileRunActiveGetsLiveReschedule(t *testing.T) {
	var hits int32
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits++
		mu.Unlock()
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	done := make(chan struct{})
	go func() {
		m.Run(ctx)
		close(done)
	}()

	// Give Run a moment to start (it has nothing to do yet — no subs configured).
	time.Sleep(50 * time.Millisecond)

	sub := Subscription{
		ID: "live1", Category: "direct", Name: "live1",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: 100 * time.Millisecond,
	}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}

	// Add's own initial fetch accounts for hit #1. Wait for a SECOND fetch to
	// prove a ticker was launched for the live-added subscription (not just
	// the one-shot initial fetch inside Add).
	deadline := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(deadline) {
		mu.Lock()
		h := hits
		mu.Unlock()
		if h >= 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	cancel()
	<-done

	mu.Lock()
	h := hits
	mu.Unlock()
	if h < 2 {
		t.Errorf("want >=2 fetches (initial Add fetch + at least one ticker fetch) for a subscription added while Run is active, got %d", h)
	}
}

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------

func TestHealthRecordedAfterSuccessfulAdd(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\nb.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{
		ID: "h1", Category: "direct", Name: "h1",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}

	health := m.Health()
	h, ok := health["h1"]
	if !ok {
		t.Fatalf("want health entry for h1, got none: %+v", health)
	}
	if !h.OK {
		t.Errorf("want OK true, got false (err=%s)", h.Err)
	}
	if h.Entries != 2 {
		t.Errorf("want Entries 2, got %d", h.Entries)
	}
	if h.Err != "" {
		t.Errorf("want empty Err on success, got %q", h.Err)
	}
	if h.At == "" {
		t.Error("want non-empty At timestamp")
	}
	if _, err := time.Parse(time.RFC3339, h.At); err != nil {
		t.Errorf("At = %q is not RFC3339: %v", h.At, err)
	}
}

func TestHealthRecordedAfterFailedFetch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{{
		ID: "h2", Category: "blacklist", Name: "h2",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}}

	res := m.UpdateOne(context.Background(), "h2")
	if res.OK {
		t.Fatal("precondition: fetch must fail (HTTP 500)")
	}

	health := m.Health()
	h, ok := health["h2"]
	if !ok {
		t.Fatalf("want health entry for h2 even on failure, got none: %+v", health)
	}
	if h.OK {
		t.Error("want OK false for failed fetch")
	}
	if h.Err == "" {
		t.Error("want non-empty Err for failed fetch")
	}
	if h.At == "" {
		t.Error("want non-empty At timestamp even on failure")
	}
}

func TestHealthAbsentForNeverUpdatedSubscription(t *testing.T) {
	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{{
		ID: "never", Category: "direct", Name: "never",
		URL: "https://example.invalid/x", Format: "plain", Enabled: false, Interval: time.Hour,
	}}

	health := m.Health()
	if _, ok := health["never"]; ok {
		t.Errorf("want no health entry for a subscription that was never updated, got %+v", health["never"])
	}
}

func TestHealthReturnsCopyNotInternalMap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{ID: "copy1", Category: "direct", Name: "copy1", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}

	health := m.Health()
	health["copy1"] = SubHealth{At: "tampered", OK: false, Entries: -1, Err: "tampered"}

	health2 := m.Health()
	if health2["copy1"].At == "tampered" {
		t.Error("Health() must return a copy: mutating the returned map affected the manager's internal state")
	}
}

func TestUpdateAllRecordsHealthForEverySubscription(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("a.com\nb.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	m.subs = []Subscription{
		{ID: "ua1", Category: "direct", Name: "ua1", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour},
		{ID: "ua2", Category: "adblock", Name: "ua2", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour},
	}

	m.UpdateAll(context.Background())

	health := m.Health()
	if _, ok := health["ua1"]; !ok {
		t.Error("want health for ua1 after UpdateAll")
	}
	if _, ok := health["ua2"]; !ok {
		t.Error("want health for ua2 after UpdateAll")
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// assertNoStrayFiles walks dir and fails the test if any file whose name
// contains substr is found. Used to prove a rejected path-traversal Name
// never resulted in a write outside the intended rules directory.
func assertNoStrayFiles(t *testing.T, dir, substr string) {
	t.Helper()
	filepathWalk(t, dir, func(path string) {
		if strings.Contains(filepath.Base(path), substr) {
			t.Errorf("stray file matching %q must not exist: %s", substr, path)
		}
	})
}

// assertNoTmpFiles walks dir and fails the test if any *.tmp file is found,
// proving atomic-write cleanliness (temp files are always renamed away).
func assertNoTmpFiles(t *testing.T, dir string) {
	t.Helper()
	filepathWalk(t, dir, func(path string) {
		if strings.HasSuffix(path, ".tmp") {
			t.Errorf("leftover tmp file: %s", path)
		}
	})
}

func filepathWalk(t *testing.T, dir string, fn func(path string)) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return
		}
		t.Fatalf("readdir %s: %v", dir, err)
	}
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		if e.IsDir() {
			filepathWalk(t, p, fn)
			continue
		}
		fn(p)
	}
}
