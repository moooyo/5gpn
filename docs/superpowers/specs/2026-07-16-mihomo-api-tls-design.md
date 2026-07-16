# Mihomo API TLS Design

**Date:** 2026-07-16

## Goal

Encrypt every 5gpn-to-mihomo controller connection used by zashboard and the
5gpn daemon. New installations must expose the mihomo REST and WebSocket API on
loopback through native TLS and must use the existing wildcard certificate.

## Scope

This change applies to newly generated mihomo configurations and to the
configuration produced by the explicit `mihomo-reset` operation.

Ordinary reinstalls and `change-*` operations continue to validate and preserve
an existing operator-owned `/etc/5gpn/mihomo/config.yaml` byte-for-byte. This
change does not migrate existing configurations automatically. The raw mihomo
configuration editor's existing controller invariant will be updated to require
the TLS-only listener and the zash certificate paths, preventing a later edit
from reintroducing plaintext controller access.

## Controller Configuration

The generated mihomo seed will configure a TLS-only controller:

```yaml
external-controller: ""
external-controller-tls: 127.0.0.1:9090
secret: __CONTROLLER_SECRET__
tls:
  certificate: /etc/5gpn/cert/zash/fullchain.pem
  private-key: /etc/5gpn/cert/zash/privkey.pem
```

The empty `external-controller` value prevents the plaintext listener from
starting. Mihomo v1.19.28 starts its plaintext and TLS controller listeners
independently, so `external-controller-tls` remains active without a plaintext
listener.

The zash role certificate is the existing wildcard certificate deployed by the
installer to `/etc/5gpn/cert/zash`. It covers `DNS_ZASH_DOMAIN` and is already
maintained by the certificate deployment and renewal flow.

Mihomo v1.19.28 safe-path enforcement also requires
`SAFE_PATHS=/etc/5gpn/cert/zash` in the systemd unit because the shared zash
certificate directory is outside mihomo's `-d /etc/5gpn/mihomo` home. This is a
read-only allowlist entry only; `ProtectSystem=strict` and
`ReadWritePaths=/etc/5gpn/mihomo` stay unchanged.

## TLS Client Architecture

The daemon will use one shared TLS client configuration for both controller
consumers:

- `MihomoClient`, used for health checks and configuration hot-apply.
- The reverse proxy mounted under zashboard's `/proxy/`, including WebSocket
  upgrades.

The client will:

- Dial the configured loopback address from `DNS_MIHOMO_CONTROLLER`.
- Send and verify TLS SNI against `DNS_ZASH_DOMAIN`.
- Trust the operating system root store plus the certificate at
  `DNS_ZASH_CERT`, allowing both publicly trusted wildcard certificates and the
  project's self-signed debug certificate.
- Require TLS 1.2 or newer.
- Never use `InsecureSkipVerify` and never fall back to HTTP.

No new environment variable is required. The existing controller address,
zashboard domain, and zash certificate settings provide the dial target,
certificate identity, and trust material.

## Installer Controller Calls

Installer-side controller requests, including whitelist refresh and readiness
probing, will use HTTPS. Curl will connect to the loopback controller address
while using `DNS_ZASH_DOMAIN` as the URL host and TLS server name, and will
validate the server with the deployed zash certificate. These requests will not
fall back to plaintext.

## Certificate Renewal

Mihomo v1.19.28 supports automatic reload of certificate and private-key files.
The renewal hook will continue copying the renewed wildcard certificate into
the zash role directory without restarting mihomo. Comments and operator
documentation will describe mihomo as a TLS endpoint that hot-reloads the
controller certificate rather than as a component that terminates no TLS.

## Failure Behavior

- Missing or unreadable zash trust material causes the daemon controller client
  to fail closed rather than downgrade to HTTP.
- A certificate with the wrong DNS identity is rejected.
- If the verified Mihomo TLS transport or daemon client cannot be constructed
  (missing `DNS_ZASH_DOMAIN`, unreadable cert, or invalid/non-loopback
  controller address), the Mihomo integration stays unavailable/503 while DNS
  startup and the rest of the control plane continue.
- Raw configuration updates that enable the plaintext controller, omit the TLS
  controller, or change the required zash certificate paths are rejected before
  validation or publication.
- Controller authentication continues to use the existing bearer secret.
- Reverse-proxy authentication behavior remains unchanged: the console injects
  the daemon-held secret, while zashboard forwards the browser-supplied
  authorization header.
- An invalid generated seed is rejected by the existing `mihomo -t` candidate
  validation before publication.

## Documentation

Update the current architecture and operator-facing configuration references to
state that:

- The mihomo controller is TLS-only on loopback for new installations.
- The zashboard reverse proxy and daemon controller client use verified HTTPS.
- The zash certificate role is shared by the zashboard panel and mihomo
  controller.
- Existing operator-owned configurations are not migrated automatically.

## Verification

Local, non-deployment verification will cover:

- TLS REST proxying with unchanged secret-injection and pass-through behavior.
- TLS WebSocket upgrade proxying.
- Successful daemon client requests with the expected certificate identity.
- Rejection of an untrusted certificate and a certificate for the wrong name.
- Generated seed parity between the installer template and the Go reset
  template.
- Shell policy assertions that generated controller configuration and installer
  controller calls use HTTPS and the zash certificate.
- Go formatting, vet, and targeted race-enabled tests.

No installer execution, systemd operation, SSH deployment, or live gateway test
will run on the current machine.
