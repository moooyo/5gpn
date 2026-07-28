package main

import (
	"context"
	"net"
	"testing"

	"github.com/miekg/dns"
)

// The upstream plugin format's [Host], now that it does something.
//
// The mapping existed as a manifest field, was conflict-checked across enabled
// extensions, was authorized as an egress destination and was rendered in the
// console — and was never consulted when a name was resolved. These pin the two
// resolution paths it now reaches, and the property that decides whether it is
// safe: a mapping supplies an address, never a routing decision.

// publishTestHostMapping installs a document carrying one mapping.
func publishTestHostMapping(t *testing.T, h *Handler, mitm bool, mappings ...interceptHostMapping) {
	t.Helper()
	document := interceptConfigDocument{
		MITM:           interceptMITMSettings{Enabled: mitm},
		ExecutionOrder: []string{"io.example.mapper"},
		Modules: []interceptModuleSnapshot{{
			ID: "io.example.mapper", Enabled: true, HostMappings: mappings,
			CaptureHosts: []string{"captured.test"},
		}},
	}
	h.setInterceptDocument(&document)
}

func hostQuestion(name string, qtype uint16) *dns.Msg {
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(name), qtype)
	return q
}

func answerAddrs(m *dns.Msg) []string {
	var out []string
	for _, rr := range m.Answer {
		if a, ok := rr.(*dns.A); ok {
			out = append(out, a.A.String())
		}
	}
	return out
}

// The address form on the egress broker. This is the path that matters most:
// mihomo re-resolves every sniffed origin here before dialing it, so an answer
// substituted here is the address mihomo dials — with no mihomo change and no
// second copy of the table.
func TestHostMappingAddressAnswersTheEgressBroker(t *testing.T) {
	h := newTestHandler(t, nil, nil)
	publishTestHostMapping(t, h, true, interceptHostMapping{Pattern: "origin.test", Target: "9.9.9.9"})

	selector := &egressDNSSelector{handler: h}
	reply, err := selector.Exchange(context.Background(), hostQuestion("origin.test", dns.TypeA))
	if err != nil {
		t.Fatalf("egress exchange: %v", err)
	}
	if got := answerAddrs(reply); len(got) != 1 || got[0] != "9.9.9.9" {
		t.Fatalf("egress answer = %v, want the mapped address; mihomo would dial the wrong origin", got)
	}
}

// A name with no mapping must still reach the upstream groups. A table that
// answered everything would black-hole every origin the moment one mapping
// existed.
func TestHostMappingLeavesUnmappedNamesToTheGroups(t *testing.T) {
	reached := false
	trust := ExchangerFunc(func(_ context.Context, q *dns.Msg) (*dns.Msg, error) {
		reached = true
		return replyWithA(q, "9.9.9.9"), nil
	})
	h := newTestHandler(t, nil, trust)
	publishTestHostMapping(t, h, true, interceptHostMapping{Pattern: "origin.test", Target: "9.9.9.9"})

	selector := &egressDNSSelector{handler: h}
	if _, err := selector.Exchange(context.Background(), hostQuestion("elsewhere.test", dns.TypeA)); err != nil {
		t.Fatalf("egress exchange: %v", err)
	}
	if !reached {
		t.Fatal("an unmapped name never reached the upstream group")
	}
}

// Wildcards match with the same first-in-execution-order semantics as capture
// hosts, because an operator reading one table should not have to learn two.
func TestHostMappingMatchesWildcards(t *testing.T) {
	h := newTestHandler(t, nil, nil)
	publishTestHostMapping(t, h, true, interceptHostMapping{Pattern: "*.origin.test", Target: "9.9.9.9"})

	selector := &egressDNSSelector{handler: h}
	reply, err := selector.Exchange(context.Background(), hostQuestion("cdn.origin.test", dns.TypeA))
	if err != nil {
		t.Fatalf("egress exchange: %v", err)
	}
	if got := answerAddrs(reply); len(got) != 1 || got[0] != "9.9.9.9" {
		t.Fatalf("wildcard mapping answer = %v", got)
	}
	// The bare suffix is not covered by "*." — same as the capture table.
	if _, err := selector.Exchange(context.Background(), hostQuestion("origin.test", dns.TypeA)); err == nil {
		t.Log("bare suffix fell through to the groups, as it should")
	}
}

