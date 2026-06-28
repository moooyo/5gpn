# P1 — smartdns DNS 大脑 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 smartdns 实现 new-5gpn 的 DNS 大脑:仅 DoT 入口、`address`(强制代理域名表)+ `ip-alias`(chnroute 反集→网关 IP)两级分流、IPv4-only、抗污染、混合 IP 选国内,并提供 chnroute 反集生成器。

**Architecture:** smartdns 接收 DoT(853);命中 `proxy-domains.txt` 的域名直接 `address` 成网关 IP(进 sniproxy);其余并发解析后,凡解析出的 IP 落在 `foreign-cidr.txt`(全网−中国−保留段)即 `ip-alias` 改写成网关 IP,否则原样返回(直连)。所有规则均为磁盘文本文件,改文件 + 重启 smartdns 生效。

**Tech Stack:** smartdns(发行版/官方二进制)、Python 3 标准库(生成器/渲染器,`ipaddress`/`unittest`)、Bash(编排与 policy 测试)。

## Global Constraints

- 目录根:所有新文件落在 `new-5gpn/`(独立于上级旧实现),逐字符合 [new-5gpn/docs/DESIGN.md](DESIGN.md)。
- 仅 DoT 对外:smartdns 只 `bind-tls [::]:853` 对外;明文 53 只允许 `bind 127.0.0.1:5353`(本机内部),不得出现对外的 `bind [::]:53` / `0.0.0.0:53`。
- IPv4-only:`force-AAAA-SOA yes` 必须存在。
- 网关 IP 占位符统一为 `__GATEWAY_IP__`,由渲染器替换;模板中其余占位符:`__BIND_CERT__`、`__BIND_KEY__`、`__PROXY_DOMAINS_FILE__`、`__FOREIGN_CIDR_FILE__`、`__CACHE_SIZE__`。
- 防回环:本阶段不接 sniproxy/quic-proxy,但模板顶部必须有注释声明"sniproxy/quic-proxy 解析器 hardcode 22.22.22.22,绝不指向本机 smartdns"(P2 落实)。
- chnroute 反集安全:生成器在中国列表条目 < 100 时**拒绝生成并退出非 0**,保留旧文件(绝不写出空表)。
- 强制表初始来源(P1 决定):`proxy-domains.txt` **默认空**(仅注释头),依赖 chnroute 兜大多数;gfwlist 导入留待后续阶段,不在 P1。
- Python 仅用标准库;Bash 测试用 Git Bash 可跑(开发机 Windows,目标 Linux,测试只做文本渲染+断言,不依赖 smartdns 二进制)。

---

## File Structure

```
new-5gpn/
  etc/
    smartdns.conf.template      # 主配置模板(占位符)
    proxy-domains.txt           # 强制代理域名表(P1 默认空 + 注释头)
  scripts/
    gen_foreign_cidr.py         # 中国IP列表 -> foreign-cidr.txt(反集,带安全闸)
    render_smartdns_conf.py     # 模板渲染:替换占位符 -> smartdns.conf
    update-lists.sh             # 编排:下载china_ip_list -> 生成反集 -> 渲染 -> 重启smartdns
  tests/
    test_gen_foreign_cidr.py    # 生成器单元测试(unittest)
    test_smartdns_conf_policy.sh# 渲染后配置 policy 断言
    fixtures/
      china-small.txt           # 测试用小型中国IP列表
    run-tests.sh                # 跑全部测试
```

---

### Task 1: 仓库骨架 + 测试入口

**Files:**
- Create: `new-5gpn/tests/run-tests.sh`
- Create: `new-5gpn/tests/fixtures/.gitkeep`
- Create: `new-5gpn/scripts/.gitkeep`

**Interfaces:**
- Produces: `tests/run-tests.sh` —— 跑 `python3 -m unittest` + 所有 `tests/*.sh`,任一失败则整体非 0 退出。

