# 5gpn 设计文档

**5gpn 是一个"直出型"中国线路 DNS/SNI 网关。** 一个自研 Go 守护进程 `5gpn-dns` 做 DNS 大脑（DoT/DoH/明文解析 + 确定性国内外分流 + 规则集），sing-box 做透明 SNI/QUIC 转发的数据面，**全程仅直出**（无 WireGuard / 多出口 / 策略路由 / 出口层）。整套控制面（HTTPS REST API + React Web 控制台 + Telegram bot + iOS 描述文件分发）都编进同一个二进制、同一个进程。

- 状态：P1–P5 全部实现并在 `origin/main`，CI 全绿（`go vet` + `go test -race` + 前端构建 + shell policy 测试）。真机 `install.sh` 全链已验证。
- 依赖：Go 侧只有 `github.com/miekg/dns` + `github.com/go-telegram/bot`（两者零额外传递依赖；`golang.org/x/*` 是 miekg/dns 的既有间接依赖）。第三方工具（sing-box、gum）用预编译二进制。**无 Python。**

---

## 1. 目标与非目标

**目标**
- 给国内客户端一个加密 DNS 入口（DoT / DoH / 明文 53），对**境内域名走国内、境外域名走网关（经 sing-box 直出转发）**，判定必须**确定性**（"解析结果含国内 IP 即用国内"，按成员关系而非竞速）。
- 规则可**订阅远程列表自动更新**，也可手动维护，两者合并。
- 控制面统一：一个 token 化的 HTTPS API + Web 控制台 + Telegram bot，三者共用同一套内存 `Controller`。
- 单文件部署：一个 Go 二进制含全部功能；`install.sh` 一键装好证书、防火墙、systemd。

**非目标**
- **没有出口层**：不做 WireGuard / 多出口 / fwmark / `ip rule` / `table 100` / tproxy / tun。sing-box 只是透明 SNI/QUIC 转发器（`direct` 出站），不做 fwmark/tun。
- 不追求 IPv6 解析（AAAA 一律合成空答复，走 IPv4）。
- 不做 DoQ（刻意排除以保持只依赖 miekg/dns）。

---

## 2. 总体架构

```
                          ┌───────────────────────────────────────────────┐
   客户端 (手机/PC)        │            单个 Go 二进制  5gpn-dns             │
        │                 │                                               │
   DoT  :853  ───────────▶│  解析引擎  ── 确定性 chnroute 仲裁 ── 规则集   │
   DoH  :8443 ───────────▶│    │              (国内UDP ‖ 可信DoT)          │
   明文 :53   ───────────▶│    │                                          │
                          │    ├─ 缓存 / TTL 钳制 / 证书热重载 / SIGHUP    │
                          │    │                                          │
   Web/curl :9443 ───────▶│  控制面 ── HTTPS REST API  ┐                  │
   浏览器   :9443 / ─────▶│           内嵌 React SPA   ├─ 同一 Controller  │
   Telegram  (长轮询) ───▶│           进程内 bot       ┘   (内存直调)      │
   iPhone   :8111 ───────▶│  iOS 描述文件分发                             │
                          │                                               │
                          └───────────────┬───────────────────────────────┘
                                          │ 境外域名 → 改写成网关 IP
                                          ▼
   客户端 HTTPS/QUIC ─────────────▶  sing-box  :80/:443(tcp) :443(udp)
                                     透明 SNI/QUIC 嗅探 → 直出 (default route)
```

**决策面 / 数据面分离**：`5gpn-dns` 只做"域名 → 判定 → 返回真实 IP 或网关 IP"；真正的字节转发由 sing-box 负责。境外域名被解析成网关 IP，客户端于是把 HTTPS/QUIC 发到网关，sing-box 在 :80/:443 嗅探 SNI、重解析真实 IP、直出转发。

---

## 3. DNS 决策模型

### 3.1 入口传输与端口

