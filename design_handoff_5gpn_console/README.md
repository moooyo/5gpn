# 交接：5GPN 控制台（Web 管理面板）

## 概述 Overview
5GPN 是个人自建的、管理自有几台服务器的代理/DNS 网关控制台。本设计是它的 **Web 管理面板**，蓝白配色、桌面为主并响应式，中文界面。核心页面：仪表盘、出口、订阅、规则、解析日志、解析测试、XRAY-CORE、设置。

## 关于设计文件 About the Design Files
本包内的文件是 **用 HTML 制作的「设计参考」（高保真原型）**，用于表达最终外观与交互意图，**不是可直接上线的生产代码**。任务是：**在目标代码库的现有技术栈里（React / Vue / SolidJS 等）用其既有的组件库与规范复刻这些设计**；若项目尚无前端环境，则自行选择最合适的框架实现。

> 文件为 `.dc.html` 格式的组件原型，浏览器直接打开即可预览（需与同目录的 `support.js` 一起）。请把它当"活的视觉稿+交互稿"来读，而非逐行照抄。

## 保真度 Fidelity
**高保真（hifi）**：颜色、字号、间距、圆角、阴影、交互均为最终值，请按下述设计令牌像素级复刻，并接入目标代码库既有的图标/组件体系。

---

## 产品工作原理（复刻时务必据此，勿臆造多节点隧道）
- 客户端经 **DoT :853**（TLS，`dot.<域名>` 的 Let's Encrypt 证书）作为唯一 DNS 传输接入。
- 核心 Go 单进程 **`5gpn-dns`** 做 DNS 仲裁，顺序：① adblock 域名 → NXDOMAIN；② force-direct 白名单 → 真实 IP（直连）；③ blacklist 黑名单 → 网关 IP（代理）；④ 其余走 **chnroute 仲裁**（并发「国内 UDP ‖ 可信 DoT」，答案 IP ∈ chnroute 则直连，否则→网关 IP）。同进程还跑控制台 REST API + Web UI + iOS 描述文件（`:18443`，经 xray `:443` SNI 分流暴露）、Telegram bot。
- 出网由 **Xray-core**（dokodemo-door inbound，TCP 80 / TCP+UDP 443）执行；WebUI 域名 SNI → freedom redirect 到 `127.0.0.1:18443`（带 PROXY protocol 透传真实客户端 IP）；其余 SNI 经 `destOverride` 取名、`XRAY_RESOLVER` 重解析后走网关默认路由直接出网（**无隧道 / 无多出口 / 无策略路由**）。
- **关键含义**："切换节点" = **出口切换**（xray-core sniproxy 的 egress 切换），不是多节点隧道选择。UI 全用「出口 / Exit」。DNS 规则与分流(route)规则**解耦**（参考 sing-box 规则模型），规则集为「订阅」。

---

## 整体布局 App Shell
- 根：`100vw × 100vh`，`display:flex`，左侧栏固定 + 右侧主区。背景 `#eef4fc`。
- **侧栏 Sidebar**：宽 `236px`，白底 `#fff`，右边框 `1px solid #e2eaf4`，内边距 `18px 14px`。
  - 顶部品牌：`34×34` 圆角 `9px` 渐变徽标（`linear-gradient(135deg,#3b82f6,#2563eb)`）+「5GPN / 控制台」。
  - 导航**分 4 组**，组间用 `1px #eef1f6` 分割线，每组有小标题（`9.5px`、`#93a2bd`、`letter-spacing:1.5px`、700）：
    - 概览：仪表盘、出口
    - 解析：解析日志、解析测试
    - 规则与订阅：规则、订阅
    - 内核与系统：XRAY-CORE、设置
  - 导航项：`padding:10px 12px`、圆角 `9px`、图标 18px（stroke 1.9，`currentColor`）+ 13px/600 文字。选中态：底色 `rgba(37,99,235,.09)`、文字/图标 `#2563eb`、左内阴影条 `inset 3px 0 0 #2563eb`；未选 `#5b6b85`。
  - 底部**内核状态卡**（两条，`#eef4fc` 底、圆角 11px）：`DNS 服务器 · 5gpn-dns · :853 DoT · 运行中` 与 `Xray-core · v25.7.1 · sniproxy · 运行中`，各带绿点（`#22c55e`，`pulse` 呼吸动画）与绿色「运行中」。
