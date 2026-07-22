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
RELEASE="$ROOT/.github/workflows/release.yml"

# --- Production renewal is unattended through one mode-aware, cert-name-scoped
# helper. Cloudflare never needs a :80 handoff; due HTTP-01 renewals coordinate
# mihomo inside the helper. The installer must not create global stop/start hooks.
[ -f "$CERT_RENEW" ] || fail "mode-aware certificate renewal helper is missing"
grep -Eq 'install -d.*renewal-hooks/pre'  "$INSTALL" && fail "install.sh must not create a global pre-renewal hook dir"
grep -Eq 'install -d.*renewal-hooks/post' "$INSTALL" && fail "install.sh must not create a global post-renewal hook dir"
grep -Fq 'systemctl stop xray'  "$INSTALL" && fail "certificate flows must never stop xray"
grep -Fq 'systemctl start xray' "$INSTALL" && fail "certificate flows must never start xray"
grep -Fiq 'xray' "$CERT_RENEW" && fail "certificate renewal helper must not reference xray"

# The persistent timer and the Telegram bot must both enter through the helper,
# never invoke an unscoped `certbot renew` of every host lineage.
renew_auto_fn="$(sed -n '/^install_renewal_automation()/,/^}/p' "$INSTALL")"
grep -Fq 'certbot_lineage_owned_by_5gpn "$base"' <<<"$renew_auto_fn" \
    || fail "public renewal automation is not restricted to a provenance-owned lineage"
grep -Fq 'acquire_install_gate || return 1' "$CERT_RENEW" \
    || fail "public renewal can enter the installer certificate-lock handoff window"
grep -Fq '5gpn-certbot-renew.timer' <<<"$renew_auto_fn" || fail "no certificate renewal timer installed"
grep -Fq 'Persistent=true' <<<"$renew_auto_fn" || fail "renewal timer not Persistent (missed runs will not catch up)"
grep -Fq 'ExecStart=/opt/5gpn/scripts/cert-renew.sh --quiet' <<<"$renew_auto_fn" \
    || fail "renewal timer does not invoke the unified certificate helper"
grep -Fq '# 5gpn-unit-id: 5gpn-certbot-renew.service:v1' <<<"$renew_auto_fn" \
    || fail "renewal service has no exact ownership marker"
grep -Fq '# 5gpn-unit-id: 5gpn-certbot-renew.timer:v1' <<<"$renew_auto_fn" \
    || fail "renewal timer has no exact ownership marker"
grep -Fq 'TimeoutStartSec=30min' <<<"$renew_auto_fn" \
    || fail "renewal service timeout cannot cover the 1.1.1.1 wait plus Certbot"
grep -Fq 'TimeoutStopSec=2min' <<<"$renew_auto_fn" \
    || fail "renewal service does not leave a bounded TERM/restore window"
grep -Eq 'ExecStart=.*certbot renew' <<<"$renew_auto_fn" \
    && fail "renewal timer bypasses the scoped helper with direct certbot renew"
grep -Fq 'intercept-cert-renew.sh' <<<"$renew_auto_fn" \
    && fail "public renewal failure can still skip the coupled interception leaf renewal"
grep -Fq 'EnvironmentFile=/etc/5gpn/dns.env' <<<"$renew_auto_fn" \
    && fail "renewal service imports arbitrary persisted keys into a root shell environment"
head -1 "$CERT_RENEW" | grep -Fxq '#!/bin/bash' \
    || fail "renewal helper uses PATH-dependent /usr/bin/env for its root shell"
head -2 "$ROOT/scripts/renew-hook.sh" | grep -Fxq '# 5gpn-renew-hook-id: deploy-v1' \
    || fail "certificate deploy hook has no exact ownership marker"
renew_owned_fn="$(sed -n '/^renew_hook_owned()/,/^}/p' "$INSTALL")"
grep -Fq '# 5gpn-renew-hook-id: deploy-v1' <<<"$renew_owned_fn" \
    || fail "deploy-hook ownership check does not require the exact current marker"
