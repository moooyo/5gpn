#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC="$ROOT/docker/docker-public-cert.sh"
INTERCEPT="$ROOT/docker/docker-intercept-cert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok: $*"; }

for helper in "$PUBLIC" "$INTERCEPT"; do
    [[ -f "$helper" && ! -L "$helper" ]] || fail "missing Docker certificate helper: $helper"
    ! grep -Eq '(^|[[:space:]])setsid([[:space:]]|$)' "$helper" \
        || fail "Docker certificate helper starts a detached process: $helper"
    ! grep -Eq '(^|[^&])&[[:space:]]*($|#)' "$helper" \
        || fail "Docker certificate helper contains a background command: $helper"
    grep -Fq 'fixed UID:GID 10001:10001' "$helper" \
        || fail "Docker certificate helper does not enforce the volume identity ABI: $helper"
done
! grep -Eq 'local[[:space:]]+role=.*root=.*\$[^[:space:]]*role' "$PUBLIC" \
    || fail "role-derived paths are expanded in the same local declaration"

for helper in "$PUBLIC" "$INTERCEPT"; do
    (
        # shellcheck disable=SC1090
        source "$helper"
        marker=.5gpn-test-owned
        value=5gpn-test-marker-v1
        root="$TMP/marker-$(basename -- "$helper")"
        mkdir "$root"
        chmod 0700 "$root"
        printf '%s\n' foreign > "$root/foreign"
        chmod 0600 "$root/foreign"
        if write_marker_if_absent "$root" "$marker" "$value" 600; then
            fail "marker helper adopted a non-empty unowned directory: $helper"
        fi
        [[ ! -e "$root/$marker" ]] \
            || fail "marker appeared in a non-empty unowned directory: $helper"

		rm -f -- "$root/foreign"
		printf '%s\n' unowned > "$root/${marker}.candidate"
		chmod 0600 "$root/${marker}.candidate"
		if write_marker_if_absent "$root" "$marker" "$value" 600; then
			fail "invalid fixed marker candidate was deleted or adopted: $helper"
		fi
		[[ "$(<"$root/${marker}.candidate")" == unowned ]] \
			|| fail "invalid fixed marker candidate was modified: $helper"
		printf '%s\n\n' "$value" > "$root/${marker}.candidate"
		if write_marker_if_absent "$root" "$marker" "$value" 600; then
			fail "marker candidate with trailing bytes was accepted: $helper"
		fi
		printf '%s\n' "$value" > "$root/${marker}.candidate"
		write_marker_if_absent "$root" "$marker" "$value" 600 \
			|| fail "fixed marker candidate did not recover: $helper"
        [[ "$(<"$root/$marker")" == "$value" \
           && ! -e "$root/${marker}.candidate" ]] \
			|| fail "marker recovery left an incomplete candidate: $helper"

		fresh="$TMP/marker-fresh-$(basename -- "$helper")"
		mkdir "$fresh"
		chmod 0700 "$fresh"
		write_marker_if_absent "$fresh" "$marker" "$value" 600 \
			|| fail "fresh marker staging did not publish: $helper"
		owned_exact_line_file "$fresh/$marker" 600 "$value" \
			|| fail "fresh marker staging published the wrong bytes: $helper"

		collision="$TMP/marker-collision-$(basename -- "$helper")"
		mkdir "$collision"
		chmod 0700 "$collision"
		printf '%s\n' foreign > "$collision/$marker"
		printf '%s\n' "$value" > "$collision/${marker}.candidate"
		chmod 0600 "$collision/$marker" "$collision/${marker}.candidate"
		if write_marker_if_absent "$collision" "$marker" "$value" 600; then
			fail "existing marker collision was overwritten: $helper"
		fi
		[[ "$(<"$collision/$marker")" == foreign \
		   && -f "$collision/${marker}.candidate" ]] \
			|| fail "marker collision changed existing state: $helper"

		repair="$TMP/mode-repair-$(basename -- "$helper")"
        mkdir "$repair"
        chmod 0700 "$repair"
        ensure_owned_directory "$repair" 750 \
            || fail "empty interrupted 0750 directory did not recover: $helper"
        [[ "$(path_mode "$repair")" == 750 ]] \
            || fail "recovered directory has the wrong mode: $helper"

        refuse="$TMP/mode-refuse-$(basename -- "$helper")"
        mkdir "$refuse"
        chmod 0700 "$refuse"
        printf '%s\n' state > "$refuse/state"
        chmod 0600 "$refuse/state"
        if ensure_owned_directory "$refuse" 750; then
            fail "populated wrong-mode directory was silently broadened: $helper"
        fi
    )
