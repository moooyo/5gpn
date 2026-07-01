package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestIsValidDomain mirrors the VALID/INVALID tables from tgbot.py's
// TestDomainRe and tests/test_domain_validation.sh, plus the over-length and
// uppercase-lowercased cases. isValidDomain and install.sh's is_valid_domain
// must stay in lockstep.
func TestIsValidDomain(t *testing.T) {
	valid := []string{
		"example.com",
		"sub.domain.example.com",
		"a-b.example.com",
		"1foo.example.co",
		"xn--fsq.com",
	}
	invalid := []string{
		"",
		"example",
		"foo.c",
		"foo.123",
		"_dmarc.example.com",
		"foo_bar.com",
		"-foo.example.com",
		"foo-.example.com",
		"foo..com",
		"ex ample.com",
		"http://example.com",
		"example.com/x",
	}

	for _, d := range valid {
		if !isValidDomain(d) {
			t.Errorf("isValidDomain(%q) = false, want true", d)
		}
	}
	for _, d := range invalid {
		if isValidDomain(d) {
			t.Errorf("isValidDomain(%q) = true, want false", d)
		}
	}
}

// TestIsValidDomain_OverLength confirms the >253 length check (done in code,
// since RE2 has no lookahead) rejects an otherwise well-formed long name.
func TestIsValidDomain_OverLength(t *testing.T) {
	// ("a"*60 + ".") * 5 + "com"  → 5*61 + 3 = 308 chars, all-valid labels.
	tooLong := strings.Repeat(strings.Repeat("a", 60)+".", 5) + "com"
	if len(tooLong) <= 253 {
		t.Fatalf("test setup: tooLong is only %d chars, expected >253", len(tooLong))
	}
	if isValidDomain(tooLong) {
		t.Errorf("isValidDomain(<%d-char name>) = true, want false (over 253)", len(tooLong))
	}
}

// TestIsValidDomain_Lowercased confirms the validator lowercases its input
// first (mirrors install.sh's `tr A-Z a-z`), so an uppercase FQDN is accepted.
func TestIsValidDomain_Lowercased(t *testing.T) {
	if !isValidDomain("EXAMPLE.COM") {
		t.Errorf("isValidDomain(%q) = false, want true (input must be lowercased first)", "EXAMPLE.COM")
	}
}

// TestBotIsAdmin tests the admin-gate decision in isolation (no live bot):
// IDs in the set are admins, IDs not in the set are not.
func TestBotIsAdmin(t *testing.T) {
	bt := &Bot{admins: map[int64]bool{111: true, 222: true}}
	if !bt.isAdmin(111) {
		t.Errorf("isAdmin(111) = false, want true (in set)")
	}
	if !bt.isAdmin(222) {
		t.Errorf("isAdmin(222) = false, want true (in set)")
	}
	if bt.isAdmin(999) {
		t.Errorf("isAdmin(999) = true, want false (not in set)")
	}
	if bt.isAdmin(0) {
		t.Errorf("isAdmin(0) = true, want false (not in set)")
	}
}

// TestBotIsAdmin_NilSet confirms a nil admins map denies everyone rather than
// panicking (defensive: an empty/unset TGBOT_ADMINS locks the bot down).
func TestBotIsAdmin_NilSet(t *testing.T) {
	bt := &Bot{}
	if bt.isAdmin(111) {
		t.Errorf("isAdmin(111) with nil admins = true, want false")
	}
}

// TestNewBot_DisabledWhenNoToken confirms an empty TGBotToken yields (nil, nil)
// — the bot is disabled, not an error.
func TestNewBot_DisabledWhenNoToken(t *testing.T) {
	cfg := Config{TGBotToken: ""}
	bt, err := NewBot(cfg, nil)
	if err != nil {
		t.Fatalf("NewBot with empty token: unexpected error %v", err)
	}
	if bt != nil {
		t.Errorf("NewBot with empty token = %v, want nil (disabled)", bt)
	}
}

// TestParseCallback confirms the callback-data → intent decision is a pure
// function, dispatchable without a live Telegram connection. This is what makes
// the whole callback router unit-testable: parseCallback classifies the button
// data, and the handler switches on the returned intent.
func TestParseCallback(t *testing.T) {
	cases := []struct {
		data     string
		wantKind callbackKind
		wantArg  string
	}{
		{"menu:main", cbMenuMain, ""},
		{"menu:domains", cbMenuDomains, ""},
		{"act:status", cbStatus, ""},
		{"act:update_lists", cbUpdateLists, ""},
		{"act:reload", cbReload, ""},
		{"dom:add", cbDomAdd, ""},
		{"dom:del", cbDomDel, ""},
		{"", cbUnknown, ""},
		{"garbage", cbUnknown, "garbage"},
		{"act:something_else", cbUnknown, "something_else"},
	}
	for _, c := range cases {
		got := parseCallback(c.data)
		if got.kind != c.wantKind {
			t.Errorf("parseCallback(%q).kind = %v, want %v", c.data, got.kind, c.wantKind)
		}
		if got.arg != c.wantArg {
			t.Errorf("parseCallback(%q).arg = %q, want %q", c.data, got.arg, c.wantArg)
		}
	}
}

