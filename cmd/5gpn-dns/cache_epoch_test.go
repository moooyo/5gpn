package main

import (
	"context"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// A Flush must invalidate writers that captured their epoch before it: an
// in-flight query resolved under the pre-reload rules would otherwise write
// its (now stale-policy) answer into the freshly flushed cache and re-mask
// the rule change for up to its TTL.
func TestPutAtEpochDiscardsWritesAcrossFlush(t *testing.T) {
	c := NewCache(16)
	msg := makeAMsg("example.test.", "1.2.3.4")

	e := c.Epoch()
	c.Flush() // a reload lands while the query is in flight
	c.PutAtEpoch("example.test.", dns.TypeA, msg, time.Minute, e)
	if n := c.Len(); n != 0 {
		t.Fatalf("a put captured before the flush must be discarded, cache has %d entries", n)
	}

	// A writer that captured the post-flush epoch stores normally.
	c.PutAtEpoch("example.test.", dns.TypeA, msg, time.Minute, c.Epoch())
	if n := c.Len(); n != 1 {
		t.Fatalf("a current-epoch put must store, cache has %d entries", n)
	}

	// Nil-cache safety mirrors Put/Flush.
	var nilCache *Cache
	if nilCache.Epoch() != 0 {
		t.Fatal("nil cache Epoch must be 0")
	}
}

// End-to-end through the handler: a reload between resolve start and cachePut
// (simulated by flushing behind resolve's back via an exchanger hook) must
// leave the cache empty, so the very next query re-resolves under the new
// rules instead of hitting a pre-reload answer.
func TestResolveDoesNotRepopulateFlushedCache(t *testing.T) {
	name := "inflight.test."
	reply := makeAMsg(name, "1.2.3.4") // CN → kept as-is

	h := newTestHandler(t, nil, nil)
	// The china exchanger flushes the cache mid-resolve — after resolve
	// captured its epoch, before cachePut runs — exactly what a concurrent
	// swapRuleSets does.
	h.China = &hookExchanger{reply: reply, hook: func() { h.Cache.Flush() }}
	h.Trust = &fakeExchanger{reply: reply}

	q := new(dns.Msg)
	q.SetQuestion(name, dns.TypeA)
	resp := h.resolve(context.Background(), q.Question[0], q)
	if len(resp.Answer) == 0 {
		t.Fatal("the in-flight query must still get its answer")
	}
	if n := h.Cache.Len(); n != 0 {
		t.Fatalf("an answer resolved before the flush must not repopulate the cache, got %d entries", n)
	}
}

// An upstream swap after epoch capture but before snapshot capture must make
// the request use the new upstreams while preventing its old-epoch cache write
// from entering the newly flushed cache generation.
func TestResolveCapturesEpochBeforeUpstreamSnapshot(t *testing.T) {
	name := "snapshot-order.direct.test."
	oldChina := &fakeExchanger{reply: makeAMsg(name)}
	oldTrust := &fakeExchanger{reply: makeAMsg(name, "9.9.9.9")}
	newChina := &fakeExchanger{reply: makeAMsg(name)}
	newTrust := &fakeExchanger{reply: makeAMsg(name, "8.8.8.8")}

	h := newTestHandler(t, oldChina, oldTrust)
	h.swapUpstreams(&upstreamSnapshot{China: oldChina, Trust: oldTrust})
	h.afterCacheEpoch = func() {
		h.swapUpstreams(&upstreamSnapshot{China: newChina, Trust: newTrust})
		h.afterCacheEpoch = nil
	}

	req := new(dns.Msg)
	req.SetQuestion(name, dns.TypeA)
	resp := h.resolve(context.Background(), req.Question[0], req)
	if got := collectAIPs(resp); len(got) != 1 || got[0] != "8.8.8.8" {
		t.Fatalf("response IPs = %v, want new upstream answer [8.8.8.8]", got)
	}
	if _, ok := h.Cache.Get(name, dns.TypeA); ok {
		t.Fatal("old-epoch write entered the post-swap cache generation")
	}
}

// hookExchanger returns a canned reply after running hook — a seam to inject
// a concurrent event (e.g. a cache flush) mid-resolve.
type hookExchanger struct {
	reply *dns.Msg
	hook  func()
}

func (h *hookExchanger) Exchange(ctx context.Context, _ *dns.Msg) (*dns.Msg, error) {
	if h.hook != nil {
		h.hook()
	}
	return h.reply, nil
}
