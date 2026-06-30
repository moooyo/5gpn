package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"sync"

	"github.com/miekg/dns"
)

// dummyAddr is a minimal net.Addr used by dohWriter to satisfy the dns.ResponseWriter interface.
type dummyAddr struct {
	network string
	address string
}

func (d dummyAddr) Network() string { return d.network }
func (d dummyAddr) String() string  { return d.address }

// dohWriter is a dns.ResponseWriter that captures the reply packed by
// h.ServeDNS so the DoH handler can serialize it to the HTTP response.
type dohWriter struct {
	// remote is returned by RemoteAddr to satisfy the interface.
	remote string
	// reply is set by WriteMsg.
	reply []byte
	// msg is the raw *dns.Msg if the caller needs it.
	msg *dns.Msg
}

func (w *dohWriter) LocalAddr() net.Addr  { return dummyAddr{"tcp", "local"} }
func (w *dohWriter) RemoteAddr() net.Addr { return dummyAddr{"tcp", w.remote} }
func (w *dohWriter) WriteMsg(m *dns.Msg) error {
	b, err := m.Pack()
	if err != nil {
		return err
	}
	w.reply = b
	w.msg = m
	return nil
}
func (w *dohWriter) Write(b []byte) (int, error) {
	w.reply = append([]byte(nil), b...)
	return len(b), nil
}
func (w *dohWriter) Close() error             { return nil }
func (w *dohWriter) TsigStatus() error        { return nil }
func (w *dohWriter) TsigTimersOnly(bool)      {}
func (w *dohWriter) Hijack()                  {}

// Servers holds all DNS listeners (DoT, DoH, plain UDP/TCP, debug) and
// provides Start / Shutdown lifecycle management.
type Servers struct {
	cfg     Config
	handler dns.Handler

	dnsSrvs  []*dns.Server
	httpSrv  *http.Server
	tlsCfg   *tls.Config
}

// NewServers builds a Servers value from cfg and handler.  No listeners are
// opened yet; call Start().
func NewServers(cfg Config, handler dns.Handler) (*Servers, error) {
	s := &Servers{cfg: cfg, handler: handler}

	// Build TLS config once if any TLS listener is active.
	if cfg.ListenDoT != "" || cfg.ListenDoH != "" {
		if cfg.CertFile == "" || cfg.KeyFile == "" {
			return nil, fmt.Errorf("servers: TLS listener requires DNS_CERT and DNS_KEY")
		}
		s.tlsCfg = &tls.Config{
			GetCertificate: certGetter(cfg.CertFile, cfg.KeyFile),
			MinVersion:     tls.VersionTLS12,
		}
	}

	return s, nil
}

// Start opens all configured listeners and begins serving.  Returns immediately
// after launching goroutines; errors during serve are logged but do not propagate.
// The caller should call Shutdown to stop.
func (s *Servers) Start() error {
	// ── DoT ─────────────────────────────────────────────────────────────────
	if s.cfg.ListenDoT != "" {
		srv := &dns.Server{
			Addr:      s.cfg.ListenDoT,
			Net:       "tcp-tls",
			TLSConfig: s.tlsCfg,
			Handler:   s.handler,
		}
		s.dnsSrvs = append(s.dnsSrvs, srv)
		go func() {
			if err := srv.ListenAndServe(); err != nil {
				log.Printf("DoT server (%s) stopped: %v", s.cfg.ListenDoT, err)
			}
		}()
	}

	// ── Plain UDP ────────────────────────────────────────────────────────────
	if s.cfg.ListenPlain != "" {
		srvUDP := &dns.Server{
			Addr:    s.cfg.ListenPlain,
			Net:     "udp",
			Handler: s.handler,
		}
		s.dnsSrvs = append(s.dnsSrvs, srvUDP)
		go func() {
			if err := srvUDP.ListenAndServe(); err != nil {
				log.Printf("plain UDP server (%s) stopped: %v", s.cfg.ListenPlain, err)
			}
		}()

		// ── Plain TCP ──────────────────────────────────────────────────────────
		srvTCP := &dns.Server{
			Addr:    s.cfg.ListenPlain,
			Net:     "tcp",
			Handler: s.handler,
		}
		s.dnsSrvs = append(s.dnsSrvs, srvTCP)
		go func() {
			if err := srvTCP.ListenAndServe(); err != nil {
				log.Printf("plain TCP server (%s) stopped: %v", s.cfg.ListenPlain, err)
			}
		}()
	}

	// ── Debug plain UDP ──────────────────────────────────────────────────────
	if s.cfg.ListenDebug != "" {
		srvDbg := &dns.Server{
			Addr:    s.cfg.ListenDebug,
			Net:     "udp",
			Handler: s.handler,
		}
		s.dnsSrvs = append(s.dnsSrvs, srvDbg)
		go func() {
			if err := srvDbg.ListenAndServe(); err != nil {
				log.Printf("debug UDP server (%s) stopped: %v", s.cfg.ListenDebug, err)
			}
		}()
	}

	// ── DoH ──────────────────────────────────────────────────────────────────
	if s.cfg.ListenDoH != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("/dns-query", s.dohHandler)
		s.httpSrv = &http.Server{
			Addr:      s.cfg.ListenDoH,
			Handler:   mux,
			TLSConfig: s.tlsCfg,
		}
		go func() {
			// TLSConfig already set; use ListenAndServeTLS with empty cert/key paths
			// so it uses GetCertificate.
			if err := s.httpSrv.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
				log.Printf("DoH server (%s) stopped: %v", s.cfg.ListenDoH, err)
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

	if s.httpSrv != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = s.httpSrv.Shutdown(ctx)
		}()
	}

	wg.Wait()
}

// dohHandler handles RFC 8484 DNS-over-HTTPS queries.
// Supports:
//   - GET  /dns-query?dns=<base64url-encoded wire>
//   - POST /dns-query  Content-Type: application/dns-message  body = wire
func (s *Servers) dohHandler(w http.ResponseWriter, r *http.Request) {
	var wire []byte
	var err error

	switch r.Method {
	case http.MethodGet:
		b64 := r.URL.Query().Get("dns")
		if b64 == "" {
			http.Error(w, "missing 'dns' query parameter", http.StatusBadRequest)
			return
		}
		wire, err = base64.RawURLEncoding.DecodeString(b64)
		if err != nil {
			http.Error(w, "invalid base64url in 'dns' parameter", http.StatusBadRequest)
			return
		}

	case http.MethodPost:
		if r.Header.Get("Content-Type") != "application/dns-message" {
			http.Error(w, "Content-Type must be application/dns-message", http.StatusUnsupportedMediaType)
			return
		}
		wire, err = io.ReadAll(io.LimitReader(r.Body, 65536))
		if err != nil {
			http.Error(w, "failed to read request body", http.StatusInternalServerError)
			return
		}

	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Unpack the DNS message.
	q := new(dns.Msg)
	if err := q.Unpack(wire); err != nil {
		http.Error(w, "invalid DNS message", http.StatusBadRequest)
		return
	}

	// Dispatch through the standard dns.Handler.
	dw := &dohWriter{remote: r.RemoteAddr}
	s.handler.ServeDNS(dw, q)

	if dw.reply == nil {
		http.Error(w, "no DNS reply generated", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/dns-message")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(dw.reply)
}
