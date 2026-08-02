package main

import (
	"context"
	"log"
	"strings"
	"sync"
	"time"
)

// Keeps the processor's readiness lease alive.
//
// The core fails capture closed when the lease lapses: a capture rule that
// cannot be serviced rejects rather than falling through to the operator's own
// routing. That is the right behaviour — a client whose DNS still points a
// capture host at the gateway must not have its traffic silently handled by
// something other than the processor — but it means readiness is a heartbeat,
// not an announcement. A coordinator that registers once and stops leaves every
// capture rule rejecting within the lease TTL.
//
// The processor cannot send this itself. Its socket is read-only by design,
// because a compromised processor able to register readiness could claim to be
// serving a generation it is not, which is exactly the assertion the lease is
// supposed to make trustworthy. So the coordinator asserts it — and earns the
// right to by reading the sidecar's own view of what it has live first. If the
// sidecar is serving a different bundle, or cannot be reached, nothing is sent
// and the lease is allowed to lapse. Letting it lapse is the honest outcome:
// the coordinator does not know that the processor is ready, and capture
// rejecting is what "not known to be ready" has to mean.

const (
	// Well inside the core's 15s lease TTL, so a single missed beat — a slow
	// sidecar, a scheduling hiccup — does not cost the lease.
	overlayReadinessInterval = 4 * time.Second
	overlayReadinessTimeout  = 5 * time.Second
	// overlayProcessorID must match the id the compiler puts in the generation's
	// processor targets; the lease is matched against the active document.
	overlayReadinessProcessorID = overlayProcessorID
)

// OverlayReadinessReporter renews the lease for whatever generation is live.
type OverlayReadinessReporter struct {
	overlay *OverlayClient
	sidecar *SidecarClient

	mu         sync.Mutex
	lastReason string
}

// NewOverlayReadinessReporter builds a reporter. A nil sidecar client means the
// deployment still writes the sidecar's file and has no way to read back what
// the sidecar has live, so no readiness can be asserted.
func NewOverlayReadinessReporter(overlay *OverlayClient, sidecar *SidecarClient) *OverlayReadinessReporter {
	return &OverlayReadinessReporter{overlay: overlay, sidecar: sidecar}
}

// Run heartbeats until the context is cancelled.
func (r *OverlayReadinessReporter) Run(ctx context.Context) {
	if r == nil || r.overlay == nil {
		return
	}
	ticker := time.NewTicker(overlayReadinessInterval)
	defer ticker.Stop()
	// Beat immediately: after a restart the generation is in quarantine and
	// stays there until a matching lease arrives, so every second of delay is a
	// second of captured traffic rejecting.
	r.beat(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.beat(ctx)
		}
	}
}

func (r *OverlayReadinessReporter) beat(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, overlayReadinessTimeout)
	defer cancel()

	readback, err := r.overlay.Readback(ctx)
	if err != nil {
		r.note("overlay readback failed: " + err.Error())
		return
	}
	if !readback.Enabled || readback.ActiveGeneration == "" {
		// Nothing is live, so there is nothing to be ready for. Not a fault.
		r.note("")
		return
	}
	if r.sidecar == nil {
		r.note("no sidecar control API; the processor's state cannot be verified")
		return
	}

	state, err := r.sidecar.State(ctx)
	if err != nil {
		r.note("sidecar state unreadable: " + err.Error())
		return
	}
	// The generation names the bundle it was compiled against. Asserting
	// readiness while the sidecar serves a different one would tell the core
	// that traffic it is about to steer will be processed by the policy in the
	// generation, when it would in fact meet the previous policy.
	if readback.ActiveBundleDigest != "" && state.ActiveBundle != readback.ActiveBundleDigest {
		r.note("sidecar is serving bundle " + quoteOrNone(state.ActiveBundle) +
			", the live generation was compiled against " + quoteOrNone(readback.ActiveBundleDigest))
		return
	}
	if state.ActiveBundle == "" {
		r.note("the sidecar has no bundle live")
		return
	}

	err = r.overlay.RegisterReadiness(ctx, overlayReadinessRequest{
		ProcessorID:     overlayReadinessProcessorID,
		ProcessInstance: state.InstanceID,
		GenerationID:    readback.ActiveGeneration,
		BundleDigest:    state.ActiveBundle,
		CertHostSet:     readback.ActiveCertHostSet,
	})
	if err != nil {
		r.note("readiness registration failed: " + err.Error())
		return
	}
	r.note("")
}

// note logs a change in why readiness is or is not being asserted.
//
// Only on change: a heartbeat every few seconds would otherwise fill the log
// with the same line, and the thing an operator needs to see is the transition.
func (r *OverlayReadinessReporter) note(reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if reason == r.lastReason {
		return
	}
	previous := r.lastReason
	r.lastReason = reason
	switch {
	case reason == "":
		log.Printf("overlay: processor readiness is being asserted again (was: %s)", previous)
	default:
		log.Printf("overlay: not asserting processor readiness -- %s; capture traffic will "+
			"reject once the lease lapses", reason)
	}
}

func quoteOrNone(v string) string {
	if strings.TrimSpace(v) == "" {
		return "none"
	}
	return `"` + v + `"`
}

// Reason reports why readiness is currently not being asserted, or "" when it
// is.
//
// note() writes this to the journal and nowhere else, so every state it
// describes -- a sidecar serving a bundle the live generation was not compiled
// against, a sidecar with no bundle live at all, a registration the core keeps
// refusing -- was invisible on every operator surface. Each of them REJECTs
// 100% of captured traffic once the lease lapses, while the console shows an
// enabled extension and a running engine.
func (r *OverlayReadinessReporter) Reason() string {
	if r == nil {
		return ""
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastReason
}
