# 设计:5gpn-dns Phase 3 —— 公开 API + Web 控制台(与 tgbot 并存)

- 状态:已批准方向,待 spec 评审
- 日期:2026-07-01
- 范围:给 `5gpn-dns` 加一个**独立的 HTTPS 控制面**(端口 :9443,复用 LE 证书,Bearer token 鉴权,防火墙受限):REST API + 内嵌 **React+Vite+Tailwind Web 控制台**,用于查询(域名判定/解析/统计)和控制(管订阅、增删手动规则、触发更新、reload)。**tgbot 改造为这套 API 的客户端**,与 Web UI 并存、同一后端。API 全部调 Phase 2 交付的 `Controller`。DNS 解析面(DoT/DoH/plain)与 sing-box 不变。
- 关联:[2026-07-01-5gpn-dns-p2-subscriptions-design.md](2026-07-01-5gpn-dns-p2-subscriptions-design.md)(交付 `Controller`,本案的后端)、[2026-06-30-5gpn-dns-go-design.md](2026-06-30-5gpn-dns-go-design.md)(P1 引擎)。**本案有意重新引入 P1 CLAUDE.md 里已标"计划中"的公开 API + Web UI。**

---

## 1. 背景与约定推翻

P1 的 CLAUDE.md 记了"控制面只有 tgbot、无 HTTP API/web UI(P3 计划重新引入,与 tgbot 并存)"。本案落地它。用户选定:**单独端口**(管理面与公开 DoH 隔离,防火墙可只放行管理网段)、**前端框架**(React+Vite+Tailwind,CI 构建)、**tgbot 改调 API**。新增一条 CI 依赖:**node(仅 CI 构建前端;盒子上仍只下预编译二进制)**。

## 2. 既定决策(2026-07-01)

| 决策点 | 选择 | 理由 |
|---|---|---|
| 监听 | **独立 :9443 HTTPS**(复用 LE 证书) | 管理面与公开 DoH:8443 隔离;防火墙可单独收紧 |
| 鉴权 | **Bearer token**(装机生成、存 dns.env `DNS_API_TOKEN`) | 简单、无状态;UI 登录页填 token |
| 防火墙 | :9443 默认只放行 `CLIENT_NET`(NPN)/管理网段,**不对全网开** | 管理面不该像 DoH 那样公开 |
| Web UI | **React + Vite + Tailwind**,`vite build` 产物 `go:embed` 进二进制 | 用户选框架;CI 构建;盒子无工具链不变 |
| 后端 | API handlers 是 P2 `Controller` 的薄封装 | 逻辑复用;引擎不动 |
| tgbot | **改成 API 客户端**(HTTP 调 :9443) | 用户定的"都调同一套 API";与 Web UI 并存 |
| 依赖 | 后端仅 stdlib `net/http`;前端 CI 依赖 node | 守最小后端依赖 |

## 3. 架构

```
                          ┌─ DoT:853 / DoH:8443 / plain:53  (公开解析面,不变)
客户端 ── 解析 ───────────┤
                          └─ 5gpn-dns 引擎 (P1) + 订阅管理器 (P2) ── Controller
运维 ── 管理 ──HTTPS:9443──┤ (Bearer token, 防火墙受限)
   ├─ Web 控制台 (React SPA, go:embed)  ── 调 /api/*
   └─ tgbot (改成 HTTP 客户端)          ── 调 /api/*
                          都经 Controller 改同一状态(订阅/规则/引擎)
```

- :9443 一个 `http.Server`(TLS,`GetCertificate` 复用 P1 的热加载 getter):`/api/*` = REST(token 鉴权),`/`+静态资源 = 内嵌 SPA(免鉴权,SPA 自己再拿 token 调 API)。

## 4. API(全部 `/api`,除登录探活外需 `Authorization: Bearer <token>`)

| 方法 路径 | 作用 | 后端 |
|---|---|---|
| `GET /api/status` | 版本、运行时长、各服务健康 | Controller.Stats + runtime |
| `GET /api/stats` | 总查询数、各类命中(direct/proxy/block)、缓存条数、上游用量 | Controller.Stats |
| `GET /api/lookup?domain=` | 该域名判定(direct/proxy/block)+ 解析出的 IP + 命中的类别/来源 | Controller.Lookup |
| `GET /api/subscriptions` | 列出订阅 | Controller.Subscriptions |
| `POST /api/subscriptions` | 新增订阅(body: category/name/url/format/interval/enabled) | Controller.AddSubscription |
| `PATCH /api/subscriptions/{id}` | 改 enabled/interval/url | Controller.AddSubscription(替换) |
| `DELETE /api/subscriptions/{id}` | 删订阅 + 其缓存 | Controller.RemoveSubscription |
| `POST /api/update` `?id=` | 立即拉取(id 缺省=全部),返回每条结果 | Controller.Update |
| `GET /api/rules/{cat}` | 列该类**手动**条目 | 读手动文件 |
| `POST /api/rules/{cat}` | 加手动条目(域名/CIDR) | Controller.AddRule |
| `DELETE /api/rules/{cat}` | 删手动条目 | Controller.RemoveRule |
| `POST /api/reload` | 重读所有规则文件 + 原子 swap | Controller.Reload |

