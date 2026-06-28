# 设计:移除 Web 控制面 + install.sh 全面 Gum 化 + TG 配置 TUI

- 状态:设计待评审
- 日期:2026-06-28
- 范围:删除 Web 控制面(webui + HTTP API),只保留 Telegram bot 作为控制面;在安装脚本里引入 Gum 作为统一交互/输出框架;把 TG bot 的对接改为 Gum 驱动的配置 TUI。
- 关联:[DESIGN.md](../../DESIGN.md) §9(规则/列表管理)、上一迁移 spec [2026-06-28-xray-replace-sniproxy-design.md](2026-06-28-xray-replace-sniproxy-design.md)(预编译二进制 + sha256 校验模式)

---

## 1. 背景与动机

现状有两条并行控制面:
- **Web**:静态 [webui/index.html](../../../webui/index.html) ↔ [api-server.py](../../../api-server.py)(stdlib HTTP API,公网 8443,Bearer token)。
- **Telegram bot**:[tgbot.py](../../../tgbot.py)(出站长轮询,经 `install.sh` CLI + systemctl 干活)。

决定**只保留 TG bot**:Web 控制面是额外的公网攻击面(8443)+ 维护负担,而 TG bot 出站无入站端口、能力已覆盖日常运维。同时把安装脚本的交互体验统一到 **Gum**(charmbracelet/gum),并把 TG bot 的对接(token/管理员 ID)从 env 变量改为 Gum 配置 TUI。

## 2. 既定决策(评审 2026-06-28)

| 决策点 | 选择 |
|---|---|
| Web 控制面 | **删 webui + api-server**(整个 HTTP 控制面),只留 TG bot |
| TUI 范围 | TUI 只管 **TG bot 配置**(token + 管理员 ID + enable/restart + /id 引导) |
| TUI 框架 | **Gum**;`install.sh` 开场先安装 Gum |
| Gum 化范围 | **整个 install.sh**:输出 + 交互 + 长操作全经 Gum(经一层兜底 helper) |
| Gum 安装方式 | **预编译二进制 + sha256 校验**(不加 charm apt 源,不引 Go),与 xray 一致 |
| 交互门控 | Gum 交互严格 `[[ -t 0 ]]`;非 TTY 保留 env-var 非交互路径(`curl\|bash`/CI 不受影响) |
| Gum 兜底 | gum 不可用时 helper **回退到现有 ANSI echo**,安装器不变砖 |
| iOS 响应器 | **保留**(`5gpn-iosprofile`/ios-http.py/WWW_DIR;非控制面,TG「iOS 二维码」依赖它) |

## 3. 移除 Web 控制面

### 删文件
- `webui/`(含 index.html)
- `api-server.py`

### install.sh
- 删 `setup_api()` 及其内联 `5gpn-api.service`。
- `install_files`:删 api-server.py 拷贝、webui 目录拷贝(及 `mkdir webui`)。
- 删 `--setup-api` CLI 分支与 usage 行、`full_install` 末尾「Optional: --setup-api」提示。
- `show_status` 的可选单元循环:`5gpn-iosprofile.socket 5gpn-api 5gpn-tgbot` → 去掉 `5gpn-api`。
- **升级清理**(幂等):`systemctl disable --now 5gpn-api 2>/dev/null || true; rm -f /etc/systemd/system/5gpn-api.service`(放在合适的安装路径上,类比 sniproxy 迁移清理)。
- 顶部 `CONF_DIR` 注释里的 `.api_token` 字样更新。

### 防火墙 [scripts/setup-firewall.sh](../../../scripts/setup-firewall.sh)
- 删 `API_PORT` 相关:`tcp_ports` 的 `${API_PORT}` 拼接、入参 `API_PORT`。
- `install.sh` 的 `run_setup_firewall`:删读 `.api_port` / 传 `API_PORT` 的逻辑。
- **保留** `IOS_PORT`(8111,iOS 描述文件,仅 172.22)。

### 状态文件
- 不再使用 `.api_token` / `.api_port`(install 不再写;遗留文件无害,可不主动删)。

## 4. 引导安装 Gum

新增 `install_gum()`:
- 若 `command -v gum` 已有 → 跳过。
- 否则下载 `https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${arch}.tar.gz`(arch:`x86_64`/`arm64`/…),`GUM_VERSION` 默认锁定(env 可覆盖,初值 `0.17.0`)。
- 校验:`GUM_SHA256` 覆盖,否则下载同 release 的 `checksums.txt` 取该 tar.gz 的 sha256 比对;失败 fail-closed(下载/校验失败时 warn 并回退,见兜底)。
- 解出 `gum` 二进制装到 `/usr/local/bin/gum`;设 `_HAVE_GUM=1`。
- **调用时机**:`check_root` 之后、其余逻辑之前(`full_install` 与各 `--setup-*` 子命令入口都先 `ensure_gum`)。
- **依赖**:需要 `curl` 与 `tar`(基本必有);`install_deps` 之前运行,故 `install_gum` 内自带最小保证(curl 缺失则回退 echo 模式,不阻断)。

