package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"sync/atomic"
	"time"

	"github.com/miekg/dns"
)

// Exchanger sends a DNS query and returns the reply.
// Implementations may be a single server or a group of servers.
type Exchanger interface {
	Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error)
}

// upstream is one member of a group: the dial address, wire transport, and
// TLS config to use. Transport is per-member (not per-group) so the trust
// group can mix plain-UDP members (bare-IP entries, e.g. an internal resolver
// like 22.22.22.22) with DoT members ("serverName@IP" entries) and DoH members
// ("https://host/path@IP" entries).
type upstream struct {
	addr   string      // normalised host:port
	net    string      // "udp" or "tcp-tls"; empty for DoH (see doh)
	tlsCfg *tls.Config // nil for UDP; set for DoT
	// doh, when non-nil, replaces the dns.Client exchange for this member with
	// a pooled HTTP/2 request. Its connections are reused across queries, so
	// unlike the udp/tcp-tls members it does not pay a handshake per query.
	doh *dohClient
}

// group is the common implementation for the china and trust upstream groups.
// It tries members sequentially in pool (configuration) order and returns the
// first success — see Exchange for why this is deliberately not a fan-out race.
type group struct {
	members []upstream
	label   string // group name for error messages ("china", "trust")
	breaker *breaker

	// ecs, when non-nil, is the EDNS Client Subnet (RFC 7871) attached to every
	// outgoing query — the clients' cellular egress /24, so CN CDNs schedule
	// answers near the CLIENTS instead of near the gateway's own egress IP.
	// Set only on the china group (see ecs.go for why trust never gets it).
	// atomic.Pointer because PUT /api/ecs swaps it at runtime while queries read.
	ecs atomic.Pointer[net.IPNet]
}

// SetGroupECS sets (or clears, with nil) the ECS subnet a group attaches to
// outgoing queries. A no-op for non-*group Exchangers (fakes in tests).
// Exported-style helper so main/Controller stay free of the concrete group
// type.
func SetGroupECS(ex Exchanger, subnet *net.IPNet) {
	if g, ok := ex.(*group); ok {
		g.ecs.Store(subnet)
	}
}

// GetGroupECS returns the group's current ECS subnet (nil when disabled or
// when ex is not a *group).
func GetGroupECS(ex Exchanger) *net.IPNet {
	if g, ok := ex.(*group); ok {
		return g.ecs.Load()
	}
	return nil
}

// Exchange implements Exchanger. It tries the members SEQUENTIALLY in pool
// (configuration) order and returns the first success. Pool order is the
// operator's deterministic preference order.
//
// Each attempt gets an equal slice of the remaining ctx budget
// (remaining / members-left), so a dead first member cannot consume the whole
// query deadline and starve the later ones; whatever an early-failing member
// doesn't use rolls over to the next. If all members fail the last error is
// returned. When the group's circuit breaker is open (repeated recent
// failures) it fails fast without dialing.
// Close releases any pooled connections the group holds.
//
// Only DoH members hold anything: the udp/tcp-tls path builds a throwaway
// dns.Client per attempt, so its sockets are closed by miekg on return. A DoH
// member's idle connections live in an http.Transport that the group keeps
// reachable, so a retired group would otherwise hold its sockets open for the
// life of the process — one leaked fd per pooled connection on every
// PUT /api/upstreams, which the console can issue repeatedly.
//
// Safe to call on a group still serving in-flight queries: CloseIdleConnections
// closes only connections that are not currently in use, and an active request
// finishes on its own connection. Callers should still retire on a grace timer
// rather than immediately, because queries that loaded the old snapshot are
// entitled to finish against it.
func (g *group) Close() {
	if g == nil {
		return
	}
	for _, m := range g.members {
		m.doh.closeIdle()
	}
}

