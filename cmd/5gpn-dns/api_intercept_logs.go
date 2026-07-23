package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	defaultInterceptLogSocketPath  = "/run/5gpn-intercept/logs.sock"
	interceptLogTicketTTL          = 30 * time.Second
	interceptLogTicketLimit        = 512
	interceptLogHealthTimeout      = 2 * time.Second
	interceptLogHeaderTimeout      = 2 * time.Second
	interceptLogHealthMaxBodyBytes = 8 << 10
	interceptLogVersionMaxBytes    = 128
	interceptLogUpstreamHost       = "5gpn-intercept.internal"
)

// interceptLogTicketStore is a purpose-bound, in-memory credential store for
// the plugin-engine log WebSocket. Only SHA-256 digests are retained. A ticket
// is removed on its first consume attempt, including an expired attempt, so two
// concurrent upgrades can never both succeed.
type interceptLogTicketStore struct {
	mu      sync.Mutex
	entries map[[sha256.Size]byte]time.Time
	ttl     time.Duration
	limit   int
	random  io.Reader
}

func newInterceptLogTicketStore(ttl time.Duration, limit int, random io.Reader) *interceptLogTicketStore {
	if ttl <= 0 {
		ttl = interceptLogTicketTTL
	}
	if limit <= 0 {
		limit = interceptLogTicketLimit
	}
	return &interceptLogTicketStore{
		entries: make(map[[sha256.Size]byte]time.Time),
		ttl:     ttl,
		limit:   limit,
		random:  random,
	}
}

func (s *interceptLogTicketStore) mint(now time.Time) (string, time.Time, error) {
	if s == nil || s.random == nil {
		return "", time.Time{}, errors.New("ticket entropy source is unavailable")
	}
	var raw [32]byte
	if _, err := io.ReadFull(s.random, raw[:]); err != nil {
		return "", time.Time{}, err
	}
	token := base64.RawURLEncoding.EncodeToString(raw[:])
	digest := sha256.Sum256(raw[:])
	expires := now.Add(s.ttl)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	for len(s.entries) >= s.limit {
		s.evictOldestLocked()
	}
	s.entries[digest] = expires
	return token, expires, nil
}

func (s *interceptLogTicketStore) consume(token string, now time.Time) bool {
	if s == nil {
		return false
	}
	digest, valid := browserCredentialDigest(token)
	if !valid {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	expires, exists := s.entries[digest]
	if exists {
		delete(s.entries, digest)
	}
	return exists && expires.After(now)
}

func (s *interceptLogTicketStore) pruneLocked(now time.Time) {
	for digest, expires := range s.entries {
		if !expires.After(now) {
			delete(s.entries, digest)
		}
	}
}

func (s *interceptLogTicketStore) evictOldestLocked() {
	var oldestDigest [sha256.Size]byte
	var oldestExpiry time.Time
	found := false
	for digest, expires := range s.entries {
		if !found || expires.Before(oldestExpiry) {
			oldestDigest = digest
			oldestExpiry = expires
			found = true
		}
	}
	if found {
		delete(s.entries, oldestDigest)
	}
}

type interceptHTTPDoer interface {
	Do(*http.Request) (*http.Response, error)
}

// interceptLogUpstream owns the lazy Unix-socket transport used by both the
// health probe and the read-only WebSocket reverse proxy. Construction performs
// no I/O; the sidecar may intentionally be absent while interception is idle.
type interceptLogUpstream struct {
	transport    *http.Transport
	proxy        http.Handler
	healthClient interceptHTTPDoer
}

func newInterceptLogUpstream(socketPath string) *interceptLogUpstream {
	transport := newInterceptLogTransport(socketPath)
	return &interceptLogUpstream{
		transport: transport,
		proxy:     newInterceptLogReverseProxy(transport),
		healthClient: &http.Client{
			Transport: transport,
			Timeout:   interceptLogHealthTimeout,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

func (u *interceptLogUpstream) closeIdleConnections() {
	if u != nil && u.transport != nil {
		u.transport.CloseIdleConnections()
	}
}

func newInterceptLogTransport(socketPath string) *http.Transport {
	dialer := &net.Dialer{Timeout: interceptLogHealthTimeout, KeepAlive: 30 * time.Second}
	return &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", socketPath)
		},
		ForceAttemptHTTP2:     false,
		DisableCompression:    true,
		MaxIdleConns:          4,
		MaxIdleConnsPerHost:   4,
		IdleConnTimeout:       30 * time.Second,
		ResponseHeaderTimeout: interceptLogHeaderTimeout,
	}
}

func newInterceptLogReverseProxy(transport http.RoundTripper) http.Handler {
	return &httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = "http"
			pr.Out.URL.Host = interceptLogUpstreamHost
			pr.Out.URL.Path = "/logs"
			pr.Out.URL.RawPath = ""
			pr.Out.URL.RawQuery = ""
			pr.Out.URL.ForceQuery = false
			pr.Out.Host = interceptLogUpstreamHost
			stripInterceptLogForwardHeaders(pr.Out.Header)
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			writeErr(w, http.StatusServiceUnavailable, "plugin engine unavailable")
		},
	}
}

