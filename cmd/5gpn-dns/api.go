package main

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

// version identifies the running build for GET /api/status. Left at "dev" for
// now; wiring an ldflags override is a later task.
var version = "dev"

// ControlServer is the Phase-3 HTTPS control plane: a REST API over
// Controller (bearer-token authenticated) plus the embedded SPA. It is a
// separate listener from the DNS-facing DoT/DoH servers (Servers in
// server.go) — different port, different purpose (admin, not resolution).
type ControlServer struct {
	srv       *http.Server
	ctrl      *Controller
	token     string
	startTime time.Time
	limiter   *rateLimiter
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

	s := &ControlServer{
		ctrl:      ctrl,
		token:     cfg.APIToken,
		startTime: time.Now(),
		limiter:   newRateLimiter(cfg.APIRate, cfg.APIBurst),
	}

	webUI, err := newWebUIHandler()
	if err != nil {
		return nil, fmt.Errorf("control server: %w", err)
	}

	mux := http.NewServeMux()
	mux.Handle("/api/", s.rateLimitMiddleware(s.auditMiddleware(s.authMiddleware(s.apiMux()))))
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

// maxAPIBodyBytes caps request bodies read by the control-plane API, so a
// misbehaving/malicious caller can't exhaust memory with an oversized body.
const maxAPIBodyBytes = 1 << 20 // 1 MiB

// apiMux builds the /api/* routes: the full Phase-3 REST surface over
// Controller (status/stats/lookup/subscriptions/rules/update/reload).
func (s *ControlServer) apiMux() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/status", s.handleStatus)
	mux.HandleFunc("GET /api/stats", s.handleStats)
	mux.HandleFunc("GET /api/lookup", s.handleLookup)

	mux.HandleFunc("GET /api/subscriptions", s.handleSubscriptionsList)
	mux.HandleFunc("POST /api/subscriptions", s.handleSubscriptionsCreate)
	mux.HandleFunc("PATCH /api/subscriptions/{id}", s.handleSubscriptionsReplace)
	mux.HandleFunc("DELETE /api/subscriptions/{id}", s.handleSubscriptionsDelete)

	mux.HandleFunc("POST /api/update", s.handleUpdate)

	mux.HandleFunc("GET /api/rules/{cat}", s.handleRulesList)
	mux.HandleFunc("POST /api/rules/{cat}", s.handleRulesAdd)
	mux.HandleFunc("DELETE /api/rules/{cat}", s.handleRulesRemove)

	mux.HandleFunc("POST /api/reload", s.handleReload)

	return mux
}

// handleStatus reports build/runtime identity plus a stats snapshot.
func (s *ControlServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"version":        version,
		"uptime_seconds": int(time.Since(s.startTime).Seconds()),
		"stats":          s.ctrl.Stats(),
	}
	if cs, ok := s.ctrl.CertStatus(); ok {
		resp["cert"] = cs
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleStats returns the raw Stats snapshot.
func (s *ControlServer) handleStats(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.ctrl.Stats())
}

// handleLookup runs a manual name classification/lookup. domain is required.
func (s *ControlServer) handleLookup(w http.ResponseWriter, r *http.Request) {
	domain := strings.TrimSpace(r.URL.Query().Get("domain"))
	if domain == "" {
		writeErr(w, http.StatusBadRequest, "missing required query parameter: domain")
		return
	}
	writeJSON(w, http.StatusOK, s.ctrl.Lookup(r.Context(), domain))
}

// handleSubscriptionsList returns every configured subscription, each
// enriched with its last-fetch health (last-run time, ok, entry count,
// error) so the control console can show a "last update" column.
func (s *ControlServer) handleSubscriptionsList(w http.ResponseWriter, r *http.Request) {
	views := s.ctrl.SubscriptionsWithHealth()
	if views == nil {
		views = []SubscriptionView{}
	}
	writeJSON(w, http.StatusOK, views)
}

