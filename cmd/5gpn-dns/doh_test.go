package main

import (
	"bytes"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// stubHandler is a minimal dns.Handler that always returns a fixed reply.
type stubHandler struct {
	reply *dns.Msg
}

func (s *stubHandler) ServeDNS(w dns.ResponseWriter, r *dns.Msg) {
	m := s.reply.Copy()
	m.SetReply(r)
	_ = w.WriteMsg(m)
}

// makeDNSQuery returns a packed A query for name.
func makeDNSQuery(name string) []byte {
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(name), dns.TypeA)
	b, _ := q.Pack()
	return b
}

// TestDoH_POST verifies that a POST application/dns-message request to the
// DoH handler returns a valid application/dns-message reply.
func TestDoH_POST(t *testing.T) {
	// Minimal stub handler that echoes an empty NOERROR reply.
	h := &stubHandler{reply: new(dns.Msg)}

	s := &Servers{
		cfg:     Config{ListenDoH: ":8443"},
		handler: h,
	}

	wire := makeDNSQuery("example.com")

	req := httptest.NewRequest(http.MethodPost, "/dns-query", bytes.NewReader(wire))
	req.Header.Set("Content-Type", "application/dns-message")
	rec := httptest.NewRecorder()

	s.dohHandler(rec, req)

	resp := rec.Result()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("POST /dns-query status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/dns-message" {
		t.Errorf("Content-Type = %q, want application/dns-message", ct)
	}

	// Parse the response body as a DNS message.
	body := rec.Body.Bytes()
	if len(body) == 0 {
		t.Fatal("response body is empty")
	}
	var reply dns.Msg
	if err := reply.Unpack(body); err != nil {
		t.Fatalf("failed to unpack response as DNS message: %v", err)
	}
}

// TestDoH_GET verifies that a GET request with a base64url-encoded DNS wire
// message in the 'dns' query parameter returns a valid reply.
func TestDoH_GET(t *testing.T) {
	h := &stubHandler{reply: new(dns.Msg)}
	s := &Servers{cfg: Config{ListenDoH: ":8443"}, handler: h}

	wire := makeDNSQuery("example.org")
	b64 := base64.RawURLEncoding.EncodeToString(wire)

	req := httptest.NewRequest(http.MethodGet, "/dns-query?dns="+b64, nil)
	rec := httptest.NewRecorder()

	s.dohHandler(rec, req)

	resp := rec.Result()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /dns-query status = %d, want 200", resp.StatusCode)
	}

	body := rec.Body.Bytes()
	var reply dns.Msg
	if err := reply.Unpack(body); err != nil {
		t.Fatalf("failed to unpack GET response as DNS message: %v", err)
	}
}

// TestDoH_InvalidMethod checks that unsupported HTTP methods return 405.
func TestDoH_InvalidMethod(t *testing.T) {
	h := &stubHandler{reply: new(dns.Msg)}
	s := &Servers{cfg: Config{}, handler: h}

	req := httptest.NewRequest(http.MethodPut, "/dns-query", nil)
	rec := httptest.NewRecorder()

	s.dohHandler(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("PUT /dns-query status = %d, want 405", rec.Code)
	}
}

// TestDoH_MissingDNSParam checks that GET without the dns param returns 400.
func TestDoH_MissingDNSParam(t *testing.T) {
	h := &stubHandler{reply: new(dns.Msg)}
	s := &Servers{cfg: Config{}, handler: h}

	req := httptest.NewRequest(http.MethodGet, "/dns-query", nil)
	rec := httptest.NewRecorder()

	s.dohHandler(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("GET /dns-query (no dns param) status = %d, want 400", rec.Code)
	}
}

