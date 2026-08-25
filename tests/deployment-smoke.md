# Read-only 5gpn deployment smoke

> **READ-ONLY:** this checklist may run on an explicitly designated working
> gateway. It must not issue a controller write, invoke an installer or
> management mutation, stop, restart, reload, signal, or kill a service, write
> a file, occupy a project lock, issue or renew a certificate, install a
> package, or inject a failure. If any assertion requires one of those actions,
> stop and use a disposable checklist instead.

This smoke owns the installed, cross-repository deployment boundary. It does
not re-test mihomo's DNS algorithms, worker behavior, extension engine, or
Telegram loop, and it does not test Console layout or interactions. Those
surfaces are linked from [integration-smoke.md](integration-smoke.md).

Ordinary DNS and HTTPS probes are permitted. They may affect bounded in-memory
caches and access logs in the same way as normal client traffic, but must not
change durable configuration or host state.

## Prerequisites and evidence

- The gateway is explicitly designated for read-only acceptance and no
  installer, certificate, or operator change is running concurrently.
- The host is Linux amd64 with kernel 5.7 or newer, systemd 257 or newer, and a
  pure cgroup-v2 hierarchy with the memory and pids controllers available.
- `dig` with DoT support, `curl`, `openssl`, `jq`, `sha256sum`, `ss`,
  `systemctl`, and `findmnt` are available.
- A client can reach one configured gateway address. Stable direct, gateway,
  and forwarded test names already exist in the current configuration; this
  smoke does not add temporary policy.
- The evidence ledger contains the exact root release, installer bundle,
  mihomo binary, zashboard archive, and fixture identities required by
  [integration-smoke.md](integration-smoke.md).

Before the first network probe, record the current main PID, `NRestarts`, and
the SHA-256 of the operator YAML and every present runtime document. Keep the
values in the runner's memory or evidence system; do not create scratch files
on the gateway.

## 1. Installed release and artifact binding

- [ ] `/opt/5gpn/install.sh` contains one exact stamped 5gpn release tag and the
  expected independent mihomo and zashboard release coordinates. They match
  the recorded, digest-verified release bundle rather than a branch tip.
- [ ] `/opt/5gpn/bin/5gpn-mihomo -v` reports the pinned mihomo version. Its
  SHA-256 matches the release asset selected by the installed root release.
- [ ] `/opt/5gpn/ui/current/.zash_version` reports the pinned zashboard version. The
  installed tree contains the release's hidden build metadata, including
  `.vite/manifest.json`, and no second vendored Console tree exists.
- [ ] `/opt/5gpn/ui` contains only the exact root marker, `generations/`, and a
  root-owned relative `current -> generations/generation-*` symlink. Current
  and at most one previous generation remain; each contains the generation
  marker, disjoint `.zash_primary_files` and `.zash_compat_files` manifests
  (the latter contains only missing assets from the immediately previous
  primary manifest), the complete Console, and both signed profiles,
  with no symlink, hardlink, special entry, or nested mount below it.
- [ ] `current/.5gpn-profile-inputs` has the exact public eight-key schema and
  matches the live DoT signer leaf/SPKI, interception-CA DER, configured
  domain/gateway, and both CMS files. It contains no private-key fingerprint.
- [ ] The installed root release binds both component pins in one revision.
  No component-update timer, service, or installed host command exists;
  Core and Console changes are installer-owned release operations.
- [ ] The installed helper, template, systemd, and notice files belong to the
  same verified root bundle. No migration helper or retired managed script is
  present under `/opt/5gpn/scripts`.
- [ ] The live and staged `5gpn-mihomo.service` bytes match, PID 1 reports
  `NeedDaemonReload=no`, and the first pre-start command is the exact installed
  `configure-runtime-gate.sh`. It is the only `Exec*` command with a `+`
  prefix; the gate timeout exceeds its fixed maximum wait.
- [ ] No retained `configure-runtime-gate{,.job,.ack,.release}` file is present
  under `/run/5gpn` during this read-only steady-state smoke.

## 2. Identity, filesystem, and state

