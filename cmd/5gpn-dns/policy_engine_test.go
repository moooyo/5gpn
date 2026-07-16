package main

import (
	"context"
	"encoding/json"
	"errors"
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

// TestPolicyEngine_CompileAndApply_Success drives the full pipeline over a
// real PolicyRuleManager (one block rule + one proxy subscription rule) and
// a real SubManager fetching from an httptest server. It asserts the DNS-only
// outcomes: the block name lands in the DNS manual file, the subscription's
// fetch lands in the DNS cache, and the fallback is applied to the handler.
func TestPolicyEngine_CompileAndApply_Success(t *testing.T) {
	dir := t.TempDir()
	rulesDir := filepath.Join(dir, "rules")

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("example.com\nfoo.example.com\n"))
	}))
	defer srv.Close()

	polMgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatalf("NewPolicyRuleManager: %v", err)
	}
	if _, err := polMgr.AddRule(PolicyRule{
		Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindDomainSuffix, Value: "ads.example.com"},
	}); err != nil {
		t.Fatalf("AddRule(block): %v", err)
	}
	subRule, err := polMgr.AddRule(PolicyRule{
		Intent: IntentProxy, Enabled: true,
		Matcher: Matcher{Kind: KindSubscription, Value: srv.URL, Format: "plain"},
	})
	if err != nil {
		t.Fatalf("AddRule(proxy-subscription): %v", err)
	}

	var reloadCalls int
	reload := func() error { reloadCalls++; return nil }

	subMgr, err := NewSubManager(filepath.Join(dir, "subscriptions.json"), rulesDir, reload, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}

	h := &Handler{}
	engine := NewPolicyEngine(polMgr, subMgr, h, reload, rulesDir)

	if err := engine.CompileAndApply(context.Background()); err != nil {
		t.Fatalf("CompileAndApply: %v", err)
	}

	// (a) block name landed in rules/block.txt.
	blockData, err := os.ReadFile(filepath.Join(rulesDir, "block.txt"))
	if err != nil {
		t.Fatalf("read block.txt: %v", err)
	}
	if !strings.Contains(string(blockData), "ads.example.com") {
		t.Errorf("block.txt missing block rule, got: %s", blockData)
	}

	// (b) the DNS cache side of the fetch exists.
	dnsCachePath := filepath.Join(rulesDir, "blacklist", "pol_"+subRule.ID+".txt")
	dnsCacheData, err := os.ReadFile(dnsCachePath)
	if err != nil {
		t.Fatalf("DNS cache %s missing: %v", dnsCachePath, err)
	}
	if !strings.Contains(string(dnsCacheData), "example.com") {
		t.Errorf("DNS cache missing fetched entries, got: %s", dnsCacheData)
	}

	// (c) handler.fallbackMode() reflects the model (default auto).
	if got := h.fallbackMode(); got != FallbackAuto {
		t.Errorf("fallback mode = %s, want %s", got, FallbackAuto)
	}

	if reloadCalls == 0 {
		t.Error("expected reload() to have been called at least once")
	}
}

func TestPolicyEngineSerializesConcurrentApplies(t *testing.T) {
	dir := t.TempDir()
	mgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	var active, maxActive atomic.Int32
	reload := func() error {
		n := active.Add(1)
		for {
			old := maxActive.Load()
			if n <= old || maxActive.CompareAndSwap(old, n) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
		active.Add(-1)
		return nil
	}
	engine := NewPolicyEngine(mgr, nil, &Handler{Cache: NewCache(8)}, reload, filepath.Join(dir, "rules"))

	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- engine.CompileAndApply(context.Background())
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("concurrent apply: %v", err)
		}
	}
	if got := maxActive.Load(); got != 1 {
		t.Fatalf("max concurrent commit sections = %d, want 1", got)
	}
}

