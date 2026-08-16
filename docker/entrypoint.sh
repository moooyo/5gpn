#!/usr/bin/env bash
# Bootstrap the single-container runtime, then replace this process with the
# monolith. No daemon, timer, or unattended child is left behind by this file.
set -Eeuo pipefail
umask 0077
export LC_ALL=C

readonly BOOTSTRAP_INPUT=/run/5gpn-bootstrap-input/config.env
readonly BOOTSTRAP_CONFIG=/run/5gpn-bootstrap/config.env
readonly CF_SECRET=/run/secrets/cloudflare_api_token
readonly CF_CREDENTIAL=/run/5gpn/cloudflare.ini
readonly CONFIG_ROOT=/etc/5gpn
readonly MIHOMO_HOME=/etc/5gpn/mihomo
readonly FIVEGPN_STATE=/etc/5gpn/mihomo/5gpn
readonly MIHOMO_CONFIG=/etc/5gpn/mihomo/config.yaml
readonly DNS_DOCUMENT=/etc/5gpn/mihomo/5gpn/dns.json
readonly DNS_ENV=/etc/5gpn/dns.env
readonly UI_SOURCE=/usr/share/5gpn/ui
readonly UI_DIR=/opt/5gpn/ui
readonly MIHOMO_BIN=/opt/5gpn/bin/5gpn-mihomo
readonly MIHOMO_TEMPLATE=/usr/share/5gpn/config.yaml.tmpl
readonly PUBLIC_CERT_HELPER=/opt/5gpn/scripts/docker-public-cert.sh
readonly INTERCEPT_CERT_HELPER=/opt/5gpn/scripts/docker-intercept-cert.sh
readonly CONFIG_MARKER=.5gpn-owned
readonly CONFIG_MARKER_VALUE=5gpn-config
readonly UI_MARKER=.5gpn-zashboard-owned
readonly UI_MARKER_VALUE=5gpn-zashboard
readonly DOCKER_LISTEN_IP=0.0.0.0
# Public 443 is mapped here by Compose. Keeping the tunnel socket off container
# port 443 lets the internal controller retain its load-bearing 127.0.0.1:443
# origin while the tunnel target and sniffed destination still remain :443.
readonly DOCKER_TLS_LISTEN_PORT=9443

readonly DNS_CHINA_DEFAULT=223.5.5.5
readonly DNS_TRUST_DEFAULT=22.22.22.22
readonly DNS_CHINA_ECS_DEFAULT=112.96.32.0/24
readonly DNS_CHINA_DOMAINS_DEFAULT=https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_Domain.yaml
readonly DNS_GFWLIST_DEFAULT=https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt
readonly DNS_SUBSCRIPTION_INTERVAL_DEFAULT=86400

CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
child_pid=""
child_pgid=""
spawning_child=0
shutdown_requested=0
PERSISTED_DNS_ENV=0
PERSISTED_DNS_SECRET=""

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }
fatal() { printf '[ERR]  %s\n' "$*" >&2; exit 1; }

request_shutdown() {
    shutdown_requested=1
    if [[ -n "$child_pgid" ]]; then
        kill -TERM -- "-$child_pgid" 2>/dev/null || true
    elif [[ "$spawning_child" == 0 ]]; then
        exit 143
    fi
}
trap request_shutdown HUP INT TERM

run_sync() {
    local rc wait_rc index
    [[ "$shutdown_requested" == 0 ]] || exit 143
    spawning_child=1
    setsid -- "$@" &
    child_pid=$!
    child_pgid="$child_pid"
    spawning_child=0
    if [[ "$shutdown_requested" == 1 ]]; then
        kill -TERM -- "-$child_pgid" 2>/dev/null || true
    fi
    set +e
    wait "$child_pid"
    rc=$?
    set -e
    if [[ "$shutdown_requested" == 1 ]]; then
        for ((index = 0; index < 10; index++)); do
            kill -0 -- "-$child_pgid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 -- "-$child_pgid" 2>/dev/null; then
            kill -KILL -- "-$child_pgid" 2>/dev/null || true
        fi
        set +e
        wait "$child_pid" 2>/dev/null
        while :; do
            wait -n 2>/dev/null
            wait_rc=$?
            [[ "$wait_rc" == 127 ]] && break
        done
        set -e
        child_pid=""
        child_pgid=""
        exit 143
    fi
    child_pid=""
    child_pgid=""
    return "$rc"
}

