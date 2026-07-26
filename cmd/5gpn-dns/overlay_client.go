package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"
)

// Errors the driver branches on. Everything else is an opaque failure.
var (
	// errOverlayConflict means a compare-and-swap precondition did not hold.
	// The coordinator must read back and decide; it must never blind-rollback.
	errOverlayConflict = errors.New("overlay: compare-and-swap conflict")
	// errOverlayTerminal means repeating the identical operation cannot help.
	errOverlayTerminal = errors.New("overlay: operation cannot succeed as submitted")
	// errOverlayRetryable means the operation may succeed later unchanged.
	errOverlayRetryable = errors.New("overlay: temporary failure")
	// errOverlayUnsupported means the core does not implement the overlay, or
	// implements a schema this build does not understand.
	errOverlayUnsupported = errors.New("overlay: core does not support this schema")
)

const (
	overlayRequestTimeout = 10 * time.Second
	// overlayMaxResponseBytes bounds a reply from the core. The core is
	// trusted, but a bounded read is what keeps a wedged socket from turning
	// into unbounded memory here.
	overlayMaxResponseBytes = 4 << 20
)

// OverlayClient talks to mihomo's machine-only runtime overlay control socket.
//
// This is deliberately a separate transport from MihomoClient's TLS controller:
// the overlay's mutation endpoint is not part of the generic Clash API, is not
// reachable over TCP, and authenticates by OS peer identity rather than by a
// shared bearer secret. Routing it through the ordinary controller would put
// generation mutation on the same socket the dashboard reaches.
type OverlayClient struct {
	socketPath string
	hc         *http.Client
}

// NewOverlayClient builds a client over a unix socket path.
func NewOverlayClient(socketPath string) *OverlayClient {
	dialer := &net.Dialer{Timeout: 2 * time.Second}
	return &OverlayClient{
		socketPath: socketPath,
		hc: &http.Client{
			Timeout: overlayRequestTimeout,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return dialer.DialContext(ctx, "unix", socketPath)
				},
				// One connection is enough and keeps the peer-credential check
				// on the core side cheap.
				MaxIdleConns:    1,
				IdleConnTimeout: 30 * time.Second,
			},
		},
	}
}

// SocketPath reports the configured socket.
func (c *OverlayClient) SocketPath() string { return c.socketPath }

func (c *OverlayClient) do(ctx context.Context, method, path string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("%w: encode request: %v", errOverlayTerminal, err)
		}
		reader = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, method, "http://overlay"+path, reader)
	if err != nil {
		return fmt.Errorf("%w: build request: %v", errOverlayTerminal, err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.hc.Do(req)
	if err != nil {
		// A transport failure is not evidence about the operation's outcome.
		// If this was a commit, the caller must read back rather than assume.
		return fmt.Errorf("%w: %v", errOverlayRetryable, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, overlayMaxResponseBytes))
	if err != nil {
		return fmt.Errorf("%w: read response: %v", errOverlayRetryable, err)
	}

	if resp.StatusCode >= 400 {
		return classifyOverlayError(resp.StatusCode, raw)
	}
	if out == nil || len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("%w: decode response: %v", errOverlayRetryable, err)
	}
	return nil
}

// classifyOverlayError maps the core's stable error code onto the three
// outcomes the coordinator's recovery actually distinguishes.
func classifyOverlayError(status int, raw []byte) error {
	var body overlayErrorBody
	_ = json.Unmarshal(raw, &body)
	detail := body.Message
	if detail == "" {
		detail = string(bytes.TrimSpace(raw))
	}

	switch body.Code {
	case "cas_conflict", "wrong_state":
		return fmt.Errorf("%w: %s", errOverlayConflict, detail)
	case "dependency_missing", "not_ready", "internal":
		return fmt.Errorf("%w: %s", errOverlayRetryable, detail)
	case "unsupported_schema", "disabled":
		return fmt.Errorf("%w: %s", errOverlayUnsupported, detail)
	case "invalid_document", "quota_exceeded", "anchor_invalid", "mode_conflict", "not_found", "store_corrupt":
		return fmt.Errorf("%w: %s", errOverlayTerminal, detail)
	}

	// No recognised code — fall back to the status class. 5xx may be
	// transient; 4xx is the caller's fault.
	if status >= 500 {
		return fmt.Errorf("%w: HTTP %d: %s", errOverlayRetryable, status, detail)
	}
	if status == http.StatusNotFound {
		return fmt.Errorf("%w: HTTP %d: %s", errOverlayUnsupported, status, detail)
	}
	return fmt.Errorf("%w: HTTP %d: %s", errOverlayTerminal, status, detail)
}

