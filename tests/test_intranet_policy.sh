#!/usr/bin/env bash
# Policy assertions for the single-config-file model + cert-mode surface
# (2026-07: /etc/5gpn/dns.env is the ONE source of truth; caller environment is
# not configuration input and there are NO per-key .state files). Cert modes are
# cloudflare | http-01 | debug; generic DNS plugins and import remain removed.
# ONE base-domain lineage is deployed to dot/web/zash role dirs. The host
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
grep -Eq '(^|[[:space:]])nft([[:space:]]|$)' "$INSTALL" \
    && fail "install.sh: must not inspect or mutate host nftables"

# ===== Cert modes: cloudflare | http-01 | debug only =====
ncm="$(sed -n '/^normalize_cert_mode()/,/^}/p' "$INSTALL")"
printf '%s' "$ncm" | grep -Fq 'cloudflare) printf' \
    || fail "install.sh: normalize_cert_mode does not accept cloudflare"
printf '%s' "$ncm" | grep -Fq 'http-01) printf' \
    || fail "install.sh: normalize_cert_mode does not accept http-01"
printf '%s' "$ncm" | grep -Fq 'http|http-01)' \
    && fail "install.sh: normalize_cert_mode still accepts the unsupported http alias"
printf '%s' "$ncm" | grep -Fq 'debug) printf' \
    || fail "install.sh: normalize_cert_mode does not accept debug"
grep -Fq 'Persisted CERT_MODE must be cloudflare, http-01, or debug.' "$INSTALL" \
    || fail "install.sh: persisted CERT_MODE is not restricted to cloudflare|http-01|debug"
grep -Eq 'IMPORT_CERT:-|CERTBOT_DNS_PLUGIN=|== "dns-01"|== "import"' "$INSTALL" \
    && fail "install.sh: removed generic DNS-01/import certificate modes returned"

# ===== One base domain, one mode-specific certificate, THREE role cert dirs =====
grep -Fq 'DOT_CERT_DIR="${DNS_CERT_DIR}/dot"' "$INSTALL" \
    || fail "install.sh: no DOT_CERT_DIR role dir (/etc/5gpn/cert/dot)"
grep -Fq 'WEB_CERT_DIR="${DNS_CERT_DIR}/web"' "$INSTALL" \
    || fail "install.sh: no WEB_CERT_DIR role dir (/etc/5gpn/cert/web)"
grep -Fq 'ZASH_CERT_DIR="${DNS_CERT_DIR}/zash"' "$INSTALL" \
    || fail "install.sh: no ZASH_CERT_DIR role dir (/etc/5gpn/cert/zash)"
grep -Fq 'DNS_WEB_CERT=${WEB_CERT_DIR}/current/fullchain.pem' "$INSTALL" \
    || fail "install.sh: dns.env does not point DNS_WEB_CERT at the web role dir"
grep -Fq 'DNS_CERT=${DOT_CERT_DIR}/current/fullchain.pem' "$INSTALL" \
    || fail "install.sh: dns.env does not point DNS_CERT at the dot role dir"
# full_install must provision the ONE lineage named for the base domain.
grep -Eq '^[[:space:]]*install_cert "\$BASE_DOMAIN"' "$INSTALL" \
    || fail "install.sh: full_install does not provision the single scoped cert via install_cert \$BASE_DOMAIN"
grep -Eq '^deploy_cert_roles\(\)' "$INSTALL" \
    || fail "install.sh: no deploy_cert_roles() (copies the selected certificate to dot/web/zash)"

# ===== CERT_MODE=debug — self-signed WILDCARD + dismantles ACME machinery =====
dbg="$(sed -n '/^issue_selfsigned_wildcard()/,/^}/p' "$INSTALL")"
printf '%s' "$dbg" | grep -Fq 'openssl req -x509' \
    || fail "install.sh: debug mode does not generate a self-signed cert (openssl req -x509)"
printf '%s' "$dbg" | grep -Fq 'remove_owned_renew_hook' \
    || fail "install.sh: debug branch does not ownership-gate deploy-hook removal"
printf '%s' "$dbg" | grep -Fq 'remove_owned_renewal_automation' \
    || fail "install.sh: debug branch does not ownership-gate renewal-unit removal"
