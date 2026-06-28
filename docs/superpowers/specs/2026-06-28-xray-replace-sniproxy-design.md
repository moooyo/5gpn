# 设计:sniproxy → xray-core(全量替换 + 开 QUIC)

- 状态:已实施
- 日期:2026-06-28
- 范围:用 xray-core 的 `dokodemo-door` + sniffing 替换 dlundquist/sniproxy,作为 TCP(80/443)与 QUIC(UDP 443)的 SNI 透明转发层;直出不变。
- 关联文档:[DESIGN.md](../../DESIGN.md)(§5 正确性约束、§6 数据流、§8 出口、§12 决策)

---

## 1. 背景与动机

现状:网关用 **dlundquist/sniproxy(C)** 做纯 TCP 的 SNI 透明转发(80 读 HTTP Host,443 读 TLS SNI,不解密),解析器 hardcode `22.22.22.22` 防回环;QUIC/HTTP3 不代理,UDP 443 在防火墙 `reject`,逼客户端回退 TCP/TLS。

动机:让 **HTTP/3 / QUIC 原生走代理**,提升 QUIC 站点体验。sniproxy 只能处理 TCP,无 UDP/QUIC 能力。xray-core 的 sniffing 支持 `quic`,可在同一进程同时按 SNI 透明转发 TCP 与 QUIC。

这是一次**明确推翻 DESIGN §12 已定决策**的变更:
- 「移除 Go 工具链 / 不引入 Go 二进制」→ 重新引入**预编译** xray(Go)二进制(不引入构建工具链)。
- 「QUIC/HTTP3 不代理,UDP 443 reject」→ QUIC 经 xray 透明转发,UDP 443 放行。
- sniproxy 的「root 启动后降权到 pxout」→ xray 以 **root** 运行(用 systemd sandbox 压爆炸半径)。

## 2. 既定决策(评审 2026-06-28)

| 决策点 | 选择 | 理由 |
|---|---|---|
| 范围 | 全量替换 + 开 QUIC | 收益最大化(原生 HTTP/3);中间态(换 xray 但不开 QUIC)被否,纯负债 |
| 安装方式 | **官方预编译二进制**(XTLS GitHub release,校验 sha256) | 不引入 Go 工具链;低内存盒子不在本地编译 |
| 权限模型 | **root 运行** + systemd sandbox | 用户选定;xray 无内置降权,以 sandbox 限制爆炸半径 |
| 防回环解析 | xray 内置 DNS = `22.22.22.22` + freedom `ForceIPv4` | 等价 sniproxy 的 hardcode 解析器,绝不指本机 smartdns |
| 嗅探失败兜底 | 占位 `address=127.0.0.1` + 路由 `geoip:private → blackhole` | xray 方案新坑:sniff 失败时不得把目的当网关 IP 连回自己 |
| 安装路径 | 二进制 `/usr/local/bin/xray`;配置 `/usr/local/etc/xray/config.json` | 约定俗成 |
| 证书续期 | 沿用「停服腾 :80 给 `certbot --standalone`」 | 与现状一致,最小改动 |

## 3. 数据面:xray 配置

`etc/xray/config.json`(IPv4-only、直出):

```jsonc
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["22.22.22.22"], "queryStrategy": "UseIPv4" },
  "inbounds": [
    { "tag": "p443", "listen": "0.0.0.0", "port": 443, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "address": "127.0.0.1" },
      "sniffing": { "enabled": true, "destOverride": ["tls", "quic"] } },
    { "tag": "p80", "listen": "0.0.0.0", "port": 80, "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "address": "127.0.0.1" },
      "sniffing": { "enabled": true, "destOverride": ["http"] } }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "ForceIPv4" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": { "domainStrategy": "AsIs", "rules": [
    { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
  ]}
}
```

行为:dokodemo-door 收到连接后,sniffing 从首包提取域名(TLS ClientHello SNI / QUIC Initial SNI / HTTP Host),用 `destOverride` 把目的地址改写成该域名;freedom `ForceIPv4` 经内置 DNS(`22.22.22.22`)解析为 IPv4 后直出。字节级透明转发,不终结/不改写/不解密。

## 4. 三类协议落地

