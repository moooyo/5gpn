# 5gpn 设计文档(smartdns DoT 网关)

- 状态:设计待评审
- 日期:2026-06-27
- 范围:smartdns DoT 网关的整体设计
- 已定决策:① 客户端仅 DoT(853) ② 不在强制列表但解析出国外 IP 的普通网站一律走 sniproxy ③ **出口仅直出**(无 sing-box / WireGuard / 多出口 / 策略路由) ④ **QUIC/HTTP3 不代理**(UDP 443 在防火墙 reject,客户端回退 TCP/TLS 走 sniproxy;不含 quic-proxy 与 Go 工具链)

---

## 1. 目标与非目标

**目标**:用 smartdns 作为 DNS 大脑,以"一张小强制代理域名表 + 一张 chnroute 反集(非中国 IP)"实现自动分流,组件尽量少;被代理流量经 sniproxy 透明转发后**直出**(单一直出口,无隧道/多出口)。

**非目标**:**不做多出口 / 隧道 / 策略路由(仅直出)**;不引入客户端 App;不追求 IPv6(维持 IPv4-only)。核心范式是"解析即策略 / SNI 透明转发不解密 TLS"。

## 2. 总体架构

```
客户端(Android 私人DNS=域名 / iOS 描述文件,仅 DoT)
        │  DoT :853(TLS,Let's Encrypt 证书)
        ▼
┌──────────────────────────────────────────────────────────┐
│ smartdns(DNS 大脑)                                        │
│  ① 命中强制代理域名表 proxylist → address → 返回网关IP      │
│  ② 其余:并发解析(cn 组就近+抗污染 / clean 组拿真实国外IP)│
│       ip-set:foreign(非中国IP CIDR)                       │
│         ├ 命中(国外)→ ip-alias → 返回网关IP               │
│         └ 未命中(国内)→ 原样返回真实国内IP                 │
└──────────────────────────────────────────────────────────┘
        │ 解析成网关IP(被墙/国外)        │ 真实国内IP
        ▼                                  ▼
  sniproxy(TCP 80/443)               客户端直连国内站
  (UDP 443/QUIC → 防火墙 reject,       (网关不在数据路径)
   客户端回退 TCP/TLS 走 sniproxy)
        │  读 SNI,经 22.22.22.22 解析真实 IP
        ▼
  直接走网关默认路由出网(直出,无隧道/多出口)→ 互联网
```

## 3. 组件清单

| 组件 | 作用 |
|---|---|
| smartdns 主配置 + 列表生成脚本 | DoT 入口、双上游抗污染、`address`、`ip-alias`、`force-AAAA-SOA` |
| `proxy-domains.txt`(强制代理域名表) | 小表;污染兜底/已知必代理域名;可选 seed 自 gfwlist |
| `foreign-cidr.txt`(chnroute 反集) | 全网 − 中国 IP 段,由公开中国 IP 表自动生成 + 定时更新 |
| sniproxy + sniproxy.conf | TCP SNI 透明转发,`user pxout`,通配兜底无域名表,解析器 hardcode `22.22.22.22`,**直出** |
| DoT-only 防火墙(nft 入站) | 仅放行 22/853 + `172.22→80/443/udp443`;**无 mark/策略路由** |
| certbot / renew-hook / iOS profile / ios-http | 仅 DoT → 证书与 iOS 描述文件 |
| install.sh 编排 | 装 smartdns、渲染配置、列表链路、systemd、sysctl/低内存 |
| api-server / tgbot / webui | 管强制表 / chnroute 刷新 / 状态;改文件 + 重启 smartdns |
| tests/ | policy 测试 |

**明确不包含**:QUIC/HTTP3 代理(UDP 443 在防火墙 reject,客户端回退 TCP 由 sniproxy 接;不引入 Go 工具链);sing-box / WireGuard / 多出口 / `pxout` 打 mark / `table 100` 等出口层(仅直出)。

## 4. smartdns DNS 决策模型(配置骨架)

> 具体指令以 P1 spec 为准,下面是设计意图骨架。

