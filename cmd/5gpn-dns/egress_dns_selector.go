package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/miekg/dns"
)

// egressDNSSelector resolves mihomo's sniffed hostnames through the live
// 5gpn-dns upstream groups. Names captured by an active extension use that
// extension's operator-selected China or trust binding; every other name uses
// trust. Client DNS policy is deliberately not consulted here.
type egressDNSSelector struct {
	handler *Handler
}

func (s *egressDNSSelector) Exchange(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
	if s == nil || s.handler == nil {
		return nil, errors.New("egress DNS selector is unavailable")
	}
	if q == nil || len(q.Question) != 1 {
		return nil, errors.New("egress DNS selector requires exactly one question")
	}
	china, trust := s.handler.exchangers()
	resolver, _ := s.handler.captureDNSForName(q.Question[0].Name)
	selected := trust
	if resolver == interceptCaptureDNSChina {
		selected = china
	}
	if selected == nil {
		return nil, fmt.Errorf("egress DNS %s group is unavailable", resolver)
	}
	return selected.Exchange(ctx, q)
}

func newDefaultEgressDNSBroker(cfg Config, handler *Handler) (*EgressDNSBroker, error) {
	if strings.TrimSpace(cfg.EgressBrokerAddr) == "" {
		return nil, errors.New("egress DNS broker address is empty; mihomo requires a loopback broker listener")
	}
	if handler == nil {
		return nil, errors.New("egress DNS broker requires the live DNS handler")
	}
	return NewEgressDNSBroker(cfg.EgressBrokerAddr, &egressDNSSelector{handler: handler}), nil
}
