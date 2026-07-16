# 5gpn

**基于自研 Go 守护进程 `5gpn-dns` 的中国线路 DNS/SNI 网关。** 核心是"**解析即策略**"——用 DNS 解析结果决定一条流量由客户端直连还是先进入网关：代理意图域名被解析成网关自己的 IP，自然漏斗进网关上的 **mihomo**；直连意图域名返回真实 IP，客户端直接连接、网关不经手。mihomo 的后续出口由运维者拥有的完整配置决定（默认种子为 `DIRECT`，也可配置应用层代理节点/组）。客户端通过 **DoT** 接入（DoT 是唯一的 DNS 接入方式），**无需装任何 App**。

> 仅用于已获合法授权的企业组网与技术研究，请遵守所在地法律法规。

---

## 工作原理

```
客户端 (Android 私人 DNS / iOS 描述文件)
        │  DoT :853   (TLS，*.<base 域名> 的 Let's Encrypt 通配符证书)   —— 唯一 DNS 传输
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
│               console/zash 需白名单，profile 仅公开 /ios/)、 │
│              zashboard 面板、Telegram bot                    │
└────────────────────────────────────────────────────────────┘
        │ 境外 → 网关 IP                    │ 国内 → 真实 IP / 封锁 → NXDOMAIN
        ▼                                    ▼
  mihomo (sniproxy tunnel 监听 TCP 80 / TCP+UDP 443)  客户端直连 / 不发起连接
  · SNI == 控制台/zashboard 域名 → 源 IP 命中 whitelist.txt 白名单则 DIRECT 回环
    (控制台 :443 / zashboard 另一回环端口)，否则 REJECT-DROP
  · 其余 SNI/QUIC → mihomo 内置嗅探器（sniffer）取域名，经 5gpn-dns 的回环 Egress DNS
    Broker (127.0.0.1:5354) 重解析，DNS_EGRESS_RESOLVER 兜底（默认 22.22.22.22 占位，
    需设成真实解析器）
        │
        ▼
  按运维者的 mihomo 配置选择应用层出口（默认 DIRECT）→ 互联网
```

**一个主域名、一张通配符证书**：`BASE_DOMAIN`（如 `example.com`）自动派生四个子域名——`console.<base>`（Web 控制台）、`zash.<base>`（zashboard）、`profile.<base>`（公开的 iOS 首次安装入口）和 `dot.<base>`（DoT `:853`）——全部由同一张 `*.<base>` Let's Encrypt 通配符证书（Cloudflare DNS-01 签发，自动续期）覆盖。`console.<base>`/`zash.<base>` 只由 5gpn-dns 为已接入客户端解析到 `GATEWAY_IP`，并由 mihomo 源 IP 白名单保护；`profile.<base>` 必须在首次接入前已有客户端可解析、可达的 A 记录，但它在守护进程中按 TLS SNI 隔离，**只提供 `/ios/`，无法访问 SPA、API 或 mihomo proxy**。

| 场景 | DNS 行为 | 数据路径 |
|---|---|---|
| 命中 block | NXDOMAIN | 客户端不发起连接 |
| 命中 proxy（强制进入网关） | 直接返回网关 IP | 客户端 → mihomo → 运维者配置的出口 |
| 仲裁后国外 IP | 改写为网关 IP | 客户端 → mihomo → 运维者配置的出口 |
| 仲裁后国内 IP | 原样返回真实 IP | 客户端直连，网关不经手 |
| SNI = 控制台/zashboard 域名（源 IP 在白名单） | —— | 客户端 → mihomo :443 → SNI 分流 → 回环 :443 |
| SNI = profile 域名 | —— | 公开到回环 :443，但服务端只允许 `/ios/` |

---

## 关键特性

