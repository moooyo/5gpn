# 设计:5gpn-dns —— 自研 Go DNS 大脑(取代 smartdns + chinadns-ng)

- 状态:已批准方向(自研 Go、淘汰 smartdns+chinadns-ng),待 spec 评审
- 日期:2026-06-30
- 范围:用一个自研 Go 二进制 **`5gpn-dns`** 取代 **smartdns 与(从未落地的)chinadns-ng**,把 DNS 大脑全部逻辑收进一个进程:DoT 入口(证书)、AAAA→SOA、黑名单(→网关IP)、**确定性 chnroute 仲裁**(国内 UDP + 可信 DoT,国内答案 IP 命中中国段才用国内,否则用可信)、国外 IP → 网关IP 改写、缓存、证书热加载。**sing-box 数据面保留不变**。
- 关联(均被本案在 DNS 大脑上取代):[2026-06-30-three-tier-dns-split-design.md](2026-06-30-three-tier-dns-split-design.md)、[2026-06-30-chinadns-ng-arbitration-design.md](2026-06-30-chinadns-ng-arbitration-design.md);[DESIGN.md](../../DESIGN.md)(§2/§4/§5/§12 重写)

---

## 1. 背景

三层方案 test-env 实测证明 smartdns 做不到"含国内 IP 即用国内、不测速"(`ip-rules -whitelist-ip` 空转;跨上游是 first-response)。chinadns-ng 能做但带来内核 nftset + 多组件拼接。用户决策:**自研一个 Go DNS 服务,把逻辑全收进去,淘汰 smartdns 和 chinadns-ng**——彻底消除组件间阻抗,DNS 大脑完全可控。逻辑本身简单(核心 ~一处 handler),用成熟库 `miekg/dns` 承担解析/DoT/EDNS/TCP 等难点。

## 2. 既定决策(2026-06-30)

| 决策点 | 选择 | 理由 |
|---|---|---|
| 语言/库 | **Go + `github.com/miekg/dns`**(唯一第三方依赖) | DoT server/client 一行、并发好写、库久经考验;chnroute/缓存用 stdlib 手写,依赖最少 |
| 取代范围 | **smartdns + chinadns-ng 全淘汰**,逻辑收进 `5gpn-dns` | 用户指令;一个进程即 DNS 大脑 |
| 分发 | **CI(GitHub Actions)交叉编译 linux-amd64 静态二进制(`CGO_ENABLED=0`)→ 挂到 `moooyo/5gpn` release**;install 下载预编译 | 守"盒子上不装工具链";构建在 CI。dev/验证期:dev box(Go 1.26.3)交叉编译 + scp 到 test-env |
| DoT 入口 | **`5gpn-dns` 自己监听 `:853`(TLS,LE 证书)**,`tls.Config.GetCertificate` 按 mtime 热加载 | smartdns 没了,DoT 服务由本程序提供;续期后无需重启 |
| chnroute 即"是否国内" | 命中 china_ip_list → 国内(直连);**未命中 = 国外 → 网关IP** | 不再需要 `foreign-cidr.txt`/`gen_foreign_cidr.py`(反集),只需 china_ip_list 正集 |
| 可信上游 | DoT `tls://1.1.1.1`、`tls://8.8.8.8`(`dial_addr` 钉 IP) | 网关在国内,可信上游必须抗污染 |
| 国内上游 | UDP `223.5.5.5`、`119.29.29.29` | 快;污染由 chnroute 校验兜底 |
| 配置 | env/flags(install.sh 设)+ 列表文件;**无配置模板** | 去掉 smartdns.conf.template + render_smartdns_conf.py |
| 版本/校验 | `DNS_VERSION` 钉、`DNS_SHA256` opt-in | 同 sing-box 约定 |

## 3. 总体架构

```
客户端 ──DoT:853──> 5gpn-dns(Go)
   │  per query:
   │  ├─ AAAA → SOA;HTTPS(65) → 空 NOERROR;其余非 A → 透传可信 DoT
   │  └─ A:
   │       ├─ 缓存命中 → 直接答
   │       ├─ 命中黑名单(proxy-domains.txt 后缀匹配) → A=__GATEWAY_IP__(强制代理)
   │       └─ 否则 chnroute 仲裁:
   │            并发查 国内UDP(223.5.5.5/119.29.29.29) + 可信DoT(1.1.1.1/8.8.8.8)
   │            国内答案含 IP∈chnroute? → 用国内答案;否则 → 用可信答案
   │       → 改写:每个 IP ∈chnroute 保留(直连),否则 → __GATEWAY_IP__(代理);去重
   │       → 缓存(TTL 钳制)→ 答
   ▼
  返回 CN IP(客户端直连) 或 网关IP(客户端连 sing-box → 代理直出)
  (网关IP 流量 → sing-box 数据面,不变)
```

**确定性**:仲裁按"国内答案 IP 是否在 chnroute",**不看谁先回**;国内慢也等(超时)。这正是 smartdns 缺的。

