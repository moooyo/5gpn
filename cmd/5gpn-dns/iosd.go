package main

import (
	"context"
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

// iosRoutes is the closed set of paths the iOS profile server answers. Only
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
}

// iosHandler returns the HTTP handler for the iOS DoT-profile server rooted at
// wwwDir. It serves exactly the two static files behind the fixed routes in
// iosRoutes:
//
//   - GET /ios-dot.mobileconfig → application/x-apple-aspen-config
//   - GET / and GET /index.html → text/html; charset=utf-8
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
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
	})
}

// RunIOSServer runs the in-process iOS DoT-profile HTTP server, blocking until
// ctx is cancelled. The caller runs it in a goroutine.
//
// If cfg.IOSListen is empty the server is disabled and this returns
// immediately. A bind failure is logged and swallowed (best-effort: the iOS
// profile is a convenience, not part of the core DNS data path — a failure
// here must never take the daemon down). Panics are recovered for the same
// reason. On ctx.Done the server is shut down gracefully.
func RunIOSServer(ctx context.Context, cfg Config) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("iosd: recovered from panic: %v", r)
		}
	}()

	if cfg.IOSListen == "" {
		return // disabled
	}

	srv := &http.Server{
		Addr:    cfg.IOSListen,
		Handler: iosHandler(cfg.WWWDir),
	}

	// Graceful shutdown on ctx cancellation.
	go func() {
		<-ctx.Done()
		if err := srv.Shutdown(context.Background()); err != nil {
			log.Printf("iosd: shutdown: %v", err)
		}
	}()

	log.Printf("iosd: iOS profile server listening on %s (www=%s)", cfg.IOSListen, cfg.WWWDir)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		// Bind failure (e.g. port in use) or another serve error: log, don't die.
		log.Printf("iosd: server stopped: %v", err)
	}
}
