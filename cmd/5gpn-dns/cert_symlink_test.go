package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// writeGeneration writes a self-signed cert/key pair with the given serial into
// dir, mirroring what install.sh publishes into <role>/generations/<n>.
func writeGeneration(t *testing.T, dir string, serial int64) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: "cert-reload.test"},
		DNSNames:     []string{"cert-reload.test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	if err := os.WriteFile(filepath.Join(dir, "fullchain.pem"), certPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "privkey.pem"), keyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
}

func servedSerial(t *testing.T, cc *certCache) int64 {
	t.Helper()
	got, err := cc.get(&tls.ClientHelloInfo{ServerName: "cert-reload.test"})
	if err != nil {
		t.Fatalf("certCache.get: %v", err)
	}
	leaf, err := x509.ParseCertificate(got.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	return leaf.SerialNumber.Int64()
}

// Certificates live in <role>/generations/<n> behind an atomically re-pointed
// `current` symlink, and renew-hook.sh signals nothing when it publishes a new
// one — tests/test_renew_hook.sh asserts twice that publication must not touch
// SIGHUP or systemctl. The whole no-signal contract therefore rests on the
// daemon noticing a renewal by itself THROUGH that symlink, which had never
// been tested: certCache stats the configured path, and whether that observes
// the new generation depends on os.Stat following the link.
//
// If this ever regresses, a renewed certificate would not be served until the
// next restart, and nothing else in the system would notice.
func TestCertCacheFollowsCurrentSymlinkAcrossGenerations(t *testing.T) {
	if runtime.GOOS == "windows" {
		// Creating a symlink on Windows needs elevation or developer mode; the
		// behaviour under test is Linux-only anyway.
		t.Skip("symlink creation requires elevation on Windows")
	}
	root := t.TempDir()
	gen1 := filepath.Join(root, "generations", "1")
	gen2 := filepath.Join(root, "generations", "2")
	writeGeneration(t, gen1, 1001)
	writeGeneration(t, gen2, 1002)

	current := filepath.Join(root, "current")
	if err := os.Symlink(gen1, current); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	// The daemon is configured with the path THROUGH the symlink, exactly as
	// install.sh writes DNS_CERT=<role>/current/fullchain.pem.
	cc := &certCache{
		certPath: filepath.Join(current, "fullchain.pem"),
		keyPath:  filepath.Join(current, "privkey.pem"),
	}

	if got := servedSerial(t, cc); got != 1001 {
		t.Fatalf("initial serial = %d, want 1001", got)
	}
	// A second call must be served from cache, not reloaded.
	if got := servedSerial(t, cc); got != 1001 {
		t.Fatalf("cached serial = %d, want 1001", got)
	}

	// Publish generation 2 the way install.sh does: atomically re-point the
	// symlink. Nothing is signalled.
	tmpLink := filepath.Join(root, "current.new")
	if err := os.Symlink(gen2, tmpLink); err != nil {
		t.Fatalf("stage symlink: %v", err)
	}
	if err := os.Rename(tmpLink, current); err != nil {
		t.Fatalf("swap symlink: %v", err)
	}

	if got := servedSerial(t, cc); got != 1002 {
		t.Errorf("serial after symlink swap = %d, want 1002 — the renewed certificate "+
			"was NOT picked up, so renew-hook.sh's no-signal contract does not hold "+
			"through the generations layout", got)
	}
}

// Detection is by mtime equality, so two generations written within the same
// filesystem timestamp tick would be indistinguishable and the swap would go
// unnoticed — the renewed certificate would be served stale until a restart,
// silently. Renewals are days apart in practice, so the window is narrow, but
// it is the single assumption the no-signal contract rests on.
func TestCertCacheSwapIsNoticedEvenWhenGenerationsShareAnMtime(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink creation requires elevation on Windows")
	}
	root := t.TempDir()
	gen1 := filepath.Join(root, "generations", "1")
	gen2 := filepath.Join(root, "generations", "2")
	writeGeneration(t, gen1, 3001)
	writeGeneration(t, gen2, 3002)

	// Force both generations to carry byte-identical timestamps.
	stamp := time.Now().Add(-time.Minute).Truncate(time.Second)
	for _, dir := range []string{gen1, gen2} {
		for _, f := range []string{"fullchain.pem", "privkey.pem"} {
			if err := os.Chtimes(filepath.Join(dir, f), stamp, stamp); err != nil {
				t.Fatal(err)
			}
		}
	}

	current := filepath.Join(root, "current")
	if err := os.Symlink(gen1, current); err != nil {
		t.Fatal(err)
	}
	cc := &certCache{
		certPath: filepath.Join(current, "fullchain.pem"),
		keyPath:  filepath.Join(current, "privkey.pem"),
	}
	if got := servedSerial(t, cc); got != 3001 {
		t.Fatalf("initial serial = %d, want 3001", got)
	}

	tmpLink := filepath.Join(root, "current.new")
	if err := os.Symlink(gen2, tmpLink); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmpLink, current); err != nil {
		t.Fatal(err)
	}

	if got := servedSerial(t, cc); got != 3002 {
		t.Errorf("serial after same-mtime swap = %d, want 3002 — mtime-only detection "+
			"cannot see a generation swap when both generations share a timestamp, so a "+
			"renewal published inside one filesystem tick would be served stale until restart", got)
	}
}

// The same must hold when the files behind a stable path are replaced, which
// is the pre-generations shape and still how a role directory can be updated.
func TestCertCacheReloadsWhenFilesAreReplacedInPlace(t *testing.T) {
	dir := t.TempDir()
	writeGeneration(t, dir, 2001)
	cc := &certCache{
		certPath: filepath.Join(dir, "fullchain.pem"),
		keyPath:  filepath.Join(dir, "privkey.pem"),
	}
	if got := servedSerial(t, cc); got != 2001 {
		t.Fatalf("initial serial = %d, want 2001", got)
	}

	// certCache compares mtime for equality, so make the replacement
	// observable even on a filesystem with coarse timestamps.
	time.Sleep(10 * time.Millisecond)
	writeGeneration(t, dir, 2002)
	future := time.Now().Add(2 * time.Second)
	for _, f := range []string{"fullchain.pem", "privkey.pem"} {
		if err := os.Chtimes(filepath.Join(dir, f), future, future); err != nil {
			t.Fatal(err)
		}
	}

	if got := servedSerial(t, cc); got != 2002 {
		t.Errorf("serial after in-place replacement = %d, want 2002", got)
	}
}
