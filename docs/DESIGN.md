# 5gpn 设计文档(smartdns DoT 网关)

- 状态:已实施
- 日期:2026-06-27
- 范围:smartdns DoT 网关的整体设计
- 已定决策:① 客户端仅 DoT(853) ② 不在强制列表但解析出国外 IP 的普通网站一律走 sing-box ③ **出口仅直出**(无 WireGuard / 多出口 / 策略路由) ④ **QUIC/HTTP3 经 sing-box `direct` inbound + route sniff `quic` 透明转发**;UDP 443 防火墙放行;引入**预编译** sing-box 二进制(不引入 Go 构建工具链);sing-box 以 root + systemd sandbox 运行(数据平面历经 sniproxy → xray → sing-box 两次反转,完整决策记录见 §12)

---

## 1. 目标与非目标

**目标**:用 smartdns 作为 DNS 大脑,以"一张小强制代理域名表 + 一张 chnroute 反集(非中国 IP)"实现自动分流,组件尽量少;被代理流量经 sing-box 透明转发后**直出**(单一直出口,无隧道/多出口)。

**非目标**:**不做多出口 / 隧道 / 策略路由(仅直出)**;不引入客户端 App;不追求 IPv6(维持 IPv4-only)。核心范式是"解析即策略 / SNI 透明转发不解密 TLS"。

## 2. 总体架构

```
客户端(Android 私人DNS=域名 / iOS 描述文件,仅 DoT)
        │  DoT :853(TLS,Let's Encrypt 证书)
        ▼
┌──────────────────────────────────────────────────────────┐
│ smartdns(DNS 大脑)                                        │
│  ① 命中强制代理域名表 blacklist → address → 返回网关IP      │
│  ② 其余:并发解析(cn 组就近+抗污染 / clean 组拿真实国外IP)│
│       ip-set:foreign(非中国IP CIDR)                       │
│         ├ 命中(国外)→ ip-alias → 返回网关IP               │
│         └ 未命中(国内)→ 原样返回真实国内IP                 │
└──────────────────────────────────────────────────────────┘
        │ 解析成网关IP(被墙/国外)        │ 真实国内IP
        ▼                                  ▼
  sing-box(direct inbound TCP 80 / TCP+UDP 443) 客户端直连国内站
  (sniff tls/quic/http, resolve ipv4_only,  (网关不在数据路径)
   dns ext 22.22.22.22, 私网/自身IP→reject)
        │  sniff SNI/域名,经 22.22.22.22 解析真实 IP
        ▼
  直接走网关默认路由出网(直出,无隧道/多出口)→ 互联网
```

## 3. 组件清单

| 组件 | 作用 |
|---|---|
| smartdns 主配置 + 列表生成脚本 | DoT 入口、双上游抗污染、`address`、`ip-alias`、`force-AAAA-SOA` |
| `proxy-domains.txt`(强制代理域名表) | 小表;污染兜底/已知必代理域名;可选 seed 自 gfwlist |
| `foreign-cidr.txt`(chnroute 反集) | 全网 − 中国 IP 段,由公开中国 IP 表自动生成 + 定时更新 |
| sing-box + config.json | `direct` inbound TCP 80 / TCP+UDP 443;route sniff tls/quic/http + resolve(ipv4_only);direct 直出;DNS 单一外部 `ext`=`22.22.22.22`;sniff 失败 / 私网 / 自身 IP → reject drop(防回环兜底) |
| DoT-only 防火墙(nft 入站) | 仅放行 22/853 + `172.22→80/443/udp443`;UDP 443 **accept**(QUIC 代理);**无 mark/策略路由** |
| certbot / renew-hook / iOS profile / ios-http | 仅 DoT → 证书与 iOS 描述文件 |
| install.sh 编排 | 装 smartdns、下载预编译 sing-box 二进制(sha256 可选/opt-in)、渲染配置、列表链路、systemd、sysctl/低内存 |
| `tgbot.py`(Telegram 控制面)+ `install.sh` Gum TUI | 管强制表 / chnroute 刷新 / 状态;改文件 + 重启 smartdns。Bot 通过 `--setup-tgbot` 配置,安装器内置 Gum TUI(自动下载预编译二进制)收集 token 与管理员 ID,无 Gum 时回退 plain echo |
| tests/ | policy 测试 |

