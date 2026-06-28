#!/usr/bin/env bash
# 5gpn installer / orchestrator (exit-less, direct-egress architecture).
#
#   client DoT:853 -> smartdns (returns the GATEWAY IP for blocked/foreign
#   domains) -> xray (TCP 80/443/QUIC) reads SNI, resolves the real IP via
#   22.22.22.22, then egress DIRECTLY out the default route.
#
# QUIC/HTTP3 is proxied by xray (UDP 443 SNI routing). No exit layer, no Go.
#
# There is NO exit layer: no sing-box, no WireGuard, no multi-exit, no
# fwmark / ip-rule / table-100. Do not add any of those.
set -euo pipefail

# ----------------------------------------------------------------------------
# Paths & constants
# ----------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"   # repo 5gpn/ when run from a checkout

BASE_DIR="/opt/5gpn"                 # installed runtime root
SCRIPTS_DIR="${BASE_DIR}/scripts"        # installed copies of repo scripts
SRC_DIR="${BASE_DIR}/src"                # ios-http.py + build scratch
WWW_DIR="${BASE_DIR}/www"                # iOS profile web root
BUILD_DIR="${BASE_DIR}/build"            # download/unpack scratch

CONF_DIR="/etc/5gpn"                 # state: .domain .public_ip .gateway_ip ...
SMARTDNS_DIR="/etc/smartdns"             # smartdns.conf(.template), lists, cert/
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"

IOS_PORT=8111                            # socket-activated iOS profile responder
RESOLV_FALLBACK="22.22.22.22"            # loop-avoidance external resolver (proxies)
GUM_VERSION="${GUM_VERSION:-0.17.0}"     # charmbracelet/gum (prebuilt; installer TUI)
_HAVE_GUM=0                              # set by install_gum(); helpers fall back to echo when 0

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

# Interactive helpers. Callers MUST gate on [[ -t 0 ]]; these only choose gum vs read.
ask_text()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum input --prompt "$1 " --placeholder "${2:-}"; else local v; read -r -p "$1 " v; printf '%s' "$v"; fi; }
ask_secret() { if [[ "$_HAVE_GUM" == 1 ]]; then gum input --password --prompt "$1 "; else local v; read -r -p "$1 " v; printf '%s' "$v"; fi; }
ask_yesno()  { if [[ "$_HAVE_GUM" == 1 ]]; then gum confirm "$1"; else local a; read -r -p "$1 [y/N] " a; [[ "$a" == [yY]* ]]; fi; }
# Run an opaque wait command behind a spinner when interactive; else run it plainly.
gum_spin()   { local t="$1"; shift; if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then gum spin --title "$t" -- "$@"; else "$@"; fi; }
# Frame multi-line stdin in a rounded box when interactive; else pass it through.
card()       { if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then gum style --border rounded --padding "0 1" --border-foreground 212; else cat; fi; }

# Bootstrap gum (prebuilt binary + sha256 verify). Never fatal: on any failure
# _HAVE_GUM stays 0 and all helpers fall back to plain echo.
install_gum() {
    if command -v gum >/dev/null 2>&1; then _HAVE_GUM=1; return 0; fi
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
    if command -v curl >/dev/null 2>&1 && curl -fsSL "$url" -o "$tmp/gum.tgz" 2>/dev/null; then
        exp="${GUM_SHA256:-}"
        if [[ -z "$exp" ]]; then
            curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/checksums.txt" \
                 -o "$tmp/sums.txt" 2>/dev/null \
                && exp="$(grep "gum_${GUM_VERSION}_Linux_${arch}.tar.gz" "$tmp/sums.txt" 2>/dev/null | awk '{print $1}' | head -1 || true)"
        fi
        if [[ -n "$exp" ]]; then
            got="$(sha256sum "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
            if [[ "$got" != "$exp" ]]; then
                warn "gum sha256 mismatch; continuing with plain output."
                rm -rf "$tmp"; _HAVE_GUM=0; return 0
            fi
        fi
        tar -xzf "$tmp/gum.tgz" -C "$tmp" 2>/dev/null || true
        bin="$(find "$tmp" -type f -name gum 2>/dev/null | head -1 || true)"
        [[ -n "$bin" ]] && { install -m 0755 "$bin" /usr/local/bin/gum 2>/dev/null || true; }
    fi
    rm -rf "$tmp" 2>/dev/null || true
    if command -v gum >/dev/null 2>&1; then _HAVE_GUM=1; else _HAVE_GUM=0; warn "gum unavailable; using plain output."; fi
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

# Sets MEM_TOTAL_MB, LOWMEM (0/1), MAKE_JOBS, CACHE_SIZE. LOWMEM env overrides.
detect_memory_profile() {
    MEM_TOTAL_MB=$(awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0)
    if [[ -n "${LOWMEM:-}" ]]; then
        case "$LOWMEM" in 1|yes|true|on) LOWMEM=1 ;; *) LOWMEM=0 ;; esac
    elif [[ "${MEM_TOTAL_MB:-0}" -le 1300 ]]; then LOWMEM=1; else LOWMEM=0; fi

    if [[ "$LOWMEM" == "1" ]]; then
        MAKE_JOBS=1; CACHE_SIZE=20000
        warn "Low-memory mode ON (RAM ${MEM_TOTAL_MB}MB): cache=${CACHE_SIZE}, 1 build job, swap ensured."
    else
        MAKE_JOBS="$(nproc 2>/dev/null || echo 2)"; CACHE_SIZE=512000
        info "Standard memory mode (RAM ${MEM_TOTAL_MB}MB): cache=${CACHE_SIZE}."
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

