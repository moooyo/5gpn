# Three-Tier Deterministic DNS Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace smartdns's implicit "resolve-then-judge-by-IP + first-ping speed test" split with an explicit three-tier deterministic model (blacklist→foreign-DNS, whitelist→domestic-DNS, neither→both-but-prefer-China-IP-without-speed-test), make the sing-box SNI resolver promptable at install time, and clean up three loose ends.

**Architecture:** smartdns gets two upstream groups (`domestic`, `foreign`), both in the default group. Tier 1 (blacklist `proxy-domains.txt`) → `address /domain-set:blacklist/GATEWAY_IP` (no resolution). Tier 2 (whitelist `china-domains.txt`) → `nameserver /domain-set:cnlist/domestic`. Tier 3 (neither, the default group queries both) → `ip-rules ip-set:china_ip -whitelist-ip` keeps only China IPs when any are present (content filter on the merged answer, no latency probe), and `ip-rules ip-set:foreign -ip-alias GATEWAY_IP` funnels the remaining foreign-only answers into the proxy. The sing-box data plane and anti-loop are untouched.

**Tech Stack:** smartdns (2024+ build), bash (`install.sh`, `scripts/update-lists.sh`), Python stdlib (`render_smartdns_conf.py`, `gen_foreign_cidr.py`), nftables, systemd. Pure-grep policy tests run under Git Bash on Windows; render / `smartdns` runtime / three-tier behavior are **test-env** (Debian 13) gates.

**Spec:** [docs/superpowers/specs/2026-06-30-three-tier-dns-split-design.md](../specs/2026-06-30-three-tier-dns-split-design.md)

## Global Constraints

Every task's requirements implicitly include these (verbatim from the spec):

- **Tier-3 selection MUST be content-based, no speed test:** `ip-rules ip-set:china_ip -whitelist-ip` + `speed-check-mode none` + `dualstack-ip-selection no`. **Never** `response-mode first-ping`/`fastest-ip`/`fastest-response` for CN preference.
- **Both upstream groups stay in the default group:** `server … -group domestic` and `server-tls … -group foreign`, **no** `-exclude-default-group` on either (tier-3 must query both).
- **Blacklist = `address /domain-set:blacklist/GATEWAY_IP`** (sourced from `proxy-domains.txt`, no resolution). This is the strongest force-proxy and is what tgbot still manages.
- **No list may be blanked on failure:** china-domains / china_ip / foreign-cidr generation must keep the old file on download/parse failure (min-entry guard + atomic write). An empty list breaks routing.
- **Data plane / anti-loop untouched:** do not change `etc/sing-box/config.json`, the `22.22.22.22` resolver, or any reject rule. This plan only touches the DNS brain + installer + docs.
- **smartdns must be a 2024+ build** (cache fix for "all-foreign-upstreams-timeout + non-CN domestic answer"). Verified on test-env in Task 4; reorder `install_smartdns` to release-first only if the distro build is older.
- **P0 resolver:** install-time Gum prompt, default `22.22.22.22`, **prompt only — no probe, no warning**; `SINGBOX_RESOLVER` env wins; non-TTY/CI falls through to env/default.
- **Platform:** pure-grep tests run under Git Bash on Windows; `render_smartdns_conf.py` + `smartdns` + live DNS behavior are test-env gates. test-env SSH per [CLAUDE.md](../../../CLAUDE.md) (Windows native ssh; base64 for multi-line; scp for whole files).
- **Branch:** direct on `main` (user-authorized for this project).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `etc/smartdns.conf.template` | Rewrite | Three-tier config skeleton (groups, blacklist `address`, cnlist `nameserver`, china_ip/foreign `ip-rules`, `speed-check-mode none`) |
| `scripts/update-lists.sh` | Modify | Generate `china-domains.txt` (felixonmars) + `china_ip.conf`; drop `china-whitelist.conf`; pass new render args |
| `scripts/render_smartdns_conf.py` | No change | Generic `__KEY__` substitutor — only the arg set changes |
| `scripts/gen_foreign_cidr.py` | No change | Already excludes reserved/private; `foreign-cidr.txt` unchanged |
| `tests/test_dns_split_policy.sh` | Create | Pure-grep asserts on the raw template + update-lists (dev-box runnable) |
| `tests/test_smartdns_conf_policy.sh` | Modify | Rendered-output asserts (new shape) + update-lists dry-run (CI/test-env gate) |
| `install.sh` | Modify | P0 resolver prompt + persistence; `DOT_RATE/DOT_BURST` in `--help` + forward; (Task 4) smartdns release-first if needed |
| `tgbot.py` | Modify | User-facing wording "强制代理域名" → "黑名单" |
| `docs/DESIGN.md` | Modify | §4 three-tier model; §12 "引入 chinalist" reversal entry |
| `README.md` | Modify | Key-features bullet: two-tier-no-list → three-tier |
| `docs/HANDOFF.md` | Modify | §3 note: ios-http chunked/zip-bomb items removed with api-server.py |
| `tests/integration-smoke.md` | Modify | Three-tier behavioral checks |

