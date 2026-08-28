# Third-Party Notices

5gpn is licensed under the MIT License. See [`LICENSE`](LICENSE), Copyright
(c) 2026 moooyo.

This document covers both distribution forms: the three-asset GitHub installer
release and the matching GHCR image. License identifiers below come from the
linked exact source or package metadata; the linked license text remains
authoritative.

## Included in the 5gpn release

The `5gpn-installer.tar.gz` asset contains the host installer, service and
configuration templates, maintenance scripts, the tagged Docker Compose,
seccomp, bootstrap-example, and runbook launch set, selected documentation, and
this notice. It also contains `release/pins.env` and the strict
`release/pins.sh` parser and URL builder; installed host deployments retain both
under `/opt/5gpn/release`. Except for the separately identified Moby-derived
seccomp profile, these first-party files are covered by this repository's MIT
License.

The GitHub asset contains no compiled daemon, sidecar, dashboard bundle, Go
module tree, npm package tree, or third-party rule-list snapshot. Mihomo and
Zashboard are retrieved separately under their own digest pins. The matching
GHCR image is a registry artifact, not a fourth GitHub Release asset; it embeds
the same verified Core and Console artifacts without rebuilding either source
tree.

The bundled [`docker/seccomp-5gpn.json`](docker/seccomp-5gpn.json) is derived
from Moby's default seccomp profile at commit
[`f9bc03ec19b2dc4c091449b08e88f85c0caa9f0b`](https://github.com/moby/profiles/blob/f9bc03ec19b2dc4c091449b08e88f85c0caa9f0b/seccomp/default.json),
changed only for the container worker's `clone3` placement requirement. The
upstream material is Apache-2.0; see the exact commit's
[`LICENSE`](https://github.com/moby/profiles/blob/f9bc03ec19b2dc4c091449b08e88f85c0caa9f0b/LICENSE).

## Release artifacts consumed by both delivery forms

`release/pins.env` is the machine-readable authority for these coordinates.
The release binding gate requires this table to match that manifest. The host
installer and Docker component preparation both use `release/pins.sh`, verify
the listed SHA-256 digest, and publish or embed the same bytes.

| Component | Exact release and downloaded artifact | SHA-256 | License evidence | Installed use |
|---|---|---|---|---|
| 5gpn mihomo fork | [`moooyo/mihomo` `v1.19.30-monolith.36`](https://github.com/moooyo/mihomo/releases/tag/v1.19.30-monolith.36), `mihomo-linux-amd64-compatible-v1.19.30-monolith.36.gz` | `62f36347d1088a42ce389a15346e5517009a6fe9c83b9ac894a97033a40d119e` | GPL-3.0; see the exact tag's [`LICENSE`](https://github.com/moooyo/mihomo/blob/v1.19.30-monolith.36/LICENSE) and [source](https://github.com/moooyo/mihomo/tree/v1.19.30-monolith.36) | Installed or embedded as `/opt/5gpn/bin/5gpn-mihomo`; this is the sole long-running 5gpn process. |
| zashboard fork | [`moooyo/zashboard` `v3.21.0-monolith.35`](https://github.com/moooyo/zashboard/releases/tag/v3.21.0-monolith.35), `dist.zip` | `f653ccd9a2b415155c54092bd7e33aa5d2f7fe3361e8dd6d659659e3f0d37c87` | MIT, Copyright 2024 Zephyruso; see the exact tag's [`LICENSE`](https://github.com/moooyo/zashboard/blob/v3.21.0-monolith.35/LICENSE) and [`package.json`](https://github.com/moooyo/zashboard/blob/v3.21.0-monolith.35/package.json). The archive includes Leaflet 1.9.4 under BSD-2-Clause and its complete license text. | Host installation publishes it in the `/opt/5gpn/ui/current` generation. The image stores verified source bytes under `/usr/share/5gpn/ui` and container bootstrap publishes the same generation shape. |

The Zashboard archive is a compiled browser bundle containing code and assets
from its runtime dependency graph. Those dependencies retain their own
licenses. The exact graph is recorded in the tagged
[`package.json`](https://github.com/moooyo/zashboard/blob/v3.21.0-monolith.35/package.json)
and [`pnpm-lock.yaml`](https://github.com/moooyo/zashboard/blob/v3.21.0-monolith.35/pnpm-lock.yaml).

## Included in the GHCR image

`ghcr.io/moooyo/5gpn:<tag>` is assembled for `linux/amd64` from
`debian:13-slim` at OCI index digest
`sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258`.
APT resolution is fixed to Debian snapshot timestamp `20260809T000000Z` for
`trixie`, `trixie-updates`, and `trixie-security`; the timestamp is recorded in
the image label `io.5gpn.debian.snapshot`.

Because the slim base initially has no CA bundle, component preparation
downloads curl's dated Mozilla CA extract
[`cacert-2026-07-16.pem`](https://curl.se/ca/cacert-2026-07-16.pem), verifies
SHA-256 `3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91`,
and uses it only to authenticate the immutable Debian snapshot transaction. The
snapshot's `ca-certificates` package replaces it. The bundle is generated from
Mozilla's CA certificate store; its NSS source is MPL-2.0 and the included
trust anchors remain the certificates of their respective issuers.

The image installs the following Debian packages from the pinned snapshot:

- `bash`, `ca-certificates`, `coreutils`, `findutils`, `iproute2`, `jq`,
  `openssl`, `passwd`, and `util-linux`;
- `certbot` and `python3-certbot-dns-cloudflare` for the container's
  Cloudflare DNS-01 certificate path.

Those packages, their transitive dependencies, and Python modules retain their
own licenses. The image's package database and `/usr/share/doc/*/copyright`
files identify the installed versions and applicable Debian notices. No Python
source or module tree is added to this repository; Python is present only as an
image dependency of the distribution-provided Certbot tooling.

## Optional installer TUI downloaded separately

The host installer attempts to download Gum for its terminal UI. Failure is
non-fatal and the installer falls back to plain output.

| Component | Exact release | License evidence | Verified Linux archive digests |
|---|---|---|---|
| [Charmbracelet Gum](https://github.com/charmbracelet/gum/tree/v0.17.0) | `v0.17.0`; `gum_0.17.0_Linux_x86_64.tar.gz`, `gum_0.17.0_Linux_arm64.tar.gz`, and `gum_0.17.0_Linux_armv7.tar.gz` | MIT, Copyright (c) 2022-2024 Charmbracelet, Inc; see [`LICENSE`](https://github.com/charmbracelet/gum/blob/v0.17.0/LICENSE) | `x86_64`: `69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb`; `arm64`: `b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c`; `armv7`: `25711c2fbc6887cde79ed586972834121a04955968808dd688c688381ac50ab2` |

The verified executable is installed as `/opt/5gpn/bin/gum` on the host. It is
build infrastructure and is not copied into the runtime image.

## Runtime rule data

The pinned mihomo binary embeds the China IPv4 prefix snapshot used for
deterministic arbitration. It is part of the versioned Core artifact rather
than a mutable installer cache:

| Data source | Fetch behavior | License status |
|---|---|---|
| [`17mon/china_ip_list`](https://github.com/17mon/china_ip_list) | A snapshot is embedded in the pinned `moooyo/mihomo` release; neither delivery fetches or refreshes `/etc/5gpn/rules`. | The upstream repository publishes no license file and reports no declared license. No license is inferred here. |

A missing `dns.json` starts with two enabled 24-hour subscription rules. The
running Core fetches them into its private state directory; neither the
installer asset nor the image bundles the rule data.

| Data source | Default purpose | Repository license |
|---|---|---|
| [`blackmatrix7/ios_rule_script` ChinaMax domains](https://github.com/blackmatrix7/ios_rule_script) | `direct` subscription in Clash format | GPL-2.0 |
| [`Loyalsoldier/v2ray-rules-dat` gfw list](https://github.com/Loyalsoldier/v2ray-rules-dat) | `proxy` subscription in plain format | GPL-3.0 |

Operator-added rule subscriptions are neither selected nor redistributed by a
5gpn release; their licenses and service terms remain the operator's
responsibility. The extension marketplace index is different: a release selects
exactly one, the first-party index published from
[`moooyo/5gpn-extensions`](https://github.com/moooyo/5gpn-extensions), and
compiles its URL in. Selecting that listing is not redistributing what it
lists — extensions are still fetched by the operator from their own publishers
and are covered by their own licenses.

## Host operating-system packages

The host installer asks the operator's package manager to install system tools.
They are not pinned by the 5gpn release and remain governed by distribution
metadata and notices.

- Debian-family names: `curl`, `ca-certificates`, `unzip`, `iproute2`,
  `openssl`, `qrencode`, `jq`, `util-linux`, and `dnsutils`.
- RPM-family names: `curl`, `ca-certificates`, `unzip`, `iproute`, `openssl`,
  `qrencode`, `jq`, `util-linux`, and `bind-utils`.
- Production certificate modes also install `certbot`; Cloudflare DNS-01 also
  installs `python3-certbot-dns-cloudflare`.

## Network services, not distributed components

Depending on delivery and certificate mode, 5gpn may contact GitHub release
APIs, Let's Encrypt's ACME service, Cloudflare through the distribution Certbot
plugin, and public IPv4 discovery services. These are network services, not
software or data bundled by 5gpn; their respective service terms apply.

Opening the Console Marketplace page fetches the fixed first-party index at
`https://moooyo.github.io/5gpn-extensions/marketplace/v2/index.json`, served by
GitHub Pages. The URL is compiled into the core and is the only marketplace a
release contacts. The listing is discovery metadata; nothing is installed,
enabled, or executed by fetching it.

The Console location editor loads visible OpenStreetMap Standard raster tiles
directly in the operator's browser and displays the required attribution. An
explicit city search reaches the fixed Nominatim service through an
authenticated, bounded mihomo projection; the controller credential is never
forwarded. OpenStreetMap data is ODbL, while the public tile and Nominatim
services remain governed by their own usage policies and have no 5gpn
availability guarantee.

First-party extension source lives in the separate
[`moooyo/5gpn-extensions`](https://github.com/moooyo/5gpn-extensions)
repository and is not part of either 5gpn distribution form. Development and
test dependencies, GitHub Actions, and source trees from the Mihomo and
Zashboard repositories are likewise not included in `5gpn-installer.tar.gz`.