- [ ] **Step 1: 写测试入口脚本**

`new-5gpn/tests/run-tests.sh`:
```bash
#!/usr/bin/env bash
# Run all new-5gpn P1 tests. Exit non-zero on any failure.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
rc=0

echo "== python unit tests =="
python3 -m unittest discover -s "$HERE" -p 'test_*.py' -v || rc=1

echo "== shell policy tests =="
for t in "$HERE"/test_*.sh; do
    [ -e "$t" ] || continue
    [ "$t" = "$HERE/run-tests.sh" ] && continue
    echo "--- $t ---"
    bash "$t" || rc=1
done

[ $rc -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $rc
```

- [ ] **Step 2: 占位文件**

创建空文件 `new-5gpn/tests/fixtures/.gitkeep` 和 `new-5gpn/scripts/.gitkeep`(内容为空)。

- [ ] **Step 3: 验证入口可运行(暂无测试)**

Run: `bash new-5gpn/tests/run-tests.sh`
Expected: 输出 `ALL TESTS PASSED`,退出码 0(此时无测试,unittest 报 0 ran)。

- [ ] **Step 4: Commit**

```bash
git add new-5gpn/tests/run-tests.sh new-5gpn/tests/fixtures/.gitkeep new-5gpn/scripts/.gitkeep
git commit -m "chore(new-5gpn): P1 test harness skeleton"
```

---

### Task 2: chnroute 反集生成器(foreign-cidr)

**Files:**
- Create: `new-5gpn/scripts/gen_foreign_cidr.py`
- Create: `new-5gpn/tests/test_gen_foreign_cidr.py`
- Create: `new-5gpn/tests/fixtures/china-small.txt`

**Interfaces:**
- Produces:
  - `load_networks(path) -> list[IPv4Network]` —— 读 CIDR 列表(忽略注释/空行/非法/非 v4)。
  - `complement_v4(exclude_nets: list[IPv4Network]) -> list[IPv4Network]` —— 返回 IPv4 空间内**不**被 `exclude_nets` 覆盖的聚合 CIDR(升序)。
  - CLI:`python3 gen_foreign_cidr.py <china_list> <out_file>` —— 中国条目<100 则退出码 1 且不写 out_file;否则原子写出 foreign 集。
  - `RESERVED: list[str]` —— 永不计入 foreign 的保留/私网段。

- [ ] **Step 1: 写失败测试**

`new-5gpn/tests/test_gen_foreign_cidr.py`:
```python
import ipaddress, os, subprocess, sys, tempfile, unittest
HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import gen_foreign_cidr as g

def _set(cidrs):
    return [ipaddress.ip_network(c) for c in cidrs]

class TestComplement(unittest.TestCase):
    def test_complement_of_half_space(self):
        # Excluding 0.0.0.0/1 leaves exactly 128.0.0.0/1.
        out = [str(n) for n in g.complement_v4(_set(["0.0.0.0/1"]))]
        self.assertEqual(out, ["128.0.0.0/1"])

    def test_full_space_excluded_gives_empty(self):
        self.assertEqual(g.complement_v4(_set(["0.0.0.0/0"])), [])

    def test_gap_between_two_blocks(self):
        # Exclude 0/8 and 2/8 -> the gap is exactly 1.0.0.0/8 (plus the rest above 3/8).
        out = [str(n) for n in g.complement_v4(_set(["0.0.0.0/8", "2.0.0.0/8"]))]
        self.assertIn("1.0.0.0/8", out)
        self.assertNotIn("0.0.0.0/8", out)
        self.assertNotIn("2.0.0.0/8", out)

    def test_reserved_never_in_foreign(self):
        # With a realistic-sized china list, private ranges must be absent from foreign.
        china = _set(["1.0.0.0/8"])
        reserved = [ipaddress.ip_network(r) for r in g.RESERVED]
        foreign = g.complement_v4(china + reserved)
        for r in ["10.0.0.0/8", "127.0.0.0/8", "192.168.0.0/16"]:
            net = ipaddress.ip_network(r)
            self.assertFalse(any(net.subnet_of(f) or net == f for f in foreign),
                             "%s leaked into foreign" % r)

class TestSafetyGate(unittest.TestCase):
    def test_small_list_refuses_and_keeps_old(self):
        with tempfile.TemporaryDirectory() as d:
            china = os.path.join(d, "china.txt")
            out = os.path.join(d, "foreign.txt")
            open(china, "w").write("1.0.0.0/8\n")            # only 1 entry (<100)
            open(out, "w").write("OLD-CONTENT\n")            # pre-existing file
            r = subprocess.run([sys.executable,
                os.path.join(HERE, "..", "scripts", "gen_foreign_cidr.py"), china, out])
            self.assertEqual(r.returncode, 1)
            self.assertEqual(open(out).read(), "OLD-CONTENT\n")  # untouched

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash new-5gpn/tests/run-tests.sh`
Expected: FAIL —— `ModuleNotFoundError: No module named 'gen_foreign_cidr'`。

