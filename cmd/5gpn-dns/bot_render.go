package main

import (
	"encoding/hex"
	"fmt"
	"html"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

// This file holds the pure rendering + formatting helpers ported from
// tgbot.py, the inline-keyboard builders, the /proc-based server metrics, and
// the callback-data → intent classifier. Keeping them out of bot.go (the
// wiring/handlers) makes the render/routing logic unit-testable without a live
// Telegram connection — see bot_render_test.go and bot_test.go.

// ansiRE matches SGR ("\x1b[...m") escape sequences, ported from tgbot.py's
// _ANSI_RE. Compiled once.
var ansiRE = regexp.MustCompile("\x1b\\[[0-9;]*m")

const preContentLimit = 3500

// truncateRunes shortens text without ever splitting a UTF-8 sequence.
func truncateRunes(text string, max int) string {
	if max <= 0 {
		return ""
	}
	if utf8.RuneCountInString(text) <= max {
		return text
	}
	runes := []rune(text)
	return string(runes[:max])
}

func tailRunes(text string, max int) string {
	if max <= 0 {
		return ""
	}
	if utf8.RuneCountInString(text) <= max {
		return text
	}
	runes := []rune(text)
	return string(runes[len(runes)-max:])
}

func cleanTelegramText(text string) string {
	text = ansiRE.ReplaceAllString(text, "")
	return strings.Map(func(r rune) rune {
		switch r {
		case '\n', '\r', '\t':
			return r
		}
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) {
			return -1
		}
		return r
	}, text)
}

// pre wraps raw text in a safely escaped monospace block. Its limit is in
// Unicode code points, not bytes, so Chinese text and emoji are never cut into
// invalid UTF-8. preTail is the log-oriented variant that keeps the newest
// output when truncation is necessary.
func pre(text string) string {
	return preBlock(text, false)
}

func preTail(text string) string {
	return preBlock(text, true)
}

func preBlock(text string, keepTail bool) string {
	text = strings.TrimSpace(cleanTelegramText(text))
	if text == "" {
		text = "(无输出)"
	}
	if utf8.RuneCountInString(text) > preContentLimit {
		marker := "\n…（已截断）"
		if keepTail {
			marker = "…（前部已截断，以下为最新内容）\n"
			text = marker + tailRunes(text, preContentLimit-utf8.RuneCountInString(marker))
		} else {
			text = truncateRunes(text, preContentLimit-utf8.RuneCountInString(marker)) + marker
		}
	}
	return "<pre>" + html.EscapeString(text) + "</pre>"
}

