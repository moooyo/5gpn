package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
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
		stats:     &statsCounters{},
	}

	// Restore cumulative query-stat counters from a previous run, if any.
	// A missing file (fresh install / first boot) is normal and silent; only
	// a corrupt file is logged, and in that case counters simply start at
	// zero rather than crashing the resolver.
	if err := LoadStats(cfg.StatsFile, h.stats); err != nil {
		log.Printf("stats: %v — starting with zero counters", err)
	}

	// reload rebuilds the rule sets from disk and atomically swaps them into
	// the live Handler. Shared by the SIGHUP handler, the SubManager (fires
	// after a subscription cache file changes), and the Controller (fires
	// after a manual rule-list edit).
	reload := func() error {
		newSets, err := loadRuleSets(cfg)
		if err != nil {
			return err
		}
		// Atomic swap: in-flight queries holding the old Handler fields finish safely.
		h.swapRuleSets(newSets.adblock, newSets.direct, newSets.blacklist, newSets.chnroute)
		return nil
	}

	// ── SIGHUP: hot-reload rule sets + chnroute ───────────────────────────────
	sighupCh := make(chan os.Signal, 1)
	signal.Notify(sighupCh, syscall.SIGHUP)
	go func() {
		for range sighupCh {
			log.Println("SIGHUP: reloading rule sets and chnroute")
			if err := reload(); err != nil {
				log.Printf("SIGHUP reload failed: %v", err)
				continue
			}
			log.Println("SIGHUP: reload complete")
		}
	}()

	// ── Phase 2: subscription manager + controller ────────────────────────────
	// A missing subscriptions.json is not an error (NewSubManager/LoadSubscriptions
	// returns an empty manager); a malformed one is logged and skipped so a bad
	// subscriptions.json can never crash the resolver.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	subMgr, err := NewSubManager(cfg.SubscriptionsFile, cfg.RulesDir, reload)
	if err != nil {
		log.Printf("subscriptions: %v — continuing without subscription manager", err)
		subMgr = nil
	}
	// ctrl is the facade the Phase 3 HTTP control-plane API consumes.
	ctrl := NewController(subMgr, reload, cfg.RulesDir, h.stats, h.Cache.Len, h)

	if subMgr != nil {
		go subMgr.Run(ctx)
	}

	// Phase 4 Task A2: periodically persist stats + do a final save on shutdown
	// (triggered by ctx being cancelled below). Best-effort — RunStatsPersister
	// never crashes the resolver on a save failure. Tracked by persistWG so the
	// shutdown path waits for the final save to complete before the process
	// exits (rather than racing it).
	var persistWG sync.WaitGroup
	persistWG.Add(1)
	go func() {
		defer persistWG.Done()
		RunStatsPersister(ctx, cfg.StatsFile, h.stats, 60*time.Second)
	}()

	// ── Phase 3: control-plane HTTPS API (:9443, bearer-token) ────────────────
	// NewControlServer returns (nil, nil) when DNS_API_TOKEN is empty: the
	// control plane is disabled rather than served without authentication.
	controlSrv, err := NewControlServer(cfg, ctrl)
	if err != nil {
		log.Fatalf("control server: %v", err)
	}
	if controlSrv != nil {
		if err := controlSrv.Start(); err != nil {
			log.Fatalf("control server start: %v", err)
		}
	}

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
	if controlSrv != nil {
		log.Printf("control API listening on %s (bearer-token)", cfg.ListenAPI)
	} else {
		log.Printf("control API disabled: DNS_API_TOKEN not set")
	}

	// ── Block until SIGINT / SIGTERM ──────────────────────────────────────────
	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, syscall.SIGINT, syscall.SIGTERM)
	<-stopCh

	log.Println("shutting down...")
	cancel() // stop the subscription manager's ticker loops
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	if controlSrv != nil {
		controlSrv.Shutdown(shutdownCtx)
	}
	servers.Shutdown(shutdownCtx)
	persistWG.Wait() // ensure the stats persister's final save completes before exit
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
		cr, err = LoadChnrouteFiles(append([]string{cfg.ChnrouteFile}, globChnrouteDir(rulesDir)...)...)
		if err != nil {
			if errors.Is(err, ErrEmptyChnroute) {
				// Fail-safe, not fail-fast: an empty chnroute means every IP looks
				// foreign (routed via proxy), which is safe — and self-heals once
				// the subscription manager's in-process fetch lands. The
				// alternative (log.Fatalf) would crash-loop forever on a fresh
				// install where nothing has seeded chnroute yet.
				log.Printf("warning: %v — starting with empty chnroute (all IPs treated as foreign) until a subscription fetch or manual file populates it", err)
				cr = &Chnroute{}
			} else {
				return nil, fmt.Errorf("chnroute: %w", err)
			}
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

// globChnrouteDir returns the subscription-cache .txt files under
// rulesDir/chnroute/*.txt (e.g. downloaded chnroute subscription caches).
// Missing directory or no matches yields nil; glob errors are ignored since
// the only possible error is a malformed pattern, which is static here.
func globChnrouteDir(rulesDir string) []string {
	matches, _ := filepath.Glob(filepath.Join(rulesDir, "chnroute", "*.txt"))
	return matches
}

// orDisabled returns addr or "(disabled)" for display.
func orDisabled(addr string) string {
	if addr == "" {
		return "(disabled)"
	}
	return addr
}
