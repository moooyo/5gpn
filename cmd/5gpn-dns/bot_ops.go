package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"html"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// This file holds the bot operations that reach the host: service restart
// (with hot reload for 5gpn-dns), journal logs, scoped certificate renewal, and
// iOS profile QR generation. Everything else goes through the in-process
// Controller.
//
// Injectability for tests: the shelling-out primitive is Bot.runFn (a nil field
// falls back to the real run via Bot.run), and the three iOS-host source files
// are package vars — so bot_ops_test.go can stub run and point the host files at
// a temp dir without ever invoking a real subprocess or reading /etc/5gpn.

// iOS-host / identity facts come from the daemon's environment, which systemd
// populates from the single config file /etc/5gpn/dns.env (EnvironmentFile). The
// keys are read via package vars so tests can override them with t.Setenv.
var baseDomainEnv = "DNS_BASE_DOMAIN"

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
		// exit (the output IS the useful part — e.g. systemctl printing a
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

// botOperationResult is the common outcome of every privileged bot operation.
// HTMLSummary is trusted, locally-authored Telegram HTML; Detail is always raw
// command/error output and is escaped only when HTML renders it. Keeping the
// success bit separate from the human text lets the callback handler record a
// final ok/err audit entry without guessing from an emoji or translated text.
type botOperationResult struct {
	OK             bool
	HTMLSummary    string
	Detail         string
	Duration       time.Duration
	KeepDetailTail bool
}

// HTML renders an operation result without ever interpreting subprocess output
// as Telegram markup. Log-like details keep their newest content when they must
// be shortened; diagnostics use the beginning by default.
func (r botOperationResult) HTML() string {
	if strings.TrimSpace(r.Detail) == "" {
		return r.HTMLSummary
	}
	detail := pre(r.Detail)
	if r.KeepDetailTail {
		detail = preTail(r.Detail)
	}
	return r.HTMLSummary + "\n" + detail
}

// botPrivilegedAction is deliberately closed: confirmation callback data may
// name only these two destructive/expensive actions. Rule reload is quick and
// reversible, while log/status/diagnostic operations are read-only.
type botPrivilegedAction string

const (
	botActionRestartMihomo botPrivilegedAction = "restart-mihomo"
	botActionRenewCert     botPrivilegedAction = "renew-cert"
	botConfirmationTTL                         = 60 * time.Second
	botConfirmationBytes                       = 12
)

func validBotPrivilegedAction(action botPrivilegedAction) bool {
	switch action {
	case botActionRestartMihomo, botActionRenewCert:
		return true
	default:
		return false
	}
}

type botConfirmation struct {
	action  botPrivilegedAction
	adminID int64
	chatID  int64
	expires time.Time
}

// botActionGuard provides both one-use confirmation nonces and Bot-wide
// single-flight exclusion for privileged actions. Its zero value is usable.
// A nonce is bound to the requesting admin, private chat and exact action, so a
// forwarded button or replay cannot authorize another operation.
type botActionGuard struct {
	mu            sync.Mutex
	confirmations map[string]botConfirmation
	inFlight      map[botPrivilegedAction]bool
	now           func() time.Time
	entropy       io.Reader
	ttl           time.Duration
}

func newBotActionGuard() *botActionGuard {
	return &botActionGuard{
		confirmations: make(map[string]botConfirmation),
		inFlight:      make(map[botPrivilegedAction]bool),
		now:           time.Now,
		entropy:       rand.Reader,
		ttl:           botConfirmationTTL,
	}
}

func (g *botActionGuard) initLocked() {
	if g.confirmations == nil {
		g.confirmations = make(map[string]botConfirmation)
	}
	if g.inFlight == nil {
		g.inFlight = make(map[botPrivilegedAction]bool)
	}
	if g.now == nil {
		g.now = time.Now
	}
	if g.entropy == nil {
		g.entropy = rand.Reader
	}
	if g.ttl <= 0 {
		g.ttl = botConfirmationTTL
	}
}

func (g *botActionGuard) pruneLocked(now time.Time) {
	for nonce, c := range g.confirmations {
		if !now.Before(c.expires) {
			delete(g.confirmations, nonce)
		}
	}
}

