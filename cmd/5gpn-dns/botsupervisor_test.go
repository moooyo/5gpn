package main

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	telegram "github.com/go-telegram/bot"
)

type fakeRunner struct {
	id int

	mu       sync.Mutex
	admins   []int64
	runCalls int
	health   func(error)
}

func (f *fakeRunner) Run(ctx context.Context) {
	f.mu.Lock()
	f.runCalls++
	f.mu.Unlock()
	<-ctx.Done()
}

func (f *fakeRunner) ReplaceAdmins(admins []int64) {
	f.mu.Lock()
	f.admins = append([]int64(nil), admins...)
	f.mu.Unlock()
}

func (f *fakeRunner) SetHealthReporter(report func(error)) {
	f.mu.Lock()
	f.health = report
	f.mu.Unlock()
}

func (f *fakeRunner) adminSnapshot() []int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]int64(nil), f.admins...)
}

func (f *fakeRunner) runCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.runCalls
}

func (f *fakeRunner) reportHealth(err error) bool {
	f.mu.Lock()
	report := f.health
	f.mu.Unlock()
	if report == nil {
		return false
	}
	report(err)
	return true
}

type returningRunner struct{}

func (returningRunner) Run(context.Context) {}

func waitBotView(t *testing.T, sup *botSupervisor, want func(TGBotView) bool) TGBotView {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		view := sup.View()
		if want(view) {
			return view
		}
		time.Sleep(time.Millisecond)
	}
	view := sup.View()
	t.Fatalf("timed out waiting for bot state; final view=%+v", view)
	return TGBotView{}
}

// TestBotSupervisor_ApplyLifecycle exercises enable, a network-free admins-only
// edit, rejected-token rollback, and disable.
func TestBotSupervisor_ApplyLifecycle(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	file := filepath.Join(t.TempDir(), "tgbot.json")
	sup := newBotSupervisor(ctx, Config{TGBotFile: file}, &Controller{})

	built := 0
	var last *fakeRunner
	sup.factory = func(c Config, _ *Controller) (botRunner, error) {
		switch c.TGBotToken {
		case "BAD":
			return nil, errors.New("getMe failed: unauthorized")
		default:
			built++
			last = &fakeRunner{id: built}
			return last, nil
		}
	}

	good := "good-token"
	if err := sup.Apply(&good, []int64{111}); err != nil {
		t.Fatalf("Apply enable: %v", err)
	}
	if v := sup.View(); !v.TokenSet || v.State != botStateHealthy || len(v.AdminIDs) != 1 || v.AdminIDs[0] != 111 {
		t.Fatalf("after enable, view = %+v", v)
	}
	if tc, err := LoadTGBot(file); err != nil || tc == nil || tc.Token != "good-token" {
		t.Fatalf("after enable, persisted = (%+v, %v)", tc, err)
	}

	prevBuilt, active := built, last
	if err := sup.Apply(nil, []int64{111, 222}); err != nil {
		t.Fatalf("Apply admins-only: %v", err)
	}
	if built != prevBuilt {
		t.Errorf("admins-only edit rebuilt %d bots, want 0", built-prevBuilt)
	}
	if got := active.adminSnapshot(); len(got) != 2 || got[0] != 111 || got[1] != 222 {
		t.Errorf("live admin replacement = %v, want [111 222]", got)
	}
	if v := sup.View(); !v.TokenSet || len(v.AdminIDs) != 2 {
		t.Fatalf("after admins edit, view = %+v", v)
	}
	if tc, _ := LoadTGBot(file); tc == nil || tc.Token != "good-token" {
		t.Errorf("admins-only edit must keep token, got %+v", tc)
	}

	bad := "BAD"
	prevRunner := last
	if err := sup.Apply(&bad, []int64{111}); err == nil {
		t.Fatal("Apply with a bad token should error")
	}
	if last != prevRunner {
		t.Error("bad-token Apply replaced the old bot")
	}
	if v := sup.View(); v.State != botStateHealthy || !v.TokenSet || len(v.AdminIDs) != 2 {
		t.Errorf("bad-token Apply changed live state: %+v", v)
	}

	empty := ""
	if err := sup.Apply(&empty, []int64{111}); err != nil {
		t.Fatalf("Apply disable: %v", err)
	}
	if v := sup.View(); v.TokenSet || v.State != botStateDisabled {
		t.Errorf("after disable, view = %+v", v)
	}
	if tc, _ := LoadTGBot(file); tc == nil || tc.Token != "" {
		t.Errorf("disable must clear persisted token, got %+v", tc)
	}
}