// TestDoH_PostWithRealHandler verifies end-to-end DoH through the full Handler.
func TestDoH_PostWithRealHandler(t *testing.T) {
	// Build a minimal real Handler with no upstreams (blacklist will handle).
	bl, _ := LoadDomainSet() // empty set
	ad, _ := LoadDomainSet()
	dir, _ := LoadDomainSet()

	h := &Handler{
		Adblock:   ad,
		Direct:    dir,
		Blacklist: bl,
		CN:        nil,
		GatewayIP: []byte{10, 0, 0, 1},
		TTLMin:    5 * time.Second,
		TTLMax:    300 * time.Second,
		Timeout:   2 * time.Second,
		// No China/Trust set — an A query with empty blacklist goes to arbitrate
		// which will fail without upstreams. Use a blacklist match instead.
	}
	// Add "blocked.example" to blacklist so it returns gateway IP without upstream.
	h.Blacklist, _ = LoadDomainSet() // Load empty, then inject manually.
	// Use a DomainSet that matches "blocked.example".
	ds := &DomainSet{entries: map[string]struct{}{"blocked.example": {}}}
	h.Blacklist = ds

	s := &Servers{cfg: Config{}, handler: h}

	// Query A for blocked.example → should return GatewayIP = 10.0.0.1.
	q := new(dns.Msg)
	q.SetQuestion("blocked.example.", dns.TypeA)
	wire, _ := q.Pack()

	req := httptest.NewRequest(http.MethodPost, "/dns-query", bytes.NewReader(wire))
	req.Header.Set("Content-Type", "application/dns-message")
	rec := httptest.NewRecorder()

	s.dohHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var reply dns.Msg
	if err := reply.Unpack(rec.Body.Bytes()); err != nil {
		t.Fatalf("unpack: %v", err)
	}
	if len(reply.Answer) == 0 {
		t.Fatal("no answers in reply")
	}
	a, ok := reply.Answer[0].(*dns.A)
	if !ok {
		t.Fatalf("expected *dns.A, got %T", reply.Answer[0])
	}
	if a.A.String() != "10.0.0.1" {
		t.Errorf("answer IP = %v, want 10.0.0.1", a.A)
	}
}

// TestDoH_POST_ContentTypeWithParams verifies that RFC 8484 is satisfied when
// the Content-Type header carries additional media-type parameters
// (e.g. "application/dns-message; charset=utf-8") — the handler must accept
// it rather than returning 415.
func TestDoH_POST_ContentTypeWithParams(t *testing.T) {
	h := &stubHandler{reply: new(dns.Msg)}
	s := &Servers{cfg: Config{ListenDoH: ":8443"}, handler: h}

	wire := makeDNSQuery("example.com")

	for _, ct := range []string{
		"application/dns-message; charset=utf-8",
		"application/dns-message; charset=UTF-8",
		"application/dns-message;boundary=something",
	} {
		req := httptest.NewRequest(http.MethodPost, "/dns-query", bytes.NewReader(wire))
		req.Header.Set("Content-Type", ct)
		rec := httptest.NewRecorder()

		s.dohHandler(rec, req)

		if rec.Code != http.StatusOK {
			t.Errorf("Content-Type %q: status = %d, want 200", ct, rec.Code)
		}
	}
}

// TestDoH_POST_WrongContentType verifies that a wrong media type returns 415.
func TestDoH_POST_WrongContentType(t *testing.T) {
	h := &stubHandler{reply: new(dns.Msg)}
	s := &Servers{cfg: Config{}, handler: h}

	wire := makeDNSQuery("example.com")

	for _, ct := range []string{
		"text/plain",
		"application/json",
		"",
		"not-a-valid/media-type(",
	} {
		req := httptest.NewRequest(http.MethodPost, "/dns-query", bytes.NewReader(wire))
		req.Header.Set("Content-Type", ct)
		rec := httptest.NewRecorder()

		s.dohHandler(rec, req)

		if rec.Code != http.StatusUnsupportedMediaType {
			t.Errorf("Content-Type %q: status = %d, want 415", ct, rec.Code)
		}
	}
}
