# 5gpn

**基于自研 Go 守护进程 `5gpn-dns` 的"直出型"中国线路 DNS/SNI 网关。** 核心是"**解析即策略**"——用 DNS 解析结果直接决定一条流量走直连还是走网关：境外/被墙域名被解析成网关自己的 IP，自然漏斗进网关上的 sing-box 透明转发后**直出**；境内域名返回真实 IP，客户端直连、网关不经手。客户端通过 DoT / DoH / 明文 DNS 接入，**无需装任何 App**。

> 仅用于已获合法授权的企业组网与技术研究，请遵守所在地法律法规。

---

## 工作原理

```
客户端 (Android 私人 DNS / iOS 描述文件 / DoH)
        │  DoT :853   (TLS，Let's Encrypt 证书)
        │  DoH :8443  (HTTPS /dns-query)
        │  明文 :53   (UDP+TCP，per-source 限速)
        ▼
┌────────────────────────────────────────────────────────────┐
│ 5gpn-dns —— 一个 Go 二进制，一个进程                         │
│   ① adblock 域名      → NXDOMAIN（广告拦截）                 │
│   ② force-direct 白名单 → 真实 IP（强制直连，不改写）        │
│   ③ blacklist 黑名单  → 网关 IP（强制代理）                  │
│   ④ 其余：确定性 chnroute 仲裁                               │
│        并发查 国内UDP ‖ 可信DoT                              │
│        国内答案 IP ∈ chnroute? → 直连;否则 → 网关 IP        │
│                                                             │
│   同进程还跑：控制台 REST API + Web UI (:9443)、             │
│              Telegram bot、iOS 描述文件分发 (:8111)          │
└────────────────────────────────────────────────────────────┘
        │ 境外 → 网关 IP                    │ 国内 → 真实 IP / 广告 → NXDOMAIN
        ▼                                    ▼
  sing-box (direct inbound TCP 80 / TCP+UDP 443)      客户端直连 / 不发起连接
  sniff tls/quic 取 SNI，dns=22.22.22.22 重解析
        │
        ▼
  走网关默认路由直接出网（无隧道 / 多出口 / 策略路由）→ 互联网
```

| 场景 | DNS 行为 | 数据路径 |
|---|---|---|
| 命中 adblock | NXDOMAIN | 客户端不发起连接 |
| 命中 blacklist（强制代理） | 直接返回网关 IP | 客户端 → sing-box → 直出 |
| 仲裁后国外 IP | 改写为网关 IP | 客户端 → sing-box → 直出 |
| 仲裁后国内 IP | 原样返回真实 IP | 客户端直连，网关不经手 |

---

## 关键特性

- **四类确定性规则**（手动文件 + 远程订阅合并生效）：`adblock` → NXDOMAIN；`force-direct` → 真实 IP 不改写；`blacklist` → 网关 IP；默认 → chnroute 仲裁。优先级 adblock > force-direct > blacklist > 默认。
- **确定性 chnroute 仲裁**：并发查国内 UDP（`223.5.5.5`/`119.29.29.29`）和可信 DoT（`8.8.8.8`/`1.1.1.1`），**按 chnroute 成员关系判定，不看谁先回**（非竞速）。这是 smartdns 做不到、当初自研的根本原因。
- **多传输入口**：DoT `:853`、DoH `:8443`（`https://<域名>:8443/dns-query`）、明文 `:53`（per-source 限速）。
- **全查询类型**：A → 仲裁+改写；AAAA → SOA（IPv4-only）；HTTPS/SVCB → 空 NOERROR（保 SNI 嗅探）；其余 → 转发可信 DoT。
- **规则订阅**：`/etc/5gpn/subscriptions.json` 配远程列表，进程内按各自 `interval` 定时拉取、解析（`plain`/`gfwlist`/`dnsmasq`/`adblock`/`hosts`/`cidr`）、落盘缓存、与手动条目合并；拉取失败保留旧缓存（离线安全）。
- **统一控制面**（三前端共用同一内存 `Controller`）：
  - **HTTPS REST API + React Web 控制台**（`:9443`，bearer token 鉴权 + per-source 限速 + 审计，仅 CLIENT_NET 可达）。
  - **进程内 Telegram bot**（`github.com/go-telegram/bot`，管理员门控，直接调 `Controller`、不走 HTTP/token）。
  - **iOS 描述文件分发**（`:8111`，仅 CLIENT_NET）。
- **仅直出**：被代理流量经 sing-box `direct` inbound 透明转发（不解密 TLS），走网关默认路由出网——无 mark / 隧道 / 多出口 / 策略路由。QUIC/HTTP3 同样由 sing-box sniff `quic` 透明转发。
- **运维友好**：证书 mtime 热重载（续期 `kill -HUP` 即生效）；统计持久化存活重启；systemd 硬化沙箱，bot 特权操作经 `systemd-run`/`systemctl` 委派而不削弱沙箱。
- **零 Python、极小依赖**：Go 侧只依赖 `miekg/dns` + `go-telegram/bot`；第三方工具（sing-box、gum）用预编译二进制，网关上不放工具链。

---

## 安装

