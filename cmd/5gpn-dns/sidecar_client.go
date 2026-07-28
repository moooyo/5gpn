package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"time"
)

// Client for the plugin sidecar's control API.
//
// This replaces writing the sidecar's private configuration file and waiting
// for it to notice. The file made the sidecar's on-disk layout part of this
// package's contract; an API makes the contract a version number, a bundle
// identity, and an answer to "did my last call land".

const (
	sidecarRequestTimeout = 20 * time.Second
	sidecarMaxResponse    = 8 << 20
	// sidecarAPISchema is the control-API version this build speaks. A sidecar
	// advertising anything else is refused rather than guessed at — the two are
	// separately released, so a mismatch is expected and must be explicit.
	//
	// 2 added enabled_when to an action. The sidecar's document decoder rejects
	// unknown fields, so emitting it to a schema-1 build would cost that gateway
	// its whole interception configuration rather than one action.
	sidecarAPISchema = 2
)

var (
	// errSidecarConflict means a compare-and-swap precondition did not hold.
	errSidecarConflict = errors.New("sidecar: compare-and-swap conflict")
	// errSidecarTerminal means repeating the identical call cannot help.
	errSidecarTerminal = errors.New("sidecar: request cannot succeed as submitted")
	// errSidecarRetryable means it may succeed later unchanged.
	errSidecarRetryable = errors.New("sidecar: temporary failure")
	// errSidecarUnsupported means the sidecar does not speak this schema.
	errSidecarUnsupported = errors.New("sidecar: unsupported control API schema")
)

// SidecarClient talks to the plugin sidecar over its machine-only socket.
type SidecarClient struct {
	socketPath string
	hc         *http.Client
}

// NewSidecarClient builds a client over a unix socket path.
func NewSidecarClient(socketPath string) *SidecarClient {
	dialer := &net.Dialer{Timeout: 2 * time.Second}
	return &SidecarClient{
		socketPath: socketPath,
		hc: &http.Client{
			Timeout: sidecarRequestTimeout,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return dialer.DialContext(ctx, "unix", socketPath)
				},
				MaxIdleConns:    1,
				IdleConnTimeout: 30 * time.Second,
			},
		},
	}
}

// SocketPath reports the configured socket.
func (c *SidecarClient) SocketPath() string { return c.socketPath }

// newSidecarControlClient builds the process-wide sidecar client, or nil when
// no control socket is configured at all.
//
// Presence is deliberately NOT checked here. The sidecar's unit carries an
// ExecCondition that refuses to run while the MITM master is off, so on any
// gateway where MITM has not been enabled yet — which includes every fresh
// install — the socket does not exist at the moment this core starts. Deciding
// here that the sidecar is therefore absent produced a nil client that nothing
// ever replaced, and two failures followed from that one nil:
//
//   - the readiness reporter had no way to read what the processor had live, so
//     it never asserted a lease. mihomo holds the generation in quarantine until
//     a lease arrives and fails capture closed while it is there, so every
//     captured connection was REJECTed. The data plane was dead from boot and
//     said so only in one line of the core's log.
//   - bundle publication fell back to writing the configuration file, so a
//     sidecar already running kept serving whatever it had cold started from
//     while the overlay generation named the newer bundle.
//
// Callers already treat presence as a per-call question (see
// sidecarSocketPresent), which is the only way to get this right: the socket
// comes and goes with the master switch over the lifetime of one core process.
func newSidecarControlClient(cfg Config) *SidecarClient {
	socket := cfg.InterceptControlSocket
	if socket == "" {
		log.Printf("intercept: no sidecar control socket configured; using the configuration file")
		return nil
	}
	log.Printf("intercept: driving the sidecar through %s when it is listening", socket)
	return NewSidecarClient(socket)
}

type sidecarCapabilities struct {
	Schema   int            `json:"schema"`
	Version  string         `json:"version"`
	Instance string         `json:"instanceId"`
	Features map[string]int `json:"features"`
	Limits   map[string]int `json:"limits"`
}

type sidecarState struct {
	Schema        int      `json:"schema"`
	InstanceID    string   `json:"instanceId"`
	ActiveBundle  string   `json:"activeBundle"`
	ActiveDigest  string   `json:"activeDigest"`
	Generation    uint64   `json:"generation"`
	MasterEnabled bool     `json:"masterEnabled"`
	Extensions    int      `json:"extensions"`
	CaptureHosts  int      `json:"captureHosts"`
	Staged        []string `json:"stagedBundles"`
	Stored        []string `json:"storedBundles"`
	Version       string   `json:"version"`
}

type sidecarStageResult struct {
	BundleID string `json:"bundleId"`
	Digest   string `json:"digest"`
}

type sidecarCommitResult struct {
	BundleID   string `json:"bundleId"`
	Digest     string `json:"digest"`
	Generation uint64 `json:"generation"`
}

type sidecarErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (c *SidecarClient) do(ctx context.Context, method, path string, body []byte, out any) error {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://sidecar"+path, reader)
	if err != nil {
		return fmt.Errorf("%w: build request: %v", errSidecarTerminal, err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.hc.Do(req)
	if err != nil {
		// A transport failure says nothing about whether the call landed. For a
		// commit the caller must read back rather than assume either way.
		return fmt.Errorf("%w: %v", errSidecarRetryable, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, sidecarMaxResponse))
	if err != nil {
		return fmt.Errorf("%w: read response: %v", errSidecarRetryable, err)
	}
	if resp.StatusCode >= 400 {
		return classifySidecarError(resp.StatusCode, raw)
	}
	if out == nil || len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("%w: decode response: %v", errSidecarRetryable, err)
	}
	return nil
}

// classifySidecarError maps the sidecar's stable code onto the three outcomes
// recovery distinguishes.
func classifySidecarError(status int, raw []byte) error {
	var body sidecarErrorBody
	_ = json.Unmarshal(raw, &body)
	detail := body.Message
	if detail == "" {
		detail = string(bytes.TrimSpace(raw))
	}
	switch body.Code {
	case "cas_conflict", "wrong_state":
		return fmt.Errorf("%w: %s", errSidecarConflict, detail)
	case "unsupported_schema":
		return fmt.Errorf("%w: %s", errSidecarUnsupported, detail)
	case "internal", "store_corrupt":
		return fmt.Errorf("%w: %s", errSidecarRetryable, detail)
	case "not_found":
		return fmt.Errorf("%w: %s", errSidecarTerminal, detail)
	}
	if status >= 500 {
		return fmt.Errorf("%w: HTTP %d: %s", errSidecarRetryable, status, detail)
	}
	return fmt.Errorf("%w: HTTP %d: %s", errSidecarTerminal, status, detail)
}

// Capabilities discovers the sidecar's schema and refuses one this build does
// not speak. The two are separately released, so a mismatch is a normal
// operational state that must be reported rather than papered over.
func (c *SidecarClient) Capabilities(ctx context.Context) (sidecarCapabilities, error) {
	var out sidecarCapabilities
	if err := c.do(ctx, http.MethodGet, "/capabilities", nil, &out); err != nil {
		return out, err
	}
	if out.Schema != sidecarAPISchema {
		return out, fmt.Errorf("%w: sidecar speaks schema %d, this build speaks %d",
			errSidecarUnsupported, out.Schema, sidecarAPISchema)
	}
	return out, nil
}

// State reads the authoritative view of what the sidecar is serving.
func (c *SidecarClient) State(ctx context.Context) (sidecarState, error) {
	var out sidecarState
	err := c.do(ctx, http.MethodGet, "/state", nil, &out)
	return out, err
}

// Plugins reads the per-extension view the console renders.
func (c *SidecarClient) Plugins(ctx context.Context) (json.RawMessage, error) {
	var out json.RawMessage
	err := c.do(ctx, http.MethodGet, "/plugins", nil, &out)
	return out, err
}

// Stage persists a bundle in the sidecar without making it live.
func (c *SidecarClient) Stage(ctx context.Context, bundleID string, document []byte) (sidecarStageResult, error) {
	var out sidecarStageResult
	err := c.do(ctx, http.MethodPut, "/bundles/"+url.PathEscape(bundleID), document, &out)
	return out, err
}

// Commit makes a staged bundle live, guarded by the bundle this coordinator
// believes is active.
func (c *SidecarClient) Commit(ctx context.Context, bundleID, expectedActive string) (sidecarCommitResult, error) {
	var out sidecarCommitResult
	body, err := json.Marshal(map[string]string{"expectedActiveBundle": expectedActive})
	if err != nil {
		return out, fmt.Errorf("%w: encode commit: %v", errSidecarTerminal, err)
	}
	err = c.do(ctx, http.MethodPost, "/bundles/"+url.PathEscape(bundleID)+"/commit", body, &out)
	return out, err
}

// Abort discards a staged bundle.
func (c *SidecarClient) Abort(ctx context.Context, bundleID string) error {
	return c.do(ctx, http.MethodPost, "/bundles/"+url.PathEscape(bundleID)+"/abort", nil, nil)
}

// Purge withdraws every bundle. The sidecar then serves nothing, which mihomo's
// capture rules treat as not-ready and fail closed on.
func (c *SidecarClient) Purge(ctx context.Context) error {
	return c.do(ctx, http.MethodDelete, "/bundles", nil, nil)
}

// PublishBundle takes one desired document to live in the sidecar.
//
// Read back first, stage, then commit against what was actually live rather
// than what this process last believed. An ambiguous commit is resolved by
// reading back, never by assuming failure: the sidecar may have committed and
// lost only the response, and withdrawing that would stop processing traffic
// mihomo is already steering at it.
func (c *SidecarClient) PublishBundle(ctx context.Context, bundleID string, document []byte) (sidecarCommitResult, error) {
	var zero sidecarCommitResult

	before, err := c.State(ctx)
	if err != nil {
		return zero, fmt.Errorf("sidecar: read state before publish: %w", err)
	}
	if before.ActiveBundle == bundleID {
		// Already serving exactly this. Publishing again would burn a
		// generation for no change.
		return sidecarCommitResult{
			BundleID: before.ActiveBundle, Digest: before.ActiveDigest, Generation: before.Generation,
		}, nil
	}

	if _, err := c.Stage(ctx, bundleID, document); err != nil {
		return zero, fmt.Errorf("sidecar: stage %s: %w", bundleID, err)
	}

	result, err := c.Commit(ctx, bundleID, before.ActiveBundle)
	if err == nil {
		return result, nil
	}
	if errors.Is(err, errSidecarTerminal) || errors.Is(err, errSidecarUnsupported) {
		return zero, err
	}

	after, readErr := c.State(ctx)
	if readErr != nil {
		return zero, fmt.Errorf("sidecar: commit outcome unknown for %s (%v); readback also failed: %w",
			bundleID, err, readErr)
	}
	if after.ActiveBundle == bundleID {
		// It landed after all.
		return sidecarCommitResult{
			BundleID: after.ActiveBundle, Digest: after.ActiveDigest, Generation: after.Generation,
		}, nil
	}
	return zero, fmt.Errorf("sidecar: commit of %s did not take effect (active is %q): %w",
		bundleID, after.ActiveBundle, err)
}
