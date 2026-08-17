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
notice file. It also contains `release/pins.env` and the strict
`release/pins.sh` parser/URL builder; installed deployments retain both below
`/opt/5gpn/release`. Those first-party files are covered by the repository's
MIT License.

The release asset contains no compiled daemon, sidecar, dashboard bundle, Go
module tree, npm package tree, or third-party rule-list snapshot. The current
runtime executable and dashboard are retrieved separately under their own
digest pins.

## Release artifacts downloaded by the installer

`release/pins.env` is the machine-readable authority for these coordinates.
The release binding gate requires this human-readable table to match that
manifest. `install.sh` retrieves the derived upstream release artifacts,
verifies the listed SHA-256 digest, and then publishes them on the gateway.

| Component | Exact release and downloaded artifact | SHA-256 | License evidence | Installed use |
|---|---|---|---|---|
| 5gpn mihomo fork | [`moooyo/mihomo` `v1.19.28-monolith.32`](https://github.com/moooyo/mihomo/releases/tag/v1.19.28-monolith.32), `mihomo-linux-amd64-compatible-v1.19.28-monolith.32.gz` | `0533c4a2d233be504c0c080404e265ed9caf348a6532d933d2ba40ec53635ce2` | GPL-3.0; see the exact tag's [`LICENSE`](https://github.com/moooyo/mihomo/blob/v1.19.28-monolith.32/LICENSE) and [source](https://github.com/moooyo/mihomo/tree/v1.19.28-monolith.32) | Installed as `/opt/5gpn/bin/5gpn-mihomo`; this is the sole long-running 5gpn process. |
| zashboard fork | [`moooyo/zashboard` `v3.16.1-monolith.32`](https://github.com/moooyo/zashboard/releases/tag/v3.16.1-monolith.32), `dist.zip` | `314e44501326d26de4d66b36972f9db962ac86277797abf67cfeda4a3630e5d9` | The zashboard project is MIT, Copyright 2024 Zephyruso; see the exact tag's [`LICENSE`](https://github.com/moooyo/zashboard/blob/v3.16.1-monolith.32/LICENSE) and [`package.json`](https://github.com/moooyo/zashboard/blob/v3.16.1-monolith.32/package.json). The archive includes Leaflet 1.9.4 under BSD-2-Clause and ships its complete license text. | Extracted to `/opt/5gpn/ui` and served as static browser assets by `5gpn-mihomo`. |

The zashboard `dist.zip` is a compiled browser bundle and includes code and
assets from its runtime dependency graph. Those dependencies retain their own
licenses. The exact dependency graph used to build this artifact is recorded in
the tagged [`package.json`](https://github.com/moooyo/zashboard/blob/v3.16.1-monolith.32/package.json)
and [`pnpm-lock.yaml`](https://github.com/moooyo/zashboard/blob/v3.16.1-monolith.32/pnpm-lock.yaml);
5gpn does not rebuild or modify the downloaded archive.

## Optional installer TUI downloaded separately

The installer attempts to download Gum for its terminal UI. Failure is
non-fatal and the installer falls back to plain output.

| Component | Exact release | License evidence | Verified Linux archive digests |
|---|---|---|---|
| [Charmbracelet Gum](https://github.com/charmbracelet/gum/tree/v0.17.0) | `v0.17.0`; `gum_0.17.0_Linux_x86_64.tar.gz`, `gum_0.17.0_Linux_arm64.tar.gz`, and `gum_0.17.0_Linux_armv7.tar.gz` | MIT, Copyright (c) 2022-2024 Charmbracelet, Inc; see [`LICENSE`](https://github.com/charmbracelet/gum/blob/v0.17.0/LICENSE) | `x86_64`: `69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb`; `arm64`: `b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c`; `armv7`: `25711c2fbc6887cde79ed586972834121a04955968808dd688c688381ac50ab2` |

The verified executable is installed as `/opt/5gpn/bin/gum`.

## Runtime rule data

The pinned mihomo binary embeds the China IPv4 prefix snapshot used for
deterministic arbitration. It is part of the versioned core artifact rather than
a mutable installer cache:

| Data source | Fetch behavior | License status |
|---|---|---|
| [`17mon/china_ip_list`](https://github.com/17mon/china_ip_list) | A snapshot is embedded in the pinned `moooyo/mihomo` release; the installer does not fetch or refresh `/etc/5gpn/rules`. | The upstream repository publishes no license file and reports no declared license. No license is inferred here. |

A missing `dns.json` also starts with two enabled 24-hour subscription rules.
They are fetched by the running core into its private state directory and are
not bundled in the 5gpn installer release:

| Data source | Default purpose | Repository license |
|---|---|---|
| [`blackmatrix7/ios_rule_script` ChinaMax domains](https://github.com/blackmatrix7/ios_rule_script) | `direct` subscription in Clash format | GPL-2.0 |
| [`Loyalsoldier/v2ray-rules-dat` gfw list](https://github.com/Loyalsoldier/v2ray-rules-dat) | `proxy` subscription in plain format | GPL-3.0 |

Operator-added rule subscriptions and extension catalogs are neither selected
nor redistributed by the 5gpn release. Their licenses and service terms remain
the operator's responsibility.

## Operating-system packages

The installer asks the host package manager to install system tools. These are
downloaded from the operator's configured OS repositories, are not pinned by
the 5gpn release, and remain governed by the distribution's package metadata
and license notices.

- Debian-family names: `curl`, `ca-certificates`, `unzip`, `iproute2`,
  `openssl`, `qrencode`, `jq`, `util-linux`, and `dnsutils`.
- RPM-family names: `curl`, `ca-certificates`, `unzip`, `iproute`, `openssl`,
  `qrencode`, `jq`, `util-linux`, and `bind-utils`.
- Production certificate modes also install the distribution's `certbot`
  package. Cloudflare DNS-01 mode additionally installs
  `python3-certbot-dns-cloudflare`.

## Network services, not distributed components

Depending on the selected installation mode, the installer may contact GitHub
release APIs, Let's Encrypt's ACME service, Cloudflare through the OS-provided
Certbot plugin, and `api.ipify.org`, `ifconfig.me`, or `icanhazip.com` for public
IPv4 discovery. These are network services, not software or data bundled by
5gpn; their respective service terms apply.

The Console location editor loads the visible OpenStreetMap Standard raster
tiles directly in the operator's browser and displays the required
OpenStreetMap contributor attribution. An explicit city search instead reaches
the fixed Nominatim service through an authenticated, bounded mihomo projection;
the controller credential is never forwarded. OpenStreetMap data is available
under the ODbL, while the public tile and Nominatim services remain governed by
their own usage policies and have no 5gpn availability guarantee.

First-party extension source lives in the separate
[`moooyo/5gpn-extensions`](https://github.com/moooyo/5gpn-extensions)
repository and is not part of the 5gpn installer release. Development and test
dependencies, GitHub Actions, and source trees from the mihomo and zashboard
repositories are likewise not included in `5gpn-installer.tar.gz`.
