package main

import (
	"os"
	"path/filepath"
	"testing"
)

// filesystemSupportsPOSIXModes probes the active filesystem instead of
// assuming support from GOOS. Some mounted or emulated filesystems ignore
// chmod even on Unix, while Windows reports synthesized permission bits.
func filesystemSupportsPOSIXModes(t *testing.T, parent string) bool {
	t.Helper()
	dir := filepath.Join(parent, ".mode-probe")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatalf("create mode probe directory: %v", err)
	}
	defer os.RemoveAll(dir)
	if err := os.Chmod(dir, 0o700); err != nil {
		return false
	}
	info, err := os.Stat(dir)
	if err != nil || info.Mode().Perm() != 0o700 {
		return false
	}
	path := filepath.Join(dir, "probe")
	if err := os.WriteFile(path, []byte("probe"), 0o600); err != nil {
		t.Fatalf("create mode probe file: %v", err)
	}
	info, err = os.Stat(path)
	return err == nil && info.Mode().Perm() == 0o600
}
