package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

func newMihomoTransport(controller, serverName, certFile string) (*http.Transport, error) {
	controller = strings.TrimSpace(controller)
	serverName = strings.TrimSuffix(strings.TrimSpace(serverName), ".")
	if controller == "" {
		return nil, fmt.Errorf("mihomo TLS: controller address is required")
	}
	host, _, err := net.SplitHostPort(controller)
	if err != nil {
		return nil, fmt.Errorf("mihomo TLS: invalid controller address %q: %w", controller, err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return nil, fmt.Errorf("mihomo TLS: controller must be a loopback IP: %q", controller)
	}
	if serverName == "" {
		return nil, fmt.Errorf("mihomo TLS: server name is required")
	}

	pemBytes, err := os.ReadFile(certFile)
	if err != nil {
		return nil, fmt.Errorf("mihomo TLS: read trust certificate: %w", err)
	}
	roots, err := x509.SystemCertPool()
	if err != nil {
		return nil, fmt.Errorf("mihomo TLS: load system roots: %w", err)
	}
	if roots == nil {
		roots = x509.NewCertPool()
	}
	if !roots.AppendCertsFromPEM(pemBytes) {
		return nil, fmt.Errorf("mihomo TLS: trust certificate contains no certificate")
	}

	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	return &http.Transport{
		Proxy:               nil,
		TLSHandshakeTimeout: 10 * time.Second,
		IdleConnTimeout:     90 * time.Second,
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			ServerName: serverName,
			RootCAs:    roots,
			NextProtos: []string{"http/1.1"},
		},
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, controller)
		},
	}, nil
}
