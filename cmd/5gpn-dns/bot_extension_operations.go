package main

import (
	"context"
	"errors"
	"sync"
	"time"
)

const maxConcurrentBotExtensionFetches = 2
const botExtensionOperationTimeout = 2 * time.Minute

type botExtensionActiveOperation struct {
	generation uint64
	cancel     context.CancelFunc
}

// botExtensionOperationGuard cancels superseded preview work per private chat
// and bounds all expensive Telegram-triggered remote fetches process-wide.
type botExtensionOperationGuard struct {
	mu     sync.Mutex
	active map[botExtensionStateOwner]botExtensionActiveOperation
	fetch  chan struct{}
	render chan struct{}
}

func newBotExtensionOperationGuard() *botExtensionOperationGuard {
	return &botExtensionOperationGuard{
		active: make(map[botExtensionStateOwner]botExtensionActiveOperation),
		fetch:  make(chan struct{}, maxConcurrentBotExtensionFetches),
		render: make(chan struct{}, 1),
	}
}

func (bt *Bot) acquireBotExtensionRender(ctx context.Context) (func(), error) {
	if ctx == nil {
		return nil, errors.New("extension render context is required")
	}
	guard := bt.extensionOperationGuard()
	select {
	case guard.render <- struct{}{}:
		return func() { <-guard.render }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (bt *Bot) extensionOperationGuard() *botExtensionOperationGuard {
	bt.extensionOpsOnce.Do(func() {
		if bt.extensionOps == nil {
			bt.extensionOps = newBotExtensionOperationGuard()
		}
	})
	return bt.extensionOps
}

// startBotExtensionOperation makes this generation the only cancellable
// preview operation for its administrator/private-chat pair.
func (bt *Bot) startBotExtensionOperation(
	parent context.Context,
	owner botExtensionStateOwner,
	generation uint64,
) (context.Context, func()) {
	ctx, cancel := context.WithTimeout(parent, botExtensionOperationTimeout)
	guard := bt.extensionOperationGuard()
	operation := botExtensionOperationContext{owner: owner, generation: generation}
	if !bt.extensionStateStore().OperationCurrent(operation) {
		cancel()
		return ctx, func() { bt.extensionStateStore().FinishOperation(operation) }
	}
	guard.mu.Lock()
	if previous, ok := guard.active[owner]; ok && previous.generation > generation {
		guard.mu.Unlock()
		cancel()
		return ctx, func() { bt.extensionStateStore().FinishOperation(operation) }
	} else if ok {
		previous.cancel()
	}
	guard.active[owner] = botExtensionActiveOperation{generation: generation, cancel: cancel}
	guard.mu.Unlock()
	// Cancellation can advance the owner generation between the first proof
	// check and registration. Remove this operation immediately if that race
	// occurred, without disturbing a newer operation that may already exist.
	if !bt.extensionStateStore().OperationCurrent(operation) {
		cancel()
		guard.mu.Lock()
		if current, ok := guard.active[owner]; ok && current.generation == generation {
			delete(guard.active, owner)
		}
		guard.mu.Unlock()
	}

	return ctx, func() {
		cancel()
		guard.mu.Lock()
		if current, ok := guard.active[owner]; ok && current.generation == generation {
			delete(guard.active, owner)
		}
		guard.mu.Unlock()
		bt.extensionStateStore().FinishOperation(operation)
	}
}

func (bt *Bot) cancelBotExtensionOperation(adminID, chatID int64) bool {
	return bt.cancelBotExtensionOperationThrough(adminID, chatID, ^uint64(0))
}

func (bt *Bot) cancelBotExtensionOperationThrough(adminID, chatID int64, maxGeneration uint64) bool {
	owner, err := newBotExtensionStateOwner(adminID, chatID)
	if err != nil || maxGeneration == 0 {
		return false
	}
	guard := bt.extensionOperationGuard()
	guard.mu.Lock()
	cancelled := false
	if current, ok := guard.active[owner]; ok && current.generation <= maxGeneration {
		current.cancel()
		delete(guard.active, owner)
		cancelled = true
	}
	guard.mu.Unlock()
	return cancelled
}

// acquireBotExtensionFetch reserves one of the small number of remote-fetch
// slots. The returned release function must be called exactly once.
func (bt *Bot) acquireBotExtensionFetch(ctx context.Context) (func(), error) {
	if ctx == nil {
		return nil, errors.New("extension fetch context is required")
	}
	guard := bt.extensionOperationGuard()
	select {
	case guard.fetch <- struct{}{}:
		return func() { <-guard.fetch }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
