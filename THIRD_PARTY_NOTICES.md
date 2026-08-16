# Third-Party Notices

5gpn is licensed under the MIT License. See [`LICENSE`](LICENSE), Copyright
(c) 2026 moooyo.

This document describes both distribution forms: the three-asset GitHub
installer release and the matching GHCR container image. It also records the
external artifacts that the installer or installed runtime retrieves. License
identifiers below are taken from the exact tagged source or package metadata
linked in each entry; the linked license text remains authoritative.

## Included in the 5gpn release

The `5gpn-installer.tar.gz` release asset contains the host installer, service
and configuration templates, maintenance scripts, the Docker Compose file,
bootstrap example and seccomp profile, selected documentation, and this notice
file. The first-party files are covered by the repository's MIT License.

The bundled [`docker/seccomp-5gpn.json`](docker/seccomp-5gpn.json) is derived
from Moby's default seccomp profile at commit
[`f9bc03ec19b2dc4c091449b08e88f85c0caa9f0b`](https://github.com/moby/profiles/blob/f9bc03ec19b2dc4c091449b08e88f85c0caa9f0b/seccomp/default.json),
changed only to allow `clone3` for atomic worker cgroup placement. The upstream
`moby/profiles` material is licensed under Apache-2.0; see its exact-commit
[`LICENSE`](https://github.com/moby/profiles/blob/f9bc03ec19b2dc4c091449b08e88f85c0caa9f0b/LICENSE).

The installer release asset contains no compiled daemon, sidecar, dashboard bundle, Go
module tree, npm package tree, or third-party rule-list snapshot. The current
runtime executable and dashboard are retrieved separately under their own
digest pins.

The GHCR image is a separate registry artifact, not a fourth GitHub Release
asset. It includes the exact digest-verified mihomo executable and zashboard
bundle listed below, but does not include either source tree or rebuild either
component.

## Included in the GHCR image

`ghcr.io/moooyo/5gpn:<tag>` is assembled for `linux/amd64` from
`debian:13-slim` at OCI index digest
`sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258`.
APT resolution is fixed to Debian snapshot timestamp `20260809T000000Z` for
`trixie`, `trixie-updates`, and `trixie-security`; the timestamp is also
recorded in the image label `io.5gpn.debian.snapshot`.
Because the slim base initially has no CA bundle, component preparation
downloads and verifies curl's dated Mozilla CA extract
[`cacert-2026-07-16.pem`](https://curl.se/ca/cacert-2026-07-16.pem), verified as
SHA-256 `3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91`
before the Dockerfile can copy it. It is used only to authenticate the immutable
Debian snapshot transaction and is then replaced by the snapshot's
`ca-certificates` package. The bundle is
generated from Mozilla's CA certificate store; its NSS source is governed by
MPL-2.0 and the included trust anchors remain the certificates of their
respective issuers.
The image preparation step reads the component coordinates directly from the
tagged `install.sh`, verifies their SHA-256 digests, and then copies the same
mihomo and zashboard artifacts named in the next table. It also installs these
Debian packages from the pinned base image's configured repositories:

- `bash`, `ca-certificates`, `coreutils`, `findutils`, `iproute2`, `jq`,
  `openssl`, `passwd`, and `util-linux`;
- `certbot` and `python3-certbot-dns-cloudflare` for the Docker-only
  Cloudflare DNS-01 certificate path.

Those Debian packages, their transitive dependencies, and Python modules retain
their own licenses. The installed package database and
`/usr/share/doc/*/copyright` files in the immutable image identify the exact
versions and applicable Debian copyright notices. No Python source or module
tree is added to this repository; Python is present only as an image dependency
of the distribution-provided Certbot tooling.

## Runtime artifacts consumed by both delivery forms

The host installer retrieves these exact upstream release artifacts and
publishes them on the gateway. Docker image preparation retrieves the same
coordinates. Both paths verify the listed SHA-256 digest before use.

| Component | Exact release and downloaded artifact | SHA-256 | License evidence | Installed use |
|---|---|---|---|---|
| 5gpn mihomo fork | [`moooyo/mihomo` `v1.19.28-monolith.29`](https://github.com/moooyo/mihomo/releases/tag/v1.19.28-monolith.29), `mihomo-linux-amd64-compatible-v1.19.28-monolith.29.gz` | `d04749b6b51974a788028b6596a3a2db803ca4144f60f915cd696c181f7a7ae3` | GPL-3.0; see the exact tag's [`LICENSE`](https://github.com/moooyo/mihomo/blob/v1.19.28-monolith.29/LICENSE) and [source](https://github.com/moooyo/mihomo/tree/v1.19.28-monolith.29) | Published as `/opt/5gpn/bin/5gpn-mihomo` by both forms; this is the sole long-running 5gpn process. |
| zashboard fork | [`moooyo/zashboard` `v3.16.1-monolith.30`](https://github.com/moooyo/zashboard/releases/tag/v3.16.1-monolith.30), `dist.zip` | `e10f8af6a05b03ae4182104777b8de4ba95e0b4eeb6455d0f7595f29af6ae55f` | The zashboard project is MIT, Copyright 2024 Zephyruso; see the exact tag's [`LICENSE`](https://github.com/moooyo/zashboard/blob/v3.16.1-monolith.30/LICENSE) and [`package.json`](https://github.com/moooyo/zashboard/blob/v3.16.1-monolith.30/package.json). The archive includes Leaflet 1.9.4 under BSD-2-Clause and ships its complete license text. | The host installer extracts it to `/opt/5gpn/ui`; the image stores it under `/usr/share/5gpn/ui` and bootstrap copies it into the `/opt/5gpn/ui` tmpfs. Mihomo serves those static browser assets. |

The zashboard `dist.zip` is a compiled browser bundle and includes code and
assets from its runtime dependency graph. Those dependencies retain their own
licenses. The exact dependency graph used to build this artifact is recorded in
the tagged [`package.json`](https://github.com/moooyo/zashboard/blob/v3.16.1-monolith.30/package.json)
and [`pnpm-lock.yaml`](https://github.com/moooyo/zashboard/blob/v3.16.1-monolith.30/pnpm-lock.yaml);
5gpn does not rebuild or modify the downloaded archive.

## Optional installer TUI downloaded separately

The installer attempts to download Gum for its terminal UI. Failure is
non-fatal and the installer falls back to plain output.

| Component | Exact release | License evidence | Verified Linux archive digests |
|---|---|---|---|
| [Charmbracelet Gum](https://github.com/charmbracelet/gum/tree/v0.17.0) | `v0.17.0` | MIT, Copyright (c) 2022-2024 Charmbracelet, Inc; see [`LICENSE`](https://github.com/charmbracelet/gum/blob/v0.17.0/LICENSE) | `x86_64`: `69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb`; `arm64`: `b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c`; `armv7`: `25711c2fbc6887cde79ed586972834121a04955968808dd688c688381ac50ab2` |

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

The host installer asks the host package manager to install system tools. These are
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

Depending on the selected host installation mode, the installer may contact
GitHub release APIs, Let's Encrypt's ACME service, Cloudflare through the
OS-provided Certbot plugin, and `api.ipify.org`, `ifconfig.me`, or
`icanhazip.com` for public IPv4 discovery. The Docker form also contacts Let's
Encrypt and Cloudflare, but supports only DNS-01. These are network services,
not software or data bundled by 5gpn; their respective service terms apply.

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

The release workflow uses the official
[`moby/buildkit` `v0.32.2`](https://github.com/moby/buildkit/tree/v0.32.2)
builder at OCI index digest
`sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8`
to rewrite layer timestamps deterministically. BuildKit is Apache-2.0 licensed
and is release infrastructure only; it is not copied into either release form.
The Dockerfile frontend is likewise fixed to
`docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e`
(the `1.7.1` OCI index at publication time). It is BuildKit/Apache-2.0 build
infrastructure and is not copied into the runtime image.