path_uid() { stat -c %u -- "$1"; }
path_gid() { stat -c %g -- "$1"; }
path_mode() { stat -c %a -- "$1"; }
path_nlink() { stat -c %h -- "$1"; }

assert_current_directory() {
    local path="$1"
    [[ -d "$path" && ! -L "$path" ]] \
        || fatal "Required path is not a real directory: $path"
    [[ "$(readlink -f -- "$path")" == "$path" ]] \
        || fatal "Required directory is not canonical: $path"
    [[ "$(path_uid "$path")" == "$CURRENT_UID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" ]] \
        || fatal "$path must be owned by container UID:GID ${CURRENT_UID}:${CURRENT_GID}."
}

ensure_current_directory() {
    local path="$1" mode="$2" parent
    parent="$(dirname -- "$path")"
    [[ -d "$parent" && ! -L "$parent" ]] \
        || fatal "Unsafe parent for runtime directory: $parent"
    if [[ -e "$path" || -L "$path" ]]; then
        assert_current_directory "$path"
    else
        mkdir -- "$path"
    fi
    chmod "$mode" "$path"
    assert_current_directory "$path"
}

safe_current_plain_file() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" \
       && "$(path_uid "$path")" == "$CURRENT_UID" \
       && "$(path_gid "$path")" == "$CURRENT_GID" \
       && "$(path_nlink "$path")" == 1 ]]
}

safe_private_input_file() {
    local path="$1"
    safe_current_plain_file "$path" && [[ "$(path_mode "$path")" == 600 ]]
}

