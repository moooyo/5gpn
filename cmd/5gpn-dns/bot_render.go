package main

import (
	"fmt"
	"html"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

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

// pre wraps raw text in a safely-escaped monospace <pre> block: strip ANSI,
// trim, HTML-escape (so Telegram's HTML parse_mode never mistakes content for
// tags), and truncate to 3500 chars. Empty input becomes the (无输出)
// placeholder. Direct port of tgbot.py's pre().
func pre(text string) string {
	text = strings.TrimSpace(ansiRE.ReplaceAllString(text, ""))
	if text == "" {
		text = "(无输出)"
	}
	if len(text) > 3500 {
		text = text[:3500] + "\n... (已截断)"
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

// chunkText splits text into pieces of at most size bytes each, for paginating
// long messages under Telegram's 4096-char limit. Empty input yields a single
// empty chunk (so callers always send at least one message). Port of
// tgbot.py's _chunks().
func chunkText(text string, size int) []string {
	if text == "" {
		return []string{""}
	}
	var out []string
	for i := 0; i < len(text); i += size {
		end := i + size
		if end > len(text) {
			end = len(text)
		}
		out = append(out, text[i:end])
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
// from /etc/5gpn/.domain and /etc/5gpn/.public_ip when present.
type statusFacts struct {
	domain   string
	publicIP string
}

// confDir is the 5gpn configuration directory the bot reads facts from. Kept
// as a var so tests could point it elsewhere if needed; matches tgbot.py's
// CONF_DIR default.
var confDir = "/etc/5gpn"

// readStatusFacts loads the domain/public-IP facts from confDir. Missing files
// yield empty strings (the status card simply omits the corresponding line).
func readStatusFacts() statusFacts {
	return statusFacts{
		domain:   readFileTrim(confDir + "/.domain"),
		publicIP: readFileTrim(confDir + "/.public_ip"),
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
//	代理 = blacklist   + chnroute_foreign
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

	direct := st.ForceDirect + st.ChnrouteCN
	proxy := st.Blacklist + st.ChnrouteForeign
	lines = append(lines, "")
	lines = append(lines, fmt.Sprintf(
		"📈 查询：总 %d · 直连 %d（强制 %d + 国内 %d）· 代理 %d（黑名单 %d + 境外 %d）· 广告拦截 %d · 缓存 %d",
		st.Total, direct, st.ForceDirect, st.ChnrouteCN,
		proxy, st.Blacklist, st.ChnrouteForeign, st.Adblock, st.CacheEntries,
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

// renderDomains renders the blacklist (forced-proxy) domain list, mirroring
// tgbot.py's op_list_domains().
func renderDomains(domains []string) string {
	if len(domains) == 0 {
		return "🎯 <b>黑名单(强制代理)域名</b>\n\n（列表为空）\n用「➕ 加域名」添加一个。"
	}
	var b strings.Builder
	for i, d := range domains {
		if i > 0 {
			b.WriteByte('\n')
		}
		fmt.Fprintf(&b, "%d. %s", i+1, d)
	}
	return fmt.Sprintf("🎯 <b>黑名单(强制代理)域名</b>（%d 个）：\n<pre>%s</pre>", len(domains), html.EscapeString(b.String()))
}

// renderUpdateResults renders a subscription-refresh batch, mirroring
// tgbot.py's op_update_lists(): a per-result line and a header that flags a
// partial failure. A nil/empty batch means no subscriptions are configured.
func renderUpdateResults(results []UpdateResult) string {
	if len(results) == 0 {
		return "✅ <b>名单已刷新</b>\n（没有配置任何订阅）"
	}
	var lines []string
	anyFail := false
	for _, r := range results {
		if r.OK {
			lines = append(lines, fmt.Sprintf("✅ %s：%d 条", r.ID, r.Entries))
		} else {
			anyFail = true
			errMsg := r.Err
			if errMsg == "" {
				errMsg = "未知错误"
			}
			lines = append(lines, fmt.Sprintf("❌ %s：%s", r.ID, errMsg))
		}
	}
	head := "✅ <b>chnroute / 名单已更新</b>"
	if anyFail {
		head = "⚠️ <b>名单已更新（部分失败）</b>"
	}
	return head + "\n" + pre(strings.Join(lines, "\n"))
}

// --------------------------------------------------------------------------- //
// Inline keyboards (ported from tgbot.py, minus the T3 OS-op entries)
// --------------------------------------------------------------------------- //

func btn(text, data string) models.InlineKeyboardButton {
	return models.InlineKeyboardButton{Text: text, CallbackData: data}
}

// mainMenu is the top-level menu. Rows 1-2 are the Controller-backed subset
// (status, domains, update subscriptions, reload rules); rows 3-4 are the T3
// OS-op entries (续证书 / 重启服务 / 日志 / iOS二维码), matching tgbot.py's
// main_menu layout.
func mainMenu() *models.InlineKeyboardMarkup {
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{btn("📊 状态", "act:status"), btn("🎯 代理域名", "menu:domains"), btn("📚 订阅", "menu:subs")},
		{btn("🔄 更新订阅", "act:update_lists"), btn("♻️ 重载规则", "act:reload")},
		{btn("🔐 续证书", "act:renew"), btn("♻️ 重启服务", "menu:restart")},
		{btn("📜 日志", "menu:logs"), btn("📱 iOS二维码", "act:ios")},
	}}
}

func domainsMenu() *models.InlineKeyboardMarkup {
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{btn("➕ 加域名", "dom:add"), btn("🗑 删域名", "dom:del")},
		{btn("« 返回", "menu:main")},
	}}
}

// restartMenu is the service-restart submenu. Per the self-restart-paradox
// design decision (the bot runs inside the 5gpn-dns process), the 5gpn-dns entry
// is labeled 热重载 (in-process hot reload via ctrl.Reload()), NOT 重启 — only
// sing-box gets a real systemctl restart. Mirrors tgbot.py's restart_menu but
// with the corrected 5gpn-dns label.
func restartMenu() *models.InlineKeyboardMarkup {
	return &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{
		{btn("♻️ 5gpn-dns 热重载", "restart:5gpn-dns"), btn("🔁 sing-box", "restart:sing-box")},
		{btn("全部", "restart:all")},
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
	{Command: "cancel", Description: "取消当前操作"},
	{Command: "id", Description: "获取我的 Telegram ID"},
	{Command: "help", Description: "帮助说明"},
}

// --------------------------------------------------------------------------- //
// Callback-data classifier (pure; unit-tested)
// --------------------------------------------------------------------------- //

// callbackKind enumerates the button intents this task handles.
type callbackKind int

const (
	cbUnknown callbackKind = iota
	cbMenuMain
	cbMenuDomains
	cbStatus
	cbUpdateLists
	cbReload
	cbDomAdd
	cbDomDel
	// T3 OS-op intents.
	cbMenuRestart // menu:restart  — open the restart submenu
	cbMenuLogs    // menu:logs     — open the logs submenu
	cbRenew       // act:renew     — certbot renew
	cbIOS         // act:ios       — iOS profile QR
	cbRestart     // restart:<svc> — restart/reload a service (arg = svc)
	cbLogs        // logs:<svc>    — tail a service's journal (arg = svc)
	// Subscription management (arg = subscription id / category / format).
	cbMenuSubs   // menu:subs     — open the subscription list
	cbSubView    // subview:<id>  — subscription detail
	cbSubRefresh // subref:<id>   — refresh one subscription
	cbSubToggle  // subtog:<id>   — enable/disable a subscription
	cbSubDelete  // subdel:<id>   — delete a subscription
	cbSubAdd     // sub:add       — start the add-subscription wizard
	cbSubCat     // subcat:<cat>  — wizard: pick category
	cbSubFmt     // subfmt:<fmt>  — wizard: pick format
)

// callbackIntent is the parsed form of a button's callback_data.
type callbackIntent struct {
	kind callbackKind
	arg  string // trailing payload for unrecognized "prefix:arg" data (aids T3)
}

// parseCallback classifies callback_data into a callbackIntent. It is a pure
// function so the whole callback router is unit-testable without a live
// Telegram connection. Unrecognized data returns cbUnknown, with arg carrying
// any "prefix:arg" tail (so T3 can extend the switch for restart:/logs: without
// changing this signature).
func parseCallback(data string) callbackIntent {
	switch data {
	case "menu:main":
		return callbackIntent{kind: cbMenuMain}
	case "menu:domains":
		return callbackIntent{kind: cbMenuDomains}
	case "act:status":
		return callbackIntent{kind: cbStatus}
	case "act:update_lists":
		return callbackIntent{kind: cbUpdateLists}
	case "act:reload":
		return callbackIntent{kind: cbReload}
	case "menu:restart":
		return callbackIntent{kind: cbMenuRestart}
	case "menu:logs":
		return callbackIntent{kind: cbMenuLogs}
	case "act:renew":
		return callbackIntent{kind: cbRenew}
	case "act:ios":
		return callbackIntent{kind: cbIOS}
	case "dom:add":
		return callbackIntent{kind: cbDomAdd}
	case "dom:del":
		return callbackIntent{kind: cbDomDel}
	case "menu:subs":
		return callbackIntent{kind: cbMenuSubs}
	case "sub:add":
		return callbackIntent{kind: cbSubAdd}
	}
	// Prefix-classified data with a payload tail: restart:<svc>, logs:<svc>.
	if svc, ok := strings.CutPrefix(data, "restart:"); ok {
		return callbackIntent{kind: cbRestart, arg: svc}
	}
	if svc, ok := strings.CutPrefix(data, "logs:"); ok {
		return callbackIntent{kind: cbLogs, arg: svc}
	}
	if id, ok := strings.CutPrefix(data, "subview:"); ok {
		return callbackIntent{kind: cbSubView, arg: id}
	}
	if id, ok := strings.CutPrefix(data, "subref:"); ok {
		return callbackIntent{kind: cbSubRefresh, arg: id}
	}
	if id, ok := strings.CutPrefix(data, "subtog:"); ok {
		return callbackIntent{kind: cbSubToggle, arg: id}
	}
	if id, ok := strings.CutPrefix(data, "subdel:"); ok {
		return callbackIntent{kind: cbSubDelete, arg: id}
	}
	if cat, ok := strings.CutPrefix(data, "subcat:"); ok {
		return callbackIntent{kind: cbSubCat, arg: cat}
	}
	if format, ok := strings.CutPrefix(data, "subfmt:"); ok {
		return callbackIntent{kind: cbSubFmt, arg: format}
	}
	// Unknown: expose the "prefix:arg" tail for future extension.
	if _, arg, ok := strings.Cut(data, ":"); ok {
		return callbackIntent{kind: cbUnknown, arg: arg}
	}
	return callbackIntent{kind: cbUnknown, arg: data}
}

// disabledPreview is a reusable "no link preview" option for outgoing
// messages, mirroring tgbot.py's disable_web_page_preview=True.
func disabledPreview() *models.LinkPreviewOptions {
	return &models.LinkPreviewOptions{IsDisabled: bot.True()}
}
