// Package chnroute_test uses the package name "chnroute" via external test package.
// This file is package chnroute (the main package for this module).
package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
)

// ipRange represents a contiguous IPv4 address range [start, end] inclusive,
// stored as uint32 in network byte order (big-endian).
type ipRange struct {
	start, end uint32
}

// Chnroute holds a sorted, merged list of IPv4 CIDR ranges for China IPs.
type Chnroute struct {
	ranges []ipRange
}

// ErrEmptyChnroute is returned (wrapped) by LoadChnrouteFiles when no valid
// IPv4 CIDRs were found across all given paths. Callers that can tolerate a
// temporarily-empty chnroute (e.g. main's startup path, before the
// subscription manager has had a chance to fetch one) can check for this with
// errors.Is and fall back to an empty *Chnroute instead of failing hard.
var ErrEmptyChnroute = errors.New("chnroute: empty set")

// ipToUint32 converts a 4-byte IPv4 address to uint32 (big-endian).
func ipToUint32(ip net.IP) uint32 {
	ip4 := ip.To4()
	if ip4 == nil {
		return 0
	}
	return binary.BigEndian.Uint32(ip4)
}

// LoadChnroute reads a file of CIDR-per-line entries (lines starting with '#'
// are comments; malformed lines are silently skipped) and returns a Chnroute.
// Returns an error if no valid CIDRs are found — an empty set would cause every
// IP to appear foreign, which is a misconfiguration.
func LoadChnroute(path string) (*Chnroute, error) {
	return LoadChnrouteFiles(path)
}

// LoadChnrouteFiles reads CIDR-per-line entries from all given paths (lines
// starting with '#' are comments; malformed lines are silently skipped) and
// returns a merged Chnroute. Paths that don't exist are skipped silently —
// this lets callers combine a manual file with subscription-cache files
// without pre-checking existence. Returns an error if no valid CIDRs are
// found across all paths — an empty set would cause every IP to appear
// foreign, which is a misconfiguration.
func LoadChnrouteFiles(paths ...string) (*Chnroute, error) {
	var raw []ipRange
	for _, path := range paths {
		f, err := os.Open(path)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("chnroute: open %s: %w", path, err)
		}

		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			_, ipNet, err := net.ParseCIDR(line)
			if err != nil {
				// silently skip bad lines per spec
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil {
				// skip non-IPv4 CIDRs
				continue
			}
			start := binary.BigEndian.Uint32(ip4)
			// Calculate end: start | ^mask
			ones, bits := ipNet.Mask.Size()
			if bits != 32 {
				// not an IPv4 mask
				continue
			}
			hostBits := uint32(bits - ones)
			var end uint32
			if hostBits == 32 {
				end = ^uint32(0)
			} else {
				end = start | (1<<hostBits - 1)
			}
			raw = append(raw, ipRange{start, end})
		}
		scanErr := scanner.Err()
		f.Close()
		if scanErr != nil {
			return nil, fmt.Errorf("chnroute: scan %s: %w", path, scanErr)
		}
	}

	if len(raw) == 0 {
		return nil, fmt.Errorf("chnroute: no valid IPv4 CIDRs found: %w", ErrEmptyChnroute)
	}

	// Sort by start address, then merge overlapping/adjacent ranges.
	sort.Slice(raw, func(i, j int) bool {
		return raw[i].start < raw[j].start
	})

	merged := raw[:1:1]
	for _, r := range raw[1:] {
		last := &merged[len(merged)-1]
		// Ranges overlap or are adjacent (last.end+1 >= r.start) when last.end >= r.start-1.
		// Guard against underflow when r.start == 0: use >= instead of last.end+1 >= r.start.
		if r.start == 0 || last.end >= r.start-1 {
			if r.end > last.end {
				last.end = r.end
			}
		} else {
			merged = append(merged, r)
		}
	}

	return &Chnroute{ranges: merged}, nil
}

// Contains reports whether ip is within any CIDR range in the set.
// Returns false for non-IPv4 addresses.
// Fix #4: nil receiver is safe — returns false (all IPs appear foreign).
func (c *Chnroute) Contains(ip net.IP) bool {
	if c == nil {
		return false
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	n := ipToUint32(ip4)
	// Binary search: find the last range whose start <= n.
	idx := sort.Search(len(c.ranges), func(i int) bool {
		return c.ranges[i].start > n
	}) - 1
	if idx < 0 {
		return false
	}
	return n <= c.ranges[idx].end
}

// Len returns the number of merged ranges in the set.
func (c *Chnroute) Len() int {
	return len(c.ranges)
}
