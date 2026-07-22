// Package main implements the raw mihomo config API. Its apply pipeline checks
// infrastructure invariants, runs `mihomo -t`, atomically writes, and hot-applies.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// mihomoBin is the mihomo binary the apply pipeline validates candidate
// configs against. A var (not a const) solely so tests can point it at a
// fake script; production never overrides it.
var mihomoBin = "/opt/5gpn/bin/mihomo"

// mihomoTester runs `mihomo -t` against a candidate config file, returning
// nil on success or an error whose message carries mihomo's own diagnostic
// output on failure. Defined as an interface so api_mihomo_config_test.go can
// fake it instead of exec'ing a real mihomo binary.
type mihomoTester interface {
	Test(ctx context.Context, path, dir string) error
}

// realMihomoTester execs the real mihomo binary: `mihomo -t -f <path> -d <dir>`.
type realMihomoTester struct{}

func (realMihomoTester) Test(ctx context.Context, path, dir string) error {
	out, err := exec.CommandContext(ctx, mihomoBin, "-t", "-f", path, "-d", dir).CombinedOutput()
	if err != nil {
		return fmt.Errorf("mihomo -t: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// mihomoApplier hot-applies an on-disk config path to the running mihomo
// controller. *MihomoClient satisfies this via PutConfigs.
type mihomoApplier interface {
	PutConfigs(ctx context.Context, path string) error
}

// mihomoStatuser is a narrow read-only health/authentication probe against the
// controller. *MihomoClient satisfies this via Reachable.
type mihomoStatuser interface {
	Status(ctx context.Context) MihomoStatus
}

// mihomoController is the union api_mihomo_config.go needs from the
// controller client — hot-apply plus a reachability read for GET's
// controller_reachable field. *MihomoClient satisfies it; tests fake it.
type mihomoController interface {
	mihomoApplier
	mihomoStatuser
}

// SetMihomoConfig wires the mihomo raw-config editor into the control server:
// store is the on-disk config file; infra is the set of invariant values
// ValidateInvariants checks a submitted config against (see
// InfraParamsFromConfig); tester runs `mihomo -t`; ctl hot-applies via the
// loopback controller and reports reachability. A nil store leaves the
// /api/mihomo/config* endpoints reporting 503 (unavailable) rather than
// panicking.
func (s *ControlServer) SetMihomoConfig(store *MihomoConfigStore, infra InfraParams, tester mihomoTester, ctl mihomoController) {
	s.mihomoStore = store
	s.mihomoInfra = infra
	s.mihomoTest = tester
	s.mihomoCtl = ctl
}

// mihomoTestTimeout bounds how long a single `mihomo -t` exec may run before
// the request context's own deadline would; validation should be near-
// instant, so this is a generous ceiling against a wedged/hung binary, not a
// tuning knob.
const mihomoTestTimeout = 20 * time.Second

// handleMihomoConfigGet returns the on-disk config text plus light metadata:
// the last successful-apply time (omitted if the daemon hasn't applied one
// this run) and whether the mihomo controller currently answers at all.
func (s *ControlServer) handleMihomoConfigGet(w http.ResponseWriter, r *http.Request) {
	if s.mihomoStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo config management unavailable")
		return
	}
	s.mihomoStore.Lock()
	text, err := s.mihomoStore.Read()
	s.mihomoStore.Unlock()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, s.mihomoConfigResponse(r.Context(), text))
}

// mihomoConfigResponse builds the shared
// {text, revision, applied_at?, controller_reachable} body that GET and a
// successful PUT/reset all return, so the console's config editor gets a
// consistent snapshot and can refresh its view from any success.
func (s *ControlServer) mihomoConfigResponse(ctx context.Context, text string) map[string]any {
	resp := map[string]any{
		"text":     text,
		"revision": mihomoConfigRevision(text),
	}
	status := s.mihomoStatus(ctx)
	resp["controller_reachable"] = status.Reachable
	resp["controller_authenticated"] = status.Authenticated
	s.mihomoAppliedAtMu.Lock()
	appliedAt := s.mihomoAppliedAt
	s.mihomoAppliedAtMu.Unlock()
	if !appliedAt.IsZero() {
		resp["applied_at"] = appliedAt.UTC().Format(time.RFC3339)
	}
	return resp
}

// mihomoReachable probes the controller with a short bounded timeout,
// independent of the request context's own deadline — a slow/hung
// controller must not make the whole GET hang.
func (s *ControlServer) mihomoStatus(ctx context.Context) MihomoStatus {
	if s.mihomoCtl == nil {
		return MihomoStatus{}
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return s.mihomoCtl.Status(ctx)
}

// handleMihomoConfigPut decodes {"text": "...", "revision": "..."} and runs it through the
// apply pipeline (validate invariants → mihomo -t → atomic write →
// hot-apply). Any failure before the atomic write is a 400 with the specific
// reason; disk and running mihomo are untouched in that case.
func (s *ControlServer) handleMihomoConfigPut(w http.ResponseWriter, r *http.Request) {
	if s.mihomoStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo config management unavailable")
		return
	}
	var body struct {
		Text     *string `json:"text"`
		Revision string  `json:"revision"`
	}
	if !decodeJSONBody(w, r, &body) {
		return
	}
	if body.Text == nil || !validMihomoConfigRevision(body.Revision) {
		writeErr(w, http.StatusBadRequest, "text and a valid revision are required")
		return
	}
	unlock, err := s.lockInterceptMihomoCandidate(*body.Text)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errInterceptModuleConflict) {
			status = http.StatusConflict
		}
		writeErr(w, status, err.Error())
		return
	}
	status, resp := s.applyMihomoConfig(r.Context(), *body.Text, false, body.Revision)
	unlock()
	if s.interceptModules != nil && (status == http.StatusOK || mihomoConfigWritten(resp)) {
		_ = s.interceptModules.ReconcileMihomoText(*body.Text)
	}
	writeJSON(w, status, resp)
}

