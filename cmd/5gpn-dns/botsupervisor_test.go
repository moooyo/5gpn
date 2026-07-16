package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
)

// fakeRunner is a botRunner whose Run just blocks until its context is cancelled,
// letting the supervisor test drive start/stop without a live Telegram.
type fakeRunner struct {
	id int
}

func (f *fakeRunner) Run(ctx context.Context) { <-ctx.Done() }

// TestBotSupervisor_ApplyLifecycle exercises the hot-reload state machine:
// enable, admins-only edit (token kept), bad-token (old bot untouched), disable.
func TestBotSupervisor_ApplyLifecycle(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	file := filepath.Join(t.TempDir(), "tgbot.json")
	sup := newBotSupervisor(ctx, Config{TGBotFile: file}, &Controller{})

	// Injected factory: empty token = disabled (nil runner); "BAD" = validation
	// error; anything else builds a fresh fakeRunner (counting builds).
	built := 0
	var last *fakeRunner
	sup.factory = func(c Config, _ *Controller) (botRunner, error) {
		switch c.TGBotToken {
		case "":
			return nil, nil
		case "BAD":
			return nil, errors.New("getMe failed: unauthorized")
		default:
			built++
			last = &fakeRunner{id: built}
			return last, nil
		}
	}

	// 1. Enable with a good token + one admin.
	good := "good-token"
	if err := sup.Apply(&good, []int64{111}); err != nil {
		t.Fatalf("Apply enable: %v", err)
	}
	if v := sup.View(); !v.TokenSet || !v.Running || len(v.AdminIDs) != 1 || v.AdminIDs[0] != 111 {
		t.Fatalf("after enable, view = %+v", v)
	}
	if tc, err := LoadTGBot(file); err != nil || tc == nil || tc.Token != "good-token" {
		t.Fatalf("after enable, persisted = (%+v, %v)", tc, err)
	}

	// 2. Admins-only edit (token omitted → nil): keeps the token, restarts.
	prevBuilt := built
	if err := sup.Apply(nil, []int64{111, 222}); err != nil {
		t.Fatalf("Apply admins-only: %v", err)
	}
	if built != prevBuilt+1 {
		t.Errorf("admins-only edit built %d bots, want +1", built-prevBuilt)
	}
	if v := sup.View(); !v.TokenSet || len(v.AdminIDs) != 2 {
		t.Fatalf("after admins edit, view = %+v", v)
	}
	if tc, _ := LoadTGBot(file); tc == nil || tc.Token != "good-token" {
		t.Errorf("admins-only edit must keep the token, got %+v", tc)
	}

	// 3. Bad token: error, and the old (running) bot is left untouched.
	bad := "BAD"
	prevRunner := last
	if err := sup.Apply(&bad, []int64{111}); err == nil {
		t.Fatalf("Apply with a bad token should error")
	}
	if last != prevRunner {
		t.Errorf("a bad-token Apply must not build a new bot")
	}
	if v := sup.View(); !v.Running || !v.TokenSet {
		t.Errorf("a bad-token Apply must leave the old bot running, got %+v", v)
	}

	// 4. Disable via an explicit empty token.
	empty := ""
	if err := sup.Apply(&empty, []int64{111}); err != nil {
		t.Fatalf("Apply disable: %v", err)
	}
	if v := sup.View(); v.Running || v.TokenSet {
		t.Errorf("after disable, view = %+v, want stopped + no token", v)
	}
	if tc, _ := LoadTGBot(file); tc == nil || tc.Token != "" {
		t.Errorf("disable must clear the persisted token, got %+v", tc)
	}
}

// TestBotSupervisor_StartEmptyTokenDisabled: Start with no token neither builds
// a bot nor reports running.
func TestBotSupervisor_StartEmptyTokenDisabled(t *testing.T) {
	sup := newBotSupervisor(context.Background(), Config{}, &Controller{})
	calls := 0
	sup.factory = func(Config, *Controller) (botRunner, error) { calls++; return nil, nil }
	sup.Start()
	if calls != 0 {
		t.Errorf("Start with an empty token called the factory %d times, want 0", calls)
	}
	if v := sup.View(); v.Running || v.TokenSet {
		t.Errorf("empty-token supervisor view = %+v, want disabled", v)
	}
}
