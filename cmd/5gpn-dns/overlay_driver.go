package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"time"
)

// OverlayDriver publishes routing changes as typed generations instead of by
// rewriting the operator's mihomo YAML.
//
// The ordering below is the whole point and is not negotiable: the sidecar
// bundle and the certificate must be in place *before* mihomo publishes the
// generation as active, because activation is what makes capture traffic
// start arriving. The legacy driver already establishes that order; this one
// keeps it and replaces only the final publish step.
type OverlayDriver struct {
	client  *OverlayClient
	journal *OverlayJournal
	// certWait blocks until the certificate publisher acknowledges the exact
	// host-set digest for this generation.
	certWait func(ctx context.Context, digest string) error
	// dnsPublish installs the client DNS overlay. It runs last, after the
	// generation is confirmed effective — publishing it earlier would steer
	// clients at a gateway that cannot yet process their traffic.
	dnsPublish func(ctx context.Context) error
}

// NewOverlayDriver builds the driver.
func NewOverlayDriver(client *OverlayClient, journal *OverlayJournal) *OverlayDriver {
	return &OverlayDriver{client: client, journal: journal}
}

// SetCertificateWaiter installs the certificate readiness gate.
func (d *OverlayDriver) SetCertificateWaiter(fn func(ctx context.Context, digest string) error) {
	d.certWait = fn
}

// SetDNSPublisher installs the client DNS overlay publisher.
func (d *OverlayDriver) SetDNSPublisher(fn func(ctx context.Context) error) {
	d.dnsPublish = fn
}

// Available reports whether the core actually implements a schema this build
// understands. It is the gate the migration uses before switching drivers.
func (d *OverlayDriver) Available(ctx context.Context) error {
	_, err := d.client.Capabilities(ctx)
	return err
}

func newOverlayOperationID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("op-%d", time.Now().UnixNano())
	}
	return "op-" + hex.EncodeToString(b[:])
}

// Publish takes one desired state to effective.
//
// Steps, in the order the failure matrix requires:
//
//  1. read back the authoritative live state — never trust local belief;
//  2. compile and stage, which is idempotent and carries no capability;
//  3. wait for the certificate for this exact host set;
//  4. write COMMIT_INTENT durably, before the commit call goes out;
//  5. commit with compare-and-swap against the live generation and the core
//     configuration revision;
//  6. on any ambiguous failure, read back and roll forward — never rollback;
//  7. publish the client DNS overlay only after the generation is effective.
func (d *OverlayDriver) Publish(ctx context.Context, in overlayCompileInput) (overlayCommitResult, error) {
	var zero overlayCommitResult

	readback, err := d.client.Readback(ctx)
	if err != nil {
		return zero, fmt.Errorf("overlay: readback before publish: %w", err)
	}

	doc, err := compileOverlayGeneration(overlayCompileInput{
		Document:                 in.Document,
		MatchTarget:              in.MatchTarget,
		DocumentRevision:         in.DocumentRevision,
		ParentGeneration:         readback.ActiveGeneration,
		Transition:               in.Transition,
		CertificateHostSetDigest: in.CertificateHostSetDigest,
		SidecarBundleDigest:      in.SidecarBundleDigest,
	})
	if err != nil {
		return zero, err
	}

	// Publishing the generation that is already live is a no-op, not a new
	// transaction. Without this, every unrelated document write would burn a
	// generation and force a drain.
	if readback.ActiveGeneration == doc.GenerationID {
		return overlayCommitResult{
			ActiveGeneration: readback.ActiveGeneration,
			ActiveDigest:     readback.ActiveDigest,
			CoreRevision:     readback.CoreRevision,
			ResolverEpoch:    readback.ResolverEpoch,
			Repeated:         true,
		}, nil
	}

	entry := overlayJournalEntry{
		OperationID:              newOverlayOperationID(),
		ExpectedDocumentRevision: in.DocumentRevision,
		BaseGeneration:           readback.ActiveGeneration,
		TargetGeneration:         doc.GenerationID,
		TargetDocumentDigest:     overlayProjection(doc),
		ExpectedCoreRevision:     readback.CoreRevision,
	}
	if err := d.journal.Begin(entry); err != nil {
		return zero, err
	}

	staged, err := d.client.Stage(ctx, doc)
	if err != nil {
		_ = d.journal.Advance(overlayPhaseStaged, err.Error())
		return zero, fmt.Errorf("overlay: stage %s: %w", doc.GenerationID, err)
	}
	if err := d.journal.Advance(overlayPhasePrepared, ""); err != nil {
		return zero, err
	}

	if d.certWait != nil && doc.CertificateHostSetDigest != "" {
		if err := d.certWait(ctx, doc.CertificateHostSetDigest); err != nil {
			// The staged generation carries no capability, so abandoning it
			// leaves the live generation untouched.
			if abortErr := d.client.Abort(ctx, doc.GenerationID); abortErr != nil {
				log.Printf("overlay: abort %s after certificate failure: %v", doc.GenerationID, abortErr)
			}
			_ = d.journal.Finish()
			return zero, fmt.Errorf("overlay: certificate not ready for %s: %w", doc.GenerationID, err)
		}
	}

	// Durable intent BEFORE the commit call. This is what makes a lost response
	// recoverable: after this point the coordinator knows a commit may have
	// landed and must read back rather than assume.
	if err := d.journal.Advance(overlayPhaseCommitIntent, ""); err != nil {
		return zero, err
	}

	result, err := d.client.Commit(ctx, doc.GenerationID, entry.BaseGeneration, entry.ExpectedCoreRevision)
	if err != nil {
		return d.recoverAfterCommit(ctx, doc.GenerationID, err)
	}
	_ = staged

	if err := d.journal.Advance(overlayPhaseEffective, ""); err != nil {
		return result, err
	}
	if err := d.publishDNS(ctx); err != nil {
		// The generation is live; only the client DNS overlay is missing. That
		// is a degraded state to report, not a reason to revoke working policy.
		return result, fmt.Errorf("overlay: generation %s is effective but the DNS overlay failed: %w", doc.GenerationID, err)
	}
	_ = d.journal.Advance(overlayPhaseDNSApplied, "")
	_ = d.journal.Finish()
	return result, nil
}

