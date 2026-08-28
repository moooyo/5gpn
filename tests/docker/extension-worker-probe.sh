#!/usr/bin/env bash
# Installs one owned fixture and proves real script execution, automatic
# interception-certificate publication, cgroup OOM classification, cleanup,
# and continued PID-1 health. Run only through container-acceptance.sh.
set -Eeuo pipefail
export LC_ALL=C

probe_error() {
    local rc=$?
    printf 'Extension/worker probe failed at line %s (status %s): %s\n' \
        "${BASH_LINENO[0]}" "$rc" "$BASH_COMMAND" >&2
    return "$rc"
}
trap probe_error ERR

PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=probe-lib.sh
source "$PROBE_DIR/probe-lib.sh"

for command in curl docker jq openssl seq sha256sum timeout; do
    require_probe_command "$command"
done

run_id="$(openssl rand -hex 8)"
extension_id="acceptance.docker.${run_id}"
capture_host="docker-${run_id}.acceptance.example"
request_file=/etc/5gpn/mihomo/5gpn/certificate-request
state_file=/etc/5gpn/intercept/cert-state
certificate_lock=/run/5gpn/cert-renew.lock
installed=false
install_attempted=false
candidate_digest=''
restore_master=false
master_before=false
http2_before=true
oom_status_file="$(mktemp /tmp/5gpn-docker-oom-status.XXXXXX)"
intercept_ca_file="$(mktemp /tmp/5gpn-docker-intercept-ca.XXXXXX)"
oom_request_pid=''
chmod 0600 "$oom_status_file" "$intercept_ca_file"

wait_for_certificate_manager_idle() {
    local rc stable=0 checks=0 deadline=$((SECONDS + 33 * 60))
    while (( SECONDS < deadline )); do
        set +e
        docker exec "$FIVEGPN_PROBE_CONTAINER" /bin/bash -euo pipefail -c '
          lock="$1"
          if [[ ! -e "$lock" && ! -L "$lock" ]]; then
            exit 2
          fi
          [[ -f "$lock" && ! -L "$lock" ]] || exit 3
          [[ "$(stat -Lc "%u:%g:%a:%h" -- "$lock")" == "10001:10001:600:1" ]] || exit 3
          exec 9<"$lock"
          flock -n 9
        ' _ "$certificate_lock" >/dev/null 2>&1
        rc=$?
        set -e
        case "$rc" in
            0)
                stable=$((stable + 1))
                if (( stable >= 8 )); then
                    assert_probe_candidate_runtime_clean \
                        || probe_die 'candidate restarted while the certificate manager was settling'
                    return 0
                fi
                ;;
            1|2) stable=0 ;;
            3) probe_die 'container certificate lock metadata is unsafe' ;;
            *) probe_die "could not inspect the container certificate lock (status $rc)" ;;
        esac
        checks=$((checks + 1))
        if (( checks % 40 == 0 )); then
            assert_probe_candidate_runtime_clean \
                || probe_die 'candidate stopped or restarted while the certificate manager was settling'
        fi
        sleep 0.25
    done
    probe_die 'container certificate manager did not become stably idle after startup'
}

current_revision() {
    api_request GET /5gpn/interception | jq -er .revision
}

