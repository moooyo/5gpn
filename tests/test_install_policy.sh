#!/usr/bin/env bash
# Policy assertions for installer cert-renewal automation + control-plane status.
# Pure grep (no Python/Linux needed); runs on the dev box.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
CERT_RENEW="$ROOT/scripts/cert-renew.sh"
BOT_OPS="$ROOT/cmd/5gpn-dns/bot_ops.go"

# --- Production renewal is unattended through one mode-aware, cert-name-scoped
# helper. Cloudflare never needs a :80 handoff; due HTTP-01 renewals coordinate
# mihomo inside the helper. Legacy pre/post hook files may still be removed on
# upgrade, but the installer must not create new global stop/start hooks.
[ -f "$CERT_RENEW" ] || fail "mode-aware certificate renewal helper is missing"
grep -Eq 'install -d.*renewal-hooks/pre'  "$INSTALL" && fail "install.sh must not create a global pre-renewal hook dir"
grep -Eq 'install -d.*renewal-hooks/post' "$INSTALL" && fail "install.sh must not create a global post-renewal hook dir"
grep -Fq 'systemctl stop xray'  "$INSTALL" && fail "certificate flows must never stop xray"
grep -Fq 'systemctl start xray' "$INSTALL" && fail "certificate flows must never start xray"
grep -Fiq 'xray' "$CERT_RENEW" && fail "certificate renewal helper must not reference xray"

# The persistent timer and the Telegram bot must both enter through the helper,
# never invoke an unscoped `certbot renew` of every host lineage.
renew_auto_fn="$(sed -n '/^install_renewal_automation()/,/^}/p' "$INSTALL")"
grep -Fq '5gpn-certbot-renew.timer' <<<"$renew_auto_fn" || fail "no certificate renewal timer installed"
grep -Fq 'Persistent=true' <<<"$renew_auto_fn" || fail "renewal timer not Persistent (missed runs will not catch up)"
grep -Fq 'ExecStart=/opt/5gpn/scripts/cert-renew.sh --quiet' <<<"$renew_auto_fn" \
    || fail "renewal timer does not invoke the unified certificate helper"
grep -Fq 'TimeoutStartSec=30min' <<<"$renew_auto_fn" \
    || fail "renewal service timeout cannot cover the 1.1.1.1 wait plus Certbot"
grep -Fq 'TimeoutStopSec=2min' <<<"$renew_auto_fn" \
    || fail "renewal service does not leave a bounded TERM/restore window"
grep -Eq 'ExecStart=.*certbot renew' <<<"$renew_auto_fn" \
    && fail "renewal timer bypasses the scoped helper with direct certbot renew"
grep -Fq 'EnvironmentFile=/etc/5gpn/dns.env' <<<"$renew_auto_fn" \
    && fail "renewal service imports arbitrary persisted keys into a root shell environment"
head -1 "$CERT_RENEW" | grep -Fxq '#!/bin/bash' \
    || fail "renewal helper uses PATH-dependent /usr/bin/env for its root shell"
grep -Fq '"/opt/5gpn/scripts/cert-renew.sh", "--cert-name", certName' "$BOT_OPS" \
    || fail "Telegram renewal does not invoke the unified helper with the validated cert name"
grep -Fq 'cf_credential_safe' "$CERT_RENEW" \
    || fail "Cloudflare renewal can follow an unsafe credential symlink or permissions drift"

# Install/configure ordering: resolve the TUI/persisted selection, wait for the
# fixed-resolver DNS gate, and only then publish or issue certificate material.
full_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
cfg_line="$(grep -n 'resolve_install_configuration' <<<"$full_fn" | head -1 | cut -d: -f1)"
dns_line="$(grep -n '^[[:space:]]*verify_console_dns$' <<<"$full_fn" | head -1 | cut -d: -f1)"
cert_line="$(grep -n '^[[:space:]]*install_cert "\$BASE_DOMAIN"' <<<"$full_fn" | head -1 | cut -d: -f1)"
lock_line="$(grep -n '^[[:space:]]*acquire_install_cert_lock$' <<<"$full_fn" | head -1 | cut -d: -f1)"
capture_line="$(grep -n '^[[:space:]]*capture_install_rollback$' <<<"$full_fn" | head -1 | cut -d: -f1)"
if [[ -z "$cfg_line" || -z "$dns_line" || -z "$cert_line" \
   || -z "$lock_line" || -z "$capture_line" \
   || "$cfg_line" -ge "$dns_line" || "$dns_line" -ge "$lock_line" \
   || "$lock_line" -ge "$capture_line" || "$capture_line" -ge "$cert_line" ]]; then
    fail "configuration/DNS-gate/certificate issuance order is not fail-closed"
fi

# ===== iOS profile is served at the web console's public /ios/ path; the
# standalone :8111 responder and the host firewall are both gone =====
grep -Eq 'IOS_PORT=' "$INSTALL" && fail "install.sh must not reference IOS_PORT (:8111 responder removed)"
grep -Fq '/ios/ios-dot.mobileconfig' "$INSTALL" \
    || fail "install.sh must print the /ios/ profile URL (web console path)"
