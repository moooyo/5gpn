package main

import (
	"context"
	crand "crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"

	telegram "github.com/go-telegram/bot"
)

const mihomoControllerUnavailableMsg = "mihomo controller unavailable"

const (
	panelReadHeaderTimeout = 10 * time.Second
	panelIdleTimeout       = 90 * time.Second
	panelMaxHeaderBytes    = 64 << 10
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

// ControlServer is the loopback HTTPS control plane on :443: a REST API over
// Controller (bearer-token authenticated) plus the disk-served SPA and the
// public iOS profile download. It is a separate listener from the DNS-facing DoT
// server (Servers in server.go) — different port, different purpose (admin,
// not resolution). It binds loopback only (cfg.ListenAPI); mihomo fronts it
// on :443 via the public console SNI split. SPA assets and the profile download
// are public; every /api/* request still requires the console bearer token.
type ControlServer struct {
	srv     *http.Server
	zashSrv *http.Server // second loopback panel (zashboard); nil when cfg.ZashListen == ""

	ctrl      *Controller
	token     string
	startTime time.Time
	limiter   *rateLimiter

	// dotDomain is the derived dot.<base> name surfaced through the token-gated
	// status endpoint for the console setup guide.
	dotDomain string

	// zashDomain is the derived zash.<base> name, surfaced read-only
	// via GET /api/status so the console's mihomo page can deep-link into the
	// zashboard panel without scraping location.host. Empty when unconfigured.
	zashDomain string

	// Mihomo raw-config editor (api_mihomo_config.go). Wired post-construction
	// via SetMihomoConfig; nil store means the
	// /api/mihomo/config* endpoints report unavailable (503) rather than
	// panicking, matching every other optional-manager idiom in this file.
	mihomoStore      *MihomoConfigStore
	interceptStore   *InterceptConfigStore
	interceptModules *InterceptModuleManager
	marketplaces     *ExtensionMarketplaceManager
	mihomoInfra      InfraParams
	mihomoTest       mihomoTester
	mihomoCtl        mihomoController
	// mihomoProxy is the secret-injecting loopback proxy used only by the
	// authenticated health endpoint and the ticket-gated log WebSocket. It is
	// deliberately not mounted directly: exposing the raw controller subtree
	// would let any public console visitor mutate mihomo without the console
	// bearer token.
	mihomoProxy http.Handler

	// Browser WebSockets cannot attach the console's Authorization header. A
	// bearer-authenticated POST therefore mints a short-lived, single-use ticket
	// for exactly one /proxy/logs upgrade. The ticket is removed before the
	// request is forwarded to mihomo and is never accepted for another path.
	mihomoLogTicketsMu sync.Mutex
	mihomoLogTickets   map[string]time.Time

	// An authenticated console request mints a one-use zashboard handoff ticket.
	// The zash origin consumes it, sets a host-only HttpOnly session cookie, and
	// injects the controller credential server-side for that session. The
	// controller secret never enters browser JavaScript, URLs, or localStorage.
	zashAuthMu         sync.Mutex
	zashHandoffTickets map[[32]byte]time.Time
	zashSessions       map[[32]byte]time.Time

	// mihomoAppliedAt is the last time a PUT/reset successfully hot-applied a
	// config (in-memory only; a restart forgets it). Guarded by
	// mihomoAppliedAtMu since it's read by GET and written by PUT/reset,
	// which can race.
	mihomoAppliedAtMu sync.Mutex
	mihomoAppliedAt   time.Time

	geocodeHTTP     *http.Client
	geocodeEndpoint string
}

// NewControlServer builds a ControlServer from cfg and ctrl.
//
// If cfg.APIToken is empty the control plane is intentionally disabled —
// serving an unauthenticated admin API would be worse than not serving one at
// all — and NewControlServer returns (nil, nil) so callers can treat that as
// "nothing to start" rather than an error.
//
// When enabled, cfg.WebCertFile and cfg.WebKeyFile are required: the control
// plane is HTTPS-only and each certificate role is explicit.
func NewControlServer(cfg Config, ctrl *Controller) (*ControlServer, error) {
	if cfg.APIToken == "" {
		return nil, nil
	}
	webCert, webKey := cfg.WebCertFile, cfg.WebKeyFile
	if webCert == "" || webKey == "" {
		return nil, fmt.Errorf("control server: DNS_WEB_CERT and DNS_WEB_KEY are required when DNS_API_TOKEN is set")
	}
	zashCert, zashKey := cfg.ZashCertFile, cfg.ZashKeyFile
	if (cfg.ZashListen != "" || cfg.MihomoController != "") && (zashCert == "" || zashKey == "") {
		return nil, fmt.Errorf("control server: DNS_ZASH_CERT and DNS_ZASH_KEY are required for zashboard/controller TLS")
	}

	s := &ControlServer{
		ctrl:            ctrl,
		token:           cfg.APIToken,
		startTime:       time.Now(),
		limiter:         newRateLimiter(cfg.APIRate, cfg.APIBurst),
		dotDomain:       cfg.DotDomain,
		zashDomain:      cfg.ZashDomain,
		mihomoProxy:     unavailableMihomoProxy(),
		interceptStore:  NewInterceptConfigStore(cfg.InterceptConfigFile),
		geocodeHTTP:     newGeocodeHTTPClient(nil),
		geocodeEndpoint: defaultGeocodeEndpoint,
	}

	webUI, err := newWebUIHandler(cfg.WebDir)
	if err != nil {
		return nil, fmt.Errorf("control server: %w", err)
	}

	var mihomoTransport http.RoundTripper
	if cfg.MihomoController != "" {
		transport, transportErr := newMihomoTransport(cfg.MihomoController, cfg.ZashDomain, zashCert)
		if transportErr != nil {
			log.Printf("warning: control server: mihomo controller TLS unavailable: %v -- /api/mihomo/health and /proxy/* fail closed until DNS_BASE_DOMAIN, the zash role certificate, and loopback controller settings are valid", transportErr)
		} else {
			mihomoTransport = transport
			s.mihomoProxy = newMihomoProxy(cfg.ZashDomain, cfg.MihomoSecret, "/proxy", mihomoTransport)
		}
	}

	ios := http.StripPrefix("/ios", iosHandler(cfg.WWWDir))
	mux := http.NewServeMux()
	// Audit every mutation, authenticate before touching the administrator's
	// shared limiter bucket, then rate-limit authenticated API work. Mihomo's
	// loopback tunnel does not carry PROXY protocol, so public callers must not
	// be able to drain a bucket keyed by the tunnel's loopback source address.
	mux.Handle("/api/", s.auditMiddleware(s.authMiddleware(s.rateLimitMiddleware(s.apiMux()))))
	// iOS .mobileconfig distribution is public and token-free. The DoT profile
	// carries only the resolver identity; the separate interception profile carries a
	// public root certificate but never its signing key. Both must be fetchable
	// before the phone has any 5gpn configuration.
	mux.Handle("/ios/", ios)
	// WebSocket authentication is enforced by an expiring one-use ticket minted
	// through the bearer-protected API. Every other controller path is hidden.
	mux.Handle("/proxy/", s.consoleMihomoProxy())
	mux.Handle("/", webUI)

	s.srv = buildPanelServer(cfg.ListenAPI, securityHeadersMiddleware(mux), webCert, webKey)

	if cfg.ZashListen != "" {
		if zashCert == "" || zashKey == "" {
			return nil, fmt.Errorf("control server: DNS_ZASH_CERT and DNS_ZASH_KEY are required when DNS_ZASH_LISTEN is set")
		}

		zashUI, err := newWebUIHandler(cfg.ZashDir)
		if err != nil {
			return nil, fmt.Errorf("control server: zash: %w", err)
		}

		// A valid HttpOnly zash session gates the full controller proxy. The
		// daemon injects the controller secret only after that gate.
		zashProxy := unavailableMihomoProxy()
		if mihomoTransport != nil {
			zashProxy = newMihomoProxy(cfg.ZashDomain, cfg.MihomoSecret, "/proxy", mihomoTransport)
		}

		zmux := http.NewServeMux()
		// Zashboard's root-scoped service worker handles every GET navigation
		// with its cached SPA shell. Keep the one-use handoff as a POST so the
		// request always reaches the daemon, including for returning users whose
		// browser already has that worker active.
		zmux.HandleFunc("POST /handoff", s.handleZashHandoff)
		zmux.HandleFunc("/handoff", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		})
		zmux.Handle("/proxy/", s.zashSessionMiddleware(zashProxy))
		zmux.Handle("/", zashUI)

		s.zashSrv = buildPanelServer(cfg.ZashListen, zashSecurityHeadersMiddleware(zmux), zashCert, zashKey)
	}

	return s, nil
}

