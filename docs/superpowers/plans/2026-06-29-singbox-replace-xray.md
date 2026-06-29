# sing-box replaces xray — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace xray-core with sing-box as the transparent SNI/QUIC forwarder, preserving the exact end-to-end behavior (DoT-only, direct egress, QUIC proxied, anti-loop).

**Architecture:** smartdns rewrites proxied traffic's destination IP to the gateway, so it arrives at a plain `direct` sing-box inbound on :443 (tcp+udp) / :80 (tcp). A route `sniff` action extracts the SNI/Host, `resolve` (ipv4_only) re-resolves it via a hardcoded external resolver, and a `direct` outbound egresses straight out the default route. Reject rules drop sniff-failed / self-directed traffic to prevent loops. No tproxy/fwmark/tunnels.

**Tech Stack:** sing-box 1.13.x (Go, prebuilt binary), nftables, systemd, bash (`install.sh`), Python stdlib (`tgbot.py`). Tests are pure-grep policy scripts run under Git Bash; runtime gates run on **test-env** (Debian 13, see CLAUDE.md).

**Spec:** [docs/superpowers/specs/2026-06-29-singbox-replace-xray-design.md](../specs/2026-06-29-singbox-replace-xray-design.md)

## Global Constraints

Every task's requirements implicitly include these (verbatim from the spec):

- **Version pin:** sing-box `1.13.14`, env-overridable via `SINGBOX_VERSION`. Config written to 1.12+ syntax (typed DNS server, route-action `sniff`/`resolve`).
- **Integrity:** **no mandatory sha256**. Optional opt-in via `SINGBOX_SHA256` (set ⇒ verify + fatal-on-mismatch; unset ⇒ warn UNVERIFIED + proceed).
- **Transport inbound:** `direct` inbound only. **Never** add tproxy / redirect / tun / fwmark / `ip rule` / `table 100` (preserves the no-exit-layer rule).
- **Anti-loop (load-bearing):** exactly one external DNS server `22.22.22.22` (overridable via `SINGBOX_RESOLVER`), referenced by `dns.final` + `route.default_domain_resolver` + the `resolve` action; **never** the local smartdns. Plus `resolve`-before-reject, `ip_is_private` reject, and a self-IP `ip_cidr` reject.
- **IPv4-only:** dns `strategy:"ipv4_only"` + resolve `strategy:"ipv4_only"`; systemd `RestrictAddressFamilies=AF_INET AF_UNIX`.
- **`network` field rule:** omit it on the :443 inbound (⇒ binds tcp+udp); set `"network":"tcp"` on :80. The literal `"tcp,udp"` is REJECTED by sing-box (`unknown network`).
- **Migration style:** replace xray outright — delete `etc/xray/config.json` and `etc/systemd/xray.service`; installer removes the old `xray.service` + `/usr/local/etc/xray`.
- **Platform:** grep policy tests run under Git Bash on Windows; `sing-box check`, runtime, QUIC, sandbox, full `install.sh` are test-env (Linux) gates.
- **test-env SSH (from CLAUDE.md):** Windows native ssh via PowerShell — `& "$env:WINDIR\System32\OpenSSH\ssh.exe" test-env '<cmd>'`. For multi-line, base64-encode locally and `| base64 -d | bash` remotely (avoids the PS5.1 BOM + paren pitfalls).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `etc/sing-box/config.json` | Create | Data-plane config (check-valid, sentinel defaults) |
| `etc/xray/config.json` | Delete | (replaced) |
| `etc/systemd/sing-box.service` | Create | Service unit + sandbox |
| `etc/systemd/xray.service` | Delete | (replaced) |
| `scripts/setup-firewall.sh` | Modify | Install sing-box.service unit; migrate off xray; comments |
| `install.sh` | Modify | `install_singbox`, resolver+self-IP patch, renewal hooks, service lists, env summary, remove old xray |
| `tgbot.py` | Modify | `SERVICES` + restart menu |
| `tests/test_proxy_policy.sh` | Modify | sing-box config/firewall/systemd asserts |
| `tests/test_hardening_policy.sh` | Modify | unit path → sing-box.service |
| `tests/test_install_policy.sh` | Modify | renewal hook stop/start sing-box |
| `tests/integration-smoke.md` | Modify | narrative xray → sing-box |
| `CLAUDE.md` | Modify | no-exit-layer reword; sha256 optional for sing-box |
| `docs/DESIGN.md` | Modify | §6/§8/§12 decision reversal |
| `README.md` | Modify | xray → sing-box references |