**明确不包含**:WireGuard / 多出口 / `pxout` 打 mark / `table 100` 等出口层(仅直出)。sing-box 以预编译二进制安装,不引入 Go 工具链。

## 4. smartdns DNS 决策模型(配置骨架)

> 具体指令以 P1 spec 为准,下面是设计意图骨架。

三层确定性分流:

- **第一层(黑名单)**:`proxy-domains.txt` 中的域名 → `address /domain-set:blacklist/GATEWAY_IP`(不解析,直接返回网关 IP,必代理)。
- **第二层(白名单)**:`china-domains.txt`(felixonmars 列表,自动更新)中的域名 → `nameserver /domain-set:cnlist/domestic`(只询问境内 DNS 组)→ 直连。
- **第三层(其余)**:默认组(境内+境外上游都查)+ `ip-rules ip-set:china_ip -whitelist-ip`(合并答案含 CN IP 则只保留 CN IP,**内容过滤,不测速**)+ `speed-check-mode none`;无 CN IP → 答案全为境外 → `ip-rules ip-set:foreign -ip-alias GATEWAY_IP` → 改写成网关 IP → 进代理。

```ini
# 入口:仅 DoT 对外
bind-tls [::]:853
bind-cert-file   /etc/smartdns/cert/fullchain.pem
bind-cert-key-file /etc/smartdns/cert/privkey.pem
bind 127.0.0.1:5353        # 仅本机内部用,不对外

# IPv4 only
force-AAAA-SOA yes

# 不测速,第三层由 IP 内容(china_ip)决定,非竞速
speed-check-mode none
dualstack-ip-selection no

# 上游两组,均留在默认组(第三层名称两组都查)
server 223.5.5.5 -group domestic
server 119.29.29.29 -group domestic
server-tls 8.8.8.8 -host-name dns.google -group foreign
server-tls 1.1.1.1 -group foreign

# 已知污染 IP → SOA
conf-file /etc/smartdns/bogus-nxdomain.conf

# ① 第一层:黑名单 → 网关 IP(不解析,必代理)
domain-set -name blacklist -type list -file /etc/smartdns/proxy-domains.txt
address /domain-set:blacklist/GATEWAY_IP

# ② 第二层:白名单(大陆域名)→ 只问境内 DNS → 直连
domain-set -name cnlist -type list -file /etc/smartdns/china-domains.txt
nameserver /domain-set:cnlist/domestic

# ③ 第三层:其余 → 默认组(两组都查);含 CN IP → 只留 CN(内容过滤,不测速)
ip-set -name china_ip -type list -file /etc/smartdns/china_ip.conf
ip-rules ip-set:china_ip -whitelist-ip
# 无 CN IP 时答案为境外 → 改写为网关 IP → 进代理
ip-set -name foreign -type list -file /etc/smartdns/foreign-cidr.txt
ip-rules ip-set:foreign -ip-alias GATEWAY_IP
```

设计意图:第一层覆盖已知必代理/被污染域名(不解析即返回网关 IP);第二层用 felixonmars 大陆域名表强制只问境内上游(避免境内域名被境外 DoT 拿到国外 IP);第三层对既不在黑名单也不在白名单的域名并发查两组,用 `whitelist-ip` 内容过滤保留 CN IP(有则直连、外压掉),无 CN 则全走代理。**`speed-check-mode none`**:选择完全由 IP 归属决定,与应答先后无关(确定性,非 response-mode 竞速)。残留硬伤:被污染成"看着像国内"的 IP 仍会通过 `whitelist-ip` 误判直连 → 把该域名补进黑名单自愈。

## 5. 三大正确性约束(必须在实现中强保证)

