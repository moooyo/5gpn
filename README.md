# 5gpn

**基于自研 Go 守护进程 `5gpn-dns` 的中国线路 DNS/SNI 网关。** 核心是"**解析即策略**"——用 DNS 解析结果决定一条流量由客户端直连还是先进入网关：代理意图域名被解析成网关自己的 IP，自然漏斗进网关上的 **mihomo**；直连意图域名返回真实 IP，客户端直接连接、网关不经手。mihomo 的后续出口由运维者拥有的完整配置决定（默认种子为 `DIRECT`，也可配置应用层代理节点/组）。客户端通过 **DoT** 接入（DoT 是唯一的 DNS 接入方式），**无需装任何 App**。

> 仅用于已获合法授权的企业组网与技术研究，请遵守所在地法律法规。

---

## 工作原理

```
客户端 (Android 私人 DNS / iOS 描述文件)
        │  DoT :853   (TLS，Let's Encrypt 或 debug 证书)   —— 唯一 DNS 传输
        ▼
┌────────────────────────────────────────────────────────────┐
│ 5gpn-dns —— 一个 Go 二进制，一个进程                         │
│   ① 按 order 评估统一策略，跨意图 first-match                │
│      block → NXDOMAIN；direct → 真实 IP；proxy → 网关 IP     │
│   ② 未命中按 fallback：auto / direct / gateway               │
│      auto 使用确定性 chnroute 仲裁                            │
│        并发查 国内UDP ‖ 可信DoT                              │
│        国内答案 IP ∈ chnroute? → 直连;否则 → 网关 IP        │
│                                                             │
│   同进程还跑：控制台 REST API + Web UI + iOS 描述文件        │
│              (回环 :443，经 mihomo 的 :443 SNI 分流暴露；     │
│               console 公开 SPA+/ios，API bearer；zash 白名单)、 │
│              zashboard 面板、Telegram bot                    │
└────────────────────────────────────────────────────────────┘
        │ 境外 → 网关 IP                    │ 国内 → 真实 IP / 封锁 → NXDOMAIN
        ▼                                    ▼
  mihomo (TCP 80/443/5060/8080/8443; UDP 443/5060) Client direct / no connection
  · SNI == console → DIRECT 回环（API bearer）；SNI == zashboard →
    源 IP 命中 whitelist.txt 才 DIRECT，否则快速 REJECT
  · 其余 SNI/QUIC → mihomo 内置嗅探器（sniffer）取域名，经 5gpn-dns 的回环 Egress DNS
    Broker (127.0.0.1:5354) re-resolves through DNS_EGRESS_RESOLVER
    (operational default: plain-UDP 22.22.22.22)
  · enabled native extension capture host + MITM master on → authenticated SOCKS5 TCP/UDP → 5gpn-intercept
    (configurable TLS/H1/H2 + QUIC v1/v2/HTTP3 termination or QUIC fallback protection) →
    authenticated SOCKS5 TCP/UDP → mihomo intercept-egress → ordered operator group binding → operator egress
        │
        ▼
  按运维者的 mihomo 配置选择应用层出口（默认 DIRECT）→ 互联网
```

**一个主域名、一条证书 lineage**：`BASE_DOMAIN` 自动派生 `console.<base>`、`zash.<base>` 和 `dot.<base>`。Cloudflare 模式签发 apex + `*.<base>`，HTTP-01 模式则只签发这三个服务名的精确 SAN；两种生产模式都固定使用 `--cert-name <base>` 的同一条 scoped lineage。`console.<base>` 提供 SPA 与公开的 iOS profile 下载，所有 `/api/*` 仍强制 bearer token；`zash.<base>` 继续由 mihomo 来源白名单保护。

Modular MITM uses a completely separate private root CA. It is not
part of the public lineage above and never replaces the DoT or console
certificate. Only the root-owned certificate publisher can use its signing key
to create a leaf for the enabled extension capture-host set; the runtime sidecar cannot
read that key.

