package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// startUDPTCPResolver spins a tiny miekg dns server on a random loopback UDP
// AND TCP port that answers name->ip. If truncateUDP is set, the UDP path
// returns a TC=1 empty response so the client must retry over TCP (where the
// real answer is served). Returns "127.0.0.1:port" and a stop func.
func startUDPTCPResolver(t *testing.T, name, ip string, truncateUDP bool) (string, func()) {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("udp listen: %v", err)
	}
	addr := pc.LocalAddr().String()
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		pc.Close()
		t.Fatalf("tcp listen: %v", err)
	}

	handler := func(isTCP bool) dns.HandlerFunc {
		return func(w dns.ResponseWriter, r *dns.Msg) {
			m := new(dns.Msg)
			m.SetReply(r)
			if truncateUDP && !isTCP {
				m.Truncated = true
				_ = w.WriteMsg(m)
				return
			}
			m.Answer = append(m.Answer, &dns.A{
				Hdr: dns.RR_Header{Name: r.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
				A:   net.ParseIP(ip).To4(),
			})
			_ = w.WriteMsg(m)
		}
	}
	udpSrv := &dns.Server{PacketConn: pc, Handler: handler(false)}
	tcpSrv := &dns.Server{Listener: ln, Handler: handler(true)}
	go func() { _ = udpSrv.ActivateAndServe() }()
	go func() { _ = tcpSrv.ActivateAndServe() }()
	return addr, func() {
		_ = udpSrv.Shutdown()
		_ = tcpSrv.Shutdown()
	}
}

// TestBrokerFallback_PlainUDP builds a fallback exchanger from a plain-IPv4
// XRAY_RESOLVER (host:port) and verifies it resolves over UDP.
func TestBrokerFallback_PlainUDP(t *testing.T) {
	addr, stop := startUDPTCPResolver(t, "example.com.", "203.0.113.7", false)
	defer stop()

	ex, closer, err := buildBrokerFallbackExchanger(addr, nil)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if closer != nil {
		defer closer.Close()
	}

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	resp, err := ex.Exchange(ctx, q)
	if err != nil {
		t.Fatalf("exchange: %v", err)
	}
	if len(resp.Answer) != 1 {
		t.Fatalf("answers = %d, want 1", len(resp.Answer))
	}
}

// TestBrokerFallback_TCFallback verifies a truncated UDP answer triggers the
// TCP retry (reusing the tested udpTransport TC->TCP path).
func TestBrokerFallback_TCFallback(t *testing.T) {
	addr, stop := startUDPTCPResolver(t, "example.com.", "203.0.113.9", true)
	defer stop()

	ex, closer, err := buildBrokerFallbackExchanger(addr, nil)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if closer != nil {
		defer closer.Close()
	}
	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	resp, err := ex.Exchange(ctx, q)
	if err != nil {
		t.Fatalf("exchange: %v", err)
	}
	if resp.Truncated {
		t.Fatalf("response still truncated; TC->TCP retry did not happen")
	}
	if len(resp.Answer) != 1 {
		t.Fatalf("answers = %d, want 1", len(resp.Answer))
	}
}

// TestBrokerFallback_BarePlainIPv4NoPort accepts a bare IPv4 with no port and
// defaults to :53.
func TestBrokerFallback_BarePlainIPv4DefaultsPort53(t *testing.T) {
	ex, _, err := buildBrokerFallbackExchanger("198.51.100.1", nil)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if ex == nil {
		t.Fatal("nil exchanger")
	}
}

// mkDoHTestCert makes a self-signed cert valid for the given DNS name and
// returns the tls.Certificate plus a client tls.Config that trusts it.
func mkDoHTestCert(t *testing.T, name string) (tls.Certificate, *tls.Config) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("genkey: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("createcert: %v", err)
	}
	leaf, _ := x509.ParseCertificate(der)
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv, Leaf: leaf}
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return cert, &tls.Config{RootCAs: pool}
}

