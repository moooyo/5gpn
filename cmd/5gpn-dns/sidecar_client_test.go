package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// End-to-end against the real sidecar binary.
//
// The coordinator and the sidecar are separately built modules that share no
// Go types — the wire format is the only thing holding them together. A test
// with a hand-rolled stub server would agree with whatever this package
// believes; only the actual binary can disagree, which is the whole point.
//
// Build the sidecar first:
//
//	(cd ../../plugin-sidecar && go build -o /tmp/5gpn-intercept .)
//	SIDECAR_BINARY=/tmp/5gpn-intercept go test -run Sidecar ./...

const sidecarBinaryEnv = "SIDECAR_BINARY"

func startRealSidecar(t *testing.T) (*SidecarClient, string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the sidecar's control socket needs a unix platform")
	}
	binary := os.Getenv(sidecarBinaryEnv)
	if binary == "" {
		t.Skipf("set %s to the built sidecar to run the end-to-end control API test", sidecarBinaryEnv)
	}

	dir := t.TempDir()
	socket := filepath.Join(dir, "control.sock")
	// A bootstrap document so the sidecar can start before anything is pushed.
	// This is the migration state: file-configured, API-capable.
	bootstrap := filepath.Join(dir, "config.json")
	raw, err := os.ReadFile(filepath.Join("..", "..", "plugin-sidecar", "testdata", "bundle.json"))
	if err != nil {
		t.Skipf("sidecar fixture unavailable: %v", err)
	}
	if err := os.WriteFile(bootstrap, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, binary,
		"--config", bootstrap,
		"--bundle-store", filepath.Join(dir, "store"),
		"--control-socket", socket,
	)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatalf("start sidecar: %v", err)
	}
	t.Cleanup(func() {
		cancel()
		_ = cmd.Wait()
	})

	client := NewSidecarClient(socket)
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := client.Capabilities(context.Background()); err == nil {
			return client, string(raw)
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("the sidecar's control API never became reachable")
	return nil, ""
}

// The two sides are built separately, so schema agreement is the first thing
// to establish and the first thing that would silently break on a rebase.
func TestSidecarCapabilitiesAgreeOnSchema(t *testing.T) {
	client, _ := startRealSidecar(t)
	caps, err := client.Capabilities(context.Background())
	if err != nil {
		t.Fatalf("capabilities: %v", err)
	}
	if caps.Schema != sidecarAPISchema {
		t.Fatalf("schema = %d, want %d", caps.Schema, sidecarAPISchema)
	}
	if caps.Instance == "" {
		t.Fatal("the sidecar reported no process instance, so a restart would be invisible")
	}
	for _, feature := range []string{"bundles", "plugins"} {
		if _, ok := caps.Features[feature]; !ok {
			t.Errorf("the sidecar does not advertise %q", feature)
		}
	}
}

// The full publish path against the real binary: read back, stage, commit,
// confirm.
func TestSidecarPublishBundleEndToEnd(t *testing.T) {
	client, document := startRealSidecar(t)
	ctx := context.Background()

	before, err := client.State(ctx)
	if err != nil {
		t.Fatalf("state: %v", err)
	}
	if before.ActiveBundle != "" {
		t.Fatalf("a fresh sidecar reported active bundle %q", before.ActiveBundle)
	}

	result, err := client.PublishBundle(ctx, "bundle-1", []byte(document))
	if err != nil {
		t.Fatalf("publish: %v", err)
	}
	if result.BundleID != "bundle-1" || result.Generation != 1 {
		t.Fatalf("publish result = %+v", result)
	}

	after, err := client.State(ctx)
	if err != nil {
		t.Fatalf("state after publish: %v", err)
	}
	if after.ActiveBundle != "bundle-1" {
		t.Fatalf("active = %q, want bundle-1", after.ActiveBundle)
	}
	if !after.MasterEnabled || after.Extensions != 1 {
		t.Fatalf("the sidecar did not decode the bundle it accepted: %+v", after)
	}
	if after.CaptureHosts == 0 {
		t.Fatal("the sidecar reported no capture hosts for a bundle that declares them")
	}

	// Republishing the same bundle must not burn a generation.
	repeat, err := client.PublishBundle(ctx, "bundle-1", []byte(document))
	if err != nil {
		t.Fatalf("republish: %v", err)
	}
	if repeat.Generation != result.Generation {
		t.Fatalf("republishing the live bundle advanced the generation %d -> %d",
			result.Generation, repeat.Generation)
	}
}

// The console renders this, so it has to come back with real content rather
// than an empty shape.
func TestSidecarPluginsViewIsPopulated(t *testing.T) {
	client, document := startRealSidecar(t)
	ctx := context.Background()
	if _, err := client.PublishBundle(ctx, "bundle-1", []byte(document)); err != nil {
		t.Fatalf("publish: %v", err)
	}

	raw, err := client.Plugins(ctx)
	if err != nil {
		t.Fatalf("plugins: %v", err)
	}
	body := string(raw)
	for _, want := range []string{"io.5gpn.apple-wloc", "captureHosts", "gs-loc.apple.com"} {
		if !strings.Contains(body, want) {
			t.Errorf("the plugin view does not mention %q: %s", want, truncate(body, 400))
		}
	}
}

// A commit against the wrong expected-active must be a conflict the coordinator
// can branch on, not a generic failure.
func TestSidecarCommitConflictIsTyped(t *testing.T) {
	client, document := startRealSidecar(t)
	ctx := context.Background()

	if _, err := client.Stage(ctx, "bundle-1", []byte(document)); err != nil {
		t.Fatalf("stage: %v", err)
	}
	if _, err := client.Commit(ctx, "bundle-1", "some-other-bundle"); !errors.Is(err, errSidecarConflict) {
		t.Fatalf("want errSidecarConflict, got %v", err)
	}
}

// Staging must not make anything live: preparation is safe to retry precisely
// because it changes nothing.
func TestSidecarStagingIsNotLive(t *testing.T) {
	client, document := startRealSidecar(t)
	ctx := context.Background()

	if _, err := client.Stage(ctx, "bundle-1", []byte(document)); err != nil {
		t.Fatalf("stage: %v", err)
	}
	state, err := client.State(ctx)
	if err != nil {
		t.Fatalf("state: %v", err)
	}
	if state.ActiveBundle != "" {
		t.Fatalf("staging made %q live", state.ActiveBundle)
	}
	if len(state.Staged) != 1 || state.Staged[0] != "bundle-1" {
		t.Fatalf("staged set = %v", state.Staged)
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
