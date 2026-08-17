#!/usr/bin/env bash
# Authoritative Docker 28/cgroup-v2 acceptance gate. Every behavioral probe is
# versioned beside this driver under tests/docker; the test host supplies only
# the candidate, controller credential, and optional narrow connection inputs.
set -Eeuo pipefail
export LC_ALL=C

acceptance_error() {
    local rc=$?
    printf 'Docker acceptance failed at line %s (status %s): %s\n' \
        "${BASH_LINENO[0]}" "$rc" "$BASH_COMMAND" >&2
    return "$rc"
}
trap acceptance_error ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_DIR="$ROOT/tests/docker"
PROBE_LIBRARY="$PROBE_DIR/probe-lib.sh"
EXTENSION_PROBE="$PROBE_DIR/extension-worker-probe.sh"
PUBLIC_CERT_PROBE="$PROBE_DIR/public-certificate-hot-reload.sh"
RECREATE_PROBE="$PROBE_DIR/recreate-container.sh"
SECCOMP_PROFILE="$ROOT/docker/seccomp-5gpn.json"
PINS_ENV="$ROOT/release/pins.env"
PINS_LIBRARY="$ROOT/release/pins.sh"

usage() {
	local status="${1:-2}"
    cat >&2 <<'EOF'
usage: tests/container-acceptance.sh CONTAINER

Required for every run:
  FIVEGPN_ACCEPTANCE_HOST=test-env
  FIVEGPN_ACCEPTANCE_TARGET=disposable
  FIVEGPN_EXPECTED_COMMIT=<40-hex candidate 5gpn commit>
  FIVEGPN_CAPABILITIES_URL=https://console.example/capabilities
  FIVEGPN_CONTROLLER_SECRET_FILE=/root/acceptance/controller-secret

Release mode (default) additionally requires:
  FIVEGPN_EXPECTED_MIHOMO_SHA256=<64-hex compressed release artifact digest>

Development mode must instead set:
  FIVEGPN_ACCEPTANCE_MODE=development
  FIVEGPN_EXPECTED_MIHOMO_BINARY_SHA256=<64-hex test-env-built binary digest>
  FIVEGPN_DEVELOPMENT_PROJECT=<safe test project name>
  FIVEGPN_DEVELOPMENT_BIND_IP=127.0.0.1
  FIVEGPN_DEVELOPMENT_HOST_PORTS='{"853":2853,"80":20080,"443":20443,"8080":28080,"8443":28443}'
  FIVEGPN_CAPABILITIES_URL=https://console.example:20443/capabilities

Optional narrow controller connection inputs:
  FIVEGPN_CONTROLLER_RESOLVE_IP=<IPv4 address for console hostname>
  FIVEGPN_CONTROLLER_CA_FILE=<PEM CA bundle>

The candidate must have been created from the repository Compose contract.
This driver executes only the fixed, versioned probes under tests/docker. It
performs no site-owned callback. Release mode accepts only a pinned-release
image and emits the three release-gate evidence values. Development mode
accepts only a development-local image and deliberately emits differently
named evidence that cannot satisfy the release gate.
EOF
	exit "$status"
}

