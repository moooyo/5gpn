// Package main (this file): the /api/mihomo/config* REST surface — the
// console's raw mihomo config editor (design §4.2/§4.3). Handler idiom
// mirrors api_policy_rules.go: decode/none → call the apply pipeline →
// writeJSON. The apply pipeline itself (applyMihomoConfig) is the ONLY path
// left in the daemon that mutates mihomo (see mihomo_client.go's package
// doc): infra-invariant check → `mihomo -t` → atomic write → hot-apply,
// exactly the order design §4.3 requires, with any failure before the
// atomic write leaving the on-disk config and running mihomo untouched.
package main

import (
	"context"
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
var mihomoBin = "/usr/local/bin/mihomo"

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
	text, err := s.mihomoStore.Read()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, s.mihomoConfigResponse(r.Context(), text))
}

// mihomoConfigResponse builds the shared {text, applied_at?, controller_reachable}
// body that GET and a successful PUT/reset all return, so the console's config
// editor (which types every /api/mihomo/config* response as MihomoConfig) gets a
// consistent shape and can refresh its view from any success — the reset recovery
// path in particular depends on getting the restored seed text back in the body.
func (s *ControlServer) mihomoConfigResponse(ctx context.Context, text string) map[string]any {
	resp := map[string]any{
		"text": text,
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

// handleMihomoConfigPut decodes {"text": "..."} and runs it through the
// apply pipeline (validate invariants → mihomo -t → atomic write →
// hot-apply). Any failure before the atomic write is a 400 with the specific
// reason; disk and running mihomo are untouched in that case.
func (s *ControlServer) handleMihomoConfigPut(w http.ResponseWriter, r *http.Request) {
	if s.mihomoStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo config management unavailable")
		return
	}
	var body struct {
		Text string `json:"text"`
	}
	if !decodeJSONBody(w, r, &body) {
		return
	}
	status, resp := s.applyMihomoConfig(r.Context(), body.Text)
	writeJSON(w, status, resp)
}

// handleMihomoConfigDefault returns the seed default text (a "reset preview")
// without writing or applying anything.
func (s *ControlServer) handleMihomoConfigDefault(w http.ResponseWriter, r *http.Request) {
	if s.mihomoStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo config management unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"text": s.mihomoStore.Default()})
}

// handleMihomoConfigReset overwrites the config with the seed default and
// runs the SAME apply pipeline as PUT — the recovery path for a
// self-inflicted bad edit that broke the invariant check or `mihomo -t`.
func (s *ControlServer) handleMihomoConfigReset(w http.ResponseWriter, r *http.Request) {
	if s.mihomoStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo config management unavailable")
		return
	}
	status, resp := s.applyMihomoConfig(r.Context(), s.mihomoStore.Default())
	writeJSON(w, status, resp)
}

// applyMihomoConfig runs the design §4.3 apply order:
//
//  1. ValidateInvariants (text-pattern, no YAML parse) → reject → 400.
//  2. `mihomo -t -f <tmpfile> -d <dir>` on a scratch temp file (never the
//     live config path) → reject → 400 with mihomo's own diagnostic text.
//  3. Atomic write (temp + rename) to the real config path.
//  4. Hot-apply via PUT /configs. A failure here does NOT roll back step 3
//     (design §4.3 step 4: "the new file is already on disk... report the
//     apply error so the operator knows a restart is pending") — reported as
//     502 with written=true so the caller can tell the two failure modes
//     apart.
//
// Returns the HTTP status and JSON body the caller should write.
func (s *ControlServer) applyMihomoConfig(ctx context.Context, text string) (int, map[string]any) {
	// Serialize the whole pipeline per store (mirrors PolicyRuleManager.mu):
	// two concurrent PUT/reset calls must not interleave their write+hot-apply
	// steps (see MihomoConfigStore.mu's doc in mihomo_config.go).
	s.mihomoStore.Lock()
	defer s.mihomoStore.Unlock()

	if err := ValidateInvariants(text, s.mihomoInfra); err != nil {
		return http.StatusBadRequest, map[string]any{"error": err.Error()}
	}

	dir := s.mihomoStore.Dir()
	if err := s.mihomoStore.EnsurePrivateDir(); err != nil {
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: mkdir %s: %v", dir, err)}
	}
	tmp, err := os.CreateTemp(dir, ".mihomo-test-*.yaml")
	if err != nil {
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: create validation temp file: %v", err)}
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: write validation temp file: %v", err)}
	}
	if err := tmp.Close(); err != nil {
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: close validation temp file: %v", err)}
	}

	if s.mihomoTest != nil {
		testCtx, cancel := context.WithTimeout(ctx, mihomoTestTimeout)
		defer cancel()
		if err := s.mihomoTest.Test(testCtx, tmpPath, dir); err != nil {
			return http.StatusBadRequest, map[string]any{"error": err.Error()}
		}
	}

	if err := atomicWriteFile(s.mihomoStore.Path(), []byte(text), 0o600); err != nil {
		return http.StatusInternalServerError, map[string]any{"error": fmt.Sprintf("mihomo: write config: %v", err)}
	}

	if s.mihomoCtl != nil {
		if err := s.mihomoCtl.PutConfigs(ctx, s.mihomoStore.Path()); err != nil {
			return http.StatusBadGateway, map[string]any{
				"error":   fmt.Sprintf("config written but hot-apply failed (mihomo will pick it up on its next restart): %v", err),
				"written": true,
			}
		}
	}

	s.mihomoAppliedAtMu.Lock()
	s.mihomoAppliedAt = time.Now()
	s.mihomoAppliedAtMu.Unlock()

	// Success returns the same {text, applied_at, controller_reachable} shape as
	// GET (not a bare {ok:true}) so the console editor refreshes from the
	// response — the reset path needs the restored seed text echoed back, and a
	// successful apply needs the real controller_reachable, not a missing field.
	return http.StatusOK, s.mihomoConfigResponse(ctx, text)
}
