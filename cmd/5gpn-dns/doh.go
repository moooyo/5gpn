package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"time"

	"github.com/miekg/dns"
)

// dohMediaType is the RFC 8484 wire-format media type, used for both the
// request body and the expected response.
const dohMediaType = "application/dns-message"

// dohMaxResponseBytes bounds how much of a DoH response body is read. A DNS
// message cannot exceed dns.MaxMsgSize, and without a limit a hostile or
// broken resolver could stream unbounded data into the sole resolver's memory.
const dohMaxResponseBytes = dns.MaxMsgSize

// dohClient is one DoH (RFC 8484) upstream member: a pooled HTTP/2 client
// pinned to a specific dial address.
//
// Why HTTP/2 rather than a hand-rolled DoT connection pool. Both remove the
// per-query TCP+TLS handshake, but a pooled DoT connection has to solve
// response demultiplexing itself, and the query IDs available to it are the
// CLIENT's IDs (they arrive on the wire from stub resolvers, which commonly
// use small or sequential values) — so two concurrent queries can collide and
// hand one client another's answer. HTTP/2 stream IDs do that demultiplexing
// at the transport, and net/http owns the pool, idle reaping, keep-alive and
// stale-connection retry.
//
// The decisive property is cancellation. arbitrateSrc cancels the abandoned
// group on every china-CN win, which on CN-heavy traffic is most cache misses.
// Cancelling an HTTP/2 request resets that stream only; the connection is
// untouched and stays pooled. The equivalent on a shared DoT connection would
// abandon a read mid-frame and desync every later query on it.
type dohClient struct {
	endpoint string // absolute https:// URL queried with POST
	http     *http.Client
	// transport is retained so idle connections can be closed when the group
	// is retired — see group.Close.
	transport *http.Transport
}

// newDoHClient builds a pooled client for one DoH member.
//
// dialAddr pins the TCP destination: name resolution for the endpoint host
// must not go through this daemon (it is the thing being configured), so the
// operator supplies the address and the hostname is used only for TLS
// verification and the Host header.
func newDoHClient(endpoint, dialAddr string, sessCache tls.ClientSessionCache) (*dohClient, error) {
	u, err := url.Parse(endpoint)
	if err != nil {
		return nil, fmt.Errorf("doh: parse %q: %w", endpoint, err)
	}
	if u.Scheme != "https" || u.Host == "" {
		return nil, fmt.Errorf("doh: %q must be an absolute https:// URL", endpoint)
	}

	transport := &http.Transport{
		// ForceAttemptHTTP2 keeps HTTP/2 negotiation on despite the custom
		// DialContext below; without it net/http silently drops to HTTP/1.1
		// for any transport carrying a dial override, and HTTP/1.1 gives one
		// query per connection at a time — the multiplexing this exists for.
		ForceAttemptHTTP2: true,
		TLSClientConfig: &tls.Config{
			ServerName:         u.Hostname(),
			ClientSessionCache: sessCache,
			MinVersion:         tls.VersionTLS12,
		},
		// Ignore the resolved address net/http would use and dial the pinned
		// one. Resolving the endpoint hostname here would be circular.
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext(ctx, network, dialAddr)
		},
		// One member is one origin, so per-host and total are the same bound.
		// A small pool is right: upstream concurrency is already bounded by the
		// response cache, the single-flight collapse and admission control, so
		// a large pool would only hold idle sockets open.
		MaxIdleConns:        4,
		MaxIdleConnsPerHost: 4,
		// Comfortably under the idle timeout public resolvers apply, so the
		// daemon closes first rather than racing a server-side FIN.
		IdleConnTimeout:     25 * time.Second,
		TLSHandshakeTimeout: 5 * time.Second,
	}

	return &dohClient{
		endpoint:  u.String(),
		transport: transport,
		// No Timeout here: the caller's ctx already carries the per-attempt
		// budget, and a second independent deadline would cut an exchange the
		// group still considers live.
		http: &http.Client{Transport: transport},
	}, nil
}

// exchange performs one RFC 8484 POST exchange.
func (c *dohClient) exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	// RFC 8484 section 4.1: the ID SHOULD be 0, because HTTP already
	// correlates request and response. Sending the client's ID would leak it
	// to the upstream for no benefit. The caller's ID is restored on the
	// reply so downstream matching is unchanged.
	sent := q.Copy()
	originalID := q.Id
	sent.Id = 0

	wire, err := sent.Pack()
	if err != nil {
		return nil, fmt.Errorf("doh: pack: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(wire))
	if err != nil {
		return nil, fmt.Errorf("doh: build request: %w", err)
	}
	req.Header.Set("Content-Type", dohMediaType)
	req.Header.Set("Accept", dohMediaType)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("doh: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Drain a bounded amount so the connection can be reused rather than
		// abandoned mid-body.
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, dohMaxResponseBytes))
		return nil, fmt.Errorf("doh: upstream returned HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, dohMaxResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("doh: read body: %w", err)
	}

	reply := new(dns.Msg)
	if err := reply.Unpack(body); err != nil {
		return nil, fmt.Errorf("doh: unpack: %w", err)
	}
	reply.Id = originalID
	return reply, nil
}

// closeIdle releases pooled connections. Called when a group is retired after
// an upstream hot-swap; without it the old group's sockets stay reachable
// through the pool and are never collected.
func (c *dohClient) closeIdle() {
	if c != nil && c.transport != nil {
		c.transport.CloseIdleConnections()
	}
}
