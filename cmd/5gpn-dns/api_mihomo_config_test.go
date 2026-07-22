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

func TestMihomoBinaryPath(t *testing.T) {
	if mihomoBin != "/opt/5gpn/bin/mihomo" {
		t.Fatalf("mihomoBin = %q", mihomoBin)
	}
}

// fakeMihomoTester is an injectable mihomoTester: err (if non-nil) is
// returned verbatim from Test, and every call's (path, dir) args are
// recorded so tests can assert the validation ran against a SCRATCH file,
// never the live config path.
type fakeMihomoTester struct {
	err    error
	calls  int
	lastP  string
	lastD  string
	onTest func()
}

func (f *fakeMihomoTester) Test(_ context.Context, path, dir string) error {
	f.calls++
	f.lastP = path
	f.lastD = dir
	if f.onTest != nil {
		f.onTest()
	}
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

func mihomoConfigPutBody(t *testing.T, text, revision string) []byte {
	t.Helper()
	body, err := json.Marshal(map[string]string{"text": text, "revision": revision})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func mihomoConfigResetBody(t *testing.T, revision string) []byte {
	t.Helper()
	body, err := json.Marshal(map[string]string{"revision": revision})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

// newMihomoConfigTestFixture builds a ControlServer wired for
// /api/mihomo/config testing: a real MihomoConfigStore rooted at a temp dir
// (pre-seeded with the golden config), fake tester/controller (both
// succeeding by default), and matching InfraParams.
func newMihomoConfigTestFixture(t *testing.T) *mihomoTestFixture {
	t.Helper()
	cs, token := newAPITestServer(t)

	dir := filepath.Join(t.TempDir(), "mihomo")
	if err := os.Mkdir(dir, 0o770); err != nil {
		t.Fatalf("create shared config dir: %v", err)
	}
	if err := os.Chmod(dir, 0o770); err != nil {
		t.Fatalf("set shared config dir mode: %v", err)
	}
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

func seedLegacyMihomoBackup(t *testing.T, store *MihomoConfigStore) (string, string) {
	t.Helper()
	legacyPath := store.Path() + ".bak"
	legacyBody := "mihomo-owned legacy backup\n"
	if err := os.WriteFile(legacyPath, []byte(legacyBody), 0o660); err != nil {
		t.Fatalf("seed legacy mihomo backup: %v", err)
	}
	if filesystemSupportsPOSIXModes(t, store.Dir()) {
		if err := os.Chmod(store.Dir(), 0o770|os.ModeSetgid|os.ModeSticky); err != nil {
			t.Fatalf("set sticky mihomo config directory: %v", err)
		}
	}
	return legacyPath, legacyBody
}

func TestMihomoConfigAPI_Get(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)

	rec := doAPI(fx.cs, http.MethodGet, "/api/mihomo/config", nil, fx.token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Text                    string `json:"text"`
		Revision                string `json:"revision"`
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
	if resp.Revision != mihomoConfigRevision(fx.golden) {
		t.Fatalf("revision=%q want SHA-256 of original config bytes", resp.Revision)
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

func TestMihomoConfigAPIRejectsDeletingBoundInterceptionGroup(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	withJapan := strings.Replace(fx.golden,
		"  - {name: Proxies, type: select, proxies: [DIRECT]}",
		"  - {name: Proxies, type: select, proxies: [DIRECT]}\n  - {name: Japan, type: select, proxies: [DIRECT]}", 1)
	if err := os.WriteFile(fx.store.Path(), []byte(withJapan), 0o660); err != nil {
		t.Fatal(err)
	}
	module := testModuleSnapshot()
	module.EgressGroup = "Japan"
	interceptPath := filepath.Join(t.TempDir(), "config.json")
	_, body := testInterceptDocument(t, module)
	if err := os.WriteFile(interceptPath, body, 0o660); err != nil {
		t.Fatal(err)
	}
	manager := NewInterceptModuleManager(NewInterceptConfigStore(interceptPath), nil, nil, fx.store, fx.infra, fx.tester, fx.ctl)
	fx.cs.SetInterceptModuleManager(manager)

	put := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config",
		mihomoConfigPutBody(t, fx.golden, mihomoConfigRevision(withJapan)), fx.token, true)
	if put.Code != http.StatusConflict || !strings.Contains(put.Body.String(), "Japan") {
		t.Fatalf("bound group deletion status=%d body=%s", put.Code, put.Body.String())
	}
	if got, _ := fx.store.Read(); got != withJapan || fx.tester.calls != 0 || fx.ctl.putCalls != 0 {
		t.Fatalf("rejected deletion changed config or reached apply: tester=%d controller=%d", fx.tester.calls, fx.ctl.putCalls)
	}

	t.Setenv("DNS_BASE_DOMAIN", "5gpn.test")
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "203.0.113.10")
	t.Setenv("DNS_GATEWAY_IP", fx.infra.GatewayIP)
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")
	reset := doAPI(fx.cs, http.MethodPost, "/api/mihomo/config/reset",
		mihomoConfigResetBody(t, mihomoConfigRevision(withJapan)), fx.token, true)
	if reset.Code != http.StatusConflict || !strings.Contains(reset.Body.String(), "Japan") {
		t.Fatalf("bound group reset status=%d body=%s", reset.Code, reset.Body.String())
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
	body := mihomoConfigPutBody(t, newText, mihomoConfigRevision(fx.golden))
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config", body, fx.token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}

	// The success body must carry the full MihomoConfig shape (text +
	// controller_reachable + applied_at), NOT a bare {ok:true}: the console
	// editor types PUT/reset as MihomoConfig and refreshes its view from it.
	var putResp struct {
		Text                string `json:"text"`
		Revision            string `json:"revision"`
		AppliedAt           string `json:"applied_at"`
		ControllerReachable bool   `json:"controller_reachable"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &putResp); err != nil {
		t.Fatalf("decode PUT response: %v", err)
	}
	if putResp.Text != newText {
		t.Fatalf("PUT success text=%q want %q", putResp.Text, newText)
	}
	if putResp.Revision != mihomoConfigRevision(newText) {
		t.Fatalf("PUT success revision=%q want candidate revision", putResp.Revision)
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
	posixModes := filesystemSupportsPOSIXModes(t, fx.store.Dir())
	if info, err := os.Stat(fx.store.Path()); err != nil || posixModes && info.Mode().Perm() != 0o640 {
		t.Fatalf("config mode = %v, %v; want 0640", func() os.FileMode {
			if info == nil {
				return 0
			}
			return info.Mode().Perm()
		}(), err)
	}
	if info, err := os.Stat(fx.store.Dir()); err != nil || posixModes && info.Mode().Perm() != 0o770 {
		t.Fatalf("config dir mode = %v, %v; want 0770", func() os.FileMode {
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
	body := mihomoConfigPutBody(t, broken, mihomoConfigRevision(fx.golden))
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
	fx.tester.err = errors.New("mihomo -t: candidate rejected by fake validator")

	// This is valid YAML and preserves every infrastructure invariant. The fake
	// tester is therefore the only layer that can reject it.
	newText := fx.golden + "\nexperimental-test-option: true\n"
	body := mihomoConfigPutBody(t, newText, mihomoConfigRevision(fx.golden))
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
	if !strings.Contains(resp.Error, "candidate rejected by fake validator") {
		t.Fatalf("error=%q should surface mihomo -t's stderr", resp.Error)
	}
	if fx.tester.calls != 1 {
		t.Fatalf("mihomo -t calls = %d, want exactly 1", fx.tester.calls)
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

func TestMihomoConfigAPI_Put_RejectsDuplicateKeyBeforeMihomoTest(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	duplicate := strings.Replace(fx.golden, "secret: 's3cr3t'\n", "secret: 's3cr3t'\nsecret: attacker\n", 1)
	body := mihomoConfigPutBody(t, duplicate, mihomoConfigRevision(fx.golden))
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
	if !strings.Contains(resp.Error, "invalid mihomo YAML") {
		t.Fatalf("error=%q, want structural YAML rejection", resp.Error)
	}
	if fx.tester.calls != 0 {
		t.Fatalf("mihomo -t must not run for duplicate keys, got %d calls", fx.tester.calls)
	}
	if fx.ctl.putCalls != 0 {
		t.Fatalf("PutConfigs must not run for duplicate keys, got %d calls", fx.ctl.putCalls)
	}
	onDisk, err := fx.store.Read()
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if onDisk != fx.golden {
		t.Fatal("disk changed after duplicate-key rejection")
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
	body := mihomoConfigPutBody(t, newText, mihomoConfigRevision(fx.golden))
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

func TestMihomoConfigAPI_AmbiguousHotApplyFailureWithdrawsInterceptionOverlay(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	module := testModuleSnapshot()
	interceptPath := filepath.Join(t.TempDir(), "config.json")
	_, interceptBody := testInterceptDocument(t, module)
	if err := os.WriteFile(interceptPath, interceptBody, 0o660); err != nil {
		t.Fatal(err)
	}
	handler := &Handler{}
	manager := NewInterceptModuleManager(
		NewInterceptConfigStore(interceptPath), handler, nil, fx.store, fx.infra, fx.tester, fx.ctl,
	)
	fx.cs.SetInterceptModuleManager(manager)
	view, err := manager.View()
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := manager.Update(context.Background(), module.ID, interceptModuleUpdate{Revision: view.Revision, Enabled: &enabled}); err != nil {
		t.Fatal(err)
	}
	if handler.decideName("api.example.com").Action != actionGateway {
		t.Fatal("interception overlay was not active before the ambiguous apply")
	}
	current, err := fx.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	fx.ctl.putErr = errors.New("controller response lost after request transmission")
	recorder := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config",
		mihomoConfigPutBody(t, fx.golden, mihomoConfigRevision(current)), fx.token, true)
	if recorder.Code != http.StatusBadGateway || !strings.Contains(recorder.Body.String(), `"written":true`) {
		t.Fatalf("ambiguous apply status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if handler.decideName("api.example.com").Action == actionGateway {
		t.Fatal("interception overlay remained active after an ambiguous apply removed its routing block")
	}
}

func TestMihomoConfigAPI_Put_RequiresStrictRevisionBody(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	tests := []struct {
		name string
		body string
	}{
		{name: "missing revision", body: `{"text":"candidate"}`},
		{name: "missing text", body: `{"revision":"` + mihomoConfigRevision(fx.golden) + `"}`},
		{name: "invalid revision", body: `{"text":"candidate","revision":"nope"}`},
		{name: "unknown field", body: `{"text":"candidate","revision":"` + mihomoConfigRevision(fx.golden) + `","extra":true}`},
		{name: "multiple values", body: `{"text":"candidate","revision":"` + mihomoConfigRevision(fx.golden) + `"} {}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config", []byte(tc.body), fx.token, true)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status=%d want 400 body=%s", rec.Code, rec.Body.String())
			}
		})
	}
	if got, _ := fx.store.Read(); got != fx.golden {
		t.Fatal("invalid request body changed config")
	}
	if fx.tester.calls != 0 || fx.ctl.putCalls != 0 {
		t.Fatalf("invalid request body reached validator/controller: %d/%d", fx.tester.calls, fx.ctl.putCalls)
	}
}

func TestMihomoConfigAPI_Put_DetectsExternalEditDuringValidation(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	externalText := fx.golden + "\n# external edit during validation\n"
	fx.tester.onTest = func() {
		if err := os.WriteFile(fx.store.Path(), []byte(externalText), 0o660); err != nil {
			t.Errorf("external edit: %v", err)
		}
	}
	candidate := fx.golden + "\n# raw editor candidate\n"
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config", mihomoConfigPutBody(t, candidate, mihomoConfigRevision(fx.golden)), fx.token, true)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status=%d want 409 body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Revision string `json:"revision"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Revision != mihomoConfigRevision(externalText) {
		t.Fatalf("revision=%q want external edit revision", resp.Revision)
	}
	if got, _ := fx.store.Read(); got != externalText {
		t.Fatal("raw candidate overwrote external edit made during validation")
	}
	if fx.tester.calls != 1 || fx.ctl.putCalls != 0 {
		t.Fatalf("validation/controller calls=%d/%d want 1/0", fx.tester.calls, fx.ctl.putCalls)
	}
}