| 传输 | 默认端口 | 说明 |
|---|---|---|
| DoT | `:853` | TLS over TCP，需证书 |
| DoH | `:8443` | HTTPS `/dns-query`（非 443，443 归 sing-box） |
| 明文 | `:53` | UDP + TCP，公网开放、按源限速 |
| debug | `127.0.0.1:5353` | 仅本机、明文，排障用 |

空值即禁用该监听。

### 3.2 查询类型分派（最高优先级）

1. `AAAA` → 合成 SOA、NOERROR、空 Answer（本网关只走 IPv4）。
2. `HTTPS` / `SVCB` → 空 NOERROR（避免 ECH/HTTPS 记录绕过 SNI 改写）。
3. `A` → 进入下面的四类规则 + 仲裁。
4. 其余类型（`MX/TXT/CNAME/NS/PTR/SOA`…）→ 原样转发可信上游。

### 3.3 四类规则（A 查询，优先级自上而下）

`classifyName` 的名字优先级：**adblock > force-direct > blacklist > 默认**。

| 类别 | 判定 verdict | reason | 行为 |
|---|---|---|---|
| adblock | block | `adblock` | 直接返回 NXDOMAIN，不查上游 |
| force-direct | direct | `force-direct` | 仲裁取真实 IP、**不改写**（强制直连） |
| blacklist | proxy | `blacklist` | 合成单条 A = 网关 IP，不查上游（sinkhole 到网关） |
| 默认 | direct / proxy | `chnroute-cn` / `chnroute-foreign` | 仲裁 → 含国内 IP 则原样返回；纯境外则改写成网关 IP |

### 3.4 确定性 chnroute 仲裁（默认类的核心）

并发向"国内 UDP 上游"和"可信 DoT 上游"发同一查询：
- 阻塞读国内答复（受 ctx 截止时间约束）。
- **若国内答复里任一 A 记录 ∈ chnroute → 返回国内答复**；否则（境外/出错/超时/NODATA）→ 返回可信答复。
- 判定**只看国内答复的 chnroute 成员关系，绝不看谁先返回**。这是 smartdns 做不到、当初自研的根本原因。

### 3.5 境外 IP → 网关改写

默认类拿到可信答复后，逐条 A 记录：国内 IP 保留原样；境外 IP 全部替换成 `DNS_GATEWAY_IP`（去重成一条）。非 A 记录透传。TTL 钳制到 `[TTL_MIN, TTL_MAX]`。这一步把境外流量"漏斗"进 sing-box。

### 3.6 缓存 / 证书热重载 / SIGHUP

- **缓存**：TTL 感知，大小可配（默认 4096，装机按内存上调）；缓存命中回填请求的事务 ID（严格 DoT 客户端要求）。
- **证书热重载**：`GetCertificate` 回调按 mtime 重载，续期后无需重启。
- **SIGHUP / `systemctl reload`**：原子重建规则集并 swap 进在跑的 Handler，在途查询安全完成。

---

## 4. 规则与订阅

**每类规则的有效集合 = 手动文件 `rules/<cat>.txt` + 该类所有订阅缓存 `rules/<cat>/*.txt`**，glob 合并加载。

**进程内订阅管理器**（`subscription.go`）：
- 从 `/etc/5gpn/subscriptions.json` 读订阅，每条按自己的 `interval` 定时拉取远程 URL。
- 解析格式：域名类 `plain` / `gfwlist`（base64）/ `dnsmasq` / `adblock` / `hosts`；chnroute 用 `cidr`。
- 落盘 `rules/<category>/<name>.txt`（原子 temp+rename）。
- **断网/解析失败/条目过少（域名 <1、CIDR <100 的地板保护）→ 保留旧缓存**，不清空。
- 每条订阅记录健康：`last-fetch 时间 / ok / 条目数 / 错误`，经 API 暴露给控制台。
- chnroute 默认由一条内置订阅维护，manual 文件仍可覆盖。

---

## 5. 控制面

