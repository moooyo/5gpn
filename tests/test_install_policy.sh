#!/usr/bin/env bash
# Policy assertions for installer cert-renewal automation + control-plane status.
# Pure grep (no Python/Linux needed); runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"

# --- certbot auto-renewal is now UNATTENDED via Cloudflare DNS-01 (2026-07-14
# reversal): the API sets the transient _acme-challenge TXT with no human step
# and no :80, so there is no pre/post renewal-hook stopping/starting anything
# around port 80 anymore (that was the old http-01/--standalone flow). A box
# upgrading from that flow still gets its legacy pre/post hook FILES cleaned up
# (rm -f), so this only asserts no NEW pre/post hook dir is ever CREATED.
grep -Eq 'install -d.*renewal-hooks/pre'  "$INSTALL" && fail "install.sh must not create a pre-renewal hook dir (no :80 dance needed for DNS-01)"
grep -Eq 'install -d.*renewal-hooks/post' "$INSTALL" && fail "install.sh must not create a post-renewal hook dir (no :80 dance needed for DNS-01)"
grep -Fq 'systemctl stop xray'  "$INSTALL" && fail "install.sh must not stop xray for cert renewal (DNS-01 needs no :80)"
grep -Fq 'systemctl start xray' "$INSTALL" && fail "install.sh must not restart xray for cert renewal (DNS-01 needs no :80)"
# a renewal timer so renewal actually runs unattended, and catches up missed runs.
grep -Eq '5gpn-certbot-renew\.timer' "$INSTALL" || fail "no certbot renewal timer installed"
grep -Eq '^Persistent=true'             "$INSTALL" || fail "renewal timer not Persistent (missed runs won't catch up)"
grep -Eq 'certbot renew'                "$INSTALL" || fail "renewal timer does not run 'certbot renew'"

# ===== iOS profile is served at the web console's public /ios/ path; the
# standalone :8111 responder and the host firewall are both gone =====
grep -Eq 'IOS_PORT=' "$INSTALL" && fail "install.sh must not reference IOS_PORT (:8111 responder removed)"
grep -Fq '/ios/ios-dot.mobileconfig' "$INSTALL" \
    || fail "install.sh must print the /ios/ profile URL (web console path)"
# GATEWAY_IP is prompted interactively at install (resolve_gateway_ip), defaults to
# the detected PUBLIC_IP on a bare Enter / non-interactive install, and is editable
# later via `5gpn change-gateway`. NPN operators enter/export the internal 172.22 addr.
grep -Eq '^resolve_gateway_ip\(\)' "$INSTALL" \
    || fail "no resolve_gateway_ip() (interactive install-time gateway IP prompt)"
grep -Eq '^[[:space:]]*resolve_gateway_ip$' "$INSTALL" \
    || fail "resolve_gateway_ip defined but never called in full_install"
gw_fn="$(sed -n '/^resolve_gateway_ip()/,/^}/p' "$INSTALL")"
printf '%s' "$gw_fn" | grep -Eq 'ask_text .*网关IP' \
    || fail "resolve_gateway_ip does not prompt for the gateway IP"
printf '%s' "$gw_fn" | grep -Fq 'GATEWAY_IP="$PUBLIC_IP"' \
    || fail "resolve_gateway_ip does not default the gateway IP to PUBLIC_IP"

# P0: install-time SNI resolver is prompted, persisted (to the single dns.env),
# and env-overridable.
grep -Eq 'XRAY_RESOLVER="?\$\{XRAY_RESOLVER:-\$\(cfg_get XRAY_RESOLVER\)\}' "$INSTALL" \
    || fail "resolver not resolved from the single dns.env via cfg_get XRAY_RESOLVER"
grep -Eq 'XRAY_RESOLVER'                       "$INSTALL" || fail "XRAY_RESOLVER not wired in install flow"
grep -Eq 'ask_text .*(解析器|resolver)'         "$INSTALL" || fail "no resolver prompt"

# --- Frontend shipped separately + served from disk (not go:embed) ---
grep -Eq 'install_web'          "$INSTALL" || fail "no install_web() to fetch the 5gpn-web tarball"
grep -Eq '5gpn-web-.*\.tar\.gz' "$INSTALL" || fail "install_web does not fetch the 5gpn-web tarball asset"
grep -Eq 'DNS_WEB_DIR'          "$INSTALL" || fail "DNS_WEB_DIR not wired in install.sh"

