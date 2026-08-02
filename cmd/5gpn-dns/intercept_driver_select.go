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
	reporter := NewOverlayReadinessReporter(client, sidecar)
	// The control plane reports what this reporter decides. Without it, every
	// state that withholds the lease -- and so REJECTs all captured traffic --
	// was visible only in the journal.
	manager.SetReadinessReporter(reporter)
	go reporter.Run(context.Background())
	return nil
}

// Retry bounds for the driver probe. The floor is short because the common
// failure is a cold-start race measured in hundreds of milliseconds; the
// ceiling keeps a genuinely misconfigured gateway to one attempt a minute.
const (
	overlayDriverRetryMin = 2 * time.Second
	overlayDriverRetryMax = time.Minute
)

// superviseInterceptRoutingDriver brings the driver up, and keeps trying if it
// cannot yet.
//
// The probe used to run exactly once, and a failure was logged and forgotten.
// That is not a rare path: the socket lives in mihomo's RuntimeDirectory, and
// 5gpn-dns is only softly ordered after mihomo -- Wants= and After=, explicitly
// best-effort -- while mihomo is Type=simple, so systemd releases this daemon
// the instant mihomo is forked, before it has loaded its config and providers
// and bound the socket. Losing that race cost the whole process lifetime:
// publishOverlayGeneration returned errInterceptRoutingDriverUnavailable for
// every subsequent change, PrepareRuntime published a nil host table so
// interception silently vanished, and the readiness reporter -- which is
// started only here -- never ran at all, leaving even a generation mihomo
// recovered from its own store quarantined forever. The process is healthy
// throughout, so Restart=on-failure and WatchdogSec never fire.
//
// Retrying also covers the operator repairing a config the probe rejected,
// which previously required a restart to take effect.
func superviseInterceptRoutingDriver(
	ctx context.Context,
	cfg Config,
	manager *InterceptModuleManager,
	mihomo *MihomoConfigStore,
	sidecar *SidecarClient,
) {
	err := selectInterceptRoutingDriver(cfg, manager, mihomo, sidecar)
	if err == nil {
		return
	}
	// DNS is this daemon's primary duty and keeps running. Interception has no
	// second publication path, so it stays fail-closed and every routing change
	// reports this rather than appearing to succeed.
	log.Printf("warning: interception routing driver: %v -- retrying in the background", err)

	go func() {
		delay := overlayDriverRetryMin
		last := err.Error()
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(delay):
			}
			retryErr := selectInterceptRoutingDriver(cfg, manager, mihomo, sidecar)
			if retryErr == nil {
				log.Print("intercept: routing driver became available; republishing the current document")
				// PrepareRuntime is what makes the coordinator authoritative,
				// and the driver short-circuits when the recompiled state is
				// already live, so republishing a healthy gateway is a readback.
				if prepareErr := manager.PrepareRuntime(); prepareErr != nil {
					log.Printf("intercept: republishing after the driver became available failed: %v", prepareErr)
				}
				return
			}
			// Only when the reason changes. A permanently broken gateway is one
			// line, not one a minute, and a reason that changes is the thing an
			// operator actually needs to see.
			if message := retryErr.Error(); message != last {
				log.Printf("warning: interception routing driver: %v", retryErr)
				last = message
			}
			if delay < overlayDriverRetryMax {
				delay *= 2
				if delay > overlayDriverRetryMax {
					delay = overlayDriverRetryMax
				}
			}
		}
	}()
}
