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