cleanup_owned_fixture() {
    local current detail revision
    set +e
    if [[ "$install_attempted" == true && -n "$candidate_digest" ]]; then
        current="$(api_request GET /5gpn/interception 2>/dev/null)"
        revision="$(jq -r '.revision // empty' <<<"$current" 2>/dev/null)"
        detail="$(api_request GET "/5gpn/interception/extensions/${extension_id}" 2>/dev/null)"
        if [[ -n "$revision" \
           && "$(jq -r '.extension.snapshot_digest // empty' <<<"$detail" 2>/dev/null)" == "$candidate_digest" ]]; then
            if api_request DELETE "/5gpn/interception/extensions/${extension_id}" \
                "$(jq -nc --arg revision "$revision" '{revision:$revision}')" >/dev/null 2>&1; then
                installed=false
                install_attempted=false
            else
                echo "WARNING: failed to remove owned acceptance extension $extension_id" >&2
            fi
        fi
    fi
    if [[ "$restore_master" == true ]]; then
        current="$(api_request GET /5gpn/interception 2>/dev/null)"
        revision="$(jq -r '.revision // empty' <<<"$current" 2>/dev/null)"
        if [[ -n "$revision" \
           && "$(jq -r '.snapshot.modules | length' <<<"$current" 2>/dev/null)" == 0 ]]; then
            api_request PUT /5gpn/interception/settings \
                "$(jq -nc --arg revision "$revision" \
                    --argjson enabled "$master_before" --argjson http2 "$http2_before" \
                    '{revision:$revision,enabled:$enabled,http2:$http2,http3:false}')" \
                >/dev/null 2>&1
            restore_master=false
        fi
    fi
    if [[ "$oom_request_pid" =~ ^[1-9][0-9]*$ ]]; then
        kill "$oom_request_pid" >/dev/null 2>&1 || true
        wait "$oom_request_pid" >/dev/null 2>&1 || true
    fi
    rm -f -- "$oom_status_file" "$intercept_ca_file"
}
trap cleanup_owned_fixture EXIT
trap 'exit 130' HUP INT TERM

# Startup deliberately serializes the interception and public-certificate
# helpers. Do not consume the extension convergence budget while a valid
# initial public renewal still owns their shared lock.
wait_for_certificate_manager_idle

manifest="$(cat <<EOF
apiVersion: 5gpn.io/v1
kind: Extension
metadata:
  id: ${extension_id}
  name: Docker acceptance fixture
  version: 1.0.0
  description: Ephemeral versioned fixture for the real test-env Docker gate.
permissions:
  persistentStorage: false
  network: false
traffic:
  captureHosts:
    - ${capture_host}
actions:
  - id: memory-bomb
    phase: request
    match:
      hosts: [${capture_host}]
      pathRegex: "^/oom$"
    script:
      inline: |
        async function transform() {
          await new Promise((resolve) => setTimeout(resolve, 1500));
          const blocks = [];
          while (true) blocks.push(new Uint8Array(16 * 1024 * 1024).fill(165));
        }
      bodyMode: none
      timeoutMs: 30000
      maxBodyBytes: 1024
  - id: healthy
    phase: request
    match:
      hosts: [${capture_host}]
      pathRegex: "^/healthy$"
    script:
      inline: "function transform() { return {response: {status: 204, headers: {'X-5gpn-Acceptance': 'worker'}}}; }"
      bodyMode: none
      timeoutMs: 3000
      maxBodyBytes: 1024
EOF
)"

initial="$(api_request GET /5gpn/interception)"
master_before="$(jq -r '.snapshot.enabled' <<<"$initial")"
http2_before="$(jq -r '.snapshot.http2' <<<"$initial")"
[[ "$master_before" == true || "$master_before" == false ]] \
    || probe_die 'interception master state is not boolean'
[[ "$http2_before" == true || "$http2_before" == false ]] \
    || probe_die 'interception HTTP/2 state is not boolean'
[[ "$(jq -er '.snapshot.modules | length' <<<"$initial")" == 0 ]] \
    || probe_die 'extension/OOM acceptance requires an empty installed-extension set'

request_before="$(docker exec "$FIVEGPN_PROBE_CONTAINER" cat "$request_file")"
digest_before="$(jq -er 'select(.version == 1 and
    (.target_digest | test("^[0-9a-f]{64}$"))) | .target_digest' \
    <<<"$request_before")"
intercept_serial_before="$(docker exec "$FIVEGPN_PROBE_CONTAINER" /bin/bash -c '
  if [[ -f /etc/5gpn/intercept/tls/leaf.crt ]]; then
    openssl x509 -in /etc/5gpn/intercept/tls/leaf.crt -noout -serial 2>/dev/null |
      sed -n "s/^serial=//p"
  fi
' || true)"
pid_before="$(container_pid)"
container_id_before="$(docker inspect --format '{{.Id}}' "$FIVEGPN_PROBE_CONTAINER")"

