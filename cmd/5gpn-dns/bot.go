package main

import (
	"context"
	"fmt"
	"html"
	"log"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

// botServices are the two data-path services the status card reports on (and
// that T3 will let an admin restart / tail). The bot only reads their state
// here (systemctl is-active); mutation lands in T3. mihomo replaces xray as
// the SNI/QUIC transparent-proxy data-plane service (see the mihomo
// migration note in main.go).
var botServices = []string{"5gpn-dns", "mihomo"}

// domainRE is the canonical FQDN pattern, ported from tgbot.py's DOMAIN_RE but
// adapted for Go's RE2 engine, which has NO lookahead. tgbot.py used a
// `(?=.{1,253}$)` lookahead to bound total length; RE2 can't express that, so
// isValidDomain does the ≤253 length check in code (mirroring install.sh's
// is_valid_domain, which likewise checks length separately because bash ERE has
// no lookahead — see install.sh:387). The remaining rule is identical: one or
// more lowercase [a-z0-9-] labels (each 1..63 chars, no leading/trailing hyphen)
// followed by an alphabetic 2..63 TLD. Compiled once as a package var.
var domainRE = regexp.MustCompile(`^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$`)

// isValidDomain reports whether s is a syntactically valid FQDN under the
// canonical rule shared with tgbot.py's DOMAIN_RE and install.sh's
// is_valid_domain. The input is lowercased first (matching install.sh's
// `tr A-Z a-z`), then bounded to 1..253 chars, then matched against domainRE.
func isValidDomain(s string) bool {
	s = strings.ToLower(s)
	if len(s) < 1 || len(s) > 253 {
		return false
	}
	return domainRE.MatchString(s)
}

// Bot is the in-process Telegram control plane. It wraps a *bot.Bot
// (long-polling) and calls the in-memory Controller directly — no HTTP, no
// bearer token. This is the Phase 5 Task 1 skeleton: connect, admin-gate, and
// the /id bootstrap command. Command handlers (subscriptions, rules, status,
// etc.) land in later tasks.
type Bot struct {
	tg     *bot.Bot
	ctrl   *Controller
	admins map[int64]bool

	// pending is the per-chat conversational state machine, mirroring
	// tgbot.py's PENDING dict: chat_id -> action. A slash command or /cancel
	// clears it. Guarded by mu. UP-1 Task D3/D4 removed the only actions that
	// ever set one (add_domain/del_domain, sub_name/sub_url — the manual-rule
	// and subscription-management commands absorbed by the web-console-managed
	// policy-rule model); the pending machinery itself is kept as generic
	// per-chat conversational-flow infra for any future multi-step command.
	mu      sync.Mutex
	pending map[int64]string

	// runFn is the injectable shelling-out seam for the T3 OS-op handlers
	// (restart/logs/certbot/QR). A nil runFn means "use the real run" (via
	// Bot.run); tests set it to a stub so no real systemctl/journalctl/certbot/
	// qrencode is ever invoked. Gateway/domain facts are read from disk
	// (readStatusFacts / iosHost).
	runFn func(argv []string, timeout time.Duration) (bool, string)
}

// NewBot constructs the in-process Telegram bot. An empty cfg.TGBotToken means
// the bot is disabled: NewBot returns (nil, nil) — not an error — and the
// caller (T5, main) simply skips Run. With a token it builds the *bot.Bot with
// an admin-gate middleware, a default handler, and the /id command registered.
//
// Note: bot.New performs a getMe round-trip to Telegram to validate the token,
// so NewBot only reaches out to the network when a token is configured.
func NewBot(cfg Config, ctrl *Controller) (*Bot, error) {
	if cfg.TGBotToken == "" {
		return nil, nil // disabled, not an error
	}

	bt := &Bot{
		ctrl:    ctrl,
		admins:  cfg.TGBotAdmins,
		pending: make(map[int64]string),
	}

	opts := []bot.Option{
		// recoverMiddleware MUST come first so it is the OUTERMOST wrapper (see
		// applyMiddlewares: m[0] wraps all the rest) and thus guards adminGate and
		// every handler goroutine — go-telegram/bot dispatches each update in its
		// own goroutine with no recover of its own, so an unrecovered panic there
		// would crash the whole process, which is the sole DNS resolver.
		bot.WithMiddlewares(bt.recoverMiddleware, bt.adminGate),
		bot.WithDefaultHandler(bt.defaultHandler),
		bot.WithMessageTextHandler("/id", bot.MatchTypeExact, bt.handleID),
		bot.WithMessageTextHandler("/start", bot.MatchTypePrefix, bt.handleMenu),
		bot.WithMessageTextHandler("/menu", bot.MatchTypePrefix, bt.handleMenu),
		bot.WithMessageTextHandler("/help", bot.MatchTypePrefix, bt.handleMenu),
		bot.WithMessageTextHandler("/status", bot.MatchTypePrefix, bt.handleStatus),
		bot.WithMessageTextHandler("/cancel", bot.MatchTypeExact, bt.handleCancel),
		// A single callback handler routes every button press; the empty
		// prefix matches all callback_data, and parseCallback classifies it.
		bot.WithCallbackQueryDataHandler("", bot.MatchTypePrefix, bt.handleCallback),
	}

	tg, err := bot.New(cfg.TGBotToken, opts...)
	if err != nil {
		return nil, fmt.Errorf("bot: %w", err)
	}
	bt.tg = tg
	return bt, nil
}

// Run starts the long-poll loop, blocking until ctx is cancelled. It registers
// the quick-command menu first (best-effort; a failure there is non-fatal),
// then recovers from any panic so a bot crash never propagates into (or takes
// down) the host process — the bot is a best-effort control plane, not part of
// the data path.
func (bt *Bot) Run(ctx context.Context) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("bot: recovered from panic: %v", r)
		}
	}()
	bt.setCommands(ctx)
	bt.tg.Start(ctx)
}