done
pass "Docker helper marker and directory creation recover only bounded empty state"

grep -Fxq 'CONFIG_FILE=/run/5gpn-bootstrap/config.env' "$PUBLIC" \
    && grep -Fxq 'CF_CREDENTIAL=/run/5gpn/cloudflare.ini' "$PUBLIC" \
    && grep -Fxq 'LE_ROOT=/etc/5gpn/letsencrypt' "$PUBLIC" \
    || fail "public helper does not use the fixed Docker config, credential, and lineage roots"
grep -Fq 'certonly' "$PUBLIC" \
    && grep -Fq -- '--dns-cloudflare' "$PUBLIC" \
    && grep -Fq -- '-d "*.${BASE_DOMAIN}"' "$PUBLIC" \
    && grep -Fq 'local -a roles=(dot console)' "$PUBLIC" \
    || fail "public helper is not one Cloudflare apex+wildcard lineage with two roles"
grep -Fq 'return 75' "$PUBLIC" \
    || fail "public bootstrap does not distinguish temporary Certbot failure"
grep -Fq 'LINEAGE_READY_MARKER=.5gpn-docker-lineage-ready' "$PUBLIC" \
    || fail "public helper has no durable first-lineage commit marker"
grep -Fq 'tombstone=".delete.${name}"' "$PUBLIC" \
    && grep -Fq 'fsync_directory "$root/generations"' "$PUBLIC" \
    || fail "role generation publication/GC has no durable tombstone protocol"
publish_roles_text="$(sed -n '/^publish_roles()/,/^}/p' "$PUBLIC")"
final_move_line="$(grep -nF 'mv -- "$stage" "$final"' <<< "$publish_roles_text" | cut -d: -f1)"
final_sync_line="$(grep -nF 'fsync_directory "$root/generations"' <<< "$publish_roles_text" | head -1 | cut -d: -f1)"
current_link_line="$(grep -nF 'ln -s -- "generations/$(basename -- "$final")"' <<< "$publish_roles_text" | cut -d: -f1)"
[[ -n "$final_move_line" && -n "$final_sync_line" && -n "$current_link_line" \
   && "$final_move_line" -lt "$final_sync_line" && "$final_sync_line" -lt "$current_link_line" ]] \
    || fail "role current can publish before its final generation directory is durable"
grep -Fq 'cert_chain_trusted "$live/cert.pem" "$live/chain.pem"' "$PUBLIC" \
    || fail "public certificate acceptance is not bound to system trust"
grep -Fq 'bash "$IOSGEN" "$DOT_DOMAIN" "$GATEWAY_IP" "$UI_DIR"' "$PUBLIC" \
    || fail "public publication does not re-sign both profiles"

grep -Fxq 'CERT_REQUEST=/etc/5gpn/mihomo/5gpn/certificate-request' "$INTERCEPT" \
    && grep -Fxq 'CERT_STATE=/etc/5gpn/intercept/cert-state' "$INTERCEPT" \
    || fail "interception helper does not use the monolith request/result paths"
grep -Fq 'rsa:3072' "$INTERCEPT" \
    && grep -Fq 'basicConstraints=critical,CA:TRUE,pathlen:0' "$INTERCEPT" \
    || fail "Docker interception CA differs from the product RSA-3072/pathlen:0 contract"
grep -Fq 'request_is_current || return 3' "$INTERCEPT" \
    && grep -Fq 'publish_state_file "$stage/ready-state"' "$INTERCEPT" \
    || fail "interception result publication is not request/attempt fenced"

