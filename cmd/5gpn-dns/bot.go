package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"html"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

// botServices are the primary DNS and forwarding services the compact bot
// reports and tails. The optional interception sidecar remains a Web-console
// and systemd surface so the bot does not gain CA-adjacent operations.
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
// bearer token.
type Bot struct {
	tg                *bot.Bot
	ctrl              *Controller
	admins            map[int64]bool
	adminsMu          sync.RWMutex
	healthMu          sync.RWMutex
	healthFn          func(error)
	actionOnce        sync.Once
	actions           *botActionGuard
	extensionOnce     sync.Once
	extensionState    *botExtensionStateStore
	extensionReviewMu sync.Mutex
	extensionOpsOnce  sync.Once
	extensionOps      *botExtensionOperationGuard

	// pending is the per-chat conversational state machine: chat_id -> action.
	// The current "diagnose" action consumes the next domain message for
	// ResolveTest; a slash command or /cancel clears it. Guarded by mu.
	mu      sync.Mutex
	pending map[int64]string

	// runFn is the injectable shelling-out seam for the T3 OS-op handlers
	// (restart/logs/certificate renewal/QR). A nil runFn means "use the real run"
	// (via Bot.run); tests set it to a stub so no real privileged command is
	// invoked. Gateway/domain facts are read from disk
	// (readStatusFacts / iosHost).
	runFn      func(argv []string, timeout time.Duration) (bool, string)
	journalDir string // test-only override; empty uses /run/5gpn-journal
}

// NewBot constructs the in-process Telegram bot. An empty cfg.TGBotToken means
// the bot is disabled: NewBot returns (nil, nil) — not an error — and the
// caller (T5, main) simply skips Run. With a token it builds the *bot.Bot with
// an admin-gate middleware, a default handler, and the /id command registered.
//
// Note: bot.New performs a getMe round-trip to Telegram to validate the token,
// so NewBot only reaches out to the network when a token is configured.
func NewBot(cfg Config, ctrl *Controller) (*Bot, error) {
	return newBotWithOptions(cfg, ctrl)
}

// newBotWithOptions is the testable constructor. Production uses NewBot;
// tests append WithServerURL to exercise real Telegram request/response wiring
// against an httptest server without contacting Telegram.
func newBotWithOptions(cfg Config, ctrl *Controller, extra ...bot.Option) (*Bot, error) {
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
		bot.WithMessageTextHandler("/help", bot.MatchTypePrefix, bt.handleHelp),
		bot.WithMessageTextHandler("/status", bot.MatchTypePrefix, bt.handleStatus),
		bot.WithMessageTextHandler("/lookup", bot.MatchTypePrefix, bt.handleLookup),
		bot.WithMessageTextHandler("/cancel", bot.MatchTypeExact, bt.handleCancel),
		// A single callback handler routes every button press; the empty
		// prefix matches all callback_data, and parseCallback classifies it.
		bot.WithCallbackQueryDataHandler("", bot.MatchTypePrefix, bt.handleCallback),
		// Telegram retains a token's previous allowed_updates value when the field
		// is omitted. Always declare both update types this implementation needs.
		bot.WithAllowedUpdates(bot.AllowedUpdates{"message", "callback_query"}),
		bot.WithErrorsHandler(func(err error) {
			log.Printf("bot: Telegram polling error: %v", err)
			bt.reportHealth(err)
		}),
	}
	client, err := newTGBotHTTPClient(cfg.TGBotProxyURL)
	if err != nil {
		return nil, fmt.Errorf("bot: proxy: %w", err)
	}
	client.Transport = &botHealthTransport{base: client.Transport, report: bt.reportHealth}
	opts = append(opts, bot.WithHTTPClient(60*time.Second, client))
	opts = append(opts, extra...)

	tg, err := bot.New(cfg.TGBotToken, opts...)
	if err != nil {
		return nil, fmt.Errorf("bot: %w", err)
	}
	// This project deliberately uses long polling and exposes no Telegram
	// webhook ingress. Taking ownership of a configured token therefore removes
	// a pre-existing webhook without dropping queued updates; otherwise getMe
	// succeeds but getUpdates loops forever with HTTP 409 while the UI claims the
	// bot is running.
	preflightCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	webhook, err := tg.GetWebhookInfo(preflightCtx)
	if err != nil {
		return nil, fmt.Errorf("bot: getWebhookInfo: %w", err)
	}
	if webhook.URL != "" {
		deleted, err := tg.DeleteWebhook(preflightCtx, &bot.DeleteWebhookParams{DropPendingUpdates: false})
		if err != nil {
			return nil, fmt.Errorf("bot: deleteWebhook: %w", err)
		}
		if !deleted {
			return nil, errors.New("bot: deleteWebhook: Telegram did not confirm deletion")
		}
		log.Printf("bot: removed an existing Telegram webhook; long polling now owns the token")
	}
	bt.tg = tg
	return bt, nil
}

