package main

import (
	"context"
	crand "crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
)

// version identifies the running build for GET /api/status. Release builds stamp
// it via -ldflags "-X main.version=..." (see .github/workflows/release.yml); the
// literal "dev" means a local or CI-untagged build, not missing wiring.
var version = "dev"

// init falls an unstamped ("dev") build back to the git revision recorded by
// the Go toolchain (present in any `go build` from a git checkout), so the
// console's version line identifies dev-built deployments too — "dev+abc1234"
// (with a trailing * when the working tree was dirty) instead of a bare "dev".
// `go test` binaries carry no VCS info and stay "dev".
func init() {
	if version != "dev" {
		return
	}
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return
	}
	var rev string
	var dirty bool
	for _, s := range bi.Settings {
		switch s.Key {
		case "vcs.revision":
			rev = s.Value
		case "vcs.modified":
			dirty = s.Value == "true"
		}
	}
	if len(rev) >= 7 {
		version = "dev+" + rev[:7]
		if dirty {
			version += "*"
		}
	}
}

// ControlServer is the HTTPS control plane on :18443: a REST API over
// Controller (bearer-token authenticated) plus the disk-served SPA and the
// public /ios/ profile path. It is a separate listener from the DNS-facing DoT
// server (Servers in server.go) — different port, different purpose (admin,
// not resolution). It binds loopback only (cfg.ListenAPI); mihomo fronts it
// on :443 via the SNI split and source-IP allowlisting happens there, before
// a connection ever reaches this listener.
type ControlServer struct {
	srv     *http.Server
	zashSrv *http.Server // second loopback panel (zashboard); nil when cfg.ZashListen == ""

	ctrl      *Controller
	token     string
	startTime time.Time
	limiter   *rateLimiter

	// zashDomain mirrors cfg.ZashDomain (DNS_ZASH_DOMAIN), surfaced read-only
	// via GET /api/status so the console's mihomo page can deep-link into the
	// zashboard panel without scraping location.host. Empty when unconfigured.
	zashDomain string

	// mihomoSecret mirrors cfg.MihomoSecret (DNS_MIHOMO_SECRET), surfaced on
	// the TOKEN-GATED GET /api/status (design §5.3) so an authenticated
	// console admin's "前往 zash" deep-link can carry it (URL-encoded) and
	// auto-auth into zashboard's pass-through /proxy/ mount. Never exposed
	// anywhere unauthenticated.
	mihomoSecret string

	// Mihomo raw-config editor (api_mihomo_config.go). Wired post-construction
	// via SetMihomoConfig; nil store means the
	// /api/mihomo/config* endpoints report unavailable (503) rather than
	// panicking, matching every other optional-manager idiom in this file.
	mihomoStore *MihomoConfigStore
	mihomoInfra InfraParams
	mihomoTest  mihomoTester
	mihomoCtl   mihomoController
	// mihomoProxy is the secret-injecting loopback proxy used only by the
	// authenticated health endpoint and the ticket-gated log WebSocket. It is
	// deliberately not mounted directly: exposing the raw controller subtree
	// would let any source-allowlisted visitor mutate mihomo without the console
	// bearer token.
	mihomoProxy http.Handler

	// Browser WebSockets cannot attach the console's Authorization header. A
	// bearer-authenticated POST therefore mints a short-lived, single-use ticket
	// for exactly one /proxy/logs upgrade. The ticket is removed before the
	// request is forwarded to mihomo and is never accepted for another path.
	mihomoLogTicketsMu sync.Mutex
	mihomoLogTickets   map[string]time.Time

	// mihomoAppliedAt is the last time a PUT/reset successfully hot-applied a
	// config (in-memory only; a restart forgets it). Guarded by
	// mihomoAppliedAtMu since it's read by GET and written by PUT/reset,
	// which can race.
	mihomoAppliedAtMu sync.Mutex
	mihomoAppliedAt   time.Time
}

