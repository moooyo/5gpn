package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// ── spec validation ──────────────────────────────────────────────────────────

func TestValidateUpstreams(t *testing.T) {
	ok := [][2][]string{
		{{"223.5.5.5"}, {"22.22.22.22"}},
		{{"223.5.5.5:5353", "119.29.29.29"}, {"dns.google@8.8.8.8", "1.1.1.1"}},
		{{"223.5.5.5"}, {"one.one.one.one@1.1.1.1:853"}},
		{{"223.5.5.5:65535"}, {"1.1.1.1:1"}},
	}
	for _, tc := range ok {
		if err := ValidateUpstreams(tc[0], tc[1]); err != nil {
			t.Errorf("ValidateUpstreams(%v, %v) = %v, want nil", tc[0], tc[1], err)
		}
	}

	bad := [][2][]string{
		{{}, {"22.22.22.22"}},                  // empty china
		{{"223.5.5.5"}, {}},                    // empty trust
		{{"not-an-ip"}, {"22.22.22.22"}},       // china must be IP
		{{"223.5.5.5"}, {"dns.google"}},        // bare hostname trust rejected (self-reference footgun)
		{{"223.5.5.5"}, {"x@not-an-ip"}},       // DoT dial part must be IP
		{{"223.5.5.5:abc"}, {"1.1.1.1"}},       // bad port
		{{"223.5.5.5:0"}, {"1.1.1.1"}},         // port zero is invalid
		{{"223.5.5.5:65536"}, {"1.1.1.1"}},     // port exceeds uint16
		{{"223.5.5.5:99999"}, {"1.1.1.1"}},     // five digits is not sufficient validation
		{{"223.5.5.5"}, {"bad name@[8.8.8.8"}}, // garbage server name / dial
	}
	for _, tc := range bad {
		err := ValidateUpstreams(tc[0], tc[1])
		if err == nil {
			t.Errorf("ValidateUpstreams(%v, %v) = nil, want error", tc[0], tc[1])
			continue
		}
		if !errors.Is(err, ErrInvalidUpstream) {
			t.Errorf("ValidateUpstreams(%v, %v) error %v does not wrap ErrInvalidUpstream", tc[0], tc[1], err)
		}
	}
}

// ── upstreams.json load/save ─────────────────────────────────────────────────

func TestUpstreamsFileRoundtrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "upstreams.json")

	// Missing file → (nil, nil): dns.env applies.
	if uc, err := LoadUpstreams(path); uc != nil || err != nil {
		t.Fatalf("LoadUpstreams(missing) = %v, %v; want nil, nil", uc, err)
	}
	// Empty path → override disabled, save is a no-op.
	if uc, err := LoadUpstreams(""); uc != nil || err != nil {
		t.Fatalf("LoadUpstreams(\"\") = %v, %v; want nil, nil", uc, err)
	}
	if err := SaveUpstreams("", UpstreamsConfig{}); err != nil {
		t.Fatalf("SaveUpstreams(\"\") = %v, want nil (no-op)", err)
	}

	want := UpstreamsConfig{China: []string{"223.5.5.5"}, Trust: []string{"22.22.22.22", "dns.google@8.8.8.8"}}
	if err := SaveUpstreams(path, want); err != nil {
		t.Fatalf("SaveUpstreams: %v", err)
	}
	got, err := LoadUpstreams(path)
	if err != nil || got == nil {
		t.Fatalf("LoadUpstreams: %v, %v", got, err)
	}
	if got.Version != upstreamsSchemaVersion {
		t.Errorf("Version = %d, want %d", got.Version, upstreamsSchemaVersion)
	}
	if strings.Join(got.China, ",") != "223.5.5.5" || strings.Join(got.Trust, ",") != "22.22.22.22,dns.google@8.8.8.8" {
		t.Errorf("roundtrip mismatch: %+v", got)
	}

	// Malformed JSON → error (caller logs and falls back to dns.env).
	if err := os.WriteFile(path, []byte("{nope"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadUpstreams(path); err == nil {
		t.Error("LoadUpstreams(malformed) = nil error, want error")
	}

	// A file that parses but fails validation is also rejected.
	if err := os.WriteFile(path, []byte(`{"version":1,"china":["nope"],"trust":["22.22.22.22"]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadUpstreams(path); err == nil {
		t.Error("LoadUpstreams(invalid specs) = nil error, want error")
	}
}

// ── mixed trust group construction ───────────────────────────────────────────

func TestNewTrustGroupMixedTransports(t *testing.T) {
	g, ok := NewTrustGroup([]TrustEntry{
		{ServerName: "22.22.22.22", DialAddr: "22.22.22.22", Plain: true},
		{ServerName: "dns.google", DialAddr: "8.8.8.8"},
	}).(*group)
	if !ok {
		t.Fatal("NewTrustGroup did not return a *group")
	}
	if len(g.members) != 2 {
		t.Fatalf("members = %d, want 2", len(g.members))
	}
	if g.members[0].net != "udp" || g.members[0].addr != "22.22.22.22:53" || g.members[0].tlsCfg != nil {
		t.Errorf("plain member = %+v, want udp 22.22.22.22:53 no TLS", g.members[0])
	}
	if g.members[1].net != "tcp-tls" || g.members[1].addr != "8.8.8.8:853" ||
		g.members[1].tlsCfg == nil || g.members[1].tlsCfg.ServerName != "dns.google" {
		t.Errorf("DoT member = %+v, want tcp-tls 8.8.8.8:853 SNI dns.google", g.members[1])
	}
}

// ── handler hot swap ─────────────────────────────────────────────────────────

// TestSwapUpstreams: exchangers() falls back to the public fields until a
// snapshot is published, swapping changes what queries use, and the swap
// flushes the response cache (a cached answer resolved against the OLD
// upstreams must not outlive them).
func TestSwapUpstreams(t *testing.T) {
	oldTrust := &fakeExchanger{reply: buildMsg("x.test", "9.9.9.9")}
	newTrust := &fakeExchanger{reply: buildMsg("x.test", "8.8.8.8")}
	h := newTestHandler(t, &fakeExchanger{reply: buildMsg("x.test", "")}, oldTrust)

	if _, tr := h.exchangers(); tr != Exchanger(oldTrust) {
		t.Fatal("exchangers() should fall back to the public Trust field before any swap")
	}

	// Seed the cache via a resolve, then swap and assert the cache was flushed.
	q := dns.Question{Name: "x.test.", Qtype: dns.TypeA}
	req := new(dns.Msg)
	req.SetQuestion("x.test.", dns.TypeA)
	_ = h.resolve(context.Background(), q, req)
	if h.Cache.Len() == 0 {
		t.Fatal("expected a cached entry after resolve")
	}

	h.swapUpstreams(&upstreamSnapshot{
		China:    &fakeExchanger{reply: buildMsg("x.test", "")},
		Trust:    newTrust,
		ChinaRaw: []string{"203.0.113.1"}, TrustRaw: []string{"22.22.22.22"},
	})
	// Flush expires entries in place (they survive only for serve-stale), so
	// assert via a fresh Get: the pre-swap answer must no longer be served.
	if _, ok := h.cacheGet("x.test.", dns.TypeA); ok {
		t.Error("swapUpstreams must flush the response cache (pre-swap answer still served)")
	}
	if _, tr := h.exchangers(); tr != Exchanger(newTrust) {
		t.Error("exchangers() should return the swapped trust group")
	}
}

// ── Controller.Get/SetUpstreams ──────────────────────────────────────────────

func TestControllerSetUpstreams(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	h.swapUpstreams(&upstreamSnapshot{
		China: h.China, Trust: h.Trust,
		ChinaRaw: []string{"223.5.5.5"}, TrustRaw: []string{"22.22.22.22"},
	})
	c := NewController(func() error { return nil }, nil, nil, h)

	// Unwired apply hook → error.
	if err := c.SetUpstreams([]string{"223.5.5.5"}, []string{"1.1.1.1"}); err == nil {
		t.Error("SetUpstreams without an apply hook should error")
	}

	var gotChina, gotTrust []string
	c.SetUpstreamsApply(func(china, trust []string) error {
		gotChina, gotTrust = china, trust
		return nil
	})

	// Validation failure never reaches the hook and wraps ErrInvalidUpstream.
	if err := c.SetUpstreams([]string{"nope"}, []string{"1.1.1.1"}); !errors.Is(err, ErrInvalidUpstream) {
		t.Errorf("invalid china: err = %v, want ErrInvalidUpstream", err)
	}
	if gotChina != nil {
		t.Error("apply hook must not run on validation failure")
	}

	// Valid input is normalized (whitespace/empties dropped) before the hook.
	if err := c.SetUpstreams([]string{" 223.5.5.5 ", ""}, []string{"dns.google@8.8.8.8", " 22.22.22.22"}); err != nil {
		t.Fatalf("SetUpstreams: %v", err)
	}
	if strings.Join(gotChina, ",") != "223.5.5.5" || strings.Join(gotTrust, ",") != "dns.google@8.8.8.8,22.22.22.22" {
		t.Errorf("apply got china=%v trust=%v", gotChina, gotTrust)
	}

	// GetUpstreams reflects the live snapshot.
	v := c.GetUpstreams()
	if strings.Join(v.China, ",") != "223.5.5.5" || strings.Join(v.Trust, ",") != "22.22.22.22" {
		t.Errorf("GetUpstreams = %+v", v)
	}
}

// ── HTTP layer ───────────────────────────────────────────────────────────────

func TestAPIUpstreams(t *testing.T) {
	cs, token := newAPITestServer(t)

	// GET on a controller without a handler snapshot → empty lists, 200.
	rec := doAPI(cs, http.MethodGet, "/api/upstreams", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status = %d; body=%s", rec.Code, rec.Body.String())
	}
	got := decodeJSON[UpstreamsView](t, rec)
	if got.China == nil || got.Trust == nil {
		t.Errorf("GET /api/upstreams should return non-null arrays, got %+v", got)
	}

	// PUT with invalid specs → 400 (the test server has no apply hook wired,
	// but validation errors must map to 400 regardless — check both orders).
	rec = doAPI(cs, http.MethodPut, "/api/upstreams", []byte(`{"china":["nope"],"trust":["22.22.22.22"]}`), token, true)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("PUT invalid: status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}

	// PUT valid but no apply hook (this test server) → 500 with a message.
	rec = doAPI(cs, http.MethodPut, "/api/upstreams", []byte(`{"china":["223.5.5.5"],"trust":["22.22.22.22"]}`), token, true)
	if rec.Code != http.StatusInternalServerError {
		t.Errorf("PUT unwired: status = %d, want 500; body=%s", rec.Code, rec.Body.String())
	}
}

func TestAPIQueryLog(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAPI(cs, http.MethodGet, "/api/querylog?q=foo&limit=10", nil, token, true)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d; body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		RetentionSeconds int             `json:"retention_seconds"`
		Entries          []QueryLogEntry `json:"entries"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("response not JSON: %v (%s)", err, rec.Body.String())
	}
	if body.RetentionSeconds != int(queryLogRetention.Seconds()) {
		t.Errorf("retention_seconds = %d, want %d", body.RetentionSeconds, int(queryLogRetention.Seconds()))
	}
	if body.Entries == nil {
		t.Error("entries should be a non-null array")
	}
}

func TestAPIResolveTest_MissingDomain(t *testing.T) {
	cs, token := newAPITestServer(t)
	rec := doAPI(cs, http.MethodGet, "/api/resolve-test", nil, token, true)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

// ── query log ring ───────────────────────────────────────────────────────────

func TestQueryLogRetentionAndSearch(t *testing.T) {
	l := newQueryLog(4, 5*time.Minute)
	now := time.Now()

	l.add(QueryLogEntry{Time: now.Add(-10 * time.Minute), Name: "old.example.com"})
	l.add(QueryLogEntry{Time: now.Add(-1 * time.Minute), Name: "a.example.com", Client: "10.0.0.9"})
	l.add(QueryLogEntry{Time: now.Add(-30 * time.Second), Name: "b.other.org"})

	// Retention: the 10-minute-old entry is not served.
	all := l.search("", 100, now)
	if len(all) != 2 {
		t.Fatalf("search all = %d entries, want 2 (retention drop)", len(all))
	}
	// Newest first.
	if all[0].Name != "b.other.org" || all[1].Name != "a.example.com" {
		t.Errorf("order = %s, %s; want newest first", all[0].Name, all[1].Name)
	}

	// Substring filter on name (case-insensitive) and on client.
	if got := l.search("EXAMPLE", 100, now); len(got) != 1 || got[0].Name != "a.example.com" {
		t.Errorf("search(EXAMPLE) = %+v, want [a.example.com]", got)
	}
	if got := l.search("10.0.0.9", 100, now); len(got) != 1 || got[0].Name != "a.example.com" {
		t.Errorf("search(client) = %+v, want [a.example.com]", got)
	}

	// Limit.
	if got := l.search("", 1, now); len(got) != 1 || got[0].Name != "b.other.org" {
		t.Errorf("search(limit=1) = %+v, want just the newest", got)
	}

	// Ring wrap: capacity 4, add 6 fresh entries → only the last 4 remain.
	for i := 0; i < 6; i++ {
		l.add(QueryLogEntry{Time: now, Name: strings.Repeat("x", i+1) + ".wrap.test"})
	}
	if got := l.search("wrap.test", 100, now); len(got) != 4 {
		t.Errorf("after wrap: %d entries, want 4 (capacity)", len(got))
	}
}

// TestServeContextLogsQueries: the serve path records one entry per query with
// the verdict trace (here: force-proxy → synthetic gateway answer, no upstream).
func TestServeContextLogsQueries(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{reply: buildMsg("proxy.test", "")}, &fakeExchanger{reply: buildMsg("proxy.test", "")})
	h.qlog = newQueryLog(16, 5*time.Minute)

	req := new(dns.Msg)
	req.SetQuestion("proxy.test.", dns.TypeA)
	fw := &fakeWriter{remote: &net.UDPAddr{IP: net.ParseIP("192.0.2.7"), Port: 5353}}
	h.serveContext(context.Background(), fw, req)

	got := h.qlog.search("", 10, time.Now())
	if len(got) != 1 {
		t.Fatalf("query log entries = %d, want 1", len(got))
	}
	e := got[0]
	if e.Name != "proxy.test" || e.Verdict != "proxy" || e.Reason != "force-proxy" {
		t.Errorf("entry = %+v, want proxy.test proxy/force-proxy", e)
	}
	if e.Client != "192.0.2.7" {
		t.Errorf("client = %q, want 192.0.2.7", e.Client)
	}
	if len(e.IPs) != 1 || e.IPs[0] != "10.0.0.1" {
		t.Errorf("ips = %v, want the gateway IP", e.IPs)
	}
}

// ── sequential pool-order Exchange ───────────────────────────────────────────

// TestGroupExchangeSequentialPoolOrder: the group must adopt the FIRST
// configured member's answer, not the fastest one. Member[0] is deliberately
// slower than member[1]; a fan-out race would return member[1]'s answer.
func TestGroupExchangeSequentialPoolOrder(t *testing.T) {
	slow := startLocalUDPDNS(t, answerA("9.9.9.1", 80*time.Millisecond))
	fast := startLocalUDPDNS(t, answerA("9.9.9.2", 0))

	g := NewUDPGroup([]string{slow, fast}, false)
	q := new(dns.Msg)
	q.SetQuestion("seq-order.test.", dns.TypeA)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	reply, err := g.Exchange(ctx, q)
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	ips := answerIPs(reply, 4)
	if len(ips) != 1 || ips[0] != "9.9.9.1" {
		t.Errorf("answer = %v, want [9.9.9.1] (pool-order member 0, not the faster member 1)", ips)
	}
}

// TestGroupExchangeFallsBackPastDeadMember: a silent (blackholed) first member
// must not eat the whole query deadline — its per-attempt budget slice expires
// and the next member's answer is returned within the caller's deadline.
func TestGroupExchangeFallsBackPastDeadMember(t *testing.T) {
	dead := startLocalUDPDNS(t, func(dns.ResponseWriter, *dns.Msg) {}) // never replies
	live := startLocalUDPDNS(t, answerA("9.9.9.2", 0))

	g := NewUDPGroup([]string{dead, live}, false)
	q := new(dns.Msg)
	q.SetQuestion("seq-fallback.test.", dns.TypeA)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	reply, err := g.Exchange(ctx, q)
	if err != nil {
		t.Fatalf("Exchange: %v (a dead first member must fall through to the second)", err)
	}
	ips := answerIPs(reply, 4)
	if len(ips) != 1 || ips[0] != "9.9.9.2" {
		t.Errorf("answer = %v, want [9.9.9.2] (fallback member)", ips)
	}
}

// ── resolve test ─────────────────────────────────────────────────────────────

// TestResolveTest_PoolOrderAdoption: the adopted probe is the first in pool
// order with a usable answer — never the fastest.
func TestResolveTest_PoolOrderAdoption(t *testing.T) {
	slowCN := startLocalUDPDNS(t, answerA("1.2.3.5", 60*time.Millisecond)) // CN, first, slower
	fastCN := startLocalUDPDNS(t, answerA("1.2.3.4", 0))                   // CN, second, faster
	trustAddr := startLocalUDPDNS(t, answerA("9.9.9.9", 0))

	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	h.swapUpstreams(&upstreamSnapshot{
		China: h.China, Trust: h.Trust,
		ChinaRaw:     []string{slowCN, fastCN},
		TrustRaw:     []string{trustAddr},
		TrustEntries: []TrustEntry{{ServerName: trustAddr, DialAddr: trustAddr, Plain: true}},
	})
	c := NewController(func() error { return nil }, nil, nil, h)

	got := c.ResolveTest(context.Background(), "order.example")
	if got.Chosen != "china" {
		t.Fatalf("chosen = %q, want china", got.Chosen)
	}
	if len(got.ChosenIPs) != 1 || got.ChosenIPs[0] != "1.2.3.5" {
		t.Errorf("chosen IPs = %v, want [1.2.3.5] (first-in-pool-order server, not the faster one)", got.ChosenIPs)
	}
	if len(got.Probes) != 3 {
		t.Fatalf("probes = %d, want 3", len(got.Probes))
	}
	if !got.Probes[0].Selected || got.Probes[1].Selected {
		t.Errorf("selected flags = [%v %v], want the FIRST china probe selected",
			got.Probes[0].Selected, got.Probes[1].Selected)
	}
}

func TestSelectFirstAdoptsNXDOMAINAndNODATA(t *testing.T) {
	for _, rcode := range []string{"NXDOMAIN", "NOERROR"} {
		probes := []ResolveProbe{
			{Group: "china", Server: "first", Rcode: rcode},
			{Group: "china", Server: "second", Rcode: "NOERROR", IPs: []string{"1.2.3.4"}},
		}
		got := selectFirst(probes, "china")
		if got == nil || got.Server != "first" {
			t.Fatalf("rcode %s selected %+v, want first empty DNS response", rcode, got)
		}
	}
}

// TestResolveTest_TerminalVerdicts: block/force-proxy never consult an
// upstream; force-proxy reports the gateway as what the client receives.
func TestResolveTest_TerminalVerdicts(t *testing.T) {
	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	c := NewController(func() error { return nil }, nil, nil, h)

	got := c.ResolveTest(context.Background(), "block.test")
	if got.Verdict != "block" || got.Reason != "block" || len(got.Probes) != 0 || len(got.ClientIPs) != 0 {
		t.Errorf("block: %+v", got)
	}

	got = c.ResolveTest(context.Background(), "proxy.test")
	if got.Verdict != "proxy" || got.Reason != "force-proxy" || len(got.Probes) != 0 {
		t.Errorf("force-proxy: %+v", got)
	}
	if len(got.ClientIPs) != 1 || got.ClientIPs[0] != "10.0.0.1" {
		t.Errorf("force-proxy client IPs = %v, want [10.0.0.1]", got.ClientIPs)
	}
}

// TestResolveTest_ProbesAndArbitration: with real local UDP servers, the test
// probes each configured server individually, adopts china when its answer is
// a CN address, and reports the gateway rewrite for a foreign answer.
func TestResolveTest_ProbesAndArbitration(t *testing.T) {
	cnAddr := startLocalUDPDNS(t, answerA("1.2.3.4", 0))      // CN (1.0.0.0/8)
	foreignAddr := startLocalUDPDNS(t, answerA("9.9.9.9", 0)) // foreign

	h := newTestHandler(t, &fakeExchanger{}, &fakeExchanger{})
	h.swapUpstreams(&upstreamSnapshot{
		China: h.China, Trust: h.Trust,
		ChinaRaw:     []string{cnAddr},
		TrustRaw:     []string{foreignAddr},
		TrustEntries: []TrustEntry{{ServerName: foreignAddr, DialAddr: foreignAddr, Plain: true}},
	})
	c := NewController(func() error { return nil }, nil, nil, h)

	got := c.ResolveTest(context.Background(), "cn-domain.example")
	if len(got.Probes) != 2 {
		t.Fatalf("probes = %d, want 2 (%+v)", len(got.Probes), got.Probes)
	}
	if got.Chosen != "china" {
		t.Errorf("chosen = %q, want china (CN answer wins)", got.Chosen)
	}
	if got.Verdict != "direct" || got.Reason != "chnroute-cn" {
		t.Errorf("verdict/reason = %s/%s, want direct/chnroute-cn", got.Verdict, got.Reason)
	}
	if len(got.ClientIPs) != 1 || got.ClientIPs[0] != "1.2.3.4" {
		t.Errorf("client IPs = %v, want the real CN IP kept", got.ClientIPs)
	}
	var sel *ResolveProbe
	for i := range got.Probes {
		if got.Probes[i].Selected {
			if sel != nil {
				t.Fatal("more than one selected probe")
			}
			sel = &got.Probes[i]
		}
	}
	if sel == nil || sel.Group != "china" {
		t.Errorf("selected probe = %+v, want the china one", sel)
	}

	// Now make china answer a foreign IP → trust is adopted and the client
	// sees the gateway.
	h.swapUpstreams(&upstreamSnapshot{
		China: h.China, Trust: h.Trust,
		ChinaRaw:     []string{foreignAddr},
		TrustRaw:     []string{foreignAddr},
		TrustEntries: []TrustEntry{{ServerName: foreignAddr, DialAddr: foreignAddr, Plain: true}},
	})
	got = c.ResolveTest(context.Background(), "foreign.example")
	if got.Chosen != "trust" {
		t.Errorf("chosen = %q, want trust", got.Chosen)
	}
	if got.Verdict != "proxy" || got.Reason != "chnroute-foreign" {
		t.Errorf("verdict/reason = %s/%s, want proxy/chnroute-foreign", got.Verdict, got.Reason)
	}
	if len(got.ClientIPs) != 1 || got.ClientIPs[0] != "10.0.0.1" {
		t.Errorf("client IPs = %v, want [10.0.0.1] (gateway rewrite)", got.ClientIPs)
	}
	if len(got.ChosenIPs) != 1 || got.ChosenIPs[0] != "9.9.9.9" {
		t.Errorf("chosen IPs = %v, want the raw upstream answer", got.ChosenIPs)
	}

	// The shared decision layer must make the same foreign answer direct when
	// fallback=direct, without changing per-server probing or pool selection.
	publishTestPolicy(t, h, FallbackDirect)
	got = c.ResolveTest(context.Background(), "foreign.example")
	if got.Verdict != "direct" || got.Reason != "fallback-direct" ||
		len(got.ClientIPs) != 1 || got.ClientIPs[0] != "9.9.9.9" {
		t.Errorf("direct fallback resolve-test = %+v", got)
	}
}
