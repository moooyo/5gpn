# 设计:5gpn-dns(自研 Go DNS 网关)—— 分阶段

- 状态:Phase 1 待 spec 评审(总体方向已批准:自研 Go、淘汰 smartdns+chinadns-ng、四类规则、订阅、公开 API+Web UI、分阶段、Web UI 与 tgbot 并存)
- 日期:2026-06-30
- 范围(总):用自研 Go 二进制 `5gpn-dns` 取代 smartdns + chinadns-ng,做 DNS 大脑:DoT 入口、**四类规则**(广告拦截 / 强制直连白名单 / 强制代理黑名单 / chnroute)、**确定性 chnroute 仲裁**、国外→网关IP、缓存;规则集走**订阅**(远程 URL 自动更新);暴露**公开 API + Web UI** 做查询与控制(与 tgbot 并存)。sing-box 数据面不变。
- 关联(被本案取代):[2026-06-30-three-tier-dns-split-design.md](2026-06-30-three-tier-dns-split-design.md)、[2026-06-30-chinadns-ng-arbitration-design.md](2026-06-30-chinadns-ng-arbitration-design.md);[DESIGN.md](../../DESIGN.md)(§2/§4/§5/§12 重写)

---

## 0. 分阶段总览(每阶段独立 spec→plan→实现→验收)

| 阶段 | 内容 | 交付 |
|---|---|---|
| **Phase 1(本 spec)** | `5gpn-dns` 引擎核心:DoT 入口+证书热加载、四类规则(**本地文件**加载)、确定性仲裁、国外→网关IP、AAAA→SOA、广告拦截、缓存、SIGHUP 重载。取代 smartdns+chinadns-ng。CI 构建。 | 能部署的 DNS 大脑;**确定性仲裁真机验收**(最高风险项先落地) |
| Phase 2(后续 spec) | 订阅系统:四类规则各订阅远程 URL(纯域名/CIDR、gfwlist-base64、adblock/hosts),定时+按需拉取、与手动条目合并、落盘缓存、断网保留旧表 | 规则从"手动/文件"升级为"订阅" |
| Phase 3(后续 spec) | 公开 HTTPS API(token 鉴权,复用 LE 证书)+ Web UI:查询(判定/解析/统计)、控制(管订阅/规则、触发更新、reload);**tgbot 改为调同一 API,与 Web UI 并存** | API + Web 控制台 |

**约定推翻(评审知悉,实现时改 CLAUDE.md):** ① "控制面只有 tgbot、无 HTTP API/web UI" → 有意重新引入公开 API + Web UI(P3);② 规则"手动添加" → 订阅(P2)。Phase 1 不碰这两条的实现,但**架构按它们预留接缝**(见 §6 前向兼容)。

> 本 spec 之后的 §1-§12 仅描述 **Phase 1**。

## 1. 背景

三层方案 test-env 实测证明 smartdns 做不到"含国内 IP 即用国内、不测速";chinadns-ng 能做但带内核 nftset + 多组件。用户决策自研 Go DNS 把逻辑收进一个进程,并扩成带订阅 + Web UI 的自有网关。Phase 1 先把**引擎 + 确定性仲裁**做扎实(逻辑窄、风险高的部分),订阅/API/UI 后续叠加。

## 2. 既定决策(Phase 1)

| 决策点 | 选择 | 理由 |
|---|---|---|
| 语言/库 | Go + `github.com/miekg/dns`(唯一第三方依赖) | DoT/解析/EDNS/TCP 交给成熟库;chnroute/缓存/规则匹配 stdlib 手写 |
| 取代范围 | smartdns + chinadns-ng 全淘汰 | 用户指令 |
| 规则类别 | **四类**:adblock、force-direct(白名单)、blacklist(强制代理)、chnroute | 用户选定的订阅四类;P1 先本地文件加载 |
| 仲裁 | 国内 UDP + 可信 DoT 并发,**国内答案 IP∈chnroute 才用国内,否则用可信**;按成员关系判,不测速、不看谁先回 | 确定性;smartdns 缺的就是这步 |
| chnroute 语义 | 命中=国内(直连);**未命中=国外→网关IP** | 不再需要 foreign-cidr 反集,只留 china_ip_list 正集 |
| DoT 入口 | `5gpn-dns` 自监听 :853(LE 证书,`GetCertificate` 按 mtime 热加载) | smartdns 没了,DoT 由本程序提供;续期不重启 |
| 分发 | CI 交叉编译 linux-amd64 静态(`CGO_ENABLED=0`)→ `moooyo/5gpn` release;install 下载 | 守"盒子无工具链";验证期 dev box 交叉编译+scp |
| 配置 | env/flags(install 注入)+ 规则文件;无配置模板 | 去掉 smartdns.conf.template + render_smartdns_conf.py |
| 版本/校验 | `DNS_VERSION` 钉、`DNS_SHA256` opt-in | 同 sing-box |

