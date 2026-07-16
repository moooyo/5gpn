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
	// -version/--version: print the build version and exit BEFORE loading config,
	// so `5gpn-dns -version` works on a box with no dns.env/cert (install.sh uses
	// it to detect version skew on re-install). No flag package — a single bare
	// flag doesn't warrant it.
	if len(os.Args) > 1 && (os.Args[1] == "-version" || os.Args[1] == "--version") {
		fmt.Println(version)
		return
	}

	// --seed-defaults: write the default policy.json, then exit. install.sh
	// runs this once at install time (before start_services) so the daemon's
	// first boot compile sees the seeded model rather than an empty one (an
	// empty policy.json would compile writeManualFiles to empty and wipe the
	// default rule set). Idempotent (skip-if-present); no dns.env/cert
	// needed, so it runs before LoadConfig like -version. It gets its own
	// FlagSet — the bare-arg convention the -version check uses does not scale to
	// the paths/URLs this takes.
	if len(os.Args) > 1 && os.Args[1] == "--seed-defaults" {
		fs := flag.NewFlagSet("seed-defaults", flag.ExitOnError)
		policyOut := fs.String("policy-out", "/etc/5gpn/policy.json", "policy.json output path")
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
		return
	}

	cfg, err := LoadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	// --mihomo-reset: restore the seed default mihomo config and restart
	// mihomo, then exit. A lifeline for a self-inflicted bad edit (via PUT
	// /api/mihomo/config) that left the console/zash panels unreachable
	// (design §4.2) — this CLI path goes straight to disk + systemctl,
	// bypassing the HTTP API and mihomo's live PUT /configs entirely, so it
	// doesn't depend on either the console or a healthy controller. Runs
	// AFTER LoadConfig (unlike --seed-defaults/-version) because it needs
	// cfg.MihomoConfigFile; MihomoConfigStore.Default() itself reads the
	// same process environment LoadConfig just read from, so this only
	// works when dns.env has actually been sourced into the environment
	// (true for both a systemd-invoked run and install.sh's `5gpn
	// mihomo-reset` wrapper).
	if len(os.Args) > 1 && os.Args[1] == "--mihomo-reset" {
		if err := mihomoResetCLI(cfg); err != nil {
			log.Fatalf("mihomo-reset: %v", err)
		}
		return
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
		// records as-is (plain split-aware resolution) and NXDOMAIN the blacklist,
		// rather than fabricating an unroutable 0.0.0.0 for every non-CN name — a
		// silent, total, hard-to-diagnose outage of all foreign destinations. The
		// old code called this a "no-op" but it substituted 0.0.0.0 instead.
		log.Printf("warning: DNS_GATEWAY_IP not set — foreign IPs will NOT be steered to the gateway; the resolver degrades to plain split-aware (foreign A returned as-is, blacklist returns NXDOMAIN)")
	}

	h := &Handler{
		CN:        sets.chnroute,
		Block:     sets.block,
		Direct:    sets.direct,
		Blacklist: sets.blacklist,
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
	// live query path (ruleSnap) reads the atomic from the very first query and
	// never the public fields. Without this the atomic is nil until the first
	// SIGHUP/reload, and that first swapRuleSets would write the public fields
	// concurrently with in-flight queries reading them through ruleSnap's
	// nil-fallback — a data race. Initialising here closes that window.
	h.swapRuleSets(sets.block, sets.direct, sets.blacklist, sets.chnroute)

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
		h.swapRuleSets(newSets.block, newSets.direct, newSets.blacklist, newSets.chnroute)
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
	//
	// UP-1 Task D3: subscriptions.json is no longer a hand-edited operator
	// source of truth (the /api/subscriptions* HTTP surface + Controller CRUD
	// facade that managed it directly are gone) — it is now a policy-compiler-
	// driven DERIVED cache: PolicyEngine.CompileAndApply reconciles subMgr's
	// tracked set to CompiledDNS.Subs on every apply (subMgr.Sync) and at boot,
	// and Sync's Add/Remove/Replace calls persist to this same file as a side
	// effect. policy.json (policy_rules.go) is the actual source of truth.
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
	// ctrl is the facade the Phase 3 HTTP control-plane API consumes.
	ctrl := NewController(subMgr, reload, cfg.RulesDir, h.stats, h.Cache.Len, h)

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
	// DNS category caches, the subscription fetch/sync, and the DNS fallback
	// switch. There is no mihomo side to this anymore (2026-07-15 policy/
	// mihomo decoupling) -- a policy apply never mutates mihomo. A
	// PolicyRuleManager construction failure (a malformed policy.json) is
	// warn-and-continue, like every other optional store -- the sole
	// resolver must never crash-loop over an operator's bad edit.
	var polEngine *PolicyEngine
	if polMgr, err := NewPolicyRuleManager(cfg.PolicyRulesFile); err != nil {
		log.Printf("warning: policy: %v -- policy rule management disabled", err)
	} else {
		// Live from the very first query, even before the boot compile below
		// (which fetches subscriptions and may take a moment, or fail
		// offline) ever runs -- mirrors the pre-policy default (auto).
		h.setFallback(polMgr.GetFallback().Policy)
		polEngine = NewPolicyEngine(polMgr, subMgr, h, reload, cfg.RulesDir)
		ctrl.SetPolicyEngine(polMgr, polEngine)
		if err := polEngine.PrepareRuntime(); err != nil {
			log.Printf("warning: policy: initial runtime snapshot: %v", err)
		}
		log.Printf("policy: rule engine ready (rules=%s, %d rule(s))", cfg.PolicyRulesFile, len(polMgr.Rules()))
	}

	// Mihomo always resolves sniffed origins through the loopback Egress DNS
	// Broker. A bind or resolver-construction failure is fatal because the data
	// plane would otherwise start while unable to resolve any forwarded SNI.
	pb, pbCloser, pbErr := newDefaultEgressDNSBroker(cfg)
	if pbErr != nil {
		log.Fatalf("egress DNS broker: %v", pbErr)
	}
	egressBroker, brokerCloser := pb, pbCloser
	if err := egressBroker.Start(); err != nil {
		log.Fatalf("egress DNS broker: %v", err)
	}
	log.Printf("egress DNS broker listening on %s", cfg.EgressBrokerAddr)

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

	// ── Control-plane HTTPS API + web console (:18443, bearer-token) ──────────
	// NewControlServer returns (nil, nil) when DNS_API_TOKEN is empty: the
	// control plane is disabled rather than served without authentication.
	controlSrv, err := NewControlServer(cfg, ctrl)
	if err != nil {
		log.Fatalf("control server: %v", err)
	}
	if controlSrv != nil {
		wireMihomoConfigManagement(controlSrv, cfg, log.Printf)
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

	// UP-1 Task C4: run the policy engine's first compile+apply in the
	// background, after the DNS/control-plane listeners are already up.
	// CompileAndApply does a real subscription fetch plus a `mihomo -t` exec;
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

	// ── Phase 5: in-process Telegram control bot (supervised goroutine) ───────
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
	if brokerCloser != nil {
		_ = brokerCloser.Close()
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
	// Mihomo raw-config editor (GET/PUT /api/mihomo/config + /default +
	// /reset — design §4.2). Wired only when the verified controller client is
	// available; otherwise the endpoints stay unavailable rather than
	// downgrading or partially working against plaintext HTTP.
	controlSrv.SetMihomoConfig(
		NewMihomoConfigStore(cfg.MihomoConfigFile),
		InfraParamsFromConfig(cfg),
		realMihomoTester{},
		mihomoClient,
	)
}

// mihomoResetCLI implements --mihomo-reset: write the seed default mihomo
// config to cfg.MihomoConfigFile (atomic temp+rename, matching the API
// apply pipeline's write step) and restart mihomo via systemd so it picks up
// the fresh file. Deliberately skips ValidateInvariants/`mihomo -t` — this is
// the LAST-RESORT recovery path when the console itself may be unreachable
// because of a bad edit, and the seed template is trusted by construction
// (it's exactly what a fresh install renders); gating recovery behind the
// same checks it exists to route around would defeat its purpose. It also
// skips the live PUT /configs hot-apply the API uses (no assumption that the
// controller is even reachable) in favor of a real `systemctl restart`,
// mirroring bot_ops.go's restartMihomo.
func mihomoResetCLI(cfg Config) error {
	store := NewMihomoConfigStore(cfg.MihomoConfigFile)
	text := store.Default()
	if err := store.EnsurePrivateDir(); err != nil {
		return fmt.Errorf("secure %s: %w", store.Dir(), err)
	}
	if err := atomicWriteFile(store.Path(), []byte(text), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", store.Path(), err)
	}
	log.Printf("mihomo-reset: wrote seed default to %s", store.Path())

	ok, out := run([]string{"systemctl", "restart", "mihomo"}, 60*time.Second)
	if !ok {
		return fmt.Errorf("systemctl restart mihomo: %s", out)
	}
	log.Printf("mihomo-reset: mihomo restarted")
	return nil
}

// ruleSets holds the reloadable rule data.
type ruleSets struct {
	block     *DomainSet
	direct    *DomainSet
	blacklist *DomainSet
	chnroute  *Chnroute
}

// loadRuleSets reads all rule files from disk according to cfg.
func loadRuleSets(cfg Config) (*ruleSets, error) {
	rulesDir := cfg.RulesDir

	block, err := LoadDomainSetTyped(globPattern(rulesDir, "block")...)
	if err != nil {
		return nil, fmt.Errorf("block: %w", err)
	}
	direct, err := LoadDomainSetTyped(globPattern(rulesDir, "direct")...)
	if err != nil {
		return nil, fmt.Errorf("direct: %w", err)
	}
	blacklist, err := LoadDomainSetTyped(globPattern(rulesDir, "blacklist")...)
	if err != nil {
		return nil, fmt.Errorf("blacklist: %w", err)
	}

	// chnroute sources, in load order (LoadChnrouteFiles merges all of them):
	//   - cfg.ChnrouteFile          → the DNS_CHNROUTE pin (default china_ip_list.txt), optional
	//   - rulesDir/chnroute.txt     → the manual file the :18443 API / bot / web console
	//     write via Controller.manualRulePath("chnroute", …). This MUST be in the load
	//     path or a manual "China route" add is a silent no-op (persisted+listed, never
	//     applied). It was previously omitted — only cfg.ChnrouteFile + chnroute/*.txt loaded.
	//   - rulesDir/chnroute/*.txt   → subscription caches (globChnrouteDir)
	// Loading is unconditional: even with DNS_CHNROUTE unset, subscription caches and
	// the manual file must still populate CN — otherwise every IP looks foreign silently.
	chnFiles := make([]string, 0, 2)
	if cfg.ChnrouteFile != "" {
		chnFiles = append(chnFiles, cfg.ChnrouteFile)
	}
	chnFiles = append(chnFiles, filepath.Join(rulesDir, "chnroute.txt"))
	chnFiles = append(chnFiles, globChnrouteDir(rulesDir)...)

	cr, err := LoadChnrouteFiles(chnFiles...)
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

	return &ruleSets{
		block:     block,
		direct:    direct,
		blacklist: blacklist,
		chnroute:  cr,
	}, nil
}

// globPattern returns the (file, match-type) specs for a domain rule category:
//   - rulesDir/<cat>.txt            → suffix (bare, backward compatible)
//   - rulesDir/<cat>.exact.txt      → exact
//   - rulesDir/<cat>.keyword.txt    → keyword
//   - rulesDir/<cat>.prefix.txt     → prefix
//   - rulesDir/<cat>/*.txt          → suffix (subscription caches)
//
// Explicit per-type filenames (not a <cat>.*.txt glob) so an unrelated file can
// never be silently picked up. Missing paths are tolerated by LoadDomainSetTyped.
func globPattern(rulesDir, category string) []fileSpec {
	specs := []fileSpec{
		{Path: filepath.Join(rulesDir, category+".txt"), Type: MatchSuffix},
		{Path: filepath.Join(rulesDir, category+".exact.txt"), Type: MatchExact},
		{Path: filepath.Join(rulesDir, category+".keyword.txt"), Type: MatchKeyword},
		{Path: filepath.Join(rulesDir, category+".prefix.txt"), Type: MatchPrefix},
	}
	matches, _ := filepath.Glob(filepath.Join(rulesDir, category, "*.txt"))
	for _, m := range matches {
		specs = append(specs, fileSpec{Path: m, Type: MatchSuffix})
	}
	return specs
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
