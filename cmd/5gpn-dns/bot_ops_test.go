package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// recordRun builds a run-stub that records every argv it is called with and
// returns the canned (ok, out). It mirrors how tgbot's tests monkeypatched
// tgbot.run: no real systemctl/renewal-helper/qrencode is invoked.
func recordRun(ok bool, out string) (func(argv []string, timeout time.Duration) (bool, string), *[][]string) {
	var calls [][]string
	fn := func(argv []string, timeout time.Duration) (bool, string) {
		calls = append(calls, append([]string(nil), argv...))
		return ok, out
	}
	return fn, &calls
}

func TestRestartMihomoRequiresCommandAndActiveSuccess(t *testing.T) {
	tests := []struct {
		name       string
		restartOK  bool
		activeOK   bool
		state      string
		wantOK     bool
		wantDetail string
	}{
		{name: "both succeed", restartOK: true, activeOK: true, state: "active", wantOK: true},
		{name: "restart fails despite stale active state", restartOK: false, activeOK: true, state: "active", wantDetail: "restart 失败"},
		{name: "restart exits zero but service is failed", restartOK: true, activeOK: false, state: "failed", wantDetail: "is-active"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			bt := &Bot{runFn: func(argv []string, _ time.Duration) (bool, string) {
				if len(argv) >= 2 && argv[1] == "restart" {
					return tc.restartOK, "restart diagnostic"
				}
				return tc.activeOK, tc.state
			}}
			result := bt.restartMihomoResult()
			if result.OK != tc.wantOK {
				t.Fatalf("result.OK = %v, want %v; result=%+v", result.OK, tc.wantOK, result)
			}
			if tc.wantDetail != "" && !strings.Contains(result.HTML(), tc.wantDetail) {
				t.Fatalf("result HTML = %q, want %q", result.HTML(), tc.wantDetail)
			}
		})
	}
}

// TestOpLogsKnownService starts only the fixed exporter unit and reads its
// bounded result file for a known service.
func TestOpLogsKnownService(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "5gpn-dns.log"), []byte("some log output"), 0o600); err != nil {
		t.Fatal(err)
	}
	fn, calls := recordRun(true, "")
	bt := &Bot{runFn: fn, journalDir: dir}

	msg := bt.opLogsResult("5gpn-dns").HTML()

	if len(*calls) != 1 {
		t.Fatalf("opLogs(5gpn-dns) made %d run calls, want 1", len(*calls))
	}
	want := []string{"systemctl", "start", "5gpn-journal@5gpn-dns.service"}
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
	if !strings.Contains(msg, "some log output") {
		t.Errorf("opLogs render = %q, want exported journal content", msg)
	}
}

func TestOpLogsFailureIsExplicitAndKeepsNewestOutput(t *testing.T) {
	out := "old-marker\n" + strings.Repeat("旧", 4000) + "\nLATEST-FAILURE"
	fn, _ := recordRun(false, out)
	result := (&Bot{runFn: fn}).opLogsResult("mihomo")

	if result.OK {
		t.Fatal("failed journal exporter reported OK")
	}
	rendered := result.HTML()
	if !strings.Contains(rendered, "日志读取失败") {
		t.Fatalf("failure not explicit: %q", rendered[:min(len(rendered), 200)])
	}
	if !strings.Contains(rendered, "LATEST-FAILURE") {
		t.Fatal("truncated log lost the newest failure line")
	}
	if strings.Contains(rendered, "old-marker") {
		t.Fatal("tail-oriented truncation retained the oldest marker")
	}
}

func TestOpLogsRejectsUnsafeOrOversizedExport(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, path string)
	}{
		{
			name: "symlink",
			setup: func(t *testing.T, path string) {
				t.Helper()
				target := filepath.Join(t.TempDir(), "target")
				if err := os.WriteFile(target, []byte("secret"), 0o600); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, path); err != nil {
					t.Skipf("symlink unavailable: %v", err)
				}
			},
		},
		{
			name: "oversized",
			setup: func(t *testing.T, path string) {
				t.Helper()
				if err := os.WriteFile(path, bytes.Repeat([]byte("x"), journalExportMaxBytes+1), 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			tc.setup(t, filepath.Join(dir, "mihomo.log"))
			fn, _ := recordRun(true, "")
			result := (&Bot{runFn: fn, journalDir: dir}).opLogsResult("mihomo")
			if result.OK || !strings.Contains(result.HTMLSummary, "日志读取失败") {
				t.Fatalf("unsafe export result = %+v", result)
			}
		})
	}
}

