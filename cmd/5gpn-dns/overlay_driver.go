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

// OverlayDriver publishes routing changes as typed generations. It is the only
// publication path: the operator's mihomo YAML is never rewritten for one.
//
// The driver owns the generation. The certificate gate and the client DNS
// overlay belong to the caller: InterceptModuleManager.mutate waits for the
// certificate before calling Publish and installs the DNS overlay after it
// returns (see intercept_module_manager.go:1260-1282). The driver used to carry
// hooks for both, which nothing ever installed -- so a doc comment called a
// seven-step ordering "not negotiable" while two of the steps could not run.
type OverlayDriver struct {
	client  *OverlayClient
	journal *OverlayJournal
}

// NewOverlayDriver builds the driver.
func NewOverlayDriver(client *OverlayClient, journal *OverlayJournal) *OverlayDriver {
	return &OverlayDriver{client: client, journal: journal}
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
//  3. write COMMIT_INTENT durably, before the commit call goes out;
//  4. commit with compare-and-swap against the live generation and the core
//     configuration revision;
//  5. on any ambiguous failure, read back and roll forward — never rollback.
//
// The certificate for this exact host set is already published when Publish is
// called, and the client DNS overlay is installed after it returns. Both are
// the caller's, and both have to bracket this call: capture traffic starts
// arriving the moment the generation goes live.
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
	// transaction. Without this, every unrelated document write burns a
	// generation and forces a drain.
	//
	// The test cannot be readback.ActiveGeneration == doc.GenerationID: the id
	// covers ParentGenerationID, and doc was just compiled with the live
	// generation as its parent, so equality would need a SHA-256 fixed point and
	// never held once. Compare the desired state instead, and only trust it when
	// the live generation is one this coordinator put there — a generation some
	// third party moved is deliberately not short-circuited, and neither is a
	// journal that has no record (an older file, or a lost store).
	fingerprint, err := overlayDesiredFingerprint(in.DocumentRevision, doc)
	if err != nil {
		return zero, err
	}
	lastGeneration, lastFingerprint := d.journal.LastEffectiveState()
	alreadyLive := readback.ActiveGeneration != "" &&
		readback.ActiveGeneration == lastGeneration &&
		lastFingerprint != "" && lastFingerprint == fingerprint
	if alreadyLive {
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
		TargetFingerprint:        fingerprint,
		ExpectedCoreRevision:     readback.CoreRevision,
	}
	if err := d.journal.Begin(entry); err != nil {
		return zero, err
	}

	staged, err := d.client.Stage(ctx, doc)
	if err != nil {
		// A stage that failed left nothing behind -- no generation, and so no
		// capability -- exactly like the certificate wait below, which already
		// abandons its entry. Recording the error and keeping the entry in
		// flight instead blocked every later apply, because Begin refuses while
		// one is unfinished: one rejected document wedged the driver until the
		// daemon restarted and recovery ran.
		_ = d.journal.Advance(overlayPhaseStaged, err.Error())
		_ = d.journal.Finish()
		return zero, fmt.Errorf("overlay: stage %s: %w", doc.GenerationID, err)
	}
	if err := d.journal.Advance(overlayPhasePrepared, ""); err != nil {
		// Same wedge the stage-failure path above documents, and the same cure.
		// Begin refuses while an entry is unfinished, so returning here left every
		// later apply failing with "is still at PREPARED" for the rest of the
		// process lifetime -- from nothing worse than a journal write failing
		// once, a full partition being the realistic trigger. Nothing was
		// committed, so the entry describes no capability and the staged
		// generation can simply be dropped.
		d.abandonStagedGeneration(ctx, doc.GenerationID)
		return zero, err
	}

	// Durable intent BEFORE the commit call. This is what makes a lost response
	// recoverable: after this point the coordinator knows a commit may have
	// landed and must read back rather than assume.
	if err := d.journal.Advance(overlayPhaseCommitIntent, ""); err != nil {
		// Commit has not run, so this is still the pre-commit world: nothing was
		// committed, the staged generation carries no capability, and leaving the
		// entry in flight would wedge every later apply at Begin.
		d.abandonStagedGeneration(ctx, doc.GenerationID)
		return zero, err
	}

	result, err := d.client.Commit(ctx, doc.GenerationID, entry.BaseGeneration, entry.ExpectedCoreRevision)
	if err != nil {
		return d.recoverAfterCommit(ctx, doc.GenerationID, entry.BaseGeneration, err)
	}
	_ = staged

	if err := d.journal.Advance(overlayPhaseEffective, ""); err != nil {
		return result, err
	}
	_ = d.journal.Advance(overlayPhaseDNSApplied, "")
	_ = d.journal.Finish()
	return result, nil
}

