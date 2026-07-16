package main

import (
	"context"
	"testing"
	"time"
)

// #21: sdNotify is a nil no-op off systemd (NOTIFY_SOCKET unset), so it's safe
// to call unconditionally.
func TestSdNotifyNoSocketIsNoop(t *testing.T) {
	t.Setenv("NOTIFY_SOCKET", "")
	if err := sdNotify("WATCHDOG=1"); err != nil {
		t.Errorf("sdNotify with no NOTIFY_SOCKET should be a nil no-op, got %v", err)
	}
}

// #21: RunWatchdog returns immediately when the watchdog isn't configured.
func TestRunWatchdogUnconfiguredReturns(t *testing.T) {
	t.Setenv("WATCHDOG_USEC", "")
	done := make(chan struct{})
	go func() { RunWatchdog(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Error("RunWatchdog should return immediately when WATCHDOG_USEC is unset")
	}
}

// #21: when configured it runs its ping loop and stops on ctx cancel (pings are
// no-ops here since NOTIFY_SOCKET is empty).
func TestRunWatchdogConfiguredStopsOnCancel(t *testing.T) {
	t.Setenv("WATCHDOG_USEC", "2000000")
	t.Setenv("NOTIFY_SOCKET", "")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { RunWatchdog(ctx); close(done) }()
	time.Sleep(50 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Error("RunWatchdog should stop promptly on ctx cancel")
	}
}
