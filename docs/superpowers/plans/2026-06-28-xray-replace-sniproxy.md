# xray-core 替换 sniproxy 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 xray-core 的 `dokodemo-door` + sniffing 替换 dlundquist/sniproxy,作为 TCP(80/443)与 QUIC(UDP 443)的 SNI 透明转发层,直出不变。

**Architecture:** xray 单进程监听 80/443,sniffing 从 ClientHello/QUIC Initial/HTTP Host 提取域名并改写目的地,freedom 直出;内置 DNS 锁定外部解析器 `22.22.22.22` 防回环;嗅探失败落占位 `127.0.0.1` 被 blackhole 丢弃。安装用官方预编译二进制(无 Go 工具链),进程以 root 跑 + systemd sandbox。

**Tech Stack:** xray-core(预编译 release 二进制)、nftables、systemd、bash;策略测试为纯 grep,在 Git Bash 本机可跑。

## Global Constraints

逐条来自 spec([2026-06-28-xray-replace-sniproxy-design.md](../specs/2026-06-28-xray-replace-sniproxy-design.md)),每个任务隐含包含:

- **IPv4-only**:xray `queryStrategy: "UseIPv4"`,freedom `domainStrategy: "ForceIPv4"`。
- **直出**:仅 freedom direct;无 mark / 策略路由 / 隧道 / 多出口。
- **防回环(强约束)**:xray `dns.servers` 只含 `22.22.22.22`,绝不含本机 smartdns(`127.0.0.1`/`::1`/`:853`/`:5353`)。
- **嗅探失败兜底**:dokodemo-door 占位 `address` = `127.0.0.1`;路由规则把私网/环回 CIDR → `blackhole`。
- **无 Go 工具链**:只下载预编译二进制,绝不 `go build` / `git clone` 编译。
- **权限**:xray `User=root`,但保留 systemd sandbox(`NoNewPrivileges` / `ProtectSystem=strict` / `RestrictAddressFamilies=AF_INET AF_UNIX` 等)。
- **二进制校验**:`XRAY_VERSION` 可由 env 覆盖(默认 `v26.6.22`);SHA256 优先用 `XRAY_SHA256` 覆盖,否则比对 release 的 `.dgst`。
- **路径**:二进制 `/usr/local/bin/xray`;配置 `/usr/local/etc/xray/config.json`。
- **测试边界**:策略测试是纯 grep,Git Bash 本机可跑;`xray run -test` 与 `nft -c` 是 Linux/CI 门禁,不在本机跑(见 [[dev-box-no-python]])。

---

### Task 1: xray 数据面配置 `etc/xray/config.json`

**Files:**
- Create: `etc/xray/config.json`

**Interfaces:**
- Produces:`/usr/local/etc/xray/config.json` 的仓库源;后续 Task 2(unit `-c` 路径)、Task 4(install_files 安装它)、Task 5(策略断言)依赖其形状:dokodemo-door 80/443、443 含 udp、sniffing `tls`/`quic`/`http`、freedom `ForceIPv4`、blackhole、占位 `127.0.0.1`、私网→block、dns `22.22.22.22`。

- [ ] **Step 1: 写配置文件**

`etc/xray/config.json`(严格 JSON,无注释,便于 `jq` 校验):

```json
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["22.22.22.22"],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "p443",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "address": "127.0.0.1" },
      "sniffing": { "enabled": true, "destOverride": ["tls", "quic"] }
    },
    {
      "tag": "p80",
      "listen": "0.0.0.0",
      "port": 80,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "address": "127.0.0.1" },
      "sniffing": { "enabled": true, "destOverride": ["http"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "ForceIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "::1/128"],
        "outboundTag": "block"
      }
    ]
  }
}
```

> 说明:不用 `geoip:private`,改用显式私网/环回 CIDR——避免依赖 release 的 `geoip.dat`(组件更少)。占位 `127.0.0.1` 落在 `127.0.0.0/8`,sniff 失败即被 blackhole,堵死回环。

