# 5gpn

[简体中文](README.md) | [English](README.en.md)

**5gpn 是一个面向可路由 IPv4 客户端的 DoT-only DNS steering gateway。**
它通过 DNS 答案决定连接应被阻断、由客户端直连，还是进入网关；进入网关后的应用层出口完全交给运维者拥有的 mihomo 配置。Android 和 iOS 可以使用系统原生 DoT，不需要安装常驻客户端。

> [!IMPORTANT]
> 本项目仍处于 pre-release。本文描述当前源码树；quick installer 安装的是最新已发布 tag，因此已发布版本的功能可能暂时落后于 `HEAD`。部署前请核对 [Releases](https://github.com/moooyo/5gpn/releases)。

> [!WARNING]
> 只管理你已获授权的网络和流量。可选的原生扩展能够在设备信任私有 CA 后解密和修改流量；启用前必须理解其权限与数据披露风险。软件许可见 [MIT License](LICENSE)。

## 5gpn 是什么

5gpn 把 DNS 决策层和应用流量出口层明确分开：

- `5gpn-dns` 是 DNS 决策引擎和控制面，只决定“阻断、直连或进入网关”。
- mihomo 是数据面；流量进入网关后，由 `/etc/5gpn/mihomo/config.yaml` 决定最终出口。
- `5gpn-intercept` 是默认关闭的可选 sidecar，只处理已启用扩展明确声明的 capture hosts。

它不是 VPN、全隧道或默认路由器，不自带代理节点，也不安装或管理 TUN、TProxy、WireGuard、NAT、fwmark、策略路由或宿主防火墙。客户端 DNS 入口只有 DoT `:853`；没有公共 DoH，也没有客户端明文 DNS `:53`。

## 工作原理

```text
Android Private DNS / iOS configuration profile
                       |
                       | DoT :853
                       v
                  5gpn-dns
             ordered DNS policy
          block / direct / proxy + fallback
              /                    \
     real origin IPv4          gateway IPv4
            |                       |
            v                       v
       client direct                 mihomo
                              /                 \
                    normal traffic     enabled capture host
                          |                  (optional)
                          |                       |
                operator-owned rules       5gpn-intercept
                          |                       |
                          |      authenticated mihomo SOCKS5 return
                          |                       |
                          |        operator binding / terminal target
                          \_______________________/
                                      |
                                operator egress
```

DNS 策略是一个全局有序、first-match 的规则列表：

| 决策 | DNS 结果 | 后续路径 |
| --- | --- | --- |
| `block` | `NXDOMAIN` | 客户端不建立连接 |
| `direct` | 采纳的真实 IPv4 | 客户端直连源站 |
| `proxy` | 网关 IPv4 | 客户端 → mihomo → 运维者配置的出口 |
| fallback `auto` | China 答案包含 `chnroute` A 时采纳 China，否则采纳 trust；采纳回复中命中 `chnroute` 的 A 保留真实地址，其余 A 改写为网关地址 | 确定性采纳并逐 A 改写，不按最快响应决定 |
| fallback `direct` | 采纳的真实 IPv4 | 不论 `chnroute` 结果都直连 |
| fallback `gateway` | 网关 IPv4 | 不查询上游，直接进入网关 |

上表描述成功的 A 答案。采纳或改写上游 response 时，5gpn 会保留其 Rcode 与 authority；`NXDOMAIN` 和 `SERVFAIL` 不会被改成 `NOERROR`。

`auto` 会并发查询 China 和 trust 两个上游组；组内成员按配置顺序串行尝试，并公平分配剩余 deadline。新安装默认使用 `223.5.5.5:53` 和 `22.22.22.22:53` 的 UDP 上游，之后可在控制台配置。A 查询执行上述策略；AAAA、HTTPS 和 SVCB 返回带 authority 的 NODATA，其他类型通过 trust 组解析。

启用扩展后，其 capture-host overlay 会先于运维者 DNS 规则把对应名字导向网关，但仍不能选择 mihomo 节点或代理组。扩展的 egress 和 capture DNS 绑定属于另一项经过确认的数据面事务。

## 核心能力

- **DoT-only 接入**：Android Private DNS 与 iOS 描述文件共用 `dot.<base>`，本机调试 DNS 只监听 `127.0.0.1:5353/udp`。
- **可审计的 DNS 策略**：exact、suffix、keyword 与 subscription 匹配统一进入有序的 `block`、`direct`、`proxy` 规则和单一 fallback。
- **运维者拥有的数据面**：完整 mihomo YAML 没有 daemon 生成区；普通安装、重装和 `configure` 会逐字节保留有效文件。
- **统一控制面**：React Console 提供状态、配置向导、DNS 日志与诊断、策略、上游、mihomo 状态与配置、扩展、marketplace 和日志；Telegram bot 复用同一后端状态与事务。
- **可选原生扩展**：严格的 `5gpn.io/v1` 快照、精确 capture hosts、typed settings、权限审阅、显式执行顺序和 operator-selected egress binding。
- **事务化安装**：精确 tag、SHA-256 校验、staging、原子发布、readiness probe 和失败回滚；网关不安装 Go 或 Node 工具链。

## 安装要求

开始前需要：

- 一台带 systemd 的 Linux amd64 网关和 root 权限。安装器直接支持使用 apt 或 dnf/yum 的发行版；其他发行版只有在检测到上述包管理器时才会尽力适配。
- 首次安装可用的交互 TTY。`curl | sudo bash` 会尝试重新连接 `/dev/tty`；没有 TTY 时首次安装会 fail closed。
- 至少一个已分配给本机接口、客户端可路由到达的非回环 IPv4。5gpn 的 steering 路径是 IPv4-only；IPv6-only 客户端无法到达网关，除非网络提供 CLAT 等 IPv4 可达性。
- 一个自有 base domain。系统会派生 `dot.<base>`、`console.<base>` 和 `zash.<base>`。
- `console.<base>` 指向公网或客户端可路由网关 IPv4 的 A 记录。Android 首次启用 Private DNS 前，`dot.<base>` 还必须能通过客户端原有 resolver 解析。
- 由云安全组或独立防火墙控制入口来源。5gpn 不创建、修改或删除宿主防火墙规则。

三个 IPv4 配置承担不同角色：

- `DNS_PUBLIC_IP` 是部署的公网身份，也是 HTTP-01 A 记录目标；
- `DNS_GATEWAY_IP` 是 DNS 返回给客户端、且客户端实际可路由到的网关地址；
- `DNS_MIHOMO_LISTEN_IPS` 是 mihomo 在本机实际绑定的非回环 IPv4 列表，通常包含 `DNS_GATEWAY_IP`。不要把仅存在于 NAT 外侧的公网地址直接用作本机 bind 地址。

### 部署入口

TCP `853` 是 `5gpn-dns` 的固定客户端入口。其余数据面 listener 来自新建或显式 reset 的 mihomo seed；已有有效 YAML 始终以运维者配置为准。

| 端口 | 用途 |
| --- | --- |
| TCP `853` | 唯一客户端 DNS 入口（DoT） |
| TCP `443` | Console HTTPS 与 DNS-steered TLS/HTTP 流量 |
| TCP `80` | DNS-steered HTTP；HTTP-01 challenge 也需要它 |
| TCP `8080`, `8443` | 需要可见 HTTP Host 或 TLS SNI 的显式备用 Web 入口 |
| TCP/UDP `5060` | 默认启用的 `speedtest-5060` 模块；不支持 SIP、Ookla native UDP 或通用 raw UDP |
| UDP `443` | 保持监听；默认 `block-quic-443` 规则拒绝到达网关的 UDP/443，以便有能力的客户端回退到 TCP |

只开放实际需要的入口。`speedtest-5060` 是未认证的 Host/SNI relay，公网部署必须限制来源。`block-quic-443` 不是防火墙规则，不会关闭 socket，也不能保证每个客户端都会回退。

## 证书模式

首次安装 TUI 会要求选择以下一种模式。两个生产模式都只使用一个名为 `<base>` 的 scoped Certbot lineage，并把证书部署到 dot、web 和 zash 三个角色目录。

| 模式 | 证书与 DNS 要求 | 续期行为 |
| --- | --- | --- |
| `cloudflare` | DNS-01；证书 SAN 为 `<base>` 与 `*.<base>`；需要仅具 `Zone:DNS:Edit` 的 token。经固定 resolver `1.1.1.1`，`console.<base>` 必须恰有一个直接 A，指向 `DNS_PUBLIC_IP` 或内网部署的 `DNS_GATEWAY_IP` | 不停止 mihomo |
| `http-01` | 经固定 resolver `1.1.1.1`，`console.<base>`、`zash.<base>`、`dot.<base>` 必须各有且仅有一条指向 `DNS_PUBLIC_IP` 的公共 A，不能有 AAAA，TCP `80` 必须公网可达 | 首次签发和到期续期都会短暂停止 mihomo 释放 `:80`，结束后恢复 |
| `debug` | 隔离的自签证书，不使用 Certbot，不受客户端默认信任 | 仅用于测试 |

Cloudflare token 只写入 root-only 的 `/etc/5gpn/acme/cloudflare.ini`，不会进入 `dns.env`、调用者环境或日志。可选 interception 使用完全独立的私有根 CA，不会替换 DoT 或 Console 公网证书。

## 快速安装

安装最新正式版：

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
```

显式安装最新 beta prerelease：

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash -s -- --beta
```

从 checkout 启动时使用：

```bash
sudo bash install.sh
sudo bash install.sh --beta
```

源码安装器也会先解析并委托给一个经过校验的精确 release bundle，避免把某个 tag 的二进制与另一份脚本或模板混用。默认通道只接受 `X.Y.Z`；`--beta` 只接受已发布的 `X.Y.Z-beta.N`，找不到合法 beta 时不会回退到正式版。

首次安装通过 TUI 收集配置并原子写入 `/etc/5gpn/dns.env`。重装只读取该文件，不把调用者环境当作配置输入。下载、摘要、证书、渲染或 readiness 校验失败时，安装器会保留或恢复之前可运行的部署。

## 安装后

先检查服务状态：

```bash
sudo 5gpn status
```

最小服务与 DNS 验证：

```bash
sudo systemctl is-active 5gpn-dns mihomo
sudo /opt/5gpn/bin/mihomo -t -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo

DOT=dot.example.com
GW=203.0.113.10
dig +tls @"$GW" -p 853 example.com A +tls-host="$DOT"
dig @127.0.0.1 -p 5353 example.com A
```

把示例域名和地址替换为实际值。公网 plain DNS `:53` 失败、远端无法访问 `:5353`、fresh install 中 `5gpn-intercept.service` 为 inactive 都是预期行为。完整实机清单见 [tests/integration-smoke.md](tests/integration-smoke.md)；它只应在一次性或明确指定的 Linux 网关上执行。

然后访问 `https://console.<base>/`。SPA 资源和两个 iOS profile 下载端点是公开的，但每个 `/api/*` 请求都需要 Console bearer token；前端登录页本身不是安全边界。需要在主机上找回 token 时：

```bash
sudo sed -n 's/^DNS_API_TOKEN=//p' /etc/5gpn/dns.env
```

- **Android**：在 Console 的 Setup Guide 中查看 `dot.<base>`，然后填入系统 Private DNS。现代 Android 应用通常不信任用户 CA，因此项目不提供 Android MITM CA 安装流程。
- **iOS**：在 Setup Guide 下载并安装 `/ios/ios-dot.mobileconfig`。若使用扩展，再单独安装 `/ios/ios-intercept-ca.mobileconfig`，并在系统设置中手动启用 Full SSL Trust。
- **zashboard**：先把来源 CIDR 加入白名单，再从 Console 发起一次性 handoff。`https://zash.<base>/` 的来源白名单和短时 session 是独立于 Console token 的边界。

Console 包含 `/overview`、`/setup-guide`、`/logs`、`/resolve-test`、`/policy-rules`、`/extensions`、`/extensions/hosts`、`/marketplace`、`/plugin-logs`、`/mihomo`、`/mihomo-config` 和 `/settings`。Console 只暴露窄化的 mihomo API；完整 controller pass-through 只属于单独保护的 zashboard。mihomo logs 与 plugin logs 使用不同的短时一次性 WebSocket ticket。

Telegram bot 运行在 `5gpn-dns` 进程内，可从 Console Settings 或下列 TUI 配置：

```bash
sudo 5gpn setup-tgbot
```

Bot 仍需要 Telegram bot token 和管理员白名单；除用于发现数字 user ID 的 `/id` 外，状态、日志与操作只接受授权管理员的 private chat。它不使用 Console bearer token。复杂 DNS policy 编辑与完整 mihomo YAML 仍留在 Web Console。

## 配置所有权

| 路径 | 所有权与用途 |
| --- | --- |
| `/etc/5gpn/dns.env` | 安装身份与 daemon knobs 的持久 source of truth |
| `/etc/5gpn/policy.json` | 有序 DNS policy 与 fallback |
| `/etc/5gpn/upstreams.json`, `ecs.json`, `subscriptions.json`, `rules/` | 控制面 override、订阅和完整缓存 |
| `/etc/5gpn/mihomo/config.yaml` | 运维者完整拥有的 mihomo 配置 |
| `/etc/5gpn/mihomo/whitelist.txt` | zashboard 来源白名单 |
| `/etc/5gpn/intercept/config.json` | interception master、协议设置和扩展快照状态 |
| `/etc/5gpn/extension-marketplaces.json` | 明确添加的 marketplace 源和最后一份完整缓存 |

普通 install、reinstall 和 `configure` 会先用 `mihomo -t` 验证已有配置，再逐字节保留它。只有显式 `mihomo-reset` 或 TTY 确认的 `upgrade-reset-mihomo` 能在备份、完整校验和原子 rename 后替换它。`configure` 若发现新域名、gateway 或 listener 与现有 operator-owned YAML 不兼容，会在写入前中止，而不是暗中修改数据面。

fresh/reset seed 的 `Proxies` 组初始只有 `DIRECT`；5gpn 不附带代理节点。直接执行 `sudo 5gpn mihomo-reset` 会显示替换警告，但不会再次要求确认，运行前必须准备好从备份恢复自定义 proxies、providers、groups 和 rules 的方案。

`SIGHUP` 或 `reload-rules` 只重载 policy 编译结果与 `chnroute`。`dns.env` 中的普通 daemon knob 变更需要 restart；证书会按文件变化热加载。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `sudo 5gpn` | 打开交互管理菜单 |
| `sudo 5gpn status` | 查看服务、域名、地址和规则状态 |
| `sudo 5gpn restart` | 重启 `5gpn-dns`、`5gpn-intercept` 和 mihomo |
| `sudo 5gpn configure` | 打开完整配置 TUI，校验后事务化应用 |
| `sudo 5gpn reload-rules` | 从磁盘热重载本地 policy 与 `chnroute` |
| `sudo 5gpn add-allow <cidr>` | 添加 zashboard 来源 CIDR 并实时刷新 |
| `sudo 5gpn del-allow <cidr>` | 删除 zashboard 来源 CIDR 并实时刷新 |
| `sudo 5gpn ios` | 重新生成 iOS profile 与二维码 |
| `sudo 5gpn setup-tgbot` | 校验并热应用 Telegram 配置 |
| `sudo 5gpn rotate-token` | 轮换 Console token 并重启 daemon |
| `sudo 5gpn set-cf-token` | 通过 TUI 更新 Cloudflare token |
| `sudo 5gpn mihomo-reset` | 备份并以当前有效 seed 替换完整 mihomo YAML |
| `sudo 5gpn uninstall` | 所有权校验后卸载，默认保留配置与证书状态 |
| `sudo 5gpn uninstall --purge` | 清除更多项目状态，但仍保留证书、ACME 与 interception CA |
| `sudo 5gpn uninstall --decommission` | 仅在 provenance 证明归 5gpn 所有时删除精确证书 lineage 与私有 CA |

## 原生扩展

原生扩展是可选功能，fresh install 的 MITM master 默认关闭。`5gpn-intercept.service` 此时保持 inactive；只有 master 打开且至少一个扩展启用后才启动：

- 只接受严格的 `5gpn.io/v1` YAML。URL manifest 与引用的远程脚本经 HTTPS/redirect/SSRF 防护抓取一次；local add 接受一份粘贴或上传的 manifest。所有输入都受大小限制、计算摘要并保存为不可变本地快照；安装和更新后都保持 disabled。
- `traffic.captureHosts` 是唯一的流量获取权限。启用后仅匹配声明的 exact 或受限 wildcard hosts，并只捕获端口 `80`/`443` 上的 HTTP、TLS 与可识别 QUIC。
- 扩展可以在 MITM master 关闭时保持 armed，但此时并不 ready，也不会发布 DNS overlay、mihomo capture rules 或启动 sidecar；只有扩展与 master 同时启用后才会接管流量。
- 每个 action 在全新的、有界 goja VM 中运行；只有 manifest 明确申请时才提供有配额的 `context.storage`，且没有 filesystem、process、timer、module loader、socket、ambient `fetch` 或直接出口。所有 upstream TCP/UDP 和允许的脚本网络请求都返回 mihomo。
- 扩展可以要求运维者从已有 mihomo group 中选择 egress，但 manifest 和脚本不能命名或修改 group。启用确认中审阅的全局 routing rule 只允许 `REJECT` 或 `DIRECT`，且只在扩展与 MITM master 同时启用时存在。
- 执行顺序会影响 action composition、重叠 host 的 egress/capture-DNS winner 和 routing first-match，因此重排也必须确认。
- marketplace 只是 discovery metadata，不是信任根；不会自动安装、启用、更新、抓取或镜像内容。第一方扩展源码位于独立的 [moooyo/5gpn-extensions](https://github.com/moooyo/5gpn-extensions) 仓库，并发布[官方 marketplace index](https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json)。
- Plugin engine logs 只存在于 sidecar 的 1000-entry 内存 ring。暂停或清除 Console 视图不会停止采集或删除 sidecar ring，进程退出后日志消失。

> [!CAUTION]
> 若 manifest 声明并由运维者确认 exact HTTP(S) origins，脚本可以把它可见的任何已解密请求、响应、setting 或 storage 数据发送到这些 origins。允许的 cross-origin URL rewrite 会转发完整 method、decoded body 和 end-to-end headers，其中可能包含 `Cookie` 或 `Authorization`。启用确认会列出每个 origin 和每条 routing rule；快照变化后必须重新审阅。

私有 CA 的签名密钥只允许 root-owned certificate publisher 读取；运行时 sidecar 只能读取受限 leaf，无法取得根私钥。安装私有 CA 也不保证每个应用都能被捕获。Certificate pinning、mTLS、应用内预置 ECH 和没有 HTTP 语义的协议会 fail closed。完整 manifest 合同见 [docs/native-extensions.md](docs/native-extensions.md)。

## 升级与发布通道

- 默认 quick installer 只安装最新正式版；`--beta` 是显式、单次的 beta opt-in，不会写入 `dns.env`。
- 常规 stable-to-beta 升级会保留有效的 operator-owned mihomo YAML。若旧 YAML 没有 interception scaffold 且当前没有 active interception runtime，核心 DNS、Console、Telegram 和现有数据面可以升级，但 Extensions 会明确报告 unavailable；不兼容的 active interception 会中止并回滚。
- `upgrade-reset-mihomo` 会替换完整 YAML；自定义 proxies、providers、groups 和 rules 不会自动合并，只能从备份手工恢复。
- 成功升级到 beta 不承诺原地降级到正式版；需要回退能力时，应在升级前保留系统快照。
- 所有仍使用 interception config schema v4 的 pre-v5 部署都需要先做显式、可恢复的 lockstep rebuild；不要删除旧 interception 文件或只改 schema version。请严格执行 [pre-v5 rebuild runbook](docs/pre-v5-upgrade.md)。

## 安全边界与已知限制

- 名称级 encrypted-DNS blocking 无法阻止使用硬编码 resolver IP 且能绕过网关的客户端。5gpn 不声称提供网络层强制执行。
- Steering 依赖 DNS 和可见 hostname。任意端口、通用 raw UDP、没有可用 Host/SNI 的流量、应用内 ECH inner name 以及绕过 5gpn DNS 的连接不受支持。
- `block-quic-443` 只拒绝到达网关的 UDP/443；它不管理防火墙，也不影响绕过网关的流量。MITM 的 QUIC fallback protection 是另一项仅作用于已匹配 capture hosts 的控制。
- Console SPA 和 profile 下载公开，但所有 `/api/*` 都要求 bearer token；没有 token 时 API 整体禁用。zashboard 另受来源白名单和一次性 handoff session 保护。
- 扩展 root CA 的信任范围覆盖整个扩展子系统，但实际解密仍受启用的 capture hosts 限制。普通 uninstall 和 purge 为已注册设备保留该 CA；只有 explicit decommission 才尝试删除所有权可证明的 CA 与公共 lineage。
- 5gpn 不修改 nftables 或任何宿主防火墙。公共入口、特别是 `:5060`，必须由运维者限制到预期客户端。

完整、规范的当前系统边界见 [docs/architecture.md](docs/architecture.md)。

## 开发与验证

仓库包含两个独立 Go module（均声明 Go `1.26.5`）和一个 Node 22 Web 工作区。完整本地 gate：

```bash
for s in install.sh quick-install.sh scripts/*.sh; do bash -n "$s"; done
for t in tests/test_*.sh; do bash "$t"; done

(cd cmd/5gpn-dns && test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...)
(cd cmd/5gpn-intercept && test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...)

(cd web && npm ci && npm run typecheck && npx vitest run && npm run build && npm run bundle:check)
(cd web && npx playwright install --with-deps chromium && npx playwright test)
```

CI 还会执行 `govulncheck`，并使用 digest-pinned mihomo 渲染和验证 seed。真实 Linux 网关行为按 [tests/integration-smoke.md](tests/integration-smoke.md) 验收。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| `cmd/5gpn-dns/` | DNS 决策引擎、控制面 API、Console backend 与 Telegram bot |
| `cmd/5gpn-intercept/` | 按需启动的原生扩展 HTTP/TLS/QUIC sidecar |
| `web/` | React、Vite、DaisyUI Console，Vitest 与 Playwright 测试 |
| `etc/` | 配置样例、mihomo seed、systemd/polkit 单元与规则种子 |
| `scripts/` | 证书、规则、iOS profile 和 Telegram 运维 helper |
| `tests/` | Shell regression、升级 fixture 与 gateway smoke checklist |
| `docs/` | 当前架构、扩展 author contract 与升级 runbook |
| `.github/workflows/` | 共享 CI gate 与精确 tag release pipeline |
| `install.sh`, `quick-install.sh` | 事务安装器与可信 release 入口 |

## 文档与许可

- [当前架构](docs/architecture.md)
- [原生扩展开发规范](docs/native-extensions.md)
- [Pre-v5 rebuild 与 release-channel upgrade](docs/pre-v5-upgrade.md)
- [Linux gateway integration smoke checklist](tests/integration-smoke.md)
- [官方扩展仓库](https://github.com/moooyo/5gpn-extensions)
- [Releases](https://github.com/moooyo/5gpn/releases) 与 [Issues](https://github.com/moooyo/5gpn/issues)
- [MIT License](LICENSE) 与 [Third-party notices](THIRD_PARTY_NOTICES.md)
