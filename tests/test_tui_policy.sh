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
#
# The per-field prompts live in install_tui_* helpers so the first pass and the
# review can share one definition each, so the properties below are asserted
# against the entry point AND its helpers as one surface. Extracting only
# configure_install_tui would silently stop covering every prompt the moment one
# moved out of it.
tui_fn="$(sed -n '/^configure_install_tui()/,/^}/p' "$INSTALL"
          sed -n '/^install_tui_[a-z_]*()/,/^}/p' "$INSTALL")"
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
printf '%s' "$tui_fn" | grep -Fq 'CACHE_SIZE' \
    && fail "installer still mirrors live DNS cache tuning through the install TUI"
printf '%s' "$tui_fn" | grep -Fq 'CHINA_ECS' \
    && fail "installer still mirrors live China ECS through the install TUI"
grep -Fq 'DNS_CHINA_DEFAULT="223.5.5.5"' "$INSTALL" \
    && grep -Fq 'DNS_TRUST_DEFAULT="22.22.22.22"' "$INSTALL" \
    && grep -Fq 'DNS_CHINA_ECS_DEFAULT="112.96.32.0/24"' "$INSTALL" \
    || fail "installer operational DNS/ECS defaults drifted"
# The upstream groups live in dns.json, not dns.env. A missing current document
# is seeded from the current operational defaults; retired dns.env values are
# never imported. An existing document is preserved apart from installer-owned
# coordinates below.
seed_fn="$(sed -n '/^seed_dns_document() {/,/^    ok "Seeded the DNS document/p' "$INSTALL")"
render_fn="$(sed -n '/^render_fresh_dns_document()/,/^}/p' "$INSTALL")"
printf '%s' "$seed_fn" | grep -Fq 'local china="$DNS_CHINA_DEFAULT" trust="$DNS_TRUST_DEFAULT"' \
    && printf '%s' "$seed_fn" | grep -Fq 'local ecs="$DNS_CHINA_ECS_DEFAULT"' \
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
printf '%s' "$render_fn" | grep -Fq 'certificate: $cert, privateKey: $key' \
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
# The names are asserted individually by the loop above, so this asserts the
# requirement rather than the count phrasing. The card said "all three names"
# for as long as there were only two, which is the kind of wrong a literal match
# on the old wording pins in place instead of catching.
printf '%s' "$tui_fn" | grep -Eq 'AAAA: none' \
    || fail "HTTP-01 confirmation card omits the no-AAAA requirement"
printf '%s' "$tui_fn" | grep -Fq 'all three names' \
    && fail "HTTP-01 card still promises three names; there are two"
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

# --- the install review: every offered label does something -------------------
#
# Same coupling as manage_menu below, on the review that replaced the summary's
# yes/no gate. A label with no arm here does not silently redraw a menu -- it
# falls through the case and confirms an install the operator was trying to
# correct, which is worse than doing nothing.
#
# The labels are compared against the case patterns with bash's own globbing,
# not with a guessed prefix. The first attempt at this derived "the arm probably
# matches up to the first English word", which is wrong for any label with
# "IPv4" in the middle of it -- and a check that mis-parses the thing it is
# checking reports failures that are its own.
review_fn="$(sed -n '/^configure_install_tui()/,/^}/p' "$INSTALL")"
[[ -n "$review_fn" ]] || fail "configure_install_tui not found"

