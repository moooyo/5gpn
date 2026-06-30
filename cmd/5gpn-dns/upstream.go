package chnroute

import (
	"context"
	"fmt"
	"net"
	"strings"

	"github.com/miekg/dns"
)

// Exchanger sends a DNS query and returns the reply.
// Implementations may be a single server or a group of servers.
type Exchanger interface {
	Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error)
}

// result bundles a reply with its associated error for channel communication.
type result struct {
	msg *dns.Msg
	err error
}

// group is the common implementation for UDP and DoT upstream groups.
// It fans out queries to all addrs concurrently and returns the first
// non-error reply, cancelling the remaining goroutines via ctx.
type group struct {
	addrs []string // normalised host:port strings
	net   string   // "udp" or "tcp-tls"
}

// Exchange implements Exchanger. It starts one goroutine per address and
// returns the first non-error response. If all fail it returns the last error.
func (g *group) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	ch := make(chan result, len(g.addrs))
	for _, addr := range g.addrs {
		addr := addr
		go func() {
			c := &dns.Client{Net: g.net}
			// ExchangeContext uses ctx for deadline/cancellation.
			m, _, err := c.ExchangeContext(ctx, q, addr)
			ch <- result{msg: m, err: err}
		}()
	}

	var lastErr error
	for range g.addrs {
		r := <-ch
		if r.err == nil {
			// Signal all losers to stop.
			cancel()
			return r.msg, nil
		}
		lastErr = r.err
	}
	return nil, fmt.Errorf("all upstreams failed: %w", lastErr)
}

// addDefaultPort appends defaultPort to addr if addr has no port component.
func addDefaultPort(addr, defaultPort string) string {
	// Check if it's already host:port.
	if strings.Contains(addr, ":") {
		// Could be IPv6 bare address or host:port — if it wraps in brackets it's IPv6.
		// For simplicity: if it parses as host+port it's already set; if not, append.
		if _, _, err := net.SplitHostPort(addr); err == nil {
			return addr
		}
		// IPv6 address without brackets — wrap and add port.
		return net.JoinHostPort(addr, defaultPort)
	}
	return net.JoinHostPort(addr, defaultPort)
}

// normaliseAddrs returns a copy of addrs with defaultPort appended to any
// address that lacks an explicit port.
func normaliseAddrs(addrs []string, defaultPort string) []string {
	out := make([]string, len(addrs))
	for i, a := range addrs {
		out[i] = addDefaultPort(a, defaultPort)
	}
	return out
}

// NewUDPGroup returns an Exchanger that fans out UDP queries to addrs and
// returns the first non-error reply. Addresses without an explicit port get
// port 53 appended.
func NewUDPGroup(addrs []string) Exchanger {
	return &group{
		addrs: normaliseAddrs(addrs, "53"),
		net:   "udp",
	}
}

// NewDoTGroup returns an Exchanger that fans out DNS-over-TLS (tcp-tls) queries
// to addrs and returns the first non-error reply. Addresses without an explicit
// port get port 853 appended.
func NewDoTGroup(addrs []string) Exchanger {
	return &group{
		addrs: normaliseAddrs(addrs, "853"),
		net:   "tcp-tls",
	}
}
