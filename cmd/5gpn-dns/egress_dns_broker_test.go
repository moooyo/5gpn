package main

import (
	"context"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/miekg/dns"
)

type brokerFakeExchanger struct {
	mu    sync.Mutex
	resp  *dns.Msg
	calls int
}

func (f *brokerFakeExchanger) Exchange(_ context.Context, m *dns.Msg) (*dns.Msg, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	out := f.resp.Copy()
	out.Id = m.Id
	return out, nil
}

func (f *brokerFakeExchanger) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func mkA(t *testing.T, name, ip string) *dns.Msg {
	t.Helper()
	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(name), dns.TypeA)
	m.Rcode = dns.RcodeSuccess
	m.RecursionAvailable = true
	m.Answer = append(m.Answer, &dns.A{
		Hdr: dns.RR_Header{Name: dns.Fqdn(name), Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 300},
		A:   net.ParseIP(ip).To4(),
	})
	return m
}

func exchangeUDP(t *testing.T, addr, name string) *dns.Msg {
	t.Helper()
	c := &dns.Client{Timeout: 2 * time.Second}
	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(name), dns.TypeA)
	resp, _, err := c.Exchange(m, addr)
	if err != nil {
		t.Fatalf("UDP exchange: %v", err)
	}
	return resp
}

func TestEgressDNSBroker_RejectsNonLoopback(t *testing.T) {
	b := NewEgressDNSBroker("0.0.0.0:0", nil)
	if err := b.Start(); err == nil {
		t.Fatal("Start must reject a non-loopback address")
	}
}

func TestEgressDNSBroker_UDPTCPParity(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.7")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())

	udp := exchangeUDP(t, b.UDPAddr().String(), "example.com")
	c := &dns.Client{Net: "tcp", Timeout: 2 * time.Second}
	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	tcp, _, err := c.Exchange(q, b.TCPAddr().String())
	if err != nil {
		t.Fatalf("TCP exchange: %v", err)
	}
	if udp.Rcode != tcp.Rcode || len(udp.Answer) != len(tcp.Answer) {
		t.Fatalf("UDP/TCP mismatch: udp=%v tcp=%v", udp, tcp)
	}
}

func TestEgressDNSBroker_MalformedQuestionIsFormerr(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.7")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	w := &captureDNSWriter{}
	b.ServeDNS(w, new(dns.Msg))
	if w.msg == nil || w.msg.Rcode != dns.RcodeFormatError {
		t.Fatalf("rcode=%v, want FORMERR", w.msg)
	}
}

func TestEgressDNSBroker_ShutdownIsIdempotent(t *testing.T) {
	b := NewEgressDNSBroker("127.0.0.1:0", nil)
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	b.Shutdown(context.Background())
	b.Shutdown(context.Background())
}

type captureDNSWriter struct{ msg *dns.Msg }

func (w *captureDNSWriter) LocalAddr() net.Addr         { return &net.UDPAddr{} }
func (w *captureDNSWriter) RemoteAddr() net.Addr        { return &net.UDPAddr{} }
func (w *captureDNSWriter) WriteMsg(m *dns.Msg) error   { w.msg = m; return nil }
func (w *captureDNSWriter) Write(p []byte) (int, error) { return len(p), nil }
func (w *captureDNSWriter) Close() error                { return nil }
func (w *captureDNSWriter) TsigStatus() error           { return nil }
func (w *captureDNSWriter) TsigTimersOnly(bool)         {}
func (w *captureDNSWriter) Hijack()                     {}

func TestEgressDNSBroker_LogsNoQueryData(t *testing.T) {
	fake := &brokerFakeExchanger{resp: mkA(t, "secret.example", "203.0.113.7")}
	b := NewEgressDNSBroker("127.0.0.1:0", fake)
	var logs strings.Builder
	b.logf = func(format string, args ...interface{}) { logs.WriteString(format) }
	if err := b.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer b.Shutdown(context.Background())
	_ = exchangeUDP(t, b.UDPAddr().String(), "secret.example")
	if strings.Contains(logs.String(), "secret.example") {
		t.Fatal("broker log leaked a query name")
	}
}