// setCommands publishes the quick-command menu (the Telegram "Menu" button /
// typing "/"). Best-effort: any error is logged, never fatal.
func (bt *Bot) setCommands(ctx context.Context) {
	if _, err := bt.tg.SetMyCommands(ctx, &bot.SetMyCommandsParams{Commands: botCommands}); err != nil {
		log.Printf("bot: setMyCommands: %v", err)
	}
}

// isAdmin reports whether uid is an authorized admin. A nil/empty admin set
// denies everyone (defensive: an unset TGBOT_ADMINS locks the bot down rather
// than opening it up). Factored out so the gate decision is unit-testable
// without a live Telegram connection.
func (bt *Bot) isAdmin(uid int64) bool {
	return bt.admins[uid]
}

// senderID extracts the Telegram user id of whoever produced the update, from
// either a message or a callback query. Returns (0, false) if neither is
// present (e.g. an update type the bot doesn't handle).
func senderID(update *models.Update) (int64, bool) {
	switch {
	case update.Message != nil && update.Message.From != nil:
		return update.Message.From.ID, true
	case update.CallbackQuery != nil:
		return update.CallbackQuery.From.ID, true
	default:
		return 0, false
	}
}

// recoverMiddleware is the OUTERMOST middleware. go-telegram/bot dispatches every
// update in its OWN goroutine with no recover (process_update.go `go r(...)`), so
// an unrecovered panic in any handler — or in a downstream middleware such as
// adminGate — would terminate the whole process, which is the sole DNS resolver.
// bt.Run's recover cannot help: it wraps the tg.Start goroutine, not the per-update
// goroutines Start spawns. Wrapping every update here contains a handler panic to a
// logged line (plus a best-effort apology) and keeps DoT serving alive. Being m[0]
// it also protects adminGate itself, making the per-handler recovers redundant.
func (bt *Bot) recoverMiddleware(next bot.HandlerFunc) bot.HandlerFunc {
	return func(ctx context.Context, b *bot.Bot, update *models.Update) {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("bot: recovered from panic in update handler: %v", r)
				// Best-effort apology so a wedged flow isn't silent; ignore errors.
				if update.CallbackQuery != nil {
					_, _ = b.AnswerCallbackQuery(ctx, &bot.AnswerCallbackQueryParams{
						CallbackQueryID: update.CallbackQuery.ID,
						Text:            "⚠️ 内部错误",
						ShowAlert:       true,
					})
				}
			}
		}()
		next(ctx, b, update)
	}
}