func TestPolicyEngineApplyPublishesReorderedGlobalFirstMatch(t *testing.T) {
	dir := t.TempDir()
	mgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	direct, err := mgr.AddRule(PolicyRule{Intent: IntentDirect, Enabled: true,
		Matcher: Matcher{Kind: KindDomainSuffix, Value: "example.com"}})
	if err != nil {
		t.Fatal(err)
	}
	block, err := mgr.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindDomain, Value: "www.example.com"}})
	if err != nil {
		t.Fatal(err)
	}
	h := &Handler{Cache: NewCache(8)}
	engine := NewPolicyEngine(mgr, nil, h, func() error { return nil }, filepath.Join(dir, "rules"))
	if err := engine.CompileAndApply(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := h.classifyName("www.example.com"); got.Reason != "force-direct" {
		t.Fatalf("initial order verdict = %+v, want direct", got)
	}
	if err := mgr.Reorder([]string{block.ID, direct.ID}); err != nil {
		t.Fatal(err)
	}
	if err := engine.CompileAndApply(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := h.classifyName("www.example.com"); got.Reason != "block" {
		t.Fatalf("reordered verdict = %+v, want block", got)
	}
}

func TestPolicyEngineRevisionCASRejectsStaleApply(t *testing.T) {
	dir := t.TempDir()
	rulesDir := filepath.Join(dir, "rules")
	requestStarted := make(chan struct{}, 1)
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		select {
		case requestStarted <- struct{}{}:
		default:
		}
		<-release
		_, _ = w.Write([]byte("one.example\ntwo.example\n"))
	}))
	defer srv.Close()

	mgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	subRule, err := mgr.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindSubscription, Value: srv.URL, Format: "plain"}})
	if err != nil {
		t.Fatal(err)
	}
	subs, err := NewSubManager(filepath.Join(dir, "subscriptions.json"), rulesDir, func() error { return nil }, nil)
	if err != nil {
		t.Fatal(err)
	}
	h := &Handler{Cache: NewCache(8)}
	engine := NewPolicyEngine(mgr, subs, h, func() error { return nil }, rulesDir)
	done := make(chan error, 1)
	go func() { done <- engine.CompileAndApply(context.Background()) }()

	select {
	case <-requestStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("subscription fetch did not start")
	}
	if _, err := mgr.AddRule(PolicyRule{Intent: IntentDirect, Enabled: true,
		Matcher: Matcher{Kind: KindDomain, Value: "new.example"}}); err != nil {
		t.Fatal(err)
	}
	close(release)
	if err := <-done; !errors.Is(err, ErrPolicyRevisionChanged) {
		t.Fatalf("stale apply error = %v, want ErrPolicyRevisionChanged", err)
	}
	if _, err := os.Stat(filepath.Join(rulesDir, "block.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale generation wrote block.txt: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "subscriptions.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale generation wrote subscriptions.json: %v", err)
	}
	cachePath := filepath.Join(rulesDir, "block", providerName(subRule.ID)+".txt")
	if _, err := os.Stat(cachePath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale generation wrote subscription cache: %v", err)
	}
	if got := subs.List(); len(got) != 0 {
		t.Fatalf("stale generation changed in-memory subscriptions: %+v", got)
	}
	if h.orderedPolicy.Load() != nil {
		t.Fatal("stale generation was published to the live handler")
	}
}

func TestPolicyEngineReloadFailureRollsBackSubscriptionGeneration(t *testing.T) {
	dir := t.TempDir()
	rulesDir := filepath.Join(dir, "rules")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("one.example\ntwo.example\n"))
	}))
	defer srv.Close()
	mgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	rule, err := mgr.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindSubscription, Value: srv.URL, Format: "plain"}})
	if err != nil {
		t.Fatal(err)
	}
	subsPath := filepath.Join(dir, "subscriptions.json")
	subs, err := NewSubManager(subsPath, rulesDir, func() error { return nil }, nil)
	if err != nil {
		t.Fatal(err)
	}
	engine := NewPolicyEngine(mgr, subs, &Handler{Cache: NewCache(8)},
		func() error { return errors.New("reload failed") }, rulesDir)
	if err := engine.CompileAndApply(context.Background()); err == nil {
		t.Fatal("expected reload failure")
	}
	for _, path := range []string{
		subsPath,
		filepath.Join(rulesDir, "block", providerName(rule.ID)+".txt"),
	} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("transaction rollback left %s: %v", path, err)
		}
	}
	if got := subs.List(); len(got) != 0 {
		t.Fatalf("rollback changed in-memory subscriptions: %+v", got)
	}
}

