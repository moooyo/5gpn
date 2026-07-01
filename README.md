# 5gpn

基于 **5gpn-dns**(自研 Go)的 DNS 网关:**解析即策略**——靠 DNS 解析结果直接决定一条流量是直连还是进代理,被代理的流量经 sing-box 透明转发后**直出**。客户端通过 DoT / DoH / 明文 DNS 接入,无需安装任何 App。

> 仅用于已获合法授权的企业组网与技术研究,请遵守所在地法律法规。

## 工作原理

核心思想:**把要走代理的流量,在 DNS 这一层解析成网关自己的 IP**,让它自然 funnel 进网关上的 sing-box;不走代理的流量则返回真实 IP,客户端直连,网关完全不经手。

```
客户端(Android 私人 DNS / iOS 描述文件)
        │  DoT :853(TLS,Let's Encrypt 证书)
        │  DoH :8443(HTTPS /dns-query)
        │  明文 DNS :53(UDP+TCP,per-source 限速)
        │  控制台 :9443(HTTPS REST API + Web UI,bearer token,仅 CLIENT_NET)
        ▼
┌──────────────────────────────────────────────────────────┐
│ 5gpn-dns(Go DNS 大脑)                                     │
│  1) 命中 adblock 域名表 → NXDOMAIN(广告拦截)              │
│  2) 命中 force-direct 白名单 → 真实 IP(强制直连)          │
│  3) 命中 blacklist 黑名单 → 网关 IP(强制代理)             │
│  4) 其余:确定性 chnroute 仲裁                             │
│       并发 国内UDP + 可信DoT                               │
│       国内答案 IP∈chnroute? → 直连;否则 → 网关IP         │
└──────────────────────────────────────────────────────────┘
        │ 解析成网关 IP(被墙/国外)        │ 真实国内 IP / NXDOMAIN
        ▼                                  ▼
  sing-box(direct inbound TCP 80 / TCP+UDP 443) 客户端直连 / 广告被拦
  sniff tls/quic/http, dns=22.22.22.22
        │
        ▼
  走网关默认路由直接出网(无隧道/多出口)→ 互联网
```

四类流量的端到端路径:

| 场景 | DNS 行为 | 数据路径 |
|---|---|---|
| 命中 adblock | NXDOMAIN | 客户端不发起连接 |
| 命中 blacklist(强制代理) | 直接返回网关 IP | 客户端 → sing-box → 直出 |
| 仲裁后国外 IP | 改写为网关 IP | 客户端 → sing-box → 直出 |
| 仲裁后国内 IP | 原样返回真实 IP | 客户端直连,网关不经手 |

## 关键特性

- **四类确定性规则**(手动 + **订阅** 合并生效):① **adblock**(`adblock.txt` + `adblock/*.txt` 订阅缓存)→ NXDOMAIN;② **force-direct**(`direct.txt` + `direct/*.txt`)→ 仲裁后返回真实 IP,跳过改写(强制直连);③ **blacklist**(`blacklist.txt` + `blacklist/*.txt`,含旧 proxy-domains)→ 直接返回网关 IP(不解析);④ **默认 chnroute 仲裁**(`china_ip_list.txt` + `chnroute/*.txt`)→ 国内答案 IP∈chnroute 则直连,否则改写为网关 IP。
- **确定性仲裁**:并发查国内 UDP(223.5.5.5/119.29.29.29)和可信 DoT(1.1.1.1/8.8.8.8);按 chnroute 成员关系判定,不看谁先回(非竞速)。这是 smartdns `whitelist-ip` 做不到的(test-env 实测验证)。
- **多传输入口**:DoT :853(Android 私人 DNS / iOS)、DoH :8443(`https://<域名>:8443/dns-query`)、明文 DNS :53(per-source 限速)。
- **控制台 API + Web UI**::9443 提供 bearer-token 鉴权的 HTTPS REST API(状态/统计/查询/订阅/规则/更新/reload)+ 内嵌 React Web UI(`go:embed`);仅 CLIENT_NET 可达,不对公网开放。
- **全查询类型**:A → 仲裁+改写;AAAA → SOA(IPv4-only);HTTPS/SVCB → 空 NOERROR(保 sing-box SNI 嗅探);其余 → 转发可信 DoT,verbatim。
- **直出**:被代理流量经 sing-box `direct` inbound 透明转发(不解密 TLS),直接走网关默认路由出网——无 mark / 隧道 / 多出口 / 策略路由。
- **QUIC/HTTP3 由 sing-box sniff `quic` 透明转发**:UDP 443 防火墙放行,sing-box sniff quic 取 SNI 后 direct 出站。
- **防回环**:sing-box DNS 单一外部 server hardcode 为 `22.22.22.22`,绝不指向本机 5gpn-dns;`ip_is_private` + 自身 IP `ip_cidr` 规则 reject drop 兜底。
- **IPv4-only**:AAAA 返回 SOA,不追求 IPv6。
- **规则来源:订阅(远程 URL 自动更新)+ 手动条目**:`/etc/5gpn/subscriptions.json` 配置各类规则的远程订阅(`id`/`category`/`name`/`url`/`format`/`interval`),`5gpn-dns` 进程内按各自 `interval` 定时拉取、解析(`plain`/`gfwlist`/`dnsmasq`/`adblock`/`hosts`/`cidr`)、落盘缓存,与手动文件合并生效;拉取/解析失败保留旧缓存(离线安全)。chnroute 默认即由订阅维护。
- **控制面**:Phase 3 已实现——控制面现为 **:9443 HTTPS REST API + 内嵌 Web UI**(React,`go:embed`),bearer token 鉴权、仅 CLIENT_NET 可达;`tgbot.py` **已改为调同一 API 的客户端**(loopback `https://127.0.0.1:9443`),与 Web UI 并存;install.sh 自动生成 `DNS_API_TOKEN`(空则禁用控制面,不会无鉴权对外提供)。
- **证书热加载**:5gpn-dns 按 mtime 检测证书变化,续期后 `kill -HUP` 即生效,不重启。

