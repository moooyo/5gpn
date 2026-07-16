package main

import (
	"os"
	"path/filepath"
	"testing"
)

// writeTempFile creates a temp file with content and returns its path.
func writeTempFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("writeTempFile: %v", err)
	}
	return p
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestDomainSetExactMatch(t *testing.T) {
	dir := t.TempDir()
	p := writeTempFile(t, dir, "rules.txt", "example.com\n")
	ds, err := LoadDomainSet(p)
	if err != nil {
		t.Fatal(err)
	}
	if !ds.Match("example.com") {
		t.Error("exact match: want true for example.com")
	}
}

func TestDomainSetParentDomainMatch(t *testing.T) {
	dir := t.TempDir()
	p := writeTempFile(t, dir, "rules.txt", "example.com\n")
	ds, err := LoadDomainSet(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sub.example.com", "a.b.example.com"} {
		if !ds.Match(name) {
			t.Errorf("parent-domain match: want true for %s", name)
		}
	}
}

func TestDomainSetNonMatchTrap(t *testing.T) {
	// "notexample.com" must NOT match "example.com" — the canonical trap for HasSuffix.
	dir := t.TempDir()
	p := writeTempFile(t, dir, "rules.txt", "example.com\n")
	ds, err := LoadDomainSet(p)
	if err != nil {
		t.Fatal(err)
	}
	if ds.Match("notexample.com") {
		t.Error("non-match trap: want false for notexample.com against example.com")
	}
}

func TestDomainSetCaseInsensitivity(t *testing.T) {
	dir := t.TempDir()
	p := writeTempFile(t, dir, "rules.txt", "Example.COM\n")
	ds, err := LoadDomainSet(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"example.com", "EXAMPLE.COM", "Sub.Example.Com"} {
		if !ds.Match(name) {
			t.Errorf("case-insensitivity: want true for %s", name)
		}
	}
}

func TestDomainSetTrailingDotNormalization(t *testing.T) {
	dir := t.TempDir()
	// File has trailing dot in the stored entry.
	p := writeTempFile(t, dir, "rules.txt", "example.com.\n")
	ds, err := LoadDomainSet(p)
	if err != nil {
		t.Fatal(err)
	}
	// Query with and without trailing dot must both match.
	for _, name := range []string{"example.com", "example.com.", "sub.example.com"} {
		if !ds.Match(name) {
			t.Errorf("trailing-dot normalization: want true for %s", name)
		}
	}
}

func TestDomainSetEmptySet(t *testing.T) {
	dir := t.TempDir()
	p := writeTempFile(t, dir, "rules.txt", "# just a comment\n\n")
	ds, err := LoadDomainSet(p)
	if err != nil {
		t.Fatal(err)
	}
	if ds.Len() != 0 {
		t.Errorf("empty set: want Len 0, got %d", ds.Len())
	}
	if ds.Match("example.com") {
		t.Error("empty set: want Match false")
	}
}

func TestDomainSetMissingFileSkipped(t *testing.T) {
	// A path that does not exist must be silently skipped (not an error).
	ds, err := LoadDomainSet("/nonexistent/path/that/does/not/exist.txt")
	if err != nil {
		t.Fatalf("missing file must be skipped, got error: %v", err)
	}
	if ds.Len() != 0 {
		t.Errorf("want Len 0 for missing-file set, got %d", ds.Len())
	}
}

func TestDomainSetMultipleFiles(t *testing.T) {
	dir := t.TempDir()
	p1 := writeTempFile(t, dir, "a.txt", "example.com\n")
	p2 := writeTempFile(t, dir, "b.txt", "test.org\n")
	ds, err := LoadDomainSet(p1, p2)
	if err != nil {
		t.Fatal(err)
	}
	if ds.Len() != 2 {
		t.Errorf("multi-file: want Len 2, got %d", ds.Len())
	}
	if !ds.Match("sub.example.com") {
		t.Error("multi-file: want match for sub.example.com")
	}
	if !ds.Match("test.org") {
		t.Error("multi-file: want match for test.org")
	}
}

func TestDomainSetCommentsAndBlankLines(t *testing.T) {
	dir := t.TempDir()
	content := "# block list\nexample.com\n\n# more\nbad.net\n"
	p := writeTempFile(t, dir, "rules.txt", content)
	ds, err := LoadDomainSet(p)
	if err != nil {
		t.Fatal(err)
	}
	if ds.Len() != 2 {
		t.Errorf("comments: want Len 2, got %d", ds.Len())
	}
}
