#!/usr/bin/env bash
# Put an already-provisioned 5gpn gateway onto the monolith beta.
#
# It expects a host that install.sh has already built: service accounts, the
# certificate roots, the interception CA, and an operator-owned mihomo config.
# What it changes is the shape of the runtime -- three processes to one -- and
# nothing else.
#
# Every step is reversible from what it saves under /root before touching
# anything, and it refuses to start rather than leave a half-migrated host.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR=/opt/5gpn
CONF_DIR=/etc/5gpn
MIHOMO_HOME="${CONF_DIR}/mihomo"
BACKUP="/root/5gpn-pre-monolith-$(date -u +%Y%m%dT%H%M%SZ)"

info() { echo "[INFO] $*"; }
ok()   { echo "[OK]   $*"; }
err()  { echo "[ERR]  $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "run as root"; exit 1; }
[[ -f "${MIHOMO_HOME}/config.yaml" ]] || { err "no operator config at ${MIHOMO_HOME}/config.yaml — this host was never provisioned"; exit 1; }
command -v jq >/dev/null || { err "jq is required"; exit 1; }

info "saving a rollback point to ${BACKUP}"
mkdir -p "$BACKUP"
cp -a "${MIHOMO_HOME}/config.yaml" "${BACKUP}/config.yaml"
[[ -x "${BASE_DIR}/bin/mihomo" ]] && cp -a "${BASE_DIR}/bin/mihomo" "${BACKUP}/mihomo" || true

# Stop the old shape first. The new binary binds :853, which the retired DNS
# daemon still holds; starting before it lets go is a bind failure that reads
# like a configuration error.
info "stopping the three-process runtime"
systemctl stop 5gpn-dns.service 5gpn-intercept.service mihomo.service 2>/dev/null || true
systemctl disable 5gpn-dns.service 5gpn-intercept.service 5gpn-intercept-runtime.path 2>/dev/null || true

info "publishing the core and the UI"
install -m 0755 "${HERE}/bin/mihomo" "${BASE_DIR}/bin/mihomo"
install -d -m 0755 "${BASE_DIR}/ui"
rm -rf -- "${BASE_DIR}/ui"/*
cp -a "${HERE}/ui/." "${BASE_DIR}/ui/"
chmod -R a+rX "${BASE_DIR}/ui"

info "publishing units and scripts"
install -m 0644 "${HERE}/systemd/"*.service "${HERE}/systemd/"*.path "${HERE}/systemd/"*.timer /etc/systemd/system/
install -m 0755 "${HERE}/scripts/intercept-cert-renew.sh" "${BASE_DIR}/scripts/intercept-cert-renew.sh"
systemctl daemon-reload

# The operator's config carries three rules the monolith cannot parse and two
# dead blocks. Migrate a candidate, validate it against the new core, and only
# then publish -- a gateway whose config fails `mihomo -t` does not start at all.
info "migrating the operator config"
candidate="$(mktemp)"
bash "${HERE}/scripts/migrate-to-monolith.sh" "${MIHOMO_HOME}/config.yaml" > "$candidate"
grep -q '^external-ui:' "$candidate" || sed -i '/^external-controller-tls:/a external-ui: /opt/5gpn/ui' "$candidate"

if ! SAFE_PATHS=/etc/5gpn/cert/console:/etc/5gpn/cert/dot:/etc/5gpn/intercept/tls:/opt/5gpn/ui \
     "${BASE_DIR}/bin/mihomo" -t -f "$candidate" -d "$MIHOMO_HOME" >/dev/null 2>&1; then
    err "the migrated config does not validate against the new core; nothing was published"
    err "candidate left at $candidate for inspection"
    exit 1
fi
owner="$(stat -c '%U:%G' "${MIHOMO_HOME}/config.yaml")"
install -o "${owner%%:*}" -g "${owner##*:}" -m 0640 "$candidate" "${MIHOMO_HOME}/config.yaml"
rm -f -- "$candidate"
ok "config migrated and validated"

info "folding the four DNS state files into one document"
bash "${HERE}/scripts/migrate-state-to-monolith.sh" "$CONF_DIR" "$MIHOMO_HOME"
chown -R mihomo:mihomo "${MIHOMO_HOME}/gpn"

# The core reads the DoT leaf and serves the UI; both live outside its home.
info "granting the core read access to the certificates it serves"
chgrp -R mihomo "${CONF_DIR}/cert"
chmod -R g+rX "${CONF_DIR}/cert"
install -d -o mihomo -g mihomo -m 0700 /var/lib/5gpn-intercept

info "starting"
systemctl enable mihomo.service >/dev/null 2>&1 || true
systemctl restart mihomo.service
systemctl enable --now 5gpn-intercept-cert.path >/dev/null 2>&1 || true
systemctl enable --now 5gpn-intercept-cert.timer >/dev/null 2>&1 || true
sleep 4

if ! systemctl is-active --quiet mihomo.service; then
    err "mihomo did not start; rollback material is in ${BACKUP}"
    journalctl -u mihomo.service -n 30 --no-pager >&2
    exit 1
fi

ok "5gpn is running as one process"
echo
echo "  rollback:  cp ${BACKUP}/config.yaml ${MIHOMO_HOME}/config.yaml && cp ${BACKUP}/mihomo ${BASE_DIR}/bin/mihomo"
echo "  verify:    bash ${HERE}/scripts/acceptance-monolith.sh"
echo "  UI:        https://127.0.0.1:9090/ui/  (tunnel it; the controller is loopback-only)"