---

## Task 1: DNS brain — three-tier template + list pipeline + policy tests

**Files:**
- Create: `tests/test_dns_split_policy.sh`
- Modify: `tests/test_smartdns_conf_policy.sh`
- Rewrite: `etc/smartdns.conf.template`
- Modify: `scripts/update-lists.sh`

**Interfaces:**
- Produces: rendered `smartdns.conf` shape consumed by smartdns at runtime; the list files `china-domains.txt`, `china_ip.conf`, `foreign-cidr.txt`, `proxy-domains.txt`, `bogus-nxdomain.conf`. Render placeholders: `__BIND_CERT__ __BIND_KEY__ __CACHE_SIZE__ __GATEWAY_IP__ __PROXY_DOMAINS_FILE__ __CHINA_DOMAINS_FILE__ __CHINA_IP_FILE__ __FOREIGN_CIDR_FILE__ __BOGUS_NXDOMAIN_FILE__` (note: `__CHINA_WHITELIST_FILE__` removed).

- [ ] **Step 1: Create the pure-grep policy test (it will fail)**

Create `tests/test_dns_split_policy.sh`:

```bash
#!/usr/bin/env bash
# Pure grep — runs on the dev box under Git Bash and in CI.
# Asserts the three-tier DNS split shape in the raw template + update-lists pipeline.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

T="$ROOT/etc/smartdns.conf.template"
U="$ROOT/scripts/update-lists.sh"

# --- groups: domestic + foreign, BOTH in default (no -exclude-default-group) ---
grep -Eq '^server 223\.5\.5\.5 .*-group domestic'   "$T" || fail "domestic group missing"
grep -Eq '^server-tls 8\.8\.8\.8 .*-group foreign'  "$T" || fail "foreign group missing"
grep -Eq 'exclude-default-group'                    "$T" && fail "groups must stay in default (no -exclude-default-group)"
# --- tier 1 blacklist: address -> gateway (no resolution) ---
grep -Eq '^domain-set -name blacklist .*__PROXY_DOMAINS_FILE__' "$T" || fail "blacklist domain-set missing"
grep -Eq '^address /domain-set:blacklist/__GATEWAY_IP__'        "$T" || fail "blacklist address->gateway missing"
# --- tier 2 whitelist: cnlist -> domestic only ---
grep -Eq '^domain-set -name cnlist .*__CHINA_DOMAINS_FILE__'    "$T" || fail "cnlist domain-set missing"
grep -Eq '^nameserver /domain-set:cnlist/domestic'             "$T" || fail "cnlist -> domestic nameserver missing"
# --- tier 3: prefer-CN content filter (no speed test) + foreign ip-alias ---
grep -Eq '^ip-set -name china_ip .*__CHINA_IP_FILE__'          "$T" || fail "china_ip ip-set missing"
grep -Eq '^ip-rules ip-set:china_ip -whitelist-ip'            "$T" || fail "china_ip prefer-CN whitelist rule missing"
grep -Eq '^ip-set -name foreign .*__FOREIGN_CIDR_FILE__'      "$T" || fail "foreign ip-set missing"
grep -Eq '^ip-rules ip-set:foreign -ip-alias __GATEWAY_IP__'  "$T" || fail "foreign ip-alias missing"
grep -Eq '^speed-check-mode none'                            "$T" || fail "speed-check-mode must be none (no latency test)"
grep -Eq 'response-mode +first-ping'                         "$T" && fail "response-mode first-ping must be removed"
# --- DoT only; no public plaintext :53; no stale xray ---
grep -Eq '^bind-tls .*:853'                                  "$T" || fail "DoT :853 bind missing"
grep -Eq '^bind(-tls)? (\[::\]|0\.0\.0\.0):53'               "$T" && fail "no public :53 bind allowed"
grep -Eq 'xray'                                              "$T" && fail "stale xray reference in template"
# --- update-lists generates the new lists; drops china-whitelist ---
grep -Eq 'china-domains\.txt'    "$U" || fail "update-lists must generate china-domains.txt"
grep -Eq 'china_ip\.conf'        "$U" || fail "update-lists must generate china_ip.conf"
grep -Eq 'CHINA_DOMAINS_FILE='   "$U" || fail "update-lists must pass CHINA_DOMAINS_FILE to render"
grep -Eq 'CHINA_IP_FILE='        "$U" || fail "update-lists must pass CHINA_IP_FILE to render"
grep -Eq 'CHINA_WHITELIST_FILE=' "$U" && fail "CHINA_WHITELIST_FILE removed (replaced by china_ip ip-set)"

[ $rc -eq 0 ] && echo "dns split policy: PASS"
exit $rc
```

- [ ] **Step 2: Run it — verify it FAILS**

Run: `bash tests/test_dns_split_policy.sh`
Expected: multiple `FAIL:` lines (template still old shape; update-lists still old).