三个前端（REST API、Web 控制台、Telegram bot）都调用同一套内存 `Controller` facade（`Subscriptions / AddSubscription / RemoveSubscription / Update / Reload / Stats / AddRule / RemoveRule / ListRules / Lookup`）。

### 5.1 :9443 HTTPS REST API

中间件链：**限速 → 审计 → 鉴权 → 路由**。

- **鉴权**：`Authorization: Bearer <DNS_API_TOKEN>`，常量时间比较（`crypto/subtle`）。`DNS_API_TOKEN` 为空 ⇒ 整个控制面不启（绝不无鉴权暴露）。
- **限速**：手搓 per-source-IP 令牌桶（`DNS_API_RATE`/`DNS_API_BURST`，默认 20/s、桶 40），在鉴权**之前**，挡 token 爆破。
- **审计**：每个写端点记一行 `audit method= path= src= status=`（不记 body/token）。
- **防火墙**：仅 CLIENT_NET 可达，绝不公网。

| 方法 + 路径 | 作用 |
|---|---|
| `GET /api/status` | 版本、运行时长、stats 快照 |
| `GET /api/stats` | reason 级计数器 + 缓存条数 + 上游健康 |
| `GET /api/lookup?domain=` | 某域名判定 + 解析 IP + reason |
| `GET/POST /api/subscriptions` | 列（含健康）/ 增 |
| `PATCH/DELETE /api/subscriptions/{id}` | 改（事务化：先校验再删旧）/ 删 |
| `POST /api/update?id=` | 立即拉取（缺省=全部） |
| `GET/POST/DELETE /api/rules/{cat}` | 手动规则 列/增/删 |
| `POST /api/reload` | 重读规则文件 + 原子 swap |

stats 为 reason 级：`total / adblock / force_direct / blacklist / chnroute_cn / chnroute_foreign / cache_entries / china_ok / china_err / trust_ok / trust_err`，持久化到 `DNS_STATS_FILE` 存活重启。

### 5.2 内嵌 React Web 控制台

`cmd/5gpn-dns/web/`（React + Vite + Tailwind + TS），`go:embed web/dist` 编进二进制、根路径 `/` 提供。视图：Login（填 token）、Dashboard（verdict 分布条 + 上游健康）、Subscriptions（CRUD + 立即更新 + 健康列）、Rules（四类增删 + 从磁盘重载）、Lookup、Stats。前端**在 CI 构建**（`npm run build` → `web/dist` → `go:embed`）；仓库只提交占位 `web/dist/index.html`，真实产物不入库。

### 5.3 进程内 Telegram bot

用 `github.com/go-telegram/bot`（零依赖）长轮询，作为守护进程的一个 goroutine，**直接调 `Controller`（内存，无 HTTP、无 token）**：
- 管理员门禁（`TGBOT_ADMINS` 数字 ID），`/id` 自助取 ID。
- inline 键盘菜单：状态 / 强制代理域名增删 / 刷新订阅 / 重载规则 / 重启服务 / 日志 / 续证书 / iOS 二维码。
- **特权操作委派给 systemd**（不在守护沙箱内跑）：sing-box 走 `systemctl restart`；"重启 5gpn-dns" 实为 `Controller.Reload()` 进程内热重载（避免自杀）；日志 `journalctl`；续证书 `systemd-run certbot`（逃逸沙箱，见 §7）。
- `NewBot` 与 `Run` 都在 goroutine 内，`bot.New` 的 getMe 阻塞不影响守护启动；坏 token 快速失败 → 记 "bot disabled" → 守护照常服务 DNS。

### 5.4 iOS 描述文件分发（:8111）

iOS 用加密 DNS 需要安装 `.mobileconfig` 描述文件。守护进程内一个 `http.Server` 在 :8111（仅 CLIENT_NET）发这个文件，content-type 精确 `application/x-apple-aspen-config`（iOS 认这个才当描述文件装）。固定两条路由、GET-only、无路径穿越。

---

## 6. 数据面（sing-box，仅直出）

