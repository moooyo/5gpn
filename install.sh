#!/usr/bin/env bash
# 5gpn installer / orchestrator (exit-less, direct-egress architecture).
#
#   client DoT:853 (the ONLY DNS transport) -> 5gpn-dns (returns GATEWAY IP for
#   blocked/foreign domains) -> mihomo (tunnel listener :443/:80) sniffs the SNI
#   (sniffer override-destination), the loopback DNS broker re-resolves the real
#   IP via DNS_EGRESS_RESOLVER, then egresses per the rule engine (DIRECT by
#   default; SP-2 adds selectable exits). mihomo also SNI-splits the panels
#   (console./zash.<base>) to the daemon's loopback :443 listener.
#
# One base domain and one scoped production cert lineage:
#   BASE_DOMAIN  -> the operator's ONE apex domain (the single knob).
#   CONSOLE_DOMAIN/ZASH_DOMAIN/DOT_DOMAIN
#     (= console./zash./dot.<BASE_DOMAIN>)
#     are auto-derived subdomains (derive_domains). Cloudflare DNS-01 issues
#     `*.<base>` + `<base>`; HTTP-01 issues the three exact service SANs because
#     HTTP-01 cannot issue wildcards. HTTP-01 waits for all three A records via
#     1.1.1.1, then briefly releases mihomo's :80 listener for issuance/renewal.
#     Auto-renewal is unattended via the daily scoped certbot timer.
#     CERT_MODE=debug issues a self-signed wildcard instead (test/dev boxes).
#
# QUIC/HTTP3 is proxied by mihomo (UDP 443 sniff-forward). No exit layer, no Go
# data plane. There is NO host firewall: nftables management was removed
# (2026-07-10) — use your provider's security group if you want one. The
# console is public with bearer-protected APIs; zashboard remains reachable
# only from source IPs on the mihomo whitelist.txt allowlist.
#
# There is NO network-layer exit: no WireGuard, no fwmark / ip-rule / table-100.
# Do not add any of those (application-layer exits live in mihomo's rule engine).
#
# FRESH-ARTIFACT re-runs (2026-07-10): every run cleans + re-downloads/regenerates
# ALL installed artifacts at the pinned versions — binaries (5gpn-dns, mihomo, the
# 5gpn launcher), systemd units, mihomo config, /opt/5gpn runtime tree — so a
# re-run can never leave a stale binary next to newer configs. ONLY /etc/5gpn
# (dns.env, token, certs, rules, subscriptions) and /etc/letsencrypt persist.
# A pre-placed dev binary is deliberately clobbered: scp dev builds in AFTER
# the install run, then `systemctl restart 5gpn-dns`.
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Paths & constants
# ----------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || echo "${BASH_SOURCE[0]:-}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"   # repo 5gpn/ when run from a checkout

BASE_DIR="/opt/5gpn"                 # installed runtime root
BIN_DIR="${BASE_DIR}/bin"                # project-private binaries; never share /usr/local/bin names
SCRIPTS_DIR="${BASE_DIR}/scripts"        # installed copies of repo scripts
WWW_DIR="${BASE_DIR}/www"                # iOS profile web root (served in-process by 5gpn-dns)
BUILD_DIR="${BASE_DIR}/build"            # download/unpack scratch
BASE_OWNERSHIP_MARKER=".5gpn-owned"
BASE_OWNERSHIP_VALUE="5gpn-runtime-v1"

CONF_DIR="/etc/5gpn"                 # config: dns.env is the single source of truth
CONF_OWNERSHIP_MARKER=".5gpn-owned"
CONF_OWNERSHIP_VALUE="5gpn-config-v1"
STATE_DIR="/var/lib/5gpn"
STATE_OWNERSHIP_MARKER=".5gpn-owned"
STATE_OWNERSHIP_VALUE="5gpn-state-v1"
SWAP_FILE="${STATE_DIR}/swapfile"
SWAP_FSTAB_MARKER="# 5gpn-owned-swap-v1"
SWAP_CREATED_THIS_RUN=0
DNS_BIN="${BIN_DIR}/5gpn-dns"            # 5gpn-dns binary (DoT resolver + web console)
DNS_CERT_DIR="/etc/5gpn/cert"            # cert root; the ONE wildcard is copied into dot/, web/, zash/
DEBUG_CERT_DIR="/etc/5gpn/debug-cert"     # self-signed debug certs; NEVER under /etc/letsencrypt
DOT_CERT_DIR="${DNS_CERT_DIR}/dot"       # DoT :853 cert copy (hot-reloaded on mtime change)
WEB_CERT_DIR="${DNS_CERT_DIR}/web"       # loopback HTTPS console :443 cert copy
ZASH_CERT_DIR="${DNS_CERT_DIR}/zash"     # zashboard panel cert copy
ACME_DIR="/etc/5gpn/acme"                # root-only Cloudflare API-token credentials dir
CERT_DNS_RESOLVER="1.1.1.1"              # fixed independent resolver for ACME A/AAAA gates
CERT_DNS_WAIT_TIMEOUT=600                 # bounded install/configure propagation wait
CERT_DNS_WAIT_INTERVAL=10
CERT_RENEW_LOCK_FILE="/run/5gpn/cert-renew.lock"
LE_PRODUCTION_SERVER="https://acme-v02.api.letsencrypt.org/directory"
INSTALL_CERT_LOCK_HELD=0
DNS_WEB_DIR_DEFAULT="/opt/5gpn/web"         # resolved from dns.env after cfg_get is defined
# DNS_ZASH_DIR (zashboard SPA dist, config.go's ZashDir) is resolved just below
# cfg_get()'s definition -- NOT here: the daemon reads DNS_ZASH_DIR out of dns.env,
# so it must honor a dns.env value (cfg_get > default) and survive a bare
# re-install, and cfg_get isn't defined yet at this point in the file.
DNS_RULES_DIR_DEFAULT="/etc/5gpn/rules"  # rule files: blacklist.txt, direct.txt, etc.
MIHOMO_BIN="${BIN_DIR}/mihomo"
MIHOMO_DIR="/etc/5gpn/mihomo"           # config.yaml + whitelist.txt + provider caches
ZASH_OWNERSHIP_MARKER=".5gpn-zashboard-owned"
WEB_OWNERSHIP_MARKER=".5gpn-web-owned"
WEB_OWNERSHIP_VALUE="5gpn-web-v1"
IOS_OWNERSHIP_MARKER=".5gpn-ios-owned"
IOS_OWNERSHIP_VALUE="5gpn-ios-v1"
TEMP_OWNERSHIP_MARKER=".5gpn-temp-owned"
TEMP_OWNERSHIP_VALUE="5gpn-temp-v1"
MIHOMO_VERSION="v1.19.28"
MIHOMO_SHA256="70d01cfb8cb7bf7a92fd1af16cb4b9553d90bb4eecde3b5c4849103e27c80ddb"
ZASH_VERSION="v3.15.0"                   # Zephyruso/zashboard prebuilt dist.zip
ZASH_SHA256="adba7b03f3bec792a354e65469fb8ac5513e48e0f646650f78aa313bcf5b18e9"
# Legacy: SMARTDNS_DIR kept only for remove-on-upgrade logic below; not used by new install.
SMARTDNS_DIR="/etc/smartdns"
# Old sing-box paths are used only for ownership-gated migration diagnostics.
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/usr/local/etc/sing-box"
SINGBOX_UNIT="/etc/systemd/system/sing-box.service"
# NOTE: the legacy xray binary (/usr/local/bin/xray) + config dir (/usr/local/etc/xray)
# are NOT tracked as constants — mihomo replaced xray as the data plane. Their
# literal paths appear ONLY in the upgrade-from-xray teardown (clean_previous_install
# + uninstall), so a box migrating off xray gets them removed.
# Egress SNI re-resolver: the resolver the loopback DNS broker uses to turn a
# sniffed (often GFW-blocked) SNI into the real server IP before egress. Poison
# resistance matters — a plain resolver can be spoofed for exactly the blocked
# domains. DNS_EGRESS_RESOLVER=<ipv4> -> plain UDP; =https://…/dns-query -> DoH
# (recommended for real deployments). Unset -> the 22.22.22.22 sentinel.
# (Consumed by 5gpn-dns as DNS_EGRESS_RESOLVER, back-compat XRAY_RESOLVER.)
DNS_EGRESS_RESOLVER_DEFAULT="22.22.22.22"
# EDNS Client Subnet for the CHINA resolver group: the /24 of the clients'
# cellular egress IP, so CN CDNs schedule answers near the CLIENTS instead of
# near the gateway's own egress. Prompted at install (check ip.cn ON CELLULAR
# data); a bare IP is normalised to its /24 before persisting.
CHINA_ECS_DEFAULT="122.96.30.0"
GUM_VERSION="0.17.0"                     # charmbracelet/gum (prebuilt; installer TUI)
GUM_BIN="${BIN_DIR}/gum"
_HAVE_GUM=0                              # set by install_gum(); helpers fall back to echo when 0
export PATH="${BIN_DIR}:${PATH}"

# 5gpn-dns binary + web SPA release tag on moooyo/5gpn. This is the SINGLE
# default the whole installer resolves against (install_5gpndns / install_web),
# and it is what quick-install.sh passes through so the config files, the binary,
# and the SPA all come from the SAME release. The release pipeline STAMPS this
# exact line to the tag being cut (see .github/workflows/release.yml) so a
# packaged installer always pulls its OWN release's artifacts — eliminating the
# release-binary / working-tree-config skew that once broke the :443 webui.
DNS_VERSION_DEFAULT="0.0.1"

# ----------------------------------------------------------------------------
# Pretty output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
info() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "$*"; else echo "${BLUE}[INFO]${NC} $*"; fi; }
ok()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "✔ $*"; else echo "${GREEN}[OK]${NC}   $*"; fi; }
warn() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level warn  -- "$*"; else echo "${YELLOW}[WARN]${NC} $*"; fi; }
err()  { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level error -- "$*" >&2; else echo "${RED}[ERR]${NC}  $*" >&2; fi; }

# Interactive helpers (gum vs read). Callers gate on [[ -t 0 ]]; main() runs
# attach_tty first, so a piped `curl | sudo bash` install still has a terminal on
# stdin and these prompts fire as intended.
ask_text()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum input --prompt "$1 " --placeholder "${2:-}"; else local v; read -r -p "$1 " v; printf '%s' "$v"; fi; }
ask_secret() { if [[ "$_HAVE_GUM" == 1 ]]; then gum input --password --prompt "$1 "; else local v; read -r -p "$1 " v; printf '%s' "$v"; fi; }
ask_yesno()  { if [[ "$_HAVE_GUM" == 1 ]]; then gum confirm "$1"; else local a; read -r -p "$1 [y/N] " a; [[ "$a" == [yY]* ]]; fi; }
ask_choice() {
    local prompt="$1"; shift
    if [[ "$_HAVE_GUM" == 1 ]]; then
        printf '%s\n' "$@" | gum choose --header "$prompt"
    else
        local i=1 answer="" item
        echo "$prompt" >&2
        for item in "$@"; do printf '  %d) %s\n' "$i" "$item" >&2; i=$((i + 1)); done
        read -r -p "选择编号: " answer
        [[ "$answer" =~ ^[0-9]+$ && "$answer" -ge 1 && "$answer" -lt "$i" ]] || return 1
        printf '%s\n' "${!answer}"
    fi
}
# Run an opaque wait command behind a spinner when interactive; else run it plainly.
gum_spin()   { local t="$1"; shift; if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then gum spin --title "$t" -- "$@"; else "$@"; fi; }
# Frame multi-line stdin in a rounded box when interactive; else pass it through.
card()       { if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then gum style --border rounded --padding "0 1" --border-foreground 212; else cat; fi; }

# attach_tty makes a PIPED install interactive. Run via `curl | sudo bash`, fd 0 is
# the pipe/script, not the terminal, so [[ -t 0 ]] is false and EVERY prompt below
# is skipped — DOMAIN/GATEWAY_IP/XRAY_RESOLVER stay unset and the run aborts on the
# missing domain. If a controlling terminal exists, reattach stdin to it so the
# install prompts as intended. A first install with no /dev/tty fails closed;
# reinstall may reuse an already persisted valid dns.env. Called once from
# main(); a no-op when stdin is already a terminal.
attach_tty() {
    [[ -t 0 ]] && return 0
    if [[ -e /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then
        exec 0</dev/tty
        info "管道安装：已将输入接入当前终端 (/dev/tty)，将进行交互式提问（域名 / 网关IP / 解析器）。"
    fi
}

# ── Single config file ──────────────────────────────────────────────────────
# /etc/5gpn/dns.env is the ONE source of truth for every persisted knob. There
# are NO per-key .state files. Reinstall reads this file; first install writes it
# from the TUI. cfg_get reads one key from dns.env (empty if absent); it greps rather
# than sourcing so a value can contain any shell-special character safely.
cfg_get() {
    [[ -f "${CONF_DIR}/dns.env" ]] || return 0
    # `|| true` keeps cfg_get exit 0 even when the key is absent: under
    # `set -euo pipefail` a grep no-match (pipeline rc=1) inside a bare
    # `VAR="$(cfg_get X)"` assignment would otherwise abort the whole install.
    grep -E "^${1}=" "${CONF_DIR}/dns.env" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Caller configuration is discarded before command dispatch. systemd still
# reads the persisted dns.env when it launches the daemon.
clear_external_config_env() {
    unset BASE_DOMAIN WEB_DOMAIN CONSOLE_DOMAIN ZASH_DOMAIN DOT_DOMAIN \
        PUBLIC_IP GATEWAY_IP MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL EMAIL DEBUG \
        CF_API_TOKEN CLOUDFLARE_API_TOKEN DNS_EGRESS_RESOLVER XRAY_RESOLVER \
        DNS_CHINA_ECS CHINA_ECS CACHE_SIZE LOWMEM DNS_API_TOKEN TGBOT_TOKEN \
        TGBOT_ADMINS DNS_TGBOT_FILE TGBOT_PROXY_URL TGBOT_ALERTS DNS_CHINA DNS_TRUST \
        DNS_MAX_INFLIGHT DNS_TTL_MIN DNS_TTL_MAX DNS_QUERY_TIMEOUT DNS_HEARTBEAT_URL DNS_CHINA_0X20 \
        DNS_MIHOMO_CONTROLLER DNS_MIHOMO_SECRET DNS_WHITELIST_FILE DNS_ZASH_LISTEN \
        ADMIN_CIDR CHINA_LIST_URL GFW_URL DNS_VERSION DNS_SHA256 WEB_SHA256 \
        GUM_SHA256 ALLOW_UNSIGNED_PROFILE SKIP_CONSOLE_DNS_CHECK
}

# DNS_ZASH_DIR resolves dns.env (cfg_get) > default HERE, right after
# cfg_get is defined -- so install_zashboard / clean_previous_install / uninstall
# (which all read the global $DNS_ZASH_DIR) honor an operator's dns.env value and
# it survives a bare re-install, matching DNS_ZASH_LISTEN. Do NOT move this back
# up into the constants block: cfg_get() isn't defined there, so it would silently
# fall through to the default and clobber a customized dns.env value on re-install.
DNS_WEB_DIR="$(cfg_get DNS_WEB_DIR)"
DNS_WEB_DIR="${DNS_WEB_DIR:-$DNS_WEB_DIR_DEFAULT}"
DNS_ZASH_DIR="$(cfg_get DNS_ZASH_DIR)"
DNS_ZASH_DIR="${DNS_ZASH_DIR:-/opt/5gpn/zash}"

# Canonicalize a directory without requiring its final component to exist.
# Deletion helpers below only operate on the returned path after checking a
# project ownership marker. This protects root-run cleanup from a typo or a
# malicious symlink in DNS_ZASH_DIR.
canonical_dir_path() {
    local p="$1" cur suffix="" leaf
    [[ "$p" == /* ]] || p="$PWD/$p"
    if command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1; then
        realpath -m -- "$p"
    elif command -v readlink >/dev/null 2>&1 && readlink -m / >/dev/null 2>&1; then
        readlink -m -- "$p"
    else
        # Portable fallback (BSD/macOS realpath lacks -m): walk to the deepest
        # existing parent, resolve that with physical `pwd`, then append the
        # missing components. Reject dot traversal rather than normalising it
        # lexically in a root-run deletion path.
        [[ "$p" != *'/../'* && "$p" != */.. && "$p" != *'/./'* ]] || return 1
        cur="$p"
        while [[ ! -e "$cur" && "$cur" != / ]]; do
            leaf="$(basename -- "$cur")"
            suffix="/${leaf}${suffix}"
            cur="$(dirname -- "$cur")"
        done
        [[ -d "$cur" ]] || return 1
        cur="$(cd -P -- "$cur" && pwd)" || return 1
        printf '%s%s\n' "$cur" "$suffix"
    fi
}

write_ownership_marker() {
    local dir="$1" name="$2" value="$3" tmp
    if [[ ! -e "$dir" ]]; then
        install -d -m 0755 -- "$dir" || return 1
    fi
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    tmp="$(mktemp "${dir}/.${name}.XXXXXX")" || return 1
    printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dir/$name" || { rm -f -- "$tmp"; return 1; }
}

verify_ownership_marker() {
    local dir="$1" name="$2" value="$3" marker="$dir/$name"
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(cat "$marker" 2>/dev/null || true)" == "$value" ]]
}

claim_temp_dir() {
    local dir="$1" canonical
    canonical="$(canonical_dir_path "$dir")" || return 1
    [[ "$canonical" == "$dir" ]] || return 1
    case "$canonical" in /tmp/5gpn-*|/var/tmp/5gpn-*) ;; *) return 1 ;; esac
    write_ownership_marker "$canonical" "$TEMP_OWNERSHIP_MARKER" "$TEMP_OWNERSHIP_VALUE"
}

remove_temp_dir() {
    local dir="$1" canonical
    [[ -n "$dir" && -e "$dir" ]] || return 0
    canonical="$(canonical_dir_path "$dir")" || return 1
    [[ "$canonical" == "$dir" ]] || return 1
    case "$canonical" in /tmp/5gpn-*|/var/tmp/5gpn-*) ;; *) return 1 ;; esac
    verify_ownership_marker "$canonical" "$TEMP_OWNERSHIP_MARKER" "$TEMP_OWNERSHIP_VALUE" || return 1
    rm -rf -- "$canonical"
}

legacy_base_owned() {
    [[ -f "$BASE_DIR/install.sh" && ! -L "$BASE_DIR/install.sh" ]] || return 1
    grep -qF '5gpn installer / orchestrator' "$BASE_DIR/install.sh" 2>/dev/null
}

legacy_conf_owned() {
    [[ -f "$CONF_DIR/dns.env" && ! -L "$CONF_DIR/dns.env" ]] || return 1
    grep -qF '# 5gpn-dns config' "$CONF_DIR/dns.env" 2>/dev/null \
        && grep -qE '^DNS_LISTEN_DOT=:853$' "$CONF_DIR/dns.env" 2>/dev/null
}