- [ ] **Step 2: 本机校验 JSON 合法 + 形状断言**

Run(Git Bash):
```bash
cd /d/Code/new-5gpn
# JSON 合法性:有 jq 用 jq,否则用 node;两者都无则跳过(留给 CI 的 xray -test)
if command -v jq >/dev/null; then jq -e . etc/xray/config.json >/dev/null && echo "JSON OK"; \
elif command -v node >/dev/null; then node -e "JSON.parse(require('fs').readFileSync('etc/xray/config.json'))" && echo "JSON OK"; \
else echo "SKIP json-parse (no jq/node) — xray -test is the CI gate"; fi
# 关键形状
grep -q '"22.22.22.22"' etc/xray/config.json && \
grep -q '"network": "tcp,udp"' etc/xray/config.json && \
grep -q '"quic"' etc/xray/config.json && \
grep -q '"ForceIPv4"' etc/xray/config.json && \
grep -q '"blackhole"' etc/xray/config.json && \
grep -q '"127.0.0.1"' etc/xray/config.json && echo "SHAPE OK"
```
Expected: `JSON OK`(或 SKIP)+ `SHAPE OK`

- [ ] **Step 3: Commit**

```bash
git add etc/xray/config.json
git commit -m "feat(xray): add dokodemo-door config (tls/quic/http sniff, direct, anti-loop)"
```

---

### Task 2: systemd 单元 `etc/systemd/xray.service`

**Files:**
- Create: `etc/systemd/xray.service`
- Delete: `etc/systemd/sniproxy.service`

**Interfaces:**
- Consumes:Task 1 的配置路径 `/usr/local/etc/xray/config.json`。
- Produces:单元文件;Task 4(firewall 安装它)、Task 5(hardening + proxy 断言)依赖 `ExecStart ... -c /usr/local/etc/xray/config.json`、`NoNewPrivileges=yes`、`ProtectSystem=strict`、`RestrictAddressFamilies=AF_INET AF_UNIX`。

- [ ] **Step 1: 写新单元**

`etc/systemd/xray.service`:

```ini
[Unit]
Description=5gpn xray-core (SNI/QUIC transparent proxy)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535
# Sandbox: leaf proxy — binds 80/443 tcp + 443 udp, root with no new privileges,
# read-only config, IPv4 (+unix) sockets only. Writes nothing (logs -> journald).
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_UNIX
ReadOnlyPaths=/usr/local/etc/xray

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: 删除旧单元**

Run(Git Bash):
```bash
cd /d/Code/new-5gpn
git rm etc/systemd/sniproxy.service
```

- [ ] **Step 3: 形状断言**

Run:
```bash
grep -q -- '-c /usr/local/etc/xray/config.json' etc/systemd/xray.service && \
grep -q 'NoNewPrivileges=yes' etc/systemd/xray.service && \
grep -q 'ProtectSystem=strict' etc/systemd/xray.service && \
grep -q 'RestrictAddressFamilies=AF_INET AF_UNIX' etc/systemd/xray.service && echo "UNIT OK"
```
Expected: `UNIT OK`

- [ ] **Step 4: Commit**

```bash
git add etc/systemd/xray.service
git commit -m "feat(xray): systemd unit (root + sandbox), drop sniproxy.service"
```

---

### Task 3: 防火墙放行 QUIC `scripts/setup-firewall.sh`

**Files:**
- Modify: `scripts/setup-firewall.sh`

**Interfaces:**
- Consumes:Task 2 的 `etc/systemd/xray.service`(安装到 `/etc/systemd/system/`)。
- Produces:nft 规则允许 `172.22.0.0/16` 的 `udp dport 443`、不再 `reject` UDP 443;安装 `xray.service` 并清理旧 `sniproxy.service`。

- [ ] **Step 1: 改文件头注释(行 1-5)**

把开头注释块里「QUIC/HTTP3 is not proxied: UDP 443 is rejected so clients fall back to TCP/TLS (sniproxy).」整段替换为:

```bash
# 5gpn firewall + proxy service install. Direct egress only — no packet
# marking, no policy routing, no tunnels, no exit layer. xray egresses
# straight out the gateway's default route. QUIC/HTTP3 IS proxied: xray
# sniffs the QUIC SNI, so UDP 443 from NPN clients is allowed.
```

- [ ] **Step 2: 替换 UDP 443 规则(原行 38-40)**

把:
```bash
        ip saddr 172.22.0.0/16 tcp dport { 80, 443, ${IOS_PORT} } accept
        # QUIC/HTTP3 not proxied: reject UDP 443 so clients fall back to TCP fast.
        udp dport 443 reject
