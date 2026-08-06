#!/bin/bash
# Publish the dynamic interception leaf from the root-protected private CA.
set -euo pipefail
export LC_ALL=C

if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level info -- "$*"; else echo "[INFO] $*"; fi; }
ok() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level info -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level warn -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err() { if [[ "$_HAVE_GUM" == 1 ]]; then CI=1 gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

CA_DIR=/etc/5gpn/intercept-ca
INTERCEPT_DIR=/etc/5gpn/intercept
TLS_DIR=/etc/5gpn/intercept/tls
CERT_REQUEST=/etc/5gpn/mihomo/5gpn/certificate-request
CERT_STATE=/etc/5gpn/intercept/cert-state
CA_MARKER=.5gpn-intercept-ca-owned
CA_MARKER_VALUE=5gpn-intercept-ca-v1
LOCK_FILE=/run/5gpn/cert-renew.lock
RENEW_BEFORE=2592000
MAX_REQUEST_BYTES=262144
MAX_CONVERGENCE_ATTEMPTS=16
TEMP_MARKER=.5gpn-temp-owned
TEMP_MARKER_VALUE=5gpn-intercept-renew
CONFIG_ROOT_MARKER=.5gpn-owned
CONFIG_ROOT_MARKER_VALUE=5gpn-config

path_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
path_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
path_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
path_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }

group_gid() {
    local group="$1" entry gid
    if [[ "$CA_DIR" != /etc/5gpn/intercept-ca ]]; then
        id -g
        return
    fi
    entry="$(getent group "$group" 2>/dev/null)" || return 1
    gid="$(printf '%s\n' "$entry" | cut -d: -f3)"
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$gid"
}

canonical_directory() {
    local path="$1" canonical
    [[ -d "$path" && ! -L "$path" ]] || return 1
    canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ -n "$canonical" && "$canonical" == "$path" ]]
}

safe_plain_file() {
    local path="$1" gid="$2" mode="$3"
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$gid" \
       && "$(path_mode "$path")" == "$mode" \
       && "$(path_nlink "$path")" == 1 ]]
}

config_boundary_safe() {
    local config_root root_gid marker
    config_root="$(dirname -- "$CA_DIR")"
    [[ "$(dirname -- "$INTERCEPT_DIR")" == "$config_root" ]] || return 1
    root_gid="$(group_gid root)" || return 1
    canonical_directory "$config_root" \
        && [[ "$(path_uid "$config_root")" == "$EUID" \
           && "$(path_gid "$config_root")" == "$root_gid" \
           && "$(path_mode "$config_root")" == 755 ]] \
        || return 1
    marker="${config_root}/${CONFIG_ROOT_MARKER}"
    safe_plain_file "$marker" "$root_gid" 644 \
        && [[ "$(cat "$marker" 2>/dev/null || true)" == "$CONFIG_ROOT_MARKER_VALUE" ]]
}

ca_boundary_safe() {
    local root_gid marker entry name
    config_boundary_safe || return 1
    root_gid="$(group_gid root)" || return 1
    canonical_directory "$CA_DIR" \
        && [[ "$(path_uid "$CA_DIR")" == "$EUID" \
           && "$(path_gid "$CA_DIR")" == "$root_gid" \
           && "$(path_mode "$CA_DIR")" == 700 ]] \
        || return 1
    marker="${CA_DIR}/${CA_MARKER}"
    safe_plain_file "$marker" "$root_gid" 644 \
        && [[ "$(cat "$marker" 2>/dev/null || true)" == "$CA_MARKER_VALUE" ]] \
        || return 1
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CA_MARKER") ;;
            root.crt) safe_plain_file "$entry" "$root_gid" 644 || return 1 ;;
            root.key) safe_plain_file "$entry" "$root_gid" 600 || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$CA_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

tls_directory_safe() {
    local intercept_gid
    config_boundary_safe || return 1
    intercept_gid="$(group_gid fivegpn)" || return 1
    canonical_directory "$INTERCEPT_DIR" \
        && [[ "$(path_uid "$INTERCEPT_DIR")" == "$EUID" \
           && "$(path_gid "$INTERCEPT_DIR")" == "$intercept_gid" \
           && "$(path_mode "$INTERCEPT_DIR")" == 3770 ]] \
        || return 1
    canonical_directory "$TLS_DIR" \
        && [[ "$(path_uid "$TLS_DIR")" == "$EUID" \
           && "$(path_gid "$TLS_DIR")" == "$intercept_gid" \
           && "$(path_mode "$TLS_DIR")" == 750 ]]
}

