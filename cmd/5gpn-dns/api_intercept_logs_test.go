package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const testWebSocketKey = "dGhlIHNhbXBsZSBub25jZQ=="

type interceptLogRoundTripFunc func(*http.Request) (*http.Response, error)

func (fn interceptLogRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

type interceptLogDoerFunc func(*http.Request) (*http.Response, error)

func (fn interceptLogDoerFunc) Do(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func TestInterceptLogTicketStoreCapacityExpiryAndCanonicalDigest(t *testing.T) {
	random := make([]byte, 32*4)
	for block := 0; block < 4; block++ {
		for index := 0; index < 32; index++ {
			random[block*32+index] = byte(block + 1)
		}
	}
	store := newInterceptLogTicketStore(time.Hour, 3, bytes.NewReader(random))
	now := time.Date(2026, 7, 23, 0, 0, 0, 0, time.UTC)
	tickets := make([]string, 0, 4)
	for index := 0; index < 4; index++ {
		ticket, _, err := store.mint(now.Add(time.Duration(index) * time.Second))
		if err != nil {
			t.Fatal(err)
		}
		tickets = append(tickets, ticket)
	}

	store.mu.Lock()
	entryCount := len(store.entries)
	retainedRaw, err := base64.RawURLEncoding.DecodeString(tickets[1])
	if err != nil {
		t.Fatal(err)
	}
	retainedDigest := sha256.Sum256(retainedRaw)
	_, retainedAsDigest := store.entries[retainedDigest]
	store.mu.Unlock()
	if entryCount != 3 {
		t.Fatalf("ticket entries = %d, want hard cap 3", entryCount)
	}
	if !retainedAsDigest {
		t.Fatal("ticket store did not retain the SHA-256 digest key")
	}
	if store.consume(tickets[0], now.Add(10*time.Second)) {
		t.Fatal("oldest ticket survived hard-cap eviction")
	}
	if !store.consume(tickets[1], now.Add(10*time.Second)) {
		t.Fatal("non-evicted ticket was rejected")
	}

	expiring := newInterceptLogTicketStore(time.Second, 2, bytes.NewReader(bytes.Repeat([]byte{9}, 32)))
	ticket, expires, err := expiring.mint(now)
	if err != nil {
		t.Fatal(err)
	}
	if expiring.consume(ticket+"=", now) {
		t.Fatal("non-canonical ticket was accepted")
	}
	if expiring.consume(ticket, expires) {
		t.Fatal("ticket remained valid at its expiry boundary")
	}
	expiring.mu.Lock()
	defer expiring.mu.Unlock()
	if len(expiring.entries) != 0 {
		t.Fatal("expired consume did not remove the ticket")
	}
}

func TestInterceptLogTicketStoreConcurrentConsumeSucceedsOnce(t *testing.T) {
	store := newInterceptLogTicketStore(time.Hour, 8, bytes.NewReader(bytes.Repeat([]byte{7}, 32)))
	ticket, _, err := store.mint(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var successes atomic.Int32
	var wait sync.WaitGroup
	for index := 0; index < 64; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if store.consume(ticket, time.Now()) {
				successes.Add(1)
			}
		}()
	}
	wait.Wait()
	if successes.Load() != 1 {
		t.Fatalf("concurrent consume successes = %d, want 1", successes.Load())
	}
}

func TestInterceptLogTicketHandlerNoStoreAndEntropyFailure(t *testing.T) {
	server := &ControlServer{interceptLogTickets: newInterceptLogTicketStore(time.Minute, 2, bytes.NewReader(bytes.Repeat([]byte{4}, 32)))}
	recorder := httptest.NewRecorder()
	server.handleInterceptLogTicket(recorder, httptest.NewRequest(http.MethodPost, "/api/intercept/logs/ticket", nil))
	if recorder.Code != http.StatusOK || recorder.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("ticket response status/cache=%d/%q body=%s", recorder.Code, recorder.Header().Get("Cache-Control"), recorder.Body.String())
	}
	var response struct {
		Ticket           string `json:"ticket"`
		ExpiresInSeconds int    `json:"expires_in_seconds"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil || response.Ticket == "" || response.ExpiresInSeconds != 60 {
		t.Fatalf("ticket response = %+v err=%v", response, err)
	}

	server.interceptLogTickets = newInterceptLogTicketStore(time.Minute, 2, io.LimitReader(strings.NewReader("short"), 5))
	recorder = httptest.NewRecorder()
	server.handleInterceptLogTicket(recorder, httptest.NewRequest(http.MethodPost, "/api/intercept/logs/ticket", nil))
	if recorder.Code != http.StatusInternalServerError || strings.Contains(recorder.Body.String(), "EOF") {
		t.Fatalf("entropy failure status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestInterceptLogTicketRouteIsBearerProtectedAndUsesProductionBounds(t *testing.T) {
	server, token := newAPITestServer(t)
	if server.interceptLogTickets == nil || server.interceptLogTickets.limit != interceptLogTicketLimit ||
		server.interceptLogTickets.ttl != interceptLogTicketTTL {
		t.Fatalf("production ticket store = %+v", server.interceptLogTickets)
	}
	unauthorized := doAPI(server, http.MethodPost, "/api/intercept/logs/ticket", nil, "", false)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized ticket status=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}
	authorized := doAPI(server, http.MethodPost, "/api/intercept/logs/ticket", nil, token, true)
	if authorized.Code != http.StatusOK || authorized.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("authorized ticket status/cache=%d/%q body=%s", authorized.Code, authorized.Header().Get("Cache-Control"), authorized.Body.String())
	}
}

func validInterceptLogRequest(ticket string) *http.Request {
	request := httptest.NewRequest(http.MethodGet, "http://console.example/intercept/logs?ticket="+ticket, nil)
	request.Host = "console.example"
	request.Header.Set("Connection", "keep-alive, Upgrade")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Sec-WebSocket-Key", testWebSocketKey)
	request.Header.Set("Sec-WebSocket-Version", "13")
	request.Header.Set("Origin", "http://console.example")
	request.Header.Set("Sec-Fetch-Site", "same-origin")
	return request
}

func TestSameOriginWebSocketRequestUsesTLSOrigin(t *testing.T) {
	request := validInterceptLogRequest("ticket")
	request.TLS = &tls.ConnectionState{}
	request.Header.Set("Origin", "https://console.example")
	if !sameOriginWebSocketRequest(request) {
		t.Fatal("matching HTTPS origin was rejected")
	}
	request.Header.Set("Origin", "http://console.example")
	if sameOriginWebSocketRequest(request) {
		t.Fatal("HTTP origin was accepted for a TLS WebSocket")
	}
}

func TestInterceptLogGateRejectsBeforeConsumingTicket(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*http.Request)
		status int
	}{
		{name: "method", mutate: func(r *http.Request) { r.Method = http.MethodPost }, status: http.StatusNotFound},
		{name: "path", mutate: func(r *http.Request) { r.URL.Path = "/intercept/other" }, status: http.StatusNotFound},
		{name: "http-1.0", mutate: func(r *http.Request) { r.ProtoMinor = 0 }, status: http.StatusBadRequest},
		{name: "http-2", mutate: func(r *http.Request) { r.ProtoMajor, r.ProtoMinor = 2, 0 }, status: http.StatusBadRequest},
		{name: "body", mutate: func(r *http.Request) {
			r.Body = io.NopCloser(strings.NewReader("x"))
			r.ContentLength = 1
		}, status: http.StatusBadRequest},
		{name: "transfer-encoding", mutate: func(r *http.Request) { r.TransferEncoding = []string{"chunked"} }, status: http.StatusBadRequest},
		{name: "connection", mutate: func(r *http.Request) { r.Header.Del("Connection") }, status: http.StatusBadRequest},
		{name: "upgrade", mutate: func(r *http.Request) { r.Header.Set("Upgrade", "h2c") }, status: http.StatusBadRequest},
		{name: "multiple-upgrades", mutate: func(r *http.Request) { r.Header.Set("Upgrade", "websocket, h2c") }, status: http.StatusBadRequest},
		{name: "key", mutate: func(r *http.Request) { r.Header.Set("Sec-WebSocket-Key", "bad") }, status: http.StatusBadRequest},
		{name: "version", mutate: func(r *http.Request) { r.Header.Set("Sec-WebSocket-Version", "12") }, status: http.StatusUpgradeRequired},
		{name: "origin", mutate: func(r *http.Request) { r.Header.Set("Origin", "http://attacker.example") }, status: http.StatusForbidden},
		{name: "fetch-site", mutate: func(r *http.Request) { r.Header.Set("Sec-Fetch-Site", "cross-site") }, status: http.StatusForbidden},
		{name: "extra-query", mutate: func(r *http.Request) { r.URL.RawQuery += "&level=info" }, status: http.StatusBadRequest},
		{name: "duplicate-ticket", mutate: func(r *http.Request) { r.URL.RawQuery += "&ticket=other" }, status: http.StatusBadRequest},
	}
	for index, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store := newInterceptLogTicketStore(time.Hour, 4, bytes.NewReader(bytes.Repeat([]byte{byte(index + 1)}, 32)))
			ticket, _, err := store.mint(time.Now())
			if err != nil {
				t.Fatal(err)
			}
			server := &ControlServer{interceptLogTickets: store}
			request := validInterceptLogRequest(ticket)
			test.mutate(request)
			recorder := httptest.NewRecorder()
			server.consoleInterceptLogProxy().ServeHTTP(recorder, request)
			if recorder.Code != test.status {
				t.Fatalf("status=%d body=%s, want %d", recorder.Code, recorder.Body.String(), test.status)
			}
			if !store.consume(ticket, time.Now()) {
				t.Fatal("validation failure consumed the one-use ticket")
			}
		})
	}
}

func TestInterceptLogProxyConsumesTicketAndStripsBrowserMetadata(t *testing.T) {
	store := newInterceptLogTicketStore(time.Hour, 4, bytes.NewReader(bytes.Repeat([]byte{5}, 32)))
	ticket, _, err := store.mint(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var outgoing *http.Request
	transport := interceptLogRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		outgoing = request.Clone(request.Context())
		outgoing.Header = request.Header.Clone()
		return &http.Response{
			StatusCode: http.StatusNoContent,
			Status:     "204 No Content",
			Header:     make(http.Header),
			Body:       http.NoBody,
			Request:    request,
		}, nil
	})
	server := &ControlServer{
		interceptLogTickets: store,
		interceptLogs: &interceptLogUpstream{
			proxy: newInterceptLogReverseProxy(transport),
		},
	}
	request := validInterceptLogRequest(ticket)
	request.Header.Set("Authorization", "Bearer console-secret")
	request.Header.Set("Cookie", "session=secret")
	request.Header.Set("Forwarded", "for=192.0.2.1")
	request.Header.Set("X-Forwarded-For", "192.0.2.1")
	request.Header.Set("X-Forwarded-Proto", "https")
	request.Header.Set("X-Real-IP", "192.0.2.1")
	request.Header.Set("True-Client-IP", "192.0.2.1")
	request.Header.Set("CF-Connecting-IP", "192.0.2.1")
	recorder := httptest.NewRecorder()
	server.consoleInterceptLogProxy().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("proxy status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if outgoing == nil || outgoing.URL.Path != "/logs" || outgoing.URL.RawQuery != "" || outgoing.Host != interceptLogUpstreamHost {
		t.Fatalf("outgoing request = %#v", outgoing)
	}
	for _, name := range []string{
		"Authorization", "Cookie", "Forwarded", "X-Forwarded-For", "X-Forwarded-Proto", "Origin", "Sec-Fetch-Site",
		"X-Real-IP", "True-Client-IP", "CF-Connecting-IP",
	} {
		if value := outgoing.Header.Get(name); value != "" {
			t.Errorf("outgoing %s = %q, want empty", name, value)
		}
	}
	if store.consume(ticket, time.Now()) {
		t.Fatal("successfully proxied ticket was reusable")
	}
}

func serveTestWebSocketUpgrade(w http.ResponseWriter, r *http.Request) {
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking unavailable", http.StatusInternalServerError)
		return
	}
	connection, buffer, err := hijacker.Hijack()
	if err != nil {
		return
	}
	defer connection.Close()
	accept := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	_, _ = buffer.WriteString("HTTP/1.1 101 Switching Protocols\r\n")
	_, _ = buffer.WriteString("Connection: Upgrade\r\nUpgrade: websocket\r\n")
	_, _ = buffer.WriteString("Sec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(accept[:]) + "\r\n\r\n")
	_ = buffer.Flush()
}

func TestInterceptLogTicketGateAndReverseProxyRealUpgrade(t *testing.T) {
	type observedRequest struct {
		path, query, authorization, cookie, forwarded string
	}
	observed := make(chan observedRequest, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		observed <- observedRequest{
			path: r.URL.Path, query: r.URL.RawQuery,
			authorization: r.Header.Get("Authorization"), cookie: r.Header.Get("Cookie"),
			forwarded: r.Header.Get("X-Forwarded-For"),
		}
		serveTestWebSocketUpgrade(w, r)
	}))
	defer upstream.Close()
	upstreamAddress := strings.TrimPrefix(upstream.URL, "http://")
	transport := &http.Transport{
		ForceAttemptHTTP2: false,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "tcp", upstreamAddress)
		},
	}
	defer transport.CloseIdleConnections()

	store := newInterceptLogTicketStore(time.Hour, 4, bytes.NewReader(bytes.Repeat([]byte{6}, 32)))
	ticket, _, err := store.mint(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	control := &ControlServer{
		interceptLogTickets: store,
		interceptLogs:       &interceptLogUpstream{proxy: newInterceptLogReverseProxy(transport)},
	}
	proxy := httptest.NewServer(control.consoleInterceptLogProxy())
	defer proxy.Close()
	proxyAddress := strings.TrimPrefix(proxy.URL, "http://")
	connection, err := net.Dial("tcp", proxyAddress)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	request, err := http.NewRequest(http.MethodGet, proxy.URL+"/intercept/logs?ticket="+ticket, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Connection", "Upgrade")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Sec-WebSocket-Key", testWebSocketKey)
	request.Header.Set("Sec-WebSocket-Version", "13")
	request.Header.Set("Origin", proxy.URL)
	request.Header.Set("Authorization", "Bearer console-secret")
	request.Header.Set("Cookie", "private=true")
	request.Header.Set("X-Forwarded-For", "192.0.2.5")
	if err := request.Write(connection); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(connection), request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("upgrade status=%d, want 101", response.StatusCode)
	}
	if response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("upgrade Cache-Control=%q, want no-store", response.Header.Get("Cache-Control"))
	}
	select {
	case got := <-observed:
		if got.path != "/logs" || got.query != "" || got.authorization != "" || got.cookie != "" || got.forwarded != "" {
			t.Fatalf("upstream request = %+v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("upstream did not receive the upgrade")
	}
}

func TestInterceptLogEndToEndBearerTicketUnixUpgrade(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "logs.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		if runtime.GOOS == "windows" {
			t.Skipf("Unix sockets are unavailable on this Windows host: %v", err)
		}
		t.Fatal(err)
	}
	observed := make(chan string, 1)
	internal := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		observed <- r.Method + " " + r.URL.RequestURI() + " auth=" + r.Header.Get("Authorization") + " cookie=" + r.Header.Get("Cookie")
		serveTestWebSocketUpgrade(w, r)
	})}
	defer func() {
		_ = internal.Close()
		_ = listener.Close()
	}()
	go func() { _ = internal.Serve(listener) }()

	control, bearer := newAPITestServer(t)
	control.interceptLogs.closeIdleConnections()
	control.interceptLogs = newInterceptLogUpstream(socketPath)
	defer control.interceptLogs.closeIdleConnections()
	public := httptest.NewServer(control.srv.Handler)
	defer public.Close()

	mint, err := http.NewRequest(http.MethodPost, public.URL+"/api/intercept/logs/ticket", nil)
	if err != nil {
		t.Fatal(err)
	}
	mint.Header.Set("Authorization", "Bearer "+bearer)
	mintResponse, err := public.Client().Do(mint)
	if err != nil {
		t.Fatal(err)
	}
	defer mintResponse.Body.Close()
	if mintResponse.StatusCode != http.StatusOK || mintResponse.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("mint status/cache=%d/%q", mintResponse.StatusCode, mintResponse.Header.Get("Cache-Control"))
	}
	var ticketResponse struct {
		Ticket string `json:"ticket"`
	}
	if err := json.NewDecoder(mintResponse.Body).Decode(&ticketResponse); err != nil || ticketResponse.Ticket == "" {
		t.Fatalf("mint response=%+v err=%v", ticketResponse, err)
	}

	publicAddress := strings.TrimPrefix(public.URL, "http://")
	connection, err := net.Dial("tcp", publicAddress)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	upgrade, err := http.NewRequest(http.MethodGet, public.URL+"/intercept/logs?ticket="+ticketResponse.Ticket, nil)
	if err != nil {
		t.Fatal(err)
	}
	upgrade.Header.Set("Connection", "Upgrade")
	upgrade.Header.Set("Upgrade", "websocket")
	upgrade.Header.Set("Sec-WebSocket-Key", testWebSocketKey)
	upgrade.Header.Set("Sec-WebSocket-Version", "13")
	upgrade.Header.Set("Origin", public.URL)
	upgrade.Header.Set("Authorization", "Bearer must-not-reach-sidecar")
	upgrade.Header.Set("Cookie", "private=true")
	if err := upgrade.Write(connection); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(connection), upgrade)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("public Unix upgrade status=%d", response.StatusCode)
	}
	select {
	case got := <-observed:
		if got != "GET /logs auth= cookie=" {
			t.Fatalf("Unix upstream request=%q", got)
		}
	case <-time.After(time.Second):
		t.Fatal("Unix upstream did not receive the public upgrade")
	}
}

func writeInterceptHealthStore(t testing.TB, enabled bool, modules ...interceptModuleSnapshot) *InterceptConfigStore {
	t.Helper()
	document, _ := testInterceptDocument(t, modules...)
	document.MITM.Enabled = enabled
	body, err := marshalInterceptDocument(document)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	return NewInterceptConfigStore(path)
}

func TestInterceptHealthIdleDoesNotDialSidecar(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	var calls atomic.Int32
	server := &ControlServer{
		interceptStore: writeInterceptHealthStore(t, false, module),
		interceptLogs: &interceptLogUpstream{healthClient: interceptLogDoerFunc(func(*http.Request) (*http.Response, error) {
			calls.Add(1)
			return nil, errors.New("must not be called")
		})},
	}
	recorder := httptest.NewRecorder()
	server.handleInterceptHealth(recorder, httptest.NewRequest(http.MethodGet, "/api/intercept/health", nil))
	if recorder.Code != http.StatusOK || calls.Load() != 0 {
		t.Fatalf("idle health status/calls=%d/%d body=%s", recorder.Code, calls.Load(), recorder.Body.String())
	}
	var view interceptHealthView
	if err := json.Unmarshal(recorder.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if view.Running || view.Expected || view.InstalledPlugins != 1 || view.ActivePlugins != 0 {
		t.Fatalf("idle health = %+v", view)
	}
}

func TestInterceptHealthExpectedProbesBoundedInternalEndpoint(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	var gotMethod, gotPath, gotHost string
	server := &ControlServer{
		interceptStore: writeInterceptHealthStore(t, true, module),
		interceptLogs: &interceptLogUpstream{healthClient: interceptLogDoerFunc(func(request *http.Request) (*http.Response, error) {
			gotMethod, gotPath, gotHost = request.Method, request.URL.Path, request.URL.Host
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     make(http.Header),
				Body:       io.NopCloser(strings.NewReader(`{"running":true,"active_extensions":1,"version":"v1.2.3"}`)),
				Request:    request,
			}, nil
		})},
	}
	recorder := httptest.NewRecorder()
	server.handleInterceptHealth(recorder, httptest.NewRequest(http.MethodGet, "/api/intercept/health", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("health status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var view interceptHealthView
	if err := json.Unmarshal(recorder.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if !view.Running || !view.Expected || view.InstalledPlugins != 1 || view.ActivePlugins != 1 || view.Version != "v1.2.3" {
		t.Fatalf("running health = %+v", view)
	}
	if gotMethod != http.MethodGet || gotPath != "/health" || gotHost != interceptLogUpstreamHost {
		t.Fatalf("internal health request=%s http://%s%s", gotMethod, gotHost, gotPath)
	}
}

func TestInterceptHealthRejectsStaleOrNonRunningSidecarSnapshot(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	for _, body := range []string{
		`{"running":false,"active_extensions":1,"version":"v1"}`,
		`{"running":true,"active_extensions":0,"version":"v1"}`,
	} {
		t.Run(body, func(t *testing.T) {
			server := &ControlServer{
				interceptStore: writeInterceptHealthStore(t, true, module),
				interceptLogs: &interceptLogUpstream{healthClient: interceptLogDoerFunc(func(request *http.Request) (*http.Response, error) {
					return &http.Response{
						StatusCode: http.StatusOK,
						Header:     make(http.Header),
						Body:       io.NopCloser(strings.NewReader(body)),
						Request:    request,
					}, nil
				})},
			}
			recorder := httptest.NewRecorder()
			server.handleInterceptHealth(recorder, httptest.NewRequest(http.MethodGet, "/api/intercept/health", nil))
			if recorder.Code != http.StatusServiceUnavailable {
				t.Fatalf("stale health status=%d body=%s", recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestProbeInterceptLogHealthBoundsBodyAndHonorsContext(t *testing.T) {
	t.Run("body", func(t *testing.T) {
		client := interceptLogDoerFunc(func(request *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     make(http.Header),
				Body:       io.NopCloser(strings.NewReader(strings.Repeat("x", interceptLogHealthMaxBodyBytes+1))),
				Request:    request,
			}, nil
		})
		if _, err := probeInterceptLogHealth(context.Background(), client); err == nil {
			t.Fatal("oversized health response was accepted")
		}
	})
	t.Run("context", func(t *testing.T) {
		client := interceptLogDoerFunc(func(request *http.Request) (*http.Response, error) {
			<-request.Context().Done()
			return nil, request.Context().Err()
		})
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		defer cancel()
		started := time.Now()
		if _, err := probeInterceptLogHealth(ctx, client); err == nil || time.Since(started) > time.Second {
			t.Fatalf("bounded health probe err=%v duration=%s", err, time.Since(started))
		}
	})
}

func TestInterceptHealthExpectedMissingSocketIsUnavailable(t *testing.T) {
	module := testModuleSnapshot()
	module.Enabled = true
	server := &ControlServer{
		interceptStore: writeInterceptHealthStore(t, true, module),
		interceptLogs:  newInterceptLogUpstream(filepath.Join(t.TempDir(), "missing.sock")),
	}
	recorder := httptest.NewRecorder()
	server.handleInterceptHealth(recorder, httptest.NewRequest(http.MethodGet, "/api/intercept/health", nil))
	if recorder.Code != http.StatusServiceUnavailable || !strings.Contains(recorder.Body.String(), "plugin engine unavailable") {
		t.Fatalf("missing socket health status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestInterceptLogUnixTransportReachesInternalHealth(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "logs.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		if runtime.GOOS == "windows" {
			t.Skipf("Unix sockets are unavailable on this Windows host: %v", err)
		}
		t.Fatal(err)
	}
	internal := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/health" || r.URL.RawQuery != "" {
			http.NotFound(w, r)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"running": true, "version": "unix-test"})
	})}
	defer func() {
		_ = internal.Close()
		_ = listener.Close()
	}()
	go func() { _ = internal.Serve(listener) }()

	upstream := newInterceptLogUpstream(socketPath)
	defer upstream.closeIdleConnections()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	health, err := probeInterceptLogHealth(ctx, upstream.healthClient)
	if err != nil {
		t.Fatal(err)
	}
	if health.Version != "unix-test" {
		t.Fatalf("Unix health version=%q", health.Version)
	}
}

func TestInterceptLogProxyMissingSocketIsUnavailableAndConsumesTicket(t *testing.T) {
	store := newInterceptLogTicketStore(time.Hour, 4, bytes.NewReader(bytes.Repeat([]byte{8}, 32)))
	ticket, _, err := store.mint(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	server := &ControlServer{
		interceptLogTickets: store,
		interceptLogs:       newInterceptLogUpstream(filepath.Join(t.TempDir(), "missing.sock")),
	}
	recorder := httptest.NewRecorder()
	server.consoleInterceptLogProxy().ServeHTTP(recorder, validInterceptLogRequest(ticket))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("missing socket proxy status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if store.consume(ticket, time.Now()) {
		t.Fatal("failed upstream dial left the ticket reusable")
	}
}