- [ ] **Step 3: 写生成器实现**

`new-5gpn/scripts/gen_foreign_cidr.py`:
```python
#!/usr/bin/env python3
"""Generate the 'foreign' (non-China, non-reserved) IPv4 CIDR set.

Usage: gen_foreign_cidr.py <china_ip_list> <out_file>
Refuses (exit 1, leaves out_file untouched) if the china list looks too small,
so a failed/empty download can never blank the foreign set.
"""
import ipaddress
import os
import sys

# Ranges that must NEVER be 'foreign' (so they are never ip-alias'd to the gateway).
RESERVED = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24",
    "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
    "224.0.0.0/4", "240.0.0.0/4",
]
MIN_CHINA_ENTRIES = 100

def load_networks(path):
    nets = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            try:
                net = ipaddress.ip_network(line, strict=False)
            except ValueError:
                continue
            if net.version == 4:
                nets.append(net)
    return nets

def complement_v4(exclude_nets):
    merged = sorted(ipaddress.collapse_addresses(exclude_nets),
                    key=lambda n: int(n.network_address))
    END = (1 << 32) - 1
    result = []
    cursor = 0
    for net in merged:
        start = int(net.network_address)
        if start > cursor:
            result += ipaddress.summarize_address_range(
                ipaddress.IPv4Address(cursor), ipaddress.IPv4Address(start - 1))
        cursor = max(cursor, int(net.broadcast_address) + 1)
    if cursor <= END:
        result += ipaddress.summarize_address_range(
            ipaddress.IPv4Address(cursor), ipaddress.IPv4Address(END))
    return result

def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: gen_foreign_cidr.py <china_list> <out_file>\n")
        return 2
    china_path, out_path = argv[1], argv[2]
    china = load_networks(china_path)
    if len(china) < MIN_CHINA_ENTRIES:
        sys.stderr.write("china list too small (%d < %d); refusing to regenerate\n"
                         % (len(china), MIN_CHINA_ENTRIES))
        return 1
    exclude = china + [ipaddress.ip_network(r) for r in RESERVED]
    foreign = complement_v4(exclude)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for cidr in foreign:
            f.write(str(cidr) + "\n")
    os.replace(tmp, out_path)
    sys.stderr.write("wrote %d foreign CIDRs\n" % len(foreign))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash new-5gpn/tests/run-tests.sh`
Expected: PASS —— 5 个 python 测试全过。

- [ ] **Step 5: Commit**

```bash
git add new-5gpn/scripts/gen_foreign_cidr.py new-5gpn/tests/test_gen_foreign_cidr.py new-5gpn/tests/fixtures/china-small.txt
git commit -m "feat(new-5gpn): chnroute foreign-cidr generator with safety gate"
```
（`fixtures/china-small.txt` 可留空占位或写几条 CIDR;单元测试自带临时数据,不依赖它。）

