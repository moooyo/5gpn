package main

import (
	"fmt"
	"sort"
	"strings"
	"testing"
)

type declaration struct {
	pattern string
	order   int
}

// The scans orderedHostIndex replaced, kept verbatim as the reference the
// indexed matcher is differentially tested against.
//
// This is the arrangement transport_projection.go uses in the sidecar for the
// same reason: the rule these encode decides which extension owns a captured
// host, and therefore which operator-selected egress group its origin
// re-resolution uses. A faster matcher is only worth having if it is provably
// the same matcher, and "provably" here means a reference implementation that
// nothing else calls, so it cannot drift into agreeing by construction.
type referenceWildcard[T any] struct {
	suffix string
	entry  orderedHostEntry[T]
}

type referenceIndex[T any] struct {
	exact    map[string]orderedHostEntry[T]
	wildcard []referenceWildcard[T]
	next     int
}

func newReferenceIndex[T any]() *referenceIndex[T] {
	return &referenceIndex[T]{exact: make(map[string]orderedHostEntry[T])}
}

func (r *referenceIndex[T]) insert(pattern string, order int, value T) {
	entry := orderedHostEntry[T]{value: value, order: order, rank: r.next}
	r.next++
	if suffix, wildcard := strings.CutPrefix(pattern, "*."); wildcard {
		if suffix == "" {
			return
		}
		for _, existing := range r.wildcard {
			if existing.suffix == suffix {
				return
			}
		}
		r.wildcard = append(r.wildcard, referenceWildcard[T]{suffix: suffix, entry: entry})
		return
	}
	if pattern == "" {
		return
	}
	if _, exists := r.exact[pattern]; !exists {
		r.exact[pattern] = entry
	}
}

// match is the original scan, unchanged except for reading order off the entry.
func (r *referenceIndex[T]) match(name string) (T, bool) {
	var zero T
	name = strings.ToLower(stripDot(name))
	exact, exactMatch := r.exact[name]
	for _, wildcard := range r.wildcard {
		if exactMatch && wildcard.entry.order >= exact.order {
			break
		}
		if len(name) > len(wildcard.suffix)+1 && strings.HasSuffix(name, "."+wildcard.suffix) {
			return wildcard.entry.value, true
		}
	}
	if exactMatch {
		return exact.value, true
	}
	return zero, false
}

// TestOrderedHostIndexMatchesTheScanItReplaced enumerates the shapes the two
// could disagree on: overlapping wildcards at different depths, an exact and a
// wildcard covering the same name from different extensions and from the same
// one, a name that is the wildcard's own apex, and names that match nothing.
func TestOrderedHostIndexMatchesTheScanItReplaced(t *testing.T) {
	t.Parallel()
	catalogues := map[string][]declaration{
		"exact and wildcard in one extension": {
			{"api.example.com", 0}, {"*.example.com", 0},
		},
		"exact behind an earlier wildcard": {
			{"*.example.com", 0}, {"api.example.com", 1},
		},
		"wildcard behind an earlier exact": {
			{"api.example.com", 0}, {"*.example.com", 1},
		},
		"nested wildcards, outer declared first": {
			{"*.example.com", 0}, {"*.cdn.example.com", 0},
		},
		"nested wildcards, inner declared first": {
			{"*.cdn.example.com", 0}, {"*.example.com", 0},
		},
		"nested wildcards across extensions": {
			{"*.cdn.example.com", 1}, {"*.example.com", 0},
		},
		"nested wildcards across extensions, specific first": {
			{"*.cdn.example.com", 0}, {"*.example.com", 1},
		},
		"three deep": {
			{"*.a.b.example.com", 2}, {"*.b.example.com", 1}, {"*.example.com", 0},
			{"x.a.b.example.com", 3},
		},
		"duplicate declarations keep the first": {
			{"*.example.com", 0}, {"*.example.com", 1}, {"api.example.com", 0}, {"api.example.com", 1},
		},
		"apex only": {
			{"example.com", 0},
		},
		"wildcard only": {
			{"*.example.com", 0},
		},
	}
	names := []string{
		"example.com", "api.example.com", "x.api.example.com", "cdn.example.com",
		"a.cdn.example.com", "b.a.cdn.example.com", "x.a.b.example.com",
		"a.b.example.com", "b.example.com", "other.test", "com", "", "EXAMPLE.COM.",
		"API.Example.Com", "deep.x.a.b.example.com",
	}

	for catalogue, declarations := range catalogues {
		catalogue, declarations := catalogue, declarations
		t.Run(catalogue, func(t *testing.T) {
			t.Parallel()
			// Insert in non-decreasing order, which is the invariant
			// newInterceptHostSnapshot provides by walking modules in execution
			// order, and the one under which the scan's "first slice position"
			// and the index's "lowest order, then earliest declaration" are the
			// same answer. A catalogue is written in declaration order within
			// each extension; sorting stably by order arranges the extensions.
			sorted := append([]declaration(nil), declarations...)
			sort.SliceStable(sorted, func(a, b int) bool { return sorted[a].order < sorted[b].order })
			indexed := newOrderedHostIndex[string]()
			reference := newReferenceIndex[string]()
			for _, declared := range sorted {
				value := fmt.Sprintf("%s@%d", declared.pattern, declared.order)
				indexed.insert(declared.pattern, declared.order, value)
				reference.insert(declared.pattern, declared.order, value)
			}
			for _, name := range names {
				wantValue, wantOK := reference.match(name)
				gotValue, gotOK := indexed.match(name)
				if gotOK != wantOK || gotValue != wantValue {
					t.Fatalf("match(%q) = (%q, %t), the scan says (%q, %t)", name, gotValue, gotOK, wantValue, wantOK)
				}
			}
		})
	}
}

