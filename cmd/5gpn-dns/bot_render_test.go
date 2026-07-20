package main

import (
	"html"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// TestFormattingHelpers ports tgbot.py's formatting helpers (pre / _tail /
// _chunks / _fmt_bytes) and asserts the same observable behavior: pre strips
// ANSI, HTML-escapes, wraps in <pre>, and truncates; tailLines keeps the last
// N non-blank lines; chunkText splits at the size boundary; fmtBytes renders
// human-readable sizes.
func TestFormattingHelpers(t *testing.T) {
	t.Run("pre strips ANSI and HTML-escapes inside a <pre> block", func(t *testing.T) {
		// \x1b[31m ... \x1b[0m are SGR color codes; they must be removed.
		in := "\x1b[31mred\x1b[0m <b>&</b>"
		got := pre(in)
		if !strings.HasPrefix(got, "<pre>") || !strings.HasSuffix(got, "</pre>") {
			t.Fatalf("pre(%q) = %q, want wrapped in <pre>...</pre>", in, got)
		}
		if strings.Contains(got, "\x1b[") {
			t.Errorf("pre(%q) = %q, ANSI escape not stripped", in, got)
		}
		// The literal < > & from the input must be HTML-escaped so Telegram's
		// HTML parse_mode doesn't treat them as tags.
		if !strings.Contains(got, "&lt;b&gt;&amp;&lt;/b&gt;") {
			t.Errorf("pre(%q) = %q, angle brackets/ampersand not HTML-escaped", in, got)
		}
		if !strings.Contains(got, "red") {
			t.Errorf("pre(%q) = %q, want the stripped text 'red' present", in, got)
		}
	})

	t.Run("pre on empty input yields the no-output placeholder", func(t *testing.T) {
		got := pre("")
		if !strings.Contains(got, "无输出") {
			t.Errorf("pre(\"\") = %q, want the (无输出) placeholder", got)
		}
	})

	t.Run("pre truncates very long input", func(t *testing.T) {
		got := pre(strings.Repeat("x", 5000))
		if len(got) > 3700 { // 3500 cap + tags + the truncation notice
			t.Errorf("pre(<5000 x>) len = %d, want truncated to ~3500+notice", len(got))
		}
		if !strings.Contains(got, "已截断") {
			t.Errorf("pre(<5000 x>) = %q, want a truncation notice", got[len(got)-40:])
		}
	})

	t.Run("pre and preTail preserve valid Unicode and opposite ends", func(t *testing.T) {
		input := "OLDEST-" + strings.Repeat("中🙂", 2200) + "-NEWEST"
		head := pre(input)
		tail := preTail(input)
		if !utf8.ValidString(head) || !utf8.ValidString(tail) {
			t.Fatal("pre truncation produced invalid UTF-8")
		}
		if !strings.Contains(head, "OLDEST") || strings.Contains(head, "NEWEST") {
			t.Fatalf("pre did not keep the head: %q ...", head[:80])
		}
		if strings.Contains(tail, "OLDEST") || !strings.Contains(tail, "NEWEST") {
			t.Fatalf("preTail did not keep the newest content")
		}
	})

	t.Run("tailLines keeps the last N non-blank lines", func(t *testing.T) {
		in := "a\n\nb\nc\n\nd\ne"
		got := tailLines(in, 3)
		if got != "c\nd\ne" {
			t.Errorf("tailLines(%q, 3) = %q, want %q", in, got, "c\nd\ne")
		}
	})

	t.Run("tailLines with fewer lines than N returns them all", func(t *testing.T) {
		if got := tailLines("only\ntwo", 10); got != "only\ntwo" {
			t.Errorf("tailLines = %q, want %q", got, "only\ntwo")
		}
	})

	t.Run("chunkText splits at the size boundary", func(t *testing.T) {
		got := chunkText("abcdef", 2)
		want := []string{"ab", "cd", "ef"}
		if len(got) != len(want) {
			t.Fatalf("chunkText len = %d (%v), want %d", len(got), got, len(want))
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("chunkText[%d] = %q, want %q", i, got[i], want[i])
			}
		}
	})

	t.Run("chunkText on empty input yields one empty chunk", func(t *testing.T) {
		got := chunkText("", 100)
		if len(got) != 1 || got[0] != "" {
			t.Errorf("chunkText(\"\") = %v, want one empty string", got)
		}
	})

	t.Run("chunkText shorter than size yields one chunk", func(t *testing.T) {
		got := chunkText("hi", 100)
		if len(got) != 1 || got[0] != "hi" {
			t.Errorf("chunkText(\"hi\", 100) = %v, want [\"hi\"]", got)
		}
	})

	t.Run("chunkText keeps UTF-8 entities and HTML tags valid", func(t *testing.T) {
		got := chunkText("<b>你好🙂&amp;世界</b>", 3)
		if len(got) < 2 {
			t.Fatalf("chunkText returned %v, want pagination", got)
		}
		for i, chunk := range got {
			if !utf8.ValidString(chunk) {
				t.Fatalf("chunk %d is invalid UTF-8: %q", i, chunk)
			}
			if strings.Count(chunk, "<b>") != strings.Count(chunk, "</b>") {
				t.Fatalf("chunk %d has unbalanced HTML: %q", i, chunk)
			}
			plain := strings.ReplaceAll(strings.ReplaceAll(chunk, "<b>", ""), "</b>", "")
			plain = html.UnescapeString(plain)
			if utf8.RuneCountInString(plain) > 3 {
				t.Fatalf("chunk %d has %d rendered chars: %q", i, utf8.RuneCountInString(plain), chunk)
			}
		}
	})

	t.Run("chunkText repairs invalid UTF-8 instead of forwarding broken bytes", func(t *testing.T) {
		got := strings.Join(chunkText(string([]byte{'a', 0xff, 'b'}), 2), "")
		if !utf8.ValidString(got) || !strings.ContainsRune(got, utf8.RuneError) {
			t.Fatalf("chunkText invalid UTF-8 result = %q", got)
		}
	})

	t.Run("chunkText escapes unsupported markup and invalid entities", func(t *testing.T) {
		got := strings.Join(chunkText("x &bogus; <wat>", 100), "")
		if !strings.Contains(got, "&amp;bogus;") || !strings.Contains(got, "&lt;wat>") {
			t.Fatalf("chunkText did not make invalid HTML safe: %q", got)
		}
	})

	t.Run("fmtBytes renders human-readable sizes", func(t *testing.T) {
		cases := []struct {
			in   uint64
			want string
		}{
			{0, "0B"},
			{512, "512B"},
			{1024, "1.0K"},
			{1536, "1.5K"},
			{1024 * 1024, "1.0M"},
			{1024 * 1024 * 1024, "1.0G"},
		}
		for _, c := range cases {
			if got := fmtBytes(c.in); got != c.want {
				t.Errorf("fmtBytes(%d) = %q, want %q", c.in, got, c.want)
			}
		}
	})
}