// handleSubscriptionsCreate decodes a Subscription from the body, adds it
// (validating + performing the initial fetch), and returns the resulting
// UpdateResult.
func (s *ControlServer) handleSubscriptionsCreate(w http.ResponseWriter, r *http.Request) {
	var sub Subscription
	if !decodeJSONBody(w, r, &sub) {
		return
	}

	res, err := s.ctrl.AddSubscription(sub)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// handleSubscriptionsReplace decodes a Subscription from the body, forces its
// ID to the path value (so the URL is authoritative over any ID in the
// body), and replaces any prior subscription with that ID (PATCH doubles as
// upsert when there is no prior subscription).
//
// Transactional guarantee: the new body is validated BEFORE the existing
// subscription is touched, so a well-formed-but-invalid body (bad category,
// malformed URL/name, empty format, etc.) is rejected with 400 while leaving
// the existing subscription untouched — it is never removed just to have the
// replacement fail. AddSubscription itself rejects a duplicate ID, so a
// like-for-like replace still has to remove the existing entry first; if that
// removal succeeded but the subsequent Add then fails for some other reason
// (e.g. a disk/persist error — validation has already passed by this point),
// the previous subscription is restored so the edit is atomic-ish rather than
// leaving the caller with neither the old nor the new subscription. Note a
// fetch failure inside Add is not such an error: Add returns
// UpdateResult{OK:false} in a 200 (the subscription is saved; the first fetch
// failed; Run's ticker or a later on-demand update will retry) — that path is
// unchanged.
func (s *ControlServer) handleSubscriptionsReplace(w http.ResponseWriter, r *http.Request) {
	var sub Subscription
	if !decodeJSONBody(w, r, &sub) {
		return
	}
	sub.ID = r.PathValue("id")

	if err := s.ctrl.ValidateSubscription(sub); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}

	old, had := s.ctrl.GetSubscription(sub.ID)
	_ = s.ctrl.RemoveSubscription(sub.ID)

	res, err := s.ctrl.AddSubscription(sub)
	if err != nil {
		// Residual failure after validation already passed (e.g. a disk/persist
		// error) — restore the previous subscription so the failed edit doesn't
		// also destroy the original.
		if had {
			_, _ = s.ctrl.AddSubscription(old)
		}
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// handleSubscriptionsDelete removes a subscription by path ID. A not-found
// error is mapped to 404; any other error is a 500.
func (s *ControlServer) handleSubscriptionsDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.ctrl.RemoveSubscription(id); err != nil {
		if isNotFoundErr(err) {
			writeErr(w, http.StatusNotFound, err.Error())
			return
		}
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// handleUpdate refreshes one subscription (?id=) or all of them (no id).
func (s *ControlServer) handleUpdate(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	results := s.ctrl.Update(r.Context(), id)
	if results == nil {
		results = []UpdateResult{}
	}
	writeJSON(w, http.StatusOK, results)
}

// handleRulesList lists the manual rule entries for a category.
func (s *ControlServer) handleRulesList(w http.ResponseWriter, r *http.Request) {
	cat := r.PathValue("cat")
	entries, err := s.ctrl.ListRules(cat)
	if err != nil {
		writeErr(w, ruleErrStatus(err), err.Error())
		return
	}
	if entries == nil {
		entries = []string{}
	}
	writeJSON(w, http.StatusOK, entries)
}

// ruleErrStatus maps a Controller rule error to an HTTP status: a caller
// mistake (bad category / malformed entry, wrapping ErrInvalidRule) is a 400;
// anything else (a disk read/write or reload failure while applying an
// otherwise-valid entry) is a server-side 500.
func ruleErrStatus(err error) int {
	if errors.Is(err, ErrInvalidRule) {
		return http.StatusBadRequest
	}
	return http.StatusInternalServerError
}

// ruleEntryBody is the JSON body shape for POST/DELETE /api/rules/{cat}.
type ruleEntryBody struct {
	Entry string `json:"entry"`
}

// handleRulesAdd adds a manual rule entry to a category.
func (s *ControlServer) handleRulesAdd(w http.ResponseWriter, r *http.Request) {
	cat := r.PathValue("cat")
	var body ruleEntryBody
	if !decodeJSONBody(w, r, &body) {
		return
	}
	if err := s.ctrl.AddRule(cat, body.Entry); err != nil {
		writeErr(w, ruleErrStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// handleRulesRemove removes a manual rule entry from a category. The entry
// may be given either as a JSON body ({"entry":"..."}) or as a ?entry= query
// parameter (so a DELETE without a body still works).
func (s *ControlServer) handleRulesRemove(w http.ResponseWriter, r *http.Request) {
	cat := r.PathValue("cat")

	entry := r.URL.Query().Get("entry")
	if entry == "" {
		var body ruleEntryBody
		if r.ContentLength != 0 {
			if !decodeJSONBody(w, r, &body) {
				return
			}
			entry = body.Entry
		}
	}

	if err := s.ctrl.RemoveRule(cat, entry); err != nil {
		writeErr(w, ruleErrStatus(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// handleReload rebuilds the rule sets from disk and swaps them into the live
// engine.
func (s *ControlServer) handleReload(w http.ResponseWriter, r *http.Request) {
	if err := s.ctrl.Reload(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// isNotFoundErr reports whether err looks like a "not found" outcome from the
// Controller/SubManager layer. SubManager.Remove doesn't define a sentinel
// error, so this matches on the message text it's known to produce.
func isNotFoundErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "not found")
}

// decodeJSONBody reads and JSON-decodes r.Body into dst, capping the body
// size and writing a 400 JSON error on any read/decode failure. Returns
// false (and has already written the error response) if decoding failed.
func decodeJSONBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxAPIBodyBytes)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(dst); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("invalid request body: %v", err))
		return false
	}
	return true
}

// rateLimitMiddleware enforces a per-source-IP token-bucket limit (Phase 4
// Task C1) on every /api/* request, to blunt brute-force against the bearer
// token and general abuse if the firewall is ever widened beyond CLIENT_NET.
// It is wired OUTSIDE authMiddleware (see NewControlServer) so an
// unauthenticated flood is limited too -- rate limiting must not depend on
// having already proven a valid token.
//
// The source key is derived from r.RemoteAddr (host part only, via
// net.SplitHostPort; the raw value is used as-is if that fails, e.g. in unit
// tests that set a bare RemoteAddr). X-Forwarded-For is deliberately NOT
// consulted: the control-plane listener is not behind a reverse proxy, so
// trusting a client-supplied header here would let any caller pick its own
// rate-limit bucket and defeat the whole point.
//
// When s.limiter has rate limiting disabled (APIRate <= 0), allow() always
// returns true, so this middleware is a zero-overhead passthrough.
func (s *ControlServer) rateLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}

		if !s.limiter.allow(host, time.Now()) {
			w.Header().Set("Retry-After", "1")
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "rate limited"})
			return
		}

		next.ServeHTTP(w, r)
	})
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

// writeErr writes a {"error": msg} JSON response body with the given status
// code.
func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
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
