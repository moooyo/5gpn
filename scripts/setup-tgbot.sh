#!/usr/bin/env bash
# Source-only Telegram configuration workflow for install.sh. The parent owns
# Gum/bootstrap/output helpers; keeping the state-changing workflow here gives
# CLI and policy tests one stable implementation even while install.sh evolves.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "setup-tgbot.sh is an install.sh helper and must not be run directly." >&2
    exit 2
fi

persist_tgbot_startup_settings() {
    local envf="$1" proxy_url="$2" alerts="$3" tmp
    [[ "$envf" == "${CONF_DIR}/dns.env" ]] \
        || { err "Refusing unexpected Telegram settings path: $envf"; return 1; }
    validate_dns_env_schema || return 1
    [[ "$proxy_url" != *$'\n'* && "$proxy_url" != *$'\r'* \
       && "$alerts" != *$'\n'* && "$alerts" != *$'\r'* ]] \
        || { err "Telegram startup settings must not contain newlines."; return 1; }
    tmp="$(mktemp "${envf}.telegram.XXXXXX")" || return 1
    grep -vE '^(TGBOT_PROXY_URL|TGBOT_ALERTS)=' "$envf" > "$tmp" 2>/dev/null || true
    {
        printf 'TGBOT_PROXY_URL=%s\n' "$proxy_url"
        printf 'TGBOT_ALERTS=%s\n' "$alerts"
    } >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0640 "$tmp" || { rm -f -- "$tmp"; return 1; }
    sync -f "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$envf" || { rm -f -- "$tmp"; return 1; }
    sync -f "$(dirname "$envf")" 2>/dev/null || true
}

