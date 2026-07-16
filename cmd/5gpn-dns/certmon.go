package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"log"
	"sync"
	"time"
)

// CertStatus is the TLS-cert expiry view exposed via the control-plane /status
// endpoint (and the Telegram bot status). It is early-warning only: an expired
// cert fails TLS handshakes; this surfaces the countdown the renewal timer does not.
type CertStatus struct {
	NotAfter      time.Time `json:"not_after"`
	DaysRemaining int       `json:"days_remaining"`
	Expired       bool      `json:"expired"`
	// Broken/Error surface a cert that currently fails to load (deleted/corrupt
	// file), so the API/bot show the degraded TLS role rather than nothing.
	Broken bool   `json:"broken,omitempty"`
	Error  string `json:"error,omitempty"`
}

// certMonitor periodically parses the served TLS cert's NotAfter, logs a
// warning as expiry approaches (and an error once expired), and exposes the
// latest expiry for the control plane. It never touches serving.
type certMonitor struct {
	certFile   string
	keyFile    string
	warnBefore time.Duration

	mu       sync.Mutex
	notAfter time.Time
	loaded   bool
	lastErr  error // set when the most recent read failed (cert broken/missing)
}

func newCertMonitor(certFile, keyFile string, warnBefore time.Duration) *certMonitor {
	return &certMonitor{certFile: certFile, keyFile: keyFile, warnBefore: warnBefore}
}

// check loads the cert the SAME way the TLS handshake does and logs/stores the
// result. now is a parameter for testability.
func (m *certMonitor) check(now time.Time) {
	// tls.LoadX509KeyPair (not a cert-file-only parse) so a key-only or
	// cert/key-mismatch fault — which leaves the cert file parseable and would
	// otherwise show falsely healthy — is caught as Broken, matching what the
	// serving path (certGetter → certCache.get) actually does.
	pair, err := tls.LoadX509KeyPair(m.certFile, m.keyFile)
	if err != nil {
		log.Printf("cert-monitor: ERROR cannot load cert+key (%s / %s): %v — the TLS listener cannot reload this role; fix it.", m.certFile, m.keyFile, err)
		m.mu.Lock()
		m.lastErr = err
		m.mu.Unlock()
		return
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		log.Printf("cert-monitor: ERROR cannot parse leaf of %s: %v", m.certFile, err)
		m.mu.Lock()
		m.lastErr = err
		m.mu.Unlock()
		return
	}
	na := leaf.NotAfter
	m.mu.Lock()
	m.notAfter = na
	m.loaded = true
	m.lastErr = nil
	m.mu.Unlock()

	switch remaining := na.Sub(now); {
	case remaining <= 0:
		log.Printf("cert-monitor: TLS cert EXPIRED %s ago (notAfter=%s) — TLS handshakes will fail. Renew now.",
			(-remaining).Round(time.Hour), na.Format(time.RFC3339))
	case remaining <= m.warnBefore:
		log.Printf("cert-monitor: TLS cert expires in %s (notAfter=%s) — confirm renewal is working.",
			remaining.Round(time.Hour), na.Format(time.RFC3339))
	}
}

// status returns the latest cert expiry view. When the most recent read failed
// it reports Broken (with the error, plus the last-known expiry if a cert was
// ever read), so the degrade is visible rather than silent. ok is false only
// before any check has run.
func (m *certMonitor) status() (CertStatus, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.lastErr != nil {
		cs := CertStatus{Broken: true, Error: m.lastErr.Error()}
		if m.loaded {
			rem := time.Until(m.notAfter)
			cs.NotAfter = m.notAfter
			cs.DaysRemaining = int(rem.Hours() / 24)
			cs.Expired = rem <= 0
		}
		return cs, true
	}
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
