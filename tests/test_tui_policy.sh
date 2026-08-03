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
for f in scripts/gen-ios-profile.sh scripts/renew-hook.sh scripts/cert-renew.sh scripts/intercept-cert-renew.sh; do
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
# The upstream groups live in upstreams.json, not dns.env: the daemon cannot
# write dns.env under its systemd sandbox, so a copy there could only ever go
# stale and silently disagree with the live configuration. The seeder consumes
# the operational defaults, refuses to clobber an operator-configured file, and
# carries a pre-existing dns.env value forward once so the first upgrade past
# this change does not reset a hand-edited value.
seed_fn="$(sed -n '/^seed_dns_document() {/,/^    ok "Seeded the DNS document/p' "$INSTALL")"
printf '%s' "$seed_fn" | grep -Fq 'china="${prev_china:-$DNS_CHINA_DEFAULT}"' \
    && printf '%s' "$seed_fn" | grep -Fq 'trust="${prev_trust:-$DNS_TRUST_DEFAULT}"' \
    || fail "DNS document seeder does not consume the operational upstream defaults"
# An existing document is refreshed, not replaced: the installer owns the
# certificate pair and the gateway, and the console owns policy, upstreams and
# tuning through the same file. A seeder that rewrote the whole document would
# discard every console edit on the next reinstall.
printf '%s' "$seed_fn" | grep -Fq '.listen.certificate = $cert' \
    && printf '%s' "$seed_fn" | grep -Fq '.listen.privateKey = $key' \
    && printf '%s' "$seed_fn" | grep -Fq '.gateway = $gw' \
    || fail "DNS document seeder does not refresh the installer-owned fields in place"
# The pair is the whole point: DefaultDocument asks for :853 and cannot name a
# key, so a document without it means a gateway that starts healthy with no DNS.
printf '%s' "$seed_fn" | grep -Fq 'certificate: $cert, privateKey: $key' \
    || fail "a freshly seeded DNS document carries no certificate pair"
grep -Eq '^DNS_CHINA=|^DNS_TRUST=' "$INSTALL" \
    && fail "DNS_CHINA/DNS_TRUST must no longer be written into dns.env"
grep -Eq '^[[:space:]]+seed_dns_document$' "$INSTALL" \
    || fail "full_install does not seed the DNS document"
grep -Eq '^[[:space:]]+seed_upstreams_json$' "$INSTALL" \
    && fail "full_install still seeds the retired upstreams.json"
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
for domain in CONSOLE_DOMAIN DOT_DOMAIN; do
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

# --- the certificate oneshot performs only the visible local publication. ---
UL="$ROOT/scripts/intercept-cert-renew.sh"
grep -Eq 'gum_spin[^|]*systemctl' "$UL" \
    && fail "intercept-cert-renew.sh must not hide publication output behind a spinner"

# --- quick-install.sh: pre-gum entrypoint — gum-aware-if-present, ANSI fallback -
QI="$ROOT/quick-install.sh"
grep -Fq 'command -v gum' "$QI" || fail "quick-install.sh is not gum-aware (use gum if already on PATH)"
grep -Fq '\033[0;31m'     "$QI" || fail "quick-install.sh lost its ANSI fallback"

# --- the management TUI: every offered label does something --------------------
#
# The flat menu carried 「重载规则」 and 「配置 Telegram Bot」 in its label list
# with no branch in its case, for the whole of the monolith work. Selecting
# either silently redrew the menu. Nothing caught it because a label and its
# dispatch were two lists nobody compared.
#
# They are one mapping now, and this compares them.
menu_fn="$(sed -n '/^manage_menu()/,/^}/p' "$INSTALL")"
action_fn="$(sed -n '/^manage_action()/,/^}/p' "$INSTALL")"
[[ -n "$menu_fn" && -n "$action_fn" ]] || fail "manage_menu/manage_action not found"

while IFS= read -r label; do
    [[ -n "$label" ]] || continue
    printf '%s' "$action_fn" | grep -Fq "\"$label\")" \
        || fail "the TUI offers \"$label\" with no branch in manage_action"
done <<< "$(printf '%s' "$menu_fn" | awk '
    # Only the arguments of a manage_screen call are labels. Every other quoted
    # string in this function is prose -- a header, an error, a hint -- and
    # matching those would make this assertion fail on its own documentation.
    /manage_screen "/ { incall = 1 }
    incall {
        line = $0
        while (match(line, /"[^"]+"/)) {
            label = substr(line, RSTART + 1, RLENGTH - 2)
            line = substr(line, RSTART + RLENGTH)
            # A screen title is CJK only; a label is "中文 English". The
            # renderer is a bare word and is never quoted.
            if (label ~ /[A-Za-z]/ && label !~ /^(概览|服务|证书|网络|危险操作)$/) print label
        }
        if (line !~ /\\$/) incall = 0
    }
' | sed -E 's/ (Back)$//' | sort -u | grep -v '^返回$')"

# Each screen renders its own facts before offering its actions: a decision is
# made with the state it acts on already on screen.
for screen in manage_screen_overview manage_screen_services \
              manage_screen_certificates manage_screen_network; do
    grep -Eq "^${screen}\(\)" "$INSTALL" || fail "$screen is missing"
done
screen_fn="$(sed -n '/^manage_screen()/,/^}/p' "$INSTALL")"
printf '%s' "$screen_fn" | grep -Fq '| card' \
    || fail "manage_screen does not frame its status through card()"
printf '%s' "$screen_fn" | grep -Fq 'ask_choice' \
    || fail "manage_screen does not use the gum-or-read chooser"

# Status must never assert a value it could not read. Without jq every field
# falls back to its zero value, which reads as a confident "off" for a switch
# that may be on.
overview_fn="$(sed -n '/^manage_screen_overview()/,/^}/p' "$INSTALL")"
printf '%s' "$overview_fn" | grep -Fq 'command -v jq' \
    || fail "the overview screen reports interception state without checking jq is present"

# The menu is still interactive-only, and still names the subcommands.
printf '%s' "$menu_fn" | grep -Fq '[[ ! -t 0 ]]' \
    || fail "manage_menu no longer refuses a non-TTY"

[ $rc -eq 0 ] && echo "tui policy: PASS"
exit $rc