func stripInterceptLogForwardHeaders(header http.Header) {
	header.Del("Authorization")
	header.Del("Proxy-Authorization")
	header.Del("Cookie")
	header.Del("Forwarded")
	header.Del("Origin")
	header.Del("Sec-Fetch-Site")
	header.Del("X-Real-IP")
	header.Del("True-Client-IP")
	header.Del("CF-Connecting-IP")
	for name := range header {
		if strings.HasPrefix(strings.ToLower(name), "x-forwarded") {
			header.Del(name)
		}
	}
}

// handleInterceptLogTicket mints a credential for exactly one validated
// /intercept/logs WebSocket upgrade. The surrounding /api middleware supplies
// bearer authentication and rate limiting.
func (s *ControlServer) handleInterceptLogTicket(w http.ResponseWriter, _ *http.Request) {
	if s.interceptLogTickets == nil {
		writeErr(w, http.StatusServiceUnavailable, "plugin log tickets unavailable")
		return
	}
	ticket, _, err := s.interceptLogTickets.mint(time.Now())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not mint plugin log ticket")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"ticket":             ticket,
		"expires_in_seconds": int(s.interceptLogTickets.ttl.Seconds()),
	})
}

// consoleInterceptLogProxy exposes one read-only WebSocket path. It validates
// the complete browser handshake and same-origin boundary before consuming the
// ticket, then removes all browser credentials and forwarding metadata before
// proxying over the fixed Unix socket.
func (s *ControlServer) consoleInterceptLogProxy() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/intercept/logs" {
			http.NotFound(w, r)
			return
		}
		hasBody := r.Body != nil && r.Body != http.NoBody
		if r.ProtoMajor != 1 || r.ProtoMinor < 1 || r.ContentLength != 0 || len(r.TransferEncoding) > 0 || hasBody {
			writeErr(w, http.StatusBadRequest, "WebSocket requires a bodyless HTTP/1.1 request")
			return
		}
		if !headerContainsToken(r.Header, "Connection", "upgrade") ||
			!validWebSocketUpgrade(r.Header.Values("Upgrade")) ||
			!validWebSocketKey(r.Header.Values("Sec-WebSocket-Key")) {
			writeErr(w, http.StatusBadRequest, "valid WebSocket upgrade required")
			return
		}
		versions := r.Header.Values("Sec-WebSocket-Version")
		if len(versions) != 1 || strings.TrimSpace(versions[0]) != "13" {
			w.Header().Set("Sec-WebSocket-Version", "13")
			writeErr(w, http.StatusUpgradeRequired, "WebSocket version 13 required")
			return
		}
		if !sameOriginWebSocketRequest(r) {
			writeErr(w, http.StatusForbidden, "same-origin WebSocket required")
			return
		}
		ticket, ok := exactInterceptLogTicketQuery(r.URL.RawQuery)
		if !ok {
			writeErr(w, http.StatusBadRequest, "exactly one log ticket is required")
			return
		}
		if s.interceptLogTickets == nil || !s.interceptLogTickets.consume(ticket, time.Now()) {
			writeErr(w, http.StatusUnauthorized, "invalid or expired plugin log ticket")
			return
		}

		clone := r.Clone(r.Context())
		u := *r.URL
		u.RawQuery = ""
		u.ForceQuery = false
		clone.URL = &u
		clone.RequestURI = u.RequestURI()
		clone.Header = r.Header.Clone()
		stripInterceptLogForwardHeaders(clone.Header)
		if s.interceptLogs == nil || s.interceptLogs.proxy == nil {
			writeErr(w, http.StatusServiceUnavailable, "plugin engine unavailable")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		s.interceptLogs.proxy.ServeHTTP(w, clone)
	})
}

func headerContainsToken(header http.Header, name, target string) bool {
	for _, value := range header.Values(name) {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), target) {
				return true
			}
		}
	}
	return false
}

func validWebSocketKey(values []string) bool {
	if len(values) != 1 {
		return false
	}
	key := strings.TrimSpace(values[0])
	raw, err := base64.StdEncoding.DecodeString(key)
	return err == nil && len(raw) == 16 && base64.StdEncoding.EncodeToString(raw) == key
}

