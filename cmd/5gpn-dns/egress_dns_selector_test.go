package main

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func TestEgressDNSSelectorDefaultsToTrust(t *testing.T) {
	china := &brokerFakeExchanger{resp: mkA(t, "example.com", "1.2.3.4")}
	trust := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.7")}
	h := &Handler{China: china, Trust: trust}
	selector := &egressDNSSelector{handler: h}

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	resp, err := selector.Exchange(context.Background(), q)
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	if got := resp.Answer[0].(*dns.A).A.String(); got != "203.0.113.7" {
		t.Fatalf("answer = %s, want trust answer", got)
	}
	if china.callCount() != 0 || trust.callCount() != 1 {
		t.Fatalf("calls china=%d trust=%d, want 0/1", china.callCount(), trust.callCount())
	}
}

func TestEgressDNSSelectorUsesChinaBindingAndExecutionOrder(t *testing.T) {
	china := &brokerFakeExchanger{resp: mkA(t, "api.example.com", "1.2.3.4")}
	trust := &brokerFakeExchanger{resp: mkA(t, "api.example.com", "203.0.113.7")}
	h := &Handler{China: china, Trust: trust}
	first := testModuleSnapshot()
	first.ID = "io.example.first"
	first.CaptureHosts = []string{"*.example.com"}
	first.CaptureDNS = interceptCaptureDNSChina
	first.Enabled = true
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.CaptureHosts = []string{"api.example.com"}
	second.CaptureDNS = interceptCaptureDNSTrust
	second.Enabled = true
	document, _ := testInterceptDocument(t, first, second)
	h.setInterceptDocument(&document)

	q := new(dns.Msg)
	q.SetQuestion("api.example.com.", dns.TypeA)
	resp, err := (&egressDNSSelector{handler: h}).Exchange(context.Background(), q)
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	if got := resp.Answer[0].(*dns.A).A.String(); got != "1.2.3.4" {
		t.Fatalf("answer = %s, want first extension's China answer", got)
	}
	if resolver, owner := h.captureDNSForName("api.example.com"); resolver != interceptCaptureDNSChina || owner != first.ID {
		t.Fatalf("binding = %s/%s, want china/%s", resolver, owner, first.ID)
	}
}

func TestInterceptHostSnapshotDeduplicatesPatternsWithoutChangingWinner(t *testing.T) {
	first := testModuleSnapshot()
	first.ID = "io.example.first"
	first.Enabled = true
	first.CaptureDNS = interceptCaptureDNSChina
	first.CaptureHosts = []string{"*.example.com", "api.example.com"}
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Enabled = true
	second.CaptureDNS = interceptCaptureDNSTrust
	second.CaptureHosts = append([]string(nil), first.CaptureHosts...)
	document, _ := testInterceptDocument(t, first, second)
	snapshot := newInterceptHostSnapshot(document)
	if len(snapshot.exact) != 1 || len(snapshot.wildcard) != 1 {
		t.Fatalf("compiled matcher size exact=%d wildcard=%d, want 1/1", len(snapshot.exact), len(snapshot.wildcard))
	}
	for _, name := range []string{"api.example.com", "cdn.example.com"} {
		resolver, owner, matched := snapshot.CaptureDNS(name)
		if !matched || resolver != interceptCaptureDNSChina || owner != first.ID {
			t.Fatalf("%s binding = %t/%s/%s, want first China binding", name, matched, resolver, owner)
		}
	}
}

