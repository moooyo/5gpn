package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// writeTestCert generates a throwaway self-signed cert+key (valid for
// 127.0.0.1 / test.local) and returns their file paths under t.TempDir().
func writeTestCert(t *testing.T) (certPath, keyPath string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen key: %v", err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test.local"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"test.local"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	dir := t.TempDir()
	certPath = filepath.Join(dir, "cert.pem")
	keyPath = filepath.Join(dir, "key.pem")

	certOut, err := os.Create(certPath)
	if err != nil {
		t.Fatalf("create cert file: %v", err)
	}
	if err := pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: der}); err != nil {
		t.Fatalf("encode cert: %v", err)
	}
	_ = certOut.Close()

	keyDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	keyOut, err := os.Create(keyPath)
	if err != nil {
		t.Fatalf("create key file: %v", err)
	}
	if err := pem.Encode(keyOut, &pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}); err != nil {
		t.Fatalf("encode key: %v", err)
	}
	_ = keyOut.Close()

	return certPath, keyPath
}

// waitDial blocks until addr accepts a TCP connection, or fails the test.
func waitDial(t *testing.T, addr string) {
	t.Helper()
	for i := 0; i < 200; i++ {
		c, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err == nil {
			_ = c.Close()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("listener %s not ready in time", addr)
}

// TestDoT_ALPN_dot is a regression test for a shared-*tls.Config bug: the DoH
// http.Server appends "h2"/"http/1.1" to its config's NextProtos when it
// enables HTTP/2. When DoT and DoH shared one *tls.Config, that mutation
// poisoned the DoT listener's ALPN set, so a DoT client offering ALPN "dot"
// (RFC 7858 — as kdig and Android Private DNS do) failed the handshake with
// no_application_protocol. DoT and DoH must use separate tls.Config values, and
// DoT must advertise "dot".
//
// It also gives server.go its first real listener-level coverage (DoT + DoH
// bind + TLS handshake), which the httptest-based DoH tests do not exercise.
func TestDoT_ALPN_dot(t *testing.T) {
	certFile, keyFile := writeTestCert(t)
	h := &stubHandler{reply: new(dns.Msg)}

	cfg := Config{
		ListenDoT: "127.0.0.1:19853",
		ListenDoH: "127.0.0.1:19443", // must be up so its HTTP/2 setup runs
		CertFile:  certFile,
		KeyFile:   keyFile,
	}
	srvs, err := NewServers(cfg, h)
	if err != nil {
		t.Fatalf("NewServers: %v", err)
	}
	if err := srvs.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		srvs.Shutdown(ctx)
	}()

	// Ensure DoH is serving first: its ListenAndServeTLS runs the HTTP/2 setup
	// that would poison a shared TLS config before we probe DoT.
	waitDial(t, "127.0.0.1:19443")
	waitDial(t, "127.0.0.1:19853")

	conn, err := tls.Dial("tcp", "127.0.0.1:19853", &tls.Config{
		InsecureSkipVerify: true, //nolint:gosec // test cert; we assert ALPN, not identity
		NextProtos:         []string{"dot"},
		ServerName:         "test.local",
	})
	if err != nil {
		t.Fatalf("DoT TLS handshake offering ALPN \"dot\" failed: %v", err)
	}
	defer conn.Close()

	if got := conn.ConnectionState().NegotiatedProtocol; got != "dot" {
		t.Errorf("negotiated ALPN = %q, want \"dot\"", got)
	}
}

// TestNewServersCertLoadGate is the startup TLS health gate: when DoT/DoH is
// configured but the cert/key cannot be loaded, NewServers must fail loudly at
// boot (so main log.Fatals) rather than defer to a silent handshake-time error
// that leaves DoT/DoH dead while the process otherwise looks healthy.
func TestNewServersCertLoadGate(t *testing.T) {
	h := &stubHandler{reply: new(dns.Msg)}

	t.Run("missing cert files → error", func(t *testing.T) {
		cfg := Config{
			ListenDoT: "127.0.0.1:0",
			CertFile:  filepath.Join(t.TempDir(), "nope-cert.pem"),
			KeyFile:   filepath.Join(t.TempDir(), "nope-key.pem"),
		}
		if _, err := NewServers(cfg, h); err == nil {
			t.Fatal("NewServers must fail when the TLS cert cannot be loaded")
		}
	})

	t.Run("valid cert → ok", func(t *testing.T) {
		certFile, keyFile := writeTestCert(t)
		cfg := Config{ListenDoH: "127.0.0.1:0", CertFile: certFile, KeyFile: keyFile}
		if _, err := NewServers(cfg, h); err != nil {
			t.Fatalf("NewServers with a valid cert: %v", err)
		}
	})

	t.Run("no TLS listener → no cert needed", func(t *testing.T) {
		cfg := Config{ListenPlain: "127.0.0.1:0"} // plain only, no cert
		if _, err := NewServers(cfg, h); err != nil {
			t.Fatalf("NewServers plain-only: %v", err)
		}
	})
}