tls_tree_safe() {
    local intercept_gid entry name
    tls_directory_safe || return 1
    intercept_gid="$(group_gid fivegpn)" || return 1
    while IFS= read -r -d '' entry; do
        name="$(basename -- "$entry")"
        case "$name" in
            leaf.crt|fullchain.pem|privkey.pem)
                safe_plain_file "$entry" "$intercept_gid" 640 || return 1 ;;
            *) return 1 ;;
        esac
    done < <(find "$TLS_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    if [[ -e "$CERT_STATE" || -L "$CERT_STATE" ]]; then
        safe_plain_file "$CERT_STATE" "$intercept_gid" 640 || return 1
    fi
}

lock_file_safe() {
    local lock="$1" root_gid
    root_gid="$(group_gid root)" || return 1
    safe_plain_file "$lock" "$root_gid" 600
}

lock_fd_targets_file() {
    local fd="$1" lock="$2" fd_identity file_identity process_id="${BASHPID:-$$}"
    [[ -e "/proc/${process_id}/fd/${fd}" ]] || return 1
    lock_file_safe "$lock" || return 1
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/${process_id}/fd/${fd}" 2>/dev/null || true)"
    file_identity="$(stat -Lc '%d:%i' -- "$lock" 2>/dev/null || true)"
    [[ -n "$fd_identity" && "$fd_identity" == "$file_identity" ]]
}

cleanup_stage() {
    local path="${stage:-}" canonical
    [[ -n "$path" && -d "$path" && ! -L "$path" ]] || return 0
    canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ "$canonical" == "$path" && "$canonical" == /var/tmp/5gpn-intercept-renew.* \
       && -f "$canonical/$TEMP_MARKER" && ! -L "$canonical/$TEMP_MARKER" \
       && "$(cat "$canonical/$TEMP_MARKER")" == "$TEMP_MARKER_VALUE" ]] || return 1
    rm -rf -- "$canonical"
}