- 输入校验:域名走 FQDN 正则(与引擎一致)、CIDR 走 `net.ParseCIDR`、category ∈ 四类、format ∈ 支持集。错误 → 4xx + JSON `{error}`。
- 鉴权中间件:比对 `DNS_API_TOKEN`(常量时间比较);缺/错 → 401。
- CORS:同源(UI 与 API 同端口),无需跨域;不加宽松 CORS。

## 5. `Controller.Lookup` / `Stats`(P3 补齐)

- `Lookup(name)`:复用引擎 handler 的**判定路径**(不实际改缓存):跑规则优先级 + 一次仲裁,返回 `{verdict: direct|proxy|block, reason: adblock|force-direct|blacklist|chnroute-cn|chnroute-foreign, ips: [...], upstream: china|trust}`。为可测,把 handler 的"决策"抽成一个纯函数 `classify(name) -> verdict` 供 Lookup 与 ServeDNS 共用。
- `Stats`:引擎侧原子计数器(P2 已起基础版)——总查询、按 verdict 计数、缓存条目、各上游成功/失败。`GET /api/stats` 序列化它。

## 6. Web 控制台(`web/`,React+Vite+Tailwind)

- 页面:**登录**(填 token)、**Dashboard**(status+stats 卡片、近况)、**订阅**(表格 CRUD + "立即更新")、**规则**(四类手动条目增删)、**查询测试器**(输 domain → 显示 verdict+IP+reason)、**日志/状态**(基础)。
- token 存 `localStorage`;所有 `fetch` 带 `Authorization`。401 → 回登录页。
- 构建:`web/` 独立 `package.json`;`vite build` → `web/dist/`;Go 侧 `//go:embed web/dist` 由 :9443 提供(SPA fallback 到 index.html)。
- 实现时用 **frontend-design 技能**把视觉做到位(Tailwind;深色/浅色;不做成模板脸)。
- 提交产物策略:`web/dist` **不提交**(CI 构建);dev 期本地 `vite build` 生成后 `go build`。

## 7. 安装 / 运维 / CI

- `install.sh`:装机**生成 `DNS_API_TOKEN`**(`openssl rand -hex 32`)写入 `/etc/5gpn/dns.env`,并在装完打印一次(或存 `/etc/5gpn/.api_token` 供 tgbot 读);env 加 `DNS_LISTEN_API=:9443`。
- 防火墙 `setup-firewall.sh`:放行 `ip saddr ${CLIENT_NET} tcp dport 9443 accept`(**不**对全网开;运维要公网访问需自行放宽,知悉风险)。
- systemd:无新增(API 在同一进程/同一二进制)。
- `tgbot.py`:重写为 **API 客户端**——读 `DNS_API_TOKEN` + `API_BASE=https://127.0.0.1:9443`(或网关地址),增删域名 → `POST/DELETE /api/rules/blacklist`,状态 → `GET /api/status`,刷新订阅 → `POST /api/update`,重启服务保留(systemctl)。移除直接改文件/调 install.sh 子命令的老路径。
- `.github/workflows/release.yml`:加前端构建 job/步骤——`actions/setup-node` → `cd web && npm ci && npm run build` → 再 `go build`(embed 生效)。`ci.yml` 加 `npm run build`(或至少 `tsc`/lint)+ 保留 `go test`。
- `CLAUDE.md`:落实反转——控制面 = tgbot **+ 公开 API + Web UI**(并存);新增 CI 依赖 node(仅前端构建;盒子无工具链不变);:9443 管理面(token+防火墙受限)。

## 8. 测试

- **Go 单测**:每个 API handler(用 `httptest`;鉴权 401、CRUD 订阅、rules 增删、lookup 判定、stats、update via httptest 上游);token 中间件(缺/错/对);SPA embed fallback。
- **前端**:基础组件/API 客户端单测(vitest)可选;至少 `vite build` 通过 + `tsc` 无错(CI 门)。
- **grep 策略**:install 生成 token + env DNS_LISTEN_API;防火墙放行 :9443 仅 CLIENT_NET;tgbot 调 API(无直接改文件);release.yml 有 node 构建。
- **真机(test-env)**:起带 :9443 的 5gpn-dns → `curl -k -H "Authorization: Bearer $T" https://127.0.0.1:9443/api/status` 通;无 token → 401;`/api/lookup` 判定正确;订阅 CRUD + update 生效;Web UI 首页可载(HTML 200);tgbot 客户端增删域名经 API 生效;防火墙 :9443 仅 CLIENT_NET 可达。

## 9. 风险 / 取舍

- **重新引入 API+UI+前端构建链**——有意推翻 P1 约定;node 只在 CI,盒子仍无工具链。
- 管理面是新攻击面:token 鉴权 + 防火墙受限 + 复用 LE 证书(HTTPS);token 泄露=全控,运维保管。
- tgbot 改造后依赖 API 可达(本机 :9443);API 挂则 tgbot 控制不可用(但解析不受影响,解析面独立)。
- SPA embed 让二进制变大(几百 KB~MB 级)——可接受。

## 10. 回滚 / 关系

- 回滚 = `git revert`;不设 `DNS_LISTEN_API` / 不放行 :9443 则控制面不起,退回 P2(订阅仍进程内跑)。
- 依赖 P2 的 `Controller`;本案只加 HTTP/UI/tgbot 层与 `Lookup`,不动引擎与订阅核心。
