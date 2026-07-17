package main

import (
	"log"
	"net"
	"net/http"
	"strings"
)

// statusRecorder wraps an http.ResponseWriter to capture the status code
// that was actually written, so middleware running after the handler (e.g.
// auditMiddleware) can report the real outcome. If the handler never calls
// WriteHeader explicitly (e.g. it only calls Write), the status defaults to
// http.StatusOK, matching net/http's own behavior.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

// WriteHeader records status and passes it through to the underlying writer.
func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// Write passes through to the underlying writer. It does not need to
// override behavior: if the handler writes without calling WriteHeader
// first, net/http's ResponseWriter implicitly sends a 200, which matches
// statusRecorder's zero-value default below.
func (r *statusRecorder) Write(b []byte) (int, error) {
	return r.ResponseWriter.Write(b)
}

// resultStatus returns the status to report: whatever was recorded, or 200
// if WriteHeader was never called.
func (r *statusRecorder) resultStatus() int {
	if r.status == 0 {
		return http.StatusOK
	}
	return r.status
}

// auditMiddleware records a single-line audit entry for every mutating
// control-plane request (POST/PUT/PATCH/DELETE), via the standard log
// package (stderr -> journald under systemd).
//
// Only method/path/src/status are logged — never the request body or the
// bearer token. For routes like POST /api/policy/rules the created
// resource's id lives in the body, not the path; that granularity avoids
// inspecting or logging request bodies.
//
// GET/HEAD requests are reads, not mutations, and are not audited at all —
// this keeps the audit log focused on actual state changes an operator
// would want to review.
//
// It is wired OUTSIDE authMiddleware (see NewControlServer) so a rejected
// (401) mutation attempt is still recorded — an unauthenticated attempt to
// mutate state is itself a security-relevant signal — while staying INSIDE
// rateLimitMiddleware so a request dropped for being rate-limited (which
// never reaches here) doesn't also get an audit line.
//
// A logging failure must never break the request: log.Printf on a plain
// stderr writer doesn't return an error the caller can act on, and this
// middleware does no I/O of its own beyond that, so there is nothing here
// that can panic or block the response path.
func (s *ControlServer) auditMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !isMutatingMethod(r.Method) {
			next.ServeHTTP(w, r)
			return
		}

		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)

		log.Printf("audit method=%s path=%s src=%s status=%d", r.Method, r.URL.Path, auditSource(r), rec.resultStatus())
	})
}

// isMutatingMethod reports whether method represents a state-changing
// control-plane request worth auditing.
func isMutatingMethod(method string) bool {
	switch method {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		return true
	default:
		return false
	}
}

// auditSource extracts the host part of r.RemoteAddr for the audit "src="
// field, falling back to the raw RemoteAddr if it has no port (e.g. some
// unit tests, or an unexpected upstream proxy format).
func auditSource(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// auditBot records a single-line audit entry for a state-changing or privileged
// operation performed through the in-process Telegram bot, mirroring the HTTP
// auditMiddleware lines for the HTTPS API (same "audit " prefix, stderr →
// journald). The bot is a privileged control path — it reaches the daemon over
// Telegram long-polling (bypassing the CLIENT_NET firewall) and can trigger
// systemctl / the fixed delegated renewal and journal-export services — yet its
// mutations were previously unaudited, an asymmetry with the HTTP API this
// closes. op is a
// short verb (e.g. "reload", "restart-mihomo", "renew-cert"),
// adminID is the Telegram user id that issued it, and result is one of
// "ok" / "err" / "invoked" (see auditResult). Never logs message bodies or
// tokens, mirroring the HTTP audit's restraint.
func auditBot(op string, adminID int64, result string) {
	log.Printf("audit src=telegram op=%s admin=%d result=%s", auditBotToken(op), adminID, auditBotToken(result))
}

// auditBotOutcome records the final result of a completed bot operation. The
// handler may still record an invocation line before a slow operation, but it
// must call this after completion so journald distinguishes attempted work from
// work that actually succeeded.
func auditBotOutcome(op string, adminID int64, ok bool) {
	auditBot(op, adminID, auditResult(ok))
}

func auditBotToken(value string) string {
	value = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r
		case r >= 'A' && r <= 'Z':
			return r
		case r >= '0' && r <= '9':
			return r
		case strings.ContainsRune("._:-", r):
			return r
		default:
			return '_'
		}
	}, value)
	if value == "" {
		return "unknown"
	}
	return truncateRunes(value, 96)
}

// auditResult maps a success boolean to the audit "result=" token used by
// auditBot for ops that expose a clear ok/err outcome.
func auditResult(ok bool) string {
	if ok {
		return "ok"
	}
	return "err"
}
