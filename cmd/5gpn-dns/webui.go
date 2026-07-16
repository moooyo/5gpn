package main

import (
	"io/fs"
	"net/http"
	"os"
	"strings"
)

// placeholderHTML is served when the SPA directory has no index.html (the
// frontend has not been deployed yet). The API keeps working; this just
// tells the operator to install the 5gpn-web release tarball into DNS_WEB_DIR.
const placeholderHTML = `<!doctype html><html><head><meta charset="utf-8"><title>5gpn-dns</title></head>` +
	`<body>5gpn-dns 控制台未部署 — 安装 5gpn-web tarball 到 DNS_WEB_DIR。</body></html>`

// newWebUIHandler serves the SPA from webDir on disk (os.DirFS). Any path with
// no matching static file falls back to index.html (client-side routing on a
// hard refresh / deep link). When webDir has no index.html (frontend not
// deployed) it serves a built-in placeholder rather than a 404/500.
func newWebUIHandler(webDir string) (http.Handler, error) {
	sub := os.DirFS(webDir)
	fileServer := http.FileServerFS(sub)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if pathExists(sub, r.URL.Path) {
			setWebUICachePolicy(w, r.URL.Path)
			fileServer.ServeHTTP(w, r)
			return
		}
		serveIndex(w, r, sub)
	}), nil
}

// setWebUICachePolicy forces the browser to revalidate the unhashed files
// that can point at a new SPA deployment. Hashed assets (and Workbox's hashed
// runtime) retain the file server's normal caching behavior.
func setWebUICachePolicy(w http.ResponseWriter, urlPath string) {
	switch urlPath {
	case "/index.html", "/sw.js", "/registerSW.js":
		w.Header().Set("Cache-Control", "no-cache")
	}
}

// pathExists reports whether the cleaned, slash-trimmed request path names a
// regular file within sub. Directories are not treated as existing files here;
// this only short-circuits the SPA fallback for genuine static assets.
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

// serveIndex serves webDir/index.html (the SPA shell) for any non-asset path,
// or the built-in placeholder when index.html is absent.
func serveIndex(w http.ResponseWriter, r *http.Request, sub fs.FS) {
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	data, err := fs.ReadFile(sub, "index.html")
	if err != nil {
		_, _ = w.Write([]byte(placeholderHTML))
		return
	}
	_, _ = w.Write(data)
}