---

## Task 1: Data plane — sing-box config, systemd unit, firewall wiring

**Files:**
- Create: `etc/sing-box/config.json`
- Delete: `etc/xray/config.json`
- Create: `etc/systemd/sing-box.service`
- Delete: `etc/systemd/xray.service`
- Modify: `scripts/setup-firewall.sh:60-65`, comment lines `2-4,46`
- Test: `tests/test_proxy_policy.sh` (full rewrite of paths + sing-box asserts), `tests/test_hardening_policy.sh:7` (unit path)

**Interfaces:**
- Produces: `/usr/local/etc/sing-box/config.json` shape (consumed by install.sh Task 2 patch + the unit's `-c` path); `etc/systemd/sing-box.service` with `ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json`.

- [ ] **Step 1: Rewrite `tests/test_proxy_policy.sh` to assert the sing-box shape**

Replace the file contents with:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

SB="$ROOT/etc/sing-box/config.json"
FW="$ROOT/scripts/setup-firewall.sh"
SS="$ROOT/etc/systemd/sing-box.service"

# --- sing-box: loop-avoidance + shape ---
grep -Eq '"22\.22\.22\.22"'                         "$SB" || fail "sing-box resolver not 22.22.22.22"
grep -Eq '127\.0\.0\.1:853|:5353|"::1"([^/]|$)'     "$SB" && fail "sing-box dns must not point at local smartdns"
grep -Eq '"type":[[:space:]]*"direct"'              "$SB" || fail "sing-box not using direct inbound/outbound"
grep -Eq '"listen_port":[[:space:]]*443'            "$SB" || fail "sing-box missing 443 inbound"
grep -Eq '"listen_port":[[:space:]]*80'             "$SB" || fail "sing-box missing 80 inbound"
grep -Eq '"network":[[:space:]]*"tcp"'              "$SB" || fail "sing-box :80 must be tcp-only"
grep -Eq '"action":[[:space:]]*"sniff"'             "$SB" || fail "sing-box missing sniff action"
grep -Eq '"quic"'                                   "$SB" || fail "sing-box must sniff quic (UDP 443/HTTP3)"
grep -Eq '"tls"'                                    "$SB" || fail "sing-box must sniff tls"
grep -Eq '"http"'                                   "$SB" || fail "sing-box must sniff http (:80)"
grep -Eq '"action":[[:space:]]*"resolve"'           "$SB" || fail "sing-box missing resolve action (ForceIPv4 egress)"
grep -Eq '"strategy":[[:space:]]*"ipv4_only"'       "$SB" || fail "sing-box not IPv4-only"
grep -Eq '"method":[[:space:]]*"drop"'              "$SB" || fail "sing-box missing reject drop (anti-loop sink)"
grep -Eq '"ip_is_private":[[:space:]]*true'         "$SB" || fail "sing-box missing ip_is_private reject (sniff-fail/private sink)"
grep -Eq '"ip_cidr"'                                "$SB" || fail "sing-box missing self-IP reject rule (sniff-fail-to-gateway anti-loop)"

# --- firewall: DoT-only inbound; exit/mark layer GONE; QUIC proxied (UNCHANGED) ---
grep -Eq 'tcp_ports="22, 853"'                   "$FW" || fail "inbound not limited to 22/853"
grep -Eq 'udp dport 53 accept'                   "$FW" && fail "public plaintext :53 must not be opened"
grep -Eq 'pgw_exit|fwmark|table 100|skuid'       "$FW" && fail "exit/mark layer must be removed (direct egress only)"
grep -Eq 'udp dport 443 reject'                  "$FW" && fail "UDP 443 must NOT be rejected (QUIC now proxied)"
grep -Fq 'ip saddr ${CLIENT_NET} udp dport 443 accept' "$FW" || fail "UDP 443 (QUIC) from CLIENT_NET must be accepted"
grep -Fq 'CLIENT_NET="${CLIENT_NET:-172.22.0.0/16}"' "$FW" || fail "CLIENT_NET default is not the NPN 172.22.0.0/16"
grep -Eq 'quic-proxy'                            "$FW" && fail "no separate quic-proxy (sing-box handles QUIC inline)"

# --- systemd: sing-box config path ---
grep -Eq -- '-c /usr/local/etc/sing-box/config.json' "$SS" || fail "sing-box.service missing config path"

[ $rc -eq 0 ] && echo "proxy policy: PASS"
exit $rc
```

- [ ] **Step 2: Update `tests/test_hardening_policy.sh:7` to point at the new unit**

Change line 7 from:
```bash
XRAY_SVC="$ROOT/etc/systemd/xray.service"
```
to:
```bash
SB_SVC="$ROOT/etc/systemd/sing-box.service"
```
Then update lines 11–13 references `"$XRAY_SVC"` → `"$SB_SVC"` and their fail messages `xray.service:` → `sing-box.service:`.

- [ ] **Step 3: Run both tests — verify they FAIL**

Run: `bash tests/test_proxy_policy.sh; bash tests/test_hardening_policy.sh`
Expected: FAIL (e.g. `FAIL: sing-box resolver not 22.22.22.22` — the file `etc/sing-box/config.json` doesn't exist yet; `sing-box.service` missing).

- [ ] **Step 4: Create `etc/sing-box/config.json`**

```json
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [ { "type": "udp", "tag": "ext", "server": "22.22.22.22" } ],
    "final": "ext",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    { "type": "direct", "tag": "in443", "listen": "0.0.0.0", "listen_port": 443 },
    { "type": "direct", "tag": "in80",  "listen": "0.0.0.0", "listen_port": 80, "network": "tcp" }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "default_domain_resolver": { "server": "ext" },
    "rules": [
      { "action": "sniff",   "sniffer": ["tls", "quic", "http"], "timeout": "300ms" },
      { "action": "resolve", "strategy": "ipv4_only", "server": "ext" },
      { "ip_is_private": true, "action": "reject", "method": "drop" },
      { "ip_cidr": ["127.0.0.2/32"], "action": "reject", "method": "drop" }
    ],
    "final": "direct"
  }
}
```

- [ ] **Step 5: Create `etc/systemd/sing-box.service`**

```ini
[Unit]
Description=5gpn sing-box (SNI/QUIC transparent proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
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
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_UNIX
ReadOnlyPaths=/usr/local/etc/sing-box

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 6: Delete the xray data-plane files**

```bash
git rm etc/xray/config.json etc/systemd/xray.service
```

- [ ] **Step 7: Update `scripts/setup-firewall.sh` to install the sing-box unit**

Change lines 60–65 from:
```bash
# Migrate off sniproxy if a previous install left it behind.
systemctl disable --now sniproxy 2>/dev/null || true
rm -f /etc/systemd/system/sniproxy.service
install -m 0644 "${ROOT}/etc/systemd/xray.service"   /etc/systemd/system/xray.service
systemctl daemon-reload
ok "firewall + xray unit installed (direct egress; QUIC/UDP 443 proxied)"
```
to:
```bash
# Migrate off sniproxy / xray if a previous install left them behind.
systemctl disable --now sniproxy 2>/dev/null || true
rm -f /etc/systemd/system/sniproxy.service
systemctl disable --now xray 2>/dev/null || true
rm -f /etc/systemd/system/xray.service
install -m 0644 "${ROOT}/etc/systemd/sing-box.service" /etc/systemd/system/sing-box.service
systemctl daemon-reload
ok "firewall + sing-box unit installed (direct egress; QUIC/UDP 443 proxied)"
```
Also update the header comment (lines 3–4) and line 46 comment: replace `xray` with `sing-box`.

- [ ] **Step 8: Run the grep tests — verify they PASS**

Run: `bash tests/test_proxy_policy.sh && bash tests/test_hardening_policy.sh`
Expected: `proxy policy: PASS` and `hardening policy: PASS`.

- [ ] **Step 9: Validate the config on test-env (`sing-box check` + boot)**

From PowerShell (downloads sing-box if not already at `/tmp` on the box, copies the repo config, checks + boots it):

```powershell
$cfg = Get-Content -Raw d:\Code\new-5gpn\etc\sing-box\config.json
$b64cfg = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cfg))
$s = @"
set -u
VER=1.13.14; BIN=/tmp/sing-box-`$VER-linux-amd64/sing-box
[ -x "`$BIN" ] || { curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v`$VER/sing-box-`$VER-linux-amd64.tar.gz -o /tmp/sb.tgz && tar -xzf /tmp/sb.tgz -C /tmp; }
echo $b64cfg | base64 -d > /tmp/repo-config.json
"`$BIN" check -c /tmp/repo-config.json && echo CHECK_OK
"`$BIN" run -c /tmp/repo-config.json > /tmp/sb.log 2>&1 & P=`$!; sleep 2
ss -tlnp 2>/dev/null | grep -E ':(80|443)\b'; ss -ulnp 2>/dev/null | grep -E ':(443)\b'
cat /tmp/sb.log; kill `$P 2>/dev/null
"@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))
& "$env:WINDIR\System32\OpenSSH\ssh.exe" -o BatchMode=yes test-env "echo $b64 | base64 -d | bash"
```
Expected: `CHECK_OK`, tcp listeners on :80/:443, udp listener on :443, empty log.

- [ ] **Step 10: Commit**

```bash
git add etc/sing-box/config.json etc/systemd/sing-box.service scripts/setup-firewall.sh tests/test_proxy_policy.sh tests/test_hardening_policy.sh
git commit -m "feat(proxy): sing-box data plane (config + unit + firewall) replacing xray"
```

---

## Task 2: Installer — install_singbox, config patch, renewal hooks, service lists

**Files:**
- Modify: `install.sh` (vars `28-29`; header comments `5,8,10`; `install_xray`→`install_singbox` `261-289`; config install + patch `316-331`; renewal hooks `446-461`; `start_services` `631`; `show_status` `755`; `full_install` `801`; env summary `849-850`)
- Test: `tests/test_install_policy.sh:17,20`

**Interfaces:**
- Consumes: `etc/sing-box/config.json` (Task 1), the `sing-box.service` unit (installed by `setup-firewall.sh`, Task 1).
- Produces: `/usr/local/bin/sing-box`, patched `/usr/local/etc/sing-box/config.json`.

- [ ] **Step 1: Update renewal-hook asserts in `tests/test_install_policy.sh`**

Change line 17 `systemctl stop xray` → `systemctl stop sing-box` and its message; change line 20 `systemctl start xray` → `systemctl start sing-box` and its message.

- [ ] **Step 2: Run the test — verify it FAILS**

Run: `bash tests/test_install_policy.sh`
Expected: FAIL `renewal must stop sing-box to free :80 for --standalone` (install.sh still says xray).

- [ ] **Step 3: Rename the binary/dir vars** (`install.sh:28-29`)

From:
```bash
XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
```
to:
```bash
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/usr/local/etc/sing-box"
```

- [ ] **Step 4: Replace `install_xray()` with `install_singbox()`** (`install.sh:261-289`)

```bash
# ----------------------------------------------------------------------------
# sing-box (prebuilt binary)
# ----------------------------------------------------------------------------
install_singbox() {
    if [[ -x "$SINGBOX_BIN" ]]; then info "sing-box already installed."; return 0; fi
    local ver="${SINGBOX_VERSION:-1.13.14}"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-amd64.tar.gz"
    info "Downloading sing-box ${ver} (prebuilt binary; no Go toolchain)..."
    mkdir -p "$BUILD_DIR"
    local tgz="$BUILD_DIR/sing-box-${ver}.tar.gz"
    gum_spin "Downloading sing-box ${ver}…" curl -fsSL "$url" -o "$tgz" || { err "sing-box download failed ($url)"; exit 1; }
    # Integrity: opt-in only. sing-box ships no .dgst sidecar; set SINGBOX_SHA256 to verify.
    local exp="${SINGBOX_SHA256:-}"
    if [[ -n "$exp" ]]; then
        local got; got="$(sha256sum "$tgz" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { err "sing-box sha256 mismatch (want $exp got $got)"; exit 1; }
        ok "sing-box archive sha256 verified."
    else
        warn "sing-box sha256 UNVERIFIED (set SINGBOX_SHA256 to pin)."
    fi
    tar -xzf "$tgz" -C "$BUILD_DIR" "sing-box-${ver}-linux-amd64/sing-box"
    install -m 0755 "$BUILD_DIR/sing-box-${ver}-linux-amd64/sing-box" "$SINGBOX_BIN"
    [[ -x "$SINGBOX_BIN" ]] || { err "sing-box install failed."; exit 1; }
    ok "sing-box installed to $SINGBOX_BIN ($ver)."
}
```

- [ ] **Step 5: Replace the xray config install + patch block** (`install.sh:316-331`)

```bash
    # sing-box config (resolver hardcoded to 22.22.22.22 for loop-avoidance, IPv4-only, direct).
    install -d -m 0755 "$SINGBOX_DIR"
    install -m 0644 "${SCRIPT_DIR}/etc/sing-box/config.json" "$SINGBOX_DIR/config.json"
    # SNI re-resolver: default 22.22.22.22 (loop-avoidance requires only that it is NOT the
    # local smartdns). Operators on a different network can point it at a reachable clean
    # IPv4 resolver via SINGBOX_RESOLVER. We patch only the installed copy.
    local xr="${SINGBOX_RESOLVER:-$RESOLV_FALLBACK}"
    if [[ "$xr" != "$RESOLV_FALLBACK" ]]; then
        if [[ "$xr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            sed -i "s/${RESOLV_FALLBACK//./\\.}/${xr}/g" "$SINGBOX_DIR/config.json"
            info "sing-box SNI resolver overridden -> ${xr}"
        else
            warn "SINGBOX_RESOLVER='${xr}' is not an IPv4; keeping default ${RESOLV_FALLBACK}."
        fi
    fi
    # Anti-loop sniff-fail sink: sing-box 1.13 keeps the original dest (the gateway's own IP)
    # when sniff fails, so replace the committed sentinel 127.0.0.2/32 with the gateway's
    # client-facing + public IPs to drop self-directed traffic instead of re-dialing it.
    local self="\"${PUBLIC_IP}/32\""
    local gwip="${GATEWAY_IP:-$PUBLIC_IP}"
    [[ -n "$gwip" && "$gwip" != "$PUBLIC_IP" ]] && self="${self}, \"${gwip}/32\""
    sed -i "s#\"127\\.0\\.0\\.2/32\"#${self}#" "$SINGBOX_DIR/config.json"
```

- [ ] **Step 6: Update renewal hooks** (`install.sh:448,450,454,456,461`)

In the pre-hook heredoc, line 448 comment `stop xray` → `stop sing-box`; line 450 `systemctl stop xray` → `systemctl stop sing-box`. In the post-hook, line 454 comment `bring xray back` → `bring sing-box back`; line 456 `systemctl start xray` → `systemctl start sing-box`. Line 461 `cycle xray` → `cycle sing-box`.

- [ ] **Step 7: Update service lists** — `start_services` (`install.sh:631`) and `show_status` (`install.sh:755`)

Line 631: `for svc in smartdns xray nftables; do` → `for svc in smartdns sing-box nftables; do`
Line 755: `for svc in smartdns xray; do` → `for svc in smartdns sing-box; do`

- [ ] **Step 8: Update `full_install` to install sing-box + remove old xray** (`install.sh:801`)

Replace line 801 `install_xray` with:
```bash
    # Drop the replaced xray proxy if a previous install left it behind.
    systemctl disable --now xray 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service; rm -rf /usr/local/etc/xray
    install_singbox
```
Also update line 812 comment `# DoT-only nft + xray unit` → `# DoT-only nft + sing-box unit`.

- [ ] **Step 9: Update header comments + env summary**

`install.sh` lines 5/8/10 comments: `xray` → `sing-box`; line 10 already says "no sing-box" in the exit-layer sense — reword to: `# There is NO exit layer: no WireGuard, no multi-exit, no` (drop "sing-box" since it's now the forwarder). Line 849-850 env summary: `XRAY_RESOLVER=22.22.22.22,` → `SINGBOX_RESOLVER=22.22.22.22, SINGBOX_VERSION=1.13.14,`.

- [ ] **Step 10: Run the install test — verify it PASSES; sanity-check no stray xray refs**

Run: `bash tests/test_install_policy.sh && bash tests/test_hardening_policy.sh`
Expected: `install policy: PASS`, `hardening policy: PASS`.
Run: `grep -nE '\bxray\b|XRAY' install.sh` — Expected: only the intentional migrate-off-xray cleanup lines (Step 8) remain; no `install_xray`, `XRAY_BIN`, `XRAY_DIR`, `XRAY_RESOLVER`.

- [ ] **Step 11: Commit**

```bash
git add install.sh tests/test_install_policy.sh
git commit -m "feat(install): install_singbox + config patch + renewal/service wiring; drop xray"
```

---

## Task 3: Control plane — tgbot.py services

**Files:**
- Modify: `tgbot.py:55`, `tgbot.py:453-454`

**Interfaces:**
- Consumes: the `sing-box` systemd service name (Task 1/2). `op_restart`/`op_logs` validate against `SERVICES`.

- [ ] **Step 1: Update `SERVICES`** (`tgbot.py:55`)

From `SERVICES = ["smartdns", "xray"]` to:
```python
SERVICES = ["smartdns", "sing-box"]
```

- [ ] **Step 2: Update the restart menu button** (`tgbot.py:453-454`)

Change the `xray` button:
```python
        [{"text": "smartdns", "callback_data": "restart:smartdns"},
         {"text": "sing-box", "callback_data": "restart:sing-box"}],
```

- [ ] **Step 3: Verify no other xray references remain in tgbot.py**

Run: `grep -nE 'xray' tgbot.py`
Expected: only the architecture-reminder comment at line 8 (update it: `smartdns -> sing-box -> DIRECT egress`). No `restart:xray` / `"xray"` service tokens.

- [ ] **Step 4: Byte-compile sanity (syntax check) on test-env**

```powershell
$py = Get-Content -Raw d:\Code\new-5gpn\tgbot.py
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($py))
& "$env:WINDIR\System32\OpenSSH\ssh.exe" -o BatchMode=yes test-env "echo $b64 | base64 -d > /tmp/tgbot.py && python3 -m py_compile /tmp/tgbot.py && echo PY_OK"
```
Expected: `PY_OK`. (If python3 absent on test-env, run the repo's `tests/test_tgbot.py` in CI instead.)

- [ ] **Step 5: Commit**

```bash
git add tgbot.py
git commit -m "feat(tgbot): manage sing-box service instead of xray"
```

---

## Task 4: Docs + policy — CLAUDE.md, DESIGN.md, README, integration-smoke

**Files:**
- Modify: `CLAUDE.md:26,28`
- Modify: `docs/DESIGN.md` (§6/§8/§12 — the data-flow / egress / decisions sections)
- Modify: `README.md` (xray references)
- Modify: `tests/integration-smoke.md` (narrative)
- Modify: `scripts/gen-ios-profile.sh` (any xray comment, if present)

**Interfaces:** none (documentation). This task reverses the standing conventions the spec §1 calls out.

- [ ] **Step 1: Reword the "No exit layer" convention** (`CLAUDE.md:26`)

From:
```markdown
- **No exit layer.** Direct egress only — no sing-box / WireGuard / multi-exit / fwmark / `ip rule` / `table 100`. Don't add any of these.
```
to:
```markdown
- **No exit layer.** Direct egress only — no WireGuard / multi-exit / fwmark / `ip rule` / `table 100`. Don't add any of these. sing-box IS the transparent SNI/QUIC forwarder (data plane) via a `direct` inbound — it does NOT do tproxy/tun/fwmark, so it stays within this rule.
```

- [ ] **Step 2: Relax the sha256 convention for sing-box** (`CLAUDE.md:28`)

From:
```markdown
- **Prebuilt binaries + sha256 verify** for third-party tools (xray, gum) — no source builds / Go toolchain on the box.
```
to:
```markdown
- **Prebuilt binaries** for third-party tools (sing-box, gum) — no source builds / Go toolchain on the box. sha256 verify is mandatory for gum (`checksums.txt`); for **sing-box it is opt-in** (`SINGBOX_SHA256`, no `.dgst` sidecar upstream).
```

- [ ] **Step 3: Update `docs/DESIGN.md` §6/§8/§12**

Read the current §6 (data flow), §8 (egress), §12 (decisions) sections. Update the data-plane references from xray `dokodemo-door` to sing-box `direct` inbound + route `sniff`/`resolve`; in §12 add a decision-reversal entry (2026-06-29): xray → sing-box per user directive, recording the new config shape, the `resolve`-before-reject + self-IP `ip_cidr` anti-loop (replacing xray's placeholder-127.0.0.1 trick), version pin 1.13.14, and the opt-in-only sha256. Keep the historical xray entry; append the reversal (mirror how §12 already records the sniproxy→xray reversal).

- [ ] **Step 4: Update `README.md`**

Run `grep -n xray README.md` and replace each xray reference with the sing-box equivalent (prebuilt sing-box binary; `sing-box` dokodemo-equivalent `direct` inbound sniffs tls/quic/http and direct-egresses; service name `sing-box`). Keep the architecture diagram semantics identical.

- [ ] **Step 5: Update `tests/integration-smoke.md` + `scripts/gen-ios-profile.sh`**

In `tests/integration-smoke.md`, replace xray install/run/verify narrative (lines ~66-107) with sing-box equivalents (`install_singbox`, `cp etc/sing-box/config.json /usr/local/etc/sing-box/config.json`, `systemctl enable --now sing-box`, "sing-box sniff quic"). In `scripts/gen-ios-profile.sh`, run `grep -n xray` and update any comment to `sing-box`.

- [ ] **Step 6: Whole-repo sweep for stray live references**

Run: `grep -rnE '\bxray\b|XRAY' --include='*.sh' --include='*.py' --include='*.md' --include='*.json' . | grep -v 'docs/superpowers/.*2026-06-28' | grep -v '2026-06-29-singbox-replace-xray'`
Expected: only intentional "migrate off xray" cleanup lines (install.sh Task 2 Step 8, setup-firewall Task 1 Step 7) and the DESIGN.md §12 historical entry. The dated 2026-06-28 spec/plan and the 2026-06-29 docs are historical records — leave them.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/DESIGN.md README.md tests/integration-smoke.md scripts/gen-ios-profile.sh
git commit -m "docs: xray -> sing-box; reverse no-sing-box + sha256 conventions"
```

---

## Task 5: End-to-end validation on test-env

**Files:** none (validation only). Produces the evidence for spec §9.

**Interfaces:** Consumes everything from Tasks 1–4. This is the runtime gate the Windows dev box can't run.

- [ ] **Step 1: Install dependencies + run full `install.sh` on test-env**

test-env lacks `nft`, `jq`, `certbot`. From PowerShell:
```powershell
& "$env:WINDIR\System32\OpenSSH\ssh.exe" -o BatchMode=yes test-env "apt-get update -qq && apt-get install -y -qq nftables jq certbot qrencode unzip >/dev/null 2>&1 && echo DEPS_OK"
```
Expected: `DEPS_OK`. Then copy the repo to test-env (e.g. `git clone` or rsync) and run `sudo bash install.sh` with a test `DOMAIN`/`PUBLIC_IP` (or `GATEWAY_IP=10.0.1.20` for an NPN-style run). Confirm `systemctl is-active sing-box` ⇒ `active` and `install.sh --status` shows sing-box.

- [ ] **Step 2: Verify the sniff-and-forward behavior (load-bearing)**

With sing-box running, simulate a client whose DNS rewrote a foreign domain to the gateway: connect to `gateway:443` sending a real SNI and confirm sing-box egresses to that domain (not the gateway IP). E.g. on test-env:
```bash
curl -v --resolve example.com:443:127.0.0.1 https://example.com/ --max-time 10
```
Expected: TLS handshake completes via sing-box (sniff tls → resolve → direct). Check `journalctl -u sing-box -n 20` shows no loop/error.

- [ ] **Step 3: Verify QUIC/HTTP3 path**

```bash
curl -v --http3-only --resolve example.com:443:127.0.0.1 https://example.com/ --max-time 10 || echo "QUIC_PATH_CHECKED"
```
Expected: UDP 443 reaches sing-box, `sniff quic` extracts SNI, direct-egress. Confirm via `journalctl -u sing-box`.

- [ ] **Step 4: Verify the systemd sandbox is sufficient**

```bash
systemctl show sing-box -p RestrictAddressFamilies; systemctl status sing-box --no-pager | head -5
```
Expected: service `active (running)` under `RestrictAddressFamilies=AF_INET AF_UNIX`. If it failed to start with a socket/AF error, add `AF_NETLINK` to `etc/systemd/sing-box.service`, reinstall, re-test, and commit that fix.

- [ ] **Step 5: Verify cert renewal still frees :80**

```bash
certbot renew --dry-run 2>&1 | tail -20
```
Expected: dry-run succeeds; the pre-hook stopped sing-box (freeing :80), the post-hook restarted it. Confirm `systemctl is-active sing-box` ⇒ `active` afterward.

- [ ] **Step 6: Record results in the spec §6 / integration-smoke**

Append the observed outcomes (active service, sniff-forward OK, QUIC OK, sandbox OK, renewal OK; or the `AF_NETLINK` fix if needed) as checked items. Commit any doc/config fixes surfaced.

```bash
git add -A
git commit -m "test: validate sing-box data plane end-to-end on test-env"
```

---

## Self-Review

**1. Spec coverage:**
- §3 config → Task 1 Step 4. §5 anti-loop (resolver, resolve-before-reject, ip_is_private, self-IP) → Task 1 (config) + Task 2 Step 5 (self-IP patch). §6 validation → Task 1 Step 9 + Task 5. §7 systemd → Task 1 Step 5; firewall → Task 1 Step 7; install.sh → Task 2; tgbot → Task 3. §8 tests → Tasks 1/2 (proxy/hardening/install) + integration-smoke Task 4; docs (CLAUDE/DESIGN/README) → Task 4. §9 risks/Linux gates → Task 5. §2 decisions (version pin, no-verify, replace-outright, direct inbound) → Global Constraints + Task 2 Steps 4/8. **No gaps.**
**2. Placeholder scan:** every code/config step shows full content; test-env steps show exact PowerShell. DESIGN.md (Task 4 Step 3) and README (Step 4) are "read current then update" — unavoidable for prose edits, but each names the exact sections and the exact substance to write. No TBD/TODO.
**3. Type/name consistency:** `SINGBOX_BIN`/`SINGBOX_DIR`/`SINGBOX_RESOLVER`/`SINGBOX_VERSION`/`SINGBOX_SHA256` used consistently across Task 2; service name `sing-box` consistent across unit (Task 1), install lists (Task 2), tgbot (Task 3); config path `/usr/local/etc/sing-box/config.json` consistent in unit (Task 1 Step 5), install (Task 2 Step 5), test (Task 1 Step 1). Sentinel `127.0.0.2/32` defined in Task 1 Step 4, patched in Task 2 Step 5. Consistent.