- **顶栏 Topbar**：高 `66px`，白底，下边框 `1px #e2eaf4`。左：当前页**标题**（16px/700）+ **副标题**（11.5px、`#93a2bd`），二者 `white-space:nowrap`；标题只用单语（中文）。右：头像按钮（`admin` + 30px 圆形渐变头像 + 下拉箭头），点击展开下拉菜单。
- **主区 Main**：`flex:1;overflow-y:auto;padding:22px 24px`。**每个页面内容统一 `max-width:1180px`**。页面不再重复大标题（标题只在顶栏出现一次）。

### 顶栏各页标题 / 副标题
- 仪表盘 · 实时监控 · QPS / 流量 / 连接
- 出口 · 切换 Xray-core sniproxy 出口 · 非多节点隧道
- 订阅 · 节点与分流规则订阅
- 规则 · DNS 与分流解耦 · 参考 sing-box 规则模型
- 解析日志 · 5gpn-dns 最近解析历史 · 决策与结果
- 解析测试 · 输入任意域名，模拟 5gpn-dns 的解析决策
- XRAY-CORE · Xray-core 内核配置
- 设置 · 系统与服务配置

### 顶栏头像下拉
白卡、圆角 13px、阴影 `0 24px 46px -12px rgba(16,24,40,.24)`、宽 240px。内容：用户信息（admin / 超级管理员）→ 分割线 → **语言**分段（中文 / English）→ **主题**分段（浅色 / 深色 / 跟随系统）→ 分割线 → 退出登录（红 `#dc2626`）。分段控件：底 `#eef4fc`、圆角 9px；选中项白底 + `#2563eb` 文字 + `0 1px 3px rgba(16,24,40,.12)` 阴影，未选 `#93a2bd`。
> 注：主题三段切换的 UI 与状态已就绪，但**整体深色换肤尚未实现**（选「深色」仅切换高亮）——如需请在目标代码库实现完整 dark theme。

---

## 各页面 Screens

### 1. 仪表盘 Dashboard
- **4 个指标卡**（`grid` 四列，gap 15px）：下行速率(`#2563eb`)、上行速率(`#38bdf8`)、QPS(`#6366f1`)、活跃连接(`#f59e0b`)。每卡：标签(12px/600 `#5b6b85`) + 环比徽标(涨绿 `#16a34a` / 跌红 `#dc2626`) + 大数字(28px/800，等宽字体) + 单位 + 32px 高迷你面积折线（sparkline，`preserveAspectRatio=none`）。
- **流量趋势卡**：双线面积图（下行 `#2563eb` / 上行 `#38bdf8`），3 条水平网格线，图例，右上累计 ↓/↑（等宽），底部时间轴 -60s…now。
- **底部三卡**（`grid` 1.1 / .82 / 1.1）：QPS 实时（面积图）、协议分布（SVG 环形图 4 段：VLESS46% / VMess22% / Trojan20% / Shadowsocks12%）、当前出口（显示所选出口 + 延迟 + "管理出口→"跳转）。
- 数据 **模拟实时**：每 1300ms 推进一次，折线滚动。

### 2. 出口 Exits —— sing-box 风格 selector 选择器面板
- 页面是若干 **SELECTOR 分组卡**（白卡，圆角 14px）。分组：默认出口(6)、AI·智能分流(3)、Google(4)、Telegram(4)、流媒体(4)、国内直连(1·direct)、兜底·Fallback(3)。
- **分组头**（可点击展开/折叠）：左＝折叠箭头(展开旋转 90°) + 组名(14px/700) + `SELECTOR` 标记(9px、`#93a2bd`) + `已选/总数`(等宽)；右＝闪电测速图标(26px 圆角方 `#eef4fc` 底、`#2563eb` 图标) + 实时吞吐(等宽；默认出口显示实时 MB/s，其余 `0 B/s`)。
- **当前选中行**：蓝点 + 当前成员名(12px/600 `#5b6b85`)。
- **展开态**：成员卡网格（`flex-wrap`，卡 `min-width:158px`、圆角 10px、padding 10px 13px）。卡内：成员名(12.5px/700) + 底行(协议类型如 `vless / udp`，`opacity:.62` 等宽 + 延迟徽标)。**选中卡**：底 `#2563eb`、文字 `#fff`、延迟徽标底 `rgba(255,255,255,.22)`；未选：白底、`#e2eaf4` 边、延迟徽标底 `#eef4fc` + 延迟色文字。点击成员卡即切换该 selector 的出口。
- **折叠态**：健康圆点行（每成员一个 11px 圆点；选中=空心蓝环 `2px #2563eb`、透明心；其余=实心，按延迟着色）。
- 延迟配色：`<80ms` 绿 `#16a34a`、`80–160` 橙 `#d97706`、`>160` 红 `#dc2626`。
- 「默认出口」的选择联动仪表盘「当前出口」与规则页的「代理出口」名称。

