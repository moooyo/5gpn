#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC="$ROOT/docker/docker-public-cert.sh"
INTERCEPT="$ROOT/docker/docker-intercept-cert.sh"
IOS_PROFILE="$ROOT/scripts/gen-ios-profile.sh"
TMP="$(mktemp -d /tmp/5gpn-docker-cert.XXXXXX)"
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
    ! grep -Eq '^(ensure_owned_directory|write_marker_if_absent)\(\)' "$helper" \
        || fail "runtime helper can recreate a missing v2 ownership root: $helper"
done
pass "Docker runtime helpers require the image-seeded v2 ownership roots"

grep -Fxq 'CONFIG_FILE=/run/5gpn-bootstrap/config.env' "$PUBLIC" \
    && grep -Fxq 'CF_CREDENTIAL=/run/5gpn/cloudflare.ini' "$PUBLIC" \
    && grep -Fxq 'LE_ROOT=/etc/5gpn/letsencrypt' "$PUBLIC" \
    || fail "public helper does not use the fixed Docker config, credential, and lineage roots"
grep -Fq 'certonly' "$PUBLIC" \
    && grep -Fq -- '--dns-cloudflare' "$PUBLIC" \
    && grep -Fq -- '-d "*.${BASE_DOMAIN}"' "$PUBLIC" \
    && grep -Fq 'cert_role_ctl_publish_pair' "$PUBLIC" \
    || fail "public helper is not one Cloudflare apex+wildcard lineage with two roles"
grep -Fq 'return 75' "$PUBLIC" \
    || fail "public bootstrap does not distinguish temporary Certbot failure"
grep -Fq 'LINEAGE_READY_MARKER=.5gpn-docker-lineage-ready' "$PUBLIC" \
    || fail "public helper has no durable first-lineage commit marker"
grep -Fq 'cert_role_ctl_remove_generation' "$ROOT/scripts/cert-role-ctl.sh" \
    && grep -Fq 'publication_fs_commit_relative_pointer' "$ROOT/scripts/cert-role-ctl.sh" \
    || fail "shared role publication/GC has no durable pointer and tombstone protocol"
publish_roles_text="$(sed -n '/^publish_roles()/,/^}/p' "$PUBLIC")"
grep -Fq 'cert_role_ctl_repair_recoverable_tree' <<< "$publish_roles_text" \
    && grep -Fq 'cert_role_ctl_publish_pair' <<< "$publish_roles_text" \
    && ! grep -Fq 'rollback' <<< "$publish_roles_text" \
    || fail "Docker role publication bypasses the shared repair-forward publisher"
grep -Fq 'cert_chain_trusted "$live/cert.pem" "$live/chain.pem"' "$PUBLIC" \
    || fail "public certificate acceptance is not bound to system trust"
grep -Fq 'ui_generation_stage_tree "$UI_DIR" "$UI_SOURCE" "$version"' "$PUBLIC" \
    && grep -Fq 'ui_generation_clone_current "$UI_DIR"' "$PUBLIC" \
    && grep -Fq 'ui_generation_publish "$UI_DIR" "$candidate"' "$PUBLIC" \
    && grep -Fq 'bash "$IOSGEN" "$DOT_DOMAIN" "$GATEWAY_IP" "$candidate"' "$PUBLIC" \
    && grep -Fq 'profiles_match_live_inputs "$current"' "$PUBLIC" \
    && grep -Fq 'dot_signer_leaf_sha256' "$PUBLIC" \
    && grep -Fq 'intercept_ca_der_sha256' "$PUBLIC" \
    || fail "public publication does not use the complete idempotent UI generation transaction"