(
    export DOCKER_PUBLIC_CERT_LIB_ONLY=1
    # shellcheck source=../docker/docker-public-cert.sh
    source "$PUBLIC"

    CONFIG_FILE="$TMP/public-config.env"
    CF_CREDENTIAL="$TMP/cloudflare.ini"
    LE_ROOT="$TMP/letsencrypt"
    LE_LIVE_ROOT="$LE_ROOT/live"
    LE_ARCHIVE_ROOT="$LE_ROOT/archive"
    LE_RENEWAL_ROOT="$LE_ROOT/renewal"
    LE_WORK_ROOT="$LE_ROOT/work"
    LE_LOG_ROOT="$LE_ROOT/log"
    CERT_ROOT="$TMP/cert"
    UI_DIR="$TMP/ui"
    IOSGEN="$TMP/gen-ios-profile.sh"
    LOCK_FILE="$TMP/public.lock"

    printf '%s\n' \
        'DNS_BASE_DOMAIN=example.test' \
        'DNS_GATEWAY_IP=192.0.2.10' \
        'CERT_EMAIL=owner@example.test' > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
    printf '%s\n' 'dns_cloudflare_api_token = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' > "$CF_CREDENTIAL"
    chmod 0600 "$CF_CREDENTIAL"
    load_configuration || fail "public helper rejected its three-key fixed bootstrap config"
    [[ "$BASE_DOMAIN" == example.test && "$DOT_DOMAIN" == dot.example.test \
       && "$CONSOLE_DOMAIN" == console.example.test ]] \
        || fail "public helper derived the wrong lineage or service names"
    credential_safe || fail "public helper rejected a safe fixed Cloudflare credential"

    mkdir -p "$LE_ARCHIVE_ROOT/$BASE_DOMAIN" "$LE_LIVE_ROOT/$BASE_DOMAIN" "$LE_RENEWAL_ROOT"
    chmod 0700 "$LE_ROOT" "$LE_ARCHIVE_ROOT" "$LE_ARCHIVE_ROOT/$BASE_DOMAIN" \
        "$LE_LIVE_ROOT" "$LE_LIVE_ROOT/$BASE_DOMAIN" "$LE_RENEWAL_ROOT"
    printf '%s\n' "$LE_MARKER_VALUE" > "$LE_ROOT/$LE_MARKER"
    chmod 0600 "$LE_ROOT/$LE_MARKER"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
        -subj '/CN=example.test' \
        -addext 'subjectAltName=DNS:example.test,DNS:*.example.test' \
        -keyout "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/privkey1.pem" \
        -out "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/fullchain1.pem" >/dev/null 2>&1
    chmod 0600 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/privkey1.pem"
    chmod 0644 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/fullchain1.pem"
    cp -- "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/fullchain1.pem" "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert1.pem"
    : > "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/chain1.pem"
    chmod 0644 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert1.pem" "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/chain1.pem"
    ln -s "../../archive/$BASE_DOMAIN/fullchain1.pem" "$LE_LIVE_ROOT/$BASE_DOMAIN/fullchain.pem"
    ln -s "../../archive/$BASE_DOMAIN/privkey1.pem" "$LE_LIVE_ROOT/$BASE_DOMAIN/privkey.pem"
    ln -s "../../archive/$BASE_DOMAIN/cert1.pem" "$LE_LIVE_ROOT/$BASE_DOMAIN/cert.pem"
    ln -s "../../archive/$BASE_DOMAIN/chain1.pem" "$LE_LIVE_ROOT/$BASE_DOMAIN/chain.pem"
    cat > "$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf" <<EOF
archive_dir = $LE_ARCHIVE_ROOT/$BASE_DOMAIN
cert = $LE_LIVE_ROOT/$BASE_DOMAIN/cert.pem
privkey = $LE_LIVE_ROOT/$BASE_DOMAIN/privkey.pem
chain = $LE_LIVE_ROOT/$BASE_DOMAIN/chain.pem
fullchain = $LE_LIVE_ROOT/$BASE_DOMAIN/fullchain.pem
server = $LE_PRODUCTION_SERVER
authenticator = dns-cloudflare
dns_cloudflare_credentials = $CF_CREDENTIAL
domains = example.test, *.example.test
EOF
    chmod 0600 "$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf"

    # The fixture is intentionally self-signed; production trust is asserted
    # statically above and exercised with Let's Encrypt in test-env.
    cert_chain_trusted() { return 0; }
    cert_chain_structurally_trusted() { return 0; }
    live_lineage_safe || fail "safe single-lineage fixture was rejected"
    commit_lineage_ready || fail "complete first lineage did not commit its ready marker"
    lineage_ready_safe || fail "committed first-lineage marker did not validate"
    printf '%s\n' partial > "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert2.pem"
    chmod 0644 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert2.pem"
    live_lineage_safe || fail "safe unreferenced partial Certbot generation was not recovered"
    [[ ! -e "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert2.pem" ]] \
        || fail "unreferenced partial Certbot generation survived recovery"
    for stem in cert chain fullchain privkey; do
        cp -- "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}1.pem" \
            "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}2.pem"
    done
    chmod 0644 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert2.pem" \
        "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/chain2.pem" \
        "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/fullchain2.pem"
    chmod 0600 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/privkey2.pem"
    rm -f -- "$LE_LIVE_ROOT/$BASE_DOMAIN/cert.pem"
    ln -s "../../archive/$BASE_DOMAIN/cert2.pem" "$LE_LIVE_ROOT/$BASE_DOMAIN/cert.pem"
    live_lineage_safe || fail "mixed live Certbot links did not converge to a complete generation"
    for stem in cert chain fullchain privkey; do
        [[ "$(readlink -- "$LE_LIVE_ROOT/$BASE_DOMAIN/${stem}.pem")" \
           == "../../archive/$BASE_DOMAIN/${stem}2.pem" ]] \
            || fail "mixed live links did not converge ${stem}.pem to generation 2"
    done
    for stem in cert chain fullchain privkey; do
        printf '%s\n' truncated > "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}3.pem"
        chmod 0644 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}3.pem"
        [[ "$stem" != privkey ]] || chmod 0600 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}3.pem"
    done
    live_lineage_safe || fail "unreferenced complete-name truncated generation blocked recovery"
    for stem in cert chain fullchain privkey; do
        [[ ! -e "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}3.pem" ]] \
            || fail "truncated unreferenced ${stem}3.pem survived recovery"
    done
    mkdir "$LE_LIVE_ROOT/unrelated.test"
    if lineage_set_is_exclusive; then
        fail "public helper accepted an unrelated Certbot lineage"
    fi
    rmdir "$LE_LIVE_ROOT/unrelated.test"

	mkdir -p "$CERT_ROOT/dot/generations" "$CERT_ROOT/console/generations" "$UI_DIR"
	chmod 0700 "$CERT_ROOT"
	chmod 0750 "$CERT_ROOT/dot" "$CERT_ROOT/console" \
		"$CERT_ROOT/dot/generations" "$CERT_ROOT/console/generations"
	for role in dot console; do
		printf '%s\n' "${CERT_ROLE_VALUE_PREFIX}:${role}" \
			> "$CERT_ROOT/$role/$CERT_ROLE_MARKER"
		chmod 0600 "$CERT_ROOT/$role/$CERT_ROLE_MARKER"
	done
	chmod 0755 "$UI_DIR"
    printf '%s\n' "$UI_MARKER_VALUE" > "$UI_DIR/$UI_MARKER"
    chmod 0644 "$UI_DIR/$UI_MARKER"
    cat > "$IOSGEN" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'signed-dot:%s:%s\n' "$1" "$2" > "$3/ios-dot.mobileconfig"