---

### Task 3: smartdns 配置模板 + 渲染器

**Files:**
- Create: `new-5gpn/etc/smartdns.conf.template`
- Create: `new-5gpn/etc/proxy-domains.txt`
- Create: `new-5gpn/scripts/render_smartdns_conf.py`
- Create: `new-5gpn/tests/test_smartdns_conf_policy.sh`

**Interfaces:**
- Consumes: 无(独立)。
- Produces:
  - CLI:`python3 render_smartdns_conf.py <template> <out_conf> KEY=VALUE ...` —— 把模板中 `__KEY__` 全部替换为 VALUE 后写出;若替换后仍残留 `__[A-Z_]+__` 则退出码 1。

- [ ] **Step 1: 写 policy 测试(失败)**

`new-5gpn/tests/test_smartdns_conf_policy.sh`:
```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
rc=0
fail(){ echo "FAIL: $1"; rc=1; }

python3 "$ROOT/scripts/render_smartdns_conf.py" \
    "$ROOT/etc/smartdns.conf.template" "$OUT" \
    GATEWAY_IP=203.0.113.7 \
    BIND_CERT=/etc/smartdns/cert/fullchain.pem \
    BIND_KEY=/etc/smartdns/cert/privkey.pem \
    PROXY_DOMAINS_FILE=/etc/smartdns/proxy-domains.txt \
    FOREIGN_CIDR_FILE=/etc/smartdns/foreign-cidr.txt \
    CACHE_SIZE=20000 || fail "render failed"

grep -Eq '^bind-tls .*:853'                                "$OUT" || fail "no DoT bind on 853"
grep -Eq '^bind-cert-file /etc/smartdns/cert/fullchain.pem' "$OUT" || fail "no bind-cert-file"
grep -Eq '^bind-cert-key-file /etc/smartdns/cert/privkey.pem' "$OUT" || fail "no bind-cert-key-file"
grep -Eq '^force-AAAA-SOA yes'                             "$OUT" || fail "AAAA not disabled"
grep -Eq '^address /domain-set:proxylist/203\.0\.113\.7'  "$OUT" || fail "no address->gateway for proxylist"
grep -Eq '^ip-rules ip-set:foreign -ip-alias 203\.0\.113\.7' "$OUT" || fail "no ip-alias foreign->gateway"
grep -Eq '^domain-set -name proxylist'                    "$OUT" || fail "no proxylist domain-set"
grep -Eq '^ip-set -name foreign'                          "$OUT" || fail "no foreign ip-set"
# Must NOT expose plaintext 53 publicly:
grep -Eq '^bind (\[::\]|0\.0\.0\.0):53'                   "$OUT" && fail "public plaintext :53 must not exist"
# No unresolved placeholders:
grep -Eq '__[A-Z_]+__'                                    "$OUT" && fail "unresolved placeholder remains"

[ $rc -eq 0 ] && echo "smartdns conf policy: PASS"
exit $rc
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash new-5gpn/tests/test_smartdns_conf_policy.sh`
Expected: FAIL（`render_smartdns_conf.py` 不存在 / 模板缺失）。

- [ ] **Step 3: 写模板**

