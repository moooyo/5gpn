#!/bin/bash
# Generate the signed 5gpn iOS DoT configuration profile (.mobileconfig).
#
# Architecture: client DoT:853 (the ONLY DNS transport) -> 5gpn-mihomo; DNS
# answers then steer application traffic to direct origins or the mihomo gateway.
# The profile points the phone's cellular DNS at this gateway over TLS (DoT). On
# Wi-Fi it disconnects, so it only applies on cellular as designed.
#
# Usage: gen-ios-profile.sh <DOMAIN> <GATEWAY_IP> <UNPUBLISHED_GENERATION>
#   GATEWAY_IP = client-facing gateway address written into ServerAddresses
#   (public IP for public deployments, internal 172.22 addr for NPN-only).
#   UNPUBLISHED_GENERATION is prepared by scripts/ui-generation.sh. This helper
#   refuses the live UI root/current generation and never switches publication.
set -euo pipefail

# --- Gum-or-echo status helpers (gum when on PATH + interactive; else plain echo).
# Installing gum is install.sh's job (install_gum); here we only detect + use it. ---
if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then _HAVE_GUM=1; else _HAVE_GUM=0; fi
info() { if [ "$_HAVE_GUM" = 1 ]; then CI=1 gum log --level info  -- "$*"; else echo "[INFO] $*"; fi; }
ok()   { if [ "$_HAVE_GUM" = 1 ]; then CI=1 gum log --level info  -- "$*"; else echo "[OK]   $*"; fi; }
warn() { if [ "$_HAVE_GUM" = 1 ]; then CI=1 gum log --level warn  -- "$*" >&2; else echo "[!]    $*" >&2; fi; }
err()  { if [ "$_HAVE_GUM" = 1 ]; then CI=1 gum log --level error -- "$*" >&2; else echo "[ERR]  $*" >&2; fi; }

