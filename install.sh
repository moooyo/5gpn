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
# One base domain, one mandatory WILDCARD cert lineage (2026-07-14, replaces the
# old http-01/:80 two-lineage flow):
#   BASE_DOMAIN  -> the operator's ONE apex domain (the single knob).
#   CONSOLE_DOMAIN/ZASH_DOMAIN/PROFILE_DOMAIN/DOT_DOMAIN
#     (= console./zash./profile./dot.<BASE_DOMAIN>)
#     are auto-derived subdomains (derive_domains), all covered by ONE
#     `*.<base>` + `<base>` Let's Encrypt cert issued via Cloudflare DNS-01
#     (certbot-dns-cloudflare; no :80 challenge). profile.<base> alone needs a
#     pre-existing client-resolvable A record for first-install bootstrap; the
#     panel/DoT names need no public A for certificate issuance. Auto-renewal is
#     unattended via the daily certbot timer.
#     CERT_MODE=debug issues a self-signed wildcard instead (test/dev boxes).
#
# QUIC/HTTP3 is proxied by mihomo (UDP 443 sniff-forward). No exit layer, no Go
# data plane. There is NO host firewall: nftables management was removed
# (2026-07-10) — use your provider's security group if you want one. The panels
# are reachable only from source IPs on the mihomo whitelist.txt allowlist
# (TUI-managed via `5gpn` add/del-allow); everything else gets REJECT-DROP.
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
set -euo pipefail

# ----------------------------------------------------------------------------
# Paths & constants
# ----------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || echo "${BASH_SOURCE[0]:-}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"   # repo 5gpn/ when run from a checkout

BASE_DIR="/opt/5gpn"                 # installed runtime root
SCRIPTS_DIR="${BASE_DIR}/scripts"        # installed copies of repo scripts
WWW_DIR="${BASE_DIR}/www"                # iOS profile web root (served in-process by 5gpn-dns)
BUILD_DIR="${BASE_DIR}/build"            # download/unpack scratch

CONF_DIR="/etc/5gpn"                 # config: dns.env is the single source of truth
DNS_BIN="/usr/local/bin/5gpn-dns"        # 5gpn-dns binary (DoT resolver + web console)
DNS_CERT_DIR="/etc/5gpn/cert"            # cert root; the ONE wildcard is copied into dot/, web/, zash/
DEBUG_CERT_DIR="/etc/5gpn/debug-cert"     # self-signed debug certs; NEVER under /etc/letsencrypt
DOT_CERT_DIR="${DNS_CERT_DIR}/dot"       # DoT :853 cert copy (hot-reloaded on mtime change)
WEB_CERT_DIR="${DNS_CERT_DIR}/web"       # web-console :18443 cert copy
ZASH_CERT_DIR="${DNS_CERT_DIR}/zash"     # zashboard panel cert copy
ACME_DIR="/etc/5gpn/acme"                # root-only Cloudflare API-token credentials dir
DNS_WEB_DIR="/opt/5gpn/web"               # control-console SPA (served from disk by :18443)
# DNS_ZASH_DIR (zashboard SPA dist, config.go's ZashDir) is resolved just below
# cfg_get()'s definition -- NOT here: the daemon reads DNS_ZASH_DIR out of dns.env,
# so it must honor a dns.env value (env > cfg_get > default) and survive a bare
# re-install, and cfg_get isn't defined yet at this point in the file.
DNS_RULES_DIR_DEFAULT="/etc/5gpn/rules"  # rule files: blacklist.txt, direct.txt, etc.
MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_DIR="/etc/5gpn/mihomo"           # config.yaml + whitelist.txt + provider caches
ZASH_OWNERSHIP_MARKER=".5gpn-zashboard-owned"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.28}"
ZASH_VERSION="${ZASH_VERSION:-v3.15.0}"  # Zephyruso/zashboard prebuilt dist.zip
# Legacy: SMARTDNS_DIR kept only for remove-on-upgrade logic below; not used by new install.
SMARTDNS_DIR="/etc/smartdns"
# Old sing-box paths — kept ONLY so migration can stop/disable/remove them (see install_mihomo + uninstall).
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/usr/local/etc/sing-box"
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
GUM_VERSION="${GUM_VERSION:-0.17.0}"     # charmbracelet/gum (prebuilt; installer TUI)
_HAVE_GUM=0                              # set by install_gum(); helpers fall back to echo when 0

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
# Run an opaque wait command behind a spinner when interactive; else run it plainly.
gum_spin()   { local t="$1"; shift; if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then gum spin --title "$t" -- "$@"; else "$@"; fi; }
# Frame multi-line stdin in a rounded box when interactive; else pass it through.
card()       { if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then gum style --border rounded --padding "0 1" --border-foreground 212; else cat; fi; }

