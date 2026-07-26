package main

import (
	"testing"
	"time"
)

func ms(n int) time.Duration { return time.Duration(n) * time.Millisecond }

// The case that prompted the change: 27 fast exchanges and one slow one. A
// cumulative mean reported 140ms for a 5ms resolver; percentiles do not move.
func TestLatencyWindow_OutlierDoesNotDominate(t *testing.T) {
	w := newLatencyWindow()
	for i := 0; i < 27; i++ {
		w.record(ms(5))
	}
	w.record(ms(3800))

	p50, p95, n := w.stats()
	if n != 28 {
		t.Fatalf("samples = %d, want 28", n)
	}
	if p50 != 5 {
		t.Errorf("p50 = %v ms, want 5 — the typical query is unaffected by one outlier", p50)
	}
	// The old arithmetic mean over exactly this input was 140.2ms.
	mean := (27*5.0 + 3800.0) / 28
	if p50 >= mean {
		t.Errorf("p50 %v is not below the old mean %v; the statistic did not improve", p50, mean)
	}
	// p95 of 28 samples is the 27th smallest — still 5ms; the single outlier
	// sits at p100, which is exactly the point: it is visible as a tail, not
	// smeared across the headline number.
	if p95 != 5 {
		t.Errorf("p95 = %v ms, want 5", p95)
	}
}

// A genuinely slow tail must show up in p95 rather than being hidden.
func TestLatencyWindow_SlowTailIsVisible(t *testing.T) {
	w := newLatencyWindow()
	for i := 0; i < 90; i++ {
		w.record(ms(10))
	}
	for i := 0; i < 10; i++ {
		w.record(ms(400))
	}
	p50, p95, n := w.stats()
	if n != 100 {
		t.Fatalf("samples = %d, want 100", n)
	}
	if p50 != 10 {
		t.Errorf("p50 = %v, want 10", p50)
	}
	if p95 != 400 {
		t.Errorf("p95 = %v, want 400 — a 10%% slow tail must surface at p95", p95)
	}
}

// The window is bounded: old samples are evicted by newer ones.
func TestLatencyWindow_EvictsBeyondCapacity(t *testing.T) {
	w := newLatencyWindow()
	for i := 0; i < latencyWindowSize; i++ {
		w.record(ms(900))
	}
	for i := 0; i < latencyWindowSize; i++ {
		w.record(ms(3))
	}
	p50, p95, n := w.stats()
	if n != latencyWindowSize {
		t.Fatalf("samples = %d, want the window capacity %d", n, latencyWindowSize)
	}
	if p50 != 3 || p95 != 3 {
		t.Errorf("p50=%v p95=%v, want 3/3 — the old samples were not evicted", p50, p95)
	}
}

// Ageing is what the cumulative mean lacked: a quiet gateway must stop
// reporting last night's numbers rather than presenting them as current.
func TestLatencyWindow_AgesOutStaleSamples(t *testing.T) {
	now := time.Now()
	w := newLatencyWindow()
	w.now = func() time.Time { return now }

	w.record(ms(42))
	if _, _, n := w.stats(); n != 1 {
		t.Fatalf("samples = %d, want 1", n)
	}

	now = now.Add(latencyWindowAge + time.Minute)
	p50, p95, n := w.stats()
	if n != 0 {
		t.Errorf("samples = %d, want 0 once past the window age", n)
	}
	if p50 != 0 || p95 != 0 {
		t.Errorf("p50=%v p95=%v, want 0/0 for an empty window", p50, p95)
	}
}

// An empty window reports zero samples, not 0ms. A resolver nobody has asked
// anything is not a resolver answering instantly.
func TestLatencyWindow_EmptyReportsNoSamples(t *testing.T) {
	if p50, p95, n := newLatencyWindow().stats(); n != 0 || p50 != 0 || p95 != 0 {
		t.Errorf("empty window = p50 %v p95 %v n %d, want zeros", p50, p95, n)
	}
	var nilWindow *latencyWindow
	if _, _, n := nilWindow.stats(); n != 0 {
		t.Error("nil window must report no samples rather than panic")
	}
	nilWindow.record(ms(1)) // must not panic
}

// Nearest-rank, so every reported value is a duration some exchange actually
// took — no interpolation between two samples.
func TestPercentileNearestRank(t *testing.T) {
	sorted := []time.Duration{ms(1), ms(2), ms(3), ms(4), ms(5)}
	for _, tc := range []struct {
		p    int
		want time.Duration
	}{
		{50, ms(3)},
		{95, ms(5)},
		{100, ms(5)},
		{1, ms(1)},
	} {
		if got := percentile(sorted, tc.p); got != tc.want {
			t.Errorf("percentile(p%d) = %v, want %v", tc.p, got, tc.want)
		}
	}
	// Small n must stay honest: p95 of three samples is the largest.
	if got := percentile([]time.Duration{ms(1), ms(2), ms(9)}, 95); got != ms(9) {
		t.Errorf("percentile(p95) over 3 samples = %v, want 9ms", got)
	}
	if got := percentile(nil, 50); got != 0 {
		t.Errorf("percentile of nothing = %v, want 0", got)
	}
}