if [[ $# -ne 3 ]]; then
    err "Usage: $0 <DOMAIN> <GATEWAY_IP> <UNPUBLISHED_GENERATION>"
    exit 1
fi

DOMAIN="$1"
GATEWAY_IP="$2"
OUTPUT_DIR="$3"

valid_profile_domain() {
    local domain="$1"
    [[ ${#domain} -ge 1 && ${#domain} -le 253 \
       && "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_profile_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    [[ "${#octets[@]}" == 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" == 0 || "$octet" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

valid_profile_domain "$DOMAIN" \
    || { err "Invalid DoT profile domain."; exit 1; }
valid_profile_ipv4 "$GATEWAY_IP" \
    || { err "Invalid DoT profile gateway IPv4 address."; exit 1; }

PROFILE_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
PROFILE_SCRIPT_DIR="$(cd "$(dirname -- "$PROFILE_SCRIPT_PATH")" && pwd)"
PROFILE_CERT_ROLE_HELPERS_LOADED=0
if [[ "${FIVEGPN_UI_GENERATION_TEST_MODE:-0}" == 1 \
   && -f "$PROFILE_SCRIPT_DIR/ui-generation.sh" && ! -L "$PROFILE_SCRIPT_DIR/ui-generation.sh" ]]; then
    UI_GENERATION_HELPER="$PROFILE_SCRIPT_DIR/ui-generation.sh"
else
    UI_GENERATION_HELPER=/opt/5gpn/scripts/ui-generation.sh
fi
[[ -f "$UI_GENERATION_HELPER" && ! -L "$UI_GENERATION_HELPER" ]] \
    || { err "UI generation helper is missing or unsafe: $UI_GENERATION_HELPER"; exit 1; }
UI_GENERATION_HELPER_STATE=""
UI_GENERATION_HELPER_HASH_FD=""
UI_GENERATION_HELPER_SOURCE_FD=""
if [[ "$UI_GENERATION_HELPER" == /opt/5gpn/scripts/ui-generation.sh ]]; then
    UI_GENERATION_HELPER_DIR="$(dirname -- "$UI_GENERATION_HELPER")"
    [[ -d "$UI_GENERATION_HELPER_DIR" && ! -L "$UI_GENERATION_HELPER_DIR" \
       && "$(readlink -f -- "$UI_GENERATION_HELPER_DIR")" == "$UI_GENERATION_HELPER_DIR" \
       && "$(stat -c '%u:%g:%a' -- "$UI_GENERATION_HELPER_DIR" 2>/dev/null)" == 0:0:755 \
       && "$(readlink -f -- "$UI_GENERATION_HELPER")" == "$UI_GENERATION_HELPER" \
       && "$(stat -c '%u:%g:%a:%h' -- "$UI_GENERATION_HELPER" 2>/dev/null)" == 0:0:755:1 ]] \
        || { err "Installed UI generation helper metadata is unsafe."; exit 1; }
    UI_GENERATION_HELPER_STATE="$(
        printf '%s:' "$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$UI_GENERATION_HELPER")"
        sha256sum -- "$UI_GENERATION_HELPER" | awk '{print $1}'
    )" || { err "Could not bind the installed UI generation helper."; exit 1; }
    exec {UI_GENERATION_HELPER_HASH_FD}<"$UI_GENERATION_HELPER" \
        || { err "Could not anchor the installed UI generation helper."; exit 1; }
    exec {UI_GENERATION_HELPER_SOURCE_FD}<"$UI_GENERATION_HELPER" \
        || { exec {UI_GENERATION_HELPER_HASH_FD}<&-; exit 1; }
    UI_GENERATION_HELPER_HASH_STATE="$(
        stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$UI_GENERATION_HELPER_HASH_FD"
    )" || { exec {UI_GENERATION_HELPER_HASH_FD}<&-; exec {UI_GENERATION_HELPER_SOURCE_FD}<&-; exit 1; }
    UI_GENERATION_HELPER_SOURCE_STATE="$(
        stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$UI_GENERATION_HELPER_SOURCE_FD"
    )" || { exec {UI_GENERATION_HELPER_HASH_FD}<&-; exec {UI_GENERATION_HELPER_SOURCE_FD}<&-; exit 1; }
    [[ "$UI_GENERATION_HELPER_HASH_STATE" == "${UI_GENERATION_HELPER_STATE%:*}" \
       && "$UI_GENERATION_HELPER_SOURCE_STATE" == "${UI_GENERATION_HELPER_STATE%:*}" ]] \
        || { exec {UI_GENERATION_HELPER_HASH_FD}<&-; exec {UI_GENERATION_HELPER_SOURCE_FD}<&-; err "Installed UI generation helper changed while it was anchored."; exit 1; }
    UI_GENERATION_HELPER_FD_DIGEST="$(
        sha256sum -- "/proc/self/fd/$UI_GENERATION_HELPER_HASH_FD" | awk '{print $1}'
    )" || { exec {UI_GENERATION_HELPER_HASH_FD}<&-; exec {UI_GENERATION_HELPER_SOURCE_FD}<&-; exit 1; }
    exec {UI_GENERATION_HELPER_HASH_FD}<&-
    [[ "$UI_GENERATION_HELPER_FD_DIGEST" == "${UI_GENERATION_HELPER_STATE##*:}" ]] \
        || { exec {UI_GENERATION_HELPER_SOURCE_FD}<&-; err "Installed UI generation helper bytes differ from the anchored path."; exit 1; }
fi
# shellcheck source=scripts/ui-generation.sh
if [[ -n "$UI_GENERATION_HELPER_SOURCE_FD" ]]; then
    source "/proc/self/fd/$UI_GENERATION_HELPER_SOURCE_FD" \
        || { exec {UI_GENERATION_HELPER_SOURCE_FD}<&-; exit 1; }
    exec {UI_GENERATION_HELPER_SOURCE_FD}<&-
else
    source "$UI_GENERATION_HELPER"
fi
if [[ -n "$UI_GENERATION_HELPER_STATE" ]]; then
    UI_GENERATION_HELPER_STATE_AFTER="$(
        printf '%s:' "$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$UI_GENERATION_HELPER")"
        sha256sum -- "$UI_GENERATION_HELPER" | awk '{print $1}'
    )" || { err "Could not revalidate the installed UI generation helper."; exit 1; }
    [[ "$UI_GENERATION_HELPER_STATE_AFTER" == "$UI_GENERATION_HELPER_STATE" ]] \
        || { err "Installed UI generation helper changed while it was loaded."; exit 1; }
fi

PROFILE_UI_ROOT="$UI_GENERATION_ROOT"
if [[ "${FIVEGPN_UI_GENERATION_TEST_MODE:-0}" == 1 ]]; then
    [[ "$PROFILE_SCRIPT_PATH" != /opt/5gpn/scripts/gen-ios-profile.sh ]] \
        || { err "The installed profile generator does not accept a test root."; exit 1; }
    PROFILE_UI_ROOT="${FIVEGPN_UI_GENERATION_TEST_ROOT:-}"
    case "$PROFILE_UI_ROOT" in
        /tmp/5gpn-ui-test.*|/var/tmp/5gpn-ui-test.*) ;;
        *) err "Invalid explicit UI generation test root."; exit 1 ;;
    esac
fi

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || uuidgen
}

PAYLOAD_UUID="$(gen_uuid)"
TOP_UUID="$(gen_uuid)"

[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] \
    || { err "Unsafe or missing unpublished iOS profile generation: $OUTPUT_DIR"; exit 1; }