// tailLines returns the last n non-blank lines of text, joined by newlines.
// Port of tgbot.py's _tail().
func tailLines(text string, n int) string {
	var lines []string
	for _, l := range strings.Split(text, "\n") {
		if strings.TrimSpace(l) != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

type openHTMLTag struct {
	name string
	raw  string
}

var telegramHTMLTags = map[string]bool{
	"a": true, "b": true, "strong": true, "i": true, "em": true,
	"u": true, "ins": true, "s": true, "strike": true, "del": true,
	"code": true, "pre": true, "blockquote": true, "tg-spoiler": true,
}

// htmlTag describes a complete supported Telegram HTML tag. Unsupported or
// incomplete '<...>' text is treated as visible text and therefore cannot
// corrupt the tag stack used to close/reopen chunks.
func htmlTag(raw string) (name string, closing, selfClosing, ok bool) {
	if len(raw) < 3 || raw[0] != '<' || raw[len(raw)-1] != '>' {
		return "", false, false, false
	}
	body := strings.TrimSpace(raw[1 : len(raw)-1])
	if strings.HasPrefix(body, "/") {
		closing = true
		body = strings.TrimSpace(body[1:])
	}
	if strings.HasSuffix(body, "/") {
		selfClosing = true
		body = strings.TrimSpace(strings.TrimSuffix(body, "/"))
	}
	if i := strings.IndexAny(body, " \t\r\n"); i >= 0 {
		body = body[:i]
	}
	name = strings.ToLower(body)
	if !telegramHTMLTags[name] {
		return "", false, false, false
	}
	return name, closing, selfClosing, true
}

func entityEnd(text string, start int) int {
	endLimit := start + 34
	if endLimit > len(text) {
		endLimit = len(text)
	}
	semi := strings.IndexByte(text[start:endLimit], ';')
	if semi < 0 {
		return -1
	}
	end := start + semi + 1
	entity := text[start:end]
	if html.UnescapeString(entity) == entity {
		return -1
	}
	return end
}

// chunkText paginates Telegram HTML by rendered Unicode characters. It never
// splits a UTF-8 sequence, entity, or tag; formatting tags are closed at the
// end of one chunk and reopened in the next so every chunk is independently
// valid HTML. Empty input still yields one chunk.
func chunkText(text string, size int) []string {
	if text == "" {
		return []string{""}
	}
	if size <= 0 {
		size = 1
	}

	var (
		out     []string
		chunk   strings.Builder
		visible int
		open    []openHTMLTag
	)

	closeOpen := func() {
		for i := len(open) - 1; i >= 0; i-- {
			chunk.WriteString("</" + open[i].name + ">")
		}
	}
	flush := func() {
		closeOpen()
		out = append(out, chunk.String())
		chunk.Reset()
		for _, tag := range open {
			chunk.WriteString(tag.raw)
		}
		visible = 0
	}

	for i := 0; i < len(text); {
		invalidTagStart := false
		if text[i] == '<' {
			if rel := strings.IndexByte(text[i:], '>'); rel >= 0 {
				end := i + rel + 1
				raw := text[i:end]
				if name, closing, selfClosing, ok := htmlTag(raw); ok {
					chunk.WriteString(raw)
					if closing {
						if len(open) > 0 && open[len(open)-1].name == name {
							open = open[:len(open)-1]
						}
					} else if !selfClosing {
						open = append(open, openHTMLTag{name: name, raw: raw})
					}
					i = end
					continue
				}
			}
			invalidTagStart = true
		}

		tokenEnd := i
		token := ""
		if invalidTagStart {
			tokenEnd = i + 1
			token = "&lt;"
		} else if text[i] == '&' {
			tokenEnd = entityEnd(text, i)
			if tokenEnd < 0 {
				tokenEnd = i + 1
				token = "&amp;"
			}
		}
		if tokenEnd < 0 || tokenEnd == i {
			r, width := utf8.DecodeRuneInString(text[i:])
			if width == 0 {
				break
			}
			tokenEnd = i + width
			if r == utf8.RuneError && width == 1 {
				token = string(utf8.RuneError)
			}
		}
		if visible == size {
			flush()
		}
		if token == "" {
			token = text[i:tokenEnd]
		}
		chunk.WriteString(token)
		visible++
		i = tokenEnd
	}
	if chunk.Len() > 0 || len(out) == 0 {
		closeOpen()
		out = append(out, chunk.String())
	}
	return out
}

// fmtBytes renders a byte count as a human-readable size (B/K/M/G/T/P). B is
// shown as a bare integer; larger units keep one decimal. Port of tgbot.py's
// _fmt_bytes().
func fmtBytes(n uint64) string {
	f := float64(n)
	for _, unit := range []string{"B", "K", "M", "G", "T"} {
		if f < 1024 {
			if unit == "B" {
				return fmt.Sprintf("%d%s", int64(f), unit)
			}
			return fmt.Sprintf("%.1f%s", f, unit)
		}
		f /= 1024
	}
	return fmt.Sprintf("%.1fP", f)
}

// readFileTrim reads path and returns its whitespace-trimmed contents, or ""
// on any error (missing file, permission). Port of tgbot.py's _read_file().
func readFileTrim(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// statusFacts are the gateway identity facts shown in the status card, read
// from DNS_BASE_DOMAIN / DNS_PUBLIC_IP, which systemd
// populates from the single config file /etc/5gpn/dns.env.
type statusFacts struct {
	domain   string
	publicIP string
}

// readStatusFacts loads the domain/public-IP facts from the environment. An
// unset key yields an empty string (the status card simply omits that line).
func readStatusFacts() statusFacts {
	base := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(os.Getenv(baseDomainEnv))), ".")
	domain := ""
	if isValidDomain(base) {
		domain = "dot." + base
	}
	return statusFacts{
		domain:   domain,
		publicIP: strings.TrimSpace(os.Getenv("DNS_PUBLIC_IP")),
	}
}

// --------------------------------------------------------------------------- //
// Server metrics (read from /proc + statfs; no external commands)
// --------------------------------------------------------------------------- //

// cpuIdleTotal reads the aggregate CPU line from /proc/stat and returns
// (idle+iowait, total). Port of tgbot.py's _cpu_idle_total(). Returns (0,0) on
// any error (e.g. non-Linux, where /proc/stat is absent).
func cpuIdleTotal() (idle, total uint64) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0
	}
	line := strings.SplitN(string(b), "\n", 2)[0]
	fields := strings.Fields(line)
	if len(fields) < 5 || fields[0] != "cpu" {
		return 0, 0
	}
	var sum uint64
	var vals []uint64
	for _, f := range fields[1:] {
		v, err := strconv.ParseUint(f, 10, 64)
		if err != nil {
			return 0, 0
		}
		vals = append(vals, v)
		sum += v
	}
	// idle is field index 3 (vals[3]); iowait is vals[4] when present.
	idle = vals[3]
	if len(vals) > 4 {
		idle += vals[4]
	}
	return idle, sum
}

