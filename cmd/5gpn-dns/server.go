package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"sync"

	"github.com/miekg/dns"
)

// Servers holds the DNS listeners (DoT + the loopback debug listener) and
// provides Start / Shutdown lifecycle management. DoT is the ONLY client-facing
// transport; the debug listener is loopback plain UDP for on-box troubleshooting.
type Servers struct {
	cfg     Config
	handler dns.Handler

	dnsSrvs   []*dns.Server
	dotTLSCfg *tls.Config // DoT :853 — advertises ALPN "dot" (RFC 7858)

	// certErr records a boot-time cert load failure (non-fatal: the TLS
	// listener degrades to failing handshakes + auto-recovers; see NewServers).
	// nil when the cert loaded cleanly or no TLS listener is configured.
	certErr error
}

// CertLoadErr returns the boot-time cert load error, or nil if the cert loaded
// cleanly. The TLS listener is wired regardless (it auto-recovers). The boot
// degrade is already logged inline in NewServers and surfaced live via
// CertStatus.Broken; this accessor is a test-observability seam.
func (s *Servers) CertLoadErr() error { return s.certErr }

// NewServers builds a Servers value from cfg and handler.  No listeners are
// opened yet; call Start().
func NewServers(cfg Config, handler dns.Handler) (*Servers, error) {
	s := &Servers{cfg: cfg, handler: handler}

	if cfg.ListenDoT != "" {
		if cfg.CertFile == "" || cfg.KeyFile == "" {
			return nil, fmt.Errorf("servers: TLS listener requires DNS_CERT and DNS_KEY")
		}
		getCert := certGetter(cfg.CertFile, cfg.KeyFile)
		// Startup cert probe — DEGRADE, don't die (review #2, supersedes the
		// earlier fail-loud-and-exit gate). Force one load so a broken cert
		// (deleted/expired lineage, a wiped cert dir) is caught and LOGGED LOUDLY
		// at boot. But do NOT fail the boot: the Telegram bot and the debug
		// listener don't need the cert, and this box is the network's ONLY
		// resolver — crash-looping over a cert-only fault would take the whole
		// LAN's DNS down. The DoT listener is still wired (lazy GetCertificate
		// below): it binds and fails handshakes until the cert is valid, then
		// auto-recovers on the next mtime reload — no restart. certMonitor keeps
		// warning and CertStatus.Broken surfaces it to the API/bot, so this is
		// loud, not silent (a387338's original concern).
		if _, err := getCert(nil); err != nil {
			log.Printf("ERROR: TLS cert load failed at boot (%v) — DoT will fail handshakes until the cert is valid. Fix the cert; the TLS listener auto-recovers on the next successful load.", err)
			s.certErr = err
		}
		s.dotTLSCfg = &tls.Config{
			GetCertificate: getCert,
			MinVersion:     tls.VersionTLS12,
			NextProtos:     []string{"dot"}, // RFC 7858
		}
	}

	return s, nil
}

// Start opens all configured listeners and begins serving. Binds happen
// synchronously so a bind failure (port already taken, bad address) returns an
// error and the caller can fail loudly — a silently-dead :853 with the
// process reporting healthy (systemd active, watchdog fed, heartbeat pinging)
// is the worst failure mode for the network's only resolver. Errors during
// serve (after a successful bind) are logged but do not propagate. The caller
// should call Shutdown to stop.
func (s *Servers) Start() error {
	// ── DoT ─────────────────────────────────────────────────────────────────
	if s.cfg.ListenDoT != "" {
		ln, err := tls.Listen("tcp", s.cfg.ListenDoT, s.dotTLSCfg)
		if err != nil {
			return fmt.Errorf("DoT listen %s: %w", s.cfg.ListenDoT, err)
		}
		srv := &dns.Server{Listener: ln, Handler: s.handler}
		s.dnsSrvs = append(s.dnsSrvs, srv)
		go func() {
			if err := srv.ActivateAndServe(); err != nil {
				log.Printf("DoT server (%s) stopped: %v", s.cfg.ListenDoT, err)
			}
		}()
	}

	// ── Debug plain UDP (loopback-only troubleshooting) ──────────────────────
	if s.cfg.ListenDebug != "" {
		pc, err := net.ListenPacket("udp", s.cfg.ListenDebug)
		if err != nil {
			return fmt.Errorf("debug UDP listen %s: %w", s.cfg.ListenDebug, err)
		}
		srvDbg := &dns.Server{PacketConn: pc, Handler: s.handler}
		s.dnsSrvs = append(s.dnsSrvs, srvDbg)
		go func() {
			if err := srvDbg.ActivateAndServe(); err != nil {
				log.Printf("debug UDP server (%s) stopped: %v", s.cfg.ListenDebug, err)
			}
		}()
	}

	return nil
}

// Shutdown gracefully stops all listeners within the deadline in ctx.
func (s *Servers) Shutdown(ctx context.Context) {
	var wg sync.WaitGroup

	for _, srv := range s.dnsSrvs {
		srv := srv
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = srv.ShutdownContext(ctx)
		}()
	}

	wg.Wait()
}
