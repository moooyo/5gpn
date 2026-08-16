#!/usr/bin/env bash
# Read-only post-release acceptance for the installed monolith.
#
# Usage: acceptance.sh <expected-5gpn-release>
#
# The only writes attempted below are deliberately rejected authorization
# probes. A passing run does not change the interception revision or rule state.

set -uo pipefail

EXPECTED_RELEASE="${1:-}"
if [[ -z "$EXPECTED_RELEASE" ]]; then
    echo "usage: $0 <expected-5gpn-release>" >&2
    exit 2
fi

INSTALLER=/opt/5gpn/install.sh
MIHOMO=/opt/5gpn/bin/5gpn-mihomo
MIHOMO_CONF=/etc/5gpn/mihomo/config.yaml
CONTROLLER=https://127.0.0.1

PASS=0
FAIL=0
ok() { printf '  PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '        %s\n' "$*"; }

installed_value() {
    local key="$1"
    sed -n "s/^${key}=\"\([^\"]*\)\".*/\1/p" "$INSTALLER" | head -n 1
}

echo '== release and service health =='
if [[ -f "$INSTALLER" ]]; then
    release="$(installed_value RELEASE_TAG)"
    core_pin="$(installed_value MIHOMO_VERSION)"
    [[ "$release" == "$EXPECTED_RELEASE" ]] \
        && ok "installed release is $EXPECTED_RELEASE" \
        || bad "expected release $EXPECTED_RELEASE, found ${release:-<unknown>}"
else
    release=''
    core_pin=''
    bad "installed release metadata is missing at $INSTALLER"
fi

if [[ -x "$MIHOMO" ]]; then
    core_version="$($MIHOMO -v 2>/dev/null | head -n 1)"
    note "${core_version:-<no version>}"
    [[ -n "$core_pin" && "$core_version" == *"$core_pin"* ]] \
        && ok "mihomo matches the installed $core_pin pin" \
        || bad "mihomo does not match the installed ${core_pin:-<unknown>} pin"
else
    bad "mihomo binary is missing"
fi

[[ "$(systemctl is-active 5gpn-mihomo 2>/dev/null)" == active ]] \
    && ok '5gpn-mihomo is active' || bad '5gpn-mihomo is not active'
if [[ "$(systemctl show 5gpn-mihomo -p User --value 2>/dev/null)" == fivegpn ]] \
   && [[ "$(systemctl show 5gpn-mihomo -p Group --value 2>/dev/null)" == fivegpn ]]; then
    ok '5gpn-mihomo runs as the single fivegpn identity'
else
    bad '5gpn-mihomo does not run as fivegpn:fivegpn'
fi

fivegpn_passwd="$(getent passwd fivegpn 2>/dev/null || true)"
fivegpn_group="$(getent group fivegpn 2>/dev/null || true)"
if [[ -n "$fivegpn_passwd" && -n "$fivegpn_group" ]]; then
    IFS=: read -r account_name _ account_uid account_gid _ account_home account_shell \
        <<< "$fivegpn_passwd"
    IFS=: read -r group_name _ named_gid group_members <<< "$fivegpn_group"
    uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null)"
    gid_min="$(awk '$1 == "GID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null)"
    uid_min="${uid_min:-1000}"
    gid_min="${gid_min:-1000}"
    uid_users="$(getent passwd | awk -F: -v id="$account_uid" '$3 == id { print $1 }')"
    gid_groups="$(getent group | awk -F: -v id="$named_gid" '$3 == id { print $1 }')"
    primary_users="$(getent passwd | awk -F: -v id="$named_gid" '$4 == id { print $1 }')"
    account_groups="$(id -G fivegpn 2>/dev/null || true)"
    if [[ "$account_name" == fivegpn && "$group_name" == fivegpn \
       && "$account_uid" =~ ^[1-9][0-9]*$ && "$account_gid" =~ ^[1-9][0-9]*$ \
       && "$named_gid" =~ ^[1-9][0-9]*$ && "$uid_min" =~ ^[1-9][0-9]*$ \
       && "$gid_min" =~ ^[1-9][0-9]*$ && "$account_uid" -lt "$uid_min" \
       && "$account_gid" -lt "$gid_min" && "$account_gid" == "$named_gid" \
       && "$account_home" == /nonexistent && -z "$group_members" \
       && "$uid_users" == fivegpn && "$gid_groups" == fivegpn \
       && "$primary_users" == fivegpn && "$account_groups" == "$account_gid" \
       && "$(id -gn fivegpn 2>/dev/null)" == fivegpn \
       && ( "$account_shell" == */nologin || "$account_shell" == /bin/false ) ]]; then
        ok 'fivegpn is an exclusive system identity with no supplementary groups'
    else
        bad 'fivegpn account shape, numeric ownership, or group exclusivity is unsafe'
    fi
else
    bad 'fivegpn account or group is missing'
fi

