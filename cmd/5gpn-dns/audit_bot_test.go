package main

import "testing"

// C1: audit classification must flag every mutating/privileged callback (and
// only those), so the bot's audit trail matches the :9443 API's. Read-only
// navigation must not be audited.
func TestAuditableCallbackOp(t *testing.T) {
	mutating := map[callbackKind]string{
		cbReload:  "reload",
		cbRenew:   "renew-cert",
		cbRestart: "restart:",
		cbLogs:    "logs:",
		cbIOS:     "ios-profile",
	}
	for kind, wantPrefix := range mutating {
		op, ok := auditableCallbackOp(callbackIntent{kind: kind})
		if !ok {
			t.Errorf("kind %v should be auditable", kind)
		}
		if len(wantPrefix) > 0 && len(op) < len(wantPrefix) {
			t.Errorf("kind %v op=%q, want prefix %q", kind, op, wantPrefix)
		}
	}

	// Read-only / navigation intents must NOT be audited.
	readOnly := []callbackKind{
		cbUnknown, cbMenuMain, cbStatus,
		cbMenuRestart, cbMenuLogs,
	}
	for _, kind := range readOnly {
		if op, ok := auditableCallbackOp(callbackIntent{kind: kind}); ok {
			t.Errorf("kind %v should NOT be auditable, got op=%q", kind, op)
		}
	}
}

func TestAuditResult(t *testing.T) {
	if auditResult(true) != "ok" {
		t.Errorf("auditResult(true) = %q, want ok", auditResult(true))
	}
	if auditResult(false) != "err" {
		t.Errorf("auditResult(false) = %q, want err", auditResult(false))
	}
}
