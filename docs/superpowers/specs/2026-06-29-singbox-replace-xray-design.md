# 设计:xray-core → sing-box(透明 SNI/QUIC 转发层全量替换)

- 状态:已批准,待实现
- 日期:2026-06-29
- 范围:用 **sing-box**(SagerNet/sing-box)的 `direct` inbound + route `sniff`/`resolve` action 替换 xray-core 的 `dokodemo-door` + sniffing,作为 TCP(80/443)与 QUIC(UDP 443)的 SNI 透明转发层;**直出不变,行为契约完全一致**。
- 关联文档:[DESIGN.md](../../DESIGN.md)(§5 正确性约束、§6 数据流、§8 出口、§12 决策)、上一次迁移 [2026-06-28-xray-replace-sniproxy-design.md](2026-06-28-xray-replace-sniproxy-design.md)

---

## 1. 背景与动机

现状:网关用 **xray-core** 的 `dokodemo-door` + sniffing 做 TCP(80 读 HTTP Host,443 读 TLS SNI)与 QUIC(UDP 443 sniff quic)的字节级 SNI 透明转发,解析器 hardcode `22.22.22.22` 防回环,freedom `ForceIPv4` 直出。这套是 2026-06-28 刚从 sniproxy 迁过来的。

动机:**用户直接指令**改用 sing-box。本次调研(见会话记录)的技术结论是:对"嗅探 SNI 直出"这个窄场景,sing-box 与 xray 功能等价、无新增能力,且带来配置 churn、内存占用更高、二进制校验路径不同等代价;但用户在知悉这些权衡后仍明确选择 sing-box。本设计因此以**功能完全对等**为目标,把代价控制到最小,并把决策与理由固化下来。

这是一次**明确推翻既有约定**的变更,需同步改文档:
- [CLAUDE.md](../../../CLAUDE.md) 现有 "No exit layer" 一条把 **sing-box 列为禁止项**(原因是它常用于搭多出口隧道)。本次把 sing-box 从禁止清单**移除**(它现在是透明转发层),但**保留**禁止真正的出口层构件(WireGuard / multi-exit / fwmark / `ip rule` / `table 100`)。
- [CLAUDE.md](../../../CLAUDE.md) "Prebuilt binaries + sha256 verify" 一条:sing-box **不做强制 sha256 校验**(用户决定),改为可选 opt-in。

## 2. 既定决策(2026-06-29)

| 决策点 | 选择 | 理由 |
|---|---|---|
| 范围 | 全量替换 + 行为对等 | 用户指令;保 QUIC、保直出、保防回环,端到端三类流量路径不变 |
| 迁移方式 | **直接替掉 xray**(二选一,无并存开关) | 与上次 sniproxy→xray 一致;回滚靠 git 历史。并存会让 install/防火墙/测试维护两套路径 |
| 版本锁定 | **pin `1.13.14`**(`SINGBOX_VERSION` 可覆盖),config 按 1.12+ 新语法写 | 锁最新稳定版;config 格式版本敏感,统一写 1.12+(typed DNS + rule-action) |
| 二进制校验 | **默认不校验**,保留可选 `SINGBOX_SHA256` opt-in(非致命) | 用户决定。sing-box 无 `.dgst` 旁文件,只有 release API JSON 内嵌 digest;不强制即免去这段脆弱逻辑 |
| 透明转发入站 | **`direct` inbound**(普通监听口),**不引入** tproxy/redirect/tun | 流量本就被 smartdns 改写成网关 IP 汇入,无需内核 TPROXY/fwmark;沿用"DNS 层做重定向"的架构,不触碰 no-exit-layer 红线 |
| 防回环解析 | 单个 typed UDP DNS server 指向 `22.22.22.22` + `route.default_domain_resolver` 引用它 | 等价 xray `dns.servers=["22.22.22.22"]`;只配一个外部 server,sing-box 无路径回查本机 smartdns |
| 嗅探失败兜底 | `resolve` 前置 + `ip_is_private` reject + **注入自身 IP 的 `ip_cidr` reject** | sing-box 1.13 移除了 inbound `override_address`,sniff 失败会保留原始目的(=网关自身 IP),需显式 reject 才能等价 xray 的"占位 127.0.0.1→blackhole" |
| 权限模型 | `User=root` + systemd sandbox 照搬 | 与 xray 一致;sing-box 同样需绑低口、无内置降权 |

