#!/bin/bash
# Let's Encrypt renewal hook - copy certs to the smartdns-readable location and
# restart. smartdns reads /etc/smartdns/cert/{fullchain.pem,privkey.pem} for the
# DoT (DNS-over-TLS) listener; it has no signal-based reload, so we restart it.
set -e

CERT_DIR=/etc/smartdns/cert

# certbot exports RENEWED_LINEAGE (the lineage being renewed) to deploy hooks —
# prefer it for a deterministic choice. Fall back to the newest live dir only if
# the hook is run manually (no RENEWED_LINEAGE in the environment).
LIVE_DIR="${RENEWED_LINEAGE:-}"
if [[ -z "$LIVE_DIR" ]]; then
    LIVE_DIR=$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | head -n1)
fi
if [[ -z "$LIVE_DIR" || ! -f "${LIVE_DIR}/fullchain.pem" ]]; then
    echo "[!] No certificate live directory found"
    exit 1
fi

mkdir -p "$CERT_DIR"
cp "${LIVE_DIR}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
cp "${LIVE_DIR}/privkey.pem" "${CERT_DIR}/privkey.pem"
chmod 640 "${CERT_DIR}"/*.pem

# smartdns commonly runs as root, but chown to its service user if one exists.
if id smartdns >/dev/null 2>&1; then
    chown -R smartdns:smartdns "$CERT_DIR/"
fi

if systemctl is-active --quiet smartdns; then
    systemctl restart smartdns   # smartdns has no hot-reload; restart applies the new cert
fi
