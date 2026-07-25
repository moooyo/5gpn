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
//
// It holds one contract of its own: NO IPv6 ADDRESS LEAVES THIS RESOLVER, in
// any section, in any record type. 5gpn is an IPv4-only steering gateway, and
// this is the boundary where that becomes true for the data plane -- the seed's
// `ipv6: false` cannot be relied on, because /etc/5gpn/mihomo/config.yaml is
// operator-owned and every deployment published before that seed keeps its own
// bytes forever.
//
// The contract is stated as a property of THIS resolver, not as a list of what
// mihomo happens to read. mihomo's Resolver.LookupIP fires an AAAA query
// unconditionally today and its msgToIP harvests A and AAAA from the Answer
// section without checking the qtype, but pinning the guard to those internals
// would make our correctness a function of a third party's private
// implementation: a future mihomo that reads another section, or another
// consumer on this socket, would silently escape a filter tuned to v1.19.28.
//
// What an unfiltered IPv6 answer costs: mihomo races it against the IPv4 one,
// and when the v6 leg wins its TCP dial SUCCEEDS -- so the dual-stack fallback
// never fires -- while a destination that refuses or mislocates the gateway's
// datacenter IPv6 prefix fails at the application layer, where nothing can
// recover it. That is the "resolves to IPv6, no fallback, unreachable" report
// this exists to prevent.
//
// Accepted deliberately: an origin, or an operator proxy node named by
// hostname, published only as AAAA is unreachable through the gateway. On an
// IPv4-only data plane an IPv6 answer would not have been dialable either.
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

	// The IPv4-only contract on the type is enforced in two halves, because a
	// question and an answer can each carry IPv6 independently of the other.
	//
	// Half one: an AAAA question never reaches an upstream. Answering it here
	// costs nothing, and the synthetic SOA lets the asker negatively cache it
	// instead of re-asking per connection. This runs before the nil-upstream
	// check on purpose -- it is a property of the resolver, not of whether an
	// upstream happens to be configured.
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
	// Half two: no reply carries an IPv6 address out, whatever was asked. This
	// is not redundant with half one -- an address can ride in the answer to a
	// different question, and a conforming upstream is not something an
	// IPv4-only guarantee can rest on. Same filter as the client boundary, so
	// there is one definition of "records that defeat steering" to audit.
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
