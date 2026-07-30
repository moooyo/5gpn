package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runInstallerCredentialAlign(t *testing.T, mihomo string, intercept []byte) (int, string, string) {
	t.Helper()
	dir := t.TempDir()
	mihomoPath := filepath.Join(dir, "config.yaml")
	interceptPath := filepath.Join(dir, "intercept.json")
	if err := os.WriteFile(mihomoPath, []byte(mihomo), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(interceptPath, intercept, 0o600); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := runInterceptionCredentialAlign([]string{
		"--mihomo-config", mihomoPath,
		"--intercept-config", interceptPath,
	}, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

// A preserved operator config carrying the previous credentials is exactly the
// state that aborted publication with `credential-mismatch`. Aligning it must
// make the routing check pass.
func TestInterceptionCredentialAlignRepairsAMismatch(t *testing.T) {
	document := installerRoutingCheckDocument()
	seed := currentInstallerRoutingSeed(t, document)
	stale := strings.Replace(seed, document.Password, "previous-sidecar-password-0123456789", 1)
	stale = strings.Replace(stale, document.UpstreamProxy.Username, "previous-upstream-user-012345", 1)
	if stale == seed {
		t.Fatal("fixture did not introduce a credential mismatch")
	}
	intercept := mustMarshalInstallerInterceptConfig(t, document)

	if code, _, _ := runInstallerRoutingCheck(t, stale, intercept); code != 3 {
		t.Fatalf("stale config was expected to fail the routing check, got code=%d", code)
	}

	code, aligned, stderr := runInstallerCredentialAlign(t, stale, intercept)
	if code != 0 || stderr != "" {
		t.Fatalf("align code=%d stderr=%q", code, stderr)
	}
	if !interceptCredentialsMatch(aligned, document) {
		t.Fatal("aligned config still does not carry the truth-source credentials")
	}
	if code, stdout, _ := runInstallerRoutingCheck(t, aligned, intercept); code != 0 || stdout != "ready\n" {
		t.Fatalf("aligned config did not become ready: code=%d stdout=%q", code, stdout)
	}
}

// Re-serializing the document would reformat an operator's file. Only the lines
// carrying the four credential scalars may differ.
func TestInterceptionCredentialAlignTouchesOnlyCredentialLines(t *testing.T) {
	document := installerRoutingCheckDocument()
	seed := currentInstallerRoutingSeed(t, document)
	stale := strings.Replace(seed, document.Password, "previous-sidecar-password-0123456789", 1)
	stale = strings.Replace(stale, document.UpstreamProxy.Password, "previous-upstream-password-0123456789", 1)

	_, aligned, _ := runInstallerCredentialAlign(t, stale, mustMarshalInstallerInterceptConfig(t, document))
	before := strings.Split(stale, "\n")
	after := strings.Split(aligned, "\n")
	if len(before) != len(after) {
		t.Fatalf("line count changed: %d -> %d", len(before), len(after))
	}
	changed := 0
	for i := range before {
		if before[i] == after[i] {
			continue
		}
		changed++
		if !strings.Contains(after[i], "password:") && !strings.Contains(after[i], "username:") {
			t.Fatalf("line %d changed but carries no credential: %q -> %q", i+1, before[i], after[i])
		}
	}
	if changed != 2 {
		t.Fatalf("expected exactly the 2 stale credential lines to change, got %d", changed)
	}
}

// An already-aligned config must come back byte-identical, so the installer can
// compare and skip the write entirely.
func TestInterceptionCredentialAlignIsAByteIdenticalNoop(t *testing.T) {
	document := installerRoutingCheckDocument()
	seed := currentInstallerRoutingSeed(t, document)
	code, aligned, stderr := runInstallerCredentialAlign(t, seed, mustMarshalInstallerInterceptConfig(t, document))
	if code != 0 || stderr != "" {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	if aligned != seed {
		t.Fatal("an already-aligned config was rewritten")
	}
}

// A flow mapping puts all four scalars on two lines. Everything around them --
// flow punctuation, sibling keys, a trailing comment -- has to survive.
func TestInterceptionCredentialAlignPreservesLineShape(t *testing.T) {
	line := "  - {name: intercept-egress, users: [{username: old-user-0123456, password: p}]} # keep"
	column := strings.Index(line, "old-user-0123456")
	got, err := replaceScalarAt(line, column, "old-user-0123456", "new-user-0123456789")
	if err != nil {
		t.Fatal(err)
	}
	want := "  - {name: intercept-egress, users: [{username: new-user-0123456789, password: p}]} # keep"
	if got != want {
		t.Fatalf("unexpected rewrite:\n got %q\nwant %q", got, want)
	}
}

// The marks and the text must agree. If they do not, aborting is the only safe
// move -- a guess here writes a corrupt config over an operator's file.
func TestInterceptionCredentialAlignRefusesAMisalignedMark(t *testing.T) {
	if _, err := replaceScalarAt("username: actual", 0, "expected", "replacement-0123456"); err == nil {
		t.Fatal("rewrote a position that did not hold the parsed value")
	}
	if _, err := replaceScalarAt("short", 3, "way-too-long-to-fit", "replacement-0123456"); err == nil {
		t.Fatal("rewrote past the end of a line")
	}
}

// A quoted scalar's mark covers the delimiter while Value does not, so the
// position check would not line up. Fail closed rather than guess at quoting.
func TestInterceptionCredentialAlignRefusesQuotedScalars(t *testing.T) {
	document := installerRoutingCheckDocument()
	quoted := `listeners:
  - {name: intercept-egress, type: socks, port: 17890, users: [{username: "stale-user-01234567", password: stale-password-0123456789}]}
proxies:
  - {name: ` + interceptMihomoProxyName + `, type: socks5, server: 127.0.0.1, port: 18080, username: stale-user-01234567, password: stale-password-0123456789}
`
	if _, err := alignInterceptCredentialLines(quoted, document); err == nil {
		t.Fatal("a quoted scalar was rewritten in place")
	}
}

func TestInterceptionCredentialAlignRejectsUnsafeValues(t *testing.T) {
	for _, value := range []string{"", "short", "has space in it here", "quote\"inside-value", strings.Repeat("a", 256)} {
		if validInterceptCredentialValue(value) {
			t.Fatalf("accepted an unsafe credential value: %q", value)
		}
	}
	if !validInterceptCredentialValue("safe-value_0123456789.abc") {
		t.Fatal("rejected a credential that install.sh would render")
	}
}