## 4. `5gpn-dns` 程序设计(`cmd/5gpn-dns/`)

**输入(env/flags;install.sh 注入)**
- `DNS_LISTEN_DOT`=`:853`,`DNS_LISTEN_PLAIN`=`127.0.0.1:5353`(内部/调试)
- `DNS_CERT`/`DNS_KEY`(LE fullchain/privkey),热加载
- `DNS_GATEWAY_IP`(代理目标 = 黑名单/国外域名返回的 IP)
- `DNS_CHINA`=`223.5.5.5,119.29.29.29`(UDP)
- `DNS_TRUST`=`1.1.1.1,8.8.8.8`(DoT,`tcp-tls` 853)
- `DNS_CHNROUTE`=`/etc/5gpn/china_ip_list.txt`,`DNS_BLACKLIST`=`/etc/5gpn/proxy-domains.txt`
- `DNS_CACHE_SIZE`、`DNS_TTL_MIN`=300、`DNS_TTL_MAX`=86400、`DNS_QUERY_TIMEOUT`=5s

**请求管线(handler)**
1. 仅处理 1 个 question(miekg/dns)。
2. `AAAA`→ 回 SOA(IPv4-only);`HTTPS`/`SVCB`(type 65)→ 空 NOERROR(避免 ECH 干扰,与项目 sniff 取向一致);其余非 A → 透传到可信 DoT,verbatim 返回(罕见)。
3. `A`:
   - 缓存查(key=qname|qtype)。
   - 黑名单后缀匹配 → answer=[A:GATEWAY_IP]。
   - 仲裁:`ctx` 并发两组上游;国内组取首个成功响应,可信组取首个成功响应;等国内(到 timeout),`chinaIsCN = 国内答案任一 A ∈ chnroute`;`final = chinaIsCN ? 国内A : 可信A`。
   - 改写:`map(A): IP∈chnroute ? IP : GATEWAY_IP`,去重。
   - 写缓存(TTL=clamp(min(rr.ttl), TTL_MIN, TTL_MAX)),返回。
4. **防回环**:上游恒为外部(UDP 国内 / DoT 可信),永不查自身;sing-box 的 22.22.22.22 与此无关。

**chnroute 匹配(stdlib)**:启动加载 china_ip_list.txt → IPv4 转 `uint32` 区间 `[start,end]`,排序合并;查询二分。`SIGHUP` 重载。

**黑名单(stdlib)**:加载 proxy-domains.txt → 后缀集(`map[string]struct{}` + 逐级父域查 或 反转 trie)。`SIGHUP` 重载。

**缓存(stdlib)**:并发安全 TTL map + 容量上限(简单分片/LRU);定期清理。

**证书热加载**:`tls.Config.GetCertificate` 回调按 mtime 重读 cert/key → 续期后自动生效,无需重启。

**依赖**:仅 `miekg/dns`(+ stdlib)。`go.mod` 锁版本。

## 5. 取代 / 保留 / 删除

**删除(随 smartdns/chinadns-ng 一起):**
- `install_smartdns`、`etc/smartdns.conf.template`、`scripts/render_smartdns_conf.py`、`etc/systemd/sing-box.service` 之外的 smartdns 单元、smartdns 相关安装/续期/服务列表分支。
- `scripts/gen_foreign_cidr.py` + `foreign-cidr.txt`(chnroute 正集替代反集)。
- 三层/chinadns 方案的 `china-domains.txt`、`china_ip.conf`、cnlist、nftset、`load-chnroute.sh`(均未最终落地或本案不需要)。
- `tests/test_smartdns_conf_policy.sh`、`tests/test_dns_split_policy.sh`(改为 Go 单测 + 新 grep 断言)。

**保留:**
- **sing-box**(数据面,完全不变)及其 P0 `SINGBOX_RESOLVER` 装机提示(sing-box SNI 用,与本案无关)。
- `china_ip_list.txt`(→ 5gpn-dns chnroute;update-lists 刷新 + SIGHUP)。
- `proxy-domains.txt`(黑名单;tgbot 增删 → 写文件 + SIGHUP)。
- certbot 签发/续期;`renew-hook` 改为 拷贝证书到 `/etc/5gpn/cert`(5gpn-dns 热加载,可不重启)。续期 pre/post 停 sing-box 腾 :80 的逻辑**不变**(:80 是 sing-box 占的;5gpn-dns 只占 :853)。
- 防火墙(DoT :853 入站 + sing-box 端口;`DOT_RATE/DOT_BURST` 仍在防火墙)。
- iOS profile、tgbot、install 编排骨架。

## 6. 安装 / 运维(`install.sh`)

