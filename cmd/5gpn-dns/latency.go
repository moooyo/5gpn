package main

import (
	"sort"
	"sync"
	"time"
)

// latencyWindowSize bounds how many recent samples a group retains. Large
// enough that p95 is meaningful (a p95 over 20 samples is really "the second
// worst"), small enough that the whole window is a few KB and sorting it on
// a status poll is free.
const latencyWindowSize = 512

// latencyWindowAge bounds how OLD a sample may be. Without it a quiet gateway
// would keep reporting last night's numbers indefinitely, which is the failure
// the cumulative mean had: it never forgot. With it, a group that has not been
// exchanged with recently reports no samples rather than stale ones.
const latencyWindowAge = 15 * time.Minute

// latencySample is one completed upstream exchange.
type latencySample struct {
	at time.Time
	d  time.Duration
}

// latencyWindow is a per-group rolling window of recent exchange durations,
// reported as percentiles.
//
// It replaces a cumulative sum/count mean, which was the wrong statistic three
// times over: it never decayed, so one pathological exchange stayed visible
// forever; it was persisted across restarts, so the number could predate the
// current upstreams entirely; and being a mean over a small sample, a single
// multi-second outlier dominated it — a 5ms resolver read as 140ms on 28
// samples, which is what prompted this.
//
// Percentiles answer the question an operator actually has. p50 is what a
// typical query costs; p95 is what the slow tail costs. Neither is moved by
// one outlier the way a mean is.
//
// A mutex rather than atomics: this is written once per completed upstream
// exchange — a path that has already done a network round trip — and read once
// per status poll. Lock contention here is not measurable, and the alternative
// (a lock-free ring) would buy nothing but a harder correctness argument.
type latencyWindow struct {
	mu      sync.Mutex
	samples []latencySample
	next    int  // write cursor for the ring
	filled  bool // the ring has wrapped at least once
	// now is a clock seam so tests can exercise ageing without sleeping.
	now func() time.Time
}

func newLatencyWindow() *latencyWindow {
	return &latencyWindow{samples: make([]latencySample, latencyWindowSize)}
}

func (w *latencyWindow) clock() time.Time {
	if w.now != nil {
		return w.now()
	}
	return time.Now()
}

// record adds one completed exchange. Nil-safe, matching the other counters.
func (w *latencyWindow) record(d time.Duration) {
	if w == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	w.samples[w.next] = latencySample{at: w.clock(), d: d}
	w.next++
	if w.next == len(w.samples) {
		w.next = 0
		w.filled = true
	}
}

// stats reports the window's percentiles in milliseconds and how many samples
// they were computed from. A window with no live samples reports zero count,
// which the API renders as "no samples" rather than as 0ms — a resolver that
// has not been asked anything is not a resolver answering instantly.
func (w *latencyWindow) stats() (p50Ms, p95Ms float64, count int) {
	if w == nil {
		return 0, 0, 0
	}
	w.mu.Lock()
	live := make([]time.Duration, 0, len(w.samples))
	cutoff := w.clock().Add(-latencyWindowAge)
	limit := w.next
	if w.filled {
		limit = len(w.samples)
	}
	for i := 0; i < limit; i++ {
		s := w.samples[i]
		if s.at.IsZero() || s.at.Before(cutoff) {
			continue
		}
		live = append(live, s.d)
	}
	w.mu.Unlock()

	if len(live) == 0 {
		return 0, 0, 0
	}
	sort.Slice(live, func(i, j int) bool { return live[i] < live[j] })
	return durationMs(percentile(live, 50)), durationMs(percentile(live, 95)), len(live)
}

// percentile returns the p-th percentile of a sorted slice using the
// nearest-rank method: the smallest value at or above p% of the samples. It is
// the definition that stays honest at small n — with 3 samples, p95 is the
// largest of them, not an interpolation between two of them that no exchange
// ever actually took.
func percentile(sorted []time.Duration, p int) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	rank := (p*len(sorted) + 99) / 100 // ceil(p/100 * n)
	if rank < 1 {
		rank = 1
	}
	if rank > len(sorted) {
		rank = len(sorted)
	}
	return sorted[rank-1]
}

func durationMs(d time.Duration) float64 {
	return float64(d.Nanoseconds()) / 1e6
}
