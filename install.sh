#!/usr/bin/env bash
# 5gpn installer / orchestrator (DNS-steering architecture).
#
#   client DoT:853 (the ONLY DNS transport) -> 5gpn-mihomo 5gpn/dns (NXDOMAIN for
#   block, real IP for direct, gateway IP for proxy/foreign) -> mihomo tunnel
#   (:80/:443/:8080/:8443) sniffs HTTP Host or TLS SNI
#   (sniffer override-destination), then the loopback DNS broker resolves the
#   real IP through an extension's operator-selected China/trust group (trust by
#   default) before mihomo applies its operator-owned policy.
#   mihomo also serves the console panel and authenticated controller at
#   console.<base> through its loopback :443 listener.
#
# One base domain and one scoped production cert lineage:
#   BASE_DOMAIN  -> the operator's ONE apex domain (the single knob).
#   CONSOLE_DOMAIN/DOT_DOMAIN
#     (= console./dot.<BASE_DOMAIN>)
#     are auto-derived subdomains (derive_domains). Cloudflare DNS-01 issues
#     `*.<base>` + `<base>`; HTTP-01 issues the two exact service SANs because
#     HTTP-01 cannot issue wildcards. HTTP-01 waits for both A records via
#     1.1.1.1, then briefly releases mihomo's :80 listener for issuance/renewal.
#     Auto-renewal is unattended via the daily scoped certbot timer.
#     CERT_MODE=debug issues a self-signed wildcard instead (test/dev boxes).
#
# HTTP/3 interception is unsupported. Fresh and explicitly reset mihomo seeds
# keep a fixed global UDP/443 REJECT rule with no product-management off switch.
# Clients that support fallback use TCP with HTTP/1.1 or HTTP/2; H3-only clients
# fail closed. This does not disable unrelated UDP traffic or QUIC sniffing on
# other ports. There is no separate daemon-managed exit layer. 5gpn never
# manages the host firewall; use your provider's security group if you want
# one. The console serves the public panel and controller-secret-protected
# routes on one origin.
#
# There is NO network-layer exit: no WireGuard, no fwmark / ip-rule / table-100.
# Do not add any of those (application-layer exits live in mihomo's rule engine).
#
# Every run stages and validates pinned artifacts before publication. Persisted
# operator state and a valid operator-owned mihomo config are preserved. A
# failure before publication leaves the host untouched; a failure during
# publication is reported as partial rather than claiming whole-system rollback.
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Paths & constants
# ----------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || echo "${BASH_SOURCE[0]:-}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"   # repo 5gpn/ when run from a checkout
BASE_DIR="/opt/5gpn"                 # installed runtime root
# Release packaging replaces these development sentinels with the SHA-256 pair
# for release/pins.env + release/pins.sh and the separate quick-install.sh
# digest. They are derived generation bindings, not component authorities.
RELEASE_PINS_BINDING="development"
RELEASE_QUICK_BINDING="development"
RELEASE_PINS_BUNDLE_DIR="${SCRIPT_DIR}/release"
RELEASE_PINS_ENV="${RELEASE_PINS_BUNDLE_DIR}/pins.env"
RELEASE_PINS_LIBRARY="${RELEASE_PINS_BUNDLE_DIR}/pins.sh"
RELEASE_QUICK_PATH="${SCRIPT_DIR}/quick-install.sh"
RELEASE_PINS_SNAPSHOT_DIR=""
RELEASE_PINS_BUNDLE_ENV_STATE=""
RELEASE_PINS_BUNDLE_LIBRARY_STATE=""
RELEASE_PINS_SNAPSHOT_ENV_STATE=""
RELEASE_PINS_SNAPSHOT_LIBRARY_STATE=""
RELEASE_PINS_ENV_REVISION=""
RELEASE_PINS_LIBRARY_REVISION=""
RELEASE_PINS_ENV_SNAPSHOT_B64=""
RELEASE_PINS_LIBRARY_SNAPSHOT_B64=""
RELEASE_QUICK_BUNDLE_STATE=""
RELEASE_QUICK_REVISION=""
INSTALLED_BACKEND_SCRIPT_STATE=""

release_pin_file_state() { # release_pin_file_state <plain-file>
    local file="$1" metadata digest
    [[ -f "$file" && ! -L "$file" ]] || return 1
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$file" 2>/dev/null)" \
        || return 1
    [[ "${metadata##*:}" == 1 ]] || return 1
    digest="$(sha256sum -- "$file" 2>/dev/null | awk '{print $1}')" \
        || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s:%s\n' "$metadata" "$digest"
}

cleanup_release_pin_snapshot() {
    local dir="${RELEASE_PINS_SNAPSHOT_DIR:-}" uid mode
    [[ -n "$dir" ]] || return 0
    case "$dir" in /var/tmp/5gpn-release-pins.*) ;; *) return 1 ;; esac
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    uid="$(stat -Lc '%u' -- "$dir" 2>/dev/null)" || return 1
    mode="$(stat -Lc '%a' -- "$dir" 2>/dev/null)" || return 1
    [[ "$uid" == "$(id -u)" && "$mode" == 700 ]] || return 1
    rm -f -- "$dir/pins.env" "$dir/pins.sh" || return 1
    rmdir -- "$dir" || return 1
    RELEASE_PINS_SNAPSHOT_DIR=""
}

capture_release_pin_pair() { # capture_release_pin_pair <bundle-release-dir>
    local origin_dir="$1" origin_canonical env library snapshot
    local before_env before_library after_env after_library snapshot_env snapshot_library
    [[ -d "$origin_dir" && ! -L "$origin_dir" ]] || return 1
    origin_canonical="$(readlink -f -- "$origin_dir" 2>/dev/null)" || return 1
    [[ "$origin_canonical" == "$origin_dir" ]] || return 1
    env="$origin_dir/pins.env"
    library="$origin_dir/pins.sh"
    before_env="$(release_pin_file_state "$env")" || return 1
    before_library="$(release_pin_file_state "$library")" || return 1

    snapshot="$(mktemp -d /var/tmp/5gpn-release-pins.XXXXXX)" || return 1
    chmod 0700 "$snapshot" \
        || { rmdir -- "$snapshot" 2>/dev/null || true; return 1; }
    if ! install -m 0600 -- "$env" "$snapshot/pins.env" \
       || ! install -m 0600 -- "$library" "$snapshot/pins.sh"; then
        rm -f -- "$snapshot/pins.env" "$snapshot/pins.sh"
        rmdir -- "$snapshot" 2>/dev/null || true
        return 1
    fi

    snapshot_env="$(release_pin_file_state "$snapshot/pins.env")" || {
        rm -f -- "$snapshot/pins.env" "$snapshot/pins.sh"; rmdir -- "$snapshot" 2>/dev/null || true; return 1;
    }
    snapshot_library="$(release_pin_file_state "$snapshot/pins.sh")" || {
        rm -f -- "$snapshot/pins.env" "$snapshot/pins.sh"; rmdir -- "$snapshot" 2>/dev/null || true; return 1;
    }
    after_env="$(release_pin_file_state "$env")" || {
        rm -f -- "$snapshot/pins.env" "$snapshot/pins.sh"; rmdir -- "$snapshot" 2>/dev/null || true; return 1;
    }
    after_library="$(release_pin_file_state "$library")" || {
        rm -f -- "$snapshot/pins.env" "$snapshot/pins.sh"; rmdir -- "$snapshot" 2>/dev/null || true; return 1;
    }
    if [[ "$before_env" != "$after_env" \
       || "$before_library" != "$after_library" \
       || "${snapshot_env##*:}" != "${before_env##*:}" \
       || "${snapshot_library##*:}" != "${before_library##*:}" ]]; then
        rm -f -- "$snapshot/pins.env" "$snapshot/pins.sh"
        rmdir -- "$snapshot" 2>/dev/null || true
        return 1
    fi

    RELEASE_PINS_SNAPSHOT_DIR="$snapshot"
    RELEASE_PINS_BUNDLE_ENV_STATE="$after_env"
    RELEASE_PINS_BUNDLE_LIBRARY_STATE="$after_library"
    RELEASE_PINS_SNAPSHOT_ENV_STATE="$snapshot_env"
    RELEASE_PINS_SNAPSHOT_LIBRARY_STATE="$snapshot_library"
    RELEASE_PINS_ENV_REVISION="${snapshot_env##*:}"
    RELEASE_PINS_LIBRARY_REVISION="${snapshot_library##*:}"
    RELEASE_PINS_ENV="$snapshot/pins.env"
    RELEASE_PINS_LIBRARY="$snapshot/pins.sh"
}

assert_release_pin_bundle_revision() {
    local env_state library_state
    env_state="$(release_pin_file_state "$RELEASE_PINS_BUNDLE_DIR/pins.env")" \
        || { printf 'Release pin manifest metadata is unsafe or unreadable.\n' >&2; return 1; }
    library_state="$(release_pin_file_state "$RELEASE_PINS_BUNDLE_DIR/pins.sh")" \
        || { printf 'Release pin parser metadata is unsafe or unreadable.\n' >&2; return 1; }
    [[ "$env_state" == "$RELEASE_PINS_BUNDLE_ENV_STATE" \
       && "$library_state" == "$RELEASE_PINS_BUNDLE_LIBRARY_STATE" ]] \
        || { printf 'Release pin files changed after their private snapshot was loaded.\n' >&2; return 1; }
}

validate_quick_installer_generation() {
    local quick_state quick_revision
    quick_state="$(release_pin_file_state "$RELEASE_QUICK_PATH")" \
        || { err "Quick installer is missing, linked, or unreadable; use the verified external installer."; return 1; }
    quick_revision="${quick_state##*:}"
    if [[ "$SCRIPT_DIR" == "$BASE_DIR" ]]; then
        [[ "$(stat -Lc '%u:%g:%a:%h' "$RELEASE_QUICK_PATH" 2>/dev/null)" == 0:0:755:1 ]] \
            || { err "Installed quick installer metadata is unsafe; use the verified external installer."; return 1; }
    fi
    if [[ "$RELEASE_QUICK_BINDING" == development ]]; then
        [[ "$SCRIPT_DIR" != "$BASE_DIR" ]] \
            || { err "Installed quick installer has no immutable generation binding."; return 1; }
        return 0
    fi
    [[ "$RELEASE_QUICK_BINDING" =~ ^[0-9a-f]{64}$ \
       && "$quick_revision" == "$RELEASE_QUICK_BINDING" ]] \
        || { err "Quick installer does not match this release generation; use the verified external installer."; return 1; }
}

installed_backend_stamped_release_tag() {
    local tag
    local -a tags=()
    mapfile -t tags < <(sed -n 's/^RELEASE_TAG="\([^"]*\)"$/\1/p' "$SCRIPT_PATH")
    [[ "${#tags[@]}" == 1 ]] || return 1
    tag="${tags[0]}"
    [[ "$tag" != latest ]] && valid_release_tag "$tag" || return 1
    printf '%s\n' "$tag"
}

assert_installed_backend_revision() {
    local script_state stamped_tag
    [[ "$SCRIPT_DIR" == "$BASE_DIR" ]] || return 0
    [[ "${RELEASE_TAG:-latest}" != latest ]] && valid_release_tag "$RELEASE_TAG" \
        || { err "The installed management backend has no immutable release stamp; use the verified external installer."; return 1; }
    stamped_tag="$(installed_backend_stamped_release_tag)" \
        || { err "The installed management backend release stamp is missing or ambiguous; use the verified external installer."; return 1; }
    [[ "$stamped_tag" == "$RELEASE_TAG" ]] \
        || { err "The installed management backend changed while this command was starting; rerun 5gpn."; return 1; }
    script_state="$(release_pin_file_state "$SCRIPT_PATH")" \
        || { err "The installed management backend is missing or unsafe; rerun the verified external installer."; return 1; }
    [[ "$script_state" == "$INSTALLED_BACKEND_SCRIPT_STATE" ]] \
        || { err "The installed management backend changed while this command was queued; rerun 5gpn."; return 1; }
    assert_release_pin_bundle_revision \
        || { err "The installed release pins changed while this command was queued; rerun 5gpn."; return 1; }
}

if [[ "$SCRIPT_DIR" == "$BASE_DIR" ]]; then
    if [[ "$(stat -c '%u:%g:%a' "$BASE_DIR" 2>/dev/null)" != 0:0:755 \
       || "$(stat -c '%u:%g:%a' "$RELEASE_PINS_BUNDLE_DIR" 2>/dev/null)" != 0:0:755 \
       || "$(stat -c '%u:%g:%a:%h' "$SCRIPT_PATH" 2>/dev/null)" != 0:0:755:1 \
       || "$(stat -c '%u:%g:%a:%h' "$RELEASE_PINS_ENV" 2>/dev/null)" != 0:0:644:1 \
       || "$(stat -c '%u:%g:%a:%h' "$RELEASE_PINS_LIBRARY" 2>/dev/null)" != 0:0:644:1 ]]; then
        printf 'Installed release pin metadata is unsafe below %s.\n' "$RELEASE_PINS_BUNDLE_DIR" >&2
        exit 1
    fi
fi
capture_release_pin_pair "$RELEASE_PINS_BUNDLE_DIR" \
    || { printf 'Could not capture one stable release pin pair below %s.\n' "$RELEASE_PINS_BUNDLE_DIR" >&2; exit 1; }
if [[ "$RELEASE_PINS_BINDING" == development ]]; then
    if [[ "$SCRIPT_DIR" == "$BASE_DIR" ]]; then
        cleanup_release_pin_snapshot || true
        printf 'Installed management backend has no immutable release-pin generation binding.\n' >&2
        exit 1
    fi
elif [[ "$RELEASE_PINS_BINDING" =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]]; then
    if [[ "$RELEASE_PINS_BINDING" != "${RELEASE_PINS_ENV_REVISION}:${RELEASE_PINS_LIBRARY_REVISION}" ]]; then
        cleanup_release_pin_snapshot || true
        printf 'Release pin files do not match the installer generation binding.\n' >&2
        exit 1
    fi
else
    cleanup_release_pin_snapshot || true
    printf 'Installer release-pin generation binding is malformed.\n' >&2
    exit 1
fi
if [[ "$SCRIPT_DIR" != "$BASE_DIR" ]]; then
    RELEASE_QUICK_BUNDLE_STATE="$(release_pin_file_state "$RELEASE_QUICK_PATH")" \
        || { cleanup_release_pin_snapshot || true; printf 'Could not fingerprint the bundled quick installer.\n' >&2; exit 1; }
    RELEASE_QUICK_REVISION="${RELEASE_QUICK_BUNDLE_STATE##*:}"
    if [[ "$RELEASE_QUICK_BINDING" == development ]]; then
        :
    elif [[ "$RELEASE_QUICK_BINDING" =~ ^[0-9a-f]{64}$ \
         && "$RELEASE_QUICK_BINDING" == "$RELEASE_QUICK_REVISION" ]]; then
        :
    else
        cleanup_release_pin_snapshot || true
        printf 'Quick installer does not match the installer generation binding.\n' >&2
        exit 1
    fi
fi
# shellcheck source=release/pins.sh
if ! source "$RELEASE_PINS_LIBRARY" \
   || ! load_release_pins "$RELEASE_PINS_ENV" \
   || [[ "$(release_pin_file_state "$RELEASE_PINS_ENV")" != "$RELEASE_PINS_SNAPSHOT_ENV_STATE" ]] \
   || [[ "$(release_pin_file_state "$RELEASE_PINS_LIBRARY")" != "$RELEASE_PINS_SNAPSHOT_LIBRARY_STATE" ]]; then
    cleanup_release_pin_snapshot || true
    printf 'Release pin snapshot changed while it was being loaded.\n' >&2
    exit 1
fi
RELEASE_PINS_ENV_SNAPSHOT_B64="$(base64 -w0 -- "$RELEASE_PINS_ENV")" \
    || { cleanup_release_pin_snapshot || true; printf 'Could not retain the release pin manifest snapshot.\n' >&2; exit 1; }
RELEASE_PINS_LIBRARY_SNAPSHOT_B64="$(base64 -w0 -- "$RELEASE_PINS_LIBRARY")" \
    || { cleanup_release_pin_snapshot || true; printf 'Could not retain the release pin parser snapshot.\n' >&2; exit 1; }
cleanup_release_pin_snapshot \
    || { printf 'Could not clean the private release pin snapshot.\n' >&2; exit 1; }
RELEASE_PINS_ENV="${RELEASE_PINS_BUNDLE_DIR}/pins.env"
RELEASE_PINS_LIBRARY="${RELEASE_PINS_BUNDLE_DIR}/pins.sh"
if [[ "$SCRIPT_DIR" == "$BASE_DIR" ]]; then
    INSTALLED_BACKEND_SCRIPT_STATE="$(release_pin_file_state "$SCRIPT_PATH")" \
        || { printf 'Could not fingerprint the installed management backend.\n' >&2; exit 1; }
fi

BIN_DIR="${BASE_DIR}/bin"                # project-managed binaries; Gum survives uninstall for host reuse
SCRIPTS_DIR="${BASE_DIR}/scripts"        # installed copies of repo scripts
RELEASE_DIR="${BASE_DIR}/release"        # installed immutable artifact coordinates and strict parser
declare -ar MANAGED_SYSTEMD_UNITS=(
    5gpn-mihomo.service
    5gpn-intercept-cert.service
    5gpn-intercept-cert.path
    5gpn-intercept-cert.timer
    5gpn-certbot-renew.service
    5gpn-certbot-renew.timer
)
BASE_OWNERSHIP_MARKER=".5gpn-owned"
BASE_OWNERSHIP_VALUE="5gpn-runtime"

CONF_DIR="/etc/5gpn"                 # installation coordinates and current runtime state
CONF_OWNERSHIP_MARKER=".5gpn-owned"
CONF_OWNERSHIP_VALUE="5gpn-config"
STATE_DIR="/var/lib/5gpn"
STATE_OWNERSHIP_MARKER=".5gpn-owned"
STATE_OWNERSHIP_VALUE="5gpn-state"
IDENTITY_RECONCILE_FILE="${STATE_DIR}/identity-reconcile"
IDENTITY_RECONCILE_VERSION=2
SWAP_FILE="${STATE_DIR}/swapfile"
SWAP_FSTAB_MARKER="# 5gpn-owned-swap-v1"
SWAP_CREATED_THIS_RUN=0
DNS_CERT_DIR="/etc/5gpn/cert"            # selected cert copied into the current dot/ and console/ roles
# Certificate ownership values keep their revision suffix, and it is not dead
# weight. Every other 5gpn root self-heals -- claiming republishes whatever
# marker is there -- so its value can change freely. Certificate roots
# deliberately have no such path: their marker is the only thing that stops the
# installer adopting a directory of someone else's key material. Changing one of
# these strings therefore strands every existing host with no way back, so they
# are frozen rather than versioned, and test_install_policy.sh pins them.
DEBUG_CERT_DIR="/etc/5gpn/debug-cert"     # self-signed debug certs; NEVER under /etc/letsencrypt
DEBUG_CERT_MARKER=".5gpn-debug-cert-owned"
DEBUG_CERT_MARKER_VALUE="5gpn-debug-cert-v1"
DOT_CERT_DIR="${DNS_CERT_DIR}/dot"       # DoT :853 cert copy (hot-reloaded on mtime change)
CONSOLE_CERT_DIR="${DNS_CERT_DIR}/console"  # the controller TLS pair; mihomo serves the panel with it
DOT_LISTEN_ADDR=":853"
DEBUG_LISTEN_ADDR="127.0.0.1:5353"
ORIGIN_LISTEN_ADDR="127.0.0.1:5354"
MIHOMO_CONTROLLER_TLS_ADDR="127.0.0.1:443"
MIHOMO_CONTROLLER_CERT="${CONSOLE_CERT_DIR}/current/fullchain.pem"
MIHOMO_CONTROLLER_KEY="${CONSOLE_CERT_DIR}/current/privkey.pem"
MIHOMO_CONTROLLER_INSPECTION_VERSION=2
CERT_ROOT_MARKER=".5gpn-cert-root-owned"
CERT_ROOT_MARKER_VALUE="5gpn-cert-root-v1"
CERTBOT_OWNERSHIP_FILE="${DNS_CERT_DIR}/.certbot-ownership"
CERT_ROLE_MARKER=".5gpn-cert-role-owned"
CERT_ROLE_VALUE_PREFIX="5gpn-cert-role-v1"
ACME_DIR="/etc/5gpn/acme"                # root-only Cloudflare API-token credentials dir
# Original distro certbot.timer state captured before this transaction changes
# it. The snapshot is process-local and is cleared only after a successful
# restore or an intentional owned-lineage commit.
GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=""
GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=""
GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=""
GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE=""
GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED=""
CERTBOT_TIMER_LOAD_STATE=""
CERTBOT_TIMER_ACTIVE_STATE=""
CERTBOT_TIMER_UNIT_FILE_STATE=""
SYSTEMD_UNIT_LOAD_STATE=""
SYSTEMD_UNIT_ACTIVE_STATE=""
SYSTEMD_UNIT_FILE_STATE=""
LE_ROOT="/etc/letsencrypt"
LE_LIVE_ROOT="${LE_ROOT}/live"
LE_ARCHIVE_ROOT="${LE_ROOT}/archive"
LE_RENEWAL_ROOT="${LE_ROOT}/renewal"
CERT_DNS_RESOLVER="1.1.1.1"              # fixed independent resolver for ACME A/AAAA gates
CERT_DNS_WAIT_TIMEOUT=600                 # bounded install/configure propagation wait
CERT_DNS_WAIT_INTERVAL=10
# certbot writes the DNS-01 TXT record itself and then sleeps this long before
# asking Let's Encrypt to validate. It cannot be replaced by a check — the
# record does not exist until certbot creates it — and it is the only
# unconditional wait on the certificate path; our own DNS verification checks
# first and sleeps only after a failed check. Lower it if the zone's
# authoritative servers converge quickly; too low fails validation outright.
CERT_DNS_PROPAGATION_SECONDS=30
INSTALL_LOCK_FILE="/run/5gpn/install.lock"
CERT_RENEW_LOCK_FILE="/run/5gpn/cert-renew.lock"
CONFIGURE_RUNTIME_GATE_RECORD="/run/5gpn/configure-runtime-gate"
CONFIGURE_RUNTIME_GATE_JOB="/run/5gpn/configure-runtime-gate.job"
CONFIGURE_RUNTIME_GATE_ACK="/run/5gpn/configure-runtime-gate.ack"
CONFIGURE_RUNTIME_GATE_RELEASE="/run/5gpn/configure-runtime-gate.release"
CONFIGURE_RUNTIME_GATE_UNIT="5gpn-mihomo.service"
CONFIGURE_RUNTIME_GATE_QUIESCE_TIMEOUT=120
INSTALL_LOCK_WAIT_TIMEOUT=900
CERT_LOCK_WAIT_TIMEOUT=30
LOCK_WAIT_REPORT_INTERVAL=5
LE_PRODUCTION_SERVER="https://acme-v02.api.letsencrypt.org/directory"
INSTALL_LOCK_HELD=0
INSTALL_CERT_LOCK_HELD=0
INSTALL_PUBLICATION_STARTED=0
VALIDATED_DNS_SOURCE_REVISION=""
LOADED_DNS_ENV_SOURCE_STATE=""
LOADED_DNS_ENV_SOURCE_REVISION=""
LOADED_DNS_ENV_SOURCE_IDENTITY=""
# The transaction layer restores the pre-install distro certbot.timer state on
# every uncommitted exit and after non-owning certificate flows. Owned 5gpn
# renewal sets this flag only after its scoped timer is active.
KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=0
DECOMMISSION_PRESERVE_ACME=0
# Stable root for the zashboard/profile generation tree. The service sandbox
# grants this root, while the operator config names only its atomic `current`
# symlink. A dns.env key that could move either path would move it out from
# under the unit's fixed SAFE_PATHS and ReadOnlyPaths boundary.
UI_DIR="/opt/5gpn/ui"
UI_CURRENT_DIR="${UI_DIR}/current"
UI_GENERATION_CANDIDATE=""
UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
UI_GENERATION_HELPER_LOADED=0
CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=0
MIHOMO_BIN="${BIN_DIR}/5gpn-mihomo"
MIHOMO_DIR="/etc/5gpn/mihomo"           # config.yaml + provider caches
FIVEGPN_STATE_DIR="/etc/5gpn/mihomo/5gpn" # the engine's own documents, beside mihomo's
# What the interception leaf must cover, published by the engine after every
# successful write and once at startup. The versioned JSON carries the desired
# host-set digest, a random attempt fence, and the canonical host list. It is a
# file rather than a subcommand because its consumer is a root oneshot holding
# the CA signing key, and having that process execute the network-facing program
# to find out what to sign is a different shape from having it read what that
# program wrote.
# scripts/intercept-cert-renew.sh parses the same file.
CERT_REQUEST_FILE="${FIVEGPN_STATE_DIR}/certificate-request"
INTERCEPT_DIR="/etc/5gpn/intercept"
INTERCEPT_CA_DIR="/etc/5gpn/intercept-ca"
INTERCEPT_CA_MARKER=".5gpn-intercept-ca-owned"
INTERCEPT_CA_MARKER_VALUE="5gpn-intercept-ca-v1"
INTERCEPT_STATE_DIR="/var/lib/5gpn-intercept"
INTERCEPT_STATE_MARKER=".5gpn-intercept-state-owned"
INTERCEPT_STATE_MARKER_VALUE="5gpn-intercept-state"
FIVEGPN_SERVICE_USER="fivegpn"
FIVEGPN_SERVICE_GROUP="fivegpn"
REPLACED_FIVEGPN_UID=""
REPLACED_FIVEGPN_GID=""
REPLACED_FIVEGPN_NAMED_GID=""
FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=0
IDENTITY_RECONCILE_LOADED=0
ZASH_OWNERSHIP_MARKER=".5gpn-zashboard-owned"
ZASH_OWNERSHIP_VALUE="5gpn-ui-generations"
TEMP_OWNERSHIP_MARKER=".5gpn-temp-owned"
TEMP_OWNERSHIP_VALUE="5gpn-temp"
# The exact Core, Console, and Gum coordinates are loaded from the strict
# 14-key release/pins.env manifest above. release/pins.sh accepts only the
# approved repositories, release-tag shapes, asset templates, and lowercase
# SHA-256 values, and it alone constructs GitHub release download URLs.
#
# The current Core is upstream v1.19.28 plus the 5gpn monolith, built from
# moooyo/mihomo's
# feat/5gpn-monolith branch. This core does not merely add interception, it *is*
# the DNS engine, the interception engine, the data plane and the control API in
# one long-running process (plus isolated same-binary one-shot workers), so an
# upstream binary here does not degrade the install -- it
# leaves the gateway with no resolver, no capture and no control API at all. The
# staging probe checks the version token exactly rather than accepting a prefix.
# Every `mihomo -t` in this script must run with the same SAFE_PATHS the unit
# grants, because the seed names paths outside its own home directory -- the
# certificates it serves and the UI bundle it publishes. Without this the core
# refuses the config it will happily run once systemd starts it, so a fresh
# install fails its own preflight probe on a config that is correct.
#
# This value duplicates Environment=SAFE_PATHS in etc/systemd/5gpn-mihomo.service.
# The duplication is checked: test_mihomo_policy asserts the two agree, because
# a drift here fails at install time on a config the running service accepts.
MIHOMO_SAFE_PATHS="/etc/5gpn/cert/console:/etc/5gpn/cert/dot:/etc/5gpn/intercept/tls:/opt/5gpn/ui"
DNS_CHINA_DEFAULT="223.5.5.5"
DNS_TRUST_DEFAULT="22.22.22.22"
DNS_CHINA_ECS_DEFAULT="112.96.32.0/24"
DNS_CHINA_DOMAINS_DEFAULT="https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_Domain.yaml"
DNS_GFWLIST_DEFAULT="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"
DNS_SUBSCRIPTION_INTERVAL_DEFAULT=86400
readonly DNS_ENV_KEYS="DNS_BASE_DOMAIN DNS_PUBLIC_IP DNS_GATEWAY_IP DNS_MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL"
# EDNS Client Subnet uses the operational default above. Operators can disable
# or change it through the web console, which persists the runtime value.
GUM_BIN="${BIN_DIR}/gum"
_HAVE_GUM=0                              # set by install_gum(); helpers fall back to echo when 0
INSTALL_ORIGINAL_PATH="$PATH"
TEMP_GUM_DIR=""
TEMP_GUM_BIN=""

# The release this installer IS, on moooyo/5gpn. Not a component version, and no
# longer an artifact selector: the core and the UI bundle are released from their
# own repositories under their own digest pins, so nothing is drawn from this
# release but the installer bundle itself. Two decisions still read it.
#
#   1. The unpinned-source sentinel -- while it is literally `latest` this
#      script refuses to install and execs quick-install.sh instead, so the
#      channel is resolved once and the install comes from a verified bundle.
#   2. Channel delegation -- a stamped stable bundle asked for --beta hands off
#      rather than reusing its own pinned artifacts.
#
# The release pipeline STAMPS this exact line to the tag being cut (see
# .github/workflows/release.yml) and quick-install.sh validates the stamp from
# the outside -- one column-zero, double-quoted, uninterpolated assignment,
# read by awk and sed without ever sourcing the downloaded script. Reformatting
# this line breaks bundle validation even if the shell semantics are identical.
RELEASE_TAG="latest"
RELEASE_CHANNEL="stable"
RELEASE_CHANNEL_EXPLICIT=0
STABLE_RELEASE_API="https://api.github.com/repos/moooyo/5gpn/releases/latest"
RELEASES_API="https://api.github.com/repos/moooyo/5gpn/releases"
SERVICE_READY_TIMEOUT=20
ACCOUNT_QUIESCE_TIMEOUT=10
MIN_EXTENSION_WORKER_KERNEL_MAJOR=5
MIN_EXTENSION_WORKER_KERNEL_MINOR=7
MIN_EXTENSION_WORKER_SYSTEMD_VERSION=257
ACCOUNT_QUIESCE_INTERVAL=1

# ----------------------------------------------------------------------------
# Pretty output helpers
# ----------------------------------------------------------------------------
# Gum v0.17 probes terminal colors with OSC/CSI queries. Some otherwise valid
# TTYs do not answer those queries, making every short-lived Gum process pause
# for seconds. Scope CI=1 to Gum itself so it uses its non-querying renderer;
# do not export it across the installer process.
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
# One accent colour for every framed or emphasised surface: stage headings, card
# borders, and the selection cursor. Keeping it in a single place is what makes
# the installer read as one program rather than a pile of scripts.
UI_ACCENT=212
info() {
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        CI=1 gum log --level info -- "$*" || echo "${BLUE}[INFO]${NC} $*"
    else
        echo "${BLUE}[INFO]${NC} $*"
    fi
}
ok() {
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        CI=1 gum log --level info -- "✔ $*" || echo "${GREEN}[OK]${NC}   $*"
    else
        echo "${GREEN}[OK]${NC}   $*"
    fi
}
warn() {
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        CI=1 gum log --level warn -- "$*" || echo "${YELLOW}[WARN]${NC} $*"
    else
        echo "${YELLOW}[WARN]${NC} $*"
    fi
}
err() {
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        CI=1 gum log --level error -- "$*" >&2 || echo "${RED}[ERR]${NC}  $*" >&2
    else
        echo "${RED}[ERR]${NC}  $*" >&2
    fi
}

# Interactive helpers (gum vs read). Callers gate on [[ -t 0 ]]; main() runs
# attach_tty first, so a piped `curl | sudo bash` install still has a terminal on
# stdin and these prompts fire as intended.
ask_text()   { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum input --prompt "$1 " --prompt.foreground "$UI_ACCENT" --placeholder "${2:-}"; else local v; read -r -p "$1 " v; printf '%s' "$v"; fi; }
ask_secret() {
    if [[ "$_HAVE_GUM" == 1 ]]; then
        CI=1 gum input --password --prompt "$1 " --prompt.foreground "$UI_ACCENT"
    else
        local v
        read -r -s -p "$1 " v
        printf '\n' >&2
        printf '%s' "$v"
    fi
}
ask_yesno()  { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum confirm "$1" --selected.background "$UI_ACCENT"; else local a; read -r -p "$1 [y/N] " a; [[ "$a" == [yY]* ]]; fi; }
ask_choice() {
    local prompt="$1"; shift
    if [[ "$_HAVE_GUM" == 1 ]]; then
        printf '%s\n' "$@" | CI=1 gum choose --header "$prompt" \
            --header.foreground "$UI_ACCENT" --cursor.foreground "$UI_ACCENT"
    else
        local i=1 answer="" item
        echo "$prompt" >&2
        for item in "$@"; do printf '  %d) %s\n' "$i" "$item" >&2; i=$((i + 1)); done
        read -r -p "选择编号: " answer
        [[ "$answer" =~ ^[0-9]+$ && "$answer" -ge 1 && "$answer" -lt "$i" ]] || return 1
        printf '%s\n' "${!answer}"
    fi
}

# Multiline operator input is needed for pasted proxy exports. Gum owns the
# normal path; the plain fallback opens a private temporary file in the
# operator's editor so YAML and URI lists keep their line boundaries.
ask_multiline() {
    local prompt="$1" placeholder="${2:-}" editor tmp value
    [[ -t 0 ]] || return 1
    if [[ "$_HAVE_GUM" == 1 ]]; then
        CI=1 gum write --header "$prompt" --header.foreground "$UI_ACCENT" \
            --placeholder "$placeholder" --width 100 --height 16
        return
    fi

    editor="${VISUAL:-${EDITOR:-vi}}"
    command -v "$editor" >/dev/null 2>&1 \
        || { err "No editor is available for multiline input (tried: $editor)."; return 1; }
    tmp="$(umask 077; mktemp /tmp/5gpn-node-input.XXXXXX)" || return 1
    printf '%s\n' "# $prompt" "# Save and close to continue; comment-only input cancels." >"$tmp"
    "$editor" "$tmp" || { rm -f -- "$tmp"; return 1; }
    value="$(sed '/^[[:space:]]*#/d' "$tmp")"
    rm -f -- "$tmp"
    printf '%s' "$value"
}
# Run an opaque wait command behind a spinner when interactive; else run it plainly.
# Restore the caller's CI state for the wrapped command because Gum inherits its
# own non-querying environment into child processes.
gum_spin() {
    local t="$1"; shift
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        if [[ -n "${CI+x}" ]]; then
            CI=1 gum spin --title "$t" -- env "CI=$CI" "$@"
        else
            CI=1 gum spin --title "$t" -- env -u CI "$@"
        fi
    else
        "$@"
    fi
}
# Frame multi-line stdin in a rounded box when interactive; else pass it through.
# `capture` is used only by the terminal tab renderer, which records the styled
# bytes before its atomic paint and therefore cannot expose a TTY on stdout.
card() {
    local mode="${1:-}"
    if [[ "$_HAVE_GUM" == 1 ]] && { [[ -t 1 ]] || [[ "$mode" == capture ]]; }; then
        CI=1 gum style --border rounded --padding "0 1" --border-foreground "$UI_ACCENT"
    else
        cat
    fi
}

# One heading per install stage. This also carries the phase name that failure
# reporting quotes, so the operator reads the same words on screen and in the
# error -- keeping them in one call is what stops the two from drifting.
phase() {
    INSTALL_PHASE="$1"
    local label="${2:-$1}"
    printf '\n'
    if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then
        CI=1 gum style --foreground "$UI_ACCENT" --bold -- "▸ ${label}" \
            || printf '%s▸ %s%s\n' "$BLUE" "$label" "$NC"
    else
        printf '%s▸ %s%s\n' "$BLUE" "$label" "$NC"
    fi
}

# The environment summary an operator wants before anything is touched: which
# release, on what host, with which memory profile.
banner() {
    local version="$1" host="$2"
    { printf '5gpn 安装器  %s\n' "$version"; printf '%s\n' "$host"; } | card
}

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
        info "Piped install: stdin is attached to /dev/tty for domain, gateway/listener IP, and certificate prompts."
    fi
}

# ── Installer coordinates ──────────────────────────────────────────────────
# /etc/5gpn/dns.env is the one source of truth for installation-owned host
# coordinates. Runtime DNS policy, upstreams, subscriptions and tuning live in
# dns.json. Reinstall reads this file; first install writes it from the TUI.
# cfg_get greps rather than sourcing so a value can contain shell-special
# characters without becoming code.
file_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
file_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
file_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
file_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }

persisted_dns_env_file_metadata_is_safe() {
    local env="${CONF_DIR}/dns.env" conf_mode conf_gid
    fixed_root_is_safe_for_readonly_inspection "$CONF_DIR" || return 1
    conf_mode="$(file_mode "$CONF_DIR")"
    conf_gid="$(file_gid "$CONF_DIR")"
    if [[ "$conf_mode:$conf_gid" != 755:0 ]]; then
        [[ "$conf_mode" == 3771 ]] || return 1
        { gid_matches_named_group "$conf_gid" "$FIVEGPN_SERVICE_GROUP" \
          || [[ -n "$REPLACED_FIVEGPN_GID" && "$conf_gid" == "$REPLACED_FIVEGPN_GID" ]] \
          || [[ -n "$REPLACED_FIVEGPN_NAMED_GID" \
             && "$conf_gid" == "$REPLACED_FIVEGPN_NAMED_GID" ]]; } \
            || return 1
    fi
    [[ -f "$env" && ! -L "$env" \
       && "$(file_uid "$env")" == 0 \
       && "$(file_nlink "$env")" == 1 ]] || return 1
    if [[ "$conf_mode:$conf_gid" == 755:0 ]]; then
        [[ "$(file_gid "$env")" == 0 && "$(file_mode "$env")" == 600 ]]
    else
        [[ "$(file_gid "$env")" == "$conf_gid" && "$(file_mode "$env")" == 640 ]]
    fi
}

persisted_dns_env_is_safe() {
    local marker="${CONF_DIR}/${CONF_OWNERSHIP_MARKER}"
    persisted_dns_env_file_metadata_is_safe || return 1
    [[ -f "$marker" && ! -L "$marker" \
       && "$(file_uid "$marker")" == 0 \
       && "$(file_gid "$marker")" == 0 \
       && "$(file_mode "$marker")" == 644 \
       && "$(file_nlink "$marker")" == 1 \
       && "$(cat "$marker" 2>/dev/null || true)" == "$CONF_OWNERSHIP_VALUE" ]]
}

dns_env_value_from_file() {
    local file="$1" key="$2"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    awk -v key="$key" '
        index($0, key "=") == 1 { value=substr($0, length(key) + 2); found++ }
        END { if (found == 1) print value; else exit 1 }
    ' "$file"
}

validate_persisted_install_config_values() {
    local file="$1" base public gateway listen cert_mode cert_email
    base="$(dns_env_value_from_file "$file" DNS_BASE_DOMAIN)" || return 1
    public="$(dns_env_value_from_file "$file" DNS_PUBLIC_IP)" || return 1
    gateway="$(dns_env_value_from_file "$file" DNS_GATEWAY_IP)" || return 1
    listen="$(dns_env_value_from_file "$file" DNS_MIHOMO_LISTEN_IPS)" || return 1
    cert_mode="$(dns_env_value_from_file "$file" CERT_MODE)" || return 1
    cert_email="$(dns_env_value_from_file "$file" CERT_EMAIL)" || return 1

    is_valid_domain "$base" \
        || { err "Persisted DNS_BASE_DOMAIN is invalid before publication."; return 1; }
    is_valid_ipv4 "$public" \
        || { err "Persisted DNS_PUBLIC_IP is invalid before publication."; return 1; }
    is_valid_ipv4 "$gateway" \
        || { err "Persisted DNS_GATEWAY_IP is invalid before publication."; return 1; }
    cert_mode="$(normalize_cert_mode "$cert_mode" 2>/dev/null || true)"
    [[ "$cert_mode" == cloudflare || "$cert_mode" == http-01 || "$cert_mode" == debug ]] \
        || { err "Persisted CERT_MODE is invalid before publication."; return 1; }
    if [[ "$cert_mode" != debug ]]; then
        is_valid_cert_email "$cert_email" \
            || { err "Persisted CERT_EMAIL is invalid before publication."; return 1; }
    fi
    [[ -n "$listen" ]] \
        || { err "Persisted DNS_MIHOMO_LISTEN_IPS is empty before publication."; return 1; }
    (
        PUBLIC_IP="$public"
        GATEWAY_IP="$gateway"
        resolve_mihomo_listen_ips "$listen" >/dev/null
    ) || { err "Persisted DNS_MIHOMO_LISTEN_IPS is invalid before publication."; return 1; }
}

assert_loaded_persisted_dns_env_revision() {
    local require_marker="${1:-0}" env="${CONF_DIR}/dns.env" revision identity
    case "$LOADED_DNS_ENV_SOURCE_STATE" in
        absent)
            [[ ! -e "$env" && ! -L "$env" ]] \
                || { err "A dns.env file appeared after the installer selected fresh configuration."; return 1; }
            ;;
        present)
            if [[ "$require_marker" == 1 ]]; then
                persisted_dns_env_is_safe \
                    || { err "Persisted installer configuration is unsafe after root claim: $env"; return 1; }
            else
                persisted_dns_env_file_metadata_is_safe \
                    || { err "Persisted installer configuration is unsafe before root claim: $env"; return 1; }
            fi
            revision="$(sha256sum "$env" | awk '{print $1}')" || return 1
            identity="$(stat -Lc '%d:%i' -- "$env" 2>/dev/null)" || return 1
            [[ "$revision" == "$LOADED_DNS_ENV_SOURCE_REVISION" \
               && "$identity" == "$LOADED_DNS_ENV_SOURCE_IDENTITY" ]] \
                || { err "Persisted dns.env changed after its configuration snapshot was loaded."; return 1; }
            ;;
        *)
            err "The installer has no pinned dns.env source revision."
            return 1
            ;;
    esac
}

revalidate_claimed_persisted_dns_env() {
    local env="${CONF_DIR}/dns.env"
    assert_loaded_persisted_dns_env_revision 1 || return 1
    [[ "$LOADED_DNS_ENV_SOURCE_STATE" == absent ]] && return 0
    validate_dns_env_schema "$env" \
        && validate_persisted_install_config_values "$env"
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
    printf '%s' "$raw"
}

# Caller configuration is discarded before command dispatch. Root installer and
# certificate helpers read persisted coordinates explicitly; systemd denies the
# network-facing monolith access to dns.env.
clear_external_config_env() {
    local key
    unset BASE_DOMAIN CONSOLE_DOMAIN DOT_DOMAIN PUBLIC_IP GATEWAY_IP \
        MIHOMO_LISTEN_IPS LOWMEM \
        DNS_LISTEN_DOT DNS_LISTEN_DEBUG DNS_CONSOLE_CERT DNS_CONSOLE_KEY \
        DNS_MIHOMO_CONTROLLER DNS_MIHOMO_SECRET
    for key in $DNS_ENV_KEYS; do
        unset "$key"
    done
}

# Canonicalize a directory without requiring its final component to exist.
# Deletion helpers below only operate on the returned path after checking a
# project ownership marker. This protects root-run cleanup from a typo or a
# malicious symlink in UI_DIR.
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

process_is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

# The marker is published, not inherited. It must always be root-owned even
# when the containing directory is setgid for the current runtime account.
write_ownership_marker() {
    local dir="$1" name="$2" value="$3" tmp
    if [[ ! -e "$dir" ]]; then
        install -d -m 0755 -- "$dir" || return 1
    fi
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    tmp="$(mktemp "${dir}/.${name}.XXXXXX")" || return 1
    printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
    if process_is_root; then
        chown 0:0 -- "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
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

identity_reconcile_state_root_is_safe() {
    fixed_owned_dir_is_safe "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE"
}

# A current reconciliation journal may be the surviving proof needed to repair
# an interrupted install before the exact fixed state root has received its
# marker. Reading that one file is allowed only when the complete unmarked-root
# claim boundary already passes; publication still requires the current marker.
identity_reconcile_state_root_is_safe_for_read() {
    identity_reconcile_state_root_is_safe && return 0
    [[ ! -e "$STATE_DIR/$STATE_OWNERSHIP_MARKER" \
       && ! -L "$STATE_DIR/$STATE_OWNERSHIP_MARKER" ]] || return 1
    preflight_fixed_owned_dir_claim \
        "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" 1
}

identity_reconcile_journal_file_is_safe() {
    [[ -f "$IDENTITY_RECONCILE_FILE" && ! -L "$IDENTITY_RECONCILE_FILE" \
       && "$(file_uid "$IDENTITY_RECONCILE_FILE")" == 0 \
       && "$(file_gid "$IDENTITY_RECONCILE_FILE")" == 0 \
       && "$(file_mode "$IDENTITY_RECONCILE_FILE")" == 600 \
       && "$(file_nlink "$IDENTITY_RECONCILE_FILE")" == 1 ]]
}

identity_reconcile_id_is_valid() {
    [[ "$1" == - || "$1" =~ ^[1-9][0-9]*$ ]]
}

load_identity_reconcile_journal() {
    local uid_value gid_value named_gid_value
    local -a lines=()
    [[ "$IDENTITY_RECONCILE_LOADED" == 0 ]] || return 0
    if [[ ! -e "$IDENTITY_RECONCILE_FILE" && ! -L "$IDENTITY_RECONCILE_FILE" ]]; then
        IDENTITY_RECONCILE_LOADED=1
        return 0
    fi
    identity_reconcile_state_root_is_safe_for_read \
        || { err "Identity reconciliation journal is outside a safe 5gpn state root."; return 1; }
    identity_reconcile_journal_file_is_safe \
        || { err "Identity reconciliation journal metadata is unsafe: $IDENTITY_RECONCILE_FILE"; return 1; }
    mapfile -t lines < "$IDENTITY_RECONCILE_FILE" || return 1
    [[ "${#lines[@]}" == 4 \
       && "${lines[0]}" == "version=${IDENTITY_RECONCILE_VERSION}" \
       && "${lines[1]}" == uid=* \
       && "${lines[2]}" == gid=* \
       && "${lines[3]}" == named_gid=* ]] \
        || { err "Identity reconciliation journal has an unsupported schema."; return 1; }
    uid_value="${lines[1]#uid=}"
    gid_value="${lines[2]#gid=}"
    named_gid_value="${lines[3]#named_gid=}"
    identity_reconcile_id_is_valid "$uid_value" \
        && identity_reconcile_id_is_valid "$gid_value" \
        && identity_reconcile_id_is_valid "$named_gid_value" \
        || { err "Identity reconciliation journal contains invalid values."; return 1; }
    REPLACED_FIVEGPN_UID="${uid_value#-}"
    REPLACED_FIVEGPN_GID="${gid_value#-}"
    REPLACED_FIVEGPN_NAMED_GID="${named_gid_value#-}"
    IDENTITY_RECONCILE_LOADED=1
}

publish_identity_reconcile_journal() {
    local uid_value="${1:--}" gid_value="${2:--}" named_gid_value="${3:--}"
    local tmp
    identity_reconcile_id_is_valid "$uid_value" \
        && identity_reconcile_id_is_valid "$gid_value" \
        && identity_reconcile_id_is_valid "$named_gid_value" \
        || { err "Refusing invalid identity reconciliation state."; return 1; }
    identity_reconcile_state_root_is_safe \
        || { err "Refusing identity reconciliation outside the owned state root."; return 1; }
    if [[ -e "$IDENTITY_RECONCILE_FILE" || -L "$IDENTITY_RECONCILE_FILE" ]]; then
        identity_reconcile_journal_file_is_safe \
            || { err "Refusing an unsafe identity reconciliation journal path."; return 1; }
    fi
    if [[ "$uid_value" == - && "$gid_value" == - && "$named_gid_value" == - ]]; then
        if [[ -e "$IDENTITY_RECONCILE_FILE" || -L "$IDENTITY_RECONCILE_FILE" ]]; then
            identity_reconcile_journal_file_is_safe \
                || { err "Refusing to remove an unsafe identity reconciliation journal."; return 1; }
            rm -f -- "$IDENTITY_RECONCILE_FILE" || return 1
            sync -f "$STATE_DIR" 2>/dev/null \
                || { err "Could not durably remove the identity reconciliation journal."; return 1; }
        fi
    else
        tmp="$(mktemp "${STATE_DIR}/.identity-reconcile.XXXXXX")" || return 1
        if ! printf 'version=%s\nuid=%s\ngid=%s\nnamed_gid=%s\n' \
            "$IDENTITY_RECONCILE_VERSION" "$uid_value" "$gid_value" "$named_gid_value" > "$tmp"; then
            rm -f -- "$tmp"
            return 1
        fi
        chown root:root "$tmp" \
            && chmod 0600 "$tmp" \
            && sync -f "$tmp" 2>/dev/null \
            || { rm -f -- "$tmp"; return 1; }
        mv -f -- "$tmp" "$IDENTITY_RECONCILE_FILE" \
            || { rm -f -- "$tmp"; return 1; }
        sync -f "$STATE_DIR" 2>/dev/null \
            || { err "Could not durably publish the identity reconciliation journal."; return 1; }
        identity_reconcile_journal_file_is_safe \
            || { err "Published identity reconciliation journal failed validation."; return 1; }
    fi
    REPLACED_FIVEGPN_UID="${uid_value#-}"
    REPLACED_FIVEGPN_GID="${gid_value#-}"
    REPLACED_FIVEGPN_NAMED_GID="${named_gid_value#-}"
    IDENTITY_RECONCILE_LOADED=1
}

persist_replaced_fivegpn_identity() {
    local candidate_uid="${1:-}" candidate_gid="${2:-}" candidate_named_gid="${3:-}"
    local merged_uid merged_gid merged_named_gid
    load_identity_reconcile_journal || return 1
    merged_uid="${REPLACED_FIVEGPN_UID:--}"
    merged_gid="${REPLACED_FIVEGPN_GID:--}"
    merged_named_gid="${REPLACED_FIVEGPN_NAMED_GID:--}"
    if [[ -n "$candidate_uid" ]]; then
        if [[ "$merged_uid" != - && "$merged_uid" != "$candidate_uid" ]]; then
            err "The pending fivegpn UID conflicts with the durable reconciliation journal."
            return 1
        fi
        merged_uid="$candidate_uid"
    fi
    if [[ -n "$candidate_gid" ]]; then
        if [[ "$merged_gid" != - && "$merged_gid" != "$candidate_gid" ]]; then
            err "The pending fivegpn GID conflicts with the durable reconciliation journal."
            return 1
        fi
        merged_gid="$candidate_gid"
    fi
    if [[ -n "$candidate_named_gid" ]]; then
        if [[ "$merged_named_gid" != - && "$merged_named_gid" != "$candidate_named_gid" ]]; then
            err "The pending fivegpn named-group GID conflicts with the durable reconciliation journal."
            return 1
        fi
        merged_named_gid="$candidate_named_gid"
    fi
    publish_identity_reconcile_journal "$merged_uid" "$merged_gid" "$merged_named_gid"
}

complete_replaced_fivegpn_identity_reconciliation() {
    [[ "$IDENTITY_RECONCILE_LOADED" == 1 ]] || load_identity_reconcile_journal || return 1
    publish_identity_reconcile_journal - - -
}

gid_matches_named_group() {
    local actual="$1" group expected
    shift
    [[ "$actual" =~ ^[0-9]+$ ]] || return 1
    for group in "$@"; do
        expected="$(account_gid "$group")"
        [[ -n "$expected" && "$actual" == "$expected" ]] && return 0
    done
    return 1
}

uid_gid_match_named_account() {
    local actual_uid="$1" actual_gid="$2" user="$3" group="$4"
    local expected_uid expected_gid
    expected_uid="$(account_uid "$user")"
    expected_gid="$(account_gid "$group")"
    [[ -n "$expected_uid" && -n "$expected_gid" \
       && "$actual_uid" == "$expected_uid" && "$actual_gid" == "$expected_gid" ]]
}

gid_matches_replaced_fivegpn_identity() {
    local actual="$1"
    [[ -n "$REPLACED_FIVEGPN_GID" && "$actual" == "$REPLACED_FIVEGPN_GID" ]] \
        && return 0
    [[ -n "$REPLACED_FIVEGPN_NAMED_GID" \
       && "$actual" == "$REPLACED_FIVEGPN_NAMED_GID" ]]
}

# Fixed roots have a deliberately small metadata state machine. A new root is
# initially root:root 0755; an installed configuration root is sticky 3771.
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
            { gid_matches_named_group "$gid" "$FIVEGPN_SERVICE_GROUP" \
              || gid_matches_replaced_fivegpn_identity "$gid"; } \
                && [[ "$mode" == 3771 ]] ;;
        "$INTERCEPT_CA_DIR")
            [[ "$uid" == 0 && "$gid" == 0 && ( "$mode" == 700 || "$mode" == 755 ) ]] ;;
        "$INTERCEPT_STATE_DIR")
            if [[ "$uid" == 0 && "$gid" == 0 && "$mode" == 755 ]]; then
                return 0
            fi
            { uid_gid_match_named_account "$uid" "$gid" \
                    "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" \
              || { [[ -n "$REPLACED_FIVEGPN_UID" \
                      && "$uid" == "$REPLACED_FIVEGPN_UID" ]] \
                   && gid_matches_replaced_fivegpn_identity "$gid"; }; } \
                && [[ "$mode" == 700 ]] ;;
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

# Read-only legacy inspection may examine an exact fixed root before it has a
# current marker. This is deliberately weaker than ownership: it proves only
# that following known child names is bounded by the canonical root and safe
# top-level metadata. Claiming and recursive deletion still require their own
# marker transaction.
fixed_root_is_safe_for_readonly_inspection() {
    local dir="$1" canonical
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    canonical="$(canonical_dir_path "$dir")" || return 1
    [[ "$canonical" == "$dir" ]] || return 1
    fixed_owned_dir_metadata_is_safe "$dir"
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

# A path that this installer may chmod or chown must not be a hard link. The
# directory-slot check rejects symlinks and escapes, while this final identity
# check prevents metadata publication through one name from mutating a second
# file outside the intended configuration transaction.
runtime_plain_file_slot_is_safe() {
    local path="$1" parent="$2"
    runtime_file_slot_is_safe "$path" "$parent" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    [[ -f "$path" && ! -L "$path" && "$(file_nlink "$path")" == 1 ]]
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

cert_role_tree_is_safe_for_recursive_metadata() {
    local role="$1" role_name="${2:-}"
    [[ -n "$role_name" ]] || role_name="$(basename -- "$role")"
    [[ "$role" == "$DNS_CERT_DIR/$role_name" ]] || return 1
    load_cert_role_helpers || return 1
    cert_role_ctl_validate_role "$role_name" 0
}




cert_root_contents_are_safe() {
    load_cert_role_helpers || return 1
    cert_role_ctl_root_is_steady_allow_missing_roles
}

cert_root_is_safe() {
    runtime_directory_slot_is_safe "$DNS_CERT_DIR" "$CONF_DIR" \
        && root_owned_nonwritable_directory_is_safe "$DNS_CERT_DIR" \
        && [[ "$(file_gid "$DNS_CERT_DIR")" == 0 \
           && "$(file_mode "$DNS_CERT_DIR")" == 751 ]] \
        && root_ownership_marker_is_safe "$DNS_CERT_DIR" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE" \
        && cert_root_contents_are_safe
}

cert_root_is_recoverable() {
    runtime_directory_slot_is_safe "$DNS_CERT_DIR" "$CONF_DIR" \
        && root_owned_nonwritable_directory_is_safe "$DNS_CERT_DIR" \
        && [[ "$(file_gid "$DNS_CERT_DIR")" == 0 \
           && ( "$(file_mode "$DNS_CERT_DIR")" == 750 \
                || "$(file_mode "$DNS_CERT_DIR")" == 751 ) ]] \
        && root_ownership_marker_is_safe "$DNS_CERT_DIR" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE" \
        && load_cert_role_helpers \
        && cert_role_ctl_tree_is_recoverable
}

# Every reason an existing certificate root can be refused, decided without
# touching it. ensure_dns_cert_root runs this too, so preflight and publication
# reach the same verdict from one implementation rather than two that can drift.
#
# This exists because ensure_dns_cert_root does not run until
# prepare_certificate_publication_boundaries -- by which point the three
# binaries have already been replaced, and with no rollback there is nothing to
# return to. A host this release cannot accept has to be turned away while its
# deployment is still untouched.
cert_root_claim_is_possible() {
    local mode
    [[ -e "$DNS_CERT_DIR" || -L "$DNS_CERT_DIR" ]] || return 0
    [[ -d "$DNS_CERT_DIR" && ! -L "$DNS_CERT_DIR" \
       && "$(file_uid "$DNS_CERT_DIR")" == 0 \
       && "$(file_gid "$DNS_CERT_DIR")" == 0 ]] \
        || { err "Certificate root ownership is unsafe: $DNS_CERT_DIR"; return 1; }
    managed_path_has_no_nested_mounts "$DNS_CERT_DIR" \
        || { err "Certificate root contains a nested mount: $DNS_CERT_DIR"; return 1; }
    if root_ownership_marker_is_safe "$DNS_CERT_DIR" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE"; then
        mode="$(file_mode "$DNS_CERT_DIR")"
        [[ "$mode" == 750 || "$mode" == 751 ]] \
            && { cert_root_contents_are_safe || cert_root_is_recoverable; } \
            || { err "Marked certificate root failed structural validation before publication."; return 1; }
        return 0
    fi
    [[ ! -e "$DNS_CERT_DIR/$CERT_ROOT_MARKER" && ! -L "$DNS_CERT_DIR/$CERT_ROOT_MARKER" ]] \
        || { err "Certificate root marker is unsafe: $DNS_CERT_DIR/$CERT_ROOT_MARKER"; return 1; }
    mode="$(file_mode "$DNS_CERT_DIR")"
    mode="${mode: -3}"
    [[ "$mode" == 750 || "$mode" == 751 || "$mode" == 755 ]] \
        || { err "Refusing to claim an unknown certificate root: $DNS_CERT_DIR"; return 1; }
    # A populated unmarked root has no acceptable current provenance and is
    # never adopted.
    local existing_entry
    existing_entry="$(find "$DNS_CERT_DIR" -mindepth 1 -print -quit 2>/dev/null)" \
        || { err "Could not inspect the certificate root before publication."; return 1; }
    [[ -z "$existing_entry" ]] \
        || { err "Refusing to claim a populated certificate root with no ownership marker: $DNS_CERT_DIR"
             err "Back it up and remove it, or restore the marker, before rerunning."; return 1; }
}

ensure_dns_cert_root() {
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$DNS_CERT_DIR" "$CONF_DIR" \
        || { err "Refusing unsafe certificate root slot: $DNS_CERT_DIR"; return 1; }
    cert_root_claim_is_possible || return 1
    if [[ ! -e "$DNS_CERT_DIR" && ! -L "$DNS_CERT_DIR" ]]; then
        install -d -o root -g root -m 0751 "$DNS_CERT_DIR" || return 1
    fi
    [[ -d "$DNS_CERT_DIR" && ! -L "$DNS_CERT_DIR" \
       && "$(file_uid "$DNS_CERT_DIR")" == 0 \
       && "$(file_gid "$DNS_CERT_DIR")" == 0 ]] \
        || { err "Certificate root ownership is unsafe: $DNS_CERT_DIR"; return 1; }
    if root_ownership_marker_is_safe "$DNS_CERT_DIR" "$CERT_ROOT_MARKER" "$CERT_ROOT_MARKER_VALUE"; then
        if [[ "$(file_mode "$DNS_CERT_DIR")" == 750 ]]; then
            chmod 00751 "$DNS_CERT_DIR" || return 1
            sync -f "$DNS_CERT_DIR" \
                || { err "Could not make the recovered certificate-root traversal mode durable."; return 1; }
        fi
        if ! cert_root_is_safe; then
            cert_root_is_recoverable \
                || { err "Existing certificate root is neither steady nor safely recoverable: $DNS_CERT_DIR"; return 1; }
            [[ "$INSTALL_PUBLICATION_STARTED" == 1 && "$INSTALL_CERT_LOCK_HELD" == 1 ]] \
                || { err "Recoverable certificate role residue may be repaired only after publication begins under the certificate lock."; return 1; }
            load_cert_role_helpers || return 1
            cert_role_ctl_repair_recoverable_tree \
                || { err "Could not repair the interrupted certificate role publication forward."; return 1; }
        fi
        cert_root_is_safe \
            || { err "Existing certificate root failed structural validation: $DNS_CERT_DIR"; return 1; }
        return 0
    fi
    # Five octal digits on purpose. GNU chmod preserves a directory's
    # set-group-ID bit for a four-digit mode, and this root inherits that bit
    # from the setgid CONF_DIR, so "chmod 0751" left it at 2751 and the
    # boundary check below -- which requires exactly 751 -- could never pass
    # on a first install.
    chmod 00751 "$DNS_CERT_DIR" || return 1
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

debug_cert_root_claim_is_possible() {
    local mode existing_entry
    [[ -e "$DEBUG_CERT_DIR" || -L "$DEBUG_CERT_DIR" ]] || return 0
    [[ -d "$DEBUG_CERT_DIR" && ! -L "$DEBUG_CERT_DIR" \
       && "$(file_uid "$DEBUG_CERT_DIR")" == 0 \
       && "$(file_gid "$DEBUG_CERT_DIR")" == 0 ]] \
        || { err "Debug-certificate root ownership is unsafe: $DEBUG_CERT_DIR"; return 1; }
    managed_path_has_no_nested_mounts "$DEBUG_CERT_DIR" \
        || { err "Debug-certificate root contains a nested mount: $DEBUG_CERT_DIR"; return 1; }
    if root_ownership_marker_is_safe "$DEBUG_CERT_DIR" "$DEBUG_CERT_MARKER" "$DEBUG_CERT_MARKER_VALUE"; then
        debug_cert_root_is_safe \
            || { err "Existing debug-certificate root failed structural validation."; return 1; }
        return 0
    fi
    [[ ! -e "$DEBUG_CERT_DIR/$DEBUG_CERT_MARKER" && ! -L "$DEBUG_CERT_DIR/$DEBUG_CERT_MARKER" ]] \
        || { err "Debug-certificate root marker is unsafe."; return 1; }
    mode="$(file_mode "$DEBUG_CERT_DIR")"
    mode="${mode: -3}"
    [[ "$mode" == 700 || "$mode" == 755 ]] \
        || { err "Refusing to claim an unknown debug-certificate root."; return 1; }
    existing_entry="$(find "$DEBUG_CERT_DIR" -mindepth 1 -print -quit 2>/dev/null)" \
        || { err "Could not inspect the debug-certificate root before publication."; return 1; }
    [[ -z "$existing_entry" ]] \
        || { err "Refusing to claim a populated debug-certificate root with no ownership marker: $DEBUG_CERT_DIR"; return 1; }
}

ensure_debug_cert_root() {
    local mode
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$DEBUG_CERT_DIR" "$CONF_DIR" \
        || { err "Refusing unsafe debug-certificate root slot: $DEBUG_CERT_DIR"; return 1; }
    debug_cert_root_claim_is_possible || return 1
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
    # Accept and clear a set-group-ID bit inherited from an older CONF_DIR.
    mode="$(file_mode "$DEBUG_CERT_DIR")"
    mode="${mode: -3}"
    [[ "$mode" == 700 || "$mode" == 755 ]] \
        || { err "Refusing to claim an unknown debug-certificate root."; return 1; }
    [[ -z "$(find "$DEBUG_CERT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]] \
        || { err "Refusing a populated unmarked debug-certificate root during publication."; return 1; }
    chmod 00700 "$DEBUG_CERT_DIR" || return 1
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
    local allow_unclaimed="${1:-0}" path

    if [[ -e "$BASE_DIR" || -L "$BASE_DIR" ]]; then
        if ! fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE"; then
            [[ "$allow_unclaimed" == 1 ]] \
                && unmarked_fixed_dir_is_safe_to_claim "$BASE_DIR" \
                || { err "Unsafe installed-runtime root: $BASE_DIR"; return 1; }
        fi
        for path in \
            "$SCRIPTS_DIR" "$RELEASE_DIR" "${BASE_DIR}/etc" "${BASE_DIR}/etc/systemd" \
            "${BASE_DIR}/etc/mihomo"; do
            runtime_directory_slot_is_safe "$path" "$BASE_DIR" \
                || { err "Refusing unsafe runtime directory slot: $path"; return 1; }
        done
        for path in \
            "${RELEASE_DIR}/pins.env" \
            "${RELEASE_DIR}/pins.sh"; do
            runtime_plain_file_slot_is_safe "$path" "$BASE_DIR" \
                || { err "Refusing unsafe installed release-pin file slot: $path"; return 1; }
        done
    elif [[ "$allow_unclaimed" != 1 ]]; then
        err "Installed-runtime root is missing after project-root claim: $BASE_DIR"
        return 1
    fi

    if [[ -e "$CONF_DIR" || -L "$CONF_DIR" ]]; then
        if ! fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE"; then
            [[ "$allow_unclaimed" == 1 ]] \
                && unmarked_fixed_dir_is_safe_to_claim "$CONF_DIR" \
                || { err "Unsafe configuration root: $CONF_DIR"; return 1; }
        fi
        for path in \
            "$MIHOMO_DIR" "$INTERCEPT_DIR" \
            "${INTERCEPT_DIR}/tls" "$DNS_CERT_DIR" "${DNS_CERT_DIR}/dot" \
            "${DNS_CERT_DIR}/console"; do
            runtime_directory_slot_is_safe "$path" "$CONF_DIR" \
                || { err "Refusing unsafe configuration directory slot: $path"; return 1; }
        done
        for path in \
            "${CONF_DIR}/dns.env" \
            "${MIHOMO_DIR}/config.yaml" \
            "${INTERCEPT_DIR}/cert-state"; do
            runtime_plain_file_slot_is_safe "$path" "$CONF_DIR" \
                || { err "Refusing unsafe configuration file slot: $path"; return 1; }
        done
    elif [[ "$allow_unclaimed" != 1 ]]; then
        err "Configuration root is missing after project-root claim: $CONF_DIR"
        return 1
    fi
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
        && shared_runtime_directory_metadata_is_safe "$MIHOMO_DIR" "$FIVEGPN_SERVICE_USER" 3770 \
        && shared_runtime_directory_metadata_is_safe "$INTERCEPT_DIR" "$FIVEGPN_SERVICE_USER" 750 \
        && runtime_control_file_metadata_is_safe "$MIHOMO_DIR/config.yaml" \
            root "$FIVEGPN_SERVICE_GROUP" 640 \
        && runtime_control_file_metadata_is_safe "$INTERCEPT_DIR/cert-state" \
            root "$FIVEGPN_SERVICE_USER" 640 \
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
    managed_path_has_no_nested_mounts "$canonical" || return 1
    rm -rf -- "$canonical"
}

clear_owned_scope() {
    local root="$1" marker="$2" value="$3" scope="$4" canonical scope_canonical preserve
    shift 4
    canonical="$(owned_root_canonical "$root" "$marker" "$value")" || return 1
    scope_canonical="$(canonical_dir_path "$scope")" || return 1
    [[ "$scope_canonical" == "$scope" ]] || return 1
    [[ "$scope_canonical" == "$canonical" || "$scope_canonical" == "$canonical"/* ]] || return 1
    managed_path_has_no_nested_mounts "$scope_canonical" || return 1
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
    managed_path_has_no_nested_mounts "$target" || return 1
    rm -rf -- "$target"
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
    managed_path_has_no_nested_mounts "$canonical" || return 1
    rm -rf -- "$canonical"
}

# Claim a fixed project root and publish the ownership marker that the recursive
# removal guards re-verify later.
#
# Existing roots are accepted when their current root-owned marker verifies. A
# caller may explicitly allow a safe populated root with no marker to be
# claimed, but an existing invalid, legacy, or symlinked marker is never
# replaced. Certificate, UI, and temporary roots do not use that policy.
preflight_fixed_owned_dir_claim() {
    local dir="$1" marker="$2" value="$3" allow_populated_unmarked="${4:-0}"
    local canonical nonempty=0
    canonical="$(canonical_dir_path "$dir")" \
        || { err "Could not canonicalize project directory: $dir"; return 1; }
    [[ "$canonical" == "$dir" && ! -L "$dir" ]] \
        || { err "Refusing project directory symlink/alias: $dir -> $canonical"; return 1; }
    [[ ! -e "$dir" || -d "$dir" ]] \
        || { err "Project path exists but is not a directory: $dir"; return 1; }
    [[ -e "$dir" ]] || return 0
    [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] \
        && nonempty=1
    if verify_ownership_marker "$dir" "$marker" "$value"; then
        fixed_owned_dir_is_safe "$dir" "$marker" "$value" \
            || { err "Unsafe ownership or mode on fixed project directory: $dir"; return 1; }
        return 0
    fi
    if [[ -e "$dir/$marker" || -L "$dir/$marker" ]]; then
        err "Invalid or symlinked ownership marker: $dir/$marker"
        return 1
    fi
    if [[ "$allow_populated_unmarked" == 1 ]]; then
        fixed_owned_dir_metadata_is_safe "$dir" \
            || { err "Refusing unsafe fixed directory before marker publication: $dir"
                 report_orphaned_root_owner "$dir"; return 1; }
    else
        [[ "$nonempty" == 0 ]] \
            || { err "Refusing non-empty unowned project directory: $dir"; return 1; }
        unmarked_fixed_dir_is_safe_to_claim "$dir" \
            || { err "Refusing unsafe empty fixed directory before marker publication: $dir"; return 1; }
    fi
    runtime_tree_has_only_plain_entries "$dir" \
        || { err "Refusing an unmarked fixed root containing a symlink, hardlink, or special file: $dir"; return 1; }
    managed_path_has_no_nested_mounts "$dir" \
        || { err "Refusing to claim a fixed directory containing a nested mount: $dir"; return 1; }
}

claim_fixed_owned_dir() {
    local dir="$1" marker="$2" value="$3" allow_populated_unmarked="${4:-0}"
    local canonical nonempty=0 created_dir=0
    preflight_fixed_owned_dir_claim "$dir" "$marker" "$value" "$allow_populated_unmarked" \
        || return 1
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
    if [[ -e "$dir/$marker" || -L "$dir/$marker" ]]; then
        err "Invalid or symlinked ownership marker: $dir/$marker"
        return 1
    fi
    if [[ -e "$dir" || -L "$dir" ]]; then
        if [[ "$allow_populated_unmarked" == 1 ]]; then
            fixed_owned_dir_metadata_is_safe "$dir" \
                || { err "Refusing unsafe fixed directory before marker publication: $dir"
                     report_orphaned_root_owner "$dir"; return 1; }
        else
            if [[ "$nonempty" == 1 ]]; then
                err "Refusing non-empty unowned project directory: $dir"
                return 1
            fi
            unmarked_fixed_dir_is_safe_to_claim "$dir" \
                || { err "Refusing unsafe empty fixed directory before marker publication: $dir"; return 1; }
        fi
    else
        created_dir=1
        install -d -o root -g root -m 0755 -- "$dir" \
            && chmod g-s -- "$dir" \
            && chmod 0755 -- "$dir" \
            || { err "Could not create fixed project directory: $dir"; return 1; }
    fi
    runtime_tree_has_only_plain_entries "$dir" \
        || { err "Refusing an unmarked fixed root containing a symlink, hardlink, or special file: $dir"; return 1; }
    managed_path_has_no_nested_mounts "$dir" \
        || { err "Refusing to claim a fixed directory containing a nested mount: $dir"; return 1; }
    write_ownership_marker "$dir" "$marker" "$value" \
        || { err "Could not write ownership marker under $dir"; return 1; }
    if ! fixed_owned_dir_is_safe "$dir" "$marker" "$value"; then
        rm -f -- "$dir/$marker"
        [[ "$created_dir" == 0 ]] || rmdir -- "$dir" 2>/dev/null || true
        err "Could not establish safe ownership on fixed project directory: $dir"
        return 1
    fi
}

preflight_project_root_claims() {
    preflight_fixed_owned_dir_claim "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" 1 \
        || return 1
    preflight_fixed_owned_dir_claim "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" 1 \
        || return 1
    preflight_fixed_owned_dir_claim "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" 1
}

claim_project_roots() {
    claim_fixed_owned_dir "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" 1 || return 1
    claim_fixed_owned_dir "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" 1 || return 1
    claim_fixed_owned_dir "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" 1 || return 1
}



# Sensitive fixed roots must be inspected without mutating the host before the
# install transaction claims them. This diagnostic explains a refusal caused
# by an orphaned owner; ordinary top-level runtime/config/state roots may still
# be claimed without a marker when their exact path and metadata are safe.
#
# Removing a service account leaves every directory it owned with a uid that no
# longer resolves, and the installer then refuses to claim those roots — which is
# the right call, because a future account recreated at that uid would inherit
# them. But "unowned" alone gives an operator nothing to act on, and the refusal
# has no self-repair path: it is reached on every subsequent run, including the
# one that would have recreated the account.
#
# Diagnose, do not repair. Silently chowning a directory whose owner the
# installer does not recognise is precisely what this check exists to prevent.
report_orphaned_root_owner() {
    local dir="$1" uid gid
    [[ -e "$dir" ]] || return 0
    uid="$(file_uid "$dir")"
    gid="$(file_gid "$dir")"
    if [[ "$uid" =~ ^[0-9]+$ ]] && ! getent passwd "$uid" >/dev/null 2>&1; then
        err "Its owner is uid ${uid}, which no longer exists — a removed service account."
        err "Restore it with: chown root:root '${dir}' && chmod 755 '${dir}'"
        err "and check the ownership marker inside it is root:root mode 644."
    elif [[ "$gid" =~ ^[0-9]+$ ]] && ! getent group "$gid" >/dev/null 2>&1; then
        err "Its group is gid ${gid}, which no longer exists — a removed service group."
        err "Restore it with: chgrp root '${dir}'"
    fi
}

# Existing interception roots are accepted only with their current markers.
preflight_intercept_roots() {
    preflight_fixed_owned_dir_claim "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" \
        || { err "Refusing pre-existing unowned interception CA root: $INTERCEPT_CA_DIR"
             report_orphaned_root_owner "$INTERCEPT_CA_DIR"; return 1; }
    preflight_fixed_owned_dir_claim "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" 1 \
        || { err "Refusing unsafe interception state root: $INTERCEPT_STATE_DIR"
             report_orphaned_root_owner "$INTERCEPT_STATE_DIR"; return 1; }
}

claim_intercept_roots() {
    claim_fixed_owned_dir "$INTERCEPT_CA_DIR" "$INTERCEPT_CA_MARKER" "$INTERCEPT_CA_MARKER_VALUE" || return 1
    claim_fixed_owned_dir "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" 1 || return 1
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
    if [[ -e "$UI_DIR" || -L "$UI_DIR" ]]; then
        remove_ui_dir \
            || { err "Refusing runtime removal while the UI generation tree is unsafe."; return 1; }
    fi

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

safe_ui_path() {
    local p
    [[ -n "${UI_DIR:-}" && "$UI_DIR" != *$'\n'* && "$UI_DIR" != *$'\r'* ]] \
        || { err "UI_DIR is empty or contains a newline; refusing it."; return 1; }
    p="$(canonical_dir_path "$UI_DIR")" \
        || { err "Could not canonicalize UI_DIR='$UI_DIR'."; return 1; }
    [[ "$p" == "$UI_DIR" ]] \
        || { err "Refusing aliased fixed UI root: $UI_DIR -> $p"; return 1; }
    case "$p" in
        /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/home|/home/*|/lib|/lib/*|/lib64|/lib64/*|/opt|/private/etc|/private/etc/*|/private/tmp|/private/tmp/*|/private/var|/private/var/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/srv|/sys|/sys/*|/tmp|/tmp/*|/usr|/usr/*|/var|/var/*|"$BASE_DIR"|"$CONF_DIR")
            err "Refusing unsafe UI_DIR: $p"; return 1 ;;
    esac
    printf '%s\n' "$p"
}

load_ui_generation_helper() {
    local helper="${SCRIPT_DIR}/scripts/ui-generation.sh" before="" after=""
    local hash_fd source_fd hash_metadata source_metadata fd_digest
    [[ "$UI_GENERATION_HELPER_LOADED" == 1 ]] && return 0
    [[ -f "$helper" && ! -L "$helper" ]] \
        || { err "Required UI generation helper is missing or unsafe: $helper"; return 1; }
    if [[ "$SCRIPT_DIR" == "$BASE_DIR" ]]; then
        [[ -d "$SCRIPTS_DIR" && ! -L "$SCRIPTS_DIR" \
           && "$(readlink -f -- "$SCRIPTS_DIR")" == "$SCRIPTS_DIR" \
           && "$(stat -Lc '%u:%g:%a' -- "$SCRIPTS_DIR")" == 0:0:755 ]] \
            || { err "Installed script directory metadata is unsafe."; return 1; }
        [[ "$(stat -Lc '%u:%g:%a:%h' -- "$helper" 2>/dev/null)" == 0:0:755:1 ]] \
            || { err "Installed UI generation helper metadata is unsafe."; return 1; }
        before="$(release_pin_file_state "$helper")" \
            || { err "Could not bind the installed UI generation helper."; return 1; }
        exec {hash_fd}<"$helper" || return 1
        exec {source_fd}<"$helper" || { exec {hash_fd}<&-; return 1; }
        hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
            || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
        source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
            || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
        [[ "$hash_metadata" == "${before%:*}" && "$source_metadata" == "${before%:*}" ]] \
            || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
        fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
            || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
        exec {hash_fd}<&-
        [[ "$fd_digest" == "${before##*:}" ]] || { exec {source_fd}<&-; return 1; }
        # shellcheck source=scripts/ui-generation.sh
        source "/proc/self/fd/$source_fd" || { exec {source_fd}<&-; return 1; }
        exec {source_fd}<&-
    else
        # shellcheck source=scripts/ui-generation.sh
        source "$helper" || return 1
    fi
    if [[ -n "$before" ]]; then
        after="$(release_pin_file_state "$helper")" \
            || { err "Could not revalidate the installed UI generation helper."; return 1; }
        [[ "$after" == "$before" ]] \
            || { err "Installed UI generation helper changed while it was loaded."; return 1; }
    fi
    [[ "$UI_GENERATION_ROOT" == "$UI_DIR" \
       && "$UI_GENERATION_MARKER" == "$ZASH_OWNERSHIP_MARKER" \
       && "$UI_GENERATION_MARKER_VALUE" == "$ZASH_OWNERSHIP_VALUE" ]] \
        || { err "UI generation helper constants drifted from the installer contract."; return 1; }
    UI_GENERATION_HELPER_LOADED=1
}

CERT_ROLE_HELPERS_LOADED=0

load_cert_role_helpers() {
    local helper path before after hash_fd source_fd hash_metadata source_metadata fd_digest
    local -a helpers=(publication-fs.sh cert-role-ctl.sh)
    if [[ "$CERT_ROLE_HELPERS_LOADED" != 1 ]]; then
        for helper in "${helpers[@]}"; do
            path="${SCRIPT_DIR}/scripts/${helper}"
            [[ -f "$path" && ! -L "$path" ]] \
                || { err "Required certificate publication helper is missing or unsafe: $path"; return 1; }
            if [[ "$SCRIPT_DIR" == "$BASE_DIR" ]]; then
                before="$(installed_runtime_script_state "$path")" \
                    || { err "Installed certificate publication helper metadata is unsafe: $path"; return 1; }
                exec {hash_fd}<"$path" || return 1
                exec {source_fd}<"$path" || { exec {hash_fd}<&-; return 1; }
                hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
                    || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
                source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
                    || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
                [[ "$hash_metadata" == "${before%:*}" && "$source_metadata" == "${before%:*}" ]] \
                    || { exec {hash_fd}<&-; exec {source_fd}<&-; err "Certificate publication helper changed while it was anchored: $path"; return 1; }
                fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
                    || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
                exec {hash_fd}<&-
                [[ "$fd_digest" == "${before##*:}" ]] \
                    || { exec {source_fd}<&-; err "Certificate publication helper bytes differ from the anchored path: $path"; return 1; }
                # shellcheck source=/dev/null
                source "/proc/self/fd/$source_fd" || { exec {source_fd}<&-; return 1; }
                exec {source_fd}<&-
                after="$(installed_runtime_script_state "$path")" \
                    || { err "Could not revalidate installed certificate publication helper: $path"; return 1; }
                [[ "$after" == "$before" ]] \
                    || { err "Installed certificate publication helper changed while it was loaded: $path"; return 1; }
            else
                # The release-bundle source lease and generation binding cover
                # source execution outside the installed management tree.
                # shellcheck source=/dev/null
                source "$path" || return 1
            fi
        done
        declare -F publication_fs_commit_relative_pointer >/dev/null 2>&1 \
            && [[ "${CERT_ROLE_CTL_API_VERSION:-0}" == 1 ]] \
            || { err "Certificate publication helper API mismatch."; return 1; }
        CERT_ROLE_HELPERS_LOADED=1
    fi
    CERT_ROLE_CTL_ROOT="$DNS_CERT_DIR"
    CERT_ROLE_CTL_SERVICE_GROUP="$FIVEGPN_SERVICE_GROUP"
    CERT_ROLE_CTL_CONFIG_MARKER="$CONF_OWNERSHIP_MARKER"
    CERT_ROLE_CTL_CONFIG_MARKER_VALUE="$CONF_OWNERSHIP_VALUE"
    CERT_ROLE_CTL_ROOT_MARKER="$CERT_ROOT_MARKER"
    CERT_ROLE_CTL_ROOT_MARKER_VALUE="$CERT_ROOT_MARKER_VALUE"
    CERT_ROLE_CTL_ROLE_MARKER="$CERT_ROLE_MARKER"
    CERT_ROLE_CTL_ROLE_VALUE_PREFIX="$CERT_ROLE_VALUE_PREFIX"
    CERT_ROLE_CTL_ALLOW_CREATE=0
    CERT_ROLE_CTL_SERVICE_GID=""
    CERT_ROLE_CTL_ADDITIONAL_GIDS="${REPLACED_FIVEGPN_GID:-}:${REPLACED_FIVEGPN_NAMED_GID:-}"
    if [[ "${INSTALL_SH_LIB_ONLY:-0}" == 1 && "$DNS_CERT_DIR" != /etc/5gpn/cert ]]; then
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=1
    else
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=0
    fi
}

cert_role_ctl_group_gid_override() {
    account_gid "$1"
}

installed_runtime_script_state() {
    local path="$1"
    [[ "$path" == "$SCRIPTS_DIR"/* \
       && -d "$SCRIPTS_DIR" && ! -L "$SCRIPTS_DIR" \
       && "$(readlink -f -- "$SCRIPTS_DIR")" == "$SCRIPTS_DIR" \
       && "$(stat -Lc '%u:%g:%a' -- "$SCRIPTS_DIR")" == 0:0:755 \
       && -f "$path" && ! -L "$path" \
       && "$(readlink -f -- "$path")" == "$path" \
       && "$(stat -Lc '%u:%g:%a:%h' -- "$path" 2>/dev/null)" == 0:0:755:1 ]] \
        || return 1
    release_pin_file_state "$path"
}

preflight_ui_dir() {
    local p
    p="$(safe_ui_path)" || return 1
    load_ui_generation_helper || return 1
    ui_generation_preflight "$p" \
        || { err "Refusing unsafe or unowned UI_DIR before staging: $p"; return 1; }
}

# Claim the stable UI generation root without publishing a live generation.
# A populated unmarked root and the retired flat-tree schema are never adopted.
claim_ui_dir() {
    local p
    preflight_ui_dir || return 1
    p="$(safe_ui_path)" || return 1
    ui_generation_claim_root "$p" \
        || { err "Could not establish the safe UI generation root: $p"; return 1; }
}


remove_ui_dir() {
    local p
    p="$(safe_ui_path)" || return 1
    [[ ! -e "$p" && ! -L "$p" ]] && return 0
    load_ui_generation_helper || return 1
    ui_generation_remove_root "$p" \
        || { err "Refusing to remove an unsafe UI generation tree: $p"; return 1; }
}

# Bootstrap Gum in an owned temporary directory. It is usable for every prompt
# without claiming /opt/5gpn or publishing a marker. Once all read-only gates
# pass and project publication begins, publish_verified_gum may copy the exact
# verified binary into the owned runtime root. Any failure remains non-fatal.
install_gum() {
    local arch asset url tmp exp got bin m
    if ! assert_release_pin_bundle_revision; then
        warn "release pin files changed; refusing the optional Gum download and using plain output."
        return 0
    fi
    if [[ -n "$TEMP_GUM_DIR" ]]; then
        cleanup_temporary_gum \
            || { warn "gum: previous temporary staging could not be cleaned; using plain output."; return 0; }
    fi
    _HAVE_GUM=0
    PATH="$INSTALL_ORIGINAL_PATH"
    export PATH
    activate_verified_installed_gum
    [[ "$_HAVE_GUM" == 1 ]] && return 0
    m="$(uname -m 2>/dev/null || echo x86_64)"
    case "$m" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armhf)  arch="armv7" ;;
        *)             arch="x86_64" ;;
    esac
    if ! asset="$(release_asset_name gum "$arch")" \
       || ! url="$(release_download_url gum "$arch")" \
       || ! exp="$(release_artifact_sha256 gum "$arch")"; then
        warn "gum release coordinates are invalid; using plain output."
        return 0
    fi
    info "Downloading optional Gum ${GUM_VERSION} TUI helper ${asset} (up to 60s; plain output remains available)."
    tmp="$(mktemp -d /tmp/5gpn-gum.XXXXXX 2>/dev/null)" || { warn "gum: mktemp failed; using plain output."; _HAVE_GUM=0; return 0; }
    claim_temp_dir "$tmp" || { rmdir -- "$tmp" 2>/dev/null || true; warn "gum: could not claim temp directory; using plain output."; return 0; }
    TEMP_GUM_DIR="$tmp"
    if ! command -v curl >/dev/null 2>&1 \
       || ! curl -fsSL --connect-timeout 10 --max-time 60 \
            "$url" -o "$tmp/gum.tgz" 2>/dev/null; then
        warn "gum download failed; using plain output."
        cleanup_temporary_gum || true
        return 0
    fi
    if [[ ! "$exp" =~ ^[0-9a-f]{64}$ ]]; then
        warn "gum pinned checksum is missing or invalid; refusing to install it and using plain output."
        cleanup_temporary_gum || true
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        got="$(sha256sum "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
    elif command -v shasum >/dev/null 2>&1; then
        got="$(shasum -a 256 "$tmp/gum.tgz" 2>/dev/null | awk '{print $1}' || true)"
    else
        warn "no SHA-256 tool is available; refusing to install gum and using plain output."
        cleanup_temporary_gum || true
        return 0
    fi
    got="${got,,}"
    if [[ "$got" != "$exp" ]]; then
        warn "gum sha256 mismatch; refusing to install it and using plain output."
        cleanup_temporary_gum || true
        return 0
    fi
    if ! archive_paths_safe tar "$tmp/gum.tgz" \
       || ! tar --no-same-owner --no-same-permissions --delay-directory-restore \
            -xzf "$tmp/gum.tgz" -C "$tmp" 2>/dev/null \
       || ! extracted_tree_safe "$tmp"; then
        warn "gum archive extraction failed; using plain output."
        cleanup_temporary_gum || true
        return 0
    fi
    bin="$(find "$tmp" -type f -name gum 2>/dev/null | head -1 || true)"
    if [[ -z "$bin" || ! -f "$bin" || -L "$bin" || "$(file_nlink "$bin")" != 1 ]] \
       || ! chmod 0755 "$bin" \
       || ! "$bin" --version 2>/dev/null | grep -qF "$GUM_VERSION"; then
        warn "verified gum archive did not contain a usable ${GUM_VERSION} binary; using plain output."
        cleanup_temporary_gum || true
        return 0
    fi
    TEMP_GUM_BIN="$bin"
    PATH="$(dirname -- "$TEMP_GUM_BIN"):${INSTALL_ORIGINAL_PATH}"
    export PATH
    if [[ "$(command -v gum 2>/dev/null || true)" == "$TEMP_GUM_BIN" ]] \
       && gum --version 2>/dev/null | grep -qF "$GUM_VERSION"; then
        _HAVE_GUM=1
    else
        cleanup_temporary_gum || true
        warn "gum verification succeeded but the temporary binary is unavailable; using plain output."
    fi
    return 0
}

activate_verified_installed_gum() {
    _HAVE_GUM=0
    PATH="$INSTALL_ORIGINAL_PATH"
    export PATH
    fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        || return 0
    [[ -f "$GUM_BIN" && ! -L "$GUM_BIN" \
       && "$(file_uid "$GUM_BIN")" == 0 \
       && "$(file_gid "$GUM_BIN")" == 0 \
       && "$(file_mode "$GUM_BIN")" == 755 \
       && "$(file_nlink "$GUM_BIN")" == 1 ]] || return 0
    "$GUM_BIN" --version 2>/dev/null | grep -qF "$GUM_VERSION" || return 0
    PATH="${BIN_DIR}:${INSTALL_ORIGINAL_PATH}"
    export PATH
    [[ "$(command -v gum 2>/dev/null || true)" == "$GUM_BIN" ]] || return 0
    _HAVE_GUM=1
}

cleanup_temporary_gum() {
    [[ -n "$TEMP_GUM_DIR" ]] || return 0
    _HAVE_GUM=0
    PATH="$INSTALL_ORIGINAL_PATH"
    export PATH
    TEMP_GUM_BIN=""
    remove_temp_dir "$TEMP_GUM_DIR" || return 1
    TEMP_GUM_DIR=""
}

publish_verified_gum() {
    [[ -n "$TEMP_GUM_DIR" ]] || { activate_verified_installed_gum; return 0; }
    [[ -n "$TEMP_GUM_BIN" ]] \
        || { cleanup_temporary_gum || true; activate_verified_installed_gum; return 0; }
    fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$BIN_DIR" "$BASE_DIR" \
        || { warn "gum could not be published inside the owned runtime root; using plain output."
             cleanup_temporary_gum || true; return 0; }
    if ! publish_executable "$TEMP_GUM_BIN" "$GUM_BIN" 2>/dev/null; then
        warn "gum publication failed; using plain output."
        cleanup_temporary_gum || true
        return 0
    fi
    cleanup_temporary_gum \
        || { warn "gum was published but its temporary directory could not be removed."; return 0; }
    activate_verified_installed_gum
    [[ "$_HAVE_GUM" == 1 ]] \
        || warn "gum was published but failed its installed verification; using plain output."
    return 0
}

install_gum_for_managed_deployment() {
    install_gum
    publish_verified_gum
    if [[ -n "$TEMP_GUM_DIR" ]]; then
        cleanup_temporary_gum \
            || { err "Temporary Gum staging was retained at: $TEMP_GUM_DIR"; return 1; }
    fi
}

check_root() {
    if ! process_is_root; then
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

# CPU arch guard: the mihomo download below is a linux-amd64 prebuilt. Without
# this, an ARM
# box installs to the end, prints ✅, and the services die with "exec format
# error" at first start. Refuse early instead. (gum's own bootstrap is
# multi-arch and unaffected — but there is nothing for it to install.)
check_arch() {
    local m; m="$(uname -m 2>/dev/null || echo unknown)"
    case "$m" in
        x86_64|amd64) ;;
        *)
            err "Unsupported CPU architecture '${m}': only a linux-amd64 5gpn-mihomo binary is published."
            err "Use an x86_64 host, or build the 5gpn mihomo fork for this architecture and install it manually."
            exit 1
            ;;
    esac
}

# Sets MEM_TOTAL_MB and LOWMEM (0/1) from host memory. Low-memory mode only
# decides whether this installer offers a private swapfile; DNS tuning belongs
# to the live dns.json document and is never inferred from the installer host.
detect_memory_profile() {
    MEM_TOTAL_MB=$(awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "${MEM_TOTAL_MB:-0}" -le 1300 ]]; then LOWMEM=1; else LOWMEM=0; fi

    if [[ "$LOWMEM" == "1" ]]; then
        warn "Low-memory mode ON (RAM ${MEM_TOTAL_MB}MB): private swap will be ensured when possible."
    else
        info "Standard memory mode (RAM ${MEM_TOTAL_MB}MB)."
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

# Expands the seed template. One implementation, two callers.
#
# Artifact staging and the live render used to carry the same expansion inline,
# differing only in the values they substituted and in whether the overlay
# probe was allowed placeholder identities. A placeholder added to the template
# therefore had to be taught to both, and the day one of them was missed is the
# day a release run failed on a config that was not YAML.
#
# Values arrive through the environment under the placeholder's own name, so a
# caller that forgets one substitutes empty rather than leaving the literal —
# and tests/test_seed_template_renderers.sh is what fails when a placeholder is
# added here and nowhere else.
render_mihomo_seed() {
    local template="$1" mode="${2:-live}" listeners="$3" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            __MIHOMO_LISTENERS__)
                printf '%s\n' "$listeners"
                continue ;;
        esac
        line="${line//__CONSOLE_DOMAIN__/$SEED_CONSOLE_DOMAIN}"
        line="${line//__CONTROLLER_SECRET__/$SEED_CONTROLLER_SECRET}"
        printf '%s\n' "$line"
    done < "$template"
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
                Restart*|Kill*|TimeoutStartSec|OOMPolicy|Delegate*|Slice|DisableControllers|\
                Memory*|StartupMemory*|AllowedMemoryNodes|StartupAllowedMemoryNodes|\
                CPU*|StartupCPU*|AllowedCPUs|StartupAllowedCPUs|\
                IO*|StartupIO*|BlockIO*|StartupBlockIO*|Tasks*|ManagedOOM*|\
                Limit*|Nice|OOMScoreAdjust|TimerSlackNSec|NUMA*|\
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
                service:'[Unit]')
                    [[ "$line" == *=* ]] || continue
                    key="${line%%=*}"
                    key="${key//[[:space:]]/}"
                    [[ "$key" == StartLimit* ]] && return 0
                    continue ;;
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

# A systemd template (`name@.service`) is a definition, not a unit: without an
# instance there is nothing to start, stop, enable, or report on. `systemctl`
# answers status queries for one with an empty string and fails `disable --now`,
# so every caller that treats it like an ordinary unit reads "broken" off a name
# that is working exactly as designed. Its unit *file* is still snapshotted,
# restored, and removed with the rest.
unit_is_template() {
    [[ "${1%.*}" == *@ ]]
}

# The fixed unit names this installer writes are its own deployment artifacts.
# Their exact unit-id marker and root-owned 0644 ordinary-file metadata are the
# ownership fingerprint for replacement and removal. Two things this
# deliberately does not do:
#
#   - It does not inspect the installed unit's body. Doing so cannot pin what we
#     ship -- it can only reject a host that has not upgraded yet, which is every
#     host mid-upgrade. The unit contents are pinned by the repository policy
#     suites against etc/systemd/, where a silent edit actually gets caught.
#   - Removal itself does not classify drop-ins. Publication separately rejects
#     overrides that would change the managed main-unit security contract.
remove_unit() {
    # Two statements: bash expands every word of a `local` before it assigns any
    # of them, so a second word reading "$unit" would get the caller's variable
    # of that name -- an unbound-variable abort under set -u, or worse, silently
    # the wrong path when the caller happens to have one.
    local unit="$1"
    local file="/etc/systemd/system/$unit"
    [[ -e "$file" || -L "$file" ]] || return 0
    current_managed_unit_file_is_safe "$unit" \
        || { err "Refusing to remove an unsafe or unmarked managed unit: $unit"; return 1; }
    # A template name carries no runtime state, so the stop-and-disable gate
    # below would refuse to delete a file that is perfectly safe to delete.
    if unit_is_template "$unit"; then
        rm -f -- "$file" || { err "Could not delete unit file: $unit"; return 1; }
        [[ ! -e "$file" && ! -L "$file" ]] \
            || { err "Unit file still exists after removal: $unit"; return 1; }
        ok "Removed unit: $unit"
        return 0
    fi
    systemctl disable --now "$unit" 2>/dev/null \
        || { err "Could not stop and disable $unit; refusing to delete its unit file."; return 1; }
    rm -f -- "$file" || { err "Could not delete unit file: $unit"; return 1; }
    [[ ! -e "$file" && ! -L "$file" ]] \
        || { err "Unit file still exists after removal: $unit"; return 1; }
    ok "Removed unit: $unit"
}

unit_file_has_5gpn_marker() {
    local unit="$1" file="/etc/systemd/system/$1" root_gid mode
    root_gid="$(account_gid root)" || return 1
    mode="$(file_mode "$file")"
    [[ -f "$file" && ! -L "$file" \
       && "$(file_uid "$file")" == 0 \
       && "$(file_gid "$file")" == "$root_gid" \
       && "$(file_nlink "$file")" == 1 ]] \
        && mode_has_no_group_or_other_write "$mode" || return 1
    grep -m1 -Fxq "# 5gpn-unit-id: ${unit}:v1" "$file" 2>/dev/null \
        || grep -m1 -Eq "^# 5gpn-unit-id: ${unit//./\\.}:v[0-9]+$" "$file" 2>/dev/null
}

# A retired unit is a footprint when systemd knows any definition for its exact
# name, regardless of who wrote the bytes. Inspect both the manager's resolved
# view and every standard definition directory so an unloaded, shadowed, masked,
# generated, or vendor unit cannot escape the read-only compatibility gate.
unit_definition_exists() {
    local unit="$1" load_state fragment_path root
    local -a roots=(/etc/systemd/system.control /run/systemd/system.control \
                    /run/systemd/transient /run/systemd/generator.early \
                    /etc/systemd/system /etc/systemd/system.attached \
                    /run/systemd/system /run/systemd/system.attached \
                    /run/systemd/generator /usr/local/lib/systemd/system \
                    /usr/lib/systemd/system /lib/systemd/system \
                    /run/systemd/generator.late)
    [[ "$unit" =~ ^[A-Za-z0-9_.@-]+$ ]] || return 1
    load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
    fragment_path="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
    [[ -n "$fragment_path" ]] && return 0
    [[ -n "$load_state" && "$load_state" != not-found ]] && return 0
    for root in "${roots[@]}"; do
        [[ -e "${root}/${unit}" || -L "${root}/${unit}" \
           || -e "${root}/${unit}.d" || -L "${root}/${unit}.d" ]] \
            && return 0
    done
    return 1
}

current_managed_unit_file_is_safe() {
    local unit="$1" file="/etc/systemd/system/$1"
    unit_file_has_5gpn_marker "$unit" \
        && [[ "$(file_mode "$file")" == 644 ]]
}

# A current managed name is replaceable only when its sole definition is the
# exact root-owned ordinary file that this installer manages. A vendor copy,
# generator output, transient/control definition, mask, alias, or unsafe local
# file is rejected before publication instead of being silently shadowed.
preflight_current_managed_unit_definition() {
    local unit="$1" file="/etc/systemd/system/$1" load_state fragment_path root
    local -a roots=(/etc/systemd/system.control /run/systemd/system.control \
                    /run/systemd/transient /run/systemd/generator.early \
                    /etc/systemd/system.attached /run/systemd/system \
                    /run/systemd/system.attached /run/systemd/generator \
                    /usr/local/lib/systemd/system /usr/lib/systemd/system \
                    /lib/systemd/system /run/systemd/generator.late)
    [[ "$unit" =~ ^[A-Za-z0-9_.@-]+$ ]] \
        || { err "Invalid managed systemd unit name: $unit"; return 1; }
    load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
    fragment_path="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
    for root in "${roots[@]}"; do
        if [[ -e "${root}/${unit}" || -L "${root}/${unit}" ]]; then
            err "Refusing a managed unit definition outside /etc/systemd/system: ${root}/${unit}"
            return 1
        fi
    done
    if [[ -e "$file" || -L "$file" ]]; then
        current_managed_unit_file_is_safe "$unit" \
            || { err "Refusing an unsafe or unmarked managed unit file: $file"; return 1; }
    fi
    if [[ -n "$fragment_path" && "$fragment_path" != "$file" ]]; then
        err "Refusing managed unit ${unit}: systemd resolves it to ${fragment_path}."
        return 1
    fi
    if [[ -n "$load_state" && "$load_state" != not-found ]]; then
        [[ "$fragment_path" == "$file" && ( -e "$file" || -L "$file" ) ]] \
            || { err "Refusing managed unit ${unit}: LoadState=${load_state} is not resolved to the exact local definition."; return 1; }
        current_managed_unit_file_is_safe "$unit" \
            || { err "Refusing managed unit ${unit}: its loaded definition is not current 5gpn state."; return 1; }
    elif [[ -n "$fragment_path" ]]; then
        err "Refusing managed unit ${unit}: FragmentPath is set while LoadState is not-found."
        return 1
    fi
}

legacy_dns_env_key_is_known() {
    case "$1" in
        DNS_CHINA|DNS_CHINA_0X20|DNS_TRUST|DNS_WEB_DIR|DNS_ZASH_DIR|DNS_ZASH_LISTEN|DNS_WHITELIST_FILE|DNS_API_TOKEN|\
        TGBOT_TOKEN|TGBOT_ADMINS|DNS_TGBOT_FILE|TGBOT_PROXY_URL|TGBOT_ALERTS|DNS_MARKETPLACES_FILE|\
        DNS_ZASH_CERT|DNS_ZASH_KEY|DNS_WEB_CERT|DNS_WEB_KEY|DNS_INTERCEPT_CONFIG|WWW_DIR|\
        DNS_LISTEN_API|DNS_CERT|DNS_KEY|DNS_UPSTREAMS|DNS_ECS_FILE|DNS_RULES_DIR|DNS_CHNROUTE|DNS_EGRESS_BROKER|DNS_EGRESS_RESOLVER|\
        DNS_SUBSCRIPTIONS|DNS_POLICY_RULES|DNS_API_RATE|DNS_API_BURST|DNS_MIHOMO_CONFIG|\
        DNS_CACHE_SIZE|DNS_MAX_INFLIGHT|DNS_TTL_MIN|DNS_TTL_MAX|DNS_QUERY_TIMEOUT|DNS_STATS_FILE|\
        DNS_HEARTBEAT_URL|DNS_HEARTBEAT_INTERVAL|DNS_CHINA_ECS|\
        DNS_LISTEN_DOT|DNS_LISTEN_DEBUG|DNS_CONSOLE_CERT|DNS_CONSOLE_KEY|\
        DNS_MIHOMO_CONTROLLER|DNS_MIHOMO_SECRET)
            return 0 ;;
        *) return 1 ;;
    esac
}

# Validate only the installation-owned projection of a Core-validated DNS
# document. Full schema and semantic validation belongs to the staged pinned
# Core; this shell boundary pins the fields that a reinstall may neither repair
# nor reinterpret.
current_dns_document_is_compatible() {
    local file="$1"
    local cert="${DOT_CERT_DIR}/current/fullchain.pem"
    local key="${DOT_CERT_DIR}/current/privkey.pem"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    jq -e \
        --arg dot "$DOT_LISTEN_ADDR" \
        --arg debug "$DEBUG_LISTEN_ADDR" \
        --arg origin "$ORIGIN_LISTEN_ADDR" \
        --arg cert "$cert" \
        --arg key "$key" '
            type == "object"
            and (.gateway | type == "string")
            and (.listen | type == "object")
            and (.listen.dot == $dot)
            and (.listen.debug == $debug)
            and (.listen.origin == $origin)
            and (.listen.certificate == $cert)
            and (.listen.privateKey == $key)
        ' "$file" >/dev/null 2>&1
}

# jq uses IEEE-754 numbers. The Core accepts 64-bit integer fields, so a
# gateway-only rewrite is safe only when every existing number is exactly
# representable and integral. The staged Core remains the schema authority.
dns_document_is_jq_gateway_update_safe() {
    local file="$1"
    jq -e '
        [.. | numbers]
        | all(. == floor and . >= -9007199254740991 and . <= 9007199254740991)
    ' "$file" >/dev/null 2>&1
}

validate_dns_candidate_with_core() {
    local candidate="$1" validator="$2" validator_label="$3" probe_parent="$4"
    local owner_uid probe_dir probe_file rc=0
    [[ -x "$validator" ]] \
        || { err "The ${validator_label} is unavailable for DNS candidate validation."; return 1; }
    [[ -d "$probe_parent" && ! -L "$probe_parent" ]] \
        || { err "The DNS candidate validation root is unavailable: $probe_parent"; return 1; }
    owner_uid="$(id -u "$FIVEGPN_SERVICE_USER")" || return 1
    probe_dir="$(mktemp -d "${probe_parent}/dns-candidate-probe.XXXXXX")" || return 1
    probe_file="${probe_dir}/dns.json"
    if ! install -o "$FIVEGPN_SERVICE_USER" -g "$FIVEGPN_SERVICE_GROUP" -m 0600 \
            "$candidate" "$probe_file"; then
        rmdir -- "$probe_dir" 2>/dev/null || true
        return 1
    fi
    timeout --kill-after=5s 30s "$validator" 5gpn-state validate \
        --owner-uid "$owner_uid" "$probe_dir" >/dev/null || rc=$?
    rm -f -- "$probe_file"
    rmdir -- "$probe_dir" \
        || { err "Could not remove the DNS candidate validation directory."; return 1; }
    [[ "$rc" == 0 ]] \
        || { err "The ${validator_label} rejected the DNS gateway-update candidate."; return "$rc"; }
}

validate_dns_candidate_with_staged_core() {
    validate_dns_candidate_with_core "$1" "${ARTIFACT_STAGE}/mihomo" \
        "staged Core" "$ARTIFACT_STAGE"
}

validate_dns_candidate_with_installed_core() {
    local probe_parent
    probe_parent="$(dirname -- "$INSTALL_LOCK_FILE")"
    validate_dns_candidate_with_core "$1" "$MIHOMO_BIN" \
        "installed Core" "$probe_parent"
}

noncomment_config_matches() {
    local file="$1" pattern="$2"
    awk -v pattern="$pattern" '
        {
            line = $0
            sub(/^[[:space:]]*#.*/, "", line)
            sub(/[[:space:]]+#.*/, "", line)
            if (line ~ pattern) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

noncomment_config_contains() {
    local file="$1" needle="$2"
    awk -v needle="$needle" '
        {
            line = $0
            sub(/^[[:space:]]*#.*/, "", line)
            sub(/[[:space:]]+#.*/, "", line)
            if (index(tolower(line), tolower(needle)) != 0) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

# Previous layouts are not migration inputs. This detector reads exact
# project-specific account/unit names and known child paths below a canonical
# fixed root whose top-level metadata is safe, even when that root has not yet
# received a current marker. That keeps safe fixed-root adoption from hiding a
# legacy footprint. It never stops a unit, changes an account, rewrites
# configuration, publishes a marker, or removes a file.
detect_legacy_footprints() {
    local found=0 base_inspectable=0 conf_inspectable=0 state_inspectable=0
    local path unit user group line key
    local base_raw="" legacy_base=""
    local conf_marker="${CONF_DIR}/${CONF_OWNERSHIP_MARKER}"
    local ui_marker="${UI_DIR}/${ZASH_OWNERSHIP_MARKER}"
    local env="${CONF_DIR}/dns.env" config="${MIHOMO_DIR}/config.yaml"
    local polkit_rule="/etc/polkit-1/rules.d/50-5gpn.rules"

    legacy_found() {
        err "Legacy 5gpn footprint: $1"
        found=1
    }

    fixed_root_is_safe_for_readonly_inspection "$BASE_DIR" && base_inspectable=1
    fixed_root_is_safe_for_readonly_inspection "$CONF_DIR" && conf_inspectable=1
    fixed_root_is_safe_for_readonly_inspection "$STATE_DIR" && state_inspectable=1

    if [[ -f "$conf_marker" && ! -L "$conf_marker" \
       && "$(file_uid "$conf_marker")" == 0 \
       && "$(cat "$conf_marker" 2>/dev/null || true)" == "5gpn-config-v1" ]]; then
        conf_inspectable=1
        legacy_found "$conf_marker uses the retired 5gpn-config-v1 root marker"
    fi
    if [[ "$conf_inspectable" == 1 && "$(file_mode "$CONF_DIR")" == 2771 ]]; then
        legacy_found "$CONF_DIR uses the retired non-sticky 2771 configuration-root mode"
    fi

    for unit in mihomo.service 5gpn-dns.service 5gpn-intercept.service \
                5gpn-intercept-runtime.path 5gpn-journal@.service \
                5gpn-journal@5gpn-dns.service 5gpn-journal@mihomo.service; do
        unit_definition_exists "$unit" \
            && legacy_found "systemd has a retired unit definition for ${unit}"
    done
    if [[ -f "$polkit_rule" && ! -L "$polkit_rule" ]] \
       && grep -m1 -Eq '^// 5gpn-polkit-id: runtime-operations' "$polkit_rule" 2>/dev/null; then
        legacy_found "$polkit_rule carries the retired 5gpn runtime-operations marker"
    fi
    if [[ -e /run/5gpn-journal || -L /run/5gpn-journal ]]; then
        legacy_found "/run/5gpn-journal exists"
    fi
    if root_ownership_marker_is_safe "${DNS_CERT_DIR}/zash" "$CERT_ROLE_MARKER" \
        "${CERT_ROLE_VALUE_PREFIX}:zash"; then
        legacy_found "${DNS_CERT_DIR}/zash carries the retired zash certificate-role marker"
    fi
    if root_ownership_marker_is_safe "${DNS_CERT_DIR}/web" "$CERT_ROLE_MARKER" \
        "${CERT_ROLE_VALUE_PREFIX}:web"; then
        legacy_found "${DNS_CERT_DIR}/web carries the retired web certificate-role marker"
    fi
    if root_ownership_marker_is_safe "${DNS_CERT_DIR}/console" "$CERT_ROLE_MARKER" \
        "${CERT_ROLE_VALUE_PREFIX}:zash"; then
        legacy_found "${DNS_CERT_DIR}/console still carries the retired zash certificate-role marker"
    fi

    for user in mihomo gpn-dns gpn-intercept; do
        getent passwd "$user" >/dev/null 2>&1 \
            && legacy_found "the retired service account name '${user}' exists"
    done
    for group in mihomo gpn-dns gpn-intercept 5gpn-overlay-ctl 5gpn-overlay-gen; do
        getent group "$group" >/dev/null 2>&1 \
            && legacy_found "the retired service group name '${group}' exists"
    done

    if [[ "$base_inspectable" == 1 ]]; then
        if [[ -f "$ui_marker" && ! -L "$ui_marker" \
           && "$(file_uid "$ui_marker")" == 0 \
           && "$(cat "$ui_marker" 2>/dev/null || true)" == "5gpn-zashboard" ]]; then
            legacy_found "$UI_DIR uses the retired flat-UI ownership marker"
        fi
        for path in "$UI_DIR/index.html" "$UI_DIR/.zash_version" \
                    "$UI_DIR/ios-dot.mobileconfig" "$UI_DIR/ios-intercept-ca.mobileconfig"; do
            [[ ! -e "$path" && ! -L "$path" ]] \
                || legacy_found "$path is a retired flat UI/profile publication"
        done
        if [[ -e "$UI_DIR/current" || -L "$UI_DIR/current" ]]; then
            [[ -L "$UI_DIR/current" ]] \
                || legacy_found "$UI_DIR/current is not the current relative generation symlink"
        fi
        for path in \
            "${BIN_DIR}/mihomo" "${BIN_DIR}/5gpn-dns" "${BIN_DIR}/5gpn-intercept" \
            "${BIN_DIR}/gpn-dns" "${BIN_DIR}/gpn-intercept" \
            "${BASE_DIR}/www" \
            "${BASE_DIR}/etc/systemd/mihomo.service" \
            "${BASE_DIR}/etc/systemd/5gpn-dns.service" \
            "${BASE_DIR}/etc/systemd/5gpn-intercept.service" \
            "${BASE_DIR}/etc/systemd/5gpn-intercept-runtime.path" \
            "${BASE_DIR}/etc/systemd/5gpn-journal@.service" \
            "${SCRIPTS_DIR}/migrate-panel-to-console.sh" \
            "${SCRIPTS_DIR}/migrate-state-to-monolith.sh" \
            "${SCRIPTS_DIR}/migrate-to-monolith.sh"; do
            [[ ! -e "$path" && ! -L "$path" ]] || legacy_found "$path exists below the owned runtime root"
        done
    fi

    if [[ "$conf_inspectable" == 1 ]]; then
        for path in \
            "${MIHOMO_DIR}/gpn" "${MIHOMO_DIR}/whitelist.txt" \
            "${DNS_CERT_DIR}/zash" "${DNS_CERT_DIR}/web" \
            "${CONF_DIR}/rules" "${CONF_DIR}/subscriptions.json" \
            "${CONF_DIR}/policy.json" "${CONF_DIR}/upstreams.json" \
            "${CONF_DIR}/ecs.json" "${CONF_DIR}/stats.json" \
            "${CONF_DIR}/tgbot.json" "${CONF_DIR}/extension-marketplaces.json" \
            "${INTERCEPT_DIR}/config.json"; do
            [[ ! -e "$path" && ! -L "$path" ]] || legacy_found "$path exists below the owned configuration root"
        done
        if [[ -f "$env" && ! -L "$env" ]]; then
            base_raw="$(grep -E '^DNS_BASE_DOMAIN=' "$env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
            legacy_base="$(printf '%s' "$base_raw" | tr '[:upper:]' '[:lower:]')"
            if grep -Eq '^DNS_MIHOMO_CONTROLLER=127\.0\.0\.1:9090[[:space:]]*$|^DNS_CONSOLE_(CERT|KEY)=.*/(zash|web)/' \
                "$env" 2>/dev/null; then
                legacy_found "$env contains retired panel controller or certificate coordinates"
            fi
            while IFS= read -r line || [[ -n "$line" ]]; do
                case "$line" in ''|\#*|*=*) ;; *) continue ;; esac
                key="${line%%=*}"
                legacy_dns_env_key_is_known "$key" \
                    && legacy_found "$env contains retired key ${key}"
            done < "$env"
        fi
        if [[ -f "$config" && ! -L "$config" ]] \
           && { noncomment_config_matches "$config" \
                    '(^|[^[:alnum:]_-])RUNTIME-OVERLAY,[[:space:]]*5gpn[[:space:]]*,' \
                || noncomment_config_matches "$config" \
                    '^runtime-overlay-processor[[:space:]]*:' \
                || noncomment_config_matches "$config" \
                    '(^|[^[:alnum:]_-])IN-NAME,[[:space:]]*intercept-egress[[:space:]]*,' \
                || noncomment_config_matches "$config" \
                    '(^|[[:space:]{,])name[[:space:]]*:[[:space:]]*intercept-egress([[:space:]]*[,}]|[[:space:]]*$)' \
                || noncomment_config_matches "$config" \
                    '(^|[[:space:]{,])name[[:space:]]*:[[:space:]]*MODULE-INTERCEPT([[:space:]]*[,}]|[[:space:]]*$)' \
                || noncomment_config_matches "$config" \
                    'external-controller-tls:[[:space:]]*127\.0\.0\.1:9090|RULE-SET,[[:space:]]*whitelist|^[[:space:]]*whitelist:[[:space:]]*$|/etc/5gpn/cert/(zash|web)/' \
                || noncomment_config_matches "$config" \
                    '^[[:space:]]*external-ui:[[:space:]]*/opt/5gpn/ui[[:space:]]*$'; }; then
            legacy_found "$config contains a retired overlay, interception inbound, or panel shape"
        fi
        if [[ -n "$legacy_base" && -f "$config" && ! -L "$config" ]] \
           && { noncomment_config_contains "$config" "zash.${legacy_base}" \
                || noncomment_config_contains "$config" "profile.${legacy_base}"; }; then
            legacy_found "$config contains a retired 5gpn panel hostname for ${legacy_base}"
        fi
        for path in "${FIVEGPN_STATE_DIR}/dns.json" "${FIVEGPN_STATE_DIR}/intercept.json" \
                    "${FIVEGPN_STATE_DIR}/bot.json"; do
            [[ ! -e "$path" && ! -L "$path" ]] && continue
            [[ -f "$path" && ! -L "$path" && "$(file_nlink "$path")" == 1 ]] \
                || legacy_found "$path is not a safe current runtime document path"
        done
    fi

    if [[ "$state_inspectable" == 1 && -f "$IDENTITY_RECONCILE_FILE" \
       && ! -L "$IDENTITY_RECONCILE_FILE" ]] \
       && { ! grep -Fxq "version=${IDENTITY_RECONCILE_VERSION}" "$IDENTITY_RECONCILE_FILE" 2>/dev/null \
            || grep -Eq '^legacy_(cleanup|mihomo)=' "$IDENTITY_RECONCILE_FILE" 2>/dev/null; }; then
        legacy_found "$IDENTITY_RECONCILE_FILE does not use the current reconciliation schema"
    fi

    unset -f legacy_found
    if [[ "$found" == 1 ]]; then
        err "This installer supports only a fresh host or a current monolith installation."
        err "Back up the old deployment and remove it completely, or provision a clean host, before installing this release."
        err "No legacy service, account, state, certificate role, or configuration was changed."
        return 1
    fi
}

# Extension source is untrusted input. Each validation and action therefore
# executes in a short-lived worker whose memory is capped in its own cgroup-v2
# subtree. There is deliberately no in-process fallback: a host that cannot
# provide the isolation boundary is not a supported installation target.
kernel_release_supports_extension_workers() {
    local release="$1" major minor
    [[ "$release" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    (( 10#$major > MIN_EXTENSION_WORKER_KERNEL_MAJOR \
       || (10#$major == MIN_EXTENSION_WORKER_KERNEL_MAJOR \
           && 10#$minor >= MIN_EXTENSION_WORKER_KERNEL_MINOR) ))
}

systemd_version_supports_extension_workers() {
    local version="$1" major
    [[ "$version" =~ ^([0-9]+) ]] || return 1
    major="${BASH_REMATCH[1]}"
    (( 10#$major >= MIN_EXTENSION_WORKER_SYSTEMD_VERSION ))
}

current_systemd_manager_version() {
    local version
    command -v systemctl >/dev/null 2>&1 || return 1
    version="$(systemctl show --property=Version --value 2>/dev/null || true)"
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

host_uses_pure_cgroup_v2() {
    local line left right fstype mountpoint
    local v2_root_count=0 v1_count=0
    [[ -r /proc/self/mountinfo && -r /sys/fs/cgroup/cgroup.controllers ]] \
        || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *' - '* ]] || continue
        left="${line%% - *}"
        right="${line#* - }"
        fstype="${right%% *}"
        read -r _ _ _ _ mountpoint _ <<< "$left"
        if [[ "$fstype" == cgroup2 && "$mountpoint" == /sys/fs/cgroup ]]; then
            v2_root_count=$((v2_root_count + 1))
        elif [[ "$fstype" == cgroup ]]; then
            v1_count=$((v1_count + 1))
        fi
    done < /proc/self/mountinfo
    (( v2_root_count == 1 && v1_count == 0 ))
}

host_has_cgroup_v2_worker_controllers() {
    local controller have_memory=0 have_pids=0
    local -a controllers=()
    [[ -r /sys/fs/cgroup/cgroup.controllers ]] || return 1
    read -r -a controllers < /sys/fs/cgroup/cgroup.controllers || return 1
    for controller in "${controllers[@]}"; do
        case "$controller" in
            memory) have_memory=1 ;;
            pids) have_pids=1 ;;
        esac
    done
    (( have_memory == 1 && have_pids == 1 ))
}

systemd_unit_candidate_source() {
    local unit="$1" source
    for source in "${SCRIPT_DIR}/etc/systemd/${unit}" "${BASE_DIR}/etc/systemd/${unit}"; do
        if [[ -f "$source" && ! -L "$source" ]]; then
            printf '%s\n' "$source"
            return 0
        fi
    done
    return 1
}

verify_systemd_unit_candidates() {
    local unit source output line line_count=0 verify_dir candidate index
    local -a units=("${MANAGED_SYSTEMD_UNITS[@]}")
    local -a sources=() candidates=()
    command -v systemd-analyze >/dev/null 2>&1 \
        || { err "systemd-analyze is required to validate the service isolation contract."; return 1; }
    for unit in "${MANAGED_SYSTEMD_UNITS[@]}"; do
        source="$(systemd_unit_candidate_source "$unit")" \
            || { err "Could not locate the candidate systemd unit: $unit"; return 1; }
        sources+=("$source")
    done
    verify_dir="$(mktemp -d /tmp/5gpn-systemd-verify.XXXXXX)" || return 1
    output="${verify_dir}/output"
    # A fresh host does not yet have the runtime account, binary, or helper.
    # Verify byte-derived candidates with only those unavailable external
    # references replaced; every unit directive, relationship, and sandbox
    # value remains the exact candidate that install_units will publish.
    for index in "${!units[@]}"; do
        candidate="${verify_dir}/${units[$index]}"
        if ! sed -e 's|^ExecStartPre=+/opt/5gpn/scripts/configure-runtime-gate.sh wait$|ExecStartPre=+/bin/true|' \
                 -e 's|^ExecStartPre=/opt/5gpn/scripts/configure-runtime-gate.sh validate-ui$|ExecStartPre=/bin/true|' \
                 -e 's|^ExecStart=.*$|ExecStart=/bin/true|' \
                 -e 's/^User=.*$/User=root/' \
                 -e 's/^Group=.*$/Group=root/' \
                 -e 's/^SupplementaryGroups=.*$/SupplementaryGroups=root/' \
                 "${sources[$index]}" > "$candidate"; then
            rm -f -- "$output" "${candidates[@]}" "$candidate"
            rmdir -- "$verify_dir" 2>/dev/null || true
            err "Could not prepare the candidate systemd unit for verification: ${units[$index]}"
            return 1
        fi
        candidates+=("$candidate")
    done
    if ! SYSTEMD_UNIT_PATH="${verify_dir}:" \
            systemd-analyze verify "${candidates[@]}" >"$output" 2>&1; then
        err "Candidate systemd units failed systemd-analyze verify; no project file was published."
        while IFS= read -r line || [[ -n "$line" ]]; do
            err "systemd-analyze: $line"
            line_count=$((line_count + 1))
            (( line_count < 20 )) || break
        done < "$output"
        rm -f -- "$output" "${candidates[@]}"
        rmdir -- "$verify_dir" 2>/dev/null || true
        return 1
    fi
    rm -f -- "$output" "${candidates[@]}"
    rmdir -- "$verify_dir" \
        || { err "Could not remove the systemd verification staging directory: $verify_dir"; return 1; }
}

preflight_extension_worker_isolation_host() {
    local kernel_name kernel_release systemd_version
    kernel_name="$(uname -s 2>/dev/null || true)"
    kernel_release="$(uname -r 2>/dev/null || true)"
    [[ "$kernel_name" == Linux ]] \
        || { err "Extension worker isolation requires Linux; found '${kernel_name:-unknown}'."; return 1; }
    kernel_release_supports_extension_workers "$kernel_release" \
        || { err "Linux kernel ${MIN_EXTENSION_WORKER_KERNEL_MAJOR}.${MIN_EXTENSION_WORKER_KERNEL_MINOR} or newer is required for extension worker memory isolation; found '${kernel_release:-unknown}'. Upgrade and reboot before installing 5gpn."; return 1; }
    host_uses_pure_cgroup_v2 \
        || { err "A pure cgroup v2 hierarchy mounted at /sys/fs/cgroup is required; legacy or hybrid cgroups were detected. Boot the host in unified cgroup-v2 mode and remove all cgroup-v1 controller mounts."; return 1; }
    host_has_cgroup_v2_worker_controllers \
        || { err "The cgroup-v2 memory and pids controllers must both be available. Enable kernel memory and PID cgroups, remove cgroup_disable=memory and cgroup_disable=pids, then reboot before installing 5gpn."; return 1; }
    systemd_version="$(current_systemd_manager_version || true)"
    [[ -n "$systemd_version" ]] \
        || { err "A running systemd system manager is required; systemctl could not read its Version property."; return 1; }
    systemd_version_supports_extension_workers "$systemd_version" \
        || { err "systemd ${MIN_EXTENSION_WORKER_SYSTEMD_VERSION} or newer is required for delegated extension workers; found '$systemd_version'. Upgrade systemd before installing 5gpn."; return 1; }
    if systemd_unit_has_dropins 5gpn-mihomo.service; then
        err "Refusing a systemd override that can change or block the extension worker isolation contract before publication.${SYSTEMD_UNIT_CONFLICT_REASON:+ ($SYSTEMD_UNIT_CONFLICT_REASON)}"
        return 1
    fi
    verify_systemd_unit_candidates
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

# A service account may carry exactly one gid: its own. The same identity is
# inherited by the same-binary one-shot workers.
service_account_groups_are_permitted() {
    local user_groups="$1" primary_gid="$2" gid allowed
    allowed=" ${primary_gid} "
    for gid in $user_groups; do
        [[ "$allowed" == *" ${gid} "* ]] || return 1
    done
}

service_account_is_safe() {
    local user="$1" group="$2" entry uid home shell primary primary_gid user_groups uid_min gid_min
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
    gid_min="$(awk '$1 == "GID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null)"
    gid_min="${gid_min:-1000}"
    [[ "$uid" =~ ^[0-9]+$ && "$uid_min" =~ ^[0-9]+$ \
       && "$uid" -gt 0 && "$uid" -lt "$uid_min" ]] || return 1
    [[ "$group_gid" =~ ^[0-9]+$ && "$gid_min" =~ ^[0-9]+$ \
       && "$group_gid" -gt 0 && "$group_gid" -lt "$gid_min" \
       && "$primary_gid" == "$group_gid" ]] || return 1
    [[ "$home" == /nonexistent && "$primary" == "$group" ]] || return 1
    [[ -z "$members" && "$primary_users" == "$user" && "$uid_users" == "$user" \
       && "$gid_groups" == "$group" && -z "$gid_members" ]] || return 1
    # The monolith account may belong only to its own primary group.
    service_account_groups_are_permitted "$user_groups" "$group_gid" || return 1
    case "$shell" in */nologin|/bin/false) ;; *) return 1 ;; esac
}

service_account_name_is_valid() {
    [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

managed_account_process_snapshot() {
    local user="$1" uid
    getent passwd "$user" >/dev/null 2>&1 || return 0
    uid="$(id -u "$user" 2>/dev/null || true)"
    [[ "$uid" =~ ^[0-9]+$ ]] || return 1
    ps -ww -eo uid=,pid=,ppid=,stat=,comm=,args= 2>/dev/null \
        | awk -v id="$uid" '
            $1 == id {
                $1 = ""
                sub(/^[[:space:]]+/, "")
                print
            }
        '
}

wait_managed_account_quiescent() {
    local user="$1" snapshot="" elapsed=0 slice announced=0
    getent passwd "$user" >/dev/null 2>&1 || return 0
    [[ "$ACCOUNT_QUIESCE_TIMEOUT" =~ ^[1-9][0-9]*$ \
       && "$ACCOUNT_QUIESCE_INTERVAL" =~ ^[1-9][0-9]*$ ]] \
        || { err "Managed-account quiescence bounds are invalid."; return 1; }
    while true; do
        snapshot="$(managed_account_process_snapshot "$user")" \
            || { err "Could not inspect processes owned by managed account: $user"; return 1; }
        [[ -n "$snapshot" ]] || return 0
        if (( elapsed >= ACCOUNT_QUIESCE_TIMEOUT )); then
            err "Managed account ${user} still owns running processes after ${ACCOUNT_QUIESCE_TIMEOUT}s."
            printf '%s\n' 'PID PPID STAT COMMAND ARGS' "$snapshot" >&2
            return 1
        fi
        if (( announced == 0 )); then
            announced=1
            info "Waiting up to ${ACCOUNT_QUIESCE_TIMEOUT}s for ${user} processes to exit after service shutdown..."
        fi
        slice="$ACCOUNT_QUIESCE_INTERVAL"
        (( slice <= ACCOUNT_QUIESCE_TIMEOUT - elapsed )) \
            || slice=$((ACCOUNT_QUIESCE_TIMEOUT - elapsed))
        sleep "$slice"
        elapsed=$((elapsed + slice))
    done
}

managed_user_uid_is_exclusive() {
    local user="$1" entry uid uid_users
    entry="$(getent passwd "$user" 2>/dev/null)" || return 1
    uid="$(printf '%s\n' "$entry" | cut -d: -f3)"
    [[ "$uid" =~ ^[0-9]+$ && "$uid" -gt 0 ]] || return 1
    uid_users="$(getent passwd 2>/dev/null | awk -F: -v id="$uid" '$3 == id { print $1 }')" \
        || return 1
    [[ "$uid_users" == "$user" ]]
}

managed_group_gid_is_exclusive() {
    local group="$1" user="$2" entry gid members gid_groups primary_users
    entry="$(getent group "$group" 2>/dev/null)" || return 1
    gid="$(printf '%s\n' "$entry" | cut -d: -f3)"
    members="$(printf '%s\n' "$entry" | cut -d: -f4)"
    [[ "$gid" =~ ^[0-9]+$ && "$gid" -gt 0 \
       && ( -z "$members" || "$members" == "$user" ) ]] || return 1
    gid_groups="$(getent group 2>/dev/null | awk -F: -v id="$gid" '$3 == id { print $1 }')" \
        || return 1
    primary_users="$(getent passwd 2>/dev/null | awk -F: -v id="$gid" '$4 == id { print $1 }')" \
        || return 1
    [[ "$gid_groups" == "$group" \
       && ( -z "$primary_users" || "$primary_users" == "$user" ) ]]
}

managed_primary_gid_is_exclusive_for_user() {
    local user="$1" gid group_entries passwd_entries gid_groups gid_members primary_users
    getent passwd "$user" >/dev/null 2>&1 || return 1
    gid="$(id -g "$user" 2>/dev/null)" || return 1
    [[ "$gid" =~ ^[0-9]+$ && "$gid" -gt 0 ]] || return 1
    group_entries="$(getent group 2>/dev/null)" || return 1
    gid_groups="$(printf '%s\n' "$group_entries" | awk -F: -v id="$gid" '$3 == id { print $1 }')"
    gid_members="$(printf '%s\n' "$group_entries" | awk -F: -v id="$gid" '$3 == id && $4 != "" { print $4 }')"
    passwd_entries="$(getent passwd 2>/dev/null)" || return 1
    primary_users="$(printf '%s\n' "$passwd_entries" | awk -F: -v id="$gid" '$4 == id { print $1 }')"
    [[ ( -z "$gid_groups" || "$gid_groups" == "$FIVEGPN_SERVICE_GROUP" ) \
       && "$primary_users" == "$user" \
       && ( -z "$gid_members" || "$gid_members" == "$user" ) ]]
}

identity_id_is_in_system_range() {
    local kind="$1" id="$2" key minimum
    [[ "$id" =~ ^[0-9]+$ && "$id" -gt 0 ]] || return 1
    case "$kind" in
        uid) key=UID_MIN ;;
        gid) key=GID_MIN ;;
        *) return 1 ;;
    esac
    minimum="$(awk -v wanted="$key" '$1 == wanted { print $2; exit }' /etc/login.defs 2>/dev/null)"
    minimum="${minimum:-1000}"
    [[ "$minimum" =~ ^[1-9][0-9]*$ && "$id" -lt "$minimum" ]]
}

current_root_marker_proves_deployment() {
    local dir marker value canonical uid gid mode
    while IFS='|' read -r dir marker value; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        canonical="$(canonical_dir_path "$dir" 2>/dev/null || true)"
        [[ "$canonical" == "$dir" ]] || continue
        root_ownership_marker_is_safe "$dir" "$marker" "$value" || continue
        uid="$(file_uid "$dir")"
        gid="$(file_gid "$dir")"
        mode="$(file_mode "$dir")"
        case "$dir" in
            "$BASE_DIR"|"$STATE_DIR")
                [[ "$uid" == 0 && "$gid" == 0 && "$mode" == 755 ]] && return 0 ;;
            "$CONF_DIR")
                [[ "$uid" == 0 \
                   && ( ( "$gid" == 0 && "$mode" == 755 ) || "$mode" == 3771 ) ]] \
                    && return 0 ;;
            "$INTERCEPT_CA_DIR")
                [[ "$uid" == 0 && "$gid" == 0 \
                   && ( "$mode" == 700 || "$mode" == 755 ) ]] && return 0 ;;
            "$INTERCEPT_STATE_DIR")
                [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$mode" == 700 ]] \
                    && return 0 ;;
        esac
    done <<EOF
$BASE_DIR|$BASE_OWNERSHIP_MARKER|$BASE_OWNERSHIP_VALUE
$CONF_DIR|$CONF_OWNERSHIP_MARKER|$CONF_OWNERSHIP_VALUE
$STATE_DIR|$STATE_OWNERSHIP_MARKER|$STATE_OWNERSHIP_VALUE
$INTERCEPT_CA_DIR|$INTERCEPT_CA_MARKER|$INTERCEPT_CA_MARKER_VALUE
$INTERCEPT_STATE_DIR|$INTERCEPT_STATE_MARKER|$INTERCEPT_STATE_MARKER_VALUE
EOF
    return 1
}

current_deployment_proves_identity_repair() {
    current_root_marker_proves_deployment \
        || current_managed_unit_file_is_safe 5gpn-mihomo.service
}

journaled_identity_recovery_is_safe() {
    local gid name
    load_identity_reconcile_journal || return 1
    current_deployment_proves_identity_repair || return 1
    identity_reconcile_journal_file_is_safe || return 1
    [[ -n "$REPLACED_FIVEGPN_GID" ]] \
        && identity_id_is_in_system_range gid "$REPLACED_FIVEGPN_GID" \
        || return 1
    if [[ -n "$REPLACED_FIVEGPN_UID" ]]; then
        identity_id_is_in_system_range uid "$REPLACED_FIVEGPN_UID" || return 1
        [[ -z "$(getent passwd "$REPLACED_FIVEGPN_UID" 2>/dev/null || true)" ]] \
            || return 1
    else
        [[ -n "$REPLACED_FIVEGPN_NAMED_GID" \
           && "$REPLACED_FIVEGPN_GID" == "$REPLACED_FIVEGPN_NAMED_GID" ]] \
            || return 1
    fi
    [[ -z "$REPLACED_FIVEGPN_NAMED_GID" ]] \
        || identity_id_is_in_system_range gid "$REPLACED_FIVEGPN_NAMED_GID" \
        || return 1
    for gid in "$REPLACED_FIVEGPN_GID" "$REPLACED_FIVEGPN_NAMED_GID"; do
        [[ -n "$gid" ]] || continue
        name="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"
        [[ -z "$name" || "$name" == "$FIVEGPN_SERVICE_GROUP" ]] || return 1
        if [[ "$name" == "$FIVEGPN_SERVICE_GROUP" ]]; then
            managed_group_gid_is_exclusive "$FIVEGPN_SERVICE_GROUP" "$FIVEGPN_SERVICE_USER" \
                || return 1
        fi
        [[ "$REPLACED_FIVEGPN_GID" != "$REPLACED_FIVEGPN_NAMED_GID" ]] || break
    done
}

current_fivegpn_identity_matches_pending_journal() {
    local uid="" gid="" named_gid=""
    [[ -n "$REPLACED_FIVEGPN_UID" || -n "$REPLACED_FIVEGPN_GID" \
       || -n "$REPLACED_FIVEGPN_NAMED_GID" ]] || return 0
    if getent passwd "$FIVEGPN_SERVICE_USER" >/dev/null 2>&1; then
        uid="$(id -u "$FIVEGPN_SERVICE_USER")"
        gid="$(id -g "$FIVEGPN_SERVICE_USER")"
    fi
    if getent group "$FIVEGPN_SERVICE_GROUP" >/dev/null 2>&1; then
        named_gid="$(account_gid "$FIVEGPN_SERVICE_GROUP")"
    fi
    # REPLACED_FIVEGPN_GID is an old ownership value to sweep, not always the
    # primary GID of the recreated account. A previously malformed user could
    # have had a different primary and named-group GID. The recreated identity
    # reuses the recorded UID and named group when those existed.
    [[ -z "$REPLACED_FIVEGPN_UID" || "$uid" == "$REPLACED_FIVEGPN_UID" ]] \
        && [[ -z "$REPLACED_FIVEGPN_NAMED_GID" \
           || ( "$gid" == "$REPLACED_FIVEGPN_NAMED_GID" \
                && "$named_gid" == "$REPLACED_FIVEGPN_NAMED_GID" ) ]]
}

remove_managed_account_identity() {
    local user="$1" group="$2"
    if getent passwd "$user" >/dev/null 2>&1; then
        wait_managed_account_quiescent "$user" || return 1
        userdel "$user" \
            || { err "Could not remove the managed account: $user"; return 1; }
    fi
    if getent group "$group" >/dev/null 2>&1; then
        groupdel "$group" \
            || { err "Could not remove the managed group: $group"; return 1; }
    fi
}

stop_managed_runtime_units() {
    local unit
    for unit in 5gpn-intercept-cert.path \
                5gpn-intercept-cert.timer 5gpn-certbot-renew.timer \
                5gpn-mihomo.service; do
        read_exact_systemd_unit_state "$unit" \
            || { err "Could not read managed unit state before identity reconciliation: $unit"; return 1; }
        [[ "$SYSTEMD_UNIT_LOAD_STATE" == not-found ]] && continue
        case "$SYSTEMD_UNIT_FILE_STATE" in
            enabled-runtime)
                systemctl disable --runtime --now "$unit" >/dev/null 2>&1 \
                    || { err "Could not disable runtime-enabled managed unit: $unit"; return 1; }
                ;;
            enabled|disabled)
                systemctl disable --now "$unit" >/dev/null 2>&1 \
                    || { err "Could not disable managed unit before identity reconciliation: $unit"; return 1; }
                read_exact_systemd_unit_state "$unit" \
                    || { err "Could not re-read managed unit after persistent disable: $unit"; return 1; }
                if [[ "$SYSTEMD_UNIT_FILE_STATE" == enabled-runtime ]]; then
                    systemctl disable --runtime --now "$unit" >/dev/null 2>&1 \
                        || { err "Could not clear the remaining runtime enablement: $unit"; return 1; }
                fi
                ;;
            *)
                err "Managed unit has unsupported enablement state before identity reconciliation: $unit (${SYSTEMD_UNIT_FILE_STATE})."
                return 1
                ;;
        esac
        read_exact_systemd_unit_state "$unit" \
            || { err "Could not verify managed unit after disable: $unit"; return 1; }
        [[ "$SYSTEMD_UNIT_LOAD_STATE" == loaded \
           && "$SYSTEMD_UNIT_ACTIVE_STATE" == inactive \
           && "$SYSTEMD_UNIT_FILE_STATE" == disabled ]] \
            || { err "Managed unit did not enter loaded/inactive/disabled state: $unit"; return 1; }
    done
    for unit in 5gpn-intercept-cert.service 5gpn-certbot-renew.service; do
        read_exact_systemd_unit_state "$unit" \
            || { err "Could not read managed certificate publisher state: $unit"; return 1; }
        [[ "$SYSTEMD_UNIT_LOAD_STATE" == not-found ]] && continue
        systemctl stop "$unit" >/dev/null 2>&1 \
            || { err "Could not stop managed certificate publisher: $unit"; return 1; }
        read_exact_systemd_unit_state "$unit" \
            || { err "Could not verify managed certificate publisher after stop: $unit"; return 1; }
        [[ "$SYSTEMD_UNIT_LOAD_STATE" == loaded \
           && "$SYSTEMD_UNIT_ACTIVE_STATE" == inactive ]] \
            || { err "Managed certificate publisher remained active: $unit"; return 1; }
    done
}

assert_managed_accounts_quiescent() {
    wait_managed_account_quiescent "$FIVEGPN_SERVICE_USER"
}

assert_dns_publication_quiescent() {
    local active_state
    active_state="$(systemctl show -p ActiveState --value 5gpn-mihomo.service 2>/dev/null)" \
        || { err "Could not verify 5gpn-mihomo quiescence before DNS publication."; return 1; }
    [[ "$active_state" == inactive ]] \
        || { err "5gpn-mihomo must be inactive before DNS publication; found ${active_state:-empty}."; return 1; }
    assert_managed_accounts_quiescent \
        || { err "A fivegpn process is still running before DNS publication."; return 1; }
}

preload_fivegpn_identity_for_claim() {
    local user_exists=0 group_exists=0 candidate_uid="" candidate_gid="" candidate_named_gid="" user_groups=""
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=0
    if getent passwd "$FIVEGPN_SERVICE_USER" >/dev/null 2>&1; then user_exists=1; fi
    if getent group "$FIVEGPN_SERVICE_GROUP" >/dev/null 2>&1; then group_exists=1; fi
    if [[ "$user_exists" == 0 && "$group_exists" == 0 ]]; then
        if [[ -n "$REPLACED_FIVEGPN_UID" || -n "$REPLACED_FIVEGPN_GID" \
           || -n "$REPLACED_FIVEGPN_NAMED_GID" ]]; then
            journaled_identity_recovery_is_safe \
                || { err "The pending fivegpn identity journal is unsafe or its numeric identity was reused."; return 1; }
            FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
        fi
        return 0
    fi
    current_deployment_proves_identity_repair \
        || { err "Refusing a same-name fivegpn identity without a safe current root or current 5gpn-mihomo unit marker."; return 1; }
    if service_account_is_safe "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" \
       && service_group_is_exclusive_for_user "$FIVEGPN_SERVICE_GROUP" "$FIVEGPN_SERVICE_USER"; then
        current_fivegpn_identity_matches_pending_journal \
            || { err "The current fivegpn identity conflicts with the pending reconciliation journal."; return 1; }
        return 0
    fi
    if [[ "$user_exists" == 1 ]]; then
        managed_user_uid_is_exclusive "$FIVEGPN_SERVICE_USER" \
            || { err "Managed fivegpn UID is aliased; refusing reconciliation preflight."; return 1; }
        managed_primary_gid_is_exclusive_for_user "$FIVEGPN_SERVICE_USER" \
            || { err "Managed fivegpn primary GID is shared or aliased; refusing reconciliation preflight."; return 1; }
        candidate_uid="$(id -u "$FIVEGPN_SERVICE_USER")"
        candidate_gid="$(id -g "$FIVEGPN_SERVICE_USER")"
        user_groups="$(id -G "$FIVEGPN_SERVICE_USER" 2>/dev/null)" \
            || { err "Could not inspect fivegpn supplementary groups during reconciliation preflight."; return 1; }
        service_account_groups_are_permitted "$user_groups" "$candidate_gid" \
            || { err "Managed fivegpn belongs to a supplementary group; refusing identity repair."; return 1; }
        identity_id_is_in_system_range uid "$candidate_uid" \
            && identity_id_is_in_system_range gid "$candidate_gid" \
            || { err "Managed fivegpn UID/GID is outside the system-account range; refusing reconciliation preflight."; return 1; }
    fi
    if [[ "$group_exists" == 1 ]]; then
        managed_group_gid_is_exclusive "$FIVEGPN_SERVICE_GROUP" "$FIVEGPN_SERVICE_USER" \
            || { err "Managed fivegpn GID is aliased or shared; refusing reconciliation preflight."; return 1; }
        candidate_named_gid="$(account_gid "$FIVEGPN_SERVICE_GROUP")"
        identity_id_is_in_system_range gid "$candidate_named_gid" \
            || { err "Managed fivegpn named-group GID is outside the system-account range; refusing reconciliation preflight."; return 1; }
        [[ -n "$candidate_gid" ]] || candidate_gid="$candidate_named_gid"
    fi
    if [[ -n "$REPLACED_FIVEGPN_UID" && -n "$candidate_uid" \
       && "$REPLACED_FIVEGPN_UID" != "$candidate_uid" ]]; then
        err "Current fivegpn UID conflicts with the durable reconciliation journal."
        return 1
    fi
    if [[ "$user_exists" == 1 \
       && -n "$REPLACED_FIVEGPN_GID" && -n "$candidate_gid" \
       && "$REPLACED_FIVEGPN_GID" != "$candidate_gid" ]]; then
        err "Current fivegpn primary GID conflicts with the durable reconciliation journal."
        return 1
    fi
    if [[ -n "$REPLACED_FIVEGPN_NAMED_GID" && -n "$candidate_named_gid" \
       && "$REPLACED_FIVEGPN_NAMED_GID" != "$candidate_named_gid" ]]; then
        err "Current fivegpn named-group GID conflicts with the durable reconciliation journal."
        return 1
    fi
    [[ -n "$candidate_uid" ]] && REPLACED_FIVEGPN_UID="$candidate_uid"
    [[ -n "$candidate_gid" ]] && REPLACED_FIVEGPN_GID="$candidate_gid"
    [[ -n "$candidate_named_gid" ]] && REPLACED_FIVEGPN_NAMED_GID="$candidate_named_gid"
    FIVEGPN_IDENTITY_REPAIR_AUTHORIZED=1
}

ensure_service_account() {
    local user="$1" group="$2" user_created_name="${3:-}" group_created_name="${4:-}"
    local uid_created_name="${5:-}" gid_created_name="${6:-}"
    local nologin group_created=0 user_created=0 user_preexists=0 account_uid="" account_gid=""
    local reuse_uid="" reuse_gid="" user_exists=0 group_exists=0 uid_min gid_min
    local candidate_uid="" candidate_gid="" candidate_named_gid="" user_groups=""
    local journal_candidate_gid=""
    [[ -z "$user_created_name" ]] || printf -v "$user_created_name" '%s' 0
    [[ -z "$group_created_name" ]] || printf -v "$group_created_name" '%s' 0
    [[ -z "$uid_created_name" ]] || printf -v "$uid_created_name" '%s' ''
    [[ -z "$gid_created_name" ]] || printf -v "$gid_created_name" '%s' ''
    service_account_name_is_valid "$user" && service_account_name_is_valid "$group" \
        || { err "Invalid strict service account name: $user/$group"; return 1; }

    if getent passwd "$user" >/dev/null 2>&1; then user_exists=1; fi
    if getent group "$group" >/dev/null 2>&1; then group_exists=1; fi
    if [[ "$user_exists" == 0 && "$group_exists" == 0 \
       && "$FIVEGPN_IDENTITY_REPAIR_AUTHORIZED" == 1 \
       && ( -n "$REPLACED_FIVEGPN_UID" || -n "$REPLACED_FIVEGPN_GID" \
            || -n "$REPLACED_FIVEGPN_NAMED_GID" ) ]]; then
        [[ "$INSTALL_PUBLICATION_STARTED" == 1 ]] \
            || { err "Refusing to resume fivegpn identity repair before publication starts."; return 1; }
        persist_replaced_fivegpn_identity "$REPLACED_FIVEGPN_UID" \
            "$REPLACED_FIVEGPN_GID" "$REPLACED_FIVEGPN_NAMED_GID" || return 1
    fi
    if [[ "$user_exists" == 1 || "$group_exists" == 1 ]]; then
        if service_account_is_safe "$user" "$group" \
           && service_group_is_exclusive_for_user "$group" "$user"; then
            account_uid="$(id -u "$user")"
            account_gid="$(id -g "$user")"
            current_fivegpn_identity_matches_pending_journal \
                || { err "The current fivegpn identity conflicts with the pending reconciliation journal."; return 1; }
            [[ -z "$uid_created_name" ]] || printf -v "$uid_created_name" '%s' "$account_uid"
            [[ -z "$gid_created_name" ]] || printf -v "$gid_created_name" '%s' "$account_gid"
            return 0
        fi
        if [[ "$user" != "$FIVEGPN_SERVICE_USER" || "$group" != "$FIVEGPN_SERVICE_GROUP" ]]; then
            err "Refusing incompatible pre-existing service account: $user"
            return 1
        fi
        [[ "$FIVEGPN_IDENTITY_REPAIR_AUTHORIZED" == 1 ]] \
            || { err "Refusing incompatible fivegpn identity without pre-publication repair authorization."; return 1; }
        if [[ "$user_exists" == 1 ]]; then
            managed_user_uid_is_exclusive "$user" \
                || { err "Managed account ${user} has an aliased UID; refusing destructive reconciliation."; return 1; }
            managed_primary_gid_is_exclusive_for_user "$user" \
                || { err "Managed account ${user} has a shared or aliased primary GID; refusing destructive reconciliation."; return 1; }
            candidate_uid="$(id -u "$user")"
            candidate_gid="$(id -g "$user")"
            user_groups="$(id -G "$user" 2>/dev/null)" \
                || { err "Could not inspect managed supplementary groups before reconciliation."; return 1; }
            service_account_groups_are_permitted "$user_groups" "$candidate_gid" \
                || { err "Managed account ${user} belongs to a supplementary group; refusing destructive reconciliation."; return 1; }
            identity_id_is_in_system_range uid "$candidate_uid" \
                && identity_id_is_in_system_range gid "$candidate_gid" \
                || { err "Managed account ${user} is outside the system UID/GID range; refusing destructive reconciliation."; return 1; }
            uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null)"
            uid_min="${uid_min:-1000}"
            [[ "$candidate_uid" -lt "$uid_min" ]] && reuse_uid="$candidate_uid"
        fi
        if [[ "$group_exists" == 1 ]]; then
            local named_group_gid
            managed_group_gid_is_exclusive "$group" "$user" \
                || { err "Managed group ${group} has an aliased GID or unknown members; refusing destructive reconciliation."; return 1; }
            named_group_gid="$(account_gid "$group")"
            candidate_named_gid="$named_group_gid"
            identity_id_is_in_system_range gid "$named_group_gid" \
                || { err "Managed group ${group} is outside the system GID range; refusing destructive reconciliation."; return 1; }
            [[ -n "$candidate_gid" ]] || candidate_gid="$named_group_gid"
            gid_min="$(awk '$1 == "GID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null)"
            gid_min="${gid_min:-1000}"
            [[ "$named_group_gid" -lt "$gid_min" ]] && reuse_gid="$named_group_gid"
        fi
        [[ "$INSTALL_PUBLICATION_STARTED" == 1 ]] \
            || { err "Refusing destructive fivegpn identity reconciliation before publication starts."; return 1; }
        journal_candidate_gid="$candidate_gid"
        if [[ "$user_exists" == 0 && -n "$REPLACED_FIVEGPN_GID" ]]; then
            journal_candidate_gid=""
        fi
        persist_replaced_fivegpn_identity "$candidate_uid" "$journal_candidate_gid" \
            "$candidate_named_gid" || return 1
        warn "Recreating the installer-managed ${user} account because its identity or permissions are incompatible."
        remove_managed_account_identity "$user" "$group" || return 1
    fi

    if [[ -z "$reuse_uid" && -n "$REPLACED_FIVEGPN_UID" ]]; then
        uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null)"
        uid_min="${uid_min:-1000}"
        if [[ "$REPLACED_FIVEGPN_UID" -lt "$uid_min" ]] \
           && ! getent passwd "$REPLACED_FIVEGPN_UID" >/dev/null 2>&1; then
            reuse_uid="$REPLACED_FIVEGPN_UID"
        fi
    fi
    if [[ -z "$reuse_gid" && -n "$REPLACED_FIVEGPN_NAMED_GID" ]]; then
        gid_min="$(awk '$1 == "GID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null)"
        gid_min="${gid_min:-1000}"
        if [[ "$REPLACED_FIVEGPN_NAMED_GID" -lt "$gid_min" ]] \
           && ! getent group "$REPLACED_FIVEGPN_NAMED_GID" >/dev/null 2>&1; then
            reuse_gid="$REPLACED_FIVEGPN_NAMED_GID"
        fi
    fi

    if getent passwd "$user" >/dev/null 2>&1; then
        user_preexists=1
    fi
    if getent group "$group" >/dev/null 2>&1; then
        service_group_is_exclusive_for_user "$group" "$user" \
            || { err "Refusing shared service group: $group"; return 1; }
    else
        [[ "$user_preexists" == 0 ]] \
            || { err "Refusing a pre-existing service account without its named primary group: $user/$group"; return 1; }
        if [[ -n "$reuse_gid" ]]; then
            groupadd --system --gid "$reuse_gid" "$group" || return 1
        else
            groupadd --system "$group" || return 1
        fi
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
        local -a useradd_args=(--system --gid "$group" --home-dir /nonexistent \
            --shell "$nologin" --no-create-home)
        [[ -z "$reuse_uid" ]] || useradd_args+=(--uid "$reuse_uid")
        if ! useradd "${useradd_args[@]}" "$user"; then
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
            # The pre-existing-account branch above says why it refuses; this one
            # did not, so an account the installer created and then rejected
            # aborted the run with no reason given at all. The usual cause is a
            # host whose UID_MIN leaves useradd --system no system uid to
            # allocate, which is worth naming rather than leaving to be guessed.
            err "Created service account $user does not satisfy the isolation rules; removed it again."
            err "Check that /etc/login.defs leaves a free system uid below UID_MIN for --system accounts."
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
    return "$result"
}

install_service_accounts() {
    command -v getent >/dev/null 2>&1 \
        && command -v ps >/dev/null 2>&1 \
        && command -v findmnt >/dev/null 2>&1 \
        && command -v groupadd >/dev/null 2>&1 \
        && command -v useradd >/dev/null 2>&1 \
        && command -v groupdel >/dev/null 2>&1 \
        && command -v userdel >/dev/null 2>&1 \
        || { err "getent, ps, findmnt, and service account management tools are required for runtime isolation."; return 1; }
    preflight_unit_ownership || return 1
    stop_managed_runtime_units || return 1
    assert_managed_accounts_quiescent || return 1
    install_service_account "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" || return 1
    ok "The single 5gpn runtime account is ready: ${FIVEGPN_SERVICE_USER}."
}

managed_path_has_no_nested_mounts() {
    local root="$1" target output
    command -v findmnt >/dev/null 2>&1 \
        || { err "findmnt is required for managed identity reconciliation."; return 1; }
    [[ -d "$root" && ! -L "$root" ]] || return 0
    output="$(findmnt -R -r -n -o TARGET --target "$root" 2>/dev/null)" \
        || { err "Could not inspect mounts below managed root: $root"; return 1; }
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case "$target" in
            "$root"/*)
                err "Refusing identity reconciliation across nested mount: $target"
                return 1 ;;
        esac
    done <<< "$output"
}

managed_roots_have_no_nested_mounts() {
    local root
    for root in "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR" "$INTERCEPT_CA_DIR"; do
        managed_path_has_no_nested_mounts "$root" || return 1
    done
}

remove_decommissioned_fivegpn_identity() {
    local uid="" primary_gid="" named_gid="" root residual id_value
    if getent passwd "$FIVEGPN_SERVICE_USER" >/dev/null 2>&1; then
        managed_user_uid_is_exclusive "$FIVEGPN_SERVICE_USER" \
            || { err "Refusing to remove an aliased fivegpn UID during decommission."; return 1; }
        wait_managed_account_quiescent "$FIVEGPN_SERVICE_USER" || return 1
        uid="$(id -u "$FIVEGPN_SERVICE_USER")"
        primary_gid="$(id -g "$FIVEGPN_SERVICE_USER")"
    fi
    if getent group "$FIVEGPN_SERVICE_GROUP" >/dev/null 2>&1; then
        managed_group_gid_is_exclusive "$FIVEGPN_SERVICE_GROUP" "$FIVEGPN_SERVICE_USER" \
            || { err "Refusing to remove a shared fivegpn group during decommission."; return 1; }
        named_gid="$(account_gid "$FIVEGPN_SERVICE_GROUP")"
    fi
    managed_roots_have_no_nested_mounts || return 1
    if [[ -n "$uid" ]]; then
        residual=""
        for root in "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR" "$INTERCEPT_CA_DIR"; do
            [[ -d "$root" && ! -L "$root" ]] || continue
            residual="$(find "$root" -mindepth 1 -uid "$uid" -print -quit 2>/dev/null)" \
                || return 1
            [[ -z "$residual" ]] || break
        done
        [[ -z "$residual" ]] \
            || { err "fivegpn identity still owns preserved managed state: $residual"; return 1; }
    fi
    for id_value in "$primary_gid" "$named_gid"; do
        [[ -n "$id_value" ]] || continue
        residual=""
        for root in "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR" "$INTERCEPT_CA_DIR"; do
            [[ -d "$root" && ! -L "$root" ]] || continue
            residual="$(find "$root" -mindepth 1 -gid "$id_value" -print -quit 2>/dev/null)" \
                || return 1
            [[ -z "$residual" ]] || break
        done
        [[ -z "$residual" ]] \
            || { err "fivegpn group still owns preserved managed state: $residual"; return 1; }
        [[ "$primary_gid" != "$named_gid" ]] || break
    done
    remove_managed_account_identity "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP"
}

state_directory_metadata_is_reconcilable() {
    local path="$1" uid gid mode
    [[ -d "$path" && ! -L "$path" ]] || return 1
    uid="$(file_uid "$path")"
    gid="$(file_gid "$path")"
    mode="$(file_mode "$path")"
    # A fresh state directory created beneath the current setgid mihomo home
    # may inherit that bit before the explicit post-create chmod runs. Treat
    # only the otherwise exact service-owned 2711 shape as interrupted
    # current-state reconciliation. Root-owned state is accepted only in its
    # ordinary sealed modes; the publication pass normalizes service-owned
    # state to 0711 before publishing documents.
    case "$mode" in
        700|711)
            [[ "$uid" == 0 && "$gid" == 0 ]] && return 0
            ;;
        2711) ;;
        *) return 1 ;;
    esac
    uid_gid_match_named_account "$uid" "$gid" \
        "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" && return 0
    [[ -n "$REPLACED_FIVEGPN_UID" && "$uid" == "$REPLACED_FIVEGPN_UID" ]] \
        && gid_matches_replaced_fivegpn_identity "$gid"
}

mihomo_home_metadata_is_reconcilable() {
    local uid gid mode
    [[ -d "$MIHOMO_DIR" && ! -L "$MIHOMO_DIR" ]] || return 1
    uid="$(file_uid "$MIHOMO_DIR")"
    gid="$(file_gid "$MIHOMO_DIR")"
    mode="$(file_mode "$MIHOMO_DIR")"
    [[ "$uid" == 0 ]] || return 1
    [[ "$gid" == 0 && ( "$mode" == 700 || "$mode" == 755 ) ]] && return 0
    [[ "$mode" == 3770 ]] || return 1
    gid_matches_named_group "$gid" "$FIVEGPN_SERVICE_GROUP" \
        || gid_matches_replaced_fivegpn_identity "$gid"
}

seal_mihomo_home_for_state_reconciliation() {
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$MIHOMO_DIR" "$CONF_DIR" \
        && mihomo_home_metadata_is_reconcilable \
        || { err "Mihomo home ownership or mode is unsafe for state reconciliation."; return 1; }
    chown root:root "$MIHOMO_DIR" && chmod 00700 "$MIHOMO_DIR" \
        || { err "Could not seal the mihomo home for state reconciliation."; return 1; }
    [[ "$(file_uid "$MIHOMO_DIR")" == 0 \
       && "$(file_gid "$MIHOMO_DIR")" == 0 \
       && "$(file_mode "$MIHOMO_DIR")" == 700 ]]
}

restore_mihomo_home_after_state_reconciliation() {
    chown "root:$FIVEGPN_SERVICE_GROUP" "$MIHOMO_DIR" && chmod 3770 "$MIHOMO_DIR" \
        || { err "Could not restore the mihomo home runtime boundary."; return 1; }
    shared_runtime_directory_metadata_is_safe "$MIHOMO_DIR" "$FIVEGPN_SERVICE_GROUP" 3770
}

seal_state_directory_for_reconciliation() {
    local path="$1"
    state_directory_metadata_is_reconcilable "$path" \
        || { err "State directory ownership or mode is unsafe: $path"; return 1; }
    managed_path_has_no_nested_mounts "$path" || return 1
    chown root:root "$path" && chmod 00700 "$path" \
        || { err "Could not seal state directory for reconciliation: $path"; return 1; }
    runtime_tree_has_only_plain_entries "$path" \
        || { err "State directory contains a link, hardlink, or special entry: $path"; return 1; }
}

normalize_fivegpn_state_tree_permissions() {
    local state="$1" request="${1}/certificate-request"
    runtime_tree_has_only_plain_entries "$state" || return 1
    find "$state" -mindepth 1 -type d -exec chmod 00700 {} + || return 1
    find "$state" -mindepth 1 -type f -exec chmod 00600 {} + || return 1
    if [[ -e "$request" || -L "$request" ]]; then
        [[ -f "$request" && ! -L "$request" && "$(file_nlink "$request")" == 1 ]] \
            || { err "Certificate request state file is unsafe."; return 1; }
        chmod 00644 "$request" || return 1
    fi
    chmod 00711 "$state"
}

reconcile_fivegpn_state_directory() {
    local state="$FIVEGPN_STATE_DIR"
    [[ -e "$state" || -L "$state" ]] || return 0
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_directory_slot_is_safe "$MIHOMO_DIR" "$CONF_DIR" \
        || { err "Unsafe mihomo home during 5gpn state reconciliation: $MIHOMO_DIR"; return 1; }
    seal_mihomo_home_for_state_reconciliation || return 1
    seal_state_directory_for_reconciliation "$state" || return 1
    chown -R "$FIVEGPN_SERVICE_USER:$FIVEGPN_SERVICE_GROUP" "$state" || return 1
    normalize_fivegpn_state_tree_permissions "$state" || return 1
    restore_mihomo_home_after_state_reconciliation || return 1
    sync -f "$MIHOMO_DIR" 2>/dev/null || true
}

preflight_fivegpn_state_directory() {
    if [[ -e "$FIVEGPN_STATE_DIR" || -L "$FIVEGPN_STATE_DIR" ]]; then
        mihomo_home_metadata_is_reconcilable \
            || { err "Refusing unsafe mihomo home before state reconciliation."; return 1; }
        state_directory_metadata_is_reconcilable "$FIVEGPN_STATE_DIR" \
            && runtime_tree_has_only_plain_entries "$FIVEGPN_STATE_DIR" \
            || { err "Refusing unsafe current 5gpn state path before publication: $FIVEGPN_STATE_DIR"; return 1; }
    fi
}

assert_replaced_fivegpn_identity_reconciled() {
    local current_uid current_gid root residual
    [[ -n "$REPLACED_FIVEGPN_UID" || -n "$REPLACED_FIVEGPN_GID" \
       || -n "$REPLACED_FIVEGPN_NAMED_GID" ]] || return 0
    current_uid="$(id -u "$FIVEGPN_SERVICE_USER")"
    current_gid="$(id -g "$FIVEGPN_SERVICE_USER")"
    managed_roots_have_no_nested_mounts || return 1
    for root in "$BASE_DIR" "$CONF_DIR" "$STATE_DIR" "$INTERCEPT_STATE_DIR" "$INTERCEPT_CA_DIR"; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        residual=""
        if [[ -n "$REPLACED_FIVEGPN_UID" && "$REPLACED_FIVEGPN_UID" != "$current_uid" ]]; then
            if ! residual="$(find "$root" -uid "$REPLACED_FIVEGPN_UID" -print -quit 2>/dev/null)"; then
                err "Could not scan managed roots for the replaced fivegpn UID."
                return 1
            fi
        fi
        if [[ -z "$residual" && -n "$REPLACED_FIVEGPN_GID" \
           && "$REPLACED_FIVEGPN_GID" != "$current_gid" ]]; then
            if ! residual="$(find "$root" -gid "$REPLACED_FIVEGPN_GID" -print -quit 2>/dev/null)"; then
                err "Could not scan managed roots for the replaced fivegpn GID."
                return 1
            fi
        fi
        if [[ -z "$residual" && -n "$REPLACED_FIVEGPN_NAMED_GID" \
           && "$REPLACED_FIVEGPN_NAMED_GID" != "$current_gid" \
           && "$REPLACED_FIVEGPN_NAMED_GID" != "$REPLACED_FIVEGPN_GID" ]]; then
            if ! residual="$(find "$root" -gid "$REPLACED_FIVEGPN_NAMED_GID" -print -quit 2>/dev/null)"; then
                err "Could not scan managed roots for the replaced fivegpn named-group GID."
                return 1
            fi
        fi
        if [[ -n "$residual" ]]; then
            err "A managed path still carries the replaced fivegpn UID/GID: $residual"
            return 1
        fi
    done
}

read_exact_systemd_unit_state() {
    local unit="$1" load active unit_file
    load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" || return 1
    [[ -n "$load" ]] || return 1
    case "$load" in
        not-found)
            SYSTEMD_UNIT_LOAD_STATE=not-found
            SYSTEMD_UNIT_ACTIVE_STATE=not-found
            SYSTEMD_UNIT_FILE_STATE=not-found
            return 0
            ;;
        loaded) ;;
        *) return 1 ;;
    esac
    active="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null)" || return 1
    unit_file="$(systemctl show -p UnitFileState --value "$unit" 2>/dev/null)" || return 1
    [[ -n "$active" && -n "$unit_file" ]] || return 1
    SYSTEMD_UNIT_LOAD_STATE="$load"
    SYSTEMD_UNIT_ACTIVE_STATE="$active"
    SYSTEMD_UNIT_FILE_STATE="$unit_file"
}

disable_scoped_renewal_timer() {
    read_exact_systemd_unit_state 5gpn-certbot-renew.timer \
        || { err "Could not read the scoped certificate renewal timer state."; return 1; }
    [[ "$SYSTEMD_UNIT_LOAD_STATE" == loaded ]] \
        || { err "The static scoped renewal timer is not installed."; return 1; }
    systemctl disable --now 5gpn-certbot-renew.timer >/dev/null 2>&1 \
        || { err "Could not disable the scoped certificate renewal timer."; return 1; }
    read_exact_systemd_unit_state 5gpn-certbot-renew.timer \
        || { err "Could not verify the scoped certificate renewal timer after disable."; return 1; }
    [[ "$SYSTEMD_UNIT_LOAD_STATE" == loaded \
       && "$SYSTEMD_UNIT_ACTIVE_STATE" == inactive \
       && "$SYSTEMD_UNIT_FILE_STATE" == disabled ]] \
        || { err "Scoped certificate renewal timer did not enter loaded/inactive/disabled state."; return 1; }
}
install_deps() {
    info "Installing dependencies..."
    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            gum_spin "更新软件包索引…" apt-get update -qq || true
            apt-get install -y -qq \
                curl ca-certificates unzip iproute2 openssl \
                jq util-linux dnsutils \
                || { err "Could not install required host packages."; return 1; }
            apt-get install -y -qq qrencode \
                || warn "qrencode is unavailable; QR display will use the plain URL fallback."
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
                curl ca-certificates unzip iproute openssl \
                jq util-linux bind-utils \
                || { err "Could not install required host packages."; return 1; }
            $PKG_MGR install -y -q qrencode \
                || warn "qrencode is unavailable; QR display will use the plain URL fallback."
            if [[ "$CERT_MODE" != debug ]]; then
                $PKG_MGR install -y -q certbot \
                    || { err "Could not install certbot from the OS repository."; return 1; }
            fi
            if [[ "$CERT_MODE" == cloudflare ]]; then
                $PKG_MGR install -y -q python3-certbot-dns-cloudflare \
                    || { err "Could not install the Cloudflare DNS plugin from the OS repository."; return 1; }
            fi
            ;;
    esac
    local cmd
    for cmd in curl openssl tar gzip unzip sha256sum ip flock timeout findmnt jq; do
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
INSTALL_PHASE="initialization"
INSTALL_FAILURE_REPORTED=0

sha256_of() { sha256sum "$1" | awk '{print tolower($1)}'; }

verify_sha256() {
    local file="$1" expected="${2,,}" got
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] \
        || { err "Missing/invalid pinned SHA-256 for $(basename "$file")."; return 1; }
    got="$(sha256_of "$file")"
    [[ "$got" == "$expected" ]] \
        || { err "SHA-256 mismatch for $(basename "$file") (want $expected got $got)."; return 1; }
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

valid_stable_release_tag() {
    local tag="$1"
    local number='(0|[1-9][0-9]*)'
    [[ "$tag" =~ ^${number}\.${number}\.${number}$ ]]
}

valid_beta_release_tag() {
    local tag="$1"
    local number='(0|[1-9][0-9]*)'
    [[ "$tag" =~ ^${number}\.${number}\.${number}-beta\.([1-9][0-9]*)$ ]]
}

valid_release_tag() {
    valid_stable_release_tag "$1" || valid_beta_release_tag "$1"
}

release_json_tag() {
    sed -n 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$1"
}

beta_tags_from_release_list() {
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+"' "$1" 2>/dev/null \
        | sed -E 's/^.*"([^"]+)"$/\1/' || true
}

stable_tags_from_release_list() {
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$1" 2>/dev/null \
        | sed -E 's/^.*"([^"]+)"$/\1/' || true
}

latest_beta_tag_from_list() {
    beta_tags_from_release_list "$1" \
        | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+)-beta\.([0-9]+)$/\1 \2 \3 \4 &/' \
        | sort -k1,1n -k2,2n -k3,3n -k4,4n \
        | tail -n 1 \
        | awk '{print $5}'
}

latest_stable_tag_from_list() {
    stable_tags_from_release_list "$1" \
        | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+)$/\1 \2 \3 &/' \
        | sort -k1,1n -k2,2n -k3,3n \
        | tail -n 1 \
        | awk '{print $4}'
}

decimal_component_is_greater() {
    local left="$1" right="$2" LC_ALL=C
    ((${#left} > ${#right})) && return 0
    ((${#left} < ${#right})) && return 1
    [[ "$left" > "$right" ]]
}

beta_base_is_newer_than_stable() {
    local beta="$1" stable="$2" beta_base
    local b_major b_minor b_patch s_major s_minor s_patch
    valid_beta_release_tag "$beta" && valid_stable_release_tag "$stable" || return 1
    beta_base="${beta%%-beta.*}"
    IFS=. read -r b_major b_minor b_patch <<< "$beta_base"
    IFS=. read -r s_major s_minor s_patch <<< "$stable"
    decimal_component_is_greater "$b_major" "$s_major" && return 0
    [[ "$b_major" == "$s_major" ]] || return 1
    decimal_component_is_greater "$b_minor" "$s_minor" && return 0
    [[ "$b_minor" == "$s_minor" ]] || return 1
    decimal_component_is_greater "$b_patch" "$s_patch"
}

resolve_latest_beta_tag() { # optional list and exact-metadata URLs are internal test seams
    local list_url="${1:-${RELEASES_API}?per_page=100}"
    local metadata_url="${2:-}"
    local list_json metadata_json candidate="" latest_stable="" metadata_tag

    list_json="$(mktemp /tmp/5gpn-beta-releases.XXXXXX)" || return 1
    if ! curl -fsSL "$list_url" -o "$list_json"; then
        rm -f -- "$list_json"
        err "Could not list 5gpn prereleases."
        return 1
    fi
    candidate="$(latest_beta_tag_from_list "$list_json")"
    latest_stable="$(latest_stable_tag_from_list "$list_json")"
    rm -f -- "$list_json"
    [[ -n "$candidate" ]] \
        || { err "No published 5gpn beta release is available."; return 1; }
    [[ -n "$latest_stable" ]] \
        || { err "Could not establish the latest official release before selecting beta."; return 1; }
    beta_base_is_newer_than_stable "$candidate" "$latest_stable" \
        || { err "Latest beta ${candidate} is not newer than official ${latest_stable}; refusing a channel downgrade."; return 1; }

    metadata_url="${metadata_url:-${RELEASES_API}/tags/${candidate}}"
    metadata_json="$(mktemp /tmp/5gpn-beta-release.XXXXXX)" || return 1
    if ! curl -fsSL "$metadata_url" -o "$metadata_json"; then
        rm -f -- "$metadata_json"
        err "Could not verify beta release ${candidate}."
        return 1
    fi
    metadata_tag="$(release_json_tag "$metadata_json")"
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

resolve_install_release_tag() { # optional stable/list/metadata URLs are internal test seams
    local requested="$RELEASE_TAG"
    local api_url="${1:-$STABLE_RELEASE_API}"
    local beta_list_url="${2:-}"
    local beta_metadata_url="${3:-}"
    local json tags

    if [[ "$requested" != latest ]]; then
        if valid_stable_release_tag "$requested"; then
            if [[ "$RELEASE_CHANNEL_EXPLICIT" == 1 && "$RELEASE_CHANNEL" == beta ]]; then
                err "A beta install cannot use an official-release installer bundle."
                return 1
            fi
            printf '%s\n' "$requested"
            return 0
        fi
        if valid_beta_release_tag "$requested"; then
            if [[ "$RELEASE_CHANNEL_EXPLICIT" == 1 && "$RELEASE_CHANNEL" != beta ]]; then
                err "A beta installer bundle requires the beta release channel."
                return 1
            fi
            printf '%s\n' "$requested"
            return 0
        fi
        err "Installer has an invalid pinned release tag."
        return 1
    fi

    if [[ "$RELEASE_CHANNEL" == beta ]]; then
        resolve_latest_beta_tag "$beta_list_url" "$beta_metadata_url"
        return
    fi
    [[ "$RELEASE_CHANNEL" == stable ]] \
        || { err "Unknown 5gpn release channel: $RELEASE_CHANNEL"; return 1; }
    json="$(curl -fsSL "$api_url")" \
        || { err "Could not resolve the latest official 5gpn release."; return 1; }
    tags="$(printf '%s\n' "$json" | sed -n 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p')"
    [[ -n "$tags" && "$tags" != *$'\n'* ]] \
        || { err "Latest official release response has no unique tag."; return 1; }
    valid_stable_release_tag "$tags" \
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

flatten_zashboard_dist() {
    local root="$1" dist="${1}/dist" unexpected
    [[ -d "$root" && ! -L "$root" && -d "$dist" && ! -L "$dist" \
       && -f "$dist/index.html" && ! -L "$dist/index.html" ]] || return 1
    unexpected="$(find "$root" -mindepth 1 -maxdepth 1 ! -path "$dist" -print -quit 2>/dev/null)" \
        || return 1
    [[ -z "$unexpected" ]] || return 1
    find "$dist" -mindepth 1 -maxdepth 1 -exec mv -t "$root" -- {} + \
        || return 1
    rmdir -- "$dist"
}

validate_existing_runtime_documents() {
    local validator="${1:-${ARTIFACT_STAGE}/mihomo}" validator_label="${2:-staged Core}"
    local path present=0 owner_uid="" dns_revision_before="" dns_revision_after=""
    local dns_document="${FIVEGPN_STATE_DIR}/dns.json"
    VALIDATED_DNS_SOURCE_REVISION=""
    for path in "${FIVEGPN_STATE_DIR}/dns.json" "${FIVEGPN_STATE_DIR}/intercept.json" \
                "${FIVEGPN_STATE_DIR}/bot.json"; do
        [[ -e "$path" || -L "$path" ]] || continue
        present=1
        [[ -f "$path" && ! -L "$path" && "$(file_nlink "$path")" == 1 ]] \
            || { err "Existing runtime document path is unsafe: $path"; return 1; }
    done
    if [[ -f "$dns_document" && ! -L "$dns_document" ]]; then
        dns_revision_before="$(sha256sum "$dns_document" | awk '{print $1}')" || return 1
    fi
    if [[ "$present" != 1 ]]; then
        VALIDATED_DNS_SOURCE_REVISION=absent
        return 0
    fi
    [[ -x "$validator" ]] \
        || { err "The ${validator_label} validator is unavailable."; return 1; }
    current_deployment_proves_identity_repair \
        || { err "Existing runtime documents lack safe current-deployment provenance."; return 1; }
    if getent passwd "$FIVEGPN_SERVICE_USER" >/dev/null 2>&1; then
        managed_user_uid_is_exclusive "$FIVEGPN_SERVICE_USER" \
            && managed_primary_gid_is_exclusive_for_user "$FIVEGPN_SERVICE_USER" \
            || { err "The current fivegpn identity cannot authorize runtime document validation."; return 1; }
        current_fivegpn_identity_matches_pending_journal \
            || { err "The current fivegpn identity conflicts with the pending reconciliation journal."; return 1; }
        owner_uid="$(id -u "$FIVEGPN_SERVICE_USER")"
        identity_id_is_in_system_range uid "$owner_uid" \
            || { err "The current fivegpn UID is outside the system-account range."; return 1; }
    else
        journaled_identity_recovery_is_safe \
            || { err "A safe, unaliased identity reconciliation journal is required to validate ownerless runtime state."; return 1; }
        owner_uid="$REPLACED_FIVEGPN_UID"
        [[ -n "$owner_uid" ]] \
            || { err "Existing runtime documents cannot be validated from a group-only identity journal."; return 1; }
    fi
    timeout --kill-after=5s 30s "$validator" 5gpn-state validate \
        --owner-uid "$owner_uid" "$FIVEGPN_STATE_DIR" \
        >/dev/null \
        || { err "Existing runtime documents failed validation by the ${validator_label}."; return 1; }
    if [[ -n "$dns_revision_before" ]]; then
        [[ -f "$dns_document" && ! -L "$dns_document" ]] \
            || { err "The DNS document changed while the ${validator_label} validated it."; return 1; }
        dns_revision_after="$(sha256sum "$dns_document" | awk '{print $1}')" || return 1
        [[ "$dns_revision_after" == "$dns_revision_before" ]] \
            || { err "The DNS document changed while the ${validator_label} validated it."; return 1; }
        current_dns_document_is_compatible "$dns_document" \
            || { err "The Core-valid DNS document has drifted installation-owned listener or certificate fields."; return 1; }
        VALIDATED_DNS_SOURCE_REVISION="$dns_revision_after"
    else
        [[ ! -e "$dns_document" && ! -L "$dns_document" ]] \
            || { err "A DNS document appeared while the ${validator_label} validated runtime state."; return 1; }
        VALIDATED_DNS_SOURCE_REVISION=absent
    fi
    ok "Existing runtime documents were validated by the ${validator_label}."
}

stage_artifacts() {
    local ver controller_inspection_target state_validator_probe state_seed_probe
    local mihomo_asset mihomo_url mihomo_sha zash_asset zash_url zash_sha
    assert_release_pin_bundle_revision \
        || { err "Release pin files changed before artifact staging."; return 1; }
    ver="$(resolve_install_release_tag)" || return 1
    RELEASE_TAG="$ver"
    ARTIFACT_STAGE="$(mktemp -d /var/tmp/5gpn-artifacts.XXXXXX)" \
        || { err "Could not create artifact staging directory."; return 1; }
    chmod 0700 "$ARTIFACT_STAGE"
    claim_temp_dir "$ARTIFACT_STAGE" \
        || { rmdir -- "$ARTIFACT_STAGE"; err "Could not claim artifact staging directory."; return 1; }
    info "Staging pinned release artifacts (${ver})..."
    # Nothing is drawn from the moooyo/5gpn release itself any more. The console
    # SPA it used to publish is gone with the process that served it, and the
    # two artifacts that remain -- the core and the UI bundle -- come from their
    # own repositories under their own digest pins, so there is no release-wide
    # digest manifest to fetch and no base URL to build. RELEASE_TAG still
    # selects the channel and still gates an unpinned source; it no longer
    # selects an artifact.

    mihomo_asset="$(release_asset_name mihomo)" \
        && mihomo_url="$(release_download_url mihomo)" \
        && mihomo_sha="$(release_artifact_sha256 mihomo)" \
        || { err "Pinned mihomo release coordinates are invalid."; return 1; }
    curl -fsSL "$mihomo_url" \
        -o "$ARTIFACT_STAGE/mihomo.gz" \
        || { err "Could not download mihomo ${MIHOMO_VERSION} asset ${mihomo_asset}."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/mihomo.gz" "$mihomo_sha" || return 1
    gzip -dc "$ARTIFACT_STAGE/mihomo.gz" > "$ARTIFACT_STAGE/mihomo"
    chmod 0755 "$ARTIFACT_STAGE/mihomo"
    mihomo_reports_exact_version "$ARTIFACT_STAGE/mihomo" "$MIHOMO_VERSION" \
        || { err "Staged mihomo version does not match pinned release ${MIHOMO_VERSION}."; return 1; }

    zash_asset="$(release_asset_name zashboard)" \
        && zash_url="$(release_download_url zashboard)" \
        && zash_sha="$(release_artifact_sha256 zashboard)" \
        || { err "Pinned zashboard release coordinates are invalid."; return 1; }
    curl -fsSL "$zash_url" \
        -o "$ARTIFACT_STAGE/zash.zip" \
        || { err "Could not download zashboard ${ZASH_VERSION} asset ${zash_asset}."; return 1; }
    verify_sha256 "$ARTIFACT_STAGE/zash.zip" "$zash_sha" || return 1
    archive_paths_safe zip "$ARTIFACT_STAGE/zash.zip" \
        || { err "Unsafe path in zashboard archive."; return 1; }
    mkdir "$ARTIFACT_STAGE/zash"
    unzip -qo "$ARTIFACT_STAGE/zash.zip" -d "$ARTIFACT_STAGE/zash"
    extracted_tree_safe "$ARTIFACT_STAGE/zash" \
        || { err "Unsafe object found after zashboard archive extraction."; return 1; }
    if [[ -f "$ARTIFACT_STAGE/zash/dist/index.html" ]]; then
        flatten_zashboard_dist "$ARTIFACT_STAGE/zash" \
            || { err "Could not flatten the verified zashboard dist tree."; return 1; }
    fi
    [[ -f "$ARTIFACT_STAGE/zash/index.html" ]] \
        || { err "Staged zashboard archive has no index.html."; return 1; }

    if [[ ! -f "$MIHOMO_DIR/config.yaml" ]]; then
        local seed="$ARTIFACT_STAGE/mihomo-seed.yaml" line listeners
        listeners="$(render_mihomo_listeners "$MIHOMO_LISTEN_IPS" "$CONSOLE_DOMAIN")"
        install -d -m 0700 "$ARTIFACT_STAGE/mihomo-home"
        # Validating with `mihomo -t` against this exact binary is the test, not
        # a version comparison: the seed names paths outside its own home -- the
        # certificates it serves and the UI bundle at external-ui -- and a core
        # that will not accept them rejects the config outright, which would
        # leave the gateway unable to start. SAFE_PATHS is the unit's, because
        # the question is whether the core accepts this config as the service
        # will run it, not as a bare -t would see it.
        #
        # Placeholder secret: this candidate is fed to `mihomo -t` and
        # discarded. Nothing in it reaches the live config, which
        # render_mihomo_config writes later once the accounts are real.
        SEED_CONSOLE_DOMAIN="$CONSOLE_DOMAIN"
        SEED_CONTROLLER_SECRET="preflight-only-secret"
        render_mihomo_seed "${SCRIPT_DIR}/etc/mihomo/config.yaml.tmpl" \
            probe "$listeners" > "$seed" || return 1
        if ! SAFE_PATHS="$MIHOMO_SAFE_PATHS" \
             "$ARTIFACT_STAGE/mihomo" -t -f "$seed" -d "$ARTIFACT_STAGE/mihomo-home"; then
            err "Staged mihomo does not accept the seed this release publishes."
            err "The core and the seed ship together, so this is a packaging fault rather than a host one. Live deployment was not touched."
            return 1
        fi
        controller_inspection_target="$seed"
        ok "Staged mihomo accepts the seed; writing it."
    else
        SAFE_PATHS="$MIHOMO_SAFE_PATHS" \
            "$ARTIFACT_STAGE/mihomo" -t -f "$MIHOMO_DIR/config.yaml" -d "$MIHOMO_DIR" \
            || { err "Existing operator-owned mihomo config is invalid; live deployment was not touched."; return 1; }
        controller_inspection_target="$MIHOMO_DIR/config.yaml"
    fi
    mihomo_controller_inspection "$controller_inspection_target" >/dev/null \
        || { err "Staged mihomo does not provide the required controller inspection v2 contract."; return 1; }
    state_validator_probe="$ARTIFACT_STAGE/missing-state-validator-probe"
    [[ ! -e "$state_validator_probe" && ! -L "$state_validator_probe" ]] || return 1
    timeout --kill-after=5s 30s "$ARTIFACT_STAGE/mihomo" 5gpn-state validate \
        --owner-uid "$(id -u)" "$state_validator_probe" >/dev/null \
        || { err "Staged mihomo does not provide the required owner-bound state validation contract."; return 1; }
    state_seed_probe="$ARTIFACT_STAGE/state-seed-probe"
    install -d -m 0700 "$state_seed_probe" || return 1
    render_fresh_dns_document "$DOT_LISTEN_ADDR" "$DEBUG_LISTEN_ADDR" \
        "${DOT_CERT_DIR}/current/fullchain.pem" "${DOT_CERT_DIR}/current/privkey.pem" \
        "$GATEWAY_IP" "$DNS_CHINA_ECS_DEFAULT" "$DNS_CHINA_DEFAULT" "$DNS_TRUST_DEFAULT" \
        > "$state_seed_probe/dns.json" || return 1
    chmod 0600 "$state_seed_probe/dns.json" || return 1
    current_dns_document_is_compatible "$state_seed_probe/dns.json" \
        || { err "The installer rendered a DNS seed with drifted fixed fields."; return 1; }
    timeout --kill-after=5s 30s "$ARTIFACT_STAGE/mihomo" 5gpn-state validate \
        --owner-uid "$(id -u)" "$state_seed_probe" >/dev/null \
        || { err "Staged mihomo rejected the DNS document seed this installer publishes."; return 1; }
    validate_existing_runtime_documents || return 1
    ok "All release artifacts staged and verified."
}

cleanup_artifact_stage() {
    [[ -n "$ARTIFACT_STAGE" && -d "$ARTIFACT_STAGE" ]] || return 0
    remove_temp_dir "$ARTIFACT_STAGE" \
        || { warn "Refusing to remove unowned artifact staging directory: $ARTIFACT_STAGE"; return 1; }
    ARTIFACT_STAGE=""
}

ensure_private_lock_dir() {
    local lock_dir root_gid; lock_dir="$(dirname -- "$INSTALL_LOCK_FILE")"
    if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
        install -d -o root -g root -m 0700 "$lock_dir" \
            || { err "Could not create the installer lock directory."; return 1; }
    fi
    root_gid="$(account_gid root)" || return 1
    [[ -d "$lock_dir" && ! -L "$lock_dir" \
       && "$(readlink -f -- "$lock_dir" 2>/dev/null || true)" == "$lock_dir" \
       && "$(file_uid "$lock_dir")" == 0 \
       && "$(file_gid "$lock_dir")" == "$root_gid" \
       && "$(file_mode "$lock_dir")" == 700 ]] \
        || { err "Unsafe installer lock directory: ${lock_dir}"; return 1; }
}

lock_file_safe() {
    local lock_file="$1" root_gid
    [[ ! -e "$lock_file" && ! -L "$lock_file" ]] && return 0
    root_gid="$(account_gid root)" || return 1
    [[ -f "$lock_file" && ! -L "$lock_file" \
       && "$(file_uid "$lock_file")" == 0 \
       && "$(file_gid "$lock_file")" == "$root_gid" \
       && "$(file_mode "$lock_file")" == 600 \
       && "$(file_nlink "$lock_file")" == 1 ]]
}

lock_fd_targets_file() {
    local fd="$1" lock_file="$2" fd_identity file_identity
    [[ -e "/proc/${BASHPID}/fd/${fd}" && -e "$lock_file" ]] || return 1
    lock_file_safe "$lock_file" || return 1
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
        lock_fd_targets_file 7 "$INSTALL_LOCK_FILE" \
            || { err "Installer transaction lock identity changed during revalidation."; return 1; }
        INSTALL_LOCK_HELD=1
        return 0
    fi
    # No 2>/dev/null here. `exec` carrying only redirections applies them to the
    # shell itself and does not restore them, so that spelling silenced every
    # error message for the rest of the run — including the ones that explain
    # why an install aborted. Closing an fd that was never opened is not an
    # error in bash, so there is nothing to suppress.
    exec 7>&- || true
    exec 7>"$INSTALL_LOCK_FILE"
    chown root:root "$INSTALL_LOCK_FILE" \
        && chmod 0600 "$INSTALL_LOCK_FILE" \
        || { exec 7>&-; err "Could not protect the installer transaction lock file."; return 1; }
    lock_fd_targets_file 7 "$INSTALL_LOCK_FILE" \
        || { exec 7>&-; err "Installer transaction lock identity changed during open."; return 1; }
    wait_for_exclusive_lock 7 "$INSTALL_LOCK_WAIT_TIMEOUT" \
        "Another 5gpn install, configure, or uninstall transaction" \
        || { exec 7>&-; err "Timed out waiting for the 5gpn installer transaction lock."; return 1; }
    lock_fd_targets_file 7 "$INSTALL_LOCK_FILE" \
        || { exec 7>&-; err "Installer transaction lock identity changed after acquisition."; return 1; }
    INSTALL_LOCK_HELD=1
}

release_install_lock() {
    local rc=0
    if [[ "$INSTALL_LOCK_HELD" == 1 ]]; then
        lock_fd_targets_file 7 "$INSTALL_LOCK_FILE" || rc=1
        flock -u 7 2>/dev/null || rc=1
    fi
    # No 2>/dev/null here. `exec` carrying only redirections applies them to the
    # shell itself and does not restore them, so that spelling silenced every
    # error message for the rest of the run — including the ones that explain
    # why an install aborted. Closing an fd that was never opened is not an
    # error in bash, so there is nothing to suppress.
    exec 7>&- || true
    INSTALL_LOCK_HELD=0
    [[ "$rc" == 0 ]] || { err "The installer transaction lock descriptor was invalid during release."; return 1; }
}

require_completed_runtime_identity() {
    load_identity_reconcile_journal || return 1
    if [[ -n "$REPLACED_FIVEGPN_UID" || -n "$REPLACED_FIVEGPN_GID" \
       || -n "$REPLACED_FIVEGPN_NAMED_GID" ]]; then
        err "Runtime identity reconciliation is incomplete. Rerun the installer before changing or restarting the deployment."
        return 1
    fi
}

run_management_with_install_lock() (
    local rc
    acquire_install_lock || exit $?
    trap 'rc=$?; trap - EXIT HUP INT TERM; release_install_lock || true; exit "$rc"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    assert_installed_backend_revision || exit $?
    require_completed_runtime_identity || exit $?
    "$@"
)

run_management_with_install_and_cert_lock() (
    local rc
    acquire_install_lock || exit $?
    trap 'rc=$?; trap - EXIT HUP INT TERM; release_install_cert_lock || true; release_install_lock || true; exit "$rc"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    assert_installed_backend_revision || exit $?
    require_completed_runtime_identity || exit $?
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
        lock_fd_targets_file 8 "$CERT_RENEW_LOCK_FILE" \
            || { err "Certificate lock identity changed during revalidation."; return 1; }
        INSTALL_CERT_LOCK_HELD=1
        return 0
    fi
    exec 8>&- || true
    exec 8>"$CERT_RENEW_LOCK_FILE"
    chown root:root "$CERT_RENEW_LOCK_FILE" \
        && chmod 0600 "$CERT_RENEW_LOCK_FILE" \
        || { exec 8>&-; err "Could not protect the certificate-renewal lock file."; return 1; }
    lock_fd_targets_file 8 "$CERT_RENEW_LOCK_FILE" \
        || { exec 8>&-; err "Certificate lock identity changed during open."; return 1; }
    wait_for_exclusive_lock 8 "$CERT_LOCK_WAIT_TIMEOUT" \
        "Another 5gpn certificate update" \
        || { exec 8>&-; \
             err "Another certificate update still holds the transaction lock after ${CERT_LOCK_WAIT_TIMEOUT}s."; \
             err "Existing certificates are preserved, but they do not bypass concurrent certificate publication safety."; \
             err "Installation stopped before live publication; inspect 5gpn certificate services and retry."; \
             return 1; }
    lock_fd_targets_file 8 "$CERT_RENEW_LOCK_FILE" \
        || { exec 8>&-; err "Certificate lock identity changed after acquisition."; return 1; }
    INSTALL_CERT_LOCK_HELD=1
}

release_install_cert_lock() {
    local rc=0
    if [[ "$INSTALL_CERT_LOCK_HELD" == 1 ]]; then
        lock_fd_targets_file 8 "$CERT_RENEW_LOCK_FILE" || rc=1
        flock -u 8 2>/dev/null || rc=1
    fi
    exec 8>&- || true
    INSTALL_CERT_LOCK_HELD=0
    [[ "$rc" == 0 ]] || { err "The certificate lock descriptor was invalid during release."; return 1; }
}

# Clear a completed transaction snapshot so repeated cleanup is a no-op.
clear_global_certbot_timer_snapshot() {
    GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=0
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=""
    GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=""
    GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=""
    GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE=""
    GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED=""
    CERTBOT_TIMER_LOAD_STATE=""
    CERTBOT_TIMER_ACTIVE_STATE=""
    CERTBOT_TIMER_UNIT_FILE_STATE=""
}

# Restore both activity and enablement to the pre-transaction state. An owned
# lineage commits the opposite outcome only after its scoped renewal timer is
# enabled successfully. The function is idempotent and is used by success,
# error, EXIT, and signal paths while the certificate lock is still held.
restore_global_certbot_timer() {
    [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 1 ]] || return 0
    global_certbot_timer_matches_expected_state \
        || { err "The distro certbot.timer changed outside the installer transaction; refusing to overwrite it."; return 1; }
    if [[ "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" == not-found ]]; then
        clear_global_certbot_timer_snapshot
        return 0
    fi
    if [[ "$KEEP_GLOBAL_CERTBOT_TIMER_DISABLED" == 1 ]]; then
        [[ "$GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD" == loaded \
           && "$GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE" == inactive \
           && "$GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED" == disabled ]] \
            || { err "Could not keep the unscoped distro certbot.timer disabled."; return 1; }
        clear_global_certbot_timer_snapshot
        return 0
    fi
    case "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" in
        enabled)
            systemctl enable certbot.timer >/dev/null 2>&1 \
                || { err "Could not restore enabled certbot.timer state."; return 1; } ;;
        disabled)
            systemctl disable certbot.timer >/dev/null 2>&1 \
                || { err "Could not restore disabled certbot.timer state."; return 1; } ;;
        *)
            err "Unsupported original certbot.timer enablement state: ${GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED:-empty}"
            return 1 ;;
    esac

    case "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE" in
        active)
            systemctl start certbot.timer >/dev/null 2>&1 \
                || { err "Could not restore active certbot.timer state."; return 1; } ;;
        inactive)
            systemctl stop certbot.timer >/dev/null 2>&1 \
                || { err "Could not restore inactive certbot.timer state."; return 1; } ;;
        *)
            err "Unsupported original certbot.timer activity state: ${GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE:-empty}"
            return 1 ;;
    esac
    read_global_certbot_timer_state \
        || { err "Could not verify the restored distro certbot.timer state."; return 1; }
    [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded \
       && "$CERTBOT_TIMER_ACTIVE_STATE" == "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE" \
       && "$CERTBOT_TIMER_UNIT_FILE_STATE" == "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" ]] \
        || { err "Could not restore the exact original distro certbot.timer state."; return 1; }
    clear_global_certbot_timer_snapshot
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


finish_install_transaction() {
    local original_rc="$1" timer_rc=0 cleanup_rc=0 gum_cleanup_rc=0 ui_cleanup_rc=0 lock_rc=0 final_rc
    final_rc="$original_rc"
    trap '' HUP INT TERM
    trap - ERR EXIT

    # The installer does not undo a partial publication. Once the publication
    # phase starts, some roots may already exist unchanged while another step
    # may have written state, so report the possibility without claiming every
    # failure necessarily mutated the host.
    if [[ "$final_rc" != 0 ]]; then
        if [[ "${INSTALL_PUBLICATION_STARTED:-0}" == 1 ]]; then
            err "The installer does not roll back. Publication started, so this host may be partially installed."
            err "Inspect the reported phase, then rerun the installer or repair it by hand."
        else
            err "Publication did not start; no 5gpn publication step ran."
        fi
    fi

    set +e
    restore_global_certbot_timer
    timer_rc=$?
    cleanup_artifact_stage
    cleanup_rc=$?
    cleanup_temporary_gum
    gum_cleanup_rc=$?
    if [[ -n "${UI_GENERATION_CANDIDATE:-}" ]]; then
        load_ui_generation_helper \
            && ui_generation_cleanup_candidate "$UI_DIR" "$UI_GENERATION_CANDIDATE"
        ui_cleanup_rc=$?
        if [[ "$ui_cleanup_rc" == 0 ]]; then
            UI_GENERATION_CANDIDATE=""
            UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
        fi
    fi
    set -e
    [[ "$cleanup_rc" == 0 || -z "$ARTIFACT_STAGE" ]] \
        || err "Staging was retained at: $ARTIFACT_STAGE"
    [[ "$gum_cleanup_rc" == 0 || -z "$TEMP_GUM_DIR" ]] \
        || err "Temporary Gum staging was retained at: $TEMP_GUM_DIR"
    [[ "$ui_cleanup_rc" == 0 || -z "$UI_GENERATION_CANDIDATE" ]] \
        || err "Unpublished UI generation was retained at: $UI_GENERATION_CANDIDATE"

    set +e
    release_install_cert_lock
    [[ "$?" == 0 ]] || lock_rc=1
    release_install_lock
    [[ "$?" == 0 ]] || lock_rc=1
    set -e
    if [[ "$timer_rc" != 0 || "$cleanup_rc" != 0 || "$gum_cleanup_rc" != 0 \
       || "$ui_cleanup_rc" != 0 || "$lock_rc" != 0 ]]; then
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

prepare_intercept_runtime_dirs() {
    local path canonical
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        || { err "Unsafe configuration root: $CONF_DIR"; return 1; }
    for path in "$INTERCEPT_DIR" "$INTERCEPT_DIR/tls"; do
        runtime_directory_slot_is_safe "$path" "$CONF_DIR" \
            || { err "Refusing unsafe interception runtime path: $path"; return 1; }
        install -d -o root -g "$FIVEGPN_SERVICE_USER" -m 0750 "$path" || return 1
        canonical="$(canonical_dir_path "$path")" || return 1
        [[ "$canonical" == "$path" ]] \
            || { err "Refusing interception runtime path alias: $path -> $canonical"; return 1; }
    done
    chmod g-s "$INTERCEPT_DIR/tls" || return 1
    # The monolith only reads the root-published certificate result and TLS
    # material here. Its writable documents live below FIVEGPN_STATE_DIR and
    # persistent extension storage lives below INTERCEPT_STATE_DIR. Five octal
    # digits explicitly clear any inherited set-group-ID bit.
    chmod 00750 "$INTERCEPT_DIR" || return 1
}

prepare_intercept_state_dir() {
    claim_fixed_owned_dir "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" 1 || return 1
    install -d -o "$FIVEGPN_SERVICE_USER" -g "$FIVEGPN_SERVICE_USER" -m 0700 "$INTERCEPT_STATE_DIR" || return 1
    runtime_tree_has_only_plain_entries "$INTERCEPT_STATE_DIR" \
        || { err "Refusing unsafe extension storage tree: $INTERCEPT_STATE_DIR"; return 1; }
    find "$INTERCEPT_STATE_DIR" -mindepth 1 \
        ! -path "$INTERCEPT_STATE_DIR/$INTERCEPT_STATE_MARKER" \
        -exec chown "$FIVEGPN_SERVICE_USER:$FIVEGPN_SERVICE_GROUP" {} + || return 1
    write_ownership_marker "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" || return 1
}

intercept_keypair_matches() {
    local cert="$1" key="$2" cert_pub key_pub
    cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

validate_intercept_ca_pair() {
    local root_cert="$1" root_key="$2"
    root_plain_file_metadata_is_safe "$root_cert" 0 644 \
        && root_plain_file_metadata_is_safe "$root_key" 0 600 \
        || return 1
    openssl x509 -in "$root_cert" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
    openssl x509 -in "$root_cert" -noout -text 2>/dev/null | grep -Fq 'CA:TRUE' || return 1
    intercept_keypair_matches "$root_cert" "$root_key"
}

validate_intercept_ca() {
    validate_intercept_ca_pair "$INTERCEPT_CA_DIR/root.crt" "$INTERCEPT_CA_DIR/root.key"
}

recover_intercept_ca_publication() {
    local live_cert="$INTERCEPT_CA_DIR/root.crt" live_key="$INTERCEPT_CA_DIR/root.key"
    local new_cert="$INTERCEPT_CA_DIR/.root.crt.new" new_key="$INTERCEPT_CA_DIR/.root.key.new"
    local cert_source="" key_source="" path
    for path in "$live_cert" "$new_cert"; do
        [[ -e "$path" || -L "$path" ]] || continue
        root_plain_file_metadata_is_safe "$path" 0 644 \
            || { err "Unsafe interception CA certificate publication slot: $path"; return 1; }
    done
    for path in "$live_key" "$new_key"; do
        [[ -e "$path" || -L "$path" ]] || continue
        root_plain_file_metadata_is_safe "$path" 0 600 \
            || { err "Unsafe interception CA key publication slot: $path"; return 1; }
    done
    if [[ -e "$live_cert" && -e "$live_key" ]]; then
        validate_intercept_ca \
            || { err "Existing complete interception CA is invalid; refusing replacement."; return 1; }
        rm -f -- "$new_cert" "$new_key"
        return 0
    fi
    [[ -e "$live_cert" ]] && cert_source="$live_cert" || { [[ -e "$new_cert" ]] && cert_source="$new_cert"; }
    [[ -e "$live_key" ]] && key_source="$live_key" || { [[ -e "$new_key" ]] && key_source="$new_key"; }
    if [[ -n "$cert_source" && -n "$key_source" ]] \
       && validate_intercept_ca_pair "$cert_source" "$key_source"; then
        [[ "$cert_source" == "$live_cert" ]] || mv -Tf -- "$cert_source" "$live_cert" || return 1
        [[ "$key_source" == "$live_key" ]] || mv -Tf -- "$key_source" "$live_key" || return 1
        rm -f -- "$new_cert" "$new_key"
        sync -f "$INTERCEPT_CA_DIR" 2>/dev/null || true
        validate_intercept_ca || return 1
        return 0
    fi
    if [[ -e "$live_cert" || -e "$live_key" ]]; then
        err "An incomplete live interception CA cannot be proven to be an unpublished candidate; refusing trust-root replacement."
        return 1
    fi
    # No complete CA pair was ever published, so exact safe partials can be
    # discarded and regenerated without changing an enrolled trust root.
    rm -f -- "$live_cert" "$live_key" "$new_cert" "$new_key"
    sync -f "$INTERCEPT_CA_DIR" 2>/dev/null || true
}

preflight_intercept_ca_publication() {
    local entry name live_cert="$INTERCEPT_CA_DIR/root.crt" live_key="$INTERCEPT_CA_DIR/root.key"
    [[ -d "$INTERCEPT_CA_DIR" && ! -L "$INTERCEPT_CA_DIR" ]] || return 0
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$INTERCEPT_CA_MARKER") root_plain_file_metadata_is_safe "$entry" 0 644 || return 1 ;;
            root.crt|.root.crt.new) root_plain_file_metadata_is_safe "$entry" 0 644 || return 1 ;;
            root.key|.root.key.new) root_plain_file_metadata_is_safe "$entry" 0 600 || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$INTERCEPT_CA_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    if [[ -e "$live_cert" && -e "$live_key" ]]; then
        validate_intercept_ca
    fi
}

validate_intercept_leaf() {
    local leaf="$INTERCEPT_DIR/tls/leaf.crt" fullchain="$INTERCEPT_DIR/tls/fullchain.pem"
    local key="$INTERCEPT_DIR/tls/privkey.pem" state_file="$INTERCEPT_DIR/cert-state"
    local host probe request_target request_attempt state_target state_attempt
    local certificate_hash private_key_hash computed_target hosts san_output entry san_name
    local -a san_entries certificate_hosts
    command -v jq >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 || return 1
    [[ -f "$leaf" && ! -L "$leaf" && -f "$fullchain" && ! -L "$fullchain" \
       && -f "$key" && ! -L "$key" && -f "$CERT_REQUEST_FILE" \
       && ! -L "$CERT_REQUEST_FILE" && -f "$state_file" && ! -L "$state_file" ]] || return 1
    jq -e '
      type == "object" and
      ((keys | sort) == ["attempt", "hosts", "target_digest", "version"]) and
      .version == 1 and
      (.target_digest | type == "string" and test("^[0-9a-f]{64}$")) and
      (.attempt | type == "string" and test("^[0-9a-f]{32}$")) and
      (.hosts | type == "array" and length > 0 and length <= 512 and
        . == (sort | unique) and
        all(.[]; type == "string" and test("^(\\*\\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$")))
    ' "$CERT_REQUEST_FILE" >/dev/null 2>&1 || return 1
    jq -e '
      type == "object" and
      ((keys | sort) == ["attempt", "certificate_sha256", "private_key_sha256", "status", "target_digest", "version"]) and
      .version == 1 and .status == "ready" and
      (.target_digest | type == "string" and test("^[0-9a-f]{64}$")) and
      (.attempt | type == "string" and test("^[0-9a-f]{32}$")) and
      (.certificate_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.private_key_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' "$state_file" >/dev/null 2>&1 || return 1
    request_target="$(jq -r '.target_digest' "$CERT_REQUEST_FILE")" || return 1
    request_attempt="$(jq -r '.attempt' "$CERT_REQUEST_FILE")" || return 1
    state_target="$(jq -r '.target_digest' "$state_file")" || return 1
    state_attempt="$(jq -r '.attempt' "$state_file")" || return 1
    [[ "$request_target" == "$state_target" && "$request_attempt" == "$state_attempt" ]] || return 1
    hosts="$(jq -r '.hosts[]' "$CERT_REQUEST_FILE")" || return 1
    computed_target="$(printf '%s\n' "$hosts" | sha256sum | awk '{print $1}')" || return 1
    [[ "$computed_target" == "$request_target" ]] || return 1
    certificate_hash="$(sha256sum "$fullchain" | awk '{print $1}')" || return 1
    private_key_hash="$(sha256sum "$key" | awk '{print $1}')" || return 1
    [[ "$certificate_hash" == "$(jq -r '.certificate_sha256' "$state_file")" \
       && "$private_key_hash" == "$(jq -r '.private_key_sha256' "$state_file")" ]] || return 1
    openssl x509 -in "$leaf" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
    openssl verify -CAfile "$INTERCEPT_CA_DIR/root.crt" "$leaf" >/dev/null 2>&1 || return 1
    intercept_keypair_matches "$leaf" "$key" || return 1
    [[ "$(openssl x509 -in "$leaf" -noout -fingerprint -sha256 2>/dev/null)" \
       == "$(openssl x509 -in "$fullchain" -noout -fingerprint -sha256 2>/dev/null)" ]] || return 1
    san_output="$(openssl x509 -in "$leaf" -noout -ext subjectAltName 2>/dev/null)" || return 1
    san_output="$(tail -n +2 <<<"$san_output" | tr '\n' ',')"
    IFS=',' read -r -a san_entries <<<"$san_output"
    certificate_hosts=()
    for entry in "${san_entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -n "$entry" ]] || continue
        [[ "$entry" == DNS:* ]] || return 1
        san_name="${entry#DNS:}"
        [[ "$san_name" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
        certificate_hosts+=("$san_name")
    done
    [[ "${#certificate_hosts[@]}" -gt 0 \
       && "${#certificate_hosts[@]}" == "$(printf '%s\n' "${certificate_hosts[@]}" | sort -u | wc -l | tr -d '[:space:]')" \
       && "$(printf '%s\n' "${certificate_hosts[@]}" | sort)" == "$hosts" ]] || return 1
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
    recover_intercept_ca_publication || return 1
    stage="$(mktemp -d /var/tmp/5gpn-intercept-cert.XXXXXX)" || return 1
    chmod 0700 "$stage"
    claim_temp_dir "$stage" || { rmdir -- "$stage"; return 1; }
    if validate_intercept_ca; then
        :
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
    # The installer establishes the root of trust and stops there.
    #
    # It used to mint a leaf too, which put it inside a loop that is otherwise
    # entirely event-driven: the engine writes its certificate request, the path
    # unit sees that file change, and the root oneshot signs a leaf covering
    # exactly the hosts it names. Calling the same script here added a second
    # entry point and, with it, a first-install special case -- there is nothing
    # to sign on a gateway whose extension set is empty.
    #
    # Removing it leaves one path to a leaf and no special cases. The first real
    # issuance happens when the first extension is enabled, which is also the
    # first moment a leaf means anything.
    if [[ -s "$CERT_REQUEST_FILE" ]] \
       && jq -e '.version == 1 and (.hosts | type == "array" and length > 0)' \
            "$CERT_REQUEST_FILE" >/dev/null 2>&1; then
        validate_intercept_leaf \
            || warn "The interception leaf does not currently cover the enabled capture hosts; the certificate watcher will reissue it."
    fi
    ok "Dedicated interception CA is ready; leaves are issued on demand."
}

# zashboard: prebuilt static dist from our fork moooyo/zashboard, which carries
# the 5gpn panels upstream does not have. Pinned by ZASH_REPO/ZASH_VERSION and
# verified against ZASH_SHA256. It is staged as one unpublished generation;
# profile signing completes that generation before one `current` symlink swap.
#
# This is the only user interface, and publishing it is NOT optional. mihomo
# serves it at /ui/ on the controller, reading it from the path the seed
# template names in external-ui. 5gpn-mihomo.service lists that same path in
# ReadOnlyPaths without a `-` prefix, so if nothing published here systemd
# cannot build the unit's namespace and the service does not start at all.
# It used to be warn-not-fatal, when a missing panel only cost a panel.
#
# This ONLY acquires+unzips the dist -- it does not seed a backend. zashboard
# reaches the controller as a same-origin relative URL, because the bundle and
# the API are now served by one process on one origin.
install_ui() {
    local candidate
    [[ -n "$ARTIFACT_STAGE" && -f "$ARTIFACT_STAGE/zash/index.html" ]] \
        || { err "zashboard was not staged."; return 1; }
    claim_ui_dir || return 1
    load_ui_generation_helper || return 1
    if [[ -n "$UI_GENERATION_CANDIDATE" ]]; then
        ui_generation_cleanup_candidate "$UI_DIR" "$UI_GENERATION_CANDIDATE" \
            || { err "Could not clean the previous unpublished UI generation."; return 1; }
        UI_GENERATION_CANDIDATE=""
        UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
    fi
    candidate="$(ui_generation_stage_tree "$UI_DIR" "$ARTIFACT_STAGE/zash" "$ZASH_VERSION")" \
        || { err "Could not stage the verified zashboard generation."; return 1; }
    UI_GENERATION_CANDIDATE="$candidate"
    ok "Verified zashboard ${ZASH_VERSION} staged in an unpublished UI generation."
}

# mihomo: prebuilt binary from the maintained moooyo/mihomo fork.
# MIHOMO_VERSION and MIHOMO_SHA256 are fixed release coordinates and every
# download is rejected unless both the digest and embedded version match.
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
    return 0
}

# ----------------------------------------------------------------------------
# Install config + scripts + control-plane sources
# ----------------------------------------------------------------------------
# render_mihomo_config renders /etc/5gpn/mihomo/config.yaml from the committed
# template (etc/mihomo/config.yaml.tmpl), substituting the box-specific
# sentinels, then validates the
# rendered file with `mihomo -t` (fatal on failure — a bad config must never
# be left live). This is the SINGLE writer for the mihomo data-plane config.

# Select the verified core used for structural config inspection. During an
# install the staged artifact is authoritative before publication; installed
# management commands use the published binary.
mihomo_config_inspector_binary() {
    if [[ -n "${ARTIFACT_STAGE:-}" && -x "${ARTIFACT_STAGE}/mihomo" ]]; then
        printf '%s' "${ARTIFACT_STAGE}/mihomo"
    elif [[ -x "$MIHOMO_BIN" ]]; then
        printf '%s' "$MIHOMO_BIN"
    else
        err "No verified mihomo binary is available for controller config inspection."
        return 1
    fi
}

# Return the exact v2 controller projection from the root-only core inspector.
# Shell never parses operator YAML and never persists the secret in dns.env.
# Exact keys and fixed values keep future contracts from being misread as this
# release's managed controller boundary.
mihomo_controller_inspection() {
    local config="${1:-${MIHOMO_DIR}/config.yaml}" inspector output
    [[ -f "$config" && ! -L "$config" && -r "$config" ]] \
        || { err "The operator mihomo config is missing, linked, or unreadable: $config"; return 1; }
    command -v jq >/dev/null 2>&1 \
        || { err "jq is required to validate the controller config inspection."; return 1; }
    inspector="$(mihomo_config_inspector_binary)" || return 1
    output="$("$inspector" 5gpn-config inspect-controller --config "$config" 2>/dev/null)" \
        || { err "The verified core rejected controller config inspection: $config"; return 1; }
    printf '%s' "$output" | jq -cse \
        --argjson version "$MIHOMO_CONTROLLER_INSPECTION_VERSION" \
        --arg controller "$MIHOMO_CONTROLLER_TLS_ADDR" \
        --arg ui "$UI_CURRENT_DIR" \
        --arg certificate "$MIHOMO_CONTROLLER_CERT" \
        --arg private_key "$MIHOMO_CONTROLLER_KEY" '
        select(length == 1) | .[0] | select(
            type == "object"
            and ((keys | sort) == ["certificate","external_controller_tls","external_ui","private_key","raw_revision","secret","version"])
            and (.version == $version)
            and (.raw_revision | type == "string" and test("^[0-9a-f]{64}$"))
            and (.secret | type == "string" and length > 0 and (explode | all(. >= 32 and . != 127)))
            and (.external_controller_tls == $controller)
            and (.external_ui == $ui)
            and (.certificate == $certificate)
            and (.private_key == $private_key)
        )' \
        || { err "The controller config inspection does not match the managed 5gpn contract."; return 1; }
}

mihomo_controller_inspection_field() {
    local inspection="$1" field="$2"
    printf '%s' "$inspection" | jq -er --arg field "$field" '.[$field]'
}

yaml_single_quoted_value() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

# Seed mihomo's fully operator-owned config only when it is missing. A normal
# install or configure operation validates and preserves an existing file
# byte-for-byte. `render_mihomo_config --reset` is the sole overwrite path: it
# renders to a same-directory candidate, validates that candidate, backs up the
# old file, fsyncs, and atomically renames it into place.
render_mihomo_config() {
    local mode="${1:-seed}" config="${MIHOMO_DIR}/config.yaml" secret="" template=""
    local inspection="" inspected_revision=""
    MIHOMO_SEED_PORTS_REQUIRED=0
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        || { err "Unsafe configuration root: $CONF_DIR"; return 1; }
    runtime_directory_slot_is_safe "$MIHOMO_DIR" "$CONF_DIR" \
        || { err "Refusing unsafe mihomo directory slot: $MIHOMO_DIR"; return 1; }
    runtime_file_slot_is_safe "$config" "$CONF_DIR" \
        || { err "Refusing unsafe mihomo configuration file slot."; return 1; }
    install -d -g "$FIVEGPN_SERVICE_USER" -m 3770 "$MIHOMO_DIR"
    runtime_tree_has_only_plain_entries "$MIHOMO_DIR" \
        || { err "Refusing unsafe link, hardlink, or special entry below $MIHOMO_DIR"; return 1; }

    if [[ -f "$config" && "$mode" != "--reset" ]]; then
        if ! SAFE_PATHS="$MIHOMO_SAFE_PATHS" "$MIHOMO_BIN" -t -f "$config" -d "$MIHOMO_DIR"; then
            err "Existing operator-owned mihomo config is invalid; it was NOT overwritten: $config"
            return 1
        fi
        chown "root:$FIVEGPN_SERVICE_GROUP" "$config" 2>/dev/null || true
        chmod 0640 "$config" 2>/dev/null || true
        inspection="$(mihomo_controller_inspection "$config")" \
            || { err "Existing mihomo controller configuration could not be inspected safely."; return 1; }
        ok "Existing operator-owned mihomo config validated and preserved: $config"
        return 0
    fi

    template="${BASE_DIR}/etc/mihomo/config.yaml.tmpl"
    [[ -f "$template" && -r "$template" && -s "$template" ]] \
        || { err "Bundled mihomo seed template is missing, unreadable, or empty: $template"; return 1; }

    # Controller secret survives an explicit reset. On first install, prefer a
    # structurally inspected existing value and otherwise generate a strong
    # mixed secret. dns.env never contains the credential.
    if [[ -f "$config" ]]; then
        inspection="$(mihomo_controller_inspection "$config")" \
            || { err "Existing mihomo controller configuration could not be inspected safely."; return 1; }
        secret="$(mihomo_controller_inspection_field "$inspection" secret)" || return 1
        inspected_revision="$(mihomo_controller_inspection_field "$inspection" raw_revision)" || return 1
    fi
    [[ -n "$secret" ]] || secret="$(openssl rand -base64 24)"

    # Resolve deployment-specific seed values only for first install/reset.
    local base="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    derive_domains "$base"
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    export MIHOMO_LISTEN_IPS
    local listeners candidate line backup secret_yaml_value
    secret_yaml_value="$(yaml_single_quoted_value "$secret")" \
        || { err "The mihomo controller secret cannot be represented safely in YAML."; return 1; }
    listeners="$(render_mihomo_listeners "$MIHOMO_LISTEN_IPS" "$CONSOLE_DOMAIN")"
    candidate="$(mktemp "${MIHOMO_DIR}/.config.yaml.XXXXXX")" \
        || { err "Could not create a mihomo config candidate in $MIHOMO_DIR"; return 1; }

    SEED_CONSOLE_DOMAIN="$CONSOLE_DOMAIN"
    SEED_CONTROLLER_SECRET="$secret_yaml_value"
    if ! render_mihomo_seed "$template" live "$listeners" > "$candidate"; then
        rm -f -- "$candidate"
        err "Could not render the mihomo config candidate from $template"
        return 1
    fi
    [[ -s "$candidate" ]] \
        || { rm -f -- "$candidate"; err "Rendered mihomo config candidate is empty."; return 1; }
    chown "root:$FIVEGPN_SERVICE_GROUP" "$candidate" \
        && chmod 0640 "$candidate" \
        || { rm -f -- "$candidate"; err "Could not secure the rendered mihomo config candidate."; return 1; }

    if ! SAFE_PATHS="$MIHOMO_SAFE_PATHS" "$MIHOMO_BIN" -t -f "$candidate" -d "$MIHOMO_DIR"; then
        rm -f -- "$candidate"
        err "mihomo candidate validation failed; live config was not changed."
        return 1
    fi
    sync -f "$candidate" 2>/dev/null || true
    if [[ -f "$config" ]]; then
        [[ "$(sha256sum "$config" | awk '{print $1}')" == "$inspected_revision" ]] \
            || { rm -f -- "$candidate"; err "Operator mihomo config changed after inspection; live config was not changed."; return 1; }
        backup="$(mktemp "${config}.bak.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" \
            || { rm -f -- "$candidate"; err "Could not reserve a mihomo config backup path."; return 1; }
        cp -p -- "$config" "$backup" \
            || { rm -f -- "$candidate" "$backup"; err "Could not back up the operator mihomo config; live config was not changed."; return 1; }
        chown "root:$FIVEGPN_SERVICE_GROUP" "$backup" \
            && chmod 0640 "$backup" \
            || { rm -f -- "$candidate" "$backup"; err "Could not secure the mihomo config backup; live config was not changed."; return 1; }
        sync -f "$backup" 2>/dev/null || true
        info "Backed up operator mihomo config to $backup"
    fi
    mv -f -- "$candidate" "$config" \
        || { rm -f -- "$candidate"; err "Could not atomically publish the mihomo config candidate."; return 1; }
    sync -f "$MIHOMO_DIR" 2>/dev/null || true
    MIHOMO_SEED_PORTS_REQUIRED=1

    ok "mihomo config ${mode/--/} candidate validated and atomically installed at $config."
}

reset_mihomo_config() {
    check_root
    install_gum_for_managed_deployment
    load_mihomo_reset_context || return 1
    warn "Explicit reset requested: the current operator mihomo config will be backed up and replaced with the validated seed."
    render_mihomo_config --reset || return 1
    restart_services || return 1
    ok "mihomo seed restored; backup retained beside ${MIHOMO_DIR}/config.yaml."
}

# ----------------------------------------------------------------------------
# The mihomo controller client.
# ----------------------------------------------------------------------------

# Dial the loopback controller using one already validated inspector snapshot.
# Address, trust root, and an optional bearer therefore come from one structural
# read of the operator config rather than independent shell parsers.
mihomo_controller_curl_with_inspection() {
    local inspection="$1" path="$2"; shift 2
    local controller server_name cert_file host port base
    controller="$(mihomo_controller_inspection_field "$inspection" external_controller_tls)" || return 1
    host="${controller%:*}"
    port="${controller##*:}"
    [[ "$host" != "$controller" && "$port" =~ ^[0-9]+$ ]] \
        || { warn "invalid mihomo controller address: $controller"; return 1; }
    base="${BASE_DOMAIN:-$(cfg_get DNS_BASE_DOMAIN)}"
    is_valid_domain "$base" \
        || { warn "DNS_BASE_DOMAIN is required for mihomo controller TLS"; return 1; }
    derive_domains "$base" || return 1
    server_name="$CONSOLE_DOMAIN"
    cert_file="$(mihomo_controller_inspection_field "$inspection" certificate)" || return 1
    [[ -r "$cert_file" ]] \
        || { warn "mihomo controller trust certificate is unreadable: $cert_file"; return 1; }
    curl --cacert "$cert_file" \
        --connect-to "${server_name}:${port}:${host}:${port}" \
        "$@" --noproxy '*' "https://${server_name}:${port}${path}"
}

# Public controller requests still inspect the config so management cannot
# drift onto a duplicate address, UI tree, or certificate path.
mihomo_controller_curl() {
    local path="$1" inspection; shift
    inspection="$(mihomo_controller_inspection)" || return 1
    mihomo_controller_curl_with_inspection "$inspection" "$path" "$@"
}

mihomo_authenticated_controller_curl() {
    local path="$1" inspection secret auth_fd status; shift
    inspection="$(mihomo_controller_inspection)" || return 1
    secret="$(mihomo_controller_inspection_field "$inspection" secret)" || return 1
    # Bash allocates a fresh descriptor for every request. curl reads the bearer
    # from that inherited descriptor, so it never appears in argv and stdin
    # remains available to callers using --data-binary @-.
    exec {auth_fd}<<<"Authorization: Bearer $secret" || return 1
    if mihomo_controller_curl_with_inspection "$inspection" "$path" \
        -H "@/proc/self/fd/${auth_fd}" "$@"; then
        status=0
    else
        status=$?
    fi
    exec {auth_fd}<&-
    return "$status"
}

# The interception snapshot, as JSON on stdout.
#
# Whether interception is on is a property of the engine's document, not of a
# unit's state -- there is no second process whose liveness could stand in for
# it. This asks the control API the same question the console asks, so the
# installer and the operator's browser cannot disagree about what is enabled.
fivegpn_interception_snapshot() {
    mihomo_authenticated_controller_curl "/5gpn/interception" \
        --fail --silent --show-error --max-time 3 2>/dev/null
}

# Static nodes remain fields in the operator-owned mihomo YAML. The core's
# one-shot helper performs structured parsing and the atomic file transaction;
# this shell surface only gathers input and asks the already-running controller
# to hot-apply the resulting complete file.
fivegpn_nodes_snapshot() {
    SAFE_PATHS="$MIHOMO_SAFE_PATHS" "$MIHOMO_BIN" 5gpn-nodes list \
        --config "${MIHOMO_DIR}/config.yaml"
}

fivegpn_reload_operator_config() {
    local body
    body="$(jq -nc --arg path "${MIHOMO_DIR}/config.yaml" '{path: $path}')" || return 1
    mihomo_authenticated_controller_curl "/configs" \
        --fail-with-body --silent --show-error --max-time 120 \
        -H 'Content-Type: application/json' \
        -X PUT --data "$body" >/dev/null
}

fivegpn_live_proxies_snapshot() {
    mihomo_authenticated_controller_curl "/proxies" \
        --fail --silent --show-error --max-time 10
}

fivegpn_verify_live_node_change() {
    local result="$1" action="$2" live names name
    live="$(fivegpn_live_proxies_snapshot)" || return 1
    case "$action" in
        import)
            names="$(printf '%s' "$result" | jq -c '.added')" || return 1
            printf '%s' "$live" | jq -e --argjson names "$names" '
                [$names[] as $name |
                    (.proxies | has($name)) and
                    ((.proxies.Proxies.all // []) | index($name) != null)] | all
            ' >/dev/null
            ;;
        delete)
            name="$(printf '%s' "$result" | jq -r '.removed')" || return 1
            printf '%s' "$live" | jq -e --arg name "$name" '
                ((.proxies | has($name)) | not) and
                (((.proxies.Proxies.all // []) | index($name)) == null)
            ' >/dev/null
            ;;
        *) return 1 ;;
    esac
}

fivegpn_apply_node_change() {
    local result="$1" action="$2"
    if fivegpn_reload_operator_config \
       && fivegpn_verify_live_node_change "$result" "$action"; then
        return 0
    fi
    warn "mihomo 热应用或运行态核对失败；将重启完整服务以应用已验证的磁盘配置。"
    restart_services || return 1
    fivegpn_verify_live_node_change "$result" "$action"
}

install_mihomo_runtime_assets() {
    local runtime_dir="${BASE_DIR}/etc/mihomo" asset source candidate
    install -d -m 0755 "$runtime_dir" \
        || { err "Could not create the installed mihomo asset directory: $runtime_dir"; return 1; }

    for asset in config.yaml.tmpl; do
        source="${SCRIPT_DIR}/etc/mihomo/${asset}"
        [[ -f "$source" && -r "$source" && -s "$source" ]] \
            || { err "Required mihomo runtime asset is missing, unreadable, or empty: $source"; return 1; }
    done

    for asset in config.yaml.tmpl; do
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

install_release_pin_files() {
    local name destination candidate expected_revision current_revision encoded
    local -a pin_files=(
        pins.env
        pins.sh
    )

    runtime_directory_slot_is_safe "$RELEASE_DIR" "$BASE_DIR" \
        || { err "Refusing unsafe installed release-pin directory slot: $RELEASE_DIR"; return 1; }
    install -d -o root -g root -m 0755 "$RELEASE_DIR" \
        || { err "Could not create the installed release-pin directory: $RELEASE_DIR"; return 1; }
    root_owned_nonwritable_directory_is_safe "$RELEASE_DIR" \
        && [[ "$(file_gid "$RELEASE_DIR")" == 0 && "$(file_mode "$RELEASE_DIR")" == 755 ]] \
        || { err "Installed release-pin directory metadata is unsafe: $RELEASE_DIR"; return 1; }
    clear_owned_scope "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        "$RELEASE_DIR" "${pin_files[@]}" \
        || { err "Could not reset the managed release-pin directory."; return 1; }

    for name in "${pin_files[@]}"; do
        destination="${RELEASE_DIR}/${name}"
        case "$name" in
            pins.env)
                expected_revision="$RELEASE_PINS_ENV_REVISION"
                encoded="$RELEASE_PINS_ENV_SNAPSHOT_B64"
                ;;
            pins.sh)
                expected_revision="$RELEASE_PINS_LIBRARY_REVISION"
                encoded="$RELEASE_PINS_LIBRARY_SNAPSHOT_B64"
                ;;
            *) return 1 ;;
        esac
        [[ -n "$encoded" ]] \
            || { err "The in-memory release-pin snapshot is missing: $name"; return 1; }
        candidate="$(mktemp "${RELEASE_DIR}/.${name}.XXXXXX")" \
            || { err "Could not stage installed release-pin file: $name"; return 1; }
        if ! printf '%s' "$encoded" | base64 -d > "$candidate" \
           || ! chown root:root "$candidate" \
           || ! chmod 0644 "$candidate"; then
            rm -f -- "$candidate"
            err "Could not materialize the private release-pin snapshot: $name"
            return 1
        fi
        sync -f "$candidate" 2>/dev/null || true
        current_revision="$(sha256sum -- "$candidate" 2>/dev/null | awk '{print $1}')" \
            || { rm -f -- "$candidate"; err "Could not fingerprint staged release-pin file: $name"; return 1; }
        [[ "$current_revision" == "$expected_revision" ]] \
            || { rm -f -- "$candidate"; err "Release-pin snapshot changed while it was staged: $name"; return 1; }
        mv -f -- "$candidate" "$destination" \
            || { rm -f -- "$candidate"; err "Could not publish release-pin file: $name"; return 1; }
        current_revision="$(sha256sum -- "$destination" 2>/dev/null | awk '{print $1}')" \
            || { err "Could not fingerprint installed release-pin file: $destination"; return 1; }
        root_plain_file_metadata_is_safe "$destination" 0 644 \
            && [[ "$current_revision" == "$expected_revision" ]] \
            || { err "Installed release-pin file failed verification: $destination"; return 1; }
    done
    sync -f "$RELEASE_DIR" \
        || { err "Could not make the installed release-pin directory durable."; return 1; }
}

install_files() {
    local f script_name u
    local -a installed_scripts=(
        publication-fs.sh
        cert-role-ctl.sh
        cert-renew.sh
        configure-runtime-gate.sh
        gen-ios-profile.sh
        intercept-cert-renew.sh
        renew-hook.sh
        ui-generation.sh
    )
    info "Installing config files and scripts..."
    preflight_runtime_publication_paths || return 1
    mkdir -p "$BASE_DIR" "$SCRIPTS_DIR" "$CONF_DIR" "$DNS_CERT_DIR"
    install_release_pin_files || return 1
    for script_name in "${installed_scripts[@]}"; do
        f="${SCRIPT_DIR}/scripts/${script_name}"
        [[ -f "$f" && ! -L "$f" ]] \
            || { err "Required installed script is missing or unsafe: $f"; return 1; }
        if [[ "$f" == "${SCRIPTS_DIR}/${script_name}" ]]; then
            [[ "$(file_uid "$f")" == 0 && "$(file_nlink "$f")" == 1 ]] \
                && mode_has_no_group_or_other_write "$(file_mode "$f")" \
                || { err "Installed script metadata is unsafe: $f"; return 1; }
        fi
    done
    clear_owned_scope "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        "$SCRIPTS_DIR" "${installed_scripts[@]}" \
        || { err "Could not reset the managed script directory."; return 1; }

    # This is an exact managed directory. Development helpers and obsolete
    # installer commands cannot enter or survive a reinstall.
    for script_name in "${installed_scripts[@]}"; do
        f="${SCRIPT_DIR}/scripts/${script_name}"
        if [[ "$f" == "${SCRIPTS_DIR}/${script_name}" ]]; then
            chmod 0755 "$f" || return 1
        else
            install -m 0755 "$f" "${SCRIPTS_DIR}/${script_name}" || return 1
        fi
    done
    # repo systemd units -> /opt/5gpn/etc/systemd (staged copies; install_units
    # installs them into /etc/systemd/system from here or from the checkout).
    install -d -m 0755 "${BASE_DIR}/etc/systemd"
    for u in "${MANAGED_SYSTEMD_UNITS[@]}"; do
        f="${SCRIPT_DIR}/etc/systemd/${u}"
        [[ -f "$f" && ! -L "$f" ]] \
            || { err "Required systemd unit is missing or unsafe: $f"; return 1; }
        if [[ "$f" == "${BASE_DIR}/etc/systemd/${u}" ]]; then
            [[ "$(file_uid "$f")" == 0 && "$(file_nlink "$f")" == 1 ]] \
                && mode_has_no_group_or_other_write "$(file_mode "$f")" \
                || { err "Installed unit staging metadata is unsafe: $f"; return 1; }
        fi
    done
    clear_owned_scope "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        "${BASE_DIR}/etc/systemd" "${MANAGED_SYSTEMD_UNITS[@]}" \
        || { err "Could not reset the managed systemd staging directory."; return 1; }
    for u in "${MANAGED_SYSTEMD_UNITS[@]}"; do
        f="${SCRIPT_DIR}/etc/systemd/${u}"
        if [[ "$f" == "${BASE_DIR}/etc/systemd/${u}" ]]; then
            chmod 0644 "$f" || return 1
        else
            install -m 0644 "$f" "${BASE_DIR}/etc/systemd/${u}" || return 1
        fi
    done
    # The installed management script resolves reset assets relative to
    # /opt/5gpn, so persist every mihomo seed input beside that script.
    install_mihomo_runtime_assets || return 1
    ok "Files installed under ${BASE_DIR} and ${CONF_DIR}."
}

# install_manage_cli installs the `5gpn` management command: a small launcher on
# PATH that opens the management menu (or runs a subcommand), backed by a copy of
# this installer at /opt/5gpn/install.sh. So an operator just types `5gpn`.
# Ownership of the fixed launcher path is its header marker alone. The body is
# generated by the heredoc in install_manage_cli below, so fingerprinting it
# here would mean any future edit to that heredoc rejects every host still
# running the previous release.
launcher_owned() {
    [[ -f /usr/local/bin/5gpn && ! -L /usr/local/bin/5gpn ]] \
        && grep -Eq '^# (Managed by 5gpn installer|5gpn management launcher)' /usr/local/bin/5gpn
}

install_manage_cli() {
    install -d -m 0755 "$BASE_DIR" || return 1
    [[ -f "$SCRIPT_PATH" && ! -L "$SCRIPT_PATH" ]] \
        || { err "Installer must come from the verified quick-install bundle or a local checkout."; return 1; }
    publish_executable "$SCRIPT_PATH" "${BASE_DIR}/install.sh" || return 1
    local quick_source="${SCRIPT_DIR}/quick-install.sh"
    [[ -f "$quick_source" && ! -L "$quick_source" ]] \
        || { err "Verified quick-install.sh is required for future release-channel switches."; return 1; }
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

# restart_services restarts the sole long-running mihomo runtime. DNS,
# interception, the controller, and the bot return with that one process.
restart_services() {
    check_root
    load_ui_generation_helper || return 1
    _ui_generation_current_only_is_safe "$UI_DIR" \
        || { err "Current UI generation is unsafe; refusing to mutate service state."; return 1; }
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

# derive_domains <base> — the SINGLE derivation of the two service subdomains
# from the operator's ONE base (apex) domain. This is the ONLY place that knows
# the console./dot. prefix scheme -- every other call site (mihomo config
# render and dns.env writer) MUST obtain the derived domains by
# calling this function (or reading the globals it sets/exports), never by
# re-deriving "console.${base}" inline, to avoid drift.
# The base must already be validated. Sets BASE_DOMAIN plus the derived globals
# and exports them. The selected certificate mode covers both names.
#
# The panel and the controller share the console name and the one certificate
# role behind it. There is deliberately no second name aliased to the same
# listener: an alias would be a second way into the management plane with no
# second purpose, and every allow rule would have to be written twice.
derive_domains() {
    is_valid_domain "${1:-}" || { err "Base domain is missing or invalid."; return 1; }
    BASE_DOMAIN="$1"
    CONSOLE_DOMAIN="console.${BASE_DOMAIN}"
    DOT_DOMAIN="dot.${BASE_DOMAIN}"
    export BASE_DOMAIN CONSOLE_DOMAIN DOT_DOMAIN
}

load_persisted_domains() {
    local base
    base="$(cfg_get DNS_BASE_DOMAIN)"
    is_valid_domain "$base" \
        || { err "Persisted DNS_BASE_DOMAIN is missing or invalid."; return 1; }
    derive_domains "$base"
}

# Encode one URL component according to RFC 3986. The controller secret is
# generated from a deliberately small alphabet today, but treating it as an
# arbitrary byte string keeps a future `&`, `#`, `%`, or space from changing the
# setup fragment's fields.
url_percent_encode() {
    local value="${1-}" out="" char encoded i
    local LC_ALL=C
    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) out+="$char" ;;
            *)
                printf -v encoded '%%%02X' "'$char"
                out+="$encoded"
                ;;
        esac
    done
    printf '%s' "$out"
}

console_public_url() {
    local domain="${1:-${CONSOLE_DOMAIN:-}}"
    if [[ -z "$domain" ]]; then
        load_persisted_domains || return 1
        domain="$CONSOLE_DOMAIN"
    fi
    is_valid_domain "$domain" || return 1
    printf 'https://%s/ui/' "$domain"
}

# This is a client-side zashboard setup URL, not a server-side handoff. All
# connection fields, including the secret, live after `#` and therefore are not
# sent in the HTTP request. The Console removes them before probing, but the
# unconsumed URL and terminal scrollback are still password-equivalent.
console_setup_url() {
    local domain="${1:?console_setup_url needs a domain}"
    local secret="${2-}" encoded_domain encoded_secret secret_bytes
    is_valid_domain "$domain" || return 1
    [[ -n "$secret" && "$secret" != *$'\r'* && "$secret" != *$'\n'* ]] || return 1
    secret_bytes="$(LC_ALL=C; printf '%s' "${#secret}")"
    (( secret_bytes <= 4096 )) || return 1
    encoded_domain="$(url_percent_encode "$domain")" || return 1
    encoded_secret="$(url_percent_encode "$secret")" || return 1
    printf 'https://%s/ui/#/setup?type=clash&hostname=%s&port=443&https=1&secret=%s&label=5gpn&disableTunMode=1' \
        "$domain" "$encoded_domain" "$encoded_secret"
}

# print_console_connection_info <reveal-sensitive>
#
# A non-terminal install may be captured by CI, a remote log collector, or a
# provisioning service. It gets the public URL and a recovery instruction, but
# never the controller credential. The interactive install and the explicit
# root-only management action may opt in to the password and fragment link.
print_console_connection_info() {
    local reveal="${1:-0}" domain="${CONSOLE_DOMAIN:-}" public_url secret setup_url inspection
    if [[ -z "$domain" ]]; then
        load_persisted_domains || return 1
        domain="$CONSOLE_DOMAIN"
    fi
    public_url="$(console_public_url "$domain")" || return 1

    echo "控制台 Console"
    echo ""
    printf '  打开 Open           %s\n' "$public_url"
    if [[ "$reveal" != 1 ]]; then
        echo "  连接凭据未写入非交互输出。"
        echo "  在主机上运行 sudo 5gpn，然后选择「显示 Console 连接信息 Console connection」。"
        return 0
    fi

    inspection="$(mihomo_controller_inspection)" || return 1
    secret="$(mihomo_controller_inspection_field "$inspection" secret)" || return 1
    if setup_url="$(console_setup_url "$domain" "$secret")"; then
        printf '  一键连接（含密码）   %s\n' "$setup_url"
        echo "  ⚠ 上述链接等同于密码；不要转发、截图或保存到共享书签。"
    else
        echo "  一键连接不可用：当前密码超过 4096 UTF-8 字节，或不适合安全地放入 URL；请按下方字段手动填写。"
    fi
    echo ""
    echo "  手动填写 zashboard"
    echo "  后端类型 Type       Clash API"
    echo "  协议 Protocol       HTTPS"
    printf '  主机 Host           %s\n' "$domain"
    echo "  端口 Port           443"
    echo "  Secondary Path      留空"
    printf '  密码 Password       %s\n' "$secret"
    echo ""
    echo "  不要填写 127.0.0.1：zashboard 运行在浏览器中，127.0.0.1 指向浏览器所在的客户端，而不是网关。"
}

show_console_connection_info() {
    load_persisted_domains || return 1
    print_console_connection_info 1 | card
}

# ----------------------------------------------------------------------------
# The management TUI shown by bare `5gpn`.
#
# Five screens rather than one flat action list, because an operator restarting
# a service needs its state on screen and one resetting mihomo needs the current
# certificate context. A real terminal gets a single-key tab strip. Redirected
# output, TERM=dumb, and other terminals that cannot support it get the same
# screen table through the two-level gum-or-numbered-list fallback. The key
# reader uses Bash's bounded single-character read, never stty, so it leaves no
# terminal mode to recover after a signal.
# ----------------------------------------------------------------------------

# fivegpn_json reads one field out of a control-API response.
#
# jq is installed by install_deps, so it is present on any host that has an
# installation to manage -- but a missing one degrades to the fallback rather
# than failing the screen, because a status display that cannot render is worse
# than one that says "?".
fivegpn_json() {
    local json="$1" filter="$2" fallback="${3:-?}" out=""
    command -v jq >/dev/null 2>&1 || { printf '%s' "$fallback"; return 0; }
    out="$(printf '%s' "$json" | jq -r "$filter" 2>/dev/null || true)"
    [[ -n "$out" && "$out" != "null" ]] && printf '%s' "$out" || printf '%s' "$fallback"
}

# One word, always.
#
# `systemctl is-active` prints its verdict *and* exits non-zero for anything not
# running, so the obvious `|| echo unknown` appends a second line rather than
# replacing the first -- and the caller's printf then splits across rows. Taking
# the first line is what makes this a value rather than a stream.
manage_unit_state() {
    local state
    state="$(systemctl is-active "$1" 2>/dev/null | head -1 || true)"
    printf '%s' "${state:-unknown}"
}

manage_mark() { [[ "$1" == active ]] && printf '✅' || printf '❌'; }

# --- screen: overview ---------------------------------------------------------
manage_screen_overview() {
    local snap ver unit master total on cert_loaded cert_cov cert_missing cert_exp panel_url
    ver="$("$MIHOMO_BIN" -v 2>/dev/null | head -1 | awk '{print $3}' || true)"
    unit="$(manage_unit_state 5gpn-mihomo.service)"
    snap="$(fivegpn_interception_snapshot 2>/dev/null || true)"

    echo "5gpn 概览"
    echo ""
    printf '  %s 核心    %s (%s)\n' "$(manage_mark "$unit")" "${ver:-未知}" "$unit"
    printf '  %s DoT     %s\n' "$(manage_mark "$unit")" "$DOT_LISTEN_ADDR"

    if [[ -z "$snap" ]]; then
        printf '  ❔ 拦截    控制 API 不可达\n'
    elif ! command -v jq >/dev/null 2>&1; then
        # Never guess. Without jq every field below would fall back to its zero
        # value, which reads as a confident "off" for a switch that may be on --
        # and an operator acting on that is worse off than one told nothing.
        printf '  ❔ 拦截    控制 API 可达,但本机缺少 jq,无法解析状态\n'
    else
        master="$(fivegpn_json "$snap" '.snapshot.enabled' false)"
        total="$(fivegpn_json "$snap" '.snapshot.modules | length' 0)"
        on="$(fivegpn_json "$snap" '[.snapshot.modules[]? | select(.enabled)] | length' 0)"
        # "Installed" and "actively capturing" are two numbers, not one. A disabled extension
        # still declares hosts; reporting the declared set as the live one tells
        # the operator traffic is being intercepted when nothing is intercepting.
        printf '  %s 拦截    %s · %s/%s 启用\n' \
            "$([[ "$master" == true ]] && printf '✅' || printf '⏸️ ')" \
            "$([[ "$master" == true ]] && echo on || echo off)" "$on" "$total"
        printf '  🚫 HTTP/3 禁用\n'

        cert_loaded="$(fivegpn_json "$snap" '.snapshot.certificate.loaded' false)"
        cert_cov="$(fivegpn_json "$snap" '.snapshot.certificate.covers_all_capture_hosts' false)"
        if [[ "$cert_loaded" != true ]]; then
            printf '  ⏸️  拦截证书 尚未签发（没有扩展请求过捕获主机）\n'
        elif [[ "$cert_cov" != true ]]; then
            # The one failure that shows up as a client-side trust error with
            # nothing in the gateway's own logs. It has to be the loudest line.
            cert_missing="$(fivegpn_json "$snap" '[.snapshot.certificate.missing_hosts[]?] | join(", ")' '')"
            printf '  ❌ 拦截证书 未覆盖 %s\n' "$cert_missing"
        else
            cert_exp="$(fivegpn_json "$snap" '.snapshot.certificate.not_after' '')"
            if [[ -n "$cert_exp" && "$cert_exp" != "?" ]]; then
                printf '  ✅ 拦截证书 覆盖全部 · %s 到期\n' "$(date -d "@$cert_exp" '+%Y-%m-%d' 2>/dev/null || echo "$cert_exp")"
            else
                printf '  ✅ 拦截证书 覆盖全部\n'
            fi
        fi
    fi

    echo ""
    panel_url="$(console_public_url)" || panel_url="不可用"
    printf '  Console %s\n' "$panel_url"
    printf '  连接    选择「显示 Console 连接信息 Console connection」查看一键链接或手填参数\n'
    printf '  DoT     tls://%s:853\n' "${DOT_DOMAIN:-?}"
    printf '  公网 IP %s\n' "$(cfg_get DNS_PUBLIC_IP || echo N/A)"
    echo ""
    # Where the runtime surfaces went. Both of the menu entries this screen
    # replaced pointed at helpers deleted with the three-process layout, and an
    # operator looking for them needs somewhere to be sent.
    printf '  扩展、DNS 策略、Telegram 机器人都在控制台里配置。\n'
}

# --- screen: services ---------------------------------------------------------
manage_screen_services() {
    local unit state cert_mode cert_lineage cert_base configured_mode configured_base ownership_match=0
    echo "服务"
    echo ""
    for unit in 5gpn-mihomo.service 5gpn-intercept-cert.path 5gpn-intercept-cert.timer; do
        state="$(manage_unit_state "$unit")"
        printf '  %s %-32s %s\n' \
            "$(manage_mark "$state")" "$unit" "$state"
    done
    unit=5gpn-certbot-renew.timer
    cert_mode="$(cert_provenance_get mode || true)"
    cert_base="$(cert_provenance_get base || true)"
    cert_lineage="$(cert_provenance_get certbot_lineage || true)"
    configured_mode="$(cfg_get CERT_MODE || true)"
    configured_base="$(cfg_get DNS_BASE_DOMAIN || true)"
    if [[ -n "$configured_base" ]] \
       && certbot_lineage_owned_by_5gpn "$configured_base"; then
        ownership_match=1
    fi
    case "$cert_lineage" in
        owned)
            if [[ "$cert_mode" == "$configured_mode" \
               && "$cert_base" == "$configured_base" \
               && ( "$cert_mode" == cloudflare || "$cert_mode" == http-01 ) \
               && "$ownership_match" == 1 ]]; then
                state="$(manage_unit_state "$unit")"
                printf '  %s %-32s %s (5gpn-owned renewal)\n' \
                    "$(manage_mark "$state")" "$unit" "$state"
            else
                printf '  ⚠️  %-32s 需修复 renewal needs repair\n' "$unit"
            fi
            ;;
        reused)
            if [[ "$cert_mode" == "$configured_mode" \
               && "$cert_base" == "$configured_base" \
               && ( "$cert_mode" == cloudflare || "$cert_mode" == http-01 ) \
               && "$ownership_match" == 0 ]]; then
                printf '  ⏸️  %-32s 外部续期 external renewal\n' "$unit"
            else
                printf '  ⚠️  %-32s 需修复 renewal needs repair\n' "$unit"
            fi
            ;;
        missing)
            printf '  ⚠️  %-32s 需修复 renewal needs repair\n' "$unit"
            ;;
        none)
            if [[ "$cert_mode" == debug \
               && "$configured_mode" == debug \
               && "$cert_base" == "$configured_base" ]]; then
                printf '  ⏸️  %-32s 不适用 debug certificate\n' "$unit"
            else
                printf '  ⚠️  %-32s provenance 不完整\n' "$unit"
            fi
            ;;
        *)
            state="$(manage_unit_state "$unit")"
            printf '  ❔ %-32s %s (provenance unknown)\n' "$unit" "$state"
            ;;
    esac
    echo ""
    printf '  一个进程拥有解析、转发、控制台、机器人和拦截,所以只有一个服务单元。\n'
    printf '  两个 root oneshot 只因为它们持有网络进程不该碰的密钥材料而存在。\n'
}

# --- screen: certificates -----------------------------------------------------
manage_screen_certificates() {
    local mode role dir
    mode="$(cfg_get CERT_MODE || echo unknown)"
    echo "证书"
    echo ""
    printf '  签发模式  %s\n' "$mode"
    printf '  基础域名  %s\n' "$(cfg_get DNS_BASE_DOMAIN || echo '?')"
    echo ""
    for role in dot console; do
        dir="${CONF_DIR}/cert/${role}/current"
        if [[ -f "$dir/fullchain.pem" ]]; then
            printf '  ✅ %-5s %s 到期\n' "$role" \
                "$(openssl x509 -enddate -noout -in "$dir/fullchain.pem" 2>/dev/null | sed 's/notAfter=//' || echo '?')"
        else
            printf '  ⏸️  %-5s 未部署\n' "$role"
        fi
    done
    echo ""
    if [[ -f "${CONF_DIR}/intercept-ca/root.crt" ]]; then
        printf '  ✅ 拦截 CA 已建立\n'
    else
        printf '  ❌ 拦截 CA 缺失\n'
    fi
    # The signing key never enters the engine's address space; the leaf's SAN set
    # is the enforcement of the capture policy, and it only bounds anything
    # because the process holding the leaf cannot sign a new one.
    printf '  叶证书由 root oneshot 按需签发,签名密钥从不进入引擎地址空间。\n'
}

# --- screen: network ----------------------------------------------------------
manage_screen_network() {
    echo "网络"
    echo ""
    printf '  公网 IPv4     %s\n' "$(cfg_get DNS_PUBLIC_IP || echo N/A)"
    printf '  网关 IPv4     %s\n' "$(cfg_get DNS_GATEWAY_IP || echo N/A)"
    printf '  5gpn-mihomo 监听   %s\n' "$(cfg_get DNS_MIHOMO_LISTEN_IPS || echo N/A)"
}

# --- screen: static proxy nodes ----------------------------------------------
manage_screen_nodes() {
    local snapshot total members
    echo "节点"
    echo ""
    if ! snapshot="$(fivegpn_nodes_snapshot 2>/dev/null)"; then
        printf '  ❔ 无法读取 operator-owned mihomo 配置中的静态节点。\n'
        printf '  请确认当前 Core 支持 5gpn-nodes 本机管理命令。\n'
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1 \
       || ! printf '%s' "$snapshot" | jq -e '
            (.revision | test("^[0-9a-f]{64}$")) and
            (.group == "Proxies") and (.nodes | type == "array")
          ' >/dev/null 2>&1; then
        printf '  ❔ 节点配置可读,但无法解析管理结果。\n'
        return 0
    fi

    total="$(printf '%s' "$snapshot" | jq '.nodes | length')"
    members="$(printf '%s' "$snapshot" | jq '[.nodes[] | select(.in_proxies)] | length')"
    printf '  静态节点 %s · Proxies 成员 %s\n' "$total" "$members"
    echo ""
    if [[ "$total" == 0 ]]; then
        printf '  暂无静态节点；Proxies 仍可包含 DIRECT 或 proxy-provider。\n'
    else
        printf '%s' "$snapshot" | jq -r \
            '.nodes[] | [(.name | @json), .type, ((.server // "-") | @json), ((.port // "-") | tostring), (if .in_proxies then "Proxies" else "未加入" end)] | @tsv' \
          | while IFS=$'\t' read -r name type server port membership; do
                printf '  • %s  [%s]  %s:%s  %s\n' "$name" "$type" "$server" "$port" "$membership"
            done
    fi
    echo ""
    printf '  新增接受 Clash/Mihomo proxies YAML、常见分享链接或标准 Base64 订阅。\n'
    printf '  导入是静态快照；所有新节点追加到 Proxies,但不会自动切换当前选择。\n'
}

manage_add_nodes() {
    local before revision content preview result added
    command -v jq >/dev/null 2>&1 || { err "jq is required for node management."; return 1; }
    before="$(fivegpn_nodes_snapshot)" || return 1
    revision="$(printf '%s' "$before" | jq -r '.revision // empty')"
    [[ "$revision" =~ ^[0-9a-f]{64}$ ]] \
        || { err "Could not read the current mihomo configuration revision."; return 1; }

    content="$(ask_multiline \
        '粘贴节点 Paste nodes（保存退出后导入）' \
        'Clash proxies: YAML, ss:// / vmess:// / vless:// / trojan:// / hy2:// ...' || true)"
    [[ -n "${content//[[:space:]]/}" ]] || { warn "未输入节点,未做任何修改。"; return 0; }

    if ! preview="$(printf '%s' "$content" | SAFE_PATHS="$MIHOMO_SAFE_PATHS" \
        "$MIHOMO_BIN" 5gpn-nodes import \
        --dry-run --config "${MIHOMO_DIR}/config.yaml" --revision "$revision")"; then
        err "节点解析或配置校验失败；当前配置未改变。"
        return 1
    fi
    {
        echo "将新增并加入 Proxies："
        printf '%s' "$preview" | jq -r '.added[] | "  • " + @json'
        echo ""
        echo "导入不会自动切换 Proxies 当前选项。"
    } | card
    ask_yesno "确认写入以上静态节点?" || { warn "已取消,当前配置未改变。"; return 0; }

    if ! result="$(printf '%s' "$content" | SAFE_PATHS="$MIHOMO_SAFE_PATHS" \
        "$MIHOMO_BIN" 5gpn-nodes import \
        --config "${MIHOMO_DIR}/config.yaml" --revision "$revision")"; then
        err "节点解析或配置校验失败；当前配置未改变。"
        return 1
    fi
    fivegpn_apply_node_change "$result" import || {
        err "节点已安全写入磁盘,但运行态未核对成功；请检查 ${MIHOMO_DIR}/config.yaml 及其 .5gpn-nodes.bak。"
        return 1
    }

    added="$(printf '%s' "$result" | jq -r '.added | map(@json) | join(", ")')"
    ok "节点已写入 operator-owned config.yaml、加入 Proxies 并热应用: ${added}"
}

manage_delete_node() {
    local before revision choice index name display result live selected_by
    local -a encoded_names display_names options=()
    command -v jq >/dev/null 2>&1 || { err "jq is required for node management."; return 1; }
    before="$(fivegpn_nodes_snapshot)" || return 1
    revision="$(printf '%s' "$before" | jq -r '.revision // empty')"
    mapfile -t encoded_names < <(printf '%s' "$before" | jq -r '.nodes[].name | @base64')
    mapfile -t display_names < <(printf '%s' "$before" | jq -r '.nodes[].name | @json')
    if (( ${#encoded_names[@]} == 0 )); then
        warn "当前没有可删除的静态节点。"
        return 0
    fi
    for index in "${!display_names[@]}"; do
        options+=("$((index + 1)). ${display_names[$index]}")
    done
    choice="$(ask_choice '选择要删除的静态节点' "${options[@]}" '取消 Cancel' || true)"
    [[ -n "$choice" && "$choice" != '取消 Cancel' ]] || return 0
    index="${choice%%.*}"
    [[ "$index" =~ ^[0-9]+$ && "$index" -ge 1 && "$index" -le "${#encoded_names[@]}" ]] || return 1
    display="${display_names[$((index - 1))]}"
    name="$(printf '%s' "${encoded_names[$((index - 1))]}" | base64 -d)" || return 1
    live="$(fivegpn_live_proxies_snapshot 2>/dev/null)" \
        || { err "无法核对当前 selector 选择；为避免流量静默切换,拒绝删除。"; return 1; }
    selected_by="$(printf '%s' "$live" | jq -r --arg name "$name" '
        [.proxies | to_entries[] |
            select(.value.now? == $name and ((.value.all? // []) | index($name) != null)) |
            (.key | @json)] | join(", ")
    ')"
    if [[ -n "$selected_by" ]]; then
        warn "该节点当前被 selector 使用: ${selected_by}。请先切换选择后再删除。"
        return 1
    fi
    ask_yesno "确认从 config.yaml 和 Proxies 删除节点 ${display}?" || return 0

    if ! result="$(SAFE_PATHS="$MIHOMO_SAFE_PATHS" "$MIHOMO_BIN" 5gpn-nodes delete \
        --config "${MIHOMO_DIR}/config.yaml" --revision "$revision" --name "$name")"; then
        err "节点仍被其他组、规则或 dialer 引用,或配置已改变；未删除。"
        return 1
    fi
    fivegpn_apply_node_change "$result" delete || {
        err "删除已安全写入磁盘,但运行态未核对成功；请检查 ${MIHOMO_DIR}/config.yaml 及其 .5gpn-nodes.bak。"
        return 1
    }
    ok "节点已从 config.yaml 和 Proxies 删除并热应用: ${display}"
}

# manage_screen runs one screen: render its facts, offer its actions, repeat
# until the operator goes back. The status is re-rendered after every action, so
# the effect of what they just did is on screen before the next choice.
manage_screen() {
    local title="$1" render="$2"; shift 2
    local -a labels=("$@")
    local choice
    while true; do
        printf '\n'
        "$render" | card
        choice="$(ask_choice "$title" "${labels[@]}" "返回 Back" || true)"
        case "$choice" in
            "返回 Back"|"") return 0 ;;
            *) manage_action "$choice" || true ;;
        esac
    done
}

# Every action the TUI can take, in one place. A screen names labels; this maps
# them. Keeping the mapping single means a label with no branch is a visible
# gap here rather than a menu entry that silently does nothing.
manage_action() {
    case "$1" in
        "显示 Console 连接信息 Console connection")
            show_console_connection_info ;;
        "重启服务 Restart services")
            run_management_with_install_lock restart_services ;;
        "查看核心日志 Core logs")
            journalctl -u 5gpn-mihomo.service -n 80 --no-pager 2>/dev/null | card || warn "journalctl unavailable" ;;
        "编辑安装配置 Configure installation")
            run_management_with_install_lock configure_installation ;;
        "新增节点 Add nodes")
            run_management_with_install_lock manage_add_nodes ;;
        "删除节点 Delete node")
            run_management_with_install_lock manage_delete_node ;;
        "重新生成 iOS 描述文件 Regenerate iOS profile")
            run_management_with_install_and_cert_lock regen_ios ;;
        "设置 Cloudflare Token Set Cloudflare token")
            run_management_with_install_and_cert_lock set_cf_token ;;
        "重置 mihomo 配置 Reset mihomo config")
            if ask_yesno "确认备份并重置 operator-owned mihomo config?"; then
                run_management_with_install_lock reset_mihomo_config
            fi ;;
        "卸载 Uninstall")
            uninstall; return 1 ;;
        *) warn "未实现的操作: $1" ;;
    esac
}

# The screen table: title | renderer | label | label ...
#
# One definition, read by both the tab UI and the plain list, so the two cannot
# drift into offering different things -- which is the shape of the bug that let
# two menu entries do nothing for the whole of the monolith work.
MANAGE_SCREENS=(
    "概览|manage_screen_overview|显示 Console 连接信息 Console connection|重启服务 Restart services|编辑安装配置 Configure installation"
    "服务|manage_screen_services|重启服务 Restart services|查看核心日志 Core logs"
    "证书|manage_screen_certificates|重新生成 iOS 描述文件 Regenerate iOS profile|设置 Cloudflare Token Set Cloudflare token"
    "网络|manage_screen_network|编辑安装配置 Configure installation"
    "节点|manage_screen_nodes|新增节点 Add nodes|删除节点 Delete node"
    # Grouped because each one is irreversible or drops live sessions, and a list
    # that mixed them with "show status" made the cursor pass over them on the
    # way to something harmless.
    "危险操作|manage_screen_overview|重置 mihomo 配置 Reset mihomo config|卸载 Uninstall"
)

# manage_read_key — one keypress, decoded to a direction.
#
# `read -rsn1` is the whole mechanism. It reads a single character without
# echoing and bash restores the terminal settings itself, so there is no stty
# raw mode here and therefore nothing to restore on a signal. An earlier note in
# HANDOFF costed this as a hand-rolled raw-mode reader needing its own terminal
# restore on every signal; that was true of an stty implementation and is not
# true of this one.
#
# Arrows arrive as ESC [ A..D. The read for the rest of the sequence must TIME
# OUT: a bare ESC is an operator asking to leave, and a blocking read would hang
# the menu until they pressed something else.
manage_read_key() {
    local k rest
    IFS= read -rsn1 k || return 1
    case "$k" in
        $'\e')
            IFS= read -rsn2 -t 0.05 rest || rest=""
            case "$rest" in
                '[A') printf 'up' ;;
                '[B') printf 'down' ;;
                '[C') printf 'right' ;;
                '[D') printf 'left' ;;
                '')   printf 'quit' ;;
                *)    printf 'other' ;;
            esac ;;
        # read -n1 yields an empty string for Enter.
        '')  printf 'enter' ;;
        q|Q) printf 'quit' ;;
        h|H) printf 'left' ;;
        l|L) printf 'right' ;;
        k|K) printf 'up' ;;
        j|J) printf 'down' ;;
        *)   printf 'other' ;;
    esac
}

# manage_tab_strip — the tabs, with the active one inverted.
manage_tab_strip() {
    local active="$1" i title out=''
    for i in "${!MANAGE_SCREENS[@]}"; do
        title="${MANAGE_SCREENS[$i]%%|*}"
        if [[ "$i" == "$active" ]]; then
            out+=$'\033[7m'" ${title} "$'\033[0m'
        else
            out+=" ${title} "
        fi
    done
    printf '%s\n' "$out"
}

# Build the complete visible frame before touching the terminal. Facts are a
# cached renderer snapshot supplied by manage_menu_tabs; cursor-only movement
# therefore never repeats systemctl, API, certificate, or filesystem probes.
manage_tab_frame() {
    local tab="$1" cursor="$2" facts="$3"; shift 3
    local -a labels=("$@")
    local i
    manage_tab_strip "$tab"
    printf '\n%s\n\n' "$facts"
    for i in "${!labels[@]}"; do
        if [[ "$i" == "$cursor" ]]; then
            printf '  \033[7m> %s\033[0m\n' "${labels[$i]}"
        else
            printf '    %s\n' "${labels[$i]}"
        fi
    done
    printf '\n  ←/→ 切换标签  ↑/↓ 选择  Enter 执行  q 退出\n'
}

# manage_menu_tabs — one level: tabs across, actions down.
#
# Only reached on a real terminal. Everything it draws is printf, so there is no
# dependency on gum for input or layout; gum still styles the fact cards through
# card() when it is present.
manage_menu_tabs() {
    local tab=0 cursor=0 key entry title render facts="" frame="" loaded_tab=-1
    local -a labels
    while true; do
        entry="${MANAGE_SCREENS[$tab]}"
        title="${entry%%|*}"
        render="${entry#*|}"; render="${render%%|*}"
        IFS='|' read -r -a labels <<< "${entry#*|*|}"

        if [[ "$loaded_tab" != "$tab" ]]; then
            # card normally detects a terminal on stdout. This explicit mode
            # preserves Gum styling while its already-rendered bytes are being
            # captured for one atomic paint.
            facts="$("$render" | card capture)"
            loaded_tab="$tab"
        fi
        frame="$(manage_tab_frame "$tab" "$cursor" "$facts" "${labels[@]}")"
        # Reset any style left by an action, then clear and paint the already
        # complete frame in one write. H + frame + J left old suffixes on every
        # line where the new frame was shorter, including inverse-video and QR
        # remnants. The probes are already complete, so J + frame introduces
        # no wait on a blank screen and does not clear scrollback like 2J.
        printf '\033[0m\033[H\033[J%s\n' "$frame"

        key="$(manage_read_key)" || break
        case "$key" in
            left)
                tab=$(( (tab - 1 + ${#MANAGE_SCREENS[@]}) % ${#MANAGE_SCREENS[@]} ))
                cursor=0
                loaded_tab=-1 ;;
            right)
                tab=$(( (tab + 1) % ${#MANAGE_SCREENS[@]} ))
                cursor=0
                loaded_tab=-1 ;;
            up)   (( cursor > 0 )) && cursor=$(( cursor - 1 )) ;;
            down) (( cursor < ${#labels[@]} - 1 )) && cursor=$(( cursor + 1 )) ;;
            enter)
                # Leave an immediate, stable title while the selected action
                # prompts or performs work; never flash an empty terminal.
                printf '\033[0m\033[H\033[J▶ %s\n' "${labels[$cursor]}"
                # Actions prompt and print; they need the screen to themselves
                # and a cooked terminal, which is what we are already in.
                manage_action "${labels[$cursor]}" || true
                printf '\n按任意键返回 Press any key to return\n'
                manage_read_key >/dev/null || true
                loaded_tab=-1 ;;
            quit)
                printf '\033[0m\033[H\033[J'
                return 0 ;;
        esac
    done
}

# manage_menu_list — the two-level fallback, for anything that is not a terminal
# capable of single-key reads. It reads the same table, so it offers the same
# things in the same order.
manage_menu_list() {
    local screen entry title render i
    local -a labels titles=()
    for i in "${!MANAGE_SCREENS[@]}"; do
        titles+=("${MANAGE_SCREENS[$i]%%|*}")
    done
    while true; do
        screen="$(ask_choice "5gpn 管理" "${titles[@]}" "退出 Quit" || true)"
        [[ -n "$screen" && "$screen" != "退出 Quit" ]] || return 0
        for i in "${!MANAGE_SCREENS[@]}"; do
            entry="${MANAGE_SCREENS[$i]}"
            title="${entry%%|*}"
            [[ "$title" == "$screen" ]] || continue
            render="${entry#*|}"; render="${render%%|*}"
            IFS='|' read -r -a labels <<< "${entry#*|*|}"
            manage_screen "$title" "$render" "${labels[@]}"
            break
        done
    done
}

manage_menu() {
    check_root
    run_management_with_install_lock install_gum_for_managed_deployment || return 1
    activate_verified_installed_gum
    if [[ ! -t 0 ]]; then
        err "The 5gpn menu is interactive. Run a subcommand directly, e.g.:"
        echo "  5gpn status | 5gpn restart | 5gpn uninstall" >&2
        exit 1
    fi
    load_persisted_domains 2>/dev/null || true

    # Tabs need to draw at a cursor position and read one key at a time, so both
    # ends must be the terminal. Anything else -- output piped to a file, a
    # dumb TERM -- gets the list, which needs neither.
    if [[ -t 1 && -n "${TERM:-}" && "${TERM}" != dumb ]]; then
        manage_menu_tabs
    else
        manage_menu_list
    fi
}

# ----------------------------------------------------------------------------
# Domain + ACME certificate
# ----------------------------------------------------------------------------
is_valid_domain() {
    # Same FQDN rule as 5gpn/bot/domain.go's domainRE in the fork; bash ERE has no
    # lookahead, so total length is checked separately): lowercase [a-z0-9-]
    # labels (<=63), alphabetic 2-63 TLD, total 1..253. Case-insensitive.
    #
    # tests/test_domain_validation.sh and the fork's
    # TestValidDomainMatchesTheInstallerRule hold the same table. Two
    # implementations of one rule drift silently; both run it, so the day they
    # disagree one of them fails.
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

is_valid_cert_email() {
    local value="${1:-}" local_part domain
    [[ ${#value} -ge 3 && ${#value} -le 254 ]] || return 1
    [[ "$value" == *@* && "${value#*@}" != *"@"* ]] || return 1
    local_part="${value%%@*}"
    domain="${value#*@}"
    [[ ${#local_part} -ge 1 && ${#local_part} -le 64 ]] || return 1
    [[ "$local_part" =~ ^[A-Za-z0-9]([A-Za-z0-9._%+-]{0,62}[A-Za-z0-9])?$ ]] || return 1
    [[ "$local_part" != *..* ]] || return 1
    is_valid_domain "$domain"
}

is_valid_ipv4() {
    # Dotted-quad, each octet 0..255, with NO leading zero on a multi-digit octet
    # — matching Go's net.ParseIP in the monolith, which rejects e.g. 010.0.0.1.
    # Parity matters: DNS_GATEWAY_IP is fatal at startup, so accepting a value
    # the runtime rejects would put 5gpn-mihomo into its bounded restart loop.
    # 10#$o forces base-10 so a lone "0" octet still compares numerically.
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
# deploy it to the two current role directories:
#   dot  -> ${DOT_CERT_DIR}  (serves DoT :853; also signs the iOS profile)
#   console -> ${CONSOLE_CERT_DIR} (the controller TLS pair; the panel is served with it)
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
#                       console/dot service SANs. The TUI confirms the DNS
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
            # Two exact names. It was three while the panel had an origin of its
            # own; a stale count here rejects a correctly issued certificate.
            [[ "$dns_san_count" == 2 ]] || return 1
            cert_has_exact_san "$cert" "console.${base}" || return 1
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
    # -checkend only answers "does this expire soon"; it says nothing about
    # notBefore, so a certificate that is not valid YET passes it. For a
    # production cert cert_chain_trusted closes that gap already — openssl
    # verify checks the whole validity window — but the non-production path ran
    # no verification at all, so a debug leaf with a future notBefore was
    # accepted and then rejected by every client that saw it.
    #
    # A debug cert is self-signed (issue_selfsigned_wildcard uses
    # `openssl req -x509` with no CA), so it is its own trust anchor and can be
    # verified against itself. That checks the validity window without needing
    # a public anchor a self-signed cert would never chain to.
    if [[ "$trust" == production ]]; then
        cert_chain_trusted "$cert"
    else
        openssl verify -purpose sslserver -CAfile "$cert" "$cert" >/dev/null 2>&1
    fi
}

cert_provenance_load() {
    local file="${DNS_CERT_DIR}/.provenance"
    local -a lines=()
    CERT_PROVENANCE_MODE=""
    CERT_PROVENANCE_BASE=""
    CERT_PROVENANCE_LINEAGE=""
    root_plain_file_metadata_is_safe "$file" 0 640 || return 1
    mapfile -t lines < "$file" || return 1
    [[ "${#lines[@]}" == 3 \
       && "${lines[0]}" == mode=* \
       && "${lines[1]}" == base=* \
       && "${lines[2]}" == certbot_lineage=* ]] || return 1
    CERT_PROVENANCE_MODE="${lines[0]#mode=}"
    CERT_PROVENANCE_BASE="${lines[1]#base=}"
    CERT_PROVENANCE_LINEAGE="${lines[2]#certbot_lineage=}"
    is_valid_domain "$CERT_PROVENANCE_BASE" || return 1
    case "${CERT_PROVENANCE_MODE}:${CERT_PROVENANCE_LINEAGE}" in
        debug:none|cloudflare:owned|cloudflare:reused|cloudflare:missing|http-01:owned|http-01:reused|http-01:missing) ;;
        *) return 1 ;;
    esac
}

cert_provenance_get() {
    local key="$1" file="${DNS_CERT_DIR}/.provenance"
    [[ ! -e "$file" && ! -L "$file" ]] && return 0
    cert_provenance_load || return 1
    case "$key" in
        mode) printf '%s\n' "$CERT_PROVENANCE_MODE" ;;
        base) printf '%s\n' "$CERT_PROVENANCE_BASE" ;;
        certbot_lineage) printf '%s\n' "$CERT_PROVENANCE_LINEAGE" ;;
        *) return 1 ;;
    esac
}

cert_provenance_matches() {
    local mode="$1" base="$2" lineage="${3:-}"
    cert_provenance_load || return 1
    [[ "$CERT_PROVENANCE_MODE" == "$mode" \
       && "$CERT_PROVENANCE_BASE" == "$base" \
       && ( -z "$lineage" || "$CERT_PROVENANCE_LINEAGE" == "$lineage" ) ]]
}

# .provenance identifies the certificate source selected for the current role
# publication. It is not a history of Certbot lineage ownership. Returning from
# debug may select the same production lineage only when the independent
# ownership record still proves that exact base and the caller separately
# validates the live certificate and renewal configuration for the requested
# production mode.
owned_lineage_current_selection_allows_reuse() {
    local base="$1" mode="$2"
    case "$mode" in cloudflare|http-01) ;; *) return 1 ;; esac
    cert_provenance_matches "$mode" "$base" owned \
        || cert_provenance_matches "$mode" "$base" missing \
        || cert_provenance_matches debug "$base" none
}

# An external lineage is never adopted. `.provenance` describes the source
# currently copied into the role trees, so changing base or production mode does
# not require that old marker to describe the new external source. Selection is
# authorized only by the absence of exact-base ownership plus the caller's
# strict validation of the canonical lineage before and after publication.
# Ownership retained for another base is unrelated.
external_lineage_current_selection_allows_reuse() {
    local base="$1" mode="$2" provenance="${DNS_CERT_DIR}/.provenance"
    case "$mode" in cloudflare|http-01) ;; *) return 1 ;; esac
    ! certbot_lineage_owned_by_5gpn "$base" || return 1
    if [[ ! -e "$provenance" && ! -L "$provenance" ]]; then
        return 0
    fi
    cert_provenance_load
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

revoke_certbot_lineage_ownership() {
    local base="$1" tmp
    local -a retained=()
    is_valid_domain "$base" || return 1
    certbot_ownership_record_is_safe || return 1
    certbot_ownership_record_has "$base" || return 0
    mapfile -t retained < <(sed -n 's/^owned=//p' "$CERTBOT_OWNERSHIP_FILE" \
        | grep -Fvx -- "$base" || true)
    if [[ "${#retained[@]}" == 0 ]]; then
        rm -f -- "$CERTBOT_OWNERSHIP_FILE" || return 1
        sync -f "$DNS_CERT_DIR" 2>/dev/null \
            || { err "Certbot ownership removal became visible but its durability was not confirmed."; return 1; }
        [[ ! -e "$CERTBOT_OWNERSHIP_FILE" && ! -L "$CERTBOT_OWNERSHIP_FILE" ]]
        return
    fi
    tmp="$(mktemp "${DNS_CERT_DIR}/.certbot-ownership.revoke.XXXXXX")" || return 1
    {
        printf 'version=1\n'
        printf '%s\n' "${retained[@]}" | sort -u | sed 's/^/owned=/'
    } > "$tmp" \
        && chown root:root "$tmp" \
        && chmod 0640 "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$tmp" 2>/dev/null \
        || { rm -f -- "$tmp"; err "Could not durably write the reduced Certbot ownership record."; return 1; }
    mv -f -- "$tmp" "$CERTBOT_OWNERSHIP_FILE" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$DNS_CERT_DIR" 2>/dev/null \
        || { err "Could not durably publish the reduced Certbot ownership record."; return 1; }
    if ! certbot_ownership_record_is_safe \
       || certbot_ownership_record_has "$base"; then
        err "Could not revoke Certbot lineage ownership for ${base}."
        return 1
    fi
}

certbot_lineage_owned_by_5gpn() {
    local base="$1"
    [[ -e "$CERTBOT_OWNERSHIP_FILE" || -L "$CERTBOT_OWNERSHIP_FILE" ]] \
        && certbot_ownership_record_has "$base"
}

certificate_selection_state_is_safe() {
    if [[ -e "$CERTBOT_OWNERSHIP_FILE" || -L "$CERTBOT_OWNERSHIP_FILE" ]]; then
        certbot_ownership_record_is_safe \
            || { err "The retained Certbot ownership record is unsafe."; return 1; }
    fi
    if [[ -e "$DNS_CERT_DIR/.provenance" || -L "$DNS_CERT_DIR/.provenance" ]]; then
        cert_provenance_load \
            || { err "The current certificate provenance marker is unsafe."; return 1; }
    fi
}

certificate_selection_state_is_consistent_for_install() {
    local base="$1" mode="$2" provenance="${DNS_CERT_DIR}/.provenance"
    is_valid_domain "$base" || return 1
    case "$mode" in cloudflare|http-01|debug) ;; *) return 1 ;; esac
    certificate_selection_state_is_safe || return 1
    [[ -e "$provenance" || -L "$provenance" ]] || return 0
    cert_provenance_load || return 1
    [[ "$CERT_PROVENANCE_BASE" == "$base" ]] || return 0
    case "$CERT_PROVENANCE_LINEAGE" in
        owned)
            certbot_lineage_owned_by_5gpn "$base" \
                || { err "Current certificate provenance claims owned without matching Certbot ownership for ${base}."; return 1; } ;;
        reused)
            ! certbot_lineage_owned_by_5gpn "$base" \
                || { err "Current certificate provenance claims external while Certbot ownership names ${base}."; return 1; } ;;
        none|missing) ;;
        *) return 1 ;;
    esac
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

read_global_certbot_timer_state() {
    read_exact_systemd_unit_state certbot.timer || return 1
    CERTBOT_TIMER_LOAD_STATE="$SYSTEMD_UNIT_LOAD_STATE"
    CERTBOT_TIMER_ACTIVE_STATE="$SYSTEMD_UNIT_ACTIVE_STATE"
    CERTBOT_TIMER_UNIT_FILE_STATE="$SYSTEMD_UNIT_FILE_STATE"
}

global_certbot_timer_matches_expected_state() {
    read_global_certbot_timer_state || return 1
    [[ "$CERTBOT_TIMER_LOAD_STATE" == "$GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD" \
       && "$CERTBOT_TIMER_ACTIVE_STATE" == "$GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE" \
       && "$CERTBOT_TIMER_UNIT_FILE_STATE" == "$GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED" ]]
}

certbot_timer_state_is_round_trippable() {
    [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded ]] || return 1
    case "$CERTBOT_TIMER_ACTIVE_STATE" in active|inactive) ;; *) return 1 ;; esac
    case "$CERTBOT_TIMER_UNIT_FILE_STATE" in enabled|disabled) ;; *) return 1 ;; esac
}

certbot_service_is_quiescent() {
    read_exact_systemd_unit_state certbot.service \
        || { err "Could not read certbot.service state exactly."; return 1; }
    case "$SYSTEMD_UNIT_LOAD_STATE:$SYSTEMD_UNIT_ACTIVE_STATE" in
        not-found:not-found|loaded:inactive) return 0 ;;
        *)
            err "certbot.service is not quiescent (LoadState=${SYSTEMD_UNIT_LOAD_STATE}, ActiveState=${SYSTEMD_UNIT_ACTIVE_STATE})."
            return 1
            ;;
    esac
}

preflight_global_certbot_timer_state() {
    read_global_certbot_timer_state \
        || { err "Could not inspect the distro certbot.timer before publication."; return 1; }
    case "$CERTBOT_TIMER_LOAD_STATE" in
        not-found) ;;
        loaded)
            certbot_timer_state_is_round_trippable \
                || { err "The distro certbot.timer is not safely round-trippable before publication."; return 1; }
            ;;
        *) return 1 ;;
    esac
    certbot_service_is_quiescent
}

# Stop the distro-wide unscoped timer before mutating an owned lineage or
# issuing a new one. External lineages are consumed read-only and debug mode
# never enters this transaction. Capture both activity and enablement before the
# first change so every transaction exit can restore the exact external state
# unless owned renewal automation commits a takeover.
pause_global_certbot_timer() {
    local first_load first_active first_unit_file
    read_global_certbot_timer_state \
        || { err "Could not read the distro certbot.timer state exactly."; return 1; }
    if [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 1 ]]; then
        [[ "$CERTBOT_TIMER_LOAD_STATE" == "$GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD" \
           && "$CERTBOT_TIMER_ACTIVE_STATE" == "$GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE" \
           && "$CERTBOT_TIMER_UNIT_FILE_STATE" == "$GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED" ]] \
            || { err "The captured distro certbot.timer changed after its installer transition."; return 1; }
        certbot_service_is_quiescent \
            || { err "Wait for the external Certbot operation to finish, then rerun the installer."; return 1; }
        return 0
    fi
    if [[ "$CERTBOT_TIMER_LOAD_STATE" == not-found ]]; then
        GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE=not-found
        GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED=not-found
        GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=not-found
        GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE=not-found
        GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED=not-found
        GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=1
        certbot_service_is_quiescent \
            || { clear_global_certbot_timer_snapshot; err "Wait for the external Certbot operation to finish, then rerun the installer."; return 1; }
        return 0
    fi
    if [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded ]]; then
        certbot_timer_state_is_round_trippable \
            || { err "The distro certbot.timer is not in a safely round-trippable state."; return 1; }
        first_load="$CERTBOT_TIMER_LOAD_STATE"
        first_active="$CERTBOT_TIMER_ACTIVE_STATE"
        first_unit_file="$CERTBOT_TIMER_UNIT_FILE_STATE"
        read_global_certbot_timer_state \
            || { err "Could not re-read the distro certbot.timer state exactly."; return 1; }
        [[ "$CERTBOT_TIMER_LOAD_STATE" == "$first_load" \
           && "$CERTBOT_TIMER_ACTIVE_STATE" == "$first_active" \
           && "$CERTBOT_TIMER_UNIT_FILE_STATE" == "$first_unit_file" ]] \
            || { err "The distro certbot.timer changed while its reversible state was being captured."; return 1; }
        GLOBAL_CERTBOT_TIMER_ORIGINAL_ACTIVE="$first_active"
        GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED="$first_unit_file"
        GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=loaded
        GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE="$first_active"
        GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED="$first_unit_file"
        GLOBAL_CERTBOT_TIMER_STATE_CAPTURED=1
        if ! systemctl stop certbot.timer; then
            if read_global_certbot_timer_state \
               && [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded \
                  && "$CERTBOT_TIMER_UNIT_FILE_STATE" == "$first_unit_file" \
                  && ( "$CERTBOT_TIMER_ACTIVE_STATE" == active \
                       || "$CERTBOT_TIMER_ACTIVE_STATE" == inactive ) ]]; then
                GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE="$CERTBOT_TIMER_ACTIVE_STATE"
            fi
            err "Could not stop the distro certbot.timer before the certificate transaction."
            return 1
        fi
        read_global_certbot_timer_state \
            || { err "Could not verify the distro certbot.timer after stop."; return 1; }
        [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded \
           && "$CERTBOT_TIMER_ACTIVE_STATE" == inactive \
           && "$CERTBOT_TIMER_UNIT_FILE_STATE" == "$first_unit_file" ]] \
            || { err "The distro certbot.timer did not enter the exact paused state."; return 1; }
        GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=loaded
        GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE=inactive
        GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED="$first_unit_file"
    else
        err "The distro certbot.timer load state is unsupported."
        return 1
    fi
    certbot_service_is_quiescent \
        || { err "Wait for the external Certbot operation to finish, then rerun the installer."; return 1; }
}

# A canonical lineage without an ownership record is external. Reading it does
# not authorize stopping the distro timer. Owned lineages and an absent
# canonical lineage may need Certbot mutation, so those paths take the reversible
# timer snapshot before publication and re-check it inside install_cert.
certbot_transaction_requires_global_timer_pause() {
    local base="$1" mode="${2:-${CERT_MODE:-}}"
    case "$mode" in
        debug) return 1 ;;
        cloudflare|http-01) ;;
        *) return 1 ;;
    esac
    if certbot_lineage_artifacts_exist "$base" \
       && ! certbot_lineage_owned_by_5gpn "$base"; then
        return 1
    fi
    return 0
}

# The distro timer invokes an unscoped `certbot renew`. It can be disabled only
# when every visible Certbot lineage belongs to this exact 5gpn base; otherwise
# disabling it would silently break renewal for unrelated services.
certbot_lineage_set_is_exclusive() {
    local base="$1" root entry name expected listing
    local -a roots=("$LE_LIVE_ROOT" "$LE_ARCHIVE_ROOT" "$LE_RENEWAL_ROOT")
    for root in "${roots[@]}"; do
        [[ ! -e "$root" && ! -L "$root" ]] && continue
        [[ -d "$root" && ! -L "$root" \
           && "$(readlink -f -- "$root" 2>/dev/null || true)" == "$root" ]] \
            || { err "Unsafe Certbot lineage root: $root"; return 1; }
        listing="$(mktemp /tmp/5gpn-certbot-lineages.XXXXXX)" || return 1
        chmod 0600 "$listing" || { rm -f -- "$listing"; return 1; }
        if ! find "$root" -mindepth 1 -maxdepth 1 -print0 > "$listing" 2>/dev/null; then
            rm -f -- "$listing"
            err "Could not enumerate Certbot lineage state: $root"
            return 1
        fi
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
                rm -f -- "$listing"
                return 1
            fi
        done < "$listing"
        rm -f -- "$listing" || return 1
    done
}

disable_global_certbot_timer_for_owned_lineage() {
    local base="$1"
    read_global_certbot_timer_state \
        || { err "Could not read the distro certbot.timer before takeover."; return 1; }
    if [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 1 ]]; then
        if [[ "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" == not-found ]]; then
            [[ "$CERTBOT_TIMER_LOAD_STATE" == not-found ]] \
                || { err "A distro certbot.timer appeared after absence was captured."; return 1; }
            return 0
        fi
        [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded \
           && "$CERTBOT_TIMER_ACTIVE_STATE" == inactive \
           && "$CERTBOT_TIMER_UNIT_FILE_STATE" == "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" ]] \
            || { err "The captured distro certbot.timer changed or disappeared before takeover."; return 1; }
        certbot_lineage_set_is_exclusive "$base" || return 1
        read_global_certbot_timer_state \
            || { err "Could not re-read the distro certbot.timer before takeover."; return 1; }
        [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded \
           && "$CERTBOT_TIMER_ACTIVE_STATE" == inactive \
           && "$CERTBOT_TIMER_UNIT_FILE_STATE" == "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" ]] \
            || { err "The distro certbot.timer changed after pause; refusing irreversible takeover."; return 1; }
        systemctl disable --now certbot.timer \
            || { err "Could not disable the unscoped distro certbot.timer."; return 1; }
        read_global_certbot_timer_state \
            || { err "Could not verify the distro certbot.timer after disable."; return 1; }
        [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded \
           && "$CERTBOT_TIMER_ACTIVE_STATE" == inactive \
           && "$CERTBOT_TIMER_UNIT_FILE_STATE" == disabled ]] \
            || { err "The distro certbot.timer did not enter the exact disabled state."; return 1; }
        GLOBAL_CERTBOT_TIMER_EXPECTED_LOAD=loaded
        GLOBAL_CERTBOT_TIMER_EXPECTED_ACTIVE=inactive
        GLOBAL_CERTBOT_TIMER_EXPECTED_ENABLED=disabled
    else
        [[ "$CERTBOT_TIMER_LOAD_STATE" == not-found ]] \
            || { err "A distro certbot.timer appeared without a reversible snapshot."; return 1; }
    fi
    return 0
}

global_certbot_timer_takeover_state_is_stable() {
    read_global_certbot_timer_state \
        || { err "Could not verify the distro certbot.timer before renewal commit."; return 1; }
    if [[ "$GLOBAL_CERTBOT_TIMER_STATE_CAPTURED" == 1 ]]; then
        if [[ "$GLOBAL_CERTBOT_TIMER_ORIGINAL_ENABLED" == not-found ]]; then
            [[ "$CERTBOT_TIMER_LOAD_STATE" == not-found ]] \
                || { err "A distro certbot.timer appeared before renewal commit."; return 1; }
            return 0
        fi
        [[ "$CERTBOT_TIMER_LOAD_STATE" == loaded \
           && "$CERTBOT_TIMER_ACTIVE_STATE" == inactive \
           && "$CERTBOT_TIMER_UNIT_FILE_STATE" == disabled ]] \
            || { err "The captured distro certbot.timer changed before renewal commit."; return 1; }
    else
        [[ "$CERTBOT_TIMER_LOAD_STATE" == not-found ]] \
            || { err "A distro certbot.timer appeared before renewal commit."; return 1; }
    fi
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
    local base="$1" mode="$2" auth value
    local conf="${LE_RENEWAL_ROOT}/${base}.conf"
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
    local base="$1" conf current_mode current_base current_lineage
    conf="${LE_RENEWAL_ROOT}/${base}.conf"
    DECOMMISSION_PRESERVE_ACME=0
    is_valid_domain "$base" \
        || { err "Cannot decommission: persisted base domain is invalid."; return 1; }
    if [[ ( -e "$CERTBOT_OWNERSHIP_FILE" || -L "$CERTBOT_OWNERSHIP_FILE" ) ]] \
       && ! certbot_ownership_record_is_safe; then
        warn "Preserving Certbot lineage '${base}': the retained ownership record is unsafe and cannot authorize deletion."
        if grep -qF -- "$ACME_DIR/cloudflare.ini" "$conf" 2>/dev/null; then
            DECOMMISSION_PRESERVE_ACME=1
        fi
        return 0
    fi
    if ! certbot_lineage_artifacts_exist "$base"; then
        if certbot_lineage_owned_by_5gpn "$base"; then
            current_mode="$(cert_provenance_get mode)" || return 1
            current_base="$(cert_provenance_get base)" || return 1
            if [[ "$current_base" == "$base" \
               && ( "$current_mode" == cloudflare || "$current_mode" == http-01 ) ]]; then
                write_cert_provenance "$current_mode" "$base" missing \
                    || { err "Could not withdraw stale owned renewal provenance for '${base}'."; return 1; }
            fi
            revoke_certbot_lineage_ownership "$base" \
                || { err "Lineage '${base}' is already absent, but its stale ownership authority could not be revoked."; return 1; }
        fi
        info "No Certbot lineage artifacts exist for '${base}'."
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
    current_mode="$(cert_provenance_get mode)" || return 1
    current_lineage="$(cert_provenance_get certbot_lineage)" || return 1
    # Withdraw renewal authorization before removing deletion ownership. A
    # crash between these two durable writes is reported as a source/ownership
    # conflict, never as healthy renewal. Debug and missing role selections
    # already carry no renewal authorization and remain unchanged.
    if [[ "$current_lineage" == owned \
       && ( "$current_mode" == cloudflare || "$current_mode" == http-01 ) ]]; then
        write_cert_provenance "$current_mode" "$base" reused \
            || { err "Could not withdraw owned renewal provenance for '${base}'."; return 1; }
    fi
    # Revoke durable deletion authority before the destructive external call.
    # A crash or Certbot failure after this boundary leaves the lineage present
    # but read-only/external. Do not roll either withdrawal back.
    revoke_certbot_lineage_ownership "$base" \
        || { err "Could not revoke ownership for '${base}' before Certbot deletion."; return 1; }
    certbot delete --non-interactive --cert-name "$base" \
        || { err "Certbot refused to delete '${base}'; its ownership was already revoked and was not rolled back."; return 1; }
    ok "Deleted the provenance-confirmed 5gpn Certbot lineage '${base}'."
}

# Ownership of the fixed deploy-hook path is its id marker alone. The rest of
# the file is scripts/renew-hook.sh, whose text changes between releases, so
# matching it here would reject every host still running the previous one.
renew_hook_owned() {
    local hook="/etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh"
    [[ -f "$hook" && ! -L "$hook" ]] || return 1
    grep -Fqx '# 5gpn-renew-hook-id: deploy-v1' "$hook"
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
    local src="${SCRIPT_DIR}/scripts/renew-hook.sh" source_path before after
    local hash_fd source_fd hash_metadata source_metadata fd_digest anchored=0
    if [[ "$SCRIPT_DIR" == "$BASE_DIR" ]]; then
        source_path="${SCRIPTS_DIR}/renew-hook.sh"
        before="$(installed_runtime_script_state "$source_path")" \
            || { err "Installed renew-hook.sh metadata is unsafe."; return 1; }
        exec {hash_fd}<"$source_path" || return 1
        exec {source_fd}<"$source_path" || { exec {hash_fd}<&-; return 1; }
        hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
            || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
        source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
            || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
        [[ "$hash_metadata" == "${before%:*}" && "$source_metadata" == "${before%:*}" ]] \
            || { exec {hash_fd}<&-; exec {source_fd}<&-; err "Installed renew-hook.sh changed while it was anchored."; return 1; }
        fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
            || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
        exec {hash_fd}<&-
        [[ "$fd_digest" == "${before##*:}" ]] \
            || { exec {source_fd}<&-; err "Installed renew-hook.sh bytes differ from its anchored path."; return 1; }
        src="/proc/self/fd/$source_fd"
        anchored=1
    else
        [[ -f "$src" && ! -L "$src" && "$(file_nlink "$src")" == 1 ]] \
            || { err "scripts/renew-hook.sh not found or unsafe; refusing production certificate setup without a deploy hook."; return 1; }
    fi
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy \
        || { [[ "$anchored" == 0 ]] || exec {source_fd}<&-; return 1; }
    if [[ -e /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh ]] \
       && ! renew_hook_owned; then
        [[ "$anchored" == 0 ]] || exec {source_fd}<&-
        err "Refusing to overwrite an unowned Certbot deploy hook: /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh"
        return 1
    fi
    install -m 0755 "$src" /etc/letsencrypt/renewal-hooks/deploy/99-5gpn.sh \
        || { [[ "$anchored" == 0 ]] || exec {source_fd}<&-; return 1; }
    if [[ "$anchored" == 1 ]]; then
        exec {source_fd}<&-
        after="$(installed_runtime_script_state "$source_path")" \
            || { err "Could not revalidate installed renew-hook.sh after publication."; return 1; }
        [[ "$after" == "$before" ]] \
            || { err "Installed renew-hook.sh changed during deploy-hook publication."; return 1; }
    fi
    ok "Renewal deploy hook installed (validated dot/console publication + iOS re-sign)."
}

# Certbot standalone must own public TCP :80. Run in a subshell so its signal
# traps cannot replace the full install transaction's ERR/EXIT failure-reporting
# and cleanup traps.
# Full install stops only a service that was active and restores it on failure.
# Installed configure instead arrives with the start half of one PID1-owned
# try-restart job blocked in ExecStartPre; this helper never starts or stops that
# runtime. The outer configure transaction releases that exact job once, after
# every selected document and profile generation passes final validation. An
# unrelated process occupying :80 is never killed and makes Certbot fail closed.
run_http_certbot() (
    local restore=0 certbot_rc=0 restore_rc=0
    local externally_quiesced="${FIVEGPN_HTTP_CERTBOT_RUNTIME_FENCED:-0}"
    restore_active_mihomo() {
        [[ "$restore" == 1 ]] || return 0
        restore=0
        systemctl start 5gpn-mihomo.service \
            && ok "5gpn-mihomo restored after the HTTP-01 challenge." \
            || { err "Could not restore 5gpn-mihomo after the HTTP-01 challenge."; return 1; }
    }
    trap 'restore_active_mihomo || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$externally_quiesced" == 1 ]]; then
        configure_assert_runtime_gate_quiescent \
            || { err "HTTP-01 configure requires its PID1-owned restart gate."; exit 1; }
    elif systemctl is-active --quiet 5gpn-mihomo.service 2>/dev/null; then
        info "Temporarily stopping 5gpn-mihomo to release TCP :80 for HTTP-01."
        restore=1
        systemctl stop 5gpn-mihomo.service \
            || { err "Could not stop 5gpn-mihomo; refusing to run Certbot while :80 may be occupied."; exit 1; }
    fi
    certbot "$@" || certbot_rc=$?
    if [[ "$certbot_rc" == 0 ]]; then
        # Full install and installed configure both leave a successful
        # challenge quiescent for their outer verified publication boundary.
        restore=0
    else
        restore_active_mihomo || restore_rc=$?
    fi
    # Keep INT/TERM armed until the subshell itself returns. Bash may defer a
    # signal delivered as Certbot exits; clearing those traps here creates a
    # narrow window in which a real operator interrupt is reported as success.
    trap - EXIT
    [[ "$certbot_rc" == 0 ]] || exit "$certbot_rc"
    [[ "$restore_rc" == 0 ]] || exit "$restore_rc"
)

deployed_cert_roles_match_source() {
    local source="$1" role target_before target_after
    [[ -s "$source/fullchain.pem" && -s "$source/privkey.pem" ]] || return 1
    load_cert_role_helpers || return 1
    cert_role_ctl_validate_current || return 1
    for role in dot console; do
        target_before="$(cert_role_ctl_current_target "$role" 0)" || return 1
        cmp -s -- "$source/fullchain.pem" "$DNS_CERT_DIR/$role/$target_before/fullchain.pem" \
            || return 1
        cmp -s -- "$source/privkey.pem" "$DNS_CERT_DIR/$role/$target_before/privkey.pem" \
            || return 1
        target_after="$(cert_role_ctl_current_target "$role" 0)" || return 1
        [[ "$target_after" == "$target_before" ]] || return 1
    done
}

install_cert() {
    local base="${1:?install_cert needs a base domain}"
    local mode="$CERT_MODE"
    local live="${LE_LIVE_ROOT}/${base}"
    local lineage_origin="" lineage_artifacts=0 lineage_was_owned=0
    local force=0 cf_token_ready=0 external_deploy_attempt external_deploy_matched=0
    certificate_selection_state_is_safe || return 1
    certbot_lineage_owned_by_5gpn "$base" && lineage_was_owned=1
    certbot_lineage_artifacts_exist "$base" && lineage_artifacts=1
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=0

    [[ "$mode" == cloudflare || "$mode" == http-01 || "$mode" == debug ]] \
        || { err "CERT_MODE must be cloudflare, http-01, or debug."; return 1; }

    if [ "$mode" = "debug" ]; then
        local debug_src="${DEBUG_CERT_DIR}/${base}"
        if cert_provenance_matches debug "$base" none \
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
        disable_scoped_renewal_timer || return 1
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
           && external_lineage_current_selection_allows_reuse "$base" "$mode"; then
            info "Reusing the valid externally owned ${mode} lineage for ${base} without changing it."
            # Install the audited hook before taking the role snapshot. A
            # renewal that completes after this point either runs that hook or
            # is detected by the exact live-to-current comparison below. One
            # bounded retry converges when an already-running renewal crosses
            # the first snapshot.
            install_cert_deploy_hook || return 1
            certbot_service_is_quiescent \
                || { err "An external Certbot operation predates the deploy hook; wait for it to finish and rerun."; return 1; }
            for external_deploy_attempt in 1 2; do
                deploy_cert_roles "$base" "$live" "$mode" || return 1
                if validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
                        "$base" "$((30*86400))" production "$mode" \
                   && certbot_renewal_mode_matches "$base" "$mode" \
                   && deployed_cert_roles_match_source "$live"; then
                    external_deploy_matched=1
                    break
                fi
                warn "The external lineage changed across role publication; retrying one fresh immutable snapshot."
            done
            [[ "$external_deploy_matched" == 1 ]] \
                || { err "The external Certbot lineage did not stabilize against the deployed role copies."; return 1; }
            write_cert_provenance "$mode" "$base" reused || return 1
            disable_scoped_renewal_timer || return 1
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
        disable_scoped_renewal_timer || return 1
        warn "The preserved certificate is active, but automatic renewal is disabled until the Certbot lineage is repaired or reissued."
        return 0
    fi

    # Reuse is mode-aware. The SAN shape distinguishes wildcard DNS-01 from
    # exact-name HTTP-01; renewal.conf and owned provenance prevent a mode
    # switch from silently retaining the previous authenticator.
    #
    # Each condition is evaluated separately so that declining to reuse can say
    # which one declined. Collapsed into a single &&-chain it could not: the
    # installer went quiet and then certbot ran, and because an existing lineage
    # also sets --force-renewal below, "I already have a certificate" turned
    # into a full re-issuance — including the propagation wait — with nothing
    # said about why.
    local reuse_declined=""
    if [[ "$lineage_was_owned" != 1 ]]; then
        reuse_declined="the lineage is not one this installer owns"
    elif ! validate_cert_pair "${live}/fullchain.pem" "${live}/privkey.pem" \
            "$base" "$((30*86400))" production "$mode"; then
        reuse_declined="the certificate is missing, untrusted, wrong for ${mode}, or expires within 30 days"
    elif ! certbot_renewal_mode_matches "$base" "$mode"; then
        reuse_declined="its renewal configuration does not use the ${mode} authenticator"
    elif ! owned_lineage_current_selection_allows_reuse "$base" "$mode"; then
        reuse_declined="the current certificate selection does not authorize this owned ${mode} lineage"
    fi

    if [[ "$lineage_was_owned" == 1 ]] \
       && cert_provenance_matches "$mode" "$base" reused; then
        err "The Certbot ownership record conflicts with the current ${mode} certificate source for ${base}."
        err "Refusing to mutate or adopt the canonical lineage until the current ownership state is repaired."
        return 1
    fi

    # External and debug paths returned above. Only owned reuse or a possible
    # new issuance may coordinate and take over the distro Certbot timer.
    pause_global_certbot_timer || return 1
    disable_global_certbot_timer_for_owned_lineage "$base" || return 1

    if [[ -z "$reuse_declined" ]]; then
        lineage_origin=owned
        info "Valid owned ${mode} certificate and matching renewal authenticator for ${base} (>30d); reusing."
    else
        info "Not reusing the existing certificate for ${base}: ${reuse_declined}."
        if [[ ! -e "$live" ]] && compgen -G "${LE_LIVE_ROOT}/${base}-[0-9][0-9][0-9][0-9]" >/dev/null; then
            err "A duplicate Certbot lineage exists for ${base}, but the canonical ${live} lineage is absent."
            err "Resolve that lineage explicitly before reinstalling; refusing silent reuse without scoped renewal."
            return 1
        fi
        # An existing lineage is re-issued rather than renewed in place,
        # because certbot otherwise refuses a changed SAN set under the same
        # cert-name. This is why declining to reuse is expensive, and why the
        # reason above is worth printing.
        [[ -e "$live" ]] && force=1
        local -a certbot_args=(certonly --cert-name "$base" --server "$LE_PRODUCTION_SERVER" --agree-tos -n \
            -m "${CERT_EMAIL:-admin@${base}}" --keep-until-expiring --no-directory-hooks)
        if [[ "$mode" == cloudflare ]]; then
            ensure_cf_token || return 1
            cf_token_ready=1
            info "Issuing Let's Encrypt WILDCARD cert for *.${base} (Cloudflare DNS-01; propagation wait is at least 30s)..."
            certbot_args+=(--dns-cloudflare \
                --dns-cloudflare-credentials "${ACME_DIR}/cloudflare.ini" \
                --dns-cloudflare-propagation-seconds "$CERT_DNS_PROPAGATION_SECONDS" -d "*.${base}" -d "${base}")
        else
            check_http_challenge_dns_once \
                || { err "HTTP-01 DNS changed after preflight: ${CERT_DNS_LAST_OBSERVATION:-no answer}."; return 1; }
            info "Issuing Let's Encrypt cert for ${CONSOLE_DOMAIN}, ${DOT_DOMAIN} (HTTP-01 / :80)..."
            certbot_args+=(--standalone --preferred-challenges http-01 \
                -d "$CONSOLE_DOMAIN" -d "$DOT_DOMAIN")
        fi
        # Non-interactive Certbot otherwise refuses a changed SAN set when the
        # same cert-name switches between wildcard DNS-01 and exact HTTP-01.
        [[ "$force" == 1 ]] && certbot_args+=(--force-renewal --renew-with-new-domains)
        if [[ "$mode" == http-01 ]]; then
            FIVEGPN_CERT_LOCK_HELD=1 FIVEGPN_SKIP_PROFILE_REFRESH=1 \
                run_http_certbot "${certbot_args[@]}" \
                || { err "Certbot HTTP-01 failed. Check both public A records, absence of AAAA, TCP/80/NAT/security-group reachability, and rate limits."; return 1; }
        else
            FIVEGPN_CERT_LOCK_HELD=1 FIVEGPN_SKIP_PROFILE_REFRESH=1 \
                certbot "${certbot_args[@]}" \
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
    disable_scoped_renewal_timer
}

# deploy_cert_roles <base> [src_dir] [mode] — copy the selected cert to the two
# current role dirs. Defaults to reading from the Certbot lineage; a preserved
# role copy or debug mode may pass an alternate source directory explicitly.
deploy_cert_roles() {
    local base="$1" mode="${3:-${CERT_MODE:-cloudflare}}"
    local src="${2:-${LE_LIVE_ROOT}/${base}}"
    local trust=production rc=0
    [[ "$src" == "$DEBUG_CERT_DIR"/* ]] && { trust=debug; mode=debug; }
    validate_cert_pair "${src}/fullchain.pem" "${src}/privkey.pem" "$base" 0 "$trust" "$mode" \
        || { err "Certificate source failed validation: $src"; return 1; }
    ensure_dns_cert_root || return 1
    load_cert_role_helpers || return 1
    CERT_ROLE_CTL_ALLOW_CREATE=1
    if [[ "$DNS_CERT_DIR" == /etc/5gpn/cert ]]; then
        CERT_ROLE_CTL_STAGE_PARENT=/run/5gpn
        CERT_ROLE_CTL_LINEAGE_LIVE_ROOT="$LE_LIVE_ROOT"
        CERT_ROLE_CTL_LINEAGE_ARCHIVE_ROOT="$LE_ARCHIVE_ROOT"
    else
        CERT_ROLE_CTL_STAGE_PARENT="$(dirname -- "$DNS_CERT_DIR")/.cert-role-staging"
        CERT_ROLE_CTL_LINEAGE_LIVE_ROOT="$LE_LIVE_ROOT"
        CERT_ROLE_CTL_LINEAGE_ARCHIVE_ROOT="$LE_ARCHIVE_ROOT"
    fi
    CERT_ROLE_DEPLOY_BASE="$base"
    CERT_ROLE_DEPLOY_MODE="$mode"
    CERT_ROLE_DEPLOY_TRUST="$trust"
    if [[ "$src" == "$LE_LIVE_ROOT/$base" ]]; then
        cert_role_ctl_deploy_lineage "$src" "$base" cert_role_install_validate_candidate || rc=$?
    else
        cert_role_ctl_publish_pair "$src/fullchain.pem" "$src/privkey.pem" \
            cert_role_install_validate_candidate || rc=$?
    fi
    if [[ "$rc" != 0 ]]; then
        case "$CERT_ROLE_CTL_COMMIT_STATE" in
            committed-undurable)
                err "Certificate role current changed, but durability was not confirmed; no rollback was attempted." ;;
            committed-partial|committed)
                err "Certificate role publication crossed its commit boundary and remains partial; no rollback was attempted." ;;
            *) err "Certificate role publication failed before any current pointer changed." ;;
        esac
        [[ -z "$CERT_ROLE_CTL_LAST_ERROR" ]] || err "$CERT_ROLE_CTL_LAST_ERROR"
        return "$rc"
    fi
    cert_role_ctl_validate_current \
        || { err "Published certificate role current generations failed validation."; return 1; }
    [[ "$CERT_ROLE_CTL_GC_WARNING" == 0 ]] \
        || warn "Certificate roles are active, but an old unreferenced generation or private source snapshot was retained."
    ok "${mode} certificate for ${base} deployed to dot/console role dirs."
}

cert_role_install_validate_candidate() {
    validate_cert_pair "$1" "$2" "$CERT_ROLE_DEPLOY_BASE" 0 \
        "$CERT_ROLE_DEPLOY_TRUST" "$CERT_ROLE_DEPLOY_MODE"
}

# install_renewal_automation installs a daily systemd timer running only the
# mode-aware public-certificate helper. The independent static
# 5gpn-intercept-cert.timer always owns interception-leaf expiry checks.
# The public helper checks the exact cert-name and due window; Cloudflare renews
# without interruption, while HTTP-01 first validates DNS via 1.1.1.1 and safely
# releases/restores mihomo's TCP :80 listeners.
install_renewal_automation() {
    local base="${1:?install_renewal_automation needs a base domain}"
    certbot_lineage_owned_by_5gpn "$base" \
        || { err "Refusing to install project renewal automation for a non-owned Certbot lineage."; return 1; }
    [[ -x "${SCRIPTS_DIR}/cert-renew.sh" ]] \
        || { err "Scoped renewal helper is missing: ${SCRIPTS_DIR}/cert-renew.sh"; return 1; }
    current_managed_unit_file_is_safe 5gpn-certbot-renew.service \
        && current_managed_unit_file_is_safe 5gpn-certbot-renew.timer \
        || { err "Scoped renewal units were not published through the managed unit transaction."; return 1; }
    systemctl daemon-reload \
        || { err "Could not reload systemd before enabling scoped certificate renewal."; return 1; }
    global_certbot_timer_takeover_state_is_stable || return 1
    systemctl enable --now 5gpn-certbot-renew.timer \
        || { err "Could not enable/start scoped certificate renewal timer."; return 1; }
    if ! read_exact_systemd_unit_state 5gpn-certbot-renew.timer \
       || [[ "$SYSTEMD_UNIT_LOAD_STATE" != loaded \
          || "$SYSTEMD_UNIT_ACTIVE_STATE" != active \
          || "$SYSTEMD_UNIT_FILE_STATE" != enabled ]]; then
        err "Scoped certificate renewal timer did not enter loaded/active/enabled state."
        disable_scoped_renewal_timer || true
        return 1
    fi
    if ! global_certbot_timer_takeover_state_is_stable; then
        disable_scoped_renewal_timer || true
        return 1
    fi
    KEEP_GLOBAL_CERTBOT_TIMER_DISABLED=1
    ok "Enabled 5gpn-certbot-renew.timer (daily, Persistent, mode-aware scoped renewal)."
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

# Decide whether a confirmed full-install candidate must obtain a Cloudflare
# credential before project publication. A canonical external lineage remains
# read-only and keeps its owner's renewal mechanism, so asking for a token would
# falsely imply 5gpn needs or gains authority over it. An absent lineage or one
# already provenance-confirmed as 5gpn-owned does require the credential for
# issuance or scoped renewal.
cloudflare_credential_required_for_install() {
    local base="$1"
    [[ "$CERT_MODE" == cloudflare ]] || return 1
    if certbot_lineage_artifacts_exist "$base"; then
        certbot_lineage_owned_by_5gpn "$base"
        return $?
    fi
    if cert_provenance_matches cloudflare "$base" \
       && validate_cert_pair \
            "${DOT_CERT_DIR}/current/fullchain.pem" \
            "${DOT_CERT_DIR}/current/privkey.pem" \
            "$base" "$((30*86400))" production cloudflare; then
        # Purge may preserve a still-valid role pair after the canonical
        # lineage disappears. install_cert consumes that pair read-only and
        # leaves renewal disabled, so collecting a token would grant and retain
        # a credential no operation will use.
        return 1
    fi
    return 0
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
# systemd units, iOS profile
# ----------------------------------------------------------------------------
preflight_unit_ownership() {
    local managed_unit
    for managed_unit in "${MANAGED_SYSTEMD_UNITS[@]}"; do
        preflight_current_managed_unit_definition "$managed_unit" || return 1
        if systemd_unit_has_dropins "$managed_unit"; then
            err "Refusing a systemd override that changes the managed ${managed_unit} security contract.${SYSTEMD_UNIT_CONFLICT_REASON:+ ($SYSTEMD_UNIT_CONFLICT_REASON)}"
            return 1
        fi
    done
}

install_units() {
    info "Installing six managed systemd units..."
    # Prefer the repo checkout; fall back to the staged copies under /opt/5gpn
    # (a piped curl|bash install has no checkout after install_files staged them).
    local src u
    for u in "${MANAGED_SYSTEMD_UNITS[@]}"; do
        preflight_current_managed_unit_definition "$u" || return 1
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
        mv -f -- "$candidate" "/etc/systemd/system/${u}" || return 1
        current_managed_unit_file_is_safe "$u" \
            || { err "Published managed unit failed its ownership marker boundary: $u"; return 1; }
    done
    systemctl daemon-reload \
        || { err "Could not reload systemd after managed unit publication."; return 1; }
    ok "All six managed 5gpn units were installed and verified."
}

prepare_runtime_permissions() {
    local path role
    local node_lock="${MIHOMO_DIR}/config.yaml.5gpn-nodes.lock"
    local node_backup="${MIHOMO_DIR}/config.yaml.5gpn-nodes.bak"
    preflight_runtime_publication_paths || return 1
    install -d -o root -g root -m 0755 "$CONF_DIR" || return 1
    chmod g-s "$CONF_DIR" || return 1
    if [[ -f "${CONF_DIR}/dns.env" ]]; then
        chown root:root "${CONF_DIR}/dns.env" || return 1
        chmod 0600 "${CONF_DIR}/dns.env" || return 1
    fi

    runtime_tree_has_only_plain_entries "$MIHOMO_DIR" \
        || { err "Refusing unsafe link, hardlink, or special entry below $MIHOMO_DIR"; return 1; }
    install -d -o root -g "$FIVEGPN_SERVICE_USER" -m 3770 "$MIHOMO_DIR" || return 1
    # 5gpn/ is the core's own state directory and its modes are not ours to
    # rewrite. state.Dir keeps it 0711 so the certificate oneshot -- root with
    # an empty capability bounding set, and therefore subject to ordinary
    # permission checks -- can traverse it without being able to list it, and
    # state.WritePublicFile keeps the certificate request 0644 so that same
    # oneshot can read it. Sweeping the tree to 0660 left the request
    # unreadable by the only process that mints leaves, until the engine
    # happened to rewrite it for an unrelated reason.
    find "$MIHOMO_DIR" -mindepth 1 -path "$FIVEGPN_STATE_DIR" -prune -o -type d \
        -exec chown "$FIVEGPN_SERVICE_USER:$FIVEGPN_SERVICE_USER" {} + \
        -exec chmod 2770 {} + || return 1
    find "$MIHOMO_DIR" -mindepth 1 -path "$FIVEGPN_STATE_DIR" -prune -o -type f \
        ! -path "$MIHOMO_DIR/config.yaml" \
        ! -name 'config.yaml.bak.*' \
        ! -path "$node_lock" \
        ! -path "$node_backup" \
        -exec chown "$FIVEGPN_SERVICE_USER:$FIVEGPN_SERVICE_USER" {} + \
        -exec chmod 0660 {} + || return 1
    find "$MIHOMO_DIR" -mindepth 1 -maxdepth 1 -type f -name 'config.yaml.bak.*' \
        -exec chown "root:$FIVEGPN_SERVICE_USER" {} + \
        -exec chmod 0640 {} + || return 1
    for path in config.yaml; do
        [[ -f "$MIHOMO_DIR/$path" ]] || continue
        chown "root:$FIVEGPN_SERVICE_GROUP" "$MIHOMO_DIR/$path" || return 1
        chmod 0640 "$MIHOMO_DIR/$path" || return 1
    done
    if [[ -f "$node_backup" ]]; then
        chown "root:$FIVEGPN_SERVICE_GROUP" "$node_backup" || return 1
        chmod 0640 "$node_backup" || return 1
    fi
    if [[ -f "$node_lock" ]]; then
        chown root:root "$node_lock" || return 1
        chmod 0600 "$node_lock" || return 1
    fi

    prepare_intercept_runtime_dirs || return 1
    prepare_intercept_state_dir || return 1
    [[ ! -f "$INTERCEPT_DIR/cert-state" ]] \
        || { chown "root:$FIVEGPN_SERVICE_USER" "$INTERCEPT_DIR/cert-state" && chmod 0640 "$INTERCEPT_DIR/cert-state"; } || return 1
    if [[ -d "$INTERCEPT_DIR/tls" ]]; then
        runtime_tree_has_only_plain_entries "$INTERCEPT_DIR/tls" \
            || { err "Refusing unsafe link, hardlink, or special entry below $INTERCEPT_DIR/tls"; return 1; }
        chown -R root:"$FIVEGPN_SERVICE_USER" "$INTERCEPT_DIR/tls" || return 1
        find "$INTERCEPT_DIR/tls" -type d -exec chmod 0750 {} + || return 1
        find "$INTERCEPT_DIR/tls" -type d -exec chmod g-s {} + || return 1
        find "$INTERCEPT_DIR/tls" -type f -exec chmod 0640 {} + || return 1
    fi

    ensure_dns_cert_root || return 1
    for role in dot console; do
        [[ -d "${DNS_CERT_DIR}/${role}" ]] || continue
        cert_role_tree_is_safe_for_recursive_metadata "${DNS_CERT_DIR}/${role}" \
            || { err "Refusing unsafe certificate-role tree: ${DNS_CERT_DIR}/${role}"; return 1; }
    done
    runtime_permission_boundary_is_safe \
        || { err "Runtime ownership boundary validation failed after permission publication."; return 1; }
    ok "Runtime state and TLS material are scoped to the dedicated fivegpn service account."
}

# Certificate publishers run before the final all-runtime permission pass. Seal
# their parent directories immediately after service accounts exist and the
# transaction has stopped the runtime services.
prepare_certificate_publication_boundaries() {
    preflight_runtime_publication_paths || return 1
    install -d -o root -g root -m 0755 "$CONF_DIR" || return 1
    chmod g-s "$CONF_DIR" || return 1
    if [[ -f "${CONF_DIR}/dns.env" && ! -L "${CONF_DIR}/dns.env" ]]; then
        chown root:root "${CONF_DIR}/dns.env" || return 1
        chmod 0600 "${CONF_DIR}/dns.env" || return 1
    fi
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        || { err "Could not seal the configuration root before certificate publication."; return 1; }

    prepare_intercept_runtime_dirs || return 1
    runtime_file_slot_is_safe "$INTERCEPT_DIR/cert-state" "$CONF_DIR" \
        || { err "Unsafe interception certificate-control file slot."; return 1; }
    if [[ -f "$INTERCEPT_DIR/cert-state" ]]; then
        chown "root:$FIVEGPN_SERVICE_USER" "$INTERCEPT_DIR/cert-state" \
            && chmod 0640 "$INTERCEPT_DIR/cert-state" || return 1
    fi
    runtime_tree_has_only_plain_entries "$INTERCEPT_DIR/tls" \
        || { err "Unsafe interception TLS tree before certificate publication."; return 1; }
    chown -R "root:$FIVEGPN_SERVICE_USER" "$INTERCEPT_DIR/tls" || return 1
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

# Render the exact document shape used only when dns.json is absent. Keeping the
# jq program independently callable lets the policy suite parse and validate the
# real candidate rather than grepping a second hand-written fixture.
render_fresh_dns_document() {
    local dot="$1" debug="$2" cert="$3" key="$4" gateway="$5"
    local ecs="$6" china="$7" trust="$8"
    jq -n \
        --arg dot "$dot" --arg debug "$debug" --arg origin "$ORIGIN_LISTEN_ADDR" \
        --arg cert "$cert" --arg key "$key" --arg gw "$gateway" \
        --arg ecs "$ecs" --arg china "$china" --arg trust "$trust" \
        --arg chinaDomains "$DNS_CHINA_DOMAINS_DEFAULT" \
        --arg gfwlist "$DNS_GFWLIST_DEFAULT" \
        --argjson interval "$DNS_SUBSCRIPTION_INTERVAL_DEFAULT" \
        'def addrs: split(",") | map(gsub("\\s";""))
                    | map(select(length > 0))
                    | map(if test(":[0-9]+$") then . else . + ":53" end);
         {
           listen:    {dot: $dot, debug: $debug, origin: $origin,
                       certificate: $cert, privateKey: $key},
           gateway:   $gw,
           upstreams: {china: ($china | addrs), trust: ($trust | addrs), ecs: $ecs},
           policy:    {
             rules: [
               {id: "china-domains", kind: "subscription", value: $chinaDomains,
                intent: "direct", enabled: true, format: "clash", intervalSeconds: $interval},
               {id: "gfwlist", kind: "subscription", value: $gfwlist,
                intent: "proxy", enabled: true, format: "plain", intervalSeconds: $interval}
             ],
             fallback: "auto"
           },
           tuning:    {}
         }'
}

# The installer does not prompt for any of this: these are operational defaults,
# changeable in the console at any time.
seed_dns_document() {
    # <mihomo-home>/5gpn/dns.json is the only document the DNS engine reads.
    # A fresh document must include the installation-owned DoT certificate pair
    # because the runtime cannot infer it from policy defaults.
    # Listener and key paths are fixed installation fields. The staged Core and
    # this publication-time recheck both require their exact current values; a
    # reinstall never repairs drift by silently rewriting them. Only the
    # separately checked installation-owned gateway may change here.
    local state_dir="$FIVEGPN_STATE_DIR"
    local target="${state_dir}/dns.json"
    local cert="${DOT_CERT_DIR}/current/fullchain.pem"
    local key="${DOT_CERT_DIR}/current/privkey.pem"
    local tmp source_revision current_revision

    # The engine creates the state directory itself on first start, but the
    # document has to exist before that start, so the installer creates it to
    # the same shape rather than waiting for a process that cannot come up
    # without it.
    #
    # The mihomo home above it may not exist yet either. Creating it here with
    # the same boundary used elsewhere is idempotent, and the final permission
    # pass normalizes the tree afterwards regardless.
    install -d -o root -g "$FIVEGPN_SERVICE_USER" -m 3770 "$MIHOMO_DIR" \
        || { err "Could not create the mihomo home: ${MIHOMO_DIR}"; return 1; }
    install -d -o "$FIVEGPN_SERVICE_USER" -g "$FIVEGPN_SERVICE_USER" -m 0711 "$state_dir" \
        || { err "Could not create the engine state directory: ${state_dir}"; return 1; }
    chmod g-s "$state_dir" && chmod 00711 "$state_dir" \
        || { err "Could not clear inherited special bits from the engine state directory."; return 1; }
    [[ "$(file_uid "$state_dir")" == "$(account_uid "$FIVEGPN_SERVICE_USER")" \
       && "$(file_gid "$state_dir")" == "$(account_gid "$FIVEGPN_SERVICE_GROUP")" \
       && "$(file_mode "$state_dir")" == 711 ]] \
        || { err "The engine state directory failed its exact ownership and mode boundary."; return 1; }
    # install_service_accounts has already stopped the monolith and waited for
    # every process using the service identity. Reassert that boundary here so
    # the content hash below detects only external/offline tampering, not a
    # legitimate concurrent Core/API writer.
    assert_dns_publication_quiescent || return 1
    validate_existing_runtime_documents \
        || { err "Runtime documents changed or became invalid before quiesced publication."; return 1; }

    if [[ -e "$target" || -L "$target" ]]; then
        runtime_control_file_metadata_is_safe "$target" \
            "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" 600 \
            || { err "Existing DNS document path is unsafe: $target"; return 1; }
    fi

    if [[ -f "$target" ]]; then
        [[ "$VALIDATED_DNS_SOURCE_REVISION" =~ ^[0-9a-f]{64}$ ]] \
            || { err "The existing DNS document lacks a quiesced Core validation revision."; return 1; }
        source_revision="$(sha256sum "$target" | awk '{print $1}')" || return 1
        [[ "$source_revision" == "$VALIDATED_DNS_SOURCE_REVISION" ]] \
            || { err "The DNS document changed after pre-publication Core validation."; return 1; }
        current_dns_document_is_compatible "$target" \
            || { err "Existing DNS fixed listener or certificate fields have drifted; refusing to rewrite them: $target"; return 1; }
        if jq -e --arg gw "$GATEWAY_IP" '.gateway == $gw' "$target" >/dev/null; then
            ok "Existing DNS document has the current fixed fields and gateway; preserved it unchanged."
            return 0
        fi
        dns_document_is_jq_gateway_update_safe "$target" \
            || { err "Existing DNS numeric fields cannot be preserved exactly by the gateway-only updater."; return 1; }
        tmp="$(mktemp "${state_dir}/.dns.json.XXXXXX")" \
            || { err "Could not create the DNS document candidate."; return 1; }
        if ! jq --arg gw "$GATEWAY_IP" '.gateway = $gw' "$target" > "$tmp"; then
            rm -f -- "$tmp"
            err "Could not refresh the DNS document: ${target}"
            return 1
        fi
        current_dns_document_is_compatible "$tmp" \
            || { rm -f -- "$tmp"; err "Refusing an invalid DNS gateway-update candidate."; return 1; }
        jq -e --arg gw "$GATEWAY_IP" '.gateway == $gw' "$tmp" >/dev/null \
            || { rm -f -- "$tmp"; err "DNS gateway-update candidate does not contain the selected gateway."; return 1; }
        chown "${FIVEGPN_SERVICE_USER}:${FIVEGPN_SERVICE_GROUP}" "$tmp" \
            && chmod 0600 "$tmp" \
            && sync -f "$tmp" 2>/dev/null \
            || { rm -f -- "$tmp"; err "Could not secure the DNS document candidate."; return 1; }
        validate_dns_candidate_with_staged_core "$tmp" \
            || { rm -f -- "$tmp"; return 1; }
        runtime_control_file_metadata_is_safe "$target" \
            "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" 600 \
            || { rm -f -- "$tmp"; err "DNS document metadata changed before publication."; return 1; }
        current_revision="$(sha256sum "$target" | awk '{print $1}')" || { rm -f -- "$tmp"; return 1; }
        [[ "$current_revision" == "$source_revision" ]] \
            || { rm -f -- "$tmp"; err "DNS document changed while its gateway update was staged."; return 1; }
        current_dns_document_is_compatible "$target" \
            || { rm -f -- "$tmp"; err "DNS fixed fields changed while its gateway update was staged."; return 1; }
        mv -Tf -- "$tmp" "$target" \
            || { rm -f -- "$tmp"; err "Could not install ${target}."; return 1; }
        runtime_control_file_metadata_is_safe "$target" \
            "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" 600 \
            || { err "Published DNS document failed metadata validation."; return 1; }
        current_dns_document_is_compatible "$target" \
            || { err "Published DNS document failed fixed-field validation."; return 1; }
        ok "Refreshed the DNS document's installation-owned gateway."
        return 0
    fi

    local china="$DNS_CHINA_DEFAULT" trust="$DNS_TRUST_DEFAULT"
    local ecs="$DNS_CHINA_ECS_DEFAULT" dot="$DOT_LISTEN_ADDR" debug="$DEBUG_LISTEN_ADDR"

    [[ "$VALIDATED_DNS_SOURCE_REVISION" == absent ]] \
        || { err "A fresh DNS document was not proven absent before publication."; return 1; }

    tmp="$(mktemp "${state_dir}/.dns.json.XXXXXX")" \
        || { err "Could not create the DNS document candidate."; return 1; }
    if ! render_fresh_dns_document "$dot" "$debug" "$cert" "$key" "$GATEWAY_IP" \
            "$ecs" "$china" "$trust" > "$tmp"; then
        rm -f -- "$tmp"
        err "Could not write the DNS document candidate."
        return 1
    fi
    if [[ "$(jq -r '.upstreams.china | length' "$tmp")" == 0 \
       || "$(jq -r '.upstreams.trust | length' "$tmp")" == 0 ]]; then
        rm -f -- "$tmp"
        err "Refusing to seed an empty upstream group into ${target}."
        return 1
    fi
    current_dns_document_is_compatible "$tmp" \
        || { rm -f -- "$tmp"; err "Refusing a fresh DNS document with drifted fixed fields."; return 1; }
    # Owned by the service account: unlike dns.env, the engine must be able to
    # replace this file when the console saves a change.
    chown "${FIVEGPN_SERVICE_USER}:${FIVEGPN_SERVICE_GROUP}" "$tmp" \
        && chmod 0600 "$tmp" \
        && sync -f "$tmp" 2>/dev/null \
        || { rm -f -- "$tmp"; err "Could not secure the DNS document candidate."; return 1; }
    validate_dns_candidate_with_staged_core "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
    [[ ! -e "$target" && ! -L "$target" ]] \
        || { rm -f -- "$tmp"; err "A DNS document appeared after pre-publication absence validation."; return 1; }
    mv -Tf -- "$tmp" "$target" \
        || { rm -f -- "$tmp"; err "Could not install ${target}."; return 1; }
    runtime_control_file_metadata_is_safe "$target" \
        "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" 600 \
        || { err "Published DNS document failed metadata validation."; return 1; }
    current_dns_document_is_compatible "$target" \
        || { err "Published fresh DNS document failed fixed-field validation."; return 1; }
    ok "Seeded the DNS document (china=${china} trust=${trust})."
}

write_dns_env() {
    # Write /etc/5gpn/dns.env from install-time collected vars.
    DNS_ENV_PUBLICATION_COMMIT_STATE=not-committed
    assert_loaded_persisted_dns_env_revision 1 || return 1
    fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        && runtime_file_slot_is_safe "${CONF_DIR}/dns.env" "$CONF_DIR" \
        || { err "Refusing unsafe dns.env path: ${CONF_DIR}/dns.env"; return 1; }
    [[ -d "$CONF_DIR" && ! -L "$CONF_DIR" ]] \
        || { err "Configuration root disappeared before dns.env publication."; return 1; }

    # Runtime documents and the operator-owned mihomo file are separate sources
    # of truth. This file contains exactly the six host-specific installer
    # inputs needed to reproduce a checked install transaction.
    local base_domain="$BASE_DOMAIN"
    derive_domains "$base_domain" || return 1

    local dns_env_tmp
    dns_env_tmp="$(mktemp "${CONF_DIR}/.dns.env.XXXXXX")" \
        || { err "Could not create the dns.env candidate."; return 1; }
    if ! cat > "$dns_env_tmp" <<EOF
# 5gpn installer inputs. Runtime DNS/interception/bot state lives only in the
# Core-owned documents, and controller credentials live only in operator-owned
# config.yaml. Re-run the installer for changes to these six coordinates.
DNS_BASE_DOMAIN=${BASE_DOMAIN}
DNS_PUBLIC_IP=${PUBLIC_IP}
DNS_GATEWAY_IP=${GATEWAY_IP}
DNS_MIHOMO_LISTEN_IPS=${MIHOMO_LISTEN_IPS}
CERT_MODE=${CERT_MODE}
CERT_EMAIL=${CERT_EMAIL}
EOF
    then
        rm -f -- "$dns_env_tmp"
        err "Could not write the dns.env candidate."
        return 1
    fi
    chown root:root "$dns_env_tmp" \
        && chmod 0600 "$dns_env_tmp" \
        && sync -f "$dns_env_tmp" 2>/dev/null \
        || { rm -f -- "$dns_env_tmp"; err "Could not protect or sync the dns.env candidate."; return 1; }
    validate_dns_env_schema "$dns_env_tmp" \
        || { rm -f -- "$dns_env_tmp"; err "dns.env candidate failed schema validation."; return 1; }
    validate_persisted_install_config_values "$dns_env_tmp" \
        || { rm -f -- "$dns_env_tmp"; err "dns.env candidate failed value validation."; return 1; }
    assert_loaded_persisted_dns_env_revision 1 \
        || { rm -f -- "$dns_env_tmp"; return 1; }
    mv -f -- "$dns_env_tmp" "${CONF_DIR}/dns.env" \
        || { rm -f -- "$dns_env_tmp"; err "Could not atomically publish dns.env."; return 1; }
    DNS_ENV_PUBLICATION_COMMIT_STATE=committed-undurable
    sync -f "$CONF_DIR" 2>/dev/null \
        || { err "Could not sync the dns.env directory publication."; return 1; }
    DNS_ENV_PUBLICATION_COMMIT_STATE=committed
    [[ -f "${CONF_DIR}/dns.env" && ! -L "${CONF_DIR}/dns.env" \
       && "$(file_uid "${CONF_DIR}/dns.env")" == 0 \
       && "$(file_gid "${CONF_DIR}/dns.env")" == 0 \
       && "$(file_mode "${CONF_DIR}/dns.env")" == 600 \
       && "$(file_nlink "${CONF_DIR}/dns.env")" == 1 ]] \
       && validate_dns_env_schema \
        && validate_persisted_install_config_values "${CONF_DIR}/dns.env" \
        || { err "Published dns.env failed metadata or schema validation."; return 1; }
    LOADED_DNS_ENV_SOURCE_STATE=present
    LOADED_DNS_ENV_SOURCE_REVISION="$(sha256sum "${CONF_DIR}/dns.env" | awk '{print $1}')" || return 1
    LOADED_DNS_ENV_SOURCE_IDENTITY="$(stat -Lc '%d:%i' -- "${CONF_DIR}/dns.env" 2>/dev/null)" || return 1
    ok "Written ${CONF_DIR}/dns.env (current schema only)."
}

prepare_ios_profile() {
    info "Preparing iOS DoT profile generation..."
    local gw="${GATEWAY_IP:-$PUBLIC_IP}" candidate created_candidate=0
    local generator="${SCRIPTS_DIR}/gen-ios-profile.sh" generator_before generator_after
    local generator_hash_fd generator_source_fd generator_hash_metadata
    local generator_source_metadata generator_fd_digest
    [[ "$INSTALL_CERT_LOCK_HELD" == 1 ]] \
        || { err "UI profile preparation requires the certificate transaction lock."; return 1; }
    load_ui_generation_helper || return 1
    UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
    candidate="$UI_GENERATION_CANDIDATE"
    if [[ -z "$candidate" ]]; then
        ui_generation_prepare_existing_current "$UI_DIR" \
            || { err "A valid existing current UI generation is required for manual profile refresh."; return 1; }
        candidate="$(ui_generation_clone_current "$UI_DIR")" \
            || { err "Could not clone the validated current UI generation."; return 1; }
        UI_GENERATION_CANDIDATE="$candidate"
        created_candidate=1
    else
        claim_ui_dir || return 1
    fi
    if generator_before="$(installed_runtime_script_state "$generator")"; then
        # The generator writes only the unpublished candidate. The filesystem
        # helper validates the complete Console/profile tree and performs the
        # only live switch, so an old current generation remains reachable on
        # every signing or validation failure.
        exec {generator_hash_fd}<"$generator" \
            || { ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; \
                 err "Could not anchor the installed profile generator."; return 1; }
        exec {generator_source_fd}<"$generator" \
            || { exec {generator_hash_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
        generator_hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' \
            -- "/proc/self/fd/$generator_hash_fd")" \
            || { exec {generator_hash_fd}<&-; exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
        generator_source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' \
            -- "/proc/self/fd/$generator_source_fd")" \
            || { exec {generator_hash_fd}<&-; exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
        [[ "$generator_hash_metadata" == "${generator_before%:*}" \
           && "$generator_source_metadata" == "${generator_before%:*}" ]] \
            || { exec {generator_hash_fd}<&-; exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; \
                 err "Profile generator changed while it was anchored."; return 1; }
        generator_fd_digest="$(sha256sum -- "/proc/self/fd/$generator_hash_fd" | awk '{print $1}')" \
            || { exec {generator_hash_fd}<&-; exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; return 1; }
        exec {generator_hash_fd}<&-
        [[ "$generator_fd_digest" == "${generator_before##*:}" ]] \
            || { exec {generator_source_fd}<&-; ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; \
                 err "Profile generator bytes differ from the anchored path."; return 1; }
        if ! bash "/proc/self/fd/$generator_source_fd" "$DOT_DOMAIN" "$gw" "$candidate"; then
            exec {generator_source_fd}<&-
            if ui_generation_cleanup_candidate "$UI_DIR" "$candidate"; then
                UI_GENERATION_CANDIDATE=""
            else
                err "Unpublished UI generation cleanup failed; retained for inspection: $candidate"
            fi
            warn "gen-ios-profile.sh failed because a signed profile could not be produced; the previous current generation remains live."
            return 1
        fi
        exec {generator_source_fd}<&-
        generator_after="$(installed_runtime_script_state "$generator")" \
            || { ui_generation_cleanup_candidate "$UI_DIR" "$candidate" || true; \
                 err "Could not revalidate the installed profile generator."; return 1; }
        if [[ "$generator_after" != "$generator_before" ]]; then
            if ui_generation_cleanup_candidate "$UI_DIR" "$candidate"; then
                UI_GENERATION_CANDIDATE=""
            fi
            err "Installed profile generator changed during execution."
            return 1
        fi
    else
        if ui_generation_cleanup_candidate "$UI_DIR" "$candidate"; then
            UI_GENERATION_CANDIDATE=""
        else
            err "Unpublished UI generation cleanup failed; retained for inspection: $candidate"
        fi
        warn "scripts/gen-ios-profile.sh not present yet; skipping profile generation."
        return 1
    fi

    UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT="$created_candidate"
    ok "Prepared a complete unpublished UI/profile generation."
}

publish_ios_profile() {
    local candidate="${UI_GENERATION_CANDIDATE:-}"
    local created_candidate="${UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT:-0}"
    [[ "$INSTALL_CERT_LOCK_HELD" == 1 ]] \
        || { err "UI profile publication requires the certificate transaction lock."; return 1; }
    [[ -n "$candidate" ]] \
        || { err "No prepared UI/profile generation is available for publication."; return 1; }

    if ! ui_generation_publish "$UI_DIR" "$candidate"; then
        if [[ "$UI_GENERATION_COMMIT_STATE" == committed* ]]; then
            UI_GENERATION_CANDIDATE=""
            UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
            err "The UI current switch committed, but its durability or final validation could not be confirmed."
            err "The installer will not roll that committed switch back; inspect the generation tree and rerun."
            return 1
        fi
        if ui_generation_cleanup_candidate "$UI_DIR" "$candidate"; then
            UI_GENERATION_CANDIDATE=""
            UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
        else
            err "Unpublished UI generation cleanup failed; retained for inspection: $candidate"
        fi
        err "The complete UI/profile generation could not be atomically published."
        return 1
    fi
    UI_GENERATION_CANDIDATE=""
    UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
    [[ "$UI_GENERATION_GC_WARNING" == 0 ]] \
        || warn "The new UI generation is active, but an older unreferenced generation could not be removed."
    if [[ "$created_candidate" == 1 ]]; then
        ok "iOS profiles re-signed in a cloned generation and atomically activated."
    else
        ok "Verified zashboard and both signed iOS profiles atomically activated."
    fi
}

setup_ios_profile() {
    prepare_ios_profile && publish_ios_profile
}

# ios_profile_url — the ONE derivation of where a phone fetches the DoT profile.
#
# It is /ui/, not /ios/. The profiles are published into the bundle directory
# because the controller is what serves them, and the /ios/ path belonged to the
# separate console origin that the monolith retired. The QR code, the success
# banner and the regenerate message all print this URL to an operator who will
# type it into a phone, so all three come through here -- one of them pointing
# at the retired path is a 404 discovered by hand, on a phone, later.
ios_profile_url() {
    local name="${1:-ios-dot.mobileconfig}"
    [[ -n "${CONSOLE_DOMAIN:-}" ]] || load_persisted_domains || return 1
    printf 'https://%s/ui/%s' "$CONSOLE_DOMAIN" "$name"
}

print_qr() {
    [[ -n "${CONSOLE_DOMAIN:-}" ]] || load_persisted_domains || return 1
    local url; url="$(ios_profile_url)" || return 1
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
    local raw="" ips="" aaaa="" aaaa_raw="" aaaa_answered=1 ip expected matched raw_count ip_count
    command -v dig >/dev/null 2>&1 \
        || { CERT_DNS_LAST_OBSERVATION="dig is unavailable"; return 1; }
    raw="$(dig +time=3 +tries=1 +short A "$domain" @"$CERT_DNS_RESOLVER" 2>/dev/null || true)"
    ips="$(printf '%s\n' "$raw" | awk '/^[0-9]+(\.[0-9]+){3}$/' || true)"
    raw_count="$(printf '%s\n' "$raw" | awk 'NF { n++ } END { print n+0 }')"
    ip_count="$(printf '%s\n' "$ips" | awk 'NF { n++ } END { print n+0 }')"
    if [[ "$require_no_aaaa" == 1 ]]; then
        # Absence of AAAA has to be OBSERVED, not inferred from empty output.
        # dig prints nothing on stdout when it gets no reply, and piping it into
        # awk replaces dig's exit status with awk's -- so the earlier
        # `dig ... | awk '/:/' || true` could not tell "this name has no AAAA"
        # apart from "the query never answered", and silently passed on the
        # second. That matters because this gate is the last thing standing
        # before run_http_certbot stops mihomo to free :80: passing it without
        # evidence drops the data plane for an issuance that then loses to
        # Let's Encrypt's IPv6 preference. Keep dig's own status by not piping
        # it, and treat a failed lookup as unproven rather than as absence.
        # wait_for_cert_dns retries, so a transient failure resolves itself and
        # a persistent one ends with an explicit operator-facing error.
        if aaaa_raw="$(dig +time=3 +tries=1 +short AAAA "$domain" @"$CERT_DNS_RESOLVER" 2>/dev/null)"; then
            aaaa="$(printf '%s\n' "$aaaa_raw" | awk '/:/')"
        else
            aaaa_answered=0
        fi
    else
        aaaa="not-required"
    fi
    CERT_DNS_LAST_OBSERVATION="${domain}: raw-A=[${raw//$'\n'/, }] A=[${ips//$'\n'/, }] AAAA=[${aaaa//$'\n'/, }]"
    [[ "$aaaa_answered" == 1 ]] || {
        CERT_DNS_LAST_OBSERVATION="${domain}: AAAA lookup through ${CERT_DNS_RESOLVER} did not answer; absence of AAAA is unproven"
        return 1
    }
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
    for domain in "$CONSOLE_DOMAIN" "$DOT_DOMAIN"; do
        cert_dns_name_matches "$domain" 1 "$PUBLIC_IP" || return 1
    done
    for domain in "$CONSOLE_DOMAIN" "$DOT_DOMAIN"; do
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
                || { err "Set console/dot A records to DNS_PUBLIC_IP=${PUBLIC_IP}, remove AAAA records, and keep public TCP/80 reachable."; return 1; } ;;
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
    # What a fresh install can actually verify about the served surface.
    #
    # This probed a public console origin: an SPA at https://<console>/, an
    # /api/status that had to answer 401, and the profiles under /ios/. None of
    # the three exists. One process serves the API and the bundle on the
    # controller now, so that is where the checks belong -- and the old ones
    # could not fail informatively, because nothing was listening to refuse them.
    #
    # Two things are worth asserting, and both were live failure modes on this
    # branch. The profiles must be readable without a secret, because an
    # unenrolled phone holds none and /ui/* is deliberately outside the
    # controller's authentication group. And they must carry the Apple content
    # type, or iOS downloads the file instead of offering to install it -- a
    # silently worse experience rather than a visible error.
    local code content_type media_type name probe

    for name in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
        [[ -s "${UI_CURRENT_DIR}/${name}" ]] \
            || { err "Profile ${name} is absent from ${UI_CURRENT_DIR} after generation."; return 1; }
        probe="$(mihomo_controller_curl "/ui/${name}" \
            --silent --show-error --max-time 5 \
            -o /dev/null -w $'%{http_code}\t%{content_type}' 2>/dev/null || true)"
        IFS=$'\t' read -r code content_type <<< "$probe"
        if [[ "$code" != 200 ]]; then
            err "Profile probe failed: /ui/${name} returned HTTP ${code:-none}, want 200."
            return 1
        fi
        media_type="${content_type%%;*}"
        media_type="${media_type#"${media_type%%[![:space:]]*}"}"
        media_type="${media_type%"${media_type##*[![:space:]]}"}"
        if [[ "${media_type,,}" != "application/x-apple-aspen-config" ]]; then
            err "Profile /ui/${name} returned Content-Type '${content_type:-<missing>}', want application/x-apple-aspen-config; iOS would download it instead of installing it."
            return 1
        fi
    done

    # The bundle itself, unauthenticated, on the same origin.
    code="$(mihomo_controller_curl "/ui/" --silent --max-time 5 \
        -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
    [[ "$code" == 200 ]] \
        || { err "Console bundle probe failed: /ui/ returned HTTP ${code:-none}, want 200."; return 1; }

    # And the authenticated half stays authenticated. Asking without a bearer
    # must be refused: /ui/* being open is a deliberate exception, not the rule.
    code="$(mihomo_controller_curl "/configs" --silent --max-time 5 \
        -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
    [[ "$code" == 401 ]] \
        || { err "Controller auth probe failed: unauthenticated /configs returned HTTP ${code:-none}, want 401."; return 1; }
    ok "Console verified: bundle and both profiles are served unauthenticated; the control API is not."
}

# ----------------------------------------------------------------------------
# Service lifecycle
# ----------------------------------------------------------------------------
# Asks whether the NAMED process is listening, not merely whether something is.
#
# Without the process test this answers "is anything bound to ip:port", so a
# pre-existing nginx or haproxy holding the same LAN address satisfies mihomo's
# readiness probe and the installer declares a data plane ready that never
# started. -p needs no privilege for sockets the caller owns and the installer
# runs as root, so attribution is available; where it is not, the probe falls
# back to the address test rather than failing a healthy gateway.
ss_has_exact_listener() {
    local kind="$1" ip="$2" port="$3" process="${4:-}" flags out
    case "$kind" in
        tcp) flags=-ltn ;;
        udp) flags=-lun ;;
        *) return 1 ;;
    esac
    out="$(ss -H -p "$flags" 2>/dev/null)" || out=""
    if [[ -z "$out" ]]; then
        ss -H "$flags" 2>/dev/null \
            | awk -v target="${ip}:${port}" '$4 == target { found=1 } END { exit !found }'
        return $?
    fi
    printf '%s\n' "$out" \
        | awk -v target="${ip}:${port}" -v want="$process" '
            $4 != target { next }
            want == "" { found=1; next }
            index($0, "\"" want "\"") { found=1 }
            END { exit !found }'
}

# One unit owns the controller, the gateway listeners, the console API and the
# DoT boundary, so readiness has to cover all four. It used to be two probes
# against two units; keeping only the mihomo half would have declared the
# install ready while the resolver was not yet answering, which is precisely
# the window install_cert runs in.
probe_mihomo_ready() {
    systemctl is-active --quiet 5gpn-mihomo.service || return 1
    local ip port domain
    local -a tcp_ports=(80 443)
    local -a udp_ports=(443)
    if [[ "${MIHOMO_SEED_PORTS_REQUIRED:-0}" == 1 ]]; then
        tcp_ports+=(8080 8443)
    fi
    mihomo_authenticated_controller_curl "/version" \
        --fail --silent --show-error --max-time 2 -o /dev/null \
        >/dev/null 2>&1 || return 1

    command -v ss >/dev/null 2>&1 || return 1
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        for port in "${tcp_ports[@]}"; do
            ss_has_exact_listener tcp "$ip" "$port" 5gpn-mihomo || return 1
        done
        for port in "${udp_ports[@]}"; do
            ss_has_exact_listener udp "$ip" "$port" 5gpn-mihomo || return 1
        done
    done < <(printf '%s\n' "$MIHOMO_LISTEN_IPS" | tr ',' '\n')

    [[ -n "${DOT_DOMAIN:-}" ]] || load_persisted_domains || return 1
    domain="$DOT_DOMAIN"
    # The loopback console origin this used to probe as a *separate* listener is
    # gone -- one process serves the API and the bundle on the controller now,
    # which is itself what answers on 127.0.0.1:443.
    #
    # /ui/ is the check worth having in its place. It is unauthenticated static
    # content, so a 200 means the bundle really was published where the unit can
    # read it. That failure otherwise surfaces as a blank page long after the
    # installer has reported success.
    mihomo_controller_curl "/ui/" --fail --silent --show-error --max-time 2 -o /dev/null \
        >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || return 1
    timeout 4 openssl s_client -brief -connect 127.0.0.1:853 -servername "$domain" \
        </dev/null 2>&1 | grep -Eq 'CONNECTION ESTABLISHED|Protocol version:'
}

wait_service_ready() {
    local svc="$1" deadline announced=0
    deadline=$((SECONDS + SERVICE_READY_TIMEOUT))
    while (( SECONDS < deadline )); do
        case "$svc" in
            5gpn-mihomo.service) probe_mihomo_ready \
                && { ok "5gpn-mihomo readiness passed (controller, gateway listeners, UI bundle, DoT handshake)."; return 0; } ;;
        esac
        # Speak up only once the first probe has failed, so a service that
        # starts promptly stays quiet. Without this a slow start is up to
        # SERVICE_READY_TIMEOUT seconds of silence per service, which reads as a
        # hang rather than as waiting.
        if (( announced == 0 )); then
            announced=1
            info "Waiting for ${svc} to become ready (up to ${SERVICE_READY_TIMEOUT}s)..."
        fi
        (( SECONDS < deadline )) && sleep 1
    done
    err "$svc did not become ready within ${SERVICE_READY_TIMEOUT}s (journalctl -u $svc)."
    return 1
}

reset_systemd_failed_state() {
    local unit="$1" load_state active_state
    systemctl reset-failed "$unit" >/dev/null 2>&1 && return 0
    load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" \
        || { err "could not read LoadState after reset-failed failed for ${unit}."; return 1; }
    active_state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null)" \
        || { err "could not read ActiveState after reset-failed failed for ${unit}."; return 1; }
    if [[ "$load_state" == loaded && -n "$active_state" && "$active_state" != failed ]]; then
        info "${unit} has no tracked failed state to clear (ActiveState=${active_state}); continuing."
        return 0
    fi
    err "could not clear failed state for ${unit} (LoadState=${load_state:-unknown}, ActiveState=${active_state:-unknown})."
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
    reset_systemd_failed_state 5gpn-intercept-cert.service || return 1
    systemctl enable --now 5gpn-intercept-cert.path >/dev/null 2>&1 \
        || { err "could not enable the interception certificate watcher."; return 1; }
    systemctl enable --now 5gpn-intercept-cert.timer >/dev/null 2>&1 \
        || { err "could not enable the interception certificate renewal timer."; return 1; }
    # One service. It carries the DNS engine, the interception engine, the data
    # plane and the control API, so there is no ordering left to get right --
    # the race this used to arbitrate, where DNS could advertise gateway
    # answers before the data-plane listener was live, cannot occur inside one
    # process that binds both before it accepts either.
    #
    # The MITM master is no longer consulted here. It used to decide whether to
    # start a second unit, and a conditioned sidecar that must not run with the
    # master off is a thing that no longer exists: the engine is loaded either
    # way and captures nothing until the document says to.
    #
    # Any enable, start or readiness failure is fatal.
    # full_install must never print success for a broken deployment.
    local failed=0
    if ! systemctl enable 5gpn-mihomo.service >/dev/null 2>&1; then
        err "could not enable 5gpn-mihomo (check: systemctl status 5gpn-mihomo.service)."
        failed=1
    fi
    if ! reset_systemd_failed_state 5gpn-mihomo.service; then
        failed=1
    elif ! systemctl restart 5gpn-mihomo.service 2>/dev/null; then
        err "could not start 5gpn-mihomo (check: journalctl -u 5gpn-mihomo.service)."
        failed=1
    else
        wait_service_ready 5gpn-mihomo.service || failed=1
    fi
    [[ "$failed" == 0 ]] || return 1
}

# The installer holds the shared certificate lock while publishing certificate
# and runtime state. Starting the certificate path can synchronously start its required
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
        if [[ "$UI_GENERATION_COMMIT_STATE" != committed* ]]; then
            err "iOS profile generation failed before current changed. Fix the reported signing or filesystem boundary."
        fi
        exit 1
    fi
    # No service restart needed: mihomo serves the profile from UI_DIR on each request.
    verify_console_dns
    MIHOMO_LISTEN_IPS="${MIHOMO_LISTEN_IPS:-$(cfg_get DNS_MIHOMO_LISTEN_IPS)}"
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    verify_console_endpoint
    print_qr
    ok "iOS profile regenerated: $(ios_profile_url)"
}

show_status() {
    local identity_pending=0
    load_identity_reconcile_journal || return 1
    [[ -z "$REPLACED_FIVEGPN_UID" && -z "$REPLACED_FIVEGPN_GID" \
       && -z "$REPLACED_FIVEGPN_NAMED_GID" ]] || identity_pending=1
    load_persisted_domains || return 1
    {
        local domain="$DOT_DOMAIN" webdomain="$CONSOLE_DOMAIN" pubip svc s intercept_snapshot
        pubip="$(cfg_get DNS_PUBLIC_IP)"; pubip="${pubip:-N/A}"
        echo "📊 5gpn 状态"
        echo ""
        if [[ "$identity_pending" == 1 ]]; then
            echo "  ❌ runtime identity reconciliation pending; rerun the installer before restart or mutation"
        fi
        # One process owns resolving, forwarding, the console, the bot and
        # interception, so there is one unit to report. Interception is a stage
        # inside it rather than a service that can be up or down on its own --
        # whether it is switched on is a property of the document, which the
        # control API reports.
        s="$(manage_unit_state 5gpn-mihomo.service)"
        echo "  $([[ "$s" == active ]] && echo '✅' || echo '❌') 5gpn-mihomo  (${s})"
        if intercept_snapshot="$(fivegpn_interception_snapshot)"; then
            if grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true' <<<"$intercept_snapshot"; then
                echo "  ✅ interception  (enabled)"
            else
                echo "  ⏸️  interception  (disabled by MITM setting)"
            fi
        else
            echo "  ❔ interception  (control API unreachable)"
        fi
        echo ""
        echo "  WebUI 域名  $webdomain  (https://${webdomain}/ui/)"
        echo "  DoT 域名    $domain"
        echo "  公网 IP     $pubip"
        echo "  DoT         tls://${domain}:853"
    } | card
}

prompt_default() {
    local label="$1" default="$2" value=""
    value="$(ask_text "$label" "$default" || true)"
    [[ -n "$value" ]] && printf '%s\n' "$value" || printf '%s\n' "$default"
}

validate_dns_env_schema_contents() {
    local file="$1" line key required seen=" "
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" != *$'\r'* ]] \
            || { err "Persisted dns.env contains a carriage return."; return 1; }
        case "$line" in ''|\#*) continue ;; esac
        [[ "$line" == *=* ]] \
            || { err "Persisted dns.env contains a malformed line."; return 1; }
        key="${line%%=*}"
        case " $DNS_ENV_KEYS " in
            *" $key "*) ;;
            *)
                err "Persisted dns.env contains unsupported key: $key"
                return 1
                ;;
        esac
        case "$seen" in
            *" $key "*) err "Persisted dns.env contains duplicate key: $key"; return 1 ;;
            *) seen="${seen}${key} " ;;
        esac
    done < "$file"
    for required in $DNS_ENV_KEYS; do
        case "$seen" in
            *" $required "*) ;;
            *) err "Persisted dns.env is missing required key: $required"; return 1 ;;
        esac
    done
}

validate_dns_env_schema() {
    local file="${1:-${CONF_DIR}/dns.env}"
    [[ -f "$file" && ! -L "$file" ]] \
        || { err "Persisted dns.env is missing or unsafe: $file"; return 1; }
    validate_dns_env_schema_contents "$file"
}

preflight_persisted_dns_env() {
    local env="${CONF_DIR}/dns.env"
    [[ ! -e "$env" && ! -L "$env" ]] && return 0
    persisted_dns_env_file_metadata_is_safe \
        || { err "Refusing unsafe persisted installer configuration before publication: $env"; return 1; }
    validate_dns_env_schema "$env" \
        || { err "Persisted installer configuration is not the exact current six-key schema: $env"; return 1; }
    validate_persisted_install_config_values "$env" \
        || { err "Persisted installer configuration contains invalid values: $env"; return 1; }
}

load_persisted_install_config() {
    local env="${CONF_DIR}/dns.env" dns_env_fd fd_path revision identity
    local loaded_base loaded_public loaded_gateway loaded_listen loaded_mode loaded_email
    preflight_persisted_dns_env || return 1
    [[ -f "$env" ]] || return 1
    exec {dns_env_fd}<"$env" \
        || { err "Could not open persisted dns.env for a stable read."; return 1; }
    fd_path="/proc/self/fd/${dns_env_fd}"
    if ! validate_dns_env_schema_contents "$fd_path" \
       || ! validate_persisted_install_config_values "$fd_path"; then
        exec {dns_env_fd}<&-
        return 1
    fi
    revision="$(sha256sum "$fd_path" | awk '{print $1}')" \
        || { exec {dns_env_fd}<&-; return 1; }
    identity="$(stat -Lc '%d:%i' -- "$fd_path" 2>/dev/null)" \
        || { exec {dns_env_fd}<&-; return 1; }
    loaded_base="$(dns_env_value_from_file "$fd_path" DNS_BASE_DOMAIN)" \
        || { exec {dns_env_fd}<&-; return 1; }
    loaded_public="$(dns_env_value_from_file "$fd_path" DNS_PUBLIC_IP)" \
        || { exec {dns_env_fd}<&-; return 1; }
    loaded_gateway="$(dns_env_value_from_file "$fd_path" DNS_GATEWAY_IP)" \
        || { exec {dns_env_fd}<&-; return 1; }
    loaded_listen="$(dns_env_value_from_file "$fd_path" DNS_MIHOMO_LISTEN_IPS)" \
        || { exec {dns_env_fd}<&-; return 1; }
    loaded_mode="$(dns_env_value_from_file "$fd_path" CERT_MODE)" \
        || { exec {dns_env_fd}<&-; return 1; }
    loaded_email="$(dns_env_value_from_file "$fd_path" CERT_EMAIL)" \
        || { exec {dns_env_fd}<&-; return 1; }
    exec {dns_env_fd}<&-

    LOADED_DNS_ENV_SOURCE_STATE=present
    LOADED_DNS_ENV_SOURCE_REVISION="$revision"
    LOADED_DNS_ENV_SOURCE_IDENTITY="$identity"
    assert_loaded_persisted_dns_env_revision 0 || return 1

    BASE_DOMAIN="$(printf '%s' "$loaded_base" | tr '[:upper:]' '[:lower:]')"
    PUBLIC_IP="$loaded_public"
    GATEWAY_IP="$loaded_gateway"
    MIHOMO_LISTEN_IPS="$loaded_listen"
    CERT_MODE="$loaded_mode"
    CERT_EMAIL="$loaded_email"
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
        is_valid_cert_email "${CERT_EMAIL:-}" \
            || { err "Persisted CERT_EMAIL is invalid for the selected production certificate mode."; return 1; }
    fi
    MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" || return 1
    export BASE_DOMAIN PUBLIC_IP GATEWAY_IP MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL
}

# ---------------------------------------------------------------------------
# First-install configuration.
#
# The collection pass is deliberately linear, and it is not a screen list like
# manage_menu. These fields are dependency-ordered: the certificate mode decides
# whether an ACME email and a Cloudflare token are asked for at all, and the base
# domain is what the DNS-prerequisite card is rendered from. A screen an operator
# could enter out of order would present fields whose validity depends on answers
# not yet given.
#
# What it lacked was not a way sideways but a way BACK. A typo in the base domain
# first became visible on the summary card, and the only thing the summary
# offered was yes or no -- so correcting one character meant cancelling the whole
# install and starting over. The summary is a review screen now: confirm, or pick
# a field and re-answer it, as many times as needed.
#
# That also retires what `advanced` used to cost. It still decides which fields
# the FIRST pass stops on, but every field is reachable from the review, so an
# auto-detected address an operator disagrees with no longer requires a rerun.
#
# One prompt per field, defined once and called from both the first pass and the
# review. Two copies of a prompt are two places for a validator to drift apart.
# ---------------------------------------------------------------------------

install_tui_cert_mode() {
    local choice
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
}

install_tui_base_domain() {
    local value
    while true; do
        value="$(prompt_default '主域名 Base domain' "${BASE_DOMAIN:-5gpn.local}")"
        value="${value#http://}"; value="${value#https://}"; value="${value%/}"; value="${value// /}"
        value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
        is_valid_domain "$value" && { derive_domains "$value"; return 0; }
        warn "Invalid domain; enter a full FQDN like example.com."
    done
}

install_tui_public_ip() {
    local default="${1:-$PUBLIC_IP}"
    while true; do
        PUBLIC_IP="$(prompt_default '公网 IPv4 Public IPv4' "$default")"
        is_valid_ipv4 "$PUBLIC_IP" && return 0
        warn "Invalid public IPv4."
    done
}

install_tui_gateway_ip() {
    while true; do
        GATEWAY_IP="$(prompt_default '客户端可达网关 IPv4 Gateway IPv4' "${GATEWAY_IP:-$PUBLIC_IP}")"
        is_valid_ipv4 "$GATEWAY_IP" && return 0
        warn "Invalid gateway IPv4."
    done
}

install_tui_listen_ips() {
    local default="${1:-$MIHOMO_LISTEN_IPS}"
    while true; do
        MIHOMO_LISTEN_IPS="$(prompt_default 'mihomo 本机监听 IPv4（逗号分隔）' "$default")"
        MIHOMO_LISTEN_IPS="$(resolve_mihomo_listen_ips "$MIHOMO_LISTEN_IPS")" && return 0
    done
}

# The ACME email belongs to the mode, so changing the mode re-runs this. debug
# issues nothing and must not carry a stale address forward.
install_tui_cert_email() {
    if [[ "$CERT_MODE" == debug ]]; then
        CERT_EMAIL=""
        return 0
    fi
    CERT_EMAIL="$(prompt_default 'Let’s Encrypt email' "${CERT_EMAIL:-admin@${BASE_DOMAIN}}")"
    is_valid_cert_email "$CERT_EMAIL" \
        || { err "Invalid certificate email."; return 1; }
}

configure_install_tui() {
    [[ -t 0 ]] || { err "First install/configuration requires an attached TTY; shell environment injection is not supported."; return 1; }
    local advanced="${1:-0}" detected default_listen choice

    install_tui_cert_mode || return 1
    install_tui_base_domain || return 1

    detected="${PUBLIC_IP:-}"
    if ! is_valid_ipv4 "$detected"; then
        PUBLIC_IP=""
        get_public_ip
        detected="$PUBLIC_IP"
    fi
    if [[ "$advanced" == 1 ]]; then
        install_tui_public_ip "$detected" || return 1
        install_tui_gateway_ip || return 1
    else
        PUBLIC_IP="$detected"
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
        install_tui_listen_ips "$default_listen" || return 1
    else
        MIHOMO_LISTEN_IPS="$default_listen"
    fi

    install_tui_cert_email || return 1

    # Review. Every label here has an arm below; a label without one is a menu
    # entry that does nothing, which is exactly what went unnoticed in
    # manage_menu for the whole of the monolith work.
    while true; do
        {
            echo "安装配置 Install configuration"
            echo "  mode:       $CERT_MODE"
            echo "  base:       $BASE_DOMAIN"
            echo "  public:     $PUBLIC_IP"
            echo "  gateway:    $GATEWAY_IP"
            echo "  listeners:  $MIHOMO_LISTEN_IPS"
            echo "  email:      ${CERT_EMAIL:-(debug: none)}"
        } | card
        choice="$(ask_choice '确认或修改 Confirm or edit' \
            '确认并继续 Confirm and continue' \
            '修改 证书模式 Certificate mode' \
            '修改 主域名 Base domain' \
            '修改 公网 IPv4 Public IPv4' \
            '修改 网关 IPv4 Gateway IPv4' \
            '修改 监听 IPv4 Listener IPv4' \
            '修改 ACME email' \
            '取消 Cancel' || true)"
        case "$choice" in
            '确认并继续'*) break ;;
            '修改 证书模式'*)
                install_tui_cert_mode || return 1
                # The mode decides whether these are asked for at all, so a
                # change re-asks rather than retaining an address that belonged
                # to the previous mode. A Cloudflare credential is requested
                # only after this complete candidate is confirmed and only if
                # certificate issuance or owned renewal actually needs it.
                install_tui_cert_email || return 1 ;;
            '修改 主域名'*)    install_tui_base_domain || return 1 ;;
            '修改 公网 IPv4'*) install_tui_public_ip "$PUBLIC_IP" || return 1 ;;
            '修改 网关 IPv4'*) install_tui_gateway_ip || return 1 ;;
            '修改 监听 IPv4'*) install_tui_listen_ips "$MIHOMO_LISTEN_IPS" || return 1 ;;
            '修改 ACME email'*) install_tui_cert_email || return 1 ;;
            '取消'*|'')
                warn "Configuration cancelled."
                return 1 ;;
        esac
    done

    if [[ "$CERT_MODE" == http-01 ]]; then
        {
            echo "HTTP-01 DNS / network prerequisites"
            echo "  ${CONSOLE_DOMAIN}  A -> ${PUBLIC_IP}"
            echo "  ${DOT_DOMAIN}      A -> ${PUBLIC_IP}"
            echo "  AAAA: none for either name (IPv4-only gateway)"
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
    export BASE_DOMAIN PUBLIC_IP GATEWAY_IP MIHOMO_LISTEN_IPS CERT_MODE CERT_EMAIL
}

resolve_install_configuration() {
    local force_tui="${1:-0}"
    if [[ -e "${CONF_DIR}/dns.env" || -L "${CONF_DIR}/dns.env" ]]; then
        load_persisted_install_config || return 1
        validate_install_config || return 1
        if [[ "$force_tui" != 1 ]]; then
            info "Using validated persisted configuration from ${CONF_DIR}/dns.env (caller environment ignored)."
            return 0
        fi
    else
        LOADED_DNS_ENV_SOURCE_STATE=absent
        LOADED_DNS_ENV_SOURCE_REVISION=absent
        LOADED_DNS_ENV_SOURCE_IDENTITY=absent
    fi
    configure_install_tui "$force_tui"
    validate_install_config
}

mihomo_config_matches_install_config() {
    local config="$MIHOMO_DIR/config.yaml" ip
    [[ -f "$config" ]] || return 0
    grep -Fq -- "$CONSOLE_DOMAIN" "$config" || return 1
    # The console must be routed to the panel, and the routing must still be the
    # shape this installer writes: engine-excluded, and nothing else.
    #
    # The exact IN-TYPE,INNER exclusion keeps captured extension traffic away
    # from the management plane. An unqualified or differently qualified rule
    # is not a current configuration.
    local console_re="${CONSOLE_DOMAIN//./\\.}"
    local allow_line deny_line
    allow_line="$(grep -nE "^[[:space:]]*-[[:space:]]*AND,\\(\\(NOT,\\(\\(IN-TYPE,INNER\\)\\)\\),\\(DOMAIN,${console_re}\\)\\),[[:space:]]*DIRECT[[:space:]]*$" "$config" | head -1 | cut -d: -f1)"
    [[ -n "$allow_line" ]] || return 1
    # A console REJECT is not disqualifying on its own: the seed ships one
    # deliberately, below the allow rule, so a captured extension excluded by the
    # rule above fails closed there rather than falling through to the loopback
    # deny for the wrong reason. What would break the panel is a REJECT first.
    deny_line="$(grep -nE "DOMAIN,[[:space:]]*${console_re},[[:space:]]*REJECT(-DROP)?" "$config" | head -1 | cut -d: -f1)"
    [[ -z "$deny_line" || "$allow_line" -lt "$deny_line" ]] || return 1
    # The current seed has no source allowlist rule-provider.
    ! grep -Eq "RULE-SET,[[:space:]]*whitelist" "$config" || return 1
    # The staged Core later validates the complete fixed controller projection
    # through inspect-controller v2. This early drift check deliberately does
    # not carry a second YAML parser.
    ! grep -Fq -- "profile.${BASE_DOMAIN}" "$config" || return 1
    # Gateway loop prevention is a dynamic Core boundary derived from dns.json;
    # operator YAML no longer contains an installer-rendered gateway /32 rule.
    while IFS= read -r ip; do
        grep -Eq "listen:[[:space:]]*${ip//./\\.}([,}[:space:]]|$)" "$config" || return 1
    done < <(printf '%s\n' "$MIHOMO_LISTEN_IPS" | tr ',' '\n')
}

# Configure is an installed-state transaction, not a reinstall. It consumes
# the already published Core and current documents, changes only the selected
# host coordinates, and never repairs a missing deployment by seeding or
# republishing release artifacts.
installed_mihomo_is_current() {
    local output first actual
    fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        || { err "The installed runtime root is not current 5gpn state."; return 1; }
    [[ -d "$BIN_DIR" && ! -L "$BIN_DIR" \
       && "$(readlink -f -- "$BIN_DIR" 2>/dev/null || true)" == "$BIN_DIR" \
       && "$(stat -Lc '%u:%g:%a' -- "$BIN_DIR" 2>/dev/null)" == 0:0:755 \
       && -f "$MIHOMO_BIN" && ! -L "$MIHOMO_BIN" \
       && "$(readlink -f -- "$MIHOMO_BIN" 2>/dev/null || true)" == "$MIHOMO_BIN" \
       && "$(stat -Lc '%u:%g:%a:%h' -- "$MIHOMO_BIN" 2>/dev/null)" == 0:0:755:1 ]] \
        || { err "The installed Core path is missing or has unsafe metadata: $MIHOMO_BIN"; return 1; }
    output="$(LC_ALL=C "$MIHOMO_BIN" -v 2>/dev/null)" \
        || { err "The installed Core did not report its version."; return 1; }
    first="${output%%$'\n'*}"
    [[ "$first" != *$'\r'* \
       && "$first" =~ ^Mihomo\ Meta\ ([^[:space:]]+)\ linux\ amd64\ with\ go[^[:space:]]+\ .+$ ]] \
        || { err "The installed Core version output is malformed."; return 1; }
    actual="${BASH_REMATCH[1]}"
    [[ "$actual" == "$MIHOMO_VERSION" ]] \
        || { err "The installed Core is ${actual}; this management backend requires ${MIHOMO_VERSION}."; return 1; }
}

configure_main_unit_restart_gate_is_current() {
    local live=/etc/systemd/system/5gpn-mihomo.service
    local staged="${BASE_DIR}/etc/systemd/5gpn-mihomo.service"
    local helper="${SCRIPTS_DIR}/configure-runtime-gate.sh"
    local ui_validator="${SCRIPTS_DIR}/ui-generation.sh" need_reload
    local live_state staged_state helper_state ui_validator_state
    root_plain_file_metadata_is_safe "$live" 0 644 \
        && root_plain_file_metadata_is_safe "$staged" 0 644 \
        && cmp -s -- "$live" "$staged" \
        || { err "Configure requires the exact installed PID1 restart-gate unit generation."; return 1; }
    grep -Fxq '# 5gpn-unit-id: 5gpn-mihomo.service:v3' "$live" \
        && [[ "$(grep -n '^ExecStartPre=' "$live" | head -1)" \
              == *'ExecStartPre=+/opt/5gpn/scripts/configure-runtime-gate.sh wait' ]] \
        && grep -Fxq 'ExecStartPre=/opt/5gpn/scripts/configure-runtime-gate.sh validate-ui' "$live" \
        && grep -Fxq 'TimeoutStartSec=40min' "$live" \
        || { err "The installed mihomo unit does not contain the current PID1 restart gate."; return 1; }
    live_state="$(release_pin_file_state "$live")" \
        || { err "Could not bind the live PID1 restart-gate unit bytes."; return 1; }
    staged_state="$(release_pin_file_state "$staged")" \
        || { err "Could not bind the staged PID1 restart-gate unit bytes."; return 1; }
    helper_state="$(installed_runtime_script_state "$helper")" \
        || { err "The installed PID1 restart-gate helper is missing or unsafe: $helper"; return 1; }
    ui_validator_state="$(installed_runtime_script_state "$ui_validator")" \
        || { err "The installed UI generation validator is missing or unsafe: $ui_validator"; return 1; }
    grep -Fxq '# 5gpn-configure-runtime-gate-id: v1' "$helper" \
        && grep -Fxq 'GATE_MAX_WAIT_SECONDS=2100' "$helper" \
        && grep -Fq 'wait|validate-ui' "$helper" \
        || { err "The installed PID1 restart-gate helper is not the current helper generation."; return 1; }
    need_reload="$(systemctl show -p NeedDaemonReload --value 5gpn-mihomo.service 2>/dev/null)" \
        || { err "Could not inspect the loaded mihomo unit generation."; return 1; }
    [[ "$need_reload" == no ]] \
        || { err "PID 1 has not loaded the installed restart-gate unit generation; run daemon-reload and retry."; return 1; }
    if [[ -z "${CONFIGURE_RUNTIME_GATE_LIVE_UNIT_STATE:-}" ]]; then
        CONFIGURE_RUNTIME_GATE_LIVE_UNIT_STATE="$live_state"
        CONFIGURE_RUNTIME_GATE_STAGED_UNIT_STATE="$staged_state"
        CONFIGURE_RUNTIME_GATE_HELPER_STATE="$helper_state"
        CONFIGURE_RUNTIME_UI_VALIDATOR_STATE="$ui_validator_state"
    else
        [[ "$live_state" == "$CONFIGURE_RUNTIME_GATE_LIVE_UNIT_STATE" \
           && "$staged_state" == "$CONFIGURE_RUNTIME_GATE_STAGED_UNIT_STATE" \
           && "$helper_state" == "$CONFIGURE_RUNTIME_GATE_HELPER_STATE" \
           && "$ui_validator_state" == "$CONFIGURE_RUNTIME_UI_VALIDATOR_STATE" ]] \
            || { err "The PID1 restart-gate unit or helper changed during configure."; return 1; }
    fi
}

configure_capture_runtime_state() {
    preflight_current_managed_unit_definition 5gpn-mihomo.service || return 1
    if systemd_unit_has_dropins 5gpn-mihomo.service; then
        err "Refusing a systemd override that changes the managed 5gpn-mihomo.service contract.${SYSTEMD_UNIT_CONFLICT_REASON:+ ($SYSTEMD_UNIT_CONFLICT_REASON)}"
        return 1
    fi
    configure_main_unit_restart_gate_is_current || return 1
    read_exact_systemd_unit_state 5gpn-mihomo.service \
        || { err "Could not inspect the current mihomo service state."; return 1; }
    [[ "$SYSTEMD_UNIT_LOAD_STATE" == loaded ]] \
        || { err "The current 5gpn-mihomo.service is not installed."; return 1; }
    case "$SYSTEMD_UNIT_FILE_STATE" in
        enabled|disabled) ;;
        *) err "The current mihomo unit file state is unsafe: $SYSTEMD_UNIT_FILE_STATE"; return 1 ;;
    esac
    CONFIGURE_RUNTIME_UNIT_FILE_STATE="$SYSTEMD_UNIT_FILE_STATE"
    case "$SYSTEMD_UNIT_ACTIVE_STATE" in
        active) CONFIGURE_RUNTIME_WAS_ACTIVE=1 ;;
        inactive) CONFIGURE_RUNTIME_WAS_ACTIVE=0 ;;
        failed)
            err "5gpn-mihomo.service is failed; repair the current deployment before changing installation coordinates."
            return 1
            ;;
        *)
            err "The mihomo service is transitioning (${SYSTEMD_UNIT_ACTIVE_STATE}); wait and rerun configure."
            return 1
            ;;
    esac
}

configure_validate_operator_config() {
    local require_selected_coordinates="${1:-1}" config="${MIHOMO_DIR}/config.yaml"
    local inspection raw_revision path_state
    [[ -f "$config" && ! -L "$config" ]] \
        || { err "A current operator-owned mihomo config is required: $config"; return 1; }
    runtime_control_file_metadata_is_safe "$config" root "$FIVEGPN_SERVICE_GROUP" 640 \
        || { err "The operator-owned mihomo config has unsafe metadata: $config"; return 1; }
    SAFE_PATHS="$MIHOMO_SAFE_PATHS" "$MIHOMO_BIN" -t -f "$config" -d "$MIHOMO_DIR" \
        || { err "The installed Core rejected the operator-owned mihomo config."; return 1; }
    inspection="$(mihomo_controller_inspection "$config")" \
        || { err "The installed Core could not inspect the current controller projection."; return 1; }
    raw_revision="$(mihomo_controller_inspection_field "$inspection" raw_revision)" || return 1
    [[ "$raw_revision" =~ ^[0-9a-f]{64}$ \
       && "$raw_revision" == "$(sha256sum "$config" | awk '{print $1}')" ]] \
        || { err "The operator config revision changed during Core inspection."; return 1; }
    if [[ "$require_selected_coordinates" == 1 ]]; then
        mihomo_config_matches_install_config \
            || { err "The operator-owned mihomo config does not match the selected domains and listener addresses."; \
                 err "Edit and validate the complete operator file explicitly, then rerun configure."; return 1; }
    fi
    path_state="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$config" 2>/dev/null)" \
        || return 1
    CONFIGURE_OPERATOR_CONFIG_STATE="${path_state}:${raw_revision}"
}

configure_revalidate_selected_operator_config() {
    local pinned_state="${CONFIGURE_OPERATOR_CONFIG_STATE:-}" observed_state
    [[ -n "$pinned_state" ]] \
        || { err "No pre-TUI operator config revision is pinned."; return 1; }
    configure_validate_operator_config 1 || return 1
    observed_state="$CONFIGURE_OPERATOR_CONFIG_STATE"
    CONFIGURE_OPERATOR_CONFIG_STATE="$pinned_state"
    [[ "$observed_state" == "$pinned_state" ]] \
        || { err "The operator-owned mihomo config changed while the configuration TUI was open."; \
             err "The concurrent file was not adopted; review it and rerun configure."; return 1; }
}

configure_assert_operator_config_revision() {
    local config="${MIHOMO_DIR}/config.yaml" path_state revision
    [[ -n "${CONFIGURE_OPERATOR_CONFIG_STATE:-}" ]] \
        || { err "No operator config revision is pinned for configure."; return 1; }
    runtime_control_file_metadata_is_safe "$config" root "$FIVEGPN_SERVICE_GROUP" 640 \
        || { err "The operator-owned mihomo config metadata changed during configure."; return 1; }
    path_state="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$config" 2>/dev/null)" \
        || return 1
    revision="$(sha256sum "$config" | awk '{print $1}')" || return 1
    [[ "${path_state}:${revision}" == "$CONFIGURE_OPERATOR_CONFIG_STATE" ]] \
        || { err "The operator-owned mihomo config changed during configure; no restart was attempted."; return 1; }
}

configure_node_lock_path_is_safe() {
    local lock="${MIHOMO_DIR}/config.yaml.5gpn-nodes.lock"
    [[ -f "$lock" && ! -L "$lock" \
       && "$(file_uid "$lock")" == 0 \
       && "$(file_gid "$lock")" == 0 \
       && "$(file_mode "$lock")" == 600 \
       && "$(file_nlink "$lock")" == 1 ]]
}

acquire_configure_node_lock() {
    local lock="${MIHOMO_DIR}/config.yaml.5gpn-nodes.lock" created=0
    command -v flock >/dev/null 2>&1 || return 1
    shared_runtime_directory_metadata_is_safe \
        "$MIHOMO_DIR" "$FIVEGPN_SERVICE_GROUP" 3770 \
        || { err "The mihomo home is unsafe before the node/configure lock."; return 1; }
    if [[ -e "$lock" || -L "$lock" ]]; then
        configure_node_lock_path_is_safe \
            || { err "The node/configure transaction lock is unsafe: $lock"; return 1; }
        exec 9<>"$lock" || return 1
    else
        set -o noclobber
        if exec 9>"$lock"; then
            created=1
        else
            set +o noclobber
            err "The node/configure transaction lock appeared concurrently."
            return 1
        fi
        set +o noclobber
        chown root:root "/proc/self/fd/9" \
            && chmod 0600 "/proc/self/fd/9" \
            && sync -f "/proc/self/fd/9" 2>/dev/null \
            || { exec 9>&-; err "Could not secure the node/configure transaction lock."; return 1; }
    fi
    configure_node_lock_path_is_safe \
        && [[ "$(stat -Lc '%d:%i' -- /proc/self/fd/9 2>/dev/null)" \
             == "$(stat -Lc '%d:%i' -- "$lock" 2>/dev/null)" ]] \
        || { exec 9>&-; err "The node/configure lock identity changed during open."; return 1; }
    flock -w "$INSTALL_LOCK_WAIT_TIMEOUT" 9 \
        || { exec 9>&-; err "Timed out waiting for the node/configure transaction lock."; return 1; }
    configure_node_lock_path_is_safe \
        && [[ "$(stat -Lc '%d:%i' -- /proc/self/fd/9 2>/dev/null)" \
             == "$(stat -Lc '%d:%i' -- "$lock" 2>/dev/null)" ]] \
        || { flock -u 9 2>/dev/null || true; exec 9>&-; \
             err "The node/configure lock changed after acquisition."; return 1; }
    CONFIGURE_NODE_LOCK_HELD=1
    [[ "$created" == 0 ]] || sync -f "$MIHOMO_DIR" 2>/dev/null \
        || { err "Could not sync the new node/configure lock directory entry."; return 1; }
}

release_configure_node_lock() {
    local rc=0
    if [[ "${CONFIGURE_NODE_LOCK_HELD:-0}" == 1 ]]; then
        configure_node_lock_path_is_safe || rc=1
        flock -u 9 2>/dev/null || rc=1
    fi
    exec 9>&- || true
    CONFIGURE_NODE_LOCK_HELD=0
    [[ "$rc" == 0 ]] \
        || { err "The node/configure lock descriptor was invalid during release."; return 1; }
}

configure_require_current_deployment() {
    local expected_gateway="$1" state_uid state_gid
    local pre_recovery_config_state pre_recovery_dns_revision
    fixed_owned_dir_is_safe "$BASE_DIR" "$BASE_OWNERSHIP_MARKER" "$BASE_OWNERSHIP_VALUE" \
        && fixed_owned_dir_is_safe "$CONF_DIR" "$CONF_OWNERSHIP_MARKER" "$CONF_OWNERSHIP_VALUE" \
        || { err "Configure requires current owned 5gpn installation roots."; return 1; }
    [[ "$(stat -Lc '%u:%g:%a' -- "$CONF_DIR" 2>/dev/null)" == 0:0:755 \
       && "$(stat -Lc '%u:%g:%a:%h' -- "${CONF_DIR}/dns.env" 2>/dev/null)" == 0:0:600:1 ]] \
        || { err "Configure refuses an incomplete configuration-root reconciliation state."; return 1; }
    persisted_dns_env_is_safe \
        || { err "Configure requires a current owned ${CONF_DIR}/dns.env."; return 1; }
    getent passwd "$FIVEGPN_SERVICE_USER" >/dev/null 2>&1 \
        && getent group "$FIVEGPN_SERVICE_GROUP" >/dev/null 2>&1 \
        && managed_user_uid_is_exclusive "$FIVEGPN_SERVICE_USER" \
        && managed_primary_gid_is_exclusive_for_user "$FIVEGPN_SERVICE_USER" \
        || { err "Configure requires the current exclusive fivegpn runtime identity."; return 1; }
    shared_runtime_directory_metadata_is_safe "$MIHOMO_DIR" "$FIVEGPN_SERVICE_GROUP" 3770 \
        || { err "Configure requires the current mihomo home boundary."; return 1; }
    state_uid="$(account_uid "$FIVEGPN_SERVICE_USER")"
    state_gid="$(account_gid "$FIVEGPN_SERVICE_GROUP")"
    [[ -n "$state_uid" && -n "$state_gid" \
       && -d "$FIVEGPN_STATE_DIR" && ! -L "$FIVEGPN_STATE_DIR" \
       && "$(file_uid "$FIVEGPN_STATE_DIR")" == "$state_uid" \
       && "$(file_gid "$FIVEGPN_STATE_DIR")" == "$state_gid" \
       && "$(file_mode "$FIVEGPN_STATE_DIR")" == 711 ]] \
        || { err "Configure requires the current Core state directory."; return 1; }
    runtime_tree_has_only_plain_entries "$FIVEGPN_STATE_DIR" \
        || { err "The Core state directory contains an unsafe link, hardlink, or special entry."; return 1; }
    [[ -f "${MIHOMO_DIR}/config.yaml" && ! -L "${MIHOMO_DIR}/config.yaml" ]] \
        || { err "Configure cannot seed a missing operator-owned mihomo config."; return 1; }
    [[ -f "${FIVEGPN_STATE_DIR}/dns.json" && ! -L "${FIVEGPN_STATE_DIR}/dns.json" ]] \
        || { err "Configure cannot seed a missing DNS document."; return 1; }
    installed_mihomo_is_current || return 1
    configure_validate_operator_config 0 || return 1
    pre_recovery_config_state="$CONFIGURE_OPERATOR_CONFIG_STATE"
    validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core" || return 1
    [[ "$VALIDATED_DNS_SOURCE_REVISION" =~ ^[0-9a-f]{64}$ ]] \
        || { err "Configure requires an existing Core-validated DNS document."; return 1; }
    pre_recovery_dns_revision="$VALIDATED_DNS_SOURCE_REVISION"
    jq -e --arg gateway "$expected_gateway" '.gateway == $gateway' \
        "${FIVEGPN_STATE_DIR}/dns.json" >/dev/null \
        || { err "dns.env and dns.json disagree on the current gateway; repair that drift explicitly before configure."; return 1; }
    command -v busctl >/dev/null 2>&1 \
        || { err "Configure requires the systemd busctl client for exact restart-job ownership."; return 1; }
    configure_main_unit_restart_gate_is_current || return 1
    # Recover only after the offline Core gates above. If recovery starts the
    # previously active runtime, every pinned input is compared again and a
    # failed comparison stops that recovered process before returning.
    CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=0
    recover_stale_configure_runtime_fence || return 1
    configure_capture_runtime_state \
        || { configure_stop_runtime_recovered_from_stale_fence || true; return 1; }
    configure_validate_operator_config 0 \
        || { configure_stop_runtime_recovered_from_stale_fence || true; return 1; }
    [[ "$CONFIGURE_OPERATOR_CONFIG_STATE" == "$pre_recovery_config_state" ]] \
        || { err "The operator YAML changed across retained-fence recovery."; \
             configure_stop_runtime_recovered_from_stale_fence || true; return 1; }
    validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core" \
        || { configure_stop_runtime_recovered_from_stale_fence || true; return 1; }
    [[ "$VALIDATED_DNS_SOURCE_REVISION" =~ ^[0-9a-f]{64}$ ]] \
        || { err "Configure requires an existing Core-validated DNS document."; \
             configure_stop_runtime_recovered_from_stale_fence || true; return 1; }
    [[ "$VALIDATED_DNS_SOURCE_REVISION" == "$pre_recovery_dns_revision" ]] \
        || { err "The DNS document changed across retained-fence recovery."; \
             configure_stop_runtime_recovered_from_stale_fence || true; return 1; }
    jq -e --arg gateway "$expected_gateway" '.gateway == $gateway' \
        "${FIVEGPN_STATE_DIR}/dns.json" >/dev/null \
        || { err "dns.env and dns.json disagree on the current gateway; repair that drift explicitly before configure."; \
             configure_stop_runtime_recovered_from_stale_fence || true; return 1; }
    CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=0
}

configure_plan_changes() {
    local old_base="$1" old_public="$2" old_gateway="$3" old_listen="$4"
    local old_mode="$5" old_email="$6" new_base="$7" new_public="$8"
    local new_gateway="$9" new_listen="${10}" new_mode="${11}" new_email="${12}"
    local base_changed=0 public_changed=0 gateway_changed=0 listen_changed=0
    local mode_changed=0 email_changed=0 debug_ip_changed=0
    [[ "$old_base" == "$new_base" ]] || base_changed=1
    [[ "$old_public" == "$new_public" ]] || public_changed=1
    [[ "$old_gateway" == "$new_gateway" ]] || gateway_changed=1
    [[ "$old_listen" == "$new_listen" ]] || listen_changed=1
    [[ "$old_mode" == "$new_mode" ]] || mode_changed=1
    [[ "$old_email" == "$new_email" ]] || email_changed=1
    if [[ "$new_mode" == debug && ( "$public_changed" == 1 || "$gateway_changed" == 1 ) ]]; then
        debug_ip_changed=1
    fi

    CONFIGURE_DNS_ENV_CHANGED=$((base_changed || public_changed || gateway_changed || listen_changed || mode_changed || email_changed))
    CONFIGURE_DNS_GATE_REQUIRED=$((base_changed || public_changed || mode_changed))
    CONFIGURE_GATEWAY_CHANGED="$gateway_changed"
    CONFIGURE_CERT_CHANGED=$((base_changed || mode_changed || debug_ip_changed))
    CONFIGURE_PROFILE_CHANGED=$((CONFIGURE_CERT_CHANGED || gateway_changed))
    CONFIGURE_RESTART_REQUIRED=$((base_changed || mode_changed || gateway_changed || listen_changed || debug_ip_changed))
    CONFIGURE_ANY_CHANGE="$CONFIGURE_DNS_ENV_CHANGED"
}

configure_certificate_selection_state() {
    local artifacts=0 owned=0 preserved=0 credential_required=0
    certbot_lineage_artifacts_exist "$BASE_DOMAIN" && artifacts=1
    certbot_lineage_owned_by_5gpn "$BASE_DOMAIN" && owned=1
    if [[ "$artifacts" == 0 && "$CERT_MODE" != debug ]] \
       && cert_provenance_matches "$CERT_MODE" "$BASE_DOMAIN" \
       && validate_cert_pair \
            "${DOT_CERT_DIR}/current/fullchain.pem" \
            "${DOT_CERT_DIR}/current/privkey.pem" \
            "$BASE_DOMAIN" "$((30*86400))" production "$CERT_MODE"; then
        preserved=1
    fi
    cloudflare_credential_required_for_install "$BASE_DOMAIN" \
        && credential_required=1
    printf '%s|%s|%s|%s|%s|%s\n' \
        "$CERT_MODE" "$BASE_DOMAIN" "$artifacts" "$owned" \
        "$preserved" "$credential_required"
}

configure_capture_certificate_selection() {
    CONFIGURE_CERTIFICATE_SELECTION_STATE="$(configure_certificate_selection_state)" \
        || return 1
    [[ -n "$CONFIGURE_CERTIFICATE_SELECTION_STATE" ]]
}

configure_assert_certificate_selection() {
    local observed
    [[ -n "${CONFIGURE_CERTIFICATE_SELECTION_STATE:-}" ]] \
        || { err "No certificate selection is pinned for configure."; return 1; }
    observed="$(configure_certificate_selection_state)" || return 1
    [[ "$observed" == "$CONFIGURE_CERTIFICATE_SELECTION_STATE" ]] \
        || { err "Certificate lineage ownership or reuse state changed while configure waited for its locks."; return 1; }
}

configure_collect_pending_cf_token() {
    PENDING_CF_TOKEN=""
    [[ "$CONFIGURE_CERT_CHANGED" == 1 && "$CERT_MODE" == cloudflare ]] \
        || return 0
    cloudflare_credential_required_for_install "$BASE_DOMAIN" || return 0
    if has_valid_cf_credential; then
        info "Reusing the saved Cloudflare API token after the locked publication recheck."
        return 0
    fi
    local tok=""
    [[ -t 0 ]] \
        && tok="$(ask_secret 'Cloudflare API token (Zone:DNS:Edit scope for your base zone):' || true)"
    if [[ -z "$tok" || ! "$tok" =~ [^[:space:]] ]]; then
        err "No Cloudflare API token. Run the attached-terminal TUI; shell environment tokens are not accepted."
        return 1
    fi
    if [[ "$tok" =~ $'\r' || "$tok" =~ $'\n' ]]; then
        err "Cloudflare API token must not contain CR or LF (check for a trailing newline)."
        return 1
    fi
    PENDING_CF_TOKEN="$tok"
    info "Cloudflare API token retained only in memory until the locked final recheck."
}

configure_commit_pending_cf_token() {
    [[ "${CONFIGURE_NODE_LOCK_HELD:-0}" == 1 \
       && "$INSTALL_CERT_LOCK_HELD" == 1 ]] \
        || { err "Cloudflare credential publication requires both configure locks."; return 1; }
    configure_assert_certificate_selection || return 1
    cloudflare_credential_required_for_install "$BASE_DOMAIN" || return 0
    if has_valid_cf_credential; then
        PENDING_CF_TOKEN=""
        return 0
    fi
    [[ -n "${PENDING_CF_TOKEN:-}" ]] \
        || { err "The confirmed Cloudflare credential candidate is no longer available."; return 1; }
    write_cf_credential "$PENDING_CF_TOKEN" || return 1
    PENDING_CF_TOKEN=""
    has_valid_cf_credential \
        || { err "The locked Cloudflare credential publication could not be verified."; return 1; }
    ok "Cloudflare API token saved after the locked final recheck."
}

configure_update_existing_dns_gateway() {
    local target="${FIVEGPN_STATE_DIR}/dns.json" state_dir="$FIVEGPN_STATE_DIR"
    local source_revision current_revision tmp
    CONFIGURE_DNS_GATEWAY_COMMIT_STATE=not-committed
    configure_assert_runtime_gate_quiescent \
        || { err "Gateway publication requires a PID1-gated quiescent Core writer boundary."; return 1; }
    configure_runtime_start_fence_is_active \
        || { err "Gateway publication requires the temporary PID1 mihomo start gate."; return 1; }
    [[ "$VALIDATED_DNS_SOURCE_REVISION" =~ ^[0-9a-f]{64}$ ]] \
        || { err "The existing DNS document has no pinned installed-Core revision."; return 1; }
    runtime_control_file_metadata_is_safe "$target" \
        "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" 600 \
        || { err "The existing DNS document has unsafe metadata."; return 1; }
    source_revision="$(sha256sum "$target" | awk '{print $1}')" || return 1
    [[ "$source_revision" == "$VALIDATED_DNS_SOURCE_REVISION" ]] \
        || { err "The DNS document changed after the configure snapshot was validated."; return 1; }
    current_dns_document_is_compatible "$target" \
        || { err "The DNS document's fixed listener or certificate fields drifted."; return 1; }
    jq -e --arg gateway "$GATEWAY_IP" '.gateway == $gateway' "$target" >/dev/null \
        && return 0
    dns_document_is_jq_gateway_update_safe "$target" \
        || { err "The DNS document cannot be preserved exactly by the gateway-only updater."; return 1; }
    tmp="$(mktemp "${state_dir}/.dns.json.configure.XXXXXX")" \
        || { err "Could not create the DNS gateway candidate."; return 1; }
    jq --arg gateway "$GATEWAY_IP" '.gateway = $gateway' "$target" > "$tmp" \
        || { rm -f -- "$tmp"; err "Could not render the DNS gateway candidate."; return 1; }
    current_dns_document_is_compatible "$tmp" \
        && jq -e --arg gateway "$GATEWAY_IP" '.gateway == $gateway' "$tmp" >/dev/null \
        || { rm -f -- "$tmp"; err "The DNS gateway candidate failed the fixed-field boundary."; return 1; }
    chown "$FIVEGPN_SERVICE_USER:$FIVEGPN_SERVICE_GROUP" "$tmp" \
        && chmod 0600 "$tmp" \
        && sync -f "$tmp" 2>/dev/null \
        || { rm -f -- "$tmp"; err "Could not secure or sync the DNS gateway candidate."; return 1; }
    validate_dns_candidate_with_installed_core "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
    runtime_control_file_metadata_is_safe "$target" \
        "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" 600 \
        || { rm -f -- "$tmp"; err "The DNS document metadata changed before gateway publication."; return 1; }
    configure_assert_runtime_gate_quiescent \
        || { rm -f -- "$tmp"; err "A Core writer reappeared before the gateway rename."; return 1; }
    configure_runtime_start_fence_is_active \
        || { rm -f -- "$tmp"; err "The PID1-owned mihomo restart gate disappeared before the gateway rename."; return 1; }
    current_revision="$(sha256sum "$target" | awk '{print $1}')" \
        || { rm -f -- "$tmp"; return 1; }
    [[ "$current_revision" == "$source_revision" ]] \
        && current_dns_document_is_compatible "$target" \
        || { rm -f -- "$tmp"; err "The DNS document changed while its gateway candidate was staged."; return 1; }
    configure_disarm_runtime_restore_for_coordinate_commit \
        || { rm -f -- "$tmp"; err "Could not disarm stale-gate recovery at the DNS commit boundary."; return 1; }
    if ! mv -Tf -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        configure_rearm_runtime_restore_after_failed_commit || true
        err "Could not atomically publish the DNS gateway update."
        return 1
    fi
    CONFIGURE_DNS_GATEWAY_COMMIT_STATE=committed-undurable
    sync -f "$state_dir" 2>/dev/null \
        || { err "The DNS gateway update is visible but its directory sync failed; it was not rolled back."; return 1; }
    CONFIGURE_DNS_GATEWAY_COMMIT_STATE=committed
    runtime_control_file_metadata_is_safe "$target" \
        "$FIVEGPN_SERVICE_USER" "$FIVEGPN_SERVICE_GROUP" 600 \
        && current_dns_document_is_compatible "$target" \
        && jq -e --arg gateway "$GATEWAY_IP" '.gateway == $gateway' "$target" >/dev/null \
        || { err "The published DNS gateway update failed validation."; return 1; }
    VALIDATED_DNS_SOURCE_REVISION="$(sha256sum "$target" | awk '{print $1}')" || return 1
    ok "Updated only the installation-owned DNS gateway field."
}

configure_require_selected_dependencies() {
    local cmd
    for cmd in openssl jq flock timeout findmnt sync busctl; do
        command -v "$cmd" >/dev/null 2>&1 \
            || { err "Configure requires the already installed command: $cmd"; return 1; }
    done
    if [[ "$CONFIGURE_DNS_GATE_REQUIRED" == 1 && "$CERT_MODE" != debug ]]; then
        command -v dig >/dev/null 2>&1 \
            || { err "Production coordinate changes require the already installed dig command."; return 1; }
    fi
    if [[ "$CONFIGURE_CERT_CHANGED" == 1 && "$CERT_MODE" != debug ]]; then
        command -v certbot >/dev/null 2>&1 && certbot --version >/dev/null 2>&1 \
            || { err "Production certificate changes require an already installed working Certbot."; return 1; }
        if [[ "$CERT_MODE" == cloudflare ]]; then
            certbot plugins 2>/dev/null | grep -q dns-cloudflare \
                || { err "Cloudflare certificate changes require the already installed dns-cloudflare plugin."; return 1; }
        fi
    fi
}

configure_preflight_selected_runtime_helpers() {
    local generator="${SCRIPTS_DIR}/gen-ios-profile.sh" helper unit
    if [[ "$CONFIGURE_CERT_CHANGED" == 1 ]]; then
        load_cert_role_helpers \
            || { err "Current certificate publication helpers are required before certificate changes."; return 1; }
        for helper in renew-hook.sh cert-renew.sh; do
            installed_runtime_script_state "${SCRIPTS_DIR}/${helper}" >/dev/null \
                || { err "Installed certificate helper is missing or unsafe: ${SCRIPTS_DIR}/${helper}"; return 1; }
        done
        for unit in 5gpn-certbot-renew.service 5gpn-certbot-renew.timer; do
            preflight_current_managed_unit_definition "$unit" || return 1
            if systemd_unit_has_dropins "$unit"; then
                err "Refusing a systemd override that changes the managed ${unit} certificate contract.${SYSTEMD_UNIT_CONFLICT_REASON:+ ($SYSTEMD_UNIT_CONFLICT_REASON)}"
                return 1
            fi
        done
    fi
    if [[ "$CONFIGURE_PROFILE_CHANGED" == 1 ]]; then
        load_ui_generation_helper \
            && _ui_generation_current_only_is_safe "$UI_DIR" \
            || { err "A valid current UI/profile generation is required before profile changes."; return 1; }
        installed_runtime_script_state "$generator" >/dev/null \
            || { err "The installed profile generator is missing or unsafe: $generator"; return 1; }
    fi
}

configure_assert_runtime_state_before_publication() {
    read_exact_systemd_unit_state 5gpn-mihomo.service \
        || { err "Could not re-read mihomo state before configuration publication."; return 1; }
    [[ "$SYSTEMD_UNIT_LOAD_STATE" == loaded ]] \
        || { err "The managed mihomo unit disappeared during configure."; return 1; }
    case "${CONFIGURE_RUNTIME_WAS_ACTIVE:-0}:${SYSTEMD_UNIT_ACTIVE_STATE}" in
        1:active|1:inactive|0:inactive) return 0 ;;
        0:active)
            err "5gpn-mihomo was started outside this transaction; refusing to publish coordinates against an unpinned live generation."
            return 1
            ;;
        *:failed)
            err "5gpn-mihomo entered failed state during configure; no coordinate publication was attempted."
            return 1
            ;;
        *)
            err "5gpn-mihomo is transitioning (${SYSTEMD_UNIT_ACTIVE_STATE}); no coordinate publication was attempted."
            return 1
            ;;
    esac
}

configure_read_mihomo_runtime_state() {
    CONFIGURE_MIHOMO_ACTIVE_STATE="$(systemctl show -p ActiveState --value \
        5gpn-mihomo.service 2>/dev/null)" \
        || { err "Could not read mihomo ActiveState."; return 1; }
    CONFIGURE_MIHOMO_SUB_STATE="$(systemctl show -p SubState --value \
        5gpn-mihomo.service 2>/dev/null)" \
        || { err "Could not read mihomo SubState."; return 1; }
    CONFIGURE_MIHOMO_UNIT_FILE_STATE="$(systemctl show -p UnitFileState --value \
        5gpn-mihomo.service 2>/dev/null)" \
        || { err "Could not read mihomo UnitFileState."; return 1; }
    CONFIGURE_MIHOMO_CONTROL_PID="$(systemctl show -p ControlPID --value \
        5gpn-mihomo.service 2>/dev/null)" \
        || { err "Could not read mihomo ControlPID."; return 1; }
    [[ -n "$CONFIGURE_MIHOMO_ACTIVE_STATE" \
       && -n "$CONFIGURE_MIHOMO_SUB_STATE" \
       && -n "$CONFIGURE_MIHOMO_UNIT_FILE_STATE" \
       && "$CONFIGURE_MIHOMO_CONTROL_PID" =~ ^[0-9]+$ ]] \
        || { err "Mihomo runtime state is incomplete."; return 1; }
}

configure_runtime_fence_private_dir() {
    local fence_dir lock_dir parent_mount fence_mount
    fence_dir="$(dirname -- "$CONFIGURE_RUNTIME_GATE_RECORD")" || return 1
    lock_dir="$(dirname -- "$INSTALL_LOCK_FILE")" || return 1
    [[ "$fence_dir" == "$lock_dir" && "$fence_dir" == /* && "$fence_dir" != / ]] \
        || return 1
    parent_mount="$(findmnt -rn -T "$(dirname -- "$fence_dir")" -o TARGET 2>/dev/null)" \
        || return 1
    fence_mount="$(findmnt -rn -T "$fence_dir" -o TARGET 2>/dev/null)" \
        || return 1
    [[ -n "$parent_mount" && "$fence_mount" == "$parent_mount" ]] || return 1
    printf '%s\n' "$fence_dir"
}

configure_repair_runtime_gate_link_residue() {
    local fence_dir temp target temp_identity target_identity matched_target=""
    local nlink matches changed=0
    local -a temps=() targets=(
        "$CONFIGURE_RUNTIME_GATE_RECORD"
        "$CONFIGURE_RUNTIME_GATE_JOB"
        "$CONFIGURE_RUNTIME_GATE_ACK"
        "$CONFIGURE_RUNTIME_GATE_RELEASE"
    )
    fence_dir="$(configure_runtime_fence_private_dir)" || return 1
    shopt -s nullglob
    temps=(
        "$fence_dir"/.configure-runtime-gate.??????
        "$fence_dir"/.configure-runtime-gate.job.??????
        "$fence_dir"/.configure-runtime-gate.ack.??????
        "$fence_dir"/.configure-runtime-gate.close.??????
    )
    shopt -u nullglob
    for temp in "${temps[@]}"; do
        [[ -f "$temp" && ! -L "$temp" \
           && "$(stat -Lc '%u:%g:%a' -- "$temp" 2>/dev/null)" == 0:0:600 ]] \
            || { err "Unsafe PID1 gate publication residue: $temp"; return 1; }
        nlink="$(file_nlink "$temp")"
        [[ "$nlink" == 1 || "$nlink" == 2 ]] \
            || { err "Unexpected PID1 gate residue link count: $temp"; return 1; }
        temp_identity="$(stat -Lc '%d:%i' -- "$temp" 2>/dev/null)" || return 1
        matches=0
        matched_target=""
        for target in "${targets[@]}"; do
            [[ -f "$target" && ! -L "$target" ]] || continue
            target_identity="$(stat -Lc '%d:%i' -- "$target" 2>/dev/null)" || return 1
            if [[ "$target_identity" == "$temp_identity" ]]; then
                matches=$((matches + 1))
                matched_target="$target"
            fi
        done
        if [[ "$nlink" == 1 ]]; then
            [[ "$matches" == 0 ]] \
                || { err "Single-link PID1 gate residue aliases a published target: $temp"; return 1; }
        else
            [[ "$matches" == 1 \
               && "$(stat -Lc '%u:%g:%a:%h' -- "$matched_target" 2>/dev/null)" == 0:0:600:2 ]] \
                || { err "PID1 gate residue does not match one exact publication target: $temp"; return 1; }
        fi
        rm -f -- "$temp" || return 1
        if [[ -n "$matched_target" ]]; then
            root_plain_file_metadata_is_safe "$matched_target" 0 600 \
                || { err "Recovered PID1 gate target metadata is unsafe: $matched_target"; return 1; }
        fi
        changed=1
    done
    [[ "$changed" == 0 ]] || sync -f "$fence_dir" 2>/dev/null
}

configure_publish_private_runtime_gate_file() {
    local path="$1" contents="$2" tmp fence_dir
    fence_dir="$(configure_runtime_fence_private_dir)" || return 1
    [[ "$path" == "$fence_dir"/* \
       && ! -e "$path" && ! -L "$path" ]] || return 1
    tmp="$(mktemp "${fence_dir}/.configure-runtime-gate.XXXXXX")" || return 1
    if ! printf '%s' "$contents" > "$tmp" \
       || ! chown root:root "$tmp" \
       || ! chmod 0600 "$tmp" \
       || ! sync -f "$tmp" 2>/dev/null \
       || ! ln -- "$tmp" "$path"; then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp" || return 1
    sync -f "$fence_dir" 2>/dev/null || return 1
    root_plain_file_metadata_is_safe "$path" 0 600
}

configure_close_runtime_gate_record() {
    local token tmp fence_dir
    configure_runtime_gate_record_is_safe open || return 1
    token="$CONFIGURE_RUNTIME_GATE_TOKEN"
    fence_dir="$(configure_runtime_fence_private_dir)" || return 1
    tmp="$(mktemp "${fence_dir}/.configure-runtime-gate.close.XXXXXX")" || return 1
    if ! printf 'version=1\ntoken=%s\nunit=%s\nstate=closing\n' \
            "$token" "$CONFIGURE_RUNTIME_GATE_UNIT" > "$tmp" \
       || ! chown root:root "$tmp" \
       || ! chmod 0600 "$tmp" \
       || ! sync -f "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    configure_runtime_gate_record_is_safe open \
        && [[ "$CONFIGURE_RUNTIME_GATE_TOKEN" == "$token" ]] \
        || { rm -f -- "$tmp"; return 1; }
    mv -Tf -- "$tmp" "$CONFIGURE_RUNTIME_GATE_RECORD" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$fence_dir" 2>/dev/null || return 1
    configure_runtime_gate_record_is_safe closing \
        && [[ "$CONFIGURE_RUNTIME_GATE_TOKEN" == "$token" ]]
}

configure_runtime_gate_record_is_safe() {
    local expected_mode="${1:-open}" token fence_dir
    local -a lines=()
    [[ "$expected_mode" == open || "$expected_mode" == closing ]] || return 1
    fence_dir="$(configure_runtime_fence_private_dir)" || return 1
    root_plain_file_metadata_is_safe "$CONFIGURE_RUNTIME_GATE_RECORD" 0 600 \
        || return 1
    mapfile -t lines < "$CONFIGURE_RUNTIME_GATE_RECORD" || return 1
    if [[ "$expected_mode" == open ]]; then
        [[ "${#lines[@]}" == 3 \
           && "${lines[0]}" == version=1 \
           && "${lines[1]}" == token=* \
           && "${lines[2]}" == "unit=${CONFIGURE_RUNTIME_GATE_UNIT}" ]] || return 1
    else
        [[ "${#lines[@]}" == 4 \
           && "${lines[0]}" == version=1 \
           && "${lines[1]}" == token=* \
           && "${lines[2]}" == "unit=${CONFIGURE_RUNTIME_GATE_UNIT}" \
           && "${lines[3]}" == state=closing ]] || return 1
    fi
    token="${lines[1]#token=}"
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
    CONFIGURE_RUNTIME_GATE_TOKEN="$token"
    CONFIGURE_RUNTIME_GATE_RECORD_MODE="$expected_mode"
}

configure_runtime_gate_job_record_is_safe() {
    local record_mode="${1:-open}" token job_id job_path method restore_active
    local -a lines=()
    configure_runtime_gate_record_is_safe "$record_mode" || return 1
    root_plain_file_metadata_is_safe "$CONFIGURE_RUNTIME_GATE_JOB" 0 600 \
        || return 1
    mapfile -t lines < "$CONFIGURE_RUNTIME_GATE_JOB" || return 1
    [[ "${#lines[@]}" == 6 \
       && "${lines[0]}" == version=1 \
       && "${lines[1]}" == token=* \
       && "${lines[2]}" == job_id=* \
       && "${lines[3]}" == job_path=* \
       && "${lines[4]}" == method=* \
       && "${lines[5]}" == restore_active=* ]] || return 1
    token="${lines[1]#token=}"
    job_id="${lines[2]#job_id=}"
    job_path="${lines[3]#job_path=}"
    method="${lines[4]#method=}"
    restore_active="${lines[5]#restore_active=}"
    [[ "$token" == "$CONFIGURE_RUNTIME_GATE_TOKEN" \
       && ( "$restore_active" == 0 || "$restore_active" == 1 ) ]] || return 1
    if [[ "$job_id" == 0 ]]; then
        [[ "$job_path" == / && "$method" == none && "$restore_active" == 0 ]] \
            || return 1
    else
        [[ "$job_id" =~ ^[1-9][0-9]*$ \
           && "$job_path" == "/org/freedesktop/systemd1/job/${job_id}" \
           && "$method" == TryRestartUnit ]] || return 1
    fi
    CONFIGURE_RUNTIME_GATE_JOB_ID="$job_id"
    CONFIGURE_RUNTIME_GATE_JOB_PATH="$job_path"
    CONFIGURE_RUNTIME_GATE_JOB_METHOD="$method"
    CONFIGURE_RUNTIME_FENCE_RESTORE_ACTIVE="$restore_active"
}

configure_runtime_gate_ack_is_safe() {
    local record_mode="${1:-open}" token pid invocation
    local -a lines=()
    configure_runtime_gate_record_is_safe "$record_mode" || return 1
    root_plain_file_metadata_is_safe "$CONFIGURE_RUNTIME_GATE_ACK" 0 600 \
        || return 1
    mapfile -t lines < "$CONFIGURE_RUNTIME_GATE_ACK" || return 1
    [[ "${#lines[@]}" == 4 \
       && "${lines[0]}" == version=1 \
       && "${lines[1]}" == token=* \
       && "${lines[2]}" == pid=* \
       && "${lines[3]}" == invocation_id=* ]] || return 1
    token="${lines[1]#token=}"
    pid="${lines[2]#pid=}"
    invocation="${lines[3]#invocation_id=}"
    [[ "$token" == "$CONFIGURE_RUNTIME_GATE_TOKEN" \
       && "$pid" =~ ^[1-9][0-9]*$ \
       && "$invocation" =~ ^[0-9a-f]{32}$ ]] || return 1
    CONFIGURE_RUNTIME_GATE_ACK_PID="$pid"
    CONFIGURE_RUNTIME_GATE_INVOCATION_ID="$invocation"
}

configure_runtime_gate_release_is_safe() {
    local record_mode="${1:-open}" token
    local -a lines=()
    configure_runtime_gate_record_is_safe "$record_mode" || return 1
    root_plain_file_metadata_is_safe "$CONFIGURE_RUNTIME_GATE_RELEASE" 0 600 \
        || return 1
    mapfile -t lines < "$CONFIGURE_RUNTIME_GATE_RELEASE" || return 1
    [[ "${#lines[@]}" == 2 \
       && "${lines[0]}" == version=1 \
       && "${lines[1]}" == token=* ]] || return 1
    token="${lines[1]#token=}"
    [[ "$token" == "$CONFIGURE_RUNTIME_GATE_TOKEN" ]]
}

configure_replace_runtime_gate_job_record() {
    local job_id="$1" job_path="$2" method="$3" restore_active="$4"
    local tmp fence_dir
    configure_runtime_gate_job_record_is_safe || return 1
    fence_dir="$(configure_runtime_fence_private_dir)" || return 1
    tmp="$(mktemp "${fence_dir}/.configure-runtime-gate.job.XXXXXX")" || return 1
    if ! printf 'version=1\ntoken=%s\njob_id=%s\njob_path=%s\nmethod=%s\nrestore_active=%s\n' \
            "$CONFIGURE_RUNTIME_GATE_TOKEN" "$job_id" "$job_path" "$method" "$restore_active" > "$tmp" \
       || ! chown root:root "$tmp" \
       || ! chmod 0600 "$tmp" \
       || ! sync -f "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    configure_runtime_gate_job_record_is_safe \
        || { rm -f -- "$tmp"; return 1; }
    mv -Tf -- "$tmp" "$CONFIGURE_RUNTIME_GATE_JOB" \
        || { rm -f -- "$tmp"; return 1; }
    sync -f "$fence_dir" 2>/dev/null || return 1
    configure_runtime_gate_job_record_is_safe \
        && [[ "$CONFIGURE_RUNTIME_GATE_JOB_ID" == "$job_id" \
           && "$CONFIGURE_RUNTIME_GATE_JOB_PATH" == "$job_path" \
           && "$CONFIGURE_RUNTIME_GATE_JOB_METHOD" == "$method" \
           && "$CONFIGURE_RUNTIME_FENCE_RESTORE_ACTIVE" == "$restore_active" ]]
}

configure_update_runtime_fence_restore_entitlement() {
    local value="$1"
    [[ "$value" == 0 || "$value" == 1 ]] || return 1
    configure_runtime_gate_job_record_is_safe || return 1
    [[ "$CONFIGURE_RUNTIME_GATE_JOB_ID" != 0 || "$value" == 0 ]] || return 1
    [[ "$CONFIGURE_RUNTIME_FENCE_RESTORE_ACTIVE" == "$value" ]] && return 0
    configure_replace_runtime_gate_job_record \
        "$CONFIGURE_RUNTIME_GATE_JOB_ID" "$CONFIGURE_RUNTIME_GATE_JOB_PATH" \
        "$CONFIGURE_RUNTIME_GATE_JOB_METHOD" "$value"
}

configure_systemd_job_is_exact() {
    local id_property unit_name unit_path unit_job_id unit_job_path
    local type_property state_property lookup unit_property
    configure_runtime_gate_job_record_is_safe || return 1
    [[ "$CONFIGURE_RUNTIME_GATE_JOB_ID" != 0 ]] || return 1
    lookup="$(busctl --system --json=short call org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetJob \
        u "$CONFIGURE_RUNTIME_GATE_JOB_ID" 2>/dev/null \
        | jq -er 'select(.type == "o") | .data | select(type == "array" and length == 1) | .[0]')" \
        || return 1
    [[ "$lookup" == "$CONFIGURE_RUNTIME_GATE_JOB_PATH" ]] || return 1
    id_property="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$CONFIGURE_RUNTIME_GATE_JOB_PATH" org.freedesktop.systemd1.Job Id 2>/dev/null \
        | jq -er 'select(.type == "u") | .data | select(type == "number") | tostring')" \
        || return 1
    unit_property="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$CONFIGURE_RUNTIME_GATE_JOB_PATH" org.freedesktop.systemd1.Job Unit 2>/dev/null \
        | jq -cer 'select(.type == "(so)") | .data | select(type == "array" and length == 2)')" \
        || return 1
    unit_name="$(jq -er '.[0] | select(type == "string")' <<<"$unit_property")" || return 1
    unit_path="$(jq -er '.[1] | select(type == "string" and startswith("/org/freedesktop/systemd1/unit/"))' \
        <<<"$unit_property")" || return 1
    unit_property="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$unit_path" org.freedesktop.systemd1.Unit Job 2>/dev/null \
        | jq -cer 'select(.type == "(uo)") | .data | select(type == "array" and length == 2)')" \
        || return 1
    unit_job_id="$(jq -er '.[0] | select(type == "number") | tostring' <<<"$unit_property")" \
        || return 1
    unit_job_path="$(jq -er '.[1] | select(type == "string")' <<<"$unit_property")" \
        || return 1
    type_property="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$CONFIGURE_RUNTIME_GATE_JOB_PATH" org.freedesktop.systemd1.Job JobType 2>/dev/null \
        | jq -er 'select(.type == "s") | .data | select(type == "string")')" \
        || return 1
    state_property="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$CONFIGURE_RUNTIME_GATE_JOB_PATH" org.freedesktop.systemd1.Job State 2>/dev/null \
        | jq -er 'select(.type == "s") | .data | select(type == "string")')" \
        || return 1
    [[ "$id_property" == "$CONFIGURE_RUNTIME_GATE_JOB_ID" \
       && "$unit_name" == "$CONFIGURE_RUNTIME_GATE_UNIT" \
       && "$unit_job_id" == "$CONFIGURE_RUNTIME_GATE_JOB_ID" \
       && "$unit_job_path" == "$CONFIGURE_RUNTIME_GATE_JOB_PATH" \
       && ( "$type_property" == try-restart \
            || "$type_property" == restart \
            || "$type_property" == start ) \
       && ( "$state_property" == waiting || "$state_property" == running ) ]]
}

configure_runtime_gate_ack_matches_control_process() {
    local invocation
    configure_systemd_job_is_exact || return 1
    configure_runtime_gate_ack_is_safe || return 1
    configure_read_mihomo_runtime_state || return 1
    invocation="$(systemctl show -p InvocationID --value \
        5gpn-mihomo.service 2>/dev/null)" || return 1
    [[ "$CONFIGURE_MIHOMO_ACTIVE_STATE" == activating \
       && "$CONFIGURE_MIHOMO_SUB_STATE" == start-pre \
       && "$CONFIGURE_MIHOMO_CONTROL_PID" == "$CONFIGURE_RUNTIME_GATE_ACK_PID" \
       && "$invocation" == "$CONFIGURE_RUNTIME_GATE_INVOCATION_ID" \
       && -d "/proc/${CONFIGURE_RUNTIME_GATE_ACK_PID}" \
       && "$(stat -Lc '%u' -- "/proc/${CONFIGURE_RUNTIME_GATE_ACK_PID}" 2>/dev/null)" == 0 ]]
}

configure_runtime_start_fence_is_active() {
    configure_runtime_gate_job_record_is_safe || return 1
    [[ ! -e "$CONFIGURE_RUNTIME_GATE_RELEASE" \
       && ! -L "$CONFIGURE_RUNTIME_GATE_RELEASE" ]] || return 1
    configure_read_mihomo_runtime_state || return 1
    case "$CONFIGURE_MIHOMO_ACTIVE_STATE:$CONFIGURE_MIHOMO_SUB_STATE" in
        inactive:dead|inactive:*) return 0 ;;
        activating:start-pre) configure_runtime_gate_ack_matches_control_process ;;
        *) return 1 ;;
    esac
}

configure_assert_runtime_gate_quiescent() {
    configure_runtime_start_fence_is_active \
        || { err "The PID1-owned runtime start gate is not active."; return 1; }
    wait_managed_account_quiescent "$FIVEGPN_SERVICE_USER" \
        || { err "A fivegpn process survived the PID1 restart stop phase."; return 1; }
}

configure_publish_runtime_gate_release() {
    configure_runtime_gate_job_record_is_safe || return 1
    [[ ! -e "$CONFIGURE_RUNTIME_GATE_RELEASE" \
       && ! -L "$CONFIGURE_RUNTIME_GATE_RELEASE" ]] || return 1
    configure_publish_private_runtime_gate_file "$CONFIGURE_RUNTIME_GATE_RELEASE" \
        "$(printf 'version=1\ntoken=%s\n' "$CONFIGURE_RUNTIME_GATE_TOKEN")" \
        && configure_runtime_gate_release_is_safe
}

configure_delete_closed_runtime_gate_state() {
    local require_inactive="$1" path fence_dir
    [[ "$require_inactive" == 0 || "$require_inactive" == 1 ]] || return 1
    fence_dir="$(configure_runtime_fence_private_dir)" || return 1
    configure_runtime_gate_record_is_safe closing || return 1
    if [[ -e "$CONFIGURE_RUNTIME_GATE_JOB" || -L "$CONFIGURE_RUNTIME_GATE_JOB" ]]; then
        configure_runtime_gate_job_record_is_safe closing || return 1
    fi
    if [[ -e "$CONFIGURE_RUNTIME_GATE_RELEASE" || -L "$CONFIGURE_RUNTIME_GATE_RELEASE" ]]; then
        configure_runtime_gate_release_is_safe closing || return 1
    fi
    if [[ -e "$CONFIGURE_RUNTIME_GATE_ACK" || -L "$CONFIGURE_RUNTIME_GATE_ACK" ]]; then
        configure_runtime_gate_ack_is_safe closing || return 1
    fi
    if [[ "$require_inactive" == 1 ]]; then
        configure_force_runtime_inactive_for_gate || return 1
    else
        configure_unit_has_no_job || return 1
    fi
    for path in "$CONFIGURE_RUNTIME_GATE_RELEASE" "$CONFIGURE_RUNTIME_GATE_ACK" \
                "$CONFIGURE_RUNTIME_GATE_JOB"; do
        [[ ! -e "$path" && ! -L "$path" ]] || rm -f -- "$path" || return 1
    done
    if [[ "$require_inactive" == 1 ]]; then
        configure_force_runtime_inactive_for_gate || return 1
    else
        configure_unit_has_no_job || return 1
    fi
    rm -f -- "$CONFIGURE_RUNTIME_GATE_RECORD" || return 1
    sync -f "$fence_dir" 2>/dev/null || return 1
    [[ ! -e "$CONFIGURE_RUNTIME_GATE_RECORD" && ! -L "$CONFIGURE_RUNTIME_GATE_RECORD" \
       && ! -e "$CONFIGURE_RUNTIME_GATE_JOB" && ! -L "$CONFIGURE_RUNTIME_GATE_JOB" \
       && ! -e "$CONFIGURE_RUNTIME_GATE_ACK" && ! -L "$CONFIGURE_RUNTIME_GATE_ACK" \
       && ! -e "$CONFIGURE_RUNTIME_GATE_RELEASE" && ! -L "$CONFIGURE_RUNTIME_GATE_RELEASE" ]]
}

configure_remove_runtime_gate_state() {
    local require_inactive="${1:-0}"
    [[ "$require_inactive" == 0 || "$require_inactive" == 1 ]] || return 1
    configure_repair_runtime_gate_link_residue || return 1
    configure_runtime_gate_job_record_is_safe open || return 1
    if [[ -e "$CONFIGURE_RUNTIME_GATE_RELEASE" || -L "$CONFIGURE_RUNTIME_GATE_RELEASE" ]]; then
        configure_runtime_gate_release_is_safe open || return 1
    fi
    if [[ -e "$CONFIGURE_RUNTIME_GATE_ACK" || -L "$CONFIGURE_RUNTIME_GATE_ACK" ]]; then
        configure_runtime_gate_ack_is_safe open || return 1
    fi
    configure_close_runtime_gate_record || return 1
    configure_delete_closed_runtime_gate_state "$require_inactive"
}

configure_remove_unbound_runtime_gate_state() {
    local require_inactive="${1:-0}"
    [[ "$require_inactive" == 0 || "$require_inactive" == 1 ]] || return 1
    configure_repair_runtime_gate_link_residue || return 1
    configure_runtime_gate_record_is_safe open || return 1
    [[ ! -e "$CONFIGURE_RUNTIME_GATE_JOB" \
       && ! -L "$CONFIGURE_RUNTIME_GATE_JOB" ]] || return 1
    if [[ -e "$CONFIGURE_RUNTIME_GATE_RELEASE" || -L "$CONFIGURE_RUNTIME_GATE_RELEASE" ]]; then
        configure_runtime_gate_release_is_safe open || return 1
    fi
    if [[ -e "$CONFIGURE_RUNTIME_GATE_ACK" || -L "$CONFIGURE_RUNTIME_GATE_ACK" ]]; then
        configure_runtime_gate_ack_is_safe open || return 1
    fi
    configure_close_runtime_gate_record || return 1
    configure_delete_closed_runtime_gate_state "$require_inactive"
}

configure_unit_has_no_job() {
    local unit_path job
    unit_path="$(busctl --system --json=short call org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetUnit \
        s "$CONFIGURE_RUNTIME_GATE_UNIT" 2>/dev/null \
        | jq -er 'select(.type == "o") | .data | select(type == "array" and length == 1) | .[0]')" \
        || return 1
    [[ "$unit_path" == /org/freedesktop/systemd1/unit/* ]] || return 1
    job="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$unit_path" org.freedesktop.systemd1.Unit Job 2>/dev/null \
        | jq -cer 'select(.type == "(uo)") | .data | select(type == "array" and length == 2)')" \
        || return 1
    jq -e '.[0] == 0 and .[1] == "/"' <<<"$job" >/dev/null
}

configure_force_runtime_inactive_for_gate() {
    local rc=0
    systemctl --job-mode=replace stop 5gpn-mihomo.service >/dev/null 2>&1 || rc=1
    configure_read_mihomo_runtime_state || rc=1
    [[ "$CONFIGURE_MIHOMO_ACTIVE_STATE" == inactive ]] || rc=1
    configure_unit_has_no_job || rc=1
    wait_managed_account_quiescent "$FIVEGPN_SERVICE_USER" || rc=1
    configure_read_mihomo_runtime_state || rc=1
    [[ "$CONFIGURE_MIHOMO_ACTIVE_STATE" == inactive ]] || rc=1
    configure_unit_has_no_job || rc=1
    [[ "$rc" == 0 ]]
}

configure_stop_runtime_recovered_from_stale_fence() {
    [[ "${CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE:-0}" == 1 ]] \
        || return 0
    CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=0
    configure_force_runtime_inactive_for_gate \
        || { err "Could not stop mihomo after retained-gate recovery validation failed."; return 1; }
    warn "Stopped the Core restored from a retained configure gate because the current deployment failed validation."
}

recover_stale_configure_runtime_fence() {
    local path runtime_rc=0
    ensure_private_lock_dir || return 1
    configure_runtime_fence_private_dir >/dev/null || return 1
    configure_repair_runtime_gate_link_residue || return 1
    if [[ ! -e "$CONFIGURE_RUNTIME_GATE_RECORD" \
       && ! -L "$CONFIGURE_RUNTIME_GATE_RECORD" ]]; then
        for path in "$CONFIGURE_RUNTIME_GATE_JOB" "$CONFIGURE_RUNTIME_GATE_ACK" \
                    "$CONFIGURE_RUNTIME_GATE_RELEASE"; do
            [[ ! -e "$path" && ! -L "$path" ]] \
                || { err "Orphan PID1 runtime-gate state exists without its ownership record: $path"; return 1; }
        done
        return 0
    fi
    if configure_runtime_gate_record_is_safe closing; then
        configure_delete_closed_runtime_gate_state 1 \
            || { err "Could not finish a retained closing PID1 gate transaction."; return 1; }
        warn "Finished cleanup for a retained closing PID1 gate; mihomo remains stopped."
        return 0
    fi
    configure_runtime_gate_record_is_safe \
        || { err "The retained configure runtime-gate record is unsafe."; return 1; }
    if ! configure_runtime_gate_job_record_is_safe; then
        err "The retained configure gate has no safe PID1 job binding; keeping mihomo inactive."
        configure_force_runtime_inactive_for_gate || return 1
        configure_remove_unbound_runtime_gate_state 1 || return 1
        return 0
    fi
    if [[ -e "$CONFIGURE_RUNTIME_GATE_RELEASE" \
       || -L "$CONFIGURE_RUNTIME_GATE_RELEASE" ]]; then
        configure_runtime_gate_release_is_safe \
            || { err "The retained PID1 gate release record is unsafe."; return 1; }
        configure_read_mihomo_runtime_state || return 1
        case "$CONFIGURE_MIHOMO_ACTIVE_STATE" in
            active|activating)
                configure_validate_runtime_before_start \
                    || { if configure_force_runtime_inactive_for_gate; then \
                             configure_remove_runtime_gate_state 1 || true; \
                         fi; return 1; }
                if wait_service_ready 5gpn-mihomo.service; then
                    CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=1
                    configure_remove_runtime_gate_state || return 1
                    warn "Completed cleanup for an already released configure restart job."
                    return 0
                fi
                configure_read_mihomo_runtime_state || return 1
                if [[ "$CONFIGURE_MIHOMO_ACTIVE_STATE" == inactive ]] \
                   && ! configure_systemd_job_is_exact; then
                    configure_remove_runtime_gate_state 1 || return 1
                    warn "An operator stop won after the configure gate was released; preserving that stop."
                    return 0
                fi
                if configure_force_runtime_inactive_for_gate; then
                    configure_remove_runtime_gate_state 1 || true
                fi
                return 1
                ;;
            inactive)
                configure_remove_runtime_gate_state 1 || return 1
                return 0
                ;;
            failed|deactivating)
                configure_force_runtime_inactive_for_gate || return 1
                configure_remove_runtime_gate_state 1 || return 1
                return 0
                ;;
            *)
                err "The retained released gate found an unsupported mihomo state: $CONFIGURE_MIHOMO_ACTIVE_STATE"
                return 1
                ;;
        esac
    fi
    if [[ "$CONFIGURE_RUNTIME_FENCE_RESTORE_ACTIVE" == 1 ]] \
       && configure_runtime_gate_ack_matches_control_process; then
        if ! configure_validate_runtime_before_start; then
            configure_update_runtime_fence_restore_entitlement 0 || true
            if configure_force_runtime_inactive_for_gate; then
                configure_remove_runtime_gate_state 1 || true
            fi
            err "Refusing to release a retained PID1 job against invalid current runtime inputs."
            return 1
        fi
        configure_update_runtime_fence_restore_entitlement 0 || return 1
        CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=1
        configure_publish_runtime_gate_release || return 1
        if ! wait_service_ready 5gpn-mihomo.service; then
            configure_read_mihomo_runtime_state || return 1
            if [[ "$CONFIGURE_MIHOMO_ACTIVE_STATE" == inactive ]] \
               && ! configure_systemd_job_is_exact; then
                CONFIGURE_RUNTIME_RECOVERED_FROM_STALE_FENCE=0
                configure_remove_runtime_gate_state 1 || return 1
                warn "An operator stop canceled the retained PID1 restart job; preserving that stop."
                return 0
            fi
            configure_stop_runtime_recovered_from_stale_fence || true
            err "Mihomo did not become ready after retained gate recovery."
            return 1
        fi
        configure_remove_runtime_gate_state || return 1
        return 0
    fi
    configure_force_runtime_inactive_for_gate || runtime_rc=$?
    [[ "$runtime_rc" == 0 ]] \
        || { err "Could not retain inactive state while cleaning a stale configure gate; the gate state was retained."; return 1; }
    configure_remove_runtime_gate_state 1 || return 1
    warn "Discarded a retained configure gate because its original blocked PID1 job no longer exists. Mihomo remains stopped."
}

configure_install_runtime_start_fence() {
    local token record_contents job_contents
    recover_stale_configure_runtime_fence || return 1
    token="$(openssl rand -hex 32 2>/dev/null)" || return 1
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
    record_contents="$(printf 'version=1\ntoken=%s\nunit=%s\n' \
        "$token" "$CONFIGURE_RUNTIME_GATE_UNIT")"
    job_contents="$(printf 'version=1\ntoken=%s\njob_id=0\njob_path=/\nmethod=none\nrestore_active=0\n' \
        "$token")"
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=1
    configure_publish_private_runtime_gate_file "$CONFIGURE_RUNTIME_GATE_RECORD" \
        "${record_contents}"$'\n' \
        || { err "Could not publish the PID1 runtime-gate ownership record."; return 1; }
    configure_publish_private_runtime_gate_file "$CONFIGURE_RUNTIME_GATE_JOB" \
        "${job_contents}"$'\n' \
        || { err "Could not publish the initial PID1 runtime-gate job record."; return 1; }
    configure_runtime_gate_job_record_is_safe \
        || { err "The PID1 runtime gate failed its post-publication validation."; return 1; }
}

configure_release_runtime_start_fence() {
    local require_inactive="${1:-0}"
    [[ "$require_inactive" == 0 || "$require_inactive" == 1 ]] || return 1
    [[ "${CONFIGURE_RUNTIME_FENCE_ATTEMPTED:-0}" == 1 \
       || "${CONFIGURE_RUNTIME_FENCED_BY_US:-0}" == 1 ]] || return 0
    configure_repair_runtime_gate_link_residue || return 1
    if [[ ! -e "$CONFIGURE_RUNTIME_GATE_RECORD" \
       && ! -L "$CONFIGURE_RUNTIME_GATE_RECORD" ]]; then
        [[ ! -e "$CONFIGURE_RUNTIME_GATE_JOB" && ! -L "$CONFIGURE_RUNTIME_GATE_JOB" \
           && ! -e "$CONFIGURE_RUNTIME_GATE_ACK" && ! -L "$CONFIGURE_RUNTIME_GATE_ACK" \
           && ! -e "$CONFIGURE_RUNTIME_GATE_RELEASE" && ! -L "$CONFIGURE_RUNTIME_GATE_RELEASE" ]] \
            || return 1
    elif [[ ! -e "$CONFIGURE_RUNTIME_GATE_JOB" \
         && ! -L "$CONFIGURE_RUNTIME_GATE_JOB" ]]; then
        configure_remove_unbound_runtime_gate_state "$require_inactive" || return 1
    else
        configure_remove_runtime_gate_state "$require_inactive" || return 1
    fi
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
}

configure_enqueue_pid1_try_restart() {
    local output job_path job_id
    output="$(busctl --system --json=short call org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager \
        TryRestartUnit ss "$CONFIGURE_RUNTIME_GATE_UNIT" fail 2>/dev/null)" \
        || return 1
    job_path="$(jq -er '
        select(.type == "o")
        | .data
        | select(type == "array" and length == 1)
        | .[0]
        | select(type == "string" and test("^/org/freedesktop/systemd1/job/[1-9][0-9]*$"))
    ' <<<"$output")" || return 1
    job_id="${job_path##*/}"
    configure_replace_runtime_gate_job_record \
        "$job_id" "$job_path" TryRestartUnit 1 || return 1
    CONFIGURE_RUNTIME_QUIESCED_BY_US=1
}

configure_wait_for_pid1_restart_gate() {
    local deadline rc=0
    deadline=$((SECONDS + CONFIGURE_RUNTIME_GATE_QUIESCE_TIMEOUT))
    while (( SECONDS < deadline )); do
        if configure_runtime_gate_ack_matches_control_process; then
            CONFIGURE_RUNTIME_FENCED_BY_US=1
            return 0
        fi
        if ! configure_systemd_job_is_exact; then
            configure_read_mihomo_runtime_state || return 1
            case "$CONFIGURE_MIHOMO_ACTIVE_STATE" in
                inactive)
                    configure_update_runtime_fence_restore_entitlement 0 || return 1
                    CONFIGURE_RUNTIME_WAS_ACTIVE=0
                    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
                    return 2
                    ;;
                failed)
                    configure_force_runtime_inactive_for_gate || return 1
                    configure_update_runtime_fence_restore_entitlement 0 || return 1
                    CONFIGURE_RUNTIME_WAS_ACTIVE=0
                    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
                    err "The PID1 restart job failed before reaching the acknowledged gate."
                    return 1
                    ;;
            esac
        fi
        sleep 0.1
    done
    err "Timed out waiting for PID 1 to reach the blocked mihomo ExecStartPre gate."
    return 1
}

configure_wait_for_runtime_inactive_behind_gate() {
    local deadline
    deadline=$((SECONDS + CONFIGURE_RUNTIME_GATE_QUIESCE_TIMEOUT))
    while (( SECONDS < deadline )); do
        configure_read_mihomo_runtime_state || return 1
        case "$CONFIGURE_MIHOMO_ACTIVE_STATE" in
            inactive) return 0 ;;
            failed)
                configure_force_runtime_inactive_for_gate || return 1
                err "The conflicting PID1 transaction left mihomo failed."
                return 1
                ;;
            active|activating|deactivating) ;;
            *) return 1 ;;
        esac
        sleep 0.1
    done
    return 1
}

configure_quiesce_runtime_for_gateway() {
    local should_restart=0 gate_rc=0
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    configure_main_unit_restart_gate_is_current || return 1
    read_exact_systemd_unit_state 5gpn-mihomo.service \
        || { err "Could not inspect mihomo at the gateway publication boundary."; return 1; }
    [[ "$SYSTEMD_UNIT_LOAD_STATE" == loaded ]] \
        || { err "The managed mihomo unit disappeared before gateway publication."; return 1; }
    case "${CONFIGURE_RUNTIME_WAS_ACTIVE:-0}:${SYSTEMD_UNIT_ACTIVE_STATE}" in
        1:active) should_restart=1 ;;
        1:inactive)
            CONFIGURE_RUNTIME_WAS_ACTIVE=0
            ;;
        0:inactive) ;;
        0:active)
            err "Mihomo was started outside configure after the initial inactive snapshot; refusing the gateway write."
            return 1
            ;;
        *:failed)
            err "Mihomo is failed at the gateway publication boundary; refusing the gateway write."
            return 1
            ;;
        *)
            err "Mihomo is transitioning (${SYSTEMD_UNIT_ACTIVE_STATE}); refusing the gateway write."
            return 1
            ;;
    esac

    configure_install_runtime_start_fence || return 1
    if [[ "$should_restart" == 1 ]]; then
        info "Asking PID 1 for one fail-on-conflict try-restart; its start phase will remain gated during publication."
        if ! configure_enqueue_pid1_try_restart; then
            configure_wait_for_runtime_inactive_behind_gate \
                || { err "Could not enqueue the PID1-owned try-restart job while mihomo remained active."; return 1; }
            CONFIGURE_RUNTIME_WAS_ACTIVE=0
        else
            configure_wait_for_pid1_restart_gate || gate_rc=$?
            [[ "$gate_rc" == 0 || "$gate_rc" == 2 ]] || return "$gate_rc"
        fi
    fi
    configure_assert_runtime_gate_quiescent
}

configure_disarm_runtime_restore_for_coordinate_commit() {
    [[ "${CONFIGURE_RUNTIME_QUIESCED_BY_US:-0}" == 1 ]] || return 0
    configure_update_runtime_fence_restore_entitlement 0 || return 1
    CONFIGURE_RUNTIME_RESTORE_DISARMED=1
}

configure_rearm_runtime_restore_after_failed_commit() {
    [[ "${CONFIGURE_RUNTIME_RESTORE_DISARMED:-0}" == 1 \
       && "${CONFIGURE_RUNTIME_QUIESCED_BY_US:-0}" == 1 ]] || return 0
    configure_visible_coordinate_was_committed && return 0
    configure_systemd_job_is_exact || return 0
    configure_update_runtime_fence_restore_entitlement 1 || return 1
    CONFIGURE_RUNTIME_RESTORE_DISARMED=0
}

configure_release_quiesced_runtime_without_start() {
    local rc=0
    configure_update_runtime_fence_restore_entitlement 0 || rc=1
    configure_release_runtime_start_fence 1 \
        || { err "Could not prove mihomo inactive; retaining the PID1 gate state."; return 1; }
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    CONFIGURE_RUNTIME_RESTORE_DISARMED=0
    [[ "$rc" == 0 ]]
}

configure_stop_runtime_after_visible_failure() {
    local rc=0
    if [[ "${CONFIGURE_RUNTIME_QUIESCED_BY_US:-0}" == 1 \
       || "${CONFIGURE_RUNTIME_FENCE_ATTEMPTED:-0}" == 1 \
       || "${CONFIGURE_RUNTIME_FENCED_BY_US:-0}" == 1 ]]; then
        configure_release_quiesced_runtime_without_start || rc=1
    else
        configure_force_runtime_inactive_for_gate || rc=1
    fi
    [[ "$rc" == 0 ]]
}

configure_validate_runtime_before_start() {
    local expected_gateway="${GATEWAY_IP:-}"
    configure_main_unit_restart_gate_is_current || return 1
    if [[ "${CONFIGURE_GATEWAY_CHANGED:-0}" == 1 \
       && "${CONFIGURE_DNS_GATEWAY_COMMIT_STATE:-}" != committed* ]]; then
        expected_gateway="${CONFIGURE_EXPECTED_OLD_GATEWAY:-}"
    fi
    configure_revalidate_selected_operator_config || return 1
    assert_loaded_persisted_dns_env_revision 1 || return 1
    validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core" || return 1
    [[ -n "$expected_gateway" ]] \
        && jq -e --arg gateway "$expected_gateway" '.gateway == $gateway' \
            "${FIVEGPN_STATE_DIR}/dns.json" >/dev/null \
        || { err "The DNS gateway failed the final pre-start validation."; return 1; }
    load_ui_generation_helper \
        && _ui_generation_current_only_is_safe "$UI_DIR" \
        || { err "The current UI/profile generation failed the final pre-start validation."; return 1; }
}

configure_start_quiesced_runtime() {
    local should_start="${CONFIGURE_RUNTIME_QUIESCED_BY_US:-0}"
    local fence_rc=0 start_rc=0 wait_rc=0 cleanup_inactive=0
    if [[ "$should_start" == 1 ]]; then
        if ! configure_validate_runtime_before_start; then
            configure_update_runtime_fence_restore_entitlement 0 || true
            if configure_release_runtime_start_fence 1; then
                CONFIGURE_RUNTIME_QUIESCED_BY_US=0
            fi
            err "Refusing to restore mihomo from a runtime generation that failed final validation."
            return 1
        fi
        configure_update_runtime_fence_restore_entitlement 0 || return 1
        if ! configure_runtime_gate_ack_matches_control_process; then
            configure_read_mihomo_runtime_state || start_rc=1
            if [[ "$start_rc" == 0 && "$CONFIGURE_MIHOMO_ACTIVE_STATE" == inactive ]]; then
                warn "An operator stop canceled the PID1 restart job; preserving that stop."
                CONFIGURE_RUNTIME_WAS_ACTIVE=0
                should_start=0
                cleanup_inactive=1
            else
                err "The original PID1 restart job disappeared before gate release."
                start_rc=1
            fi
        else
            configure_publish_runtime_gate_release || start_rc=1
        fi
        if [[ "$start_rc" == 0 && "$should_start" == 1 ]]; then
            wait_service_ready 5gpn-mihomo.service || wait_rc=$?
            if [[ "$wait_rc" != 0 ]]; then
                configure_read_mihomo_runtime_state || start_rc=1
                if [[ "$start_rc" == 0 \
                   && "$CONFIGURE_MIHOMO_ACTIVE_STATE" == inactive ]] \
                   && ! configure_systemd_job_is_exact; then
                    warn "An operator stop canceled the released PID1 restart job; preserving that stop."
                    CONFIGURE_RUNTIME_WAS_ACTIVE=0
                    should_start=0
                    cleanup_inactive=1
                else
                    err "Mihomo did not become ready after the PID1 restart gate was released."
                    start_rc=1
                fi
            fi
        fi
        if [[ "$start_rc" == 0 \
           && "$should_start" == 1 \
           && "${CONFIGURE_NODE_LOCK_HELD:-0}" == 1 \
           && -n "${CONFIGURE_OPERATOR_CONFIG_STATE:-}" ]] \
           && ! configure_assert_operator_config_revision; then
            err "Operator YAML changed while mihomo was starting; stopping the runtime."
            start_rc=1
        fi
    else
        configure_read_mihomo_runtime_state || start_rc=1
        if [[ "$start_rc" == 0 ]]; then
            case "$CONFIGURE_MIHOMO_ACTIVE_STATE" in
                inactive) cleanup_inactive=1 ;;
                active)
                    [[ "${CONFIGURE_RUNTIME_WAS_ACTIVE:-0}" == 1 ]] \
                        && configure_unit_has_no_job \
                        || start_rc=1
                    ;;
                *) start_rc=1 ;;
            esac
        fi
    fi
    if [[ "$start_rc" != 0 ]]; then
        configure_force_runtime_inactive_for_gate || return 1
        cleanup_inactive=1
    fi
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    CONFIGURE_RUNTIME_RESTORE_DISARMED=0
    configure_release_runtime_start_fence "$cleanup_inactive" || fence_rc=$?
    [[ "$fence_rc" == 0 && "$start_rc" == 0 ]]
}

configure_visible_coordinate_was_committed() {
    [[ "${CONFIGURE_DNS_GATEWAY_COMMIT_STATE:-}" == committed* \
       || "${DNS_ENV_PUBLICATION_COMMIT_STATE:-}" == committed* \
       || "${CERT_ROLE_CTL_COMMIT_STATE:-}" == committed* \
       || "${CONFIGURE_CERT_PUBLICATION_COMPLETED:-0}" == 1 ]]
}

configure_revalidate_locked_publication_inputs() {
    local expected_old_gateway="$1"
    [[ "${CONFIGURE_NODE_LOCK_HELD:-0}" == 1 \
       && "$INSTALL_CERT_LOCK_HELD" == 1 ]] \
        || { err "Configure final validation requires both transaction locks."; return 1; }
    configure_assert_certificate_selection || return 1
    configure_revalidate_selected_operator_config || return 1
    configure_assert_runtime_state_before_publication || return 1
    assert_loaded_persisted_dns_env_revision 1 || return 1
    validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core" || return 1
    [[ "$VALIDATED_DNS_SOURCE_REVISION" =~ ^[0-9a-f]{64}$ ]] \
        || { err "The installed Core did not pin the current DNS document revision."; return 1; }
    if [[ "$CONFIGURE_GATEWAY_CHANGED" == 1 ]]; then
        jq -e --arg gateway "$expected_old_gateway" '.gateway == $gateway' \
            "${FIVEGPN_STATE_DIR}/dns.json" >/dev/null \
            || { err "The current gateway changed while configure waited for its locks."; return 1; }
    fi
    if [[ "$CONFIGURE_DNS_GATE_REQUIRED" == 1 ]]; then
        verify_console_dns || return 1
    fi
}

configure_apply_gateway_publication() {
    local expected_old_gateway="$1"
    [[ "$INSTALL_CERT_LOCK_HELD" == 1 \
       && -n "${UI_GENERATION_CANDIDATE:-}" ]] \
        || { err "Gateway publication requires the locked prepared profile generation."; return 1; }
    if [[ "${CONFIGURE_RUNTIME_FENCE_ATTEMPTED:-0}" != 1 \
       && "${CONFIGURE_RUNTIME_FENCED_BY_US:-0}" != 1 ]]; then
        configure_quiesce_runtime_for_gateway || return 1
    else
        configure_runtime_start_fence_is_active \
            || { err "The HTTP-01 PID1 restart gate disappeared before gateway publication."; return 1; }
        configure_assert_runtime_gate_quiescent || return 1
    fi
    configure_assert_operator_config_revision || return 1
    assert_loaded_persisted_dns_env_revision 1 || return 1
    validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core" || return 1
    [[ "$VALIDATED_DNS_SOURCE_REVISION" =~ ^[0-9a-f]{64}$ ]] || return 1
    jq -e --arg gateway "$expected_old_gateway" '.gateway == $gateway' \
        "${FIVEGPN_STATE_DIR}/dns.json" >/dev/null \
        || { err "The current gateway changed outside configure before the bounded publication."; return 1; }

    configure_update_existing_dns_gateway || return 1
    write_dns_env || return 1
    publish_ios_profile || return 1
    configure_revalidate_selected_operator_config || return 1
    assert_loaded_persisted_dns_env_revision 1 || return 1
    validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core" || return 1
    jq -e --arg gateway "$GATEWAY_IP" '.gateway == $gateway' \
        "${FIVEGPN_STATE_DIR}/dns.json" >/dev/null \
        || { err "The published DNS gateway failed final validation."; return 1; }
    load_ui_generation_helper \
        && _ui_generation_current_only_is_safe "$UI_DIR" \
        || { err "The published UI/profile generation failed final validation."; return 1; }
    configure_start_quiesced_runtime
}

configure_apply_environment_transaction() (
    local final_rc=0 stop_rc=0 runtime_rc=0
    DNS_ENV_PUBLICATION_COMMIT_STATE=not-committed
    CONFIGURE_DNS_GATEWAY_COMMIT_STATE=not-committed
    CONFIGURE_CERT_PUBLICATION_COMPLETED=0
    CERT_ROLE_CTL_COMMIT_STATE=""
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    CONFIGURE_RUNTIME_RESTORE_DISARMED=0
    configure_environment_finish() {
        final_rc="$1"
        trap - EXIT
        trap '' HUP INT TERM
        if [[ "$final_rc" != 0 \
           && "${DNS_ENV_PUBLICATION_COMMIT_STATE:-}" == committed* ]]; then
            err "Configure failed after dns.env became visible; stopping mihomo without rolling the file back."
            configure_stop_runtime_after_visible_failure || stop_rc=$?
        elif [[ "$final_rc" != 0 \
             && ( "${CONFIGURE_RUNTIME_QUIESCED_BY_US:-0}" == 1 \
                  || "${CONFIGURE_RUNTIME_FENCE_ATTEMPTED:-0}" == 1 \
                  || "${CONFIGURE_RUNTIME_FENCED_BY_US:-0}" == 1 ) ]]; then
            err "Configure failed before dns.env publication; releasing only the original PID1 restart job."
            configure_start_quiesced_runtime || runtime_rc=$?
        fi
        if [[ "$final_rc" == 0 && ( "$stop_rc" != 0 || "$runtime_rc" != 0 ) ]]; then
            final_rc=1
        fi
        exit "$final_rc"
    }
    trap 'configure_environment_finish $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$CONFIGURE_RESTART_REQUIRED" == 1 ]]; then
        configure_quiesce_runtime_for_gateway || exit $?
        configure_disarm_runtime_restore_for_coordinate_commit || exit $?
        if ! write_dns_env; then
            if [[ "${DNS_ENV_PUBLICATION_COMMIT_STATE:-}" != committed* ]]; then
                configure_rearm_runtime_restore_after_failed_commit || true
            fi
            exit 1
        fi
        configure_start_quiesced_runtime || exit $?
    else
        write_dns_env || exit $?
    fi
)

configure_apply_certificate_transaction() (
    local cert_changed="$1" profile_changed="$2" expected_old_gateway="$3"
    local cleanup_rc=0 timer_rc=0 lock_rc=0 runtime_rc=0
    local visible_failure_stopped=0 cert_install_rc=0
    CONFIGURE_RUNTIME_QUIESCED_BY_US=0
    CONFIGURE_RUNTIME_FENCE_ATTEMPTED=0
    CONFIGURE_RUNTIME_FENCED_BY_US=0
    CONFIGURE_RUNTIME_RESTORE_DISARMED=0
    CONFIGURE_DNS_GATEWAY_COMMIT_STATE=not-committed
    DNS_ENV_PUBLICATION_COMMIT_STATE=not-committed
    CONFIGURE_CERT_PUBLICATION_COMPLETED=0
    CERT_ROLE_CTL_COMMIT_STATE=""
    CONFIGURE_EXPECTED_OLD_GATEWAY="$expected_old_gateway"
    configure_certificate_finish() {
        local final_rc="$1"
        trap - EXIT
        trap '' HUP INT TERM
        set +e
        if [[ "$final_rc" != 0 ]] && configure_visible_coordinate_was_committed; then
            err "Configure failed after visible certificate or coordinate publication; mihomo remains stopped and visible files were not rolled back."
            configure_stop_runtime_after_visible_failure
            runtime_rc=$?
            visible_failure_stopped=1
        elif [[ "${CONFIGURE_RUNTIME_QUIESCED_BY_US:-0}" == 1 \
             || "${CONFIGURE_RUNTIME_FENCE_ATTEMPTED:-0}" == 1 \
             || "${CONFIGURE_RUNTIME_FENCED_BY_US:-0}" == 1 ]]; then
            [[ "$final_rc" == 0 ]] \
                || err "Configure failed before a visible coordinate commit; attempting to restore the previously active runtime."
            configure_start_quiesced_runtime
            runtime_rc=$?
        fi
        if [[ -n "${UI_GENERATION_CANDIDATE:-}" ]]; then
            load_ui_generation_helper \
                && ui_generation_cleanup_candidate "$UI_DIR" "$UI_GENERATION_CANDIDATE"
            cleanup_rc=$?
            if [[ "$cleanup_rc" == 0 ]]; then
                UI_GENERATION_CANDIDATE=""
                UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
            fi
        fi
        PENDING_CF_TOKEN=""
        restore_global_certbot_timer
        timer_rc=$?
        release_install_cert_lock
        lock_rc=$?
        set -e
        [[ "$cleanup_rc" == 0 ]] || err "An unpublished UI generation was retained after configure failure."
        [[ "$runtime_rc" == 0 ]] || err "The PID1 runtime gate could not be finalized after configure."
        [[ "$timer_rc" == 0 ]] || err "The distro Certbot timer state needs repair after configure."
        [[ "$lock_rc" == 0 ]] || err "The certificate lock descriptor was invalid during configure cleanup."
        if [[ "$final_rc" == 0 \
           && ( "$cleanup_rc" != 0 || "$runtime_rc" != 0 \
                || "$timer_rc" != 0 || "$lock_rc" != 0 ) ]]; then
            final_rc=1
        fi
        if [[ "$final_rc" != 0 && "$visible_failure_stopped" == 0 ]] \
           && configure_visible_coordinate_was_committed; then
            configure_stop_runtime_after_visible_failure || runtime_rc=1
            visible_failure_stopped=1
        fi
        exit "$final_rc"
    }
    trap 'configure_certificate_finish $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [[ "$profile_changed" == 1 ]] \
        || { err "The certificate transaction requires a profile generation."; exit 1; }
    acquire_install_cert_lock || exit $?
    configure_revalidate_locked_publication_inputs "$expected_old_gateway" || exit $?
    if [[ "$cert_changed" == 1 ]]; then
        preflight_global_certbot_timer_state || exit $?
    fi
    if [[ "$cert_changed" == 1 && "$CERT_MODE" == cloudflare ]]; then
        configure_commit_pending_cf_token || exit $?
    fi
    if [[ "$cert_changed" == 1 ]]; then
        configure_quiesce_runtime_for_gateway || exit $?
        # From this point a hard process death must not make a later configure
        # release the blocked restart across an unknown certificate publication
        # boundary. A normal pre-commit failure can re-arm the same still-live
        # PID1 job for the EXIT restoration.
        configure_disarm_runtime_restore_for_coordinate_commit || exit $?
        if [[ "$CERT_MODE" == http-01 ]]; then
            FIVEGPN_HTTP_CERTBOT_RUNTIME_FENCED=1 install_cert "$BASE_DOMAIN" \
                || cert_install_rc=$?
        else
            install_cert "$BASE_DOMAIN" || cert_install_rc=$?
        fi
        if [[ "$cert_install_rc" != 0 ]]; then
            if [[ "${CERT_ROLE_CTL_COMMIT_STATE:-}" != committed* \
               && "${CONFIGURE_CERT_PUBLICATION_COMPLETED:-0}" != 1 ]]; then
                configure_rearm_runtime_restore_after_failed_commit || true
            fi
            exit "$cert_install_rc"
        fi
        CONFIGURE_CERT_PUBLICATION_COMPLETED=1
    fi
    prepare_ios_profile || exit $?
    configure_revalidate_selected_operator_config || exit $?
    assert_loaded_persisted_dns_env_revision 1 || exit $?
    validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core" || exit $?

    if [[ "$CONFIGURE_GATEWAY_CHANGED" == 1 ]]; then
        configure_apply_gateway_publication "$expected_old_gateway" || exit $?
    else
        if [[ "$CONFIGURE_DNS_ENV_CHANGED" == 1 ]]; then
            configure_disarm_runtime_restore_for_coordinate_commit || exit $?
            if ! write_dns_env; then
                if [[ "${DNS_ENV_PUBLICATION_COMMIT_STATE:-}" != committed* ]]; then
                    configure_rearm_runtime_restore_after_failed_commit || true
                fi
                exit 1
            fi
        fi
        publish_ios_profile || exit $?
        configure_revalidate_selected_operator_config || exit $?
        assert_loaded_persisted_dns_env_revision 1 || exit $?
        validate_existing_runtime_documents "$MIHOMO_BIN" "installed Core" || exit $?
        load_ui_generation_helper \
            && _ui_generation_current_only_is_safe "$UI_DIR" \
            || { err "The published UI/profile generation failed final validation."; exit 1; }
        if [[ "${CONFIGURE_RUNTIME_FENCE_ATTEMPTED:-0}" == 1 \
           || "${CONFIGURE_RUNTIME_FENCED_BY_US:-0}" == 1 ]]; then
            configure_start_quiesced_runtime || exit $?
        elif [[ "$CONFIGURE_RESTART_REQUIRED" == 1 ]]; then
            configure_restart_runtime_if_active || exit $?
        fi
    fi
)

configure_restart_runtime_if_active() {
    configure_revalidate_selected_operator_config || return 1
    if [[ "${CONFIGURE_RUNTIME_WAS_ACTIVE:-0}" != 1 ]]; then
        read_exact_systemd_unit_state 5gpn-mihomo.service \
            || { err "Could not re-read the initially inactive mihomo service."; return 1; }
        case "$SYSTEMD_UNIT_LOAD_STATE:$SYSTEMD_UNIT_ACTIVE_STATE" in
            loaded:inactive)
                warn "Configuration was saved, but 5gpn-mihomo remains stopped; start it explicitly when ready."
                return 0
                ;;
            loaded:active)
                err "Mihomo was started outside configure; it was not restarted against the newly saved coordinates."
                return 1
                ;;
            loaded:failed)
                err "Mihomo is failed after configuration publication; it was not misclassified as an operator stop."
                return 1
                ;;
            *)
                err "Mihomo is transitioning after configuration publication: ${SYSTEMD_UNIT_ACTIVE_STATE}."
                return 1
                ;;
        esac
    fi
    load_ui_generation_helper || return 1
    _ui_generation_current_only_is_safe "$UI_DIR" \
        || { err "Current UI generation is unsafe; refusing to restart mihomo."; return 1; }
    if ! systemctl --job-mode=fail try-restart 5gpn-mihomo.service 2>/dev/null; then
        read_exact_systemd_unit_state 5gpn-mihomo.service \
            || { err "Could not inspect mihomo after a conflicting try-restart job."; return 1; }
        if [[ "$SYSTEMD_UNIT_LOAD_STATE:$SYSTEMD_UNIT_ACTIVE_STATE" == loaded:inactive ]]; then
            warn "An operator stop won the try-restart job race; preserving that stop."
            return 0
        fi
        err "Could not try-restart 5gpn-mihomo after configuration."
        return 1
    fi
    read_exact_systemd_unit_state 5gpn-mihomo.service \
        || { err "Could not inspect mihomo after try-restart."; return 1; }
    case "$SYSTEMD_UNIT_LOAD_STATE:$SYSTEMD_UNIT_ACTIVE_STATE" in
        loaded:inactive)
            warn "5gpn-mihomo was stopped before try-restart committed; preserving that operator stop."
            return 0
            ;;
        loaded:active) ;;
        loaded:failed)
            err "Mihomo entered failed state during try-restart."
            return 1
            ;;
        *)
            err "Mihomo is transitioning after try-restart: ${SYSTEMD_UNIT_ACTIVE_STATE}."
            return 1
            ;;
    esac
    wait_service_ready 5gpn-mihomo.service || return 1
    if ! configure_assert_operator_config_revision; then
        systemctl stop 5gpn-mihomo.service >/dev/null 2>&1 || true
        wait_managed_account_quiescent "$FIVEGPN_SERVICE_USER" || true
        err "Operator YAML changed while mihomo was restarting; the runtime was stopped."
        return 1
    fi
}

configure_installation() {
    local old_base old_public old_gateway old_listen old_mode old_email
    local PENDING_CF_TOKEN=""
    check_root || return 1
    [[ "$SCRIPT_DIR" == "$BASE_DIR" ]] \
        || { err "Configure is available only through the installed 5gpn management backend."; return 1; }
    [[ "${RELEASE_CHANNEL_EXPLICIT:-0}" != 1 ]] \
        || { err "Configure does not select or switch release channels; rerun without --beta."; return 2; }
    activate_verified_installed_gum
    LOADED_DNS_ENV_SOURCE_STATE=""
    LOADED_DNS_ENV_SOURCE_REVISION=""
    LOADED_DNS_ENV_SOURCE_IDENTITY=""
    CONFIGURE_OPERATOR_CONFIG_STATE=""
    CONFIGURE_NODE_LOCK_HELD=0
    CONFIGURE_CERTIFICATE_SELECTION_STATE=""
    CONFIGURE_RUNTIME_GATE_LIVE_UNIT_STATE=""
    CONFIGURE_RUNTIME_GATE_STAGED_UNIT_STATE=""
    CONFIGURE_RUNTIME_GATE_HELPER_STATE=""
    CONFIGURE_RUNTIME_UI_VALIDATOR_STATE=""
    UI_GENERATION_CANDIDATE=""
    UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
    load_persisted_install_config \
        || { err "Configure requires a complete current dns.env; it cannot perform a fresh install."; return 1; }
    validate_install_config || return 1
    old_base="$BASE_DOMAIN"
    old_public="$PUBLIC_IP"
    old_gateway="$GATEWAY_IP"
    old_listen="$MIHOMO_LISTEN_IPS"
    old_mode="$CERT_MODE"
    old_email="$CERT_EMAIL"
    configure_require_current_deployment "$old_gateway" || return 1

    configure_install_tui 1 || return 1
    validate_install_config || return 1
    configure_plan_changes \
        "$old_base" "$old_public" "$old_gateway" "$old_listen" "$old_mode" "$old_email" \
        "$BASE_DOMAIN" "$PUBLIC_IP" "$GATEWAY_IP" "$MIHOMO_LISTEN_IPS" "$CERT_MODE" "$CERT_EMAIL"
    configure_revalidate_selected_operator_config || return 1
    assert_loaded_persisted_dns_env_revision 1 || return 1

    if [[ "$CONFIGURE_ANY_CHANGE" != 1 ]]; then
        configure_assert_operator_config_revision || return 1
        ok "Configuration is already current; no file was written and mihomo was not restarted."
        return 0
    fi

    configure_require_selected_dependencies || return 1
    configure_preflight_selected_runtime_helpers || return 1
    if [[ "$CONFIGURE_PROFILE_CHANGED" == 1 ]]; then
        configure_capture_certificate_selection || return 1
    fi
    if [[ "$CONFIGURE_DNS_GATE_REQUIRED" == 1 ]]; then
        verify_console_dns || return 1
    fi
    configure_collect_pending_cf_token || return 1
    acquire_configure_node_lock || return 1
    configure_revalidate_selected_operator_config || return 1
    configure_assert_runtime_state_before_publication || return 1
    configure_assert_operator_config_revision || return 1
    assert_loaded_persisted_dns_env_revision 1 || return 1

    if [[ "$CONFIGURE_PROFILE_CHANGED" == 1 ]]; then
        configure_apply_certificate_transaction \
            "$CONFIGURE_CERT_CHANGED" "$CONFIGURE_PROFILE_CHANGED" "$old_gateway" \
            || { PENDING_CF_TOKEN=""; return 1; }
        PENDING_CF_TOKEN=""
    else
        configure_assert_runtime_state_before_publication || return 1
        configure_assert_operator_config_revision || return 1
        configure_apply_environment_transaction || return 1
    fi
    if ! release_configure_node_lock; then
        configure_stop_runtime_after_visible_failure || true
        return 1
    fi
    ok "Installed configuration update complete."
}

delegate_unpinned_installer() {
    local mode="${1:-}" quick
    local -a args=()
    [[ "$RELEASE_TAG" == latest ]] || return 0
    quick="${SCRIPT_DIR}/quick-install.sh"
    [[ -f "$quick" && ! -L "$quick" ]] \
        || { err "An unpinned source install requires the sibling quick-install.sh entrypoint."; return 1; }
    [[ "$RELEASE_CHANNEL" == stable || "$RELEASE_CHANNEL" == beta ]] \
        || { err "Unknown 5gpn release channel: $RELEASE_CHANNEL"; return 1; }
    [[ "$RELEASE_CHANNEL" == stable ]] || args+=(--beta)
    [[ -z "$mode" ]] \
        || { err "Only a full install may delegate to quick-install.sh."; return 1; }
    info "Resolving a version-matched ${RELEASE_CHANNEL} installer bundle before installation."
    exec bash "$quick" "${args[@]}"
}

# A stamped stable installer must never reuse its own pinned artifacts for a
# beta request. Future installed management scripts keep a verified copy of
# quick-install.sh and hand the channel transition back to that resolver.
delegate_pinned_channel_switch() {
    local mode="${1:-}" quick quick_mode quick_digest base_mode quick_before quick_after quick_fd_state rc
    local -a args=(--beta)
    [[ -z "$mode" ]] \
        || { err "Only a full install may switch release channels."; return 1; }
    [[ "$RELEASE_CHANNEL_EXPLICIT" == 1 && "$RELEASE_CHANNEL" == beta ]] || return 0
    [[ "$RELEASE_TAG" != latest ]] || return 0
    valid_stable_release_tag "$RELEASE_TAG" || return 0
    quick="${SCRIPT_DIR}/quick-install.sh"
    quick_mode="$(file_mode "$quick")"
    [[ -f "$quick" && ! -L "$quick" && "$(file_uid "$quick")" == 0 \
       && "$(file_nlink "$quick")" == 1 \
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
    quick_digest="$(sha256sum -- "$quick" 2>/dev/null | awk '{print $1}')" \
        || { err "Could not hash the verified quick installer."; return 1; }
    [[ "$RELEASE_QUICK_BINDING" =~ ^[0-9a-f]{64}$ \
       && "$quick_digest" == "$RELEASE_QUICK_BINDING" ]] \
        || { err "Quick installer does not match this release generation."; return 1; }
    info "Handing the explicit beta channel switch to verified quick-install.sh; older beta lines are refused."
    [[ "$INSTALL_LOCK_HELD" == 1 ]] \
        || { err "Channel handoff requires the stale-backend check under the install lock."; return 1; }
    quick_before="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$quick" 2>/dev/null)" \
        || { err "Could not fingerprint the verified quick installer."; return 1; }
    exec 9<"$quick" \
        || { err "Could not anchor the verified quick installer."; return 1; }
    quick_fd_state="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- /proc/self/fd/9 2>/dev/null)" \
        || { exec 9<&-; err "Could not inspect the anchored quick installer."; return 1; }
    quick_after="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$quick" 2>/dev/null)" \
        || { exec 9<&-; err "Quick installer path changed during handoff."; return 1; }
    [[ "$quick_before" == "$quick_after" && "$quick_fd_state" == "$quick_after" ]] \
        || { exec 9<&-; err "Quick installer changed during handoff."; return 1; }
    # quick-install.sh takes its source lease before it waits for this lock, so
    # retaining fd 7 would invert the lock order. fd 9 instead anchors the exact
    # verified inode across unlock and exec; an atomic path replacement cannot
    # change the script this process executes.
    release_install_lock \
        || { exec 9<&-; err "Could not release the install lock before channel handoff."; return 1; }
    trap - ERR EXIT HUP INT TERM
    exec bash /proc/self/fd/9 "${args[@]}"
    rc=$?
    exec 9<&-
    return "$rc"
}

full_install() {
    local mode="" postcommit_failed=0
    local reveal_console_connection=0
    INSTALL_PUBLICATION_STARTED=0
    LOADED_DNS_ENV_SOURCE_STATE=""
    LOADED_DNS_ENV_SOURCE_REVISION=""
    LOADED_DNS_ENV_SOURCE_IDENTITY=""
    UI_GENERATION_CANDIDATE=""
    UI_GENERATION_CANDIDATE_CREATED_FROM_CURRENT=0
    # Capture the real destination before the success block enters a pipeline:
    # stdout inside `{ ...; } | card` is a pipe and can never satisfy `-t 1`.
    if [[ -t 1 ]]; then
        reveal_console_connection=1
    fi
    delegate_unpinned_installer "$mode" || return 1
    check_root || return 1
    acquire_install_lock || return 1
    INSTALL_PHASE="initializing the install transaction"
    INSTALL_FAILURE_REPORTED=0
    trap install_transaction_error ERR
    trap install_transaction_exit EXIT
    trap 'install_transaction_signal 129' HUP
    trap 'install_transaction_signal 130' INT
    trap 'install_transaction_signal 143' TERM
    assert_installed_backend_revision || return 1
    delegate_pinned_channel_switch "$mode" || return 1
    validate_quick_installer_generation || return 1
    INSTALL_PHASE="loading identity reconciliation state"
    load_identity_reconcile_journal
    preload_fivegpn_identity_for_claim
    INSTALL_PHASE="checking for unsupported legacy footprints"
    detect_legacy_footprints
    INSTALL_PHASE="checking extension worker isolation support"
    preflight_extension_worker_isolation_host
    INSTALL_PHASE="checking managed mount boundaries"
    command -v findmnt >/dev/null 2>&1 \
        || { err "findmnt is required before any managed filesystem publication."; return 1; }
    managed_roots_have_no_nested_mounts
    INSTALL_PHASE="checking current publication boundaries"
    preflight_project_root_claims
    preflight_runtime_publication_paths 1
    preflight_persisted_dns_env
    preflight_fivegpn_state_directory
    preflight_intercept_roots
    cert_root_claim_is_possible
    certificate_selection_state_is_safe
    debug_cert_root_claim_is_possible
    preflight_unit_ownership
    preflight_ui_dir
    assert_release_pin_bundle_revision \
        || { err "Release pin files changed before any installer download."; return 1; }
    # The optional TUI helper is verified inside an owned temporary directory.
    # It is not published beneath /opt/5gpn until every read-only gate and
    # staged-artifact validation below has passed.
    install_gum
    phase "checking the host and persisted configuration" "检查主机与配置"
    detect_os
    check_arch
    detect_memory_profile
    banner "$RELEASE_TAG" "${OS:-unknown} ${VER:-?} · $(uname -m 2>/dev/null || echo unknown)${MEM_TOTAL_MB:+ · ${MEM_TOTAL_MB}MB}"
    resolve_install_configuration 0
    derive_domains "$BASE_DOMAIN"
    certificate_selection_state_is_consistent_for_install "$BASE_DOMAIN" "$CERT_MODE"
    mihomo_config_matches_install_config || {
        err "The operator-owned mihomo config does not match the selected domains and listener addresses."
        err "Edit and validate the current operator-owned file explicitly before rerunning configuration."
        return 1
    }
    # The shared TUI never persists a credential while the operator is still
    # editing or may cancel the candidate. A full install nevertheless keeps a
    # missing Cloudflare credential on the fail-before-publication side by
    # collecting it only after the complete candidate and operator YAML agree.
    if cloudflare_credential_required_for_install "$BASE_DOMAIN"; then
        ensure_cf_token
    fi
    # Package installation may add shared OS packages, but no live 5gpn file has
    # been removed or replaced yet. Debug mode deliberately skips Certbot.
    phase "installing host dependencies" "安装主机依赖"
    install_deps
    INSTALL_PHASE="checking external Certbot timer state"
    preflight_global_certbot_timer_state
    managed_roots_have_no_nested_mounts
    preflight_intercept_ca_publication \
        || { err "Interception CA publication state is unsafe before binary publication."; return 1; }
    phase "verifying public console DNS" "校验公网 console DNS"
    verify_console_dns
    phase "staging and verifying release artifacts" "下载并校验发布产物"
    stage_artifacts
    INSTALL_PHASE="acquiring the certificate transaction lock"
    acquire_install_cert_lock
    INSTALL_PHASE="coordinating the external Certbot timer"
    certificate_selection_state_is_consistent_for_install "$BASE_DOMAIN" "$CERT_MODE"
    if certbot_transaction_requires_global_timer_pause "$BASE_DOMAIN" "$CERT_MODE"; then
        pause_global_certbot_timer
    fi
    INSTALL_PHASE="rechecking publication boundaries"
    preload_fivegpn_identity_for_claim
    detect_legacy_footprints
    preflight_project_root_claims
    preflight_runtime_publication_paths 1
    preflight_persisted_dns_env
    assert_loaded_persisted_dns_env_revision 0
    preflight_fivegpn_state_directory
    preflight_intercept_roots
    cert_root_claim_is_possible
    certificate_selection_state_is_consistent_for_install "$BASE_DOMAIN" "$CERT_MODE"
    debug_cert_root_claim_is_possible
    preflight_unit_ownership
    preflight_ui_dir
    validate_existing_runtime_documents
    if certbot_transaction_requires_global_timer_pause "$BASE_DOMAIN" "$CERT_MODE"; then
        pause_global_certbot_timer
    fi
    if cloudflare_credential_required_for_install "$BASE_DOMAIN"; then
        ensure_cf_token
    fi
    certificate_selection_state_is_consistent_for_install "$BASE_DOMAIN" "$CERT_MODE"
    validate_quick_installer_generation || return 1
    assert_release_pin_bundle_revision \
        || { err "Release pin files changed at the final publication boundary."; return 1; }
    INSTALL_PHASE="starting publication by claiming project roots"
    INSTALL_PUBLICATION_STARTED=1
    claim_project_roots
    revalidate_claimed_persisted_dns_env
    phase "quiescing runtime state writers" "暂停运行时写入"
    stop_managed_runtime_units
    assert_managed_accounts_quiescent
    validate_existing_runtime_documents
    publish_verified_gum
    phase "claiming publication directories" "认领发布目录"
    claim_ui_dir
    claim_intercept_roots
    phase "preparing low-memory runtime support" "准备低内存运行支持"
    ensure_swap

    # Every runtime payload has now passed its input, host-conflict, digest,
    # archive, DNS and existing-config gates. Project-root publication began
    # earlier; this is the narrower runtime-payload boundary.
    phase "installing the runtime account" "创建运行账户"
    install_service_accounts
    reconcile_fivegpn_state_directory
    phase "publishing verified executables" "发布可执行文件"
    install_mihomo
    phase "publishing runtime configuration and assets" "发布运行配置与资源"
    prepare_certificate_publication_boundaries
    install_files
    install_manage_cli
    install_units
    seed_dns_document
    write_dns_env
    ensure_intercept_certificates
    install_cert "$BASE_DOMAIN"
    render_mihomo_config
    # Do not expose a half-built fresh UI or replace a healthy current tree
    # during reinstall. Both public certificate roles and the interception CA
    # are ready before the complete Console/profile candidate is built.
    install_ui
    setup_ios_profile
    prepare_runtime_permissions
    assert_replaced_fivegpn_identity_reconciled
    complete_replaced_fivegpn_identity_reconciliation
    start_services_with_cert_lock_handoff
    verify_console_endpoint
    # Shield the short timer-restore critical section. A disconnect must not
    # leave an external/unrelated distro renewal timer stopped forever.
    trap '' HUP INT TERM
    restore_global_certbot_timer \
        || { err "The deployment is up, but the distro Certbot timer state needs repair."; postcommit_failed=1; }
    release_install_cert_lock \
        || { err "The deployment is up, but the certificate lock descriptor ended unexpectedly."; postcommit_failed=1; }
    trap 'install_transaction_signal 129' HUP
    trap 'install_transaction_signal 130' INT
    trap 'install_transaction_signal 143' TERM
    cleanup_artifact_stage \
        || { err "The deployment is up, but staging was retained at: $ARTIFACT_STAGE"; postcommit_failed=1; }
    cleanup_temporary_gum \
        || { err "The deployment is up, but temporary Gum staging could not be removed."; postcommit_failed=1; }
    release_install_lock \
        || { err "The deployment is up, but the installer lock descriptor ended unexpectedly."; postcommit_failed=1; }
    trap - ERR EXIT HUP INT TERM
    [[ "$postcommit_failed" == 0 ]] || return 1

    echo ""
    ok "5gpn install complete."
    {
        echo "✅ 5gpn 安装完成"
        echo ""
        echo "  DoT 地址         tls://${DOT_DOMAIN}:853"
        echo "  Android 私人DNS  ${DOT_DOMAIN}"
        echo "  iOS 描述文件      $(ios_profile_url ios-dot.mobileconfig)"
        echo "  MITM CA 描述文件  $(ios_profile_url ios-intercept-ca.mobileconfig)（需手动完全信任）"
        echo "  Public console   ${CONSOLE_DOMAIN} A -> ${PUBLIC_IP}（NPN 可用客户端可路由 ${GATEWAY_IP}）"
    } | card
    print_console_connection_info "$reveal_console_connection" | card
    print_qr
    echo ""
    ok "管理入口：直接输入  5gpn  打开管理菜单（状态 / 重启 / 改域名 / 改公网IP / 卸载 …）。"
}

# ----------------------------------------------------------------------------
# Usage / dispatch
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Uninstall: reverse the current monolith install. Keeps /etc/5gpn by default;
# --purge removes current runtime state except retained certificate material.
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
    trap install_transaction_error ERR
    trap install_transaction_exit EXIT
    trap 'install_transaction_signal 129' HUP
    trap 'install_transaction_signal 130' INT
    trap 'install_transaction_signal 143' TERM
    assert_installed_backend_revision || return 1
    load_identity_reconcile_journal || return 1
    if [[ -n "$REPLACED_FIVEGPN_UID" || -n "$REPLACED_FIVEGPN_GID" \
       || -n "$REPLACED_FIVEGPN_NAMED_GID" ]]; then
        err "An interrupted current runtime identity reconciliation is still pending."
        err "Rerun the installer successfully before uninstalling so preserved state is not orphaned."
        return 1
    fi
    managed_roots_have_no_nested_mounts || return 1
    claim_project_roots || return 1
    acquire_install_cert_lock || return 1
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
    for unit in 5gpn-mihomo.service 5gpn-intercept-cert.service 5gpn-intercept-cert.path 5gpn-intercept-cert.timer 5gpn-certbot-renew.timer \
                5gpn-certbot-renew.service; do
        remove_unit "$unit"
    done
    systemctl daemon-reload 2>/dev/null || true

    # Remove the exact deploy hook installed by the current release.
    remove_owned_renew_hook

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

    # Keep the installed publication helpers until decommission has finished
    # validating and removing the certificate-role tree. Removing /opt first
    # would make a safe decommission deterministically fail on its own missing
    # cert-role/publication helpers. The UI tree lives below $BASE_DIR and is
    # removed with that runtime after the certificate boundary is complete.
    remove_runtime_preserving_gum

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
        if [[ -e "$INTERCEPT_STATE_DIR" ]]; then
            claim_fixed_owned_dir "$INTERCEPT_STATE_DIR" "$INTERCEPT_STATE_MARKER" "$INTERCEPT_STATE_MARKER_VALUE" 1 \
                || { err "Refusing unsafe interception state removal."; return 1; }
        fi
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
    if [[ "$decommission" == 1 ]]; then
        remove_decommissioned_fivegpn_identity || return 1
    fi
    remove_fixed_owned_dir "$STATE_DIR" "$STATE_OWNERSHIP_MARKER" "$STATE_OWNERSHIP_VALUE" \
        || { err "Refusing unsafe installer-state removal."; return 1; }
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
  --beta              Resolve a beta prerelease through verified quick-install.sh
                      only when its base is newer than latest official. Older or
                      missing beta lines fail instead of downgrading/falling back.
  (no command)        Full install/re-run. First install requires the TUI;
                      reinstall validates and reuses /etc/5gpn/dns.env. A
                      packaged script remains pinned to its tag unless an
                      explicit beta channel switch invokes verified quick-install.sh.
  configure           Edit only a complete current installation. It does not
                      download or republish release artifacts, repair missing
                      state, or start a deliberately stopped mihomo service.
  menu                Open the interactive management menu (this is what bare '5gpn' runs)
  status              Show service state, interception state, domains, and IP
  restart             Restart the 5gpn service
  ios                 Regenerate the iOS profile + QR
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

Config: /etc/5gpn/dns.env stores exactly six host-specific installer inputs.
First install writes that schema from the TUI; reinstall reads it. Live DNS
state is only in dns.json, and ambient shell variables are discarded. The
controller secret exists only in operator-owned config.yaml. Rotate it by
editing the complete file, validating it, and explicitly restarting mihomo;
managed PUT /configs secret changes are rejected with HTTP 409.

Domains + certificates: ONE base domain and ONE scoped Let's Encrypt lineage.
  BASE_DOMAIN (e.g. example.com)     the operator's single domain knob. Two
                                     service domains are auto-derived:
                                       console.<base>  web console (mihomo :443 SNI
                                                       and zashboard panel)
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
  http-01 mode       exact console/dot SAN certificate via public TCP :80.
                     After explicit TUI confirmation, both A records must
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
TCP 80, 443, 8080, and 8443 plus UDP 443. The console panel at
/ui/ and the iOS profiles beside it are public; /5gpn/* and ordinary controller
routes require the mihomo controller secret.

  TUI configuration:
    certificate mode/email, base domain, and public/gateway/listener IPv4.
    A missing Cloudflare token is requested only after the complete candidate
    is confirmed and only when owned certificate issuance/renewal needs it.

  Automatic runtime defaults:
    dns.json starts with China/trust upstreams, China ECS, two built-in default
    subscription rules, and core-owned zero-value tuning defaults. The
    authenticated Console changes these live fields.

  Fixed release inputs:
    The 5gpn release tag plus the strictly parsed release/pins.env coordinates
    for mihomo, zashboard, and Gum are bundled and installed together. Unsigned
    profiles and profile-DNS bypasses do not exist.
EOF
}

require_command_arity() {
    local name="$1" actual="$2" minimum="$3" maximum="$4"
    if (( actual < minimum || actual > maximum )); then
        err "Command '$name' received an unsupported number of arguments."
        return 1
    fi
}

main() {
    RELEASE_CHANNEL=stable
    RELEASE_CHANNEL_EXPLICIT=0
    if [[ "${1:-}" == --beta ]]; then
        RELEASE_CHANNEL=beta
        RELEASE_CHANNEL_EXPLICIT=1
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
        configure)      require_command_arity "$cmd" "$#" 1 1 || return $?
                        [[ "$SCRIPT_DIR" == "$BASE_DIR" ]] \
                            || { err "Configure is available only through the installed 5gpn management backend."; return 1; }
                        run_management_with_install_lock configure_installation ;;
        menu)           require_command_arity "$cmd" "$#" 1 1 || return $?; manage_menu ;;
        restart)        require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_lock restart_services ;;
        status)         require_command_arity "$cmd" "$#" 1 1 || return $?; show_status ;;
        ios)            require_command_arity "$cmd" "$#" 1 1 || return $?; run_management_with_install_and_cert_lock regen_ios ;;
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
