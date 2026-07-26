# 交接文档 — Runtime Overlay

最后更新：2026-07-26。记录**当前状态**与**下一步**，不重复实现原理——
原理与踩坑史在 mihomo 仓库 `docs/runtime-overlay-implementation-plan.md`。

---

## 1. 一句话状态

**runtime overlay 已进入正式发布通道。** 5gpn `0.0.26`（正式版，非 prerelease）
已从 `main` 发布，在 test-env 上走**稳定通道**（`quick-install.sh` 不带 `--beta`）
全新安装，22/22 实流量验证通过。mihomo `v1.19.28-overlay.2` 与 zashboard
`v3.16.0-overlay.1` 已提升为正式发布；extensions 已合 main，marketplace 的
`v1` / `v1beta` 两份产物均已上线。console 现在同时显示三个已安装组件的版本。

---

## 2. 仓库与分支

| 仓库 | 本地 worktree | 分支 | HEAD | 推送目标 |
| --- | --- | --- | --- | --- |
| 5gpn | `D:\Code\worktrees\5gpn-runtime-overlay` | **`main`**（`feat/runtime-overlay` 与 `beta` 已对齐至同一提交） | `91ea86e` | `origin` = moooyo/5gpn |
| mihomo | `D:\Code\worktrees\mihomo-runtime-overlay` | `5gpn-ext` | `793f6b9b` | `origin` = moooyo/mihomo |
| zashboard | `D:\Code\worktrees\zashboard-runtime-overlay` | `5gpn-ext` | `f7e23bf` | **`fork`** = moooyo/zashboard |
| 5gpn-extensions | `D:\Code\worktrees\5gpn-extensions-typed` | **`main`**（`feat/typed-policy` 已合入） | `ed51945` | `origin` = moooyo/5gpn-extensions |
| sidecar | `D:\Code\worktrees\sidecar` | `main` | `5726517` | `origin` = moooyo/mihomo-extension-sidecar |

五个仓库均 clean、无未推送提交。

### 两个会咬人的地方

**zashboard 的 `origin` 是上游 Zephyruso/zashboard，不是我们的 fork。**
我们的分支 `5gpn-ext` 跟踪的是 `fork/5gpn-ext`。裸 `git push` 是对的，但
`git push origin 5gpn-ext` 会推到**上游**。推之前确认远程名。

**mihomo 没有配 upstream remote**，只有 `origin` = 我们的 fork。要同步
MetaCubeX 上游需要先 `git remote add upstream`。当初把分支从 `Alpha` 挪到
`5gpn-ext` 就是为了让这件事以后不痛。

### 已发布

- 5gpn **`0.0.26`（正式版）** —— `releases/latest` 解析到它，所以
  `quick-install.sh` 不带参数就装这个
- mihomo **`v1.19.28-overlay.2`（正式版）** —— fork 上 Actions 从未启用，二进制
  本地交叉编译后手动上传，这是 overlay.1 就定下的路径
- sidecar `0.1.0-beta.1`（**仍是 prerelease，有意为之**：tag 字面就叫 beta，
  标成 latest release 会误导；要正式化得重新切 `0.1.0` 并重建）
- zashboard **`v3.16.0-overlay.1`（正式版）**，**我们的 fork** moooyo/zashboard；
  上游 3.16.0 + 我们的四个提交

---

## 3. 已完成

overlay 数据面、失败即拒、就绪租约、双 socket 对端校验、CAS 提交与前滚、
控制台只读视图——细节见实现计划的状态表（30 项）。本轮新增：

- **marketplace 索引拆成两个 profile**：`v1` 冻结在稳定版核心能接受的形态，
  `v1beta` 携带 typed policy 投影，由**同一次构建**产出两份（详见 §3.1）。
- **zashboard 真正跑起来了**：fork 有了独立的 `5gpn-release.yml`，安装器
  参数化出 `ZASH_REPO`，overlay 面板新增策略投影摘要一行。
- **就绪 sweeper 在恢复路径上也启动了**（mihomo `v1.19.28-overlay.2`）：
  它原本只由 `Commit()` 启动，而网关重启走的是 recovery、之后往往再也不 commit
  ——test-env 上 12 天的日志里只有 2 次 commit、每次启动都有 recovery。所以那个
  "把失效租约变成失败即拒、且不依赖流量"的机制在实际运行的进程里根本没跑。

  **它看起来一切正常，这才是要点**：`Readback()` 在读的时候就地把状态改写成
  not-ready，所以轮询 API 的协调者看到的是对的，捕获也确实失败即拒。缺的是
  状态转移本身——`[Overlay] processor state for generation %s changed to %s`
  在 12 天日志里**一次都没打过**，尽管验证脚本反复杀掉 processor。运维看到的
  是一串 connect-refused，没有任何一行说明原因。

  既有测试抓不到它：唯一覆盖这条路径的测试**手动调用** `RefreshReadiness()`，
  证明的是函数能工作，不是有人调用它。新测试断言的是持有的状态而非 readback，
  因为读 readback 无论 sweeper 有没有跑都会通过。部署后已验证那条日志会打出来。