// adminGate is the middleware that enforces admin-only access. It lets the /id
// text command through unconditionally (so an admin can discover their numeric
// id to add themselves to TGBOT_ADMINS), then checks the sender against the
// admin set. Non-admins get a refusal (a reply for a message, an alert for a
// callback) and next is NOT called.
func (bt *Bot) adminGate(next bot.HandlerFunc) bot.HandlerFunc {
	return func(ctx context.Context, b *bot.Bot, update *models.Update) {
		// /id is always allowed so an admin can bootstrap their id.
		if update.Message != nil && update.Message.Text == "/id" {
			next(ctx, b, update)
			return
		}

		uid, ok := senderID(update)
		if ok && bt.isAdmin(uid) {
			next(ctx, b, update)
			return
		}

		// Unauthorized (or unidentifiable sender): refuse, don't call next.
		switch {
		case update.CallbackQuery != nil:
			_, _ = b.AnswerCallbackQuery(ctx, &bot.AnswerCallbackQueryParams{
				CallbackQueryID: update.CallbackQuery.ID,
				Text:            "⛔ 未授权",
				ShowAlert:       true,
			})
		case update.Message != nil:
			_, _ = b.SendMessage(ctx, &bot.SendMessageParams{
				ChatID: update.Message.Chat.ID,
				Text:   "⛔ 未授权，请联系管理员。",
			})
		}
	}
}

// handleID replies with the sender's Telegram numeric id. Reachable by anyone
// (the gate allow-lists /id) so a would-be admin can find the id to add to
// TGBOT_ADMINS.
func (bt *Bot) handleID(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil || update.Message.From == nil {
		return
	}
	_, _ = b.SendMessage(ctx, &bot.SendMessageParams{
		ChatID:    update.Message.Chat.ID,
		Text:      fmt.Sprintf("你的 Telegram 数字 ID：<code>%d</code>", update.Message.From.ID),
		ParseMode: models.ParseModeHTML,
	})
}

// --------------------------------------------------------------------------- //
// Per-chat conversational state (mirrors tgbot.py's PENDING dict)
// --------------------------------------------------------------------------- //

// setPending records that chat's next text message is the argument to action.
func (bt *Bot) setPending(chatID int64, action string) {
	bt.mu.Lock()
	defer bt.mu.Unlock()
	bt.pending[chatID] = action
}

// getPending returns chat's pending action (and whether one is set).
func (bt *Bot) getPending(chatID int64) (string, bool) {
	bt.mu.Lock()
	defer bt.mu.Unlock()
	a, ok := bt.pending[chatID]
	return a, ok
}

// clearPending drops chat's pending action (a no-op if none is set).
func (bt *Bot) clearPending(chatID int64) {
	bt.mu.Lock()
	defer bt.mu.Unlock()
	delete(bt.pending, chatID)
}

// --------------------------------------------------------------------------- //
// Send / edit helpers
// --------------------------------------------------------------------------- //

// send delivers an HTML message, paginating anything over Telegram's limit and
// attaching kb (if non-nil) to the final chunk. Mirrors tgbot.py's send().
func (bt *Bot) send(ctx context.Context, b *bot.Bot, chatID int64, text string, kb *models.InlineKeyboardMarkup) {
	chunks := chunkText(text, 3900)
	last := len(chunks) - 1
	for i, chunk := range chunks {
		params := &bot.SendMessageParams{
			ChatID:             chatID,
			Text:               chunk,
			ParseMode:          models.ParseModeHTML,
			LinkPreviewOptions: disabledPreview(),
		}
		if kb != nil && i == last {
			params.ReplyMarkup = kb
		}
		_, _ = b.SendMessage(ctx, params)
	}
}