// recoverAfterCommit resolves an ambiguous commit.
//
// A transport error says nothing about whether the commit landed. Reading back
// is the only way to find out, and rolling back on the strength of a lost
// response would revoke a generation that is serving traffic.
func (d *OverlayDriver) recoverAfterCommit(ctx context.Context, generationID string, commitErr error) (overlayCommitResult, error) {
	var zero overlayCommitResult

	if errors.Is(commitErr, errOverlayTerminal) || errors.Is(commitErr, errOverlayUnsupported) {
		// The core refused outright, so nothing was published.
		_ = d.journal.Advance(overlayPhaseCommitIntent, commitErr.Error())
		return zero, commitErr
	}

	readback, err := d.client.Readback(ctx)
	if err != nil {
		// Still ambiguous. The journal keeps COMMIT_INTENT so the next start
		// resolves it instead of starting a fresh transaction on top.
		_ = d.journal.Advance(overlayPhaseCommitIntent, commitErr.Error())
		return zero, fmt.Errorf("overlay: commit outcome unknown for %s (%v); readback also failed: %w",
			generationID, commitErr, err)
	}

	if readback.ActiveGeneration == generationID {
		// It landed after all. Roll forward.
		_ = d.journal.Advance(overlayPhaseEffective, commitErr.Error())
		if dnsErr := d.publishDNS(ctx); dnsErr != nil {
			return overlayCommitResult{ActiveGeneration: readback.ActiveGeneration}, dnsErr
		}
		_ = d.journal.Advance(overlayPhaseDNSApplied, "")
		_ = d.journal.Finish()
		return overlayCommitResult{
			ActiveGeneration: readback.ActiveGeneration,
			ActiveDigest:     readback.ActiveDigest,
			CoreRevision:     readback.CoreRevision,
			ResolverEpoch:    readback.ResolverEpoch,
		}, nil
	}

	_ = d.journal.Advance(overlayPhaseCommitIntent, commitErr.Error())
	return zero, fmt.Errorf("overlay: commit of %s did not take effect (active is %q): %w",
		generationID, readback.ActiveGeneration, commitErr)
}

func (d *OverlayDriver) publishDNS(ctx context.Context) error {
	if d.dnsPublish == nil {
		return nil
	}
	return d.dnsPublish(ctx)
}

// Recover resolves an operation interrupted by a crash or a lost response. It
// runs at startup, before anything else touches routing.
func (d *OverlayDriver) Recover(ctx context.Context) error {
	action, readback, err := RecoverOverlayOperation(ctx, d.journal, d.client)
	switch action {
	case overlayRecoveryNone:
		return err

	case overlayRecoveryAbandon:
		entry := d.journal.Current()
		if entry != nil && entry.TargetGeneration != "" {
			// Abort is best-effort: the generation may already have been
			// garbage-collected, and it carries no capability either way.
			if abortErr := d.client.Abort(ctx, entry.TargetGeneration); abortErr != nil {
				log.Printf("overlay: abandon %s: %v", entry.TargetGeneration, abortErr)
			}
		}
		return d.journal.Finish()

	case overlayRecoveryRollForward:
		log.Printf("overlay: rolling forward to generation %s recovered from the journal", readback.ActiveGeneration)
		if err := d.journal.Advance(overlayPhaseEffective, ""); err != nil {
			return err
		}
		if dnsErr := d.publishDNS(ctx); dnsErr != nil {
			return dnsErr
		}
		_ = d.journal.Advance(overlayPhaseDNSApplied, "")
		return d.journal.Finish()

	case overlayRecoveryRetry:
		// The transaction never took effect. Leave the journal in place; the
		// next publish supersedes it.
		log.Printf("overlay: interrupted operation did not take effect; active generation is %q", readback.ActiveGeneration)
		return d.journal.Finish()

	case overlayRecoveryConflict:
		// Deliberately not resolved automatically. Something outside this
		// coordinator moved the generation, and picking a side would either
		// revoke live policy or adopt policy nobody here authored.
		return fmt.Errorf("overlay: active generation %q matches neither the base nor the target of the interrupted operation; operator intervention required",
			readback.ActiveGeneration)
	}
	return err
}