OUTPUT_DIR="$(readlink -f -- "$OUTPUT_DIR" 2>/dev/null)" \
    || { err "Could not canonicalize the unpublished iOS profile generation."; exit 1; }
ui_generation_candidate_is_safe "$PROFILE_UI_ROOT" "$OUTPUT_DIR" \
    || { err "Refusing a path that is not a validated unpublished UI generation: $OUTPUT_DIR"; exit 1; }

# Both payloads are completed in one private, same-filesystem staging directory.
# Nothing under the public filenames changes until both CMS signatures exist.
stage_dir="$(mktemp -d "${OUTPUT_DIR}/.ios-profile.XXXXXX")" \
    || { err "Could not create the iOS profile staging directory."; exit 1; }
chmod 0700 "$stage_dir" \
    || { rmdir -- "$stage_dir" 2>/dev/null || true; exit 1; }
profile_path="${OUTPUT_DIR}/ios-dot.mobileconfig"
intercept_profile_path="${OUTPUT_DIR}/ios-intercept-ca.mobileconfig"
staged_profile="${stage_dir}/ios-dot.mobileconfig"
unsigned_profile="${stage_dir}/ios-dot.mobileconfig.unsigned"
staged_intercept_profile="${stage_dir}/ios-intercept-ca.mobileconfig"
unsigned_intercept_profile="${stage_dir}/ios-intercept-ca.mobileconfig.unsigned"
chain_path="${stage_dir}/signing-chain.pem"
verified_profile="${stage_dir}/ios-dot.mobileconfig.verified"
verified_intercept_profile="${stage_dir}/ios-intercept-ca.mobileconfig.verified"
embedded_intercept_ca="${stage_dir}/intercept-ca.der"
staged_profile_inputs="${stage_dir}/.5gpn-profile-inputs"
profile_inputs_path="${OUTPUT_DIR}/.5gpn-profile-inputs"
signing_fullchain="${stage_dir}/signing-fullchain.pem"
signing_privkey="${stage_dir}/signing-privkey.pem"
signing_intercept_ca="${stage_dir}/signing-intercept-ca.crt"

cleanup_profile_stage() {
    local rc=0
    rm -f -- \
        "$staged_profile" "$unsigned_profile" \
        "$staged_intercept_profile" "$unsigned_intercept_profile" \
        "$chain_path" "$verified_profile" "$verified_intercept_profile" \
        "$embedded_intercept_ca" "$staged_profile_inputs" \
        "$signing_fullchain" "$signing_privkey" "$signing_intercept_ca" \
        2>/dev/null || rc=1
    rmdir -- "$stage_dir" 2>/dev/null || rc=1
    [[ "$rc" == 0 ]]
}

profile_script_exit() {
    local rc=$?
    trap - EXIT
    trap '' HUP INT TERM
    if ! cleanup_profile_stage; then
        err "Could not clean private profile-signing material from the unpublished generation." || true
        rc=1
    fi
    exit "$rc"
}

profile_script_signal() {
    local signal_name="$1" signal_status="$2"
    err "Interrupted by ${signal_name} during iOS profile generation." || true
    exit "$signal_status"
}

trap profile_script_exit EXIT
trap 'profile_script_signal HUP 129' HUP
trap 'profile_script_signal INT 130' INT
trap 'profile_script_signal TERM 143' TERM

profile_input_file_state() {
    local path="$1" metadata digest
    [[ -f "$path" && ! -L "$path" \
       && "$(stat -c %h -- "$path" 2>/dev/null || true)" == 1 ]] || return 1
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$path" 2>/dev/null)" \
        || return 1
    digest="$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s:%s\n' "$metadata" "$digest"
}

profile_signing_snapshot() {
    local dot_target current_state cert_state key_state ca_state
    load_profile_cert_role_helpers || return 1
    [[ "$CERT_DIR" == "$DOT_CERT_ROLE/current" ]] || return 1
    dot_target="$(cert_role_ctl_current_target dot 0)" || return 1
    current_state="$(stat -c '%d:%i:%s:%y:%z:%u:%g:%a:%h' -- "$CERT_DIR" 2>/dev/null)" \
        || return 1
    cert_state="$(profile_input_file_state "$CERT_DIR/fullchain.pem")" || return 1
    key_state="$(profile_input_file_state "$CERT_DIR/privkey.pem")" || return 1
    ca_state="$(profile_input_file_state "$INTERCEPT_CA")" || return 1
    printf '%s|%s|%s|%s|%s\n' \
        "$dot_target" "$current_state" "$cert_state" "$key_state" "$ca_state"
}

