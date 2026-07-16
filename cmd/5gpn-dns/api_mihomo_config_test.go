package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeMihomoTester is an injectable mihomoTester: err (if non-nil) is
// returned verbatim from Test, and every call's (path, dir) args are
// recorded so tests can assert the validation ran against a SCRATCH file,
// never the live config path.
type fakeMihomoTester struct {
	err   error
	calls int
	lastP string
	lastD string
}

func (f *fakeMihomoTester) Test(_ context.Context, path, dir string) error {
	f.calls++
	f.lastP = path
	f.lastD = dir
	return f.err
}

// fakeMihomoController is an injectable mihomoController: putErr (if
// non-nil) is returned from PutConfigs; reachable is returned from
// Reachable. Records call counts/args for assertions.
type fakeMihomoController struct {
	putErr        error
	putCalls      int
	lastPath      string
	reachable     bool
	authenticated bool
}

func (f *fakeMihomoController) PutConfigs(_ context.Context, path string) error {
	f.putCalls++
	f.lastPath = path
	return f.putErr
}

func (f *fakeMihomoController) Status(_ context.Context) MihomoStatus {
	return MihomoStatus{Reachable: f.reachable, Authenticated: f.authenticated}
}

// mihomoTestFixture bundles the ControlServer + its fakes + the seed
// InfraParams/text so a test can mutate one piece (e.g. break an invariant,
// or make the fake tester fail) without re-deriving everything.
type mihomoTestFixture struct {
	cs     *ControlServer
	token  string
	store  *MihomoConfigStore
	tester *fakeMihomoTester
	ctl    *fakeMihomoController
	infra  InfraParams
	golden string
}

// newMihomoConfigTestFixture builds a ControlServer wired for
// /api/mihomo/config testing: a real MihomoConfigStore rooted at a temp dir
// (pre-seeded with the golden config), fake tester/controller (both
// succeeding by default), and matching InfraParams.
func newMihomoConfigTestFixture(t *testing.T) *mihomoTestFixture {
	t.Helper()
	cs, token := newAPITestServer(t)

	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	golden := goldenMihomoConfig()
	if err := os.WriteFile(path, []byte(golden), 0o644); err != nil {
		t.Fatalf("seed config: %v", err)
	}

	store := NewMihomoConfigStore(path)
	tester := &fakeMihomoTester{}
	ctl := &fakeMihomoController{reachable: true, authenticated: true}
	infra := goldenInfraParams()
	cs.SetMihomoConfig(store, infra, tester, ctl)

	return &mihomoTestFixture{cs: cs, token: token, store: store, tester: tester, ctl: ctl, infra: infra, golden: golden}
}

