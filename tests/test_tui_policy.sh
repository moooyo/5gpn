#!/usr/bin/env bash
# Policy: every operator-facing shell script renders status through the shared
# gum-or-echo pattern (gum when present + TTY, plain echo otherwise) — never a
# bare echo as the only path. Bootstrapping gum (install_gum) is the one exempt
# step. Pure grep — runs on the dev box under Git Bash.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"

# --- install.sh: card() frames the status + completion summary -----------------
grep -Eq 'card\(\)'                "$INSTALL" || fail "install.sh has no card() box helper"
grep -Fq 'gum style --border rounded' "$INSTALL" || fail "install.sh card() does not use a gum style border"
# ...and must not regress to the old ASCII status banner.
grep -Fq '==========================================' "$INSTALL" \
    && fail "install.sh still uses the old ==== status banner instead of a gum card"

# --- sub-scripts + hooks: gum-detect + gum log + plain-echo fallback all present -
for f in scripts/reload-rules.sh scripts/gen-ios-profile.sh scripts/renew-hook.sh scripts/cert-renew.sh; do
    s="$ROOT/$f"
    grep -Fq 'command -v gum'  "$s" || fail "$f does not detect gum on PATH"
    grep -Fq 'gum log'         "$s" || fail "$f has no gum log output path"
    grep -Eq '\[OK\]|\[INFO\]' "$s" || fail "$f lost its plain-echo fallback"
done

# --- Certificate-mode TUI: selection is TTY-only, cancellation-safe, and the
# operator sees/accepts the DNS plan before the installer begins its resolver
# wait. HTTP-01 must show all exact ACME names plus the no-AAAA/:80 contract.
tui_fn="$(sed -n '/^configure_install_tui()/,/^}/p' "$INSTALL")"
printf '%s' "$tui_fn" | grep -Fq '[[ -t 0 ]]' \
    || fail "certificate-mode TUI is not gated on attached stdin"
printf '%s' "$tui_fn" | grep -Fq "http-01 — Let’s Encrypt exact service SANs" \
    || fail "certificate-mode TUI does not offer HTTP-01"
printf '%s' "$tui_fn" | grep -Fq "cloudflare — Let’s Encrypt wildcard" \
    || fail "certificate-mode TUI does not offer Cloudflare DNS-01"
printf '%s' "$tui_fn" | grep -Fq 'ensure_cf_token || return 1' \
    || fail "Cloudflare selection does not collect or reuse the API token inside the TUI"
printf '%s' "$tui_fn" | grep -Eq "国内解析 ECS|DNS cache entries" \
    && fail "installer still prompts for automatic ECS/cache values"
printf '%s' "$tui_fn" | grep -Fq 'EGRESS_RESOLVER' \
    && fail "installer still exposes the retired single egress resolver"
printf '%s' "$tui_fn" | grep -Fq 'CACHE_SIZE="${CACHE_SIZE:-${_CACHE_SIZE_DEFAULT:-4096}}"' \
    || fail "installer does not apply the memory-derived cache default automatically"
printf '%s' "$tui_fn" | grep -Fq 'CHINA_ECS="$DNS_CHINA_ECS_DEFAULT"' \
    || fail "installer does not apply the operational ECS default"
grep -Fq 'DNS_CHINA_DEFAULT="223.5.5.5"' "$INSTALL" \
    && grep -Fq 'DNS_TRUST_DEFAULT="22.22.22.22"' "$INSTALL" \
    && grep -Fq 'DNS_CHINA_ECS_DEFAULT="112.96.32.0/24"' "$INSTALL" \
    || fail "installer operational DNS/ECS defaults drifted"
grep -Fq 'local dns_china="${existing_china:-$DNS_CHINA_DEFAULT}"' "$INSTALL" \
    && grep -Fq 'local dns_trust="${existing_trust:-$DNS_TRUST_DEFAULT}"' "$INSTALL" \
    || fail "dns.env writer does not consume the operational upstream defaults"
