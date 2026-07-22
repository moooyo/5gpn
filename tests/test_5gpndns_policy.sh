#!/usr/bin/env bash
# Policy assertions for the 5gpn-dns installer rollout (Task 8).
# Pure grep — runs on the dev box under Git Bash, no Linux/Python needed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
RENEW="$ROOT/scripts/renew-hook.sh"
DNS_SVC="$ROOT/etc/systemd/5gpn-dns.service"
RELOAD_RULES="$ROOT/scripts/reload-rules.sh"
BOT="$ROOT/cmd/5gpn-dns/bot.go"

# --- install.sh: install_5gpndns function present ---
grep -Fq 'install_5gpndns'                  "$INSTALL" || fail "install.sh: no install_5gpndns function"
grep -Fq '5gpn-dns-linux-amd64'             "$INSTALL" || fail "install.sh: does not download 5gpn-dns-linux-amd64"
grep -Fq 'moooyo/5gpn'                      "$INSTALL" || fail "install.sh: release URL not from moooyo/5gpn"
grep -Fq 'DNS_VERSION'                      "$INSTALL" || fail "install.sh: no DNS_VERSION var"
grep -Fq 'release_checksum "$ARTIFACT_STAGE/checksums.txt" "$dns_asset"' "$INSTALL" \
    || fail "install.sh: 5gpn-dns does not use mandatory release checksum"

# --- etc/systemd/5gpn-dns.service: must exist with required directives ---
[ -f "$DNS_SVC" ] || fail "etc/systemd/5gpn-dns.service does not exist"
grep -Fq 'EnvironmentFile=/etc/5gpn/dns.env' "$DNS_SVC" || fail "5gpn-dns.service: no EnvironmentFile=/etc/5gpn/dns.env"
grep -Fq 'ExecStart=/opt/5gpn/bin/5gpn-dns' "$DNS_SVC" || fail "5gpn-dns.service: binary is not project-private"
grep -Fq 'ExecReload=/bin/kill -HUP $MAINPID' "$DNS_SVC" || fail "5gpn-dns.service: no ExecReload=HUP"
grep -Fq 'NoNewPrivileges=yes'               "$DNS_SVC" || fail "5gpn-dns.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict'              "$DNS_SVC" || fail "5gpn-dns.service: no ProtectSystem=strict"
grep -Fq 'RestrictAddressFamilies=AF_INET AF_UNIX' "$DNS_SVC" || fail "5gpn-dns.service: RestrictAddressFamilies not AF_INET AF_UNIX"

# --- install.sh: writes /etc/5gpn/dns.env and uses DNS_* vars ---
grep -Fq '/etc/5gpn/dns.env'    "$INSTALL" || fail "install.sh: does not write /etc/5gpn/dns.env"
grep -Fq 'DNS_GATEWAY_IP'       "$INSTALL" || fail "install.sh: no DNS_GATEWAY_IP in dns.env"
grep -Fq 'DNS_CHINA'            "$INSTALL" || fail "install.sh: no DNS_CHINA in dns.env"
grep -Fq 'DNS_TRUST'            "$INSTALL" || fail "install.sh: no DNS_TRUST in dns.env"
grep -Fq 'DNS_RULES_DIR'        "$INSTALL" || fail "install.sh: no DNS_RULES_DIR in dns.env"
grep -Fq 'DNS_CERT'             "$INSTALL" || fail "install.sh: no DNS_CERT in dns.env"
grep -Fq 'DNS_KEY'              "$INSTALL" || fail "install.sh: no DNS_KEY in dns.env"

# --- renewal publishes cert files; SIGHUP remains rules/chnroute-only ---
grep -Fq '/etc/5gpn/cert'             "$RENEW" || fail "renew-hook.sh: certs not copied to /etc/5gpn/cert"
grep -Eq 'systemctl reload 5gpn-dns|kill -HUP' "$RENEW" \
    && fail "renew-hook.sh: certificate publication must not misuse the rules-only SIGHUP API"
