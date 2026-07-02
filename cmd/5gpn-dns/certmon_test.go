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

// writeCertWithExpiry writes a self-signed cert with the given NotAfter and
// returns its path.
func writeCertWithExpiry(t *testing.T, notAfter time.Time) string {
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
	p := filepath.Join(t.TempDir(), "cert.pem")
	f, err := os.Create(p)
	if err != nil {
		t.Fatalf("create file: %v", err)
	}
	if err := pem.Encode(f, &pem.Block{Type: "CERTIFICATE", Bytes: der}); err != nil {
		t.Fatalf("encode: %v", err)
	}
	_ = f.Close()
	return p
}

func TestCertMonitorStatus(t *testing.T) {
	t.Run("valid cert reports days remaining, not expired", func(t *testing.T) {
		na := time.Now().Add(10 * 24 * time.Hour)
		m := newCertMonitor(writeCertWithExpiry(t, na), 14*24*time.Hour)
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
		m := newCertMonitor(writeCertWithExpiry(t, na), 14*24*time.Hour)
		m.check(time.Now())
		st, ok := m.status()
		if !ok {
			t.Fatal("status should be loaded")
		}
		if !st.Expired {
			t.Error("cert should be expired")
		}
	})

	t.Run("missing cert file is not loaded", func(t *testing.T) {
		m := newCertMonitor(filepath.Join(t.TempDir(), "nope.pem"), 14*24*time.Hour)
		m.check(time.Now())
		if _, ok := m.status(); ok {
			t.Error("status should not be loaded for a missing cert file")
		}
	})

	t.Run("leafNotAfter parses the notAfter", func(t *testing.T) {
		na := time.Now().Add(30 * 24 * time.Hour).Truncate(time.Second)
		got, err := leafNotAfter(writeCertWithExpiry(t, na))
		if err != nil {
			t.Fatalf("leafNotAfter: %v", err)
		}
		if !got.Equal(na.UTC()) {
			t.Errorf("notAfter = %v, want %v", got, na.UTC())
		}
	})
}