# attach_tty makes a PIPED install interactive. Run via `curl | sudo bash`, fd 0 is
# the pipe/script, not the terminal, so [[ -t 0 ]] is false and EVERY prompt below
# is skipped — DOMAIN/GATEWAY_IP/XRAY_RESOLVER stay unset and the run aborts on the
# missing domain. If a controlling terminal exists, reattach stdin to it so the
# install prompts as intended. Truly headless runs (no /dev/tty: CI, cloud-init,
# systemd) fall through untouched and stay non-interactive (env-var driven). Called
# once from main(); a no-op when stdin is already a terminal.
attach_tty() {
    [[ -t 0 ]] && return 0
    if [[ -e /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; then
        exec 0</dev/tty
        info "管道安装：已将输入接入当前终端 (/dev/tty)，将进行交互式提问（域名 / 网关IP / 解析器）。"
    fi
}

# ── Single config file ──────────────────────────────────────────────────────
# /etc/5gpn/dns.env is the ONE source of truth for every persisted knob. There
# are NO per-key .state files and no multi-tier precedence: a value resolves as
# `env override > dns.env value > default/prompt`, then write_dns_env persists it
# back. cfg_get reads one key from dns.env (empty if absent); it greps rather
# than sourcing so a value can contain any shell-special character safely.
cfg_get() {
    [[ -f "${CONF_DIR}/dns.env" ]] || return 0
    # `|| true` keeps cfg_get exit 0 even when the key is absent: under
    # `set -euo pipefail` a grep no-match (pipeline rc=1) inside a bare
    # `VAR="$(cfg_get X)"` assignment would otherwise abort the whole install.
    grep -E "^${1}=" "${CONF_DIR}/dns.env" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# DNS_ZASH_DIR resolves env > dns.env (cfg_get) > default HERE, right after
# cfg_get is defined -- so install_zashboard / clean_previous_install / uninstall
# (which all read the global $DNS_ZASH_DIR) honor an operator's dns.env value and
# it survives a bare re-install, matching DNS_ZASH_LISTEN. Do NOT move this back
# up into the constants block: cfg_get() isn't defined there, so it would silently
# fall through to the default and clobber a customized dns.env value on re-install.
DNS_ZASH_DIR="${DNS_ZASH_DIR:-$(cfg_get DNS_ZASH_DIR)}"
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

safe_zashboard_path() {
    local p
    [[ -n "${DNS_ZASH_DIR:-}" && "$DNS_ZASH_DIR" != *$'\n'* && "$DNS_ZASH_DIR" != *$'\r'* ]] \
        || { err "DNS_ZASH_DIR is empty or contains a newline; refusing it."; return 1; }
    p="$(canonical_dir_path "$DNS_ZASH_DIR")" \
        || { err "Could not canonicalize DNS_ZASH_DIR='$DNS_ZASH_DIR'."; return 1; }
    case "$p" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|"$BASE_DIR"|"$CONF_DIR")
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

# Bootstrap gum (prebuilt binary + sha256 verify). Never fatal: on any failure
# _HAVE_GUM stays 0 and all helpers fall back to plain echo.
install_gum() {
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
    tmp="$(mktemp -d 2>/dev/null)" || { warn "gum: mktemp failed; using plain output."; _HAVE_GUM=0; return 0; }
    if ! command -v curl >/dev/null 2>&1 \
       || ! curl -fsSL "$url" -o "$tmp/gum.tgz" 2>/dev/null; then
        warn "gum download failed; using plain output."
        rm -rf -- "$tmp"; return 0
    fi

    exp="${GUM_SHA256:-}"
    if [[ -z "$exp" ]]; then
        curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/checksums.txt" \
             -o "$tmp/sums.txt" 2>/dev/null \
            && exp="$(awk -v f="gum_${GUM_VERSION}_Linux_${arch}.tar.gz" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/sums.txt" 2>/dev/null || true)"
    fi
    exp="${exp,,}"
    if [[ ! "$exp" =~ ^[0-9a-f]{64}$ ]]; then
        warn "gum checksum is missing or invalid; refusing to install it and using plain output."
        rm -rf -- "$tmp"; return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        got="$(sha256sum "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
    elif command -v shasum >/dev/null 2>&1; then
        got="$(shasum -a 256 "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
    else
        warn "no SHA-256 tool is available; refusing to install gum and using plain output."
        rm -rf -- "$tmp"; return 0
    fi
    got="${got,,}"
    if [[ "$got" != "$exp" ]]; then
        warn "gum sha256 mismatch; refusing to install it and using plain output."
        rm -rf -- "$tmp"; return 0
    fi
    if ! tar -xzf "$tmp/gum.tgz" -C "$tmp" 2>/dev/null; then
        warn "gum archive extraction failed; using plain output."
        rm -rf -- "$tmp"; return 0
    fi
    bin="$(find "$tmp" -type f -name gum 2>/dev/null | head -1 || true)"
    if [[ -z "$bin" ]] || ! "$bin" --version 2>/dev/null | grep -qF "$GUM_VERSION" \
       || ! install -m 0755 "$bin" /usr/local/bin/gum 2>/dev/null; then
        warn "verified gum archive did not contain an installable ${GUM_VERSION} binary; using plain output."
        rm -rf -- "$tmp"; return 0
    fi
    rm -rf -- "$tmp" 2>/dev/null || true
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

# Sets MEM_TOTAL_MB, LOWMEM (0/1), MAKE_JOBS, CACHE_SIZE. LOWMEM env overrides.
detect_memory_profile() {
    MEM_TOTAL_MB=$(awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0)
    if [[ -n "${LOWMEM:-}" ]]; then
        case "$LOWMEM" in 1|yes|true|on) LOWMEM=1 ;; *) LOWMEM=0 ;; esac
    elif [[ "${MEM_TOTAL_MB:-0}" -le 1300 ]]; then LOWMEM=1; else LOWMEM=0; fi

    # RAM-derived cache default only; full_install resolves the effective
    # CACHE_SIZE (env > dns.env DNS_CACHE_SIZE > this default) — the single-source
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
    [[ -e /swapfile ]] && return 0
    local avail_mb; avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [[ -z "$avail_mb" || "$avail_mb" -lt 1536 ]]; then
        warn "Not enough free disk for a swapfile (${avail_mb:-?}MB); skipping."; return 0
    fi
    info "Creating 1G swapfile (low-memory host)..."
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null || {
        warn "swapfile allocation failed; continuing without swap."; rm -f /swapfile; return 0; }
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null || {
        warn "mkswap/swapon failed; skipping swap."; rm -f /swapfile; return 0; }
    grep -q '^/swapfile ' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
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
        err "Failed to detect public IPv4. Set PUBLIC_IP=<ip> and retry."; exit 1
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
# sing-box/smartdns/xray data planes) ARE stopped — nothing should restart those,
# including a box upgrading from a pre-mihomo xray install (xray.service would
# otherwise keep holding :443/:80 and mihomo could never bind).
# The gum binary is NOT removed (the running installer's own TUI helpers exec
# it); install_gum refreshes it in place when the GUM_VERSION pin moves.
clean_previous_install() {
    info "Cleaning previous install artifacts (units + generated configs; /etc/5gpn kept)..."

    # Validate/claim a custom zashboard path before the BASE_DIR sweep below.
    # This makes later cleanup depend on a strong ownership marker instead of
    # trusting an arbitrary root-supplied DNS_ZASH_DIR.
    claim_zashboard_dir

    # Our two live units: remove the unit FILES only (no stop). install_units
    # reinstalls them before install_cert runs (cloudflare DNS-01 needs no :80/
    # mihomo coordination — the certbot API sets the TXT record directly).
    rm -f /etc/systemd/system/5gpn-dns.service /etc/systemd/system/mihomo.service

    # Legacy units: stop + remove (regenerated later where still applicable,
    # e.g. the renew timer via install_renewal_automation).
    local unit
    for unit in 5gpn-api.service 5gpn-tgbot.service 5gpn-iosprofile.socket \
                '5gpn-iosprofile@.service' xray.service sing-box.service smartdns.service \
                sniproxy.service 5gpn-certbot-renew.timer 5gpn-certbot-renew.service; do
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/$unit"
    done
    systemctl daemon-reload 2>/dev/null || true

    # Stray binaries of removed components (current binaries are replaced by
    # their installers, not pre-deleted — no broken window on download failure).
    rm -f "$SINGBOX_BIN"

    # Generated runtime configs + tuning (all regenerated later this run). The
    # legacy xray config dir is removed by literal path (upgrade-from-xray).
    rm -rf /usr/local/etc/xray "$SINGBOX_DIR"
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh \
          /etc/letsencrypt/renewal-hooks/pre/10-5gpn-stop-xray.sh \
          /etc/letsencrypt/renewal-hooks/post/10-5gpn-start-xray.sh \
          /etc/letsencrypt/renewal-hooks/pre/10-5gpn-open80.sh \
          /etc/letsencrypt/renewal-hooks/post/10-5gpn-close80.sh
    rm -f /etc/sysctl.d/99-5gpn.conf /etc/modules-load.d/5gpn.conf /etc/modprobe.d/5gpn.conf

    # /opt/5gpn runtime tree: wipe everything EXCEPT the staged install.sh —
    # when the operator launched this run VIA that staged copy (`5gpn` menu),
    # deleting it would make install_manage_cli's restage fall back to a GitHub
    # fetch instead of the copy that is actually running. web/ www/ scripts/
    # build/ etc/ are all repopulated by install_web / setup_ios_profile /
    # install_files this same run.
    if [[ -d "$BASE_DIR" ]]; then
        find "$BASE_DIR" -mindepth 1 -maxdepth 1 ! -name install.sh -exec rm -rf {} + 2>/dev/null || true
    fi
    # A custom zashboard dist may live outside BASE_DIR. Clear it only while
    # its 5gpn ownership marker is still present; the default path was already
    # removed by the BASE_DIR sweep and is recreated by install_zashboard.
    if [[ -d "$DNS_ZASH_DIR" ]]; then
        clear_zashboard_dir
    fi

    ok "Previous artifacts cleaned (kept: ${CONF_DIR}, /etc/letsencrypt)."
}

# Remove retired draft/generation and structured-egress state on upgrade. Keep
# this outside clean_previous_install: that function's contract is to leave
# /etc/5gpn entirely untouched, while this narrow migration deliberately
# removes only stores that no current daemon path reads. The live unified
# policy model at /etc/5gpn/policy.json is intentionally preserved.
remove_legacy_policy_state() {
    rm -rf "${CONF_DIR}/policy"
    rm -f "${CONF_DIR}/egress.json" "${CONF_DIR}/egress-nodes.enc"
}

install_deps() {
    info "Installing dependencies..."
    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || true
            apt-get install -y -qq \
                wget curl ca-certificates unzip iproute2 \
                certbot python3-certbot-dns-cloudflare qrencode jq libcap2-bin \
                dnsutils || warn "some apt packages failed; continuing."
            ;;
        dnf|yum)
            $PKG_MGR install -y -q \
                wget curl ca-certificates unzip iproute \
                certbot python3-certbot-dns-cloudflare qrencode jq \
                bind-utils || warn "some rpm packages failed; continuing."
            # libcap setcap tooling (name varies by distro)
            $PKG_MGR install -y -q libcap libcap-ng-utils 2>/dev/null || true
            ;;
    esac

    install_5gpndns

    # certbot may break on very new Python; try to repair non-fatally.
    if command -v certbot >/dev/null 2>&1 && ! certbot --version >/dev/null 2>&1; then
        warn "certbot self-check failed; attempting pip repair."
        pip3 install --upgrade --break-system-packages certbot 2>/dev/null \
            || pip3 install --upgrade certbot 2>/dev/null || true
    fi
    command -v certbot >/dev/null 2>&1 || { err "certbot is required but missing."; exit 1; }
    # certbot-dns-cloudflare (the Cloudflare DNS-01 plugin) may not ship as an apt/
    # dnf package on every distro; fall back to pip so `certbot --dns-cloudflare`
    # is always available for CERT_MODE=cloudflare.
    if command -v certbot >/dev/null 2>&1 && ! certbot plugins 2>/dev/null | grep -q dns-cloudflare; then
        warn "certbot-dns-cloudflare plugin missing; attempting pip install."
        pip3 install --break-system-packages certbot-dns-cloudflare 2>/dev/null \
            || pip3 install certbot-dns-cloudflare 2>/dev/null || true
    fi
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
    local ver="${DNS_VERSION:-$DNS_VERSION_DEFAULT}"
    local cur=""
    [[ -x "$DNS_BIN" ]] && cur="$("$DNS_BIN" -version 2>/dev/null | head -1 || true)"
    local url="https://github.com/moooyo/5gpn/releases/download/${ver}/5gpn-dns-linux-amd64"
    info "Downloading 5gpn-dns ${ver} (prebuilt binary; no Go toolchain${cur:+; replacing installed ${cur}})..."
    mkdir -p "$BUILD_DIR"
    local bin_dl="$BUILD_DIR/5gpn-dns-linux-amd64"
    gum_spin "Downloading 5gpn-dns ${ver}…" curl -fsSL "$url" -o "$bin_dl" \
        || { err "5gpn-dns download failed ($url)"; \
             err "If ${ver} has not been published yet (no GitHub release/tag), pin an existing one with DNS_VERSION=<tag>. (Any previously installed binary was left untouched.)"; \
             exit 1; }
    # Integrity: opt-in only. Set DNS_SHA256=<hash> to pin the binary.
    local exp="${DNS_SHA256:-}"
    if [[ -n "$exp" ]]; then
        local got; got="$(sha256sum "$bin_dl" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { err "5gpn-dns sha256 mismatch (want $exp got $got)"; exit 1; }
        ok "5gpn-dns binary sha256 verified."
    else
        warn "5gpn-dns sha256 UNVERIFIED (set DNS_SHA256 to pin)."
    fi
    install -m 0755 "$bin_dl" "$DNS_BIN"
    [[ -x "$DNS_BIN" ]] || { err "5gpn-dns install failed."; exit 1; }
    ok "5gpn-dns installed to $DNS_BIN (${ver})."
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
    local ver="${DNS_VERSION:-$DNS_VERSION_DEFAULT}"
    local v="${ver#dns-}"
    local url="https://github.com/moooyo/5gpn/releases/download/${ver}/5gpn-web-${v}.tar.gz"
    info "Downloading control-console SPA (5gpn-web ${v})..."
    mkdir -p "$BUILD_DIR" "$DNS_WEB_DIR"
    local tgz="$BUILD_DIR/5gpn-web-${v}.tar.gz"
    gum_spin "Downloading 5gpn-web ${v}…" curl -fsSL "$url" -o "$tgz" \
        || { warn "5gpn-web download failed ($url); the console will show a placeholder."; return 0; }
    local exp="${WEB_SHA256:-}"
    if [[ -n "$exp" ]]; then
        local got; got="$(sha256sum "$tgz" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { err "5gpn-web sha256 mismatch (want $exp got $got)"; exit 1; }
        ok "5gpn-web sha256 verified."
    fi
    rm -rf "${DNS_WEB_DIR:?}"/*
    tar -xzf "$tgz" -C "$DNS_WEB_DIR" \
        || { warn "5gpn-web extract failed; the console will show a placeholder."; return 0; }
    printf '%s\n' "$ver" > "${DNS_WEB_DIR}/.web_version"
    ok "Control-console SPA installed to ${DNS_WEB_DIR}/ (${ver})."
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
    local ver="${ZASH_VERSION}"
    local url="https://github.com/Zephyruso/zashboard/releases/download/${ver}/dist.zip"
    info "Downloading zashboard ${ver}..."
    mkdir -p "$BUILD_DIR"
    claim_zashboard_dir || return 1
    local zip="$BUILD_DIR/zashboard-${ver}.zip"
    gum_spin "Downloading zashboard ${ver}…" curl -fsSL "$url" -o "$zip" \
        || { warn "zashboard download failed ($url); the zash panel will be empty."; return 0; }
    local exp="${ZASH_SHA256:-}"
    if [[ -n "$exp" ]]; then
        local got; got="$(sha256sum "$zip" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { err "zashboard sha256 mismatch (want $exp got $got)"; exit 1; }
        ok "zashboard sha256 verified."
    fi
    clear_zashboard_dir || return 1
    # dist.zip may pack a top-level dist/ dir -- normalize so index.html lands at $DNS_ZASH_DIR/.
    unzip -qo "$zip" -d "$DNS_ZASH_DIR" \
        || { warn "zashboard extract failed; the zash panel will be empty."; return 0; }
    if [[ -f "$DNS_ZASH_DIR/dist/index.html" ]]; then
        mv "$DNS_ZASH_DIR"/dist/* "$DNS_ZASH_DIR"/ && rmdir "$DNS_ZASH_DIR/dist"
    fi
    printf '%s\n' "$ver" > "${DNS_ZASH_DIR}/.zash_version"
    ok "zashboard installed to ${DNS_ZASH_DIR}/ (${ver})."
}

# mihomo: prebuilt binary from MetaCubeX/mihomo releases (amd64-compatible).
# Pinned by MIHOMO_VERSION (env or default); opt-in sha256 verify via MIHOMO_SHA256.
#
# Fresh-artifact rule (2026-07-10): ALWAYS downloads the pinned MIHOMO_VERSION
# and installs it over $MIHOMO_BIN (install(1) unlinks first — safe while the old
# process is running; start_services restarts into it). No keep-if-present path.
install_mihomo() {
    local ver="${MIHOMO_VERSION}"
    local url="https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-amd64-compatible-${ver}.gz"
    info "Downloading mihomo ${ver}..."
    mkdir -p "$BUILD_DIR"
    local bin_dl="$BUILD_DIR/mihomo.gz"
    gum_spin "Downloading mihomo ${ver}…" curl -fsSL "$url" -o "$bin_dl" \
        || { err "mihomo download failed ($url)"; return 1; }
    local exp="${MIHOMO_SHA256:-}"
    if [[ -n "$exp" ]]; then
        local got; got="$(sha256sum "$bin_dl" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { err "mihomo sha256 mismatch (want $exp got $got)"; return 1; }
        ok "mihomo sha256 verified."
    fi
    gunzip -f "$bin_dl"
    install -m 0755 "$BUILD_DIR/mihomo" "$MIHOMO_BIN"
    [[ -x "$MIHOMO_BIN" ]] || { err "mihomo install failed."; return 1; }
    ok "mihomo installed to $MIHOMO_BIN (${ver})."
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

    # Default §7 list URLs — env override > default (matches every other knob).
    local china_list_url="${CHINA_LIST_URL:-https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf}"
    local gfw_url="${GFW_URL:-https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt}"

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
    if [[ "$xr" =~ ^https://[A-Za-z0-9./_:-]+$ ]] || [[ "$xr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        info "Sniffed-origin resolution uses the loopback DNS broker (127.0.0.1:5354); DNS_EGRESS_RESOLVER='${xr}' is the broker fallback upstream (consumed by 5gpn-dns)."
    else
        warn "DNS_EGRESS_RESOLVER='${xr}' is neither an IPv4 nor an https:// DoH URL; the broker fallback cannot use it -- fix it."
        return 1
    fi
}

# render_mihomo_config renders /etc/5gpn/mihomo/config.yaml from the committed
# template (etc/mihomo/config.yaml.tmpl), substituting the box-specific
# sentinels, seeds the panel whitelist.txt on first run, then validates the
# rendered file with `mihomo -t` (fatal on failure — a bad config must never
# be left live). This is the SINGLE writer for the mihomo data-plane config;
# re-run it whenever a consumed value (PUBLIC_IP/GATEWAY_IP/WEB_DOMAIN)
# changes. Replaces the old xray-config copy + the three per-field xray-config
# patcher functions this migration retired (gateway/resolver/webdomain).
seed_mihomo_whitelist() {
    # whitelist.txt is TUI-managed after install and never clobbered.
    if [[ ! -f "$MIHOMO_DIR/whitelist.txt" ]]; then
        install -m 0644 "${SCRIPT_DIR}/etc/mihomo/whitelist.seed.txt" "$MIHOMO_DIR/whitelist.txt"
        local admin_cidr="${ADMIN_CIDR:-}"
        if [[ -z "$admin_cidr" && -n "${SSH_CONNECTION:-}" ]]; then
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
            ok "Seeded panel whitelist with admin CIDR ${admin_cidr} (refine via the 5gpn menu)."
        else
            warn "No admin CIDR detected; ${MIHOMO_DIR}/whitelist.txt has no entries yet -- panels are unreachable until you add one via the 5gpn menu."
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
        line="${line//__PROFILE_DOMAIN__/$PROFILE_DOMAIN}"
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
# Panel source-IP allowlist (whitelist.txt) — TUI-managed OUT-OF-BAND, never
# web-editable. add/del edit the file directly, then apply_whitelist pushes it
# live via the mihomo controller's rule-provider reload — NOT a full config
# reload/restart, so an in-flight admin session over the panel is undisturbed.
# ----------------------------------------------------------------------------

# apply_whitelist pushes the on-disk whitelist.txt live via the mihomo
# controller's rule-provider reload endpoint (no full config reload/restart).
apply_whitelist() {
    # TODO(Task 6): read DNS_MIHOMO_SECRET once that dns.env knob exists. Until
    # then, source the controller secret the same way render_mihomo_config's
    # own re-render path does: read it back out of the rendered config.yaml.
    local secret; secret="$(sed -n 's/^secret:[[:space:]]*//p' "$MIHOMO_DIR/config.yaml" 2>/dev/null | head -1)"
    curl -fsS -X PUT "http://127.0.0.1:9090/providers/rules/whitelist" \
        -H "Authorization: Bearer ${secret}" -o /dev/null \
        && ok "whitelist applied" || warn "whitelist refresh failed (is mihomo running?)"
}

# add_allow_ip appends a source IP/CIDR to the panel allowlist and refreshes
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

# del_allow_ip removes a source IP/CIDR from the panel allowlist and
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
    rm -rf "${DNS_RULES_DIR_DEFAULT}"/adblock "${DNS_RULES_DIR_DEFAULT}"/adblock*.txt 2>/dev/null || true

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
install_manage_cli() {
    install -d -m 0755 "$BASE_DIR"
    if [[ -f "$SCRIPT_PATH" ]]; then
        install -m 0755 "$SCRIPT_PATH" "${BASE_DIR}/install.sh"
    else
        # Piped install (curl|bash) with no on-disk script — fetch the installer
        # so the management backend exists. Non-fatal: the launcher warns if absent.
        curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/install.sh \
            -o "${BASE_DIR}/install.sh" 2>/dev/null && chmod 755 "${BASE_DIR}/install.sh" \
            || warn "could not stage ${BASE_DIR}/install.sh for the 5gpn command (piped install)."
    fi
    cat > /usr/local/bin/5gpn <<'EOF'
#!/usr/bin/env bash
# 5gpn management launcher. `5gpn` opens the menu; `5gpn <subcommand>` runs it
# directly (e.g. 5gpn --status, 5gpn restart, 5gpn --uninstall).
BK=/opt/5gpn/install.sh
[ -f "$BK" ] || { echo "5gpn backend missing ($BK); re-run the installer." >&2; exit 1; }
if [ $# -eq 0 ]; then exec bash "$BK" --menu; else exec bash "$BK" "$@"; fi
EOF
    chmod 755 /usr/local/bin/5gpn
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
# dns.env (env overrides still win): identities, cert mode, email. Auto-detects
# + persists PUBLIC_IP if it was never captured (used by mihomo's listener bind
# + debug-mode self-signed cert SANs; cloudflare-mode DNS-01 needs no public IP).
# BASE_DOMAIN is the authoritative apex knob; WEB/DOT are the derived
# console.<base>/dot.<base> service domains read back from dns.env.
_load_change_ctx() {
    PUBLIC_IP="${PUBLIC_IP:-$(cfg_get DNS_PUBLIC_IP)}"
    GATEWAY_IP="${GATEWAY_IP:-$(cfg_get DNS_GATEWAY_IP)}"
    WEB_DOMAIN="${WEB_DOMAIN:-$(cfg_get DNS_WEB_DOMAIN)}"
    DOT_DOMAIN="${DOT_DOMAIN:-$(cfg_get DNS_DOMAIN)}"
    PROFILE_DOMAIN="${PROFILE_DOMAIN:-$(cfg_get DNS_PROFILE_DOMAIN)}"
    BASE_DOMAIN="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    # Legacy fallback: a box predating the base-domain scheme has no
    # DNS_BASE_DOMAIN. Recover the apex from the (possibly console.<base>)
    # web-console domain so change-* still targets the right wildcard.
    [[ -z "$BASE_DOMAIN" ]] && BASE_DOMAIN="${WEB_DOMAIN#console.}"
    derive_domains "$BASE_DOMAIN"
    CERT_MODE="${CERT_MODE:-$(cfg_get CERT_MODE)}"; CERT_MODE="${CERT_MODE:-cloudflare}"
    CERT_EMAIL="${CERT_EMAIL:-$(cfg_get CERT_EMAIL)}"
    if [[ -z "$PUBLIC_IP" ]]; then
        get_public_ip                                            # sets PUBLIC_IP or exits
        set_dns_env_kv "${CONF_DIR}/dns.env" DNS_PUBLIC_IP "$PUBLIC_IP"
    fi
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_MIHOMO_LISTEN_IPS "$MIHOMO_LISTEN_IPS"
    export PUBLIC_IP GATEWAY_IP WEB_DOMAIN DOT_DOMAIN PROFILE_DOMAIN BASE_DOMAIN CERT_MODE CERT_EMAIL MIHOMO_LISTEN_IPS
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
    PROFILE_DOMAIN="profile.${BASE_DOMAIN}"
    DOT_DOMAIN="dot.${BASE_DOMAIN}"
    WEB_DOMAIN="$CONSOLE_DOMAIN"    # back-compat: WEB_DOMAIN == the console panel
    export BASE_DOMAIN CONSOLE_DOMAIN ZASH_DOMAIN PROFILE_DOMAIN DOT_DOMAIN WEB_DOMAIN
}

# change_base_domain re-points the operator's ONE base (apex) domain and every
# service subdomain derived from it (console./zash./dot.<base>): (re)issue/reuse
# the single *.<base> wildcard, persist DNS_BASE_DOMAIN + the derived
# DNS_DOMAIN/DNS_WEB_DOMAIN/DNS_CONSOLE_DOMAIN/DNS_ZASH_DOMAIN, re-render the
# mihomo config (console/zash hosts + SNI allowlist rules), regenerate the iOS
# profile (dot.<base>), and restart mihomo + 5gpn-dns.
change_base_domain() {
    check_root
    install_gum
    _load_change_ctx
    local new="${1:-}"
    if [[ -z "$new" && -t 0 ]]; then
        new="$(ask_text '新的主域名 base domain (如 example.com):' "$BASE_DOMAIN" || true)"
    fi
    new="${new#http://}"; new="${new#https://}"; new="${new%/}"; new="${new// /}"
    is_valid_domain "$new" || { err "Invalid domain: '$new'. Usage: 5gpn change-base-domain <fqdn>"; return 1; }
    derive_domains "$new"

    info "Changing base domain to ${new} (CERT_MODE=${CERT_MODE}): console.${new} / zash.${new} / profile.${new} / dot.${new}..."
    install_cert "$new"                                                    # issue/reuse the *.<new> wildcard
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_BASE_DOMAIN "$new"            # persist the single knob
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_DOMAIN "$DOT_DOMAIN"          # derived DoT domain
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_WEB_DOMAIN "$WEB_DOMAIN"      # derived console domain
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_CONSOLE_DOMAIN "$CONSOLE_DOMAIN"
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_ZASH_DOMAIN "$ZASH_DOMAIN"
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_PROFILE_DOMAIN "$PROFILE_DOMAIN"
    apply_domain_to_mihomo                                                 # validate/preserve operator config
    setup_ios_profile || warn "iOS profile regeneration failed (fail-closed); profile may be absent."
    restart_services
    verify_profile_dns
    verify_profile_endpoint
    ok "Base domain changed to ${new}: *.${new} wildcard issued/reused, operator mihomo config preserved, iOS regenerated, services verified."
    info "控制台: https://${CONSOLE_DOMAIN}/   zashboard: https://${ZASH_DOMAIN}/   iOS: https://${PROFILE_DOMAIN}/ios/ios-dot.mobileconfig   DoT: tls://${DOT_DOMAIN}:853"
    print_qr
}

# change_public_ip re-points the public IPv4 (cert A-record target + mihomo's
# anti-loop self IP + listener bind address): persist DNS_PUBLIC_IP, re-render
# the mihomo config, reissue the debug self-signed certs whose SAN embeds the
# IP, restart mihomo.
change_public_ip() {
    check_root
    install_gum
    _load_change_ctx
    local new="${1:-}"
    if [[ -z "$new" && -t 0 ]]; then
        local detected=""
        detected="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || true)"
        new="$(ask_text "新的公网 IPv4 (当前 ${PUBLIC_IP:-未设置}; 检测到 ${detected:-无}):" "${detected:-$PUBLIC_IP}" || true)"
        new="${new// /}"
        [[ -z "$new" && -n "$detected" ]] && new="$detected"
    fi
    is_valid_ipv4 "$new" || { err "Invalid public IP: '$new'. Usage: 5gpn change-public-ip <ipv4>"; return 1; }
    PUBLIC_IP="$new"; export PUBLIC_IP

    info "Changing public IP to ${PUBLIC_IP}..."
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_PUBLIC_IP "$PUBLIC_IP"
    apply_gateway_to_mihomo                     # validate/preserve operator config
    # Debug self-signed certs embed the public IP in their SAN — reissue. The
    # cloudflare wildcard is name-only (DNS-01); the IP change does not touch it
    # (and these subdomains carry no public A record to update in the first place).
    if [[ "$CERT_MODE" == "debug" ]]; then
        derive_domains "${BASE_DOMAIN:-$WEB_DOMAIN}"    # single source; empty falls back to its own "5gpn.local" placeholder
        install_cert "$BASE_DOMAIN"
    fi
    restart_services
    verify_profile_dns
    verify_profile_endpoint
    ok "Public IP changed to ${PUBLIC_IP}: dns.env persisted, operator mihomo config preserved, services verified."
}

# change_resolver re-points the Egress DNS Broker's fallback resolver: validate,
# persist DNS_EGRESS_RESOLVER (primary) + XRAY_RESOLVER (back-compat) into
# dns.env, restart 5gpn-dns (the daemon consumes it directly; mihomo's config
# does not reference it at all -- its dns.nameserver always points at the fixed
# loopback broker). This is the resolver that turns a sniffed (often GFW-blocked)
# SNI into the real server IP before egress dials it — not prompted at install.
change_resolver() {
    check_root
    install_gum
    local cur; cur="$(cfg_get DNS_EGRESS_RESOLVER)"; cur="${cur:-$(cfg_get XRAY_RESOLVER)}"; cur="${cur:-$DNS_EGRESS_RESOLVER_DEFAULT}"
    local new="${1:-}"
    if [[ -z "$new" && -t 0 ]]; then
        new="$(ask_text "回源 SNI 解析器 (当前 ${cur}; 明文 UDP IPv4 或 https://…/dns-query DoH):" "$cur" || true)"
        new="${new// /}"
    fi
    [[ -z "$new" ]] && { err "No resolver given. Usage: 5gpn change-resolver <plain-IPv4 | https://…/dns-query>"; return 1; }
    if ! { [[ "$new" =~ ^https://[A-Za-z0-9./_:-]+$ ]] || [[ "$new" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }; then
        err "Invalid resolver '$new' (want a plain IPv4 like 1.1.1.1 or an https://…/dns-query DoH URL)."
        return 1
    fi
    info "Changing the Egress DNS Broker's fallback resolver to ${new}..."
    validate_egress_resolver "$new" || return 1
    # Persist BOTH keys with the same value: DNS_EGRESS_RESOLVER is the primary
    # (config.go prefers it); XRAY_RESOLVER is kept so a box mid-upgrade whose
    # daemon still only reads the old key stays consistent.
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_EGRESS_RESOLVER "$new"
    set_dns_env_kv "${CONF_DIR}/dns.env" XRAY_RESOLVER "$new"
    # Reachability precheck for a plain-UDP IPv4 (DoH is not dig-probed).
    if [[ "$new" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && command -v dig >/dev/null 2>&1; then
        if dig +time=3 +tries=1 +short A example.com "@${new}" 2>/dev/null | grep -qE '^[0-9.]+$'; then
            ok "Resolver reachable (plain UDP ${new})."
        else
            warn "Resolver ${new} did NOT answer a test query — proxied domains may fail. Double-check it."
        fi
    fi
    # 5gpn-dns consumes the resolver (the Egress DNS Broker fallback exchanger is
    # built from it at startup), so restart the daemon to pick up the change.
    # mihomo needs no restart: its config never references the resolver.
    restart_dns_service
    ok "Egress DNS Broker fallback resolver changed to ${new}: dns.env persisted, 5gpn-dns restarted."
}

# change_gateway re-points the client-facing gateway IP: persist DNS_GATEWAY_IP into
# the single dns.env, re-render the mihomo config (anti-loop blackhole) + the
# iOS profile's ServerAddresses, reissue the (debug) self-signed cert whose SAN
# embeds the IP, and restart 5gpn-dns (it reads GatewayIP only at startup) +
# mihomo (new blackhole). The cloudflare wildcard is name-based (DNS-01), so no
# reissue there. The rest is read from dns.env.
change_gateway() {
    check_root
    install_gum
    _load_change_ctx
    local new="${1:-}"
    if [[ -z "$new" && -t 0 ]]; then
        new="$(ask_text '新的客户端可达网关IP (如 172.22.0.1):' "$GATEWAY_IP" || true)"
    fi
    new="${new// /}"
    is_valid_ipv4 "$new" || { err "Invalid gateway IP: '$new'. Usage: 5gpn change-gateway <ipv4>"; return 1; }

    GATEWAY_IP="$new"; export GATEWAY_IP

    info "Changing gateway IP to ${GATEWAY_IP} (CERT_MODE=${CERT_MODE})..."
    set_dns_env_kv "${CONF_DIR}/dns.env" DNS_GATEWAY_IP "$GATEWAY_IP"   # persist into the single config
    apply_gateway_to_mihomo                                            # validate/preserve operator config
    # The debug self-signed cert embeds IP:GATEWAY_IP in its SAN, so a client
    # reaching the box by the new IP would otherwise hit a SAN mismatch — reissue.
    # The cloudflare wildcard is name-only, so the IP change does not touch it.
    if [[ "$CERT_MODE" == "debug" ]]; then
        derive_domains "${BASE_DOMAIN:-$WEB_DOMAIN}"    # single source; empty falls back to its own "5gpn.local" placeholder
        install_cert "$BASE_DOMAIN"
    fi
    setup_ios_profile || warn "iOS profile regeneration failed (fail-closed); profile may be absent."
    restart_services
    verify_profile_dns
    verify_profile_endpoint
    ok "Gateway IP changed to ${GATEWAY_IP}: dns.env persisted, operator mihomo config preserved, iOS profile refreshed, services verified."
    print_qr
}

# manage_menu is the interactive management TUI shown by `5gpn`. gum when
# available on a TTY; a numbered read-menu otherwise. Loops until Quit.
manage_menu() {
    check_root
    install_gum
    if [[ ! -t 0 ]]; then
        err "The 5gpn menu is interactive. Run a subcommand directly, e.g.:"
        echo "  5gpn --status | 5gpn restart | 5gpn change-domain <fqdn> | 5gpn --uninstall" >&2
        exit 1
    fi
    local labels=(
        "状态 Status"
        "重启服务 Restart services"
        "修改主域名 Change base domain"
        "修改公网IP Change public IP"
        "修改网关IP Change gateway IP"
        "修改回源解析器 Change SNI resolver"
        "更新规则列表 Update rule lists"
        "添加面板白名单IP Add panel allowlist IP"
        "移除面板白名单IP Remove panel allowlist IP"
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
            "修改主域名 Change base domain")        change_base_domain ;;
            "修改公网IP Change public IP")          change_public_ip ;;
            "修改网关IP Change gateway IP")         change_gateway ;;
            "修改回源解析器 Change SNI resolver")    change_resolver ;;
            "更新规则列表 Update rule lists")        do_update_lists ;;
            "添加面板白名单IP Add panel allowlist IP")    add_allow_ip ;;
            "移除面板白名单IP Remove panel allowlist IP") del_allow_ip ;;
            "重新生成 iOS 描述文件 Regenerate iOS profile") regen_ios ;;
            "轮换控制台令牌 Rotate console token")   rotate_token ;;
            "设置 Cloudflare Token Set Cloudflare token") set_cf_token ;;
            "重置 mihomo 配置 Reset mihomo config")
                if ask_yesno "确认备份并重置 operator-owned mihomo config?"; then reset_mihomo_config; fi ;;
            "配置 Telegram Bot")                    setup_tgbot ;;
            "卸载 Uninstall")
                if [[ "$_HAVE_GUM" == 1 ]]; then
                    gum confirm "确认卸载 5gpn? (保留 /etc/5gpn 配置; --purge 才删除)" && { uninstall; break; }
                else
                    local c=""; read -r -p "确认卸载 5gpn? [y/N] " c || true
                    [[ "$c" == [yY]* ]] && { uninstall; break; }
                fi
                ;;
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
    # ONE operator domain knob: the base (apex) domain. The four service
    # domains are auto-derived subdomains (derive_domains), all covered by the
    # single *.<base> wildcard cert:
    #   console.<base> -> the web console (also exported as WEB_DOMAIN)
    #   zash.<base>    -> the zashboard panel
    #   profile.<base> -> public iOS bootstrap SNI (/ios/ only)
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
        err "No base domain. Set BASE_DOMAIN=example.com (or WEB_DOMAIN=example.com) for a non-interactive install (or DEBUG=1 for a self-signed test cert)."; exit 1
    else
        local input=""
        while true; do
            input="$(ask_text '请输入主域名 base domain (如 example.com; 使用 console./zash./profile./dot. 子域):' || true)"
            input="${input#http://}"; input="${input#https://}"; input="${input%/}"; input="${input// /}"
            is_valid_domain "$input" && { base="$input"; break; }
            warn "Invalid domain; enter a full FQDN like example.com."
        done
    fi

    derive_domains "$base"
    info "Base domain: $BASE_DOMAIN  ($CONSOLE_DOMAIN / $ZASH_DOMAIN / $PROFILE_DOMAIN / $DOT_DOMAIN)"
    info "Bootstrap requirement: create ${PROFILE_DOMAIN} A -> ${PUBLIC_IP} (or client-routable ${GATEWAY_IP} in NPN) before completion."
}