func TestMihomoConfigAPI_StaleRawPutAfterIngressModuleUpdate(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	rawGet := doAPI(fx.cs, http.MethodGet, "/api/mihomo/config", nil, fx.token, true)
	var raw struct {
		Revision string `json:"revision"`
	}
	if err := json.Unmarshal(rawGet.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	modules := getIngressModules(t, fx)
	disableBody, _ := json.Marshal(map[string]any{"enabled": false, "revision": modules.Revision})
	updatedRec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, disableBody, fx.token, true)
	if updatedRec.Code != http.StatusOK {
		t.Fatalf("disable status=%d body=%s", updatedRec.Code, updatedRec.Body.String())
	}
	updatedText, err := fx.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	rec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/config", mihomoConfigPutBody(t, fx.golden+"\n# stale raw edit\n", raw.Revision), fx.token, true)
	if rec.Code != http.StatusConflict {
		t.Fatalf("stale raw PUT status=%d want 409 body=%s", rec.Code, rec.Body.String())
	}
	var conflict struct {
		Revision string `json:"revision"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &conflict); err != nil {
		t.Fatal(err)
	}
	if conflict.Revision != mihomoConfigRevision(updatedText) {
		t.Fatalf("conflict revision=%q want updated config revision", conflict.Revision)
	}
	if got, _ := fx.store.Read(); got != updatedText {
		t.Fatal("stale raw PUT overwrote ingress module update")
	}
	if view := analyzeSpeedtestModule(updatedText, fx.infra).View; view.Enabled || !view.Manageable {
		t.Fatalf("disabled module state not retained: %+v", view)
	}
	if fx.tester.calls != 1 || fx.ctl.putCalls != 1 {
		t.Fatalf("stale raw PUT reached validator/controller: %d/%d", fx.tester.calls, fx.ctl.putCalls)
	}
}

func TestMihomoConfigAPI_StaleResetAfterIngressModuleUpdate(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	t.Setenv("DNS_BASE_DOMAIN", "5gpn.test")
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "203.0.113.10")
	t.Setenv("DNS_GATEWAY_IP", fx.infra.GatewayIP)
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")

	rawRevision := mihomoConfigRevision(fx.golden)
	modules := getIngressModules(t, fx)
	disableBody, _ := json.Marshal(map[string]any{"enabled": false, "revision": modules.Revision})
	updatedRec := doAPI(fx.cs, http.MethodPut, "/api/mihomo/ingress-modules/"+speedtestModuleID, disableBody, fx.token, true)
	if updatedRec.Code != http.StatusOK {
		t.Fatalf("disable status=%d body=%s", updatedRec.Code, updatedRec.Body.String())
	}
	updatedText, err := fx.store.Read()
	if err != nil {
		t.Fatal(err)
	}
	rec := doAPI(fx.cs, http.MethodPost, "/api/mihomo/config/reset", mihomoConfigResetBody(t, rawRevision), fx.token, true)
	if rec.Code != http.StatusConflict {
		t.Fatalf("stale reset status=%d want 409 body=%s", rec.Code, rec.Body.String())
	}
	var conflict struct {
		Revision string `json:"revision"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &conflict); err != nil {
		t.Fatal(err)
	}
	if conflict.Revision != mihomoConfigRevision(updatedText) {
		t.Fatalf("conflict revision=%q want updated config revision", conflict.Revision)
	}
	if got, _ := fx.store.Read(); got != updatedText {
		t.Fatal("stale reset overwrote ingress module update")
	}
	if view := analyzeSpeedtestModule(updatedText, fx.infra).View; view.Enabled || !view.Manageable {
		t.Fatalf("disabled module state not retained: %+v", view)
	}
	if fx.tester.calls != 1 || fx.ctl.putCalls != 1 {
		t.Fatalf("stale reset reached validator/controller: %d/%d", fx.tester.calls, fx.ctl.putCalls)
	}
}