sing-box 是**透明 SNI/QUIC 转发器**：`direct` 入站在 `:80`/`:443`(TCP) + `:443`(UDP/QUIC) 嗅探 SNI，用一个 loop-avoidance 解析器（默认 22.22.22.22，可 `SINGBOX_RESOLVER` 覆盖）重解析真实 IP，然后**直出**（走默认路由，无代理链）。它**不做** tproxy/tun/fwmark，因此仍在"无出口层"约束内。

境外流量漏斗：客户端把境外域名解析成网关 IP（§3.5）→ 连网关 :443 → sing-box 嗅 SNI、重解析、直出。

---

## 7. 安全模型

- **API**：token 化 + 常量时间比较 + 空-token-禁用 + 限速 + 审计 + 仅 CLIENT_NET 防火墙。
- **明文 :53 开放解析器面**：有意接受，靠 nftables per-source 限速缓解。
- **5gpn-dns.service 沙箱**：`ProtectSystem=strict`、`NoNewPrivileges=yes`、`RestrictAddressFamilies=AF_INET AF_UNIX`（真机验证过 IPv4 单栈够，不需要 AF_INET6）、`ReadWritePaths=/etc/5gpn`、把 `dns.env`（含 token）与 `cert/` 重新设为只读白名单（解析器不能改写自己的密钥/证书）。
- **bot 特权操作不削弱沙箱**：`systemctl`/`journalctl` 走 systemd 的 AF_UNIX socket（已放行）；`certbot` 用 `systemd-run`——由 PID 1 起的临时单元，**逃逸出守护沙箱**，能写 `/etc/letsencrypt` 并刷新 `/etc/5gpn/cert`。因此守护进程保持完整硬化。

---

## 8. 部署与运维

**`install.sh`**（gum-or-echo TUI；`curl | sudo bash` 或 checkout 内 `sudo bash install.sh`）：

`full_install` 顺序：root 检查 → gum bootstrap → OS 探测 → 内存画像 → 公网 IP → 装依赖（含下载 `5gpn-dns` 二进制 + sing-box）→ 装文件（规则/订阅/脚本/systemd 单元）→ 解析域名 + 验 A 记录 → 装 5gpn-dns.service → 证书（certbot 或复用现有）→ 写 `dns.env` → 拉订阅 → 防火墙 → 系统调优 → 生成 iOS 描述文件 → 启服务。

子命令：`--update-lists`（触发 reload）、`--status`、`--add-domain <d>` / `--del-domain <d>`（强制代理黑名单）、`--ios`（重生描述文件）、`--setup-tgbot`（写 `TGBOT_TOKEN`/`TGBOT_ADMINS` 进 dns.env + 重启守护）、`--help`。

**目录布局**
- `/usr/local/bin/{5gpn-dns,sing-box}` — 二进制
- `/opt/5gpn/{scripts,www,etc/systemd}` — 安装树
- `/etc/5gpn/dns.env` — 运维可编辑的环境配置（改后 `systemctl reload 5gpn-dns`）
- `/etc/5gpn/cert/{fullchain,privkey}.pem` — 证书副本（续期钩子维护）
- `/etc/5gpn/rules/` — `<cat>.txt` 手动 + `<cat>/*.txt` 订阅缓存
- `/etc/5gpn/{subscriptions.json,stats.json,.domain,.public_ip,.gateway_ip}`

**证书 / 续期**：`certbot certonly --standalone` → 部署钩子拷进 `/etc/5gpn/cert` + `systemctl reload 5gpn-dns`。续期由 certbot 自身 timer 驱动；bot 的"手动续期"走 `systemd-run certbot`。

**防火墙**（`setup-firewall.sh`，nftables，`policy drop`，默认 `CLIENT_NET=172.22.0.0/16`）：
- 公网：`:22`、`:53`(限速)、`:853`、`:8443`。
- 仅 CLIENT_NET：`:9443`(控制台)、`:80`/`:443`/`:8111`(sing-box + iOS)、`:443/udp`(QUIC)。

