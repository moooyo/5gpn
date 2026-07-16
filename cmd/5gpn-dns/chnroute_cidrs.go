package main

import (
	"encoding/binary"
	"fmt"
	"math/bits"
	"net"
)

// CIDRs returns the minimal set of IPv4 CIDR strings that exactly represents
// the merged ranges held by this Chnroute. Each merged range is decomposed
// into the fewest power-of-two-aligned subnets that cover it without
// overlapping adjacent ranges. An empty Chnroute returns nil.
func (c *Chnroute) CIDRs() []string {
	if c == nil || len(c.ranges) == 0 {
		return nil
	}
	out := make([]string, 0, len(c.ranges)*2)
	for _, r := range c.ranges {
		out = appendRangeCIDRs(out, r.start, r.end)
	}
	return out
}

// appendRangeCIDRs decomposes [start, end] (inclusive uint32) into the minimal
// set of CIDR blocks. Algorithm: greedily pick the largest power-of-two block
// starting at `start` that fits within [start, end].
func appendRangeCIDRs(dst []string, start, end uint32) []string {
	for start <= end {
		// Largest block size: limited by trailing zeros of start and by
		// remaining space [start, end].
		maxBits := bits.TrailingZeros32(start)
		if start == 0 {
			maxBits = 32
		}
		remaining := end - start + 1
		// Find highest bit of remaining
		nBits := 0
		for (uint32(1)<<nBits) <= remaining && nBits <= maxBits {
			nBits++
		}
		nBits-- // largest power of 2 that fits
		if nBits < 0 {
			nBits = 0
		}

		prefixLen := 32 - nBits
		ip := make(net.IP, 4)
		binary.BigEndian.PutUint32(ip, start)
		dst = append(dst, fmt.Sprintf("%s/%d", ip.String(), prefixLen))

		blockSize := uint32(1) << nBits
		start += blockSize
		if start == 0 {
			break // overflow
		}
	}
	return dst
}