review="$(api_request POST /5gpn/interception/review \
    "$(jq -nc --arg content "$manifest" '{content:$content}')")"
review_revision="$(jq -er '.revision | select(test("^[0-9a-f]{32}$"))' <<<"$review")"
candidate_digest="$(jq -er \
    --arg host "$capture_host" \
    '.candidate.digest as $digest |
     select($digest | test("^[0-9a-f]{64}$")) |
     select((.candidate.installed // "") == "") |
     select(.candidate.detail.review_contract == 8) |
     select(.candidate.detail.capture_hosts == [$host]) |
     select((.candidate.detail.actions | map(.id)) == ["memory-bomb","healthy"]) |
     select(all(.candidate.detail.actions[];
       .kind == "script" and .source_kind == "inline" and
       (.code_digest | test("^[0-9a-f]{64}$")) and .code_bytes > 0 and
       (.review_digest | test("^[0-9a-f]{64}$")) and
       (has("script") | not) and (has("source") | not))) |
     $digest' <<<"$review")"

install_attempted=true
install="$(api_request POST /5gpn/interception/extensions \
    "$(jq -nc --arg revision "$review_revision" --arg digest "$candidate_digest" \
        --arg content "$manifest" \
        '{revision:$revision,review_contract:8,digest:$digest,content:$content}')")"
installed=true
jq -e --arg id "$extension_id" --arg digest "$candidate_digest" '
  (.snapshot.modules[] | select(.id == $id) | .enabled) == false and
  .revision != "" and $digest != ""
' <<<"$install" >/dev/null \
    || probe_die 'reviewed extension did not install disabled'
[[ "$(docker exec "$FIVEGPN_PROBE_CONTAINER" jq -r .target_digest "$request_file")" == "$digest_before" ]] \
    || probe_die 'installing a disabled extension changed the certificate target'

if [[ "$master_before" != true ]]; then
    restore_master=true
    enabled_master="$(api_request PUT /5gpn/interception/settings \
        "$(jq -nc --arg revision "$(current_revision)" --argjson http2 "$http2_before" \
            '{revision:$revision,enabled:true,http2:$http2,http3:false}')")"
    jq -e --argjson http2 "$http2_before" \
        '.snapshot.enabled == true and .snapshot.http2 == $http2' \
        <<<"$enabled_master" >/dev/null \
        || probe_die 'could not enable the interception master for the owned fixture'
fi

enable="$(api_request PUT "/5gpn/interception/extensions/${extension_id}/enabled" \
    "$(jq -nc --arg revision "$(current_revision)" \
        '{revision:$revision,review_contract:8,enabled:true}')")"
enabled_revision="$(jq -er .revision <<<"$enable")"
jq -e --arg id "$extension_id" '
  (.snapshot.modules[] | select(.id == $id) | .enabled) == true and
  ((.snapshot.certificate.status == "pending" and
    (.snapshot.modules[] | select(.id == $id) | .runtime.phase) == "certificate_pending") or
   (.snapshot.certificate.status == "ready" and
    (.snapshot.modules[] | select(.id == $id) | .runtime.phase) == "active"))
' <<<"$enable" >/dev/null \
    || probe_die 'extension enable returned an inconsistent certificate phase'

request_after="$(docker exec "$FIVEGPN_PROBE_CONTAINER" cat "$request_file")"
jq -e --arg host "$capture_host" --arg before "$digest_before" '
  .version == 1 and
  (.target_digest | test("^[0-9a-f]{64}$")) and .target_digest != $before and
  (.attempt | test("^[0-9a-f]{32}$")) and .hosts == [$host]
' <<<"$request_after" >/dev/null \
    || probe_die 'enabled extension did not publish its fenced certificate request'

ready=''
for _ in $(seq 1 240); do
    current="$(api_request GET /5gpn/interception)"
    if jq -e --arg id "$extension_id" --arg host "$capture_host" \
        --arg revision "$enabled_revision" '
      .revision == $revision and .snapshot.certificate.status == "ready" and
      (.snapshot.modules[] | select(.id == $id) | .runtime.ready) == true and
      (.snapshot.modules[] | select(.id == $id) | .runtime.phase) == "active" and
      .snapshot.active_capture_hosts == [$host]
    ' <<<"$current" >/dev/null; then
        ready="$current"
        break
    fi
    sleep 0.25
done
[[ -n "$ready" ]] \
    || probe_die 'container certificate manager did not hot-publish the interception leaf'
[[ "$(container_pid)" == "$pid_before" ]] \
    || probe_die 'interception certificate publication restarted PID 1'

certificate_state="$(docker exec "$FIVEGPN_PROBE_CONTAINER" cat "$state_file")"
request_target="$(jq -er .target_digest <<<"$request_after")"
request_attempt="$(jq -er .attempt <<<"$request_after")"
certificate_hash="$(docker exec "$FIVEGPN_PROBE_CONTAINER" sha256sum \
    /etc/5gpn/intercept/tls/fullchain.pem | awk '{print $1}')"
private_key_hash="$(docker exec "$FIVEGPN_PROBE_CONTAINER" sha256sum \
    /etc/5gpn/intercept/tls/privkey.pem | awk '{print $1}')"
jq -e --arg target "$request_target" --arg attempt "$request_attempt" \
    --arg certificate "$certificate_hash" --arg key "$private_key_hash" '
  .version == 1 and .status == "ready" and .target_digest == $target and
  .attempt == $attempt and .certificate_sha256 == $certificate and
  .private_key_sha256 == $key
' <<<"$certificate_state" >/dev/null \
    || probe_die 'interception certificate result is not fenced to the published bytes'
docker exec "$FIVEGPN_PROBE_CONTAINER" openssl x509 \
    -in /etc/5gpn/intercept/tls/leaf.crt -noout -checkhost "$capture_host" \
    2>/dev/null | grep -Fq 'does match certificate' \
    || probe_die 'published interception leaf does not cover the owned fixture host'
docker exec "$FIVEGPN_PROBE_CONTAINER" openssl verify -purpose sslserver \
    -CAfile /etc/5gpn/intercept-ca/root.crt /etc/5gpn/intercept/tls/leaf.crt \
    >/dev/null \
    || probe_die 'published interception leaf is not signed by the persistent CA'
san_entries="$(docker exec "$FIVEGPN_PROBE_CONTAINER" openssl x509 \
    -in /etc/5gpn/intercept/tls/leaf.crt -noout -ext subjectAltName \
    | tail -n +2 | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d')"
[[ "$san_entries" == "DNS:${capture_host}" ]] \
    || probe_die "interception leaf SAN set is not exactly the owned fixture host: $san_entries"
docker exec "$FIVEGPN_PROBE_CONTAINER" cat /etc/5gpn/intercept-ca/root.crt \
    > "$intercept_ca_file"
openssl x509 -in "$intercept_ca_file" -noout >/dev/null 2>&1 \
    || probe_die 'persistent interception CA could not be exported for the client proof'
disk_serial="$(docker exec "$FIVEGPN_PROBE_CONTAINER" openssl x509 \
    -in /etc/5gpn/intercept/tls/leaf.crt -noout -serial | sed -n 's/^serial=//p')"
served_serial="$(served_interception_serial "$capture_host")"
[[ "${disk_serial^^}" == "$served_serial" ]] \
    || probe_die 'data-plane TLS did not hot-load the committed interception leaf'
[[ -z "$intercept_serial_before" || "${intercept_serial_before^^}" != "$served_serial" ]] \
    || probe_die 'interception certificate request did not rotate the previously published leaf'

healthy_status="$(data_plane_status "$capture_host" /healthy "$intercept_ca_file")"
[[ "$healthy_status" == 204 ]] \
    || probe_die "owned healthy extension action returned HTTP $healthy_status instead of 204"
healthy_logs="$(api_request GET "/5gpn/interception/logs?extension=${extension_id}&limit=1000")"
jq -e --arg id "$extension_id" '
  any(.logs[]?; .extension == $id and .action == "healthy" and
      .level == "info" and .message == "action completed")
' <<<"$healthy_logs" >/dev/null \
    || probe_die 'healthy response was not backed by a completed worker action log'

aggregate="$(aggregate_path)"
oom_before="$(aggregate_oom_kill_count "$aggregate")"
[[ "$oom_before" =~ ^[0-9]+$ ]] || probe_die 'worker aggregate has no OOM counter'
[[ -z "$(docker exec "$FIVEGPN_PROBE_CONTAINER" find "$aggregate" \
    -mindepth 1 -maxdepth 1 -type d -name 'action.*' -print -quit)" ]] \
    || probe_die 'a worker action leaf existed before the OOM fixture'

set +e
data_plane_status "$capture_host" /oom "$intercept_ca_file" >"$oom_status_file" 2>/dev/null &
oom_request_pid=$!
set -e
leaf_limits=''
for _ in $(seq 1 100); do
    leaf_limits="$(docker exec "$FIVEGPN_PROBE_CONTAINER" /bin/bash -euo pipefail -c '
      aggregate="$1"
      shopt -s nullglob
      leaves=("$aggregate"/action.*)
      [[ ${#leaves[@]} == 1 && -d "${leaves[0]}" ]] || exit 1
      printf "%s:%s:%s:%s\n" \
        "$(cat "${leaves[0]}/memory.max")" \
        "$(cat "${leaves[0]}/memory.swap.max")" \
        "$(cat "${leaves[0]}/memory.oom.group")" \
        "$(cat "${leaves[0]}/pids.max")"
    ' _ "$aggregate" 2>/dev/null || true)"
    [[ -z "$leaf_limits" ]] || break
    sleep 0.05
done
[[ "$leaf_limits" == '536870912:0:1:32' ]] \
    || probe_die "live worker leaf limits were not 512MiB/no-swap/OOM-group/32-pids: ${leaf_limits:-missing}"
set +e
wait "$oom_request_pid"
set -e
oom_request_pid=''
oom_http="$(cat "$oom_status_file" 2>/dev/null || true)"
[[ "$oom_http" == 502 ]] \
    || probe_die "worker OOM returned HTTP ${oom_http:-none} instead of the isolated-operation 502"

oom_after="$oom_before"
for _ in $(seq 1 120); do
    oom_after="$(aggregate_oom_kill_count "$aggregate" 2>/dev/null || true)"
    if [[ "$oom_after" =~ ^[0-9]+$ && "$oom_after" -gt "$oom_before" ]]; then
        break
    fi
    sleep 0.1
done
[[ "$oom_after" =~ ^[0-9]+$ && "$oom_after" -gt "$oom_before" ]] \
    || probe_die "owned worker did not increment hierarchical oom_kill (HTTP ${oom_http:-none})"

classified=false
for _ in $(seq 1 100); do
    oom_logs="$(api_request GET "/5gpn/interception/logs?extension=${extension_id}&limit=1000")"
    if jq -e --arg id "$extension_id" '
      any(.logs[]?; .extension == $id and .action == "memory-bomb" and
          .level == "error" and (.message | contains("exceeded its memory limit")))
    ' <<<"$oom_logs" >/dev/null; then
        classified=true
        break
    fi
    sleep 0.1
done
[[ "$classified" == true ]] \
    || probe_die 'runtime did not classify the cgroup kill as a worker memory-limit failure'
[[ "$(container_pid)" == "$pid_before" \
   && "$(docker inspect --format '{{.Id}}' "$FIVEGPN_PROBE_CONTAINER")" == "$container_id_before" ]] \
    || probe_die 'worker OOM restarted or replaced the monolith container'
wait_for_authenticated_capabilities

for _ in $(seq 1 100); do
    leaf_left="$(docker exec "$FIVEGPN_PROBE_CONTAINER" find "$aggregate" \
        -mindepth 1 -maxdepth 1 -type d -name 'action.*' -print -quit 2>/dev/null || true)"
    [[ -n "$leaf_left" ]] || break
    sleep 0.1
done
[[ -z "$leaf_left" ]] || probe_die "OOM worker leaf remains: $leaf_left"
[[ "$(data_plane_status "$capture_host" /healthy "$intercept_ca_file")" == 204 ]] \
    || probe_die 'a fresh isolated worker did not execute after the OOM'

detail="$(api_request GET "/5gpn/interception/extensions/${extension_id}")"
jq -e --arg digest "$candidate_digest" '
  .extension.snapshot_digest == $digest and .extension.review_contract == 8 and
  (.extension.actions | map(.id)) == ["memory-bomb","healthy"] and
  all(.extension.actions[]; (.review_digest | test("^[0-9a-f]{64}$")))
' <<<"$detail" >/dev/null \
    || probe_die 'owned extension review contract or digest changed before cleanup'
delete="$(api_request DELETE "/5gpn/interception/extensions/${extension_id}" \
    "$(jq -nc --arg revision "$(jq -er .revision <<<"$detail")" '{revision:$revision}')")"
jq -e --arg id "$extension_id" \
    '[.snapshot.modules[] | select(.id == $id)] | length == 0' <<<"$delete" >/dev/null \
    || probe_die 'owned extension was not removed'
installed=false
install_attempted=false

restored=false
for _ in $(seq 1 240); do
    current_request="$(docker exec "$FIVEGPN_PROBE_CONTAINER" cat "$request_file")"
    current_state="$(docker exec "$FIVEGPN_PROBE_CONTAINER" cat "$state_file" 2>/dev/null || true)"
    if [[ "$(jq -r '.target_digest // empty' <<<"$current_request")" == "$digest_before" ]] \
       && jq -e --arg target "$digest_before" --arg attempt "$(jq -r .attempt <<<"$current_request")" '
            .version == 1 and .status == "ready" and
            .target_digest == $target and .attempt == $attempt
          ' <<<"$current_state" >/dev/null 2>&1; then
        restored=true
        break
    fi
    sleep 0.25
done
[[ "$restored" == true ]] \
    || probe_die 'certificate manager did not converge after fixture removal'

if [[ "$restore_master" == true ]]; then
    before_restore="$(api_request GET /5gpn/interception)"
    [[ "$(jq -er '.snapshot.modules | length' <<<"$before_restore")" == 0 ]] \
        || probe_die 'interception document changed concurrently during cleanup'
    api_request PUT /5gpn/interception/settings \
        "$(jq -nc --arg revision "$(jq -er .revision <<<"$before_restore")" \
            --argjson enabled "$master_before" --argjson http2 "$http2_before" \
            '{revision:$revision,enabled:$enabled,http2:$http2,http3:false}')" >/dev/null
    restore_master=false
fi

stable_after_restore=false
for _ in $(seq 1 240); do
    current_request="$(docker exec "$FIVEGPN_PROBE_CONTAINER" cat "$request_file")"
    current_state="$(docker exec "$FIVEGPN_PROBE_CONTAINER" cat "$state_file" 2>/dev/null || true)"
    if jq -e --arg target "$(jq -r .target_digest <<<"$current_request")" \
        --arg attempt "$(jq -r .attempt <<<"$current_request")" '
          .version == 1 and .status == "ready" and
          .target_digest == $target and .attempt == $attempt
        ' <<<"$current_state" >/dev/null 2>&1; then
        stable_after_restore=true
        break
    fi
    sleep 0.25
done
[[ "$stable_after_restore" == true ]] \
    || probe_die 'certificate state did not settle after restoring interception settings'

rm -f -- "$oom_status_file" "$intercept_ca_file"
trap - EXIT
printf 'FIVEGPN_PROBE_EXTENSION_ID=%s\n' "$extension_id"
printf 'FIVEGPN_PROBE_INTERCEPT_CERT_SERIAL=%s\n' "$served_serial"
printf 'FIVEGPN_PROBE_WORKER_OOM_KILL=%s:%s\n' "$oom_before" "$oom_after"
printf 'FIVEGPN_PROBE_WORKER_PID1=%s\n' "$pid_before"