## 安装

在一台 root 权限的 Linux 网关上:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
# 或在 checkout 内:sudo bash install.sh
```

安装器会:自动下载预编译 **Gum** 二进制(sha256 验证,无 Gum 时回退 plain echo)、下载 CI 构建的 **5gpn-dns** 二进制(`moooyo/5gpn` release)、下载预编译 **sing-box** 二进制、签发并自动续期 Let's Encrypt 证书、装防火墙(53/853/8443 + sing-box 端口)、生成 iOS DoT 描述文件 + 二维码、拉起服务。

内网部署(客户端在内网,如 172.22.0.0/16)时,指定网关内网地址:

```bash
export GATEWAY_IP=<网关内网地址>
sudo bash install.sh
```

环境变量覆盖:`DOMAIN=` `PUBLIC_IP=` `EMAIL=` `LOWMEM=1|0` `DNS_VERSION=` `DNS_SHA256=` `DNS_SUBSCRIPTIONS=`(默认 `/etc/5gpn/subscriptions.json`)`SINGBOX_SHA256=` `TGBOT_TOKEN=` `TGBOT_ADMINS=` `DNS_API_TOKEN=`(控制台鉴权 token,不设则安装器自动生成 `openssl rand -hex 32` 并在重装时保留)。

安装结束会打印控制台地址与 token:`https://<域名或网关地址>:9443`(仅 CLIENT_NET 内可访问)。

## 客户端接入

- **Android**:设置 → 私人 DNS → 填网关域名(DoT)。
- **iOS**:安装 DoT 描述文件(扫描安装结束时打印的二维码,或访问 profile URL)。
- **DoH**:在支持 DoH 的客户端填 `https://<网关域名>:8443/dns-query`。
- **明文 DNS**:可直接使用 `:53`,但有限速;建议优先使用 DoT/DoH。

## 🖥 Web 控制台(Phase 3)

- **地址**:`https://<域名或网关地址>:9443`,安装结束时会打印一次。
- **可达范围**:仅 CLIENT_NET(NPN 内网)可达,不对公网开放——:9443 虽然监听所有网卡,但 `setup-firewall.sh` 只放行 CLIENT_NET 来源。
- **登录**:使用安装时打印的 `DNS_API_TOKEN` 登录,token 保存在浏览器 localStorage。
- **找回 token**:`grep DNS_API_TOKEN /etc/5gpn/dns.env`。
- **tgbot 共用同一 API**:`tgbot.py` 走回环(`https://127.0.0.1:9443`)调用同一套控制面 API,与 Web UI 并存。

## 常用命令

```bash
sudo bash install.sh --status        # 服务 / 域名 / 列表 状态
sudo bash install.sh --update-lists  # 重载 5gpn-dns 规则缓存(SIGHUP;订阅的拉取由进程内定时器完成)
sudo bash install.sh --add-domain d  # 强制代理某域名
sudo bash install.sh --del-domain d  # 取消强制代理
sudo bash install.sh --ios           # 重新生成 iOS 描述文件 + 二维码
sudo bash install.sh --setup-tgbot   # 启用 Telegram 控制 bot(Gum TUI 交互)
```

> `--status` 不打印 Web 控制台 token;需要时读 `/etc/5gpn/dns.env` 里的 `DNS_API_TOKEN`。

## 仓库结构

| 路径 | 说明 |
|---|---|
| `cmd/5gpn-dns/` | 5gpn-dns Go 源码(DNS 大脑;CI 构建 → `moooyo/5gpn` release) |
| `cmd/5gpn-dns/api.go` | 控制台 HTTPS REST API(:9443,bearer token,仅 CLIENT_NET;基于 `Controller` facade) |
| `cmd/5gpn-dns/web/` | 控制台 Web UI 前端(React + Vite + Tailwind + TypeScript;CI 构建 `npm run build` → `web/dist` → `go:embed`;仓库内仅提交占位 `index.html`) |
| `install.sh` | 安装 / 升级编排,以及上面的运维子命令 |
| `quick-install.sh` | 一键入口(拉取仓库后调用 `install.sh`) |
| `etc/` | `blacklist.txt`(旧 proxy-domains)、`direct.txt`、`adblock.txt`、`etc/5gpn-dns/dns.env.example`(含 `DNS_SUBSCRIPTIONS`)、sing-box 配置(`etc/sing-box/config.json`)、systemd 单元 |
| `scripts/` | 防火墙、iOS profile、证书续期 hook、`update-lists.sh`(手动 reload 触发;chnroute 拉取已移入 5gpn-dns 进程内订阅管理器) |
| `src/ios-http.py` | iOS 描述文件分发的小型 HTTP 服务 |
| `tgbot.py` | Telegram 控制面(已改为 :9443 API 客户端;与 Web UI 并存) |
| `tests/` | 策略测试(grep policy) + Go 单测(`cmd/5gpn-dns/*_test.go`) + 集成冒烟清单 |
| `docs/DESIGN.md` | 完整设计文档 |

## 文档与验证

- 设计文档:[docs/DESIGN.md](docs/DESIGN.md)
- 行为验收(需在 Linux 网关上执行):[tests/integration-smoke.md](tests/integration-smoke.md)