- [ ] `fivegpn` is the only managed service user and group. Its UID and GID are
  system-range, exclusive, unaliased, and it has no supplementary group.
- [ ] `/opt/5gpn`, `/etc/5gpn`, `/var/lib/5gpn`, and
  `/var/lib/5gpn-intercept` resolve to their exact canonical paths and have
  valid current ownership markers. No managed root or marker is a symlink.
- [ ] `findmnt --submounts` shows no unexpected nested mount below a managed
  root. Certificate, interception-CA, UI, and temporary trees retain their
  stricter ownership boundaries.
- [ ] `/etc/5gpn/dns.env` has exactly the installed current-schema key set and
  no controller secret or retired key. The complete operator-owned
  `/etc/5gpn/mihomo/config.yaml` is a root-owned, non-linked regular file that
  is not group- or world-writable.
- [ ] The installed Core succeeds read-only with:

  ```bash
  owner_uid="$(id -u fivegpn)"
  sudo timeout --kill-after=5s 30s \
    /opt/5gpn/bin/5gpn-mihomo 5gpn-state validate \
    --owner-uid "$owner_uid" /etc/5gpn/mihomo/5gpn
  ```

  Its single JSON result accounts for `dns.json`, `intercept.json`, and
  `bot.json` as either validated or missing. The command creates nothing.
- [ ] `/etc/5gpn` is `root:root` mode `0755`, `/etc/5gpn/cert` is
  `root:root` mode `0751`, and the current public role files are readable by
  `fivegpn` without making their parent directories runtime-writable. The
  interception CA private key remains unreadable by `fivegpn`.

## 3. Managed units and process boundary

- [ ] `5gpn-mihomo.service` is active with exactly `User=fivegpn` and
  `Group=fivegpn`. No `5gpn-dns`, `5gpn-intercept`, generic `mihomo`, or other
  retired long-running unit definition exists.
- [ ] The main unit reports `Restart=always`, `RestartSec=3`,
  `StartLimitIntervalSec=60`, `StartLimitBurst=10`,
  `StartLimitAction=none`, `OOMPolicy=continue`, and
  `KillMode=control-group`.
- [ ] The unit delegates only memory and pids, has an empty
  `DelegateSubgroup`, uses `ProtectControlGroups=private`, contains
  `SystemCallFilter=~unshare setns`, and contains no `RestrictNamespaces=`.
- [ ] The six shipped unit files are byte-derived release assets and pass a
  read-only `systemd-analyze verify` together:
  `5gpn-mihomo.service`, `5gpn-intercept-cert.service`,
  `5gpn-intercept-cert.path`, `5gpn-intercept-cert.timer`,
  `5gpn-certbot-renew.service`, and `5gpn-certbot-renew.timer`.
- [ ] `5gpn-intercept-cert.path` and its timer are enabled as required. The
  public Certbot timer state agrees with the recorded certificate provenance:
  owned production lineage uses the scoped timer, while debug or externally
  renewed lineage does not claim scoped renewal ownership.

## 4. Listener publication and transport

- [ ] `ss -lntup` shows DoT on configured `:853/tcp`, local debug DNS on
  `127.0.0.1:5353/udp`, origin DNS on `127.0.0.1:5354/tcp+udp`, the controller
  on `127.0.0.1:443/tcp`, and only the application ingress listeners declared
  by the complete operator YAML.
- [ ] No public plain DNS `:53`, public DoH handler, standalone profile port,
  interception sidecar listener, or loopback SOCKS return hop is present.
- [ ] From an external client, DoT succeeds with the expected `dot.<base>` TLS
  identity. Plain DNS `:53` and remote access to debug `:5353` fail.
- [ ] An on-box query to `127.0.0.1:5353` succeeds. A request to
  `https://<gateway>:8443/dns-query` does not behave as DoH; `:8443` is
  application ingress when configured.
- [ ] A stable direct name returns its recorded real address, and a stable
  gateway-steered name returns the installation-managed gateway address. No
  policy or upstream is changed to manufacture these cases.

## 5. Public UI, profiles, and authentication boundary

