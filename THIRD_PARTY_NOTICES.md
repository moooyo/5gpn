# Third-Party Notices

5gpn ("5gpn-dns") is licensed under the MIT License — see [`LICENSE`](LICENSE),
Copyright (c) 2026 moooyo.

This file lists the third-party components that 5gpn **distributes** (compiled
into the `5gpn-dns` binary or bundled in the `5gpn-web` release tarball) or that
`install.sh` **downloads onto the gateway** at install time, together with their
licenses and upstream sources. Development- and test-only tooling (Go test
dependencies, npm `devDependencies`) is not redistributed and is not listed.

Each component remains under its own license. Full license texts are available
at the linked upstream projects; only attribution is reproduced here.

---

## 1. Go modules — compiled into the `5gpn-dns` binary

Versions per [`cmd/5gpn-dns/go.mod`](cmd/5gpn-dns/go.mod).

### Direct

| Module | Version | License | Copyright / Source |
|---|---|---|---|
| `github.com/go-telegram/bot` | v1.22.0 | MIT | © the go-telegram authors — https://github.com/go-telegram/bot |
| `github.com/miekg/dns` | v1.1.72 | BSD-3-Clause | © 2009 The Go Authors; © 2011 Miek Gieben — https://github.com/miekg/dns |

### Indirect (transitively required)

All under BSD-3-Clause, © The Go Authors — https://cs.opensource.google/go/x

| Module | Version |
|---|---|
| `golang.org/x/mod` | v0.31.0 |
| `golang.org/x/net` | v0.48.0 |
| `golang.org/x/sync` | v0.19.0 |
| `golang.org/x/sys` | v0.39.0 |
| `golang.org/x/tools` | v0.40.0 |

---

## 2. Web console — bundled in the `5gpn-web` release tarball

Runtime dependencies per [`web/package.json`](web/package.json) (`dependencies`).

| Package | Version | License | Copyright / Source |
|---|---|---|---|
| `react` | ^19.2.7 | MIT | © Meta Platforms, Inc. and affiliates — https://github.com/facebook/react |
| `react-dom` | ^19.2.7 | MIT | © Meta Platforms, Inc. and affiliates — https://github.com/facebook/react |
| `react-router-dom` | ^7.18.1 | MIT | © Remix Software Inc. — https://github.com/remix-run/react-router |
| `@radix-ui/react-alert-dialog` | ^1.1.19 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@radix-ui/react-dialog` | ^1.1.19 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@radix-ui/react-dropdown-menu` | ^2.1.20 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@radix-ui/react-label` | ^2.1.11 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@radix-ui/react-separator` | ^1.1.11 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@radix-ui/react-slot` | ^1.3.0 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@radix-ui/react-switch` | ^1.3.3 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@radix-ui/react-tabs` | ^1.1.17 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@radix-ui/react-tooltip` | ^1.2.12 | MIT | © WorkOS, Inc. — https://github.com/radix-ui/primitives |
| `@tanstack/react-table` | ^8.21.3 | MIT | © Tanner Linsley — https://github.com/TanStack/table |
| `@tanstack/react-virtual` | ^3.13.0 | MIT | © Tanner Linsley — https://github.com/TanStack/virtual |
| `react-hook-form` | ^7.81.0 | MIT | © react-hook-form contributors — https://github.com/react-hook-form/react-hook-form |
| `@hookform/resolvers` | ^3.10.0 | MIT | © react-hook-form contributors — https://github.com/react-hook-form/resolvers |
| `zod` | ^3.25.76 | MIT | © Colin McDonnell — https://github.com/colinhacks/zod |
| `echarts` | ^6.0.0 | Apache-2.0 | © The Apache Software Foundation — https://github.com/apache/echarts |
| `zrender` (via echarts) | ^6 | BSD-3-Clause | © Baidu, Inc. / ecomfe — https://github.com/ecomfe/zrender |
| `lucide-react` | ^1.24.0 | ISC | © Lucide Contributors; portions © Cole Bemis (Feather) — https://github.com/lucide-icons/lucide |
| `class-variance-authority` | ^0.7.1 | Apache-2.0 | © Joe Bell — https://github.com/joe-bell/cva |
| `clsx` | ^2.1.1 | MIT | © Luke Edwards — https://github.com/lukeed/clsx |
| `tailwind-merge` | ^3.6.0 | MIT | © Dany Castillo — https://github.com/dcastil/tailwind-merge |
| `i18next` | ^23.16.8 | MIT | © i18next / Jan Mühlemann and contributors — https://github.com/i18next/i18next |
| `react-i18next` | ^15.7.4 | MIT | © i18next / Jan Mühlemann and contributors — https://github.com/i18next/react-i18next |
| `i18next-browser-languagedetector` | ^8.2.1 | MIT | © i18next / Jan Mühlemann and contributors — https://github.com/i18next/i18next-browser-languageDetector |
| `uqr` | ^0.1.3 | MIT | © Anthony Fu — https://github.com/unjs/uqr |

> `echarts` incorporates [`zrender`](https://github.com/ecomfe/zrender) (BSD-3-Clause)
> and portions of [d3](https://github.com/d3) (BSD-3-Clause, © Mike Bostock); its
> upstream `NOTICE` (Apache Software Foundation) applies.

---

## 3. Fonts — self-hosted and bundled in the `5gpn-web` tarball

The npm delivery packages are MIT-licensed wrappers; the font files inside carry
their own licenses (listed below). Imported in [`web/src/main.tsx`](web/src/main.tsx).

| Font | Delivery package | Font license | Copyright / Source |
|---|---|---|---|
| Plus Jakarta Sans | `@fontsource/plus-jakarta-sans` ^5.2.8 (MIT) | SIL OFL-1.1 | © 2020 The Plus Jakarta Sans Project Authors (Tokotype) — https://github.com/tokotype/PlusJakartaSans |
| JetBrains Mono | `@fontsource/jetbrains-mono` ^5.2.8 (MIT) | SIL OFL-1.1 | © 2020 The JetBrains Mono Project Authors (JetBrains s.r.o.) — https://github.com/JetBrains/JetBrainsMono |
| MiSans VF | `subsetted-fonts` ^1.0.4 (MIT) | MiSans Font License (Xiaomi) | © Xiaomi Inc. — https://hyperos.mi.com/font/ |

> Only `MiSans-VF` is imported from `subsetted-fonts` (which also vendors other
> unused families). The MiSans Font License permits free use including
> commercial; see the Xiaomi terms at the link above.

---

## 4. Prebuilt binaries — downloaded to the gateway by `install.sh`

Not part of this repository or the release tarballs; fetched at install time (no
Go toolchain on the box). Pins per [`install.sh`](install.sh).

| Component | Version | License | Copyright / Source |
|---|---|---|---|
| mihomo | v1.19.28 | GPL-3.0 | © MetaCubeX contributors — https://github.com/MetaCubeX/mihomo |
| gum | 0.17.0 | MIT | © Charmbracelet, Inc. — https://github.com/charmbracelet/gum |
| Zephyruso/zashboard | v3.15.0 | MIT | © 2024 Zephyruso — https://github.com/Zephyruso/zashboard |

> mihomo is distributed under the GNU General Public License v3.0; its source
> is available at the link above.

> zashboard is a prebuilt frontend `dist.zip` (a mihomo/Clash web dashboard),
> not a compiled binary — `install_zashboard()` downloads and unpacks the
> pinned release archive to `DNS_ZASH_DIR`, served at `DNS_ZASH_LISTEN` and
> reverse-proxied to mihomo's controller by `5gpn-dns` (see `mihomo_proxy.go`).