1. **防回环(最关键)**:sing-box 解析 SNI 时**绝不能使用会做 `ip-alias` 的 smartdns**,否则"国外域名→改写成网关IP→sing-box 又连回网关"形成死循环。**决策:sing-box 配置单一外部 DNS server `ext`=`22.22.22.22`**(`route.default_domain_resolver` 与 `resolve` action 均引用它),绝不指向本机 smartdns。
2. **嗅探失败兜底**:sing-box 1.13 移除了 inbound 的 `override_address`,sniff 失败会**保留原始目的(= 网关自身 IP)**。兜底机制:`resolve` action 置于 reject 规则**之前**(即便"域名解析回自身 IP"也能被随后 reject 命中);`ip_is_private:true → reject(method:drop)` 覆盖 NPN 私网网关部署;`ip_cidr:[GATEWAY_IP/32, PUBLIC_IP/32] → reject(method:drop)` 覆盖公网部署(提交默认 sentinel `127.0.0.2/32`,install.sh patch 为实际 IP)。净效果与 xray 旧占位 `127.0.0.1` trick 一致:sniff 失败 / 指向自身的流量被丢弃,绝不回环。
3. **判 geo 前先拿到干净真实 IP**:第三层对既不在黑名单也不在白名单的域名并发查两组(境内 + 境外),用全局 `ip-rules ip-set:china_ip -whitelist-ip` 对合并后答案做内容过滤:含 CN IP 则只保留 CN IP(直连)、无 CN IP 则全走代理(`ip-alias`)。`speed-check-mode none`,确定性、非竞速。`bogus-nxdomain` 阻断已知污染 IP。残留硬伤:被污染成"看着像国内"的 IP 会被误判直连 → 把该域名补进强制表自愈。
4. **chnroute 反集的生成与时效**:`foreign-cidr.txt` = `0.0.0.0/0` 去掉中国段;由公开中国 IP 列表(如 `china_ip_list` / APNIC 衍生)自动生成并定时刷新。生成失败时保留旧表,不得清空(清空会把全部流量判成国内→直连→被墙站打不开)。

## 6. 端到端数据流(三类)

- **强制表命中(被墙/已知必代理)**:DoT 查 → `address` 直接返回网关 IP(不解析)→ 客户端连网关 → sing-box `direct` inbound route `action:sniff` 提取 SNI/quic/http → `action:resolve` 经 22.22.22.22 解析真实 IP → **直接走网关默认路由出网**。
- **未命中 + 国外 IP**:DoT 查 → 解析得真实国外 IP → `ip-alias` 改写成网关 IP → 同上进代理后**直出**。
- **未命中 + 国内 IP**:DoT 查 → 解析得真实国内 IP(原样)→ 客户端**直连**,网关不经手。
- QUIC/HTTP3 与 TLS 走同一 sing-box 实例:UDP 443 由防火墙放行进 sing-box,`action:sniff sniffer:quic` 取 SNI 后直出;TCP 443 同理 sniff `tls`。

## 7. 客户端接入(仅 DoT)

- Android:私人 DNS 填网关域名。
- iOS:安装 DoT 描述文件(`DNSProtocol=TLS`,`ServerAddresses` 写网关公网 IP 以免引导解析被污染),扫码下发(沿用 ios-http + 二维码)。
- 不提供明文 53 对外入口(P1 决策)。证书走 Let's Encrypt + 自动续期 hook(续期后重启 smartdns,而非 dnsdist)。

## 8. 出口:仅直出(无出口层)

被代理的流量(命中强制表 / 国外 IP,被解析成网关 IP)由 sing-box `direct` inbound 接住(TCP 80 sniff http、TCP+UDP 443 sniff tls/quic),**route rule `action:sniff` 提取域名、`action:resolve` 经 22.22.22.22 解析真实目标 IP 后,直接走网关自身的默认路由出网**。QUIC/HTTP3 与 TLS 均代理:UDP 443 由防火墙放行,sing-box sniff `quic` 取得目标域名后 `direct` 出站(IPv4-only)。网关本身即"够得到目标"的有利位置,无需隧道/多出口。

