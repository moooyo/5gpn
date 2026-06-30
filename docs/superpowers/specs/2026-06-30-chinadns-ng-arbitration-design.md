# 设计:chinadns-ng 仲裁层 —— 确定性"国内 IP 优先"分流

- 状态:已批准方向(工具=chinadns-ng),待 spec 评审
- 日期:2026-06-30
- 范围:在 smartdns **后面**接入 **chinadns-ng** 做 chnroute 仲裁("国内 DNS 答案的 IP 命中中国段才用国内,否则用可信 DoT 上游"),给"两表都不在的混合/未知域名"提供**确定性**的"有国内 IP 就直连、否则走代理"。**取代** 2026-06-30 三层方案里 DNS 大脑的 `nameserver/cnlist` + `ip-rules china_ip -whitelist-ip` 那套(真机验证证明它在 smartdns 里做不到)。sing-box 数据面、DoT 入口、黑名单、`ip-alias`、P0 解析器提示、P2 清理**保留**。
- 关联:[2026-06-30-three-tier-dns-split-design.md](2026-06-30-three-tier-dns-split-design.md)(被本案在 DNS 大脑分流上取代)、[DESIGN.md](../../DESIGN.md)(§4/§5/§12)、test-env 验证记录(`.superpowers/sdd/progress.md`)

---

## 1. 背景:为什么要加一个组件

2026-06-30 的三层方案在 test-env 实测中,**第3层"含国内 IP 就用国内 IP、不测速"被证明 smartdns 做不到**:
- 全局 `ip-rules ip-set:china_ip -whitelist-ip` 是**空转**(同一条含国内+国外 IP 的回答,两个 IP 都留下,没过滤)。
- per-server `-whitelist-ip` 只过滤单个 server 的回答,且 smartdns 跨上游是"**谁先回用谁**"(无测速时 first-response),国内 DNS 慢一点就用了国外答案 → 误走代理。

