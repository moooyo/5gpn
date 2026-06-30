package main

import (
	"crypto/tls"
	"fmt"
	"os"
	"sync"
	"time"
)

// certState holds the last-loaded certificate and the file modification times
// at which it was loaded, so we can detect when a renewal has replaced the files.
type certState struct {
	cert     *tls.Certificate
	certMod  time.Time
	keyMod   time.Time
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
func (c *certCache) get(_ *tls.ClientHelloInfo) (*tls.Certificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	certInfo, err := os.Stat(c.certPath)
	if err != nil {
		return nil, fmt.Errorf("cert: stat %s: %w", c.certPath, err)
	}
	keyInfo, err := os.Stat(c.keyPath)
	if err != nil {
		return nil, fmt.Errorf("cert: stat %s: %w", c.keyPath, err)
	}

	// Use cached certificate if files have not been modified.
	if c.state.cert != nil &&
		certInfo.ModTime().Equal(c.state.certMod) &&
		keyInfo.ModTime().Equal(c.state.keyMod) {
		return c.state.cert, nil
	}

	// Reload.
	cert, err := tls.LoadX509KeyPair(c.certPath, c.keyPath)
	if err != nil {
		return nil, fmt.Errorf("cert: load %s / %s: %w", c.certPath, c.keyPath, err)
	}
	c.state = certState{
		cert:    &cert,
		certMod: certInfo.ModTime(),
		keyMod:  keyInfo.ModTime(),
	}
	return c.state.cert, nil
}

// certGetter returns a GetCertificate callback that loads certPath/keyPath on
// first call and reloads them whenever either file's mtime changes.  The
// initial load is deferred to the first TLS handshake — files need not exist
// until the server starts accepting connections.
//
// The returned function is safe for concurrent use; only one goroutine reloads
// at a time.
func certGetter(certPath, keyPath string) func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	cc := &certCache{certPath: certPath, keyPath: keyPath}
	return cc.get
}