- **确定性 chnroute 仲裁**：并发查国内 UDP（`223.5.5.5`/`119.29.29.29`）和可信 DoT（`8.8.8.8`/`1.1.1.1`），**按 chnroute 成员关系判定，不看谁先回**（非竞速）。这是 smartdns 做不到、当初自研的根本原因。
- **DoT-only 入口**：唯一的客户端 DNS 传输是 DoT `:853`（DoH 与明文 `:53` 已移除）。另有一个仅回环的 `127.0.0.1:5353` 明文调试监听，仅用于本机排障。
- **全查询类型**：A → 仲裁+改写；AAAA → SOA（IPv4-only）；HTTPS/SVCB → 空 NOERROR（保 SNI 嗅探）；其余 → 转发可信 DoT。
- **有序统一策略**：`/etc/5gpn/policy.json` 中每条规则以 exact/suffix/keyword/subscription 匹配一种 block/direct/proxy 意图，跨意图按全局顺序 first-match；未命中项可选 auto/direct/gateway fallback。系统 chnroute 与编译后的策略订阅由进程内抓取器定时更新，支持 `plain`/`gfwlist`/`dnsmasq`/`adblock`/`hosts`/`cidr`，失败保留旧缓存（离线安全）。
- **统一控制面**（多前端共用同一内存 `Controller`）：
  - **HTTPS REST API + React Web 控制台 + iOS 描述文件**（同一回环 `:443` 监听，经 mihomo `:443` 的 SNI 分流对外暴露）。API 需 bearer token；来源 IP 先过 mihomo 的 `whitelist.txt` 面板白名单（TUI 管理），未放行的来源直接被 mihomo `REJECT-DROP`，连接根本到不了控制台监听端口。
  - **zashboard 面板**：同样经 mihomo SNI 分流 + 白名单暴露到本机另一回环端口。
  - **进程内 Telegram bot**（`github.com/go-telegram/bot`，管理员门控，直接调 `Controller`、不走 HTTP/token）。
  - **Mihomo controller TLS**: the zash wildcard certificate role is shared by the zashboard panel and the mihomo controller. `DNS_MIHOMO_CONTROLLER` remains the loopback dial target; verified controller clients use `DNS_ZASH_DOMAIN` for TLS identity and trust `DNS_ZASH_CERT`. Mihomo v1.19.28 also needs `SAFE_PATHS=/etc/5gpn/cert/zash` because the shared controller cert lives outside `-d /etc/5gpn/mihomo`; that allowlist is read-only and does not widen writes or relax `ProtectSystem=strict`. Ordinary reinstall/change-* preserve an existing operator-owned mihomo config byte-for-byte and do not migrate it; older installs need `DNS_ZASH_DOMAIN` plus either `mihomo-reset` or a manual TLS-only edit before verified controller clients can connect, otherwise they fail closed. If the verified controller transport/client cannot be built, DNS and the rest of the control plane keep running while Mihomo health/config/proxy endpoints stay unavailable (503) rather than downgrading to plaintext HTTP.
- **出口由 mihomo 原生配置拥有**：被代理流量经 mihomo 的 `tunnel` 监听 + 内置嗅探器透明转发（不解密 TLS）；完整 `/etc/5gpn/mihomo/config.yaml` 由运维者管理，默认 `Proxies` 组只有 `DIRECT`，也可加入 mihomo 支持的应用层节点/组。DNS 策略只决定“是否进入网关”，绝不生成 mihomo 出口。仍禁止 TUN/TProxy、WireGuard、fwmark、策略路由表或把本项目变成客户端默认路由器。
- **无宿主防火墙**：项目**不再管理宿主 nftables 防火墙**（`setup-firewall.sh` 已删除）。若需网络层过滤，用你的云安全组；控制台/zashboard 面板的访问控制改由 mihomo 的源 IP 白名单（`whitelist.txt`）承担（见上）。
- **运维友好**：证书按文件 mtime 热重载（续期后下次 TLS 握手自动加载，无需重启；`kill -HUP` 只重载规则、与证书无关）；统计持久化存活重启；systemd 硬化沙箱，bot 特权操作经 `systemd-run`/`systemctl` 委派而不削弱沙箱。
- **零 Python、极小依赖**：Go 侧只依赖 `miekg/dns` + `go-telegram/bot`；第三方工具（mihomo、gum）用预编译二进制，网关上不放工具链。

---

## 安装

