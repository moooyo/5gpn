package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	telegram "github.com/go-telegram/bot"
)

const (
	botStateDisabled = "disabled"
	botStateStarting = "starting"
	botStateHealthy  = "healthy"
	botStateDegraded = "degraded"

	defaultBotRetryInitial = time.Second
	defaultBotRetryMax     = time.Minute
)

var errBotConfigSuperseded = errors.New("configuration superseded by a newer update")

// botRunner is the subset of *Bot the supervisor drives: Run blocks until ctx
// is cancelled. An interface keeps lifecycle tests independent of Telegram.
type botRunner interface {
	Run(ctx context.Context)
}

// botAdminUpdater is implemented by runners whose authorization set can be
// atomically replaced while Run is active. *Bot implements this with its own
// lock. Keeping it optional lets small test/alternate runners fall back to a
// rebuild without weakening the botRunner contract.
type botAdminUpdater interface {
	ReplaceAdmins(admins []int64)
}

// botHealthSource lets a runner report long-poll health without ending Run.
// nil means healthy; a non-nil error marks the still-live runner degraded. The
// callback installed by the supervisor is scoped to both config generation and
// runner identity, so a late signal from a replaced bot is ignored.
type botHealthSource interface {
	SetHealthReporter(report func(error))
}

type botAdminNotifier interface {
	NotifyAdmins(ctx context.Context, text string) error
}

// botFactory constructs a botRunner from a token/admins-overridden Config.
// NewBot performs a getMe round-trip, so token or connectivity failures surface
// here. It returns (nil, nil) only when the bot is disabled.
type botFactory func(cfg Config, ctrl *Controller) (botRunner, error)

func newBotRunner(cfg Config, ctrl *Controller) (botRunner, error) {
	b, err := NewBot(cfg, ctrl)
	if err != nil {
		return nil, err
	}
	if b == nil {
		return nil, nil
	}
	return b, nil
}

// botSupervisor owns the Telegram bot lifecycle. There are two monotonic
// counters with deliberately different meanings:
//
//   - requestSeq orders concurrent Apply calls. A slow, older getMe result may
//     never overwrite a newer request.
//   - generation identifies the committed configuration. Startup retry loops
//     capture it and become inert as soon as a new configuration commits.
//
// Factory/network work happens without mu or transitionMu held. transitionMu
// only serializes short request-number allocation and the persist/live commit,
// which also prevents out-of-order tgbot.json writes.
type botSupervisor struct {
	parent  context.Context
	baseCfg Config
	ctrl    *Controller
	file    string
	factory botFactory

	retryInitial time.Duration
	retryMax     time.Duration

	transitionMu sync.Mutex
	mu           sync.Mutex

	token      string
	admins     []int64
	generation uint64
	requestSeq uint64

	runner  botRunner
	cancel  context.CancelFunc
	runDone chan struct{}
	running bool

	retryCancel context.CancelFunc
	retrySeq    uint64

	state     string
	lastError string
}

func newBotSupervisor(parent context.Context, cfg Config, ctrl *Controller) *botSupervisor {
	state := botStateStarting
	if strings.TrimSpace(cfg.TGBotToken) == "" {
		state = botStateDisabled
	}
	return &botSupervisor{
		parent:       parent,
		baseCfg:      cfg,
		ctrl:         ctrl,
		file:         cfg.TGBotFile,
		factory:      newBotRunner,
		retryInitial: defaultBotRetryInitial,
		retryMax:     defaultBotRetryMax,
		token:        strings.TrimSpace(cfg.TGBotToken),
		admins:       adminIDsFromSet(cfg.TGBotAdmins),
		generation:   1,
		state:        state,
	}
}

// Start begins the startup retry loop. A transient getMe/build failure is
// visible as degraded state and retried with bounded exponential backoff. The
// loop is tied to the committed generation, so a successful Apply immediately
// cancels its timer; a factory call already in progress is discarded when it
// eventually returns.
func (s *botSupervisor) Start() {
	s.transitionMu.Lock()
	s.mu.Lock()
	if s.running || s.retryCancel != nil {
		s.mu.Unlock()
		s.transitionMu.Unlock()
		return
	}
	if s.token == "" {
		s.state = botStateDisabled
		s.lastError = ""
		s.mu.Unlock()
		s.transitionMu.Unlock()
		log.Printf("telegram bot disabled: TGBOT_TOKEN not set (configure it in the web console → Settings)")
		return
	}
	if s.parent.Err() != nil {
		s.state = botStateDegraded
		s.lastError = botLifecycleError(s.parent.Err())
		s.mu.Unlock()
		s.transitionMu.Unlock()
		return
	}
	spec := s.scheduleRetryLocked()
	s.mu.Unlock()
	s.transitionMu.Unlock()
	s.startRetry(spec)
}

