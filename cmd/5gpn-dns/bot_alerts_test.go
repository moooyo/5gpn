package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

type alertRecorder struct {
	messages []string
	err      error
}

func (r *alertRecorder) NotifyAdmins(_ context.Context, text string) error {
	if r.err != nil {
		return r.err
	}
	r.messages = append(r.messages, text)
	return nil
}

func TestBotAlertMonitorTransitionsAndDeduplicates(t *testing.T) {
	recorder := &alertRecorder{}
	cert := CertStatus{DaysRemaining: 60, NotAfter: time.Now().Add(60 * 24 * time.Hour)}
	service := "active"
	stats := Stats{}
	m := &botAlertMonitor{
		notifier:  recorder,
		statsFn:   func() Stats { return stats },
		certFn:    func() (CertStatus, bool) { return cert, true },
		serviceFn: func() string { return service },
	}
	ctx := context.Background()
	m.check(ctx) // healthy baseline is silent
	if len(recorder.messages) != 0 {
		t.Fatalf("healthy baseline emitted alerts: %v", recorder.messages)
	}

	service = "failed"
	m.check(ctx)
	m.check(ctx)
	if len(recorder.messages) != 1 || !strings.Contains(recorder.messages[0], "Mihomo") {
		t.Fatalf("service transition alerts = %v", recorder.messages)
	}
	service = "active"
	m.check(ctx)
	if len(recorder.messages) != 2 || !strings.Contains(recorder.messages[1], "恢复") {
		t.Fatalf("service recovery alerts = %v", recorder.messages)
	}

	cert = CertStatus{Broken: true, Error: "bad key"}
	m.check(ctx)
	m.check(ctx)
	if len(recorder.messages) != 3 || !strings.Contains(recorder.messages[2], "证书") {
		t.Fatalf("certificate alerts = %v", recorder.messages)
	}
}

func TestBotAlertMonitorRequiresSustainedUpstreamFailure(t *testing.T) {
	recorder := &alertRecorder{}
	stats := Stats{}
	m := &botAlertMonitor{
		notifier:  recorder,
		statsFn:   func() Stats { return stats },
		certFn:    func() (CertStatus, bool) { return CertStatus{}, false },
		serviceFn: func() string { return "active" },
	}
	ctx := context.Background()
	m.check(ctx)
	for i := 0; i < upstreamFailureWindows; i++ {
		stats.ChinaErr++
		m.check(ctx)
	}
	if len(recorder.messages) != 1 || !strings.Contains(recorder.messages[0], "国内上游") {
		t.Fatalf("sustained failure alerts = %v", recorder.messages)
	}
	stats.ChinaOK++
	m.check(ctx)
	if len(recorder.messages) != 2 || !strings.Contains(recorder.messages[1], "恢复") {
		t.Fatalf("upstream recovery alerts = %v", recorder.messages)
	}
}
