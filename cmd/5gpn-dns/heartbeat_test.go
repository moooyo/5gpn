package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// D4: RunHeartbeat pings the configured URL while alive and stops on ctx cancel.
func TestRunHeartbeatPings(t *testing.T) {
	var hits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		RunHeartbeat(ctx, srv.URL, 20*time.Millisecond)
		close(done)
	}()

	time.Sleep(120 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("RunHeartbeat did not return after ctx cancel")
	}
	if got := hits.Load(); got < 2 {
		t.Errorf("expected multiple heartbeat pings, got %d", got)
	}
}

func TestHeartbeatClientRejectsCrossOriginRedirect(t *testing.T) {
	var targetHits atomic.Int64
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		targetHits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusFound)
	}))
	defer source.Close()

	_, err := newHeartbeatHTTPClient().Get(source.URL + "/secret-uuid")
	if err == nil || !strings.Contains(err.Error(), "cross-origin redirect refused") {
		t.Fatalf("redirect error = %v", err)
	}
	if targetHits.Load() != 0 {
		t.Fatal("heartbeat followed a cross-origin redirect")
	}
}

func TestHeartbeatClientIgnoresAmbientProxyAndRedactsPath(t *testing.T) {
	client := newHeartbeatHTTPClient()
	transport, ok := client.Transport.(*http.Transport)
	if !ok || transport.Proxy != nil {
		t.Fatalf("heartbeat transport proxy = %#v, want nil", client.Transport)
	}
	label := heartbeatEndpointLabel("https://health.example/secret-uuid?token=hidden")
	if strings.Contains(label, "secret") || strings.Contains(label, "hidden") {
		t.Fatalf("heartbeat label leaked secret path/query: %q", label)
	}
}

// D4: an empty URL disables the heartbeat (returns immediately, no goroutine leak).
func TestRunHeartbeatDisabled(t *testing.T) {
	done := make(chan struct{})
	go func() {
		RunHeartbeat(context.Background(), "", time.Second)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("RunHeartbeat with empty URL should return immediately")
	}
}
