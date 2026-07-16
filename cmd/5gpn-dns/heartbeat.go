package main

import (
	"context"
	"log"
	"net/http"
	"time"
)

// RunHeartbeat pings HeartbeatURL every interval while the daemon is alive — an
// outbound dead-man's switch. It is the one liveness signal that survives the
// failure modes the rest of the design can't report: a powered-off / crashed box
// (the authenticated console control plane may not be externally monitored, and the in-process
// Telegram bot dies with the daemon) and a wedged process (stops pinging). An
// external monitor (healthchecks.io, Uptime Kuma push endpoint, a self-hosted
// receiver) alerts when the pings stop for longer than its grace period.
//
// Crash-loop caveat: because each restart fires an immediate first ping (below),
// a crash-loop is only surfaced once systemd's restart backoff (RestartSteps →
// RestartMaxDelaySec, 5s→300s) exceeds the monitor's grace period — a fast
// early-backoff loop keeps re-pinging INSIDE the grace window and can hide a
// short-lived loop. Pair a modest monitor grace with WatchdogSec (which catches
// a wedged-but-alive process independently) to cover that early window.
//
// It is a no-op when url is empty (heartbeat disabled), so it is always safe to
// launch. A failed ping is logged and retried on the next tick — a transient
// network blip must not stop the heartbeat loop. Mirrors RunWatchdog's shape
// (immediate first ping closes the startup gap, then ticker-paced).
func RunHeartbeat(ctx context.Context, url string, interval time.Duration) {
	if url == "" {
		return
	}
	if interval <= 0 {
		interval = 60 * time.Second
	}
	client := &http.Client{Timeout: 10 * time.Second}
	ping := func() {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			log.Printf("heartbeat: bad DNS_HEARTBEAT_URL %q: %v", url, err)
			return
		}
		resp, err := client.Do(req)
		if err != nil {
			// Log but keep looping: the external monitor's missed-ping alert is the
			// real signal; a single failed ping shouldn't silence all future ones.
			log.Printf("heartbeat: ping failed: %v", err)
			return
		}
		_ = resp.Body.Close()
	}
	ping() // immediate first ping so a very-short-lived process still registers
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			ping()
		}
	}
}
