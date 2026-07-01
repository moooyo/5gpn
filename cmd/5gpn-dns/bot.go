package main

import (
	"context"
	"fmt"
	"log"
	"regexp"
	"strings"

	"github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

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
	// Gateway/domain facts are added in T3.
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
		ctrl:   ctrl,
		admins: cfg.TGBotAdmins,
	}

	opts := []bot.Option{
		bot.WithMiddlewares(bt.adminGate),
		bot.WithDefaultHandler(bt.defaultHandler),
		bot.WithMessageTextHandler("/id", bot.MatchTypeExact, bt.handleID),
	}

	tg, err := bot.New(cfg.TGBotToken, opts...)
	if err != nil {
		return nil, fmt.Errorf("bot: %w", err)
	}
	bt.tg = tg
	return bt, nil
}

// Run starts the long-poll loop, blocking until ctx is cancelled. It recovers
// from any panic so a bot crash never propagates into (or takes down) the host
// process — the bot is a best-effort control plane, not part of the data path.
func (bt *Bot) Run(ctx context.Context) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("bot: recovered from panic: %v", r)
		}
	}()
	bt.tg.Start(ctx)
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

// defaultHandler catches updates with no specific handler. For an admin-gated
// bot skeleton it just acknowledges unknown input; real commands arrive in T2/T3.
func (bt *Bot) defaultHandler(ctx context.Context, b *bot.Bot, update *models.Update) {
	if update.Message == nil {
		return
	}
	_, _ = b.SendMessage(ctx, &bot.SendMessageParams{
		ChatID: update.Message.Chat.ID,
		Text:   "未知命令。发送 /id 查看你的数字 ID。",
	})
}