if [[ $# == 1 && "$1" == --help ]]; then
	usage 0
fi
[[ $# == 1 ]] || usage 2
CONTAINER="$1"
[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || usage
[[ "${FIVEGPN_ACCEPTANCE_HOST:-}" == test-env ]] \
    || { echo 'refusing to run outside the explicit test-env gate' >&2; exit 2; }
[[ "${FIVEGPN_ACCEPTANCE_TARGET:-}" == disposable ]] \
    || { echo 'refusing mutating acceptance without FIVEGPN_ACCEPTANCE_TARGET=disposable' >&2; exit 2; }

ACCEPTANCE_MODE="${FIVEGPN_ACCEPTANCE_MODE:-release}"
EXPECTED_COMMIT="${FIVEGPN_EXPECTED_COMMIT:-}"
EXPECTED_MIHOMO_SHA256="${FIVEGPN_EXPECTED_MIHOMO_SHA256:-}"
EXPECTED_MIHOMO_BINARY_SHA256="${FIVEGPN_EXPECTED_MIHOMO_BINARY_SHA256:-}"
DEVELOPMENT_PROJECT="${FIVEGPN_DEVELOPMENT_PROJECT:-}"
DEVELOPMENT_BIND_IP="${FIVEGPN_DEVELOPMENT_BIND_IP:-}"
DEVELOPMENT_HOST_PORTS="${FIVEGPN_DEVELOPMENT_HOST_PORTS:-}"
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || { echo 'FIVEGPN_EXPECTED_COMMIT must be one exact 40-hex commit' >&2; exit 2; }
case "$ACCEPTANCE_MODE" in
    release)
        [[ "$EXPECTED_MIHOMO_SHA256" =~ ^[0-9a-f]{64}$ \
           && -z "$EXPECTED_MIHOMO_BINARY_SHA256" \
           && -z "$DEVELOPMENT_PROJECT" && -z "$DEVELOPMENT_BIND_IP" \
           && -z "$DEVELOPMENT_HOST_PORTS" ]] \
            || { echo 'release acceptance requires only the compressed mihomo artifact SHA-256' >&2; exit 2; }
        ;;
    development)
        [[ "$EXPECTED_MIHOMO_BINARY_SHA256" =~ ^[0-9a-f]{64}$ \
           && -z "$EXPECTED_MIHOMO_SHA256" \
           && "$DEVELOPMENT_PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ \
           && "$DEVELOPMENT_BIND_IP" == 127.0.0.1 \
           && -n "$DEVELOPMENT_HOST_PORTS" ]] \
            || { echo 'development acceptance requires a local binary digest, project, loopback bind, and explicit host-port map' >&2; exit 2; }
        ;;
    *)
        echo 'FIVEGPN_ACCEPTANCE_MODE must be release or development' >&2
        exit 2
        ;;
esac

for command in awk cmp curl docker find git grep hostname jq od openssl readlink sed seq sha256sum sort stat timeout tr uname wc; do
    command -v "$command" >/dev/null 2>&1 \
        || { echo "missing test-env command: $command" >&2; exit 2; }
done
[[ "$(hostname -s)" == test-env ]] \
    || { echo 'acceptance must execute on the real test-env host' >&2; exit 2; }
[[ "$(uname -m)" == x86_64 || "$(uname -m)" == amd64 ]] \
    || { echo 'test-env must be an amd64 Linux host' >&2; exit 2; }
if [[ -n "${DOCKER_HOST:-}" ]]; then
    [[ "$DOCKER_HOST" == unix:///* ]] \
        || { echo 'remote Docker endpoints are forbidden for test-env acceptance' >&2; exit 2; }
else
    docker_endpoint="$(docker context inspect "$(docker context show)" \
        | jq -r '.[0].Endpoints.docker.Host')"
    [[ "$docker_endpoint" == unix:///* ]] \
        || { echo 'the active Docker context is not a local Unix socket' >&2; exit 2; }
fi
if command -v getenforce >/dev/null 2>&1; then
    [[ "$(getenforce)" != Enforcing ]] \
        || { echo 'SELinux enforcing is outside the validated Docker boundary' >&2; exit 1; }
fi

HOST_BIND_IP=0.0.0.0
HOST_PORT_853=853
HOST_PORT_80=80
HOST_PORT_443=443
HOST_PORT_8080=8080
HOST_PORT_8443=8443
if [[ "$ACCEPTANCE_MODE" == development ]]; then
    jq -e '
      (keys | sort) == ["443","80","8080","8443","853"] and
      all(.[]; type == "number" and . == floor and . >= 1024 and . <= 65535) and
      ([.[]] | unique | length) == 5
    ' <<<"$DEVELOPMENT_HOST_PORTS" >/dev/null \
        || { echo 'FIVEGPN_DEVELOPMENT_HOST_PORTS must be five unique high TCP/UDP host ports' >&2; exit 2; }
    HOST_BIND_IP="$DEVELOPMENT_BIND_IP"
    HOST_PORT_853="$(jq -r '.["853"]' <<<"$DEVELOPMENT_HOST_PORTS")"
    HOST_PORT_80="$(jq -r '.["80"]' <<<"$DEVELOPMENT_HOST_PORTS")"
    HOST_PORT_443="$(jq -r '.["443"]' <<<"$DEVELOPMENT_HOST_PORTS")"
    HOST_PORT_8080="$(jq -r '.["8080"]' <<<"$DEVELOPMENT_HOST_PORTS")"
    HOST_PORT_8443="$(jq -r '.["8443"]' <<<"$DEVELOPMENT_HOST_PORTS")"
fi
VERSIONED_ACCEPTANCE_INPUTS=(
	"$PINS_ENV"
	"$PINS_LIBRARY"
	"$ROOT/tests/container-acceptance.sh"
	"$PROBE_LIBRARY"
	"$EXTENSION_PROBE"
	"$PUBLIC_CERT_PROBE"
	"$RECREATE_PROBE"
	"$ROOT/compose.yaml"
	"$SECCOMP_PROFILE"
)
for file in "${VERSIONED_ACCEPTANCE_INPUTS[@]}"; do
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] \
        || { echo "versioned acceptance input is missing, unreadable, or symlinked: $file" >&2; exit 2; }
done
[[ -x "$EXTENSION_PROBE" && -x "$RECREATE_PROBE" ]] \
    || { echo 'host-side versioned probes must be executable' >&2; exit 2; }

actual_checkout_root="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" \
	|| { echo 'acceptance must run from the root of a Git checkout' >&2; exit 2; }
[[ "$actual_checkout_root" == "$ROOT" ]] \
	|| { echo "acceptance Git root $actual_checkout_root does not match driver root $ROOT" >&2; exit 2; }
actual_checkout_commit="$(git -C "$ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
	|| { echo 'acceptance must run from a Git checkout with an exact HEAD commit' >&2; exit 2; }
[[ "$actual_checkout_commit" == "$EXPECTED_COMMIT" ]] \
	|| { echo "acceptance checkout $actual_checkout_commit does not match expected commit $EXPECTED_COMMIT" >&2; exit 2; }
for file in "${VERSIONED_ACCEPTANCE_INPUTS[@]}"; do
	relative="${file#"$ROOT"/}"
	git -C "$ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
		|| { echo "acceptance input is not tracked by the expected commit: $relative" >&2; exit 2; }
	git -C "$ROOT" diff --quiet HEAD -- "$relative" \
		|| { echo "acceptance input differs from the expected commit: $relative" >&2; exit 2; }
	git -C "$ROOT" show "HEAD:$relative" | cmp -s - "$file" \
		|| { echo "acceptance input bytes differ from the expected commit: $relative" >&2; exit 2; }
done

# Load the pin parser only after both its code and data have been proven to be
# exact files from the accepted commit. Release evidence is valid only for the
# Core digest that this same commit ships.
# shellcheck source=../release/pins.sh
source "$PINS_LIBRARY"
load_release_pins "$PINS_ENV" \
    || { echo 'the accepted commit has an invalid centralized pin generation' >&2; exit 2; }
PINNED_MIHOMO_SHA256="$(release_artifact_sha256 mihomo)" \
    || { echo 'the accepted pin generation has no Core artifact digest' >&2; exit 2; }
if [[ "$ACCEPTANCE_MODE" == release \
   && "$EXPECTED_MIHOMO_SHA256" != "$PINNED_MIHOMO_SHA256" ]]; then
    echo 'release acceptance digest does not match this commit release/pins.env' >&2
    exit 2
fi

probe_bundle_sha="$({
    printf 'commit  %s\n' "$EXPECTED_COMMIT"
    for file in "${VERSIONED_ACCEPTANCE_INPUTS[@]}"; do
        printf '%s  %s\n' "$(sha256sum "$file" | awk '{print $1}')" "${file#"$ROOT/"}"
    done
} | sha256sum | awk '{print $1}')"
[[ "$probe_bundle_sha" =~ ^[0-9a-f]{64}$ ]] \
    || { echo 'could not identify the versioned acceptance probe bundle' >&2; exit 2; }

docker_version="$(docker version --format '{{.Server.Version}}')"
docker_major="${docker_version%%.*}"
[[ "$docker_major" =~ ^[0-9]+$ && "$docker_major" -ge 28 ]] \
    || { echo "Docker Engine 28+ required, found $docker_version" >&2; exit 1; }
[[ -f /sys/fs/cgroup/cgroup.controllers ]] \
    || { echo 'test-env is not using a pure cgroup v2 hierarchy' >&2; exit 1; }
[[ "$(docker info --format '{{.CgroupVersion}}')" == 2 \
   && "$(docker info --format '{{.CgroupDriver}}')" == systemd ]] \
    || { echo 'Docker must use cgroup v2 with the systemd driver' >&2; exit 1; }
docker info --format '{{json .SecurityOptions}}' \
    | jq -e 'all(.[];
        (contains("name=userns") | not) and
        (contains("name=rootless") | not))' >/dev/null \
    || { echo 'rootless Docker or daemon userns-remap is outside the supported contract' >&2; exit 1; }

assert_container_boundary() {
    local inspect image_id labels label_binary_sha actual_binary_sha
    local manifest_binary_sha manifest_pinned_sha manifest_source manifest_contract network
    local actual_seccomp expected_seccomp
    inspect="$(docker inspect "$CONTAINER")"
    jq -e --arg mode "$ACCEPTANCE_MODE" --arg bind "$HOST_BIND_IP" \
      --arg p853 "$HOST_PORT_853" --arg p80 "$HOST_PORT_80" \
      --arg p443 "$HOST_PORT_443" \
      --arg p8080 "$HOST_PORT_8080" --arg p8443 "$HOST_PORT_8443" '
      def binding($container; $host):
        .[0].HostConfig.PortBindings[$container] ==
          [{"HostIp":$bind,"HostPort":$host}];
      def tmpfs($path; $mode):
        (.[0].HostConfig.Tmpfs[$path] | split(",")) as $options |
        ($options | index("uid=10001") != null) and
        ($options | index("gid=10001") != null) and
        ($options | index("mode=" + $mode) != null);
      length == 1 and
      .[0].State.Running == true and
      .[0].Config.User == "10001:10001" and
      .[0].Path == "/opt/5gpn/bin/docker-entrypoint.sh" and
      ([.[0].Config.Env[] | select(. == "FIVEGPN_RUNTIME=container")] | length) == 1 and
      .[0].HostConfig.Privileged == false and
      .[0].AppArmorProfile == "docker-default" and
      .[0].HostConfig.ReadonlyRootfs == true and
      .[0].HostConfig.UsernsMode == "" and
      (.[0].HostConfig.Devices | length) == 0 and
      (.[0].HostConfig.GroupAdd == null or .[0].HostConfig.GroupAdd == []) and
      (.[0].HostConfig.NetworkMode != "host") and
      (.[0].HostConfig.NetworkMode != "bridge") and
      (.[0].HostConfig.NetworkMode != "default") and
      (.[0].HostConfig.NetworkMode != "none") and
      .[0].HostConfig.CgroupnsMode == "private" and
      .[0].HostConfig.CapDrop == ["ALL"] and
      (.[0].HostConfig.CapAdd == null or .[0].HostConfig.CapAdd == []) and
      .[0].HostConfig.Sysctls == {"net.ipv4.ip_unprivileged_port_start":"0"} and
      .[0].Config.StopSignal == "SIGTERM" and
      .[0].HostConfig.PidsLimit == 256 and
      .[0].HostConfig.PublishAllPorts == false and
      (.[0].HostConfig.SecurityOpt | any(. == "writable-cgroups=true")) and
      (.[0].HostConfig.SecurityOpt | any(. == "no-new-privileges=true")) and
      ([.[0].HostConfig.SecurityOpt[] | select(startswith("seccomp="))] | length == 1) and
      (.[0].HostConfig.SecurityOpt | all(
        . != "seccomp=unconfined" and . != "seccomp=builtin" and . != "seccomp=default"
      )) and
      (.[0].HostConfig.PortBindings | keys | sort) ==
        ["80/tcp","8080/tcp","8443/tcp","853/tcp","9443/tcp","9443/udp"] and
      binding("853/tcp"; $p853) and
      binding("80/tcp"; $p80) and
      binding("9443/tcp"; $p443) and
      binding("9443/udp"; $p443) and
      binding("8080/tcp"; $p8080) and
      binding("8443/tcp"; $p8443) and
      ([.[0].Mounts[] | select(.Type == "volume" and
          .Destination == "/etc/5gpn" and .RW == true)] | length) == 1 and
      ([.[0].Mounts[] | select(.Type == "volume" and
          .Destination == "/opt/5gpn/ui" and .RW == true)] | length) == 1 and
      ([.[0].Mounts[] | select(.Type == "bind" and
          (.Destination == "/run/5gpn-bootstrap-input/config.env" or
           .Destination == "/run/secrets/cloudflare_api_token") and
          .RW == false)] | length) == 2 and
      (.[0].Mounts | length) == 4 and
      (.[0].Mounts | all(
        .Destination != "/sys/fs/cgroup" and .Source != "/sys/fs/cgroup" and
        .Destination != "/var/run/docker.sock" and .Destination != "/run/docker.sock" and
        .Source != "/var/run/docker.sock" and .Source != "/run/docker.sock"
      )) and
      (.[0].HostConfig.Tmpfs | keys | sort) ==
        ["/run/5gpn","/run/5gpn-bootstrap","/tmp","/var/tmp"] and
      tmpfs("/run/5gpn"; "0700") and
      tmpfs("/run/5gpn-bootstrap"; "0700") and
      tmpfs("/tmp"; "1777") and tmpfs("/var/tmp"; "1777") and
      (.[0].NetworkSettings.Networks | length) == 1 and
      (if $mode == "release" then
         .[0].Config.Labels["com.docker.compose.service"] == "gateway" and
         (.[0].Config.Labels["com.docker.compose.project"] | test("^[a-z0-9][a-z0-9_-]*$")) and
         .[0].HostConfig.RestartPolicy.Name == "unless-stopped" and
         .[0].HostConfig.Init == false and .[0].Config.StopTimeout == 45
       else
         ((.[0].Config.Labels["com.docker.compose.service"] // "gateway") == "gateway") and
         ((.[0].Config.Labels["com.docker.compose.project"] // "development") |
            test("^[a-z0-9][a-z0-9_-]*$")) and
         (.[0].HostConfig.RestartPolicy.Name == "no" or
          .[0].HostConfig.RestartPolicy.Name == "unless-stopped") and
         (.[0].HostConfig.Init == null or .[0].HostConfig.Init == false) and
         (.[0].Config.StopTimeout == null or .[0].Config.StopTimeout == 45)
       end)
    ' <<<"$inspect" >/dev/null \
        || { echo 'candidate container does not match the supported Compose boundary' >&2; return 1; }

    network="$(jq -r '.[0].HostConfig.NetworkMode' <<<"$inspect")"
    docker network inspect "$network" | jq -e '
      length == 1 and .[0].Driver == "bridge" and
      .[0].Internal == false and .[0].EnableIPv6 == false
    ' >/dev/null \
        || { echo 'candidate does not use one user-defined IPv4 bridge' >&2; return 1; }
    [[ "$(jq -r '[.[0].NetworkSettings.Networks | to_entries[] |
        select(.value.GlobalIPv6Address != "")] | length' <<<"$inspect")" == 0 ]] \
        || { echo 'candidate unexpectedly acquired an IPv6 container address' >&2; return 1; }

    actual_seccomp="$(jq -r '
      [.[0].HostConfig.SecurityOpt[] | select(startswith("seccomp="))][0] |
      sub("^seccomp="; "")
    ' <<<"$inspect" | jq -S -c .)"
    expected_seccomp="$(jq -S -c . "$SECCOMP_PROFILE")"
    [[ "$actual_seccomp" == "$expected_seccomp" ]] \
        || { echo 'candidate is not using the exact shipped clone3-aware seccomp profile' >&2; return 1; }

    image_id="$(jq -r '.[0].Image' <<<"$inspect")"
    labels="$(docker image inspect "$image_id" | jq -S -c '.[0].Config.Labels')"
    jq -e --arg commit "$EXPECTED_COMMIT" --arg mode "$ACCEPTANCE_MODE" \
      --arg artifact "$EXPECTED_MIHOMO_SHA256" --arg binary "$EXPECTED_MIHOMO_BINARY_SHA256" \
      --arg core_version "$MIHOMO_VERSION" --arg zash_version "$ZASH_VERSION" \
      --arg zash_sha "$ZASH_SHA256" '
      .[0].Os == "linux" and .[0].Architecture == "amd64" and
      .[0].Config.Labels["org.opencontainers.image.revision"] == $commit and
      .[0].Config.Labels["io.5gpn.mihomo.container-contract"] == "5gpn-container-runtime-v2" and
      .[0].Config.Labels["io.5gpn.mihomo.version"] == $core_version and
      .[0].Config.Labels["io.5gpn.zashboard.version"] == $zash_version and
      .[0].Config.Labels["io.5gpn.zashboard.sha256"] == $zash_sha and
      (.[0].Config.Labels["io.5gpn.mihomo.binary.sha256"] | test("^[0-9a-f]{64}$")) and
      (if $mode == "release" then
         .[0].Config.Labels["io.5gpn.mihomo.source"] == "pinned-release" and
         .[0].Config.Labels["io.5gpn.mihomo.sha256"] == $artifact
       else
         .[0].Config.Labels["io.5gpn.mihomo.source"] == "development-local" and
         .[0].Config.Labels["io.5gpn.mihomo.binary.sha256"] == $binary
       end)
    ' < <(docker image inspect "$image_id") >/dev/null \
        || { echo "candidate image labels do not match $ACCEPTANCE_MODE acceptance" >&2; return 1; }

    label_binary_sha="$(jq -r '.[0].Config.Labels["io.5gpn.mihomo.binary.sha256"]' \
      < <(docker image inspect "$image_id"))"
    actual_binary_sha="$(docker exec "$CONTAINER" sha256sum /opt/5gpn/bin/5gpn-mihomo | awk '{print $1}')"
    manifest_binary_sha="$(docker exec "$CONTAINER" sed -n \
      's/^MIHOMO_BINARY_SHA256=//p' /usr/share/5gpn/components.env)"
    manifest_pinned_sha="$(docker exec "$CONTAINER" sed -n \
      's/^MIHOMO_SHA256=//p' /usr/share/5gpn/components.env)"
    manifest_source="$(docker exec "$CONTAINER" sed -n \
      's/^MIHOMO_SOURCE=//p' /usr/share/5gpn/components.env)"
    manifest_contract="$(docker exec "$CONTAINER" sed -n \
      's/^MIHOMO_CONTAINER_CONTRACT=//p' /usr/share/5gpn/components.env)"
    [[ "$actual_binary_sha" == "$label_binary_sha" \
       && "$manifest_binary_sha" == "$label_binary_sha" \
       && "$manifest_contract" == 5gpn-container-runtime-v2 ]] \
        || { echo 'candidate image label, manifest, and runtime binary digest differ' >&2; return 1; }
    if [[ "$ACCEPTANCE_MODE" == release ]]; then
        [[ "$manifest_source" == pinned-release \
           && "$manifest_pinned_sha" == "$EXPECTED_MIHOMO_SHA256" ]] \
            || { echo 'release manifest does not contain the expected compressed artifact pin' >&2; return 1; }
    else
        [[ "$manifest_source" == development-local \
           && "$label_binary_sha" == "$EXPECTED_MIHOMO_BINARY_SHA256" ]] \
            || { echo 'development manifest does not contain the expected local binary digest' >&2; return 1; }
    fi
    printf '%s\n' "$labels"
}

before_image_labels="$(assert_container_boundary)"

check_process_boundary() {
    docker exec "$CONTAINER" /bin/bash -euo pipefail -c '
      [[ "$(readlink -f /proc/1/exe)" == /opt/5gpn/bin/5gpn-mihomo ]]
      [[ "$(tr "\000" "\n" < /proc/1/cmdline | sed -n "1p")" == /opt/5gpn/bin/5gpn-mihomo ]]
      tr "\000" "\n" < /proc/1/cmdline | grep -Fx -- -f >/dev/null
      tr "\000" "\n" < /proc/1/cmdline | grep -Fx /etc/5gpn/mihomo/config.yaml >/dev/null
      tr "\000" "\n" < /proc/1/cmdline | grep -Fx -- -d >/dev/null
      tr "\000" "\n" < /proc/1/cmdline | grep -Fx /etc/5gpn/mihomo >/dev/null
      [[ "$(tr "\000" "\n" < /proc/1/environ | grep -Fxc FIVEGPN_RUNTIME=container)" == 1 ]]
      awk '\''
        $1 == "Uid:" { if ($2 != 10001 || $3 != 10001 || $4 != 10001 || $5 != 10001) exit 1; uid=1 }
        $1 == "Gid:" { if ($2 != 10001 || $3 != 10001 || $4 != 10001 || $5 != 10001) exit 1; gid=1 }
        $1 == "Groups:" {
          if (NF != 2 || $2 != 10001) exit 1
          groups=1
        }
        $1 == "CapPrm:" { if ($2 != "0000000000000000") exit 1; prm=1 }
        $1 == "CapEff:" { if ($2 != "0000000000000000") exit 1; eff=1 }
        $1 == "CapBnd:" { if ($2 != "0000000000000000") exit 1; bnd=1 }
        $1 == "CapAmb:" { if ($2 != "0000000000000000") exit 1; amb=1 }
        $1 == "NoNewPrivs:" { if ($2 != 1) exit 1; nnp=1 }
        $1 == "Seccomp:" { if ($2 != 2) exit 1; seccomp=1 }
        END { if (!(uid && gid && groups && prm && eff && bnd && amb && nnp && seccomp)) exit 1 }
      '\'' /proc/1/status
      [[ "$(cat /proc/1/cgroup)" == "0::/main" ]]
      [[ ! -s /sys/fs/cgroup/cgroup.procs ]]
      # Docker 28 delegates ownership of the cgroup control files to the fixed
      # UID. The mount group remains root and is not an authorization grant.
      [[ "$(stat -c %u /sys/fs/cgroup)" == 10001 ]]
      [[ "$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)" == 0 ]]
      grep -qw memory /sys/fs/cgroup/cgroup.controllers
      grep -qw pids /sys/fs/cgroup/cgroup.controllers
      grep -qw memory /sys/fs/cgroup/cgroup.subtree_control
      grep -qw pids /sys/fs/cgroup/cgroup.subtree_control
      shopt -s nullglob
      aggregates=(/sys/fs/cgroup/workers.1.*)
      [[ ${#aggregates[@]} == 1 && -d "${aggregates[0]}" ]]
      [[ "$(cat "${aggregates[0]}/memory.max")" == 1073741824 ]]
      [[ "$(cat "${aggregates[0]}/memory.swap.max")" == 0 ]]
      # Only a one-operation leaf is an OOM group. Marking the two-worker
      # aggregate would let one action kill its healthy sibling.
      [[ "$(cat "${aggregates[0]}/memory.oom.group")" == 0 ]]
      [[ "$(cat "${aggregates[0]}/pids.max")" == 64 ]]
    '
}

CAPABILITIES_URL="${FIVEGPN_CAPABILITIES_URL:-}"
SECRET_FILE="${FIVEGPN_CONTROLLER_SECRET_FILE:-}"
CONTROLLER_RESOLVE_IP="${FIVEGPN_CONTROLLER_RESOLVE_IP:-}"
CONTROLLER_CA_FILE="${FIVEGPN_CONTROLLER_CA_FILE:-}"
if [[ "$CAPABILITIES_URL" =~ ^https://([a-z0-9][a-z0-9.-]{0,251}[a-z0-9])(:([0-9]{1,5}))?/capabilities$ ]]; then
    CONTROLLER_HOST="${BASH_REMATCH[1]}"
    CONTROLLER_PORT="${BASH_REMATCH[3]:-443}"
else
    echo 'FIVEGPN_CAPABILITIES_URL must be an https hostname on /capabilities' >&2
    exit 2
fi
[[ "$CONTROLLER_PORT" == "$HOST_PORT_443" ]] \
    || { echo 'capabilities URL port must match the accepted HTTPS host publication' >&2; exit 2; }
[[ -f "$SECRET_FILE" && ! -L "$SECRET_FILE" \
   && "$(stat -c %a "$SECRET_FILE")" == 600 \
   && "$(stat -c %h "$SECRET_FILE")" == 1 \
   && "$(stat -c %s "$SECRET_FILE")" -le 4096 ]] \
    || { echo 'controller secret file must be a bounded mode-0600 regular single-link file' >&2; exit 2; }
mapfile -t secret_lines < "$SECRET_FILE"
[[ "${#secret_lines[@]}" == 1 \
   && "${#secret_lines[0]}" -ge 16 \
   && "${#secret_lines[0]}" -le 512 \
   && "${secret_lines[0]}" != *[[:space:]]* ]] \
    || { echo 'controller secret file must contain one bounded non-whitespace token' >&2; exit 2; }
if [[ -n "$CONTROLLER_RESOLVE_IP" ]]; then
    [[ "$CONTROLLER_RESOLVE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || { echo 'FIVEGPN_CONTROLLER_RESOLVE_IP must be IPv4' >&2; exit 2; }
    IFS=. read -r -a resolve_octets <<<"$CONTROLLER_RESOLVE_IP"
    for octet in "${resolve_octets[@]}"; do
        [[ "$octet" != 0* || "$octet" == 0 ]] && ((10#$octet <= 255)) \
            || { echo 'FIVEGPN_CONTROLLER_RESOLVE_IP is not canonical IPv4' >&2; exit 2; }
    done
fi
if [[ -n "$CONTROLLER_CA_FILE" ]]; then
    [[ -f "$CONTROLLER_CA_FILE" && ! -L "$CONTROLLER_CA_FILE" \
       && "$(stat -c %h "$CONTROLLER_CA_FILE")" == 1 \
       && "$(stat -c %s "$CONTROLLER_CA_FILE")" -gt 0 \
       && "$(stat -c %s "$CONTROLLER_CA_FILE")" -le 1048576 ]] \
        || { echo 'FIVEGPN_CONTROLLER_CA_FILE is unsafe or unbounded' >&2; exit 2; }
    ca_mode="$(stat -c %a "$CONTROLLER_CA_FILE")"
    (( (8#$ca_mode & 0022) == 0 )) \
        || { echo 'FIVEGPN_CONTROLLER_CA_FILE is group/world writable' >&2; exit 2; }
    openssl crl2pkcs7 -nocrl -certfile "$CONTROLLER_CA_FILE" 2>/dev/null \
        | openssl pkcs7 -print_certs -noout >/dev/null 2>&1 \
        || { echo 'FIVEGPN_CONTROLLER_CA_FILE contains no parseable certificates' >&2; exit 2; }
fi

header_file="$(mktemp /tmp/5gpn-container-acceptance-header.XXXXXX)"
chmod 0600 "$header_file"
RECREATE_BACKUP=''
RECREATE_ORIGINAL=''
cleanup() {
    local rc=$?
    rm -f -- "$header_file"
    if [[ -n "$RECREATE_BACKUP" && -n "$RECREATE_ORIGINAL" ]] \
       && docker inspect "$RECREATE_BACKUP" >/dev/null 2>&1; then
        docker rm -f "$RECREATE_ORIGINAL" >/dev/null 2>&1 || true
        if docker rename "$RECREATE_BACKUP" "$RECREATE_ORIGINAL" >/dev/null 2>&1; then
            docker start "$RECREATE_ORIGINAL" >/dev/null 2>&1 || true
        fi
    fi
    return "$rc"
}
trap cleanup EXIT
printf 'Authorization: Bearer %s\n' "${secret_lines[0]}" > "$header_file"
CONTROLLER_SECRET="${secret_lines[0]}"
unset secret_lines

export FIVEGPN_ACCEPTANCE_INTERNAL=5gpn-container-acceptance-v2
export FIVEGPN_PROBE_CONTAINER="$CONTAINER"
export FIVEGPN_PROBE_HEADER_FILE="$header_file"
export FIVEGPN_PROBE_API_ORIGIN="${CAPABILITIES_URL%/capabilities}"
export FIVEGPN_PROBE_CONTROLLER_HOST="$CONTROLLER_HOST"
export FIVEGPN_PROBE_CONTROLLER_PORT="$CONTROLLER_PORT"
export FIVEGPN_PROBE_CONTROLLER_RESOLVE_IP="$CONTROLLER_RESOLVE_IP"
export FIVEGPN_PROBE_CONTROLLER_CA_FILE="$CONTROLLER_CA_FILE"
export FIVEGPN_PROBE_SECCOMP_PROFILE="$SECCOMP_PROFILE"
export FIVEGPN_PROBE_ACCEPTANCE_MODE="$ACCEPTANCE_MODE"
export FIVEGPN_PROBE_DEVELOPMENT_PROJECT="$DEVELOPMENT_PROJECT"
export FIVEGPN_PROBE_HOST_BIND_IP="$HOST_BIND_IP"
export FIVEGPN_PROBE_HOST_PORT_853="$HOST_PORT_853"
export FIVEGPN_PROBE_HOST_PORT_80="$HOST_PORT_80"
export FIVEGPN_PROBE_HOST_PORT_443="$HOST_PORT_443"
export FIVEGPN_PROBE_HOST_PORT_8080="$HOST_PORT_8080"
export FIVEGPN_PROBE_HOST_PORT_8443="$HOST_PORT_8443"
# shellcheck source=docker/probe-lib.sh
source "$PROBE_LIBRARY"

assert_pid1_live() {
    docker inspect "$CONTAINER" \
        | jq -e '.[0].State.Running == true and .[0].State.Pid > 0' >/dev/null
    wait_for_authenticated_capabilities
}

host_served_serial() {
    local port="$1" name="$2" output serial
    local -a args=(
        -connect "127.0.0.1:${port}"
        -servername "$name"
        -verify_hostname "$name"
        -verify_return_error
        -showcerts
    )
    [[ -z "$CONTROLLER_CA_FILE" ]] || args+=(-CAfile "$CONTROLLER_CA_FILE")
    output="$(timeout 12 openssl s_client "${args[@]}" </dev/null 2>/dev/null)" \
        || { echo "host TLS publication failed for $name on port $port" >&2; return 1; }
    serial="$(openssl x509 -noout -serial <<<"$output" 2>/dev/null | sed -n 's/^serial=//p')"
    [[ "$serial" =~ ^[0-9A-Fa-f]+$ ]] \
        || { echo "host TLS publication returned no leaf for $name" >&2; return 1; }
    printf '%s\n' "${serial^^}"
}

check_host_publication() {
    local base dot_host console_host dot_expected console_expected dot_served console_served
    base="$(docker exec "$CONTAINER" sed -n 's/^DNS_BASE_DOMAIN=//p' /etc/5gpn/dns.env)"
    [[ "$base" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
        || { echo 'candidate base domain is invalid' >&2; return 1; }
    dot_host="dot.${base}"
    console_host="console.${base}"
    dot_expected="$(docker exec "$CONTAINER" openssl x509 \
        -in /etc/5gpn/cert/dot/current/fullchain.pem -noout -serial \
        | sed -n 's/^serial=//p')"
    console_expected="$(docker exec "$CONTAINER" openssl x509 \
        -in /etc/5gpn/cert/console/current/fullchain.pem -noout -serial \
        | sed -n 's/^serial=//p')"
    dot_served="$(host_served_serial "$HOST_PORT_853" "$dot_host")"
    console_served="$(host_served_serial "$HOST_PORT_443" "$console_host")"
    [[ "${dot_expected^^}" == "$dot_served" \
       && "${console_expected^^}" == "$console_served" ]] \
        || { printf 'host port certificate mismatch: dot=%s/%s console=%s/%s\n' \
            "$dot_expected" "$dot_served" "$console_expected" "$console_served" >&2; return 1; }
}

check_persisted_bootstrap_contract() {
    local projection state
    [[ "$(docker exec "$CONTAINER" /opt/5gpn/bin/5gpn-mihomo \
        5gpn-container-contract)" == 5gpn-container-runtime-v2 ]] \
        || { echo 'live Core does not report container runtime contract v2' >&2; return 1; }
    projection="$(docker exec "$CONTAINER" /opt/5gpn/bin/5gpn-mihomo \
        5gpn-config inspect-controller --owner-uid 10001 \
        --config /etc/5gpn/mihomo/config.yaml)" \
        || { echo 'owner-scoped controller inspection failed in the live image' >&2; return 1; }
    jq -e '
      type == "object" and .version == 2 and
      (.raw_revision | test("^[0-9a-f]{64}$")) and
      .external_controller_tls == "127.0.0.1:443" and
      .external_ui == "/opt/5gpn/ui/current" and
      .certificate == "/etc/5gpn/cert/console/current/fullchain.pem" and
      .private_key == "/etc/5gpn/cert/console/current/privkey.pem" and
      (.secret | type == "string" and length >= 16 and length <= 256) and
      ((keys | sort) == ["certificate","external_controller_tls","external_ui",
                         "private_key","raw_revision","secret","version"])
    ' <<<"$projection" >/dev/null \
        || { echo 'live operator config does not match controller inspector v2' >&2; return 1; }
    [[ "$(jq -r .secret <<<"$projection")" == "$CONTROLLER_SECRET" ]] \
        || { echo 'authenticated acceptance secret differs from operator config' >&2; return 1; }

    state="$(docker exec "$CONTAINER" /opt/5gpn/bin/5gpn-mihomo \
        5gpn-state validate --owner-uid 10001 /etc/5gpn/mihomo/5gpn)" \
        || { echo 'live runtime documents failed the owner-scoped Core validator' >&2; return 1; }
    jq -e '
      .status == "ok" and (.validated | type == "array") and
      (.validated | index("dns.json") != null) and (.missing | type == "array")
    ' <<<"$state" >/dev/null \
        || { echo 'live runtime validator returned an incomplete result' >&2; return 1; }

    docker exec "$CONTAINER" /bin/bash -euo pipefail -c '
      [[ "$(stat -c "%u:%g:%a:%h" /etc/5gpn/dns.env)" == 10001:10001:600:1 ]]
      [[ "$(stat -c "%u:%g:%a:%h" /etc/5gpn/.5gpn-docker-schema)" == 10001:10001:644:1 ]]
      [[ "$(cat /etc/5gpn/.5gpn-docker-schema)" == 5gpn-docker-state-v2 ]]
      [[ "$(stat -c "%u:%g:%a" /etc/5gpn/mihomo/5gpn)" == 10001:10001:711 ]]
      mapfile -t keys < <(
        sed -e "/^[[:space:]]*#/d" -e "/^[[:space:]]*$/d" \
            -e "s/=.*//" /etc/5gpn/dns.env | LC_ALL=C sort
      )
      expected=(CERT_EMAIL CERT_MODE DNS_BASE_DOMAIN DNS_GATEWAY_IP DNS_MIHOMO_LISTEN_IPS DNS_PUBLIC_IP)
      [[ "${#keys[@]}" == 6 && "${keys[*]}" == "${expected[*]}" ]]
      ! grep -Fq DNS_MIHOMO_SECRET /etc/5gpn/dns.env
      ! grep -Eq "^(DNS_LISTEN_DOT|DNS_LISTEN_DEBUG|DNS_MIHOMO_CONTROLLER|DNS_CONSOLE_CERT|DNS_CONSOLE_KEY)=" \
        /etc/5gpn/dns.env

      FIVEGPN_RUNTIME=container /opt/5gpn/scripts/ui-generation.sh validate-current
      current="$(readlink -- /opt/5gpn/ui/current)"
      [[ "$current" == generations/generation-* ]]
      generation="/opt/5gpn/ui/$current"
      [[ -s "$generation/index.html" \
         && -s "$generation/ios-dot.mobileconfig" \
         && -s "$generation/ios-intercept-ca.mobileconfig" \
         && -s "$generation/.5gpn-profile-inputs" ]]
      [[ ! -e /opt/5gpn/ui/ios-dot.mobileconfig \
         && ! -e /opt/5gpn/ui/ios-intercept-ca.mobileconfig ]]
    ' || { echo 'persistent six-key state or Console generation is invalid' >&2; return 1; }
}

wait_for_authenticated_capabilities
check_process_boundary
check_persisted_bootstrap_contract

extension_evidence="$($EXTENSION_PROBE)"
printf '%s\n' "$extension_evidence"
assert_pid1_live
check_process_boundary

public_evidence="$(docker exec -i --user 10001:10001 \
    --env FIVEGPN_ACCEPTANCE_INTERNAL=5gpn-container-acceptance-v2 \
    "$CONTAINER" /bin/bash -s < "$PUBLIC_CERT_PROBE")"
printf '%s\n' "$public_evidence"
assert_pid1_live
check_host_publication

persistent_state_fingerprint() {
    docker exec "$CONTAINER" /bin/bash -euo pipefail -c '
      base="$(sed -n "s/^DNS_BASE_DOMAIN=//p" /etc/5gpn/dns.env)"
      [[ "$base" =~ ^[a-z0-9.-]+$ ]]
      lineage=/etc/5gpn/letsencrypt/live/$base
      ready=/etc/5gpn/letsencrypt/.5gpn-docker-lineage-ready
      [[ "$(stat -c "%u:%g:%a" "$ready")" == 10001:10001:600 ]]
      [[ "$(cat "$ready")" == "5gpn-docker-lineage-ready-v1:$base" ]]
      [[ "$(stat -c "%u:%g:%a" /etc/5gpn/intercept-ca/root.key)" == 10001:10001:600 ]]
      [[ "$(stat -c "%u:%g:%a" /etc/5gpn/intercept-ca/root.crt)" == 10001:10001:644 ]]
      ca_marker=/etc/5gpn/intercept-ca/.5gpn-intercept-ca-owned
      [[ "$(stat -c "%u:%g:%a" "$ca_marker")" == 10001:10001:644 ]]
      [[ "$(cat "$ca_marker")" == 5gpn-intercept-ca-v1 ]]

      ca_cert_pub="$(openssl x509 -in /etc/5gpn/intercept-ca/root.crt -pubkey -noout | openssl sha256)"
      ca_key_pub="$(openssl pkey -in /etc/5gpn/intercept-ca/root.key -pubout | openssl sha256)"
      [[ -n "$ca_cert_pub" && "$ca_cert_pub" == "$ca_key_pub" ]]
      public_cert_pub="$(openssl x509 -in "$lineage/fullchain.pem" -pubkey -noout | openssl sha256)"
      public_key_pub="$(openssl pkey -in "$lineage/privkey.pem" -pubout | openssl sha256)"
      [[ -n "$public_cert_pub" && "$public_cert_pub" == "$public_key_pub" ]]
      for role in dot console; do
        cmp -s "$lineage/fullchain.pem" "/etc/5gpn/cert/$role/current/fullchain.pem"
        cmp -s "$lineage/privkey.pem" "/etc/5gpn/cert/$role/current/privkey.pem"
      done

      {
        while IFS= read -r -d "" path; do
          [[ "$path" != *$'\''\n'\''* && "$path" != *$'\''\r'\''* ]]
          metadata="$(stat -c "%F:%u:%g:%a:%s" -- "$path")"
          if [[ -L "$path" ]]; then
            target="$(readlink -- "$path")"
            [[ -n "$target" && "$target" != *$'\''\n'\''* && "$target" != *$'\''\r'\''* ]]
            printf "link %s %s %s\n" "$path" "$metadata" "$target"
          elif [[ -f "$path" ]]; then
            digest="$(sha256sum -- "$path" | awk "{print \$1}")"
            [[ "$digest" =~ ^[0-9a-f]{64}$ ]]
            printf "file %s %s %s\n" "$path" "$metadata" "$digest"
          elif [[ -d "$path" ]]; then
            printf "directory %s %s\n" "$path" "$metadata"
          else
            exit 1
          fi
        done < <(
          find /etc/5gpn -xdev \
            \( -path /etc/5gpn/letsencrypt/log \
               -o -path /etc/5gpn/letsencrypt/work \
               -o -path /etc/5gpn/mihomo/5gpn/dns-rules \
               -o -path /etc/5gpn/mihomo/cache.db \) -prune \
            -o -print0
          find /opt/5gpn/ui -xdev -print0
        )
      } | LC_ALL=C sort | sha256sum | awk "{print \$1}"
    '
}

before_state="$(persistent_state_fingerprint)"
before_id="$(docker inspect --format '{{.Id}}' "$CONTAINER")"
before_image="$(docker inspect --format '{{.Image}}' "$CONTAINER")"
before_volume="$(docker inspect "$CONTAINER" | jq -r '
  [.[0].Mounts[] | select(.Destination == "/etc/5gpn" and .Type == "volume")] |
  if length == 1 then .[0].Name else empty end
')"
before_ui_volume="$(docker inspect "$CONTAINER" | jq -r '
  [.[0].Mounts[] | select(.Destination == "/opt/5gpn/ui" and .Type == "volume")] |
  if length == 1 then .[0].Name else empty end
')"
[[ -n "$before_volume" && -n "$before_ui_volume" \
   && "$before_volume" != "$before_ui_volume" ]] \
    || { echo 'candidate does not have distinct named state and Console volumes' >&2; exit 1; }

recreate_result="$($RECREATE_PROBE)"
read -r new_container RECREATE_BACKUP recreate_extra <<<"$recreate_result"
[[ "$new_container" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ \
   && "$RECREATE_BACKUP" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ \
   && -z "$recreate_extra" ]] \
    || { echo 'versioned recreate probe did not return one new/rollback container pair' >&2; exit 1; }
RECREATE_ORIGINAL="$new_container"
docker inspect "$RECREATE_BACKUP" \
    | jq -e '.[0].State.Running == false' >/dev/null \
    || { echo 'recreate rollback container is missing or still running' >&2; exit 1; }
CONTAINER="$new_container"
export FIVEGPN_PROBE_CONTAINER="$CONTAINER"
wait_for_authenticated_capabilities
after_id="$(docker inspect --format '{{.Id}}' "$CONTAINER")"
after_image="$(docker inspect --format '{{.Image}}' "$CONTAINER")"
after_image_labels="$(assert_container_boundary)"
after_volume="$(docker inspect "$CONTAINER" | jq -r '
  [.[0].Mounts[] | select(.Destination == "/etc/5gpn" and .Type == "volume")] |
  if length == 1 then .[0].Name else empty end
')"
after_ui_volume="$(docker inspect "$CONTAINER" | jq -r '
  [.[0].Mounts[] | select(.Destination == "/opt/5gpn/ui" and .Type == "volume")] |
  if length == 1 then .[0].Name else empty end
')"
[[ "$after_id" != "$before_id" \
   && "$after_volume" == "$before_volume" \
   && "$after_ui_volume" == "$before_ui_volume" \
   && "$after_image" == "$before_image" \
   && "$after_image_labels" == "$before_image_labels" ]] \
    || { echo 'recreate did not preserve the exact image boundary and named volume' >&2; exit 1; }
after_state="$(persistent_state_fingerprint)"
[[ "$after_state" == "$before_state" ]] \
    || { echo 'configuration, CA, lineage, role, Console, or state bytes changed across recreate' >&2; exit 1; }
check_process_boundary
check_host_publication
check_persisted_bootstrap_contract

docker rm "$RECREATE_BACKUP" >/dev/null
RECREATE_BACKUP=''
RECREATE_ORIGINAL=''

printf 'FIVEGPN_CONTAINER_ACCEPTANCE_PROBES_SHA256=%s\n' "$probe_bundle_sha"
if [[ "$ACCEPTANCE_MODE" == release ]]; then
    printf 'FIVEGPN_CONTAINER_ACCEPTED_COMMIT=%s\n' "$EXPECTED_COMMIT"
    printf 'FIVEGPN_CONTAINER_ACCEPTED_MIHOMO_SHA256=%s\n' "$EXPECTED_MIHOMO_SHA256"
    printf 'FIVEGPN_CONTAINER_ACCEPTED_IMAGE_ID=%s\n' "$after_image"
    echo 'Docker 28 test-env disposable release acceptance: PASS'
else
    printf 'FIVEGPN_CONTAINER_DEVELOPMENT_ACCEPTED_COMMIT=%s\n' "$EXPECTED_COMMIT"
    printf 'FIVEGPN_CONTAINER_DEVELOPMENT_ACCEPTED_MIHOMO_BINARY_SHA256=%s\n' \
        "$EXPECTED_MIHOMO_BINARY_SHA256"
    printf 'FIVEGPN_CONTAINER_DEVELOPMENT_ACCEPTED_IMAGE_ID=%s\n' "$after_image"
    echo 'Docker 28 test-env disposable development acceptance: PASS (not release evidence)'
fi