以及上一轮的三项结构性工作：sidecar 真正独立、模板契约从模板推导、
安装器内两个渲染器合一。

### 3.1 为什么是两份产物而不是两个分支

`policy` 字段一度合不进 main：索引是与每个已部署网关的线上契约，核心用
`DisallowUnknownFields` 解析它，所以**加字段不是增量变更**——不认识该字段的
核心会拒绝整个文档，连带丢掉整个扩展目录。全新安装最惨：没有缓存 snapshot，
添加推荐市场源直接失败，等于完全没有目录。

**版本号在这里是反直觉的**：`0.0.25` 数字更大，但它在 `main` 上，没有 overlay
线的提交，因此**恰恰是不认识 `policy` 的那个**。只有 `0.0.24-beta.2` 及之后
的 beta 认识它。

一度考虑"从 beta 分支发布"。那会**更糟**：Pages 用 `upload-pages-artifact` +
`deploy-pages`，整站是一次性替换的，第二个 deploy 会把第一个盖掉——稳定版
网关拿到的不是"多了一个不认识的字段"，而是整份 beta 文档，或者 404。
`concurrency` 只是排队，不是隔离。

所以拆的是产物不是分支。已验证的四个组合：

| 核心 \ 产物 | v1 | v1beta |
| --- | --- | --- |
| stable（main / `0.0.25`） | 通过 | 拒绝：`json: unknown field "policy"` |
| beta（`feat/runtime-overlay`） | 通过 | 通过 |

并且 `v1` 的输出与**投影出现之前**的生成器逐字节相同——合 main 对 v1 读者
真的什么都没变。

**顺带修掉一个会说谎的门**：`validate.yml` 原本只 checkout 5gpn 的 `beta` 来
验证索引，也就是那个**已经认识该字段**的分支。合 main 时 CI 会全绿而
`0.0.25` 照炸。现在每个 profile 交给真正消费它的核心：`v1` 给 `main`，
`v1beta` 给 `beta`。

---

## 4. 下一步

按我的建议顺序。每条都写了**为什么**和**怎么算做完**。

### 4.1 zashboard —— 已完成并随正式版部署

fork 有自己的 `.github/workflows/5gpn-release.yml`：tag 匹配 `v*-overlay.*` 时
构建 `dist.zip` 并发布。**没有复用继承来的 `deploy.yml`** —— 那个由
release-please 对 `main` 把门，会刷上游的 gh-pages CNAME（`board.zash.run.place`）
并推 `ghcr.io/zephyruso` 镜像，在 fork 上跑等于用我们的树重新发布上游的站点。

安装器侧 `ZASH_REPO` 与 `SIDECAR_REPO`/`MIHOMO_REPO` 并列，下载 URL 不再硬编码
`Zephyruso/zashboard`。

test-env 上（`0.0.26` 稳定通道安装后）已验证：`.zash_version` =
`v3.16.0-overlay.1`，交付的 index 引用的正是含我们改动的 bundle，
`/capabilities` 报 `runtime-overlays` v1，readback 的 `activeProjectionDigest`
非空，`/api/status` 的 `zash_version` 与磁盘一致。

**唯一还没被人眼看过的**：面板本身的渲染。`10.0.0.0/8` 已在白名单里，从内网
浏览器打开 `https://zash.5gpn.test/` 可达。要确认：面板渲染出真实状态、
"策略投影"一行显示摘要前 16 位、且在不支持 overlay 的后端上整个面板被隐藏。

### 4.2 extensions 合 main —— 已完成

`feat/typed-policy` 已合入 `main`（合并提交 `ed51945`），`publish-marketplace.yml`
随即把两份产物部署到 Pages。线上已验证：同一 revision 产出的 `v1` 不含 `policy`、
`v1beta` 全部含，两个路径的 `schema.json` 均可访问。

### 4.3 核心指向 v1beta —— 已完成