```
替换为:
```bash
        ip saddr 172.22.0.0/16 tcp dport { 80, 443, ${IOS_PORT} } accept
        # QUIC/HTTP3 proxied by xray: allow UDP 443 from NPN clients (same scope as TCP 443).
        ip saddr 172.22.0.0/16 udp dport 443 accept
```

- [ ] **Step 3: 装 xray 单元、清理旧 sniproxy 单元(原行 52-54)**

把:
```bash
install -m 0644 "${ROOT}/etc/systemd/sniproxy.service"   /etc/systemd/system/sniproxy.service
systemctl daemon-reload
echo "[OK] firewall + sniproxy unit installed (direct egress; QUIC/UDP 443 disabled)"
```
替换为:
```bash
# Migrate off sniproxy if a previous install left it behind.
systemctl disable --now sniproxy 2>/dev/null || true
rm -f /etc/systemd/system/sniproxy.service
install -m 0644 "${ROOT}/etc/systemd/xray.service"   /etc/systemd/system/xray.service
systemctl daemon-reload
echo "[OK] firewall + xray unit installed (direct egress; QUIC/UDP 443 proxied)"
```

- [ ] **Step 4: 语法 + 形状断言**

Run(Git Bash):
```bash
cd /d/Code/new-5gpn
bash -n scripts/setup-firewall.sh && echo "SYNTAX OK"
grep -q '172.22.0.0/16 udp dport 443 accept' scripts/setup-firewall.sh && \
! grep -q 'udp dport 443 reject' scripts/setup-firewall.sh && \
grep -q 'xray.service' scripts/setup-firewall.sh && echo "FW OK"
```
Expected: `SYNTAX OK` + `FW OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-firewall.sh
git commit -m "feat(firewall): allow UDP 443 (QUIC) from NPN, install xray unit"
```

---

### Task 4: 安装编排 `install.sh`

**Files:**
- Modify: `install.sh`

**Interfaces:**
- Consumes:Task 1 配置、Task 2 单元、Task 3 防火墙脚本。
- Produces:`install_xray()`(下载+校验+装预编译二进制)、安装 config.json、certbot hook 停/启 xray、服务列表含 xray。后续 Task 5 的 install/hardening 断言依赖 `systemctl stop xray`、`systemctl start xray`、`install_xray`、`SMARTDNS_SHA256` 仍在。

- [ ] **Step 1: 路径变量(原行 25-29)**

把:
```bash
BUILD_DIR="${BASE_DIR}/build"            # sniproxy git build scratch
```
改为:
```bash
BUILD_DIR="${BASE_DIR}/build"            # download/unpack scratch
```
把:
```bash
SNIPROXY_CONF="/etc/sniproxy.conf"
```
改为:
```bash
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
```

- [ ] **Step 2: 用 `install_xray()` 替换 `build_sniproxy()`(原行 219-236)**

整段 `build_sniproxy() { ... }` 替换为:

```bash
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then info "xray already installed."; return 0; fi
    local ver="${XRAY_VERSION:-v26.6.22}"
    local url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-64.zip"
    info "Downloading xray ${ver} (prebuilt binary; no Go toolchain)..."
    command -v unzip >/dev/null 2>&1 || { apt-get install -y unzip >/dev/null 2>&1 || true; }
    mkdir -p "$BUILD_DIR"
    local zip="$BUILD_DIR/Xray-linux-64.zip"
    curl -fsSL "$url" -o "$zip" || { err "xray download failed ($url)"; exit 1; }
    # Integrity: opt-in pin via XRAY_SHA256, else verify against the release .dgst.
    local exp="${XRAY_SHA256:-}"
    if [[ -z "$exp" ]]; then
        curl -fsSL "${url}.dgst" -o "${zip}.dgst" \
            && exp="$(grep -ioE '\b[0-9a-f]{64}\b' "${zip}.dgst" | head -1)" || true
    fi
    if [[ -n "$exp" ]]; then
        local got; got="$(sha256sum "$zip" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { err "xray sha256 mismatch (want $exp got $got)"; exit 1; }
        ok "xray archive sha256 verified."
    else
        warn "xray sha256 UNVERIFIED (set XRAY_SHA256 or ensure .dgst reachable)."
    fi
    unzip -o "$zip" xray -d "$BUILD_DIR" >/dev/null
    install -m 0755 "$BUILD_DIR/xray" "$XRAY_BIN"
    [[ -x "$XRAY_BIN" ]] || { err "xray install failed."; exit 1; }
    ok "xray installed to $XRAY_BIN ($ver)."
}
```

- [ ] **Step 3: 安装配置文件(原行 263-264)**

把:
```bash
    # sniproxy.conf (resolver hardcoded to 22.22.22.22 in the repo file)
    install -m 0644 "${SCRIPT_DIR}/etc/sniproxy.conf" "$SNIPROXY_CONF"
