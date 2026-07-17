package main

import (
	"encoding/base64"
	"errors"
	"reflect"
	"strings"
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

func TestParseCIDRsEmpty(t *testing.T) {
	got, err := ParseCIDRs([]byte("# only comments\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("got %v, want empty", got)
	}
}

func TestParseDomainsAcceptsLineAboveScannerDefault(t *testing.T) {
	// Regression: bufio.Scanner used to stop at 64 KiB and ParseDomains ignored
	// Scanner.Err, allowing a partially parsed list to replace the old cache. A
	// line this long is not a valid domain, but the parser must still reach and
	// retain the valid line after it.
	long := strings.Repeat("a", 70*1024) + ".example\n"
	got, err := ParseDomains("plain", []byte("first.example\n"+long+"last.example\n"))
	if err != nil {
		t.Fatalf("long but in-cap line rejected: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"first.example", "last.example"}) {
		t.Fatalf("got %v, want valid entries on both sides of the long line", got)
	}
}

func TestParseDomainsRejectsHTMLAndMostlyInvalidContent(t *testing.T) {
	for _, raw := range []string{
		"<html><body>upstream error</body></html>\n",
		"valid.example\nnot a domain\n<html>\n{}\n",
	} {
		if _, err := ParseDomains("plain", []byte(raw)); err == nil {
			t.Fatalf("mostly invalid payload was accepted: %q", raw)
		}
	}
}

func TestParseCIDRsRejectsMostlyInvalidContent(t *testing.T) {
	if _, err := ParseCIDRs([]byte("1.0.0.0/8\nbad\nalso-bad\n<html>\n")); err == nil {
		t.Fatal("mostly invalid CIDR payload was accepted")
	}
}

func TestParseDomainsInvalidGFWListReturnsError(t *testing.T) {
	if _, err := ParseDomains("gfwlist", []byte("%%%not-base64%%%")); err == nil {
		t.Fatal("invalid base64 must be a parse error, not an empty successful list")
	}
}