resolve_gateway_ip() {
    # GATEWAY_IP = the client-facing address 5gpn-dns returns for CHINA-resolved
    # names so mihomo (sniff-forward data plane) intercepts + forwards them. Precedence:
    #   env override > dns.env (DNS_GATEWAY_IP) > interactive prompt (default =
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
    # queries (persisted as DNS_CHINA_ECS). Precedence: env override > dns.env
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

# install_cert <base_domain> — provision ONE mandatory WILDCARD lineage
# (*.<base> + <base>) and deploy it to all three role directories:
#   dot  -> ${DOT_CERT_DIR}  (serves DoT :853; also signs the iOS profile)
#   web  -> ${WEB_CERT_DIR}  (serves the web console behind the mihomo SNI split)
#   zash -> ${ZASH_CERT_DIR} (serves the zashboard panel)
# Two modes (resolved in full_install: env > dns.env CERT_MODE > cloudflare):
#   cloudflare (default) — Let's Encrypt DNS-01 through the Cloudflare API
#                       (certbot-dns-cloudflare; no :80, no public A-record
#                       needed for these subdomains); auto-renews unattended
#                       via the daily certbot timer (see install_renewal_automation).
#                       Reuse (a still-valid lineage, or a still-valid preserved
#                       role-dir copy when the lineage is gone) never needs the
#                       token; only an actual ISSUANCE does. Set it via
#                       '5gpn --set-cf-token' (or the manage menu), or manually:
#                       a scoped Cloudflare API token in
#                       /etc/5gpn/acme/cloudflare.ini (0600):
#                         install -d -m 0700 /etc/5gpn/acme
#                         echo 'dns_cloudflare_api_token = <token>' \
#                           > /etc/5gpn/acme/cloudflare.ini
#                         chmod 600 /etc/5gpn/acme/cloudflare.ini
#   debug              — a self-signed WILDCARD cert for test/dev boxes with no
#                       public domain. No certbot, no DNS-01, no renewal.
#                       iOS/browsers will flag it untrusted; that is the point
#                       of "debug".
install_cert() {
    local base="${1:?install_cert needs a base domain}"
    local mode="${CERT_MODE:-cloudflare}"
    local live="/etc/letsencrypt/live/${base}"

    if [ "$mode" = "debug" ] || [ "${DEBUG:-0}" = "1" ]; then
        local debug_src="${DEBUG_CERT_DIR}/${base}"
        issue_selfsigned_wildcard "$base" || return 1
        deploy_cert_roles "$base" "$debug_src"
        return 0
    fi

    # ── cloudflare (DNS-01), wildcard, auto-renew ───────────────────────────
    # Reuse is checked FIRST, in two forms, and — deliberately — neither reuse
    # path requires the Cloudflare API token: pure reuse never calls certbot.
    if [ -s "${live}/fullchain.pem" ] \
       && openssl x509 -checkend "$((30*86400))" -noout -in "${live}/fullchain.pem" >/dev/null 2>&1; then
        # 1) A still-valid (>30d) certbot lineage for this base domain.
        info "Valid wildcard cert for *.${base} in the certbot lineage (>30d); reusing (no issuance)."
    elif [ ! -s "${live}/fullchain.pem" ] \
         && [ -s "${DOT_CERT_DIR}/fullchain.pem" ] && [ -s "${DOT_CERT_DIR}/privkey.pem" ] \
         && openssl x509 -checkend "$((7*86400))" -noout -in "${DOT_CERT_DIR}/fullchain.pem" >/dev/null 2>&1 \
         && openssl x509 -noout -text -in "${DOT_CERT_DIR}/fullchain.pem" 2>/dev/null | grep -q "DNS:\*\.${base}\b"; then
        # 2) No certbot lineage (e.g. /etc/letsencrypt was cleared, or --purge
        # ran on a box whose /etc/letsencrypt lives elsewhere), but the
        # deployed copy preserved under /etc/5gpn/cert survived and is still
        # valid (>7d) AND covers *.${base} — reuse it in place (redeployed
        # from here to all three role dirs) instead of forcing a fresh LE
        # issuance. Trade-off: without the lineage this cert cannot
        # auto-renew; re-run once the lineage is restored to re-establish
        # renewal before it expires.
        warn "No certbot lineage for *.${base}; reusing the still-valid preserved wildcard in ${DOT_CERT_DIR}/ (no issuance, no Cloudflare token needed). Auto-renew is NOT set up until the lineage is restored."
        deploy_cert_roles "$base" "$DOT_CERT_DIR"
        return 0
    else
        # Neither reuse path applies — an actual certbot issuance is required,
        # and THIS is the only branch that needs the Cloudflare API token.
        install -d -m 0700 "$ACME_DIR"
        [ -s "${ACME_DIR}/cloudflare.ini" ] \
            || { err "missing ${ACME_DIR}/cloudflare.ini — set it via '5gpn --set-cf-token' (or the manage menu), or create it manually: install -d -m 0700 ${ACME_DIR} && echo 'dns_cloudflare_api_token = <token>' > ${ACME_DIR}/cloudflare.ini && chmod 600 ${ACME_DIR}/cloudflare.ini"; return 1; }
        chmod 600 "${ACME_DIR}/cloudflare.ini"

        info "Issuing Let's Encrypt WILDCARD cert for *.${base} (cloudflare DNS-01)..."
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials "${ACME_DIR}/cloudflare.ini" \
            -d "*.${base}" -d "${base}" --agree-tos -n -m "${CERT_EMAIL:-admin@${base}}" \
            --keep-until-expiring --dns-cloudflare-propagation-seconds 30 \
            || { err "certbot DNS-01 failed for *.${base} (check the Cloudflare token's Zone:DNS:Edit scope + zone match)."; return 1; }
    fi

    deploy_cert_roles "$base"

    # Renewal deploy hook (copies the renewed wildcard to all three role dirs +
    # reloads 5gpn-dns via SIGHUP + re-signs the iOS profile). Ships in repo.
    if [[ -f "${SCRIPT_DIR}/scripts/renew-hook.sh" ]]; then
        install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
        install -m 0755 "${SCRIPT_DIR}/scripts/renew-hook.sh" \
            /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh
        ok "Renewal deploy hook installed (copies cert to dot/web/zash + reload + iOS re-sign)."
    else
        warn "scripts/renew-hook.sh not found; auto-renew reload hook skipped."
    fi

    install_renewal_automation
}

# issue_selfsigned_wildcard <base> — CERT_MODE=debug: a long-lived (825d)
# self-signed WILDCARD cert (CN=<base>, SAN=<base>+*.<base>+gateway/public IPs)
# so every role's cert works by IP or name on an internal test box. Debug
# material lives under /etc/5gpn/debug-cert only: writing through Certbot's
# /etc/letsencrypt/live symlinks can truncate the real archive certificates.
# No renewal machinery — and any cloudflare-mode automation a prior install
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
    # Dismantle any cloudflare-mode renewal machinery a prior install left.
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh 2>/dev/null || true
    if [[ -f /etc/systemd/system/5gpn-certbot-renew.timer ]]; then
        systemctl disable --now 5gpn-certbot-renew.timer 2>/dev/null || true
        rm -f /etc/systemd/system/5gpn-certbot-renew.timer \
              /etc/systemd/system/5gpn-certbot-renew.service
        systemctl daemon-reload 2>/dev/null || true
    fi
}