## 3. 总体架构(请求流)

```
客户端 ──DoT:853──> 5gpn-dns(Go)
   │  per query(precedence 自上而下):
   │  1) AAAA→SOA;HTTPS/SVCB(65)→空 NOERROR;其余非 A → 透传可信 DoT verbatim
   │  2) 命中 adblock 域名表 → NXDOMAIN(拦截)
   │  3) 命中 force-direct 白名单 → 仲裁解析,返回真实 IP,**跳过国外→网关改写**(强制直连)
   │  4) 命中 blacklist 黑名单 → A=__GATEWAY_IP__(强制代理,不解析)
   │  5) 其余 → chnroute 仲裁:
   │        并发 国内UDP(223.5.5.5/119.29.29.29) + 可信DoT(1.1.1.1/8.8.8.8)
   │        国内答案含 IP∈chnroute? → 用国内答案;否则 → 用可信答案
   │        → 改写:每个 IP∈chnroute 保留(直连),否则→__GATEWAY_IP__(代理);去重
   │  → 缓存(TTL 钳制)→ 答
   ▼
  CN IP(客户端直连) / 网关IP(连 sing-box → 代理直出) / NXDOMAIN(广告)
  (网关IP 流量 → sing-box 数据面,不变)
```

**确定性**:第5步按 chnroute 成员关系判,不看谁先回(国内慢也等到超时)。**优先级**:adblock > force-direct > blacklist > 默认仲裁;同一域名既在 force-direct 又在 blacklist 时,**force-direct(直连)优先**(显式 allow > deny),并记录。

## 4. 四类规则(Phase 1:本地文件;Phase 2 接订阅)

| 类别 | 文件(`/etc/5gpn/rules/`) | 匹配 | 命中行为 |
|---|---|---|---|
| adblock | `adblock.txt`(域名) | 域名后缀 | NXDOMAIN |
| force-direct | `direct.txt`(域名) | 域名后缀 | 仲裁解析,返回真实 IP,不改写 |
| blacklist | `blacklist.txt`(域名;= 旧 proxy-domains) | 域名后缀 | A=网关IP |
| chnroute | `china_ip_list.txt`(CIDR) | IP∈集合 | 决定直连/改写 |

- 每类 = "**规则集**":加载一组源文件 → 内部 matcher。Phase 2 的订阅只是往这组源文件里多塞几份(订阅缓存文件)+ 触发 reload —— P1 把这个接缝留好(每类从一个目录/文件列表加载,而非写死单文件)。
- 域名匹配:后缀/父域命中(`a.b.example.com` 命中 `example.com`)。
- `china_ip_list.txt` 仍由 `update-lists.sh` 远程刷新(P2 纳入统一订阅)。
- 黑名单更名 `blacklist.txt`(tgbot/install 的 proxy-domains 引用相应改;或保留 proxy-domains.txt 作为 blacklist 源之一——实现时定,倾向更名 + 兼容)。

## 5. 取代 / 保留 / 删除

**删除**:`install_smartdns`、`etc/smartdns.conf.template`、`render_smartdns_conf.py`、smartdns 单元/安装/续期/服务分支;`gen_foreign_cidr.py`+`foreign-cidr.txt`;三层/chinadns 方案的 china-domains/china_ip/cnlist/nftset;`test_smartdns_conf_policy.sh`/`test_dns_split_policy.sh`。
**保留**:sing-box(数据面 + P0 `SINGBOX_RESOLVER` 提示);`china_ip_list.txt`;`proxy-domains.txt`(→ blacklist 源);certbot 签发/续期(renew-hook 改为拷证书,5gpn-dns 热加载);防火墙(:853 + sing-box 端口);iOS profile;tgbot(SERVICES 改 5gpn-dns;P3 再接 API);install 编排骨架。

## 6. `5gpn-dns` 程序设计(`cmd/5gpn-dns/`)

**输入(env/flags;install 注入)**:`DNS_LISTEN_DOT=:853`、`DNS_LISTEN_PLAIN=127.0.0.1:5353`、`DNS_CERT`/`DNS_KEY`(热加载)、`DNS_GATEWAY_IP`、`DNS_CHINA=223.5.5.5,119.29.29.29`(UDP)、`DNS_TRUST=1.1.1.1,8.8.8.8`(DoT)、`DNS_RULES_DIR=/etc/5gpn/rules`、`DNS_CHNROUTE`、`DNS_CACHE_SIZE`、`DNS_TTL_MIN=300`/`MAX=86400`、`DNS_QUERY_TIMEOUT=5s`。

**handler**:按 §3 优先级;仲裁 = 并发两组、国内取首成功、可信取首成功,等国内到 timeout 判 `chinaIsCN`,`final=chinaIsCN?国内A:可信A`,再 `map(IP): IP∈chnroute?IP:GATEWAY_IP` 去重。