claim_fixed_owned_dir() {
    local dir="$1" marker="$2" value="$3" legacy_check="$4" canonical nonempty=0
    canonical="$(canonical_dir_path "$dir")" \
        || { err "Could not canonicalize project directory: $dir"; return 1; }
    [[ "$canonical" == "$dir" ]] \
        || { err "Refusing project directory symlink/alias: $dir -> $canonical"; return 1; }
    [[ ! -e "$dir" || -d "$dir" ]] \
        || { err "Project path exists but is not a directory: $dir"; return 1; }
    [[ -d "$dir" && -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && nonempty=1
    if verify_ownership_marker "$dir" "$marker" "$value"; then
        return 0
    fi
    if [[ -e "$dir/$marker" ]]; then
        err "Invalid or symlinked ownership marker: $dir/$marker"
        return 1
    fi
    if [[ "$nonempty" == 1 ]]; then
        "$legacy_check" \
            || { err "Refusing non-empty unowned project directory: $dir"; return 1; }
        warn "Adopting strongly fingerprinted legacy 5gpn directory: $dir"
    fi
    write_ownership_marker "$dir" "$marker" "$value" \
        || { err "Could not write ownership marker under $dir"; return 1; }
}

legacy_state_owned() { return 1; }

claim_project_roots() {
    claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" legacy_base_owned
    claim_fixed_owned_dir "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" legacy_conf_owned
    claim_fixed_owned_dir "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" legacy_state_owned
}

remove_fixed_owned_dir() {
    local dir="$1" marker="$2" value="$3" canonical
    [[ -e "$dir" ]] || return 0
    canonical="$(canonical_dir_path "$dir")" || return 1
    [[ "$canonical" == "$dir" ]] || { err "Refusing directory alias during removal: $dir"; return 1; }
    verify_ownership_marker "$dir" "$marker" "$value" \
        || { err "Refusing to remove unowned directory: $dir"; return 1; }
    rm -rf -- "$dir"
}

safe_zashboard_path() {
    local p
    [[ -n "${DNS_ZASH_DIR:-}" && "$DNS_ZASH_DIR" != *$'\n'* && "$DNS_ZASH_DIR" != *$'\r'* ]] \
        || { err "DNS_ZASH_DIR is empty or contains a newline; refusing it."; return 1; }
    p="$(canonical_dir_path "$DNS_ZASH_DIR")" \
        || { err "Could not canonicalize DNS_ZASH_DIR='$DNS_ZASH_DIR'."; return 1; }
    case "$p" in
        /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/home|/home/*|/lib|/lib/*|/lib64|/lib64/*|/opt|/private/etc|/private/etc/*|/private/tmp|/private/tmp/*|/private/var|/private/var/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/srv|/sys|/sys/*|/tmp|/tmp/*|/usr|/usr/*|/var|/var/*|"$BASE_DIR"|"$CONF_DIR")
            err "Refusing unsafe DNS_ZASH_DIR: $p"; return 1 ;;
    esac
    printf '%s\n' "$p"
}

# Claim the zashboard directory before ever clearing it. The exact default
# below BASE_DIR is already project-owned; an external legacy install can be
# adopted only when its zashboard version marker + index are both present.
claim_zashboard_dir() {
    local p marker current nonempty=0
    p="$(safe_zashboard_path)" || return 1
    DNS_ZASH_DIR="$p"
    marker="$p/$ZASH_OWNERSHIP_MARKER"
    if [[ -e "$p" && ! -d "$p" ]]; then
        err "DNS_ZASH_DIR exists but is not a directory: $p"; return 1
    fi
    [[ -d "$p" && -n "$(find "$p" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && nonempty=1
    if [[ -e "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker" ]] \
            || { err "Invalid zashboard ownership marker: $marker"; return 1; }
        current="$(cat "$marker" 2>/dev/null || true)"
        [[ "$current" == '5gpn-zashboard-v1' ]] \
            || { err "Unknown zashboard ownership marker contents in $marker"; return 1; }
    elif [[ "$p" == "$BASE_DIR"/* ]] || [[ "$nonempty" == 0 ]] \
         || { [[ -f "$p/.zash_version" && -f "$p/index.html" ]]; }; then
        mkdir -p -- "$p"
        printf '%s\n' '5gpn-zashboard-v1' > "$marker"
    else
        err "Refusing non-empty external DNS_ZASH_DIR without a 5gpn ownership marker: $p"
        return 1
    fi
    export DNS_ZASH_DIR
}

clear_zashboard_dir() {
    claim_zashboard_dir || return 1
    find "$DNS_ZASH_DIR" -mindepth 1 -maxdepth 1 ! -name "$ZASH_OWNERSHIP_MARKER" \
        -exec rm -rf -- {} +
}

remove_zashboard_dir() {
    local p marker
    p="$(safe_zashboard_path)" || return 1
    [[ -e "$p" ]] || return 0
    marker="$p/$ZASH_OWNERSHIP_MARKER"
    [[ -f "$marker" && ! -L "$marker" ]] \
        && [[ "$(cat "$marker" 2>/dev/null || true)" == '5gpn-zashboard-v1' ]] \
        || { err "Refusing to remove unowned zashboard directory: $p"; return 1; }
    rm -rf -- "$p"
}

safe_web_path() {
    local p
    [[ -n "$DNS_WEB_DIR" && "$DNS_WEB_DIR" != *$'\n'* && "$DNS_WEB_DIR" != *$'\r'* ]] || return 1
    p="$(canonical_dir_path "$DNS_WEB_DIR")" || return 1
    case "$p" in
        /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/home|/home/*|/lib|/lib/*|/lib64|/lib64/*|/opt|/private/etc|/private/etc/*|/private/tmp|/private/tmp/*|/private/var|/private/var/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/srv|/sys|/sys/*|/tmp|/tmp/*|/usr|/usr/*|/var|/var/*|"$BASE_DIR"|"$CONF_DIR")
            err "Refusing unsafe DNS_WEB_DIR: $p"; return 1 ;;
    esac
    printf '%s\n' "$p"
}

claim_web_dir() {
    local p marker nonempty=0
    p="$(safe_web_path)" || return 1
    DNS_WEB_DIR="$p"
    marker="$p/$WEB_OWNERSHIP_MARKER"
    [[ ! -e "$p" || -d "$p" ]] || { err "DNS_WEB_DIR is not a directory: $p"; return 1; }
    [[ -d "$p" && -n "$(find "$p" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && nonempty=1
    if verify_ownership_marker "$p" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"; then
        return 0
    fi
    [[ ! -e "$marker" ]] || { err "Invalid web ownership marker: $marker"; return 1; }
    if [[ "$nonempty" == 1 && "$p" != "$BASE_DIR"/* ]]; then
        [[ -f "$p/.web_version" && -f "$p/index.html" ]] \
            || { err "Refusing non-empty external DNS_WEB_DIR without a 5gpn fingerprint: $p"; return 1; }
        warn "Adopting strongly fingerprinted legacy web directory: $p"
    fi
    write_ownership_marker "$p" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"
}

publish_owned_tree() {
    local src="$1" dest="$2" marker="$3" value="$4" parent leaf candidate backup
    parent="$(dirname -- "$dest")"; leaf="$(basename -- "$dest")"
    candidate="$(mktemp -d "${parent}/.${leaf}.new.XXXXXX")" || return 1
    write_ownership_marker "$candidate" "$marker" "$value" \
        || { rmdir -- "$candidate"; return 1; }
    cp -a -- "$src/." "$candidate/" || { rm -rf -- "$candidate"; return 1; }
    write_ownership_marker "$candidate" "$marker" "$value" \
        || { rm -rf -- "$candidate"; return 1; }
    backup="${parent}/.${leaf}.old.$$"
    if [[ -e "$dest" ]]; then
        verify_ownership_marker "$dest" "$marker" "$value" \
            || { rm -rf -- "$candidate"; err "Refusing to replace unowned tree: $dest"; return 1; }
        mv -- "$dest" "$backup" || { rm -rf -- "$candidate"; return 1; }
    fi
    if ! mv -- "$candidate" "$dest"; then
        [[ -e "$backup" ]] && mv -- "$backup" "$dest"
        return 1
    fi
    if [[ -e "$backup" ]]; then
        verify_ownership_marker "$backup" "$marker" "$value" && rm -rf -- "$backup"
    fi
}

claim_ios_dir() {
    local nonempty=0
    [[ ! -e "$WWW_DIR" || -d "$WWW_DIR" ]] || return 1
    [[ -d "$WWW_DIR" && -n "$(find "$WWW_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && nonempty=1
    if verify_ownership_marker "$WWW_DIR" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE"; then
        return 0
    fi
    [[ ! -e "$WWW_DIR/$IOS_OWNERSHIP_MARKER" ]] || return 1
    if [[ "$nonempty" == 1 ]]; then
        [[ -f "$WWW_DIR/index.html" || -f "$WWW_DIR/ios-dot.mobileconfig" ]] || return 1
    fi
    write_ownership_marker "$WWW_DIR" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE"
}

# Bootstrap gum (prebuilt binary + sha256 verify). Never fatal: on any failure
# _HAVE_GUM stays 0 and all helpers fall back to plain echo.
install_gum() {
    claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" legacy_base_owned \
        || { _HAVE_GUM=0; return 1; }
    # Only trust a gum that THIS process already verified. An arbitrary binary
    # on PATH with a matching --version is not supply-chain evidence.
    if [[ "$_HAVE_GUM" == 1 ]] && command -v gum >/dev/null 2>&1 \
       && gum --version 2>/dev/null | grep -qF "$GUM_VERSION"; then return 0; fi
    _HAVE_GUM=0
    local arch url tmp exp got bin m
    m="$(uname -m 2>/dev/null || echo x86_64)"
    case "$m" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="arm64"  ;;
        armv7l|armhf)  arch="armv7"  ;;
        *)             arch="x86_64" ;;
    esac
    url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${arch}.tar.gz"
    tmp="$(mktemp -d /tmp/5gpn-gum.XXXXXX 2>/dev/null)" || { warn "gum: mktemp failed; using plain output."; _HAVE_GUM=0; return 0; }
    claim_temp_dir "$tmp" || { rmdir -- "$tmp" 2>/dev/null || true; warn "gum: could not claim temp directory; using plain output."; return 0; }
    if ! command -v curl >/dev/null 2>&1 \
       || ! curl -fsSL "$url" -o "$tmp/gum.tgz" 2>/dev/null; then
        warn "gum download failed; using plain output."
        remove_temp_dir "$tmp"; return 0
    fi

    exp=""
    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/checksums.txt" \
         -o "$tmp/sums.txt" 2>/dev/null \
        && exp="$(awk -v f="gum_${GUM_VERSION}_Linux_${arch}.tar.gz" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/sums.txt" 2>/dev/null || true)"
    exp="${exp,,}"
    if [[ ! "$exp" =~ ^[0-9a-f]{64}$ ]]; then
        warn "gum checksum is missing or invalid; refusing to install it and using plain output."
        remove_temp_dir "$tmp"; return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        got="$(sha256sum "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
    elif command -v shasum >/dev/null 2>&1; then
        got="$(shasum -a 256 "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
    else
        warn "no SHA-256 tool is available; refusing to install gum and using plain output."
        remove_temp_dir "$tmp"; return 0
    fi
    got="${got,,}"
    if [[ "$got" != "$exp" ]]; then
        warn "gum sha256 mismatch; refusing to install it and using plain output."
        remove_temp_dir "$tmp"; return 0
    fi
    if ! tar -xzf "$tmp/gum.tgz" -C "$tmp" 2>/dev/null; then
        warn "gum archive extraction failed; using plain output."
        remove_temp_dir "$tmp"; return 0
    fi
    bin="$(find "$tmp" -type f -name gum 2>/dev/null | head -1 || true)"
    if [[ -z "$bin" ]] || ! "$bin" --version 2>/dev/null | grep -qF "$GUM_VERSION" \
       || ! publish_executable "$bin" "$GUM_BIN" 2>/dev/null; then
        warn "verified gum archive did not contain an installable ${GUM_VERSION} binary; using plain output."
        remove_temp_dir "$tmp"; return 0
    fi
    remove_temp_dir "$tmp" 2>/dev/null || true
    if command -v gum >/dev/null 2>&1 \
       && gum --version 2>/dev/null | grep -qF "$GUM_VERSION"; then
        _HAVE_GUM=1
    else
        _HAVE_GUM=0; warn "gum verification succeeded but the installed binary is unavailable; using plain output."
    fi
    return 0
}

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# OS / memory / network detection
# ----------------------------------------------------------------------------
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "Cannot detect OS (/etc/os-release missing)."; exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS="${ID:-unknown}"; VER="${VERSION_ID:-?}"
    case "$OS" in
        ubuntu|debian|raspbian|linuxmint|pop) PKG_MGR="apt-get" ;;
        centos|rhel|rocky|almalinux|fedora|ol)
            if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi ;;
        *)  # best-effort fallback by available manager
            if   command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
            elif command -v dnf     >/dev/null 2>&1; then PKG_MGR="dnf"
            elif command -v yum     >/dev/null 2>&1; then PKG_MGR="yum"
            else err "Unsupported OS '$OS' and no known package manager."; exit 1; fi ;;
    esac
    info "Detected OS: $OS $VER (package manager: $PKG_MGR)"
}

# CPU arch guard: the 5gpn-dns and mihomo downloads below are linux-amd64
# prebuilts ONLY (no other arch is published for 5gpn-dns). Without this, an ARM
# box installs to the end, prints ✅, and the services die with "exec format
# error" at first start. Refuse early instead. (gum's own bootstrap is
# multi-arch and unaffected — but there is nothing for it to install.)
check_arch() {
    local m; m="$(uname -m 2>/dev/null || echo unknown)"
    case "$m" in
        x86_64|amd64) ;;
        *)
            err "Unsupported CPU architecture '${m}': only linux-amd64 prebuilt binaries are published for 5gpn-dns and mihomo."
            err "Use an x86_64 host, or build cmd/5gpn-dns/ (and fetch a matching mihomo) yourself and install the binaries manually."
            exit 1
            ;;
    esac
}

# Sets MEM_TOTAL_MB, LOWMEM (0/1), MAKE_JOBS, CACHE_SIZE from host memory.
detect_memory_profile() {
    MEM_TOTAL_MB=$(awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "${MEM_TOTAL_MB:-0}" -le 1300 ]]; then LOWMEM=1; else LOWMEM=0; fi

    # RAM-derived cache default only; full_install resolves the effective
    # CACHE_SIZE (persisted dns.env > this default) — the single-source
    # config model, no separate .cache_size state file.
    if [[ "$LOWMEM" == "1" ]]; then
        MAKE_JOBS=1; _CACHE_SIZE_DEFAULT=20000
    else
        MAKE_JOBS="$(nproc 2>/dev/null || echo 2)"; _CACHE_SIZE_DEFAULT=512000
    fi
    if [[ "$LOWMEM" == "1" ]]; then
        warn "Low-memory mode ON (RAM ${MEM_TOTAL_MB}MB): 1 build job, swap ensured (cache default ${_CACHE_SIZE_DEFAULT})."
    else
        info "Standard memory mode (RAM ${MEM_TOTAL_MB}MB): cache default ${_CACHE_SIZE_DEFAULT}."
    fi
}

ensure_swap() {
    [[ "${LOWMEM:-0}" == "1" ]] || return 0
    if [[ "$(wc -l < /proc/swaps 2>/dev/null || echo 1)" -gt 1 ]]; then
        info "Swap already present."; return 0
    fi
    verify_ownership_marker "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" \
        || { err "State directory ownership is not established; refusing swap creation."; return 1; }
    if [[ -e "$SWAP_FILE" ]]; then
        [[ -f "$SWAP_FILE" && ! -L "$SWAP_FILE" ]] \
            || { err "Owned swap path is not a regular file: $SWAP_FILE"; return 1; }
        info "5gpn swapfile already present."
        return 0
    fi
    local avail_mb; avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "$avail_mb" || "$avail_mb" -lt 1536 ]]; then
        warn "Not enough free disk for a swapfile (${avail_mb:-?}MB); skipping."; return 0
    fi
    info "Creating 1G swapfile (low-memory host)..."
    fallocate -l 1G "$SWAP_FILE" 2>/dev/null \
        || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=1024 status=none 2>/dev/null || {
        warn "swapfile allocation failed; continuing without swap."; rm -f -- "$SWAP_FILE"; return 0; }
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null 2>&1 && swapon "$SWAP_FILE" 2>/dev/null || {
        warn "mkswap/swapon failed; skipping swap."; rm -f -- "$SWAP_FILE"; return 0; }
    SWAP_CREATED_THIS_RUN=1
    grep -qF "$SWAP_FILE none swap sw 0 0 $SWAP_FSTAB_MARKER" /etc/fstab 2>/dev/null \
        || printf '%s none swap sw 0 0 %s\n' "$SWAP_FILE" "$SWAP_FSTAB_MARKER" >> /etc/fstab
    ok "1G swapfile active."
}

get_public_ip() {
    if [[ -n "${PUBLIC_IP:-}" ]]; then info "Using PUBLIC_IP override: $PUBLIC_IP"; return 0; fi
    # Prefer the gateway's own egress source address (this box IS the gateway).
    PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo "")
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null \
                 || curl -4 -s --max-time 10 https://ifconfig.me   2>/dev/null \
                 || curl -4 -s --max-time 10 https://icanhazip.com 2>/dev/null || echo "")
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        err "Failed to detect public IPv4. Enter it through the attached-terminal TUI."; exit 1
    fi
    info "Public IPv4: $PUBLIC_IP"
}

local_ipv4_present() {
    local want="$1"
    command -v ip >/dev/null 2>&1 || return 1
    ip -o -4 addr show 2>/dev/null \
        | awk -v want="$want" '{ split($4, a, "/"); if (a[1] == want) found=1 } END { exit(found ? 0 : 1) }'
}

# Resolve the dedicated mihomo bind addresses. PUBLIC_IP is deployment identity
# (and may be a provider/NAT address), while GATEWAY_IP is what DNS returns to
# clients; neither is automatically a valid local bind target. The persisted
# DNS_MIHOMO_LISTEN_IPS list contains only addresses actually assigned to this
# host. Loopback is forbidden because 127.0.0.1:443 and 127.0.0.2:443 belong to
# the console/zashboard listeners behind mihomo's SNI split.
resolve_mihomo_listen_ips() {
    local requested="${1:-}" ip route_src out="" count=0
    local candidates="$requested"
    if [[ -z "$candidates" ]]; then
        candidates="${GATEWAY_IP:-},${PUBLIC_IP:-}"
        route_src="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 || true)"
        candidates="${candidates},${route_src}"
    fi
    while IFS= read -r ip; do
        ip="${ip//[[:space:]]/}"
        [[ -n "$ip" ]] || continue
        is_valid_ipv4 "$ip" || { err "Invalid IPv4 in MIHOMO_LISTEN_IPS: '$ip'"; return 1; }
        [[ "$ip" != 127.* ]] \
            || { err "MIHOMO_LISTEN_IPS may not use loopback ($ip); loopback :443 belongs to the panels."; return 1; }
        if ! local_ipv4_present "$ip"; then
            if [[ -n "$requested" ]]; then
                err "MIHOMO_LISTEN_IPS address $ip is not assigned to a local interface."
                return 1
            fi
            continue
        fi
        case ",$out," in *",$ip,"*) continue ;; esac
        out="${out:+$out,}$ip"
        count=$((count + 1))
        [[ "$count" -le 16 ]] \
            || { err "MIHOMO_LISTEN_IPS supports at most 16 local addresses."; return 1; }
    done < <(printf '%s\n' "$candidates" | tr ',' '\n')
    [[ -n "$out" ]] \
        || { err "No locally assigned non-loopback IPv4 is available for mihomo. Set MIHOMO_LISTEN_IPS=<local-ip>[,<local-ip>...]."; return 1; }
    printf '%s\n' "$out"
}

render_mihomo_listeners() {
    local ips="$1" ip idx=0 suffix
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        idx=$((idx + 1)); suffix=""
        [[ "$idx" -gt 1 ]] && suffix="-${idx}"
        printf '  - {name: sniproxy%s, type: tunnel, listen: %s, port: 443, network: [tcp, udp], target: 127.0.0.1:443}\n' "$suffix" "$ip"
        printf '  - {name: sniproxy80%s, type: tunnel, listen: %s, port: 80, network: [tcp], target: 127.0.0.1:80}\n' "$suffix" "$ip"
    done < <(printf '%s\n' "$ips" | tr ',' '\n')
}

# ----------------------------------------------------------------------------
# Dependencies
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Fresh-artifact guarantee: every install run removes all previously installed
# units / generated configs / runtime tree, and every binary is unconditionally
# re-downloaded at its pin (install(1) overwrite — see install_5gpndns/
# install_mihomo) — so a re-run can never leave a stale artifact next to a new
# one. ONLY /etc/5gpn (dns.env, token, certs, rules, subscriptions) and the
# /etc/letsencrypt lineage persist.
#
# Deliberately does NOT stop the running 5gpn-dns/mihomo processes: unlinked
# files keep their inodes while the processes run, so the resolver stays up
# through the whole install; start_services restarts into the fresh artifacts
# at the end. Legacy units (python control plane, socket iOS responder,
# smartdns/xray data planes) ARE stopped; a sing-box unit is stopped only when
# its unit file carries an explicit 5gpn fingerprint. This keeps unrelated
# operator-managed sing-box installations intact while allowing a verified
# legacy unit to release :443/:80 for mihomo.
# The gum binary is NOT removed (the running installer's own TUI helpers exec
# it); install_gum refreshes it in place when the GUM_VERSION pin moves.
legacy_singbox_unit_owned() {
    [[ -f "$SINGBOX_UNIT" ]] || return 1
    grep -Eiq '^[[:space:]]*(Description=5gpn([[:space:]:_-]|$)|#[[:space:]]*(Managed|Installed) by 5gpn([[:space:]]|$))' \
        "$SINGBOX_UNIT"
}

unit_file_owned_by_5gpn() {
    local unit="$1" file="/etc/systemd/system/$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    grep -Eiq '^[[:space:]]*(Description=5gpn([[:space:]:_-]|$)|#[[:space:]]*(Managed|Installed) by 5gpn([[:space:]]|$))' "$file"
}

remove_owned_unit() {
    local unit="$1"
    if unit_file_owned_by_5gpn "$unit"; then
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f -- "/etc/systemd/system/$unit"
        ok "Removed 5gpn-owned unit: $unit"
        return 0
    fi
    if systemctl cat "$unit" >/dev/null 2>&1 || [[ -e "/etc/systemd/system/$unit" ]]; then
        warn "Preserving unowned unit: $unit"
    fi
}

remove_legacy_xray() {
    if unit_file_owned_by_5gpn xray.service; then
        systemctl disable --now xray.service 2>/dev/null || true
        rm -f -- /etc/systemd/system/xray.service
        rm -f -- /usr/local/etc/xray/config.json /usr/local/bin/xray
        rmdir -- /usr/local/etc/xray 2>/dev/null || true
        ok "Removed fingerprinted legacy 5gpn Xray artifacts."
    elif systemctl cat xray.service >/dev/null 2>&1 \
         || [[ -e /usr/local/bin/xray || -e /usr/local/etc/xray ]]; then
        warn "Preserving Xray artifacts because 5gpn ownership cannot be established."
    fi
}

remove_legacy_generic_unit() {
    local unit="$1"
    if unit_file_owned_by_5gpn "$unit"; then
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f -- "/etc/systemd/system/$unit"
        ok "Removed fingerprinted legacy 5gpn unit: $unit"
    elif systemctl cat "$unit" >/dev/null 2>&1 || [[ -e "/etc/systemd/system/$unit" ]]; then
        warn "Preserving unowned legacy unit: $unit"
    fi
}

remove_legacy_singbox() {
    if legacy_singbox_unit_owned; then
        systemctl disable --now sing-box.service 2>/dev/null || true
        rm -f -- "$SINGBOX_UNIT"
        ok "Removed the fingerprinted legacy 5gpn sing-box unit; preserved shared binary and config paths."
        return 0
    fi
    if [[ -e "$SINGBOX_BIN" || -e "$SINGBOX_DIR" || -e "$SINGBOX_UNIT" ]]; then
        warn "Preserving sing-box artifacts because 5gpn ownership cannot be established."
    fi
}

clean_previous_install() {
    info "Cleaning previous install artifacts (units + generated configs; /etc/5gpn kept)..."

    # Validate/claim a custom zashboard path before the BASE_DIR sweep below.
    # This makes later cleanup depend on a strong ownership marker instead of
    # trusting an arbitrary root-supplied DNS_ZASH_DIR.
    claim_zashboard_dir

    # Current units and renewal automation stay in place until validated
    # replacements are published. Never dismantle the rollback path here.

    # Legacy units: stop + remove (regenerated later where still applicable,
    # e.g. the renew timer via install_renewal_automation).
    local unit
    for unit in 5gpn-api.service 5gpn-tgbot.service 5gpn-iosprofile.socket \
                '5gpn-iosprofile@.service'; do
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/$unit"
    done
    remove_legacy_xray
    remove_legacy_generic_unit smartdns.service
    remove_legacy_generic_unit sniproxy.service
    remove_legacy_singbox
    systemctl daemon-reload 2>/dev/null || true

    # Generated runtime configs + tuning (all regenerated later this run).
    rm -f /etc/letsencrypt/renewal-hooks/pre/10-5gpn-stop-xray.sh \
          /etc/letsencrypt/renewal-hooks/post/10-5gpn-start-xray.sh \
          /etc/letsencrypt/renewal-hooks/pre/10-5gpn-open80.sh \
          /etc/letsencrypt/renewal-hooks/post/10-5gpn-close80.sh
    rm -f /etc/sysctl.d/99-5gpn.conf /etc/modules-load.d/5gpn.conf /etc/modprobe.d/5gpn.conf

    # Keep the currently runnable runtime tree until each replacement is ready.
    # Only the owned scratch directory is disposable here; binaries and panel
    # trees are published atomically later in the run.
    if [[ -d "$BASE_DIR" ]]; then
        verify_ownership_marker "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
            || { err "Runtime ownership marker vanished; refusing cleanup."; return 1; }
        if [[ -d "$BUILD_DIR" ]]; then
            rm -rf -- "$BUILD_DIR"
        fi
    fi
    # Custom panel trees outside BASE_DIR remain live until their fully staged
    # replacements are published by install_web/install_zashboard.

    ok "Previous artifacts cleaned (kept: ${CONF_DIR}, /etc/letsencrypt)."
}

# Remove retired draft/generation and structured-egress state on upgrade. Keep
# this outside clean_previous_install: that function's contract is to leave
# /etc/5gpn entirely untouched, while this narrow migration deliberately
# removes only stores that no current daemon path reads. The live unified
# policy model at /etc/5gpn/policy.json is intentionally preserved.
remove_legacy_policy_state() {
    if [[ -d "${CONF_DIR}/policy" ]]; then
        warn "Preserving unmarked retired ${CONF_DIR}/policy directory; current daemon ignores it."
    fi
    rm -f "${CONF_DIR}/egress.json" "${CONF_DIR}/egress-nodes.enc"
}

install_deps() {
    info "Installing dependencies..."
    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || true
            apt-get install -y -qq \
                wget curl ca-certificates unzip iproute2 openssl \
                qrencode jq libcap2-bin util-linux \
                dnsutils || warn "some apt packages failed; continuing."
            if [[ "$CERT_MODE" != debug ]]; then
                apt-get install -y -qq certbot \
                    || { err "Could not install certbot from the OS repository."; return 1; }
            fi
            if [[ "$CERT_MODE" == cloudflare ]]; then
                apt-get install -y -qq python3-certbot-dns-cloudflare \
                    || { err "Could not install the Cloudflare DNS plugin from the OS repository."; return 1; }
            fi
            ;;
        dnf|yum)
            $PKG_MGR install -y -q \
                wget curl ca-certificates unzip iproute openssl \
                qrencode jq util-linux \
                bind-utils || warn "some rpm packages failed; continuing."
            if [[ "$CERT_MODE" != debug ]]; then
                $PKG_MGR install -y -q certbot \
                    || { err "Could not install certbot from the OS repository."; return 1; }
            fi
            if [[ "$CERT_MODE" == cloudflare ]]; then
                $PKG_MGR install -y -q python3-certbot-dns-cloudflare \
                    || { err "Could not install the Cloudflare DNS plugin from the OS repository."; return 1; }
            fi
            # libcap setcap tooling (name varies by distro)
            $PKG_MGR install -y -q libcap libcap-ng-utils 2>/dev/null || true
            ;;
    esac
    local cmd
    for cmd in curl openssl tar gzip unzip sha256sum ip flock; do
        command -v "$cmd" >/dev/null 2>&1 \
            || { err "Required command is missing after dependency install: $cmd"; return 1; }
    done
    if [[ "$CERT_MODE" != debug ]]; then
        command -v dig >/dev/null 2>&1 \
            || { err "dig is required for public DNS verification in production certificate modes."; return 1; }
    fi
    if [[ "$CERT_MODE" != debug ]]; then
        command -v certbot >/dev/null 2>&1 && certbot --version >/dev/null 2>&1 \
            || { err "Working certbot is required for production certificates."; return 1; }
    fi
    if [[ "$CERT_MODE" == cloudflare ]]; then
        certbot plugins 2>/dev/null | grep -q dns-cloudflare \
            || { err "certbot-dns-cloudflare plugin is required for renewal."; return 1; }
    fi
}

# Download every executable/static artifact into a disposable directory outside
# the live runtime. Nothing below publishes to the working installation until
# every digest and archive has passed validation.
ARTIFACT_STAGE=""
ROLLBACK_DIR=""
INSTALL_TRANSACTION_ACTIVE=0

sha256_of() { sha256sum "$1" | awk '{print tolower($1)}'; }

verify_sha256() {
    local file="$1" expected="${2,,}" got
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] \
        || { err "Missing/invalid pinned SHA-256 for $(basename "$file")."; return 1; }
    got="$(sha256_of "$file")"
    [[ "$got" == "$expected" ]] \
        || { err "SHA-256 mismatch for $(basename "$file") (want $expected got $got)."; return 1; }
}

release_checksum() {
    local sums="$1" asset="$2"
    awk -v f="$asset" '$2 == f || $2 == "*" f { print tolower($1); exit }' "$sums"
}

archive_paths_safe() {
    local kind="$1" archive="$2" entry
    if [[ "$kind" == tar ]]; then
        while IFS= read -r entry; do
            [[ -n "$entry" && "$entry" != /* && "$entry" != ../* && "$entry" != *'/../'* && "$entry" != */.. ]] \
                || return 1
        done < <(tar -tzf "$archive")
    else
        while IFS= read -r entry; do
            [[ -n "$entry" && "$entry" != /* && "$entry" != ../* && "$entry" != *'/../'* && "$entry" != */.. ]] \
                || return 1
        done < <(unzip -Z1 "$archive")
    fi
}