- [ ] **Step 3: Rewrite `etc/smartdns.conf.template`**

Replace the entire file with:

```ini
# 5gpn smartdns — auto-rendered from smartdns.conf.template. DO NOT edit in place.
# Loop-avoidance: sing-box MUST resolve via 22.22.22.22 (or SINGBOX_RESOLVER), NEVER this smartdns.

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

# ---- No latency probing: tier-3 selection is by IP content (china_ip), not speed ----
speed-check-mode none
dualstack-ip-selection no

# ---- Two upstream groups; BOTH stay in the default group so tier-3 names query both ----
server 223.5.5.5 -group domestic
server 119.29.29.29 -group domestic
server-tls 8.8.8.8 -host-name dns.google -group foreign
server-tls 1.1.1.1 -group foreign

# Known ISP/GFW bogus-NXDOMAIN poison addresses -> SOA. Operator-editable.
conf-file __BOGUS_NXDOMAIN_FILE__

# ---- (Tier 1) Blacklist domains -> gateway IP, no resolution (force proxy) ----
domain-set -name blacklist -type list -file __PROXY_DOMAINS_FILE__
address /domain-set:blacklist/__GATEWAY_IP__

# ---- (Tier 2) Whitelist (mainland) domains -> domestic group only -> direct ----
domain-set -name cnlist -type list -file __CHINA_DOMAINS_FILE__
nameserver /domain-set:cnlist/domestic

# ---- (Tier 3) Neither list: default group queries both; prefer China IP if present ----
# whitelist-ip fires only when the merged answer contains a China IP -> then only
# China IPs are kept (foreign dropped). No China IP -> whole foreign answer passes.
ip-set -name china_ip -type list -file __CHINA_IP_FILE__
ip-rules ip-set:china_ip -whitelist-ip
# Any remaining foreign IP -> rewrite to the gateway IP -> sing-box -> proxy.
ip-set -name foreign -type list -file __FOREIGN_CIDR_FILE__
ip-rules ip-set:foreign -ip-alias __GATEWAY_IP__
```

- [ ] **Step 4: Update `scripts/update-lists.sh`**

(a) Replace the list-path block (current lines ~25-28) — drop `china_whitelist`, add `china_ipset` + `china_domains` + their source URL / guard knob. Change:
```bash
china="$SMARTDNS_DIR/china_ip_list.txt"
foreign="$SMARTDNS_DIR/foreign-cidr.txt"
china_whitelist="$SMARTDNS_DIR/china-whitelist.conf"
bogus="$SMARTDNS_DIR/bogus-nxdomain.conf"
mkdir -p "$SMARTDNS_DIR"
```
to:
```bash
china="$SMARTDNS_DIR/china_ip_list.txt"
foreign="$SMARTDNS_DIR/foreign-cidr.txt"
china_ipset="$SMARTDNS_DIR/china_ip.conf"
china_domains="$SMARTDNS_DIR/china-domains.txt"
bogus="$SMARTDNS_DIR/bogus-nxdomain.conf"
CHINA_DOMAINS_URL="${CHINA_DOMAINS_URL:-https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf}"
MIN_CN_DOMAINS="${MIN_CN_DOMAINS:-10000}"
mkdir -p "$SMARTDNS_DIR"
```

(b) Add the china-domains download+extract block right after the existing china_ip_list download block (after its closing `fi`, ~line 39):
```bash
# Mainland domain whitelist (felixonmars accelerated-domains). Lines look like:
#   server=/example.cn/114.114.114.114  -> extract the domain. Keep old on failure.
if [ "$DRY_RUN" != "1" ]; then
    tmpd="$china_domains.dl"
    if gum_spin "下载 china domains…" wget -qO "$tmpd" "$CHINA_DOMAINS_URL"; then
        tmpx="$china_domains.tmp"
        sed -n 's|^server=/\([^/]*\)/.*|\1|p' "$tmpd" | sort -u > "$tmpx"
        n=$(grep -c . "$tmpx" 2>/dev/null || echo 0)
        if [ "$n" -ge "$MIN_CN_DOMAINS" ]; then mv "$tmpx" "$china_domains"
        else warn "china-domains too small ($n < $MIN_CN_DOMAINS); keeping existing"; rm -f "$tmpx"; fi
        rm -f "$tmpd"
    else
        warn "china domains download failed; keeping existing $china_domains"
        rm -f "$tmpd"
    fi
fi
# domain-set -file must exist or smartdns refuses to start.
[ -f "$china_domains" ] || printf '# (regenerate via update-lists.sh)\n' > "$china_domains"
```