# ----------------------------------------------------------------------------
# Dependencies
# ----------------------------------------------------------------------------
install_deps() {
    info "Installing dependencies..."
    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || true
            apt-get install -y -qq \
                wget curl ca-certificates unzip \
                certbot nftables qrencode jq libcap2-bin \
                python3 dnsutils || warn "some apt packages failed; continuing."
            ;;
        dnf|yum)
            $PKG_MGR install -y -q \
                wget curl ca-certificates unzip \
                certbot nftables qrencode jq \
                python3 bind-utils || warn "some rpm packages failed; continuing."
            # libcap setcap tooling (name varies by distro)
            $PKG_MGR install -y -q libcap libcap-ng-utils 2>/dev/null || true
            ;;
    esac

    install_smartdns

    # certbot may break on very new Python; try to repair non-fatally.
    if command -v certbot >/dev/null 2>&1 && ! certbot --version >/dev/null 2>&1; then
        warn "certbot self-check failed; attempting pip repair."
        pip3 install --upgrade --break-system-packages certbot 2>/dev/null \
            || pip3 install --upgrade certbot 2>/dev/null || true
    fi
    command -v certbot >/dev/null 2>&1 || { err "certbot is required but missing."; exit 1; }
}

# smartdns: try the distro package, else fetch the official release binary.
install_smartdns() {
    if command -v smartdns >/dev/null 2>&1; then
        [[ -n "${SMARTDNS_SHA256:-}" ]] && warn "SMARTDNS_SHA256 set but smartdns already on PATH; pin not applied."
        info "smartdns already installed."; return 0
    fi
    info "Installing smartdns (distro package)..."
    case "$PKG_MGR" in
        apt-get) apt-get install -y -qq smartdns 2>/dev/null || true ;;
        dnf|yum) $PKG_MGR install -y -q smartdns 2>/dev/null || true ;;
    esac
    command -v smartdns >/dev/null 2>&1 && {
        [[ -n "${SMARTDNS_SHA256:-}" ]] && warn "SMARTDNS_SHA256 set but smartdns came from distro package (apt/dnf signature-verified); pin not applied."
        ok "smartdns installed (distro)."; return 0
    }

    warn "Distro smartdns unavailable; downloading official release binary."
    local arch sd_arch tmp ver
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  sd_arch="x86_64" ;;
        aarch64|arm64) sd_arch="aarch64" ;;
        armv7l|armhf)  sd_arch="arm" ;;
        *) sd_arch="x86_64"; warn "unknown arch '$arch', trying x86_64." ;;
    esac
    ver="$(curl -fsSL https://api.github.com/repos/pymumu/smartdns/releases/latest 2>/dev/null \
            | jq -r '.tag_name' 2>/dev/null || echo "")"
    [[ -z "$ver" || "$ver" == "null" ]] && ver="Release46.1"
    tmp="$(mktemp -d)"
    # Prefer the static tar.gz asset for the arch; install the bundled binary.
    if curl -fsSL "https://github.com/pymumu/smartdns/releases/download/${ver}/smartdns.${sd_arch}-debian-all.tar.gz" \
            -o "$tmp/smartdns.tar.gz" 2>/dev/null && tar -tzf "$tmp/smartdns.tar.gz" >/dev/null 2>&1; then
        # Opt-in integrity check: set SMARTDNS_SHA256=<hash> to pin the archive.
        if [[ -n "${SMARTDNS_SHA256:-}" ]]; then
            echo "${SMARTDNS_SHA256}  $tmp/smartdns.tar.gz" | sha256sum -c - \
                || { err "smartdns archive sha256 mismatch."; rm -rf "$tmp"; exit 1; }
        fi
        tar -xzf "$tmp/smartdns.tar.gz" -C "$tmp"
        local bin; bin="$(find "$tmp" -type f -name smartdns -perm -u+x 2>/dev/null | head -n1)"
        [[ -z "$bin" ]] && bin="$(find "$tmp" -type f -name smartdns 2>/dev/null | head -n1)"
        if [[ -n "$bin" ]]; then
            install -m 0755 "$bin" /usr/sbin/smartdns
            ok "smartdns ${ver} installed to /usr/sbin/smartdns."
        fi
    fi
    rm -rf "$tmp"
    command -v smartdns >/dev/null 2>&1 || { err "smartdns install failed (no package, no release)."; exit 1; }
}

