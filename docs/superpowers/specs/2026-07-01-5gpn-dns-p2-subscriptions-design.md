# 设计:5gpn-dns Phase 2 —— 规则集订阅系统(进程内)

- 状态:已批准方向(进程内拉取),待 spec 评审
- 日期:2026-07-01
- 范围:在 `5gpn-dns`(Phase 1 已交付的 Go DNS 引擎)内新增**订阅管理器**:四类规则(adblock / force-direct / blacklist / chnroute)各自可订阅远程 URL,定时+按需拉取、解析、与手动条目合并、落盘缓存、离线保留旧表、热重载。暴露一个内部 `Controller`,供 Phase 3 的 API 直接调用。sing-box 数据面、DoT/DoH/plain 入口不变。
- 关联:[2026-06-30-5gpn-dns-go-design.md](2026-06-30-5gpn-dns-go-design.md)(Phase 1,§0 已把 P2 列为订阅、并预留 RuleSet/Controller 接缝);Phase 3 见 [2026-07-01-5gpn-dns-p3-api-webui-design.md](2026-07-01-5gpn-dns-p3-api-webui-design.md)

---

## 1. 背景

Phase 1 的四类规则从 `/etc/5gpn/rules/` 的**本地文件**加载,手动维护(tgbot / update-lists.sh)。P2 把它们升级为**订阅**:运维配置远程 URL,`5gpn-dns` 自动定时拉取更新——像 AdGuardHome / mosdns 的规则订阅。拉取放**进程内**(用户决策),因为它天然接上 P1 已有的原子热重载,且 P3 的 API 可直接调进程内的订阅管理器触发更新/改订阅,无需 shell out。

## 2. 既定决策(2026-07-01)

| 决策点 | 选择 | 理由 |
|---|---|---|
| 拉取位置 | **进程内**订阅管理器 goroutine | 接已有热重载 + P3 API 直调;无外部 timer/脚本 |
| 订阅配置 | `/etc/5gpn/subscriptions.json`(一个 JSON 文件) | P3 API 读写它;结构化、易校验 |
| 合并模型 | 每类最终集 = 手动文件 + 该类所有启用订阅缓存(`<cat>.d/*.txt`) | `LoadDomainSet(paths...)` 已支持多文件;订阅只是多塞几份源文件 |
| 缓存落盘 | `/etc/5gpn/rules/<category>.d/<name>.txt` | 重启不必重拉;断网保留旧表 |
| 更新触发 | 每条订阅的 `interval` 定时 + 按需(`Controller.Update`) | 定时自动 + P3/信号手动 |
| 失败策略 | 拉取/解析失败/条目过少 → 保留旧缓存,不清空 | 空规则会误伤(空 chnroute = 全判国外) |
| 热重载 | 拉完 → 重建该类 RuleSet → 原子 swap(复用 P1 的 `swapRuleSets`) | 无需重启,in-flight 查询安全 |
| 依赖 | 仅 stdlib `net/http`(+ 已有 miekg/dns) | 拉取用 net/http;不引入第三方 |

## 3. 订阅配置(`/etc/5gpn/subscriptions.json`)

```jsonc
{
  "subscriptions": [
    { "id": "gfwlist",     "category": "blacklist",    "name": "gfwlist",
      "url": "https://.../gfwlist.txt", "format": "gfwlist", "enabled": true, "interval": "24h" },
    { "id": "china-ip",    "category": "chnroute",     "name": "china_ip_list",
      "url": "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt",
      "format": "cidr", "enabled": true, "interval": "24h" },
    { "id": "cn-domains",  "category": "direct",       "name": "accelerated",
      "url": "https://.../accelerated-domains.china.conf", "format": "dnsmasq", "enabled": true, "interval": "24h" },
    { "id": "adguard",     "category": "adblock",      "name": "adguard-base",
      "url": "https://.../filter.txt", "format": "adblock", "enabled": true, "interval": "24h" }
  ]
}
```

- `category` ∈ {adblock, direct, blacklist, chnroute}。`id` 唯一(P3 用它增删)。`interval` 是 Go duration(`24h`/`6h`)。
- 缺失文件 → 视为空订阅列表(启动不报错);损坏 JSON → 报错并保留上次内存态(不覆盖)。

