# new-5gpn(全新重写版)

这是 5gpn 的**从零重写版本**,与上一级目录里的旧实现并存、互不影响。

## 与旧版的根本区别

| | 旧版(`../`) | new-5gpn(本目录) |
|---|---|---|
| DNS 大脑 | dnsdist + 自研 china-dns-race-proxy | **smartdns**(一个软件搞定:DoT 入口 + 并发竞速/测速 + 规则改写) |
| 分流依据 | gfwlist + chinalist 两张**域名表** | 一张小**强制代理域名表** + 一张 **chnroute 反集(非中国 IP)** |
| 国外站判定 | 看域名(gfwlist) | **解析后看 IP**:国外 IP → 改写成网关 IP 进代理 |
| 客户端接入 | DoT + 内网明文 53 | **仅 DoT(853)** |
| 出口 | sniproxy/quic-proxy + pxout/mark/策略路由 + sing-box/WireGuard 多出口 | sniproxy **直出**(无 mark / 隧道 / 多出口 / sing-box;**QUIC/UDP443 不代理**,客户端回退 TCP) |

核心思想没变(**解析即策略**:被代理的流量靠"把 DNS 解析成网关自己的 IP"funnel 进 sniproxy),只是把"DNS 大脑"从 dnsdist 体系换成 smartdns,用它原生的 `address` + `ip-alias` 实现"强制表 + chnroute"两级分流。被代理流量经 sniproxy 后**直接走网关默认路由出网**(只直出,不做多出口/隧道;QUIC/UDP443 不代理,客户端回退 TCP)。

## 状态

P1–P4 **代码已实现**;行为验收需在 Linux 网关上执行(见 [tests/integration-smoke.md](tests/integration-smoke.md))。完整设计见 [docs/DESIGN.md](docs/DESIGN.md)。要点:QUIC/HTTP3 **不代理**(UDP 443 在防火墙 `reject`,客户端回退 TCP);出口**仅直出**。

## 安装

在一台 root 权限的 Linux 网关上:

```bash
curl -fsSL https://raw.githubusercontent.com/moooyo/5gpn/main/quick-install.sh | sudo bash
# 或在 checkout 内:sudo bash install.sh
```

安装器会:装 smartdns、编译 sniproxy、签发并自动续期 Let's Encrypt 证书、渲染配置、装 DoT-only 防火墙、生成 iOS DoT 描述文件 + 二维码、拉起服务。

NPN-only(客户端在内网 172.22.0.0/16)部署:`export GATEWAY_IP=<网关内网地址>` 再运行安装器。

## 常用命令

```bash
sudo bash install.sh --status        # 服务/域名/列表 状态
sudo bash install.sh --update-lists  # 刷新 chnroute + 重渲染 + 重启 smartdns
sudo bash install.sh --add-domain d  # 强制代理某域名
sudo bash install.sh --del-domain d  # 取消强制代理
sudo bash install.sh --ios           # 重新生成 iOS 描述文件 + 二维码
sudo bash install.sh --setup-api     # 启用 HTTPS 控制 API(打印 token)
sudo bash install.sh --setup-tgbot   # 启用 Telegram 控制 bot
```

客户端接入:Android 私人 DNS 填网关域名;iOS 安装 DoT 描述文件(扫码)。

> 仅用于已获合法授权的企业组网与技术研究,请遵守所在地法律法规。
