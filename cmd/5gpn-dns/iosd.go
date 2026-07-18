package main

import (
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
)

// iosRoute maps a fixed request path to the on-disk filename (relative to
// wwwDir) and the exact Content-Type to serve it with.
type iosRoute struct {
	file  string
	ctype string
}

// iosRoutes is the closed set of files the iOS profile handler answers. The
// configuration guide now lives inside the console SPA; this handler only
// distributes the signed DoT and opt-in interception CA payloads. Request paths are never joined into the
// filesystem path, so path traversal is impossible by construction.
//
// The mobileconfig's Content-Type "application/x-apple-aspen-config" is the
// exact type iOS keys on to install the payload as a configuration profile;
// it is set explicitly rather than sniffed.
var iosRoutes = map[string]iosRoute{
	"/ios-dot.mobileconfig":          {file: "ios-dot.mobileconfig", ctype: "application/x-apple-aspen-config"},
	"/ios-intercept-ca.mobileconfig": {file: "ios-intercept-ca.mobileconfig", ctype: "application/x-apple-aspen-config"},
}

// iosHandler returns the HTTP handler for the signed iOS DoT profile rooted at
// wwwDir. It is mounted PUBLIC (no bearer token) on the control server at
// /ios/ (behind http.StripPrefix) — the profile carries no secrets, and an
// iPhone must be able to fetch it before it has any configuration.
//
//   - GET/HEAD /ios/ios-dot.mobileconfig → application/x-apple-aspen-config
//   - GET /ios/ → redirect to the console setup guide
//
// Anything else is 404; a method other than GET or HEAD is 405; a missing
// backing file is 404 (not 500). Because only the fixed route table selects the
// filename — request input is never joined into the path — there is no
// path-traversal surface.
func iosHandler(wwwDir string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/setup-guide", http.StatusSeeOther)
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
		// The profile is re-signed on certificate renewal. Never let Safari reuse
		// a stale CMS payload across those events.
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodHead {
			return
		}
		_, _ = w.Write(body)
	})
}