interrupted_tls_candidate_is_safe() {
    local path="$1" intercept_gid="$2" root_gid mode gid
    root_gid="$(group_gid root)" || return 1
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_nlink "$path")" == 1 ]] || return 1
    gid="$(path_gid "$path")"
    mode="$(path_mode "$path")"
    [[ "$gid" == "$root_gid" || "$gid" == "$intercept_gid" ]] || return 1
    [[ "$mode" =~ ^[0-7]{3}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

cleanup_tls_candidates() {
    local intercept_gid path
    tls_directory_safe || return 1
    intercept_gid="$(group_gid fivegpn)" || return 1
    for path in \
        "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/.fullchain.pem.new" \
        "$TLS_DIR/.privkey.pem.new" "$(dirname -- "$CERT_STATE")/.cert-state.new"; do
        [[ ! -e "$path" && ! -L "$path" ]] && continue
        interrupted_tls_candidate_is_safe "$path" "$intercept_gid" || return 1
        rm -f -- "$path" || return 1
    done
}

cleanup_all() {
    local rc=0
    # Never scrub another publisher's candidates. EXIT runs before descriptors
    # close, so this is safe only after this process acquired fd 9's lock.
    if [[ "${CERT_LOCK_HELD:-0}" == 1 ]]; then
        cleanup_tls_candidates || rc=1
    fi
    cleanup_stage || rc=1
    return "$rc"
}

keypair_matches() {
    local cert="$1" key="$2" cert_pub key_pub
    cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

validate_root() {
    ca_boundary_safe || return 1
    openssl x509 -in "$CA_DIR/root.crt" -noout -checkend "$RENEW_BEFORE" >/dev/null 2>&1 || return 1
    openssl x509 -in "$CA_DIR/root.crt" -noout -text 2>/dev/null | grep -Fq 'CA:TRUE' || return 1
    keypair_matches "$CA_DIR/root.crt" "$CA_DIR/root.key"
}

# The request/result pair is a fenced, one-way protocol. The network-facing
# process may ask root to mint a bounded SAN set, but it never receives the CA
# key and the publisher never calls back into the process. The attempt token is
# changed for an explicit retry even when the host digest is unchanged. A result
# is authoritative only when both values still match the current request.

file_sha256() {
    local digest rest
    read -r digest rest < <(sha256sum -- "$1") || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

fsync_file() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    sync -f -- "$1"
}

fsync_directory() {
    canonical_directory "$1" || return 1
    sync -f -- "$1"
}

read_compact_line() {
    local path="$1" size
    [[ -f "$path" && ! -L "$path" ]] || return 1
    compact_line="$(<"$path")"
    [[ -n "$compact_line" && "$compact_line" != *$'\n'* && "$compact_line" != *$'\r'* ]] || return 1
    size="$(wc -c < "$path" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ && "$size" == "${#compact_line}" ]]
}

snapshot_certificate_request() {
    local destination="$1" fd path_identity fd_identity initial_size final_size copied_size
    local process_id="${BASHPID:-$$}"
    [[ -f "$CERT_REQUEST" && ! -L "$CERT_REQUEST" \
       && "$(path_nlink "$CERT_REQUEST")" == 1 \
       && "$(path_mode "$CERT_REQUEST")" == 644 \
       && "$(path_uid "$CERT_REQUEST")" == "$(path_uid "$(dirname -- "$CERT_REQUEST")")" ]] \
        || return 1
    exec {fd}<"$CERT_REQUEST" || return 1
    path_identity="$(stat -Lc '%d:%i' -- "$CERT_REQUEST" 2>/dev/null || true)"
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/${process_id}/fd/${fd}" 2>/dev/null || true)"
    initial_size="$(stat -Lc '%s' -- "/proc/${process_id}/fd/${fd}" 2>/dev/null || true)"
    if [[ -z "$path_identity" || "$path_identity" != "$fd_identity" \
       || ! "$initial_size" =~ ^[0-9]+$ || "$initial_size" -le 0 \
       || "$initial_size" -gt "$MAX_REQUEST_BYTES" \
       || ! -f "$CERT_REQUEST" || -L "$CERT_REQUEST" \
       || "$(path_nlink "$CERT_REQUEST")" != 1 ]]; then
        exec {fd}<&-
        return 1
    fi
    if ! head -c "$((MAX_REQUEST_BYTES + 1))" <&"$fd" > "$destination"; then
        exec {fd}<&-
        return 1
    fi
    final_size="$(stat -Lc '%s' -- "/proc/${process_id}/fd/${fd}" 2>/dev/null || true)"
    exec {fd}<&-
    [[ "$(stat -Lc '%d:%i' -- "$CERT_REQUEST" 2>/dev/null || true)" == "$path_identity" ]] \
        || return 1
    copied_size="$(wc -c < "$destination" | tr -d '[:space:]')"
    [[ "$final_size" == "$initial_size" && "$copied_size" == "$initial_size" ]]
}

load_desired_hosts() {
    local request_re payload remaining host previous="" count=0 computed
    snapshot_certificate_request "$stage/request" || return 1
    read_compact_line "$stage/request" || return 1
    request_re='^\{"version":1,"target_digest":"([0-9a-f]{64})","attempt":"([0-9a-f]{32})","hosts":\[(.*)\]\}$'
    [[ "$compact_line" =~ $request_re ]] || return 1
    desired_digest="${BASH_REMATCH[1]}"
    desired_attempt="${BASH_REMATCH[2]}"
    payload="${BASH_REMATCH[3]}"
    : > "$stage/hosts"
    if [[ -n "$payload" ]]; then
        [[ "${payload:0:1}" == '"' && "${payload: -1}" == '"' ]] || return 1
        remaining="${payload:1:${#payload}-2}"
        while :; do
            if [[ "$remaining" == *'","'* ]]; then
                host="${remaining%%'","'*}"
                remaining="${remaining#*'","'}"
            else
                host="$remaining"
                remaining=""
            fi
            [[ "${#host}" -le 255 \
               && "$host" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
                || return 1
            [[ -z "$previous" || "$host" > "$previous" ]] || return 1
            printf '%s\n' "$host" >> "$stage/hosts"
            previous="$host"
            ((count += 1))
            (( count <= 512 )) || return 1
            [[ -n "$remaining" ]] || break
        done
    fi
    if [[ -s "$stage/hosts" ]]; then
        computed="$(file_sha256 "$stage/hosts")" || return 1
    else
        computed="$(printf '\n' | sha256sum | cut -d' ' -f1)" || return 1
    fi
    [[ "$computed" == "$desired_digest" ]]
}

request_is_current() {
    snapshot_certificate_request "$stage/request-current" || return 1
    cmp -s -- "$stage/request" "$stage/request-current"
}

render_ready_state() {
    local destination="$1" certificate_hash="${2:-}" private_key_hash="${3:-}"
    if [[ -s "$stage/hosts" ]]; then
        [[ "$certificate_hash" =~ ^[0-9a-f]{64}$ \
           && "$private_key_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf '{"version":1,"target_digest":"%s","attempt":"%s","status":"ready","certificate_sha256":"%s","private_key_sha256":"%s"}' \
            "$desired_digest" "$desired_attempt" "$certificate_hash" "$private_key_hash" > "$destination"
    else
        printf '{"version":1,"target_digest":"%s","attempt":"%s","status":"ready"}' \
            "$desired_digest" "$desired_attempt" > "$destination"
    fi
}

render_error_state() {
    local destination="$1" code="$2" message="$3"
    [[ "$code" =~ ^[a-z][a-z0-9_]{0,63}$ \
       && "$message" =~ ^[A-Za-z0-9.,\ -]{1,160}$ \
       && "$message" != *$'\n'* && "$message" != *$'\r'* ]] || return 1
    printf '{"version":1,"target_digest":"%s","attempt":"%s","status":"error","code":"%s","message":"%s"}' \
        "$desired_digest" "$desired_attempt" "$code" "$message" > "$destination"
}

load_committed_ready_state() {
    local gid ready_re empty_re
    gid="$(group_gid fivegpn)" || return 1
    safe_plain_file "$CERT_STATE" "$gid" 640 || return 1
    read_compact_line "$CERT_STATE" || return 1
    ready_re='^\{"version":1,"target_digest":"([0-9a-f]{64})","attempt":"([0-9a-f]{32})","status":"ready","certificate_sha256":"([0-9a-f]{64})","private_key_sha256":"([0-9a-f]{64})"\}$'
    empty_re='^\{"version":1,"target_digest":"([0-9a-f]{64})","attempt":"([0-9a-f]{32})","status":"ready"\}$'
    committed_certificate_hash=""
    committed_private_key_hash=""
    if [[ "$compact_line" =~ $ready_re ]]; then
        [[ -s "$stage/hosts" ]] || return 1
        committed_digest="${BASH_REMATCH[1]}"
        committed_attempt="${BASH_REMATCH[2]}"
        committed_certificate_hash="${BASH_REMATCH[3]}"
        committed_private_key_hash="${BASH_REMATCH[4]}"
    elif [[ "$compact_line" =~ $empty_re ]]; then
        [[ ! -s "$stage/hosts" ]] || return 1
        committed_digest="${BASH_REMATCH[1]}"
        committed_attempt="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    [[ "$committed_digest" == "$desired_digest" \
       && "$committed_attempt" == "$desired_attempt" ]]
}

certificate_der_sha256() {
    local digest rest
    read -r digest rest < <(openssl x509 -in "$1" -outform DER 2>/dev/null | sha256sum) || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

certificate_hosts_are_exact() {
    local certificate="$1" sans entry host count=0 unique_count
    sans="$(openssl x509 -in "$certificate" -noout -ext subjectAltName 2>/dev/null)" \
        || return 1
    : > "$stage/material-hosts"
    while IFS= read -r entry; do
        entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -n "$entry" ]] || continue
        [[ "$entry" == DNS:* ]] || return 1
        host="${entry#DNS:}"
        [[ "${#host}" -le 255 \
           && "$host" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
            || return 1
        printf '%s\n' "$host" >> "$stage/material-hosts"
        ((count += 1))
    done < <(printf '%s\n' "$sans" | tail -n +2 | tr ',' '\n')
    (( count > 0 )) || return 1
    sort -u -- "$stage/material-hosts" > "$stage/material-hosts-sorted" || return 1
    unique_count="$(wc -l < "$stage/material-hosts-sorted" | tr -d '[:space:]')"
    [[ "$unique_count" == "$count" ]] || return 1
    cmp -s -- "$stage/hosts" "$stage/material-hosts-sorted"
}

validate_material() {
    local leaf="$1" fullchain="$2" key="$3" check_seconds="${4:-$RENEW_BEFORE}"
    local leaf_digest chain_leaf_digest host probe
    [[ -f "$leaf" && ! -L "$leaf" && -f "$fullchain" && ! -L "$fullchain" \
       && -f "$key" && ! -L "$key" ]] || return 1
    openssl x509 -in "$leaf" -noout -checkend "$check_seconds" >/dev/null 2>&1 || return 1
    openssl verify -CAfile "$CA_DIR/root.crt" "$leaf" >/dev/null 2>&1 || return 1
    keypair_matches "$leaf" "$key" || return 1
    leaf_digest="$(certificate_der_sha256 "$leaf")" || return 1
    chain_leaf_digest="$(certificate_der_sha256 "$fullchain")" || return 1
    [[ "$leaf_digest" == "$chain_leaf_digest" ]] || return 1
    while IFS= read -r host; do
        probe="$host"
        [[ "$probe" != \*.* ]] || probe="probe.${probe#*.}"
        openssl x509 -in "$leaf" -noout -checkhost "$probe" 2>/dev/null \
            | grep -Fq 'does match certificate' || return 1
    done < "$stage/hosts"
    certificate_hosts_are_exact "$leaf" || return 1
    material_certificate_hash="$(file_sha256 "$fullchain")" || return 1
    material_private_key_hash="$(file_sha256 "$key")" || return 1
}

validate_live_material() {
    local check_seconds="${1:-$RENEW_BEFORE}"
    tls_tree_safe || return 1
    validate_root || return 1
    validate_material "$TLS_DIR/leaf.crt" "$TLS_DIR/fullchain.pem" \
        "$TLS_DIR/privkey.pem" "$check_seconds"
}

validate_committed_ready() {
    local check_seconds="${1:-$RENEW_BEFORE}"
    load_committed_ready_state || return 1
    [[ -s "$stage/hosts" ]] || return 0
    validate_live_material "$check_seconds" || return 1
    [[ "$committed_certificate_hash" == "$material_certificate_hash" \
       && "$committed_private_key_hash" == "$material_private_key_hash" ]]
}

publish_state_file() {
    local source="$1" group="$2" gid="$3"
    local state_dir candidate
    state_dir="$(dirname -- "$CERT_STATE")"
    [[ "$state_dir" == "$INTERCEPT_DIR" ]] || return 1
    tls_directory_safe || return 1
    candidate="$state_dir/.cert-state.new"
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || return 1
    install -o root -g "$group" -m 0640 "$source" "$candidate" || return 1
    safe_plain_file "$candidate" "$gid" 640 || return 1
    fsync_file "$candidate" || return 1
    if ! request_is_current; then
        rm -f -- "$candidate"
        return 3
    fi
    mv -Tf -- "$candidate" "$CERT_STATE" || return 1
    fsync_directory "$state_dir" || return 1
    request_is_current || return 3
}

publish_error_if_current() {
    local code="$1" message="$2" group="$3" gid="$4" rc=0
    render_error_state "$stage/error-state" "$code" "$message" || return 1
    publish_state_file "$stage/error-state" "$group" "$gid" || rc=$?
    return "$rc"
}

generate_candidate() {
    local first_host san="" host serial
    first_host="$(head -n 1 "$stage/hosts")"
    [[ -n "$first_host" ]] || return 1
    while IFS= read -r host; do
        san="${san}${san:+,}DNS:${host}"
    done < "$stage/hosts"
    rm -f -- "$stage/privkey.pem" "$stage/leaf.csr" "$stage/leaf.ext" \
        "$stage/leaf.crt" "$stage/fullchain.pem"
    openssl ecparam -name prime256v1 -genkey -noout -out "$stage/privkey.pem" || return 1
    openssl req -new -sha256 -key "$stage/privkey.pem" \
        -subj "/CN=${first_host}" -out "$stage/leaf.csr" || return 1
    printf '%s\n' \
        'basicConstraints=critical,CA:FALSE' \
        'keyUsage=critical,digitalSignature' \
        'extendedKeyUsage=serverAuth' \
        "subjectAltName=${san}" > "$stage/leaf.ext"
    serial="0x$(openssl rand -hex 16)" || return 1
    openssl x509 -req -sha256 -days 397 -set_serial "$serial" \
        -in "$stage/leaf.csr" -CA "$CA_DIR/root.crt" -CAkey "$CA_DIR/root.key" \
        -extfile "$stage/leaf.ext" -out "$stage/leaf.crt" >/dev/null 2>&1 || return 1
    cat "$stage/leaf.crt" "$CA_DIR/root.crt" > "$stage/fullchain.pem" || return 1
    validate_material "$stage/leaf.crt" "$stage/fullchain.pem" \
        "$stage/privkey.pem" "$RENEW_BEFORE"
}

publish_certificate_candidate() {
    local group="$1" gid="$2" candidate rc=0
    render_ready_state "$stage/ready-state" "$material_certificate_hash" \
        "$material_private_key_hash" || return 1
    request_is_current || return 3
    cleanup_tls_candidates || return 1
    install -o root -g "$group" -m 0640 "$stage/leaf.crt" "$TLS_DIR/.leaf.crt.new" \
        && install -o root -g "$group" -m 0640 "$stage/fullchain.pem" "$TLS_DIR/.fullchain.pem.new" \
        && install -o root -g "$group" -m 0640 "$stage/privkey.pem" "$TLS_DIR/.privkey.pem.new" \
        || return 1
    for candidate in "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/.fullchain.pem.new" \
        "$TLS_DIR/.privkey.pem.new"; do
        safe_plain_file "$candidate" "$gid" 640 && fsync_file "$candidate" || return 1
    done
    if ! request_is_current; then
        cleanup_tls_candidates || return 1
        return 3
    fi
    mv -f -- "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/leaf.crt" \
        && mv -f -- "$TLS_DIR/.fullchain.pem.new" "$TLS_DIR/fullchain.pem" \
        && mv -f -- "$TLS_DIR/.privkey.pem.new" "$TLS_DIR/privkey.pem" \
        && fsync_directory "$TLS_DIR" || return 1
    request_is_current || return 3
    publish_state_file "$stage/ready-state" "$group" "$gid" || rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    validate_committed_ready 60 || return 1
    request_is_current || return 3
}

converge_current_request() {
    local group="$1" gid="$2" rc=0
    load_desired_hosts \
        || { err "The interception certificate request is invalid."; return 1; }
    if validate_committed_ready "$RENEW_BEFORE"; then
        return 0
    fi
    if [[ ! -s "$stage/hosts" ]]; then
        render_ready_state "$stage/ready-state" || return 1
        publish_state_file "$stage/ready-state" "$group" "$gid" || return $?
        return 0
    fi
    if ! tls_tree_safe; then
        err "The interception TLS directory is unsafe."
        return 1
    fi
    if ! validate_root; then
        publish_error_if_current ca_invalid \
            "The interception certificate authority is invalid." "$group" "$gid" || rc=$?
        [[ "$rc" == 3 ]] && return 3
        err "The shared interception root is invalid."
        return 1
    fi
    # A retry changes only the attempt. Reuse an already fresh exact leaf when
    # possible, and commit a new fenced result without burning the CA.
    if validate_live_material "$RENEW_BEFORE"; then
        render_ready_state "$stage/ready-state" "$material_certificate_hash" \
            "$material_private_key_hash" || return 1
        publish_state_file "$stage/ready-state" "$group" "$gid" || return $?
        return 0
    fi
    if ! generate_candidate; then
        publish_error_if_current signing_failed \
            "The interception certificate could not be generated." "$group" "$gid" || rc=$?
        [[ "$rc" == 3 ]] && return 3
        err "Could not generate a valid interception certificate."
        return 1
    fi
    publish_certificate_candidate "$group" "$gid" || rc=$?
    case "$rc" in
        0) return 0 ;;
        3) return 3 ;;
    esac
    publish_error_if_current publication_failed \
        "The interception certificate could not be published." "$group" "$gid" || rc=$?
    [[ "$rc" == 3 ]] && return 3
    err "Could not publish the interception certificate transaction."
    return 1
}

readonly_leaf_ready() {
    if [[ ! -e "$CERT_REQUEST" && ! -L "$CERT_REQUEST" ]]; then
        return 3
    fi
    load_desired_hosts || return 1
    validate_committed_ready 60 || return 1
    request_is_current || return 1
    [[ -s "$stage/hosts" ]] || return 0
    if validate_committed_ready "$RENEW_BEFORE"; then
        request_is_current || return 1
        return 0
    fi
    request_is_current || return 1
    return 4
}

main() {
    local root_gid readonly_rc=0 group group_gid_value attempt rc=0
    CERT_LOCK_HELD=0
    # The helper has no command surface. The request file is its only input.
    [[ $# == 0 ]] || { err "This helper takes no arguments."; return 2; }
    [[ "$EUID" == 0 ]] || { err "Interception certificate renewal must run as root."; return 1; }
    for command in openssl flock sha256sum sync cmp sort head; do
        command -v "$command" >/dev/null 2>&1 \
            || { err "Required certificate publication tools are unavailable."; return 1; }
    done
    stage="$(mktemp -d /var/tmp/5gpn-intercept-renew.XXXXXX)" || return 1
    printf '%s\n' "$TEMP_MARKER_VALUE" > "$stage/$TEMP_MARKER"
    chmod 0644 "$stage/$TEMP_MARKER"
    trap cleanup_all EXIT
    chmod 0700 "$stage"
    if [[ ! -e "$CERT_REQUEST" && ! -L "$CERT_REQUEST" ]]; then
        info "No extension has requested interception hosts yet; nothing to publish."
        return 0
    fi
    readonly_leaf_ready || readonly_rc=$?
    if [[ "$readonly_rc" == 0 ]]; then
        info "The interception certificate result is already current."
        return 0
    fi
    if [[ ! -e /run/5gpn && ! -L /run/5gpn ]]; then
        install -d -o root -g root -m 0700 /run/5gpn
    fi
    root_gid="$(group_gid root)" || { err "The root group is unavailable."; return 1; }
    [[ -d /run/5gpn && ! -L /run/5gpn \
       && "$(readlink -f -- /run/5gpn 2>/dev/null || true)" == /run/5gpn \
       && "$(path_uid /run/5gpn)" == "$EUID" \
       && "$(path_gid /run/5gpn)" == "$root_gid" \
       && "$(path_mode /run/5gpn)" == 700 ]] \
        || { err "The certificate lock directory is unsafe."; return 1; }
    if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        lock_file_safe "$LOCK_FILE" \
            || { err "The certificate lock file is unsafe."; return 1; }
    fi
    exec 9>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE" \
        || { exec 9>&-; err "Could not protect the certificate lock file."; return 1; }
    lock_fd_targets_file 9 "$LOCK_FILE" \
        || { exec 9>&-; err "The certificate lock descriptor is unsafe."; return 1; }
    if ! flock -w 10 9; then
        if [[ "$readonly_rc" == 4 ]]; then
            warn "The interception leaf is due for renewal but remains runtime-valid; another certificate operation will retry renewal later."
            return 0
        fi
        err "Another 5gpn certificate operation is running."
        return 1
    fi
    CERT_LOCK_HELD=1
    cleanup_tls_candidates \
        || { err "Interrupted interception certificate candidates are unsafe."; return 1; }
    group="$(getent group fivegpn 2>/dev/null | cut -d: -f1 || true)"
    [[ "$group" == fivegpn ]] || { err "The fivegpn service group is missing."; return 1; }
    group_gid_value="$(group_gid "$group")" || return 1

    # Path events may coalesce while this oneshot is signing. Re-read and fence
    # each candidate, then converge to the newest request within a strict bound.
    for ((attempt = 1; attempt <= MAX_CONVERGENCE_ATTEMPTS; attempt++)); do
        if [[ ! -e "$CERT_REQUEST" && ! -L "$CERT_REQUEST" ]]; then
            info "The certificate request was withdrawn before publication."
            return 0
        fi
        rc=0
        converge_current_request "$group" "$group_gid_value" || rc=$?
        case "$rc" in
            0)
                ok "Published the fenced interception certificate result."
                return 0
                ;;
            3)
                info "The certificate request changed while signing; converging to the newer attempt."
                continue
                ;;
            *) return "$rc" ;;
        esac
    done
    err "The certificate request changed too frequently to converge safely."
    return 1
}

if [[ "${INTERCEPT_CERT_RENEW_LIB_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