valid_ipv4() {
    local value="$1" a b c d extra octet
    IFS=. read -r a b c d extra <<< "$value"
    [[ -z "${extra:-}" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

valid_domain() {
    local domain="$1"
    [[ ${#domain} -ge 1 && ${#domain} -le 253 \
       && "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ \
       && "$1" != -* && ${#1} -le 254 \
       && "$1" != *$'\r'* && "$1" != *$'\n'* ]]
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

declare -A BOOTSTRAP=()
prepare_bootstrap_config() {
    local size candidate
    [[ -r "$BOOTSTRAP_INPUT" ]] && safe_private_input_file "$BOOTSTRAP_INPUT" \
        || fatal "Bootstrap configuration input must be one mode-0600 file owned by container UID:GID ${CURRENT_UID}:${CURRENT_GID}: $BOOTSTRAP_INPUT"
    size="$(wc -c < "$BOOTSTRAP_INPUT" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le 65536 ]] \
        || fatal "Bootstrap configuration input has an invalid size."
    assert_current_directory /run/5gpn-bootstrap
    candidate="$(mktemp /run/5gpn-bootstrap/.config.env.XXXXXX)"
    cp -- "$BOOTSTRAP_INPUT" "$candidate"
    chmod 0600 "$candidate"
    mv -f -- "$candidate" "$BOOTSTRAP_CONFIG"
    safe_current_plain_file "$BOOTSTRAP_CONFIG" \
        || fatal "Could not secure the runtime bootstrap configuration."
}

load_bootstrap_config() {
    local raw line key value line_number=0
    [[ -f "$BOOTSTRAP_CONFIG" && ! -L "$BOOTSTRAP_CONFIG" && -r "$BOOTSTRAP_CONFIG" ]] \
        || fatal "Missing readable bootstrap configuration: $BOOTSTRAP_CONFIG"
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line_number=$((line_number + 1))
        [[ "$raw" != *$'\r'* ]] \
            || fatal "Bootstrap configuration contains CR at line $line_number."
        line="$(trim "$raw")"
        [[ -n "$line" && "${line:0:1}" != '#' ]] || continue
        [[ "$line" == *=* ]] \
            || fatal "Malformed bootstrap configuration at line $line_number."
        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] \
            || fatal "Invalid bootstrap key at line $line_number."
        case "$key" in
            DNS_BASE_DOMAIN|DNS_GATEWAY_IP|DNS_PUBLIC_IP|DNS_MIHOMO_SECRET|CERT_EMAIL|CERT_MODE) ;;
            *) fatal "Unsupported Docker bootstrap key: $key" ;;
        esac
        [[ -z "${BOOTSTRAP[$key]+present}" ]] \
            || fatal "Duplicate Docker bootstrap key: $key"
        [[ -n "$value" ]] || fatal "Docker bootstrap value is empty: $key"
        [[ "$line" == "$key=$value" ]] \
            || fatal "Docker bootstrap entries must use exact KEY=value syntax at line $line_number."
        BOOTSTRAP[$key]="$value"
    done < "$BOOTSTRAP_CONFIG"

    for key in DNS_BASE_DOMAIN DNS_GATEWAY_IP CERT_EMAIL; do
        [[ -n "${BOOTSTRAP[$key]:-}" ]] || fatal "Missing required Docker bootstrap key: $key"
    done
}

validate_bootstrap_values() {
    DNS_BASE_DOMAIN="${BOOTSTRAP[DNS_BASE_DOMAIN]}"
    DNS_GATEWAY_IP="${BOOTSTRAP[DNS_GATEWAY_IP]}"
    DNS_PUBLIC_IP="${BOOTSTRAP[DNS_PUBLIC_IP]:-$DNS_GATEWAY_IP}"
    CERT_EMAIL="${BOOTSTRAP[CERT_EMAIL]}"
    CERT_MODE="${BOOTSTRAP[CERT_MODE]:-cloudflare}"

    valid_domain "$DNS_BASE_DOMAIN" || fatal "DNS_BASE_DOMAIN must be a lowercase apex domain."
    valid_ipv4 "$DNS_GATEWAY_IP" || fatal "DNS_GATEWAY_IP must be an IPv4 address."
    valid_ipv4 "$DNS_PUBLIC_IP" || fatal "DNS_PUBLIC_IP must be an IPv4 address."
    valid_email "$CERT_EMAIL" || fatal "CERT_EMAIL is invalid."
    [[ "$CERT_MODE" == cloudflare ]] \
        || fatal "Docker supports only CERT_MODE=cloudflare."
    DNS_MIHOMO_LISTEN_IPS="$DOCKER_LISTEN_IP"
    CONSOLE_DOMAIN="console.${DNS_BASE_DOMAIN}"
    DOT_DOMAIN="dot.${DNS_BASE_DOMAIN}"
}

dns_env_decode_value() {
    local raw="$1" body out="" char next index
    if [[ "$raw" != \"* ]]; then
        printf '%s' "$raw"
        return 0
    fi
    [[ ${#raw} -ge 2 && "$raw" == *\" ]] || return 1
    body="${raw:1:${#raw}-2}"
    for ((index = 0; index < ${#body}; index++)); do
        char="${body:index:1}"
        if [[ "$char" == \\ ]]; then
            index=$((index + 1))
            (( index < ${#body} )) || return 1
            next="${body:index:1}"
            case "$next" in
                '"'|'\'|'$'|'`') out+="$next" ;;
                *) out+="\\$next" ;;
            esac
        else
            [[ "$char" != '"' ]] || return 1
            out+="$char"
        fi
    done
    printf '%s' "$out"
}

dns_env_get() {
    local key="$1" raw count
    count="$(grep -cE "^${key}=" "$DNS_ENV" 2>/dev/null || true)"
    [[ "$count" == 1 ]] || return 1
    raw="$(grep -E "^${key}=" "$DNS_ENV" | cut -d= -f2-)"
    if [[ "$key" == DNS_MIHOMO_SECRET ]]; then
        dns_env_decode_value "$raw"
    else
        printf '%s' "$raw"
    fi
}

load_persisted_dns_env() {
    local line key mode value
    if [[ ! -e "$DNS_ENV" && ! -L "$DNS_ENV" ]]; then
        PERSISTED_DNS_ENV=0
        return
    fi
    safe_current_plain_file "$DNS_ENV" \
        || fatal "Existing Docker dns.env is unsafe."
    mode="$(path_mode "$DNS_ENV")"
    (( (8#$mode & 0077) == 0 )) \
        || fatal "Existing Docker dns.env must be private to UID 10001."

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -n "$line" && "${line:0:1}" != '#' ]] || continue
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)= ]] \
            || fatal "Existing Docker dns.env contains a malformed entry."
        key="${BASH_REMATCH[1]}"
        case "$key" in
            DNS_LISTEN_DOT|DNS_LISTEN_DEBUG|DNS_BASE_DOMAIN|DNS_PUBLIC_IP|DNS_GATEWAY_IP|DNS_MIHOMO_LISTEN_IPS|CERT_MODE|CERT_EMAIL|DNS_MIHOMO_CONTROLLER|DNS_MIHOMO_SECRET|DNS_CONSOLE_CERT|DNS_CONSOLE_KEY) ;;
            *) fatal "Existing Docker dns.env contains an unsupported key: $key" ;;
        esac
    done < "$DNS_ENV"

    [[ "$(dns_env_get DNS_LISTEN_DOT)" == :853 \
       && "$(dns_env_get DNS_LISTEN_DEBUG)" == 127.0.0.1:5353 \
       && "$(dns_env_get DNS_BASE_DOMAIN)" == "$DNS_BASE_DOMAIN" \
       && "$(dns_env_get DNS_PUBLIC_IP)" == "$DNS_PUBLIC_IP" \
       && "$(dns_env_get DNS_GATEWAY_IP)" == "$DNS_GATEWAY_IP" \
       && "$(dns_env_get DNS_MIHOMO_LISTEN_IPS)" == "$DNS_MIHOMO_LISTEN_IPS" \
       && "$(dns_env_get CERT_MODE)" == cloudflare \
       && "$(dns_env_get CERT_EMAIL)" == "$CERT_EMAIL" \
       && "$(dns_env_get DNS_MIHOMO_CONTROLLER)" == 127.0.0.1:443 \
       && "$(dns_env_get DNS_CONSOLE_CERT)" == /etc/5gpn/cert/console/current/fullchain.pem \
       && "$(dns_env_get DNS_CONSOLE_KEY)" == /etc/5gpn/cert/console/current/privkey.pem ]] \
        || fatal "Bootstrap coordinates conflict with the persisted Docker dns.env."
    value="$(dns_env_get DNS_MIHOMO_SECRET)" \
        || fatal "Persisted Docker controller secret is malformed."
    [[ -n "$value" && "$value" != *$'\r'* && "$value" != *$'\n'* ]] \
        || fatal "Persisted Docker controller secret is invalid."
    if [[ -n "${BOOTSTRAP[DNS_MIHOMO_SECRET]:-}" \
       && "${BOOTSTRAP[DNS_MIHOMO_SECRET]}" != "$value" ]]; then
        fatal "DNS_MIHOMO_SECRET conflicts with the persisted Docker state."
    fi
    PERSISTED_DNS_ENV=1
    PERSISTED_DNS_SECRET="$value"
}

prepare_runtime_directories() {
    assert_current_directory "$CONFIG_ROOT"
    [[ -f "$CONFIG_ROOT/$CONFIG_MARKER" && ! -L "$CONFIG_ROOT/$CONFIG_MARKER" \
       && "$(<"$CONFIG_ROOT/$CONFIG_MARKER")" == "$CONFIG_MARKER_VALUE" ]] \
        || fatal "The /etc/5gpn volume is missing its ownership marker."
    ensure_current_directory "$MIHOMO_HOME" 0750
    ensure_current_directory "$FIVEGPN_STATE" 0750
    assert_current_directory /run/5gpn
    assert_current_directory "$UI_DIR"
}

prepare_ui() {
    local first
    [[ -d "$UI_SOURCE" && ! -L "$UI_SOURCE" \
       && -f "$UI_SOURCE/index.html" && ! -L "$UI_SOURCE/index.html" ]] \
        || fatal "The image does not contain a safe Console bundle."
    [[ -z "$(find "$UI_SOURCE" -mindepth 1 \( -type l -o ! -type d ! -type f \) -print -quit)" ]] \
        || fatal "The image Console bundle contains an unsafe object."
    first="$(find "$UI_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
    [[ -z "$first" ]] \
        || fatal "$UI_DIR must be an empty tmpfs at container start."
    cp -R -- "$UI_SOURCE/." "$UI_DIR/"
    find "$UI_DIR" -type d -exec chmod 0755 {} +
    find "$UI_DIR" -type f -exec chmod 0644 {} +
    [[ -f "$UI_DIR/$UI_MARKER" && ! -L "$UI_DIR/$UI_MARKER" \
       && "$(<"$UI_DIR/$UI_MARKER")" == "$UI_MARKER_VALUE" ]] \
        || fatal "The copied Console bundle has no valid ownership marker."
    ok "Console bundle refreshed in tmpfs."
}

prepare_cloudflare_credential() {
    local token file_size token_size last_byte candidate
    [[ -r "$CF_SECRET" ]] && safe_private_input_file "$CF_SECRET" \
        || fatal "Cloudflare API token secret must be one mode-0600 file owned by container UID:GID ${CURRENT_UID}:${CURRENT_GID}: $CF_SECRET"
    file_size="$(wc -c < "$CF_SECRET" | tr -d '[:space:]')"
    [[ "$file_size" =~ ^[0-9]+$ && "$file_size" -gt 0 && "$file_size" -le 4096 ]] \
        || fatal "Cloudflare API token secret has an invalid size."
    token="$(<"$CF_SECRET")"
    [[ "$token" =~ ^[A-Za-z0-9_-]{20,200}$ ]] \
        || fatal "Cloudflare API token secret has an invalid format."
    token_size="${#token}"
    if (( file_size == token_size + 1 )); then
        last_byte="$(tail -c 1 "$CF_SECRET" | od -An -tx1 | tr -d '[:space:]')"
        [[ "$last_byte" == 0a ]] \
            || fatal "Cloudflare API token secret contains trailing data."
    elif (( file_size != token_size )); then
        fatal "Cloudflare API token secret must contain one raw token."
    fi
    candidate="$(mktemp /run/5gpn/.cloudflare.ini.XXXXXX)"
    printf 'dns_cloudflare_api_token = %s\n' "$token" > "$candidate"
    chmod 0600 "$candidate"
    mv -f -- "$candidate" "$CF_CREDENTIAL"
    unset token
}

bootstrap_public_certificate() {
    local rc delay_index=0 delay
    local -a delays=(60 300 1800 3600)
    while :; do
        if run_sync "$PUBLIC_CERT_HELPER" bootstrap; then
            return 0
        else
            rc=$?
        fi
        [[ "$rc" == 75 ]] || return "$rc"
        if (( delay_index >= ${#delays[@]} )); then
            return 75
        fi
        delay="${delays[$delay_index]}"
        delay_index=$((delay_index + 1))
        info "Temporary ACME failure; retrying public certificate bootstrap in ${delay}s."
        run_sync sleep "$delay" || return $?
    done
}

render_listeners() {
    printf '  - {name: gateway, type: tunnel, listen: %s, port: %s, network: [tcp, udp], target: %s:443}\n' "$DOCKER_LISTEN_IP" "$DOCKER_TLS_LISTEN_PORT" "$CONSOLE_DOMAIN"
    printf '  - {name: gateway80, type: tunnel, listen: %s, port: 80, network: [tcp], target: %s:80}\n' "$DOCKER_LISTEN_IP" "$CONSOLE_DOMAIN"
    printf '  - {name: gateway8080, type: tunnel, listen: %s, port: 8080, network: [tcp], target: %s:8080}\n' "$DOCKER_LISTEN_IP" "$CONSOLE_DOMAIN"
    printf '  - {name: gateway8443, type: tunnel, listen: %s, port: 8443, network: [tcp], target: %s:8443}\n' "$DOCKER_LISTEN_IP" "$CONSOLE_DOMAIN"
    printf '  - {name: gateway5060, type: tunnel, listen: %s, port: 5060, network: [tcp, udp], target: %s:5060}\n' "$DOCKER_LISTEN_IP" "$CONSOLE_DOMAIN"
}

render_mihomo_seed() {
    local destination="$1" secret="$2" line listeners
    listeners="$(render_listeners)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == __MIHOMO_LISTENERS__ ]]; then
            printf '%s\n' "$listeners"
            continue
        fi
        line="${line//__GATEWAY_IP__/$DNS_GATEWAY_IP}"
        line="${line//__CONSOLE_DOMAIN__/$CONSOLE_DOMAIN}"
        line="${line//__CONTROLLER_SECRET__/$secret}"
        printf '%s\n' "$line"
    done < "$MIHOMO_TEMPLATE" > "$destination"
}

yaml_single_quoted_value() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

prepare_mihomo_config() {
    local candidate secret secret_yaml mode
    [[ -x "$MIHOMO_BIN" && -f "$MIHOMO_TEMPLATE" && ! -L "$MIHOMO_TEMPLATE" ]] \
        || fatal "The image runtime or seed template is missing."
    if [[ -e "$MIHOMO_CONFIG" || -L "$MIHOMO_CONFIG" ]]; then
        [[ "$PERSISTED_DNS_ENV" == 1 ]] \
            || fatal "Existing operator config has no persisted Docker dns.env; refusing to infer its secret from YAML."
        safe_current_plain_file "$MIHOMO_CONFIG" \
            || fatal "Existing operator mihomo config is unsafe: $MIHOMO_CONFIG"
        mode="$(path_mode "$MIHOMO_CONFIG")"
        (( (8#$mode & 0022) == 0 )) \
            || fatal "Existing operator mihomo config is group/other writable."
        run_sync "$MIHOMO_BIN" -t -f "$MIHOMO_CONFIG" -d "$MIHOMO_HOME" \
            || fatal "Existing operator mihomo config is invalid and was preserved."
        DNS_MIHOMO_SECRET="$PERSISTED_DNS_SECRET"
        ok "Existing operator mihomo config validated and preserved."
        return
    fi

    secret="$DNS_MIHOMO_SECRET"
    [[ "$secret" =~ ^[A-Za-z0-9._~-]{16,256}$ ]] \
        || fatal "A fresh DNS_MIHOMO_SECRET must contain 16 to 256 URL-safe characters."
    secret_yaml="$(yaml_single_quoted_value "$secret")" \
        || fatal "DNS_MIHOMO_SECRET cannot be represented safely in YAML."
    candidate="$(mktemp "$MIHOMO_HOME/.config.yaml.XXXXXX")"
    render_mihomo_seed "$candidate" "$secret_yaml"
    chmod 0600 "$candidate"
    run_sync "$MIHOMO_BIN" -t -f "$candidate" -d "$MIHOMO_HOME" \
        || { rm -f -- "$candidate"; fatal "Generated mihomo config failed validation."; }
    sync -f "$candidate"
    mv -f -- "$candidate" "$MIHOMO_CONFIG"
    sync -f "$MIHOMO_HOME"
    DNS_MIHOMO_SECRET="$secret"
    ok "Initial operator-owned mihomo config published."
}

dns_env_encode_value() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

write_dns_env() {
    local candidate encoded_secret
    [[ "$PERSISTED_DNS_ENV" == 0 ]] || return 0
    encoded_secret="$(dns_env_encode_value "$DNS_MIHOMO_SECRET")" \
        || fatal "Controller secret cannot be represented in dns.env."
    if [[ -e "$DNS_ENV" || -L "$DNS_ENV" ]]; then
        safe_current_plain_file "$DNS_ENV" \
            || fatal "Existing dns.env path is unsafe."
    fi
    candidate="$(mktemp "$CONFIG_ROOT/.dns.env.XXXXXX")"
    cat > "$candidate" <<EOF
# 5gpn Docker installation coordinates. Live DNS, interception, and bot state
# lives under /etc/5gpn/mihomo/5gpn and is not mirrored here.
DNS_LISTEN_DOT=:853
DNS_LISTEN_DEBUG=127.0.0.1:5353
DNS_BASE_DOMAIN=${DNS_BASE_DOMAIN}
DNS_PUBLIC_IP=${DNS_PUBLIC_IP}
DNS_GATEWAY_IP=${DNS_GATEWAY_IP}
DNS_MIHOMO_LISTEN_IPS=${DNS_MIHOMO_LISTEN_IPS}
CERT_MODE=cloudflare
CERT_EMAIL=${CERT_EMAIL}
DNS_MIHOMO_CONTROLLER=127.0.0.1:443
DNS_MIHOMO_SECRET=${encoded_secret}
DNS_CONSOLE_CERT=/etc/5gpn/cert/console/current/fullchain.pem
DNS_CONSOLE_KEY=/etc/5gpn/cert/console/current/privkey.pem
EOF
    chmod 0600 "$candidate"
    sync -f "$candidate"
    mv -f -- "$candidate" "$DNS_ENV"
    sync -f "$CONFIG_ROOT"
    PERSISTED_DNS_ENV=1
    PERSISTED_DNS_SECRET="$DNS_MIHOMO_SECRET"
}

ensure_dns_env() {
    if [[ "$PERSISTED_DNS_ENV" == 1 ]]; then
        DNS_MIHOMO_SECRET="$PERSISTED_DNS_SECRET"
        return
    fi
    [[ ! -e "$MIHOMO_CONFIG" && ! -L "$MIHOMO_CONFIG" ]] \
        || fatal "Existing operator config has no persisted Docker dns.env; refusing to invent a replacement secret."
    DNS_MIHOMO_SECRET="${BOOTSTRAP[DNS_MIHOMO_SECRET]:-}"
    [[ -n "$DNS_MIHOMO_SECRET" ]] || DNS_MIHOMO_SECRET="$(openssl rand -hex 32)"
    [[ "$DNS_MIHOMO_SECRET" =~ ^[A-Za-z0-9._~-]{16,256}$ ]] \
        || fatal "A fresh DNS_MIHOMO_SECRET must contain 16 to 256 URL-safe characters."
    write_dns_env
}

write_dns_document() {
    local candidate
    if [[ -e "$DNS_DOCUMENT" || -L "$DNS_DOCUMENT" ]]; then
        safe_current_plain_file "$DNS_DOCUMENT" \
            || fatal "Existing DNS document is unsafe: $DNS_DOCUMENT"
        jq -e \
           --arg cert /etc/5gpn/cert/dot/current/fullchain.pem \
           --arg key /etc/5gpn/cert/dot/current/privkey.pem \
           --arg gateway "$DNS_GATEWAY_IP" \
           'type == "object"
            and .listen.dot == ":853"
            and .listen.debug == "127.0.0.1:5353"
            and .listen.origin == "127.0.0.1:5354"
            and .listen.certificate == $cert
            and .listen.privateKey == $key
            and .gateway == $gateway' \
           "$DNS_DOCUMENT" >/dev/null \
            || fatal "Persisted DNS document conflicts with Docker installation coordinates."
        return
    fi
    candidate="$(mktemp "$FIVEGPN_STATE/.dns.json.XXXXXX")"
    jq -n \
       --arg cert /etc/5gpn/cert/dot/current/fullchain.pem \
       --arg key /etc/5gpn/cert/dot/current/privkey.pem \
       --arg gateway "$DNS_GATEWAY_IP" \
       --arg china "$DNS_CHINA_DEFAULT" \
       --arg trust "$DNS_TRUST_DEFAULT" \
       --arg ecs "$DNS_CHINA_ECS_DEFAULT" \
       --arg chinaDomains "$DNS_CHINA_DOMAINS_DEFAULT" \
       --arg gfwlist "$DNS_GFWLIST_DEFAULT" \
       --argjson interval "$DNS_SUBSCRIPTION_INTERVAL_DEFAULT" \
       '{
          listen: {
            dot: ":853",
            debug: "127.0.0.1:5353",
            origin: "127.0.0.1:5354",
            certificate: $cert,
            privateKey: $key
          },
          gateway: $gateway,
          upstreams: {china: [($china + ":53")], trust: [($trust + ":53")], ecs: $ecs},
          policy: {
            rules: [
              {id: "china-domains", kind: "subscription", value: $chinaDomains,
               intent: "direct", enabled: true, format: "clash", intervalSeconds: $interval},
              {id: "gfwlist", kind: "subscription", value: $gfwlist,
               intent: "proxy", enabled: true, format: "plain", intervalSeconds: $interval}
            ],
            fallback: "auto"
          },
          tuning: {}
        }' > "$candidate" \
        || { rm -f -- "$candidate"; fatal "Could not render the DNS document."; }
    chmod 0600 "$candidate"
    sync -f "$candidate"
    mv -f -- "$candidate" "$DNS_DOCUMENT"
    sync -f "$FIVEGPN_STATE"
}

main() {
    [[ $# == 0 ]] || fatal "The Docker image has one fixed gateway entrypoint and accepts no command override."
    [[ "${FIVEGPN_RUNTIME:-}" == container ]] \
        || fatal "FIVEGPN_RUNTIME must be exactly 'container'."
    [[ "$CURRENT_UID" == 10001 && "$CURRENT_GID" == 10001 ]] \
        || fatal "The OCI process must start as fixed UID:GID 10001:10001."

    prepare_bootstrap_config
    load_bootstrap_config
    validate_bootstrap_values
    prepare_runtime_directories
    load_persisted_dns_env
    ensure_dns_env
    prepare_ui
    prepare_cloudflare_credential

    info "Initializing the Docker interception CA."
    run_sync "$INTERCEPT_CERT_HELPER" init-ca \
        || fatal "Docker interception CA initialization failed."
    info "Bootstrapping the Cloudflare public certificate."
    bootstrap_public_certificate \
        || fatal "Docker public certificate bootstrap failed."

    prepare_mihomo_config
    write_dns_document

    ok "Bootstrap complete; starting the 5gpn monolith."
    [[ "$shutdown_requested" == 0 ]] || exit 143
    exec "$MIHOMO_BIN" -f "$MIHOMO_CONFIG" -d "$MIHOMO_HOME"
}

main "$@"