在一台 root 权限的 Linux 网关上：

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
# 或在 checkout 内：sudo bash install.sh
```

> 上面的 `curl | sudo bash` 一键安装**仍会交互提问**（主域名 `BASE_DOMAIN` / 网关IP）：脚本检测到管道会自动把输入接回当前终端（`/dev/tty`）。`console.<base>` / `zash.<base>` / `profile.<base>` / `dot.<base>` 四个子域名从 `BASE_DOMAIN` 自动派生，无需分别填写。**SNI 回源解析器不再在安装时询问**——默认用占位 `22.22.22.22`，装完后用 `5gpn change-resolver <解析器>`（或菜单）设成真实解析器。若在无终端环境（cloud-init / CI / systemd）运行，则回退为非交互，需用下面的环境变量预置（`BASE_DOMAIN=` 等；无公网域名用 `DEBUG=1` 自签）。

安装器会：下载预编译 **Gum**（sha256 校验，缺失回退 plain echo）、下载 CI 构建的 **5gpn-dns** 与预编译 **mihomo**、为主域名签发一张 `*.<base>` 通配符 Let's Encrypt 证书（Cloudflare DNS-01，自动续期）、生成 iOS DoT 描述文件 + 二维码、拉起 systemd 服务。结束时打印控制台/zashboard 地址与 token。安装时会**自动探测公网 IP**（可用 `PUBLIC_IP=` 覆盖，或装完后用 `5gpn change-public-ip <ip>` 修改）。

**内网部署**（客户端在内网，如 `172.22.0.0/16`，经内网直达网关、不经公网）——这是本项目的主力场景：

```bash
# 域名安装时只会交互式询问一个主域名 BASE_DOMAIN；console./zash./profile./dot. 四个子域名
# 自动派生，无需分别填写。网关IP 也会询问（默认=探测到的 PUBLIC_IP，回车即用公网IP）；
# 内网部署时填客户端实际可达的网关内网地址。均可用 env 预先指定（跳过询问），或装完后
# 随时用 5gpn 子命令修改。
export BASE_DOMAIN=example.com         # 主域名（非 debug 必填）；派生 console./zash./profile./dot.<base>
export GATEWAY_IP=<网关内网地址>        # 可选：客户端实际访问的地址，写进 iOS 描述文件
# 证书：默认 CERT_MODE=cloudflare（*.<base> 通配符，Cloudflare DNS-01，无需 :80，自动续签，
# 首次签发时安装器自动提示输入 Cloudflare API token；无人值守用 CF_API_TOKEN= 预置，
# 或装完后随时用 5gpn --set-cf-token 更新，均可选）；测试/无公网入站可用 DEBUG=1 自签
# export DEBUG=1                       # 自签证书（客户端不信任，仅测试用）
sudo bash install.sh
```

- **配置只有一个文件**：`/etc/5gpn/dns.env` 是唯一真源。每个开关按 `环境变量 > dns.env 现值 > 默认` 解析，然后写回 `dns.env`；裸重跑沿用其中的值。没有一堆 `.xxx` 状态文件。
- **重跑刷新程序、保留运维配置**：每次运行安装脚本都会刷新 systemd 单元、`/opt/5gpn` 运行目录以及 pin 版本的 5gpn-dns/mihomo/Web 产物，避免二进制与模板错配；`/etc/5gpn` 和 `/etc/letsencrypt` 持久保留。已有且通过 `mihomo -t` 的完整 mihomo 配置会逐字节保留，普通安装和 `change-*` 不会用模板覆盖，也不会自动迁移到 TLS-only controller 模式；老安装要先补 `DNS_ZASH_DOMAIN`，再显式跑 `mihomo-reset` 或手工改成 TLS-only，verified Controller clients 才会放行。Until that migration happens, the Mihomo TLS integration fails closed/unavailable while DNS startup continues. 下载或校验失败会中止且不预删工作二进制。
- **一个主域名、一张通配符证书、三个证书角色目录**：`BASE_DOMAIN` 只有**一条** certbot lineage、**一张** `*.<base>` 通配符证书，部署到 `/etc/5gpn/cert/{dot,web,zash}`（profile 与 console 共用 web 监听/证书）。菜单里 `5gpn change-base-domain <d>` 一次性重签通配符证书并重新派生四个子域名。
  - `CERT_MODE=cloudflare`（默认）— 真 Let's Encrypt 通配符证书，走 **DNS-01**（Cloudflare API 写 `_acme-challenge` TXT 记录），**不占用 :80、不需要停 mihomo**，也不需要 `console.<base>`/`zash.<base>`/`dot.<base>` 有公网 A 记录；自动续签（每日 `5gpn-certbot-renew.timer`）。**首次签发时安装器自动提示输入** Cloudflare API token（作用域：Zone:DNS:Edit）；token 存于 `/etc/5gpn/acme/cloudflare.ini`（目录 0700、文件 0600，仅 root 可读），**不**写入 `dns.env` 也不记日志。无人值守/CI 安装用 `CF_API_TOKEN=<token>` 环境变量预置（与 `CLOUDFLARE_API_TOKEN` 等价）；已有有效 token 的复用安装不会再次提示。也可在装完后随时用 `5gpn --set-cf-token` 更新。
  - `CERT_MODE=debug`（或 `DEBUG=1`）— 自签通配符证书，测试/开发用，无 certbot、无 DNS-01、无续签；客户端会提示不受信任。**除 debug 外，安装一定需要主域名。**
  - **证书复用**：卸载**不清理**证书目录；安装/换域名时若检测到已存在有效通配符证书（certbot lineage `>30d`，或保留的 `/etc/5gpn/cert` 副本 `>7d` 且 SAN 匹配），则**复用而不重签**，避免 LE 的按域名签发限流。
- **按域名访问**：`console.<base>`/`zash.<base>` 可只由 5gpn-dns 为已接入客户端解析到 `GATEWAY_IP`；首次安装用的 `profile.<base>` 必须提前有指向 `PUBLIC_IP`（或客户端可路由 `GATEWAY_IP`）的 A 记录，且服务端只允许 `/ios/`。安装器默认对此 fail-closed；`SKIP_PROFILE_DNS_CHECK=1` 只供 CI/明确的分阶段部署使用。iOS 描述文件内置服务器 IP，`dot.<base>` 主要用于 TLS SNI/证书校验；Android 私人 DNS 按域名引导时仍要求 `dot.<base>` 可由系统 DNS 解析到可达地址。
- **IPv4 前提**：本方案全链路 **IPv4-only**（AAAA 一律 SOA、chnroute/网关改写仅 IPv4、守护进程沙箱仅 `AF_INET`）。要求 5G/APN 给客户端分配 **可路由到网关的 IPv4**（或 CLAT）；IPv6-only 接入的客户端够不到网关。

**常用环境变量覆盖**（全部持久化到 `dns.env`，但 `CF_API_TOKEN` 例外）：`BASE_DOMAIN=`（非 debug 必填；派生 `console./zash./profile./dot.<base>`） `DEBUG=1`（=`CERT_MODE=debug` 自签） `CERT_MODE=cloudflare|debug` `CERT_EMAIL=`(=`EMAIL=`) `CF_API_TOKEN=`（或 `CLOUDFLARE_API_TOKEN=`）— 无人值守/CI 安装时预置的 Cloudflare API token（作用域 Zone:DNS:Edit；被复制到 `/etc/5gpn/acme/cloudflare.ini`（0600），**不**持久化到 `dns.env` 或日志；交互安装在首次签发时自动提示，**无需**预设此变量） `PUBLIC_IP=`（不设则自动探测） `GATEWAY_IP=` `MIHOMO_LISTEN_IPS=`（mihomo 实际绑定的本机 IPv4 列表） `DNS_CHINA_0X20=1|0` `DNS_HEARTBEAT_URL=` `LOWMEM=1|0` `CACHE_SIZE=` `DNS_VERSION=` `DNS_SHA256=` `MIHOMO_VERSION=` `MIHOMO_SHA256=` `DNS_EGRESS_RESOLVER=`（默认 `22.22.22.22` 仅为不可用占位，需设真实 UDP IPv4 或 DoH） `DNS_WEB_DIR=` `TGBOT_TOKEN=` `TGBOT_ADMINS=` `DNS_API_TOKEN=`。

---

## 客户端接入

- **Android**：设置 → 私人 DNS → 填 DoT 域名（`dot.<BASE_DOMAIN>`）。
- **iOS**：安装 DoT 描述文件（扫安装结束打印的二维码，或访问 `https://profile.<BASE_DOMAIN>/ios/ios-dot.mobileconfig`）。该 host 公开但只暴露 `/ios/`；iOS 安装后只走 DoT。

