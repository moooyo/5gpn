# Pre-v5 rebuild and release-channel upgrades

This runbook covers the exceptional upgrade paths that do not belong in the
project overview. Read it completely before changing a deployed gateway. The
commands below intentionally fail closed and assume that the operator has
checksum-verified artifacts from the exact target release.

> [!WARNING]
> A pre-v5 interception document has no lossless automatic migration. Do not
> delete it, edit only its version number, or let a new installer generate
> replacement SOCKS credentials while preserving the old mihomo configuration.

## Stable-to-beta upgrade

The normal stable-to-beta path preserves the core deployment:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash -s -- --beta
```

The installer preserves a valid operator-owned mihomo configuration byte for
byte and checks the interception boundary structurally. If an inactive legacy
configuration lacks the authenticated `intercept-egress` listener,
`MODULE-INTERCEPT` node, or fail-closed rule, the core DNS, Console, Telegram,
and existing mihomo data plane may be upgraded while Extensions are reported as
unavailable. The installer never silently patches operator YAML.

Use the reset path only when replacing the complete mihomo configuration is
acceptable:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash -s -- --beta upgrade-reset-mihomo
```

`upgrade-reset-mihomo` requires an existing installation and an interactive TTY
confirmation. It retains a byte-for-byte backup, renders the target release's
seed, runs the pinned `mihomo -t`, and publishes the candidate atomically.
Custom proxies, providers, groups, and rules are not merged and must be restored
manually from the backup. Normal install, reinstall, and `configure` operations
never select this reset path.

A successful beta upgrade does not promise an in-place downgrade to the
official channel. Keep a pre-upgrade system snapshot when reversal is required;
the installer rollback covers failures before commit, not a later downgrade.

Repository documentation describes the current source tree. A quick installer
can deploy a behavior only after it is included in a published tag, so verify
the selected release before relying on a recently added upgrade capability.

## Required pre-v5 rebuild

Every deployment whose `/etc/5gpn/intercept/config.json` still uses interception
schema version 4, including the pre-v5 `0.0.19`, `test-env`, and `kfchost`
shapes, requires one explicit, recoverable configuration rebuild before the
current quick installer runs. While the old v4 daemon still owns the transaction:

1. Take an active-state recovery snapshot of `dns.env`,
   `intercept/config.json`, and the complete mihomo file.
2. Disable the MITM master through the authenticated old Console/API.
3. Verify that the sidecar stopped and the old egress, policy, and capture
   blocks were withdrawn from mihomo.
4. Save a separate clean post-disable snapshot.
5. Stop `5gpn-dns` so no writer can race the rebuild.

The first snapshot can restore the original active state. The second snapshot
is the required v5 routing baseline.

Use `jq` to project only installer-owned infrastructure from v4 into a disabled,
empty v5 document. This preserves both authenticated SOCKS credential pairs,
the listener, TLS paths, upstream proxy, and protocol choices while clearing
extension snapshots and execution order. All three `NEW_*` paths must come from
the same exact GitHub release. `NEW_5GPN_INTERCEPT` and `NEW_5GPN_DNS` are
standalone release assets verified against that release's `checksums.txt`;
`NEW_INSTALL_SH` is extracted from the `5gpn-installer.tar.gz` whose digest is
verified by the same file.

Enter a root shell, place the three verified artifacts in root-owned,
single-link paths that are not group- or world-writable, assign the `NEW_*`
variables to their absolute paths, and run the block from a root-only local file.
Do not pipe this recovery script from the network. It acquires the same installer
transaction lock as normal 5gpn management commands and refuses to start unless
all target artifacts pass local preflight checks.

