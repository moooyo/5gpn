package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

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

func newTestSubManager(t *testing.T, rulesDir string, reload func() error) *SubManager {
	t.Helper()
	m, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), rulesDir, reload, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	return m
}

func healthEntry(m *SubManager, id string) (SubHealth, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	h, ok := m.health[id]
	return h, ok
}

func waitFor(t *testing.T, within time.Duration, cond func() bool, message string) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", message)
}

func TestLoadSubscriptionsGoodJSON(t *testing.T) {
	p := filepath.Join(t.TempDir(), "subscriptions.json")
	body := `{"version":1,"subscriptions":[
		{"id":"gfwlist","category":"proxy","name":"gfwlist","url":"https://example.com/gfwlist.txt","format":"gfwlist","enabled":true,"interval":"24h"}
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
	if s.ID != "gfwlist" || s.Category != "proxy" || s.Name != "gfwlist" ||
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

func TestLoadSubscriptionsRejectsMalformedAndDuplicateEntries(t *testing.T) {
	tests := map[string]string{
		"bad JSON":             `{not valid json`,
		"duplicate ID":         `{"version":1,"subscriptions":[{"id":"dup","category":"direct","name":"a","url":"https://example.com/a","format":"plain","enabled":true,"interval":"1h"},{"id":"dup","category":"block","name":"b","url":"https://example.com/b","format":"plain","enabled":true,"interval":"1h"}]}`,
		"duplicate cache path": `{"version":1,"subscriptions":[{"id":"one","category":"direct","name":"shared","url":"https://example.com/a","format":"plain","enabled":true,"interval":"1h"},{"id":"two","category":"direct","name":"shared","url":"https://example.com/b","format":"hosts","enabled":true,"interval":"1h"}]}`,
		"invalid entry":        `{"version":1,"subscriptions":[{"id":"bad","category":"bogus","name":"bad","url":"https://example.com/a","format":"plain","enabled":true,"interval":"1h"}]}`,
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "subscriptions.json")
			if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
				t.Fatal(err)
			}
			if _, err := LoadSubscriptions(p); err == nil {
				t.Fatal("want error, got nil")
			}
		})
	}
}

func TestValidateSubscriptionCurrentSchema(t *testing.T) {
	base := Subscription{
		ID: "valid", Category: "direct", Name: "valid",
		URL: "https://example.com/list", Format: "plain", Enabled: true, Interval: time.Hour,
	}
	if err := validateSubscription(base); err != nil {
		t.Fatalf("valid subscription rejected: %v", err)
	}
	boundary := base
	boundary.ID = strings.Repeat("a", maxSubscriptionIDLen)
	boundary.Name = strings.Repeat("b", maxSubscriptionNameLen)
	if err := validateSubscription(boundary); err != nil {
		t.Fatalf("current-schema boundary rejected: %v", err)
	}
	chnroute := base
	chnroute.Category = "chnroute"
	chnroute.Format = "cidr"
	if err := validateSubscription(chnroute); err != nil {
		t.Fatalf("valid chnroute subscription rejected: %v", err)
	}
	disabled := base
	disabled.Enabled = false
	disabled.Interval = 0
	if err := validateSubscription(disabled); err != nil {
		t.Fatalf("disabled zero-interval subscription rejected: %v", err)
	}

	tests := map[string]Subscription{
		"empty id":             func() Subscription { s := base; s.ID = ""; return s }(),
		"long id":              func() Subscription { s := base; s.ID = strings.Repeat("a", maxSubscriptionIDLen+1); return s }(),
		"invalid category":     func() Subscription { s := base; s.Category = "bogus"; return s }(),
		"empty format":         func() Subscription { s := base; s.Format = ""; return s }(),
		"domain category cidr": func() Subscription { s := base; s.Format = "cidr"; return s }(),
		"chnroute domain format": func() Subscription {
			s := base
			s.Category = "chnroute"
			return s
		}(),
		"enabled zero interval": func() Subscription { s := base; s.Interval = 0; return s }(),
		"enabled negative interval": func() Subscription {
			s := base
			s.Interval = -time.Second
			return s
		}(),
		"non-http URL":       func() Subscription { s := base; s.URL = "file:///etc/passwd"; return s }(),
		"path traversal":     func() Subscription { s := base; s.Name = "../outside"; return s }(),
		"long cache name":    func() Subscription { s := base; s.Name = strings.Repeat("a", maxSubscriptionNameLen+1); return s }(),
		"missing URL scheme": func() Subscription { s := base; s.URL = "example.com/list"; return s }(),
	}
	for name, sub := range tests {
		t.Run(name, func(t *testing.T) {
			if err := validateSubscription(sub); err == nil {
				t.Fatalf("invalid subscription accepted: %+v", sub)
			}
		})
	}
}

func TestPreparePolicyGenerationRejectsDuplicateCachePaths(t *testing.T) {
	valid := func(id, category, name, format string) Subscription {
		return Subscription{
			ID: id, Category: category, Name: name,
			URL: "https://example.com/" + id, Format: format, Enabled: true, Interval: time.Hour,
		}
	}

	t.Run("desired set", func(t *testing.T) {
		m := newTestSubManager(t, t.TempDir(), func() error { return nil })
		_, err := m.PreparePolicyGeneration(context.Background(), []Subscription{
			valid("one", "block", "shared", "plain"),
			valid("two", "block", "shared", "hosts"),
		})
		if err == nil || !strings.Contains(err.Error(), "duplicate cache path") {
			t.Fatalf("duplicate desired cache path error = %v", err)
		}
	})

	t.Run("final set", func(t *testing.T) {
		m := newTestSubManager(t, t.TempDir(), func() error { return nil })
		m.subs = []Subscription{
			valid("cn-one", "chnroute", "shared", "cidr"),
			valid("cn-two", "chnroute", "shared", "cidr"),
		}
		_, err := m.PreparePolicyGeneration(context.Background(), nil)
		if err == nil || !strings.Contains(err.Error(), "final set: subscription: duplicate cache path") {
			t.Fatalf("duplicate final cache path error = %v", err)
		}
	})
}

func TestWriteSubscriptionsFileRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "subscriptions.json")
	want := Subscription{
		ID: "current", Category: "block", Name: "current",
		URL: "https://example.com/list", Format: "plain", Enabled: true, Interval: 24 * time.Hour,
	}
	if err := writeSubscriptionsFile(p, []Subscription{want}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"version": 1`) || !strings.Contains(string(data), `"interval": "24h0m0s"`) {
		t.Fatalf("unexpected current-schema JSON: %s", data)
	}
	got, err := LoadSubscriptions(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != want {
		t.Fatalf("round trip = %+v, want %+v", got, want)
	}
}

func TestPeriodicRefreshWritesCacheAndReloadsOnChange(t *testing.T) {
	var body atomic.Value
	body.Store("a.com\nb.com\n")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(body.Load().(string)))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	reload, count := countingReload()
	m := newTestSubManager(t, rulesDir, reload)
	m.subs = []Subscription{{
		ID: "proxy-list", Category: "proxy", Name: "proxy-list",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}}

	res := m.updateOne(context.Background(), "proxy-list")
	if !res.OK || res.Entries != 2 || count() != 1 {
		t.Fatalf("initial refresh = %+v, reloads=%d", res, count())
	}
	cachePath := filepath.Join(rulesDir, "proxy", "proxy-list.txt")
	if data, err := os.ReadFile(cachePath); err != nil || string(data) != "a.com\nb.com\n" {
		t.Fatalf("cache = %q, err=%v", data, err)
	}

	res = m.updateOne(context.Background(), "proxy-list")
	if !res.OK || count() != 1 {
		t.Fatalf("unchanged refresh = %+v, reloads=%d", res, count())
	}
	body.Store("a.com\nb.com\nc.com\n")
	res = m.updateOne(context.Background(), "proxy-list")
	if !res.OK || res.Entries != 3 || count() != 2 {
		t.Fatalf("changed refresh = %+v, reloads=%d", res, count())
	}
	assertNoTmpFiles(t, rulesDir)

	h, ok := healthEntry(m, "proxy-list")
	if !ok || !h.OK || h.Entries != 3 || h.Err != "" {
		t.Fatalf("health after refresh = %+v, present=%v", h, ok)
	}
	if _, err := time.Parse(time.RFC3339, h.At); err != nil {
		t.Fatalf("health timestamp %q: %v", h.At, err)
	}
}

