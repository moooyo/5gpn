package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	cfg, err := LoadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// ── Initial load of rule sets and chnroute ────────────────────────────────
	sets, err := loadRuleSets(cfg)
	if err != nil {
		log.Fatalf("rule sets: %v", err)
	}

	// ── Build Handler ─────────────────────────────────────────────────────────
	var setsPtr atomic.Pointer[ruleSets]
	setsPtr.Store(sets)

	cacheSize := cfg.CacheSize
	if cacheSize <= 0 {
		cacheSize = 4096
	}
	cache := NewCache(cacheSize)

	china := NewUDPGroup(cfg.ChinaAddrs)
	trust := NewDoTGroupFromEntries(cfg.TrustEntries)

	gatewayIP := cfg.GatewayIP
	if gatewayIP == nil {
		log.Printf("warning: DNS_GATEWAY_IP not set — foreign IPs will not be rewritten")
		gatewayIP = net.IPv4(0, 0, 0, 0) // no-op rewrite
	}

	h := &Handler{
		CN:        sets.chnroute,
		Adblock:   sets.adblock,
		Direct:    sets.direct,
		Blacklist: sets.blacklist,
		Cache:     cache,
		China:     china,
		Trust:     trust,
		GatewayIP: gatewayIP,
		TTLMin:    cfg.TTLMin,
		TTLMax:    cfg.TTLMax,
		Timeout:   cfg.QueryTimeout,
	}

	// ── SIGHUP: hot-reload rule sets + chnroute ───────────────────────────────
	sighupCh := make(chan os.Signal, 1)
	signal.Notify(sighupCh, syscall.SIGHUP)
	go func() {
		for range sighupCh {
			log.Println("SIGHUP: reloading rule sets and chnroute")
			newSets, err := loadRuleSets(cfg)
			if err != nil {
				log.Printf("SIGHUP reload failed: %v", err)
				continue
			}
			// Atomic swap: in-flight queries holding the old Handler fields finish safely.
			setsPtr.Store(newSets)
			h.swapRuleSets(newSets.adblock, newSets.direct, newSets.blacklist, newSets.chnroute)
			log.Println("SIGHUP: reload complete")
		}
	}()

	// ── Start servers ─────────────────────────────────────────────────────────
	servers, err := NewServers(cfg, h)
	if err != nil {
		log.Fatalf("servers: %v", err)
	}
	if err := servers.Start(); err != nil {
		log.Fatalf("servers start: %v", err)
	}

	log.Printf("5gpn-dns started (DoT=%s DoH=%s plain=%s debug=%s)",
		orDisabled(cfg.ListenDoT),
		orDisabled(cfg.ListenDoH),
		orDisabled(cfg.ListenPlain),
		orDisabled(cfg.ListenDebug),
	)

	// ── Block until SIGINT / SIGTERM ──────────────────────────────────────────
	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, syscall.SIGINT, syscall.SIGTERM)
	<-stopCh

	log.Println("shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	servers.Shutdown(ctx)
	log.Println("shutdown complete")
}

// ruleSets holds the reloadable rule data.
type ruleSets struct {
	adblock   *DomainSet
	direct    *DomainSet
	blacklist *DomainSet
	chnroute  *Chnroute
}

// loadRuleSets reads all rule files from disk according to cfg.
func loadRuleSets(cfg Config) (*ruleSets, error) {
	rulesDir := cfg.RulesDir

	adblock, err := LoadDomainSet(globPattern(rulesDir, "adblock")...)
	if err != nil {
		return nil, fmt.Errorf("adblock: %w", err)
	}
	direct, err := LoadDomainSet(globPattern(rulesDir, "direct")...)
	if err != nil {
		return nil, fmt.Errorf("direct: %w", err)
	}
	blacklist, err := LoadDomainSet(globPattern(rulesDir, "blacklist")...)
	if err != nil {
		return nil, fmt.Errorf("blacklist: %w", err)
	}

	var cr *Chnroute
	if cfg.ChnrouteFile != "" {
		cr, err = LoadChnroute(cfg.ChnrouteFile)
		if err != nil {
			return nil, fmt.Errorf("chnroute: %w", err)
		}
	}

	return &ruleSets{
		adblock:   adblock,
		direct:    direct,
		blacklist: blacklist,
		chnroute:  cr,
	}, nil
}

// globPattern returns a list of .txt files for the given rule category.
// Checks both the single-file form (rulesDir/category.txt) and the
// directory form (rulesDir/category/*.txt).  Missing paths are silently
// tolerated by LoadDomainSet.
func globPattern(rulesDir, category string) []string {
	var paths []string

	// Single file form: /etc/5gpn/rules/adblock.txt
	single := filepath.Join(rulesDir, category+".txt")
	paths = append(paths, single)

	// Directory glob: /etc/5gpn/rules/adblock/*.txt
	pattern := filepath.Join(rulesDir, category, "*.txt")
	matches, _ := filepath.Glob(pattern)
	paths = append(paths, matches...)

	return paths
}

// orDisabled returns addr or "(disabled)" for display.
func orDisabled(addr string) string {
	if addr == "" {
		return "(disabled)"
	}
	return addr
}
