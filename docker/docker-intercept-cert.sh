#!/bin/bash -p
# Same-UID interception CA and fenced leaf publisher for the Docker runtime.
# The weaker single-container key boundary is an explicit Docker-mode tradeoff;
# the request/attempt/result protocol remains identical to the host deployment.
set +x +v
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    while IFS= read -r exported_name; do
        unset "$exported_name" 2>/dev/null || true
    done < <(compgen -e)
fi
LANG=C
LC_ALL=C
export LANG LC_ALL
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
HOME=/nonexistent
TMPDIR=/tmp
export HOME TMPDIR
CURRENT_GID="$(id -g)"
EXPECTED_UID=10001
EXPECTED_GID=10001

CA_DIR=/etc/5gpn/intercept-ca
INTERCEPT_DIR=/etc/5gpn/intercept
TLS_DIR=/etc/5gpn/intercept/tls
CERT_REQUEST=/etc/5gpn/mihomo/5gpn/certificate-request
CERT_STATE=/etc/5gpn/intercept/cert-state
LOCK_FILE=/run/5gpn/cert-renew.lock
CA_MARKER=.5gpn-intercept-ca-owned
CA_MARKER_VALUE=5gpn-intercept-ca-v1
INTERCEPT_MARKER=.5gpn-docker-intercept-owned
INTERCEPT_MARKER_VALUE=5gpn-docker-intercept-v1
RENEW_BEFORE=2592000
MAX_REQUEST_BYTES=262144
MAX_CONVERGENCE_ATTEMPTS=16

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }
warn() { printf '[!]    %s\n' "$*" >&2; }
err() { printf '[ERR]  %s\n' "$*" >&2; }

path_uid() { stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || true; }
path_gid() { stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null || true; }
path_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
path_nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || true; }
path_size() { stat -c %s -- "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || true; }

directory_entries() {
    local directory="$1" output_name="$2" scan map_rc=0
    local -n output_ref="$output_name"
    output_ref=()
    scan="$(mktemp "${TMPDIR}/5gpn-directory-entries.XXXXXX")" || return 1
    chmod 0600 "$scan" || { rm -f -- "$scan" 2>/dev/null || true; return 1; }
    owned_plain_file "$scan" 600 \
        || { rm -f -- "$scan" 2>/dev/null || true; return 1; }
    if ! find "$directory" -mindepth 1 -maxdepth 1 -print0 > "$scan" 2>/dev/null; then
        rm -f -- "$scan" 2>/dev/null || true
        return 1
    fi
    mapfile -d '' -t output_ref < "$scan" || map_rc=$?
    rm -f -- "$scan" || return 1
    [[ "$map_rc" == 0 ]]
}

canonical_directory() {
    local path="$1" canonical
    [[ -d "$path" && ! -L "$path" ]] || return 1
    canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ -n "$canonical" && "$canonical" == "$path" ]]
}

owned_directory() {
    local path="$1" mode="$2"
    canonical_directory "$path" \
        && [[ "$(path_uid "$path")" == "$EUID" \
           && "$(path_gid "$path")" == "$CURRENT_GID" \
           && "$(path_mode "$path")" == "$mode" ]]
}

owned_plain_file() {
    local path="$1" mode="$2"
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" \
       && "$(path_mode "$path")" == "$mode" \
       && "$(path_nlink "$path")" == 1 ]]
}