type botRetrySpec struct {
	ctx        context.Context
	generation uint64
	retrySeq   uint64
	token      string
	admins     []int64
}

// scheduleRetryLocked installs a fresh retry identity and returns the immutable
// launch snapshot. s.mu must be held and token must be non-empty.
func (s *botSupervisor) scheduleRetryLocked() botRetrySpec {
	if s.retryCancel != nil {
		s.retryCancel()
	}
	ctx, cancel := context.WithCancel(s.parent)
	s.retrySeq++
	s.retryCancel = cancel
	s.state = botStateStarting
	return botRetrySpec{
		ctx:        ctx,
		generation: s.generation,
		retrySeq:   s.retrySeq,
		token:      s.token,
		admins:     append([]int64(nil), s.admins...),
	}
}

func (s *botSupervisor) startRetry(spec botRetrySpec) {
	go s.retryLaunch(spec)
}

func (s *botSupervisor) retryLaunch(spec botRetrySpec) {
	delay := time.Duration(0)
	for {
		if delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-spec.ctx.Done():
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				s.finishRetryCancellation(spec)
				return
			case <-timer.C:
			}
		}

		if !s.markRetryStarting(spec) {
			s.finishRetryCancellation(spec)
			return
		}
		runner, err := s.build(spec.token, spec.admins)
		if err == nil && runner == nil {
			err = errors.New("enabled configuration produced no runner")
		}
		if err != nil {
			if !s.recordRetryFailure(spec, err) {
				s.finishRetryCancellation(spec)
				return
			}
			if errors.Is(err, telegram.ErrorUnauthorized) || errors.Is(err, telegram.ErrorForbidden) {
				s.finishPermanentRetryFailure(spec)
				log.Printf("telegram bot startup rejected permanently: %v; waiting for a new token", err)
				return
			}
			log.Printf("telegram bot startup failed: %v; retrying", err)
			delay = nextBotRetryDelay(delay, s.retryInitial, s.retryMax)
			continue
		}

		if s.activateRetryResult(spec, runner) {
			log.Printf("telegram bot enabled (%d admin(s))", len(spec.admins))
		} else {
			s.finishRetryCancellation(spec)
		}
		return
	}
}

func (s *botSupervisor) finishPermanentRetryFailure(spec botRetrySpec) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.retryIsCurrentLocked(spec) {
		s.retryCancel()
		s.retryCancel = nil
	}
}

func nextBotRetryDelay(previous, initial, maximum time.Duration) time.Duration {
	if initial <= 0 {
		initial = defaultBotRetryInitial
	}
	if maximum < initial {
		maximum = initial
	}
	if previous <= 0 {
		return initial
	}
	if previous >= maximum/2 {
		return maximum
	}
	return previous * 2
}

func (s *botSupervisor) retryIsCurrentLocked(spec botRetrySpec) bool {
	return s.generation == spec.generation && s.retrySeq == spec.retrySeq && s.retryCancel != nil
}

func (s *botSupervisor) markRetryStarting(spec botRetrySpec) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if spec.ctx.Err() != nil || !s.retryIsCurrentLocked(spec) {
		return false
	}
	s.state = botStateStarting
	return true
}

func (s *botSupervisor) recordRetryFailure(spec botRetrySpec, err error) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if spec.ctx.Err() != nil || !s.retryIsCurrentLocked(spec) {
		return false
	}
	s.running = false
	s.state = botStateDegraded
	s.lastError = botLifecycleError(err)
	return true
}

func (s *botSupervisor) finishRetryCancellation(spec botRetrySpec) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.retryIsCurrentLocked(spec) {
		return
	}
	s.retryCancel = nil
	if s.parent.Err() != nil {
		s.state = botStateDegraded
		s.lastError = botLifecycleError(s.parent.Err())
	}
}

