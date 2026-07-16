package main

import (
	"context"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// sdNotify sends a state line (e.g. "WATCHDOG=1") to systemd's NOTIFY_SOCKET.
// It is a no-op returning nil when NOTIFY_SOCKET is unset — i.e. off systemd, in
// tests, or on any non-Linux build — so callers need no platform guards.
func sdNotify(state string) error {
	sock := os.Getenv("NOTIFY_SOCKET")
	if sock == "" {
		return nil
	}
	name := sock
	if strings.HasPrefix(sock, "@") {
		name = "\x00" + sock[1:] // Linux abstract-namespace socket
	}
	c, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: name, Net: "unixgram"})
	if err != nil {
		return err
	}
	defer c.Close()
	_, err = c.Write([]byte(state))
	return err
}

// RunWatchdog keeps systemd's hardware-style watchdog alive by sending
// WATCHDOG=1 at half the WATCHDOG_USEC interval systemd advertises (set only
// when the unit declares WatchdogSec). A fully-wedged process — one whose
// goroutine scheduler can no longer run this ticker (total deadlock, OOM
// thrash) — stops pinging, so systemd restarts it (paced by the unit's
// RestartSteps backoff) instead of leaving a hung-but-"active" daemon serving
// nothing. It is a no-op when the watchdog isn't configured (WATCHDOG_USEC
// unset / non-systemd / non-Linux), so it is always safe to launch.
func RunWatchdog(ctx context.Context) {
	usecStr := os.Getenv("WATCHDOG_USEC")
	if usecStr == "" {
		return
	}
	usec, err := strconv.ParseInt(usecStr, 10, 64)
	if err != nil || usec <= 0 {
		return
	}
	interval := time.Duration(usec) * time.Microsecond / 2 // systemd's recommended cadence
	if interval < time.Second {
		interval = time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	_ = sdNotify("WATCHDOG=1") // immediate first ping closes the startup window
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_ = sdNotify("WATCHDOG=1")
		}
	}
}