// systemMetrics renders the compact CPU/mem/disk/uptime card, sampling CPU over
// a short interval. Port of tgbot.py's system_metrics(). All reads are from
// /proc + statfs("/"); each is individually guarded so a missing source drops
// only its line rather than failing the whole card. On a non-Linux dev box
// (where /proc is absent) this degrades to a header with whatever it could read
// (typically nothing) — callers still render the rest of the status card.
func systemMetrics() string {
	idle0, tot0 := cpuIdleTotal()
	time.Sleep(500 * time.Millisecond)
	idle1, tot1 := cpuIdleTotal()

	var cpu int
	if dtot := tot1 - tot0; dtot > 0 {
		didle := idle1 - idle0
		cpu = int(100 * (float64(dtot-didle) / float64(dtot)))
		if cpu < 0 {
			cpu = 0
		}
		if cpu > 100 {
			cpu = 100
		}
	}

	loadFields := strings.Fields(readFileTrim("/proc/loadavg"))
	load := "?"
	if len(loadFields) >= 3 {
		load = strings.Join(loadFields[:3], " ")
	}
	cores := runtime.NumCPU()

	// /proc/meminfo (values in kB).
	var memTotalKB, memAvailKB uint64
	if b, err := os.ReadFile("/proc/meminfo"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			k, v, ok := strings.Cut(line, ":")
			if !ok {
				continue
			}
			fields := strings.Fields(v)
			if len(fields) == 0 {
				continue
			}
			n, err := strconv.ParseUint(fields[0], 10, 64)
			if err != nil {
				continue
			}
			switch strings.TrimSpace(k) {
			case "MemTotal":
				memTotalKB = n
			case "MemAvailable":
				memAvailKB = n
			}
		}
	}
	memTotalMB := memTotalKB / 1024
	memAvailMB := memAvailKB / 1024
	memUsedMB := memTotalMB - memAvailMB

	// Disk usage of "/" via statfs (Linux-only; diskUsage returns (0,0) on
	// other platforms so this line is simply omitted on the dev box).
	diskUsed, diskTotal := diskUsage("/")

	// Uptime in hours.
	var upHours int
	if f := strings.Fields(readFileTrim("/proc/uptime")); len(f) > 0 {
		if secs, err := strconv.ParseFloat(f[0], 64); err == nil {
			upHours = int(secs) / 3600
		}
	}

	pct := func(u, t uint64) int {
		if t == 0 {
			return 0
		}
		return int(100 * u / t)
	}

	var out []string
	out = append(out, "━━━━━━━━━━", "🖥 <b>服务器</b>")
	out = append(out, fmt.Sprintf("⏱ 运行 %d 小时", upHours))
	out = append(out, fmt.Sprintf("🧮 CPU %d%%（load %s · %d核）", cpu, load, cores))
	out = append(out, fmt.Sprintf("🧠 内存 %d/%d MB（%d%%）", memUsedMB, memTotalMB, pct(memUsedMB, memTotalMB)))
	if diskTotal > 0 {
		out = append(out, fmt.Sprintf("🗄 磁盘 %s/%s（%d%%）", fmtBytes(diskUsed), fmtBytes(diskTotal), pct(diskUsed, diskTotal)))
	}
	return strings.Join(out, "\n")
}

