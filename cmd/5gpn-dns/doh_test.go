package main

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// dohTestServer starts a TLS DoH endpoint answering every A query with ip.
// Returns the server and the host:port to pin as the dial address.
func dohTestServer(t *testing.T, ip string, onRequest func(*http.Request)) (*httptest.Server, string) {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if onRequest != nil {
			onRequest(r)
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, dohMaxResponseBytes))
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		q := new(dns.Msg)
		if err := q.Unpack(body); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		reply := new(dns.Msg)
		reply.SetReply(q)
		if len(q.Question) > 0 {
			reply.Answer = []dns.RR{&dns.A{
				Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
				A:   net.ParseIP(ip).To4(),
			}}
		}
		packed, err := reply.Pack()
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", dohMediaType)
		_, _ = w.Write(packed)
	}))
	t.Cleanup(srv.Close)
	return srv, strings.TrimPrefix(srv.URL, "https://")
}

// newTestDoHClient builds a client that trusts the test server's cert and
// pins its address, mirroring how NewTrustGroup wires a real member.
func newTestDoHClient(t *testing.T, srv *httptest.Server, addr string) *dohClient {
	t.Helper()
	c, err := newDoHClient("https://dns.test/dns-query", addr, nil)
	if err != nil {
		t.Fatalf("newDoHClient: %v", err)
	}
	// Trust the httptest CA and point verification at a name its certificate
	// actually carries, but mutate the transport's OWN config rather than
	// swapping in a different object: replacing it drops the ALPN settings
	// net/http arranged for HTTP/2, which makes negotiation depend on
	// construction order and fail non-deterministically.
	c.transport.TLSClientConfig.RootCAs = srv.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs
	c.transport.TLSClientConfig.ServerName = "example.com"
	return c
}

func TestDoHExchange_ResolvesAndRestoresCallerID(t *testing.T) {
	srv, addr := dohTestServer(t, "93.184.216.34", nil)
	c := newTestDoHClient(t, srv, addr)

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	q.Id = 0xBEEF

	reply, err := c.exchange(context.Background(), q)
	if err != nil {
		t.Fatalf("exchange: %v", err)
	}
	// RFC 8484 says send ID 0 on the wire, but downstream matching relies on
	// the caller's ID, so it must come back.
	if reply.Id != 0xBEEF {
		t.Errorf("reply.Id = %#x, want the caller's %#x", reply.Id, 0xBEEF)
	}
	if len(reply.Answer) != 1 {
		t.Fatalf("answers = %d, want 1", len(reply.Answer))
	}
	if a, ok := reply.Answer[0].(*dns.A); !ok || a.A.String() != "93.184.216.34" {
		t.Errorf("answer = %v, want 93.184.216.34", reply.Answer[0])
	}
}

// The client's own DNS ID must not leak upstream — HTTP already correlates
// request and response, so sending it buys nothing and identifies the client.
func TestDoHExchange_SendsZeroIDUpstream(t *testing.T) {
	var seenID atomic.Uint32
	srv, addr := dohTestServer(t, "1.2.3.4", func(r *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(r.Body, dohMaxResponseBytes))
		m := new(dns.Msg)
		if m.Unpack(body) == nil {
			seenID.Store(uint32(m.Id))
		}
		r.Body = io.NopCloser(strings.NewReader(string(body)))
	})
	c := newTestDoHClient(t, srv, addr)

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	q.Id = 0x1234
	if _, err := c.exchange(context.Background(), q); err != nil {
		t.Fatalf("exchange: %v", err)
	}
	if got := seenID.Load(); got != 0 {
		t.Errorf("upstream saw DNS ID %#x, want 0 (RFC 8484 §4.1)", got)
	}
	// And the caller's message must not have been mutated in place.
	if q.Id != 0x1234 {
		t.Errorf("caller's query was mutated: Id = %#x", q.Id)
	}
}