```bash
set -euo pipefail
: "${NEW_5GPN_INTERCEPT:?set this to the verified current sidecar binary}"
: "${NEW_5GPN_DNS:?set this to the verified current DNS binary}"
: "${NEW_INSTALL_SH:?set this to the verified current installer}"

if (( EUID != 0 )); then
  echo 'save this block in a root-only file, set the three NEW_* paths inside it, and run it as root' >&2
  exit 1
fi
artifact_is_root_safe() {
  local path="$1" mode parent
  [[ "$path" == /* && -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(readlink -f -- "$path")" == "$path" ]] || return 1
  [[ "$(stat -c %u -- "$path")" == 0 && "$(stat -c %h -- "$path")" == 1 ]] || return 1
  mode="$(stat -c %a -- "$path")"
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  (( (8#$mode & 8#022) == 0 )) || return 1
  parent="$(dirname -- "$path")"
  while true; do
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    [[ "$(readlink -f -- "$parent")" == "$parent" ]] || return 1
    [[ "$(stat -c %u -- "$parent")" == 0 ]] || return 1
    mode="$(stat -c %a -- "$parent")"
    [[ "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ "$parent" == / ]] && break
    parent="$(dirname -- "$parent")"
  done
}
artifact_is_root_safe "$NEW_5GPN_INTERCEPT" && [[ -x "$NEW_5GPN_INTERCEPT" ]] || {
  echo 'NEW_5GPN_INTERCEPT must be a root-owned, single-link, non-symlink executable that is not group/world-writable' >&2
  exit 1
}
artifact_is_root_safe "$NEW_5GPN_DNS" && [[ -x "$NEW_5GPN_DNS" ]] || {
  echo 'NEW_5GPN_DNS must be a root-owned, single-link, non-symlink executable that is not group/world-writable' >&2
  exit 1
}
artifact_is_root_safe "$NEW_INSTALL_SH" && [[ -r "$NEW_INSTALL_SH" ]] || {
  echo 'NEW_INSTALL_SH must be a root-owned, single-link, non-symlink readable file that is not group/world-writable' >&2
  exit 1
}
export INSTALL_SH_LIB_ONLY=1
source "$NEW_INSTALL_SH"
declare -F validate_dns_env_schema >/dev/null
declare -F acquire_install_lock >/dev/null
declare -F release_install_lock >/dev/null
declare -F valid_dns_release_tag >/dev/null
valid_dns_release_tag "$DNS_VERSION_DEFAULT" || {
  echo 'NEW_INSTALL_SH is not stamped to an exact official or beta release tag' >&2
  exit 1
}
binary_reports_target_version() {
  local binary="$1" output result=1
  output="$(mktemp /root/.5gpn-target-version.XXXXXX)" || return 1
  chmod 0600 "$output" || { rm -f -- "$output"; return 1; }
  if "$binary" --version > "$output" 2>/dev/null \
     && printf '%s\n' "$DNS_VERSION_DEFAULT" | cmp -s - "$output"; then
    result=0
  fi
  rm -f -- "$output" || return 1
  return "$result"
}
binary_reports_target_version "$NEW_5GPN_INTERCEPT" || {
  echo 'NEW_5GPN_INTERCEPT does not report the installer release tag exactly' >&2
  exit 1
}
binary_reports_target_version "$NEW_5GPN_DNS" || {
  echo 'NEW_5GPN_DNS does not report the installer release tag exactly' >&2
  exit 1
}

candidate=""
env_candidate=""
config_rollback=""
env_rollback=""
old=""
env_file=""
api_config=""
backup_dir=""
dns_was_active=0
dns_stop_attempted=0
config_published=0
env_published=0
committed=0
cleanup_candidates() {
  local exit_rc=$? rollback_failed=0
  trap - EXIT HUP INT TERM
  set +e
  if (( committed == 0 )); then
    if (( env_published == 1 )) && [[ -n "$env_rollback" && -n "$env_file" ]]; then
      if ! sudo mv -fT -- "$env_rollback" "$env_file"; then
        echo 'ROLLBACK FAILED: could not restore dns.env' >&2
        rollback_failed=1
      fi
      env_rollback=""
    fi
    if (( config_published == 1 )) && [[ -n "$config_rollback" && -n "$old" ]]; then
      if ! sudo mv -fT -- "$config_rollback" "$old"; then
        echo 'ROLLBACK FAILED: could not restore the v4 interception document' >&2
        rollback_failed=1
      fi
      config_rollback=""
    fi
    sudo sync -d /etc/5gpn/intercept 2>/dev/null || rollback_failed=1
    sudo sync -d /etc/5gpn 2>/dev/null || rollback_failed=1
  fi
  for path in "$candidate" "$env_candidate" "$config_rollback" "$env_rollback" "$api_config"; do
    [[ -z "$path" ]] || sudo rm -f -- "$path"
  done
  if (( committed == 0 && dns_stop_attempted == 1 && dns_was_active == 1 )); then
    if (( rollback_failed == 0 )); then
      if ! sudo systemctl start 5gpn-dns.service \
         || ! sudo systemctl is-active --quiet 5gpn-dns.service; then
        echo 'RECOVERY FAILED: the old 5gpn-dns service is not active' >&2
      fi
    else
      echo 'RECOVERY REQUIRED: files could not be rolled back, so 5gpn-dns was not restarted' >&2
    fi
  fi
  if [[ "${INSTALL_LOCK_HELD:-0}" == 1 ]]; then
    release_install_lock \
      || echo 'RECOVERY WARNING: could not release the 5gpn installer lock cleanly' >&2
  fi
  exit "$exit_rc"
}
trap cleanup_candidates EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_install_lock

# Prove this is the exact retired shape before any live-state mutation.
sudo jq -e '.version == 4' /etc/5gpn/intercept/config.json >/dev/null
if [[ "$(sudo grep -c '^DNS_EGRESS_RESOLVER=' /etc/5gpn/dns.env || true)" != 1 ]]; then
  echo 'expected interception schema v4 and exactly one retired DNS_EGRESS_RESOLVER key' >&2
  exit 1
fi
if sudo systemctl is-active --quiet 5gpn-dns.service; then
  dns_was_active=1
else
  echo 'the old 5gpn-dns service must be active so its authenticated v4 control plane owns the disable transaction' >&2
  exit 1
fi

backup_dir="$(sudo mktemp -d /root/5gpn-pre-v5.XXXXXX)"
sudo chmod 0700 "$backup_dir"
sudo sync -d /root
printf 'Recovery snapshots will remain in %s\n' "$backup_dir"

# Before any mutation: retain the original active state.
sudo cp -a /etc/5gpn/dns.env "$backup_dir/dns.env.active"
sudo cp -a /etc/5gpn/intercept/config.json "$backup_dir/intercept-v4.active.json"
sudo cp -a /etc/5gpn/mihomo/config.yaml "$backup_dir/mihomo.active.yaml"
sudo sync -f "$backup_dir/dns.env.active"
sudo sync -f "$backup_dir/intercept-v4.active.json"
sudo sync -f "$backup_dir/mihomo.active.yaml"
sudo sync -d "$backup_dir"

# Disable MITM through the old authenticated API before stopping its daemon.
base="$(sudo sed -n 's/^DNS_BASE_DOMAIN=//p' /etc/5gpn/dns.env)"
token="$(sudo sed -n 's/^DNS_API_TOKEN=//p' /etc/5gpn/dns.env)"
[[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || {
  echo 'DNS_API_TOKEN must be non-empty and contain no CR or LF' >&2
  exit 1
}
token_escaped="${token//\\/\\\\}"
token_escaped="${token_escaped//\"/\\\"}"
token_escaped="${token_escaped//$'\t'/\\t}"
token_escaped="${token_escaped//$'\v'/\\v}"
console="console.${base}"
api_config="$(sudo mktemp "$backup_dir/.curl-config.XXXXXX")"
sudo chmod 0600 "$api_config"
if ! printf 'header = "Authorization: Bearer %s"\n' "$token_escaped" | sudo tee "$api_config" >/dev/null; then
  exit 1
fi
token=""
token_escaped=""
api=(--disable --fail --silent --show-error --noproxy '*' --cacert /etc/5gpn/cert/web/current/fullchain.pem \
  --resolve "${console}:443:127.0.0.1" --config "$api_config")
settings="$(sudo curl "${api[@]}" "https://${console}/api/interception/settings")"
jq -e '(.http2 | type) == "boolean" and (.quic_fallback_protection | type) == "boolean"' <<<"$settings" >/dev/null
revision="$(jq -er '.revision' <<<"$settings")"
http2="$(jq -r '.http2' <<<"$settings")"
quic="$(jq -r '.quic_fallback_protection' <<<"$settings")"
payload="$(jq -cn --arg revision "$revision" --argjson http2 "$http2" --argjson quic "$quic" \
  '{revision:$revision,enabled:false,http2:$http2,quic_fallback_protection:$quic}')"
sudo curl "${api[@]}" -X PUT -H 'Content-Type: application/json' --data "$payload" \
  "https://${console}/api/interception/settings" >/dev/null

# Prove the old transaction withdrew its overlay and stopped the sidecar.
modules="$(sudo curl "${api[@]}" "https://${console}/api/interception/modules")"
jq -e '.active_capture_hosts | length == 0' <<<"$modules" >/dev/null
sudo rm -f -- "$api_config"
api_config=""
for _ in {1..20}; do
  sudo systemctl is-active --quiet 5gpn-intercept.service || break
  sleep 0.25
done
if sudo systemctl is-active --quiet 5gpn-intercept.service; then
  echo 'old interception sidecar is still active' >&2
  exit 1
fi

# Snapshot that clean post-disable boundary separately, then stop the writer.
sudo cp -a /etc/5gpn/intercept/config.json "$backup_dir/intercept-v4.disabled.json"
sudo cp -a /etc/5gpn/mihomo/config.yaml "$backup_dir/mihomo.post-disable.yaml"
sudo sync -f "$backup_dir/intercept-v4.disabled.json"
sudo sync -f "$backup_dir/mihomo.post-disable.yaml"
sudo sync -d "$backup_dir"
dns_stop_attempted=1
sudo systemctl stop 5gpn-dns.service
if sudo systemctl is-active --quiet 5gpn-dns.service; then
  echo 'old 5gpn-dns remained active after stop' >&2
  exit 1
fi

old=/etc/5gpn/intercept/config.json
sudo jq -e '.version == 4 and .mitm.enabled == false' "$old" >/dev/null
candidate="$(sudo mktemp /etc/5gpn/intercept/.config.v5.XXXXXX)"
if ! sudo jq '
  if (.version == 4 and .mitm.enabled == false) then {
    version: 5,
    listen: .listen,
    username: .username,
    password: .password,
    tls_cert: .tls_cert,
    tls_key: .tls_key,
    upstream_proxy: .upstream_proxy,
    mitm: {
      enabled: false,
      http2: (if .mitm.http2 == null then true else .mitm.http2 end),
      quic_fallback_protection: (if .mitm.quic_fallback_protection == null then true else .mitm.quic_fallback_protection end)
    },
    execution_order: [],
    modules: []
  } else error("expected interception v4 with MITM already disabled") end
' "$old" | sudo tee "$candidate" >/dev/null; then
  sudo rm -f -- "$candidate"
  candidate=""
  exit 1
fi
sudo chown --reference="$old" "$candidate"
sudo chmod --reference="$old" "$candidate"
if ! sudo "$NEW_5GPN_INTERCEPT" --config "$candidate" --check-config; then
  sudo rm -f -- "$candidate"
  candidate=""
  exit 1
fi
routing_rc=0
sudo "$NEW_5GPN_DNS" --check-interception-routing \
  --mihomo-config /etc/5gpn/mihomo/config.yaml \
  --intercept-config "$candidate" || routing_rc=$?
if (( routing_rc != 0 )); then
  sudo rm -f -- "$candidate"
  candidate=""
  exit "$routing_rc"
fi

env_file=/etc/5gpn/dns.env
if [[ "$(sudo grep -c '^DNS_EGRESS_RESOLVER=' "$env_file" || true)" != 1 ]]; then
  echo 'expected exactly one retired DNS_EGRESS_RESOLVER key' >&2
  exit 1
fi
env_candidate="$(sudo mktemp /etc/5gpn/.dns.env.v5.XXXXXX)"
if ! sudo grep -v '^DNS_EGRESS_RESOLVER=' "$env_file" | sudo tee "$env_candidate" >/dev/null; then
  exit 1
fi
if [[ "$(sudo grep -c '^DNS_EGRESS_RESOLVER=' "$env_candidate" || true)" != 0 ]]; then
  echo 'retired resolver survived the dns.env candidate rewrite' >&2
  exit 1
fi
sudo chown --reference="$env_file" "$env_candidate"
sudo chmod --reference="$env_file" "$env_candidate"
if ! sudo env INSTALL_SH_LIB_ONLY=1 bash -c \
  'source "$1"; validate_dns_env_schema "$2"' _ "$NEW_INSTALL_SH" "$env_candidate"; then
  exit 1
fi

sudo sync -f "$candidate"
sudo sync -f "$env_candidate"
config_rollback="$(sudo mktemp /etc/5gpn/intercept/.config.v4.rollback.XXXXXX)"
env_rollback="$(sudo mktemp /etc/5gpn/.dns.env.v4.rollback.XXXXXX)"
sudo cp -a -- "$old" "$config_rollback"
sudo cp -a -- "$env_file" "$env_rollback"
sudo sync -f "$config_rollback"
sudo sync -f "$env_rollback"
sudo sync -d /etc/5gpn/intercept
sudo sync -d /etc/5gpn
config_published=1
if ! sudo mv -fT -- "$candidate" "$old"; then
  exit 1
fi
candidate=""
env_published=1
if ! sudo mv -fT -- "$env_candidate" "$env_file"; then
  exit 1
fi
env_candidate=""
sudo sync -d /etc/5gpn/intercept
sudo sync -d /etc/5gpn
committed=1
sudo rm -f -- "$config_rollback" "$env_rollback"
sudo sync -d /etc/5gpn/intercept
sudo sync -d /etc/5gpn
config_rollback=""
env_rollback=""
release_install_lock
trap - EXIT HUP INT TERM
printf 'Recovery snapshots retained in %s\n' "$backup_dir"
```

The old master-disable and `ready` routing check are mandatory. An empty v5
document cannot claim or remove rules owned by the old snapshot. The synced
dual-file transaction removes the one retired environment key. After it
completes, run the current installer and explicitly re-import and review every
extension.

The `0.0.13` stable installer predates channel delegation, so use the remote
quick installer after completing the rebuild. Later installed releases may
delegate an explicit channel switch to their stored, verified quick installer,
but the exact behavior always depends on the installed release.
