package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/miekg/dns"
)

func main() {
	// --version: print the build version and exit BEFORE loading config,
	// so the release binary can be inspected without dns.env/cert (install.sh uses
	// it to detect version skew on re-install). No flag package — a single bare
	// flag doesn't warrant it.
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Println(version)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "--print-mihomo-secret" {
		os.Exit(runMihomoSecretPrint(os.Args[2:], os.Stdout, os.Stderr))
	}

	// --seed-defaults: write the default policy.json, then exit. install.sh
	// runs this once at install time (before start_services) so the daemon's
	// first boot compile sees the seeded model rather than an empty one.
	// Idempotent (validate-if-present); no dns.env/cert is needed, so it runs
	// before LoadConfig like --version. It gets its own FlagSet because
	// the paths/URLs this takes.
	if len(os.Args) > 1 && os.Args[1] == "--seed-defaults" {
		fs := flag.NewFlagSet("seed-defaults", flag.ExitOnError)
		policyOut := fs.String("policy-out", "/etc/5gpn/policy.json", "policy.json output path")
		subscriptions := fs.String("subscriptions", "/etc/5gpn/subscriptions.json", "subscriptions.json validation path")
		bypass := fs.String("bypass", "", "bundled DoH/DoT/HTTPDNS bypass domain list (domain-suffix block)")
		keyword := fs.String("keyword", "", "bundled bypass keyword list (domain-keyword block)")
		proxyDomains := fs.String("proxy-domains", "", "bundled forced-proxy domain list (domain-suffix proxy)")
		chinaList := fs.String("china-list-url", defaultChinaListURL, "dnsmasq-china-list subscription URL")
		gfw := fs.String("gfw-url", defaultGFWURL, "gfw subscription URL")
		_ = fs.Parse(os.Args[2:])
		in := seedInputs{
			BypassPath: *bypass, KeywordPath: *keyword, ProxyPath: *proxyDomains,
			ChinaListURL: *chinaList, GFWURL: *gfw,
		}
		if err := seedDefaults(*policyOut, in); err != nil {
			log.Fatalf("seed-defaults: %v", err)
		}
		if _, err := LoadSubscriptions(*subscriptions); err != nil {
			log.Fatalf("seed-defaults: %v", err)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "--check-interception-routing" {
		os.Exit(runInterceptionRoutingCheck(os.Args[2:], os.Stdout, os.Stderr))
	}
	if len(os.Args) > 1 {
		log.Fatalf("unknown command %q", os.Args[1])
	}

	cfg, err := LoadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// Runtime upstream override (web-console managed): when upstreams.json
	// exists and is valid, its lists override DNS_CHINA/DNS_TRUST. A malformed
	// file is logged and ignored — never a reason to crash the sole resolver.
	if uc, err := LoadUpstreams(cfg.UpstreamsFile); err != nil {
		log.Printf("warning: %v — using dns.env upstreams", err)
	} else if uc != nil {
		cfg.ChinaAddrs = uc.China
		cfg.TrustRaw = uc.Trust
		cfg.TrustEntries = parseTrustEntryList(uc.Trust)
		log.Printf("upstreams: %s overrides dns.env (china=%v trust=%v)", cfg.UpstreamsFile, uc.China, uc.Trust)
	}

	applyTGBotOverride(&cfg)

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

	china := NewUDPGroup(cfg.ChinaAddrs, cfg.China0x20)
	trust := NewTrustGroup(cfg.TrustEntries)

	// China-group EDNS Client Subnet: the web-console override file (written
	// by PUT /api/ecs) wins over dns.env's DNS_CHINA_ECS at startup. A
	// malformed override file is logged and ignored (dns.env value applies) —
	// never a reason to crash the sole resolver.
	chinaECS := cfg.ChinaECS
	if fc, err := LoadECSFile(cfg.EcsFile); err != nil {
		log.Printf("ecs: %v — using DNS_CHINA_ECS", err)
	} else if fc != nil {
		chinaECS, _ = parseECS(fc.Subnet) // subnet already validated by LoadECSFile
	}
	SetGroupECS(china, chinaECS)
	if chinaECS != nil {
		log.Printf("china ECS: %s (CN CDN answers scheduled near the clients' subnet)", chinaECS)
	} else {
		log.Printf("china ECS disabled")
	}

	gatewayIP := cfg.GatewayIP
	if gatewayIP == nil {
		// Degrade, don't blackhole: without a gateway to steer to, keep foreign A
		// records as-is (plain split-aware resolution) and NXDOMAIN explicit
		// proxy-intent names,
		// rather than fabricating an unroutable 0.0.0.0 for every non-CN name — a
		// silent, total, hard-to-diagnose outage of all foreign destinations. The
		// old code called this a "no-op" but it substituted 0.0.0.0 instead.
		log.Printf("warning: DNS_GATEWAY_IP not set — foreign IPs will NOT be steered to the gateway; the resolver degrades to plain split-aware (foreign A returned as-is, force-proxy returns NXDOMAIN)")
	}

	h := &Handler{
		CN:        sets.chnroute,
		Cache:     cache,
		China:     china,
		Trust:     trust,
		GatewayIP: gatewayIP,
		// Mihomo panel domains: answered locally with GatewayIP (no public A
		// record) so the admin's browser reaches the gateway's SNI split.
		ConsoleDomain: cfg.ConsoleDomain,
		ZashDomain:    cfg.ZashDomain,
		TTLMin:        cfg.TTLMin,
		TTLMax:        cfg.TTLMax,
		Timeout:       cfg.QueryTimeout,
		stats:         &statsCounters{},
	}
	// Admission control: cap concurrent in-flight resolutions so an overload
	// sheds with REFUSED rather than growing goroutines/sockets without bound.
	// DNS_MAX_INFLIGHT=0 leaves h.sem nil (disabled).
	if cfg.MaxInflight > 0 {
		h.sem = make(chan struct{}, cfg.MaxInflight)
	}
	// Publish the initial rule sets into the atomic snapshot immediately, so the
	// Publish chnroute before serving so every query reads an atomic snapshot.
	h.swapRuleSets(sets.chnroute)

	// Publish the initial upstream snapshot for the same reason: the query path
	// (exchangers) and PUT /api/upstreams both go through the atomic pointer.
	h.swapUpstreams(&upstreamSnapshot{
		China:        china,
		Trust:        trust,
		ChinaRaw:     cfg.ChinaAddrs,
		TrustRaw:     cfg.TrustRaw,
		TrustEntries: cfg.TrustEntries,
	})

	// In-memory query log (GET /api/querylog): last 5 minutes of resolved
	// queries for the console's log-search view.
	h.qlog = newQueryLog(queryLogCapacity, queryLogRetention)

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
		h.swapRuleSets(newSets.chnroute)
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

	// ── Subscription manager + controller ────────────────────────────────────
	// A missing subscriptions.json is not an error (NewSubManager/LoadSubscriptions
	// returns an empty manager); a malformed one is logged and skipped so a bad
	// subscriptions.json can never crash the resolver.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// DNS 0x20 self-probe: if enabled (default), verify the china upstreams echo
	// query-name case and auto-disable 0x20 if any normalises it, so the default-on
	// posture can never quietly funnel CN domains through the gateway. Background;
	// never blocks serving.
	StartChina0x20Probe(ctx, china)

	// The subscription fetcher's trust-host resolver delegates to the CURRENT
	// trust group on every call (not the boot-time one), so a hot upstream swap
	// (PUT /api/upstreams) is picked up without re-wiring the manager.
	trustDyn := exchangerFunc(func(ctx context.Context, q *dns.Msg) (*dns.Msg, error) {
		_, t := h.exchangers()
		return t.Exchange(ctx, q)
	})
	trustResolver := trustHostResolver(trustDyn)
	subMgr, err := NewSubManager(cfg.SubscriptionsFile, cfg.RulesDir, reload, trustResolver)
	if err != nil {
		log.Printf("subscriptions: %v — continuing without subscription manager", err)
		subMgr = nil
	}
	// ctrl is shared by the HTTP API and Telegram bot.
	ctrl := NewController(reload, h.stats, h.Cache.Len, h)

	// Upstream hot-swap hook (PUT /api/upstreams): rebuild both groups from the
	// validated specs, swap them into the live engine (flushes the response
	// cache), re-run the 0x20 self-probe against the NEW china members, then
	// persist to upstreams.json so the change survives a restart. A persist
	// failure leaves the swap live and reports it — the operator asked for the
	// change; better applied-but-not-durable than silently ignored.
	ctrl.SetUpstreamsApply(func(chinaList, trustList []string) error {
		entries := parseTrustEntryList(trustList)
		cg := NewUDPGroup(chinaList, cfg.China0x20)
		tg := NewTrustGroup(entries)
		// Carry the live china-group ECS subnet onto the NEW group — an
		// upstream swap must not silently drop an operator-set ECS override.
		oldChina, _ := h.exchangers()
		SetGroupECS(cg, GetGroupECS(oldChina))
		h.swapUpstreams(&upstreamSnapshot{
			China:        cg,
			Trust:        tg,
			ChinaRaw:     chinaList,
			TrustRaw:     trustList,
			TrustEntries: entries,
		})
		StartChina0x20Probe(ctx, cg)
		log.Printf("upstreams: hot-swapped (china=%v trust=%v)", chinaList, trustList)
		if err := SaveUpstreams(cfg.UpstreamsFile, UpstreamsConfig{China: chinaList, Trust: trustList}); err != nil {
			return fmt.Errorf("applied live, but persisting failed (will revert to dns.env on restart): %w", err)
		}
		return nil
	})

	// ECS persistence path for PUT /api/ecs (the live apply goes through the
	// handler's exchangers directly; only the durable write needs wiring).
	ctrl.SetECSFile(cfg.EcsFile)

	// Telegram-bot supervisor: owns the bot's lifecycle so its token + admin set
	// can be hot-reloaded from the web console (PUT /api/tgbot) without restarting
	// the daemon. Wired into the Controller BEFORE the control server starts so a
	// PUT never hits a nil manager; actually launched (Start) further below.
	botSup := newBotSupervisor(ctx, cfg, ctrl)
	ctrl.SetTGBotManager(botSup)

	// The unified policy-rule engine -- policy_rules.go's PolicyRuleManager
	// (the console-managed policy.json store) + policy_compile.go's
	// CompilePolicy (the DNS-only compiler) tied together by
	// policy_engine.go's PolicyEngine, which runs the compiler end-to-end:
	// policy subscriptions and the live ordered DNS snapshot. A policy apply
	// never mutates mihomo. A
	// PolicyRuleManager construction failure (a malformed policy.json) is
	// warn-and-continue, like every other optional store -- the sole
	// resolver must never crash-loop over an operator's bad edit.
	var polEngine *PolicyEngine
	if polMgr, err := NewPolicyRuleManager(cfg.PolicyRulesFile); err != nil {
		log.Printf("warning: policy: %v -- policy rule management disabled", err)
	} else {
		polEngine = NewPolicyEngine(polMgr, subMgr, h, reload, cfg.RulesDir)
		ctrl.SetPolicyEngine(polMgr, polEngine)
		if err := polEngine.PrepareRuntime(); err != nil {
			log.Printf("warning: policy: initial runtime snapshot: %v", err)
		}
		log.Printf("policy: rule engine ready (rules=%s, %d rule(s))", cfg.PolicyRulesFile, len(polMgr.Rules()))
	}
	if h.orderedPolicy.Load() == nil {
		model := PolicyModel{Version: policySchemaVersion, Fallback: Fallback{Policy: FallbackAuto}}
		if err := h.publishPolicyModel(model, cfg.RulesDir); err != nil {
			log.Fatalf("policy: publish default runtime: %v", err)
		}
	}

	// Interception modules share one manager across the Web console and
	// Telegram. Build the verified mihomo client once so raw-config edits and
	// module transactions also share the same on-disk store lock.
	var moduleMihomoStore *MihomoConfigStore
	var moduleMihomoClient *MihomoClient
	if client, clientErr := NewMihomoClient(cfg.MihomoController, cfg.MihomoSecret, cfg.ZashDomain, cfg.ZashCertFile); clientErr != nil {
		log.Printf("warning: interception module hot-apply unavailable: %v", clientErr)
	} else {
		moduleMihomoStore = NewMihomoConfigStore(cfg.MihomoConfigFile)
		moduleMihomoClient = client
	}
	interceptManager := NewInterceptModuleManager(
		NewInterceptConfigStore(cfg.InterceptConfigFile),
		h,
		trustResolver,
		moduleMihomoStore,
		InfraParamsFromConfig(cfg),
		realMihomoTester{},
		moduleMihomoClient,
	)
	interceptManager.SetSidecarTester(realInterceptConfigTester{})
	ctrl.SetInterceptModuleManager(interceptManager)
	marketplaceManager := NewExtensionMarketplaceManager(
		NewExtensionMarketplaceStore(cfg.MarketplacesFile),
		trustResolver,
		interceptManager,
	)
	ctrl.SetExtensionMarketplaceManager(marketplaceManager)
	if err := interceptManager.PrepareRuntime(); err != nil {
		log.Printf("warning: interception modules: %v -- DNS interception overlay remains fail-closed", err)
	}

	// Mihomo always resolves sniffed origins through the loopback egress DNS
	// broker. The broker selects the live China or trust group from the active
	// extension binding and defaults non-extension names to trust; it never
	// applies client DNS policy. A bind or selector-construction failure is fatal
	// because the data plane would otherwise be unable to resolve forwarded SNI.
	pb, pbErr := newDefaultEgressDNSBroker(cfg, h)
	if pbErr != nil {
		log.Fatalf("egress DNS broker: %v", pbErr)
	}
	egressBroker := pb
	if err := egressBroker.Start(); err != nil {
		log.Fatalf("egress DNS broker: %v", err)
	}
	log.Printf("egress DNS broker listening on %s", cfg.EgressBrokerAddr)

	if subMgr != nil {
		go subMgr.Run(ctx)
	}

	// Periodically persist stats and do a final save on shutdown
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

	// ── Control-plane HTTPS API + web console (loopback :443) ────────────────
	// NewControlServer returns (nil, nil) when DNS_API_TOKEN is empty: the
	// control plane is disabled rather than served without authentication.
	controlSrv, err := NewControlServer(cfg, ctrl)
	if err != nil {
		log.Fatalf("control server: %v", err)
	}
	if controlSrv != nil {
		controlSrv.SetGeocodeResolver(trustResolver)
		if moduleMihomoStore != nil && moduleMihomoClient != nil {
			controlSrv.SetMihomoConfig(moduleMihomoStore, InfraParamsFromConfig(cfg), realMihomoTester{}, moduleMihomoClient)
		}
		controlSrv.SetInterceptModuleManager(interceptManager)
		controlSrv.SetExtensionMarketplaceManager(marketplaceManager)
		interceptManager.SetAppliedHook(func() {
			controlSrv.mihomoAppliedAtMu.Lock()
			controlSrv.mihomoAppliedAt = time.Now()
			controlSrv.mihomoAppliedAtMu.Unlock()
		})
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

	// Run the policy engine's first compile+apply in the
	// background, after the DNS/control-plane listeners are already up.
	// CompileAndApply can perform real subscription fetches;
	// it must never delay -- or, offline, indefinitely block -- the sole
	// resolver's startup. Warn-on-error, like every other best-effort
	// boot-time task here (stats restore, cert monitor, heartbeat): an
	// empty/absent policy.json compiles to a valid bootstrap config (MATCH,
	// DIRECT), so this never fails on a fresh install.
	if polEngine != nil {
		go func() {
			if err := polEngine.CompileAndApply(ctx); err != nil {
				log.Printf("warning: policy: initial compile+apply failed: %v", err)
			} else {
				log.Println("policy: initial compile+apply complete")
			}
		}()
	}

	// TLS-cert expiry early-warning: when a cert is configured, periodically log
	// as expiry approaches (error once expired) and surface days-until-expiry via
	// the control-plane /status (and the bot). The scoped renewal timer runs at
	// 03:00 ±6h; this warns if it ever falls behind, before TLS service fails.
	if cfg.CertFile != "" {
		certMon := newCertMonitor(cfg.CertFile, cfg.KeyFile, 14*24*time.Hour)
		ctrl.SetCertStatusFn(certMon.status)
		go certMon.Run(ctx, 6*time.Hour)
	}

	log.Printf("5gpn-dns started (DoT=%s debug=%s)",
		orDisabled(cfg.ListenDoT),
		orDisabled(cfg.ListenDebug),
	)
	if controlSrv != nil {
		log.Printf("control API + web console listening on %s (bearer-token, loopback)", cfg.ListenAPI)
	} else {
		log.Printf("control API disabled: DNS_API_TOKEN not set")
	}

	// ── In-process Telegram control bot (supervised goroutine) ────────────────
	// The bot calls the in-memory Controller directly (no HTTP/token). The
	// supervisor builds it (bot.New does a getMe round-trip to Telegram) and runs
	// the long-poll in a child goroutine, so a slow/unreachable Telegram can never
	// block the daemon's startup or DNS serving. An empty token disables it. The
	// token + admin set are hot-reloadable from the web console via PUT /api/tgbot
	// (botSup.Apply), which restarts just the bot goroutine, not the daemon.
	botSup.Start()
	if cfg.TGBotAlerts {
		go newBotAlertMonitor(ctrl, botSup).Run(ctx)
		log.Printf("telegram transition alerts enabled for configured bot administrators")
	}

	// systemd watchdog keepalive (no-op unless the unit sets WatchdogSec): a
	// fully-wedged process stops pinging and systemd restarts it.
	go RunWatchdog(ctx)

	// Outbound liveness heartbeat / dead-man's switch (no-op unless
	// DNS_HEARTBEAT_URL is set): pings an external monitor so a box-down or
	// crash-loop — which the control plane and the die-with-the-daemon bot
	// cannot report — surfaces as a missed ping.
	go RunHeartbeat(ctx, cfg.HeartbeatURL, cfg.HeartbeatInterval)
	if cfg.HeartbeatURL != "" {
		log.Printf("liveness heartbeat every %s", cfg.HeartbeatInterval)
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
	if egressBroker != nil {
		egressBroker.Shutdown(shutdownCtx)
	}
	persistWG.Wait() // ensure the stats persister's final save completes before exit
	log.Println("shutdown complete")
}

// applyTGBotOverride applies the console-managed runtime bot configuration.
// A present-but-unreadable override fails closed: falling back to an older
// dns.env token/admin set could silently re-authorize an administrator that the
// operator already revoked. A missing override still means "use bootstrap
// dns.env values".
func applyTGBotOverride(cfg *Config) {
	tc, err := LoadTGBot(cfg.TGBotFile)
	if err != nil {
		cfg.TGBotToken = ""
		cfg.TGBotAdmins = map[int64]bool{}
		log.Printf("warning: %v — Telegram bot disabled fail-closed until the override is repaired", err)
		return
	}
	if tc == nil {
		return
	}
	cfg.TGBotToken = tc.Token
	cfg.TGBotAdmins = adminSetFromIDs(tc.Admins)
	state := "token set"
	if tc.Token == "" {
		state = "no token (disabled)"
	}
	log.Printf("tgbot: %s overrides dns.env (%s, %d admin(s))", cfg.TGBotFile, state, len(tc.Admins))
}

// wireMihomoConfigManagement enables the raw mihomo config editor only when the
// daemon can build its own verified-TLS controller client. A broken/old
// controller TLS setup must fail closed for the mihomo integration while the
// DNS resolver and the rest of the control plane keep running.
func wireMihomoConfigManagement(controlSrv *ControlServer, cfg Config, logf func(string, ...any)) {
	if controlSrv == nil {
		return
	}
	mihomoClient, err := NewMihomoClient(
		cfg.MihomoController,
		cfg.MihomoSecret,
		cfg.ZashDomain,
		cfg.ZashCertFile,
	)
	if err != nil {
		if logf != nil {
			logf("warning: mihomo config management unavailable: %v -- DNS continues and /api/mihomo/config stays fail-closed until the controller TLS inputs are fixed", err)
		}
		return
	}
	// Mihomo raw-config editor and explicit reset. Wired only when the verified controller client is
	// available; otherwise the endpoints stay unavailable rather than
	// downgrading or partially working against plaintext HTTP.
	controlSrv.SetMihomoConfig(
		NewMihomoConfigStore(cfg.MihomoConfigFile),
		InfraParamsFromConfig(cfg),
		realMihomoTester{},
		mihomoClient,
	)
}

// ruleSets holds the reloadable rule data.
type ruleSets struct {
	chnroute *Chnroute
}

// loadRuleSets reads all rule files from disk according to cfg.
func loadRuleSets(cfg Config) (*ruleSets, error) {
	rulesDir := cfg.RulesDir

	// chnroute sources, in load order (LoadChnrouteFiles merges all of them):
	//   - cfg.ChnrouteFile          → the DNS_CHNROUTE pin (default china_ip_list.txt), optional
	//   - rulesDir/chnroute/*.txt   → subscription caches (globChnrouteDir)
	// Loading is unconditional: even with DNS_CHNROUTE unset, subscription caches
	// must still populate CN.
	chnFiles := make([]string, 0, 2)
	if cfg.ChnrouteFile != "" {
		chnFiles = append(chnFiles, cfg.ChnrouteFile)
	}
	chnFiles = append(chnFiles, globChnrouteDir(rulesDir)...)

	cr, err := LoadChnrouteFiles(chnFiles...)
	if err != nil {
		if errors.Is(err, ErrEmptyChnroute) {
			// Fail-safe, not fail-fast: an empty chnroute means every IP looks
			// foreign (routed via proxy), which is safe — and self-heals once
			// the subscription manager's in-process fetch lands. The
			// alternative (log.Fatalf) would crash-loop forever on a fresh
			// install where nothing has seeded chnroute yet.
			log.Printf("warning: %v — starting with empty chnroute (all IPs treated as foreign) until a subscription fetch populates it", err)
			cr = &Chnroute{}
		} else {
			return nil, fmt.Errorf("chnroute: %w", err)
		}
	}

	return &ruleSets{
		chnroute: cr,
	}, nil
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