// edit rewrites the message a callback button belongs to, keeping a flow in one
// bubble. Falls back to a fresh message when the edit cannot be applied (e.g.
// the message is inaccessible). Mirrors tgbot.py's edit().
func (bt *Bot) edit(ctx context.Context, b *bot.Bot, cq *models.CallbackQuery, text string, kb *models.InlineKeyboardMarkup) {
	chatID, msgID, ok := callbackTarget(cq)
	if !ok {
		return
	}
	if len(text) > 4096 {
		text = text[:4096]
	}
	params := &bot.EditMessageTextParams{
		ChatID:             chatID,
		MessageID:          msgID,
		Text:               text,
		ParseMode:          models.ParseModeHTML,
		LinkPreviewOptions: disabledPreview(),
	}
	if kb != nil {
		params.ReplyMarkup = kb
	}
	if _, err := b.EditMessageText(ctx, params); err != nil {
		// "message is not modified" is benign; otherwise fall back to a fresh
		// message so the operator still sees the result.
		if !strings.Contains(err.Error(), "not modified") {
			bt.send(ctx, b, chatID, text, kb)
		}
	}
}

// callbackTarget extracts the (chatID, messageID) the callback's message lives
// in, handling both accessible and inaccessible message shapes.
func callbackTarget(cq *models.CallbackQuery) (chatID int64, msgID int, ok bool) {
	switch cq.Message.Type {
	case models.MaybeInaccessibleMessageTypeMessage:
		if m := cq.Message.Message; m != nil {
			return m.Chat.ID, m.ID, true
		}
	case models.MaybeInaccessibleMessageTypeInaccessibleMessage:
		if m := cq.Message.InaccessibleMessage; m != nil {
			return m.Chat.ID, m.MessageID, true
		}
	}
	return 0, 0, false
}

// --------------------------------------------------------------------------- //
// Command handlers
// --------------------------------------------------------------------------- //

// handleMenu opens the main menu (for /start, /menu, /help). Any slash command
// also aborts an in-progress conversational flow, mirroring tgbot.py.
func (bt *Bot) handleMenu(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	bt.clearPending(update.Message.Chat.ID)
	bt.send(ctx, b, update.Message.Chat.ID, "<b>5gpn 控制台</b>\n选择一个操作：", mainMenu())
}

// handleStatus renders the status card (for /status).
func (bt *Bot) handleStatus(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	bt.clearPending(update.Message.Chat.ID)
	bt.send(ctx, b, update.Message.Chat.ID, bt.doStatus(), backKB("menu:main"))
}

// handleCancel clears any pending flow and reopens the menu (for /cancel).
func (bt *Bot) handleCancel(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	bt.clearPending(update.Message.Chat.ID)
	bt.send(ctx, b, update.Message.Chat.ID, "已取消。", mainMenu())
}

// defaultHandler catches messages with no specific command handler. It drives
// the conversational flows: when a chat has a pending action (add_domain /
// del_domain), the next non-slash text message is treated as the domain
// argument. Any unrecognized slash command clears the flow and hints at /menu;
// plain text with no pending flow just reopens the menu. Mirrors tgbot.py's
// handle_message tail. Panics are recovered so one bad update never kills the
// poll loop.
func (bt *Bot) defaultHandler(ctx context.Context, b *bot.Bot, update *models.Update) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("bot: recovered from panic in defaultHandler: %v", r)
		}
	}()

	if update.Message == nil {
		return
	}
	chatID := update.Message.Chat.ID
	text := strings.TrimSpace(update.Message.Text)

	// Any slash command aborts an in-progress flow. (/start,/menu,/help,
	// /status,/cancel,/id have their own handlers; this catches everything
	// else, e.g. a typo.)
	if strings.HasPrefix(text, "/") {
		bt.clearPending(chatID)
		bt.send(ctx, b, chatID, "未知命令。发送 /menu 打开操作面板。", nil)
		return
	}

	// UP-1 Task D3/D4 removed every conversational flow that used to arm a
	// pending action (add/del domain, the add-subscription wizard — both
	// absorbed by the web-console-managed policy-rule model). The pending
	// machinery itself is kept (see the Bot.pending field doc) for a future
	// multi-step command; nothing currently sets one, so this always falls
	// through to reopening the menu.
	bt.clearPending(chatID)
	bt.send(ctx, b, chatID, "发送 /menu 打开操作面板。", mainMenu())
}