# ----------------------------------------------------------------------------
# xray (prebuilt binary)
# ----------------------------------------------------------------------------
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then info "xray already installed."; return 0; fi
    local ver="${XRAY_VERSION:-v26.6.22}"
    local url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-64.zip"
    info "Downloading xray ${ver} (prebuilt binary; no Go toolchain)..."
    command -v unzip >/dev/null 2>&1 || { $PKG_MGR install -y unzip >/dev/null 2>&1 || true; }
    mkdir -p "$BUILD_DIR"
    local zip="$BUILD_DIR/Xray-linux-64.zip"
    gum_spin "Downloading xray ${ver}…" curl -fsSL "$url" -o "$zip" || { err "xray download failed ($url)"; exit 1; }
    # Integrity: opt-in pin via XRAY_SHA256, else verify against the release .dgst.
    local exp="${XRAY_SHA256:-}"
    if [[ -z "$exp" ]]; then
        curl -fsSL "${url}.dgst" -o "${zip}.dgst" \
            && exp="$(grep -ioE '\b[0-9a-f]{64}\b' "${zip}.dgst" | head -1)" || true
    fi
    if [[ -n "$exp" ]]; then
        local got; got="$(sha256sum "$zip" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { err "xray sha256 mismatch (want $exp got $got)"; exit 1; }
        ok "xray archive sha256 verified."
    else
        warn "xray sha256 UNVERIFIED (set XRAY_SHA256 or ensure .dgst reachable)."
    fi
    unzip -o "$zip" xray -d "$BUILD_DIR" >/dev/null
    install -m 0755 "$BUILD_DIR/xray" "$XRAY_BIN"
    [[ -x "$XRAY_BIN" ]] || { err "xray install failed."; exit 1; }
    ok "xray installed to $XRAY_BIN ($ver)."
}

