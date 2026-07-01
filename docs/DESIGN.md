# 5gpn 设计文档(5gpn-dns DoT/DoH/plain-53 网关)

- 状态:已实施(Phase 1 引擎 + Phase 2 订阅系统已完成;Phase 3 API+Web UI 计划中)
- 日期:2026-06-27(更新 2026-07-01)
- 范围:5gpn-dns Go DNS 网关的整体设计
- 已定决策:① 客户端多传输接入:DoT :853 / DoH :8443 / 明文 DNS :53(限速) ② 不在强制列表但解析出国外 IP 的域名 → 改写为网关 IP,进 sing-box ③ **出口仅直出**(无 WireGuard / 多出口 / 策略路由) ④ **QUIC/HTTP3 经 sing-box `direct` inbound + route sniff `quic` 透明转发**;UDP 443 防火墙放行;sing-box 以 root + systemd sandbox 运行(数据平面历经 sniproxy → xray → sing-box 两次反转,完整决策记录见 §12)

---

## 1. 目标与非目标

**目标**:用自研 Go 二进制 `5gpn-dns` 作为 DNS 大脑,以"四类规则 + 确定性 chnroute 仲裁"实现自动分流,组件尽量少;被代理流量经 sing-box 透明转发后**直出**(单一直出口,无隧道/多出口)。

**非目标**:**不做多出口 / 隧道 / 策略路由(仅直出)**;不引入客户端 App;不追求 IPv6(维持 IPv4-only)。核心范式是"解析即策略 / SNI 透明转发不解密 TLS"。

## 2. 总体架构

```
客户端(Android 私人DNS=域名 / iOS 描述文件)
        │  DoT :853(TLS,Let's Encrypt 证书)
        │  DoH :8443(HTTPS /dns-query,复用 LE 证书)
        │  明文 DNS :53(UDP+TCP,对外,per-source 限速)
        ▼
┌──────────────────────────────────────────────────────────┐
│ 5gpn-dns(Go DNS 大脑,cmd/5gpn-dns/)                      │
│  per query(优先级自上而下):                               │
│  0) AAAA → SOA(IPv4-only);HTTPS/SVCB(65) → 空 NOERROR   │
│     其余非 A → 转发可信 DoT(1.1.1.1/8.8.8.8),verbatim  │
│  1) 命中 adblock 域名表 → NXDOMAIN(广告拦截)              │
│  2) 命中 force-direct 白名单 → 仲裁解析,返回真实 IP       │
│     (强制直连,跳过国外→网关改写)                          │
│  3) 命中 blacklist 黑名单 → A = 网关IP(强制代理)          │
│  4) 其余 → chnroute 仲裁:                                 │
│        并发 国内UDP(223.5.5.5/119.29.29.29)               │
│            + 可信DoT(1.1.1.1/8.8.8.8)                    │
│        国内答案含 IP∈chnroute? → 用国内答案               │
│        否则 → 用可信答案                                   │
│        → 改写:IP∈chnroute 保留,否则→网关IP;去重         │
│  → 缓存(TTL 钳制)→ 答                                    │
└──────────────────────────────────────────────────────────┘
        │ 解析成网关IP(国外/被墙)         │ 真实国内IP / NXDOMAIN(广告)
        ▼                                  ▼
  sing-box(direct inbound TCP 80 / TCP+UDP 443) 客户端直连国内站
  (sniff tls/quic/http, resolve ipv4_only,  (网关不在数据路径)
   dns ext 22.22.22.22, 私网/自身IP→reject)
        │  sniff SNI/域名,经 22.22.22.22 解析真实 IP
        ▼
  直接走网关默认路由出网(直出,无隧道/多出口)→ 互联网
```

**确定性仲裁**:第4步按 chnroute 成员关系判定,不看谁先回(国内慢也等到超时)。**优先级**:adblock > force-direct > blacklist > 默认仲裁;同一域名既在 force-direct 又在 blacklist 时,**force-direct(直连)优先**(显式 allow > deny),并记录。

## 3. 组件清单

