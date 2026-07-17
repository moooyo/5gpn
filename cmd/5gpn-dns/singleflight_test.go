package main

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
)

type blockingFlightExchanger struct {
	calls   atomic.Int32
	started chan string
	release <-chan struct{}
}

func (x *blockingFlightExchanger) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	x.calls.Add(1)
	name := ""
	if len(q.Question) > 0 {
		name = q.Question[0].Name
	}
	select {
	case x.started <- name:
	default:
	}
	select {
	case <-x.release:
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	resp := new(dns.Msg)
	resp.SetReply(q)
	resp.Answer = append(resp.Answer, &dns.TXT{
		Hdr: dns.RR_Header{Name: name, Rrtype: dns.TypeTXT, Class: dns.ClassINET, Ttl: 60},
		Txt: []string{"ok"},
	})
	return resp, nil
}

func TestDNSFlightCoalescesConcurrentCacheMisses(t *testing.T) {
	release := make(chan struct{})
	trust := &blockingFlightExchanger{started: make(chan string, 32), release: release}
	h := newTestHandler(t, &fakeExchanger{}, trust)

	const callers = 24
	gate := make(chan struct{})
	var ready sync.WaitGroup
	ready.Add(callers)
	results := make(chan *dns.Msg, callers)
	for i := 0; i < callers; i++ {
		go func(id int) {
			ready.Done()
			<-gate
			req := new(dns.Msg)
			req.Id = uint16(id + 1)
			req.Question = []dns.Question{{Name: "Burst.Example.", Qtype: dns.TypeTXT, Qclass: dns.ClassINET}}
			results <- h.resolve(context.Background(), req.Question[0], req)
		}(i)
	}
	ready.Wait()
	close(gate)

	select {
	case <-trust.started:
	case <-time.After(time.Second):
		t.Fatal("shared upstream resolution did not start")
	}
	time.Sleep(50 * time.Millisecond)
	if got := trust.calls.Load(); got != 1 {
		t.Fatalf("upstream calls while requests are concurrent = %d, want 1", got)
	}
	close(release)

	seenIDs := make(map[uint16]bool, callers)
	for i := 0; i < callers; i++ {
		select {
		case resp := <-results:
			if resp == nil || resp.Rcode != dns.RcodeSuccess {
				t.Fatalf("caller received unsuccessful response: %#v", resp)
			}
			seenIDs[resp.Id] = true
			if len(resp.Question) != 1 || resp.Question[0].Name != "Burst.Example." {
				t.Fatalf("caller question was not restored: %#v", resp.Question)
			}
		case <-time.After(time.Second):
			t.Fatal("timed out waiting for coalesced response")
		}
	}
	for id := 1; id <= callers; id++ {
		if !seenIDs[uint16(id)] {
			t.Fatalf("response ID %d was not restored", id)
		}
	}
}

