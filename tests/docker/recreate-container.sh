#!/usr/bin/env bash
# Recreates the already-validated Compose candidate from its immutable image ID
# and the repository's fixed runtime boundary. No site-owned command is run.
set -Eeuo pipefail
export LC_ALL=C

probe_error() {
    local rc=$?
    printf 'Recreate probe failed at line %s (status %s): %s\n' \
        "${BASH_LINENO[0]}" "$rc" "$BASH_COMMAND" >&2
    return "$rc"
}
trap probe_error ERR

PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=probe-lib.sh
source "$PROBE_DIR/probe-lib.sh"

for command in docker jq stat; do
    require_probe_command "$command"
done
[[ -f "$FIVEGPN_PROBE_SECCOMP_PROFILE" \
   && ! -L "$FIVEGPN_PROBE_SECCOMP_PROFILE" ]] \
    || probe_die 'versioned seccomp profile is missing or symlinked'

inspect="$(docker inspect "$FIVEGPN_PROBE_CONTAINER")"
name="$(jq -er '.[0].Name | ltrimstr("/")' <<<"$inspect")"
backup="${name}.acceptance-backup.${BASHPID}.${RANDOM}"
image="$(jq -er '.[0].Image' <<<"$inspect")"
network="$(jq -er '.[0].HostConfig.NetworkMode' <<<"$inspect")"
project="$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<<"$inspect")"
if [[ -z "$project" && "$FIVEGPN_PROBE_ACCEPTANCE_MODE" == development ]]; then
    project="$FIVEGPN_PROBE_DEVELOPMENT_PROJECT"
fi
data_volume="$(jq -er '
  [.[0].Mounts[] | select(.Type == "volume" and .Destination == "/etc/5gpn")] |
  if length == 1 then .[0].Name else error("volume") end
' <<<"$inspect")"
ui_volume="$(jq -er '
  [.[0].Mounts[] | select(.Type == "volume" and .Destination == "/opt/5gpn/ui")] |
  if length == 1 then .[0].Name else error("ui volume") end
' <<<"$inspect")"
bootstrap_source="$(jq -er '
  [.[0].Mounts[] | select(.Type == "bind" and .Destination == "/run/5gpn-bootstrap-input/config.env")] |
  if length == 1 then .[0].Source else error("bootstrap") end
' <<<"$inspect")"
secret_source="$(jq -er '
  [.[0].Mounts[] | select(.Type == "bind" and .Destination == "/run/secrets/cloudflare_api_token")] |
  if length == 1 then .[0].Source else error("secret") end
' <<<"$inspect")"

