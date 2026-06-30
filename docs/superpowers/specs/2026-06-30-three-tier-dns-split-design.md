# 设计:三层确定性 DNS 分流 + 安装期可指定解析器 + 清理

- 状态:已批准,待实现
- 日期:2026-06-30
- 范围:把 smartdns 的分流从「纯 IP 判定 + first-ping 测速」重构为**显式三层确定性模型**(黑名单只走境外 DNS、白名单只走境内 DNS、其余两边都查且**含国内 IP 即用国内 IP、不测速**);并让 **install.sh 在装机时可交互指定 sing-box 的 SNI 解析器**;附带三项琐碎清理。出口/数据面(sing-box 直出)不变。
- 关联文档:[DESIGN.md](../../DESIGN.md)(§4 决策模型、§5 约束、§12 决策)、[HANDOFF.md](../../HANDOFF.md)、上一次迁移 [2026-06-29-singbox-replace-xray-design.md](2026-06-29-singbox-replace-xray-design.md)

---

## 1. 背景与动机

现状([etc/smartdns.conf.template](../../../etc/smartdns.conf.template)):无域名表,所有上游并发竞速;国内明文上游 `-whitelist-ip` 只收 CN IP;`response-mode first-ping` 按 ping/TCP:443 **测速**选一个最终 IP;再由 `ip-rules ip-set:foreign -ip-alias` 把境外 IP 改写成网关 IP 进代理。

问题(2026-06-30 复核确认):DESIGN §12 声称「只要解析含一个 CN IP 即直连,仅当全部境外才改写」是**硬保证**,但代码只有 `first-ping` **延迟启发式** —— 选 IP 看的是"谁先应答/最快",不是"是不是 CN IP"。混合 CN/境外答案里若境外边缘恰好更快、或国内上游被污染/超时,first-ping 可能选到境外 IP → 被误判成代理(与"选国内"相反)。这是文档与代码的实质性偏差,也是 [integration-smoke.md](../../../tests/integration-smoke.md) 自己标注待调的点。

**用户决策(2026-06-30,经多轮澄清)**:改为显式三层、确定性、**不测速**的分流模型。这是对 DESIGN §12「不维护 chinalist」既定决策的**有意反转**(引入一张自动更新的大陆域名白名单),记法沿用此前 sniproxy→xray→sing-box 的反转条目。

附带本次一并做:**P0** 安装期可指定解析器(把当前隐藏的 `SINGBOX_RESOLVER` 抬到装机交互),**P2** 三项清理。

---

## 2. 既定决策(2026-06-30)

| 决策点 | 选择 | 理由 |
|---|---|---|
| 分流模型 | **显式三层**(黑名单/白名单/默认) | 用户指令;要确定性而非延迟启发式 |
| 第3层选 IP | **`ip-rules ip-set:china_ip -whitelist-ip` 内容过滤,不测速** | smartdns 官方语义:答案含白名单(CN)IP 时只保留 CN,否则整份境外放行;对**合并后**答案过滤,与应答先后无关 → 确定性(见 §6) |
| 测速 | **`speed-check-mode none` + `dualstack-ip-selection no`**,删 `response-mode first-ping` | 用户明确"不需要测速";选择交给 china_ip 内容过滤 |
| 黑名单落地 | **`address /domain-set:blacklist/网关IP`(不解析,沿用 proxy-domains.txt)** | 用户选 A:最稳,被污染也必走代理,不依赖解析成功 |
| 白名单源 | **felixonmars `accelerated-domains.china`**(~8 万条),自动更新 | 业界标准大陆域名表;并入现有 update-lists 拉取链路 |
| 白名单管理 | **仅自动生成,暂不接 tgbot**(YAGNI) | 大表自动维护;运维仍只管黑名单。后续可加 |
| 列表命名 | 黑名单仍用 `proxy-domains.txt`(概念=黑名单),白名单新增 `china-domains.txt` | 避免改名 churn,tgbot 增删逻辑不动 |
| 反转 §12 | 记录"引入 chinalist"反转条目,保留旧决策不删 | 沿用既有反转记法 |
| smartdns 版本 | **确保安装 2024+ 构建**(`SMARTDNS_VERSION` 钉) | 规避旧版"境外全超时 + 境内非 CN"长缓存空结果坑(2024 已修,见 §6) |
| P0 解析器 | **装机 Gum 提示(默认 22.22.22.22),仅提示不拦** | 用户选"仅提示不拦":无可达性探测、无警告;非 TTY/CI 回退 env/默认 |