# First install is TUI-only; reinstall reads the persisted dns.env and caller
# environment is explicitly cleared.
grep -Eq '^configure_install_tui\(\)' "$INSTALL" || fail "no first-install TUI configuration wizard"
grep -Eq '^load_persisted_install_config\(\)' "$INSTALL" || fail "no persisted installer config loader"
grep -Eq '^clear_external_config_env\(\)' "$INSTALL" || fail "caller environment is not cleared"
grep -Fq "First install/configuration requires an attached TTY" "$INSTALL" \
    || fail "headless first install does not fail closed"
grep -Eq "prompt_default .*网关|prompt_default .*Gateway" "$INSTALL" || fail "TUI has no gateway prompt"
grep -Eq "prompt_default .*解析器|prompt_default .*resolver" "$INSTALL" || fail "TUI has no resolver prompt"

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
main_fn="$(sed -n '/^main()/,/^}/p' "$INSTALL")"
printf '%s' "$main_fn" | grep -Fq 'change_base_domain "${2:-}"' \
    || fail "value-less deprecated change-domain aliases can trip set -u before opening the TUI"
printf '%s' "$main_fn" | grep -Fq '${2#dot.}' \
    && fail "change-dot-domain dereferences an unset positional argument under set -u"
grep -Eq '^manage_menu\(\)'      "$INSTALL" || fail "no manage_menu() TUI"
grep -Eq '^change_base_domain\(\)' "$INSTALL" || fail "no change_base_domain() (single base-domain change op)"
grep -Eq '^change_public_ip\(\)'  "$INSTALL" || fail "no change_public_ip() (menu 'modify public IP')"
grep -Eq '^change_gateway\(\)'   "$INSTALL" || fail "no change_gateway() (menu 'modify gateway IP')"
grep -Eq '^restart_services\(\)' "$INSTALL" || fail "no restart_services() (menu 'restart')"
# Legacy change commands are TUI-only compatibility wrappers around the single
# transactional configuration/install path.
cb_fn="$(sed -n '/^change_base_domain()/,/^}/p' "$INSTALL")"
printf '%s' "$cb_fn" | grep -Fq 'full_install configure' || fail "change_base_domain bypasses transactional TUI configure"
cp_fn="$(sed -n '/^change_public_ip()/,/^}/p' "$INSTALL")"
printf '%s' "$cp_fn" | grep -Fq 'full_install configure' || fail "change_public_ip bypasses transactional TUI configure"
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
cg_fn="$(sed -n '/^change_gateway()/,/^}/p' "$INSTALL")"
printf '%s' "$cg_fn" | grep -Fq 'full_install configure' || fail "change_gateway bypasses transactional TUI configure"

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
printf '%s' "$aw_fn" | grep -Fq 'mihomo_controller_curl "/providers/rules/whitelist"' \
    || fail "apply_whitelist does not use the shared HTTPS controller helper"
printf '%s' "$aw_fn" | grep -Fq 'Authorization: Bearer' \
    || fail "apply_whitelist does not send the controller bearer secret"
grep -Fq 'http://127.0.0.1:9090' "$INSTALL" \
    && fail "installer still calls the plaintext mihomo controller"
mc_fn="$(sed -n '/^mihomo_controller_curl()/,/^}/p' "$INSTALL")"
printf '%s' "$mc_fn" | grep -Fq -- '--cacert' \
    || fail "mihomo_controller_curl does not verify the zash certificate"
printf '%s' "$mc_fn" | grep -Fq -- '--connect-to' \
    || fail "mihomo_controller_curl does not dial the configured loopback target"
printf '%s' "$mc_fn" | grep -Fq 'https://' \
    || fail "mihomo_controller_curl does not use HTTPS"
printf '%s' "$mc_fn" | grep -Eq -- '(^|[[:space:]])(-k|--insecure)([[:space:]]|$)' \
    && fail "mihomo_controller_curl must not disable TLS verification"
pmr_fn="$(sed -n '/^probe_mihomo_ready()/,/^}/p' "$INSTALL")"
printf '%s' "$pmr_fn" | grep -Fq 'mihomo_controller_curl "/version"' \
    || fail "probe_mihomo_ready must call mihomo_controller_curl for the TLS controller probe"
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
# It must not stop the live resolver/data plane. Legacy generic units are
# handled only by ownership-gated helpers.
printf '%s' "$cl_fn" | grep -Eq 'systemctl (stop|disable --now) (5gpn-dns|xray)' \
    && fail "clean_previous_install must not stop the running 5gpn-dns/xray"
printf '%s' "$cl_fn" | sed -n '/for unit in/,/done/p' | grep -Eq '5gpn-dns\.service' \
    && fail "clean_previous_install's legacy stop-loop must not include the live 5gpn-dns unit"
printf '%s' "$cl_fn" | grep -Fq 'remove_legacy_xray' \
    || fail "clean_previous_install does not use ownership-gated Xray teardown"
printf '%s' "$cl_fn" | grep -Fq 'BASE_OWNERSHIP_MARKER' \
    || fail "runtime cleanup is not ownership-marker gated"
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
# ensure_cf_token accepts only a saved credential or TUI input.
grep -Eq '^ensure_cf_token\(\)' "$INSTALL" \
    || fail "no ensure_cf_token() (credential helper called before certbot in the issuance branch)"