func TestPolicyEngineSubscriptionFetchFailureKeepsLastGoodCache(t *testing.T) {
	dir := t.TempDir()
	rulesDir := filepath.Join(dir, "rules")
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := srv.URL
	srv.Close() // deterministic connection-refused during prepare

	mgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	rule, err := mgr.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindSubscription, Value: url, Format: "plain"}})
	if err != nil {
		t.Fatal(err)
	}
	sub := Subscription{ID: rule.ID, Category: "block", Name: providerName(rule.ID), URL: url, Format: "plain", Enabled: true}
	subsPath := filepath.Join(dir, "subscriptions.json")
	if err := writeSubscriptionsFile(subsPath, []Subscription{sub}); err != nil {
		t.Fatal(err)
	}
	cachePath := filepath.Join(rulesDir, "block", providerName(rule.ID)+".txt")
	if err := atomicWriteLines(cachePath, []string{"last-good.example"}); err != nil {
		t.Fatal(err)
	}
	subs, err := NewSubManager(subsPath, rulesDir, func() error { return nil }, nil)
	if err != nil {
		t.Fatal(err)
	}
	h := &Handler{Cache: NewCache(8)}
	engine := NewPolicyEngine(mgr, subs, h, func() error { return nil }, rulesDir)
	if err := engine.CompileAndApply(context.Background()); err != nil {
		t.Fatalf("offline-safe apply: %v", err)
	}
	data, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "last-good.example\n" {
		t.Fatalf("cache replaced after fetch failure: %q", data)
	}
	if got := h.classifyName("last-good.example"); got.Reason != "block" {
		t.Fatalf("last-good cache not published: %+v", got)
	}
}

func TestPolicyEngineReloadFailureRollsBackManualGeneration(t *testing.T) {
	dir := t.TempDir()
	rulesDir := filepath.Join(dir, "rules")
	if err := os.MkdirAll(rulesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(rulesDir, "block.txt")
	if err := os.WriteFile(path, []byte("old.example\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := mgr.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindDomainSuffix, Value: "new.example"}}); err != nil {
		t.Fatal(err)
	}
	engine := NewPolicyEngine(mgr, nil, &Handler{Cache: NewCache(8)},
		func() error { return errors.New("reload failed") }, rulesDir)
	if err := engine.CompileAndApply(context.Background()); err == nil {
		t.Fatal("expected reload failure")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "old.example\n" {
		t.Fatalf("block.txt after rollback = %q, want original", data)
	}
}

func TestPolicyEngineCanceledApplyDoesNotCommit(t *testing.T) {
	dir := t.TempDir()
	mgr, err := NewPolicyRuleManager(filepath.Join(dir, "policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := mgr.AddRule(PolicyRule{Intent: IntentBlock, Enabled: true,
		Matcher: Matcher{Kind: KindDomain, Value: "cancel.example"}}); err != nil {
		t.Fatal(err)
	}
	engine := NewPolicyEngine(mgr, nil, &Handler{Cache: NewCache(8)}, func() error { return nil }, filepath.Join(dir, "rules"))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := engine.CompileAndApply(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled apply error = %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "rules", "block.exact.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("canceled apply committed manual file: %v", err)
	}
}

// TestPolicyEngine_CompileAndApply_CompileErrorLeavesFallbackUntouched
// proves a compile-time error (an unknown intent slipping past validation,
// e.g. a hand-edited policy.json) returns an error and leaves the handler's
// fallback untouched — CompileAndApply must not partially apply a rejected
// compile.
func TestPolicyEngine_CompileAndApply_CompileErrorLeavesFallbackUntouched(t *testing.T) {
	dir := t.TempDir()
	rulesDir := filepath.Join(dir, "rules")
	policyPath := filepath.Join(dir, "policy.json")

	// Hand-craft an invalid model on disk (bypassing AddRule's validation) so
	// CompilePolicy itself rejects it.
	bad := PolicyModel{
		Version:  policySchemaVersion,
		Rules:    []PolicyRule{{ID: "bad", Order: 0, Intent: Intent("bogus"), Enabled: true, Matcher: Matcher{Kind: KindDomain, Value: "x.com"}}},
		Fallback: Fallback{Policy: FallbackGateway},
	}
	data, err := json.MarshalIndent(bad, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(policyPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	polMgr, err := NewPolicyRuleManager(policyPath)
	if err != nil {
		t.Fatalf("NewPolicyRuleManager: %v", err)
	}

	h := &Handler{}
	h.setFallback(FallbackDirect) // known starting value, distinct from the model's fallback

	reload := func() error { return nil }
	engine := NewPolicyEngine(polMgr, nil, h, reload, rulesDir)

	if err := engine.CompileAndApply(context.Background()); err == nil {
		t.Fatal("expected an error from an invalid compile, got nil")
	}
	if got := h.fallbackMode(); got != FallbackDirect {
		t.Errorf("fallback must not change on a rejected compile, got %s want %s", got, FallbackDirect)
	}
}
