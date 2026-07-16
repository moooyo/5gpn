package main

import (
	"strings"
	"testing"

	"github.com/go-telegram/bot/models"
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

func TestBotReplaceAdmins(t *testing.T) {
	bt := &Bot{admins: map[int64]bool{111: true}}
	bt.ReplaceAdmins([]int64{222, 222, -1})
	if bt.isAdmin(111) || !bt.isAdmin(222) || bt.isAdmin(-1) {
		t.Fatalf("ReplaceAdmins did not atomically replace the effective set: %v", bt.adminIDs())
	}
}

func TestIsPrivateUpdate(t *testing.T) {
	privateMessage := &models.Update{Message: &models.Message{Chat: models.Chat{ID: 1, Type: models.ChatTypePrivate}}}
	groupMessage := &models.Update{Message: &models.Message{Chat: models.Chat{ID: -1, Type: models.ChatTypeGroup}}}
	privateCallback := &models.Update{CallbackQuery: &models.CallbackQuery{
		Message: models.MaybeInaccessibleMessage{
			Type:    models.MaybeInaccessibleMessageTypeMessage,
			Message: &models.Message{Chat: models.Chat{ID: 1, Type: models.ChatTypePrivate}},
		},
	}}
	for name, tc := range map[string]struct {
		update *models.Update
		want   bool
	}{
		"private message":  {privateMessage, true},
		"group message":    {groupMessage, false},
		"private callback": {privateCallback, true},
		"nil":              {nil, false},
	} {
		t.Run(name, func(t *testing.T) {
			if got := isPrivateUpdate(tc.update); got != tc.want {
				t.Fatalf("isPrivateUpdate() = %v, want %v", got, tc.want)
			}
		})
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
		{versionedCallback("menu:main"), cbMenuMain, ""},
		{versionedCallback("act:status"), cbStatus, ""},
		{versionedCallback("menu:upstreams"), cbUpstreams, ""},
		{versionedCallback("act:reload"), cbReload, ""},
		{"", cbUnknown, ""},
		{"garbage", cbUnknown, "garbage"},
		{versionedCallback("act:something_else"), cbUnknown, "something_else"},
		{"menu:main", cbUnknown, "menu:main"},
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

// TestDoUpstreams renders the read-only upstream view. With a Controller that has
// no live handler snapshot, GetUpstreams returns empty lists, so the view shows
// both group labels and the "（未配置）" placeholder — and must never panic.
func TestDoUpstreams(t *testing.T) {
	bt := &Bot{ctrl: &Controller{}}
	out := bt.doUpstreams()
	for _, want := range []string{"上游 DNS", "境内组", "境外组", "未配置"} {
		if !strings.Contains(out, want) {
			t.Errorf("doUpstreams() missing %q; got:\n%s", want, out)
		}
	}
}

// TestRenderUpstreamList: a non-empty spec list renders one per line inside a
// <pre> block (HTML-escaped); an empty list renders the placeholder.
func TestRenderUpstreamList(t *testing.T) {
	if got := renderUpstreamList(nil); !strings.Contains(got, "未配置") {
		t.Errorf("empty list should render the placeholder, got %q", got)
	}
	got := renderUpstreamList([]string{"223.5.5.5", "dns.google@8.8.8.8"})
	if !strings.Contains(got, "223.5.5.5") || !strings.Contains(got, "dns.google@8.8.8.8") {
		t.Errorf("list should contain both specs, got %q", got)
	}
}