// TestRenderStatus_ReasonBreakdown drives renderStatus from a fixed Stats and
// asserts the reason-level breakdown (总查询 / 直连 / 代理 / 拦截 / 缓存) and the
// upstream health (china/trust ok/err) appear, mirroring op_status's stats line.
func TestRenderStatus_ReasonBreakdown(t *testing.T) {
	st := Stats{
		Total:           100,
		Block:           7,
		ForceDirect:     5,
		ForceProxy:      3,
		ChnrouteCN:      40,
		ChnrouteForeign: 45,
		CacheEntries:    12,
		ChinaOK:         80,
		ChinaErr:        2,
		TrustOK:         60,
		TrustErr:        1,
	}
	facts := statusFacts{domain: "dns.example.com", publicIP: "203.0.113.9"}
	svc := map[string]string{"5gpn-dns": "active", "mihomo": "active"}

	out := renderStatus(st, svc, facts, "" /* no metrics card in test */, nil)

	// The reason breakdown must be derivable/visible:
	// 直连 = force_direct(5) + chnroute_cn(40) = 45
	// 代理 = force_proxy(3) + chnroute_foreign(45) = 48
	for _, want := range []string{
		"总", "100", // total
		"直连", "45", // force_direct + chnroute_cn
		"代理", "48", // force_proxy + chnroute_foreign
		"拦截", "7", // block
		"缓存", "12", // cache_entries
	} {
		if !strings.Contains(out, want) {
			t.Errorf("renderStatus output missing %q\n---\n%s", want, out)
		}
	}

	// Upstream health.
	for _, want := range []string{"80", "60"} { // china_ok, trust_ok
		if !strings.Contains(out, want) {
			t.Errorf("renderStatus output missing upstream-health value %q\n---\n%s", want, out)
		}
	}

	// Facts.
	if !strings.Contains(out, "dns.example.com") {
		t.Errorf("renderStatus output missing domain fact\n---\n%s", out)
	}
	if !strings.Contains(out, "203.0.113.9") {
		t.Errorf("renderStatus output missing public IP fact\n---\n%s", out)
	}
}