### 3. 订阅 Subscription
两段（各带段标题）：
- **节点订阅**：段头 + "添加订阅"主按钮。一张卡内列订阅链接行（链接图标 + 等宽 URL(省略号截断) + "Xh 前更新 · N 个节点" + 绿色「正常」徽标 + 更新/编辑按钮）。下方**节点类型统计**卡：VLESS/VMess/Trojan/Shadowsocks 各自计数徽标 + "合计 N 个节点"。（不要"主力机房/备用"之类命名，不要测速。）
- **分流规则订阅**：段头 + "全部更新"。表格：规则集(等宽名) | 类型(远程/本地 + Geosite/GeoIP/Domain 徽标) | 格式(.srs 二进制 / 源列表) | 条目 | 更新时间 | 更新/编辑。行例：`geosite-geolocation-cn`、`geoip-cn`、`category-ads-all`、`force-direct 白名单`、`blacklist 黑名单`。

### 4. 规则 Rules（DNS 与分流解耦）
- 顶部两张**解耦说明卡**：① DNS 规则 — 决定"哪个解析器应答"（5gpn-dns 仲裁）；② 分流规则 — 决定"连接去哪个出口"（Xray-core）。
- **标签页**：DNS 规则 / 分流规则（选中底部 2.5px `#2563eb` 下划线 + `#2563eb`/700；未选 `#5b6b85`/600），标签行右侧有"新建规则"按钮。
- **DNS 规则表**：# | 匹配条件(sing-box 风格 chips：`rule_set`/`域名后缀`/`query_type`/`logical AND·OR`/`geoip`…) | 应答来源/动作(彩色 pill：NXDOMAIN 拦截红 / 可信直连解析绿 / 网关解析·DoT代理蓝 / chnroute 仲裁青) | 命中24h | 启用开关。
- **分流规则表**：# | 匹配条件(`protocol`/`port`/`ip_is_private`/`rule_set`/`域名后缀`/`logical`) | 出口动作(hijack-dns / 直连 direct / 代理出口·<出口名> / …) | 命中24h | 启用。
- 规则集不在本页（属于「订阅 / 分流规则订阅」）。

### 5. 解析日志 DNS Log
- 顶部右侧图例（直连绿 / 国内直连青 / 代理蓝 / 拦截红）+ 「实时」呼吸徽标。
- 表格：时间(等宽) | 域名(等宽，省略号) | 命中规则(chip) | 决策(彩点+彩字：强制代理/国内直连/拦截/强制直连/境外代理) | 结果 IP(等宽) | 耗时(等宽)。约 10 行历史。

### 6. 解析测试 DNS Test
- **输入卡**：标签"测试域名" + 输入框(带地球图标，等宽字体) + "测试"主按钮；下方"示例"chips（点击填入并运行）：`www.youtube.com` / `apple.com` / `baidu.com` / `ads.doubleclick.net` / `github.com` / `taobao.com`。
- **结果卡**（输入后显示）：顶行 `域名 → 决策 pill(按决策着色)`；三小卡（命中规则 / 解析来源 / 应答结果）；**决策路径**（编号步骤，圆序号按决策色）。判定逻辑见"工作原理"四步（adblock→拦截；force-direct 白名单→直连；blacklist 黑名单→代理；否则 chnroute 仲裁按国内/境外分流）。

### 7. XRAY-CORE
- 顶部**内核状态条**：图标 + Xray-core + 运行中徽标 + `v25.7.1` + 运行时间 + 「重启内核」「停止(红)」。
- 两列卡：**入站 · dokodemo-door**（TCP :80 开关、TCP+UDP :443 开关、`sniffing.destOverride` = tls/http/quic chips）；**出站 · freedom**（直接出网 · 无隧道/无多出口、`XRAY_RESOLVER` 输入框=占位 `22.22.22.22` 带琥珀色"需设为真实解析器"提示、日志级别 warning 下拉）。
- 底部 **WebUI SNI 分流** 说明卡（SNI==控制台域名 → freedom redirect 到 `127.0.0.1:18443` + PROXY protocol）。

