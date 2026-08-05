# Third-Party Notices

5gpn is licensed under the MIT License. See [`LICENSE`](LICENSE), Copyright
(c) 2026 moooyo.

This document describes the distribution boundary of the 5gpn installer
release and the external artifacts that the installer or installed runtime
retrieves. License identifiers below are taken from the exact tagged source or
package metadata linked in each entry; the linked license text remains
authoritative.

## Included in the 5gpn release

The `5gpn-installer.tar.gz` release asset contains the installer, service and
configuration templates, maintenance scripts, selected documentation, and this
notice file. Those first-party files are covered by the repository's MIT
License.

The release asset contains no compiled daemon, sidecar, dashboard bundle, Go
module tree, npm package tree, or third-party rule-list snapshot. The current
runtime executable and dashboard are retrieved separately under their own
digest pins.

## Release artifacts downloaded by the installer

`install.sh` retrieves these exact upstream release artifacts, verifies the
listed SHA-256 digest, and then publishes them on the gateway.

| Component | Exact release and downloaded artifact | SHA-256 | License evidence | Installed use |
|---|---|---|---|---|
| 5gpn mihomo fork | [`moooyo/mihomo` `v1.19.28-monolith.16`](https://github.com/moooyo/mihomo/releases/tag/v1.19.28-monolith.16), `mihomo-linux-amd64-compatible-v1.19.28-monolith.16.gz` | `6f1e1e961e28a22fb2009d9029def6d21dbc0dccbf646d65b8cb69c25b43f494` | GPL-3.0; see the exact tag's [`LICENSE`](https://github.com/moooyo/mihomo/blob/v1.19.28-monolith.16/LICENSE) and [source](https://github.com/moooyo/mihomo/tree/v1.19.28-monolith.16) | Installed as `/opt/5gpn/bin/5gpn-mihomo`; this is the sole long-running 5gpn process. |
| zashboard fork | [`moooyo/zashboard` `v3.16.0-monolith.22`](https://github.com/moooyo/zashboard/releases/tag/v3.16.0-monolith.22), `dist.zip` | `c4b41234c7f12aa13d93ad56ba3e23abf2944532a8c10d984665d061b5888373` | The zashboard project is MIT, Copyright 2024 Zephyruso; see the exact tag's [`LICENSE`](https://github.com/moooyo/zashboard/blob/v3.16.0-monolith.22/LICENSE) and [`package.json`](https://github.com/moooyo/zashboard/blob/v3.16.0-monolith.22/package.json) | Extracted to `/opt/5gpn/ui` and served as static browser assets by `5gpn-mihomo`. |

The zashboard `dist.zip` is a compiled browser bundle and includes code and
assets from its runtime dependency graph. Those dependencies retain their own
licenses. The exact dependency graph used to build this artifact is recorded in
the tagged [`package.json`](https://github.com/moooyo/zashboard/blob/v3.16.0-monolith.22/package.json)
and [`pnpm-lock.yaml`](https://github.com/moooyo/zashboard/blob/v3.16.0-monolith.22/pnpm-lock.yaml);
5gpn does not rebuild or modify the downloaded archive.

## Optional installer TUI downloaded separately

The installer attempts to download Gum for its terminal UI. Failure is
non-fatal and the installer falls back to plain output.

| Component | Exact release | License evidence | Verified Linux archive digests |
|---|---|---|---|
| [Charmbracelet Gum](https://github.com/charmbracelet/gum/tree/v0.17.0) | `v0.17.0` | MIT, Copyright (c) 2022-2024 Charmbracelet, Inc; see [`LICENSE`](https://github.com/charmbracelet/gum/blob/v0.17.0/LICENSE) | `x86_64`: `69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb`; `arm64`: `b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c`; `armv7`: `25711c2fbc6887cde79ed586972834121a04955968808dd688c688381ac50ab2` |

The verified executable is installed as `/opt/5gpn/bin/gum`.

## Runtime rule data

A fresh installation writes one enabled, 24-hour subscription for the
split-horizon China IPv4 input:

| Data source | Fetch behavior | License status |
|---|---|---|
| [`17mon/china_ip_list`](https://github.com/17mon/china_ip_list), [`china_ip_list.txt`](https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt) | The installed `5gpn-mihomo` fetches the unversioned `master` resource and stores the cache under `/etc/5gpn/rules`; the list is not included in the 5gpn release asset. | The upstream repository publishes no license file and reports no declared license. No license is inferred here; operators must review the upstream terms before enabling or redistributing this data. |

Operator-added rule subscriptions and extension catalogs are neither selected
nor redistributed by the 5gpn release. Their licenses and service terms remain
the operator's responsibility.

## Operating-system packages

The installer asks the host package manager to install system tools. These are
downloaded from the operator's configured OS repositories, are not pinned by
the 5gpn release, and remain governed by the distribution's package metadata
and license notices.

- Debian-family names: `wget`, `curl`, `ca-certificates`, `unzip`, `iproute2`,
  `openssl`, `qrencode`, `jq`, `libcap2-bin`, `util-linux`, `polkitd`, and
  `dnsutils`.
- RPM-family names: `wget`, `curl`, `ca-certificates`, `unzip`, `iproute`,
  `openssl`, `qrencode`, `jq`, `util-linux`, `polkit`, `bind-utils`, `libcap`,
  and `libcap-ng-utils`.
- Production certificate modes also install the distribution's `certbot`
  package. Cloudflare DNS-01 mode additionally installs
  `python3-certbot-dns-cloudflare`.

## Network services, not distributed components

Depending on the selected installation mode, the installer may contact GitHub
release APIs, Let's Encrypt's ACME service, Cloudflare through the OS-provided
Certbot plugin, and `api.ipify.org`, `ifconfig.me`, or `icanhazip.com` for public
IPv4 discovery. These are network services, not software or data bundled by
5gpn; their respective service terms apply.

First-party extension source lives in the separate
[`moooyo/5gpn-extensions`](https://github.com/moooyo/5gpn-extensions)
repository and is not part of the 5gpn installer release. Development and test
dependencies, GitHub Actions, and source trees from the mihomo and zashboard
repositories are likewise not included in `5gpn-installer.tar.gz`.
