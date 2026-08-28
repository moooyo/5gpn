#!/usr/bin/env bash
# Static contract for the single-image, single-container Docker delivery.
# Real cgroup/worker behavior belongs only to tests/container-acceptance.sh on
# test-env; this suite must never turn textual checks into a runtime claim.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="$ROOT/Dockerfile"
COMPOSE="$ROOT/compose.yaml"
ENTRYPOINT="$ROOT/docker/entrypoint.sh"
PREPARE="$ROOT/docker/prepare-components.sh"
SECCOMP="$ROOT/docker/seccomp-5gpn.json"
BOOTSTRAP_EXAMPLE="$ROOT/docker/bootstrap/config.env.example"
PINS_ENV="$ROOT/release/pins.env"
PINS_LIBRARY="$ROOT/release/pins.sh"
MIHOMO_TEMPLATE="$ROOT/etc/mihomo/config.yaml.tmpl"
CHECKS="$ROOT/.github/workflows/checks.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
DOCKER_GUIDE="$ROOT/docs/docker.md"
FAIL=0

pass() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

required=(
    Dockerfile
    compose.yaml
    .dockerignore
    docker/entrypoint.sh
    docker/prepare-components.sh
    docker/docker-public-cert.sh
    docker/docker-intercept-cert.sh
    docker/seccomp-5gpn.json
    docker/bootstrap/config.env.example
    release/pins.env
    release/pins.sh
    scripts/publication-fs.sh
    scripts/cert-role-ctl.sh
    scripts/ui-generation.sh
    docs/docker.md
    tests/container-acceptance.sh
    tests/docker/probe-lib.sh
    tests/docker/extension-worker-probe.sh
    tests/docker/public-certificate-hot-reload.sh
    tests/docker/recreate-container.sh
)
for path in "${required[@]}"; do
    [[ -f "$ROOT/$path" && ! -L "$ROOT/$path" ]] \
        || fail "required Docker delivery file is missing or symlinked: $path"
done

if grep -Fxq '# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e' "$DOCKERFILE" \
   && grep -Eq '^FROM --platform=linux/amd64 debian:13-slim@sha256:[0-9a-f]{64}$' "$DOCKERFILE" \
   && grep -Fxq 'ENV DEBIAN_SNAPSHOT=20260809T000000Z' "$DOCKERFILE" \
   && grep -Fq 'snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/' "$DOCKERFILE" \
   && grep -Fxq 'USER 10001:10001' "$DOCKERFILE" \
   && grep -Fq 'FIVEGPN_RUNTIME=container' "$DOCKERFILE" \
   && grep -Fxq 'VOLUME ["/etc/5gpn", "/opt/5gpn/ui"]' "$DOCKERFILE" \
   && awk '
        /install -d -o 10001 -g 10001 -m 0755/ { inside=1; next }
        inside && /\/opt\/5gpn\/ui/ { found=1 }
        inside && $0 !~ /\\$/ { inside=0 }
        END { exit !found }
      ' "$DOCKERFILE" \
   && grep -Fq 'scripts/ui-generation.sh /opt/5gpn/scripts/ui-generation.sh' "$DOCKERFILE" \
   && grep -Fq 'ENTRYPOINT ["/opt/5gpn/bin/docker-entrypoint.sh"]' "$DOCKERFILE"; then
    pass "image platform, identity, persistent roots, and PID-1 entrypoint are fixed"
else
    fail "Dockerfile does not lock the initial Linux amd64 runtime identity"
fi

if grep -Fq 'docker/build/components/5gpn-mihomo' "$DOCKERFILE" \
   && grep -Fq 'docker/build/components/manifest.env' "$DOCKERFILE" \
   && grep -Fq 'docker/build/components/ui/' "$DOCKERFILE" \
   && grep -Fq 'docker/build/components/bootstrap-ca.pem' "$DOCKERFILE" \
   && grep -Fq 'COPY --chmod=0644 LICENSE THIRD_PARTY_NOTICES.md /usr/share/doc/5gpn/' "$DOCKERFILE" \
   && ! grep -Eiq '^[[:space:]]*(RUN.*(curl|wget)|ADD[[:space:]]+https?://)' "$DOCKERFILE"; then
    pass "Dockerfile consumes only preverified component inputs"
else
    fail "Dockerfile downloads components or bypasses the prepared manifest"
fi

if grep -Fq 'COPY --chmod=0644 LICENSE THIRD_PARTY_NOTICES.md /usr/share/doc/5gpn/' "$DOCKERFILE" \
   && grep -Fxq '!LICENSE' "$ROOT/.dockerignore" \
   && grep -Fxq '!THIRD_PARTY_NOTICES.md' "$ROOT/.dockerignore"; then
    pass "image includes the project license and complete third-party notices"
else
    fail "image omits its license delivery or excludes the notice inputs"
fi

if grep -Fxq 'PINS_ENV="$ROOT/release/pins.env"' "$PREPARE" \
   && grep -Fxq 'PINS_LIBRARY="$ROOT/release/pins.sh"' "$PREPARE" \
   && grep -Fq 'source "$PINS_LIBRARY"' "$PREPARE" \
   && grep -Fq 'load_release_pins "$PINS_ENV"' "$PREPARE" \
   && grep -Fq 'release_download_url mihomo' "$PREPARE" \
   && grep -Fq 'release_download_url zashboard' "$PREPARE" \
   && grep -Fq 'release_artifact_sha256 mihomo' "$PREPARE" \
   && grep -Fq 'release_artifact_sha256 zashboard' "$PREPARE" \
   && grep -Fq 'verify_digest "$stage/mihomo.gz" "$MIHOMO_SHA256"' "$PREPARE" \
   && grep -Fq 'verify_digest "$stage/zashboard.zip" "$ZASH_SHA256"' "$PREPARE" \
   && grep -Fq 'verify_digest "$stage/bootstrap-ca.pem" "$CA_BUNDLE_SHA256"' "$PREPARE" \
   && grep -Fq '"$binary" 5gpn-container-contract' "$PREPARE" \
   && grep -Fq "printf '%s\\n' '5gpn-container-runtime-v2' | cmp -s - \"\$output\"" "$PREPARE" \
   && grep -Fq 'MIHOMO_CONTAINER_CONTRACT=5gpn-container-runtime-v2' "$PREPARE" \
   && grep -Fq 'CA_BUNDLE_SHA256=' "$PREPARE" \
   && grep -Fq 'manifest.env' "$PREPARE" \
   && ! grep -Fq 'read_pin ' "$PREPARE" \
   && ! grep -Fq 'install.sh' "$PREPARE"; then
    pass "Docker preparation consumes the centralized pins and requires runtime contract v2"
else
    fail "Docker preparation bypasses the centralized pin generation or v2 handshake"
