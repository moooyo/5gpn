package main

import (
	"io"
	"net/http"
	"net/http/httputil"
	"strconv"
	"strings"
)

// newMihomoProxy builds the BROWSER-facing reverse-proxy to Mihomo's verified
// loopback-TLS external-controller REST+WebSocket API. Unlike MihomoClient
// (mihomo_client.go, the daemon's own apply calls), this is mounted on the
// panel HTTPS servers at mountPrefix so the console's read-only monitoring and
// zashboard's full ops can reach the controller. Callers decide the access
// model: the console never mounts the raw proxy and reaches it only through a
// bearer-authenticated health handler or a one-use-ticket log gate; the
// separate zashboard panel mounts pass-through mode behind its SNI source
// allowlist and relies on the controller secret supplied by zashboard itself.
//
// inject selects which of the two mihomo-auth models this mount uses (design
// §5.2, zashboard authentication):
//
//   - inject=true (console internal use): the secret is injected daemon-side,
//     so the browser never holds it. The caller must already have passed the
//     console bearer/ticket gate in api.go.
//   - inject=false (the zash mux): the browser's own Authorization header is
//     forwarded UNCHANGED (added when present, omitted when absent). This is
//     the password gate for zashboard: an allowlisted-but-unauthenticated
//     visitor has no secret to send, so the controller itself 401s; a console
//     admin's "前往 zash" deep-link carries the secret (api.go's
//     GET /api/status, §5.3) so it auto-auths.
func newMihomoProxy(upstreamHost, secret, mountPrefix string, inject bool, transport http.RoundTripper) http.Handler {
	if transport == nil {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "mihomo controller unavailable", http.StatusServiceUnavailable)
		})
	}
	prefix := strings.TrimSuffix(mountPrefix, "/")
	return &httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = "https"
			pr.Out.URL.Host = upstreamHost
			pr.Out.Host = upstreamHost
			p := strings.TrimPrefix(pr.In.URL.Path, prefix)
			if p == "" || p[0] != '/' {
				p = "/" + p
			}
			pr.Out.URL.Path = p
			pr.Out.URL.RawPath = ""
			if !inject {
				// Pass-through mode (zash mux): pr.Out already carries whatever
				// Authorization the browser sent (httputil.ReverseProxy clones
				// pr.In's headers into pr.Out before calling Rewrite) — leave it
				// untouched, and add nothing when the browser sent none.
				return
			}
			// Injecting mode (console mux): never forward the browser's own
			// Authorization (the 5gpn console bearer) to mihomo; inject the
			// controller secret instead. An empty-secret mihomo rejects ANY
			// Authorization header, so the Del is load-bearing for the
			// empty-secret case.
			pr.Out.Header.Del("Authorization")
			if secret != "" {
				pr.Out.Header.Set("Authorization", "Bearer "+secret)
			}
		},
		ModifyResponse: func(resp *http.Response) error {
			// In injecting mode the browser has already authenticated to the
			// 5gpn API. A 401/403 here therefore means the daemon-held mihomo
			// controller secret is stale; forwarding that status verbatim would
			// make apiFetch mistake it for a rejected CONSOLE token, clear the
			// valid token, and log the operator out. Present controller-auth
			// failures as an upstream 502 instead. Pass-through zashboard mode
			// deliberately retains mihomo's native 401 password challenge.
			if !inject || (resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden) {
				return nil
			}
			const body = `{"error":"mihomo controller authentication failed"}`
			resp.StatusCode = http.StatusBadGateway
			resp.Status = "502 Bad Gateway"
			resp.Header.Del("Www-Authenticate")
			resp.Header.Set("Content-Type", "application/json")
			resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
			resp.Body = io.NopCloser(strings.NewReader(body))
			resp.ContentLength = int64(len(body))
			return nil
		},
	}
}
