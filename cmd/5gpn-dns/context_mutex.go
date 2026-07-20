package main

import (
	"context"
	"errors"
	"sync"
	"time"
)

const contextMutexRetryInterval = 10 * time.Millisecond

// lockMutexContext acquires a standard mutex without allowing a cancelled
// control-plane request to remain queued behind a long-running transaction.
// The caller owns the mutex only when this function returns nil.
func lockMutexContext(ctx context.Context, mutex *sync.Mutex) error {
	if ctx == nil {
		return errors.New("a lock context is required")
	}
	if mutex == nil {
		return errors.New("a mutex is required")
	}
	ticker := time.NewTicker(contextMutexRetryInterval)
	defer ticker.Stop()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if mutex.TryLock() {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}