// handleMihomoConfigReset overwrites the config with the seed default and
// runs the SAME apply pipeline as PUT — the recovery path for a
// self-inflicted bad edit that broke the invariant check or `mihomo -t`.
func (s *ControlServer) handleMihomoConfigReset(w http.ResponseWriter, r *http.Request) {
	if s.mihomoStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo config management unavailable")
		return
	}
	var body struct {
		Revision string `json:"revision"`
	}
	if !decodeJSONBody(w, r, &body) {
		return
	}
	if !validMihomoConfigRevision(body.Revision) {
		writeErr(w, http.StatusBadRequest, "a valid revision is required")
		return
	}
	candidate := s.mihomoStore.Default()
	unlock, err := s.lockInterceptMihomoCandidate(candidate)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errInterceptModuleConflict) {
			status = http.StatusConflict
		}
		writeErr(w, status, err.Error())
		return
	}
	status, resp := s.applyMihomoConfig(r.Context(), candidate, true, body.Revision)
	unlock()
	if s.interceptModules != nil && (status == http.StatusOK || mihomoConfigWritten(resp)) {
		_ = s.interceptModules.ReconcileMihomoText(candidate)
	}
	writeJSON(w, status, resp)
}

func (s *ControlServer) lockInterceptMihomoCandidate(text string) (func(), error) {
	if s.interceptModules == nil {
		return func() {}, nil
	}
	return s.interceptModules.LockMihomoCandidate(text)
}

func validMihomoConfigRevision(revision string) bool {
	if len(revision) != sha256.Size*2 || revision != strings.ToLower(revision) {
		return false
	}
	_, err := hex.DecodeString(revision)
	return err == nil
}

func mihomoConfigWritten(response map[string]any) bool {
	written, _ := response["written"].(bool)
	return written
}

