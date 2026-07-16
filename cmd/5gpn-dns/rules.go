package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// MatchType selects how a DomainSet entry is compared against a query name.
type MatchType int

const (
	MatchSuffix  MatchType = iota // parent-domain / self match at label boundaries (default)
	MatchExact                    // whole-name equality
	MatchKeyword                  // substring anywhere in the FQDN
	MatchPrefix                   // FQDN starts with the entry (raw string)
)

// matchTypeName returns the wire/file name for a MatchType.
func matchTypeName(mt MatchType) string {
	switch mt {
	case MatchExact:
		return "exact"
	case MatchKeyword:
		return "keyword"
	case MatchPrefix:
		return "prefix"
	default:
		return "suffix"
	}
}

// parseMatchType maps a wire/file name to a MatchType. An empty string is the
// default (suffix). ok=false for an unrecognized name.
func parseMatchType(s string) (MatchType, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "suffix":
		return MatchSuffix, true
	case "exact":
		return MatchExact, true
	case "keyword":
		return MatchKeyword, true
	case "prefix":
		return MatchPrefix, true
	default:
		return MatchSuffix, false
	}
}

// DomainSet matches a query name against four kinds of rule entries. exact and
// suffix hold normalized FQDNs (lowercase, no trailing dot); keyword and prefix
// hold raw lowercased substrings.
type DomainSet struct {
	exact   map[string]struct{}
	suffix  map[string]struct{}
	keyword []string
	prefix  []string
}

// fileSpec is one rule file plus the match type its lines carry.
type fileSpec struct {
	Path string
	Type MatchType
}

// LoadDomainSet loads one or more files, all as MatchSuffix (back-compat).
func LoadDomainSet(paths ...string) (*DomainSet, error) {
	specs := make([]fileSpec, 0, len(paths))
	for _, p := range paths {
		specs = append(specs, fileSpec{Path: p, Type: MatchSuffix})
	}
	return LoadDomainSetTyped(specs...)
}

// LoadDomainSetTyped merges the given (path, type) specs into one DomainSet.
// A missing file is silently skipped; a present-but-unreadable file errors.
func LoadDomainSetTyped(specs ...fileSpec) (*DomainSet, error) {
	ds := &DomainSet{
		exact:  make(map[string]struct{}),
		suffix: make(map[string]struct{}),
	}
	seenKW := make(map[string]struct{})
	seenPfx := make(map[string]struct{})
	for _, s := range specs {
		if err := ds.loadFile(s.Path, s.Type, seenKW, seenPfx); err != nil {
			return nil, err
		}
	}
	return ds, nil
}

// loadFile loads one file's lines into the structure selected by mt. Missing
// files are skipped. seenKW/seenPfx dedupe keyword/prefix slices across files.
func (d *DomainSet) loadFile(path string, mt MatchType, seenKW, seenPfx map[string]struct{}) error {
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
		switch mt {
		case MatchKeyword:
			line = strings.ToLower(line)
			if _, ok := seenKW[line]; !ok {
				seenKW[line] = struct{}{}
				d.keyword = append(d.keyword, line)
			}
		case MatchPrefix:
			line = strings.ToLower(line)
			if _, ok := seenPfx[line]; !ok {
				seenPfx[line] = struct{}{}
				d.prefix = append(d.prefix, line)
			}
		case MatchExact:
			line = strings.ToLower(strings.TrimRight(line, "."))
			if line != "" {
				d.exact[line] = struct{}{}
			}
		default: // MatchSuffix
			line = strings.ToLower(strings.TrimRight(line, "."))
			if line != "" {
				d.suffix[line] = struct{}{}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("domainset: scan %s: %w", path, err)
	}
	return nil
}

// Match reports whether name matches any entry, checking exact, then suffix
// (label-bounded parent-domain walk), then keyword substrings, then prefixes.
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
	for _, p := range d.prefix {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// Len returns the total number of entries across all four match types.
func (d *DomainSet) Len() int {
	if d == nil {
		return 0
	}
	return len(d.exact) + len(d.suffix) + len(d.keyword) + len(d.prefix)
}
