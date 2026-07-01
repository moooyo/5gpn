package main

import (
	"context"
	"fmt"
	"html"
	"os/exec"
	"strings"
	"time"
)

// This file holds the Phase-5 Task-3 OS-operation ops ported from tgbot.py:
// service restart (→ hot reload for 5gpn-dns), journalctl logs, certbot cert
// renewal, and the iOS profile QR. These are the only bot operations that shell
// out (systemctl / journalctl / certbot / qrencode are not part of the
// control-plane API); everything else goes through the in-process Controller.
//
// Injectability for tests: the shelling-out primitive is Bot.runFn (a nil field
// falls back to the real run via Bot.run), and the three iOS-host source files
// are package vars — so bot_ops_test.go can stub run and point the host files at
// a temp dir without ever invoking a real subprocess or reading /etc/5gpn.

// iosPort is the port the on-box iOS-profile responder listens on (mirrors
// tgbot.py's IOS_PORT).
const iosPort = "8111"

// iOS-host source files, in preference order (gateway_ip > public_ip > domain).
// Package vars, not constants, so tests can repoint them at a temp dir. Named
// distinctly from bot_render.go's confDir-derived reads: iosDomainFile is the
// same .domain path but kept separate so a test can vary the iOS-host lookup in
// isolation. Mirrors tgbot.py's GATEWAY_FILE / PUBLIC_IP_FILE / DOMAIN_FILE.
var (
	gatewayIPFile = "/etc/5gpn/.gateway_ip"
	publicIPFile  = "/etc/5gpn/.public_ip"
	iosDomainFile = "/etc/5gpn/.domain"
)

