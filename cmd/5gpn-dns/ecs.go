package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/miekg/dns"
)

// EDNS Client Subnet (RFC 7871) for the CHINA group only.
//
// The gateway queries the china upstreams from its own egress IP, which is
// usually in a different province/ISP than the phones it serves — so CN CDNs
// would hand back nodes near the GATEWAY, not near the CLIENT. Attaching the
// clients' cellular egress /24 as ECS steers CDN answers back to the clients'
// real region. The trust group never gets ECS: foreign answers are rewritten
// to the gateway anyway, and leaking a client subnet to foreign resolvers
// buys nothing.
//
// The subnet is deliberately a /24 (never a full /32): it is precise enough
// for CDN scheduling and avoids shipping one identifiable address upstream.

// ErrInvalidECS wraps caller-caused ECS validation failures so the HTTP layer
// can map them to a 400 (vs a 500 for a disk failure while persisting).
var ErrInvalidECS = errors.New("invalid ecs")

// parseECS parses an operator-supplied ECS spec into the subnet to attach:
//
//   - ""                → nil (ECS disabled)
//   - bare IPv4         → its /24 ("122.96.30.5" → 122.96.30.0/24)
//   - IPv4/IPv6 CIDR    → honoured as written (masked to its own prefix)
//   - bare IPv6         → its /56 (common ECS practice; v6 assignments are
//     per-site, a /24-equivalent privacy cut)
func parseECS(raw string) (*net.IPNet, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	if strings.Contains(raw, "/") {
		_, ipnet, err := net.ParseCIDR(raw)
		if err != nil {
			return nil, fmt.Errorf("%w: %q is not a valid CIDR", ErrInvalidECS, raw)
		}
		return ipnet, nil
	}
	ip := net.ParseIP(raw)
	if ip == nil {
		return nil, fmt.Errorf("%w: %q is not an IP address or CIDR", ErrInvalidECS, raw)
	}
	if v4 := ip.To4(); v4 != nil {
		return &net.IPNet{IP: v4.Mask(net.CIDRMask(24, 32)), Mask: net.CIDRMask(24, 32)}, nil
	}
	return &net.IPNet{IP: ip.Mask(net.CIDRMask(56, 128)), Mask: net.CIDRMask(56, 128)}, nil
}

// ecsSubnetString renders the attached subnet for display/persistence
// ("122.96.30.0/24"); nil (disabled) renders as "".
func ecsSubnetString(subnet *net.IPNet) string {
	if subnet == nil {
		return ""
	}
	return subnet.String()
}

// setECSOnMsg attaches subnet as an EDNS Client Subnet option to m, creating
// the OPT pseudo-record if the query has none and REPLACING any client-sent
// subnet option — the operator-configured subnet is authoritative on the
// china path. m must be a private copy (the caller's message is never
// mutated; group.Exchange copies before calling this).
func setECSOnMsg(m *dns.Msg, subnet *net.IPNet) {
	opt := m.IsEdns0()
	if opt == nil {
		m.SetEdns0(1232, false)
		opt = m.IsEdns0()
	}
	stripECSFromOpt(opt)
	family := uint16(1)
	addr := subnet.IP
	if v4 := addr.To4(); v4 != nil {
		addr = v4
	} else {
		family = 2
	}
	ones, _ := subnet.Mask.Size()
	opt.Option = append(opt.Option, &dns.EDNS0_SUBNET{
		Code:          dns.EDNS0SUBNET,
		Family:        family,
		SourceNetmask: uint8(ones),
		SourceScope:   0,
		Address:       addr,
	})
}

// stripECSFromMsg removes any EDNS Client Subnet option from m's OPT record.
// Used on china replies when we injected ECS ourselves, so the configured
// subnet stays contained to the upstream wire (clients never asked for ECS
// and should not see our echo).
func stripECSFromMsg(m *dns.Msg) {
	if m == nil {
		return
	}
	if opt := m.IsEdns0(); opt != nil {
		stripECSFromOpt(opt)
	}
}

func stripECSFromOpt(opt *dns.OPT) {
	kept := opt.Option[:0]
	for _, o := range opt.Option {
		if o.Option() != dns.EDNS0SUBNET {
			kept = append(kept, o)
		}
	}
	opt.Option = kept
}

// ecsFileVersion is the current ecs.json schema version.
const ecsFileVersion = 1

// ecsFileConfig is the on-disk shape of /etc/5gpn/ecs.json — the web-console-
// managed runtime override for the china-group ECS subnet. dns.env's
// DNS_CHINA_ECS stays the install-time value; this file, when present, wins at
// startup and is rewritten by PUT /api/ecs. Like upstreams.json it lives in
// the daemon-writable part of /etc/5gpn (dns.env itself is read-only to the
// sandboxed daemon). An empty Subnet means "explicitly disabled".
type ecsFileConfig struct {
	Version int    `json:"version"`
	Subnet  string `json:"subnet"`
}

// LoadECSFile reads the runtime ECS-override file. A missing file (or an
// empty path — persistence disabled) returns (nil, nil): the DNS_CHINA_ECS
// env value applies. A malformed file is an error the caller should log and
// ignore, never a reason to crash the sole resolver.
func LoadECSFile(path string) (*ecsFileConfig, error) {
	if path == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("ecs: read %s: %w", path, err)
	}
	var fc ecsFileConfig
	if err := unmarshalStrictJSON(data, &fc); err != nil {
		return nil, fmt.Errorf("ecs: parse %s: %w", path, err)
	}
	if fc.Version != ecsFileVersion {
		return nil, fmt.Errorf("ecs: %s: unsupported schema version %d (want %d)", path, fc.Version, ecsFileVersion)
	}
	if _, err := parseECS(fc.Subnet); err != nil {
		return nil, fmt.Errorf("ecs: %s: %w", path, err)
	}
	return &fc, nil
}

// SaveECSFile atomically writes the runtime ECS-override file (create-temp +
// rename, like subscriptions.json / upstreams.json). An empty path means
// persistence is disabled and the save is a silent no-op.
func SaveECSFile(path, subnet string) error {
	if path == "" {
		return nil
	}
	data, err := json.MarshalIndent(ecsFileConfig{Version: ecsFileVersion, Subnet: subnet}, "", "  ")
	if err != nil {
		return fmt.Errorf("ecs: marshal: %w", err)
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".ecs-*.tmp")
	if err != nil {
		return fmt.Errorf("ecs: create temp in %s: %w", dir, err)
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("ecs: write %s: %w", tmpPath, err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("ecs: close %s: %w", tmpPath, err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("ecs: rename to %s: %w", path, err)
	}
	return nil
}