func TestPeriodicRefreshKeepsOldCacheOnFetchFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	cachePath := filepath.Join(rulesDir, "direct", "list.txt")
	if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
		t.Fatal(err)
	}
	const oldContent = "last-good.example\n"
	if err := os.WriteFile(cachePath, []byte(oldContent), 0o644); err != nil {
		t.Fatal(err)
	}
	reload, count := countingReload()
	m := newTestSubManager(t, rulesDir, reload)
	m.subs = []Subscription{{
		ID: "list", Category: "direct", Name: "list",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}}

	res := m.updateOne(context.Background(), "list")
	if res.OK || res.Err == "" || count() != 0 {
		t.Fatalf("failed refresh = %+v, reloads=%d", res, count())
	}
	data, err := os.ReadFile(cachePath)
	if err != nil || string(data) != oldContent {
		t.Fatalf("last-good cache = %q, err=%v", data, err)
	}
	h, ok := healthEntry(m, "list")
	if !ok || h.OK || h.Err == "" || h.At == "" {
		t.Fatalf("failure health = %+v, present=%v", h, ok)
	}
}

func TestPeriodicRefreshKeepsOldCacheBelowFloor(t *testing.T) {
	tests := []struct {
		name, category, format, body string
	}{
		{name: "domain", category: "block", format: "plain", body: "# no entries\n"},
		{name: "chnroute", category: "chnroute", format: "cidr", body: "1.0.0.0/8\n2.0.0.0/8\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()

			rulesDir := t.TempDir()
			cachePath := filepath.Join(rulesDir, tc.category, tc.name+".txt")
			if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
				t.Fatal(err)
			}
			const oldContent = "last-good\n"
			if err := os.WriteFile(cachePath, []byte(oldContent), 0o644); err != nil {
				t.Fatal(err)
			}
			reload, count := countingReload()
			m := newTestSubManager(t, rulesDir, reload)
			m.subs = []Subscription{{
				ID: tc.name, Category: tc.category, Name: tc.name,
				URL: srv.URL, Format: tc.format, Enabled: true, Interval: time.Hour,
			}}

			res := m.updateOne(context.Background(), tc.name)
			if res.OK || count() != 0 {
				t.Fatalf("below-floor refresh = %+v, reloads=%d", res, count())
			}
			data, err := os.ReadFile(cachePath)
			if err != nil || string(data) != oldContent {
				t.Fatalf("last-good cache = %q, err=%v", data, err)
			}
		})
	}
}

func TestPeriodicRefreshRejectsHTMLResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte("<html><body>temporary error</body></html>"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	cachePath := filepath.Join(rulesDir, "block", "list.txt")
	if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
		t.Fatal(err)
	}
	const oldContent = "last-good.example\n"
	if err := os.WriteFile(cachePath, []byte(oldContent), 0o644); err != nil {
		t.Fatal(err)
	}
	m := newTestSubManager(t, rulesDir, nil)
	m.subs = []Subscription{{ID: "list", Category: "block", Name: "list", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour}}
	if res := m.updateOne(context.Background(), "list"); res.OK || !strings.Contains(res.Err, "HTML") {
		t.Fatalf("HTML refresh = %+v", res)
	}
	if data, err := os.ReadFile(cachePath); err != nil || string(data) != oldContent {
		t.Fatalf("last-good cache = %q, err=%v", data, err)
	}
}

func TestPeriodicRefreshRejectsLargeRelativeShrink(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("only-one.example\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	cachePath := filepath.Join(rulesDir, "proxy", "list.txt")
	if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
		t.Fatal(err)
	}
	var old strings.Builder
	for i := 0; i < 100; i++ {
		fmt.Fprintf(&old, "entry-%d.example\n", i)
	}
	if err := os.WriteFile(cachePath, []byte(old.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	m := newTestSubManager(t, rulesDir, nil)
	m.subs = []Subscription{{ID: "list", Category: "proxy", Name: "list", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour}}
	if res := m.updateOne(context.Background(), "list"); res.OK || !strings.Contains(res.Err, "shrink guard") {
		t.Fatalf("shrinking refresh = %+v", res)
	}
	if data, err := os.ReadFile(cachePath); err != nil || string(data) != old.String() {
		t.Fatalf("last-good cache changed, err=%v", err)
	}
}

func TestRunRefreshesMissingCache(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	m := newTestSubManager(t, rulesDir, func() error { return nil })
	m.subs = []Subscription{{
		ID: "missing", Category: "direct", Name: "missing",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { m.Run(ctx); close(done) }()
	cachePath := filepath.Join(rulesDir, "direct", "missing.txt")
	waitFor(t, 2*time.Second, func() bool {
		_, err := os.Stat(cachePath)
		return err == nil
	}, "initial subscription refresh")
	cancel()
	<-done
	if _, err := os.Stat(cachePath); err != nil {
		t.Fatalf("cache not created: %v", err)
	}
}

func TestRunWaitsForInFlightWorker(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	reloadEntered := make(chan struct{}, 1)
	releaseReload := make(chan struct{})
	m := newTestSubManager(t, t.TempDir(), func() error {
		reloadEntered <- struct{}{}
		<-releaseReload
		return nil
	})
	m.subs = []Subscription{{
		ID: "blocking", Category: "direct", Name: "blocking",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { m.Run(ctx); close(done) }()

	select {
	case <-reloadEntered:
	case <-time.After(2 * time.Second):
		cancel()
		close(releaseReload)
		t.Fatal("initial subscription refresh did not reach reload")
	}
	cancel()
	select {
	case <-done:
		close(releaseReload)
		t.Fatal("Run returned while a cache worker was still active")
	case <-time.After(50 * time.Millisecond):
	}
	close(releaseReload)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after the cache worker completed")
	}
}

func TestRunSkipsInitialRefreshWithExistingCache(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	rulesDir := t.TempDir()
	cachePath := filepath.Join(rulesDir, "direct", "existing.txt")
	if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cachePath, []byte("cached.example\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := newTestSubManager(t, rulesDir, func() error { return nil })
	m.subs = []Subscription{{
		ID: "existing", Category: "direct", Name: "existing",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour,
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	m.Run(ctx)
	if hits.Load() != 0 {
		t.Fatalf("existing cache caused %d immediate fetches", hits.Load())
	}
}

func TestPolicyPublishWhileRunActiveStartsTicker(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = w.Write([]byte("a.com\n"))
	}))
	defer srv.Close()

	m := newTestSubManager(t, t.TempDir(), func() error { return nil })
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() { m.Run(ctx); close(done) }()
	waitFor(t, time.Second, func() bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		return m.runCtx != nil
	}, "subscription runner startup")

	sub := Subscription{
		ID: "published", Category: "direct", Name: "published",
		URL: srv.URL, Format: "plain", Enabled: true, Interval: 50 * time.Millisecond,
	}
	prepared, err := m.PreparePolicyGeneration(context.Background(), []Subscription{sub})
	if err != nil {
		t.Fatal(err)
	}
	if err := prepared.CommitFiles(); err != nil {
		_ = prepared.Rollback()
		t.Fatal(err)
	}
	prepared.Publish()
	waitFor(t, 2*time.Second, func() bool { return hits.Load() >= 2 }, "ticker after policy publication")
	cancel()
	<-done
}

func TestSubHTTPClientResolvesViaTrustAndPreservesHost(t *testing.T) {
	var wantHost string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != wantHost {
			t.Errorf("Host header = %q, want %q", r.Host, wantHost)
		}
		_, _ = w.Write([]byte("a.cn\nb.cn\n"))
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)
	_, port, _ := net.SplitHostPort(u.Host)
	wantHost = "lists.example.com:" + port

	resolver := func(_ context.Context, host string) ([]net.IP, error) {
		if host != "lists.example.com" {
			return nil, fmt.Errorf("unexpected host %q", host)
		}
		return []net.IP{net.ParseIP("127.0.0.1")}, nil
	}
	client := newSubHTTPClient(resolver)
	req, _ := http.NewRequest(http.MethodGet, "http://"+wantHost+"/list", nil)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestNextBackoff(t *testing.T) {
	tests := []struct{ in, want time.Duration }{
		{0, time.Minute},
		{time.Minute, 2 * time.Minute},
		{2 * time.Minute, 4 * time.Minute},
		{20 * time.Minute, 30 * time.Minute},
		{30 * time.Minute, 30 * time.Minute},
	}
	for _, tc := range tests {
		if got := nextBackoff(tc.in); got != tc.want {
			t.Errorf("nextBackoff(%v) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

func assertNoTmpFiles(t *testing.T, dir string) {
	t.Helper()
	err := filepath.WalkDir(dir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() && strings.HasSuffix(path, ".tmp") {
			t.Errorf("leftover tmp file: %s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", dir, err)
	}
}
