package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestChnrouteContains(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "cn.txt")
	os.WriteFile(p, []byte("1.0.0.0/8\n# comment\n203.0.113.0/24\nbogus\n"), 0o644)
	c, err := LoadChnroute(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		ip   string
		want bool
	}{
		{"1.2.3.4", true}, {"203.0.113.5", true},
		{"8.8.8.8", false}, {"203.0.114.1", false},
	} {
		if got := c.Contains(net.ParseIP(tc.ip)); got != tc.want {
			t.Errorf("Contains(%s)=%v want %v", tc.ip, got, tc.want)
		}
	}
}

func TestChnrouteRefusesEmpty(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "e.txt")
	os.WriteFile(p, []byte("# none\n"), 0o644)
	if _, err := LoadChnroute(p); err == nil {
		t.Fatal("want error on empty chnroute")
	}
}