// NewControlServer builds a ControlServer from cfg and ctrl.
//
// If cfg.APIToken is empty the control plane is intentionally disabled —
// serving an unauthenticated admin API would be worse than not serving one at
// all — and NewControlServer returns (nil, nil) so callers can treat that as
// "nothing to start" rather than an error.
//
// When enabled, cfg.WebCertFile and cfg.WebKeyFile are required (LoadConfig
// falls them back to DNS_CERT/DNS_KEY when unset): the control plane is
// HTTPS-only, serving the WEB domain's certificate.
func NewControlServer(cfg Config, ctrl *Controller) (*ControlServer, error) {
	if cfg.APIToken == "" {
		return nil, nil
	}
	// LoadConfig already falls the web cert back to the DoT cert; repeat the
	// fallback here so a directly-constructed Config (tests, embedding) gets the
	// same behavior.
	webCert, webKey := cfg.WebCertFile, cfg.WebKeyFile
	if webCert == "" || webKey == "" {
		webCert, webKey = cfg.CertFile, cfg.KeyFile
	}
	if webCert == "" || webKey == "" {
		return nil, fmt.Errorf("control server: DNS_WEB_CERT and DNS_WEB_KEY (or DNS_CERT/DNS_KEY) are required when DNS_API_TOKEN is set")
	}
	zashCert, zashKey := cfg.ZashCertFile, cfg.ZashKeyFile
	if zashCert == "" || zashKey == "" {
		zashCert, zashKey = webCert, webKey
	}

	s := &ControlServer{
		ctrl:         ctrl,
		token:        cfg.APIToken,
		startTime:    time.Now(),
		limiter:      newRateLimiter(cfg.APIRate, cfg.APIBurst),
		zashDomain:   cfg.ZashDomain,
		mihomoSecret: cfg.MihomoSecret,
	}

	webUI, err := newWebUIHandler(cfg.WebDir)
	if err != nil {
		return nil, fmt.Errorf("control server: %w", err)
	}

	var mihomoTransport http.RoundTripper
	if cfg.MihomoController != "" {
		transport, transportErr := newMihomoTransport(cfg.MihomoController, cfg.ZashDomain, zashCert)
		if transportErr != nil {
			return nil, fmt.Errorf("control server: %w", transportErr)
		}
		mihomoTransport = transport
	}

	// Secret-injecting console proxy. It is NOT exposed as a raw subtree: the
	// authenticated /api/mihomo/health handler uses it internally for /version,
	// while the only public proxy route is the single-use-ticket-gated /logs
	// WebSocket. The zash panel below keeps its separate pass-through model.
	s.mihomoProxy = newMihomoProxy(cfg.ZashDomain, cfg.MihomoSecret, "/proxy", true, mihomoTransport)

	ios := http.StripPrefix("/ios", iosHandler(cfg.WWWDir))
	mux := http.NewServeMux()
	mux.Handle("/api/", s.rateLimitMiddleware(s.auditMiddleware(s.authMiddleware(s.apiMux()))))
	// iOS .mobileconfig distribution (formerly the :8111 responder): public,
	// token-free — the profile carries no secrets (just the DoT hostname), and
	// an iPhone must be able to fetch it before it is configured for anything.
	mux.Handle("/ios/", ios)
	// WebSocket authentication is enforced by an expiring one-use ticket minted
	// through the bearer-protected API. Every other controller path is hidden.
	mux.Handle("/proxy/", s.consoleMihomoProxy())
	mux.Handle("/", webUI)

	var consoleHandler http.Handler = mux
	if cfg.ProfileDomain != "" {
		// The public bootstrap SNI bypasses the admin source-IP whitelist in
		// mihomo, so it must never be able to reach the console API or SPA. Route
		// by the TLS SNI (not merely Host, which a client can spoof) and require
		// the HTTP authority to agree before serving only /ios/.
		profileMux := http.NewServeMux()
		profileMux.Handle("/ios/", ios)
		profileMux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/" {
				http.Redirect(w, r, "/ios/", http.StatusTemporaryRedirect)
				return
			}
			http.NotFound(w, r)
		})
		consoleHandler = profileSNIRouter(cfg.ProfileDomain, mux, profileMux)
	}

	s.srv = buildPanelServer(cfg.ListenAPI, securityHeadersMiddleware(consoleHandler), webCert, webKey)

	if cfg.ZashListen != "" {
		if zashCert == "" || zashKey == "" {
			return nil, fmt.Errorf("control server: DNS_ZASH_CERT and DNS_ZASH_KEY (or DNS_WEB_CERT/DNS_CERT) are required when DNS_ZASH_LISTEN is set")
		}

		zashUI, err := newWebUIHandler(cfg.ZashDir)
		if err != nil {
			return nil, fmt.Errorf("control server: zash: %w", err)
		}

		// Pass-through proxy (inject=false): forwards the browser's own
		// Authorization unchanged instead of injecting the secret — see the
		// design §5.2 comment on consoleProxy above.
		zashProxy := newMihomoProxy(cfg.ZashDomain, cfg.MihomoSecret, "/proxy", false, mihomoTransport)

		zmux := http.NewServeMux()
		zmux.Handle("/proxy/", zashProxy)
		zmux.Handle("/", zashUI)

		s.zashSrv = buildPanelServer(cfg.ZashListen, zashSecurityHeadersMiddleware(zmux), zashCert, zashKey)
	}

	return s, nil
}