| 组件 | 作用 |
|---|---|
| `5gpn-dns`(Go 二进制,`cmd/5gpn-dns/`) | DNS 大脑:DoT/DoH/plain-53 入口、四类规则、确定性仲裁、chnroute CIDR 判定、改写网关IP、AAAA→SOA、adblock、缓存、SIGHUP 重载、证书热加载 |
| `/etc/5gpn/rules/`(四类规则,手动文件 + 订阅缓存) | `adblock.txt`、`direct.txt`、`blacklist.txt`、`china_ip_list.txt`(手动)+ `<cat>/*.txt`(订阅缓存,Phase 2 已实现,见 §9) |
| sing-box + config.json | `direct` inbound TCP 80 / TCP+UDP 443;route sniff tls/quic/http + resolve(ipv4_only);direct 直出;DNS 单一外部 `ext`=`22.22.22.22`;sniff 失败 / 私网 / 自身 IP → reject drop(防回环兜底) |
| 防火墙(nft 入站) | 放行 22/53/853/8443 + `172.22→80/443/udp443`;:53 per-source 限速;**无 mark/策略路由** |
| certbot / renew-hook / iOS profile / ios-http | 证书、iOS 描述文件;renew-hook 拷证书 + `kill -HUP`(5gpn-dns 热加载,不重启) |
| install.sh 编排 | 装 5gpn-dns(下载 CI 预编译产物)、下载预编译 sing-box、规则文件、systemd、sysctl/低内存 |
| `subscriptions.json`(`/etc/5gpn/subscriptions.json`) | 订阅配置:各条目 `id`/`category`/`name`/`url`/`format`/`enabled`/`interval`;`5gpn-dns` 进程内订阅管理器按此定时拉取(见 §9) |
| `tgbot.py`(Telegram 控制面)+ `install.sh` Gum TUI | 管手动规则 / `update-lists.sh` 触发 reload / 状态;改文件 + SIGHUP。Phase 3 tgbot 将改为调同一 API |
| tests/ | policy 测试 + Go 单测 |

**明确不包含**:WireGuard / 多出口 / `pxout` 打 mark / `table 100` 等出口层(仅直出)。sing-box 以预编译二进制安装,5gpn-dns 以 CI 构建产物安装,网关上不引入 Go 工具链。

## 4. 5gpn-dns DNS 决策模型(四类规则 + 确定性仲裁)

### 4.1 查询类型分派(最高优先级)

| qtype | 行为 |
|---|---|
| `A` | 走四类规则 + chnroute 仲裁(见 §4.2) |
| `AAAA` | 返回 SOA(IPv4-only,不响应 AAAA) |
| `HTTPS`/`SVCB`(65) | 返回空 NOERROR(避免 ECH 藏 SNI,逼回退 A + 明文 SNI,保 sing-box 嗅探) |
| 其余所有类型 | 转发可信 DoT(1.1.1.1/8.8.8.8),verbatim 返回,不改写;先查缓存 |

adblock 对**所有 qtype** 拦截(命中即 NXDOMAIN);blacklist / force-direct **主要作用于 A**(非 A 命中时按"转发可信 DoT"处理)。

### 4.2 四类规则(A 查询优先级,自上而下)

| 优先级 | 类别 | 文件(`/etc/5gpn/rules/`) | 匹配 | 命中行为 |
|---|---|---|---|---|
| 1 | adblock | `adblock.txt`(域名) | 域名后缀 | NXDOMAIN(广告拦截) |
| 2 | force-direct | `direct.txt`(域名) | 域名后缀 | 仲裁解析,返回真实 IP,**跳过国外→网关改写**(强制直连) |
| 3 | blacklist | `blacklist.txt`(域名;= 旧 proxy-domains) | 域名后缀 | A = 网关IP(强制代理,不解析) |
| 4 | 默认(chnroute 仲裁) | `china_ip_list.txt`(CIDR) | IP∈集合 | 见 §4.3 |

域名匹配:后缀/父域命中(`a.b.example.com` 命中 `example.com`)。force-direct 与 blacklist 冲突时 force-direct 优先(显式 allow > deny)。

### 4.3 确定性 chnroute 仲裁(第4条规则)

1. **并发**查询国内 UDP(223.5.5.5, 119.29.29.29)和可信 DoT(1.1.1.1, 8.8.8.8)。
2. 等待两组各返回首个成功答案(国内慢也等到 `DNS_QUERY_TIMEOUT`,不看先后)。
3. **判定**:国内答案的 IP 集合中有任意 IP ∈ chnroute → 用国内答案;否则 → 用可信答案。
4. **改写**:对最终答案的每个 IP:∈ chnroute → 保留(直连);否则 → 改写为 `GATEWAY_IP`(进 sing-box);去重。