(c) Replace the china-whitelist generation block (current lines ~44-53) with the china_ip.conf + bogus stub block:
```bash
# China IP set for tier-3 prefer-CN (ip-rules ip-set:china_ip -whitelist-ip).
# Plain CIDR list from china_ip_list; keep old if china is unusable.
if grep -Eq '^[0-9]' "$china" 2>/dev/null; then
    tmpc="$china_ipset.tmp"
    grep -E '^[0-9]' "$china" > "$tmpc" && mv "$tmpc" "$china_ipset"
fi
# conf-file / *-file includes must always exist or smartdns refuses to start.
[ -f "$china_ipset" ] || printf '# (regenerate via update-lists.sh)\n' > "$china_ipset"
[ -f "$bogus" ]       || printf '# bogus-nxdomain poison IPs (operator-editable)\n' > "$bogus"
```

(d) Update the render invocation (current lines ~55-64): drop the `CHINA_WHITELIST_FILE=` line, add `CHINA_DOMAINS_FILE=` and `CHINA_IP_FILE=`:
```bash
python3 "$HERE/render_smartdns_conf.py" \
    "$ROOT/etc/smartdns.conf.template" "$SMARTDNS_DIR/smartdns.conf" \
    GATEWAY_IP="$GATEWAY_IP" \
    BIND_CERT="$SMARTDNS_DIR/cert/fullchain.pem" \
    BIND_KEY="$SMARTDNS_DIR/cert/privkey.pem" \
    PROXY_DOMAINS_FILE="$SMARTDNS_DIR/proxy-domains.txt" \
    FOREIGN_CIDR_FILE="$foreign" \
    CHINA_DOMAINS_FILE="$china_domains" \
    CHINA_IP_FILE="$china_ipset" \
    BOGUS_NXDOMAIN_FILE="$bogus" \
    CACHE_SIZE="$CACHE_SIZE"
```

- [ ] **Step 5: Run the pure-grep test — verify it PASSES**

Run: `bash tests/test_dns_split_policy.sh`
Expected: `dns split policy: PASS`.

- [ ] **Step 6: Update `tests/test_smartdns_conf_policy.sh` (rendered asserts + dry-run)**

Replace the whole file with:

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
    CHINA_DOMAINS_FILE=/etc/smartdns/china-domains.txt \
    CHINA_IP_FILE=/etc/smartdns/china_ip.conf \
    BOGUS_NXDOMAIN_FILE=/etc/smartdns/bogus-nxdomain.conf \
    CACHE_SIZE=20000 || fail "render failed"

grep -Eq '^bind-tls .*:853'                                 "$OUT" || fail "no DoT bind on 853"
grep -Eq '^bind-cert-file /etc/smartdns/cert/fullchain.pem' "$OUT" || fail "no bind-cert-file"
grep -Eq '^bind-cert-key-file /etc/smartdns/cert/privkey.pem' "$OUT" || fail "no bind-cert-key-file"
grep -Eq '^force-AAAA-SOA yes'                              "$OUT" || fail "AAAA not disabled"
grep -Eq '^speed-check-mode none'                           "$OUT" || fail "speed-check-mode not none"
grep -Eq 'response-mode +first-ping'                        "$OUT" && fail "first-ping speed test must be gone"
# tier 1
grep -Eq '^domain-set -name blacklist'                     "$OUT" || fail "no blacklist domain-set"
grep -Eq '^address /domain-set:blacklist/203\.0\.113\.7'   "$OUT" || fail "no blacklist address->gateway"
# tier 2
grep -Eq '^domain-set -name cnlist'                        "$OUT" || fail "no cnlist domain-set"
grep -Eq '^nameserver /domain-set:cnlist/domestic'         "$OUT" || fail "no cnlist->domestic nameserver"
# tier 3
grep -Eq '^ip-set -name china_ip'                          "$OUT" || fail "no china_ip ip-set"
grep -Eq '^ip-rules ip-set:china_ip -whitelist-ip'         "$OUT" || fail "no china_ip prefer-CN rule"
grep -Eq '^ip-set -name foreign'                           "$OUT" || fail "no foreign ip-set"
grep -Eq '^ip-rules ip-set:foreign -ip-alias 203\.0\.113\.7' "$OUT" || fail "no ip-alias foreign->gateway"
# groups
grep -Eq '^server 223\.5\.5\.5 .*-group domestic'          "$OUT" || fail "domestic group missing"
grep -Eq '^server-tls 8\.8\.8\.8 .*-group foreign'         "$OUT" || fail "foreign group missing"
# includes / safety
grep -Eq '^conf-file /etc/smartdns/bogus-nxdomain\.conf'   "$OUT" || fail "bogus-nxdomain include missing"
grep -Eq '^bind (\[::\]|0\.0\.0\.0):53'                    "$OUT" && fail "public plaintext :53 must not exist"
grep -Eq '__[A-Z_]+__'                                     "$OUT" && fail "unresolved placeholder remains"

# --- update-lists.sh dry-run end-to-end (no network, no restart) ---
TMPDIR2="$(mktemp -d)"; trap 'rm -f "$OUT"; rm -rf "$TMPDIR2"' EXIT
python3 - "$TMPDIR2/china_ip_list.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(150):
        f.write("%d.0.0.0/8\n" % (i % 223))