fi

service_count="$(awk '
    /^services:[[:space:]]*$/ { in_services=1; next }
    in_services && /^[^[:space:]]/ { exit }
    in_services && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { count++ }
    END { print count+0 }
' "$COMPOSE")"
if [[ "$service_count" == 1 ]] && grep -Fxq '  gateway:' "$COMPOSE"; then
    pass "Compose defines exactly one gateway service"
else
    fail "Compose must define one gateway service and no sidecars"
fi

compose_required=(
    '    image: ${FIVEGPN_IMAGE:?set FIVEGPN_IMAGE to the exact ghcr.io/moooyo/5gpn tag@sha256:REPLACE_WITH_RELEASE_MANIFEST_DIGEST reference from the GitHub Release body}'
    '    user: "10001:10001"'
    '    ports:'
    '      - "0.0.0.0:853:853/tcp"'
    '      - "0.0.0.0:80:80/tcp"'
    '      - "0.0.0.0:443:9443/tcp"'
    '      - "0.0.0.0:443:9443/udp"'
    '      - "0.0.0.0:8080:8080/tcp"'
    '      - "0.0.0.0:8443:8443/tcp"'
    '    sysctls:'
    '      net.ipv4.ip_unprivileged_port_start: "0"'
    '    cgroup: private'
    '    init: false'
    '    read_only: true'
    '      - ALL'
    '      - writable-cgroups=true'
    '      - no-new-privileges=true'
    '      - seccomp=./docker/seccomp-5gpn.json'
    '    restart: unless-stopped'
    '    stop_grace_period: 45s'
    '        source: fivegpn-data'
    '        target: /etc/5gpn'
    '        source: fivegpn-ui'
    '        target: /opt/5gpn/ui'
    '    name: ${FIVEGPN_DATA_VOLUME:-fivegpn-data}'
    '    name: ${FIVEGPN_UI_VOLUME:-fivegpn-ui}'
    '  cloudflare_api_token:'
    'networks:'
    '    driver: bridge'
    '    enable_ipv6: false'
)
for contract in "${compose_required[@]}"; do
    grep -Fxq "$contract" "$COMPOSE" \
        || fail "Compose contract is missing: $contract"
done
port_mapping_count="$(grep -Ec '^      - "0\.0\.0\.0:[0-9]+:[0-9]+/(tcp|udp)"$' "$COMPOSE")"
if [[ "$port_mapping_count" == 6 ]] \
   && ! grep -Eq '^      - "0\.0\.0\.0:(53|5353|5354):' "$COMPOSE" \
   && ! grep -Eq '^      - "0\.0\.0\.0:[0-9]+:(53|5353|5354|443|5060)/(tcp|udp)"$' "$COMPOSE" \
   && ! grep -Fq '/opt/5gpn/ui:uid=10001' "$COMPOSE" \
   && ! grep -Eiq 'network_mode:|cap_add:|NET_BIND_SERVICE|privileged:[[:space:]]*true|SYS_ADMIN|seccomp[=:]unconfined|docker\.sock|/sys/fs/cgroup|FIVEGPN_IMAGE:-.*latest' "$COMPOSE"; then
    pass "Compose publishes six IPv4 mappings, persists both state roots, and grants no privilege escape"
else
    fail "Compose widened its IPv4-only port, privilege, network, or image boundary"
fi

main_body="$(sed -n '/^main()/,/^}/p' "$ENTRYPOINT")"
legacy_line="$(grep -nF 'reject_legacy_footprints' <<<"$main_body" | tail -1 | cut -d: -f1)"
config_candidates_line="$(grep -nF 'validate_config_candidates' <<<"$main_body" | tail -1 | cut -d: -f1)"
publication_candidates_line="$(grep -nF 'validate_publication_candidates' <<<"$main_body" | tail -1 | cut -d: -f1)"
state_line="$(grep -nF 'validate_runtime_documents' <<<"$main_body" | tail -1 | cut -d: -f1)"
ui_line="$(grep -nF 'validate_existing_ui_generation' <<<"$main_body" | tail -1 | cut -d: -f1)"
inspect_line="$(grep -nF 'inspect_existing_operator_config' <<<"$main_body" | tail -1 | cut -d: -f1)"
cert_preflight_line="$(grep -nF 'preflight_certificate_state' <<<"$main_body" | tail -1 | cut -d: -f1)"
config_scrub_line="$(grep -nF 'scrub_config_candidates' <<<"$main_body" | tail -1 | cut -d: -f1)"
publication_scrub_line="$(grep -nF 'scrub_publication_candidates' <<<"$main_body" | tail -1 | cut -d: -f1)"
publish_line="$(grep -nF 'ensure_dns_env' <<<"$main_body" | tail -1 | cut -d: -f1)"
cert_line="$(grep -nF 'run_sync "$INTERCEPT_CERT_HELPER" init-ca' <<<"$main_body" | tail -1 | cut -d: -f1)"
public_cert_line="$(grep -nF 'bootstrap_public_certificate' <<<"$main_body" | tail -1 | cut -d: -f1)"
if grep -Fq 'exec "$MIHOMO_BIN"' "$ENTRYPOINT" \
   && grep -Fq 'wait "$child_pid"' "$ENTRYPOINT" \
   && grep -Fq 'readable_input_file "$BOOTSTRAP_INPUT"' "$ENTRYPOINT" \
   && grep -Fq 'readable_input_file "$CF_SECRET"' "$ENTRYPOINT" \
   && grep -Fq 'Docker supports only CERT_MODE=cloudflare.' "$ENTRYPOINT" \
   && grep -Fq '5gpn-container-runtime-v2' "$ENTRYPOINT" \
   && grep -Fq '5gpn-state validate --owner-uid "$CURRENT_UID"' "$ENTRYPOINT" \
   && grep -Fq '5gpn-config inspect-controller' "$ENTRYPOINT" \
   && grep -Fq -- '--owner-uid "$CURRENT_UID" --config "$MIHOMO_CONFIG"' "$ENTRYPOINT" \
   && grep -Fq '.version == 2' "$ENTRYPOINT" \
   && grep -Fq '.external_ui == "/opt/5gpn/ui/current"' "$ENTRYPOINT" \
   && grep -Fq 'DOCKER_SCHEMA_MARKER_VALUE=5gpn-docker-state-v2' "$ENTRYPOINT" \
   && grep -Fq 'DNS_BASE_DOMAIN|DNS_PUBLIC_IP|DNS_GATEWAY_IP|DNS_MIHOMO_LISTEN_IPS|CERT_MODE|CERT_EMAIL' "$ENTRYPOINT" \
   && ! grep -Fq 'DNS_MIHOMO_SECRET' "$ENTRYPOINT" \
   && ! grep -Fq 'DNS_MIHOMO_SECRET' "$BOOTSTRAP_EXAMPLE" \
   && grep -Fxq 'readonly DOCKER_LISTEN_IP=0.0.0.0' "$ENTRYPOINT" \
   && grep -Fxq 'readonly DOCKER_TLS_LISTEN_PORT=9443' "$ENTRYPOINT" \
   && grep -Fq 'port: %s, network: [tcp, udp], target: %s:443' "$ENTRYPOINT" \
   && grep -Fq '"$DOCKER_LISTEN_IP" "$DOCKER_TLS_LISTEN_PORT" "$CONSOLE_DOMAIN"' "$ENTRYPOINT" \
   && ! grep -Fq 'port: 5060' "$ENTRYPOINT" \
   && ! grep -Fq 'IP-CIDR,' "$ENTRYPOINT" \
   && grep -Fq 'external-ui: /opt/5gpn/ui/current' "$MIHOMO_TEMPLATE" \
   && [[ "$legacy_line" =~ ^[0-9]+$ \
      && "$config_candidates_line" =~ ^[0-9]+$ \
      && "$publication_candidates_line" =~ ^[0-9]+$ \
      && "$state_line" =~ ^[0-9]+$ && "$ui_line" =~ ^[0-9]+$ \
      && "$inspect_line" =~ ^[0-9]+$ \
      && "$cert_preflight_line" =~ ^[0-9]+$ \
      && "$config_scrub_line" =~ ^[0-9]+$ \
      && "$publication_scrub_line" =~ ^[0-9]+$ \
      && "$publish_line" =~ ^[0-9]+$ && "$cert_line" =~ ^[0-9]+$ \
      && "$public_cert_line" =~ ^[0-9]+$ \
      && "$config_candidates_line" -lt "$config_scrub_line" \
      && "$publication_candidates_line" -lt "$publication_scrub_line" \
      && "$legacy_line" -lt "$publish_line" && "$state_line" -lt "$publish_line" \
      && "$ui_line" -lt "$publish_line" && "$inspect_line" -lt "$publish_line" \
      && "$state_line" -lt "$config_scrub_line" \
      && "$ui_line" -lt "$publication_scrub_line" \
      && "$inspect_line" -lt "$config_scrub_line" \
      && "$cert_preflight_line" -lt "$cert_line" \
      && "$config_scrub_line" -lt "$cert_line" \
      && "$publication_scrub_line" -lt "$cert_line" \
      && "$cert_line" -lt "$public_cert_line" \
      && "$public_cert_line" -lt "$publish_line" ]]; then
    pass "entrypoint performs the current read-only preflight before any state or certificate publication"