## 4. 格式解析器

**域名类**(adblock / direct / blacklist)→ 归一化为"一行一域名"缓存:
- `plain` —— 一行一域名(`#` 整行注释)。
- `gfwlist` —— base64 整体解码后,取每行去掉 `||`/`|http...`/`@@` 前缀后的域名(gfwlist 语法子集;`@@` 白名单行忽略——P2 只做"提取要代理的域名")。
- `dnsmasq` —— `server=/domain/ip` / `address=/domain/ip` 取 domain(felixonmars accelerated-domains 格式)。
- `adblock`(ABP)—— `||domain^` 取 domain;忽略含通配/正则/元素隐藏(`##`)/例外(`@@`)的行(只吃纯域名阻断规则)。
- `hosts` —— `0.0.0.0 domain` / `127.0.0.1 domain` 取 domain。

**CIDR 类**(chnroute)→ `cidr`:一行一 CIDR(`#` 注释),即 17mon/china_ip_list 原格式。

- 每个解析器:输入原始字节 → 输出去重、归一化(小写、去尾点)的行集合 → 原子写缓存文件(tmp + rename)。
- **守卫**:解析后条目数 < 每类下限(域名类如 1、chnroute 如 100)→ 视为失败,保留旧缓存。

## 5. `5gpn-dns` 程序设计(新增/改动)

**新增 `cmd/5gpn-dns/subscription.go`(+ `_test`)**
```go
type Subscription struct{ ID, Category, Name, URL, Format string; Enabled bool; Interval time.Duration }
type SubManager struct{ /* subs []Subscription, rulesDir string, http *http.Client, mu, reload func() error */ }
func LoadSubscriptions(path string) ([]Subscription, error)   // parse subscriptions.json
func NewSubManager(path, rulesDir string, reload func() error) (*SubManager, error)
func (m *SubManager) Run(ctx context.Context)                 // per-sub interval tickers; fetch->parse->cache->reload
func (m *SubManager) UpdateAll(ctx context.Context) []UpdateResult   // on-demand (P3 /update)
func (m *SubManager) UpdateOne(ctx context.Context, id string) UpdateResult
func (m *SubManager) List() []Subscription
func (m *SubManager) Add(s Subscription) error                // validate + persist subscriptions.json + fetch
func (m *SubManager) Remove(id string) error                  // persist + delete its cache file + reload
```
- `fetchAndCache(sub)`: `http.Get`(超时、size cap、`If-Modified-Since`/ETag 可选)→ parser[format] → 守卫 → 原子写 `<rulesDir>/<category>.d/<name>.txt` → 调 `reload()`。失败:log + 保留旧缓存 + 返回错误结果(不 panic)。
- `Run` 为每条启用订阅起一个按 `interval` 的 ticker;启动时先跑一轮(若缓存缺失或过期)。
- `reload()` = P1 的规则重建 + 原子 swap(复用现有 `loadRuleSets` + `swapRuleSets`)。

**改动:规则加载(main.go / rules 加载)**
- 每类从 **手动文件 + `<category>.d/*.txt`(glob)** 加载:`LoadDomainSet(append([]string{manualPath}, glob(catDir)...)...)`。
- **chnroute 需支持多文件**:扩展 `LoadChnroute` → `LoadChnrouteFiles(paths ...string)`(合并所有 CIDR;空集仍报错)。P1 单文件调用改为多文件(手动 china_ip_list.txt + `chnroute.d/*.txt`)。
- 目录不存在 → 视为无订阅缓存(只用手动文件)。

**改动:`main.go` 装配**
- 构建 `SubManager`(若 `subscriptions.json` 存在)→ `go m.Run(ctx)`。
- `SIGHUP` 仍触发 `reload()`(重读所有规则文件,含订阅缓存)——手动改文件或订阅更新后都生效。
- `Controller` 聚合:`{ SubManager, reload, Stats() }`,P3 API 持有它。