---

## 9. 配置项（`/etc/5gpn/dns.env` / 环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DNS_LISTEN_DOT/DOH/PLAIN/DEBUG` | `:853`/`:8443`/`:53`/`127.0.0.1:5353` | 监听地址，空=禁用 |
| `DNS_CERT` / `DNS_KEY` | — | TLS 证书/私钥（DoT/DoH/API 需要） |
| `DNS_GATEWAY_IP` | — | 境外 IP 改写成的网关 IP |
| `DNS_CHINA` | `223.5.5.5,119.29.29.29` | 国内 UDP 上游 |
| `DNS_TRUST` | `dns.google@8.8.8.8,one.one.one.one@1.1.1.1` | 可信 DoT 上游（`SNI@地址`） |
| `DNS_RULES_DIR` | `/etc/5gpn/rules` | 规则目录 |
| `DNS_CHNROUTE` | `/etc/5gpn/rules/china_ip_list.txt` | chnroute CIDR 文件 |
| `DNS_SUBSCRIPTIONS` | `/etc/5gpn/subscriptions.json` | 订阅配置 |
| `DNS_CACHE_SIZE` / `DNS_TTL_MIN` / `DNS_TTL_MAX` / `DNS_QUERY_TIMEOUT` | `4096` / `300` / `86400` / `5s` | 缓存与 TTL |
| `DNS_LISTEN_API` | `:9443` | 控制面监听 |
| `DNS_API_TOKEN` | — | bearer token，空=控制面禁用 |
| `DNS_API_RATE` / `DNS_API_BURST` | `20` / `40` | API per-source 限速；`≤0` 关限速 |
| `DNS_STATS_FILE` | `/etc/5gpn/stats.json` | 统计持久化，空=不持久化 |
| `DNS_IOS_LISTEN` / `WWW_DIR` | `:8111` / `/opt/5gpn/www` | iOS 分发监听 / 静态目录 |
| `TGBOT_TOKEN` / `TGBOT_ADMINS` | — | Telegram bot token / 管理员数字 ID，空=bot 禁用 |

---

## 10. 构建、发布与测试

- **构建**：`5gpn-dns` 在 **CI 构建**（`cmd/5gpn-dns/` → `moooyo/5gpn` release，`DNS_VERSION` 钉版本，`DNS_SHA256` 可选校验），装机时下载——网关上不放 Go 工具链。release.yml：先 `npm run build` 前端 → `go build`（`-X main.version` 打版本号）→ 发布 `5gpn-dns-linux-amd64` + `checksums.txt`。
- **CI（ci.yml）**：`go`（`go vet` + `go test -race`）、`web`（`npm ci` + build + typecheck）、`test`（纯 grep shell policy 测试，无工具链）。
- **测试分层**：Go 单测 `cmd/5gpn-dns/*_test.go`；shell policy 测试 `tests/test_*.sh`；Linux 门（`sing-box check`、`nft -c`、live DoT/DoH/plain、证书/续期、`install.sh` 全链）在真实 Debian 机验证。
- **发布状态**：`dns-v0.1.0` tag 尚未 cut；打了它 install.sh 才能给普通用户下载安装。

---

## 11. 正确性约束（实现必须强保证）

- chnroute 仲裁按**成员关系**判定，不看返回顺序（`Arbitrate` 阻塞读国内 + 条件读可信，无 select 竞速）。
- 缓存命中必须回填请求事务 ID。
- `DNS_API_TOKEN` 为空绝不无鉴权暴露控制面；token 常量时间比较。
- 订阅拉取失败/条目过少必须**保留旧缓存**（离线安全，绝不清空）。
- 订阅 `name` 拒绝路径穿越；订阅 `url` 仅 http/https（防 SSRF/文件读取）。
- bot/iOS goroutine 的 panic 必须 recover，绝不拖垮 DNS 解析。
- 解析路径（DoT/DoH/明文）与控制面/bot 相互隔离；控制面故障不影响解析。