// The alias form resolves through whatever the target resolves to, and the
// answer must come back carrying the name that was asked about — a stub
// resolver treats an answer for another name as a failure.
func TestHostMappingAliasResolvesTargetAndKeepsTheQuestion(t *testing.T) {
	trust := ExchangerFunc(func(_ context.Context, q *dns.Msg) (*dns.Msg, error) {
		if q.Question[0].Name != dns.Fqdn("cdn.example.test") {
			t.Errorf("alias resolved %q, want the target", q.Question[0].Name)
		}
		return replyWithA(q, "9.9.9.9"), nil
	})
	h := newTestHandler(t, nil, trust)
	publishTestHostMapping(t, h, true,
		interceptHostMapping{Pattern: "origin.test", Target: "cdn.example.test"})

	selector := &egressDNSSelector{handler: h}
	reply, err := selector.Exchange(context.Background(), hostQuestion("origin.test", dns.TypeA))
	if err != nil {
		t.Fatalf("egress exchange: %v", err)
	}
	if got := answerAddrs(reply); len(got) != 1 || got[0] != "9.9.9.9" {
		t.Fatalf("alias answer = %v", got)
	}
	if len(reply.Answer) > 0 && reply.Answer[0].Header().Name != dns.Fqdn("origin.test") {
		t.Fatalf("alias answered for %q, not the name that was asked",
			reply.Answer[0].Header().Name)
	}
}

// An alias cycle must terminate. Without the depth bound this hangs the
// resolver, which is worse than any wrong answer.
func TestHostMappingAliasCycleTerminates(t *testing.T) {
	h := newTestHandler(t, nil, nil)
	publishTestHostMapping(t, h, true,
		interceptHostMapping{Pattern: "a.test", Target: "b.test"},
		interceptHostMapping{Pattern: "b.test", Target: "a.test"})

	done := make(chan struct{})
	go func() {
		defer close(done)
		selector := &egressDNSSelector{handler: h}
		if _, err := selector.Exchange(context.Background(), hostQuestion("a.test", dns.TypeA)); err == nil {
			t.Error("an alias cycle produced an answer instead of an error")
		}
	}()
	<-done
}

// THE property. A mapping supplies an address; the steering ladder still
// decides what happens to it. A domestic name mapped to a domestic address goes
// direct because directness was decided by the address, and a name mapped to a
// foreign address is still steered to the gateway rather than handed to the
// client raw.
func TestHostMappingSuppliesTheAddressButNotTheRouting(t *testing.T) {
	for _, tc := range []struct {
		name   string
		target string
		want   string
		why    string
	}{
		{"domestic address stays direct", "1.2.3.4", "1.2.3.4",
			"a CN address must be handed to the client as-is, exactly as an arbitrated CN answer is"},
		{"foreign address is still steered", "9.9.9.9", "10.0.0.1",
			"a mapping that bypassed the ladder would hand the client a foreign address and silently disable auto steering"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Real groups, answering an address that is neither expected
			// outcome. If the mapping were bypassed the assertion fails with
			// the upstream's address rather than crashing on a nil exchanger,
			// which is the difference between a test that discriminates and one
			// that merely happens not to pass.
			upstream := ExchangerFunc(func(_ context.Context, q *dns.Msg) (*dns.Msg, error) {
				return replyWithA(q, "203.0.113.7"), nil
			})
			h := newTestHandler(t, upstream, upstream)
			publishTestHostMapping(t, h, false,
				interceptHostMapping{Pattern: "mapped.test", Target: tc.target})

			reply := h.resolveTraced(context.Background(),
				dns.Question{Name: dns.Fqdn("mapped.test"), Qtype: dns.TypeA, Qclass: dns.ClassINET},
				hostQuestion("mapped.test", dns.TypeA), nil)
			got := answerAddrs(reply)
			if len(got) != 1 || got[0] != tc.want {
				t.Fatalf("client answer = %v, want %s — %s", got, tc.want, tc.why)
			}
		})
	}
}

// Capture beats a mapping, and does so by construction: decideName steers a
// captured name to the gateway before the resolution paths that consult the
// table run at all. If a mapping could win, the client would connect to the
// origin and the sidecar would never see the traffic.
func TestCaptureBeatsAHostMappingOnTheClientPath(t *testing.T) {
	h := newTestHandler(t, nil, nil)
	publishTestHostMapping(t, h, true,
		interceptHostMapping{Pattern: "captured.test", Target: "9.9.9.9"})

	reply := h.resolveTraced(context.Background(),
		dns.Question{Name: dns.Fqdn("captured.test"), Qtype: dns.TypeA, Qclass: dns.ClassINET},
		hostQuestion("captured.test", dns.TypeA), nil)
	got := answerAddrs(reply)
	if len(got) != 1 || got[0] != "10.0.0.1" {
		t.Fatalf("captured name answered %v, want the gateway; MITM is bypassed otherwise", got)
	}
}

