package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The sidecar's unit refuses to run while the MITM master is off, so its
// control socket is gone by the time an operator turns the master back on.
// Deciding the transport once at startup therefore failed every such enable:
// the transaction was refused for want of the very process it exists to start,
// which made the master switch a one-way door on a live box.
//
// Presence has to be a per-call question. These pin both directions, because a
// check that always falls back would silently abandon the control API.
func TestPublishSidecarDocument_FallsBackWhenTheSocketIsGone(t *testing.T) {
	manager, _, _, interceptPath, _ := newInterceptManagerFixture(t)

	// A client installed at boot, whose socket has since disappeared with the
	// sidecar — exactly the state a disable leaves behind.
	missing := filepath.Join(t.TempDir(), "gone", "control.sock")
	manager.SetSidecarClient(NewSidecarClient(missing))
	// No path unit here to start anything, so do not sleep through the real
	// start-up window waiting for a socket that will never appear.
	manager.sidecarStart = 10 * time.Millisecond

	_, body := testInterceptDocument(t)
	if err := manager.publishSidecarDocument(context.Background(), body); err != nil {
		t.Fatalf("publish with an absent socket = %v; the enable must not be refused for want of the sidecar", err)
	}
	written, err := os.ReadFile(interceptPath)
	if err != nil || len(written) == 0 {
		t.Fatalf("nothing was written to the configuration file the sidecar cold starts from: %v", err)
	}
}

// A socket that IS present must still be used: the fallback is for absence, not
// for every failure. Pointing the client at a path that exists but speaks
// nothing proves the call is attempted rather than skipped.
func TestPublishSidecarDocument_UsesTheControlAPIWhenTheSocketExists(t *testing.T) {
	manager, _, _, _, _ := newInterceptManagerFixture(t)

	present := filepath.Join(t.TempDir(), "control.sock")
	if err := os.WriteFile(present, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	manager.SetSidecarClient(NewSidecarClient(present))

	_, body := testInterceptDocument(t)
	if err := manager.publishSidecarDocument(context.Background(), body); err == nil {
		t.Fatal("a present socket was skipped; the control API is no longer being used at all")
	}
}