func TestEgressDNSSelectorChinaBindingCarriesLiveECS(t *testing.T) {
	got := make(chan *dns.EDNS0_SUBNET, 1)
	addr := startLocalUDPDNS(t, captureECSHandler(got))
	china := NewUDPGroup([]string{addr}, false)
	subnet, err := parseECS("112.96.32.0/24")
	if err != nil {
		t.Fatal(err)
	}
	SetGroupECS(china, subnet)
	trust := &brokerFakeExchanger{resp: mkA(t, "api.example.com", "203.0.113.7")}
	h := &Handler{China: china, Trust: trust}
	module := testModuleSnapshot()
	module.CaptureDNS = interceptCaptureDNSChina
	module.Enabled = true
	document, _ := testInterceptDocument(t, module)
	h.setInterceptDocument(&document)

	q := new(dns.Msg)
	q.SetQuestion("api.example.com.", dns.TypeA)
	if _, err := (&egressDNSSelector{handler: h}).Exchange(context.Background(), q); err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	select {
	case ecs := <-got:
		if ecs == nil || ecs.SourceNetmask != 24 || ecs.Address.String() != "112.96.32.0" {
			t.Fatalf("ECS = %+v, want 112.96.32.0/24", ecs)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("China upstream did not receive the query")
	}
	if trust.callCount() != 0 {
		t.Fatalf("trust calls = %d, want 0", trust.callCount())
	}
}

func TestEgressDNSSelectorTracksLiveUpstreamSwap(t *testing.T) {
	oldTrust := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.7")}
	newTrust := &brokerFakeExchanger{resp: mkA(t, "example.com", "203.0.113.8")}
	h := &Handler{Trust: oldTrust}
	selector := &egressDNSSelector{handler: h}
	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)

	if _, err := selector.Exchange(context.Background(), q); err != nil {
		t.Fatal(err)
	}
	h.swapUpstreams(&upstreamSnapshot{China: h.China, Trust: newTrust})
	resp, err := selector.Exchange(context.Background(), q)
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.Answer[0].(*dns.A).A.String(); got != "203.0.113.8" {
		t.Fatalf("answer = %s, want new trust answer", got)
	}
}

func TestNewDefaultEgressDNSBrokerRequiresBoundaryAndHandler(t *testing.T) {
	if _, err := newDefaultEgressDNSBroker(Config{}, &Handler{}); err == nil {
		t.Fatal("empty broker address must fail")
	}
	if _, err := newDefaultEgressDNSBroker(Config{EgressBrokerAddr: "127.0.0.1:5354"}, nil); err == nil {
		t.Fatal("nil handler must fail")
	}
	if broker, err := newDefaultEgressDNSBroker(Config{EgressBrokerAddr: "127.0.0.1:5354"}, &Handler{}); err != nil || broker == nil {
		t.Fatalf("valid broker = %v, %v", broker, err)
	}
}

var benchmarkCaptureDNSResolver, benchmarkCaptureDNSOwner string

func BenchmarkInterceptHostSnapshotCaptureDNS(b *testing.B) {
	for _, test := range []struct {
		name     string
		wildcard bool
	}{
		{name: "exact"},
		{name: "wildcard-last", wildcard: true},
	} {
		b.Run(test.name, func(b *testing.B) {
			hosts := make([]string, 512)
			for index := range hosts {
				if test.wildcard {
					hosts[index] = fmt.Sprintf("*.h%03d.example.com", index)
				} else {
					hosts[index] = fmt.Sprintf("h%03d.example.com", index)
				}
			}
			module := interceptModuleSnapshot{ID: "io.example.benchmark", Enabled: true, CaptureDNS: interceptCaptureDNSChina, CaptureHosts: hosts}
			document := interceptConfigDocument{
				MITM: interceptMITMSettings{Enabled: true}, ExecutionOrder: []string{module.ID}, Modules: []interceptModuleSnapshot{module},
			}
			snapshot := newInterceptHostSnapshot(document)
			name := "h511.example.com."
			if test.wildcard {
				name = "api.h511.example.com."
			}
			b.ReportAllocs()
			b.ResetTimer()
			for iteration := 0; iteration < b.N; iteration++ {
				benchmarkCaptureDNSResolver, benchmarkCaptureDNSOwner, _ = snapshot.CaptureDNS(name)
			}
		})
	}
}