// --------------------------------------------------------------------------- //
// Status card
// --------------------------------------------------------------------------- //

// renderStatus builds the compact status card: service up/down, gateway facts,
// the reason-level query breakdown, upstream health, and (appended verbatim)
// the metricsCard from systemMetrics. It is a pure function of its inputs so a
// test can drive it from a fixed Stats. Mirrors tgbot.py's op_status(), but
// reads the reason counters directly from the in-process Stats instead of over
// the HTTP API.
//
// The breakdown mirrors op_status's stats line:
//
//	直连 = force_direct + chnroute_cn
//	代理 = force_proxy + chnroute_foreign
func renderStatus(st Stats, svc map[string]string, facts statusFacts, metricsCard string, cert *CertStatus) string {
	var lines []string
	lines = append(lines, "<b>📊 5gpn 状态</b>", "")

	var down []string
	for _, name := range botServices {
		active := svc[name] == "active"
		icon := "✅ "
		if !active {
			icon = "❌ "
			down = append(down, name)
		}
		lines = append(lines, icon+name)
	}
	lines = append(lines, "")

	if facts.domain != "" {
		lines = append(lines, fmt.Sprintf("🔗 域名：<code>%s</code>", html.EscapeString(facts.domain)))
		lines = append(lines, fmt.Sprintf("🔒 DoT：<code>tls://%s:853</code>", html.EscapeString(facts.domain)))
	}
	if facts.publicIP != "" {
		lines = append(lines, fmt.Sprintf("🌍 公网 IP：<code>%s</code>", html.EscapeString(facts.publicIP)))
	}
	if cert != nil {
		switch {
		case cert.Broken:
			// The cert can't be (re)loaded (deleted/corrupt/key-mismatch). DoT
			// either fails handshakes (nothing cached) or keeps serving a
			// previously-loaded cert. This is often the ONLY surface that reaches
			// an operator in that state (the web console may be unreachable too),
			// so make it unmistakable.
			lines = append(lines, "🔴 证书：无法加载（DoT/控制台可能失败或仍在用旧证书）——请尽快修复")
		default:
			icon := "🔐"
			note := fmt.Sprintf("%d 天后过期", cert.DaysRemaining)
			switch {
			case cert.Expired:
				icon, note = "🔴", "已过期"
			case cert.DaysRemaining <= 14:
				icon = "🟠"
			}
			lines = append(lines, fmt.Sprintf("%s 证书：%s（%s 到期）", icon, note, cert.NotAfter.Format("2006-01-02")))
		}
	}

	direct := st.ForceDirect + st.ChnrouteCN
	proxy := st.ForceProxy + st.ChnrouteForeign
	lines = append(lines, "")
	lines = append(lines, fmt.Sprintf(
		"📈 查询：总 %d · 直连 %d（强制 %d + 国内 %d）· 代理 %d（GFW %d + 境外 %d）· 拦截 %d · 缓存 %d",
		st.Total, direct, st.ForceDirect, st.ChnrouteCN,
		proxy, st.ForceProxy, st.ChnrouteForeign, st.Block, st.CacheEntries,
	))
	lines = append(lines, fmt.Sprintf(
		"🔀 上游：国内 ✅%d/❌%d · 境外 ✅%d/❌%d",
		st.ChinaOK, st.ChinaErr, st.TrustOK, st.TrustErr,
	))

	if len(down) > 0 {
		lines = append(lines, "", fmt.Sprintf("⚠️ 异常：%s（用 📜 日志查看）", html.EscapeString(strings.Join(down, "、"))))
	}

	if metricsCard != "" {
		lines = append(lines, "", metricsCard)
	}
	return strings.Join(lines, "\n")
}

