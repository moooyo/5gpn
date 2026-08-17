#!/usr/bin/env bash
# Strict parser and URL builder for installer release artifacts.
# pins.env is data, not shell code. Only the fixed keys and value shapes below
# can enter the installer, CI, or release-verification environment.

declare -ar RELEASE_PIN_KEYS=(
    MIHOMO_REPO
    MIHOMO_VERSION
    MIHOMO_ASSET_TEMPLATE
    MIHOMO_SHA256
    ZASH_REPO
    ZASH_VERSION
    ZASH_ASSET_TEMPLATE
    ZASH_SHA256
    GUM_REPO
    GUM_VERSION
    GUM_ASSET_TEMPLATE
    GUM_SHA256_X86_64
    GUM_SHA256_ARM64
    GUM_SHA256_ARMV7
)
RELEASE_PINS_LOADED=0

_release_pins_error() {
    printf 'release pins: %s\n' "$*" >&2
}

_release_pins_clear() {
    local key
    for key in "${RELEASE_PIN_KEYS[@]}"; do
        unset "$key" \
            || { _release_pins_error "caller variable $key cannot be cleared"; return 1; }
    done
    RELEASE_PINS_LOADED=0
}

_release_template_token_count() { # _release_template_token_count <template> <token>
    local remainder="$1" token="$2" count=0
    while [[ "$remainder" == *"$token"* ]]; do
        remainder="${remainder#*"$token"}"
        ((count += 1))
    done
    printf '%s\n' "$count"
}