printf '%s' "$dbg" | grep -Eq 'systemctl disable --now 5gpn-certbot-renew|rm -f.*/5gpn-certbot-renew' \
    && fail "install.sh: debug branch mutates renewal units outside the ownership gate"

# ===== Production issuance: scoped Cloudflare DNS-01 or standalone HTTP-01 =====
ic="$(sed -n '/^install_cert()/,/^}/p' "$INSTALL")"
printf '%s' "$ic" | grep -Fq 'certbot_args=(certonly --cert-name "$base"' \
    || fail "install.sh: certificate issuance is not scoped to --cert-name \$base"
printf '%s' "$ic" | grep -Fq -- '--dns-cloudflare' \
    || fail "install.sh: Cloudflare mode does not use certbot --dns-cloudflare"
printf '%s' "$ic" | grep -Fqe '-d "*.${base}"' \
    || fail "install.sh: Cloudflare mode does not request wildcard *.\${base}"
printf '%s' "$ic" | grep -Fqe '-d "${base}"' \
    || fail "install.sh: Cloudflare mode does not request the apex SAN"
printf '%s' "$ic" | grep -Fq -- '--standalone --preferred-challenges http-01' \
    || fail "install.sh: HTTP-01 mode does not use Certbot standalone HTTP challenge"
printf '%s' "$ic" | grep -Fq -- '--force-renewal --renew-with-new-domains' \
    || fail "install.sh: non-interactive mode switch cannot replace the lineage SAN set"
for domain in CONSOLE_DOMAIN ZASH_DOMAIN DOT_DOMAIN; do
    printf '%s' "$ic" | grep -Fq -- "-d \"\$$domain\"" \
        || fail "install.sh: HTTP-01 certificate omits \$$domain"
done
printf '%s' "$ic" | grep -Eq -- '--http-01-port|--webroot' \
    && fail "install.sh: HTTP-01 must use the standard standalone :80 flow, not custom-port/webroot flags"

# HTTP-01 releases only mihomo's :80 listeners. Failure and signal paths restore
# an originally active service immediately; successful initial issuance defers
# restoration until after role publication. Cloudflare reaches Certbot directly.
http_run="$(sed -n '/^run_http_certbot()/,/^)/p' "$INSTALL")"
printf '%s' "$http_run" | grep -Fq 'systemctl is-active --quiet mihomo.service' \
    || fail "install.sh: HTTP-01 wrapper does not remember whether mihomo was active"
printf '%s' "$http_run" | grep -Fq 'systemctl stop mihomo.service' \
    || fail "install.sh: HTTP-01 wrapper does not release mihomo TCP :80"
printf '%s' "$http_run" | grep -Fq 'systemctl start mihomo.service' \
    || fail "install.sh: HTTP-01 wrapper does not restore the originally active mihomo"
printf '%s' "$http_run" | grep -Eq 'xray|5gpn-dns' \
    && fail "install.sh: HTTP-01 wrapper may coordinate only mihomo"
_http_guard_line="$(printf '%s' "$ic" | grep -nF 'if [[ "$mode" == http-01 ]]; then' | tail -1 | cut -d: -f1)"
_http_run_line="$(printf '%s' "$ic" | grep -nF 'run_http_certbot "${certbot_args[@]}"' | head -1 | cut -d: -f1)"
[ -n "${_http_guard_line:-}" ] && [ -n "${_http_run_line:-}" ] \
    && [ "$_http_guard_line" -lt "$_http_run_line" ] \
    || fail "install.sh: run_http_certbot is not guarded by CERT_MODE=http-01"

# The install/configure preflight uses an independent resolver, requires every
# HTTP name to have only DNS_PUBLIC_IP A answers, and rejects any AAAA answer.
dns_match="$(sed -n '/^cert_dns_name_matches()/,/^}/p' "$INSTALL")"
http_dns="$(sed -n '/^check_http_challenge_dns_once()/,/^}/p' "$INSTALL")"
verify_dns="$(sed -n '/^verify_console_dns()/,/^}/p' "$INSTALL")"
grep -Fq 'CERT_DNS_RESOLVER="1.1.1.1"' "$INSTALL" \
    || fail "install.sh: certificate DNS gate is not pinned to 1.1.1.1"
printf '%s' "$dns_match" | grep -Fq '+short A "$domain" @"$CERT_DNS_RESOLVER"' \
    || fail "install.sh: certificate DNS gate does not query A through the fixed resolver"
