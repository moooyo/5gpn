#!/usr/bin/env bash
# 5gpn-configure-runtime-gate-id: v1
#
# This helper owns both mihomo pre-start steps. Its privileged `wait` mode
# returns immediately on a normal start, or acknowledges a root-owned configure
# nonce and blocks the start half of one PID1 try-restart job. Its unprivileged
# `validate-ui` mode delegates to the strict current-generation validator. Both
# modes end cleanly when an operator stop terminates the start transaction.
set -eu

LOCK_ROOT=/run/5gpn
GATE_RECORD=${LOCK_ROOT}/configure-runtime-gate
GATE_ACK=${LOCK_ROOT}/configure-runtime-gate.ack
GATE_JOB=${LOCK_ROOT}/configure-runtime-gate.job
GATE_RELEASE=${LOCK_ROOT}/configure-runtime-gate.release
GATE_UNIT=5gpn-mihomo.service
GATE_MAX_WAIT_SECONDS=2100
UI_VALIDATOR=/opt/5gpn/scripts/ui-generation.sh

plain_root_file_is_safe() {
    local path="$1" mode="$2"
    [[ -f "$path" && ! -L "$path" \
       && "$(stat -Lc '%u:%g:%a:%h' -- "$path" 2>/dev/null)" == "0:0:${mode}:1" ]]
}

# A systemd stop job terminates a running ExecStartPre command. Exiting cleanly
# on that TERM lets the stop replace the pending restart without leaving the
# unit failed; PID 1 still owns and completes the stop transaction.
ACK_TMP=""

cleanup_ack_tmp() {
    local tmp_identity ack_identity
    [[ -n "$ACK_TMP" ]] || return 0
    if [[ ! -e "$ACK_TMP" && ! -L "$ACK_TMP" ]]; then
        ACK_TMP=""
        return 0
    fi
    [[ -f "$ACK_TMP" && ! -L "$ACK_TMP" \
       && "$(stat -Lc '%u:%g:%a' -- "$ACK_TMP" 2>/dev/null)" == 0:0:600 \
       && "$(stat -Lc '%h' -- "$ACK_TMP" 2>/dev/null)" =~ ^[12]$ ]] || return 1
    if [[ -e "$GATE_ACK" || -L "$GATE_ACK" ]]; then
        [[ -f "$GATE_ACK" && ! -L "$GATE_ACK" \
           && "$(stat -Lc '%u:%g:%a:%h' -- "$GATE_ACK" 2>/dev/null)" == 0:0:600:2 \
           && "$(stat -Lc '%h' -- "$ACK_TMP" 2>/dev/null)" == 2 ]] || return 1
        tmp_identity="$(stat -Lc '%d:%i' -- "$ACK_TMP" 2>/dev/null)" || return 1
        ack_identity="$(stat -Lc '%d:%i' -- "$GATE_ACK" 2>/dev/null)" || return 1
        [[ "$tmp_identity" == "$ack_identity" ]] || return 1
    else
        [[ "$(stat -Lc '%h' -- "$ACK_TMP" 2>/dev/null)" == 1 ]] || return 1
    fi
    rm -f -- "$ACK_TMP" || return 1
    sync -f "$LOCK_ROOT" 2>/dev/null || return 1
    ACK_TMP=""
}