**Controller 接口(P3 用;P2 先定义 + 内部实现)**
```go
type Controller struct{ subs *SubManager; reload func() error; stats *Stats }
func (c *Controller) Subscriptions() []Subscription
func (c *Controller) AddSubscription(Subscription) error
func (c *Controller) RemoveSubscription(id string) error
func (c *Controller) Update(ctx, id string) []UpdateResult   // id="" => all
func (c *Controller) AddRule(cat, domainOrCidr string) error // manual file append + reload
func (c *Controller) RemoveRule(cat, entry string) error
func (c *Controller) Reload() error
func (c *Controller) Lookup(ctx, name string) LookupResult   // verdict(direct/proxy/block)+resolved IPs
func (c *Controller) Stats() Stats
```
> P2 实现 subscription 相关 + Reload;`AddRule/RemoveRule/Lookup/Stats` 在 P2 打桩或实现基础版,P3 接 API。为减少 P3 返工,P2 一并实现 `AddRule/RemoveRule`(手动文件增删,tgbot 后续也走它)与 `Stats`(引擎侧计数器:总查询、各类命中、缓存条数)。`Lookup` 放 P3(它更依赖引擎内部)。

## 6. 安装 / 运维

- `install.sh`:装机写一个默认 `subscriptions.json`(可空 `[]` 或带推荐的 chnroute/gfwlist 订阅,enabled 由运维定;默认给 chnroute 一条指向 17mon,替代 P1 里 update-lists.sh 拉 chnroute 的活)。创建 `<cat>.d/` 目录。
- `scripts/update-lists.sh`:P2 后 chnroute 由订阅拉;该脚本**保留为手动强制刷新入口**,改为"给运行中的 5gpn-dns 发一个 update 信号/调 P3 API",或直接删(P3 API 的 `/update` 取代)。**决策:P2 阶段保留 update-lists.sh 但改为 `systemctl reload 5gpn-dns`(触发 SIGHUP 重读缓存);真正的拉取由进程内定时器做。** P3 落地后可用 API 触发。
- systemd 单元:`ReadWritePaths=/etc/5gpn/rules`(订阅管理器要写缓存文件——P1 的 `ReadOnlyPaths=/etc/5gpn` 需放开 rules 子目录为可写)。**这是对 P1 沙箱的必要调整**,test-env 验证。
- 网络:出站拉取走网关默认路由(直出);URL 建议 https。

## 7. 测试

- **Go 单测**:每个格式解析器(plain/gfwlist-base64/dnsmasq/adblock/hosts/cidr)对样例输入→期望域名/CIDR 集;守卫(条目过少→保留旧);原子写;LoadSubscriptions(好/坏 JSON);`LoadChnrouteFiles` 合并;Add/Remove 订阅持久化 + 缓存文件增删;fetchAndCache 用 `httptest.Server`(200/404/超时/损坏体→保留旧缓存)。
- **grep 策略**:install 写 subscriptions.json + 建 `.d` 目录;systemd `ReadWritePaths=/etc/5gpn/rules`;update-lists 改为 reload。
- **真机(test-env)**:起 5gpn-dns 带一条指向本地 httptest 的订阅 → 缓存文件生成 → 该类规则生效;改订阅体 → 定时/按需拉 → 热重载生效;断网 → 保留旧缓存;沙箱 ReadWritePaths 生效(能写缓存,不误伤)。

## 8. 风险 / 取舍

- 进程内 HTTP 拉取给 resolver 增了出站+调度面;隔离在订阅管理器,失败不影响解析(保留旧表)。
- gfwlist/adblock 语法只吃"纯域名阻断/代理"子集——通配/正则/例外行忽略(文档写明);够用,复杂规则非本网关目标。
- 沙箱放开 `/etc/5gpn/rules` 可写是必要代价(订阅要落盘)。
- update-lists.sh 语义变化(不再自己拉 chnroute)——文档更新。

## 9. 回滚 / 关系

- 回滚 = `git revert`;订阅管理器不启(无 subscriptions.json)则退回 P1 纯本地文件行为。
- **P3 依赖本 spec 的 `Controller`**;P2 先交付 Controller + 订阅 + Reload + AddRule/RemoveRule + Stats,P3 加 HTTP API/UI + Lookup + tgbot 改造。
