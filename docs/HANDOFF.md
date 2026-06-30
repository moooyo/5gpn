# 5gpn 交付报告 / Handoff

- 日期:2026-06-28(架构更新说明 2026-07-01)
- 范围:在既有代码基础上,完成审计发现的**全部必修 + 应修 + 安全硬化**,并补齐自动化测试与 CI。
- 架构图:见会话内 SVG;权威设计见 [DESIGN.md](DESIGN.md);上线验收清单见 [tests/integration-smoke.md](../tests/integration-smoke.md)。

> **⚠️ 架构已更新(2026-07-01)**:本 Handoff 记录的是 smartdns 时代的架构与改动。该架构已被 **`5gpn-dns`(自研 Go DNS 网关)** 取代——smartdns + chinadns-ng 已移除,DNS 大脑改由 `5gpn-dns` 承担,入口从 DoT-only 扩展为 DoT :853 + DoH :8443 + 明文 DNS :53。当前权威设计见 [DESIGN.md](DESIGN.md) 及规格说明 [docs/superpowers/specs/2026-06-30-5gpn-dns-go-design.md](superpowers/specs/2026-06-30-5gpn-dns-go-design.md)。本 Handoff 保留为历史参考。

---

## 1. 架构现状(一句话)

**解析即策略**:客户端经 **DoT :853** 查 smartdns;命中强制表或解析出**国外 IP** 的域名被解析成**网关 IP**,客户端遂连到网关上的 **sing-box(TCP 80/443)**,后者读 SNI、经硬编码 **22.22.22.22** 重解析真实 IP,**直接走默认路由出网**;国内域名拿到真实国内 IP **直连**(网关不在数据路径)。**QUIC/HTTP3 由 sing-box sniff quic 透明转发**;UDP 443 放行（172.22 来源）。出口**仅直出**(无隧道/多出口/mark)。控制面为 **Telegram Bot**(`tgbot.py`),通过 `install.sh --setup-tgbot` 配置(安装器内置 **Gum TUI**,无 Gum 时回退 plain echo)。

---

## 2. 本次改动汇总

### 架构决策
- **QUIC 由 sing-box 代理**:引入 sing-box `direct` inbound + route sniff `quic`;`setup-firewall.sh` 对 UDP 443 放行（172.22 来源）;预编译 sing-box 二进制,无 Go 工具链依赖;sing-box 以 root + systemd sandbox 运行。
- **NPN-only 拓扑**:客户端在 `172.22.0.0/16`;引入客户端朝向地址 `GATEWAY_IP`(默认 = `PUBLIC_IP`,NPN 时 `export GATEWAY_IP=<内网地址>`),用于 smartdns `ip-alias` 目标、iOS `ServerAddresses`、profile/QR URL。

### 必修(P0/P1)
- **证书续期**:`install.sh` 加全局 `renewal-hooks/pre|post`(临时开 80 + 停 sing-box → 还原)+ Persistent `5gpn-certbot-renew.timer`,绕过 DoT-only 防火墙与 sing-box 占用 :80 的问题(否则证书 ~90 天到期 → DoT 全量下线)。
- **iOS / 防火墙拓扑**:`setup-firewall.sh` 放行 `172.22 → 8111`(iOS 描述文件抓取),profile 指向内网网关地址。
- **抗污染(约束 2)**:smartdns 国内解析器加 `-whitelist-ip`(只收中国 IP)+ `conf-file` 引入生成的 `china-whitelist.conf` 与 `bogus-nxdomain.conf`。(已于 2026-06-30 被三层全局模型取代:全局 `ip-rules ip-set:china_ip -whitelist-ip` 对合并后答案过滤,per-server `-whitelist-ip` 与 `china-whitelist.conf` 已移除,改由 `china_ip.conf` 承载 ip-set；见 §12 决策记录。)

### 应修(§3)
解压炸弹上限(restore 每成员封顶)、拒绝 chunked/`Transfer-Encoding`、`renew-hook.sh` 用 `$RENEWED_LINEAGE`、生成器丢弃 `/0` 且拒绝空 foreign 集、`--status` 计数一致、README 状态+用法。(注:这些 guard 随 api-server.py 移除;现 ios-http.py 为 GET-only 静态响应,不读请求体)

### 安全硬化(§4,经对抗式评审)
systemd 沙箱(`NoNewPrivileges`/`ProtectSystem=strict`/`ProtectKernel*` 等)、DoT :853 每源限速(`DOT_RATE`/`DOT_BURST` 可调)、鉴权失败日志(**限速 1/s + 脱敏**防 journald 刷屏与终端转义注入)、`SMARTDNS_SHA256` 选配校验。
> 评审又揪出并已修:**iosprofile 部署用的是 install.sh heredoc(裸奔),我之前只加固了从不安装的静态文件** → 已加固 heredoc + 删死文件 + 修正测试。

### 测试与 CI
- **`DOMAIN_RE` 三处统一**到同一 FQDN 规则(tgbot 逐字相同;install.sh 等价)+ 反漂移测试。
- **7 个自动化测试**:5 个 grep 策略测试(proxy/install/cleanup/hardening/domain,本机+CI 可跑)+ 2 个 Python(gen_foreign_cidr 单测、smartdns_conf policy,CI 跑)。
- **CI**:`.github/workflows/ci.yml`(GitHub Actions/ubuntu)跑 `py_compile` + `run-tests.sh`;用 `find` 定位测试,兼容 5gpn 作为根或子目录。

---

## 3. 验证状态

- **本机已通过**:全部 shell `bash -n`;5 个 grep 策略测试;`smartdns.conf.template` 用 `sed` 模拟渲染断言;`is_valid_domain` 行为表。
- **CI 门(GitHub 上跑)**:`py_compile`(本机无 Python)、`test_gen_foreign_cidr.py`、`test_smartdns_conf_policy.sh`。
- **仅能在 Linux 真机验证**:见第 4 节。

---

## 4. 上线前 checklist(Linux 真机)

> 逐项把 [tests/integration-smoke.md](../tests/integration-smoke.md) 的 `[ ]` 转成带日期/主机的 pass/fail。

- [ ] 全装一遍:`sudo bash install.sh`(NPN 时先 `export GATEWAY_IP=<内网>`)。
- [ ] **P1 DNS**:DoT 查 被墙/国外→网关 IP、国内→真实国内 IP、AAAA→SOA、混合 IP 选国内、无回环。
- [ ] **抗污染**:`china_ip.conf`/`bogus-nxdomain.conf` 存在且 smartdns 正常启动;被墙域名稳定返回网关 IP(不被伪国内 IP 直连)。
- [ ] **P2 转发**:`curl https://<国外域名>` 经 sing-box 直出可达;`tcpdump` 证实代理只查 22.22.22.22,不回 :853/:5353。
- [ ] **QUIC 代理**:`curl --http3 https://<国外域名>` 经 sing-box sniff quic 透明转发成功;UDP 443 放行（172.22 来源）。
- [ ] **证书续期**:drop 防火墙生效下 `certbot renew --dry-run` 端到端成功;过程中 80 短暂放行、sing-box 停后恢复;timer active。
- [ ] **防火墙/沙箱**:仅 `172.22` 能连 80/443/8111;`systemctl show sing-box/5gpn-iosprofile@ -p NoNewPrivileges,ProtectSystem` 生效;服务能正常启动(沙箱没误伤)。
- [ ] **控制面**:`--setup-tgbot` 后,bot 增删域名 + chnroute 刷新 + 重启正常;鉴权失败日志限速可见。
- [ ] **CI**:把仓库推到 GitHub,确认 Actions 绿。