// renderResolveTest presents the same per-upstream DNS diagnostic used by the
// web console. Probe order is preserved because pool order, not latency,
// determines which reply a group adopts.
func renderResolveTest(result ResolveTestResult) string {
	name := result.Name
	if name == "" {
		name = "(未知域名)"
	}
	lines := []string{
		"<b>🧪 DNS 诊断</b>",
		fmt.Sprintf("域名：<code>%s</code>", html.EscapeString(name)),
	}
	if result.Verdict != "" || result.Reason != "" {
		lines = append(lines, fmt.Sprintf(
			"判定：<b>%s</b> · <code>%s</code>",
			html.EscapeString(result.Verdict), html.EscapeString(result.Reason),
		))
	}
	if result.Chosen != "" {
		lines = append(lines, fmt.Sprintf(
			"采用：<b>%s</b> · <code>%s</code>",
			html.EscapeString(result.Chosen),
			html.EscapeString(strings.Join(result.ChosenIPs, ", ")),
		))
	}
	if len(result.ClientIPs) > 0 {
		lines = append(lines, "客户端答案：<code>"+html.EscapeString(strings.Join(result.ClientIPs, ", "))+"</code>")
	}
	if len(result.Probes) == 0 {
		lines = append(lines, "", "未查询上游（规则已直接给出结果，或当前没有可用上游）。")
		return strings.Join(lines, "\n")
	}

	lines = append(lines, "", "<b>逐上游探测（配置顺序）</b>")
	for _, probe := range result.Probes {
		icon := "✅"
		outcome := strings.Join(probe.IPs, ", ")
		if probe.Err != "" {
			icon = "❌"
			outcome = probe.Err
		} else if outcome == "" {
			icon = "⚠️"
			outcome = probe.Rcode
		}
		selected := ""
		if probe.Selected {
			selected = " · 组内采用"
		}
		lines = append(lines, fmt.Sprintf(
			"%s <b>%s</b> <code>%s</code> · %.1f ms%s\n   <code>%s</code>",
			icon,
			html.EscapeString(probe.Group),
			html.EscapeString(probe.Server),
			probe.DurationMs,
			selected,
			html.EscapeString(outcome),
		))
	}
	return strings.Join(lines, "\n")
}

// --------------------------------------------------------------------------- //
// Inline keyboards
// --------------------------------------------------------------------------- //

const botCallbackPrefix = "b1:"

func versionedCallback(data string) string {
	if strings.HasPrefix(data, botCallbackPrefix) {
		return data
	}
	return botCallbackPrefix + data
}

func btn(text, data string) models.InlineKeyboardButton {
	return models.InlineKeyboardButton{Text: text, CallbackData: versionedCallback(data)}
}

func urlBtn(text, target string) models.InlineKeyboardButton {
	return models.InlineKeyboardButton{Text: text, URL: target}
}

func webConsoleURL() (string, bool) {
	base := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(os.Getenv(baseDomainEnv))), ".")
	if isValidDomain(base) {
		return "https://console." + base + "/", true
	}
	return "", false
}

// mainMenu keeps frequent read-only tasks at the top and moves privileged
// operations into one maintenance submenu. Policy/subscription editing remains
// exclusively in the Web console.
func mainMenu() *models.InlineKeyboardMarkup {
	rows := [][]models.InlineKeyboardButton{
		{btn("📊 状态", "act:status"), btn("🧪 DNS 诊断", "act:diagnose")},
		{btn("📜 日志", "menu:logs"), btn("🌐 上游 DNS", "menu:upstreams")},
		{btn("🧩 插件管理", "ext:modules"), btn("🛍 插件市场", "ext:market")},
		{btn("📱 iOS 安装", "menu:ios")},
		{btn("🛠 维护", "menu:maintenance")},
	}
	if target, ok := webConsoleURL(); ok {
		rows = append(rows, []models.InlineKeyboardButton{urlBtn("🔗 Web 控制台", target)})
	}
	return &models.InlineKeyboardMarkup{InlineKeyboard: rows}
}