else
    fail "entrypoint bypasses the v2 state, controller, legacy, UI, or publication boundary"
fi

# The controller secret is printed so a first-time operator can reach the
# Console without an owner-scoped Core inspection they would have to look up.
# It must be printed only from the branch that generates it: a boot that reuses
# an existing operator YAML has no business re-emitting the credential into the
# container log, and re-reading it from the YAML to print it would be exactly
# the mirroring the six-key dns.env contract forbids.
seed_body="$(sed -n '/^prepare_mihomo_config()/,/^}/p' "$ENTRYPOINT")"
secret_print_count="$(grep -Fc 'CONTROLLER SECRET' "$ENTRYPOINT")"
if [[ -n "$seed_body" && "$secret_print_count" == 1 ]] \
   && grep -Fq 'CONTROLLER SECRET' <<<"$seed_body" \
   && grep -Fq 'openssl rand -hex 32' <<<"$seed_body"; then
    pass "the controller secret is printed only where it is generated"
else
    fail "the controller secret is printed outside its generation branch"
fi

if command -v jq >/dev/null 2>&1 \
   && jq -e '
        .defaultAction == "SCMP_ACT_ERRNO" and
        any(.syscalls[]?;
            .action == "SCMP_ACT_ALLOW" and
            (.names | index("clone3") != null))
      ' "$SECCOMP" >/dev/null 2>&1; then
    pass "seccomp retains default-deny behavior while explicitly allowing clone3"
else
    fail "seccomp is not a bounded clone3-aware Docker profile"
fi

if grep -Fq 'needs: artifact-pins' "$CHECKS" \
   && grep -Fq 'bash docker/prepare-components.sh' "$CHECKS" \
   && grep -Fq "grep -Fxq 'MIHOMO_SOURCE=pinned-release'" "$CHECKS" \
   && grep -Fq 'MIHOMO_CONTAINER_CONTRACT=5gpn-container-runtime-v2' "$CHECKS" \
   && grep -Fq 'release/pins.env through release/pins.sh' "$CHECKS" \
   && grep -Fq 'docker build --platform linux/amd64' "$CHECKS" \
   && grep -Fq 'tests/container-acceptance.sh on test-env' "$CHECKS" \
   && ! grep -Eiq 'docker run .*privileged|seccomp[=:]unconfined' "$CHECKS"; then
    pass "hosted CI builds after pin verification without faking cgroup acceptance"
else
    fail "hosted CI Docker coverage exceeds or misses its static-build boundary"
fi

if awk '
    function finish_checkout() {
        if (!in_checkout) return
        if (expect_with || persist_count != 1 || token_count != 0) failed=1
        in_checkout=0
        expect_with=0
        in_with=0
    }
    {
        if (in_checkout) {
            if (expect_with) {
                if ($0 != checkout_prefix "  with:") {
                    failed=1
                    finish_checkout()
                } else {
                    expect_with=0
                    in_with=1
                    next
                }
            } else if (in_with) {
                option_prefix=checkout_prefix "    "
                if (index($0, option_prefix) == 1) {
                    if (index($0, option_prefix "persist-credentials:") == 1) {
                        persist_count++
                        if ($0 != option_prefix "persist-credentials: false") failed=1
                    }
                    if ($0 ~ /^[[:space:]]*token[[:space:]]*:/) token_count++
                    next
                }
                finish_checkout()
            }
        }
        if ($0 ~ /^[[:space:]]*- uses: actions\/checkout@/) {
            checkout_prefix=$0
            sub(/- uses:.*/, "", checkout_prefix)
            in_checkout=1
            expect_with=1
            persist_count=0
            token_count=0
            checkout_count++
        }
    }
    END {
        finish_checkout()
        exit !(checkout_count > 0 && !failed)
    }
' "$RELEASE"; then
    pass "release checkouts do not persist the write-scoped token into the build tree"
else
    fail "a release checkout lacks an adjacent non-persistent credential policy or names a token"
fi