```ini
# 入口:仅 DoT 对外
bind-tls [::]:853
tls-cert-file /etc/smartdns/cert/fullchain.pem
tls-key-file  /etc/smartdns/cert/privkey.pem
bind 127.0.0.1:5353        # 仅本机内部用,不对外

# IPv4 only
force-AAAA-SOA yes

# 上游(抗污染):无域名表,所有上游并发竞速;不分 group / 不 exclude-default。
# 国内明文解析器 -whitelist-ip:只接受中国 IP(滤掉污染/伪国内答案);
# 干净 DoT 解析器无过滤:拿真实国外 IP。
server     223.5.5.5    -whitelist-ip                 # 国内:只收中国 IP
server     119.29.29.29 -whitelist-ip
server-tls 8.8.8.8 -host-name dns.google             # 干净:真实国外 IP
server-tls 1.1.1.1
conf-file /etc/smartdns/china-whitelist.conf         # whitelist-ip 集(由 china_ip_list 生成)
conf-file /etc/smartdns/bogus-nxdomain.conf          # 已知污染 IP -> SOA

# ① 强制代理域名 → 网关IP（命中即代理，不解析）
domain-set -name proxylist -file /etc/smartdns/proxy-domains.txt
address /domain-set:proxylist/__GATEWAY_IP__

# ② chnroute：解析后若 IP 属于「非中国」→ 改写成网关IP
ip-set   -name foreign -file /etc/smartdns/foreign-cidr.txt
ip-rules ip-set:foreign -ip-alias __GATEWAY_IP__
```

设计意图:对未命中强制表的域名,smartdns 并发查所有上游;国内明文解析器经 `-whitelist-ip` 只回中国 IP(污染/伪国内答案被滤掉),干净 DoT 解析器拿真实国外 IP。国内域名 → 拿到就近国内 IP(不在 foreign 集 → 直连);被墙/国外域名 → 拿到真实国外 IP(在 foreign 集 → `ip-alias` 改写成网关 IP → 进 sniproxy)。**不需要 chinalist**:国内/国外的区分由"解析出的 IP 是否在中国段"决定。残留硬伤:被污染成"看着像国内"的 IP 仍会通过 whitelist(补进强制表自愈)。

## 5. 三大正确性约束(必须在实现中强保证)

1. **防回环(最关键)**:sniproxy 解析 SNI 时**绝不能使用会做 `ip-alias` 的 smartdns**,否则"国外域名→改写成网关IP→sniproxy 又连回网关"形成死循环。**决策:sniproxy 的解析器一律 hardcode 为 `22.22.22.22`**(外部解析器,绝不指向本机 smartdns)。(QUIC/HTTP3 不代理,UDP 443 reject,故无 quic-proxy 侧的回环面。)
2. **判 geo 前先拿到干净真实 IP**:第二级判"国外?"依赖解析正确。靠 cn 组 `whitelist-ip`(只收中国 IP)+ `bogus-nxdomain` + clean 组(DoT 上游更难污染)。残留硬伤:被污染成"看着像国内"的 IP 会被误判直连 → 把该域名补进强制表自愈。
3. **chnroute 反集的生成与时效**:`foreign-cidr.txt` = `0.0.0.0/0` 去掉中国段;由公开中国 IP 列表(如 `china_ip_list` / APNIC 衍生)自动生成并定时刷新。生成失败时保留旧表,不得清空(清空会把全部流量判成国内→直连→被墙站打不开)。

## 6. 端到端数据流(三类)

- **强制表命中(被墙/已知必代理)**:DoT 查 → `address` 直接返回网关 IP(不解析)→ 客户端连网关 → sniproxy 读 SNI(QUIC 被 reject→客户端回退 TCP)→ 经 22.22.22.22 解析真实 IP → **直接走网关默认路由出网**。
- **未命中 + 国外 IP**:DoT 查 → 解析得真实国外 IP → `ip-alias` 改写成网关 IP → 同上进代理后**直出**。
- **未命中 + 国内 IP**:DoT 查 → 解析得真实国内 IP(原样)→ 客户端**直连**,网关不经手。

## 7. 客户端接入(仅 DoT)

- Android:私人 DNS 填网关域名。
- iOS:安装 DoT 描述文件(`DNSProtocol=TLS`,`ServerAddresses` 写网关公网 IP 以免引导解析被污染),扫码下发(沿用 ios-http + 二维码)。
- 不提供明文 53 对外入口(P1 决策)。证书走 Let's Encrypt + 自动续期 hook(续期后重启 smartdns,而非 dnsdist)。

