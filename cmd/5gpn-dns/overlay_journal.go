package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

// overlayPhase is the coordinator's position in one transaction.
//
//	IDLE -> STAGED -> PREPARED -> COMMIT_INTENT -> EFFECTIVE -> DNS_APPLIED -> DONE
//
// COMMIT_INTENT is the load-bearing one. It is written to disk *before* the
// commit call goes out, so a crash or a lost response leaves durable evidence
// that a commit may have landed. Without it, recovery cannot distinguish "never
// sent" from "sent and the answer was lost", and the only safe action for the
// latter — read back, then roll forward — would be unavailable.
type overlayPhase string

const (
	overlayPhaseIdle         overlayPhase = "IDLE"
	overlayPhaseStaged       overlayPhase = "STAGED"
	overlayPhasePrepared     overlayPhase = "PREPARED"
	overlayPhaseCommitIntent overlayPhase = "COMMIT_INTENT"
	overlayPhaseEffective    overlayPhase = "EFFECTIVE"
	overlayPhaseDNSApplied   overlayPhase = "DNS_APPLIED"
	overlayPhaseDone         overlayPhase = "DONE"
)

// overlayJournalEntry is the durable record of one in-flight transaction.
type overlayJournalEntry struct {
	OperationID              string       `json:"operation_id"`
	Phase                    overlayPhase `json:"phase"`
	ExpectedDocumentRevision string       `json:"expected_document_revision"`
	BaseGeneration           string       `json:"base_generation_id"`
	TargetGeneration         string       `json:"target_generation_id"`
	TargetDocumentDigest     string       `json:"target_document_digest"`
	ExpectedCoreRevision     uint64       `json:"expected_core_config_revision"`
	LastError                string       `json:"last_error,omitempty"`
	UpdatedAt                int64        `json:"updated_at"`
}

// overlayJournalState is the complete on-disk journal.
type overlayJournalState struct {
	Version int `json:"version"`
	// Current is the in-flight operation, or nil when idle.
	Current *overlayJournalEntry `json:"current,omitempty"`
	// LastEffective records the last generation this coordinator observed as
	// live, which is the CAS base for the next transaction.
	LastEffective string `json:"last_effective_generation,omitempty"`
}

const overlayJournalVersion = 1

// OverlayJournal is the coordinator's durable operation log.
type OverlayJournal struct {
	mu    sync.Mutex
	path  string
	state overlayJournalState
}

// NewOverlayJournal opens (or creates) the journal.
//
// A journal that cannot be read is a hard failure, not a fresh start: silently
// starting over would discard the very evidence recovery depends on and could
// commit a second generation on top of one already live.
func NewOverlayJournal(path string) (*OverlayJournal, error) {
	j := &OverlayJournal{path: path}
	raw, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		j.state = overlayJournalState{Version: overlayJournalVersion}
		return j, nil
	case err != nil:
		return nil, fmt.Errorf("overlay journal: read %s: %w", path, err)
	}
	if err := json.Unmarshal(raw, &j.state); err != nil {
		return nil, fmt.Errorf("overlay journal: %s is unreadable: %w", path, err)
	}
	if j.state.Version > overlayJournalVersion {
		return nil, fmt.Errorf("overlay journal: %s was written by version %d, this build understands %d",
			path, j.state.Version, overlayJournalVersion)
	}
	return j, nil
}

// LastEffective reports the last generation observed live.
func (j *OverlayJournal) LastEffective() string {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.state.LastEffective
}

// Current returns a copy of the in-flight entry, or nil.
func (j *OverlayJournal) Current() *overlayJournalEntry {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.state.Current == nil {
		return nil
	}
	entry := *j.state.Current
	return &entry
}

// Begin records a new transaction at STAGED.
func (j *OverlayJournal) Begin(entry overlayJournalEntry) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.state.Current != nil && j.state.Current.Phase != overlayPhaseDone {
		return fmt.Errorf("overlay journal: operation %s is still at %s",
			j.state.Current.OperationID, j.state.Current.Phase)
	}
	entry.Phase = overlayPhaseStaged
	entry.UpdatedAt = time.Now().Unix()
	j.state.Current = &entry
	return j.writeLocked()
}

// Advance moves the in-flight operation to a new phase.
func (j *OverlayJournal) Advance(phase overlayPhase, lastErr string) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.state.Current == nil {
		return errors.New("overlay journal: no operation in flight")
	}
	j.state.Current.Phase = phase
	j.state.Current.LastError = lastErr
	j.state.Current.UpdatedAt = time.Now().Unix()
	if phase == overlayPhaseEffective {
		j.state.LastEffective = j.state.Current.TargetGeneration
	}
	return j.writeLocked()
}