// canonicalHTTPHost normalises a TLS SNI or HTTP authority for exact routing.
// ProfileDomain is a DNS name, so lowercasing and trimming one trailing dot is
// sufficient; an optional HTTP port is removed first.
func canonicalHTTPHost(raw string) string {
	raw = strings.TrimSpace(raw)
	if host, _, err := net.SplitHostPort(raw); err == nil {
		raw = host
	}
	return strings.ToLower(strings.TrimSuffix(strings.Trim(raw, "[]"), "."))
}

// profileSNIRouter makes the public bootstrap domain a separate security
// surface while reusing the console's loopback TLS listener and wildcard cert.
// Routing on r.TLS.ServerName is load-bearing: Host alone is attacker-chosen,
// and the profile SNI deliberately bypasses the panel source-IP whitelist.
func profileSNIRouter(profileDomain string, console, profile http.Handler) http.Handler {
	want := canonicalHTTPHost(profileDomain)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sni := ""
		if r.TLS != nil {
			sni = canonicalHTTPHost(r.TLS.ServerName)
		}
		if want != "" && sni == want {
			if canonicalHTTPHost(r.Host) != want {
				http.Error(w, "misdirected request", http.StatusMisdirectedRequest)
				return
			}
			profile.ServeHTTP(w, r)
			return
		}
		console.ServeHTTP(w, r)
	})
}

// buildPanelServer constructs one *http.Server bound to addr, serving handler
// over TLS via certGetter(certFile, keyFile) (TLS 1.2 minimum). Shared by the
// console and zash panel servers, which differ only in handler/middleware
// stack and which cert pair they present.
func buildPanelServer(addr string, handler http.Handler, certFile, keyFile string) *http.Server {
	return &http.Server{
		Addr:    addr,
		Handler: handler,
		TLSConfig: &tls.Config{
			GetCertificate: certGetter(certFile, keyFile),
			MinVersion:     tls.VersionTLS12,
		},
	}
}

// securityHeadersMiddleware sets defense-in-depth response headers on the whole
// :18443 surface (API + SPA + /ios/). The console holds its bearer token in localStorage,
// so an injected script would be a full control-plane takeover — CSP is the real
// mitigation; the rest blunt MIME-sniffing and clickjacking. External hashed
// module chunks satisfy the 'self' default-src.
//
// Style policy (split directives): the production Vite build emits NO inline
// <style> elements — all CSS is extracted to external files — so
// style-src-elem is locked to 'self', closing the main CSS-injection path
// (injected <style> elements) on modern browsers. What actually needs inline
// styles is the SPA's dynamic React style={} *attributes*, which are governed
// by style-src-attr; that stays 'unsafe-inline'. The plain
// style-src 'self' 'unsafe-inline' is kept ONLY as a fallback for older
// browsers that don't understand the -elem/-attr split (their behavior is
// unchanged). Tightening style-src-attr further would require migrating the
// dynamic values to CSS custom properties first (long-term item) — do not drop
// it blind.
//
// worker-src 'self' is explicit (not just inherited from default-src): the
// PWA service worker registered at /sw.js is same-origin and would already be
// allowed by default-src 'self', but spelling it out means the SW allowance
// survives any future tightening of default-src.
//
// font-src 'self' is spelled out for the same defense-in-depth reason as
// worker-src: the bundled MiSans-VF font is same-origin and already covered
// by default-src 'self', but the explicit allowance survives any future
// tightening of default-src.
//
// connect-src 'self' is explicit for the same reason: the StatusContext poll
// fetches same-origin /api/mihomo/health, and the mihomo-logs monitoring view
// opens a ticket-gated same-origin wss:// to /proxy/logs. Both are already
// same-origin and would be allowed by default-src 'self', but spelling out
// connect-src means fetch/WebSocket allowance survives any future tightening
// of default-src, matching the worker-src/font-src precedent above.
func securityHeadersMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy",
			"default-src 'self'; img-src 'self' data:; font-src 'self'; style-src 'self' 'unsafe-inline'; style-src-elem 'self'; style-src-attr 'unsafe-inline'; worker-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Strict-Transport-Security", "max-age=31536000")
		next.ServeHTTP(w, r)
	})
}

