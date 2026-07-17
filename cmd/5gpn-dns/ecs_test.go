package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// ---------------------------------------------------------------------------
// parseECS
// ---------------------------------------------------------------------------

func TestParseECS(t *testing.T) {
	cases := []struct {
		in   string
		want string // "" = disabled (nil subnet)
		err  bool
	}{
		{"", "", false},
		{"122.96.30.5", "122.96.30.0/24", false},    // bare IPv4 → its /24
		{"122.96.30.0", "122.96.30.0/24", false},    // install default
		{"122.96.30.7/24", "122.96.30.0/24", false}, // CIDR masked
		{"10.0.0.0/8", "10.0.0.0/8", false},         // CIDR prefix honoured
		{"2001:db8::1", "2001:db8::/56", false},     // bare IPv6 → /56
		{"not-an-ip", "", true},
		{"1.2.3.4/99", "", true},
		{"1.2.3", "", true},
	}
	for _, c := range cases {
		subnet, err := parseECS(c.in)
		if c.err {
			if err == nil {
				t.Errorf("parseECS(%q): want error, got %v", c.in, subnet)
			} else if !errors.Is(err, ErrInvalidECS) {
				t.Errorf("parseECS(%q): error %v does not wrap ErrInvalidECS", c.in, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseECS(%q): unexpected error %v", c.in, err)
			continue
		}
		if got := ecsSubnetString(subnet); got != c.want {
			t.Errorf("parseECS(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// setECSOnMsg
// ---------------------------------------------------------------------------

// findECS returns the first EDNS Client Subnet option on m's OPT, or nil.
func findECS(m *dns.Msg) *dns.EDNS0_SUBNET {
	opt := m.IsEdns0()
	if opt == nil {
		return nil
	}
	for _, o := range opt.Option {
		if e, ok := o.(*dns.EDNS0_SUBNET); ok {
			return e
		}
	}
	return nil
}

func TestSetECSOnMsg_CreatesOPT(t *testing.T) {
	subnet, _ := parseECS("122.96.30.0/24")
	m := new(dns.Msg)
	m.SetQuestion("example.cn.", dns.TypeA)

	setECSOnMsg(m, subnet)

	e := findECS(m)
	if e == nil {
		t.Fatal("no ECS option attached")
	}
	if e.Family != 1 || e.SourceNetmask != 24 || !e.Address.Equal(net.ParseIP("122.96.30.0")) {
		t.Fatalf("ECS = family=%d mask=%d addr=%s, want 1/24/122.96.30.0", e.Family, e.SourceNetmask, e.Address)
	}
}

func TestSetECSOnMsg_ReplacesClientECS(t *testing.T) {
	subnet, _ := parseECS("122.96.30.0/24")
	m := new(dns.Msg)
	m.SetQuestion("example.cn.", dns.TypeA)
	m.SetEdns0(1232, false)
	opt := m.IsEdns0()
	opt.Option = append(opt.Option, &dns.EDNS0_SUBNET{
		Code: dns.EDNS0SUBNET, Family: 1, SourceNetmask: 32,
		Address: net.ParseIP("9.9.9.9").To4(),
	})

	setECSOnMsg(m, subnet)

	var count int
	for _, o := range m.IsEdns0().Option {
		if _, ok := o.(*dns.EDNS0_SUBNET); ok {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("ECS option count = %d, want exactly 1 (client-sent subnet replaced)", count)
	}
	if e := findECS(m); !e.Address.Equal(net.ParseIP("122.96.30.0")) {
		t.Fatalf("ECS addr = %s, want the configured 122.96.30.0", e.Address)
	}
}

// ---------------------------------------------------------------------------
// group.Exchange ECS injection (real UDP socket end-to-end)
// ---------------------------------------------------------------------------

// captureECSHandler answers any A query and records the ECS option (if any)
// the query arrived with.
func captureECSHandler(got chan<- *dns.EDNS0_SUBNET) dns.HandlerFunc {
	return func(w dns.ResponseWriter, r *dns.Msg) {
		var e *dns.EDNS0_SUBNET
		if opt := r.IsEdns0(); opt != nil {
			for _, o := range opt.Option {
				if s, ok := o.(*dns.EDNS0_SUBNET); ok {
					e = s
				}
			}
		}
		select {
		case got <- e:
		default:
		}
		m := new(dns.Msg)
		m.SetReply(r)
		// RFC 7871 echo: a real upstream echoes the ECS option back; the group
		// must strip it before handing the reply downstream.
		if e != nil {
			m.SetEdns0(1232, false)
			m.IsEdns0().Option = append(m.IsEdns0().Option, e)
		}
		m.Answer = []dns.RR{&dns.A{
			Hdr: dns.RR_Header{Name: r.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60},
			A:   net.ParseIP("1.2.3.4").To4(),
		}}
		_ = w.WriteMsg(m)
	}
}

func TestGroupExchange_AttachesECS(t *testing.T) {
	got := make(chan *dns.EDNS0_SUBNET, 1)
	addr := startLocalUDPDNS(t, captureECSHandler(got))

	g := NewUDPGroup([]string{addr}, false)
	subnet, _ := parseECS("122.96.30.0/24")
	SetGroupECS(g, subnet)

	q := new(dns.Msg)
	q.SetQuestion("example.cn.", dns.TypeA)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := g.Exchange(ctx, q)
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}

	select {
	case e := <-got:
		if e == nil {
			t.Fatal("upstream saw no ECS option")
		}
		if e.Family != 1 || e.SourceNetmask != 24 || !e.Address.Equal(net.ParseIP("122.96.30.0")) {
			t.Fatalf("upstream saw ECS family=%d mask=%d addr=%s, want 1/24/122.96.30.0", e.Family, e.SourceNetmask, e.Address)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("upstream never received the query")
	}

	// The caller's query must not have been mutated (it doubles as the reply
	// template on the serve path).
	if q.IsEdns0() != nil {
		t.Error("caller's query message was mutated (OPT added)")
	}
	// The upstream's ECS echo must be stripped from the reply — clients never
	// asked for ECS and must not see the operator's configured subnet.
	if findECS(resp) != nil {
		t.Error("reply still carries the ECS echo; want it stripped")
	}
}

// ECS + 0x20 combined: both wire transformations must coexist on the same
// (single) query copy.
func TestGroupExchange_ECSWith0x20(t *testing.T) {
	got := make(chan *dns.EDNS0_SUBNET, 1)
	addr := startLocalUDPDNS(t, captureECSHandler(got))

	g := NewUDPGroup([]string{addr}, true)
	subnet, _ := parseECS("122.96.30.0/24")
	SetGroupECS(g, subnet)

	q := new(dns.Msg)
	q.SetQuestion("example.cn.", dns.TypeA)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := g.Exchange(ctx, q)
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	select {
	case e := <-got:
		if e == nil {
			t.Fatal("upstream saw no ECS option with 0x20 enabled")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("upstream never received the query")
	}
	if resp.Question[0].Name != "example.cn." {
		t.Errorf("question casing not restored: %q", resp.Question[0].Name)
	}
}

func TestGroupExchange_NoECSWhenDisabled(t *testing.T) {
	got := make(chan *dns.EDNS0_SUBNET, 1)
	addr := startLocalUDPDNS(t, captureECSHandler(got))

	g := NewUDPGroup([]string{addr}, false) // no SetGroupECS call

	q := new(dns.Msg)
	q.SetQuestion("example.com.", dns.TypeA)
	clientSubnet, _ := parseECS("198.51.100.0/24")
	setECSOnMsg(q, clientSubnet)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := g.Exchange(ctx, q)
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	select {
	case e := <-got:
		if e != nil {
			t.Fatalf("upstream saw ECS %v with ECS disabled", e)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("upstream never received the query")
	}
	if findECS(resp) != nil {
		t.Fatal("client ECS was echoed back in the downstream response")
	}
}

// ---------------------------------------------------------------------------
// LoadConfig: DNS_CHINA_ECS
// ---------------------------------------------------------------------------

func TestLoadConfig_ChinaECS(t *testing.T) {
	cases := []struct {
		name string
		set  bool
		env  string
		want string
	}{
		{name: "unset uses operational default", want: "112.96.32.0/24"},
		{name: "explicit empty disables", set: true, env: "", want: ""},
		{name: "bare IPv4 normalizes to slash 24", set: true, env: "1.2.3.4", want: "1.2.3.0/24"},
		{name: "CIDR is honored", set: true, env: "10.1.0.0/16", want: "10.1.0.0/16"},
		{name: "off disables", set: true, env: "off", want: ""},
		{name: "none disables", set: true, env: "none", want: ""},
		{name: "invalid disables", set: true, env: "garbage", want: ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			clearAllDNSEnv(t)
			t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
			t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
			if c.set {
				t.Setenv("DNS_CHINA_ECS", c.env)
			}
			cfg, err := LoadConfig()
			if err != nil {
				t.Fatalf("LoadConfig: %v", err)
			}
			if got := ecsSubnetString(cfg.ChinaECS); got != c.want {
				t.Errorf("ChinaECS = %q, want %q", got, c.want)
			}
		})
	}
}

func TestLoadConfig_EcsFileDefault(t *testing.T) {
	clearAllDNSEnv(t)
	t.Setenv("DNS_CERT", "/etc/5gpn/cert/cert.pem")
	t.Setenv("DNS_KEY", "/etc/5gpn/cert/key.pem")
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.EcsFile != "/etc/5gpn/ecs.json" {
		t.Errorf("EcsFile = %q, want /etc/5gpn/ecs.json", cfg.EcsFile)
	}
}

// ---------------------------------------------------------------------------
// ecs.json persistence round-trip
// ---------------------------------------------------------------------------

func TestECSFile_RoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ecs.json")

	// Missing file → (nil, nil): env value applies.
	fc, err := LoadECSFile(path)
	if err != nil || fc != nil {
		t.Fatalf("LoadECSFile(missing) = %v, %v; want nil, nil", fc, err)
	}

	if err := SaveECSFile(path, "122.96.30.0/24"); err != nil {
		t.Fatalf("SaveECSFile: %v", err)
	}
	fc, err = LoadECSFile(path)
	if err != nil {
		t.Fatalf("LoadECSFile: %v", err)
	}
	if fc == nil || fc.Subnet != "122.96.30.0/24" {
		t.Fatalf("LoadECSFile = %+v, want subnet 122.96.30.0/24", fc)
	}

	// Explicit disable persists as an empty subnet (distinct from no file).
	if err := SaveECSFile(path, ""); err != nil {
		t.Fatalf("SaveECSFile(disable): %v", err)
	}
	fc, err = LoadECSFile(path)
	if err != nil || fc == nil || fc.Subnet != "" {
		t.Fatalf("LoadECSFile(after disable) = %+v, %v; want subnet \"\"", fc, err)
	}
}

// ---------------------------------------------------------------------------
// Controller.SetChinaECS: live apply + cache flush + persistence
// ---------------------------------------------------------------------------

func TestControllerSetChinaECS(t *testing.T) {
	china := NewUDPGroup([]string{"127.0.0.1:1"}, false)
	h := &Handler{China: china, Cache: NewCache(16)}
	ctrl := NewController(func() error { return nil }, nil, nil, h)
	ecsPath := filepath.Join(t.TempDir(), "ecs.json")
	ctrl.SetECSFile(ecsPath)

	if got := ctrl.ChinaECS(); got != "" {
		t.Fatalf("initial ChinaECS = %q, want \"\"", got)
	}

	norm, err := ctrl.SetChinaECS("122.96.30.9") // bare IP → /24
	if err != nil {
		t.Fatalf("SetChinaECS: %v", err)
	}
	if norm != "122.96.30.0/24" {
		t.Fatalf("normalised = %q, want 122.96.30.0/24", norm)
	}
	if got := ctrl.ChinaECS(); got != "122.96.30.0/24" {
		t.Fatalf("live ChinaECS = %q, want 122.96.30.0/24 (apply must hit the live group)", got)
	}
	if got := ecsSubnetString(GetGroupECS(china)); got != "122.96.30.0/24" {
		t.Fatalf("group ECS = %q, want 122.96.30.0/24", got)
	}
	fc, err := LoadECSFile(ecsPath)
	if err != nil || fc == nil || fc.Subnet != "122.96.30.0/24" {
		t.Fatalf("persisted = %+v, %v; want subnet 122.96.30.0/24", fc, err)
	}

	// Invalid input: rejected with ErrInvalidECS, live value untouched.
	if _, err := ctrl.SetChinaECS("bogus"); !errors.Is(err, ErrInvalidECS) {
		t.Fatalf("SetChinaECS(bogus) err = %v, want ErrInvalidECS", err)
	}
	if got := ctrl.ChinaECS(); got != "122.96.30.0/24" {
		t.Fatalf("live ChinaECS after invalid set = %q, want unchanged", got)
	}

	// Disable: empty subnet applies + persists.
	norm, err = ctrl.SetChinaECS("")
	if err != nil || norm != "" {
		t.Fatalf("SetChinaECS(\"\") = %q, %v; want \"\", nil", norm, err)
	}
	if got := ctrl.ChinaECS(); got != "" {
		t.Fatalf("live ChinaECS after disable = %q, want \"\"", got)
	}
}

// ---------------------------------------------------------------------------
// GET/PUT /api/ecs
// ---------------------------------------------------------------------------

func TestAPIECS_GetAndPut(t *testing.T) {
	cs, token := newAPITestServer(t)

	rec := doAuthReq(t, cs, token, http.MethodGet, "/api/ecs", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/ecs = %d; body=%s", rec.Code, rec.Body.String())
	}

	rec = doAuthReq(t, cs, token, http.MethodPut, "/api/ecs", `{"subnet":"122.96.30.5"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT /api/ecs = %d; body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON[map[string]string](t, rec)
	if body["subnet"] != "122.96.30.0/24" {
		t.Fatalf("PUT normalised subnet = %q, want 122.96.30.0/24", body["subnet"])
	}

	rec = doAuthReq(t, cs, token, http.MethodPut, "/api/ecs", `{"subnet":"not-an-ip"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("PUT /api/ecs invalid = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}
