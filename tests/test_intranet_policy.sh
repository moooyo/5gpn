#!/usr/bin/env bash
# Policy assertions for the single-config-file model + cert-mode surface
# (2026-07: /etc/5gpn/dns.env is the ONE source of truth — env override > dns.env
# value > default, NO per-key .state files). Cert modes are cloudflare | debug only
# (http-01 / dns-01-generic / import removed). ONE base domain, ONE mandatory
# wildcard lineage deployed to dot/web/zash role dirs (2026-07-14). The host
# nftables firewall management was REMOVED — this file also locks that.
# Pure grep/sed — runs on the dev box under Git Bash; also the CI test job.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"
IOSGEN="$ROOT/scripts/gen-ios-profile.sh"

# ===== No host firewall management (removed 2026-07-10) =====
[ -e "$ROOT/scripts/setup-firewall.sh" ] && fail "scripts/setup-firewall.sh must stay removed"
grep -Eq 'DNS_PUBLIC_INGRESS="\$\{DNS_PUBLIC_INGRESS' "$INSTALL" \
    && fail "install.sh: DNS_PUBLIC_INGRESS knob must stay removed (no firewall to scope)"
grep -Eq 'SETUP_FIREWALL="\$\{SETUP_FIREWALL' "$INSTALL" \
    && fail "install.sh: SETUP_FIREWALL knob must stay removed (no firewall to apply)"
grep -Eq 'DNS_PLAIN53' "$INSTALL" \
    && fail "install.sh: DNS_PLAIN53 knob must stay removed (plain :53 listener is gone entirely)"
grep -Eq 'DNS_CLIENT_NET=\$\{CLIENT_NET\}' "$INSTALL" \
    && fail "install.sh: dns.env must not emit DNS_CLIENT_NET (in-process IP allowlist removed)"
# Upgrade path: a legacy ruleset must be flushed, and stale removed-feature keys
# must NOT be carried over into the rewritten dns.env.
grep -Eq '^remove_legacy_firewall\(\)' "$INSTALL" \
    || fail "install.sh: no remove_legacy_firewall() upgrade cleanup"
grep -Fq 'removed_keys=' "$INSTALL" \
    || fail "install.sh: write_dns_env has no removed-keys drop list (stale DoH/firewall knobs would be carried forever)"

# ===== Cert modes: only cloudflare | debug (http-01 / dns-01-generic / import removed) =====
grep -Eq 'CERT_MODE must be cloudflare or debug' "$INSTALL" \
    || fail "install.sh: CERT_MODE is not validated to cloudflare|debug (http-01/dns-01/import must be rejected)"
grep -Eq '== "http-01"|== "dns-01"|== "import"|IMPORT_CERT:-|CERTBOT_DNS_PLUGIN=|--standalone' "$INSTALL" \
    && fail "install.sh: still has removed cert-mode CODE (http-01 / dns-01 / import / CERTBOT_DNS / IMPORT_CERT / --standalone branches)"

# ===== One base domain, one wildcard, THREE role cert dirs =====
grep -Fq 'DOT_CERT_DIR="${DNS_CERT_DIR}/dot"' "$INSTALL" \
    || fail "install.sh: no DOT_CERT_DIR role dir (/etc/5gpn/cert/dot)"
grep -Fq 'WEB_CERT_DIR="${DNS_CERT_DIR}/web"' "$INSTALL" \
    || fail "install.sh: no WEB_CERT_DIR role dir (/etc/5gpn/cert/web)"
grep -Fq 'ZASH_CERT_DIR="${DNS_CERT_DIR}/zash"' "$INSTALL" \
    || fail "install.sh: no ZASH_CERT_DIR role dir (/etc/5gpn/cert/zash)"
grep -Fq 'DNS_WEB_CERT=${WEB_CERT_DIR}/fullchain.pem' "$INSTALL" \
    || fail "install.sh: dns.env does not point DNS_WEB_CERT at the web role dir"
grep -Fq 'DNS_CERT=${DOT_CERT_DIR}/fullchain.pem' "$INSTALL" \
    || fail "install.sh: dns.env does not point DNS_CERT at the dot role dir"
# full_install must provision the ONE wildcard lineage for the base domain.
grep -Eq '^[[:space:]]*install_cert "\$BASE_DOMAIN"' "$INSTALL" \
    || fail "install.sh: full_install does not issue the single wildcard cert via install_cert \$BASE_DOMAIN"
grep -Eq '^deploy_cert_roles\(\)' "$INSTALL" \
    || fail "install.sh: no deploy_cert_roles() (copies the wildcard to dot/web/zash)"

