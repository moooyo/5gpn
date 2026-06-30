package main

import (
	"context"
	"crypto/tls"
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

// upstream is one member of a group: the dial address and TLS config to use.
type upstream struct {
	addr   string      // normalised host:port
	tlsCfg *tls.Config // nil for UDP; set for DoT
}

// group is the common implementation for UDP and DoT upstream groups.
// It fans out queries to all members concurrently and returns the first
// non-error reply, cancelling the remaining goroutines via ctx.
type group struct {
	members []upstream
	net     string // "udp" or "tcp-tls"
}

// Exchange implements Exchanger. It starts one goroutine per member and
// returns the first non-error response. If all fail it returns the last error.
func (g *group) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	ch := make(chan result, len(g.members))
	for _, m := range g.members {
		m := m
		go func() {
			c := &dns.Client{Net: g.net, TLSConfig: m.tlsCfg}
			msg, _, err := c.ExchangeContext(ctx, q, m.addr)
			ch <- result{msg: msg, err: err}
		}()
	}

	var lastErr error
	for range g.members {
		r := <-ch
		if r.err == nil {
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
	members := make([]upstream, len(addrs))
	for i, a := range normaliseAddrs(addrs, "53") {
		members[i] = upstream{addr: a}
	}
	return &group{members: members, net: "udp"}
}

// NewDoTGroup returns an Exchanger that fans out DNS-over-TLS (tcp-tls) queries
// to addrs and returns the first non-error reply. Addresses without an explicit
// port get port 853 appended.
//
// Each address is used as the TLS ServerName as well (relying on the IP SAN in
// the server certificate). Use NewDoTGroupFromEntries for explicit ServerName
// control (e.g. "dns.google@8.8.8.8").
func NewDoTGroup(addrs []string) Exchanger {
	members := make([]upstream, len(addrs))
	for i, a := range normaliseAddrs(addrs, "853") {
		host, _, _ := net.SplitHostPort(a)
		members[i] = upstream{
			addr:   a,
			tlsCfg: &tls.Config{ServerName: host},
		}
	}
	return &group{members: members, net: "tcp-tls"}
}

// NewDoTGroupFromEntries returns an Exchanger that fans out DoT queries to the
// given entries, using each entry's ServerName for TLS verification and DialAddr
// for the connection.  Addresses without an explicit port get port 853 appended.
//
// This is the preferred constructor when trust upstreams are configured via the
// "serverName@dialIP" form (e.g. "dns.google@8.8.8.8").
func NewDoTGroupFromEntries(entries []TrustEntry) Exchanger {
	members := make([]upstream, len(entries))
	for i, e := range entries {
		addr := addDefaultPort(e.DialAddr, "853")
		members[i] = upstream{
			addr:   addr,
			tlsCfg: &tls.Config{ServerName: e.ServerName},
		}
	}
	return &group{members: members, net: "tcp-tls"}
}

