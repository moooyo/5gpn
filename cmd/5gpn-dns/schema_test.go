package main

import (
	"os"
	"path/filepath"
	"testing"
)

// #34: a subscriptions.json written by a newer binary (higher schema version)
// still loads its known fields rather than failing like corruption.
func TestSubscriptionsForwardCompatSchema(t *testing.T) {
	p := filepath.Join(t.TempDir(), "subscriptions.json")
	doc := `{"version":99,"subscriptions":[{"id":"s1","category":"direct","name":"n1","url":"https://e.test/x","format":"plain","enabled":true,"interval":"1h"}]}`
	if err := os.WriteFile(p, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	subs, err := LoadSubscriptions(p)
	if err != nil {
		t.Fatalf("LoadSubscriptions on a newer schema should not error: %v", err)
	}
	if len(subs) != 1 || subs[0].ID != "s1" {
		t.Errorf("want the known subscription s1 to load, got %v", subs)
	}
}

// #34: a stats.json from a newer binary restores the counters it understands
// without erroring.
func TestStatsForwardCompatSchema(t *testing.T) {
	p := filepath.Join(t.TempDir(), "stats.json")
	doc := `{"version":99,"total":42,"cache_hits":7,"some_future_field":123}`
	if err := os.WriteFile(p, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	s := &statsCounters{}
	if err := LoadStats(p, s); err != nil {
		t.Fatalf("LoadStats on a newer schema should not error: %v", err)
	}
	if got := s.total.Load(); got != 42 {
		t.Errorf("total = %d, want 42 (known field restored)", got)
	}
}
