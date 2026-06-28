# Drop Web Control Plane + Gum-ify Installer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Web control plane (webui + api-server), keep the Telegram bot as the sole control plane, bootstrap charmbracelet/gum at installer start, and route all `install.sh` output/prompts through a gum-backed helper layer (with ANSI-echo fallback) including a Gum TG-bot config TUI.

**Architecture:** Delete `webui/` and `api-server.py` and every installer/firewall/test/doc reference to them. Add `install_gum()` (prebuilt binary + sha256 verify, like xray) run early; set `_HAVE_GUM`. Rewrite `info/warn/ok/err` + add prompt/spin helpers that use gum when `_HAVE_GUM=1` else fall back to the current ANSI echo / `read`. All gum *interactions* stay gated on `[[ -t 0 ]]` so `curl|bash` and CI keep working.

**Tech Stack:** bash (install.sh), nftables, systemd, charmbracelet/gum (prebuilt binary), grep-based policy tests under Git Bash.

## Global Constraints

Verbatim from [the spec](../specs/2026-06-28-gum-installer-drop-webui-design.md); every task implicitly includes these:

- **Only TG bot remains** as control plane: `webui/` and `api-server.py` deleted; no `5gpn-api` unit, no `setup_api`, no `API_PORT` in the firewall.
- **Keep the iOS responder**: `5gpn-iosprofile*`, `src/ios-http.py`, `WWW_DIR`, `IOS_PORT` stay untouched.
- **Gum install = prebuilt binary + verify, no Go, no apt repo**: download `gum_${GUM_VERSION}_Linux_${arch}.tar.gz` from `github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/…`; verify via `GUM_SHA256` override else the release `checksums.txt`. `GUM_VERSION` env-overridable, default `0.17.0`.
- **gum interactions are TTY-gated**: every `gum input/choose/confirm` only runs under `[[ -t 0 ]]`; non-TTY keeps the env-var / error path. `curl | sudo bash` and CI MUST stay non-interactive.
- **gum has an echo fallback**: when `_HAVE_GUM=0` (not installed / download or verify failed) every output helper falls back to the existing ANSI echo; the installer must never brick because gum is missing. A gum download/verify failure warns and continues (does NOT `exit`).
- **gum spin only wraps opaque waits** (binary downloads), never output-bearing ops like `update-lists.sh`.
- **Tests are grep-only**, run under Git Bash on the Windows box; gum runtime / `xray -test` / `nft -c` are Linux/CI gates (see [[dev-box-no-python]]).

---

### Task 1: Remove the Web control plane (files + install.sh + firewall)

**Files:**
- Delete: `webui/index.html`, `api-server.py`
- Modify: `install.sh`, `scripts/setup-firewall.sh`

**Interfaces:**
- Produces: an installer with no `setup_api`/`5gpn-api`/`API_PORT`; later tasks (gum) edit the same `install.sh` helpers and entry points. The status loop becomes `5gpn-iosprofile.socket 5gpn-tgbot`.

- [ ] **Step 1: Delete the web files**

Run (Git Bash, from `D:\Code\new-5gpn`):
```bash
git rm api-server.py
git rm -r webui
```

- [ ] **Step 2: install.sh — drop api-server/webui install + the setup_api function**

In [install.sh](../../../install.sh) `install_files`, delete the api-server copy line and the webui block:
```bash
    [[ -f "${SCRIPT_DIR}/api-server.py"  ]] && install -m 0755 "${SCRIPT_DIR}/api-server.py"  "${BASE_DIR}/api-server.py"
```
and
```bash
    if [[ -d "${SCRIPT_DIR}/webui" ]]; then
        mkdir -p "${BASE_DIR}/webui"
        cp -r "${SCRIPT_DIR}/webui/." "${BASE_DIR}/webui/" 2>/dev/null || true
    fi
```
Delete the ENTIRE `setup_api() { … }` function (from the `setup_api() {` line through its closing `}` and the preceding `# Optional control plane: api / tgbot` comment becomes `# Optional control plane: tgbot`).

