package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// recordRun builds a run-stub that records every argv it is called with and
// returns the canned (ok, out). It mirrors how tgbot's tests monkeypatched
// tgbot.run: no real systemctl/journalctl/certbot/qrencode is ever invoked.
func recordRun(ok bool, out string) (func(argv []string, timeout time.Duration) (bool, string), *[][]string) {
	var calls [][]string
	fn := func(argv []string, timeout time.Duration) (bool, string) {
		calls = append(calls, append([]string(nil), argv...))
		return ok, out
	}
	return fn, &calls
}

// TestOpRestartSingBoxUsesSystemctl asserts restarting sing-box shells out to
// `systemctl restart sing-box` (real restart) and then reports is-active.
func TestOpRestartSingBox(t *testing.T) {
	dir := t.TempDir()
	reloadCalls := 0
	ctrl := NewController(nil, func() error { reloadCalls++; return nil }, dir, nil, nil, nil)
	fn, calls := recordRun(true, "active")
	bt := &Bot{ctrl: ctrl, runFn: fn}

	msg := bt.opRestart("sing-box")

	// It must have shelled out to restart sing-box (and separately is-active).
	foundRestart := false
	for _, c := range *calls {
		if len(c) == 3 && c[0] == "systemctl" && c[1] == "restart" && c[2] == "sing-box" {
			foundRestart = true
		}
	}
	if !foundRestart {
		t.Errorf("opRestart(sing-box) did not run [systemctl restart sing-box]; calls=%v", *calls)
	}
	if reloadCalls != 0 {
		t.Errorf("opRestart(sing-box) called ctrl.Reload() %d times, want 0 (sing-box is a real restart)", reloadCalls)
	}
	if !strings.Contains(msg, "sing-box") {
		t.Errorf("opRestart(sing-box) msg = %q, want it to name sing-box", msg)
	}
}

// TestOpRestart5gpnDnsReloadsNoSystemctl is the self-restart-paradox guard:
// restarting the bot's own host process (5gpn-dns) must NOT systemctl-restart
// (that would kill the bot mid-command). It must instead call ctrl.Reload()
// (in-process hot reload) and label it as 热重载 (not 重启).
func TestOpRestart5gpnDnsReloadsNoSystemctl(t *testing.T) {
	dir := t.TempDir()
	reloadCalls := 0
	ctrl := NewController(nil, func() error { reloadCalls++; return nil }, dir, nil, nil, nil)
	fn, calls := recordRun(true, "active")
	bt := &Bot{ctrl: ctrl, runFn: fn}

	msg := bt.opRestart("5gpn-dns")

	if reloadCalls != 1 {
		t.Errorf("opRestart(5gpn-dns) called ctrl.Reload() %d times, want 1 (hot reload, not restart)", reloadCalls)
	}
	for _, c := range *calls {
		if len(c) >= 2 && c[0] == "systemctl" && c[1] == "restart" {
			t.Errorf("opRestart(5gpn-dns) ran a systemctl restart (%v); self-restart would kill the bot", c)
		}
	}
	if !strings.Contains(msg, "热重载") {
		t.Errorf("opRestart(5gpn-dns) msg = %q, want it to say 热重载 (hot reload, not restart)", msg)
	}
}

// TestOpRestartAll restarts sing-box (real) AND hot-reloads 5gpn-dns.
func TestOpRestartAll(t *testing.T) {
	dir := t.TempDir()
	reloadCalls := 0
	ctrl := NewController(nil, func() error { reloadCalls++; return nil }, dir, nil, nil, nil)
	fn, calls := recordRun(true, "active")
	bt := &Bot{ctrl: ctrl, runFn: fn}

	bt.opRestart("all")

	if reloadCalls != 1 {
		t.Errorf("opRestart(all) called ctrl.Reload() %d times, want 1 (5gpn-dns hot reload)", reloadCalls)
	}
	foundSingBoxRestart := false
	for _, c := range *calls {
		if len(c) == 3 && c[0] == "systemctl" && c[1] == "restart" && c[2] == "sing-box" {
			foundSingBoxRestart = true
		}
		if len(c) == 3 && c[0] == "systemctl" && c[1] == "restart" && c[2] == "5gpn-dns" {
			t.Errorf("opRestart(all) systemctl-restarted 5gpn-dns; want hot reload, not restart")
		}
	}
	if !foundSingBoxRestart {
		t.Errorf("opRestart(all) did not restart sing-box; calls=%v", *calls)
	}
}