结论:smartdns **没有**"收集两边答案 → 按 IP geoip → 有国内留国内"的跨上游仲裁能力(官方 issue #575 也确认无 if/else 分组逻辑)。用户要的就是这个确定性逻辑 → 引入专门做这件事的 **chinadns-ng**。

## 2. 既定决策(2026-06-30)

| 决策点 | 选择 | 理由 |
|---|---|---|
| 仲裁工具 | **chinadns-ng**(zfl9,`+wolfssl` 构建) | 专用、静态 musl 二进制满载 ~2.4MB(贴 LOWMEM)、原生 DoT、不用拼插件;对比 mosdns(Go ~7MB+运行时、`fallback` experimental) |
| 拓扑 | chinadns-ng **接在 smartdns 后面**(本机 `127.0.0.1:5301`),作 smartdns 默认上游 | smartdns 保留 DoT 入口/证书/黑名单/`ip-alias`/缓存;仲裁交给 chinadns-ng;无回环 |
| chnroute 载体 | **内核 nftset**(`inet@chinadns@chnroute`) | chinadns-ng 经 netlink 查 nftset(不读纯文本);本机已用 nftables,多一个 set + awk 加载脚本 |
| 域名白名单 | **删除 `china-domains.txt` + cnlist 层** | chinadns-ng 按 IP 仲裁已覆盖 CN/国外判断;回归"不维护大域名表"初衷;纯国内域名多一次并发查询(~数十 ms,可接受) |
| 可信上游 | **DoT**(`tls://dns.google@8.8.8.8#853`、`tls://one.one.one.one@1.1.1.1#853`) | 网关在国内,可信上游必须抗污染(TLS 不可被 GFW 污染) |
| 国内上游 | UDP `223.5.5.5` + `119.29.29.29` | 快;污染由 chnroute 校验兜底(国内答案 IP 不在中国段 → 用可信答案) |
| 版本锁定 | `CHINADNS_VERSION=2025.08.09`(可覆盖) | 最新稳定;`+wolfssl` 资产带 DoT |
| 二进制校验 | 默认不校验,`CHINADNS_SHA256` opt-in | 同 sing-box 约定 |

## 3. 拓扑与请求流

```
客户端 ──DoT:853──> smartdns(127.0.0.1 内部 :5353)
  │
  ├─ 命中黑名单 proxy-domains.txt? → address → __GATEWAY_IP__(强制代理,不解析)
  │
  └─ 其余 → 转发给 chinadns-ng(127.0.0.1:5301)
        │  并发查:国内 UDP(223.5.5.5/119.29.29.29) + 可信 DoT(8.8.8.8/1.1.1.1)
        │  判定:国内答案的 IP ∈ nftset chnroute? → 用国内答案(真实 CN IP)
        │        否则(不在中国段/被污染/GFW 伪 IP) → 用可信 DoT 答案(真实国外 IP)
        ▼
  smartdns 收到 chinadns-ng 的答案,过 ip-rules ip-set:foreign -ip-alias __GATEWAY_IP__
        ├─ CN IP → 不在 foreign 集 → 原样返回 → 客户端直连
        └─ 国外 IP → 改写成网关 IP → 客户端连 sing-box → 代理直出
  (force-AAAA-SOA、缓存 仍在 smartdns)
```

**确定性来源**:chinadns-ng 拿到国内答案后**按 chnroute 成员关系**决定(不是比谁快),国内慢也会等(到超时)。这正是 smartdns 缺的那一步。

## 4. chinadns-ng 配置(仓库 `etc/chinadns-ng/chinadns-ng.conf`)

```ini
bind-addr 127.0.0.1
bind-port 5301
# 国内(明文 UDP)
china-dns 223.5.5.5
china-dns 119.29.29.29
# 可信(DoT,抗污染)
trust-dns tls://dns.google@8.8.8.8#853
trust-dns tls://one.one.one.one@1.1.1.1#853
# chnroute = 内核 nftset(family@table@set)
ipset-name4 inet@chinadns@chnroute
ipset-name6 inet@chinadns@chnroute6
cache 4096
verdict-cache 4096
```

不用 `chnlist-file`/`gfwlist-file`(域名表交给 smartdns 的黑名单 + chnroute IP 判定)。

## 5. nftset 生命周期(新增 `scripts/load-chnroute.sh`)

chinadns-ng 不读纯文本;CIDR 必须灌进内核 nftset。专用表 `inet chinadns`(与防火墙表隔离):

```bash
nft list table inet chinadns >/dev/null 2>&1 || nft -f - <<'NFT'
table inet chinadns {
  set chnroute  { type ipv4_addr; flags interval; }
  set chnroute6 { type ipv6_addr; flags interval; }
}
NFT
nft flush set inet chinadns chnroute
# china_ip_list.txt: 一行一 CIDR(17mon/china_ip_list 已是此格式)
awk 'NF{print "add element inet chinadns chnroute { " $0 " }"}' "$CHINA_IP_LIST" | nft -f -
```

- 调用点:① `install.sh` 装机时;② chinadns-ng.service 的 `ExecStartPre`;③ `scripts/update-lists.sh` 下载 china_ip_list 后(运行时热更,无需重启 chinadns-ng)。
- `flags interval` 必须有,否则 nft 拒绝 CIDR。
- ipv6:本项目 IPv4-only,chnroute6 建空集即可(满足配置引用)。

## 6. smartdns.conf.template 改写(大幅简化)

```ini
# 5gpn smartdns — auto-rendered. DO NOT edit in place.
# 解析+CN/国外仲裁交给 chinadns-ng(127.0.0.1:5301);smartdns 只做入口/黑名单/ip-alias/缓存。
bind-tls [::]:853
bind-cert-file __BIND_CERT__
bind-cert-key-file __BIND_KEY__
bind 127.0.0.1:5353
force-AAAA-SOA yes
cache-size __CACHE_SIZE__
rr-ttl-min 300
rr-ttl-max 86400

# 唯一上游 = chinadns-ng(它做国内/国外仲裁)
server 127.0.0.1:5301

# (黑名单)强制代理:直接返回网关 IP,不解析
domain-set -name blacklist -type list -file __PROXY_DOMAINS_FILE__
address /domain-set:blacklist/__GATEWAY_IP__

# 仲裁后若是国外 IP → 改写成网关 IP → sing-box 代理
ip-set -name foreign -type list -file __FOREIGN_CIDR_FILE__
ip-rules ip-set:foreign -ip-alias __GATEWAY_IP__
```

**删除**:`-group domestic/foreign` 上游、`server-tls` 直连上游、`speed-check-mode`/`dualstack-ip-selection`/`response-mode`、`domain-set cnlist` + `nameserver`、`ip-set china_ip` + `ip-rules china_ip -whitelist-ip`、`conf-file bogus-nxdomain`(抗污染now在 chinadns-ng)。`render_smartdns_conf.py` 占位精简为 `__BIND_CERT__ __BIND_KEY__ __CACHE_SIZE__ __GATEWAY_IP__ __PROXY_DOMAINS_FILE__ __FOREIGN_CIDR_FILE__`。

## 7. 列表与生成(`scripts/update-lists.sh`)

- **保留**:下载 `china_ip_list.txt`;`gen_foreign_cidr.py` → `foreign-cidr.txt`(smartdns ip-alias 用,不变,失败保留旧表)。
- **新增**:下载后调用 `load-chnroute.sh` 热更 nftset。
- **删除**:`china-domains.txt`(felixonmars)下载/提取、`china_ip.conf` 生成、`CHINA_DOMAINS_FILE`/`CHINA_IP_FILE` 渲染参数。
- render 参数相应精简。

## 8. 安装编排(`install.sh`)

- 新增 `install_chinadns()`:下预编译 `+wolfssl` musl 二进制(默认资产 `chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto`,`CHINADNS_VERSION` 可覆盖),`CHINADNS_SHA256` opt-in 校验,装到 `/usr/local/bin/chinadns-ng`;装配置到 `/etc/chinadns-ng/chinadns-ng.conf`;幂等。
- `full_install`:`install_chinadns` + 首次 `load-chnroute.sh`(在 update-lists 之后,确保 china_ip_list 已下载)。
- `start_services`/`show_status` 服务列表加 `chinadns-ng`(在 smartdns **之前**起,smartdns 依赖它)。
- 证书续期不受影响(chinadns-ng 不绑 :80)。P0 的 `SINGBOX_RESOLVER` 提示(sing-box 用,无关)**保留**。
- systemd 单元 `etc/systemd/chinadns-ng.service`:`ExecStartPre=/usr/local/bin/5gpn-load-chnroute`(装机时复制 `load-chnroute.sh` 到此路径)、`ExecStart=/usr/local/bin/chinadns-ng -C /etc/chinadns-ng/chinadns-ng.conf`、`After=nftables.service network-online.target`、`Before=smartdns.service`(若可表达,否则 start_services 顺序保证)。沙箱:`NoNewPrivileges`、`ProtectSystem=strict` 等;**权限待验证**(查 nftset 经 netlink 可能需 `CAP_NET_ADMIN`/`AF_NETLINK`;ExecStartPre 的 `nft` 需要写权限)——test-env 实测后定(参照 sing-box 的 AF_NETLINK 教训)。

## 9. 控制面 / 文档

- `tgbot.py`:`SERVICES += ["chinadns-ng"]`;重启菜单加。黑名单增删不变。
- `docs/DESIGN.md`:§4 改为"smartdns 入口+黑名单+ip-alias / chinadns-ng 按 chnroute 仲裁"模型;§5 抗污染改述(可信 DoT + chnroute 校验);§12 追加决策(三层 IP-whitelist 失败 → 引入 chinadns-ng)。
- `README.md`:关键特性改述为"smartdns + chinadns-ng + sing-box;国内/国外按 chnroute 确定性分流"。
- `CLAUDE.md`:预编译二进制清单加 chinadns-ng(opt-in sha256);组件清单更新。
- `tests/integration-smoke.md`:加 chinadns-ng 仲裁行为验收。

## 10. 测试

- **grep 策略测试**(dev box):新 `tests/test_chinadns_policy.sh` 断言 chinadns-ng.conf(china-dns/trust-dns DoT/ipset-name4)、smartdns.conf.template 新形态(单上游 127.0.0.1:5301、无 cnlist/china_ip/speed-check、保留 blacklist+ip-alias)、load-chnroute.sh(nftset `flags interval` + awk)、install_chinadns、systemd 单元、tgbot SERVICES。改 `test_smartdns_conf_policy.sh`/`test_dns_split_policy.sh` 到新形态(删三层断言)。`test_proxy_policy.sh`/`test_hardening_policy.sh` 视 sing-box 不变。
- **真机(test-env)**:见 §11。

## 11. 真机验证(test-env,确定性是重点)

用 mock 上游(test-env 外网 DNS 被劫持为 198.18.x):
1. **确定性 prefer-CN(最关键)**:mock 国内上游返回 CN IP、可信上游返回国外 IP,**两种时序都测**(国内慢/国外快、国内快/国外慢)→ chinadns-ng 都返回 CN IP(对比 smartdns 的 first-response 翻车)。再测国内只返回国外 IP(不在 chnroute)→ 用可信答案。
2. **端到端**:smartdns → chinadns-ng → 仲裁 → ip-alias:黑名单→网关IP;CN 域名→直连;国外/被墙→网关IP(代理)。
3. **nftset**:`load-chnroute.sh` 建集+灌入;`update-lists` 热更后成员变化;chinadns-ng 重启后 ExecStartPre 重建。
4. **沙箱权限**:确认 chinadns-ng 查 nftset 所需权限(CAP_NET_ADMIN/AF_NETLINK?),单元能起、无权限报错;不足则补并记录(同 sing-box AF_NETLINK)。
5. **DoT 可信上游可达**:test-env 能否直连 8.8.8.8:853(若被墙环境拦,用 mock DoT 或记录为环境限制)。

## 12. 风险 / 取舍

- **多一个组件 + 内核 nftset**:违背"组件最少",但用户为确定性明确接受;footprint 小(~2.4MB)。
- **残留硬伤**:被污染成"看着像 CN"的国外 IP(命中 chnroute)仍会误判直连——和原设计同源,靠黑名单(强制代理)自愈。chinadns-ng 的可信 DoT + chnroute 校验已显著收窄。
- **纯国内域名延迟**:删了域名快路径,每次走 chinadns-ng 并发双查(+数十 ms)。在意可后续加精简快路径表(YAGNI,暂不做)。
- **smartdns ↔ chinadns-ng 启动顺序**:smartdns 上游指向 chinadns-ng,需先起 chinadns-ng(start_services 顺序 + `Before=`)。

## 13. 回滚

- 三层方案与本案均在 git 历史;回滚 = `git revert` 本案 + 恢复三层 smartdns.conf(或更早的 first-ping)。chinadns-ng 二进制/单元/nftset 由 install 卸载逻辑清理(`systemctl disable --now chinadns-ng` + 删单元 + `nft delete table inet chinadns`)。

## 14. 与既有已落地工作的关系

- **取代**:三层 spec 的 DNS 大脑分流(template 三层、china-domains、china_ip、cnlist、update-lists 对应段、相关 grep 断言、DESIGN/README 三层叙述)。
- **保留**:Task 2 的 P0 `SINGBOX_RESOLVER` 装机提示(sing-box SNI 用);Task 3 的 `DOT_RATE/DOT_BURST` 转发 + HANDOFF §3 注记。
- 实现时以"在三层已落地的 main 之上做增量改"为基线(不是从更早 revert)。