# deploy_cert_roles <base> — copy the wildcard lineage to all three role dirs.
# deploy_cert_roles <base> [src_dir] — copy the wildcard cert to all three role
# dirs. Defaults to reading from the certbot lineage (/etc/letsencrypt/live/<base>);
# a caller can pass an alternate src_dir (e.g. a still-valid preserved role-dir
# copy, when the lineage itself is gone — see install_cert's reuse fallback).
# When src_dir IS one of the role dirs (the dot-preserved-copy case), that one
# role is a same-file copy (which `install` refuses) — just re-chmod it in place.
deploy_cert_roles() {
    local base="$1" src="${2:-/etc/letsencrypt/live/${base}}" r dest
    for r in dot web zash; do
        dest="/etc/5gpn/cert/$r"
        install -d -m 0750 "$dest"
        if [ "$src" = "$dest" ]; then
            chmod 0640 "${dest}/fullchain.pem" "${dest}/privkey.pem" 2>/dev/null || true
            continue
        fi
        install -m 0640 "${src}/fullchain.pem" "${dest}/fullchain.pem"
        install -m 0640 "${src}/privkey.pem"   "${dest}/privkey.pem"
    done
    ok "Wildcard cert for *.${base} deployed to dot/web/zash role dirs."
}

# install_renewal_automation installs a daily systemd timer running
# `certbot renew`. With --dns-cloudflare the renewal is fully unattended (the
# API sets the transient _acme-challenge TXT, no :80, no human step, no xray
# coordination) — so, unlike the old http-01 flow, there are no pre/post
# renewal-hooks to stop/start anything around port 80.
install_renewal_automation() {
    # Don't double up if the distro/snap already ships an enabled renewal timer.
    if systemctl is-enabled certbot.timer >/dev/null 2>&1 \
       || systemctl is-enabled snap.certbot.renew.timer >/dev/null 2>&1; then
        info "Existing certbot timer detected; relying on it."
        return 0
    fi
    cat > /etc/systemd/system/5gpn-certbot-renew.service <<'EOF'
[Unit]
Description=5gpn certbot renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'certbot renew --quiet'
EOF
    cat > /etc/systemd/system/5gpn-certbot-renew.timer <<'EOF'
[Unit]
Description=5gpn daily certbot renewal check

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now 5gpn-certbot-renew.timer 2>/dev/null || true
    ok "Installed 5gpn-certbot-renew.timer (daily, Persistent, unattended DNS-01 renewal)."
}