// TestOpLogsUnknownService rejects an unknown service without shelling out.
func TestOpLogsUnknownService(t *testing.T) {
	fn, calls := recordRun(true, "")
	bt := &Bot{runFn: fn}

	msg := bt.opLogsResult("nginx").HTML()
	if len(*calls) != 0 {
		t.Errorf("opLogs(nginx) shelled out %v, want none for unknown service", *calls)
	}
	if !strings.Contains(msg, "未知服务") {
		t.Errorf("opLogs(nginx) msg = %q, want an unknown-service notice", msg)
	}
}

// TestOpRenewCert covers the fixed renewal-service success and failure paths.
func TestOpRenewCert(t *testing.T) {
	cases := []struct {
		name       string
		ok         bool
		out        string
		wantSubstr string
	}{
		{"not yet due", true, "", "检查已完成"},
		{"renewed", true, "", "检查已完成"},
		{"failed", false, "some error", "失败"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv(baseDomainEnv, "example.com")
			fn, calls := recordRun(c.ok, c.out)
			var gotTimeout time.Duration
			bt := &Bot{runFn: func(argv []string, timeout time.Duration) (bool, string) {
				gotTimeout = timeout
				return fn(argv, timeout)
			}}
			msg := bt.opRenewCertResult().HTML()
			if len(*calls) != 1 {
				t.Fatalf("opRenewCert made %d run calls, want 1: %v", len(*calls), *calls)
			}
			argv := (*calls)[0]
			want := []string{"systemctl", "start", "5gpn-certbot-renew.service"}
			if len(argv) != len(want) {
				t.Fatalf("opRenewCert argv = %v, want %v", argv, want)
			}
			for i := range want {
				if argv[i] != want[i] {
					t.Fatalf("opRenewCert argv = %v, want %v", argv, want)
				}
			}
			if gotTimeout != 30*time.Minute {
				t.Fatalf("opRenewCert timeout = %s, want 30m", gotTimeout)
			}
			if !strings.Contains(msg, c.wantSubstr) {
				t.Errorf("opRenewCert(%s) = %q, want substring %q", c.name, msg, c.wantSubstr)
			}
		})
	}
}

func TestOpRenewCertFailsClosedWithoutValidBaseDomain(t *testing.T) {
	for _, value := range []string{"", "not-a-domain", "example.com;certbot renew"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv(baseDomainEnv, value)
			fn, calls := recordRun(true, "must not run")
			bt := &Bot{runFn: fn}

			msg := bt.opRenewCertResult().HTML()

			if len(*calls) != 0 {
				t.Fatalf("opRenewCert with DNS_BASE_DOMAIN=%q ran %v, want no subprocess", value, *calls)
			}
			if !strings.Contains(msg, "已拒绝") || !strings.Contains(msg, baseDomainEnv) {
				t.Errorf("opRenewCert with DNS_BASE_DOMAIN=%q = %q, want fail-closed notice", value, msg)
			}
		})
	}
}

func TestOpRenewCertCanonicalizesCertName(t *testing.T) {
	for _, value := range []string{"EXAMPLE.COM", "example.com."} {
		t.Run(value, func(t *testing.T) {
			t.Setenv(baseDomainEnv, value)
			fn, calls := recordRun(true, "[INFO] Cert not yet due for renewal")
			bt := &Bot{runFn: fn}

			msg := bt.opRenewCertResult().HTML()

			if len(*calls) != 1 {
				t.Fatalf("opRenewCert made %d calls, want 1", len(*calls))
			}
			want := []string{"systemctl", "start", "5gpn-certbot-renew.service"}
			argv := (*calls)[0]
			if strings.Join(argv, "\x00") != strings.Join(want, "\x00") {
				t.Fatalf("opRenewCert argv = %v, want %v", argv, want)
			}
			if !strings.Contains(msg, "检查已完成") {
				t.Fatalf("opRenewCert helper result = %q, want completion notice", msg)
			}
		})
	}
}

func setIOSHostEnv(t *testing.T, baseDomain string) {
	t.Helper()
	t.Setenv(baseDomainEnv, baseDomain)
}

func TestIosHost(t *testing.T) {
	setIOSHostEnv(t, "example.com")
	if got := iosHost(); got != "console.example.com" {
		t.Fatalf("iosHost() = %q, want configured console domain", got)
	}

	setIOSHostEnv(t, "")
	if got := iosHost(); got != "" {
		t.Fatalf("iosHost() = %q, want empty without DNS_BASE_DOMAIN", got)
	}
}