`new-5gpn/etc/smartdns.conf.template`:
```ini
# new-5gpn smartdns — auto-rendered from smartdns.conf.template. DO NOT edit in place.
# Loop-avoidance: sniproxy/quic-proxy MUST resolve via 22.22.22.22, NEVER this smartdns.

# ---- Ingress: DoT only (853). Plaintext 53 is localhost-internal only. ----
bind-tls [::]:853
bind-cert-file __BIND_CERT__
bind-cert-key-file __BIND_KEY__
bind 127.0.0.1:5353

# ---- IPv4-only ----
force-AAAA-SOA yes

# ---- Cache / TTL ----
cache-size __CACHE_SIZE__
rr-ttl-min 300
rr-ttl-max 86400

# ---- Upstreams: domestic (cn) + clean overseas, raced in default group ----
server 223.5.5.5
server 119.29.29.29
server-tls 8.8.8.8 -host-name dns.google
server-tls 1.1.1.1

# Prefer reachable/closest IP so mixed answers favor the direct (China) IP.
speed-check-mode ping,tcp:443
response-mode first-ping

# ---- (1) Forced-proxy domains -> gateway IP (no resolution) ----
domain-set -name proxylist -type list -file __PROXY_DOMAINS_FILE__
address /domain-set:proxylist/__GATEWAY_IP__

# ---- (2) chnroute: any resolved IP in 'foreign' (non-China) -> rewrite to gateway IP ----
ip-set -name foreign -type list -file __FOREIGN_CIDR_FILE__
ip-rules ip-set:foreign -ip-alias __GATEWAY_IP__
```

`new-5gpn/etc/proxy-domains.txt`:
```text
# Forced-proxy domains (one per line, suffix match). P1 default: empty.
# Add a domain here to ALWAYS route it through the proxy regardless of resolved IP.
```

- [ ] **Step 4: 写渲染器**

`new-5gpn/scripts/render_smartdns_conf.py`:
```python
#!/usr/bin/env python3
"""Render smartdns.conf.template by replacing __KEY__ with KEY=VALUE args.

Usage: render_smartdns_conf.py <template> <out_conf> KEY=VALUE [KEY=VALUE ...]
Exits 1 if any __PLACEHOLDER__ remains after substitution.
"""
import re
import sys

def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: render_smartdns_conf.py <template> <out> KEY=VALUE ...\n")
        return 2
    template, out = argv[1], argv[2]
    subs = {}
    for pair in argv[3:]:
        if "=" not in pair:
            sys.stderr.write("bad KEY=VALUE: %s\n" % pair)
            return 2
        k, v = pair.split("=", 1)
        subs[k] = v
    with open(template, encoding="utf-8") as f:
        content = f.read()
    for k, v in subs.items():
        content = content.replace("__%s__" % k, v)
    leftover = re.search(r"__[A-Z_]+__", content)
    if leftover:
        sys.stderr.write("unresolved placeholder: %s\n" % leftover.group(0))
        return 1
    with open(out, "w", encoding="utf-8") as f:
        f.write(content)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 5: 运行,确认通过**

Run: `bash new-5gpn/tests/run-tests.sh`
Expected: PASS —— python 单测 + `smartdns conf policy: PASS`。

- [ ] **Step 6: Commit**

```bash
git add new-5gpn/etc/smartdns.conf.template new-5gpn/etc/proxy-domains.txt new-5gpn/scripts/render_smartdns_conf.py new-5gpn/tests/test_smartdns_conf_policy.sh
git commit -m "feat(new-5gpn): smartdns config template + renderer + policy tests"
```

---

### Task 4: update-lists 编排脚本

**Files:**
- Create: `new-5gpn/scripts/update-lists.sh`
- Modify: `new-5gpn/tests/test_smartdns_conf_policy.sh`（追加对 update-lists 的 dry-run 断言）

**Interfaces:**
- Consumes: `gen_foreign_cidr.py`、`render_smartdns_conf.py`、`smartdns.conf.template`。
- Produces: `update-lists.sh` —— 环境变量驱动(`CHINA_IP_URL`、`GATEWAY_IP`、`SMARTDNS_DIR`、`DRY_RUN`);`DRY_RUN=1` 时只生成/渲染到指定目录、不下载不重启,退出码反映成功。

- [ ] **Step 1: 写编排脚本**

`new-5gpn/scripts/update-lists.sh`:
```bash
#!/usr/bin/env bash
# Refresh chnroute foreign set + render smartdns.conf, then restart smartdns.
# DRY_RUN=1 skips download (uses existing china file) and skips restart.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."