## 3. 数据面:sing-box 配置

仓库提交的 `etc/sing-box/config.json` **本身就 `sing-box check`-valid**:解析器默认 `22.22.22.22`,自身 IP reject 规则提交时填一个无害 sentinel `127.0.0.2/32`(未被 patch 时只匹配 loopback,无害)。install.sh 在安装时把这两处改写为运维实际值(详见 §7):

```jsonc
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [ { "type": "udp", "tag": "ext", "server": "22.22.22.22" } ],
    "final": "ext",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    { "type": "direct", "tag": "in443", "listen": "0.0.0.0", "listen_port": 443 },
    { "type": "direct", "tag": "in80",  "listen": "0.0.0.0", "listen_port": 80, "network": "tcp" }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "default_domain_resolver": { "server": "ext" },
    "rules": [
      { "action": "sniff",   "sniffer": ["tls", "quic", "http"], "timeout": "300ms" },
      { "action": "resolve", "strategy": "ipv4_only", "server": "ext" },
      { "ip_is_private": true, "action": "reject", "method": "drop" },
      { "ip_cidr": ["127.0.0.2/32"], "action": "reject", "method": "drop" }
    ],
    "final": "direct"
  }
}
```

> 上面这份与 §6 在 test-env 实测 `CHECK_OK` 的配置**结构完全一致**(实测时 `ip_cidr` 用的是 test-env 自身 `10.0.1.20/32`,sentinel 只是 `ip_cidr` 取值不同)。

行为:`direct` inbound 收到连接 → route rule `action:sniff` 从首包提取域名(TLS SNI / QUIC Initial SNI / HTTP Host)并默认改写连接目的为该域名(1.11+ sniff 默认即 override,等价 xray `destOverride`)→ `action:resolve strategy:ipv4_only` 经 `ext`(22.22.22.22)解析为 IPv4 → `direct` outbound 直出。字节级透明转发,不终结/不解密。

**关键字段对照 xray:**

| xray | sing-box | 说明 |
|---|---|---|
| `dokodemo-door` inbound | `direct` inbound | `network` **省略 = tcp+udp**(`"tcp,udp"` 会被拒);:80 写 `"network":"tcp"` |
| `sniffing.destOverride:["tls","quic","http"]` | route `action:"sniff", sniffer:[...]` | 1.11+ sniff 默认 override 目的为嗅探域名 |
| `freedom domainStrategy:ForceIPv4` | `action:"resolve" strategy:"ipv4_only"` + dns `strategy:"ipv4_only"` | 双保险锁 IPv4 |
| `dns.servers:["22.22.22.22"]` | 单 typed udp server `ext` + `default_domain_resolver` | 防回环 |
| `routing` `geoip:private→blackhole` | `ip_is_private:true → reject method:drop` | 覆盖更全(含 CGNAT/link-local) |
| dokodemo 占位 `address:127.0.0.1`(sniff 失败兜底) | `ip_cidr:[自身IP] → reject drop`(详见 §5) | 1.13 无 inbound override_address,改用显式自身 IP reject |

## 4. 三类协议落地(与 xray 等价)

- **TLS(443/TCP)**:sniff `tls` 读 SNI → 直出。
- **QUIC/HTTP3(443/UDP)**:`direct` inbound 默认绑 UDP、sniff `quic` 读 QUIC Initial SNI → 直出。
- **HTTP(80/TCP)**:sniff `http` 读 `Host:` → 直出;**80 无 QUIC**,不放行 UDP 80。
- 无 SNI / 无 Host / 非 TLS / ECH-only:sniff 失败 → 被 §5 的 reject 丢弃,绝不回环。ECH-only 只暴露 outer SNI(协议层限制,与 xray 同,非回退)。

## 5. 正确性约束(对应 DESIGN §5)