Set `CONSOLE=console.<base>`. Obtain the current secret only through the
root-only v2 inspector and keep it out of argv, logs, screenshots, and the
evidence archive:

```bash
set +x
unset controller_json secret config_revision
config_revision="$(sudo sha256sum /etc/5gpn/mihomo/config.yaml | awk '{print $1}')"
controller_json="$(sudo /opt/5gpn/bin/5gpn-mihomo \
  5gpn-config inspect-controller \
  --config /etc/5gpn/mihomo/config.yaml)"
controller_json="$(jq -cse --arg revision "$config_revision" '
  select(length == 1) | .[0] | select(
    type == "object" and .version == 2
    and ((keys | sort) == ["certificate","external_controller_tls","external_ui","private_key","raw_revision","secret","version"])
    and .raw_revision == $revision
    and (.secret | type == "string" and length > 0
         and (explode | all(. >= 32 and . != 127)))
    and .external_controller_tls == "127.0.0.1:443"
    and .external_ui == "/opt/5gpn/ui/current"
    and .certificate == "/etc/5gpn/cert/console/current/fullchain.pem"
    and .private_key == "/etc/5gpn/cert/console/current/privkey.pem"
  )
' <<<"$controller_json")" || {
  echo "controller inspector contract mismatch" >&2
  exit 1
}
secret="$(jq -er '.secret' <<<"$controller_json")"

auth_get() {
  curl --disable --request GET --fail --silent --show-error \
    --proto '=https' --noproxy '*' \
    --header @/proc/self/fd/3 "$@" \
    3<<<"Authorization: Bearer ${secret}"
}
```

- [ ] The inspector returns exactly one version-2 controller projection. Its
  controller, UI, certificate, and private-key paths match the installed
  contract; the secret is non-empty but is never printed.
- [ ] `https://$CONSOLE/ui` redirects to `/ui/`, and `/ui/` loads without an
  Authorization header with `Cache-Control: no-store` and the expected browser
  isolation headers.
- [ ] Both `/ui/ios-dot.mobileconfig` and
  `/ui/ios-intercept-ca.mobileconfig` return 200 without authentication, have
  media type `application/x-apple-aspen-config` case-insensitively with optional
  parameters, and contain no controller secret.
- [ ] A missing or deliberately wrong credential returns 401 from
  `/5gpn/dns`, `/5gpn/interception`, `/5gpn/bot` when advertised, `/configs`,
  and `/proxies`. Error bodies contain neither the real secret nor plugin-log
  text.
- [ ] `auth_get "https://$CONSOLE/capabilities"` returns
  `controllerApi: "1"`, DNS capability 2, interception capability 8, and bot
  capability 1 when the bot surface is present. The authenticated DNS,
  interception, configuration, and proxy reads return 200.
- [ ] No `/proxy/` origin, second panel SNI, source allowlist, handoff session,
  separate Console bearer, or authenticated profile route exists.

After the probes, run `unset secret controller_json`.

## 6. Cross-repository forwarding and final invariants

- [ ] One stable gateway-steered HTTP or TLS request reaches its recorded
  origin through the installed mihomo data plane. One stable direct name
  bypasses gateway steering. These names and expectations were established
  before the smoke; no temporary rule or extension is installed.
- [ ] Gateway UDP/443 is rejected by the fixed guard, while an unrelated
  operator-configured UDP path, if present in the recorded fixture, remains an
  operator mihomo behavior rather than a 5gpn firewall rule.
- [ ] The host contains no 5gpn-managed TUN, TProxy, WireGuard, fwmark, policy
  table, NAT forwarding rule, or nftables table.
- [ ] The main PID and `NRestarts` equal their before-values. No service was
  stopped, signalled, reloaded, or restarted during the run.
- [ ] The SHA-256 values of the operator YAML and all present runtime documents
  equal their before-values. No project lock, certificate issuance, package
  action, or host-file write occurred.

Record every failed or skipped assertion with its evidence. Do not repair the
working gateway as part of this checklist; reproduce the problem on a
disposable target.
