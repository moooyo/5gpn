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
CHECKS="$ROOT/.github/workflows/checks.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
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
   && grep -Fq 'ENTRYPOINT ["/opt/5gpn/bin/docker-entrypoint.sh"]' "$DOCKERFILE"; then
    pass "image platform, base digest, runtime mode, identity, and PID-1 entrypoint are fixed"
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

for pin in MIHOMO_REPO MIHOMO_VERSION MIHOMO_SHA256 ZASH_REPO ZASH_VERSION ZASH_SHA256; do
    grep -Fq "read_pin $pin" "$PREPARE" \
        || fail "component preparation does not read $pin from install.sh"
done
if grep -Fq 'verify_digest "$stage/mihomo.gz" "$MIHOMO_SHA256"' "$PREPARE" \
   && grep -Fq 'verify_digest "$stage/zashboard.zip" "$ZASH_SHA256"' "$PREPARE" \
   && grep -Fq 'verify_digest "$stage/bootstrap-ca.pem" "$CA_BUNDLE_SHA256"' "$PREPARE" \
   && grep -Fq '"$binary" 5gpn-container-contract' "$PREPARE" \
   && grep -Fq "printf '%s\\n' '5gpn-container-runtime-v1' | cmp -s - \"\$output\"" "$PREPARE" \
   && grep -Fq 'MIHOMO_CONTAINER_CONTRACT=5gpn-container-runtime-v1' "$PREPARE" \
   && grep -Fq 'CA_BUNDLE_SHA256=' "$PREPARE" \
   && grep -Fq 'manifest.env' "$PREPARE"; then
    pass "Docker preparation verifies both install.sh pins and records the manifest"
else
    fail "Docker preparation does not bind both component digests before use"
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
    '    image: ${FIVEGPN_IMAGE:?set FIVEGPN_IMAGE to an exact ghcr.io/moooyo/5gpn tag}'
    '    user: "10001:10001"'
    '    ports:'
    '      - "0.0.0.0:853:853/tcp"'
    '      - "0.0.0.0:80:80/tcp"'
    '      - "0.0.0.0:443:9443/tcp"'
    '      - "0.0.0.0:443:9443/udp"'
    '      - "0.0.0.0:5060:5060/tcp"'
    '      - "0.0.0.0:5060:5060/udp"'
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
    '    stop_grace_period: 30s'
    '        target: /etc/5gpn'
    '    name: ${FIVEGPN_DATA_VOLUME:-fivegpn-data}'
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
if [[ "$port_mapping_count" == 8 ]] \
   && ! grep -Eq '^      - "0\.0\.0\.0:(53|5353|5354):' "$COMPOSE" \
   && ! grep -Eq '^      - "0\.0\.0\.0:[0-9]+:(53|5353|5354|443)/(tcp|udp)"$' "$COMPOSE" \
   && ! grep -Eiq 'network_mode:|cap_add:|NET_BIND_SERVICE|privileged:[[:space:]]*true|SYS_ADMIN|seccomp[=:]unconfined|docker\.sock|/sys/fs/cgroup|FIVEGPN_IMAGE:-.*latest' "$COMPOSE"; then
    pass "Compose publishes only the eight IPv4 bridge mappings, grants no capability or privilege escape, and has no movable image default"
else
    fail "Compose widened its IPv4-only port, privilege, network, or image boundary"
fi

if grep -Fq 'exec "$MIHOMO_BIN"' "$ENTRYPOINT" \
   && grep -Fq 'wait "$child_pid"' "$ENTRYPOINT" \
   && grep -Fq 'safe_private_input_file "$BOOTSTRAP_INPUT"' "$ENTRYPOINT" \
   && grep -Fq 'safe_private_input_file "$CF_SECRET"' "$ENTRYPOINT" \
   && grep -Fq 'Docker supports only CERT_MODE=cloudflare.' "$ENTRYPOINT" \
   && grep -Fxq 'readonly DOCKER_LISTEN_IP=0.0.0.0' "$ENTRYPOINT" \
   && grep -Fxq 'readonly DOCKER_TLS_LISTEN_PORT=9443' "$ENTRYPOINT" \
   && grep -Fq 'port: %s, network: [tcp, udp], target: %s:443' "$ENTRYPOINT" \
   && grep -Fq '"$DOCKER_LISTEN_IP" "$DOCKER_TLS_LISTEN_PORT" "$CONSOLE_DOMAIN"' "$ENTRYPOINT" \
   && grep -Fq 'DNS_MIHOMO_CONTROLLER=127.0.0.1:443' "$ENTRYPOINT" \
   && ! grep -Fq 'BOOTSTRAP[DNS_MIHOMO_LISTEN_IPS]' "$ENTRYPOINT" \
   && ! grep -Eq '^[[:space:]]*DNS_MIHOMO_LISTEN_IPS=' "$BOOTSTRAP_EXAMPLE"; then
    pass "entrypoint secures inputs, fixes bridge listeners, preserves the public 443 target, waits children, and execs the monolith"