// run executes a fixed argv with a timeout, returning (ok, ansi-stripped
// combined stdout+stderr). It NEVER uses a shell: argv is passed verbatim to
// exec.CommandContext, so a user-supplied value can never be interpreted as a
// command. Direct port of tgbot.py's run(). Cross-platform to compile — on the
// Windows dev box the target binaries simply won't exist (run reports that
// gracefully); tests stub this out entirely.
//
//   - timeout → the context is cancelled and the process killed; run returns
//     (false, "执行超时（Ns）").
//   - command not found → (false, "命令不存在：<argv0>").
//   - any other start/wait error → (false, "错误：<err>").
//   - otherwise → (exit==0, output).
func run(argv []string, timeout time.Duration) (bool, string) {
	if len(argv) == 0 {
		return false, "错误：空命令"
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	out, err := cmd.CombinedOutput()
	clean := ansiRE.ReplaceAllString(string(out), "")

	if ctx.Err() == context.DeadlineExceeded {
		return false, fmt.Sprintf("执行超时（%ds）", int(timeout.Seconds()))
	}
	if err != nil {
		// Distinguish "binary not found" (friendlier message) from a non-zero
		// exit (the output IS the useful part — e.g. journalctl printing a
		// state line). exec.ErrNotFound / *exec.Error wrap the lookup failure.
		if execErr, ok := err.(*exec.Error); ok {
			return false, "命令不存在：" + execErr.Name
		}
		// A non-zero exit still carries useful output (return it), but report
		// ok=false so callers can branch. If there's no output at all, surface
		// the error text.
		if strings.TrimSpace(clean) == "" {
			return false, "错误：" + err.Error()
		}
		return false, clean
	}
	return true, clean
}

// run is the injectable seam: it prefers the Bot's runFn stub (set by tests or
// wiring) and falls back to the real package-level run. This keeps every op
// method calling bt.run(...) while remaining subprocess-free under test.
func (bt *Bot) run(argv []string, timeout time.Duration) (bool, string) {
	if bt.runFn != nil {
		return bt.runFn(argv, timeout)
	}
	return run(argv, timeout)
}

// --------------------------------------------------------------------------- //
// Restart (→ hot reload for 5gpn-dns; real restart for sing-box)
// --------------------------------------------------------------------------- //

// opRestart handles the restart:<svc> callbacks. The self-restart paradox: the
// bot now runs INSIDE the 5gpn-dns process, so a `systemctl restart 5gpn-dns`
// would kill the bot mid-command. Therefore 5gpn-dns is NOT restarted — it is
// hot-reloaded in-process via ctrl.Reload() and labeled 热重载 (not 重启). Only
// sing-box gets a real `systemctl restart`. "all" does both. An unknown service
// is rejected without shelling out or reloading.
func (bt *Bot) opRestart(svc string) string {
	switch svc {
	case "all":
		var lines []string
		lines = append(lines, bt.restartSingBox())
		lines = append(lines, bt.reload5gpnDNS())
		return "♻️ <b>全部服务已处理</b>\n" + strings.Join(lines, "\n")
	case "sing-box":
		return bt.restartSingBox()
	case "5gpn-dns":
		return bt.reload5gpnDNS()
	default:
		return "未知服务。"
	}
}

// restartSingBox does a real `systemctl restart sing-box`, then reports the
// resulting is-active state. Mirrors tgbot.py's op_restart for sing-box.
func (bt *Bot) restartSingBox() string {
	bt.run([]string{"systemctl", "restart", "sing-box"}, 60*time.Second)
	state := bt.serviceActive("sing-box")
	icon := "❌"
	if state == "active" {
		icon = "✅"
	}
	return fmt.Sprintf("%s <b>sing-box</b> 已重启（%s）", icon, html.EscapeString(state))
}

// reload5gpnDNS hot-reloads 5gpn-dns's rules in-process (ctrl.Reload()) instead
// of restarting the host process — see opRestart's self-restart note.
func (bt *Bot) reload5gpnDNS() string {
	if err := bt.ctrl.Reload(); err != nil {
		return "❌ <b>5gpn-dns 热重载失败</b>\n" + pre(err.Error())
	}
	return "♻️ 5gpn-dns 已热重载规则（进程内，不重启）"
}

// serviceActive returns the injectable-run equivalent of `systemctl is-active
// <unit>` (its trimmed stdout, e.g. "active"/"failed"), so restart reporting
// uses the same stubbed run in tests rather than the real systemctl. `is-active`
// exits non-zero for a non-active unit but still prints the state, so we use the
// output regardless of ok.
func (bt *Bot) serviceActive(unit string) string {
	_, out := bt.run([]string{"systemctl", "is-active", unit}, 10*time.Second)
	state := strings.TrimSpace(out)
	if state == "" {
		return "unknown"
	}
	return state
}

// --------------------------------------------------------------------------- //
// Logs (journalctl)
// --------------------------------------------------------------------------- //

// opLogs handles the logs:<svc> callbacks: it tails the last 50 lines of a
// known service's journal and returns them <pre>-wrapped (the raw content IS the
// requested result). Only the two known data-path services are allowed; any
// other value is rejected without shelling out. Mirrors tgbot.py's op_logs.
func (bt *Bot) opLogs(svc string) string {
	if !isKnownService(svc) {
		return "未知服务。"
	}
	_, out := bt.run(
		[]string{"journalctl", "-u", svc, "-n", "50", "--no-pager", "-o", "short-iso"},
		30*time.Second,
	)
	return fmt.Sprintf("📜 <b>%s</b> 最近 50 行：\n%s", html.EscapeString(svc), pre(out))
}

// isKnownService reports whether svc is one of the two data-path services the
// bot may restart/tail (guards logs: and restart: against arbitrary units).
func isKnownService(svc string) bool {
	for _, s := range botServices {
		if s == svc {
			return true
		}
	}
	return false
}

// --------------------------------------------------------------------------- //
// Cert renewal (certbot)
// --------------------------------------------------------------------------- //

// opRenewCert runs `certbot renew` and classifies the result. certbot is
// launched via `systemd-run` — a transient unit spawned by PID 1 that does NOT
// inherit 5gpn-dns's hardened sandbox (ProtectSystem=strict, read-only
// /etc/5gpn/cert, etc.). This lets certbot write /etc/letsencrypt and its deploy
// hook refresh /etc/5gpn/cert without loosening the resolver's own unit — the
// bot now runs in-process, so a bare `certbot` would inherit the tight sandbox
// and fail to write its state. The deploy hook SIGHUPs 5gpn-dns to pick up the
// renewed cert. Port of tgbot.py's op_renew_cert (wording branches preserved).
func (bt *Bot) opRenewCert() string {
	ok, out := bt.run([]string{
		"systemd-run", "--pipe", "--collect", "--quiet",
		"certbot", "renew", "--non-interactive",
	}, 600*time.Second)
	tail := tailLines(out, 12)
	if ok {
		lower := strings.ToLower(out)
		if strings.Contains(out, "No renewals were attempted") || strings.Contains(lower, "not yet due") {
			return "ℹ️ <b>证书尚未到期</b>，无需续期。\n" + pre(tail)
		}
		return "✅ <b>证书已续期</b>（续期钩子会重载 5gpn-dns）。\n" + pre(tail)
	}
	return "❌ <b>证书续期失败</b>\n" + pre(tail)
}

// --------------------------------------------------------------------------- //
// iOS profile QR
// --------------------------------------------------------------------------- //

// iosHost picks the host for the iOS profile URL, mirroring install.sh's
// print_qr/regen_ios and tgbot.py's _ios_host: prefer the client-facing gateway
// IP, then the public IP, then the domain. In NPN deployments the gateway IP is
// the internal 172.22 address and the iOS responder (:8111) is firewalled to
// 172.22.0.0/16; the bare domain resolves to the public IP and would be dropped
// there, so .gateway_ip wins. Non-NPN: .gateway_ip == .public_ip, so the URL is
// unchanged in practice. Reads the injectable package-var paths.
func iosHost() string {
	if v := readFileTrim(gatewayIPFile); v != "" {
		return v
	}
	if v := readFileTrim(publicIPFile); v != "" {
		return v
	}
	return readFileTrim(iosDomainFile)
}

// opIOS builds the iOS profile URL (http://<host>:8111/ios-dot.mobileconfig)
// and, when qrencode is available, an ANSI-UTF8 QR block for it. If no host is
// configured yet, it returns a "not found" notice (and never shells out). If
// qrencode is missing/fails, the URL alone is still returned — it is actionable
// on its own. Port of tgbot.py's op_ios.
func (bt *Bot) opIOS() string {
	host := iosHost()
	if host == "" {
		return fmt.Sprintf(
			"未找到网关地址（%s / %s / %s 均为空）。先在服务器上完成安装。",
			gatewayIPFile, publicIPFile, iosDomainFile,
		)
	}
	url := fmt.Sprintf("http://%s:%s/ios-dot.mobileconfig", host, iosPort)
	cap := "📱 <b>iOS DoT 描述文件</b>\n用相机/浏览器打开下面的地址安装（仅蜂窝网生效）：\n" +
		fmt.Sprintf("<code>%s</code>", html.EscapeString(url))

	ok, qr := bt.run([]string{"qrencode", "-t", "ANSIUTF8", "-m", "1", url}, 15*time.Second)
	if ok && strings.TrimSpace(qr) != "" {
		return cap + "\n\n<pre>" + html.EscapeString(qr) + "</pre>"
	}
	// qrencode missing / failed: the URL alone is still actionable.
	return cap
}