// TestOpIosURLUsesConsoleDomain: the QR must point at the public console.
func TestOpIosURLUsesConsoleDomain(t *testing.T) {
	setIOSHostEnv(t, "example.com")

	fn, calls := recordRun(true, "QRCODE-ANSI-BLOCK")
	bt := &Bot{runFn: fn}
	msg := bt.opIOSResult().HTML()

	wantURL := "https://console.example.com/ios/ios-dot.mobileconfig"
	if !strings.Contains(msg, wantURL) {
		t.Errorf("opIOS() = %q, want it to contain the console URL %q", msg, wantURL)
	}
	if strings.Contains(msg, "QRCODE-ANSI-BLOCK") {
		t.Errorf("opIOS() = %q, ANSI QR art must not be embedded", msg)
	}
	if len(*calls) != 0 {
		t.Errorf("opIOS() ran %v; QR generation belongs to the native photo action", *calls)
	}
}

// TestOpIosNoHost: with no domain configured, opIOS reports that no host was
// found and does NOT build a URL.
func TestOpIosNoHost(t *testing.T) {
	setIOSHostEnv(t, "")

	fn, calls := recordRun(true, "")
	bt := &Bot{runFn: fn}
	msg := bt.opIOSResult().HTML()

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

func TestOpIosDoesNotNeedQrencodeForActionableURL(t *testing.T) {
	setIOSHostEnv(t, "example.com")

	fn, calls := recordRun(false, "命令不存在：qrencode")
	bt := &Bot{runFn: fn}
	msg := bt.opIOSResult().HTML()

	if !strings.Contains(msg, "https://console.example.com/ios/ios-dot.mobileconfig") {
		t.Errorf("opIOS() = %q, want the actionable URL", msg)
	}
	if len(*calls) != 0 {
		t.Errorf("opIOS() unexpectedly invoked qrencode through text runner: %v", *calls)
	}
}

func TestBotActionGuardConfirmationAndSingleFlight(t *testing.T) {
	now := time.Unix(1000, 0)
	guard := newBotActionGuard()
	guard.now = func() time.Time { return now }
	guard.entropy = bytes.NewReader(bytes.Join([][]byte{
		bytes.Repeat([]byte{0x5a}, botConfirmationBytes),
		bytes.Repeat([]byte{0x5b}, botConfirmationBytes),
		bytes.Repeat([]byte{0x5c}, botConfirmationBytes),
		bytes.Repeat([]byte{0x5d}, botConfirmationBytes),
	}, nil))

	nonce, expires, err := guard.Issue(botActionRestartMihomo, 7, 11)
	if err != nil {
		t.Fatal(err)
	}
	if !validConfirmationNonce(nonce) || !expires.Equal(now.Add(botConfirmationTTL)) {
		t.Fatalf("nonce/expires = %q/%v", nonce, expires)
	}
	if guard.Consume(nonce, botActionRestartMihomo, 8, 11) {
		t.Fatal("another admin consumed the confirmation")
	}
	if !guard.Consume(nonce, botActionRestartMihomo, 7, 11) {
		t.Fatal("owner could not consume confirmation")
	}
	if guard.Consume(nonce, botActionRestartMihomo, 7, 11) {
		t.Fatal("confirmation replay succeeded")
	}

	expired, _, err := guard.Issue(botActionRenewCert, 7, 11)
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(botConfirmationTTL)
	if guard.Consume(expired, botActionRenewCert, 7, 11) {
		t.Fatal("expired confirmation succeeded")
	}
	revoked, _, err := guard.Issue(botActionRenewCert, 7, 11)
	if err != nil {
		t.Fatal(err)
	}
	otherAdmin, _, err := guard.Issue(botActionRenewCert, 8, 8)
	if err != nil {
		t.Fatal(err)
	}
	guard.RevokeAdmin(7)
	if guard.Consume(revoked, botActionRenewCert, 7, 11) {
		t.Fatal("revoked administrator retained a confirmation")
	}
	if !guard.Consume(otherAdmin, botActionRenewCert, 8, 8) {
		t.Fatal("revoking one administrator removed another administrator's confirmation")
	}

	if !guard.TryStart(botActionRestartMihomo) {
		t.Fatal("first operation did not acquire single-flight guard")
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		if guard.TryStart(botActionRestartMihomo) {
			t.Error("concurrent operation acquired single-flight guard")
		}
	}()
	wg.Wait()
	guard.Finish(botActionRestartMihomo)
	if !guard.TryStart(botActionRestartMihomo) {
		t.Fatal("operation remained locked after Finish")
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
