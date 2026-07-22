#!/bin/bash
# Publish the dynamic interception leaf from the root-protected private CA.
set -euo pipefail

if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info -- "$*"; else echo "[INFO] $*"; fi; }
ok() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level warn -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

CA_DIR=/etc/5gpn/intercept-ca
INTERCEPT_DIR=/etc/5gpn/intercept
TLS_DIR=/etc/5gpn/intercept/tls
CONFIG=/etc/5gpn/intercept/config.json
INTERCEPT_BIN=/opt/5gpn/bin/5gpn-intercept
CERT_STATE=/etc/5gpn/intercept/cert-state
CA_MARKER=.5gpn-intercept-ca-owned
CA_MARKER_VALUE=5gpn-intercept-ca-v1
LOCK_FILE=/run/5gpn/cert-renew.lock
RENEW_BEFORE=2592000
TEMP_MARKER=.5gpn-temp-owned
TEMP_MARKER_VALUE=5gpn-intercept-renew-v2
CONFIG_ROOT_MARKER=.5gpn-owned
CONFIG_ROOT_MARKER_VALUE=5gpn-config-v1

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
    local config_root dns_gid root_gid marker
    config_root="$(dirname -- "$CA_DIR")"
    [[ "$(dirname -- "$INTERCEPT_DIR")" == "$config_root" ]] || return 1
    dns_gid="$(group_gid gpn-dns)" || return 1
    root_gid="$(group_gid root)" || return 1
    canonical_directory "$config_root" \
        && [[ "$(path_uid "$config_root")" == "$EUID" \
           && "$(path_gid "$config_root")" == "$dns_gid" \
           && "$(path_mode "$config_root")" == 3771 ]] \
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
    intercept_gid="$(group_gid gpn-intercept)" || return 1
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
    intercept_gid="$(group_gid gpn-intercept)" || return 1
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
    local fd="$1" lock="$2" fd_identity file_identity
    [[ -e "/proc/$$/fd/${fd}" ]] || return 1
    lock_file_safe "$lock" || return 1
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/$$/fd/${fd}" 2>/dev/null || true)"
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
    intercept_gid="$(group_gid gpn-intercept)" || return 1
    for path in \
        "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/.fullchain.pem.new" \
        "$TLS_DIR/.privkey.pem.new" "$TLS_DIR/.cert-state.new"; do
        [[ ! -e "$path" && ! -L "$path" ]] && continue
        interrupted_tls_candidate_is_safe "$path" "$intercept_gid" || return 1
        rm -f -- "$path" || return 1
    done
}