setup_tgbot_live() {
    check_root
    install_gum
    [[ -t 0 ]] || { err "Telegram configuration requires the TUI."; return 1; }
    local envf="${CONF_DIR}/dns.env"
    [[ -f "$envf" ]] || { err "${envf} not found (run a full install first)."; return 1; }

    local tgbot_file
    tgbot_file="$(cfg_get DNS_TGBOT_FILE)"
    tgbot_file="${tgbot_file:-${CONF_DIR}/tgbot.json}"

    local request response current code detail
    request="$(mktemp)" || return 1
    response="$(mktemp)" || { rm -f -- "$request"; return 1; }
    current="$(mktemp)" || { rm -f -- "$request" "$response"; return 1; }
    chmod 600 "$request" "$response" "$current" \
        || { rm -f -- "$request" "$response" "$current"; return 1; }

    local token="" admins="" existing_token existing_admins include_token=1 override=0 token_set=0
    existing_token="$(cfg_get TGBOT_TOKEN)"
    existing_admins="$(cfg_get TGBOT_ADMINS)"

    if [[ -e "$tgbot_file" ]]; then
        override=1
        info "Runtime Telegram override detected at ${tgbot_file}; it is the active source, not TGBOT_* in dns.env."
        if ! code="$(tgbot_api_call GET "" "$current")"; then
            rm -f -- "$request" "$response" "$current"
            err "Could not read the live Telegram configuration; dns.env was left unchanged. Check: systemctl status 5gpn-dns"
            return 1
        fi
        if [[ "$code" != 200 ]]; then
            detail="$(tr '\n' ' ' < "$current" | cut -c1-300)"
            rm -f -- "$request" "$response" "$current"
            err "Local Telegram API returned HTTP ${code}: ${detail:-no response}. No configuration was changed."
            return 1
        fi
        grep -Eq '"token_set"[[:space:]]*:[[:space:]]*true' "$current" && token_set=1
        existing_admins="$(sed -n 's/.*"admins"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$current" | head -1)"
        include_token=0
    fi

    # Blank input keeps an existing runtime token because GET redacts it and PUT
    # can omit token.
    if [[ "$override" == 0 ]]; then
        token="$existing_token"
        local entered_token=""
        entered_token="$(ask_secret 'Telegram Bot Token (blank keeps persisted token / cancels when none):' || true)"
        [[ -n "$entered_token" ]] && token="$entered_token"
    else
        token="$(ask_secret 'New Telegram Bot Token (blank keeps the active token):' || true)"
        [[ -n "$token" ]] && include_token=1
    fi

    if [[ "$include_token" == 1 ]]; then
        if [[ -z "$token" ]]; then
            rm -f -- "$request" "$response" "$current"
            info "No Telegram token supplied; nothing changed. Re-run later: $0 setup-tgbot"
            return 0
        fi
        if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            rm -f -- "$request" "$response" "$current"
            err "Telegram token has an invalid format; no configuration was changed."
            return 1
        fi
    elif [[ "$token_set" != 1 ]]; then
        rm -f -- "$request" "$response" "$current"
        err "${tgbot_file} does not provide an active token. Enter one through the TUI; no configuration was changed."
        return 1
    fi

    admins="$existing_admins"
    local entered_admins
    entered_admins="$(ask_text "Authorized Telegram numeric IDs (comma-separated; blank keeps '${admins:-none}', type 'none' to clear):" || true)"
    if [[ "$entered_admins" == none ]]; then
        admins=""
    elif [[ -n "$entered_admins" ]]; then
        admins="$entered_admins"
    fi
    local raw_admins="$admins"
    admins="$(printf '%s' "$admins" | tr ', ' '\n\n' | grep -E '^[1-9][0-9]*$' | paste -sd ',' - 2>/dev/null || true)"
    if [[ -n "$raw_admins" && -z "$admins" ]]; then
        rm -f -- "$request" "$response" "$current"
        err "No valid positive numeric Telegram administrator ID was supplied; no configuration was changed."
        return 1
    fi

    local proxy_url existing_proxy alerts existing_alerts startup_changed=0
    existing_proxy="$(cfg_get TGBOT_PROXY_URL)"
    proxy_url="$existing_proxy"
    local entered_proxy
    entered_proxy="$(ask_text "Telegram HTTP(S) proxy URL (blank keeps '${proxy_url:-none}', type 'none' to clear):" || true)"
    if [[ "$entered_proxy" == none ]]; then
        proxy_url=""
    elif [[ -n "$entered_proxy" ]]; then
        proxy_url="$entered_proxy"
    fi
    if [[ -n "$proxy_url" && ! "$proxy_url" =~ ^https?://[^/?#[:space:]]+/?$ ]]; then
        rm -f -- "$request" "$response" "$current"
        err "Telegram proxy must be an HTTP(S) origin URL without path/query/fragment."
        return 1
    fi
    existing_alerts="$(cfg_get TGBOT_ALERTS)"; existing_alerts="${existing_alerts:-false}"
    alerts="$existing_alerts"
    local alert_choice
    alert_choice="$(ask_choice 'Telegram transition alerts' "keep current (${alerts})" disabled enabled || true)"
    [[ "$alert_choice" == enabled ]] && alerts=true
    [[ "$alert_choice" == disabled ]] && alerts=false
    case "$alerts" in
        1|true|TRUE|True|yes|YES|Yes|on|ON|On) alerts=true ;;
        0|false|FALSE|False|no|NO|No|off|OFF|Off) alerts=false ;;
        *)
            rm -f -- "$request" "$response" "$current"
            err "TGBOT_ALERTS must be true or false."
            return 1 ;;
    esac
    [[ "$proxy_url" == "$existing_proxy" && "$alerts" == "$existing_alerts" ]] || startup_changed=1

    if [[ "$include_token" == 1 ]]; then
        printf '{"token":"%s","admins":[%s]}\n' "$token" "$admins" > "$request"
    else
        printf '{"admins":[%s]}\n' "$admins" > "$request"
    fi

    if ! code="$(tgbot_api_call PUT "$request" "$response")"; then
        rm -f -- "$request" "$response" "$current"
        err "Could not reach the local Telegram API; no durable configuration was reported. Check: journalctl -u 5gpn-dns"
        return 1
    fi
    if [[ "$code" != 200 ]]; then
        detail="$(tr '\n' ' ' < "$response" | cut -c1-300)"
        rm -f -- "$request" "$response" "$current"
        err "Telegram configuration was rejected (HTTP ${code}): ${detail:-no response}."
        return 1
    fi
    if [[ "$startup_changed" == 1 ]]; then
        persist_tgbot_startup_settings "$envf" "$proxy_url" "$alerts" || return 1
        if ! systemctl restart 5gpn-dns 2>/dev/null; then
            rm -f -- "$request" "$response" "$current"
            err "Telegram runtime config was applied and startup settings saved, but 5gpn-dns restart failed."
            return 1
        fi
    fi
    rm -f -- "$request" "$response" "$current"

    local tgbot_mode
    tgbot_mode="$(stat -c '%a' "$tgbot_file" 2>/dev/null \
        || stat -f '%Lp' "$tgbot_file" 2>/dev/null || true)"
    if [[ ! -f "$tgbot_file" || -L "$tgbot_file" || "$tgbot_mode" != 600 ]]; then
        err "Telegram config may be live, but the expected 0600 override at ${tgbot_file} was not verified. If DNS_TGBOT_FILE changed, restart 5gpn-dns and retry."
        return 1
    fi

    if [[ -t 0 && "${_HAVE_GUM:-0}" == 1 ]]; then
        gum style --border rounded --padding "0 1" \
          "未知自己的 Telegram ID?" \
          "1) 给你的 bot 发 /id" \
          "2) 再运行 5gpn setup-tgbot，或在 Web 设置中加入该 ID"
    fi
    ok "Telegram 配置已由守护进程接受并安全应用；有效配置已原子保存到 ${tgbot_file}。"
    info "The token remains redacted through the API; ${tgbot_file} is mode 0600."
    [[ -n "$admins" ]] \
        || warn "No admin IDs set yet; only /id is useful until an administrator is added through this command or Web Settings."
}