```
替换为:
```bash
    # xray config (dns hardcoded to 22.22.22.22 for loop-avoidance, IPv4-only, direct).
    install -d -m 0755 "$XRAY_DIR"
    install -m 0644 "${SCRIPT_DIR}/etc/xray/config.json" "$XRAY_DIR/config.json"
```

- [ ] **Step 4: certbot 续期 hook 改停/启 xray(原行 378-399)**

逐处把 `sniproxy` 改 `xray`:
- 注释行 378-380:`where sniproxy / holds :80` → `where xray / holds :80`。
- pre hook 注释行 386 与命令行 388:`stop sniproxy (binds :80)` → `stop xray (binds :80)`;`systemctl stop sniproxy` → `systemctl stop xray`。
- post hook 注释行 392 与命令行 394:`bring sniproxy back` → `bring xray back`;`systemctl start sniproxy` → `systemctl start xray`。
- 行 399 echo:`cycle sniproxy` → `cycle xray`。

具体替换后这两行为:
```bash
systemctl stop xray 2>/dev/null || true
```
```bash
systemctl start xray 2>/dev/null || true
```

- [ ] **Step 5: 服务列表(原行 571、745)与编排(原行 786、797、450)**

- 行 571:`for svc in smartdns sniproxy nftables; do` → `for svc in smartdns xray nftables; do`
- 行 745:`for svc in smartdns sniproxy; do` → `for svc in smartdns xray; do`
- 行 786:`    build_sniproxy` → `    install_xray`
- 行 797 注释:`# pxout user + DoT-only nft + sniproxy unit` → `# DoT-only nft + xray unit`
- 行 450 ok 消息:`Firewall + sniproxy unit installed.` → `Firewall + xray unit installed.`
- 文件头注释(行 5、9)把 `sniproxy` / `QUIC/HTTP3 is not proxied ... fall back to TCP` 改为 xray + QUIC 已代理的措辞。

- [ ] **Step 6: 语法 + 断言**

