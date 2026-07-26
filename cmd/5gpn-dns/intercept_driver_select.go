package main

import (
	"context"
	"log"
	"os"
	"time"
)

// Chooses which driver publishes interception routing.
//
// Three things have to agree before the overlay is used, and each is checked
// against reality rather than against configuration:
//
//   - the mihomo config carries the anchors, which is what splices the overlay
//     into rule resolution at all;
//   - the core answers on the control socket with a schema this build speaks;
//   - any transition left in flight by a previous process has been resolved.
//
// Any one of them failing selects the legacy renderer. That is not a
// degradation to hide: the legacy path is fully supported, and running it is
// strictly better than committing generations to a core that will not resolve
// the anchors, or rewriting a config whose anchors say the rules live
// elsewhere. Which one was chosen, and why, is logged at startup because it
// determines how every later routing change is applied.

const overlayDriverProbeTimeout = 10 * time.Second

func selectInterceptRoutingDriver(
	cfg Config,
	manager *InterceptModuleManager,
	mihomo *MihomoConfigStore,
	sidecar *SidecarClient,
) {
	socket := cfg.OverlayControlSocket
	if socket == "" {
		log.Printf("intercept: no overlay control socket configured; rendering the mihomo config")
		return
	}
	if manager == nil || mihomo == nil {
		return
	}

	mihomo.Lock()
	text, err := mihomo.Read()
	mihomo.Unlock()
	if err != nil {
		log.Printf("intercept: mihomo config unreadable (%v); rendering the mihomo config", err)
		return
	}
	if !mihomoConfigIsOverlayAnchored(text) {
		// Not an error, and not something to fix here. A config without anchors
		// is the pre-migration arrangement, and splicing them in behind the
		// operator's back would change how their traffic is routed without them
		// having asked for it.
		log.Printf("intercept: mihomo config carries no overlay anchors; rendering the mihomo config")
		return
	}
	if analysis := analyzeOverlayAnchoredDocument(text); !analysis.Manageable {
		// Anchored but not correctly: the operator asked for the overlay and
		// the arrangement does not hold. Saying so is the whole value of the
		// structural check — falling back silently would leave a config that
		// looks migrated and a gateway that is not.
		log.Printf("intercept: mihomo config is anchored but not manageable (%s); rendering the mihomo config",
			analysis.Reason)
		return
	}
	if _, err := os.Stat(socket); err != nil {
		log.Printf("intercept: overlay control socket %s is absent (%v); rendering the mihomo config", socket, err)
		return
	}

	journal, err := NewOverlayJournal(cfg.OverlayJournalFile)
	if err != nil {
		log.Printf("intercept: overlay journal %s unusable (%v); rendering the mihomo config",
			cfg.OverlayJournalFile, err)
		return
	}
	driver := NewOverlayDriver(NewOverlayClient(socket), journal)

	ctx, cancel := context.WithTimeout(context.Background(), overlayDriverProbeTimeout)
	defer cancel()
	if err := driver.Available(ctx); err != nil {
		log.Printf("intercept: overlay control API at %s unusable (%v); rendering the mihomo config", socket, err)
		return
	}
	// A transition left in flight by a previous process is resolved by reading
	// back what the core actually has, never by undoing it: the commit may have
	// landed and lost only its response, and revoking that would stop processing
	// traffic mihomo is already steering at the sidecar.
	if err := driver.Recover(ctx); err != nil {
		log.Printf("intercept: overlay recovery failed (%v); rendering the mihomo config", err)
		return
	}
	if err := journal.SetDriver(overlayDriverOverlay); err != nil {
		log.Printf("intercept: could not record the overlay driver (%v); rendering the mihomo config", err)
		return
	}

	manager.SetOverlayDriver(driver)
	log.Printf("intercept: publishing routing as typed generations through %s", socket)

	// The core fails capture closed unless the processor holds a current lease,
	// and after a restart the recovered generation sits in quarantine until one
	// arrives. Nothing else renews it, so this heartbeat is what makes the
	// overlay serve traffic at all rather than an optional refinement.
	client := NewOverlayClient(socket)
	go NewOverlayReadinessReporter(client, sidecar).Run(context.Background())
}