grep -Fq '/etc/5gpn/cert'             "$INSTALL" || fail "install.sh: does not copy certs to /etc/5gpn/cert"

# --- no smartdns implementation in install.sh ---
grep -Eq '^\s*install_smartdns\b'            "$INSTALL" \
    && fail "install.sh: still calls install_smartdns (not just disabled/removed)"
grep -Eq '^\s*install_smartdns_unit\b'       "$INSTALL" \
    && fail "install.sh: still calls install_smartdns_unit"
grep -Eq '^\s*(render_smartdns_conf|gen_foreign_cidr)' "$INSTALL" \
    && fail "install.sh: still references render_smartdns_conf/gen_foreign_cidr as a call"

# --- start_services / show_status: 5gpn-dns replaces smartdns ---
grep -Eq '"5gpn-dns"' "$INSTALL" || fail "install.sh: 5gpn-dns not in service list (start_services/show_status)"

# --- DoT-only ingress (2026-07-10): no DoH/plain-53 listeners, no host firewall ---
[ -e "$ROOT/scripts/setup-firewall.sh" ] && fail "scripts/setup-firewall.sh must stay removed (no host firewall management)"
grep -Eq '^DNS_LISTEN_DOH='   "$INSTALL" && fail "install.sh: dns.env must not emit DNS_LISTEN_DOH (DoH removed)"
grep -Eq '^DNS_LISTEN_PLAIN=' "$INSTALL" && fail "install.sh: dns.env must not emit DNS_LISTEN_PLAIN (plain :53 removed)"
grep -Fq 'DNS_LISTEN_DOT=:853' "$INSTALL" || fail "install.sh: dns.env must pin the DoT listener :853"
grep -Fq 'install_units'       "$INSTALL" || fail "install.sh: no install_units (unit install moved out of the removed setup-firewall.sh)"
grep -Eq '(^|[[:space:]])nft([[:space:]]|$)' "$INSTALL" && fail "install.sh: must not manage host nftables"

# --- reload-rules.sh performs a local SIGHUP and never claims to fetch. ---
grep -Fq 'systemctl reload 5gpn-dns' "$RELOAD_RULES" || fail "reload-rules.sh: does not reload 5gpn-dns"
grep -Eq 'curl|wget|CHINA_IP_URL' "$RELOAD_RULES" \
    && fail "reload-rules.sh: must not fetch remote lists"
grep -Fq -- 'reload-rules)' "$INSTALL" || fail "install.sh: current reload-rules command is not dispatched"
reload_fn="$(sed -n '/^reload_rules()/,/^}/p' "$INSTALL")"
printf '%s' "$reload_fn" | grep -Fq 'bash "$script" ||' \
    || fail "install.sh: reload_rules does not propagate helper failure"
reload_stub="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$reload_stub/systemctl"
chmod +x "$reload_stub/systemctl"
if PATH="$reload_stub:$PATH" bash "$RELOAD_RULES" >/dev/null 2>&1; then
    fail "reload-rules.sh reports success after systemctl reload failure"
fi
rm -rf "$reload_stub"