func unavailableMihomoProxy() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeErr(w, http.StatusServiceUnavailable, mihomoControllerUnavailableMsg)
	})
}

// buildPanelServer constructs one *http.Server bound to addr, serving handler
// over TLS via certGetter(certFile, keyFile) (TLS 1.2 minimum). Shared by the
// console and zash panel servers, which differ only in handler/middleware
// stack and which cert pair they present.
func buildPanelServer(addr string, handler http.Handler, certFile, keyFile string) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: panelReadHeaderTimeout,
		IdleTimeout:       panelIdleTimeout,
		MaxHeaderBytes:    panelMaxHeaderBytes,
		TLSConfig: &tls.Config{
			GetCertificate: certGetter(certFile, keyFile),
			MinVersion:     tls.VersionTLS12,
		},
	}
}

// securityHeadersMiddleware sets defense-in-depth response headers on the whole
// console HTTPS surface (API + SPA + /ios/). The console holds its bearer token in localStorage,
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
// style-src 'self' 'unsafe-inline' is the baseline fallback for browsers that
// do not implement the -elem/-attr split. Tightening style-src-attr further would require moving the
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
// connect-src keeps the control plane, city-search projection, and log socket
// same-origin. img-src permits only the fixed OpenStreetMap tile origin used by
// the location setting editor. No third-party script, style, or browser-fetch
// origin is added.
func securityHeadersMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy",
			"default-src 'self'; img-src 'self' data: https://tile.openstreetmap.org; font-src 'self'; style-src 'self' 'unsafe-inline'; style-src-elem 'self'; style-src-attr 'unsafe-inline'; worker-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'")
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
// allowlist-gated (mihomo :443), holds NO 5gpn bearer or controller token (the
// controller secret is injected only after an HttpOnly session gate), so the
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