---

## 🖥 Web 控制台

- **地址**：`https://console.<BASE_DOMAIN>/`（安装结束打印一次）。浏览器走标准 443，由 mihomo 的 SNI 分流转到本机回环 `:443`——前提是浏览器所在源 IP 在 `whitelist.txt` 面板白名单里（`5gpn --add-allow <cidr>` 添加），否则连接被 mihomo `REJECT-DROP`，根本到不了控制台。
- **登录**：用 `DNS_API_TOKEN` 登录（浏览器 localStorage 保存）。找回：`grep DNS_API_TOKEN /etc/5gpn/dns.env`。
- **访问控制**：源 IP 白名单在 mihomo 层前置拦截（见上，取代了旧版的进程内 token 失败封锁）；token 本身仍是 bearer 鉴权。
- **功能**：Dashboard、解析日志、解析测试、有序统一策略规则与 fallback、上游/ECS/Telegram 设置、mihomo 健康与 ticket 化实时日志，以及经 `mihomo -t` 校验的完整 mihomo 配置编辑/显式重置。
- **zashboard 面板**：`https://zash.<BASE_DOMAIN>/`，同样经 mihomo SNI 分流 + 白名单保护到本机另一回环端口。

---

## 📱 Telegram 控制 bot

Telegram bot 是 `5gpn-dns` 守护进程内的一个 Go 组件（不是独立进程/服务），直接调用进程内 `Controller`（不经回环 `:443`、不需 token），与 Web 控制台并存。

