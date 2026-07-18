#!/bin/bash
# Publish the dynamic interception leaf from the root-protected private CA.
set -euo pipefail

if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info -- "$*"; else echo "[INFO] $*"; fi; }
ok() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info -- "$*"; else echo "[OK]   $*"; fi; }
err() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

CA_DIR=/etc/5gpn/intercept-ca
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

cleanup_stage() {
    local path="${stage:-}" canonical
    [[ -n "$path" && -d "$path" && ! -L "$path" ]] || return 0
    canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ "$canonical" == "$path" && "$canonical" == /var/tmp/5gpn-intercept-renew.* \
       && -f "$canonical/$TEMP_MARKER" && ! -L "$canonical/$TEMP_MARKER" \
       && "$(cat "$canonical/$TEMP_MARKER")" == "$TEMP_MARKER_VALUE" ]] || return 1
    rm -rf -- "$canonical"
}

keypair_matches() {
    local cert="$1" key="$2" cert_pub key_pub
    cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

validate_root() {
    [[ -d "$CA_DIR" && ! -L "$CA_DIR" \
       && "$(readlink -f -- "$CA_DIR" 2>/dev/null || true)" == "$CA_DIR" \
       && -f "$CA_DIR/$CA_MARKER" && ! -L "$CA_DIR/$CA_MARKER" \
       && "$(cat "$CA_DIR/$CA_MARKER")" == "$CA_MARKER_VALUE" \
       && -f "$CA_DIR/root.crt" && ! -L "$CA_DIR/root.crt" \
       && -f "$CA_DIR/root.key" && ! -L "$CA_DIR/root.key" \
       && "$(stat -c %u "$CA_DIR/root.key" 2>/dev/null || true)" == 0 \
       && "$(stat -c %a "$CA_DIR/root.key" 2>/dev/null || true)" == 600 ]] || return 1
    openssl x509 -in "$CA_DIR/root.crt" -noout -checkend "$RENEW_BEFORE" >/dev/null 2>&1 || return 1
    openssl x509 -in "$CA_DIR/root.crt" -noout -text 2>/dev/null | grep -Fq 'CA:TRUE' || return 1
    keypair_matches "$CA_DIR/root.crt" "$CA_DIR/root.key"
}

load_desired_hosts() {
    [[ -x "$INTERCEPT_BIN" && -f "$CONFIG" && ! -L "$CONFIG" ]] || return 1
    "$INTERCEPT_BIN" --config "$CONFIG" --print-certificate-request > "$stage/request"
    head -n 1 "$stage/request" > "$stage/digest"
    tail -n +2 "$stage/request" > "$stage/hosts"
    [[ -s "$stage/hosts" && -s "$stage/digest" ]] || return 1
    desired_digest="$(tr -d '[:space:]' < "$stage/digest")"
    [[ "$desired_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    local host count=0
    while IFS= read -r host; do
        [[ "$host" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
        ((count += 1))
        (( count <= 256 )) || return 1
    done < "$stage/hosts"
    (( count > 0 ))
}

validate_leaf() {
    [[ -f "$TLS_DIR/leaf.crt" && ! -L "$TLS_DIR/leaf.crt" \
       && -f "$TLS_DIR/privkey.pem" && ! -L "$TLS_DIR/privkey.pem" \
       && -f "$CERT_STATE" && ! -L "$CERT_STATE" ]] || return 1
    [[ "$(tr -d '[:space:]' < "$CERT_STATE")" == "$desired_digest" ]] || return 1
    openssl x509 -in "$TLS_DIR/leaf.crt" -noout -checkend "$RENEW_BEFORE" >/dev/null 2>&1 || return 1
    openssl verify -CAfile "$CA_DIR/root.crt" "$TLS_DIR/leaf.crt" >/dev/null 2>&1 || return 1
    keypair_matches "$TLS_DIR/leaf.crt" "$TLS_DIR/privkey.pem" || return 1
    local host probe
    while IFS= read -r host; do
        probe="$host"
        [[ "$probe" != \*.* ]] || probe="probe.${probe#*.}"
        openssl x509 -in "$TLS_DIR/leaf.crt" -noout -checkhost "$probe" 2>/dev/null | grep -Fq 'does match certificate' || return 1
    done < "$stage/hosts"
}

main() {
    local inherited_lock=0
    if [[ $# == 1 && "$1" == --installer-lock-held ]]; then
        inherited_lock=1
    elif [[ $# != 0 ]]; then
        err "This helper accepts only the internal --installer-lock-held flag."
        return 2
    fi
    command -v openssl >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
        || { err "openssl and flock are required."; return 1; }
    if [[ ! -e /run/5gpn && ! -L /run/5gpn ]]; then
        install -d -o root -g root -m 0700 /run/5gpn
    fi
    [[ -d /run/5gpn && ! -L /run/5gpn \
       && "$(readlink -f -- /run/5gpn 2>/dev/null || true)" == /run/5gpn \
       && "$(stat -c %u /run/5gpn 2>/dev/null || true)" == 0 \
       && "$(stat -c %a /run/5gpn 2>/dev/null || true)" == 700 ]] \
        || { err "The certificate lock directory is unsafe."; return 1; }
    if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" \
           && "$(stat -c %u "$LOCK_FILE" 2>/dev/null || true)" == 0 ]] \
            || { err "The certificate lock file is unsafe."; return 1; }
    fi
    if [[ "$inherited_lock" == 1 ]]; then
        [[ -e "/proc/$$/fd/8" \
           && "$(readlink -f "/proc/$$/fd/8" 2>/dev/null || true)" == "$LOCK_FILE" ]] \
            || { err "The installer certificate lock was not inherited on fd 8."; return 1; }
    else
        exec 9>"$LOCK_FILE"
        chmod 0600 "$LOCK_FILE"
        flock -w 10 9 || { err "Another 5gpn certificate operation is running."; return 1; }
    fi
    validate_root || { err "The shared interception root is invalid."; return 1; }
    [[ -d "$TLS_DIR" && ! -L "$TLS_DIR" && "$(readlink -f -- "$TLS_DIR" 2>/dev/null || true)" == "$TLS_DIR" ]] \
        || { err "The interception TLS directory is unsafe."; return 1; }

    local serial group first_host san host
    stage="$(mktemp -d /var/tmp/5gpn-intercept-renew.XXXXXX)"
    printf '%s\n' "$TEMP_MARKER_VALUE" > "$stage/$TEMP_MARKER"
    chmod 0644 "$stage/$TEMP_MARKER"
    trap cleanup_stage EXIT
    chmod 0700 "$stage"
    load_desired_hosts || { err "The enabled module host set is invalid."; return 1; }
    if validate_leaf; then
        info "The interception leaf already covers the enabled module set."
        return 0
    fi

    group="$(getent group gpn-intercept 2>/dev/null | cut -d: -f1 || true)"
    [[ "$group" == gpn-intercept ]] || { err "The gpn-intercept service group is missing."; return 1; }
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
    mv -f -- "$TLS_DIR/.leaf.crt.new" "$TLS_DIR/leaf.crt"
    mv -f -- "$TLS_DIR/.fullchain.pem.new" "$TLS_DIR/fullchain.pem"
    mv -f -- "$TLS_DIR/.privkey.pem.new" "$TLS_DIR/privkey.pem"
    mv -Tf -- "$TLS_DIR/.cert-state.new" "$CERT_STATE"
    validate_leaf || { err "Published interception leaf failed validation."; return 1; }
    ok "Published the interception leaf for the enabled module host set."
}

main "$@"
