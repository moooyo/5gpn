# 交接文档 — Runtime Overlay

最后更新：2026-07-26。记录**当前状态**与**下一步**，不重复实现原理——
原理与踩坑史在 mihomo 仓库 `docs/runtime-overlay-implementation-plan.md`。

---

## 1. 一句话状态

5gpn `0.0.24-beta.4` 已发布，从**已发布产物**全新安装并通过 22/22 实流量验证。
mihomo、sidecar 同样已发布并在线上运行。**zashboard 的改动是唯一一块写完但从
未被部署验证过的**（见 §4.1）——它不在任何安装路径上。

---

## 2. 仓库与分支

| 仓库 | 本地 worktree | 分支 | HEAD | 推送目标 |
| --- | --- | --- | --- | --- |
| 5gpn | `D:\Code\worktrees\5gpn-runtime-overlay` | `feat/runtime-overlay` → 镜像 `beta` | `e7f114a` | `origin` = moooyo/5gpn |
| mihomo | `D:\Code\worktrees\mihomo-runtime-overlay` | `5gpn-ext` | `b888a9f7` | `origin` = moooyo/mihomo |
| zashboard | `D:\Code\worktrees\zashboard-runtime-overlay` | `5gpn-ext` | `d66a4ff` | **`fork`** = moooyo/zashboard |
| 5gpn-extensions | `D:\Code\worktrees\5gpn-extensions-typed` | `feat/typed-policy` | `a820a26` | `origin` = moooyo/5gpn-extensions |
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

- 5gpn `0.0.24-beta.4`（prerelease）
- mihomo `v1.19.28-overlay.1`
- sidecar `0.1.0-beta.1`
- zashboard：**无发布**，安装器仍拉上游 `v3.15.0` 的预构建 dist.zip

---

## 3. 已完成

overlay 数据面、失败即拒、就绪租约、双 socket 对端校验、CAS 提交与前滚、
控制台只读视图——细节见实现计划的状态表（30 项）。本轮新增的三项结构性工作：

- **sidecar 真正独立**：自己的仓库、CI、release；5gpn 按仓库+版本+摘要下载，
  与 mihomo/gum 同一机制，断言它自己的版本而非网关版本。
- **模板契约从模板推导**：`tests/test_seed_template_renderers.sh` 读取
  `etc/mihomo/config.yaml.tmpl` 的占位符，点名任何不展开它的渲染器。
- **安装器内两个渲染器合一**：由 `test/overlay/render-equivalence.sh`
  逐字节证明输出未变，而非靠人审。

以及一条**撤回**：我曾报告安装器 ERR trap 会把已处理的失败重复上报。加装探针
后不成立——trap 在 `depth=0` 触发，幂等守卫有效，那一次上报是正确的。原本的
修法是重构 7500 行安装器的错误模型；在机制未确认时那么做，是把吵闹的失败换成
沉默的失败，而沉默正是这个安装器已经付过一次代价的失败模式。

---

## 4. 下一步

按我的建议顺序。每条都写了**为什么**和**怎么算做完**。

### 4.1 把 zashboard 的改动真正跑起来 —— 优先级最高

**现状**：`5gpn-ext` 上有三个我们的提交（XSS + WebSocket token 冲突、
clear 按钮误提交表单、携带用于识别陈旧 processor 的摘要），加上 overlay
能力发现与状态面板（`src/api/overlay.ts`、`src/assembly/overlay/`、
`src/components/settings/overlay/OverlaySettings.vue`，已接入 `HomePage.vue`
与 `SettingsPage.vue`）。代码在、接线在。

**问题**：安装器第 171-172 行钉的是上游 `ZASH_VERSION="v3.15.0"` 的
`dist.zip`。test-env 上 `/opt/5gpn/zash/.zash_version` 就是 `v3.15.0`。
**也就是说这些改动从未被构建、部署或验证过**，22/22 里没有一项碰到它们。
实现计划状态表把第 16/17/18 项标为 done —— 那是"代码写完"的 done，不是这个
项目其它部分所用的"跑过了"的 done。这个差别我在表里没有区分，是个缺陷。

**怎么做**：给 fork 加一个构建 workflow 产出 `dist.zip` + 发 prerelease，
然后把安装器的 `ZASH_VERSION` / `ZASH_SHA256` / 下载 URL 指向我们的 fork。
下载 URL 现在硬编码在 install.sh:2752 的 `Zephyruso/zashboard`，需要参数化成
`ZASH_REPO`，与 sidecar 的做法一致。

**怎么算做完**：test-env 上 `.zash_version` 显示我们的版本，浏览器打开
`https://zash.5gpn.test/` 能看到 overlay 面板渲染出真实状态，且能力发现在
不支持的后端上正确隐藏面板。

### 4.2 extensions 的 `policy` 字段合 main —— 卡在你的部署节奏

`feat/typed-policy` 比 `main`（`a96babd`）领先 1 个提交，加了 index 的
`policy` 字段。**不要现在合。** marketplace index 是运行时线上契约，旧核心用
`DisallowUnknownFields` 解析它——多一个字段就是破坏性变更，会让还没升级的
核心直接解析失败。核心侧已经先学会了这个字段（这是正确的顺序：先教会读的人，
再让写的人开始写）。

**合并的前提**：确认在线的核心都已经是能识别 `policy` 的版本。这取决于你的
部署进度，我判断不了。

### 4.3 剩余 4 个模板渲染器合并

CI job（`.github/workflows/checks.yml`）、两个 mihomo 回归脚本
（`tests/mihomo-compact-suffix-regression.sh`、`tests/mihomo-sniff-cache-regression.sh`）、
以及等价性工具本身，各自还手写着占位符展开。

**没那么急了**：契约已从模板推导，漏掉会被 `test_seed_template_renderers.sh`
点名，不再依赖记忆。合并要让这些上下文去 source 一个随包脚本，改动面比看上去大。

**做的时候**：先 `test/overlay/render-equivalence.sh capture /tmp/before`，
改完再 capture + compare，要求 `identical`。这个工具的第一版我写错过——手写了
一份"参考实现"去对比，那不过是同一模板的第七个渲染器，被重新引入到它自己的
测试里。它现在只证明一个窄而诚实的性质：同一渲染器改动前后输出相同。

### 4.4 实现计划状态表区分两种 "done"

第 16/17/18 项（zashboard）标着 done，但含义与其它行不同（见 4.1）。加一列或
改措辞，让"写完"和"验证过"不再共用一个词。这是我引入的问题，值得单独修掉。

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
