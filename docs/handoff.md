# 交接文档 — Runtime Overlay

最后更新：2026-07-26。记录**当前状态**与**下一步**，不重复实现原理——
原理与踩坑史在 mihomo 仓库 `docs/runtime-overlay-implementation-plan.md`。

---

## 1. 一句话状态

5gpn `0.0.24-beta.5` 已发布，从**已发布产物**全新安装并通过 22/22 实流量验证。
mihomo、sidecar 同样已发布并在线上运行。**zashboard 的改动这一轮补齐了**——
fork 有了自己的构建与发布路径，安装器改为拉我们的 `v3.16.0-overlay.1`，
test-env 上 `.zash_version` 已经是我们的版本（见 §4.1）。

---

## 2. 仓库与分支

| 仓库 | 本地 worktree | 分支 | HEAD | 推送目标 |
| --- | --- | --- | --- | --- |
| 5gpn | `D:\Code\worktrees\5gpn-runtime-overlay` | `feat/runtime-overlay` → 镜像 `beta` | `8312259` | `origin` = moooyo/5gpn |
| mihomo | `D:\Code\worktrees\mihomo-runtime-overlay` | `5gpn-ext` | `b888a9f7` | `origin` = moooyo/mihomo |
| zashboard | `D:\Code\worktrees\zashboard-runtime-overlay` | `5gpn-ext` | `f7e23bf` | **`fork`** = moooyo/zashboard |
| 5gpn-extensions | `D:\Code\worktrees\5gpn-extensions-typed` | `feat/typed-policy` | `e98359a` | `origin` = moooyo/5gpn-extensions |
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

- 5gpn `0.0.24-beta.5`（prerelease）
- mihomo `v1.19.28-overlay.1`
- sidecar `0.1.0-beta.1`
- zashboard `v3.16.0-overlay.1`（prerelease，**我们的 fork** moooyo/zashboard；
  上游 3.16.0 + 我们的四个提交）

---

## 3. 已完成

overlay 数据面、失败即拒、就绪租约、双 socket 对端校验、CAS 提交与前滚、
控制台只读视图——细节见实现计划的状态表（30 项）。本轮新增：

- **marketplace 索引拆成两个 profile**：`v1` 冻结在稳定版核心能接受的形态，
  `v1beta` 携带 typed policy 投影，由**同一次构建**产出两份（详见 §3.1）。
- **zashboard 真正跑起来了**：fork 有了独立的 `5gpn-release.yml`，安装器
  参数化出 `ZASH_REPO`，overlay 面板新增策略投影摘要一行。

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

### 4.1 zashboard —— 已完成，但浏览器那一步要你来点

fork 现在有自己的 `.github/workflows/5gpn-release.yml`：tag 匹配
`v*-overlay.*` 时构建 `dist.zip` 并发 prerelease。**没有复用继承来的
`deploy.yml`** —— 那个由 release-please 对 `main` 把门，会刷上游的 gh-pages
CNAME（`board.zash.run.place`）并推 `ghcr.io/zephyruso` 镜像，在 fork 上跑
等于用我们的树重新发布上游的站点。

安装器侧 `ZASH_REPO` 与 `SIDECAR_REPO`/`MIHOMO_REPO` 并列，下载 URL 不再硬编码
`Zephyruso/zashboard`。

test-env 上已验证：`.zash_version` = `v3.16.0-overlay.1`，loopback 监听器
返回 200，交付的 index 引用的正是含我们改动的 bundle，`/capabilities` 报
`runtime-overlays` v1（发现会解析成 `supported`），readback 的
`activeProjectionDigest` 非空。

**还差最后一步，我做不了**：面板要用眼睛看一次。`10.0.0.0/8` 已加入来源 IP
白名单，从内网浏览器打开 `https://zash.5gpn.test/` 现在可达（端到端已验证：
经网关 IP 返回 200，交付的 index 引用的正是含改动的 bundle）。要确认的是：
面板渲染出真实状态、新增的"策略投影"一行显示摘要前 16 位
（当前应为 `efc69d78cc90148b`）、且在不支持 overlay 的后端上整个面板被隐藏。

### 4.2 extensions 的 `policy` 字段合 main —— 现在是安全的

`feat/typed-policy`（`e98359a`）比 `main`（`a96babd`）领先 2 个提交。
§3.1 那套拆分就是为了让这次合并不再破坏任何东西：合了之后 `v1` 的字节不变，
`v1beta` 才带 `policy`。

**但合并本身仍然是你的决定**，因为它会立刻触发 `publish-marketplace.yml`
把两份产物推到 Pages。合之前值得确认 CI 全绿（推 `feat/typed-policy` 时
`validate.yml` 已经跑过双核心验证，两步都 success）。

### 4.3 合并之后：把 beta 核心指向 v1beta

`recommendedMarketplaceURL`（`cmd/5gpn-dns/extension_marketplace.go:25`）
现在仍指向 `marketplace/v1/index.json`。**这是有意暂缓的**：`v1beta` 这个路径
要等 4.2 合并、Pages 重新部署之后才存在，提前切过去就是给 beta 网关一个 404。

beta 核心接受 `v1`（已验证），只是把 policy 当作"未验证"，所以暂缓零成本。
4.2 落地后改这一行、发下一个 beta 即可。

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
  目标格式化都尊重它——改的是全树 churn 最高的目录。`public-only` 目前**携带
  并校验，但未在传输层强制执行**。
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

- 5gpn：`feat/runtime-overlay` → 镜像 `beta`。**不推 main，不发正式版**，
  beta（`X.Y.Z-beta.N`）可以。
- mihomo / zashboard：不直接用 `Alpha` / `main`，用 `5gpn-ext`——它们是需要
  持续拉上游的 fork，把我们的工作提交到同步分支上会让每次上游合并都变痛。
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
