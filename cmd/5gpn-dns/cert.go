package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// certState holds the last-loaded certificate and the identity of the files it
// came from, so we can detect when a renewal has replaced them.
type certState struct {
	cert    *tls.Certificate
	certMod time.Time
	keyMod  time.Time
	// certReal is certPath with symlinks resolved. Certificates are published
	// into <role>/generations/<n> behind an atomically re-pointed `current`
	// symlink, so a renewal changes which file the configured path resolves
	// to. mtime alone cannot see that: two generations written inside the same
	// filesystem timestamp tick compare equal, and the swap would go unnoticed
	// — the old certificate served indefinitely, with nothing logged, until a
	// restart. Comparing the resolved path closes that, because a swap always
	// changes it.
	certReal string
}

// certCache wraps a cached TLS certificate and reloads it when either the cert
// or key file's mtime changes.
type certCache struct {
	certPath string
	keyPath  string

	mu    sync.Mutex
	state certState
}

// get returns the current certificate, reloading from disk if either file's
// mtime has changed since the last load.
//
// If a reload attempt fails (e.g. files are mid-write during cert renewal) and
// a previously-loaded certificate is already cached, the stale certificate is
// returned so that in-flight TLS handshakes continue to succeed.  An error is
// only returned when there is no cached certificate at all (first-load failure).
func (c *certCache) get(_ *tls.ClientHelloInfo) (*tls.Certificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	certInfo, err := os.Stat(c.certPath)
	if err != nil {
		if c.state.cert != nil {
			log.Printf("cert: stat %s: %v — serving stale cert", c.certPath, err)
			return c.state.cert, nil
		}
		return nil, fmt.Errorf("cert: stat %s: %w", c.certPath, err)
	}
	keyInfo, err := os.Stat(c.keyPath)
	if err != nil {
		if c.state.cert != nil {
			log.Printf("cert: stat %s: %v — serving stale cert", c.keyPath, err)
			return c.state.cert, nil
		}
		return nil, fmt.Errorf("cert: stat %s: %w", c.keyPath, err)
	}

	// EvalSymlinks failing is not itself a reason to reload or to fail: fall
	// back to the configured path so the mtime comparison still applies. A
	// renewal mid-swap can briefly leave the link unresolvable.
	certReal, err := filepath.EvalSymlinks(c.certPath)
	if err != nil {
		certReal = c.certPath
	}

	// Use cached certificate if neither file has been modified AND the path
	// still resolves to the same file.
	if c.state.cert != nil &&
		certReal == c.state.certReal &&
		certInfo.ModTime().Equal(c.state.certMod) &&
		keyInfo.ModTime().Equal(c.state.keyMod) {
		return c.state.cert, nil
	}

	// Reload.
	cert, err := tls.LoadX509KeyPair(c.certPath, c.keyPath)
	if err != nil {
		if c.state.cert != nil {
			log.Printf("cert: load %s / %s: %v — serving stale cert", c.certPath, c.keyPath, err)
			return c.state.cert, nil
		}
		return nil, fmt.Errorf("cert: load %s / %s: %w", c.certPath, c.keyPath, err)
	}
	c.state = certState{
		cert:     &cert,
		certMod:  certInfo.ModTime(),
		keyMod:   keyInfo.ModTime(),
		certReal: certReal,
	}
	return c.state.cert, nil
}

// certGetter returns a GetCertificate callback that loads certPath/keyPath on
// first call and reloads them whenever either file's mtime changes.  The
// callback itself is lazy (it loads on first invocation); NewServers invokes it
// once at startup to detect a broken cert and log loudly, but does NOT fail the
// boot on it (review #2 degrade): the TLS listeners bind and this callback
// re-attempts the load on every subsequent handshake, so a cert that is broken
// at boot AUTO-RECOVERS on the next successful on-disk load — no restart.
//
// The returned function is safe for concurrent use; only one goroutine reloads
// at a time.
func certGetter(certPath, keyPath string) func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	cc := &certCache{certPath: certPath, keyPath: keyPath}
	return cc.get
}
