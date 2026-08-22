#!/bin/bash -p
# Bootstrap the single-container runtime, then replace this process with the
# monolith. No daemon, timer, or unattended child is left behind by this file.
set +x +v
set -Eeuo pipefail
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    while IFS= read -r exported_name; do
        unset "$exported_name" 2>/dev/null || true
    done < <(compgen -e)
fi
umask 0077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
HOME=/run/5gpn
TMPDIR=/tmp
LANG=C
LC_ALL=C
FIVEGPN_RUNTIME=container
PYTHONDONTWRITEBYTECODE=1
SAFE_PATHS=/etc/5gpn/cert/console:/etc/5gpn/cert/dot:/etc/5gpn/intercept/tls:/opt/5gpn/ui
export PATH HOME TMPDIR LANG LC_ALL FIVEGPN_RUNTIME PYTHONDONTWRITEBYTECODE SAFE_PATHS

readonly BOOTSTRAP_INPUT=/run/5gpn-bootstrap-input/config.env
readonly BOOTSTRAP_CONFIG=/run/5gpn-bootstrap/config.env
readonly CF_SECRET=/run/secrets/cloudflare_api_token
readonly CF_CREDENTIAL=/run/5gpn/cloudflare.ini
readonly CONFIG_ROOT=/etc/5gpn
readonly CGROUP_ROOT=/sys/fs/cgroup
# At least the tail of the transient retry ladder, so a permanent failure can
# never restart faster than a transient one retried.
readonly PERMANENT_ACME_HOLD_SECONDS=3600
readonly MIHOMO_HOME=/etc/5gpn/mihomo
readonly FIVEGPN_STATE=/etc/5gpn/mihomo/5gpn
readonly MIHOMO_CONFIG=/etc/5gpn/mihomo/config.yaml
readonly DNS_DOCUMENT=/etc/5gpn/mihomo/5gpn/dns.json
readonly DNS_ENV=/etc/5gpn/dns.env
readonly UI_SOURCE=/usr/share/5gpn/ui
readonly UI_DIR=/opt/5gpn/ui
readonly UI_GENERATION_HELPER=/opt/5gpn/scripts/ui-generation.sh
readonly MIHOMO_BIN=/opt/5gpn/bin/5gpn-mihomo
readonly MIHOMO_TEMPLATE=/usr/share/5gpn/config.yaml.tmpl
readonly PUBLIC_CERT_HELPER=/opt/5gpn/scripts/docker-public-cert.sh
readonly INTERCEPT_CERT_HELPER=/opt/5gpn/scripts/docker-intercept-cert.sh
readonly CONFIG_MARKER=.5gpn-owned
readonly CONFIG_MARKER_VALUE=5gpn-config
readonly DOCKER_SCHEMA_MARKER=.5gpn-docker-schema
readonly DOCKER_SCHEMA_MARKER_VALUE=5gpn-docker-state-v2
readonly DOCKER_LISTEN_IP=0.0.0.0
# Public 443 is mapped here by Compose. Keeping the tunnel socket off container
# port 443 lets the internal controller retain its load-bearing 127.0.0.1:443
# origin while the tunnel target and sniffed destination still remain :443.
readonly DOCKER_TLS_LISTEN_PORT=9443

readonly DNS_CHINA_DEFAULT=223.5.5.5
readonly DNS_TRUST_DEFAULT=22.22.22.22
readonly DNS_CHINA_ECS_DEFAULT=112.96.32.0/24
readonly DNS_CHINA_DOMAINS_DEFAULT=https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_Domain.yaml
readonly DNS_GFWLIST_DEFAULT=https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt
readonly DNS_SUBSCRIPTION_INTERVAL_DEFAULT=86400

CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
child_pid=""
child_pgid=""
spawning_child=0
shutdown_requested=0
PERSISTED_DNS_ENV=0

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }
fatal() { printf '[ERR]  %s\n' "$*" >&2; exit 1; }

request_shutdown() {
    shutdown_requested=1
    if [[ -n "$child_pgid" ]]; then
        kill -TERM -- "-$child_pgid" 2>/dev/null || true
    elif [[ "$spawning_child" == 0 ]]; then
        exit 143
    fi
}
trap request_shutdown HUP INT TERM

run_sync() {
    local rc wait_rc index
    [[ "$shutdown_requested" == 0 ]] || exit 143
    spawning_child=1
    setsid -- "$@" &
    child_pid=$!
    child_pgid="$child_pid"
    spawning_child=0
    if [[ "$shutdown_requested" == 1 ]]; then
        kill -TERM -- "-$child_pgid" 2>/dev/null || true
    fi
    set +e
    wait "$child_pid"
    rc=$?
    set -e
    if [[ "$shutdown_requested" == 1 ]]; then
        for ((index = 0; index < 10; index++)); do
            kill -0 -- "-$child_pgid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 -- "-$child_pgid" 2>/dev/null; then
            kill -KILL -- "-$child_pgid" 2>/dev/null || true
        fi
        set +e
        wait "$child_pid" 2>/dev/null
        while :; do
            wait -n 2>/dev/null
            wait_rc=$?
            [[ "$wait_rc" == 127 ]] && break
        done
        set -e
        child_pid=""
        child_pgid=""
        exit 143
    fi
    child_pid=""
    child_pgid=""
    return "$rc"
}

path_uid() { stat -c %u -- "$1"; }
path_gid() { stat -c %g -- "$1"; }
path_mode() { stat -c %a -- "$1"; }
path_nlink() { stat -c %h -- "$1"; }

collect_find_entries() {
    local output_name="$1" scan rc=0
    local -n output_ref="$output_name"
    shift
    scan="$(mktemp /run/5gpn/.find-entries.XXXXXX)" || return 1
    chmod 0600 "$scan" || { rm -f -- "$scan"; return 1; }
    if ! find "$@" -print0 > "$scan"; then
        rm -f -- "$scan"
        return 1
    fi
    mapfile -d '' -t output_ref < "$scan" || rc=$?
    rm -f -- "$scan" || return 1
    [[ "$rc" == 0 ]]
}

acquire_volume_locks() {
    command -v flock >/dev/null 2>&1 || fatal "flock is required for persistent volume exclusion."
    exec 8<"$CONFIG_ROOT"
    flock -n 8 \
        || fatal "Another container is already using the 5gpn configuration volume."
    exec 9<"$UI_DIR"
    flock -n 9 \
        || fatal "Another container is already using the 5gpn Console volume."
}