# --- UP-1 Task D5: unified policy-rule model is the console-facing surface.
# config.go carries the policy-rule store knobs, and api.go mounts the new
# /api/policy/* CRUD+reorder+fallback+apply surface. The former managed-DNS-
# subscription (/api/subscriptions*), manual per-category rules
# (/api/rules/{cat}), manual refresh (/api/update), and egress rule-provider
# endpoints (/api/egress/split-rules, /api/egress/rule-subs) were ABSORBED by
# it (D2/D3) -- a route REGISTRATION for any of them reappearing (not just an
# explanatory comment referencing the old path) must fail this test. ---
POLICY_RULES_CFG="$ROOT/cmd/5gpn-dns/config.go"
POLICY_RULES_API="$ROOT/cmd/5gpn-dns/api.go"
grep -Fq 'DNS_POLICY_RULES'        "$POLICY_RULES_CFG" || fail "config.go: no DNS_POLICY_RULES env var"
# UP-4 (2026-07-15 policy/mihomo decoupling): the mihomo-side rule-provider
# projection this dir backed is gone (policy_compile.go is DNS-only now), so
# the DNS_POLICY_PROVIDER_DIR knob + PolicyProviderDir field were removed --
# a reintroduction would be a regression, not a fix.
grep -Fq 'DNS_POLICY_PROVIDER_DIR' "$POLICY_RULES_CFG" && fail "config.go: DNS_POLICY_PROVIDER_DIR must stay removed (no mihomo-side rule-provider projection anymore)"
grep -Fq 'HandleFunc("GET /api/policy/rules"'          "$POLICY_RULES_API" || fail "api.go: does not mount GET /api/policy/rules"
grep -Fq 'HandleFunc("PUT /api/policy/rules/reorder"'  "$POLICY_RULES_API" || fail "api.go: does not mount PUT /api/policy/rules/reorder"
grep -Fq 'HandleFunc("GET /api/policy/fallback"'       "$POLICY_RULES_API" || fail "api.go: does not mount GET /api/policy/fallback"
grep -Fq 'HandleFunc("POST /api/policy/apply"'         "$POLICY_RULES_API" || fail "api.go: does not mount POST /api/policy/apply"
grep -Eq 'HandleFunc\("[A-Z]+ /api/subscriptions'       "$POLICY_RULES_API" \
    && fail "api.go: /api/subscriptions must stay removed (absorbed by /api/policy/rules)"
grep -Eq 'HandleFunc\("[A-Z]+ /api/rules/\{cat\}'       "$POLICY_RULES_API" \
    && fail "api.go: /api/rules/{cat} must stay removed (absorbed by /api/policy/rules)"
grep -Eq 'HandleFunc\("[A-Z]+ /api/update"'             "$POLICY_RULES_API" \
    && fail "api.go: /api/update must stay removed (absorbed by /api/policy/apply)"
grep -Eq 'HandleFunc\("[A-Z]+ /api/egress/split-rules'  "$POLICY_RULES_API" \
    && fail "api.go: /api/egress/split-rules must stay removed (absorbed by /api/policy/rules)"
grep -Eq 'HandleFunc\("[A-Z]+ /api/egress/rule-subs'    "$POLICY_RULES_API" \
    && fail "api.go: /api/egress/rule-subs must stay removed (absorbed by /api/policy/rules)"

# --- install.sh: stages etc/systemd into the installed tree (install_units
# falls back to it on a piped curl|bash install with no checkout) ---
grep -Fq '${BASE_DIR}/etc/systemd' "$INSTALL" || fail "install.sh: install_files does not stage etc/systemd into /opt/5gpn"
grep -Fq 'mihomo.service' "$INSTALL" || fail "install.sh: install_units does not install mihomo.service"
grep -Fq '${BASE_DIR}/etc/mihomo' "$INSTALL" || fail "install.sh: installed management runtime has no mihomo asset directory"
grep -Fq 'config.yaml.tmpl whitelist.seed.txt' "$INSTALL" \
    || fail "install.sh: installed management runtime does not retain every mihomo reset asset"

# --- 5gpn-dns.service: sandboxed conf-dir writes allowed under ProtectSystem=strict ---
# The policy engine rewrites /etc/5gpn/policy.json (the console-managed
# DNS_POLICY_RULES store, atomic temp+rename) alongside the subscription
# manager's rule caches under /etc/5gpn/rules, so the whole conf dir stays RW
# with the secrets (dns.env, cert) re-protected read-only.
grep -Fq 'ReadWritePaths=/etc/5gpn' "$DNS_SVC" || fail "5gpn-dns.service: no ReadWritePaths=/etc/5gpn (policy.json + provider-dir write path)"
grep -Fq 'ReadOnlyPaths=/etc/5gpn/dns.env' "$DNS_SVC" || fail "5gpn-dns.service: dns.env (token) not re-protected read-only"
grep -Fq 'InaccessiblePaths=-/etc/5gpn/acme' "$DNS_SVC" \
    || fail "5gpn-dns.service: resolver sandbox can access the Cloudflare Zone:DNS:Edit token"

