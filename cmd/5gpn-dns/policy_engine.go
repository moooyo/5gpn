// PolicyEngine reconciles policy-owned subscriptions and atomically publishes
// the resulting ordered DNS policy snapshot. It never mutates mihomo config.
package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
)

// PolicyEngine ties the policy model, compiler, subscription fetcher, and
// live handler snapshot together. subs/handler may be nil — mirroring every
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

// CompileAndApply compiles the current PolicyModel and commits it to the DNS
// plane: subscription cache reconciliation, a rule reload, and one ordered
// runtime snapshot publication.
func (e *PolicyEngine) CompileAndApply(ctx context.Context) error {
	e.applyMu.Lock()
	defer e.applyMu.Unlock()
	if e.mgr == nil {
		return fmt.Errorf("policy engine: manager unavailable")
	}
	model, revision := e.mgr.Snapshot()

	cdns, err := CompilePolicy(model)
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

	// The durable subscription generation and live snapshot commit only if the model
	// revision is still the one compiled above. CRUD remains available during
	// network fetches; a concurrent edit makes this apply fail cleanly instead
	// of publishing stale state.
	if err := e.mgr.CommitIfRevision(revision, func() error {
		rollback := func(cause error) error {
			var rollbackErrs []error
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