// Finish clears the in-flight operation.
func (j *OverlayJournal) Finish() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.state.Current == nil {
		return nil
	}
	j.state.Current = nil
	return j.writeLocked()
}

// writeLocked persists the journal atomically. Callers hold mu.
func (j *OverlayJournal) writeLocked() error {
	j.state.Version = overlayJournalVersion
	raw, err := json.MarshalIndent(j.state, "", "  ")
	if err != nil {
		return fmt.Errorf("overlay journal: encode: %w", err)
	}
	raw = append(raw, '\n')

	dir := filepath.Dir(j.path)
	if err := os.MkdirAll(dir, 0o770); err != nil {
		return fmt.Errorf("overlay journal: create %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".overlay-journal-*.tmp")
	if err != nil {
		return fmt.Errorf("overlay journal: create temp: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if err := tmp.Chmod(0o640); err != nil {
		tmp.Close()
		return fmt.Errorf("overlay journal: chmod: %w", err)
	}
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return fmt.Errorf("overlay journal: write: %w", err)
	}
	// fsync before rename. The journal's whole purpose is to survive the crash
	// that loses a commit response, and an unsynced write does not.
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("overlay journal: fsync: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("overlay journal: close: %w", err)
	}
	if err := os.Rename(tmpName, j.path); err != nil {
		return fmt.Errorf("overlay journal: publish: %w", err)
	}
	return syncOverlayDir(dir)
}

// syncOverlayDir fsyncs a directory so the rename itself is durable.
//
// Windows cannot open a directory as a file and its rename is
// metadata-journalled, so the call is skipped there rather than failing every
// write. The gateway is Linux; this only matters for development.
func syncOverlayDir(dir string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	f, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("overlay journal: open %s: %w", dir, err)
	}
	defer f.Close()
	if err := f.Sync(); err != nil {
		return fmt.Errorf("overlay journal: fsync %s: %w", dir, err)
	}
	return nil
}

// overlayRecoveryAction is what recovery decided to do about an interrupted
// transaction.
type overlayRecoveryAction string

const (
	// overlayRecoveryNone means nothing was in flight.
	overlayRecoveryNone overlayRecoveryAction = "none"
	// overlayRecoveryRollForward means the commit landed; adopt it and finish
	// the remaining steps.
	overlayRecoveryRollForward overlayRecoveryAction = "roll-forward"
	// overlayRecoveryRetry means the commit did not land; the identical
	// idempotent operation may be retried.
	overlayRecoveryRetry overlayRecoveryAction = "retry"
	// overlayRecoveryAbandon means prepared artifacts can simply be dropped.
	overlayRecoveryAbandon overlayRecoveryAction = "abandon"
	// overlayRecoveryConflict means some third party moved the active
	// generation. This needs an operator, not an automatic decision.
	overlayRecoveryConflict overlayRecoveryAction = "conflict"
)

// RecoverOverlayOperation decides what to do about an interrupted transaction.
//
// The rules are the ones the failure matrix requires, and the important one is
// negative: after COMMIT_INTENT the coordinator never assumes failure. It reads
// the authoritative live generation and believes that, because a blind rollback
// there would revoke a generation that is actually serving traffic.
func RecoverOverlayOperation(ctx context.Context, journal *OverlayJournal, client *OverlayClient) (overlayRecoveryAction, overlayReadback, error) {
	entry := journal.Current()
	if entry == nil || entry.Phase == overlayPhaseDone {
		return overlayRecoveryNone, overlayReadback{}, nil
	}

	readback, err := client.Readback(ctx)
	if err != nil {
		return overlayRecoveryRetry, overlayReadback{}, err
	}

	switch entry.Phase {
	case overlayPhaseStaged, overlayPhasePrepared:
		// Nothing was committed. Prepared artifacts carry no capability, so
		// dropping them is free.
		return overlayRecoveryAbandon, readback, nil

	case overlayPhaseCommitIntent, overlayPhaseEffective, overlayPhaseDNSApplied:
		switch readback.ActiveGeneration {
		case entry.TargetGeneration:
			// The commit landed, whether or not we saw the response.
			return overlayRecoveryRollForward, readback, nil
		case entry.BaseGeneration:
			// It did not land. The same idempotent operation may be repeated.
			return overlayRecoveryRetry, readback, nil
		default:
			// Neither the base nor the target is live. Something outside this
			// coordinator moved the generation; guessing would make it worse.
			return overlayRecoveryConflict, readback, nil
		}
	}
	return overlayRecoveryNone, readback, nil
}