grep -Fq 'renewed 5gpn WILDCARD lineage' <<<"$renew_owned_fn" \
    && fail "deploy-hook ownership still accepts the superseded wildcard text"
grep -Fq '"systemctl", "start", "5gpn-certbot-renew.service"' "$BOT_OPS" \
    || fail "Telegram renewal does not start the fixed scoped renewal service"
grep -Fq 'systemd-run' "$BOT_OPS" \
    && fail "Telegram renewal must not create an operator-controlled transient root unit"
grep -Fq 'cf_credential_safe' "$CERT_RENEW" \
    || fail "Cloudflare renewal can follow an unsafe credential symlink or permissions drift"

unit_owned_fn="$(sed -n '/^unit_file_owned_by_5gpn()/,/^}/p' "$INSTALL")"
grep -Fq '# 5gpn-unit-id:' <<<"$unit_owned_fn" \
    || fail "systemd ownership does not require an exact unit marker"
grep -Fq 'Description=5gpn' <<<"$unit_owned_fn" \
    && fail "systemd ownership still trusts a display description"
grep -Fxq '# 5gpn-unit-id: 5gpn-dns.service:v1' "$ROOT/etc/systemd/5gpn-dns.service" \
    || fail "5gpn-dns unit lacks its exact ownership marker"
grep -Fxq '# 5gpn-unit-id: mihomo.service:v1' "$ROOT/etc/systemd/mihomo.service" \
    || fail "mihomo unit lacks its exact ownership marker"
grep -Fxq '# 5gpn-unit-id: 5gpn-journal@.service:v1' "$ROOT/etc/systemd/5gpn-journal@.service" \
    || fail "journal exporter unit lacks its exact ownership marker"

# Install/configure ordering: resolve the TUI/persisted selection, wait for the
# fixed-resolver DNS gate, and only then publish or issue certificate material.
full_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
cfg_line="$(grep -n 'resolve_install_configuration' <<<"$full_fn" | head -1 | cut -d: -f1)"
dns_line="$(grep -n '^[[:space:]]*verify_console_dns' <<<"$full_fn" | head -1 | cut -d: -f1)"
cert_line="$(grep -n '^[[:space:]]*install_cert "\$BASE_DOMAIN"' <<<"$full_fn" | head -1 | cut -d: -f1)"
lock_line="$(grep -n '^[[:space:]]*acquire_install_cert_lock' <<<"$full_fn" | head -1 | cut -d: -f1)"
capture_line="$(grep -n '^[[:space:]]*capture_install_rollback' <<<"$full_fn" | head -1 | cut -d: -f1)"
if [[ -z "$cfg_line" || -z "$dns_line" || -z "$cert_line" \
   || -z "$lock_line" || -z "$capture_line" \
   || "$cfg_line" -ge "$dns_line" || "$dns_line" -ge "$lock_line" \
   || "$lock_line" -ge "$capture_line" || "$capture_line" -ge "$cert_line" ]]; then
    fail "configuration/DNS-gate/certificate issuance order is not fail-closed"
fi
grep -Fq '    start_services_with_cert_lock_handoff' <<<"$full_fn" \
    || fail "full install does not hand the certificate lock to sidecar startup"
grep -Fqx '    start_services' <<<"$full_fn" \
    && fail "full install still starts the sidecar while holding the certificate lock"

# ===== iOS profile is served at the web console's public /ios/ path; the
# standalone :8111 responder and the host firewall are both gone =====
grep -Eq 'IOS_PORT=' "$INSTALL" && fail "install.sh must not reference IOS_PORT (:8111 responder removed)"
grep -Fq '/ios/ios-dot.mobileconfig' "$INSTALL" \
    || fail "install.sh must print the /ios/ profile URL (web console path)"
