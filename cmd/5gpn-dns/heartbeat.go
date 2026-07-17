package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"net/url"
	"strings"
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
	client := newHeartbeatHTTPClient()
	ping := func() {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			log.Printf("heartbeat: invalid DNS_HEARTBEAT_URL; ping skipped")
			return
		}
		resp, err := client.Do(req)
		if err != nil {
			// Log but keep looping: the external monitor's missed-ping alert is the
			// real signal; a single failed ping shouldn't silence all future ones.
			log.Printf("heartbeat: ping to %s failed: %s", heartbeatEndpointLabel(url), heartbeatErrorSummary(err))
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

func newHeartbeatHTTPClient() *http.Client {
	var transport *http.Transport
	if base, ok := http.DefaultTransport.(*http.Transport); ok {
		transport = base.Clone()
	} else {
		transport = &http.Transport{}
	}
	// DNS_HEARTBEAT_URL is the complete configured route. Ambient process or
	// systemd-manager proxy variables must not silently change its destination.
	transport.Proxy = nil
	return &http.Client{
		Transport: transport,
		Timeout:   10 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("redirect limit exceeded")
			}
			if len(via) == 0 {
				return nil
			}
			origin := via[0].URL
			if !strings.EqualFold(req.URL.Scheme, origin.Scheme) || !strings.EqualFold(req.URL.Host, origin.Host) {
				return errors.New("cross-origin redirect refused")
			}
			return nil
		},
	}
}

func heartbeatEndpointLabel(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "configured endpoint"
	}
	return u.Scheme + "://" + u.Host + "/<redacted>"
}

func heartbeatErrorSummary(err error) string {
	var urlErr *url.Error
	if errors.As(err, &urlErr) && urlErr.Err != nil {
		return urlErr.Err.Error()
	}
	return "request failed"
}
