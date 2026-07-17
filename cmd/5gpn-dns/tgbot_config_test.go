package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestTGBotConfig_SaveLoadRoundtrip: a saved tgbot.json round-trips, is written
// 0600 (it holds the bot token), and its admin IDs come back normalized.
func TestTGBotConfig_SaveLoadRoundtrip(t *testing.T) {
	f := filepath.Join(t.TempDir(), "tgbot.json")

	// A missing file is not an error — dns.env values apply.
	if tc, err := LoadTGBot(f); err != nil || tc != nil {
		t.Fatalf("missing file: got (%+v, %v), want (nil, nil)", tc, err)
	}

	in := TGBotConfig{Token: "secret-token", Admins: []int64{333, 111, 111, 0, -5, 222}}
	if err := SaveTGBot(f, in); err != nil {
		t.Fatalf("SaveTGBot: %v", err)
	}

	// 0600 — the file holds a secret when the filesystem enforces POSIX modes.
	if filesystemSupportsPOSIXModes(t, filepath.Dir(f)) {
		fi, err := os.Stat(f)
		if err != nil {
			t.Fatalf("stat: %v", err)
		}
		if perm := fi.Mode().Perm(); perm != 0o600 {
			t.Errorf("tgbot.json mode = %o, want 600 (holds the token)", perm)
		}
	}

	out, err := LoadTGBot(f)
	if err != nil || out == nil {
		t.Fatalf("LoadTGBot: got (%+v, %v)", out, err)
	}
	if out.Token != "secret-token" {
		t.Errorf("token = %q, want %q", out.Token, "secret-token")
	}
	// Normalized: dedup, drop <= 0, sorted.
	if want := []int64{111, 222, 333}; !reflect.DeepEqual(out.Admins, want) {
		t.Errorf("admins = %v, want %v", out.Admins, want)
	}
	if out.Version != tgbotSchemaVersion {
		t.Errorf("version = %d, want %d", out.Version, tgbotSchemaVersion)
	}
}

func TestLoadTGBotRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target.json")
	link := filepath.Join(dir, "tgbot.json")
	if err := os.WriteFile(target, []byte(`{"version":1,"token":"secret","admins":[1]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if _, err := LoadTGBot(link); err == nil {
		t.Fatal("LoadTGBot accepted a symlink")
	}
}

// TestTGBotConfig_EmptyPathNoop: an empty path disables persistence — Save is a
// no-op and Load returns (nil, nil).
func TestTGBotConfig_EmptyPathNoop(t *testing.T) {
	if err := SaveTGBot("", TGBotConfig{Token: "x"}); err != nil {
		t.Errorf("SaveTGBot(\"\") = %v, want nil (no-op)", err)
	}
	if tc, err := LoadTGBot(""); err != nil || tc != nil {
		t.Errorf("LoadTGBot(\"\") = (%+v, %v), want (nil, nil)", tc, err)
	}
}

func TestNormalizeAdminIDs(t *testing.T) {
	got := normalizeAdminIDs([]int64{5, 5, -1, 0, 3, 10, 3})
	if want := []int64{3, 5, 10}; !reflect.DeepEqual(got, want) {
		t.Errorf("normalizeAdminIDs = %v, want %v", got, want)
	}
	// Set <-> slice helpers round-trip through normalization.
	set := adminSetFromIDs([]int64{7, 2, 2, 0})
	if ids := adminIDsFromSet(set); !reflect.DeepEqual(ids, []int64{2, 7}) {
		t.Errorf("adminIDsFromSet = %v, want [2 7]", ids)
	}
}
