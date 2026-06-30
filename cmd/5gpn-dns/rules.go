package chnroute

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// DomainSet holds a set of normalized FQDNs used for suffix/parent-domain matching.
// Entries are stored lowercase without trailing dots.
type DomainSet struct {
	entries map[string]struct{}
}

// LoadDomainSet reads one or more domain-list files and merges them into a single
// DomainSet. Each file contains one domain per line; lines starting with '#' and
// blank lines are ignored. Domains are lowercased and have trailing dots trimmed.
//
// A path that does not exist is silently skipped (so optional rule files are fine).
// A path that exists but cannot be read IS returned as an error.
func LoadDomainSet(paths ...string) (*DomainSet, error) {
	ds := &DomainSet{entries: make(map[string]struct{})}
	for _, path := range paths {
		if err := ds.loadFile(path); err != nil {
			return nil, err
		}
	}
	return ds, nil
}

// loadFile loads a single file into the DomainSet. Missing files are skipped.
func (d *DomainSet) loadFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // silently skip missing files
		}
		return fmt.Errorf("domainset: open %s: %w", path, err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Normalize: lowercase + strip trailing dot.
		line = strings.ToLower(strings.TrimRight(line, "."))
		if line == "" {
			continue
		}
		d.entries[line] = struct{}{}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("domainset: scan %s: %w", path, err)
	}
	return nil
}

// Match reports whether name matches any entry in the DomainSet via exact or
// parent-domain (suffix) matching. It walks labels from the full name upward:
//
//	a.b.example.com → checks a.b.example.com, b.example.com, example.com, com
//
// The critical correctness rule: we only check at label boundaries, so
// "notexample.com" will never match "example.com".
func (d *DomainSet) Match(name string) bool {
	if len(d.entries) == 0 {
		return false
	}
	// Normalize the query the same way entries were stored.
	name = strings.ToLower(strings.TrimRight(name, "."))
	if name == "" {
		return false
	}

	// Walk label-by-label from full name up to TLD.
	// We stop before reducing to an empty string so we never do a spurious
	// empty-string lookup.
	for {
		if _, ok := d.entries[name]; ok {
			return true
		}
		// Advance to the next label boundary.
		dot := strings.IndexByte(name, '.')
		if dot < 0 {
			// No more dots: we just checked the TLD (or single-label name); stop.
			break
		}
		name = name[dot+1:]
		if name == "" {
			break
		}
	}
	return false
}

// Len returns the number of entries in the DomainSet.
func (d *DomainSet) Len() int {
	return len(d.entries)
}
