#!/bin/bash
# Offline check of the lineage validators against the real Certbot output that
# the first live DNS-01 run left in fivegpn-data. Costs no ACME order and needs
# no published ports, so it can run while the host gateway is up.
set -uo pipefail

IMG="5gpn-release-candidate:663978bccb574b7596dc946736eb0a8532416cfc"
FIXED=/root/lineage-fix/docker-public-cert.sh

echo "=== snapshot the pristine post-certbot volume ==="
docker volume rm -f fivegpn-data-probe >/dev/null 2>&1
docker volume create fivegpn-data-probe >/dev/null
docker run --rm --user 0:0 --entrypoint /bin/bash \
    -v fivegpn-data:/from:ro -v fivegpn-data-probe:/to "$IMG" \
    -c 'cp -a /from/. /to/ && echo copied' || exit 1

echo
echo "=== run the validators as uid 10001 against the copy ==="
docker run --rm --entrypoint /bin/bash \
    -v fivegpn-data-probe:/etc/5gpn \
    -v "$FIXED":/tmp/fixed-public-cert.sh:ro \
    --tmpfs /run/5gpn:uid=10001,gid=10001,mode=0700 \
    --tmpfs /run/5gpn-bootstrap:uid=10001,gid=10001,mode=0700 \
    --tmpfs /tmp2:uid=10001,gid=10001,mode=1777 \
    -e FIVEGPN_RUNTIME=container \
    "$IMG" -c '
set +e
printf "DNS_BASE_DOMAIN=test.5gpn.de\nDNS_GATEWAY_IP=10.0.1.20\nCERT_EMAIL=admin@5gpn.de\nCERT_MODE=cloudflare\n" \
    > /run/5gpn-bootstrap/config.env
chmod 600 /run/5gpn-bootstrap/config.env
export DOCKER_PUBLIC_CERT_LIB_ONLY=1
source /tmp/fixed-public-cert.sh
echo "uid=$(id -u) gid=$(id -g)"
load_configuration && echo "load_configuration          PASS" || echo "load_configuration          FAIL"
echo "BASE_DOMAIN=$BASE_DOMAIN"
lineage_set_is_exclusive     && echo "lineage_set_is_exclusive    PASS" || echo "lineage_set_is_exclusive    FAIL"
renewal_conf_safe            && echo "renewal_conf_safe           PASS" || echo "renewal_conf_safe           FAIL"
live_lineage_tree_safe       && echo "live_lineage_tree_safe      PASS" || echo "live_lineage_tree_safe      FAIL"
scan_complete_archive_generations && echo "scan_complete_archive_gens  PASS (${COMPLETE_ARCHIVE_GENERATIONS[*]})" || echo "scan_complete_archive_gens  FAIL"
recover_live_lineage         && echo "recover_live_lineage        PASS" || echo "recover_live_lineage        FAIL"
archive_lineage_safe         && echo "archive_lineage_safe        PASS" || echo "archive_lineage_safe        FAIL"
validate_live_cert_pair "$LE_LIVE_ROOT/$BASE_DOMAIN" 0 && echo "validate_live_cert_pair     PASS" || echo "validate_live_cert_pair     FAIL"
echo "-----"
live_lineage_safe            && echo ">>> live_lineage_safe       PASS" || echo ">>> live_lineage_safe       FAIL"
lineage_structure_safe       && echo ">>> lineage_structure_safe  PASS" || echo ">>> lineage_structure_safe  FAIL"
'
