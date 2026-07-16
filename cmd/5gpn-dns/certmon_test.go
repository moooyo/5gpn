package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeCertWithExpiry writes a self-signed cert + its matching key with the
// given NotAfter and returns both paths (certMonitor now loads the pair, like
// the TLS handshake does).
func writeCertWithExpiry(t *testing.T, notAfter time.Time) (certPath, keyPath string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen key: %v", err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test"},
		NotBefore:    notAfter.Add(-365 * 24 * time.Hour),
		NotAfter:     notAfter,
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	dir := t.TempDir()
	certPath = filepath.Join(dir, "cert.pem")
	f, err := os.Create(certPath)
	if err != nil {
		t.Fatalf("create file: %v", err)
	}
	if err := pem.Encode(f, &pem.Block{Type: "CERTIFICATE", Bytes: der}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	_ = f.Close()

	keyPath = filepath.Join(dir, "key.pem")
	kf, err := os.Create(keyPath)
	if err != nil {
		t.Fatalf("create key file: %v", err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	if err := pem.Encode(kf, &pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}); err != nil {
		t.Fatalf("encode key: %v", err)
	}
	_ = kf.Close()
	return certPath, keyPath
}

func TestCertMonitorStatus(t *testing.T) {
	t.Run("valid cert reports days remaining, not expired", func(t *testing.T) {
		na := time.Now().Add(10 * 24 * time.Hour)
		cert, key := writeCertWithExpiry(t, na)
		m := newCertMonitor(cert, key, 14*24*time.Hour)
		m.check(time.Now())
		st, ok := m.status()
		if !ok {
			t.Fatal("status should be loaded")
		}
		if st.Expired {
			t.Error("cert should not be expired")
		}
		if st.DaysRemaining < 9 || st.DaysRemaining > 10 {
			t.Errorf("DaysRemaining = %d, want ~10", st.DaysRemaining)
		}
	})

	t.Run("expired cert reports Expired", func(t *testing.T) {
		na := time.Now().Add(-1 * time.Hour)
		cert, key := writeCertWithExpiry(t, na)
		m := newCertMonitor(cert, key, 14*24*time.Hour)
		m.check(time.Now())
		st, ok := m.status()
		if !ok {
			t.Fatal("status should be loaded")
		}
		if !st.Expired {
			t.Error("cert should be expired")
		}
	})

	t.Run("missing cert file → Broken status (degrade, review #2)", func(t *testing.T) {
		m := newCertMonitor(filepath.Join(t.TempDir(), "nope.pem"), filepath.Join(t.TempDir(), "nope-key.pem"), 14*24*time.Hour)
		m.check(time.Now())
		st, ok := m.status()
		if !ok {
			t.Fatal("a failed read should surface a status (ok=true) so the degrade is visible")
		}
		if !st.Broken || st.Error == "" {
			t.Errorf("missing cert should report Broken with an error, got %+v", st)
		}
	})

	t.Run("key-only fault (cert OK, key missing) → Broken, not falsely green", func(t *testing.T) {
		// Regression for review #0: the status probe must use the same load path
		// as the handshake (cert+key), so a valid cert file with a missing/bad key
		// is Broken rather than showing a healthy expiry.
		cert, _ := writeCertWithExpiry(t, time.Now().Add(30*24*time.Hour))
		m := newCertMonitor(cert, filepath.Join(t.TempDir(), "absent-key.pem"), 14*24*time.Hour)
		m.check(time.Now())
		st, ok := m.status()
		if !ok || !st.Broken {
			t.Errorf("a valid cert with a missing key must report Broken, got ok=%v %+v", ok, st)
		}
	})

	t.Run("never checked → not loaded", func(t *testing.T) {
		m := newCertMonitor(filepath.Join(t.TempDir(), "nope.pem"), filepath.Join(t.TempDir(), "nope-key.pem"), 14*24*time.Hour)
		if _, ok := m.status(); ok {
			t.Error("status should be ok=false before any check has run")
		}
	})
}