# Labels: the single-quoted arguments of the review's ask_choice call.
mapfile -t review_labels < <(printf '%s' "$review_fn" | awk "
    /ask_choice '确认或修改/ { incall = 1 }
    incall {
        line = \$0
        while (match(line, /'[^']+'/)) {
            label = substr(line, RSTART + 1, RLENGTH - 2)
            line = substr(line, RSTART + RLENGTH)
            if (label !~ /^确认或修改/) print label
        }
        if (line !~ /\\\\\$/) incall = 0
    }
")
[[ "${#review_labels[@]}" -ge 6 ]] \
    || fail "found only ${#review_labels[@]} review labels; the extraction is broken, not the menu"

# Patterns: the case arms, taken from inside the case block only. An arm ends at
# the first ) -- a case pattern cannot contain one -- and most arms carry their
# body on the same line, so anchoring on end-of-line finds almost none of them.
mapfile -t review_arms < <(printf '%s' "$review_fn" | awk '
    /case "\$choice" in/ { incase = 1; next }
    incase && /^[[:space:]]*esac/ { incase = 0 }
    incase {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (line ~ /^\x27/ && index(line, ")") > 0) {
            print substr(line, 1, index(line, ")") - 1)
        }
    }
')
[[ "${#review_arms[@]}" -ge 6 ]] \
    || fail "found only ${#review_arms[@]} review case arms; the extraction is broken, not the menu"

for label in "${review_labels[@]}"; do
    matched=0
    for arm in "${review_arms[@]}"; do
        # An arm is one or more shell patterns separated by |, each quoted the
        # way bash would see it inside a case. Strip the quotes and test.
        IFS='|' read -r -a alts <<< "$arm"
        for alt in "${alts[@]}"; do
            alt="${alt#\'}"; alt="${alt%\'}"
            alt="${alt//\'/}"
            [[ "$label" == $alt ]] && { matched=1; break 2; }
        done
    done
    [[ "$matched" == 1 ]] \
        || fail "the install review offers \"$label\" with no case arm that matches it"
done
echo "ok: every install-review label is matched by a case arm"

# Cancelling and an escaped selection must both abort rather than fall through
# to confirming; ask_choice yields an empty string when the operator escapes.
printf '%s' "$review_fn" | grep -Fq "'取消'*|'')" \
    || fail "the install review does not treat an escaped selection as cancel"
echo "ok: an escaped install-review selection cancels rather than confirms"

# --- the management TUI: every offered label does something --------------------
#
# The flat menu carried 「重载规则」 and 「配置 Telegram Bot」 in its label list
# with no branch in its case, for the whole of the monolith work. Selecting
# either silently redrew the menu. Nothing caught it because a label and its
# dispatch were two lists nobody compared.
#
# The labels live in MANAGE_SCREENS now -- one table read by both the tab UI and
# the plain list -- so this reads the table and compares it against
# manage_action. Parsing the table the same way install.sh does is the point: a
# check that split the rows differently would pass while the menu dropped an
# action.
action_fn="$(sed -n '/^manage_action()/,/^}/p' "$INSTALL")"
[[ -n "$action_fn" ]] || fail "manage_action not found"

eval "$(sed -n '/^MANAGE_SCREENS=(/,/^)/p' "$INSTALL")"
[[ "${#MANAGE_SCREENS[@]}" -ge 4 ]] \
    || fail "MANAGE_SCREENS parsed to ${#MANAGE_SCREENS[@]} rows; the table or this check is broken"

for row in "${MANAGE_SCREENS[@]}"; do
    title="${row%%|*}"
    render="${row#*|}"; render="${render%%|*}"
    [[ -n "$title" && "$title" != *"|"* ]] || fail "a screen row has no title: $row"
    grep -Eq "^${render}\(\)" "$INSTALL" \
        || fail "screen \"$title\" names renderer $render, which does not exist"
    IFS='|' read -r -a row_labels <<< "${row#*|*|}"
    [[ "${#row_labels[@]}" -ge 1 ]] || fail "screen \"$title\" offers no actions"
    for label in "${row_labels[@]}"; do
        printf '%s' "$action_fn" | grep -Fq "\"$label\")" \
            || fail "the TUI offers \"$label\" with no branch in manage_action"
    done
done
echo "ok: every screen has a renderer and every label has a manage_action branch"

# Tabs read one key at a time and draw at a cursor position, so they need both
# ends to be the terminal; everything else must still get a working menu. Losing
# either half is losing the property every surface here keeps.
menu_fn="$(sed -n '/^manage_menu()/,/^}/p' "$INSTALL")"
printf '%s' "$menu_fn" | grep -Fq 'manage_menu_tabs' \
    || fail "manage_menu no longer offers the tab UI"
printf '%s' "$menu_fn" | grep -Fq 'manage_menu_list' \
    || fail "manage_menu lost its non-terminal fallback"
printf '%s' "$menu_fn" | grep -Fq '[[ -t 1 ' \
    || fail "manage_menu does not gate the tab UI on stdout being a terminal"
printf '%s' "$menu_fn" | grep -Fq 'dumb' \
    || fail "manage_menu draws tabs on TERM=dumb"

# The key reader must not leave the terminal changed. `read -rsn1` is why there
# is no stty here: bash restores what it altered, so a signal mid-read cannot
# strand the operator with echo off.
key_fn="$(sed -n '/^manage_read_key()/,/^}/p' "$INSTALL")"
[[ -n "$key_fn" ]] || fail "manage_read_key not found"
printf '%s' "$key_fn" | grep -Fq 'read -rsn1' \
    || fail "manage_read_key does not read a single key without echo"
printf '%s' "$key_fn" | grep -Fq 'stty' \
    && fail "manage_read_key changes terminal modes; it then owes a restore on every signal"
printf '%s' "$key_fn" | grep -Fq -- '-t 0.05' \
    || fail "the escape-sequence read does not time out; a bare ESC would hang the menu"
echo "ok: the key reader leaves no terminal state to restore"

# Each screen renders its own facts before offering its actions: a decision is
# made with the state it acts on already on screen.
for screen in manage_screen_overview manage_screen_services \
              manage_screen_certificates manage_screen_network manage_screen_nodes; do
    grep -Eq "^${screen}\(\)" "$INSTALL" || fail "$screen is missing"
done

nodes_screen_fn="$(sed -n '/^manage_screen_nodes()/,/^}/p' "$INSTALL")"
printf '%s' "$nodes_screen_fn" | grep -Fq 'fivegpn_nodes_snapshot' \
    || fail "the node screen does not read the operator-owned mihomo config through the core helper"
printf '%s' "$nodes_screen_fn" | grep -Fq 'if ! snapshot=' \
    && printf '%s' "$nodes_screen_fn" | grep -Fq '.nodes | type == "array"' \
    || fail "the node screen mistakes a helper error JSON for a successful node view"
printf '%s' "$nodes_screen_fn" | grep -Fq 'Proxies' \
    || fail "the node screen does not explain the Proxies membership boundary"
printf '%s' "$nodes_screen_fn" | grep -Fq '@json' \
    || fail "the node screen prints untrusted YAML strings without terminal escaping"
multiline_fn="$(sed -n '/^ask_multiline()/,/^}/p' "$INSTALL")"
printf '%s' "$multiline_fn" | grep -Fq 'gum write' \
    || fail "multiline node input does not use Gum on the primary TUI path"
printf '%s' "$multiline_fn" | grep -Fq '[[ -t 0 ]]' \
    || fail "multiline node input is not gated on attached stdin"

add_nodes_fn="$(sed -n '/^manage_add_nodes()/,/^}/p' "$INSTALL")"
delete_node_fn="$(sed -n '/^manage_delete_node()/,/^}/p' "$INSTALL")"
nodes_snapshot_fn="$(sed -n '/^fivegpn_nodes_snapshot()/,/^}/p' "$INSTALL")"
for fn in "$add_nodes_fn" "$delete_node_fn"; do
    printf '%s' "$fn" | grep -Fq '5gpn-nodes' \
        || fail "a node mutation bypasses the core parser helper"
    printf '%s' "$fn" | grep -Fq 'fivegpn_apply_node_change' \
        || fail "a persisted node mutation does not use the shared apply-and-verify path"
done
node_helper_surface="${nodes_snapshot_fn}${add_nodes_fn}${delete_node_fn}"
[[ "$(printf '%s' "$node_helper_surface" | grep -Fc 'SAFE_PATHS="$MIHOMO_SAFE_PATHS"')" == 4 ]] \
    || fail "not every one-shot node helper call inherits the runtime SAFE_PATHS contract"
printf '%s' "$add_nodes_fn" | grep -Fq -- '--dry-run' \
    && printf '%s' "$add_nodes_fn" | grep -Fq 'ask_yesno' \
    || fail "node import does not preview the parsed names before confirmation"
printf '%s' "$delete_node_fn" | grep -Fq 'fivegpn_live_proxies_snapshot' \
    && printf '%s' "$delete_node_fn" | grep -Fq '.value.now?' \
    || fail "node deletion does not refuse a node currently selected by a live group"
printf '%s' "$delete_node_fn" | grep -Fq '@base64' \
    && printf '%s' "$delete_node_fn" | grep -Fq '@json' \
    || fail "node deletion does not separate the exact name from its terminal-safe label"
apply_nodes_fn="$(sed -n '/^fivegpn_apply_node_change()/,/^}/p' "$INSTALL")"
verify_nodes_fn="$(sed -n '/^fivegpn_verify_live_node_change()/,/^}/p' "$INSTALL")"
printf '%s' "$apply_nodes_fn" | grep -Fq 'fivegpn_reload_operator_config' \
    && printf '%s' "$apply_nodes_fn" | grep -Fq 'fivegpn_verify_live_node_change' \
    || fail "node changes are not hot-applied and checked against the live Proxies view"
printf '%s' "$apply_nodes_fn" | grep -Fq 'restart_services' \
    || fail "node changes do not converge disk and runtime when hot apply fails"
printf '%s' "$verify_nodes_fn" | grep -Fq '[$names[] as $name |' \
    || fail "live node verification lost its jq 1.6-compatible all-members expression"
printf '%s' "$verify_nodes_fn" | grep -Fq 'all($names[] as $name;' \
    && fail "live node verification uses jq syntax unsupported by the deployed jq 1.6"
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
printf '%s' "$overview_fn" | grep -Fq 'console_public_url' \
    && printf '%s' "$overview_fn" | grep -Fq 'Console connection' \
    || fail "the overview does not show the public Console URL and explicit connection action"
printf '%s' "$overview_fn" | grep -Eq 'DNS_MIHOMO_SECRET|console_setup_url' \
    && fail "the overview renderer contains sensitive Console connection material"
printf '%s' "$overview_fn" | grep -Fq "printf '  🚫 HTTP/3 禁用\\n'" \
    || fail "the overview does not render the intentionally short HTTP/3 disabled state"
printf '%s' "$overview_fn" | grep -Fq 'H3-only fails' \
    && fail "the overview restored the long HTTP/3 explanation that widens the TUI frame"

tabs_fn="$(sed -n '/^manage_menu_tabs()/,/^}/p' "$INSTALL")"
printf '%s' "$tabs_fn" | grep -Fq "printf '\\033[0m\\033[H\\033[J%s\\n'" \
    || fail "tab frames do not reset, erase, and paint in one ready-frame write"
printf '%s' "$tabs_fn" | grep -Fq "printf '\\033[0m\\033[H\\033[J▶ %s\\n'" \
    || fail "action titles do not erase old line suffixes before painting"
printf '%s' "$tabs_fn" | grep -Fq '\033[2J' \
    && fail "tab navigation clears the terminal before rendering"

# The menu is still interactive-only, and still names the subcommands.
printf '%s' "$menu_fn" | grep -Fq '[[ ! -t 0 ]]' \
    || fail "manage_menu no longer refuses a non-TTY"

[ $rc -eq 0 ] && echo "tui policy: PASS"
exit $rc