Run(Git Bash):
```bash
cd /d/Code/new-5gpn
bash -n install.sh && echo "SYNTAX OK"
grep -q 'install_xray' install.sh && \
! grep -q 'build_sniproxy' install.sh && \
grep -q 'systemctl stop xray' install.sh && \
grep -q 'systemctl start xray' install.sh && \
grep -q 'for svc in smartdns xray nftables' install.sh && \
grep -q 'SMARTDNS_SHA256' install.sh && echo "INSTALL OK"
```
Expected: `SYNTAX OK` + `INSTALL OK`

- [ ] **Step 7: Commit**

```bash
git add install.sh
git commit -m "feat(install): install prebuilt xray + verify, replace sniproxy wiring"
```

---

### Task 5: 策略测试改写 + 全套跑绿

**Files:**
- Modify: `tests/test_proxy_policy.sh`
- Modify: `tests/test_hardening_policy.sh`
- Modify: `tests/test_install_policy.sh`

**Interfaces:**
- Consumes:Task 1-4 的所有产物。
- Produces:更新后的 grep 回归套件,断言 xray 形状、QUIC 放行、防回环兜底、续期停/启 xray。

- [ ] **Step 1: 重写 `tests/test_proxy_policy.sh`**

整文件替换为:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

XRAY="$ROOT/etc/xray/config.json"
FW="$ROOT/scripts/setup-firewall.sh"
SS="$ROOT/etc/systemd/xray.service"

# --- xray: loop-avoidance + shape ---
grep -Eq '"22\.22\.22\.22"'                          "$XRAY" || fail "xray dns resolver not 22.22.22.22"
grep -Eq '127\.0\.0\.1:853|:5353|"::1"[^/]'          "$XRAY" && fail "xray dns must not point at local smartdns"
grep -Eq '"dokodemo-door"'                           "$XRAY" || fail "xray not using dokodemo-door"
grep -Eq '"port":[[:space:]]*443'                    "$XRAY" || fail "xray missing 443 inbound"
grep -Eq '"network":[[:space:]]*"tcp,udp"'           "$XRAY" || fail "xray 443 must handle tcp+udp (QUIC)"
grep -Eq '"quic"'                                    "$XRAY" || fail "xray must sniff quic"
grep -Eq '"tls"'                                     "$XRAY" || fail "xray must sniff tls"
grep -Eq '"port":[[:space:]]*80'                     "$XRAY" || fail "xray missing 80 inbound"
grep -Eq '"http"'                                    "$XRAY" || fail "xray must sniff http on :80"
grep -Eq '"domainStrategy":[[:space:]]*"ForceIPv4"'  "$XRAY" || fail "xray freedom not ForceIPv4 (IPv4-only)"
grep -Eq '"blackhole"'                               "$XRAY" || fail "xray missing blackhole (anti-loop sink)"
grep -Eq '"address":[[:space:]]*"127\.0\.0\.1"'      "$XRAY" || fail "xray dokodemo placeholder not 127.0.0.1 (sniff-fail sink)"
grep -Eq '127\.0\.0\.0/8'                            "$XRAY" || fail "xray missing private->block anti-loop rule"

# --- firewall: DoT-only inbound; exit/mark layer GONE; QUIC now proxied ---
grep -Eq 'tcp_ports="22, 853"'                   "$FW" || fail "inbound not limited to 22/853"
grep -Eq 'udp dport 53 accept'                   "$FW" && fail "public plaintext :53 must not be opened"
grep -Eq 'pgw_exit|fwmark|table 100|skuid'       "$FW" && fail "exit/mark layer must be removed (direct egress only)"
grep -Eq 'udp dport 443 reject'                  "$FW" && fail "UDP 443 must NOT be rejected (QUIC now proxied)"
grep -Eq '172\.22\.0\.0/16 udp dport 443 accept' "$FW" || fail "UDP 443 (QUIC) from NPN must be accepted"
grep -Eq 'quic-proxy'                            "$FW" && fail "no separate quic-proxy (xray handles QUIC inline)"