stage_artifacts() {
    local ver="$DNS_VERSION_DEFAULT" web_ver="${DNS_VERSION_DEFAULT#dns-}"
    local release="https://github.com/moooyo/5gpn/releases/download/${ver}"
    local dns_asset="5gpn-dns-linux-amd64" web_asset="5gpn-web-${web_ver}.tar.gz"
    ARTIFACT_STAGE="$(mktemp -d /var/tmp/5gpn-artifacts.XXXXXX)" \
        || { err "Could not create artifact staging directory."; return 1; }
    chmod 0700 "$ARTIFACT_STAGE"
    claim_temp_dir "$ARTIFACT_STAGE" \
        || { rmdir -- "$ARTIFACT_STAGE"; err "Could not claim artifact staging directory."; return 1; }
    info "Staging pinned release artifacts (${ver})..."
    curl -fsSL "$release/checksums.txt" -o "$ARTIFACT_STAGE/checksums.txt" \
        || { err "Could not download release checksums.txt."; return 1; }
    curl -fsSL "$release/$dns_asset" -o "$ARTIFACT_STAGE/5gpn-dns" \
        || { err "Could not download $dns_asset."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/5gpn-dns" \
        "$(release_checksum "$ARTIFACT_STAGE/checksums.txt" "$dns_asset")" || return 1
    chmod 0755 "$ARTIFACT_STAGE/5gpn-dns"
    "$ARTIFACT_STAGE/5gpn-dns" -version >/dev/null 2>&1 \
        || { err "Staged 5gpn-dns binary did not execute."; return 1; }

    curl -fsSL "$release/$web_asset" -o "$ARTIFACT_STAGE/web.tgz" \
        || { err "Could not download $web_asset."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/web.tgz" \
        "$(release_checksum "$ARTIFACT_STAGE/checksums.txt" "$web_asset")" || return 1
    archive_paths_safe tar "$ARTIFACT_STAGE/web.tgz" \
        || { err "Unsafe path in web archive."; return 1; }
    mkdir "$ARTIFACT_STAGE/web"
    tar --no-same-owner --no-same-permissions -xzf "$ARTIFACT_STAGE/web.tgz" -C "$ARTIFACT_STAGE/web"
    [[ -f "$ARTIFACT_STAGE/web/index.html" ]] \
        || { err "Staged web archive has no index.html."; return 1; }

    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz" \
        -o "$ARTIFACT_STAGE/mihomo.gz" || { err "Could not download mihomo ${MIHOMO_VERSION}."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/mihomo.gz" "$MIHOMO_SHA256" || return 1
    gzip -dc "$ARTIFACT_STAGE/mihomo.gz" > "$ARTIFACT_STAGE/mihomo"
    chmod 0755 "$ARTIFACT_STAGE/mihomo"
    "$ARTIFACT_STAGE/mihomo" -v >/dev/null 2>&1 \
        || { err "Staged mihomo binary did not execute."; return 1; }

    curl -fsSL "https://github.com/Zephyruso/zashboard/releases/download/${ZASH_VERSION}/dist.zip" \
        -o "$ARTIFACT_STAGE/zash.zip" || { err "Could not download zashboard ${ZASH_VERSION}."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/zash.zip" "$ZASH_SHA256" || return 1
    archive_paths_safe zip "$ARTIFACT_STAGE/zash.zip" \
        || { err "Unsafe path in zashboard archive."; return 1; }
    mkdir "$ARTIFACT_STAGE/zash"
    unzip -qo "$ARTIFACT_STAGE/zash.zip" -d "$ARTIFACT_STAGE/zash"
    if [[ -f "$ARTIFACT_STAGE/zash/dist/index.html" ]]; then
        mv "$ARTIFACT_STAGE/zash/dist"/* "$ARTIFACT_STAGE/zash/"
        rmdir "$ARTIFACT_STAGE/zash/dist"
    fi
    [[ -f "$ARTIFACT_STAGE/zash/index.html" ]] \
        || { err "Staged zashboard archive has no index.html."; return 1; }

    if [[ ! -f "$MIHOMO_DIR/config.yaml" || "$MIHOMO_RESET_APPROVED" == 1 ]]; then
        local seed="$ARTIFACT_STAGE/mihomo-seed.yaml" line listeners
        listeners="$(render_mihomo_listeners "$MIHOMO_LISTEN_IPS")"
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == '__MIHOMO_LISTENERS__' ]]; then
                printf '%s\n' "$listeners"
                continue
            fi
            line="${line//__GATEWAY_IP__/$GATEWAY_IP}"
            line="${line//__CONSOLE_DOMAIN__/$CONSOLE_DOMAIN}"
            line="${line//__ZASH_DOMAIN__/$ZASH_DOMAIN}"
            line="${line//__CONTROLLER_SECRET__/preflight-only-secret}"
            printf '%s\n' "$line"
        done < "${SCRIPT_DIR}/etc/mihomo/config.yaml.tmpl" > "$seed"
        install -d -m 0700 "$ARTIFACT_STAGE/mihomo-home"
        : > "$ARTIFACT_STAGE/mihomo-home/whitelist.txt"
        "$ARTIFACT_STAGE/mihomo" -t -f "$seed" -d "$ARTIFACT_STAGE/mihomo-home" \
            || { err "Staged mihomo seed candidate is invalid; live deployment was not touched."; return 1; }
    else
        "$ARTIFACT_STAGE/mihomo" -t -f "$MIHOMO_DIR/config.yaml" -d "$MIHOMO_DIR" \
            || { err "Existing operator-owned mihomo config is invalid; live deployment was not touched."; return 1; }
    fi
    ok "All release artifacts staged and verified."
}

cleanup_artifact_stage() {
    [[ -n "$ARTIFACT_STAGE" && -d "$ARTIFACT_STAGE" ]] || return 0
    remove_temp_dir "$ARTIFACT_STAGE" \
        || { warn "Refusing to remove unowned artifact staging directory: $ARTIFACT_STAGE"; return 1; }
    ARTIFACT_STAGE=""
}

file_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
file_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }

acquire_install_cert_lock() {
    [[ "$INSTALL_CERT_LOCK_HELD" == 0 ]] || return 0
    command -v flock >/dev/null 2>&1 \
        || { err "flock is required for certificate-operation exclusion."; return 1; }
    local lock_dir; lock_dir="$(dirname -- "$CERT_RENEW_LOCK_FILE")"
    if [[ ! -e "$lock_dir" ]]; then
        install -d -o root -g root -m 0700 "$lock_dir" \
            || { err "Could not create the certificate-renewal lock directory."; return 1; }
    fi
    [[ -d "$lock_dir" && ! -L "$lock_dir" \
       && "$(readlink -f -- "$lock_dir" 2>/dev/null || true)" == "$lock_dir" \
       && "$(file_uid "$lock_dir")" == 0 \
       && "$(file_mode "$lock_dir")" == 700 ]] \
        || { err "Unsafe certificate-renewal lock directory: ${lock_dir}"; return 1; }
    if [[ -e "$CERT_RENEW_LOCK_FILE" ]]; then
        [[ -f "$CERT_RENEW_LOCK_FILE" && ! -L "$CERT_RENEW_LOCK_FILE" \
           && "$(file_uid "$CERT_RENEW_LOCK_FILE")" == 0 ]] \
            || { err "Unsafe certificate-renewal lock file: ${CERT_RENEW_LOCK_FILE}"; return 1; }
    fi
    exec 8>"$CERT_RENEW_LOCK_FILE"
    chmod 0600 "$CERT_RENEW_LOCK_FILE" \
        || { exec 8>&-; err "Could not protect the certificate-renewal lock file."; return 1; }
    info "Waiting for any active 5gpn certificate renewal to finish..."
    flock -w 900 8 \
        || { exec 8>&-; err "Timed out waiting for the 5gpn certificate-renewal lock."; return 1; }
    INSTALL_CERT_LOCK_HELD=1
}

release_install_cert_lock() {
    [[ "$INSTALL_CERT_LOCK_HELD" == 1 ]] || return 0
    flock -u 8 2>/dev/null || true
    exec 8>&-
    INSTALL_CERT_LOCK_HELD=0
}

capture_install_rollback() {
    ROLLBACK_DIR="$ARTIFACT_STAGE/rollback"
    install -d -m 0700 "$ROLLBACK_DIR"
    cp -a -- "$BASE_DIR" "$ROLLBACK_DIR/base"
    cp -a -- "$CONF_DIR" "$ROLLBACK_DIR/conf"
    local unit
    install -d -m 0700 "$ROLLBACK_DIR/units"
    for unit in 5gpn-dns.service mihomo.service 5gpn-certbot-renew.service 5gpn-certbot-renew.timer; do
        if [[ -f "/etc/systemd/system/$unit" && ! -L "/etc/systemd/system/$unit" ]]; then
            cp -p -- "/etc/systemd/system/$unit" "$ROLLBACK_DIR/units/$unit"
        else
            : > "$ROLLBACK_DIR/units/$unit.absent"
        fi
    done
    if systemctl is-enabled --quiet 5gpn-certbot-renew.timer 2>/dev/null; then
        : > "$ROLLBACK_DIR/units/5gpn-certbot-renew.timer.enabled"
    else
        : > "$ROLLBACK_DIR/units/5gpn-certbot-renew.timer.disabled"
    fi
    if systemctl is-active --quiet 5gpn-certbot-renew.timer 2>/dev/null; then
        : > "$ROLLBACK_DIR/units/5gpn-certbot-renew.timer.active"
    else
        : > "$ROLLBACK_DIR/units/5gpn-certbot-renew.timer.inactive"
    fi
    if [[ -f /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh ]]; then
        cp -p -- /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh "$ROLLBACK_DIR/renew-hook"
    else
        : > "$ROLLBACK_DIR/renew-hook.absent"
    fi
    # A certificate-method switch rewrites this scoped Certbot renewal file.
    # Snapshot both the currently persisted base and the newly selected base so
    # a later publication failure cannot leave dns.env and the authenticator in
    # different modes. No other host lineage is read or touched.
    install -d -m 0700 "$ROLLBACK_DIR/renewal-conf"
    local old_base selected_base b seen="" conf_present live_present archive_present present_count
    old_base="$(cfg_get DNS_BASE_DOMAIN)"
    selected_base="${BASE_DOMAIN:-}"
    : > "$ROLLBACK_DIR/renewal-names"
    for b in "$old_base" "$selected_base"; do
        b="$(printf '%s' "${b%.}" | tr '[:upper:]' '[:lower:]')"
        is_valid_domain "$b" || continue
        case " $seen " in *" $b "*) continue ;; esac
        seen+=" $b"
        printf '%s\n' "$b" >> "$ROLLBACK_DIR/renewal-names"
        conf_present=0; live_present=0; archive_present=0
        [[ -e "/etc/letsencrypt/renewal/${b}.conf" || -L "/etc/letsencrypt/renewal/${b}.conf" ]] && conf_present=1
        [[ -e "/etc/letsencrypt/live/${b}" || -L "/etc/letsencrypt/live/${b}" ]] && live_present=1
        [[ -e "/etc/letsencrypt/archive/${b}" || -L "/etc/letsencrypt/archive/${b}" ]] && archive_present=1
        present_count=$((conf_present + live_present + archive_present))
        [[ "$present_count" == 0 || "$present_count" == 3 ]] \
            || { err "Certbot lineage ${b} is partial (renewal/live/archive must be all present or all absent); refusing replacement."; return 1; }
        if [[ -f "/etc/letsencrypt/renewal/${b}.conf" && ! -L "/etc/letsencrypt/renewal/${b}.conf" ]]; then
            certbot_renewal_conf_scoped "/etc/letsencrypt/renewal/${b}.conf" "$b" \
                || { err "Certbot renewal config for ${b} escapes its exact live/archive paths; refusing replacement."; return 1; }
            cp -p -- "/etc/letsencrypt/renewal/${b}.conf" "$ROLLBACK_DIR/renewal-conf/${b}.conf"
        elif [[ -e "/etc/letsencrypt/renewal/${b}.conf" || -L "/etc/letsencrypt/renewal/${b}.conf" ]]; then
            err "Refusing unsafe Certbot renewal config path: /etc/letsencrypt/renewal/${b}.conf"
            return 1
        else
            : > "$ROLLBACK_DIR/renewal-conf/${b}.absent"
        fi
        if [[ "$live_present" == 1 ]]; then
            : > "$ROLLBACK_DIR/renewal-conf/${b}.lineage-present"
            [[ -d "/etc/letsencrypt/live/${b}" && ! -L "/etc/letsencrypt/live/${b}" \
               && -d "/etc/letsencrypt/archive/${b}" && ! -L "/etc/letsencrypt/archive/${b}" \
               && -s "/etc/letsencrypt/live/${b}/fullchain.pem" \
               && -s "/etc/letsencrypt/live/${b}/privkey.pem" ]] \
                || { err "Existing Certbot lineage ${b} has an unsafe or incomplete layout; refusing transactional replacement."; return 1; }
            install -d -m 0700 "$ROLLBACK_DIR/le-live" "$ROLLBACK_DIR/le-archive" "$ROLLBACK_DIR/lineage-leaf/${b}"
            cp -a -- "/etc/letsencrypt/live/${b}" "$ROLLBACK_DIR/le-live/${b}"
            cp -a -- "/etc/letsencrypt/archive/${b}" "$ROLLBACK_DIR/le-archive/${b}"
            cp -L -- "/etc/letsencrypt/live/${b}/fullchain.pem" "$ROLLBACK_DIR/lineage-leaf/${b}/fullchain.pem"
            cp -L -- "/etc/letsencrypt/live/${b}/privkey.pem" "$ROLLBACK_DIR/lineage-leaf/${b}/privkey.pem"
        else
            : > "$ROLLBACK_DIR/renewal-conf/${b}.lineage-absent"
        fi
    done
    if unit_file_owned_by_5gpn xray.service; then
        install -d -m 0700 "$ROLLBACK_DIR/legacy-xray"
        cp -p -- /etc/systemd/system/xray.service "$ROLLBACK_DIR/legacy-xray/xray.service"
        [[ -f /usr/local/bin/xray ]] && cp -p -- /usr/local/bin/xray "$ROLLBACK_DIR/legacy-xray/xray"
        [[ -d /usr/local/etc/xray ]] && cp -a -- /usr/local/etc/xray "$ROLLBACK_DIR/legacy-xray/config"
    fi
    if [[ "$DNS_WEB_DIR" != "$BASE_DIR"/* && -d "$DNS_WEB_DIR" ]] \
       && verify_ownership_marker "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"; then
        cp -a -- "$DNS_WEB_DIR" "$ROLLBACK_DIR/external-web"
    fi
    if [[ "$DNS_ZASH_DIR" != "$BASE_DIR"/* && -d "$DNS_ZASH_DIR" ]] \
       && verify_ownership_marker "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1'; then
        cp -a -- "$DNS_ZASH_DIR" "$ROLLBACK_DIR/external-zash"
    fi
    INSTALL_TRANSACTION_ACTIVE=1
}

rollback_install() {
    [[ "$INSTALL_TRANSACTION_ACTIVE" == 1 && -d "$ROLLBACK_DIR" ]] || return 0
    local rollback_cert_failed=0
    INSTALL_TRANSACTION_ACTIVE=0
    warn "Install publication failed; restoring the previous 5gpn deployment."
    if [[ "$SWAP_CREATED_THIS_RUN" == 1 ]]; then
        swapoff "$SWAP_FILE" 2>/dev/null || true
        rm -f -- "$SWAP_FILE"
        sed -i "\|^${SWAP_FILE} none swap sw 0 0 ${SWAP_FSTAB_MARKER}$|d" /etc/fstab 2>/dev/null || true
        SWAP_CREATED_THIS_RUN=0
    fi
    systemctl stop 5gpn-dns.service mihomo.service 2>/dev/null || true
    if verify_ownership_marker "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"; then
        rm -rf -- "$BASE_DIR"
    fi
    cp -a -- "$ROLLBACK_DIR/base" "$BASE_DIR"
    if verify_ownership_marker "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"; then
        rm -rf -- "$CONF_DIR"
    fi
    cp -a -- "$ROLLBACK_DIR/conf" "$CONF_DIR"
    local unit
    for unit in 5gpn-dns.service mihomo.service 5gpn-certbot-renew.service 5gpn-certbot-renew.timer; do
        if [[ -f "$ROLLBACK_DIR/units/$unit" ]]; then
            cp -p -- "$ROLLBACK_DIR/units/$unit" "/etc/systemd/system/$unit"
        elif [[ -f "$ROLLBACK_DIR/units/$unit.absent" ]] \
             && unit_file_owned_by_5gpn "$unit"; then
            rm -f -- "/etc/systemd/system/$unit"
        fi
    done
    if [[ -f "$ROLLBACK_DIR/renew-hook" ]]; then
        install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
        cp -p -- "$ROLLBACK_DIR/renew-hook" /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh
    elif [[ -f "$ROLLBACK_DIR/renew-hook.absent" ]]; then
        rm -f -- /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh
    fi
    if [[ -f "$ROLLBACK_DIR/renewal-names" ]]; then
        local renewal_base lineage_changed restore_ok
        while IFS= read -r renewal_base; do
            is_valid_domain "$renewal_base" || continue
            if [[ -f "$ROLLBACK_DIR/renewal-conf/${renewal_base}.lineage-present" ]]; then
                lineage_changed=0
                cmp -s "$ROLLBACK_DIR/lineage-leaf/${renewal_base}/fullchain.pem" \
                    "/etc/letsencrypt/live/${renewal_base}/fullchain.pem" 2>/dev/null \
                    || lineage_changed=1
                cmp -s "$ROLLBACK_DIR/lineage-leaf/${renewal_base}/privkey.pem" \
                    "/etc/letsencrypt/live/${renewal_base}/privkey.pem" 2>/dev/null \
                    || lineage_changed=1
                if [[ -f "$ROLLBACK_DIR/renewal-conf/${renewal_base}.conf" ]]; then
                    cmp -s "$ROLLBACK_DIR/renewal-conf/${renewal_base}.conf" \
                        "/etc/letsencrypt/renewal/${renewal_base}.conf" 2>/dev/null \
                        || lineage_changed=1
                elif [[ -e "/etc/letsencrypt/renewal/${renewal_base}.conf" ]]; then
                    lineage_changed=1
                fi
                if [[ "$lineage_changed" == 1 ]]; then
                    if certbot delete --non-interactive --cert-name "$renewal_base" >/dev/null 2>&1; then
                        restore_ok=1
                        [[ ! -e "/etc/letsencrypt/live/${renewal_base}" \
                           && ! -e "/etc/letsencrypt/archive/${renewal_base}" \
                           && ! -e "/etc/letsencrypt/renewal/${renewal_base}.conf" ]] \
                            || restore_ok=0
                        install -d -m 0755 /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal \
                            || restore_ok=0
                        [[ "$restore_ok" == 1 ]] \
                            && cp -a -- "$ROLLBACK_DIR/le-live/${renewal_base}" "/etc/letsencrypt/live/${renewal_base}" \
                            || restore_ok=0
                        [[ "$restore_ok" == 1 ]] \
                            && cp -a -- "$ROLLBACK_DIR/le-archive/${renewal_base}" "/etc/letsencrypt/archive/${renewal_base}" \
                            || restore_ok=0
                        if [[ "$restore_ok" == 1 && -f "$ROLLBACK_DIR/renewal-conf/${renewal_base}.conf" ]]; then
                            cp -p -- "$ROLLBACK_DIR/renewal-conf/${renewal_base}.conf" \
                                "/etc/letsencrypt/renewal/${renewal_base}.conf" \
                                || restore_ok=0
                        fi
                        if [[ "$restore_ok" == 1 ]]; then
                            cmp -s "$ROLLBACK_DIR/lineage-leaf/${renewal_base}/fullchain.pem" \
                                "/etc/letsencrypt/live/${renewal_base}/fullchain.pem" 2>/dev/null \
                                || restore_ok=0
                            cmp -s "$ROLLBACK_DIR/lineage-leaf/${renewal_base}/privkey.pem" \
                                "/etc/letsencrypt/live/${renewal_base}/privkey.pem" 2>/dev/null \
                                || restore_ok=0
                        fi
                        if [[ "$restore_ok" != 1 ]]; then
                            rollback_cert_failed=1
                            systemctl disable --now 5gpn-certbot-renew.timer 2>/dev/null || true
                            warn "Certbot lineage ${renewal_base} could not be fully restored; automatic renewal was disabled."
                        fi
                    else
                        rollback_cert_failed=1
                        systemctl disable --now 5gpn-certbot-renew.timer 2>/dev/null || true
                        warn "Could not restore Certbot lineage ${renewal_base}; automatic renewal was disabled to avoid a mode mismatch."
                    fi
                fi
            elif [[ -f "$ROLLBACK_DIR/renewal-conf/${renewal_base}.lineage-absent" ]] \
               && [[ -e "/etc/letsencrypt/live/${renewal_base}" || -e "/etc/letsencrypt/renewal/${renewal_base}.conf" ]]; then
                certbot delete --non-interactive --cert-name "$renewal_base" >/dev/null 2>&1 \
                    || warn "Could not remove newly created rollback lineage ${renewal_base}; it is not referenced by restored dns.env."
            fi
        done < "$ROLLBACK_DIR/renewal-names"
    fi
    if [[ -d "$ROLLBACK_DIR/legacy-xray" ]]; then
        cp -p -- "$ROLLBACK_DIR/legacy-xray/xray.service" /etc/systemd/system/xray.service
        [[ -f "$ROLLBACK_DIR/legacy-xray/xray" ]] \
            && cp -p -- "$ROLLBACK_DIR/legacy-xray/xray" /usr/local/bin/xray
        if [[ -d "$ROLLBACK_DIR/legacy-xray/config" ]]; then
            install -d -m 0755 /usr/local/etc
            cp -a -- "$ROLLBACK_DIR/legacy-xray/config" /usr/local/etc/xray
        fi
    fi
    if [[ -d "$ROLLBACK_DIR/external-web" ]]; then
        if verify_ownership_marker "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"; then
            rm -rf -- "$DNS_WEB_DIR"
        fi
        cp -a -- "$ROLLBACK_DIR/external-web" "$DNS_WEB_DIR"
    fi
    if [[ -d "$ROLLBACK_DIR/external-zash" ]]; then
        if verify_ownership_marker "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1'; then
            rm -rf -- "$DNS_ZASH_DIR"
        fi
        cp -a -- "$ROLLBACK_DIR/external-zash" "$DNS_ZASH_DIR"
    fi
    systemctl daemon-reload 2>/dev/null || true
    if [[ "$rollback_cert_failed" == 0 ]]; then
        if [[ -f "$ROLLBACK_DIR/units/5gpn-certbot-renew.timer.enabled" ]]; then
            systemctl enable 5gpn-certbot-renew.timer 2>/dev/null || true
        else
            systemctl disable 5gpn-certbot-renew.timer 2>/dev/null || true
        fi
        if [[ -f "$ROLLBACK_DIR/units/5gpn-certbot-renew.timer.active" ]]; then
            systemctl start 5gpn-certbot-renew.timer 2>/dev/null || true
        else
            systemctl stop 5gpn-certbot-renew.timer 2>/dev/null || true
        fi
    else
        systemctl disable --now 5gpn-certbot-renew.timer 2>/dev/null || true
    fi
    systemctl restart mihomo.service 2>/dev/null || true
    systemctl restart 5gpn-dns.service 2>/dev/null || true
    [[ -d "$ROLLBACK_DIR/legacy-xray" ]] && systemctl enable --now xray.service 2>/dev/null || true
    release_install_cert_lock
    if [[ "$rollback_cert_failed" == 0 ]]; then
        warn "Previous deployment restored; inspect the reported error before retrying."
    else
        err "Previous service files were restored, but certificate-lineage rollback was incomplete; automatic renewal is disabled pending repair."
        return 1
    fi
}

install_transaction_exit() {
    local rc=$?
    trap - ERR EXIT
    if [[ "$rc" != 0 && "$INSTALL_TRANSACTION_ACTIVE" == 1 ]]; then
        rollback_install || true
    fi
    cleanup_artifact_stage || true
    exit "$rc"
}

install_transaction_error() {
    local rc=$?
    trap - ERR
    rollback_install || true
    cleanup_artifact_stage || true
    exit "$rc"
}

publish_executable() {
    local src="$1" dest="$2" candidate
    install -d -m 0755 "$(dirname -- "$dest")" || return 1
    candidate="$(mktemp "$(dirname -- "$dest")/.$(basename -- "$dest").XXXXXX")" || return 1
    install -m 0755 "$src" "$candidate" || { rm -f -- "$candidate"; return 1; }
    sync -f "$candidate" 2>/dev/null || true
    mv -f -- "$candidate" "$dest"
}

# 5gpn-dns: prebuilt binary from moooyo/5gpn releases.
# Mirrors the install_mihomo download/sha256/install pattern.
#
# Fresh-artifact rule (2026-07-10): ALWAYS downloads the pinned DNS_VERSION and
# installs it over $DNS_BIN — an existing binary is never kept, so a re-run can
# no longer leave an old daemon next to newer configs (the v0.1.0-binary +
# newer-xray-config skew that broke the :443 webui). install(1) unlinks the
# destination first, so replacing the running daemon's binary is safe (the
# process keeps its inode until start_services restarts it). Download failure
# aborts the install and leaves the previously installed binary untouched.
# Dev builds must be scp'd in AFTER the install run (then restarted) — a
# pre-placed binary is deliberately clobbered.
install_5gpndns() {
    [[ -n "$ARTIFACT_STAGE" && -x "$ARTIFACT_STAGE/5gpn-dns" ]] \
        || { err "5gpn-dns was not staged."; return 1; }
    publish_executable "$ARTIFACT_STAGE/5gpn-dns" "$DNS_BIN"
    [[ -x "$DNS_BIN" ]] || { err "5gpn-dns install failed."; exit 1; }
    ok "Verified 5gpn-dns ${DNS_VERSION_DEFAULT} published to $DNS_BIN."
}

# 5gpn-web: control-console SPA tarball from the same moooyo/5gpn release.
# Served from disk by the :18443 control server (DNS_WEB_DIR); no go:embed.
#
# Fresh-artifact rule (2026-07-10, mirrors install_5gpndns): ALWAYS downloads
# the pinned DNS_VERSION's SPA and replaces DNS_WEB_DIR — daemon and SPA move
# together on every run, never skew. The dir was already wiped by
# clean_previous_install, so a failed download leaves the built-in placeholder
# (warn-not-fatal: a missing console must not abort the resolver install).
install_web() {
    [[ -n "$ARTIFACT_STAGE" && -f "$ARTIFACT_STAGE/web/index.html" ]] \
        || { err "Control-console SPA was not staged."; return 1; }
    claim_web_dir || return 1
    printf '%s\n' "$DNS_VERSION_DEFAULT" > "$ARTIFACT_STAGE/web/.web_version"
    publish_owned_tree "$ARTIFACT_STAGE/web" "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE" \
        || { err "Could not atomically publish control-console SPA."; return 1; }
    ok "Verified control-console SPA published to ${DNS_WEB_DIR}/ (${DNS_VERSION_DEFAULT})."
}

# zashboard: prebuilt static dist from Zephyruso/zashboard. Pinned by
# ZASH_VERSION; opt-in sha256 via ZASH_SHA256. Fresh-artifact: wipes+replaces
# DNS_ZASH_DIR on every run (never build on the box). Warn-not-fatal — a missing
# zash panel must not abort the resolver install (the console + DoT still work).
#
# This ONLY acquires+unzips the dist -- it does not seed a backend. zashboard
# reads its mihomo-controller target from URL params on first load
# (#/setup?hostname=...&port=...&secret=...&secondaryPath=<path>), persisted to
# localStorage; SP-3's C3 console adds a deep-link with those params (secondary
# path pointed at the mihomo reverse-proxy route), so no index.html/config patch
# happens here. Real zashboard -> reverse-proxy -> mihomo controller wiring is a
# test-env cutover gate, not installer scope.
install_zashboard() {
    [[ -n "$ARTIFACT_STAGE" && -f "$ARTIFACT_STAGE/zash/index.html" ]] \
        || { err "zashboard was not staged."; return 1; }
    claim_zashboard_dir || return 1
    printf '%s\n' "$ZASH_VERSION" > "$ARTIFACT_STAGE/zash/.zash_version"
    publish_owned_tree "$ARTIFACT_STAGE/zash" "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1' \
        || { err "Could not atomically publish zashboard."; return 1; }
    ok "Verified zashboard published to ${DNS_ZASH_DIR}/ (${ZASH_VERSION})."
}

# mihomo: prebuilt binary from MetaCubeX/mihomo releases (amd64-compatible).
# Pinned by MIHOMO_VERSION (env or default); opt-in sha256 verify via MIHOMO_SHA256.
#
# Fresh-artifact rule (2026-07-10): ALWAYS downloads the pinned MIHOMO_VERSION
# and installs it over $MIHOMO_BIN (install(1) unlinks first — safe while the old
# process is running; start_services restarts into it). No keep-if-present path.
install_mihomo() {
    [[ -n "$ARTIFACT_STAGE" && -x "$ARTIFACT_STAGE/mihomo" ]] \
        || { err "mihomo was not staged."; return 1; }
    publish_executable "$ARTIFACT_STAGE/mihomo" "$MIHOMO_BIN"
    [[ -x "$MIHOMO_BIN" ]] || { err "mihomo install failed."; return 1; }
    ok "Verified mihomo ${MIHOMO_VERSION} published to $MIHOMO_BIN."
}

# ----------------------------------------------------------------------------
# Phase 2: subscriptions.json (remote rule-list auto-update, in-process in 5gpn-dns)
# ----------------------------------------------------------------------------
# Writes the default subscriptions.json — only if absent, so operator edits
# (added/disabled/re-pointed subscriptions) are never clobbered on re-install.
# Ships ONE default subscription: chnroute (the system arbitration input, NOT
# policy-owned). The former direct/proxy subscriptions (china-list, gfw)
# moved to policy.json (UP-2) — they're now seeded as policy
# subscription rules by seed_policy_defaults, so listing them here too would
# just have the compiler's Sync step remove them as no-longer-policy-owned.
#   chnroute  china-ip    17mon/china_ip_list  (cidr)  split-horizon arbitration input
# The old update-lists.sh direct china_ip_list download is now the china-ip sub.
# Best-effort + offline-safe: a failed/too-small fetch keeps the prior cache,
# and the operator can disable it via the Web/Bot console.
write_subscriptions_json() {
    local f="${CONF_DIR}/subscriptions.json"
    if [[ -f "$f" ]]; then
        info "Keeping existing ${f}."
        return 0
    fi
    cat > "$f" <<'EOF'
{
  "subscriptions": [
    {
      "id": "china-ip",
      "category": "chnroute",
      "name": "china_ip_list",
      "url": "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt",
      "format": "cidr",
      "enabled": true,
      "interval": "24h"
    }
  ]
}
EOF
    chmod 644 "$f"
    ok "Written ${f} (1 default subscription: chnroute — block/direct/blacklist now live in policy.json)."
}

# ----------------------------------------------------------------------------
# UP-4: seed the unified policy-rule model (policy.json). Runs the installed
# 5gpn-dns binary's --seed-defaults subcommand (which owns the JSON shape,
# reusing the daemon's own types). This MUST run before start_services: the
# daemon's first boot compile rewrites the block/direct/blacklist manual
# files from policy.json, so any default not in policy.json is wiped.
# Idempotent — the subcommand skips a present policy.json (operator source of
# truth). Each default list URL is env-overridable.
#
# Binary policy (2026-07-15 policy/mihomo decoupling): a proxy-intent rule
# carries no selector/target, so this seed does NOT create egress.json or
# egress-nodes.enc anymore (there is no structured egress model to seed) --
# the operator's egress routing lives entirely in the mihomo config seeded by
# render_mihomo_config (see etc/mihomo/config.yaml.tmpl's default Proxies
# select group).
seed_policy_defaults() {
    local policy="${CONF_DIR}/policy.json"

    # Fixed, reviewable default list URLs.
    local china_list_url="https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf"
    local gfw_url="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"

    if [[ -f "$policy" ]]; then
        info "Keeping existing ${policy} (operator policy model preserved)."
    fi

    if "$DNS_BIN" --seed-defaults \
        --policy-out "$policy" \
        --bypass "${SCRIPT_DIR}/etc/block-dns-bypass.txt" \
        --keyword "${SCRIPT_DIR}/etc/block-dns-bypass.keyword.txt" \
        --proxy-domains "${SCRIPT_DIR}/etc/proxy-domains.txt" \
        --china-list-url "$china_list_url" \
        --gfw-url "$gfw_url"; then
        chmod 644 "$policy" 2>/dev/null || true
        ok "Seeded ${policy} (default policy ruleset)."
    else
        warn "policy-defaults seed failed; the daemon will boot with an empty policy (no default rules until you add them via the web console)."
    fi
}

# ----------------------------------------------------------------------------
# Install config + scripts + control-plane sources
# ----------------------------------------------------------------------------
# validate_egress_resolver <resolver> -- validate the format of the Egress DNS
# Broker's fallback resolver (DNS_EGRESS_RESOLVER, back-compat XRAY_RESOLVER;
# 22.22.22.22 sentinel by default). The runtime data path is the fixed loopback
# broker (udp://127.0.0.1:5354, wired into mihomo's dns.nameserver in the
# committed template), so there is no per-install file substitution to do here.
# The resolver is NOT inert: the 5gpn-dns daemon consumes it directly to build
# the broker's fallback exchanger. This stays a validating check; a bad value is
# an error so change-resolver refuses it. (Renamed from the old xray-era patcher
# of the same job; xray is gone but the broker is not.)
validate_egress_resolver() {
    local xr="${1:-}"
    if [[ "$xr" =~ ^https://[A-Za-z0-9./_:-]+$ ]] || is_valid_ipv4 "$xr"; then
        info "Sniffed-origin resolution uses the loopback DNS broker (127.0.0.1:5354); DNS_EGRESS_RESOLVER='${xr}' is the broker fallback upstream (consumed by 5gpn-dns)."
    else
        warn "DNS_EGRESS_RESOLVER='${xr}' is neither an IPv4 nor an https:// DoH URL; the broker fallback cannot use it -- fix it."
        return 1
    fi
}

# render_mihomo_config renders /etc/5gpn/mihomo/config.yaml from the committed
# template (etc/mihomo/config.yaml.tmpl), substituting the box-specific
# sentinels, seeds the zashboard whitelist.txt on first run, then validates the
# rendered file with `mihomo -t` (fatal on failure — a bad config must never
# be left live). This is the SINGLE writer for the mihomo data-plane config;
# re-run it whenever a consumed value (PUBLIC_IP/GATEWAY_IP/WEB_DOMAIN)
# changes. Replaces the old xray-config copy + the three per-field xray-config
# patcher functions this migration retired (gateway/resolver/webdomain).
seed_mihomo_whitelist() {
    # whitelist.txt is TUI-managed after install and never clobbered.
    if [[ ! -f "$MIHOMO_DIR/whitelist.txt" ]]; then
        install -m 0644 "${SCRIPT_DIR}/etc/mihomo/whitelist.seed.txt" "$MIHOMO_DIR/whitelist.txt"
        local admin_cidr=""
        if [[ -n "${SSH_CONNECTION:-}" ]]; then
            local admin_ip
            admin_ip="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
            if [[ "$admin_ip" == *:* ]]; then
                admin_cidr="${admin_ip}/128"
            else
                admin_cidr="${admin_ip}/32"
            fi
        fi
        if [[ -n "$admin_cidr" ]]; then
            echo "$admin_cidr" >> "$MIHOMO_DIR/whitelist.txt"
            ok "Seeded zashboard whitelist with admin CIDR ${admin_cidr} (refine via the 5gpn menu)."
        else
            warn "No admin CIDR detected; zashboard is unreachable until you add one to ${MIHOMO_DIR}/whitelist.txt via the 5gpn menu."
        fi
    fi
}

mihomo_config_secret() {
    local f="$1" secret=""
    [[ -f "$f" ]] && secret="$(sed -n 's/^[[:space:]]*secret:[[:space:]]*//p' "$f" | head -1)"
    secret="${secret%$'\r'}"
    if [[ "$secret" == \"*\" && "$secret" == *\" ]]; then secret="${secret:1:${#secret}-2}"; fi
    if [[ "$secret" == \'*\' && "$secret" == *\' ]]; then secret="${secret:1:${#secret}-2}"; fi
    printf '%s' "$secret"
}

persist_mihomo_secret() {
    local secret="$1"
    [[ -n "$secret" ]] || { warn "mihomo config has no readable controller secret; DNS_MIHOMO_SECRET was not changed."; return 0; }
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_MIHOMO_SECRET "$secret" \
        || warn "could not persist DNS_MIHOMO_SECRET to dns.env; the daemon reverse-proxy may not match the mihomo controller secret."
}

# Seed mihomo's fully operator-owned config only when it is missing. A normal
# install or change-* operation validates and preserves an existing file
# byte-for-byte. `render_mihomo_config --reset` is the sole overwrite path: it
# renders to a same-directory candidate, validates that candidate, backs up the
# old file, fsyncs, and atomically renames it into place.
render_mihomo_config() {
    local mode="${1:-seed}" config="${MIHOMO_DIR}/config.yaml" secret=""
    install -d -m 0700 "$MIHOMO_DIR"
    seed_mihomo_whitelist

    if [[ -f "$config" && "$mode" != "--reset" ]]; then
        if ! "$MIHOMO_BIN" -t -f "$config" -d "$MIHOMO_DIR"; then
            err "Existing operator-owned mihomo config is invalid; it was NOT overwritten: $config"
            return 1
        fi
        chmod 0600 "$config" 2>/dev/null || true
        secret="$(mihomo_config_secret "$config")"
        persist_mihomo_secret "$secret"
        ok "Existing operator-owned mihomo config validated and preserved: $config"
        return 0
    fi

    # Controller secret survives an explicit reset. On first install, prefer a
    # persisted value and otherwise generate a strong mixed secret.
    [[ -f "$config" ]] && secret="$(mihomo_config_secret "$config")"
    [[ -n "$secret" ]] || secret="$(cfg_get DNS_MIHOMO_SECRET)"
    [[ -n "$secret" ]] || secret="$(openssl rand -base64 24)"

    # Resolve deployment-specific seed values only for first install/reset.
    local base="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    if [[ -z "$base" ]]; then
        local legacy_web="${WEB_DOMAIN:-$(cfg_get DNS_WEB_DOMAIN)}"
        base="${legacy_web#console.}"
    fi
    derive_domains "$base"
    local gw="${GATEWAY_IP:-$PUBLIC_IP}"
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    export MIHOMO_LISTEN_IPS
    local listeners candidate line backup
    listeners="$(render_mihomo_listeners "$MIHOMO_LISTEN_IPS")"
    candidate="$(mktemp "${MIHOMO_DIR}/.config.yaml.XXXXXX")" \
        || { err "Could not create a mihomo config candidate in $MIHOMO_DIR"; return 1; }
    chmod 0600 "$candidate"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '__MIHOMO_LISTENERS__' ]]; then
            printf '%s\n' "$listeners"
            continue
        fi
        line="${line//__GATEWAY_IP__/$gw}"
        line="${line//__CONSOLE_DOMAIN__/$CONSOLE_DOMAIN}"
        line="${line//__ZASH_DOMAIN__/$ZASH_DOMAIN}"
        line="${line//__CONTROLLER_SECRET__/$secret}"
        printf '%s\n' "$line"
    done < "${SCRIPT_DIR}/etc/mihomo/config.yaml.tmpl" > "$candidate"

    if ! "$MIHOMO_BIN" -t -f "$candidate" -d "$MIHOMO_DIR"; then
        rm -f -- "$candidate"
        err "mihomo candidate validation failed; live config was not changed."
        return 1
    fi
    sync -f "$candidate" 2>/dev/null || true
    if [[ -f "$config" ]]; then
        backup="${config}.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
        cp -p -- "$config" "$backup"
        chmod 0600 "$backup" 2>/dev/null || true
        sync -f "$backup" 2>/dev/null || true
        info "Backed up operator mihomo config to $backup"
    fi
    mv -f -- "$candidate" "$config"
    sync -f "$MIHOMO_DIR" 2>/dev/null || true
    persist_mihomo_secret "$secret"

    ok "mihomo config ${mode/--/} candidate validated and atomically installed at $config."
}

# apply_gateway_to_mihomo / apply_domain_to_mihomo: change-* call sites used
# to patch one field of the xray config in place; mihomo's config.yaml is
# cheap to fully re-render instead (single render, no per-field sed).
apply_gateway_to_mihomo() {
    render_mihomo_config
    warn "mihomo config is operator-owned and was not patched for the address change; review its listeners/anti-loop rules or run '5gpn mihomo-reset'."
}

apply_domain_to_mihomo() {
    render_mihomo_config
    warn "mihomo config is operator-owned and was not patched for the domain change; update its panel host/rule entries or run '5gpn mihomo-reset'."
}

reset_mihomo_config() {
    check_root
    install_gum
    _load_change_ctx
    warn "Explicit reset requested: the current operator mihomo config will be backed up and replaced with the validated seed."
    render_mihomo_config --reset
    restart_services
    ok "mihomo seed restored; backup retained beside ${MIHOMO_DIR}/config.yaml."
}

# ----------------------------------------------------------------------------
# Zashboard source-IP allowlist (whitelist.txt) — TUI-managed OUT-OF-BAND, never
# web-editable. add/del edit the file directly, then apply_whitelist pushes it
# live via the mihomo controller's rule-provider reload — NOT a full config
# reload/restart, so an in-flight zashboard session is undisturbed.
# ----------------------------------------------------------------------------

# mihomo_controller_curl dials the loopback mihomo controller over verified TLS
# using the zash certificate and SNI, while still letting callers supply their
# own curl flags and path.
mihomo_controller_curl() {
    local path="$1"; shift
    local controller server_name cert_file host port
    controller="${DNS_MIHOMO_CONTROLLER:-$(cfg_get DNS_MIHOMO_CONTROLLER)}"
    controller="${controller:-127.0.0.1:9090}"
    controller="${controller#http://}"
    controller="${controller#https://}"
    host="${controller%:*}"
    port="${controller##*:}"
    [[ "$host" != "$controller" && "$port" =~ ^[0-9]+$ ]] \
        || { warn "invalid mihomo controller address: $controller"; return 1; }
    server_name="${ZASH_DOMAIN:-${DNS_ZASH_DOMAIN:-$(cfg_get DNS_ZASH_DOMAIN)}}"
    cert_file="${DNS_ZASH_CERT:-$(cfg_get DNS_ZASH_CERT)}"
    cert_file="${cert_file:-${ZASH_CERT_DIR}/fullchain.pem}"
    [[ -n "$server_name" ]] \
        || { warn "DNS_ZASH_DOMAIN is required for mihomo controller TLS"; return 1; }
    [[ -r "$cert_file" ]] \
        || { warn "mihomo controller trust certificate is unreadable: $cert_file"; return 1; }
    curl --cacert "$cert_file" \
        --connect-to "${server_name}:${port}:${host}:${port}" \
        "$@" "https://${server_name}:${port}${path}"
}

# apply_whitelist pushes the on-disk whitelist.txt live via the mihomo
# controller's rule-provider reload endpoint (no full config reload/restart).
apply_whitelist() {
    local secret
    secret="${DNS_MIHOMO_SECRET:-$(cfg_get DNS_MIHOMO_SECRET)}"
    [[ -n "$secret" ]] || secret="$(mihomo_config_secret "$MIHOMO_DIR/config.yaml")"
    mihomo_controller_curl "/providers/rules/whitelist" \
        -fsS -X PUT -H "Authorization: Bearer $secret" -o /dev/null \
        && ok "whitelist applied" || warn "whitelist refresh failed (is mihomo running?)"
}

# add_allow_ip appends a source IP/CIDR to the zashboard allowlist and refreshes
# it live. Accepts an optional positional arg (CLI/menu dispatch); prompts
# interactively via ask_text when omitted and stdin is a TTY.
add_allow_ip() {
    check_root
    install_gum
    local ip="${1:-}"
    if [[ -z "$ip" && -t 0 ]]; then
        ip="$(ask_text 'Allow source IP/CIDR (e.g. 203.0.113.10/32)' || true)"
    fi
    [ -z "$ip" ] && return 0
    install -d -m 0755 "$MIHOMO_DIR"; touch "$MIHOMO_DIR/whitelist.txt"
    grep -qxF "$ip" "$MIHOMO_DIR/whitelist.txt" || printf '%s\n' "$ip" >> "$MIHOMO_DIR/whitelist.txt"
    apply_whitelist
}

# del_allow_ip removes a source IP/CIDR from the zashboard allowlist and
# refreshes it live. Same optional-arg/prompt convention as add_allow_ip.
del_allow_ip() {
    check_root
    install_gum
    local ip="${1:-}"
    if [[ -z "$ip" && -t 0 ]]; then
        ip="$(ask_text 'Remove source IP/CIDR' || true)"
    fi
    [ -z "$ip" ] && return 0
    [[ -f "$MIHOMO_DIR/whitelist.txt" ]] || { warn "No whitelist.txt yet."; return 0; }
    sed -i "\#^${ip}\$#d" "$MIHOMO_DIR/whitelist.txt"
    apply_whitelist
}

install_files() {
    info "Installing config files and scripts..."
    mkdir -p "$BASE_DIR" "$SCRIPTS_DIR" "$WWW_DIR" \
             "$CONF_DIR" "$DNS_CERT_DIR" "$DNS_RULES_DIR_DEFAULT"

    # block/direct/blacklist manual files (all 4 match-type variants) are no
    # longer seeded here (UP-2): they are policy-owned now (policy.json's
    # inline block rules + subscription rules, seeded by seed_policy_defaults
    # below), and the daemon's writeManualFiles regenerates them from the
    # compiled policy on every boot/compile anyway -- a stub seeded here would
    # just be overwritten. See seed_policy_defaults() and cmd/5gpn-dns rules.go.

    # Phase 2: per-category subdirs for subscription-fetched caches (merged by
    # the resolver alongside the manual <cat>.txt above: <cat>.txt + <cat>/*.txt).
    install -d -m 0755 "${DNS_RULES_DIR_DEFAULT}"/{block,direct,blacklist,chnroute}

    # Remove stale pre-rename adblock category artifacts (renamed to block/).
    rm -f "${DNS_RULES_DIR_DEFAULT}"/adblock*.txt 2>/dev/null || true
    if [[ -d "${DNS_RULES_DIR_DEFAULT}/adblock" ]]; then
        warn "Preserving retired unmarked rules/adblock directory; current daemon ignores it."
    fi

    # Fresh-install fix (defense in depth #1): seed the manual chnroute file from
    # the bundled snapshot so 5gpn-dns has a non-empty chnroute at first boot,
    # before the subscription manager's in-process fetch has had a chance to run.
    # Only when the cache is absent — never clobber a fresher subscription-fetched
    # cache on re-install/upgrade. DNS_CHNROUTE (dns.env) points at this same path.
    if [[ -s "${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt" ]]; then
        info "Keeping existing ${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt."
    elif [[ -f "${SCRIPT_DIR}/etc/china_ip_list.txt" ]]; then
        install -m 0644 "${SCRIPT_DIR}/etc/china_ip_list.txt" \
            "${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt"
        ok "Seeded ${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt from bundled snapshot."
    else
        warn "${SCRIPT_DIR}/etc/china_ip_list.txt missing; chnroute unseeded until subscription fetch runs."
    fi

    write_subscriptions_json
    seed_policy_defaults

    # repo scripts -> /opt/5gpn/scripts. Drop the removed setup-firewall.sh if a
    # previous install staged it (the host firewall is no longer managed here).
    rm -f "${SCRIPTS_DIR}/setup-firewall.sh"
    for f in "${SCRIPT_DIR}"/scripts/*.sh; do
        [[ -e "$f" ]] || continue
        install -m 0755 "$f" "${SCRIPTS_DIR}/$(basename "$f")"
    done
    # repo systemd units -> /opt/5gpn/etc/systemd (staged copies; install_units
    # installs them into /etc/systemd/system from here or from the checkout).
    install -d -m 0755 "${BASE_DIR}/etc/systemd"
    for u in "${SCRIPT_DIR}"/etc/systemd/*.service; do
        [[ -e "$u" ]] || continue
        install -m 0644 "$u" "${BASE_DIR}/etc/systemd/$(basename "$u")"
    done
    ok "Files installed under ${BASE_DIR} and ${CONF_DIR}."
}

# install_manage_cli installs the `5gpn` management command: a small launcher on
# PATH that opens the management menu (or runs a subcommand), backed by a copy of
# this installer at /opt/5gpn/install.sh. So an operator just types `5gpn`.
launcher_owned() {
    [[ -f /usr/local/bin/5gpn && ! -L /usr/local/bin/5gpn ]] \
        && grep -qF 'BK=/opt/5gpn/install.sh' /usr/local/bin/5gpn \
        && grep -Eq '^# (Managed by 5gpn installer|5gpn management launcher)' /usr/local/bin/5gpn
}

install_manage_cli() {
    install -d -m 0755 "$BASE_DIR"
    [[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] \
        || { err "Installer must come from the verified quick-install bundle or a local checkout."; return 1; }
    publish_executable "$SCRIPT_PATH" "${BASE_DIR}/install.sh" || return 1
    if [[ -e /usr/local/bin/5gpn ]] && ! launcher_owned; then
        err "Refusing to overwrite an unowned /usr/local/bin/5gpn."
        return 1
    fi
    local launcher
    launcher="$(mktemp /usr/local/bin/.5gpn.XXXXXX)" || return 1
    cat > "$launcher" <<'EOF'
#!/usr/bin/env bash
# Managed by 5gpn installer
# 5gpn management launcher. `5gpn` opens the menu; `5gpn <subcommand>` runs it
# directly (e.g. 5gpn --status, 5gpn restart, 5gpn --uninstall).
BK=/opt/5gpn/install.sh
[ -f "$BK" ] || { echo "5gpn backend missing ($BK); re-run the installer." >&2; exit 1; }
if [ $# -eq 0 ]; then exec bash "$BK" --menu; else exec bash "$BK" "$@"; fi
EOF
    chmod 0755 "$launcher"
    mv -f -- "$launcher" /usr/local/bin/5gpn
    ok "Management command installed: type '5gpn' to manage (status / restart / change domain / uninstall / …)."
}

# restart_services restarts the two 5gpn units (the in-process bot + iOS server
# come back with 5gpn-dns; mihomo is the data plane + panel SNI split).
restart_services() {
    check_root
    info "Restarting 5gpn services..."
    start_services
}

# _load_change_ctx resolves the shared change-command context from the single
# dns.env: identities, cert mode, email. Auto-detects
# + persists PUBLIC_IP if it was never captured (used by mihomo's listener bind,
# debug SANs, and HTTP-01 DNS validation; Cloudflare issuance itself needs no A).
# BASE_DOMAIN is the authoritative apex knob; WEB/DOT are the derived
# console.<base>/dot.<base> service domains read back from dns.env.
_load_change_ctx() {
    PUBLIC_IP="$(cfg_get DNS_PUBLIC_IP)"
    GATEWAY_IP="$(cfg_get DNS_GATEWAY_IP)"
    WEB_DOMAIN="$(cfg_get DNS_WEB_DOMAIN)"
    DOT_DOMAIN="$(cfg_get DNS_DOMAIN)"
    BASE_DOMAIN="$(cfg_get DNS_BASE_DOMAIN)"
    # Legacy fallback: a box predating the base-domain scheme has no
    # DNS_BASE_DOMAIN. Recover the apex from the (possibly console.<base>)
    # web-console domain so change-* still targets the right wildcard.
    [[ -z "$BASE_DOMAIN" ]] && BASE_DOMAIN="${WEB_DOMAIN#console.}"
    derive_domains "$BASE_DOMAIN"
    CERT_MODE="$(cfg_get CERT_MODE)"; CERT_MODE="${CERT_MODE:-cloudflare}"
    CERT_MODE="$(normalize_cert_mode "$CERT_MODE" 2>/dev/null || printf '%s' "$CERT_MODE")"
    CERT_EMAIL="$(cfg_get CERT_EMAIL)"
    if [[ -z "$PUBLIC_IP" ]]; then
        get_public_ip                                            # sets PUBLIC_IP or exits
        set_dns_env_kv "${CONF_DIR}/dns.env" DNS_PUBLIC_IP "$PUBLIC_IP"
    fi
    MIHOMO_LISTEN_IPS="$(cfg_get DNS_MIHOMO_LISTEN_IPS)"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_MIHOMO_LISTEN_IPS "$MIHOMO_LISTEN_IPS"
    export PUBLIC_IP GATEWAY_IP WEB_DOMAIN DOT_DOMAIN BASE_DOMAIN CERT_MODE CERT_EMAIL MIHOMO_LISTEN_IPS
}

# derive_domains <base> — the SINGLE derivation of the three service subdomains
# from the operator's ONE base (apex) domain. This is the ONLY place that knows
# the console./zash./dot. prefix scheme -- every other call site (mihomo config
# render, dns.env writer, change-* commands) MUST obtain the derived domains by
# calling this function (or reading the globals it sets/exports), never by
# re-deriving "console.${base}"/"zash.${base}" inline, to avoid drift.
# An empty/unset <base> defaults to the "5gpn.local" placeholder -- the single
# fallback apex used whenever no real base domain is known yet (matches the
# CERT_MODE=debug placeholder in resolve_domains). Sets BASE_DOMAIN + the
# derived globals and exports them. console.<base> = the web console panel
# (WEB_DOMAIN is kept as a back-compat alias for it); zash.<base> = the
# zashboard panel; dot.<base> = DoT :853. All three are covered by the one
# *.<base> wildcard.
derive_domains() {
    BASE_DOMAIN="${1:-5gpn.local}"
    CONSOLE_DOMAIN="console.${BASE_DOMAIN}"
    ZASH_DOMAIN="zash.${BASE_DOMAIN}"
    DOT_DOMAIN="dot.${BASE_DOMAIN}"
    WEB_DOMAIN="$CONSOLE_DOMAIN"    # back-compat: WEB_DOMAIN == the console panel
    export BASE_DOMAIN CONSOLE_DOMAIN ZASH_DOMAIN DOT_DOMAIN WEB_DOMAIN
}

# Legacy configuration commands are compatibility entries for the single
# transactional TUI. Values on argv are deliberately rejected.
change_base_domain() {
    [[ -z "${1:-}" ]] || { err "Configuration arguments are disabled; use the TUI."; return 1; }
    full_install configure
}

change_public_ip() {
    [[ -z "${1:-}" ]] || { err "Configuration arguments are disabled; use the TUI."; return 1; }
    full_install configure
}

change_resolver() {
    [[ -z "${1:-}" ]] || { err "Configuration arguments are disabled; use the TUI."; return 1; }
    full_install configure
}

change_gateway() {
    [[ -z "${1:-}" ]] || { err "Configuration arguments are disabled; use the TUI."; return 1; }
    full_install configure
}

# manage_menu is the interactive management TUI shown by `5gpn`. gum when
# available on a TTY; a numbered read-menu otherwise. Loops until Quit.
manage_menu() {
    check_root
    install_gum
    if [[ ! -t 0 ]]; then
        err "The 5gpn menu is interactive. Run a subcommand directly, e.g.:"
        echo "  5gpn --status | 5gpn restart | 5gpn --uninstall" >&2
        exit 1
    fi
    local labels=(
        "状态 Status"
        "重启服务 Restart services"
        "编辑安装配置 Configure installation"
        "更新规则列表 Update rule lists"
        "添加 zashboard 白名单IP Add zashboard allowlist IP"
        "移除 zashboard 白名单IP Remove zashboard allowlist IP"
        "重新生成 iOS 描述文件 Regenerate iOS profile"
        "轮换控制台令牌 Rotate console token"
        "设置 Cloudflare Token Set Cloudflare token"
        "重置 mihomo 配置 Reset mihomo config"
        "配置 Telegram Bot"
        "卸载 Uninstall"
        "退出 Quit"
    )
    while true; do
        local choice=""
        if [[ "$_HAVE_GUM" == 1 ]]; then
            choice="$(printf '%s\n' "${labels[@]}" | gum choose --header '5gpn 管理 (↑/↓ 选择, Enter 确认)' || true)"
        else
            echo ""; echo "5gpn 管理菜单:"
            local i=1; for l in "${labels[@]}"; do echo "  $i) $l"; i=$((i+1)); done
            local n=""; read -r -p "选择编号: " n || true
            [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le ${#labels[@]} ]] && choice="${labels[$((n-1))]}"
        fi
        case "$choice" in
            "状态 Status")                          show_status ;;
            "重启服务 Restart services")            restart_services ;;
            "编辑安装配置 Configure installation")  full_install configure ;;
            "更新规则列表 Update rule lists")        do_update_lists ;;
            "添加 zashboard 白名单IP Add zashboard allowlist IP")    add_allow_ip ;;
            "移除 zashboard 白名单IP Remove zashboard allowlist IP") del_allow_ip ;;
            "重新生成 iOS 描述文件 Regenerate iOS profile") regen_ios ;;
            "轮换控制台令牌 Rotate console token")   rotate_token ;;
            "设置 Cloudflare Token Set Cloudflare token") set_cf_token ;;
            "重置 mihomo 配置 Reset mihomo config")
                if ask_yesno "确认备份并重置 operator-owned mihomo config?"; then reset_mihomo_config; fi ;;
            "配置 Telegram Bot")                    setup_tgbot ;;
            "卸载 Uninstall")                       uninstall; break ;;
            "退出 Quit"|"") break ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Domain + ACME certificate
# ----------------------------------------------------------------------------
is_valid_domain() {
    # Same FQDN rule as the Go bot's domainRE (cmd/5gpn-dns/bot.go); bash ERE has no
    # lookahead, so total length is checked separately): lowercase [a-z0-9-]
    # labels (<=63), alphabetic 2-63 TLD, total 1..253. Case-insensitive.
    local d; d="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ ${#d} -ge 1 && ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

normalize_cert_mode() {
    case "${1:-}" in
        cloudflare) printf '%s\n' cloudflare ;;
        http|http-01) printf '%s\n' http-01 ;;
        debug) printf '%s\n' debug ;;
        *) return 1 ;;
    esac
}

is_valid_ipv4() {
    # Dotted-quad, each octet 0..255, with NO leading zero on a multi-digit octet
    # — matching Go's net.ParseIP (cmd/5gpn-dns/config.go), which rejects e.g.
    # 010.0.0.1. Parity matters: DNS_GATEWAY_IP is fatal in the daemon, so a value
    # this validator accepts but net.ParseIP rejects would crash-loop 5gpn-dns on
    # restart. 10#$o forces base-10 so a lone "0" octet still compares numerically.
    local ip="${1:-}" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ ${#o} -gt 1 && "$o" == 0* ]] && return 1     # reject leading zeros (net.ParseIP parity)
        [[ "$((10#$o))" -le 255 ]] || return 1
    done
    return 0
}

resolve_domains() {
    # ONE operator domain knob: the base (apex) domain. The three service
    # domains are auto-derived subdomains (derive_domains), all covered by the
    # single selected certificate (wildcard in Cloudflare/debug, exact SANs in HTTP-01):
    #   console.<base> -> the web console (also exported as WEB_DOMAIN)
    #   zash.<base>    -> the zashboard panel
    #   dot.<base>     -> DoT :853 (Android Private DNS / iOS profile)
    #
    # Precedence for the base: env BASE_DOMAIN > env WEB_DOMAIN (back-compat
    # alias) > dns.env DNS_BASE_DOMAIN > dns.env DNS_WEB_DOMAIN (legacy box —
    # a console.<base> value is stripped back to <base>) > interactive prompt.
    # Required unless CERT_MODE=debug (which falls back to a placeholder apex —
    # a self-signed wildcard works without a real public domain).
    local base="${BASE_DOMAIN:-${WEB_DOMAIN:-}}"
    [[ -z "$base" ]] && base="$(cfg_get DNS_BASE_DOMAIN)"
    if [[ -z "$base" ]]; then
        local legacy_web; legacy_web="$(cfg_get DNS_WEB_DOMAIN)"
        [[ -n "$legacy_web" ]] && base="${legacy_web#console.}"
    fi

    if [[ -n "$base" ]]; then
        base="${base#http://}"; base="${base#https://}"; base="${base%/}"; base="${base// /}"
        is_valid_domain "$base" || { err "Invalid base domain '$base'."; exit 1; }
    elif [[ "${CERT_MODE:-cloudflare}" == "debug" ]]; then
        base="5gpn.local"
        warn "CERT_MODE=debug and no base domain set — using placeholder '${base}' for the self-signed wildcard."
    elif [[ ! -t 0 ]]; then
        err "No base domain. Run the attached-terminal configuration TUI."; exit 1
    else
        local input=""
        while true; do
            input="$(ask_text '请输入主域名 base domain (如 example.com; 使用 console./zash./dot. 子域):' || true)"
            input="${input#http://}"; input="${input#https://}"; input="${input%/}"; input="${input// /}"
            is_valid_domain "$input" && { base="$input"; break; }
            warn "Invalid domain; enter a full FQDN like example.com."
        done
    fi

    derive_domains "$base"
    info "Base domain: $BASE_DOMAIN  ($CONSOLE_DOMAIN / $ZASH_DOMAIN / $DOT_DOMAIN)"
    info "Public console requirement: create ${CONSOLE_DOMAIN} A -> ${PUBLIC_IP} (or client-routable ${GATEWAY_IP} in NPN) before completion."
}

resolve_gateway_ip() {
    # GATEWAY_IP = the client-facing address 5gpn-dns returns for CHINA-resolved
    # names so mihomo (sniff-forward data plane) intercepts + forwards them. Precedence:
    #   persisted dns.env > interactive prompt (default =
    #   detected PUBLIC_IP) > PUBLIC_IP (non-interactive first-install fallback).
    # PUBLIC_IP must already be resolved. A bare re-run reads the persisted value
    # from dns.env and does NOT re-prompt; only a first install on a TTY prompts.
    GATEWAY_IP="${GATEWAY_IP:-$(cfg_get DNS_GATEWAY_IP)}"
    if [[ -n "$GATEWAY_IP" ]]; then
        is_valid_ipv4 "$GATEWAY_IP" || { err "Invalid GATEWAY_IP '$GATEWAY_IP' (want an IPv4 like 172.22.0.1)."; exit 1; }
    elif [[ -t 0 ]]; then
        local input=""
        while true; do
            # ask_text's 2nd arg is gum's --placeholder (a ghost hint, NOT returned
            # on a bare Enter) — so an empty answer means "same as the public IP".
            input="$(ask_text '客户端可达的网关IP (回车=与公网IP相同; 内网/NPN 填内网地址如 172.22.0.1):' "$PUBLIC_IP" || true)"
            input="${input// /}"
            [[ -z "$input" ]] && { GATEWAY_IP="$PUBLIC_IP"; break; }
            is_valid_ipv4 "$input" && { GATEWAY_IP="$input"; break; }
            warn "无效 IPv4；请输入形如 172.22.0.1 的地址（或直接回车用公网IP ${PUBLIC_IP}）。"
        done
    else
        GATEWAY_IP="$PUBLIC_IP"   # non-interactive first install -> mirror PUBLIC_IP
    fi
    info "Gateway IP (client-facing): $GATEWAY_IP"
}

# ecs_to_cidr24 normalises an operator-entered IPv4 (or a.b.c.d/nn CIDR) to
# the /24 the daemon attaches as EDNS Client Subnet: a.b.c.0/24. A /24 (never
# the full address) is precise enough for CDN scheduling without shipping one
# identifiable client IP upstream.
ecs_to_cidr24() {
    local ip="${1%%/*}"
    printf '%s.0/24' "${ip%.*}"
}

resolve_china_ecs() {
    # CHINA_ECS = the EDNS Client Subnet the china group attaches to domestic
    # queries (persisted as DNS_CHINA_ECS). Precedence: persisted dns.env
    # > interactive prompt (default = CHINA_ECS_DEFAULT) > default. A bare
    # re-run reads the persisted value and does NOT re-prompt. Whatever the
    # source, the value is normalised to its /24. The web console can change
    # it later at runtime (Settings → 国内解析 ECS, writes /etc/5gpn/ecs.json
    # which overrides dns.env on the next restart).
    CHINA_ECS="${DNS_CHINA_ECS:-$(cfg_get DNS_CHINA_ECS)}"
    if [[ -n "$CHINA_ECS" ]]; then
        case "$CHINA_ECS" in
            off|none|disable|0)   # daemon-recognised "ECS disabled" values — keep verbatim
                export CHINA_ECS; info "China ECS: disabled (DNS_CHINA_ECS=${CHINA_ECS})."; return 0 ;;
        esac
        is_valid_ipv4 "${CHINA_ECS%%/*}" || { err "Invalid DNS_CHINA_ECS '$CHINA_ECS' (want an IPv4 like 122.96.30.1, its /24 CIDR, or 'off')."; exit 1; }
    elif [[ -t 0 ]]; then
        info "国内解析 ECS：请用手机【蜂窝流量】访问 ip.cn 查看当前出口 IP 并填入 —— 国内 CDN 会按该网段就近调度。"
        local input=""
        while true; do
            input="$(ask_text "客户端蜂窝出口IP (回车=默认 ${CHINA_ECS_DEFAULT}):" "$CHINA_ECS_DEFAULT" || true)"
            input="${input// /}"
            [[ -z "$input" ]] && { CHINA_ECS="$CHINA_ECS_DEFAULT"; break; }
            is_valid_ipv4 "${input%%/*}" && { CHINA_ECS="$input"; break; }
            warn "无效 IPv4；请输入形如 122.96.30.1 的地址（或直接回车用默认 ${CHINA_ECS_DEFAULT}）。"
        done
    else
        CHINA_ECS="$CHINA_ECS_DEFAULT"   # non-interactive first install
    fi
    CHINA_ECS="$(ecs_to_cidr24 "$CHINA_ECS")"
    export CHINA_ECS
    info "China ECS subnet: $CHINA_ECS"
}

# install_cert <base_domain> — provision ONE scoped production lineage and
# deploy it to all three role directories:
#   dot  -> ${DOT_CERT_DIR}  (serves DoT :853; also signs the iOS profile)
#   web  -> ${WEB_CERT_DIR}  (serves the web console behind the mihomo SNI split)
#   zash -> ${ZASH_CERT_DIR} (serves the zashboard panel)
# Three modes (resolved from persisted dns.env or the TUI):
#   cloudflare (default) — Let's Encrypt DNS-01 through the Cloudflare API
#                       for apex + *.<base>; auto-renews unattended
#                       via the daily certbot timer (see install_renewal_automation).
#                       A protected token is required for unattended renewal,
#                       even when the current lineage is reusable. ensure_cf_token
#                       obtains it with this precedence:
#                         1. Valid saved /etc/5gpn/acme/cloudflare.ini — reused.
#                         2. Interactive ask_secret on a TTY (guarded || true).
#                         3. Explicit error — non-interactive with no saved token.
#                       Use '5gpn --set-cf-token' (or the manage menu) to update
#                       the token at any time.
#   http-01            — Let's Encrypt standalone HTTP challenge for the exact
#                       console/zash/dot service SANs. The TUI confirms the DNS
#                       plan, then waits for 1.1.1.1 to see every A record at
#                       PUBLIC_IP with no AAAA. Issuance and due renewal briefly
#                       stop and restore mihomo to release public TCP :80.
#   debug              — a self-signed WILDCARD cert for test/dev boxes with no
#                       public domain. No certbot, no DNS-01, no renewal.
#                       iOS/browsers will flag it untrusted; that is the point
#                       of "debug".
cert_has_exact_san() {
    local cert="$1" wanted="$2"
    openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p' | grep -Fxq -- "$wanted"
}

cert_dns_san_count() {
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p' | wc -l | tr -d '[:space:]'
}

cert_key_matches() {
    local cert="$1" key="$2" a b
    a="$(mktemp)"; b="$(mktemp)"
    openssl x509 -in "$cert" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER > "$a" 2>/dev/null \
        && openssl pkey -in "$key" -pubout -outform DER > "$b" 2>/dev/null \
        && cmp -s "$a" "$b"
    local rc=$?
    rm -f -- "$a" "$b"
    return "$rc"
}

cert_chain_trusted() {
    local cert="$1"
    openssl verify -purpose sslserver -CApath /etc/ssl/certs -untrusted "$cert" "$cert" >/dev/null 2>&1 \
        || { [[ -f /etc/pki/tls/certs/ca-bundle.crt ]] \
             && openssl verify -purpose sslserver -CAfile /etc/pki/tls/certs/ca-bundle.crt \
                    -untrusted "$cert" "$cert" >/dev/null 2>&1; }
}

cert_identity_matches_mode() {
    local cert="$1" key="$2" base="$3" mode="$4" dns_san_count
    [[ -s "$cert" && -s "$key" ]] || return 1
    dns_san_count="$(cert_dns_san_count "$cert")" || return 1
    case "$mode" in
        cloudflare|debug)
            [[ "$dns_san_count" == 2 ]] || return 1
            cert_has_exact_san "$cert" "$base" || return 1
            cert_has_exact_san "$cert" "*.${base}" || return 1 ;;
        http|http-01)
            [[ "$dns_san_count" == 3 ]] || return 1
            cert_has_exact_san "$cert" "console.${base}" || return 1
            cert_has_exact_san "$cert" "zash.${base}" || return 1
            cert_has_exact_san "$cert" "dot.${base}" || return 1 ;;
        *) return 1 ;;
    esac
    openssl x509 -checkhost "dot.${base}" -noout -in "$cert" >/dev/null 2>&1 || return 1
    cert_key_matches "$cert" "$key"
}

validate_cert_pair() {
    local cert="$1" key="$2" base="$3" seconds="$4" trust="$5"
    local mode="${6:-cloudflare}"
    [[ "$trust" == debug ]] && mode=debug
    openssl x509 -checkend "$seconds" -noout -in "$cert" >/dev/null 2>&1 || return 1
    cert_identity_matches_mode "$cert" "$key" "$base" "$mode" || return 1
    [[ "$trust" != production ]] || cert_chain_trusted "$cert"
}

cert_provenance_matches() {
    local mode="$1" base="$2" f="$DNS_CERT_DIR/.provenance"
    [[ -f "$f" && ! -L "$f" ]] || return 1
    [[ "$(grep -E '^mode=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)" == "$mode" ]] || return 1
    [[ "$(grep -E '^base=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)" == "$base" ]]
}

cert_provenance_base_matches() {
    local base="$1" f="$DNS_CERT_DIR/.provenance" mode
    [[ -f "$f" && ! -L "$f" ]] || return 1
    [[ "$(grep -E '^base=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)" == "$base" ]] || return 1
    mode="$(grep -E '^mode=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)"
    [[ "$mode" == cloudflare || "$mode" == http-01 || "$mode" == debug ]]
}

certbot_renewal_conf_scoped() {
    local conf="$1" base="$2" key value expected server
    [[ -f "$conf" && ! -L "$conf" ]] || return 1
    for key in archive_dir cert privkey chain fullchain; do
        value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null \
            | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$key" in
            archive_dir) expected="/etc/letsencrypt/archive/${base}" ;;
            *) expected="/etc/letsencrypt/live/${base}/${key}.pem" ;;
        esac
        [[ "$value" == "$expected" ]] || return 1
    done
    # 5gpn uses one audited directory deploy hook and its own mode-aware wrapper.
    # Persisted per-lineage hooks would execute arbitrary root commands when the
    # timer/Bot renews a lineage, so they are never adopted or preserved.
    if grep -Eq '^[[:space:]]*(pre_hook|post_hook|deploy_hook|renew_hook)[[:space:]]*=[[:space:]]*[^[:space:]]' "$conf"; then
        return 1
    fi
    server="$(grep -E '^[[:space:]]*server[[:space:]]*=' "$conf" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
    [[ "$server" == "$LE_PRODUCTION_SERVER" ]]
}

certbot_renewal_mode_matches() {
    local base="$1" mode="$2" conf="/etc/letsencrypt/renewal/${base}.conf" auth value
    certbot_renewal_conf_scoped "$conf" "$base" || return 1
    auth="$(grep -E '^[[:space:]]*authenticator[[:space:]]*=' "$conf" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
    case "$mode" in
        cloudflare)
            [[ "$auth" == dns-cloudflare ]] || return 1
            value="$(grep -E '^[[:space:]]*dns_cloudflare_credentials[[:space:]]*=' "$conf" 2>/dev/null \
                | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
            [[ "$value" == "$ACME_DIR/cloudflare.ini" ]] ;;
        http-01)
            [[ "$auth" == standalone ]] || return 1
            value="$(grep -E '^[[:space:]]*http01_port[[:space:]]*=' "$conf" 2>/dev/null \
                | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
            [[ -z "$value" || "$value" == 80 ]] || return 1
            value="$(grep -E '^[[:space:]]*http01_address[[:space:]]*=' "$conf" 2>/dev/null \
                | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
            [[ -z "$value" ]] ;;
        *) return 1 ;;
    esac
}

decommission_lineage_safe() {
    local base="$1" mode=""
    cert_provenance_base_matches "$base" || return 1
    [[ -d "/etc/letsencrypt/live/${base}" && ! -L "/etc/letsencrypt/live/${base}" \
       && -d "/etc/letsencrypt/archive/${base}" && ! -L "/etc/letsencrypt/archive/${base}" ]] \
        || return 1
    if certbot_renewal_mode_matches "$base" cloudflare; then
        mode=cloudflare
    elif certbot_renewal_mode_matches "$base" http-01; then
        mode=http-01
    else
        return 1
    fi
    cert_identity_matches_mode "/etc/letsencrypt/live/${base}/fullchain.pem" \
        "/etc/letsencrypt/live/${base}/privkey.pem" "$base" "$mode"
}

write_cert_provenance() {
    local mode="$1" base="$2" tmp
    install -d -m 0750 "$DNS_CERT_DIR"
    tmp="$(mktemp "${DNS_CERT_DIR}/.provenance.XXXXXX")" || return 1
    printf 'mode=%s\nbase=%s\n' "$mode" "$base" > "$tmp"
    chmod 0640 "$tmp"
    mv -f -- "$tmp" "$DNS_CERT_DIR/.provenance"
}

renew_hook_owned() {
    local hook="/etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh"
    [[ -f "$hook" && ! -L "$hook" ]] || return 1
    grep -qF 'renewed 5gpn WILDCARD lineage' "$hook" 2>/dev/null \
        || { grep -qF "Let's Encrypt renewal deploy hook" "$hook" 2>/dev/null \
             && grep -qF 'DNS_BASE_DOMAIN' "$hook" 2>/dev/null \
             && grep -qF '/etc/5gpn/cert' "$hook" 2>/dev/null; }
}

remove_owned_renew_hook() {
    local hook="/etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh"
    [[ -e "$hook" ]] || return 0
    if renew_hook_owned; then
        rm -f -- "$hook"
    else
        warn "Preserving unowned Certbot deploy hook: $hook"
    fi
}

install_cert_deploy_hook() {
    local src="${SCRIPT_DIR}/scripts/renew-hook.sh"
    [[ -f "$src" ]] || src="${SCRIPTS_DIR}/renew-hook.sh"
    [[ -f "$src" ]] \
        || { err "scripts/renew-hook.sh not found; refusing production certificate setup without a deploy hook."; return 1; }
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy || return 1
    if [[ -e /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh ]] \
       && ! renew_hook_owned; then
        err "Refusing to overwrite an unowned Certbot deploy hook: /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh"
        return 1
    fi
    install -m 0755 "$src" /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh || return 1
    ok "Renewal deploy hook installed (validated dot/web/zash publication + iOS re-sign)."
}

# Certbot standalone must own public TCP :80. Run in a subshell so its signal
# traps cannot replace the full install transaction's ERR/EXIT rollback traps.
# Only a mihomo service that was active is stopped and restored; an unrelated
# process occupying :80 is never killed and simply makes Certbot fail closed.
run_http_certbot() (
    local restore=0 certbot_rc=0 restore_rc=0
    restore_active_mihomo() {
        [[ "$restore" == 1 ]] || return 0
        restore=0
        systemctl start mihomo.service \
            && ok "mihomo restored after the HTTP-01 challenge." \
            || { err "Could not restore mihomo after the HTTP-01 challenge."; return 1; }
    }
    trap 'restore_active_mihomo || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if systemctl is-active --quiet mihomo.service 2>/dev/null; then
        info "Temporarily stopping mihomo to release TCP :80 for HTTP-01."
        restore=1
        systemctl stop mihomo.service \
            || { err "Could not stop mihomo; refusing to run Certbot while :80 may be occupied."; exit 1; }
    fi
    certbot "$@" || certbot_rc=$?
    restore_active_mihomo || restore_rc=$?
    trap - EXIT INT TERM
    [[ "$certbot_rc" == 0 ]] || exit "$certbot_rc"
    [[ "$restore_rc" == 0 ]] || exit "$restore_rc"
)

install_cert() {
    local base="${1:?install_cert needs a base domain}"
    local mode="$CERT_MODE"
    local live="/etc/letsencrypt/live/${base}"

    if [ "$mode" = "debug" ]; then
        local debug_src="${DEBUG_CERT_DIR}/${base}"
        if validate_cert_pair "${debug_src}/fullchain.pem" "${debug_src}/privkey.pem" \
                "$base" "$((30*86400))" debug \
           && { [[ -z "$GATEWAY_IP" ]] || openssl x509 -checkip "$GATEWAY_IP" -noout -in "${debug_src}/fullchain.pem" >/dev/null 2>&1; } \
           && { [[ -z "$PUBLIC_IP" ]] || openssl x509 -checkip "$PUBLIC_IP" -noout -in "${debug_src}/fullchain.pem" >/dev/null 2>&1; }; then
            info "Reusing valid matching debug certificate for *.${base}."
        else
            issue_selfsigned_wildcard "$base" || return 1
        fi
        deploy_cert_roles "$base" "$debug_src"
        write_cert_provenance debug "$base"
        remove_owned_renew_hook
        remove_owned_unit 5gpn-certbot-renew.timer
        remove_owned_unit 5gpn-certbot-renew.service
        systemctl daemon-reload 2>/dev/null || true
        return 0
    fi

    [[ "$mode" == cloudflare || "$mode" == http-01 ]] \
        || { err "CERT_MODE must be cloudflare, http-01, or debug."; return 1; }

    # Reuse is mode-aware. The SAN shape distinguishes wildcard DNS-01 from
    # exact-name HTTP-01; renewal.conf and provenance prevent a mode switch
    # from silently retaining the previous authenticator.
    local force=0 cf_token_ready=0
    if validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
            "$base" "$((30*86400))" production "$mode" \
       && certbot_renewal_mode_matches "$base" "$mode" \
       && { [[ ! -e "$DNS_CERT_DIR/.provenance" ]] || cert_provenance_matches "$mode" "$base"; }; then
        info "Valid ${mode} certificate and matching renewal authenticator for ${base} (>30d); reusing."
    else
        if [[ ! -e "$live" ]] && compgen -G "/etc/letsencrypt/live/${base}-[0-9][0-9][0-9][0-9]" >/dev/null; then
            err "A duplicate Certbot lineage exists for ${base}, but the canonical ${live} lineage is absent."
            err "Resolve that lineage explicitly before reinstalling; refusing silent reuse without scoped renewal."
            return 1
        fi
        [[ -e "$live" ]] && force=1
        local -a certbot_args=(certonly --cert-name "$base" --server "$LE_PRODUCTION_SERVER" --agree-tos -n \
            -m "${CERT_EMAIL:-admin@${base}}" --keep-until-expiring --no-directory-hooks)
        if [[ "$mode" == cloudflare ]]; then
            ensure_cf_token || return 1
            cf_token_ready=1
            info "Issuing Let's Encrypt WILDCARD cert for *.${base} (Cloudflare DNS-01)..."
            certbot_args+=(--dns-cloudflare \
                --dns-cloudflare-credentials "${ACME_DIR}/cloudflare.ini" \
                --dns-cloudflare-propagation-seconds 30 -d "*.${base}" -d "${base}")
        else
            check_http_challenge_dns_once \
                || { err "HTTP-01 DNS changed after preflight: ${CERT_DNS_LAST_OBSERVATION:-no answer}."; return 1; }
            info "Issuing Let's Encrypt cert for ${CONSOLE_DOMAIN}, ${ZASH_DOMAIN}, ${DOT_DOMAIN} (HTTP-01 / :80)..."
            certbot_args+=(--standalone --preferred-challenges http-01 \
                -d "$CONSOLE_DOMAIN" -d "$ZASH_DOMAIN" -d "$DOT_DOMAIN")
        fi
        # Non-interactive Certbot otherwise refuses a changed SAN set when the
        # same cert-name switches between wildcard DNS-01 and exact HTTP-01.
        [[ "$force" == 1 ]] && certbot_args+=(--force-renewal --renew-with-new-domains)
        if [[ "$mode" == http-01 ]]; then
            run_http_certbot "${certbot_args[@]}" \
                || { err "Certbot HTTP-01 failed. Check all three public A records, absence of AAAA, TCP/80/NAT/security-group reachability, and rate limits."; return 1; }
        else
            certbot "${certbot_args[@]}" \
                || { err "Certbot DNS-01 failed for *.${base} (check the Cloudflare token's Zone:DNS:Edit scope + zone match)."; return 1; }
        fi
    fi

    validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" "$base" 86400 production "$mode" \
        || { err "Issued/reused production certificate failed trust, SAN, expiry, or key validation."; return 1; }
    certbot_renewal_mode_matches "$base" "$mode" \
        || { err "Certbot renewal config is unscoped, mode-mismatched, or contains persistent hooks."; return 1; }
    if [[ "$mode" == cloudflare && "$cf_token_ready" == 0 ]]; then
        ensure_cf_token || { err "Cloudflare renewal requires a protected API token even when the current certificate is reusable."; return 1; }
    fi
    deploy_cert_roles "$base" "$live" "$mode"
    write_cert_provenance "$mode" "$base"
    install_cert_deploy_hook
    install_renewal_automation
}

# issue_selfsigned_wildcard <base> — CERT_MODE=debug: a long-lived (825d)
# self-signed WILDCARD cert (CN=<base>, SAN=<base>+*.<base>+gateway/public IPs)
# so every role's cert works by IP or name on an internal test box. Debug
# material lives under /etc/5gpn/debug-cert only: writing through Certbot's
# /etc/letsencrypt/live symlinks can truncate the real archive certificates.
# No renewal machinery — and any production-mode automation a prior install
# left is dismantled so the daily timer cannot run an unwanted renewal.
issue_selfsigned_wildcard() {
    local base="$1"
    local live="${DEBUG_CERT_DIR}/${base}" tmp
    install -d -m 0700 "$live"
    tmp="$(mktemp -d "${live}/.new.XXXXXX")" \
        || { err "CERT_MODE=debug: could not create a certificate staging directory."; return 1; }
    local san="DNS:${base},DNS:*.${base}"
    [[ -n "${GATEWAY_IP:-}" ]] && san="${san},IP:${GATEWAY_IP}"
    [[ -n "${PUBLIC_IP:-}" && "${PUBLIC_IP:-}" != "${GATEWAY_IP:-}" ]] && san="${san},IP:${PUBLIC_IP}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "${tmp}/privkey.pem" -out "${tmp}/fullchain.pem" \
        -subj "/CN=${base}" -addext "subjectAltName=${san}" >/dev/null 2>&1 \
        || { rm -rf -- "$tmp"; err "CERT_MODE=debug: self-signed wildcard cert generation failed (is openssl installed?)."; return 1; }
    chmod 0600 "${tmp}/privkey.pem" "${tmp}/fullchain.pem"
    # Candidate files are complete before either live role source is replaced.
    # Both moves stay on the same filesystem and are therefore atomic.
    sync -f "${tmp}/privkey.pem" "${tmp}/fullchain.pem" 2>/dev/null || true
    mv -f -- "${tmp}/privkey.pem" "${live}/privkey.pem"
    mv -f -- "${tmp}/fullchain.pem" "${live}/fullchain.pem"
    rmdir -- "$tmp"
    warn "CERT_MODE=debug: SELF-SIGNED WILDCARD cert for *.${base} (CN=${base}, SAN=${san}). NOT trusted by clients — test/dev only."
    # Dismantle any production-mode renewal machinery a prior install left.
    remove_owned_renew_hook
    remove_owned_unit 5gpn-certbot-renew.timer
    remove_owned_unit 5gpn-certbot-renew.service
    systemctl daemon-reload 2>/dev/null || true
}

# deploy_cert_roles <base> — copy the selected lineage to all three role dirs.
# deploy_cert_roles <base> [src_dir] [mode] — copy the selected cert to all role
# dirs. Defaults to reading from the certbot lineage (/etc/letsencrypt/live/<base>);
# debug mode passes its isolated source directory explicitly.
deploy_cert_roles() {
    local base="$1" src="${2:-/etc/letsencrypt/live/${base}}" mode="${3:-${CERT_MODE:-cloudflare}}"
    local r dest cert_tmp key_tmp trust=production i
    local -a roles=(dot web zash) dests=() cert_tmps=() key_tmps=()
    [[ "$src" == "$DEBUG_CERT_DIR"/* ]] && { trust=debug; mode=debug; }
    validate_cert_pair "${src}/fullchain.pem" "${src}/privkey.pem" "$base" 0 "$trust" "$mode" \
        || { err "Certificate source failed validation: $src"; return 1; }
    # Stage and validate every role before replacing any live file.
    for r in "${roles[@]}"; do
        dest="/etc/5gpn/cert/$r"
        install -d -m 0750 "$dest" \
            || { rm -f -- "${cert_tmps[@]}" "${key_tmps[@]}"; return 1; }
        cert_tmp="$(mktemp "${dest}/.fullchain.pem.XXXXXX")" \
            || { rm -f -- "${cert_tmps[@]}" "${key_tmps[@]}"; return 1; }
        key_tmp="$(mktemp "${dest}/.privkey.pem.XXXXXX")" \
            || { rm -f -- "$cert_tmp" "${cert_tmps[@]}" "${key_tmps[@]}"; return 1; }
        dests+=("$dest"); cert_tmps+=("$cert_tmp"); key_tmps+=("$key_tmp")
        install -m 0640 "${src}/fullchain.pem" "$cert_tmp" \
            && install -m 0640 "${src}/privkey.pem" "$key_tmp" \
            && validate_cert_pair "$cert_tmp" "$key_tmp" "$base" 0 "$trust" "$mode" \
            || { rm -f -- "${cert_tmps[@]}" "${key_tmps[@]}"; return 1; }
        sync -f "$cert_tmp" "$key_tmp" 2>/dev/null || true
    done
    for i in "${!roles[@]}"; do
        mv -f -- "${key_tmps[$i]}" "${dests[$i]}/privkey.pem" \
            || { rm -f -- "${cert_tmps[@]}" "${key_tmps[@]}"; return 1; }
        key_tmps[$i]=""
        mv -f -- "${cert_tmps[$i]}" "${dests[$i]}/fullchain.pem" \
            || { rm -f -- "${cert_tmps[@]}" "${key_tmps[@]}"; return 1; }
        cert_tmps[$i]=""
    done
    ok "${mode} certificate for ${base} deployed to dot/web/zash role dirs."
}

# install_renewal_automation installs a daily systemd timer running the single
# mode-aware renewal helper. It checks the exact cert-name and due window;
# Cloudflare renews without interruption, while HTTP-01 first validates DNS via
# 1.1.1.1 and safely releases/restores mihomo's TCP :80 listeners.
install_renewal_automation() {
    local service_tmp timer_tmp
    [[ -x "${SCRIPTS_DIR}/cert-renew.sh" ]] \
        || { err "Scoped renewal helper is missing: ${SCRIPTS_DIR}/cert-renew.sh"; return 1; }
    service_tmp="$(mktemp /etc/systemd/system/.5gpn-certbot-renew.service.XXXXXX)" || return 1
    timer_tmp="$(mktemp /etc/systemd/system/.5gpn-certbot-renew.timer.XXXXXX)" \
        || { rm -f -- "$service_tmp"; return 1; }
    cat > "$service_tmp" <<'EOF'
[Unit]
Description=5gpn certbot renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=30min
TimeoutStopSec=2min
ExecStart=/opt/5gpn/scripts/cert-renew.sh --quiet
EOF
    cat > "$timer_tmp" <<'EOF'
[Unit]
Description=5gpn daily certbot renewal check

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$service_tmp" "$timer_tmp"
    mv -f -- "$service_tmp" /etc/systemd/system/5gpn-certbot-renew.service
    mv -f -- "$timer_tmp" /etc/systemd/system/5gpn-certbot-renew.timer
    systemctl daemon-reload
    systemctl enable --now 5gpn-certbot-renew.timer \
        || { err "Could not enable/start scoped certificate renewal timer."; return 1; }
    systemctl is-enabled --quiet 5gpn-certbot-renew.timer \
        || { err "Scoped certificate renewal timer is not enabled."; return 1; }
    ok "Installed 5gpn-certbot-renew.timer (daily, Persistent, mode-aware scoped renewal)."
}

acme_dir_safe() {
    [[ -d "$ACME_DIR" && ! -L "$ACME_DIR" \
       && "$(readlink -f -- "$ACME_DIR" 2>/dev/null || true)" == "$ACME_DIR" \
       && "$(file_uid "$ACME_DIR")" == 0 \
       && "$(file_mode "$ACME_DIR")" == 700 ]]
}

ensure_acme_dir() {
    if [[ ! -e "$ACME_DIR" && ! -L "$ACME_DIR" ]]; then
        install -d -o root -g root -m 0700 "$ACME_DIR" \
            || { err "Cannot create ACME credentials directory ${ACME_DIR}."; return 1; }
    fi
    acme_dir_safe \
        || { err "ACME credentials directory must be canonical, root-owned, non-symlink, and mode 0700: ${ACME_DIR}"; return 1; }
}

cf_credential_file_safe() {
    local f="${ACME_DIR}/cloudflare.ini"
    [[ -f "$f" && ! -L "$f" \
       && "$(file_uid "$f")" == 0 \
       && "$(file_mode "$f")" == 600 ]]
}

# has_valid_cf_credential returns 0 (true) when ${ACME_DIR}/cloudflare.ini
# exists and contains a non-empty dns_cloudflare_api_token value.
# Used by ensure_cf_token to decide whether to prompt or reuse.
has_valid_cf_credential() {
    local f="${ACME_DIR}/cloudflare.ini"
    acme_dir_safe && cf_credential_file_safe && [[ -s "$f" ]] || return 1
    grep -qE '^dns_cloudflare_api_token[[:space:]]*=[[:space:]]*[^[:space:]]' "$f"
}

# write_cf_credential validates tok and writes it atomically to
# ${ACME_DIR}/cloudflare.ini. Shared by ensure_cf_token and set_cf_token so
# that CR/LF rejection, directory setup, atomic write, and temp-file cleanup
# live in exactly one place.
#   - Rejects CR and LF (no multi-line token injection).
#   - Creates ACME_DIR at 0700.
#   - Stages to a same-directory temp file (same-fs → atomic rename).
#   - Removes the temp file explicitly on any publication failure.
write_cf_credential() {
    local tok="$1"
    if [[ "$tok" =~ $'\r' || "$tok" =~ $'\n' ]]; then
        err "Cloudflare API token must not contain CR or LF (check for a trailing newline)."; return 1
    fi
    ensure_acme_dir || return 1
    if [[ -e "${ACME_DIR}/cloudflare.ini" || -L "${ACME_DIR}/cloudflare.ini" ]]; then
        cf_credential_file_safe \
            || { err "Refusing unsafe existing Cloudflare credential path: ${ACME_DIR}/cloudflare.ini"; return 1; }
    fi
    local tmp; tmp="$(mktemp "${ACME_DIR}/.cloudflare.ini.XXXXXX")" || { err "Cannot create temp file in ${ACME_DIR}."; return 1; }
    printf 'dns_cloudflare_api_token = %s\n' "$tok" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0600 "$tmp"                                         || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "${ACME_DIR}/cloudflare.ini"              || { rm -f -- "$tmp"; return 1; }
}

# ensure_cf_token guarantees a valid Cloudflare API token exists in
# ${ACME_DIR}/cloudflare.ini before Certbot issuance or renewal automation is
# enabled. A reusable lineage still requires the credential for future renewal.
# Precedence:
#   1. Valid saved credential (has_valid_cf_credential) — reuse, no prompt.
#   2. Interactive ask_secret    — TTY only, guarded with || true under set -e.
#   3. Explicit error            — non-interactive with no saved token.
# CR and LF are rejected before writing (delegated to write_cf_credential).
# The credentials dir is created as 0700; the file is written atomically and
# chmod'd to 0600.
ensure_cf_token() {
    ensure_acme_dir || return 1
    # 1) Valid saved credential — reuse without prompting.
    if has_valid_cf_credential; then
        info "Reusing saved Cloudflare API token (${ACME_DIR}/cloudflare.ini)."
        return 0
    fi
    local tok=""
    [[ -t 0 ]] && tok="$(ask_secret 'Cloudflare API token (Zone:DNS:Edit scope for your base zone):' || true)"
    if [[ -z "$tok" ]]; then
        err "No Cloudflare API token. Run the attached-terminal TUI; shell environment tokens are not accepted."
        return 1
    fi
    write_cf_credential "$tok" || return 1
    ok "Cloudflare API token saved → ${ACME_DIR}/cloudflare.ini (0600, root-only)."
}

# set_cf_token prompts for (or accepts as $1) the Cloudflare API token used by
# install_cert's cloudflare/DNS-01 issuance path, and writes it to
# ${ACME_DIR}/cloudflare.ini (0600, root-only). This is the ONLY TUI/CLI op that
# writes that file — previously it had to be placed there by hand. The saved
# credential is required for both Cloudflare issuance and unattended renewal.
set_cf_token() {
    check_root
    [[ -z "${1:-}" ]] || { err "Token arguments are not accepted; enter it through the TUI."; return 1; }
    [[ -t 0 ]] || { err "Cloudflare token configuration requires the TUI."; return 1; }
    local tok=""
    tok="$(ask_secret 'Cloudflare API token (scope: Zone:DNS:Edit for your base zone)' || true)"
    [ -z "$tok" ] && { warn "no token entered — unchanged."; return 0; }
    write_cf_credential "$tok" || return 1
    ok "Cloudflare token saved → ${ACME_DIR}/cloudflare.ini"
}

# ----------------------------------------------------------------------------
# Lists + rules, systemd units, iOS profile
# ----------------------------------------------------------------------------
run_update_lists() {
    info "Triggering 5gpn-dns rule-cache reload (subscriptions fetch in-process)..."
    bash "${SCRIPTS_DIR}/update-lists.sh"
    ok "Reload triggered."
}

# remove_legacy_firewall reverses only nftables tables that can be attributed to
# an older 5gpn install with a strong fingerprint. Older releases unfortunately
# used the generic `table inet filter`; deleting it based on the table name (or
# on the word "5gpn" in a comment) can destroy Docker/firewalld/operator rules.
# Never flush the global ruleset, rewrite /etc/nftables.conf, or disable the
# host's nftables service. A legacy persisted config is reported for the
# operator to migrate, but is deliberately left byte-for-byte untouched.
remove_legacy_firewall() {
    local family table dump deleted=0
    if command -v nft >/dev/null 2>&1; then
        # Some development/pre-release builds used a uniquely named table.
        for family in inet ip ip6; do
            for table in 5gpn 5gpn_filter; do
                if nft list table "$family" "$table" >/dev/null 2>&1; then
                    nft delete table "$family" "$table" \
                        && { warn "Removed legacy 5gpn nftables table: $family $table"; deleted=1; } \
                        || warn "Could not remove legacy 5gpn nftables table: $family $table"
                fi
            done
        done

        # Released legacy builds used the dangerously generic `inet filter`.
        # Even a strong legacy fingerprint cannot prove that an operator did
        # not later add unrelated rules to the same table, so report it but do
        # not delete the whole host-owned table.
        dump="$(nft list table inet filter 2>/dev/null || true)"
        if [[ -n "$dump" ]] \
           && grep -q 'dot_rate4' <<<"$dump" \
           && grep -q 'dot_rate6' <<<"$dump" \
           && grep -q 'doh_rate4' <<<"$dump" \
           && grep -q 'doh_rate6' <<<"$dump" \
           && grep -Eq 'tcp dport (9443|8111)' <<<"$dump"; then
            warn "Strongly fingerprinted legacy 5gpn rules remain in host table 'inet filter'; preserving the entire mixed-ownership table for manual migration."
        fi
    fi
    if grep -qE 'dot_rate4|doh_rate4|dns53_agg|5gpn firewall' /etc/nftables.conf 2>/dev/null; then
        warn "Legacy 5gpn rules remain in /etc/nftables.conf; safety policy left that host-owned file unchanged. Remove only the old 5gpn table block before reboot."
    elif [[ "$deleted" == 1 ]]; then
        info "No legacy 5gpn persistence fingerprint found in /etc/nftables.conf."
    fi
    rm -f "${SCRIPTS_DIR}/setup-firewall.sh" 2>/dev/null || true
}

preflight_unit_ownership() {
    local unit
    for unit in 5gpn-dns.service mihomo.service \
                5gpn-certbot-renew.service 5gpn-certbot-renew.timer; do
        if systemctl cat "$unit" >/dev/null 2>&1 || [[ -e "/etc/systemd/system/$unit" ]]; then
            unit_file_owned_by_5gpn "$unit" \
                || { err "Refusing to replace an existing non-5gpn unit: $unit"; return 1; }
        fi
    done
}

install_units() {
    info "Installing systemd units (5gpn-dns + mihomo)..."
    # Prefer the repo checkout; fall back to the staged copies under /opt/5gpn
    # (a piped curl|bash install has no checkout after install_files staged them).
    local src u
    for u in 5gpn-dns.service mihomo.service; do
        if [[ -f "${SCRIPT_DIR}/etc/systemd/${u}" ]]; then
            src="${SCRIPT_DIR}/etc/systemd/${u}"
        elif [[ -f "${BASE_DIR}/etc/systemd/${u}" ]]; then
            src="${BASE_DIR}/etc/systemd/${u}"
        else
            err "etc/systemd/${u} not found (checkout or ${BASE_DIR}/etc/systemd)."
            exit 1
        fi
        local candidate
        candidate="$(mktemp "/etc/systemd/system/.${u}.XXXXXX")" || return 1
        install -m 0644 "$src" "$candidate" || { rm -f -- "$candidate"; return 1; }
        sync -f "$candidate" 2>/dev/null || true
        mv -f -- "$candidate" "/etc/systemd/system/${u}"
    done
    systemctl daemon-reload
    ok "5gpn-dns.service + mihomo.service installed."
}

write_dns_env() {
    # Write /etc/5gpn/dns.env from install-time collected vars.
    # cert paths always point at the /etc/5gpn/cert copies (maintained by renew-hook.sh).
    mkdir -p "$CONF_DIR"

    # DNS_API_TOKEN: reuse an existing token across re-installs (never rotate a
    # working token); otherwise generate one.
    # Read current values from the single config file (dns.env). Secrets + tuning
    # knobs are preserved across a re-install; caller environment is ignored.
    local existing_token existing_tgtoken existing_tgadmins existing_tgfile existing_tgproxy existing_tgalerts existing_china existing_trust
    existing_token="$(cfg_get DNS_API_TOKEN)"
    existing_tgtoken="$(cfg_get TGBOT_TOKEN)"
    existing_tgadmins="$(cfg_get TGBOT_ADMINS)"
    existing_tgfile="$(cfg_get DNS_TGBOT_FILE)"
    existing_tgproxy="$(cfg_get TGBOT_PROXY_URL)"
    existing_tgalerts="$(cfg_get TGBOT_ALERTS)"
    existing_china="$(cfg_get DNS_CHINA)"
    existing_trust="$(cfg_get DNS_TRUST)"
	DNS_API_TOKEN="${existing_token:-$(openssl rand -hex 32)}"
	local tg_token="$existing_tgtoken"
	local tg_admins="$existing_tgadmins"
	local tg_file="${existing_tgfile:-${CONF_DIR}/tgbot.json}"
	local tg_proxy="$existing_tgproxy"
    local tg_alerts="${existing_tgalerts:-false}"
    # DNS_TRUST default is the 22.22.22.22 sentinel (same convention as
    # XRAY_RESOLVER): a bare IP is queried over plain UDP; "host@IP" entries
    # use DoT. Operators change it post-install via the web console
    # (Settings → upstream DNS), which persists to /etc/5gpn/upstreams.json.
    local dns_china="${existing_china:-223.5.5.5,119.29.29.29}"
    local dns_trust="${existing_trust:-dns.google@8.8.8.8,one.one.one.one@1.1.1.1}"

    # Mihomo migration: console/zash/base domains obtained from derive_domains,
    # the SINGLE derivation from the operator's base (apex) domain
    # (console.<base> / zash.<base>), also used by render_mihomo_config and the
    # *.<base> wildcard install_cert issues, so dns.env and the rendered
    # config.yaml agree instead of drifting. A legacy box with no BASE_DOMAIN
    # recovers the apex from the (possibly console.<base>) web domain; an
    # empty base falls back to derive_domains' own "5gpn.local" placeholder.
    local base_domain="$BASE_DOMAIN"
    derive_domains "$base_domain"
    # Mihomo's loopback external-controller API + the zashboard source-IP
    # allowlist file it reloads from (add_allow_ip/del_allow_ip/apply_whitelist
    # already hardcode these same two values; persisting them here lets the
    # daemon read back what it's actually being served against).
    local dns_mihomo_controller="$(cfg_get DNS_MIHOMO_CONTROLLER)"; dns_mihomo_controller="${dns_mihomo_controller:-127.0.0.1:9090}"
    local dns_mihomo_secret="$(cfg_get DNS_MIHOMO_SECRET)"
    local dns_whitelist_file="$(cfg_get DNS_WHITELIST_FILE)"; dns_whitelist_file="${dns_whitelist_file:-${MIHOMO_DIR}/whitelist.txt}"
    # SP-3 zashboard panel: dir + listen address for the second loopback HTTPS
    # panel (Task A1). DNS_ZASH_DIR is already resolved (dns.env > default)
    # up at cfg_get's definition — the global is authoritative here, so the value
    # written back matches what install_zashboard/clean/uninstall actually used.
    # DNS_ZASH_LISTEN resolves here (its only consumer). The cert paths below are
    # NOT preserved — they always point at the deploy_cert_roles zash/ copy, like
    # DNS_CERT/DNS_WEB_CERT.
    local dns_zash_dir="$DNS_ZASH_DIR"
    local dns_zash_listen="$(cfg_get DNS_ZASH_LISTEN)"; dns_zash_listen="${dns_zash_listen:-127.0.0.2:443}"

    # Tuning knobs: current dns.env value > default (single-source, so a
    # hand-edited value survives an idempotent re-run).
    local max_inflight="$(cfg_get DNS_MAX_INFLIGHT)"; max_inflight="${max_inflight:-4096}"
    local ttl_min="$(cfg_get DNS_TTL_MIN)";               ttl_min="${ttl_min:-300}"
    local ttl_max="$(cfg_get DNS_TTL_MAX)";               ttl_max="${ttl_max:-86400}"
    local query_timeout="$(cfg_get DNS_QUERY_TIMEOUT)"; query_timeout="${query_timeout:-5s}"
    # China ECS: full_install resolves it via resolve_china_ecs (prompt + /24
    # normalisation); this fallback covers any other write_dns_env caller.
    local china_ecs="$CHINA_ECS"

    local dns_env_tmp; dns_env_tmp="$(mktemp "${CONF_DIR}/.dns.env.XXXXXX")"
    cat > "$dns_env_tmp" <<EOF
# 5gpn-dns config — the SINGLE source of truth (written by install.sh).
# 'systemctl reload 5gpn-dns' (SIGHUP) reloads ONLY the rule files under
# /etc/5gpn/rules/ + chnroute, NOT this file — a daemon knob here needs
# 'systemctl restart 5gpn-dns' (read once at startup). Re-run install.sh for
# cert knobs. There are no separate .state files.

# DoT is the ONLY client-facing DNS transport (DoH/plain-:53 removed 2026-07-10).
DNS_LISTEN_DOT=:853
DNS_LISTEN_DEBUG=127.0.0.1:5353

# TLS certs — ONE scoped lineage. Cloudflare uses apex+wildcard; HTTP-01 uses
# exact console/zash/dot SANs. Either shape is deployed to THREE role dirs:
#   dot/  serves DoT :853 (also signs the iOS profile)
#   web/  serves the web console (loopback :443, behind the mihomo SNI split)
#   zash/ serves the zashboard panel
# All hot-reload on file-mtime change; pinned mihomo v1.19.28 guarantees that
# mihomo reloads the controller certificate files automatically, and
# renew-hook.sh redeploys on renewal.
DNS_CERT=${DOT_CERT_DIR}/fullchain.pem
DNS_KEY=${DOT_CERT_DIR}/privkey.pem
DNS_WEB_CERT=${WEB_CERT_DIR}/fullchain.pem
DNS_WEB_KEY=${WEB_CERT_DIR}/privkey.pem

# ── Deployment identity + cert (read by install.sh/renew-hook.sh; also read by
# the in-process Telegram bot). DNS_BASE_DOMAIN = the operator's ONE apex domain
# (the cert-name); the three service domains are auto-derived subdomains and
# covered by the selected wildcard or exact-SAN certificate:
#   DNS_DOMAIN         = dot.<base>      (DoT :853)
#   DNS_WEB_DOMAIN     = console.<base>  (web console; == DNS_CONSOLE_DOMAIN)
#   DNS_CONSOLE_DOMAIN = console.<base>  (mihomo SNI-split to loopback :443)
#   DNS_ZASH_DOMAIN    = zash.<base>     (zashboard panel)
# ──
DNS_DOMAIN=${DOT_DOMAIN}
DNS_WEB_DOMAIN=${WEB_DOMAIN}
DNS_BASE_DOMAIN=${BASE_DOMAIN}
DNS_CONSOLE_DOMAIN=${CONSOLE_DOMAIN}
DNS_ZASH_DOMAIN=${ZASH_DOMAIN}
DNS_PUBLIC_IP=${PUBLIC_IP}
DNS_GATEWAY_IP=${GATEWAY_IP}
# Local addresses on which mihomo binds its public tunnel listeners. This is
# deliberately separate from DNS_PUBLIC_IP (which may be a provider/NAT
# identity) and DNS_GATEWAY_IP (the address returned to clients). Every entry
# must be assigned to this host; loopback is reserved for panel backends.
DNS_MIHOMO_LISTEN_IPS=${MIHOMO_LISTEN_IPS}
CERT_MODE=${CERT_MODE}
CERT_EMAIL=${CERT_EMAIL}

# Upstream resolver groups. DNS_CHINA entries are plain-UDP IPs; DNS_TRUST
# entries are bare "IP" (plain UDP — e.g. the 22.22.22.22 internal-resolver
# sentinel) or "serverName@IP" (DoT). These are the INSTALL-TIME defaults:
# when /etc/5gpn/upstreams.json exists (written by the web console via
# Settings → upstream DNS, hot-applied without a restart) it overrides both.
DNS_CHINA=${dns_china}
DNS_TRUST=${dns_trust}

# EDNS Client Subnet attached to china-group queries: the /24 of the clients'
# cellular egress IP (check ip.cn ON CELLULAR data), so CN CDNs schedule
# answers near the clients. INSTALL-TIME default: when /etc/5gpn/ecs.json
# exists (written by the web console via Settings → 国内解析 ECS, hot-applied
# without a restart) it overrides this. "off" disables ECS.
DNS_CHINA_ECS=${china_ecs}

DNS_RULES_DIR=${DNS_RULES_DIR_DEFAULT}
DNS_CHNROUTE=${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt

# Egress DNS Broker's fallback resolver (consumed by 5gpn-dns to build the
# broker's fallback exchanger; mihomo's config.yaml never references it -- its
# dns.nameserver always points at the fixed loopback broker). Persisted here so
# a bare re-run re-applies it and '5gpn change-resolver' survives.
# Default 22.22.22.22 is a NON-functional placeholder — set a real plain-IPv4 or
# https://…/dns-query DoH via '5gpn change-resolver'.
# DNS_EGRESS_RESOLVER is the PRIMARY key (the mihomo-migration rename of
# XRAY_RESOLVER; the daemon's config.go prefers it). XRAY_RESOLVER is written
# with the same value as a back-compat alias for a box upgraded before the
# rename; both work until XRAY_RESOLVER is retired.
DNS_EGRESS_RESOLVER=${EGRESS_RESOLVER}
XRAY_RESOLVER=${EGRESS_RESOLVER}
DNS_EGRESS_BROKER=127.0.0.1:5354

# Phase 2: remote rule-list subscriptions (fetched in-process; caches written to
# DNS_RULES_DIR/<category>/<name>.txt, merged automatically with the manual
# <category>.txt files above). See /etc/5gpn/subscriptions.json.
DNS_SUBSCRIPTIONS=${CONF_DIR}/subscriptions.json

# Control-plane HTTPS API + public web console. Browsers reach it
# at https://DNS_WEB_DOMAIN via the mihomo :443 SNI split, which forwards
# straight to this loopback listener. The SPA and /ios/ are public; every
# /api/* request requires the bearer token. The token is generated once and
# preserved across re-installs so a working token is never rotated out from
# under an operator config.
#
# Binds LOOPBACK :443 directly: mihomo owns the public :443 socket and routes
# console.<base> to this listener. Do not bind the daemon itself publicly.
DNS_LISTEN_API=127.0.0.1:443
DNS_API_TOKEN=${DNS_API_TOKEN}

# Mihomo's loopback external-controller API (DNS_MIHOMO_CONTROLLER) + its
# bearer secret (DNS_MIHOMO_SECRET) + the zashboard source-IP allowlist file
# (DNS_WHITELIST_FILE) mihomo's rule-provider reloads from. add_allow_ip /
# del_allow_ip / apply_whitelist already hardcode these same values directly;
# persisting them here lets the daemon read back what it's actually being
# served against (consumption is follow-up work -- see apply_whitelist's
# TODO(Task 6) marker).
DNS_MIHOMO_CONTROLLER=${dns_mihomo_controller}
DNS_MIHOMO_SECRET=${dns_mihomo_secret}
DNS_WHITELIST_FILE=${dns_whitelist_file}

# SP-3 zashboard panel (Task A1): ZashDir is the unzipped Zephyruso/zashboard
# dist served by a SECOND loopback HTTPS listener on ZashListen. ZashCert/Key
# always point at the selected certificate's zash/ role-dir copy
# (deploy_cert_roles); the daemon's fallback remains defense in depth.
DNS_ZASH_DIR=${dns_zash_dir}
DNS_ZASH_LISTEN=${dns_zash_listen}
DNS_ZASH_CERT=${ZASH_CERT_DIR}/fullchain.pem
DNS_ZASH_KEY=${ZASH_CERT_DIR}/privkey.pem

# Control-console SPA (served from disk by the loopback :443 server). Populated
# by install_web from the 5gpn-web release tarball; empty dir -> built-in placeholder.
DNS_WEB_DIR=${DNS_WEB_DIR}

# iOS .mobileconfig files (served by the daemon at the public /ios/ path of the
# web console — the standalone :8111 responder was removed).
WWW_DIR=${WWW_DIR}

# Phase 5: in-process Telegram control bot (goroutine of 5gpn-dns). Populated by
# 'install.sh --setup-tgbot' (or set here manually). Empty token ⇒ bot disabled.
# TGBOT_ADMINS is a comma-separated list of authorized numeric Telegram IDs.
# These are the INSTALL-TIME DEFAULTS: the web console (Settings → Telegram bot,
# PUT /api/tgbot) writes /etc/5gpn/tgbot.json, which OVERRIDES these at startup
# and hot-restarts the bot without touching this read-only file (same pattern as
# upstreams.json). Delete tgbot.json to fall back to the values below.
TGBOT_TOKEN=${tg_token}
TGBOT_ADMINS=${tg_admins}
# Runtime token/admin override written atomically by PUT /api/tgbot. This path
# must remain in a daemon-writable directory (the systemd unit permits
# /etc/5gpn); changing it takes effect after a 5gpn-dns restart.
DNS_TGBOT_FILE=${tg_file}
# Optional Telegram-only HTTP/HTTPS CONNECT proxy. This is a daemon startup
# knob, not part of tgbot.json: change it in dns.env and restart 5gpn-dns.
# 5gpn never edits operator-owned mihomo config to create a proxy listener.
TGBOT_PROXY_URL=${tg_proxy}
# Opt-in transition alerts for certificate, mihomo and upstream health. This is
# also a daemon startup knob; the bot cannot report its own process/host death,
# so DNS_HEARTBEAT_URL remains the external dead-man's switch.
TGBOT_ALERTS=${tg_alerts}

DNS_CACHE_SIZE=${CACHE_SIZE}
DNS_MAX_INFLIGHT=${max_inflight}
DNS_TTL_MIN=${ttl_min}
DNS_TTL_MAX=${ttl_max}
DNS_QUERY_TIMEOUT=${query_timeout}
EOF
    # Merge: carry over any operator-set knob from the old dns.env that this
    # heredoc does NOT emit (e.g. DNS_HEARTBEAT_URL, DNS_HEARTBEAT_INTERVAL,
    # DNS_CHINA_0X20) so an idempotent re-install never silently drops a
    # hand-added tuning line. Install-managed keys (emitted above) keep the
    # freshly-resolved value. Keys whose FEATURE was removed (DoH/plain-53
    # listeners, CLIENT_NET gating, firewall knobs, the :8111 iOS listener, the
    # in-process token-lockout blocker) are dropped instead of carried, so an
    # upgraded box doesn't keep re-enabling surfaces that no longer exist.
    local removed_keys="DNS_LISTEN_DOH= DNS_LISTEN_PLAIN= DNS_CLIENT_NET= DNS_PUBLIC_INGRESS= SETUP_FIREWALL= DOT_RATE= DOT_BURST= DNS53_AGG_RATE= DNS_IOS_LISTEN= DNS_PROFILE_DOMAIN= DNS_AUTH_FAIL_LIMIT= DNS_AUTH_FAIL_WINDOW= DNS_AUTH_BLOCK= DNS_EGRESS_MODEL= DNS_EGRESS_NODES="
    if [[ -f "${CONF_DIR}/dns.env" ]]; then
        local managed_keys; managed_keys="$(grep -oE '^[A-Za-z0-9_]+=' "$dns_env_tmp" | sort -u)"
        local carried=0 line key
        while IFS= read -r line; do
            case "$line" in ''|\#*) continue ;; esac
            [[ "$line" == *=* ]] || continue
            key="${line%%=*}="
            case " $removed_keys " in *" $key "*) continue ;; esac
            # DNS_POLICY_RULES is the live unified policy file override. Every
            # other knob under the old namespace belonged to the retired
            # draft/shadow implementation and must not survive an upgrade.
            case "$key" in
                DNS_POLICY_RULES=) ;;
                DNS_POLICY_*=) continue ;;
            esac
            if ! printf '%s\n' "$managed_keys" | grep -qxF "$key"; then
                if [[ $carried -eq 0 ]]; then
                    printf '\n# --- preserved operator-set knobs (carried over on re-install) ---\n' >> "$dns_env_tmp"
                    carried=1
                fi
                printf '%s\n' "$line" >> "$dns_env_tmp"
            fi
        done < "${CONF_DIR}/dns.env"
    fi
    chmod 0640 "$dns_env_tmp"
    sync -f "$dns_env_tmp" 2>/dev/null || true
    mv -f -- "$dns_env_tmp" "${CONF_DIR}/dns.env"
    sync -f "$CONF_DIR" 2>/dev/null || true
    ok "Written ${CONF_DIR}/dns.env (operator-set extra knobs preserved; removed-feature knobs dropped)."
}

setup_ios_profile() {
    info "Generating iOS DoT profile..."
    claim_ios_dir || { err "Refusing unowned iOS profile directory: $WWW_DIR"; return 1; }
    local gw="${GATEWAY_IP:-$PUBLIC_IP}" candidate
    candidate="$(mktemp -d "${BASE_DIR}/.www.new.XXXXXX")" || return 1
    write_ownership_marker "$candidate" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE" \
        || { rmdir -- "$candidate"; return 1; }
    if [[ -x "${SCRIPTS_DIR}/gen-ios-profile.sh" ]]; then
        # The profile configures (and is signed with) the DoT domain's cert.
        if ! bash "${SCRIPTS_DIR}/gen-ios-profile.sh" "$DOT_DOMAIN" "$gw" "$candidate"; then
            warn "gen-ios-profile.sh failed because a signed profile could not be produced — no profile served."
            rm -rf -- "$candidate"
            return 1
        fi
    else
        warn "scripts/gen-ios-profile.sh not present yet; skipping profile generation."
        rm -rf -- "$candidate"
        return 1
    fi
    publish_owned_tree "$candidate" "$WWW_DIR" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE" \
        || { rm -rf -- "$candidate"; return 1; }
    rm -rf -- "$candidate"

    # The .mobileconfig is served by the 5gpn-dns daemon at the web console's
    # public /ios/ path (the standalone :8111 responder was removed). Clean up
    # any socket-activated unit a prior install left.
    if systemctl list-unit-files 2>/dev/null | grep -q '^5gpn-iosprofile\.'; then
        remove_owned_unit 5gpn-iosprofile.socket
        remove_owned_unit '5gpn-iosprofile@.service'
        systemctl daemon-reload 2>/dev/null || true
        info "Removed obsolete socket-activated iOS responder (daemon serves /ios/ now)."
    fi
    ok "iOS profile generated (served at https://${CONSOLE_DOMAIN:-<console-domain>}/ios/)."
}

print_qr() {
    local console="${CONSOLE_DOMAIN:-$(cfg_get DNS_CONSOLE_DOMAIN)}"
    [[ -n "$console" ]] || return 0
    local url="https://${console}/ios/ios-dot.mobileconfig"
    if command -v qrencode >/dev/null 2>&1; then
        echo ""; info "Scan to install the iOS profile:"
        qrencode -t ANSIUTF8 "$url" || true
    fi
}

# Certificate/public-bootstrap DNS checks use a fixed independent resolver. A
# system resolver can be this gateway itself (and therefore synthesize the
# desired answer before public DNS is ready), which is unsafe for both HTTP-01
# and the public console bootstrap.
CERT_DNS_LAST_OBSERVATION=""

cert_dns_name_matches() {
    local domain="$1" require_no_aaaa="$2"; shift 2
    local raw="" ips="" aaaa="" ip expected matched
    command -v dig >/dev/null 2>&1 \
        || { CERT_DNS_LAST_OBSERVATION="dig is unavailable"; return 1; }
    raw="$(dig +time=3 +tries=1 +short A "$domain" @"$CERT_DNS_RESOLVER" 2>/dev/null || true)"
    ips="$(printf '%s\n' "$raw" | awk '/^[0-9]+(\.[0-9]+){3}$/' || true)"
    if [[ "$require_no_aaaa" == 1 ]]; then
        aaaa="$(dig +time=3 +tries=1 +short AAAA "$domain" @"$CERT_DNS_RESOLVER" 2>/dev/null \
            | awk '/:/' || true)"
    else
        aaaa="not-required"
    fi
    CERT_DNS_LAST_OBSERVATION="${domain}: A=[${ips//$'\n'/, }] AAAA=[${aaaa//$'\n'/, }]"
    [[ -n "$ips" ]] || return 1
    [[ "$require_no_aaaa" != 1 || -z "$aaaa" ]] || return 1
    while IFS= read -r ip; do
        matched=0
        for expected in "$@"; do
            [[ -n "$expected" && "$ip" == "$expected" ]] && { matched=1; break; }
        done
        [[ "$matched" == 1 ]] || return 1
    done <<<"$ips"
}

wait_for_cert_dns() {
    local description="$1"; shift
    local check_fn="$1"; shift
    local started=$SECONDS elapsed
    info "Waiting for ${description} through DNS ${CERT_DNS_RESOLVER} (up to ${CERT_DNS_WAIT_TIMEOUT}s)..."
    while true; do
        if "$check_fn" "$@"; then
            return 0
        fi
        elapsed=$((SECONDS - started))
        if (( elapsed >= CERT_DNS_WAIT_TIMEOUT )); then
            err "DNS did not converge through ${CERT_DNS_RESOLVER} within ${CERT_DNS_WAIT_TIMEOUT}s."
            err "Last observation: ${CERT_DNS_LAST_OBSERVATION:-no answer}."
            return 1
        fi
        info "DNS not ready (${CERT_DNS_LAST_OBSERVATION:-no answer}); retrying in ${CERT_DNS_WAIT_INTERVAL}s."
        sleep "$CERT_DNS_WAIT_INTERVAL"
    done
}

check_console_dns_once() {
    local console="$1"
    cert_dns_name_matches "$console" 0 "${PUBLIC_IP:-}" "${GATEWAY_IP:-}" || return 1
    ok "Public console DNS verified via ${CERT_DNS_RESOLVER}: ${CERT_DNS_LAST_OBSERVATION}."
}

check_http_challenge_dns_once() {
    local domain
    for domain in "$CONSOLE_DOMAIN" "$ZASH_DOMAIN" "$DOT_DOMAIN"; do
        cert_dns_name_matches "$domain" 1 "$PUBLIC_IP" || return 1
    done
    for domain in "$CONSOLE_DOMAIN" "$ZASH_DOMAIN" "$DOT_DOMAIN"; do
        ok "HTTP-01 DNS verified via ${CERT_DNS_RESOLVER}: ${domain} A ${PUBLIC_IP} (no AAAA)."
    done
}

# The public gate is mode-aware: Cloudflare only needs the console bootstrap
# name, HTTP-01 needs all exact certificate SANs, and debug is intentionally
# allowed to use the private 5gpn.local placeholder.
verify_console_dns() {
    local mode="${CERT_MODE:-cloudflare}"
    case "$mode" in
        debug)
            info "CERT_MODE=debug: skipping public DNS propagation checks."
            return 0 ;;
        http|http-01)
            wait_for_cert_dns "HTTP-01 service records" check_http_challenge_dns_once \
                || { err "Set console/zash/dot A records to DNS_PUBLIC_IP=${PUBLIC_IP}, remove AAAA records, and keep public TCP/80 reachable."; return 1; } ;;
        cloudflare)
            local console="${CONSOLE_DOMAIN:-$(cfg_get DNS_CONSOLE_DOMAIN)}"
            [[ -n "$console" ]] \
                || { err "DNS_CONSOLE_DOMAIN is empty; cannot verify the public console endpoint."; return 1; }
            wait_for_cert_dns "public console record" check_console_dns_once "$console" \
                || { err "Create '${console} A -> ${PUBLIC_IP:-<PUBLIC_IP>}' (or client-routable ${GATEWAY_IP:-<GATEWAY_IP>} in NPN)."; return 1; } ;;
        *) err "Unknown CERT_MODE '${mode}' during DNS verification."; return 1 ;;
    esac
}

verify_console_endpoint() {
    [[ -s "${WWW_DIR}/ios-dot.mobileconfig" ]] \
        || { warn "iOS profile file is absent; endpoint content probe skipped (profile generation already reported fail-closed)."; return 0; }
    local console="${CONSOLE_DOMAIN:-$(cfg_get DNS_CONSOLE_DOMAIN)}"
    local bind_ip="${MIHOMO_LISTEN_IPS%%,*}" tmp headers code api_code root_code
    [[ -n "$console" && -n "$bind_ip" ]] \
        || { err "Cannot probe console SNI: console domain or mihomo bind address is empty."; return 1; }
    tmp="$(mktemp -d /tmp/5gpn-console-probe.XXXXXX)" || return 1
    claim_temp_dir "$tmp" || { rmdir -- "$tmp"; return 1; }
    code="$(curl --silent --show-error --insecure --max-time 5 \
        --resolve "${console}:443:${bind_ip}" -D "$tmp/headers" -o "$tmp/body" \
        -w '%{http_code}' "https://${console}/ios/ios-dot.mobileconfig" 2>/dev/null || true)"
    if [[ "$code" != 200 ]] \
       || ! grep -qi '^Content-Type:[[:space:]]*application/x-apple-aspen-config' "$tmp/headers"; then
        remove_temp_dir "$tmp"
        err "Public console profile probe failed (HTTP ${code:-none}); operator mihomo config may lack the public ${console} host/rule. Update it or run '5gpn mihomo-reset'."
        return 1
    fi
    api_code="$(curl --silent --insecure --max-time 5 --resolve "${console}:443:${bind_ip}" \
        -o /dev/null -w '%{http_code}' "https://${console}/api/status" 2>/dev/null || true)"
    root_code="$(curl --silent --insecure --max-time 5 --resolve "${console}:443:${bind_ip}" \
        -o /dev/null -w '%{http_code}' "https://${console}/" 2>/dev/null || true)"
    remove_temp_dir "$tmp"
    [[ "$root_code" == 200 ]] \
        || { err "Public console SPA probe failed: / returned HTTP ${root_code:-none}, want 200."; return 1; }
    [[ "$api_code" == 401 ]] \
        || { err "Console API auth probe failed: unauthenticated /api/status returned HTTP ${api_code:-none}, want 401."; return 1; }
    ok "Public console verified: SPA and mobileconfig are reachable; /api remains bearer-protected."
}

# ----------------------------------------------------------------------------
# Host tuning ownership
# ----------------------------------------------------------------------------
# The current application-layer architecture does not require forwarding,
# conntrack sizing, BBR, module loading, or global socket/sysctl changes. Remove
# only files carrying the old 5gpn-specific names; do not run `sysctl --system`
# because that would re-apply unrelated host configuration.
system_tuning() {
    rm -f /etc/sysctl.d/99-5gpn.conf /etc/modules-load.d/5gpn.conf /etc/modprobe.d/5gpn.conf
    info "Host sysctl/module tuning is not managed by 5gpn."
}

# ----------------------------------------------------------------------------
# Service lifecycle
# ----------------------------------------------------------------------------
probe_mihomo_ready() {
    systemctl is-active --quiet mihomo || return 1
    local secret ip port
    secret="${DNS_MIHOMO_SECRET:-$(cfg_get DNS_MIHOMO_SECRET)}"
    local -a curl_args=(--fail --silent --show-error --max-time 2 -o /dev/null)
    [[ -n "$secret" ]] && curl_args+=(-H "Authorization: Bearer $secret")
    mihomo_controller_curl "/version" "${curl_args[@]}" >/dev/null 2>&1 || return 1

    command -v ss >/dev/null 2>&1 || return 1
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        for port in 80 443; do
            ss -H -ltn 2>/dev/null | grep -Fq "${ip}:${port} " || return 1
        done
        ss -H -lun 2>/dev/null | grep -Fq "${ip}:443 " || return 1
    done < <(printf '%s\n' "$MIHOMO_LISTEN_IPS" | tr ',' '\n')
}

probe_dns_ready() {
    systemctl is-active --quiet 5gpn-dns || return 1
    local token domain
    token="${DNS_API_TOKEN:-$(cfg_get DNS_API_TOKEN)}"
    domain="${DOT_DOMAIN:-$(cfg_get DNS_DOMAIN)}"; domain="${domain:-localhost}"
    curl --fail --silent --show-error --insecure --max-time 2 -o /dev/null \
        -H "Authorization: Bearer $token" https://127.0.0.1/api/status \
        >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || return 1
    timeout 4 openssl s_client -brief -connect 127.0.0.1:853 -servername "$domain" \
        </dev/null 2>&1 | grep -Eq 'CONNECTION ESTABLISHED|Protocol version:'
}

wait_service_ready() {
    local svc="$1" i
    for i in {1..20}; do
        case "$svc" in
            mihomo)    probe_mihomo_ready && { ok "mihomo readiness passed (controller + local TCP/UDP listeners)."; return 0; } ;;
            5gpn-dns)  probe_dns_ready && { ok "5gpn-dns readiness passed (API + DoT TLS handshake)."; return 0; } ;;
        esac
        sleep 1
    done
    err "$svc did not become ready within 20s (journalctl -u $svc)."
    return 1
}

start_services() {
    info "Enabling and starting services..."
    PUBLIC_IP="${PUBLIC_IP:-$(cfg_get DNS_PUBLIC_IP)}"
    GATEWAY_IP="${GATEWAY_IP:-$(cfg_get DNS_GATEWAY_IP)}"
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    export PUBLIC_IP GATEWAY_IP MIHOMO_LISTEN_IPS
    systemctl daemon-reload || { err "systemctl daemon-reload failed."; return 1; }
    # mihomo is the data plane + panel SNI split; it was installed by
    # install_units but is enabled/started HERE (nothing started it before).
    # Start mihomo first so DNS cannot advertise gateway answers before the
    # data-plane listener is live. Any enable/start/readiness failure is fatal;
    # full_install must never print success for a broken deployment.
    local svc failed=0
    for svc in mihomo 5gpn-dns; do
        if ! systemctl enable "$svc" >/dev/null 2>&1; then
            err "could not enable $svc (check: systemctl status $svc)."
            failed=1
        fi
        if ! systemctl restart "$svc" 2>/dev/null && ! systemctl start "$svc" 2>/dev/null; then
            err "could not start $svc (check: journalctl -u $svc)."
            failed=1
            continue
        fi
        wait_service_ready "$svc" || failed=1
    done
    [[ "$failed" == 0 ]] || return 1
}

restart_dns_service() {
    systemctl restart 5gpn-dns 2>/dev/null \
        || { err "could not restart 5gpn-dns (journalctl -u 5gpn-dns)."; return 1; }
    wait_service_ready 5gpn-dns
}

# ----------------------------------------------------------------------------
# Optional control plane: Telegram bot (an in-process goroutine of 5gpn-dns).
# dns.env supplies startup defaults; the validated runtime override at
# DNS_TGBOT_FILE is authoritative once created by the control API.
# ----------------------------------------------------------------------------
# Set (or replace) a KEY=VALUE line in a dotenv file, preserving all other keys.
# Appends the key if absent without clobbering unrelated settings.
set_dns_env_kv() {
    local f="$1" key="$2" val="$3" tmp
    mkdir -p "$(dirname "$f")"; touch "$f"
    tmp="$(mktemp "${f}.XXXXXX")"
    # Drop any existing (commented or live) definition of this key, then append the new one.
    grep -vE "^#?[[:space:]]*${key}=" "$f" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    chmod 0640 "$tmp"
    sync -f "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$f"
    sync -f "$(dirname "$f")" 2>/dev/null || true
}

# Call the live, bearer-authenticated control API on its loopback listener.
# The response body is written to the caller-provided file; stdout contains only
# the HTTP status so callers can distinguish validation (400), availability
# (503), and persistence (500) failures without parsing human text. --insecure
# is limited to this loopback hop because the listener certificate names
# console.<base>, not 127.0.0.1.
tgbot_api_call() {
    local method="$1" data_file="$2" response_file="$3" token auth_file rc=0
    token="$(cfg_get DNS_API_TOKEN)"
    [[ -n "$token" ]] || { err "DNS_API_TOKEN is missing from ${CONF_DIR}/dns.env; cannot authenticate the local control API."; return 1; }
    [[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] \
        || { err "DNS_API_TOKEN contains a newline; refusing to construct an HTTP header."; return 1; }
    auth_file="$(mktemp)" || return 1
    chmod 600 "$auth_file" || { rm -f -- "$auth_file"; return 1; }
    printf 'Authorization: Bearer %s\n' "$token" > "$auth_file" \
        || { rm -f -- "$auth_file"; return 1; }

    # NewBot performs getMe plus webhook preflight synchronously; allow that
    # bounded validation to finish so curl cannot time out while the server is
    # still committing a change the CLI would mistakenly treat as rejected.
    local -a args=(--silent --show-error --insecure --noproxy '*' --connect-timeout 10 --max-time 90
        --request "$method" -H "@${auth_file}"
        -o "$response_file" -w '%{http_code}')
    if [[ -n "$data_file" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "@${data_file}")
    fi
    curl "${args[@]}" https://127.0.0.1/api/tgbot || rc=$?
    rm -f -- "$auth_file"
    return "$rc"
}

setup_tgbot_legacy_inline() {
    check_root
    install_gum
    [[ -t 0 ]] || { err "Telegram configuration requires the TUI."; return 1; }
    local envf="${CONF_DIR}/dns.env"
    [[ -f "$envf" ]] || { err "${envf} not found (run a full install first)."; return 1; }

    # Clean up the old python bot unit if a previous install left it behind
    # (the bot is an in-process goroutine of 5gpn-dns now).
    systemctl disable --now 5gpn-tgbot 2>/dev/null || true
    rm -f /etc/systemd/system/5gpn-tgbot.service
    systemctl daemon-reload 2>/dev/null || true

    # The runtime override wins over TGBOT_TOKEN/TGBOT_ADMINS in dns.env. Use
    # the same authenticated Apply path as the web console so a new token is
    # checked with getMe, the live bot is swapped, and tgbot.json is published
    # atomically. Hand-writing dns.env here would be both inactive when an
    # override exists and capable of falsely reporting success for a bad token.
    local tgbot_file
    tgbot_file="$(cfg_get DNS_TGBOT_FILE)"; tgbot_file="${tgbot_file:-${CONF_DIR}/tgbot.json}"

    local request response current code detail
    request="$(mktemp)"; response="$(mktemp)"; current="$(mktemp)"
    chmod 600 "$request" "$response" "$current"

    local token="" admins="" proxy_url="" alerts="false" existing_token existing_admins include_token=1 override=0 token_set=0
    existing_token="$(cfg_get TGBOT_TOKEN)"
    existing_admins="$(cfg_get TGBOT_ADMINS)"

    if [[ -e "$tgbot_file" ]]; then
        override=1
        info "Runtime Telegram override detected at ${tgbot_file}; it is the active source, not TGBOT_* in dns.env."
        if ! code="$(tgbot_api_call GET "" "$current")"; then
            rm -f -- "$request" "$response" "$current"
            err "Could not read the live Telegram configuration; dns.env was left unchanged. Check: systemctl status 5gpn-dns"
            return 1
        fi
        if [[ "$code" != 200 ]]; then
            detail="$(tr '\n' ' ' < "$current" | cut -c1-300)"
            rm -f -- "$request" "$response" "$current"
            err "Local Telegram API returned HTTP ${code}: ${detail:-no response}. No configuration was changed."
            return 1
        fi
        grep -Eq '"token_set"[[:space:]]*:[[:space:]]*true' "$current" && token_set=1
        existing_admins="$(sed -n 's/.*"admins"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$current" | head -1)"
        include_token=0
    fi

    # Blank interactive input keeps the live token; caller environment is not
    # a credential input.
    # omits the token field; the API never discloses the current secret.
    if [[ "$override" == 0 ]]; then
        token="$existing_token"
        local entered_token=""
        entered_token="$(ask_secret 'Telegram Bot Token (blank keeps persisted token / cancels when none):' || true)"
        [[ -n "$entered_token" ]] && token="$entered_token"
    else
        token="$(ask_secret 'New Telegram Bot Token (blank keeps the active token):' || true)"
        [[ -n "$token" ]] && include_token=1
    fi

    if [[ "$include_token" == 1 ]]; then
        if [[ -z "$token" ]]; then
            rm -f -- "$request" "$response" "$current"
            info "No Telegram token supplied; nothing changed. Re-run later: $0 --setup-tgbot"
            return 0
        fi
        if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            rm -f -- "$request" "$response" "$current"
            err "Telegram token has an invalid format; no configuration was changed."
            return 1
        fi
    elif [[ "$token_set" != 1 ]]; then
        rm -f -- "$request" "$response" "$current"
        err "${tgbot_file} does not provide an active token. Enter one through the TUI; no configuration was changed."
        return 1
    fi

    admins="$existing_admins"
    local entered_admins
    entered_admins="$(ask_text "Authorized Telegram numeric IDs (comma-separated; blank keeps '${admins:-none}', type 'none' to clear):" || true)"
    if [[ "$entered_admins" == "none" ]]; then
        admins=""
    elif [[ -n "$entered_admins" ]]; then
        admins="$entered_admins"
    fi
    local raw_admins="$admins"
    admins="$(printf '%s' "$admins" | tr ', ' '\n\n' | grep -E '^[1-9][0-9]*$' | paste -sd ',' - 2>/dev/null || true)"
    if [[ -n "$raw_admins" && -z "$admins" ]]; then
        rm -f -- "$request" "$response" "$current"
        err "No valid positive numeric Telegram administrator ID was supplied; no configuration was changed."
        return 1
    fi

    proxy_url="$(cfg_get TGBOT_PROXY_URL)"
    local entered_proxy=""
    entered_proxy="$(ask_text "Telegram HTTP(S) proxy URL (blank keeps '${proxy_url:-none}', type 'none' to clear):" || true)"
    if [[ "$entered_proxy" == none ]]; then
        proxy_url=""
    elif [[ -n "$entered_proxy" ]]; then
        proxy_url="$entered_proxy"
    fi
    if [[ -n "$proxy_url" && ! "$proxy_url" =~ ^https?://[^/?#[:space:]]+/?$ ]]; then
        rm -f -- "$request" "$response" "$current"
        err "Telegram proxy must be an HTTP(S) origin URL without path/query/fragment."
        return 1
    fi
    alerts="$(cfg_get TGBOT_ALERTS)"; alerts="${alerts:-false}"
    local alert_choice=""
    alert_choice="$(ask_choice 'Telegram transition alerts' "keep current (${alerts})" 'disabled' 'enabled' || true)"
    [[ "$alert_choice" == enabled ]] && alerts=true
    [[ "$alert_choice" == disabled ]] && alerts=false

    if [[ "$include_token" == 1 ]]; then
        printf '{"token":"%s","admins":[%s]}\n' "$token" "$admins" > "$request"
    else
        printf '{"admins":[%s]}\n' "$admins" > "$request"
    fi

    if ! code="$(tgbot_api_call PUT "$request" "$response")"; then
        rm -f -- "$request" "$response" "$current"
        err "Could not reach the local Telegram API; no durable configuration was reported. Check: journalctl -u 5gpn-dns"
        return 1
    fi
    if [[ "$code" != 200 ]]; then
        detail="$(tr '\n' ' ' < "$response" | cut -c1-300)"
        rm -f -- "$request" "$response" "$current"
        err "Telegram configuration was rejected (HTTP ${code}): ${detail:-no response}."
        return 1
    fi
    set_dns_env_kv "$envf" TGBOT_PROXY_URL "$proxy_url"
    set_dns_env_kv "$envf" TGBOT_ALERTS "$alerts"
    systemctl restart 5gpn-dns 2>/dev/null \
        || { rm -f -- "$request" "$response" "$current"; err "Telegram settings were saved, but 5gpn-dns restart failed."; return 1; }
    rm -f -- "$request" "$response" "$current"
    local tgbot_mode
    tgbot_mode="$(stat -c '%a' "$tgbot_file" 2>/dev/null \
        || stat -f '%Lp' "$tgbot_file" 2>/dev/null || true)"
    if [[ ! -f "$tgbot_file" || -L "$tgbot_file" || "$tgbot_mode" != 600 ]]; then
        err "Telegram config may be live, but the expected 0600 override at ${tgbot_file} was not verified. If DNS_TGBOT_FILE changed, restart 5gpn-dns and retry."
        return 1
    fi

    if [[ -t 0 && "$_HAVE_GUM" == 1 ]]; then
        gum style --border rounded --padding "0 1" \
          "未知自己的 Telegram ID?" \
          "1) 给你的 bot 发 /id" \
          "2) 再运行 5gpn --setup-tgbot，或在 Web 设置中加入该 ID"
    fi
    ok "Telegram 配置已由守护进程接受并安全应用；有效配置已原子保存到 ${tgbot_file}。"
    info "The token remains redacted through the API; ${tgbot_file} is mode 0600."
    if [[ -z "$admins" ]]; then
        warn "No admin IDs set yet; only /id is useful until an administrator is added through this command or Web Settings."
    fi
    return 0
}

# rotate_token generates a fresh DNS_API_TOKEN, writes it into dns.env, and
# restarts 5gpn-dns so the new token takes effect (the control server reads the
# token at startup, so a SIGHUP reload is NOT enough — a restart is required).
# The old token stops working immediately; browsers must re-login with the new
# one. Mitigates the "token never rotates" exposure of the localStorage-held
# bearer credential.
rotate_token() {
    check_root
    [[ -t 0 && -t 1 ]] || { err "Token rotation requires an interactive TTY; refusing to write a secret to logs."; return 1; }
    local envf="${CONF_DIR}/dns.env"
    [[ -f "$envf" ]] || { err "${envf} not found (run a full install first)."; exit 1; }
    local new; new="$(openssl rand -hex 32)"
    set_dns_env_kv "$envf" DNS_API_TOKEN "$new"
    systemctl restart 5gpn-dns 2>/dev/null || warn "could not restart 5gpn-dns (check: journalctl -u 5gpn-dns)."
    {
        echo "控制台 token 已轮换（旧 token 立即失效）"
        echo ""
        echo "New token: ${new}"
        echo "(浏览器需用新 token 重新登录；仅显示一次)"
    } | card
}

# ----------------------------------------------------------------------------
# Domain-list management (rules/blacklist.txt) + list refresh + status
# ----------------------------------------------------------------------------
add_domain() {
    check_root
    local d="${1:-}"; is_valid_domain "$d" || { err "Invalid domain: '$d'"; exit 1; }
    local f="${DNS_RULES_DIR_DEFAULT}/blacklist.txt"; mkdir -p "$DNS_RULES_DIR_DEFAULT"; touch "$f"
    if grep -qxF "$d" "$f"; then info "$d already in proxy list."; else echo "$d" >> "$f"; ok "Added $d to forced-proxy list."; fi
    refresh_lists_and_restart
}

del_domain() {
    check_root
    local d="${1:-}"; [[ -n "$d" ]] || { err "Usage: --del-domain <domain>"; exit 1; }
    local f="${DNS_RULES_DIR_DEFAULT}/blacklist.txt"; [[ -f "$f" ]] || { warn "No proxy list."; return 0; }
    if grep -qxF "$d" "$f"; then grep -vxF "$d" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"; ok "Removed $d."; else info "$d not in list."; fi
    refresh_lists_and_restart
}

refresh_lists_and_restart() {
    local sd="${SCRIPTS_DIR}/update-lists.sh"; [[ -x "$sd" ]] || sd="${SCRIPT_DIR}/scripts/update-lists.sh"
    bash "$sd"
}

do_update_lists() {
    check_root
    info "Refreshing 5gpn-dns rule caches (reload; subscriptions fetch in-process)..."
    refresh_lists_and_restart
    ok "Lists refreshed."
}

regen_ios() {
    check_root
    DOT_DOMAIN="$(cfg_get DNS_DOMAIN)"
    WEB_DOMAIN="${WEB_DOMAIN:-$(cfg_get DNS_WEB_DOMAIN)}"
    CONSOLE_DOMAIN="${CONSOLE_DOMAIN:-$(cfg_get DNS_CONSOLE_DOMAIN)}"
    BASE_DOMAIN="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    derive_domains "$BASE_DOMAIN"
    CERT_MODE="$(cfg_get CERT_MODE)"; CERT_MODE="${CERT_MODE:-cloudflare}"
    CERT_MODE="$(normalize_cert_mode "$CERT_MODE" 2>/dev/null || printf '%s' "$CERT_MODE")"
    PUBLIC_IP="$(cfg_get DNS_PUBLIC_IP)"
    GATEWAY_IP="${GATEWAY_IP:-$(cfg_get DNS_GATEWAY_IP)}"
    [[ -n "$DOT_DOMAIN" && -n "$PUBLIC_IP" ]] || { err "Domain/public IP unknown; run a full install first."; exit 1; }
    if ! setup_ios_profile; then
        err "iOS profile not generated (fail-closed on unsigned profile). Fix certificate signing."
        exit 1
    fi
    # No service restart needed: 5gpn-dns serves the profile from WWW_DIR on each request.
    verify_console_dns
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    verify_console_endpoint
    print_qr
    ok "iOS profile regenerated: https://${CONSOLE_DOMAIN:-<console-domain>}/ios/ios-dot.mobileconfig"
}

show_status() {
    {
        local domain webdomain pubip svc s pd
        domain="$(cfg_get DNS_DOMAIN)"; domain="${domain:-N/A}"
        webdomain="$(cfg_get DNS_WEB_DOMAIN)"; webdomain="${webdomain:-N/A}"
        pubip="$(cfg_get DNS_PUBLIC_IP)"; pubip="${pubip:-N/A}"
        echo "📊 5gpn 状态"
        echo ""
        # Telegram bot + iOS profile path are in-process parts of 5gpn-dns now;
        # mihomo is the data plane + panel SNI split.
        for svc in "5gpn-dns" mihomo; do
            s="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
            echo "  $([[ "$s" == active ]] && echo '✅' || echo '❌') ${svc}  (${s})"
        done
        echo ""
        echo "  WebUI 域名  $webdomain  (https://${webdomain}/)"
        echo "  DoT 域名    $domain"
        echo "  公网 IP     $pubip"
        echo "  DoT         tls://${domain}:853"
        pd=0
        [[ -f "${DNS_RULES_DIR_DEFAULT}/blacklist.txt" ]] && \
            pd="$(grep -cvE '^[[:space:]]*(#|$)' "${DNS_RULES_DIR_DEFAULT}/blacklist.txt" 2>/dev/null | head -n1 || echo 0)"
        echo "  强制代理域名  ${pd:-0}"
        if [[ -f "${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt" ]]; then
            local f_lines now mtime f_age
            f_lines="$(grep -cvE '^[[:space:]]*(#|$)' "${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt" 2>/dev/null | head -n1 || echo 0)"
            now=$(date +%s); mtime=$(stat -c %Y "${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt" 2>/dev/null || echo "$now")
            f_age="$(( (now - mtime) / 3600 ))h"
            echo "  china_ip_list  ${f_lines:-0} 行（age ${f_age}）"
        else
            echo "  china_ip_list  缺失"
        fi
    } | card
}

prompt_default() {
    local label="$1" default="$2" value=""
    value="$(ask_text "$label" "$default" || true)"
    [[ -n "$value" ]] && printf '%s\n' "$value" || printf '%s\n' "$default"
}

load_persisted_install_config() {
    [[ -f "${CONF_DIR}/dns.env" ]] || return 1
    BASE_DOMAIN="$(cfg_get DNS_BASE_DOMAIN)"
    [[ -z "$BASE_DOMAIN" ]] && BASE_DOMAIN="$(cfg_get DNS_WEB_DOMAIN)" && BASE_DOMAIN="${BASE_DOMAIN#console.}"
    BASE_DOMAIN="$(printf '%s' "$BASE_DOMAIN" | tr '[:upper:]' '[:lower:]')"
    PUBLIC_IP="$(cfg_get DNS_PUBLIC_IP)"
    GATEWAY_IP="$(cfg_get DNS_GATEWAY_IP)"
    MIHOMO_LISTEN_IPS="$(cfg_get DNS_MIHOMO_LISTEN_IPS)"
    CERT_MODE="$(cfg_get CERT_MODE)"; CERT_MODE="${CERT_MODE:-cloudflare}"
    CERT_MODE="$(normalize_cert_mode "$CERT_MODE" 2>/dev/null || printf '%s' "$CERT_MODE")"
    CERT_EMAIL="$(cfg_get CERT_EMAIL)"
    CACHE_SIZE="$(cfg_get DNS_CACHE_SIZE)"
    CHINA_ECS="$(cfg_get DNS_CHINA_ECS)"
    EGRESS_RESOLVER="$(cfg_get DNS_EGRESS_RESOLVER)"
    [[ -z "$EGRESS_RESOLVER" ]] && EGRESS_RESOLVER="$(cfg_get XRAY_RESOLVER)"
    derive_domains "$BASE_DOMAIN"
}

validate_install_config() {
    is_valid_domain "${BASE_DOMAIN:-}" || { err "Persisted base domain is invalid."; return 1; }
    is_valid_ipv4 "${PUBLIC_IP:-}" || { err "Persisted public IPv4 is invalid."; return 1; }
    is_valid_ipv4 "${GATEWAY_IP:-}" || { err "Persisted gateway IPv4 is invalid."; return 1; }
    CERT_MODE="$(normalize_cert_mode "$CERT_MODE" 2>/dev/null || true)"
    [[ "$CERT_MODE" == cloudflare || "$CERT_MODE" == http-01 || "$CERT_MODE" == debug ]] \
        || { err "Persisted CERT_MODE must be cloudflare, http-01, or debug."; return 1; }
    if [[ "$CERT_MODE" != debug ]]; then
        [[ "${CERT_EMAIL:-}" == *@* && "$CERT_EMAIL" != *[[:space:]]* ]] \
            || { err "Persisted CERT_EMAIL is invalid for the selected production certificate mode."; return 1; }
    fi
    [[ "$CACHE_SIZE" =~ ^[1-9][0-9]*$ ]] || { err "Persisted DNS_CACHE_SIZE is invalid."; return 1; }
    case "$CHINA_ECS" in
        off|none|disable|0) ;;
        *) is_valid_ipv4 "${CHINA_ECS%%/*}" || { err "Persisted DNS_CHINA_ECS is invalid."; return 1; } ;;
    esac
    validate_egress_resolver "$EGRESS_RESOLVER" >/dev/null \
        || { err "Persisted DNS_EGRESS_RESOLVER is invalid."; return 1; }
    [[ "$EGRESS_RESOLVER" != "$DNS_EGRESS_RESOLVER_DEFAULT" ]] \
        || { err "Persisted DNS_EGRESS_RESOLVER is still the non-functional placeholder."; return 1; }
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    export BASE_DOMAIN PUBLIC_IP GATEWAY_IP MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL \
        CACHE_SIZE CHINA_ECS EGRESS_RESOLVER
}

configure_install_tui() {
    [[ -t 0 ]] || { err "First install/configuration requires an attached TTY; shell environment injection is not supported."; return 1; }
    local choice detected value default_listen
    case "${CERT_MODE:-cloudflare}" in
        http-01)
            choice="$(ask_choice '证书模式 Certificate mode' \
                'http-01 — Let’s Encrypt exact service SANs (current)' \
                'cloudflare — Let’s Encrypt wildcard (recommended)' \
                'debug — self-signed test certificate' || true)" ;;
        debug)
            choice="$(ask_choice '证书模式 Certificate mode' \
                'debug — self-signed test certificate (current)' \
                'cloudflare — Let’s Encrypt wildcard (recommended)' \
                'http-01 — Let’s Encrypt exact service SANs' || true)" ;;
        *)
            choice="$(ask_choice '证书模式 Certificate mode' \
                'cloudflare — Let’s Encrypt wildcard (current/recommended)' \
                'http-01 — Let’s Encrypt exact service SANs' \
                'debug — self-signed test certificate' || true)" ;;
    esac
    [[ -n "$choice" ]] || { warn "Certificate mode selection cancelled."; return 1; }
    case "$choice" in
        debug*) CERT_MODE=debug ;;
        http-01*) CERT_MODE=http-01 ;;
        cloudflare*) CERT_MODE=cloudflare ;;
    esac

    while true; do
        value="$(prompt_default '主域名 Base domain' "${BASE_DOMAIN:-5gpn.local}")"
        value="${value#http://}"; value="${value#https://}"; value="${value%/}"; value="${value// /}"
        value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
        is_valid_domain "$value" && { derive_domains "$value"; break; }
        warn "Invalid domain; enter a full FQDN like example.com."
    done

    detected="${PUBLIC_IP:-}"
    if ! is_valid_ipv4 "$detected"; then
        PUBLIC_IP=""
        get_public_ip
        detected="$PUBLIC_IP"
    fi
    while true; do
        PUBLIC_IP="$(prompt_default '公网 IPv4 Public IPv4' "$detected")"
        is_valid_ipv4 "$PUBLIC_IP" && break
        warn "Invalid public IPv4."
    done
    while true; do
        GATEWAY_IP="$(prompt_default '客户端可达网关 IPv4 Gateway IPv4' "${GATEWAY_IP:-$PUBLIC_IP}")"
        is_valid_ipv4 "$GATEWAY_IP" && break
        warn "Invalid gateway IPv4."
    done

    while true; do
        EGRESS_RESOLVER="$(prompt_default 'SNI 回源解析器 (IPv4 或 https://…/dns-query)' "${EGRESS_RESOLVER:-https://1.1.1.1/dns-query}")"
        validate_egress_resolver "$EGRESS_RESOLVER" >/dev/null && break
        warn "Invalid resolver."
    done

    default_listen="$(resolve_mihomo_listen_ips "${MIHOMO_LISTEN_IPS:-}" 2>/dev/null || true)"
    [[ -n "$default_listen" ]] || default_listen="$(resolve_mihomo_listen_ips '' 2>/dev/null || true)"
    [[ -n "$default_listen" ]] \
        || { err "No locally assigned IPv4 is available for mihomo listeners."; return 1; }
    while true; do
        MIHOMO_LISTEN_IPS="$(prompt_default 'mihomo 本机监听 IPv4（逗号分隔）' "$default_listen")"
        MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" && break
    done

    while true; do
        CHINA_ECS="$(prompt_default '国内解析 ECS IPv4（或 off）' "${CHINA_ECS:-$CHINA_ECS_DEFAULT}")"
        case "$CHINA_ECS" in
            off|none|disable|0) break ;;
            *) is_valid_ipv4 "${CHINA_ECS%%/*}" && { CHINA_ECS="$(ecs_to_cidr24 "$CHINA_ECS")"; break; } ;;
        esac
        warn "Invalid ECS value."
    done

    CACHE_SIZE="$(prompt_default 'DNS cache entries' "${CACHE_SIZE:-${_CACHE_SIZE_DEFAULT:-4096}}")"
    [[ "$CACHE_SIZE" =~ ^[1-9][0-9]*$ ]] \
        || { err "DNS cache size must be a positive integer."; return 1; }
    if [[ "$CERT_MODE" != debug ]]; then
        CERT_EMAIL="$(prompt_default 'Let’s Encrypt email' "${CERT_EMAIL:-admin@${BASE_DOMAIN}}")"
        [[ "$CERT_EMAIL" == *@* && "$CERT_EMAIL" != *[[:space:]]* ]] \
            || { err "Invalid certificate email."; return 1; }
    else
        CERT_EMAIL=""
    fi

    {
        echo "安装配置 Install configuration"
        echo "  mode:       $CERT_MODE"
        echo "  base:       $BASE_DOMAIN"
        echo "  public:     $PUBLIC_IP"
        echo "  gateway:    $GATEWAY_IP"
        echo "  listeners:  $MIHOMO_LISTEN_IPS"
        echo "  resolver:   $EGRESS_RESOLVER"
        echo "  ECS:        $CHINA_ECS"
        echo "  cache:      $CACHE_SIZE"
    } | card
    if [[ "$CERT_MODE" == http-01 ]]; then
        {
            echo "HTTP-01 DNS / network prerequisites"
            echo "  ${CONSOLE_DOMAIN}  A -> ${PUBLIC_IP}"
            echo "  ${ZASH_DOMAIN}     A -> ${PUBLIC_IP}"
            echo "  ${DOT_DOMAIN}      A -> ${PUBLIC_IP}"
            echo "  AAAA: none for all three names (IPv4-only gateway)"
            echo "  TCP/80: publicly reachable through NAT/security-group rules"
            echo "The installer will wait for 1.1.1.1 to observe these records."
        } | card
        ask_yesno "我已确认上述 DNS 和 TCP/80 配置正确；保存并开始等待验证?" \
            || { warn "Configuration cancelled before the DNS check."; return 1; }
    elif [[ "$CERT_MODE" == cloudflare ]]; then
        {
            echo "Cloudflare DNS-01 prerequisites"
            echo "  ${CONSOLE_DOMAIN} A -> ${PUBLIC_IP}"
            [[ "$GATEWAY_IP" != "$PUBLIC_IP" ]] && echo "  or client-routable gateway A -> ${GATEWAY_IP}"
            echo "  Cloudflare token needs Zone:DNS:Edit for ${BASE_DOMAIN}."
            echo "The installer will wait for 1.1.1.1 to observe the console A record."
        } | card
        ask_yesno "我已确认上述 DNS 配置正确；保存并开始等待验证?" \
            || { warn "Configuration cancelled before the DNS check."; return 1; }
    else
        ask_yesno "保存以上 debug 配置并继续?" \
            || { warn "Configuration cancelled."; return 1; }
    fi
    export BASE_DOMAIN PUBLIC_IP GATEWAY_IP MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL \
        CACHE_SIZE CHINA_ECS EGRESS_RESOLVER
}

resolve_install_configuration() {
    local force_tui="${1:-0}"
    if [[ "$force_tui" != 1 ]] && load_persisted_install_config && validate_install_config; then
        info "Using validated persisted configuration from ${CONF_DIR}/dns.env (caller environment ignored)."
        return 0
    fi
    [[ -f "${CONF_DIR}/dns.env" ]] && load_persisted_install_config || true
    configure_install_tui
    validate_install_config
}

MIHOMO_RESET_APPROVED=0
mihomo_config_matches_install_config() {
    local config="$MIHOMO_DIR/config.yaml" ip
    [[ -f "$config" ]] || return 0
    grep -Fq -- "$CONSOLE_DOMAIN" "$config" || return 1
    grep -Eq "^[[:space:]]*-[[:space:]]*DOMAIN,[[:space:]]*${CONSOLE_DOMAIN//./\\.},[[:space:]]*DIRECT[[:space:]]*$" "$config" || return 1
    ! grep -Eq "DOMAIN,[[:space:]]*${CONSOLE_DOMAIN//./\\.},[[:space:]]*REJECT-DROP" "$config" || return 1
    ! grep -Eq "AND,.*DOMAIN,[[:space:]]*${CONSOLE_DOMAIN//./\\.}.*RULE-SET,[[:space:]]*whitelist" "$config" || return 1
    ! grep -Fq -- "profile.${BASE_DOMAIN}" "$config" || return 1
    grep -Fq -- "$ZASH_DOMAIN" "$config" || return 1
    grep -Fq -- "${GATEWAY_IP}/32" "$config" || return 1
    while IFS= read -r ip; do
        grep -Eq "listen:[[:space:]]*${ip//./\\.}([,}[:space:]]|$)" "$config" || return 1
    done < <(printf '%s\n' "$MIHOMO_LISTEN_IPS" | tr ',' '\n')
}

approve_mihomo_reset_if_needed() {
    MIHOMO_RESET_APPROVED=0
    mihomo_config_matches_install_config && return 0
    warn "The operator-owned mihomo config does not contain the selected domains, gateway, and listener addresses."
    [[ -t 0 ]] || { err "Run the TUI and explicitly approve a validated mihomo reset, or edit the config first."; return 1; }
    if ask_yesno "显式备份并重置 mihomo 配置以匹配新的 TUI 配置?"; then
        MIHOMO_RESET_APPROVED=1
        return 0
    fi
    err "Configuration was not changed. Update mihomo manually or approve reset."
    return 1
}

# ----------------------------------------------------------------------------
# Full install
# ----------------------------------------------------------------------------
full_install() {
    local force_tui=0 token_was_present=0
    [[ "${1:-}" == configure ]] && force_tui=1
    check_root
    claim_project_roots
    install_gum
    detect_os
    check_arch
    detect_memory_profile
    resolve_install_configuration "$force_tui"
    derive_domains "$BASE_DOMAIN"
    EGRESS_RESOLVER="${EGRESS_RESOLVER:?validated resolver missing}"
    XRAY_RESOLVER="$EGRESS_RESOLVER" # persisted compatibility alias only
    export XRAY_RESOLVER
    approve_mihomo_reset_if_needed
    preflight_unit_ownership
    claim_web_dir
    claim_zashboard_dir
    [[ -n "$(cfg_get DNS_API_TOKEN)" ]] && token_was_present=1

    # Package installation may add shared OS packages, but no live 5gpn file has
    # been removed or replaced yet. Debug mode deliberately skips Certbot.
    install_deps
    trap cleanup_artifact_stage EXIT
    verify_console_dns
    stage_artifacts
    acquire_install_cert_lock
    capture_install_rollback
    trap install_transaction_error ERR
    trap install_transaction_exit EXIT
    ensure_swap

    # Only after every input, host conflict, download, digest, archive, console
    # DNS gate, and existing mihomo config has passed do we enter publication.
    clean_previous_install
    remove_legacy_policy_state
    install_5gpndns
    install_mihomo
    install_files
    install_manage_cli
    install_web
    install_zashboard
    install_units
    write_dns_env
    install_cert "$BASE_DOMAIN"
    if [[ "$MIHOMO_RESET_APPROVED" == 1 ]]; then
        render_mihomo_config --reset
    else
        render_mihomo_config
    fi
    system_tuning
    setup_ios_profile
    start_services
    verify_console_endpoint
    remove_legacy_firewall
    run_update_lists
    INSTALL_TRANSACTION_ACTIVE=0
    release_install_cert_lock
    cleanup_artifact_stage
    trap - ERR EXIT

    echo ""
    ok "5gpn install complete."
    {
        echo "✅ 5gpn 安装完成"
        echo ""
        echo "  DoT 地址         tls://${DOT_DOMAIN}:853"
        echo "  Android 私人DNS  ${DOT_DOMAIN}"
        echo "  iOS 描述文件      https://${CONSOLE_DOMAIN}/ios/ios-dot.mobileconfig"
        echo "  Public console   ${CONSOLE_DOMAIN} A -> ${PUBLIC_IP}（NPN 可用客户端可路由 ${GATEWAY_IP}）"
    } | card
    {
        echo "Web 控制台: https://${CONSOLE_DOMAIN}/"
        echo "zashboard:  https://${ZASH_DOMAIN}/"
        echo "iOS 安装:   https://${CONSOLE_DOMAIN}/ios/"
        [[ "$token_was_present" == 0 && -t 1 ]] && echo "Token:      ${DNS_API_TOKEN}"
        echo "(console 公网开放，/api 需要 bearer token；zashboard 仅对白名单来源 IP 开放)"
    } | card
    print_qr
    echo ""
    ok "管理入口：直接输入  5gpn  打开管理菜单（状态 / 重启 / 改域名 / 改公网IP / 卸载 …）。"
    info "Optional: '5gpn --setup-tgbot' (or '$0 --setup-tgbot') to set up the Telegram control bot."
}

# ----------------------------------------------------------------------------
# Usage / dispatch
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Uninstall: reverse install.sh's invasive host changes. Keeps /etc/5gpn (cert,
# token, rules, subscriptions) by default; --purge removes it EXCEPT the cert dir.
# TLS material is DELIBERATELY preserved in every mode — re-issuing a Let's Encrypt
# cert for the same domain is rate-limited, so the deployed copy (/etc/5gpn/cert)
# AND the certbot lineage (/etc/letsencrypt, never touched here) survive so a
# re-install reuses the cert instead of burning a new issuance. Remove certs
# manually only when decommissioning the domain.
# ----------------------------------------------------------------------------
uninstall() {
    check_root
    local purge=0 decommission=0 legacy_dns=0 legacy_mihomo=0 base=""
    case "${1:-}" in
        '') ;;
        --purge) purge=1 ;;
        --decommission) purge=1; decommission=1 ;;
        *) err "Unknown uninstall mode: ${1:-}"; return 1 ;;
    esac
    [[ -t 0 ]] || { err "Uninstall requires an attached TTY confirmation."; return 1; }
    local prompt="确认卸载 5gpn?"
    [[ "$decommission" == 1 ]] && prompt="确认卸载并永久删除 5gpn 证书及 Cloudflare 凭据?"
    ask_yesno "$prompt" || return 0
    claim_project_roots
    acquire_install_cert_lock
    if [[ "$decommission" == 1 ]]; then
        base="$(cfg_get DNS_BASE_DOMAIN)"
        if ! is_valid_domain "$base"; then
            release_install_cert_lock
            err "Cannot decommission: persisted base domain is invalid."
            return 1
        fi
        if [[ -e "/etc/letsencrypt/live/$base" || -e "/etc/letsencrypt/archive/$base" \
           || -e "/etc/letsencrypt/renewal/$base.conf" ]]; then
            if ! decommission_lineage_safe "$base"; then
                release_install_cert_lock
                err "Refusing to delete an unscoped, partial, or non-5gpn Certbot lineage for '$base'."
                return 1
            fi
            if ! certbot delete --non-interactive --cert-name "$base"; then
                release_install_cert_lock
                err "Certbot refused to delete the exact 5gpn lineage '$base'."
                return 1
            fi
        fi
    fi
    warn "Uninstalling 5gpn: stopping services and reverting host changes."

    unit_file_owned_by_5gpn 5gpn-dns.service \
        && grep -qF 'ExecStart=/usr/local/bin/5gpn-dns' /etc/systemd/system/5gpn-dns.service \
        && legacy_dns=1
    unit_file_owned_by_5gpn mihomo.service \
        && grep -qF 'ExecStart=/usr/local/bin/mihomo' /etc/systemd/system/mihomo.service \
        && legacy_mihomo=1
    local unit
    for unit in 5gpn-dns.service mihomo.service 5gpn-certbot-renew.timer \
                5gpn-certbot-renew.service 5gpn-api.service 5gpn-tgbot.service \
                5gpn-iosprofile.socket '5gpn-iosprofile@.service'; do
        remove_owned_unit "$unit"
    done
    remove_legacy_xray
    remove_legacy_generic_unit smartdns.service
    remove_legacy_generic_unit sniproxy.service
    remove_legacy_singbox
    systemctl daemon-reload 2>/dev/null || true

    # letsencrypt hooks we installed (current + legacy nft-era names).
    remove_owned_renew_hook
    rm -f /etc/letsencrypt/renewal-hooks/pre/10-5gpn-stop-xray.sh \
          /etc/letsencrypt/renewal-hooks/post/10-5gpn-start-xray.sh \
          /etc/letsencrypt/renewal-hooks/pre/10-5gpn-open80.sh \
          /etc/letsencrypt/renewal-hooks/post/10-5gpn-close80.sh

    # Remove only old project-named tuning files. Do not run global sysctl reload.
    rm -f /etc/sysctl.d/99-5gpn.conf /etc/modules-load.d/5gpn.conf /etc/modprobe.d/5gpn.conf

    # Precise legacy cleanup only; never touch unrelated host firewall state.
    remove_legacy_firewall

    # Remove only the project-private swapfile under a marked state directory.
    if verify_ownership_marker "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" \
       && [[ -f "$SWAP_FILE" && ! -L "$SWAP_FILE" ]]; then
        swapoff "$SWAP_FILE" 2>/dev/null || true
        rm -f -- "$SWAP_FILE"
        sed -i "\|^${SWAP_FILE} none swap sw 0 0 ${SWAP_FSTAB_MARKER}$|d" /etc/fstab 2>/dev/null || true
        ok "Removed 5gpn-owned swapfile."
    fi

    if [[ "$legacy_dns" == 1 ]]; then rm -f -- /usr/local/bin/5gpn-dns; fi
    if [[ "$legacy_mihomo" == 1 ]]; then rm -f -- /usr/local/bin/mihomo; fi
    if launcher_owned; then
        rm -f -- /usr/local/bin/5gpn
    elif [[ -e /usr/local/bin/5gpn ]]; then
        warn "Preserving unowned /usr/local/bin/5gpn."
    fi
    if [[ "$DNS_WEB_DIR" != "$BASE_DIR"/* && -e "$DNS_WEB_DIR" ]]; then
        if [[ "$(safe_web_path 2>/dev/null || true)" == "$DNS_WEB_DIR" ]] \
           && verify_ownership_marker "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"; then
            rm -rf -- "$DNS_WEB_DIR"
        else
            warn "Kept unowned/unsafe DNS_WEB_DIR '$DNS_WEB_DIR'."
        fi
    fi
    if [[ "$DNS_ZASH_DIR" != "$BASE_DIR"/* ]]; then
        remove_zashboard_dir || warn "Kept unowned/unsafe DNS_ZASH_DIR '$DNS_ZASH_DIR'."
    fi
    remove_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"
    if [[ -d /opt/5gpn-src ]] \
       && verify_ownership_marker /opt/5gpn-src .5gpn-quick-install-owned 5gpn-quick-install-v1; then
        rm -rf -- /opt/5gpn-src
    fi
    remove_fixed_owned_dir "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE"

    if [[ "$decommission" == 1 ]]; then
        rm -rf -- "$DNS_CERT_DIR" "$DEBUG_CERT_DIR" "$ACME_DIR"
        ok "Deleted exact 5gpn certificate material and Cloudflare credential."
    fi

    if [[ $purge == 1 ]]; then
        # DELIBERATELY preserve the cert dir even on --purge: re-issuing a Let's
        # Encrypt cert for the same domain is rate-limited, so the deployed copy
        # (/etc/5gpn/cert) AND the certbot lineage (/etc/letsencrypt, never removed
        # here) must survive so a later re-install reuses the cert instead of
        # burning a fresh issuance. The acme/ dir (Cloudflare API token) is ALSO
        # preserved: install_cert's valid-lineage reuse path never touches certbot,
        # but a re-install that DOES
        # need to issue (no valid cert survived) must not hard-abort for a token
        # that was needlessly wiped. Remove everything else under CONF_DIR.
        verify_ownership_marker "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
            || { err "Config ownership marker missing; refusing purge."; return 1; }
        find "$CONF_DIR" -mindepth 1 -maxdepth 1 ! -name "$CONF_OWNERSHIP_MARKER" \
            ! -name cert ! -name acme ! -name debug-cert -exec rm -rf -- {} +
        if [[ "$decommission" == 1 ]]; then
            remove_fixed_owned_dir "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"
            ok "Decommissioned all 5gpn configuration and certificate credentials."
        else
            warn "Purged ${CONF_DIR} EXCEPT cert/, debug-cert/, and acme/ for safe certificate reuse."
            info "Use the explicit TUI-confirmed '--uninstall --decommission' mode to remove the exact lineage and Cloudflare token."
        fi
    else
        ok "Kept ${CONF_DIR} (cert, acme token, DNS_API_TOKEN, rules, subscriptions). '--purge' removes it EXCEPT cert/ and acme/ (always kept for reuse)."
    fi
    release_install_cert_lock
    ok "5gpn uninstalled."
}

usage() {
    cat <<EOF
5gpn installer (exit-less DoT gateway; DoT is the ONLY DNS transport)
Usage: sudo bash install.sh [option]     — or, after install, just:  5gpn [option]

  (no args)           Full install/re-run. First install requires the TUI;
                      reinstall validates and reuses /etc/5gpn/dns.env.
  --configure         Open the full TUI, stage/verify, publish, probe, and rollback on failure
  --menu              Open the interactive management menu (this is what bare '5gpn' runs)
  --status            Show service states, domains, IP, list counts/age
  --restart           Restart the 5gpn services (5gpn-dns + mihomo)
  --change-base-domain  Deprecated compatibility entry for --configure; value arguments are rejected
  --change-web-domain   Deprecated compatibility entry for --configure
  --change-dot-domain   Deprecated compatibility entry for --configure
  --change-public-ip    Deprecated compatibility entry for --configure
  --change-gateway      Deprecated compatibility entry for --configure
  --change-resolver     Deprecated compatibility entry for --configure
  --update-lists      Reload 5gpn-dns rule caches (subscriptions fetch in-process)
  --add-domain <d>    Force-proxy a domain (adds to rules/blacklist.txt)
  --del-domain <d>    Remove a domain from the forced-proxy list
  --add-allow <cidr>  Add a source IP/CIDR to the zashboard allowlist + live refresh
  --del-allow <cidr>  Remove a source IP/CIDR from the zashboard allowlist + live refresh
  --ios               Regenerate the iOS profile + QR
  --setup-tgbot       Validate + hot-apply Telegram config through the local API
  --rotate-token      Generate a new control-console DNS_API_TOKEN + restart
  --set-cf-token      Enter/update the Cloudflare token through the TUI only
  mihomo-reset        Explicitly back up + replace the operator mihomo config
                      with a freshly rendered, validated seed, then restart
  --uninstall [--purge|--decommission]
                      TUI-confirmed ownership-safe removal. Purge preserves cert/
                      debug-cert/acme; decommission deletes only the exact 5gpn lineage
  --help              This help

After a full install, `5gpn` opens the management TUI. Configuration commands do
not accept values on argv or through the caller environment.

Config: /etc/5gpn/dns.env is the persistent source of truth. First install writes
it from the TUI; reinstall reads it. Ambient shell variables are discarded.

Domains + certificates: ONE base domain and ONE scoped Let's Encrypt lineage.
  BASE_DOMAIN (e.g. example.com)     the operator's single domain knob. Three
                                     service domains are auto-derived:
                                       console.<base>  web console (mihomo :443 SNI
                                                       split -> daemon loopback :443)
                                       zash.<base>     zashboard panel
                                       dot.<base>      DoT :853 (Private DNS / iOS)
                                     Values are collected by the TUI.
  cloudflare mode (default)          apex + WILDCARD *.<base> cert via Let's
                     Encrypt DNS-01 through the Cloudflare API (no :80, no public
                     A-record needed for certificate issuance); auto-renews unattended
                     via the daily 5gpn-certbot-renew.timer. A protected Cloudflare
                     API token is required even when reusing a valid cert so future
                     renewal remains unattended; missing credentials prompt in the TUI. The token
                     is stored in /etc/5gpn/acme/cloudflare.ini
                     (dir 0700, file 0600) and is NEVER written to dns.env or logs.
                     Use '5gpn --set-cf-token' (or the menu) to update it at any time.
  http-01 mode       exact console/zash/dot SAN certificate via public TCP :80.
                     After explicit TUI confirmation, all three A records must
                     resolve through 1.1.1.1 to DNS_PUBLIC_IP with no AAAA.
                     Issuance and due renewal briefly stop and restore mihomo;
                     automatic renewal uses the same scoped helper as the bot.
  debug mode         self-signed WILDCARD cert for a test/dev box with
                     no public domain — no certbot, no DNS-01, no renewal; clients
                     see it untrusted.
  Production reuse validates mode-specific SANs, renewal authenticator,
  provenance, trust, expiry, and cert/key matching;
  debug certificates are reusable only inside debug mode.

There is NO host firewall management (removed): use your provider's security
group if you need one. The console SPA and /ios/ are public while /api/* requires
the bearer token. Zashboard remains limited to source IPs in mihomo's
whitelist.txt allowlist.

  TUI configuration:
    certificate mode/email, base domain, public/gateway/listener IPv4,
    poison-resistant egress resolver, China ECS, cache size, Cloudflare token,
    Telegram identity/admins/proxy/alerts, and explicit mihomo reset approval.

  Fixed release inputs:
    DNS/mihomo/zashboard/Gum versions and SHA-256 values are embedded in the
    release installer. Unsigned profiles and profile-DNS bypasses do not exist.
EOF
}

# Keep the Telegram workflow in one stable source-only helper. A late function
# definition wins over older inline implementations retained temporarily for
# upgrade archaeology and ensures --setup-tgbot always uses the validated live
# API path without restarting 5gpn-dns.
setup_tgbot() {
    [[ -t 0 ]] || { err "Telegram configuration requires the TUI."; return 1; }
    unset TGBOT_TOKEN TGBOT_ADMINS DNS_TGBOT_FILE TGBOT_PROXY_URL TGBOT_ALERTS
    local helper="${SCRIPT_DIR}/scripts/setup-tgbot.sh"
    [[ -r "$helper" ]] || helper="${SCRIPTS_DIR}/setup-tgbot.sh"
    [[ -r "$helper" ]] || { err "Telegram setup helper not found: scripts/setup-tgbot.sh"; return 1; }
    # shellcheck source=scripts/setup-tgbot.sh
    source "$helper"
    setup_tgbot_live "$@"
}

main() {
    # Piped install (curl | sudo bash): reattach stdin to the terminal so the
    # prompts below fire. No-op when stdin is already a tty; truly headless first
    # install/configuration fails closed instead of consuming caller environment.
    attach_tty
    clear_external_config_env
    local cmd="${1:-}"
    case "$cmd" in
        ""|install)     full_install ;;
        --configure|configure) full_install configure ;;
        --menu|menu)    manage_menu ;;
        --restart|restart)            restart_services ;;
        --change-base-domain|change-base-domain) change_base_domain "${2:-}" ;;
        # Back-compat aliases (single base-domain model): the old web/base domain
        # command maps straight through; the old DoT-domain command strips a
        # leading 'dot.' to recover the base; --change-domain is the legacy
        # single-domain alias.
        --change-web-domain|change-web-domain)
            warn "'$1' is deprecated; use '5gpn configure'."
            change_base_domain "${2:-}" ;;
        --change-domain|change-domain)
            warn "'$1' is deprecated; use '5gpn configure'."
            change_base_domain "${2:-}" ;;
        --change-dot-domain|change-dot-domain)
            warn "'$1' is deprecated; use '5gpn configure'."
            change_base_domain "${2:-}" ;;
        --change-public-ip|change-public-ip) change_public_ip "${2:-}" ;;
        --change-gateway|change-gateway) change_gateway "${2:-}" ;;
        --change-resolver|change-resolver) change_resolver "${2:-}" ;;
        --update-lists) do_update_lists ;;
        --status)       show_status ;;
        --add-domain)   add_domain "${2:-}" ;;
        --del-domain)   del_domain "${2:-}" ;;
        --add-allow)    add_allow_ip "${2:-}" ;;
        --del-allow)    del_allow_ip "${2:-}" ;;
        --ios)          regen_ios ;;
        --setup-tgbot)  setup_tgbot ;;
        --rotate-token) rotate_token ;;
        --set-cf-token) set_cf_token "${2:-}" ;;
        --mihomo-reset|mihomo-reset) reset_mihomo_config ;;
        --uninstall)    uninstall "${2:-}" ;;
        --help|-h)      usage ;;
        *)              err "Unknown option: $cmd"; echo ""; usage; exit 2 ;;
    esac
}

if [[ "${INSTALL_SH_LIB_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
