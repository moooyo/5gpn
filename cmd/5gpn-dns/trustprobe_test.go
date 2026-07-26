package main

import "testing"

// The exact failure the probe exists to catch: a resolver that answers every
// name with an address in its own /24. Nothing else in the daemon can see it,
// because rewriteA replaces a foreign address with GatewayIP before any client
// receives it, so browsing keeps working while trust resolves nothing.
func TestImplausibleTrustAnswer(t *testing.T) {
	placeholder := []TrustEntry{{ServerName: "22.22.22.22", DialAddr: "22.22.22.22", Transport: TrustPlainUDP}}
	google := []TrustEntry{{ServerName: "dns.google", DialAddr: "8.8.8.8", Transport: TrustDoT}}

	for _, tc := range []struct {
		name    string
		ips     []string
		entries []TrustEntry
		flagged bool
	}{
		{"resolver answers with its own /24", []string{"22.22.22.18"}, placeholder, true},
		{"resolver answers with itself", []string{"22.22.22.22"}, placeholder, true},
		{"private address for a public name", []string{"192.168.1.10"}, google, true},
		{"loopback for a public name", []string{"127.0.0.1"}, google, true},
		{"genuine public answer", []string{"93.184.216.34"}, google, false},
		{"genuine answer, placeholder group", []string{"93.184.216.34"}, placeholder, false},
		// A member with an explicit port must still be compared correctly.
		{"same /24 with an explicit port", []string{"22.22.22.9"}, []TrustEntry{{DialAddr: "22.22.22.22:53"}}, true},
		{"no addresses at all", nil, google, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			why := implausibleTrustAnswer(tc.ips, tc.entries)
			if tc.flagged && why == "" {
				t.Errorf("implausibleTrustAnswer(%v) = ok, want it flagged", tc.ips)
			}
			if !tc.flagged && why != "" {
				t.Errorf("implausibleTrustAnswer(%v) = %q, want ok", tc.ips, why)
			}
		})
	}
}

// Ranges that are not private but can never be a genuine public answer. A
// placeholder trust resolver on a real gateway answered example.com with
// 198.18.1.12, which ip.IsPrivate() does not catch, and the probe called it
// genuine.
func TestImplausibleTrustAnswer_ReservedRanges(t *testing.T) {
	google := []TrustEntry{{ServerName: "dns.google", DialAddr: "8.8.8.8", Transport: TrustDoT}}
	for _, tc := range []struct {
		ip      string
		flagged bool
	}{
		{"198.18.1.12", true},    // RFC 2544 benchmarking — the observed case
		{"100.64.0.7", true},     // CGNAT
		{"192.0.2.5", true},      // documentation
		{"198.51.100.5", true},   // documentation
		{"203.0.113.5", true},    // documentation
		{"240.0.0.1", true},      // reserved
		{"93.184.216.34", false}, // a genuine public answer
		{"1.1.1.1", false},
	} {
		why := implausibleTrustAnswer([]string{tc.ip}, google)
		if tc.flagged && why == "" {
			t.Errorf("%s = ok, want it flagged as never-a-real-answer", tc.ip)
		}
		if !tc.flagged && why != "" {
			t.Errorf("%s = %q, want ok", tc.ip, why)
		}
	}
}