PY
printf '# empty\n' > "$TMPDIR2/proxy-domains.txt"
printf 'example.cn\nqq.com\n' > "$TMPDIR2/china-domains.txt"   # dry-run skips download; seed it
DRY_RUN=1 SMARTDNS_DIR="$TMPDIR2" GATEWAY_IP=203.0.113.7 \
    bash "$ROOT/scripts/update-lists.sh" >/dev/null 2>&1 || fail "update-lists dry-run failed"
[ -s "$TMPDIR2/foreign-cidr.txt" ] || fail "foreign-cidr.txt not generated"
[ -s "$TMPDIR2/china_ip.conf" ]    || fail "china_ip.conf not generated"
[ -f "$TMPDIR2/china-domains.txt" ] || fail "china-domains.txt missing"
grep -Eq '^ip-rules ip-set:china_ip -whitelist-ip' "$TMPDIR2/smartdns.conf" || fail "rendered conf missing china_ip rule"
grep -Eq '^ip-rules ip-set:foreign -ip-alias 203\.0\.113\.7' "$TMPDIR2/smartdns.conf" || fail "rendered conf missing ip-alias"

[ $rc -eq 0 ] && echo "smartdns conf policy: PASS"
exit $rc
```

- [ ] **Step 7: Run the rendered test where Python works**

On the dev box this test is subject to MSYS path mangling (the `/etc/...` args get rewritten); the authoritative run is CI/test-env. Quick local sanity via direct render (non-path tokens):
```bash
python scripts/render_smartdns_conf.py etc/smartdns.conf.template /tmp/o.conf \
  GATEWAY_IP=203.0.113.7 BIND_CERT=C BIND_KEY=K PROXY_DOMAINS_FILE=P \
  FOREIGN_CIDR_FILE=F CHINA_DOMAINS_FILE=D CHINA_IP_FILE=I BOGUS_NXDOMAIN_FILE=B CACHE_SIZE=20000 \
  && grep -E 'domain-set:blacklist|cnlist/domestic|china_ip -whitelist-ip|ip-alias 203|speed-check-mode none' /tmp/o.conf
```
Expected: the five lines print (no `__...__` left). Full test is asserted on test-env in Step 9.

- [ ] **Step 8: Validate render + smartdns load on test-env**

From PowerShell (renders the template + dry-run update-lists + `smartdns -v` and a config load check). Copy the repo to test-env first if not already there (`scp -r` or `git clone`), then:
```powershell
$s = @'
set -e
cd /root/5gpn 2>/dev/null || cd ~/5gpn
bash tests/test_smartdns_conf_policy.sh && echo SMARTDNS_CONF_OK
bash tests/test_dns_split_policy.sh && echo DNS_SPLIT_OK
command -v smartdns >/dev/null && smartdns -v || echo "smartdns not yet installed"
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))
& "$env:WINDIR\System32\OpenSSH\ssh.exe" -o BatchMode=yes test-env "echo $b64 | base64 -d | bash"
```
Expected: `smartdns conf policy: PASS`, `SMARTDNS_CONF_OK`, `dns split policy: PASS`, `DNS_SPLIT_OK`.

- [ ] **Step 9: Commit**

```bash
git add etc/smartdns.conf.template scripts/update-lists.sh tests/test_dns_split_policy.sh tests/test_smartdns_conf_policy.sh
git commit -m "feat(dns): three-tier deterministic split (blacklist/whitelist/prefer-CN) replacing first-ping"
```

---

## Task 2: Installer — install-time SNI resolver prompt (P0)

**Files:**
- Modify: `install.sh` (resolver prompt + persistence; `--help`)
- Test: `tests/test_install_policy.sh` (assert the prompt + persistence wiring)

**Interfaces:**
- Consumes: existing `ask_text` helper, `CONF_DIR=/etc/5gpn`, `RESOLV_FALLBACK=22.22.22.22`, and `install_singbox`'s existing patch `xr="${SINGBOX_RESOLVER:-$RESOLV_FALLBACK}"` (no change to install_singbox — we only set/export `SINGBOX_RESOLVER` before it runs).
- Produces: `/etc/5gpn/.singbox_resolver` (persisted value); exported `SINGBOX_RESOLVER`.

- [ ] **Step 1: Add resolver asserts to `tests/test_install_policy.sh` (they will fail)**

Append before the final `[ $rc -eq 0 ]` line (match the file's existing `$INSTALL`/`fail` variables — read the file header to confirm the var name; below assumes `INSTALL` points at `install.sh`):
```bash
# P0: install-time SNI resolver is prompted, persisted, and env-overridable.
grep -Eq '\.singbox_resolver'                  "$INSTALL" || fail "resolver not persisted to /etc/5gpn/.singbox_resolver"
grep -Eq 'SINGBOX_RESOLVER'                    "$INSTALL" || fail "SINGBOX_RESOLVER not wired in install flow"
grep -Eq 'ask_text .*(解析器|resolver)'         "$INSTALL" || fail "no resolver prompt"
```

- [ ] **Step 2: Run it — verify it FAILS**

Run: `bash tests/test_install_policy.sh`
Expected: `FAIL: no resolver prompt` (and the other two).

- [ ] **Step 3: Add the prompt + persistence in `full_install`**

In `install.sh`, locate `full_install()` and insert this block **before** the `install_singbox` call (and after `PUBLIC_IP`/`GATEWAY_IP` are resolved, so `CONF_DIR` exists — `install -d "$CONF_DIR"` already runs earlier in full_install). Use the same `ask_text "<prompt>" "<default>"` shape the file already uses (verify the helper's arg order against an existing call such as in `resolve_domain`/`setup_tgbot`):
```bash
    # P0: sing-box SNI re-resolver. Prompt only (no probe/warning); env wins; persist.
    SINGBOX_RESOLVER="${SINGBOX_RESOLVER:-$(cat "$CONF_DIR/.singbox_resolver" 2>/dev/null || true)}"
    SINGBOX_RESOLVER="${SINGBOX_RESOLVER:-$RESOLV_FALLBACK}"
    if [[ -t 0 ]]; then
        _r="$(ask_text 'sing-box SNI 解析器 (代理流量重解析; 留默认即占位 IP)' "$SINGBOX_RESOLVER" || true)"
        [[ -n "$_r" ]] && SINGBOX_RESOLVER="$_r"
    fi
    export SINGBOX_RESOLVER
    printf '%s\n' "$SINGBOX_RESOLVER" > "$CONF_DIR/.singbox_resolver"
    info "sing-box SNI resolver: ${SINGBOX_RESOLVER}"
