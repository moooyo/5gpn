#!/usr/bin/env bash
# 5gpn installer / orchestrator (DNS-steering architecture).
#
#   client DoT:853 (the ONLY DNS transport) -> 5gpn-dns (NXDOMAIN for block,
#   real IP for direct, gateway IP for proxy/foreign) -> mihomo
#   (:80/:443/:5060/:8080/:8443) sniffs HTTP Host or TLS SNI
#   (sniffer override-destination), then the loopback DNS broker resolves the
#   real IP through an extension's operator-selected China/trust group (trust by
#   default) before mihomo applies its operator-owned policy.
#   mihomo also SNI-splits the panels
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
# QUIC/HTTP3 is proxied by mihomo (UDP 443 sniff-forward). There is no
# daemon-managed exit layer or Go data plane. 5gpn never manages the host firewall; use your provider's
# security group if you want one. The
# console is public with bearer-protected APIs; zashboard remains reachable
# only from source IPs on the mihomo whitelist.txt allowlist.
#
# There is NO network-layer exit: no WireGuard, no fwmark / ip-rule / table-100.
# Do not add any of those (application-layer exits live in mihomo's rule engine).
#
# Every run stages and validates pinned artifacts before atomically publishing
# them. Persisted operator state and a valid operator-owned mihomo config are
# preserved; failed publication rolls back to the runnable snapshot.
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Paths & constants
# ----------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || echo "${BASH_SOURCE[0]:-}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"   # repo 5gpn/ when run from a checkout

BASE_DIR="/opt/5gpn"                 # installed runtime root
BIN_DIR="${BASE_DIR}/bin"                # project-managed binaries; Gum survives uninstall for host reuse
SCRIPTS_DIR="${BASE_DIR}/scripts"        # installed copies of repo scripts
WWW_DIR="${BASE_DIR}/www"                # signed iOS profile root (served in-process by 5gpn-dns)
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
INTERCEPT_BIN="${BIN_DIR}/5gpn-intercept" # allowlisted TLS/HTTP3 interception sidecar
DNS_CERT_DIR="/etc/5gpn/cert"            # selected cert copied into dot/, web/, zash/ roles
DEBUG_CERT_DIR="/etc/5gpn/debug-cert"     # self-signed debug certs; NEVER under /etc/letsencrypt
DEBUG_CERT_MARKER=".5gpn-debug-cert-owned"
DEBUG_CERT_MARKER_VALUE="5gpn-debug-cert-v1"
DOT_CERT_DIR="${DNS_CERT_DIR}/dot"       # DoT :853 cert copy (hot-reloaded on mtime change)
WEB_CERT_DIR="${DNS_CERT_DIR}/web"       # loopback HTTPS console :443 cert copy
ZASH_CERT_DIR="${DNS_CERT_DIR}/zash"     # zashboard panel cert copy
CERT_ROOT_MARKER=".5gpn-cert-root-owned"
CERT_ROOT_MARKER_VALUE="5gpn-cert-root-v1"
CERTBOT_OWNERSHIP_FILE="${DNS_CERT_DIR}/.certbot-ownership"
CERT_ROLE_MARKER=".5gpn-cert-role-owned"
CERT_ROLE_VALUE_PREFIX="5gpn-cert-role-v1"
ACME_DIR="/etc/5gpn/acme"                # root-only Cloudflare API-token credentials dir
GLOBAL_CERTBOT_TIMER_STATE="${ACME_DIR}/certbot.timer.state"
LE_ROOT="/etc/letsencrypt"
LE_LIVE_ROOT="${LE_ROOT}/live"
LE_ARCHIVE_ROOT="${LE_ROOT}/archive"
LE_RENEWAL_ROOT="${LE_ROOT}/renewal"
CERT_DNS_RESOLVER="1.1.1.1"              # fixed independent resolver for ACME A/AAAA gates
CERT_DNS_WAIT_TIMEOUT=600                 # bounded install/configure propagation wait
CERT_DNS_WAIT_INTERVAL=10
INSTALL_LOCK_FILE="/run/5gpn/install.lock"
CERT_RENEW_LOCK_FILE="/run/5gpn/cert-renew.lock"
INSTALL_LOCK_WAIT_TIMEOUT=900
CERT_LOCK_WAIT_TIMEOUT=30
LOCK_WAIT_REPORT_INTERVAL=5
LE_PRODUCTION_SERVER="https://acme-v02.api.letsencrypt.org/directory"
INSTALL_LOCK_HELD=0
INSTALL_CERT_LOCK_HELD=0
# The transaction layer restores the pre-install distro certbot.timer state on
# rollback and after non-owning certificate flows. Owned 5gpn lineages set this
# flag so the unscoped distro timer stays disabled after commit.
KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=0
RELEASE_PERSISTED_GLOBAL_CERTBOT_TIMER=0
DECOMMISSION_PRESERVE_ACME=0
INTERCEPT_ROUTING_READY=0
INTERCEPT_ROUTING_REASON="not-checked"
CREATED_SERVICE_ACCOUNT_USERS=()
CREATED_SERVICE_ACCOUNT_GROUPS=()
CREATED_SERVICE_ACCOUNT_UIDS=()
CREATED_SERVICE_ACCOUNT_GIDS=()
CREATED_SERVICE_ACCOUNT_USER_FLAGS=()
CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=()
DNS_WEB_DIR_DEFAULT="/opt/5gpn/web"         # resolved from dns.env after cfg_get is defined
# DNS_ZASH_DIR (zashboard SPA dist, config.go's ZashDir) is resolved just below
# cfg_get()'s definition -- NOT here: the daemon reads DNS_ZASH_DIR out of dns.env,
# so it must honor a dns.env value (cfg_get > default) and survive a bare
# re-install, and cfg_get isn't defined yet at this point in the file.
DNS_RULES_DIR_DEFAULT="/etc/5gpn/rules"  # subscription caches and chnroute snapshot
MIHOMO_BIN="${BIN_DIR}/mihomo"
MIHOMO_DIR="/etc/5gpn/mihomo"           # config.yaml + whitelist.txt + provider caches
INTERCEPT_DIR="/etc/5gpn/intercept"
INTERCEPT_CA_DIR="/etc/5gpn/intercept-ca"
INTERCEPT_CA_MARKER=".5gpn-intercept-ca-owned"
INTERCEPT_CA_MARKER_VALUE="5gpn-intercept-ca-v1"
INTERCEPT_STATE_DIR="/var/lib/5gpn-intercept"
INTERCEPT_STATE_MARKER=".5gpn-intercept-state-owned"
INTERCEPT_STATE_MARKER_VALUE="5gpn-intercept-state-v1"
DNS_SERVICE_USER="gpn-dns"
MIHOMO_SERVICE_USER="mihomo"
INTERCEPT_SERVICE_USER="gpn-intercept"
POLKIT_RULE_PATH="/etc/polkit-1/rules.d/50-5gpn.rules"
POLKIT_RULE_MARKER="// 5gpn-polkit-id: runtime-operations-v1"
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
DNS_CHINA_DEFAULT="223.5.5.5"
DNS_TRUST_DEFAULT="22.22.22.22"
DNS_CHINA_ECS_DEFAULT="112.96.32.0/24"
readonly DNS_ENV_KEYS="DNS_LISTEN_DOT DNS_LISTEN_DEBUG DNS_LISTEN_API DNS_CERT DNS_KEY DNS_WEB_CERT DNS_WEB_KEY DNS_ZASH_CERT DNS_ZASH_KEY \
DNS_BASE_DOMAIN DNS_PUBLIC_IP DNS_GATEWAY_IP DNS_MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL DNS_CHINA DNS_TRUST DNS_UPSTREAMS \
DNS_CHINA_ECS DNS_CHINA_0X20 DNS_ECS_FILE DNS_RULES_DIR DNS_CHNROUTE DNS_EGRESS_BROKER \
DNS_SUBSCRIPTIONS DNS_POLICY_RULES DNS_API_TOKEN DNS_API_RATE DNS_API_BURST DNS_MIHOMO_CONTROLLER DNS_MIHOMO_SECRET \
DNS_WHITELIST_FILE DNS_MIHOMO_CONFIG DNS_INTERCEPT_CONFIG DNS_MARKETPLACES_FILE DNS_ZASH_DIR DNS_ZASH_LISTEN DNS_WEB_DIR WWW_DIR TGBOT_TOKEN TGBOT_ADMINS \
DNS_TGBOT_FILE TGBOT_PROXY_URL TGBOT_ALERTS DNS_CACHE_SIZE DNS_MAX_INFLIGHT DNS_TTL_MIN DNS_TTL_MAX DNS_QUERY_TIMEOUT \
DNS_STATS_FILE DNS_HEARTBEAT_URL DNS_HEARTBEAT_INTERVAL"
# EDNS Client Subnet uses the operational default above. Operators can disable
# or change it through the web console, which persists the runtime value.
GUM_VERSION="0.17.0"                     # charmbracelet/gum (prebuilt; installer TUI)
GUM_SHA256_X86_64="69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb"
GUM_SHA256_ARM64="b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c"
GUM_SHA256_ARMV7="25711c2fbc6887cde79ed586972834121a04955968808dd688c688381ac50ab2"
GUM_BIN="${BIN_DIR}/gum"
_HAVE_GUM=0                              # set by install_gum(); helpers fall back to echo when 0
export PATH="${BIN_DIR}:${PATH}"

# 5gpn-dns binary + web SPA release selector on moooyo/5gpn. The source-tree
# sentinel delegates to quick-install so the selected channel is resolved once
# and every installer input comes from the same exact release bundle.
# The release pipeline STAMPS this exact line to the tag being cut (see
# .github/workflows/release.yml), so a packaged installer always pulls its OWN
# release's artifacts and never mixes release binaries with another tag's files.
DNS_VERSION_DEFAULT="latest"
DNS_RELEASE_CHANNEL="stable"
DNS_RELEASE_CHANNEL_EXPLICIT=0
DNS_STABLE_RELEASE_API="https://api.github.com/repos/moooyo/5gpn/releases/latest"
DNS_RELEASES_API="https://api.github.com/repos/moooyo/5gpn/releases"
SERVICE_READY_TIMEOUT=20
INTERCEPT_HEALTHCHECK_MAX_TIMEOUT=10

# ----------------------------------------------------------------------------
# Pretty output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
info() {
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        gum log --level info -- "$*" || echo "${BLUE}[INFO]${NC} $*"
    else
        echo "${BLUE}[INFO]${NC} $*"
    fi
}
ok() {
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        gum log --level info -- "✔ $*" || echo "${GREEN}[OK]${NC}   $*"
    else
        echo "${GREEN}[OK]${NC}   $*"
    fi
}
warn() {
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        gum log --level warn -- "$*" || echo "${YELLOW}[WARN]${NC} $*"
    else
        echo "${YELLOW}[WARN]${NC} $*"
    fi
}
err() {
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        gum log --level error -- "$*" >&2 || echo "${RED}[ERR]${NC}  $*" >&2
    else
        echo "${RED}[ERR]${NC}  $*" >&2
    fi
}

# Interactive helpers (gum vs read). Callers gate on [[ -t 0 ]]; main() runs
# attach_tty first, so a piped `curl | sudo bash` install still has a terminal on
# stdin and these prompts fire as intended.
ask_text()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum input --prompt "$1 " --placeholder "${2:-}"; else local v; read -r -p "$1 " v; printf '%s' "$v"; fi; }
ask_secret() {
    if [[ "$_HAVE_GUM" == 1 ]]; then
        gum input --password --prompt "$1 "
    else
        local v
        read -r -s -p "$1 " v
        printf '\n' >&2
        printf '%s' "$v"
    fi
}
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
# is skipped — BASE_DOMAIN/GATEWAY_IP stay unset and the run aborts on the
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
file_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
file_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
file_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
file_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }

persisted_dns_env_is_safe() {
    local env="${CONF_DIR}/dns.env" marker="${CONF_DIR}/${CONF_OWNERSHIP_MARKER}"
    local canonical expected_gid conf_mode conf_gid
    [[ -d "$CONF_DIR" && ! -L "$CONF_DIR" ]] || return 1
    canonical="$(readlink -f -- "$CONF_DIR" 2>/dev/null || true)"
    [[ "$canonical" == "$CONF_DIR" && "$(file_uid "$CONF_DIR")" == 0 ]] || return 1
    expected_gid="$(getent group "$DNS_SERVICE_USER" 2>/dev/null | awk -F: 'NR == 1 { print $3 }')"
    [[ -n "$expected_gid" ]] || return 1
    conf_mode="$(file_mode "$CONF_DIR")"
    conf_gid="$(file_gid "$CONF_DIR")"
    case "$conf_mode:$conf_gid" in
        755:0|2771:"$expected_gid"|3771:"$expected_gid") ;;
        *) return 1 ;;
    esac
    [[ -f "$marker" && ! -L "$marker" \
       && "$(file_uid "$marker")" == 0 \
       && "$(file_gid "$marker")" == 0 \
       && "$(file_mode "$marker")" == 644 \
       && "$(file_nlink "$marker")" == 1 \
       && "$(cat "$marker" 2>/dev/null || true)" == "$CONF_OWNERSHIP_VALUE" ]] \
        || return 1
    [[ -f "$env" && ! -L "$env" \
       && "$(file_uid "$env")" == 0 \
       && "$(file_gid "$env")" == "$expected_gid" \
       && "$(file_mode "$env")" == 640 \
       && "$(file_nlink "$env")" == 1 ]]
}

dns_env_encode_value() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

dns_env_decode_value() {
    local raw="$1" body out="" char next i
    if [[ "$raw" != \"* ]]; then
        printf '%s' "$raw"
        return 0
    fi
    [[ ${#raw} -ge 2 && "$raw" == *\" ]] || return 1
    body="${raw:1:${#raw}-2}"
    for ((i = 0; i < ${#body}; i++)); do
        char="${body:i:1}"
        if [[ "$char" == \\ ]]; then
            ((i += 1))
            (( i < ${#body} )) || return 1
            next="${body:i:1}"
            case "$next" in
                '"'|'\'|'$'|'`') out+="$next" ;;
                *) out+="\\$next" ;;
            esac
        else
            [[ "$char" != '"' ]] || return 1
            out+="$char"
        fi
    done
    printf '%s' "$out"
}

cfg_get() {
    local env="${CONF_DIR}/dns.env" raw
    [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    [[ ! -e "$env" && ! -L "$env" ]] && return 0
    persisted_dns_env_is_safe \
        || { err "Refusing unsafe persisted configuration: $env"; return 1; }
    # `|| true` keeps cfg_get exit 0 even when the key is absent: under
    # `set -euo pipefail` a grep no-match (pipeline rc=1) inside a bare
    # `VAR="$(cfg_get X)"` assignment would otherwise abort the whole install.
    raw="$(grep -E "^${1}=" "$env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [[ "$1" == DNS_MIHOMO_SECRET ]]; then
        dns_env_decode_value "$raw"
    else
        printf '%s' "$raw"
    fi
}

# Caller configuration is discarded before command dispatch. systemd still
# reads the persisted dns.env when it launches the daemon.
clear_external_config_env() {
    local key
    unset BASE_DOMAIN CONSOLE_DOMAIN ZASH_DOMAIN DOT_DOMAIN PUBLIC_IP GATEWAY_IP \
        MIHOMO_LISTEN_IPS CHINA_ECS CACHE_SIZE LOWMEM
    for key in $DNS_ENV_KEYS; do
        # The web/zashboard paths were already resolved from dns.env immediately
        # after cfg_get was defined. WWW_DIR is an installer-owned constant that
        # was assigned above, not caller configuration. Preserve all three while
        # clearing every externally supplied daemon key.
        [[ "$key" == DNS_WEB_DIR || "$key" == DNS_ZASH_DIR || "$key" == WWW_DIR ]] && continue
        unset "$key"
    done
}

# DNS_ZASH_DIR resolves dns.env (cfg_get) > default HERE, right after
# cfg_get is defined -- so install_zashboard and uninstall
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
    local dir="$1" name="$2" value="$3" marker
    marker="$dir/$name"
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(cat "$marker" 2>/dev/null || true)" == "$value" ]]
}

# A marker inside a service-writable directory is not proof of ownership by
# content alone: the service account can recreate the same bytes. Fixed runtime
# roots therefore accept only the marker atomically published by root.
root_ownership_marker_is_safe() {
    local dir="$1" name="$2" value="$3" marker="$1/$2"
    verify_ownership_marker "$dir" "$name" "$value" || return 1
    [[ "$(file_uid "$marker")" == 0 \
       && "$(file_gid "$marker")" == 0 \
       && "$(file_mode "$marker")" == 644 \
       && "$(file_nlink "$marker")" == 1 ]]
}

account_uid() {
    getent passwd "$1" 2>/dev/null | awk -F: 'NR == 1 { print $3 }'
}

account_gid() {
    getent group "$1" 2>/dev/null | awk -F: 'NR == 1 { print $3 }'
}

# Fixed roots have a deliberately small metadata state machine. A new root is
# initially root:root 0755. The prior non-sticky config mode is accepted only so
# this transaction can normalize an installed beta to the current 3771 boundary.
fixed_owned_dir_metadata_is_safe() {
    local dir="$1" uid gid mode expected_uid expected_gid
    uid="$(file_uid "$dir")"
    gid="$(file_gid "$dir")"
    mode="$(file_mode "$dir")"
    case "$dir" in
        "$BASE_DIR"|"$STATE_DIR")
            [[ "$uid" == 0 && "$gid" == 0 && "$mode" == 755 ]] ;;
        "$CONF_DIR")
            [[ "$uid" == 0 ]] || return 1
            if [[ "$gid" == 0 && "$mode" == 755 ]]; then
                return 0
            fi
            expected_gid="$(account_gid "$DNS_SERVICE_USER")"
            [[ -n "$expected_gid" && "$gid" == "$expected_gid" \
               && ( "$mode" == 3771 || "$mode" == 2771 ) ]] ;;
        "$INTERCEPT_CA_DIR")
            [[ "$uid" == 0 && "$gid" == 0 && ( "$mode" == 700 || "$mode" == 755 ) ]] ;;
        "$INTERCEPT_STATE_DIR")
            if [[ "$uid" == 0 && "$gid" == 0 && "$mode" == 755 ]]; then
                return 0
            fi
            expected_uid="$(account_uid "$INTERCEPT_SERVICE_USER")"
            expected_gid="$(account_gid "$INTERCEPT_SERVICE_USER")"
            [[ -n "$expected_uid" && -n "$expected_gid" \
               && "$uid" == "$expected_uid" && "$gid" == "$expected_gid" \
               && "$mode" == 700 ]] ;;
        *)
            return 1 ;;
    esac
}

fixed_owned_dir_is_safe() {
    local dir="$1" marker="$2" value="$3" canonical
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    canonical="$(canonical_dir_path "$dir")" || return 1
    [[ "$canonical" == "$dir" ]] || return 1
    fixed_owned_dir_metadata_is_safe "$dir" || return 1
    root_ownership_marker_is_safe "$dir" "$marker" "$value"
}

unmarked_fixed_dir_is_safe_to_claim() {
    local dir="$1" canonical mode
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    canonical="$(canonical_dir_path "$dir")" || return 1
    [[ "$canonical" == "$dir" \
       && "$(file_uid "$dir")" == 0 \
       && "$(file_gid "$dir")" == 0 ]] || return 1
    mode="$(file_mode "$dir")"
    case "$dir" in
        "$INTERCEPT_CA_DIR") [[ "$mode" == 700 || "$mode" == 755 ]] ;;
        *) [[ "$mode" == 755 ]] ;;
    esac
}

# Validate an installer-managed directory slot before a root operation can
# follow it. canonical_dir_path catches aliases in existing ancestors, while
# the component walk also rejects a non-directory or a broken symlink.
runtime_directory_slot_is_safe() {
    local path="$1" root="$2" canonical_root canonical_path relative component current
    [[ "$path" == /* && "$root" == /* ]] || return 1
    [[ -d "$root" && ! -L "$root" ]] || return 1
    canonical_root="$(canonical_dir_path "$root")" || return 1
    [[ "$canonical_root" == "$root" ]] || return 1
    case "$path" in "$root"|"$root"/*) ;; *) return 1 ;; esac
    canonical_path="$(canonical_dir_path "$path")" || return 1
    [[ "$canonical_path" == "$path" ]] || return 1
    relative="${path#"$root"}"
    relative="${relative#/}"
    current="$root"
    while [[ -n "$relative" ]]; do
        component="${relative%%/*}"
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
        current="${current}/${component}"
        if [[ -e "$current" || -L "$current" ]]; then
            [[ -d "$current" && ! -L "$current" ]] || return 1
        fi
        if [[ "$relative" == */* ]]; then
            relative="${relative#*/}"
        else
            relative=""
        fi
    done
}

runtime_file_slot_is_safe() {
    local path="$1" root="$2" parent
    parent="$(dirname -- "$path")" || return 1
    runtime_directory_slot_is_safe "$parent" "$root" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    [[ -f "$path" && ! -L "$path" ]]
}

runtime_tree_has_only_plain_entries() {
    local root="$1" unsafe
    runtime_directory_slot_is_safe "$root" "$root" || return 1
    unsafe="$(find "$root" -mindepth 1 ! -type d ! -type f -print -quit 2>/dev/null)" \
        || return 1
    [[ -z "$unsafe" ]] || return 1
    unsafe="$(find "$root" -mindepth 1 -type f -links +1 -print -quit 2>/dev/null)" \
        || return 1
    [[ -z "$unsafe" ]]
}

# Certificate roles deliberately contain one symlink used as their atomic
# publication pointer. It is safe only when it is the exact `current` entry and
# resolves to an ordinary generation directory below the same role.
root_plain_file_metadata_is_safe() {
    local path="$1" expected_gid="$2" expected_mode="$3"
    [[ -f "$path" && ! -L "$path" \
       && "$(file_uid "$path")" == 0 \
       && "$(file_gid "$path")" == "$expected_gid" \
       && "$(file_mode "$path")" == "$expected_mode" \
       && "$(file_nlink "$path")" == 1 ]]
}

cert_generation_is_safe() {
    local generation="$1" expected_gid="$2" entry name count=0
    root_owned_nonwritable_directory_is_safe "$generation" || return 1
    [[ "$(file_gid "$generation")" == "$expected_gid" \
       && "$(file_mode "$generation")" == 750 ]] || return 1
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in fullchain.pem|privkey.pem) ;; *) return 1 ;; esac
        root_plain_file_metadata_is_safe "$entry" "$expected_gid" 640 || return 1
        count=$((count + 1))
    done < <(find "$generation" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    [[ "$count" == 2 ]]
}

cert_role_tree_is_safe_for_recursive_metadata() {
    local role="$1" role_name group expected_gid current target canonical entry name generations
    role_name="$(basename -- "$role")"
    case "$role_name" in
        dot|web) group="$DNS_SERVICE_USER" ;;
        zash) group="$MIHOMO_SERVICE_USER" ;;
        *) return 1 ;;
    esac
    expected_gid="$(account_gid "$group")"
    [[ -n "$expected_gid" ]] || return 1
    runtime_directory_slot_is_safe "$role" "$DNS_CERT_DIR" || return 1
    root_owned_nonwritable_directory_is_safe "$role" \
        && [[ "$(file_gid "$role")" == "$expected_gid" \
           && "$(file_mode "$role")" == 750 ]] \
        && root_ownership_marker_is_safe "$role" "$CERT_ROLE_MARKER" \
            "${CERT_ROLE_VALUE_PREFIX}:${role_name}" \
        || return 1
    generations="$role/generations"
    root_owned_nonwritable_directory_is_safe "$generations" \
        && [[ "$(file_gid "$generations")" == "$expected_gid" \
           && "$(file_mode "$generations")" == 750 ]] \
        || return 1
    current="$role/current"
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_MARKER"|generations) ;;
            current)
                [[ -L "$entry" && "$(file_uid "$entry")" == 0 \
                   && "$(file_gid "$entry")" == 0 \
                   && "$(file_nlink "$entry")" == 1 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$role" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        [[ "$name" =~ ^generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] \
            || return 1
        cert_generation_is_safe "$entry" "$expected_gid" || return 1
    done < <(find "$generations" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    if [[ -e "$current" || -L "$current" ]]; then
        [[ -L "$current" ]] || return 1
        target="$(readlink -- "$current")" || return 1
        [[ "$target" =~ ^generations/generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] \
            || return 1
        [[ -d "$role/$target" && ! -L "$role/$target" ]] || return 1
        canonical="$(canonical_dir_path "$role/$target")" || return 1
        [[ "$canonical" == "$role/$target" ]] || return 1
    fi
}

# The immediately preceding beta normalized role markers and `current` symlinks
# to the role group. Accept that exact structure only while no certificate-root
# marker exists, then atomically republish those metadata entries in final form.
legacy_cert_role_tree_is_migratable() {
    local role="$1" role_name group expected_gid current target canonical entry name generations marker
    role_name="$(basename -- "$role")"
    case "$role_name" in
        dot|web) group="$DNS_SERVICE_USER" ;;
        zash) group="$MIHOMO_SERVICE_USER" ;;
        *) return 1 ;;
    esac
    expected_gid="$(account_gid "$group")"
    [[ -n "$expected_gid" ]] || return 1
    runtime_directory_slot_is_safe "$role" "$DNS_CERT_DIR" || return 1
    root_owned_nonwritable_directory_is_safe "$role" \
        && [[ "$(file_gid "$role")" == "$expected_gid" \
           && "$(file_mode "$role")" == 750 ]] || return 1
    marker="$role/$CERT_ROLE_MARKER"
    if ! root_ownership_marker_is_safe "$role" "$CERT_ROLE_MARKER" \
            "${CERT_ROLE_VALUE_PREFIX}:${role_name}"; then
        root_plain_file_metadata_is_safe "$marker" "$expected_gid" 640 \
            && [[ "$(cat "$marker" 2>/dev/null || true)" == "${CERT_ROLE_VALUE_PREFIX}:${role_name}" ]] \
            || return 1
    fi
    generations="$role/generations"
    root_owned_nonwritable_directory_is_safe "$generations" \
        && [[ "$(file_gid "$generations")" == "$expected_gid" \
           && "$(file_mode "$generations")" == 750 ]] || return 1
    current="$role/current"
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROLE_MARKER"|generations) ;;
            current)
                [[ -L "$entry" && "$(file_uid "$entry")" == 0 \
                   && ( "$(file_gid "$entry")" == 0 || "$(file_gid "$entry")" == "$expected_gid" ) \
                   && "$(file_nlink "$entry")" == 1 ]] || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$role" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        [[ "$name" =~ ^generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] \
            || return 1
        cert_generation_is_safe "$entry" "$expected_gid" || return 1
    done < <(find "$generations" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    if [[ -e "$current" || -L "$current" ]]; then
        [[ -L "$current" ]] || return 1
        target="$(readlink -- "$current")" || return 1
        [[ "$target" =~ ^generations/generation-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] \
            || return 1
        [[ -d "$role/$target" && ! -L "$role/$target" ]] || return 1
        canonical="$(canonical_dir_path "$role/$target")" || return 1
        [[ "$canonical" == "$role/$target" ]] || return 1
    fi
}

normalize_legacy_cert_role_metadata() {
    local role="$1" role_name current target candidate
    role_name="$(basename -- "$role")"
    legacy_cert_role_tree_is_migratable "$role" || return 1
    write_ownership_marker "$role" "$CERT_ROLE_MARKER" "${CERT_ROLE_VALUE_PREFIX}:${role_name}" \
        || return 1
    current="$role/current"
    if [[ -e "$current" || -L "$current" ]]; then
        target="$(readlink -- "$current")" || return 1
        candidate="$role/.current.normalize.${BASHPID}.${RANDOM}"
        [[ ! -e "$candidate" && ! -L "$candidate" ]] || return 1
        ln -s "$target" "$candidate" \
            && mv -Tf -- "$candidate" "$current" \
            || { rm -f -- "$candidate"; return 1; }
    fi
    cert_role_tree_is_safe_for_recursive_metadata "$role"
}

legacy_cert_root_contents_are_migratable() {
    local entry name
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            .provenance) root_plain_file_metadata_is_safe "$entry" 0 640 || return 1 ;;
            dot|web|zash) legacy_cert_role_tree_is_migratable "$entry" || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$DNS_CERT_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

cert_root_contents_are_safe() {
    local entry name
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CERT_ROOT_MARKER") ;;
            .provenance) root_plain_file_metadata_is_safe "$entry" 0 640 || return 1 ;;
            .certbot-ownership) root_plain_file_metadata_is_safe "$entry" 0 640 || return 1 ;;
            dot|web|zash) cert_role_tree_is_safe_for_recursive_metadata "$entry" || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$DNS_CERT_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

cert_root_is_safe() {
    runtime_directory_slot_is_safe "$DNS_CERT_DIR" "$CONF_DIR" \
        && root_owned_nonwritable_directory_is_safe "$DNS_CERT_DIR" \
        && [[ "$(file_gid "$DNS_CERT_DIR")" == 0 \
           && "$(file_mode "$DNS_CERT_DIR")" == 751 ]] \
        && root_ownership_marker_is_safe "$DNS_CERT_DIR" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE" \
        && cert_root_contents_are_safe
}

ensure_dns_cert_root() {
    local mode
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$DNS_CERT_DIR" "$CONF_DIR" \
        || { err "Refusing unsafe certificate root slot: $DNS_CERT_DIR"; return 1; }
    if [[ ! -e "$DNS_CERT_DIR" && ! -L "$DNS_CERT_DIR" ]]; then
        install -d -o root -g root -m 0751 "$DNS_CERT_DIR" || return 1
    fi
    [[ -d "$DNS_CERT_DIR" && ! -L "$DNS_CERT_DIR" \
       && "$(file_uid "$DNS_CERT_DIR")" == 0 \
       && "$(file_gid "$DNS_CERT_DIR")" == 0 ]] \
        || { err "Certificate root ownership is unsafe: $DNS_CERT_DIR"; return 1; }
    if root_ownership_marker_is_safe "$DNS_CERT_DIR" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE"; then
        if [[ "$(file_mode "$DNS_CERT_DIR")" == 750 ]] \
           && cert_root_contents_are_safe; then
            chmod 0751 "$DNS_CERT_DIR" || return 1
        fi
        cert_root_is_safe \
            || { err "Existing certificate root failed structural validation: $DNS_CERT_DIR"; return 1; }
        return 0
    fi
    [[ ! -e "$DNS_CERT_DIR/$CERT_ROOT_MARKER" && ! -L "$DNS_CERT_DIR/$CERT_ROOT_MARKER" ]] \
        || { err "Certificate root marker is unsafe: $DNS_CERT_DIR/$CERT_ROOT_MARKER"; return 1; }
    mode="$(file_mode "$DNS_CERT_DIR")"
    [[ "$mode" == 750 || "$mode" == 751 || "$mode" == 755 ]] \
        && legacy_cert_root_contents_are_migratable \
        || { err "Refusing to claim an unknown certificate root: $DNS_CERT_DIR"; return 1; }
    local role
    for role in dot web zash; do
        [[ ! -e "$DNS_CERT_DIR/$role" && ! -L "$DNS_CERT_DIR/$role" ]] \
            || normalize_legacy_cert_role_metadata "$DNS_CERT_DIR/$role" || return 1
    done
    chmod 0751 "$DNS_CERT_DIR" || return 1
    write_ownership_marker "$DNS_CERT_DIR" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE" \
        || return 1
    cert_root_is_safe \
        || { err "Could not establish the certificate root boundary: $DNS_CERT_DIR"; return 1; }
}

debug_cert_lineage_slot_is_safe() {
    local live="$1" entry name
    runtime_directory_slot_is_safe "$live" "$DEBUG_CERT_DIR" \
        && root_owned_nonwritable_directory_is_safe "$live" \
        && [[ "$(file_gid "$live")" == 0 \
           && "$(file_mode "$live")" == 700 ]] || return 1
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in fullchain.pem|privkey.pem) ;; *) return 1 ;; esac
        root_plain_file_metadata_is_safe "$entry" 0 600 || return 1
    done < <(find "$live" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

debug_cert_root_contents_are_safe() {
    local entry name
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        if [[ "$name" == "$DEBUG_CERT_MARKER" ]]; then
            continue
        fi
        is_valid_domain "$name" || return 1
        debug_cert_lineage_slot_is_safe "$entry" || return 1
    done < <(find "$DEBUG_CERT_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

debug_cert_root_is_safe() {
    runtime_directory_slot_is_safe "$DEBUG_CERT_DIR" "$CONF_DIR" \
        && root_owned_nonwritable_directory_is_safe "$DEBUG_CERT_DIR" \
        && [[ "$(file_gid "$DEBUG_CERT_DIR")" == 0 \
           && "$(file_mode "$DEBUG_CERT_DIR")" == 700 ]] \
        && root_ownership_marker_is_safe "$DEBUG_CERT_DIR" "$DEBUG_CERT_MARKER" "$DEBUG_CERT_MARKER_VALUE" \
        && debug_cert_root_contents_are_safe
}

ensure_debug_cert_root() {
    local mode
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$DEBUG_CERT_DIR" "$CONF_DIR" \
        || { err "Refusing unsafe debug-certificate root slot: $DEBUG_CERT_DIR"; return 1; }
    if [[ ! -e "$DEBUG_CERT_DIR" && ! -L "$DEBUG_CERT_DIR" ]]; then
        install -d -o root -g root -m 0700 "$DEBUG_CERT_DIR" || return 1
    fi
    [[ -d "$DEBUG_CERT_DIR" && ! -L "$DEBUG_CERT_DIR" \
       && "$(file_uid "$DEBUG_CERT_DIR")" == 0 \
       && "$(file_gid "$DEBUG_CERT_DIR")" == 0 ]] \
        || { err "Debug-certificate root ownership is unsafe: $DEBUG_CERT_DIR"; return 1; }
    if root_ownership_marker_is_safe "$DEBUG_CERT_DIR" "$DEBUG_CERT_MARKER" "$DEBUG_CERT_MARKER_VALUE"; then
        debug_cert_root_is_safe \
            || { err "Existing debug-certificate root failed structural validation."; return 1; }
        return 0
    fi
    [[ ! -e "$DEBUG_CERT_DIR/$DEBUG_CERT_MARKER" && ! -L "$DEBUG_CERT_DIR/$DEBUG_CERT_MARKER" ]] \
        || { err "Debug-certificate root marker is unsafe."; return 1; }
    mode="$(file_mode "$DEBUG_CERT_DIR")"
    [[ "$mode" == 700 || "$mode" == 755 ]] \
        && debug_cert_root_contents_are_safe \
        || { err "Refusing to claim an unknown debug-certificate root."; return 1; }
    chmod 0700 "$DEBUG_CERT_DIR" || return 1
    write_ownership_marker "$DEBUG_CERT_DIR" "$DEBUG_CERT_MARKER" "$DEBUG_CERT_MARKER_VALUE" \
        || return 1
    debug_cert_root_is_safe \
        || { err "Could not establish the debug-certificate root boundary."; return 1; }
}

remove_debug_cert_root() {
    [[ ! -e "$DEBUG_CERT_DIR" && ! -L "$DEBUG_CERT_DIR" ]] && return 0
    ensure_debug_cert_root || return 1
    debug_cert_root_is_safe || return 1
    remove_owned_root "$DEBUG_CERT_DIR" "$DEBUG_CERT_MARKER" "$DEBUG_CERT_MARKER_VALUE"
}

preflight_runtime_publication_paths() {
    local path
    fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        || { err "Unsafe installed-runtime root: $BASE_DIR"; return 1; }
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        || { err "Unsafe configuration root: $CONF_DIR"; return 1; }

    for path in \
        "$SCRIPTS_DIR" "$WWW_DIR" "${BASE_DIR}/etc" "${BASE_DIR}/etc/systemd" \
        "${BASE_DIR}/etc/mihomo" \
        "${BASE_DIR}/etc/polkit-1" "${BASE_DIR}/etc/polkit-1/rules.d"; do
        runtime_directory_slot_is_safe "$path" "$BASE_DIR" \
            || { err "Refusing unsafe runtime directory slot: $path"; return 1; }
    done
    for path in \
        "$DNS_RULES_DIR_DEFAULT" "${DNS_RULES_DIR_DEFAULT}/block" \
        "${DNS_RULES_DIR_DEFAULT}/direct" "${DNS_RULES_DIR_DEFAULT}/proxy" \
        "${DNS_RULES_DIR_DEFAULT}/chnroute" "$MIHOMO_DIR" "$INTERCEPT_DIR" \
        "${INTERCEPT_DIR}/tls" "$DNS_CERT_DIR" "${DNS_CERT_DIR}/dot" \
        "${DNS_CERT_DIR}/web" "${DNS_CERT_DIR}/zash"; do
        runtime_directory_slot_is_safe "$path" "$CONF_DIR" \
            || { err "Refusing unsafe configuration directory slot: $path"; return 1; }
    done
    for path in \
        "${CONF_DIR}/dns.env" "${CONF_DIR}/subscriptions.json" \
        "${CONF_DIR}/policy.json" "${CONF_DIR}/upstreams.json" \
        "${CONF_DIR}/ecs.json" "${CONF_DIR}/stats.json" \
        "${CONF_DIR}/tgbot.json" "${CONF_DIR}/extension-marketplaces.json" \
        "${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt" \
        "${MIHOMO_DIR}/config.yaml" "${MIHOMO_DIR}/whitelist.txt" \
        "${INTERCEPT_DIR}/config.json" "${INTERCEPT_DIR}/cert-state"; do
        runtime_file_slot_is_safe "$path" "$CONF_DIR" \
            || { err "Refusing unsafe configuration file slot: $path"; return 1; }
    done
}

shared_runtime_directory_metadata_is_safe() {
    local dir="$1" group="$2" mode="$3" expected_gid
    expected_gid="$(account_gid "$group")"
    [[ -n "$expected_gid" && -d "$dir" && ! -L "$dir" \
       && "$(canonical_dir_path "$dir")" == "$dir" \
       && "$(file_uid "$dir")" == 0 \
       && "$(file_gid "$dir")" == "$expected_gid" \
       && "$(file_mode "$dir")" == "$mode" ]]
}

runtime_control_file_metadata_is_safe() {
    local path="$1" owner="$2" group="$3" mode="$4" expected_uid expected_gid
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    expected_uid="$(account_uid "$owner")"
    expected_gid="$(account_gid "$group")"
    [[ -n "$expected_uid" && -n "$expected_gid" \
       && -f "$path" && ! -L "$path" \
       && "$(file_uid "$path")" == "$expected_uid" \
       && "$(file_gid "$path")" == "$expected_gid" \
       && "$(file_mode "$path")" == "$mode" \
       && "$(file_nlink "$path")" == 1 ]]
}

runtime_permission_boundary_is_safe() {
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && shared_runtime_directory_metadata_is_safe "$MIHOMO_DIR" "$MIHOMO_SERVICE_USER" 3770 \
        && shared_runtime_directory_metadata_is_safe "$INTERCEPT_DIR" "$INTERCEPT_SERVICE_USER" 3770 \
        && runtime_control_file_metadata_is_safe "$MIHOMO_DIR/config.yaml" \
            "$DNS_SERVICE_USER" "$MIHOMO_SERVICE_USER" 640 \
        && runtime_control_file_metadata_is_safe "$MIHOMO_DIR/whitelist.txt" \
            "$DNS_SERVICE_USER" "$MIHOMO_SERVICE_USER" 640 \
        && runtime_control_file_metadata_is_safe "$INTERCEPT_DIR/config.json" \
            "$DNS_SERVICE_USER" "$INTERCEPT_SERVICE_USER" 640 \
        && runtime_control_file_metadata_is_safe "$INTERCEPT_DIR/cert-state" \
            root "$INTERCEPT_SERVICE_USER" 640 \
        && cert_root_is_safe
}

owned_root_canonical() {
    local dir="$1" marker="$2" value="$3" canonical
    [[ -n "$dir" && "$dir" == /* && -d "$dir" && ! -L "$dir" ]] || return 1
    canonical="$(canonical_dir_path "$dir")" || return 1
    [[ "$canonical" == "$dir" ]] || return 1
    case "$canonical" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            return 1 ;;
    esac
    verify_ownership_marker "$canonical" "$marker" "$value" || return 1
    printf '%s\n' "$canonical"
}

remove_owned_root() {
    local canonical
    canonical="$(owned_root_canonical "$1" "$2" "$3")" || return 1
    rm -rf -- "$canonical"
}

clear_owned_scope() {
    local root="$1" marker="$2" value="$3" scope="$4" canonical scope_canonical preserve
    shift 4
    canonical="$(owned_root_canonical "$root" "$marker" "$value")" || return 1
    scope_canonical="$(canonical_dir_path "$scope")" || return 1
    [[ "$scope_canonical" == "$scope" ]] || return 1
    [[ "$scope_canonical" == "$canonical" || "$scope_canonical" == "$canonical"/* ]] || return 1
    local -a find_args=(find "$scope_canonical" -mindepth 1 -maxdepth 1)
    for preserve in "$@"; do
        [[ -n "$preserve" && "$preserve" != */* ]] || return 1
        find_args+=(! -name "$preserve")
    done
    "${find_args[@]}" -exec rm -rf -- {} +
}

remove_owned_child() {
    local root="$1" marker="$2" value="$3" child="$4" canonical target
    [[ -n "$child" && "$child" != */* ]] || return 1
    canonical="$(owned_root_canonical "$root" "$marker" "$value")" || return 1
    target="${canonical}/${child}"
    [[ ! -e "$target" && ! -L "$target" ]] && return 0
    [[ -d "$target" && ! -L "$target" ]] || return 1
    [[ "$(canonical_dir_path "$target")" == "$target" ]] || return 1
    rm -rf -- "$target"
}

remove_owned_scoped_child() {
    local root="$1" marker="$2" value="$3" scope="$4" child="$5"
    local canonical scope_canonical target
    [[ -n "$child" && "$child" != */* ]] || return 1
    canonical="$(owned_root_canonical "$root" "$marker" "$value")" || return 1
    scope_canonical="$(canonical_dir_path "$scope")" || return 1
    [[ "$scope_canonical" == "$scope" && "$scope_canonical" == "$canonical"/* ]] || return 1
    target="${scope_canonical}/${child}"
    [[ ! -e "$target" && ! -L "$target" ]] && return 0
    [[ -d "$target" && ! -L "$target" ]] || return 1
    [[ "$(canonical_dir_path "$target")" == "$target" ]] || return 1
    rm -rf -- "$target"
}

# Remove unpublished certificate generations and temporary current links after
# a staging or publication failure. A generation still referenced by current is
# deliberately retained: that can happen only when rollback of a published role
# also failed, and deleting it would turn a recoverable new certificate into a
# dangling live link.
cleanup_cert_role_candidates() {
    local roles_name="$1" dests_name="$2" generations_name="$3" links_name="$4"
    local -n candidate_roles="$roles_name"
    local -n candidate_dests="$dests_name"
    local -n candidate_generations="$generations_name"
    local -n candidate_links="$links_name"
    local i role dest generation link target current
    for i in "${!candidate_generations[@]}"; do
        role="${candidate_roles[$i]}"
        dest="${candidate_dests[$i]}"
        generation="${candidate_generations[$i]}"
        link="${candidate_links[$i]:-}"
        [[ -z "$link" ]] || rm -f -- "$link"
        [[ -n "$generation" ]] || continue
        target="generations/$(basename -- "$generation")"
        current="$(readlink -- "${dest}/current" 2>/dev/null || true)"
        if [[ "$current" != "$target" ]]; then
            remove_owned_scoped_child "$dest" "$CERT_ROLE_MARKER" \
                "${CERT_ROLE_VALUE_PREFIX}:${role}" "${dest}/generations" \
                "$(basename -- "$generation")" || true
        fi
    done
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

claim_fixed_owned_dir() {
    local dir="$1" marker="$2" value="$3" canonical nonempty=0 created_dir=0
    canonical="$(canonical_dir_path "$dir")" \
        || { err "Could not canonicalize project directory: $dir"; return 1; }
    [[ "$canonical" == "$dir" ]] \
        || { err "Refusing project directory symlink/alias: $dir -> $canonical"; return 1; }
    [[ ! -e "$dir" || -d "$dir" ]] \
        || { err "Project path exists but is not a directory: $dir"; return 1; }
    [[ -d "$dir" && -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && nonempty=1
    if verify_ownership_marker "$dir" "$marker" "$value"; then
        fixed_owned_dir_is_safe "$dir" "$marker" "$value" \
            || { err "Unsafe ownership or mode on fixed project directory: $dir"; return 1; }
        return 0
    fi
    if [[ -e "$dir/$marker" ]]; then
        err "Invalid or symlinked ownership marker: $dir/$marker"
        return 1
    fi
    if [[ "$nonempty" == 1 ]]; then
        err "Refusing non-empty unowned project directory: $dir"
        return 1
    fi
    if [[ -e "$dir" || -L "$dir" ]]; then
        unmarked_fixed_dir_is_safe_to_claim "$dir" \
            || { err "Refusing unsafe empty fixed directory before marker publication: $dir"; return 1; }
    else
        created_dir=1
        # CONF_DIR is intentionally setgid. A child created there without an
        # explicit group inherits gpn-dns and immediately fails the root-owned
        # fixed-root boundary. Establish fresh roots with exact metadata before
        # publishing the ownership marker.
        install -d -o root -g root -m 0755 -- "$dir" \
            && chmod g-s -- "$dir" \
            && chmod 0755 -- "$dir" \
            || { err "Could not create fixed project directory: $dir"; return 1; }
    fi
    write_ownership_marker "$dir" "$marker" "$value" \
        || { err "Could not write ownership marker under $dir"; return 1; }
    if ! fixed_owned_dir_is_safe "$dir" "$marker" "$value"; then
        rm -f -- "$dir/$marker"
        [[ "$created_dir" == 0 ]] || rmdir -- "$dir" 2>/dev/null || true
        err "Could not establish safe ownership on fixed project directory: $dir"
        return 1
    fi
}

claim_project_roots() {
    claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" || return 1
    claim_fixed_owned_dir "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" || return 1
    claim_fixed_owned_dir "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" || return 1
}

# Older beta installs used a setgid CA directory and inherited the gpn-dns
# group on its root-published marker. Accept only that exact, closed legacy
# shape during read-only preflight; normalization happens after the rollback
# snapshot and while runtime writers are stopped.
legacy_intercept_ca_root_is_safe() {
    local marker="$INTERCEPT_CA_DIR/$INTERCEPT_CA_MARKER" dns_gid entry name count=0
    dns_gid="$(account_gid "$DNS_SERVICE_USER")"
    [[ -n "$dns_gid" \
       && -d "$INTERCEPT_CA_DIR" && ! -L "$INTERCEPT_CA_DIR" \
       && "$(canonical_dir_path "$INTERCEPT_CA_DIR")" == "$INTERCEPT_CA_DIR" \
       && "$(file_uid "$INTERCEPT_CA_DIR")" == 0 \
       && "$(file_gid "$INTERCEPT_CA_DIR")" == 0 \
       && ( "$(file_mode "$INTERCEPT_CA_DIR")" == 2700 \
          || "$(file_mode "$INTERCEPT_CA_DIR")" == 700 ) \
       && -f "$marker" && ! -L "$marker" \
       && "$(file_uid "$marker")" == 0 \
       && ( "$(file_gid "$marker")" == 0 || "$(file_gid "$marker")" == "$dns_gid" ) \
       && "$(file_mode "$marker")" == 644 \
       && "$(file_nlink "$marker")" == 1 \
       && "$(cat "$marker" 2>/dev/null || true)" == "$INTERCEPT_CA_MARKER_VALUE" ]] \
        || return 1
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$INTERCEPT_CA_MARKER") ;;
            root.crt) root_plain_file_metadata_is_safe "$entry" 0 644 || return 1 ;;
            root.key) root_plain_file_metadata_is_safe "$entry" 0 600 || return 1 ;;
            *) return 1 ;;
        esac
        count=$((count + 1))
    done < <(find "$INTERCEPT_CA_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    [[ "$count" == 3 ]]
}

normalize_legacy_intercept_ca_root() {
    local marker="$INTERCEPT_CA_DIR/$INTERCEPT_CA_MARKER"
    legacy_intercept_ca_root_is_safe \
        || { err "Legacy interception CA root failed strict migration validation."; return 1; }
    chown root:root "$marker" \
        && chmod 0644 "$marker" \
        && chmod 0700 "$INTERCEPT_CA_DIR" \
        && chmod g-s "$INTERCEPT_CA_DIR" \
        || { err "Could not normalize the legacy interception CA root metadata."; return 1; }
    fixed_owned_dir_is_safe "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" \
        || { err "Normalized interception CA root failed validation."; return 1; }
}

# New fixed roots must be inspected without mutating the host before the
# install transaction records whether each path was absent. Existing paths are
# accepted only when their ownership marker is already valid.
preflight_intercept_roots() {
    local dir marker value
    while read -r dir marker value; do
        if [[ ! -e "$dir" && ! -L "$dir" ]]; then
            continue
        fi
        if [[ "$dir" == "$INTERCEPT_CA_DIR" ]]; then
            fixed_owned_dir_is_safe "$dir" "$marker" "$value" \
                || legacy_intercept_ca_root_is_safe \
                || { err "Refusing pre-existing unowned interception root: $dir"; return 1; }
        else
            fixed_owned_dir_is_safe "$dir" "$marker" "$value" \
                || { err "Refusing pre-existing unowned interception root: $dir"; return 1; }
        fi
    done <<EOF
$INTERCEPT_CA_DIR $INTERCEPT_CA_MARKER $INTERCEPT_CA_MARKER_VALUE
$INTERCEPT_STATE_DIR $INTERCEPT_STATE_MARKER $INTERCEPT_STATE_MARKER_VALUE
EOF
}

claim_intercept_roots() {
    if [[ -e "$INTERCEPT_CA_DIR" || -L "$INTERCEPT_CA_DIR" ]]; then
        if ! fixed_owned_dir_is_safe "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE"; then
            normalize_legacy_intercept_ca_root || return 1
        fi
    fi
    claim_fixed_owned_dir "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" || return 1
    claim_fixed_owned_dir "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" || return 1
}

remove_fixed_owned_dir() {
    local dir="$1" marker="$2" value="$3"
    [[ -e "$dir" ]] || return 0
    case "$dir" in
        "$BASE_DIR"|"$CONF_DIR"|"$STATE_DIR"|"$INTERCEPT_CA_DIR"|"$INTERCEPT_STATE_DIR") ;;
        *) err "Refusing non-fixed directory through fixed-root removal: $dir"; return 1 ;;
    esac
    fixed_owned_dir_is_safe "$dir" "$marker" "$value" \
        || { err "Refusing to remove unsafe or unowned fixed directory: $dir"; return 1; }
    remove_owned_root "$dir" "$marker" "$value" \
        || { err "Refusing to remove unsafe or unowned directory: $dir"; return 1; }
}

# Remove the 5gpn runtime while preserving the verified Gum binary. Gum is a
# general operator UI tool and may be referenced by other host automation after
# 5gpn is removed. The project root and ownership marker remain so a later
# reinstall can safely reuse the directory. If Gum is already absent, disable
# Gum output before removing the whole owned runtime.
remove_runtime_preserving_gum() {
    local canonical
    [[ -e "$BASE_DIR" ]] || { _HAVE_GUM=0; return 0; }
    canonical="$(canonical_dir_path "$BASE_DIR")" || return 1
    [[ "$canonical" == "$BASE_DIR" ]] \
        || { err "Refusing runtime directory alias during removal: $BASE_DIR"; return 1; }
    fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        || { err "Refusing to remove unowned runtime directory: $BASE_DIR"; return 1; }

    if [[ -d "$BIN_DIR" && ! -L "$BIN_DIR" && -f "$GUM_BIN" && ! -L "$GUM_BIN" ]]; then
        clear_owned_scope "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
            "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" bin \
            || { err "Could not remove the 5gpn runtime around preserved Gum."; return 1; }
        clear_owned_scope "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
            "$BIN_DIR" gum \
            || { err "Could not clean project binaries around preserved Gum."; return 1; }
        ok "Preserved shared Gum binary: $GUM_BIN"
        return 0
    fi

    _HAVE_GUM=0
    remove_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"
}

mode_has_no_group_or_other_write() {
    local mode="$1" value
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    value=$((8#$mode))
    (( (value & 0022) == 0 ))
}

root_owned_nonwritable_directory_is_safe() {
    local dir="$1" canonical
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    canonical="$(canonical_dir_path "$dir")" || return 1
    [[ "$canonical" == "$dir" && "$(file_uid "$dir")" == 0 ]] || return 1
    mode_has_no_group_or_other_write "$(file_mode "$dir")"
}

# A local user must not be able to rename the publication parent after it was
# checked but before root creates or swaps a static tree. Validate every existing
# component, including the direct parent, and reject aliases and writable dirs.
secure_directory_chain_is_safe() {
    local path="$1" canonical relative component current="/"
    [[ "$path" == /* ]] || return 1
    canonical="$(canonical_dir_path "$path")" || return 1
    [[ "$canonical" == "$path" ]] || return 1
    root_owned_nonwritable_directory_is_safe / || return 1
    relative="${path#/}"
    while [[ -n "$relative" ]]; do
        component="${relative%%/*}"
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
        current="${current%/}/${component}"
        if [[ -e "$current" || -L "$current" ]]; then
            root_owned_nonwritable_directory_is_safe "$current" || return 1
        fi
        if [[ "$relative" == */* ]]; then
            relative="${relative#*/}"
        else
            relative=""
        fi
    done
}

ensure_static_publish_parent() {
    local dest="$1" parent
    parent="$(dirname -- "$dest")" || return 1
    secure_directory_chain_is_safe "$parent" || return 1
    root_owned_nonwritable_directory_is_safe "$parent"
}

static_publish_parent_is_safe() {
    local parent
    parent="$(dirname -- "$1")" || return 1
    secure_directory_chain_is_safe "$parent" \
        && root_owned_nonwritable_directory_is_safe "$parent"
}

static_owned_tree_is_safe() {
    local dir="$1" marker="$2" value="$3"
    root_owned_nonwritable_directory_is_safe "$dir" \
        && root_ownership_marker_is_safe "$dir" "$marker" "$value"
}

claim_empty_public_owned_tree() {
    local dir="$1" marker="$2" value="$3" created_dir=0
    if [[ -e "$dir" || -L "$dir" ]]; then
        root_owned_nonwritable_directory_is_safe "$dir" || return 1
        [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] \
            || return 1
    else
        created_dir=1
    fi
    write_ownership_marker "$dir" "$marker" "$value" || return 1
    if ! static_owned_tree_is_safe "$dir" "$marker" "$value"; then
        rm -f -- "$dir/$marker"
        [[ "$created_dir" == 0 ]] || rmdir -- "$dir" 2>/dev/null || true
        return 1
    fi
}

remove_public_owned_tree() {
    local dir="$1" marker="$2" value="$3"
    [[ ! -e "$dir" && ! -L "$dir" ]] && return 0
    static_publish_parent_is_safe "$dir" \
        && static_owned_tree_is_safe "$dir" "$marker" "$value" \
        || { err "Refusing to remove unsafe or unowned public tree: $dir"; return 1; }
    remove_owned_root "$dir" "$marker" "$value"
}

normalize_static_tree_ownership() {
    find "$1" -exec chown root:root {} +
}

preflight_public_owned_tree() {
    local path="$1" marker="$2" value="$3" parent nonempty=0
    parent="$(dirname -- "$path")" || return 1
    secure_directory_chain_is_safe "$parent" \
        && root_owned_nonwritable_directory_is_safe "$parent" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    [[ -d "$path" && ! -L "$path" ]] || return 1
    if verify_ownership_marker "$path" "$marker" "$value"; then
        static_owned_tree_is_safe "$path" "$marker" "$value"
        return
    fi
    [[ ! -e "$path/$marker" && ! -L "$path/$marker" ]] || return 1
    [[ -n "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] \
        && nonempty=1
    [[ "$nonempty" == 0 ]] || return 1
    root_owned_nonwritable_directory_is_safe "$path"
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

preflight_zashboard_dir() {
    local p
    p="$(safe_zashboard_path)" || return 1
    DNS_ZASH_DIR="$p"
    preflight_public_owned_tree "$p" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1' \
        || { err "Refusing unsafe or unowned DNS_ZASH_DIR before staging: $p"; return 1; }
    export DNS_ZASH_DIR
}

# Claim the zashboard directory before ever clearing it. A non-empty directory
# must already carry the exact current ownership marker.
claim_zashboard_dir() {
    local p marker nonempty=0
    preflight_zashboard_dir || return 1
    p="$(safe_zashboard_path)" || return 1
    DNS_ZASH_DIR="$p"
    marker="$p/$ZASH_OWNERSHIP_MARKER"
    ensure_static_publish_parent "$p" \
        || { err "DNS_ZASH_DIR parent is not root-owned and non-writable: $(dirname -- "$p")"; return 1; }
    if [[ ( -e "$p" || -L "$p" ) && ( ! -d "$p" || -L "$p" ) ]]; then
        err "DNS_ZASH_DIR exists but is not a directory: $p"; return 1
    fi
    [[ -d "$p" && -n "$(find "$p" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && nonempty=1
    if verify_ownership_marker "$p" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1'; then
        static_owned_tree_is_safe "$p" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1' \
            || { err "Unsafe zashboard directory or ownership marker: $p"; return 1; }
    elif [[ "$nonempty" == 0 ]]; then
        [[ ! -e "$marker" && ! -L "$marker" ]] \
            || { err "Invalid zashboard ownership marker: $marker"; return 1; }
        claim_empty_public_owned_tree "$p" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1' \
            || { err "Could not establish safe zashboard ownership: $p"; return 1; }
    else
        err "Refusing non-empty external DNS_ZASH_DIR without a 5gpn ownership marker: $p"
        return 1
    fi
    export DNS_ZASH_DIR
}

clear_zashboard_dir() {
    claim_zashboard_dir || return 1
    clear_owned_scope "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1' \
        "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER"
}

remove_zashboard_dir() {
    local p
    p="$(safe_zashboard_path)" || return 1
    [[ -e "$p" ]] || return 0
    static_publish_parent_is_safe "$p" \
        && static_owned_tree_is_safe "$p" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1' \
        || { err "Refusing to remove unowned zashboard directory: $p"; return 1; }
    remove_public_owned_tree "$p" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1'
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

preflight_web_dir() {
    local p
    p="$(safe_web_path)" || return 1
    DNS_WEB_DIR="$p"
    preflight_public_owned_tree "$p" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE" \
        || { err "Refusing unsafe or unowned DNS_WEB_DIR before staging: $p"; return 1; }
}

claim_web_dir() {
    local p marker nonempty=0
    preflight_web_dir || return 1
    p="$(safe_web_path)" || return 1
    DNS_WEB_DIR="$p"
    marker="$p/$WEB_OWNERSHIP_MARKER"
    ensure_static_publish_parent "$p" \
        || { err "DNS_WEB_DIR parent is not root-owned and non-writable: $(dirname -- "$p")"; return 1; }
    [[ ( ! -e "$p" && ! -L "$p" ) || ( -d "$p" && ! -L "$p" ) ]] \
        || { err "DNS_WEB_DIR is not a directory: $p"; return 1; }
    [[ -d "$p" && -n "$(find "$p" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && nonempty=1
    if verify_ownership_marker "$p" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"; then
        static_owned_tree_is_safe "$p" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE" \
            || { err "Unsafe web directory or ownership marker: $p"; return 1; }
        return 0
    fi
    [[ ! -e "$marker" ]] || { err "Invalid web ownership marker: $marker"; return 1; }
    [[ "$nonempty" == 0 ]] \
        || { err "Refusing non-empty DNS_WEB_DIR without the current ownership marker: $p"; return 1; }
    claim_empty_public_owned_tree "$p" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"
}

# Atomically publish a tree of public static assets. Source trees may come from
# mktemp (0700) or a restrictive caller umask, and cp -a preserves those modes.
# Normalize the complete candidate before the live-tree swap so the unprivileged
# gpn-dns service can traverse and read the console, zashboard, and iOS profile
# without exposing any writable path to it.
publish_owned_tree() {
    local src="$1" dest="$2" marker="$3" value="$4" parent leaf candidate backup
    parent="$(dirname -- "$dest")"; leaf="$(basename -- "$dest")"
    ensure_static_publish_parent "$dest" \
        || { err "Refusing unsafe static publication parent: $parent"; return 1; }
    candidate="$(mktemp -d "${parent}/.${leaf}.new.XXXXXX")" || return 1
    write_ownership_marker "$candidate" "$marker" "$value" \
        || { rmdir -- "$candidate"; return 1; }
    cp -a -- "$src/." "$candidate/" \
        || { remove_owned_root "$candidate" "$marker" "$value" || true; return 1; }
    write_ownership_marker "$candidate" "$marker" "$value" \
        || { remove_owned_root "$candidate" "$marker" "$value" || true; return 1; }
    runtime_tree_has_only_plain_entries "$candidate" \
        && normalize_static_tree_ownership "$candidate" \
        && find "$candidate" -type d -exec chmod 0755 {} + \
        && find "$candidate" -type f -exec chmod 0644 {} + \
        || { remove_owned_root "$candidate" "$marker" "$value" || true; return 1; }
    static_owned_tree_is_safe "$candidate" "$marker" "$value" \
        || { remove_owned_root "$candidate" "$marker" "$value" || true; return 1; }
    backup="${parent}/.${leaf}.old.$$"
    static_publish_parent_is_safe "$dest" \
        || { remove_owned_root "$candidate" "$marker" "$value" || true; err "Static publication parent changed before swap: $parent"; return 1; }
    [[ ! -e "$backup" && ! -L "$backup" ]] \
        || { remove_owned_root "$candidate" "$marker" "$value" || true; err "Static publication backup path already exists: $backup"; return 1; }
    if [[ -e "$dest" || -L "$dest" ]]; then
        static_owned_tree_is_safe "$dest" "$marker" "$value" \
            || { remove_owned_root "$candidate" "$marker" "$value" || true; err "Refusing to replace unowned tree: $dest"; return 1; }
        mv -- "$dest" "$backup" \
            || { remove_owned_root "$candidate" "$marker" "$value" || true; return 1; }
    fi
    if ! mv -- "$candidate" "$dest"; then
        [[ -e "$backup" ]] && mv -- "$backup" "$dest"
        remove_owned_root "$candidate" "$marker" "$value" || true
        return 1
    fi
    if [[ -e "$backup" ]]; then
        remove_owned_root "$backup" "$marker" "$value" || true
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
    [[ "$nonempty" == 0 ]] || return 1
    write_ownership_marker "$WWW_DIR" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE"
}

# Bootstrap gum (prebuilt binary + sha256 verify). Never fatal: on any failure
# _HAVE_GUM stays 0 and all helpers fall back to plain echo.
install_gum() {
    claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        || { _HAVE_GUM=0; warn "gum bootstrap could not claim the runtime directory; using plain output."; return 0; }
    # Only trust a gum that THIS process already verified. An arbitrary binary
    # on PATH with a matching --version is not supply-chain evidence.
    if [[ "$_HAVE_GUM" == 1 ]] && command -v gum >/dev/null 2>&1 \
       && gum --version 2>/dev/null | grep -qF "$GUM_VERSION"; then return 0; fi
    _HAVE_GUM=0
    local arch url tmp exp got bin m
    m="$(uname -m 2>/dev/null || echo x86_64)"
    case "$m" in
        x86_64|amd64)  arch="x86_64"; exp="$GUM_SHA256_X86_64" ;;
        aarch64|arm64) arch="arm64";  exp="$GUM_SHA256_ARM64" ;;
        armv7l|armhf)  arch="armv7";  exp="$GUM_SHA256_ARMV7" ;;
        *)             arch="x86_64"; exp="$GUM_SHA256_X86_64" ;;
    esac
    url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${arch}.tar.gz"
    tmp="$(mktemp -d /tmp/5gpn-gum.XXXXXX 2>/dev/null)" || { warn "gum: mktemp failed; using plain output."; _HAVE_GUM=0; return 0; }
    claim_temp_dir "$tmp" || { rmdir -- "$tmp" 2>/dev/null || true; warn "gum: could not claim temp directory; using plain output."; return 0; }
    if ! command -v curl >/dev/null 2>&1 \
       || ! curl -fsSL --connect-timeout 10 --max-time 60 \
            "$url" -o "$tmp/gum.tgz" 2>/dev/null; then
        warn "gum download failed; using plain output."
        remove_temp_dir "$tmp" 2>/dev/null || true
        return 0
    fi
    if [[ ! "$exp" =~ ^[0-9a-f]{64}$ ]]; then
        warn "gum pinned checksum is missing or invalid; refusing to install it and using plain output."
        remove_temp_dir "$tmp" 2>/dev/null || true
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        got="$(sha256sum "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
    elif command -v shasum >/dev/null 2>&1; then
        got="$(shasum -a 256 "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
    else
        warn "no SHA-256 tool is available; refusing to install gum and using plain output."
        remove_temp_dir "$tmp" 2>/dev/null || true
        return 0
    fi
    got="${got,,}"
    if [[ "$got" != "$exp" ]]; then
        warn "gum sha256 mismatch; refusing to install it and using plain output."
        remove_temp_dir "$tmp" 2>/dev/null || true
        return 0
    fi
    if ! archive_paths_safe tar "$tmp/gum.tgz" \
       || ! tar --no-same-owner --no-same-permissions --delay-directory-restore \
            -xzf "$tmp/gum.tgz" -C "$tmp" 2>/dev/null \
       || ! extracted_tree_safe "$tmp"; then
        warn "gum archive extraction failed; using plain output."
        remove_temp_dir "$tmp" 2>/dev/null || true
        return 0
    fi
    bin="$(find "$tmp" -type f -name gum 2>/dev/null | head -1 || true)"
    if [[ -z "$bin" ]] || ! "$bin" --version 2>/dev/null | grep -qF "$GUM_VERSION" \
       || ! publish_executable "$bin" "$GUM_BIN" 2>/dev/null; then
        warn "verified gum archive did not contain an installable ${GUM_VERSION} binary; using plain output."
        remove_temp_dir "$tmp" 2>/dev/null || true
        return 0
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

activate_verified_installed_gum() {
    _HAVE_GUM=0
    fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        || return 0
    [[ -f "$GUM_BIN" && ! -L "$GUM_BIN" \
       && "$(file_uid "$GUM_BIN")" == 0 \
       && "$(file_gid "$GUM_BIN")" == 0 \
       && "$(file_mode "$GUM_BIN")" == 755 \
       && "$(file_nlink "$GUM_BIN")" == 1 ]] || return 0
    "$GUM_BIN" --version 2>/dev/null | grep -qF "$GUM_VERSION" || return 0
    _HAVE_GUM=1
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
    local ips="$1" console_domain="$2" ip idx=0 suffix
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        idx=$((idx + 1)); suffix=""
        [[ "$idx" -gt 1 ]] && suffix="-${idx}"
        printf '  - {name: gateway%s, type: tunnel, listen: %s, port: 443, network: [tcp, udp], target: %s:443}\n' "$suffix" "$ip" "$console_domain"
        printf '  - {name: gateway80%s, type: tunnel, listen: %s, port: 80, network: [tcp], target: %s:80}\n' "$suffix" "$ip" "$console_domain"
        printf '  - {name: gateway8080%s, type: tunnel, listen: %s, port: 8080, network: [tcp], target: %s:8080}\n' "$suffix" "$ip" "$console_domain"
        printf '  - {name: gateway8443%s, type: tunnel, listen: %s, port: 8443, network: [tcp], target: %s:8443}\n' "$suffix" "$ip" "$console_domain"
        printf '  - {name: gateway5060%s, type: tunnel, listen: %s, port: 5060, network: [tcp, udp], target: %s:5060}\n' "$suffix" "$ip" "$console_domain"
    done < <(printf '%s\n' "$ips" | tr ',' '\n')
}

# ----------------------------------------------------------------------------
# Dependencies and installed-unit ownership
# ----------------------------------------------------------------------------
SYSTEMD_UNIT_CONFLICT_REASON=""

# systemd applies both exact drop-ins and dash-prefix drop-ins. For example,
# 5gpn-intercept-cert.service inherits 5gpn-intercept-.service.d and
# 5gpn-.service.d in addition to its exact directory.
systemd_unit_specific_dropin_names() {
    local unit="$1" type="${1##*.}" stem="${1%.*}" truncated template
    printf '%s.d\n' "$unit"
    if [[ "$stem" == *@* && "$stem" != *@ ]]; then
        template="${stem%%@*}@.${type}.d"
        printf '%s\n' "$template"
    fi
    truncated="$stem"
    while [[ "$truncated" == *-* ]]; do
        truncated="${truncated%-*}"
        printf '%s-.%s.d\n' "$truncated" "$type"
    done
}

systemd_global_dropin_key_is_managed() {
    local type="$1" key="$2"
    case "$type" in
        service)
            case "$key" in
                Exec*|User|Group|SupplementaryGroups|DynamicUser|Environment|EnvironmentFile|PassEnvironment|UnsetEnvironment|\
                WorkingDirectory|RootDirectory|RootDirectoryStartOnly|RootImage|RootEphemeral|UMask|PermissionsStartOnly|\
                Protect*|Private*|Restrict*|ReadWritePaths|ReadOnlyPaths|InaccessiblePaths|BindPaths|BindReadOnlyPaths|\
                TemporaryFileSystem|MountImages|ExtensionImages|NoExecPaths|ExecPaths|CapabilityBoundingSet|AmbientCapabilities|\
                NoNewPrivileges|SystemCall*|LockPersonality|MemoryDenyWriteExecute|SecureBits|KeyringMode|ProtectProc|ProcSubset|\
                IPAddressAllow|IPAddressDeny|SocketBindAllow|SocketBindDeny|NetworkNamespacePath|JoinsNamespaceOf|Device*|\
                LoadCredential*|SetCredential*|ImportCredential*|StateDirectory*|CacheDirectory*|LogsDirectory*|\
                ConfigurationDirectory*|RuntimeDirectory*|Type|PIDFile|BusName)
                    return 0 ;;
            esac ;;
        path)
            case "$key" in PathExists|PathExistsGlob|PathChanged|PathModified|DirectoryNotEmpty|Unit|MakeDirectory)
                return 0 ;;
            esac ;;
        timer)
            case "$key" in OnActiveSec|OnBootSec|OnStartupSec|OnUnitActiveSec|OnUnitInactiveSec|OnCalendar|Unit|Persistent|RandomizedDelaySec)
                return 0 ;;
            esac ;;
    esac
    return 1
}

systemd_global_dropin_has_managed_override() {
    local dir="$1" type="$2" conf line section key
    local -a files=()
    [[ -e "$dir" || -L "$dir" ]] || return 1
    [[ -d "$dir" && ! -L "$dir" ]] || return 0
    shopt -s nullglob
    files=("$dir"/*.conf)
    shopt -u nullglob
    for conf in "${files[@]}"; do
        [[ -f "$conf" && ! -L "$conf" ]] || return 0
        section=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -n "$line" && "$line" != \#* && "$line" != \;* ]] || continue
            if [[ "$line" == \[*\] ]]; then
                section="$line"
                continue
            fi
            case "$type:$section" in
                service:'[Service]'|path:'[Path]'|timer:'[Timer]') ;;
                *) continue ;;
            esac
            [[ "$line" == *=* ]] || continue
            key="${line%%=*}"
            key="${key//[[:space:]]/}"
            systemd_global_dropin_key_is_managed "$type" "$key" && return 0
        done < "$conf"
    done
    return 1
}

systemd_unit_has_dropins() {
    local unit="$1" root name type="${1##*.}" global
    shift
    local -a roots=("$@")
    SYSTEMD_UNIT_CONFLICT_REASON=""
    if [[ "${#roots[@]}" == 0 ]]; then
        roots=(/etc/systemd/system.control /run/systemd/system.control \
               /run/systemd/transient /run/systemd/generator.early \
               /etc/systemd/system /etc/systemd/system.attached \
               /run/systemd/system /run/systemd/system.attached \
               /run/systemd/generator /usr/local/lib/systemd/system \
               /usr/lib/systemd/system /lib/systemd/system \
               /run/systemd/generator.late)
    fi
    for root in "${roots[@]}"; do
        while IFS= read -r name; do
            if [[ -e "${root}/${name}" || -L "${root}/${name}" ]]; then
                SYSTEMD_UNIT_CONFLICT_REASON="drop-in directory ${root}/${name}"
                return 0
            fi
        done < <(systemd_unit_specific_dropin_names "$unit")
        global="${root}/${type}.d"
        if systemd_global_dropin_has_managed_override "$global" "$type"; then
            SYSTEMD_UNIT_CONFLICT_REASON="managed directive in global drop-in directory ${global}"
            return 0
        fi
        case "$root" in
            /etc/systemd/system.control|/run/systemd/system.control|/run/systemd/transient|/run/systemd/generator.early)
                if [[ -e "${root}/${unit}" || -L "${root}/${unit}" ]]; then
                    SYSTEMD_UNIT_CONFLICT_REASON="control or transient unit ${root}/${unit}"
                    return 0
                fi ;;
        esac
    done
    return 1
}

journal_export_instances_clear() {
    local unit root
    local -a roots=("$@")
    if [[ "${#roots[@]}" == 0 ]]; then
        roots=(/etc/systemd/system.control /run/systemd/system.control \
               /run/systemd/transient /run/systemd/generator.early \
               /etc/systemd/system /etc/systemd/system.attached \
               /run/systemd/system /run/systemd/system.attached \
               /run/systemd/generator /usr/local/lib/systemd/system \
               /usr/lib/systemd/system /lib/systemd/system \
               /run/systemd/generator.late)
    fi
    for unit in 5gpn-journal@5gpn-dns.service 5gpn-journal@mihomo.service; do
        systemd_unit_has_dropins "$unit" "${roots[@]}" && return 1
        for root in "${roots[@]}"; do
            [[ ! -e "${root}/${unit}" && ! -L "${root}/${unit}" ]] \
                || return 1
        done
    done
}

unit_file_owned_by_5gpn() {
    local unit="$1" file="/etc/systemd/system/$1"
    SYSTEMD_UNIT_CONFLICT_REASON=""
    [[ -f "$file" && ! -L "$file" ]] || return 1
    ! systemd_unit_has_dropins "$unit" || return 1
    grep -Fqx "# 5gpn-unit-id: ${unit}:v1" "$file" || return 1
    case "$unit" in
        5gpn-dns.service)
            grep -Fqx 'EnvironmentFile=/etc/5gpn/dns.env' "$file" \
                && grep -Fqx 'ExecStart=/opt/5gpn/bin/5gpn-dns' "$file" ;;
        mihomo.service)
            grep -Fqx 'ExecStart=/opt/5gpn/bin/mihomo -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo' "$file" ;;
        5gpn-intercept.service)
            grep -Fqx 'ExecStart=/opt/5gpn/bin/5gpn-intercept --config /etc/5gpn/intercept/config.json' "$file" ;;
        5gpn-intercept-cert.service)
            grep -Fqx 'ExecStart=/opt/5gpn/scripts/intercept-cert-renew.sh' "$file" ;;
        5gpn-intercept-cert.path)
            grep -Fqx 'PathChanged=/etc/5gpn/intercept/config.json' "$file" ;;
        5gpn-intercept-cert.timer)
            grep -Fqx 'OnCalendar=*-*-* 02:00:00' "$file" \
                && grep -Fqx 'Persistent=true' "$file" \
                && grep -Fqx 'Unit=5gpn-intercept-cert.service' "$file" ;;
        5gpn-intercept-runtime.path)
            grep -Fqx 'PathChanged=/etc/5gpn/intercept/config.json' "$file" \
                && grep -Fqx 'Unit=5gpn-intercept.service' "$file" ;;
        5gpn-journal@.service)
            grep -Fqx 'ExecStart=/opt/5gpn/scripts/export-journal.sh %i' "$file" \
                && journal_export_instances_clear ;;
        5gpn-certbot-renew.service)
            grep -Fqx 'ExecStart=/opt/5gpn/scripts/cert-renew.sh --quiet' "$file" ;;
        5gpn-certbot-renew.timer)
            grep -Fqx 'OnCalendar=*-*-* 03:00:00' "$file" \
                && grep -Fqx 'Persistent=true' "$file" ;;
        *) return 1 ;;
    esac
}

preflight_owned_units() {
    local unit
    for unit in "$@"; do
        if systemctl cat "$unit" >/dev/null 2>&1 || [[ -e "/etc/systemd/system/$unit" ]]; then
            unit_file_owned_by_5gpn "$unit" \
                || { err "Refusing to replace an existing non-5gpn or overridden unit: $unit${SYSTEMD_UNIT_CONFLICT_REASON:+ ($SYSTEMD_UNIT_CONFLICT_REASON)}"; return 1; }
        fi
    done
}

remove_owned_unit() {
    local unit="$1"
    if unit_file_owned_by_5gpn "$unit"; then
        systemctl disable --now "$unit" 2>/dev/null \
            || { err "Could not stop and disable owned unit $unit; refusing to delete its unit file."; return 1; }
        rm -f -- "/etc/systemd/system/$unit" \
            || { err "Could not delete owned unit file: $unit"; return 1; }
        [[ ! -e "/etc/systemd/system/$unit" && ! -L "/etc/systemd/system/$unit" ]] \
            || { err "Owned unit file still exists after removal: $unit"; return 1; }
        ok "Removed 5gpn-owned unit: $unit"
        return 0
    fi
    if systemctl cat "$unit" >/dev/null 2>&1 || [[ -e "/etc/systemd/system/$unit" ]]; then
        warn "Preserving unowned unit: $unit"
    fi
}

preflight_renewal_unit_ownership() {
    preflight_owned_units 5gpn-certbot-renew.service 5gpn-certbot-renew.timer
}

service_group_is_exclusive_for_user() {
    local group="$1" user="$2" entry gid members passwd_entries primary_users group_entries gid_groups gid_members
    entry="$(getent group "$group" 2>/dev/null)" || return 1
    gid="$(printf '%s\n' "$entry" | cut -d: -f3)"
    members="$(printf '%s\n' "$entry" | cut -d: -f4)"
    [[ "$gid" =~ ^[0-9]+$ && -z "$members" ]] || return 1
    group_entries="$(getent group 2>/dev/null)" || return 1
    gid_groups="$(printf '%s\n' "$group_entries" | awk -F: -v gid="$gid" '$3 == gid { print $1 }')"
    gid_members="$(printf '%s\n' "$group_entries" | awk -F: -v gid="$gid" '$3 == gid && $4 != "" { print $1 }')"
    [[ "$gid_groups" == "$group" && -z "$gid_members" ]] || return 1
    passwd_entries="$(getent passwd 2>/dev/null)" || return 1
    primary_users="$(printf '%s\n' "$passwd_entries" | awk -F: -v gid="$gid" '$4 == gid { print $1 }')"
    [[ -z "$primary_users" || "$primary_users" == "$user" ]]
}

service_account_is_safe() {
    local user="$1" group="$2" entry uid home shell primary primary_gid user_groups uid_min
    local group_entry group_gid members passwd_entries primary_users uid_users group_entries gid_groups gid_members
    entry="$(getent passwd "$user" 2>/dev/null)" || return 1
    group_entry="$(getent group "$group" 2>/dev/null)" || return 1
    uid="$(printf '%s\n' "$entry" | cut -d: -f3)"
    home="$(printf '%s\n' "$entry" | cut -d: -f6)"
    shell="$(printf '%s\n' "$entry" | cut -d: -f7)"
    group_gid="$(printf '%s\n' "$group_entry" | cut -d: -f3)"
    members="$(printf '%s\n' "$group_entry" | cut -d: -f4)"
    primary="$(id -gn "$user" 2>/dev/null)" || return 1
    primary_gid="$(id -g "$user" 2>/dev/null)" || return 1
    user_groups="$(id -G "$user" 2>/dev/null)" || return 1
    passwd_entries="$(getent passwd 2>/dev/null)" || return 1
    primary_users="$(printf '%s\n' "$passwd_entries" | awk -F: -v gid="$group_gid" '$4 == gid { print $1 }')"
    uid_users="$(printf '%s\n' "$passwd_entries" | awk -F: -v uid="$uid" '$3 == uid { print $1 }')"
    group_entries="$(getent group 2>/dev/null)" || return 1
    gid_groups="$(printf '%s\n' "$group_entries" | awk -F: -v gid="$group_gid" '$3 == gid { print $1 }')"
    gid_members="$(printf '%s\n' "$group_entries" | awk -F: -v gid="$group_gid" '$3 == gid && $4 != "" { print $1 }')"
    uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null)"
    uid_min="${uid_min:-1000}"
    [[ "$uid" =~ ^[0-9]+$ && "$uid_min" =~ ^[0-9]+$ \
       && "$uid" -gt 0 && "$uid" -lt "$uid_min" ]] || return 1
    [[ "$group_gid" =~ ^[0-9]+$ && "$primary_gid" == "$group_gid" ]] || return 1
    [[ "$home" == /nonexistent && "$primary" == "$group" ]] || return 1
    [[ -z "$members" && "$primary_users" == "$user" && "$uid_users" == "$user" \
       && "$gid_groups" == "$group" && -z "$gid_members" \
       && "$user_groups" == "$group_gid" ]] || return 1
    case "$shell" in */nologin|/bin/false) ;; *) return 1 ;; esac
}

service_account_name_is_valid() {
    [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

ensure_service_account() {
    local user="$1" group="$2" user_created_name="${3:-}" group_created_name="${4:-}"
    local uid_created_name="${5:-}" gid_created_name="${6:-}"
    local nologin group_created=0 user_created=0 user_preexists=0 account_uid="" account_gid=""
    [[ -z "$user_created_name" ]] || printf -v "$user_created_name" '%s' 0
    [[ -z "$group_created_name" ]] || printf -v "$group_created_name" '%s' 0
    [[ -z "$uid_created_name" ]] || printf -v "$uid_created_name" '%s' ''
    [[ -z "$gid_created_name" ]] || printf -v "$gid_created_name" '%s' ''
    service_account_name_is_valid "$user" && service_account_name_is_valid "$group" \
        || { err "Invalid strict service account name: $user/$group"; return 1; }
    if getent passwd "$user" >/dev/null 2>&1; then
        user_preexists=1
    fi
    if getent group "$group" >/dev/null 2>&1; then
        service_group_is_exclusive_for_user "$group" "$user" \
            || { err "Refusing shared service group: $group"; return 1; }
    else
        [[ "$user_preexists" == 0 ]] \
            || { err "Refusing a pre-existing service account without its named primary group: $user/$group"; return 1; }
        groupadd --system "$group" || return 1
        group_created=1
        account_gid="$(getent group "$group" 2>/dev/null | cut -d: -f3 || true)"
        [[ -z "$group_created_name" ]] || printf -v "$group_created_name" '%s' "$group_created"
        [[ -z "$gid_created_name" ]] || printf -v "$gid_created_name" '%s' "$account_gid"
        if ! service_group_is_exclusive_for_user "$group" "$user"; then
            groupdel "$group" 2>/dev/null || true
            err "Refusing non-exclusive service group: $group"
            return 1
        fi
    fi
    if [[ "$user_preexists" == 1 ]]; then
        if ! service_account_is_safe "$user" "$group"; then
            [[ "$group_created" == 0 ]] || groupdel "$group" 2>/dev/null || true
            err "Refusing incompatible pre-existing service account: $user"
            return 1
        fi
    else
        nologin="$(command -v nologin 2>/dev/null || true)"
        nologin="${nologin:-/usr/sbin/nologin}"
        if ! useradd --system --gid "$group" --home-dir /nonexistent --shell "$nologin" \
            --no-create-home "$user"; then
            [[ "$group_created" == 0 ]] || groupdel "$group" 2>/dev/null || true
            return 1
        fi
        user_created=1
        account_uid="$(id -u "$user" 2>/dev/null || true)"
        if [[ -z "$account_gid" ]]; then
            account_gid="$(id -g "$user" 2>/dev/null || true)"
        fi
        [[ -z "$user_created_name" ]] || printf -v "$user_created_name" '%s' "$user_created"
        [[ -z "$group_created_name" ]] || printf -v "$group_created_name" '%s' "$group_created"
        [[ -z "$uid_created_name" ]] || printf -v "$uid_created_name" '%s' "$account_uid"
        [[ -z "$gid_created_name" ]] || printf -v "$gid_created_name" '%s' "$account_gid"
        if ! service_account_is_safe "$user" "$group"; then
            userdel "$user" 2>/dev/null || true
            [[ "$group_created" == 0 ]] || groupdel "$group" 2>/dev/null || true
            return 1
        fi
    fi
    if [[ "$user_created" == 1 || "$group_created" == 1 ]]; then
        account_uid="$(id -u "$user" 2>/dev/null || true)"
        account_gid="$(id -g "$user" 2>/dev/null || true)"
        if [[ ! "$account_uid" =~ ^[0-9]+$ || ! "$account_gid" =~ ^[0-9]+$ ]]; then
            [[ "$user_created" == 0 ]] || userdel "$user" 2>/dev/null || true
            [[ "$group_created" == 0 ]] || groupdel "$group" 2>/dev/null || true
            err "Could not record the created service account identity: $user/$group"
            return 1
        fi
    fi
    [[ -z "$user_created_name" ]] || printf -v "$user_created_name" '%s' "$user_created"
    [[ -z "$group_created_name" ]] || printf -v "$group_created_name" '%s' "$group_created"
    [[ -z "$uid_created_name" ]] || printf -v "$uid_created_name" '%s' "$account_uid"
    [[ -z "$gid_created_name" ]] || printf -v "$gid_created_name" '%s' "$account_gid"
}

install_service_account() {
    local user="$1" group="$2"
    local created_user_flag=0 created_group_flag=0 created_uid_value="" created_gid_value="" result=0
    ensure_service_account "$user" "$group" created_user_flag created_group_flag \
        created_uid_value created_gid_value || result=$?
    if [[ "$created_user_flag" == 1 || "$created_group_flag" == 1 ]]; then
        CREATED_SERVICE_ACCOUNT_USERS+=("$user")
        CREATED_SERVICE_ACCOUNT_GROUPS+=("$group")
        CREATED_SERVICE_ACCOUNT_UIDS+=("$created_uid_value")
        CREATED_SERVICE_ACCOUNT_GIDS+=("$created_gid_value")
        CREATED_SERVICE_ACCOUNT_USER_FLAGS+=("$created_user_flag")
        CREATED_SERVICE_ACCOUNT_GROUP_FLAGS+=("$created_group_flag")
    fi
    return "$result"
}

install_service_accounts() {
    command -v getent >/dev/null 2>&1 \
        && command -v groupadd >/dev/null 2>&1 \
        && command -v useradd >/dev/null 2>&1 \
        && command -v groupdel >/dev/null 2>&1 \
        && command -v userdel >/dev/null 2>&1 \
        || { err "getent and service account management tools are required for service isolation."; return 1; }
    install_service_account "$DNS_SERVICE_USER" "$DNS_SERVICE_USER" || return 1
    install_service_account "$MIHOMO_SERVICE_USER" "$MIHOMO_SERVICE_USER" || return 1
    install_service_account "$INTERCEPT_SERVICE_USER" "$INTERCEPT_SERVICE_USER" || return 1
    ok "Dedicated service accounts are ready: ${DNS_SERVICE_USER}, ${MIHOMO_SERVICE_USER}, ${INTERCEPT_SERVICE_USER}."
}

polkit_rule_owned_by_5gpn() {
    [[ -f "$POLKIT_RULE_PATH" && ! -L "$POLKIT_RULE_PATH" ]] \
        && grep -Fqx "$POLKIT_RULE_MARKER" "$POLKIT_RULE_PATH"
}

preflight_polkit_rule_ownership() {
    [[ ! -e "$POLKIT_RULE_PATH" ]] || polkit_rule_owned_by_5gpn \
        || { err "Refusing to replace an unowned polkit rule: $POLKIT_RULE_PATH"; return 1; }
}

install_polkit_rule() {
    local src candidate
    preflight_polkit_rule_ownership || return 1
    if [[ -f "${SCRIPT_DIR}/etc/polkit-1/rules.d/50-5gpn.rules" ]]; then
        src="${SCRIPT_DIR}/etc/polkit-1/rules.d/50-5gpn.rules"
    elif [[ -f "${BASE_DIR}/etc/polkit-1/rules.d/50-5gpn.rules" ]]; then
        src="${BASE_DIR}/etc/polkit-1/rules.d/50-5gpn.rules"
    else
        err "The fixed 5gpn polkit rule is missing."
        return 1
    fi
    install -d -o root -g root -m 0755 "$(dirname -- "$POLKIT_RULE_PATH")" || return 1
    candidate="$(mktemp "$(dirname -- "$POLKIT_RULE_PATH")/.50-5gpn.rules.XXXXXX")" || return 1
    install -o root -g root -m 0644 "$src" "$candidate" \
        || { rm -f -- "$candidate"; return 1; }
    mv -f -- "$candidate" "$POLKIT_RULE_PATH"
}

remove_owned_renewal_automation() {
    remove_owned_unit 5gpn-certbot-renew.timer || return 1
    remove_owned_unit 5gpn-certbot-renew.service || return 1
    systemctl daemon-reload 2>/dev/null \
        || { err "Could not reload systemd after removing certificate renewal units."; return 1; }
}
install_deps() {
    info "Installing dependencies..."
    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || true
            apt-get install -y -qq \
                wget curl ca-certificates unzip iproute2 openssl \
                qrencode jq libcap2-bin util-linux polkitd \
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
                qrencode jq util-linux polkit \
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
    for cmd in curl openssl tar gzip unzip sha256sum ip flock timeout; do
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
ROLLBACK_SNAPSHOT_READY=0
ROLLBACK_IN_PROGRESS=0
PRESERVE_ROLLBACK_STAGE=0
PRETRANSACTION_ROOTS_ACTIVE=0
BASE_ROOT_WAS_ABSENT=0
CONF_ROOT_WAS_ABSENT=0
STATE_ROOT_WAS_ABSENT=0
POSTCOMMIT_TIMER_RESTORE_PENDING=0
INSTALL_PHASE="initialization"
INSTALL_FAILURE_REPORTED=0

# Unit files are snapshotted only for project-owned units. Runtime state also
# includes the distro Certbot timer because an owned-lineage install may
# deliberately coordinate it, but the installer never replaces its unit file.
TRANSACTION_UNIT_FILES=(
    5gpn-dns.service
    5gpn-intercept.service
    5gpn-intercept-cert.service
    5gpn-intercept-cert.path
    5gpn-intercept-cert.timer
    5gpn-intercept-runtime.path
    mihomo.service
    5gpn-journal@.service
    5gpn-certbot-renew.service
    5gpn-certbot-renew.timer
)
TRANSACTION_STATE_UNITS=(
    mihomo.service
    5gpn-intercept.service
    5gpn-dns.service
    5gpn-intercept-cert.path
    5gpn-intercept-cert.timer
    5gpn-intercept-runtime.path
    5gpn-intercept-cert.service
    5gpn-certbot-renew.service
    5gpn-certbot-renew.timer
    certbot.timer
)
TRANSACTION_STOP_UNITS=(
    certbot.timer
    5gpn-certbot-renew.timer
    5gpn-intercept-cert.timer
    5gpn-intercept-cert.path
    5gpn-intercept-runtime.path
    5gpn-certbot-renew.service
    5gpn-intercept-cert.service
    5gpn-dns.service
    5gpn-intercept.service
    mihomo.service
)

sha256_of() { sha256sum "$1" | awk '{print tolower($1)}'; }

verify_sha256() {
    local file="$1" expected="${2,,}" got
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] \
        || { err "Missing/invalid pinned SHA-256 for $(basename "$file")."; return 1; }
    got="$(sha256_of "$file")"
    [[ "$got" == "$expected" ]] \
        || { err "SHA-256 mismatch for $(basename "$file") (want $expected got $got)."; return 1; }
}

# A release version declaration is one exact LF-terminated byte sequence.
# Bytewise comparison rejects NULs that shell line readers would silently drop.
release_tag_file_matches() {
    local file="$1" expected="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(file_nlink "$file")" == 1 ]] || return 1
    printf '%s\n' "$expected" | cmp -s - "$file"
}

binary_reports_exact_version() {
    local binary="$1" flag="$2" expected="$3" output result=1
    [[ -d "$ARTIFACT_STAGE" && ! -L "$ARTIFACT_STAGE" ]] || return 1
    output="$(mktemp "${ARTIFACT_STAGE}/.version-output.XXXXXX")" || return 1
    chmod 0600 "$output" || { rm -f -- "$output"; return 1; }
    if "$binary" "$flag" > "$output" 2>/dev/null \
       && release_tag_file_matches "$output" "$expected"; then
        result=0
    fi
    rm -f -- "$output" || return 1
    return "$result"
}

# Upstream mihomo prints build metadata and feature tags as well as its release
# version. Require its documented amd64 first-line shape, then compare the
# complete version token rather than accepting a substring match.
mihomo_reports_exact_version() {
    local binary="$1" expected="$2" output first actual result=1
    [[ -d "$ARTIFACT_STAGE" && ! -L "$ARTIFACT_STAGE" ]] || return 1
    output="$(mktemp "${ARTIFACT_STAGE}/.mihomo-version.XXXXXX")" || return 1
    chmod 0600 "$output" || { rm -f -- "$output"; return 1; }
    "$binary" -v > "$output" 2>/dev/null \
        || { rm -f -- "$output"; return 1; }
    LC_ALL=C tr -d '\000' < "$output" | cmp -s - "$output" \
        || { rm -f -- "$output"; return 1; }
    IFS= read -r first < "$output" \
        || { rm -f -- "$output"; return 1; }
    [[ "$first" != *$'\r'* ]] || { rm -f -- "$output"; return 1; }
    [[ "$first" =~ ^Mihomo\ Meta\ ([^[:space:]]+)\ linux\ amd64\ with\ go[^[:space:]]+\ .+$ ]] \
        && actual="${BASH_REMATCH[1]}" \
        && [[ "$actual" == "$expected" ]] \
        && result=0
    rm -f -- "$output" || return 1
    return "$result"
}

release_checksum() {
    local sums="$1" asset="$2"
    awk -v f="$asset" '$2 == f || $2 == "*" f { print tolower($1); exit }' "$sums"
}

valid_dns_stable_release_tag() {
    local tag="$1"
    local number='(0|[1-9][0-9]*)'
    [[ "$tag" =~ ^${number}\.${number}\.${number}$ ]]
}

valid_dns_beta_release_tag() {
    local tag="$1"
    local number='(0|[1-9][0-9]*)'
    [[ "$tag" =~ ^${number}\.${number}\.${number}-beta\.([1-9][0-9]*)$ ]]
}

valid_dns_release_tag() {
    valid_dns_stable_release_tag "$1" || valid_dns_beta_release_tag "$1"
}

dns_release_json_tag() {
    sed -n 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$1"
}

dns_beta_tags_from_release_list() {
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+"' "$1" 2>/dev/null \
        | sed -E 's/^.*"([^"]+)"$/\1/' || true
}

resolve_dns_latest_beta_version() { # optional list and exact-metadata URLs are internal test seams
    local list_url="${1:-${DNS_RELEASES_API}?per_page=100}"
    local metadata_url="${2:-}"
    local list_json metadata_json candidate="" tag metadata_tag

    list_json="$(mktemp /tmp/5gpn-dns-beta-releases.XXXXXX)" || return 1
    if ! curl -fsSL "$list_url" -o "$list_json"; then
        rm -f -- "$list_json"
        err "Could not list 5gpn prereleases."
        return 1
    fi
    while IFS= read -r tag; do
        if valid_dns_beta_release_tag "$tag"; then
            candidate="$tag"
            break
        fi
    done < <(dns_beta_tags_from_release_list "$list_json")
    rm -f -- "$list_json"
    [[ -n "$candidate" ]] \
        || { err "No published 5gpn beta release is available."; return 1; }

    metadata_url="${metadata_url:-${DNS_RELEASES_API}/tags/${candidate}}"
    metadata_json="$(mktemp /tmp/5gpn-dns-beta-release.XXXXXX)" || return 1
    if ! curl -fsSL "$metadata_url" -o "$metadata_json"; then
        rm -f -- "$metadata_json"
        err "Could not verify beta release ${candidate}."
        return 1
    fi
    metadata_tag="$(dns_release_json_tag "$metadata_json")"
    if [[ "$metadata_tag" != "$candidate" ]] \
       || ! grep -Eq '"draft"[[:space:]]*:[[:space:]]*false' "$metadata_json" \
       || ! grep -Eq '"prerelease"[[:space:]]*:[[:space:]]*true' "$metadata_json"; then
        rm -f -- "$metadata_json"
        err "Latest beta candidate is not a published GitHub prerelease."
        return 1
    fi
    rm -f -- "$metadata_json"
    printf '%s\n' "$candidate"
}

resolve_dns_release_version() { # optional stable/list/metadata URLs are internal test seams
    local requested="$DNS_VERSION_DEFAULT"
    local api_url="${1:-$DNS_STABLE_RELEASE_API}"
    local beta_list_url="${2:-}"
    local beta_metadata_url="${3:-}"
    local json tags

    if [[ "$requested" != latest ]]; then
        if valid_dns_stable_release_tag "$requested"; then
            if [[ "$DNS_RELEASE_CHANNEL_EXPLICIT" == 1 && "$DNS_RELEASE_CHANNEL" == beta ]]; then
                err "A beta install cannot use an official-release installer bundle."
                return 1
            fi
            printf '%s\n' "$requested"
            return 0
        fi
        if valid_dns_beta_release_tag "$requested"; then
            if [[ "$DNS_RELEASE_CHANNEL_EXPLICIT" == 1 && "$DNS_RELEASE_CHANNEL" != beta ]]; then
                err "A beta installer bundle requires the beta release channel."
                return 1
            fi
            printf '%s\n' "$requested"
            return 0
        fi
        err "Installer has an invalid pinned release tag."
        return 1
    fi

    if [[ "$DNS_RELEASE_CHANNEL" == beta ]]; then
        resolve_dns_latest_beta_version "$beta_list_url" "$beta_metadata_url"
        return
    fi
    [[ "$DNS_RELEASE_CHANNEL" == stable ]] \
        || { err "Unknown 5gpn release channel: $DNS_RELEASE_CHANNEL"; return 1; }
    json="$(curl -fsSL "$api_url")" \
        || { err "Could not resolve the latest official 5gpn release."; return 1; }
    tags="$(printf '%s\n' "$json" | sed -n 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p')"
    [[ -n "$tags" && "$tags" != *$'\n'* ]] \
        || { err "Latest official release response has no unique tag."; return 1; }
    valid_dns_stable_release_tag "$tags" \
        || { err "Latest official release returned an unsafe or non-official tag."; return 1; }
    printf '%s\n' "$tags"
}

archive_paths_safe() {
    local kind="$1" archive="$2" entry normalized names verbose types
    local name_count type_count
    declare -A seen=()
    if [[ "$kind" == tar ]]; then
        names="$(tar -tzf "$archive" 2>/dev/null)" || return 1
        verbose="$(tar -tvzf "$archive" 2>/dev/null)" || return 1
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || return 1
            normalized="$entry"
            while [[ "$normalized" == ./* ]]; do normalized="${normalized#./}"; done
            normalized="${normalized%/}"
            [[ -z "$normalized" ]] && continue
            [[ "$normalized" != /* && "$normalized" != ../* \
                && "$normalized" != *'/../'* && "$normalized" != */.. \
                && "$normalized" != *'\'* ]] || return 1
            case "/$normalized/" in
                */"$TEMP_OWNERSHIP_MARKER"/*|*/"$BASE_OWNERSHIP_MARKER"/*) return 1 ;;
            esac
            [[ -z "${seen[$normalized]+x}" ]] || return 1
            seen[$normalized]=1
        done <<< "$names"
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            case "${entry:0:1}" in -|d) ;; *) return 1 ;; esac
        done <<< "$verbose"
    else
        names="$(unzip -Z1 "$archive" 2>/dev/null)" || return 1
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || return 1
            normalized="${entry%/}"
            [[ -n "$normalized" && "$normalized" != /* && "$normalized" != ../* \
                && "$normalized" != *'/../'* && "$normalized" != */.. \
                && "$normalized" != *'\'* ]] || return 1
            case "/$normalized/" in
                */"$TEMP_OWNERSHIP_MARKER"/*|*/"$BASE_OWNERSHIP_MARKER"/*) return 1 ;;
            esac
            [[ -z "${seen[$normalized]+x}" ]] || return 1
            seen[$normalized]=1
        done <<< "$names"
        verbose="$(unzip -Z -l "$archive" 2>/dev/null)" || return 1
        types="$(printf '%s\n' "$verbose" | awk '/^[-dlcbps][rwxstST-]{9}[[:space:]]/ { print substr($0,1,1) }')"
        name_count="$(printf '%s\n' "$names" | awk 'NF { n++ } END { print n+0 }')"
        type_count="$(printf '%s\n' "$types" | awk 'NF { n++ } END { print n+0 }')"
        [[ "$name_count" == "$type_count" && "$name_count" -gt 0 ]] || return 1
        [[ -z "$(printf '%s\n' "$types" | grep -Ev '^[-d]$' || true)" ]] || return 1
    fi
}

extracted_tree_safe() {
    local root="$1"
    [[ -d "$root" && ! -L "$root" ]] || return 1
    [[ -z "$(find "$root" -mindepth 1 -type l -print -quit 2>/dev/null)" ]] || return 1
    [[ -z "$(find "$root" -mindepth 1 ! -type f ! -type d -print -quit 2>/dev/null)" ]] || return 1
    [[ -z "$(find "$root" -mindepth 1 -type f -links +1 -print -quit 2>/dev/null)" ]] || return 1
}

stage_artifacts() {
    local ver release
    local dns_asset intercept_asset web_asset
    ver="$(resolve_dns_release_version)" || return 1
    DNS_VERSION_DEFAULT="$ver"
    release="https://github.com/moooyo/5gpn/releases/download/${ver}"
    dns_asset="5gpn-dns-linux-amd64"
    intercept_asset="5gpn-intercept-linux-amd64"
    web_asset="5gpn-web-${ver}.tar.gz"
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
    binary_reports_exact_version "$ARTIFACT_STAGE/5gpn-dns" --version "$ver" \
        || { err "Staged 5gpn-dns version does not match pinned release ${ver}."; return 1; }

    curl -fsSL "$release/$intercept_asset" -o "$ARTIFACT_STAGE/5gpn-intercept" \
        || { err "Could not download $intercept_asset."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/5gpn-intercept" \
        "$(release_checksum "$ARTIFACT_STAGE/checksums.txt" "$intercept_asset")" || return 1
    chmod 0755 "$ARTIFACT_STAGE/5gpn-intercept"
    binary_reports_exact_version "$ARTIFACT_STAGE/5gpn-intercept" --version "$ver" \
        || { err "Staged 5gpn-intercept version does not match pinned release ${ver}."; return 1; }

    curl -fsSL "$release/$web_asset" -o "$ARTIFACT_STAGE/web.tgz" \
        || { err "Could not download $web_asset."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/web.tgz" \
        "$(release_checksum "$ARTIFACT_STAGE/checksums.txt" "$web_asset")" || return 1
    archive_paths_safe tar "$ARTIFACT_STAGE/web.tgz" \
        || { err "Unsafe path in web archive."; return 1; }
    mkdir "$ARTIFACT_STAGE/web"
    tar --no-same-owner --no-same-permissions --delay-directory-restore \
        -xzf "$ARTIFACT_STAGE/web.tgz" -C "$ARTIFACT_STAGE/web"
    extracted_tree_safe "$ARTIFACT_STAGE/web" \
        || { err "Unsafe object found after web archive extraction."; return 1; }
    [[ -f "$ARTIFACT_STAGE/web/index.html" ]] \
        || { err "Staged web archive has no index.html."; return 1; }
    release_tag_file_matches "$ARTIFACT_STAGE/web/.web_version" "$ver" \
        || { err "Staged web archive version does not match pinned release ${ver}."; return 1; }

    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz" \
        -o "$ARTIFACT_STAGE/mihomo.gz" || { err "Could not download mihomo ${MIHOMO_VERSION}."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/mihomo.gz" "$MIHOMO_SHA256" || return 1
    gzip -dc "$ARTIFACT_STAGE/mihomo.gz" > "$ARTIFACT_STAGE/mihomo"
    chmod 0755 "$ARTIFACT_STAGE/mihomo"
    mihomo_reports_exact_version "$ARTIFACT_STAGE/mihomo" "$MIHOMO_VERSION" \
        || { err "Staged mihomo version does not match pinned release ${MIHOMO_VERSION}."; return 1; }

    curl -fsSL "https://github.com/Zephyruso/zashboard/releases/download/${ZASH_VERSION}/dist.zip" \
        -o "$ARTIFACT_STAGE/zash.zip" || { err "Could not download zashboard ${ZASH_VERSION}."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/zash.zip" "$ZASH_SHA256" || return 1
    archive_paths_safe zip "$ARTIFACT_STAGE/zash.zip" \
        || { err "Unsafe path in zashboard archive."; return 1; }
    mkdir "$ARTIFACT_STAGE/zash"
    unzip -qo "$ARTIFACT_STAGE/zash.zip" -d "$ARTIFACT_STAGE/zash"
    extracted_tree_safe "$ARTIFACT_STAGE/zash" \
        || { err "Unsafe object found after zashboard archive extraction."; return 1; }
    if [[ -f "$ARTIFACT_STAGE/zash/dist/index.html" ]]; then
        mv "$ARTIFACT_STAGE/zash/dist"/* "$ARTIFACT_STAGE/zash/"
        rmdir "$ARTIFACT_STAGE/zash/dist"
    fi
    [[ -f "$ARTIFACT_STAGE/zash/index.html" ]] \
        || { err "Staged zashboard archive has no index.html."; return 1; }

    if [[ ! -f "$MIHOMO_DIR/config.yaml" ]]; then
        local seed="$ARTIFACT_STAGE/mihomo-seed.yaml" line listeners
        listeners="$(render_mihomo_listeners "$MIHOMO_LISTEN_IPS" "$CONSOLE_DOMAIN")"
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == '__MIHOMO_LISTENERS__' ]]; then
                printf '%s\n' "$listeners"
                continue
            fi
            line="${line//__GATEWAY_IP__/$GATEWAY_IP}"
            line="${line//__CONSOLE_DOMAIN__/$CONSOLE_DOMAIN}"
            line="${line//__ZASH_DOMAIN__/$ZASH_DOMAIN}"
            line="${line//__CONTROLLER_SECRET__/preflight-only-secret}"
            line="${line//__INTERCEPT_INBOUND_USERNAME__/preflight-inbound-user}"
            line="${line//__INTERCEPT_INBOUND_PASSWORD__/preflight-inbound-password-123456}"
            line="${line//__INTERCEPT_UPSTREAM_USERNAME__/preflight-upstream-user}"
            line="${line//__INTERCEPT_UPSTREAM_PASSWORD__/preflight-upstream-password-123456}"
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

ensure_private_lock_dir() {
    local lock_dir; lock_dir="$(dirname -- "$INSTALL_LOCK_FILE")"
    if [[ ! -e "$lock_dir" ]]; then
        install -d -o root -g root -m 0700 "$lock_dir" \
            || { err "Could not create the installer lock directory."; return 1; }
    fi
    [[ -d "$lock_dir" && ! -L "$lock_dir" \
       && "$(readlink -f -- "$lock_dir" 2>/dev/null || true)" == "$lock_dir" \
       && "$(file_uid "$lock_dir")" == 0 \
       && "$(file_mode "$lock_dir")" == 700 ]] \
        || { err "Unsafe installer lock directory: ${lock_dir}"; return 1; }
}

lock_file_safe() {
    local lock_file="$1"
    [[ ! -e "$lock_file" ]] && return 0
    [[ -f "$lock_file" && ! -L "$lock_file" \
       && "$(file_uid "$lock_file")" == 0 ]]
}

lock_fd_targets_file() {
    local fd="$1" lock_file="$2" fd_identity file_identity
    [[ -e "/proc/${BASHPID}/fd/${fd}" && -f "$lock_file" && ! -L "$lock_file" ]] || return 1
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/self/fd/${fd}" 2>/dev/null || true)"
    file_identity="$(stat -Lc '%d:%i' -- "$lock_file" 2>/dev/null || true)"
    [[ -n "$fd_identity" && "$fd_identity" == "$file_identity" ]]
}

wait_for_exclusive_lock() {
    local fd="$1" timeout="$2" subject="$3"
    local waited=0 remaining slice
    [[ "$timeout" =~ ^[1-9][0-9]*$ \
       && "$LOCK_WAIT_REPORT_INTERVAL" =~ ^[1-9][0-9]*$ ]] || return 2
    if flock -n "$fd"; then
        return 0
    fi
    info "${subject} is active; waiting up to ${timeout}s for its transaction lock."
    while (( waited < timeout )); do
        remaining=$((timeout - waited))
        slice="$LOCK_WAIT_REPORT_INTERVAL"
        (( slice <= remaining )) || slice="$remaining"
        if flock -w "$slice" "$fd"; then
            info "${subject} released its transaction lock; continuing."
            return 0
        fi
        waited=$((waited + slice))
        if (( waited < timeout )); then
            info "Still waiting for ${subject} (${waited}s elapsed, $((timeout - waited))s remaining)..."
        fi
    done
    return 1
}

acquire_install_lock() {
    command -v flock >/dev/null 2>&1 \
        || { err "flock is required for installer transaction exclusion."; return 1; }
    ensure_private_lock_dir || return 1
    lock_file_safe "$INSTALL_LOCK_FILE" \
        || { err "Unsafe installer transaction lock file: ${INSTALL_LOCK_FILE}"; return 1; }
    if lock_fd_targets_file 7 "$INSTALL_LOCK_FILE"; then
        flock -w "$INSTALL_LOCK_WAIT_TIMEOUT" 7 \
            || { err "Timed out revalidating the installer transaction lock."; return 1; }
        INSTALL_LOCK_HELD=1
        return 0
    fi
    exec 7>&- 2>/dev/null || true
    exec 7>"$INSTALL_LOCK_FILE"
    chmod 0600 "$INSTALL_LOCK_FILE" \
        || { exec 7>&-; err "Could not protect the installer transaction lock file."; return 1; }
    wait_for_exclusive_lock 7 "$INSTALL_LOCK_WAIT_TIMEOUT" \
        "Another 5gpn install, configure, or uninstall transaction" \
        || { exec 7>&-; err "Timed out waiting for the 5gpn installer transaction lock."; return 1; }
    INSTALL_LOCK_HELD=1
}

release_install_lock() {
    local rc=0
    if [[ "$INSTALL_LOCK_HELD" == 1 ]]; then
        lock_fd_targets_file 7 "$INSTALL_LOCK_FILE" || rc=1
        flock -u 7 2>/dev/null || rc=1
    fi
    exec 7>&- 2>/dev/null || true
    INSTALL_LOCK_HELD=0
    [[ "$rc" == 0 ]] || { err "The installer transaction lock descriptor was invalid during release."; return 1; }
}

run_management_with_install_lock() (
    local rc
    acquire_install_lock || exit $?
    trap 'rc=$?; trap - EXIT HUP INT TERM; release_install_lock || true; exit "$rc"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@"
)

run_management_with_install_and_cert_lock() (
    local rc
    acquire_install_lock || exit $?
    trap 'rc=$?; trap - EXIT HUP INT TERM; release_install_cert_lock || true; release_install_lock || true; exit "$rc"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    acquire_install_cert_lock || exit $?
    "$@"
)

acquire_install_cert_lock() {
    command -v flock >/dev/null 2>&1 \
        || { err "flock is required for certificate-operation exclusion."; return 1; }
    lock_fd_targets_file 7 "$INSTALL_LOCK_FILE" \
        || { err "The installer transaction lock must be held before the certificate lock."; return 1; }
    flock -n 7 \
        || { err "The installer transaction lock is no longer held."; return 1; }
    INSTALL_LOCK_HELD=1
    ensure_private_lock_dir || return 1
    lock_file_safe "$CERT_RENEW_LOCK_FILE" \
        || { err "Unsafe certificate-renewal lock file: ${CERT_RENEW_LOCK_FILE}"; return 1; }
    if lock_fd_targets_file 8 "$CERT_RENEW_LOCK_FILE"; then
        flock -w "$CERT_LOCK_WAIT_TIMEOUT" 8 \
            || { err "Timed out revalidating the certificate-renewal lock."; return 1; }
        INSTALL_CERT_LOCK_HELD=1
        return 0
    fi
    exec 8>&- 2>/dev/null || true
    exec 8>"$CERT_RENEW_LOCK_FILE"
    chmod 0600 "$CERT_RENEW_LOCK_FILE" \
        || { exec 8>&-; err "Could not protect the certificate-renewal lock file."; return 1; }
    wait_for_exclusive_lock 8 "$CERT_LOCK_WAIT_TIMEOUT" \
        "Another 5gpn certificate update" \
        || { exec 8>&-; \
             err "Another certificate update still holds the transaction lock after ${CERT_LOCK_WAIT_TIMEOUT}s."; \
             err "Existing certificates are preserved, but they do not bypass concurrent certificate publication safety."; \
             err "Installation stopped before live publication; inspect 5gpn certificate services and retry."; \
             return 1; }
    INSTALL_CERT_LOCK_HELD=1
}

release_install_cert_lock() {
    local rc=0
    if [[ "$INSTALL_CERT_LOCK_HELD" == 1 ]]; then
        lock_fd_targets_file 8 "$CERT_RENEW_LOCK_FILE" || rc=1
        flock -u 8 2>/dev/null || rc=1
    fi
    exec 8>&- 2>/dev/null || true
    INSTALL_CERT_LOCK_HELD=0
    [[ "$rc" == 0 ]] || { err "The certificate lock descriptor was invalid during release."; return 1; }
}

record_project_root_prestate() {
    BASE_ROOT_WAS_ABSENT=0
    CONF_ROOT_WAS_ABSENT=0
    STATE_ROOT_WAS_ABSENT=0
    POSTCOMMIT_TIMER_RESTORE_PENDING=0
    [[ -e "$BASE_DIR" || -L "$BASE_DIR" ]] || BASE_ROOT_WAS_ABSENT=1
    [[ -e "$CONF_DIR" || -L "$CONF_DIR" ]] || CONF_ROOT_WAS_ABSENT=1
    [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]] || STATE_ROOT_WAS_ABSENT=1
    PRETRANSACTION_ROOTS_ACTIVE=1
}

cleanup_pretransaction_project_roots() {
    local failed_name="$1"
    local -n failed_ref="$failed_name"
    [[ "$PRETRANSACTION_ROOTS_ACTIVE" == 1 ]] || return 0
    if [[ "$STATE_ROOT_WAS_ABSENT" == 1 && ( -e "$STATE_DIR" || -L "$STATE_DIR" ) ]]; then
        remove_fixed_owned_dir "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" \
            || failed_ref=1
    fi
    if [[ "$CONF_ROOT_WAS_ABSENT" == 1 && ( -e "$CONF_DIR" || -L "$CONF_DIR" ) ]]; then
        remove_fixed_owned_dir "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
            || failed_ref=1
    fi
    if [[ "$BASE_ROOT_WAS_ABSENT" == 1 && ( -e "$BASE_DIR" || -L "$BASE_DIR" ) ]]; then
        remove_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
            || failed_ref=1
    fi
    [[ "$failed_ref" != 0 ]] || PRETRANSACTION_ROOTS_ACTIVE=0
}

capture_optional_owned_root() {
    local dir="$1" marker="$2" value="$3" name="$4"
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        : > "$ROLLBACK_DIR/${name}.absent"
        return 0
    fi
    owned_root_canonical "$dir" "$marker" "$value" >/dev/null \
        || { err "Cannot capture unowned rollback root: $dir"; return 1; }
    cp -a -- "$dir" "$ROLLBACK_DIR/$name"
}

capture_managed_unit_states() {
    local unit enabled_state active_state fragment_path load_state enabled_rc active_rc
    install -d -m 0700 "$ROLLBACK_DIR/unit-state" || return 1
    for unit in "${TRANSACTION_STATE_UNITS[@]}"; do
        load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
        [[ -n "$load_state" ]] \
            || { err "Could not determine systemd load state for $unit."; return 1; }
        if [[ -n "$load_state" && "$load_state" != not-found ]]; then
            : > "$ROLLBACK_DIR/unit-state/${unit}.exists" || return 1
        else
            : > "$ROLLBACK_DIR/unit-state/${unit}.absent" || return 1
        fi
        if enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null)"; then
            enabled_rc=0
        else
            enabled_rc=$?
        fi
        if active_state="$(systemctl is-active "$unit" 2>/dev/null)"; then
            active_rc=0
        else
            active_rc=$?
        fi
        fragment_path="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
        [[ "$enabled_state" != *$'\n'* && "$active_state" != *$'\n'* \
           && "$fragment_path" != *$'\n'* ]] || return 1
        case "${enabled_state:-not-found}" in
            enabled|enabled-runtime|masked|masked-runtime|static|indirect|disabled|not-found) ;;
            *) err "Unsupported systemd enablement state for $unit: ${enabled_state:-empty}"; return 1 ;;
        esac
        if [[ "$load_state" == not-found ]]; then
            [[ "${enabled_state:-not-found}" == not-found \
               && ( "${active_state:-unknown}" == inactive || "${active_state:-unknown}" == unknown ) ]] \
                || { err "Inconsistent absent-unit state for $unit."; return 1; }
        else
            [[ "$enabled_state" != not-found \
               && ( "$active_state" == active || "$active_state" == inactive ) ]] \
                || { err "Unstable systemd state for $unit (${enabled_state:-empty}/${active_state:-empty}); retry when it is active or inactive."; return 1; }
        fi
        printf '%s\n' "${enabled_state:-not-found}" \
            > "$ROLLBACK_DIR/unit-state/${unit}.enabled-state" || return 1
        printf '%s\n' "${active_state:-unknown}" \
            > "$ROLLBACK_DIR/unit-state/${unit}.active-state" || return 1
        printf '%s\n' "$fragment_path" \
            > "$ROLLBACK_DIR/unit-state/${unit}.fragment-path" || return 1
        if [[ "$enabled_rc" == 0 ]]; then
            : > "$ROLLBACK_DIR/unit-state/${unit}.enabled" || return 1
            # Keep the legacy path while older rollback tests and snapshots are
            # still consumed by pre-release installers.
            : > "$ROLLBACK_DIR/units/${unit}.enabled" || return 1
        else
            : > "$ROLLBACK_DIR/unit-state/${unit}.disabled" || return 1
            : > "$ROLLBACK_DIR/units/${unit}.disabled" || return 1
        fi
        if [[ "$active_rc" == 0 ]]; then
            : > "$ROLLBACK_DIR/unit-state/${unit}.active" || return 1
            : > "$ROLLBACK_DIR/units/${unit}.active" || return 1
        else
            : > "$ROLLBACK_DIR/unit-state/${unit}.inactive" || return 1
            : > "$ROLLBACK_DIR/units/${unit}.inactive" || return 1
        fi
    done
}

stop_units_for_install_snapshot() {
    local unit
    for unit in "${TRANSACTION_STOP_UNITS[@]}"; do
        [[ -f "$ROLLBACK_DIR/unit-state/${unit}.exists" ]] || continue
        systemctl stop "$unit" >/dev/null 2>&1 \
            || { err "Could not stop $unit before the install snapshot."; return 1; }
        ! systemctl is-active --quiet "$unit" 2>/dev/null \
            || { err "$unit remained active before the install snapshot."; return 1; }
    done
    if systemctl is-active --quiet certbot.service 2>/dev/null; then
        err "certbot.service is active after its timer was stopped; retry after that external renewal completes."
        return 1
    fi
}

snapshot_has_exactly_one_file() {
    local first="$1" second="$2" count=0
    [[ -f "$first" && ! -L "$first" ]] && count=$((count + 1))
    [[ -f "$second" && ! -L "$second" ]] && count=$((count + 1))
    [[ "$count" == 1 ]]
}

snapshot_has_dir_or_absent() {
    local dir="$1" absent="$2" count=0
    [[ -d "$dir" && ! -L "$dir" ]] && count=$((count + 1))
    [[ -f "$absent" && ! -L "$absent" ]] && count=$((count + 1))
    [[ "$count" == 1 ]]
}

snapshot_has_exactly_one_public_tree_state() {
    local owned="$1" empty="$2" absent="$3" count=0
    [[ -d "$owned" && ! -L "$owned" ]] && count=$((count + 1))
    [[ -d "$empty" && ! -L "$empty" ]] && count=$((count + 1))
    [[ -f "$absent" && ! -L "$absent" ]] && count=$((count + 1))
    [[ "$count" == 1 ]]
}

empty_unowned_public_tree_is_safe() {
    local dir="$1" marker="$2" entry
    root_owned_nonwritable_directory_is_safe "$dir" || return 1
    [[ ! -e "$dir/$marker" && ! -L "$dir/$marker" ]] || return 1
    entry="$(find "$dir" -mindepth 1 -print -quit 2>/dev/null)" || return 1
    [[ -z "$entry" ]]
}

validate_install_rollback_snapshot() {
    local unit b seen=" "
    [[ -d "$ROLLBACK_DIR" && ! -L "$ROLLBACK_DIR" \
       && -f "$ROLLBACK_DIR/.complete" && ! -L "$ROLLBACK_DIR/.complete" \
       && "$(cat "$ROLLBACK_DIR/.complete" 2>/dev/null || true)" == 5gpn-install-rollback-v2 \
       && -d "$ROLLBACK_DIR/units" && ! -L "$ROLLBACK_DIR/units" \
       && -d "$ROLLBACK_DIR/unit-state" && ! -L "$ROLLBACK_DIR/unit-state" \
       && -d "$ROLLBACK_DIR/polkit" && ! -L "$ROLLBACK_DIR/polkit" \
       && -d "$ROLLBACK_DIR/renewal-conf" && ! -L "$ROLLBACK_DIR/renewal-conf" \
       && -f "$ROLLBACK_DIR/renewal-names" && ! -L "$ROLLBACK_DIR/renewal-names" ]] \
        || return 1
    snapshot_has_dir_or_absent "$ROLLBACK_DIR/base" "$ROLLBACK_DIR/base.absent" || return 1
    snapshot_has_dir_or_absent "$ROLLBACK_DIR/conf" "$ROLLBACK_DIR/conf.absent" || return 1
    snapshot_has_exactly_one_file "$ROLLBACK_DIR/state.present" "$ROLLBACK_DIR/state.absent" || return 1
    [[ ! -d "$ROLLBACK_DIR/base" ]] \
        || verify_ownership_marker "$ROLLBACK_DIR/base" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" || return 1
    [[ ! -d "$ROLLBACK_DIR/conf" ]] \
        || verify_ownership_marker "$ROLLBACK_DIR/conf" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" || return 1
    snapshot_has_exactly_one_file "$ROLLBACK_DIR/launcher" "$ROLLBACK_DIR/launcher.absent" || return 1
    snapshot_has_exactly_one_file "$ROLLBACK_DIR/polkit/50-5gpn.rules" \
        "$ROLLBACK_DIR/polkit/50-5gpn.rules.absent" || return 1
    snapshot_has_exactly_one_file "$ROLLBACK_DIR/renew-hook" "$ROLLBACK_DIR/renew-hook.absent" || return 1
    snapshot_has_dir_or_absent "$ROLLBACK_DIR/intercept-ca" "$ROLLBACK_DIR/intercept-ca.absent" || return 1
    snapshot_has_dir_or_absent "$ROLLBACK_DIR/intercept-state" "$ROLLBACK_DIR/intercept-state.absent" || return 1
    [[ ! -d "$ROLLBACK_DIR/intercept-ca" ]] \
        || verify_ownership_marker "$ROLLBACK_DIR/intercept-ca" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" || return 1
    [[ ! -d "$ROLLBACK_DIR/intercept-state" ]] \
        || verify_ownership_marker "$ROLLBACK_DIR/intercept-state" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" || return 1
    for unit in "${TRANSACTION_UNIT_FILES[@]}"; do
        snapshot_has_exactly_one_file "$ROLLBACK_DIR/units/$unit" "$ROLLBACK_DIR/units/$unit.absent" || return 1
    done
    for unit in "${TRANSACTION_STATE_UNITS[@]}"; do
        snapshot_has_exactly_one_file "$ROLLBACK_DIR/unit-state/${unit}.exists" \
            "$ROLLBACK_DIR/unit-state/${unit}.absent" || return 1
        [[ -f "$ROLLBACK_DIR/unit-state/${unit}.enabled-state" \
           && ! -L "$ROLLBACK_DIR/unit-state/${unit}.enabled-state" \
           && -f "$ROLLBACK_DIR/unit-state/${unit}.active-state" \
           && ! -L "$ROLLBACK_DIR/unit-state/${unit}.active-state" \
           && -f "$ROLLBACK_DIR/unit-state/${unit}.fragment-path" \
           && ! -L "$ROLLBACK_DIR/unit-state/${unit}.fragment-path" ]] || return 1
        if [[ -f "$ROLLBACK_DIR/unit-state/${unit}.exists" ]]; then
            grep -Eq '^(enabled|enabled-runtime|masked|masked-runtime|static|indirect|disabled)$' \
                "$ROLLBACK_DIR/unit-state/${unit}.enabled-state" || return 1
            grep -Eq '^(active|inactive)$' "$ROLLBACK_DIR/unit-state/${unit}.active-state" || return 1
        else
            grep -Eq '^not-found$' "$ROLLBACK_DIR/unit-state/${unit}.enabled-state" || return 1
            grep -Eq '^(inactive|unknown)$' "$ROLLBACK_DIR/unit-state/${unit}.active-state" || return 1
        fi
        snapshot_has_exactly_one_file "$ROLLBACK_DIR/unit-state/${unit}.enabled" \
            "$ROLLBACK_DIR/unit-state/${unit}.disabled" || return 1
        snapshot_has_exactly_one_file "$ROLLBACK_DIR/unit-state/${unit}.active" \
            "$ROLLBACK_DIR/unit-state/${unit}.inactive" || return 1
    done
    while IFS= read -r b; do
        is_valid_domain "$b" || return 1
        case "$seen" in *" $b "*) return 1 ;; *) seen+="$b " ;; esac
        snapshot_has_exactly_one_file "$ROLLBACK_DIR/renewal-conf/${b}.conf" \
            "$ROLLBACK_DIR/renewal-conf/${b}.absent" || return 1
        snapshot_has_exactly_one_file "$ROLLBACK_DIR/renewal-conf/${b}.lineage-present" \
            "$ROLLBACK_DIR/renewal-conf/${b}.lineage-absent" || return 1
        if [[ -f "$ROLLBACK_DIR/renewal-conf/${b}.lineage-present" ]]; then
            [[ -d "$ROLLBACK_DIR/le-live/${b}" && ! -L "$ROLLBACK_DIR/le-live/${b}" \
               && -d "$ROLLBACK_DIR/le-archive/${b}" && ! -L "$ROLLBACK_DIR/le-archive/${b}" \
               && -s "$ROLLBACK_DIR/lineage-leaf/${b}/fullchain.pem" \
               && -f "$ROLLBACK_DIR/lineage-leaf/${b}/fullchain.pem" \
               && ! -L "$ROLLBACK_DIR/lineage-leaf/${b}/fullchain.pem" \
               && -s "$ROLLBACK_DIR/lineage-leaf/${b}/privkey.pem" \
               && -f "$ROLLBACK_DIR/lineage-leaf/${b}/privkey.pem" \
               && ! -L "$ROLLBACK_DIR/lineage-leaf/${b}/privkey.pem" ]] || return 1
        fi
    done < "$ROLLBACK_DIR/renewal-names"
    if [[ "$DNS_WEB_DIR" != "$BASE_DIR"/* ]]; then
        snapshot_has_exactly_one_public_tree_state "$ROLLBACK_DIR/external-web" \
            "$ROLLBACK_DIR/external-web.empty-unowned" "$ROLLBACK_DIR/external-web.absent" || return 1
        [[ ! -d "$ROLLBACK_DIR/external-web" ]] \
            || verify_ownership_marker "$ROLLBACK_DIR/external-web" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE" || return 1
        if [[ -d "$ROLLBACK_DIR/external-web.empty-unowned" ]]; then
            empty_unowned_public_tree_is_safe "$ROLLBACK_DIR/external-web.empty-unowned" \
                "$WEB_OWNERSHIP_MARKER" || return 1
        fi
    fi
    if [[ "$DNS_ZASH_DIR" != "$BASE_DIR"/* ]]; then
        snapshot_has_exactly_one_public_tree_state "$ROLLBACK_DIR/external-zash" \
            "$ROLLBACK_DIR/external-zash.empty-unowned" "$ROLLBACK_DIR/external-zash.absent" || return 1
        [[ ! -d "$ROLLBACK_DIR/external-zash" ]] \
            || verify_ownership_marker "$ROLLBACK_DIR/external-zash" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1' || return 1
        if [[ -d "$ROLLBACK_DIR/external-zash.empty-unowned" ]]; then
            empty_unowned_public_tree_is_safe "$ROLLBACK_DIR/external-zash.empty-unowned" \
                "$ZASH_OWNERSHIP_MARKER" || return 1
        fi
    fi
}

capture_install_rollback() {
    ROLLBACK_DIR="$ARTIFACT_STAGE/rollback"
    local unit
    info "Capturing the pre-install rollback snapshot before live publication..."
    install -d -m 0700 "$ROLLBACK_DIR" "$ROLLBACK_DIR/units" \
        || { err "Could not create the rollback snapshot directories."; return 1; }
    for unit in "${TRANSACTION_UNIT_FILES[@]}"; do
        if [[ -e "/etc/systemd/system/$unit" || -L "/etc/systemd/system/$unit" ]]; then
            [[ -f "/etc/systemd/system/$unit" && ! -L "/etc/systemd/system/$unit" ]] \
                || { err "Unsafe managed unit path before rollback capture: /etc/systemd/system/$unit"; return 1; }
            cp -p -- "/etc/systemd/system/$unit" "$ROLLBACK_DIR/units/$unit" \
                || { err "Could not snapshot the managed unit file: $unit"; return 1; }
        else
            : > "$ROLLBACK_DIR/units/$unit.absent" \
                || { err "Could not record the absent managed unit: $unit"; return 1; }
        fi
    done
    capture_managed_unit_states \
        || { err "Could not capture the complete systemd state for the rollback snapshot."; return 1; }
    INSTALL_TRANSACTION_ACTIVE=1
    ROLLBACK_SNAPSHOT_READY=0
    stop_units_for_install_snapshot || return 1
    if [[ -s "$CONF_DIR/dns.env" ]]; then
        validate_dns_env_schema \
            || { err "dns.env changed before the transaction fence; refusing a stale snapshot."; return 1; }
    fi
    mihomo_config_matches_install_config \
        || { err "The operator-owned mihomo config changed before the transaction fence; refusing a stale snapshot."; return 1; }

    # Daemons that can rewrite operator state are now stopped. Snapshot live
    # files only after this fence so a rollback never overwrites a later daemon
    # write that raced the copy.
    if [[ "$BASE_ROOT_WAS_ABSENT" == 1 ]]; then
        : > "$ROLLBACK_DIR/base.absent" || return 1
    else
        cp -a -- "$BASE_DIR" "$ROLLBACK_DIR/base" || return 1
    fi
    if [[ "$CONF_ROOT_WAS_ABSENT" == 1 ]]; then
        : > "$ROLLBACK_DIR/conf.absent" || return 1
    else
        cp -a -- "$CONF_DIR" "$ROLLBACK_DIR/conf" || return 1
    fi
    if [[ "$STATE_ROOT_WAS_ABSENT" == 1 ]]; then
        : > "$ROLLBACK_DIR/state.absent" || return 1
    else
        : > "$ROLLBACK_DIR/state.present" || return 1
    fi
    if [[ -e /usr/local/bin/5gpn || -L /usr/local/bin/5gpn ]]; then
        launcher_owned \
            || { err "Refusing to snapshot an unowned /usr/local/bin/5gpn launcher."; return 1; }
        cp -p -- /usr/local/bin/5gpn "$ROLLBACK_DIR/launcher" || return 1
    else
        : > "$ROLLBACK_DIR/launcher.absent" || return 1
    fi
    capture_optional_owned_root "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" \
        "$INTERCEPT_CA_MARKER_VALUE" intercept-ca || return 1
    capture_optional_owned_root "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" \
        "$INTERCEPT_STATE_MARKER_VALUE" intercept-state || return 1
    install -d -m 0700 "$ROLLBACK_DIR/polkit" || return 1
    if [[ -e "$POLKIT_RULE_PATH" || -L "$POLKIT_RULE_PATH" ]]; then
        polkit_rule_owned_by_5gpn \
            || { err "Unsafe polkit rule appeared before rollback capture: $POLKIT_RULE_PATH"; return 1; }
        cp -p -- "$POLKIT_RULE_PATH" "$ROLLBACK_DIR/polkit/50-5gpn.rules" || return 1
    else
        : > "$ROLLBACK_DIR/polkit/50-5gpn.rules.absent" || return 1
    fi
    if [[ -e /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh \
       || -L /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh ]]; then
        renew_hook_owned \
            || { err "Unsafe Certbot deploy hook before rollback capture."; return 1; }
        cp -p -- /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh "$ROLLBACK_DIR/renew-hook" || return 1
    else
        : > "$ROLLBACK_DIR/renew-hook.absent" || return 1
    fi
    # A certificate-method switch rewrites this scoped Certbot renewal file.
    # Snapshot both the currently persisted base and the newly selected base so
    # a later publication failure cannot leave dns.env and the authenticator in
    # different modes. No other host lineage is read or touched.
    install -d -m 0700 "$ROLLBACK_DIR/renewal-conf" || return 1
    local old_base selected_base b seen="" conf_present live_present archive_present present_count
    old_base="$(cfg_get DNS_BASE_DOMAIN)" || return 1
    selected_base="${BASE_DOMAIN:-}"
    : > "$ROLLBACK_DIR/renewal-names" || return 1
    for b in "$old_base" "$selected_base"; do
        b="$(printf '%s' "${b%.}" | tr '[:upper:]' '[:lower:]')" || return 1
        is_valid_domain "$b" || continue
        case " $seen " in *" $b "*) continue ;; esac
        seen+=" $b"
        printf '%s\n' "$b" >> "$ROLLBACK_DIR/renewal-names" || return 1
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
            cp -p -- "/etc/letsencrypt/renewal/${b}.conf" "$ROLLBACK_DIR/renewal-conf/${b}.conf" || return 1
        elif [[ -e "/etc/letsencrypt/renewal/${b}.conf" || -L "/etc/letsencrypt/renewal/${b}.conf" ]]; then
            err "Refusing unsafe Certbot renewal config path: /etc/letsencrypt/renewal/${b}.conf"
            return 1
        else
            : > "$ROLLBACK_DIR/renewal-conf/${b}.absent" || return 1
        fi
        if [[ "$live_present" == 1 ]]; then
            : > "$ROLLBACK_DIR/renewal-conf/${b}.lineage-present" || return 1
            [[ -d "/etc/letsencrypt/live/${b}" && ! -L "/etc/letsencrypt/live/${b}" \
               && -d "/etc/letsencrypt/archive/${b}" && ! -L "/etc/letsencrypt/archive/${b}" \
               && -s "/etc/letsencrypt/live/${b}/fullchain.pem" \
               && -s "/etc/letsencrypt/live/${b}/privkey.pem" ]] \
                || { err "Existing Certbot lineage ${b} has an unsafe or incomplete layout; refusing transactional replacement."; return 1; }
            install -d -m 0700 "$ROLLBACK_DIR/le-live" "$ROLLBACK_DIR/le-archive" "$ROLLBACK_DIR/lineage-leaf/${b}" || return 1
            cp -a -- "/etc/letsencrypt/live/${b}" "$ROLLBACK_DIR/le-live/${b}" || return 1
            cp -a -- "/etc/letsencrypt/archive/${b}" "$ROLLBACK_DIR/le-archive/${b}" || return 1
            cp -L -- "/etc/letsencrypt/live/${b}/fullchain.pem" "$ROLLBACK_DIR/lineage-leaf/${b}/fullchain.pem" || return 1
            cp -L -- "/etc/letsencrypt/live/${b}/privkey.pem" "$ROLLBACK_DIR/lineage-leaf/${b}/privkey.pem" || return 1
        else
            : > "$ROLLBACK_DIR/renewal-conf/${b}.lineage-absent" || return 1
        fi
    done
    if [[ "$DNS_WEB_DIR" != "$BASE_DIR"/* ]]; then
        if [[ -e "$DNS_WEB_DIR" || -L "$DNS_WEB_DIR" ]]; then
            if verify_ownership_marker "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"; then
                static_owned_tree_is_safe "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE" \
                    || { err "Cannot capture unsafe external web root: $DNS_WEB_DIR"; return 1; }
                cp -a -- "$DNS_WEB_DIR" "$ROLLBACK_DIR/external-web" || return 1
            else
                empty_unowned_public_tree_is_safe "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" \
                    || { err "Cannot capture non-empty or unsafe unowned web root: $DNS_WEB_DIR"; return 1; }
                cp -a -- "$DNS_WEB_DIR" "$ROLLBACK_DIR/external-web.empty-unowned" || return 1
            fi
        else
            : > "$ROLLBACK_DIR/external-web.absent" || return 1
        fi
    fi
    if [[ "$DNS_ZASH_DIR" != "$BASE_DIR"/* ]]; then
        if [[ -e "$DNS_ZASH_DIR" || -L "$DNS_ZASH_DIR" ]]; then
            if verify_ownership_marker "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1'; then
                static_owned_tree_is_safe "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER" '5gpn-zashboard-v1' \
                    || { err "Cannot capture unsafe external zashboard root: $DNS_ZASH_DIR"; return 1; }
                cp -a -- "$DNS_ZASH_DIR" "$ROLLBACK_DIR/external-zash" || return 1
            else
                empty_unowned_public_tree_is_safe "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER" \
                    || { err "Cannot capture non-empty or unsafe unowned zashboard root: $DNS_ZASH_DIR"; return 1; }
                cp -a -- "$DNS_ZASH_DIR" "$ROLLBACK_DIR/external-zash.empty-unowned" || return 1
            fi
        else
            : > "$ROLLBACK_DIR/external-zash.absent" || return 1
        fi
    fi
    printf '%s\n' 5gpn-install-rollback-v2 > "$ROLLBACK_DIR/.complete" || return 1
    validate_install_rollback_snapshot \
        || { rm -f -- "$ROLLBACK_DIR/.complete" 2>/dev/null || true; err "Rollback snapshot completeness validation failed."; return 1; }
    ROLLBACK_SNAPSHOT_READY=1
    ok "Pre-install rollback snapshot captured and validated."
}

restore_optional_owned_root() {
    local dir="$1" marker="$2" value="$3" name="$4" failed_name="$5"
    local -n failed_ref="$failed_name"
    [[ "$failed_ref" == 0 ]] || return 0
    if [[ -e "$dir" || -L "$dir" ]]; then
        if verify_ownership_marker "$dir" "$marker" "$value"; then
            remove_fixed_owned_dir "$dir" "$marker" "$value" || failed_ref=1
        else
            warn "Could not restore $dir because its live path is no longer 5gpn-owned."
            failed_ref=1
        fi
    fi
    [[ "$failed_ref" == 0 ]] || return 0
    if [[ -f "$ROLLBACK_DIR/${name}.absent" ]]; then
        return 0
    fi
    [[ -d "$ROLLBACK_DIR/$name" ]] \
        || { warn "Rollback snapshot for $dir is missing."; failed_ref=1; return 0; }
    cp -a -- "$ROLLBACK_DIR/$name" "$dir" || failed_ref=1
}

restore_config_root_without_intercept_ca() {
    local failed_name="$1" source
    local -n failed_ref="$failed_name"
    if ! verify_ownership_marker "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"; then
        warn "Could not restore the config root because its live ownership marker changed."
        failed_ref=1
        return 0
    fi
    clear_owned_scope "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" intercept-ca || { failed_ref=1; return 0; }
    (
        shopt -s dotglob nullglob
        for source in "$ROLLBACK_DIR/conf"/*; do
            [[ "$(basename -- "$source")" == intercept-ca ]] && continue
            cp -a -- "$source" "$CONF_DIR/" || exit 1
        done
    ) || failed_ref=1
    [[ "$failed_ref" != 0 ]] \
        || chown --reference="$ROLLBACK_DIR/conf" "$CONF_DIR" || failed_ref=1
    [[ "$failed_ref" != 0 ]] \
        || chmod --reference="$ROLLBACK_DIR/conf" "$CONF_DIR" || failed_ref=1
}

rollback_created_service_accounts() {
    local failed_name="$1" count index user group recorded_uid recorded_gid user_flag group_flag
    local current_uid current_gid user_groups group_entry members passwd_entries primary_users
    local -n failed_ref="$failed_name"
    count="${#CREATED_SERVICE_ACCOUNT_USERS[@]}"
    if [[ "${#CREATED_SERVICE_ACCOUNT_GROUPS[@]}" != "$count" \
       || "${#CREATED_SERVICE_ACCOUNT_UIDS[@]}" != "$count" \
       || "${#CREATED_SERVICE_ACCOUNT_GIDS[@]}" != "$count" \
       || "${#CREATED_SERVICE_ACCOUNT_USER_FLAGS[@]}" != "$count" \
       || "${#CREATED_SERVICE_ACCOUNT_GROUP_FLAGS[@]}" != "$count" ]]; then
        warn "Refusing service-account rollback because its creation registry is inconsistent."
        failed_ref=1
        return 0
    fi
    for (( index=count - 1; index >= 0; index-- )); do
        user="${CREATED_SERVICE_ACCOUNT_USERS[index]}"
        group="${CREATED_SERVICE_ACCOUNT_GROUPS[index]}"
        recorded_uid="${CREATED_SERVICE_ACCOUNT_UIDS[index]}"
        recorded_gid="${CREATED_SERVICE_ACCOUNT_GIDS[index]}"
        user_flag="${CREATED_SERVICE_ACCOUNT_USER_FLAGS[index]}"
        group_flag="${CREATED_SERVICE_ACCOUNT_GROUP_FLAGS[index]}"
        if ! service_account_name_is_valid "$user" || ! service_account_name_is_valid "$group" \
           || [[ ! "$user_flag" =~ ^[01]$ || ! "$group_flag" =~ ^[01]$ ]] \
           || [[ "$user_flag" == 0 && "$group_flag" == 0 ]]; then
            warn "Refusing an invalid service-account rollback registry entry."
            failed_ref=1
            continue
        fi
        if [[ ! "$recorded_gid" =~ ^[0-9]+$ \
           || ( "$user_flag" == 1 && ! "$recorded_uid" =~ ^[0-9]+$ ) ]]; then
            warn "Refusing a service-account rollback entry without its recorded identity."
            failed_ref=1
            continue
        fi
        if [[ "$user_flag" == 1 ]] && getent passwd "$user" >/dev/null 2>&1; then
            current_uid="$(id -u "$user" 2>/dev/null || true)"
            current_gid="$(id -g "$user" 2>/dev/null || true)"
            user_groups="$(id -G "$user" 2>/dev/null || true)"
            if [[ "$current_uid" == "$recorded_uid" \
               && "$current_gid" == "$recorded_gid" \
               && "$user_groups" == "$recorded_gid" ]] \
               && service_account_is_safe "$user" "$group"; then
                if ! userdel "$user" 2>/dev/null \
                   || getent passwd "$user" >/dev/null 2>&1; then
                    warn "Could not remove the service user created by this run: $user"
                    failed_ref=1
                fi
            else
                warn "Refusing to remove a changed service user: $user"
                failed_ref=1
            fi
        fi
        if [[ "$group_flag" == 1 ]] && getent group "$group" >/dev/null 2>&1; then
            group_entry="$(getent group "$group" 2>/dev/null || true)"
            current_gid="$(printf '%s\n' "$group_entry" | cut -d: -f3)"
            members="$(printf '%s\n' "$group_entry" | cut -d: -f4)"
            passwd_entries="$(getent passwd 2>/dev/null)" || passwd_entries="__enumeration_failed__"
            primary_users="$(printf '%s\n' "$passwd_entries" | awk -F: -v gid="$current_gid" '$4 == gid { print $1 }')"
            if [[ "$passwd_entries" != __enumeration_failed__ \
               && "$current_gid" == "$recorded_gid" \
               && -z "$members" && -z "$primary_users" ]]; then
                if ! groupdel "$group" 2>/dev/null \
                   || getent group "$group" >/dev/null 2>&1; then
                    warn "Could not remove the service group created by this run: $group"
                    failed_ref=1
                fi
            else
                warn "Refusing to remove a changed or non-empty service group: $group"
                failed_ref=1
            fi
        fi
    done
    CREATED_SERVICE_ACCOUNT_USERS=()
    CREATED_SERVICE_ACCOUNT_GROUPS=()
    CREATED_SERVICE_ACCOUNT_UIDS=()
    CREATED_SERVICE_ACCOUNT_GIDS=()
    CREATED_SERVICE_ACCOUNT_USER_FLAGS=()
    CREATED_SERVICE_ACCOUNT_GROUP_FLAGS=()
}

atomic_restore_regular_file() {
    local source="$1" dest="$2" candidate
    [[ -f "$source" && ! -L "$source" ]] || return 1
    [[ -d "$(dirname -- "$dest")" && ! -L "$(dirname -- "$dest")" ]] || return 1
    candidate="$(mktemp "$(dirname -- "$dest")/.$(basename -- "$dest").rollback.XXXXXX")" \
        || return 1
    if ! cp -p -- "$source" "$candidate" || ! mv -f -- "$candidate" "$dest"; then
        rm -f -- "$candidate" 2>/dev/null || true
        return 1
    fi
}

restore_managed_unit_files() {
    local failed_name="$1" unit live candidate
    local -n failed_ref="$failed_name"
    [[ -d /etc/systemd/system && ! -L /etc/systemd/system ]] \
        || { warn "Unsafe systemd unit root during rollback."; failed_ref=1; return 0; }
    for unit in "${TRANSACTION_UNIT_FILES[@]}"; do
        live="/etc/systemd/system/$unit"
        if [[ -f "$ROLLBACK_DIR/units/$unit" && ! -L "$ROLLBACK_DIR/units/$unit" ]]; then
            if [[ -e "$live" || -L "$live" ]]; then
                unit_file_owned_by_5gpn "$unit" \
                    || { warn "Refusing to overwrite a changed unit during rollback: $unit"; failed_ref=1; continue; }
            fi
            atomic_restore_regular_file "$ROLLBACK_DIR/units/$unit" "$live" \
                || { warn "Could not restore unit file: $unit"; failed_ref=1; }
        elif [[ -f "$ROLLBACK_DIR/units/$unit.absent" ]]; then
            if [[ -e "$live" || -L "$live" ]]; then
                if unit_file_owned_by_5gpn "$unit"; then
                    rm -f -- "$live" \
                        || { warn "Could not remove newly installed unit: $unit"; failed_ref=1; }
                else
                    warn "Refusing to remove a changed unit during rollback: $unit"
                    failed_ref=1
                fi
            fi
        else
            warn "Rollback snapshot is missing the unit state for $unit."
            failed_ref=1
        fi
    done
}

restore_management_launcher() {
    local failed_name="$1" launcher=/usr/local/bin/5gpn
    local -n failed_ref="$failed_name"
    if [[ -f "$ROLLBACK_DIR/launcher" && ! -L "$ROLLBACK_DIR/launcher" ]]; then
        if [[ -e "$launcher" || -L "$launcher" ]]; then
            launcher_owned \
                || { warn "Refusing to overwrite a changed management launcher during rollback."; failed_ref=1; return 0; }
        fi
        atomic_restore_regular_file "$ROLLBACK_DIR/launcher" "$launcher" \
            || { failed_ref=1; return 0; }
        launcher_owned || failed_ref=1
    elif [[ -f "$ROLLBACK_DIR/launcher.absent" ]]; then
        if [[ -e "$launcher" || -L "$launcher" ]]; then
            if launcher_owned; then
                rm -f -- "$launcher" || failed_ref=1
            else
                warn "Refusing to remove a changed management launcher during rollback."
                failed_ref=1
            fi
        fi
    else
        warn "Rollback snapshot is missing the management-launcher state."
        failed_ref=1
    fi
}

restore_renew_hook() {
    local failed_name="$1" hook="/etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh"
    local -n failed_ref="$failed_name"
    if [[ -f "$ROLLBACK_DIR/renew-hook" && ! -L "$ROLLBACK_DIR/renew-hook" ]]; then
        if [[ -e "$hook" || -L "$hook" ]]; then
            renew_hook_owned \
                || { warn "Refusing to overwrite a changed Certbot deploy hook during rollback."; failed_ref=1; return 0; }
        fi
        install -d -o root -g root -m 0755 "$(dirname -- "$hook")" \
            || { failed_ref=1; return 0; }
        atomic_restore_regular_file "$ROLLBACK_DIR/renew-hook" "$hook" \
            || failed_ref=1
    elif [[ -f "$ROLLBACK_DIR/renew-hook.absent" ]]; then
        if [[ -e "$hook" || -L "$hook" ]]; then
            if renew_hook_owned; then
                rm -f -- "$hook" || failed_ref=1
            else
                warn "Refusing to remove a changed Certbot deploy hook during rollback."
                failed_ref=1
            fi
        fi
    else
        warn "Rollback snapshot is missing the Certbot deploy-hook state."
        failed_ref=1
    fi
}

restore_external_owned_tree() {
    local dir="$1" marker="$2" value="$3" name="$4" failed_name="$5"
    local component_failed=0
    local -n failed_ref="$failed_name"
    if [[ -e "$dir" || -L "$dir" ]]; then
        if verify_ownership_marker "$dir" "$marker" "$value"; then
            remove_public_owned_tree "$dir" "$marker" "$value" || component_failed=1
        elif empty_unowned_public_tree_is_safe "$dir" "$marker"; then
            rmdir -- "$dir" || component_failed=1
        else
            warn "Refusing to replace a changed external asset root during rollback: $dir"
            component_failed=1
        fi
    fi
    if [[ "$component_failed" != 0 ]]; then
        failed_ref=1
        return 0
    fi
    if [[ -d "$ROLLBACK_DIR/$name" && ! -L "$ROLLBACK_DIR/$name" ]]; then
        static_publish_parent_is_safe "$dir" \
            && cp -a -- "$ROLLBACK_DIR/$name" "$dir" \
            && static_owned_tree_is_safe "$dir" "$marker" "$value" \
            || component_failed=1
    elif [[ -d "$ROLLBACK_DIR/${name}.empty-unowned" \
         && ! -L "$ROLLBACK_DIR/${name}.empty-unowned" ]]; then
        static_publish_parent_is_safe "$dir" \
            && cp -a -- "$ROLLBACK_DIR/${name}.empty-unowned" "$dir" \
            && empty_unowned_public_tree_is_safe "$dir" "$marker" \
            || component_failed=1
    elif [[ ! -f "$ROLLBACK_DIR/${name}.absent" ]]; then
        warn "Rollback snapshot is missing the external asset state for $dir."
        component_failed=1
    fi
    [[ "$component_failed" == 0 ]] || failed_ref=1
}

unit_enablement_links_absent() {
    local unit="$1" root found
    for root in /etc/systemd/system /run/systemd/system; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        found="$(find "$root" -type l -name "$unit" -print -quit 2>/dev/null || true)"
        [[ -z "$found" ]] || return 1
    done
    return 0
}

restore_unit_enablement() {
    local unit="$1" failed_name="$2" state current
    local -n failed_ref="$failed_name"
    if [[ -f "$ROLLBACK_DIR/unit-state/${unit}.absent" ]]; then
        systemctl disable "$unit" >/dev/null 2>&1 || true
        unit_enablement_links_absent "$unit" \
            || { warn "Dangling enablement links remain for absent unit $unit."; failed_ref=1; }
        return 0
    fi
    [[ -f "$ROLLBACK_DIR/unit-state/${unit}.exists" \
       && -f "$ROLLBACK_DIR/unit-state/${unit}.enabled-state" ]] \
        || { warn "Rollback snapshot is missing enablement state for $unit."; failed_ref=1; return 0; }
    IFS= read -r state < "$ROLLBACK_DIR/unit-state/${unit}.enabled-state" || state=""
    systemctl unmask "$unit" >/dev/null 2>&1 || failed_ref=1
    systemctl unmask --runtime "$unit" >/dev/null 2>&1 || failed_ref=1
    systemctl disable "$unit" >/dev/null 2>&1 || true
    case "$state" in
        enabled) systemctl enable "$unit" >/dev/null 2>&1 || failed_ref=1 ;;
        enabled-runtime) systemctl enable --runtime "$unit" >/dev/null 2>&1 || failed_ref=1 ;;
        disabled) ;;
        masked) systemctl mask "$unit" >/dev/null 2>&1 || failed_ref=1 ;;
        masked-runtime) systemctl mask --runtime "$unit" >/dev/null 2>&1 || failed_ref=1 ;;
        static|indirect) ;;
        *) warn "Unsupported saved enablement state '$state' for $unit."; failed_ref=1; return 0 ;;
    esac
    current="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    [[ "$current" == "$state" ]] \
        || { warn "Could not restore exact enablement state '$state' for $unit (got '${current:-unknown}')."; failed_ref=1; }
}

restore_unit_activity() {
    local unit="$1" failed_name="$2"
    local -n failed_ref="$failed_name"
    [[ -f "$ROLLBACK_DIR/unit-state/${unit}.exists" ]] || return 0
    if [[ -f "$ROLLBACK_DIR/unit-state/${unit}.active" ]]; then
        systemctl start "$unit" >/dev/null 2>&1 || failed_ref=1
        systemctl is-active --quiet "$unit" 2>/dev/null || failed_ref=1
        case "$unit" in
            5gpn-intercept.service|mihomo.service|5gpn-dns.service)
                [[ "$failed_ref" != 0 ]] \
                    || wait_service_ready "${unit%.service}" || failed_ref=1
                ;;
        esac
    elif [[ -f "$ROLLBACK_DIR/unit-state/${unit}.inactive" ]]; then
        systemctl stop "$unit" >/dev/null 2>&1 || failed_ref=1
        ! systemctl is-active --quiet "$unit" 2>/dev/null || failed_ref=1
    else
        warn "Rollback snapshot is missing activity state for $unit."
        failed_ref=1
    fi
}

disable_and_verify_quarantined_unit() {
    local unit="$1" failed_name="$2" load_state active_state enabled_state
    local -n failed_ref="$failed_name"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl stop "$unit" >/dev/null 2>&1 || true
    load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
    active_state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    if [[ -z "$load_state" || -z "$active_state" || -z "$enabled_state" ]]; then
        warn "Could not verify quarantine state for $unit."
        failed_ref=1
        return 0
    fi
    case "$active_state" in inactive|failed) ;; unknown) [[ "$load_state" == not-found ]] || failed_ref=1 ;; *) failed_ref=1 ;; esac
    case "$enabled_state" in disabled|static|indirect|masked|masked-runtime|linked|linked-runtime|alias|generated|transient|not-found) ;; *) failed_ref=1 ;; esac
}

quarantine_managed_units_after_failed_rollback() {
    local failed_name="$1" cert_failed="${2:-0}" unit base global_failed=0
    local -n failed_ref="$failed_name"
    for unit in "${TRANSACTION_UNIT_FILES[@]}"; do
        disable_and_verify_quarantined_unit "$unit" "$failed_name"
    done

    # certbot.timer is distro-owned and may renew unrelated lineages. Preserve
    # its exact pre-transaction state unless the failed 5gpn lineage is proven
    # to be the only Certbot lineage on the host.
    base="$(awk -F= '$1 == "DNS_BASE_DOMAIN" { print substr($0, index($0, "=") + 1); exit }' \
        "$ROLLBACK_DIR/conf/dns.env" 2>/dev/null || true)"
    if [[ "$cert_failed" == 1 && -n "$base" ]] \
       && is_valid_domain "$base" \
       && certbot_lineage_set_is_exclusive "$base"; then
        disable_and_verify_quarantined_unit certbot.timer global_failed
    else
        restore_unit_enablement certbot.timer global_failed
        restore_unit_activity certbot.timer global_failed
        if [[ "$cert_failed" == 1 ]]; then
            warn "The distro certbot.timer was restored to protect unrelated lineages; isolate and repair only the 5gpn lineage manually."
        fi
    fi
    [[ "$global_failed" == 0 ]] || failed_ref=1
}

restore_managed_unit_states() {
    local failed_name="$1" cert_failed="$2" allow_start="$3" unit
    local -n failed_ref="$failed_name"
    if [[ "$allow_start" != 1 ]]; then
        quarantine_managed_units_after_failed_rollback "$failed_name" "$cert_failed"
        return 0
    fi
    for unit in "${TRANSACTION_STATE_UNITS[@]}"; do
        restore_unit_enablement "$unit" "$failed_name"
    done
    if [[ "$allow_start" == 1 ]]; then
        for unit in "${TRANSACTION_STATE_UNITS[@]}"; do
            restore_unit_activity "$unit" "$failed_name"
        done
        # Starting an active unit may pull in a unit that was originally
        # inactive through Wants=/Requires=. Normalize inactive units once more,
        # then verify the final active set and runtime readiness.
        for unit in "${TRANSACTION_STATE_UNITS[@]}"; do
            [[ -f "$ROLLBACK_DIR/unit-state/${unit}.exists" \
               && -f "$ROLLBACK_DIR/unit-state/${unit}.inactive" ]] || continue
            systemctl stop "$unit" >/dev/null 2>&1 || failed_ref=1
            ! systemctl is-active --quiet "$unit" 2>/dev/null || failed_ref=1
        done
        for unit in "${TRANSACTION_STATE_UNITS[@]}"; do
            [[ -f "$ROLLBACK_DIR/unit-state/${unit}.exists" \
               && -f "$ROLLBACK_DIR/unit-state/${unit}.active" ]] || continue
            if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
                failed_ref=1
                continue
            fi
            case "$unit" in
                5gpn-intercept.service|mihomo.service|5gpn-dns.service)
                    wait_service_ready "${unit%.service}" || failed_ref=1 ;;
            esac
        done
    fi
}

restore_global_certbot_timer_after_success() {
    local failed=0 load_state active_state enabled_state
    if [[ "$RELEASE_PERSISTED_GLOBAL_CERTBOT_TIMER" == 1 \
       && ( -e "$GLOBAL_CERTBOT_TIMER_STATE" || -L "$GLOBAL_CERTBOT_TIMER_STATE" ) ]]; then
        restore_persisted_global_certbot_timer
        return
    fi
    if [[ "$KEEP_GLOBAL_CERTBOT_TIMER_DISABLED" == 1 ]]; then
        systemctl disable --now certbot.timer >/dev/null 2>&1 || true
        systemctl stop certbot.timer >/dev/null 2>&1 || true
        load_state="$(systemctl show -p LoadState --value certbot.timer 2>/dev/null || true)"
        active_state="$(systemctl is-active certbot.timer 2>/dev/null || true)"
        enabled_state="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
        if [[ -z "$load_state" || -z "$active_state" || -z "$enabled_state" ]] \
           || [[ "$active_state" != inactive && "$active_state" != failed \
              && ! ( "$active_state" == unknown && "$load_state" == not-found ) ]] \
           || [[ "$enabled_state" == enabled || "$enabled_state" == enabled-runtime ]]; then
            err "Could not keep the unscoped distro certbot.timer disabled."
            return 1
        fi
        return 0
    fi
    if [[ -e "$GLOBAL_CERTBOT_TIMER_STATE" || -L "$GLOBAL_CERTBOT_TIMER_STATE" ]]; then
        err "A saved distro Certbot timer takeover state exists, but this flow did not authorize releasing it."
        return 1
    fi
    restore_unit_enablement certbot.timer failed
    restore_unit_activity certbot.timer failed
    [[ "$failed" == 0 ]] \
        || { err "Could not restore the distro certbot.timer after the non-owning certificate flow."; return 1; }
}

rollback_install() {
    [[ "$INSTALL_TRANSACTION_ACTIVE" == 1 && -d "$ROLLBACK_DIR" ]] || return 0
    local rollback_cert_failed=0 rollback_host_failed=0 rollback_state_failed=0
    local rollback_base_failed=0 rollback_config_failed=0 rollback_unit_failed=0
    local rollback_asset_failed=0 rollback_account_failed=0 rollback_polkit_failed=0
    local rollback_launcher_failed=0
    local rollback_service_failed=0
    local rollback_lock_failed=0 polkit_candidate="" unit load_state content_failed=0 restore_ok=0
    warn "Install publication failed; restoring the previous 5gpn deployment."

    # A capture failure before the immutable file snapshot has not published
    # anything. Only the services stopped by the capture fence need restoring.
    if [[ "$ROLLBACK_SNAPSHOT_READY" != 1 ]]; then
        release_install_cert_lock || rollback_lock_failed=1
        if [[ "$rollback_lock_failed" == 0 ]]; then
            restore_managed_unit_states rollback_service_failed 0 1
            [[ "$rollback_service_failed" == 0 ]] \
                || quarantine_managed_units_after_failed_rollback rollback_service_failed 0
        else
            restore_managed_unit_states rollback_service_failed 0 0
        fi
        if [[ "$rollback_lock_failed" == 0 && "$rollback_service_failed" == 0 ]]; then
            INSTALL_TRANSACTION_ACTIVE=0
            warn "Install snapshot failed before publication; prior service states were restored."
            return 0
        fi
        return 1
    fi

    if ! validate_install_rollback_snapshot; then
        rollback_state_failed=1
        release_install_cert_lock || rollback_lock_failed=1
        restore_managed_unit_states rollback_service_failed 0 0
        err "Rollback snapshot completeness validation failed; live files were not removed or overwritten."
        return 1
    fi

    # Publication may already have restarted the runtime. Stop every current
    # writer before replacing live state; failure leaves the snapshot intact.
    for unit in "${TRANSACTION_STOP_UNITS[@]}"; do
        load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
        if [[ ( -z "$load_state" || "$load_state" == not-found ) ]] \
           && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
            continue
        fi
        systemctl stop "$unit" >/dev/null 2>&1 || rollback_service_failed=1
        ! systemctl is-active --quiet "$unit" 2>/dev/null || rollback_service_failed=1
    done
    if [[ "$rollback_service_failed" != 0 ]]; then
        release_install_cert_lock || rollback_lock_failed=1
        restore_managed_unit_states rollback_service_failed 0 0
        err "Rollback could not stop all live writers; no filesystem snapshot was applied."
        return 1
    fi

    if [[ "$SWAP_CREATED_THIS_RUN" == 1 ]]; then
        if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
            swapoff "$SWAP_FILE" 2>/dev/null || rollback_host_failed=1
        fi
        rm -f -- "$SWAP_FILE" || rollback_host_failed=1
        [[ ! -e "$SWAP_FILE" && ! -L "$SWAP_FILE" ]] || rollback_host_failed=1
        sed -i "\|^${SWAP_FILE} none swap sw 0 0 ${SWAP_FSTAB_MARKER}$|d" /etc/fstab 2>/dev/null \
            || rollback_host_failed=1
        grep -Fq "$SWAP_FSTAB_MARKER" /etc/fstab 2>/dev/null && rollback_host_failed=1
        [[ "$rollback_host_failed" != 0 ]] || SWAP_CREATED_THIS_RUN=0
    fi

    if [[ ! -d "$ROLLBACK_DIR/base" && ! -f "$ROLLBACK_DIR/base.absent" ]]; then
        rollback_base_failed=1
    fi
    if [[ -e "$BASE_DIR" || -L "$BASE_DIR" ]]; then
        if verify_ownership_marker "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"; then
            remove_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
                || rollback_base_failed=1
        else
            warn "Refusing to replace a changed runtime root during rollback: $BASE_DIR"
            rollback_base_failed=1
        fi
    fi
    # Never copy over BASE_DIR after a failed removal. A partial copy is also a
    # hard rollback failure and the pristine snapshot remains retained.
    if [[ "$rollback_base_failed" == 0 && -d "$ROLLBACK_DIR/base" ]]; then
        [[ ! -e "$BASE_DIR" && ! -L "$BASE_DIR" ]] || rollback_base_failed=1
        [[ "$rollback_base_failed" != 0 ]] \
            || cp -a -- "$ROLLBACK_DIR/base" "$BASE_DIR" || rollback_base_failed=1
    fi

    if [[ -f "$ROLLBACK_DIR/conf.absent" ]]; then
        if [[ -e "$CONF_DIR" || -L "$CONF_DIR" ]]; then
            remove_fixed_owned_dir "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
                || rollback_config_failed=1
        fi
    else
        restore_config_root_without_intercept_ca rollback_config_failed
    fi
    restore_optional_owned_root "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" \
        "$INTERCEPT_CA_MARKER_VALUE" intercept-ca rollback_config_failed
    restore_optional_owned_root "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" \
        "$INTERCEPT_STATE_MARKER_VALUE" intercept-state rollback_state_failed
    restore_managed_unit_files rollback_unit_failed
    restore_management_launcher rollback_launcher_failed
    if [[ -f "$ROLLBACK_DIR/state.absent" && ( -e "$STATE_DIR" || -L "$STATE_DIR" ) ]]; then
        remove_fixed_owned_dir "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" \
            || rollback_state_failed=1
    fi

    if [[ -f "$ROLLBACK_DIR/polkit/50-5gpn.rules" ]]; then
        if [[ ( -e "$POLKIT_RULE_PATH" || -L "$POLKIT_RULE_PATH" ) ]] \
           && ! polkit_rule_owned_by_5gpn; then
            warn "Could not restore the previous polkit rule because the live path is no longer 5gpn-owned."
            rollback_polkit_failed=1
        else
            install -d -o root -g root -m 0755 "$(dirname -- "$POLKIT_RULE_PATH")" \
                || rollback_polkit_failed=1
            if [[ "$rollback_polkit_failed" == 0 ]]; then
                polkit_candidate="$(mktemp "$(dirname -- "$POLKIT_RULE_PATH")/.50-5gpn.rollback.XXXXXX")" \
                    || rollback_polkit_failed=1
            fi
            if [[ "$rollback_polkit_failed" == 0 ]]; then
                install -o root -g root -m 0644 "$ROLLBACK_DIR/polkit/50-5gpn.rules" "$polkit_candidate" \
                    && mv -f -- "$polkit_candidate" "$POLKIT_RULE_PATH" \
                    || rollback_polkit_failed=1
            fi
            [[ "$rollback_polkit_failed" == 0 || -z "$polkit_candidate" ]] \
                || rm -f -- "$polkit_candidate" || rollback_polkit_failed=1
        fi
    elif [[ -f "$ROLLBACK_DIR/polkit/50-5gpn.rules.absent" ]]; then
        if polkit_rule_owned_by_5gpn; then
            rm -f -- "$POLKIT_RULE_PATH" || rollback_polkit_failed=1
        elif [[ -e "$POLKIT_RULE_PATH" || -L "$POLKIT_RULE_PATH" ]]; then
            warn "Could not restore an absent polkit rule because the live path is no longer 5gpn-owned."
            rollback_polkit_failed=1
        fi
    else
        warn "Rollback snapshot is missing the polkit rule state."
        rollback_polkit_failed=1
    fi

    restore_renew_hook rollback_cert_failed
    if [[ -f "$ROLLBACK_DIR/renewal-names" ]]; then
        local renewal_base lineage_changed restore_ok
        while IFS= read -r renewal_base; do
            if ! is_valid_domain "$renewal_base"; then
                rollback_cert_failed=1
                continue
            fi
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
                            warn "Certbot lineage ${renewal_base} could not be fully restored; automatic renewal was disabled."
                        fi
                    else
                        rollback_cert_failed=1
                        warn "Could not restore Certbot lineage ${renewal_base}; automatic renewal was disabled to avoid a mode mismatch."
                    fi
                fi
            elif [[ -f "$ROLLBACK_DIR/renewal-conf/${renewal_base}.lineage-absent" ]] \
               && [[ -e "/etc/letsencrypt/live/${renewal_base}" \
                  || -e "/etc/letsencrypt/archive/${renewal_base}" \
                  || -e "/etc/letsencrypt/renewal/${renewal_base}.conf" ]]; then
                if ! certbot delete --non-interactive --cert-name "$renewal_base" >/dev/null 2>&1 \
                   || [[ -e "/etc/letsencrypt/live/${renewal_base}" \
                      || -e "/etc/letsencrypt/archive/${renewal_base}" \
                      || -e "/etc/letsencrypt/renewal/${renewal_base}.conf" ]]; then
                    rollback_cert_failed=1
                    warn "Could not remove the Certbot lineage created by the failed transaction: ${renewal_base}."
                fi
            fi
        done < "$ROLLBACK_DIR/renewal-names"
    else
        rollback_cert_failed=1
    fi

    if [[ "$DNS_WEB_DIR" != "$BASE_DIR"/* ]]; then
        restore_external_owned_tree "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" \
            "$WEB_OWNERSHIP_VALUE" external-web rollback_asset_failed
    fi
    if [[ "$DNS_ZASH_DIR" != "$BASE_DIR"/* ]]; then
        restore_external_owned_tree "$DNS_ZASH_DIR" "$ZASH_OWNERSHIP_MARKER" \
            '5gpn-zashboard-v1' external-zash rollback_asset_failed
    fi
    rollback_created_service_accounts rollback_account_failed
    systemctl daemon-reload >/dev/null 2>&1 || rollback_unit_failed=1

    # Starting 5gpn-intercept may synchronously start its required certificate
    # oneshot. Release the certificate lock before restoring any active state.
    release_install_cert_lock || rollback_lock_failed=1
    content_failed=$((rollback_cert_failed + rollback_host_failed + rollback_state_failed \
        + rollback_base_failed + rollback_config_failed + rollback_unit_failed \
        + rollback_asset_failed + rollback_account_failed + rollback_polkit_failed \
        + rollback_launcher_failed + rollback_lock_failed))
    if [[ "$content_failed" == 0 ]]; then
        restore_managed_unit_states rollback_service_failed 0 1
        [[ "$rollback_service_failed" == 0 ]] \
            || quarantine_managed_units_after_failed_rollback rollback_service_failed
    else
        restore_managed_unit_states rollback_service_failed "$rollback_cert_failed" 0
    fi

    if [[ "$content_failed" == 0 && "$rollback_service_failed" == 0 ]]; then
        INSTALL_TRANSACTION_ACTIVE=0
        ROLLBACK_SNAPSHOT_READY=0
        PRETRANSACTION_ROOTS_ACTIVE=0
        warn "Previous deployment restored; inspect the reported error before retrying."
        return 0
    else
        [[ "$rollback_cert_failed" == 0 ]] \
            || err "Certificate-lineage rollback was incomplete; automatic renewal is disabled pending repair."
        [[ "$rollback_host_failed" == 0 && "$rollback_base_failed" == 0 \
           && "$rollback_config_failed" == 0 && "$rollback_unit_failed" == 0 \
           && "$rollback_asset_failed" == 0 && "$rollback_account_failed" == 0 \
           && "$rollback_polkit_failed" == 0 && "$rollback_launcher_failed" == 0 ]] \
            || err "Host authorization rollback was incomplete; inspect $POLKIT_RULE_PATH before retrying."
        [[ "$rollback_state_failed" == 0 ]] \
            || err "Interception state rollback was incomplete; inspect $INTERCEPT_STATE_DIR before retrying."
        [[ "$rollback_service_failed" == 0 ]] \
            || err "Service enablement, activity, or readiness could not be restored."
        err "Project-managed services, paths, and timers were quarantined (disabled/stopped); verify them before reboot."
        [[ "$rollback_lock_failed" == 0 ]] \
            || err "A transaction lock descriptor became invalid during rollback."
        return 1
    fi
}

report_install_failure() {
    local rc="$1"
    [[ "$INSTALL_FAILURE_REPORTED" == 0 ]] || return 0
    INSTALL_FAILURE_REPORTED=1
    err "Installation failed during phase '${INSTALL_PHASE:-unknown}' (exit ${rc})."
    err "No success message was emitted; this run did not complete."
}

install_transaction_exit() {
    local rc=$?
    [[ "$rc" == 0 ]] || report_install_failure "$rc"
    finish_install_transaction "$rc"
}

install_transaction_error() {
    local rc=$?
    report_install_failure "$rc"
    finish_install_transaction "$rc"
}

install_transaction_signal() {
    finish_install_transaction "$1"
}

ensure_install_lock_for_rollback() {
    if lock_fd_targets_file 7 "$INSTALL_LOCK_FILE"; then
        flock -w "$INSTALL_LOCK_WAIT_TIMEOUT" 7 \
            || { err "Timed out revalidating the installer lock for rollback."; return 1; }
        INSTALL_LOCK_HELD=1
        return 0
    fi
    INSTALL_LOCK_HELD=0
    acquire_install_lock
}

ensure_install_cert_lock_for_rollback() {
    ensure_install_lock_for_rollback || return 1
    if lock_fd_targets_file 8 "$CERT_RENEW_LOCK_FILE"; then
        flock -w "$CERT_LOCK_WAIT_TIMEOUT" 8 \
            || { err "Timed out revalidating the certificate lock for rollback."; return 1; }
        INSTALL_CERT_LOCK_HELD=1
        return 0
    fi
    INSTALL_CERT_LOCK_HELD=0
    acquire_install_cert_lock
}

finish_install_transaction() {
    local original_rc="$1" rollback_rc=0 cleanup_rc=0 root_cleanup_rc=0 lock_rc=0
    local active_was_set=0 postcommit_was_pending=0 final_rc
    final_rc="$original_rc"
    trap '' HUP INT TERM
    trap - ERR EXIT
    if [[ "$ROLLBACK_IN_PROGRESS" == 1 ]]; then
        PRESERVE_ROLLBACK_STAGE=1
        rollback_rc=1
        err "A second failure reached the installer while rollback was already running."
    elif [[ "$INSTALL_TRANSACTION_ACTIVE" == 1 ]]; then
        active_was_set=1
        ROLLBACK_IN_PROGRESS=1
        set +e
        ensure_install_cert_lock_for_rollback
        lock_rc=$?
        if [[ "$lock_rc" == 0 ]]; then
            rollback_install
            rollback_rc=$?
        else
            rollback_rc=1
            err "Could not reacquire both transaction locks; refusing an unsafe concurrent rollback."
        fi
        set -e
        [[ "$rollback_rc" == 0 ]] || PRESERVE_ROLLBACK_STAGE=1
    fi

    if [[ "$POSTCOMMIT_TIMER_RESTORE_PENDING" == 1 ]]; then
        postcommit_was_pending=1
        set +e
        restore_global_certbot_timer_after_success
        cleanup_rc=$?
        set -e
        POSTCOMMIT_TIMER_RESTORE_PENDING=0
        [[ "$cleanup_rc" == 0 ]] || PRESERVE_ROLLBACK_STAGE=1
    fi

    if [[ "$PRESERVE_ROLLBACK_STAGE" == 0 && "$PRETRANSACTION_ROOTS_ACTIVE" == 1 ]]; then
        set +e
        cleanup_pretransaction_project_roots root_cleanup_rc
        set -e
        [[ "$root_cleanup_rc" == 0 ]] || PRESERVE_ROLLBACK_STAGE=1
    fi
    if [[ "$PRESERVE_ROLLBACK_STAGE" == 0 ]]; then
        set +e
        cleanup_artifact_stage
        cleanup_rc=$?
        set -e
        [[ "$cleanup_rc" == 0 ]] || PRESERVE_ROLLBACK_STAGE=1
    fi
    if [[ "$PRESERVE_ROLLBACK_STAGE" == 1 ]]; then
        [[ "$root_cleanup_rc" == 0 ]] \
            || err "Could not restore one or more project roots that were absent before this run."
        [[ -z "$ROLLBACK_DIR" ]] \
            || err "Rollback was incomplete; the recovery snapshot was preserved at: $ROLLBACK_DIR"
        [[ -z "$ARTIFACT_STAGE" ]] \
            || err "Do not remove the retained transaction directory: $ARTIFACT_STAGE"
    fi

    set +e
    release_install_cert_lock
    [[ "$?" == 0 ]] || lock_rc=1
    release_install_lock
    [[ "$?" == 0 ]] || lock_rc=1
    set -e
    if [[ "$active_was_set" == 1 || "$postcommit_was_pending" == 1 || "$rollback_rc" != 0 \
       || "$cleanup_rc" != 0 || "$root_cleanup_rc" != 0 || "$lock_rc" != 0 ]]; then
        [[ "$final_rc" != 0 ]] || final_rc=1
    fi
    exit "$final_rc"
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
# Every run publishes the already verified pinned DNS_VERSION over $DNS_BIN.
# Replacing the running daemon's binary is safe because the
# process keeps its inode until start_services restarts it). Download failure
# aborts the install and leaves the previously installed binary untouched.
# Dev builds must be scp'd in AFTER the install run (then restarted) — a
# pre-placed binary is deliberately clobbered.
install_5gpndns() {
    [[ -n "$ARTIFACT_STAGE" && -x "$ARTIFACT_STAGE/5gpn-dns" ]] \
        || { err "5gpn-dns was not staged."; return 1; }
    publish_executable "$ARTIFACT_STAGE/5gpn-dns" "$DNS_BIN" \
        || { err "5gpn-dns publication failed."; return 1; }
    [[ -x "$DNS_BIN" ]] && cmp -s "$ARTIFACT_STAGE/5gpn-dns" "$DNS_BIN" \
        && binary_reports_exact_version "$DNS_BIN" --version "$DNS_VERSION_DEFAULT" \
        || { err "Published 5gpn-dns failed identity/version verification."; return 1; }
    ok "Verified 5gpn-dns ${DNS_VERSION_DEFAULT} published to $DNS_BIN."
}

install_intercept() {
    [[ -n "$ARTIFACT_STAGE" && -x "$ARTIFACT_STAGE/5gpn-intercept" ]] \
        || { err "5gpn-intercept was not staged."; return 1; }
    publish_executable "$ARTIFACT_STAGE/5gpn-intercept" "$INTERCEPT_BIN" \
        || { err "5gpn-intercept publication failed."; return 1; }
    [[ -x "$INTERCEPT_BIN" ]] && cmp -s "$ARTIFACT_STAGE/5gpn-intercept" "$INTERCEPT_BIN" \
        && binary_reports_exact_version "$INTERCEPT_BIN" --version "$DNS_VERSION_DEFAULT" \
        || { err "Published 5gpn-intercept failed identity/version verification."; return 1; }
    ok "Verified 5gpn-intercept ${DNS_VERSION_DEFAULT} published to $INTERCEPT_BIN."
}

prepare_intercept_runtime_dirs() {
    local path canonical
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        || { err "Unsafe configuration root: $CONF_DIR"; return 1; }
    for path in "$INTERCEPT_DIR" "$INTERCEPT_DIR/tls"; do
        runtime_directory_slot_is_safe "$path" "$CONF_DIR" \
            || { err "Refusing unsafe interception runtime path: $path"; return 1; }
        install -d -o root -g "$INTERCEPT_SERVICE_USER" -m 0750 "$path" || return 1
        canonical="$(canonical_dir_path "$path")" || return 1
        [[ "$canonical" == "$path" ]] \
            || { err "Refusing interception runtime path alias: $path -> $canonical"; return 1; }
    done
    chmod g-s "$INTERCEPT_DIR/tls" || return 1
    chmod 3770 "$INTERCEPT_DIR" || return 1
}

prepare_intercept_state_dir() {
    claim_fixed_owned_dir "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" || return 1
    install -d -o "$INTERCEPT_SERVICE_USER" -g "$INTERCEPT_SERVICE_USER" -m 0700 "$INTERCEPT_STATE_DIR" || return 1
    write_ownership_marker "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" || return 1
}

ensure_intercept_config() {
    local config="$INTERCEPT_DIR/config.json" candidate inbound_user inbound_pass upstream_user upstream_pass
    prepare_intercept_runtime_dirs || return 1
    if [[ -f "$config" && ! -L "$config" ]]; then
        if ! "$INTERCEPT_BIN" --config "$config" --check-config; then
            if grep -Eq '"version"[[:space:]]*:[[:space:]]*4([,[:space:]}]|$)' "$config"; then
                err "Pre-v5 interception config detected: $config"
                err "Do not delete it: back up active env/intercept/mihomo state, use the old v4 control plane to disable MITM and withdraw managed rules, then save the clean post-disable boundary."
                err "Follow README's jq rebuild preserving SOCKS/TLS infrastructure; require current sidecar --check-config and 5gpn-dns --check-interception-routing to report ready before synced atomic publication."
                err "Modules/order are cleared and extensions must be re-imported and reviewed."
            else
                err "Existing interception config is invalid: $config"
            fi
            return 1
        fi
        ok "Existing interception config validated and preserved: $config"
        return 0
    fi
    [[ ! -e "$config" && ! -L "$config" ]] \
        || { err "Refusing unsafe interception config path: $config"; return 1; }
    inbound_user="module-in-$(openssl rand -hex 12)"
    inbound_pass="$(openssl rand -hex 24)"
    upstream_user="module-up-$(openssl rand -hex 12)"
    upstream_pass="$(openssl rand -hex 24)"
    candidate="$(mktemp "$INTERCEPT_DIR/.config.json.XXXXXX")" || return 1
    cat > "$candidate" <<EOF
{
  "version": 5,
  "listen": "127.0.0.1:18080",
  "username": "${inbound_user}",
  "password": "${inbound_pass}",
  "tls_cert": "/etc/5gpn/intercept/tls/fullchain.pem",
  "tls_key": "/etc/5gpn/intercept/tls/privkey.pem",
  "upstream_proxy": {
    "address": "127.0.0.1:17890",
    "username": "${upstream_user}",
    "password": "${upstream_pass}"
  },
  "mitm": {
    "enabled": false,
    "http2": true,
    "quic_fallback_protection": true
  },
  "execution_order": [],
  "modules": []
}
EOF
    chown "$DNS_SERVICE_USER:$INTERCEPT_SERVICE_USER" "$candidate" && chmod 0640 "$candidate" \
        || { rm -f -- "$candidate"; return 1; }
    "$INTERCEPT_BIN" --config "$candidate" --check-config \
        || { rm -f -- "$candidate"; err "Generated interception config failed validation."; return 1; }
    sync -f "$candidate" 2>/dev/null || true
    mv -f -- "$candidate" "$config"
    ok "Created disabled-by-default interception config: $config"
}

intercept_keypair_matches() {
    local cert="$1" key="$2" cert_pub key_pub
    cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

validate_intercept_ca() {
    local root_cert="$INTERCEPT_CA_DIR/root.crt" root_key="$INTERCEPT_CA_DIR/root.key"
    [[ -f "$root_cert" && ! -L "$root_cert" && -f "$root_key" && ! -L "$root_key" ]] || return 1
    [[ "$(file_uid "$root_key")" == 0 && "$(file_mode "$root_key")" == 600 ]] || return 1
    openssl x509 -in "$root_cert" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
    openssl x509 -in "$root_cert" -noout -text 2>/dev/null | grep -Fq 'CA:TRUE' || return 1
    intercept_keypair_matches "$root_cert" "$root_key"
}

validate_intercept_leaf() {
    local leaf="$INTERCEPT_DIR/tls/leaf.crt" key="$INTERCEPT_DIR/tls/privkey.pem"
    [[ -f "$leaf" && ! -L "$leaf" && -f "$key" && ! -L "$key" ]] || return 1
    openssl x509 -in "$leaf" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
    openssl verify -CAfile "$INTERCEPT_CA_DIR/root.crt" "$leaf" >/dev/null 2>&1 || return 1
    intercept_keypair_matches "$leaf" "$key" || return 1
    local host probe digest state request hosts
    request="$("$INTERCEPT_BIN" --config "$INTERCEPT_DIR/config.json" --print-certificate-request 2>/dev/null)" || return 1
    digest="$(head -n 1 <<<"$request" | tr -d '[:space:]')"
    hosts="$(tail -n +2 <<<"$request")"
    state="$(tr -d '[:space:]' < "$INTERCEPT_DIR/cert-state" 2>/dev/null || true)"
    [[ "$digest" =~ ^[0-9a-f]{64}$ && "$state" == "$digest" ]] || return 1
    while IFS= read -r host; do
        probe="$host"
        [[ "$probe" != \*.* ]] || probe="probe.${probe#*.}"
        openssl x509 -in "$leaf" -noout -checkhost "$probe" 2>/dev/null | grep -Fq 'does match certificate' || return 1
    done <<<"$hosts"
}

ensure_intercept_certificates() {
    local stage serial fullchain_candidate
    claim_fixed_owned_dir "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" || return 1
    install -d -o root -g root -m 0700 "$INTERCEPT_CA_DIR" || return 1
    chmod g-s "$INTERCEPT_CA_DIR" || return 1
    stage="$(mktemp -d /var/tmp/5gpn-intercept-cert.XXXXXX)" || return 1
    chmod 0700 "$stage"
    claim_temp_dir "$stage" || { rmdir -- "$stage"; return 1; }
    if [[ -e "$INTERCEPT_CA_DIR/root.crt" || -e "$INTERCEPT_CA_DIR/root.key" ]]; then
        validate_intercept_ca \
            || { remove_temp_dir "$stage"; err "Existing interception CA is invalid; refusing replacement."; return 1; }
    else
        openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
            -subj '/CN=5gpn Interception Root' \
            -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
            -addext 'keyUsage=critical,keyCertSign,cRLSign' \
            -keyout "$stage/root.key" -out "$stage/root.crt" >/dev/null 2>&1 \
            || { remove_temp_dir "$stage"; err "Could not generate the interception CA."; return 1; }
        install -m 0600 "$stage/root.key" "$INTERCEPT_CA_DIR/.root.key.new" \
            && install -m 0644 "$stage/root.crt" "$INTERCEPT_CA_DIR/.root.crt.new" \
            || { rm -f -- "$INTERCEPT_CA_DIR/.root.key.new" "$INTERCEPT_CA_DIR/.root.crt.new"; remove_temp_dir "$stage"; return 1; }
        mv -f -- "$INTERCEPT_CA_DIR/.root.key.new" "$INTERCEPT_CA_DIR/root.key"
        mv -f -- "$INTERCEPT_CA_DIR/.root.crt.new" "$INTERCEPT_CA_DIR/root.crt"
        validate_intercept_ca \
            || { remove_temp_dir "$stage"; err "Generated interception CA failed validation."; return 1; }
    fi

    prepare_intercept_runtime_dirs || { remove_temp_dir "$stage"; return 1; }
    remove_temp_dir "$stage"
	"${SCRIPTS_DIR}/intercept-cert-renew.sh" --installer-lock-held \
		|| { err "Dynamic interception leaf publication failed."; return 1; }
	if [[ -n "$("$INTERCEPT_BIN" --config "$INTERCEPT_DIR/config.json" --print-certificate-hosts 2>/dev/null)" ]]; then
		validate_intercept_leaf \
			|| { err "Dynamic interception leaf validation failed."; return 1; }
		ok "Dedicated interception CA and extension-scoped leaf are ready."
	else
		ok "Dedicated interception CA is ready; no extension leaf is needed yet."
	fi
}

# 5gpn-web: control-console SPA tarball from the same moooyo/5gpn release.
# Served from disk by the loopback :443 console server (DNS_WEB_DIR); no go:embed.
#
# The pinned DNS_VERSION's SPA and daemon move together on every run. Staging
# and atomic tree publication leave the active console untouched on failure.
install_web() {
    [[ -n "$ARTIFACT_STAGE" && -f "$ARTIFACT_STAGE/web/index.html" ]] \
        || { err "Control-console SPA was not staged."; return 1; }
    release_tag_file_matches "$ARTIFACT_STAGE/web/.web_version" "$DNS_VERSION_DEFAULT" \
        || { err "Control-console SPA version does not match ${DNS_VERSION_DEFAULT}."; return 1; }
    claim_web_dir || return 1
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
# receives its controller target from the daemon's one-use handoff redirect.
# The redirect stores only a fixed non-secret placeholder in zashboard; an
# HttpOnly host session gates /proxy/ and the daemon injects the real controller
# credential. No index.html/config patch happens here.
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
    publish_executable "$ARTIFACT_STAGE/mihomo" "$MIHOMO_BIN" \
        || { err "mihomo publication failed."; return 1; }
    [[ -x "$MIHOMO_BIN" ]] && cmp -s "$ARTIFACT_STAGE/mihomo" "$MIHOMO_BIN" \
        && mihomo_reports_exact_version "$MIHOMO_BIN" "$MIHOMO_VERSION" \
        || { err "Published mihomo failed identity/version verification."; return 1; }
    ok "Verified mihomo ${MIHOMO_VERSION} published to $MIHOMO_BIN."
}

# ----------------------------------------------------------------------------
# subscriptions.json (remote rule-list auto-update, in-process in 5gpn-dns)
# ----------------------------------------------------------------------------
# Writes the default subscriptions.json — only if absent, so operator edits
# (added/disabled/re-pointed subscriptions) are never clobbered on re-install.
# Ships one default subscription: chnroute, the system arbitration input.
#   chnroute  china-ip    17mon/china_ip_list  (cidr)  split-horizon arbitration input
# Best-effort + offline-safe: a failed or too-small fetch keeps the prior cache.
# The system subscription is edited directly in subscriptions.json.
write_subscriptions_json() {
    local f="${CONF_DIR}/subscriptions.json"
    if [[ -f "$f" ]]; then
        info "Keeping existing ${f}."
        return 0
    fi
    cat > "$f" <<'EOF'
{
  "version": 1,
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
    ok "Written ${f} (1 default subscription: chnroute; DNS intent rules live in policy.json)."
}

# ----------------------------------------------------------------------------
# Seed the unified policy-rule model (policy.json). Runs the installed
# 5gpn-dns binary's --seed-defaults subcommand (which owns the JSON shape,
# reusing the daemon's own types). This MUST run before start_services: the
# daemon compiles the ordered DNS intent rules directly from policy.json.
# Idempotent — the subcommand skips a present policy.json (operator source of
# truth). Each default list URL is env-overridable.
#
# Proxy intent selects the gateway only; application egress routing lives
# entirely in the operator-owned mihomo configuration.
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
        --subscriptions "${CONF_DIR}/subscriptions.json" \
        --bypass "${SCRIPT_DIR}/etc/block-dns-bypass.txt" \
        --keyword "${SCRIPT_DIR}/etc/block-dns-bypass.keyword.txt" \
        --proxy-domains "${SCRIPT_DIR}/etc/proxy-domains.txt" \
        --china-list-url "$china_list_url" \
        --gfw-url "$gfw_url"; then
        chmod 644 "$policy" 2>/dev/null || true
        ok "Seeded ${policy} (default policy ruleset)."
    else
        err "Policy seed/current-schema validation failed; refusing installation."
        return 1
    fi
}

# ----------------------------------------------------------------------------
# Install config + scripts + control-plane sources
# ----------------------------------------------------------------------------
# render_mihomo_config renders /etc/5gpn/mihomo/config.yaml from the committed
# template (etc/mihomo/config.yaml.tmpl), substituting the box-specific
# sentinels, seeds the zashboard whitelist.txt on first run, then validates the
# rendered file with `mihomo -t` (fatal on failure — a bad config must never
# be left live). This is the SINGLE writer for the mihomo data-plane config.
seed_mihomo_whitelist() {
    # whitelist.txt is TUI-managed after install and never clobbered.
    if [[ ! -f "$MIHOMO_DIR/whitelist.txt" ]]; then
        local seed="${SCRIPT_DIR}/etc/mihomo/whitelist.seed.txt"
        [[ -f "$seed" && -r "$seed" && -s "$seed" ]] \
            || { err "Bundled mihomo whitelist seed is missing, unreadable, or empty: $seed"; return 1; }
        install -o "$DNS_SERVICE_USER" -g "$MIHOMO_SERVICE_USER" -m 0640 \
            "$seed" "$MIHOMO_DIR/whitelist.txt" \
            || { err "Could not seed the mihomo source allowlist."; return 1; }
        warn "Zashboard is unreachable until you explicitly add a source CIDR with '5gpn add-allow'."
    fi
}

mihomo_config_secret() {
    local f="$1"
    [[ -x "$DNS_BIN" ]] \
        || { err "5gpn-dns is unavailable for structural mihomo secret parsing."; return 1; }
    "$DNS_BIN" --print-mihomo-secret --config "$f"
}

yaml_single_quoted_value() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

persist_mihomo_secret() {
    local secret="$1"
    [[ -n "$secret" ]] || { warn "mihomo config has no readable controller secret; DNS_MIHOMO_SECRET was not changed."; return 0; }
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_MIHOMO_SECRET "$secret" \
        || { err "Could not persist DNS_MIHOMO_SECRET to dns.env."; return 1; }
}

# Seed mihomo's fully operator-owned config only when it is missing. A normal
# install or configure operation validates and preserves an existing file
# byte-for-byte. `render_mihomo_config --reset` is the sole overwrite path: it
# renders to a same-directory candidate, validates that candidate, backs up the
# old file, fsyncs, and atomically renames it into place.
render_mihomo_config() {
    local mode="${1:-seed}" config="${MIHOMO_DIR}/config.yaml" secret="" template=""
    MIHOMO_SEED_PORTS_REQUIRED=0
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        || { err "Unsafe configuration root: $CONF_DIR"; return 1; }
    runtime_directory_slot_is_safe "$MIHOMO_DIR" "$CONF_DIR" \
        || { err "Refusing unsafe mihomo directory slot: $MIHOMO_DIR"; return 1; }
    runtime_file_slot_is_safe "$config" "$CONF_DIR" \
        && runtime_file_slot_is_safe "$MIHOMO_DIR/whitelist.txt" "$CONF_DIR" \
        || { err "Refusing unsafe mihomo configuration file slot."; return 1; }
    install -d -g "$MIHOMO_SERVICE_USER" -m 3770 "$MIHOMO_DIR"
    runtime_tree_has_only_plain_entries "$MIHOMO_DIR" \
        || { err "Refusing unsafe link, hardlink, or special entry below $MIHOMO_DIR"; return 1; }
    seed_mihomo_whitelist || return 1

    if [[ -f "$config" && "$mode" != "--reset" ]]; then
        if ! "$MIHOMO_BIN" -t -f "$config" -d "$MIHOMO_DIR"; then
            err "Existing operator-owned mihomo config is invalid; it was NOT overwritten: $config"
            return 1
        fi
        chown "$DNS_SERVICE_USER:$MIHOMO_SERVICE_USER" "$config" 2>/dev/null || true
        chmod 0640 "$config" 2>/dev/null || true
        secret="$(mihomo_config_secret "$config")" \
            || { err "Existing mihomo controller secret could not be parsed safely."; return 1; }
        persist_mihomo_secret "$secret" || return 1
        ok "Existing operator-owned mihomo config validated and preserved: $config"
        return 0
    fi

    template="${BASE_DIR}/etc/mihomo/config.yaml.tmpl"
    [[ -f "$template" && -r "$template" && -s "$template" ]] \
        || { err "Bundled mihomo seed template is missing, unreadable, or empty: $template"; return 1; }

    # Controller secret survives an explicit reset. On first install, prefer a
    # persisted value and otherwise generate a strong mixed secret.
    if [[ -f "$config" ]]; then
        secret="$(mihomo_config_secret "$config")" \
            || { err "Existing mihomo controller secret could not be parsed safely."; return 1; }
    fi
    [[ -n "$secret" ]] || secret="$(cfg_get DNS_MIHOMO_SECRET)"
    [[ -n "$secret" ]] || secret="$(openssl rand -base64 24)"

    # Resolve deployment-specific seed values only for first install/reset.
    local base="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    derive_domains "$base"
    local gw="${GATEWAY_IP:-$PUBLIC_IP}"
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    export MIHOMO_LISTEN_IPS
    local listeners candidate line backup intercept_fields intercept_in_user intercept_in_pass intercept_up_user intercept_up_pass secret_yaml_value
    secret_yaml_value="$(yaml_single_quoted_value "$secret")" \
        || { err "The mihomo controller secret cannot be represented safely in YAML."; return 1; }
    intercept_fields="$("$INTERCEPT_BIN" --config "$INTERCEPT_DIR/config.json" --print-mihomo-fields)" \
        || { err "Could not read validated interception credentials."; return 1; }
    IFS=$'\t' read -r intercept_in_user intercept_in_pass intercept_up_user intercept_up_pass <<< "$intercept_fields"
    [[ "$intercept_in_user" =~ ^[A-Za-z0-9._-]{16,255}$ \
       && "$intercept_in_pass" =~ ^[A-Za-z0-9._-]{24,255}$ \
       && "$intercept_up_user" =~ ^[A-Za-z0-9._-]{16,255}$ \
       && "$intercept_up_pass" =~ ^[A-Za-z0-9._-]{24,255}$ ]] \
        || { err "Interception credentials are unsafe for mihomo YAML."; return 1; }
    listeners="$(render_mihomo_listeners "$MIHOMO_LISTEN_IPS" "$CONSOLE_DOMAIN")"
    candidate="$(mktemp "${MIHOMO_DIR}/.config.yaml.XXXXXX")" \
        || { err "Could not create a mihomo config candidate in $MIHOMO_DIR"; return 1; }

    if ! while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '__MIHOMO_LISTENERS__' ]]; then
            printf '%s\n' "$listeners"
            continue
        fi
        line="${line//__GATEWAY_IP__/$gw}"
        line="${line//__CONSOLE_DOMAIN__/$CONSOLE_DOMAIN}"
        line="${line//__ZASH_DOMAIN__/$ZASH_DOMAIN}"
        line="${line//__CONTROLLER_SECRET__/$secret_yaml_value}"
        line="${line//__INTERCEPT_INBOUND_USERNAME__/$intercept_in_user}"
        line="${line//__INTERCEPT_INBOUND_PASSWORD__/$intercept_in_pass}"
        line="${line//__INTERCEPT_UPSTREAM_USERNAME__/$intercept_up_user}"
        line="${line//__INTERCEPT_UPSTREAM_PASSWORD__/$intercept_up_pass}"
        printf '%s\n' "$line"
    done < "$template" > "$candidate"; then
        rm -f -- "$candidate"
        err "Could not render the mihomo config candidate from $template"
        return 1
    fi
    [[ -s "$candidate" ]] \
        || { rm -f -- "$candidate"; err "Rendered mihomo config candidate is empty."; return 1; }
    chown "$DNS_SERVICE_USER:$MIHOMO_SERVICE_USER" "$candidate" \
        && chmod 0640 "$candidate" \
        || { rm -f -- "$candidate"; err "Could not secure the rendered mihomo config candidate."; return 1; }

    if ! "$MIHOMO_BIN" -t -f "$candidate" -d "$MIHOMO_DIR"; then
        rm -f -- "$candidate"
        err "mihomo candidate validation failed; live config was not changed."
        return 1
    fi
    sync -f "$candidate" 2>/dev/null || true
    if [[ -f "$config" ]]; then
        backup="$(mktemp "${config}.bak.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" \
            || { rm -f -- "$candidate"; err "Could not reserve a mihomo config backup path."; return 1; }
        cp -p -- "$config" "$backup" \
            || { rm -f -- "$candidate" "$backup"; err "Could not back up the operator mihomo config; live config was not changed."; return 1; }
        chgrp "$MIHOMO_SERVICE_USER" "$backup" \
            && chmod 0640 "$backup" \
            || { rm -f -- "$candidate" "$backup"; err "Could not secure the mihomo config backup; live config was not changed."; return 1; }
        sync -f "$backup" 2>/dev/null || true
        info "Backed up operator mihomo config to $backup"
    fi
    mv -f -- "$candidate" "$config" \
        || { rm -f -- "$candidate"; err "Could not atomically publish the mihomo config candidate."; return 1; }
    sync -f "$MIHOMO_DIR" 2>/dev/null || true
    persist_mihomo_secret "$secret" || return 1
    MIHOMO_SEED_PORTS_REQUIRED=1

    ok "mihomo config ${mode/--/} candidate validated and atomically installed at $config."
}

reset_mihomo_config() {
    check_root
    install_gum
    load_mihomo_reset_context || return 1
    warn "Explicit reset requested: the current operator mihomo config will be backed up and replaced with the validated seed."
    render_mihomo_config --reset || return 1
    restart_services || return 1
    ok "mihomo seed restored; backup retained beside ${MIHOMO_DIR}/config.yaml."
}

check_interception_routing_compatibility() {
    local dns_binary="${1:-$DNS_BIN}" intercept_binary="${2:-$INTERCEPT_BIN}"
    local output rc=0 enabled_rc=0
    INTERCEPT_ROUTING_READY=0
    INTERCEPT_ROUTING_REASON="not-checked"
    output="$("$dns_binary" --check-interception-routing \
        --mihomo-config "$MIHOMO_DIR/config.yaml" \
        --intercept-config "$INTERCEPT_DIR/config.json" 2>&1)" || rc=$?
    case "$rc" in
        0)
            INTERCEPT_ROUTING_READY=1
            INTERCEPT_ROUTING_REASON="ready"
            return 0 ;;
        3)
            INTERCEPT_ROUTING_REASON="${output##*$'\n'}"
            [[ -n "$INTERCEPT_ROUTING_REASON" ]] || INTERCEPT_ROUTING_REASON="legacy-mihomo-config"
            if [[ "$INTERCEPT_ROUTING_REASON" != legacy-mihomo-boundary-missing-clean ]]; then
                err "Interception routing is structurally incompatible or contains residual managed rules (${INTERCEPT_ROUTING_REASON}); refusing to publish or preserve a dead sidecar route."
                return 1
            fi
            "$intercept_binary" --config "$INTERCEPT_DIR/config.json" --check-enabled >/dev/null 2>&1 \
                || enabled_rc=$?
            case "$enabled_rc" in
                0)
                    err "Active interception cannot be preserved on an incompatible mihomo config (${INTERCEPT_ROUTING_REASON})."
                    return 1 ;;
                3) ;;
                *)
                    err "Could not determine whether interception is active (exit ${enabled_rc})."
                    return 1 ;;
            esac
            warn "Core services can use the clean legacy mihomo config, but extension interception is unavailable: ${INTERCEPT_ROUTING_REASON}."
            return 0 ;;
        *)
            err "Could not validate mihomo interception compatibility: ${output:-unknown error}"
            return 1 ;;
    esac
}

preflight_existing_interception_state() {
    local config="$INTERCEPT_DIR/config.json"
    [[ -e "$config" || -L "$config" ]] || return 0
    [[ -f "$config" && ! -L "$config" ]] \
        || { err "Existing interception config path is unsafe before publication: $config"; return 1; }
    if ! "$ARTIFACT_STAGE/5gpn-intercept" --config "$config" --check-config; then
        if grep -Eq '"version"[[:space:]]*:[[:space:]]*4([,[:space:]}]|$)' "$config"; then
            err "Pre-v5 interception config detected before publication: $config"
            err "Back up active state, disable the old v4 MITM transaction, then follow README's credential-preserving checked jq rebuild. No live 5gpn bytes were changed."
        else
            err "Existing interception config is invalid under the target release: $config"
        fi
        return 1
    fi
    [[ -f "$MIHOMO_DIR/config.yaml" && ! -L "$MIHOMO_DIR/config.yaml" ]] || return 0
    check_interception_routing_compatibility "$ARTIFACT_STAGE/5gpn-dns" "$ARTIFACT_STAGE/5gpn-intercept"
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
    local controller server_name cert_file host port base
    controller="$(cfg_get DNS_MIHOMO_CONTROLLER)"
    host="${controller%:*}"
    port="${controller##*:}"
    [[ "$host" != "$controller" && "$port" =~ ^[0-9]+$ ]] \
        || { warn "invalid mihomo controller address: $controller"; return 1; }
    base="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    is_valid_domain "$base" \
        || { warn "DNS_BASE_DOMAIN is required for mihomo controller TLS"; return 1; }
    derive_domains "$base" || return 1
    server_name="$ZASH_DOMAIN"
    cert_file="$(cfg_get DNS_ZASH_CERT)"
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
    secret="$(cfg_get DNS_MIHOMO_SECRET)"
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
    local ip="${1:-}" file="${MIHOMO_DIR}/whitelist.txt" tmp
    if [[ -z "$ip" && -t 0 ]]; then
        ip="$(ask_text 'Allow source IP/CIDR (e.g. 203.0.113.10/32)' || true)"
    fi
    [ -z "$ip" ] && return 0
    is_valid_ipv4_or_cidr "$ip" \
        || { err "Allowlist entry must be a canonical IPv4 address or IPv4 CIDR."; return 1; }
    [[ "$ip" == */* ]] || ip="${ip}/32"
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$MIHOMO_DIR" "$CONF_DIR" \
        && runtime_file_slot_is_safe "$file" "$CONF_DIR" \
        || { err "Refusing unsafe mihomo allowlist path: $file"; return 1; }
    install -d -g "$MIHOMO_SERVICE_USER" -m 3770 "$MIHOMO_DIR"
    [[ ! -e "$file" || ( -f "$file" && ! -L "$file" ) ]] \
        || { err "Refusing unsafe allowlist path: $file"; return 1; }
    tmp="$(mktemp "${MIHOMO_DIR}/.whitelist.XXXXXX")" || return 1
    if [[ -f "$file" ]] && ! cat "$file" > "$tmp"; then
        rm -f -- "$tmp"
        err "Could not read the existing allowlist: $file"
        return 1
    fi
    if [[ ! -f "$file" ]] || ! grep -qxF "$ip" "$file"; then
        printf '%s\n' "$ip" >> "$tmp" \
            || { rm -f -- "$tmp"; err "Could not update the allowlist candidate."; return 1; }
    fi
    chown "$DNS_SERVICE_USER:$MIHOMO_SERVICE_USER" "$tmp" \
        && chmod 0640 "$tmp" \
        || { rm -f -- "$tmp"; err "Could not secure the allowlist candidate."; return 1; }
    sync -f "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file" \
        || { rm -f -- "$tmp"; err "Could not publish the allowlist candidate."; return 1; }
    sync -f "$MIHOMO_DIR" 2>/dev/null || true
    apply_whitelist
}

# del_allow_ip removes a source IP/CIDR from the zashboard allowlist and
# refreshes it live. Same optional-arg/prompt convention as add_allow_ip.
del_allow_ip() {
    check_root
    install_gum
    local ip="${1:-}" file="${MIHOMO_DIR}/whitelist.txt" tmp
    if [[ -z "$ip" && -t 0 ]]; then
        ip="$(ask_text 'Remove source IP/CIDR' || true)"
    fi
    [ -z "$ip" ] && return 0
    is_valid_ipv4_or_cidr "$ip" \
        || { err "Allowlist entry must be a canonical IPv4 address or IPv4 CIDR."; return 1; }
    [[ "$ip" == */* ]] || ip="${ip}/32"
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$MIHOMO_DIR" "$CONF_DIR" \
        && runtime_file_slot_is_safe "$file" "$CONF_DIR" \
        || { err "Refusing unsafe mihomo allowlist path: $file"; return 1; }
    [[ -f "$file" && ! -L "$file" ]] || {
        [[ -e "$file" ]] \
            && { err "Refusing unsafe allowlist path: $file"; return 1; }
        warn "No whitelist.txt yet."
        return 0
    }
    tmp="$(mktemp "${MIHOMO_DIR}/.whitelist.XXXXXX")" || return 1
    awk -v entry="$ip" '$0 != entry' "$file" > "$tmp" \
        || { rm -f -- "$tmp"; err "Could not update the allowlist candidate."; return 1; }
    chown "$DNS_SERVICE_USER:$MIHOMO_SERVICE_USER" "$tmp" \
        && chmod 0640 "$tmp" \
        || { rm -f -- "$tmp"; err "Could not secure the allowlist candidate."; return 1; }
    sync -f "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file" \
        || { rm -f -- "$tmp"; err "Could not publish the allowlist candidate."; return 1; }
    sync -f "$MIHOMO_DIR" 2>/dev/null || true
    apply_whitelist
}

install_mihomo_runtime_assets() {
    local runtime_dir="${BASE_DIR}/etc/mihomo" asset source candidate
    install -d -m 0755 "$runtime_dir" \
        || { err "Could not create the installed mihomo asset directory: $runtime_dir"; return 1; }

    for asset in config.yaml.tmpl whitelist.seed.txt; do
        source="${SCRIPT_DIR}/etc/mihomo/${asset}"
        [[ -f "$source" && -r "$source" && -s "$source" ]] \
            || { err "Required mihomo runtime asset is missing, unreadable, or empty: $source"; return 1; }
    done

    for asset in config.yaml.tmpl whitelist.seed.txt; do
        source="${SCRIPT_DIR}/etc/mihomo/${asset}"
        candidate="$(mktemp "${runtime_dir}/.${asset}.XXXXXX")" \
            || { err "Could not stage mihomo runtime asset: $asset"; return 1; }
        install -m 0644 "$source" "$candidate" \
            || { rm -f -- "$candidate"; err "Could not copy mihomo runtime asset: $asset"; return 1; }
        sync -f "$candidate" 2>/dev/null || true
        mv -f -- "$candidate" "${runtime_dir}/${asset}" \
            || { rm -f -- "$candidate"; err "Could not publish mihomo runtime asset: $asset"; return 1; }
    done
}

install_files() {
    info "Installing config files and scripts..."
    preflight_runtime_publication_paths || return 1
    mkdir -p "$BASE_DIR" "$SCRIPTS_DIR" "$WWW_DIR" \
             "$CONF_DIR" "$DNS_CERT_DIR" "$DNS_RULES_DIR_DEFAULT"

    # Per-category subdirectories hold subscription-fetched caches. Ordered
    # DNS intent rules themselves live only in policy.json.
    install -d -m 0755 "${DNS_RULES_DIR_DEFAULT}"/{block,direct,proxy,chnroute}

    # Fresh-install fix (defense in depth #1): seed the manual chnroute file from
    # the bundled snapshot so 5gpn-dns has a non-empty chnroute at first boot,
    # before the subscription manager's in-process fetch has had a chance to run.
    # Only when the cache is absent — never clobber a fresher subscription-fetched
    # cache on re-install. DNS_CHNROUTE (dns.env) points at this same path.
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

    # repo scripts -> /opt/5gpn/scripts.
    for f in "${SCRIPT_DIR}"/scripts/*.sh; do
        [[ -e "$f" ]] || continue
        install -m 0755 "$f" "${SCRIPTS_DIR}/$(basename "$f")"
    done
    # repo systemd units -> /opt/5gpn/etc/systemd (staged copies; install_units
    # installs them into /etc/systemd/system from here or from the checkout).
    install -d -m 0755 "${BASE_DIR}/etc/systemd"
    for u in "${SCRIPT_DIR}"/etc/systemd/*.service "${SCRIPT_DIR}"/etc/systemd/*.path \
             "${SCRIPT_DIR}"/etc/systemd/*.timer; do
        [[ -e "$u" ]] || continue
        install -m 0644 "$u" "${BASE_DIR}/etc/systemd/$(basename "$u")"
    done
    install -d -m 0755 "${BASE_DIR}/etc/polkit-1/rules.d"
    install -m 0644 "${SCRIPT_DIR}/etc/polkit-1/rules.d/50-5gpn.rules" \
        "${BASE_DIR}/etc/polkit-1/rules.d/50-5gpn.rules"
    # The installed management script resolves reset assets relative to
    # /opt/5gpn, so persist every mihomo seed input beside that script.
    install_mihomo_runtime_assets || return 1
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
    install -d -m 0755 "$BASE_DIR" || return 1
    [[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] \
        || { err "Installer must come from the verified quick-install bundle or a local checkout."; return 1; }
    publish_executable "$SCRIPT_PATH" "${BASE_DIR}/install.sh" || return 1
    local quick_source="${SCRIPT_DIR}/quick-install.sh"
    [[ -f "$quick_source" && ! -L "$quick_source" ]] \
        || { err "Verified quick-install.sh is required for future release-channel upgrades."; return 1; }
    publish_executable "$quick_source" "${BASE_DIR}/quick-install.sh" || return 1
    if [[ ( -e /usr/local/bin/5gpn || -L /usr/local/bin/5gpn ) ]] && ! launcher_owned; then
        err "Refusing to overwrite an unowned /usr/local/bin/5gpn."
        return 1
    fi
    local launcher
    launcher="$(mktemp /usr/local/bin/.5gpn.XXXXXX)" || return 1
    if ! cat > "$launcher" <<'EOF'
#!/usr/bin/env bash
# Managed by 5gpn installer
# 5gpn management launcher. `5gpn` opens the menu; `5gpn <subcommand>` runs it
# directly (e.g. 5gpn status, 5gpn restart, 5gpn uninstall).
BK=/opt/5gpn/install.sh
[ -f "$BK" ] || { echo "5gpn backend missing ($BK); re-run the installer." >&2; exit 1; }
if [ $# -eq 0 ]; then exec bash "$BK" menu; else exec bash "$BK" "$@"; fi
EOF
    then
        rm -f -- "$launcher" 2>/dev/null || true
        return 1
    fi
    chmod 0755 "$launcher" || { rm -f -- "$launcher" 2>/dev/null || true; return 1; }
    mv -f -- "$launcher" /usr/local/bin/5gpn \
        || { rm -f -- "$launcher" 2>/dev/null || true; return 1; }
    launcher_owned || { err "Management launcher verification failed after publication."; return 1; }
    ok "Management command installed: type '5gpn' to manage (status / restart / configure / uninstall / …)."
}

# restart_services restarts the three 5gpn runtime units. The in-process bot and
# iOS server come back with 5gpn-dns; the interception sidecar remains isolated.
restart_services() {
    check_root
    info "Restarting 5gpn services..."
    start_services
}

# Resolve the explicit mihomo-reset context from the current persisted schema.
load_mihomo_reset_context() {
    load_persisted_install_config \
        || { err "A current ${CONF_DIR}/dns.env is required for mihomo reset."; return 1; }
    validate_install_config || return 1
    export PUBLIC_IP GATEWAY_IP BASE_DOMAIN CERT_MODE CERT_EMAIL MIHOMO_LISTEN_IPS
}

# derive_domains <base> — the SINGLE derivation of the three service subdomains
# from the operator's ONE base (apex) domain. This is the ONLY place that knows
# the console./zash./dot. prefix scheme -- every other call site (mihomo config
# render and dns.env writer) MUST obtain the derived domains by
# calling this function (or reading the globals it sets/exports), never by
# re-deriving "console.${base}"/"zash.${base}" inline, to avoid drift.
# The base must already be validated. Sets BASE_DOMAIN plus the derived globals
# and exports them. The selected certificate mode covers all three names.
derive_domains() {
    is_valid_domain "${1:-}" || { err "Base domain is missing or invalid."; return 1; }
    BASE_DOMAIN="$1"
    CONSOLE_DOMAIN="console.${BASE_DOMAIN}"
    ZASH_DOMAIN="zash.${BASE_DOMAIN}"
    DOT_DOMAIN="dot.${BASE_DOMAIN}"
    export BASE_DOMAIN CONSOLE_DOMAIN ZASH_DOMAIN DOT_DOMAIN
}

load_persisted_domains() {
    local base
    base="$(cfg_get DNS_BASE_DOMAIN)"
    is_valid_domain "$base" \
        || { err "Persisted DNS_BASE_DOMAIN is missing or invalid."; return 1; }
    derive_domains "$base"
}

# manage_menu is the interactive management TUI shown by `5gpn`. gum when
# available on a TTY; a numbered read-menu otherwise. Loops until Quit.
manage_menu() {
    check_root
    run_management_with_install_lock install_gum
    activate_verified_installed_gum
    if [[ ! -t 0 ]]; then
        err "The 5gpn menu is interactive. Run a subcommand directly, e.g.:"
        echo "  5gpn status | 5gpn restart | 5gpn uninstall" >&2
        exit 1
    fi
    local labels=(
        "状态 Status"
        "重启服务 Restart services"
        "编辑安装配置 Configure installation"
        "重载规则 Reload rules"
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
            "重启服务 Restart services")            run_management_with_install_lock restart_services ;;
            "编辑安装配置 Configure installation")  full_install configure ;;
            "重载规则 Reload rules")                       run_management_with_install_lock reload_rules ;;
            "添加 zashboard 白名单IP Add zashboard allowlist IP")    run_management_with_install_lock add_allow_ip ;;
            "移除 zashboard 白名单IP Remove zashboard allowlist IP") run_management_with_install_lock del_allow_ip ;;
            "重新生成 iOS 描述文件 Regenerate iOS profile") run_management_with_install_and_cert_lock regen_ios ;;
            "轮换控制台令牌 Rotate console token")   run_management_with_install_lock rotate_token ;;
            "设置 Cloudflare Token Set Cloudflare token") run_management_with_install_and_cert_lock set_cf_token ;;
            "重置 mihomo 配置 Reset mihomo config")
                if ask_yesno "确认备份并重置 operator-owned mihomo config?"; then run_management_with_install_lock reset_mihomo_config; fi ;;
            "配置 Telegram Bot")                    run_management_with_install_lock setup_tgbot ;;
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
        http-01) printf '%s\n' http-01 ;;
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

is_valid_ipv4_or_cidr() {
    local value="${1:-}" ip prefix
    case "$value" in
        */*)
            ip="${value%%/*}"
            prefix="${value#*/}"
            [[ "$prefix" =~ ^(0|[1-9]|[12][0-9]|3[0-2])$ ]] || return 1
            is_valid_ipv4 "$ip"
            ;;
        *) is_valid_ipv4 "$value" ;;
    esac
}

# install_cert <base_domain> — provision ONE scoped production lineage and
# deploy it to all three role directories:
#   dot  -> ${DOT_CERT_DIR}  (serves DoT :853; also signs the iOS profile)
#   web  -> ${WEB_CERT_DIR}  (serves the web console behind the mihomo SNI split)
#   zash -> ${ZASH_CERT_DIR} (serves the zashboard panel)
# Three modes (resolved from persisted dns.env or the TUI):
#   cloudflare (default) — Let's Encrypt DNS-01 through the Cloudflare API
#                       for apex + *.<base>; an owned lineage auto-renews
#                       unattended via the daily scoped timer. A protected token
#                       is required for owned issuance and renewal, including
#                       reuse of an owned lineage. ensure_cf_token
#                       obtains it with this precedence:
#                         1. Valid saved /etc/5gpn/acme/cloudflare.ini — reused.
#                         2. Interactive ask_secret on a TTY (guarded || true).
#                         3. Explicit error — non-interactive with no saved token.
#                       Use '5gpn set-cf-token' (or the manage menu) to update
#                       the token at any time.
#   http-01            — Let's Encrypt standalone HTTP challenge for the exact
#                       console/zash/dot service SANs. The TUI confirms the DNS
#                       plan, then waits for 1.1.1.1 to see every A record at
#                       PUBLIC_IP with no AAAA. Initial issuance keeps an
#                       originally active mihomo stopped through role-certificate
#                       publication, then full_install starts it. Due renewal
#                       briefly stops and restores mihomo around Certbot.
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
        http-01)
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

cert_provenance_get() {
    local key="$1" file="${DNS_CERT_DIR}/.provenance"
    [[ -f "$file" && ! -L "$file" ]] || return 0
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

cert_provenance_matches() {
    local mode="$1" base="$2"
    [[ "$(cert_provenance_get mode)" == "$mode" \
       && "$(cert_provenance_get base)" == "$base" ]]
}

cert_provenance_base_matches() {
    local base="$1" mode
    [[ "$(cert_provenance_get base)" == "$base" ]] || return 1
    mode="$(cert_provenance_get mode)"
    [[ "$mode" == cloudflare || "$mode" == http-01 || "$mode" == debug ]]
}

certbot_ownership_record_is_safe() {
    local file="$CERTBOT_OWNERSHIP_FILE" line base previous="" count=0 index=0
    local -a lines=()
    root_plain_file_metadata_is_safe "$file" 0 640 || return 1
    mapfile -t lines < "$file" || return 1
    [[ "${#lines[@]}" -ge 2 && "${#lines[@]}" -le 17 \
       && "${lines[0]}" == 'version=1' ]] || return 1
    for ((index = 1; index < ${#lines[@]}; index++)); do
        line="${lines[$index]}"
        [[ "$line" == owned=* ]] || return 1
        base="${line#owned=}"
        is_valid_domain "$base" || return 1
        [[ -z "$previous" || "$previous" < "$base" ]] || return 1
        previous="$base"
        ((count += 1))
    done
    [[ "$count" -ge 1 && "$count" -le 16 ]]
}

certbot_ownership_record_has() {
    local base="$1"
    certbot_ownership_record_is_safe \
        && grep -Fqx "owned=${base}" "$CERTBOT_OWNERSHIP_FILE"
}

persist_certbot_lineage_ownership() {
    local base="$1" tmp
    local -a owned=()
    is_valid_domain "$base" || return 1
    ensure_dns_cert_root || return 1
    if [[ -e "$CERTBOT_OWNERSHIP_FILE" || -L "$CERTBOT_OWNERSHIP_FILE" ]]; then
        certbot_ownership_record_is_safe \
            || { err "The retained Certbot ownership record is unsafe."; return 1; }
        certbot_ownership_record_has "$base" && return 0
        mapfile -t owned < <(sed -n 's/^owned=//p' "$CERTBOT_OWNERSHIP_FILE")
    fi
    owned+=("$base")
    [[ "${#owned[@]}" -le 16 ]] \
        || { err "Too many retained 5gpn Certbot lineage ownership records."; return 1; }
    tmp="$(mktemp "${DNS_CERT_DIR}/.certbot-ownership.XXXXXX")" || return 1
    {
        printf 'version=1\n'
        printf '%s\n' "${owned[@]}" | sort -u | sed 's/^/owned=/'
    } > "$tmp" \
        && chown root:root "$tmp" \
        && chmod 0640 "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$tmp" 2>/dev/null \
        || { rm -f -- "$tmp"; err "Could not durably write the Certbot ownership record."; return 1; }
    mv -f -- "$tmp" "$CERTBOT_OWNERSHIP_FILE" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$DNS_CERT_DIR" 2>/dev/null \
        || { err "Could not durably publish the Certbot ownership record."; return 1; }
    certbot_ownership_record_has "$base" \
        || { err "Could not persist Certbot lineage ownership for ${base}."; return 1; }
}

certbot_lineage_owned_by_5gpn() {
    local base="$1" mode
    if [[ -e "$CERTBOT_OWNERSHIP_FILE" || -L "$CERTBOT_OWNERSHIP_FILE" ]]; then
        certbot_ownership_record_has "$base"
        return
    fi
    # One-time compatibility with the immediately preceding beta: preserve its
    # ownership proof before any mode switch overwrites active-role provenance.
    cert_provenance_base_matches "$base" || return 1
    mode="$(cert_provenance_get mode)"
    [[ "$mode" == cloudflare || "$mode" == http-01 ]] \
        && [[ "$(cert_provenance_get certbot_lineage)" == owned ]]
}

certbot_lineage_artifacts_exist() {
    local base="$1"
    [[ -e "${LE_LIVE_ROOT}/${base}" \
       || -e "${LE_ARCHIVE_ROOT}/${base}" \
       || -e "${LE_RENEWAL_ROOT}/${base}.conf" ]] \
        || compgen -G "${LE_LIVE_ROOT}/${base}-[0-9][0-9][0-9][0-9]" >/dev/null \
        || compgen -G "${LE_ARCHIVE_ROOT}/${base}-[0-9][0-9][0-9][0-9]" >/dev/null \
        || compgen -G "${LE_RENEWAL_ROOT}/${base}-[0-9][0-9][0-9][0-9].conf" >/dev/null
}

global_certbot_timer_exists() {
    systemctl cat certbot.timer >/dev/null 2>&1
}

# Stop the distro-wide unscoped timer before inspecting or mutating certificate
# state. The install transaction records its enabled/active state and restores
# it on rollback. A non-owning certificate flow also restores it before commit.
pause_global_certbot_timer() {
    if global_certbot_timer_exists; then
        systemctl stop certbot.timer \
            || { err "Could not stop the distro certbot.timer before the certificate transaction."; return 1; }
        systemctl is-active --quiet certbot.timer 2>/dev/null \
            && { err "The distro certbot.timer remained active after stop; refusing a certificate race."; return 1; }
    fi
    if systemctl is-active --quiet certbot.service 2>/dev/null; then
        err "certbot.service is already running outside the 5gpn certificate lock."
        err "Wait for it to finish, then rerun the installer."
        return 1
    fi
}

# The distro timer invokes an unscoped `certbot renew`. It can be disabled only
# when every visible Certbot lineage belongs to this exact 5gpn base; otherwise
# disabling it would silently break renewal for unrelated services.
certbot_lineage_set_is_exclusive() {
    local base="$1" root entry name expected
    local -a roots=("$LE_LIVE_ROOT" "$LE_ARCHIVE_ROOT" "$LE_RENEWAL_ROOT")
    for root in "${roots[@]}"; do
        [[ ! -e "$root" && ! -L "$root" ]] && continue
        [[ -d "$root" && ! -L "$root" \
           && "$(readlink -f -- "$root" 2>/dev/null || true)" == "$root" ]] \
            || { err "Unsafe Certbot lineage root: $root"; return 1; }
        while IFS= read -r -d '' entry; do
            name="$(basename -- "$entry")"
            if [[ "$root" == "$LE_RENEWAL_ROOT" ]]; then
                expected="${base}.conf"
            else
                expected="$base"
                [[ "$name" == README && -f "$entry" && ! -L "$entry" ]] && continue
            fi
            if [[ "$name" != "$expected" ]]; then
                err "Unrelated Certbot lineage state prevents disabling the distro certbot.timer: $entry"
                err "Configure independent locked renewal for every lineage before installing an owned 5gpn lineage."
                return 1
            fi
        done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    done
}

global_certbot_timer_state_is_safe() {
    local file="$GLOBAL_CERTBOT_TIMER_STATE" root_gid enabled active
    root_gid="$(account_gid root)"
    [[ -n "$root_gid" \
       && -f "$file" && ! -L "$file" \
       && "$(file_uid "$file")" == 0 \
       && "$(file_gid "$file")" == "$root_gid" \
       && "$(file_mode "$file")" == 600 \
       && "$(file_nlink "$file")" == 1 ]] || return 1
    grep -Eq '^version=1$' "$file" \
        && grep -Eq '^exists=1$' "$file" \
        && grep -Eq '^enabled=(enabled|enabled-runtime|disabled|masked|masked-runtime|static|indirect)$' "$file" \
        && grep -Eq '^active=(active|inactive)$' "$file" \
        && [[ "$(wc -l < "$file" | tr -d '[:space:]')" == 4 ]] \
        || return 1
    enabled="$(grep -E '^enabled=' "$file" | cut -d= -f2-)"
    active="$(grep -E '^active=' "$file" | cut -d= -f2-)"
    [[ "$active" != active || ( "$enabled" != masked && "$enabled" != masked-runtime ) ]]
}

persist_global_certbot_timer_state() {
    local enabled active tmp
    if [[ -e "$GLOBAL_CERTBOT_TIMER_STATE" || -L "$GLOBAL_CERTBOT_TIMER_STATE" ]]; then
        global_certbot_timer_state_is_safe \
            || { err "The persisted distro Certbot timer state is unsafe."; return 1; }
        return 0
    fi
    [[ -n "$ROLLBACK_DIR" \
       && -f "$ROLLBACK_DIR/unit-state/certbot.timer.exists" \
       && -f "$ROLLBACK_DIR/unit-state/certbot.timer.enabled-state" \
       && -f "$ROLLBACK_DIR/unit-state/certbot.timer.active-state" ]] \
        || { err "The pre-takeover distro Certbot timer state was not captured."; return 1; }
    enabled="$(<"$ROLLBACK_DIR/unit-state/certbot.timer.enabled-state")"
    active="$(<"$ROLLBACK_DIR/unit-state/certbot.timer.active-state")"
    [[ "$enabled" =~ ^(enabled|enabled-runtime|disabled|masked|masked-runtime|static|indirect)$ \
       && "$active" =~ ^(active|inactive)$ ]] \
        || { err "The distro Certbot timer is in a state that cannot be restored exactly: ${enabled}/${active}"; return 1; }
    [[ "$active" != active || ( "$enabled" != masked && "$enabled" != masked-runtime ) ]] \
        || { err "An active masked distro Certbot timer cannot be restored exactly; refusing takeover."; return 1; }
    ensure_acme_dir || return 1
    tmp="$(mktemp "${ACME_DIR}/.certbot.timer.state.XXXXXX")" || return 1
    printf 'version=1\nexists=1\nenabled=%s\nactive=%s\n' "$enabled" "$active" > "$tmp" \
        && chown root:root "$tmp" \
        && chmod 0600 "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$GLOBAL_CERTBOT_TIMER_STATE" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$ACME_DIR" 2>/dev/null \
        || { err "Could not durably persist the distro Certbot timer takeover state."; return 1; }
    global_certbot_timer_state_is_safe \
        || { err "Could not persist the distro Certbot timer takeover state."; return 1; }
}

restore_persisted_global_certbot_timer() {
    local enabled active actual
    [[ -e "$GLOBAL_CERTBOT_TIMER_STATE" || -L "$GLOBAL_CERTBOT_TIMER_STATE" ]] || return 0
    global_certbot_timer_state_is_safe \
        || { err "The persisted distro Certbot timer state is unsafe; refusing restoration."; return 1; }
    enabled="$(grep -E '^enabled=' "$GLOBAL_CERTBOT_TIMER_STATE" | cut -d= -f2-)"
    active="$(grep -E '^active=' "$GLOBAL_CERTBOT_TIMER_STATE" | cut -d= -f2-)"
    systemctl stop certbot.timer >/dev/null 2>&1 \
        || { err "Could not stop certbot.timer before restoring its saved state."; return 1; }
    case "$enabled" in
        enabled) systemctl enable certbot.timer >/dev/null 2>&1 || return 1 ;;
        enabled-runtime) systemctl enable --runtime certbot.timer >/dev/null 2>&1 || return 1 ;;
        disabled) systemctl disable certbot.timer >/dev/null 2>&1 || return 1 ;;
        masked) systemctl mask certbot.timer >/dev/null 2>&1 || return 1 ;;
        masked-runtime) systemctl mask --runtime certbot.timer >/dev/null 2>&1 || return 1 ;;
        static|indirect) ;;
        *) return 1 ;;
    esac
    if [[ "$active" == active ]]; then
        systemctl start certbot.timer >/dev/null 2>&1 || return 1
    fi
    actual="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
    [[ "$actual" == "$enabled" ]] \
        || { err "certbot.timer enablement restore mismatch: expected ${enabled}, got ${actual:-unknown}."; return 1; }
    actual="$(systemctl is-active certbot.timer 2>/dev/null || true)"
    [[ "$actual" == "$active" ]] \
        || { err "certbot.timer activity restore mismatch: expected ${active}, got ${actual:-unknown}."; return 1; }
    rm -f -- "$GLOBAL_CERTBOT_TIMER_STATE" || return 1
    sync -f "$ACME_DIR" 2>/dev/null || true
    if [[ "$enabled" != enabled && "$enabled" != enabled-runtime ]] \
       || [[ "$active" != active ]]; then
        warn "Restored the original distro certbot.timer state (${enabled}/${active}); it does not provide active automatic renewal."
    fi
}

disable_global_certbot_timer_for_owned_lineage() {
    local base="$1"
    if global_certbot_timer_exists; then
        certbot_lineage_set_is_exclusive "$base" || return 1
        persist_global_certbot_timer_state || return 1
        systemctl disable --now certbot.timer \
            || { err "Could not disable the unscoped distro certbot.timer."; return 1; }
        systemctl is-active --quiet certbot.timer 2>/dev/null \
            && { err "The distro certbot.timer is still active."; return 1; }
        systemctl is-enabled --quiet certbot.timer 2>/dev/null \
            && { err "The distro certbot.timer is still enabled."; return 1; }
    fi
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=1
}

certbot_renewal_conf_scoped() {
    local conf="$1" base="$2" key value expected server
    [[ -f "$conf" && ! -L "$conf" ]] || return 1
    for key in archive_dir cert privkey chain fullchain; do
        value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null \
            | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$key" in
            archive_dir) expected="${LE_ARCHIVE_ROOT}/${base}" ;;
            *) expected="${LE_LIVE_ROOT}/${base}/${key}.pem" ;;
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
    local base="$1" mode="$2" conf="${LE_RENEWAL_ROOT}/${base}.conf" auth value
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
    [[ -d "${LE_LIVE_ROOT}/${base}" && ! -L "${LE_LIVE_ROOT}/${base}" \
       && -d "${LE_ARCHIVE_ROOT}/${base}" && ! -L "${LE_ARCHIVE_ROOT}/${base}" ]] \
        || return 1
    if certbot_renewal_mode_matches "$base" cloudflare; then
        mode=cloudflare
    elif certbot_renewal_mode_matches "$base" http-01; then
        mode=http-01
    else
        return 1
    fi
    cert_identity_matches_mode "${LE_LIVE_ROOT}/${base}/fullchain.pem" \
        "${LE_LIVE_ROOT}/${base}/privkey.pem" "$base" "$mode"
}

write_cert_provenance() {
    local mode="$1" base="$2" lineage="${3:-none}" tmp
    case "$mode:$lineage" in
        debug:none|cloudflare:owned|cloudflare:reused|cloudflare:missing|http-01:owned|http-01:reused|http-01:missing) ;;
        *) err "Invalid certificate provenance state: ${mode}:${lineage}"; return 1 ;;
    esac
    ensure_dns_cert_root || return 1
    [[ "$lineage" != owned ]] || persist_certbot_lineage_ownership "$base" || return 1
    tmp="$(mktemp "${DNS_CERT_DIR}/.provenance.XXXXXX")" || return 1
    printf 'mode=%s\nbase=%s\ncertbot_lineage=%s\n' "$mode" "$base" "$lineage" > "$tmp"
    chmod 0640 "$tmp"
    sync -f "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$DNS_CERT_DIR/.provenance"
    sync -f "$DNS_CERT_DIR" 2>/dev/null || true
    cert_root_is_safe \
        || { err "Certificate provenance publication broke the root boundary."; return 1; }
}

decommission_certbot_lineage() {
    local base="$1" conf
    conf="${LE_RENEWAL_ROOT}/${base}.conf"
    DECOMMISSION_PRESERVE_ACME=0
    is_valid_domain "$base" \
        || { err "Cannot decommission: persisted base domain is invalid."; return 1; }
    if ! certbot_lineage_artifacts_exist "$base"; then
        info "No Certbot lineage artifacts exist for '${base}'."
        return 0
    fi
    if [[ ( -e "$CERTBOT_OWNERSHIP_FILE" || -L "$CERTBOT_OWNERSHIP_FILE" ) ]] \
       && ! certbot_ownership_record_is_safe; then
        warn "Preserving Certbot lineage '${base}': the retained ownership record is unsafe and cannot authorize deletion."
        if grep -qF -- "$ACME_DIR/cloudflare.ini" "$conf" 2>/dev/null; then
            DECOMMISSION_PRESERVE_ACME=1
        fi
        return 0
    fi
    if ! certbot_lineage_owned_by_5gpn "$base"; then
        warn "Preserving Certbot lineage '${base}': provenance does not prove that 5gpn created it."
        if grep -qF -- "$ACME_DIR/cloudflare.ini" "$conf" 2>/dev/null; then
            DECOMMISSION_PRESERVE_ACME=1
            warn "Its renewal configuration still references the 5gpn Cloudflare credential; preserving ${ACME_DIR}."
        fi
        warn "Delete that lineage manually only after checking that no other service uses it."
        return 0
    fi
    decommission_lineage_safe "$base" \
        || { err "Owned lineage '${base}' is partial, unscoped, or mode-mismatched; refusing Certbot deletion."; return 1; }
    certbot delete --non-interactive --cert-name "$base" \
        || { err "Certbot refused to delete the exact 5gpn-owned lineage '$base'."; return 1; }
    ok "Deleted the provenance-confirmed 5gpn Certbot lineage '${base}'."
}

renew_hook_owned() {
    local hook="/etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh"
    [[ -f "$hook" && ! -L "$hook" ]] || return 1
    grep -Fqx '# 5gpn-renew-hook-id: deploy-v1' "$hook" \
        && grep -qF "Let's Encrypt renewal deploy hook" "$hook" \
        && grep -qF 'DNS_BASE_DOMAIN' "$hook" \
        && grep -qF '/etc/5gpn/cert' "$hook"
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
# Only a mihomo service that was active is stopped. Failure and signal paths
# restore it from this subshell. After successful initial issuance, leave it
# stopped so install_cert can validate and publish zash/current before
# full_install's normal start_services step restores the data plane. An
# unrelated process occupying :80 is never killed and makes Certbot fail closed.
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
    if [[ "$certbot_rc" == 0 ]]; then
        # Disarm the EXIT restore only after Certbot has returned successfully.
        # Until this assignment, INT/TERM/EXIT still restore the original state.
        restore=0
    else
        restore_active_mihomo || restore_rc=$?
    fi
    trap - EXIT INT TERM
    [[ "$certbot_rc" == 0 ]] || exit "$certbot_rc"
    [[ "$restore_rc" == 0 ]] || exit "$restore_rc"
)

install_cert() {
    local base="${1:?install_cert needs a base domain}"
    local mode="$CERT_MODE"
    local live="${LE_LIVE_ROOT}/${base}"
    local lineage_origin="" lineage_artifacts=0 lineage_was_owned=0
    local force=0 cf_token_ready=0
    if [[ -e "$CERTBOT_OWNERSHIP_FILE" || -L "$CERTBOT_OWNERSHIP_FILE" ]]; then
        certbot_ownership_record_is_safe \
            || { err "The retained Certbot ownership record is unsafe."; return 1; }
    fi
    certbot_lineage_owned_by_5gpn "$base" && lineage_was_owned=1
    certbot_lineage_artifacts_exist "$base" && lineage_artifacts=1
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=0
    RELEASE_PERSISTED_GLOBAL_CERTBOT_TIMER=0

    [[ "$mode" == cloudflare || "$mode" == http-01 || "$mode" == debug ]] \
        || { err "CERT_MODE must be cloudflare, http-01, or debug."; return 1; }
    if [[ -e "$GLOBAL_CERTBOT_TIMER_STATE" || -L "$GLOBAL_CERTBOT_TIMER_STATE" ]]; then
        global_certbot_timer_state_is_safe \
            || { err "The persisted distro Certbot timer takeover state is unsafe."; return 1; }
    fi
    pause_global_certbot_timer || return 1

    if [ "$mode" = "debug" ]; then
        local debug_src="${DEBUG_CERT_DIR}/${base}"
        if cert_provenance_matches debug "$base" \
           && validate_cert_pair "${debug_src}/fullchain.pem" "${debug_src}/privkey.pem" \
                "$base" "$((30*86400))" debug \
           && { [[ -z "$GATEWAY_IP" ]] || openssl x509 -checkip "$GATEWAY_IP" -noout -in "${debug_src}/fullchain.pem" >/dev/null 2>&1; } \
           && { [[ -z "$PUBLIC_IP" ]] || openssl x509 -checkip "$PUBLIC_IP" -noout -in "${debug_src}/fullchain.pem" >/dev/null 2>&1; }; then
            info "Reusing valid matching debug certificate for *.${base}."
        else
            issue_selfsigned_wildcard "$base" || return 1
        fi
        deploy_cert_roles "$base" "$debug_src" || return 1
        if [[ "$lineage_was_owned" == 1 && "$lineage_artifacts" == 1 ]]; then
            persist_certbot_lineage_ownership "$base" || return 1
        fi
        write_cert_provenance debug "$base" none || return 1
        remove_owned_renew_hook
        remove_owned_renewal_automation || return 1
        RELEASE_PERSISTED_GLOBAL_CERTBOT_TIMER=1
        return 0
    fi

    # A canonical lineage without owned provenance is operator state. A strict,
    # still-valid fingerprint may be consumed read-only, but 5gpn never invokes
    # Certbot to renew, change SANs, or replace its authenticator. Its external
    # renewal remains responsible for the lineage; the exact deploy hook keeps
    # the role copies synchronized without transferring deletion ownership.
    if [[ "$lineage_artifacts" == 1 && "$lineage_was_owned" == 0 ]]; then
        if validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
                "$base" "$((30*86400))" production "$mode" \
           && certbot_renewal_mode_matches "$base" "$mode" \
           && { [[ ! -e "$DNS_CERT_DIR/.provenance" ]] || cert_provenance_matches "$mode" "$base"; }; then
            info "Reusing the valid externally owned ${mode} lineage for ${base} without changing it."
            deploy_cert_roles "$base" "$live" "$mode" || return 1
            write_cert_provenance "$mode" "$base" reused || return 1
            install_cert_deploy_hook || return 1
            remove_owned_renewal_automation || return 1
            RELEASE_PERSISTED_GLOBAL_CERTBOT_TIMER=1
            warn "The external lineage remains operator-owned; 5gpn did not install a public renewal timer or gain deletion authority."
            return 0
        fi
        err "The canonical Certbot lineage '${base}' exists but is not provenance-confirmed as 5gpn-owned."
        err "It is expiring, invalid, mode-mismatched, partial, or has an unsafe renewal fingerprint."
        err "Renew or repair it with its owner, or move it out of the canonical name before asking 5gpn to issue a new lineage."
        return 1
    fi

    # Purge preserves deployed role copies. If the canonical lineage is
    # entirely absent, a matching trusted role copy may recover service without
    # consuming a new issuance. Renewal stays disabled until repair.
    if [[ "$lineage_artifacts" == 0 ]] \
       && cert_provenance_matches "$mode" "$base" \
       && validate_cert_pair "${DOT_CERT_DIR}/current/fullchain.pem" "${DOT_CERT_DIR}/current/privkey.pem" \
            "$base" "$((30*86400))" production "$mode"; then
        info "Certbot lineage is missing; reusing the validated preserved ${mode} role certificate for ${base}."
        deploy_cert_roles "$base" "$DOT_CERT_DIR/current" "$mode" || return 1
        write_cert_provenance "$mode" "$base" missing || return 1
        remove_owned_renew_hook
        remove_owned_renewal_automation || return 1
        RELEASE_PERSISTED_GLOBAL_CERTBOT_TIMER=1
        warn "The preserved certificate is active, but automatic renewal is disabled until the Certbot lineage is repaired or reissued."
        return 0
    fi

    # From here the lineage is either absent or provenance-confirmed as owned.
    # Only this path may disable the distro-wide timer and invoke Certbot.
    disable_global_certbot_timer_for_owned_lineage "$base" || return 1

    # Reuse is mode-aware. The SAN shape distinguishes wildcard DNS-01 from
    # exact-name HTTP-01; renewal.conf and owned provenance prevent a mode
    # switch from silently retaining the previous authenticator.
    if [[ "$lineage_was_owned" == 1 ]] \
       && validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
            "$base" "$((30*86400))" production "$mode" \
       && certbot_renewal_mode_matches "$base" "$mode" \
       && cert_provenance_matches "$mode" "$base"; then
        lineage_origin=owned
        info "Valid owned ${mode} certificate and matching renewal authenticator for ${base} (>30d); reusing."
    else
        if [[ ! -e "$live" ]] && compgen -G "${LE_LIVE_ROOT}/${base}-[0-9][0-9][0-9][0-9]" >/dev/null; then
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
            GPN_CERT_LOCK_HELD=1 run_http_certbot "${certbot_args[@]}" \
                || { err "Certbot HTTP-01 failed. Check all three public A records, absence of AAAA, TCP/80/NAT/security-group reachability, and rate limits."; return 1; }
        else
            GPN_CERT_LOCK_HELD=1 certbot "${certbot_args[@]}" \
                || { err "Certbot DNS-01 failed for *.${base} (check the Cloudflare token's Zone:DNS:Edit scope + zone match)."; return 1; }
        fi
        lineage_origin=owned
    fi

    validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" "$base" 86400 production "$mode" \
        || { err "Issued/reused production certificate failed trust, SAN, expiry, or key validation."; return 1; }
    certbot_renewal_mode_matches "$base" "$mode" \
        || { err "Certbot renewal config is unscoped, mode-mismatched, or contains persistent hooks."; return 1; }
    if [[ "$mode" == cloudflare && "$cf_token_ready" == 0 ]]; then
        ensure_cf_token || { err "Owned Cloudflare renewal requires a protected API token even when its certificate is reusable."; return 1; }
    fi
    [[ "$lineage_origin" == owned ]] \
        || { err "Internal error: public renewal automation requires an owned lineage."; return 1; }
    deploy_cert_roles "$base" "$live" "$mode" || return 1
    write_cert_provenance "$mode" "$base" owned || return 1
    install_cert_deploy_hook || return 1
    install_renewal_automation "$base" || return 1
}

# issue_selfsigned_wildcard <base> — CERT_MODE=debug: a long-lived (825d)
# self-signed WILDCARD cert (CN=<base>, SAN=<base>+*.<base>+gateway/public IPs)
# so every role's cert works by IP or name on an internal test box. Debug
# material lives under /etc/5gpn/debug-cert only: writing through Certbot's
# /etc/letsencrypt/live symlinks can truncate the real archive certificates.
# Debug mode has no renewal machinery. Remove the production renewal units so
# the daily timer cannot run an unwanted renewal after an explicit mode change.
issue_selfsigned_wildcard() {
    local base="$1"
    local live="${DEBUG_CERT_DIR}/${base}" tmp
    ensure_debug_cert_root || return 1
    runtime_directory_slot_is_safe "$live" "$DEBUG_CERT_DIR" \
        || { err "CERT_MODE=debug: unsafe lineage path: $live"; return 1; }
    if [[ -e "$live" || -L "$live" ]]; then
        debug_cert_lineage_slot_is_safe "$live" \
            || { err "CERT_MODE=debug: unsafe existing lineage tree: $live"; return 1; }
    else
        install -d -o root -g root -m 0700 "$live" || return 1
    fi
    tmp="$(mktemp -d "${live}/.new.XXXXXX")" \
        || { err "CERT_MODE=debug: could not create a certificate staging directory."; return 1; }
    write_ownership_marker "$tmp" "$TEMP_OWNERSHIP_MARKER" "$TEMP_OWNERSHIP_VALUE" \
        || { rmdir -- "$tmp"; return 1; }
    local san="DNS:${base},DNS:*.${base}"
    [[ -n "${GATEWAY_IP:-}" ]] && san="${san},IP:${GATEWAY_IP}"
    [[ -n "${PUBLIC_IP:-}" && "${PUBLIC_IP:-}" != "${GATEWAY_IP:-}" ]] && san="${san},IP:${PUBLIC_IP}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "${tmp}/privkey.pem" -out "${tmp}/fullchain.pem" \
        -subj "/CN=${base}" -addext "subjectAltName=${san}" >/dev/null 2>&1 \
        || { remove_owned_root "$tmp" "$TEMP_OWNERSHIP_MARKER" "$TEMP_OWNERSHIP_VALUE" || true; err "CERT_MODE=debug: self-signed wildcard cert generation failed (is openssl installed?)."; return 1; }
    chmod 0600 "${tmp}/privkey.pem" "${tmp}/fullchain.pem"
    # Candidate files are complete before either live role source is replaced.
    # Both moves stay on the same filesystem and are therefore atomic.
    sync -f "${tmp}/privkey.pem" "${tmp}/fullchain.pem" 2>/dev/null || true
    mv -f -- "${tmp}/privkey.pem" "${live}/privkey.pem"
    mv -f -- "${tmp}/fullchain.pem" "${live}/fullchain.pem"
    rm -f -- "${tmp}/${TEMP_OWNERSHIP_MARKER}"
    rmdir -- "$tmp"
    debug_cert_root_is_safe \
        || { err "CERT_MODE=debug: published lineage failed filesystem validation."; return 1; }
    warn "CERT_MODE=debug: SELF-SIGNED WILDCARD cert for *.${base} (CN=${base}, SAN=${san}). NOT trusted by clients — test/dev only."
    # Dismantle production renewal machinery when switching to debug mode.
    remove_owned_renew_hook
    remove_owned_renewal_automation
}

# deploy_cert_roles <base> — copy the selected lineage to all three role dirs.
# deploy_cert_roles <base> [src_dir] [mode] — copy the selected cert to all role
# dirs. Defaults to reading from the Certbot lineage; a preserved role copy or
# debug mode may pass an alternate source directory explicitly.
deploy_cert_roles() {
    local base="$1" src="${2:-${LE_LIVE_ROOT}/${base}}" mode="${3:-${CERT_MODE:-cloudflare}}"
    local r dest group generation final link_tmp old trust=production i j rollback_link
    local -a roles=(dot web zash) dests=() generations=() links=() old_targets=()
    [[ "$src" == "$DEBUG_CERT_DIR"/* ]] && { trust=debug; mode=debug; }
    validate_cert_pair "${src}/fullchain.pem" "${src}/privkey.pem" "$base" 0 "$trust" "$mode" \
        || { err "Certificate source failed validation: $src"; return 1; }
    ensure_dns_cert_root || return 1

    # Each role publishes one complete generation through an atomically replaced
    # relative symlink. Readers therefore see the old pair or the new pair,
    # never a key and certificate from different generations.
    for r in "${roles[@]}"; do
        dest="${DNS_CERT_DIR}/$r"
        group="$DNS_SERVICE_USER"
        [[ "$r" == zash ]] && group="$MIHOMO_SERVICE_USER"
        if [[ -e "$dest" || -L "$dest" ]]; then
            cert_role_tree_is_safe_for_recursive_metadata "$dest" \
                || { cleanup_cert_role_candidates roles dests generations links; err "Certificate role boundary is unsafe: $dest"; return 1; }
        else
            install -d -o root -g "$group" -m 0750 "$dest" \
                || { cleanup_cert_role_candidates roles dests generations links; return 1; }
            write_ownership_marker "$dest" "$CERT_ROLE_MARKER" "${CERT_ROLE_VALUE_PREFIX}:${r}" \
                || { cleanup_cert_role_candidates roles dests generations links; return 1; }
            install -d -o root -g "$group" -m 0750 "${dest}/generations" \
                || { cleanup_cert_role_candidates roles dests generations links; return 1; }
            cert_role_tree_is_safe_for_recursive_metadata "$dest" \
                || { cleanup_cert_role_candidates roles dests generations links; err "Could not establish certificate role boundary: $dest"; return 1; }
        fi
        if [[ -e "${dest}/current" || -L "${dest}/current" ]]; then
            [[ -L "${dest}/current" ]] \
                || { cleanup_cert_role_candidates roles dests generations links; err "Certificate role current path is not a symlink: ${dest}/current"; return 1; }
            old="$(readlink -- "${dest}/current")"
            [[ "$old" =~ ^generations/[A-Za-z0-9._-]+$ && -d "${dest}/${old}" ]] \
                || { cleanup_cert_role_candidates roles dests generations links; err "Certificate role current symlink is unsafe: ${dest}/current"; return 1; }
        else
            old=""
        fi

        generation="$(mktemp -d "${dest}/generations/.new.XXXXXX")" \
            || { cleanup_cert_role_candidates roles dests generations links; return 1; }
        dests+=("$dest")
        generations+=("$generation")
        links+=("")
        old_targets+=("$old")
        i=$((${#generations[@]} - 1))
        chown "root:$group" "$generation" && chmod 0750 "$generation" \
            || { cleanup_cert_role_candidates roles dests generations links; return 1; }
        install -g "$group" -m 0640 "${src}/fullchain.pem" "${generation}/fullchain.pem" \
            && install -g "$group" -m 0640 "${src}/privkey.pem" "${generation}/privkey.pem" \
            && validate_cert_pair "${generation}/fullchain.pem" "${generation}/privkey.pem" \
                "$base" 0 "$trust" "$mode" \
            || { cleanup_cert_role_candidates roles dests generations links; return 1; }
        sync -f "${generation}/fullchain.pem" "${generation}/privkey.pem" "$generation" 2>/dev/null || true
        final="${dest}/generations/generation-$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}-${RANDOM}"
        [[ ! -e "$final" ]] \
            || { cleanup_cert_role_candidates roles dests generations links; return 1; }
        mv -- "$generation" "$final" \
            || { cleanup_cert_role_candidates roles dests generations links; return 1; }
        generations[$i]="$final"
        link_tmp="${dest}/.current.${BASHPID}.${RANDOM}"
        [[ ! -e "$link_tmp" && ! -L "$link_tmp" ]] \
            || { cleanup_cert_role_candidates roles dests generations links; return 1; }
        links[$i]="$link_tmp"
        ln -s "generations/$(basename -- "$final")" "$link_tmp" \
            || { cleanup_cert_role_candidates roles dests generations links; return 1; }
    done

    for i in "${!roles[@]}"; do
        if ! mv -Tf -- "${links[$i]}" "${dests[$i]}/current"; then
            for ((j = 0; j < i; j++)); do
                if [[ -n "${old_targets[$j]}" ]]; then
                    rollback_link="${dests[$j]}/.rollback.${BASHPID}.${RANDOM}"
                    ln -s "${old_targets[$j]}" "$rollback_link" \
                        && mv -Tf -- "$rollback_link" "${dests[$j]}/current" || true
                    rm -f -- "$rollback_link"
                else
                    rm -f -- "${dests[$j]}/current"
                fi
            done
            cleanup_cert_role_candidates roles dests generations links
            err "Could not atomically publish certificate role ${roles[$i]}."
            return 1
        fi
        links[$i]=""
    done

    for i in "${!roles[@]}"; do
        r="${roles[$i]}"
        dest="${dests[$i]}"
        final="${generations[$i]}"
        clear_owned_scope "$dest" "$CERT_ROLE_MARKER" "${CERT_ROLE_VALUE_PREFIX}:${r}" \
            "${dest}/generations" "$(basename -- "$final")" || return 1
        rm -f -- "${dest}/fullchain.pem" "${dest}/privkey.pem"
    done
    cert_root_is_safe \
        || { err "Published certificate role tree failed ownership validation."; return 1; }
    ok "${mode} certificate for ${base} deployed to dot/web/zash role dirs."
}

# install_renewal_automation installs a daily systemd timer running only the
# mode-aware public-certificate helper. The independent static
# 5gpn-intercept-cert.timer always owns interception-leaf expiry checks.
# The public helper checks the exact cert-name and due window; Cloudflare renews
# without interruption, while HTTP-01 first validates DNS via 1.1.1.1 and safely
# releases/restores mihomo's TCP :80 listeners.
install_renewal_automation() {
    local base="${1:?install_renewal_automation needs a base domain}"
    local service_tmp timer_tmp
    certbot_lineage_owned_by_5gpn "$base" \
        || { err "Refusing to install project renewal automation for a non-owned Certbot lineage."; return 1; }
    preflight_renewal_unit_ownership || return 1
    [[ -x "${SCRIPTS_DIR}/cert-renew.sh" ]] \
        || { err "Scoped renewal helper is missing: ${SCRIPTS_DIR}/cert-renew.sh"; return 1; }
    service_tmp="$(mktemp /etc/systemd/system/.5gpn-certbot-renew.service.XXXXXX)" || return 1
    timer_tmp="$(mktemp /etc/systemd/system/.5gpn-certbot-renew.timer.XXXXXX)" \
        || { rm -f -- "$service_tmp"; return 1; }
    cat > "$service_tmp" <<'EOF'
# 5gpn-unit-id: 5gpn-certbot-renew.service:v1
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
# 5gpn-unit-id: 5gpn-certbot-renew.timer:v1
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
# enabled. A reusable owned lineage still requires the credential for renewal;
# a read-only external lineage retains its owner's renewal mechanism.
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

# set_cf_token prompts for the Cloudflare API token used by
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
reload_rules() {
    check_root
    local script="${SCRIPTS_DIR}/reload-rules.sh"
    [[ -x "$script" ]] || script="${SCRIPT_DIR}/scripts/reload-rules.sh"
    info "Reloading 5gpn-dns policy and chnroute state from disk..."
    bash "$script" || { err "5gpn-dns rule reload failed."; return 1; }
    ok "Rules reloaded."
}

preflight_unit_ownership() {
    preflight_owned_units 5gpn-dns.service 5gpn-intercept.service 5gpn-intercept-cert.service 5gpn-intercept-cert.path 5gpn-intercept-cert.timer 5gpn-intercept-runtime.path mihomo.service 5gpn-journal@.service \
        5gpn-certbot-renew.service 5gpn-certbot-renew.timer
    journal_export_instances_clear \
        || { err "Refusing conflicting fixed 5gpn journal exporter instance or drop-in."; return 1; }
    preflight_polkit_rule_ownership
}

install_units() {
    info "Installing systemd units (5gpn-dns + 5gpn-intercept + mihomo)..."
    # Prefer the repo checkout; fall back to the staged copies under /opt/5gpn
    # (a piped curl|bash install has no checkout after install_files staged them).
    local src u
    for u in 5gpn-dns.service 5gpn-intercept.service 5gpn-intercept-cert.service 5gpn-intercept-cert.path 5gpn-intercept-cert.timer 5gpn-intercept-runtime.path mihomo.service 5gpn-journal@.service; do
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
    install_polkit_rule || return 1
    systemctl daemon-reload
    ok "5gpn-dns, modular interception, certificate watcher/timer, mihomo, and fixed journal units installed."
}

prepare_runtime_permissions() {
    local path role
    preflight_runtime_publication_paths || return 1
    install -d -o root -g "$DNS_SERVICE_USER" -m 3771 "$CONF_DIR" || return 1
    if [[ -f "${CONF_DIR}/dns.env" ]]; then
        chown root:"$DNS_SERVICE_USER" "${CONF_DIR}/dns.env" || return 1
        chmod 0640 "${CONF_DIR}/dns.env" || return 1
    fi

    install -d -o "$DNS_SERVICE_USER" -g "$DNS_SERVICE_USER" -m 2770 \
        "$DNS_RULES_DIR_DEFAULT" || return 1
    runtime_tree_has_only_plain_entries "$DNS_RULES_DIR_DEFAULT" \
        || { err "Refusing unsafe link, hardlink, or special entry below $DNS_RULES_DIR_DEFAULT"; return 1; }
    find "$DNS_RULES_DIR_DEFAULT" -type d -exec chown "$DNS_SERVICE_USER:$DNS_SERVICE_USER" {} + \
        -exec chmod 2770 {} + || return 1
    find "$DNS_RULES_DIR_DEFAULT" -type f -exec chown "$DNS_SERVICE_USER:$DNS_SERVICE_USER" {} + \
        -exec chmod 0640 {} + || return 1

    for path in subscriptions.json policy.json upstreams.json ecs.json stats.json extension-marketplaces.json; do
        [[ -f "${CONF_DIR}/${path}" ]] || continue
        chown "$DNS_SERVICE_USER:$DNS_SERVICE_USER" "${CONF_DIR}/${path}" || return 1
        chmod 0640 "${CONF_DIR}/${path}" || return 1
    done
    if [[ -f "${CONF_DIR}/tgbot.json" ]]; then
        chown "$DNS_SERVICE_USER:$DNS_SERVICE_USER" "${CONF_DIR}/tgbot.json" || return 1
        chmod 0600 "${CONF_DIR}/tgbot.json" || return 1
    fi

    runtime_tree_has_only_plain_entries "$MIHOMO_DIR" \
        || { err "Refusing unsafe link, hardlink, or special entry below $MIHOMO_DIR"; return 1; }
    install -d -o root -g "$MIHOMO_SERVICE_USER" -m 3770 "$MIHOMO_DIR" || return 1
    find "$MIHOMO_DIR" -mindepth 1 -type d \
        -exec chown "$MIHOMO_SERVICE_USER:$MIHOMO_SERVICE_USER" {} + \
        -exec chmod 2770 {} + || return 1
    find "$MIHOMO_DIR" -mindepth 1 -type f \
        ! -path "$MIHOMO_DIR/config.yaml" ! -path "$MIHOMO_DIR/whitelist.txt" \
        ! -name 'config.yaml.bak.*' \
        -exec chown "$MIHOMO_SERVICE_USER:$MIHOMO_SERVICE_USER" {} + \
        -exec chmod 0660 {} + || return 1
    find "$MIHOMO_DIR" -mindepth 1 -maxdepth 1 -type f -name 'config.yaml.bak.*' \
        -exec chown "root:$MIHOMO_SERVICE_USER" {} + \
        -exec chmod 0640 {} + || return 1
    for path in config.yaml whitelist.txt; do
        [[ -f "$MIHOMO_DIR/$path" ]] || continue
        chown "$DNS_SERVICE_USER:$MIHOMO_SERVICE_USER" "$MIHOMO_DIR/$path" || return 1
        chmod 0640 "$MIHOMO_DIR/$path" || return 1
    done

    prepare_intercept_runtime_dirs || return 1
    prepare_intercept_state_dir || return 1
    [[ ! -f "$INTERCEPT_DIR/config.json" ]] \
        || { chown "$DNS_SERVICE_USER:$INTERCEPT_SERVICE_USER" "$INTERCEPT_DIR/config.json" && chmod 0640 "$INTERCEPT_DIR/config.json"; } || return 1
    [[ ! -f "$INTERCEPT_DIR/cert-state" ]] \
        || { chown "root:$INTERCEPT_SERVICE_USER" "$INTERCEPT_DIR/cert-state" && chmod 0640 "$INTERCEPT_DIR/cert-state"; } || return 1
    if [[ -d "$INTERCEPT_DIR/tls" ]]; then
        runtime_tree_has_only_plain_entries "$INTERCEPT_DIR/tls" \
            || { err "Refusing unsafe link, hardlink, or special entry below $INTERCEPT_DIR/tls"; return 1; }
        chown -R root:"$INTERCEPT_SERVICE_USER" "$INTERCEPT_DIR/tls" || return 1
        find "$INTERCEPT_DIR/tls" -type d -exec chmod 0750 {} + || return 1
        find "$INTERCEPT_DIR/tls" -type d -exec chmod g-s {} + || return 1
        find "$INTERCEPT_DIR/tls" -type f -exec chmod 0640 {} + || return 1
    fi

    ensure_dns_cert_root || return 1
    for role in dot web zash; do
        [[ -d "${DNS_CERT_DIR}/${role}" ]] || continue
        cert_role_tree_is_safe_for_recursive_metadata "${DNS_CERT_DIR}/${role}" \
            || { err "Refusing unsafe certificate-role tree: ${DNS_CERT_DIR}/${role}"; return 1; }
    done
    runtime_permission_boundary_is_safe \
        || { err "Runtime ownership boundary validation failed after permission publication."; return 1; }
    ok "Runtime state and TLS material are scoped to dedicated service accounts."
}

# Certificate publishers run before the final all-runtime permission pass. Seal
# their parent directories immediately after service accounts exist and the
# transaction has stopped the runtime services, so fresh 0755 and prior 2771
# installs both reach the same sticky boundary before any renewal helper runs.
prepare_certificate_publication_boundaries() {
    preflight_runtime_publication_paths || return 1
    install -d -o root -g "$DNS_SERVICE_USER" -m 3771 "$CONF_DIR" || return 1
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        || { err "Could not seal the configuration root before certificate publication."; return 1; }

    prepare_intercept_runtime_dirs || return 1
    runtime_file_slot_is_safe "$INTERCEPT_DIR/config.json" "$CONF_DIR" \
        && runtime_file_slot_is_safe "$INTERCEPT_DIR/cert-state" "$CONF_DIR" \
        || { err "Unsafe interception certificate-control file slot."; return 1; }
    if [[ -f "$INTERCEPT_DIR/config.json" ]]; then
        chown "$DNS_SERVICE_USER:$INTERCEPT_SERVICE_USER" "$INTERCEPT_DIR/config.json" \
            && chmod 0640 "$INTERCEPT_DIR/config.json" || return 1
    fi
    if [[ -f "$INTERCEPT_DIR/cert-state" ]]; then
        chown "root:$INTERCEPT_SERVICE_USER" "$INTERCEPT_DIR/cert-state" \
            && chmod 0640 "$INTERCEPT_DIR/cert-state" || return 1
    fi
    runtime_tree_has_only_plain_entries "$INTERCEPT_DIR/tls" \
        || { err "Unsafe interception TLS tree before certificate publication."; return 1; }
    chown -R "root:$INTERCEPT_SERVICE_USER" "$INTERCEPT_DIR/tls" || return 1
    find "$INTERCEPT_DIR/tls" -type d -exec chmod 0750 {} + \
        && find "$INTERCEPT_DIR/tls" -type f -exec chmod 0640 {} + || return 1
    find "$INTERCEPT_DIR/tls" -type d -exec chmod g-s {} + || return 1

    claim_fixed_owned_dir "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" \
        || return 1
    install -d -o root -g root -m 0700 "$INTERCEPT_CA_DIR" || return 1
    chmod g-s "$INTERCEPT_CA_DIR" || return 1
    fixed_owned_dir_is_safe "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" \
        || { err "Could not seal the interception CA root."; return 1; }
    ensure_dns_cert_root || return 1

    if [[ "${CERT_MODE:-}" == debug ]]; then
        ensure_debug_cert_root || return 1
    fi
}

write_dns_env() {
    # Write /etc/5gpn/dns.env from install-time collected vars.
    # cert paths always point at the /etc/5gpn/cert copies (maintained by renew-hook.sh).
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_file_slot_is_safe "${CONF_DIR}/dns.env" "$CONF_DIR" \
        || { err "Refusing unsafe dns.env path: ${CONF_DIR}/dns.env"; return 1; }
    [[ -d "$CONF_DIR" && ! -L "$CONF_DIR" ]] \
        || { err "Configuration root disappeared before dns.env publication."; return 1; }

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
	DNS_API_TOKEN="$existing_token"
	if [[ -z "$DNS_API_TOKEN" ]]; then
		DNS_API_TOKEN="$(openssl rand -hex 32)" \
			|| { err "Could not generate DNS_API_TOKEN."; return 1; }
	fi
	local tg_token="$existing_tgtoken"
	local tg_admins="$existing_tgadmins"
	local tg_file="${existing_tgfile:-${CONF_DIR}/tgbot.json}"
	local tg_proxy="$existing_tgproxy"
    local tg_alerts="${existing_tgalerts:-false}"
    # A bare DNS_TRUST IP is queried over plain UDP; "host@IP" entries use DoT.
    # Operators change it post-install via the web console
    # (Settings → upstream DNS), which persists to /etc/5gpn/upstreams.json.
    local dns_china="${existing_china:-$DNS_CHINA_DEFAULT}"
    local dns_trust="${existing_trust:-$DNS_TRUST_DEFAULT}"

    # Obtain console/zash/base domains from the single derivation of the
    # operator's base (apex) domain
    # (console.<base> / zash.<base>), also used by render_mihomo_config and the
    # *.<base> wildcard install_cert issues, so dns.env and the rendered
    # config.yaml agree instead of drifting.
    local base_domain="$BASE_DOMAIN"
    derive_domains "$base_domain" || return 1
    # Mihomo's loopback external-controller API + the zashboard source-IP
    # allowlist file it reloads from (add_allow_ip/del_allow_ip/apply_whitelist
    # already hardcode these same two values; persisting them here lets the
    # daemon read back what it's actually being served against).
    local dns_mihomo_controller="$(cfg_get DNS_MIHOMO_CONTROLLER)"; dns_mihomo_controller="${dns_mihomo_controller:-127.0.0.1:9090}"
    local dns_mihomo_secret="$(cfg_get DNS_MIHOMO_SECRET)" dns_mihomo_secret_env
    dns_mihomo_secret_env="$(dns_env_encode_value "$dns_mihomo_secret")" \
        || { err "DNS_MIHOMO_SECRET cannot be represented safely in dns.env."; return 1; }
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
    local api_rate="$(cfg_get DNS_API_RATE)"; api_rate="${api_rate:-20}"
    local api_burst="$(cfg_get DNS_API_BURST)"; api_burst="${api_burst:-40}"
    local china_0x20="$(cfg_get DNS_CHINA_0X20)"; china_0x20="${china_0x20:-1}"
    local upstreams_file="$(cfg_get DNS_UPSTREAMS)"; upstreams_file="${upstreams_file:-${CONF_DIR}/upstreams.json}"
    local ecs_file="$(cfg_get DNS_ECS_FILE)"; ecs_file="${ecs_file:-${CONF_DIR}/ecs.json}"
    local policy_rules="$(cfg_get DNS_POLICY_RULES)"; policy_rules="${policy_rules:-${CONF_DIR}/policy.json}"
    local stats_file="$(cfg_get DNS_STATS_FILE)"; stats_file="${stats_file:-${CONF_DIR}/stats.json}"
    local mihomo_config="$(cfg_get DNS_MIHOMO_CONFIG)"; mihomo_config="${mihomo_config:-${MIHOMO_DIR}/config.yaml}"
    local intercept_config="${INTERCEPT_DIR}/config.json"
    local marketplaces_file="${CONF_DIR}/extension-marketplaces.json"
    local heartbeat_url="$(cfg_get DNS_HEARTBEAT_URL)"
    local heartbeat_interval="$(cfg_get DNS_HEARTBEAT_INTERVAL)"; heartbeat_interval="${heartbeat_interval:-60s}"
    # full_install has already validated and normalized the China ECS value.
    local china_ecs="$CHINA_ECS"

    local dns_env_tmp
    dns_env_tmp="$(mktemp "${CONF_DIR}/.dns.env.XXXXXX")" \
        || { err "Could not create the dns.env candidate."; return 1; }
    if ! cat > "$dns_env_tmp" <<EOF
# 5gpn-dns config — the SINGLE source of truth (written by install.sh).
# 'systemctl reload 5gpn-dns' (SIGHUP) reloads ONLY the rule files under
# /etc/5gpn/rules/ + chnroute, NOT this file — a daemon knob here needs
# 'systemctl restart 5gpn-dns' (read once at startup). Re-run install.sh for
# cert knobs. There are no separate .state files.

# DoT is the ONLY client-facing DNS transport; no DoH or client :53 is served.
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
DNS_CERT=${DOT_CERT_DIR}/current/fullchain.pem
DNS_KEY=${DOT_CERT_DIR}/current/privkey.pem
DNS_WEB_CERT=${WEB_CERT_DIR}/current/fullchain.pem
DNS_WEB_KEY=${WEB_CERT_DIR}/current/privkey.pem

# ── Deployment identity + cert (read by install.sh/renew-hook.sh; also read by
# the in-process Telegram bot). DNS_BASE_DOMAIN = the operator's ONE apex domain
# (the cert-name); the three service domains are auto-derived subdomains and
# covered by the selected wildcard or exact-SAN certificate. Runtime components
# derive dot./console./zash. directly from DNS_BASE_DOMAIN.
# ──
DNS_BASE_DOMAIN=${BASE_DOMAIN}
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
# entries are bare "IP" (plain UDP — e.g. the 22.22.22.22 resolver) or
# "serverName@IP" (DoT). These are the INSTALL-TIME defaults:
# when /etc/5gpn/upstreams.json exists (written by the web console via
# Settings → upstream DNS, hot-applied without a restart) it overrides both.
DNS_CHINA=${dns_china}
DNS_TRUST=${dns_trust}
DNS_UPSTREAMS=${upstreams_file}

# EDNS Client Subnet attached to china-group queries. New installations use
# the operational 112.96.32.0/24 default; /etc/5gpn/ecs.json (written by the
# web console and hot-applied without a restart) overrides it at runtime.
DNS_CHINA_ECS=${china_ecs}
DNS_CHINA_0X20=${china_0x20}
DNS_ECS_FILE=${ecs_file}

DNS_RULES_DIR=${DNS_RULES_DIR_DEFAULT}
DNS_CHNROUTE=${DNS_RULES_DIR_DEFAULT}/china_ip_list.txt

# Mihomo resolves sniffed hostnames only through this loopback broker. The
# broker uses each active extension's operator-selected China/trust binding and
# defaults all other hostnames to the live trust group.
DNS_EGRESS_BROKER=127.0.0.1:5354

# Remote rule-list subscriptions (fetched in-process; caches written to
# DNS_RULES_DIR/<category>/<name>.txt). See /etc/5gpn/subscriptions.json.
DNS_SUBSCRIPTIONS=${CONF_DIR}/subscriptions.json
DNS_POLICY_RULES=${policy_rules}

# Control-plane HTTPS API + public web console. Browsers reach it at
# https://console.<DNS_BASE_DOMAIN> via the mihomo :443 SNI split, which forwards
# straight to this loopback listener. The SPA and /ios/ are public; every
# /api/* request requires the bearer token. The token is generated once and
# preserved across re-installs so a working token is never rotated out from
# under an operator config.
#
# Binds LOOPBACK :443 directly: mihomo owns the public :443 socket and routes
# console.<base> to this listener. Do not bind the daemon itself publicly.
DNS_LISTEN_API=127.0.0.1:443
DNS_API_TOKEN=${DNS_API_TOKEN}
DNS_API_RATE=${api_rate}
DNS_API_BURST=${api_burst}

# Mihomo's loopback external-controller API (DNS_MIHOMO_CONTROLLER) + its
# bearer secret (DNS_MIHOMO_SECRET) + the zashboard source-IP allowlist file
# (DNS_WHITELIST_FILE) mihomo's rule-provider reloads from. add_allow_ip /
# del_allow_ip / apply_whitelist use these same values directly.
DNS_MIHOMO_CONTROLLER=${dns_mihomo_controller}
DNS_MIHOMO_SECRET=${dns_mihomo_secret_env}
DNS_WHITELIST_FILE=${dns_whitelist_file}
DNS_MIHOMO_CONFIG=${mihomo_config}
DNS_INTERCEPT_CONFIG=${intercept_config}
# Console-managed extension marketplace source snapshots. The daemon writes
# this file atomically; marketplace indexes never contain executable runtime
# state and every selected extension is still imported through the strict
# native manifest snapshot pipeline.
DNS_MARKETPLACES_FILE=${marketplaces_file}

# ZashDir is the unzipped Zephyruso/zashboard
# dist served by a SECOND loopback HTTPS listener on ZashListen. ZashCert/Key
# always point at the selected certificate's zash/ role-dir copy
# (deploy_cert_roles).
DNS_ZASH_DIR=${dns_zash_dir}
DNS_ZASH_LISTEN=${dns_zash_listen}
DNS_ZASH_CERT=${ZASH_CERT_DIR}/current/fullchain.pem
DNS_ZASH_KEY=${ZASH_CERT_DIR}/current/privkey.pem

# Control-console SPA (served from disk by the loopback :443 server). Populated
# by install_web from the 5gpn-web release tarball; empty dir -> built-in placeholder.
DNS_WEB_DIR=${DNS_WEB_DIR}

# iOS .mobileconfig files served by the daemon at the public /ios/ path.
WWW_DIR=${WWW_DIR}

# In-process Telegram control bot (goroutine of 5gpn-dns). Populated by
# 'install.sh setup-tgbot' (or set here manually). Empty token ⇒ bot disabled.
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
DNS_STATS_FILE=${stats_file}
DNS_HEARTBEAT_URL=${heartbeat_url}
DNS_HEARTBEAT_INTERVAL=${heartbeat_interval}
EOF
    then
        rm -f -- "$dns_env_tmp"
        err "Could not write the dns.env candidate."
        return 1
    fi
    chown root:"$DNS_SERVICE_USER" "$dns_env_tmp" \
        && chmod 0640 "$dns_env_tmp" \
        && sync -f "$dns_env_tmp" 2>/dev/null \
        || { rm -f -- "$dns_env_tmp"; err "Could not protect or sync the dns.env candidate."; return 1; }
    validate_dns_env_schema "$dns_env_tmp" \
        || { rm -f -- "$dns_env_tmp"; err "dns.env candidate failed schema validation."; return 1; }
    mv -f -- "$dns_env_tmp" "${CONF_DIR}/dns.env" \
        || { rm -f -- "$dns_env_tmp"; err "Could not atomically publish dns.env."; return 1; }
    sync -f "$CONF_DIR" 2>/dev/null \
        || { err "Could not sync the dns.env directory publication."; return 1; }
    [[ -f "${CONF_DIR}/dns.env" && ! -L "${CONF_DIR}/dns.env" \
       && "$(file_uid "${CONF_DIR}/dns.env")" == 0 \
       && "$(file_gid "${CONF_DIR}/dns.env")" == "$(account_gid "$DNS_SERVICE_USER")" \
       && "$(file_mode "${CONF_DIR}/dns.env")" == 640 \
       && "$(file_nlink "${CONF_DIR}/dns.env")" == 1 ]] \
        && validate_dns_env_schema \
        || { err "Published dns.env failed metadata or schema validation."; return 1; }
    ok "Written ${CONF_DIR}/dns.env (current schema only)."
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
            remove_owned_root "$candidate" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE" || true
            return 1
        fi
    else
        warn "scripts/gen-ios-profile.sh not present yet; skipping profile generation."
        remove_owned_root "$candidate" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE" || true
        return 1
    fi
    publish_owned_tree "$candidate" "$WWW_DIR" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE" \
        || { remove_owned_root "$candidate" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE" || true; return 1; }
    remove_owned_root "$candidate" "$IOS_OWNERSHIP_MARKER" "$IOS_OWNERSHIP_VALUE"

    ok "iOS profile generated (downloaded from https://${CONSOLE_DOMAIN:-<console-domain>}/ios/ios-dot.mobileconfig)."
}

print_qr() {
    [[ -n "${CONSOLE_DOMAIN:-}" ]] || load_persisted_domains || return 1
    local url="https://${CONSOLE_DOMAIN}/ios/ios-dot.mobileconfig"
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
    local raw="" ips="" aaaa="" ip expected matched raw_count ip_count
    command -v dig >/dev/null 2>&1 \
        || { CERT_DNS_LAST_OBSERVATION="dig is unavailable"; return 1; }
    raw="$(dig +time=3 +tries=1 +short A "$domain" @"$CERT_DNS_RESOLVER" 2>/dev/null || true)"
    ips="$(printf '%s\n' "$raw" | awk '/^[0-9]+(\.[0-9]+){3}$/' || true)"
    raw_count="$(printf '%s\n' "$raw" | awk 'NF { n++ } END { print n+0 }')"
    ip_count="$(printf '%s\n' "$ips" | awk 'NF { n++ } END { print n+0 }')"
    if [[ "$require_no_aaaa" == 1 ]]; then
        aaaa="$(dig +time=3 +tries=1 +short AAAA "$domain" @"$CERT_DNS_RESOLVER" 2>/dev/null \
            | awk '/:/' || true)"
    else
        aaaa="not-required"
    fi
    CERT_DNS_LAST_OBSERVATION="${domain}: raw-A=[${raw//$'\n'/, }] A=[${ips//$'\n'/, }] AAAA=[${aaaa//$'\n'/, }]"
    [[ "$raw_count" == 1 && "$ip_count" == 1 ]] || return 1
    [[ "$require_no_aaaa" != 1 || -z "$aaaa" ]] || return 1
    ip="$ips"; matched=0
    for expected in "$@"; do
        [[ -n "$expected" && "$ip" == "$expected" ]] && { matched=1; break; }
    done
    [[ "$matched" == 1 ]]
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
        http-01)
            wait_for_cert_dns "HTTP-01 service records" check_http_challenge_dns_once \
                || { err "Set console/zash/dot A records to DNS_PUBLIC_IP=${PUBLIC_IP}, remove AAAA records, and keep public TCP/80 reachable."; return 1; } ;;
        cloudflare)
            [[ -n "${CONSOLE_DOMAIN:-}" ]] || load_persisted_domains || return 1
            local console="$CONSOLE_DOMAIN"
            [[ -n "$console" ]] \
                || { err "Derived console domain is empty; cannot verify the public console endpoint."; return 1; }
            wait_for_cert_dns "public console record" check_console_dns_once "$console" \
                || { err "Create '${console} A -> ${PUBLIC_IP:-<PUBLIC_IP>}' (or client-routable ${GATEWAY_IP:-<GATEWAY_IP>} in NPN)."; return 1; } ;;
        *) err "Unknown CERT_MODE '${mode}' during DNS verification."; return 1 ;;
    esac
}

verify_console_endpoint() {
    [[ -s "${WWW_DIR}/ios-dot.mobileconfig" ]] \
        || { warn "iOS profile file is absent; endpoint content probe skipped (profile generation already reported fail-closed)."; return 0; }
    [[ -s "${WWW_DIR}/ios-intercept-ca.mobileconfig" ]] \
        || { err "Interception CA profile file is absent after profile generation."; return 1; }
    [[ -n "${CONSOLE_DOMAIN:-}" ]] || load_persisted_domains || return 1
    local console="$CONSOLE_DOMAIN"
    local bind_ip="${MIHOMO_LISTEN_IPS%%,*}" tmp headers code intercept_code api_code root_code
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
    intercept_code="$(curl --silent --show-error --insecure --max-time 5 \
        --resolve "${console}:443:${bind_ip}" -o /dev/null \
        -w '%{http_code}' "https://${console}/ios/ios-intercept-ca.mobileconfig" 2>/dev/null || true)"
    [[ "$intercept_code" == 200 ]] \
        || { remove_temp_dir "$tmp"; err "Public interception CA profile probe failed (HTTP ${intercept_code:-none})."; return 1; }
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
# Service lifecycle
# ----------------------------------------------------------------------------
ss_has_exact_listener() {
    local kind="$1" ip="$2" port="$3" flags
    case "$kind" in
        tcp) flags=-ltn ;;
        udp) flags=-lun ;;
        *) return 1 ;;
    esac
    ss -H "$flags" 2>/dev/null \
        | awk -v target="${ip}:${port}" '$4 == target { found=1 } END { exit !found }'
}

probe_mihomo_ready() {
    systemctl is-active --quiet mihomo || return 1
    local secret ip port
    local -a tcp_ports=(80 443)
    local -a udp_ports=(443)
    if [[ "${MIHOMO_SEED_PORTS_REQUIRED:-0}" == 1 ]]; then
        tcp_ports+=(5060 8080 8443)
        udp_ports+=(5060)
    fi
    secret="$(cfg_get DNS_MIHOMO_SECRET)"
    local -a curl_args=(--fail --silent --show-error --max-time 2 -o /dev/null)
    [[ -n "$secret" ]] && curl_args+=(-H "Authorization: Bearer $secret")
    mihomo_controller_curl "/version" "${curl_args[@]}" >/dev/null 2>&1 || return 1

    command -v ss >/dev/null 2>&1 || return 1
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        for port in "${tcp_ports[@]}"; do
            ss_has_exact_listener tcp "$ip" "$port" || return 1
        done
        for port in "${udp_ports[@]}"; do
            ss_has_exact_listener udp "$ip" "$port" || return 1
        done
    done < <(printf '%s\n' "$MIHOMO_LISTEN_IPS" | tr ',' '\n')
}

probe_dns_ready() {
    systemctl is-active --quiet 5gpn-dns || return 1
    local token domain
    token="$(cfg_get DNS_API_TOKEN)"
    [[ -n "${DOT_DOMAIN:-}" ]] || load_persisted_domains || return 1
    domain="$DOT_DOMAIN"
    curl --fail --silent --show-error --insecure --max-time 2 -o /dev/null \
        -H "Authorization: Bearer $token" https://127.0.0.1/api/status \
        >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || return 1
    timeout 4 openssl s_client -brief -connect 127.0.0.1:853 -servername "$domain" \
        </dev/null 2>&1 | grep -Eq 'CONNECTION ESTABLISHED|Protocol version:'
}

wait_service_ready() {
    local svc="$1" deadline remaining probe_timeout check_rc
    deadline=$((SECONDS + SERVICE_READY_TIMEOUT))
    while (( SECONDS < deadline )); do
        case "$svc" in
            5gpn-intercept)
                if "$INTERCEPT_BIN" --config "$INTERCEPT_DIR/config.json" --check-enabled >/dev/null 2>&1; then
                    remaining=$((deadline - SECONDS))
                    (( remaining > 0 )) || break
                    probe_timeout="$remaining"
                    (( probe_timeout <= INTERCEPT_HEALTHCHECK_MAX_TIMEOUT )) \
                        || probe_timeout="$INTERCEPT_HEALTHCHECK_MAX_TIMEOUT"
                    timeout --signal=TERM --kill-after=2s "${probe_timeout}s" \
                        "$INTERCEPT_BIN" --config "$INTERCEPT_DIR/config.json" --healthcheck \
                        && { ok "5gpn-intercept readiness passed (authenticated loopback SOCKS5 TCP/UDP)."; return 0; }
                else
                    check_rc=$?
                    if [[ "$check_rc" == 3 ]]; then
                    systemctl stop 5gpn-intercept.service 2>/dev/null || true
					ok "5gpn-intercept remains stopped because no interception extension is active."
                    return 0
                    fi
                    err "5gpn-intercept configuration could not be read while checking the MITM master setting."
                    return 1
                fi
                ;;
            mihomo)    probe_mihomo_ready && { ok "mihomo readiness passed (controller + local TCP/UDP listeners)."; return 0; } ;;
            5gpn-dns)  probe_dns_ready && { ok "5gpn-dns readiness passed (API + DoT TLS handshake)."; return 0; } ;;
        esac
        (( SECONDS < deadline )) && sleep 1
    done
    err "$svc did not become ready within ${SERVICE_READY_TIMEOUT}s (journalctl -u $svc)."
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
    systemctl enable --now 5gpn-intercept-cert.path >/dev/null 2>&1 \
        || { err "could not enable the interception certificate watcher."; return 1; }
    systemctl enable --now 5gpn-intercept-cert.timer >/dev/null 2>&1 \
        || { err "could not enable the interception certificate renewal timer."; return 1; }
    systemctl enable --now 5gpn-intercept-runtime.path >/dev/null 2>&1 \
        || { err "could not enable the MITM runtime watcher."; return 1; }
    # mihomo is the data plane + panel SNI split; it was installed by
    # install_units but is enabled/started HERE (nothing started it before).
    # Start mihomo first so DNS cannot advertise gateway answers before the
    # data-plane listener is live. Any enable/start/readiness failure is fatal;
    # full_install must never print success for a broken deployment.
    local svc failed=0 check_rc=0
    for svc in mihomo 5gpn-intercept 5gpn-dns; do
        if ! systemctl enable "$svc" >/dev/null 2>&1; then
            err "could not enable $svc (check: systemctl status $svc)."
            failed=1
        fi
        if [[ "$svc" == 5gpn-intercept ]]; then
            if "$INTERCEPT_BIN" --config "$INTERCEPT_DIR/config.json" --check-enabled >/dev/null 2>&1; then
                :
            else
                check_rc=$?
                if [[ "$check_rc" == 3 ]]; then
                    if systemctl stop 5gpn-intercept.service 2>/dev/null; then
                        ok "5gpn-intercept remains stopped because MITM is disabled."
                    else
                        err "could not stop disabled 5gpn-intercept (check: journalctl -u 5gpn-intercept)."
                        failed=1
                    fi
                    continue
                fi
                err "could not validate the MITM master setting before starting 5gpn-intercept."
                failed=1
                continue
            fi
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

# The installer holds the shared certificate lock while publishing certificate
# and runtime state. Starting 5gpn-intercept synchronously starts its required
# certificate oneshot, which must acquire that same lock. Hand the lock to
# systemd for the bounded service-start phase, then reacquire it before final
# verification or any rollback can run.
start_services_with_cert_lock_handoff() {
    local start_rc=0
    [[ "$INSTALL_CERT_LOCK_HELD" == 1 ]] \
        || { err "The installer certificate lock is not held before service start."; return 1; }
    release_install_cert_lock || return 1
    start_services || start_rc=$?
    acquire_install_cert_lock || return 1
    [[ "$start_rc" == 0 ]] || return "$start_rc"
}

# ----------------------------------------------------------------------------
# Optional control plane: Telegram bot (an in-process goroutine of 5gpn-dns).
# dns.env supplies startup defaults; the validated runtime override at
# DNS_TGBOT_FILE is authoritative once created by the control API.
# ----------------------------------------------------------------------------
# Set (or replace) a KEY=VALUE line in a dotenv file, preserving all other keys.
# Appends the key if absent without clobbering unrelated settings.
set_dns_env_kv() {
    local f="$1" key="$2" val="$3" tmp encoded_val
    [[ "$f" == "${CONF_DIR}/dns.env" ]] \
        || { err "Refusing a non-canonical dns.env path: $f"; return 1; }
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_file_slot_is_safe "$f" "$CONF_DIR" \
        || { err "Refusing unsafe dns.env path: $f"; return 1; }
    if [[ -e "$f" || -L "$f" ]]; then
        persisted_dns_env_is_safe \
            || { err "Refusing unsafe persisted dns.env before update: $f"; return 1; }
    fi
    case " $DNS_ENV_KEYS " in
        *" $key "*) ;;
        *) err "Refusing unsupported dns.env key: $key"; return 1 ;;
    esac
    [[ "$val" != *$'\n'* && "$val" != *$'\r'* ]] \
        || { err "Refusing a multiline dns.env value for $key."; return 1; }
    encoded_val="$val"
    if [[ "$key" == DNS_MIHOMO_SECRET ]]; then
        encoded_val="$(dns_env_encode_value "$val")" || return 1
    fi
    if [[ "$f" == "${CONF_DIR}/dns.env" && -s "$f" ]]; then
        validate_dns_env_schema || return 1
    fi
    tmp="$(mktemp "${f}.XXXXXX")" \
        || { err "Could not create a dns.env update candidate."; return 1; }
    # Drop any existing (commented or live) definition of this key, then append the new one.
    if [[ -f "$f" ]]; then
        awk -v key="$key" '$0 !~ ("^#?[[:space:]]*" key "=") { print }' "$f" > "$tmp" \
            || { rm -f -- "$tmp"; return 1; }
    else
        : > "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    printf '%s=%s\n' "$key" "$encoded_val" >> "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
    chown root:"$DNS_SERVICE_USER" "$tmp" \
        && chmod 0640 "$tmp" \
        && sync -f "$tmp" 2>/dev/null \
        || { rm -f -- "$tmp"; return 1; }
    validate_dns_env_schema "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$f" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$CONF_DIR" 2>/dev/null || return 1
    persisted_dns_env_is_safe && validate_dns_env_schema
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
# Rule status
# ----------------------------------------------------------------------------
regen_ios() {
    check_root
    load_persisted_install_config \
        || { err "A current ${CONF_DIR}/dns.env is required to regenerate the iOS profile."; return 1; }
    validate_install_config || return 1
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
    load_persisted_domains || return 1
    {
        local domain="$DOT_DOMAIN" webdomain="$CONSOLE_DOMAIN" pubip svc s
        pubip="$(cfg_get DNS_PUBLIC_IP)"; pubip="${pubip:-N/A}"
        echo "📊 5gpn 状态"
        echo ""
        # Telegram bot + iOS profile path are in-process parts of 5gpn-dns now;
        # mihomo is the forwarding data plane; interception is a separate sidecar.
        for svc in "5gpn-dns" 5gpn-intercept mihomo; do
            if [[ "$svc" == 5gpn-intercept ]]; then
                if "$INTERCEPT_BIN" --config "$INTERCEPT_DIR/config.json" --check-enabled >/dev/null 2>&1; then
                    :
                elif [[ "$?" == 3 ]]; then
                    echo "  ⏸️  ${svc}  (disabled by MITM setting)"
                    continue
                fi
            fi
            s="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
            echo "  $([[ "$s" == active ]] && echo '✅' || echo '❌') ${svc}  (${s})"
        done
        echo ""
        echo "  WebUI 域名  $webdomain  (https://${webdomain}/)"
        echo "  DoT 域名    $domain"
        echo "  公网 IP     $pubip"
        echo "  DoT         tls://${domain}:853"
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

validate_dns_env_schema() {
    local file="${1:-${CONF_DIR}/dns.env}" line key seen=" "
    [[ -f "$file" && ! -L "$file" ]] \
        || { err "Persisted dns.env is missing or unsafe: $file"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in ''|\#*) continue ;; esac
        [[ "$line" == *=* ]] \
            || { err "Persisted dns.env contains a malformed line."; return 1; }
        key="${line%%=*}"
        case " $DNS_ENV_KEYS " in
            *" $key "*) ;;
            *)
                if [[ "$key" == DNS_EGRESS_RESOLVER ]]; then
                    err "Pre-v5 dns.env contains retired DNS_EGRESS_RESOLVER. Back up active dns.env/mihomo/intercept state, disable the old MITM master, and save the clean boundary."
                    err "Follow README's credential-preserving jq rebuild and require the current sidecar/routing checks before removing only that exact key."
                else
                    err "Persisted dns.env contains unsupported key: $key"
                fi
                return 1
                ;;
        esac
        case "$seen" in
            *" $key "*) err "Persisted dns.env contains duplicate key: $key"; return 1 ;;
            *) seen="${seen}${key} " ;;
        esac
    done < "$file"
}

load_persisted_install_config() {
    [[ -f "${CONF_DIR}/dns.env" ]] || return 1
    validate_dns_env_schema || return 1
    BASE_DOMAIN="$(cfg_get DNS_BASE_DOMAIN)"
    BASE_DOMAIN="$(printf '%s' "$BASE_DOMAIN" | tr '[:upper:]' '[:lower:]')"
    PUBLIC_IP="$(cfg_get DNS_PUBLIC_IP)"
    GATEWAY_IP="$(cfg_get DNS_GATEWAY_IP)"
    MIHOMO_LISTEN_IPS="$(cfg_get DNS_MIHOMO_LISTEN_IPS)"
    CERT_MODE="$(cfg_get CERT_MODE)"
    CERT_EMAIL="$(cfg_get CERT_EMAIL)"
    CACHE_SIZE="$(cfg_get DNS_CACHE_SIZE)"
    CHINA_ECS="$(cfg_get DNS_CHINA_ECS)"
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
        ""|off|none|disable|0) ;;
        *) is_valid_ipv4 "${CHINA_ECS%%/*}" || { err "Persisted DNS_CHINA_ECS is invalid."; return 1; } ;;
    esac
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    export BASE_DOMAIN PUBLIC_IP GATEWAY_IP MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL \
        CACHE_SIZE CHINA_ECS
}

configure_install_tui() {
    [[ -t 0 ]] || { err "First install/configuration requires an attached TTY; shell environment injection is not supported."; return 1; }
    local advanced="${1:-0}" choice detected value default_listen
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
    if [[ "$advanced" == 1 ]]; then
        while true; do
            PUBLIC_IP="$(prompt_default '公网 IPv4 Public IPv4' "$detected")"
            is_valid_ipv4 "$PUBLIC_IP" && break
            warn "Invalid public IPv4."
        done
    else
        PUBLIC_IP="$detected"
    fi
    if [[ "$advanced" == 1 ]]; then
        while true; do
            GATEWAY_IP="$(prompt_default '客户端可达网关 IPv4 Gateway IPv4' "${GATEWAY_IP:-$PUBLIC_IP}")"
            is_valid_ipv4 "$GATEWAY_IP" && break
            warn "Invalid gateway IPv4."
        done
    else
        GATEWAY_IP="$PUBLIC_IP"
    fi

    default_listen="$(resolve_mihomo_listen_ips "${MIHOMO_LISTEN_IPS:-}" 2>/dev/null || true)"
    if [[ -z "$default_listen" ]]; then
        default_listen="$(resolve_mihomo_listen_ips "$PUBLIC_IP" 2>/dev/null || true)"
    fi
    [[ -n "$default_listen" ]] || default_listen="$(resolve_mihomo_listen_ips '' 2>/dev/null || true)"
    [[ -n "$default_listen" ]] \
        || { err "No locally assigned IPv4 is available for mihomo listeners."; return 1; }
    if [[ "$advanced" == 1 ]]; then
        while true; do
            MIHOMO_LISTEN_IPS="$(prompt_default 'mihomo 本机监听 IPv4（逗号分隔）' "$default_listen")"
            MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" && break
        done
    else
        MIHOMO_LISTEN_IPS="$default_listen"
    fi
    if [[ -z "${CHINA_ECS+x}" ]]; then
        CHINA_ECS="$DNS_CHINA_ECS_DEFAULT"
    fi
    CACHE_SIZE="${CACHE_SIZE:-${_CACHE_SIZE_DEFAULT:-4096}}"
    [[ "$CACHE_SIZE" =~ ^[1-9][0-9]*$ ]] \
        || { err "DNS cache size must be a positive integer."; return 1; }
    if [[ "$CERT_MODE" != debug ]]; then
        CERT_EMAIL="$(prompt_default 'Let’s Encrypt email' "${CERT_EMAIL:-admin@${BASE_DOMAIN}}")"
        [[ "$CERT_EMAIL" == *@* && "$CERT_EMAIL" != *[[:space:]]* ]] \
            || { err "Invalid certificate email."; return 1; }
    else
        CERT_EMAIL=""
    fi
    if [[ "$CERT_MODE" == cloudflare ]]; then
        ensure_cf_token || return 1
    fi

    {
        echo "安装配置 Install configuration"
        echo "  mode:       $CERT_MODE"
        echo "  base:       $BASE_DOMAIN"
        echo "  public:     $PUBLIC_IP"
        echo "  gateway:    $GATEWAY_IP"
        echo "  listeners:  $MIHOMO_LISTEN_IPS"
        echo "  ECS:        ${CHINA_ECS:-disabled (configure in WebUI)}"
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
            echo "  Required record: ${CONSOLE_DOMAIN} A -> ${PUBLIC_IP}"
            [[ "$GATEWAY_IP" != "$PUBLIC_IP" ]] && echo "  or client-routable gateway A -> ${GATEWAY_IP}"
            echo "  The API token is used only for ACME TXT records."
            echo "  The installer does NOT create or modify this A record."
            echo "  Token scope: Zone:DNS:Edit for ${BASE_DOMAIN}."
            echo "The installer will wait for 1.1.1.1 to observe the console A record."
        } | card
        ask_yesno "我已添加上述 console A 记录；现在开始通过 1.1.1.1 验证?" \
            || { warn "Configuration cancelled before the DNS check."; return 1; }
    else
        ask_yesno "保存以上 debug 配置并继续?" \
            || { warn "Configuration cancelled."; return 1; }
    fi
    export BASE_DOMAIN PUBLIC_IP GATEWAY_IP MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL \
        CACHE_SIZE CHINA_ECS
}

resolve_install_configuration() {
    local force_tui="${1:-0}"
    if [[ "$force_tui" != 1 ]] && load_persisted_install_config && validate_install_config; then
        info "Using validated persisted configuration from ${CONF_DIR}/dns.env (caller environment ignored)."
        return 0
    fi
    [[ -f "${CONF_DIR}/dns.env" ]] && load_persisted_install_config || true
    configure_install_tui "$force_tui"
    validate_install_config
}

mihomo_config_matches_install_config() {
    local config="$MIHOMO_DIR/config.yaml" ip
    [[ -f "$config" ]] || return 0
    grep -Fq -- "$CONSOLE_DOMAIN" "$config" || return 1
    grep -Eq "^[[:space:]]*-[[:space:]]*DOMAIN,[[:space:]]*${CONSOLE_DOMAIN//./\\.},[[:space:]]*DIRECT[[:space:]]*$" "$config" || return 1
    ! grep -Eq "DOMAIN,[[:space:]]*${CONSOLE_DOMAIN//./\\.},[[:space:]]*REJECT(-DROP)?" "$config" || return 1
    ! grep -Eq "AND,.*DOMAIN,[[:space:]]*${CONSOLE_DOMAIN//./\\.}.*RULE-SET,[[:space:]]*whitelist" "$config" || return 1
    ! grep -Fq -- "profile.${BASE_DOMAIN}" "$config" || return 1
    grep -Fq -- "$ZASH_DOMAIN" "$config" || return 1
    grep -Fq -- "${GATEWAY_IP}/32" "$config" || return 1
    while IFS= read -r ip; do
        grep -Eq "listen:[[:space:]]*${ip//./\\.}([,}[:space:]]|$)" "$config" || return 1
    done < <(printf '%s\n' "$MIHOMO_LISTEN_IPS" | tr ',' '\n')
}

# ----------------------------------------------------------------------------
# Full install
# ----------------------------------------------------------------------------
confirm_upgrade_mihomo_reset() {
    [[ -f "${CONF_DIR}/dns.env" && -f "${MIHOMO_DIR}/config.yaml" ]] \
        || { err "upgrade-reset-mihomo requires an existing 5gpn installation."; return 1; }
    [[ -t 0 && -t 1 ]] \
        || { err "upgrade-reset-mihomo requires an interactive TTY."; return 1; }
    warn "The explicit upgrade will replace the complete operator-owned mihomo config with the current seed."
    warn "A byte-for-byte backup will be retained, but custom proxies, providers, groups, and rules must be merged back manually."
    ask_yesno "Continue with the transactional mihomo reset?" \
        || { warn "Explicit upgrade reset cancelled."; return 1; }
}

delegate_unpinned_installer() {
    local mode="${1:-}" quick
    local -a args=()
    [[ "$DNS_VERSION_DEFAULT" == latest ]] || return 0
    quick="${SCRIPT_DIR}/quick-install.sh"
    [[ -f "$quick" && ! -L "$quick" ]] \
        || { err "An unpinned source install requires the sibling quick-install.sh entrypoint."; return 1; }
    [[ "$DNS_RELEASE_CHANNEL" == stable || "$DNS_RELEASE_CHANNEL" == beta ]] \
        || { err "Unknown 5gpn release channel: $DNS_RELEASE_CHANNEL"; return 1; }
    [[ "$DNS_RELEASE_CHANNEL" == stable ]] || args+=(--beta)
    case "$mode" in
        "") ;;
        configure|upgrade-reset-mihomo) args+=("$mode") ;;
        *) err "Unsupported delegated installer mode: $mode"; return 1 ;;
    esac
    info "Resolving a version-matched ${DNS_RELEASE_CHANNEL} installer bundle before installation."
    exec bash "$quick" "${args[@]}"
}

# A stamped stable installer must never reuse its own pinned artifacts for a
# beta request. Future installed management scripts keep a verified copy of
# quick-install.sh and hand the channel transition back to that resolver.
delegate_pinned_channel_switch() {
    local mode="${1:-}" quick quick_mode base_mode
    local -a args=(--beta)
    [[ "$DNS_RELEASE_CHANNEL_EXPLICIT" == 1 && "$DNS_RELEASE_CHANNEL" == beta ]] || return 0
    [[ "$DNS_VERSION_DEFAULT" != latest ]] || return 0
    valid_dns_stable_release_tag "$DNS_VERSION_DEFAULT" || return 0
    quick="${SCRIPT_DIR}/quick-install.sh"
    quick_mode="$(file_mode "$quick")"
    [[ -f "$quick" && ! -L "$quick" && "$(file_uid "$quick")" == 0 \
       && "$quick_mode" =~ ^[4-7][0145][0145]$ ]] \
        || { err "This stable installer is pinned and cannot switch channels by itself."; \
             err "Run the verified remote quick installer with --beta."; return 1; }
    if [[ "$SCRIPT_DIR" == "$BASE_DIR" ]]; then
        base_mode="$(file_mode "$BASE_DIR")"
        [[ "$(file_uid "$BASE_DIR")" == 0 && "$base_mode" =~ ^[4-7][0145][0145]$ ]] \
            || { err "Installed runtime root is writable by an untrusted account."; return 1; }
        owned_root_canonical "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" >/dev/null \
            || { err "Installed quick installer is outside a valid owned runtime root."; return 1; }
    fi
    [[ -z "$mode" ]] || args+=("$mode")
    info "Handing the stable-to-beta channel upgrade to verified quick-install.sh."
    exec bash "$quick" "${args[@]}"
}

full_install() {
    local mode="${1:-}" force_tui=0 reset_mihomo=0 postcommit_failed=0
    [[ "$mode" == configure ]] && force_tui=1
    [[ "$mode" == upgrade-reset-mihomo ]] && reset_mihomo=1
    delegate_pinned_channel_switch "$mode" || return 1
    delegate_unpinned_installer "$mode" || return 1
    if [[ "$reset_mihomo" == 1 ]] && ! valid_dns_beta_release_tag "$DNS_VERSION_DEFAULT"; then
        err "upgrade-reset-mihomo is available only from a pinned beta installer bundle."
        return 1
    fi
    check_root || return 1
    acquire_install_lock || return 1
    INSTALL_PHASE="initializing the install transaction"
    INSTALL_FAILURE_REPORTED=0
    INSTALL_TRANSACTION_ACTIVE=0
    ROLLBACK_SNAPSHOT_READY=0
    ROLLBACK_IN_PROGRESS=0
    PRESERVE_ROLLBACK_STAGE=0
    PRETRANSACTION_ROOTS_ACTIVE=0
    BASE_ROOT_WAS_ABSENT=0
    CONF_ROOT_WAS_ABSENT=0
    STATE_ROOT_WAS_ABSENT=0
    trap install_transaction_error ERR
    trap install_transaction_exit EXIT
    trap 'install_transaction_signal 129' HUP
    trap 'install_transaction_signal 130' INT
    trap 'install_transaction_signal 143' TERM
    INSTALL_PHASE="claiming project roots"
    record_project_root_prestate
    claim_project_roots
    preflight_intercept_roots
    INSTALL_PHASE="checking the host and persisted configuration"
    detect_os
    check_arch
    detect_memory_profile
    resolve_install_configuration "$force_tui"
    derive_domains "$BASE_DOMAIN"
    mihomo_config_matches_install_config || {
        err "The operator-owned mihomo config does not match the selected domains, gateway, and listener addresses."
        err "Edit and validate the operator-owned file explicitly before rerunning configuration."
        return 1
    }
    [[ "$reset_mihomo" == 0 ]] || confirm_upgrade_mihomo_reset || return 1
    INSTALL_PHASE="checking existing unit and static-asset ownership"
    preflight_unit_ownership
    preflight_web_dir
    preflight_zashboard_dir

    # Package installation may add shared OS packages, but no live 5gpn file has
    # been removed or replaced yet. Debug mode deliberately skips Certbot.
    INSTALL_PHASE="installing host dependencies"
    install_deps
    INSTALL_PHASE="verifying public console DNS"
    verify_console_dns
    INSTALL_PHASE="staging and verifying release artifacts"
    stage_artifacts
    INSTALL_PHASE="checking existing interception routing before publication"
    preflight_existing_interception_state
    INSTALL_PHASE="acquiring the certificate transaction lock"
    acquire_install_cert_lock
    INSTALL_PHASE="capturing the pre-install rollback snapshot"
    capture_install_rollback
    INSTALL_PHASE="claiming publication directories"
    claim_web_dir
    claim_zashboard_dir
    install_gum
    claim_intercept_roots
    INSTALL_PHASE="preparing low-memory runtime support"
    ensure_swap

    # Only after every input, host conflict, download, digest, archive, console
    # DNS gate, and existing mihomo config has passed do we enter publication.
    INSTALL_PHASE="installing service accounts"
    install_service_accounts
    INSTALL_PHASE="publishing verified executables"
    install_5gpndns
    install_intercept
    install_mihomo
    INSTALL_PHASE="publishing runtime configuration and assets"
    ensure_intercept_config
    prepare_certificate_publication_boundaries
    install_files
    install_manage_cli
    install_web
    install_zashboard
    install_units
    write_dns_env
    ensure_intercept_certificates
    install_cert "$BASE_DOMAIN"
    if [[ "$reset_mihomo" == 1 ]]; then
        render_mihomo_config --reset
    else
        render_mihomo_config
    fi
    check_interception_routing_compatibility
    if [[ "$reset_mihomo" == 1 && "$INTERCEPT_ROUTING_READY" != 1 ]]; then
        err "Explicit mihomo reset did not produce a manageable interception boundary."
        return 1
    fi
    setup_ios_profile
    prepare_runtime_permissions
    start_services_with_cert_lock_handoff
    verify_console_endpoint
    reload_rules
    # Shield the short commit/timer-restore critical section. A disconnect must
    # not leave an external/unrelated distro renewal timer stopped forever.
    trap '' HUP INT TERM
    release_install_cert_lock
    # The deployment is fully verified at this point. Commit before starting a
    # distro-wide timer or deleting the rollback snapshot; post-commit cleanup
    # failures must never roll a healthy deployment back.
    INSTALL_TRANSACTION_ACTIVE=0 ROLLBACK_SNAPSHOT_READY=0 PRETRANSACTION_ROOTS_ACTIVE=0
    POSTCOMMIT_TIMER_RESTORE_PENDING=1
    restore_global_certbot_timer_after_success \
        || { err "The deployment committed, but the distro Certbot timer state needs repair."; postcommit_failed=1; }
    POSTCOMMIT_TIMER_RESTORE_PENDING=0
    trap 'install_transaction_signal 129' HUP
    trap 'install_transaction_signal 130' INT
    trap 'install_transaction_signal 143' TERM
    if [[ "$postcommit_failed" == 0 ]]; then
        cleanup_artifact_stage \
            || { err "The deployment committed, but transaction staging was retained at: $ARTIFACT_STAGE"; postcommit_failed=1; }
    else
        err "The committed transaction snapshot was retained for timer-state recovery at: $ROLLBACK_DIR"
    fi
    release_install_lock \
        || { err "The deployment committed, but the installer lock descriptor ended unexpectedly."; postcommit_failed=1; }
    trap - ERR EXIT HUP INT TERM
    [[ "$postcommit_failed" == 0 ]] || return 1

    echo ""
    if [[ "$INTERCEPT_ROUTING_READY" == 1 ]]; then
        ok "5gpn install complete."
    else
        ok "5gpn core install complete."
        warn "Extensions remain disabled because the preserved mihomo config is not interception-ready (${INTERCEPT_ROUTING_REASON})."
        info "Run '5gpn mihomo-reset' only if replacing the complete operator-owned mihomo config is acceptable."
    fi
    {
        if [[ "$INTERCEPT_ROUTING_READY" == 1 ]]; then
            echo "✅ 5gpn 安装完成"
        else
            echo "✅ 5gpn 核心安装完成（Extensions 暂不可启用）"
        fi
        echo ""
        echo "  DoT 地址         tls://${DOT_DOMAIN}:853"
        echo "  Android 私人DNS  ${DOT_DOMAIN}"
        echo "  iOS 描述文件      https://${CONSOLE_DOMAIN}/ios/ios-dot.mobileconfig"
        echo "  MITM CA 描述文件  https://${CONSOLE_DOMAIN}/ios/ios-intercept-ca.mobileconfig（需手动完全信任）"
        echo "  Public console   ${CONSOLE_DOMAIN} A -> ${PUBLIC_IP}（NPN 可用客户端可路由 ${GATEWAY_IP}）"
    } | card
    {
        echo "Web 控制台: https://${CONSOLE_DOMAIN}/"
        echo "zashboard:  https://${ZASH_DOMAIN}/"
        echo "配置向导:   https://${CONSOLE_DOMAIN}/setup-guide"
        [[ -t 1 ]] && echo "Console token: ${DNS_API_TOKEN}"
        echo "(console 公网开放，/api 需要 bearer token；zashboard 仅对白名单来源 IP 开放)"
    } | card
    print_qr
    echo ""
    ok "管理入口：直接输入  5gpn  打开管理菜单（状态 / 重启 / 改域名 / 改公网IP / 卸载 …）。"
    info "Optional: '5gpn setup-tgbot' (or '$0 setup-tgbot') to set up the Telegram control bot."
}

# ----------------------------------------------------------------------------
# Usage / dispatch
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Uninstall: reverse install.sh's invasive host changes. Keeps /etc/5gpn (cert,
# token, rules, subscriptions) by default; --purge removes it EXCEPT the cert dir.
# TLS material is DELIBERATELY preserved in normal/purge modes — re-issuing a Let's Encrypt
# cert for the same domain is rate-limited, so the deployed copy (/etc/5gpn/cert)
# AND the certbot lineage (/etc/letsencrypt, never touched here) survive so a
# re-install reuses the cert instead of burning a new issuance. Remove certs
# manually only when decommissioning the domain. Decommission removes a Certbot
# lineage only when provenance proves 5gpn created it; shared/external lineages
# and any 5gpn credential they still reference remain intact.
# ----------------------------------------------------------------------------
uninstall() {
    check_root || return 1
    local purge=0 decommission=0 base=""
    case "${1:-}" in
        '') ;;
        --purge) purge=1 ;;
        --decommission) purge=1; decommission=1 ;;
        *) err "Unknown uninstall mode: ${1:-}"; return 1 ;;
    esac
    [[ -t 0 ]] || { err "Uninstall requires an attached TTY confirmation."; return 1; }
    local prompt="确认卸载 5gpn?"
    [[ "$decommission" == 1 ]] \
        && prompt="确认卸载并删除可证明由 5gpn 拥有的证书材料?（共享 lineage/凭据会保留）"
    ask_yesno "$prompt" || return 0
    acquire_install_lock || return 1
    INSTALL_TRANSACTION_ACTIVE=0
    ROLLBACK_SNAPSHOT_READY=0
    ROLLBACK_IN_PROGRESS=0
    PRESERVE_ROLLBACK_STAGE=0
    trap install_transaction_error ERR
    trap install_transaction_exit EXIT
    trap 'install_transaction_signal 129' HUP
    trap 'install_transaction_signal 130' INT
    trap 'install_transaction_signal 143' TERM
    claim_project_roots || return 1
    acquire_install_cert_lock || return 1
    if [[ -e "$GLOBAL_CERTBOT_TIMER_STATE" || -L "$GLOBAL_CERTBOT_TIMER_STATE" ]]; then
        global_certbot_timer_state_is_safe \
            || { err "The saved distro Certbot timer state is unsafe; refusing partial uninstall."; return 1; }
    fi
    if [[ "$decommission" == 1 ]]; then
        base="$(cfg_get DNS_BASE_DOMAIN)"
        if ! decommission_certbot_lineage "$base"; then
            release_install_cert_lock || true
            release_install_lock || true
            trap - ERR EXIT HUP INT TERM
            return 1
        fi
    fi
    warn "Uninstalling 5gpn: stopping services and reverting host changes."

    local unit
    for unit in 5gpn-dns.service 5gpn-intercept.service 5gpn-intercept-cert.service 5gpn-intercept-cert.path 5gpn-intercept-cert.timer 5gpn-intercept-runtime.path mihomo.service 5gpn-journal@.service 5gpn-certbot-renew.timer \
                5gpn-certbot-renew.service; do
        remove_owned_unit "$unit"
    done
    rm -f -- /run/5gpn-journal/5gpn-dns.log /run/5gpn-journal/mihomo.log 2>/dev/null || true
    rmdir -- /run/5gpn-journal 2>/dev/null || true
    if polkit_rule_owned_by_5gpn; then
        rm -f -- "$POLKIT_RULE_PATH"
    elif [[ -e "$POLKIT_RULE_PATH" ]]; then
        warn "Preserving unowned polkit rule: $POLKIT_RULE_PATH"
    fi
    systemctl daemon-reload 2>/dev/null || true

    # Remove the exact deploy hook installed by the current release.
    remove_owned_renew_hook
    restore_persisted_global_certbot_timer \
        || { err "Could not restore the distro Certbot timer state during uninstall."; return 1; }

    # Remove only the project-private swapfile under a marked state directory.
    if verify_ownership_marker "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" \
       && [[ -f "$SWAP_FILE" && ! -L "$SWAP_FILE" ]]; then
        swapoff "$SWAP_FILE" 2>/dev/null || true
        rm -f -- "$SWAP_FILE"
        sed -i "\|^${SWAP_FILE} none swap sw 0 0 ${SWAP_FSTAB_MARKER}$|d" /etc/fstab 2>/dev/null || true
        ok "Removed 5gpn-owned swapfile."
    fi

    if launcher_owned; then
        rm -f -- /usr/local/bin/5gpn
    elif [[ -e /usr/local/bin/5gpn ]]; then
        warn "Preserving unowned /usr/local/bin/5gpn."
    fi
    if [[ "$DNS_WEB_DIR" != "$BASE_DIR"/* && -e "$DNS_WEB_DIR" ]]; then
        if [[ "$(safe_web_path 2>/dev/null || true)" == "$DNS_WEB_DIR" ]] \
           && verify_ownership_marker "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"; then
            remove_public_owned_tree "$DNS_WEB_DIR" "$WEB_OWNERSHIP_MARKER" "$WEB_OWNERSHIP_VALUE"
        else
            warn "Kept unowned/unsafe DNS_WEB_DIR '$DNS_WEB_DIR'."
        fi
    fi
    if [[ "$DNS_ZASH_DIR" != "$BASE_DIR"/* ]]; then
        remove_zashboard_dir || warn "Kept unowned/unsafe DNS_ZASH_DIR '$DNS_ZASH_DIR'."
    fi
    remove_runtime_preserving_gum
    remove_fixed_owned_dir "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE"

    if [[ "$decommission" == 1 ]]; then
        if [[ -e "$DNS_CERT_DIR" || -L "$DNS_CERT_DIR" ]]; then
            ensure_dns_cert_root \
                && cert_root_is_safe \
                && remove_owned_root "$DNS_CERT_DIR" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE" \
                || { err "Refusing unsafe certificate-role removal."; return 1; }
        fi
        remove_debug_cert_root \
            || { err "Refusing unsafe debug-certificate removal."; return 1; }
        if [[ "$DECOMMISSION_PRESERVE_ACME" == 0 ]]; then
            remove_owned_child "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" acme \
                || { err "Refusing unsafe ACME credential removal."; return 1; }
            ok "Deleted 5gpn role/debug certificate material and Cloudflare credential."
        else
            ok "Deleted 5gpn role/debug certificate material; kept the credential required by the preserved external lineage."
        fi
        remove_fixed_owned_dir "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" \
            || { err "Refusing unsafe interception CA removal."; return 1; }
        ok "Deleted the dedicated interception CA."
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
        clear_owned_scope "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
            "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" cert acme debug-cert intercept-ca \
            || { err "Config ownership validation failed; refusing purge."; return 1; }
        remove_fixed_owned_dir "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" \
            || { err "Refusing unsafe interception state removal."; return 1; }
        if [[ "$decommission" == 1 && "$DECOMMISSION_PRESERVE_ACME" == 0 ]]; then
            remove_fixed_owned_dir "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"
            ok "Decommissioned all 5gpn configuration and certificate credentials."
        elif [[ "$decommission" == 1 ]]; then
            warn "Decommission kept ${CONF_DIR}/acme because the preserved external lineage still references it."
        else
            warn "Purged ${CONF_DIR} EXCEPT cert/, debug-cert/, and acme/; preserved ${INTERCEPT_CA_DIR} for enrolled interception devices."
            info "Use the explicit TUI-confirmed 'uninstall --decommission' mode to remove the exact lineage and Cloudflare token."
        fi
    else
        ok "Kept ${CONF_DIR}, ${INTERCEPT_CA_DIR}, and ${INTERCEPT_STATE_DIR}. '--purge' removes module persistent data but preserves certificate state."
    fi
    release_install_cert_lock || return 1
    release_install_lock || return 1
    trap - ERR EXIT HUP INT TERM
    ok "5gpn uninstalled."
}

usage() {
    cat <<EOF
5gpn installer (DNS-steering gateway; DoT is the ONLY DNS transport)
Usage: sudo bash install.sh [--beta] [command] — or, after install:  5gpn [command]

  (no channel option) Resolve the latest official release when run from source.
  --beta              Resolve the latest beta prerelease through verified
                      quick-install.sh. A missing beta never falls back to official.
  (no command)        Full install/re-run. First install requires the TUI;
                      reinstall validates and reuses /etc/5gpn/dns.env. A
                      packaged script remains pinned to its tag unless an
                      explicit stable-to-beta handoff invokes verified quick-install.sh.
  configure           Open the full TUI, stage/verify, publish, probe, and rollback on failure
  upgrade-reset-mihomo
                      Explicit TTY-confirmed upgrade that replaces the complete
                      operator-owned mihomo config with the backed-up current seed
  menu                Open the interactive management menu (this is what bare '5gpn' runs)
  status              Show service states, domains, IP, list counts/age
  restart             Restart the 5gpn services (5gpn-dns + 5gpn-intercept + mihomo)
  reload-rules        Reload local policy and chnroute state from disk
  add-allow <cidr>    Add a source IP/CIDR to the zashboard allowlist + live refresh
  del-allow <cidr>    Remove a source IP/CIDR from the zashboard allowlist + live refresh
  ios                 Regenerate the iOS profile + QR
  setup-tgbot         Validate + hot-apply Telegram config through the local API
  rotate-token        Generate a new control-console DNS_API_TOKEN + restart
  set-cf-token        Enter/update the Cloudflare token through the TUI only
  mihomo-reset        Explicitly back up + replace the operator mihomo config
                      with a freshly rendered, validated seed, then restart
  uninstall [--purge|--decommission]
                       TUI-confirmed ownership-safe removal. Purge preserves cert/
                       debug-cert/acme and the interception root CA; decommission also
                       removes the owned interception CA and deletes a Certbot lineage only
                       when provenance proves that 5gpn created it
  help                This help

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
                     A-record needed for certificate issuance). A 5gpn-owned lineage
                     auto-renews through the daily 5gpn-certbot-renew.timer. A protected
                     Cloudflare API token is required for owned issuance/renewal;
                     missing credentials prompt in the TUI. A strictly validated external
                     lineage remains externally renewed and is never force-modified. The token
                     is stored in /etc/5gpn/acme/cloudflare.ini
                     (dir 0700, file 0600) and is NEVER written to dns.env or logs.
                     Use '5gpn set-cf-token' (or the menu) to update it at any time.
  http-01 mode       exact console/zash/dot SAN certificate via public TCP :80.
                     After explicit TUI confirmation, all three A records must
                     resolve through 1.1.1.1 to DNS_PUBLIC_IP with no AAAA.
                     Initial issuance keeps mihomo stopped until role certificates
                     are published and full_install starts services. Due renewal
                     briefly stops and restores mihomo with the scoped helper.
  interception leaf independent 5gpn-intercept-cert.timer checks the private
                     extension leaf daily in every certificate mode.
  debug mode         self-signed WILDCARD cert for a test/dev box with
                     no public domain — no certbot, no DNS-01, no renewal; clients
                     see it untrusted.
  Production reuse validates mode-specific SANs, renewal authenticator,
  provenance, trust, expiry, and cert/key matching;
  debug certificates are reusable only inside debug mode. If only a preserved
  production role copy survives, it is reused without issuance and renewal stays
  disabled until the Certbot lineage is repaired.

There is NO host firewall management: use your provider's security
group if you need one. New/reset mihomo seeds require client reachability to
TCP 80, 443, 5060, 8080, and 8443 plus UDP 443 and 5060. The console SPA and /ios/ are public
while /api/* requires the bearer token. Zashboard remains limited to source IPs
in mihomo's whitelist.txt allowlist.

  TUI configuration:
    certificate mode/email, base domain, public/gateway/listener IPv4,
    Cloudflare token, and Telegram identity/admins/proxy/alerts.

  Automatic runtime defaults:
    China/trust upstream groups, China ECS, and cache size. The authenticated
    Console can change the upstream groups and ECS at runtime.

  Fixed release inputs:
    DNS/mihomo/zashboard/Gum versions and SHA-256 values are embedded in the
    release installer. Unsigned profiles and profile-DNS bypasses do not exist.
EOF
}

# Keep the Telegram workflow in one source-only helper.
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

require_command_arity() {
    local name="$1" actual="$2" minimum="$3" maximum="$4"
    if (( actual < minimum || actual > maximum )); then
        err "Command '$name' received an unsupported number of arguments."
        return 1
    fi
}

main() {
    DNS_RELEASE_CHANNEL=stable
    DNS_RELEASE_CHANNEL_EXPLICIT=0
    if [[ "${1:-}" == --beta ]]; then
        DNS_RELEASE_CHANNEL=beta
        DNS_RELEASE_CHANNEL_EXPLICIT=1
        shift
    fi
    case "${1:-}" in
        --beta)
            err "--beta must be specified exactly once as the first argument."
            return 2 ;;
    esac
    # Piped install (curl | sudo bash): reattach stdin to the terminal so the
    # prompts below fire. No-op when stdin is already a tty; truly headless first
    # install/configuration fails closed instead of consuming caller environment.
    attach_tty
    clear_external_config_env
    local cmd="${1:-}"
    case "$cmd" in
        "")             require_command_arity install "$#" 0 0 || return $?; full_install ;;
        configure)      require_command_arity "$cmd" "$#" 1 1 || return $?; full_install configure ;;
        upgrade-reset-mihomo)
                         require_command_arity "$cmd" "$#" 1 1 || return $?; full_install upgrade-reset-mihomo ;;
        menu)           require_command_arity "$cmd" "$#" 1 1 || return $?; manage_menu ;;
        restart)        require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_lock restart_services ;;
        reload-rules)   require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_lock reload_rules ;;
        status)         require_command_arity "$cmd" "$#" 1 1 || return $?; show_status ;;
        add-allow)      require_command_arity "$cmd" "$#" 2 2 || return $?; run_management_with_install_lock add_allow_ip "$2" ;;
        del-allow)      require_command_arity "$cmd" "$#" 2 2 || return $?; run_management_with_install_lock del_allow_ip "$2" ;;
        ios)            require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_and_cert_lock regen_ios ;;
        setup-tgbot)    require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_lock setup_tgbot ;;
        rotate-token)   require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_lock rotate_token ;;
        set-cf-token)   require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_and_cert_lock set_cf_token ;;
        mihomo-reset)   require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_lock reset_mihomo_config ;;
        uninstall)      require_command_arity "$cmd" "$#" 1 2 || return $?; uninstall "${2:-}" ;;
        help)           require_command_arity "$cmd" "$#" 1 1 || return $?; usage ;;
        *)              err "Unknown command: $cmd"; echo ""; usage; exit 2 ;;
    esac
}

if [[ "${INSTALL_SH_LIB_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