# ===== CERT_MODE=debug — self-signed WILDCARD + dismantles cloudflare renewal machinery =====
dbg="$(sed -n '/^issue_selfsigned_wildcard()/,/^}/p' "$INSTALL")"
printf '%s' "$dbg" | grep -Fq 'openssl req -x509' \
    || fail "install.sh: debug mode does not generate a self-signed cert (openssl req -x509)"
printf '%s' "$dbg" | grep -Fq 'remove_owned_renew_hook' \
    || fail "install.sh: debug branch does not ownership-gate deploy-hook removal"
printf '%s' "$dbg" | grep -Fq 'remove_owned_renewal_automation' \
    || fail "install.sh: debug branch does not ownership-gate renewal-unit removal"
printf '%s' "$dbg" | grep -Eq 'systemctl disable --now 5gpn-certbot-renew|rm -f.*/5gpn-certbot-renew' \
    && fail "install.sh: debug branch mutates renewal units outside the ownership gate"

# ===== cloudflare DNS-01 issuance — no :80, no xray, no --standalone =====
ic="$(sed -n '/^install_cert()/,/^}/p' "$INSTALL")"
printf '%s' "$ic" | grep -Eq 'certbot_args=\(certonly --cert-name .*--dns-cloudflare' \
    || fail "install.sh: install_cert does not use certbot --dns-cloudflare (Cloudflare DNS-01)"
printf '%s' "$ic" | grep -Fqe '-d "*.${base}"' \
    || fail "install.sh: install_cert does not request a WILDCARD (-d \"*.\${base}\")"
printf '%s' "$ic" | grep -Fq 'systemctl stop xray' \
    && fail "install.sh: install_cert must not stop xray (DNS-01 needs no :80 port-coordination)"
printf '%s' "$ic" | grep -Fqe '--standalone' \
    && fail "install.sh: install_cert must not use certbot --standalone (:80 challenge removed)"
# cloudflare.ini must be protected 0600 — chmod must happen inside ensure_cf_token.
ect_fn_it="$(sed -n '/^ensure_cf_token()/,/^}/p' "$INSTALL")"
printf '%s' "$ect_fn_it" | grep -Eq 'chmod 0?600' \
    || fail "install.sh: ensure_cf_token does not set mode 0600 on cloudflare.ini"
# Apex SAN must appear alongside the wildcard in the certbot invocation.
printf '%s' "$ic" | grep -Fqe '-d "${base}"' \
    || fail "install.sh: install_cert does not request the apex SAN (-d \"\${base}\")"
# ensure_cf_token must be called BEFORE construction/execution of certbot args.
# Anchor on the actual call line, not a comment that also contains the name.
_ect_line="$(printf '%s' "$ic" | grep -n 'ensure_cf_token || return 1' | head -1 | cut -d: -f1)"
_cb_line="$(printf '%s'  "$ic" | grep -n 'certbot_args=(certonly' | head -1 | cut -d: -f1)"
[ -z "${_ect_line:-}" ] && fail "install.sh: install_cert does not contain 'ensure_cf_token || return 1' (anchored call missing)"
[ -z "${_cb_line:-}" ] && fail "install.sh: install_cert does not construct scoped certbot certonly arguments"
[ -n "${_ect_line:-}" ] && [ "${_ect_line}" -ge "${_cb_line}" ] && \
    fail "install.sh: ensure_cf_token must appear BEFORE certbot certonly in install_cert"
# No HTTP-01 or webroot-based flags in the certbot issuance branch.
printf '%s' "$ic" | grep -Eq -- '--http-01-port|--webroot' \
    && fail "install.sh: install_cert must not use HTTP-01/webroot certbot flags"
# write_cf_credential owns CR/LF rejection, atomic write, and temp cleanup for both callers.
# Checking it here covers ensure_cf_token's env-var path (finding 3) and finding 5.
wcf_fn_it="$(sed -n '/^write_cf_credential()/,/^}/p' "$INSTALL")"
printf '%s' "$wcf_fn_it" | grep -Fq '$'"'"'\r'"'"'' \
    || fail "install.sh: write_cf_credential does not reject CR (covers ensure_cf_token env-var path)"
printf '%s' "$wcf_fn_it" | grep -Fq '$'"'"'\n'"'"'' \
    || fail "install.sh: write_cf_credential does not reject LF (covers ensure_cf_token env-var path)"
# Atomic write: same-dir mktemp + mv rename.
printf '%s' "$wcf_fn_it" | grep -Fq 'mktemp' \
    || fail "install.sh: write_cf_credential does not stage atomically (mktemp missing)"
# Temp-file cleanup on failure — explicit rm -f per step, no broad trap (finding 5).
printf '%s' "$wcf_fn_it" | grep -Fq 'rm -f' \
    || fail "install.sh: write_cf_credential does not clean up temp on failure (rm -f missing)"
