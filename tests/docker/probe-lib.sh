#!/usr/bin/env bash
# Shared host-side primitives for the versioned Docker acceptance probes.
# This file is sourced only by tests/container-acceptance.sh children.

[[ "${FIVEGPN_ACCEPTANCE_INTERNAL:-}" == 5gpn-container-acceptance-v2 ]] || {
    echo 'Docker acceptance probe library is not a standalone command.' >&2
    return 2 2>/dev/null || exit 2
}

probe_die() {
    printf 'Docker acceptance probe failed: %s\n' "$*" >&2
    exit 1
}

require_probe_command() {
    command -v "$1" >/dev/null 2>&1 \
        || probe_die "missing test-env command: $1"
}

container_ip() {
    local address
    address="$(docker inspect "$FIVEGPN_PROBE_CONTAINER" | jq -r '
      [.[0].NetworkSettings.Networks[]?.IPAddress | select(length > 0)] |
      if length == 1 then .[0] else empty end
    ')"
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || probe_die 'candidate container does not have one IPv4 bridge address'
    printf '%s\n' "$address"
}

container_pid() {
    local pid
    pid="$(docker inspect --format '{{.State.Pid}}' "$FIVEGPN_PROBE_CONTAINER")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || probe_die 'candidate container has no live PID 1'
    printf '%s\n' "$pid"
}

api_request() {
    local method="$1" path="$2" data="${3-}"
    local -a args=(
        --fail
        --silent
        --show-error
        --noproxy '*'
        --max-time 60
        --request "$method"
        --header "@$FIVEGPN_PROBE_HEADER_FILE"
        --header 'Content-Type: application/json'
    )
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] \
        || probe_die 'internal API probe path is invalid'
    if [[ -n "${FIVEGPN_PROBE_CONTROLLER_CA_FILE:-}" ]]; then
        args+=(--cacert "$FIVEGPN_PROBE_CONTROLLER_CA_FILE")
    fi
    if [[ -n "${FIVEGPN_PROBE_CONTROLLER_RESOLVE_IP:-}" ]]; then
        args+=(--resolve "${FIVEGPN_PROBE_CONTROLLER_HOST}:${FIVEGPN_PROBE_CONTROLLER_PORT}:${FIVEGPN_PROBE_CONTROLLER_RESOLVE_IP}")
    fi
    [[ $# -lt 3 ]] || args+=(--data-binary "$data")
    curl "${args[@]}" "${FIVEGPN_PROBE_API_ORIGIN}${path}"
}

wait_for_authenticated_capabilities() {
    local attempt payload
    for attempt in $(seq 1 90); do
        if payload="$(api_request GET /capabilities 2>/dev/null)" \
           && jq -e '
                .controllerApi == "1" and
                .features["5gpn-dns"].version == 2 and
                .features["5gpn-interception"].version == 8
              ' <<<"$payload" >/dev/null; then
            return 0
        fi
        sleep 1
    done
    probe_die 'authenticated capabilities did not become ready'
}

data_plane_status() {
    local host="$1" path="$2" ca_file="${3:-}" address
    local -a tls_args=(--insecure)
    address="$(container_ip)"
    [[ "$host" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ \
       && "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] \
        || probe_die 'internal data-plane probe target is invalid'
    if [[ -n "$ca_file" ]]; then
        [[ -f "$ca_file" && ! -L "$ca_file" ]] \
            || probe_die 'interception CA probe file is unsafe'
        tls_args=(--cacert "$ca_file")
    fi
    curl "${tls_args[@]}" --silent --show-error --noproxy '*' --http1.1 \
        --connect-timeout 5 --max-time 45 \
        --resolve "${host}:9443:${address}" \
        --output /dev/null --write-out '%{http_code}' \
        "https://${host}:9443${path}"
}

served_interception_serial() {
    local host="$1" address output serial
    address="$(container_ip)"
    output="$(timeout 10 openssl s_client \
        -connect "${address}:9443" -servername "$host" -showcerts \
        </dev/null 2>/dev/null || true)"
    serial="$(openssl x509 -noout -serial <<<"$output" 2>/dev/null | sed -n 's/^serial=//p')"
    [[ "$serial" =~ ^[0-9A-Fa-f]+$ ]] \
        || probe_die "the interception listener did not serve a certificate for $host"
    printf '%s\n' "${serial^^}"
}

aggregate_path() {
    docker exec "$FIVEGPN_PROBE_CONTAINER" /bin/bash -euo pipefail -c '
      shopt -s nullglob
      paths=(/sys/fs/cgroup/workers.1.*)
      [[ ${#paths[@]} == 1 && -d "${paths[0]}" ]]
      printf "%s\n" "${paths[0]}"
    '
}

aggregate_oom_kill_count() {
    local aggregate="$1"
    docker exec "$FIVEGPN_PROBE_CONTAINER" /bin/awk '
      $1 == "oom_kill" && $2 ~ /^[0-9]+$/ { value=$2; found=1 }
      END { if (!found) exit 1; print value }
    ' "$aggregate/memory.events"
}