# --- systemd: xray config path ---
grep -Eq -- '-c /usr/local/etc/xray/config.json' "$SS" || fail "xray.service missing config path"

[ $rc -eq 0 ] && echo "proxy policy: PASS"
exit $rc
```

- [ ] **Step 2: 改 `tests/test_hardening_policy.sh`(行 7、12-14)**

行 7 把:
```bash
SNI_SVC="$ROOT/etc/systemd/sniproxy.service"
```
改为:
```bash
XRAY_SVC="$ROOT/etc/systemd/xray.service"
```
行 12-14 替换为:
```bash
grep -Fq 'NoNewPrivileges=yes'   "$XRAY_SVC" || fail "xray.service: no NoNewPrivileges"
grep -Fq 'ProtectSystem=strict'  "$XRAY_SVC" || fail "xray.service: no ProtectSystem=strict"
grep -Fq 'RestrictAddressFamilies=AF_INET AF_UNIX' "$XRAY_SVC" || fail "xray.service: address families not restricted"
```

- [ ] **Step 3: 改 `tests/test_install_policy.sh`(行 12-21)**

把行 12-21 中 `sniproxy` 全改 `xray`,关键断言两行变为:
```bash
grep -Eq 'systemctl stop xray' "$INSTALL" || fail "renewal must stop xray to free :80 for --standalone"
```
```bash
grep -Eq 'systemctl start xray' "$INSTALL" || fail "post-renewal must restart xray"
```
注释行 12、15、16、19 里的 `sniproxy` 一并改 `xray`。

- [ ] **Step 4: 跑全套策略测试(应全绿)**

Run(Git Bash):
```bash
cd /d/Code/new-5gpn
for t in tests/test_proxy_policy.sh tests/test_hardening_policy.sh tests/test_install_policy.sh tests/test_cleanup_policy.sh; do
  echo "== $t =="; bash "$t"
done
```
Expected:每个输出 `... policy: PASS`,无 `FAIL:` 行。

- [ ] **Step 5: Commit**

```bash
git add tests/test_proxy_policy.sh tests/test_hardening_policy.sh tests/test_install_policy.sh
git commit -m "test: update policy assertions for xray + QUIC migration"
```

---

### Task 6: 文档更新

**Files:**
- Modify: `docs/DESIGN.md`
- Modify: `README.md`
- Modify: `tests/integration-smoke.md`

**Interfaces:**
- Consumes:全部前序变更(描述最终状态)。
- Produces:与实现一致的文档与冒烟手册。

- [ ] **Step 1: `docs/DESIGN.md`**

- 顶部「已定决策」§(行 6)与 §12:把「QUIC/HTTP3 不代理 / UDP 443 reject / 不含 Go 工具链」改为「QUIC/HTTP3 经 xray dokodemo-door sniff `quic` 透明转发;UDP 443 放行;引入**预编译** xray 二进制(不引入 Go 构建工具链);xray 以 root + systemd sandbox 运行」,并保留决策反转的「理由」一行。
- §3 组件表:`sniproxy + sniproxy.conf` 行改为 `xray + config.json`(dokodemo-door 80/443tcp+443udp、sniffing tls/quic/http、freedom 直出、dns hardcode 22.22.22.22)。
- §5 正确性约束:第 1 条解析器改述为 xray `dns.servers=["22.22.22.22"]`;新增第 (嗅探失败 blackhole)兜底约束。
- §6 数据流三类:把「QUIC 被 reject→回退 TCP」改为「QUIC 经 xray sniff quic 直出」。
- §8 出口:把 sniproxy 改为 xray,删「UDP 443 reject / 回退 TCP」表述。

- [ ] **Step 2: `README.md`(行 3、9、24、35-36、44-46、59、93)**

把所有 `sniproxy` 改为 `xray`;行 45「QUIC/HTTP3 不代理:UDP 443 reject…」改为「QUIC/HTTP3 由 xray sniff `quic` 透明转发、直出」;行 59「编译 sniproxy」改为「装预编译 xray 二进制」;行 46 防回环表述改为 xray `dns` hardcode `22.22.22.22`;行 93 `etc/` 说明里 `sniproxy 配置` 改 `xray 配置`。

- [ ] **Step 3: `tests/integration-smoke.md`(行 66-69、77-80、94-107)**

- 行 66-69 安装步骤:删「Build/install dlundquist sniproxy」「cp sniproxy.conf」;改为「安装预编译 xray 到 `/usr/local/bin/xray`、`cp 5gpn/etc/xray/config.json /usr/local/etc/xray/config.json`、`systemctl enable --now xray`」;setup-firewall 描述改「allows UDP 443」。
- 行 77 路径:sniproxy → xray。
- 行 79-80「QUIC disabled → TCP fallback」整条改为「**QUIC proxied**:`curl --http3 https://<foreign-domain>` 应经 xray 直出可达;`curl https://...` 也可」。
- 行 94-107 续期段:`sniproxy` 全改 `xray`(停/启 xray、`systemctl is-active xray`)。

