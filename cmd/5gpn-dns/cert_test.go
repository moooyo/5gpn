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

// generateSelfSignedCert writes a self-signed cert+key PEM pair to dir and
// returns the paths.  Fails the test on any error.
func generateSelfSignedCert(t *testing.T, dir string) (certPath, keyPath string) {
	t.Helper()

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test"},
		DNSNames:     []string{"test.local"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}

	certPath = filepath.Join(dir, "cert.pem")
	keyPath = filepath.Join(dir, "key.pem")

	certFile, err := os.Create(certPath)
	if err != nil {
		t.Fatalf("create cert file: %v", err)
	}
	defer certFile.Close()
	if err := pem.Encode(certFile, &pem.Block{Type: "CERTIFICATE", Bytes: der}); err != nil {
		t.Fatalf("encode cert: %v", err)
	}

	keyBytes, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	keyFile, err := os.Create(keyPath)
	if err != nil {
		t.Fatalf("create key file: %v", err)
	}
	defer keyFile.Close()
	if err := pem.Encode(keyFile, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes}); err != nil {
		t.Fatalf("encode key: %v", err)
	}

	return certPath, keyPath
}

// TestCertCache_StaleFallback verifies that after a successful initial load,
// a subsequent reload failure (e.g. cert files removed mid-renewal) causes
// get() to return the previously-cached certificate rather than an error.
func TestCertCache_StaleFallback(t *testing.T) {
	dir := t.TempDir()
	certPath, keyPath := generateSelfSignedCert(t, dir)

	cc := &certCache{certPath: certPath, keyPath: keyPath}

	// First call — should load successfully.
	cert1, err := cc.get(nil)
	if err != nil {
		t.Fatalf("initial get failed: %v", err)
	}
	if cert1 == nil {
		t.Fatal("initial get returned nil cert")
	}

	// Simulate a transient failure: point the cache at non-existent paths.
	// The state still holds the previously-loaded cert.
	cc.certPath = filepath.Join(dir, "missing-cert.pem")
	cc.keyPath = filepath.Join(dir, "missing-key.pem")

	// Second call — stat will fail, but stale cert should be returned.
	cert2, err := cc.get(nil)
	if err != nil {
		t.Fatalf("get after stat failure returned error: %v — expected stale cert", err)
	}
	if cert2 == nil {
		t.Fatal("get after stat failure returned nil cert")
	}
	// Should be the same certificate object (pointer equality).
	if cert2 != cert1 {
		t.Error("stale cert returned is not the originally-loaded cert")
	}
}

// TestCertCache_FirstLoadFailure verifies that if the very first load fails
// (no cached cert available), get() returns a non-nil error.
func TestCertCache_FirstLoadFailure(t *testing.T) {
	dir := t.TempDir()

	cc := &certCache{
		certPath: filepath.Join(dir, "absent-cert.pem"),
		keyPath:  filepath.Join(dir, "absent-key.pem"),
	}

	cert, err := cc.get(nil)
	if err == nil {
		t.Fatal("expected error on first-load failure, got nil")
	}
	if cert != nil {
		t.Errorf("expected nil cert on first-load failure, got %v", cert)
	}
}

// TestCertCache_ReloadOnMtimeChange verifies that the cert is reloaded when
// the file mtime changes (simulated by writing a new cert and touching mtime).
func TestCertCache_ReloadOnMtimeChange(t *testing.T) {
	dir := t.TempDir()
	certPath, keyPath := generateSelfSignedCert(t, dir)

	cc := &certCache{certPath: certPath, keyPath: keyPath}

	cert1, err := cc.get(nil)
	if err != nil || cert1 == nil {
		t.Fatalf("initial get: cert=%v err=%v", cert1, err)
	}

	// Write a new cert (different key) to simulate renewal.
	// Sleep briefly to ensure a different mtime.
	time.Sleep(10 * time.Millisecond)

	newKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate new key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "test-renewed"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(2 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &newKey.PublicKey, newKey)
	if err != nil {
		t.Fatalf("create renewed cert: %v", err)
	}

	// Overwrite cert file (mtime changes).
	cf, _ := os.Create(certPath)
	_ = pem.Encode(cf, &pem.Block{Type: "CERTIFICATE", Bytes: der})
	cf.Close()

	keyBytes, _ := x509.MarshalECPrivateKey(newKey)
	kf, _ := os.Create(keyPath)
	_ = pem.Encode(kf, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
	kf.Close()

	cert2, err := cc.get(nil)
	if err != nil {
		t.Fatalf("get after renewal: %v", err)
	}
	if cert2 == nil {
		t.Fatal("get after renewal returned nil")
	}

	// The leaf certificate should differ (different serial / public key).
	leaf1, _ := x509.ParseCertificate(cert1.Certificate[0])
	leaf2, _ := x509.ParseCertificate(cert2.Certificate[0])
	if leaf1.SerialNumber.Cmp(leaf2.SerialNumber) == 0 {
		t.Error("expected renewed cert to have a different serial number")
	}

	// Ensure tls.Certificate itself is a different pointer (new load).
	if cert2 == cert1 {
		t.Error("expected a new *tls.Certificate pointer after reload")
	}
}

// TestCertCache_RecoverFromFirstLoadFailure locks the load-bearing promise of
// the review #2 degrade: a certGetter whose FIRST load fails (broken/absent cert
// at boot, no cached cert) must AUTO-RECOVER — pick up the cert with no restart —
// once the files become valid on disk. A refactor that cached the first-load
// failure would silently break the sole-resolver's recovery path.
func TestCertCache_RecoverFromFirstLoadFailure(t *testing.T) {
	dir := t.TempDir()
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")
	cc := &certCache{certPath: certPath, keyPath: keyPath}

	// First load: files absent → error, no cached cert.
	if _, err := cc.get(nil); err == nil {
		t.Fatal("expected an error before the cert files exist")
	}

	// The cert appears on disk (operator fixed it / renewal landed).
	gotCert, gotKey := generateSelfSignedCert(t, dir)
	if gotCert != certPath || gotKey != keyPath {
		t.Fatalf("helper wrote to unexpected paths %s / %s", gotCert, gotKey)
	}

	// Next get must succeed WITHOUT reconstructing the cache (no restart).
	cert, err := cc.get(nil)
	if err != nil || cert == nil {
		t.Fatalf("get after the cert appeared should auto-recover, got cert=%v err=%v", cert, err)
	}
}