func mihomoConfigRevision(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func mihomoConfigRevisionConflict(text string) (int, map[string]any) {
	return http.StatusConflict, map[string]any{
		"error":    "mihomo config revision changed",
		"revision": mihomoConfigRevision(text),
	}
}

// applyMihomoConfig runs the apply order:
//
//  1. Compare the submitted revision with the current file → reject → 409.
//  2. ValidateInvariants (structural YAML parse) → reject → 400.
//  3. `mihomo -t -f <tmpfile> -d <dir>` on a scratch temp file (never the
//     live config path) → reject → 400 with mihomo's own diagnostic text.
//  4. Recompare the revision, then atomically write to the real config path.
//  5. Hot-apply via PUT /configs. A failure here does NOT roll back step 4
//     because the new file is already durable — reported as
//     502 with written=true so the caller can tell the two failure modes
//     apart.
//
// Returns the HTTP status and JSON body the caller should write.
func (s *ControlServer) applyMihomoConfig(ctx context.Context, text string, backup bool, expectedRevision string) (int, map[string]any) {
	// Serialize the whole pipeline per store (mirrors PolicyRuleManager.mu):
	// two concurrent PUT/reset calls must not interleave their write+hot-apply
	// steps (see MihomoConfigStore.mu's doc in mihomo_config.go).
	s.mihomoStore.Lock()
	defer s.mihomoStore.Unlock()
	current, err := s.mihomoStore.Read()
	if err != nil {
		return http.StatusInternalServerError, map[string]any{"error": err.Error()}
	}
	if mihomoConfigRevision(current) != expectedRevision {
		return mihomoConfigRevisionConflict(current)
	}
	status, resp, _ := s.applyMihomoConfigLockedCAS(ctx, text, backup, expectedRevision)
	return status, resp
}

// applyMihomoConfigLocked is the store-lock-held form of applyMihomoConfig.
// The third result reports whether the candidate reached the live path. It is
// used by structured, revision-checked edits that must distinguish a
// pre-publication rejection from a controller failure after publication.
// Callers must hold s.mihomoStore's lock for the entire call.
func (s *ControlServer) applyMihomoConfigLocked(ctx context.Context, text string, backup bool) (int, map[string]any, bool) {
	return s.applyMihomoConfigLockedCAS(ctx, text, backup, "")
}

// applyMihomoConfigLockedCAS applies a raw-editor candidate while protecting
// its read revision from both other API writes and external file edits during
// candidate validation. An empty expectedRevision is reserved for callers
// that perform their own structural revision transaction.
func (s *ControlServer) applyMihomoConfigLockedCAS(ctx context.Context, text string, backup bool, expectedRevision string) (int, map[string]any, bool) {

	if err := ValidateInvariants(text, s.mihomoInfra); err != nil {
		return http.StatusBadRequest, map[string]any{"error": err.Error()}, false
	}

	dir := s.mihomoStore.Dir()
	if err := s.mihomoStore.EnsurePrivateDir(); err != nil {
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: mkdir %s: %v", dir, err)}, false
	}
	tmp, err := os.CreateTemp(dir, ".mihomo-test-*.yaml")
	if err != nil {
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: create validation temp file: %v", err)}, false
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: write validation temp file: %v", err)}, false
	}
	if err := tmp.Close(); err != nil {
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: close validation temp file: %v", err)}, false
	}

	if s.mihomoTest != nil {
		testCtx, cancel := context.WithTimeout(ctx, mihomoTestTimeout)
		defer cancel()
		if err := s.mihomoTest.Test(testCtx, tmpPath, dir); err != nil {
			return http.StatusBadRequest, map[string]any{"error": err.Error()}, false
		}
	}
	var currentBeforePublish string
	if expectedRevision != "" {
		currentBeforePublish, err = s.mihomoStore.Read()
		if err != nil {
			return http.StatusInternalServerError, map[string]any{"error": err.Error()}, false
		}
		if mihomoConfigRevision(currentBeforePublish) != expectedRevision {
			status, resp := mihomoConfigRevisionConflict(currentBeforePublish)
			return status, resp, false
		}
	}
	if backup {
		if currentBeforePublish == "" {
			currentBeforePublish, err = s.mihomoStore.Read()
			if err != nil {
				return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: read config for backup: %v", err)}, false
			}
		}
		if err := atomicWriteFile(s.mihomoStore.BackupPath(), []byte(currentBeforePublish), 0o640); err != nil {
			return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: write backup: %v", err)}, false
		}
	}

	if err := atomicWriteFile(s.mihomoStore.Path(), []byte(text), 0o640); err != nil {
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: write config: %v", err)}, false
	}

	if s.mihomoCtl != nil {
		if err := s.mihomoCtl.PutConfigs(ctx, s.mihomoStore.Path()); err != nil {
			return http.StatusBadGateway, map[string]any{
				"error":   fmt.Sprintf("config written but hot-apply failed (mihomo will pick it up on its next restart): %v", err),
				"written": true,
			}, true
		}
	}

	s.mihomoAppliedAtMu.Lock()
	s.mihomoAppliedAt = time.Now()
	s.mihomoAppliedAtMu.Unlock()

	// Success returns the same {text, applied_at, controller_reachable} shape as
	// GET (not a bare {ok:true}) so the console editor refreshes from the
	// response — the reset path needs the restored seed text echoed back, and a
	// successful apply needs the real controller_reachable, not a missing field.
	return http.StatusOK, s.mihomoConfigResponse(ctx, text), true
}