[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ \
   && "$backup" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ \
   && "$image" =~ ^sha256:[0-9a-f]{64}$ \
   && "$network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ \
   && "$network" != host && "$network" != bridge && "$network" != default && "$network" != none \
   && "$project" =~ ^[a-z0-9][a-z0-9_-]*$ \
   && "$data_volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ \
   && "$ui_volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ \
   && "$data_volume" != "$ui_volume" ]] \
    || probe_die 'candidate identity is unsafe for fixed recreation'
[[ "$(docker network inspect "$network" | jq -r '.[0].Driver')" == bridge ]] \
    || probe_die 'candidate network is not a user-defined bridge'

safe_bind_source() {
    local path="$1" mode size
    [[ "$path" == /* && "$path" != *:* && "$path" != *,* \
       && "$path" != *$'\n'* && "$path" != *$'\r'* \
       && -f "$path" && ! -L "$path" \
       && "$(stat -c %h "$path")" == 1 ]] || return 1
    mode="$(stat -c %a "$path")"
    size="$(stat -c %s "$path")"
    [[ "$mode" =~ ^[0-7]{3,4}$ && "$size" =~ ^[0-9]+$ \
       && "$size" -gt 0 && "$size" -le 65536 ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}
safe_bind_source "$bootstrap_source" \
    || probe_die 'bootstrap bind source is unsafe'
safe_bind_source "$secret_source" \
    || probe_die 'Cloudflare secret bind source is unsafe'

[[ -z "$(docker ps -aq --filter "name=^/${backup}$")" ]] \
    || probe_die 'recreate rollback container name already exists'
renamed=false
stopped=false
rollback_recreate() {
    local rc=$?
    trap - EXIT
    if [[ "$renamed" == true ]]; then
        docker rm -f "$name" >/dev/null 2>&1 || true
        if docker rename "$backup" "$name" >/dev/null 2>&1; then
            docker start "$name" >/dev/null 2>&1 || true
        fi
    elif [[ "$stopped" == true ]]; then
        docker start "$name" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap rollback_recreate EXIT

docker stop --time 45 "$name" >/dev/null
stopped=true
stopped_state="$(docker inspect "$name" | jq -c \
    '.[0].State | {Running,ExitCode,OOMKilled,Error}')"
# A deliberately OOM-killed extension descendant can set Docker state
# OOMKilled even though PID 1 remains live and later exits normally. ExitCode
# is the authoritative orderly-PID1 result here; the worker probe already
# proves the main process survived that descendant event.
jq -e '.Running == false and .ExitCode == 0 and .Error == ""' \
    <<<"$stopped_state" >/dev/null \
    || probe_die "candidate PID 1 did not complete orderly zero-status SIGTERM shutdown: $stopped_state"
docker rename "$name" "$backup"
renamed=true
new_id="$(docker run --detach --pull never \
    --name "$name" \
    --user 10001:10001 \
    --env FIVEGPN_RUNTIME=container \
    --network "$network" \
    --publish "${FIVEGPN_PROBE_HOST_BIND_IP}:${FIVEGPN_PROBE_HOST_PORT_853}:853/tcp" \
    --publish "${FIVEGPN_PROBE_HOST_BIND_IP}:${FIVEGPN_PROBE_HOST_PORT_80}:80/tcp" \
    --publish "${FIVEGPN_PROBE_HOST_BIND_IP}:${FIVEGPN_PROBE_HOST_PORT_443}:9443/tcp" \
    --publish "${FIVEGPN_PROBE_HOST_BIND_IP}:${FIVEGPN_PROBE_HOST_PORT_443}:9443/udp" \
    --publish "${FIVEGPN_PROBE_HOST_BIND_IP}:${FIVEGPN_PROBE_HOST_PORT_8080}:8080/tcp" \
    --publish "${FIVEGPN_PROBE_HOST_BIND_IP}:${FIVEGPN_PROBE_HOST_PORT_8443}:8443/tcp" \
    --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    --cgroupns private \
    --init=false \
    --read-only \
    --cap-drop ALL \
    --security-opt writable-cgroups=true \
    --security-opt no-new-privileges=true \
    --security-opt "seccomp=${FIVEGPN_PROBE_SECCOMP_PROFILE}" \
    --pids-limit 256 \
    --restart unless-stopped \
    --stop-signal SIGTERM \
    --stop-timeout 45 \
    --label "com.docker.compose.project=${project}" \
    --label 'com.docker.compose.service=gateway' \
    --label 'com.docker.compose.oneoff=False' \
    --mount "type=volume,src=${data_volume},dst=/etc/5gpn" \
    --mount "type=volume,src=${ui_volume},dst=/opt/5gpn/ui" \
    --mount "type=bind,src=${bootstrap_source},dst=/run/5gpn-bootstrap-input/config.env,readonly" \
    --mount "type=bind,src=${secret_source},dst=/run/secrets/cloudflare_api_token,readonly" \
    --tmpfs /run/5gpn:rw,uid=10001,gid=10001,mode=0700 \
    --tmpfs /run/5gpn-bootstrap:rw,uid=10001,gid=10001,mode=0700 \
    --tmpfs /tmp:rw,uid=10001,gid=10001,mode=1777 \
    --tmpfs /var/tmp:rw,uid=10001,gid=10001,mode=1777 \
    "$image")"
[[ "$new_id" =~ ^[0-9a-f]{64}$ \
   && "$new_id" == "$(docker inspect --format '{{.Id}}' "$name")" ]] \
    || probe_die 'Docker did not return the recreated container identity'
trap - EXIT
printf '%s %s\n' "$name" "$backup"