| 场景 | DNS 行为 | 数据路径 |
|---|---|---|
| 命中 block | NXDOMAIN | 客户端不发起连接 |
| 命中 proxy（强制进入网关） | 直接返回网关 IP | 客户端 → mihomo → 运维者配置的出口 |
| 仲裁后国外 IP | 改写为网关 IP | 客户端 → mihomo → 运维者配置的出口 |
| 仲裁后国内 IP | 原样返回真实 IP | 客户端直连，网关不经手 |
| SNI = console 域名 | —— | 公开 SPA 资源与 `/ios/ios-dot.mobileconfig`；`/api/*` 强制 bearer |
| SNI = zashboard 域名（源 IP 在白名单） | —— | mihomo :443 → 独立回环面板 |

---

## 关键特性

- **Deterministic chnroute arbitration**: query the operational China resolver `223.5.5.5` and trust resolver `22.22.22.22` concurrently over UDP/53, then decide by chnroute membership rather than response speed.
- **DoT-only 入口**：唯一的客户端 DNS 传输是 DoT `:853`；不提供 DoH 或客户端明文 `:53`。另有一个仅回环的 `127.0.0.1:5353` 明文调试监听，仅用于本机排障。
- **All query types**: A uses arbitration and rewriting; AAAA returns IPv4-only NODATA with SOA; HTTPS/SVCB returns NODATA to preserve hostname sniffing; other types use the trust upstream.
- **Sniff-failure isolation**: new mihomo seeds pair same-port `console.<base>` listener targets with an exact `force-domain` entry. Successful sniffing still replaces the provisional target with the real origin, while malformed public traffic cannot poison one shared IP failure-cache key for every connection.
- **有序统一策略**：`/etc/5gpn/policy.json` 中每条规则以 exact/suffix/keyword/subscription 匹配一种 block/direct/proxy 意图，跨意图按全局顺序 first-match；未命中项可选 auto/direct/gateway fallback。系统 chnroute 与编译后的策略订阅由进程内抓取器定时更新，域名列表支持 `plain`/`gfwlist`/`dnsmasq`/`hosts`，chnroute 使用 `cidr`；失败保留旧缓存（离线安全）。
- **统一控制面**（多前端共用同一内存 `Controller`）：
  - **HTTPS REST API + React Web 控制台 + iOS 描述文件**：console SPA 资源与 profile 下载公开，所有 API 需 bearer token；iOS/Android 配置说明、二维码与下载入口统一位于控制台“配置向导”；zashboard 仍由 mihomo `whitelist.txt` 来源白名单保护。
  - **zashboard 面板**：同样经 mihomo SNI 分流 + 白名单暴露到本机另一回环端口。
  - **进程内 Telegram bot**（`github.com/go-telegram/bot`，管理员门控，直接调 `Controller`、不走 HTTP/token）。
  - **插件控制一致性**：Console `/extensions` 与 Telegram 插件菜单调用同一个事务管理器；启用或关闭会一并更新证书、mihomo 规则和 DNS 引流，任一步失败都会回滚或保持旧状态。`/extensions/hosts` 提供按插件分组的接管域名审计。
  - **Mihomo controller TLS**：zash 证书角色由 zashboard 与 mihomo controller 共用。`DNS_MIHOMO_CONTROLLER` 是回环拨号地址；客户端以派生的 `zash.<base>` 校验 TLS 身份并信任 `DNS_ZASH_CERT`。Mihomo v1.19.28 通过只读 `SAFE_PATHS=/etc/5gpn/cert/zash` 读取位于 `-d /etc/5gpn/mihomo` 外的证书。普通重装逐字节保留已通过校验的 operator-owned 配置；若 verified controller transport 无法构造，DNS 与其余控制面继续运行，Mihomo 健康、配置和代理端点返回 unavailable/503，绝不降级到明文 HTTP。
