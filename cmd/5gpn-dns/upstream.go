package main

import (
	"context"
	crand "crypto/rand"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"strings"
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
// like 22.22.22.22) with DoT members ("serverName@IP" entries).
type upstream struct {
	addr   string      // normalised host:port
	net    string      // "udp" or "tcp-tls"
	tlsCfg *tls.Config // nil for UDP; set for DoT
}

// group is the common implementation for the china and trust upstream groups.
// It tries members sequentially in pool (configuration) order and returns the
// first success — see Exchange for why this is deliberately not a fan-out race.
type group struct {
	members []upstream
	label   string // group name for error messages ("china", "trust")
	breaker *breaker

	// randomize enables DNS 0x20 encoding (RFC-draft) on outgoing queries: the
	// question name's letters are randomly cased and the reply must echo that
	// exact casing or it is rejected as a probable off-path spoof. It raises the
	// bar for blind cache poisoning on the plaintext-UDP china path (whose CN
	// verdict steers a client to a real IP, so a poisoned answer redirects
	// traffic). Default-on (DNS_CHINA_0X20) but backed by a startup self-probe
	// (probe0x20): if a china upstream is CONFIRMED to normalise query-name case —
	// which would make every echo check fail and quietly funnel CN domains through
	// the gateway — the probe flips this off, so "default on" cannot degrade
	// resolution. atomic because the probe writes it from a goroutine while queries
	// read it. Set only on the UDP group.
	randomize atomic.Bool

	// ecs, when non-nil, is the EDNS Client Subnet (RFC 7871) attached to every
	// outgoing query — the clients' cellular egress /24, so CN CDNs schedule
	// answers near the CLIENTS instead of near the gateway's own egress IP.
	// Set only on the china group (see ecs.go for why trust never gets it).
	// atomic.Pointer because PUT /api/ecs swaps it at runtime while queries read.
	ecs atomic.Pointer[net.IPNet]
}

// SetGroupECS sets (or clears, with nil) the ECS subnet a group attaches to
// outgoing queries. A no-op for non-*group Exchangers (fakes in tests).
// Exported-style helper (like StartChina0x20Probe) so main/Controller stay
// free of the concrete group type.
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

	// 0x20: send a case-randomised copy of the query and require the reply to
	// echo that exact casing. Randomised once per Exchange so every attempted
	// member sends (and must echo) the same name. origName/sentName are empty
	// when disabled.
	var origName, sentName string
	if g.randomize.Load() && len(q.Question) > 0 {
		origName = q.Question[0].Name
		sentName = randomizeDNSCase(origName)
		send.Question[0].Name = sentName
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
		c := &dns.Client{Net: m.net, TLSConfig: m.tlsCfg}
		msg, _, err := c.ExchangeContext(attemptCtx, send, m.addr)
		// miekg/dns deliberately does not retry a truncated UDP response over
		// TCP. Do it here within the same member slice so a DoT client never gets
		// a TC response it cannot recover from on its already-stream transport.
		if err == nil && msg != nil && msg.Truncated && m.net == "udp" {
			tcpClient := &dns.Client{Net: "tcp"}
			msg, _, err = tcpClient.ExchangeContext(attemptCtx, send, m.addr)
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

		if err == nil && sentName != "" {
			// The reply must echo our randomised question name byte-for-byte;
			// otherwise treat it as a probable off-path spoof and drop it
			// (this member fails; the next one is tried).
			if msg == nil || len(msg.Question) == 0 || msg.Question[0].Name != sentName {
				lastErr = fmt.Errorf("0x20 case-echo mismatch (possible off-path spoof or case-normalising upstream)")
				continue
			}
			// Restore the caller's original casing so 0x20 stays contained to
			// the wire and downstream sees a byte-identical message.
			restoreDNSCase(msg, sentName, origName)
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

// randomizeDNSCase returns name with each ASCII letter's case flipped at random
// (DNS 0x20). Non-letters (dots, digits, hyphens) are untouched. Uses crypto/rand
// for the per-letter bit; on the (practically impossible) read failure the bytes
// stay zero, yielding an all-lowercased-where-flipped name that is still a valid
// query — 0x20 degrades to no-op rather than erroring.
func randomizeDNSCase(name string) string {
	b := []byte(name)
	r := make([]byte, len(b))
	_, _ = crand.Read(r)
	for i, c := range b {
		if r[i]&1 == 0 {
			continue
		}
		switch {
		case c >= 'a' && c <= 'z':
			b[i] = c - 32 // to upper
		case c >= 'A' && c <= 'Z':
			b[i] = c + 32 // to lower
		}
	}
	return string(b)
}

// restoreDNSCase rewrites msg's question name and any answer/authority/additional
// owner name that byte-matches sentName back to origName, so the case-randomised
// wire form never leaks past Exchange. Records whose owner differs (e.g. CNAME
// chain targets) are left as the upstream sent them. Case-insensitive resolution
// makes this cosmetic downstream, but it keeps 0x20 fully contained.
func restoreDNSCase(msg *dns.Msg, sentName, origName string) {
	if len(msg.Question) > 0 && msg.Question[0].Name == sentName {
		msg.Question[0].Name = origName
	}
	for _, section := range [][]dns.RR{msg.Answer, msg.Ns, msg.Extra} {
		for _, rr := range section {
			if h := rr.Header(); h != nil && h.Name == sentName {
				h.Name = origName
			}
		}
	}
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
// port 53 appended. randomize enables DNS 0x20 anti-spoof encoding (see
// group.randomize); the caller should run StartChina0x20Probe afterwards so a
// case-normalising upstream disables it automatically.
func NewUDPGroup(addrs []string, randomize bool) Exchanger {
	members := make([]upstream, len(addrs))
	for i, a := range normaliseAddrs(addrs, "53") {
		members[i] = upstream{addr: a, net: "udp"}
	}
	g := &group{members: members, label: "china", breaker: newBreaker()}
	g.randomize.Store(randomize)
	return g
}

// decide0x20 turns the probe's observations into "keep 0x20 enabled?":
//   - anyPreserve: at least one member echoed the 0x20-cased name byte-for-byte
//     → 0x20 works (the group returns that member's reply), keep it on.
//   - else anyReachablePlain: a member answered a PLAIN query but none preserved
//     the 0x20 casing → the reachable upstream(s) normalise case → disable, or
//     every CN query would echo-mismatch and get funnelled through the gateway.
//   - else (nothing reachable): inconclusive; keep on (harmless — the china group
//     is down anyway, and a later restart re-probes when it recovers).
func decide0x20(anyPreserve, anyReachablePlain bool) bool {
	if anyPreserve {
		return true
	}
	if anyReachablePlain {
		return false
	}
	return true
}

// probe0x20 checks whether the china upstreams echo 0x20 query-name casing and
// flips g.randomize off if they are confirmed to normalise it. Runs once at
// startup (in a goroutine — never blocks serving); queries members directly (not
// via Exchange) so it never mutates shared state mid-flight. A no-op if 0x20 is
// already off.
func (g *group) probe0x20(ctx context.Context) {
	if !g.randomize.Load() {
		return
	}
	const probeName = "www.qq.com."
	timeout := 4 * time.Second
	anyPreserve, anyReachablePlain := false, false
	for _, m := range g.members {
		select {
		case <-ctx.Done():
			return
		default:
		}
		// Ensure the cased probe actually DIFFERS from the plain name.
		// randomizeDNSCase flips each letter with p=1/2, so ~1/256 of the time it
		// returns the unchanged all-lowercase probeName — and a case-NORMALISING
		// upstream echoing that lowercase name would then match below and be
		// mis-counted as case-preserving, defeating the probe. Retry (bounded — the
		// cap guards the theoretical no-letter name where no casing can differ).
		sent := randomizeDNSCase(probeName)
		for i := 0; sent == probeName && i < 16; i++ {
			sent = randomizeDNSCase(probeName)
		}
		q := new(dns.Msg)
		q.SetQuestion(sent, dns.TypeA)
		c := &dns.Client{Net: m.net, Timeout: timeout}
		if r, _, err := c.ExchangeContext(ctx, q, m.addr); err == nil && r != nil && len(r.Question) > 0 {
			if r.Question[0].Name == sent {
				anyPreserve = true
				break // one preserving member is enough for the group to work
			}
			// Reachable but did not echo our casing → normalises.
			anyReachablePlain = true
		} else {
			// 0x20 query failed; see if a PLAIN query reaches this member (to tell
			// "normalises" apart from "unreachable").
			qp := new(dns.Msg)
			qp.SetQuestion(probeName, dns.TypeA)
			if rp, _, errp := c.ExchangeContext(ctx, qp, m.addr); errp == nil && rp != nil {
				anyReachablePlain = true
			}
		}
	}
	if !decide0x20(anyPreserve, anyReachablePlain) {
		g.randomize.Store(false)
		log.Printf("warning: DNS_CHINA_0X20 auto-disabled — a china upstream normalises query-name case (0x20 echo check would funnel CN domains through the gateway). Point DNS_CHINA at case-preserving resolvers to re-enable.")
	}
}

// StartChina0x20Probe launches the china group's 0x20 case-preservation probe in
// the background (a no-op if ex is not a *group or 0x20 is off). Keeps main free
// of the concrete group type.
func StartChina0x20Probe(ctx context.Context, ex Exchanger) {
	if g, ok := ex.(*group); ok {
		go g.probe0x20(ctx)
	}
}

// NewTrustGroup returns an Exchanger that fans out queries to the given trust
// entries. Each entry picks its own transport:
//
//   - "serverName@dialIP" → DoT (port 853 default), TLS-verified against
//     ServerName, sharing one TLS client-session cache so cache-miss queries
//     resume handshakes instead of paying full asymmetric crypto each time.
//   - bare "IP" (Plain) → plain UDP (port 53 default) — for a trusted internal
//     resolver reachable over a clean path (the 22.22.22.22 default), where
//     requiring a DoT cert would just break resolution.
func NewTrustGroup(entries []TrustEntry) Exchanger {
	sessCache := tls.NewLRUClientSessionCache(0) // 0 → default capacity
	members := make([]upstream, len(entries))
	for i, e := range entries {
		if e.Plain {
			members[i] = upstream{addr: addDefaultPort(e.DialAddr, "53"), net: "udp"}
			continue
		}
		members[i] = upstream{
			addr:   addDefaultPort(e.DialAddr, "853"),
			net:    "tcp-tls",
			tlsCfg: &tls.Config{ServerName: e.ServerName, ClientSessionCache: sessCache},
		}
	}
	return &group{members: members, label: "trust", breaker: newBreaker()}
}