// TestRenderStatus_ServiceDown flags a down service in the card.
func TestRenderStatus_ServiceDown(t *testing.T) {
	svc := map[string]string{"5gpn-dns": "active", "mihomo": "failed"}
	out := renderStatus(Stats{}, svc, statusFacts{}, "", nil)
	if !strings.Contains(out, "❌") {
		t.Errorf("renderStatus with a down service should show ❌\n---\n%s", out)
	}
	if !strings.Contains(out, "mihomo") {
		t.Errorf("renderStatus should name the services\n---\n%s", out)
	}
}

// TestRenderStatusCert renders the TLS-cert expiry line in the status card.
func TestRenderStatusCert(t *testing.T) {
	svc := map[string]string{"5gpn-dns": "active", "mihomo": "active"}
	facts := statusFacts{domain: "dns.example.com"}

	t.Run("healthy cert shows days remaining", func(t *testing.T) {
		cert := &CertStatus{NotAfter: time.Now().Add(60 * 24 * time.Hour), DaysRemaining: 60}
		out := renderStatus(Stats{}, svc, facts, "", cert)
		if !strings.Contains(out, "60 天后过期") {
			t.Errorf("expected days-remaining in card:\n%s", out)
		}
	})

	t.Run("expired cert shows 已过期", func(t *testing.T) {
		cert := &CertStatus{NotAfter: time.Now().Add(-time.Hour), Expired: true}
		out := renderStatus(Stats{}, svc, facts, "", cert)
		if !strings.Contains(out, "已过期") {
			t.Errorf("expected 已过期 in card:\n%s", out)
		}
	})

	t.Run("no cert omits the line", func(t *testing.T) {
		out := renderStatus(Stats{}, svc, facts, "", nil)
		if strings.Contains(out, "证书") {
			t.Errorf("no cert should omit the cert line:\n%s", out)
		}
	})
}

// A broken cert renders an unmistakable "cannot load" line in bot status.
func TestRenderStatus_CertBroken(t *testing.T) {
	out := renderStatus(Stats{}, map[string]string{}, statusFacts{}, "",
		&CertStatus{Broken: true, Error: "open /etc/5gpn/cert/fullchain.pem: no such file"})
	if !strings.Contains(out, "无法加载") {
		t.Errorf("broken-cert status should say 无法加载\n---\n%s", out)
	}
}