printf '%s' "$dns_match" | grep -Fq '+short AAAA "$domain" @"$CERT_DNS_RESOLVER"' \
    || fail "install.sh: certificate DNS gate does not reject AAAA through the fixed resolver"
for domain in CONSOLE_DOMAIN ZASH_DOMAIN DOT_DOMAIN; do
    printf '%s' "$http_dns" | grep -Fq "\$$domain" \
        || fail "install.sh: HTTP-01 DNS gate omits \$$domain"
done
printf '%s' "$http_dns" | grep -Fq 'cert_dns_name_matches "$domain" 1 "$PUBLIC_IP"' \
    || fail "install.sh: HTTP-01 DNS gate does not require DNS_PUBLIC_IP exclusively"
printf '%s' "$verify_dns" | grep -Fq 'wait_for_cert_dns "HTTP-01 service records" check_http_challenge_dns_once' \
    || fail "install.sh: HTTP-01 install/configure path does not wait for DNS propagation"

# cloudflare.ini must be a root-owned non-symlink 0600 file before reuse; the
# atomic writer applies that mode to new credentials.
ect_fn_it="$(sed -n '/^ensure_cf_token()/,/^}/p' "$INSTALL")"
cf_safe_fn="$(sed -n '/^cf_credential_file_safe()/,/^}/p' "$INSTALL")"
printf '%s' "$cf_safe_fn" | grep -Fq '! -L "$f"' \
    && printf '%s' "$cf_safe_fn" | grep -Fq 'file_mode "$f"' \
    || fail "install.sh: saved Cloudflare credential lacks non-symlink/mode validation"
# ensure_cf_token must be called before the Cloudflare Certbot execution. The
# common scoped argument array may safely be constructed before token input.
_ect_line="$(printf '%s' "$ic" | grep -n 'ensure_cf_token || return 1' | head -1 | cut -d: -f1)"
_cb_line="$(printf '%s'  "$ic" | grep -nF 'certbot "${certbot_args[@]}"' | head -1 | cut -d: -f1)"
[ -z "${_ect_line:-}" ] && fail "install.sh: install_cert does not contain 'ensure_cf_token || return 1' (anchored call missing)"
[ -z "${_cb_line:-}" ] && fail "install.sh: install_cert does not execute scoped Cloudflare Certbot arguments"
[ -n "${_ect_line:-}" ] && [ "${_ect_line}" -ge "${_cb_line}" ] && \
    fail "install.sh: ensure_cf_token must run before Cloudflare Certbot"
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
printf '%s' "$wcf_fn_it" | grep -Fq 'ensure_acme_dir || return 1' \
    || fail "install.sh: write_cf_credential bypasses ACME directory safety validation"
printf '%s' "$wcf_fn_it" | grep -Eq 'mktemp.*\|\|' \
    || fail "install.sh: write_cf_credential mktemp is not guarded with || (silent failure under errexit suppression)"
printf '%s' "$ect_fn_it" | grep -Fq 'ensure_acme_dir || return 1' \
    || fail "install.sh: ensure_cf_token bypasses ACME directory safety validation"
grep -Fq 'systemctl stop xray' "$INSTALL" \
    && fail "install.sh: no cert-flow reference to 'systemctl stop xray' may remain anywhere"
# No firewall to open — the old open_port80/close_port80 nft dance must stay gone.
grep -Eq 'open_port80|close_port80' "$INSTALL" \
    && fail "install.sh: open_port80/close_port80 must stay removed (no host firewall)"

# ===== renew-hook.sh — deploys the ONE selected certificate to all THREE role dirs =====
RENEW="$ROOT/scripts/renew-hook.sh"
grep -Fq 'RENEWED_LINEAGE' "$RENEW" || fail "renew-hook.sh: does not use RENEWED_LINEAGE"
grep -Fq 'DNS_BASE_DOMAIN' "$RENEW" || fail "renew-hook.sh: does not match the lineage to DNS_BASE_DOMAIN"
grep -Fq 'roles=(dot web zash)' "$RENEW" \
    || fail "renew-hook.sh: does not deploy to all dot/web/zash role dirs"
grep -Fq 'validate_cert_pair' "$RENEW" \
    || fail "renew-hook.sh: does not validate SANs and the certificate/private-key pair"
