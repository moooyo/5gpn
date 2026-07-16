package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebUIHandler_ServesRealFiles(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<html>APP SHELL</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "assets", "app.js"), []byte("console.log(1)"), 0o644); err != nil {
		t.Fatal(err)
	}
	h, err := newWebUIHandler(dir)
	if err != nil {
		t.Fatalf("newWebUIHandler: %v", err)
	}

	// Real asset is served verbatim.
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/assets/app.js", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "console.log") {
		t.Errorf("asset: code=%d body=%q", rec.Code, rec.Body.String())
	}

	// Deep link falls back to index.html (SPA shell).
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/dashboard/subs", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "APP SHELL") {
		t.Errorf("fallback: code=%d body=%q", rec.Code, rec.Body.String())
	}
}

func TestWebUIHandler_PlaceholderWhenEmpty(t *testing.T) {
	h, err := newWebUIHandler(t.TempDir()) // empty dir, no index.html
	if err != nil {
		t.Fatalf("newWebUIHandler: %v", err)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("code=%d, want 200 (placeholder)", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "5gpn-dns") {
		t.Errorf("placeholder body = %q", rec.Body.String())
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-cache" {
		t.Errorf("placeholder Cache-Control = %q, want no-cache", got)
	}
}

func TestWebUIHandler_CachePolicy(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{
		"index.html":             "<html>APP SHELL</html>",
		"sw.js":                  "self.addEventListener('fetch', () => {})",
		"registerSW.js":          "navigator.serviceWorker.register('/sw.js')",
		"workbox-deadbeef.js":    "export const cached = true",
		"assets/app-deadbeef.js": "console.log('hashed')",
	}
	for name, body := range files {
		path := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	h, err := newWebUIHandler(dir)
	if err != nil {
		t.Fatalf("newWebUIHandler: %v", err)
	}

	for _, path := range []string{"/", "/settings/appearance", "/index.html", "/sw.js", "/registerSW.js"} {
		t.Run("revalidate_"+strings.TrimPrefix(path, "/"), func(t *testing.T) {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
			if got := rec.Header().Get("Cache-Control"); got != "no-cache" {
				t.Errorf("%s Cache-Control = %q, want no-cache", path, got)
			}
		})
	}

	for _, path := range []string{"/assets/app-deadbeef.js", "/workbox-deadbeef.js"} {
		t.Run("hashed_"+strings.TrimPrefix(path, "/"), func(t *testing.T) {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
			if got := rec.Header().Get("Cache-Control"); got == "no-cache" {
				t.Errorf("%s Cache-Control = no-cache, want hashed asset caching unchanged", path)
			}
		})
	}
}