// abandonStagedGeneration drops a generation that was staged but never
// committed, and clears the journal entry describing it.
//
// Both are best effort and both are safe: a staged generation confers no
// capability, and Finish only removes a record of something that did not happen.
// What is not safe is skipping either — an un-aborted generation leaks in the
// core's staging area, and an unfinished entry makes Begin refuse every
// subsequent transaction until the daemon restarts.
func (d *OverlayDriver) abandonStagedGeneration(ctx context.Context, generation string) {
	if err := d.client.Abort(ctx, generation); err != nil {
		log.Printf("overlay: abort %s after a journal write failed: %v", generation, err)
	}
	if err := d.journal.Finish(); err != nil {
		log.Printf("overlay: clear the journal entry for %s: %v", generation, err)
	}
}

// recoverAfterCommit resolves an ambiguous commit.
//
// A transport error says nothing about whether the commit landed. Reading back
// is the only way to find out, and rolling back on the strength of a lost
// response would revoke a generation that is serving traffic.
//
// The entry is kept in flight only while that ambiguity is real. An outcome
// this function can prove -- the core refused the document, or the base is
// still live -- leaves nothing for recovery to resolve, and keeping it would
// refuse every later apply at Begin until the daemon restarted, which is the
// wedge a failed stage already avoids.
func (d *OverlayDriver) recoverAfterCommit(ctx context.Context, generationID, baseGeneration string, commitErr error) (overlayCommitResult, error) {
	var zero overlayCommitResult

	if errors.Is(commitErr, errOverlayTerminal) || errors.Is(commitErr, errOverlayUnsupported) {
		// The core refused outright, so nothing was published and the entry
		// describes no capability. Repeating it cannot help either, so there is
		// nothing for a later recovery to do with it.
		_ = d.journal.Advance(overlayPhaseCommitIntent, commitErr.Error())
		_ = d.journal.Finish()
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
	if readback.ActiveGeneration == baseGeneration {
		// The base is still live, so the commit provably did not land and the
		// entry describes nothing. Recovery would classify this as a plain
		// retry and clear it; doing that here keeps the driver usable without
		// waiting for a restart.
		_ = d.journal.Finish()
	}
	// Anything else means a third party moved the active generation. That is
	// the conflict recovery deliberately refuses to resolve on its own, so the
	// entry stays in flight for an operator.
	return zero, fmt.Errorf("overlay: commit of %s did not take effect (active is %q): %w",
		generationID, readback.ActiveGeneration, commitErr)
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
		_ = d.journal.Advance(overlayPhaseDNSApplied, "")
		return d.journal.Finish()

	case overlayRecoveryRetry:
		// The transaction never took effect. Leave the journal in place; the
		// next publish supersedes it.
		log.Printf("overlay: interrupted operation did not take effect; active generation is %q", readback.ActiveGeneration)
		return d.journal.Finish()

	case overlayRecoveryUnknown:
		// The entry stays. It is the only record that a commit may have landed,
		// and the conflict case below can only ever be detected while it exists.
		return fmt.Errorf("overlay: the live generation could not be read back, so the interrupted operation remains in flight: %w", err)

	case overlayRecoveryConflict:
		// Deliberately not resolved automatically. Something outside this
		// coordinator moved the generation, and picking a side would either
		// revoke live policy or adopt policy nobody here authored.
		return fmt.Errorf("overlay: active generation %q matches neither the base nor the target of the interrupted operation; operator intervention required",
			readback.ActiveGeneration)
	}
	return err
}