func (s *botSupervisor) activateRetryResult(spec botRetrySpec, runner botRunner) bool {
	s.transitionMu.Lock()
	defer s.transitionMu.Unlock()

	s.mu.Lock()
	defer s.mu.Unlock()
	if spec.ctx.Err() != nil || !s.retryIsCurrentLocked(spec) || s.parent.Err() != nil {
		return false
	}
	s.retryCancel = nil
	s.startRunnerLocked(runner)
	return true
}

func (s *botSupervisor) build(token string, admins []int64) (botRunner, error) {
	if token == "" {
		return nil, nil
	}
	cfg := s.baseCfg
	cfg.TGBotToken = token
	cfg.TGBotAdmins = adminSetFromIDs(admins)
	return s.factory(cfg, s.ctrl)
}

// startRunnerLocked publishes runner as active before starting its goroutine,
// so View never misses a successful transition. s.mu must be held.
func (s *botSupervisor) startRunnerLocked(runner botRunner) {
	botCtx, cancel := context.WithCancel(s.parent)
	done := make(chan struct{})
	s.runner = runner
	s.cancel = cancel
	s.runDone = done
	s.running = true
	s.state = botStateHealthy
	s.lastError = ""
	s.installHealthReporterLocked(runner, done)
	go s.runAndObserve(runner, botCtx, done)
}

// installHealthReporterLocked registers asynchronously because third-party or
// test implementations may synchronously invoke report from their setter. The
// callback itself validates generation + runDone before changing visible state.
// s.mu must be held.
func (s *botSupervisor) installHealthReporterLocked(runner botRunner, done chan struct{}) {
	source, ok := runner.(botHealthSource)
	if !ok {
		return
	}
	generation := s.generation
	go source.SetHealthReporter(func(err error) {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.generation != generation || s.runner != runner || s.runDone != done || !s.running {
			return
		}
		if err != nil {
			s.state = botStateDegraded
			s.lastError = botLifecycleError(err)
			return
		}
		s.state = botStateHealthy
		s.lastError = ""
	})
}

// runAndObserve makes runner termination part of the supervisor state machine.
// A Run implementation returning (or panicking) without cancellation is
// degraded, never left falsely reported as running.
func (s *botSupervisor) runAndObserve(runner botRunner, ctx context.Context, done chan struct{}) {
	var panicValue any
	func() {
		defer func() { panicValue = recover() }()
		runner.Run(ctx)
	}()

	s.mu.Lock()
	if s.runDone == done {
		s.runner = nil
		s.cancel = nil
		s.runDone = nil
		s.running = false
		s.state = botStateDegraded
		s.lastError = "telegram bot runner exited unexpectedly"
		if panicValue != nil {
			s.lastError = botLifecycleError(fmt.Errorf("telegram bot runner panicked: %v", panicValue))
		} else if ctx.Err() != nil {
			s.state = botStateDegraded
			s.lastError = botLifecycleError(ctx.Err())
		}
	}
	s.mu.Unlock()
	close(done)
}

func botLifecycleError(err error) string {
	if err == nil {
		return ""
	}
	text := strings.Join(strings.Fields(err.Error()), " ")
	return truncateRunes(text, 512)
}

// detachRunnerLocked removes the current runner identity before cancellation.
// That makes its observer a no-op and lets the caller wait without holding mu.
// s.mu must be held.
func (s *botSupervisor) detachRunnerLocked() (context.CancelFunc, <-chan struct{}) {
	cancel, done := s.cancel, s.runDone
	s.runner = nil
	s.cancel = nil
	s.runDone = nil
	s.running = false
	return cancel, done
}

func stopBotRunner(cancel context.CancelFunc, done <-chan struct{}) {
	if cancel == nil {
		return
	}
	cancel()
	if done != nil {
		<-done
	}
}

// View returns the current token-redacted configuration and live health.
func (s *botSupervisor) View() TGBotView {
	s.mu.Lock()
	defer s.mu.Unlock()
	return TGBotView{
		AdminIDs:  append([]int64(nil), s.admins...),
		TokenSet:  s.token != "",
		State:     s.state,
		LastError: s.lastError,
	}
}

// NotifyAdmins forwards an opt-in operational alert through the current live
// runner without exposing the Telegram client to the rest of main.
func (s *botSupervisor) NotifyAdmins(ctx context.Context, text string) error {
	s.mu.Lock()
	runner, running := s.runner, s.running
	s.mu.Unlock()
	if !running || runner == nil {
		return errors.New("telegram bot is not running")
	}
	notifier, ok := runner.(botAdminNotifier)
	if !ok {
		return errors.New("telegram bot runner does not support notifications")
	}
	return notifier.NotifyAdmins(ctx, text)
}