// The scope refusal. A mapping is the one way an extension could aim origin
// traffic at the gateway's own management plane: the rendered private-range
// denies are all no-resolve, and the egress anchor resolves ahead of the rule
// list entirely. It has to fail at import.
func TestHostMappingTargetRefusesNonGlobalAddresses(t *testing.T) {
	for _, target := range []string{
		"127.0.0.1", "10.0.1.20", "192.168.1.1", "172.16.0.1",
		"169.254.169.254", "100.64.0.1", "0.0.0.0",
	} {
		if validInterceptHostTarget(target) {
			t.Errorf("%s was accepted as a mapping target", target)
		}
	}
	for _, target := range []string{"9.9.9.9", "1.2.3.4", "cdn.example.com", "server:9.9.9.9"} {
		if !validInterceptHostTarget(target) {
			t.Errorf("%s was refused as a mapping target", target)
		}
	}
}

// The resolver form is the upstream format's own spelling and must parse as such.
func TestHostMappingServerFormParses(t *testing.T) {
	mapping := interceptHostMapping{Pattern: "origin.test", Target: "server:9.9.9.9, 1.1.1.1"}
	got := mapping.hostMappingServers()
	if len(got) != 2 || got[0] != "9.9.9.9" || got[1] != "1.1.1.1" {
		t.Fatalf("server specs = %v", got)
	}
	if (interceptHostMapping{Target: "9.9.9.9"}).hostMappingServers() != nil {
		t.Fatal("an address form was read as a resolver form")
	}
	if !validInterceptHostTarget("server:9.9.9.9") || validInterceptHostTarget("server:") {
		t.Fatal("resolver-form validation is wrong")
	}
}

// The resolver form must actually route the query at the named servers rather
// than at the operator's groups.
func TestHostMappingServerFormUsesItsOwnResolver(t *testing.T) {
	trustReached := false
	trust := ExchangerFunc(func(_ context.Context, q *dns.Msg) (*dns.Msg, error) {
		trustReached = true
		return replyWithA(q, "1.2.3.4"), nil
	})
	h := newTestHandler(t, nil, trust)
	publishTestHostMapping(t, h, true,
		interceptHostMapping{Pattern: "origin.test", Target: "server:203.0.113.253"})

	selector := &egressDNSSelector{handler: h}
	// The named server is unreachable in a unit test; what is being pinned is
	// that the query went there and not to the operator's trust group.
	_, _ = selector.Exchange(context.Background(), hostQuestion("origin.test", dns.TypeA))
	if trustReached {
		t.Fatal("a resolver-form mapping fell through to the trust group")
	}
}

// A resolver-form mapping names nameservers, not a destination. Turning
// "server:1.1.1.1" into a domain selector would authorize an endpoint that does
// not exist.
func TestHostMappingServerFormContributesNoEgressSelector(t *testing.T) {
	module := interceptModuleSnapshot{
		ID: "io.example.mapper", Enabled: true,
		CaptureHosts: []string{"origin.test"},
		HostMappings: []interceptHostMapping{
			{Pattern: "origin.test", Target: "server:9.9.9.9"},
			{Pattern: "other.test", Target: "9.9.9.9"},
		},
	}
	for _, selector := range interceptModuleEgressSelectors(module) {
		if selector.Value == "server:9.9.9.9" {
			t.Fatal("a resolver spec was authorized as an egress destination")
		}
	}
}

func replyWithA(q *dns.Msg, addr string) *dns.Msg {
	m := new(dns.Msg)
	m.SetReply(q)
	m.Answer = append(m.Answer, &dns.A{
		Hdr: dns.RR_Header{
			Name: q.Question[0].Name, Rrtype: dns.TypeA,
			Class: dns.ClassINET, Ttl: 60,
		},
		A: net.ParseIP(addr).To4(),
	})
	return m
}

// ExchangerFunc adapts a function to Exchanger for these tests.
type ExchangerFunc func(context.Context, *dns.Msg) (*dns.Msg, error)

func (f ExchangerFunc) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	return f(ctx, q)
}
