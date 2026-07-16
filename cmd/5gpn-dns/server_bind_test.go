package main

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"
)

// A DNS listener that cannot bind must fail Start() loudly (main log.Fatals on
// it) instead of logging inside a goroutine and leaving the process "healthy"
// (systemd active, watchdog fed, heartbeat pinging) with a dead :853 —
// previously Start() unconditionally returned nil and a port conflict on the
// main ingress was silently swallowed. Exercised via the debug UDP listener
// (the DoT path shares the same synchronous-bind structure).
func TestStartFailsLoudlyWhenDebugPortTaken(t *testing.T) {
	// Occupy a UDP port first.
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	addr := pc.LocalAddr().String()

	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	srv, err := NewServers(Config{ListenDebug: addr}, h)
	if err != nil {
		t.Fatalf("NewServers: %v", err)
	}
	err = srv.Start()
	if err == nil {
		t.Fatal("Start must return the bind error when the debug port is already taken")
	}
	if !strings.Contains(err.Error(), addr) {
		t.Fatalf("bind error should name the listener address, got: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}

// The happy path still binds and returns nil.
func TestStartBindsDebugListener(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	srv, err := NewServers(Config{ListenDebug: "127.0.0.1:0"}, h)
	if err != nil {
		t.Fatalf("NewServers: %v", err)
	}
	if err := srv.Start(); err != nil {
		t.Fatalf("Start on a free port must succeed, got: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}
