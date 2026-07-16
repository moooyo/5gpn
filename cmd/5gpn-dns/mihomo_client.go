package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// MihomoClient talks to a mihomo (Clash-Meta) external controller REST API.
// Trimmed by the 2026-07-15 policy/mihomo decoupling: the daemon no longer
// projects a per-domain rule set into mihomo, so the per-provider/
// per-selector mutation methods (force-refresh a proxy/rule provider, switch
// a selector's active member) are removed along with the structured egress
// model + api_egress.go that were their only callers. What's KEPT: PutConfigs
// (PUT /configs — reused by the mihomo-config-editor's hot-apply,
// api_mihomo_config.go) and Reachable, the one read-only status call so far
// (GET /api/mihomo/config's controller_reachable field; the browser-facing
// /proxy/ reverse-proxy in mihomo_proxy.go covers richer read-only monitoring
// today).
//
// It deliberately dials LOOPBACK: mihomo's external-controller listens on
// 127.0.0.1 (Config.MihomoController defaults to "127.0.0.1:9090"), so this
// client is built as a plain *http.Client — NOT newSubHTTPClient's
// SSRF-guarded dialer (subscription.go), which explicitly REJECTS loopback
// targets. Mirrors heartbeat.go's client shape (plain client, fixed
// timeout, no shared transport tricks).
type MihomoClient struct {
	base   string
	secret string
	hc     *http.Client
}

// MihomoStatus separates transport reachability from successful controller
// authentication. A 401 proves the process is reachable but also proves the
// daemon's configured secret no longer matches it.
type MihomoStatus struct {
	Reachable     bool
	Authenticated bool
}

// NewMihomoClient builds a client for the controller at host:port (e.g.
// "127.0.0.1:9090"), authenticating with secret when non-empty.
func NewMihomoClient(controller, secret string) *MihomoClient {
	return &MihomoClient{
		base:   "http://" + controller,
		secret: secret,
		hc:     &http.Client{Timeout: 10 * time.Second},
	}
}

// PutConfigs tells mihomo to reload its config from path on disk
// (PUT /configs?force=false, body {"path": path}).
func (c *MihomoClient) PutConfigs(ctx context.Context, path string) error {
	body, err := json.Marshal(struct {
		Path string `json:"path"`
	}{Path: path})
	if err != nil {
		return fmt.Errorf("mihomo: encode configs body: %w", err)
	}
	return c.do(ctx, http.MethodPut, "/configs?force=false", body)
}

// Reachable reports whether the controller answered at all — any completed
// HTTP round trip (even a non-2xx status, e.g. 401 on a bad/missing secret)
// counts as reachable; only a dial/timeout failure (mihomo down, wrong
// address) counts as unreachable. Used by GET /api/mihomo/config's
// controller_reachable field, a light health signal for the console — NOT an
// auth check.
func (c *MihomoClient) Reachable(ctx context.Context) bool {
	return c.Status(ctx).Reachable
}

// Status probes /version and reports both transport reachability and whether
// the configured bearer token was accepted.
func (c *MihomoClient) Status(ctx context.Context) MihomoStatus {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/version", nil)
	if err != nil {
		return MihomoStatus{}
	}
	if c.secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.secret)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return MihomoStatus{}
	}
	defer resp.Body.Close()
	return MihomoStatus{
		Reachable:     true,
		Authenticated: resp.StatusCode >= 200 && resp.StatusCode < 300,
	}
}

// do issues a PUT to base+path with an optional JSON body, attaching the
// bearer token only when a secret is configured (an empty-secret mihomo
// controller rejects requests carrying any Authorization header at all), and
// treats any 2xx status as success.
func (c *MihomoClient) do(ctx context.Context, method, path string, body []byte) error {
	var reqBody io.Reader
	if body != nil {
		reqBody = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, reqBody)
	if err != nil {
		return fmt.Errorf("mihomo: build request: %w", err)
	}
	if c.secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.secret)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return fmt.Errorf("mihomo: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("mihomo: %s %s: status %d: %s", method, path, resp.StatusCode, snippet)
	}
	return nil
}