# Both callers must delegate to write_cf_credential — no duplicated write logic (finding 4).
sct_fn="$(sed -n '/^set_cf_token()/,/^}/p' "$INSTALL")"
printf '%s' "$sct_fn" | grep -Fq 'write_cf_credential' \
    || fail "install.sh: set_cf_token does not delegate to write_cf_credential"
printf '%s' "$ect_fn_it" | grep -Fq 'write_cf_credential' \
    || fail "install.sh: ensure_cf_token does not delegate to write_cf_credential"
# Errexit-suppression hardening: unguarded commands inside these helpers must carry
# explicit || guards so they fail loudly when called with || (which suppresses set -e).
printf '%s' "$wcf_fn_it" | grep -Eq 'install -d.*\|\|' \
    || fail "install.sh: write_cf_credential install -d is not guarded with || (silent failure under errexit suppression)"
printf '%s' "$wcf_fn_it" | grep -Eq 'mktemp.*\|\|' \
    || fail "install.sh: write_cf_credential mktemp is not guarded with || (silent failure under errexit suppression)"
printf '%s' "$ect_fn_it" | grep -Eq 'install -d.*\|\|' \
    || fail "install.sh: ensure_cf_token install -d is not guarded with || (silent failure under errexit suppression)"
printf '%s' "$ect_fn_it" | grep -Eq 'chmod 0?600.*\|\|' \
    || fail "install.sh: ensure_cf_token chmod 0600 reuse path is not guarded with || (prints success on chmod failure)"
grep -Fq 'systemctl stop xray' "$INSTALL" \
    && fail "install.sh: no cert-flow reference to 'systemctl stop xray' may remain anywhere"
# No firewall to open — the old open_port80/close_port80 nft dance must stay gone.
grep -Eq 'open_port80|close_port80' "$INSTALL" \
    && fail "install.sh: open_port80/close_port80 must stay removed (no host firewall)"

# ===== renew-hook.sh — deploys the ONE wildcard to all THREE role dirs =====
RENEW="$ROOT/scripts/renew-hook.sh"
grep -Fq 'RENEWED_LINEAGE' "$RENEW" || fail "renew-hook.sh: does not use RENEWED_LINEAGE"
grep -Fq 'DNS_BASE_DOMAIN' "$RENEW" || fail "renew-hook.sh: does not match the lineage to DNS_BASE_DOMAIN"
grep -Fq 'roles=(dot web zash)' "$RENEW" \
    || fail "renew-hook.sh: does not deploy to all dot/web/zash role dirs"
grep -Fq 'validate_cert_pair' "$RENEW" \
    || fail "renew-hook.sh: does not validate SANs and the certificate/private-key pair"
grep -Fq 'mktemp "${dest}/.fullchain.pem.XXXXXX"' "$RENEW" \
    || fail "renew-hook.sh: certificate publication is not same-directory staged"
grep -Fq 'mv -f -- "${cert_tmps[$i]}"' "$RENEW" \
    || fail "renew-hook.sh: staged certificate is not atomically renamed into place"
grep -Fq 'mihomo reloads the controller certificate files automatically' "$RENEW" \
    || fail "renew-hook.sh: missing mihomo controller certificate hot-reload contract"
grep -Eq 'systemctl (restart|reload) mihomo' "$RENEW" \
    && fail "renew-hook.sh: must not restart/reload mihomo for controller certificate renewal"
grep -iq 'xray' "$RENEW" && fail "renew-hook.sh: must not reference xray (mihomo is the data plane)"

# ===== gen-ios-profile.sh — unsigned profile fails CLOSED =====
fc="$(sed -n '/sign_ok -ne 1/,/^fi$/p' "$IOSGEN")"
grep -Fq 'ALLOW_UNSIGNED_PROFILE' "$IOSGEN" \
    && fail "gen-ios-profile.sh: caller environment can still allow unsigned profiles"
printf '%s' "$fc" | grep -Fq 'rm -f "$profile_path"' \
    || fail "gen-ios-profile.sh: unsigned profile is not removed (must fail closed, not serve tamperable)"
printf '%s' "$fc" | grep -Eq 'exit 1' \
    || fail "gen-ios-profile.sh: refusing an unsigned profile must exit non-zero"
# The landing page must remain compatible with the console's strict CSP and its
# profile link/probe must stay under the mounted /ios/ prefix (relative URL).
grep -Fq 'href="ios-dot.mobileconfig"' "$IOSGEN" \
    || fail "gen-ios-profile.sh: profile download URL must be relative to /ios/"
grep -Fq 'fetch("ios-dot.mobileconfig"' "$IOSGEN" \
    || fail "gen-ios-profile.sh: availability probe must use the real relative profile URL"
