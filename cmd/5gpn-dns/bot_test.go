package main

import (
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
