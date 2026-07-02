package main

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"log"
	"os"
	"sync"
	"time"
)

// CertStatus is the TLS-cert expiry view exposed via the control-plane /status
// endpoint (and the Telegram bot status). It is early-warning only: an expired
// cert still fails DoT/DoH at the TLS layer while plain :53 keeps serving — this
// surfaces the countdown the renewal timer doesn't.
type CertStatus struct {
	NotAfter      time.Time `json:"not_after"`
	DaysRemaining int       `json:"days_remaining"`
	Expired       bool      `json:"expired"`
}

// certMonitor periodically parses the served TLS cert's NotAfter, logs a
// warning as expiry approaches (and an error once expired), and exposes the
// latest expiry for the control plane. It never touches serving.
type certMonitor struct {
	certFile   string
	warnBefore time.Duration

	mu       sync.Mutex
	notAfter time.Time
	loaded   bool
}

func newCertMonitor(certFile string, warnBefore time.Duration) *certMonitor {
	return &certMonitor{certFile: certFile, warnBefore: warnBefore}
}

// leafNotAfter parses the first CERTIFICATE block in a PEM file (the leaf, which
// certbot/openssl emit first in fullchain.pem) and returns its NotAfter.
func leafNotAfter(certFile string) (time.Time, error) {
	data, err := os.ReadFile(certFile)
	if err != nil {
		return time.Time{}, err
	}
	for len(data) > 0 {
		var block *pem.Block
		block, data = pem.Decode(data)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		crt, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return time.Time{}, err
		}
		return crt.NotAfter, nil
	}
	return time.Time{}, fmt.Errorf("no certificate found in %s", certFile)
}

// check reads the cert and logs according to time remaining, storing notAfter
// for status reporting. now is a parameter for testability.
func (m *certMonitor) check(now time.Time) {
	na, err := leafNotAfter(m.certFile)
	if err != nil {
		log.Printf("cert-monitor: cannot read cert %s: %v", m.certFile, err)
		m.mu.Lock()
		m.loaded = false
		m.mu.Unlock()
		return
	}
	m.mu.Lock()
	m.notAfter = na
	m.loaded = true
	m.mu.Unlock()

	switch remaining := na.Sub(now); {
	case remaining <= 0:
		log.Printf("cert-monitor: TLS cert EXPIRED %s ago (notAfter=%s) — DoT/DoH handshakes will fail; plain :53 still serves. Renew now.",
			(-remaining).Round(time.Hour), na.Format(time.RFC3339))
	case remaining <= m.warnBefore:
		log.Printf("cert-monitor: TLS cert expires in %s (notAfter=%s) — confirm renewal is working.",
			remaining.Round(time.Hour), na.Format(time.RFC3339))
	}
}

// status returns the latest cert expiry view; ok is false until a cert has been
// successfully read at least once.
func (m *certMonitor) status() (CertStatus, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.loaded {
		return CertStatus{}, false
	}
	rem := time.Until(m.notAfter)
	return CertStatus{
		NotAfter:      m.notAfter,
		DaysRemaining: int(rem.Hours() / 24), // truncated toward zero; negative once expired
		Expired:       rem <= 0,
	}, true
}

// Run does one immediate check, then re-checks on interval until ctx is done.
func (m *certMonitor) Run(ctx context.Context, interval time.Duration) {
	m.check(time.Now())
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			m.check(time.Now())
		}
	}
}