pre_auth_build="$(sed -n '/^  build:/,/- name: Authenticate to GHCR and bind the exact image identity/p' "$RELEASE")"
if grep -Fq -- '- name: Revalidate immutable release identity' <<<"$pre_auth_build" \
   && grep -Fq -- '- name: Build exact-tag Linux amd64 image' <<<"$pre_auth_build" \
   && grep -Fq -- '- name: Authenticate to GHCR and bind the exact image identity' <<<"$pre_auth_build" \
   && ! grep -Eq 'github\.token|secrets(\.|\[)|(^|[^[:alnum:]_])(GH_TOKEN|GITHUB_TOKEN)([^[:alnum:]_]|$)|with:[[:space:]]*(\{[[:space:]]*)?token[[:space:]]*:|^[[:space:]]+token[[:space:]]*:' \
        <<<"$pre_auth_build"; then
    pass "release revalidation and build run before any explicit repository credential"
else
    fail "release revalidation or build can reference a repository credential before publication"
fi

if grep -Fq 'packages: write' "$RELEASE" \
   && grep -Fq 'IMAGE: ghcr.io/moooyo/5gpn:${{ github.ref_name }}' "$RELEASE" \
   && grep -Fq 'remote_id" == "$candidate_id" && "$remote_labels" == "$candidate_labels' "$RELEASE" \
   && grep -Fq '(has("manifests") | not)' "$RELEASE" \
   && grep -Fq 'body="OCI image: ${image_ref}"' "$RELEASE" \
   && grep -Fq 'map(select(startswith("OCI image: ")))) ==' "$RELEASE" \
   && grep -Fq 'Remote release asset differs from local bytes: $asset' "$RELEASE" \
   && grep -Fq 'Exact OCI tag moved during publication.' "$RELEASE" \
   && ! grep -Fq 'FIVEGPN_CONTAINER_ACCEPTED_' "$RELEASE" \
   && [[ "$(grep -Fc 'assert_exact_image_digest' "$RELEASE")" -ge 3 ]] \
   && grep -Fq 'if [[ "$RELEASE_CHANNEL" == stable ]]' "$RELEASE" \
   && grep -Fq 'latest=ghcr.io/moooyo/5gpn:latest' "$RELEASE" \
   && grep -Fq 'docker buildx imagetools create --prefer-index=false' "$RELEASE" \
   && grep -Fq 'Stable release did not become GitHub latest.' "$RELEASE" \
   && grep -Fq 'Beta release must not become GitHub latest.' "$RELEASE" \
   && grep -Fq 'elif [[ "$RELEASE_CHANNEL" != beta ]]' "$RELEASE"; then
    pass "release publishes an exact GHCR tag and advances latest only for stable"
else
    fail "GHCR tag or stable/beta latest policy drifted"
fi

# docker/build-candidate-image.sh refuses a dirty working tree, and packaging the
# installer bundle writes its stage directory, tarball, and checksums into that
# tree. The image must therefore be built first; this ordering is a permanent
# contract regardless of which release first exercised both paths.
image_build_line="$(grep -n 'name: Build exact-tag Linux amd64 image' "$RELEASE" | head -1 | cut -d: -f1)"
bundle_line="$(grep -n 'name: Package installer bundle' "$RELEASE" | head -1 | cut -d: -f1)"
if [[ "$image_build_line" =~ ^[0-9]+$ && "$bundle_line" =~ ^[0-9]+$ \
   && "$image_build_line" -lt "$bundle_line" ]] \
   && grep -Fq 'the working tree is dirty; acceptance requires a clean checkout' \
        "$ROOT/docker/build-candidate-image.sh"; then
    pass "the exact-tag image is built before packaging dirties the working tree"
else
    fail "installer packaging precedes the image build and will fail its clean-tree check"
fi

# The candidate build has exactly one definition. If the release job ever
# re-inlines it, the maintainer who ran test-env acceptance and the job that
# rebuilds before publishing stop executing the same steps -- and the only
# symptom is an image-ID mismatch with no diagnostic.
CANDIDATE_BUILD="$ROOT/docker/build-candidate-image.sh"
if [[ -x "$CANDIDATE_BUILD" ]] \
   && grep -Fq 'bash docker/build-candidate-image.sh' "$RELEASE" \
   && grep -Fq -- '--tag "${GITHUB_REF_NAME}"' "$RELEASE" \
   && ! grep -Fq 'docker buildx build' "$RELEASE"; then
    pass "the release job delegates the candidate build to its single definition"
else
    fail "the release job does not build through docker/build-candidate-image.sh"
fi
if grep -Fq "grep -Fxq 'MIHOMO_SOURCE=pinned-release'" "$CANDIDATE_BUILD" \
   && grep -Fq 'MIHOMO_CONTAINER_CONTRACT=5gpn-container-runtime-v2' "$CANDIDATE_BUILD" \
   && grep -Fq 'touch -h -d "@${source_epoch}"' "$CANDIDATE_BUILD" \
   && grep -Fq 'BUILDKIT_DIGEST=sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8' "$CANDIDATE_BUILD" \
   && grep -Fq 'rewrite-timestamp=true' "$CANDIDATE_BUILD" \
   && grep -Fq 'VERSION=${RELEASE_TAG}' "$CANDIDATE_BUILD" \
   && grep -Fq '[[ "$RELEASE_TAG" =~ $stable_release_re || "$RELEASE_TAG" =~ $beta_release_re ]]' "$CANDIDATE_BUILD" \
   && grep -Fq 'release tag must be X.Y.Z or X.Y.Z-beta.N without leading zeroes' "$CANDIDATE_BUILD" \
   && grep -Fq 'git status --porcelain' "$CANDIDATE_BUILD"; then
    pass "the candidate build pins its frontend, epoch, tag, and clean checkout"
else
    fail "the candidate build lost a reproducibility input"
fi

# The optional pull-through mirror must never become a way to fetch different
# bytes: both the driver image and BuildKit's own registry config keep the same
# pinned digest, and an unset mirror must leave the command line untouched.
if grep -Fq 'image=${REGISTRY_MIRROR}/moby/buildkit@${BUILDKIT_DIGEST}' "$CANDIDATE_BUILD" \
   && grep -Fq 'image=${BUILDKIT_IMAGE}' "$CANDIDATE_BUILD" \
   && grep -Fq 'REGISTRY_MIRROR="${FIVEGPN_BUILD_REGISTRY_MIRROR:-}"' "$CANDIDATE_BUILD" \
   && ! grep -Fq 'FIVEGPN_BUILD_REGISTRY_MIRROR' "$RELEASE"; then
    pass "the optional registry mirror stays digest-pinned and out of the release job"
else
    fail "the registry mirror can change which bytes the candidate build consumes"
fi