grep -Fq 'href="ios.css"' "$IOSGEN" \
    || fail "gen-ios-profile.sh: landing CSS must be an external same-origin asset"
grep -Fq 'src="ios.js"' "$IOSGEN" \
    || fail "gen-ios-profile.sh: landing JS must be an external same-origin asset"
grep -Eq '^[[:space:]]*<(style|script)>' "$IOSGEN" \
    && fail "gen-ios-profile.sh: inline style/script blocks violate the production CSP"

# ===== rotate_token — restart, never reload/SIGHUP =====
rt="$(sed -n '/^rotate_token()/,/^}/p' "$INSTALL")"
printf '%s' "$rt" | grep -Fq 'systemctl restart 5gpn-dns' \
    || fail "install.sh: rotate_token must 'systemctl restart 5gpn-dns' (token read at startup)"
printf '%s' "$rt" | grep -Eq 'systemctl reload 5gpn-dns|kill -HUP' \
    && fail "install.sh: rotate_token must not use reload/SIGHUP (insufficient for a token change)"

# ===== Single config file: dns.env is the ONE source of truth =====
# There must be NO per-key .state file read/write (a bare `.cache_size` mention in
# a comment is fine; a `$CONF_DIR/.<key>` path is not).
grep -Eq 'CONF_DIR\}?/\.(gateway_ip|public_ip|domain|cert_mode|client_net|dot_rate|dot_burst|dns_public_ingress|cache_size|xray_resolver|certbot)' "$INSTALL" \
    && fail "install.sh still reads/writes a per-key .state file (config must be the single dns.env)"
# full_install resolves persisted config or collects it through the TUI.
grep -Eq '^cfg_get\(\)' "$INSTALL" \
    || fail "install.sh: no cfg_get() single-source reader"
grep -Eq '^load_persisted_install_config\(\)' "$INSTALL" \
    || fail "install.sh: persisted install configuration loader missing"
grep -Eq '^configure_install_tui\(\)' "$INSTALL" \
    || fail "install.sh: TUI configuration wizard missing"
grep -Eq '^clear_external_config_env\(\)' "$INSTALL" \
    || fail "install.sh: caller environment is not explicitly discarded"
# PUBLIC_IP retains TUI auto-detection.
grep -Eq '^get_public_ip\(\)' "$INSTALL" \
    || fail "install.sh: no get_public_ip() auto-detection"
# ===== Persisted resolver is validated BEFORE install_files =====
resolver_line="$(grep -n '^[[:space:]]*resolve_install_configuration ' "$INSTALL" | tail -1 | cut -d: -f1)"
files_line="$(grep -n '^[[:space:]]*install_files$' "$INSTALL" | tail -1 | cut -d: -f1)"
if [ -z "${resolver_line:-}" ] || [ -z "${files_line:-}" ]; then
    fail "install.sh: could not locate configuration resolution or install_files"
elif [ "$resolver_line" -ge "$files_line" ]; then
    fail "install.sh: persisted/TUI configuration must be resolved before publication"
fi

# ===== The mihomo config must be rendered AFTER configuration resolution =====
webdom_line="$(grep -nE '^[[:space:]]*render_mihomo_config( --reset)?$' "$INSTALL" | tail -1 | cut -d: -f1)"
domains_line="$resolver_line"
if [ -z "${webdom_line:-}" ] || [ -z "${domains_line:-}" ]; then
    fail "install.sh: could not locate render_mihomo_config or configuration resolution"
elif [ "$webdom_line" -le "$domains_line" ]; then
    fail "install.sh: render_mihomo_config must run after validated TUI/persisted configuration"
fi

# ===== CPU arch guard — amd64-only prebuilts must refuse other arches early =====
grep -Eq '^check_arch\(\)' "$INSTALL" \
    || fail "install.sh: no check_arch() guard (ARM box would install to the end then hit exec format error)"
grep -Eq '^[[:space:]]*check_arch$' "$INSTALL" \
    || fail "install.sh: check_arch is defined but never called in full_install"

# ===== DNS_CACHE_SIZE — the RAM-derived cache size must reach dns.env =====
grep -Eq 'DNS_CACHE_SIZE=\$\{CACHE_SIZE' "$INSTALL" \
    || fail "install.sh: write_dns_env hardcodes DNS_CACHE_SIZE (must interpolate \${CACHE_SIZE} so the memory-derived size takes effect)"
grep -Fq 'CACHE_SIZE="$(cfg_get DNS_CACHE_SIZE)"' "$INSTALL" \
    || fail "install.sh: CACHE_SIZE not loaded from persisted dns.env"

[ $rc -eq 0 ] && echo "intranet policy: PASS"
exit $rc
