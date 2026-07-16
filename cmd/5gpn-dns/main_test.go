package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestApplyTGBotOverrideFailClosed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tgbot.json")
	if err := os.WriteFile(path, []byte("{not-json"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := Config{
		TGBotFile:   path,
		TGBotToken:  "old-token-must-not-revive",
		TGBotAdmins: map[int64]bool{111: true},
	}
	applyTGBotOverride(&cfg)
	if cfg.TGBotToken != "" || len(cfg.TGBotAdmins) != 0 {
		t.Fatalf("malformed override did not fail closed: token=%q admins=%v", cfg.TGBotToken, cfg.TGBotAdmins)
	}
}

func TestApplyTGBotOverrideMissingUsesBootstrap(t *testing.T) {
	cfg := Config{
		TGBotFile:   filepath.Join(t.TempDir(), "missing.json"),
		TGBotToken:  "bootstrap",
		TGBotAdmins: map[int64]bool{111: true},
	}
	applyTGBotOverride(&cfg)
	if cfg.TGBotToken != "bootstrap" || !cfg.TGBotAdmins[111] {
		t.Fatalf("missing override changed bootstrap config: %+v", cfg)
	}
}

// TestLoadRuleSets_EmptyChnrouteTolerated verifies the fresh-install fix: a
// Config pointing at a missing chnroute file plus an empty rules directory
// (i.e. nothing has seeded chnroute yet, and no subscription cache exists)
// must NOT make loadRuleSets fail. Before this fix, LoadChnrouteFiles found no
// CIDRs, returned an error, and main() called log.Fatalf — crash-looping
// forever on a fresh box because the daemon died before the subscription
// manager (which would otherwise fetch and populate chnroute) ever ran.
//
// The fail-safe behavior: loadRuleSets returns a usable ruleset with an empty
// (but non-nil) *Chnroute — every IP looks foreign (routed via proxy) until a
// subscription fetch or manual file populates it, which is safe, not fatal.
func TestLoadRuleSets_EmptyChnrouteTolerated(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{
		RulesDir:     dir, // empty: no block.txt/direct.txt/blacklist.txt/chnroute/*.txt
		ChnrouteFile: filepath.Join(dir, "does-not-exist.txt"),
	}

	sets, err := loadRuleSets(cfg)
	if err != nil {
		t.Fatalf("loadRuleSets returned error for empty/missing chnroute, want nil: %v", err)
	}
	if sets == nil {
		t.Fatal("loadRuleSets returned nil sets with nil error")
	}
	if sets.chnroute == nil {
		t.Fatal("sets.chnroute is nil, want non-nil empty *Chnroute")
	}
	if sets.chnroute.Len() != 0 {
		t.Fatalf("sets.chnroute.Len() = %d, want 0", sets.chnroute.Len())
	}
	// Nil-safe Contains: everything appears foreign (fail-safe -> proxied).
	if sets.chnroute.Contains(net.ParseIP("1.2.3.4")) {
		t.Fatal("empty chnroute must not claim any IP as CN")
	}
}

func TestLoadRuleSets_PerTypeFiles(t *testing.T) {
	dir := t.TempDir()
	must := func(name, content string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	must("blacklist.txt", "suf.example.com\n")       // suffix (bare)
	must("blacklist.exact.txt", "api.example.com\n") // exact
	must("blacklist.keyword.txt", "trackme\n")       // keyword
	must("blacklist.prefix.txt", "ads\n")            // prefix

	cfg := Config{RulesDir: dir}
	sets, err := loadRuleSets(cfg)
	if err != nil {
		t.Fatal(err)
	}
	bl := sets.blacklist
	if !bl.Match("x.suf.example.com") {
		t.Error("suffix entry not loaded")
	}
	if !bl.Match("api.example.com") || bl.Match("x.api.example.com") {
		t.Error("exact entry not loaded as exact")
	}
	if !bl.Match("mytrackme.net") {
		t.Error("keyword entry not loaded")
	}
	if !bl.Match("ads.example.com") {
		t.Error("prefix entry not loaded")
	}
}

// TestLoadRuleSets_ManualChnrouteLoaded verifies that the manual chnroute.txt
// the :9443 API / Telegram bot / web console write (via
// Controller.manualRulePath("chnroute", …) → rulesDir/chnroute.txt) is actually
// picked up by loadRuleSets. This regresses a silent no-op: the load path used
// to be `cfg.ChnrouteFile + rulesDir/chnroute/*.txt` only, so a manual "China
// route" add was persisted and listed but never applied to CN classification.
func TestLoadRuleSets_ManualChnrouteLoaded(t *testing.T) {
	dir := t.TempDir()
	// The manual file the Controller writes — note NO cfg.ChnrouteFile is set,
	// so this also covers "DNS_CHNROUTE unset must not skip chnroute loading".
	if err := os.WriteFile(filepath.Join(dir, "chnroute.txt"), []byte("203.0.113.0/24\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := Config{RulesDir: dir} // ChnrouteFile deliberately empty
	sets, err := loadRuleSets(cfg)
	if err != nil {
		t.Fatalf("loadRuleSets: %v", err)
	}
	if sets.chnroute == nil || !sets.chnroute.Contains(net.ParseIP("203.0.113.10")) {
		t.Fatal("manual rulesDir/chnroute.txt CIDR not loaded — a manual China-route add is a silent no-op")
	}
	if sets.chnroute.Contains(net.ParseIP("198.51.100.1")) {
		t.Fatal("chnroute matched an out-of-range IP")
	}
}

// TestLoadRuleSets_ChnrouteSubdirLoadedWithoutPin verifies subscription caches
// under rulesDir/chnroute/*.txt load even when cfg.ChnrouteFile (DNS_CHNROUTE)
// is unset — previously the whole block was gated on ChnrouteFile != "".
func TestLoadRuleSets_ChnrouteSubdirLoadedWithoutPin(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "chnroute")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "china_ip_list.txt"), []byte("110.0.0.0/8\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := Config{RulesDir: dir} // ChnrouteFile empty
	sets, err := loadRuleSets(cfg)
	if err != nil {
		t.Fatalf("loadRuleSets: %v", err)
	}
	if sets.chnroute == nil || !sets.chnroute.Contains(net.ParseIP("110.1.2.3")) {
		t.Fatal("subscription-cache chnroute/*.txt not loaded when DNS_CHNROUTE unset")
	}
}
