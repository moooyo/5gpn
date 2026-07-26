package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// bumpAll bumps every counter field in s to a distinct, easily-verified value
// (field index * 10 + 1) so a round-trip test can catch any field being
// swapped or dropped.
func bumpAllStats(s *statsCounters) {
	s.total.Store(11)
	s.block.Store(21)
	s.forceDirect.Store(31)
	s.forceProxy.Store(41)
	s.chnrouteCN.Store(51)
	s.chnrouteForeign.Store(61)
	s.chinaOK.Store(71)
	s.chinaErr.Store(81)
	s.trustOK.Store(91)
	s.trustErr.Store(101)
	// The observability counters are persisted and restored like the rest, so
	// they belong in the round-trip fixture too — without them a field could be
	// dropped from save or restore and every test here would still pass.
	s.cacheHits.Store(111)
	s.cacheMisses.Store(121)
	s.chinaLatNanos.Store(131)
	s.chinaLatCount.Store(141)
	s.trustLatNanos.Store(151)
	s.trustLatCount.Store(161)
}

func TestStatsPersist_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stats.json")

	src := &statsCounters{}
	bumpAllStats(src)

	if err := SaveStats(path, src); err != nil {
		t.Fatalf("SaveStats: %v", err)
	}

	dst := &statsCounters{}
	if err := LoadStats(path, dst); err != nil {
		t.Fatalf("LoadStats: %v", err)
	}

	want := src.snapshot()
	got := dst.snapshot()
	if got != want {
		t.Errorf("round-trip snapshot mismatch:\n got  %+v\n want %+v", got, want)
	}
}

func TestStatsPersist_MissingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "does-not-exist.json")

	s := &statsCounters{}
	if err := LoadStats(path, s); err != nil {
		t.Fatalf("LoadStats on missing file: got error %v, want nil", err)
	}

	zero := statsSnapshot{}
	if got := s.snapshot(); got != zero {
		t.Errorf("counters after missing-file load = %+v, want zero %+v", got, zero)
	}
}

func TestStatsPersist_MalformedFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stats.json")
	if err := os.WriteFile(path, []byte("{not valid json"), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	s := &statsCounters{}
	err := LoadStats(path, s)
	if err == nil {
		t.Fatal("LoadStats on malformed file: got nil error, want non-nil")
	}

	zero := statsSnapshot{}
	if got := s.snapshot(); got != zero {
		t.Errorf("counters after malformed-file load = %+v, want unchanged zero %+v", got, zero)
	}
}

func TestStatsPersist_EmptyPath(t *testing.T) {
	s := &statsCounters{}
	bumpAllStats(s)

	if err := LoadStats("", s); err != nil {
		t.Errorf("LoadStats(\"\", s) = %v, want nil", err)
	}
	if err := SaveStats("", s); err != nil {
		t.Errorf("SaveStats(\"\", s) = %v, want nil", err)
	}
}

func TestStatsPersist_NilCounters(t *testing.T) {
	if err := SaveStats("/tmp/should-not-be-created.json", nil); err != nil {
		t.Errorf("SaveStats(path, nil) = %v, want nil", err)
	}
	if _, err := os.Stat("/tmp/should-not-be-created.json"); err == nil {
		t.Error("SaveStats(path, nil) created a file, want no-op")
		os.Remove("/tmp/should-not-be-created.json")
	}
}

func TestStatsPersist_Atomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stats.json")

	s := &statsCounters{}
	bumpAllStats(s)

	if err := SaveStats(path, s); err != nil {
		t.Fatalf("SaveStats: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
		if filepath.Ext(e.Name()) == ".tmp" || matchTmpGlob(e.Name()) {
			t.Errorf("leftover temp file found: %s", e.Name())
		}
	}
	if len(names) != 1 || names[0] != "stats.json" {
		t.Errorf("dir contents = %v, want exactly [stats.json]", names)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	var snap statsSnapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		t.Errorf("saved file is not valid JSON: %v", err)
	}
}

// matchTmpGlob reports whether name looks like one of our temp-file patterns
// (".stats-*.tmp" style), independent of the exact prefix chosen.
func matchTmpGlob(name string) bool {
	matched, _ := filepath.Match("*.tmp*", name)
	return matched
}

func TestStatsPersist_PersisterFinalSaveOnCancel(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stats.json")

	s := &statsCounters{}
	s.total.Store(42)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled: persister should do exactly one final save and return.

	done := make(chan struct{})
	go func() {
		RunStatsPersister(ctx, path, s, 20*time.Millisecond)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("RunStatsPersister did not return after ctx cancel")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("expected final save to have written %s: %v", path, err)
	}
	var snap statsSnapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		t.Fatalf("final save file not valid JSON: %v", err)
	}
	if snap.Total != 42 {
		t.Errorf("final save Total = %d, want 42", snap.Total)
	}
}