// --------------------------------------------------------------------------- //
// Callback (inline-button) routing
// --------------------------------------------------------------------------- //

// auditableCallbackOp reports whether an inline-button intent is a state-
// changing or privileged operation worth an audit line, and returns a short op
// label for it. Pure read-only navigation (menus, status, subscription detail
// views) returns mutating=false. Kept as a small pure function so the audit
// wiring in handleCallback stays a single call and the classification is unit-
// testable.
func auditableCallbackOp(intent callbackIntent) (op string, mutating bool) {
	switch intent.kind {
	case cbReload:
		return "reload", true
	case cbRenew:
		return "renew-cert", true
	case cbRestart:
		return "restart:" + intent.arg, true
	case cbLogs:
		return "logs:" + intent.arg, true // privileged journal exfil to Telegram
	case cbIOS:
		return "ios-profile", true
	default:
		return "", false
	}
}

// handleCallback routes every inline-button press. It answers the callback
// immediately (to stop the button's spinner), then classifies the data via the
// pure parseCallback and dispatches. Panics are recovered so one bad update
// never kills the poll loop.
func (bt *Bot) handleCallback(ctx context.Context, b *bot.Bot, update *models.Update) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("bot: recovered from panic in handleCallback: %v", r)
		}
	}()

	cq := update.CallbackQuery
	if cq == nil {
		return
	}
	// Stop the button spinner immediately; long ops still run synchronously.
	_, _ = b.AnswerCallbackQuery(ctx, &bot.AnswerCallbackQueryParams{CallbackQueryID: cq.ID})

	chatID, _, ok := callbackTarget(cq)
	if !ok {
		return
	}

	intent := parseCallback(cq.Data)

	// Audit every state-changing / privileged callback (mutations, service
	// control, cert renewal, log exfil) with the issuing admin id, mirroring the
	// :9443 API's audit trail. Read-only menu navigation is not audited. Logged at
	// invocation ("invoked"); the op's own success/failure is visible in the same
	// journald stream. See auditBot.
	if op, auditable := auditableCallbackOp(intent); auditable {
		if uid, has := senderID(update); has {
			auditBot(op, uid, "invoked")
		}
	}

	switch intent.kind {
	case cbMenuMain:
		bt.clearPending(chatID)
		bt.edit(ctx, b, cq, "选择一个操作：", mainMenu())
	case cbStatus:
		bt.edit(ctx, b, cq, bt.doStatus(), backKB("menu:main"))
	case cbUpstreams:
		bt.edit(ctx, b, cq, bt.doUpstreams(), backKB("menu:main"))
	case cbReload:
		bt.edit(ctx, b, cq, "⏳ 正在重载规则…", nil)
		bt.edit(ctx, b, cq, bt.doReload(ctx), backKB("menu:main"))
	case cbMenuRestart:
		bt.edit(ctx, b, cq, "选择要重启的服务：", restartMenu())
	case cbMenuLogs:
		bt.edit(ctx, b, cq, "选择要查看日志的服务：", logsMenu())
	case cbRenew:
		bt.edit(ctx, b, cq, "⏳ 正在续期证书，请稍候…", nil)
		bt.edit(ctx, b, cq, bt.opRenewCert(), backKB("menu:main"))
	case cbIOS:
		bt.edit(ctx, b, cq, "⏳ 正在生成 iOS 二维码…", nil)
		bt.edit(ctx, b, cq, bt.opIOS(), backKB("menu:main"))
	case cbRestart:
		bt.edit(ctx, b, cq, fmt.Sprintf("⏳ 正在处理 <b>%s</b>…", htmlEscape(intent.arg)), nil)
		bt.edit(ctx, b, cq, bt.opRestart(intent.arg), backKB("menu:restart"))
	case cbLogs:
		bt.edit(ctx, b, cq, fmt.Sprintf("📜 正在取 <b>%s</b> 日志…", htmlEscape(intent.arg)), nil)
		bt.edit(ctx, b, cq, bt.opLogs(intent.arg), backKB("menu:logs"))
	default:
		bt.edit(ctx, b, cq, "未知操作。", backKB("menu:main"))
	}
}