systemd_stop_job_owns_unit() {
    local unit_path job job_id job_path job_type job_state active_state sub_state
    unit_path="$(busctl --system --json=short call org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetUnit \
        s "$GATE_UNIT" 2>/dev/null \
        | jq -er 'select(.type == "o") | .data | select(type == "array" and length == 1) | .[0]')" \
        || return 1
    [[ "$unit_path" == /org/freedesktop/systemd1/unit/* ]] || return 1
    job="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$unit_path" org.freedesktop.systemd1.Unit Job 2>/dev/null \
        | jq -cer 'select(.type == "(uo)") | .data | select(type == "array" and length == 2)')" \
        || return 1
    job_id="$(jq -er '.[0] | select(type == "number" and . > 0) | tostring' <<<"$job")" \
        || return 1
    job_path="$(jq -er '.[1] | select(type == "string")' <<<"$job")" || return 1
    [[ "$job_path" == "/org/freedesktop/systemd1/job/${job_id}" ]] || return 1
    job_type="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$job_path" org.freedesktop.systemd1.Job JobType 2>/dev/null \
        | jq -er 'select(.type == "s") | .data | select(type == "string")')" \
        || return 1
    job_state="$(busctl --system --json=short get-property org.freedesktop.systemd1 \
        "$job_path" org.freedesktop.systemd1.Job State 2>/dev/null \
        | jq -er 'select(.type == "s") | .data | select(type == "string")')" \
        || return 1
    active_state="$(systemctl show -p ActiveState --value "$GATE_UNIT" 2>/dev/null)" \
        || return 1
    sub_state="$(systemctl show -p SubState --value "$GATE_UNIT" 2>/dev/null)" \
        || return 1
    [[ "$job_type" == stop \
       && ( "$job_state" == waiting || "$job_state" == running ) \
       && "$active_state" == deactivating \
       && "$sub_state" == stop-* ]]
}

on_term() {
    cleanup_ack_tmp || true
    systemd_stop_job_owns_unit && exit 0
    exit 143
}

trap on_term TERM

die() {
    printf '5gpn configure runtime gate: %s\n' "$*" >&2
    exit 1
}

lock_root_is_safe() {
    local parent parent_target parent_device parent_root
    local lock_target lock_device lock_fsroot relative expected_root
    [[ -d "$LOCK_ROOT" && ! -L "$LOCK_ROOT" \
       && "$(readlink -f -- "$LOCK_ROOT" 2>/dev/null)" == "$LOCK_ROOT" \
       && "$(stat -Lc '%u:%g:%a' -- "$LOCK_ROOT" 2>/dev/null)" == 0:0:700 ]] \
        || return 1
    parent="$(dirname -- "$LOCK_ROOT")"
    read -r parent_target parent_device parent_root \
        < <(findmnt -rn -T "$parent" -o TARGET,MAJ:MIN,FSROOT 2>/dev/null) \
        || return 1
    read -r lock_target lock_device lock_fsroot \
        < <(findmnt -rn -T "$LOCK_ROOT" -o TARGET,MAJ:MIN,FSROOT 2>/dev/null) \
        || return 1
    [[ -n "$parent_target" && -n "$parent_device" && -n "$parent_root" \
       && -n "$lock_target" && -n "$lock_device" && -n "$lock_fsroot" ]] \
        || return 1
    [[ "$lock_target" == "$parent_target" ]] && return 0
    relative="${LOCK_ROOT#"${parent_target%/}/"}"
    [[ -n "$relative" && "$relative" != "$LOCK_ROOT" && "$relative" != */../* ]] \
        || return 1
    expected_root="${parent_root%/}/${relative}"
    [[ "$expected_root" == /* ]] || expected_root="/${expected_root}"
    [[ "$lock_target" == "$LOCK_ROOT" \
       && "$lock_device" == "$parent_device" \
       && "$lock_fsroot" == "$expected_root" ]]
}

gate_state_is_clear() {
    local path
    local -a paths=("$GATE_RECORD" "$GATE_JOB" "$GATE_ACK" "$GATE_RELEASE") temps=()
    shopt -s nullglob
    temps=("$LOCK_ROOT"/.configure-runtime-gate.*)
    shopt -u nullglob
    paths+=("${temps[@]}")
    for path in "${paths[@]}"; do
        [[ ! -e "$path" && ! -L "$path" ]] || return 1
    done
}

load_gate_record() {
    local path_state fd_state
    local -a lines=()
    plain_root_file_is_safe "$GATE_RECORD" 600 || return 1
    exec 3<"$GATE_RECORD" || return 1
    path_state="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$GATE_RECORD" 2>/dev/null)" \
        || { exec 3<&-; return 1; }
    fd_state="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- /proc/self/fd/3 2>/dev/null)" \
        || { exec 3<&-; return 1; }
    [[ "$path_state" == "$fd_state" ]] \
        || { exec 3<&-; return 1; }
    mapfile -t lines <&3 || { exec 3<&-; return 1; }
    [[ "${#lines[@]}" == 3 \
       && "${lines[0]}" == version=1 \
       && "${lines[1]}" == token=* \
       && "${lines[2]}" == "unit=${GATE_UNIT}" ]] \
        || { exec 3<&-; return 1; }
    GATE_TOKEN="${lines[1]#token=}"
    [[ "$GATE_TOKEN" =~ ^[0-9a-f]{64}$ ]] \
        || { exec 3<&-; return 1; }
    GATE_RECORD_STATE="$path_state"
}

gate_record_identity_is_current() {
    plain_root_file_is_safe "$GATE_RECORD" 600 \
        && [[ "$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$GATE_RECORD" 2>/dev/null)" \
              == "$GATE_RECORD_STATE" ]]
}

publish_ack() {
    local tmp invocation
    invocation="${INVOCATION_ID:-}"
    [[ "$invocation" =~ ^[0-9a-f]{32}$ ]] \
        || die "systemd did not provide a valid invocation ID"
    [[ ! -e "$GATE_ACK" && ! -L "$GATE_ACK" ]] \
        || die "an acknowledgement already exists"
    tmp="$(mktemp "${LOCK_ROOT}/.configure-runtime-gate.ack.XXXXXX")" \
        || die "could not stage the acknowledgement"
    ACK_TMP="$tmp"
    if ! printf 'version=1\ntoken=%s\npid=%s\ninvocation_id=%s\n' \
            "$GATE_TOKEN" "$$" "$invocation" > "$tmp" \
       || ! chmod 0600 "$tmp" \
       || ! sync -f "$tmp" 2>/dev/null \
       || ! ln -- "$tmp" "$GATE_ACK"; then
        rm -f -- "$tmp"
        die "could not publish the acknowledgement"
    fi
    rm -f -- "$tmp" || die "could not finalize the acknowledgement"
    ACK_TMP=""
    sync -f "$LOCK_ROOT" 2>/dev/null \
        || die "could not sync the acknowledgement directory entry"
    plain_root_file_is_safe "$GATE_ACK" 600 \
        || die "the acknowledgement metadata is unsafe"
}

release_matches_gate() {
    local path_state fd_state
    local -a lines=()
    [[ -e "$GATE_RELEASE" || -L "$GATE_RELEASE" ]] || return 1
    plain_root_file_is_safe "$GATE_RELEASE" 600 \
        || die "the release record metadata is unsafe"
    exec 4<"$GATE_RELEASE" || die "could not open the release record"
    path_state="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$GATE_RELEASE" 2>/dev/null)" \
        || { exec 4<&-; die "could not inspect the release record"; }
    fd_state="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- /proc/self/fd/4 2>/dev/null)" \
        || { exec 4<&-; die "could not bind the release record"; }
    [[ "$path_state" == "$fd_state" ]] \
        || { exec 4<&-; die "the release record changed during open"; }
    mapfile -t lines <&4 || { exec 4<&-; die "could not read the release record"; }
    exec 4<&-
    [[ "${#lines[@]}" == 2 \
       && "${lines[0]}" == version=1 \
       && "${lines[1]}" == "token=${GATE_TOKEN}" ]] \
        || die "the release record does not match the active gate"
}

wait_for_release() {
    local deadline
    deadline=$((SECONDS + GATE_MAX_WAIT_SECONDS))
    publish_ack
    while (( SECONDS < deadline )); do
        gate_record_identity_is_current \
            || die "the gate ownership record changed while start was blocked"
        if release_matches_gate; then
            exec 3<&-
            exit 0
        fi
        sleep 0.1
    done
    die "timed out waiting for configure to release the start job"
}

validate_current_ui() {
    [[ -f "$UI_VALIDATOR" && ! -L "$UI_VALIDATOR" \
       && "$(stat -Lc '%u:%g:%a:%h' -- "$UI_VALIDATOR" 2>/dev/null)" == 0:0:755:1 ]] \
        || die "the installed UI validator is missing or unsafe"
    "$UI_VALIDATOR" validate-current
}

main() {
    [[ "$#" == 1 ]] || die "usage: configure-runtime-gate.sh wait|validate-ui|assert-clear"
    case "$1" in
        wait)
            if [[ ! -e "$LOCK_ROOT" && ! -L "$LOCK_ROOT" ]]; then
                exit 0
            fi
            lock_root_is_safe || die "the private runtime directory is unsafe"
            if [[ ! -e "$GATE_RECORD" && ! -L "$GATE_RECORD" ]]; then
                [[ ! -e "$GATE_ACK" && ! -L "$GATE_ACK" \
                   && ! -e "$GATE_JOB" && ! -L "$GATE_JOB" \
                   && ! -e "$GATE_RELEASE" && ! -L "$GATE_RELEASE" ]] \
                    || die "orphan gate state exists without an ownership record"
                exit 0
            fi
            load_gate_record || die "the gate ownership record is unsafe"
            wait_for_release
            ;;
        validate-ui)
            validate_current_ui
            ;;
        assert-clear)
            if [[ ! -e "$LOCK_ROOT" && ! -L "$LOCK_ROOT" ]]; then
                exit 0
            fi
            lock_root_is_safe || die "the private runtime directory is unsafe"
            gate_state_is_clear || die "retained configure runtime-gate state is present"
            ;;
        *)
            die "usage: configure-runtime-gate.sh wait|validate-ui|assert-clear"
            ;;
    esac
}

main "$@"