state_owner_uid="$(id -u fivegpn 2>/dev/null || true)"
state_validation_rc=0
state_validation="$(timeout --kill-after=5s 30s "$MIHOMO" 5gpn-state validate \
    --owner-uid "$state_owner_uid" /etc/5gpn/mihomo/5gpn 2>/dev/null)" \
    || state_validation_rc=$?
if [[ "$state_validation_rc" == 0 \
   && "$(printf '%s\n' "$state_validation" | awk 'END { print NR }')" == 1 ]] \
   && jq -e '
        .status == "ok"
        and (.validated | type == "array")
        and (.missing | type == "array")
        and (((.validated + .missing) | sort)
            == ["bot.json","dns.json","intercept.json"])
        and (.validated | index("dns.json") != null)
    ' >/dev/null 2>&1 <<< "$state_validation"; then
    ok 'installed Core validates every present runtime document read-only'
else
    bad "installed Core state validator failed or returned malformed output (rc=$state_validation_rc)"
fi

# These names are unsupported footprints, never current compatibility aliases.
retired_unit_definition_exists() {
    local unit="$1" load_state fragment_path root
    local -a roots=(/etc/systemd/system.control /run/systemd/system.control \
                    /run/systemd/transient /run/systemd/generator.early \
                    /etc/systemd/system /etc/systemd/system.attached \
                    /run/systemd/system /run/systemd/system.attached \
                    /run/systemd/generator /usr/local/lib/systemd/system \
                    /usr/lib/systemd/system /lib/systemd/system \
                    /run/systemd/generator.late)
    load_state="$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)"
    fragment_path="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null || true)"
    [[ -n "$fragment_path" ]] && return 0
    [[ -n "$load_state" && "$load_state" != not-found ]] && return 0
    for root in "${roots[@]}"; do
        [[ -e "$root/$unit" || -L "$root/$unit" \
           || -e "$root/$unit.d" || -L "$root/$unit.d" ]] && return 0
    done
    return 1
}

for retired in mihomo.service 5gpn-dns.service 5gpn-intercept.service \
               5gpn-intercept-runtime.path 5gpn-journal@.service \
               5gpn-journal@5gpn-dns.service 5gpn-journal@mihomo.service; do
    retired_unit_definition_exists "$retired" \
        && bad "$retired still has a unit file, drop-in, generated definition, or loaded state" \
        || ok "$retired has no unit definition"
done
for retired_user in mihomo gpn-dns gpn-intercept; do
    getent passwd "$retired_user" >/dev/null \
        && bad "legacy account $retired_user still exists" \
        || ok "legacy account $retired_user is absent"
done
for retired_group in mihomo gpn-dns gpn-intercept 5gpn-overlay-ctl 5gpn-overlay-gen; do
    getent group "$retired_group" >/dev/null \
        && bad "legacy group $retired_group still exists" \
        || ok "legacy group $retired_group is absent"
done
[[ -d /etc/5gpn/mihomo/5gpn ]] \
    && ok '5gpn state directory exists' || bad '5gpn state directory is missing'
[[ ! -e /etc/5gpn/mihomo/gpn ]] \
    && ok 'legacy gpn state directory is absent' \
    || bad 'legacy gpn state directory still exists'

echo
echo '== controller authentication and documents =='
if [[ ! -f "$MIHOMO_CONF" ]]; then
    bad "mihomo config is missing"
    SECRET=''
else
    SECRET="$(sed -n -E "s/^secret:[[:space:]]*'?([^']*)'?.*/\1/p" "$MIHOMO_CONF" | head -n 1)"
    [[ -n "$SECRET" ]] && ok 'controller secret is configured' \
        || bad 'controller secret is missing'
fi

request() {
    curl --noproxy '*' -sk --max-time 30 \
        -H "Authorization: Bearer ${SECRET}" \
        -H 'Content-Type: application/json' "$@"
}

http_status() {
    curl --noproxy '*' -sk --max-time 30 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${SECRET}" \
        -H 'Content-Type: application/json' "$@"
}

unauth="$(curl --noproxy '*' -sk --max-time 30 -o /dev/null -w '%{http_code}' \
    "$CONTROLLER/5gpn/dns")"
[[ "$unauth" == 401 ]] && ok '/5gpn/dns rejects missing authentication' \
    || bad "/5gpn/dns returned $unauth without authentication"

ui="$(curl --noproxy '*' -sk --max-time 30 -o /dev/null -w '%{http_code}' \
    "$CONTROLLER/ui/")"
[[ "$ui" == 200 ]] && ok '/ui/ is available for bootstrap' \
    || bad "/ui/ returned $ui"