- 新增 `install_5gpndns()`:下预编译 `5gpn-dns-linux-amd64`(`DNS_VERSION` 钉,`DNS_SHA256` opt-in)→ `/usr/local/bin/5gpn-dns`;幂等。
- `full_install`:`install_5gpndns` 取代 `install_smartdns`;证书装到 `/etc/5gpn/cert`;列表装到 `/etc/5gpn/`;移除旧 smartdns(`systemctl disable --now smartdns`、删单元/conf,若残留)。
- systemd `etc/systemd/5gpn-dns.service`:`ExecStart=/usr/local/bin/5gpn-dns`(env 经 unit `Environment=`/`EnvironmentFile=/etc/5gpn/dns.env`),`User=root`(绑 :853),`Restart=on-failure`,`After=network-online.target`(在 sing-box 之前或无依赖均可——客户端先经 5gpn-dns)。沙箱:`NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`RestrictAddressFamilies=AF_INET AF_UNIX`、`ReadOnlyPaths`(配置/列表/证书);**权限/AF 充分性 test-env 实测**(参照 sing-box AF_NETLINK 教训)。
- `start_services`/`show_status`:`smartdns` → `5gpn-dns`;续期 deploy hook 拷证书 + `kill -HUP`(或重启)5gpn-dns。
- `--update-lists`:刷 china_ip_list + SIGHUP。`--add/del-domain`:改 proxy-domains.txt + SIGHUP。

## 7. 构建 / 发布(新基础设施)

- 源码 `cmd/5gpn-dns/`(+ `go.mod`/`go.sum`)。
- `.github/workflows/release.yml`:tag(如 `dns-vX.Y.Z`)触发 → `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build` → 上传 `5gpn-dns-linux-amd64` + `checksums.txt` 到 release。
- 现有 `ci.yml`:加 `go vet` + `go test ./...`(Go 单测门)。
- dev/验证期:dev box `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build` 产物 scp 到 test-env,先于首个正式 release 验证。

## 8. 测试

- **Go 单测(`cmd/5gpn-dns/*_test.go`,CI + dev box 都跑)**:chnroute 区间匹配(边界/合并)、黑名单后缀匹配(父域/精确/非匹配)、AAAA→SOA、HTTPS(65)→空、仲裁逻辑(table-driven,注入假上游:国内CN/国内污染/国内超时/仅国外)、国外→网关 改写 + 去重、TTL 钳制、缓存命中/过期。
- **grep 策略(dev box)**:`install_5gpndns`、`5gpn-dns.service`、tgbot `SERVICES` 含 `5gpn-dns`、update-lists SIGHUP、**无残留 smartdns/chinadns 引用**;sing-box 相关测试不变。
- **真机(test-env)**:见 §9。

## 9. 真机验证(test-env)

dev box 交叉编译 → scp。用 mock 上游(test-env 外网 DNS 被劫持为 198.18.x):
1. **确定性 prefer-CN(最关键)**:国内 mock=CN IP、可信 mock=国外 IP,**两种时序都测**(国内慢/国外快、国内快/国外慢)→ 都返回 CN(对比 smartdns first-response 翻车)。国内只给国外 IP(不在 chnroute)→ 用可信答案 → 改写网关IP。国内超时 → 用可信答案。
2. **黑名单**:proxy-domains 内 → 网关IP(不解析)。
3. **DoT 入口**:自签证书起 :853,`kdig +tls`/`dig +tls` 查通;**证书热加载**:替换 cert 文件 → 新握手用新证书(无需重启)。
4. **AAAA→SOA、HTTPS(65)→空**。
5. **缓存 + SIGHUP 重载**:改 proxy-domains/china_ip_list + `kill -HUP` → 行为随之变,无需重启。
6. **沙箱**:真单元起服务,`RestrictAddressFamilies` 等不误伤(不足则补,记录)。

## 10. 风险 / 取舍

- **自有一个网络面 DNS 服务**:安全/维护面新增,但 miekg/dns 承担难点,本程序逻辑窄(本地监听 DoT,逻辑确定),~中等代码量。
- **新 CI 构建/发布链**:本仓库首次自产二进制;一次性搭好。
- **残留硬伤**:污染成"看着像 CN"的国外 IP(命中 chnroute)仍误判直连——同源问题,靠黑名单(强制代理)自愈;可信 DoT + chnroute 已显著收窄。
- **纯国内域名**:每次并发双查(+数十 ms);可后续加正向缓存/域名快路径(YAGNI)。
- **首发依赖 release**:install 需 release 存在;验证期用 dev box 交叉编译产物。

## 11. 回滚

- smartdns/chinadns 方案保留于 git 历史;回滚 = `git revert` 本案 + 恢复 smartdns 安装/配置。`5gpn-dns` 卸载:`systemctl disable --now 5gpn-dns` + 删二进制/单元。

## 12. 与既有已落地工作的关系

- **取代**:main 上三层方案的全部 DNS-大脑件(smartdns 模板/渲染/列表三层段/相关测试与文档),以及未落地的 chinadns 方案。
- **保留**:Task 2 P0 `SINGBOX_RESOLVER` 提示、Task 3 `DOT_RATE/DOT_BURST` 转发 + HANDOFF §3 注记、sing-box 全部。
- 实现基线 = 当前 main(三层已落地)之上做增量:加 `cmd/5gpn-dns` + CI,删 smartdns 件,改 install/update-lists/renew-hook/tgbot/docs。