# ----------------------------------------------------------------------------
# Install config + scripts + control-plane sources
# ----------------------------------------------------------------------------
install_files() {
    info "Installing config files and scripts..."
    mkdir -p "$BASE_DIR" "$SCRIPTS_DIR" "$SRC_DIR" "$WWW_DIR" \
             "$CONF_DIR" "$SMARTDNS_DIR" "$SMARTDNS_DIR/cert"

    # smartdns template + proxy-domains seed (don't clobber an edited proxy list).
    # The template is installed to BOTH /etc/smartdns (canonical) and
    # /opt/5gpn/etc (where the installed update-lists.sh resolves it via
    # ROOT="$HERE/..").
    install -m 0644 "${SCRIPT_DIR}/etc/smartdns.conf.template" "${SMARTDNS_DIR}/smartdns.conf.template"
    install -d -m 0755 "${BASE_DIR}/etc"
    install -m 0644 "${SCRIPT_DIR}/etc/smartdns.conf.template" "${BASE_DIR}/etc/smartdns.conf.template"
    if [[ ! -f "${SMARTDNS_DIR}/proxy-domains.txt" ]]; then
        install -m 0644 "${SCRIPT_DIR}/etc/proxy-domains.txt" "${SMARTDNS_DIR}/proxy-domains.txt"
    else
        info "Keeping existing ${SMARTDNS_DIR}/proxy-domains.txt."
    fi
    # bogus-nxdomain poison list (anti-pollution include; don't clobber edits).
    if [[ ! -f "${SMARTDNS_DIR}/bogus-nxdomain.conf" ]]; then
        install -m 0644 "${SCRIPT_DIR}/etc/bogus-nxdomain.conf" "${SMARTDNS_DIR}/bogus-nxdomain.conf"
    fi

    # xray config (dns hardcoded to 22.22.22.22 for loop-avoidance, IPv4-only, direct).
    install -d -m 0755 "$XRAY_DIR"
    install -m 0644 "${SCRIPT_DIR}/etc/xray/config.json" "$XRAY_DIR/config.json"
    # SNI re-resolver: default 22.22.22.22 (the NPN carrier resolver; loop-avoidance
    # requires only that it is NOT the local smartdns). Operators on a different
    # network can point it at a reachable clean IPv4 resolver via XRAY_RESOLVER.
    # The repo config.json keeps the default literal; we patch only the installed copy.
    local xr="${XRAY_RESOLVER:-$RESOLV_FALLBACK}"
    if [[ "$xr" != "$RESOLV_FALLBACK" ]]; then
        if [[ "$xr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            sed -i "s/${RESOLV_FALLBACK//./\\.}/${xr}/g" "$XRAY_DIR/config.json"
            info "xray SNI resolver overridden -> ${xr}"
        else
            warn "XRAY_RESOLVER='${xr}' is not an IPv4; keeping default ${RESOLV_FALLBACK}."
        fi
    fi

    # repo scripts -> /opt/5gpn/scripts
    for f in "${SCRIPT_DIR}"/scripts/*.sh "${SCRIPT_DIR}"/scripts/*.py; do
        [[ -e "$f" ]] || continue
        install -m 0755 "$f" "${SCRIPTS_DIR}/$(basename "$f")"
    done

    # iOS responder + control-plane python (only if shipped in the checkout)
    [[ -f "${SCRIPT_DIR}/src/ios-http.py" ]] && install -m 0755 "${SCRIPT_DIR}/src/ios-http.py" "${SRC_DIR}/ios-http.py"
    [[ -f "${SCRIPT_DIR}/tgbot.py"       ]] && install -m 0755 "${SCRIPT_DIR}/tgbot.py"       "${BASE_DIR}/tgbot.py"
    ok "Files installed under ${BASE_DIR} and ${SMARTDNS_DIR}."
}

# ----------------------------------------------------------------------------
# Domain + ACME certificate
# ----------------------------------------------------------------------------
is_valid_domain() {
    # Same FQDN rule as tgbot.py DOMAIN_RE (bash ERE has no
    # lookahead, so total length is checked separately): lowercase [a-z0-9-]
    # labels (<=63), alphabetic 2-63 TLD, total 1..253. Case-insensitive.
    local d; d="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ ${#d} -ge 1 && ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

resolve_domain() {
    # Reuse a saved domain, else env DOMAIN, else prompt.
    if [[ -z "${DOMAIN:-}" && -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN="$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)"
        is_valid_domain "$DOMAIN" && info "Reusing saved domain: $DOMAIN"
    fi
    if [[ -n "${DOMAIN:-}" ]]; then
        is_valid_domain "$DOMAIN" || { err "Invalid DOMAIN '$DOMAIN'."; exit 1; }
    else
        if [[ ! -t 0 ]]; then
            err "No domain. Set DOMAIN=dns.example.com for non-interactive installs."; exit 1
        fi
        local input=""
        while true; do
            input="$(ask_text 'Enter your DoT domain (e.g. dns.example.com):' || true)"
            input="${input#http://}"; input="${input#https://}"; input="${input%/}"; input="${input// /}"
            is_valid_domain "$input" && { DOMAIN="$input"; break; }
            warn "Invalid domain; enter a full FQDN like dns.example.com."
        done
    fi
    mkdir -p "$CONF_DIR"
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
    echo "$PUBLIC_IP" > "${CONF_DIR}/.public_ip"
    info "Domain: $DOMAIN -> $PUBLIC_IP"
}

verify_a_record() {
    info "Verifying $DOMAIN resolves to $PUBLIC_IP ..."
    info "  Add an A record: ${DOMAIN}  A  ${PUBLIC_IP}  (low TTL)."
    if [[ -t 0 ]]; then
        local c=""; c="$(ask_text "Press Enter once the A record is set (or type 'skip'):")" || c=""
        [[ "$c" == "skip" ]] && { warn "Skipping A-record verification."; return 0; }
    fi
    local waited=0 resolved=""
    while [[ $waited -lt 120 ]]; do
        resolved=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
        [[ -z "$resolved" ]] && resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)
        if [[ "$resolved" == "$PUBLIC_IP" ]]; then ok "DNS verified: $DOMAIN -> $PUBLIC_IP"; return 0; fi
        sleep 5; waited=$((waited+5)); echo -n "."
    done
    echo ""
    warn "A record not effective in 120s (saw: ${resolved:-none}); continuing. Cert issuance may fail."
}

open_port80()  { nft list table inet filter >/dev/null 2>&1 && nft insert rule inet filter input tcp dport 80 accept 2>/dev/null || true; }
close_port80() { [[ -f /etc/nftables.conf ]] && nft -f /etc/nftables.conf 2>/dev/null || true; }

install_cert() {
    local live="/etc/letsencrypt/live/${DOMAIN}"
    # Keep a still-valid cert (>30 days) to dodge Let's Encrypt rate limits.
    if [[ -f "${live}/fullchain.pem" ]] && \
       openssl x509 -checkend $((30*86400)) -noout -in "${live}/fullchain.pem" >/dev/null 2>&1; then
        info "Valid cert exists (>30d); reusing."
    else
        info "Issuing Let's Encrypt cert for $DOMAIN (standalone)..."
        open_port80
        local rc=0
        certbot certonly --standalone -d "$DOMAIN" --agree-tos -n \
            -m "${EMAIL:-admin@${DOMAIN}}" --keep-until-expiring || rc=$?
        close_port80
        if [[ $rc -ne 0 || ! -f "${live}/fullchain.pem" ]]; then
            err "Certificate issuance failed. Check: A record -> $PUBLIC_IP, port 80 reachable, LE rate limits."
            exit 1
        fi
    fi
    install -d -m 0755 "${SMARTDNS_DIR}/cert"
    install -m 0644 "${live}/fullchain.pem" "${SMARTDNS_DIR}/cert/fullchain.pem"
    install -m 0640 "${live}/privkey.pem"   "${SMARTDNS_DIR}/cert/privkey.pem"
    ok "Cert deployed to ${SMARTDNS_DIR}/cert/."

    # Renewal deploy hook (redeploys cert + restarts smartdns). Ships in repo.
    if [[ -f "${SCRIPT_DIR}/scripts/renew-hook.sh" ]]; then
        install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
        install -m 0755 "${SCRIPT_DIR}/scripts/renew-hook.sh" \
            /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh
        ok "Renewal deploy hook installed."
    else
        warn "scripts/renew-hook.sh not found; auto-renew reload hook skipped."
    fi

    install_renewal_automation
}

# Make `certbot renew` work behind the DoT-only (drop) firewall where xray
# holds :80: install pre/post renewal-hooks that briefly open 80 + stop xray
# (then restore), plus a Persistent daily timer so renewal runs unattended.
# Without this the LE cert expires (~90d) and DoT :853 dies with no :53 fallback.
install_renewal_automation() {
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
    cat > /etc/letsencrypt/renewal-hooks/pre/10-5gpn-open80.sh <<'EOF'
#!/usr/bin/env bash
# Free TCP 80 for certbot --standalone: open the firewall + stop xray (binds :80).
nft list table inet filter >/dev/null 2>&1 && nft insert rule inet filter input tcp dport 80 accept 2>/dev/null || true
systemctl stop xray 2>/dev/null || true
EOF
    cat > /etc/letsencrypt/renewal-hooks/post/10-5gpn-close80.sh <<'EOF'
#!/usr/bin/env bash
# Restore DoT-only firewall (drops the temp :80 accept) + bring xray back.
# Runs after every renewal attempt, success or failure.
systemctl start xray 2>/dev/null || true
[ -f /etc/nftables.conf ] && nft -f /etc/nftables.conf 2>/dev/null || true
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/pre/10-5gpn-open80.sh \
             /etc/letsencrypt/renewal-hooks/post/10-5gpn-close80.sh
    ok "Renewal pre/post hooks installed (open/close :80 + cycle xray)."

    # Don't double up if the distro/snap already ships an enabled renewal timer
    # (our renewal-hooks above apply regardless of which timer triggers renew).
    if systemctl is-enabled certbot.timer >/dev/null 2>&1 \
       || systemctl is-enabled snap.certbot.renew.timer >/dev/null 2>&1; then
        info "Existing certbot timer detected; relying on it (our hooks still apply)."
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
    ok "Installed 5gpn-certbot-renew.timer (daily, Persistent)."
}

# ----------------------------------------------------------------------------
# Lists + smartdns render, firewall, iOS profile
# ----------------------------------------------------------------------------
run_update_lists() {
    info "Building chnroute lists + rendering smartdns.conf..."
    SMARTDNS_DIR="$SMARTDNS_DIR" GATEWAY_IP="${GATEWAY_IP:-$PUBLIC_IP}" CACHE_SIZE="$CACHE_SIZE" \
        bash "${SCRIPTS_DIR}/update-lists.sh"
    ok "Lists updated and smartdns.conf rendered."
}

run_setup_firewall() {
    info "Installing firewall + proxy units (direct egress, no exit layer)..."
    CLIENT_NET="${CLIENT_NET:-172.22.0.0/16}" IOS_PORT="$IOS_PORT" bash "${SCRIPTS_DIR}/setup-firewall.sh"
    ok "Firewall + xray unit installed."
}

install_smartdns_unit() {
    # Most smartdns packages ship a unit; if not, provide a minimal one.
    if systemctl list-unit-files 2>/dev/null | grep -q '^smartdns\.service'; then return 0; fi
    cat > /etc/systemd/system/smartdns.service <<EOF
[Unit]
Description=5gpn smartdns (DoT brain)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v smartdns) -f -c ${SMARTDNS_DIR}/smartdns.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

setup_ios_profile() {
    info "Generating iOS DoT profile..."
    mkdir -p "$WWW_DIR" "$SRC_DIR"
    local gw="${GATEWAY_IP:-$PUBLIC_IP}"
    if [[ -x "${SCRIPTS_DIR}/gen-ios-profile.sh" ]]; then
        bash "${SCRIPTS_DIR}/gen-ios-profile.sh" "$DOMAIN" "$gw" "$WWW_DIR" \
            || warn "gen-ios-profile.sh failed; profile may be incomplete."
    else
        warn "scripts/gen-ios-profile.sh not present yet; skipping profile generation."
    fi

    # Socket-activated (inetd-style) responder: only spawns on a real fetch.
    local py; py="$(command -v python3 || echo /usr/bin/python3)"
    if [[ ! -f "${SRC_DIR}/ios-http.py" ]]; then
        warn "${SRC_DIR}/ios-http.py missing; iOS HTTP service not installed."
        return 0
    fi
    cat > /etc/systemd/system/5gpn-iosprofile.socket <<EOF
[Unit]
Description=5gpn iOS profile HTTP socket

[Socket]
ListenStream=0.0.0.0:${IOS_PORT}
Accept=yes

[Install]
WantedBy=sockets.target
EOF
    cat > /etc/systemd/system/5gpn-iosprofile@.service <<EOF
[Unit]
Description=5gpn iOS profile responder (per-connection)

[Service]
Type=simple
ExecStart=${py} ${SRC_DIR}/ios-http.py
Environment=WWW_DIR=${WWW_DIR}
StandardInput=socket
StandardOutput=socket
StandardError=journal
User=root
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
EOF
    systemctl daemon-reload
    ok "iOS profile responder configured (socket-activated on :${IOS_PORT})."
}

print_qr() {
    local url="http://${GATEWAY_IP:-$PUBLIC_IP}:${IOS_PORT}/ios-dot.mobileconfig"
    if command -v qrencode >/dev/null 2>&1; then
        echo ""; info "Scan to install the iOS profile:"
        qrencode -t ANSIUTF8 "$url" || true
    fi
}

# ----------------------------------------------------------------------------
# System tuning (lean: BBR + conntrack + ip_forward, profile-scaled)
# ----------------------------------------------------------------------------
system_tuning() {
    info "Applying sysctl tuning..."
    modprobe nf_conntrack >/dev/null 2>&1 || true
    mkdir -p /etc/modules-load.d; echo nf_conntrack > /etc/modules-load.d/5gpn.conf
    local ct sm
    if [[ "${LOWMEM:-0}" == "1" ]]; then ct=131072; sm=60; else ct=1048576; sm=10; fi
    cat > /etc/sysctl.d/99-5gpn.conf <<EOF
# 5gpn ($([[ "${LOWMEM:-0}" == "1" ]] && echo low-memory || echo standard))
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.netfilter.nf_conntrack_max=${ct}
vm.swappiness=${sm}
EOF
    sysctl --system >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# Service lifecycle
# ----------------------------------------------------------------------------
start_services() {
    info "Enabling and starting services..."
    systemctl daemon-reload
    for svc in smartdns xray nftables; do
        systemctl enable "$svc" >/dev/null 2>&1 || true
        systemctl restart "$svc" 2>/dev/null || systemctl start "$svc" 2>/dev/null \
            || warn "could not start $svc (check: journalctl -u $svc)."
    done
    if systemctl list-unit-files 2>/dev/null | grep -q '^5gpn-iosprofile\.socket'; then
        systemctl enable --now 5gpn-iosprofile.socket 2>/dev/null || warn "iOS socket failed to start."
    fi
}

# ----------------------------------------------------------------------------
# Optional control plane: tgbot
# ----------------------------------------------------------------------------
setup_tgbot() {
    check_root
    install_gum
    [[ -f "${BASE_DIR}/tgbot.py" ]] || { err "${BASE_DIR}/tgbot.py not found (run a full install or place the file)."; return 1; }
    local py; py="$(command -v python3 || echo /usr/bin/python3)"
    local token admins
    token="${TGBOT_TOKEN:-$(cat "${CONF_DIR}/.tgbot_token" 2>/dev/null || true)}"
    if [[ -z "$token" && -t 0 ]]; then token="$(ask_secret 'Telegram Bot Token (blank to skip):' || true)"; fi
    [[ -z "$token" ]] && { info "No Telegram token; skipping tgbot. Re-run later: $0 --setup-tgbot"; return 0; }
    admins="${TGBOT_ADMINS:-$(cat "${CONF_DIR}/.tgbot_admins" 2>/dev/null || true)}"
    if [[ -z "$admins" && -t 0 ]]; then admins="$(ask_text 'Authorized Telegram numeric IDs (comma-separated, optional):' || true)"; fi
    admins="$(printf '%s' "$admins" | tr ', ' '\n\n' | grep -E '^[0-9]+$' | paste -sd ',' - 2>/dev/null || true)"

    mkdir -p "$CONF_DIR"
    printf '%s' "$token"  > "${CONF_DIR}/.tgbot_token";  chmod 600 "${CONF_DIR}/.tgbot_token"
    printf '%s' "$admins" > "${CONF_DIR}/.tgbot_admins"; chmod 600 "${CONF_DIR}/.tgbot_admins"

    cat > /etc/systemd/system/5gpn-tgbot.service <<EOF
[Unit]
Description=5gpn Telegram control bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Secrets are NOT placed here: a systemd unit is world-readable (mode 644, and
# visible via 'systemctl show'). tgbot.py loads the token + admin IDs from the
# chmod-600 ${CONF_DIR}/.tgbot_token + .tgbot_admins instead (see _load_secret()).
Environment=CONF_DIR=${CONF_DIR}
ExecStart=${py} ${BASE_DIR}/tgbot.py
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now 5gpn-tgbot.service 2>/dev/null || systemctl restart 5gpn-tgbot.service || true
    if [[ -t 0 && "$_HAVE_GUM" == 1 ]]; then
        gum style --border rounded --padding "0 1" \
          "未知自己的 Telegram ID?" \
          "1) 给你的 bot 发 /id" \
          "2) 把回显的数字 ID 填入 ${CONF_DIR}/.tgbot_admins" \
          "3) systemctl restart 5gpn-tgbot"
    fi
    ok "Telegram bot enabled."
    info "Token stored: ${CONF_DIR}/.tgbot_token (chmod 600)"
    [[ -z "$admins" ]] && warn "No admin IDs set yet; message the bot, then add IDs to ${CONF_DIR}/.tgbot_admins and: systemctl restart 5gpn-tgbot"
}

# ----------------------------------------------------------------------------
# Domain-list management (proxy-domains.txt) + list refresh + status
# ----------------------------------------------------------------------------
add_domain() {
    check_root
    local d="${1:-}"; is_valid_domain "$d" || { err "Invalid domain: '$d'"; exit 1; }
    local f="${SMARTDNS_DIR}/proxy-domains.txt"; mkdir -p "$SMARTDNS_DIR"; touch "$f"
    if grep -qxF "$d" "$f"; then info "$d already in proxy list."; else echo "$d" >> "$f"; ok "Added $d to forced-proxy list."; fi
    refresh_lists_and_restart
}

del_domain() {
    check_root
    local d="${1:-}"; [[ -n "$d" ]] || { err "Usage: --del-domain <domain>"; exit 1; }
    local f="${SMARTDNS_DIR}/proxy-domains.txt"; [[ -f "$f" ]] || { warn "No proxy list."; return 0; }
    if grep -qxF "$d" "$f"; then grep -vxF "$d" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"; ok "Removed $d."; else info "$d not in list."; fi
    refresh_lists_and_restart
}

refresh_lists_and_restart() {
    local gw; gw="${GATEWAY_IP:-$(cat "${CONF_DIR}/.gateway_ip" 2>/dev/null || cat "${CONF_DIR}/.public_ip" 2>/dev/null || true)}"
    [[ -z "$gw" ]] && gw="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo 127.0.0.1)"
    local cs; cs="$(cat "${SMARTDNS_DIR}/.cache_size" 2>/dev/null || echo 20000)"
    local sd="${SCRIPTS_DIR}/update-lists.sh"; [[ -x "$sd" ]] || sd="${SCRIPT_DIR}/scripts/update-lists.sh"
    SMARTDNS_DIR="$SMARTDNS_DIR" GATEWAY_IP="$gw" CACHE_SIZE="$cs" bash "$sd"
}

do_update_lists() {
    check_root
    info "Refreshing china_ip_list + foreign-cidr + smartdns.conf..."
    refresh_lists_and_restart
    ok "Lists refreshed."
}

regen_ios() {
    check_root
    DOMAIN="$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)"
    PUBLIC_IP="$(cat "${CONF_DIR}/.public_ip" 2>/dev/null || true)"
    GATEWAY_IP="${GATEWAY_IP:-$(cat "${CONF_DIR}/.gateway_ip" 2>/dev/null || true)}"
    [[ -n "$DOMAIN" && -n "$PUBLIC_IP" ]] || { err "Domain/public IP unknown; run a full install first."; exit 1; }
    setup_ios_profile
    systemctl reload-or-restart 5gpn-iosprofile.socket 2>/dev/null || systemctl enable --now 5gpn-iosprofile.socket 2>/dev/null || true
    print_qr
    ok "iOS profile regenerated: http://${GATEWAY_IP:-$PUBLIC_IP}:${IOS_PORT}/ios-dot.mobileconfig"
}

show_status() {
    {
        local domain pubip svc s opt pd
        domain="$(cat "${CONF_DIR}/.domain" 2>/dev/null || echo N/A)"
        pubip="$(cat "${CONF_DIR}/.public_ip" 2>/dev/null || echo N/A)"
        echo "📊 5gpn 状态"
        echo ""
        for svc in smartdns xray; do
            s="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
            echo "  $([[ "$s" == active ]] && echo '✅' || echo '❌') ${svc}  (${s})"
        done
        for opt in 5gpn-iosprofile.socket 5gpn-tgbot; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${opt}"; then
                s="$(systemctl is-active "$opt" 2>/dev/null || echo unknown)"
                echo "  $([[ "$s" == active ]] && echo '✅' || echo '❌') ${opt}  (${s})"
            fi
        done
        echo ""
        echo "  域名      $domain"
        echo "  公网 IP   $pubip"
        echo "  DoT       tls://${domain}:853"
        pd=0; [[ -f "${SMARTDNS_DIR}/proxy-domains.txt" ]] && pd="$(grep -cvE '^[[:space:]]*(#|$)' "${SMARTDNS_DIR}/proxy-domains.txt" 2>/dev/null | head -n1 || echo 0)"
        echo "  强制代理域名  ${pd:-0}"
        if [[ -f "${SMARTDNS_DIR}/foreign-cidr.txt" ]]; then
            local f_lines now mtime f_age
            f_lines="$(grep -cvE '^[[:space:]]*(#|$)' "${SMARTDNS_DIR}/foreign-cidr.txt" 2>/dev/null | head -n1 || echo 0)"
            now=$(date +%s); mtime=$(stat -c %Y "${SMARTDNS_DIR}/foreign-cidr.txt" 2>/dev/null || echo "$now")
            f_age="$(( (now - mtime) / 3600 ))h"
            echo "  foreign-cidr  ${f_lines:-0} 行（age ${f_age}）"
        else
            echo "  foreign-cidr  缺失"
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
    detect_memory_profile
    ensure_swap
    get_public_ip
    GATEWAY_IP="${GATEWAY_IP:-$PUBLIC_IP}"   # client-facing addr (NPN: export internal 172.22 IP)
    mkdir -p "$CONF_DIR"; printf '%s' "$GATEWAY_IP" > "${CONF_DIR}/.gateway_ip"

    install_deps
    install_files
    # Drop the removed HTTP control API if a previous install left it behind.
    systemctl disable --now 5gpn-api 2>/dev/null || true
    rm -f /etc/systemd/system/5gpn-api.service
    install_xray

    # Persist memory profile knobs the renderer/scripts read.
    mkdir -p "$SMARTDNS_DIR"; echo "$CACHE_SIZE" > "${SMARTDNS_DIR}/.cache_size"

    resolve_domain
    verify_a_record
    install_smartdns_unit
    install_cert

    run_update_lists       # fetch china_ip_list, build foreign-cidr, render smartdns.conf
    run_setup_firewall     # DoT-only nft + xray unit
    system_tuning
    setup_ios_profile
    start_services

    echo ""
    ok "5gpn install complete."
    {
        echo "✅ 5gpn 安装完成"
        echo ""
        echo "  DoT 地址         tls://${DOMAIN}:853"
        echo "  Android 私人DNS  ${DOMAIN}"
        echo "  iOS 描述文件      http://${GATEWAY_IP:-$PUBLIC_IP}:${IOS_PORT}/ios-dot.mobileconfig"
    } | card
    print_qr
    echo ""
    info "Optional: '$0 --setup-tgbot' to set up the Telegram control bot."
}

# ----------------------------------------------------------------------------
# Usage / dispatch
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
5gpn installer (exit-less DoT gateway)

Usage: sudo bash install.sh [option]

  (no args)           Full install / idempotent re-run
  --update-lists      Refresh china_ip_list + foreign-cidr, re-render smartdns.conf
  --status            Show service states, domain, IP, list counts/age
  --add-domain <d>    Force-proxy a domain (adds to proxy-domains.txt)
  --del-domain <d>    Remove a domain from the forced-proxy list
  --ios               Regenerate the iOS profile + QR
  --setup-tgbot       Install + enable the Telegram control bot
  --help              This help

Env overrides: DOMAIN=, PUBLIC_IP=, GATEWAY_IP=, EMAIL=, LOWMEM=1|0,
               CLIENT_NET=172.22.0.0/16, XRAY_RESOLVER=22.22.22.22,
               TGBOT_TOKEN=, TGBOT_ADMINS=
EOF
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        ""|install)     full_install ;;
        --update-lists) do_update_lists ;;
        --status)       show_status ;;
        --add-domain)   add_domain "${2:-}" ;;
        --del-domain)   del_domain "${2:-}" ;;
        --ios)          regen_ios ;;
        --setup-tgbot)  setup_tgbot ;;
        --help|-h)      usage ;;
        *)              err "Unknown option: $cmd"; echo ""; usage; exit 2 ;;
    esac
}

main "$@"