**确定性**:选择完全由 chnroute 成员关系决定,与应答先后无关(非竞速)。残留硬伤:被污染成"看着像国内"的 IP 仍可能误判直连 → 把该域名加进 blacklist 自愈。

`china_ip_list.txt`(手动文件)+ `chnroute/*.txt`(订阅缓存,默认由一条指向 17mon/china_ip_list 的订阅维护,取代 Phase 1 `update-lists.sh` 直接下载 chnroute 的方式;见 §9)。

### 4.4 规则文件加载(Phase 2:手动文件 + 订阅缓存合并)

每类的**有效集合 = 手动文件(`DNS_RULES_DIR/<cat>.txt`)+ 该类所有订阅缓存(`DNS_RULES_DIR/<cat>/*.txt`)**;`LoadDomainSet`/`LoadChnrouteFiles` 按 glob 合并多文件加载,不再是写死单文件。订阅缓存由 `5gpn-dns` 进程内的订阅管理器(见 §9)写入,手动文件仍可直接编辑(tgbot / 运维)。目录不存在(未配置任何订阅)→ 只用手动文件,行为退化为 Phase 1。

**Phase 1**:本地文件加载。**Phase 2(已实现)**:每类规则可订阅远程 URL,定时+按需拉取、解析、与手动条目合并、落盘缓存、断网保留旧表、热重载(见 §9)。

## 5. 正确性约束(必须在实现中强保证)

1. **防回环(最关键)**:sing-box 解析 SNI 时**绝不能使用 5gpn-dns**,否则形成死循环。**决策:sing-box 配置单一外部 DNS server `ext`=`22.22.22.22`**(`route.default_domain_resolver` 与 `resolve` action 均引用它),绝不指向本机 5gpn-dns。

2. **嗅探失败兜底**:sing-box 1.13 移除了 inbound `override_address`,sniff 失败保留原始目的(= 网关自身 IP)。兜底:`resolve` 置于 reject 之前 + `ip_is_private:true → reject drop` + `ip_cidr:[GATEWAY_IP/32, PUBLIC_IP/32] → reject drop`(sentinel `127.0.0.2/32`,install.sh patch 为实际 IP)。

3. **反污染(anti-pollution)**:可信 DoT(1.1.1.1/8.8.8.8)用于仲裁时的"可信"一侧,不受境内 DNS 污染。chnroute 成员判定基于 `china_ip_list.txt`(正集,定期更新)。污染成"看着像国内"的硬边缘情况靠 blacklist 自愈。不再需要 `foreign-cidr.txt`(反集)或 `bogus-nxdomain.conf`。

4. **chnroute 时效**:`chnroute/*.txt` 订阅缓存由进程内订阅管理器定时刷新(默认订阅指向 17mon/china_ip_list);拉取/解析失败或条目数低于下限保留旧表(不得清空,清空会把全部流量判成国内→直连→被墙站打不开)。`update-lists.sh` 现仅触发 `systemctl reload`(重读磁盘缓存),不再自己下载。

5. **证书热加载**:`5gpn-dns` 用 `GetCertificate` 按 mtime 检测证书变化,续期后 `kill -HUP` 即生效,不需要重启服务。

## 6. 端到端数据流(四类)

- **adblock 命中**:查询 → `5gpn-dns` 匹配 adblock → NXDOMAIN → 客户端不发起连接。
- **blacklist 命中(被墙/必代理)**:查询 → `address` 直接返回网关 IP → 客户端连网关 → sing-box sniff SNI → 经 22.22.22.22 解析真实 IP → 直接走网关默认路由出网。
- **仲裁后国外 IP**:查询 → chnroute 仲裁 → 可信答案 → 改写为网关 IP → 同上直出。
- **仲裁后国内 IP**:查询 → chnroute 仲裁 → 国内答案原样返回 → 客户端直连,网关不经手。
- QUIC/HTTP3:UDP 443 防火墙放行进 sing-box,`action:sniff sniffer:quic` 取 SNI 后直出;TCP 443 同理 sniff `tls`。

## 7. 客户端接入(DoT / DoH / 明文 DNS)