// The invariant the equivalence rests on: the builder never declares a
// lower-order pattern after a higher-order one.
func TestInterceptHostSnapshotInsertsInNonDecreasingOrder(t *testing.T) {
	t.Parallel()
	first := testModuleSnapshot()
	first.ID = "io.example.first"
	first.Enabled = true
	first.CaptureHosts = []string{"*.first.example.com", "api.first.example.com"}
	first.Scripts[0].Match.Hosts = []string{"api.first.example.com"}
	second := testModuleSnapshot()
	second.ID = "io.example.second"
	second.Enabled = true
	second.CaptureHosts = []string{"*.second.example.com"}
	second.Scripts[0].Match.Hosts = []string{"*.second.example.com"}
	document, _ := testInterceptDocument(t, first, second)
	snapshot := newInterceptHostSnapshot(document)

	byRank := map[int]int{}
	snapshotEntries := func(index *orderedHostIndex[interceptHostBinding]) {
		for _, entry := range index.exact {
			byRank[entry.rank] = entry.order
		}
		for _, entry := range index.wildcard {
			byRank[entry.rank] = entry.order
		}
	}
	snapshotEntries(snapshot.capture)
	previous := -1
	for rank := 0; rank < snapshot.capture.next; rank++ {
		order, present := byRank[rank]
		if !present {
			continue
		}
		if order < previous {
			t.Fatalf("rank %d declared order %d after %d; the index is only equivalent to the scan under non-decreasing insertion", rank, order, previous)
		}
		previous = order
	}
}

// The two properties the rewrite must not quietly change, stated directly
// rather than only through the reference.
func TestOrderedHostIndexKeepsExecutionOrderOwnership(t *testing.T) {
	t.Parallel()
	t.Run("an earlier extension's broad wildcard beats a later specific one", func(t *testing.T) {
		index := newOrderedHostIndex[string]()
		index.insert("*.example.com", 0, "first")
		index.insert("*.cdn.example.com", 1, "second")
		// Most-specific-suffix matching would answer "second". The rule is
		// first-in-execution-order, and it decides egress ownership.
		if got, ok := index.match("a.cdn.example.com"); !ok || got != "first" {
			t.Fatalf("match = %q %t, want first: execution order owns the binding, not specificity", got, ok)
		}
	})
	t.Run("an exact match beats a wildcard of equal order", func(t *testing.T) {
		index := newOrderedHostIndex[string]()
		index.insert("*.example.com", 0, "wildcard")
		index.insert("api.example.com", 0, "exact")
		if got, ok := index.match("api.example.com"); !ok || got != "exact" {
			t.Fatalf("match = %q %t, want exact", got, ok)
		}
	})
	t.Run("a wildcard does not cover its own apex", func(t *testing.T) {
		index := newOrderedHostIndex[string]()
		index.insert("*.example.com", 0, "wildcard")
		if got, ok := index.match("example.com"); ok {
			t.Fatalf("match = %q %t, want no match: *.example.com covers subdomains only", got, ok)
		}
	})
}

func BenchmarkInterceptCaptureLookupMiss(b *testing.B) {
	document := interceptConfigDocument{MITM: interceptMITMSettings{Enabled: true}}
	module := interceptModuleSnapshot{ID: "io.example.bench", Enabled: true}
	for index := 0; index < 256; index++ {
		module.CaptureHosts = append(module.CaptureHosts,
			fmt.Sprintf("host%03d.example.com", index),
			fmt.Sprintf("*.cdn%03d.example.com", index))
	}
	document.Modules = []interceptModuleSnapshot{module}
	document.ExecutionOrder = []string{module.ID}
	snapshot := newInterceptHostSnapshot(document)

	reference := newReferenceIndex[interceptHostBinding]()
	for _, pattern := range module.CaptureHosts {
		reference.insert(pattern, 0, interceptHostBinding{pattern: pattern})
	}

	// A random-subdomain flood is entirely names that match nothing, which is
	// the case the scan walked the whole table for.
	const miss = "a3f9c2.unmatched.example.net"

	b.Run("indexed", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			if _, ok := snapshot.lookup(miss); ok {
				b.Fatal("fixture matched")
			}
		}
	})
	b.Run("scan", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			if _, ok := reference.match(miss); ok {
				b.Fatal("fixture matched")
			}
		}
	})
}