# set_cf_token prompts for (or accepts as $1) the Cloudflare API token used by
# install_cert's cloudflare/DNS-01 issuance path, and writes it to
# ${ACME_DIR}/cloudflare.ini (0600, root-only). This is the ONLY TUI/CLI op that
# writes that file — previously it had to be placed there by hand. Reuse-only
# installs (a still-valid lineage or preserved cert copy) never need this; it's
# only required the first time an actual certbot issuance happens for a domain.
set_cf_token() {
    check_root
    local tok="${1:-}"
    [[ -z "$tok" && -t 0 ]] && tok="$(ask_secret 'Cloudflare API token (scope: Zone:DNS:Edit for your base zone)' || true)"
    [ -z "$tok" ] && { warn "no token entered — unchanged."; return 0; }
    install -d -m 0700 "$ACME_DIR"
    printf 'dns_cloudflare_api_token = %s\n' "$tok" > "${ACME_DIR}/cloudflare.ini"
    chmod 600 "${ACME_DIR}/cloudflare.ini"
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
        # Require several generated-only meter/rule fingerprints together
        # before deleting that table; any ordinary table merely named filter
        # is preserved.
        dump="$(nft list table inet filter 2>/dev/null || true)"
        if [[ -n "$dump" ]] \
           && grep -q 'dot_rate4' <<<"$dump" \
           && grep -q 'dot_rate6' <<<"$dump" \
           && grep -q 'doh_rate4' <<<"$dump" \
           && grep -q 'doh_rate6' <<<"$dump" \
           && grep -Eq 'tcp dport (9443|8111)' <<<"$dump"; then
            nft delete table inet filter \
                && { warn "Removed strongly fingerprinted legacy 5gpn table inet filter."; deleted=1; } \
                || warn "Could not remove the fingerprinted legacy 5gpn table inet filter."
        fi
    fi
    if grep -qE 'dot_rate4|doh_rate4|dns53_agg|5gpn firewall' /etc/nftables.conf 2>/dev/null; then
        warn "Legacy 5gpn rules remain in /etc/nftables.conf; safety policy left that host-owned file unchanged. Remove only the old 5gpn table block before reboot."
    elif [[ "$deleted" == 1 ]]; then
        info "No legacy 5gpn persistence fingerprint found in /etc/nftables.conf."
    fi
    rm -f "${SCRIPTS_DIR}/setup-firewall.sh" 2>/dev/null || true
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
        install -m 0644 "$src" "/etc/systemd/system/${u}"
    done
    systemctl daemon-reload
    ok "5gpn-dns.service + mihomo.service installed."
}

