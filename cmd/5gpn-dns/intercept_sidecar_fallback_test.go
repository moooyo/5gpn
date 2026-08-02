package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
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
	published, pending, err := manager.stageSidecarDocument(context.Background(), body)
	if err != nil {
		t.Fatalf("staging with an absent socket = %v; the enable must not be refused for want of the sidecar", err)
	}
	if !published {
		t.Fatal("the document was written but not reported as published; the caller would skip its compensation")
	}
	if !pending {
		t.Fatal("the handover was not reported as pending; the bundle would never be pushed and readiness never asserted")
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
	published, _, err := manager.stageSidecarDocument(context.Background(), body)
	if err == nil {
		t.Fatal("a present socket was skipped; the control API is no longer being used at all")
	}
	if published {
		t.Fatal("a bundle that was never committed must not be reported as published; the caller would compensate a transaction that did not happen")
	}
}

// Constructing the client is the same question one level up, and getting it
// wrong there is worse: the manager can fall back to the file, but the readiness
// reporter cannot fall back to anything. Without a client it never reads what
// the processor has live, never asserts a lease, and mihomo keeps the generation
// quarantined — which fails every captured connection closed.
//
// On a fresh install the socket is guaranteed absent at this point: the
// sidecar's unit refuses to run until the MITM master is turned on, and that
// happens through this very process, later. So a build that only constructs the
// client when the socket already exists never has one on the deployment that
// matters most.
func TestSidecarControlClientIsBuiltBeforeTheSocketExists(t *testing.T) {
	absent := filepath.Join(t.TempDir(), "not-yet", "control.sock")
	if _, err := os.Stat(absent); err == nil {
		t.Fatal("the fixture socket must not exist for this test to mean anything")
	}

	client := newSidecarControlClient(Config{InterceptControlSocket: absent})
	if client == nil {
		t.Fatal("no client for a configured socket that is not listening yet; " +
			"readiness can never be asserted and all captured traffic will reject")
	}
	if client.SocketPath() != absent {
		t.Fatalf("client points at %q, want %q", client.SocketPath(), absent)
	}
	// The client must not claim the sidecar is there. Presence stays a per-call
	// question so the master switch can turn it on and off under a running core.
	if sidecarSocketPresent(client) {
		t.Fatal("an absent socket reported present")
	}
}

// The rollback position stays reachable: no configured socket means no client,
// and the manager keeps writing the configuration file.
func TestSidecarControlClientIsNilWithoutAConfiguredSocket(t *testing.T) {
	if client := newSidecarControlClient(Config{InterceptControlSocket: ""}); client != nil {
		t.Fatalf("built a client for an unconfigured socket: %q", client.SocketPath())
	}
}

// A change that leaves routing alone still has to reach both the processor and
// the overlay.
//
// The manager used to write the document and return for any such change. Under
// the overlay that quietly breaks the data plane: the sidecar adopts the new
// bundle, the live generation still names the old one, and mihomo refuses to
// treat the processor as ready while the two disagree -- so every captured
// connection rejects, and nothing says why except one line in the core's log.
// A settings edit is the ordinary way to reach that state.
//
// Pointing the driver at a control socket that does not exist makes the publish
// attempt observable: reaching it fails, and failing is what the caller must
// see. Before the fix this call returned success without the generation having
// moved at all.
func TestSettingsOnlyChangeStillPublishesAGenerationUnderTheOverlay(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroup = "Proxies"
	manager, _, _, _, _ := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }

	dir := t.TempDir()
	journal, err := NewOverlayJournal(filepath.Join(dir, "journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	manager.SetOverlayDriver(NewOverlayDriver(
		NewOverlayClient(filepath.Join(dir, "never-listening.sock")), journal))

	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	_, err = manager.mutate(context.Background(), view.Revision,
		func(document *interceptConfigDocument) (interceptMutationEffects, error) {
			// Any edit that changes the document without changing routing.
			document.Modules[0].Name = "Fixture extension (edited)"
			return interceptMutationEffects{routingChanged: false}, nil
		})
	if err == nil {
		t.Fatal("a settings-only change reported success without publishing a generation; " +
			"the sidecar's bundle and the live generation are free to drift apart, " +
			"which fails every captured connection closed")
	}
}

// The rollback position keeps its behaviour: with no overlay driver the same
// change is a document write and nothing more. Rewriting the mihomo config or
// reloading the data plane for a settings edit is exactly what the routing gate
// exists to prevent.
func TestSettingsOnlyChangeWithoutTheOverlayOnlyWritesTheDocument(t *testing.T) {
	module := testModuleSnapshot()
	module.EgressGroup = "Proxies"
	manager, controller, _, interceptPath, mihomoPath := newInterceptManagerFixture(t, module)
	manager.certWait = func(context.Context, string) error { return nil }

	before, err := os.ReadFile(mihomoPath)
	if err != nil {
		t.Fatal(err)
	}
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.mutate(context.Background(), view.Revision,
		func(document *interceptConfigDocument) (interceptMutationEffects, error) {
			document.Modules[0].Name = "Fixture extension (edited)"
			return interceptMutationEffects{routingChanged: false}, nil
		}); err != nil {
		t.Fatalf("settings-only change on the legacy path = %v", err)
	}

	written, err := os.ReadFile(interceptPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(written), "Fixture extension (edited)") {
		t.Fatal("the edited document never reached the sidecar's configuration file")
	}
	after, err := os.ReadFile(mihomoPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytesEqual(before, after) {
		t.Fatal("a settings-only change rewrote the mihomo config")
	}
	if controller.putCalls != 0 {
		t.Fatalf("a settings-only change reloaded mihomo %d time(s)", controller.putCalls)
	}
}