在一台 root 权限的 Linux 网关上：

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
# 或在 checkout 内：sudo bash install.sh
```

安装器会：下载预编译 **Gum**（sha256 校验，缺失回退 plain echo）、下载 CI 构建的 **5gpn-dns** 与预编译 **sing-box**、签发并自动续期 Let's Encrypt 证书、装 nftables 防火墙、生成 iOS DoT 描述文件 + 二维码、拉起 systemd 服务。结束时打印控制台地址与 token。

**内网部署**（客户端在内网，如 `172.22.0.0/16`）指定网关内网地址：

```bash
export GATEWAY_IP=<网关内网地址>
sudo bash install.sh
```

**常用环境变量覆盖**：`DOMAIN=` `PUBLIC_IP=` `EMAIL=` `GATEWAY_IP=` `CLIENT_NET=` `LOWMEM=1|0` `DNS_VERSION=` `DNS_SHA256=` `SINGBOX_SHA256=` `TGBOT_TOKEN=` `TGBOT_ADMINS=` `DNS_API_TOKEN=`（不设则自动生成 `openssl rand -hex 32`，重装保留）。

---

## 客户端接入

- **Android**：设置 → 私人 DNS → 填网关域名（DoT）。
- **iOS**：安装 DoT 描述文件（扫安装结束打印的二维码，或访问 `http://<网关>:8111/ios-dot.mobileconfig`）。
- **DoH**：支持 DoH 的客户端填 `https://<网关域名>:8443/dns-query`。
- **明文 DNS**：可直接用 `:53`（有限速），建议优先 DoT/DoH。

---

## 🖥 Web 控制台

- **地址**：`https://<域名或网关地址>:9443`（安装结束打印一次）。
- **可达范围**：仅 CLIENT_NET——:9443 监听所有网卡，但防火墙只放行 CLIENT_NET 来源，不对公网开放。
- **登录**：用 `DNS_API_TOKEN` 登录（浏览器 localStorage 保存）。找回：`grep DNS_API_TOKEN /etc/5gpn/dns.env`。
- **功能**：Dashboard（verdict 分布 + 上游健康）、Subscriptions（增删改 + 立即更新 + 健康）、Rules（四类增删 + 从磁盘重载）、Lookup（域名判定）、Stats。

---

## 📱 Telegram 控制 bot

Telegram bot 是 `5gpn-dns` 守护进程内的一个 Go 组件（不是独立进程/服务），直接调用进程内 `Controller`（不经 :9443、不需 token），与 Web 控制台并存。

```bash
sudo bash install.sh --setup-tgbot   # 写 TGBOT_TOKEN/TGBOT_ADMINS 到 dns.env 并重启守护
```

- **管理员门控**：只有 `TGBOT_ADMINS` 里的数字 ID 能操作；`/id` 自助取自己的 ID。
- **inline 键盘菜单**：状态、强制代理域名增删、刷新订阅、重载规则、重启服务、日志、续证书、iOS 二维码。
- **特权操作走 systemd**：sing-box 用 `systemctl restart`；"重启 5gpn-dns" 实为进程内热重载（避免自杀）；续证书用 `systemd-run certbot`（逃逸沙箱），**不削弱守护进程的硬化沙箱**。

---

## 常用命令

```bash
sudo bash install.sh --status        # 服务 / 域名 / 列表 状态
sudo bash install.sh --update-lists  # 触发规则缓存 reload（SIGHUP）
sudo bash install.sh --add-domain d  # 强制代理某域名（加入 blacklist）
sudo bash install.sh --del-domain d  # 取消强制代理
sudo bash install.sh --ios           # 重新生成 iOS 描述文件 + 二维码
sudo bash install.sh --setup-tgbot   # 启用进程内 Telegram bot
```

配置改动：编辑 `/etc/5gpn/dns.env` 后 `systemctl reload 5gpn-dns`（SIGHUP 热重载，不重启）。全部配置项见 [docs/DESIGN.md](docs/DESIGN.md) §9。

---

## 仓库结构

| 路径 | 说明 |
|---|---|
| `cmd/5gpn-dns/` | `5gpn-dns` Go 源码——DNS 引擎 + 控制面 API + bot + iOS 分发，全在一个二进制（CI 构建 → `moooyo/5gpn` release） |
| `cmd/5gpn-dns/api.go` | 控制台 HTTPS REST API（`:9443`，基于 `Controller` facade） |
| `cmd/5gpn-dns/bot.go` `bot_ops.go` | 进程内 Telegram bot |
| `cmd/5gpn-dns/iosd.go` | iOS 描述文件分发（`:8111`） |
| `web/` | React 控制台前端（独立构建；`npm run build` → `web/dist`，打包成 `5gpn-web-*.tar.gz` release asset；daemon 从 `DNS_WEB_DIR`=/opt/5gpn/web 磁盘 serve） |
| `install.sh` / `quick-install.sh` | 安装 / 升级编排 + 运维子命令 |
| `etc/` | 规则种子、`5gpn-dns/dns.env.example`、sing-box 配置、systemd 单元 |
| `scripts/` | 防火墙、iOS profile 生成、证书续期 hook、`update-lists.sh` |
| `tests/` | Go 单测 `cmd/5gpn-dns/*_test.go` + shell policy 测试 + 集成冒烟清单 |
| `docs/DESIGN.md` | 完整设计文档 |

---

## 构建与发布

- `5gpn-dns` **在 CI 构建**（网关上不放 Go 工具链）：`release.yml` 先 `npm run build` 前端 → `go build`（`-X main.version` 打版本号）→ 发布 `5gpn-dns-linux-amd64` + `checksums.txt`。
- CI（`ci.yml`）：`go vet` + `go test -race`、前端 build+typecheck、shell policy 测试。
- **注意**：发布标签 `dns-v0.1.0` 尚未 cut——打了它 `install.sh` 才能给普通用户下载二进制安装。

---

## 文档

- 设计文档：[docs/DESIGN.md](docs/DESIGN.md)
- 行为验收（在 Linux 网关上执行）：[tests/integration-smoke.md](tests/integration-smoke.md)