cleanup_all() {
    local rc=0
    cleanup_tls_candidates || rc=1
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

load_desired_hosts() {
    [[ -x "$INTERCEPT_BIN" && -f "$CONFIG" && ! -L "$CONFIG" ]] || return 1
    "$INTERCEPT_BIN" --config "$CONFIG" --print-certificate-request > "$stage/request"
    head -n 1 "$stage/request" > "$stage/digest"
    tail -n +2 "$stage/request" > "$stage/hosts"
    [[ -f "$stage/hosts" && -s "$stage/digest" ]] || return 1
    desired_digest="$(tr -d '[:space:]' < "$stage/digest")"
    [[ "$desired_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    local host count=0
    while IFS= read -r host; do
        [[ "$host" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
        ((count += 1))
        (( count <= 512 )) || return 1
    done < "$stage/hosts"
    return 0
}

validate_leaf() {
    local check_seconds="${1:-$RENEW_BEFORE}"
    tls_tree_safe || return 1
    [[ -f "$TLS_DIR/leaf.crt" && -f "$TLS_DIR/fullchain.pem" \
       && -f "$TLS_DIR/privkey.pem" && -f "$CERT_STATE" ]] || return 1
    [[ "$(tr -d '[:space:]' < "$CERT_STATE")" == "$desired_digest" ]] || return 1
    openssl x509 -in "$TLS_DIR/leaf.crt" -noout -checkend "$check_seconds" >/dev/null 2>&1 || return 1
    openssl verify -CAfile "$CA_DIR/root.crt" "$TLS_DIR/leaf.crt" >/dev/null 2>&1 || return 1
    keypair_matches "$TLS_DIR/leaf.crt" "$TLS_DIR/privkey.pem" || return 1
    local host probe
    while IFS= read -r host; do
        probe="$host"
        [[ "$probe" != \*.* ]] || probe="probe.${probe#*.}"
        openssl x509 -in "$TLS_DIR/leaf.crt" -noout -checkhost "$probe" 2>/dev/null | grep -Fq 'does match certificate' || return 1
    done < "$stage/hosts"
}

readonly_leaf_ready() {
    load_desired_hosts || return 1
    [[ -s "$stage/hosts" ]] || return 3
    validate_root && tls_tree_safe && validate_leaf 60 || return 1
    validate_leaf "$RENEW_BEFORE" && return 0
    return 4
}

main() {
    local inherited_lock=0 root_gid readonly_rc=0
    if [[ $# == 1 && "$1" == --installer-lock-held ]]; then
        inherited_lock=1
    elif [[ $# != 0 ]]; then
        err "This helper accepts only the internal --installer-lock-held flag."
        return 2
    fi
    [[ "$EUID" == 0 ]] || { err "Interception certificate renewal must run as root."; return 1; }
    command -v openssl >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
        || { err "openssl and flock are required."; return 1; }
    stage="$(mktemp -d /var/tmp/5gpn-intercept-renew.XXXXXX)" || return 1
    printf '%s\n' "$TEMP_MARKER_VALUE" > "$stage/$TEMP_MARKER"
    chmod 0644 "$stage/$TEMP_MARKER"
    trap cleanup_all EXIT
    chmod 0700 "$stage"
    readonly_leaf_ready || readonly_rc=$?
    case "$readonly_rc" in
        0) info "The interception leaf already covers the enabled extension set."; return 0 ;;
        3) info "No enabled extension requests interception hosts; keeping any previous leaf unused."; return 0 ;;
    esac
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
    if [[ "$inherited_lock" == 1 ]]; then
        lock_fd_targets_file 8 "$LOCK_FILE" \
            || { err "The installer certificate lock was not inherited on fd 8."; return 1; }
    else
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
    fi
    cleanup_tls_candidates \
        || { err "Interrupted interception certificate candidates are unsafe."; return 1; }
    validate_root || { err "The shared interception root is invalid."; return 1; }
    tls_tree_safe \
        || { err "The interception TLS directory is unsafe."; return 1; }

    local serial group group_gid_value first_host san host
    load_desired_hosts || { err "The enabled extension capture-host set is invalid."; return 1; }
    if [[ ! -s "$stage/hosts" ]]; then
        info "No enabled extension requests interception hosts; keeping any previous leaf unused."
        return 0
    fi
    if validate_leaf; then
        info "The interception leaf already covers the enabled extension set."
        return 0
    fi

    group="$(getent group gpn-intercept 2>/dev/null | cut -d: -f1 || true)"
    [[ "$group" == gpn-intercept ]] || { err "The gpn-intercept service group is missing."; return 1; }
    group_gid_value="$(group_gid "$group")" || return 1
    first_host="$(head -n 1 "$stage/hosts")"
    san=""
    while IFS= read -r host; do
        san="${san}${san:+,}DNS:${host}"
    done < "$stage/hosts"
    openssl ecparam -name prime256v1 -genkey -noout -out "$stage/privkey.pem"
    openssl req -new -sha256 -key "$stage/privkey.pem" -subj "/CN=${first_host}" -out "$stage/leaf.csr"
    cat > "$stage/leaf.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=${san}
EOF
    serial="0x$(openssl rand -hex 16)"
    openssl x509 -req -sha256 -days 397 -set_serial "$serial" \
        -in "$stage/leaf.csr" -CA "$CA_DIR/root.crt" -CAkey "$CA_DIR/root.key" \
        -extfile "$stage/leaf.ext" -out "$stage/leaf.crt" >/dev/null 2>&1
    cat "$stage/leaf.crt" "$CA_DIR/root.crt" > "$stage/fullchain.pem"
    openssl verify -CAfile "$CA_DIR/root.crt" "$stage/leaf.crt" >/dev/null
    install -d -o root -g "$group" -m 0750 "$TLS_DIR"
    install -o root -g "$group" -m 0640 "$stage/leaf.crt" "$TLS_DIR/.leaf.crt.new"
    install -o root -g "$group" -m 0640 "$stage/fullchain.pem" "$TLS_DIR/.fullchain.pem.new"
    install -o root -g "$group" -m 0640 "$stage/privkey.pem" "$TLS_DIR/.privkey.pem.new"
    rm -f -- "$TLS_DIR/.cert-state.new"
    [[ ! -e "$TLS_DIR/.cert-state.new" && ! -L "$TLS_DIR/.cert-state.new" ]] \
        || { err "The interception certificate state candidate path is unsafe."; return 1; }
    install -o root -g "$group" -m 0640 "$stage/digest" "$TLS_DIR/.cert-state.new"
    safe_plain_file "$TLS_DIR/.leaf.crt.new" "$group_gid_value" 640 \
        && safe_plain_file "$TLS_DIR/.fullchain.pem.new" "$group_gid_value" 640 \
        && safe_plain_file "$TLS_DIR/.privkey.pem.new" "$group_gid_value" 640 \
        && safe_plain_file "$TLS_DIR/.cert-state.new" "$group_gid_value" 640 \
        || { err "The interception certificate candidates are unsafe."; return 1; }
    mv -f -- "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/leaf.crt"
    mv -f -- "$TLS_DIR/.fullchain.pem.new" "$TLS_DIR/fullchain.pem"
    mv -f -- "$TLS_DIR/.privkey.pem.new" "$TLS_DIR/privkey.pem"
    mv -Tf -- "$TLS_DIR/.cert-state.new" "$CERT_STATE"
    validate_leaf || { err "Published interception leaf failed validation."; return 1; }
    ok "Published the interception leaf for the enabled extension capture-host set."
}

if [[ "${INTERCEPT_CERT_RENEW_LIB_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
