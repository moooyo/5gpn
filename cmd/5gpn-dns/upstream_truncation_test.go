package main

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func TestUDPGroupRetriesTruncatedResponseOverTCP(t *testing.T) {
	tcpListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := tcpListener.Addr().String()
	udpConn, err := net.ListenPacket("udp", addr)
	if err != nil {
		tcpListener.Close()
		t.Fatal(err)
	}

	handler := dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		resp := new(dns.Msg)
		resp.SetReply(r)
		if w.LocalAddr().Network() == "udp" {
			resp.Truncated = true
		} else {
			resp.Answer = makeAMsg(r.Question[0].Name, "1.2.3.4").Answer
		}
		_ = w.WriteMsg(resp)
	})
	udpServer := &dns.Server{PacketConn: udpConn, Handler: handler}
	tcpServer := &dns.Server{Listener: tcpListener, Handler: handler}
	go func() { _ = udpServer.ActivateAndServe() }()
	go func() { _ = tcpServer.ActivateAndServe() }()
	t.Cleanup(func() {
		_ = udpServer.Shutdown()
		_ = tcpServer.Shutdown()
	})

	g := NewUDPGroup([]string{addr}, false)
	req := new(dns.Msg)
	req.SetQuestion("example.com.", dns.TypeA)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	resp, err := g.Exchange(ctx, req)
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	if resp.Truncated || len(resp.Answer) != 1 {
		t.Fatalf("response = %#v, want full TCP answer", resp)
	}
}