grep -Fq 'mktemp -d "${dest}/generations/.new.XXXXXX"' "$RENEW" \
    || fail "renew-hook.sh: certificate generation is not same-directory staged"
grep -Fq 'mv -Tf -- "${links[$i]}" "${dests[$i]}/current"' "$RENEW" \
    || fail "renew-hook.sh: certificate pair is not atomically published"
grep -Fq 'mihomo reloads the controller certificate files automatically' "$RENEW" \
    || fail "renew-hook.sh: missing mihomo controller certificate hot-reload contract"
grep -Eq 'systemctl (restart|reload) mihomo' "$RENEW" \
    && fail "renew-hook.sh: must not restart/reload mihomo for controller certificate renewal"
grep -iq 'xray' "$RENEW" && fail "renew-hook.sh: must not reference xray (mihomo is the data plane)"

# ===== gen-ios-profile.sh — unsigned profile fails CLOSED =====
grep -Fq 'ALLOW_UNSIGNED_PROFILE' "$IOSGEN" \
    && fail "gen-ios-profile.sh: caller environment can still allow unsigned profiles"
grep -Fq 'Refusing to serve an UNSIGNED .mobileconfig' "$IOSGEN" \
    || fail "gen-ios-profile.sh: refusing an unsigned profile must exit non-zero"
grep -Fq 'stage_dir="$(mktemp -d "${WWW_DIR}/.ios-profile.XXXXXX")"' "$IOSGEN" \
    || fail "gen-ios-profile.sh: profiles are not staged privately on the destination filesystem"
grep -Fq 'mv -Tf -- "$staged_profile" "$profile_path"' "$IOSGEN" \
    && grep -Fq 'mv -Tf -- "$staged_intercept_profile" "$intercept_profile_path"' "$IOSGEN" \
    || fail "gen-ios-profile.sh: signed profiles are not atomically renamed into place"
# The configuration guide lives in the console SPA. The profile generator must
# publish only the signed payload, never recreate a second landing-page bundle.
grep -Eq '(index\.html|ios\.css|ios\.js)' "$IOSGEN" \
    && fail "gen-ios-profile.sh: standalone iOS landing assets must stay removed"

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
files_line="$(grep -nE '^[[:space:]]*install_files([[:space:]]*\|\| return 1)?$' "$INSTALL" | tail -1 | cut -d: -f1)"
if [ -z "${resolver_line:-}" ] || [ -z "${files_line:-}" ]; then
    fail "install.sh: could not locate configuration resolution or install_files"
elif [ "$resolver_line" -ge "$files_line" ]; then
    fail "install.sh: persisted/TUI configuration must be resolved before publication"
fi

# ===== The mihomo config must be rendered AFTER configuration resolution =====
webdom_line="$(grep -nE '^[[:space:]]*render_mihomo_config( --reset)?([[:space:]]*\|\| return 1)?$' "$INSTALL" | tail -1 | cut -d: -f1)"
domains_line="$resolver_line"
if [ -z "${webdom_line:-}" ] || [ -z "${domains_line:-}" ]; then
    fail "install.sh: could not locate render_mihomo_config or configuration resolution"
elif [ "$webdom_line" -le "$domains_line" ]; then
    fail "install.sh: render_mihomo_config must run after validated TUI/persisted configuration"
fi

# ===== CPU arch guard — amd64-only prebuilts must refuse other arches early =====
grep -Eq '^check_arch\(\)' "$INSTALL" \
    || fail "install.sh: no check_arch() guard (ARM box would install to the end then hit exec format error)"
grep -Eq '^[[:space:]]*check_arch([[:space:]]*\|\| return 1)?$' "$INSTALL" \
    || fail "install.sh: check_arch is defined but never called in full_install"

# ===== DNS_CACHE_SIZE — the RAM-derived cache size must reach dns.env =====
grep -Eq 'DNS_CACHE_SIZE=\$\{CACHE_SIZE' "$INSTALL" \
    || fail "install.sh: write_dns_env hardcodes DNS_CACHE_SIZE (must interpolate \${CACHE_SIZE} so the memory-derived size takes effect)"
grep -Fq 'CACHE_SIZE="$(cfg_get DNS_CACHE_SIZE)"' "$INSTALL" \
    || fail "install.sh: CACHE_SIZE not loaded from persisted dns.env"

[ $rc -eq 0 ] && echo "intranet policy: PASS"
exit $rc