// apiMux builds the bearer-authenticated control API.
func (s *ControlServer) apiMux() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/status", s.handleStatus)
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
	mux.HandleFunc("POST /api/mihomo/zashboard-handoff", s.handleZashboardHandoffTicket)

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
	mux.HandleFunc("POST /api/mihomo/config/reset", s.handleMihomoConfigReset)
	mux.HandleFunc("GET /api/mihomo/ingress-modules", s.handleMihomoIngressModulesGet)
	mux.HandleFunc("PUT /api/mihomo/ingress-modules/{id}", s.handleMihomoIngressModulePut)
	mux.HandleFunc("GET /api/interception/settings", s.handleInterceptSettingsGet)
	mux.HandleFunc("PUT /api/interception/settings", s.handleInterceptSettingsPut)
	mux.HandleFunc("GET /api/interception/modules", s.handleInterceptModulesGet)
	mux.HandleFunc("PUT /api/interception/modules/reorder", s.handleInterceptModulesReorder)
	mux.HandleFunc("GET /api/interception/modules/{id}", s.handleInterceptModuleSnapshotGet)
	mux.HandleFunc("POST /api/interception/modules/import", s.handleInterceptModulesImport)
	mux.HandleFunc("POST /api/interception/modules/{id}/update-check", s.handleInterceptModuleUpdateCheck)
	mux.HandleFunc("POST /api/interception/modules/{id}/update-apply", s.handleInterceptModuleUpdateApply)
	mux.HandleFunc("PUT /api/interception/modules/{id}", s.handleInterceptModulePut)
	mux.HandleFunc("DELETE /api/interception/modules/{id}", s.handleInterceptModuleDelete)
	mux.HandleFunc("GET /api/interception/marketplaces", s.handleMarketplacesGet)
	mux.HandleFunc("POST /api/interception/marketplaces", s.handleMarketplaceAdd)
	mux.HandleFunc("POST /api/interception/marketplaces/{id}/refresh", s.handleMarketplaceRefresh)
	mux.HandleFunc("DELETE /api/interception/marketplaces/{id}", s.handleMarketplaceDelete)
	mux.HandleFunc("POST /api/interception/marketplaces/{marketplace}/entries/{extension}/install", s.handleMarketplaceInstall)
	mux.HandleFunc("GET /api/geocode/cities", s.handleGeocodeCities)

	return mux
}

