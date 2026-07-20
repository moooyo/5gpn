# Third-Party Notices

5gpn ("5gpn-dns") is licensed under the MIT License — see [`LICENSE`](LICENSE),
Copyright (c) 2026 moooyo.

This file lists the third-party components that 5gpn **distributes** (compiled
into the `5gpn-dns` or `5gpn-intercept` binaries or bundled in the `5gpn-web`
release tarball) or that `install.sh` **downloads onto the gateway** at install
time, together with their licenses and upstream sources. Development- and
test-only tooling (Go test dependencies, npm `devDependencies`) is not
redistributed and is not listed.

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
| `@base-ui/react` | 1.6.0 | MIT | © MUI Team and contributors — https://github.com/mui/base-ui |
| `@fontsource/jetbrains-mono` | ^5.2.8 | MIT wrapper / OFL-1.1 font | © Fontsource; © JetBrains s.r.o. — https://fontsource.org/fonts/jetbrains-mono |
| `@material-symbols/svg-400` | 0.45.8 | Apache-2.0 | Material Symbols © Google LLC; package © Marella — https://github.com/marella/material-symbols |
| `@tanstack/react-table` | ^8.21.3 | MIT | © Tanner Linsley — https://github.com/TanStack/table |
| `@tanstack/react-virtual` | ^3.13.0 | MIT | © Tanner Linsley — https://github.com/TanStack/virtual |
| `clsx` | ^2.1.1 | MIT | © Luke Edwards — https://github.com/lukeed/clsx |
| `daisyui` | 5.6.18 | MIT | © Pouya Saadeghi and contributors — https://github.com/saadeghi/daisyui |
| `i18next` | ^23.16.8 | MIT | © i18next / Jan Mühlemann and contributors — https://github.com/i18next/i18next |
| `i18next-browser-languagedetector` | ^8.2.1 | MIT | © i18next contributors — https://github.com/i18next/i18next-browser-languageDetector |
| `leaflet` | 1.9.4 | BSD-2-Clause | © 2010–2023 Vladimir Agafonkin; © 2010–2011 CloudMade — https://leafletjs.com/ |
| `react` | ^19.2.7 | MIT | © Meta Platforms, Inc. and affiliates — https://github.com/facebook/react |
| `react-dom` | ^19.2.7 | MIT | © Meta Platforms, Inc. and affiliates — https://github.com/facebook/react |
| `react-hook-form` | ^7.81.0 | MIT | © react-hook-form contributors — https://github.com/react-hook-form/react-hook-form |
| `react-i18next` | ^15.7.4 | MIT | © i18next / Jan Mühlemann and contributors — https://github.com/i18next/react-i18next |
| `react-router-dom` | ^7.18.1 | MIT | © Remix Software Inc. — https://github.com/remix-run/react-router |
| `subsetted-fonts` | ^1.0.4 | MIT wrapper / MiSans Font License | © subsetted-fonts contributors; © Xiaomi Inc. — https://www.npmjs.com/package/subsetted-fonts |
| `tailwind-merge` | ^3.6.0 | MIT | © Dany Castillo — https://github.com/dcastil/tailwind-merge |
| `uqr` | ^0.1.3 | MIT | © Anthony Fu — https://github.com/unjs/uqr |

The optional location-setting editor requests map tiles from OpenStreetMap and
explicit city searches from Nominatim. OpenStreetMap data is © OpenStreetMap
contributors under ODbL; attribution is rendered on the map. These services
are not bundled or mirrored by 5gpn. The browser loads tiles directly; explicit
city searches use a bounded authenticated same-origin projection that contacts
only the fixed Nominatim origin.

---

## 3. Fonts — self-hosted and bundled in the `5gpn-web` tarball

The npm delivery packages are MIT-licensed wrappers; the font files inside carry
their own licenses (listed below). Imported in [`web/src/main.tsx`](web/src/main.tsx).

| Font | Delivery package | Font license | Copyright / Source |
|---|---|---|---|
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

---

## 5. Interception sidecar

Third-party native extension manifests installed by an operator are stored only
on that operator's gateway and are not crawled, mirrored, or redistributed by
5gpn. Their own licenses and usage terms remain the operator's responsibility.

First-party extension source and its third-party notices are maintained in the
separate `moooyo/5gpn-extensions` repository. They are not part of this core
repository or its release artifacts.

### quic-go

`5gpn-intercept` includes `github.com/quic-go/quic-go` v0.60.0.

Its redistributed transitive modules are:

| Module | Version | License | Source |
|---|---|---|---|
| `github.com/quic-go/qpack` | v0.6.0 | MIT | https://github.com/quic-go/qpack |
| `golang.org/x/crypto` | v0.51.0 | BSD-3-Clause | https://cs.opensource.google/go/x/crypto |
| `golang.org/x/net` | v0.55.0 | BSD-3-Clause | https://cs.opensource.google/go/x/net |
| `golang.org/x/sys` | v0.45.0 | BSD-3-Clause | https://cs.opensource.google/go/x/sys |
| `golang.org/x/text` | v0.37.0 | BSD-3-Clause | https://cs.opensource.google/go/x/text |

MIT License

Copyright (c) 2016 the quic-go authors & Google, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### goja

`5gpn-intercept` includes `github.com/dop251/goja`
v0.0.0-20260701091749-b07b74453ea9.

Its additional redistributed transitive modules are:

| Module | Version | License | Source |
|---|---|---|---|
| `github.com/go-sourcemap/sourcemap` | v2.1.3 | BSD-2-Clause | https://github.com/go-sourcemap/sourcemap |
| `github.com/google/pprof` | v0.0.0-20230207041349-798e818bf904 | Apache-2.0 | https://github.com/google/pprof |

MIT License

Copyright (c) 2016 Dmitry Panov

Copyright (c) 2012 Robert Krimen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### andybalholm/brotli

`5gpn-intercept` directly imports `github.com/andybalholm/brotli` v1.2.2
for bounded Brotli request and response decoding.

MIT License

Copyright (c) 2009, 2010, 2013-2016 by the Brotli Authors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### regexp2

`5gpn-intercept` directly imports `github.com/dlclark/regexp2/v2` v2.2.1
to set the timeout on goja's backtracking regular-expression fallback.

MIT License

Copyright (c) Doug Clark

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