// Apply validates and commits a console update.
//
//   - tokenPtr == nil keeps the committed token and changes only admins.
//   - a non-nil empty token disables the bot.
//   - a changed token is validated before persistence or live replacement.
//
// Persistence precedes the live transition, so a write failure leaves the
// current runner/config untouched. Concurrent calls are last-request-wins:
// stale factory results return errBotConfigSuperseded and are discarded.
func (s *botSupervisor) Apply(tokenPtr *string, admins []int64) error {
	admins = normalizeAdminIDs(admins)

	// Allocate order under transitionMu so no request can appear halfway through
	// another request's persistence/live commit.
	s.transitionMu.Lock()
	s.mu.Lock()
	s.requestSeq++
	requestSeq := s.requestSeq
	currentToken := s.token
	currentRunner := s.runner
	s.mu.Unlock()
	s.transitionMu.Unlock()

	token := currentToken
	if tokenPtr != nil {
		token = strings.TrimSpace(*tokenPtr)
	}

	// Admin-only/same-token edits can use the live runner's atomic updater and
	// avoid a getMe round-trip. Alternate runners without that capability fall
	// back to validation/rebuild.
	adminOnly := token == currentToken
	_, canUpdateAdmins := currentRunner.(botAdminUpdater)
	var candidate botRunner
	if token != "" && (!adminOnly || (currentRunner != nil && !canUpdateAdmins)) {
		var err error
		candidate, err = s.build(token, admins)
		if err != nil {
			return fmt.Errorf("telegram bot: %w", err)
		}
		if candidate == nil {
			return errors.New("telegram bot: enabled configuration produced no runner")
		}
	}

	s.transitionMu.Lock()
	defer s.transitionMu.Unlock()

	s.mu.Lock()
	if requestSeq != s.requestSeq {
		s.mu.Unlock()
		return fmt.Errorf("telegram bot: %w", errBotConfigSuperseded)
	}
	if s.parent.Err() != nil {
		err := s.parent.Err()
		s.mu.Unlock()
		return fmt.Errorf("telegram bot: %w", err)
	}
	// The committed token cannot have changed without a newer requestSeq.
	s.mu.Unlock()

	if err := SaveTGBot(s.file, TGBotConfig{Token: token, Admins: admins}); err != nil {
		return fmt.Errorf("persisting to %s failed; live telegram bot configuration unchanged: %w", s.file, err)
	}

	s.mu.Lock()
	s.generation++
	if s.retryCancel != nil {
		s.retryCancel()
		s.retryCancel = nil
	}
	s.token = token
	s.admins = append([]int64(nil), admins...)

	// Re-read the runner at commit time: it may have exited while a replacement
	// token was being validated.
	liveRunner := s.runner
	if adminOnly && liveRunner != nil {
		if updater, ok := liveRunner.(botAdminUpdater); ok {
			updater.ReplaceAdmins(admins)
			s.installHealthReporterLocked(liveRunner, s.runDone)
			s.mu.Unlock()
			log.Printf("telegram bot admin allowlist updated (%d admin(s))", len(admins))
			return nil
		}
	}

	cancel, done := s.detachRunnerLocked()
	if token == "" {
		s.state = botStateDisabled
		s.lastError = ""
		s.mu.Unlock()
		stopBotRunner(cancel, done)
		log.Printf("telegram bot disabled")
		return nil
	}

	// No live runner during an admin-only edit (startup retry/degraded state):
	// commit the authorization change immediately and restart asynchronously so
	// the API does not depend on Telegram connectivity.
	if adminOnly && candidate == nil {
		spec := s.scheduleRetryLocked()
		s.mu.Unlock()
		stopBotRunner(cancel, done)
		s.startRetry(spec)
		return nil
	}

	s.state = botStateStarting
	s.lastError = ""
	s.mu.Unlock()
	stopBotRunner(cancel, done)

	s.mu.Lock()
	// transitionMu prevents another Apply commit while the old runner stops.
	s.startRunnerLocked(candidate)
	s.mu.Unlock()
	log.Printf("telegram bot enabled (%d admin(s))", len(admins))
	return nil
}