SMARTDNS_DIR="${SMARTDNS_DIR:-/etc/smartdns}"
GATEWAY_IP="${GATEWAY_IP:-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo 127.0.0.1)}"
CHINA_IP_URL="${CHINA_IP_URL:-https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt}"
CACHE_SIZE="${CACHE_SIZE:-20000}"
DRY_RUN="${DRY_RUN:-0}"

china="$SMARTDNS_DIR/china_ip_list.txt"
foreign="$SMARTDNS_DIR/foreign-cidr.txt"
mkdir -p "$SMARTDNS_DIR"

if [ "$DRY_RUN" != "1" ]; then
    tmp="$china.tmp"
    if wget -qO "$tmp" "$CHINA_IP_URL"; then
        mv "$tmp" "$china"
    else
        echo "[!] china_ip_list download failed; keeping existing $china" >&2
        rm -f "$tmp"
    fi
fi

# Generator refuses (exit 1) on a too-small list, leaving old foreign intact.
python3 "$HERE/gen_foreign_cidr.py" "$china" "$foreign"

python3 "$HERE/render_smartdns_conf.py" \
    "$ROOT/etc/smartdns.conf.template" "$SMARTDNS_DIR/smartdns.conf" \
    GATEWAY_IP="$GATEWAY_IP" \
    BIND_CERT="$SMARTDNS_DIR/cert/fullchain.pem" \
    BIND_KEY="$SMARTDNS_DIR/cert/privkey.pem" \
    PROXY_DOMAINS_FILE="$SMARTDNS_DIR/proxy-domains.txt" \
    FOREIGN_CIDR_FILE="$foreign" \
    CACHE_SIZE="$CACHE_SIZE"

if [ "$DRY_RUN" != "1" ]; then
    systemctl restart smartdns
fi
echo "[OK] lists updated (gateway=$GATEWAY_IP, dry_run=$DRY_RUN)"
```

- [ ] **Step 2: 追加 dry-run policy 测试**

在 `new-5gpn/tests/test_smartdns_conf_policy.sh` 末尾(`exit $rc` 之前)插入:
```bash
# --- update-lists.sh dry-run end-to-end (no network, no restart) ---
TMPDIR2="$(mktemp -d)"; trap 'rm -f "$OUT"; rm -rf "$TMPDIR2"' EXIT
# Seed a >=100-entry china file so the generator does not refuse.
python3 - "$TMPDIR2/china_ip_list.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(150):
        f.write("%d.0.0.0/8\n" % (i % 223))
PY
printf '# empty\n' > "$TMPDIR2/proxy-domains.txt"
DRY_RUN=1 SMARTDNS_DIR="$TMPDIR2" GATEWAY_IP=203.0.113.7 \
    bash "$ROOT/scripts/update-lists.sh" >/dev/null 2>&1 || fail "update-lists dry-run failed"
[ -s "$TMPDIR2/foreign-cidr.txt" ] || fail "foreign-cidr.txt not generated"
grep -Eq '^ip-rules ip-set:foreign -ip-alias 203\.0\.113\.7' "$TMPDIR2/smartdns.conf" \
    || fail "rendered conf missing ip-alias"