// zashSecurityHeadersMiddleware serves the third-party zashboard dist. Its CSP
// is deliberately more permissive than the console's: zashboard ships inline
// styles, blob: workers, and may need wasm eval — the console's strict CSP would
// break it. This is acceptable because the zash panel is loopback-bound +
// allowlist-gated (mihomo :443), holds NO 5gpn bearer token (the mihomo secret
// is injected by the /proxy/ reverse-proxy, never sent to the browser), so the
// strict-CSP token-theft threat model does not apply here. Exact directive set
// is verified against the pinned zashboard on test-env (see A4 gate).
func zashSecurityHeadersMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy",
			"default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'; connect-src 'self'; worker-src 'self' blob:; font-src 'self' data:; object-src 'none'; base-uri 'self'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Strict-Transport-Security", "max-age=31536000")
		next.ServeHTTP(w, r)
	})
}

// maxAPIBodyBytes caps request bodies read by the control-plane API, so a
// misbehaving/malicious caller can't exhaust memory with an oversized body.
const maxAPIBodyBytes = 1 << 20 // 1 MiB

// apiMux builds the /api/* routes: the full REST surface over Controller
// (status/stats/lookup/upstreams/ecs/tgbot/reload/unified policy rules —
// see the NOTE below on the removed managed-
// subscription/manual-rules surface).
func (s *ControlServer) apiMux() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/status", s.handleStatus)
	mux.HandleFunc("GET /api/stats", s.handleStats)
	mux.HandleFunc("GET /api/lookup", s.handleLookup)
	mux.HandleFunc("GET /api/resolve-test", s.handleResolveTest)
	mux.HandleFunc("GET /api/querylog", s.handleQueryLog)

	mux.HandleFunc("GET /api/upstreams", s.handleUpstreamsGet)
	mux.HandleFunc("PUT /api/upstreams", s.handleUpstreamsSet)

	mux.HandleFunc("GET /api/ecs", s.handleECSGet)
	mux.HandleFunc("PUT /api/ecs", s.handleECSSet)

	mux.HandleFunc("GET /api/tgbot", s.handleTGBotGet)
	mux.HandleFunc("PUT /api/tgbot", s.handleTGBotSet)

	// Read-only mihomo monitoring for the console. Health stays on the normal
	// bearer-authenticated API surface; the log stream gets a short-lived ticket
	// because browser WebSocket handshakes cannot set Authorization headers.
	mux.HandleFunc("GET /api/mihomo/health", s.handleMihomoHealth)
	mux.HandleFunc("POST /api/mihomo/log-ticket", s.handleMihomoLogTicket)

	// NOTE (UP-1 Task D3): the managed DNS-subscription (/api/subscriptions*),
	// manual per-category rules (/api/rules/{cat}), and manual refresh
	// (/api/update) operator surface was REMOVED here — absorbed by the
	// unified policy-rule model (see /api/policy/* below). The underlying
	// SubManager fetch engine (subscription.go) is NOT removed: the policy
	// compiler drives it directly via SubManager.Sync (policy_engine.go),
	// it's just no longer a hand-managed HTTP surface.

	mux.HandleFunc("POST /api/reload", s.handleReload)

	mux.HandleFunc("GET /api/policy/rules", s.handlePolicyRulesList)
	mux.HandleFunc("POST /api/policy/rules", s.handlePolicyRulesCreate)
	mux.HandleFunc("PATCH /api/policy/rules/{id}", s.handlePolicyRulesReplace)
	mux.HandleFunc("DELETE /api/policy/rules/{id}", s.handlePolicyRulesDelete)
	mux.HandleFunc("PUT /api/policy/rules/reorder", s.handlePolicyRulesReorder)

	mux.HandleFunc("GET /api/policy/fallback", s.handlePolicyFallbackGet)
	mux.HandleFunc("PUT /api/policy/fallback", s.handlePolicyFallbackSet)

	mux.HandleFunc("POST /api/policy/apply", s.handlePolicyApply)

	mux.HandleFunc("GET /api/mihomo/config", s.handleMihomoConfigGet)
	mux.HandleFunc("PUT /api/mihomo/config", s.handleMihomoConfigPut)
	mux.HandleFunc("GET /api/mihomo/config/default", s.handleMihomoConfigDefault)
	mux.HandleFunc("POST /api/mihomo/config/reset", s.handleMihomoConfigReset)

	return mux
}

