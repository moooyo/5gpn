#!/usr/bin/env bash
# Build the exact reproducible release-candidate image.
#
# This file is the single definition of that build. Both the release workflow
# and the maintainer who runs test-env acceptance must use it, because the
# release job rebuilds the image and refuses to publish unless the rebuilt
# image ID equals FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID. Every input that lands
# in the config digest therefore has to match: the pinned BuildKit, the pinned
# Dockerfile frontend and base image, the normalized context timestamps, the
# component labels, and VERSION -- which becomes
# org.opencontainers.image.version. A bare `docker build`, a different builder,
# an unset SOURCE_DATE_EPOCH, or a placeholder VERSION all produce an image
# that can pass acceptance and then fail the release gate with nothing but
# "Candidate image ID differs from the exact test-env result."
set -Eeuo pipefail
umask 0022
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# buildx rejects a builder name that does not start with a letter, so this
# cannot be "5gpn-release-builder" the way the rest of the project names things.
BUILDER=fivegpn-release-builder
BUILDKIT_IMAGE='moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8'
EXPECTED_LABEL_ARGS=20

# Exactly the paths whose mtimes reach the image. Keep this list identical to
# the build context the Dockerfile consumes; a path added to the image without
# being added here reintroduces nondeterminism.
CONTEXT_INPUTS=(
    Dockerfile
    .dockerignore
    LICENSE
    THIRD_PARTY_NOTICES.md
    docker/entrypoint.sh
    docker/docker-public-cert.sh
    docker/docker-intercept-cert.sh
    docker/build
    etc/mihomo/config.yaml.tmpl
    scripts/publication-fs.sh
    scripts/cert-role-ctl.sh
    scripts/ui-generation.sh
    scripts/gen-ios-profile.sh
)

usage() {
    cat >&2 <<'EOF'
usage: docker/build-candidate-image.sh --tag RELEASE_TAG [--commit COMMIT] [--image NAME:TAG]

  --tag     The exact release tag that will later be pushed. It becomes VERSION
            and lands inside the image config digest, so it has no default:
            guessing it silently invalidates the acceptance evidence.
  --commit  Commit-ish to build. Defaults to HEAD.
  --image   Local tag for the result. Defaults to
            5gpn-release-candidate:<commit>.

The working tree must be clean and must be at the named commit; the acceptance
driver rejects a candidate whose versioned inputs differ from the commit.

Prints the resulting image ID on stdout. Record it as
FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID only after release-mode acceptance passes
against this exact image.
EOF
    exit 2
}

fail() { echo "build-candidate-image: $*" >&2; exit 1; }

RELEASE_TAG=""
COMMITISH=HEAD
CANDIDATE_IMAGE=""
while (($#)); do
    case "$1" in
        --tag) [[ $# -ge 2 ]] || usage; RELEASE_TAG="$2"; shift 2 ;;
        --commit) [[ $# -ge 2 ]] || usage; COMMITISH="$2"; shift 2 ;;
        --image) [[ $# -ge 2 ]] || usage; CANDIDATE_IMAGE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done
[[ -n "$RELEASE_TAG" ]] || usage

cd "$ROOT"

for command in git docker find touch diff jq; do
    command -v "$command" >/dev/null 2>&1 || fail "missing required command: $command"
done

commit="$(git rev-parse "${COMMITISH}^{commit}")" \
    || fail "could not resolve commit: $COMMITISH"
[[ "$(git rev-parse 'HEAD^{commit}')" == "$commit" ]] \
    || fail "the working tree is not at $commit; check it out before building"
[[ -z "$(git status --porcelain)" ]] \
    || fail "the working tree is dirty; acceptance requires a clean checkout"

source_epoch="$(git show -s --format=%ct "${commit}^{commit}")"
[[ "$source_epoch" =~ ^[1-9][0-9]*$ ]] \
    || fail "could not derive a usable SOURCE_DATE_EPOCH from $commit"

[[ -n "$CANDIDATE_IMAGE" ]] || CANDIDATE_IMAGE="5gpn-release-candidate:${commit}"

# Every narration goes to stderr so stdout carries exactly one thing: the image
# ID. The documented capture is `image_id="$(...)"`, and a stray progress line in
# that variable becomes an unexplained "Candidate image ID differs" at release
# time -- the precise failure this script exists to prevent.
bash docker/prepare-components.sh >&2
grep -Fxq 'MIHOMO_SOURCE=pinned-release' docker/build/components/manifest.env \
    || fail "component preparation did not use the pinned release artifact"
grep -Fxq 'MIHOMO_CONTAINER_CONTRACT=5gpn-container-runtime-v2' \
    docker/build/components/manifest.env \
    || fail "the pinned Core does not answer the container-runtime-v2 handshake"

label_args=()
while IFS= read -r label; do
    [[ "$label" == *=* ]] || fail "malformed component label: $label"
    label_args+=(--label "$label")
done < <(bash docker/prepare-components.sh --print-labels)
((${#label_args[@]} == EXPECTED_LABEL_ARGS)) \
    || fail "expected ${EXPECTED_LABEL_ARGS} component label arguments, got ${#label_args[@]}"

for input in "${CONTEXT_INPUTS[@]}"; do
    [[ -e "$input" ]] || fail "missing build context input: $input"
    find "$input" -exec touch -h -d "@${source_epoch}" {} +
done

archive="$(mktemp "${TMPDIR:-/tmp}/5gpn-release-candidate.XXXXXX.tar")"
builder_started=0
cleanup() {
    # `|| true` is required even here: the trap runs under errexit, so a failing
    # `docker buildx rm` would abort cleanup before the multi-hundred-megabyte
    # archive is removed and would turn a successful build into a failed one.
    if [[ "$builder_started" == 1 ]]; then
        docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
    fi
    rm -f -- "$archive"
    return 0
}
trap cleanup EXIT

# A dedicated container-driver builder pinned by digest. The default builder is
# deliberately left alone: `--builder` selects it per invocation, so this never
# mutates the caller's buildx context.
docker buildx create \
    --name "$BUILDER" \
    --driver docker-container \
    --driver-opt "image=${BUILDKIT_IMAGE}" >/dev/null
builder_started=1
docker buildx inspect --bootstrap "$BUILDER" >/dev/null

docker buildx build --builder "$BUILDER" \
    --platform linux/amd64 \
    --build-arg "VCS_REF=${commit}" \
    --build-arg "VERSION=${RELEASE_TAG}" \
    --build-arg "SOURCE_DATE_EPOCH=${source_epoch}" \
    "${label_args[@]}" \
    --tag "$CANDIDATE_IMAGE" \
    --output "type=docker,dest=${archive},rewrite-timestamp=true" \
    .

docker load --input "$archive" >&2

[[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$CANDIDATE_IMAGE")" \
   == linux/amd64 ]] \
    || fail "the candidate image is not linux/amd64"

image_components="$(mktemp "${TMPDIR:-/tmp}/5gpn-image-components.XXXXXX.env")"
docker run --rm --entrypoint /bin/cat "$CANDIDATE_IMAGE" \
    /usr/share/5gpn/components.env > "$image_components"
if ! diff -u docker/build/components/manifest.env "$image_components" >&2; then
    rm -f -- "$image_components"
    fail "the built image does not carry the prepared component manifest"
fi
rm -f -- "$image_components"

# The sole stdout writer on the success path.
docker image inspect --format '{{.Id}}' "$CANDIDATE_IMAGE"