# --- `5gpn` management command: installed on PATH, backed by a copy of install.sh ---
grep -Eq '^install_manage_cli\(\)' "$INSTALL" || fail "no install_manage_cli() (the 5gpn management command)"
grep -Eq '^[[:space:]]*install_manage_cli$' "$INSTALL" || fail "install_manage_cli defined but never called in full_install"
grep -Fq '/usr/local/bin/5gpn' "$INSTALL" || fail "5gpn launcher not written to /usr/local/bin/5gpn"
grep -Fq 'exec bash "$BK" --menu' "$INSTALL" || fail "5gpn launcher does not open the management menu with no args"
# The menu + its operations must be dispatchable — including the single
# base-domain change command (with its back-compat aliases) and the public-IP
# change.
for tok in '--menu|menu)' '--restart|restart)' '--change-base-domain|change-base-domain)' \
           '--change-web-domain|change-web-domain)' '--change-dot-domain|change-dot-domain)' \
           '--change-public-ip|change-public-ip)' '--change-gateway|change-gateway)'; do
    grep -Fq -e "$tok" "$INSTALL" || fail "install.sh dispatch missing case: $tok"
done
grep -Eq '^manage_menu\(\)'      "$INSTALL" || fail "no manage_menu() TUI"
grep -Eq '^change_base_domain\(\)' "$INSTALL" || fail "no change_base_domain() (single base-domain change op)"
grep -Eq '^change_public_ip\(\)'  "$INSTALL" || fail "no change_public_ip() (menu 'modify public IP')"
grep -Eq '^change_gateway\(\)'   "$INSTALL" || fail "no change_gateway() (menu 'modify gateway IP')"
grep -Eq '^restart_services\(\)' "$INSTALL" || fail "no restart_services() (menu 'restart')"
# change_base_domain must (re)issue the *.<base> wildcard, persist the base +
# derived DoT domain, and re-render the mihomo config.
cb_fn="$(sed -n '/^change_base_domain()/,/^}/p' "$INSTALL")"
printf '%s' "$cb_fn" | grep -Fq 'install_cert "$new"' || fail "change_base_domain does not (re)issue the *.<base> wildcard cert"
printf '%s' "$cb_fn" | grep -Fq 'set_dns_env_kv "${CONF_DIR}/dns.env" DNS_BASE_DOMAIN' \
    || fail "change_base_domain does not persist DNS_BASE_DOMAIN into dns.env"
printf '%s' "$cb_fn" | grep -Fq 'set_dns_env_kv "${CONF_DIR}/dns.env" DNS_DOMAIN' \
    || fail "change_base_domain does not persist the derived DoT domain (DNS_DOMAIN)"
printf '%s' "$cb_fn" | grep -Eq 'apply_domain_to_mihomo|render_mihomo_config' \
    || fail "change_base_domain does not re-render the mihomo config"
# change_public_ip must persist DNS_PUBLIC_IP + refresh the mihomo anti-loop list.
cp_fn="$(sed -n '/^change_public_ip()/,/^}/p' "$INSTALL")"
printf '%s' "$cp_fn" | grep -Fq 'set_dns_env_kv "${CONF_DIR}/dns.env" DNS_PUBLIC_IP' \
    || fail "change_public_ip does not persist DNS_PUBLIC_IP into dns.env"
printf '%s' "$cp_fn" | grep -Fq 'apply_gateway_to_mihomo' \
    || fail "change_public_ip does not refresh the mihomo anti-loop blackhole"
# Base-domain install flow: ONE base domain, the three service subdomains
# (console./zash./dot.<base>) auto-derived by derive_domains.
grep -Eq '^resolve_domains\(\)' "$INSTALL" || fail "no resolve_domains() (base-domain install prompt)"
rd_fn="$(sed -n '/^resolve_domains()/,/^}/p' "$INSTALL")"
printf '%s' "$rd_fn" | grep -Fq 'derive_domains' \
    || fail "resolve_domains does not derive the service subdomains via derive_domains"
printf '%s' "$rd_fn" | grep -Eq 'DNS_BASE_DOMAIN|DNS_WEB_DOMAIN' \
    || fail "resolve_domains does not read the base/web domain back from dns.env"