printf 'signed-ca:%s\n' "$1" > "$3/ios-intercept-ca.mobileconfig"
chmod 0644 "$3/ios-dot.mobileconfig" "$3/ios-intercept-ca.mobileconfig"
EOF
    chmod 0755 "$IOSGEN"

    publish_roles || fail "public helper could not publish both role generations"
    [[ "$_ROLES_CHANGED" == 1 ]] || fail "first role publication was not reported"
    for role in dot console; do
        [[ -L "$CERT_ROOT/$role/current" ]] || fail "$role current is not an atomic symlink"
        cmp -s "$LE_LIVE_ROOT/$BASE_DOMAIN/fullchain.pem" "$CERT_ROOT/$role/current/fullchain.pem" \
            || fail "$role certificate differs from the canonical lineage"
        cmp -s "$LE_LIVE_ROOT/$BASE_DOMAIN/privkey.pem" "$CERT_ROOT/$role/current/privkey.pem" \
            || fail "$role key differs from the canonical lineage"
    done
    publish_profiles || fail "public helper did not publish both signed profile files"
    current_before="$(readlink -- "$CERT_ROOT/dot/current")"
    current_name="${current_before#generations/}"
    mv -- "$CERT_ROOT/dot/generations/$current_name" \
        "$CERT_ROOT/dot/generations/.delete.$current_name"
    if purge_generation_candidate dot ".delete.$current_name"; then
        fail "role tombstone GC deleted the material named by current"
    fi
    [[ -d "$CERT_ROOT/dot/generations/.delete.$current_name" ]] \
        || fail "current-target tombstone disappeared after fail-closed refusal"
    mv -- "$CERT_ROOT/dot/generations/.delete.$current_name" \
        "$CERT_ROOT/dot/generations/$current_name"
    old_name=generation-20000101T000000Z-1-1
    mkdir "$CERT_ROOT/dot/generations/$old_name"
    chmod 0750 "$CERT_ROOT/dot/generations/$old_name"
    cp -- "$CERT_ROOT/dot/current/fullchain.pem" \
        "$CERT_ROOT/dot/generations/$old_name/fullchain.pem"
    cp -- "$CERT_ROOT/dot/current/privkey.pem" \
        "$CERT_ROOT/dot/generations/$old_name/privkey.pem"
    chmod 0640 "$CERT_ROOT/dot/generations/$old_name/fullchain.pem" \
        "$CERT_ROOT/dot/generations/$old_name/privkey.pem"
    # Bash locals are dynamically scoped. A caller's stale role must never be
    # consumed while deriving the callee's root in the same local declaration.
    role=console
    remove_generation dot "$old_name" || fail "old role generation tombstone GC failed"
    [[ ! -e "$CERT_ROOT/dot/generations/$old_name" \
       && ! -e "$CERT_ROOT/dot/generations/.delete.$old_name" \
       && "$(readlink -- "$CERT_ROOT/dot/current")" == "$current_before" ]] \
        || fail "role generation GC changed current or retained its tombstone"
    tomb_name=.delete.generation-20000101T000001Z-1-2
    mkdir "$CERT_ROOT/dot/generations/$tomb_name"
    chmod 0750 "$CERT_ROOT/dot/generations/$tomb_name"
    cp -- "$CERT_ROOT/dot/current/fullchain.pem" \
        "$CERT_ROOT/dot/generations/$tomb_name/fullchain.pem"
    chmod 0640 "$CERT_ROOT/dot/generations/$tomb_name/fullchain.pem"
    scrub_role_candidates dot || fail "interrupted role tombstone did not resume safely"
    [[ ! -e "$CERT_ROOT/dot/generations/$tomb_name" \
       && "$(readlink -- "$CERT_ROOT/dot/current")" == "$current_before" ]] \
        || fail "interrupted tombstone recovery changed current or remained partial"
    publish_roles || fail "idempotent public role publication failed"
    [[ "$_ROLES_CHANGED" == 0 ]] || fail "unchanged lineage needlessly republished role generations"

    ensure_layout() { return 0; }
    credential_safe() { return 0; }
    lineage_set_is_exclusive() { return 0; }
    lineage_ready_exists() { return 1; }
    lineage_ready_safe() { return 1; }
    live_lineage_safe() { return 1; }
    lineage_artifacts_exist() { return 1; }
    run_certbot_bootstrap() { return 1; }
    rc=0
    bootstrap_public_certificate >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 75 ]] \
        || fail "temporary Certbot bootstrap failure did not return EX_TEMPFAIL"
)
pass "Docker public certificate helper enforces one lineage and atomic role/profile publication"