func TestBotSupervisor_StartEmptyTokenDisabled(t *testing.T) {
	sup := newBotSupervisor(context.Background(), Config{}, &Controller{})
	calls := 0
	sup.factory = func(Config, *Controller) (botRunner, error) {
		calls++
		return nil, nil
	}
	sup.Start()
	if calls != 0 {
		t.Errorf("Start with empty token called factory %d times", calls)
	}
	if v := sup.View(); v.TokenSet || v.State != botStateDisabled {
		t.Errorf("empty-token view = %+v", v)
	}
}

func TestBotSupervisor_StartupFailureRetriesAndRecovers(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sup := newBotSupervisor(ctx, Config{TGBotToken: "startup-token"}, &Controller{})
	sup.retryInitial = time.Millisecond
	sup.retryMax = 2 * time.Millisecond
	runner := &fakeRunner{}
	var calls atomic.Int32
	sup.factory = func(Config, *Controller) (botRunner, error) {
		if calls.Add(1) < 3 {
			return nil, errors.New("temporary Telegram outage")
		}
		return runner, nil
	}

	sup.Start()
	view := waitBotView(t, sup, func(v TGBotView) bool { return v.State == botStateHealthy })
	if view.State != botStateHealthy || view.LastError != "" {
		t.Fatalf("recovered view = %+v", view)
	}
	if got := calls.Load(); got != 3 {
		t.Fatalf("factory calls = %d, want 3", got)
	}
}

func TestBotSupervisor_StartupUnauthorizedWaitsForNewToken(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sup := newBotSupervisor(ctx, Config{TGBotToken: "revoked"}, &Controller{})
	sup.retryInitial = time.Millisecond
	sup.retryMax = time.Millisecond
	var calls atomic.Int32
	sup.factory = func(Config, *Controller) (botRunner, error) {
		calls.Add(1)
		return nil, fmt.Errorf("getMe: %w", telegram.ErrorUnauthorized)
	}
	sup.Start()
	waitBotView(t, sup, func(v TGBotView) bool { return v.State == botStateDegraded })
	time.Sleep(10 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("permanent unauthorized error retried %d times, want one attempt", got)
	}
}

// A getMe already in flight for the startup configuration must not publish its
// runner after a newer API configuration commits.
func TestBotSupervisor_StartupBuildCannotOverwriteNewConfig(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	file := filepath.Join(t.TempDir(), "tgbot.json")
	sup := newBotSupervisor(ctx, Config{TGBotToken: "old", TGBotFile: file}, &Controller{})
	oldStarted := make(chan struct{})
	releaseOld := make(chan struct{})
	oldBuilt := make(chan struct{})
	oldRunner, newRunner := &fakeRunner{id: 1}, &fakeRunner{id: 2}
	sup.factory = func(c Config, _ *Controller) (botRunner, error) {
		if c.TGBotToken == "old" {
			close(oldStarted)
			<-releaseOld
			close(oldBuilt)
			return oldRunner, nil
		}
		return newRunner, nil
	}

	sup.Start()
	<-oldStarted
	newToken := "new"
	if err := sup.Apply(&newToken, []int64{22}); err != nil {
		t.Fatalf("Apply new token: %v", err)
	}
	close(releaseOld)
	<-oldBuilt
	waitBotView(t, sup, func(v TGBotView) bool {
		return v.State == botStateHealthy && len(v.AdminIDs) == 1 && v.AdminIDs[0] == 22
	})
	time.Sleep(5 * time.Millisecond)

	sup.mu.Lock()
	active, token := sup.runner, sup.token
	sup.mu.Unlock()
	if active != newRunner || token != "new" {
		t.Fatalf("active=(%T,%q), want new runner/token", active, token)
	}
	if oldRunner.runCount() != 0 {
		t.Errorf("stale startup runner ran %d times", oldRunner.runCount())
	}
}