func TestDoHExchange_UsesPOSTAndWireFormat(t *testing.T) {
	var method, ctype, accept atomic.Value
	srv, addr := dohTestServer(t, "1.2.3.4", func(r *http.Request) {
		method.Store(r.Method)
		ctype.Store(r.Header.Get("Content-Type"))
		accept.Store(r.Header.Get("Accept"))
	})
	c := newTestDoHClient(t, srv, addr)

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	if _, err := c.exchange(context.Background(), q); err != nil {
		t.Fatalf("exchange: %v", err)
	}
	if method.Load() != http.MethodPost {
		t.Errorf("method = %v, want POST", method.Load())
	}
	if ctype.Load() != dohMediaType || accept.Load() != dohMediaType {
		t.Errorf("content-type=%v accept=%v, want %s for both", ctype.Load(), accept.Load(), dohMediaType)
	}
}

// The whole point of the transport: the connection is reused, so a second
// query pays no handshake. Counted at the TLS layer, which is where the cost
// a per-query dns.Client would pay actually lands.
func TestDoHExchange_ReusesTheConnection(t *testing.T) {
	var handshakes atomic.Int64
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(r.Body, dohMaxResponseBytes))
		q := new(dns.Msg)
		_ = q.Unpack(body)
		reply := new(dns.Msg)
		reply.SetReply(q)
		packed, _ := reply.Pack()
		w.Header().Set("Content-Type", dohMediaType)
		_, _ = w.Write(packed)
	}))
	srv.TLS = &tls.Config{}
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "https://")
	c, err := newDoHClient("https://dns.test/dns-query", addr, nil)
	if err != nil {
		t.Fatalf("newDoHClient: %v", err)
	}
	c.transport.TLSClientConfig.RootCAs = srv.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs
	c.transport.TLSClientConfig.ServerName = "example.com"
	c.transport.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		handshakes.Add(1)
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	defer c.closeIdle()

	for i := 0; i < 5; i++ {
		q := new(dns.Msg)
		q.SetQuestion("example.com.", dns.TypeA)
		if _, err := c.exchange(context.Background(), q); err != nil {
			t.Fatalf("exchange %d: %v", i, err)
		}
	}
	if got := handshakes.Load(); got != 1 {
		t.Errorf("dials = %d across 5 queries, want 1 — the pool is not being reused", got)
	}
}

// Cancellation is the reason this transport was chosen over a hand-rolled DoT
// pool: aborting one query must not poison the connection for the next.
func TestDoHExchange_CancelledQueryLeavesThePoolUsable(t *testing.T) {
	release := make(chan struct{})
	var slow atomic.Bool
	slow.Store(true)
	srv, addr := dohTestServer(t, "5.6.7.8", func(r *http.Request) {
		if slow.Swap(false) {
			select {
			case <-release:
			case <-r.Context().Done():
			case <-time.After(2 * time.Second):
			}
		}
	})
	c := newTestDoHClient(t, srv, addr)
	defer c.closeIdle()

	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(50 * time.Millisecond); cancel() }()
	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	if _, err := c.exchange(ctx, q); err == nil {
		t.Fatal("expected the cancelled exchange to fail")
	} else if !errors.Is(err, context.Canceled) && !strings.Contains(err.Error(), "context canceled") {
		t.Fatalf("cancelled exchange error = %v, want context.Canceled", err)
	}
	close(release)

	// The next query must succeed and be correct — a desynced stream would
	// return the previous answer or garbage.
	q2 := new(dns.Msg)
	q2.SetQuestion("example.com.", dns.TypeA)
	q2.Id = 0x4242
	reply, err := c.exchange(context.Background(), q2)
	if err != nil {
		t.Fatalf("exchange after cancel: %v", err)
	}
	if reply.Id != 0x4242 {
		t.Errorf("reply.Id = %#x, want %#x — the connection desynced", reply.Id, 0x4242)
	}
}

func TestDoHExchange_RejectsNon200(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "nope", http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	c := newTestDoHClient(t, srv, strings.TrimPrefix(srv.URL, "https://"))

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	if _, err := c.exchange(context.Background(), q); err == nil || !strings.Contains(err.Error(), "503") {
		t.Errorf("error = %v, want an HTTP 503 failure", err)
	}
}

func TestNewDoHClient_RejectsBadEndpoints(t *testing.T) {
	for _, endpoint := range []string{
		"http://dns.google/dns-query", // not https
		"dns.google/dns-query",        // no scheme
		"https:///dns-query",          // no host
	} {
		if _, err := newDoHClient(endpoint, "8.8.8.8:443", nil); err == nil {
			t.Errorf("newDoHClient(%q) succeeded, want an error", endpoint)
		}
	}
}