// TestDomainOpsRejectBeforeMutate is the Go analogue of tgbot.py's
// TestDomainOpsRejectBeforeShell: an invalid domain must be rejected by
// isValidDomain BEFORE any Controller mutation, so the on-disk rule file is
// never touched (and reload is never called). We build a real Controller over a
// temp rules dir with a reload counter, drive the add/del handlers with an
// invalid domain, and assert the file was not created and reload never ran.
func TestDomainOpsRejectBeforeMutate(t *testing.T) {
	dir := t.TempDir()
	reloadCalls := 0
	ctrl := NewController(nil, func() error { reloadCalls++; return nil }, dir, nil, nil, nil)
	bt := &Bot{ctrl: ctrl, admins: map[int64]bool{1: true}, pending: map[int64]string{}}

	blacklistFile := filepath.Join(dir, "blacklist.txt")

	invalids := []string{"not a domain", "http://x.com", "foo", "_x.com", "bar.com/x"}
	for _, bad := range invalids {
		// Add path.
		msg, ok := bt.applyDomainOp("add_domain", bad)
		if ok {
			t.Errorf("applyDomainOp add %q reported success, want rejection", bad)
		}
		if !strings.Contains(msg, "无效") {
			t.Errorf("applyDomainOp add %q message = %q, want an invalid-domain notice", bad, msg)
		}
		// Del path.
		if _, ok := bt.applyDomainOp("del_domain", bad); ok {
			t.Errorf("applyDomainOp del %q reported success, want rejection", bad)
		}
	}

	if _, err := os.Stat(blacklistFile); !os.IsNotExist(err) {
		t.Errorf("blacklist.txt should not exist after only-invalid ops, stat err = %v", err)
	}
	if reloadCalls != 0 {
		t.Errorf("reload was called %d times on invalid-only ops, want 0", reloadCalls)
	}
}

// TestDomainOpsValidMutates confirms the positive path still works: a valid
// domain flows through to AddRule (file written, reload called), and the
// success message names the domain.
func TestDomainOpsValidMutates(t *testing.T) {
	dir := t.TempDir()
	reloadCalls := 0
	ctrl := NewController(nil, func() error { reloadCalls++; return nil }, dir, nil, nil, nil)
	bt := &Bot{ctrl: ctrl, admins: map[int64]bool{1: true}, pending: map[int64]string{}}

	msg, ok := bt.applyDomainOp("add_domain", "example.com")
	if !ok {
		t.Fatalf("applyDomainOp add valid domain failed: %q", msg)
	}
	if !strings.Contains(msg, "example.com") {
		t.Errorf("success message = %q, want it to name the domain", msg)
	}
	got, err := ctrl.ListRules("blacklist")
	if err != nil {
		t.Fatalf("ListRules: %v", err)
	}
	if len(got) != 1 || got[0] != "example.com" {
		t.Errorf("blacklist after add = %v, want [example.com]", got)
	}
	if reloadCalls != 1 {
		t.Errorf("reload called %d times, want 1", reloadCalls)
	}

	// Remove it again.
	if _, ok := bt.applyDomainOp("del_domain", "example.com"); !ok {
		t.Errorf("applyDomainOp del valid domain reported failure")
	}
	got, _ = ctrl.ListRules("blacklist")
	if len(got) != 0 {
		t.Errorf("blacklist after del = %v, want empty", got)
	}
}

// TestPendingState exercises the per-chat conversational state machine: setting
// a pending action, reading it, and clearing it are all guarded and correct.
func TestPendingState(t *testing.T) {
	bt := &Bot{pending: map[int64]string{}}

	if got, ok := bt.getPending(42); ok || got != "" {
		t.Errorf("getPending on empty = (%q,%v), want (\"\",false)", got, ok)
	}
	bt.setPending(42, "add_domain")
	if got, ok := bt.getPending(42); !ok || got != "add_domain" {
		t.Errorf("getPending after set = (%q,%v), want (\"add_domain\",true)", got, ok)
	}
	// A different chat is unaffected.
	if _, ok := bt.getPending(99); ok {
		t.Errorf("getPending(99) leaked state from chat 42")
	}
	bt.clearPending(42)
	if _, ok := bt.getPending(42); ok {
		t.Errorf("getPending after clear still set")
	}
}

// TestRenderReload covers the reload button's ok/err rendering.
func TestRenderReload(t *testing.T) {
	dir := t.TempDir()
	okCtrl := NewController(nil, func() error { return nil }, dir, nil, nil, nil)
	bt := &Bot{ctrl: okCtrl, pending: map[int64]string{}}
	if out := bt.doReload(context.Background()); !strings.Contains(out, "✅") {
		t.Errorf("doReload success render = %q, want a ✅", out)
	}

	errCtrl := NewController(nil, func() error { return os.ErrPermission }, dir, nil, nil, nil)
	bt2 := &Bot{ctrl: errCtrl, pending: map[int64]string{}}
	if out := bt2.doReload(context.Background()); !strings.Contains(out, "❌") {
		t.Errorf("doReload failure render = %q, want a ❌", out)
	}
}