# First install is TUI-only; reinstall reads the persisted dns.env and caller
# environment is explicitly cleared.
grep -Eq '^configure_install_tui\(\)' "$INSTALL" || fail "no first-install TUI configuration wizard"
grep -Eq '^load_persisted_install_config\(\)' "$INSTALL" || fail "no persisted installer config loader"
grep -Eq '^validate_dns_env_schema\(\)' "$INSTALL" || fail "no strict persisted dns.env schema validator"
grep -Fq 'unsupported key' "$INSTALL" || fail "persisted dns.env does not reject unknown keys"
grep -Eq '^clear_external_config_env\(\)' "$INSTALL" || fail "caller environment is not cleared"
grep -Fq "First install/configuration requires an attached TTY" "$INSTALL" \
    || fail "headless first install does not fail closed"
grep -Eq "prompt_default .*网关|prompt_default .*Gateway" "$INSTALL" || fail "TUI has no gateway prompt"
grep -Fq 'Pre-v5 dns.env contains retired DNS_EGRESS_RESOLVER' "$INSTALL" \
    || fail "installer does not reject the retired single egress resolver explicitly"
grep -Eq '^[[:space:]]*DNS_EGRESS_RESOLVER=' "$INSTALL" \
    && fail "installer still persists the retired single egress resolver"
full_install_fn="$(sed -n '/^full_install()/,/^}/p' "$INSTALL")"
printf '%s' "$full_install_fn" | grep -Fq 'echo "Console token: ${DNS_API_TOKEN}"' \
    && ! printf '%s' "$full_install_fn" | grep -Fq 'token_was_present' \
    || fail "successful interactive installs do not always show the current console token"

# --- Frontend shipped separately + served from disk (not go:embed) ---
grep -Eq 'install_web'          "$INSTALL" || fail "no install_web() to fetch the 5gpn-web tarball"
grep -Eq '5gpn-web-.*\.tar\.gz' "$INSTALL" || fail "install_web does not fetch the 5gpn-web tarball asset"
grep -Eq 'DNS_WEB_DIR'          "$INSTALL" || fail "DNS_WEB_DIR not wired in install.sh"

# --- `5gpn` management command: installed on PATH, backed by a copy of install.sh ---
grep -Eq '^install_manage_cli\(\)' "$INSTALL" || fail "no install_manage_cli() (the 5gpn management command)"
grep -Eq '^[[:space:]]*install_manage_cli( \|\| return 1)?$' "$INSTALL" || fail "install_manage_cli defined but never called in full_install"
grep -Fq '/usr/local/bin/5gpn' "$INSTALL" || fail "5gpn launcher not written to /usr/local/bin/5gpn"
grep -Fq 'exec bash "$BK" menu' "$INSTALL" || fail "5gpn launcher does not open the management menu with no args"
# The current menu, restart, and transactional configure operations are dispatchable.
for tok in 'menu)' 'restart)' 'configure)'; do
    grep -Fq -e "$tok" "$INSTALL" || fail "install.sh dispatch missing case: $tok"
done
grep -Eq -- '--(configure|menu|status|restart|reload-rules|add-allow|del-allow|ios|setup-tgbot|rotate-token|set-cf-token|mihomo-reset|uninstall|help)\)' "$INSTALL" \
    && fail "install.sh still accepts a flag-style command alias"
