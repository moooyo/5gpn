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

func TestParseDomainsClash(t *testing.T) {
	raw := []byte(`# NAME: Example
payload:
  - '+.suffix.com'
  - '.surge.com'
  - 'bare.com'
  - DOMAIN-SUFFIX,token.com
  - DOMAIN,exact.com
  - DOMAIN-KEYWORD,ads
  - IP-CIDR,1.2.3.0/24,no-resolve
  - IP-CIDR6,2001:db8::/32
  - GEOIP,CN
  - PROCESS-NAME,curl
`)
	got, err := ParseDomains("clash", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"bare.com", "exact.com", "suffix.com", "surge.com", "token.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// A Clash provider entry keeps its suffix marker in the payload. validPolicyDomain
// accepts '+' as a legal hostname byte, so an unstripped "+.foo.com" would pass
// validation and be cached as a literal entry that DomainSet.Match — which walks
// label boundaries — can never match. The fetch would report success with a
// healthy entry count while blocking or steering nothing at all. Pin the strip.
func TestParseDomainsClashStripsSuffixMarker(t *testing.T) {
	got, err := ParseDomains("clash", []byte("payload:\n  - '+.foo.com'\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"foo.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for _, d := range got {
		if strings.ContainsAny(d, "+*,") {
			t.Fatalf("marker survived normalization: %q", d)
		}
	}
}

// A wildcard matches exactly one label; the suffix cache would over-match it,
// so it is dropped rather than silently widened.
func TestParseDomainsClashDropsWildcard(t *testing.T) {
	got, err := ParseDomains("clash", []byte("payload:\n  - '*.wild.com'\n  - 'keep.com'\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"keep.com"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestParseDomainsClashRejectsMalformedYAML(t *testing.T) {
	if _, err := ParseDomains("clash", []byte("payload:\n  - [unclosed\n")); err == nil {
		t.Fatal("malformed YAML must error rather than yield an empty list")
	}
}

// Non-domain rule kinds are dropped before normalization, so a provider that is
// mostly IP rules does not trip the 40% invalid-entry rejection.
func TestParseDomainsClashIPOnlyProviderIsEmptyNotRejected(t *testing.T) {
	raw := []byte("payload:\n  - IP-CIDR,1.2.3.0/24\n  - IP-CIDR,4.5.6.0/24\n  - 'only.com'\n")
	got, err := ParseDomains("clash", raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"only.com"}) {
		t.Fatalf("got %v", got)
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