## 5. install.sh 全面 Gum 化(经兜底 helper 层)

不裸调 `gum`,收敛到 helper:

### 输出 helper
- `info/warn/ok/err` 重写:`_HAVE_GUM=1` 时用 `gum log --level info/warn/error`(或 `gum style`),否则**回退现有 ANSI echo**(保留 `[[ -t 1 ]]` 逻辑)。
- section 标题用 `gum style`(带框)在 gum 可用时美化,否则普通 echo。

### 交互 helper(仅 `[[ -t 0 ]]` 且 `_HAVE_GUM=1`)
- 文本输入(域名)→ `gum input`;密钥(bot token)→ `gum input --password`。
- 是/否(A 记录确认、enable 服务)→ `gum confirm`。
- 多选一 → `gum choose`。
- **非 TTY 或无 gum**:走现有 `read -r -p`(若 TTY 无 gum)或 env-var/报错(若非 TTY)——即当前行为不回退。

### 长操作
- **不需看输出**的等待(下载 xray/gum、`certbot` 申请、`make`/解压)→ `gum spin --title "…" -- <cmd>`(gum 可用且 TTY 时;否则直接跑)。
- **需要看输出**的(`update-lists.sh`、smartdns 渲染)→ **不包 spin**,保留实时输出。

### 非交互/CI 不变量
- `gum input/choose/confirm` 一律 `[[ -t 0 ]]` 门控;`curl | sudo bash`(stdin 非 TTY)与 CI 走 env-var 路径,行为与今日一致。

## 6. TG bot 配置 TUI(Gum)

`setup_tgbot()` 改为 Gum 引导(TTY + gum 时):
1. `gum input --password` 收 bot token(空=跳过,与现状一致)。
2. `gum input` 收管理员数字 ID(逗号分隔,可空)。
3. `gum confirm` 是否立即 enable + restart `5gpn-tgbot`。
4. `gum style` 输出冷启动指引:「未知自己 ID → 给 bot 发 `/id` → 填回 `.tgbot_admins` → `systemctl restart 5gpn-tgbot`」。

落地不变:写 `/etc/5gpn/.tgbot_token`、`.tgbot_admins`(chmod 600)+ 生成/enable `5gpn-tgbot.service`(`Environment=TGBOT_TOKEN/TGBOT_ADMINS`)。

**非 TTY 保留**:`TGBOT_TOKEN=/TGBOT_ADMINS=` env + 现有 `read` 回退,`--setup-tgbot` 仍可脚本化。

## 7. 测试与文档

### tests
- `test_install_policy.sh`:删全部 api/webui 断言(8443、`BoundedSemaphore`、`close_connection`、`timeout`、`TasksMax`/`MemoryMax`、`os.environ`、webui `=== 'active'`/`!!svc[k]`)。保留与 api/webui 无关的(GATEWAY_IP、IOS_PORT、续期等)。
- `test_hardening_policy.sh`:删 api 鉴权日志断言、webui CSP 断言;`NoNewPrivileges ≥4` 阈值**下调**(移除 5gpn-api 单元后重新数:smartdns/iosprofile/tgbot 等内联单元);保留 DoT 853 限速等。
- 新增断言(可放入 `test_install_policy.sh` 或新 `test_gum_policy.sh`):`install_gum` 函数存在且用 release 下载 + 校验;helper 有 echo 兜底(`_HAVE_GUM`);`api-server.py`/`webui` 已从 install.sh 移除;`5gpn-api` 升级清理存在。
- 注:本机 Windows 无 gum/python,grep 级 policy 测试在 Git Bash 跑;gum 交互与 `xray -test`/`nft -c` 是 Linux/CI 门禁(见 [[dev-box-no-python]])。

### docs
- README:组件表/流程去掉 webui + api,保留 TG bot;`etc/` 说明更新;补「install.sh 用 Gum 交互、开场自动装 gum」。
- DESIGN.md §3 组件表 + §9:把 `api-server / tgbot / webui` 改为 `tgbot`(+ 安装期 Gum TUI)。
- HANDOFF.md:同步移除 webui/api 描述。

## 8. 回滚
- webui/api-server 保留于 git 历史;需要时可从历史恢复 + 重新加 `setup_api`。
- Gum 化经兜底 helper,gum 不可用即回退 echo,故 Gum 引入失败不阻断安装。

## 9. 风险
- **Gum 成为安装期硬依赖的观感**:若 gum 下载失败,UI 退化为 echo——必须保证每个 helper 都有 echo 兜底,否则安装器在无网环境不可用。
- **gum spin 吞输出**:只对「不需看输出」的等待用 spin,避免藏掉 update-lists/证书错误。
- **非 TTY 回归**:所有 gum 交互必须 `[[ -t 0 ]]` 门控;漏掉会让 `curl|bash`/CI 卡在等待输入。
- gum 版本锁定与升级:release 二进制需定期校验更新。