- **Android**:私人 DNS 填网关域名(DoT)。
- **iOS**:安装 DoT 描述文件(`DNSProtocol=TLS`,扫码下发)。
- **DoH**:客户端填 `https://<域名>:8443/dns-query`。
- **明文 DNS**:`:53` 对外开放,per-source 限速。已知风险:易被 spoof/放大攻击;已接受。
- 证书走 Let's Encrypt + 自动续期 hook(续期后 `kill -HUP`,5gpn-dns 热加载)。

## 8. 出口:仅直出(无出口层)

被代理的流量由 sing-box `direct` inbound 接住(TCP 80/443, UDP 443),route rule `action:sniff` 提取域名、`action:resolve` 经 22.22.22.22 解析真实目标 IP,**直接走网关自身的默认路由出网**。QUIC/HTTP3 与 TLS 均代理。

**明确不做**:`pxout` 打 mark、`ip rule fwmark`、`table 100`、WireGuard、多出口/tproxy/tun/fwmark。

## 9. 规则与列表管理(Phase 2:进程内订阅管理器)

规则有两个来源,合并生效(见 §4.4):**手动文本文件**(`/etc/5gpn/rules/<cat>.txt`,控制面 **Telegram Bot** `tgbot.py` 编辑 + SIGHUP,或运维直接改文件)和**订阅**(`/etc/5gpn/subscriptions.json`,`5gpn-dns` 进程内的订阅管理器按各自 `interval` 定时拉取远程 URL)。Phase 3 计划:公开 HTTPS API + Web UI(tgbot 改为调同一 API,与 Web UI 并存),届时订阅的增删也走 API。

**订阅管理器(`cmd/5gpn-dns/subscription.go`)**:
- 配置文件 `/etc/5gpn/subscriptions.json`(env `DNS_SUBSCRIPTIONS` 覆盖路径);每条订阅含 `id`/`category`/`name`/`url`/`format`/`enabled`/`interval`。文件缺失 → 视为无订阅(不报错);JSON 损坏 → 报错并保留上次内存态。
- **支持格式**:域名类(adblock / force-direct / blacklist 三个分类)—— `plain`(一行一域名)、`gfwlist`(base64 整体解码 + 前缀剥离)、`dnsmasq`(`server=`/`address=` 取 domain)、`adblock`(ABP `||domain^` 语法子集)、`hosts`(`0.0.0.0 domain` 取 domain);CIDR 类(chnroute)—— `cidr`(一行一 CIDR)。
- **落盘**:每条订阅的拉取结果写 `/etc/5gpn/rules/<category>/<name>.txt`(原子写 tmp+rename)。
- **失败即保留旧表(offline-safe)**:拉取失败、解析失败、或解析后条目数低于该类别的下限(floor guard,域名类如 1、chnroute 如 100)→ 视为失败,**保留旧缓存不覆盖**,不清空(空表会误伤,如空 chnroute = 全部误判国外)。
- **热重载**:每次成功拉取 → 重建该类规则集 → 原子 swap 生效,无需重启;`SIGHUP` 同样触发全量重读(手动文件 + 全部订阅缓存)。
- **chnroute 现由默认订阅提供**(指向 17mon/china_ip_list),取代了 Phase 1 由 `update-lists.sh` 直接下载 chnroute 的方式。
- `scripts/update-lists.sh` 现在只是一个手动刷新触发器:`systemctl reload 5gpn-dns`(SIGHUP 重读磁盘缓存),真正的拉取由进程内定时器完成。

需管理:
- `blacklist.txt` / `blacklist/*.txt`:强制代理域名(手动 + 订阅缓存)。
- `direct.txt` / `direct/*.txt`:强制直连域名(手动 + 订阅缓存)。
- `adblock.txt` / `adblock/*.txt`:广告拦截域名(手动 + 订阅缓存)。
- `china_ip_list.txt` / `chnroute/*.txt`:chnroute CIDR;默认由订阅维护,一般不手动改。
- `subscriptions.json`:订阅本身的增删(id/URL/format/interval),Phase 2 手动编辑该文件 + reload;Phase 3 走 API。

## 10. 安全与合规

- 客户端→网关：DoT / DoH(TLS);明文 :53 per-source 限速防滥用。
- 网关→上游：可信 DoT(1.1.1.1/8.8.8.8)抗污染。
- 维持"仅用于已获合法授权场景"的定位与声明。

## 11. 阶段拆分(每阶段独立 spec + plan + 验证)