## 8. 出口:仅直出(无出口层)

被代理的流量(命中强制表 / 国外 IP,被解析成网关 IP)由 sniproxy 接住(QUIC/HTTP3 不代理:UDP 443 在防火墙 reject,客户端回退 TCP/TLS),**读 SNI、经 22.22.22.22 解析真实目标 IP 后,直接走网关自身的默认路由出网**。网关本身即"够得到目标"的有利位置,无需隧道/多出口。

**明确不做**:`pxout` 打 mark、`ip rule fwmark`、`table 100`、apply-exit/set-exit、sing-box、WireGuard、连通性/延迟检查——全部不做。`pxout` 仅作为代理进程的非特权账户保留;防火墙只做入站过滤(仅 DoT 22/853 + NPN 的 80/443/udp443)。

## 9. 规则与列表管理 / "API 改配置"

smartdns 规则均为**磁盘文本文件**;控制面(API/Bot/WebUI)以"**编辑文本文件 + 重启 smartdns**"方式生效(smartdns 无"改路由规则的内置 API")。需管理:
- `proxy-domains.txt`:增删强制代理域名(一行一条)。
- `foreign-cidr.txt`:由 chnroute 生成器维护,一般不手动改。
- (无出口管理——仅直出。)

## 10. 安全与合规

- 仅客户端→网关一跳加密(DoT);网关→上游建议尽量用 DoT 上游(clean 组)以抗污染。
- DoT/853 对公网开放,需 TLS + 每源限速(smartdns 限速/ACL)防滥用。
- 维持"仅用于已获合法授权场景"的定位与声明。

## 11. 阶段拆分(每阶段独立 spec + plan + 验证)

- **P1 — DNS 大脑(smartdns)**:DoT 入口 + 双上游抗污染 + `address`(强制表)+ `ip-alias`(chnroute→网关IP)+ IPv4-only + 防回环解析器 + `foreign-cidr` 生成器。验收:DoT 查被墙/国外域名→网关 IP;查国内→真实国内 IP;查环回不死循环。
- **P2 — 透明转发 + 直出**:sniproxy(解析器 hardcode `22.22.22.22`)+ DoT-only 入站防火墙(UDP 443/QUIC reject),接上 P1,**直接走默认路由出网**。验收:国外域名端到端经网关→sniproxy→直出可达;QUIC 被 reject 后客户端回退 TCP。
- ~~**P3 — 出口层**~~:**取消**(仅直出,无 sing-box / WireGuard / 多出口 / 策略路由)。
- **P3 — 安装编排**:新 install、systemd 单元、ACME 证书、iOS profile(DoT)、sysctl/低内存、续期 hook。
- **P4 — 控制面 + 测试 + 文档**:API/Bot/WebUI 按新模型重写;policy 测试;README。

## 12. 已定决策 / 待定 / 风险

**已定(评审追加 2026-06-27):**
- 不维护 chinalist:国内/国外的区分完全由"解析出的 IP 是否在中国段"决定(第 4 节模型,**认可**)。
- 混合 IP(同域名既有国内又有国外 A 记录):**选国内** —— 只要解析结果含至少一个中国 IP,即按国内处理、直连;仅当全部 IP 均为国外时才 `ip-alias` 改写进代理。机制用 smartdns 的 IP 优选/过滤实现,P1 细化。
- sniproxy 解析器:**hardcode `22.22.22.22`**(见第 5 节,满足防回环)。
- QUIC/HTTP3:**不代理**——UDP 443 在防火墙 `reject`,客户端回退 TCP/TLS(由 sniproxy 接);quic-proxy 与 Go 工具链一并移除(评审追加 2026-06-27)。
- 出口:**仅直出**——sing-box / WireGuard / 多出口 / `pxout` 打 mark / `ip rule` / `table 100` / apply-exit / set-exit / check-exits **全部移除**;被代理流量经 sniproxy 后直接走网关默认路由。

**待定:**
- clean 组在国内机器上的可达性(可能需先经一个固定干净通道)——P1/P3(安装)细化。
- 强制表初始来源(是否 seed 自 gfwlist 以减少冷启动漏网)——P1 决定。