grep -Fq 'ui_generation_cleanup_orphan_candidates "$UI_DIR"' "$PUBLIC" \
    && grep -Fq 'profile_stage_parent=/run/5gpn' "$IOS_PROFILE" \
    && grep -Fq 'stage_dir="$(mktemp -d "${profile_stage_parent}/.ios-profile.XXXXXX")"' "$IOS_PROFILE" \
    || fail "Docker profile signing can leave private staging material in the persistent UI volume"

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
    UI_SOURCE="$TMP/ui-source"
    UI_GENERATION_HELPER="$ROOT/scripts/ui-generation.sh"
    PUBLICATION_FS_HELPER="$ROOT/scripts/publication-fs.sh"
    CERT_ROLE_HELPER="$ROOT/scripts/cert-role-ctl.sh"
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

	mkdir -p "$CERT_ROOT/dot/generations" "$CERT_ROOT/console/generations" \
        "$UI_DIR" "$UI_SOURCE/assets"
	chmod 0751 "$CERT_ROOT"
	chmod 0750 "$CERT_ROOT/dot" "$CERT_ROOT/console" \
		"$CERT_ROOT/dot/generations" "$CERT_ROOT/console/generations"
	printf '%s\n' 5gpn-config > "$TMP/.5gpn-owned"
	chmod 0644 "$TMP/.5gpn-owned"
	printf '%s\n' "$CERT_ROOT_MARKER_VALUE" > "$CERT_ROOT/$CERT_ROOT_MARKER"
	chmod 0644 "$CERT_ROOT/$CERT_ROOT_MARKER"
	for role in dot console; do
		printf '%s\n' "${CERT_ROLE_VALUE_PREFIX}:${role}" \
			> "$CERT_ROOT/$role/$CERT_ROLE_MARKER"
		chmod 0644 "$CERT_ROOT/$role/$CERT_ROLE_MARKER"
	done
	chmod 0755 "$UI_DIR"
    printf '%s\n' '<!doctype html><title>fixture</title>' > "$UI_SOURCE/index.html"
    printf '%s\n' 'console.log("fixture")' > "$UI_SOURCE/assets/app.js"
    chmod 0755 "$UI_SOURCE" "$UI_SOURCE/assets"
    chmod 0644 "$UI_SOURCE/index.html" "$UI_SOURCE/assets/app.js"
    # Load the real generation functions through the test path. The production
    # loader separately pins root-owned /opt metadata before sourcing it.
    source "$UI_GENERATION_HELPER"
    UI_HELPER_LOADED=1
    component_value() {
        [[ "$1" == ZASH_VERSION ]] || return 1
        printf '%s' v-test
    }
    cat > "$IOSGEN" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'signed-dot:%s:%s\n' "$1" "$2" > "$3/ios-dot.mobileconfig"
printf 'signed-ca:%s\n' "$1" > "$3/ios-intercept-ca.mobileconfig"
dot_digest="$(sha256sum "$3/ios-dot.mobileconfig" | awk '{print $1}')"
ca_digest="$(sha256sum "$3/ios-intercept-ca.mobileconfig" | awk '{print $1}')"
printf '%s\n' \
    'version=1' \
    "dot_signer_leaf_sha256=$(printf leaf | sha256sum | awk '{print $1}')" \
    "dot_public_key_sha256=$(printf key | sha256sum | awk '{print $1}')" \
    "intercept_ca_der_sha256=$(printf ca | sha256sum | awk '{print $1}')" \
    "domain=$1" \
    "gateway_ipv4=$2" \
    "ios_dot_sha256=$dot_digest" \
    "ios_intercept_ca_sha256=$ca_digest" > "$3/.5gpn-profile-inputs"
chmod 0644 "$3/ios-dot.mobileconfig" "$3/ios-intercept-ca.mobileconfig" \
    "$3/.5gpn-profile-inputs"
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
    publish_profiles || fail "public helper did not publish a complete Console/profile generation"
    [[ -L "$UI_DIR/current" ]] || fail "Console current is not an atomic generation symlink"
    current_ui="$(ui_generation_current_path "$UI_DIR")" \
        || fail "published Console current did not validate"
    [[ -f "$current_ui/index.html" \
       && -f "$current_ui/assets/app.js" \
       && -f "$current_ui/ios-dot.mobileconfig" \
       && -f "$current_ui/ios-intercept-ca.mobileconfig" \
       && -f "$current_ui/.5gpn-profile-inputs" \
       && ! -e "$UI_DIR/ios-dot.mobileconfig" \
       && ! -e "$UI_DIR/ios-intercept-ca.mobileconfig" ]] \
        || fail "published Console generation is flat or incomplete"
    current_ui_target="$(readlink -- "$UI_DIR/current")"
    profiles_match_live_inputs() { return 0; }
    publish_profiles || fail "matching profile inputs did not remain idempotent"
    [[ "$(readlink -- "$UI_DIR/current")" == "$current_ui_target" ]] \
        || fail "matching profile inputs needlessly switched Console current"
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
