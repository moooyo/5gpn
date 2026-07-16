// Package main (this file): the policy engine — the piece that ties the
// unified policy-rule model (policy_rules.go), the compiler
// (policy_compile.go), the subscription fetcher (subscription.go), and the
// DNS handler's fallback switch (handler.go) together into one
// CompileAndApply(ctx) call.
//
// DNS-only apply (2026-07-15 policy/mihomo decoupling design, §2.4/§3):
// CompileAndApply touches ONLY the DNS plane — write category files → Sync
// policy subscriptions (DNS cache) → setFallback → reload/flush. It performs
// NO mihomo validation or apply; there is no daemon-side mihomo config
// mutation triggered by a policy change anymore (a future config-editor unit
// adds the ONLY remaining path that mutates mihomo, entirely separate from
// policy). Do not reintroduce a mihomo render/validate/apply step here.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// PolicyEngine ties the policy model + compiler + subscription fetcher +
// DNS-fallback switch together. subs/handler may be nil — mirroring every
// other optional daemon component (main wires real ones; tests may omit what
// they don't exercise) — CompileAndApply guards each before use.
type PolicyEngine struct {
	mgr     *PolicyRuleManager
	subs    *SubManager
	handler *Handler
	reload  func() error

	rulesDir string
	applyMu  sync.Mutex
}

type manualFileBackup struct {
	path   string
	data   []byte
	mode   os.FileMode
	exists bool
}

func (e *PolicyEngine) backupManualFiles() ([]manualFileBackup, error) {
	backups := make([]manualFileBackup, 0, len(policyManualCategories)*len(policyManualMatchTypes))
	for _, cat := range policyManualCategories {
		for _, mt := range policyManualMatchTypes {
			path := e.manualRulePath(cat, mt)
			b := manualFileBackup{path: path, mode: 0o644}
			data, err := os.ReadFile(path)
			if err != nil {
				if !errors.Is(err, os.ErrNotExist) {
					return nil, fmt.Errorf("backup %s: %w", path, err)
				}
			} else {
				b.exists, b.data = true, data
				if info, statErr := os.Stat(path); statErr == nil {
					b.mode = info.Mode().Perm()
				}
			}
			backups = append(backups, b)
		}
	}
	return backups, nil
}

func restoreManualFiles(backups []manualFileBackup) error {
	var errs []error
	for _, b := range backups {
		if !b.exists {
			if err := os.Remove(b.path); err != nil && !errors.Is(err, os.ErrNotExist) {
				errs = append(errs, fmt.Errorf("remove %s: %w", b.path, err))
			}
			continue
		}
		if err := atomicWriteFile(b.path, b.data, b.mode); err != nil {
			errs = append(errs, fmt.Errorf("restore %s: %w", b.path, err))
		}
	}
	return errors.Join(errs...)
}

// PrepareRuntime publishes the persisted model against existing subscription
// caches without mutating any derived files or performing network I/O. Startup
// uses it before serving so global order/fallback are correct from query one.
func (e *PolicyEngine) PrepareRuntime() error {
	e.applyMu.Lock()
	defer e.applyMu.Unlock()
	if e.mgr == nil || e.handler == nil {
		return nil
	}
	model, _ := e.mgr.Snapshot()
	if err := e.handler.publishPolicyModel(model, e.rulesDir); err != nil {
		return err
	}
	e.handler.setFallback(model.Fallback.Policy)
	return nil
}

// NewPolicyEngine constructs a PolicyEngine. See the field docs above for
// which dependencies may be nil.
func NewPolicyEngine(mgr *PolicyRuleManager, subs *SubManager, h *Handler, reload func() error, rulesDir string) *PolicyEngine {
	return &PolicyEngine{
		mgr:      mgr,
		subs:     subs,
		handler:  h,
		reload:   reload,
		rulesDir: rulesDir,
	}
}

// policyManualCategories/policyManualMatchTypes enumerate every (category,
// match-type) manual rule file writeManualFiles owns: the three DNS-steering
// categories intentCategory ever produces (block/direct/blacklist —
// chnroute is a system input, never a policy-rule category) crossed with
// every MatchType rules.go supports. MatchPrefix is included even though the
// policy compiler never produces a prefix entry, so a legacy
// "<cat>.prefix.txt" left over from the pre-policy manual rule editor is
// wiped to empty like every other now-compiler-owned file (see
// writeManualFiles). policyManualCategories doubles as the policy-owned
// category set for SubManager.Sync (policyOwnedCategory, subscription.go) —
// the two consumers must agree on exactly which categories the policy
// compiler can ever emit, so they share this one slice rather than each
// keeping their own copy.
var policyManualCategories = []string{"block", "direct", "blacklist"}
var policyManualMatchTypes = []MatchType{MatchSuffix, MatchExact, MatchKeyword, MatchPrefix}

