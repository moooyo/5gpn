package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeIOSFixtures populates a temp wwwDir with the two static files the iOS
// profile server serves, returning the dir and the mobileconfig bytes.
func writeIOSFixtures(t *testing.T) (dir string, mobileconfig []byte) {
	t.Helper()
	dir = t.TempDir()
	mobileconfig = []byte("<?xml version=\"1.0\"?>\x00\x01 fake mobileconfig payload")
	if err := os.WriteFile(filepath.Join(dir, "ios-dot.mobileconfig"), mobileconfig, 0o644); err != nil {
		t.Fatalf("write mobileconfig: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(`<html><link rel="stylesheet" href="ios.css"><script src="ios.js" defer></script></html>`), 0o644); err != nil {
		t.Fatalf("write index.html: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ios.css"), []byte("body{color:black}"), 0o644); err != nil {
		t.Fatalf("write ios.css: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ios.js"), []byte(`fetch("ios-dot.mobileconfig")`), 0o644); err != nil {
		t.Fatalf("write ios.js: %v", err)
	}
	return dir, mobileconfig
}

func TestIOSHandler_Mobileconfig(t *testing.T) {
	dir, want := writeIOSFixtures(t)
	h := iosHandler(dir)

	req := httptest.NewRequest(http.MethodGet, "/ios-dot.mobileconfig", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	// The exact content-type iOS keys on to install the payload as a profile.
	if got := rec.Header().Get("Content-Type"); got != "application/x-apple-aspen-config" {
		t.Errorf("Content-Type = %q, want application/x-apple-aspen-config", got)
	}
	if got := rec.Body.Bytes(); string(got) != string(want) {
		t.Errorf("body = %q, want %q", got, want)
	}
}

func TestIOSHandler_IndexRoutes(t *testing.T) {
	dir, _ := writeIOSFixtures(t)
	h := iosHandler(dir)

	for _, path := range []string{"/", "/index.html"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Errorf("GET %s: status = %d, want 200", path, rec.Code)
		}
		if got := rec.Header().Get("Content-Type"); got != "text/html; charset=utf-8" {
			t.Errorf("GET %s: Content-Type = %q, want text/html; charset=utf-8", path, got)
		}
		if strings.Contains(rec.Body.String(), "<style") || strings.Contains(rec.Body.String(), "<script>") {
			t.Errorf("GET %s: landing page contains inline CSS/JS and would violate CSP: %q", path, rec.Body.String())
		}
	}
}

func TestIOSHandler_StrictCSPAssets(t *testing.T) {
	dir, _ := writeIOSFixtures(t)
	h := iosHandler(dir)
	for path, wantType := range map[string]string{
		"/ios.css": "text/css; charset=utf-8",
		"/ios.js":  "text/javascript; charset=utf-8",
	} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != wantType {
			t.Errorf("GET %s: status/type=%d/%q, want 200/%q", path, rec.Code, rec.Header().Get("Content-Type"), wantType)
		}
		if got := rec.Header().Get("Cache-Control"); got != "no-store" {
			t.Errorf("GET %s: Cache-Control=%q, want no-store", path, got)
		}
	}
}

func TestIOSHandler_UnknownPath404(t *testing.T) {
	dir, _ := writeIOSFixtures(t)
	h := iosHandler(dir)

	req := httptest.NewRequest(http.MethodGet, "/nope", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}

func TestIOSHandler_MissingFile404(t *testing.T) {
	// Point at an empty dir: the routes exist but the backing files don't.
	dir := t.TempDir()
	h := iosHandler(dir)

	for _, path := range []string{"/ios-dot.mobileconfig", "/", "/index.html", "/ios.css", "/ios.js"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Errorf("GET %s (missing file): status = %d, want 404 (not 500)", path, rec.Code)
		}
	}
}

func TestIOSHandler_NonGET405(t *testing.T) {
	dir, _ := writeIOSFixtures(t)
	h := iosHandler(dir)

	req := httptest.NewRequest(http.MethodPost, "/ios-dot.mobileconfig", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /ios-dot.mobileconfig: status = %d, want 405", rec.Code)
	}
}

// TestIOSHandler_PathTraversal confirms a crafted path can never escape wwwDir
// and serve an outside file. Because the handler maps only the two fixed
// routes (never joins request path into the filesystem path), a traversal
// attempt simply fails to match any route and returns 404.
func TestIOSHandler_PathTraversal(t *testing.T) {
	dir, _ := writeIOSFixtures(t)
	// Create a secret file OUTSIDE wwwDir (in the parent temp dir) that a
	// traversal would try to reach.
	parent := filepath.Dir(dir)
	secret := filepath.Join(parent, "secret.txt")
	if err := os.WriteFile(secret, []byte("TOP SECRET"), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}
	t.Cleanup(func() { _ = os.Remove(secret) })

	h := iosHandler(dir)
	for _, path := range []string{
		"/../secret.txt",
		"/../../secret.txt",
		"/ios-dot.mobileconfig/../../secret.txt",
		"/index.html/../../secret.txt",
		"/%2e%2e/secret.txt",
	} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code == http.StatusOK && rec.Body.String() == "TOP SECRET" {
			t.Fatalf("GET %s escaped wwwDir and served the outside secret file", path)
		}
		// The expected outcome for every traversal attempt is a non-200.
		if rec.Code == http.StatusOK {
			t.Errorf("GET %s: unexpectedly served 200 (body=%q)", path, rec.Body.String())
		}
	}
}

// TestIOSHandler_MountedUnderIOSPrefix exercises the handler exactly as the
// control server mounts it — under http.StripPrefix("/ios", …) — so the public
// /ios/ paths of the web console resolve to the fixed route table.
func TestIOSHandler_MountedUnderIOSPrefix(t *testing.T) {
	dir, want := writeIOSFixtures(t)
	mux := http.NewServeMux()
	mux.Handle("/ios/", http.StripPrefix("/ios", iosHandler(dir)))
	ts := httptest.NewServer(mux)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/ios/ios-dot.mobileconfig")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/x-apple-aspen-config" {
		t.Errorf("Content-Type = %q, want application/x-apple-aspen-config", ct)
	}
	body, _ := io.ReadAll(resp.Body)
	if string(body) != string(want) {
		t.Errorf("body = %q, want the mobileconfig fixture", body)
	}

	// The landing page under the prefix.
	resp2, err := http.Get(ts.URL + "/ios/")
	if err != nil {
		t.Fatalf("GET /ios/: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Errorf("GET /ios/: status = %d, want 200", resp2.StatusCode)
	}
}