# --- install.sh: fresh-install chnroute seed (Task 8 fix A) ---
# A truly fresh box must not crash-loop: the bundled etc/china_ip_list.txt
# snapshot is installed as the manual chnroute file (DNS_CHNROUTE target)
# before start_services, but only when no cache is already present (never
# clobber a fresher subscription-fetched cache on re-install/upgrade).
CHNROUTE_SEED="$ROOT/etc/china_ip_list.txt"
[ -f "$CHNROUTE_SEED" ] || fail "etc/china_ip_list.txt seed does not exist"
if [ -f "$CHNROUTE_SEED" ]; then
    seed_lines="$(grep -cvE '^[[:space:]]*(#|$)' "$CHNROUTE_SEED" 2>/dev/null | head -n1 || echo 0)"
    [ "${seed_lines:-0}" -ge 1000 ] || fail "etc/china_ip_list.txt seed has too few CIDR lines (${seed_lines:-0})"
fi
grep -Fq 'etc/china_ip_list.txt' "$INSTALL" || fail "install.sh: does not reference etc/china_ip_list.txt seed"
grep -Eq '\[\[ -s "\$\{DNS_RULES_DIR_DEFAULT\}/china_ip_list.txt" \]\]' "$INSTALL" \
    || fail "install.sh: does not guard chnroute seed install on cache absence (-s check)"

# --- bot.go: botServices has 5gpn-dns + mihomo (bot controls both data-path
# services: 5gpn-dns in-process, mihomo is the SNI/QUIC transparent proxy) ---
grep -Fq '"5gpn-dns"'   "$BOT" || fail "bot.go: botServices does not contain 5gpn-dns"
grep -Fq '"smartdns"'   "$BOT" \
    && fail "bot.go: botServices still contains smartdns"
grep -Fq '"xray"'       "$BOT" \
    && fail "bot.go: botServices still contains xray (bot must control mihomo, not xray)"
grep -Fq '"mihomo"'     "$BOT" \
    || fail "bot.go: botServices does not contain mihomo (bot must control the mihomo data plane)"

# --- install.sh: control-plane token + loopback :443 pin ---
grep -Fq 'openssl rand'      "$INSTALL" || fail "install.sh: no token auto-gen (openssl rand)"
grep -Fq 'DNS_API_TOKEN'     "$INSTALL" || fail "install.sh: does not write DNS_API_TOKEN into dns.env"
grep -Fq 'DNS_LISTEN_API=127.0.0.1:443' "$INSTALL" \
    || fail "install.sh: dns.env must pin the control plane to 127.0.0.1:443 (webui behind the mihomo SNI split)"
grep -Fq 'DNS_LISTEN_API=:9443' "$INSTALL" \
    && fail "install.sh: the old :9443 control-plane port must not come back"
grep -Fq 'DNS_LISTEN_API=:18443' "$INSTALL" \
    && fail "install.sh: the old xray-era :18443 control-plane port must not come back"
grep -Fq 'existing_token'    "$INSTALL" || fail "install.sh: does not preserve an existing token across re-install"

# --- Unified policy state + mihomo loopback origin DNS selector ---
grep -Fq 'ReadOnlyPaths=/etc/5gpn/dns.env' "$DNS_SVC" \
    || fail "5gpn-dns.service: dns.env is not re-protected read-only"
grep -Eq '^ReadWritePaths=/etc/5gpn$' "$DNS_SVC" \
    || fail "5gpn-dns.service: ReadWritePaths must stay a single /etc/5gpn entry"