grep -Eq '^manage_menu\(\)'      "$INSTALL" || fail "no manage_menu() TUI"
grep -Eq '^restart_services\(\)' "$INSTALL" || fail "no restart_services() (menu 'restart')"
grep -Eq '^require_command_arity\(\)' "$INSTALL" || fail "commands do not reject unsupported argv shapes"
# Base-domain install flow: ONE base domain, the three service subdomains
# (console./zash./dot.<base>) auto-derived by derive_domains.
grep -Eq '^derive_domains\(\)' "$INSTALL" || fail "no derive_domains() (single subdomain derivation)"
dd_fn="$(sed -n '/^derive_domains()/,/^}/p' "$INSTALL")"
printf '%s' "$dd_fn" | grep -Fq 'console.' || fail "derive_domains does not derive console.<base>"
printf '%s' "$dd_fn" | grep -Fq 'zash.'    || fail "derive_domains does not derive zash.<base>"
printf '%s' "$dd_fn" | grep -Fq 'dot.'     || fail "derive_domains does not derive dot.<base>"
grep -Eq '^load_persisted_domains\(\)' "$INSTALL" || fail "no persisted base-domain derivation helper"
grep -Eq 'DNS_(DOMAIN|WEB_DOMAIN|CONSOLE_DOMAIN|ZASH_DOMAIN)=' "$INSTALL" \
    && fail "installer still persists a redundant derived-domain key"

# --- Task 4: panel whitelist.txt TUI management + live controller refresh
# (out-of-band; never web-editable, no full config reload). ---
for tok in 'add-allow)' 'del-allow)'; do
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
printf '%s' "$aa_fn" | grep -Fq 'file="${MIHOMO_DIR}/whitelist.txt"' \
    || fail "add_allow_ip does not write MIHOMO_DIR/whitelist.txt"
printf '%s' "$aa_fn" | grep -Fq 'is_valid_ipv4_or_cidr' \
    || fail "add_allow_ip does not validate the current IPv4/CIDR format"
printf '%s' "$aa_fn" | grep -Fq 'apply_whitelist' \
    || fail "add_allow_ip does not call apply_whitelist (live refresh)"
da_fn="$(sed -n '/^del_allow_ip()/,/^}/p' "$INSTALL")"
printf '%s' "$da_fn" | grep -Eq 'ask_text .*\|\| true\)"' \
    || fail "del_allow_ip's ask_text capture is not guarded with || true (cancel would abort under set -e)"
printf '%s' "$da_fn" | grep -Fq 'file="${MIHOMO_DIR}/whitelist.txt"' \
    || fail "del_allow_ip does not edit MIHOMO_DIR/whitelist.txt"
printf '%s' "$da_fn" | grep -Fq 'is_valid_ipv4_or_cidr' \
    || fail "del_allow_ip does not validate the current IPv4/CIDR format"
printf '%s' "$da_fn" | grep -Eq 'sed -i.*\$ip' \
    && fail "del_allow_ip still interpolates an entry into a sed regular expression"
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
printf '%s' "$pmr_fn" | grep -Fq 'local -a tcp_ports=(80 443)' \
    || fail "probe_mihomo_ready must always require the baseline TCP ports"
printf '%s' "$pmr_fn" | grep -Fq 'tcp_ports+=(5060 8080 8443)' \
    || fail "probe_mihomo_ready must conditionally require every extra seed TCP port"
printf '%s' "$pmr_fn" | grep -Fq '${MIHOMO_SEED_PORTS_REQUIRED:-0}' \
    || fail "probe_mihomo_ready must default alternate-port readiness to disabled"
printf '%s' "$pmr_fn" | grep -Fq 'local -a udp_ports=(443)' \
    || fail "probe_mihomo_ready must always require UDP :443"
printf '%s' "$pmr_fn" | grep -Fq 'udp_ports+=(5060)' \
    || fail "probe_mihomo_ready must conditionally require default-module UDP :5060"
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

# Publication is staged and rollback-capable without any old-release teardown.
grep -Eq '^stage_artifacts\(\)' "$INSTALL" || fail "release artifacts are not staged"
grep -Eq '^capture_install_rollback\(\)' "$INSTALL" || fail "install rollback snapshot is missing"
grep -Eq '^rollback_install\(\)' "$INSTALL" || fail "install rollback path is missing"
grep -Eq '^[[:space:]]*stage_artifacts( \|\| return 1)?$' "$INSTALL" || fail "full_install does not stage artifacts"
grep -Eq '^[[:space:]]*capture_install_rollback( \|\| return 1)?$' "$INSTALL" || fail "full_install does not capture rollback state"
grep -Eq '^remove_legacy_|^clean_previous_install\(\)' "$INSTALL" \
    && fail "installer still contains an old-release teardown helper"