// handleStatus reports build/runtime identity plus a stats snapshot. Controller
// credentials are deliberately absent; zashboard access uses the separate
// one-use handoff endpoint and an HttpOnly host session.
func (s *ControlServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"version":        version,
		"uptime_seconds": int(time.Since(s.startTime).Seconds()),
		"stats":          s.ctrl.Stats(),
	}
	if cs, ok := s.ctrl.CertStatus(); ok {
		resp["cert"] = cs
	}
	if s.dotDomain != "" {
		resp["dot_domain"] = s.dotDomain
	}
	if s.zashDomain != "" {
		resp["zash_domain"] = s.zashDomain
	}
	writeJSON(w, http.StatusOK, resp)
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
		case errors.Is(err, errBotConfigSuperseded):
			status = http.StatusConflict
		case errors.Is(err, telegram.ErrorUnauthorized), errors.Is(err, telegram.ErrorForbidden):
			status = http.StatusBadRequest
		case strings.Contains(err.Error(), "telegram bot:"):
			// Transient Telegram/proxy/webhook-preflight failures are an upstream
			// availability problem. The old live bot remains untouched.
			status = http.StatusBadGateway
		}
		writeErr(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.ctrl.GetTGBot())
}

const (
	mihomoLogTicketTTL  = 30 * time.Second
	mihomoHealthTimeout = 2 * time.Second
	zashHandoffTTL      = 30 * time.Second
	zashSessionTTL      = 12 * time.Hour
	zashAuthEntryLimit  = 512
	zashSessionCookie   = "__Host-5gpn-zash"
)

func newBrowserCredential() (string, [32]byte, error) {
	var raw [32]byte
	if _, err := crand.Read(raw[:]); err != nil {
		return "", [32]byte{}, err
	}
	token := base64.RawURLEncoding.EncodeToString(raw[:])
	return token, sha256.Sum256(raw[:]), nil
}

func browserCredentialDigest(token string) ([32]byte, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) != 32 || base64.RawURLEncoding.EncodeToString(raw) != token {
		return [32]byte{}, false
	}
	return sha256.Sum256(raw), true
}

func pruneBrowserCredentials(entries map[[32]byte]time.Time, now time.Time) {
	for key, expires := range entries {
		if !expires.After(now) {
			delete(entries, key)
		}
	}
	for len(entries) >= zashAuthEntryLimit {
		var oldestKey [32]byte
		var oldest time.Time
		for key, expires := range entries {
			if oldest.IsZero() || expires.Before(oldest) {
				oldestKey, oldest = key, expires
			}
		}
		delete(entries, oldestKey)
	}
}

func (s *ControlServer) mintZashHandoff(now time.Time) (string, time.Time, error) {
	token, digest, err := newBrowserCredential()
	if err != nil {
		return "", time.Time{}, err
	}
	expires := now.Add(zashHandoffTTL)
	s.zashAuthMu.Lock()
	defer s.zashAuthMu.Unlock()
	if s.zashHandoffTickets == nil {
		s.zashHandoffTickets = make(map[[32]byte]time.Time)
	}
	pruneBrowserCredentials(s.zashHandoffTickets, now)
	s.zashHandoffTickets[digest] = expires
	return token, expires, nil
}

func (s *ControlServer) consumeZashHandoff(token string, now time.Time) bool {
	digest, valid := browserCredentialDigest(token)
	if !valid {
		return false
	}
	s.zashAuthMu.Lock()
	defer s.zashAuthMu.Unlock()
	expires, ok := s.zashHandoffTickets[digest]
	if ok {
		delete(s.zashHandoffTickets, digest)
	}
	return ok && expires.After(now)
}

func (s *ControlServer) mintZashSession(now time.Time) (string, time.Time, error) {
	token, digest, err := newBrowserCredential()
	if err != nil {
		return "", time.Time{}, err
	}
	expires := now.Add(zashSessionTTL)
	s.zashAuthMu.Lock()
	defer s.zashAuthMu.Unlock()
	if s.zashSessions == nil {
		s.zashSessions = make(map[[32]byte]time.Time)
	}
	pruneBrowserCredentials(s.zashSessions, now)
	s.zashSessions[digest] = expires
	return token, expires, nil
}