- [ ] **Step 3: install.sh — drop --setup-api wiring, status entry, hint, firewall api_port; add upgrade cleanup**

- In `usage()` delete the line `  --setup-api         Install + enable the HTTP control API; print the token` and change the env line to drop `API_TOKEN=, API_PORT=,`:
```
Env overrides: DOMAIN=, PUBLIC_IP=, EMAIL=, LOWMEM=1|0,
               TGBOT_TOKEN=, TGBOT_ADMINS=
```
- In `main()` delete the case branch `        --setup-api)    setup_api ;;`.
- In `full_install` change the trailing hint to:
```bash
    info "Optional: '$0 --setup-tgbot' to set up the Telegram control bot."
```
- In `show_status`, change the optional-units loop:
```bash
    for opt in 5gpn-iosprofile.socket 5gpn-tgbot; do
```
- In `run_setup_firewall`, replace the api_port read+pass:
```bash
    bash "${SCRIPTS_DIR}/setup-firewall.sh"
    ok "Firewall + xray unit installed."
```
  (delete the `local api_port=""` line, the `[[ -f "${CONF_DIR}/.api_port" ]] …` line, and drop `API_PORT="$api_port"` from the invocation; keep `IOS_PORT="$IOS_PORT"` only if the firewall still reads it — it does, so:)
```bash
    IOS_PORT="$IOS_PORT" bash "${SCRIPTS_DIR}/setup-firewall.sh"
    ok "Firewall + xray unit installed."
```
- In `full_install`, add upgrade cleanup right after `install_files` (idempotent removal of a legacy api unit):
```bash
    # Drop the removed HTTP control API if a previous install left it behind.
    systemctl disable --now 5gpn-api 2>/dev/null || true
    rm -f /etc/systemd/system/5gpn-api.service
```
- Update the `CONF_DIR` comment (top of file) from `# state: .domain .public_ip .api_token ...` to `# state: .domain .public_ip .gateway_ip ...`.

- [ ] **Step 4: setup-firewall.sh — drop API_PORT**

In [scripts/setup-firewall.sh](../../../scripts/setup-firewall.sh):
- Delete the line `API_PORT="${API_PORT:-}"`.
- Replace the tcp_ports lines:
```bash
tcp_ports="22, 853"
[ -n "${API_PORT}" ] && tcp_ports="${tcp_ports}, ${API_PORT}"
```
with:
```bash
tcp_ports="22, 853"
```

- [ ] **Step 5: Verify removal**