// handleStatus reports build/runtime identity plus a stats snapshot. This
// handler sits behind authMiddleware (see apiMux), so mihomo_secret — the
// controller secret zashboard's pass-through /proxy/ mount requires (design
// §5.2/§5.3) — is safe to include: only an authenticated console admin can
// read it, and the frontend uses it solely to build the "前往 zash"
// deep-link's URL-encoded secret= query param.
func (s *ControlServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"version":        version,
		"uptime_seconds": int(time.Since(s.startTime).Seconds()),
		"stats":          s.ctrl.Stats(),
	}
	if cs, ok := s.ctrl.CertStatus(); ok {
		resp["cert"] = cs
	}
	if s.zashDomain != "" {
		resp["zash_domain"] = s.zashDomain
	}
	if s.mihomoSecret != "" {
		resp["mihomo_secret"] = s.mihomoSecret
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

// handleResolveTest runs the diagnostic per-server lookup (see ResolveTest):
// every configured upstream is queried individually and the arbitration
// decision is reported on top. domain is required.
func (s *ControlServer) handleResolveTest(w http.ResponseWriter, r *http.Request) {
	domain := strings.TrimSpace(r.URL.Query().Get("domain"))
	if domain == "" {
		writeErr(w, http.StatusBadRequest, "missing required query parameter: domain")
		return
	}
	writeJSON(w, http.StatusOK, s.ctrl.ResolveTest(r.Context(), domain))
}

// handleQueryLog returns recent query-log entries (the in-memory 5-minute
// ring), newest first. ?q= filters by substring on name/client; ?limit= caps
// the result (default 200, max 1000).
func (s *ControlServer) handleQueryLog(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	limit := 200
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			limit = n
		}
	}
	if limit > 1000 {
		limit = 1000
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"retention_seconds": int(queryLogRetention.Seconds()),
		"entries":           s.ctrl.QueryLog(q, limit),
	})
}

// handleUpstreamsGet returns the raw specs of the live china/trust upstream
// groups.
func (s *ControlServer) handleUpstreamsGet(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.ctrl.GetUpstreams())
}

// handleUpstreamsSet validates and applies a new upstream config: the live
// groups are rebuilt and hot-swapped (no restart needed) and the config is
// persisted to upstreams.json, which overrides dns.env on the next start.
// Spec-validation failures are 400s; a persist failure after a successful
// swap is a 500 whose message says the change is live but not durable.
func (s *ControlServer) handleUpstreamsSet(w http.ResponseWriter, r *http.Request) {
	var body UpstreamsView
	if !decodeJSONBody(w, r, &body) {
		return
	}
	if err := s.ctrl.SetUpstreams(body.China, body.Trust); err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, ErrInvalidUpstream) {
			status = http.StatusBadRequest
		}
		writeErr(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.ctrl.GetUpstreams())
}

// handleECSGet returns the EDNS Client Subnet the live china group attaches
// ("" = disabled).
func (s *ControlServer) handleECSGet(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"subnet": s.ctrl.ChinaECS()})
}

// handleECSSet replaces the china-group ECS subnet. Body: {"subnet": "..."} —
// a bare IPv4 is normalised to its /24, a CIDR is honoured as written, ""
// disables ECS. Applies live (no restart) + persists to ecs.json. Validation
// failures are 400s; a persist failure after a successful apply is a 500
// whose message says the change is live but not durable.
func (s *ControlServer) handleECSSet(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Subnet string `json:"subnet"`
	}
	if !decodeJSONBody(w, r, &body) {
		return
	}
	norm, err := s.ctrl.SetChinaECS(body.Subnet)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, ErrInvalidECS) {
			status = http.StatusBadRequest
		}
		writeErr(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"subnet": norm})
}