POLICY_CFG="$ROOT/cmd/5gpn-dns/config.go"
POLICY_MAIN="$ROOT/cmd/5gpn-dns/main.go"
grep -Fq 'DNS_EGRESS_BROKER' "$POLICY_CFG" \
    || fail "config.go: no DNS_EGRESS_BROKER env var"
grep -Fq '127.0.0.1:5354' "$POLICY_CFG" \
    || fail "config.go: DNS_EGRESS_BROKER default is not 127.0.0.1:5354"
grep -Fq 'DNS_EGRESS_BROKER=127.0.0.1:5354' "$ROOT/etc/5gpn-dns/dns.env.example" \
    || fail "dns.env.example: DNS_EGRESS_BROKER not documented with default 127.0.0.1:5354"

BROKER_SELECTOR="$ROOT/cmd/5gpn-dns/egress_dns_selector.go"
BROKER_GO="$ROOT/cmd/5gpn-dns/egress_dns_broker.go"
INSTALL_SH="$ROOT/install.sh"
grep -Fq 'newDefaultEgressDNSBroker' "$POLICY_MAIN" \
    || fail "main.go: egress broker must be built unconditionally"
grep -Fq 'newDefaultEgressDNSBroker' "$BROKER_SELECTOR" \
    || fail "egress_dns_selector.go: no newDefaultEgressDNSBroker constructor"
grep -Fq 'captureDNSForName' "$BROKER_SELECTOR" \
    || fail "egress_dns_selector.go: active extension capture DNS binding is not consulted"
grep -Fq 'type EgressDNSBroker struct' "$BROKER_GO" \
    || fail "egress_dns_broker.go: no EgressDNSBroker"
# An empty broker address must be a config error there (not a silent disable).
grep -Fq 'mihomo requires a loopback broker listener' "$BROKER_SELECTOR" \
    || fail "egress_dns_selector.go: empty broker address must be a config error"
# A broker bind failure must be fatal in main (fail-loud), not warn-disable.
grep -Eq 'log\.Fatalf\("egress DNS broker' "$POLICY_MAIN" \
    || fail "main.go: broker bind failure must be fatal (log.Fatalf)"
# The retired single-upstream fallback must stay gone. The broker uses the live
# China/trust groups instead of a second resolver contract.
grep -Fq 'DNS_EGRESS_RESOLVER is retired' "$POLICY_CFG" \
    || fail "config.go: retired DNS_EGRESS_RESOLVER is not rejected explicitly"
grep -Fq 'EgressResolver string' "$POLICY_CFG" \
    && fail "config.go: retired EgressResolver field remains"
grep -Fq 'Pre-v5 dns.env contains retired DNS_EGRESS_RESOLVER' "$INSTALL_SH" \
    || fail "install.sh: retired DNS_EGRESS_RESOLVER is not rejected explicitly"
grep -Eq '^[[:space:]]*DNS_EGRESS_RESOLVER=' "$INSTALL_SH" \
    && fail "install.sh: retired DNS_EGRESS_RESOLVER is still persisted"
grep -Fq 'XRAY_RESOLVER' "$POLICY_CFG" \
    && fail "config.go: removed XRAY_RESOLVER key is still read"
grep -Fq 'XRAY_RESOLVER' "$INSTALL_SH" \
    && fail "install.sh: removed XRAY_RESOLVER key remains"

API_GO="$ROOT/cmd/5gpn-dns/api.go"

# The obsolete draft/shadow surface must stay gone. Restrict this scan to
# production/config/frontend sources so historical design docs remain intact.
if grep -rEl 'policyv2|policy-v2|DNS_POLICY_(ROOT|KEY|KEY_ID|BROKER|SHADOW_RUNTIME|RUNTIME_LIVE)|/api/(drafts|capabilities)' \
    "$ROOT/cmd/5gpn-dns" "$ROOT/web/src" "$ROOT/web/e2e" "$ROOT/install.sh" "$ROOT/etc" \
    --include='*.go' --include='*.ts' --include='*.tsx' --include='*.sh' --include='*.service' --include='*.example' \
    | grep -v '_test\.' >/dev/null 2>&1; then
    fail "found a reintroduced legacy draft/shadow policy surface"
