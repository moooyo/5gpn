package main

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
)

// ControlServer is the Phase-3 HTTPS control plane: a REST API over
// Controller (bearer-token authenticated) plus the embedded SPA. It is a
// separate listener from the DNS-facing DoT/DoH servers (Servers in
// server.go) — different port, different purpose (admin, not resolution).
type ControlServer struct {
	srv   *http.Server
	ctrl  *Controller
	token string
}

// NewControlServer builds a ControlServer from cfg and ctrl.
//
// If cfg.APIToken is empty the control plane is intentionally disabled —
// serving an unauthenticated admin API would be worse than not serving one at
// all — and NewControlServer returns (nil, nil) so callers can treat that as
// "nothing to start" rather than an error.
//
// When enabled, cfg.CertFile and cfg.KeyFile are required (mirroring how the
// DNS servers require certs for their TLS listeners in NewServers): the
// control plane is HTTPS-only.
func NewControlServer(cfg Config, ctrl *Controller) (*ControlServer, error) {
	if cfg.APIToken == "" {
		return nil, nil
	}
	if cfg.CertFile == "" || cfg.KeyFile == "" {
		return nil, fmt.Errorf("control server: DNS_CERT and DNS_KEY are required when DNS_API_TOKEN is set")
	}

	s := &ControlServer{ctrl: ctrl, token: cfg.APIToken}

	webUI, err := newWebUIHandler()
	if err != nil {
		return nil, fmt.Errorf("control server: %w", err)
	}

	mux := http.NewServeMux()
	mux.Handle("/api/", s.authMiddleware(s.apiMux()))
	mux.Handle("/", webUI)

	s.srv = &http.Server{
		Addr:    cfg.ListenAPI,
		Handler: mux,
		TLSConfig: &tls.Config{
			GetCertificate: certGetter(cfg.CertFile, cfg.KeyFile),
			MinVersion:     tls.VersionTLS12,
		},
	}

	return s, nil
}

// apiMux builds the /api/* routes. Task 3 fills in the real REST endpoints
// (subscriptions/rules/update/reload/lookup/stats); for now a single
// placeholder route gives the auth middleware something to protect and
// exercises the end-to-end request path.
func (s *ControlServer) apiMux() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	return mux
}

// authMiddleware requires a valid "Authorization: Bearer <token>" header on
// every request, comparing the presented token to s.token in constant time
// (crypto/subtle) to avoid leaking the token's value via response-timing
// side channels. Missing, malformed, or mismatched tokens get 401 with a
// small JSON error body.
func (s *ControlServer) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		const prefix = "Bearer "
		auth := r.Header.Get("Authorization")

		var presented string
		if strings.HasPrefix(auth, prefix) {
			presented = strings.TrimPrefix(auth, prefix)
		}

		// Constant-time compare against the real token. subtle.ConstantTimeCompare
		// requires equal-length slices to be meaningful; a length mismatch is
		// itself not a secret worth protecting (token lengths aren't sensitive),
		// but we still route both the equal- and unequal-length cases through
		// the same rejection path so there's no early-return shortcut based on
		// presented's length.
		ok := len(presented) == len(s.token) &&
			subtle.ConstantTimeCompare([]byte(presented), []byte(s.token)) == 1

		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}

		next.ServeHTTP(w, r)
	})
}

// writeJSON writes v as a JSON response body with the given status code.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// Start begins serving HTTPS on cfg.ListenAPI in a background goroutine and
// returns once the listener is bound (or returns the bind error directly).
// Mirrors the DoH listener pattern in server.go: TLSConfig.GetCertificate is
// already set, so ListenAndServeTLS is called with empty cert/key paths.
func (s *ControlServer) Start() error {
	ln, err := tls.Listen("tcp", s.srv.Addr, s.srv.TLSConfig)
	if err != nil {
		return fmt.Errorf("control server: listen %s: %w", s.srv.Addr, err)
	}
	go func() {
		if err := s.srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("control server (%s) stopped: %v", s.srv.Addr, err)
		}
	}()
	return nil
}

// Shutdown gracefully stops the control server within ctx's deadline.
func (s *ControlServer) Shutdown(ctx context.Context) error {
	return s.srv.Shutdown(ctx)
}