(
    source "$PUBLIC"
    BASE_DOMAIN=partial.example.test
    LE_ROOT="$TMP/partial-letsencrypt"
    LE_LIVE_ROOT="$LE_ROOT/live"
    LE_ARCHIVE_ROOT="$LE_ROOT/archive"
    LE_RENEWAL_ROOT="$LE_ROOT/renewal"
    CERT_ROOT="$TMP/partial-cert"
    mkdir -p "$LE_LIVE_ROOT/$BASE_DOMAIN" "$LE_ARCHIVE_ROOT/$BASE_DOMAIN" \
        "$LE_RENEWAL_ROOT" "$LE_ROOT/accounts/keep" "$CERT_ROOT/dot" "$CERT_ROOT/console"
    chmod 0700 "$LE_ROOT" "$LE_LIVE_ROOT" "$LE_LIVE_ROOT/$BASE_DOMAIN" \
        "$LE_ARCHIVE_ROOT" "$LE_ARCHIVE_ROOT/$BASE_DOMAIN" "$LE_RENEWAL_ROOT" \
        "$CERT_ROOT" "$CERT_ROOT/dot" "$CERT_ROOT/console"
    printf '%s\n' "$LE_MARKER_VALUE" > "$LE_ROOT/$LE_MARKER"
    printf '%s\n' keep > "$LE_ROOT/accounts/keep/account.json"
    printf '%s\n' partial > "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert1.pem"
    printf '%s\n' partial > "$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf"
    chmod 0600 "$LE_ROOT/$LE_MARKER" "$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf"
    chmod 0644 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert1.pem"
    ln -s "../../archive/$BASE_DOMAIN/cert1.pem" "$LE_LIVE_ROOT/$BASE_DOMAIN/cert.pem"
    reset_unpublished_partial_lineage \
        || fail "uncommitted first-boot partial lineage could not be safely reset"
    [[ -f "$LE_ROOT/accounts/keep/account.json" \
       && ! -e "$LE_LIVE_ROOT/$BASE_DOMAIN" \
       && ! -e "$LE_ARCHIVE_ROOT/$BASE_DOMAIN" \
       && ! -e "$LE_RENEWAL_ROOT/$BASE_DOMAIN.conf" ]] \
        || fail "first-boot partial reset removed accounts or retained lineage fragments"

    mkdir -p "$LE_LIVE_ROOT/$BASE_DOMAIN" "$LE_ARCHIVE_ROOT/$BASE_DOMAIN"
    chmod 0700 "$LE_LIVE_ROOT/$BASE_DOMAIN" "$LE_ARCHIVE_ROOT/$BASE_DOMAIN"
    for stem in cert chain fullchain privkey; do
        printf '%s\n' interrupted > "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}1.pem"
        chmod 0644 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}1.pem"
        [[ "$stem" != privkey ]] || chmod 0600 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/${stem}1.pem"
        ln -s "../../archive/$BASE_DOMAIN/${stem}1.pem" \
            "$LE_LIVE_ROOT/$BASE_DOMAIN/${stem}.pem"
    done
    reset_unpublished_partial_lineage \
        || fail "complete filenames without committed renewal metadata could not be reset"
    [[ -f "$LE_ROOT/accounts/keep/account.json" \
       && ! -e "$LE_LIVE_ROOT/$BASE_DOMAIN" \
       && ! -e "$LE_ARCHIVE_ROOT/$BASE_DOMAIN" ]] \
        || fail "complete-name first-boot reset removed accounts or retained lineage fragments"

    mkdir -p "$LE_ARCHIVE_ROOT/$BASE_DOMAIN"
    chmod 0700 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN"
    printf '%s\n' partial > "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert1.pem"
    chmod 0644 "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert1.pem"
    printf '%s\n' "${LINEAGE_READY_VALUE_PREFIX}:${BASE_DOMAIN}" \
        > "$LE_ROOT/$LINEAGE_READY_MARKER"
    chmod 0600 "$LE_ROOT/$LINEAGE_READY_MARKER"
    if reset_unpublished_partial_lineage; then
        fail "committed lineage marker allowed destructive partial reset"
    fi
    [[ -f "$LE_ARCHIVE_ROOT/$BASE_DOMAIN/cert1.pem" ]] \
        || fail "ready lineage material changed after fail-closed reset refusal"
)
pass "Docker public lineage ready marker fences first-boot cleanup from committed state"