owned_exact_line_file() {
	local path="$1" mode="$2" value="$3" size expected
	owned_plain_file "$path" "$mode" || return 1
	size="$(path_size "$path")"
	expected=$((${#value} + 1))
	[[ "$size" =~ ^[0-9]+$ && "$size" == "$expected" ]] || return 1
	printf '%s\n' "$value" | cmp -s - "$path"
}

ensure_owned_directory() {
	local path="$1" mode="$2" parent actual_mode
	local -a entries=()
	if [[ ! -e "$path" && ! -L "$path" ]]; then
        parent="$(dirname -- "$path")"
        canonical_directory "$parent" \
            && [[ "$(path_uid "$parent")" == "$EUID" \
               && "$(path_gid "$parent")" == "$CURRENT_GID" ]] || return 1
		mkdir -m "$mode" -- "$path" || return 1
		fsync_directory "$parent" || return 1
	fi
	if owned_directory "$path" "$mode"; then
		return 0
	fi
	if [[ "$mode" == 750 ]] && canonical_directory "$path" \
	   && [[ "$(path_uid "$path")" == "$EUID" \
	      && "$(path_gid "$path")" == "$CURRENT_GID" ]]; then
		actual_mode="$(path_mode "$path")"
		directory_entries "$path" entries || return 1
		if [[ "$actual_mode" == 700 && "${#entries[@]}" == 0 ]]; then
			chmod 0750 "$path" || return 1
			fsync_directory "$path" || return 1
		fi
	fi
	owned_directory "$path" "$mode"
}

write_marker_if_absent() {
	local dir="$1" name="$2" value="$3" mode="$4" marker candidate entry tmp parent
	local -a entries=()
	marker="$dir/$name"
	candidate="$dir/${name}.candidate"
	if [[ ! -e "$marker" && ! -L "$marker" ]]; then
		directory_entries "$dir" entries || return 1
		for entry in "${entries[@]}"; do
			[[ "$entry" == "$candidate" ]] || return 1
		done
		if [[ -e "$candidate" || -L "$candidate" ]]; then
			owned_exact_line_file "$candidate" "$mode" "$value" || return 1
		else
			parent="$(dirname -- "$dir")"
			tmp="$(mktemp "$parent/.5gpn-marker-stage.XXXXXX")" || return 1
			printf '%s\n' "$value" > "$tmp" \
				|| { rm -f -- "$tmp"; return 1; }
			chmod "$mode" "$tmp" || { rm -f -- "$tmp"; return 1; }
			owned_plain_file "$tmp" "$mode" \
				|| { rm -f -- "$tmp"; return 1; }
			fsync_file "$tmp" || { rm -f -- "$tmp"; return 1; }
			directory_entries "$dir" entries \
				|| { rm -f -- "$tmp"; return 1; }
			[[ "${#entries[@]}" == 0 ]] \
				|| { rm -f -- "$tmp"; return 1; }
			mv -Tn -- "$tmp" "$candidate" || { rm -f -- "$tmp"; return 1; }
			[[ ! -e "$tmp" && ! -L "$tmp" ]] \
				|| { rm -f -- "$tmp"; return 1; }
			fsync_directory "$dir" || return 1
		fi
		owned_exact_line_file "$candidate" "$mode" "$value" || return 1
		mv -Tn -- "$candidate" "$marker" || return 1
		[[ ! -e "$candidate" && ! -L "$candidate" ]] || return 1
		fsync_directory "$dir" || return 1
	fi
	[[ ! -e "$candidate" && ! -L "$candidate" ]] \
		&& owned_exact_line_file "$marker" "$mode" "$value"
}

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

keypair_matches() {
    local cert="$1" key="$2" cert_pub key_pub
    cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

ca_tree_safe() {
    local entry name count=0
    local -a entries=()
	owned_directory "$CA_DIR" 700 \
		&& owned_exact_line_file "$CA_DIR/$CA_MARKER" 644 "$CA_MARKER_VALUE" \
        || return 1
    directory_entries "$CA_DIR" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            "$CA_MARKER") owned_plain_file "$entry" 644 || return 1 ;;
            root.crt) owned_plain_file "$entry" 644 || return 1 ;;
            root.key) owned_plain_file "$entry" 600 || return 1 ;;
            *) return 1 ;;
        esac
        ((count += 1))
    done
    [[ "$count" == 3 ]]
}

validate_ca_pair() {
    local cert="$1" key="$2" subject issuer constraints key_usage
    [[ -f "$cert" && ! -L "$cert" && -f "$key" && ! -L "$key" \
       && "$(path_uid "$cert")" == "$EUID" \
       && "$(path_gid "$cert")" == "$CURRENT_GID" \
       && "$(path_mode "$cert")" == 644 \
       && "$(path_nlink "$cert")" == 1 \
       && "$(path_uid "$key")" == "$EUID" \
       && "$(path_gid "$key")" == "$CURRENT_GID" \
       && "$(path_mode "$key")" == 600 \
       && "$(path_nlink "$key")" == 1 ]] || return 1
    openssl x509 -in "$cert" -noout -checkend "$RENEW_BEFORE" >/dev/null 2>&1 || return 1
    openssl verify -check_ss_sig -CAfile "$cert" "$cert" >/dev/null 2>&1 || return 1
    subject="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null)" || return 1
    issuer="$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 2>/dev/null)" || return 1
    [[ "$subject" == 'subject=CN=5gpn Interception Root' \
       && "$issuer" == 'issuer=CN=5gpn Interception Root' ]] || return 1
    constraints="$(openssl x509 -in "$cert" -noout -ext basicConstraints 2>/dev/null)" || return 1
    [[ "$constraints" == *'Basic Constraints: critical'* \
       && "$constraints" == *'CA:TRUE, pathlen:0'* ]] || return 1
    key_usage="$(openssl x509 -in "$cert" -noout -ext keyUsage 2>/dev/null)" || return 1
    [[ "$key_usage" == *'Key Usage: critical'* \
       && "$key_usage" == *'Certificate Sign, CRL Sign'* ]] || return 1
    openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -Fq 'Public Key Algorithm: rsaEncryption' \
        && openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -Fq 'Public-Key: (3072 bit)' \
        && keypair_matches "$cert" "$key"
}

