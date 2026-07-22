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