# Official and beta publications share one gate but have disjoint tag,
# provenance, and GitHub release metadata boundaries.
grep -Fq 'required_branch=main' "$RELEASE" \
    || fail "official release tags are not tied to main"
grep -Fq 'required_branch=beta' "$RELEASE" \
    || fail "beta release tags are not tied to beta"
grep -Fq 'git merge-base --is-ancestor' "$RELEASE" \
    || fail "release workflow does not verify tag branch provenance"
grep -Fq 'prerelease: ${{ needs.classify.outputs.prerelease }}' "$RELEASE" \
    || fail "release workflow does not publish beta as a prerelease"
grep -Fq 'make_latest: ${{ needs.classify.outputs.make_latest }}' "$RELEASE" \
    || fail "release workflow does not protect the official latest pointer"
grep -Fq 'uses: ./.github/workflows/checks.yml' "$RELEASE" \
    || fail "release channels do not share the repository checks gate"
grep -Fq 'DNS_VERSION_DEFAULT=\"${GITHUB_REF_NAME}\"' "$RELEASE" \
    || fail "release installer bundle is not stamped to the exact tag"

# --- Certs are DELIBERATELY preserved (re-issuing an LE cert is rate-limited) ---
un_fn="$(sed -n '/^uninstall()/,/^}/p' "$INSTALL")"
printf '%s' "$un_fn" | grep -Fq '"$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"' \
    && printf '%s' "$un_fn" | grep -Fq '"$CONF_DIR" "$CONF_OWNERSHIP_MARKER" cert acme debug-cert' \
    || fail "uninstall --purge must use the owned-scope helper while preserving certificate state"
# The Cloudflare API-token dir must ALSO survive --purge: otherwise a reinstall
# with a still-valid cert (which needs no token) is fine, but a reinstall that
# DOES need to issue would hard-abort for a token wiped for no reason.
printf '%s' "$un_fn" | grep -Fq 'cert acme debug-cert' \
    || fail "uninstall --purge must preserve acme/ so the Cloudflare token survives"
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
grep -Fq '/etc/5gpn/cert/zash/current/fullchain.pem' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing zash certificate path"
grep -Fq '/etc/5gpn/cert/zash/current/privkey.pem' "$MIHOMO_TMPL" \
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
grep -Fq 'certificate: /etc/5gpn/cert/zash/current/fullchain.pem' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #1 (zash controller certificate path)"
grep -Fq 'private-key: /etc/5gpn/cert/zash/current/privkey.pem' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #1 (zash controller private-key path)"
grep -Fq '__MIHOMO_LISTENERS__'                 "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing dynamic listener placeholder"
grep -Fq 'target: %s:443'                       "$INSTALL" \
    || fail "install.sh: dynamic listener renderer missing gateway hostname target"
grep -Fq 'target: %s:8080'                      "$INSTALL" \
    || fail "install.sh: dynamic listener renderer missing :8080 hostname target"
grep -Fq 'target: %s:8443'                      "$INSTALL" \
    || fail "install.sh: dynamic listener renderer missing :8443 hostname target"
grep -Fq 'render_mihomo_listeners "$MIHOMO_LISTEN_IPS" "$CONSOLE_DOMAIN"' "$INSTALL" \
    || fail "install.sh: listener renderer is not passed the console hostname"
grep -Fq 'name: gateway%s'                       "$INSTALL" \
    || fail "install.sh: dynamic listener renderer missing gateway listener name"