**明确不做**:`pxout` 打 mark、`ip rule fwmark`、`table 100`、apply-exit/set-exit、WireGuard、多出口/tproxy/tun/fwmark——全部不做。防火墙只做入站过滤(仅 DoT 22/853 + NPN 的 80/443/udp443)。

## 9. 规则与列表管理

smartdns 规则均为**磁盘文本文件**;控制面(**Telegram Bot** `tgbot.py`,通过 `install.sh --setup-tgbot` 配置;安装期使用 **Gum TUI** 交互,无 Gum 时回退 plain echo)以"**编辑文本文件 + 重启 smartdns**"方式生效(smartdns 无"改路由规则的内置 API")。需管理:
- `proxy-domains.txt`:增删强制代理域名(一行一条)。
- `foreign-cidr.txt`:由 chnroute 生成器维护,一般不手动改。
- (无出口管理——仅直出。)

## 10. 安全与合规

- 仅客户端→网关一跳加密(DoT);网关→上游建议尽量用 DoT 上游(clean 组)以抗污染。
- DoT/853 对公网开放,需 TLS + 每源限速(smartdns 限速/ACL)防滥用。
- 维持"仅用于已获合法授权场景"的定位与声明。

## 11. 阶段拆分(每阶段独立 spec + plan + 验证)

- **P1 — DNS 大脑(smartdns)**:DoT 入口 + 双上游抗污染 + `address`(强制表)+ `ip-alias`(chnroute→网关IP)+ IPv4-only + 防回环解析器 + `foreign-cidr` 生成器。验收:DoT 查被墙/国外域名→网关 IP;查国内→真实国内 IP;查环回不死循环。
- **P2 — 透明转发 + 直出**:sing-box direct inbound(DNS 单一外部 `ext`=`22.22.22.22`,私网/自身 IP → reject drop)+ DoT-only 入站防火墙(UDP 443 accept,QUIC 代理),接上 P1,**直接走默认路由出网**。验收:国外域名端到端经网关→sing-box→直出可达;QUIC/TLS 均可达。
- ~~**P3 — 出口层**~~:**取消**(仅直出,无 WireGuard / 多出口 / 策略路由)。
- **P3 — 安装编排**:新 install、systemd 单元、ACME 证书、iOS profile(DoT)、sysctl/低内存、续期 hook。
- **P4 — 控制面 + 测试 + 文档**:Telegram Bot 按新模型重写(Gum TUI 配置);policy 测试;README。

## 12. 已定决策 / 待定 / 风险

**已定(评审追加 2026-06-27):**
- 不维护 chinalist:国内/国外的区分完全由"解析出的 IP 是否在中国段"决定(第 4 节模型,**认可**)。
- 混合 IP(同域名既有国内又有国外 A 记录):**选国内** —— 只要解析结果含至少一个中国 IP,即按国内处理、直连;仅当全部 IP 均为国外时才 `ip-alias` 改写进代理。机制用 smartdns 的 IP 优选/过滤实现,P1 细化。
- sing-box 解析器:**单一外部 `ext`=`22.22.22.22`**(`default_domain_resolver` + `resolve` action 引用;见第 5 节,满足防回环)。
- QUIC/HTTP3:**代理**——sing-box direct inbound 在 UDP 443 上 sniff `quic` 取 SNI,直出;UDP 443 防火墙 `accept`(仅 NPN 172.22.0.0/16)。(決策反転:原为"防火墙拒绝 UDP 443、客户端回退 TCP";理由:sing-box direct inbound 原生支持 quic sniff,预编译二进制无需 Go 工具链,覆盖面更完整)
- 出口:**仅直出**——WireGuard / 多出口 / `pxout` 打 mark / `ip rule` / `table 100` / apply-exit / set-exit / check-exits **全部移除**;被代理流量经 sing-box 后直接走网关默认路由。
- sing-box 权限:**root + systemd sandbox**——`User=root`(需绑定低端口 80/443),`NoNewPrivileges=yes` / `ProtectSystem=strict` / `RestrictAddressFamilies=AF_INET AF_UNIX` 等 sandbox 指令限权。(理由:direct inbound 必须绑定 80/443,sing-box 无内置降权,故以 root + 严格 sandbox 替代)