// manualRulePath mirrors Controller.manualRulePath's convention exactly
// (controller.go): suffix is the bare "<cat>.txt" (back-compat), every other
// match type is "<cat>.<type>.txt" — writeManualFiles must rewrite precisely
// the files the existing loadRuleSets/globPattern engine reads.
func (e *PolicyEngine) manualRulePath(cat string, mt MatchType) string {
	if mt == MatchSuffix {
		return filepath.Join(e.rulesDir, cat+".txt")
	}
	return filepath.Join(e.rulesDir, cat+"."+matchTypeName(mt)+".txt")
}

// writeManualFiles rewrites every manual "<category>[.<matchtype>].txt" file
// to EXACTLY cdns.Manual[cat][mt], atomically. The compiler now OWNS these
// files: a rule that was deleted (or whose kind/intent changed) must
// disappear from the file even though nothing explicitly "removed" a line
// the old Controller.AddRule/RemoveRule read-modify-write model would have
// required. A category/match-type with no compiled entries writes an EMPTY
// file, not "leave whatever was already there".
func (e *PolicyEngine) writeManualFiles(cdns CompiledDNS) error {
	for _, cat := range policyManualCategories {
		for _, mt := range policyManualMatchTypes {
			path := e.manualRulePath(cat, mt)
			if err := atomicWriteLines(path, cdns.Manual[cat][mt]); err != nil {
				return fmt.Errorf("write manual file %s: %w", path, err)
			}
		}
	}
	return nil
}

// CompileAndApply compiles the current PolicyModel and commits it to the DNS
// plane: manual rule files, subscription fetch/sync, the fallback switch,
// and a rule reload that flushes the response cache. There is no mihomo
// side to this apply anymore — a compile error is the only failure mode.
func (e *PolicyEngine) CompileAndApply(ctx context.Context) error {
	e.applyMu.Lock()
	defer e.applyMu.Unlock()
	if e.mgr == nil {
		return fmt.Errorf("policy engine: manager unavailable")
	}
	model, revision := e.mgr.Snapshot()

	cdns, err := CompilePolicy(model, e.rulesDir)
	if err != nil {
		return fmt.Errorf("policy engine: compile: %w", err)
	}

	var preparedSubs *preparedPolicySubscriptions
	if e.subs != nil {
		preparedSubs, err = e.subs.PreparePolicyGeneration(ctx, cdns.Subs)
		if err != nil {
			return fmt.Errorf("policy engine: prepare subscriptions: %w", err)
		}
		// Any exit before Publish must release the transaction locks; Rollback is
		// also safe before CommitFiles (then it is equivalent to Abort).
		defer func() {
			if !preparedSubs.released {
				_ = preparedSubs.Rollback()
			}
		}()
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("policy engine: apply canceled: %w", err)
	}

	// The durable/manual generation and live snapshots commit only if the model
	// revision is still the one compiled above. CRUD remains available during
	// network fetches; a concurrent edit makes this apply fail cleanly instead
	// of publishing stale state.
	if err := e.mgr.CommitIfRevision(revision, func() error {
		backups, err := e.backupManualFiles()
		if err != nil {
			return err
		}
		rollback := func(cause error) error {
			var rollbackErrs []error
			if restoreErr := restoreManualFiles(backups); restoreErr != nil {
				rollbackErrs = append(rollbackErrs, fmt.Errorf("manual generation rollback: %w", restoreErr))
			}
			if preparedSubs != nil {
				if restoreErr := preparedSubs.Rollback(); restoreErr != nil {
					rollbackErrs = append(rollbackErrs, fmt.Errorf("subscription generation rollback: %w", restoreErr))
				}
			}
			return errors.Join(append([]error{cause}, rollbackErrs...)...)
		}
		if preparedSubs != nil {
			if err := preparedSubs.CommitFiles(); err != nil {
				return rollback(fmt.Errorf("policy engine: commit subscriptions: %w", err))
			}
		}
		if err := e.writeManualFiles(cdns); err != nil {
			return rollback(fmt.Errorf("policy engine: %w", err))
		}
		preparedRuntime, err := CompileRuntimePolicy(model, e.rulesDir)
		if err != nil {
			return rollback(fmt.Errorf("policy engine: prepare runtime: %w", err))
		}
		if e.reload != nil {
			if e.handler != nil {
				e.handler.policyRefreshPaused.Store(true)
			}
			reloadErr := e.reload()
			if e.handler != nil {
				e.handler.policyRefreshPaused.Store(false)
			}
			if reloadErr != nil {
				return rollback(fmt.Errorf("policy engine: dns reload: %w", reloadErr))
			}
		}
		if e.handler != nil {
			e.handler.publishPreparedPolicy(model, e.rulesDir, preparedRuntime)
			e.handler.setFallback(model.Fallback.Policy)
		}
		if preparedSubs != nil {
			preparedSubs.Publish()
		}
		return nil
	}); err != nil {
		return err
	}

	return nil
}