fi
if grep -rEln "['\"]/(policy|egress)['\"]" "$ROOT/web/e2e" --include='*.ts' >/dev/null 2>&1; then
    fail "web/e2e: found a reintroduced retired /policy or /egress route"
fi

# --- SP-3: browser-facing reverse proxy to mihomo + second (zashboard) panel
# server. These lock the Phase A wiring that api.go / mihomo_proxy.go carry so
# a refactor can't silently drop the "/proxy/" mount or the zash listener. ---
MIHOMO_PROXY_GO="$ROOT/cmd/5gpn-dns/mihomo_proxy.go"
grep -Fq 'func newMihomoProxy(' "$MIHOMO_PROXY_GO" \
    || fail "mihomo_proxy.go: no newMihomoProxy constructor"
grep -Fq '"/proxy/"' "$API_GO" \
    || fail "api.go: does not mount \"/proxy/\" (reverse-proxy to mihomo's controller)"
grep -Fq 'newMihomoProxy(' "$API_GO" \
    || fail "api.go: does not call newMihomoProxy"
grep -Fq 'zashSrv' "$API_GO" \
    || fail "api.go: no zashSrv field (second loopback panel server for zashboard)"
grep -Fq 's.zashSrv = buildPanelServer(' "$API_GO" \
    || fail "api.go: NewControlServer does not build/assign the zashSrv panel server"

# --- SP-3: no-xray-in-web regression lock. Phase B deleted the xray/exits
# frontend feature and its API bindings; nothing under web/src may reintroduce
# their module paths or entry points (a merge/rebase resurrecting the deleted
# tree would otherwise slip past a per-file grep helper). ---
WEB_SRC="$ROOT/web/src"
if [ -d "$WEB_SRC" ]; then
    if grep -rlE 'features/xray|features/exits|getXray|getExits|RouteRules' "$WEB_SRC" >/dev/null 2>&1; then
        fail "web/src: found a reintroduced xray/exits reference (features/xray, features/exits, getXray, getExits, or RouteRules)"
    fi
else
    fail "web/src directory not found"
fi


# --- UP-2/UP-4: install seeds the unified policy default ruleset (policy.json) ---
# install.sh invokes the daemon's --seed-defaults subcommand (Go owns the JSON
# shape) BEFORE start_services, so the first boot compile sees a populated
# model. Binary policy (UP-4,
# 2026-07-15 policy/mihomo decoupling): a proxy-intent rule carries no
# selector, so the seed no longer creates egress.json/egress-nodes.enc or a
# rule-provider dir -- egress routing is entirely the operator's mihomo
# config (its default Proxies select group is seeded by render_mihomo_config
# instead, asserted in test_mihomo_policy.sh).
grep -Fq 'seed_policy_defaults'  "$INSTALL" || fail "install.sh: no seed_policy_defaults function"
grep -Fq -- '--seed-defaults'    "$INSTALL" || fail "install.sh: does not invoke 5gpn-dns --seed-defaults"
grep -Fq '${CONF_DIR}/policy.json' "$INSTALL" || fail "install.sh: does not seed /etc/5gpn/policy.json"
grep -Fq -- '--egress-out'         "$INSTALL" && fail "install.sh: seed_policy_defaults must not pass --egress-out (flag removed from --seed-defaults)"
spd_fn="$(sed -n '/^seed_policy_defaults()/,/^}/p' "$INSTALL")"
printf '%s' "$spd_fn" | grep -Fq '${CONF_DIR}/egress.json' && fail "install.sh: must not seed egress.json (structured egress model removed)"

