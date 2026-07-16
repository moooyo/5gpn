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

// MihomoClient provides verified controller status and hot config apply.
//
// It deliberately dials LOOPBACK through verified TLS: MihomoController
// supplies the loopback host:port to connect to, while ZashDomain supplies the
// SNI and verified certificate identity. The transport trusts the operating
// system root store plus the panel certificate file and never falls back to
// plaintext HTTP.
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

// NewMihomoClient builds a verified-TLS client for the controller at host:port
// (for example "127.0.0.1:9090"), authenticating with secret when non-empty.
func NewMihomoClient(controller, secret, serverName, certFile string) (*MihomoClient, error) {
	transport, err := newMihomoTransport(controller, serverName, certFile)
	if err != nil {
		return nil, err
	}
	return &MihomoClient{
		base:   "https://" + serverName,
		secret: secret,
		hc: &http.Client{
			Transport: transport,
			Timeout:   10 * time.Second,
		},
	}, nil
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
