# 5gpn

[简体中文](README.md) | [English](README.en.md)

**5gpn 是一个面向可路由 IPv4 客户端的 DoT-only DNS steering gateway。**
它通过 DNS 答案决定连接应被阻断、由客户端直连，还是进入网关；进入网关后的应用层出口完全交给运维者拥有的 mihomo 配置。Android 和 iOS 可以使用系统原生 DoT，不需要安装常驻客户端。

> [!IMPORTANT]
> 本项目仍处于 pre-release。本文描述当前源码树；quick installer 安装的是最新已发布 tag，因此已发布版本的功能可能暂时落后于 `HEAD`。部署前请核对 [Releases](https://github.com/moooyo/5gpn/releases)。

> [!WARNING]
> 只管理你已获授权的网络和流量。可选的原生扩展能够在设备信任私有 CA 后解密和修改流量；启用前必须理解其权限与数据披露风险。软件许可见 [MIT License](LICENSE)。

## 5gpn 是什么

5gpn keeps DNS decisions distinct from application-traffic egress inside one
long-running process:

- The `moooyo/mihomo` fork is the entire runtime: DoT DNS policy, forwarding,
  native-extension interception, Telegram, and the authenticated controller.
- zashboard is the static Console mihomo serves at `https://console.<base>/ui/`.
- This repository contains only the installer and operator TUI. It installs
  digest-pinned mihomo and zashboard release artifacts.

它不是 VPN、全隧道或默认路由器，不自带代理节点，也不安装或管理 TUN、TProxy、WireGuard、NAT、fwmark、策略路由或宿主防火墙。客户端 DNS 入口只有 DoT `:853`；没有公共 DoH，也没有客户端明文 DNS `:53`。

## 工作原理

```text
Android Private DNS / iOS configuration profile
                       |
                       | DoT :853
                       v
                    mihomo
             ordered DNS policy
          block / direct / proxy + fallback
              /                    \
     real origin IPv4          gateway IPv4
            |                       |
            v                       v
        client direct          in-process tunnel and rules
                                      |
                         optional HTTP/TLS capture hook
                                      |
                          goja actions and inner dial
                                      |
                       operator binding / terminal target
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

`auto` queries the China and trust upstream groups concurrently. Members within each group are attempted sequentially in configured order with fair slices of the remaining deadline. Fresh installations seed `223.5.5.5:53` and `22.22.22.22:53` into `/etc/5gpn/mihomo/gpn/dns.json`, the atomic source of truth for DNS policy and upstreams, after which the Console can hot-apply a revision-protected whole-document update. A member declares its transport by spec form: bare `IP[:port]` is UDP, `serverName@IP[:port]` is DoT, and `https://host/path@IP[:port]` is DoH. AAAA, HTTPS, and SVCB remain behind the documented IPv4-only NODATA boundary.

AAAA 的 NODATA 不只针对客户端。mihomo 嗅探出主机名之后，会在 `127.0.0.1:5354` 这个回源解析器上重新解析 origin，那里同样在查询任何上游之前就返回合成 NODATA。这一条是网关保持 IPv4-only 出口的实际保证：mihomo 对每个 origin 都会无条件发出 AAAA 查询，它的 `dns.ipv6` 并不能抑制该查询，只有顶层 `ipv6` 可以，而 `/etc/5gpn/mihomo/config.yaml` 完全归运维者所有，无法假定其中存在某个 seed 值。若放行 AAAA，mihomo 会拿到 origin 的真实 IPv6 并与 IPv4 竞速；IPv6 一侧一旦完成 TCP 握手，双栈回退就不会再触发，而拒绝或错误定位机房 IPv6 段的目标站会在应用层失败，此时已无任何可回退的余地。返回 NODATA 后 mihomo 只剩 IPv4 候选。代价是明确接受的：只发布 AAAA 的 origin（或以主机名配置的运维者节点）无法经网关访问 —— 在 IPv4-only 数据面上，即使拿到 IPv6 答案也同样拨不通。新装或显式 reset 的 mihomo seed 另外写入 `ipv6: false` 作为纵深防御。

当 MITM master 与扩展同时启用并进入 active state 后，capture-host overlay 会先于运维者 DNS 规则把对应名字导向网关，但仍不能选择 mihomo 节点或代理组。扩展的 egress 和 capture DNS 绑定属于另一项经过确认的数据面事务。

## 核心能力

- **DoT-only 接入**：Android Private DNS 与 iOS 描述文件共用 `dot.<base>`，本机调试 DNS 只监听 `127.0.0.1:5353/udp`。
- **可审计的 DNS 策略**：exact、suffix、keyword 与 subscription 匹配统一进入有序的 `block`、`direct`、`proxy` 规则和单一 fallback。
- **运维者拥有的数据面**：完整 mihomo YAML 没有 daemon 生成区；普通安装、重装和 `configure` 会逐字节保留有效文件。
- **Unified control plane**: zashboard covers status, setup, DNS logs and diagnosis, policy, upstreams, mihomo health and configuration, extensions, marketplace discovery, and logs. The Telegram bot is read-only and alert-only.
- **可选原生扩展**：严格的 `5gpn.io/v1` 快照、明确声明的 exact 与受限 wildcard capture-host allowlist、typed settings、权限审阅、显式执行顺序和 operator-selected egress binding。
- **Checked installation**: exact tags, SHA-256 verification, staging, atomic file publication, and readiness probes. Failures before publication leave the host untouched; failures during publication are reported as partial. No Go or Node toolchain is installed on the gateway.

## 安装要求

开始前需要：

- 一台带 systemd 的 Linux amd64 网关和 root 权限。安装器直接支持使用 apt 或 dnf/yum 的发行版；其他发行版只有在检测到上述包管理器时才会尽力适配。
- 首次安装可用的交互 TTY。`curl | sudo bash` 会尝试重新连接 `/dev/tty`；没有 TTY 时首次安装会 fail closed。
- 至少一个已分配给本机接口、客户端可路由到达的非回环 IPv4。5gpn 的 steering 路径是 IPv4-only；IPv6-only 客户端无法到达网关，除非网络提供 CLAT 等 IPv4 可达性。
- 一个自有 base domain。系统会派生 `dot.<base>` 和 `console.<base>`。
- 生产模式需要 `console.<base>` 指向公网或客户端可路由网关 IPv4 的 A 记录；`debug` 会跳过公共 DNS gate。Android 首次启用 Private DNS 前，`dot.<base>` 还必须能通过客户端原有 resolver 解析。
- 由云安全组或独立防火墙控制入口来源。5gpn 不创建、修改或删除宿主防火墙规则。

三个 IPv4 配置承担不同角色：

- `DNS_PUBLIC_IP` 是部署的公网身份，也是 HTTP-01 A 记录目标；
- `DNS_GATEWAY_IP` 是 DNS 返回给客户端、且客户端实际可路由到的网关地址；
- `DNS_MIHOMO_LISTEN_IPS` 是 mihomo 在本机实际绑定的非回环 IPv4 列表，通常包含 `DNS_GATEWAY_IP`。不要把仅存在于 NAT 外侧的公网地址直接用作本机 bind 地址。

### 部署入口

TCP `853` is mihomo's fixed client DNS ingress. The remaining data-plane listeners belong to a fresh or explicitly reset mihomo seed; an existing valid operator-owned YAML remains authoritative.

| 端口 | 用途 |
| --- | --- |
| TCP `853` | 唯一客户端 DNS 入口（DoT） |
| TCP `443` | Console HTTPS 与 DNS-steered TLS/HTTP 流量 |
| TCP `80` | DNS-steered HTTP；HTTP-01 challenge 也需要它 |
| TCP `8080`, `8443` | 需要可见 HTTP Host 或 TLS SNI 的显式备用 Web 入口 |
| TCP/UDP `5060` | 默认启用的 `speedtest-5060` 模块；不支持 SIP、Ookla native UDP 或通用 raw UDP |
| UDP `443` | Remains bound; one fixed global rule rejects gateway UDP/443 so capable clients can fall back to TCP |

Expose only what you need. `speedtest-5060` is an unauthenticated Host/SNI relay and must be source-restricted on public deployments. The UDP/443 guard is not a firewall rule, does not close the socket, and cannot guarantee that every client falls back. Product management cannot disable it; an H3-only client fails.

## 证书模式

首次安装 TUI 会要求选择以下一种模式。两个生产模式都只使用一个名为 `<base>` 的 scoped Certbot lineage，并把证书部署到 dot、web 和 console 三个角色目录。

| 模式 | 证书与 DNS 要求 | 续期行为 |
| --- | --- | --- |
| `cloudflare` | DNS-01；证书 SAN 为 `<base>` 与 `*.<base>`；需要仅具 `Zone:DNS:Edit` 的 token。通过固定解析器 `1.1.1.1` 查询时，`console.<base>` 的结果必须只包含一条 A、不得经过 CNAME，并指向 `DNS_PUBLIC_IP` 或内网部署的 `DNS_GATEWAY_IP` | 不停止 mihomo |
| `http-01` | 通过固定解析器 `1.1.1.1` 查询时，`console.<base>`、`dot.<base>` 的结果必须各自只包含一条指向 `DNS_PUBLIC_IP` 的公共 A、不得经过 CNAME 且不能有 AAAA，TCP `80` 必须公网可达 | 首次签发仅在 mihomo 原本 active 时停止；失败或信号会立即恢复，成功则在 lineage 与角色证书完整发布后由安装流程恢复。到期续期会短停 `:80`，并在成功或失败后恢复 |
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

The first installation collects configuration through the TUI and atomically writes `/etc/5gpn/dns.env`. Reinstall reads only that file and never treats the caller environment as configuration input. Preflight and staging fail before publication where possible; a failure during publication is reported as a partial installation rather than hidden behind a rollback claim.

## 安装后

先检查服务状态：

```bash
sudo 5gpn status
```

最小服务与配置验证：

```bash
sudo systemctl is-active mihomo
sudo /opt/5gpn/bin/mihomo -t -f /etc/5gpn/mihomo/config.yaml -d /etc/5gpn/mihomo
```

再使用具备 DoT 支持的 `dig` 验证 DNS：

```bash
DOT=dot.example.com
GW=203.0.113.10
dig +tls @"$GW" -p 853 example.com A +tls-host="$DOT"
dig @127.0.0.1 -p 5353 example.com A
```

Replace the example domain and address with actual values; skip the first DNS command when an older `dig` lacks `+tls`. Public plain DNS `:53` and remote access to `:5353` must fail. There is no `5gpn-dns` or `5gpn-intercept` service in the monolith. See [tests/integration-smoke.md](tests/integration-smoke.md) for the complete real-host checklist, and run it only on a disposable or explicitly designated Linux gateway.

Open `https://console.<base>/ui/`. The panel and two iOS profiles are public, while `/gpn/*` and the ordinary controller routes require mihomo's controller secret. On first open, enter that secret in zashboard. To recover it on the host:

```bash
sudo sed -n 's/^DNS_MIHOMO_SECRET=//p' /etc/5gpn/dns.env
```

- **Android**：在 Console 的 Setup Guide 中查看 `dot.<base>`，然后填入系统 Private DNS。现代 Android 应用通常默认不信任用户安装的 CA，因此项目不提供 Android MITM CA 安装流程。
- **iOS**：下载并安装 `https://console.<base>/ui/ios-dot.mobileconfig`。若使用扩展，再单独安装 `/ui/ios-intercept-ca.mobileconfig`，并在系统设置中手动启用 Full SSL Trust。
- **面板 (zashboard)**：`https://console.<base>/ui/`，对所有能解析到本网关的客户端开放。凭据只有 mihomo controller secret 一个，且只挡 `/api` 一侧——`/ui/` 与其下的描述文件是免鉴权的，因为未入网的手机身上没有 token。

The Console and mihomo controller share one process, origin, and controller secret. Plugin logs are read through the authenticated interception API; there is no second one-use ticket service.

The Telegram bot runs inside mihomo and is configured from Console Settings.

The bot requires a Telegram token and administrator allowlist. `/id` reports
the caller and chat IDs; configured administrators may use `/status` and
`/resolve <domain>`. The command surface is read-only: extension, policy,
certificate, service, log, and mihomo mutations remain Console or host
operations.

## 配置所有权

| 路径 | 所有权与用途 |
| --- | --- |
| `/etc/5gpn/dns.env` | 安装身份与 daemon knobs 的持久 source of truth |
| `/etc/5gpn/mihomo/config.yaml` | 运维者完整拥有的 mihomo 配置 |
| `/etc/5gpn/mihomo/gpn/dns.json` | Ordered DNS policy, upstreams, subscriptions, and resolver settings |
| `/etc/5gpn/mihomo/gpn/intercept.json` | Interception master, fixed-false HTTP/3 marker, catalogs, and extension snapshots |
| `/etc/5gpn/mihomo/gpn/bot.json` | Telegram switch, token, administrators, and alerts |

普通 install、reinstall 和 `configure` 会先用 `mihomo -t` 验证已有配置，再逐字节保留它。只有显式 `mihomo-reset` 或 TTY 确认的 `upgrade-reset-mihomo` 能在备份、完整校验和原子 rename 后替换它。`configure` 若发现新域名、gateway 或 listener 与现有 operator-owned YAML 不兼容，会在写入前中止，而不是暗中修改数据面。

fresh/reset seed 的 `Proxies` 组初始只有 `DIRECT`；5gpn 不附带代理节点。直接执行 `sudo 5gpn mihomo-reset` 会显示替换警告，但不会再次要求确认，运行前必须准备好从备份恢复自定义 proxies、providers、groups 和 rules 的方案。

Console writes hot-apply the revisioned mihomo `gpn` documents. Deployment values in `dns.env` change only through a validated installer run; certificates hot-reload when their files change.

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `sudo 5gpn` | 打开交互管理菜单 |
| `sudo 5gpn status` | 查看服务、域名、地址和规则状态 |
| `sudo 5gpn restart` | Restart mihomo |
| `sudo 5gpn configure` | 打开完整配置 TUI，校验后事务化应用 |
| `sudo 5gpn ios` | 重新生成 iOS profile 与二维码 |
| `sudo 5gpn rotate-token` | Rotate the mihomo controller secret and restart mihomo |
| `sudo 5gpn set-cf-token` | 通过 TUI 更新 Cloudflare token |
| `sudo 5gpn mihomo-reset` | 备份并以当前有效 seed 替换完整 mihomo YAML |
| `sudo 5gpn uninstall` | 所有权校验后卸载，默认保留配置与证书状态 |
| `sudo 5gpn uninstall --purge` | 清除更多项目状态，但仍保留证书、ACME 与 interception CA |
| `sudo 5gpn uninstall --decommission` | 仅在 provenance 证明归 5gpn 所有时删除精确证书 lineage 与私有 CA |

## 原生扩展

Native extensions are optional, and a fresh installation has the MITM master disabled. The engine remains inside mihomo; no sidecar service is started:

- 只接受严格的 `5gpn.io/v1` YAML。URL manifest 与引用的远程脚本经 HTTPS/redirect/SSRF 防护抓取一次；local add 接受一份粘贴或上传的 manifest。所有输入都受大小限制、计算摘要并保存为不可变本地快照；安装和更新后都保持 disabled。
- `traffic.captureHosts` is the sole traffic-acquisition permission. Only when both the extension and MITM master are enabled and ready does it capture plain HTTP or TLS/H1/H2 on ports `80` and `443`.
- HTTP/3 interception is unsupported. `http3=true` is rejected, and the fixed global UDP/443 `REJECT` has no product-management off switch. Fallback-capable clients may retry over captured TCP; H3-only clients fail.
- An extension may remain armed while the MITM master is off, but it is not ready and contributes no DNS overlay or in-process capture policy.
- Every action runs in a fresh, bounded goja VM. Quota-bound `context.storage` exists only when the manifest requests it. The sandbox exposes bounded action-scoped timers and, with the network grant, synchronous `request` plus promise-based `requestAsync`; it has no filesystem, process, module loader, socket, ambient `fetch`, or direct egress. All permitted network calls return through mihomo's inner dialer and current rule evaluation.
- 扩展可以要求运维者从已有 mihomo group 中选择 egress，但 manifest 和脚本不能命名或修改 group。启用确认中审阅的全局 routing rule 只允许 `REJECT` 或 `DIRECT`，且只在扩展与 MITM master 同时启用时存在。
- 执行顺序会影响 action composition、重叠 host 的 egress/capture-DNS winner 和 routing first-match，因此重排也必须确认。
- marketplace 只是 discovery metadata，不是信任根；不会自动安装、启用、更新、抓取或镜像内容。第一方扩展源码位于独立的 [moooyo/5gpn-extensions](https://github.com/moooyo/5gpn-extensions) 仓库，并发布[官方 marketplace index](https://moooyo.github.io/5gpn-extensions/marketplace/v2/index.json)。
- Plugin engine logs exist only in mihomo's 1000-entry memory ring. Pausing or clearing the Console view neither stops ingestion nor deletes that ring; the log disappears when the process exits.

> [!CAUTION]
> When a manifest declares `permissions.network: true` and the operator confirms it, the script may send any request or response data visible to it, including decrypted content, settings, and storage data, to any host it can reach. The grant has no destination allowlist. An authorized cross-origin URL rewrite forwards the complete method, decoded body, and end-to-end headers, potentially including `Cookie` or `Authorization`. The enablement confirmation names the unrestricted grant and every routing rule; any changed snapshot requires a new review.

Only the root-owned certificate publisher can read the private CA signing key; mihomo receives a constrained leaf and cannot access the root key. Installing the private CA does not guarantee that every application can be captured. Certificate pinning, mTLS, application-provisioned ECH, HTTP/3, and protocols without HTTP semantics are unsupported: the connection fails closed instead of bypassing interception. See [docs/native-extensions.md](docs/native-extensions.md) for the full manifest contract.

## 升级与发布通道

- 默认 quick installer 只安装最新正式版；`--beta` 是显式、单次的 beta opt-in，不会写入 `dns.env`。
- A normal channel transition uses one complete verified installer bundle and preserves a valid current operator-owned mihomo YAML byte for byte. Moving from the retired multi-process design to the monolith is a separate checked migration: it removes only the retired anchors and inbound from a candidate, rewrites the management-plane exclusion to `INNER`, requires the fixed UDP/443 guard, and publishes only after pinned `mihomo -t` succeeds.
- `upgrade-reset-mihomo` 会替换完整 YAML；自定义 proxies、providers、groups 和 rules 不会自动合并，只能从备份手工恢复。
- A successful beta upgrade does not guarantee that an in-place downgrade to the stable release channel is supported. Keep a system snapshot before upgrading when reversal is required. The installer does not claim whole-system rollback after publication begins.
- 所有仍使用 interception config schema v4 的 pre-v5 部署都需要先做显式、可恢复的 lockstep rebuild；不要删除旧 interception 文件或只改 schema version。请严格执行 [pre-v5 rebuild runbook](docs/pre-v5-upgrade.md)。

## 安全边界与已知限制

- 名称级 encrypted-DNS blocking 无法阻止使用硬编码 resolver IP 且能绕过网关的客户端。5gpn 不声称提供网络层强制执行。
- Steering 依赖 DNS 和可见 hostname。任意端口、通用 raw UDP、没有可用 Host/SNI 的流量、由应用内预置 ECH 隐藏的 inner name，以及绕过 5gpn DNS 的连接不受支持。
- The fixed global UDP/443 guard rejects only traffic that reaches the gateway. It is immutable through product management, does not manage a firewall, and does not affect ordinary UDP or QUIC sniffing on other configured ports such as `:5060`.
- Console SPA assets and profiles under `/ui/*` are public. `/gpn/*` and the ordinary controller routes require mihomo's controller secret; there is no second panel origin, source allowlist, handoff session, or Console bearer.
- 扩展 root CA 的信任范围覆盖整个扩展子系统，但实际解密仍受启用的 capture hosts 限制。普通 uninstall 和 purge 为已注册设备保留该 CA；只有 explicit decommission 才尝试删除所有权可证明的 CA 与公共 lineage。
- 5gpn 不修改 nftables 或任何宿主防火墙。公共入口、特别是 `:5060`，必须由运维者限制到预期客户端。

完整、规范的当前系统边界见 [docs/architecture.md](docs/architecture.md)。

## 开发与验证

This repository contains installer assets only. The local gate is:

```bash
for s in install.sh quick-install.sh scripts/*.sh; do bash -n "$s"; done
for t in tests/test_*.sh; do bash "$t"; done

tests/verify-artifact-pins.sh
```

CI renders and validates the seed with the digest-pinned mihomo binary. Validate real Linux gateway behavior with [tests/integration-smoke.md](tests/integration-smoke.md).

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| *(external: `moooyo/mihomo`)* | The single runtime: DNS, forwarding, HTTP/TLS interception, Telegram, and controller API |
| *(external: `moooyo/zashboard`)* | The React Console served by mihomo |
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
