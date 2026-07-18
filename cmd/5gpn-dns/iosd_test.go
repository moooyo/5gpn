package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// writeIOSFixtures populates a temp wwwDir with the signed payload the iOS
// profile server serves, returning the dir and the mobileconfig bytes.
func writeIOSFixtures(t *testing.T) (dir string, mobileconfig []byte) {
	t.Helper()
	dir = t.TempDir()
	mobileconfig = []byte("<?xml version=\"1.0\"?>\x00\x01 fake mobileconfig payload")
	if err := os.WriteFile(filepath.Join(dir, "ios-dot.mobileconfig"), mobileconfig, 0o644); err != nil {
		t.Fatalf("write mobileconfig: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ios-intercept-ca.mobileconfig"), mobileconfig, 0o644); err != nil {
		t.Fatalf("write interception CA mobileconfig: %v", err)
	}
	return dir, mobileconfig
}

func TestIOSHandler_WLOCCAMobileconfig(t *testing.T) {
	dir, want := writeIOSFixtures(t)
	recorder := httptest.NewRecorder()
	iosHandler(dir).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/ios-intercept-ca.mobileconfig", nil))
	if recorder.Code != http.StatusOK || recorder.Header().Get("Content-Type") != "application/x-apple-aspen-config" {
		t.Fatalf("status/type=%d/%q", recorder.Code, recorder.Header().Get("Content-Type"))
	}
	if string(recorder.Body.Bytes()) != string(want) {
		t.Fatal("unexpected interception CA profile body")
	}
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

func TestIOSHandler_MobileconfigHead(t *testing.T) {
	dir, want := writeIOSFixtures(t)
	h := iosHandler(dir)

	req := httptest.NewRequest(http.MethodHead, "/ios-dot.mobileconfig", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/x-apple-aspen-config" {
		t.Errorf("Content-Type = %q, want application/x-apple-aspen-config", got)
	}
	if got := rec.Header().Get("Content-Length"); got != strconv.Itoa(len(want)) {
		t.Errorf("Content-Length = %q, want %d", got, len(want))
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD body length = %d, want 0", rec.Body.Len())
	}
}

func TestIOSHandler_SetupGuideRedirect(t *testing.T) {
	dir, _ := writeIOSFixtures(t)
	h := iosHandler(dir)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Errorf("GET /: status = %d, want 303", rec.Code)
	}
	if got := rec.Header().Get("Location"); got != "/setup-guide" {
		t.Errorf("GET /: Location = %q, want /setup-guide", got)
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
	// Point at an empty dir: the profile route exists but its backing file doesn't.
	dir := t.TempDir()
	h := iosHandler(dir)

	req := httptest.NewRequest(http.MethodGet, "/ios-dot.mobileconfig", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Errorf("GET /ios-dot.mobileconfig (missing file): status = %d, want 404 (not 500)", rec.Code)
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
// and serve an outside file. Because the handler maps only a fixed route
// (never joins request path into the filesystem path), a traversal
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

	// The public bootstrap path enters the guide inside the console SPA.
	client := &http.Client{CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	resp2, err := client.Get(ts.URL + "/ios/")
	if err != nil {
		t.Fatalf("GET /ios/: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusSeeOther || resp2.Header.Get("Location") != "/setup-guide" {
		t.Errorf("GET /ios/: status/location = %d/%q, want 303 and /setup-guide", resp2.StatusCode, resp2.Header.Get("Location"))
	}
}