ACCEPTANCE="$ROOT/tests/container-acceptance.sh"
PROBE_LIBRARY="$ROOT/tests/docker/probe-lib.sh"
EXTENSION_PROBE="$ROOT/tests/docker/extension-worker-probe.sh"
if grep -Fq 'FIVEGPN_EXPECTED_COMMIT' "$ACCEPTANCE" \
   && grep -Fq 'FIVEGPN_ACCEPTANCE_TARGET' "$ACCEPTANCE" \
   && grep -Fq 'disposable' "$ACCEPTANCE" \
   && grep -Fq 'FIVEGPN_EXPECTED_MIHOMO_SHA256' "$ACCEPTANCE" \
   && grep -Fq 'FIVEGPN_EXPECTED_MIHOMO_BINARY_SHA256' "$ACCEPTANCE" \
   && grep -Fq 'release/pins.env' "$ACCEPTANCE" \
   && grep -Fq 'release/pins.sh' "$ACCEPTANCE" \
   && grep -Fq 'release_artifact_sha256 mihomo' "$ACCEPTANCE" \
   && grep -Fq 'git -C "$ROOT" rev-parse --show-toplevel' "$ACCEPTANCE" \
   && grep -Fq "git -C \"\$ROOT\" rev-parse --verify 'HEAD^{commit}'" "$ACCEPTANCE" \
   && grep -Fq 'git -C "$ROOT" ls-files --error-unmatch -- "$relative"' "$ACCEPTANCE" \
   && grep -Fq 'git -C "$ROOT" diff --quiet HEAD -- "$relative"' "$ACCEPTANCE" \
   && grep -Fq 'git -C "$ROOT" show "HEAD:$relative" | cmp -s - "$file"' "$ACCEPTANCE" \
   && grep -Fq 'org.opencontainers.image.revision' "$ACCEPTANCE" \
   && grep -Fq 'io.5gpn.mihomo.sha256' "$ACCEPTANCE" \
   && grep -Fq '5gpn-container-runtime-v2' "$ACCEPTANCE" \
   && grep -Fq '/opt/5gpn/ui' "$ACCEPTANCE" \
   && grep -Fq 'review_contract:8' "$EXTENSION_PROBE" \
   && [[ "$(grep -Fc 'assert_container_boundary' "$ACCEPTANCE")" -ge 3 ]] \
   && grep -Fq 'tests/docker' "$ACCEPTANCE" \
   && ! grep -Eq 'FIVEGPN_(EXTENSION|WORKER_OOM|CERT_HOT_RELOAD|RECREATE)_PROBE' "$ACCEPTANCE" \
   && grep -Fq 'development acceptance: PASS (not release evidence)' "$ACCEPTANCE"; then
    pass "test-env acceptance binds the exact clean candidate and uses only versioned probes"
else
    fail "test-env acceptance can use an unversioned probe or emit ambiguous evidence"
fi

certificate_idle_body="$(sed -n \
    '/^wait_for_certificate_manager_idle()/,/^}/p' "$EXTENSION_PROBE")"
certificate_idle_call_line="$(grep -n '^wait_for_certificate_manager_idle$' \
    "$EXTENSION_PROBE" | head -1 | cut -d: -f1)"
extension_review_line="$(grep -n '^review=' "$EXTENSION_PROBE" | head -1 | cut -d: -f1)"
if [[ "$certificate_idle_call_line" =~ ^[0-9]+$ \
   && "$extension_review_line" =~ ^[0-9]+$ \
   && "$certificate_idle_call_line" -lt "$extension_review_line" ]] \
   && grep -Fq '/run/5gpn/cert-renew.lock' "$EXTENSION_PROBE" \
   && grep -Fq 'docker exec --user 10001:10001' <<<"$certificate_idle_body" \
   && grep -Fq 'readlink -f -- "$runtime"' <<<"$certificate_idle_body" \
   && grep -Fq '10001:10001:700' <<<"$certificate_idle_body" \
   && grep -Fq 'stat -Lc "%u:%g:%a:%h"' <<<"$certificate_idle_body" \
   && grep -Fq '10001:10001:600:1' <<<"$certificate_idle_body" \
   && grep -Fq 'path_identity="$(stat -Lc "%d:%i" -- "$lock")"' \
        <<<"$certificate_idle_body" \
   && grep -Fq 'fd_identity="$(stat -Lc "%d:%i" -- "/proc/${BASHPID}/fd/9")"' \
        <<<"$certificate_idle_body" \
   && grep -Fq '[[ "$fd_identity" == "$path_identity" ]] || exit 74' \
        <<<"$certificate_idle_body" \
   && grep -Fq '[[ -e "$lock" && ! -L "$lock" ]] || exit 74' \
        <<<"$certificate_idle_body" \
   && grep -Fq 'flock -n -E 75 9' <<<"$certificate_idle_body" \
   && grep -Fq '75)' <<<"$certificate_idle_body" \
   && grep -Fq 'sleep 1' <<<"$certificate_idle_body" \
   && grep -Fq 'stable >= 8' <<<"$certificate_idle_body" \
   && grep -Fq 'sleep 0.25' <<<"$certificate_idle_body" \
   && grep -Fq '35 * 60' <<<"$certificate_idle_body" \
   && grep -Fq 'assert_probe_candidate_runtime_clean' <<<"$certificate_idle_body"; then
    pass "extension acceptance waits for a stably idle certificate manager"
else
    fail "extension acceptance can race the serialized startup certificate helpers"
fi