func TestMihomoConfigAPI_Reset_RequiresStrictRevisionBody(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	tests := []string{
		``,
		`{}`,
		`{"revision":"nope"}`,
		`{"revision":"` + mihomoConfigRevision(fx.golden) + `","extra":true}`,
	}
	for _, body := range tests {
		rec := doAPI(fx.cs, http.MethodPost, "/api/mihomo/config/reset", []byte(body), fx.token, true)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("body=%q status=%d want 400 response=%s", body, rec.Code, rec.Body.String())
		}
	}
	if fx.tester.calls != 0 || fx.ctl.putCalls != 0 {
		t.Fatalf("invalid reset reached validator/controller: %d/%d", fx.tester.calls, fx.ctl.putCalls)
	}
}

// TestMihomoConfigAPI_Reset restores the seed default: it should overwrite a
// broken on-disk config and successfully re-apply it.
func TestMihomoConfigAPI_Reset(t *testing.T) {
	fx := newMihomoConfigTestFixture(t)
	t.Setenv("DNS_BASE_DOMAIN", "5gpn.test")
	t.Setenv("DNS_MIHOMO_LISTEN_IPS", "203.0.113.10")
	t.Setenv("DNS_GATEWAY_IP", fx.infra.GatewayIP)
	t.Setenv("DNS_MIHOMO_SECRET", "s3cr3t")
	t.Setenv("DNS_PUBLIC_IP", "203.0.113.10")
	legacyBackupPath, legacyBackupBody := seedLegacyMihomoBackup(t, fx.store)

	// Break the on-disk config first (simulating a prior bad edit).
	if err := os.WriteFile(fx.store.Path(), []byte("garbage: not a real config"), 0o644); err != nil {
		t.Fatalf("seed broken config: %v", err)
	}

	rec := doAPI(fx.cs, http.MethodPost, "/api/mihomo/config/reset", mihomoConfigResetBody(t, mihomoConfigRevision("garbage: not a real config")), fx.token, true)
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
	backup, err := os.ReadFile(fx.store.BackupPath())
	if err != nil || string(backup) != "garbage: not a real config" {
		t.Fatalf("reset backup = %q, %v", backup, err)
	}
	if info, err := os.Stat(fx.store.BackupPath()); err != nil || filesystemSupportsPOSIXModes(t, filepath.Dir(fx.store.BackupPath())) && info.Mode().Perm() != 0o640 {
		t.Fatalf("reset backup mode: info=%v err=%v", info, err)
	}
	if legacyBackup, err := os.ReadFile(legacyBackupPath); err != nil || string(legacyBackup) != legacyBackupBody {
		t.Fatalf("reset changed legacy backup: body=%q err=%v", legacyBackup, err)
	}
	if fx.ctl.putCalls != 1 {
		t.Fatalf("reset should hot-apply the restored default, got %d PutConfigs calls", fx.ctl.putCalls)
	}
}