func (s *ControlServer) validZashSession(token string, now time.Time) bool {
	digest, valid := browserCredentialDigest(token)
	if !valid {
		return false
	}
	s.zashAuthMu.Lock()
	defer s.zashAuthMu.Unlock()
	expires, ok := s.zashSessions[digest]
	if ok && !expires.After(now) {
		delete(s.zashSessions, digest)
		ok = false
	}
	return ok
}

// handleZashboardHandoffTicket mints a one-use cross-origin bootstrap URL.
// The URL carries only a disposable ticket; never the controller secret.
func (s *ControlServer) handleZashboardHandoffTicket(w http.ResponseWriter, _ *http.Request) {
	if s.zashDomain == "" || s.zashSrv == nil {
		writeErr(w, http.StatusServiceUnavailable, "zashboard unavailable")
		return
	}
	ticket, _, err := s.mintZashHandoff(time.Now())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not mint zashboard handoff")
		return
	}
	u := url.URL{Scheme: "https", Host: s.zashDomain, Path: "/handoff"}
	q := u.Query()
	q.Set("ticket", ticket)
	u.RawQuery = q.Encode()
	writeJSON(w, http.StatusOK, map[string]any{
		"url":                u.String(),
		"expires_in_seconds": int(zashHandoffTTL.Seconds()),
	})
}

// handleZashHandoff consumes the ticket before issuing a host-only HttpOnly
// session. The redirect fragment contains only a fixed non-secret placeholder
// required by zashboard's setup parser; proxy authentication is cookie-backed.
func (s *ControlServer) handleZashHandoff(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	if !s.consumeZashHandoff(r.URL.Query().Get("ticket"), now) {
		writeErr(w, http.StatusUnauthorized, "invalid or expired zashboard handoff")
		return
	}
	session, expires, err := s.mintZashSession(now)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not create zashboard session")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     zashSessionCookie,
		Value:    session,
		Path:     "/",
		Expires:  expires,
		MaxAge:   int(zashSessionTTL.Seconds()),
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
	})
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	target := "/#/setup?hostname=" + url.QueryEscape(s.zashDomain) +
		"&port=443&secret=5gpn-session&secondaryPath=/proxy"
	http.Redirect(w, r, target, http.StatusSeeOther)
}

func (s *ControlServer) zashSessionMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
			writeErr(w, http.StatusUnauthorized, "zashboard session required")
			return
		}
		cookie, err := r.Cookie(zashSessionCookie)
		if err != nil || !s.validZashSession(cookie.Value, time.Now()) {
			writeErr(w, http.StatusUnauthorized, "zashboard session required")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

// handleMihomoHealth proxies exactly mihomo's GET /version through the
// daemon-held controller credential. This handler itself sits behind the
// console bearer middleware; callers cannot select another controller path.
func (s *ControlServer) handleMihomoHealth(w http.ResponseWriter, r *http.Request) {
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

// decodeJSONBody reads and JSON-decodes r.Body into dst, capping the body
// size and writing a 400 JSON error on any read/decode failure. Returns
// false (and has already written the error response) if decoding failed.
func decodeJSONBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	return decodeJSONBodyLimit(w, r, dst, maxAPIBodyBytes)
}

func decodeJSONBodyLimit(w http.ResponseWriter, r *http.Request, dst any, limit int64) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	if err := decodeStrictJSON(r.Body, dst); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Sprintf("invalid request body: %v", err))
		return false
	}
	return true
}

// rateLimitMiddleware enforces a per-source-IP token-bucket limit on every
// authenticated /api/* request to bound expensive control-plane work. It is
// wired inside authMiddleware because the public mihomo tunnel collapses
// backend RemoteAddr values to loopback; unauthenticated callers must not be
// able to consume the administrator's shared bucket.
//
// The source key is derived from r.RemoteAddr (host part only, via
// net.SplitHostPort; the raw value is used as-is if that fails, e.g. in unit
// tests that set a bare RemoteAddr). X-Forwarded-For is deliberately not
// consulted because mihomo does not authenticate or set that header.
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
// There is no pre-authentication IP lockout here. The console SNI is public by
// design, while the bearer token is high entropy; connection-level timeouts
// bound slow clients and only authenticated requests consume rate-limit state.
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
// Control-plane JSON carries sensitive operational data such as client IP and
// qname in /api/querylog. Controller secrets are never serialized to JSON.
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
