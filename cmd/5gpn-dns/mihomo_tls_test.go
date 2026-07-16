package main

import (
	"context"
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

type mihomoTLSTestServer struct {
	server     *httptest.Server
	controller string
	serverName string
	certFile   string
}

func newMihomoTLSTestServer(t *testing.T, handler http.Handler) mihomoTLSTestServer {
	t.Helper()

	certFile, keyFile := generateSelfSignedCert(t, t.TempDir())
	return newMihomoTLSTestServerWithCert(t, certFile, keyFile, handler)
}

func newMihomoTLSTestServerWithCert(t *testing.T, certFile, keyFile string, handler http.Handler) mihomoTLSTestServer {
	t.Helper()

	pair, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		t.Fatalf("load test certificate: %v", err)
	}

	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{
		Certificates: []tls.Certificate{pair},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"h2", "http/1.1"},
	}
	server.StartTLS()
	t.Cleanup(server.Close)

	return mihomoTLSTestServer{
		server:     server,
		controller: strings.TrimPrefix(server.URL, "https://"),
		serverName: "test.local",
		certFile:   certFile,
	}
}

func TestMihomoClientUsesVerifiedTLS(t *testing.T) {
	var gotAuth string

	upstream := newMihomoTLSTestServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusNoContent)
	}))

	client, err := NewMihomoClient(upstream.controller, "s3cr3t", upstream.serverName, upstream.certFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := client.PutConfigs(context.Background(), "/etc/5gpn/mihomo/config.yaml"); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer s3cr3t" {
		t.Fatalf("Authorization = %q", gotAuth)
	}
}

func TestMihomoClientRejectsWrongServerName(t *testing.T) {
	upstream := newMihomoTLSTestServer(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))

	client, err := NewMihomoClient(upstream.controller, "", "wrong.test", upstream.certFile)
	if err != nil {
		t.Fatal(err)
	}
	if client.Status(context.Background()).Reachable {
		t.Fatal("wrong certificate identity must be unreachable")
	}
}

func TestMihomoTransportRejectsMissingTrustFile(t *testing.T) {
	_, err := newMihomoTransport("127.0.0.1:9090", "zash.example.com", filepath.Join(t.TempDir(), "missing.pem"))
	if err == nil {
		t.Fatal("missing trust file must fail")
	}
}
