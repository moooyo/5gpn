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
// separate zashboard panel mounts the full pass-through behind its SNI source
// allowlist. Every caller must first enforce its own console ticket or zash
// HttpOnly-session gate; the proxy always strips browser Authorization and
// injects the daemon-held controller credential.
func newMihomoProxy(upstreamHost, secret, mountPrefix string, transport http.RoundTripper) http.Handler {
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
			// Never forward the browser's own
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
			// The browser has already authenticated through the relevant gate.
			// A 401/403 here therefore means the daemon-held mihomo
			// controller secret is stale; forwarding that status verbatim would
			// make apiFetch mistake it for a rejected CONSOLE token, clear the
			// valid token, and log the operator out. Present controller-auth
			// failures as an upstream 502 instead.
			if resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden {
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
