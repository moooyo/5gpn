# 5gpn

基于 **smartdns** 的 DoT 网关:**解析即策略**——靠 DNS 解析结果直接决定一条流量是直连还是进代理,被代理的流量经 sniproxy 透明转发后**直出**。客户端仅通过 DoT(853)接入,无需安装任何 App。

> 仅用于已获合法授权的企业组网与技术研究,请遵守所在地法律法规。

## 工作原理

核心思想:**把要走代理的流量,在 DNS 这一层解析成网关自己的 IP**,让它自然 funnel 进网关上的 sniproxy;不走代理的流量则返回真实 IP,客户端直连,网关完全不经手。

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
  sniproxy(TCP 80/443)               客户端直连国内站
  读 SNI,经 22.22.22.22 解析真实 IP    (网关不在数据路径)
        │
        ▼
  走网关默认路由直接出网(无隧道/多出口)→ 互联网
```

三类流量的端到端路径:

| 场景 | DNS 行为 | 数据路径 |
|---|---|---|
| 命中强制代理域名表 | `address` 直接返回网关 IP | 客户端 → sniproxy → 直出 |
| 未命中,解析出国外 IP | `ip-alias` 改写成网关 IP | 客户端 → sniproxy → 直出 |
| 未命中,解析出国内 IP | 原样返回真实 IP | 客户端直连,网关不经手 |

## 关键特性

- **两级分流,无需维护大域名表**:一张小的**强制代理域名表**(`proxy-domains.txt`,污染兜底/已知必代理)+ 一张 **chnroute 反集**(`foreign-cidr.txt`,非中国 IP 段,自动生成并定时刷新)。国内/国外的区分由"解析出的 IP 是否在中国段"决定,不需要 chinalist/gfwlist。
- **抗污染解析**:国内明文上游用 `-whitelist-ip` 只接受中国 IP(滤掉污染答案),干净 DoT 上游(8.8.8.8 / 1.1.1.1)拿真实国外 IP,并发竞速选优。
- **仅 DoT 接入**:对外只开 853(TLS),无明文 53 入口;客户端零 App。
- **直出**:被代理流量经 sniproxy 透明转发(不解密 TLS),直接走网关默认路由出网——无 mark / 隧道 / 多出口 / 策略路由。
- **QUIC/HTTP3 不代理**:UDP 443 在防火墙 `reject`,客户端自动回退 TCP/TLS,由 sniproxy 接住。
- **防回环**:sniproxy 的解析器 hardcode 为外部解析器 `22.22.22.22`,绝不指向本机会做 `ip-alias` 的 smartdns,避免"国外域名→改写成网关 IP→又连回网关"的死循环。
- **IPv4-only**:`force-AAAA-SOA`,不追求 IPv6。
- **控制面**:可选的 HTTPS API / Telegram Bot / WebUI,以"编辑文本文件 + 重启 smartdns"方式管理强制表与列表刷新。

## 安装

在一台 root 权限的 Linux 网关上:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
# 或在 checkout 内:sudo bash install.sh
```

安装器会:安装 smartdns、编译 sniproxy、签发并自动续期 Let's Encrypt 证书、渲染配置、装 DoT-only 防火墙、生成 iOS DoT 描述文件 + 二维码、拉起服务。

内网部署(客户端在内网,如 172.22.0.0/16)时,指定网关内网地址:

```bash
export GATEWAY_IP=<网关内网地址>
sudo bash install.sh
```

环境变量覆盖:`DOMAIN=` `PUBLIC_IP=` `EMAIL=` `LOWMEM=1|0` `API_TOKEN=` `API_PORT=` `TGBOT_TOKEN=` `TGBOT_ADMINS=`。

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
sudo bash install.sh --setup-api     # 启用 HTTPS 控制 API(打印 token)
sudo bash install.sh --setup-tgbot   # 启用 Telegram 控制 bot
```

## 仓库结构

| 路径 | 说明 |
|---|---|
| `install.sh` | 安装 / 升级编排,以及上面的运维子命令 |
| `quick-install.sh` | 一键入口(拉取仓库后调用 `install.sh`) |
| `etc/` | smartdns 配置模板、`proxy-domains.txt`、sniproxy 配置、systemd 单元 |
| `scripts/` | chnroute 生成、配置渲染、防火墙、iOS profile、证书续期 hook、列表更新 |
| `src/ios-http.py` | iOS 描述文件分发的小型 HTTP 服务 |
| `api-server.py` / `tgbot.py` / `webui/` | 可选控制面(API / Telegram Bot / WebUI) |
| `tests/` | 策略测试 + 集成冒烟清单 |
| `docs/DESIGN.md` | 完整设计文档 |

## 文档与验证

- 设计文档:[docs/DESIGN.md](docs/DESIGN.md)
- 行为验收(需在 Linux 网关上执行):[tests/integration-smoke.md](tests/integration-smoke.md)
```
