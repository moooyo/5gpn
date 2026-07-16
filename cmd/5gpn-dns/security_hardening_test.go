package main

import (
	"context"
	"net"
	"os"
	"testing"

	"github.com/miekg/dns"
)

// TestMain relaxes the subscription SSRF dial guard for the whole test suite,
// because the subscription tests fetch from loopback httptest servers (which the
// production guard correctly refuses). The guard's own logic is covered by
// TestSubscriptionSSRFPredicate, which exercises isInternalFetchIP directly and
// is unaffected by this override.
func TestMain(m *testing.M) {
	subDialAllowed = func(net.IP) bool { return true }
	os.Exit(m.Run())
}

// #8: the SSRF predicate rejects internal destinations (loopback, RFC1918,
// link-local incl. the 169.254.169.254 metadata endpoint, unspecified) and
// allows real public IPs.
func TestSubscriptionSSRFPredicate(t *testing.T) {
	internal := []string{
		"127.0.0.1", "::1", "10.0.0.1", "192.168.1.1", "172.16.5.5",
		"169.254.169.254", "0.0.0.0", "fe80::1", "fc00::1",
		"100.64.0.1",      // shared/CGNAT
		"198.18.0.1",      // benchmarking
		"203.0.113.7",     // documentation/reserved
		"224.0.0.1",       // IPv4 multicast
		"255.255.255.255", // reserved/limited broadcast
		"2001:db8::1",     // IPv6 documentation
		"ff02::1",         // IPv6 multicast
		"64:ff9b::1",      // NAT64 well-known prefix
		"2620:4f:8000::1", // AS112 direct-delegation special-purpose prefix
	}
	for _, s := range internal {
		if ip := net.ParseIP(s); ip == nil || !isInternalFetchIP(ip) {
			t.Errorf("isInternalFetchIP(%s) = false, want true (must be blocked)", s)
		}
	}
	public := []string{"8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111"}
	for _, s := range public {
		if ip := net.ParseIP(s); ip == nil || isInternalFetchIP(ip) {
			t.Errorf("isInternalFetchIP(%s) = true, want false (must be allowed)", s)
		}
	}
}

// #11: with no gateway configured (unspecified GatewayIP), a foreign default-path
// answer is returned as-is (plain split-aware degrade) rather than rewritten to a
// blackhole 0.0.0.0.
func TestNoGatewayDegradesInsteadOfBlackhole(t *testing.T) {
	china := &fakeExchanger{reply: makeAMsg("foreign.test", "9.9.9.9")}
	trust := &fakeExchanger{reply: makeAMsg("foreign.test", "9.9.9.9")}
	h := newTestHandler(t, china, trust)
	h.GatewayIP = net.IPv4(0, 0, 0, 0) // unspecified → no steering

	q := dns.Question{Name: "foreign.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("foreign.test.", dns.TypeA)
	resp := h.resolve(context.Background(), q, req)

	ips := collectAIPs(resp)
	if len(ips) != 1 || ips[0] != "9.9.9.9" {
		t.Errorf("no-gateway degrade should return the real foreign IP as-is, got %v", ips)
	}
}

// With no gateway, a force-proxy name returns NXDOMAIN instead of 0.0.0.0.
func TestNoGatewayForceProxyReturnsNXDOMAIN(t *testing.T) {
	china := &fakeExchanger{}
	trust := &fakeExchanger{}
	h := newTestHandler(t, china, trust)
	h.GatewayIP = nil // unset

	q := dns.Question{Name: "proxy.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET}
	req := new(dns.Msg)
	req.SetQuestion("proxy.test.", dns.TypeA)
	resp := h.resolve(context.Background(), q, req)

	if resp.Rcode != dns.RcodeNameError {
		t.Errorf("no-gateway force-proxy should be NXDOMAIN, got rcode %d with answer %v", resp.Rcode, resp.Answer)
	}
}
