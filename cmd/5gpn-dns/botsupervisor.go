package main

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"
)

// botRunner is the subset of *Bot the supervisor drives: Run blocks until ctx is
// cancelled. An interface so the supervisor is unit-testable without a live
// Telegram connection (a fake runner can be injected via botFactory).
type botRunner interface {
	Run(ctx context.Context)
}

// botFactory constructs a botRunner from a token/admins-overridden Config, doing
// whatever validation the real bot does (NewBot performs a getMe round-trip, so
// an invalid token surfaces here as an error). Returns (nil, nil) when the token
// is empty (bot disabled). Defaults to newBotRunner; tests inject a fake.
type botFactory func(cfg Config, ctrl *Controller) (botRunner, error)

// newBotRunner is the production botFactory: it builds the real in-process bot.
func newBotRunner(cfg Config, ctrl *Controller) (botRunner, error) {
	b, err := NewBot(cfg, ctrl)
	if err != nil {
		return nil, err
	}
	if b == nil {
		// Empty token → NewBot returns (nil, nil): bot disabled, not an error.
		return nil, nil
	}
	return b, nil
}

// botSupervisor owns the Telegram bot's lifecycle so its token + admin set can be
// hot-reloaded from the web console (PUT /api/tgbot) without restarting the whole
// daemon. The running bot lives in a CHILD of the daemon context; a config change
// cancels that child (stopping the old long-poll goroutine) and launches a fresh
// bot. Daemon shutdown cancels the parent, which cascades to the bot.
//
// It satisfies the Controller's tgbotManager interface (View + Apply).
type botSupervisor struct {
	parent  context.Context
	baseCfg Config // TGBotToken/TGBotAdmins are overridden per launch
	ctrl    *Controller
	file    string // tgbot.json persist target ("" disables persistence)
	factory botFactory

	mu      sync.Mutex
	token   string
	admins  []int64
	cancel  context.CancelFunc // cancels the running bot; nil when stopped
	running bool
}

// newBotSupervisor builds a supervisor seeded with the startup config's token +
// admins (already tgbot.json-overridden by main). The bot is not started until
// Start is called.
func newBotSupervisor(parent context.Context, cfg Config, ctrl *Controller) *botSupervisor {
	return &botSupervisor{
		parent:  parent,
		baseCfg: cfg,
		ctrl:    ctrl,
		file:    cfg.TGBotFile,
		factory: newBotRunner,
		token:   cfg.TGBotToken,
		admins:  adminIDsFromSet(cfg.TGBotAdmins),
	}
}

// Start launches the bot with the supervisor's current (startup) config. A no-op
// with an empty token. The build (getMe round-trip) + launch happen in a
// GOROUTINE so a slow/unreachable Telegram can never block the daemon's startup
// or DNS serving — matching the pre-supervisor behaviour. (The API-driven Apply
// path deliberately stays synchronous so a bad token gives the operator immediate
// feedback.) Errors are logged, never fatal — the bot is a best-effort control
// plane, not part of the DNS data path.
func (s *botSupervisor) Start() {
	s.mu.Lock()
	token := s.token
	admins := append([]int64(nil), s.admins...)
	s.mu.Unlock()

	if token == "" {
		log.Printf("telegram bot disabled: TGBOT_TOKEN not set (configure it in the web console → Settings)")
		return
	}
	go func() {
		if err := s.launch(token, admins); err != nil {
			log.Printf("telegram bot: %v — bot disabled (fix the token in the web console)", err)
		}
	}()
}

// launch builds a bot for (token, admins) and starts it, cancelling any previous
// one. The build (getMe validation) happens OUTSIDE the lock so a slow/unreachable
// Telegram can't block a concurrent View(). On a build error the CURRENT bot is
// left running untouched (the caller — Apply — turns it into an HTTP error).
func (s *botSupervisor) launch(token string, admins []int64) error {
	var runner botRunner
	if token != "" {
		cfg := s.baseCfg
		cfg.TGBotToken = token
		cfg.TGBotAdmins = adminSetFromIDs(admins)
		r, err := s.factory(cfg, s.ctrl)
		if err != nil {
			return err
		}
		runner = r // may still be nil if the factory treats this as disabled
	}

	s.mu.Lock()
	if s.cancel != nil {
		s.cancel() // stop the old long-poll before starting the new one
		s.cancel = nil
	}
	s.token, s.admins = token, admins
	s.running = false
	if runner != nil {
		botCtx, cancel := context.WithCancel(s.parent)
		s.cancel = cancel
		s.running = true
		go runner.Run(botCtx)
	}
	s.mu.Unlock()

	if runner != nil {
		log.Printf("telegram bot enabled (%d admin(s))", len(admins))
	} else {
		log.Printf("telegram bot disabled")
	}
	return nil
}

// View returns the current bot config for GET /api/tgbot — NEVER the raw token.
func (s *botSupervisor) View() TGBotView {
	s.mu.Lock()
	defer s.mu.Unlock()
	return TGBotView{
		AdminIDs: append([]int64(nil), s.admins...),
		TokenSet: s.token != "",
		Running:  s.running,
	}
}

// Apply hot-reloads the bot from PUT /api/tgbot.
//
//   - tokenPtr == nil  → keep the current token (edit the admin set only).
//   - tokenPtr != nil  → set that token; an empty string DISABLES the bot.
//
// A bad token (getMe fails) returns an error and leaves the running bot
// untouched, so a typo can't take the bot offline. On success the new config is
// persisted to tgbot.json (applied-live even if the persist write fails, matching
// the upstreams/ecs behaviour — the operator asked for the change).
func (s *botSupervisor) Apply(tokenPtr *string, admins []int64) error {
	admins = normalizeAdminIDs(admins)

	s.mu.Lock()
	token := s.token
	s.mu.Unlock()
	if tokenPtr != nil {
		token = strings.TrimSpace(*tokenPtr)
	}

	if err := s.launch(token, admins); err != nil {
		return fmt.Errorf("telegram bot: %w", err)
	}
	if err := SaveTGBot(s.file, TGBotConfig{Token: token, Admins: admins}); err != nil {
		return fmt.Errorf("applied live, but persisting to %s failed (reverts to dns.env on restart): %w", s.file, err)
	}
	return nil
}