grep -Eq '^derive_domains\(\)' "$INSTALL" || fail "no derive_domains() (single subdomain derivation)"
dd_fn="$(sed -n '/^derive_domains()/,/^}/p' "$INSTALL")"
printf '%s' "$dd_fn" | grep -Fq 'console.' || fail "derive_domains does not derive console.<base>"
printf '%s' "$dd_fn" | grep -Fq 'zash.'    || fail "derive_domains does not derive zash.<base>"
printf '%s' "$dd_fn" | grep -Fq 'dot.'     || fail "derive_domains does not derive dot.<base>"
# change_gateway must persist DNS_GATEWAY_IP + refresh the mihomo anti-loop blackhole.
cg_fn="$(sed -n '/^change_gateway()/,/^}/p' "$INSTALL")"
printf '%s' "$cg_fn" | grep -Fq 'set_dns_env_kv "${CONF_DIR}/dns.env" DNS_GATEWAY_IP' \
    || fail "change_gateway does not persist DNS_GATEWAY_IP into dns.env"
printf '%s' "$cg_fn" | grep -Fq 'apply_gateway_to_mihomo' \
    || fail "change_gateway does not refresh the mihomo anti-loop blackhole"

# --- Task 4: panel whitelist.txt TUI management + live controller refresh
# (out-of-band; never web-editable, no full config reload). ---
for tok in '--add-allow)' '--del-allow)'; do
    grep -Fq -e "$tok" "$INSTALL" || fail "install.sh dispatch missing case: $tok"
done
grep -Eq '^add_allow_ip\(\)'     "$INSTALL" || fail "no add_allow_ip() (menu/CLI whitelist add)"
grep -Eq '^del_allow_ip\(\)'     "$INSTALL" || fail "no del_allow_ip() (menu/CLI whitelist del)"
grep -Eq '^apply_whitelist\(\)'  "$INSTALL" || fail "no apply_whitelist() (live controller refresh)"
aa_fn="$(sed -n '/^add_allow_ip()/,/^}/p' "$INSTALL")"
printf '%s' "$aa_fn" | grep -Fq 'ask_text' \
    || fail "add_allow_ip does not prompt via ask_text"
printf '%s' "$aa_fn" | grep -Eq 'ask_text .*\|\| true\)"' \
    || fail "add_allow_ip's ask_text capture is not guarded with || true (cancel would abort under set -e)"
printf '%s' "$aa_fn" | grep -Fq '"$MIHOMO_DIR/whitelist.txt"' \
    || fail "add_allow_ip does not write MIHOMO_DIR/whitelist.txt"
printf '%s' "$aa_fn" | grep -Fq 'apply_whitelist' \
    || fail "add_allow_ip does not call apply_whitelist (live refresh)"
da_fn="$(sed -n '/^del_allow_ip()/,/^}/p' "$INSTALL")"
printf '%s' "$da_fn" | grep -Eq 'ask_text .*\|\| true\)"' \
    || fail "del_allow_ip's ask_text capture is not guarded with || true (cancel would abort under set -e)"
printf '%s' "$da_fn" | grep -Fq '"$MIHOMO_DIR/whitelist.txt"' \
    || fail "del_allow_ip does not edit MIHOMO_DIR/whitelist.txt"
printf '%s' "$da_fn" | grep -Fq 'apply_whitelist' \
    || fail "del_allow_ip does not call apply_whitelist (live refresh)"
aw_fn="$(sed -n '/^apply_whitelist()/,/^}/p' "$INSTALL")"
printf '%s' "$aw_fn" | grep -Fq 'providers/rules/whitelist' \
    || fail "apply_whitelist does not PUT the controller's providers/rules/whitelist endpoint"
printf '%s' "$aw_fn" | grep -Fq 'Authorization: Bearer' \
    || fail "apply_whitelist does not send the controller bearer secret"
printf '%s' "$aw_fn" | grep -Fq 'TODO(Task 6)' \
    || fail "apply_whitelist is missing the TODO(Task 6) DNS_MIHOMO_SECRET marker"
# manage_menu must expose add/remove allowlist entries as menu ops.
mm_fn="$(sed -n '/^manage_menu()/,/^}/p' "$INSTALL")"
printf '%s' "$mm_fn" | grep -Fq 'add_allow_ip' \
    || fail "manage_menu does not wire an add-allowlist-IP entry"