func validWebSocketUpgrade(values []string) bool {
	return len(values) == 1 && strings.EqualFold(strings.TrimSpace(values[0]), "websocket")
}

func sameOriginWebSocketRequest(r *http.Request) bool {
	origins := r.Header.Values("Origin")
	if len(origins) != 1 {
		return false
	}
	origin, err := url.Parse(origins[0])
	if err != nil || origin.User != nil || origin.Opaque != "" || origin.Path != "" ||
		origin.RawQuery != "" || origin.Fragment != "" {
		return false
	}
	expectedScheme := "http"
	if r.TLS != nil {
		expectedScheme = "https"
	}
	if !strings.EqualFold(origin.Scheme, expectedScheme) || !strings.EqualFold(origin.Host, r.Host) {
		return false
	}
	if sites := r.Header.Values("Sec-Fetch-Site"); len(sites) > 0 {
		if len(sites) != 1 || sites[0] != "same-origin" {
			return false
		}
	}
	return true
}

func exactInterceptLogTicketQuery(rawQuery string) (string, bool) {
	query, err := url.ParseQuery(rawQuery)
	if err != nil || len(query) != 1 {
		return "", false
	}
	values, exists := query["ticket"]
	if !exists || len(values) != 1 || values[0] == "" {
		return "", false
	}
	return values[0], true
}

type interceptHealthView struct {
	Running          bool   `json:"running"`
	Expected         bool   `json:"expected"`
	InstalledPlugins int    `json:"installed_plugins"`
	ActivePlugins    int    `json:"active_plugins"`
	Version          string `json:"version,omitempty"`
}

type interceptInternalHealth struct {
	Running          bool   `json:"running"`
	ActiveExtensions int    `json:"active_extensions"`
	Version          string `json:"version,omitempty"`
}

// handleInterceptHealth distinguishes an intentionally idle sidecar from a
// failed one. Installed/active counts come from the control-plane document;
// only an expected runtime must answer the bounded Unix-socket health probe.
func (s *ControlServer) handleInterceptHealth(w http.ResponseWriter, r *http.Request) {
	if s.interceptStore == nil {
		writeErr(w, http.StatusServiceUnavailable, "plugin engine health unavailable")
		return
	}
	if err := lockMutexContext(r.Context(), &s.interceptStore.mu); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "plugin engine health unavailable")
		return
	}
	projection, err := s.interceptStore.HealthProjection()
	s.interceptStore.mu.Unlock()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "plugin engine health unavailable")
		return
	}
	view := interceptHealthView{
		InstalledPlugins: projection.InstalledPlugins,
		ActivePlugins:    projection.ActivePlugins,
	}
	view.Expected = view.ActivePlugins > 0
	if !view.Expected {
		writeJSON(w, http.StatusOK, view)
		return
	}
	if s.interceptLogs == nil || s.interceptLogs.healthClient == nil {
		writeErr(w, http.StatusServiceUnavailable, "plugin engine unavailable")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), interceptLogHealthTimeout)
	defer cancel()
	health, err := probeInterceptLogHealth(ctx, s.interceptLogs.healthClient)
	if err != nil || !health.Running || health.ActiveExtensions != view.ActivePlugins {
		writeErr(w, http.StatusServiceUnavailable, "plugin engine unavailable")
		return
	}
	view.Running = true
	view.Version = health.Version
	writeJSON(w, http.StatusOK, view)
}

func probeInterceptLogHealth(ctx context.Context, client interceptHTTPDoer) (interceptInternalHealth, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+interceptLogUpstreamHost+"/health", nil)
	if err != nil {
		return interceptInternalHealth{}, err
	}
	response, err := client.Do(request)
	if err != nil {
		return interceptInternalHealth{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return interceptInternalHealth{}, fmt.Errorf("plugin engine health returned HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, interceptLogHealthMaxBodyBytes+1))
	if err != nil {
		return interceptInternalHealth{}, err
	}
	if len(body) > interceptLogHealthMaxBodyBytes {
		return interceptInternalHealth{}, errors.New("plugin engine health response is too large")
	}
	var health interceptInternalHealth
	if err := json.Unmarshal(body, &health); err != nil {
		return interceptInternalHealth{}, errors.New("plugin engine health response is invalid")
	}
	health.Version = strings.TrimSpace(health.Version)
	if len(health.Version) > interceptLogVersionMaxBytes {
		return interceptInternalHealth{}, errors.New("plugin engine version is too large")
	}
	return health, nil
}