**子模块(都为 P2/P3 预留接缝)**:
- **RuleSet 抽象**:`type RuleSet interface{ Match(...) bool; Reload() error }`;每类从 `DNS_RULES_DIR/<cat>/*.txt`(或单文件)加载。P2 订阅写文件 + 调 `Reload`;P3 API 增删手动条目 + 触发 `Reload`。
- **chnroute**:CIDR→`uint32` 区间排序合并 + 二分;`Reload` 重载。
- **cache**:并发安全 TTL map + 容量上限;P3 暴露统计。
- **cert**:`GetCertificate` 按 mtime 重读。
- **control 接缝**:内部 `Controller`(reload/lookup/stats 方法),Phase 1 由 `SIGHUP`(reload)驱动;P3 的 API 直接调 `Controller`(不改引擎)。
- **依赖**:仅 `miekg/dns` + stdlib;`go.mod` 锁版本。

**防回环**:上游恒外部;不查自身。

## 7. 安装 / 运维(`install.sh`)

`install_5gpndns()`(下预编译二进制,`DNS_VERSION`/`DNS_SHA256`)→ `/usr/local/bin/5gpn-dns`;`full_install` 用它取代 `install_smartdns`,证书→`/etc/5gpn/cert`、规则→`/etc/5gpn/rules/`;移除旧 smartdns。systemd `etc/systemd/5gpn-dns.service`:`EnvironmentFile=/etc/5gpn/dns.env`、`User=root`(绑:853)、沙箱(`NoNewPrivileges`/`ProtectSystem=strict`/`RestrictAddressFamilies=AF_INET AF_UNIX`/`ReadOnlyPaths`),**权限/AF test-env 实测**。`start_services`/`show_status`:smartdns→5gpn-dns;续期 deploy hook 拷证书 + `kill -HUP`(或热加载);`--update-lists` 刷 china_ip_list + SIGHUP;`--add/del-domain` 改 blacklist 文件 + SIGHUP。

## 8. 构建 / 发布(新基础设施)

源码 `cmd/5gpn-dns/` + `go.mod`/`go.sum`。`.github/workflows/release.yml`:tag `dns-vX.Y.Z` → `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build` → 上传 `5gpn-dns-linux-amd64` + `checksums.txt`。`ci.yml` 加 `go vet` + `go test ./...`。验证期 dev box 交叉编译产物 scp。

## 9. 测试

- **Go 单测(CI + dev box)**:四类规则匹配(adblock/direct/blacklist 后缀、chnroute 区间边界)、优先级(direct>blacklist 冲突)、AAAA→SOA、HTTPS(65)→空、仲裁(注入假上游:国内CN/国内污染/国内超时/仅国外)、国外→网关改写+去重、TTL 钳制、缓存命中/过期。
- **grep 策略(dev box)**:`install_5gpndns`、`5gpn-dns.service`、tgbot SERVICES、update-lists SIGHUP、无残留 smartdns/chinadns。
- **真机(test-env)**:§10。

## 10. 真机验证(test-env)

dev box 交叉编译→scp;mock 上游:
1. **确定性 prefer-CN(最关键)**:国内 mock=CN、可信=国外,**两种时序都测**→ 都返回 CN;国内仅国外 IP→用可信;国内超时→用可信。
2. 四类规则:adblock→NXDOMAIN;direct→真实 IP 不改写;blacklist→网关IP;默认→chnroute 直连/改写。
3. DoT 入口(自签证书)`dig +tls` 通;**证书热加载**(换文件→新握手用新证书,不重启)。
4. AAAA→SOA、HTTPS(65)→空;缓存;`SIGHUP` 重载规则。
5. 沙箱权限充分性(不足补,记录,同 sing-box AF_NETLINK 教训)。

## 11. 风险 / 取舍

- 自有网络面 DNS 服务(安全/维护面)——逻辑窄、本地监听、成熟库担难点。
- 新 CI 构建链(首次自产二进制)。
- 残留硬伤(伪 CN 污染)同源,靠 blacklist 自愈;可信 DoT+chnroute 已收窄。
- 纯国内域名并发双查(+数十 ms),P1 靠缓存缓解;域名快路径 YAGNI。
- **范围**:这是大改 + 后续 P2/P3 还要叠;P1 已是可独立交付的完整 DNS 大脑。

## 12. 回滚 / 关系

- 回滚 = `git revert` + 恢复 smartdns。`5gpn-dns` 卸载:disable + 删二进制/单元。
- **取代**:main 上三层方案全部 DNS-大脑件 + 未落地 chinadns 方案。**保留**:Task 2 P0 提示、Task 3 DOT_RATE 转发、sing-box 全部。实现基线 = 当前 main 之上增量。