(
    export DOCKER_INTERCEPT_CERT_LIB_ONLY=1
    # shellcheck source=../docker/docker-intercept-cert.sh
    source "$INTERCEPT"

    CONFIG_ROOT="$TMP/intercept-config"
    CA_DIR="$CONFIG_ROOT/intercept-ca"
    INTERCEPT_DIR="$CONFIG_ROOT/intercept"
    TLS_DIR="$INTERCEPT_DIR/tls"
    CERT_STATE="$INTERCEPT_DIR/cert-state"
    CERT_REQUEST_DIR="$CONFIG_ROOT/mihomo/5gpn"
    CERT_REQUEST="$CERT_REQUEST_DIR/certificate-request"
    LOCK_FILE="$TMP/intercept.lock"
    stage="$TMP/intercept-stage"

    mkdir -p "$CA_DIR" "$TLS_DIR" "$CERT_REQUEST_DIR" "$stage"
    chmod 0700 "$CA_DIR" "$stage"
    chmod 0750 "$INTERCEPT_DIR" "$TLS_DIR" "$CERT_REQUEST_DIR"
    printf '%s\n' "$CA_MARKER_VALUE" > "$CA_DIR/$CA_MARKER"
    printf '%s\n' "$INTERCEPT_MARKER_VALUE" > "$INTERCEPT_DIR/$INTERCEPT_MARKER"
    chmod 0644 "$CA_DIR/$CA_MARKER"
    chmod 0600 "$INTERCEPT_DIR/$INTERCEPT_MARKER"
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
        -subj '/CN=5gpn Interception Root' \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -keyout "$CA_DIR/root.key" -out "$CA_DIR/root.crt" >/dev/null 2>&1
    chmod 0600 "$CA_DIR/root.key"
    chmod 0644 "$CA_DIR/root.crt"
    validate_root || fail "Docker helper rejected the product interception CA contract"

    write_request() {
        local attempt="$1" host digest json="" separator="" host_file="$TMP/docker-hosts"
        shift
        : > "$host_file"
        for host in "$@"; do
            printf '%s\n' "$host" >> "$host_file"
            json="${json}${separator}\"${host}\""
            separator=,
        done
        if [[ -s "$host_file" ]]; then
            digest="$(file_sha256 "$host_file")"
        else
            digest="$(printf '\n' | sha256sum | cut -d' ' -f1)"
        fi
        printf '{"version":1,"target_digest":"%s","attempt":"%s","hosts":[%s]}' \
            "$digest" "$attempt" "$json" > "$CERT_REQUEST"
        chmod 0644 "$CERT_REQUEST"
    }

    ATTEMPT_A=11111111111111111111111111111111
    ATTEMPT_B=22222222222222222222222222222222
    write_request "$ATTEMPT_A" '*.example.test' api.example.test
    load_desired_hosts || fail "Docker helper rejected a valid fenced request"
    generate_candidate || fail "Docker helper could not mint an exact-SAN leaf"
    publish_certificate_candidate || fail "Docker helper could not commit leaf then hash-bound state"
    validate_committed_ready 60 || fail "Docker helper rejected its complete committed result"
    [[ "$(<"$CERT_STATE")" == *"\"attempt\":\"$ATTEMPT_A\""* \
       && "$(<"$CERT_STATE")" == *'"certificate_sha256"'* \
       && "$(<"$CERT_STATE")" == *'"private_key_sha256"'* ]] \
        || fail "committed interception state is not attempt/hash bound"

    load_desired_hosts || fail "could not restore attempt A snapshot"
    before="$(<"$CERT_STATE")"
    write_request "$ATTEMPT_B" '*.example.test' api.example.test
    if request_is_current; then
        fail "stale attempt A remained current after attempt B publication"
    fi
    [[ "$(<"$CERT_STATE")" == "$before" ]] \
        || fail "publishing a newer request mutated the prior committed result"
    load_desired_hosts || fail "attempt B request did not parse"
    validate_live_material 60 || fail "same-digest retry could not reuse exact live material"
    render_ready_state "$stage/ready-b" "$material_certificate_hash" "$material_private_key_hash"
    publish_state_file "$stage/ready-b" || fail "same-digest retry did not commit under its new attempt"
    validate_committed_ready 60 || fail "attempt B hash-bound result did not become authoritative"
)
pass "Docker interception helper preserves exact SANs, fencing, and final hash-bound commit"

echo "Docker certificate helpers: PASS"