func (g *group) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	if !g.breaker.allow() {
		return nil, fmt.Errorf("upstream group (%s) circuit open", g.label)
	}

	// Always send a private copy and remove client-supplied ECS before any
	// upstream exchange. Only the operator-configured China subnet may leave the
	// gateway; trust must never receive a client subnet, and a client-provided ECS
	// value must never affect a response stored for another client.
	send := q.Copy()
	stripECSFromMsg(send)
	ecsSubnet := g.ecs.Load()
	if ecsSubnet != nil {
		setECSOnMsg(send, ecsSubnet)
	}

	var lastErr error
	for i, m := range g.members {
		// Per-attempt budget: an even share of what's left, so member k of n
		// can never eat the later members' chance to answer.
		attemptCtx := ctx
		var cancel context.CancelFunc
		if dl, ok := ctx.Deadline(); ok {
			slice := time.Until(dl) / time.Duration(len(g.members)-i)
			attemptCtx, cancel = context.WithTimeout(ctx, slice)
		}
		var msg *dns.Msg
		var err error
		if m.doh != nil {
			// Pooled HTTP/2: no per-query handshake, and a cancelled request
			// resets only its own stream, leaving the connection reusable.
			msg, err = m.doh.exchange(attemptCtx, send)
		} else {
			c := &dns.Client{Net: m.net, TLSConfig: m.tlsCfg}
			msg, _, err = c.ExchangeContext(attemptCtx, send, m.addr)
			// miekg/dns deliberately does not retry a truncated UDP response over
			// TCP. Do it here within the same member slice so a DoT client never gets
			// a TC response it cannot recover from on its already-stream transport.
			if err == nil && msg != nil && msg.Truncated && m.net == "udp" {
				tcpClient := &dns.Client{Net: "tcp"}
				msg, _, err = tcpClient.ExchangeContext(attemptCtx, send, m.addr)
			}
		}
		if cancel != nil {
			cancel()
		}

		// A caller-side cancellation is not an upstream health signal:
		// Arbitrate cancels the abandoned group on every china-CN win, and a
		// disconnecting client cancels both groups. A trust attempt (especially
		// a TCP+TLS member) may still be in flight when a fast china UDP answer
		// wins, and DialContext honours cancellation — so counting those as
		// failures lets ordinary CN-heavy traffic trip the trust breaker
		// (5 consecutive CN answers open it, and the half-open probe can be
		// re-cancelled the same way, latching it). Deadline expiry still counts:
		// the upstream had its budget and didn't answer. Checked on the PARENT
		// ctx — an attempt-slice timeout is DeadlineExceeded on the child only
		// and must keep iterating.
		if ctx.Err() == context.Canceled {
			g.breaker.recordCanceled()
			if err == nil {
				err = ctx.Err()
			}
			return nil, fmt.Errorf("exchange abandoned by caller: %w", err)
		}

		if err == nil {
			// ECS is an upstream-only implementation detail. Strip an echo or an
			// unsolicited option regardless of whether operator ECS is enabled.
			stripECSFromMsg(msg)
			g.breaker.record(true)
			return msg, nil
		}
		lastErr = err
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("no upstream members configured")
	}
	g.breaker.record(false)
	return nil, fmt.Errorf("all upstreams failed: %w", lastErr)
}

// addDefaultPort appends defaultPort to addr if addr has no port component.
func addDefaultPort(addr, defaultPort string) string {
	if _, _, err := net.SplitHostPort(addr); err != nil {
		return net.JoinHostPort(addr, defaultPort)
	}
	return addr
}

// retireGroup closes a replaced group's pooled connections after a grace
// window. Not immediate: a query that already loaded the old snapshot may hold
// the old exchanger for up to the per-query timeout and is entitled to finish
// against it. A no-op when the group was reused, or when it is not a *group
// (test fakes).
func retireGroup(old, replacement Exchanger, grace time.Duration) {
	retiring, ok := old.(*group)
	if !ok || Exchanger(retiring) == replacement {
		return
	}
	time.AfterFunc(grace, retiring.Close)
}

// newTransportGroup builds a group from transport-tagged entries. Both groups
// share it because transport is a per-MEMBER property (see the upstream type):
// label differs only for error messages and the degraded-member warning.
func newTransportGroup(label string, entries []UpstreamEntry) *group {
	sessCache := tls.NewLRUClientSessionCache(0) // 0 → default capacity
	members := make([]upstream, len(entries))
	for i, e := range entries {
		switch e.Transport {
		case UpstreamDoH:
			client, err := newDoHClient(e.Endpoint, addDefaultPort(e.DialAddr, "443"), sessCache)
			if err != nil {
				// ValidateUpstreams rejects malformed DoH specs before they
				// reach here, so this is a defensive path. Degrade the member
				// rather than the group: a nil doh member fails its own
				// attempt and the loop rolls to the next one.
				log.Printf("warning: %s upstream %q: %v — member disabled", label, e.Endpoint, err)
				members[i] = upstream{addr: addDefaultPort(e.DialAddr, "443")}
				continue
			}
			members[i] = upstream{addr: addDefaultPort(e.DialAddr, "443"), doh: client}
		case UpstreamDoT:
			members[i] = upstream{
				addr:   addDefaultPort(e.DialAddr, "853"),
				net:    "tcp-tls",
				tlsCfg: &tls.Config{ServerName: e.ServerName, ClientSessionCache: sessCache},
			}
		default:
			members[i] = upstream{addr: addDefaultPort(e.DialAddr, "53"), net: "udp"}
		}
	}
	return &group{members: members, label: label, breaker: newBreaker()}
}

// NewChinaGroup builds the china group. Transports are per-member, exactly as
// for trust: a domestic resolver reachable only over plaintext UDP and one
// offering DoH can sit in the same pool.
func NewChinaGroup(entries []UpstreamEntry) Exchanger {
	return newTransportGroup("china", entries)
}

// NewTrustGroup builds the trust group from transport-tagged entries: DoH over
// a pooled HTTP/2 connection, DoT with TLS verified against ServerName, or
// plain UDP for a trusted internal resolver on a clean path where requiring a
// certificate would just break resolution.
func NewTrustGroup(entries []UpstreamEntry) Exchanger {
	return newTransportGroup("trust", entries)
}
