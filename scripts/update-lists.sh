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
china_whitelist="$SMARTDNS_DIR/china-whitelist.conf"
bogus="$SMARTDNS_DIR/bogus-nxdomain.conf"
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

# Generator refuses (exit 1) on a too-small list, leaving old foreign intact.
python3 "$HERE/gen_foreign_cidr.py" "$china" "$foreign"

# Anti-pollution whitelist: domestic resolvers may only return these (China) IPs.
# Regenerate from the china list; keep the old file if china is unusable (an empty
# whitelist would make every domain look foreign -> everything proxied).
if grep -Eq '^[0-9]' "$china" 2>/dev/null; then
    tmpw="$china_whitelist.tmp"
    grep -E '^[0-9]' "$china" | sed 's/^/whitelist-ip /' > "$tmpw" && mv "$tmpw" "$china_whitelist"
fi
# conf-file includes must always exist or smartdns refuses to start.
[ -f "$china_whitelist" ] || printf '# (regenerate via update-lists.sh)\n' > "$china_whitelist"
[ -f "$bogus" ] || printf '# bogus-nxdomain poison IPs (operator-editable)\n' > "$bogus"

python3 "$HERE/render_smartdns_conf.py" \
    "$ROOT/etc/smartdns.conf.template" "$SMARTDNS_DIR/smartdns.conf" \
    GATEWAY_IP="$GATEWAY_IP" \
    BIND_CERT="$SMARTDNS_DIR/cert/fullchain.pem" \
    BIND_KEY="$SMARTDNS_DIR/cert/privkey.pem" \
    PROXY_DOMAINS_FILE="$SMARTDNS_DIR/proxy-domains.txt" \
    FOREIGN_CIDR_FILE="$foreign" \
    CHINA_WHITELIST_FILE="$china_whitelist" \
    BOGUS_NXDOMAIN_FILE="$bogus" \
    CACHE_SIZE="$CACHE_SIZE"

if [ "$DRY_RUN" != "1" ]; then
    systemctl restart smartdns
fi
ok "lists updated (gateway=$GATEWAY_IP, dry_run=$DRY_RUN)"