---

## 3. 分流模型与 smartdns 配置

[etc/smartdns.conf.template](../../../etc/smartdns.conf.template) 重写为下述骨架(`__...__` 由 [render_smartdns_conf.py](../../../scripts/render_smartdns_conf.py) 替换):

```ini
# 5gpn smartdns — auto-rendered from smartdns.conf.template. DO NOT edit in place.
# Loop-avoidance: sing-box MUST resolve via 22.22.22.22 (or SINGBOX_RESOLVER), NEVER this smartdns.

# ---- Ingress: DoT only (853). Plaintext 53 is localhost-internal only. ----
bind-tls [::]:853
bind-cert-file __BIND_CERT__
bind-cert-key-file __BIND_KEY__
bind 127.0.0.1:5353

# ---- IPv4-only ----
force-AAAA-SOA yes

# ---- Cache / TTL ----
cache-size __CACHE_SIZE__
rr-ttl-min 300
rr-ttl-max 86400

# ---- No latency probing: selection is by IP content (china_ip whitelist), not speed ----
speed-check-mode none
dualstack-ip-selection no

# ---- Two upstream groups; BOTH in the default group so tier-3 names query both ----
server 223.5.5.5   -group domestic
server 119.29.29.29 -group domestic
server-tls 8.8.8.8 -host-name dns.google -group foreign
server-tls 1.1.1.1 -group foreign

# Known ISP/GFW bogus-NXDOMAIN poison addresses -> SOA. Operator-editable.
conf-file __BOGUS_NXDOMAIN_FILE__

# ---- (Tier 1) Blacklist domains -> gateway IP, no resolution (force proxy) ----
domain-set -name blacklist -type list -file __PROXY_DOMAINS_FILE__
address /domain-set:blacklist/__GATEWAY_IP__

# ---- (Tier 2) Whitelist (mainland) domains -> domestic group only -> direct ----
domain-set -name cnlist -type list -file __CHINA_DOMAINS_FILE__
nameserver /domain-set:cnlist/domestic

# ---- (Tier 3) Neither list: query both groups; prefer China IP if present (no speed test) ----
ip-set   -name china_ip -type list -file __CHINA_IP_FILE__
ip-rules ip-set:china_ip -whitelist-ip
# Any IP NOT preferred-as-China above and in 'foreign' -> rewrite to gateway IP -> proxy
ip-set   -name foreign -type list -file __FOREIGN_CIDR_FILE__
ip-rules ip-set:foreign -ip-alias __GATEWAY_IP__
```

**三类域名的落地:**

| 层 | 命中 | DNS 行为 | 结果 |
|---|---|---|---|
| 1 黑名单 | `proxy-domains.txt` | `address` 直接返回网关 IP(不解析) | → sing-box → 代理 |
| 2 白名单 | `china-domains.txt` | `nameserver .../domestic` 只问境内组 → CN IP | 不在 foreign → 直连 |
| 3 其余 | 都不在 | 默认组(境内+境外)都查;`ip-rules china_ip -whitelist-ip` 选 IP | 含 CN→留 CN→直连;无 CN→境外→`ip-alias`→代理 |

