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

	s := &ControlServer{ctrl: ctrl, token: cfg.APIToken, startTime: time.Now()}

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
	writeJSON(w, http.StatusOK, map[string]any{
		"version":        version,
		"uptime_seconds": int(time.Since(s.startTime).Seconds()),
		"stats":          s.ctrl.Stats(),
	})
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

// handleSubscriptionsList returns every configured subscription.
func (s *ControlServer) handleSubscriptionsList(w http.ResponseWriter, r *http.Request) {
	subs := s.ctrl.Subscriptions()
	if subs == nil {
		subs = []Subscription{}
	}
	writeJSON(w, http.StatusOK, subs)
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
// body), and adds it in place of any prior subscription with that ID.
func (s *ControlServer) handleSubscriptionsReplace(w http.ResponseWriter, r *http.Request) {
	var sub Subscription
	if !decodeJSONBody(w, r, &sub) {
		return
	}
	sub.ID = r.PathValue("id")

	// AddSubscription rejects a duplicate ID, so a like-for-like replace has
	// to remove the existing entry (if any) first. A missing subscription is
	// not an error here — PATCH doubles as upsert.
	_ = s.ctrl.RemoveSubscription(sub.ID)

	res, err := s.ctrl.AddSubscription(sub)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
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
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if entries == nil {
		entries = []string{}
	}
	writeJSON(w, http.StatusOK, entries)
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
		writeErr(w, http.StatusBadRequest, err.Error())
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
		writeErr(w, http.StatusBadRequest, err.Error())
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
