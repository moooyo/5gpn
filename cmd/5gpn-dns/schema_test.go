package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPersistentJSONRejectsVersionAndShapeDrift(t *testing.T) {
	tests := []struct {
		name string
		doc  string
		load func(string) error
	}{
		{"subscriptions missing version", `{"subscriptions":[]}`, func(p string) error { _, err := LoadSubscriptions(p); return err }},
		{"subscriptions future version", `{"version":99,"subscriptions":[]}`, func(p string) error { _, err := LoadSubscriptions(p); return err }},
		{"subscriptions unknown field", `{"version":1,"subscriptions":[],"extra":1}`, func(p string) error { _, err := LoadSubscriptions(p); return err }},
		{"stats missing version", `{"total":1}`, func(p string) error { return LoadStats(p, &statsCounters{}) }},
		{"stats future version", `{"version":99,"total":1}`, func(p string) error { return LoadStats(p, &statsCounters{}) }},
		{"stats unknown field", `{"version":1,"extra":1}`, func(p string) error { return LoadStats(p, &statsCounters{}) }},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "state.json")
			if err := os.WriteFile(p, []byte(tc.doc), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := tc.load(p); err == nil {
				t.Fatal("invalid persistent JSON was accepted")
			}
		})
	}
}
