//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadTGBotRejectsLoosePermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tgbot.json")
	if err := os.WriteFile(path, []byte(`{"version":1,"token":"secret","admins":[1]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadTGBot(path); err == nil {
		t.Fatal("LoadTGBot accepted a group/world-readable token file")
	}
}
