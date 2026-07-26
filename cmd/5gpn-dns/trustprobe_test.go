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