validate_root() {
    ca_tree_safe \
        && validate_ca_pair "$CA_DIR/root.crt" "$CA_DIR/root.key"
}

recover_ca_publication() {
    local live_cert="$CA_DIR/root.crt" live_key="$CA_DIR/root.key"
    local new_cert="$CA_DIR/.root.crt.new" new_key="$CA_DIR/.root.key.new"
    local cert_source="" key_source="" path
    for path in "$live_cert" "$new_cert"; do
        [[ -e "$path" || -L "$path" ]] || continue
        [[ -f "$path" && ! -L "$path" \
           && "$(path_uid "$path")" == "$EUID" \
           && "$(path_gid "$path")" == "$CURRENT_GID" \
           && "$(path_mode "$path")" == 644 \
           && "$(path_nlink "$path")" == 1 ]] || return 1
    done
    for path in "$live_key" "$new_key"; do
        [[ -e "$path" || -L "$path" ]] || continue
        [[ -f "$path" && ! -L "$path" \
           && "$(path_uid "$path")" == "$EUID" \
           && "$(path_gid "$path")" == "$CURRENT_GID" \
           && "$(path_mode "$path")" == 600 \
           && "$(path_nlink "$path")" == 1 ]] || return 1
    done
    if [[ -e "$live_cert" && -e "$live_key" ]]; then
        validate_ca_pair "$live_cert" "$live_key" || return 1
        rm -f -- "$new_cert" "$new_key" || return 1
        return 0
    fi
    if [[ -e "$live_cert" ]]; then
        cert_source="$live_cert"
    elif [[ -e "$new_cert" ]]; then
        cert_source="$new_cert"
    fi
    if [[ -e "$live_key" ]]; then
        key_source="$live_key"
    elif [[ -e "$new_key" ]]; then
        key_source="$new_key"
    fi
    if [[ -n "$cert_source" && -n "$key_source" ]] \
       && validate_ca_pair "$cert_source" "$key_source"; then
        [[ "$cert_source" == "$live_cert" ]] || mv -Tf -- "$cert_source" "$live_cert" || return 1
        [[ "$key_source" == "$live_key" ]] || mv -Tf -- "$key_source" "$live_key" || return 1
        fsync_directory "$CA_DIR" || return 1
        validate_ca_pair "$live_cert" "$live_key"
        return
    fi
    if [[ -e "$live_cert" || -e "$live_key" ]]; then
        return 1
    fi
    rm -f -- "$new_cert" "$new_key" || return 1
    return 2
}

ensure_intercept_layout() {
    ensure_owned_directory "$INTERCEPT_DIR" 750 \
        && write_marker_if_absent "$INTERCEPT_DIR" "$INTERCEPT_MARKER" "$INTERCEPT_MARKER_VALUE" 600 \
        && ensure_owned_directory "$TLS_DIR" 750
}

tls_tree_safe() {
    local entry name
    local -a entries=()
    ensure_intercept_layout || return 1
    directory_entries "$TLS_DIR" entries || return 1
    for entry in "${entries[@]}"; do
        name="$(basename -- "$entry")"
        case "$name" in
            leaf.crt|fullchain.pem|privkey.pem) owned_plain_file "$entry" 640 || return 1 ;;
            *) return 1 ;;
        esac
    done
    if [[ -e "$CERT_STATE" || -L "$CERT_STATE" ]]; then
        owned_plain_file "$CERT_STATE" 640 || return 1
    fi
}