func TestBotSupervisor_ConcurrentApplyLastRequestWins(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	file := filepath.Join(t.TempDir(), "tgbot.json")
	sup := newBotSupervisor(ctx, Config{TGBotFile: file}, &Controller{})
	aStarted := make(chan struct{})
	releaseA := make(chan struct{})
	runners := map[string]*fakeRunner{
		"base": {id: 1},
		"A":    {id: 2},
		"B":    {id: 3},
	}
	sup.factory = func(c Config, _ *Controller) (botRunner, error) {
		if c.TGBotToken == "A" {
			close(aStarted)
			<-releaseA
		}
		return runners[c.TGBotToken], nil
	}
	base := "base"
	if err := sup.Apply(&base, []int64{1}); err != nil {
		t.Fatalf("Apply base: %v", err)
	}

	errA := make(chan error, 1)
	a := "A"
	go func() { errA <- sup.Apply(&a, []int64{2}) }()
	<-aStarted
	b := "B"
	if err := sup.Apply(&b, []int64{3}); err != nil {
		t.Fatalf("Apply B: %v", err)
	}
	close(releaseA)
	if err := <-errA; !errors.Is(err, errBotConfigSuperseded) {
		t.Fatalf("Apply A error = %v, want superseded", err)
	}

	sup.mu.Lock()
	active, token := sup.runner, sup.token
	sup.mu.Unlock()
	if active != runners["B"] || token != "B" {
		t.Fatalf("active/token=(%T,%q), want B", active, token)
	}
	if tc, err := LoadTGBot(file); err != nil || tc == nil || tc.Token != "B" || len(tc.Admins) != 1 || tc.Admins[0] != 3 {
		t.Fatalf("persisted latest config = (%+v,%v)", tc, err)
	}
}

func TestBotSupervisor_RunnerExitUpdatesHealth(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sup := newBotSupervisor(ctx, Config{}, &Controller{})
	sup.factory = func(Config, *Controller) (botRunner, error) { return returningRunner{}, nil }
	token := "token"
	if err := sup.Apply(&token, []int64{1}); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	view := waitBotView(t, sup, func(v TGBotView) bool { return v.State == botStateDegraded })
	if view.LastError == "" {
		t.Fatalf("runner exit omitted last error: %+v", view)
	}
}

func TestBotSupervisor_HealthReporterIsRunnerScoped(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sup := newBotSupervisor(ctx, Config{}, &Controller{})
	oldRunner, newRunner := &fakeRunner{id: 1}, &fakeRunner{id: 2}
	sup.factory = func(c Config, _ *Controller) (botRunner, error) {
		if c.TGBotToken == "old" {
			return oldRunner, nil
		}
		return newRunner, nil
	}
	old := "old"
	if err := sup.Apply(&old, []int64{1}); err != nil {
		t.Fatalf("Apply old: %v", err)
	}
	for !oldRunner.reportHealth(errors.New("poll failed")) {
		time.Sleep(time.Millisecond)
	}
	view := sup.View()
	if view.State != botStateDegraded || view.LastError != "poll failed" {
		t.Fatalf("degraded health view = %+v", view)
	}
	if !oldRunner.reportHealth(nil) || sup.View().State != botStateHealthy {
		t.Fatalf("healthy report did not recover state: %+v", sup.View())
	}

	newToken := "new"
	if err := sup.Apply(&newToken, []int64{2}); err != nil {
		t.Fatalf("Apply new: %v", err)
	}
	oldRunner.reportHealth(errors.New("late old-runner failure"))
	view = sup.View()
	if view.State != botStateHealthy || view.LastError != "" {
		t.Fatalf("late old health polluted new runner: %+v", view)
	}
}

func TestBotSupervisor_PersistFailureLeavesLiveConfigUntouched(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	missingDirFile := filepath.Join(t.TempDir(), "missing", "tgbot.json")
	sup := newBotSupervisor(ctx, Config{TGBotToken: "old", TGBotAdmins: map[int64]bool{1: true}, TGBotFile: missingDirFile}, &Controller{})
	runner := &fakeRunner{}
	sup.factory = func(Config, *Controller) (botRunner, error) { return runner, nil }
	sup.Start()
	waitBotView(t, sup, func(v TGBotView) bool { return v.State == botStateHealthy })

	if err := sup.Apply(nil, []int64{2}); err == nil {
		t.Fatal("Apply should fail when persistence directory is missing")
	}
	view := sup.View()
	if len(view.AdminIDs) != 1 || view.AdminIDs[0] != 1 || view.State != botStateHealthy {
		t.Fatalf("persist failure changed live view: %+v", view)
	}
	if got := runner.adminSnapshot(); len(got) != 0 {
		t.Fatalf("persist failure changed runner admins: %v", got)
	}
}