// handleTGBotGet returns the current (token-REDACTED) Telegram-bot config:
// {"admins":[...],"token_set":bool,"running":bool}. The raw token is never
// echoed — a client only learns whether one is configured.
func (s *ControlServer) handleTGBotGet(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.ctrl.GetTGBot())
}

// handleTGBotSet hot-reloads the bot from the web console. Body:
//
//	{"token": "<optional>", "admins": [123, 456]}
//
// The token is a POINTER field: OMIT it to change only the admin set (the
// current token is kept); send a non-empty string to set a new token; send ""
// to disable the bot. The supervisor validates a new token via getMe, restarts
// just the bot goroutine (not the daemon), and persists to tgbot.json. A bad
// token is a 400 and leaves the running bot untouched; an unavailable manager is
// a 503; a persist failure after a successful live apply is a 500 whose message
// says the change is live but not durable.
func (s *ControlServer) handleTGBotSet(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Token  *string `json:"token"`
		Admins []int64 `json:"admins"`
	}
	if !decodeJSONBody(w, r, &body) {
		return
	}
	if err := s.ctrl.SetTGBot(body.Token, body.Admins); err != nil {
		status := http.StatusInternalServerError
		switch {
		case errors.Is(err, ErrTGBotUnavailable):
			status = http.StatusServiceUnavailable
		case strings.Contains(err.Error(), "telegram bot:"):
			// A bad token (getMe failed) is a client error, not a server fault.
			status = http.StatusBadRequest
		}
		writeErr(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.ctrl.GetTGBot())
}

const mihomoLogTicketTTL = 30 * time.Second
const mihomoHealthTimeout = 2 * time.Second

// handleMihomoHealth proxies exactly mihomo's GET /version through the
// daemon-held controller credential. This handler itself sits behind the
// console bearer middleware; callers cannot select another controller path.
func (s *ControlServer) handleMihomoHealth(w http.ResponseWriter, r *http.Request) {
	if s.mihomoProxy == nil {
		writeErr(w, http.StatusServiceUnavailable, "mihomo monitoring unavailable")
		return
	}
	// The controller is loopback, but a wedged process can still accept a
	// connection without answering. Bound the internal probe so the shared
	// StatusContext poll cannot hang forever and stop all later health updates.
	ctx, cancel := context.WithTimeout(r.Context(), mihomoHealthTimeout)
	defer cancel()
	clone := r.Clone(ctx)
	u := *r.URL
	u.Path = "/proxy/version"
	u.RawPath = ""
	u.RawQuery = ""
	clone.URL = &u
	s.mihomoProxy.ServeHTTP(w, clone)
}

// handleMihomoLogTicket mints a cryptographically random, one-use credential
// for one /proxy/logs WebSocket handshake. Tickets are deliberately short
// lived and returned with no-store so they do not become reusable browser
// state like a long-term query-string token would.
func (s *ControlServer) handleMihomoLogTicket(w http.ResponseWriter, r *http.Request) {
	var raw [32]byte
	if _, err := crand.Read(raw[:]); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not mint log ticket")
		return
	}
	ticket := base64.RawURLEncoding.EncodeToString(raw[:])
	expires := time.Now().Add(mihomoLogTicketTTL)

	s.mihomoLogTicketsMu.Lock()
	if s.mihomoLogTickets == nil {
		s.mihomoLogTickets = make(map[string]time.Time)
	}
	for k, deadline := range s.mihomoLogTickets {
		if !deadline.After(time.Now()) {
			delete(s.mihomoLogTickets, k)
		}
	}
	s.mihomoLogTickets[ticket] = expires
	s.mihomoLogTicketsMu.Unlock()

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"ticket":             ticket,
		"expires_in_seconds": int(mihomoLogTicketTTL.Seconds()),
	})
}

// consumeMihomoLogTicket atomically validates and removes a ticket. Removing
// it even on the first attempt prevents replay, including a second WebSocket
// opened while the original stream remains connected.
func (s *ControlServer) consumeMihomoLogTicket(ticket string, now time.Time) bool {
	if ticket == "" {
		return false
	}
	s.mihomoLogTicketsMu.Lock()
	defer s.mihomoLogTicketsMu.Unlock()
	expires, ok := s.mihomoLogTickets[ticket]
	if ok {
		delete(s.mihomoLogTickets, ticket)
	}
	return ok && expires.After(now)
}

