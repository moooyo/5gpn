package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// NOTE (UP-1 Task D3): TestControllerAddRuleConcurrentNoLostUpdate (concurrent
// Controller.AddRule) and TestControllerNilSubsDegradesGracefully (nil-subs
// degrade of Subscriptions/SubscriptionHealth/SubscriptionsWithHealth/
// GetSubscription/Update/AddSubscription/RemoveSubscription/
// ReplaceSubscription/ValidateSubscription) were REMOVED here — the manual-
// rule and subscription CRUD facade they covered is gone, absorbed by the
// unified policy-rule model. The manual-rule-file concurrency concern now
// lives in policy_engine.go's writeManualFiles (compiler-driven, one atomic
// rewrite per apply — no per-entry RMW race to lose updates on).

// countingServer returns an httptest server that serves a fixed body and counts
// requests atomically.
func countingServer(t *testing.T, body string) (*httptest.Server, func() int32) {
	t.Helper()
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv, func() int32 { return atomic.LoadInt32(&hits) }
}

func waitFor(t *testing.T, cond func() bool, within time.Duration, msg string) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for: %s", msg)
}

// #10: Remove must stop the subscription's ticker goroutine. Before the fix the
// ticker looped forever on the process context, calling UpdateOne("not found")
// on every tick — a permanent goroutine + fetch leak.
func TestSubManagerRemoveStopsTicker(t *testing.T) {
	srv, hits := countingServer(t, "a.com\n")

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() { m.Run(ctx); close(done) }()
	time.Sleep(50 * time.Millisecond) // let Run start (no subs yet)

	sub := Subscription{ID: "r1", Category: "direct", Name: "r1", URL: srv.URL, Format: "plain", Enabled: true, Interval: 60 * time.Millisecond}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}
	// Wait until the ticker has fired at least once beyond Add's initial fetch.
	waitFor(t, func() bool { return hits() >= 2 }, 2*time.Second, "ticker to fire before Remove")

	if err := m.Remove("r1"); err != nil {
		t.Fatalf("Remove: %v", err)
	}
	time.Sleep(120 * time.Millisecond) // let any in-flight fetch settle
	baseline := hits()
	time.Sleep(300 * time.Millisecond) // several intervals with no ticker
	if got := hits(); got != baseline {
		t.Errorf("ticker kept fetching after Remove: baseline=%d, later=%d (leak)", baseline, got)
	}

	cancel()
	<-done
}

// #10: Replace must reschedule the ticker onto the new definition — the old
// ticker stops and a single new one drives the new URL/interval, rather than
// leaving the old ticker alive (double-fetch) as Remove+Add did.
func TestSubManagerReplaceReschedulesTicker(t *testing.T) {
	oldSrv, oldHits := countingServer(t, "old.com\n")
	newSrv, newHits := countingServer(t, "new.com\n")

	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() { m.Run(ctx); close(done) }()
	time.Sleep(50 * time.Millisecond)

	sub := Subscription{ID: "e1", Category: "direct", Name: "e1", URL: oldSrv.URL, Format: "plain", Enabled: true, Interval: 60 * time.Millisecond}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}
	waitFor(t, func() bool { return oldHits() >= 2 }, 2*time.Second, "old ticker to fire")

	edited := sub
	edited.URL = newSrv.URL
	if _, err := m.Replace("e1", edited); err != nil {
		t.Fatalf("Replace: %v", err)
	}

	// The new ticker should now be fetching the new server…
	waitFor(t, func() bool { return newHits() >= 2 }, 2*time.Second, "new ticker to fire after Replace")

	// …and the old server should stop receiving hits (old ticker cancelled).
	time.Sleep(120 * time.Millisecond)
	oldBaseline := oldHits()
	time.Sleep(240 * time.Millisecond)
	if got := oldHits(); got != oldBaseline {
		t.Errorf("old ticker kept fetching after Replace: baseline=%d later=%d (double-schedule)", oldBaseline, got)
	}

	cancel()
	<-done
}

// Replace updates the subscription in place and persists it.
func TestSubManagerReplaceUpdatesInPlace(t *testing.T) {
	srv, _ := countingServer(t, "a.com\n")
	rulesDir := t.TempDir()
	subPath := filepath.Join(t.TempDir(), "subscriptions.json")
	reload, _ := countingReload()
	m, err := NewSubManager(subPath, rulesDir, reload, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	sub := Subscription{ID: "u1", Category: "direct", Name: "u1", URL: srv.URL, Format: "plain", Enabled: true, Interval: time.Hour}
	if _, err := m.Add(sub); err != nil {
		t.Fatalf("Add: %v", err)
	}

	edited := sub
	edited.Enabled = false
	edited.Interval = 2 * time.Hour
	if _, err := m.Replace("u1", edited); err != nil {
		t.Fatalf("Replace: %v", err)
	}

	got, ok := m.Get("u1")
	if !ok {
		t.Fatal("Get after Replace: not found")
	}
	if got.Enabled != false || got.Interval != 2*time.Hour {
		t.Errorf("Replace did not apply edits: got Enabled=%v Interval=%v", got.Enabled, got.Interval)
	}

	// Replacing a non-existent ID is a not-found error.
	if _, err := m.Replace("nope", Subscription{ID: "nope", Category: "direct", Name: "nope", URL: srv.URL, Format: "plain"}); err == nil {
		t.Error("Replace of non-existent ID should error")
	}
}

// #28: a not-found subscription error wraps the ErrSubNotFound sentinel, so the
// HTTP layer maps it via errors.Is rather than a fragile "not found" substring.
func TestSubNotFoundWrapsSentinel(t *testing.T) {
	m, err := NewSubManager(filepath.Join(t.TempDir(), "subscriptions.json"), t.TempDir(), func() error { return nil }, nil)
	if err != nil {
		t.Fatalf("NewSubManager: %v", err)
	}
	if err := m.Remove("ghost"); !errors.Is(err, ErrSubNotFound) {
		t.Errorf("Remove(missing) err = %v, want wrap of ErrSubNotFound", err)
	}
}
