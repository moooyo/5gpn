// Package main (this file): the install-time default-ruleset seed. Generates
// the default policy.json (the two §7 subscription rules + the bundled
// HTTPDNS/DoH bypass as inline block rules + fallback auto), reusing the
// delivered PolicyModel type so the seeded shape can never drift from what
// the daemon parses. Invoked by `5gpn-dns --seed-defaults` (main.go), which
// install.sh calls once at install time BEFORE the daemon's first boot
// compile. Proxy-intent rules only steer DNS answers to the gateway.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"time"
)

// Default subscription list URLs. The seed command accepts explicit URL flags;
// these constants apply when a flag is omitted.
const (
	defaultChinaListURL = "https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf"
	defaultGFWURL       = "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"
	defaultSeedInterval = 24 * time.Hour
)

// seedInputs are the bundled-file paths + list URLs the seed reads. The three
// paths point at the in-repo etc/*.txt lists (install.sh passes ${SCRIPT_DIR}
// paths); a missing/empty file contributes zero rules (never an error).
type seedInputs struct {
	BypassPath   string // etc/block-dns-bypass.txt        -> domain-suffix block
	KeywordPath  string // etc/block-dns-bypass.keyword.txt -> domain-keyword block
	ProxyPath    string // etc/proxy-domains.txt (empty)      -> domain-suffix proxy
	ChinaListURL string
	GFWURL       string
}

// readSeedList returns the non-blank, non-comment (leading '#') lines of a
// bundled seed file, trimmed + lowercased. A missing file is NOT an error: a
// seed input may legitimately be absent (e.g. proxy-domains.txt) — it yields
// an empty slice.
func readSeedList(path string) ([]string, error) {
	if path == "" {
		return nil, nil
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("seed: read %s: %w", path, err)
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.ToLower(strings.TrimSpace(sc.Text()))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("seed: scan %s: %w", path, err)
	}
	return out, nil
}

// buildDefaultPolicyModel assembles the default policy.json model. Rule order
// (first-match-wins) is deliberate: the explicit inline bypass blocks first
// (an explicit block beats any subscription), then the inline forced-proxy
// defaults, then the two subscriptions in direct -> proxy order (a name that
// would match both the china-direct list and the gfw-proxy list resolves
// direct, matching the historical split-horizon intent).
func buildDefaultPolicyModel(in seedInputs) (PolicyModel, error) {
	var rules []PolicyRule
	add := func(r PolicyRule) {
		r.ID = newPolicyID("prule")
		r.Order = len(rules)
		r.Enabled = true
		rules = append(rules, r)
	}

	bypass, err := readSeedList(in.BypassPath)
	if err != nil {
		return PolicyModel{}, err
	}
	for _, d := range bypass {
		if !isValidRuleDomain(d) {
			log.Printf("seed: skipping invalid bypass domain %q", d)
			continue
		}
		add(PolicyRule{Matcher: Matcher{Kind: KindDomainSuffix, Value: d}, Intent: IntentBlock})
	}

	keywords, err := readSeedList(in.KeywordPath)
	if err != nil {
		return PolicyModel{}, err
	}
	for _, k := range keywords {
		add(PolicyRule{Matcher: Matcher{Kind: KindDomainKeyword, Value: k}, Intent: IntentBlock})
	}

	forced, err := readSeedList(in.ProxyPath)
	if err != nil {
		return PolicyModel{}, err
	}
	for _, d := range forced {
		if !isValidRuleDomain(d) {
			log.Printf("seed: skipping invalid forced-proxy domain %q", d)
			continue
		}
		add(PolicyRule{Matcher: Matcher{Kind: KindDomainSuffix, Value: d}, Intent: IntentProxy})
	}

	add(PolicyRule{Matcher: Matcher{Kind: KindSubscription, Value: in.ChinaListURL, Format: "dnsmasq", Interval: defaultSeedInterval}, Intent: IntentDirect})
	add(PolicyRule{Matcher: Matcher{Kind: KindSubscription, Value: in.GFWURL, Format: "plain", Interval: defaultSeedInterval}, Intent: IntentProxy})

	return PolicyModel{
		Version:  policySchemaVersion,
		Rules:    rules,
		Fallback: Fallback{Policy: FallbackAuto},
	}, nil
}

// seedDefaults seeds policy.json (skip-if-present), idempotent. Called by
// `5gpn-dns --seed-defaults` at install time.
func seedDefaults(policyPath string, in seedInputs) error {
	return seedPolicyFile(policyPath, in)
}

// seedPolicyFile writes the default policy model to path only when path does
// not exist — an operator-edited policy.json is the source of truth and must
// never be clobbered on re-install (mirrors write_subscriptions_json's
// skip-if-present). IDs are therefore minted once and preserved across runs.
func seedPolicyFile(path string, in seedInputs) error {
	if _, err := os.Stat(path); err == nil {
		if _, err := LoadPolicyModel(path); err != nil {
			return fmt.Errorf("seed: existing policy validation: %w", err)
		}
		log.Printf("seed: %s exists and is valid — preserving the operator policy model", path)
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("seed: stat %s: %w", path, err)
	}
	model, err := buildDefaultPolicyModel(in)
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(model, "", "  ")
	if err != nil {
		return fmt.Errorf("seed: marshal policy: %w", err)
	}
	if err := atomicWriteFile(path, append(data, '\n'), 0o644); err != nil {
		return err
	}
	log.Printf("seed: wrote %s (%d rules, fallback=%s)", path, len(model.Rules), model.Fallback.Policy)
	return nil
}