printf '%s' "$mm_fn" | grep -Fq 'del_allow_ip' \
    || fail "manage_menu does not wire a remove-allowlist-IP entry"

# uninstall must remove the 5gpn launcher.
grep -Fq '/usr/local/bin/5gpn ' "$INSTALL" || grep -Eq 'rm -f .*/usr/local/bin/5gpn( |$)' "$INSTALL" \
    || fail "uninstall does not remove /usr/local/bin/5gpn"

# --- Piped install (curl | sudo bash) must still prompt: reattach stdin to /dev/tty ---
# Without this, fd 0 is the pipe, [[ -t 0 ]] is false, and DOMAIN/GATEWAY_IP/resolver
# prompts are all skipped (the install then aborts on the missing domain).
grep -Eq '^attach_tty\(\)' "$INSTALL" \
    || fail "no attach_tty() (a piped curl|bash install would skip every prompt)"
at_fn="$(sed -n '/^attach_tty()/,/^}/p' "$INSTALL")"
printf '%s' "$at_fn" | grep -Fq 'exec 0</dev/tty' \
    || fail "attach_tty does not reattach stdin to /dev/tty"
printf '%s' "$at_fn" | grep -Fq '[[ -t 0 ]] && return 0' \
    || fail "attach_tty must no-op when stdin is already a terminal"
grep -Eq '^[[:space:]]*attach_tty$' "$INSTALL" \
    || fail "main() does not call attach_tty (piped install stays non-interactive)"

# --- Fresh-artifact re-runs (2026-07-10): every install cleans previous units/
# configs and unconditionally re-downloads every binary at its pin; ONLY
# /etc/5gpn + /etc/letsencrypt persist. No keep-if-present shortcuts. ---
grep -Eq '^clean_previous_install\(\)' "$INSTALL" \
    || fail "no clean_previous_install() (fresh-artifact rule)"
grep -Eq '^[[:space:]]*clean_previous_install$' "$INSTALL" \
    || fail "clean_previous_install defined but never called in full_install"
cl_fn="$(sed -n '/^clean_previous_install()/,/^}/p' "$INSTALL")"
# The clean step must never touch the persisted config/cert dir or the LE lineage.
printf '%s' "$cl_fn" | grep -Eq 'rm .*(\$\{?CONF_DIR|/etc/5gpn)' \
    && fail "clean_previous_install must not rm anything under /etc/5gpn (persisted)"
printf '%s' "$cl_fn" | grep -Eq 'rm.*/etc/letsencrypt/(live|archive|renewal/)' \
    && fail "clean_previous_install must not remove the /etc/letsencrypt cert lineage"
# It must not stop the live resolver/data plane (only legacy units are stopped):
# no direct stop, and the CURRENT live unit (5gpn-dns) must never appear in the
# disable --now legacy loop. xray is now a LEGACY unit (mihomo replaced it as the
# data plane) and MUST appear in that loop, so a box upgrading from xray gets it
# stopped/removed — otherwise it keeps holding :443 and mihomo can't bind.
printf '%s' "$cl_fn" | grep -Eq 'systemctl (stop|disable --now) (5gpn-dns|xray)' \
    && fail "clean_previous_install must not stop the running 5gpn-dns/xray"
printf '%s' "$cl_fn" | sed -n '/for unit in/,/done/p' | grep -Eq '5gpn-dns\.service' \
    && fail "clean_previous_install's legacy stop-loop must not include the live 5gpn-dns unit"
printf '%s' "$cl_fn" | sed -n '/for unit in/,/done/p' | grep -Eq 'xray\.service' \
    || fail "clean_previous_install's legacy stop-loop must include xray.service (upgrade-from-xray teardown)"
# The staged /opt/5gpn/install.sh must survive the wipe (the '5gpn' menu runs it).
printf '%s' "$cl_fn" | grep -Fq '! -name install.sh' \
    || fail "clean_previous_install must keep the staged /opt/5gpn/install.sh (find ... ! -name install.sh)"
# Installers must have NO keep-if-present early return: a stale binary next to a
# fresh config is exactly the skew this rule exists to kill.
grep -Fq '5gpn-dns already installed' "$INSTALL" \
    && fail "install_5gpndns must not keep an existing binary (fresh-artifact rule)"
grep -Fq 'Xray already installed' "$INSTALL" \
    && fail "install_xray must not keep an existing binary (fresh-artifact rule)"