```

- [ ] **Step 4: Surface `SINGBOX_RESOLVER` in `--help`**

In the usage/`--help` env-override list, confirm `SINGBOX_RESOLVER=` is present (it is per the env summary line); if the user-facing usage block omits it, add `SINGBOX_RESOLVER=<ipv4>` to the documented overrides. No placeholder — copy the existing override-line format exactly.

- [ ] **Step 5: Run the install tests — verify PASS + syntax**

Run: `bash tests/test_install_policy.sh && bash -n install.sh`
Expected: `install policy: PASS` and no syntax error.

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/test_install_policy.sh
git commit -m "feat(install): prompt for sing-box SNI resolver at install (default 22.22.22.22, env wins)"
```

---

## Task 3: Docs + cleanups (P2)

**Files:**
- Modify: `docs/DESIGN.md` (§4 model, §12 reversal)
- Modify: `README.md` (key-features bullet)
- Modify: `docs/HANDOFF.md` (§3 note)
- Modify: `install.sh` (`DOT_RATE`/`DOT_BURST` in `--help` + forward through `run_setup_firewall`)
- Modify: `tgbot.py` (wording)
- Modify: `tests/integration-smoke.md` (three-tier checks)
- Test: `tests/test_dns_split_policy.sh` (add a DOT_RATE-forward assert)

**Interfaces:** none (docs + a config-forward + wording). `run_setup_firewall` already exports `CLIENT_NET`/`IOS_PORT`; this adds `DOT_RATE`/`DOT_BURST` to that export so the documented `--help` knobs actually reach `setup-firewall.sh`.

- [ ] **Step 1: Add the DOT_RATE-forward assert (fails first)**

Append to `tests/test_dns_split_policy.sh` before the final `[ $rc -eq 0 ]`:
```bash
I="$ROOT/install.sh"
grep -Eq 'DOT_RATE'  "$I" || fail "install.sh must reference DOT_RATE (forward/help)"
grep -Eq 'DOT_BURST' "$I" || fail "install.sh must reference DOT_BURST (forward/help)"
```
Run: `bash tests/test_dns_split_policy.sh` → Expected: `FAIL: install.sh must reference DOT_RATE`.

- [ ] **Step 2: Forward `DOT_RATE`/`DOT_BURST` and document them**

In `install.sh` `run_setup_firewall()` (where it already exports `CLIENT_NET`/`IOS_PORT` before calling `setup-firewall.sh`), add them to the exported env, passing through any operator override:
```bash
    DOT_RATE="${DOT_RATE:-30}" DOT_BURST="${DOT_BURST:-60}" \
    CLIENT_NET="$CLIENT_NET" IOS_PORT="$IOS_PORT" \
        bash "${SCRIPT_DIR}/scripts/setup-firewall.sh"
```
(Match the existing invocation form; the point is `DOT_RATE`/`DOT_BURST` are now forwarded.) Add `DOT_RATE=` and `DOT_BURST=` to the `--help` env-override list.
Run: `bash tests/test_dns_split_policy.sh` → Expected: `dns split policy: PASS`.

- [ ] **Step 3: Update `docs/DESIGN.md` §4 (decision model → three-tier)**