func TestMihomoConfigAPI_Get(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)

	rec := doAPI(fx.cs, http.MethodGet, "/api/mihomo/config", nil, fx.token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Text                    string `json:"text"`
		ControllerReachable     bool   `json:"controller_reachable"`
		ControllerAuthenticated bool   `json:"controller_authenticated"`
		AppliedAt               string `json:"applied_at"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v (body=%s)", err, rec.Body.String())
	}
	if resp.Text != fx.golden {
		t.Fatalf("text mismatch:\n--- got ---\n%s\n--- want ---\n%s", resp.Text, fx.golden)
	}
	if !resp.ControllerReachable {
		t.Fatalf("expected controller_reachable=true (fake reports reachable)")
	}
	if !resp.ControllerAuthenticated {
		t.Fatalf("expected controller_authenticated=true (fake accepts configured secret)")
	}
	if resp.AppliedAt != "" {
		t.Fatalf("expected no applied_at before any PUT/reset, got %q", resp.AppliedAt)
	}
}

func TestMihomoConfigAPI_Get_Unwired(t *testing.T) {
	cs, token := newAPITestServer(t) // SetMihomoConfig never called
	rec := doAPI(cs, http.MethodGet, "/api/mihomo/config", nil, token, true)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want 503 (unwired)", rec.Code)
	}
}

// TestMihomoConfigAPI_Put_Valid asserts a valid PUT writes the new text,
// hot-applies it (fake -t OK + fake PutConfigs), and reports 200 — and that a
// subsequent GET reflects the new text and a populated applied_at.
func TestMihomoConfigAPI_Put_Valid(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)

	newText := fx.golden + "\n# a harmless trailing comment\n"
	body, _ := json.Marshal(map[string]string{"text": newText})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config", body, fx.token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}

	// The success body must carry the full MihomoConfig shape (text +
	// controller_reachable + applied_at), NOT a bare {ok:true}: the console
	// editor types PUT/reset as MihomoConfig and refreshes its view from it.
	var putResp struct {
		Text                string `json:"text"`
		AppliedAt           string `json:"applied_at"`
		ControllerReachable bool   `json:"controller_reachable"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &putResp); err != nil {
		t.Fatalf("decode PUT response: %v", err)
	}
	if putResp.Text != newText {
		t.Fatalf("PUT success text=%q want %q", putResp.Text, newText)
	}
	if !putResp.ControllerReachable {
		t.Fatalf("PUT success should report controller_reachable=true (fake reachable)")
	}
	if putResp.AppliedAt == "" {
		t.Fatalf("PUT success should carry applied_at")
	}

	onDisk, err := fx.store.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if onDisk != newText {
		t.Fatalf("on-disk config not updated:\n--- got ---\n%s\n--- want ---\n%s", onDisk, newText)
	}
	if info, err := os.Stat(fx.store.Path()); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("config mode = %v, %v; want 0600", func() os.FileMode {
			if info == nil {
				return 0
			}
			return info.Mode().Perm()
		}(), err)
	}
	if info, err := os.Stat(fx.store.Dir()); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("config dir mode = %v, %v; want 0700", func() os.FileMode {
			if info == nil {
				return 0
			}
			return info.Mode().Perm()
		}(), err)
	}

	if fx.tester.calls != 1 {
		t.Fatalf("expected exactly 1 mihomo -t call, got %d", fx.tester.calls)
	}
	if fx.tester.lastP == fx.store.Path() {
		t.Fatalf("mihomo -t must validate a SCRATCH file, not the live config path")
	}
	if fx.ctl.putCalls != 1 || fx.ctl.lastPath != fx.store.Path() {
		t.Fatalf("expected PutConfigs(ctx, %q) exactly once, got calls=%d lastPath=%q", fx.store.Path(), fx.ctl.putCalls, fx.ctl.lastPath)
	}

	// A follow-up GET reflects the write and a populated applied_at.
	rec = doAPI(fx.cs, http.MethodGet, "/api/mihomo/config", nil, fx.token, true)
	var resp struct {
		Text      string `json:"text"`
		AppliedAt string `json:"applied_at"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Text != newText {
		t.Fatalf("GET after PUT: text=%q want %q", resp.Text, newText)
	}
	if resp.AppliedAt == "" {
		t.Fatalf("expected applied_at to be populated after a successful PUT")
	}
}

// TestMihomoConfigAPI_Put_MissingController asserts a config missing the
// external-controller invariant is rejected 400 with the exact reason, and
// that the disk is left untouched (no `mihomo -t` exec, no write, no apply).
func TestMihomoConfigAPI_Put_MissingController(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)

	broken := strings.Replace(fx.golden, "external-controller-tls: 127.0.0.1:9090\n", "", 1)
	body, _ := json.Marshal(map[string]string{"text": broken})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config", body, fx.token, true)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400; body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Error != "missing required infrastructure: controller" {
		t.Fatalf("error=%q, want the exact controller message", resp.Error)
	}

	onDisk, err := fx.store.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if onDisk != fx.golden {
		t.Fatalf("disk must be untouched on a rejected PUT")
	}
	if fx.tester.calls != 0 {
		t.Fatalf("mihomo -t must not run when the invariant check itself fails, got %d calls", fx.tester.calls)
	}
	if fx.ctl.putCalls != 0 {
		t.Fatalf("PutConfigs must not run when the invariant check fails, got %d calls", fx.ctl.putCalls)
	}
}

// TestMihomoConfigAPI_Put_FailsMihomoTest asserts a config that passes the
// invariant check but fails `mihomo -t` is rejected 400 with the stderr, and
// the disk is left untouched.
func TestMihomoConfigAPI_Put_FailsMihomoTest(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	fx.tester.err = errors.New("mihomo -t: 1: 2: yaml: line 3: mapping values are not allowed in this context")

	newText := fx.golden + "\nsome: garbage: here\n"
	body, _ := json.Marshal(map[string]string{"text": newText})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config", body, fx.token, true)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400; body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !strings.Contains(resp.Error, "mapping values are not allowed") {
		t.Fatalf("error=%q should surface mihomo -t's stderr", resp.Error)
	}

	onDisk, err := fx.store.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if onDisk != fx.golden {
		t.Fatalf("disk must be untouched when mihomo -t fails")
	}
	if fx.ctl.putCalls != 0 {
		t.Fatalf("PutConfigs must not run when mihomo -t fails, got %d calls", fx.ctl.putCalls)
	}
}

// TestMihomoConfigAPI_Put_ApplyFails_DiskStillUpdated asserts the partial-
// success case (design §4.3 step 4): validation + `mihomo -t` pass, the
// atomic write to disk succeeds, but the hot-apply PUT /configs fails. The
// response must say so (502, written=true) and the on-disk file MUST already
// reflect the new text — mihomo will pick it up on its next restart.
func TestMihomoConfigAPI_Put_ApplyFails_DiskStillUpdated(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	fx.ctl.putErr = errors.New("dial tcp 127.0.0.1:9090: connect: connection refused")

	newText := fx.golden + "\n# a harmless trailing comment\n"
	body, _ := json.Marshal(map[string]string{"text": newText})
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config", body, fx.token, true)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status=%d, want 502; body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Error   string `json:"error"`
		Written bool   `json:"written"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !resp.Written {
		t.Fatalf("expected written=true (disk write succeeded before the apply failure)")
	}

	onDisk, err := fx.store.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if onDisk != newText {
		t.Fatalf("disk must reflect the new (validated) text even though hot-apply failed")
	}
}