else
    fail "entrypoint drifted from the fixed bridge-listener or synchronous single-PID contract"
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
   && grep -Fq 'MIHOMO_CONTAINER_CONTRACT=5gpn-container-runtime-v1' "$CHECKS" \
   && grep -Fq 'docker build --platform linux/amd64' "$CHECKS" \
   && grep -Fq 'tests/container-acceptance.sh on test-env' "$CHECKS" \
   && ! grep -Eiq 'docker run .*privileged|seccomp[=:]unconfined' "$CHECKS"; then
    pass "hosted CI builds after pin verification without faking cgroup acceptance"
else
    fail "hosted CI Docker coverage exceeds or misses its static-build boundary"
fi

if grep -Fq 'packages: write' "$RELEASE" \
   && grep -Fq 'IMAGE: ghcr.io/moooyo/5gpn:${{ github.ref_name }}' "$RELEASE" \
   && grep -Fq "grep -Fxq 'MIHOMO_SOURCE=pinned-release'" "$RELEASE" \
   && grep -Fq 'MIHOMO_CONTAINER_CONTRACT=5gpn-container-runtime-v1' "$RELEASE" \
   && grep -Fq 'remote_id" == "$candidate_id" && "$remote_labels" == "$candidate_labels' "$RELEASE" \
   && grep -Fq '(has("manifests") | not)' "$RELEASE" \
   && grep -Fq 'body="OCI image: ${image_ref}"' "$RELEASE" \
   && grep -Fq 'map(select(startswith("OCI image: ")))) ==' "$RELEASE" \
   && grep -Fq 'Remote release asset differs from local bytes: $asset' "$RELEASE" \
   && grep -Fq 'Exact OCI tag moved during publication.' "$RELEASE" \
   && grep -Fq 'touch -h -d "@${source_epoch}"' "$RELEASE" \
   && grep -Fq 'moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8' "$RELEASE" \
   && grep -Fq 'rewrite-timestamp=true' "$RELEASE" \
   && grep -Fq 'FIVEGPN_CONTAINER_ACCEPTED_COMMIT' "$RELEASE" \
   && grep -Fq 'FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256' "$RELEASE" \
   && grep -Fq 'FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID' "$RELEASE" \
   && grep -Fq '"$ACCEPTED_COMMIT" == "$event_commit"' "$RELEASE" \
   && grep -Fq '"$ACCEPTED_MIHOMO_SHA256" == "$pinned_sha"' "$RELEASE" \
   && grep -Fq '"$candidate_id" == "$ACCEPTED_IMAGE_ID"' "$RELEASE" \
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

ACCEPTANCE="$ROOT/tests/container-acceptance.sh"
if grep -Fq 'FIVEGPN_EXPECTED_COMMIT' "$ACCEPTANCE" \
   && grep -Fq 'FIVEGPN_EXPECTED_MIHOMO_SHA256' "$ACCEPTANCE" \
   && grep -Fq 'FIVEGPN_EXPECTED_MIHOMO_BINARY_SHA256' "$ACCEPTANCE" \
   && grep -Fq 'git -C "$ROOT" rev-parse --show-toplevel' "$ACCEPTANCE" \
   && grep -Fq "git -C \"\$ROOT\" rev-parse --verify 'HEAD^{commit}'" "$ACCEPTANCE" \
   && grep -Fq 'git -C "$ROOT" ls-files --error-unmatch -- "$relative"' "$ACCEPTANCE" \
   && grep -Fq 'git -C "$ROOT" diff --quiet HEAD -- "$relative"' "$ACCEPTANCE" \
   && grep -Fq 'git -C "$ROOT" show "HEAD:$relative" | cmp -s - "$file"' "$ACCEPTANCE" \
   && grep -Fq 'org.opencontainers.image.revision' "$ACCEPTANCE" \
   && grep -Fq 'io.5gpn.mihomo.sha256' "$ACCEPTANCE" \
   && [[ "$(grep -Fc 'assert_container_boundary' "$ACCEPTANCE")" -ge 3 ]] \
   && grep -Fq 'tests/docker' "$ACCEPTANCE" \
   && ! grep -Eq 'FIVEGPN_(EXTENSION|WORKER_OOM|CERT_HOT_RELOAD|RECREATE)_PROBE' "$ACCEPTANCE" \
   && grep -Fq 'development acceptance: PASS (not release evidence)' "$ACCEPTANCE"; then
    pass "test-env acceptance binds the exact clean candidate and uses only versioned probes"
else
    fail "test-env acceptance can use an unversioned probe or emit ambiguous evidence"
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

exit "$FAIL"
