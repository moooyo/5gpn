package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/miekg/dns"
)

// brokerQueryTimeout bounds one sniffed-origin lookup so a wedged resolver
// cannot hold a mihomo connection indefinitely.
const brokerQueryTimeout = 5 * time.Second

// EgressDNSBroker is mihomo's loopback DNS resolver for sniffed origins. Its
// selector returns a canonical China- or trust-group answer without applying
// the client-facing gateway rewrite, and never falls back to the host resolver.
// AAAA is answered with synthetic NODATA so the data plane stays IPv4-only; see
// ServeDNS.
type EgressDNSBroker struct {
	addr     string
	upstream Exchanger

	mu      sync.Mutex
	pc      net.PacketConn
	ln      net.Listener
	udpSrv  *dns.Server
	tcpSrv  *dns.Server
	started bool
	stopped bool
	logf    func(format string, args ...interface{})
}

func NewEgressDNSBroker(addr string, upstream Exchanger) *EgressDNSBroker {
	return &EgressDNSBroker{addr: addr, upstream: upstream, logf: log.Printf}
}

func (b *EgressDNSBroker) UDPAddr() net.Addr {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.pc == nil {
		return nil
	}
	return b.pc.LocalAddr()
}

func (b *EgressDNSBroker) TCPAddr() net.Addr {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ln == nil {
		return nil
	}
	return b.ln.Addr()
}

// Start binds UDP and TCP synchronously. The address must be an IPv4
// loopback literal; :0 is accepted for tests even though configuration only
// accepts real ports.
func (b *EgressDNSBroker) Start() error {
	if b.addr == "" {
		return nil
	}
	host, _, err := net.SplitHostPort(b.addr)
	if err != nil {
		return fmt.Errorf("egress DNS broker: invalid listen address %q: must be host:port (%w)", b.addr, err)
	}
	if err := validateLoopbackIPv4Host(host); err != nil {
		return fmt.Errorf("egress DNS broker: invalid listen address %q: %w", b.addr, err)
	}

	pc, err := net.ListenPacket("udp", b.addr)
	if err != nil {
		return fmt.Errorf("egress DNS broker UDP listen %s: %w", b.addr, err)
	}
	ln, err := net.Listen("tcp", b.addr)
	if err != nil {
		_ = pc.Close()
		return fmt.Errorf("egress DNS broker TCP listen %s: %w", b.addr, err)
	}

	b.mu.Lock()
	b.pc = pc
	b.ln = ln
	b.udpSrv = &dns.Server{PacketConn: pc, Handler: b}
	b.tcpSrv = &dns.Server{Listener: ln, Handler: b}
	b.started = true
	b.mu.Unlock()

	go func() {
		if err := b.udpSrv.ActivateAndServe(); err != nil && !b.isStopped() {
			b.logf("egress DNS broker: udp serve on %s stopped: %v", b.addr, err)
		}
	}()
	go func() {
		if err := b.tcpSrv.ActivateAndServe(); err != nil && !b.isStopped() {
			b.logf("egress DNS broker: tcp serve on %s stopped: %v", b.addr, err)
		}
	}()
	return nil
}

func (b *EgressDNSBroker) isStopped() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.stopped
}

func (b *EgressDNSBroker) Shutdown(ctx context.Context) {
	b.mu.Lock()
	if b.stopped || !b.started {
		b.stopped = true
		b.mu.Unlock()
		return
	}
	b.stopped = true
	udpSrv, tcpSrv := b.udpSrv, b.tcpSrv
	b.mu.Unlock()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_ = udpSrv.ShutdownContext(ctx)
	}()
	go func() {
		defer wg.Done()
		_ = tcpSrv.ShutdownContext(ctx)
	}()
	wg.Wait()
}

func (b *EgressDNSBroker) ServeDNS(w dns.ResponseWriter, r *dns.Msg) {
	if len(r.Question) != 1 {
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeFormatError)
		_ = w.WriteMsg(m)
		return
	}

	// AAAA -> synthetic NODATA, exactly like the client-facing handler.
	//
	// This is not cosmetic symmetry; it is the only place an IPv4-only gateway
	// can enforce IPv4-only egress. mihomo v1.19.28 resolves a sniffed origin
	// through this broker, and its Resolver.LookupIP fires the AAAA query
	// UNCONDITIONALLY -- it never consults the resolver's own `ipv6` field, so a
	// `dns.ipv6: false` in the operator's config does not suppress it. Only the
	// top-level `ipv6: false` does, by flipping resolver.DisableIPv6, and
	// /etc/5gpn/mihomo/config.yaml is fully operator-owned: existing deployments
	// keep their own bytes forever, so the seed cannot be relied on to carry it.
	//
	// Left unfiltered, mihomo learns the origin's real IPv6 addresses and races
	// them against the IPv4 ones. When the v6 leg wins, the gateway egresses from
	// a datacenter IPv6 prefix that many destinations refuse or geolocate
	// differently -- and because the TCP dial SUCCEEDED, mihomo's dual-stack
	// fallback never fires. The failure surfaces at the application layer, where
	// nothing can recover it, which is exactly the "resolves to IPv6, no
	// fallback, unreachable" report this guard exists to prevent.
	//
	// With no AAAA answer mihomo has only IPv4 candidates and the box stays
	// IPv4-only end to end. The synthetic SOA lets mihomo negatively cache it
	// instead of re-asking per connection. Trade-off, accepted deliberately: an
	// origin (or an operator proxy node named by hostname) that publishes ONLY
	// AAAA is unreachable through the gateway. That is inherent to an IPv4-only
	// data plane -- an IPv6 answer here would not have been dialable either.
	if r.Question[0].Qtype == dns.TypeAAAA {
		_ = w.WriteMsg(syntheticNODATA(r))
		return
	}

	if b.upstream == nil {
		b.servfail(w, r)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), brokerQueryTimeout)
	defer cancel()
	resp, err := b.upstream.Exchange(ctx, r)
	if err != nil || resp == nil {
		b.servfail(w, r)
		return
	}
	// Gating the AAAA QUESTION is not enough on its own. mihomo's msgToIP
	// iterates the Answer section and collects every *dns.A AND *dns.AAAA it
	// finds, without checking what was asked -- so an AAAA record riding inside
	// the reply to an A query becomes a dial candidate just the same. A
	// well-behaved resolver does not do that, but this broker is the boundary
	// that has to hold when one misbehaves, and "the upstream is well-behaved"
	// is not something an IPv4-only guarantee can rest on. Strip the same RR
	// set the client path strips, for the same reason.
	resp = filterSteeringBypassRRs(resp)
	resp.Id = r.Id
	resp.Response = true
	resp.RecursionAvailable = true
	_ = w.WriteMsg(resp)
}

func (b *EgressDNSBroker) servfail(w dns.ResponseWriter, r *dns.Msg) {
	m := new(dns.Msg)
	m.SetRcode(r, dns.RcodeServerFailure)
	m.RecursionAvailable = true
	_ = w.WriteMsg(m)
}