func TestDNSFlightWaiterCancellationDoesNotCancelSharedQuery(t *testing.T) {
	release := make(chan struct{})
	trust := &blockingFlightExchanger{started: make(chan string, 4), release: release}
	h := newTestHandler(t, &fakeExchanger{}, trust)

	req := new(dns.Msg)
	req.SetQuestion("cancel.example.", dns.TypeTXT)
	leaderResult := make(chan *dns.Msg, 1)
	go func() {
		leaderResult <- h.resolve(context.Background(), req.Question[0], req)
	}()
	select {
	case <-trust.started:
	case <-time.After(time.Second):
		t.Fatal("shared upstream resolution did not start")
	}

	waitCtx, cancel := context.WithCancel(context.Background())
	waiterResult := make(chan *dns.Msg, 1)
	go func() {
		waitReq := req.Copy()
		waitReq.Id++
		waiterResult <- h.resolve(waitCtx, waitReq.Question[0], waitReq)
	}()
	time.Sleep(20 * time.Millisecond)
	cancel()

	select {
	case resp := <-waiterResult:
		if resp == nil || resp.Rcode != dns.RcodeServerFailure {
			t.Fatalf("canceled waiter response = %#v, want SERVFAIL", resp)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled waiter did not return promptly")
	}
	select {
	case <-leaderResult:
		t.Fatal("canceling a waiter canceled the shared query")
	default:
	}
	if got := trust.calls.Load(); got != 1 {
		t.Fatalf("upstream calls after waiter cancellation = %d, want 1", got)
	}

	close(release)
	select {
	case resp := <-leaderResult:
		if resp == nil || resp.Rcode != dns.RcodeSuccess {
			t.Fatalf("leader response = %#v, want success", resp)
		}
	case <-time.After(time.Second):
		t.Fatal("shared query did not complete after release")
	}
}

func TestDNSFlightMapCapacityIsBounded(t *testing.T) {
	release := make(chan struct{})
	trust := &blockingFlightExchanger{started: make(chan string, 4), release: release}
	h := newTestHandler(t, &fakeExchanger{}, trust)
	h.flightLimit = 1

	results := make(chan *dns.Msg, 2)
	for i := 0; i < 2; i++ {
		name := fmt.Sprintf("capacity-%d.example.", i)
		go func() {
			req := new(dns.Msg)
			req.SetQuestion(name, dns.TypeTXT)
			results <- h.resolve(context.Background(), req.Question[0], req)
		}()
		select {
		case <-trust.started:
		case <-time.After(time.Second):
			t.Fatalf("upstream resolution %d did not start", i+1)
		}
	}

	h.flightMu.Lock()
	flightCount := len(h.flights)
	h.flightMu.Unlock()
	if flightCount != 1 {
		t.Fatalf("tracked flight count = %d, want hard cap 1", flightCount)
	}
	if got := trust.calls.Load(); got != 2 {
		t.Fatalf("capacity fallback upstream calls = %d, want 2 independent resolutions", got)
	}

	close(release)
	for i := 0; i < 2; i++ {
		select {
		case resp := <-results:
			if resp == nil || resp.Rcode != dns.RcodeSuccess {
				t.Fatalf("capacity fallback response = %#v", resp)
			}
		case <-time.After(time.Second):
			t.Fatal("capacity fallback did not complete")
		}
	}
}

func TestDNSFlightKeySeparatesResponseVaryingRequestProperties(t *testing.T) {
	scope := dnsFlightScope{epoch: 7, action: actionAuto}
	baseQ := dns.Question{Name: "Key.Example.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	baseReq := new(dns.Msg)
	baseReq.Question = []dns.Question{baseQ}
	baseReq.SetEdns0(1232, true)
	base := newDNSFlightKey(baseQ, baseReq, scope)

	caseVariant := baseQ
	caseVariant.Name = "key.example."
	if got := newDNSFlightKey(caseVariant, baseReq, scope); got != base {
		t.Fatal("DNS name casing must not split a flight")
	}

	variants := []struct {
		name string
		q    dns.Question
		req  *dns.Msg
	}{
		{name: "qtype", q: dns.Question{Name: baseQ.Name, Qtype: dns.TypeTXT, Qclass: dns.ClassINET}, req: baseReq},
		{name: "qclass", q: dns.Question{Name: baseQ.Name, Qtype: dns.TypeA, Qclass: dns.ClassCHAOS}, req: baseReq},
	}
	withoutDO := baseReq.Copy()
	withoutDO.IsEdns0().SetDo(false)
	variants = append(variants, struct {
		name string
		q    dns.Question
		req  *dns.Msg
	}{name: "DO", q: baseQ, req: withoutDO})
	withCD := baseReq.Copy()
	withCD.CheckingDisabled = true
	variants = append(variants, struct {
		name string
		q    dns.Question
		req  *dns.Msg
	}{name: "CD", q: baseQ, req: withCD})

	for _, tc := range variants {
		if got := newDNSFlightKey(tc.q, tc.req, scope); got == base {
			t.Errorf("%s change did not split the flight key", tc.name)
		}
	}
}