secret_source_line="$(grep -nF 'candidate_secret="$(jq -er .secret' \
    "$ACCEPTANCE" | head -1 | cut -d: -f1)"
leaf_match_line="$(grep -nF 'loopback HTTPS publication does not serve the candidate controller leaf' \
    "$ACCEPTANCE" | head -1 | cut -d: -f1)"
header_line="$(grep -nF "printf 'Authorization: Bearer %s\\n'" \
    "$ACCEPTANCE" | head -1 | cut -d: -f1)"
mapfile -t descriptor_wait_lines < <(
    grep -n '^wait_for_candidate_controller_descriptor$' "$ACCEPTANCE" | cut -d: -f1
)
mapfile -t authenticated_wait_lines < <(
    grep -n '^wait_for_authenticated_capabilities$' "$ACCEPTANCE" | cut -d: -f1
)
mapfile -t pid1_assert_lines < <(
    grep -n '^assert_pid1_live$' "$ACCEPTANCE" | cut -d: -f1
)
initial_tls_wait_line="$(grep -n '^wait_for_controller_tls_listener$' \
    "$ACCEPTANCE" | head -1 | cut -d: -f1)"
initial_boundary_line="$(grep -nF 'before_image_labels="$(assert_container_boundary)"' \
    "$ACCEPTANCE" | head -1 | cut -d: -f1)"
public_probe_line="$(grep -nF 'public_evidence="$(docker exec' \
    "$ACCEPTANCE" | head -1 | cut -d: -f1)"
recreate_switch_line="$(grep -nF 'CONTAINER="$new_container"' \
    "$ACCEPTANCE" | head -1 | cut -d: -f1)"
recreate_boundary_line="$(grep -nF 'after_image_labels="$(assert_container_boundary)"' \
    "$ACCEPTANCE" | head -1 | cut -d: -f1)"
recreate_final_runtime_line="$(grep -n '^assert_candidate_runtime_clean$' \
    "$ACCEPTANCE" | tail -1 | cut -d: -f1)"
recreate_pre_ready_body=''
if [[ "$recreate_switch_line" =~ ^[0-9]+$ \
   && "${authenticated_wait_lines[1]:-}" =~ ^[0-9]+$ \
   && "$recreate_switch_line" -lt "${authenticated_wait_lines[1]}" ]]; then
    recreate_pre_ready_body="$(sed -n "$((recreate_switch_line + 1)),$((authenticated_wait_lines[1] - 1))p" \
        "$ACCEPTANCE")"
fi
if ! grep -Eq 'FIVEGPN_CAPABILITIES_URL|FIVEGPN_CONTROLLER_SECRET_FILE|FIVEGPN_CONTROLLER_RESOLVE_IP|FIVEGPN_PROBE_API_ORIGIN|FIVEGPN_PROBE_CONTROLLER_RESOLVE_IP' \
       "$ACCEPTANCE" "$PROBE_LIBRARY" "$DOCKER_GUIDE" \
   && grep -Fq 's/^DNS_BASE_DOMAIN=//p' "$ACCEPTANCE" \
   && grep -Fq 'CONTROLLER_HOST="console.${base}"' "$ACCEPTANCE" \
   && grep -Fq 'inspect_candidate_controller' "$ACCEPTANCE" \
   && grep -Fq 'CONTROLLER_SECRET="$candidate_secret"' "$ACCEPTANCE" \
   && grep -Fq 'export FIVEGPN_PROBE_CONTROLLER_HOST="$CONTROLLER_HOST"' "$ACCEPTANCE" \
   && grep -Fq 'export FIVEGPN_PROBE_CONTROLLER_PORT="$CONTROLLER_PORT"' "$ACCEPTANCE" \
   && grep -Fq 'export FIVEGPN_PROBE_CONTROLLER_PINNED_PUBKEY="sha256//${pin_body}"' "$ACCEPTANCE" \
   && [[ "$secret_source_line" =~ ^[0-9]+$ && "$leaf_match_line" =~ ^[0-9]+$ \
      && "$header_line" =~ ^[0-9]+$ \
      && "$secret_source_line" -lt "$header_line" \
      && "$leaf_match_line" -lt "$header_line" ]] \
   && [[ "${#descriptor_wait_lines[@]}" == 3 \
      && "${#authenticated_wait_lines[@]}" == 3 \
      && "${#pid1_assert_lines[@]}" == 2 \
      && "$initial_tls_wait_line" =~ ^[0-9]+$ \
      && "$initial_boundary_line" =~ ^[0-9]+$ \
      && "$public_probe_line" =~ ^[0-9]+$ \
      && "$recreate_switch_line" =~ ^[0-9]+$ \
      && "$recreate_boundary_line" =~ ^[0-9]+$ \
      && "$recreate_final_runtime_line" =~ ^[0-9]+$ \
      && "$initial_tls_wait_line" -lt "$initial_boundary_line" \
      && "$initial_boundary_line" -lt "${descriptor_wait_lines[0]:-0}" \
      && "${descriptor_wait_lines[0]:-0}" -lt "${authenticated_wait_lines[0]:-0}" \
      && "$public_probe_line" -lt "${descriptor_wait_lines[1]:-0}" \
      && "${descriptor_wait_lines[1]:-0}" -lt "${pid1_assert_lines[1]:-0}" \
      && "$recreate_switch_line" -lt "${authenticated_wait_lines[1]:-0}" \
      && "${authenticated_wait_lines[1]:-0}" -lt "$recreate_boundary_line" \
      && "$recreate_boundary_line" -lt "${descriptor_wait_lines[2]:-0}" \
      && "${descriptor_wait_lines[2]:-0}" -lt "${authenticated_wait_lines[2]:-0}" \
      && "${authenticated_wait_lines[2]:-0}" -lt "$recreate_final_runtime_line" ]] \
   && [[ -n "$recreate_pre_ready_body" \
      && "$recreate_pre_ready_body" != *'docker exec'* ]] \
   && [[ "$(grep -Fc -- '--resolve "${FIVEGPN_PROBE_CONTROLLER_HOST}:${FIVEGPN_PROBE_CONTROLLER_PORT}:127.0.0.1"' \
        "$PROBE_LIBRARY")" == 1 ]] \
   && grep -Fq -- '--disable' "$PROBE_LIBRARY" \
   && grep -Fq -- "--proto '=https'" "$PROBE_LIBRARY" \
   && grep -Fq -- '--pinnedpubkey "$FIVEGPN_PROBE_CONTROLLER_PINNED_PUBKEY"' "$PROBE_LIBRARY" \
   && grep -Fq 'https://${FIVEGPN_PROBE_CONTROLLER_HOST}:${FIVEGPN_PROBE_CONTROLLER_PORT}${path}' \
        "$PROBE_LIBRARY"; then
    pass "controller acceptance derives and verifies the candidate endpoint before authenticated loopback requests"
else
    fail "controller acceptance can authenticate to a target not bound to the candidate"
fi

if grep -Fq 'FIVEGPN_EXPECTED_RELEASE_TAG' "$ACCEPTANCE" \
   && grep -Fq 'FIVEGPN_EXPECTED_RELEASE_TAG="$accepted_release_tag"' "$DOCKER_GUIDE" \
   && grep -Fq 'org.opencontainers.image.version' "$ACCEPTANCE" \
   && grep -Fq '.[0].Config.Labels["org.opencontainers.image.version"] == $release_tag' "$ACCEPTANCE" \
   && grep -Fq '&& -z "$EXPECTED_RELEASE_TAG" && -z "$EXPECTED_MIHOMO_SHA256"' "$ACCEPTANCE" \
   && grep -Fq 'candidate_descriptor' "$ACCEPTANCE" \
   && grep -Fq 'image_config_digest: $image_config_digest' "$ACCEPTANCE" \
   && grep -Fq 'platform: "linux/amd64"' "$ACCEPTANCE"; then
    pass "release acceptance binds the expected tag to the candidate image descriptor"
else
    fail "release acceptance does not bind the expected tag to the candidate image"
fi

descriptor_wait_body="$(sed -n '/^wait_for_candidate_controller_descriptor()/,/^}/p' "$ACCEPTANCE")"
authenticated_wait_body="$(sed -n '/^wait_for_authenticated_capabilities()/,/^}/p' "$PROBE_LIBRARY")"
descriptor_runtime_body="$(sed -n '/^assert_candidate_runtime_clean()/,/^}/p' "$ACCEPTANCE")"
probe_runtime_body="$(sed -n '/^assert_probe_candidate_runtime_clean()/,/^}/p' "$PROBE_LIBRARY")"
api_request_body="$(sed -n '/^api_request()/,/^}/p' "$PROBE_LIBRARY")"
tls_wait_body="$(sed -n '/^wait_for_controller_tls_listener()/,/^}/p' "$ACCEPTANCE")"
mapfile -t descriptor_load_lines < <(
    grep -n 'load_candidate_controller_descriptor' <<<"$descriptor_wait_body" | cut -d: -f1
)
mapfile -t descriptor_runtime_lines < <(
    grep -n 'assert_candidate_runtime_clean' <<<"$descriptor_wait_body" | cut -d: -f1
)
descriptor_return_line="$(grep -n 'return 0' <<<"$descriptor_wait_body" | head -1 | cut -d: -f1)"
authenticated_runtime_line="$(grep -n 'assert_probe_candidate_runtime_clean' \
    <<<"$authenticated_wait_body" | head -1 | cut -d: -f1)"
authenticated_return_line="$(grep -n 'return 0' <<<"$authenticated_wait_body" | head -1 | cut -d: -f1)"
if [[ "$tls_wait_body" != *'docker exec'* ]] \
   && [[ "$authenticated_wait_body" != *'docker exec'* \
      && "$api_request_body" != *'docker exec'* \
      && "$probe_runtime_body" != *'docker exec'* ]] \
   && grep -Fq -- '-connect "127.0.0.1:${HOST_PORT_443}"' <<<"$tls_wait_body" \
   && grep -Fq '.[0].RestartCount == 0' <<<"$tls_wait_body" \
   && grep -Fq '.[0].State.Running == true' <<<"$descriptor_runtime_body" \
   && grep -Fq '.[0].State.Pid > 0' <<<"$descriptor_runtime_body" \
   && grep -Fq '.[0].RestartCount == 0' <<<"$descriptor_runtime_body" \
   && grep -Fq '.[0].State.Running == true' <<<"$probe_runtime_body" \
   && grep -Fq '.[0].State.Pid > 0' <<<"$probe_runtime_body" \
   && grep -Fq '.[0].RestartCount == 0' <<<"$probe_runtime_body" \
   && [[ "${#descriptor_load_lines[@]}" == 2 \
      && "${#descriptor_runtime_lines[@]}" == 3 \
      && "$descriptor_return_line" =~ ^[0-9]+$ \
      && "${descriptor_load_lines[0]:-0}" -lt "${descriptor_runtime_lines[1]:-0}" \
      && "${descriptor_runtime_lines[1]:-0}" -lt "$descriptor_return_line" \
      && "${descriptor_load_lines[1]:-0}" -lt "${descriptor_runtime_lines[2]:-0}" ]] \
   && [[ "$authenticated_runtime_line" =~ ^[0-9]+$ \
      && "$authenticated_return_line" =~ ^[0-9]+$ \
      && "$authenticated_runtime_line" -lt "$authenticated_return_line" ]]; then
    pass "descriptor and authentication readiness reject candidates that restarted"
else
    fail "candidate readiness can hide a failed start behind Docker restart policy"
fi

immutable_line="$(grep -nF -- '- name: Publish and verify immutable release' "$RELEASE" | cut -d: -f1)"
latest_line="$(grep -nF -- '- name: Advance stable GHCR latest after immutable release' "$RELEASE" | cut -d: -f1)"
if [[ "$immutable_line" =~ ^[0-9]+$ && "$latest_line" =~ ^[0-9]+$ \
   && "$immutable_line" -lt "$latest_line" ]]; then
    pass "stable GHCR latest moves only after immutable GitHub publication"
else
    fail "GHCR latest can move before the GitHub release is immutable"
fi

for launch_file in compose.yaml docker/seccomp-5gpn.json docker/bootstrap/config.env.example docs/docker.md; do
    grep -Fxq "            $launch_file" "$RELEASE" \
        || fail "installer archive omits Docker launch input: $launch_file"
done

collect_step="$(sed -n '/- name: Collect exact release assets/,/- name: Revalidate release identity immediately before publish/p' "$RELEASE")"
if grep -Fq 'cp 5gpn-installer.tar.gz checksums.txt THIRD_PARTY_NOTICES.md release-assets/' <<<"$collect_step" \
   && ! grep -Eiq 'docker|\.tar(\.gz)?[[:space:]]+release-assets' <<<"$collect_step"; then
    pass "GitHub Release remains exactly three installer assets; OCI stays in GHCR"
else
    fail "Docker delivery leaked into the exact-three GitHub asset set"
fi

for doc in README.md README.en.md docs/architecture.md docs/docker.md MEMORY.md AGENTS.md THIRD_PARTY_NOTICES.md; do
    if grep -Eiq 'Docker|GHCR|ghcr\.io' "$ROOT/$doc"; then
        pass "$doc records the Docker boundary"
    else
        fail "$doc omits the Docker delivery contract"
    fi
done

if grep -Fq 'ghcr.io/moooyo/5gpn:${TAG}@${IMAGE_DIGEST}' "$ROOT/README.md" \
   && grep -Fq 'ghcr.io/moooyo/5gpn:${TAG}@${IMAGE_DIGEST}' "$ROOT/README.en.md" \
   && grep -Fq 'ghcr.io/moooyo/5gpn:${TAG}@${IMAGE_DIGEST}' "$ROOT/docs/docker.md" \
   && grep -Fq 'tag-and-digest container image reference recorded by the immutable release' \
        "$ROOT/docs/architecture.md"; then
    pass "Docker deployment documentation consumes the immutable release image reference"
else
    fail "Docker deployment documentation falls back to an unqualified image tag"
fi

ENTRYPOINT="$ROOT/docker/entrypoint.sh"
PUBLIC_CERT="$ROOT/docker/docker-public-cert.sh"

# The public certificate helper reads the same bootstrap file with `grep -E
# "^KEY="` over raw bytes. If the entrypoint validated a trimmed copy instead,
# a leading or trailing space would pass bootstrap and then fail the helper,
# and `restart: unless-stopped` would loop that forever.
bootstrap_parser="$(sed -n '/^load_bootstrap_config()/,/^}/p' "$ENTRYPOINT")"
if grep -Fq '[[ "$raw" == "$key=$value" ]]' <<<"$bootstrap_parser" \
   && ! grep -Fq '[[ "$line" == "$key=$value" ]]' <<<"$bootstrap_parser"; then
    pass "bootstrap entries are validated against the untrimmed line"
else
    fail "bootstrap parser accepts whitespace the certificate helper rejects"
fi
if grep -Fq 'config_get()' "$PUBLIC_CERT" \
   && grep -Fq 'grep -cE "^${key}=" "$CONFIG_FILE"' "$PUBLIC_CERT"; then
    pass "the certificate helper remains the strict raw-byte reference parser"
else
    fail "the certificate helper no longer reads raw KEY= bytes"
fi

# Delegation must be proven before bootstrap spends a real ACME order and mints
# the interception CA key; the Core only checks it after listeners prepare.
if grep -Fq 'verify_cgroup_delegation' "$ENTRYPOINT"; then
    main_body="$(sed -n '/^main()/,/^}/p' "$ENTRYPOINT")"
    cgroup_line="$(grep -n 'verify_cgroup_delegation' <<<"$main_body" | head -n 1 | cut -d: -f1)"
    cert_line="$(grep -n 'preflight_certificate_state\|bootstrap_public_certificate\|INTERCEPT_CERT_HELPER' <<<"$main_body" | head -n 1 | cut -d: -f1)"
    if [[ -n "$cgroup_line" && -n "$cert_line" ]] && (( cgroup_line < cert_line )); then
        pass "cgroup delegation is verified before any certificate work"
    else
        fail "cgroup delegation is not verified before certificate work"
    fi
    for signal in 'cgroup2fs' "0::/" 'writable-cgroups=true' 'cgroup: private'; do
        grep -Fq "$signal" "$ENTRYPOINT" \
            || fail "cgroup preflight does not name the required host setting: $signal"
    done
else
    fail "the entrypoint has no cgroup delegation preflight"
fi

# Retrying a permanent certbot failure is pointless, but exiting is not how you
# stop: `restart: unless-stopped` restarts on any exit code and Docker resets
# its backoff after a >=10s run, so a bare early return attempts a fresh ACME
# order roughly every 15 seconds. The hold is the load-bearing half of the fix.
if grep -Fq 'certbot_failure_is_permanent' "$PUBLIC_CERT" \
   && grep -Fq 'return 78' "$PUBLIC_CERT" \
   && grep -Fq 'return 75' "$PUBLIC_CERT"; then
    pass "certbot failures are split into permanent and transient verdicts"
else
    fail "every certbot failure is still classified transient"
fi
if grep -Fq 'PERMANENT_ACME_HOLD_SECONDS' "$ENTRYPOINT" \
   && grep -Fq 'run_sync sleep "$PERMANENT_ACME_HOLD_SECONDS"' "$ENTRYPOINT"; then
    pass "a permanent ACME verdict holds before exit instead of hot-restarting"
else
    fail "a permanent ACME verdict exits straight into the container restart loop"
fi

# certbot 4.0.0's _find_zone_id funnels unrecognised Cloudflare API errors --
# including 429 and 5xx -- through "Unable to determine zone_id ... The error
# from Cloudflare was: ...". Matching zone_id broadly would call a Cloudflare
# outage permanent and skip the ladder.
classifier="$(sed -n '/^certbot_failure_is_permanent()/,/^}/p' "$PUBLIC_CERT")"
for pattern in 'error determining zone_id: (6003|9103|9109) ' \
               'please confirm that the domain name has been entered correctly' \
               'too many (certificates|registrations)'; do
    grep -Fq "$pattern" <<<"$classifier" \
        || fail "permanent certbot classification omits a known-permanent signature: $pattern"
done
for antipattern in 'the error from cloudflare was' 'failed authorizations' 'ratelimited'; do
    grep -Fiq "$antipattern" <<<"$classifier" \
        && fail "permanent certbot classification sweeps in a transient signature: $antipattern"
done
pass "the classifier keeps Cloudflare API and hourly-limit failures transient"

retry_ladder="$(sed -n '/^bootstrap_public_certificate()/,/^}/p' "$ENTRYPOINT")"
grep -Fq '[[ "$rc" == 75 ]] || return "$rc"' <<<"$retry_ladder" \
    || fail "the entrypoint retry ladder no longer restricts itself to code 75"

deps_ok=1
for tool in diffutils mawk; do
    grep -Eq "^[[:space:]]+$tool \\\\$" "$DOCKERFILE" \
        || { fail "Dockerfile does not install a load-bearing bootstrap tool: $tool"; deps_ok=0; }
done
[[ "$deps_ok" == 1 ]] && pass "cmp and awk are declared image dependencies"

# Reproducibility is a release gate, not a nicety: release.yml rebuilds the image
# and refuses to publish unless the ID matches the accepted one. ldconfig's
# aux-cache embeds inode numbers and scan timestamps and was the single file that
# made two builds of one commit differ. /etc/ssl/certs must also stay traversable
# or APT's unprivileged _apt user cannot read the pinned CA bundle.
if grep -Fq 'rm -f /var/cache/ldconfig/aux-cache' "$DOCKERFILE"; then
    pass "the nondeterministic ldconfig aux-cache is removed in its own layer"
else
    fail "ldconfig aux-cache survives and makes the image ID unreproducible"
fi
if grep -Fq 'chmod 0755 /etc/ssl /etc/ssl/certs' "$DOCKERFILE"; then
    pass "the bootstrap CA directory is traversable by APT"
else
    fail "APT cannot read the pinned CA bundle through a non-traversable directory"
fi

# The documented capture is image_id="$(build-candidate-image.sh ...)", so any
# other writer on stdout silently corrupts the accepted image ID.
build_stdout_writers="$(grep -cE '^(bash docker/prepare-components\.sh|docker load) ' "$CANDIDATE_BUILD" || true)"
if grep -Fq 'bash docker/prepare-components.sh >&2' "$CANDIDATE_BUILD" \
   && grep -Fq 'docker load --input "$archive" >&2' "$CANDIDATE_BUILD" \
   && [[ "$(grep -c "docker image inspect --format '{{.Id}}'" "$CANDIDATE_BUILD")" == 1 ]]; then
    pass "the candidate build prints only the image ID on stdout"
else
    fail "the candidate build leaks progress output into the captured image ID"
fi
if grep -Fq 'docker buildx rm "$BUILDER" >/dev/null 2>&1 || true' "$CANDIDATE_BUILD"; then
    pass "candidate build cleanup cannot abort under errexit"
else
    fail "a failing builder removal can abort cleanup and fail a good build"
fi
# buildx refuses a builder name that does not start with a letter.
if grep -Eq '^BUILDER=[A-Za-z][A-Za-z0-9._-]*$' "$CANDIDATE_BUILD"; then
    pass "the buildx builder name is one buildx will accept"
else
    fail "the buildx builder name is rejected by docker buildx create"
fi

exit "$FAIL"
