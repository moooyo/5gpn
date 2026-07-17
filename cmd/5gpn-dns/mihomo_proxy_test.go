package main

import (
	"bufio"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newMihomoProxyTestHandler(t *testing.T, secret string, upstream http.Handler) http.Handler {
	t.Helper()

	server := newMihomoTLSTestServer(t, upstream)
	transport, err := newMihomoTransport(server.controller, server.serverName, server.certFile)
	if err != nil {
		t.Fatal(err)
	}
	return newMihomoProxy(server.serverName, secret, "/proxy", transport)
}

func TestMihomoProxy_InjectsSecretAndStripsPrefix(t *testing.T) {
	var gotPath, gotAuth string
	h := newMihomoProxyTestHandler(t, "s3cr3t", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"version":"meta"}`))
	}))

	req := httptest.NewRequest(http.MethodGet, "/proxy/version", nil)
	req.Header.Set("Authorization", "Bearer console-token")
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
	h := newMihomoProxyTestHandler(t, "", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest(http.MethodGet, "/proxy/configs", nil)
	req.Header.Set("Authorization", "Bearer console-token")
	h.ServeHTTP(httptest.NewRecorder(), req)
	if gotAuth != "" {
		t.Errorf("empty-secret proxy forwarded Authorization %q; must be stripped", gotAuth)
	}
}

func TestMihomoProxy_InjectedAuthFailureIsBadGateway(t *testing.T) {
	injected := newMihomoProxyTestHandler(t, "stale-secret", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="mihomo"`)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}))
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

}

// TestMihomoProxy_WebSocketUpgradePassesThrough locks in the stdlib behavior we
// rely on: ReverseProxy forwards WebSocket upgrades correctly as long as the
// shared controller transport stays on HTTP/1.1.
func TestMihomoProxy_WebSocketUpgradePassesThrough(t *testing.T) {
	var gotConn, gotUpgrade, gotAuth, gotRESTProto, gotWSProto string

	upstream := newMihomoTLSTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/version":
			gotRESTProto = r.Proto
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"version":"meta"}`))
		case "/ws":
			gotWSProto = r.Proto
			gotConn = r.Header.Get("Connection")
			gotUpgrade = r.Header.Get("Upgrade")
			gotAuth = r.Header.Get("Authorization")
			hj, ok := w.(http.Hijacker)
			if !ok {
				http.Error(w, "upstream missing hijacker", http.StatusInternalServerError)
				return
			}
			conn, bufrw, err := hj.Hijack()
			if err != nil {
				http.Error(w, "hijack failed", http.StatusInternalServerError)
				return
			}
			defer conn.Close()
			_, _ = bufrw.WriteString("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
			_ = bufrw.Flush()
		default:
			http.NotFound(w, r)
		}
	}))

	transport, err := newMihomoTransport(upstream.controller, upstream.serverName, upstream.certFile)
	if err != nil {
		t.Fatal(err)
	}
	restReq, err := http.NewRequest(http.MethodGet, "https://"+upstream.serverName+"/version", nil)
	if err != nil {
		t.Fatalf("new rest request: %v", err)
	}
	restResp, err := (&http.Client{Transport: transport}).Do(restReq)
	if err != nil {
		t.Fatalf("prime shared transport: %v", err)
	}
	_ = restResp.Body.Close()

	h := newMihomoProxy(upstream.serverName, "s3cr3t", "/proxy", transport)
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
	if gotRESTProto != "HTTP/1.1" {
		t.Errorf("shared transport REST protocol = %q, want HTTP/1.1 only", gotRESTProto)
	}
	if gotWSProto != "HTTP/1.1" {
		t.Errorf("upstream websocket protocol = %q, want HTTP/1.1", gotWSProto)
	}
	if gotConn != "Upgrade" || gotUpgrade != "websocket" {
		t.Errorf("upstream saw Connection=%q Upgrade=%q, want Upgrade/websocket (headers swallowed by proxy)", gotConn, gotUpgrade)
	}
	if gotAuth != "Bearer s3cr3t" {
		t.Errorf("upstream saw Authorization=%q on the WS upgrade request, want injected secret", gotAuth)
	}
}
