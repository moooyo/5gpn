package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/miekg/dns"
)

var ErrInvalidResolver = errors.New("invalid egress resolver")

// hostLookupFunc is used only once at startup to bootstrap a DoH hostname.
type hostLookupFunc func(host string) ([]net.IP, error)

func defaultHostLookup(host string) ([]net.IP, error) {
	return net.DefaultResolver.LookupIP(context.Background(), "ip4", host)
}

func buildBrokerFallbackExchanger(resolver string, lookup hostLookupFunc) (Exchanger, io.Closer, error) {
	return buildBrokerFallbackExchangerTLS(resolver, lookup, nil)
}

func buildBrokerFallbackExchangerTLS(resolver string, lookup hostLookupFunc, dohTLS *tls.Config) (Exchanger, io.Closer, error) {
	resolver = strings.TrimSpace(resolver)
	if err := validateFallbackResolver(resolver); err != nil {
		return nil, nil, err
	}
	if lookup == nil {
		lookup = defaultHostLookup
	}
	if strings.HasPrefix(resolver, "https://") {
		return buildDoHFallback(resolver, lookup, dohTLS)
	}
	return buildUDPFallback(resolver)
}

func ValidateResolver(s string) error {
	s = strings.TrimSpace(s)
	if s == "" {
		return fmt.Errorf("%w: empty", ErrInvalidResolver)
	}
	if strings.HasPrefix(s, "https://") {
		u, err := url.Parse(s)
		if err != nil || u.Host == "" {
			return fmt.Errorf("%w: malformed DoH URL %q", ErrInvalidResolver, s)
		}
		return nil
	}
	if ip := net.ParseIP(s); ip != nil && ip.To4() != nil {
		return nil
	}
	return fmt.Errorf("%w: %q (want a plain IPv4 or an https://…/dns-query DoH URL)", ErrInvalidResolver, s)
}

func validateFallbackResolver(resolver string) error {
	if strings.HasPrefix(resolver, "https://") {
		return ValidateResolver(resolver)
	}
	host := resolver
	if h, _, err := net.SplitHostPort(resolver); err == nil {
		host = h
	}
	return ValidateResolver(host)
}

type udpBrokerExchanger struct{ addr string }

func (u *udpBrokerExchanger) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	resp, _, err := (&dns.Client{Net: "udp", Timeout: brokerQueryTimeout}).ExchangeContext(ctx, q, u.addr)
	if err != nil || resp == nil || !resp.Truncated {
		return resp, err
	}
	resp, _, err = (&dns.Client{Net: "tcp", Timeout: brokerQueryTimeout}).ExchangeContext(ctx, q, u.addr)
	return resp, err
}

func buildUDPFallback(resolver string) (Exchanger, io.Closer, error) {
	addr := resolver
	if _, _, err := net.SplitHostPort(addr); err != nil {
		addr = net.JoinHostPort(addr, "53")
	}
	return &udpBrokerExchanger{addr: addr}, nil, nil
}

type dohBrokerExchanger struct {
	endpoint  string
	transport *http.Transport
	client    *http.Client
}

func (d *dohBrokerExchanger) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	wire, err := q.Pack()
	if err != nil {
		return nil, fmt.Errorf("broker DoH pack: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.endpoint, bytes.NewReader(wire))
	if err != nil {
		return nil, fmt.Errorf("broker DoH request: %w", err)
	}
	req.Header.Set("Accept", "application/dns-message")
	req.Header.Set("Content-Type", "application/dns-message")
	resp, err := d.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("broker DoH exchange: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("broker DoH status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 65536))
	if err != nil {
		return nil, fmt.Errorf("broker DoH read: %w", err)
	}
	out := new(dns.Msg)
	if err := out.Unpack(body); err != nil {
		return nil, fmt.Errorf("broker DoH unpack: %w", err)
	}
	return out, nil
}

func (d *dohBrokerExchanger) Close() error {
	d.transport.CloseIdleConnections()
	return nil
}

func buildDoHFallback(rawURL string, lookup hostLookupFunc, dohTLS *tls.Config) (Exchanger, io.Closer, error) {
	u, err := url.Parse(rawURL)
	if err != nil || u.Hostname() == "" {
		return nil, nil, fmt.Errorf("broker fallback: malformed DoH URL")
	}
	host := u.Hostname()
	ips, err := lookup(host)
	if err != nil {
		return nil, nil, fmt.Errorf("broker fallback: DoH bootstrap resolve for %q failed: %w", host, err)
	}
	boot := make([]string, 0, len(ips))
	for _, ip := range ips {
		if v4 := ip.To4(); v4 != nil {
			boot = append(boot, v4.String())
		}
	}
	if len(boot) == 0 {
		return nil, nil, fmt.Errorf("broker fallback: DoH bootstrap for %q yielded no IPv4 address", host)
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: host}
	if dohTLS != nil {
		tlsCfg = dohTLS.Clone()
		tlsCfg.ServerName = host
	}
	dialer := &net.Dialer{}
	transport := &http.Transport{
		ForceAttemptHTTP2: true,
		TLSClientConfig:   tlsCfg,
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var lastErr error
			for _, ip := range boot {
				conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(ip, port))
				if err == nil {
					return conn, nil
				}
				lastErr = err
			}
			return nil, lastErr
		},
	}
	ex := &dohBrokerExchanger{
		endpoint:  rawURL,
		transport: transport,
		client:    &http.Client{Transport: transport},
	}
	return ex, ex, nil
}

func newDefaultEgressDNSBroker(cfg Config) (*EgressDNSBroker, io.Closer, error) {
	if strings.TrimSpace(cfg.EgressBrokerAddr) == "" {
		return nil, nil, fmt.Errorf("egress DNS broker address is empty; mihomo requires a loopback broker listener")
	}
	upstream, closer, err := buildBrokerFallbackExchanger(cfg.XrayResolver, nil)
	if err != nil {
		return nil, nil, err
	}
	return NewEgressDNSBroker(cfg.EgressBrokerAddr, upstream), closer, nil
}
