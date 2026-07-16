package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

// Audit classification must flag every mutating/privileged callback (and
// only those), matching the control API. Read-only
// navigation must not be audited.
func TestAuditableCallbackOp(t *testing.T) {
	mutating := []struct {
		intent callbackIntent
		want   string
	}{
		{callbackIntent{kind: cbReload}, "reload"},
		{callbackIntent{kind: cbConfirmAction, arg: string(botActionRenewCert)}, "renew-cert"},
		{callbackIntent{kind: cbLogs, arg: "mihomo"}, "logs:mihomo"},
		{callbackIntent{kind: cbIOSPhoto}, "ios-profile-photo"},
	}
	for _, tc := range mutating {
		op, ok := auditableCallbackOp(tc.intent)
		if !ok {
			t.Errorf("kind %v should be auditable", tc.intent.kind)
		}
		if op != tc.want {
			t.Errorf("kind %v op=%q, want %q", tc.intent.kind, op, tc.want)
		}
	}

	// Read-only / navigation intents must NOT be audited.
	readOnly := []callbackKind{
		cbUnknown, cbMenuMain, cbStatus,
		cbMenuMaintenance, cbMenuLogs, cbMenuIOS, cbRequestConfirm,
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

func TestAuditBotOutcomeRecordsFinalAndSanitizesFields(t *testing.T) {
	var out bytes.Buffer
	original := log.Writer()
	log.SetOutput(&out)
	t.Cleanup(func() { log.SetOutput(original) })

	auditBotOutcome("restart:mihomo\nforged=1", 42, false)
	line := out.String()
	if !strings.Contains(line, "result=err") || !strings.Contains(line, "admin=42") {
		t.Fatalf("final audit line = %q", line)
	}
	if strings.Contains(line, "\nforged=1") {
		t.Fatalf("audit field allowed newline injection: %q", line)
	}
}
