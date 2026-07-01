# 5gpn 交付报告 / Handoff

- 日期:2026-06-28(架构更新说明 2026-07-01)

> **⚠️ 本文档为历史归档**:本 Handoff 记录的是 smartdns 时代的架构与改动,此后经历了**多次架构反转**(smartdns → 自研 `5gpn-dns`;控制面 DoT-only/tgbot-only → DoT+DoH+明文53 / tgbot+HTTPS API+Web UI;Phase 5:Telegram bot + iOS 分发收进守护进程为进程内 Go,Python 全部移除、CI 去 Python),正文内容已全面过期,**不代表当前状态**。当前权威设计见 [DESIGN.md](DESIGN.md) 与仓库根的 `CLAUDE.md`;上线验收清单见 [tests/integration-smoke.md](../tests/integration-smoke.md)。本文件仅保留作历史参考,不再更新正文。

---

## 当前状态摘要(2026-07-01)

- **DNS 大脑**:自研 Go 二进制 `5gpn-dns`(`cmd/5gpn-dns/`),smartdns + chinadns-ng 已移除。
- **入口**:DoT :853 + DoH :8443 + 明文 DNS :53(per-source 限速),四类确定性规则(adblock/force-direct/blacklist/chnroute 仲裁)+ 订阅自动更新。
- **控制面**:Phase 3 已实现——`:9443` bearer-token HTTPS REST API + 内嵌 React Web UI(`go:embed`),监听所有网卡但由 `setup-firewall.sh` 限制仅 CLIENT_NET 可达;`DNS_API_TOKEN` 为空则不提供 HTTP 控制面。**Telegram bot 自 Phase 5 起为 `5gpn-dns` 守护进程内的 Go 组件**(`cmd/5gpn-dns/bot.go`,`github.com/go-telegram/bot`,`TGBOT_TOKEN`/`TGBOT_ADMINS` 管理员门控),**直接调进程内 `Controller`**(不经 :9443 / 不需 token),与 Web UI 并存;iOS 描述文件分发亦为进程内服务(`cmd/5gpn-dns/iosd.go`,:8111)。**Python 全部移除**,CI 已去 Python。
- **出口**:仍是唯一直出(sing-box `direct` inbound 透传 + 网关默认路由),无隧道/多出口/mark,此项从未反转。

## 当前上线前 checklist(Linux 真机)

> 详细步骤见 [tests/integration-smoke.md](../tests/integration-smoke.md);这里只列必过项:

- [ ] `5gpn-dns` 服务 active,DoT/DoH/明文 :53 均可查询到正确结果。
- [ ] `:9443` 已绑定(`ss -ltnp | grep 9443`),且 `DNS_API_TOKEN` 已在 `/etc/5gpn/dns.env` 中设置(非空)。
- [ ] 防火墙确认 `:9443` 仅 CLIENT_NET 可达(`nft list ruleset` 中 9443 规则的来源限制),公网侧连接被拒绝/超时。
- [ ] 进程内 Telegram bot(`TGBOT_TOKEN` 已设时)active,管理员可通过 bot 命令正常查状态/增删域名(直接调进程内 `Controller`,不经 :9443)。
