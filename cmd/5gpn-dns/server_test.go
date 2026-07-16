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

// stubHandler is a minimal dns.Handler that echoes a canned reply.
type stubHandler struct {
	reply *dns.Msg
}

func (s *stubHandler) ServeDNS(w dns.ResponseWriter, r *dns.Msg) {
	m := s.reply.Copy()
	m.SetReply(r)
	_ = w.WriteMsg(m)
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

// TestDoT_ALPN_dot asserts the DoT listener advertises ALPN "dot" (RFC 7858):
// DoT clients that offer it (kdig, Android Private DNS) must complete the
// handshake with "dot" negotiated. Historically this regressed when another
// TLS listener's http.Server mutated a SHARED tls.Config's NextProtos; DoT now
// owns its config, and this test keeps the ALPN contract locked either way.
func TestDoT_ALPN_dot(t *testing.T) {
	certFile, keyFile := writeTestCert(t)
	h := &stubHandler{reply: new(dns.Msg)}

	cfg := Config{
		ListenDoT: "127.0.0.1:19853",
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

// TestNewServersCertLoadGate covers the boot-time cert probe. A cert that
// cannot be loaded (paths set but file missing/corrupt) must DEGRADE, not die
// (review #2): NewServers still succeeds and records the error via
// CertLoadErr() so the process keeps running and the DoT listener auto-recovers —
// this box is the network's only resolver. Missing cert *paths* with a TLS
// listener configured is a distinct config error and stays fatal.
func TestNewServersCertLoadGate(t *testing.T) {
	h := &stubHandler{reply: new(dns.Msg)}

	t.Run("unloadable cert files → degrade, not fatal", func(t *testing.T) {
		cfg := Config{
			ListenDoT: "127.0.0.1:0",
			CertFile:  filepath.Join(t.TempDir(), "nope-cert.pem"),
			KeyFile:   filepath.Join(t.TempDir(), "nope-key.pem"),
		}
		srvs, err := NewServers(cfg, h)
		if err != nil {
			t.Fatalf("NewServers must NOT fail on an unloadable cert (degrade): %v", err)
		}
		if srvs.CertLoadErr() == nil {
			t.Error("CertLoadErr() should record the boot-time cert failure")
		}
		if srvs.dotTLSCfg == nil {
			t.Error("DoT TLS config must still be wired after the degrade (listeners auto-recover), got nil")
		}
	})

	t.Run("valid cert → ok, no cert error", func(t *testing.T) {
		certFile, keyFile := writeTestCert(t)
		cfg := Config{ListenDoT: "127.0.0.1:0", CertFile: certFile, KeyFile: keyFile}
		srvs, err := NewServers(cfg, h)
		if err != nil {
			t.Fatalf("NewServers with a valid cert: %v", err)
		}
		if srvs.CertLoadErr() != nil {
			t.Errorf("CertLoadErr() should be nil for a valid cert, got %v", srvs.CertLoadErr())
		}
	})

	t.Run("empty cert paths with TLS listener → config error (fatal)", func(t *testing.T) {
		cfg := Config{ListenDoT: "127.0.0.1:0"} // TLS listener, no cert paths
		if _, err := NewServers(cfg, h); err == nil {
			t.Fatal("NewServers must fail when a TLS listener has no cert paths configured")
		}
	})

	t.Run("no TLS listener → no cert needed", func(t *testing.T) {
		cfg := Config{ListenDebug: "127.0.0.1:0"} // debug only, no cert
		if _, err := NewServers(cfg, h); err != nil {
			t.Fatalf("NewServers debug-only: %v", err)
		}
	})
}