- **出口由 mihomo 原生配置拥有**：被代理流量经 mihomo 的 `tunnel` 监听 + 内置嗅探器透明转发；完整 `/etc/5gpn/mihomo/config.yaml` 由运维者管理，默认 `Proxies` 组只有 `DIRECT`，也可加入 mihomo 支持的应用层节点/组。The allowlisted module sidecar is the only TLS-termination exception, and every transformed upstream returns through mihomo. An extension may require an operator binding to an existing group, but its manifest and script cannot name or change that group. DNS 策略只决定“是否进入网关”，绝不生成 mihomo 出口。仍禁止 TUN/TProxy、WireGuard、fwmark、策略路由表或把本项目变成客户端默认路由器。
- **Explicit alternate Web ports**: the initial mihomo seed accepts TCP `:8080` and `:8443` in addition to `:80` and `:443`. HTTP Host or TLS SNI replaces the synthetic gateway destination while preserving the accepted port. This does not provide arbitrary-port, raw-UDP, no-SNI, or ECH-inner-name forwarding.
- **Ingress modules**: Settings exposes a fixed, explicit catalog backed by the complete operator-owned mihomo YAML. The `speedtest-5060` module is enabled in fresh and explicitly reset seeds, adding TCP/UDP `:5060`, a same-port `console.<base>:5060` forced-sniff target, HTTP/TLS/QUIC sniffing, and port-scoped rejects for the loopback console panels. Operators can disable or re-enable it with revision checks, full `mihomo -t` validation, backup, atomic publication, and hot-apply rollback. Its hostname target isolates malformed traffic from the other default ingress ports. TCP needs a visible Host/SNI and UDP supports recognizable QUIC only — Ookla native UDP and other raw UDP remain unsupported. Because `5060` is also a common SIP port and the listener is an unauthenticated Host/SNI relay, restrict its sources with the provider security group or an independently managed firewall.
- **Native interception extensions**: the dedicated Console page accepts only strict `5gpn.io/v1` YAML manifests from one HTTPS URL or a local paste/upload. A manifest explicitly declares immutable metadata, `captureHosts`, structured request/response actions, typed settings, optional bounded storage, exact HTTP(S) network origins, an optional operator-group requirement, and safe upstream mappings. Unknown fields and unsafe YAML features fail installation; there is no third-party client-format compatibility layer. Every script defines `transform(context)` and runs in a fresh bounded goja VM with no filesystem, process, timer, module-loader, socket, or ambient `fetch`. Only an explicitly declared and confirmed origin list exposes synchronous `context.network.request`; all such traffic still returns through mihomo. The Console shows explicit execution order, lets the operator bind an existing group, and warns that a permitted script may send any decrypted data visible to it to those origins. Text and Uint8Array bodies support bounded identity, gzip, deflate, and Brotli decoding. Apple WLOC lives under `extensions/apple-wloc` as a normal URL-installable plugin and uses the generic map-backed `location` setting; it is not compiled into either daemon.
  The complete author contract is documented in [`docs/native-extensions.md`](docs/native-extensions.md).
