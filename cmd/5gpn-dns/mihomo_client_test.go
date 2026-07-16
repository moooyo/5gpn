package main

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// TestMihomoClient_PutConfigs asserts a PUT /configs?force=false with a
// {"path": ...} JSON body.
func TestMihomoClient_PutConfigs(t *testing.T) {
	var gotPath, gotQuery, gotBody string
	srv := newMihomoTLSTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		if r.Method != "PUT" {
			t.Errorf("bad method %s", r.Method)
		}
		w.WriteHeader(http.StatusNoContent)
	}))

	c, err := NewMihomoClient(srv.controller, "tok", srv.serverName, srv.certFile)
	if err != nil {
		t.Fatal(err)
	}
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
	srv := newMihomoTLSTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusNoContent)
	}))

	c, err := NewMihomoClient(srv.controller, "s3cr3t", srv.serverName, srv.certFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.PutConfigs(context.Background(), "/etc/mihomo/config.yaml"); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer s3cr3t" {
		t.Fatalf("auth=%q", gotAuth)
	}
}

// TestMihomoClient_PutConfigs_NoSecret asserts the Authorization header is
// omitted entirely when the client is constructed with an empty secret.
// A mihomo controller with no configured secret rejects any Authorization
// header, so the client must leave the header out completely.
func TestMihomoClient_PutConfigs_NoSecret(t *testing.T) {
	authSet := false
	srv := newMihomoTLSTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authSet = r.Header.Get("Authorization") != "" || len(r.Header.Values("Authorization")) > 0
		w.WriteHeader(http.StatusOK)
	}))

	c, err := NewMihomoClient(srv.controller, "", srv.serverName, srv.certFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.PutConfigs(context.Background(), "/etc/mihomo/config.yaml"); err != nil {
		t.Fatal(err)
	}
	if authSet {
		t.Fatalf("expected no Authorization header when secret is empty")
	}
}

// TestMihomoClient_Status asserts any completed round trip — including a
// non-2xx status — counts as reachable, while a dead/unlistening address
// (nothing to dial) counts as unreachable.
func TestMihomoClient_Status(t *testing.T) {
	srv := newMihomoTLSTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))

	c, err := NewMihomoClient(srv.controller, "tok", srv.serverName, srv.certFile)
	if err != nil {
		t.Fatal(err)
	}
	status := c.Status(context.Background())
	if !status.Reachable || status.Authenticated {
		t.Fatalf("401 status = %+v, want reachable but unauthenticated", status)
	}

	dead, err := NewMihomoClient("127.0.0.1:1", "", srv.serverName, srv.certFile) // nothing listens on port 1
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if dead.Status(ctx).Reachable {
		t.Fatalf("expected reachable=false when nothing is listening")
	}
}

// TestMihomoClient_ErrorStatus asserts a non-2xx response surfaces as an
// error carrying the status code and a snippet of the response body.
func TestMihomoClient_ErrorStatus(t *testing.T) {
	srv := newMihomoTLSTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom: config validation failed"))
	}))

	c, err := NewMihomoClient(srv.controller, "tok", srv.serverName, srv.certFile)
	if err != nil {
		t.Fatal(err)
	}
	err = c.PutConfigs(context.Background(), "/etc/mihomo/config.yaml")
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