init_ca() {
    local stage recovery_rc=0
    canonical_directory /etc/5gpn \
        && [[ "$(path_uid /etc/5gpn)" == "$EUID" \
           && "$(path_gid /etc/5gpn)" == "$CURRENT_GID" ]] \
        || { err "The persistent /etc/5gpn root is unsafe or belongs to another identity."; return 1; }
    ensure_owned_directory "$CA_DIR" 700 \
        && write_marker_if_absent "$CA_DIR" "$CA_MARKER" "$CA_MARKER_VALUE" 644 \
        && ensure_intercept_layout \
        || { err "The interception certificate directories are unsafe."; return 1; }
    recover_ca_publication || recovery_rc=$?
    if [[ "$recovery_rc" == 0 ]] && validate_root; then
        ok "The persistent interception CA is valid."
        return 0
    fi
    [[ "$recovery_rc" == 2 ]] \
        || { err "The committed interception CA is invalid; refusing to replace client trust silently."; return 1; }
    stage="$(mktemp -d /tmp/5gpn-intercept-ca.XXXXXX)" || return 1
    chmod 0700 "$stage" || { rm -rf -- "$stage"; return 1; }
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
            -subj '/CN=5gpn Interception Root' \
            -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
            -addext 'keyUsage=critical,keyCertSign,cRLSign' \
            -keyout "$stage/root.key" -out "$stage/root.crt" >/dev/null 2>&1 \
        || { rm -rf -- "$stage"; return 1; }
    chmod 0600 "$stage/root.key" \
        && chmod 0644 "$stage/root.crt" \
        || { rm -rf -- "$stage"; return 1; }
    validate_ca_pair "$stage/root.crt" "$stage/root.key" \
        || { rm -rf -- "$stage"; return 1; }
    install -m 0600 "$stage/root.key" "$CA_DIR/.root.key.new" \
        && install -m 0644 "$stage/root.crt" "$CA_DIR/.root.crt.new" \
        || { rm -rf -- "$stage"; return 1; }
    fsync_file "$CA_DIR/.root.key.new" \
        && fsync_file "$CA_DIR/.root.crt.new" \
        || { rm -rf -- "$stage"; return 1; }
    rm -rf -- "$stage" || return 1
    recovery_rc=0
    recover_ca_publication || recovery_rc=$?
    [[ "$recovery_rc" == 0 ]] || return 1
    validate_root || { err "The published interception CA failed validation."; return 1; }
    ok "Initialized the persistent interception CA."
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
    local process_id="${BASHPID:-$$}" parent
    parent="$(dirname -- "$CERT_REQUEST")"
    canonical_directory "$parent" \
        && [[ "$(path_uid "$parent")" == "$EUID" \
           && "$(path_gid "$parent")" == "$CURRENT_GID" ]] || return 1
    [[ -f "$CERT_REQUEST" && ! -L "$CERT_REQUEST" \
       && "$(path_nlink "$CERT_REQUEST")" == 1 \
       && "$(path_mode "$CERT_REQUEST")" == 644 \
       && "$(path_uid "$CERT_REQUEST")" == "$EUID" \
       && "$(path_gid "$CERT_REQUEST")" == "$CURRENT_GID" ]] || return 1
    exec {fd}<"$CERT_REQUEST" || return 1
    path_identity="$(stat -Lc '%d:%i' -- "$CERT_REQUEST" 2>/dev/null || true)"
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/${process_id}/fd/${fd}" 2>/dev/null || true)"
    initial_size="$(stat -Lc '%s' -- "/proc/${process_id}/fd/${fd}" 2>/dev/null || true)"
    if [[ -z "$path_identity" || "$path_identity" != "$fd_identity" \
       || ! "$initial_size" =~ ^[0-9]+$ || "$initial_size" -le 0 \
       || "$initial_size" -gt "$MAX_REQUEST_BYTES" ]]; then
        exec {fd}<&-
        return 1
    fi
    if ! head -c "$((MAX_REQUEST_BYTES + 1))" <&"$fd" > "$destination"; then
        exec {fd}<&-
        return 1
    fi
    final_size="$(stat -Lc '%s' -- "/proc/${process_id}/fd/${fd}" 2>/dev/null || true)"
    exec {fd}<&-
    [[ "$(stat -Lc '%d:%i' -- "$CERT_REQUEST" 2>/dev/null || true)" == "$path_identity" ]] || return 1
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
    : > "$stage/hosts" || return 1
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
            [[ ${#host} -le 255 \
               && "$host" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
            [[ -z "$previous" || "$host" > "$previous" ]] || return 1
            printf '%s\n' "$host" >> "$stage/hosts" || return 1
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
            "$desired_digest" "$desired_attempt" "$certificate_hash" "$private_key_hash" > "$destination" \
            || return 1
    else
        printf '{"version":1,"target_digest":"%s","attempt":"%s","status":"ready"}' \
            "$desired_digest" "$desired_attempt" > "$destination" || return 1
    fi
}

render_error_state() {
    local destination="$1" code="$2" message="$3"
    [[ "$code" =~ ^[a-z][a-z0-9_]{0,63}$ \
       && "$message" =~ ^[A-Za-z0-9.,\ -]{1,160}$ \
       && "$message" != *$'\n'* && "$message" != *$'\r'* ]] || return 1
    printf '{"version":1,"target_digest":"%s","attempt":"%s","status":"error","code":"%s","message":"%s"}' \
        "$desired_digest" "$desired_attempt" "$code" "$message" > "$destination" || return 1
}

load_committed_ready_state() {
    local ready_re empty_re
    owned_plain_file "$CERT_STATE" 640 || return 1
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
    sans="$(openssl x509 -in "$certificate" -noout -ext subjectAltName 2>/dev/null)" || return 1
    : > "$stage/material-hosts" || return 1
    while IFS= read -r entry; do
        entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -n "$entry" ]] || continue
        [[ "$entry" == DNS:* ]] || return 1
        host="${entry#DNS:}"
        [[ ${#host} -le 255 \
           && "$host" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
        printf '%s\n' "$host" >> "$stage/material-hosts" || return 1
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
    local leaf_digest chain_leaf_digest expected_chain_digest fullchain_digest host probe
    [[ -f "$leaf" && ! -L "$leaf" && -f "$fullchain" && ! -L "$fullchain" \
       && -f "$key" && ! -L "$key" ]] || return 1
    openssl x509 -in "$leaf" -noout -checkend "$check_seconds" >/dev/null 2>&1 || return 1
    openssl verify -purpose sslserver -CAfile "$CA_DIR/root.crt" "$leaf" >/dev/null 2>&1 || return 1
    keypair_matches "$leaf" "$key" || return 1
    leaf_digest="$(certificate_der_sha256 "$leaf")" || return 1
    chain_leaf_digest="$(certificate_der_sha256 "$fullchain")" || return 1
    [[ "$leaf_digest" == "$chain_leaf_digest" ]] || return 1
    expected_chain_digest="$(cat "$leaf" "$CA_DIR/root.crt" | sha256sum)" || return 1
    fullchain_digest="$(sha256sum "$fullchain")" || return 1
    [[ "${expected_chain_digest%% *}" == "${fullchain_digest%% *}" ]] || return 1
    openssl x509 -in "$leaf" -noout -ext basicConstraints 2>/dev/null \
        | grep -Fq 'CA:FALSE' || return 1
    openssl x509 -in "$leaf" -noout -ext keyUsage 2>/dev/null \
        | grep -Fq 'Digital Signature' || return 1
    openssl x509 -in "$leaf" -noout -ext extendedKeyUsage 2>/dev/null \
        | grep -Fq 'TLS Web Server Authentication' || return 1
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
    tls_tree_safe && validate_root \
        && validate_material "$TLS_DIR/leaf.crt" "$TLS_DIR/fullchain.pem" \
            "$TLS_DIR/privkey.pem" "$check_seconds"
}

validate_committed_ready() {
    local check_seconds="${1:-$RENEW_BEFORE}"
    load_committed_ready_state || return 1
    [[ -s "$stage/hosts" ]] || return 0
    validate_live_material "$check_seconds" \
        && [[ "$committed_certificate_hash" == "$material_certificate_hash" \
           && "$committed_private_key_hash" == "$material_private_key_hash" ]]
}

candidate_file_safe() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$EUID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" \
       && "$(path_nlink "$path")" == 1 \
       && "$(path_mode "$path")" =~ ^(600|640)$ ]]
}

cleanup_candidates() {
    local path
    ensure_intercept_layout || return 1
    for path in "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/.fullchain.pem.new" \
        "$TLS_DIR/.privkey.pem.new" "$INTERCEPT_DIR/.cert-state.new"; do
        [[ ! -e "$path" && ! -L "$path" ]] && continue
        candidate_file_safe "$path" || return 1
        rm -f -- "$path" || return 1
    done
}

publish_state_file() {
    local source="$1" candidate="$INTERCEPT_DIR/.cert-state.new"
    ensure_intercept_layout || return 1
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || return 1
    install -m 0640 "$source" "$candidate" || return 1
    owned_plain_file "$candidate" 640 && fsync_file "$candidate" || return 1
    if ! request_is_current; then
        rm -f -- "$candidate" || return 1
        return 3
    fi
    mv -Tf -- "$candidate" "$CERT_STATE" || return 1
    fsync_directory "$INTERCEPT_DIR" || return 1
    request_is_current || return 3
}

publish_error_if_current() {
    local code="$1" message="$2"
    render_error_state "$stage/error-state" "$code" "$message" || return 1
    publish_state_file "$stage/error-state"
}

generate_candidate() {
    local first_host san="" host serial
    first_host="$(head -n 1 "$stage/hosts")"
    [[ -n "$first_host" ]] || return 1
    while IFS= read -r host; do
        san="${san}${san:+,}DNS:${host}"
    done < "$stage/hosts"
    openssl ecparam -name prime256v1 -genkey -noout -out "$stage/privkey.pem" || return 1
    openssl req -new -sha256 -key "$stage/privkey.pem" \
        -subj "/CN=${first_host}" -out "$stage/leaf.csr" || return 1
    printf '%s\n' \
        'basicConstraints=critical,CA:FALSE' \
        'keyUsage=critical,digitalSignature' \
        'extendedKeyUsage=serverAuth' \
        "subjectAltName=${san}" > "$stage/leaf.ext" || return 1
    serial="0x$(openssl rand -hex 16)" || return 1
    openssl x509 -req -sha256 -days 397 -set_serial "$serial" \
        -in "$stage/leaf.csr" -CA "$CA_DIR/root.crt" -CAkey "$CA_DIR/root.key" \
        -extfile "$stage/leaf.ext" -out "$stage/leaf.crt" >/dev/null 2>&1 || return 1
    cat "$stage/leaf.crt" "$CA_DIR/root.crt" > "$stage/fullchain.pem" || return 1
    validate_material "$stage/leaf.crt" "$stage/fullchain.pem" "$stage/privkey.pem" "$RENEW_BEFORE"
}

publish_certificate_candidate() {
    local candidate rc=0
    render_ready_state "$stage/ready-state" "$material_certificate_hash" \
        "$material_private_key_hash" || return 1
    request_is_current || return 3
    cleanup_candidates || return 1
    install -m 0640 "$stage/leaf.crt" "$TLS_DIR/.leaf.crt.new" \
        && install -m 0640 "$stage/fullchain.pem" "$TLS_DIR/.fullchain.pem.new" \
        && install -m 0640 "$stage/privkey.pem" "$TLS_DIR/.privkey.pem.new" || return 1
    for candidate in "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/.fullchain.pem.new" \
        "$TLS_DIR/.privkey.pem.new"; do
        owned_plain_file "$candidate" 640 && fsync_file "$candidate" || return 1
    done
    if ! request_is_current; then
        cleanup_candidates || return 1
        return 3
    fi
    mv -f -- "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/leaf.crt" \
        && mv -f -- "$TLS_DIR/.fullchain.pem.new" "$TLS_DIR/fullchain.pem" \
        && mv -f -- "$TLS_DIR/.privkey.pem.new" "$TLS_DIR/privkey.pem" \
        && fsync_directory "$TLS_DIR" || return 1
    request_is_current || return 3
    publish_state_file "$stage/ready-state" || rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    validate_committed_ready 60 && request_is_current
}

converge_current_request() {
    local rc=0
    load_desired_hosts || { err "The interception certificate request is invalid."; return 1; }
    validate_committed_ready "$RENEW_BEFORE" && return 0
    if [[ ! -s "$stage/hosts" ]]; then
        render_ready_state "$stage/ready-state" || return 1
        publish_state_file "$stage/ready-state"
        return
    fi
    if ! validate_root; then
        publish_error_if_current ca_invalid 'The interception certificate authority is invalid.' || rc=$?
        [[ "$rc" == 3 ]] && return 3
        return 1
    fi
    if validate_live_material "$RENEW_BEFORE"; then
        render_ready_state "$stage/ready-state" "$material_certificate_hash" \
            "$material_private_key_hash" || return 1
        publish_state_file "$stage/ready-state"
        return
    fi
    if ! generate_candidate; then
        publish_error_if_current signing_failed \
            'The interception certificate could not be generated.' || rc=$?
        [[ "$rc" == 3 ]] && return 3
        return 1
    fi
    publish_certificate_candidate || rc=$?
    case "$rc" in
        0) return 0 ;;
        3) return 3 ;;
    esac
    publish_error_if_current publication_failed \
        'The interception certificate could not be published.' || rc=$?
    [[ "$rc" == 3 ]] && return 3
    return 1
}

ensure_lock() {
    local lock_dir fd_identity file_identity
    lock_dir="$(dirname -- "$LOCK_FILE")"
    owned_directory "$lock_dir" 700 || return 1
    if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        owned_plain_file "$LOCK_FILE" 600 || return 1
    fi
    exec 9>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE" || { exec 9>&-; return 1; }
    owned_plain_file "$LOCK_FILE" 600 || { exec 9>&-; return 1; }
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/9" 2>/dev/null || true)"
    file_identity="$(stat -Lc '%d:%i' -- "$LOCK_FILE" 2>/dev/null || true)"
    [[ -n "$fd_identity" && "$fd_identity" == "$file_identity" ]] \
        || { exec 9>&-; return 1; }
    flock -w 10 9
}

cleanup_stage() {
    local path="${stage:-}" canonical
    [[ -n "$path" && -d "$path" && ! -L "$path" ]] || return 0
    canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ "$canonical" == "$path" && "$canonical" == /tmp/5gpn-intercept-cert.* \
       && "$(path_uid "$canonical")" == "$EUID" \
       && "$(path_gid "$canonical")" == "$CURRENT_GID" \
       && "$(path_mode "$canonical")" == 700 ]] || return 1
    rm -rf -- "$canonical"
}

