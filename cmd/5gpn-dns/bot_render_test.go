package main

import (
	"strings"
	"testing"
	"time"
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
// asserts the reason-level breakdown (总查询 / 直连 / 代理 / 广告 / 缓存) and the
// upstream health (china/trust ok/err) appear, mirroring op_status's stats line.
func TestRenderStatus_ReasonBreakdown(t *testing.T) {
	st := Stats{
		Total:           100,
		Adblock:         7,
		ForceDirect:     5,
		Blacklist:       3,
		ChnrouteCN:      40,
		ChnrouteForeign: 45,
		CacheEntries:    12,
		ChinaOK:         80,
		ChinaErr:        2,
		TrustOK:         60,
		TrustErr:        1,
	}
	facts := statusFacts{domain: "dns.example.com", publicIP: "203.0.113.9"}
	svc := map[string]string{"5gpn-dns": "active", "sing-box": "active"}

	out := renderStatus(st, svc, facts, "" /* no metrics card in test */, nil)

	// The reason breakdown must be derivable/visible:
	// 直连 = force_direct(5) + chnroute_cn(40) = 45
	// 代理 = blacklist(3) + chnroute_foreign(45) = 48
	for _, want := range []string{
		"总", "100", // total
		"直连", "45", // force_direct + chnroute_cn
		"代理", "48", // blacklist + chnroute_foreign
		"广告", "7", // adblock
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
	svc := map[string]string{"5gpn-dns": "active", "sing-box": "failed"}
	out := renderStatus(Stats{}, svc, statusFacts{}, "", nil)
	if !strings.Contains(out, "❌") {
		t.Errorf("renderStatus with a down service should show ❌\n---\n%s", out)
	}
	if !strings.Contains(out, "sing-box") {
		t.Errorf("renderStatus should name the services\n---\n%s", out)
	}
}

// TestRenderStatusCert renders the TLS-cert expiry line in the status card.
func TestRenderStatusCert(t *testing.T) {
	svc := map[string]string{"5gpn-dns": "active", "sing-box": "active"}
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

// TestRenderUpdateResults renders a mixed success/failure Update() batch like
// op_update_lists, asserting per-result rendering and the mixed-failure header.
func TestRenderUpdateResults(t *testing.T) {
	t.Run("mixed success and failure", func(t *testing.T) {
		res := []UpdateResult{
			{ID: "chnroute", OK: true, Entries: 9000},
			{ID: "adblock-1", OK: false, Err: "http 500"},
		}
		out := renderUpdateResults(res)
		for _, want := range []string{"chnroute", "9000", "adblock-1", "http 500", "部分失败"} {
			if !strings.Contains(out, want) {
				t.Errorf("renderUpdateResults missing %q\n---\n%s", want, out)
			}
		}
	})

	t.Run("all success", func(t *testing.T) {
		out := renderUpdateResults([]UpdateResult{{ID: "chnroute", OK: true, Entries: 5}})
		if strings.Contains(out, "部分失败") {
			t.Errorf("all-success render should not claim partial failure\n---\n%s", out)
		}
	})

	t.Run("no subscriptions", func(t *testing.T) {
		out := renderUpdateResults(nil)
		if !strings.Contains(out, "没有配置任何订阅") {
			t.Errorf("empty render should note no subscriptions\n---\n%s", out)
		}
	})
}

// TestRenderDomains renders the blacklist domain list like op_list_domains,
// covering the empty and non-empty cases.
func TestRenderDomains(t *testing.T) {
	t.Run("empty list", func(t *testing.T) {
		out := renderDomains(nil)
		if !strings.Contains(out, "列表为空") {
			t.Errorf("empty domains render should say the list is empty\n---\n%s", out)
		}
	})
	t.Run("with entries", func(t *testing.T) {
		out := renderDomains([]string{"a.com", "b.net"})
		for _, want := range []string{"a.com", "b.net", "2"} {
			if !strings.Contains(out, want) {
				t.Errorf("domains render missing %q\n---\n%s", want, out)
			}
		}
	})
}