_release_asset_template_is_safe() { # <template> <version-count> <arch-count> <suffix>
    local template="$1" expected_version="$2" expected_arch="$3" suffix="$4"
    local version_count arch_count remainder LC_ALL=C
    [[ ${#template} -le 160 \
       && "$template" =~ ^[A-Za-z0-9][A-Za-z0-9._+{}-]*$ \
       && "$template" != *..* \
       && "$template" == *"$suffix" ]] || return 1
    version_count="$(_release_template_token_count "$template" '{version}')" || return 1
    arch_count="$(_release_template_token_count "$template" '{arch}')" || return 1
    [[ "$version_count" == "$expected_version" && "$arch_count" == "$expected_arch" ]] \
        || return 1
    remainder="${template//\{version\}/}"
    remainder="${remainder//\{arch\}/}"
    [[ "$remainder" != *'{'* && "$remainder" != *'}'* ]]
}

_release_pins_values_are_valid() {
    local map_name="$1" digest_key
    local -n pins="$map_name"
    local LC_ALL=C

    [[ "${pins[MIHOMO_REPO]}" == moooyo/mihomo ]] \
        || { _release_pins_error "MIHOMO_REPO is not an approved repository"; return 1; }
    [[ "${pins[ZASH_REPO]}" == moooyo/zashboard ]] \
        || { _release_pins_error "ZASH_REPO is not an approved repository"; return 1; }
    [[ "${pins[GUM_REPO]}" == charmbracelet/gum ]] \
        || { _release_pins_error "GUM_REPO is not an approved repository"; return 1; }

    [[ "${pins[MIHOMO_VERSION]}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-monolith\.(0|[1-9][0-9]*)$ ]] \
        || { _release_pins_error "MIHOMO_VERSION is not an approved release tag"; return 1; }
    [[ "${pins[ZASH_VERSION]}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-monolith\.(0|[1-9][0-9]*)$ ]] \
        || { _release_pins_error "ZASH_VERSION is not an approved release tag"; return 1; }
    [[ "${pins[GUM_VERSION]}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
        || { _release_pins_error "GUM_VERSION is not an approved release version"; return 1; }

    _release_asset_template_is_safe "${pins[MIHOMO_ASSET_TEMPLATE]}" 1 0 .gz \
        || { _release_pins_error "MIHOMO_ASSET_TEMPLATE is not approved"; return 1; }
    _release_asset_template_is_safe "${pins[ZASH_ASSET_TEMPLATE]}" 0 0 .zip \
        || { _release_pins_error "ZASH_ASSET_TEMPLATE is not approved"; return 1; }
    _release_asset_template_is_safe "${pins[GUM_ASSET_TEMPLATE]}" 1 1 .tar.gz \
        || { _release_pins_error "GUM_ASSET_TEMPLATE is not approved"; return 1; }

    for digest_key in \
        MIHOMO_SHA256 ZASH_SHA256 \
        GUM_SHA256_X86_64 GUM_SHA256_ARM64 GUM_SHA256_ARMV7; do
        [[ "${pins[$digest_key]}" =~ ^[0-9a-f]{64}$ ]] \
            || { _release_pins_error "$digest_key is not a lowercase SHA-256"; return 1; }
    done
}

load_release_pins() { # load_release_pins <pins.env>
    local file="${1:-}" bytes byte line key value required_key
    local line_number=0 file_size
    local -A parsed=()
    local LC_ALL=C

    _release_pins_clear || return 1
    [[ "$#" == 1 && -n "$file" && -f "$file" && ! -L "$file" && -r "$file" \
       && "$(stat -Lc '%h' -- "$file" 2>/dev/null)" == 1 ]] \
        || { _release_pins_error "pin file is missing, linked, or unreadable"; return 1; }
    file_size="$(wc -c < "$file" 2>/dev/null)" \
        || { _release_pins_error "pin file size could not be read"; return 1; }
    [[ "$file_size" =~ ^[0-9]+$ ]] && (( file_size > 0 && file_size <= 4096 )) \
        || { _release_pins_error "pin file size is outside the accepted bound"; return 1; }
    bytes="$(LC_ALL=C od -An -v -t x1 -- "$file" 2>/dev/null)" \
        || { _release_pins_error "pin file bytes could not be inspected"; return 1; }
    for byte in $bytes; do
        case "$byte" in
            0a|2[1-9a-f]|[3-6][0-9a-f]|7[0-9a-e]) ;;
            *) _release_pins_error "pin file contains a non-ASCII or control byte"; return 1 ;;
        esac
    done

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number += 1))
        [[ -n "$line" ]] \
            || { _release_pins_error "blank line at $line_number"; return 1; }
        [[ "$line" != *[[:space:]]* ]] \
            || { _release_pins_error "whitespace at line $line_number"; return 1; }
        [[ "$line" != *"'"* && "$line" != *'"'* ]] \
            || { _release_pins_error "quotes at line $line_number"; return 1; }
        [[ "$line" == *=* ]] \
            || { _release_pins_error "missing assignment at line $line_number"; return 1; }
        key="${line%%=*}"
        value="${line#*=}"
        [[ -n "$key" && -n "$value" && "$value" != *=* && "$key" =~ ^[A-Z0-9_]+$ ]] \
            || { _release_pins_error "malformed assignment at line $line_number"; return 1; }
        case "$key" in
            MIHOMO_REPO|MIHOMO_VERSION|MIHOMO_ASSET_TEMPLATE|MIHOMO_SHA256|\
            ZASH_REPO|ZASH_VERSION|ZASH_ASSET_TEMPLATE|ZASH_SHA256|\
            GUM_REPO|GUM_VERSION|GUM_ASSET_TEMPLATE|\
            GUM_SHA256_X86_64|GUM_SHA256_ARM64|GUM_SHA256_ARMV7) ;;
            *) _release_pins_error "unknown key $key"; return 1 ;;
        esac
        [[ -z "${parsed[$key]+present}" ]] \
            || { _release_pins_error "duplicate key $key"; return 1; }
        parsed["$key"]="$value"
    done < "$file"

    (( line_number == ${#RELEASE_PIN_KEYS[@]} )) \
        || { _release_pins_error "pin file does not contain exactly ${#RELEASE_PIN_KEYS[@]} entries"; return 1; }
    for required_key in "${RELEASE_PIN_KEYS[@]}"; do
        [[ -n "${parsed[$required_key]+present}" ]] \
            || { _release_pins_error "missing key $required_key"; return 1; }
    done
    _release_pins_values_are_valid parsed || return 1

    for required_key in "${RELEASE_PIN_KEYS[@]}"; do
        printf -v "$required_key" '%s' "${parsed[$required_key]}"
    done
    RELEASE_PINS_LOADED=1
}

_release_pins_require_loaded() {
    [[ "${RELEASE_PINS_LOADED:-0}" == 1 ]] \
        || { _release_pins_error "pins have not been loaded"; return 1; }
}

release_asset_name() { # release_asset_name <mihomo|zashboard|gum> [gum-arch]
    local component="${1:-}" arch="${2:-}" asset
    _release_pins_require_loaded || return 1
    case "$component" in
        mihomo)
            [[ "$#" == 1 ]] || return 1
            asset="${MIHOMO_ASSET_TEMPLATE/\{version\}/$MIHOMO_VERSION}"
            ;;
        zashboard)
            [[ "$#" == 1 ]] || return 1
            asset="$ZASH_ASSET_TEMPLATE"
            ;;
        gum)
            [[ "$#" == 2 ]] || return 1
            case "$arch" in x86_64|arm64|armv7) ;; *) return 1 ;; esac
            asset="${GUM_ASSET_TEMPLATE/\{version\}/$GUM_VERSION}"
            asset="${asset/\{arch\}/$arch}"
            ;;
        *) return 1 ;;
    esac
    [[ "$asset" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    printf '%s\n' "$asset"
}

release_artifact_sha256() { # release_artifact_sha256 <mihomo|zashboard|gum> [gum-arch]
    local component="${1:-}" arch="${2:-}"
    _release_pins_require_loaded || return 1
    case "$component" in
        mihomo) [[ "$#" == 1 ]] && printf '%s\n' "$MIHOMO_SHA256" ;;
        zashboard) [[ "$#" == 1 ]] && printf '%s\n' "$ZASH_SHA256" ;;
        gum)
            [[ "$#" == 2 ]] || return 1
            case "$arch" in
                x86_64) printf '%s\n' "$GUM_SHA256_X86_64" ;;
                arm64)  printf '%s\n' "$GUM_SHA256_ARM64" ;;
                armv7)  printf '%s\n' "$GUM_SHA256_ARMV7" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

release_download_url() { # release_download_url <mihomo|zashboard|gum> [gum-arch]
    local component="${1:-}" arch="${2:-}" repo tag asset
    _release_pins_require_loaded || return 1
    case "$component" in
        mihomo)
            [[ "$#" == 1 ]] || return 1
            repo="$MIHOMO_REPO"
            tag="$MIHOMO_VERSION"
            asset="$(release_asset_name mihomo)" || return 1
            ;;
        zashboard)
            [[ "$#" == 1 ]] || return 1
            repo="$ZASH_REPO"
            tag="$ZASH_VERSION"
            asset="$(release_asset_name zashboard)" || return 1
            ;;
        gum)
            [[ "$#" == 2 ]] || return 1
            repo="$GUM_REPO"
            tag="v${GUM_VERSION}"
            asset="$(release_asset_name gum "$arch")" || return 1
            ;;
        *) return 1 ;;
    esac
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$repo" "$tag" "$asset"
}