**两条 ip-rules 组合无歧义**(触发条件互斥):合并答案含 CN IP → `china_ip -whitelist-ip` 触发,只留 CN、丢境外 → 直连,`foreign -ip-alias` 无境外可匹配;答案无 CN → 白名单过滤不触发、整份境外放行 → `foreign -ip-alias` 全改写成网关 IP → 代理。

**分组语义**:境内/境外服务器各带 `-group`,均**不加** `-exclude-default-group`,故都在默认组里 → 第3层(走默认组)两边都查;第2层 `nameserver /domain-set:cnlist/domestic` 只命中境内组;第1层 `address` 不发起查询。`response-mode` 不参与选 IP(选择交给 `china_ip` 内容过滤)。

> **去掉了** 旧的 per-server `-whitelist-ip` 与 `china-whitelist.conf`:全局 `ip-rules ip-set:china_ip -whitelist-ip` 过滤**合并后**答案,严格覆盖 per-server 版的效果(官方与社区均以全局形式为首选,见 §6),故合并为一张 `china_ip` ip-set。

---

## 4. 列表生成与更新([scripts/update-lists.sh](../../../scripts/update-lists.sh))

沿用现有"下载到 `.tmp` → 成功才 `mv` → 失败保留旧表 → 最小条目数守卫 → 原子写"的安全模式。需要的列表:

| 文件 | 用途 | 来源 / 生成 | 状态 |
|---|---|---|---|
| `proxy-domains.txt` | 第1层黑名单 domain-set | 运维/tgbot 管(小表) | 不变 |
| `china-domains.txt` | 第2层白名单 domain-set | **新增**:下 felixonmars `accelerated-domains.china.conf`,`sed 's\|^server=/\(.*\)/.*\|\1\|'` 提取域名,去重 | 新增 |
| `china_ip.conf` | 第3层 china_ip ip-set(CIDR) | **新增**:= 下载的 `china_ip_list.txt`(已是一行一 CIDR),直接装入 | 新增(替代 `china-whitelist.conf`) |
| `foreign-cidr.txt` | foreign ip-set(反集) | [gen_foreign_cidr.py](../../../scripts/gen_foreign_cidr.py) 由 china_ip_list 反算 | 不变 |
| `bogus-nxdomain.conf` | 污染 IP → SOA | 仓库内置,运维可编辑 | 不变 |

- `china-domains.txt` 守卫:提取后条目数 < 一个下限(如 10000)则视为下载/解析失败,**保留旧表**(空白名单会让大量国内域名退回第3层,虽不致命但失确定性)。
- `china_ip.conf` 与 `foreign-cidr.txt` 同源(china_ip_list),保持现有 < 100 条拒跑 + 原子写。
- 渲染占位变更:[render_smartdns_conf.py](../../../scripts/render_smartdns_conf.py) 新增 `__CHINA_DOMAINS_FILE__`、`__CHINA_IP_FILE__`;移除 `__CHINA_WHITELIST_FILE__`;其余不变。`render` 仍在残留 `__PLACEHOLDER__` 时 exit 1。

---

## 5. 正确性约束(对应 DESIGN §5)

1. **防回环不变**:本变更只动 DNS 大脑的分流逻辑,sing-box 数据面/解析器(22.22.22.22)不动。
2. **第3层确定性**:选 IP 由 `china_ip` 内容过滤决定,**与上游应答先后无关**(§6)。`speed-check-mode none` 确保无测速重排。
3. **生成失败不清空**:任一列表(china-domains / china_ip / foreign-cidr)生成失败一律保留旧表,绝不清空 —— 空 `foreign` 会把全部判国内→直连;空 `china_ip` 会让第3层失去 CN 优先→混合域名可能误代理;空 `cnlist` 让白名单域名退回第3层。
4. **残留硬伤(仍在,已记录)**:被污染成"看着像 CN"的境外域名(不在黑名单、第3层)→ `china_ip` 误判为含 CN → 直连 → 打不开。兜底:补进黑名单(`address`→必代理)自愈。这是 IP 判定派的固有边界,白名单覆盖不到的域名仍受此影响。