// TestOpRestartUnknown rejects an unknown service without shelling out or
// reloading.
func TestOpRestartUnknown(t *testing.T) {
	dir := t.TempDir()
	reloadCalls := 0
	ctrl := NewController(nil, func() error { reloadCalls++; return nil }, dir, nil, nil, nil)
	fn, calls := recordRun(true, "active")
	bt := &Bot{ctrl: ctrl, runFn: fn}

	msg := bt.opRestart("nginx")
	if len(*calls) != 0 {
		t.Errorf("opRestart(nginx) shelled out %v, want none for unknown service", *calls)
	}
	if reloadCalls != 0 {
		t.Errorf("opRestart(nginx) reloaded %d times, want 0", reloadCalls)
	}
	if !strings.Contains(msg, "未知服务") {
		t.Errorf("opRestart(nginx) msg = %q, want an unknown-service notice", msg)
	}
}

// TestOpLogsKnownService builds the journalctl argv for a known service.
func TestOpLogsKnownService(t *testing.T) {
	fn, calls := recordRun(true, "some log output")
	bt := &Bot{runFn: fn}

	msg := bt.opLogs("5gpn-dns")

	if len(*calls) != 1 {
		t.Fatalf("opLogs(5gpn-dns) made %d run calls, want 1", len(*calls))
	}
	want := []string{"journalctl", "-u", "5gpn-dns", "-n", "50", "--no-pager", "-o", "short-iso"}
	got := (*calls)[0]
	if len(got) != len(want) {
		t.Fatalf("opLogs argv = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("opLogs argv = %v, want %v", got, want)
		}
	}
	if !strings.Contains(msg, "5gpn-dns") || !strings.Contains(msg, "<pre>") {
		t.Errorf("opLogs render = %q, want a <pre>-wrapped block naming the service", msg)
	}
}

// TestOpLogsUnknownService rejects an unknown service without shelling out.
func TestOpLogsUnknownService(t *testing.T) {
	fn, calls := recordRun(true, "")
	bt := &Bot{runFn: fn}

	msg := bt.opLogs("nginx")
	if len(*calls) != 0 {
		t.Errorf("opLogs(nginx) shelled out %v, want none for unknown service", *calls)
	}
	if !strings.Contains(msg, "未知服务") {
		t.Errorf("opLogs(nginx) msg = %q, want an unknown-service notice", msg)
	}
}

// TestOpRenewCert covers the three certbot-renew branches (not-yet-due,
// renewed, failed) via the stubbed run.
func TestOpRenewCert(t *testing.T) {
	cases := []struct {
		name       string
		ok         bool
		out        string
		wantSubstr string
	}{
		{"not yet due", true, "Cert not yet due for renewal", "尚未到期"},
		{"no renewals attempted", true, "No renewals were attempted.", "尚未到期"},
		{"renewed", true, "Congratulations, all renewals succeeded", "已续期"},
		{"failed", false, "some error", "失败"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fn, calls := recordRun(c.ok, c.out)
			bt := &Bot{runFn: fn}
			msg := bt.opRenewCert()
			if len(*calls) != 1 || (*calls)[0][0] != "certbot" {
				t.Fatalf("opRenewCert argv = %v, want a certbot renew", *calls)
			}
			if !strings.Contains(msg, c.wantSubstr) {
				t.Errorf("opRenewCert(%s) = %q, want substring %q", c.name, msg, c.wantSubstr)
			}
		})
	}
}

// withIOSHostFiles points the three iosHost source files at a temp dir for the
// duration of a test, restoring the originals afterward.
func withIOSHostFiles(t *testing.T) (gatewayFile, publicFile, domainFile string) {
	t.Helper()
	dir := t.TempDir()
	gatewayFile = filepath.Join(dir, ".gateway_ip")
	publicFile = filepath.Join(dir, ".public_ip")
	domainFile = filepath.Join(dir, ".domain")

	origG, origP, origD := gatewayIPFile, publicIPFile, iosDomainFile
	gatewayIPFile, publicIPFile, iosDomainFile = gatewayFile, publicFile, domainFile
	t.Cleanup(func() {
		gatewayIPFile, publicIPFile, iosDomainFile = origG, origP, origD
	})
	return gatewayFile, publicFile, domainFile
}

