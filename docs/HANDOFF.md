# new-5gpn 交付报告 / Handoff

- 日期:2026-06-28
- 范围:在既有代码基础上,完成审计发现的**全部必修 + 应修 + 安全硬化**,并补齐自动化测试与 CI。
- 架构图:见会话内 SVG;权威设计见 [DESIGN.md](DESIGN.md);上线验收清单见 [tests/integration-smoke.md](../tests/integration-smoke.md)。

---

## 1. 架构现状(一句话)

**解析即策略**:客户端经 **DoT :853** 查 smartdns;命中强制表或解析出**国外 IP** 的域名被解析成**网关 IP**,客户端遂连到网关上的 **sniproxy(TCP 80/443)**,后者读 SNI、经硬编码 **22.22.22.22** 重解析真实 IP,**直接走默认路由出网**;国内域名拿到真实国内 IP **直连**(网关不在数据路径)。**QUIC/HTTP3 不代理**(UDP 443 在防火墙 `reject`,客户端回退 TCP)。出口**仅直出**(无隧道/多出口/mark)。

---

## 2. 本次改动汇总

### 架构决策
- **QUIC 不代理**:删除 `src/quic-proxy.go` + `quic-proxy.service` + Go 工具链;`setup-firewall.sh` 对 UDP 443 `reject`(快速回退 TCP)。
- **NPN-only 拓扑**:客户端在 `172.22.0.0/16`;引入客户端朝向地址 `GATEWAY_IP`(默认 = `PUBLIC_IP`,NPN 时 `export GATEWAY_IP=<内网地址>`),用于 smartdns `ip-alias` 目标、iOS `ServerAddresses`、profile/QR URL。

### 必修(P0/P1)
- **证书续期**:`install.sh` 加全局 `renewal-hooks/pre|post`(临时开 80 + 停 sniproxy → 还原)+ Persistent `new5gpn-certbot-renew.timer`,绕过 DoT-only 防火墙与 sniproxy 占用 :80 的问题(否则证书 ~90 天到期 → DoT 全量下线)。
- **iOS / 防火墙拓扑**:`setup-firewall.sh` 放行 `172.22 → 8111`(iOS 描述文件抓取),profile 指向内网网关地址。
- **webui 假绿**:`!!svc[k]` → `svc[k] === 'active'`,停机时显示真实状态词。
- **API 端口**:`install.sh` 默认 `8080` → `8443`;`api-server.py` 改读 systemd `Environment=`(token/port/bind/cert/CONF_DIR,文件兜底)。
- **API 资源/keep-alive**:Handler 读超时 30s、`BoundedSemaphore(64)` 限并发、错误响应 `Connection: close`、unit `TasksMax/MemoryMax/LimitNOFILE`。
- **抗污染(约束 2)**:smartdns 国内解析器加 `-whitelist-ip`(只收中国 IP)+ `conf-file` 引入生成的 `china-whitelist.conf` 与 `bogus-nxdomain.conf`。

### 应修(§3)
解压炸弹上限(restore 每成员封顶)、拒绝 chunked/`Transfer-Encoding`、webui token 改 `sessionStorage`、`renew-hook.sh` 用 `$RENEWED_LINEAGE`、生成器丢弃 `/0` 且拒绝空 foreign 集、`--status` 计数与 API 一致、README 状态+用法。

### 安全硬化(§4,经对抗式评审)
systemd 沙箱(`NoNewPrivileges`/`ProtectSystem=strict`/`ProtectKernel*` 等)、DoT :853 每源限速(`DOT_RATE`/`DOT_BURST` 可调)、鉴权失败日志(**限速 1/s + 脱敏**防 journald 刷屏与终端转义注入)、webui CSP、`SMARTDNS_SHA256` 选配校验。
> 评审又揪出并已修:**iosprofile 部署用的是 install.sh heredoc(裸奔),我之前只加固了从不安装的静态文件** → 已加固 heredoc + 删死文件 + 修正测试。

### 测试与 CI
- **`DOMAIN_RE` 三处统一**到同一 FQDN 规则(api/tgbot 逐字相同;install.sh 等价)+ 反漂移测试。
- **7 个自动化测试**:5 个 grep 策略测试(proxy/install/cleanup/hardening/domain,本机+CI 可跑)+ 2 个 Python(gen_foreign_cidr 单测、smartdns_conf policy,CI 跑)。
- **CI**:`.github/workflows/ci.yml`(GitHub Actions/ubuntu)跑 `py_compile` + `run-tests.sh`;用 `find` 定位测试,兼容 new-5gpn 作为根或子目录。

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
- [ ] **抗污染**:`china-whitelist.conf`/`bogus-nxdomain.conf` 存在且 smartdns 正常启动;被墙域名稳定返回网关 IP(不被伪国内 IP 直连)。
- [ ] **P2 转发**:`curl https://<国外域名>` 经 sniproxy 直出可达;`tcpdump` 证实代理只查 22.22.22.22,不回 :853/:5353。
- [ ] **QUIC 回退**:`curl --http3` 失败/回退,普通 `curl` 正常;`nc -uvz <gw> 443` 被拒。
- [ ] **证书续期**:drop 防火墙生效下 `certbot renew --dry-run` 端到端成功;过程中 80 短暂放行、sniproxy 停后恢复;timer active。
- [ ] **防火墙/沙箱**:仅 `172.22` 能连 80/443/8111;`systemctl show sniproxy/new5gpn-iosprofile@ -p NoNewPrivileges,ProtectSystem` 生效;服务能正常启动(沙箱没误伤)。
- [ ] **控制面(可选)**:`--setup-api`/`--setup-tgbot` 后,API/bot/webui 增删域名 + chnroute 刷新 + 重启 + 备份/恢复正常;鉴权失败日志限速可见。
- [ ] **CI**:把仓库推到 GitHub,确认 Actions 绿。
