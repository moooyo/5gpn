#!/usr/bin/env bash
# Runs inside the candidate as fivegpn. It holds the trusted certificate lock,
# temporarily publishes a valid role generation, proves both DoT and controller
# listeners load it without replacing PID 1, then restores and removes it.
set -Eeuo pipefail
export LC_ALL=C

probe_error() {
    local rc=$?
    printf 'Public-certificate probe failed at line %s (status %s): %s\n' \
        "${BASH_LINENO[0]}" "$rc" "$BASH_COMMAND" >&2
    return "$rc"
}
trap probe_error ERR

[[ "${FIVEGPN_ACCEPTANCE_INTERNAL:-}" == 5gpn-container-acceptance-v1 ]] \
    || { echo 'public-certificate-hot-reload.sh is not standalone' >&2; exit 2; }
[[ "$EUID" == 10001 && "$(id -g)" == 10001 ]] \
    || { echo 'public certificate probe requires fivegpn UID:GID 10001:10001' >&2; exit 1; }

for command in awk date flock install openssl readlink sed seq sha256sum sync timeout; do
    command -v "$command" >/dev/null 2>&1 \
        || { echo "missing container probe command: $command" >&2; exit 1; }
done

base="$(sed -n 's/^DNS_BASE_DOMAIN=//p' /etc/5gpn/dns.env)"
[[ "$base" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
    || { echo 'container DNS_BASE_DOMAIN is invalid' >&2; exit 1; }
dot_host="dot.${base}"
console_host="console.${base}"
stage="$(mktemp -d /tmp/5gpn-public-hot.XXXXXX)"
chmod 0700 "$stage"
generation="generation-$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}-${RANDOM}"
dot_old=''
console_old=''
transaction_started=false

served_serial() {
    local port="$1" name="$2" output serial
    output="$(timeout 8 openssl s_client -connect "127.0.0.1:${port}" \
        -servername "$name" -showcerts </dev/null 2>/dev/null || true)"
    serial="$(openssl x509 -noout -serial <<<"$output" 2>/dev/null | sed -n 's/^serial=//p')"
    [[ "$serial" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    printf '%s\n' "${serial^^}"
}

restore_roles() {
    local role old root link path current
    [[ "$transaction_started" == true ]] || return 0
    for role in dot console; do
        root="/etc/5gpn/cert/${role}"
        old="$dot_old"
        [[ "$role" != console ]] || old="$console_old"
        [[ "$old" == generations/generation-* ]] || return 1
        current="$(readlink -- "$root/current")"
        if [[ "$current" == "generations/${generation}" ]]; then
            link="$root/.acceptance-restore.${BASHPID}.${RANDOM}"
            ln -s -- "$old" "$link"
            mv -Tf -- "$link" "$root/current"
            sync -f -- "$root"
        elif [[ "$current" != "$old" ]]; then
            return 1
        fi
    done
    for role in dot console; do
        path="/etc/5gpn/cert/${role}/generations/${generation}"
        [[ "$(readlink -- "/etc/5gpn/cert/${role}/current")" != "generations/${generation}" ]] \
            || return 1
        if [[ -e "$path" || -L "$path" ]]; then
            [[ -d "$path" && ! -L "$path" ]] || return 1
            rm -f -- "$path/fullchain.pem" "$path/privkey.pem"
            rmdir -- "$path"
        fi
        sync -f -- "/etc/5gpn/cert/${role}/generations"
    done
    transaction_started=false
}

cleanup() {
    local rc=$?
    trap - EXIT
    restore_roles || rc=1
    rm -rf -- "$stage" || rc=1
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

exec 9>/run/5gpn/cert-renew.lock
chmod 0600 /run/5gpn/cert-renew.lock
flock -w 30 9 \
    || { echo 'could not acquire the container certificate transaction lock' >&2; exit 1; }

pid1_start="$(awk '{print $22}' /proc/1/stat)"
[[ "$pid1_start" =~ ^[0-9]+$ ]] || { echo 'could not identify PID 1' >&2; exit 1; }
dot_before="$(served_serial 853 "$dot_host")"
console_before="$(served_serial 443 "$console_host")"
[[ "$dot_before" == "$console_before" ]] \
    || { echo 'dot and console did not start on one public lineage' >&2; exit 1; }

serial="$(openssl rand -hex 16)"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 90 \
    -set_serial "0x${serial}" \
    -subj "/CN=${base}" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
    -addext 'extendedKeyUsage=serverAuth' \
    -addext "subjectAltName=DNS:${base},DNS:*.${base}" \
    -keyout "$stage/privkey.pem" -out "$stage/fullchain.pem" >/dev/null 2>&1
chmod 0640 "$stage/fullchain.pem" "$stage/privkey.pem"
candidate_serial="$(openssl x509 -in "$stage/fullchain.pem" -noout -serial | sed -n 's/^serial=//p')"
candidate_serial="${candidate_serial^^}"
[[ "$candidate_serial" =~ ^[0-9A-F]+$ && "$candidate_serial" != "$dot_before" ]] \
    || { echo 'generated public-role fixture did not receive a distinct serial' >&2; exit 1; }

for role in dot console; do
    root="/etc/5gpn/cert/${role}"
    [[ -d "$root/generations" && ! -L "$root/generations" ]] \
        || { echo "unsafe $role role generation root" >&2; exit 1; }
    old="$(readlink -- "$root/current")"
    [[ "$old" == generations/generation-* \
       && -f "$root/$old/fullchain.pem" && -f "$root/$old/privkey.pem" ]] \
        || { echo "unsafe $role current role generation" >&2; exit 1; }
    [[ ! -e "$root/generations/$generation" \
       && ! -L "$root/generations/$generation" ]] \
        || { echo "refusing to reuse $role acceptance generation" >&2; exit 1; }
    if [[ "$role" == dot ]]; then dot_old="$old"; else console_old="$old"; fi
done
transaction_started=true
for role in dot console; do
    root="/etc/5gpn/cert/${role}"
    mkdir -- "$root/generations/$generation"
    chmod 0750 "$root/generations/$generation"
    install -m 0640 "$stage/fullchain.pem" "$root/generations/$generation/fullchain.pem"
    install -m 0640 "$stage/privkey.pem" "$root/generations/$generation/privkey.pem"
    sync -f -- "$root/generations/$generation/fullchain.pem"
    sync -f -- "$root/generations/$generation/privkey.pem"
    sync -f -- "$root/generations/$generation"
done
published_links=0
for role in dot console; do
    root="/etc/5gpn/cert/${role}"
    link="$root/.acceptance-current.${BASHPID}.${RANDOM}"
    ln -s -- "generations/${generation}" "$link"
    mv -Tf -- "$link" "$root/current"
    sync -f -- "$root"
    published_links=$((published_links + 1))
done
[[ "$published_links" == 2 ]]

dot_live=''
console_live=''
# The controller re-stats once per second. DoT deliberately caps certificate
# path I/O at once per minute, so a real generation switch needs a full minute
# window rather than a unit-test-scale poll.
for _ in $(seq 1 150); do
    dot_live="$(served_serial 853 "$dot_host" 2>/dev/null || true)"
    console_live="$(served_serial 443 "$console_host" 2>/dev/null || true)"
    [[ "$dot_live" == "$candidate_serial" && "$console_live" == "$candidate_serial" ]] && break
    sleep 0.5
done
[[ "$dot_live" == "$candidate_serial" && "$console_live" == "$candidate_serial" ]] \
    || { printf 'DoT/controller hot-load mismatch: expected=%s dot=%s console=%s\n' \
        "$candidate_serial" "${dot_live:-missing}" "${console_live:-missing}" >&2; exit 1; }
[[ "$(awk '{print $22}' /proc/1/stat)" == "$pid1_start" ]] \
    || { echo 'public certificate hot publication replaced PID 1' >&2; exit 1; }

restore_roles
dot_restored=''
console_restored=''
for _ in $(seq 1 150); do
    dot_restored="$(served_serial 853 "$dot_host" 2>/dev/null || true)"
    console_restored="$(served_serial 443 "$console_host" 2>/dev/null || true)"
    [[ "$dot_restored" == "$dot_before" && "$console_restored" == "$console_before" ]] && break
    sleep 0.5
done
[[ "$dot_restored" == "$dot_before" && "$console_restored" == "$console_before" ]] \
    || { echo 'public role listeners did not hot-restore the committed generation' >&2; exit 1; }
[[ "$(awk '{print $22}' /proc/1/stat)" == "$pid1_start" ]] \
    || { echo 'public certificate restore replaced PID 1' >&2; exit 1; }

rm -rf -- "$stage"
trap - EXIT
printf 'FIVEGPN_PROBE_PUBLIC_CERT_SERIAL=%s:%s\n' "$dot_before" "$candidate_serial"
printf 'FIVEGPN_PROBE_PUBLIC_CERT_PID1_START=%s\n' "$pid1_start"