**两种配置方式**（任选其一，Web 优先）：

```bash
# 1) 安装时：写 TGBOT_TOKEN/TGBOT_ADMINS 到 dns.env 并重启守护
sudo bash install.sh --setup-tgbot
```

2) **Web 控制台**（推荐，运行时热切换）：设置 → Telegram 机器人，填令牌 + 管理员 ID → 保存。后端 `PUT /api/tgbot` 会先向 Telegram 校验令牌（getMe），只**热重启 bot goroutine**（守护进程持续解析 DNS，无需整体重启），并写入 `/etc/5gpn/tgbot.json`——该文件在启动时**覆盖** dns.env 的 `TGBOT_TOKEN/TGBOT_ADMINS`（与 `upstreams.json` 同一套「web 覆盖只读 dns.env」机制；令牌 0600 存储，`GET /api/tgbot` 从不回传明文令牌）。留空令牌只改管理员；清空令牌即停用 bot。

- **管理员门控**：只有 `TGBOT_ADMINS` 里的数字 ID 能操作；`/id` 自助取自己的 ID。
- **inline 键盘菜单**：状态、强制代理域名增删、刷新订阅、重载规则、重启服务、日志、续证书、iOS 二维码。
- **特权操作走 systemd**：mihomo 用 `systemctl restart`；"重启 5gpn-dns" 实为进程内热重载（避免自杀）；续证书用 `systemd-run certbot`（逃逸沙箱，Cloudflare DNS-01 无需停 mihomo 让出 :80），**不削弱守护进程的硬化沙箱**。

---

## 常用命令

安装完成后，终端直接输入 **`5gpn`** 打开交互管理菜单（状态 / 重启 / 改主域名 / 改公网IP / 改网关IP / 改回源解析器 / 更新规则 / 面板白名单 / iOS 描述文件 / 轮换令牌 / Cloudflare token / Telegram Bot / 卸载）。也可带子命令直接执行：

```bash
5gpn                        # 打开管理菜单
5gpn --status              # 服务 / 域名 / 列表 状态
5gpn restart               # 重启 5gpn-dns + mihomo
5gpn change-base-domain d  # 换主域名（重签 *.<d> 通配符证书 + 重新派生 console./zash./dot. + 重启）
5gpn change-public-ip ip   # 换公网 IP（持久化；保留 operator-owned mihomo 配置并提示人工复核）
5gpn change-resolver r     # 设置回环 Egress DNS Broker 的兜底 SNI 重解析器（明文 IPv4 或 https://…/dns-query DoH）+ 重启 5gpn-dns
5gpn change-gateway ip     # 换客户端可达网关IP（重生成 iOS；mihomo 地址/防环需复核或显式 reset）
5gpn mihomo-reset          # 显式备份当前配置，以通过 mihomo -t 的最新种子原子替换
5gpn --update-lists        # 触发规则缓存 reload（SIGHUP）
5gpn --add-domain d        # 强制代理某域名（加入 blacklist）
5gpn --del-domain d        # 取消强制代理
5gpn --add-allow cidr      # 添加控制台/zashboard 面板源 IP 白名单（whitelist.txt，live 生效）
5gpn --del-allow cidr      # 从面板白名单移除
5gpn --ios                 # 重新生成 iOS 描述文件 + 二维码
5gpn --setup-tgbot         # 启用进程内 Telegram bot
5gpn --rotate-token        # 轮换控制台 DNS_API_TOKEN（旧 token 立即失效 + 重启）
5gpn --set-cf-token t      # 设置/更新 Cloudflare API token（证书 DNS-01 签发用）
5gpn --uninstall           # 卸载（默认保留 /etc/5gpn；--purge 删除其余但仍保留 cert/ 与 acme/，证书与 Cloudflare token 始终留存以便复用，避免 LE 签发限流）
```

