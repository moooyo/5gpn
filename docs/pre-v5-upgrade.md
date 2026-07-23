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
extension snapshots and execution order. `NEW_5GPN_INTERCEPT`, `NEW_5GPN_DNS`,
and `NEW_INSTALL_SH` must point to checksum-verified current artifacts extracted
from the exact target release bundle.

```bash
set -euo pipefail
: "${NEW_5GPN_INTERCEPT:?set this to the verified current sidecar binary}"
: "${NEW_5GPN_DNS:?set this to the verified current DNS binary}"
: "${NEW_INSTALL_SH:?set this to the verified current installer}"

candidate=""
env_candidate=""
config_rollback=""
env_rollback=""
old=""
env_file=""
api_header=""
config_published=0
env_published=0
committed=0
cleanup_candidates() {
  if (( committed == 0 )); then
    if (( env_published == 1 )) && [[ -n "$env_rollback" && -n "$env_file" ]]; then
      sudo mv -fT -- "$env_rollback" "$env_file" || true
      env_rollback=""
    fi
    if (( config_published == 1 )) && [[ -n "$config_rollback" && -n "$old" ]]; then
      sudo mv -fT -- "$config_rollback" "$old" || true
      config_rollback=""
    fi
    sudo sync -d /etc/5gpn/intercept 2>/dev/null || true
    sudo sync -d /etc/5gpn 2>/dev/null || true
  fi
  for path in "$candidate" "$env_candidate" "$config_rollback" "$env_rollback" "$api_header"; do
    [[ -z "$path" ]] || sudo rm -f -- "$path"
  done
}
trap cleanup_candidates EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Prove this is the exact retired shape before any live-state mutation.
sudo jq -e '.version == 4' /etc/5gpn/intercept/config.json >/dev/null
if [[ "$(sudo grep -c '^DNS_EGRESS_RESOLVER=' /etc/5gpn/dns.env || true)" != 1 ]]; then
  echo 'expected interception schema v4 and exactly one retired DNS_EGRESS_RESOLVER key' >&2
  exit 1
fi

sudo install -d -m 0700 /root/5gpn-pre-v5

# Before any mutation: retain the original active state.
sudo cp -a /etc/5gpn/dns.env /root/5gpn-pre-v5/dns.env.active
sudo cp -a /etc/5gpn/intercept/config.json /root/5gpn-pre-v5/intercept-v4.active.json
sudo cp -a /etc/5gpn/mihomo/config.yaml /root/5gpn-pre-v5/mihomo.active.yaml

# Disable MITM through the old authenticated API before stopping its daemon.
base="$(sudo sed -n 's/^DNS_BASE_DOMAIN=//p' /etc/5gpn/dns.env)"
token="$(sudo sed -n 's/^DNS_API_TOKEN=//p' /etc/5gpn/dns.env)"
[[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || {
  echo 'invalid DNS_API_TOKEN' >&2
  exit 1
}
console="console.${base}"
api_header="$(sudo mktemp /root/5gpn-pre-v5/.api-header.XXXXXX)"
sudo chmod 0600 "$api_header"
if ! printf 'Authorization: Bearer %s\n' "$token" | sudo tee "$api_header" >/dev/null; then
  exit 1
fi
token=""
api=(--fail --silent --show-error --cacert /etc/5gpn/cert/web/current/fullchain.pem \
  --resolve "${console}:443:127.0.0.1" -H "@${api_header}")
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
sudo rm -f -- "$api_header"
api_header=""
for _ in {1..20}; do
  sudo systemctl is-active --quiet 5gpn-intercept.service || break
  sleep 0.25
done
if sudo systemctl is-active --quiet 5gpn-intercept.service; then
  echo 'old interception sidecar is still active' >&2
  exit 1
fi

# Snapshot that clean post-disable boundary separately, then stop the writer.
sudo cp -a /etc/5gpn/intercept/config.json /root/5gpn-pre-v5/intercept-v4.disabled.json
sudo cp -a /etc/5gpn/mihomo/config.yaml /root/5gpn-pre-v5/mihomo.post-disable.yaml
sudo systemctl stop 5gpn-dns.service

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
config_rollback=""
env_rollback=""
trap - EXIT HUP INT TERM
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