```

- [ ] **Step 3: 运行,确认通过**

Run: `bash new-5gpn/tests/run-tests.sh`
Expected: PASS（含 update-lists dry-run 断言)。

- [ ] **Step 4: Commit**

```bash
git add new-5gpn/scripts/update-lists.sh new-5gpn/tests/test_smartdns_conf_policy.sh
git commit -m "feat(new-5gpn): update-lists orchestrator (chnroute refresh + render) with dry-run test"
```

---

### Task 5: 行为冒烟(Linux 集成,需 smartdns 二进制)

> 这是 P1 的**验收门**,不能在开发机(Windows)自动跑;在一台 Linux 测试机上手动执行,逐项记录结果。它验证三件 DESIGN 承诺:被墙/国外→网关IP、国内→真实国内IP、混合IP选国内、环回不死循环。

**Files:**
- Create: `new-5gpn/tests/integration-smoke.md`(把下面步骤与预期落成可勾选清单)

**Interfaces:**
- Consumes: Task 1–4 全部产物 + 已安装 smartdns + 测试机网络。

- [ ] **Step 1: 准备**

在 Linux 测试机:安装 smartdns;放置自签或 LE 证书到 `/etc/smartdns/cert/`;`SMARTDNS_DIR=/etc/smartdns GATEWAY_IP=<本机IP> bash scripts/update-lists.sh`;`systemctl restart smartdns`。

- [ ] **Step 2: 国外域名 → 网关 IP**

Run: `dig +tcp @<本机IP> -p 853 ... `（用支持 DoT 的客户端,如 `kdig -d @<本机IP> +tls www.google.com`）
Expected: 返回 **网关 IP**(`__GATEWAY_IP__` 渲染值),而非 Google 真实 IP。

- [ ] **Step 3: 国内域名 → 真实国内 IP**

Run: `kdig @<本机IP> +tls www.qq.com`
Expected: 返回 **真实国内 IP**(落在 china_ip_list,不是网关 IP)。

- [ ] **Step 4: 混合 IP → 选国内**

Run: 选一个已知双解析(国内+国外)的域名,`kdig @<本机IP> +tls <domain>`
Expected: 返回的是**国内 IP**(直连),不是网关 IP。
若不满足:在 `ip-rules` 增补 `ip-set:foreign -ip-alias ... ` 的同时,加 `nameserver`/`-whitelist-ip` 偏好国内组,重测(记录到 integration-smoke.md 的"调参"段)。

- [ ] **Step 5: AAAA 关闭 + 无死循环**

Run: `kdig @<本机IP> +tls -t AAAA www.google.com`;并确认 smartdns 日志无对自身 853/5353 的递归。
Expected: AAAA 返回 SOA/空;无回环。

- [ ] **Step 6: Commit 冒烟记录**

```bash
git add new-5gpn/tests/integration-smoke.md
git commit -m "test(new-5gpn): P1 integration smoke checklist + results"
```

---

## Self-Review

- **Spec coverage(对照 DESIGN 第 4/5/11 节)**:DoT-only 入口✓(Task3 模板+policy)、`address` 强制表✓(Task3)、`ip-alias` chnroute✓(Task2 生成器 + Task3 规则)、IPv4-only✓(`force-AAAA-SOA`)、防回环✓(模板注释 + 不接代理 + Step5 验证)、chnroute 不清空✓(Task2 安全闸 + Task4 保留旧文件)、混合IP选国内✓(Task3 `response-mode first-ping` + Task5 验证/调参)、列表管理"改文件+重启"✓(Task4)。
- **Placeholder 扫描**:无 TBD;`__KEY__` 为有意模板占位,渲染器强制校验残留。Task5 是显式的人工集成门(配置行为无法在 Windows 单元化),已给出确切 `kdig` 命令与预期,非含糊。
- **类型/名称一致性**:`complement_v4` / `load_networks` / `RESERVED` 在 Task2 定义并在测试中按同名引用;渲染占位符集合(`GATEWAY_IP/BIND_CERT/BIND_KEY/PROXY_DOMAINS_FILE/FOREIGN_CIDR_FILE/CACHE_SIZE`)在模板、渲染器调用、policy 测试、update-lists 四处一致。

## 已知后续(非 P1)
- clean 组在国内机器的可达性(可能需先经固定干净通道)——P4。
- 抗污染若 `response-mode`+ 上游 DoT 仍漏污染,补 `bogus-nxdomain` / `-blacklist-ip` 已知污染段——P1 调参段或 P2。
- `proxy-domains.txt` 可选 gfwlist 导入——后续阶段。