func TestRenderResolveTest(t *testing.T) {
	result := ResolveTestResult{
		Name:      "evil<&.example",
		Verdict:   "proxy",
		Reason:    "chnroute-foreign",
		Chosen:    "trust",
		ChosenIPs: []string{"203.0.113.4"},
		ClientIPs: []string{"192.0.2.10"},
		Probes: []ResolveProbe{
			{Server: "dns.example@1.1.1.1:853", Group: "trust", IPs: []string{"203.0.113.4"}, DurationMs: 12.5, Selected: true},
			{Server: "bad.example", Group: "china", Err: "timeout <secret>", DurationMs: 2000},
		},
	}
	out := renderResolveTest(result)
	for _, want := range []string{"DNS 诊断", "组内采用", "12.5 ms", "timeout &lt;secret&gt;", "192.0.2.10"} {
		if !strings.Contains(out, want) {
			t.Errorf("renderResolveTest missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "evil<&") {
		t.Fatalf("domain was not HTML escaped: %s", out)
	}
}

func TestBotMenusAreVersionedAndUnambiguous(t *testing.T) {
	t.Setenv(baseDomainEnv, "example.com")

	main := mainMenu()
	var labels []string
	for _, row := range main.InlineKeyboard {
		for _, button := range row {
			labels = append(labels, button.Text)
			if button.CallbackData != "" && !strings.HasPrefix(button.CallbackData, botCallbackPrefix) {
				t.Errorf("callback %q is not versioned", button.CallbackData)
			}
		}
	}
	joined := strings.Join(labels, "|")
	for _, want := range []string{"状态", "DNS 诊断", "日志", "上游 DNS", "插件管理", "插件市场", "维护", "iOS 安装", "Web 控制台"} {
		if !strings.Contains(joined, want) {
			t.Errorf("main menu missing %q: %s", want, joined)
		}
	}

	maintenance := maintenanceMenu()
	var maintenanceLabels []string
	for _, row := range maintenance.InlineKeyboard {
		for _, button := range row {
			maintenanceLabels = append(maintenanceLabels, button.Text)
		}
	}
	maintenanceText := strings.Join(maintenanceLabels, "|")
	if strings.Contains(maintenanceText, "全部") || strings.Contains(maintenanceText, "5gpn-dns 热重载") {
		t.Fatalf("maintenance menu has duplicate/inaccurate actions: %s", maintenanceText)
	}
	if strings.Count(maintenanceText, "重载 DNS 规则") != 1 {
		t.Fatalf("maintenance menu should have exactly one reload action: %s", maintenanceText)
	}

	ios := iosMenu()
	var hasURL, hasPhoto bool
	for _, row := range ios.InlineKeyboard {
		for _, button := range row {
			hasURL = hasURL || strings.Contains(button.URL, "/ios/ios-dot.mobileconfig")
			hasPhoto = hasPhoto || strings.Contains(button.CallbackData, "ios-photo")
		}
	}
	if !hasURL || !hasPhoto {
		t.Fatalf("iOS menu missing URL/photo action: %+v", ios.InlineKeyboard)
	}
}

func TestExtensionCallbacksRequireCurrentTrustedFlow(t *testing.T) {
	for _, action := range []string{"modules", "market", "module:AAAAAAAAAAAAAAAA", "confirm:enable:AAAAAAAAAAAAAAAA"} {
		callback := botExtensionCallbackData(action)
		if len(callback) > 64 {
			t.Fatalf("Telegram callback exceeds 64 bytes: %q", callback)
		}
		intent := parseCallback(callback)
		if intent.kind != cbExtension || intent.arg != action {
			t.Fatalf("extension callback %q parsed as %+v", callback, intent)
		}
	}

	for _, retired := range []string{
		"menu:modules",
		"module:request:on:io.example.fixture",
		"module:apply:off:io.example.fixture",
	} {
		if got := parseCallback(versionedCallback(retired)); got.kind != cbUnknown {
			t.Fatalf("retired callback %q remained actionable: %+v", retired, got)
		}
	}
}

func TestConfirmationCallbacks(t *testing.T) {
	nonce := strings.Repeat("ab", botConfirmationBytes)
	request := parseCallback(versionedCallback("request:" + string(botActionRestartMihomo)))
	if request.kind != cbRequestConfirm || request.arg != string(botActionRestartMihomo) {
		t.Fatalf("request parsed as %+v", request)
	}
	confirmed := parseCallback(versionedCallback("confirm:" + string(botActionRestartMihomo) + ":" + nonce))
	if confirmed.kind != cbConfirmAction || confirmed.arg != string(botActionRestartMihomo) || confirmed.nonce != nonce {
		t.Fatalf("confirmation parsed as %+v", confirmed)
	}
	cancelled := parseCallback(versionedCallback("cancel:" + nonce))
	if cancelled.kind != cbCancelAction || cancelled.nonce != nonce {
		t.Fatalf("cancel parsed as %+v", cancelled)
	}
	if got := parseCallback(versionedCallback("confirm:restart-mihomo:not-hex")); got.kind != cbUnknown {
		t.Fatalf("malformed confirmation parsed as %+v", got)
	}
}
