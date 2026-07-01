package main

import (
	"encoding/base64"
	"errors"
	"reflect"
	"testing"
)

func TestParseDomainsPlain(t *testing.T) {
	raw := []byte("a.com\n# c\nb.com\n")
	got, err := ParseDomains("plain", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"a.com", "b.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseDomainsGFWList(t *testing.T) {
	body := "||x.com^\n|http://y.com\n@@||white.com^\n!comment"
	raw := []byte(base64.StdEncoding.EncodeToString([]byte(body)))
	got, err := ParseDomains("gfwlist", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"x.com", "y.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseDomainsDnsmasq(t *testing.T) {
	raw := []byte("server=/z.cn/114.114.114.114\naddress=/w.cn/1.1.1.1\n")
	got, err := ParseDomains("dnsmasq", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"w.cn", "z.cn"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseDomainsAdblock(t *testing.T) {
	raw := []byte("||ad.com^\n||b.com^$third-party\n##.banner\n@@||ok.com^\n/regex/\n")
	got, err := ParseDomains("adblock", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"ad.com", "b.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseDomainsHosts(t *testing.T) {
	raw := []byte("0.0.0.0 h.com\n127.0.0.1 g.com localhost\n")
	got, err := ParseDomains("hosts", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"g.com", "h.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseDomainsUnknownFormat(t *testing.T) {
	_, err := ParseDomains("bogus", []byte("a.com\n"))
	if !errors.Is(err, ErrUnknownFormat) {
		t.Fatalf("got err %v, want ErrUnknownFormat", err)
	}
}

func TestParseCIDRs(t *testing.T) {
	raw := []byte("1.0.0.0/8\n# x\nbad\n2.2.2.0/24\n")
	got, err := ParseCIDRs(raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"1.0.0.0/8", "2.2.2.0/24"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// Additional edge-case coverage beyond the brief's minimal samples.

func TestParseDomainsPlainDedupAndCase(t *testing.T) {
	raw := []byte("A.com\nA.COM.\na.com\n\nb.com\n")
	got, err := ParseDomains("plain", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"a.com", "b.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseDomainsGFWListHTTPS(t *testing.T) {
	body := "|https://secure.com/path^\n||plain.com^\n"
	raw := []byte(base64.StdEncoding.EncodeToString([]byte(body)))
	got, err := ParseDomains("gfwlist", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"plain.com", "secure.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseDomainsAdblockWildcardAndPathDropped(t *testing.T) {
	raw := []byte("||wild*.com^\n||path.com/x^\n||keep.com^\n")
	got, err := ParseDomains("adblock", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"keep.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseCIDRsEmpty(t *testing.T) {
	got, err := ParseCIDRs([]byte("# only comments\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("got %v, want empty", got)
	}
}