Rewrite §4's model description from "no domain list, IP decides + first-ping" to the three tiers (blacklist→foreign-DNS via `address`→gateway; whitelist `china-domains.txt`→`nameserver .../domestic`→direct; neither→both groups + `ip-rules ip-set:china_ip -whitelist-ip` prefer-CN, no speed test, else foreign→`ip-alias`). Update the config skeleton to match `etc/smartdns.conf.template`. Update the residual-risk note: the "selects fastest IP" hard-edge is replaced by deterministic prefer-CN; the remaining hard-edge is "poisoned-to-look-Chinese foreign IPs on tier-3 domains → self-heal via blacklist."

- [ ] **Step 4: Add the §12 reversal decision entry**

Append to `docs/DESIGN.md` §12 (keep the existing "不维护 chinalist" entry; mirror the sniproxy→xray→sing-box reversal style):
```markdown
**决策追加 2026-06-30 — 分流模型:纯 IP 判定 → 三层确定性(反转「不维护 chinalist」):**
- **背景**:原 §4 称"含一个 CN IP 即直连"是硬保证,但代码只有 `response-mode first-ping` 延迟启发式,混合 CN/境外答案可能误判。
- **新模型**:① 黑名单(`proxy-domains.txt`)→ `address`→网关IP(不解析,必代理);② 白名单(`china-domains.txt`,felixonmars,自动更新)→ `nameserver /domain-set:cnlist/domestic`(只问境内 DNS)→ 直连;③ 其余 → 默认组(境内+境外)都查 + `ip-rules ip-set:china_ip -whitelist-ip`(含 CN 即只留 CN,内容过滤、**不测速**)+ `speed-check-mode none`;无 CN → 境外 → `ip-alias`→ 代理。
- **机制依据**:smartdns `whitelist-ip` 仅在答案含白名单 IP 时触发,对合并答案过滤,与应答先后无关 → 确定性(非 response-mode 竞速)。需 2024+ smartdns(空结果缓存修复)。
- **取舍**:多一张 ~8 万条自动更新域名表;移除 per-server `-whitelist-ip` 与 `china-whitelist.conf`(由全局 `ip-rules china_ip` 取代)。残留硬伤(伪 CN 污染)仍靠黑名单自愈。
- **保留历史**:旧"不维护 chinalist"决策不删;回滚靠 git。
```

- [ ] **Step 5: Update `README.md` + `docs/HANDOFF.md` + `tgbot.py` wording**

- `README.md` 关键特性: replace the "两级分流,无需维护大域名表 … 不需要 chinalist/gfwlist" bullet with the three-tier description (黑名单→代理 / 白名单→直连 / 其余→prefer-CN-不测速).
- `docs/HANDOFF.md` §3: append a parenthetical to the ios-http chunked/zip-bomb bullet: "(注:这些 guard 随 api-server.py 移除;现 ios-http.py 为 GET-only 静态响应,不读请求体)".
- `tgbot.py`: change user-facing strings "强制代理域名"/"强制代理" to "黑名单(强制代理)" where shown to the operator (menu labels / messages). Do not rename the `proxy-domains.txt` file or the add/del wiring. Run `grep -n 强制代理 tgbot.py` and update only display strings.

- [ ] **Step 6: Update `tests/integration-smoke.md` (three-tier checks)**

In the P1 DNS section, replace the "Mixed IP → prefer China (选国内)" check with the three deterministic checks:
- **Blacklist → gateway IP**: a domain in `proxy-domains.txt` returns the gateway IP (no resolution).
- **Whitelist → direct, domestic-only**: a domain in `china-domains.txt` returns a China IP; `tcpdump` shows the query went only to the domestic group (no DoT to 8.8.8.8/1.1.1.1).
- **Tier-3 mixed → prefer China (no speed test)**: a name resolving to both CN and foreign IPs returns the CN IP (direct); with the CN record removed it returns the foreign result rewritten to the gateway IP (proxy). Confirm no ping/probe traffic (`speed-check-mode none`).

- [ ] **Step 7: Run all dev-box tests + commit**

Run: `bash tests/test_dns_split_policy.sh && for t in tests/test_*_policy.sh; do bash "$t"; done`
Expected: all `PASS` (except `test_smartdns_conf_policy.sh`, which is the MSYS-path-mangled CI/test-env gate on Windows).
```bash
git add docs/DESIGN.md README.md docs/HANDOFF.md install.sh tgbot.py tests/integration-smoke.md tests/test_dns_split_policy.sh
git commit -m "docs: three-tier split in DESIGN/README/HANDOFF/smoke; forward DOT_RATE/DOT_BURST; tgbot wording"
```

---

## Task 4: End-to-end validation on test-env

**Files:** `install.sh` (only if smartdns build is too old — the release-first reorder below); `tests/integration-smoke.md` / spec (record results).

**Interfaces:** consumes everything from Tasks 1–3. This is the runtime gate the Windows dev box can't run.

- [ ] **Step 1: Install deps + run full `install.sh` on test-env**