// Issue creates a fresh confirmation nonce and revokes any older outstanding
// nonce for the same admin/chat/action tuple.
func (g *botActionGuard) Issue(action botPrivilegedAction, adminID, chatID int64) (string, time.Time, error) {
	if !validBotPrivilegedAction(action) {
		return "", time.Time{}, fmt.Errorf("unsupported bot action %q", action)
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	g.initLocked()
	now := g.now()
	g.pruneLocked(now)

	var nonce string
	for attempt := 0; attempt < 4; attempt++ {
		raw := make([]byte, botConfirmationBytes)
		if _, err := io.ReadFull(g.entropy, raw); err != nil {
			return "", time.Time{}, fmt.Errorf("generate confirmation nonce: %w", err)
		}
		candidate := hex.EncodeToString(raw)
		if _, exists := g.confirmations[candidate]; !exists {
			nonce = candidate
			break
		}
	}
	if nonce == "" {
		return "", time.Time{}, fmt.Errorf("generate confirmation nonce: repeated collision")
	}

	for nonce, c := range g.confirmations {
		if c.action == action && c.adminID == adminID && c.chatID == chatID {
			delete(g.confirmations, nonce)
		}
	}
	expires := now.Add(g.ttl)
	g.confirmations[nonce] = botConfirmation{
		action: action, adminID: adminID, chatID: chatID, expires: expires,
	}
	return nonce, expires, nil
}

// Consume authorizes exactly one matching operation. A mismatch does not burn
// the real owner's ticket; an expired or successfully used nonce is deleted.
func (g *botActionGuard) Consume(nonce string, action botPrivilegedAction, adminID, chatID int64) bool {
	if !validBotPrivilegedAction(action) {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.initLocked()
	now := g.now()
	c, ok := g.confirmations[nonce]
	if !ok {
		return false
	}
	if !now.Before(c.expires) {
		delete(g.confirmations, nonce)
		return false
	}
	if c.action != action || c.adminID != adminID || c.chatID != chatID {
		return false
	}
	delete(g.confirmations, nonce)
	return true
}

// Cancel deletes a confirmation only for the admin/chat that owns it.
func (g *botActionGuard) Cancel(nonce string, adminID, chatID int64) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.initLocked()
	c, ok := g.confirmations[nonce]
	if !ok || c.adminID != adminID || c.chatID != chatID {
		return false
	}
	delete(g.confirmations, nonce)
	return true
}

// RevokeAdmin invalidates every unconsumed maintenance confirmation issued to
// an administrator whose authorization was removed. Already running actions
// remain governed by their process-wide single-flight lifecycle.
func (g *botActionGuard) RevokeAdmin(adminID int64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.initLocked()
	for nonce, confirmation := range g.confirmations {
		if confirmation.adminID == adminID {
			delete(g.confirmations, nonce)
		}
	}
}

// TryStart/Finish form the single-flight boundary around the actual command.
// Exclusion is per action and shared by all updates handled by one Bot, which
// prevents two admins from concurrently restarting mihomo or renewing the same
// certificate.
func (g *botActionGuard) TryStart(action botPrivilegedAction) bool {
	if !validBotPrivilegedAction(action) {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.initLocked()
	if g.inFlight[action] {
		return false
	}
	g.inFlight[action] = true
	return true
}

func (g *botActionGuard) Finish(action botPrivilegedAction) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.initLocked()
	delete(g.inFlight, action)
}

// restartMihomoResult restarts mihomo and verifies the resulting active state.
func (bt *Bot) restartMihomoResult() botOperationResult {
	started := time.Now()
	restartOK, restartOut := bt.run([]string{"systemctl", "restart", "mihomo"}, 60*time.Second)
	activeOK, stateOut := bt.run([]string{"systemctl", "is-active", "mihomo"}, 10*time.Second)
	state := normalizedServiceState(stateOut)
	ok := restartOK && activeOK && state == "active"

	if ok {
		return botOperationResult{
			OK:          true,
			HTMLSummary: "✅ <b>mihomo</b> 已重启并确认 active",
			Duration:    time.Since(started),
		}
	}

	var detail []string
	if !restartOK {
		detail = append(detail, "systemctl restart 失败：\n"+strings.TrimSpace(restartOut))
	}
	if !activeOK || state != "active" {
		detail = append(detail, "systemctl is-active 未确认服务正常：\n"+strings.TrimSpace(stateOut))
	}
	return botOperationResult{
		OK: false,
		HTMLSummary: fmt.Sprintf(
			"❌ <b>Mihomo 重启失败</b>（当前状态：%s）",
			html.EscapeString(state),
		),
		Detail:   strings.Join(detail, "\n\n"),
		Duration: time.Since(started),
	}
}

func (bt *Bot) reload5gpnDNSResult() botOperationResult {
	started := time.Now()
	if err := bt.ctrl.Reload(); err != nil {
		return botOperationResult{
			OK:          false,
			HTMLSummary: "❌ <b>DNS 规则重载失败</b>",
			Detail:      err.Error(),
			Duration:    time.Since(started),
		}
	}
	return botOperationResult{
		OK:          true,
		HTMLSummary: "✅ 5gpn-dns 已热重载 DNS 规则（进程内，不重启）",
		Duration:    time.Since(started),
	}
}

// serviceActive returns the injectable-run equivalent of `systemctl is-active
// <unit>` (its trimmed stdout, e.g. "active"/"failed"), so restart reporting
// uses the same stubbed run in tests rather than the real systemctl. `is-active`
// exits non-zero for a non-active unit but still prints the state, so we use the
// output regardless of ok.
func (bt *Bot) serviceActive(unit string) string {
	_, out := bt.run([]string{"systemctl", "is-active", unit}, 10*time.Second)
	return normalizedServiceState(out)
}

func normalizedServiceState(out string) string {
	state := strings.TrimSpace(out)
	if state == "" {
		return "unknown"
	}
	// systemctl normally emits one word. Keep an unexpected diagnostic safe and
	// compact in the status/restart card instead of reflecting arbitrary output.
	if fields := strings.Fields(state); len(fields) > 0 {
		state = fields[len(fields)-1]
	}
	return truncateRunes(state, 64)
}

// --------------------------------------------------------------------------- //
// Logs (fixed systemd journal exporter)
// --------------------------------------------------------------------------- //

const (
	journalExportDir      = "/run/5gpn-journal"
	journalExportMaxBytes = 256 << 10
)

func journalExportTarget(svc string) (unit, filename string, ok bool) {
	switch svc {
	case "5gpn-dns":
		return "5gpn-journal@5gpn-dns.service", "5gpn-dns.log", true
	case "mihomo":
		return "5gpn-journal@mihomo.service", "mihomo.log", true
	default:
		return "", "", false
	}
}

// opLogsResult handles the logs:<svc> callbacks: it tails the last 50 lines of a
// known service's journal and returns them <pre>-wrapped (the raw content IS the
// requested result). The daemon cannot read the host journal directly. Instead,
// polkit lets it start one of two exact root-owned exporter instances, which
// atomically publishes a bounded read-only file. Any other service is rejected
// without starting a unit.
func (bt *Bot) opLogsResult(svc string) botOperationResult {
	started := time.Now()
	exportUnit, filename, known := journalExportTarget(svc)
	if !known {
		return botOperationResult{OK: false, HTMLSummary: "❌ 未知服务。", Duration: time.Since(started)}
	}
	ok, out := bt.run(
		[]string{"systemctl", "start", exportUnit},
		30*time.Second,
	)
	if !ok {
		return botOperationResult{
			OK:             false,
			HTMLSummary:    fmt.Sprintf("❌ <b>%s 日志读取失败</b>", html.EscapeString(svc)),
			Detail:         out,
			Duration:       time.Since(started),
			KeepDetailTail: true,
		}
	}
	dir := bt.journalDir
	if dir == "" {
		dir = journalExportDir
	}
	path := filepath.Join(dir, filename)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > journalExportMaxBytes {
		detail := ""
		if err != nil {
			detail = err.Error()
		} else if !info.Mode().IsRegular() {
			detail = "journal exporter produced a non-regular file"
		} else {
			detail = "journal exporter exceeded its output limit"
		}
		return botOperationResult{
			OK:             false,
			HTMLSummary:    fmt.Sprintf("❌ <b>%s 日志读取失败</b>", html.EscapeString(svc)),
			Detail:         detail,
			Duration:       time.Since(started),
			KeepDetailTail: true,
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return botOperationResult{
			OK:             false,
			HTMLSummary:    fmt.Sprintf("❌ <b>%s 日志读取失败</b>", html.EscapeString(svc)),
			Detail:         err.Error(),
			Duration:       time.Since(started),
			KeepDetailTail: true,
		}
	}
	return botOperationResult{
		OK:             true,
		HTMLSummary:    fmt.Sprintf("📜 <b>%s</b> 最近 50 行", html.EscapeString(svc)),
		Detail:         string(data),
		Duration:       time.Since(started),
		KeepDetailTail: true,
	}
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
// Cert renewal
// --------------------------------------------------------------------------- //

// renewalCertName returns the one certificate lineage name this daemon is
// allowed to renew. install.sh names the lineage after DNS_BASE_DOMAIN. A
// single trailing root dot is harmless in DNS configuration but is not part of
// the lineage name, so it is removed before applying the same strict FQDN
// validation used by the rest of the bot.
func renewalCertName() (string, bool) {
	name := strings.ToLower(strings.TrimSuffix(os.Getenv(baseDomainEnv), "."))
	if !isValidDomain(name) {
		return "", false
	}
	return name, true
}

// opRenewCertResult starts the one pre-installed scoped renewal unit. Missing
// or invalid identity fails closed before any subprocess is started. Using a
// fixed unit keeps the privileged command, arguments, timeout, and filesystem
// access outside bot-controlled input while preserving the resolver sandbox.
func (bt *Bot) opRenewCertResult() botOperationResult {
	started := time.Now()
	certName, valid := renewalCertName()
	if !valid {
		return botOperationResult{
			OK:          false,
			HTMLSummary: "❌ <b>证书续期已拒绝</b>\n<code>DNS_BASE_DOMAIN</code> 缺失或非法；未运行续期脚本。",
			Duration:    time.Since(started),
		}
	}
	_ = certName
	ok, out := bt.run([]string{"systemctl", "start", "5gpn-certbot-renew.service"}, 30*time.Minute)
	tail := tailLines(out, 12)
	if ok {
		return botOperationResult{
			OK:          true,
			HTMLSummary: "✅ <b>证书续期检查已完成</b>（如已到期，TLS 将在下次握手加载新文件）。",
			Detail:      tail,
			Duration:    time.Since(started),
		}
	}
	return botOperationResult{
		OK:          false,
		HTMLSummary: "❌ <b>证书续期失败</b>",
		Detail:      tail,
		Duration:    time.Since(started),
	}
}

// --------------------------------------------------------------------------- //
// iOS profile QR
// --------------------------------------------------------------------------- //

// iosHost derives the public console host from the configured base domain.
func iosHost() string {
	base := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(os.Getenv(baseDomainEnv))), ".")
	if !isValidDomain(base) {
		return ""
	}
	return "console." + base
}

// iosProfileURL returns the safe, canonical HTTPS URL used by both the URL
// keyboard button and the QR-photo path.
func iosProfileURL() (string, bool) {
	host := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(iosHost())), ".")
	if !isValidDomain(host) {
		return "", false
	}
	return "https://" + host + "/ios/ios-dot.mobileconfig", true
}

