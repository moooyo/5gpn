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

// writeFile writes content to an explicit path (used by the typed-DomainSet tests below).
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

func TestDomainSet_ExactMatch(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "exact.txt"), "api.example.com\n")
	ds, err := LoadDomainSetTyped(fileSpec{filepath.Join(dir, "exact.txt"), MatchExact})
	if err != nil {
		t.Fatal(err)
	}
	if !ds.Match("api.example.com") {
		t.Error("exact should match api.example.com")
	}
	if ds.Match("x.api.example.com") {
		t.Error("exact must NOT match a subdomain")
	}
	if ds.Match("example.com") {
		t.Error("exact must NOT match the parent")
	}
}

func TestDomainSet_KeywordMatch(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "keyword.txt"), "google\n")
	ds, err := LoadDomainSetTyped(fileSpec{filepath.Join(dir, "keyword.txt"), MatchKeyword})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"www.google.com", "googlevideo.com", "mygoogleapi.net"} {
		if !ds.Match(name) {
			t.Errorf("keyword google should match %s", name)
		}
	}
	if ds.Match("example.com") {
		t.Error("keyword google must not match example.com")
	}
}

func TestDomainSet_PrefixMatch(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "prefix.txt"), "ads\n")
	ds, err := LoadDomainSetTyped(fileSpec{filepath.Join(dir, "prefix.txt"), MatchPrefix})
	if err != nil {
		t.Fatal(err)
	}
	if !ds.Match("ads.example.com") || !ds.Match("adservice.com") {
		t.Error("prefix ads should match ads.* and adservice.com")
	}
	if ds.Match("x-ads.com") {
		t.Error("prefix ads must not match x-ads.com")
	}
}

func TestDomainSet_SuffixStillLabelBounded(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "suffix.txt"), "example.com\n")
	ds, err := LoadDomainSetTyped(fileSpec{filepath.Join(dir, "suffix.txt"), MatchSuffix})
	if err != nil {
		t.Fatal(err)
	}
	if !ds.Match("example.com") || !ds.Match("a.b.example.com") {
		t.Error("suffix should match self and subdomains")
	}
	if ds.Match("notexample.com") {
		t.Error("suffix must not match notexample.com")
	}
}

func TestDomainSet_MergedTypesAndLen(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "s.txt"), "example.com\n")
	writeFile(t, filepath.Join(dir, "e.txt"), "api.test.com\n")
	writeFile(t, filepath.Join(dir, "k.txt"), "ads\n")
	ds, err := LoadDomainSetTyped(
		fileSpec{filepath.Join(dir, "s.txt"), MatchSuffix},
		fileSpec{filepath.Join(dir, "e.txt"), MatchExact},
		fileSpec{filepath.Join(dir, "k.txt"), MatchKeyword},
	)
	if err != nil {
		t.Fatal(err)
	}
	if ds.Len() != 3 {
		t.Errorf("Len = %d, want 3", ds.Len())
	}
	if !ds.Match("x.example.com") || !ds.Match("api.test.com") || !ds.Match("trackads.net") {
		t.Error("merged set should match all three type entries")
	}
}