### 8. 设置 Settings
两列卡 + 通栏：**DoT 服务**（DoT 域名输入、Let's Encrypt 证书 有效/到期）；**控制台**（监听端口 18443、管理员账号 + 修改密码）；**Telegram Bot**（启用开关、Bot Token 掩码输入、Chat ID）；底部关于条（版本/构建）。

> 登录页：见对比稿文件 `5GPN 管理面板.dc.html`（含 4 个视觉方向的登录页 + 仪表盘）。本控制台文件为登录后的应用主体。

---

## 交互与行为 Interactions & Behavior
- **侧栏导航**：点击切换 `page`，仅重渲染主区；顶栏标题/副标题随之切换。
- **出口 selector**：点击分组头 = 展开/折叠该组；点击成员卡 = 切换该组出口（选中态蓝色高亮）；默认出口的选择联动仪表盘/规则。
- **规则标签**：DNS / 分流 切换表格。
- **解析测试**：输入受控（`onInput`），随输入实时重算决策；"测试"按钮与示例 chips 触发。
- **头像下拉**：点头像开合；语言、主题为分段单选（高亮切换）。
- **实时数据**：`setInterval` 1300ms 推进 QPS/流量/连接折线与累计值（可由 `live` 开关暂停）。
- 悬停：导航项、按钮、卡片有轻微 `filter:brightness` 或底色变化。

## 状态管理 State
- `page`（当前页）、`live`（是否实时）、`defaultPage`（落地页）
- 实时序列：`up/down/qps/conn`（数组）、`totalUp/totalDown`
- 出口：`selSel`（各 selector 组 → 选中成员 id）、`selOpen`（各组展开态）、`exit`（默认出口 id，联动仪表盘/规则）
- 其它：`rulesTab`(dns/route)、`profileOpen`、`lang`(zh/en)、`theme`(light/dark/system)、`testDomain`/`testRan`

## 设计令牌 Design Tokens
**颜色**
- 主蓝 `#2563eb`；主按钮渐变 `linear-gradient(135deg,#3b82f6,#2563eb)`；青 `#38bdf8`(上行) / `#0284c7`·`#0891b2`；靛 `#6366f1`·`#4f46e5`；琥珀 `#f59e0b`·`#d97706`；绿 `#16a34a`·`#22c55e`；红 `#dc2626`
- 背景 `#eef4fc`；卡片 `#fff`；主边框 `#e2eaf4`；次边框/分隔 `#eef1f6`；输入/chip 底 `#eef4fc`，边 `#dbe6f4`；表头底 `#f7faff`
- 文字：强 `#0f1e35`；中 `#2b3a55` / `#5b6b85`；弱 `#93a2bd`

**字体**
- UI：`'Plus Jakarta Sans'`（400/500/600/700/800）
- 数字/代码/URL：`'JetBrains Mono'`
- `body` `line-height:1.45`

**圆角**：卡片 14px；小卡/输入/按钮 8–11px；chip/徽标 6–8px；开关/pill 999px
**阴影**：卡片 `0 1px 2px rgba(16,24,40,.04)`；下拉/弹层 `0 24px 46px -12px rgba(16,24,40,.24)`
**尺寸**：侧栏 236px；顶栏 66px；主区 padding 22px 24px；内容 `max-width:1180px`；网格/卡片 gap 14–16px
**动画**：状态点 `pulse` 呼吸；折线每 1300ms 更新

## 资源 Assets
全部图标为内联 SVG（stroke，`currentColor`，line-width 1.9/2.2/2.4）；无位图。品牌徽标为盾形内联 SVG + 渐变。复刻时用目标代码库既有图标库（如 lucide / heroicons）替换等价图标即可。

## 截图 Screenshots
`screenshots/` 目录，各页面高保真截图（1280 宽预览）：
- `01-dashboard.png` — 仪表盘
- `02-exits.png` — 出口（sing-box 风格 selector 选择器面板）
- `03-subscription.png` — 订阅
- `04-rules.png` — 规则（DNS / 分流）
- `05-dns-log.png` — 解析日志
- `06-dns-test.png` — 解析测试
- `07-xray-core.png` — XRAY-CORE
- `08-settings.png` — 设置

## 文件 Files
- `5GPN 控制台.dc.html` —— 控制台主体（八个页面，全部交互与模拟数据）。**这是主要参考文件。**
- `support.js` —— 预览运行时（仅为在浏览器中打开预览用；复刻时无需移植）。
- 预览方式：将两者放同一目录，浏览器打开 `5GPN 控制台.dc.html`。
