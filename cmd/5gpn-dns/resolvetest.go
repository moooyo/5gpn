package main

import (
	"context"
	"crypto/tls"
	"net"
	"sync"
	"time"

	"github.com/miekg/dns"
)

// The resolve test (GET /api/resolve-test) is the web console's diagnostic
// lookup: unlike the query pipeline (which fans out per GROUP and takes the
// first reply), it queries every configured upstream server INDIVIDUALLY and
// reports what each one answered, then re-applies the arbitration rule on top
// so the operator can see not just the final verdict but why: which servers
// answered, with what, and whose answer was adopted. Each group's adopted
// answer is the first server in POOL ORDER with a usable reply — never the
// fastest (gateway-side latency is not the clients'; see selectFirst).

// ResolveProbe is one upstream server's individual answer.
type ResolveProbe struct {
	Server string   `json:"server"`          // display spec: "223.5.5.5:53" or "dns.google@8.8.8.8:853"
	Group  string   `json:"group"`           // "china" | "trust"
	Proto  string   `json:"proto"`           // "udp" | "dot"
	IPs    []string `json:"ips,omitempty"`   // A records answered
	Rcode  string   `json:"rcode,omitempty"` // DNS rcode when a reply arrived
	// DurationMs is the gateway→upstream round trip, shown as a DIAGNOSTIC
	// only (it exposes a dead/slow upstream). It deliberately does NOT drive
	// adoption: the real clients sit on the terminal side of the network, so
	// gateway-side latency says nothing about their experience.
	DurationMs float64 `json:"duration_ms"`
	Err        string  `json:"err,omitempty"`
	Selected   bool    `json:"selected"` // this reply is its group's answer (first in pool order)
}

// ResolveTestResult is the full diagnostic outcome.
type ResolveTestResult struct {
	Name    string `json:"name"`
	Verdict string `json:"verdict"`
	Reason  string `json:"reason"`
	// Probes is empty for terminal name-only verdicts (block/force-proxy),
	// which never consult an upstream — mirroring the real pipeline.
	Probes []ResolveProbe `json:"probes"`
	// Chosen is the group whose answer the arbitration rule adopts ("china"
	// when the china answer contains a CN address, else "trust"); empty when
	// no upstream answered or none was consulted.
	Chosen    string   `json:"chosen,omitempty"`
	ChosenIPs []string `json:"chosen_ips,omitempty"` // the adopted upstream answer, un-rewritten
	// ClientIPs is what a real client would receive after the pipeline's
	// rewrite step (foreign IPs collapsed to the gateway IP; CN kept as-is).
	ClientIPs []string `json:"client_ips,omitempty"`
}

// ResolveTest runs the diagnostic lookup for name. It never touches the
// cache. A Controller with a nil handler returns a zero-value result.
func (c *Controller) ResolveTest(ctx context.Context, name string) ResolveTestResult {
	if c.handler == nil {
		return ResolveTestResult{}
	}
	h := c.handler
	res := ResolveTestResult{Name: name, Probes: []ResolveProbe{}}

	decision := h.decideName(name)
	verdict := decision.Verdict
	cn := h.chnroute()

	// Terminal name-only verdicts never consult an upstream (same as resolve).
	switch decision.Action {
	case actionBlock:
		res.Verdict, res.Reason = verdict.Verdict, verdict.Reason
		return res // NXDOMAIN — client gets nothing
	case actionGateway:
		res.Verdict, res.Reason = verdict.Verdict, verdict.Reason
		if h.GatewayIP != nil && !h.GatewayIP.IsUnspecified() {
			res.ClientIPs = []string{h.GatewayIP.String()}
		}
		return res
	}

	snap := h.upstreamSnap()
	if snap == nil {
		// Test-constructed handler with no published snapshot: report the
		// name-only classification and stop.
		res.Verdict, res.Reason = verdict.Verdict, verdict.Reason
		return res
	}

	res.Probes = h.probeUpstreams(ctx, name, snap)

	// Group answer = the FIRST configured server (pool order) with a usable
	// reply — deterministic, never latency-based (see selectFirst).
	chinaSel := selectFirst(res.Probes, "china")
	trustSel := selectFirst(res.Probes, "trust")

	// Arbitration rule: china wins iff its answer contains a CN address.
	var chosen *ResolveProbe
	if chinaSel != nil && anyCN(chinaSel.IPs, cn) {
		res.Chosen = "china"
		chosen = chinaSel
	} else if trustSel != nil {
		res.Chosen = "trust"
		chosen = trustSel
	}
	if chosen == nil {
		res.Verdict, res.Reason = verdict.Verdict, verdict.Reason
		return res
	}
	chosen.Selected = true
	res.ChosenIPs = chosen.IPs

	// Final verdict + what the client would see, mirroring resolve/Lookup:
	// force-direct keeps IPs as-is; the default path keeps CN answers and
	// collapses foreign ones to the gateway IP.
	gwUnset := h.GatewayIP == nil || h.GatewayIP.IsUnspecified()
	if decision.Action == actionDirect {
		res.Verdict, res.Reason = verdict.Verdict, verdict.Reason
		res.ClientIPs = chosen.IPs
		return res
	}
	if len(chosen.IPs) == 0 {
		// Live auto resolution preserves NXDOMAIN/NODATA but has no IP-based
		// chnroute verdict. Do not mislabel an empty response as foreign/proxy.
		return res
	}
	if anyCN(chosen.IPs, cn) {
		res.Verdict, res.Reason = "direct", "chnroute-cn"
		res.ClientIPs = chosen.IPs
		return res
	}
	res.Verdict, res.Reason = "proxy", "chnroute-foreign"
	if gwUnset || len(chosen.IPs) == 0 {
		res.ClientIPs = chosen.IPs
	} else {
		res.ClientIPs = []string{h.GatewayIP.String()}
	}
	return res
}