// opIOSResult renders only the actionable URL. QR delivery is a separate native
// Telegram photo action (iosQRCodePNG), avoiding unreadable ANSI-art messages.
func (bt *Bot) opIOSResult() botOperationResult {
	started := time.Now()
	url, ok := iosProfileURL()
	if !ok {
		return botOperationResult{
			OK:          false,
			HTMLSummary: fmt.Sprintf("❌ 未找到合法的控制台域名（由 %s 派生）。先完成网关域名配置。", baseDomainEnv),
			Duration:    time.Since(started),
		}
	}
	return botOperationResult{
		OK: true,
		HTMLSummary: "📱 <b>iOS DoT 描述文件</b>\n点击“安装描述文件”或发送二维码图片：\n" +
			fmt.Sprintf("<code>%s</code>", html.EscapeString(url)),
		Duration: time.Since(started),
	}
}

// iosQRCodePNG renders a bounded PNG suitable for models.InputFileUpload.
// qrencode writes to stdout; no shell is involved. The PNG signature is
// verified so command diagnostics or a corrupt result are never uploaded as an
// image. The URL remains separately available when qrencode is unavailable.
func iosQRCodePNG() ([]byte, string, error) {
	url, ok := iosProfileURL()
	if !ok {
		return nil, "", fmt.Errorf("no valid iOS profile URL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "qrencode", "-t", "PNG", "-o", "-", "-m", "1", url)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	png, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, url, fmt.Errorf("qrencode timed out")
	}
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return nil, url, fmt.Errorf("qrencode: %s", detail)
	}
	if len(png) > 10<<20 {
		return nil, url, fmt.Errorf("qrencode output is too large")
	}
	if !bytes.HasPrefix(png, []byte("\x89PNG\r\n\x1a\n")) {
		return nil, url, fmt.Errorf("qrencode returned a non-PNG response")
	}
	return png, url, nil
}