- **MITM runtime controls**: Settings owns a disabled-by-default master switch plus `MitM over HTTP/2` and `QUIC fallback protection`. The master atomically publishes or removes the DNS/mihomo host routes and starts or stops `5gpn-intercept`, while preserving armed module snapshots. HTTP/2 can be disabled for new client/upstream connections. QUIC fallback protection discards only already-matched IETF QUIC v1/v2 traffic so capable clients can retry over TCP/HTTPS; it does not claim legacy GQUIC support.
- **Default HTTP/3 / QUIC compatibility guard**: fresh and explicitly reset mihomo configs enable a Settings-controlled fixed rule that rejects gateway UDP/443 after the ordered authenticated interception-egress rules and their fail-closed guard. Capable clients fall back to TCP/HTTPS. Existing valid operator configs are preserved, and this is not host-firewall management.
- **无宿主防火墙**：项目不管理宿主 nftables；zashboard 的网络访问控制由 mihomo 来源白名单承担，console API 依赖 bearer 鉴权。
- **Operational hardening**: certificate pairs hot-reload without a service restart; HTTP-01 stops mihomo only for the bounded ACME `:80` challenge; `kill -HUP` remains rules-only; privileged bot operations can request only pre-installed fixed units through narrowly authorized `systemctl` actions.
- **Minimal runtime dependencies**: the repository contains no Python. `5gpn-dns` retains its three direct dependencies (`miekg/dns`, `go-telegram/bot`, and `yaml.v3`); the separate interception module has four explicit direct dependencies: `quic-go`, `goja`, `regexp2` (used to bound goja's backtracking fallback), and pinned `brotli` decoding. Release binaries are built in CI, so no compiler toolchain is installed on the gateway.

---

## 安装

在一台 root 权限的 Linux 网关上：

```bash
# Latest official release (default)
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash

# Latest published beta prerelease (explicit opt-in)
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash -s -- --beta

# A checkout delegates to the same exact-tag bundle selection
sudo bash install.sh
sudo bash install.sh --beta
```

Official and beta selection is per installer invocation. The default path only
accepts `X.Y.Z`; `--beta` only accepts a published `X.Y.Z-beta.N` prerelease.
Missing or malformed beta metadata fails closed and never falls back to an
official release. Release channels select only first-party 5gpn artifacts;
third-party version and checksum pins remain unchanged.

> First installation requires the TUI. It collects the certificate mode, base domain, certificate email, and Cloudflare token when selected. `PUBLIC_IP` is detected automatically; the gateway and listener default to it. `5gpn configure` retains advanced public/gateway/listener overrides for special network layouts. China DNS defaults to `223.5.5.5` over UDP/53, trust DNS and the egress resolver default to `22.22.22.22` over UDP/53, China ECS defaults to `112.96.32.0/24`, and cache size is selected from the memory profile. Caller environment variables never override configuration; a first install without a TTY fails closed, while reinstall can reuse a valid `dns.env` non-interactively.

> TCP `:8080`, TCP/UDP `:5060`, and TCP `:8443` are present in new seeds and explicit `5gpn mihomo-reset` output. Reinstall preserves an existing valid operator-owned mihomo config byte-for-byte, so existing deployments do not gain missing listeners automatically; use the module switch where manageable, edit the YAML manually, or use the explicit reset path after reviewing its backup-and-replace behavior. Provider security groups or upstream firewalls must allow only the intended clients.

> The `speedtest-5060` switch requires the reviewed rule boundary: base panel protocol/port rejects, the two `:5060` panel rejects, panel routes, zashboard deny-by-default, anti-loop destination guards, then terminal `MATCH`. The anti-loop guards intentionally follow the panel routes because mihomo resolves the console fallback through `hosts` before rule matching. Older operator-owned configs are still preserved and may therefore show the module as custom/unmanageable until the rules are reordered manually or the reviewed seed is restored explicitly.

安装器会先把固定版本的 5gpn-dns、Web、mihomo、zashboard 下载到 staging 并强制校验 SHA-256，再备份当前部署、原子发布并执行 readiness 探针；发布后失败会自动回滚。生产证书可选 Cloudflare DNS-01 或 HTTP-01，debug 模式使用隔离的自签证书。

**内网部署**（客户端在内网，如 `172.22.0.0/16`，经内网直达网关、不经公网）——这是本项目的主力场景：

运行 `sudo bash install.sh`，在 TUI 的“客户端可达网关 IPv4”中填写内网地址；证书模式也在同一向导选择。`console.`、`zash.`、`dot.` 三个域名自动从主域名派生。

- **配置只有一个持久入口**：安装器配置由 TUI 写入 `/etc/5gpn/dns.env`；重装只读该文件，明确忽略调用者环境。仅 Cloudflare 模式需要的 API token 单独保存在 root-only 的 `/etc/5gpn/acme/cloudflare.ini`，不会进入 `dns.env`、调用者环境或日志。
- **重跑刷新程序、保留运维配置**：每次运行安装脚本都会刷新 systemd 单元、`/opt/5gpn` 运行目录以及 pin 版本的 5gpn-dns/mihomo/Web 产物；`/etc/5gpn` 和 `/etc/letsencrypt` 持久保留。已有且通过 `mihomo -t` 的完整 mihomo 配置会逐字节保留；只有显式 `mihomo-reset` 才会在备份和校验后替换它。下载或校验失败会中止且不预删工作二进制。
- **一个主域名、一条 lineage、三个证书角色目录**：两种生产模式都只使用 cert-name 为 `<base>` 的**一条** scoped Certbot lineage，并部署到 `/etc/5gpn/cert/{dot,web,zash}`。所有身份和证书模式修改统一进入 `5gpn configure` TUI；`CERT_MODE` 只允许 `cloudflare`、`http-01`、`debug`。
  - **cloudflare** — TUI 输入 Cloudflare API token，DNS-01 签发 apex `<base>` + `*.<base>`；签发和续期都不停止 mihomo。即使当前证书可复用，也必须保留受保护的 token 以保证自动续期；`zash.<base>` 可继续只由 5gpn 合成解析。
  - **http-01** — 签发且只签发 `console.<base>`、`zash.<base>`、`dot.<base>` 三个精确 SAN，不包含 apex 或 wildcard。TUI 会展示三条所需 A 记录并要求确认，再通过固定解析器 `1.1.1.1` 等待三个名字各自只有一条 A 且均为 `DNS_PUBLIC_IP`；三者都不得发布 AAAA。初签及到期续签会短暂停止 mihomo 释放 TCP `:80`，并在成功或失败后恢复。
  - **debug** — TUI 选择的自签模式；无 Certbot。仍有效且 SAN/IP/私钥匹配时复用，不会每次重签。
  - **安全复用**：生产复用要求有效期、可信链、cert/key 匹配，以及与模式完全一致的 SAN；debug 自签永远不能进入生产复用路径。
- **按域名访问**：`console.<base>` 必须提前有指向公网或客户端可路由网关 IP 的 A 记录；该检查没有环境变量 bypass。HTTP-01 进一步要求三个服务名都满足上述公网 A/无 AAAA 约束。SPA 资源与 iOS profile 下载公开，所有 `/api/*` 仍需 bearer token。
  The Cloudflare API token manages ACME TXT records only; the operator must create the displayed `console.<base>` A record before confirming the installer prompt.
- **统一续期入口**：systemd timer 与 Telegram bot 的确认续期动作调用同一个 mode-aware helper，只处理 `--cert-name <base>`。未到期时不打断数据面；Cloudflare 到期续签仍不停机，HTTP-01 到期续签会再次等待 `1.1.1.1` DNS 检查通过后再执行 `:80` 的短暂停机窗口。
- **IPv4 前提**：本方案全链路 **IPv4-only**（AAAA 一律 SOA、chnroute/网关改写仅 IPv4、守护进程沙箱仅 `AF_INET`）。要求 5G/APN 给客户端分配 **可路由到网关的 IPv4**（或 CLAT）；IPv6-only 接入的客户端够不到网关。

安装版本和第三方版本/摘要固定在发布包中，不接受 `DNS_VERSION`、`MIHOMO_VERSION` 或 `*_SHA256` 环境覆盖。Telegram token、管理员、代理和告警也从管理 TUI 配置。

---

## 客户端接入

- **Android**：登录 Web 控制台并打开“配置向导”，按页面提示在“私人 DNS”中填写实际 DoT 域名。
- **iOS**：登录 Web 控制台并打开“配置向导”，使用页面二维码或下载按钮安装已签名描述文件。

---

## 🖥 Web 控制台

- **地址**：`https://console.<BASE_DOMAIN>/`。SPA 公开；所有 `/api/*` 仍需 `DNS_API_TOKEN`。zashboard 单独保留来源 IP 白名单。
- **登录**：用 `DNS_API_TOKEN` 登录（浏览器 localStorage 保存）。找回：`grep DNS_API_TOKEN /etc/5gpn/dns.env`。
- **访问控制**：zashboard 的源 IP 白名单在 mihomo 层前置拦截；console API 使用 bearer token 鉴权。
- **功能**：Dashboard、iOS/Android 配置向导、解析日志、解析测试、有序统一策略规则与 fallback、上游/ECS/Telegram 设置、mihomo 健康与 ticket 化实时日志，以及经 `mihomo -t` 校验的完整 mihomo 配置编辑/显式重置。
- **zashboard 面板**：`https://zash.<BASE_DOMAIN>/`，同样经 mihomo SNI 分流 + 白名单保护到本机另一回环端口。

---

## 📱 Telegram 控制 bot

Telegram bot 是 `5gpn-dns` 守护进程内的一个 Go 组件（不是独立进程/服务），直接调用进程内 `Controller`（不经回环 `:443`、不需 token），与 Web 控制台并存。

**两种配置入口**（都走同一条校验与原子保存路径，Web 更方便）：

```bash
# 守护进程启动后：通过 TUI 输入 token/admin，调用本机 PUT /api/tgbot
sudo bash install.sh setup-tgbot
```

2) **Web 控制台**（推荐）：设置 → Telegram 机器人，填令牌 + 管理员 ID → 保存。