**待定:**
- clean 组在国内机器上的可达性(可能需先经一个固定干净通道)——P1/P3(安装)细化。
- 强制表初始来源(是否 seed 自 gfwlist 以减少冷启动漏网)——P1 决定。

**决策追加 2026-06-29 — 数据平面 xray → sing-box(反转):**
- **背景**:2026-06-28 刚完成 sniproxy→xray 迁移;2026-06-29 用户明确指令再次反转,改用 sing-box。
- **技术结论**:对"嗅探 SNI 直出"窄场景,sing-box 与 xray 功能完全等价;代价是配置 churn、内存更高(~256 MB)、无 `.dgst` 旁文件。用户知悉权衡后仍明确选择 sing-box。
- **新配置形态**:sing-box `direct` inbound(普通监听口,不引入 tproxy/redirect/tun)+ route rule `action:sniff sniffer:[tls,quic,http]` + `action:resolve strategy:ipv4_only server:ext` + `direct` outbound;DNS 单一外部 udp server `ext`=`22.22.22.22`(`default_domain_resolver` 引用),防回环机制与 xray hardcode 等价。
- **嗅探失败防回环(sing-box 1.13 新坑)**:xray 用 dokodemo-door 占位 `127.0.0.1` → routing blackhole;sing-box 1.13 移除了 inbound `override_address`,sniff 失败保留原始目的(= 网关自身 IP)。替代方案:`resolve` 置于 reject 之前 + `ip_is_private:true → reject drop`(覆盖 NPN 私网部署)+ `ip_cidr:[GATEWAY_IP/32, PUBLIC_IP/32] → reject drop`(覆盖公网部署,私网规则盖不住时兜底);提交默认 sentinel `127.0.0.2/32`,install.sh 用实际 IP 改写。
- **版本锁定**:pin `1.13.14`(`SINGBOX_VERSION` 可覆盖),config 按 1.12+ 新语法(typed DNS + rule-action)。
- **sha256 验证**:默认不校验,保留 `SINGBOX_SHA256` opt-in(非致命)——sing-box 无 `.dgst` 旁文件,免去脆弱逻辑。(与 gum 强制 sha256 对比:gum 有 `checksums.txt`,可自动验;sing-box 无等价机制,故改为可选)
- **保留历史**:xray 相关旧配置保留于 git 历史(上一条已定决策条目不删)。回滚靠 `git revert` + 切回旧单元 + `install_xray`。

**决策追加 2026-06-30 — 分流模型:纯 IP 判定 → 三层确定性(反转「不维护 chinalist」):**
- **背景**:原 §4 称"含一个 CN IP 即直连"是硬保证,但代码只有 `response-mode first-ping` 延迟启发式,混合 CN/境外答案可能误判。
- **新模型**:① 黑名单(`proxy-domains.txt`)→ `address`→网关IP(不解析,必代理);② 白名单(`china-domains.txt`,felixonmars,自动更新)→ `nameserver /domain-set:cnlist/domestic`(只问境内 DNS)→ 直连;③ 其余 → 默认组(境内+境外)都查 + `ip-rules ip-set:china_ip -whitelist-ip`(含 CN 即只留 CN,内容过滤、**不测速**)+ `speed-check-mode none`;无 CN → 境外 → `ip-alias`→ 代理。
- **机制依据**:smartdns `whitelist-ip` 仅在答案含白名单 IP 时触发,对合并答案过滤,与应答先后无关 → 确定性(非 response-mode 竞速)。需 2024+ smartdns(空结果缓存修复)。
- **取舍**:多一张 ~8 万条自动更新域名表;移除 per-server `-whitelist-ip` 与 `china-whitelist.conf`(由全局 `ip-rules china_ip` 取代)。残留硬伤(伪 CN 污染)仍靠黑名单自愈。
- **保留历史**:旧"不维护 chinalist"决策不删;回滚靠 git。
