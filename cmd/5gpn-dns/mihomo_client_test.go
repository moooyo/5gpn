package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// TestMihomoClient_PutConfigs asserts a PUT /configs?force=false with a
// {"path": ...} JSON body.
func TestMihomoClient_PutConfigs(t *testing.T) {
	var gotPath, gotQuery, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		if r.Method != "PUT" {
			t.Errorf("bad method %s", r.Method)
		}
		w.WriteHeader(204)
	}))
	defer srv.Close()

	c := NewMihomoClient(strings.TrimPrefix(srv.URL, "http://"), "tok")
	if err := c.PutConfigs(context.Background(), "/etc/mihomo/config.yaml"); err != nil {
		t.Fatal(err)
	}
	if gotPath != "/configs" {
		t.Fatalf("path=%q", gotPath)
	}
	if gotQuery != "force=false" {
		t.Fatalf("query=%q", gotQuery)
	}
	if !strings.Contains(gotBody, `"path"`) || !strings.Contains(gotBody, "/etc/mihomo/config.yaml") {
		t.Fatalf("body=%q", gotBody)
	}
}

// TestMihomoClient_PutConfigsAuth asserts the fake controller sees the
// bearer token attached.
func TestMihomoClient_PutConfigsAuth(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(204)
	}))
	defer srv.Close()

	c := NewMihomoClient(strings.TrimPrefix(srv.URL, "http://"), "s3cr3t")
	if err := c.PutConfigs(context.Background(), "/etc/mihomo/config.yaml"); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer s3cr3t" {
		t.Fatalf("auth=%q", gotAuth)
	}
}

// TestMihomoClient_PutConfigs_NoSecret asserts the Authorization header is
// omitted entirely when the client is constructed with an empty secret — a
// mihomo controller with no `secret:` configured rejects any Authorization
// header at all, so we must not send `Bearer ` (empty).
func TestMihomoClient_PutConfigs_NoSecret(t *testing.T) {
	authSet := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authSet = r.Header.Get("Authorization") != "" || len(r.Header.Values("Authorization")) > 0
		w.WriteHeader(200)
	}))
	defer srv.Close()

	c := NewMihomoClient(strings.TrimPrefix(srv.URL, "http://"), "")
	if err := c.PutConfigs(context.Background(), "/etc/mihomo/config.yaml"); err != nil {
		t.Fatal(err)
	}
	if authSet {
		t.Fatalf("expected no Authorization header when secret is empty")
	}
}

// TestMihomoClient_Reachable asserts any completed round trip — including a
// non-2xx status — counts as reachable, while a dead/unlistening address
// (nothing to dial) counts as unreachable.
func TestMihomoClient_Reachable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	c := NewMihomoClient(strings.TrimPrefix(srv.URL, "http://"), "tok")
	if !c.Reachable(context.Background()) {
		t.Fatalf("expected reachable=true for a live (even 401) controller")
	}
	status := c.Status(context.Background())
	if !status.Reachable || status.Authenticated {
		t.Fatalf("401 status = %+v, want reachable but unauthenticated", status)
	}

	dead := NewMihomoClient("127.0.0.1:1", "") // nothing listens on port 1
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if dead.Reachable(ctx) {
		t.Fatalf("expected reachable=false when nothing is listening")
	}
}

// TestMihomoClient_ErrorStatus asserts a non-2xx response surfaces as an
// error carrying the status code and a snippet of the response body.
func TestMihomoClient_ErrorStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom: config validation failed"))
	}))
	defer srv.Close()

	c := NewMihomoClient(strings.TrimPrefix(srv.URL, "http://"), "tok")
	err := c.PutConfigs(context.Background(), "/etc/mihomo/config.yaml")
	if err == nil {
		t.Fatal("expected error for 500 response")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Fatalf("error should carry status code: %v", err)
	}
	if !strings.Contains(err.Error(), "boom: config validation failed") {
		t.Fatalf("error should carry response body snippet: %v", err)
	}
}