grep -Fq 'SPA already present' "$INSTALL" \
    && fail "install_web must not keep an existing web dir (fresh-artifact rule)"

# --- Certs are DELIBERATELY preserved (re-issuing an LE cert is rate-limited) ---
un_fn="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
printf '%s' "$un_fn" | grep -Fq '! -name cert' \
    || fail "uninstall --purge must preserve the cert dir (find ... ! -name cert)"
# The Cloudflare API-token dir must ALSO survive --purge: otherwise a reinstall
# with a still-valid cert (which needs no token) is fine, but a reinstall that
# DOES need to issue would hard-abort for a token wiped for no reason.
printf '%s' "$un_fn" | grep -Fq '! -name acme' \
    || fail "uninstall --purge must preserve the acme/ dir (find ... ! -name acme) so the Cloudflare token survives"
printf '%s' "$un_fn" | grep -Eq 'rm -rf "\$CONF_DIR"( |$)' \
    && fail "uninstall must NOT 'rm -rf \$CONF_DIR' wholesale (would delete the preserved cert dir)"
# The certbot lineage (live/archive/renewal conf) must never be removed by uninstall —
# it is what a re-install reuses. (Removing renewal-HOOKS is fine and expected.)
printf '%s' "$un_fn" | grep -Eq 'rm.*/etc/letsencrypt/(live|archive|renewal/)' \
    && fail "uninstall must not remove the /etc/letsencrypt cert lineage (needed for reuse)"
# install_cert reuses a valid cert instead of re-issuing (rate-limit safe).
ic_fn="$(sed -n '/^install_cert()/,/^}/p' "$INSTALL")"
printf '%s' "$ic_fn" | grep -Fq 'keep-until-expiring' \
    || fail "install_cert must pass certbot --keep-until-expiring (reuse, not re-issue)"
printf '%s' "$ic_fn" | grep -Eiq 'reus(e|ing)' \
    || fail "install_cert has no cert-reuse path (would re-issue every install)"

# --- Task 1: Cloudflare API-token credential helper ---
# has_valid_cf_credential must recognise a saved token in cloudflare.ini.
grep -Eq '^has_valid_cf_credential\(\)' "$INSTALL" \
    || fail "no has_valid_cf_credential() (must recognise a saved Cloudflare API token in cloudflare.ini)"
hvc_fn="$(sed -n '/^has_valid_cf_credential()/,/^}/p' "$INSTALL")"
printf '%s' "$hvc_fn" | grep -Fq 'dns_cloudflare_api_token' \
    || fail "has_valid_cf_credential does not check for the dns_cloudflare_api_token credential entry"
# ensure_cf_token must implement the full precedence chain.
grep -Eq '^ensure_cf_token\(\)' "$INSTALL" \
    || fail "no ensure_cf_token() (credential helper called before certbot in the issuance branch)"
ect_fn="$(sed -n '/^ensure_cf_token()/,/^}/p' "$INSTALL")"
printf '%s' "$ect_fn" | grep -Fq 'has_valid_cf_credential' \
    || fail "ensure_cf_token does not check has_valid_cf_credential (reuse path)"
printf '%s' "$ect_fn" | grep -Fq 'CF_API_TOKEN' \
    || fail "ensure_cf_token does not accept CF_API_TOKEN (headless-install env)"
printf '%s' "$ect_fn" | grep -Fq 'CLOUDFLARE_API_TOKEN' \
    || fail "ensure_cf_token does not accept CLOUDFLARE_API_TOKEN (alternate headless env)"
printf '%s' "$ect_fn" | grep -Eq 'ask_secret.*\|\| true' \
    || fail "ensure_cf_token's ask_secret is not guarded with || true (cancel aborts under set -e)"
printf '%s' "$ect_fn" | grep -Eq '\[\[ -t 0 \]\]' \
    || fail "ensure_cf_token does not gate the interactive prompt on a TTY ([[ -t 0 ]])"
printf '%s' "$ect_fn" | grep -Eq 'err.*CF_API_TOKEN' \
    || fail "ensure_cf_token does not reference CF_API_TOKEN in its noninteractive failure message"
# ensure_cf_token must create ACME_DIR with mode 0700 so credentials dir is root-only.
printf '%s' "$ect_fn" | grep -Eq 'install -d -m 0700' \
    || fail "ensure_cf_token does not create ACME_DIR with mode 0700 (install -d -m 0700 missing)"