// Capabilities discovers whether this core implements the overlay, and at which
// schema version. A version this build does not understand is refused rather
// than assumed compatible.
func (c *OverlayClient) Capabilities(ctx context.Context) (overlayCapabilities, error) {
	var out overlayCapabilities
	if err := c.do(ctx, http.MethodGet, "/capabilities", nil, &out); err != nil {
		return out, err
	}
	feature, ok := out.Features["runtime-overlays"]
	if !ok {
		return out, fmt.Errorf("%w: core advertises no runtime-overlays feature", errOverlayUnsupported)
	}
	if feature.Version != overlaySchemaVersion {
		return out, fmt.Errorf("%w: core advertises schema %d, this build speaks %d",
			errOverlayUnsupported, feature.Version, overlaySchemaVersion)
	}
	if feature.Owner != "" && feature.Owner != overlayOwner {
		return out, fmt.Errorf("%w: core overlay is owned by %q, not %q",
			errOverlayTerminal, feature.Owner, overlayOwner)
	}
	return out, nil
}

// Stage persists and validates a generation without giving it any data-plane
// capability. It is idempotent for an identical document.
func (c *OverlayClient) Stage(ctx context.Context, doc overlayDocument) (overlayStageResult, error) {
	var out overlayStageResult
	path := fmt.Sprintf("/runtime-overlays/%s/generations/%s",
		url.PathEscape(overlayOwner), url.PathEscape(doc.GenerationID))
	err := c.do(ctx, http.MethodPut, path, doc, &out)
	return out, err
}

// Commit performs the compare-and-swap and publishes the generation.
//
// expectedActive asserts which generation the coordinator believes is live;
// expectedCoreRevision asserts the configuration it was validated against has
// not moved. Both are required for a commit that supersedes something —
// omitting them turns a compare-and-swap into a blind write.
func (c *OverlayClient) Commit(ctx context.Context, generationID, expectedActive string, expectedCoreRevision uint64) (overlayCommitResult, error) {
	var out overlayCommitResult
	path := fmt.Sprintf("/runtime-overlays/%s/generations/%s/commit",
		url.PathEscape(overlayOwner), url.PathEscape(generationID))
	body := map[string]any{
		"expectedActiveGeneration":   expectedActive,
		"expectedCoreConfigRevision": expectedCoreRevision,
	}
	err := c.do(ctx, http.MethodPost, path, body, &out)
	return out, err
}

// Abort discards a staged generation. It is rejected for anything already
// active, draining or revoked — those must be superseded, not erased.
func (c *OverlayClient) Abort(ctx context.Context, generationID string) error {
	path := fmt.Sprintf("/runtime-overlays/%s/generations/%s/abort",
		url.PathEscape(overlayOwner), url.PathEscape(generationID))
	return c.do(ctx, http.MethodPost, path, nil, nil)
}

// Readback returns the authoritative live state. This is what a coordinator
// that lost a commit response calls before doing anything else.
func (c *OverlayClient) Readback(ctx context.Context) (overlayReadback, error) {
	var out overlayReadback
	path := "/runtime-overlays/" + url.PathEscape(overlayOwner)
	err := c.do(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

// overlayReadinessRequest attests that the processor is serving one generation.
//
// The processor does not send this itself: its socket is read-only, deliberately,
// because a compromised processor that could register readiness could also claim
// to be serving a generation it is not. The coordinator asserts it instead, and
// only after reading the sidecar's own view of what it has live — so the claim
// is something the coordinator verified rather than something it assumed.
type overlayReadinessRequest struct {
	ProcessorID     string `json:"processorId"`
	ProcessInstance string `json:"processInstanceId"`
	GenerationID    string `json:"generationId"`
	BundleDigest    string `json:"sidecarBundleDigest"`
	CertHostSet     string `json:"certificateHostSetDigest"`
}

// RegisterReadiness renews the processor's lease.
//
// The lease has a short TTL and the core fails capture closed when it lapses,
// so this is a heartbeat rather than a one-time announcement: a coordinator
// that registers once and stops leaves every capture rule rejecting within
// seconds.
func (c *OverlayClient) RegisterReadiness(ctx context.Context, req overlayReadinessRequest) error {
	path := "/runtime-overlays/" + url.PathEscape(overlayOwner) + "/readiness"
	return c.do(ctx, http.MethodPost, path, req, nil)
}

// Purge removes every durable overlay artifact from the core.
//
// This is the downgrade contract's purge step, and it is destructive by design:
// artifacts left behind would let a later upgrade rediscover and resurrect a
// generation the operator believes was rolled back.
func (c *OverlayClient) Purge(ctx context.Context) error {
	path := "/runtime-overlays/" + url.PathEscape(overlayOwner)
	return c.do(ctx, http.MethodDelete, path, nil, nil)
}