printf '%s' "$tui_fn" | grep -Fq 'GATEWAY_IP="$PUBLIC_IP"' \
    && printf '%s' "$tui_fn" | grep -Fq 'MIHOMO_LISTEN_IPS="$default_listen"' \
    && printf '%s' "$tui_fn" | grep -Fq 'PUBLIC_IP="$detected"' \
    || fail "first install does not derive public/gateway/listener values automatically"
printf '%s' "$tui_fn" | grep -Fq 'if [[ "$advanced" == 1 ]]' \
    && printf '%s' "$tui_fn" | grep -Fq '公网 IPv4 Public IPv4' \
    && printf '%s' "$tui_fn" | grep -Fq 'mihomo 本机监听 IPv4' \
    || fail "advanced configure TUI lost public/gateway/listener overrides"
printf '%s' "$tui_fn" | grep -Fq 'SNI 回源解析器' \
    && fail "advanced configure TUI still prompts for the retired single egress resolver"
printf '%s' "$tui_fn" | grep -Fq "|| true)" \
    || fail "certificate-mode TUI prompt capture is not cancellation-safe under set -e"
for domain in CONSOLE_DOMAIN ZASH_DOMAIN DOT_DOMAIN; do
    printf '%s' "$tui_fn" | grep -Fq "\${$domain}" \
        || fail "HTTP-01 confirmation card omits \$$domain"
done
printf '%s' "$tui_fn" | grep -Fq 'AAAA: none for all three names' \
    || fail "HTTP-01 confirmation card omits the no-AAAA requirement"
printf '%s' "$tui_fn" | grep -Fq 'TCP/80: publicly reachable' \
    || fail "HTTP-01 confirmation card omits public TCP/80 reachability"
printf '%s' "$tui_fn" | grep -Fq 'wait for 1.1.1.1' \
    || fail "certificate TUI does not explain the independent 1.1.1.1 wait"
http_plan_line="$(grep -nF 'HTTP-01 DNS / network prerequisites' <<<"$tui_fn" | head -1 | cut -d: -f1)"
http_confirm_line="$(grep -nF '我已确认上述 DNS 和 TCP/80 配置正确' <<<"$tui_fn" | head -1 | cut -d: -f1)"
cf_confirm_line="$(grep -nF '我已添加上述 console A 记录' <<<"$tui_fn" | head -1 | cut -d: -f1)"
cf_token_line="$(grep -nF 'ensure_cf_token || return 1' <<<"$tui_fn" | head -1 | cut -d: -f1)"
[[ -n "$http_plan_line" && -n "$http_confirm_line" && "$http_plan_line" -lt "$http_confirm_line" ]] \
    || fail "HTTP-01 DNS plan is not shown before explicit confirmation"
[[ -n "$cf_token_line" && -n "$cf_confirm_line" && "$cf_token_line" -lt "$cf_confirm_line" ]] \
    || fail "Cloudflare token is not collected before final DNS confirmation"
printf '%s' "$tui_fn" | grep -Fq 'The API token is used only for ACME TXT records.' \
    && printf '%s' "$tui_fn" | grep -Fq 'does NOT create or modify this A record' \
    || fail "Cloudflare TUI does not explain that the console A record is operator-managed"

# --- reload-rules.sh performs only the visible local reload. ---
UL="$ROOT/scripts/reload-rules.sh"
grep -Eq 'gum_spin[^|]*(render_smartdns_conf|systemctl)' "$UL" \
    && fail "reload-rules.sh must not hide reload output behind a spinner"

# --- quick-install.sh: pre-gum entrypoint — gum-aware-if-present, ANSI fallback -
QI="$ROOT/quick-install.sh"
grep -Fq 'command -v gum' "$QI" || fail "quick-install.sh is not gum-aware (use gum if already on PATH)"
grep -Fq '\033[0;31m'     "$QI" || fail "quick-install.sh lost its ANSI fallback"

[ $rc -eq 0 ] && echo "tui policy: PASS"
exit $rc