# ensure_cf_token must be called within install_cert (issuance branch).
printf '%s' "$ic_fn" | grep -Fq 'ensure_cf_token' \
    || fail "install_cert does not call ensure_cf_token (first issuance hard-aborts without a token)"
# write_cf_credential is the shared atomic writer for both ensure_cf_token and set_cf_token.
# It owns CR/LF rejection, atomic write, and temp-file cleanup (findings 3–5).
grep -Eq '^write_cf_credential\(\)' "$INSTALL" \
    || fail "no write_cf_credential() (shared CR/LF + atomic-write helper missing)"
wcf_fn="$(sed -n '/^write_cf_credential()/,/^}/p' "$INSTALL")"
# CR/LF rejection must be in the shared writer so env-var tokens are covered (finding 3).
printf '%s' "$wcf_fn" | grep -Fq '$'"'"'\r'"'"'' \
    || fail "write_cf_credential does not reject CR (env-var token CR/LF path uncovered)"
printf '%s' "$wcf_fn" | grep -Fq '$'"'"'\n'"'"'' \
    || fail "write_cf_credential does not reject LF (env-var token CR/LF path uncovered)"
# Both callers must delegate writes to write_cf_credential (finding 4 — no duplicated logic).
printf '%s' "$ect_fn" | grep -Fq 'write_cf_credential' \
    || fail "ensure_cf_token does not call write_cf_credential (write logic duplicated)"
printf '%s' "$(sed -n '/^set_cf_token()/,/^}/p' "$INSTALL")" | grep -Fq 'write_cf_credential' \
    || fail "set_cf_token does not call write_cf_credential (write logic duplicated)"
# Errexit-suppression hardening: all unguarded commands inside write_cf_credential and
# ensure_cf_token must carry explicit || guards so they fail loudly when the function is
# called with || (which suppresses set -e inside the callee).
printf '%s' "$wcf_fn" | grep -Eq 'install -d.*\|\|' \
    || fail "write_cf_credential: install -d is not guarded with || (silent failure under errexit suppression)"
printf '%s' "$wcf_fn" | grep -Eq 'mktemp.*\|\|' \
    || fail "write_cf_credential: mktemp assignment is not guarded with || (silent failure under errexit suppression)"
printf '%s' "$wcf_fn" | grep -Fq 'trailing newline' \
    || fail "write_cf_credential: CR/LF rejection error does not mention 'trailing newline' (operator hint missing)"
printf '%s' "$ect_fn" | grep -Eq 'install -d.*\|\|' \
    || fail "ensure_cf_token: install -d is not guarded with || (silent failure under errexit suppression)"
printf '%s' "$ect_fn" | grep -Eq 'chmod 0?600.*\|\|' \
    || fail "ensure_cf_token: chmod 0600 reuse path is not guarded with || (prints reuse success even if chmod failed)"
# install_cert must contain the anchored call, not just a comment referencing ensure_cf_token.
printf '%s' "$ic_fn" | grep -Fq 'ensure_cf_token || return 1' \
    || fail "install_cert: issuance branch must contain 'ensure_cf_token || return 1' (anchored call, not just a comment)"

# --- UP-4 Task 8 (2026-07-15 policy/mihomo decoupling): strong zash secret +
# full-config mihomo seed, no daemon-owned marker regions. ---
MIHOMO_TMPL="$ROOT/etc/mihomo/config.yaml.tmpl"
[ -f "$MIHOMO_TMPL" ] || fail "etc/mihomo/config.yaml.tmpl does not exist"
grep -Fq '>>>5gpn' "$MIHOMO_TMPL" \
    && fail "etc/mihomo/config.yaml.tmpl: no daemon-owned >>>5gpn marker regions may remain (config is fully operator-owned)"
grep -Fq '<<<5gpn' "$MIHOMO_TMPL" \
    && fail "etc/mihomo/config.yaml.tmpl: no daemon-owned <<<5gpn marker regions may remain (config is fully operator-owned)"
grep -Fq -- '- MATCH,Proxies' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: terminal rule must be MATCH,Proxies (routes gateway-bound traffic to the default Proxies group)"
grep -Fq -- '- MATCH,DIRECT' "$MIHOMO_TMPL" \
    && fail "etc/mihomo/config.yaml.tmpl: must not carry a bare MATCH,DIRECT terminal (replaced by MATCH,Proxies)"