# No superseded policy/egress state helper or path remains.
grep -Fq 'remove_legacy_policy_state' "$INSTALL" \
    && fail "install.sh: old policy-state migration helper remains"
grep -Eq 'egress(-nodes)?\.(json|enc)' "$INSTALL" \
    && fail "install.sh: removed structured-egress state path remains"

# the two default §7 list URLs are env-overridable
grep -Fq 'felixonmars/dnsmasq-china-list' "$INSTALL" || fail "install.sh: fixed china-list seed URL missing"
grep -Fq 'Loyalsoldier/v2ray-rules-dat' "$INSTALL" || fail "install.sh: fixed gfw seed URL missing"
seed_fn="$(sed -n '/^seed_policy_defaults()/,/^}/p' "$INSTALL")"
printf '%s' "$seed_fn" | grep -Eq 'CHINA_LIST_URL|GFW_URL' \
    && fail "install.sh: policy seed URLs still accept caller environment overrides"
grep -Fq 'accelerated-domains.china.conf'  "$INSTALL" || fail "install.sh: missing dnsmasq-china-list default URL"
grep -Fq 'v2ray-rules-dat'                 "$INSTALL" || fail "install.sh: missing gfw default URL"

# the seed's Go surface exists
SEED_GO="$ROOT/cmd/5gpn-dns/seed_defaults.go"
[ -f "$SEED_GO" ] || fail "cmd/5gpn-dns/seed_defaults.go does not exist"
grep -Fq 'buildDefaultPolicyModel' "$SEED_GO" || fail "seed_defaults.go: no buildDefaultPolicyModel"
grep -Fq 'seedSelectorName = "Proxies"' "$SEED_GO" && fail "seed_defaults.go: must not seed a Proxies default selector (binary policy carries no selector -- see mihomoConfigSeedTemplate's Proxies group instead)"
grep -Fq -- '--seed-defaults' "$ROOT/cmd/5gpn-dns/main.go" || fail "main.go: no --seed-defaults subcommand"

# the bundled bypass lists still ship (now CONSUMED by the seed, not installed as block.txt)
[ -f "$ROOT/etc/block-dns-bypass.txt" ]         || fail "etc/block-dns-bypass.txt must still ship (seed input)"
[ -f "$ROOT/etc/block-dns-bypass.keyword.txt" ] || fail "etc/block-dns-bypass.keyword.txt must still ship (seed input)"

# chnroute STAYS in subscriptions.json (system arbitration input, NOT a policy rule)
grep -Fq '"category": "chnroute"' "$INSTALL" || fail "install.sh: chnroute subscription must stay in subscriptions.json"
grep -Fq 'china_ip_list'          "$INSTALL" || fail "install.sh: china_ip_list chnroute source must stay"

# Policy-owned subscriptions stay in policy.json rather than subscriptions.json.
grep -Fq '"category": "block"'   "$INSTALL" && fail "install.sh: block subscription must move to policy.json"
grep -Fq '"category": "proxy"'     "$INSTALL" && fail "install.sh: proxy(gfw) subscription must move to policy.json"
grep -Fq '"category": "direct"'    "$INSTALL" && fail "install.sh: direct(china-list) subscription must move to policy.json"

# Current cache directories use the block/direct/proxy vocabulary; there is no
# shell-managed category file.
grep -Fq '"${DNS_RULES_DIR_DEFAULT}"/{block,direct,proxy,chnroute}' "$INSTALL" \
    || fail "install.sh: current subscription cache directories are incomplete"
grep -Eq '(block|direct|proxy|blacklist)(\.keyword|\.prefix|\.suffix)?\.txt' "$INSTALL" \
    && fail "install.sh: shell-managed DNS category file remains"
grep -Fq 'blacklist' "$INSTALL" && fail "install.sh: removed blacklist category remains"

true  # ensure the block's last command never sets rc via a && short-circuit

[ $rc -eq 0 ] && echo "5gpn-dns policy: PASS"
exit $rc