validate_volume_mounts() {
    local root target output
    command -v findmnt >/dev/null 2>&1 || fatal "findmnt is required for volume-boundary validation."
    for root in "$CONFIG_ROOT" "$UI_DIR"; do
        target="$(findmnt -r -n -o TARGET --target "$root" 2>/dev/null | head -n 1)" \
            || fatal "Could not resolve the persistent volume mount: $root"
        [[ "$target" == "$root" ]] \
            || fatal "The persistent path is not an exact volume root: $root"
        output="$(findmnt -R -r -n -o TARGET --target "$root" 2>/dev/null)" \
            || fatal "Could not enumerate the persistent volume mount: $root"
        while IFS= read -r target; do
            [[ -n "$target" ]] || continue
            [[ "$target" == "$root" ]] \
                || fatal "Nested mounts are unsupported inside the persistent volume: $target"
        done <<< "$output"
    done
}

verify_runtime_contract() {
    local output
    output="$("$MIHOMO_BIN" 5gpn-container-contract 2>/dev/null)" \
        || fatal "The image runtime does not expose its container contract."
    [[ "$output" == 5gpn-container-runtime-v2 ]] \
        || fatal "The image runtime does not implement 5gpn-container-runtime-v2."
}

# The Core re-establishes and enforces the delegated cgroup layout itself, but
# it does so after listeners are prepared and therefore after bootstrap has
# already obtained a real ACME lineage, minted the interception CA key, and
# published a complete UI generation. A host that never had writable delegation
# would burn a production certificate order on every attempt and then die with
# an isolation-probe message that never names the missing Compose setting.
# These checks are read-only and mirror the Core's own preconditions in
# 5gpn/engine/worker_process_linux.go.
verify_cgroup_delegation() {
    local fstype self controllers controller
    fstype="$(stat -f -c %T -- "$CGROUP_ROOT" 2>/dev/null)" \
        || fatal "Could not inspect $CGROUP_ROOT; the container has no cgroup mount."
    [[ "$fstype" == cgroup2fs ]] \
        || fatal "Extension workers require a pure cgroup v2 hierarchy at $CGROUP_ROOT, found '$fstype'. Use a host with unified cgroups and Docker's systemd cgroup driver."

    [[ -r /proc/self/cgroup ]] \
        || fatal "Could not read /proc/self/cgroup."
    self="$(trim "$(cat /proc/self/cgroup)")"
    [[ "$self" == '0::/' ]] \
        || fatal "The container must start in a private cgroup namespace root, found '$self'. Set 'cgroup: private' on the Compose service."

    [[ -r "$CGROUP_ROOT/cgroup.controllers" ]] \
        || fatal "Could not read $CGROUP_ROOT/cgroup.controllers."
    controllers="$(<"$CGROUP_ROOT/cgroup.controllers")"
    for controller in memory pids; do
        [[ " $controllers " == *" $controller "* ]] \
            || fatal "Extension workers require the cgroup $controller controller, which this host does not delegate."
    done

    [[ -w "$CGROUP_ROOT/cgroup.subtree_control" && -w "$CGROUP_ROOT/cgroup.procs" ]] \
        || fatal "The delegated cgroup at $CGROUP_ROOT is not writable. Set 'writable-cgroups=true' in the Compose service security_opt and use rootful Docker Engine 28 or newer."
}

assert_current_directory() {
    local path="$1"
    [[ -d "$path" && ! -L "$path" ]] \
        || fatal "Required path is not a real directory: $path"
    [[ "$(readlink -f -- "$path")" == "$path" ]] \
        || fatal "Required directory is not canonical: $path"
    [[ "$(path_uid "$path")" == "$CURRENT_UID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" ]] \
        || fatal "$path must be owned by container UID:GID ${CURRENT_UID}:${CURRENT_GID}."
}

current_directory_is_exact() {
    local path="$1" mode="$2"
    [[ -d "$path" && ! -L "$path" \
       && "$(readlink -f -- "$path")" == "$path" \
       && "$(path_uid "$path")" == "$CURRENT_UID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" \
       && "$(path_mode "$path")" == "$mode" ]]
}

safe_current_plain_file() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$CURRENT_UID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" \
       && "$(path_nlink "$path")" == 1 ]]
}

safe_private_input_file() {
    local path="$1"
    safe_current_plain_file "$path" && [[ "$(path_mode "$path")" == 600 ]]
}

safe_exact_marker() {
    local path="$1" mode="$2" value="$3"
    safe_current_plain_file "$path" \
        && [[ "$(path_mode "$path")" == "$mode" ]] \
        && printf '%s\n' "$value" | cmp -s - "$path"
}

