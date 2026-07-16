package main

import (
	"math/rand"
	"net"
	"testing"
)

func TestChnrouteCIDRs_Empty(t *testing.T) {
	c := &Chnroute{}
	if cidrs := c.CIDRs(); cidrs != nil {
		t.Fatalf("expected nil, got %v", cidrs)
	}
	var nilC *Chnroute
	if cidrs := nilC.CIDRs(); cidrs != nil {
		t.Fatalf("expected nil for nil Chnroute, got %v", cidrs)
	}
}

func TestChnrouteCIDRs_SingleCIDR(t *testing.T) {
	cr, err := LoadChnrouteFiles() // no files = empty
	if err == nil || cr != nil {
		// Load from inline
	}
	// Build from a known CIDR
	cr = mustLoadChnrouteFromString(t, "10.0.0.0/8\n172.16.0.0/12\n")
	cidrs := cr.CIDRs()
	if len(cidrs) == 0 {
		t.Fatal("expected non-empty CIDRs")
	}
	// Every IP that Contains() says true must be covered by one of the CIDRs
	// and vice versa.
	nets := parseCIDRNets(t, cidrs)

	// Test specific IPs
	testIPs := []struct {
		ip   string
		want bool
	}{
		{"10.0.0.1", true},
		{"10.255.255.255", true},
		{"172.16.0.1", true},
		{"172.31.255.255", true},
		{"172.32.0.1", false},
		{"192.168.1.1", false},
		{"11.0.0.1", false},
	}
	for _, tc := range testIPs {
		ip := net.ParseIP(tc.ip)
		containsOrig := cr.Contains(ip)
		containsCIDR := containedInNets(ip, nets)
		if containsOrig != tc.want {
			t.Errorf("Contains(%s) = %v, want %v", tc.ip, containsOrig, tc.want)
		}
		if containsCIDR != tc.want {
			t.Errorf("CIDRs coverage for %s = %v, want %v", tc.ip, containsCIDR, tc.want)
		}
	}
}

func TestChnrouteCIDRs_EquivalenceRandomIPs(t *testing.T) {
	cr := mustLoadChnrouteFromString(t, "1.0.1.0/24\n1.0.2.0/23\n14.0.0.0/21\n")
	cidrs := cr.CIDRs()
	nets := parseCIDRNets(t, cidrs)

	rng := rand.New(rand.NewSource(42))
	for i := 0; i < 10000; i++ {
		ip := make(net.IP, 4)
		ip[0] = byte(rng.Intn(256))
		ip[1] = byte(rng.Intn(256))
		ip[2] = byte(rng.Intn(256))
		ip[3] = byte(rng.Intn(256))
		got := containedInNets(ip, nets)
		want := cr.Contains(ip)
		if got != want {
			t.Fatalf("IP %s: CIDRs=%v Contains=%v", ip, got, want)
		}
	}
}

func mustLoadChnrouteFromString(t *testing.T, data string) *Chnroute {
	t.Helper()
	tmp := t.TempDir() + "/chn.txt"
	writeFileForTest(t, tmp, data)
	cr, err := LoadChnrouteFiles(tmp)
	if err != nil {
		t.Fatal(err)
	}
	return cr
}

func writeFileForTest(t *testing.T, path, data string) {
	t.Helper()
	writeFile(t, path, data)
}

func parseCIDRNets(t *testing.T, cidrs []string) []*net.IPNet {
	t.Helper()
	nets := make([]*net.IPNet, len(cidrs))
	for i, c := range cidrs {
		_, n, err := net.ParseCIDR(c)
		if err != nil {
			t.Fatalf("invalid CIDR from CIDRs(): %q: %v", c, err)
		}
		nets[i] = n
	}
	return nets
}

func containedInNets(ip net.IP, nets []*net.IPNet) bool {
	for _, n := range nets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}
