package main

import (
	"context"
	"net/http"
	"net/http/httptest"
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