Run (Git Bash):
```bash
cd /d/Code/new-5gpn
bash -n install.sh && bash -n scripts/setup-firewall.sh && echo "SYNTAX OK"
test ! -e api-server.py && test ! -e webui && echo "FILES GONE"
# no live api/webui refs remain (the upgrade-cleanup '5gpn-api' rm/disable lines are allowed)
grep -nE 'setup_api|api-server\.py|webui|API_PORT|\.api_port|\.api_token' install.sh scripts/setup-firewall.sh \
  | grep -vE 'disable --now 5gpn-api|rm -f /etc/systemd/system/5gpn-api\.service' \
  || echo "NO STALE API/WEBUI REFS"
grep -q 'systemctl disable --now 5gpn-api' install.sh && echo "CLEANUP PRESENT"
```
Expected: `SYNTAX OK`, `FILES GONE`, `NO STALE API/WEBUI REFS`, `CLEANUP PRESENT`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: remove web control plane (webui + api-server), keep TG bot"
```

---

### Task 2: Bootstrap Gum (`install_gum()` + `_HAVE_GUM`)

**Files:**
- Modify: `install.sh`

**Interfaces:**
- Produces: global `_HAVE_GUM` (0/1), function `install_gum()` (sets `_HAVE_GUM`, never exits non-zero), called early in `full_install` and each `--setup-*` entry. Task 3's helpers read `_HAVE_GUM`.

- [ ] **Step 1: Add the `_HAVE_GUM` global + `GUM_VERSION` near the top constants**

In [install.sh](../../../install.sh), just after the `IOS_PORT`/`RESOLV_FALLBACK` constants, add:
```bash
GUM_VERSION="${GUM_VERSION:-0.17.0}"     # charmbracelet/gum (prebuilt; installer TUI)
_HAVE_GUM=0                              # set by install_gum(); helpers fall back to echo when 0
```

- [ ] **Step 2: Add `install_gum()` (after the output helpers / before `check_root`'s callers use it)**

Add this function (place it right after the `err()` helper definition block):
```bash
# Bootstrap gum (prebuilt binary + sha256 verify). Never fatal: on any failure
# _HAVE_GUM stays 0 and all helpers fall back to plain echo.
install_gum() {
    if command -v gum >/dev/null 2>&1; then _HAVE_GUM=1; return 0; fi
    local arch url tmp exp got bin
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="arm64"  ;;
        armv7l|armhf)  arch="armv7"  ;;
        *)             arch="x86_64" ;;
    esac
    url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${arch}.tar.gz"
    tmp="$(mktemp -d)"
    if command -v curl >/dev/null 2>&1 && curl -fsSL "$url" -o "$tmp/gum.tgz" 2>/dev/null; then
        exp="${GUM_SHA256:-}"
        if [[ -z "$exp" ]]; then
            curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/checksums.txt" \
                 -o "$tmp/sums.txt" 2>/dev/null \
                && exp="$(grep "gum_${GUM_VERSION}_Linux_${arch}.tar.gz" "$tmp/sums.txt" 2>/dev/null | awk '{print $1}' | head -1)"
        fi
        if [[ -n "$exp" ]]; then
            got="$(sha256sum "$tmp/gum.tgz" | awk '{print $1}')"
            if [[ "$got" != "$exp" ]]; then
                warn "gum sha256 mismatch; continuing with plain output."
                rm -rf "$tmp"; _HAVE_GUM=0; return 0
            fi
        fi
        tar -xzf "$tmp/gum.tgz" -C "$tmp" 2>/dev/null
        bin="$(find "$tmp" -type f -name gum 2>/dev/null | head -1)"
        [[ -n "$bin" ]] && install -m 0755 "$bin" /usr/local/bin/gum 2>/dev/null
    fi
    rm -rf "$tmp"
    if command -v gum >/dev/null 2>&1; then _HAVE_GUM=1; else _HAVE_GUM=0; warn "gum unavailable; using plain output."; fi
    return 0
}
```

- [ ] **Step 3: Call `install_gum` early in `full_install` and each setup entry**

In `full_install`, add `install_gum` as the FIRST line after `check_root` (before `detect_os`):
```bash
full_install() {
    check_root
    install_gum
    detect_os
```
In `setup_tgbot`, add `install_gum` right after its `check_root` (Task 4 will use gum there).

- [ ] **Step 4: Verify**

Run (Git Bash):
```bash
cd /d/Code/new-5gpn
bash -n install.sh && echo "SYNTAX OK"
grep -q 'install_gum()' install.sh \
  && grep -q 'GUM_VERSION:-0.17.0' install.sh \
  && grep -q 'checksums.txt' install.sh \
  && grep -q 'gum sha256 mismatch' install.sh \
  && grep -q '_HAVE_GUM=0' install.sh && echo "GUM BOOTSTRAP OK"
# install_gum must be called before detect_os in full_install
awk '/^full_install\(\)/{f=1} f&&/install_gum/{print "called"; exit}' install.sh | grep -q called && echo "CALLED EARLY"
```
Expected: `SYNTAX OK`, `GUM BOOTSTRAP OK`, `CALLED EARLY`.

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "feat(install): bootstrap gum (prebuilt binary + sha256 verify)"
```

---

### Task 3: Gum-ify output + prompt + spin helpers (echo fallback)

**Files:**
- Modify: `install.sh`

**Interfaces:**
- Consumes: `_HAVE_GUM` (Task 2).
- Produces: `info/warn/ok/err` (gum-or-echo), `ask_text`/`ask_secret`/`ask_yesno` (gum-or-read, caller TTY-gated), `gum_spin TITLE -- CMD…`. Task 4 uses `ask_secret`/`ask_text`/`ask_yesno`.

- [ ] **Step 1: Rewrite the output helpers to use gum with echo fallback**

Replace the existing helper block:
```bash
info() { echo "${BLUE}[INFO]${NC} $*"; }
ok()   { echo "${GREEN}[OK]${NC}   $*"; }
warn() { echo "${YELLOW}[WARN]${NC} $*"; }
err()  { echo "${RED}[ERR]${NC}  $*" >&2; }
```
with:
```bash
info() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "$*"; else echo "${BLUE}[INFO]${NC} $*"; fi; }
ok()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level info  -- "✔ $*"; else echo "${GREEN}[OK]${NC}   $*"; fi; }
warn() { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level warn  -- "$*"; else echo "${YELLOW}[WARN]${NC} $*"; fi; }
err()  { if [[ "$_HAVE_GUM" == 1 ]]; then gum log --level error -- "$*" >&2; else echo "${RED}[ERR]${NC}  $*" >&2; fi; }
```
(Keep the `_HAVE_GUM=0` default from Task 2 above this block so the helpers are safe before `install_gum` runs.)

- [ ] **Step 2: Add prompt + spin helpers (right after `err()`)**

```bash
# Interactive helpers. Callers MUST gate on [[ -t 0 ]]; these only choose gum vs read.
ask_text()   { if [[ "$_HAVE_GUM" == 1 ]]; then gum input --prompt "$1 " --placeholder "${2:-}"; else local v; read -r -p "$1 " v; printf '%s' "$v"; fi; }
ask_secret() { if [[ "$_HAVE_GUM" == 1 ]]; then gum input --password --prompt "$1 "; else local v; read -r -p "$1 " v; printf '%s' "$v"; fi; }
ask_yesno()  { if [[ "$_HAVE_GUM" == 1 ]]; then gum confirm "$1"; else local a; read -r -p "$1 [y/N] " a; [[ "$a" == [yY]* ]]; fi; }
# Run an opaque wait command behind a spinner when interactive; else run it plainly.
gum_spin()   { local t="$1"; shift; if [[ "$_HAVE_GUM" == 1 && -t 1 ]]; then gum spin --title "$t" -- "$@"; else "$@"; fi; }
```

- [ ] **Step 3: Wire `resolve_domain` + A-record prompt to the helpers**

In `resolve_domain`, replace the interactive read:
```bash
            read -r -p "Enter your DoT domain (e.g. dns.example.com): " input
```
with:
```bash
            input="$(ask_text 'Enter your DoT domain (e.g. dns.example.com):')"
```
And the A-record wait:
```bash
        local c=""; read -r -p "Press Enter once the A record is set (or type 'skip'): " c || c=""
```
with:
```bash
        local c=""; c="$(ask_text "Press Enter once the A record is set (or type 'skip'):")" || c=""
```
(Both are already inside `if [[ -t 0 ]]` guards — keep those guards.)

- [ ] **Step 4: Wrap the xray binary download in a spinner**

In `install_xray()`, replace:
```bash
    curl -fsSL "$url" -o "$zip" || { err "xray download failed ($url)"; exit 1; }
```
with:
```bash
    gum_spin "Downloading xray ${ver}…" curl -fsSL "$url" -o "$zip" || { err "xray download failed ($url)"; exit 1; }
```

- [ ] **Step 5: Verify**

Run (Git Bash):
```bash
cd /d/Code/new-5gpn
bash -n install.sh && echo "SYNTAX OK"
# helpers have a gum branch AND an echo fallback
grep -q 'gum log --level info' install.sh && grep -q '\[INFO\]' install.sh && echo "OUTPUT FALLBACK OK"
grep -q 'ask_secret()' install.sh && grep -q 'gum input --password' install.sh && echo "PROMPT HELPERS OK"
grep -q 'gum_spin()' install.sh && grep -q 'gum_spin "Downloading xray' install.sh && echo "SPIN OK"
# interactive helpers still only invoked under -t 0 guards (resolve_domain unchanged guard)
grep -q 'ask_text .Enter your DoT domain' install.sh && echo "DOMAIN PROMPT WIRED"
```
Expected: `SYNTAX OK`, `OUTPUT FALLBACK OK`, `PROMPT HELPERS OK`, `SPIN OK`, `DOMAIN PROMPT WIRED`.

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "feat(install): route output/prompts through gum helpers with echo fallback"
```

---

### Task 4: TG bot config TUI (gum-driven `setup_tgbot`)

**Files:**
- Modify: `install.sh`

**Interfaces:**
- Consumes: `ask_text`/`ask_secret`/`ask_yesno` (Task 3), `install_gum` (Task 2).
- Produces: a `setup_tgbot` that prompts via gum when `[[ -t 0 ]]`, else keeps the env-var/`read` path; still writes `.tgbot_token`/`.tgbot_admins` (chmod 600) and the `5gpn-tgbot.service`.

- [ ] **Step 1: Replace the two interactive `read` prompts in `setup_tgbot`**

In `setup_tgbot`, replace:
```bash
    if [[ -z "$token" && -t 0 ]]; then read -r -p "Telegram Bot Token (blank to skip): " token; fi
```
with:
```bash
    if [[ -z "$token" && -t 0 ]]; then token="$(ask_secret 'Telegram Bot Token (blank to skip):')"; fi
```
and replace:
```bash
    if [[ -z "$admins" && -t 0 ]]; then read -r -p "Authorized Telegram numeric IDs (comma-separated, optional): " admins; fi
```
with:
```bash
    if [[ -z "$admins" && -t 0 ]]; then admins="$(ask_text 'Authorized Telegram numeric IDs (comma-separated, optional):')"; fi
```

- [ ] **Step 2: Add a gum confirm + styled bootstrap hint at the end of `setup_tgbot`**

Just before `setup_tgbot`'s final success `echo`/`ok` lines (after the unit is written and the `.tgbot_admins` warn), add an interactive enable confirm + a styled `/id` hint (TTY + gum only; non-TTY behavior unchanged because it already enables the unit):
```bash
    if [[ -t 0 && "$_HAVE_GUM" == 1 ]]; then
        gum style --border rounded --padding "0 1" \
          "未知自己的 Telegram ID?" \
          "1) 给你的 bot 发 /id" \
          "2) 把回显的数字 ID 填入 ${CONF_DIR}/.tgbot_admins" \
          "3) systemctl restart 5gpn-tgbot"
    fi
```
(Keep the existing `systemctl enable --now 5gpn-tgbot.service …` line — non-interactive installs still enable it.)

- [ ] **Step 3: Verify**

Run (Git Bash):
```bash
cd /d/Code/new-5gpn
bash -n install.sh && echo "SYNTAX OK"
grep -q "ask_secret 'Telegram Bot Token" install.sh && echo "TOKEN VIA GUM"
grep -q "ask_text 'Authorized Telegram numeric IDs" install.sh && echo "ADMINS VIA GUM"
grep -q 'gum style --border rounded' install.sh && echo "HINT OK"
#落地不变:仍写 600 的 token/admins 文件 + 单元
grep -q 'chmod 600 "${CONF_DIR}/.tgbot_token"' install.sh && grep -q '5gpn-tgbot.service' install.sh && echo "PERSIST INTACT"
```
Expected: `SYNTAX OK`, `TOKEN VIA GUM`, `ADMINS VIA GUM`, `HINT OK`, `PERSIST INTACT`.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat(install): gum-driven TG bot config TUI in setup_tgbot"
```

---

### Task 5: Update policy tests

**Files:**
- Modify: `tests/test_install_policy.sh`, `tests/test_hardening_policy.sh`
- Create: `tests/test_gum_policy.sh`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a green grep suite asserting the web plane is gone + gum bootstrap/fallback present.

- [ ] **Step 1: `tests/test_hardening_policy.sh` — drop api/webui, lower NoNewPrivileges threshold**

- Delete line 9 (`API="$ROOT/api-server.py";  WEBUI="$ROOT/webui/index.html"`).
- Change line 17 threshold from `-ge 4` to `-ge 3`:
```bash
[ "$(grep -c 'NoNewPrivileges=yes' "$INSTALL")" -ge 3 ] || fail "install.sh units not all hardened (NoNewPrivileges <3)"
```
- Delete the `--- API auth-failure logging ---` block (the `grep -Fq 'auth failure from' "$API" …` line) and the `--- webui CSP …---` block (the `grep -Fq 'Content-Security-Policy' "$WEBUI" …` line).
- Keep everything else (xray.service hardening, DoT rate-limit, SMARTDNS_SHA256).

- [ ] **Step 2: `tests/test_install_policy.sh` — drop api/webui assertions**

- Delete line 10 `WEBUI="$ROOT/webui/index.html"`.
- Delete the webui status block (lines asserting `svc\[k\] === 'active'` and `!!svc\[k\]`).
- Delete the `# ===== 2.6 — API port unified to 8443 …` block (the `8080`, `echo 8443`, `os\.environ` asserts).
- Delete the `# ===== 2.7 — API hardening …` block (`BoundedSemaphore`, `close_connection = True`, Handler `timeout`, `TasksMax=`, `MemoryMax=`).
- Delete the now-unused `API="$ROOT/api-server.py"` line.
- Keep: certbot renewal (stop/start xray) block, the NPN iOS `:8111`/GATEWAY_IP block, and any FW assertions.

- [ ] **Step 3: Create `tests/test_gum_policy.sh`**

```bash
#!/usr/bin/env bash
# Policy: web control plane removed; gum bootstrap + echo fallback present.
# Pure grep — runs on the dev box under Git Bash.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0; fail(){ echo "FAIL: $1"; rc=1; }

INSTALL="$ROOT/install.sh"; FW="$ROOT/scripts/setup-firewall.sh"

# --- web control plane gone ---
[ ! -e "$ROOT/api-server.py" ] || fail "api-server.py must be removed"
[ ! -e "$ROOT/webui" ]         || fail "webui/ must be removed"
grep -Eq 'setup_api|api-server\.py|API_PORT' "$INSTALL" && fail "install.sh still references the removed HTTP API"
grep -Eq 'API_PORT' "$FW" && fail "firewall still references API_PORT"
grep -Fq 'systemctl disable --now 5gpn-api' "$INSTALL" || fail "no upgrade cleanup for the removed 5gpn-api unit"

# --- gum bootstrap: prebuilt + verify, version-pinned, never fatal ---
grep -Eq 'install_gum\(\)' "$INSTALL"                 || fail "no install_gum() bootstrap"
grep -Eq 'GUM_VERSION:-0\.17\.0' "$INSTALL"           || fail "GUM_VERSION not pinned (default 0.17.0)"
grep -Fq 'checksums.txt' "$INSTALL"                   || fail "gum not verified against release checksums"
grep -Fq 'gum sha256 mismatch' "$INSTALL"             || fail "gum verify is not fail-closed"

# --- helpers gum-or-echo (fallback must exist) ---
grep -Fq 'gum log --level info' "$INSTALL"            || fail "info() has no gum branch"
grep -Fq '[INFO]' "$INSTALL"                          || fail "info() lost its echo fallback"
grep -Eq 'ask_secret\(\)' "$INSTALL"                  || fail "no ask_secret() prompt helper"
grep -Fq 'gum input --password' "$INSTALL"            || fail "bot token not collected via gum --password"

# --- non-TTY safety: gum prompts stay behind -t 0 (token prompt still guarded) ---
grep -Eq '\[\[ -z "\$token" && -t 0 \]\]' "$INSTALL"  || fail "tgbot token prompt no longer TTY-gated"

[ $rc -eq 0 ] && echo "gum policy: PASS"
exit $rc
```

- [ ] **Step 4: Run the full suite green**

Run (Git Bash):
```bash
cd /d/Code/new-5gpn
for t in tests/test_gum_policy.sh tests/test_install_policy.sh tests/test_hardening_policy.sh tests/test_proxy_policy.sh tests/test_cleanup_policy.sh tests/test_domain_validation.sh; do
  echo "== $t =="; bash "$t"
done
```
Expected: each prints `… policy: PASS` (or `domain validation: PASS`) with NO `FAIL:` lines. If a test FAILs, read the artifact and correct the assertion to match reality — do not weaken an assertion to force green.

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test: drop api/webui policy asserts; add gum bootstrap policy"
```

---

### Task 6: Docs

**Files:**
- Modify: `README.md`, `docs/DESIGN.md`, `docs/HANDOFF.md`

**Interfaces:**
- Consumes: all prior tasks.

- [ ] **Step 1: README.md**

- In the components table / `etc/` description, remove `webui` and the HTTP `api-server`; keep the Telegram bot. Wherever the control plane is described, state it is **Telegram-bot-only**.
- Add one line that the installer uses **Gum** for its TUI and auto-installs a prebuilt gum at start.
- Keep the literal `quick-install` string (a policy test greps for it).

- [ ] **Step 2: docs/DESIGN.md**

- §3 component table: change the `api-server / tgbot / webui` row to `tgbot`(Telegram 控制面)+ a note that `install.sh` 用 Gum 做安装期 TUI.
- §9: where it says control plane = API/Bot/WebUI, reduce to Bot (+ installer Gum TUI for bot onboarding). Remove the "API 改配置" framing tied to the HTTP API; keep "编辑文本文件 + 重启 smartdns" (that still describes the bot path).

- [ ] **Step 3: docs/HANDOFF.md**

- Remove webui/api-server references; describe the control plane as the Telegram bot only. Read the file first to find the exact lines.

- [ ] **Step 4: Verify docs + regression**

Run (Git Bash):
```bash
cd /d/Code/new-5gpn
! grep -rinE 'webui|api-server' README.md docs/DESIGN.md docs/HANDOFF.md && echo "DOCS CLEAN"
grep -q 'quick-install' README.md && echo "QUICKINSTALL KEPT"
grep -riq 'gum' README.md docs/DESIGN.md && echo "GUM DOCUMENTED"
for t in tests/test_gum_policy.sh tests/test_install_policy.sh tests/test_hardening_policy.sh tests/test_cleanup_policy.sh; do bash "$t"; done
```
Expected: `DOCS CLEAN`, `QUICKINSTALL KEPT`, `GUM DOCUMENTED`, all `… policy: PASS`.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/DESIGN.md docs/HANDOFF.md
git commit -m "docs: control plane is Telegram-bot-only; installer uses Gum"
```

---

## Self-Review

**Spec coverage:**
- §3 remove web plane → Task 1 (files + install.sh + firewall) + Task 5 (tests) + Task 6 (docs). ✓
- §4 gum bootstrap → Task 2. ✓
- §5 gum-ify output/interaction/spin via fallback helpers → Task 3. ✓
- §6 TG bot config TUI → Task 4. ✓
- §7 tests + docs → Task 5 + Task 6. ✓
- §8 rollback (git history) — no task needed; deletions are recoverable from history. ✓
- §9 risks — addressed structurally: echo fallback (Task 3), TTY-gating preserved (Tasks 3/4), spin only on opaque download (Task 3), gum verify fail → warn+continue (Task 2). ✓

**Placeholder scan:** No TBD/TODO. `install_gum()`, helper rewrites, and all test edits give full content. `GUM_VERSION` default `0.17.0` is a real env-overridable default.

**Type/name consistency:** `_HAVE_GUM`, `install_gum`, `GUM_VERSION`, `ask_text`/`ask_secret`/`ask_yesno`, `gum_spin` used identically across Tasks 2–4 and asserted verbatim in Task 5. The `5gpn-api` cleanup string (`systemctl disable --now 5gpn-api`) is the one allowed surviving mention of the removed unit and Task 5 asserts its presence — consistent with Task 1 Step 3.