grep -Fq '{name: Proxies, type: select, proxies: [DIRECT]}' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: default Proxies select group (DIRECT-only) missing"
# Infrastructure invariants must all still be present in the seed/render path.
grep -Fq 'external-controller: ""' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: plaintext controller must stay disabled"
grep -Fq 'external-controller-tls: 127.0.0.1:9090' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #1 (TLS controller)"
grep -Fq 'certificate: /etc/5gpn/cert/zash/fullchain.pem' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #1 (zash controller certificate path)"
grep -Fq 'private-key: /etc/5gpn/cert/zash/privkey.pem' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #1 (zash controller private-key path)"
grep -Fq '__MIHOMO_LISTENERS__'                 "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing dynamic listener placeholder"
grep -Fq 'target: 127.0.0.1:443'               "$INSTALL" \
    || fail "install.sh: dynamic listener renderer missing sniproxy loopback target"
grep -Fq 'udp://127.0.0.1:5354'                "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #3 (egress DNS broker)"
grep -Fq '__CONSOLE_DOMAIN__: 127.0.0.1'       "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #4 (console SNI hosts mapping)"
grep -Fq '__ZASH_DOMAIN__:    127.0.0.2'        "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #5 (zash SNI hosts mapping)"
grep -Fq '__PROFILE_DOMAIN__: 127.0.0.1'        "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing public profile SNI hosts mapping"
grep -Fq 'DOMAIN,__PROFILE_DOMAIN__,DIRECT'     "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: profile SNI is not routed before panel whitelist rules"
grep -Fq 'IP-CIDR,__GATEWAY_IP__/32,REJECT-DROP' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #6 (anti-loop guard)"

# render_mihomo_config generates a strong mixed secret (base64), not the old hex.
rmc_fn="$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")"
printf '%s' "$rmc_fn" | grep -Fq 'openssl rand -base64 24' \
    || fail "render_mihomo_config must generate the controller secret via openssl rand -base64 24 (strong mixed secret, design §5.1)"
printf '%s' "$rmc_fn" | grep -Fq 'openssl rand -hex 16' \
    && fail "render_mihomo_config must not generate the controller secret via the old openssl rand -hex 16"
printf '%s' "$rmc_fn" | grep -Fq 'mihomo_config_secret "$config"' \
    || fail "render_mihomo_config does not read back an existing secret across re-renders"
printf '%s' "$rmc_fn" | grep -Fq 'Existing operator-owned mihomo config' \
    || fail "render_mihomo_config does not preserve an existing operator-owned config"
printf '%s' "$rmc_fn" | grep -Fq 'mktemp "${MIHOMO_DIR}/.config.yaml.' \
    || fail "render_mihomo_config does not stage a same-directory candidate"
printf '%s' "$rmc_fn" | grep -Fq 'mv -f -- "$candidate" "$config"' \
    || fail "render_mihomo_config does not atomically rename the validated candidate"

# Bootstrap and bind identities are independent/fail-closed.
grep -Fq 'DNS_MIHOMO_LISTEN_IPS=${MIHOMO_LISTEN_IPS}' "$INSTALL" \
    || fail "dns.env does not persist DNS_MIHOMO_LISTEN_IPS"
grep -Fq 'DNS_PROFILE_DOMAIN=${PROFILE_DOMAIN}' "$INSTALL" \
    || fail "dns.env does not persist DNS_PROFILE_DOMAIN"
grep -Eq '^verify_profile_dns\(\)' "$INSTALL" \
    || fail "install.sh has no fail-closed profile A-record verification"

# seed_policy_defaults no longer seeds egress.json/egress-nodes.enc or passes --egress-out.
spd_fn="$(sed -n '/^seed_policy_defaults()/,/^}/p' "$INSTALL")"
printf '%s' "$spd_fn" | grep -Fq 'egress.json' \
    && fail "seed_policy_defaults must not seed egress.json (structured egress model removed)"
printf '%s' "$spd_fn" | grep -Fq -- '--egress-out' \
    && fail "seed_policy_defaults must not pass --egress-out (flag removed from --seed-defaults)"

[ $rc -eq 0 ] && echo "install policy: PASS"
exit $rc