1. **防回环(最关键)**:DNS 只配一个外部 server `ext`=`22.22.22.22`,`route.default_domain_resolver` 与 `resolve` action 都引用它。sing-box 无 fakeip、无 `local`(resolv.conf)server、无 detour,**没有任何路径**回查本机会做 ip-alias 的 smartdns。安装时由 `SINGBOX_RESOLVER`(默认 22.22.22.22)覆盖,必须是外部 IPv4。
2. **嗅探失败不回环(sing-box 1.13 新坑)**:xray 用 dokodemo 占位 `127.0.0.1`,sniff 失败统一变 127.x 被 blackhole;sing-box 1.13 移除了 inbound `override_address`,sniff 失败会**保留原始目的 = 网关自身 IP**。故:
   - `resolve` 置于 reject **之前**,使"域名解析回自身 IP"的极端情况也能被随后 reject 命中;
   - `ip_is_private:true → reject drop` 兜住 NPN 部署(网关是 172.22 私网);
   - 注入 `ip_cidr:[GATEWAY_IP/32, PUBLIC_IP/32] → reject drop` 兜住公网部署(网关是公网 IP,private 规则盖不住)。提交默认是 sentinel `127.0.0.2/32`,install.sh 用 `GATEWAY_IP`/`PUBLIC_IP` 改写(两者相等时去重)。
3. **判 geo 与 chnroute** 仍由 smartdns 完成,本层不变。

## 6. 验证证据(test-env 真机)

已在 **test-env**(Debian 13 trixie x86_64,见 [CLAUDE.md](../../../CLAUDE.md))对 §3 候选 config 实测 sing-box **1.13.14**:

- `sing-box check -c config.json` → **`CHECK_OK`**:`direct` inbound、typed udp DNS server、`action:sniff`/`resolve`、`ip_is_private`、`method:"drop"`、`default_domain_resolver` 等版本敏感字段名全部通过。
- `sing-box run` boot test → 进程正常,监听:`0.0.0.0:443`(tcp)+ `0.0.0.0:443`(udp)+ `0.0.0.0:80`(tcp),日志无报错。确认 `direct` inbound **省略 network 即同时绑 tcp+udp**(`"tcp,udp"` 会 `unknown network` 报错),:80 `network:"tcp"` 只绑 tcp。

> 这两步把"版本敏感字段名翻车"和"配置能否运行/正确绑 QUIC UDP"两个最大风险消除在写实现之前。

## 7. 系统集成

### systemd
`etc/systemd/xray.service` → `etc/systemd/sing-box.service`:
- `ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json`
- `User=root`,`Type=simple`,`Restart=on-failure`,`RestartSec=5`,`LimitNOFILE=65535`,`After/Wants=network-online.target`
- **沙箱照搬**:`NoNewPrivileges=yes`、`ProtectSystem=strict`、`ProtectHome=yes`、`PrivateTmp=yes`、`ProtectKernelTunables/Modules/Logs=yes`、`ProtectControlGroups=yes`、`RestrictSUIDSGID=yes`、`RestrictAddressFamilies=AF_INET AF_UNIX`、`ReadOnlyPaths=/usr/local/etc/sing-box`
- ⚠️ 验收项:`RestrictAddressFamilies=AF_INET AF_UNIX` 对 sing-box 是否够(可能需补 `AF_NETLINK` 读路由/接口);在 test-env 用真单元起一次确认,失败则加 `AF_NETLINK`。

### 防火墙([scripts/setup-firewall.sh](../../../scripts/setup-firewall.sh))
- 端口规则**不变**:`ip saddr ${CLIENT_NET} tcp dport {80,443,${IOS_PORT}} accept` + `ip saddr ${CLIENT_NET} udp dport 443 accept`(UDP 仅 443,NPN 来源)。
- 安装的服务单元名 `xray.service` → `sing-box.service`;文件头/注释 xray → sing-box。

