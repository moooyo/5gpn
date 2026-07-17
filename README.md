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
  mihomo (gateway tunnel 监听 TCP 80 / TCP+UDP 443)  客户端直连 / 不发起连接
  · SNI == console → DIRECT 回环（API bearer）；SNI == zashboard →
    源 IP 命中 whitelist.txt 才 DIRECT，否则 REJECT-DROP
  · 其余 SNI/QUIC → mihomo 内置嗅探器（sniffer）取域名，经 5gpn-dns 的回环 Egress DNS
    Broker (127.0.0.1:5354) re-resolves through DNS_EGRESS_RESOLVER
    (operational default: plain-UDP 22.22.22.22)
        │
        ▼
  按运维者的 mihomo 配置选择应用层出口（默认 DIRECT）→ 互联网
```

**一个主域名、一条证书 lineage**：`BASE_DOMAIN` 自动派生 `console.<base>`、`zash.<base>` 和 `dot.<base>`。Cloudflare 模式签发 apex + `*.<base>`，HTTP-01 模式则只签发这三个服务名的精确 SAN；两种生产模式都固定使用 `--cert-name <base>` 的同一条 scoped lineage。`console.<base>` 提供 SPA 与公开的 iOS profile 下载，所有 `/api/*` 仍强制 bearer token；`zash.<base>` 继续由 mihomo 来源白名单保护。

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

- **确定性 chnroute 仲裁**：并发查国内 UDP（`223.5.5.5`/`119.29.29.29`）和可信 DoT（`8.8.8.8`/`1.1.1.1`），**按 chnroute 成员关系判定，不看谁先回**（非竞速）。
- **DoT-only 入口**：唯一的客户端 DNS 传输是 DoT `:853`；不提供 DoH 或客户端明文 `:53`。另有一个仅回环的 `127.0.0.1:5353` 明文调试监听，仅用于本机排障。
- **全查询类型**：A → 仲裁+改写；AAAA → SOA（IPv4-only）；HTTPS/SVCB → 空 NOERROR（保 SNI 嗅探）；其余 → 转发可信 DoT。
- **有序统一策略**：`/etc/5gpn/policy.json` 中每条规则以 exact/suffix/keyword/subscription 匹配一种 block/direct/proxy 意图，跨意图按全局顺序 first-match；未命中项可选 auto/direct/gateway fallback。系统 chnroute 与编译后的策略订阅由进程内抓取器定时更新，域名列表支持 `plain`/`gfwlist`/`dnsmasq`/`hosts`，chnroute 使用 `cidr`；失败保留旧缓存（离线安全）。
- **统一控制面**（多前端共用同一内存 `Controller`）：
  - **HTTPS REST API + React Web 控制台 + iOS 描述文件**：console SPA 资源与 profile 下载公开，所有 API 需 bearer token；iOS/Android 配置说明、二维码与下载入口统一位于控制台“配置向导”；zashboard 仍由 mihomo `whitelist.txt` 来源白名单保护。
  - **zashboard 面板**：同样经 mihomo SNI 分流 + 白名单暴露到本机另一回环端口。
  - **进程内 Telegram bot**（`github.com/go-telegram/bot`，管理员门控，直接调 `Controller`、不走 HTTP/token）。
  - **Mihomo controller TLS**：zash 证书角色由 zashboard 与 mihomo controller 共用。`DNS_MIHOMO_CONTROLLER` 是回环拨号地址；客户端以派生的 `zash.<base>` 校验 TLS 身份并信任 `DNS_ZASH_CERT`。Mihomo v1.19.28 通过只读 `SAFE_PATHS=/etc/5gpn/cert/zash` 读取位于 `-d /etc/5gpn/mihomo` 外的证书。普通重装逐字节保留已通过校验的 operator-owned 配置；若 verified controller transport 无法构造，DNS 与其余控制面继续运行，Mihomo 健康、配置和代理端点返回 unavailable/503，绝不降级到明文 HTTP。
- **出口由 mihomo 原生配置拥有**：被代理流量经 mihomo 的 `tunnel` 监听 + 内置嗅探器透明转发（不解密 TLS）；完整 `/etc/5gpn/mihomo/config.yaml` 由运维者管理，默认 `Proxies` 组只有 `DIRECT`，也可加入 mihomo 支持的应用层节点/组。DNS 策略只决定“是否进入网关”，绝不生成 mihomo 出口。仍禁止 TUN/TProxy、WireGuard、fwmark、策略路由表或把本项目变成客户端默认路由器。
- **无宿主防火墙**：项目不管理宿主 nftables；zashboard 的网络访问控制由 mihomo 来源白名单承担，console API 依赖 bearer 鉴权。
- **Operational lifecycle**: successful renewal atomically deploys all certificate roles, re-signs the iOS profile, then restarts `mihomo` followed by `5gpn-dns`. HTTP-01 additionally stops mihomo only for its bounded ACME `:80` challenge window. `kill -HUP` remains rules-only and is never a certificate activation API.
- **零 Python、极小依赖**：Go 侧只依赖 `miekg/dns` + `go-telegram/bot`；第三方工具（mihomo、gum）用预编译二进制，网关上不放工具链。

---

## 安装

在一台 root 权限的 Linux 网关上：

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
# 或在 checkout 内：sudo bash install.sh
```

> First installation requires the TUI. It collects the certificate mode, base domain, certificate email, and Cloudflare token when selected. `PUBLIC_IP` is detected automatically; the gateway and listener default to it. `5gpn configure` retains advanced public/gateway/listener overrides for special network layouts. The egress resolver defaults to `22.22.22.22`, ECS starts disabled for later WebUI configuration, and cache size is selected from the memory profile. Caller environment variables never override configuration; a first install without a TTY fails closed, while reinstall can reuse a valid `dns.env` non-interactively.

安装器会先把固定版本的 5gpn-dns、Web、mihomo、zashboard 下载到 staging 并强制校验 SHA-256，再备份当前部署、原子发布并执行 readiness 探针；发布后失败会自动回滚。生产证书可选 Cloudflare DNS-01 或 HTTP-01，debug 模式使用隔离的自签证书。

**内网部署**（客户端在内网，如 `172.22.0.0/16`，经内网直达网关、不经公网）——这是本项目的主力场景：

运行 `sudo bash install.sh`，在 TUI 的“客户端可达网关 IPv4”中填写内网地址；证书模式也在同一向导选择。`console.`、`zash.`、`dot.` 三个域名自动从主域名派生。

- **配置只有一个持久入口**：安装器配置由 TUI 写入 `/etc/5gpn/dns.env`；重装只读该文件，明确忽略调用者环境。仅 Cloudflare 模式需要的 API token 单独保存在 root-only 的 `/etc/5gpn/acme/cloudflare.ini`，不会进入 `dns.env`、调用者环境或日志。
- **重跑刷新程序、保留运维配置**：每次运行安装脚本都会刷新 systemd 单元、`/opt/5gpn` 运行目录以及 pin 版本的 5gpn-dns/mihomo/Web 产物；`/etc/5gpn` 和 `/etc/letsencrypt` 持久保留。已有且通过 `mihomo -t` 的完整 mihomo 配置会逐字节保留；只有显式 `mihomo-reset` 才会在备份和校验后替换它。下载或校验失败会中止且不预删工作二进制。
- **一个主域名、一条 lineage、三个证书角色目录**：两种生产模式都只使用 cert-name 为 `<base>` 的**一条** scoped Certbot lineage，并部署到 `/etc/5gpn/cert/{dot,web,zash}`。所有身份和证书模式修改统一进入 `5gpn configure` TUI；`CERT_MODE` 只允许 `cloudflare`、`http-01`、`debug`。
  - **cloudflare** — The TUI stores a protected Cloudflare API token and DNS-01 issues apex `<base>` plus `*.<base>`. ACME validation does not release mihomo's `:80` listener, but successful renewal still performs the common mihomo/5gpn-dns restarts. The token remains required for unattended renewal even when the current certificate is reusable; `zash.<base>` may remain synthetic-only.
  - **http-01** — Issuance covers exactly `console.<base>`, `zash.<base>`, and `dot.<base>`, with no apex or wildcard SAN. The TUI confirms all three A records, and `1.1.1.1` must observe exactly `DNS_PUBLIC_IP` with no AAAA. Initial issuance and due renewal briefly stop mihomo for TCP `:80`; failure restores its prior state, while successful renewal continues into the common ordered service restarts.
  - **debug** — TUI 选择的自签模式；无 Certbot。仍有效且 SAN/IP/私钥匹配时复用，不会每次重签。
  - **Safe reuse**: first install, reinstall, and `configure` reuse every currently valid certificate whose trust, cert/key pair, exact SAN set, mode, renewal metadata, and provenance checks pass. Near-expiry alone never triggers installer issuance; the daily renewal helper owns the three-day rotation window.
- **按域名访问**：`console.<base>` 必须提前有指向公网或客户端可路由网关 IP 的 A 记录；该检查没有环境变量 bypass。HTTP-01 进一步要求三个服务名都满足上述公网 A/无 AAAA 约束。SPA 资源与 iOS profile 下载公开，所有 `/api/*` 仍需 bearer token。
  The Cloudflare API token manages ACME TXT records only; the operator must create the displayed `console.<base>` A record before confirming the installer prompt.
- **Unified renewal entrypoint**: the systemd timer and confirmed Telegram action call the same mode-aware helper for only `--cert-name <base>`. More than three days before expiry it does not invoke Certbot or restart services. Successful Cloudflare or HTTP-01 renewal restarts mihomo and 5gpn-dns; HTTP-01 first repeats the `1.1.1.1` gate and its bounded `:80` handoff.
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
5gpn restart               # 重启 5gpn-dns + mihomo
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

Configuration lifecycle: `systemctl reload 5gpn-dns` (`SIGHUP`) reloads only compiled policy results and chnroute; it does not fetch remote subscriptions. Daemon settings from `dns.env` are read at startup and require `systemctl restart 5gpn-dns`. Certificate renewal uses the deploy hook's explicit ordered restart of `mihomo` and `5gpn-dns`.

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
- **发布**：release 流程把唯一的 `DNS_VERSION_DEFAULT` 固定为当前 tag。quick installer 先解析 latest tag，只接受该 tag 的 bundle，强制核对 `checksums.txt`；bundle 缺失时也只 checkout 同一 tag，绝不回退 `main`。5gpn-dns、Web、mihomo 与 zashboard 均在 staging 校验摘要后发布。

---

## 文档

- 行为验收（在 Linux 网关上执行）：[tests/integration-smoke.md](tests/integration-smoke.md)