for profile in ios-dot.mobileconfig ios-intercept-ca.mobileconfig; do
    profile_probe="$(curl --noproxy '*' -sk --max-time 30 -o /dev/null \
        -w $'%{http_code}\t%{content_type}' \
        "$CONTROLLER/ui/$profile")"
    IFS=$'\t' read -r profile_code profile_content_type <<< "$profile_probe"
    profile_media_type="${profile_content_type%%;*}"
    profile_media_type="${profile_media_type#"${profile_media_type%%[![:space:]]*}"}"
    profile_media_type="${profile_media_type%"${profile_media_type##*[![:space:]]}"}"
    if [[ "$profile_code" == 200 \
       && "${profile_media_type,,}" == "application/x-apple-aspen-config" ]]; then
        ok "/ui/$profile is served as an Apple configuration profile"
    else
        bad "/ui/$profile returned HTTP ${profile_code:-none}, Content-Type '${profile_content_type:-<missing>}'"
    fi
done

dns="$(request "$CONTROLLER/5gpn/dns")"
interception="$(request "$CONTROLLER/5gpn/interception")"
bot="$(request "$CONTROLLER/5gpn/bot")"
for name in dns interception bot; do
    value="${!name}"
    if jq -e '.revision | type == "string" and length > 0' \
        >/dev/null 2>&1 <<<"$value"; then
        ok "$name document is readable"
    else
        bad "$name document is unavailable or malformed"
    fi
done

echo
echo '== fixed HTTP/3 boundary =='
revision="$(jq -r '.revision // empty' <<<"$interception")"
enabled="$(jq -r '.snapshot.enabled // false' <<<"$interception")"
http2="$(jq -r '.snapshot.http2 // false' <<<"$interception")"
if jq -e '.snapshot.http3 == false and (.snapshot.available_egress_groups | type == "array")' \
    >/dev/null 2>&1 <<<"$interception"; then
    ok 'snapshot reports http3=false and the narrow egress catalog'
else
    bad 'interception snapshot violates the fixed HTTP/3 contract'
fi

enable_h3="$(jq -nc --arg r "$revision" --argjson e "$enabled" \
    --argjson h2 "$http2" \
    '{revision:$r, enabled:$e, http2:$h2, http3:true}')"
code="$(http_status -X PUT --data "$enable_h3" \
    "$CONTROLLER/5gpn/interception/settings")"
[[ "$code" == 422 ]] && ok 'http3=true is rejected with 422' \
    || bad "http3=true returned $code"

after="$(request "$CONTROLLER/5gpn/interception")"
if [[ "$(jq -r '.revision' <<<"$after")" == "$revision" ]] \
   && [[ "$(jq -r '.snapshot.http3' <<<"$after")" == false ]]; then
    ok 'the rejected HTTP/3 write changed no state'
else
    bad 'the rejected HTTP/3 write changed revision or state'
fi

guard='  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT'
guard_count="$(grep -cFx "$guard" "$MIHOMO_CONF" 2>/dev/null || true)"
private_line="$(grep -nF '  - IP-CIDR,169.254.0.0/16,REJECT,no-resolve' \
    "$MIHOMO_CONF" | cut -d: -f1 || true)"
guard_line="$(grep -nF "$guard" "$MIHOMO_CONF" | cut -d: -f1 || true)"
match_line="$(grep -nF '  - MATCH,Proxies' "$MIHOMO_CONF" | cut -d: -f1 || true)"
if [[ "$guard_count" == 1 && -n "$private_line" && -n "$guard_line" \
      && -n "$match_line" && "$private_line" -lt "$guard_line" \
      && "$guard_line" -lt "$match_line" ]]; then
    ok 'operator config contains one fixed UDP/443 guard in the safe position'
else
    bad 'operator config guard is missing, duplicated, or out of position'
fi

rules="$(request "$CONTROLLER/rules")"
api_guard_count="$(jq -r '[.rules[] | select(.type == "AND" and .payload == "((Network,udp) && (DstPort,443))" and .proxy == "REJECT")] | length' <<<"$rules")"
if [[ "$api_guard_count" == 1 ]]; then
    ok 'running rules contain exactly one fixed UDP/443 guard'
    guard_index="$(jq -r '.rules[] | select(.type == "AND" and .payload == "((Network,udp) && (DstPort,443))" and .proxy == "REJECT") | .index' <<<"$rules")"
    disable_body="$(jq -nc --arg i "$guard_index" '{($i):true}')"
    code="$(http_status -X PATCH --data "$disable_body" \
        "$CONTROLLER/rules/disable")"
    [[ "$code" == 400 ]] && ok 'controller refuses to disable the guard' \
        || bad "guard disable returned $code"
    rules_after="$(request "$CONTROLLER/rules")"
    if jq -e --argjson i "$guard_index" \
        '.rules[] | select(.index == $i and .type == "AND" and .payload == "((Network,udp) && (DstPort,443))" and .proxy == "REJECT" and .extra.disabled == false)' \
        >/dev/null <<<"$rules_after"; then
        ok 'the rejected disable left the guard enabled'
    else
        bad 'the guard changed after the rejected disable'
    fi
else
    bad "running rules contain $api_guard_count fixed UDP/443 guards"
fi

echo
echo "== summary: $PASS passed, $FAIL failed =="
(( FAIL == 0 ))