- **Phase 1(当前)**:`5gpn-dns` 引擎核心:DoT/DoH/plain-53 入口、四类规则(本地文件)、确定性仲裁、改写、AAAA→SOA、adblock、缓存、SIGHUP 重载、证书热加载。CI 构建(`moooyo/5gpn` release)。取代 smartdns + chinadns-ng。
- **Phase 2(已实现)**:订阅系统:四类规则各可订阅远程 URL,进程内订阅管理器定时+按需拉取、与手动条目合并、落盘缓存、断网保留旧表、热重载。chnroute 默认由订阅提供;`update-lists.sh` 改为手动 reload 触发器。
- **Phase 3(计划)**:公开 HTTPS API(token 鉴权,复用 LE 证书)+ Web UI:查询/统计/控制;**tgbot 改为调同一 API,与 Web UI 并存**。
- ~~**出口层**~~:**取消**(仅直出,无 WireGuard/多出口/策略路由)。

## 12. 已定决策 / 待定 / 风险

**已定(评审追加 2026-06-27):**
- 不维护 chinalist:国内/国外的区分完全由"解析出的 IP 是否在中国段"决定(第 4 节模型,**认可**)。
- 混合 IP(同域名既有国内又有国外 A 记录):**选国内** —— 只要解析结果含至少一个中国 IP,即按国内处理、直连;仅当全部 IP 均为国外时才改写进代理。
- sing-box 解析器:**单一外部 `ext`=`22.22.22.22`**(满足防回环)。
- QUIC/HTTP3:**代理**——sing-box direct inbound 在 UDP 443 上 sniff `quic` 取 SNI,直出;UDP 443 防火墙 `accept`(仅 NPN 172.22.0.0/16)。
- 出口:**仅直出**——WireGuard / 多出口 / `pxout` 打 mark / `ip rule` / `table 100` **全部移除**。
- sing-box 权限:**root + systemd sandbox**——`User=root`,`NoNewPrivileges=yes` / `ProtectSystem=strict` / `RestrictAddressFamilies=AF_INET AF_UNIX` 等限权。

**待定:**
- clean 组在国内机器上的可达性(可能需先经一个固定干净通道)——Phase 1 细化。

**决策追加 2026-06-29 — 数据平面 xray → sing-box(反转):**
- **背景**:2026-06-28 刚完成 sniproxy→xray 迁移;2026-06-29 用户明确指令再次反转,改用 sing-box。
- **技术结论**:对"嗅探 SNI 直出"窄场景,sing-box 与 xray 功能完全等价;代价是配置 churn、内存更高(~256 MB)、无 `.dgst` 旁文件。用户知悉权衡后仍明确选择 sing-box。
- **新配置形态**:sing-box `direct` inbound + route rule `action:sniff sniffer:[tls,quic,http]` + `action:resolve strategy:ipv4_only server:ext` + `direct` outbound;DNS 单一外部 udp server `ext`=`22.22.22.22`。
- **嗅探失败防回环(sing-box 1.13 新坑)**:xray 用 dokodemo-door 占位 `127.0.0.1` → routing blackhole;sing-box 1.13 移除了 inbound `override_address`。替代方案:`resolve` 置于 reject 之前 + `ip_is_private:true → reject drop` + `ip_cidr:[GATEWAY_IP/32, PUBLIC_IP/32] → reject drop`。
- **版本锁定**:pin `1.13.14`(`SINGBOX_VERSION` 可覆盖)。
- **保留历史**:xray 相关旧配置保留于 git 历史。

**决策追加 2026-06-30 — 分流模型:纯 IP 判定 → 三层确定性(反转「不维护 chinalist」):**
- **背景**:原 §4 称"含一个 CN IP 即直连"是硬保证,但代码只有 `response-mode first-ping` 延迟启发式,混合 CN/境外答案可能误判。
- **新模型**:三层 smartdns 分流方案已设计并提交 test-env 实测。
- **保留历史**:旧"不维护 chinalist"决策不删;回滚靠 git。