grep -Fq 'udp://127.0.0.1:5354'                "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #3 (egress DNS broker)"
grep -Fq '__CONSOLE_DOMAIN__: 127.0.0.1'       "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #4 (console SNI hosts mapping)"
grep -Fq 'force-domain: [__CONSOLE_DOMAIN__]'  "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: console fallback does not force hostname sniffing"
grep -Fq '__ZASH_DOMAIN__:    127.0.0.2'        "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #5 (zash SNI hosts mapping)"
grep -Fq 'DOMAIN,__CONSOLE_DOMAIN__,DIRECT'     "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: public console is not routed directly"
grep -Fq '__PROFILE_DOMAIN__' "$MIHOMO_TMPL" \
    && fail "etc/mihomo/config.yaml.tmpl: retired profile SNI remains"
grep -Fq 'IP-CIDR,__GATEWAY_IP__/32,REJECT' "$MIHOMO_TMPL" \
    || fail "etc/mihomo/config.yaml.tmpl: missing invariant #6 (anti-loop guard)"

# render_mihomo_config generates a strong mixed secret (base64), not the old hex.
rmc_fn="$(sed -n '/^render_mihomo_config()/,/^}/p' "$INSTALL")"
printf '%s' "$rmc_fn" | grep -Fq 'MIHOMO_SEED_PORTS_REQUIRED=0' \
    || fail "render_mihomo_config must clear the in-process seed-port readiness flag on entry"
printf '%s' "$rmc_fn" | grep -Fq 'MIHOMO_SEED_PORTS_REQUIRED=1' \
    || fail "render_mihomo_config must require seed-port readiness after publishing a seed"
printf '%s' "$rmc_fn" | grep -Fq 'openssl rand -base64 24' \
    || fail "render_mihomo_config must generate the controller secret via openssl rand -base64 24 (strong mixed secret, design §5.1)"
printf '%s' "$rmc_fn" | grep -Fq 'openssl rand -hex 16' \
    && fail "render_mihomo_config must not generate the controller secret via the old openssl rand -hex 16"
printf '%s' "$rmc_fn" | grep -Fq 'mihomo_config_secret "$config"' \
    || fail "render_mihomo_config does not read back an existing secret across re-renders"
parser_guards="$(printf '%s' "$rmc_fn" | grep -Fc 'Existing mihomo controller secret could not be parsed safely.' || true)"
[[ "$parser_guards" == 2 ]] \
    || fail "render_mihomo_config must fail closed on secret parsing in preserve and reset paths"
mcs_fn="$(sed -n '/^mihomo_config_secret()/,/^}/p' "$INSTALL")"
printf '%s' "$mcs_fn" | grep -Fq '"$DNS_BIN" --print-mihomo-secret --config "$f"' \
    || fail "mihomo_config_secret must use the structural 5gpn-dns YAML reader"
printf '%s' "$mcs_fn" | grep -Eq 'sed|head -1' \
    && fail "mihomo_config_secret must not parse operator YAML as text"
grep -Fq -- '--print-mihomo-secret' "$ROOT/cmd/5gpn-dns/main.go" \
    || fail "5gpn-dns does not expose the installer-only mihomo secret reader"
printf '%s' "$rmc_fn" | grep -Fq 'Existing operator-owned mihomo config' \
    || fail "render_mihomo_config does not preserve an existing operator-owned config"
printf '%s' "$rmc_fn" | grep -Fq 'mktemp "${MIHOMO_DIR}/.config.yaml.' \
    || fail "render_mihomo_config does not stage a same-directory candidate"
printf '%s' "$rmc_fn" | grep -Fq 'mv -f -- "$candidate" "$config"' \
    || fail "render_mihomo_config does not atomically rename the validated candidate"

# Bootstrap and bind identities are independent/fail-closed.
grep -Fq 'DNS_MIHOMO_LISTEN_IPS=${MIHOMO_LISTEN_IPS}' "$INSTALL" \
    || fail "dns.env does not persist DNS_MIHOMO_LISTEN_IPS"
grep -Fq 'DNS_BASE_DOMAIN=${BASE_DOMAIN}' "$INSTALL" \
    || fail "dns.env does not persist the base domain"
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