// --------------------------------------------------------------------------- //
// Controller-backed operations (in-memory; NO HTTP, NO :9443, NO token)
// --------------------------------------------------------------------------- //

// doStatus builds the status card from the in-process Controller stats, the
// live service states (systemctl is-active — read-only), the on-disk gateway
// facts, and the /proc server metrics. Metrics are computed defensively so a
// failure there never breaks the card.
func (bt *Bot) doStatus() string {
	st := bt.ctrl.Stats()
	svc := bt.serviceStates()
	facts := readStatusFacts()
	metrics := safeSystemMetrics()
	var cert *CertStatus
	if cs, ok := bt.ctrl.CertStatus(); ok {
		cert = &cs
	}
	return renderStatus(st, svc, facts, metrics, cert)
}

// safeSystemMetrics wraps systemMetrics so a panic there degrades to a note
// rather than taking down the status render.
func safeSystemMetrics() (card string) {
	defer func() {
		if r := recover(); r != nil {
			card = fmt.Sprintf("（服务器指标获取失败：%v）", r)
		}
	}()
	return systemMetrics()
}

// doUpstreams renders a READ-ONLY view of the live china/trust upstream groups
// (the specs the groups were built from). Editing upstreams from Telegram would
// mean typing whole resolver lists into a chat box — error-prone and easy to
// self-lock the sole resolver — so mutation stays in the web console; the bot
// surfaces visibility, which is the operational need (the status card only shows
// per-group ok/err counts, not WHICH resolvers are configured).
func (bt *Bot) doUpstreams() string {
	up := bt.ctrl.GetUpstreams()
	var b strings.Builder
	b.WriteString("🌐 <b>上游 DNS</b>\n")
	b.WriteString("\n<b>境内组 (china)</b> · 顺序查询取首个成功\n")
	b.WriteString(renderUpstreamList(up.China))
	b.WriteString("\n<b>境外组 (trust)</b> · 顺序查询取首个成功\n")
	b.WriteString(renderUpstreamList(up.Trust))
	b.WriteString("\n<i>编辑上游请在 Web 控制台「设置 → 上游 DNS」进行。</i>")
	return b.String()
}

// renderUpstreamList formats a list of upstream specs as an HTML block, one per
// line (or a placeholder when empty). pre() HTML-escapes the content.
func renderUpstreamList(specs []string) string {
	if len(specs) == 0 {
		return pre("（未配置）")
	}
	return pre(strings.Join(specs, "\n"))
}

// NOTE (UP-1 Task D3/D4): doListDomains/applyDomainOp/doUpdateLists (the
// bot's "🎯 代理域名" GFW-domain view+edit and "🔄 更新订阅" quick actions)
// were REMOVED here — they called Controller.ListAllRules/AddRule/
// RemoveRule/Update, all absorbed by the unified policy-rule model and
// managed exclusively via the web console's /api/policy/* surface now.

// doReload rebuilds the rule sets from disk via the Controller.
func (bt *Bot) doReload(ctx context.Context) string {
	if err := bt.ctrl.Reload(); err != nil {
		return "❌ <b>重载失败</b>\n" + pre(err.Error())
	}
	return "✅ <b>规则已重载</b>（已从磁盘重建并原子切换）。"
}

// --------------------------------------------------------------------------- //
// Service state (read-only; systemctl is-active)
// --------------------------------------------------------------------------- //

// serviceStates returns each data-path service's systemctl state (e.g.
// "active"/"failed"/"inactive"), or "unknown" when systemctl is unavailable
// (e.g. the Windows dev box). Read-only. It reuses bt.serviceActive — the same
// injectable, timeout-bounded run seam every other bot op uses — so the status
// card is testable and can't block indefinitely on a hung systemctl (the old
// package-level serviceState called exec.Command directly, with neither).
func (bt *Bot) serviceStates() map[string]string {
	out := make(map[string]string, len(botServices))
	for _, s := range botServices {
		out[s] = bt.serviceActive(s)
	}
	return out
}

// htmlEscape is a tiny wrapper so bot.go can HTML-escape without importing
// html directly alongside the render helpers.
func htmlEscape(s string) string { return html.EscapeString(s) }