**决策追加 2026-07-01 — DNS 大脑:smartdns + chinadns-ng → 自研 Go `5gpn-dns`(反转):**
- **背景**:三层 smartdns 方案在 test-env 实测时**证明不可行**:smartdns 无法做到"含国内 IP 即用国内、不测速"(内部实现是 response-mode 竞速,非 IP 成员关系判定),`whitelist-ip` 在混合答案下行为不确定。随后评估 chinadns-ng:能做确定性仲裁,但依赖内核 nftset + 多组件协调,复杂度高。
- **用户决策**:自研 Go DNS 把逻辑收进一个进程,彻底取代 smartdns + chinadns-ng。分阶段:Phase 1 引擎(确定性仲裁,本 §§2-11)、Phase 2 订阅、Phase 3 公开 API + Web UI。
- **约定反转(同步改 CLAUDE.md)**:① "控制面只有 tgbot、无 HTTP API/web UI" → 有意重新引入(P3);② "规则手动添加" → 订阅(P2);③ "DoT-only 入站,不开明文 53" → DoT :853 + DoH :8443 + 明文 :53(限速,已接受);④ "prebuilt 第三方工具" → 5gpn-dns 是我们自己的 CI 产物(同规则,网关上不引工具链)。
- **实测驱动的正确性基线**:确定性仲裁已在 test-env 用 mock 上游(CN/国外/超时)验证,两种时序均通过。smartdns `whitelist-ip` 的不确定性已被实测确认(非猜测)。
- **保留历史**:三层 smartdns 设计 + chinadns-ng 评估保留于 `docs/superpowers/specs/` 历史记录中。smartdns 从 install.sh / systemd / 防火墙中移除(见 install.sh cleanup 段);`foreign-cidr.txt` + `gen_foreign_cidr.py` + `render_smartdns_conf.py` + `china-domains.txt` 一并移除。

**决策追加 2026-07-01 — Phase 2:规则集经进程内订阅落地;失败保旧表;chnroute 改订阅;update-lists→reload:**
- **背景**:Phase 1 的四类规则只支持本地手动文件;`china_ip_list.txt` 由 `update-lists.sh` 单独下载。Phase 2 spec(`docs/superpowers/specs/2026-07-01-5gpn-dns-p2-subscriptions-design.md`)把"规则手动添加"升级为订阅系统,现已实现(`cmd/5gpn-dns/subscription.go` + `subscription_test.go` + `controller_test.go`)。
- **实现摘要**:`5gpn-dns` 读取 `/etc/5gpn/subscriptions.json`(env `DNS_SUBSCRIPTIONS`),每条订阅按各自 `interval` 在进程内定时拉取远程 URL,支持 `plain`/`gfwlist`(base64)/`dnsmasq`/`adblock`(ABP)/`hosts` 五种域名格式解析器和 `cidr`(chnroute)解析器,写入 `/etc/5gpn/rules/<category>/<name>.txt`。每类有效集合 = 手动 `<cat>.txt` + 该类全部订阅缓存(glob 合并,`LoadDomainSet`/`LoadChnrouteFiles`)。
- **失败即保旧表(offline-safe)**:拉取失败、解析失败、或条目数低于该类别下限(floor guard)→ 视为失败,保留旧缓存不覆盖,不清空(空表会误伤,如空 chnroute = 全部误判国外)。
- **chnroute 改由订阅提供**:默认 `subscriptions.json` 含一条指向 17mon/china_ip_list 的订阅,取代 Phase 1 里 `update-lists.sh` 直接下载 chnroute 的方式。
- **`update-lists.sh` 降级为 reload 触发器**:不再自己下载任何东西,只 `systemctl reload 5gpn-dns`(SIGHUP 重读磁盘缓存),真正的拉取由进程内定时器完成。
- **沙箱调整**:systemd 单元新增 `ReadWritePaths=/etc/5gpn/rules`,允许订阅管理器写缓存文件(其余 `/etc/5gpn` 仍 `ReadOnlyPaths`)。
- **约定反转(同步改 CLAUDE.md)**:"规则手动添加,Phase 2 前不实现订阅" → Phase 2 完成,订阅与手动文件并存合并生效。
- **Phase 3 承接**:`Controller`(`Subscriptions/AddSubscription/RemoveSubscription/Update/AddRule/RemoveRule/Reload/Stats`)已在 Phase 2 定义并实现,供 Phase 3 的 HTTPS API 直接调用;`Lookup` 留给 Phase 3。
- **保留历史**:Phase 1 "本地文件、手动维护"的规则加载方式保留于 git 历史;回滚 = 不部署 `subscriptions.json`,行为退化为纯 Phase 1。