`recommendedMarketplaceURL`（`cmd/5gpn-dns/extension_marketplace.go:25`）已改为
`marketplace/v1beta/index.json`，随 `0.0.26` 发布。test-env 上已验证：部署的
二进制含该 URL，且从盒子上能真正拉到该索引（8 条 entry 全带 policy，
`ad-platform-blocker` 的摘要 `a65ccac63b95fd5b` 与本地 fixture 断言一致——
JS 与 Go 两个编译器在真实链路上对齐）。

注意 `validateAddCandidate` 按 `metadata.id` 去重，两份索引的 id 都是
`io.5gpn.official`，所以**同一台网关不能同时加两个源**——切换要先 Delete 再 Add。

### 4.4 剩余 4 个模板渲染器合并

CI job（`.github/workflows/checks.yml`）、两个 mihomo 回归脚本
（`tests/mihomo-compact-suffix-regression.sh`、`tests/mihomo-sniff-cache-regression.sh`）、
以及等价性工具本身，各自还手写着占位符展开。

**没那么急了**：契约已从模板推导，漏掉会被 `test_seed_template_renderers.sh`
点名，不再依赖记忆。合并要让这些上下文去 source 一个随包脚本，改动面比看上去大。

**做的时候**：先 `test/overlay/render-equivalence.sh capture /tmp/before`，
改完再 capture + compare，要求 `identical`。这个工具的第一版我写错过——手写了
一份"参考实现"去对比，那不过是同一模板的第七个渲染器，被重新引入到它自己的
测试里。它现在只证明一个窄而诚实的性质：同一渲染器改动前后输出相同。

### 4.5 实现计划状态表区分两种 "done"

第 16/17/18 项（zashboard）标着 done，但当时的含义与其它行不同：那是"代码
写完"的 done。本轮补上了构建、发布、部署，所以现在它们**够得上**"跑过了"的
done——除了 §4.1 末尾那个浏览器确认。但状态表本身仍然只有一个 done 列，
下一次同样的混淆还会发生。加一列或改措辞。

---

## 5. 有意不做 / 已知失败

- **transport-level pinned-IP dialing**。`Metadata.RemoteAddress()` 在 `Host`
  非空时返回它，于是 DIRECT / HTTP / SOCKS5-out / VMess 全都转发域名、忽略已
  填充的 `DstIP`。真正的 pin 需要新增一个 metadata 字段并让每个 adapter 的
  目标格式化都尊重它——改的是全树 churn 最高的目录。
  **`public-only` 比之前记的更糟，这一轮实测确认（每条断言都亲手核对，非转述）**：
  它不只是"未在传输层强制"，而是**协调者从未把该字段设为 true**，所以
  `snapshot.go:186` 的 `if c.PublicOnly && …` 左操作数恒假、整条是死代码；就算
  设了，`forbiddenEgressScope` 对空 `DstIP`（域名形态）也返回放行。加上 IP-CIDR
  私网拒绝全带 `no-resolve`（只拦已是 IP 的目标），**一个解析到私网的域名会一路
  通过、被 DIRECT 在拨号时解析并连上**。可达路径：扩展声明一个 network origin →
  自动生成 DOMAIN egress selector（`intercept_mihomo.go:180`）→ 攻击者审查后把该
  域名 DNS 翻成 `127.x`/`10.x`/`169.254.169.254` → 响应 body 回传给扩展 VM
  （`sidecar/module_network.go:259`）。**读型 SSRF**，触发者是恶意/被劫持的扩展，
  非外部未认证方；网关自己的 `:9090` 仍需 bearer secret，但云元数据不需要。
  详见记忆 `public-only-egress-gap`。
  **本轮已做**：修正两处会骗人的注释（`types.go` 的 PublicOnly 说"forces
  pinned-IP dialing"、tmpl 的"an extension can never capture private ranges"）——
  纯注释、无规则变化。**未做**：真正的缓解。便宜候选＝给 egress 路径的私网拒绝
  去掉 `no-resolve`（代价：每次求值多一次解析 + 更窄的 TOCTOU 残留 + 需评估
  resolver 归属/性能），未验证；真正修法＝传输层 pin，deferred。
- **processor 侧 generation 轮询与事务绑定**（计划第 15 项）。现在由协调者
  attest 就绪；processor 的 socket 按设计是只读的。
- **DNS quarantine cacheable negatives**（review 6.15）。
- **geo 更新作为 revision-bearing**。
- **Option C** 全部。
- **`tests/test_renew_hook.sh` 失败**，在 `origin/main` 上同样失败。属于既有
  问题，本轮未触碰，也不要把它当成本轮引入的回归。

---

## 6. 必须遵守的两条