```powershell
& "$env:WINDIR\System32\OpenSSH\ssh.exe" -o BatchMode=yes test-env "apt-get update -qq && apt-get install -y -qq nftables jq certbot qrencode unzip dnsutils >/dev/null 2>&1 && echo DEPS_OK"
```
Copy the repo (scp/clone), then `GATEWAY_IP=10.0.1.20 sudo bash install.sh` (NPN-style). Confirm `systemctl is-active smartdns sing-box`, `install.sh --status`, and that the install prompted for / used the SNI resolver (check `/etc/5gpn/.singbox_resolver` and the patched `/usr/local/etc/sing-box/config.json`).

- [ ] **Step 2: Verify smartdns build is 2024+**

```bash
smartdns -v   # or: dpkg -s smartdns | grep Version
```
If the version predates the 2024 empty-result cache fix (§6 of spec), reorder `install_smartdns()` in `install.sh` to **release-first**: try the pymumu `releases/latest` binary first, fall back to the distro package. Re-run install, re-check, and commit:
```bash
git add install.sh && git commit -m "fix(install): prefer pymumu release smartdns (2024+ cache fix) over distro build"
```
If the distro build is already 2024+, record the version and skip the reorder.

- [ ] **Step 3: Verify the three tiers behave (load-bearing)**

On test-env, with smartdns running and DoT on :853 (use `kdig @127.0.0.1 +tls` or query the rendered conf via a local smartdns on :5353):
- **Blacklist**: add a domain to `/etc/smartdns/proxy-domains.txt`, restart, query → returns `GATEWAY_IP`.
- **Whitelist**: pick a domain in `/etc/smartdns/china-domains.txt` (e.g. `qq.com`), query → China IP; `tcpdump -ni any port 53 or port 853` shows lookups only to 223.5.5.5/119.29.29.29, not 8.8.8.8/1.1.1.1.
- **Tier-3 prefer-CN**: craft a name with both CN and foreign A records (or use `address` injection / a controlled zone); query → CN IP. Remove the CN record → foreign IP rewritten to `GATEWAY_IP`. Confirm no ICMP/TCP-443 probe traffic during resolution (`speed-check-mode none`).
Record outcomes; if tier-3 does not prefer CN, re-check the two `ip-rules` order and that both groups are in the default group (spec §3/§9).

- [ ] **Step 4: Verify list update pipeline live**

```bash
SMARTDNS_DIR=/etc/smartdns GATEWAY_IP=10.0.1.20 bash /root/5gpn/scripts/update-lists.sh
wc -l /etc/smartdns/china-domains.txt /etc/smartdns/china_ip.conf /etc/smartdns/foreign-cidr.txt
```
Expected: china-domains ≥ 10000 lines, china_ip.conf non-empty, foreign-cidr non-empty; smartdns restarts cleanly. Then simulate a download failure (bad `CHINA_DOMAINS_URL`) → old `china-domains.txt` preserved (not blanked).

- [ ] **Step 5: Record results**

Append observed outcomes (service active, three tiers OK, resolver path OK, lists OK, smartdns version, any reorder) into `tests/integration-smoke.md` results section and the spec §9. Commit:
```bash
git add -A
git commit -m "test: validate three-tier DNS split + resolver prompt end-to-end on test-env"
```

---

## Self-Review

**1. Spec coverage:**
- §2 decisions: three-tier (T1), no-speed-test (T1), blacklist=address (T1), whitelist source felixonmars (T1 update-lists), §12 reversal (T3), smartdns 2024+ (T4), P0 resolver prompt (T2) — all mapped.
- §3 config → T1 Step 3. §4 lists → T1 Step 4 + gen_foreign_cidr unchanged. §5 constraints (anti-loop untouched, determinism, no-blank-on-failure, residual) → T1 (template/guards) + DESIGN note T3 Step 3/4. §6 mechanism → encoded in template + asserted T1/T4. §7 install P0 + version + tgbot → T2 + T4 + T3 Step 5. §8 tests/docs → T1 (tests) + T3 (docs). §9 risks/Linux gates → T4. **No gaps.**
**2. Placeholder scan:** template, both tests, and all update-lists blocks are shown in full. install.sh edits show the exact inserted code and reference existing helpers (`ask_text`, `run_setup_firewall` export) the subagent confirms by reading the file — no TBD/TODO. Doc steps name the exact section + the substance to write (§12 entry shown verbatim).
**3. Type/name consistency:** placeholders `__CHINA_DOMAINS_FILE__`/`__CHINA_IP_FILE__` consistent across template (T1.3), update-lists render args (T1.4d), and both tests (T1.1/T1.6). Vars `china_ipset`→`china_ip.conf`, `china_domains`→`china-domains.txt` consistent in update-lists. `SINGBOX_RESOLVER`/`.singbox_resolver`/`RESOLV_FALLBACK` consistent across T2. Service/group names `domestic`/`foreign`, domain-sets `blacklist`/`cnlist`, ip-sets `china_ip`/`foreign` consistent template↔tests. **Consistent.**
