package main

import (
	"net"
	"path/filepath"
	"testing"
)

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
		RulesDir:     dir, // empty: no adblock.txt/direct.txt/blacklist.txt/chnroute/*.txt
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