// newTGBotHTTPClient returns a client whose proxy override is scoped to
// Telegram only. With an empty override it explicitly disables proxying so
// ambient HTTP_PROXY/HTTPS_PROXY variables cannot become undeclared config.
func newTGBotHTTPClient(proxyRaw string) (*http.Client, error) {
	transport, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return nil, fmt.Errorf("default HTTP transport has unexpected type %T", http.DefaultTransport)
	}
	tr := transport.Clone()
	tr.Proxy = nil
	if proxyRaw != "" {
		proxyURL, err := url.Parse(proxyRaw)
		if err != nil {
			return nil, err
		}
		if err := validateTGBotProxyURL(proxyRaw); err != nil {
			return nil, err
		}
		tr.Proxy = http.ProxyURL(proxyURL)
	}
	return &http.Client{Transport: tr, Timeout: 70 * time.Second}, nil
}

type botHealthTransport struct {
	base   http.RoundTripper
	report func(error)
}

func (t *botHealthTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(req)
	if strings.HasSuffix(req.URL.Path, "/getUpdates") {
		switch {
		case err != nil:
			t.report(err)
		case resp == nil:
			t.report(errors.New("Telegram getUpdates returned no response"))
		case resp.StatusCode < 200 || resp.StatusCode >= 300:
			t.report(fmt.Errorf("Telegram getUpdates HTTP %d", resp.StatusCode))
		default:
			t.report(nil)
		}
	}
	return resp, err
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
	bt.reportHealth(nil)
	bt.tg.Start(ctx)
}

// SetHealthReporter lets the supervisor observe long-poll health without
// coupling Bot to its lifecycle implementation. A nil report means the most
// recent Bot API/poll operation succeeded.
func (bt *Bot) SetHealthReporter(fn func(error)) {
	bt.healthMu.Lock()
	bt.healthFn = fn
	bt.healthMu.Unlock()
}

func (bt *Bot) reportHealth(err error) {
	bt.healthMu.RLock()
	fn := bt.healthFn
	bt.healthMu.RUnlock()
	if fn != nil {
		fn(err)
	}
}

// setCommands publishes the quick-command menu (the Telegram "Menu" button /
// typing "/"). Best-effort: any error is logged, never fatal.
func (bt *Bot) setCommands(ctx context.Context) {
	// The default scope exposes only the bootstrap-safe /id command. Full
	// operator commands are scoped to each configured admin's private chat.
	if _, err := bt.tg.SetMyCommands(ctx, &bot.SetMyCommandsParams{Commands: idBotCommand}); err != nil {
		log.Printf("bot: setMyCommands(default): %v", err)
	}
	for _, adminID := range bt.adminIDs() {
		bt.setAdminCommands(ctx, adminID)
	}
}

func (bt *Bot) setAdminCommands(ctx context.Context, adminID int64) {
	if _, err := bt.tg.SetMyCommands(ctx, &bot.SetMyCommandsParams{
		Commands: botCommands,
		Scope:    &models.BotCommandScopeChat{ChatID: adminID},
	}); err != nil {
		log.Printf("bot: setMyCommands(admin=%d): %v", adminID, err)
	}
}

// isAdmin reports whether uid is an authorized admin. A nil/empty admin set
// denies everyone (defensive: an unset TGBOT_ADMINS locks the bot down rather
// than opening it up). Factored out so the gate decision is unit-testable
// without a live Telegram connection.
func (bt *Bot) isAdmin(uid int64) bool {
	bt.adminsMu.RLock()
	defer bt.adminsMu.RUnlock()
	return bt.admins[uid]
}

func (bt *Bot) adminIDs() []int64 {
	bt.adminsMu.RLock()
	defer bt.adminsMu.RUnlock()
	return adminIDsFromSet(bt.admins)
}

