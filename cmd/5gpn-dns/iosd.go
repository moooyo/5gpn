package main

import (
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
)

// iosRoute maps a fixed request path to the on-disk filename (relative to
// wwwDir) and the exact Content-Type to serve it with.
type iosRoute struct {
	file  string
	ctype string
}

// iosRoutes is the closed set of paths the iOS profile handler answers. Only
// these fixed routes are served; the request path is never joined into the
// filesystem path, so path traversal is impossible by construction.
//
// The mobileconfig's Content-Type "application/x-apple-aspen-config" is the
// exact type iOS keys on to install the payload as a configuration profile;
// it is set explicitly rather than sniffed.
var iosRoutes = map[string]iosRoute{
	"/ios-dot.mobileconfig": {file: "ios-dot.mobileconfig", ctype: "application/x-apple-aspen-config"},
	"/":                     {file: "index.html", ctype: "text/html; charset=utf-8"},
	"/index.html":           {file: "index.html", ctype: "text/html; charset=utf-8"},
	"/ios.css":              {file: "ios.css", ctype: "text/css; charset=utf-8"},
	"/ios.js":               {file: "ios.js", ctype: "text/javascript; charset=utf-8"},
}

// iosHandler returns the HTTP handler for the iOS DoT-profile pages rooted at
// wwwDir. It is mounted PUBLIC (no bearer token) on the control server at
// /ios/ (behind http.StripPrefix) — the profile carries no secrets, and an
// iPhone must be able to fetch it before it has any configuration. The old
// standalone :8111 responder was removed; this handler is its in-mux successor.
//
//   - GET /ios/ios-dot.mobileconfig → application/x-apple-aspen-config
//   - GET /ios/ and /ios/index.html → text/html; charset=utf-8
//
// Anything else is 404; a non-GET method is 405; a missing backing file is 404
// (not 500). Because only the fixed route table selects the filename — request
// input is never joined into the path — there is no path-traversal surface.
func iosHandler(wwwDir string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		route, ok := iosRoutes[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		// filepath.Join with a constant filename from the route table; no user
		// input reaches this path, so it cannot escape wwwDir.
		body, err := os.ReadFile(filepath.Join(wwwDir, route.file))
		if err != nil {
			// A missing (or otherwise unreadable) file is a 404, not a 500 —
			// the profile is a convenience, an absent file is "not found".
			if !errors.Is(err, os.ErrNotExist) {
				log.Printf("iosd: read %s: %v", route.file, err)
			}
			http.NotFound(w, r)
			return
		}
		// Set the explicit Content-Type BEFORE writing the body so it is not
		// overridden by net/http's content sniffing on the first Write.
		w.Header().Set("Content-Type", route.ctype)
		// The profile is re-signed on certificate renewal and the landing assets
		// may change on an installer upgrade. Never let Safari reuse a stale page
		// or stale CMS payload across those events.
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
	})
}