// maintenanceMenu has one unambiguous rule-reload entry. Restart and renewal
// callbacks request a one-use confirmation; they never execute directly.
func maintenanceMenu() *models.InlineKeyboardMarkup {
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{btn("♻️ 重载 DNS 规则", "act:reload")},
		{btn("🔁 重启 Mihomo", "request:"+string(botActionRestartMihomo))},
		{btn("🔐 检查并续期证书", "request:"+string(botActionRenewCert))},
		{btn("« 返回", "menu:main")},
	}}
}

// logsMenu is the log-view submenu: one row per data-path service plus a back
// button. Mirrors tgbot.py's logs_menu.
func logsMenu() *models.InlineKeyboardMarkup {
	rows := make([][]models.InlineKeyboardButton, 0, len(botServices)+1)
	for _, s := range botServices {
		rows = append(rows, []models.InlineKeyboardButton{btn(s, "logs:"+s)})
	}
	rows = append(rows, []models.InlineKeyboardButton{btn("« 返回", "menu:main")})
	return &models.InlineKeyboardMarkup{InlineKeyboard: rows}
}

func statusKB() *models.InlineKeyboardMarkup {
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{btn("🔄 刷新状态", "act:status")},
		{btn("« 返回", "menu:main")},
	}}
}

func logsResultKB(service string) *models.InlineKeyboardMarkup {
	rows := [][]models.InlineKeyboardButton{}
	if isKnownService(service) {
		rows = append(rows, []models.InlineKeyboardButton{btn("🔄 刷新日志", "logs:"+service)})
	}
	rows = append(rows, []models.InlineKeyboardButton{btn("« 返回", "menu:logs")})
	return &models.InlineKeyboardMarkup{InlineKeyboard: rows}
}

func diagnoseKB() *models.InlineKeyboardMarkup {
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{btn("🧪 再次诊断", "act:diagnose")},
		{btn("« 返回", "menu:main")},
	}}
}

func iosMenu() *models.InlineKeyboardMarkup {
	rows := [][]models.InlineKeyboardButton{}
	if target, ok := iosProfileURL(); ok {
		rows = append(rows, []models.InlineKeyboardButton{urlBtn("📥 安装描述文件", target)})
		rows = append(rows, []models.InlineKeyboardButton{btn("🖼 发送二维码图片", "act:ios-photo")})
	}
	rows = append(rows, []models.InlineKeyboardButton{btn("« 返回", "menu:main")})
	return &models.InlineKeyboardMarkup{InlineKeyboard: rows}
}

func confirmationMenu(action botPrivilegedAction, nonce string) *models.InlineKeyboardMarkup {
	if !validBotPrivilegedAction(action) || !validConfirmationNonce(nonce) {
		return backKB("menu:maintenance")
	}
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{
			btn("✅ 确认执行", "confirm:"+string(action)+":"+nonce),
			btn("取消", "cancel:"+nonce),
		},
	}}
}

// backKB is a single "« 返回" button pointing at target (default the main menu).
func backKB(target string) *models.InlineKeyboardMarkup {
	if target == "" {
		target = "menu:main"
	}
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{btn("« 返回", target)},
	}}
}

// botCommands is the quick command menu (the Telegram "Menu" button / "/").
var botCommands = []models.BotCommand{
	{Command: "menu", Description: "打开操作面板"},
	{Command: "status", Description: "查看运行状态"},
	{Command: "lookup", Description: "诊断域名解析与策略"},
	{Command: "cancel", Description: "取消待输入内容"},
	{Command: "id", Description: "获取我的 Telegram ID"},
	{Command: "help", Description: "帮助说明"},
}

