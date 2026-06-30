#!/usr/bin/env bash
# Refresh chnroute foreign set + render smartdns.conf, then restart smartdns.
# DRY_RUN=1 skips download (uses existing china file) and skips restart.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."

# --- Gum-or-echo status helpers (gum when on PATH + interactive; else plain echo).
# Installing gum is install.sh's job (install_gum); here we only detect + use it. ---
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [ "$_HAVE_GUM" = 1 ]; then gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [ "$_HAVE_GUM" = 1 ]; then gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [ "$_HAVE_GUM" = 1 ]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }
# Spinner only wraps the opaque download (its stdout is not operator-facing);
# the rendered conf + the final "lists updated" line stay on the terminal.
gum_spin() { local t="$1"; shift; if [ "$_HAVE_GUM" = 1 ] && [ -t 1 ]; then gum spin --title "$t" -- "$@"; else "$@"; fi; }

SMARTDNS_DIR="${SMARTDNS_DIR:-/etc/smartdns}"
GATEWAY_IP="${GATEWAY_IP:-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo 127.0.0.1)}"
CHINA_IP_URL="${CHINA_IP_URL:-https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt}"
CACHE_SIZE="${CACHE_SIZE:-20000}"
DRY_RUN="${DRY_RUN:-0}"

china="$SMARTDNS_DIR/china_ip_list.txt"
foreign="$SMARTDNS_DIR/foreign-cidr.txt"
china_ipset="$SMARTDNS_DIR/china_ip.conf"
china_domains="$SMARTDNS_DIR/china-domains.txt"
bogus="$SMARTDNS_DIR/bogus-nxdomain.conf"
CHINA_DOMAINS_URL="${CHINA_DOMAINS_URL:-https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf}"
MIN_CN_DOMAINS="${MIN_CN_DOMAINS:-10000}"
mkdir -p "$SMARTDNS_DIR"

if [ "$DRY_RUN" != "1" ]; then
    tmp="$china.tmp"
    if gum_spin "下载 china_ip_list…" wget -qO "$tmp" "$CHINA_IP_URL"; then
        mv "$tmp" "$china"
    else
        warn "china_ip_list download failed; keeping existing $china"
        rm -f "$tmp"
    fi
fi

# Mainland domain whitelist (felixonmars accelerated-domains). Lines look like:
#   server=/example.cn/114.114.114.114  -> extract the domain. Keep old on failure.
if [ "$DRY_RUN" != "1" ]; then
    tmpd="$china_domains.dl"
    if gum_spin "下载 china domains…" wget -qO "$tmpd" "$CHINA_DOMAINS_URL"; then
        tmpx="$china_domains.tmp"
        sed -n 's|^server=/\([^/]*\)/.*|\1|p' "$tmpd" | sort -u > "$tmpx"
        n=$(grep -c . "$tmpx" 2>/dev/null || echo 0)
        if [ "$n" -ge "$MIN_CN_DOMAINS" ]; then mv "$tmpx" "$china_domains"
        else warn "china-domains too small ($n < $MIN_CN_DOMAINS); keeping existing"; rm -f "$tmpx"; fi
        rm -f "$tmpd"
    else
        warn "china domains download failed; keeping existing $china_domains"
        rm -f "$tmpd"
    fi
fi
# domain-set -file must exist or smartdns refuses to start.
[ -f "$china_domains" ] || printf '# (regenerate via update-lists.sh)\n' > "$china_domains"

# Generator refuses (exit 1) on a too-small list, leaving old foreign intact.
python3 "$HERE/gen_foreign_cidr.py" "$china" "$foreign"

# China IP set for tier-3 prefer-CN (ip-rules ip-set:china_ip -whitelist-ip).
# Plain CIDR list from china_ip_list; keep old if china is unusable.
if grep -Eq '^[0-9]' "$china" 2>/dev/null; then
    tmpc="$china_ipset.tmp"
    grep -E '^[0-9]' "$china" > "$tmpc" && mv "$tmpc" "$china_ipset"
fi
# conf-file / *-file includes must always exist or smartdns refuses to start.
[ -f "$china_ipset" ] || printf '# (regenerate via update-lists.sh)\n' > "$china_ipset"
[ -f "$bogus" ]       || printf '# bogus-nxdomain poison IPs (operator-editable)\n' > "$bogus"

python3 "$HERE/render_smartdns_conf.py" \
    "$ROOT/etc/smartdns.conf.template" "$SMARTDNS_DIR/smartdns.conf" \
    GATEWAY_IP="$GATEWAY_IP" \
    BIND_CERT="$SMARTDNS_DIR/cert/fullchain.pem" \
    BIND_KEY="$SMARTDNS_DIR/cert/privkey.pem" \
    PROXY_DOMAINS_FILE="$SMARTDNS_DIR/proxy-domains.txt" \
    FOREIGN_CIDR_FILE="$foreign" \
    CHINA_DOMAINS_FILE="$china_domains" \
    CHINA_IP_FILE="$china_ipset" \
    BOGUS_NXDOMAIN_FILE="$bogus" \
    CACHE_SIZE="$CACHE_SIZE"

if [ "$DRY_RUN" != "1" ]; then
    systemctl restart smartdns
fi
ok "lists updated (gateway=$GATEWAY_IP, dry_run=$DRY_RUN)"