### 分支与发布

**这条规则在 2026-07-26 变了。** 此前是"5gpn 只在 `feat/runtime-overlay` +
`beta`，不推 main、不发正式版"。overlay 这条线已按明确决定进入正式发布通道，
所以现在是：

- 5gpn：**`main` 是主干，发正式版（`X.Y.Z`，无 `-beta.N`）**。`beta` 与
  `feat/runtime-overlay` 保留并已对齐到同一提交，beta 预发布仍然可用。
  release workflow 要求正式 tag 从 `main` 可达、beta tag 从 `beta` 可达。
- 5gpn-extensions：`main`。合入会**立刻**触发 `publish-marketplace.yml` 把
  `v1` / `v1beta` 两份产物部署到 Pages，没有反悔窗口。
- mihomo / zashboard：**仍然不用 `Alpha` / `main`，继续用 `5gpn-ext`**——它们
  是需要持续拉上游的 fork，把我们的工作提交到同步分支上会让每次上游合并都变痛。
  这一条没有变，别因为 5gpn 改了就顺手把它们也合上去。
- sidecar：自己的仓库，`main`。
- **我曾经强推过 mihomo 的 `Alpha`**。已用 `--force-with-lease` 回退到
  `b9faf971`，工作移到 `5gpn-ext`，被弃提交由 tag 保活。记在这里，免得它在你
  下次拉上游时变成一个谜。

### 动过 release 或安装路径就必须真装一次

改了 release workflow、`install.sh`、`quick-install.sh`，就在 test-env 上从
**已发布产物**装一遍并重跑 `verify-live.sh`。

**为什么**：本轮每一个真实缺陷都活在没人执行过的路径里。22 项实流量检查全程
通过、一个都没抓到，因为它们覆盖数据面**做什么**，不覆盖它**怎么被装出来**。
其中数个是审阅看不出来的：`exec 7>&- 2>/dev/null` 从取锁那一刻起永久丢弃了
安装器自己的 stderr，症状是"退出 1、什么都不打印"；`StateDirectory=` 在每次
服务启动时递归 chown 一个共享项目根，把之后每一次安装都弄坏。

---

## 7. 复现环境

```bash
# 装已发布的 beta（quick-install 用分支上的版本，main 上的可能还不认 --beta）
scp D:\Code\worktrees\5gpn-runtime-overlay\quick-install.sh test-env:/tmp/
ssh test-env 'cd /tmp && sudo bash quick-install.sh --beta'

# 22 项实流量验证
scp -r D:\Code\worktrees\5gpn-runtime-overlay\test\overlay test-env:/tmp/overlay
ssh test-env 'cd /tmp && sudo bash overlay/verify-live.sh'   # 期望 22 passed, 0 failed
```

- ssh 别名 `test-env`（10.0.1.20）。它是**一次性**的，配置和程序可随意清掉、
  卸载，不需要备份。
- 二进制装在 **`/opt/5gpn/bin/`**，不是 `/usr/local/bin/`。
- `MIHOMO_SHA256` 钉的是 **`.gz` 归档**，`SIDECAR_SHA256` 钉的是**裸二进制**。
  所以只有 sidecar 的落盘摘要会与钉住值相符；mihomo 的不符是预期的，不是缺陷。
- Git Bash 的 ssh 读不到 Windows 的 ssh config（Include 用了反斜杠路径），
  连 test-env 要走 PowerShell 的 ssh。
- **zashboard 的监听器在 loopback 上**（`DNS_ZASH_LISTEN=127.0.0.2:443`，第二个
  HTTPS 监听器），但它**确实可以通过网关 IP 访问** —— mihomo 按来源 IP 白名单
  转发过去。`curl --resolve zash.5gpn.test:443:10.0.1.20` 在来源被放行时返回 200。
- **白名单未放行时的失败是连接失败（curl `000`），不是 HTTP 403。**
  这一点值得单独记：它和"地址写错了"长得一模一样。我就是这样误判过一次，
  以为面板不在公网 IP 上，其实只是全新安装后
  `/etc/5gpn/mihomo/whitelist.txt` 是空的（注释写明 "Intentionally empty"）。
  打不开先查白名单：`5gpn add-allow <CIDR>`，它会写盘并让 mihomo 的
  rule-provider 实时重载（`5gpn add-allow 10.0.0.0/8` 已在 test-env 上放行内网）。
- `verify-live.sh` 里**没有任何 zashboard 相关检查**。22/22 全绿不代表面板
  可用——这正是 §4.1 最后那一步必须用眼睛确认的原因。
