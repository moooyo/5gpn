package main

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"
)

// embeddedWeb holds the built (or placeholder) SPA under web/dist. The real
// assets are produced by `vite build` in CI; a committed placeholder
// index.html keeps `go build` (which requires go:embed's pattern to match at
// least one file) working before any frontend build has run.
//
//go:embed web/dist
var embeddedWeb embed.FS

// newWebUIHandler returns an http.Handler that serves the embedded SPA and
// falls back to index.html for any path that doesn't map to a real embedded
// file (client-side routing support: a hard refresh / deep link on e.g.
// /dashboard/subscriptions must still return the app shell, not a 404).
func newWebUIHandler() (http.Handler, error) {
	sub, err := fs.Sub(embeddedWeb, "web/dist")
	if err != nil {
		return nil, err
	}
	fileServer := http.FileServerFS(sub)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if pathExists(sub, r.URL.Path) {
			fileServer.ServeHTTP(w, r)
			return
		}
		serveIndex(w, r, sub)
	}), nil
}

// pathExists reports whether the cleaned, slash-trimmed request path names a
// regular file within sub. Directories are not treated as existing files here
// (http.FileServerFS handles "/" and directory-index resolution itself via
// serveIndex's explicit "/" request below); this only short-circuits the SPA
// fallback for genuine static assets (JS/CSS/images/etc).
func pathExists(sub fs.FS, urlPath string) bool {
	name := strings.TrimPrefix(urlPath, "/")
	if name == "" {
		name = "."
	}
	info, err := fs.Stat(sub, name)
	if err != nil {
		return false
	}
	return !info.IsDir()
}

// serveIndex serves web/dist/index.html regardless of the request path (SPA
// fallback), so client-side routes without a matching static asset (e.g. a
// deep link into the eventual SPA's router) still get the app shell.
func serveIndex(w http.ResponseWriter, r *http.Request, sub fs.FS) {
	data, err := fs.ReadFile(sub, "index.html")
	if err != nil {
		http.Error(w, "index.html not found", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