- **TLS(443/TCP)**:sniff `tls` 读 SNI → 改写 → 直出。替代 sniproxy `tls_hosts`。
- **QUIC/HTTP3(443/UDP)**:`network` 含 `udp`、sniff `quic` 读 QUIC Initial 的 SNI → 改写 → freedom UDP 直出。**sniproxy 不具备的新能力。** ECH-only 流量只能看到 outer SNI(与 TLS 同,非回退)。
- **HTTP(80/TCP)**:sniff `http` 读 `Host:` → 改写 → 直出。替代 sniproxy `http_hosts`。字节级透明转发,xray 不充当 HTTP 代理、不改头。**80 无 QUIC**,不放行 UDP 80。
  - 细节 1:HTTP/1.1 keep-alive 一条连接按**首请求 Host** 锁定上游(与 sniproxy 同,非回退)。
  - 细节 2:无 `Host:` 的请求(老 HTTP/1.0)sniff 失败 → 落占位 `127.0.0.1` → blackhole 丢弃(与 sniproxy 转不了同级)。

## 5. 正确性约束(对应 DESIGN §5)

1. **防回环(最关键)**:xray `dns.servers=["22.22.22.22"]`(外部解析器,绝不指本机 smartdns)。freedom `ForceIPv4` 用此 DNS 解析改写后的域名。等价 sniproxy 的 hardcode resolver。
2. **嗅探失败不回环(xray 新增坑)**:dokodemo-door sniff 失败时使用占位 `address`。设为 `127.0.0.1` 并加路由 `geoip:private → blackhole`,确保无 SNI / 非 TLS / ECH-only 流量被丢弃,绝不把目的当作网关公网 IP 再连回 xray 自身(否则死循环)。
3. **判 geo 与 chnroute** 仍由 smartdns 完成,本层不变。

## 6. 系统集成

### systemd
`etc/systemd/sniproxy.service` → `etc/systemd/xray.service`:
- `ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json`
- `User=root`
- 保留 sandbox:`NoNewPrivileges=yes`、`ProtectSystem=strict`、`ProtectHome=yes`、`PrivateTmp=yes`、`ProtectKernelTunables=yes`、`ProtectKernelModules=yes`、`ProtectControlGroups=yes`、`RestrictAddressFamilies=AF_INET AF_UNIX`(IPv4-only,含 UDP)、`LimitNOFILE=65535`、`Restart=on-failure`。
- `ReadOnlyPaths` 指向配置目录。

### 防火墙([scripts/setup-firewall.sh](../../../scripts/setup-firewall.sh))
- **删除** `udp dport 443 reject`。
- **新增** `ip saddr 172.22.0.0/16 udp dport 443 accept`(NPN 客户端的 QUIC)。
- TCP 80/443、DoT 853 限速、22 等不变。
- 安装的服务单元从 `sniproxy.service` 改为 `xray.service`。
- 文件头注释更新(QUIC 现已代理)。

### install.sh
- `build_sniproxy()` → `install_xray()`:下载锁定版本 release zip → 校验 sha256 → 解压 `xray` 到 `/usr/local/bin` → 安装 `config.json` 到 `/usr/local/etc/xray/`。**不引入 Go 工具链。**
- 配置安装从 `etc/sniproxy.conf` 改为 `etc/xray/config.json`。
- certbot 续期 pre/post hook 内 `stop/start sniproxy` → `xray`(仍停服腾 :80)。
- 状态/重启服务列表 `smartdns sniproxy nftables` → `smartdns xray nftables`。
- `pxout` 账户:xray 以 root 运行后不再需要;若无其它使用者则移除其创建逻辑(待实现期确认无残留引用)。

## 7. 文档与测试

- **DESIGN.md**:更新 §6(数据流)、§8(出口)、§12(决策),记录上述三项决策反转及理由;§5 增补「嗅探失败 blackhole」约束。
- **tests/**:`test_proxy_policy.sh` 等对 sniproxy 的引用改为 xray;新增断言:(a) 无 SNI/无 Host → 不回环(blackhole);(b) 防火墙放行 udp443 from 172.22、不再 reject。
  - 注:本机为 Windows 开发盒,无可运行 Python/Linux 运行时;shell policy 测试以 CI/Linux 为准(见 [[dev-box-no-python]])。

## 8. 回滚

- `etc/sniproxy.conf` 与旧 `sniproxy.service` 保留于 git 历史;迁移失败可 `systemctl` 切回旧单元 + 恢复防火墙 `reject`。
- install 中 xray 与 sniproxy 为二选一(直接替换;如需保留并存开关,实现期再定)。

## 9. 风险

- xray 资源占用高于 sniproxy(Go 运行时 + GC),低内存盒子需观察。
- root 运行 + 公网 UDP 443:攻击面与 UDP 滥用面增大,依赖 systemd sandbox + 仅放行 172.22 来源。
- xray 版本锁定与升级:release 二进制需定期校验更新。