valid_ipv4() {
    local value="$1" a b c d extra octet
    IFS=. read -r a b c d extra <<< "$value"
    [[ -z "${extra:-}" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

valid_domain() {
    local domain="$1"
    [[ ${#domain} -ge 1 && ${#domain} -le 253 \
       && "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ \
       && "$1" != -* && ${#1} -le 254 \
       && "$1" != *$'\r'* && "$1" != *$'\n'* ]]
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

declare -A BOOTSTRAP=()
prepare_bootstrap_config() {
    local size candidate
    [[ -r "$BOOTSTRAP_INPUT" ]] && safe_private_input_file "$BOOTSTRAP_INPUT" \
        || fatal "Bootstrap configuration input must be one mode-0600 file owned by container UID:GID ${CURRENT_UID}:${CURRENT_GID}: $BOOTSTRAP_INPUT"
    size="$(wc -c < "$BOOTSTRAP_INPUT" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le 65536 ]] \
        || fatal "Bootstrap configuration input has an invalid size."
    assert_current_directory /run/5gpn-bootstrap
    candidate="$(mktemp /run/5gpn-bootstrap/.config.env.XXXXXX)"
    cp -- "$BOOTSTRAP_INPUT" "$candidate"
    chmod 0600 "$candidate"
    mv -f -- "$candidate" "$BOOTSTRAP_CONFIG"
    safe_current_plain_file "$BOOTSTRAP_CONFIG" \
        || fatal "Could not secure the runtime bootstrap configuration."
}

load_bootstrap_config() {
    local raw line key value line_number=0
    [[ -f "$BOOTSTRAP_CONFIG" && ! -L "$BOOTSTRAP_CONFIG" && -r "$BOOTSTRAP_CONFIG" ]] \
        || fatal "Missing readable bootstrap configuration: $BOOTSTRAP_CONFIG"
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line_number=$((line_number + 1))
        [[ "$raw" != *$'\r'* ]] \
            || fatal "Bootstrap configuration contains CR at line $line_number."
        line="$(trim "$raw")"
        [[ -n "$line" && "${line:0:1}" != '#' ]] || continue
        [[ "$line" == *=* ]] \
            || fatal "Malformed bootstrap configuration at line $line_number."
        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] \
            || fatal "Invalid bootstrap key at line $line_number."
        case "$key" in
            DNS_BASE_DOMAIN|DNS_GATEWAY_IP|DNS_PUBLIC_IP|CERT_EMAIL|CERT_MODE) ;;
            *) fatal "Unsupported Docker bootstrap key: $key" ;;
        esac
        [[ -z "${BOOTSTRAP[$key]+present}" ]] \
            || fatal "Duplicate Docker bootstrap key: $key"
        [[ -n "$value" ]] || fatal "Docker bootstrap value is empty: $key"
        # Compare against the untrimmed line, not the trimmed one. The public
        # certificate helper reads this same file with `grep -E "^KEY="` over raw
        # bytes and then regex-checks the raw value, so a leading or trailing
        # space that a trimmed comparison accepts here would be rejected there --
        # after bootstrap had already blessed the file -- and `restart:
        # unless-stopped` would loop that failure forever.
        [[ "$raw" == "$key=$value" ]] \
            || fatal "Docker bootstrap entries must use exact KEY=value syntax with no surrounding whitespace; fix $key at line $line_number."
        BOOTSTRAP[$key]="$value"
    done < "$BOOTSTRAP_CONFIG"

    for key in DNS_BASE_DOMAIN DNS_GATEWAY_IP CERT_EMAIL; do
        [[ -n "${BOOTSTRAP[$key]:-}" ]] || fatal "Missing required Docker bootstrap key: $key"
    done
}

validate_bootstrap_values() {
    DNS_BASE_DOMAIN="${BOOTSTRAP[DNS_BASE_DOMAIN]}"
    DNS_GATEWAY_IP="${BOOTSTRAP[DNS_GATEWAY_IP]}"
    DNS_PUBLIC_IP="${BOOTSTRAP[DNS_PUBLIC_IP]:-$DNS_GATEWAY_IP}"
    CERT_EMAIL="${BOOTSTRAP[CERT_EMAIL]}"
    CERT_MODE="${BOOTSTRAP[CERT_MODE]:-cloudflare}"

    valid_domain "$DNS_BASE_DOMAIN" || fatal "DNS_BASE_DOMAIN must be a lowercase apex domain."
    valid_ipv4 "$DNS_GATEWAY_IP" || fatal "DNS_GATEWAY_IP must be an IPv4 address."
    valid_ipv4 "$DNS_PUBLIC_IP" || fatal "DNS_PUBLIC_IP must be an IPv4 address."
    valid_email "$CERT_EMAIL" || fatal "CERT_EMAIL is invalid."
    # cloudflare is the only mode that produces publicly trusted certificates,
    # and the only mode a release-mode acceptance run may use. debug issues a
    # self-signed wildcard instead, which makes every path downstream of
    # certificate issuance -- UI generation, certificate-role publication, and
    # PID 1 itself -- reachable without spending a Let's Encrypt order. A debug
    # lineage commits a distinct ready marker, so a volume bootstrapped this way
    # can never satisfy the release acceptance fingerprint.
    [[ "$CERT_MODE" == cloudflare || "$CERT_MODE" == debug ]] \
        || fatal "Docker supports only CERT_MODE=cloudflare or CERT_MODE=debug."
    DNS_MIHOMO_LISTEN_IPS="$DOCKER_LISTEN_IP"
    CONSOLE_DOMAIN="console.${DNS_BASE_DOMAIN}"
    DOT_DOMAIN="dot.${DNS_BASE_DOMAIN}"
}

dns_env_get() {
    local key="$1" count
    count="$(grep -cE "^${key}=" "$DNS_ENV" 2>/dev/null || true)"
    [[ "$count" == 1 ]] || return 1
    sed -n "s/^${key}=//p" "$DNS_ENV"
}

load_persisted_dns_env() {
    local raw line key value mode
    local -A seen=()
    if [[ ! -e "$DNS_ENV" && ! -L "$DNS_ENV" ]]; then
        PERSISTED_DNS_ENV=0
        return
    fi
    safe_current_plain_file "$DNS_ENV" \
        || fatal "Existing Docker dns.env is unsafe."
    mode="$(path_mode "$DNS_ENV")"
    (( (8#$mode & 0077) == 0 )) \
        || fatal "Existing Docker dns.env must be private to UID 10001."

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        [[ "$raw" != *$'\r'* ]] || fatal "Existing Docker dns.env contains CR bytes."
        line="$(trim "$raw")"
        [[ -n "$line" && "${line:0:1}" != '#' ]] || continue
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] \
            || fatal "Existing Docker dns.env contains a malformed entry."
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        case "$key" in
            DNS_BASE_DOMAIN|DNS_PUBLIC_IP|DNS_GATEWAY_IP|DNS_MIHOMO_LISTEN_IPS|CERT_MODE|CERT_EMAIL) ;;
            *) fatal "Existing Docker dns.env contains an unsupported key: $key" ;;
        esac
        [[ -z "${seen[$key]+present}" && -n "$value" \
           && "$raw" == "$line" && "$line" == "$key=$value" ]] \
            || fatal "Existing Docker dns.env contains a duplicate or non-canonical entry: $key"
        seen[$key]=1
    done < "$DNS_ENV"

    [[ "${#seen[@]}" == 6 \
       && "$(dns_env_get DNS_BASE_DOMAIN)" == "$DNS_BASE_DOMAIN" \
       && "$(dns_env_get DNS_PUBLIC_IP)" == "$DNS_PUBLIC_IP" \
       && "$(dns_env_get DNS_GATEWAY_IP)" == "$DNS_GATEWAY_IP" \
       && "$(dns_env_get DNS_MIHOMO_LISTEN_IPS)" == "$DNS_MIHOMO_LISTEN_IPS" \
       && "$(dns_env_get CERT_MODE)" == "$CERT_MODE" \
       && "$(dns_env_get CERT_EMAIL)" == "$CERT_EMAIL" ]] \
        || fatal "Bootstrap coordinates conflict with the persisted Docker dns.env."
    PERSISTED_DNS_ENV=1
}

prepare_runtime_directories() {
    assert_current_directory "$CONFIG_ROOT"
    [[ "$(path_mode "$CONFIG_ROOT")" == 750 ]] \
        || fatal "$CONFIG_ROOT must retain mode 0750."
    safe_exact_marker "$CONFIG_ROOT/$CONFIG_MARKER" 644 "$CONFIG_MARKER_VALUE" \
        || fatal "The /etc/5gpn volume is missing its ownership marker."
    safe_exact_marker "$CONFIG_ROOT/$DOCKER_SCHEMA_MARKER" 644 "$DOCKER_SCHEMA_MARKER_VALUE" \
        || fatal "The /etc/5gpn volume is not a current Docker state-v2 volume."
    assert_current_directory "$MIHOMO_HOME"
    [[ "$(path_mode "$MIHOMO_HOME")" == 750 ]] \
        || fatal "$MIHOMO_HOME must retain mode 0750."
    assert_current_directory "$FIVEGPN_STATE"
    [[ "$(path_mode "$FIVEGPN_STATE")" == 711 ]] \
        || fatal "$FIVEGPN_STATE must retain mode 0711."
    assert_current_directory /run/5gpn
    assert_current_directory "$UI_DIR"
    [[ "$(path_mode "$UI_DIR")" == 755 ]] \
        || fatal "$UI_DIR must retain mode 0755."
}

validate_ui_source() {
    [[ -x "$UI_GENERATION_HELPER" && -f "$UI_GENERATION_HELPER" \
       && ! -L "$UI_GENERATION_HELPER" \
       && "$(path_uid "$UI_GENERATION_HELPER")" == 0 \
       && "$(path_gid "$UI_GENERATION_HELPER")" == 0 \
       && "$(path_mode "$UI_GENERATION_HELPER")" == 755 \
       && "$(path_nlink "$UI_GENERATION_HELPER")" == 1 ]] \
        || fatal "The immutable UI generation validator is unavailable."
    [[ -d "$UI_SOURCE" && ! -L "$UI_SOURCE" \
       && -f "$UI_SOURCE/index.html" && ! -L "$UI_SOURCE/index.html" ]] \
        || fatal "The image does not contain a safe Console bundle."
    [[ -z "$(find "$UI_SOURCE" -mindepth 1 \( -type l -o ! -type d ! -type f \) -print -quit)" ]] \
        || fatal "The image Console bundle contains an unsafe object."
    [[ -z "$(find "$UI_SOURCE" -type f -links +1 -print -quit)" ]] \
        || fatal "The image Console bundle contains a hard-linked file."
    local generated
    for generated in .zash_version .zash_primary_files .zash_compat_files \
                     .5gpn-ui-base-target .5gpn-ui-generation-owned \
                     .5gpn-profile-inputs ios-dot.mobileconfig \
                     ios-intercept-ca.mobileconfig .5gpn-zashboard-owned; do
        [[ ! -e "$UI_SOURCE/$generated" && ! -L "$UI_SOURCE/$generated" ]] \
            || fatal "The image Console source contains generated metadata: $generated"
    done
    [[ -z "$(find "$UI_SOURCE" -mindepth 1 \
        \( -name '.ios-profile.*' -o -name '.ios-*.new.*' \
           -o -name '.5gpn-profile-inputs.new.*' \) -print -quit)" ]] \
        || fatal "The image Console source contains transient generation artifacts."
    FIVEGPN_RUNTIME=container "$UI_GENERATION_HELPER" validate-image-source \
        || fatal "The image Console source failed the shared generation validator."
}

reject_legacy_footprints() {
    local path
    local -a unsupported=(
        "$CONFIG_ROOT/mihomo/gpn"
        "$CONFIG_ROOT/rules"
        "$CONFIG_ROOT/cert/web"
        "$CONFIG_ROOT/cert/.5gpn-docker-cert-root-owned"
        "$CONFIG_ROOT/cert/dot/.5gpn-docker-cert-role-owned"
        "$CONFIG_ROOT/cert/console/.5gpn-docker-cert-role-owned"
        "$FIVEGPN_STATE/policy.json"
        "$FIVEGPN_STATE/upstreams.json"
        "$FIVEGPN_STATE/ecs.json"
        "$FIVEGPN_STATE/subscriptions.json"
        "$FIVEGPN_STATE/stats.json"
        "$CONFIG_ROOT/intercept/config.json"
    )
    for path in "${unsupported[@]}"; do
        [[ ! -e "$path" && ! -L "$path" ]] \
            || fatal "Unsupported legacy Docker footprint requires explicit volume replacement: $path"
    done
}

validate_seeded_security_roots() {
    current_directory_is_exact "$CONFIG_ROOT/cert" 751 \
        && safe_exact_marker "$CONFIG_ROOT/cert/.5gpn-cert-root-owned" 644 \
            5gpn-cert-root-v1 \
        || fatal "The Docker public certificate root is not current."
    local role
    for role in dot console; do
        current_directory_is_exact "$CONFIG_ROOT/cert/$role" 750 \
            && current_directory_is_exact "$CONFIG_ROOT/cert/$role/generations" 750 \
            && safe_exact_marker "$CONFIG_ROOT/cert/$role/.5gpn-cert-role-owned" 644 \
                "5gpn-cert-role-v1:$role" \
            || fatal "The Docker $role certificate role root is not current."
    done
    current_directory_is_exact "$CONFIG_ROOT/intercept-ca" 700 \
        && safe_exact_marker "$CONFIG_ROOT/intercept-ca/.5gpn-intercept-ca-owned" 644 \
            5gpn-intercept-ca-v1 \
        || fatal "The Docker interception CA root is not current."
    current_directory_is_exact "$CONFIG_ROOT/intercept" 750 \
        && current_directory_is_exact "$CONFIG_ROOT/intercept/tls" 750 \
        && safe_exact_marker "$CONFIG_ROOT/intercept/.5gpn-docker-intercept-owned" 600 \
            5gpn-docker-intercept-v1 \
        || fatal "The Docker interception publication root is not current."
    current_directory_is_exact "$CONFIG_ROOT/letsencrypt" 700 \
        && current_directory_is_exact "$CONFIG_ROOT/letsencrypt/work" 700 \
        && current_directory_is_exact "$CONFIG_ROOT/letsencrypt/log" 700 \
        && safe_exact_marker "$CONFIG_ROOT/letsencrypt/.5gpn-docker-letsencrypt-owned" 600 \
            5gpn-docker-letsencrypt-v1 \
        || fatal "The Docker Certbot root is not current."
}

validate_config_candidates() {
    local entry name
    local -a candidates=()
    collect_find_entries candidates "$MIHOMO_HOME" \
        -mindepth 1 -maxdepth 1 -name '.config.yaml.*' \
        || fatal "Could not enumerate interrupted operator-config candidates."
    for entry in "${candidates[@]}"; do
        name="$(basename -- "$entry")"
        [[ "$name" =~ ^\.config\.yaml\.[0-9A-Za-z]{6}$ \
           && -f "$entry" && ! -L "$entry" \
           && "$(path_uid "$entry")" == "$CURRENT_UID" \
           && "$(path_gid "$entry")" == "$CURRENT_GID" \
           && "$(path_mode "$entry")" == 600 \
           && "$(path_nlink "$entry")" == 1 ]] \
            || fatal "Unsafe interrupted operator-config candidate: $entry"
    done
}

scrub_config_candidates() {
    local entry removed=0
    local -a candidates=()
    validate_config_candidates
    collect_find_entries candidates "$MIHOMO_HOME" \
        -mindepth 1 -maxdepth 1 -name '.config.yaml.*' \
        || fatal "Could not enumerate interrupted operator-config candidates."
    for entry in "${candidates[@]}"; do
        rm -f -- "$entry"
        removed=1
    done
    [[ "$removed" == 0 ]] || sync -f "$MIHOMO_HOME"
}

validate_publication_candidates() {
    local entry name expected_parent
    local -a candidates=()
    collect_find_entries candidates "$CONFIG_ROOT" \
        -mindepth 1 -maxdepth 1 -name '.dns.env.*' \
        || fatal "Could not enumerate interrupted dns.env candidates."
    local -a state_candidates=()
    collect_find_entries state_candidates "$FIVEGPN_STATE" \
        -mindepth 1 -maxdepth 1 -name '.dns.json.*' \
        || fatal "Could not enumerate interrupted DNS-document candidates."
    candidates+=("${state_candidates[@]}")
    for entry in "${candidates[@]}"; do
        name="$(basename -- "$entry")"
        expected_parent="$(dirname -- "$entry")"
        [[ ( "$expected_parent" == "$CONFIG_ROOT" \
             && "$name" =~ ^\.dns\.env\.[0-9A-Za-z]{6}$ ) \
           || ( "$expected_parent" == "$FIVEGPN_STATE" \
                && "$name" =~ ^\.dns\.json\.[0-9A-Za-z]{6}$ ) ]] \
            || fatal "Unexpected publication candidate path: $entry"
        [[ -f "$entry" && ! -L "$entry" \
           && "$(path_uid "$entry")" == "$CURRENT_UID" \
           && "$(path_gid "$entry")" == "$CURRENT_GID" \
           && "$(path_mode "$entry")" == 600 \
           && "$(path_nlink "$entry")" == 1 ]] \
            || fatal "Unsafe interrupted publication candidate: $entry"
    done
}

scrub_publication_candidates() {
    local entry config_removed=0 state_removed=0
    local -a candidates=()
    validate_publication_candidates
    collect_find_entries candidates "$CONFIG_ROOT" \
        -mindepth 1 -maxdepth 1 -name '.dns.env.*' \
        || fatal "Could not enumerate interrupted dns.env candidates."
    for entry in "${candidates[@]}"; do rm -f -- "$entry"; config_removed=1; done
    collect_find_entries candidates "$FIVEGPN_STATE" \
        -mindepth 1 -maxdepth 1 -name '.dns.json.*' \
        || fatal "Could not enumerate interrupted DNS-document candidates."
    for entry in "${candidates[@]}"; do rm -f -- "$entry"; state_removed=1; done
    [[ "$config_removed" == 0 ]] || sync -f "$CONFIG_ROOT"
    [[ "$state_removed" == 0 ]] || sync -f "$FIVEGPN_STATE"
}

validate_existing_ui_generation() {
    local first
    first="$(find "$UI_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
    [[ -n "$first" ]] \
        || fatal "The Console volume is missing its image-seeded generation boundary."
    [[ -x "$UI_GENERATION_HELPER" && -f "$UI_GENERATION_HELPER" \
       && ! -L "$UI_GENERATION_HELPER" \
       && "$(path_uid "$UI_GENERATION_HELPER")" == 0 \
       && "$(path_gid "$UI_GENERATION_HELPER")" == 0 \
       && "$(path_mode "$UI_GENERATION_HELPER")" == 755 \
       && "$(path_nlink "$UI_GENERATION_HELPER")" == 1 ]] \
        || fatal "The immutable UI generation validator is unavailable."
    FIVEGPN_RUNTIME=container "$UI_GENERATION_HELPER" preflight \
        || fatal "The persisted Console volume is not a safe current or recoverable generation tree."
}

validate_runtime_documents() {
    local result
    result="$(mktemp /run/5gpn/.state-validation.XXXXXX)"
    chmod 0600 "$result"
    if ! run_sync "$MIHOMO_BIN" 5gpn-state validate --owner-uid "$CURRENT_UID" \
            "$FIVEGPN_STATE" > "$result"; then
        rm -f -- "$result"
        fatal "Existing runtime documents failed the pinned Core validator."
    fi
    jq -e '.status == "ok" and (.validated | type == "array") and (.missing | type == "array")' \
        "$result" >/dev/null \
        || { rm -f -- "$result"; fatal "The Core state validator returned an invalid result."; }
    rm -f -- "$result"
}

inspect_existing_operator_config() {
    local result expected_revision mode
    [[ -e "$MIHOMO_CONFIG" || -L "$MIHOMO_CONFIG" ]] || return 0
    [[ "$PERSISTED_DNS_ENV" == 1 ]] \
        || fatal "Existing operator config has no current six-key dns.env."
    safe_current_plain_file "$MIHOMO_CONFIG" \
        || fatal "Existing operator mihomo config is unsafe: $MIHOMO_CONFIG"
    mode="$(path_mode "$MIHOMO_CONFIG")"
    (( (8#$mode & 0022) == 0 )) \
        || fatal "Existing operator mihomo config is group/other writable."
    result="$(mktemp /run/5gpn/.controller-inspection.XXXXXX)"
    chmod 0600 "$result"
    if ! run_sync "$MIHOMO_BIN" 5gpn-config inspect-controller \
            --owner-uid "$CURRENT_UID" --config "$MIHOMO_CONFIG" > "$result"; then
        rm -f -- "$result"
        fatal "Existing operator config failed managed-controller inspection."
    fi
    expected_revision="$(sha256sum "$MIHOMO_CONFIG" | awk '{print $1}')"
    jq -e --arg revision "$expected_revision" '
        type == "object" and .version == 2 and .raw_revision == $revision
        and .external_controller_tls == "127.0.0.1:443"
        and .external_ui == "/opt/5gpn/ui/current"
        and .certificate == "/etc/5gpn/cert/console/current/fullchain.pem"
        and .private_key == "/etc/5gpn/cert/console/current/privkey.pem"
        and (.secret | type == "string" and length >= 16 and length <= 256)
        and ((keys | sort) == ["certificate","external_controller_tls","external_ui","private_key","raw_revision","secret","version"])
    ' "$result" >/dev/null \
        || { rm -f -- "$result"; fatal "Existing operator config does not match the managed container controller boundary."; }
    rm -f -- "$result"
    run_sync "$MIHOMO_BIN" -t -f "$MIHOMO_CONFIG" -d "$MIHOMO_HOME" \
        || fatal "Existing operator mihomo config is invalid and was preserved."
}

validate_existing_dns_coordinates() {
    [[ -e "$DNS_DOCUMENT" || -L "$DNS_DOCUMENT" ]] || return 0
    jq -e \
       --arg cert /etc/5gpn/cert/dot/current/fullchain.pem \
       --arg key /etc/5gpn/cert/dot/current/privkey.pem \
       --arg gateway "$DNS_GATEWAY_IP" \
       'type == "object"
        and .listen.dot == ":853"
        and .listen.debug == "127.0.0.1:5353"
        and .listen.origin == "127.0.0.1:5354"
        and .listen.certificate == $cert
        and .listen.privateKey == $key
        and .gateway == $gateway' \
       "$DNS_DOCUMENT" >/dev/null \
        || fatal "Persisted DNS coordinates conflict with the Docker deployment."
}

repair_existing_file_durability() {
    local path parent
    for path in "$DNS_ENV" "$MIHOMO_CONFIG" "$DNS_DOCUMENT"; do
        [[ -e "$path" || -L "$path" ]] || continue
        safe_current_plain_file "$path" \
            || fatal "Cannot repair durability for an unsafe current file: $path"
        parent="$(dirname -- "$path")"
        sync -f "$path" \
            && sync -f "$parent" \
            || fatal "Could not repair current file durability: $path"
    done
}

preflight_certificate_state() {
    run_sync "$PUBLIC_CERT_HELPER" preflight \
        || fatal "Docker public certificate state failed read-only preflight."
    run_sync "$INTERCEPT_CERT_HELPER" preflight \
        || fatal "Docker interception certificate state failed read-only preflight."
}

prepare_cloudflare_credential() {
    local token file_size token_size last_byte candidate
    [[ -r "$CF_SECRET" ]] && safe_private_input_file "$CF_SECRET" \
        || fatal "Cloudflare API token secret must be one mode-0600 file owned by container UID:GID ${CURRENT_UID}:${CURRENT_GID}: $CF_SECRET"
    file_size="$(wc -c < "$CF_SECRET" | tr -d '[:space:]')"
    [[ "$file_size" =~ ^[0-9]+$ && "$file_size" -gt 0 && "$file_size" -le 4096 ]] \
        || fatal "Cloudflare API token secret has an invalid size."
    token="$(<"$CF_SECRET")"
    [[ "$token" =~ ^[A-Za-z0-9_-]{20,200}$ ]] \
        || fatal "Cloudflare API token secret has an invalid format."
    token_size="${#token}"
    if (( file_size == token_size + 1 )); then
        last_byte="$(tail -c 1 "$CF_SECRET" | od -An -tx1 | tr -d '[:space:]')"
        [[ "$last_byte" == 0a ]] \
            || fatal "Cloudflare API token secret contains trailing data."
    elif (( file_size != token_size )); then
        fatal "Cloudflare API token secret must contain one raw token."
    fi
    candidate="$(mktemp /run/5gpn/.cloudflare.ini.XXXXXX)"
    printf 'dns_cloudflare_api_token = %s\n' "$token" > "$candidate"
    chmod 0600 "$candidate"
    mv -f -- "$candidate" "$CF_CREDENTIAL"
    unset token
}

bootstrap_public_certificate() {
    local rc delay_index=0 delay
    local -a delays=(60 300 1800 3600)
    while :; do
        if run_sync "$PUBLIC_CERT_HELPER" bootstrap; then
            return 0
        else
            rc=$?
        fi
        if [[ "$rc" == 78 ]]; then
            # 78 is the helper's permanent verdict: the operator must change
            # something before any attempt can succeed. Exiting is nonetheless
            # not a way to stop attempting. `restart: unless-stopped` restarts
            # on every exit code, and Docker resets its restart backoff whenever
            # the previous run lasted at least ten seconds -- which every
            # bootstrap does, since the runtime handshake, volume locks, mount
            # validation, and interception CA init all precede certbot.
            # Measured on Docker 29: a container that runs 12s and exits 1
            # restarts roughly every 15s, with no backoff growth at all. So
            # returning here immediately would turn one permanent
            # misconfiguration into a fresh Let's Encrypt order every 15
            # seconds, an order of magnitude worse than the ladder below.
            # Holding first bounds it to about one order per hour while the
            # operator reads the cause the helper already printed.
            info "Permanent ACME failure; holding ${PERMANENT_ACME_HOLD_SECONDS}s before exit so the container restart policy cannot re-enter the Let's Encrypt order budget."
            run_sync sleep "$PERMANENT_ACME_HOLD_SECONDS" || return $?
            return 78
        fi
        [[ "$rc" == 75 ]] || return "$rc"
        if (( delay_index >= ${#delays[@]} )); then
            return 75
        fi
        delay="${delays[$delay_index]}"
        delay_index=$((delay_index + 1))
        info "Temporary ACME failure; retrying public certificate bootstrap in ${delay}s."
        run_sync sleep "$delay" || return $?
    done
}

render_listeners() {
    printf '  - {name: gateway, type: tunnel, listen: %s, port: %s, network: [tcp, udp], target: %s:443}\n' "$DOCKER_LISTEN_IP" "$DOCKER_TLS_LISTEN_PORT" "$CONSOLE_DOMAIN"
    printf '  - {name: gateway80, type: tunnel, listen: %s, port: 80, network: [tcp], target: %s:80}\n' "$DOCKER_LISTEN_IP" "$CONSOLE_DOMAIN"
    printf '  - {name: gateway8080, type: tunnel, listen: %s, port: 8080, network: [tcp], target: %s:8080}\n' "$DOCKER_LISTEN_IP" "$CONSOLE_DOMAIN"
    printf '  - {name: gateway8443, type: tunnel, listen: %s, port: 8443, network: [tcp], target: %s:8443}\n' "$DOCKER_LISTEN_IP" "$CONSOLE_DOMAIN"
}

render_mihomo_seed() {
    local destination="$1" secret="$2" line listeners
    listeners="$(render_listeners)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == __MIHOMO_LISTENERS__ ]]; then
            printf '%s\n' "$listeners"
            continue
        fi
        line="${line//__CONSOLE_DOMAIN__/$CONSOLE_DOMAIN}"
        line="${line//__CONTROLLER_SECRET__/$secret}"
        printf '%s\n' "$line"
    done < "$MIHOMO_TEMPLATE" > "$destination"
}

yaml_single_quoted_value() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

prepare_mihomo_config() {
    local candidate secret secret_yaml mode
    [[ -x "$MIHOMO_BIN" && -f "$MIHOMO_TEMPLATE" && ! -L "$MIHOMO_TEMPLATE" ]] \
        || fatal "The image runtime or seed template is missing."
    if [[ -e "$MIHOMO_CONFIG" || -L "$MIHOMO_CONFIG" ]]; then
        safe_current_plain_file "$MIHOMO_CONFIG" \
            || fatal "Existing operator mihomo config is unsafe: $MIHOMO_CONFIG"
        mode="$(path_mode "$MIHOMO_CONFIG")"
        (( (8#$mode & 0022) == 0 )) \
            || fatal "Existing operator mihomo config is group/other writable."
        run_sync "$MIHOMO_BIN" -t -f "$MIHOMO_CONFIG" -d "$MIHOMO_HOME" \
            || fatal "Existing operator mihomo config is invalid and was preserved."
        ok "Existing operator mihomo config validated and preserved."
        return
    fi

    secret="$(openssl rand -hex 32)"
    [[ "$secret" =~ ^[A-Za-z0-9._~-]{16,256}$ ]] \
        || fatal "A fresh controller secret must contain 16 to 256 URL-safe characters."
    secret_yaml="$(yaml_single_quoted_value "$secret")" \
        || fatal "The fresh controller secret cannot be represented safely in YAML."
    candidate="$(mktemp "$MIHOMO_HOME/.config.yaml.XXXXXX")"
    render_mihomo_seed "$candidate" "$secret_yaml"
    chmod 0600 "$candidate"
    run_sync "$MIHOMO_BIN" -t -f "$candidate" -d "$MIHOMO_HOME" \
        || { rm -f -- "$candidate"; fatal "Generated mihomo config failed validation."; }
    sync -f "$candidate"
    mv -f -- "$candidate" "$MIHOMO_CONFIG"
    sync -f "$MIHOMO_HOME" \
        || fatal "Operator config rename committed, but directory durability is unconfirmed."
    ok "Initial operator-owned mihomo config published."
}

write_dns_env() {
    local candidate
    [[ "$PERSISTED_DNS_ENV" == 0 ]] || return 0
    if [[ -e "$DNS_ENV" || -L "$DNS_ENV" ]]; then
        safe_current_plain_file "$DNS_ENV" \
            || fatal "Existing dns.env path is unsafe."
    fi
    candidate="$(mktemp "$CONFIG_ROOT/.dns.env.XXXXXX")"
    cat > "$candidate" <<EOF
# 5gpn Docker installation coordinates. Live DNS, interception, and bot state
# lives under /etc/5gpn/mihomo/5gpn and is not mirrored here.
DNS_BASE_DOMAIN=${DNS_BASE_DOMAIN}
DNS_PUBLIC_IP=${DNS_PUBLIC_IP}
DNS_GATEWAY_IP=${DNS_GATEWAY_IP}
DNS_MIHOMO_LISTEN_IPS=${DNS_MIHOMO_LISTEN_IPS}
CERT_MODE=${CERT_MODE}
CERT_EMAIL=${CERT_EMAIL}
EOF
    chmod 0600 "$candidate"
    sync -f "$candidate"
    mv -f -- "$candidate" "$DNS_ENV"
    sync -f "$CONFIG_ROOT" \
        || fatal "dns.env rename committed, but directory durability is unconfirmed."
    PERSISTED_DNS_ENV=1
}

ensure_dns_env() {
    if [[ "$PERSISTED_DNS_ENV" == 1 ]]; then
        return
    fi
    [[ ! -e "$MIHOMO_CONFIG" && ! -L "$MIHOMO_CONFIG" ]] \
        || fatal "Existing operator config has no current Docker dns.env; refusing to infer installation coordinates."
    write_dns_env
}

validate_dns_candidate() {
    local candidate="$1" stage result document
    stage="$(mktemp -d /run/5gpn/.state-candidate.XXXXXX)"
    chmod 0711 "$stage"
    result="$(mktemp /run/5gpn/.state-candidate-result.XXXXXX)"
    chmod 0600 "$result"
    install -m 0600 -- "$candidate" "$stage/dns.json"
    for document in intercept.json bot.json; do
        if [[ -e "$FIVEGPN_STATE/$document" || -L "$FIVEGPN_STATE/$document" ]]; then
            safe_current_plain_file "$FIVEGPN_STATE/$document" \
                || { rm -f -- "$result" "$stage/dns.json"; rmdir -- "$stage"; return 1; }
            install -m 0600 -- "$FIVEGPN_STATE/$document" "$stage/$document"
        fi
    done
    if ! run_sync "$MIHOMO_BIN" 5gpn-state validate --owner-uid "$CURRENT_UID" \
            "$stage" > "$result" \
       || ! jq -e '.status == "ok" and (.validated | index("dns.json")) != null' \
            "$result" >/dev/null; then
        rm -f -- "$result" "$stage/dns.json" "$stage/intercept.json" "$stage/bot.json"
        rmdir -- "$stage"
        return 1
    fi
    rm -f -- "$result" "$stage/dns.json" "$stage/intercept.json" "$stage/bot.json"
    rmdir -- "$stage"
}

write_dns_document() {
    local candidate
    if [[ -e "$DNS_DOCUMENT" || -L "$DNS_DOCUMENT" ]]; then
        safe_current_plain_file "$DNS_DOCUMENT" \
            || fatal "Existing DNS document is unsafe: $DNS_DOCUMENT"
        jq -e \
           --arg cert /etc/5gpn/cert/dot/current/fullchain.pem \
           --arg key /etc/5gpn/cert/dot/current/privkey.pem \
           --arg gateway "$DNS_GATEWAY_IP" \
           'type == "object"
            and .listen.dot == ":853"
            and .listen.debug == "127.0.0.1:5353"
            and .listen.origin == "127.0.0.1:5354"
            and .listen.certificate == $cert
            and .listen.privateKey == $key
            and .gateway == $gateway' \
           "$DNS_DOCUMENT" >/dev/null \
            || fatal "Persisted DNS document conflicts with Docker installation coordinates."
        return
    fi
    candidate="$(mktemp "$FIVEGPN_STATE/.dns.json.XXXXXX")"
    jq -n \
       --arg cert /etc/5gpn/cert/dot/current/fullchain.pem \
       --arg key /etc/5gpn/cert/dot/current/privkey.pem \
       --arg gateway "$DNS_GATEWAY_IP" \
       --arg china "$DNS_CHINA_DEFAULT" \
       --arg trust "$DNS_TRUST_DEFAULT" \
       --arg ecs "$DNS_CHINA_ECS_DEFAULT" \
       --arg chinaDomains "$DNS_CHINA_DOMAINS_DEFAULT" \
       --arg gfwlist "$DNS_GFWLIST_DEFAULT" \
       --argjson interval "$DNS_SUBSCRIPTION_INTERVAL_DEFAULT" \
       '{
          listen: {
            dot: ":853",
            debug: "127.0.0.1:5353",
            origin: "127.0.0.1:5354",
            certificate: $cert,
            privateKey: $key
          },
          gateway: $gateway,
          upstreams: {china: [($china + ":53")], trust: [($trust + ":53")], ecs: $ecs},
          policy: {
            rules: [
              {id: "china-domains", kind: "subscription", value: $chinaDomains,
               intent: "direct", enabled: true, format: "clash", intervalSeconds: $interval},
              {id: "gfwlist", kind: "subscription", value: $gfwlist,
               intent: "proxy", enabled: true, format: "plain", intervalSeconds: $interval}
            ],
            fallback: "auto"
          },
          tuning: {}
       }' > "$candidate" \
        || { rm -f -- "$candidate"; fatal "Could not render the DNS document."; }
    chmod 0600 "$candidate"
    validate_dns_candidate "$candidate" \
        || { rm -f -- "$candidate"; fatal "The fresh DNS document failed the pinned Core validator."; }
    sync -f "$candidate"
    mv -f -- "$candidate" "$DNS_DOCUMENT"
    sync -f "$FIVEGPN_STATE" \
        || fatal "DNS document rename committed, but directory durability is unconfirmed."
}

main() {
    [[ $# == 0 ]] || fatal "The Docker image has one fixed gateway entrypoint and accepts no command override."
    [[ "${FIVEGPN_RUNTIME:-}" == container ]] \
        || fatal "FIVEGPN_RUNTIME must be exactly 'container'."
    [[ "$CURRENT_UID" == 10001 && "$CURRENT_GID" == 10001 ]] \
        || fatal "The OCI process must start as fixed UID:GID 10001:10001."

    verify_runtime_contract
    verify_cgroup_delegation
    prepare_bootstrap_config
    load_bootstrap_config
    validate_bootstrap_values
    prepare_runtime_directories
    acquire_volume_locks
    validate_volume_mounts
    validate_ui_source
    load_persisted_dns_env
    reject_legacy_footprints
    validate_seeded_security_roots
    validate_config_candidates
    validate_publication_candidates
    validate_runtime_documents
    validate_existing_ui_generation
    inspect_existing_operator_config
    validate_existing_dns_coordinates
    repair_existing_file_durability
    preflight_certificate_state
    # debug issues its wildcard locally and never reads a Cloudflare token, so
    # requiring the secret would make the mode unusable for its whole purpose.
    if [[ "$CERT_MODE" == cloudflare ]]; then
        prepare_cloudflare_credential
    fi
    scrub_config_candidates
    scrub_publication_candidates

    info "Initializing the Docker interception CA."
    run_sync "$INTERCEPT_CERT_HELPER" init-ca \
        || fatal "Docker interception CA initialization failed."
    if [[ "$CERT_MODE" == debug ]]; then
        info "Issuing the self-signed debug public certificate (NOT publicly trusted)."
    else
        info "Bootstrapping the Cloudflare public certificate."
    fi
    bootstrap_public_certificate \
        || fatal "Docker public certificate bootstrap failed."

    ensure_dns_env
    prepare_mihomo_config
    write_dns_document

    ok "Bootstrap complete; starting the 5gpn monolith."
    [[ "$shutdown_requested" == 0 ]] || exit 143
    exec "$MIHOMO_BIN" -f "$MIHOMO_CONFIG" -d "$MIHOMO_HOME"
}

main "$@"