profile_expected_root_uid() {
    [[ "$DOT_CERT_ROLE" == /etc/5gpn/cert/dot ]] && printf '0\n' || printf '%s\n' "${EUID:-$(id -u)}"
}

profile_expected_root_gid() {
    [[ "$DOT_CERT_ROLE" == /etc/5gpn/cert/dot ]] && printf '0\n' || id -g
}

profile_expected_role_gid() {
    local entry gid
    if [[ "$DOT_CERT_ROLE" != /etc/5gpn/cert/dot ]]; then
        id -g
        return
    fi
    entry="$(getent group fivegpn 2>/dev/null)" || return 1
    gid="$(printf '%s\n' "$entry" | cut -d: -f3)"
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$gid"
}

cert_role_ctl_group_gid_override() {
    profile_expected_role_gid
}

profile_cert_helper_state() {
    local path="$1" production="$2" parent metadata digest
    [[ -f "$path" && ! -L "$path" \
       && "$(stat -c %h -- "$path" 2>/dev/null)" == 1 ]] || return 1
    if [[ "$path" == "$production" ]]; then
        parent="$(dirname -- "$production")"
        [[ -d "$parent" && ! -L "$parent" \
           && "$(readlink -f -- "$parent")" == "$parent" \
           && "$(stat -Lc '%u:%g:%a' -- "$parent")" == 0:0:755 \
           && "$(stat -Lc '%u:%g:%a:%h' -- "$path")" == 0:0:755:1 ]] || return 1
    fi
    metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "$path")" || return 1
    digest="$(sha256sum -- "$path" | awk '{print $1}')" || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s:%s\n' "$metadata" "$digest"
}

load_profile_cert_role_helpers() {
    local helper path production before after hash_fd source_fd hash_metadata source_metadata fd_digest
    local -a helpers=(publication-fs.sh cert-role-ctl.sh)
    if [[ "$PROFILE_CERT_ROLE_HELPERS_LOADED" != 1 ]]; then
        for helper in "${helpers[@]}"; do
            production="/opt/5gpn/scripts/$helper"
            if [[ "${FIVEGPN_UI_GENERATION_TEST_MODE:-0}" == 1 \
               && -f "$PROFILE_SCRIPT_DIR/$helper" && ! -L "$PROFILE_SCRIPT_DIR/$helper" ]]; then
                path="$PROFILE_SCRIPT_DIR/$helper"
            else
                path="$production"
            fi
            before="$(profile_cert_helper_state "$path" "$production")" || return 1
            exec {hash_fd}<"$path" || return 1
            exec {source_fd}<"$path" || { exec {hash_fd}<&-; return 1; }
            hash_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$hash_fd")" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            source_metadata="$(stat -Lc '%d:%i:%s:%Y:%Z:%u:%g:%a:%h' -- "/proc/self/fd/$source_fd")" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            fd_digest="$(sha256sum -- "/proc/self/fd/$hash_fd" | awk '{print $1}')" \
                || { exec {hash_fd}<&-; exec {source_fd}<&-; return 1; }
            exec {hash_fd}<&-
            [[ "$hash_metadata" == "${before%:*}" \
               && "$source_metadata" == "${before%:*}" \
               && "$fd_digest" == "${before##*:}" ]] \
                || { exec {source_fd}<&-; return 1; }
            # shellcheck source=/dev/null
            source "/proc/self/fd/$source_fd" || { exec {source_fd}<&-; return 1; }
            exec {source_fd}<&-
            after="$(profile_cert_helper_state "$path" "$production")" || return 1
            [[ "$after" == "$before" ]] || return 1
        done
        declare -F publication_fs_commit_relative_pointer >/dev/null 2>&1 \
            && [[ "${CERT_ROLE_CTL_API_VERSION:-0}" == 1 ]] || return 1
        PROFILE_CERT_ROLE_HELPERS_LOADED=1
    fi
    CERT_ROLE_CTL_ROOT="$(dirname -- "$DOT_CERT_ROLE")"
    CERT_ROLE_CTL_CONFIG_MARKER=.5gpn-owned
    CERT_ROLE_CTL_CONFIG_MARKER_VALUE=5gpn-config
    CERT_ROLE_CTL_ROOT_MARKER=.5gpn-cert-root-owned
    CERT_ROLE_CTL_ROOT_MARKER_VALUE=5gpn-cert-root-v1
    CERT_ROLE_CTL_ROLE_MARKER=.5gpn-cert-role-owned
    CERT_ROLE_CTL_ROLE_VALUE_PREFIX=5gpn-cert-role-v1
    CERT_ROLE_CTL_SERVICE_GROUP=fivegpn
    CERT_ROLE_CTL_SERVICE_GID=""
    CERT_ROLE_CTL_ALLOW_CREATE=0
    CERT_ROLE_CTL_ADDITIONAL_GIDS=""
    if [[ "${FIVEGPN_UI_GENERATION_TEST_MODE:-0}" == 1 \
       && "$CERT_ROLE_CTL_ROOT" != /etc/5gpn/cert ]]; then
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=1
        CERT_ROLE_CTL_STAGE_PARENT="$(dirname -- "$CERT_ROLE_CTL_ROOT")/.cert-role-staging"
    else
        CERT_ROLE_CTL_ALLOW_TEST_ROOT=0
        CERT_ROLE_CTL_STAGE_PARENT=/run/5gpn
    fi
}

