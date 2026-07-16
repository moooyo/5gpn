package main

import (
	"context"
	"fmt"
	"html"
	"log"
	"time"
)

const (
	botAlertInterval       = time.Minute
	botAlertInitialDelay   = 15 * time.Second
	upstreamFailureWindows = 3
)

type botAlertNotifier interface {
	NotifyAdmins(ctx context.Context, text string) error
}

// botAlertMonitor emits transition-only Telegram alerts. It deliberately does
// not claim to detect the daemon's own death; the external heartbeat remains
// the only signal that survives a stopped process or powered-off gateway.
type botAlertMonitor struct {
	notifier  botAlertNotifier
	statsFn   func() Stats
	certFn    func() (CertStatus, bool)
	serviceFn func() string

	lastCert    string
	lastMihomo  string
	previous    Stats
	statsLoaded bool
	chinaStreak int
	trustStreak int
	chinaAlert  bool
	trustAlert  bool
}

func newBotAlertMonitor(ctrl *Controller, notifier botAlertNotifier) *botAlertMonitor {
	return &botAlertMonitor{
		notifier: notifier,
		statsFn:  ctrl.Stats,
		certFn:   ctrl.CertStatus,
		serviceFn: func() string {
			_, out := run([]string{"systemctl", "is-active", "mihomo"}, 5*time.Second)
			return normalizedServiceState(out)
		},
	}
}

func (m *botAlertMonitor) Run(ctx context.Context) {
	timer := time.NewTimer(botAlertInitialDelay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return
	case <-timer.C:
	}
	m.check(ctx)

	ticker := time.NewTicker(botAlertInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.check(ctx)
		}
	}
}

func (m *botAlertMonitor) deliver(ctx context.Context, text string) bool {
	alertCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := m.notifier.NotifyAdmins(alertCtx, text); err != nil {
		log.Printf("telegram alert delivery failed: %v", err)
		return false
	}
	return true
}

func (m *botAlertMonitor) check(ctx context.Context) {
	m.checkCertificate(ctx)
	m.checkMihomo(ctx)
	m.checkUpstreams(ctx)
}

func certAlertState(status CertStatus, ok bool) (key, text string) {
	if !ok {
		return "unknown", ""
	}
	switch {
	case status.Broken:
		return "broken", "🔴 <b>5gpn 证书无法加载</b>\nDoT/控制台可能已失效或仍在使用旧证书，请立即检查。"
	case status.Expired:
		return "expired", "🔴 <b>5gpn TLS 证书已过期</b>\n请立即续期并检查 DoT 握手。"
	case status.DaysRemaining <= 14:
		return "expiring", fmt.Sprintf("🟠 <b>5gpn TLS 证书即将过期</b>\n剩余 %d 天（%s）。", status.DaysRemaining, status.NotAfter.Format("2006-01-02"))
	default:
		return "healthy", "✅ <b>5gpn TLS 证书已恢复正常</b>"
	}
}

func (m *botAlertMonitor) checkCertificate(ctx context.Context) {
	key, message := certAlertState(m.certFn())
	if key == "unknown" || key == m.lastCert {
		return
	}
	if m.lastCert == "" && key == "healthy" {
		m.lastCert = key
		return
	}
	if message != "" && m.deliver(ctx, message) {
		m.lastCert = key
	}
}

func (m *botAlertMonitor) checkMihomo(ctx context.Context) {
	state := m.serviceFn()
	if state == m.lastMihomo {
		return
	}
	if m.lastMihomo == "" && state == "active" {
		m.lastMihomo = state
		return
	}
	message := "🔴 <b>Mihomo 异常</b>\n当前 systemd 状态：<code>" + html.EscapeString(state) + "</code>"
	if state == "active" {
		message = "✅ <b>Mihomo 已恢复 active</b>"
	}
	if m.deliver(ctx, message) {
		m.lastMihomo = state
	}
}

func counterDelta(now, before uint64) uint64 {
	if now < before {
		return now // counter was reset/restarted
	}
	return now - before
}

func (m *botAlertMonitor) checkUpstreams(ctx context.Context) {
	current := m.statsFn()
	if !m.statsLoaded {
		m.previous = current
		m.statsLoaded = true
		return
	}
	chinaOK := counterDelta(current.ChinaOK, m.previous.ChinaOK)
	chinaErr := counterDelta(current.ChinaErr, m.previous.ChinaErr)
	trustOK := counterDelta(current.TrustOK, m.previous.TrustOK)
	trustErr := counterDelta(current.TrustErr, m.previous.TrustErr)
	m.previous = current
	m.checkUpstreamGroup(ctx, "国内", chinaOK, chinaErr, &m.chinaStreak, &m.chinaAlert)
	m.checkUpstreamGroup(ctx, "境外", trustOK, trustErr, &m.trustStreak, &m.trustAlert)
}

func (m *botAlertMonitor) checkUpstreamGroup(ctx context.Context, label string, okDelta, errDelta uint64, streak *int, alerted *bool) {
	switch {
	case okDelta > 0:
		*streak = 0
		if *alerted && m.deliver(ctx, "✅ <b>"+label+"上游 DNS 已恢复</b>") {
			*alerted = false
		}
	case errDelta > 0:
		*streak++
		if *streak >= upstreamFailureWindows && !*alerted {
			message := fmt.Sprintf("🔴 <b>%s上游 DNS 持续失败</b>\n连续 %d 个检查窗口无成功响应。", label, *streak)
			if m.deliver(ctx, message) {
				*alerted = true
			}
		}
	default:
		*streak = 0 // no traffic is not evidence of an upstream outage
	}
}
