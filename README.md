# 5gpn

基于 **smartdns** 的 DoT 网关:**解析即策略**——靠 DNS 解析结果直接决定一条流量是直连还是进代理,被代理的流量经 sing-box 透明转发后**直出**。客户端仅通过 DoT(853)接入,无需安装任何 App。

> 仅用于已获合法授权的企业组网与技术研究,请遵守所在地法律法规。

## 工作原理

核心思想:**把要走代理的流量,在 DNS 这一层解析成网关自己的 IP**,让它自然 funnel 进网关上的 sing-box;不走代理的流量则返回真实 IP,客户端直连,网关完全不经手。

```
客户端(Android 私人 DNS / iOS 描述文件,仅 DoT)
        │  DoT :853(TLS,Let's Encrypt 证书)
        ▼
┌──────────────────────────────────────────────────────────┐
│ smartdns(DNS 大脑)                                        │
│  ① 命中强制代理域名表 → address → 返回网关 IP              │
│  ② 其余:并发解析抗污染,拿到真实 IP 后看 chnroute          │
│       ├ 国外 IP → ip-alias → 改写成网关 IP                 │
│       └ 国内 IP → 原样返回                                  │
└──────────────────────────────────────────────────────────┘
        │ 解析成网关 IP(被墙/国外)        │ 真实国内 IP
        ▼                                  ▼
  sing-box(direct inbound TCP 80 / TCP+UDP 443) 客户端直连国内站
  sniff tls/quic/http, dns=22.22.22.22     (网关不在数据路径)
        │
        ▼
  走网关默认路由直接出网(无隧道/多出口)→ 互联网
```

三类流量的端到端路径:

| 场景 | DNS 行为 | 数据路径 |
|---|---|---|
| 命中强制代理域名表 | `address` 直接返回网关 IP | 客户端 → sing-box → 直出 |
| 未命中,解析出国外 IP | `ip-alias` 改写成网关 IP | 客户端 → sing-box → 直出 |
| 未命中,解析出国内 IP | 原样返回真实 IP | 客户端直连,网关不经手 |

## 关键特性

- **三层确定性分流**:① **黑名单**(`proxy-domains.txt`,污染兜底/已知必代理)→ `address` 直接返回网关 IP(不解析);② **白名单**(`china-domains.txt`,felixonmars,自动更新)→ 只问境内 DNS → 直连;③ **其余** → 境内+境外并发查 + `ip-rules china_ip -whitelist-ip`(含 CN IP 优先直连,不测速)→ 无 CN 则 `ip-alias` 改写成网关 IP → 进代理。`speed-check-mode none`。
- **抗污染解析**:第三层中,干净 DoT 上游(8.8.8.8 / 1.1.1.1)解析不确定/境外域名;全局 `china_ip` ip-set 对合并后答案做内容过滤——含 CN IP 即只保留 CN IP(直连),全为境外则 `ip-alias` 改写为网关 IP(进代理)。`speed-check-mode none`,选择由 IP 归属决定(确定性,不竞速)。
- **仅 DoT 接入**:对外只开 853(TLS),无明文 53 入口;客户端零 App。
- **直出**:被代理流量经 sing-box `direct` inbound 透明转发(不解密 TLS),直接走网关默认路由出网——无 mark / 隧道 / 多出口 / 策略路由。
- **QUIC/HTTP3 由 sing-box sniff `quic` 透明转发、直出**:UDP 443 防火墙放行(仅 NPN 172.22.0.0/16),sing-box sniff quic 取 SNI 后 direct 出站,与 TLS 走同一实例。
- **防回环**:sing-box 的 DNS 单一外部 server hardcode 为 `22.22.22.22`,绝不指向本机会做 `ip-alias` 的 smartdns,避免"国外域名→改写成网关 IP→又连回网关"的死循环;`ip_is_private` + 自身 IP `ip_cidr` 规则 reject drop 兜底(sniff 失败保留原始目的 = 网关自身 IP,显式 reject 防止回环)。
- **IPv4-only**:`force-AAAA-SOA`,不追求 IPv6。
- **控制面**:Telegram Bot(`tgbot.py`),以"编辑文本文件 + 重启 smartdns"方式管理强制表与列表刷新。Bot 通过 `install.sh --setup-tgbot` 配置,安装器内置 **Gum** TUI(自动下载预编译二进制)收集 token 与管理员 ID,无 Gum 时回退 plain echo 交互。

## 安装

在一台 root 权限的 Linux 网关上:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
# 或在 checkout 内:sudo bash install.sh
```

安装器会:自动下载预编译 **Gum** 二进制(sha256 验证,无 Gum 时回退 plain echo)、安装 smartdns、下载预编译 **sing-box** 二进制(opt-in sha256)、签发并自动续期 Let's Encrypt 证书、渲染配置、装 DoT-only 防火墙、生成 iOS DoT 描述文件 + 二维码、拉起服务。

内网部署(客户端在内网,如 172.22.0.0/16)时,指定网关内网地址:

```bash
export GATEWAY_IP=<网关内网地址>
sudo bash install.sh
```

环境变量覆盖:`DOMAIN=` `PUBLIC_IP=` `EMAIL=` `LOWMEM=1|0` `TGBOT_TOKEN=` `TGBOT_ADMINS=`。

## 客户端接入

- **Android**:设置 → 私人 DNS → 填网关域名。
- **iOS**:安装 DoT 描述文件(扫描安装结束时打印的二维码,或访问 profile URL)。

## 常用命令

```bash
sudo bash install.sh --status        # 服务 / 域名 / 列表 状态
sudo bash install.sh --update-lists  # 刷新 chnroute + 重渲染 + 重启 smartdns
sudo bash install.sh --add-domain d  # 强制代理某域名
sudo bash install.sh --del-domain d  # 取消强制代理
sudo bash install.sh --ios           # 重新生成 iOS 描述文件 + 二维码
sudo bash install.sh --setup-tgbot   # 启用 Telegram 控制 bot(Gum TUI 交互)
```

## 仓库结构

| 路径 | 说明 |
|---|---|
| `install.sh` | 安装 / 升级编排,以及上面的运维子命令 |
| `quick-install.sh` | 一键入口(拉取仓库后调用 `install.sh`) |
| `etc/` | smartdns 配置模板、`proxy-domains.txt`、sing-box 配置(`etc/sing-box/config.json`)、systemd 单元 |
| `scripts/` | chnroute 生成、配置渲染、防火墙、iOS profile、证书续期 hook、列表更新 |
| `src/ios-http.py` | iOS 描述文件分发的小型 HTTP 服务 |
| `tgbot.py` | Telegram 控制 bot(唯一控制面) |
| `tests/` | 策略测试 + 集成冒烟清单 |
| `docs/DESIGN.md` | 完整设计文档 |

## 文档与验证

- 设计文档:[docs/DESIGN.md](docs/DESIGN.md)
- 行为验收(需在 Linux 网关上执行):[tests/integration-smoke.md](tests/integration-smoke.md)
```
