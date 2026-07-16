package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// DomainSet matches a query name against the policy match kinds. exact and
// suffix hold normalized FQDNs; keyword holds lowercased substrings.
type DomainSet struct {
	exact   map[string]struct{}
	suffix  map[string]struct{}
	keyword []string
}

// LoadDomainSet loads subscription cache files as domain-suffix entries.
func LoadDomainSet(paths ...string) (*DomainSet, error) {
	ds := &DomainSet{
		exact:  make(map[string]struct{}),
		suffix: make(map[string]struct{}),
	}
	for _, path := range paths {
		if err := ds.loadSuffixFile(path); err != nil {
			return nil, err
		}
	}
	return ds, nil
}

// loadSuffixFile loads one subscription cache. Missing files are empty so a
// policy can be prepared before its first successful fetch.
func (d *DomainSet) loadSuffixFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
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
		line = strings.ToLower(strings.TrimRight(line, "."))
		if line != "" {
			d.suffix[line] = struct{}{}
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("domainset: scan %s: %w", path, err)
	}
	return nil
}

// Match reports whether name matches any exact, suffix, or keyword entry.
func (d *DomainSet) Match(name string) bool {
	if d == nil {
		return false
	}
	name = strings.ToLower(strings.TrimRight(name, "."))
	if name == "" {
		return false
	}

	if len(d.exact) > 0 {
		if _, ok := d.exact[name]; ok {
			return true
		}
	}

	if len(d.suffix) > 0 {
		cur := name
		for {
			if _, ok := d.suffix[cur]; ok {
				return true
			}
			dot := strings.IndexByte(cur, '.')
			if dot < 0 {
				break
			}
			cur = cur[dot+1:]
			if cur == "" {
				break
			}
		}
	}

	for _, kw := range d.keyword {
		if strings.Contains(name, kw) {
			return true
		}
	}
	return false
}

// Len returns the total number of entries across all match types.
func (d *DomainSet) Len() int {
	if d == nil {
		return 0
	}
	return len(d.exact) + len(d.suffix) + len(d.keyword)
}
