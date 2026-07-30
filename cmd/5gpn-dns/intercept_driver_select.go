package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"time"
)

// Brings up the runtime-overlay driver, which is the only way this build
// publishes interception routing.
//
// Three things have to agree, and each is checked against reality rather than
// against configuration:
//
//   - the mihomo config carries the anchors, which is what splices the overlay
//     into rule resolution at all;
//   - the core answers on the control socket with a schema this build speaks;
//   - any transition left in flight by a previous process has been resolved.
//
// Any one of them failing is fatal to interception. There is no renderer to
// fall back to, and continuing without a driver would leave a gateway that
// accepts routing changes and silently applies none of them -- the operator
// would see every extension toggle succeed while traffic kept following the
// last generation the core happened to hold.
const overlayDriverProbeTimeout = 10 * time.Second

func selectInterceptRoutingDriver(
	cfg Config,
	manager *InterceptModuleManager,
	mihomo *MihomoConfigStore,
	sidecar *SidecarClient,
) error {
	socket := cfg.OverlayControlSocket
	if socket == "" {
		return errors.New("no overlay control socket configured")
	}
	if manager == nil || mihomo == nil {
		return errors.New("interception management is unavailable")
	}

	mihomo.Lock()
	text, err := mihomo.Read()
	mihomo.Unlock()
	if err != nil {
		return fmt.Errorf("mihomo config unreadable: %w", err)
	}
	if !mihomoConfigIsOverlayAnchored(text) {
		// The installer refuses to publish an unanchored config, so reaching
		// here means the file was changed out of band. Splicing anchors in
		// behind the operator's back would change how their traffic is routed
		// without them having asked for it; refusing says so instead.
		return errors.New("mihomo config carries no overlay anchors; run '5gpn mihomo-reset' to reseed it")
	}
	if analysis := analyzeOverlayAnchoredDocument(text); !analysis.Manageable {
		return fmt.Errorf("mihomo config is anchored but not manageable: %s", analysis.Reason)
	}
	if _, err := os.Stat(socket); err != nil {
		return fmt.Errorf("overlay control socket %s is absent: %w", socket, err)
	}

	journal, err := NewOverlayJournal(cfg.OverlayJournalFile)
	if err != nil {
		return fmt.Errorf("overlay journal %s unusable: %w", cfg.OverlayJournalFile, err)
	}
	driver := NewOverlayDriver(NewOverlayClient(socket), journal)

	ctx, cancel := context.WithTimeout(context.Background(), overlayDriverProbeTimeout)
	defer cancel()
	if err := driver.Available(ctx); err != nil {
		return fmt.Errorf("overlay control API at %s unusable: %w", socket, err)
	}
	// A transition left in flight by a previous process is resolved by reading
	// back what the core actually has, never by undoing it: the commit may have
	// landed and lost only its response, and revoking that would stop processing
	// traffic mihomo is already steering at the sidecar.
	if err := driver.Recover(ctx); err != nil {
		return fmt.Errorf("overlay recovery failed: %w", err)
	}

	manager.SetOverlayDriver(driver)
	log.Printf("intercept: publishing routing as typed generations through %s", socket)

	// The core fails capture closed unless the processor holds a current lease,
	// and after a restart the recovered generation sits in quarantine until one
	// arrives. Nothing else renews it, so this heartbeat is what makes the
	// overlay serve traffic at all rather than an optional refinement.
	client := NewOverlayClient(socket)
	go NewOverlayReadinessReporter(client, sidecar).Run(context.Background())
	return nil
}