var idBotCommand = []models.BotCommand{
	{Command: "id", Description: "获取我的 Telegram ID"},
}

// --------------------------------------------------------------------------- //
// Callback-data classifier (pure; unit-tested)
// --------------------------------------------------------------------------- //

// callbackKind enumerates the button intents this task handles.
type callbackKind int

const (
	cbUnknown callbackKind = iota
	cbMenuMain
	cbStatus
	cbDiagnose
	cbUpstreams // menu:upstreams — read-only china/trust upstream view
	cbReload
	cbMenuMaintenance
	cbMenuLogs
	cbMenuIOS
	cbIOSPhoto
	cbExtension
	cbRequestConfirm
	cbConfirmAction
	cbCancelAction
	cbLogs // logs:<svc> — tail a service's journal (arg = svc)
)

// callbackIntent is the parsed form of a button's callback_data.
type callbackIntent struct {
	kind  callbackKind
	arg   string
	nonce string
}

func validConfirmationNonce(nonce string) bool {
	if len(nonce) != botConfirmationBytes*2 {
		return false
	}
	_, err := hex.DecodeString(nonce)
	return err == nil
}

// parseCallback classifies current, versioned callback data without a live
// Telegram connection. Unversioned data is not part of the callback protocol.
func parseCallback(data string) callbackIntent {
	payload, versioned := strings.CutPrefix(data, botCallbackPrefix)
	if !versioned {
		return callbackIntent{kind: cbUnknown, arg: data}
	}

	switch payload {
	case "menu:main":
		return callbackIntent{kind: cbMenuMain}
	case "act:status":
		return callbackIntent{kind: cbStatus}
	case "act:diagnose":
		return callbackIntent{kind: cbDiagnose}
	case "menu:upstreams":
		return callbackIntent{kind: cbUpstreams}
	case "act:reload":
		return callbackIntent{kind: cbReload}
	case "menu:maintenance":
		return callbackIntent{kind: cbMenuMaintenance}
	case "menu:logs":
		return callbackIntent{kind: cbMenuLogs}
	case "menu:ios":
		return callbackIntent{kind: cbMenuIOS}
	case "act:ios-photo":
		return callbackIntent{kind: cbIOSPhoto}
	}
	if rest, ok := strings.CutPrefix(payload, "ext:"); ok && rest != "" && len(rest) <= 57 {
		return callbackIntent{kind: cbExtension, arg: rest}
	}
	if svc, ok := strings.CutPrefix(payload, "logs:"); ok {
		return callbackIntent{kind: cbLogs, arg: svc}
	}
	if actionRaw, ok := strings.CutPrefix(payload, "request:"); ok {
		action := botPrivilegedAction(actionRaw)
		if validBotPrivilegedAction(action) {
			return callbackIntent{kind: cbRequestConfirm, arg: actionRaw}
		}
	}
	if rest, ok := strings.CutPrefix(payload, "confirm:"); ok {
		actionRaw, nonce, found := strings.Cut(rest, ":")
		action := botPrivilegedAction(actionRaw)
		if found && validBotPrivilegedAction(action) && validConfirmationNonce(nonce) {
			return callbackIntent{kind: cbConfirmAction, arg: actionRaw, nonce: nonce}
		}
	}
	if nonce, ok := strings.CutPrefix(payload, "cancel:"); ok && validConfirmationNonce(nonce) {
		return callbackIntent{kind: cbCancelAction, nonce: nonce}
	}
	if _, arg, ok := strings.Cut(payload, ":"); ok {
		return callbackIntent{kind: cbUnknown, arg: arg}
	}
	return callbackIntent{kind: cbUnknown, arg: payload}
}

// disabledPreview is a reusable "no link preview" option for outgoing
// messages, mirroring tgbot.py's disable_web_page_preview=True.
func disabledPreview() *models.LinkPreviewOptions {
	return &models.LinkPreviewOptions{IsDisabled: bot.True()}
}
