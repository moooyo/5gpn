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
}
