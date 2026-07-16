package main

import (
	"bufio"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMihomoProxy_InjectsSecretAndStripsPrefix(t *testing.T) {
	var gotPath, gotAuth string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"version":"meta"}`))
	}))
	defer upstream.Close()
	controller := strings.TrimPrefix(upstream.URL, "http://")

	h := newMihomoProxy(controller, "s3cr3t", "/proxy", true)
	req := httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.Header.Set("Authorization", "Bearer 5gpn-console-token") // must NOT reach mihomo
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d", rr.Code)
	}
	if gotPath != "/version" {
		t.Errorf("upstream path = %q, want /version (prefix stripped)", gotPath)
	}
	if gotAuth != "Bearer s3cr3t" {
		t.Errorf("upstream auth = %q, want the injected mihomo secret (never the console token)", gotAuth)
	}
}

func TestMihomoProxy_EmptySecretStripsInboundAuth(t *testing.T) {
	var gotAuth string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
	}))
	defer upstream.Close()
	h := newMihomoProxy(strings.TrimPrefix(upstream.URL, "http://"), "", "/proxy", true)
	req := httptest.NewRequest(http.MethodGet, "/proxy/configs", nil)
	req.Header.Set("Authorization", "Bearer leak")
	h.ServeHTTP(httptest.NewRecorder(), req)
	if gotAuth != "" {
		t.Errorf("empty-secret proxy forwarded Authorization %q; must be stripped", gotAuth)
	}
}

func TestMihomoProxy_InjectedAuthFailureIsBadGateway(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="mihomo"`)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}))
	defer upstream.Close()
	controller := strings.TrimPrefix(upstream.URL, "http://")

	// The injecting console proxy sits behind a successfully validated 5gpn
	// bearer token. It must not relay mihomo's 401, because the SPA treats any
	// API 401 as a rejected console token and logs the operator out.
	injected := newMihomoProxy(controller, "stale-secret", "/proxy", true)
	rec := httptest.NewRecorder()
	injected.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/proxy/version", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("injecting proxy status = %d, want 502", rec.Code)
	}
	if got := rec.Header().Get("WWW-Authenticate"); got != "" {
		t.Fatalf("injecting proxy leaked WWW-Authenticate %q", got)
	}
	if !strings.Contains(rec.Body.String(), "controller authentication failed") {
		t.Fatalf("injecting proxy body = %q", rec.Body.String())
	}

	// Zashboard supplies its own controller credential, so pass-through mode
	// must retain mihomo's native challenge rather than hiding it.
	passThrough := newMihomoProxy(controller, "ignored", "/proxy", false)
	rec = httptest.NewRecorder()
	passThrough.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/proxy/version", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("pass-through proxy status = %d, want 401", rec.Code)
	}
}

// TestMihomoProxy_PassThroughForwardsIncomingAuth asserts the zash mux's
// pass-through proxy (inject=false, design §5.2) forwards the BROWSER's own
// Authorization header unchanged — the opposite of the injecting proxy above
// — regardless of what the daemon's own controller secret is configured to.
func TestMihomoProxy_PassThroughForwardsIncomingAuth(t *testing.T) {
	var gotAuth string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	controller := strings.TrimPrefix(upstream.URL, "http://")

	h := newMihomoProxy(controller, "s3cr3t", "/proxy", false)
	req := httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.Header.Set("Authorization", "Bearer from-the-browser")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d", rr.Code)
	}
	if gotAuth != "Bearer from-the-browser" {
		t.Errorf("upstream auth = %q, want the browser's own Authorization forwarded unchanged (never the configured secret)", gotAuth)
	}
}

// TestMihomoProxy_PassThroughAddsNoneWhenAbsent asserts the pass-through
// proxy does not invent an Authorization header when the browser sent none
// — an unauthenticated zashboard visitor must reach the controller with no
// credential at all, so mihomo itself can 401 it.
func TestMihomoProxy_PassThroughAddsNoneWhenAbsent(t *testing.T) {
	var gotAuth string
	sawHeader := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, sawHeader = r.Header.Get("Authorization"), r.Header.Get("Authorization") != ""
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	controller := strings.TrimPrefix(upstream.URL, "http://")

	h := newMihomoProxy(controller, "s3cr3t", "/proxy", false)
	req := httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d", rr.Code)
	}
	if sawHeader {
		t.Errorf("upstream saw an Authorization header (%q) despite the browser sending none; pass-through must not inject one", gotAuth)
	}
}

// TestMihomoProxy_WebSocketUpgradePassesThrough proves the proxy forwards a
// WebSocket upgrade handshake rather than swallowing it: the upstream hijacks
// the raw connection and writes a hand-rolled "101 Switching Protocols"
// response, and we assert the client sees that 101 (plus its Connection/
// Upgrade headers) THROUGH the proxy, and that the upstream received the
// inbound Connection/Upgrade headers and the injected mihomo secret. This
// deliberately avoids any websocket library (module policy: only miekg/dns +
// go-telegram/bot as direct deps) — net/http/httputil.ReverseProxy detects
// the "Connection: Upgrade" request itself and switches to raw byte-pipe
// proxying (net/http/httputil since Go 1.12), so a stdlib hijack on both ends
// is sufficient to exercise that path.
func TestMihomoProxy_WebSocketUpgradePassesThrough(t *testing.T) {
	var gotConn, gotUpgrade, gotAuth string
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		req, err := http.ReadRequest(bufio.NewReader(conn))
		if err != nil {
			return
		}
		gotConn = req.Header.Get("Connection")
		gotUpgrade = req.Header.Get("Upgrade")
		gotAuth = req.Header.Get("Authorization")
		_, _ = conn.Write([]byte("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"))
	}()

	h := newMihomoProxy(ln.Addr().String(), "s3cr3t", "/proxy", true)
	proxySrv := httptest.NewServer(h)
	defer proxySrv.Close()

	conn, err := net.Dial("tcp", strings.TrimPrefix(proxySrv.URL, "http://"))
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()

	req, err := http.NewRequest(http.MethodGet, proxySrv.URL+"/proxy/ws", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	if err := req.Write(conn); err != nil {
		t.Fatalf("write request: %v", err)
	}

	resp, err := http.ReadResponse(bufio.NewReader(conn), req)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("status = %d, want 101", resp.StatusCode)
	}
	if got := resp.Header.Get("Upgrade"); got != "websocket" {
		t.Errorf("response Upgrade header = %q, want websocket", got)
	}
	if gotConn != "Upgrade" || gotUpgrade != "websocket" {
		t.Errorf("upstream saw Connection=%q Upgrade=%q, want Upgrade/websocket (headers swallowed by proxy)", gotConn, gotUpgrade)
	}
	if gotAuth != "Bearer s3cr3t" {
		t.Errorf("upstream saw Authorization=%q on the WS upgrade request, want injected secret", gotAuth)
	}
}