// ReplaceAdmins updates authorization without rebuilding the Telegram client
// or performing a network-dependent getMe. It is used by the supervisor so an
// emergency administrator revocation remains effective even while Telegram is
// temporarily unreachable.
func (bt *Bot) ReplaceAdmins(ids []int64) {
	next := adminSetFromIDs(ids)
	bt.adminsMu.Lock()
	previous := adminIDsFromSet(bt.admins)
	bt.admins = next
	bt.adminsMu.Unlock()
	for _, oldID := range previous {
		if next[oldID] {
			continue
		}
		bt.actionGuard().RevokeAdmin(oldID)
		_, cutoff := bt.extensionStateStore().CancelOwnerWithGeneration(oldID, oldID)
		bt.cancelBotExtensionOperationThrough(oldID, oldID, cutoff)
	}

	if bt.tg == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		for _, oldID := range previous {
			if next[oldID] {
				continue
			}
			if _, err := bt.tg.DeleteMyCommands(ctx, &bot.DeleteMyCommandsParams{
				Scope: &models.BotCommandScopeChat{ChatID: oldID},
			}); err != nil {
				log.Printf("bot: deleteMyCommands(admin=%d): %v", oldID, err)
			}
		}
		for _, adminID := range adminIDsFromSet(next) {
			bt.setAdminCommands(ctx, adminID)
		}
	}()
}