// probeUpstreams queries every configured upstream server individually and
// concurrently for name's A record, each bounded by the handler's per-query
// timeout. Probe order in the result is stable: china members first (config
// order), then trust members.
func (h *Handler) probeUpstreams(ctx context.Context, name string, snap *upstreamSnapshot) []ResolveProbe {
	type spec struct {
		display string
		addr    string
		group   string
		proto   string
		sni     string
	}
	var specs []spec
	for _, a := range snap.ChinaRaw {
		addr := addDefaultPort(a, "53")
		specs = append(specs, spec{display: addr, addr: addr, group: "china", proto: "udp"})
	}
	for i, e := range snap.TrustEntries {
		display := ""
		if i < len(snap.TrustRaw) {
			display = snap.TrustRaw[i]
		}
		if e.Plain {
			addr := addDefaultPort(e.DialAddr, "53")
			if display == "" {
				display = addr
			}
			specs = append(specs, spec{display: display, addr: addr, group: "trust", proto: "udp"})
		} else {
			addr := addDefaultPort(e.DialAddr, "853")
			if display == "" {
				display = e.ServerName + "@" + addr
			}
			specs = append(specs, spec{display: display, addr: addr, group: "trust", proto: "dot", sni: e.ServerName})
		}
	}

	to := h.Timeout
	if to <= 0 {
		to = 5 * time.Second
	}

	probes := make([]ResolveProbe, len(specs))
	var wg sync.WaitGroup
	for i, sp := range specs {
		wg.Add(1)
		go func(i int, sp spec) {
			defer wg.Done()
			pctx, cancel := context.WithTimeout(ctx, to)
			defer cancel()

			q := new(dns.Msg)
			q.SetQuestion(dns.Fqdn(name), dns.TypeA)

			c := &dns.Client{Net: "udp"}
			if sp.proto == "dot" {
				c.Net = "tcp-tls"
				c.TLSConfig = &tls.Config{ServerName: sp.sni}
			}
			start := time.Now()
			reply, _, err := c.ExchangeContext(pctx, q, sp.addr)
			p := ResolveProbe{
				Server:     sp.display,
				Group:      sp.group,
				Proto:      sp.proto,
				DurationMs: float64(time.Since(start).Microseconds()) / 1000.0,
			}
			if err != nil {
				p.Err = err.Error()
			} else if reply != nil {
				p.Rcode = dns.RcodeToString[reply.Rcode]
				p.IPs = answerIPs(reply, queryLogMaxIPs)
			}
			probes[i] = p
		}(i, sp)
	}
	wg.Wait()
	return probes
}

// selectFirst returns the group's adopted probe: the FIRST server in the
// configured pool order that returned a DNS message, or nil. A successful
// NXDOMAIN/NODATA response is still the group's first success in the live
// sequential group and must stop pool fallback just like an A response does.
//
// Adoption is deliberately NOT by measured latency: the probes' RTT is
// gateway→upstream, but the real clients sit on the terminal side of the
// network — a fast-for-the-gateway upstream says nothing about what serves
// the clients best. Pool order IS the operator's preference order, so the
// adopted answer is deterministic and configurable; the latency column stays
// as a diagnostic (it still exposes a dead or degraded upstream). Probes are
// built in pool order (probeUpstreams: china members first, config order,
// then trust members), so a forward scan is exactly pool order.
func selectFirst(probes []ResolveProbe, group string) *ResolveProbe {
	for i := range probes {
		p := &probes[i]
		if p.Group != group || p.Err != "" || p.Rcode == "" {
			continue
		}
		return p
	}
	return nil
}

// anyCN reports whether any of the dotted-string IPs is a chnroute member.
func anyCN(ips []string, cn *Chnroute) bool {
	if cn == nil {
		return false
	}
	for _, s := range ips {
		if ip := net.ParseIP(s); ip != nil && cn.Contains(ip) {
			return true
		}
	}
	return false
}