两种入口都由后端先调用 Telegram `getMe` 校验新令牌，再切换 bot goroutine，并把有效配置以 `0600` 原子写入 `DNS_TGBOT_FILE`（默认 `/etc/5gpn/tgbot.json`）。CLI 明确识别并更新这个有效 override；调用者环境中的 `TGBOT_*` 会被丢弃，没有 TTY 时快速失败。override 若损坏或不可读，bot 会 fail-closed 停用；`GET /api/tgbot` 永不返回令牌明文。

- **私聊与管理员门控**：`/id` 用于取得数字 user ID；状态、日志和操作菜单只接受已配置管理员的私聊，不向群组泄露网关信息。
- **inline 菜单**：状态/刷新、DNS 诊断、日志/刷新、上游、维护、iOS 安装和 Web 控制台。复杂策略排序、订阅和完整 mihomo YAML 仍只在 Web 管理。
- **危险操作有闭环**：Mihomo 重启和证书续期使用 60 秒一次性确认并进程级去重；唯一的 DNS 维护动作是进程内重载规则，不伪装成重启守护进程。
- **Telegram 原生输出**：iOS 使用 URL 按钮和 PNG 二维码；短日志保留最新故障行并按 Unicode/HTML 安全分页，超长日志作为受保护文本文件发送。
- **受限网络出站**：在 `5gpn setup-tgbot` TUI 中配置 Telegram 专用 HTTP/HTTPS CONNECT 代理；修改该启动期设置时会重启 `5gpn-dns`。5gpn 不会改写 operator-owned mihomo 配置；如使用本机 mihomo，operator 必须自行提供仅按需暴露的 HTTP/mixed listener。
- **可选状态告警**：在同一 TUI 中启用后，证书、Mihomo 和上游健康状态变化会以受保护私聊推送给所有已配置管理员（用户须先主动打开 bot 私聊）。该监视器与守护进程同生共死，主机/进程宕机仍必须依靠外部 dead-man's switch。