// NotifyAdmins sends one protected private message to every configured admin.
// It is used only by the opt-in transition alert monitor; individual delivery
// failures are joined so the monitor can retry a state that nobody received.
func (bt *Bot) NotifyAdmins(ctx context.Context, text string) error {
	ids := bt.adminIDs()
	if len(ids) == 0 {
		return errors.New("no Telegram administrators configured")
	}
	var errs []error
	delivered := 0
	for _, adminID := range ids {
		if _, err := bt.tg.SendMessage(ctx, &bot.SendMessageParams{
			ChatID:         adminID,
			Text:           text,
			ParseMode:      models.ParseModeHTML,
			ProtectContent: true,
		}); err != nil {
			errs = append(errs, fmt.Errorf("admin %d: %w", adminID, err))
		} else {
			delivered++
		}
	}
	if delivered > 0 {
		for _, err := range errs {
			log.Printf("bot: partial alert delivery: %v", err)
		}
		return nil
	}
	return errors.Join(errs...)
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
		if !isPrivateUpdate(update) {
			refuseNonPrivate(ctx, b, update)
			return
		}
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

func isPrivateUpdate(update *models.Update) bool {
	if update == nil {
		return false
	}
	if update.Message != nil {
		return update.Message.Chat.Type == models.ChatTypePrivate
	}
	if update.CallbackQuery == nil {
		return false
	}
	switch update.CallbackQuery.Message.Type {
	case models.MaybeInaccessibleMessageTypeMessage:
		m := update.CallbackQuery.Message.Message
		return m != nil && m.Chat.Type == models.ChatTypePrivate
	case models.MaybeInaccessibleMessageTypeInaccessibleMessage:
		m := update.CallbackQuery.Message.InaccessibleMessage
		return m != nil && m.Chat.Type == models.ChatTypePrivate
	default:
		return false
	}
}

func refuseNonPrivate(ctx context.Context, b *bot.Bot, update *models.Update) {
	switch {
	case update != nil && update.CallbackQuery != nil:
		_, _ = b.AnswerCallbackQuery(ctx, &bot.AnswerCallbackQueryParams{
			CallbackQueryID: update.CallbackQuery.ID,
			Text:            "⛔ 仅允许管理员私聊操作",
			ShowAlert:       true,
		})
	case update != nil && update.Message != nil:
		_, _ = b.SendMessage(ctx, &bot.SendMessageParams{
			ChatID: update.Message.Chat.ID,
			Text:   "⛔ 为避免泄露网关状态和日志，请私聊机器人。",
		})
	}
}

// handleID replies with the sender's Telegram numeric id. Reachable by anyone
// (the gate allow-lists /id) so a would-be admin can find the id to add to
// TGBOT_ADMINS.
func (bt *Bot) handleID(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil || update.Message.From == nil {
		return
	}
	if bt.isAdmin(update.Message.From.ID) && update.Message.Chat.Type == models.ChatTypePrivate {
		if bt.handleExtensionInput(ctx, b, update, update.Message.From.ID) {
			return
		}
		bt.cancelExtensionState(update)
	}
	if _, err := b.SendMessage(ctx, &bot.SendMessageParams{
		ChatID:         update.Message.Chat.ID,
		Text:           fmt.Sprintf("你的 Telegram 数字 ID：<code>%d</code>", update.Message.From.ID),
		ParseMode:      models.ParseModeHTML,
		ProtectContent: true,
	}); err != nil {
		log.Printf("bot: send /id response: %v", err)
	}
	if bt.isAdmin(update.Message.From.ID) {
		bt.setAdminCommands(ctx, update.Message.From.ID)
	}
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

func (bt *Bot) actionGuard() *botActionGuard {
	bt.actionOnce.Do(func() {
		bt.actions = newBotActionGuard()
	})
	return bt.actions
}

func (bt *Bot) extensionStateStore() *botExtensionStateStore {
	bt.extensionOnce.Do(func() {
		if bt.extensionState == nil {
			bt.extensionState = newBotExtensionStateStore()
		}
	})
	return bt.extensionState
}

func (bt *Bot) cancelExtensionState(update *models.Update) bool {
	if update == nil || update.Message == nil {
		return false
	}
	uid, ok := senderID(update)
	if !ok {
		return false
	}
	removed, cutoff := bt.extensionStateStore().CancelOwnerWithGeneration(uid, update.Message.Chat.ID)
	cancelled := bt.cancelBotExtensionOperationThrough(uid, update.Message.Chat.ID, cutoff)
	return removed || cancelled
}

// --------------------------------------------------------------------------- //
// Send / edit helpers
// --------------------------------------------------------------------------- //

// send delivers an HTML message, paginating anything over Telegram's limit and
// attaching kb (if non-nil) to the final chunk. Mirrors tgbot.py's send().
func (bt *Bot) send(ctx context.Context, b *bot.Bot, chatID int64, text string, kb *models.InlineKeyboardMarkup) {
	chunks := chunkText(text, 3900)
	bt.sendChunks(ctx, b, chatID, chunks, kb)
}

func (bt *Bot) sendChunks(ctx context.Context, b *bot.Bot, chatID int64, chunks []string, kb *models.InlineKeyboardMarkup) {
	last := len(chunks) - 1
	for i, chunk := range chunks {
		params := &bot.SendMessageParams{
			ChatID:             chatID,
			Text:               chunk,
			ParseMode:          models.ParseModeHTML,
			LinkPreviewOptions: disabledPreview(),
			ProtectContent:     true,
		}
		if kb != nil && i == last {
			params.ReplyMarkup = kb
		}
		if _, err := b.SendMessage(ctx, params); err != nil {
			log.Printf("bot: sendMessage chat=%d chunk=%d/%d: %v", chatID, i+1, len(chunks), err)
		}
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
	chunks := chunkText(text, 3900)
	params := &bot.EditMessageTextParams{
		ChatID:             chatID,
		MessageID:          msgID,
		Text:               chunks[0],
		ParseMode:          models.ParseModeHTML,
		LinkPreviewOptions: disabledPreview(),
	}
	if len(chunks) == 1 && kb != nil {
		params.ReplyMarkup = kb
	} else {
		// Explicitly remove the old keyboard while a long result is paginated or a
		// privileged operation is in progress. Omitting reply_markup can preserve
		// stale buttons and permit duplicate execution.
		params.ReplyMarkup = &models.InlineKeyboardMarkup{InlineKeyboard: [][]models.InlineKeyboardButton{}}
	}
	if _, err := b.EditMessageText(ctx, params); err != nil {
		// "message is not modified" is benign; otherwise fall back to a fresh
		// message so the operator still sees the result.
		if !strings.Contains(err.Error(), "not modified") {
			log.Printf("bot: editMessageText chat=%d message=%d: %v", chatID, msgID, err)
			bt.sendChunks(ctx, b, chatID, chunks, kb)
			return
		}
	}
	if len(chunks) > 1 {
		bt.sendChunks(ctx, b, chatID, chunks[1:], kb)
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

// handleMenu opens the main menu (for /start and /menu). While an extension
// value is pending, command-shaped text is data; /cancel is the explicit exit.
func (bt *Bot) handleMenu(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	uid, _ := senderID(update)
	if bt.handleExtensionInput(ctx, b, update, uid) {
		return
	}
	bt.clearPending(update.Message.Chat.ID)
	bt.cancelExtensionState(update)
	bt.send(ctx, b, update.Message.Chat.ID, "<b>5gpn 控制台</b>\n选择一个操作：", mainMenu())
}

func (bt *Bot) handleHelp(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	uid, _ := senderID(update)
	if bt.handleExtensionInput(ctx, b, update, uid) {
		return
	}
	bt.clearPending(update.Message.Chat.ID)
	bt.cancelExtensionState(update)
	bt.send(ctx, b, update.Message.Chat.ID,
		"<b>5gpn Telegram 运维助手</b>\n\n"+
			"• 仅允许已配置管理员私聊操作。\n"+
			"• <code>/lookup example.com</code> 查看规则判定与逐上游结果。\n"+
			"• 重启 Mihomo 和续证需二次确认，并且同类操作只能同时运行一个。\n"+
			"• 插件市场、安装卸载、启停、参数、位置、出口、排序和更新均可在菜单中管理。\n"+
			"• 每个写操作都会先显示完整影响，并要求短期一次性确认；联网插件会逐项列出 origin 风险。\n"+
			"• 复杂策略、上游编辑和 Mihomo YAML 请使用 Web 控制台。\n"+
			"• <code>/cancel</code> 取消当前等待的输入或确认，不会中断已经开始执行的操作。",
		mainMenu())
}

// handleStatus renders the status card (for /status).
func (bt *Bot) handleStatus(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	uid, _ := senderID(update)
	if bt.handleExtensionInput(ctx, b, update, uid) {
		return
	}
	bt.clearPending(update.Message.Chat.ID)
	bt.cancelExtensionState(update)
	bt.send(ctx, b, update.Message.Chat.ID, bt.doStatus(), statusKB())
}

func (bt *Bot) handleLookup(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	uid, _ := senderID(update)
	if bt.handleExtensionInput(ctx, b, update, uid) {
		return
	}
	chatID := update.Message.Chat.ID
	bt.cancelExtensionState(update)
	parts := strings.Fields(update.Message.Text)
	if len(parts) < 2 {
		bt.setPending(chatID, "diagnose")
		bt.send(ctx, b, chatID, "🧪 请发送要诊断的域名，例如 <code>example.com</code>。\n发送 /cancel 取消输入。", backKB("menu:main"))
		return
	}
	bt.clearPending(chatID)
	bt.sendResolveTest(ctx, b, chatID, strings.TrimSpace(parts[1]))
}

func (bt *Bot) sendResolveTest(ctx context.Context, b *bot.Bot, chatID int64, raw string) {
	name := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), ".")
	if !isValidDomain(name) {
		bt.setPending(chatID, "diagnose")
		bt.send(ctx, b, chatID, "❌ 域名格式无效，请重新输入（例如 <code>example.com</code>），或发送 /cancel。", backKB("menu:main"))
		return
	}
	bt.clearPending(chatID)
	diagCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	result := bt.ctrl.ResolveTest(diagCtx, name)
	bt.send(ctx, b, chatID, renderResolveTest(result), diagnoseKB())
}

// handleCancel clears any pending flow and reopens the menu (for /cancel).
func (bt *Bot) handleCancel(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	chatID := update.Message.Chat.ID
	_, pending := bt.getPending(chatID)
	bt.clearPending(chatID)
	extensionPending := bt.cancelExtensionState(update)
	if pending || extensionPending {
		bt.send(ctx, b, chatID, "已取消当前待输入内容或确认，未执行任何变更。", mainMenu())
		return
	}
	bt.send(ctx, b, chatID, "当前没有待取消的输入。", mainMenu())
}

// defaultHandler catches messages with no specific command handler. When a
// chat is waiting for DNS diagnosis, the next non-slash text is the domain;
// unknown slash commands clear the flow and plain text otherwise reopens the
// menu. Panics are contained so one malformed update cannot affect DNS.
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

	uid, _ := senderID(update)
	if bt.handleExtensionInput(ctx, b, update, uid) {
		return
	}

	// Unknown slash commands cancel only the DNS text prompt. Extension input
	// is checked first because a valid typed text value or local manifest may
	// legitimately begin with '/'; /cancel remains the explicit escape hatch.
	if strings.HasPrefix(text, "/") {
		bt.clearPending(chatID)
		bt.send(ctx, b, chatID, "未知命令。发送 /menu 打开操作面板。", nil)
		return
	}

	if action, ok := bt.getPending(chatID); ok && action == "diagnose" {
		bt.sendResolveTest(ctx, b, chatID, text)
		return
	}
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
	case cbConfirmAction:
		return intent.arg, true
	case cbLogs:
		return "logs:" + intent.arg, true // privileged journal exfil to Telegram
	case cbIOSPhoto:
		return "ios-profile-photo", true
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

	uid, _ := senderID(update) // adminGate already rejected an absent/unauthorized sender.
	if intent.kind != cbExtension {
		_, cutoff := bt.extensionStateStore().CancelOwnerWithGeneration(uid, chatID)
		bt.cancelBotExtensionOperationThrough(uid, chatID, cutoff)
	}

	switch intent.kind {
	case cbMenuMain:
		bt.clearPending(chatID)
		bt.edit(ctx, b, cq, "选择一个操作：", mainMenu())
	case cbStatus:
		bt.edit(ctx, b, cq, bt.doStatus(), statusKB())
	case cbDiagnose:
		bt.setPending(chatID, "diagnose")
		bt.edit(ctx, b, cq, "🧪 请发送要诊断的域名，例如 <code>example.com</code>。\n发送 /cancel 取消输入。", backKB("menu:main"))
	case cbUpstreams:
		bt.edit(ctx, b, cq, bt.doUpstreams(), backKB("menu:main"))
	case cbReload:
		auditBot("reload", uid, "invoked")
		bt.edit(ctx, b, cq, "⏳ 正在重载 DNS 规则…", nil)
		result := bt.reload5gpnDNSResult()
		auditBotOutcome("reload", uid, result.OK)
		bt.edit(ctx, b, cq, result.HTML(), backKB("menu:maintenance"))
	case cbMenuMaintenance:
		bt.edit(ctx, b, cq, "维护操作：", maintenanceMenu())
	case cbMenuLogs:
		bt.edit(ctx, b, cq, "选择要查看日志的服务：", logsMenu())
	case cbMenuIOS:
		bt.edit(ctx, b, cq, bt.opIOSResult().HTML(), iosMenu())
	case cbExtension:
		bt.handleExtensionCallback(ctx, b, cq, uid, chatID, intent.arg)
	case cbIOSPhoto:
		auditBot("ios-profile-photo", uid, "invoked")
		ok := bt.sendIOSPhoto(ctx, b, chatID)
		auditBotOutcome("ios-profile-photo", uid, ok)
		message := bt.opIOSResult().HTML()
		if !ok {
			message += "\n⚠️ 二维码图片生成或发送失败，请使用“安装描述文件”链接。"
		}
		bt.edit(ctx, b, cq, message, iosMenu())
	case cbRequestConfirm:
		action := botPrivilegedAction(intent.arg)
		nonce, expires, err := bt.actionGuard().Issue(action, uid, chatID)
		if err != nil {
			bt.edit(ctx, b, cq, "❌ 无法创建确认请求："+pre(err.Error()), backKB("menu:maintenance"))
			return
		}
		bt.edit(ctx, b, cq, confirmationPrompt(action, expires), confirmationMenu(action, nonce))
	case cbConfirmAction:
		bt.executeConfirmedAction(ctx, b, cq, botPrivilegedAction(intent.arg), intent.nonce, uid, chatID)
	case cbCancelAction:
		if bt.actionGuard().Cancel(intent.nonce, uid, chatID) {
			bt.edit(ctx, b, cq, "已取消，未执行任何维护操作。", maintenanceMenu())
		} else {
			bt.edit(ctx, b, cq, "确认请求已失效或不属于当前管理员。", maintenanceMenu())
		}
	case cbLogs:
		auditBot("logs:"+intent.arg, uid, "invoked")
		bt.edit(ctx, b, cq, fmt.Sprintf("📜 正在取 <b>%s</b> 日志…", htmlEscape(intent.arg)), nil)
		result := bt.opLogsResult(intent.arg)
		auditBotOutcome("logs:"+intent.arg, uid, result.OK)
		if result.OK && utf8.RuneCountInString(result.Detail) > preContentLimit && bt.sendLogDocument(ctx, b, chatID, intent.arg, result.Detail) {
			bt.edit(ctx, b, cq, result.HTMLSummary+"\n✅ 完整日志已作为受保护的文本文件发送。", logsResultKB(intent.arg))
		} else {
			bt.edit(ctx, b, cq, result.HTML(), logsResultKB(intent.arg))
		}
	default:
		bt.edit(ctx, b, cq, "未知操作。", backKB("menu:main"))
	}
}

func confirmationPrompt(action botPrivilegedAction, expires time.Time) string {
	label := "未知操作"
	impact := ""
	switch action {
	case botActionRestartMihomo:
		label = "重启 Mihomo"
		impact = "转发中的新连接可能短暂中断。"
	case botActionRenewCert:
		label = "检查并续期 5gpn 证书"
		impact = "仅针对当前 DNS_BASE_DOMAIN 的 certbot lineage。"
	}
	return fmt.Sprintf(
		"⚠️ <b>确认%s？</b>\n%s\n\n确认仅可使用一次，并将于 <code>%s</code> 过期。",
		html.EscapeString(label), html.EscapeString(impact), expires.Format("15:04:05"),
	)
}

func (bt *Bot) executeConfirmedAction(
	ctx context.Context,
	b *bot.Bot,
	cq *models.CallbackQuery,
	action botPrivilegedAction,
	nonce string,
	adminID, chatID int64,
) {
	guard := bt.actionGuard()
	if !guard.Consume(nonce, action, adminID, chatID) {
		bt.edit(ctx, b, cq, "⚠️ 确认已过期、已使用或不属于当前管理员。", maintenanceMenu())
		return
	}
	if !guard.TryStart(action) {
		bt.edit(ctx, b, cq, "⏳ 同类维护操作正在执行，本次请求未重复启动。", maintenanceMenu())
		return
	}
	defer guard.Finish(action)

	op := string(action)
	auditBot(op, adminID, "invoked")
	bt.edit(ctx, b, cq, "⏳ 正在执行 <b>"+html.EscapeString(op)+"</b>…", nil)
	var result botOperationResult
	switch action {
	case botActionRestartMihomo:
		result = bt.restartMihomoResult()
	case botActionRenewCert:
		result = bt.opRenewCertResult()
	default:
		result = botOperationResult{OK: false, HTMLSummary: "❌ 不支持的维护操作。"}
	}
	auditBotOutcome(op, adminID, result.OK)
	bt.edit(ctx, b, cq, result.HTML(), maintenanceMenu())
}

func (bt *Bot) sendIOSPhoto(ctx context.Context, b *bot.Bot, chatID int64) bool {
	png, profileURL, err := iosQRCodePNG()
	if err != nil {
		log.Printf("bot: generate iOS QR PNG: %v", err)
		return false
	}
	_, err = b.SendPhoto(ctx, &bot.SendPhotoParams{
		ChatID: chatID,
		Photo: &models.InputFileUpload{
			Filename: "5gpn-ios-profile.png",
			Data:     bytes.NewReader(png),
		},
		Caption:        "📱 <b>iOS DoT 描述文件</b>\n<code>" + html.EscapeString(profileURL) + "</code>",
		ParseMode:      models.ParseModeHTML,
		ProtectContent: true,
		ReplyMarkup:    iosMenu(),
	})
	if err != nil {
		log.Printf("bot: sendPhoto iOS profile chat=%d: %v", chatID, err)
		return false
	}
	return true
}

func (bt *Bot) sendLogDocument(ctx context.Context, b *bot.Bot, chatID int64, service, content string) bool {
	if !isKnownService(service) {
		return false
	}
	_, err := b.SendDocument(ctx, &bot.SendDocumentParams{
		ChatID: chatID,
		Document: &models.InputFileUpload{
			Filename: service + "-journal.txt",
			Data:     bytes.NewReader([]byte(cleanTelegramText(content))),
		},
		Caption:        "📜 <b>" + html.EscapeString(service) + "</b> 最近 50 行完整日志",
		ParseMode:      models.ParseModeHTML,
		ProtectContent: true,
	})
	if err != nil {
		log.Printf("bot: sendDocument logs service=%s chat=%d: %v", service, chatID, err)
		return false
	}
	return true
}

// --------------------------------------------------------------------------- //
// Controller-backed operations (in-memory; no HTTP or bearer token)
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