// TestMihomoConfigAPI_Default returns the seed text without touching disk or
// the controller.
func TestMihomoConfigAPI_Default(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	t.Setenv("DNS_CONSOLE_DOMAIN", fx.infra.ConsoleDomain)
	t.Setenv("DNS_ZASH_DOMAIN", fx.infra.ZashDomain)
	t.Setenv("DNS_PROFILE_DOMAIN", fx.infra.ProfileDomain)
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "203.0.113.10")
	t.Setenv("DNS_GATEWAY_IP", fx.infra.GatewayIP)
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")

	rec := doAPI(fx.cs, http.MethodGet, "/api/mihomo/config/default", nil, fx.token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Text != goldenMihomoConfig() {
		t.Fatalf("default text mismatch:\n--- got ---\n%s\n--- want ---\n%s", resp.Text, goldenMihomoConfig())
	}
	if fx.tester.calls != 0 || fx.ctl.putCalls != 0 {
		t.Fatalf("GET .../default must not validate or apply anything")
	}
	onDisk, _ := fx.store.Read()
	if onDisk != fx.golden {
		t.Fatalf("GET .../default must not touch the on-disk config")
	}
}

// TestMihomoConfigAPI_Reset restores the seed default: it should overwrite a
// broken on-disk config and successfully re-apply it.
func TestMihomoConfigAPI_Reset(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	t.Setenv("DNS_CONSOLE_DOMAIN", fx.infra.ConsoleDomain)
	t.Setenv("DNS_ZASH_DOMAIN", fx.infra.ZashDomain)
	t.Setenv("DNS_PROFILE_DOMAIN", fx.infra.ProfileDomain)
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "203.0.113.10")
	t.Setenv("DNS_GATEWAY_IP", fx.infra.GatewayIP)
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")

	// Break the on-disk config first (simulating a prior bad edit).
	if err := os.WriteFile(fx.store.Path(), []byte("garbage: not a real config"), 0o644); err != nil {
		t.Fatalf("seed broken config: %v", err)
	}

	rec := doAPI(fx.cs, http.MethodPost, "/api/mihomo/config/reset", nil, fx.token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}

	// The reset response body must echo the restored seed text — the recovery
	// path: the console editor replaces its textarea from this body, so a bare
	// {ok:true} would leave the operator staring at the old broken config.
	var resetResp struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resetResp); err != nil {
		t.Fatalf("decode reset response: %v", err)
	}
	if resetResp.Text != goldenMihomoConfig() {
		t.Fatalf("reset response should echo the restored seed text, got %q", resetResp.Text)
	}

	onDisk, err := fx.store.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if onDisk != goldenMihomoConfig() {
		t.Fatalf("reset should restore the seed default:\n--- got ---\n%s\n--- want ---\n%s", onDisk, goldenMihomoConfig())
	}
	if fx.ctl.putCalls != 1 {
		t.Fatalf("reset should hot-apply the restored default, got %d PutConfigs calls", fx.ctl.putCalls)
	}
}