// TestBrokerFallback_DoH builds a fallback from an https DoH URL. The URL
// hostname is resolved to a bootstrap IP via the injected lookup, the final
// request dials that IP directly while preserving TLS SNI/Host.
func TestBrokerFallback_DoH(t *testing.T) {
	var gotSNI string
	answer := mkA(t, "example.com", "203.0.113.20")
	wire, _ := answer.Pack()

	cert, clientTLS := mkDoHTestCert(t, "doh.test")
	ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(wire)
	}))
	ts.TLS = &tls.Config{
		GetCertificate: func(chi *tls.ClientHelloInfo) (*tls.Certificate, error) {
			gotSNI = chi.ServerName
			return &cert, nil
		},
	}
	ts.StartTLS()
	defer ts.Close()

	_, port, _ := net.SplitHostPort(strings.TrimPrefix(ts.URL, "https://"))
	dohURL := "https://doh.test:" + port + "/dns-query"
	lookup := func(host string) ([]net.IP, error) {
		if host != "doh.test" {
			return nil, errors.New("unexpected host " + host)
		}
		return []net.IP{net.ParseIP("127.0.0.1")}, nil
	}

	ex, closer, err := buildBrokerFallbackExchangerTLS(dohURL, lookup, clientTLS)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if closer != nil {
		defer closer.Close()
	}

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	resp, err := ex.Exchange(ctx, q)
	if err != nil {
		t.Fatalf("exchange: %v", err)
	}
	if len(resp.Answer) != 1 {
		t.Fatalf("answers = %d, want 1", len(resp.Answer))
	}
	if gotSNI != "doh.test" {
		t.Fatalf("SNI = %q, want doh.test (must preserve TLS SNI to the URL hostname)", gotSNI)
	}
}

// TestBrokerFallback_DoHBootstrapFailFatal: a DoH URL whose hostname cannot
// be resolved to any bootstrap IP fails loudly at build time (fail-loud).
func TestBrokerFallback_DoHBootstrapFailFatal(t *testing.T) {
	lookup := func(string) ([]net.IP, error) { return nil, errors.New("no such host") }
	_, _, err := buildBrokerFallbackExchanger("https://doh.test/dns-query", lookup)
	if err == nil {
		t.Fatal("build must fail when DoH bootstrap resolution fails")
	}
}

// TestBrokerFallback_DoHNoCredentialLeak: a DoH URL carrying a query
// credential must never appear verbatim in a build error.
func TestBrokerFallback_DoHNoCredentialLeak(t *testing.T) {
	lookup := func(string) ([]net.IP, error) { return nil, errors.New("no such host") }
	_, _, err := buildBrokerFallbackExchanger("https://doh.test/dns-query?token=SECRET123", lookup)
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(err.Error(), "SECRET123") {
		t.Fatalf("error leaked credential: %v", err)
	}
}

// --- broker lifecycle ---

func TestEgressDNSBroker_UsesConfiguredResolver(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.30")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())

	resp := exchangeUDP(t, b.UDPAddr().String(), "example.com")
	if resp.Rcode != dns.RcodeSuccess || len(resp.Answer) != 1 {
		t.Fatalf("fallback answer rcode=%d answers=%d", resp.Rcode, len(resp.Answer))
	}
	if fake.callCount() != 1 {
		t.Fatalf("fallback calls = %d, want 1", fake.callCount())
	}
}

func TestEgressDNSBroker_NoResolverServfails(t *testing.T) {
	b := NewEgressDNSBroker("127.0.0.1:0", nil)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())
	resp := exchangeUDP(t, b.UDPAddr().String(), "example.com")
	if resp.Rcode != dns.RcodeServerFailure {
		t.Fatalf("rcode=%d, want SERVFAIL", resp.Rcode)
	}
}

var _ Exchanger = (*brokerFakeExchanger)(nil)

func TestNewDefaultEgressDNSBroker(t *testing.T) {
	cfg := Config{EgressBrokerAddr: "127.0.0.1:0", XrayResolver: "198.51.100.1"}
	b, closer, err := newDefaultEgressDNSBroker(cfg)
	if err != nil {
		t.Fatalf("newDefaultEgressDNSBroker: %v", err)
	}
	if b == nil {
		t.Fatal("broker must be non-nil (mihomo depends on it)")
	}
	if closer != nil {
		_ = closer.Close()
	}
}

func TestNewDefaultEgressDNSBroker_EmptyAddrIsConfigError(t *testing.T) {
	cfg := Config{EgressBrokerAddr: "", XrayResolver: "198.51.100.1"}
	_, _, err := newDefaultEgressDNSBroker(cfg)
	if err == nil {
		t.Fatal("empty broker address must be a config error, not a silent disable")
	}
}

func TestValidateResolver(t *testing.T) {
	good := []string{"223.5.5.5", "8.8.8.8", "https://dns.google/dns-query", "https://1.1.1.1/dns-query"}
	for _, s := range good {
		if err := ValidateResolver(s); err != nil {
			t.Errorf("ValidateResolver(%q) = %v, want nil", s, err)
		}
	}
	// bare hostname, junk, out-of-range octets, non-https, IPv6 all rejected.
	bad := []string{"", "  ", "dns.google", "not-an-ip", "999.999.999.999", "http://insecure/dns-query", "ftp://x", "2001:db8::1"}
	for _, s := range bad {
		if err := ValidateResolver(s); err == nil {
			t.Errorf("ValidateResolver(%q) = nil, want an error", s)
		}
	}
}