profile_plain_file_is_safe() {
    local path="$1" uid="$2" gid="$3" mode="$4"
    [[ -f "$path" && ! -L "$path" \
       && "$(stat -c %u -- "$path" 2>/dev/null)" == "$uid" \
       && "$(stat -c %g -- "$path" 2>/dev/null)" == "$gid" \
       && "$(stat -c %a -- "$path" 2>/dev/null)" == "$mode" \
       && "$(stat -c %h -- "$path" 2>/dev/null)" == 1 ]]
}

profile_no_nested_mounts() {
    local root="$1" target output
    command -v findmnt >/dev/null 2>&1 || return 1
    output="$(findmnt -R -r -n -o TARGET --target "$root" 2>/dev/null)" || return 1
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        case "$target" in "$root"/*) return 1 ;; esac
    done <<< "$output"
}

profile_certificate_time_is_valid() {
    local cert="$1" not_before not_before_epoch now_epoch
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
    not_before="$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null)" || return 1
    not_before="${not_before#notBefore=}"
    not_before_epoch="$(date -u -d "$not_before" +%s 2>/dev/null)" || return 1
    now_epoch="$(date -u +%s)" || return 1
    [[ "$not_before_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ \
       && "$not_before_epoch" -le "$now_epoch" ]]
}

profile_cert_pair_is_valid() {
    local cert="$1" key="$2" cert_pub key_pub
    # OpenSSL 3.0's `x509 -checkhost` prints a mismatch but still exits zero.
    # `verify` provides a stable status while the explicit partial trust keeps
    # this hostname check independent of the host CA store and an omitted root.
    profile_certificate_time_is_valid "$cert" \
        && openssl verify -verify_hostname "$DOMAIN" -partial_chain \
            -trusted "$cert" "$cert" >/dev/null 2>&1 \
        || return 1
    cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

profile_dot_role_boundary_is_safe() {
    load_profile_cert_role_helpers || return 1
    cert_role_ctl_validate_current_role dot \
        && profile_cert_pair_is_valid "$DOT_CERT_ROLE/current/fullchain.pem" \
            "$DOT_CERT_ROLE/current/privkey.pem"
}

profile_intercept_ca_boundary_is_safe() {
    local root_uid root_gid marker
    root_uid="$(profile_expected_root_uid)" || return 1
    root_gid="$(profile_expected_root_gid)" || return 1
    [[ -d "$INTERCEPT_CA_ROOT" && ! -L "$INTERCEPT_CA_ROOT" \
       && "$(readlink -f -- "$INTERCEPT_CA_ROOT")" == "$INTERCEPT_CA_ROOT" \
       && "$(stat -c %u -- "$INTERCEPT_CA_ROOT")" == "$root_uid" \
       && "$(stat -c %g -- "$INTERCEPT_CA_ROOT")" == "$root_gid" \
       && ( "$(stat -c %a -- "$INTERCEPT_CA_ROOT")" == 700 \
            || "$(stat -c %a -- "$INTERCEPT_CA_ROOT")" == 755 ) ]] || return 1
    profile_no_nested_mounts "$INTERCEPT_CA_ROOT" || return 1
    marker="$INTERCEPT_CA_ROOT/.5gpn-intercept-ca-owned"
    profile_plain_file_is_safe "$marker" "$root_uid" "$root_gid" 644 \
        && [[ "$(cat "$marker")" == 5gpn-intercept-ca-v1 ]] || return 1
    profile_plain_file_is_safe "$INTERCEPT_CA" "$root_uid" "$root_gid" 644 || return 1
    profile_certificate_time_is_valid "$INTERCEPT_CA" \
        && openssl x509 -in "$INTERCEPT_CA" -noout -text 2>/dev/null | grep -Fq 'CA:TRUE' \
        && openssl verify -CAfile "$INTERCEPT_CA" "$INTERCEPT_CA" >/dev/null 2>&1
}

profile_live_boundaries_are_safe() {
    profile_dot_role_boundary_is_safe && profile_intercept_ca_boundary_is_safe
}

cat > "$unsigned_profile" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>DNSSettings</key>
            <dict>
                <key>DNSProtocol</key>
                <string>TLS</string>
                <key>ServerName</key>
                <string>${DOMAIN}</string>
                <key>ServerAddresses</key>
                <array>
                    <string>${GATEWAY_IP}</string>
                </array>
            </dict>
            <key>OnDemandRules</key>
            <array>
                <dict>
                    <key>Action</key>
                    <string>Connect</string>
                    <key>InterfaceTypeMatch</key>
                    <string>Cellular</string>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Disconnect</string>
                    <key>InterfaceTypeMatch</key>
                    <string>WiFi</string>
                </dict>
                <dict>
                    <key>Action</key>
                    <string>Disconnect</string>
                </dict>
            </array>
            <key>PayloadDescription</key>
            <string>Use ${DOMAIN} DNS over TLS only on cellular networks.</string>
            <key>PayloadDisplayName</key>
            <string>5gpn Cellular DoT</string>
            <key>PayloadIdentifier</key>
            <string>com.5gpn.${DOMAIN}.dnssettings</string>
            <key>PayloadType</key>
            <string>com.apple.dnsSettings.managed</string>
            <key>PayloadUUID</key>
            <string>${PAYLOAD_UUID}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs a DNS over TLS profile for cellular networks only.</string>
    <key>PayloadDisplayName</key>
    <string>5gpn Cellular DoT</string>
    <key>PayloadIdentifier</key>
    <string>com.5gpn.${DOMAIN}</string>
    <key>PayloadOrganization</key>
    <string>5gpn</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>${TOP_UUID}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

# Sign the .mobileconfig with the deployment's Let's Encrypt cert so iOS shows a
# "Verified" profile and REJECTS any in-flight tampering — the delivery is over
# the network, so an on-path attacker could otherwise
# rewrite ServerName/ServerAddresses and persistently hijack the phone's cellular
# DNS. If signing is impossible (no cert / openssl), the staged unsigned profile
# is refused while the caller leaves the last-known-good current generation
# untouched. Caller-environment overrides are not a configuration surface.
DOT_CERT_ROLE="/etc/5gpn/cert/dot"
INTERCEPT_CA_ROOT="/etc/5gpn/intercept-ca"
if [[ "${FIVEGPN_UI_GENERATION_TEST_MODE:-0}" == 1 ]]; then
    DOT_CERT_ROLE="${FIVEGPN_PROFILE_TEST_DOT_ROLE:-}"
    INTERCEPT_CA_ROOT="${FIVEGPN_PROFILE_TEST_CA_ROOT:-}"
    case "$DOT_CERT_ROLE" in /tmp/5gpn-ui-test.*|/var/tmp/5gpn-ui-test.*) ;; *) exit 1 ;; esac
    case "$INTERCEPT_CA_ROOT" in /tmp/5gpn-ui-test.*|/var/tmp/5gpn-ui-test.*) ;; *) exit 1 ;; esac
fi
CERT_DIR="${DOT_CERT_ROLE}/current"
INTERCEPT_CA="${INTERCEPT_CA_ROOT}/root.crt"
profile_live_boundaries_are_safe \
    || { err "DoT certificate role or interception CA boundary is unsafe."; exit 1; }
if ! command -v openssl >/dev/null 2>&1 \
   || [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
    warn "No cert at ${CERT_DIR} (or openssl missing)."
    err "Refusing to serve an UNSIGNED .mobileconfig. Repair the configured certificate and rerun the TUI profile action."
    exit 1
fi
if [[ ! -f "$INTERCEPT_CA" || -L "$INTERCEPT_CA" ]]; then
    err "Dedicated interception CA is missing or unsafe: $INTERCEPT_CA"
    exit 1
fi
PROFILE_SIGNING_SNAPSHOT="$(profile_signing_snapshot)" \
    || { err "Could not bind the certificate inputs used for profile signing."; exit 1; }
IFS='|' read -r PROFILE_DOT_TARGET PROFILE_CURRENT_STATE PROFILE_CERT_STATE PROFILE_KEY_STATE PROFILE_CA_STATE \
    <<< "$PROFILE_SIGNING_SNAPSHOT"
install -m 0600 -- "$CERT_DIR/fullchain.pem" "$signing_fullchain" \
    && install -m 0600 -- "$CERT_DIR/privkey.pem" "$signing_privkey" \
    && install -m 0600 -- "$INTERCEPT_CA" "$signing_intercept_ca" \
    || { err "Could not create the private immutable signing snapshot."; exit 1; }
[[ "$(sha256sum "$signing_fullchain" | awk '{print $1}')" == "${PROFILE_CERT_STATE##*:}" \
   && "$(sha256sum "$signing_privkey" | awk '{print $1}')" == "${PROFILE_KEY_STATE##*:}" \
   && "$(sha256sum "$signing_intercept_ca" | awk '{print $1}')" == "${PROFILE_CA_STATE##*:}" ]] \
    || { err "Signing inputs changed while their private snapshot was captured."; exit 1; }
profile_cert_pair_is_valid "$signing_fullchain" "$signing_privkey" \
    || { err "Private DoT signing snapshot failed certificate/key validation."; exit 1; }
profile_certificate_time_is_valid "$signing_intercept_ca" \
    && openssl x509 -in "$signing_intercept_ca" -noout -text 2>/dev/null | grep -Fq 'CA:TRUE' \
    && openssl verify -CAfile "$signing_intercept_ca" "$signing_intercept_ca" >/dev/null 2>&1 \
    || { err "Private interception CA snapshot is not a valid CA."; exit 1; }
INTERCEPT_CA_DER_SHA256="$(
    openssl x509 -in "$signing_intercept_ca" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
)" || { err "Could not fingerprint the interception CA payload."; exit 1; }
[[ "$INTERCEPT_CA_DER_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || { err "Could not fingerprint the interception CA payload."; exit 1; }

# Every non-leaf cert in fullchain.pem must ride along in the CMS signature:
# LE's Gen-Y chain (leaf ← YE2 ← Root YE ← cross-signed X2 ← X1) only
# reaches an anchor iOS actually trusts via the cross-certs. Only the leaf is
# dropped here because -signer already embeds it.
awk '/-----BEGIN CERTIFICATE-----/{n++} n>=2' \
    "$signing_fullchain" > "$chain_path"
certfile_args=()
[[ -s "$chain_path" ]] && certfile_args=(-certfile "$chain_path")
if ! openssl smime -sign -binary -nodetach -outform der \
    -signer "$signing_fullchain" -inkey "$signing_privkey" \
    "${certfile_args[@]}" \
    -in "$unsigned_profile" -out "$staged_profile" 2>/dev/null; then
    err "Refusing to serve an UNSIGNED .mobileconfig. Repair the configured certificate and rerun the TUI profile action."
    exit 1
fi
chmod 0644 "$staged_profile"

[[ "$(profile_signing_snapshot)" == "$PROFILE_SIGNING_SNAPSHOT" ]] \
    || { err "Certificate inputs changed while the DoT profile was signed."; exit 1; }

# Generate a separate, explicitly removable profile for the shared modular
# interception root. Keeping this payload separate from the cellular DoT profile
# lets an operator revoke interception trust without changing DNS enrollment.
INTERCEPT_PAYLOAD_UUID="$(gen_uuid)"
INTERCEPT_TOP_UUID="$(gen_uuid)"
INTERCEPT_CA_DER_BASE64="$(
    openssl x509 -in "$signing_intercept_ca" -outform DER 2>/dev/null | openssl base64 -A
)"
[[ -n "$INTERCEPT_CA_DER_BASE64" ]] || { err "Could not encode the interception CA."; exit 1; }
cat > "$unsigned_intercept_profile" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadContent</key>
            <data>${INTERCEPT_CA_DER_BASE64}</data>
            <key>PayloadDescription</key>
            <string>Trusts the shared root used by all enabled 5gpn modular interception hosts.</string>
            <key>PayloadDisplayName</key>
            <string>5gpn Interception CA</string>
            <key>PayloadIdentifier</key>
            <string>com.5gpn.interception.ca</string>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadUUID</key>
            <string>${INTERCEPT_PAYLOAD_UUID}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs the opt-in shared root used by explicitly enabled 5gpn interception modules.</string>
    <key>PayloadDisplayName</key>
    <string>5gpn Interception Trust</string>
    <key>PayloadIdentifier</key>
    <string>com.5gpn.interception</string>
    <key>PayloadOrganization</key>
    <string>5gpn</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>${INTERCEPT_TOP_UUID}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

if ! openssl smime -sign -binary -nodetach -outform der \
    -signer "$signing_fullchain" -inkey "$signing_privkey" \
    "${certfile_args[@]}" \
    -in "$unsigned_intercept_profile" -out "$staged_intercept_profile" 2>/dev/null; then
    err "Refusing to serve an unsigned interception CA profile."
    exit 1
fi
chmod 0644 "$staged_intercept_profile"

[[ "$(profile_signing_snapshot)" == "$PROFILE_SIGNING_SNAPSHOT" ]] \
    || { err "Certificate inputs changed while both profiles were signed."; exit 1; }

if ! openssl smime -verify -binary -inform der -noverify \
        -in "$staged_profile" -out "$verified_profile" >/dev/null 2>&1 \
   || ! cmp -s -- "$unsigned_profile" "$verified_profile" \
   || ! grep -Fq "<string>${DOMAIN}</string>" "$verified_profile" \
   || ! grep -Fq "<string>${GATEWAY_IP}</string>" "$verified_profile"; then
    err "The signed DoT profile did not verify to the requested domain and gateway payload."
    exit 1
fi
if ! openssl smime -verify -binary -inform der -noverify \
        -in "$staged_intercept_profile" -out "$verified_intercept_profile" >/dev/null 2>&1 \
   || ! cmp -s -- "$unsigned_intercept_profile" "$verified_intercept_profile"; then
    err "The signed interception profile did not verify to its staged payload."
    exit 1
fi
embedded_base64="$(
    sed -n 's|^[[:space:]]*<data>\([^<]*\)</data>[[:space:]]*$|\1|p' \
        "$verified_intercept_profile"
)"
[[ -n "$embedded_base64" && "$embedded_base64" != *$'\n'* ]] \
    || { err "The verified interception profile has no unique embedded CA payload."; exit 1; }
if ! printf '%s' "$embedded_base64" | openssl base64 -d -A > "$embedded_intercept_ca" \
   || [[ "$(sha256sum -- "$embedded_intercept_ca" | awk '{print $1}')" \
        != "$INTERCEPT_CA_DER_SHA256" ]]; then
    err "The verified interception profile does not embed the bound interception CA."
    exit 1
fi

[[ "$(profile_signing_snapshot)" == "$PROFILE_SIGNING_SNAPSHOT" ]] \
    || { err "Certificate inputs changed before candidate profile publication."; exit 1; }

DOT_LEAF_SHA256="$(
    openssl x509 -in "$signing_fullchain" -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}'
)" || { err "Could not fingerprint the bound DoT signer leaf."; exit 1; }
DOT_PUBLIC_KEY_SHA256="$(
    openssl x509 -in "$signing_fullchain" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}'
)" || { err "Could not fingerprint the bound DoT public key."; exit 1; }
IOS_DOT_SHA256="$(sha256sum -- "$staged_profile" | awk '{print $1}')" || exit 1
IOS_INTERCEPT_SHA256="$(sha256sum -- "$staged_intercept_profile" | awk '{print $1}')" || exit 1
for digest in "$DOT_LEAF_SHA256" "$DOT_PUBLIC_KEY_SHA256" \
              "$INTERCEPT_CA_DER_SHA256" "$IOS_DOT_SHA256" "$IOS_INTERCEPT_SHA256"; do
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
        || { err "Could not build the exact profile-input manifest."; exit 1; }
done
cat > "$staged_profile_inputs" <<EOF
version=1
dot_signer_leaf_sha256=${DOT_LEAF_SHA256}
dot_public_key_sha256=${DOT_PUBLIC_KEY_SHA256}
intercept_ca_der_sha256=${INTERCEPT_CA_DER_SHA256}
domain=${DOMAIN}
gateway_ipv4=${GATEWAY_IP}
ios_dot_sha256=${IOS_DOT_SHA256}
ios_intercept_ca_sha256=${IOS_INTERCEPT_SHA256}
EOF
chmod 0644 "$staged_profile_inputs"

profile_live_boundaries_are_safe \
    && [[ "$(profile_signing_snapshot)" == "$PROFILE_SIGNING_SNAPSHOT" ]] \
    || { err "Certificate inputs changed while the profile-input manifest was finalized."; exit 1; }

# Existing files are permitted only inside the unpublished cloned candidate.
# They must be singly linked so replacing them cannot mutate another generation.
for live_path in "$profile_path" "$intercept_profile_path" "$profile_inputs_path"; do
    if [[ -e "$live_path" || -L "$live_path" ]]; then
        [[ -f "$live_path" && ! -L "$live_path" \
           && "$(stat -c %h -- "$live_path" 2>/dev/null || true)" == 1 ]] \
            || { err "Unsafe existing candidate profile: $live_path"; exit 1; }
    fi
done

# These renames modify only the unpublished candidate. The caller validates
# the complete generation and performs the single live `current` symlink swap.
if ! mv -Tf -- "$staged_profile" "$profile_path"; then
    err "Could not place the signed iOS profile in the unpublished generation."
    exit 1
fi
if ! mv -Tf -- "$staged_intercept_profile" "$intercept_profile_path"; then
    err "Could not place both signed profiles in the unpublished generation."
    exit 1
fi
if ! mv -Tf -- "$staged_profile_inputs" "$profile_inputs_path"; then
    err "Could not place the bound profile-input manifest in the unpublished generation."
    exit 1
fi

ok "Signed both profiles inside unpublished generation ${OUTPUT_DIR}."