// consoleMihomoProxy exposes exactly the log WebSocket and nothing else from
// mihomo's controller. The one-use ticket is consumed before forwarding and
// stripped from the upstream query string; only harmless log-level parameters
// reach mihomo.
func (s *ControlServer) consoleMihomoProxy() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/proxy/logs" || s.mihomoProxy == nil {
			http.NotFound(w, r)
			return
		}
		if !s.consumeMihomoLogTicket(r.URL.Query().Get("ticket"), time.Now()) {
			writeErr(w, http.StatusUnauthorized, "invalid or expired log ticket")
			return
		}

		clone := r.Clone(r.Context())
		u := *r.URL
		q := u.Query()
		q.Del("ticket")
		u.RawQuery = q.Encode()
		clone.URL = &u
		s.mihomoProxy.ServeHTTP(w, clone)
	})
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
//
// There is no in-process IP lockout here: the control plane binds loopback
// and mihomo enforces source-IP allowlisting ahead of it, so a source that
// can reach this listener at all is already trusted at the network layer —
// brute-forcing the token from an untrusted source never gets this far.
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
		//
		// The leading `s.token != ""` guard is defense-in-depth: NewControlServer
		// already refuses to build (and main never starts a server) when the token
		// is empty, so an empty s.token is unreachable here today — but should any
		// future path construct this middleware with an empty secret, a client
		// sending `Authorization: Bearer ` (empty value) would otherwise satisfy
		// ConstantTimeCompare([]byte{}, []byte{}) == 1 and authenticate. The guard
		// makes an empty secret fail closed, never open.
		ok := s.token != "" &&
			len(presented) == len(s.token) &&
			subtle.ConstantTimeCompare([]byte(presented), []byte(s.token)) == 1

		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}

		next.ServeHTTP(w, r)
	})
}

// writeJSON writes v as a JSON response body with the given status code.
//
// Control-plane JSON carries secrets (mihomo_secret in /api/status, polled
// every 5s by the SPA) and client PII (client IP + qname in /api/querylog).
// no-store keeps a private browser cache from persisting those bodies to disk,
// where they would outlive the localStorage token past logout and be readable
// by a same-host local user or disk forensics. Applied centrally so every
// /api/* JSON response is covered; mirrors the per-endpoint no-store already at
// iosd.go (iOS profile) and handleMihomoLogTicket.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeErr writes a {"error": msg} JSON response body with the given status
// code.
func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// Start begins serving HTTPS on cfg.ListenAPI (and, when built, the zash panel
// on cfg.ZashListen) in background goroutines, returning once BOTH listeners
// are bound (or the FIRST bind error encountered, fail-loud — matching the
// pre-A3 single-listener behavior; only the serve loops run in goroutines).
// Both addresses are loopback; mihomo fronts them via the SNI split and
// source-IP allowlisting, so TLS is served directly on the raw listener — no
// PROXY protocol unwrapping is needed here.
func (s *ControlServer) Start() error {
	if err := startPanel(s.srv); err != nil {
		return err
	}
	if s.zashSrv != nil {
		if err := startPanel(s.zashSrv); err != nil {
			return err
		}
	}
	return nil
}

// startPanel binds srv.Addr synchronously (fail-loud on a bind error) and
// then serves it in a background goroutine. Shared by Start() for both the
// console and zash panel servers.
func startPanel(srv *http.Server) error {
	tcpLn, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		return fmt.Errorf("control server: listen %s: %w", srv.Addr, err)
	}
	ln := tls.NewListener(tcpLn, srv.TLSConfig)
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("control server (%s) stopped: %v", srv.Addr, err)
		}
	}()
	return nil
}

// Shutdown gracefully stops the control server (and the zash panel server,
// when built) within ctx's deadline. Both are attempted even if the first
// errors; the first non-nil error is returned.
func (s *ControlServer) Shutdown(ctx context.Context) error {
	err := s.srv.Shutdown(ctx)
	if s.zashSrv != nil {
		if zerr := s.zashSrv.Shutdown(ctx); err == nil {
			err = zerr
		}
	}
	return err
}
