package main

import (
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

// TestOpRestartMihomoUsesSystemctl asserts restarting mihomo shells out to
// `systemctl restart mihomo` (real restart) and then reports is-active.
func TestOpRestartMihomo(t *testing.T) {
	dir := t.TempDir()
	reloadCalls := 0
	ctrl := NewController(nil, func() error { reloadCalls++; return nil }, dir, nil, nil, nil)
	fn, calls := recordRun(true, "active")
	bt := &Bot{ctrl: ctrl, runFn: fn}

	msg := bt.opRestart("mihomo")

	// It must have shelled out to restart mihomo (and separately is-active).
	foundRestart := false
	for _, c := range *calls {
		if len(c) == 3 && c[0] == "systemctl" && c[1] == "restart" && c[2] == "mihomo" {
			foundRestart = true
		}
	}
	if !foundRestart {
		t.Errorf("opRestart(mihomo) did not run [systemctl restart mihomo]; calls=%v", *calls)
	}
	if reloadCalls != 0 {
		t.Errorf("opRestart(mihomo) called ctrl.Reload() %d times, want 0 (mihomo is a real restart)", reloadCalls)
	}
	if !strings.Contains(msg, "mihomo") {
		t.Errorf("opRestart(mihomo) msg = %q, want it to name mihomo", msg)
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

// TestOpRestartAll restarts mihomo (real) AND hot-reloads 5gpn-dns.
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
	foundMihomoRestart := false
	for _, c := range *calls {
		if len(c) == 3 && c[0] == "systemctl" && c[1] == "restart" && c[2] == "mihomo" {
			foundMihomoRestart = true
		}
		if len(c) == 3 && c[0] == "systemctl" && c[1] == "restart" && c[2] == "5gpn-dns" {
			t.Errorf("opRestart(all) systemctl-restarted 5gpn-dns; want hot reload, not restart")
		}
	}
	if !foundMihomoRestart {
		t.Errorf("opRestart(all) did not restart mihomo; calls=%v", *calls)
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
			if len(*calls) != 1 {
				t.Fatalf("opRenewCert made %d run calls, want 1: %v", len(*calls), *calls)
			}
			argv := (*calls)[0]
			// certbot is wrapped in systemd-run so it escapes the daemon's
			// hardened sandbox; the argv must be a systemd-run … certbot renew.
			if len(argv) == 0 || argv[0] != "systemd-run" {
				t.Fatalf("opRenewCert argv = %v, want a systemd-run wrapper", argv)
			}
			if joined := strings.Join(argv, " "); !strings.Contains(joined, "certbot renew") {
				t.Fatalf("opRenewCert argv = %v, want certbot renew inside", argv)
			}
			if !strings.Contains(msg, c.wantSubstr) {
				t.Errorf("opRenewCert(%s) = %q, want substring %q", c.name, msg, c.wantSubstr)
			}
		})
	}
}

// setIOSHostEnv points the iosHost source env keys at fresh test-scoped vars
// (cleared by default) for the duration of a test. The bot reads the identity
// from the environment (systemd loads dns.env), not from state files.
func setIOSHostEnv(t *testing.T, webDomain, dotDomain string) {
	t.Helper()
	t.Setenv(profileDomainEnv, "")
	t.Setenv(webDomainEnv, webDomain)
	t.Setenv(domainEnv, dotDomain)
}

// TestIosHost: the dedicated public profile-only SNI wins. WEB and DoT remain
// migration fallbacks; an IP is never used because it cannot satisfy TLS SNI.
func TestIosHost(t *testing.T) {
	cases := []struct {
		profileDomain, webDomain, dotDomain, want string
	}{
		{"profile.example.com", "console.example.com", "dot.example.com", "profile.example.com"},
		{"", "console.example.com", "dot.example.com", "console.example.com"},
		{"", "", "dot.example.com", "dot.example.com"},
		{"", "", "", ""},
	}
	for _, c := range cases {
		setIOSHostEnv(t, c.webDomain, c.dotDomain)
		t.Setenv(profileDomainEnv, c.profileDomain)
		if got := iosHost(); got != c.want {
			t.Errorf("iosHost() with profile=%q web=%q dot=%q = %q, want %q", c.profileDomain, c.webDomain, c.dotDomain, got, c.want)
		}
	}
}

// TestOpIosURLUsesProfileDomain: the QR must point at the public profile-only
// host, not the source-allowlisted admin console.
func TestOpIosURLUsesProfileDomain(t *testing.T) {
	setIOSHostEnv(t, "console.example.com", "dot.example.com")
	t.Setenv(profileDomainEnv, "profile.example.com")

	fn, _ := recordRun(true, "QRCODE-ANSI-BLOCK")
	bt := &Bot{runFn: fn}
	msg := bt.opIOS()

	wantURL := "https://profile.example.com/ios/ios-dot.mobileconfig"
	if !strings.Contains(msg, wantURL) {
		t.Errorf("opIOS() = %q, want it to contain the profile-domain URL %q", msg, wantURL)
	}
	if strings.Contains(msg, "8111") {
		t.Errorf("opIOS() = %q, must NOT reference the removed :8111 responder", msg)
	}
	if !strings.Contains(msg, "QRCODE-ANSI-BLOCK") {
		t.Errorf("opIOS() = %q, want the QR block embedded when qrencode succeeds", msg)
	}
}

// TestOpIosNoHost: with no domain configured, opIOS reports that no host was
// found and does NOT build a URL.
func TestOpIosNoHost(t *testing.T) {
	setIOSHostEnv(t, "", "") // no web/dot domain in the environment

	fn, calls := recordRun(true, "")
	bt := &Bot{runFn: fn}
	msg := bt.opIOS()

	if strings.Contains(msg, "https://") {
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
	setIOSHostEnv(t, "example.com", "")

	fn, _ := recordRun(false, "命令不存在：qrencode")
	bt := &Bot{runFn: fn}
	msg := bt.opIOS()

	if !strings.Contains(msg, "https://example.com/ios/ios-dot.mobileconfig") {
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
		{"restart:mihomo", cbRestart, "mihomo"},
		{"restart:5gpn-dns", cbRestart, "5gpn-dns"},
		{"restart:all", cbRestart, "all"},
		{"logs:5gpn-dns", cbLogs, "5gpn-dns"},
		{"logs:mihomo", cbLogs, "mihomo"},
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