// TestIosHost mirrors tgbot.py's TestIosHost: preference is gateway_ip >
// public_ip > domain > "".
func TestIosHost(t *testing.T) {
	gatewayFile, publicFile, domainFile := withIOSHostFiles(t)

	writeF := func(path, val string) {
		if val == "" {
			_ = os.Remove(path)
			return
		}
		if err := os.WriteFile(path, []byte(val+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	cases := []struct {
		gateway, public, domain, want string
	}{
		{"1.2.3.4", "5.6.7.8", "example.com", "1.2.3.4"}, // gateway wins
		{"", "5.6.7.8", "example.com", "5.6.7.8"},        // public next
		{"", "", "example.com", "example.com"},           // domain last
		{"", "", "", ""},                                 // nothing
	}
	for _, c := range cases {
		writeF(gatewayFile, c.gateway)
		writeF(publicFile, c.public)
		writeF(domainFile, c.domain)
		if got := iosHost(); got != c.want {
			t.Errorf("iosHost() with gw=%q pub=%q dom=%q = %q, want %q", c.gateway, c.public, c.domain, got, c.want)
		}
	}
}

// TestOpIosURLUsesGatewayNotDomain ports tgbot.py's
// test_op_ios_url_uses_gateway_not_domain: when a gateway IP exists, the iOS
// profile URL must use it, NOT the domain.
func TestOpIosURLUsesGatewayNotDomain(t *testing.T) {
	gatewayFile, _, domainFile := withIOSHostFiles(t)
	if err := os.WriteFile(gatewayFile, []byte("172.22.0.1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(domainFile, []byte("example.com\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	fn, _ := recordRun(true, "QRCODE-ANSI-BLOCK")
	bt := &Bot{runFn: fn}
	msg := bt.opIOS()

	wantURL := "http://172.22.0.1:8111/ios-dot.mobileconfig"
	if !strings.Contains(msg, wantURL) {
		t.Errorf("opIOS() = %q, want it to contain the gateway URL %q", msg, wantURL)
	}
	if strings.Contains(msg, "example.com") {
		t.Errorf("opIOS() = %q, must NOT use the domain when a gateway IP exists", msg)
	}
	if !strings.Contains(msg, "QRCODE-ANSI-BLOCK") {
		t.Errorf("opIOS() = %q, want the QR block embedded when qrencode succeeds", msg)
	}
}

// TestOpIosNoHost ports the no-host case: with all three source files empty,
// opIOS reports that no gateway address was found and does NOT build a URL.
func TestOpIosNoHost(t *testing.T) {
	withIOSHostFiles(t) // all three files absent in the fresh temp dir

	fn, calls := recordRun(true, "")
	bt := &Bot{runFn: fn}
	msg := bt.opIOS()

	if strings.Contains(msg, "http://") {
		t.Errorf("opIOS() with no host = %q, want no URL", msg)
	}
	if len(*calls) != 0 {
		t.Errorf("opIOS() with no host shelled out %v, want no qrencode call", *calls)
	}
	if !strings.Contains(msg, "未找到") {
		t.Errorf("opIOS() with no host = %q, want a not-found notice", msg)
	}
}

// TestOpIosQrencodeMissing: when qrencode fails/missing, the URL alone is still
// returned (actionable) with no QR block.
func TestOpIosQrencodeMissing(t *testing.T) {
	gatewayFile, _, _ := withIOSHostFiles(t)
	if err := os.WriteFile(gatewayFile, []byte("10.0.0.1\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	fn, _ := recordRun(false, "命令不存在：qrencode")
	bt := &Bot{runFn: fn}
	msg := bt.opIOS()

	if !strings.Contains(msg, "http://10.0.0.1:8111/ios-dot.mobileconfig") {
		t.Errorf("opIOS() = %q, want the URL even when qrencode is missing", msg)
	}
}

// TestParseCallbackT3 confirms the T3 callback additions classify correctly,
// including the restart:/logs: arg tail.
func TestParseCallbackT3(t *testing.T) {
	cases := []struct {
		data     string
		wantKind callbackKind
		wantArg  string
	}{
		{"menu:restart", cbMenuRestart, ""},
		{"menu:logs", cbMenuLogs, ""},
		{"act:renew", cbRenew, ""},
		{"act:ios", cbIOS, ""},
		{"restart:sing-box", cbRestart, "sing-box"},
		{"restart:5gpn-dns", cbRestart, "5gpn-dns"},
		{"restart:all", cbRestart, "all"},
		{"logs:5gpn-dns", cbLogs, "5gpn-dns"},
		{"logs:sing-box", cbLogs, "sing-box"},
	}
	for _, c := range cases {
		got := parseCallback(c.data)
		if got.kind != c.wantKind {
			t.Errorf("parseCallback(%q).kind = %v, want %v", c.data, got.kind, c.wantKind)
		}
		if got.arg != c.wantArg {
			t.Errorf("parseCallback(%q).arg = %q, want %q", c.data, got.arg, c.wantArg)
		}
	}
}

// TestBotRunFallsBackToReal confirms a Bot with a nil runFn uses the real run
// (which, on a box without the binary, returns ok=false + a friendly message
// rather than panicking). We invoke a definitely-absent command.
func TestBotRunFallsBackToReal(t *testing.T) {
	bt := &Bot{} // no runFn injected
	ok, out := bt.run([]string{"definitely-not-a-real-binary-xyz"}, 5*time.Second)
	if ok {
		t.Errorf("run of a non-existent binary reported ok=true")
	}
	if out == "" {
		t.Errorf("run of a non-existent binary returned empty message, want a friendly error")
	}
}