---

## 6. 调研证据(smartdns 机制,带引用)

第3层"含 CN 即用 CN、不测速"经独立调研确认**可在单实例 smartdns 干净、确定性地表达**,是社区公认的「国内 IP 优先(不测速)」惯用法:

- **`whitelist-ip` 官方语义**:*"When the filtering server responds IPs in the IP whitelist, only result in whitelist will be accepted."* —— **仅当答案含白名单内 IP 时触发**,此时只保留白名单(CN)结果;否则整份(境外)答案放行。对**合并后**的多组答案做内容过滤,**与哪个组先应答无关** → 非 `response-mode` 竞速,确定性成立。官方配置参考:<https://pymumu.github.io/smartdns/en/configuration>
- **生产案例**:`ip-rules ip-set:all_china_ip -whitelist-ip` 用于"国内 IP 优先",见 [pymumu/smartdns#1552](https://github.com/pymumu/smartdns/issues/1552)。
- **已知坑 + 修复**:旧版在"境外上游全超时 **且** 境内答案非 CN(被白名单清空)"时会长缓存空/NXDOMAIN 结果;pymumu 于 **2024-01** 优化缓存(失败结果不再长缓存)。→ §2 钉 2024+ 构建。
- **避免 response-mode 近似**:`fastest-response`/`first-ping` 都是 timing/测速,会在境内慢跳时回境外 IP,**不用**于 CN 优先。
- **smartdns 无 else 分支**(仅显式分组路由),见 [pymumu/smartdns#575](https://github.com/pymumu/smartdns/issues/575) —— 正因此第3层必须用 IP 内容过滤而非域名路由实现。

> 实现期仍需在 test-env 实测两条 ip-rules 的组合次序与分组成员是否如上(§9 验收),把"配置能否如设想生效"消除在写完之前。

---

## 7. 系统集成

### P0 · install.sh 装机指定解析器([install.sh](../../../install.sh))
- 在装机流程(域名/IP 收集附近)加一个 Gum 提示:`SNI 解析器 [22.22.22.22]:`,默认 `22.22.22.22`,持久化到 `/etc/5gpn/`(如 `.singbox_resolver`)。
- 取值优先级:`SINGBOX_RESOLVER` env > 交互输入 > 默认。**仅提示不拦**:不做 DNS 可达性探测、不警告占位默认;非 TTY/CI 直接用 env/默认。
- 沿用现有 `ask_text … || true` 取消保护;复用现有 sentinel→实际值的 sed patch 链路(只改安装副本 `/usr/local/etc/sing-box/config.json`),逻辑不新增、只把取值抬到交互。
- `--help` env 列表补 `SINGBOX_RESOLVER`(已在;确认可见)。

### smartdns 版本钉
- 现状 [install.sh](../../../install.sh) `install_smartdns()`:**先试发行版包**(`apt-get install smartdns`),装不上再下 **pymumu 最新 release**(`releases/latest`)。发行版包可能偏旧、缺 §6 的 2024 空结果缓存修复。
- 落地:实现期先在 test-env 查 Debian trixie 发行版 `smartdns --version`;若 < 2024(无该修复)则把 `install_smartdns` 改为 **release-first**(优先 pymumu latest,发行版兜底),保证拿到含修复的构建。distro-first 已 signature-verified,reorder 后 release 路径保留 `SMARTDNS_SHA256` opt-in。

### 控制面([tgbot.py](../../../tgbot.py))
- 黑名单增删(=proxy-domains.txt)机制不变;仅把面向用户的措辞从"强制代理域名"对齐到"黑名单"。白名单暂不接管理。

### P2 · 清理
- [etc/smartdns.conf.template](../../../etc/smartdns.conf.template) 头注释 `xray`→`sing-box`(本次重写顺带)。
- `DOT_RATE`/`DOT_BURST` 在 install.sh `--help` 暴露,并经 `run_setup_firewall` 转发给 [scripts/setup-firewall.sh](../../../scripts/setup-firewall.sh)。
- [docs/HANDOFF.md](../../HANDOFF.md) §3 标注 ios-http 的 chunked/解压炸弹条目已随 api-server.py 移除(说明性,非代码)。

---

## 8. 文档与测试

- **[etc/smartdns.conf.template](../../../etc/smartdns.conf.template)**:按 §3 重写。
- **[scripts/update-lists.sh](../../../scripts/update-lists.sh)** / **[render_smartdns_conf.py](../../../scripts/render_smartdns_conf.py)**:按 §4 改(新列表 + 新占位)。
- **[tests/test_smartdns_conf_policy.sh](../../../tests/test_smartdns_conf_policy.sh)**:断言新形态 —— 三层指令存在(`address /domain-set:blacklist/网关IP`、`nameserver /domain-set:cnlist/domestic`、`ip-rules ip-set:china_ip -whitelist-ip`、`ip-rules ip-set:foreign -ip-alias`)、`speed-check-mode none`、无 `response-mode first-ping`、无公网 :53 bind、无残留占位;update-lists dry-run 生成 china-domains/china_ip/foreign-cidr 且非空。
- **新增 grep 策略断言**(可在 Windows/Git Bash 跑):分组 `-group domestic`/`-group foreign`、两条 ip-rules、两个 domain-set。
- **[tests/integration-smoke.md](../../../tests/integration-smoke.md)**:加三层行为验收项(见 §9)。
- **[docs/DESIGN.md](../../DESIGN.md)**:改 §4 分流模型为三层;§12 追加"引入 chinalist"反转决策条目(保留旧"不维护 chinalist"条目),更新残留风险措辞。
- **[README.md](../../../README.md)**:关键特性段从"无需维护大域名表"改述为三层模型(黑/白名单 + 第3层 CN 优先)。

---

## 9. 风险 / 待 Linux 验证(test-env)

实现期在 **test-env**(见 [CLAUDE.md](../../../CLAUDE.md))验证(纯 grep 测试在 Windows 跑;以下是运行时门):
1. **第3层选 IP**:构造一个同时有 CN 与境外 A 记录的名字(或用 `address` 注入测试),确认 smartdns 返回 CN IP(直连),去掉 CN 记录后返回境外→`ip-alias`→网关 IP(代理)。验证两条 ip-rules 次序与分组成员如 §3。
2. **白名单**:`cnlist` 内域名只问境内组(`tcpdump`/日志确认不发境外 DoT),得 CN IP 直连。
3. **黑名单**:`proxy-domains.txt` 内域名返回网关 IP(不解析)。
4. **`sing-box check` + smartdns 启动**:渲染后的 conf 能正常加载(缺 include/坏指令会中止启动)。
5. **smartdns 版本**:确认 ≥2024 构建,空结果不长缓存(§6 坑)。
6. **P0 解析器**:装机提示→持久化→sing-box 配置被 patch 为所填值;留默认时 sing-box check 仍 OK。
7. **列表更新**:`update-lists.sh` 拉 felixonmars + china_ip_list,提取/守卫/原子写正常;断网时保留旧表。
- 已知取舍:白名单 ~8 万条域名表(domain-set 内存可控);第3层残留"伪 CN 污染"硬伤仍在(§5.4),靠黑名单自愈。

---

## 10. 回滚

- 旧 `smartdns.conf.template`(first-ping 模型)与 `china-whitelist.conf` 生成逻辑保留于 git 历史;失败可 `git revert` 回到纯 IP 判定 + first-ping。
- 新增的 `china-domains.txt` / `china_ip.conf` 列表与 sing-box 数据面无关,回滚只影响 DNS 大脑分流。