ect_fn="$(sed -n '/^ensure_cf_token()/,/^}/p' "$INSTALL")"
printf '%s' "$ect_fn" | grep -Fq 'has_valid_cf_credential' \
    || fail "ensure_cf_token does not check has_valid_cf_credential (reuse path)"
printf '%s' "$ect_fn" | grep -Eq 'CF_API_TOKEN|CLOUDFLARE_API_TOKEN' \
    && fail "ensure_cf_token still accepts headless environment credentials"
printf '%s' "$ect_fn" | grep -Eq 'ask_secret.*\|\| true' \
    || fail "ensure_cf_token's ask_secret is not guarded with || true (cancel aborts under set -e)"
printf '%s' "$ect_fn" | grep -Eq '\[\[[^]]*-t 0' \
    || fail "ensure_cf_token does not gate the interactive prompt on a TTY ([[ -t 0 ]])"
printf '%s' "$ect_fn" | grep -Fq 'shell environment tokens are not accepted' \
    || fail "ensure_cf_token noninteractive error does not explain TUI-only input"
# Directory creation and reuse go through the symlink/owner/mode safety gate.
ead_fn="$(sed -n '/^ensure_acme_dir()/,/^}/p' "$INSTALL")"
ads_fn="$(sed -n '/^acme_dir_safe()/,/^}/p' "$INSTALL")"
printf '%s' "$ect_fn" | grep -Fq 'ensure_acme_dir || return 1' \
    || fail "ensure_cf_token bypasses the protected ACME directory helper"
printf '%s' "$ead_fn" | grep -Fq 'install -d -o root -g root -m 0700' \
    || fail "ensure_acme_dir does not create a root-owned mode-0700 directory"
printf '%s' "$ads_fn" | grep -Fq '! -L "$ACME_DIR"' \
    || fail "ACME directory safety gate does not reject symlinks"
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
printf '%s' "$wcf_fn" | grep -Fq 'ensure_acme_dir || return 1' \
    || fail "write_cf_credential bypasses the protected ACME directory helper"
printf '%s' "$wcf_fn" | grep -Eq 'mktemp.*\|\|' \
    || fail "write_cf_credential: mktemp assignment is not guarded with || (silent failure under errexit suppression)"
printf '%s' "$wcf_fn" | grep -Fq 'trailing newline' \
    || fail "write_cf_credential: CR/LF rejection error does not mention 'trailing newline' (operator hint missing)"
printf '%s' "$ect_fn" | grep -Fq 'ensure_acme_dir || return 1' \
    || fail "ensure_cf_token bypasses the protected ACME directory helper"
# install_cert must contain the anchored call, not just a comment referencing ensure_cf_token.
printf '%s' "$ic_fn" | grep -Fq 'ensure_cf_token || return 1' \
    || fail "install_cert: issuance branch must contain 'ensure_cf_token || return 1' (anchored call, not just a comment)"

# --- UP-4 Task 8 (2026-07-15 policy/mihomo decoupling): strong zash secret +
# full-config mihomo seed, no daemon-owned marker regions. ---
MIHOMO_TMPL="$ROOT/etc/mihomo/config.yaml.tmpl"
[ -f "$MIHOMO_TMPL" ] || fail "etc/mihomo/config.yaml.tmpl does not exist"
grep -Fq 'external-controller: ""' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: plaintext controller must stay disabled"
grep -Fq 'external-controller-tls: 127.0.0.1:9090' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing TLS controller listener"
grep -Fq '/etc/5gpn/cert/zash/fullchain.pem' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing zash certificate path"
grep -Fq '/etc/5gpn/cert/zash/privkey.pem' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing zash private key path"
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
grep -Fq 'DOMAIN,__CONSOLE_DOMAIN__,DIRECT'     "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: public console is not routed directly"
grep -Fq '__PROFILE_DOMAIN__' "$MIHOMO_TMPL" \
    && fail "etc/mihomo/config.yaml.tmpl: retired profile SNI remains"
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
grep -Fq 'DNS_CONSOLE_DOMAIN=${CONSOLE_DOMAIN}' "$INSTALL" \
    || fail "dns.env does not persist DNS_CONSOLE_DOMAIN"
grep -Eq '^verify_console_dns\(\)' "$INSTALL" \
    || fail "install.sh has no fail-closed public console A-record verification"

# seed_policy_defaults no longer seeds egress.json/egress-nodes.enc or passes --egress-out.
spd_fn="$(sed -n '/^seed_policy_defaults()/,/^}/p' "$INSTALL")"
printf '%s' "$spd_fn" | grep -Fq 'egress.json' \
    && fail "seed_policy_defaults must not seed egress.json (structured egress model removed)"
printf '%s' "$spd_fn" | grep -Fq -- '--egress-out' \
    && fail "seed_policy_defaults must not pass --egress-out (flag removed from --seed-defaults)"

[ $rc -eq 0 ] && echo "install policy: PASS"
exit $rc