---

## 常用命令

安装完成后，终端直接输入 **`5gpn`** 打开交互管理菜单（状态 / 重启 / 编辑安装与证书配置 / 重载规则 / zashboard 白名单 / iOS 描述文件 / 轮换令牌 / Cloudflare token / Telegram Bot / 卸载）。也可带子命令直接执行：

```bash
5gpn                        # 打开管理菜单
5gpn status                # 服务 / 域名 / 列表 状态
5gpn restart               # 重启 5gpn-dns + 5gpn-intercept + mihomo
5gpn configure             # 打开完整配置 TUI，事务化应用并在失败时回滚
5gpn mihomo-reset          # 显式备份当前配置，以通过 mihomo -t 的最新种子原子替换
5gpn reload-rules          # 重载规则缓存与 chnroute（SIGHUP）
5gpn add-allow cidr        # 添加 zashboard 来源 IP 白名单（live 生效）
5gpn del-allow cidr        # 从 zashboard 白名单移除
5gpn ios                   # 重新生成 iOS 描述文件 + 二维码
5gpn setup-tgbot           # 校验并热应用进程内 Telegram bot 配置
5gpn rotate-token          # 轮换控制台 DNS_API_TOKEN（旧 token 立即失效 + 重启）
5gpn set-cf-token          # 在 TUI 中设置/更新 Cloudflare API token
5gpn uninstall             # TUI 确认卸载，默认保留 /etc/5gpn
5gpn uninstall --purge     # 清除非证书状态，仍保留 cert/debug-cert/acme 供复用
5gpn uninstall --decommission # 仅在 provenance 证明 5gpn 创建时删除精确 lineage，并安全处理凭据
```

