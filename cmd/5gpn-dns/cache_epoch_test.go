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