### install.sh
- `install_xray()` → `install_singbox()`:`ver=${SINGBOX_VERSION:-1.13.14}`;下 `https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-amd64.tar.gz`(tag 带 `v`、文件名不带),`tar -xzf` 取 `sing-box` 装到 `/usr/local/bin/sing-box`。**默认不 sha256**;保留 `SINGBOX_SHA256` opt-in(设置则校验、不匹配 fatal;未设则 plain 下载)。配置装到 `/usr/local/etc/sing-box/config.json`。幂等:已存在可执行则跳过。
- 解析器 patch:`XRAY_RESOLVER` → `SINGBOX_RESOLVER`(默认 22.22.22.22),sed 把提交默认的 `22.22.22.22` 改写为该值。
- 自身 IP patch:sed 把提交默认的 sentinel `127.0.0.2/32` 改写为 `"GATEWAY_IP/32"`(及 `"PUBLIC_IP/32"`,不等时追加)。
- 续期 pre/post hook 内 `stop/start xray` → `sing-box`(仍停服腾 :80 给 `certbot --standalone`)。
- `--status`/重启服务列表 `xray` → `sing-box`;full_install 主动移除旧 `xray.service`(disable + rm)与旧 `/usr/local/etc/xray`。

### 控制面([tgbot.py](../../../tgbot.py))
- `SERVICES = ['smartdns','xray']` → `['smartdns','sing-box']`;重启菜单标签同步。机制(改文件 + 重启)不变。

## 8. 文档与测试

- **[tests/test_proxy_policy.sh](../../../tests/test_proxy_policy.sh)**:重写为 sing-box 形态断言——`22.22.22.22` 且不指本机 smartdns;`direct` inbound 443(默认 tcp+udp)+ 80(`network:"tcp"`);`action:"sniff"` 含 `quic`/`tls`/`http`;`ipv4_only`;`reject`+`method:"drop"`(防回环 sink);`ip_is_private`;自身 IP reject 规则存在;systemd `-c /usr/local/etc/sing-box/config.json`。
- **[tests/test_hardening_policy.sh](../../../tests/test_hardening_policy.sh)**:路径指向 `sing-box.service`,沙箱断言不变(含 `RestrictAddressFamilies`)。
- **[tests/test_install_policy.sh](../../../tests/test_install_policy.sh)**:`systemctl stop/start xray` → `sing-box`。
- **[tests/integration-smoke.md](../../../tests/integration-smoke.md)**、**[README.md](../../../README.md)**:叙述 xray → sing-box。
- **[CLAUDE.md](../../../CLAUDE.md)**:§1 所述两处约定改写(no-exit-layer 移除 sing-box、保留出口层禁令并注明 direct inbound 无 tproxy/fwmark;sha256 校验对 sing-box 改为可选)。
- **[docs/DESIGN.md](../../DESIGN.md)**:更新 §6/§8/§12,记录 xray→sing-box 反转、新 config 形态、§5 自身 IP reject 防回环、不校验决策及理由。

## 9. 风险 / 待 Linux 验证(test-env 可跑)

已验证(§6):config schema、运行时绑定 tcp+udp/80。**仍需在实现期于 test-env 验证**:
1. **真实转发行为**:起 sing-box,从客户端连 `网关:443` 带真实域名 SNI,确认按嗅探域名直出(而非连原始 IP)。这是最 load-bearing 的行为假设。
2. **QUIC 实测**:`curl --http3` 经 UDP 443 走通。
3. **沙箱 AF_INET 充分性**:真单元(含 `RestrictAddressFamilies=AF_INET AF_UNIX`)起服务,失败则补 `AF_NETLINK`。
4. **证书续期**:停 sing-box 腾 :80 → certbot dry-run → 复服,端到端。
5. **完整 install.sh**:test-env 缺 `nft`/`jq`/`certbot`,跑全装前需先装这些依赖。
- 已知取舍(用户接受):sing-box ~256MB 内存底(test-env 3.9GB,无虞)、config 每个 minor 可能 break、默认不校验=信任 GitHub release。

## 10. 回滚

- 旧 `etc/xray/config.json` 与 `xray.service` 保留于 git 历史;迁移失败可 `git revert` + 切回旧单元 + `install_xray`。
- xray 与 sing-box 为二选一直接替换,无并存开关。