cleanup_stage_on_exit() {
    local rc=$?
    trap - EXIT
    cleanup_stage || rc=1
    exit "$rc"
}

reconcile() {
    local attempt rc=0
    ensure_intercept_layout && validate_root \
        || { err "The interception CA or publication tree is unsafe."; return 1; }
    cleanup_candidates && tls_tree_safe \
        || { err "Interrupted certificate candidates or the live TLS tree are unsafe."; return 1; }
    if [[ ! -e "$CERT_REQUEST" && ! -L "$CERT_REQUEST" ]]; then
        info "No extension certificate request exists yet."
        return 0
    fi
    stage="$(mktemp -d /tmp/5gpn-intercept-cert.XXXXXX)" || return 1
    chmod 0700 "$stage" || { rm -rf -- "$stage"; return 1; }
    trap cleanup_stage_on_exit EXIT
    for ((attempt = 1; attempt <= MAX_CONVERGENCE_ATTEMPTS; attempt++)); do
        if [[ ! -e "$CERT_REQUEST" && ! -L "$CERT_REQUEST" ]]; then
            info "The interception certificate request was withdrawn."
            return 0
        fi
        rc=0
        converge_current_request || rc=$?
        case "$rc" in
            0) ok "The fenced interception certificate result is current."; return 0 ;;
            3) info "The request changed during signing; converging to its new attempt." ;;
            *) return "$rc" ;;
        esac
    done
    err "The interception certificate request changed too frequently to converge."
    return 1
}

main() {
    [[ $# == 1 ]] || { err "Usage: $0 init-ca|reconcile"; return 2; }
    [[ "$EUID" == "$EXPECTED_UID" && "$CURRENT_GID" == "$EXPECTED_GID" ]] \
        || { err "Docker certificate helpers require fixed UID:GID 10001:10001."; return 1; }
    for command in openssl flock sha256sum sync cmp sort head find; do
        command -v "$command" >/dev/null 2>&1 \
            || { err "Required certificate tool is unavailable: $command"; return 1; }
    done
    ensure_lock || { err "Another certificate operation is running or the lock is unsafe."; return 1; }
    case "$1" in
        init-ca) init_ca ;;
        reconcile) reconcile ;;
        *) err "Usage: $0 init-ca|reconcile"; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