Uninstall preserves the verified `/opt/5gpn/bin/gum` binary for reuse by other host automation while removing the remaining 5gpn runtime.

等价的 `sudo bash install.sh <同名子命令>` 仍可用。

配置改动：`systemctl reload 5gpn-dns`（=SIGHUP）**只重载 policy 编译结果与 chnroute**，不主动拉取远程订阅。**dns.env 里的守护进程开关（上游、网关IP、监听地址、token、cache、TTL、0x20、心跳等）在启动时读取一次，改动后需 `systemctl restart 5gpn-dns` 才生效**；证书是例外——按文件 mtime 在下次握手自动加载。

---

## 仓库结构

| 路径 | 说明 |
|---|---|
| `cmd/5gpn-dns/` | `5gpn-dns` Go 源码——DNS 引擎 + 控制面 API + bot + iOS 分发，全在一个二进制（CI 构建 → `moooyo/5gpn` release） |
| `cmd/5gpn-dns/api.go` | 控制台 HTTPS REST API + Web + iOS profile 下载（回环 `:443`，基于 `Controller` facade，经 mihomo SNI 分流对外暴露） |
| `cmd/5gpn-dns/bot.go` `bot_ops.go` | 进程内 Telegram bot |
| `cmd/5gpn-dns/iosd.go` | iOS 描述文件分发（公开 `/ios/ios-dot.mobileconfig`，`/ios/` 跳转到控制台向导） |
| `web/` | React 控制台前端（独立构建；`npm run build` → `web/dist`，打包成 `5gpn-web-*.tar.gz` release asset；daemon 从 `DNS_WEB_DIR`=/opt/5gpn/web 磁盘 serve） |
| `install.sh` / `quick-install.sh` | 安装 / 重装编排 + 运维子命令 |
| `etc/` | 规则种子、`5gpn-dns/dns.env.example`、mihomo 配置模板、systemd 单元 |
| `scripts/` | iOS profile 生成、mode-aware 证书续期 helper/部署 hook、`reload-rules.sh` |
| `tests/` | Go 单测 `cmd/5gpn-dns/*_test.go` + shell policy 测试 + 集成冒烟清单 |

---

## 构建与发布

- `5gpn-dns` **在 CI 构建**（网关上不放 Go 工具链）：`release.yml` 先 `npm run build` 前端 → `go build`（`-X main.version` 打版本号）→ 发布 `5gpn-dns-linux-amd64` + `5gpn-web-<ver>.tar.gz`（前端 SPA）+ **`5gpn-installer.tar.gz`（install.sh + 配置模板 + 脚本，`DNS_VERSION_DEFAULT` 已 stamp 到本 tag）** + `checksums.txt`。
- CI（`ci.yml`）：`go vet` + `go test -race`、前端 build+typecheck、shell policy 测试（含 mihomo 配置模板的 grep 断言）。
- **Release channels**: official `X.Y.Z` tags must be reachable from `main` and
  publish normal latest-eligible releases. Beta `X.Y.Z-beta.N` tags must be
  reachable from `beta` and publish prereleases with `make_latest=false`. Both
  channels run the shared checks gate, stamp `DNS_VERSION_DEFAULT` to the exact
  tag, and publish the matching installer, daemon, Web, checksum, and optional
  tagged-tree first-party assets. The quick installer verifies the bundle from
  that exact tag and never falls back to branch content or the other channel.

---

## 文档

- 行为验收（在 Linux 网关上执行）：[tests/integration-smoke.md](tests/integration-smoke.md)