- [ ] **Step 4: 断言文档无残留 sniproxy/旧表述**

Run(Git Bash):
```bash
cd /d/Code/new-5gpn
# 这些文件不应再提 sniproxy,也不应再说 UDP 443 reject
! grep -rin 'sniproxy' docs/DESIGN.md README.md tests/integration-smoke.md && \
! grep -rin 'udp 443.*reject\|reject.*udp 443' README.md docs/DESIGN.md && echo "DOCS OK"
```
Expected: `DOCS OK`

- [ ] **Step 5: 跑全套策略测试确认未回归**

Run:
```bash
cd /d/Code/new-5gpn
bash tests/test_cleanup_policy.sh && bash tests/test_proxy_policy.sh && \
bash tests/test_hardening_policy.sh && bash tests/test_install_policy.sh
```
Expected:全部 `... policy: PASS`。

- [ ] **Step 6: Commit**

```bash
git add docs/DESIGN.md README.md tests/integration-smoke.md
git commit -m "docs: reflect xray + QUIC migration (DESIGN, README, smoke)"
```

---

## Self-Review

**Spec coverage**(逐节对照 spec):
- §2 决策(安装方式/权限/防回环/兜底/路径/续期)→ Task 1(防回环、兜底)、Task 2(权限/路径)、Task 4(安装方式/续期)。✓
- §3 数据面 config → Task 1。✓
- §4 三类协议(tls/quic/http)→ Task 1 形状 + Task 5 断言;HTTP Host 锁定/无 Host blackhole 由占位+私网规则覆盖。✓
- §5 两条正确性约束 → Task 1(dns + 私网 blackhole)+ Task 5 断言。✓
- §6 systemd/防火墙/install → Task 2/3/4。✓
- §7 文档/测试 → Task 5(测试)+ Task 6(文档)。✓
- §8 回滚 → 旧文件留在 git 历史;Task 3 含 `systemctl disable sniproxy` + 删旧单元的迁移清理。✓
- §9 风险 → 文档(Task 6)记录;不需代码。✓

**Placeholder scan:** 无 TBD/TODO;`install_xray` 给出完整函数;所有 grep/编辑给出确切行与内容。`XRAY_VERSION` 默认 `v26.6.22` 为可由 env 覆盖的真实默认值(非占位),运维可 bump。

**Type/命名一致性:** `XRAY_BIN`、`XRAY_DIR`、`install_xray`、`/usr/local/etc/xray/config.json`、`xray.service`、占位 `127.0.0.1` 在 config/unit/install/tests 间一致;Task 5 断言字符串与 Task 1-4 产物逐一对齐(`"tcp,udp"`、`"ForceIPv4"`、`172.22.0.0/16 udp dport 443 accept`、`-c /usr/local/etc/xray/config.json`、`systemctl stop/start xray`)。✓
