package main

import (
	"net"
	"strings"
	"sync"
	"time"

	"github.com/miekg/dns"
)

// The in-memory query log: every answered DNS query is recorded into a small
// ring buffer with a short retention window (5 minutes), served at
// GET /api/querylog for the web console's log-search view. It is deliberately
// ephemeral — nothing is written to disk, a restart empties it — because its
// job is "what just resolved on this box", not long-term analytics.

const (
	// queryLogCapacity bounds the ring regardless of QPS, so a query flood
	// can't grow memory: at ~27 QPS sustained the window still covers the full
	// 5 minutes; above that the oldest entries rotate out early.
	queryLogCapacity = 8192

	// queryLogRetention is how far back entries are served. Fixed by design —
	// the log answers "just now", not "today".
	queryLogRetention = 5 * time.Minute

	// queryLogMaxIPs caps the answer IPs stored per entry (an A answer rarely
	// has more; keeps entry size bounded).
	queryLogMaxIPs = 8
)

// QueryLogEntry is one resolved query as the API reports it.
type QueryLogEntry struct {
	Time       time.Time `json:"time"`
	Client     string    `json:"client,omitempty"`
	Name       string    `json:"name"`
	Qtype      string    `json:"qtype"`
	Verdict    string    `json:"verdict,omitempty"`
	Reason     string    `json:"reason,omitempty"`
	Upstream   string    `json:"upstream,omitempty"`
	CacheHit   bool      `json:"cache_hit"`
	Rcode      string    `json:"rcode"`
	IPs        []string  `json:"ips,omitempty"`
	DurationMs float64   `json:"duration_ms"`
}

// queryLog is a fixed-capacity ring of QueryLogEntry with time-based
// retention applied on read. add is called from the hot query path (one mutex
// acquisition + one slot write — no allocation beyond the entry itself).
type queryLog struct {
	mu        sync.Mutex
	buf       []QueryLogEntry
	next      int // next write position
	filled    bool
	retention time.Duration
}

func newQueryLog(capacity int, retention time.Duration) *queryLog {
	if capacity <= 0 {
		capacity = queryLogCapacity
	}
	if retention <= 0 {
		retention = queryLogRetention
	}
	return &queryLog{buf: make([]QueryLogEntry, capacity), retention: retention}
}

// add records one entry, overwriting the oldest when the ring is full.
func (l *queryLog) add(e QueryLogEntry) {
	l.mu.Lock()
	l.buf[l.next] = e
	l.next++
	if l.next == len(l.buf) {
		l.next = 0
		l.filled = true
	}
	l.mu.Unlock()
}

// search returns up to limit entries newer than the retention window, newest
// first, whose name or client contains q (case-insensitive; empty q matches
// everything).
func (l *queryLog) search(q string, limit int, now time.Time) []QueryLogEntry {
	if limit <= 0 {
		limit = 200
	}
	q = strings.ToLower(strings.TrimSpace(q))
	cutoff := now.Add(-l.retention)

	l.mu.Lock()
	defer l.mu.Unlock()

	n := l.next
	if l.filled {
		n = len(l.buf)
	}
	out := make([]QueryLogEntry, 0, min(limit, n))
	// Walk backwards from the newest entry.
	for i := 0; i < n && len(out) < limit; i++ {
		idx := l.next - 1 - i
		if idx < 0 {
			idx += len(l.buf)
		}
		e := l.buf[idx]
		if e.Time.Before(cutoff) {
			break // entries only get older from here
		}
		if q != "" &&
			!strings.Contains(strings.ToLower(e.Name), q) &&
			!strings.Contains(strings.ToLower(e.Client), q) {
			continue
		}
		out = append(out, e)
	}
	return out
}

// clientHost extracts the client IP (sans port) from the DNS transport's
// remote address. Nil-safe for test ResponseWriters without a remote address.
func clientHost(w dns.ResponseWriter) string {
	if w == nil {
		return ""
	}
	ra := w.RemoteAddr()
	if ra == nil {
		return ""
	}
	if host, _, err := net.SplitHostPort(ra.String()); err == nil {
		return host
	}
	return ra.String()
}

// answerIPs returns up to max A-record addresses from resp's Answer section.
func answerIPs(resp *dns.Msg, max int) []string {
	if resp == nil {
		return nil
	}
	var ips []string
	for _, rr := range resp.Answer {
		if a, ok := rr.(*dns.A); ok {
			ips = append(ips, a.A.String())
			if len(ips) == max {
				break
			}
		}
	}
	return ips
}