write_dns_env() {
    # Write /etc/5gpn/dns.env from install-time collected vars.
    # cert paths always point at the /etc/5gpn/cert copies (maintained by renew-hook.sh).
    mkdir -p "$CONF_DIR"

    # DNS_API_TOKEN: reuse an existing token across re-installs (never rotate a
    # working token); else honor an env override; else generate one.
    # Read current values from the single config file (dns.env). Secrets + tuning
    # knobs are preserved across a re-install; env overrides win.
	local existing_token existing_tgtoken existing_tgadmins existing_china existing_trust
    existing_token="$(cfg_get DNS_API_TOKEN)"
    existing_tgtoken="$(cfg_get TGBOT_TOKEN)"
    existing_tgadmins="$(cfg_get TGBOT_ADMINS)"
    existing_china="$(cfg_get DNS_CHINA)"
    existing_trust="$(cfg_get DNS_TRUST)"
	DNS_API_TOKEN="${DNS_API_TOKEN:-${existing_token:-$(openssl rand -hex 32)}}"
    local tg_token="${TGBOT_TOKEN:-$existing_tgtoken}"
    local tg_admins="${TGBOT_ADMINS:-$existing_tgadmins}"
    # DNS_TRUST default is the 22.22.22.22 sentinel (same convention as
    # XRAY_RESOLVER): a bare IP is queried over plain UDP; "host@IP" entries
    # use DoT. Operators change it post-install via the web console
    # (Settings → upstream DNS), which persists to /etc/5gpn/upstreams.json.
    local dns_china="${DNS_CHINA:-${existing_china:-223.5.5.5,119.29.29.29}}"
    local dns_trust="${DNS_TRUST:-${existing_trust:-22.22.22.22}}"

    # Mihomo migration: console/zash/base domains obtained from derive_domains,
    # the SINGLE derivation from the operator's base (apex) domain
    # (console.<base> / zash.<base>), also used by render_mihomo_config and the
    # *.<base> wildcard install_cert issues, so dns.env and the rendered
    # config.yaml agree instead of drifting. A legacy box with no BASE_DOMAIN
    # recovers the apex from the (possibly console.<base>) web domain; an
    # empty base falls back to derive_domains' own "5gpn.local" placeholder.
    local base_domain="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    [[ -z "$base_domain" ]] && base_domain="${WEB_DOMAIN#console.}"
    derive_domains "$base_domain"
    # Mihomo's loopback external-controller API + the panel source-IP
    # allowlist file it reloads from (add_allow_ip/del_allow_ip/apply_whitelist
    # already hardcode these same two values; persisting them here lets the
    # daemon read back what it's actually being served against).
    local dns_mihomo_controller="${DNS_MIHOMO_CONTROLLER:-$(cfg_get DNS_MIHOMO_CONTROLLER)}"; dns_mihomo_controller="${dns_mihomo_controller:-127.0.0.1:9090}"
    local dns_mihomo_secret="${DNS_MIHOMO_SECRET:-$(cfg_get DNS_MIHOMO_SECRET)}"
    local dns_whitelist_file="${DNS_WHITELIST_FILE:-$(cfg_get DNS_WHITELIST_FILE)}"; dns_whitelist_file="${dns_whitelist_file:-${MIHOMO_DIR}/whitelist.txt}"
    # SP-3 zashboard panel: dir + listen address for the second loopback HTTPS
    # panel (Task A1). DNS_ZASH_DIR is already resolved (env > dns.env > default)
    # up at cfg_get's definition — the global is authoritative here, so the value
    # written back matches what install_zashboard/clean/uninstall actually used.
    # DNS_ZASH_LISTEN resolves here (its only consumer). The cert paths below are
    # NOT preserved — they always point at the deploy_cert_roles zash/ copy, like
    # DNS_CERT/DNS_WEB_CERT.
    local dns_zash_dir="$DNS_ZASH_DIR"
    local dns_zash_listen="${DNS_ZASH_LISTEN:-$(cfg_get DNS_ZASH_LISTEN)}"; dns_zash_listen="${dns_zash_listen:-127.0.0.2:443}"

    # Tuning knobs: env > current dns.env value > default (single-source, so a
    # hand-edited value survives an idempotent re-run).
    local max_inflight="${DNS_MAX_INFLIGHT:-$(cfg_get DNS_MAX_INFLIGHT)}"; max_inflight="${max_inflight:-4096}"
    local ttl_min="${DNS_TTL_MIN:-$(cfg_get DNS_TTL_MIN)}";               ttl_min="${ttl_min:-300}"
    local ttl_max="${DNS_TTL_MAX:-$(cfg_get DNS_TTL_MAX)}";               ttl_max="${ttl_max:-86400}"
    local query_timeout="${DNS_QUERY_TIMEOUT:-$(cfg_get DNS_QUERY_TIMEOUT)}"; query_timeout="${query_timeout:-5s}"
    # China ECS: full_install resolves it via resolve_china_ecs (prompt + /24
    # normalisation); this fallback covers any other write_dns_env caller.
    local china_ecs="${CHINA_ECS:-$(cfg_get DNS_CHINA_ECS)}"; china_ecs="${china_ecs:-$(ecs_to_cidr24 "$CHINA_ECS_DEFAULT")}"

    local dns_env_tmp; dns_env_tmp="$(mktemp)"
    cat > "$dns_env_tmp" <<EOF
# 5gpn-dns config — the SINGLE source of truth (written by install.sh).
# 'systemctl reload 5gpn-dns' (SIGHUP) reloads ONLY the rule files under
# /etc/5gpn/rules/ + chnroute, NOT this file — a daemon knob here needs
# 'systemctl restart 5gpn-dns' (read once at startup). Re-run install.sh for
# cert knobs. There are no separate .state files.

# DoT is the ONLY client-facing DNS transport (DoH/plain-:53 removed 2026-07-10).
DNS_LISTEN_DOT=:853
DNS_LISTEN_DEBUG=127.0.0.1:5353

# TLS certs — ONE mandatory WILDCARD lineage (*.<DNS_BASE_DOMAIN> + base),
# deployed to THREE role dirs:
#   dot/  serves DoT :853 (also signs the iOS profile)
#   web/  serves the web console (loopback :443, behind the mihomo SNI split)
#   zash/ serves the zashboard panel
# All hot-reload on file-mtime change; renew-hook.sh redeploys on renewal.
DNS_CERT=${DOT_CERT_DIR}/fullchain.pem
DNS_KEY=${DOT_CERT_DIR}/privkey.pem
DNS_WEB_CERT=${WEB_CERT_DIR}/fullchain.pem
DNS_WEB_KEY=${WEB_CERT_DIR}/privkey.pem

# ── Deployment identity + cert (read by install.sh/renew-hook.sh; also read by
# the in-process Telegram bot). DNS_BASE_DOMAIN = the operator's ONE apex domain
# (the wildcard cert's base); the three service domains are auto-derived
# subdomains of it, all covered by the one *.<base> lineage:
#   DNS_DOMAIN         = dot.<base>      (DoT :853)
#   DNS_WEB_DOMAIN     = console.<base>  (web console; == DNS_CONSOLE_DOMAIN)
#   DNS_CONSOLE_DOMAIN = console.<base>  (mihomo SNI-split to loopback :443)
#   DNS_ZASH_DOMAIN    = zash.<base>     (zashboard panel)
#   DNS_PROFILE_DOMAIN = profile.<base>  (public, /ios/ only; no console access)
# ──
DNS_DOMAIN=${DOT_DOMAIN}
DNS_WEB_DOMAIN=${WEB_DOMAIN}
DNS_BASE_DOMAIN=${BASE_DOMAIN}
DNS_CONSOLE_DOMAIN=${CONSOLE_DOMAIN}
DNS_ZASH_DOMAIN=${ZASH_DOMAIN}
DNS_PROFILE_DOMAIN=${PROFILE_DOMAIN}
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
DNS_EGRESS_RESOLVER=${XRAY_RESOLVER:-$DNS_EGRESS_RESOLVER_DEFAULT}
XRAY_RESOLVER=${XRAY_RESOLVER:-$DNS_EGRESS_RESOLVER_DEFAULT}
DNS_EGRESS_BROKER=127.0.0.1:5354

# Phase 2: remote rule-list subscriptions (fetched in-process; caches written to
# DNS_RULES_DIR/<category>/<name>.txt, merged automatically with the manual
# <category>.txt files above). See /etc/5gpn/subscriptions.json.
DNS_SUBSCRIPTIONS=${CONF_DIR}/subscriptions.json

# Control-plane HTTPS API + web console (bearer-token auth). Browsers reach it
# at https://DNS_WEB_DOMAIN via the mihomo :443 SNI split, which forwards
# straight to this loopback listener (no PROXY protocol -- source-IP gating now
# happens in mihomo's whitelist.txt rule-provider, before the connection ever
# reaches this listener). The token is generated once and preserved across
# re-installs so a working token is never rotated out from under an operator
# config.
#
# Binds LOOPBACK :443 directly: the ONLY intended path is the mihomo SNI split,
# so there is no reason to expose this publicly -- doing so would put the
# bearer token (and any future auth bug) on the open internet with no network
# ACL in front of it. Set DNS_LISTEN_API=:443 to opt back into a public
# listener if you deliberately need direct access.
DNS_LISTEN_API=127.0.0.1:443
DNS_API_TOKEN=${DNS_API_TOKEN}

# Mihomo's loopback external-controller API (DNS_MIHOMO_CONTROLLER) + its
# bearer secret (DNS_MIHOMO_SECRET) + the panel source-IP allowlist file
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
# always point at the wildcard's zash/ role-dir copy (deploy_cert_roles); the
# daemon's own config.go fallback (zash -> web -> dot cert) covers a
# debug/self-signed single-cert box where that role dir is never populated.
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

DNS_CACHE_SIZE=${CACHE_SIZE:-4096}
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
    local removed_keys="DNS_LISTEN_DOH= DNS_LISTEN_PLAIN= DNS_CLIENT_NET= DNS_PUBLIC_INGRESS= SETUP_FIREWALL= DOT_RATE= DOT_BURST= DNS53_AGG_RATE= DNS_IOS_LISTEN= DNS_AUTH_FAIL_LIMIT= DNS_AUTH_FAIL_WINDOW= DNS_AUTH_BLOCK= DNS_EGRESS_MODEL= DNS_EGRESS_NODES="
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
    mv "$dns_env_tmp" "${CONF_DIR}/dns.env"
    chmod 640 "${CONF_DIR}/dns.env"
    ok "Written ${CONF_DIR}/dns.env (operator-set extra knobs preserved; removed-feature knobs dropped)."
}

setup_ios_profile() {
    info "Generating iOS DoT profile..."
    mkdir -p "$WWW_DIR"
    local gw="${GATEWAY_IP:-$PUBLIC_IP}"
    local gen_ok=0
    if [[ -x "${SCRIPTS_DIR}/gen-ios-profile.sh" ]]; then
        # The profile configures (and is signed with) the DoT domain's cert.
        if CERT_DIR="$DOT_CERT_DIR" bash "${SCRIPTS_DIR}/gen-ios-profile.sh" "$DOT_DOMAIN" "$gw" "$WWW_DIR"; then
            gen_ok=1
        else
            warn "gen-ios-profile.sh failed (e.g. unsigned profile refused; set ALLOW_UNSIGNED_PROFILE=1 to override) — no profile served."
        fi
    else
        warn "scripts/gen-ios-profile.sh not present yet; skipping profile generation."
    fi

    # The .mobileconfig is served by the 5gpn-dns daemon at the web console's
    # public /ios/ path (the standalone :8111 responder was removed). Clean up
    # any socket-activated unit a prior install left.
    if systemctl list-unit-files 2>/dev/null | grep -q '^5gpn-iosprofile\.'; then
        systemctl disable --now '5gpn-iosprofile.socket' 2>/dev/null || true
        rm -f /etc/systemd/system/5gpn-iosprofile.socket \
              /etc/systemd/system/'5gpn-iosprofile@.service'
        systemctl daemon-reload 2>/dev/null || true
        info "Removed obsolete socket-activated iOS responder (daemon serves /ios/ now)."
    fi
    # Fail-closed propagation: gen-ios-profile.sh refuses to serve an unsigned
    # profile (exit non-zero); do NOT print a success checkmark then — return
    # non-zero so --ios exits non-zero and full_install can tolerate it explicitly.
    if [[ "$gen_ok" != "1" ]]; then
        return 1
    fi
    ok "iOS profile generated (served at https://${PROFILE_DOMAIN:-<profile-domain>}/ios/)."
}

print_qr() {
    local profile="${PROFILE_DOMAIN:-$(cfg_get DNS_PROFILE_DOMAIN)}"
    [[ -n "$profile" ]] || return 0
    local url="https://${profile}/ios/ios-dot.mobileconfig"
    if command -v qrencode >/dev/null 2>&1; then
        echo ""; info "Scan to install the iOS profile:"
        qrencode -t ANSIUTF8 "$url" || true
    fi
}

# The profile host is the only bootstrap endpoint reachable before a client has
# installed DoT. Fail closed unless its A record already reaches this box. The
# explicit bypass is for CI or a deliberately staged deployment only; it is
# never selected automatically.
verify_profile_dns() {
    if [[ "${SKIP_PROFILE_DNS_CHECK:-0}" == 1 ]]; then
        warn "SKIP_PROFILE_DNS_CHECK=1: profile bootstrap DNS verification skipped explicitly."
        return 0
    fi
    local profile="${PROFILE_DOMAIN:-$(cfg_get DNS_PROFILE_DOMAIN)}" answers="" ip
    [[ -n "$profile" ]] \
        || { err "DNS_PROFILE_DOMAIN is empty; cannot verify the iOS bootstrap endpoint."; return 1; }
    if command -v dig >/dev/null 2>&1; then
        answers="$(dig +time=3 +tries=1 +short A "$profile" 2>/dev/null || true)"
    elif command -v getent >/dev/null 2>&1; then
        answers="$(getent ahostsv4 "$profile" 2>/dev/null | awk '{print $1}' || true)"
    else
        err "Neither dig nor getent is available to verify ${profile}."
        return 1
    fi
    while IFS= read -r ip; do
        [[ "$ip" == "${PUBLIC_IP:-}" || "$ip" == "${GATEWAY_IP:-}" ]] || continue
        ok "Profile bootstrap DNS verified: ${profile} A ${ip}."
        return 0
    done <<<"$answers"
    err "Profile bootstrap is not reachable: ${profile} A records [${answers//$'\n'/, }] do not include PUBLIC_IP=${PUBLIC_IP:-unset} or GATEWAY_IP=${GATEWAY_IP:-unset}."
    err "Create 'profile.${BASE_DOMAIN:-<base>} A -> ${PUBLIC_IP:-<PUBLIC_IP>}' (or a client-routable ${GATEWAY_IP:-<GATEWAY_IP>} in NPN), wait for DNS propagation, then re-run."
    err "Only staged/CI installs may bypass this gate explicitly with SKIP_PROFILE_DNS_CHECK=1."
    return 1
}

verify_profile_endpoint() {
    [[ -s "${WWW_DIR}/ios-dot.mobileconfig" ]] \
        || { warn "iOS profile file is absent; endpoint content probe skipped (profile generation already reported fail-closed)."; return 0; }
    local profile="${PROFILE_DOMAIN:-$(cfg_get DNS_PROFILE_DOMAIN)}"
    local bind_ip="${MIHOMO_LISTEN_IPS%%,*}" tmp headers code denied
    [[ -n "$profile" && -n "$bind_ip" ]] \
        || { err "Cannot probe profile SNI: profile domain or mihomo bind address is empty."; return 1; }
    tmp="$(mktemp -d /tmp/5gpn-profile-probe.XXXXXX)" || return 1
    code="$(curl --silent --show-error --insecure --max-time 5 \
        --resolve "${profile}:443:${bind_ip}" -D "$tmp/headers" -o "$tmp/body" \
        -w '%{http_code}' "https://${profile}/ios/ios-dot.mobileconfig" 2>/dev/null || true)"
    if [[ "$code" != 200 ]] \
       || ! grep -qi '^Content-Type:[[:space:]]*application/x-apple-aspen-config' "$tmp/headers"; then
        rm -rf -- "$tmp"
        err "Profile SNI probe failed (HTTP ${code:-none}); operator mihomo config may lack the ${profile} host/rule. Update it or run '5gpn mihomo-reset'."
        return 1
    fi
    denied="$(curl --silent --insecure --max-time 5 --resolve "${profile}:443:${bind_ip}" \
        -o /dev/null -w '%{http_code}' "https://${profile}/api/status" 2>/dev/null || true)"
    rm -rf -- "$tmp"
    [[ "$denied" == 404 ]] \
        || { err "Profile SNI isolation failed: /api/status returned HTTP ${denied:-none}, want 404."; return 1; }
    ok "Profile SNI verified: mobileconfig is reachable and console/API paths are isolated."
}

# ----------------------------------------------------------------------------
# System tuning (lean: BBR + conntrack + ip_forward, profile-scaled)
# ----------------------------------------------------------------------------
system_tuning() {
    info "Applying sysctl tuning..."
    modprobe nf_conntrack >/dev/null 2>&1 || true
    mkdir -p /etc/modules-load.d; echo nf_conntrack > /etc/modules-load.d/5gpn.conf
    local ct sm hs rmax
    if [[ "${LOWMEM:-0}" == "1" ]]; then ct=131072; sm=60; hs=32768; rmax=4194304; else ct=1048576; sm=10; hs=262144; rmax=16777216; fi
    # conntrack hash table sized alongside the table max (~max/4) so a full table
    # doesn't degrade to long hash-chain lookups. Set via the module param — the
    # nf_conntrack_buckets sysctl is read-only on many kernels.
    mkdir -p /etc/modprobe.d
    echo "options nf_conntrack hashsize=${hs}" > /etc/modprobe.d/5gpn.conf
    cat > /etc/sysctl.d/99-5gpn.conf <<EOF
# 5gpn ($([[ "${LOWMEM:-0}" == "1" ]] && echo low-memory || echo standard))
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.netfilter.nf_conntrack_max=${ct}
# Wider ephemeral range for the many concurrent outbound upstream dials (UDP
# china + fresh-conn DoT trust per cache miss) plus mihomo forwarder flows.
net.ipv4.ip_local_port_range=10240 65535
# UDP socket buffers sized for the public :53 + proxied QUIC(:443) forwarding
# volume (jointly with nf_conntrack_max above).
net.core.rmem_max=${rmax}
net.core.wmem_max=${rmax}
vm.swappiness=${sm}
EOF
    sysctl --system >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# Service lifecycle
# ----------------------------------------------------------------------------
probe_mihomo_ready() {
    systemctl is-active --quiet mihomo || return 1
    local controller secret ip port
    controller="${DNS_MIHOMO_CONTROLLER:-$(cfg_get DNS_MIHOMO_CONTROLLER)}"
    controller="${controller:-127.0.0.1:9090}"
    controller="${controller#http://}"; controller="${controller#https://}"
    secret="${DNS_MIHOMO_SECRET:-$(cfg_get DNS_MIHOMO_SECRET)}"
    local -a curl_args=(--fail --silent --show-error --max-time 2 -o /dev/null)
    [[ -n "$secret" ]] && curl_args+=(-H "Authorization: Bearer $secret")
    curl "${curl_args[@]}" "http://${controller}/version" >/dev/null 2>&1 || return 1

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
# Optional control plane: Telegram bot (now an in-process goroutine of 5gpn-dns,
# configured via TGBOT_TOKEN / TGBOT_ADMINS in /etc/5gpn/dns.env)
# ----------------------------------------------------------------------------
# Set (or replace) a KEY=VALUE line in a dotenv file, preserving all other keys.
# Appends the key if absent. Used to write TGBOT_* into dns.env without clobbering
# DNS_API_TOKEN / DNS_* etc. (mirrors how write_dns_env preserves the token).
set_dns_env_kv() {
    local f="$1" key="$2" val="$3" tmp
    mkdir -p "$(dirname "$f")"; touch "$f"
    tmp="$(mktemp "${f}.XXXXXX")"
    # Drop any existing (commented or live) definition of this key, then append the new one.
    grep -vE "^#?[[:space:]]*${key}=" "$f" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
    chmod 640 "$f"
}

setup_tgbot() {
    check_root
    install_gum
    local envf="${CONF_DIR}/dns.env"
    [[ -f "$envf" ]] || { err "${envf} not found (run a full install first)."; return 1; }

    # Clean up the old python bot unit if a previous install left it behind
    # (the bot is an in-process goroutine of 5gpn-dns now).
    systemctl disable --now 5gpn-tgbot 2>/dev/null || true
    rm -f /etc/systemd/system/5gpn-tgbot.service
    systemctl daemon-reload 2>/dev/null || true

    # Token/admins: env override, else an existing dns.env value, else prompt.
    local token admins existing_token existing_admins
    existing_token="$(grep -E '^TGBOT_TOKEN=' "$envf" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    existing_admins="$(grep -E '^TGBOT_ADMINS=' "$envf" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    token="${TGBOT_TOKEN:-$existing_token}"
    if [[ -z "$token" && -t 0 ]]; then token="$(ask_secret 'Telegram Bot Token (blank to skip):' || true)"; fi
    [[ -z "$token" ]] && { info "No Telegram token; skipping tgbot. Re-run later: $0 --setup-tgbot"; return 0; }
    admins="${TGBOT_ADMINS:-$existing_admins}"
    if [[ -z "$admins" && -t 0 ]]; then admins="$(ask_text 'Authorized Telegram numeric IDs (comma-separated, optional):' || true)"; fi
    admins="$(printf '%s' "$admins" | tr ', ' '\n\n' | grep -E '^[0-9]+$' | paste -sd ',' - 2>/dev/null || true)"

    # Persist into dns.env (the daemon reads TGBOT_TOKEN/TGBOT_ADMINS from its env).
    set_dns_env_kv "$envf" TGBOT_TOKEN  "$token"
    set_dns_env_kv "$envf" TGBOT_ADMINS "$admins"

    systemctl restart 5gpn-dns 2>/dev/null || warn "could not restart 5gpn-dns (check: journalctl -u 5gpn-dns)."
    if [[ -t 0 && "$_HAVE_GUM" == 1 ]]; then
        gum style --border rounded --padding "0 1" \
          "未知自己的 Telegram ID?" \
          "1) 给你的 bot 发 /id" \
          "2) 把回显的数字 ID 填入 ${envf} 的 TGBOT_ADMINS=" \
          "3) systemctl restart 5gpn-dns"
    fi
    ok "bot 已随 5gpn-dns 启用。"
    info "Token stored in ${envf} (chmod 640)."
    [[ -z "$admins" ]] && warn "No admin IDs set yet; message the bot, then set TGBOT_ADMINS= in ${envf} and: systemctl restart 5gpn-dns"
}

# rotate_token generates a fresh DNS_API_TOKEN, writes it into dns.env, and
# restarts 5gpn-dns so the new token takes effect (the control server reads the
# token at startup, so a SIGHUP reload is NOT enough — a restart is required).
# The old token stops working immediately; browsers must re-login with the new
# one. Mitigates the "token never rotates" exposure of the localStorage-held
# bearer credential.
rotate_token() {
    check_root
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
    PROFILE_DOMAIN="${PROFILE_DOMAIN:-$(cfg_get DNS_PROFILE_DOMAIN)}"
    BASE_DOMAIN="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    PUBLIC_IP="$(cfg_get DNS_PUBLIC_IP)"
    GATEWAY_IP="${GATEWAY_IP:-$(cfg_get DNS_GATEWAY_IP)}"
    [[ -n "$DOT_DOMAIN" && -n "$PUBLIC_IP" ]] || { err "Domain/public IP unknown; run a full install first."; exit 1; }
    if ! setup_ios_profile; then
        err "iOS profile not generated (fail-closed on unsigned profile). Fix signing or set ALLOW_UNSIGNED_PROFILE=1."
        exit 1
    fi
    # No service restart needed: 5gpn-dns serves the profile from WWW_DIR on each request.
    verify_profile_dns
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    verify_profile_endpoint
    print_qr
    ok "iOS profile regenerated: https://${PROFILE_DOMAIN:-<profile-domain>}/ios/ios-dot.mobileconfig"
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

# ----------------------------------------------------------------------------
# Full install
# ----------------------------------------------------------------------------
full_install() {
    check_root
    install_gum
    detect_os
    check_arch
    detect_memory_profile
    ensure_swap
    # ── Resolve every persisted knob: env override > dns.env value > default. ──
    # This is the WHOLE precedence — no per-key .state files, no third tier. Each
    # value is written back by write_dns_env (the single source of truth). A bare
    # re-run reads dns.env and preserves it; an explicit env var changes + persists.
    PUBLIC_IP="${PUBLIC_IP:-$(cfg_get DNS_PUBLIC_IP)}"
    get_public_ip          # detects the public IPv4 ONLY if still unset (env/cfg win);
                           # editable later via '5gpn change-public-ip' or the menu
    # GATEWAY_IP: env > dns.env > interactive prompt (default = PUBLIC_IP).
    resolve_gateway_ip
    # CHINA_ECS: env > dns.env > interactive prompt (default = 122.96.30.0),
    # normalised to its /24 (EDNS Client Subnet for the china resolver group).
    resolve_china_ecs
    CACHE_SIZE="${CACHE_SIZE:-$(cfg_get DNS_CACHE_SIZE)}"; CACHE_SIZE="${CACHE_SIZE:-${_CACHE_SIZE_DEFAULT:-4096}}"
    CERT_EMAIL="${CERT_EMAIL:-${EMAIL:-$(cfg_get CERT_EMAIL)}}"
    # CERT_MODE: only cloudflare (default, DNS-01 wildcard) | debug (self-signed
    # wildcard). DEBUG=1 is a shortcut. http-01/dns-01-generic/import were removed.
    CERT_MODE="${CERT_MODE:-$(cfg_get CERT_MODE)}"
    [[ "${DEBUG:-0}" == "1" ]] && CERT_MODE="debug"
    CERT_MODE="${CERT_MODE:-cloudflare}"
    [[ "$CERT_MODE" == "cloudflare" || "$CERT_MODE" == "debug" ]] \
        || { err "CERT_MODE must be cloudflare or debug (got '$CERT_MODE'). http-01/dns-01/import were removed."; exit 1; }
    export PUBLIC_IP GATEWAY_IP CACHE_SIZE CERT_EMAIL CERT_MODE

    # Fresh-artifact rule: clean every previous artifact BEFORE the installers
    # repopulate them (units/configs/runtime tree removed here; binaries are
    # replaced by unconditional download+install below). /etc/5gpn persists.
    clean_previous_install
    remove_legacy_policy_state

    install_deps

    # Bind addresses are a separate local-interface concern: PUBLIC_IP may be
    # a non-local provider/NAT identity, while GATEWAY_IP may live on another
    # client-facing interface. Include every locally assigned candidate, or
    # strictly validate the operator's explicit comma-separated list.
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    export MIHOMO_LISTEN_IPS
    info "mihomo tunnel listeners: ${MIHOMO_LISTEN_IPS} (local bind addresses; independent of PUBLIC_IP/GATEWAY_IP)"

    # Egress DNS Broker fallback resolver: env override > dns.env (either the
    # primary DNS_EGRESS_RESOLVER or the back-compat XRAY_RESOLVER) > 22.22.22.22
    # sentinel. NOT prompted at install (keeps the flow short) — it defaults to
    # the placeholder and the operator sets it later via '5gpn change-resolver
    # <ip|https://…/dns-query>' or the menu. Empty is a valid choice (= sentinel).
    # The resolved value is carried in XRAY_RESOLVER so write_dns_env emits BOTH
    # keys (DNS_EGRESS_RESOLVER primary + XRAY_RESOLVER alias) with it.
    XRAY_RESOLVER="${XRAY_RESOLVER:-$(cfg_get XRAY_RESOLVER)}"
    XRAY_RESOLVER="${XRAY_RESOLVER:-$(cfg_get DNS_EGRESS_RESOLVER)}"
    export XRAY_RESOLVER
    if [[ -z "$XRAY_RESOLVER" || "$XRAY_RESOLVER" == "22.22.22.22" ]]; then
        warn "Egress DNS Broker fallback resolver is the 22.22.22.22 placeholder — proxied domains will NOT resolve until you set a real poison-resistant resolver: '5gpn change-resolver <plain-IPv4|https://…/dns-query>' (or the menu)."
    fi
    validate_egress_resolver "${XRAY_RESOLVER:-$DNS_EGRESS_RESOLVER_DEFAULT}"

    install_files
    install_manage_cli
    # (Legacy python units, sing-box, smartdns etc. were all removed by
    # clean_previous_install above.)

    install_mihomo
    install_web
    install_zashboard
    # 5gpn no longer manages a host firewall: clean up the ruleset an older
    # version may have left (a stale policy-drop must not linger).
    remove_legacy_firewall

    # ONE operator domain knob: resolve_domains prompts for the base (apex) and
    # derives + exports BASE_DOMAIN/CONSOLE_DOMAIN/ZASH_DOMAIN/PROFILE_DOMAIN/
    # DOT_DOMAIN/WEB_DOMAIN
    # (all covered by the single *.<base> wildcard install_cert issues below).
    resolve_domains
    if [[ "$CERT_MODE" == "cloudflare" ]]; then
        info "CERT_MODE=cloudflare: wildcard *.${BASE_DOMAIN} via DNS-01 (no :80 challenge; ${PROFILE_DOMAIN} still needs its bootstrap A record)."
    else
        info "CERT_MODE=$CERT_MODE: skipping DNS-01 issuance (self-signed wildcard)."
    fi
    install_units
    # ONE wildcard lineage for the base domain: an existing valid cert (lineage
    # or the preserved /etc/5gpn/cert copies) is REUSED, never re-issued needlessly.
    install_cert "$BASE_DOMAIN"
    write_dns_env          # single source of truth — persists every knob above
    # Seed mihomo only on first install; a re-install validates and preserves
    # the operator-owned file. install_mihomo already ran, so `mihomo -t` is
    # available for both paths.
    render_mihomo_config

    run_update_lists       # trigger reload (subscriptions fetch chnroute in-process)
    system_tuning
    # Tolerate a fail-closed (unsigned) profile: the install continues, the
    # profile is simply absent rather than aborting the whole run.
    setup_ios_profile || warn "iOS profile not generated (fail-closed); install continues, profile absent."
    start_services
    verify_profile_dns
    verify_profile_endpoint

    echo ""
    ok "5gpn install complete."
    {
        echo "✅ 5gpn 安装完成"
        echo ""
        echo "  DoT 地址         tls://${DOT_DOMAIN}:853"
        echo "  Android 私人DNS  ${DOT_DOMAIN}"
        echo "  iOS 描述文件      https://${PROFILE_DOMAIN}/ios/ios-dot.mobileconfig"
        echo "  Bootstrap DNS    ${PROFILE_DOMAIN} A -> ${PUBLIC_IP}（NPN 可用客户端可路由 ${GATEWAY_IP}）"
    } | card
    {
        echo "Web 控制台: https://${CONSOLE_DOMAIN}/"
        echo "zashboard:  https://${ZASH_DOMAIN}/"
        echo "iOS only:   https://${PROFILE_DOMAIN}/ios/  (该 SNI 不提供 SPA/API)"
        echo "Token:      ${DNS_API_TOKEN}"
        echo "(经 mihomo :443 SNI 分流到 loopback:443；面板仅对白名单来源 IP 开放 — 5gpn add-allow <cidr>)"
        echo "(shown once — not logged elsewhere)"
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
# The TLS cert is DELIBERATELY preserved in BOTH modes — re-issuing a Let's Encrypt
# cert for the same domain is rate-limited, so the deployed copy (/etc/5gpn/cert)
# AND the certbot lineage (/etc/letsencrypt, never touched here) survive so a
# re-install reuses the cert instead of burning a new issuance. Remove certs
# manually only when decommissioning the domain.
# ----------------------------------------------------------------------------
uninstall() {
    check_root
    local purge=0
    [[ "${1:-}" == "--purge" ]] && purge=1
    warn "Uninstalling 5gpn: stopping services and reverting host changes."

    # systemd units + our renew timer (+ legacy unit names, best-effort). Includes
    # the removed sing-box data plane, the obsolete socket-activated iOS responder,
    # and the legacy sniproxy unit so a box that once ran an older layout is fully
    # cleaned.
    for unit in 5gpn-dns.service mihomo.service xray.service sing-box.service 5gpn-certbot-renew.timer \
                5gpn-certbot-renew.service 5gpn-api.service 5gpn-tgbot.service \
                5gpn-iosprofile.socket '5gpn-iosprofile@.service' sniproxy.service; do
        systemctl disable --now "$unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/$unit"
    done
    systemctl daemon-reload 2>/dev/null || true

    # letsencrypt hooks we installed (current + legacy nft-era names).
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh \
          /etc/letsencrypt/renewal-hooks/pre/10-5gpn-stop-xray.sh \
          /etc/letsencrypt/renewal-hooks/post/10-5gpn-start-xray.sh \
          /etc/letsencrypt/renewal-hooks/pre/10-5gpn-open80.sh \
          /etc/letsencrypt/renewal-hooks/post/10-5gpn-close80.sh

    # sysctl / kernel-module tuning.
    rm -f /etc/sysctl.d/99-5gpn.conf /etc/modules-load.d/5gpn.conf /etc/modprobe.d/5gpn.conf
    sysctl --system >/dev/null 2>&1 || true

    # Precise legacy cleanup only; never touch unrelated host firewall state.
    remove_legacy_firewall

    # Swapfile added on low-memory hosts.
    if [[ -e /swapfile ]]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        sed -i '\#^/swapfile #d' /etc/fstab 2>/dev/null || true
        ok "Removed /swapfile and its fstab entry."
    fi

    # Binaries + install tree. Also the gum binary install_gum fetched and the
    # quick-install.sh source checkout, so an uninstall leaves nothing of ours on
    # the box (both are best-effort — absent on a manual/dev install).
    rm -f /usr/local/bin/5gpn-dns /usr/local/bin/mihomo /usr/local/bin/xray /usr/local/bin/sing-box /usr/local/bin/gum /usr/local/bin/5gpn
    rm -rf /usr/local/etc/xray "$SINGBOX_DIR"
    # Remove an external zashboard path while its ownership marker is still
    # available. The default path is removed with BASE_DIR immediately after.
    if [[ "$DNS_ZASH_DIR" != "$BASE_DIR"/* ]]; then
        remove_zashboard_dir || warn "Kept unowned/unsafe DNS_ZASH_DIR '$DNS_ZASH_DIR'."
    fi
    rm -rf "$BASE_DIR" /opt/5gpn-src

    if [[ $purge == 1 ]]; then
        # DELIBERATELY preserve the cert dir even on --purge: re-issuing a Let's
        # Encrypt cert for the same domain is rate-limited, so the deployed copy
        # (/etc/5gpn/cert) AND the certbot lineage (/etc/letsencrypt, never removed
        # here) must survive so a later re-install reuses the cert instead of
        # burning a fresh issuance. The acme/ dir (Cloudflare API token) is ALSO
        # preserved: install_cert's reuse-only path (a still-valid lineage or
        # preserved cert copy) never touches certbot, but a re-install that DOES
        # need to issue (no valid cert survived) must not hard-abort for a token
        # that was needlessly wiped. Remove everything else under CONF_DIR.
        find "$CONF_DIR" -mindepth 1 -maxdepth 1 ! -name cert ! -name acme -exec rm -rf {} + 2>/dev/null || true
        warn "Purged ${CONF_DIR} EXCEPT cert/ and acme/ (DNS_API_TOKEN, rules, subscriptions removed; cert + Cloudflare token kept for reuse — LE rate limits)."
        info "To also drop certs (only when decommissioning): rm -rf ${DNS_CERT_DIR} && certbot delete --cert-name <domain>"
    else
        ok "Kept ${CONF_DIR} (cert, acme token, DNS_API_TOKEN, rules, subscriptions). '--purge' removes it EXCEPT cert/ and acme/ (always kept for reuse)."
    fi
    ok "5gpn uninstalled."
}

usage() {
    cat <<EOF
5gpn installer (exit-less DoT gateway; DoT is the ONLY DNS transport)
Usage: sudo bash install.sh [option]     — or, after install, just:  5gpn [option]

  (no args)           Full install / re-run (requires BASE_DOMAIN unless DEBUG=1).
                      Re-runs refresh binaries/units/web assets at the pins while
                      preserving + validating operator-owned mihomo config and
                      /etc/5gpn state. Dev builds: scp AFTER install.
  --menu              Open the interactive management menu (this is what bare '5gpn' runs)
  --status            Show service states, domains, IP, list counts/age
  --restart           Restart the 5gpn services (5gpn-dns + mihomo)
  --change-base-domain <d> Re-point the base domain: reissue *.<d> wildcard, re-derive
                      console./zash./profile./dot.<d>, preserve+validate mihomo,
                      regen iOS, restart (mihomo-reset explicitly restores seed)
  --change-web-domain <d>  Deprecated alias for --change-base-domain <d>
  --change-dot-domain <d>  Deprecated alias for --change-base-domain (dot. prefix stripped)
  --change-public-ip <ip>  Re-point the public IPv4; preserve+validate operator mihomo config
  --change-gateway <ip> Re-point the client-facing gateway IP; preserve+validate mihomo + refresh iOS + restart
  --change-resolver <r> Set the Egress DNS Broker's fallback resolver (plain IPv4 or https://…/dns-query DoH) + restart 5gpn-dns
  --update-lists      Reload 5gpn-dns rule caches (subscriptions fetch in-process)
  --add-domain <d>    Force-proxy a domain (adds to rules/blacklist.txt)
  --del-domain <d>    Remove a domain from the forced-proxy list
  --add-allow <cidr>  Add a source IP/CIDR to the panel allowlist (whitelist.txt) + live refresh
  --del-allow <cidr>  Remove a source IP/CIDR from the panel allowlist + live refresh
  --ios               Regenerate the iOS profile + QR
  --setup-tgbot       Install + enable the Telegram control bot
  --rotate-token      Generate a new control-console DNS_API_TOKEN + restart
  --set-cf-token [t]  Set/update the Cloudflare API token used by cert issuance
                      (writes /etc/5gpn/acme/cloudflare.ini; prompts if omitted)
  mihomo-reset        Explicitly back up + replace the operator mihomo config
                      with a freshly rendered, validated seed, then restart
  --uninstall [--purge]  Remove units/tuning + binaries (keeps /etc/5gpn;
                      --purge removes it EXCEPT cert/ and acme/ — the TLS certs +
                      certbot lineages are ALWAYS kept for reuse, since re-issuing
                      hits Let's Encrypt rate limits, and the Cloudflare token is
                      kept so a later re-issue doesn't hard-abort for a wiped
                      credential; a re-install detects + reuses the cert)
  --help              This help

After a full install, a '5gpn' command is placed on PATH: run it with no args for
the menu, or pass any option above (e.g. '5gpn --status', '5gpn change-base-domain example.com').

Config: /etc/5gpn/dns.env is the SINGLE source of truth. Every knob below is
persisted there and reused on a bare re-run; an env var overrides it for that run
(then is written back). There are no per-key .state files.

Domains + certificates: ONE base (apex) domain, ONE mandatory WILDCARD Let's Encrypt lineage.
  BASE_DOMAIN (e.g. example.com)     the operator's single domain knob. Four
                                     service domains are auto-derived:
                                       console.<base>  web console (mihomo :443 SNI
                                                       split -> daemon loopback :443)
                                       zash.<base>     zashboard panel
                                       profile.<base>  public iOS bootstrap (/ios/
                                                       only); MUST have an A record
                                       dot.<base>      DoT :853 (Private DNS / iOS)
                                     WEB_DOMAIN= is a back-compat alias for BASE_DOMAIN.
  CERT_MODE=cloudflare (default)     mandatory WILDCARD *.<base> cert via Let's
                     Encrypt DNS-01 through the Cloudflare API (no :80, no public
                     A-record needed for certificate issuance); auto-renews unattended
                     via the daily 5gpn-certbot-renew.timer. Only an actual
                     ISSUANCE (no valid cert to reuse) needs a scoped Cloudflare
                     API token in /etc/5gpn/acme/cloudflare.ini (0600); set it via
                     '5gpn --set-cf-token' (or the menu), or manually:
                       install -d -m 0700 /etc/5gpn/acme
                       echo 'dns_cloudflare_api_token = <token>' > /etc/5gpn/acme/cloudflare.ini
                       chmod 600 /etc/5gpn/acme/cloudflare.ini
  CERT_MODE=debug    (or DEBUG=1) self-signed WILDCARD cert for a test/dev box with
                     no public domain — no certbot, no DNS-01, no renewal; clients
                     see it untrusted.
  An existing valid wildcard (lineage or the preserved /etc/5gpn/cert copies) is
  DETECTED and REUSED on re-install — never re-issued needlessly.

There is NO host firewall management (removed): use your provider's security
group if you need one. The web console + zashboard panels are reachable ONLY from
source IPs on the mihomo whitelist.txt allowlist (TUI-managed: '5gpn add-allow
<cidr>' / '5gpn del-allow <cidr>'); every other source gets REJECT-DROP.

Env overrides (persisted to dns.env):
  BASE_DOMAIN=         base (apex) domain (required unless DEBUG=1); DNS_BASE_DOMAIN
                       in dns.env. console./zash./profile./dot. are auto-derived.
  WEB_DOMAIN=          back-compat alias for BASE_DOMAIN
  DEBUG=1              shortcut for CERT_MODE=debug (self-signed, no domain needed)
  CERT_EMAIL= (EMAIL=) Let's Encrypt registration email
  PUBLIC_IP=           public IP (cert A-record target); auto-detected if unset,
                       editable later via '5gpn change-public-ip <ip>' or the menu
  GATEWAY_IP=          client-facing address; prompted at install (default=PUBLIC_IP),
                       editable later via '5gpn change-gateway <ip>' or the menu
  MIHOMO_LISTEN_IPS=   comma-separated LOCAL IPv4 bind addresses for mihomo :80/:443;
                       defaults to locally-assigned GATEWAY_IP/PUBLIC_IP (deduped),
                       then the default-route source. Loopback/non-local values fail.
  CACHE_SIZE=          DNS response-cache entries (default scales with RAM)
  DNS_CHINA= DNS_TRUST=             upstream resolver groups (see dns.env)
  DNS_CHINA_ECS=       EDNS Client Subnet for the china group; prompted at install
                       (default=122.96.30.0, check ip.cn ON CELLULAR data), normalised
                       to its /24; 'off' disables; editable later in the web console
  DNS_MAX_INFLIGHT= DNS_TTL_MIN= DNS_TTL_MAX= DNS_QUERY_TIMEOUT=   daemon tuning (see dns.env)
  DNS_API_TOKEN=       control-console bearer token (auto-generated + preserved; see --rotate-token)
  DNS_EGRESS_RESOLVER= egress SNI re-resolver (back-compat alias XRAY_RESOLVER;
                       default=22.22.22.22 placeholder; ipv4=plain-UDP or
                       https://…/dns-query=DoH). NOT prompted at install — set it
                       later via '5gpn change-resolver <r>' or the menu.
  MIHOMO_VERSION= MIHOMO_SHA256=   mihomo pin
  ZASH_VERSION= ZASH_SHA256=   zashboard (Zephyruso/zashboard) dist.zip pin
  DNS_ZASH_DIR= DNS_ZASH_LISTEN=   zashboard panel dir/listen (default /opt/5gpn/zash,
                       127.0.0.2:443); DNS_ZASH_CERT/_KEY always derive from the
                       wildcard's zash/ role-dir copy (daemon falls back to
                       web/dot cert if that role dir is unpopulated)
  DNS_VERSION=0.0.1 DNS_SHA256= WEB_SHA256= DNS_WEB_DIR=/opt/5gpn/web   binary/SPA pins
  ALLOW_UNSIGNED_PROFILE=1   serve an unsigned iOS .mobileconfig (tamperable; off by default)
  SKIP_PROFILE_DNS_CHECK=1   explicitly bypass profile.<base> A verification
                             (staged deployment/CI only; default fail-closed)
  GUM_VERSION= GUM_SHA256=   pin the bootstrapped gum binary
  TGBOT_TOKEN= TGBOT_ADMINS= LOWMEM=1|0
EOF
}

main() {
    local cmd="${1:-}"
    # Piped install (curl | sudo bash): reattach stdin to the terminal so the
    # prompts below fire. No-op when stdin is already a tty or when headless.
    attach_tty
    case "$cmd" in
        ""|install)     full_install ;;
        --menu|menu)    manage_menu ;;
        --restart|restart)            restart_services ;;
        --change-base-domain|change-base-domain) change_base_domain "${2:-}" ;;
        # Back-compat aliases (single base-domain model): the old web/base domain
        # command maps straight through; the old DoT-domain command strips a
        # leading 'dot.' to recover the base; --change-domain is the legacy
        # single-domain alias.
        --change-web-domain|change-web-domain)
            warn "'$1' is deprecated; use 'change-base-domain <base>' (one wildcard covers console./zash./dot.)."
            change_base_domain "${2:-}" ;;
        --change-domain|change-domain)
            warn "'$1' is deprecated; use 'change-base-domain <base>'."
            change_base_domain "${2:-}" ;;
        --change-dot-domain|change-dot-domain)
            warn "'$1' is deprecated: the DoT name is now dot.<base>. Use 'change-base-domain <base>'."
            change_base_domain "${2#dot.}" ;;
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