func TestStatsPersist_PersisterDisabled(t *testing.T) {
	s := &statsCounters{}
	s.total.Store(1)

	done := make(chan struct{})
	go func() {
		// Empty path → should return immediately regardless of ctx state.
		RunStatsPersister(context.Background(), "", s, time.Hour)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("RunStatsPersister with empty path did not return immediately")
	}

	done2 := make(chan struct{})
	go func() {
		// Nil stats → should also return immediately.
		RunStatsPersister(context.Background(), filepath.Join(t.TempDir(), "x.json"), nil, time.Hour)
		close(done2)
	}()
	select {
	case <-done2:
	case <-time.After(2 * time.Second):
		t.Fatal("RunStatsPersister with nil stats did not return immediately")
	}
}

// The counters are cumulative since first boot, so an operator's only escape
// from a skewed average used to be stopping the daemon and deleting the file.
// reset() zeroes every field — asserted against the zero snapshot rather than
// field by field, so a counter added later cannot be forgotten here.
func TestStatsReset_ZeroesEveryCounter(t *testing.T) {
	s := &statsCounters{}
	bumpAllStats(s)
	if s.snapshot() == (statsSnapshot{}) {
		t.Fatal("fixture did not bump anything; the test would pass vacuously")
	}

	s.reset()

	if got := s.snapshot(); got != (statsSnapshot{}) {
		t.Errorf("reset left counters set: %+v", got)
	}
}

func TestStatsReset_NilCountersDoesNotPanic(t *testing.T) {
	var s *statsCounters
	s.reset()
}

// A reset that lived only in memory would be undone by the next restart, since
// boot restores from this file. ResetStats must write it straight away rather
// than wait for the persister's tick.
func TestControllerResetStats_PersistsImmediately(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stats.json")
	s := &statsCounters{}
	bumpAllStats(s)
	if err := SaveStats(path, s); err != nil {
		t.Fatalf("SaveStats: %v", err)
	}

	c := NewController(func() error { return nil }, s, nil, nil)
	c.SetStatsFile(path)
	if err := c.ResetStats(); err != nil {
		t.Fatalf("ResetStats: %v", err)
	}

	if got := s.snapshot(); got != (statsSnapshot{}) {
		t.Errorf("in-memory counters not zeroed: %+v", got)
	}
	// Reload from disk exactly as boot would.
	restored := &statsCounters{}
	if err := LoadStats(path, restored); err != nil {
		t.Fatalf("LoadStats: %v", err)
	}
	if got := restored.snapshot(); got != (statsSnapshot{}) {
		t.Errorf("reset did not survive a reload — a restart would resurrect the old numbers: %+v", got)
	}
}

// Persistence disabled (DNS_STATS_FILE=""): the reset is memory-only, must
// succeed, and must not create a file at some guessed default path.
func TestControllerResetStats_PersistenceDisabled(t *testing.T) {
	dir := t.TempDir()
	s := &statsCounters{}
	bumpAllStats(s)

	c := NewController(func() error { return nil }, s, nil, nil)
	if err := c.ResetStats(); err != nil {
		t.Fatalf("ResetStats with no stats file: %v", err)
	}
	if got := s.snapshot(); got != (statsSnapshot{}) {
		t.Errorf("counters not zeroed: %+v", got)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("reset wrote %d file(s) with persistence disabled", len(entries))
	}
}

// A nil stats pointer is valid (Controllers built without stats wiring).
func TestControllerResetStats_NilStats(t *testing.T) {
	c := NewController(func() error { return nil }, nil, nil, nil)
	if err := c.ResetStats(); err != nil {
		t.Fatalf("ResetStats with nil stats: %v", err)
	}
}

// An unwritable path must surface an error, because the in-memory counters are
// already zero by then: reporting success would tell the operator the reset is
// durable when a restart will undo it.
func TestControllerResetStats_ReportsPersistFailure(t *testing.T) {
	s := &statsCounters{}
	bumpAllStats(s)
	c := NewController(func() error { return nil }, s, nil, nil)
	// A path whose parent is a regular file can never be written on any OS.
	parent := filepath.Join(t.TempDir(), "notadir")
	if err := os.WriteFile(parent, []byte("x"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	c.SetStatsFile(filepath.Join(parent, "stats.json"))

	err := c.ResetStats()
	if err == nil {
		t.Fatal("expected an error when the reset cannot be persisted")
	}
	if got := s.snapshot(); got != (statsSnapshot{}) {
		t.Errorf("counters must still be zeroed in memory even when the write fails: %+v", got)
	}
}