（等价的 `sudo bash install.sh <同名子命令>` 仍可用；`change-web-domain` / `change-dot-domain` / `change-domain` 都是 `change-base-domain` 的过渡期废弃别名。）

配置改动：`systemctl reload 5gpn-dns`（=SIGHUP）**只热重载 `/etc/5gpn/rules/` 下的规则文件 + chnroute**（订阅 / 手动规则更新走同一路径，不重启）。**dns.env 里的守护进程开关（上游、网关IP、监听地址、token、cache、TTL、0x20、心跳等）在启动时读取一次，改动后需 `systemctl restart 5gpn-dns` 才生效**；证书是例外——按文件 mtime 在下次握手自动加载。

---

## 仓库结构

| 路径 | 说明 |
|---|---|
| `cmd/5gpn-dns/` | `5gpn-dns` Go 源码——DNS 引擎 + 控制面 API + bot + iOS 分发，全在一个二进制（CI 构建 → `moooyo/5gpn` release） |
| `cmd/5gpn-dns/api.go` | 控制台 HTTPS REST API + Web + `/ios/`（回环 `:443`，基于 `Controller` facade，经 mihomo SNI 分流对外暴露） |
| `cmd/5gpn-dns/bot.go` `bot_ops.go` | 进程内 Telegram bot |
| `cmd/5gpn-dns/iosd.go` | iOS 描述文件分发（控制台 `/ios/` 公开路径） |
| `web/` | React 控制台前端（独立构建；`npm run build` → `web/dist`，打包成 `5gpn-web-*.tar.gz` release asset；daemon 从 `DNS_WEB_DIR`=/opt/5gpn/web 磁盘 serve） |
| `install.sh` / `quick-install.sh` | 安装 / 升级编排 + 运维子命令 |
| `etc/` | 规则种子、`5gpn-dns/dns.env.example`、mihomo 配置模板、systemd 单元 |
| `scripts/` | iOS profile 生成、证书续期 hook、`update-lists.sh` |
| `tests/` | Go 单测 `cmd/5gpn-dns/*_test.go` + shell policy 测试 + 集成冒烟清单 |

---

## 构建与发布

- `5gpn-dns` **在 CI 构建**（网关上不放 Go 工具链）：`release.yml` 先 `npm run build` 前端 → `go build`（`-X main.version` 打版本号）→ 发布 `5gpn-dns-linux-amd64` + `5gpn-web-<ver>.tar.gz`（前端 SPA）+ **`5gpn-installer.tar.gz`（install.sh + 配置模板 + 脚本，`DNS_VERSION_DEFAULT` 已 stamp 到本 tag）** + `checksums.txt`。
- CI（`ci.yml`）：`go vet` + `go test -race`、前端 build+typecheck、shell policy 测试（含 mihomo 配置模板的 grep 断言）。
- **发布**：`install.sh` 默认 `DNS_VERSION=dns-v0.4.0`；网关上**只从 release 下载预编译产物**（二进制/SPA/mihomo/gum），从不现场编译。`quick-install.sh` 下载与二进制**同一 release** 的 `5gpn-installer.tar.gz` 取得 install.sh + 配置模板（不再 clone `main`），二进制与配置永远版本一致，杜绝「release 二进制 vs 工作树配置」漂移（曾导致 `:443` webui 故障的根因）。

---

## 文档

- 行为验收（在 Linux 网关上执行）：[tests/integration-smoke.md](tests/integration-smoke.md)
