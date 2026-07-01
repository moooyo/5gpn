#!/usr/bin/env python3
"""
5gpn Telegram ops bot.

A lean, stdlib-only (urllib long-polling) Telegram bot that drives the
5gpn DoT/DoH/plain-DNS gateway from inline-keyboard buttons.

Architecture reminder: 5gpn-dns (data-plane resolver) -> sing-box -> DIRECT egress.
There is NO exit layer, so there are NO exit-switching commands. The bot only
manages: status, forced-proxy domains, chnroute/list refresh, cert renewal,
service restarts, logs, and the iOS profile QR.

Security model:
  * Bot token comes from the systemd EnvironmentFile (TGBOT_TOKEN) or, as a
    fallback, /etc/5gpn/.tgbot_token (root-only, chmod 600).
  * Only numeric Telegram IDs in TGBOT_ADMINS / .tgbot_admins may operate the
    bot; every other update is ignored (except /id, which only reveals the
    caller's own id so an admin can bootstrap the allowlist).
  * Rule/list operations (add/del/list forced-proxy domains, refresh
    subscriptions, status stats) go through the 5gpn-dns control-plane REST
    API on 127.0.0.1:9443 (see api_call()), authenticated with a bearer token
    (DNS_API_TOKEN). The bot and the API server are the same box; only
    service restarts, logs, cert renewal, and the iOS QR stay local
    (systemctl / journalctl / certbot / qrencode are not part of the API).
  * The only user-supplied value routed to the API (a domain) is validated
    against a strict regex before it is ever sent.

Config / paths (override CONF_DIR via env if needed):
  /etc/5gpn/.tgbot_token     bot token (fallback to TGBOT_TOKEN env)
  /etc/5gpn/.tgbot_admins    authorized ids (fallback to TGBOT_ADMINS env)
  /etc/5gpn/.domain          the gateway's domain (for the iOS URL)
  /etc/5gpn/dns.env          5gpn-dns env file (DNS_API_TOKEN lives here)
  https://127.0.0.1:9443/api/*  5gpn-dns control-plane REST API (loopback)
"""

import html
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
CONF_DIR = os.environ.get("CONF_DIR", "/etc/5gpn")
DOMAIN_FILE = os.path.join(CONF_DIR, ".domain")
GATEWAY_FILE = os.path.join(CONF_DIR, ".gateway_ip")
PUBLIC_IP_FILE = os.path.join(CONF_DIR, ".public_ip")
IOS_PORT = "8111"

# 5gpn-dns control-plane REST API (same box, bearer-token authenticated).
# The API listener itself binds ALL interfaces on :9443 (not loopback-only) —
# it is firewall-gated to CLIENT_NET only (see scripts/setup-firewall.sh).
# tgbot's own connection here is over loopback (127.0.0.1), which is why the
# no-verify TLS below is safe: the traffic never leaves the box.
# See docs/superpowers/specs/2026-07-01-5gpn-dns-p3-api-webui-design.md.
API_BASE = os.environ.get("API_BASE", "https://127.0.0.1:9443")

# Services the bot may restart / tail (the only two in the data path).
SERVICES = ["5gpn-dns", "sing-box"]

# Canonical FQDN rule, shared behaviorally with install.sh's is_valid_domain:
# lowercase [a-z0-9-] labels (<=63), alphabetic 2-63 TLD, total <=253.
# Input is lowercased before matching. Rejects underscores, numeric TLDs,
# and over-length — keep both validators in lockstep.
DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"
)

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _load_secret(env_name, filename):
    """Prefer the systemd-provided env var; fall back to the on-disk file."""
    val = os.environ.get(env_name, "").strip()
    if not val:
        val = _read_file(os.path.join(CONF_DIR, filename))
    return val


def _load_api_token():
    """DNS_API_TOKEN: prefer the env var, else parse it out of dns.env
    (a KEY=value file written by install.sh). Never logged."""
    val = os.environ.get("DNS_API_TOKEN", "").strip()
    if val:
        return val
    for line in _read_file(os.path.join(CONF_DIR, "dns.env")).splitlines():
        line = line.strip()
        if line.startswith("DNS_API_TOKEN="):
            return line.split("=", 1)[1].strip()
    return ""


TOKEN = _load_secret("TGBOT_TOKEN", ".tgbot_token")
ADMIN_IDS = {
    int(x) for x in re.split(r"[,\s]+", _load_secret("TGBOT_ADMINS", ".tgbot_admins")) if x
}
API = "https://api.telegram.org/bot%s/" % TOKEN
API_TOKEN = _load_api_token()

# Tiny per-chat state machine for the "send me the domain next" flows.
# chat_id -> {"action": "add_domain" | "del_domain"}
PENDING = {}


# --------------------------------------------------------------------------- #
# Telegram API helpers (stdlib urllib + json)
# --------------------------------------------------------------------------- #
def tg(method, **params):
    """Call a Telegram Bot API method; never raises (returns a dict)."""
    data = json.dumps(params).encode("utf-8")
    req = urllib.request.Request(
        API + method, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=70) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8"))
        except Exception:
            return {"ok": False, "error": str(e)}
    except Exception as e:
        # Transient network error: caller decides whether to retry.
        return {"ok": False, "error": str(e)}


# --------------------------------------------------------------------------- #
# 5gpn-dns control-plane API client (stdlib urllib + ssl)
# --------------------------------------------------------------------------- #
# The control API's TLS certificate is issued for the gateway's public domain
# (the same LE/self cert 5gpn-dns uses for DoT/DoH), but the bot always talks
# to 127.0.0.1 (loopback), so the certificate's hostname can never match.
# Hostname/chain verification is disabled here on purpose: the connection
# never leaves loopback, and the bearer token (not TLS) is the real
# authenticator for this API.
_API_SSL_CTX = ssl.create_default_context()
_API_SSL_CTX.check_hostname = False
_API_SSL_CTX.verify_mode = ssl.CERT_NONE


def api_call(method, path, body=None, query=None):
    """Call the 5gpn-dns control-plane REST API.

    Returns (ok, data_or_error). Never raises: on transport failure or a
    non-2xx response, returns (False, <human-readable message>); on success
    returns (True, <decoded JSON>).
    """
    if not API_TOKEN:
        return False, "控制台 API 未启用：dns.env 中没有 DNS_API_TOKEN"

    url = API_BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)

    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + API_TOKEN)
    if data is not None:
        req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=30, context=_API_SSL_CTX) as resp:
            raw = resp.read().decode("utf-8")
            return True, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read().decode("utf-8")).get("error", str(e))
        except Exception:
            err = str(e)
        return False, err
    except Exception:
        return False, "控制台 API 无法访问（%s）" % API_BASE


def _chunks(text, size):
    if not text:
        yield ""
        return
    for i in range(0, len(text), size):
        yield text[i : i + size]


def send(chat_id, text, keyboard=None):
    """Send (HTML) text, paginating long messages; attach a keyboard if given."""
    wrapped = list(_chunks(text, 3900))
    last = len(wrapped) - 1
    for i, chunk in enumerate(wrapped):
        params = {
            "chat_id": chat_id,
            "text": chunk,
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
        }
        if keyboard is not None and i == last:
            params["reply_markup"] = {"inline_keyboard": keyboard}
        tg("sendMessage", **params)


def edit(cb, text, keyboard=None):
    """Edit the message a button belongs to, so a flow stays in one bubble.
    Falls back to a fresh message if the edit cannot be applied."""
    msg = cb.get("message", {})
    chat_id = msg.get("chat", {}).get("id")
    mid = msg.get("message_id")
    params = {
        "chat_id": chat_id,
        "message_id": mid,
        "text": (text or "")[:4096],
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    if keyboard is not None:
        params["reply_markup"] = {"inline_keyboard": keyboard}
    r = tg("editMessageText", **params)
    if not r.get("ok") and "not modified" not in str(r):
        send(chat_id, text, keyboard)


def pre(text):
    """Wrap raw command output in a safely-escaped monospace block."""
    text = _ANSI_RE.sub("", text or "").strip() or "(无输出)"
    if len(text) > 3500:
        text = text[:3500] + "\n... (已截断)"
    return "<pre>" + html.escape(text) + "</pre>"


def back_kb(target="menu:main", label="« 返回"):
    return [[{"text": label, "callback_data": target}]]


# --------------------------------------------------------------------------- #
# Shelling out (fixed argv, never shell=True)
# --------------------------------------------------------------------------- #
def run(argv, timeout=120, inp=None):
    """Run a command; return (ok, ansi-stripped combined output)."""
    try:
        p = subprocess.run(
            argv,
            input=inp,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        )
        return p.returncode == 0, _ANSI_RE.sub("", p.stdout or "")
    except subprocess.TimeoutExpired:
        return False, "执行超时（%ds）" % timeout
    except FileNotFoundError:
        return False, "命令不存在：%s" % argv[0]
    except Exception as e:  # pragma: no cover
        return False, "错误：%s" % e


def _tail(text, n=20):
    lines = [l for l in (text or "").splitlines() if l.strip()]
    return "\n".join(lines[-n:])


def _is_active(unit):
    try:
        p = subprocess.run(
            ["systemctl", "is-active", unit],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
        return p.stdout.strip()
    except Exception:
        return "unknown"


# --------------------------------------------------------------------------- #
# Live server metrics (read from /proc + statvfs; no external commands)
# --------------------------------------------------------------------------- #
def _cpu_idle_total():
    try:
        vals = list(map(int, open("/proc/stat").readline().split()[1:]))
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)  # idle + iowait
        return idle, sum(vals)
    except Exception:
        return 0, 0


def _fmt_bytes(n):
    n = float(n)
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return ("%d%s" % (n, unit)) if unit == "B" else ("%.1f%s" % (n, unit))
        n /= 1024
    return "%.1fP" % n


def system_metrics():
    """Compact CPU / mem / disk / uptime card, sampled over a short interval."""
    idle0, tot0 = _cpu_idle_total()
    time.sleep(0.5)
    idle1, tot1 = _cpu_idle_total()
    dtot = (tot1 - tot0) or 1
    cpu = max(0, min(100, round(100 * (1 - (idle1 - idle0) / dtot))))

    load = " ".join(_read_file("/proc/loadavg").split()[:3]) or "?"
    cores = os.cpu_count() or 1

    mi = {}
    try:
        for line in open("/proc/meminfo"):
            k, v = line.split(":")
            mi[k.strip()] = int(v.split()[0])  # kB
    except Exception:
        pass
    mt = mi.get("MemTotal", 0) // 1024
    ma = mi.get("MemAvailable", 0) // 1024
    mu = mt - ma

    dused = dtotal = 0
    try:
        sv = os.statvfs("/")
        dtotal = sv.f_blocks * sv.f_frsize
        dused = dtotal - sv.f_bavail * sv.f_frsize
    except Exception:
        pass

    try:
        up_h = int(float(_read_file("/proc/uptime").split()[0]) // 3600)
    except Exception:
        up_h = 0

    def pct(u, t):
        return round(100 * u / t) if t else 0

    out = ["━━━━━━━━━━", "🖥 <b>服务器</b>"]
    out.append("⏱ 运行 %d 小时" % up_h)
    out.append("🧮 CPU %d%%（load %s · %d核）" % (cpu, load, cores))
    out.append("🧠 内存 %d/%d MB（%d%%）" % (mu, mt, pct(mu, mt)))
    if dtotal:
        out.append(
            "🗄 磁盘 %s/%s（%d%%）"
            % (_fmt_bytes(dused), _fmt_bytes(dtotal), pct(dused, dtotal))
        )
    return "\n".join(out)


# --------------------------------------------------------------------------- #
# Operations
# --------------------------------------------------------------------------- #
def _proxy_domains():
    """Effective forced-proxy (blacklist) domains, fetched from the control API.

    Returns (ok, list_or_error_string) so callers can tell "empty list" apart
    from "API unreachable" without raising.
    """
    return api_call("GET", "/api/rules/blacklist")


def op_status():
    """Compact status card: services + key facts + server metrics + a block
    of live stats from the 5gpn-dns control API. The API block is additive —
    if the API is unreachable, the local (systemctl/metrics) card still
    renders in full, with a note that the API is down."""
    lines = ["<b>📊 5gpn 状态</b>", ""]
    down = []
    for svc in SERVICES:
        ok = _is_active(svc) == "active"
        lines.append(("✅ " if ok else "❌ ") + svc)
        if not ok:
            down.append(svc)
    lines.append("")

    domain = _read_file(DOMAIN_FILE)
    if domain:
        lines.append("🔗 域名：<code>%s</code>" % html.escape(domain))
        lines.append("🔒 DoT：<code>tls://%s:853</code>" % html.escape(domain))
    pubip = _read_file(PUBLIC_IP_FILE)
    if pubip:
        lines.append("🌍 公网 IP：<code>%s</code>" % html.escape(pubip))

    ok, data = api_call("GET", "/api/status")
    if ok:
        stats = data.get("stats", {}) if isinstance(data, dict) else {}
        up_s = data.get("uptime_seconds", 0) if isinstance(data, dict) else 0
        up_h, up_m = divmod(int(up_s) // 60, 60)
        lines.append("")
        lines.append(
            "🧩 5gpn-dns <code>%s</code>（运行 %d 小时 %d 分）"
            % (html.escape(str(data.get("version", "?"))), up_h, up_m)
        )
        lines.append(
            "📈 查询：总 %s · 直连 %s（强制 %s + 国内 %s）· 代理 %s（黑名单 %s + 境外 %s）· 广告拦截 %s · 缓存 %s"
            % (
                stats.get("total", 0),
                stats.get("force_direct", 0) + stats.get("chnroute_cn", 0),
                stats.get("force_direct", 0),
                stats.get("chnroute_cn", 0),
                stats.get("blacklist", 0) + stats.get("chnroute_foreign", 0),
                stats.get("blacklist", 0),
                stats.get("chnroute_foreign", 0),
                stats.get("adblock", 0),
                stats.get("cache_entries", 0),
            )
        )
    else:
        lines.append("")
        lines.append("⚠️ 控制台 API 不可用：%s" % html.escape(str(data)))

    if down:
        lines += ["", "⚠️ 异常：%s（用 📜 日志查看）" % html.escape("、".join(down))]

    try:
        lines += ["", system_metrics()]
    except Exception as e:  # metrics must never break the status card
        lines += ["", "（服务器指标获取失败：%s）" % html.escape(str(e))]
    return "\n".join(lines)


def op_list_domains():
    ok, data = _proxy_domains()
    if not ok:
        return "🎯 <b>黑名单(强制代理)域名</b>\n\n❌ %s" % html.escape(str(data))
    ds = data or []
    if not ds:
        return "🎯 <b>黑名单(强制代理)域名</b>\n\n（列表为空）\n用「➕ 加域名」添加一个。"
    body = "\n".join("%d. %s" % (i + 1, d) for i, d in enumerate(ds))
    return "🎯 <b>黑名单(强制代理)域名</b>（%d 个）：\n<pre>%s</pre>" % (len(ds), html.escape(body))


def op_add_domain(domain):
    domain = (domain or "").strip().lower()
    if not DOMAIN_RE.match(domain) or len(domain) > 253:
        return "❌ 域名无效。请发送形如 <code>example.com</code> 的域名，或 /cancel。"
    ok, data = api_call("POST", "/api/rules/blacklist", body={"entry": domain})
    if ok:
        return "✅ 已把 <b>%s</b> 加入黑名单(强制代理)列表，并已刷新生效。" % html.escape(domain)
    return "❌ <b>添加失败</b>\n%s" % pre(str(data))


def op_del_domain(domain):
    domain = (domain or "").strip().lower()
    if not DOMAIN_RE.match(domain) or len(domain) > 253:
        return "❌ 域名无效。请发送要删除的域名，或 /cancel。"
    ok, data = api_call("DELETE", "/api/rules/blacklist", query={"entry": domain})
    if ok:
        return "✅ 已把 <b>%s</b> 从黑名单(强制代理)列表移除，并已刷新生效。" % html.escape(domain)
    return "❌ <b>删除失败</b>\n%s" % pre(str(data))


def op_update_lists():
    """Refresh every configured rule-list subscription (chnroute, adblock,
    etc.) via the control API and render a per-list summary."""
    ok, data = api_call("POST", "/api/update")
    if not ok:
        return "❌ <b>更新失败</b>\n%s" % pre(str(data))
    results = data or []
    if not results:
        return "✅ <b>名单已刷新</b>\n（没有配置任何订阅）"
    lines = []
    for r in results:
        rid = r.get("id", "?")
        if r.get("ok"):
            lines.append("✅ %s：%s 条" % (rid, r.get("entries", 0)))
        else:
            lines.append("❌ %s：%s" % (rid, r.get("err", "未知错误")))
    any_fail = any(not r.get("ok") for r in results)
    head = "⚠️ <b>名单已更新（部分失败）</b>" if any_fail else "✅ <b>chnroute / 名单已更新</b>"
    return head + "\n" + pre("\n".join(lines))


def op_renew_cert():
    """certbot renew; the installed deploy/renew hook reloads 5gpn-dns."""
    ok, out = run(["certbot", "renew", "--non-interactive"], timeout=600)
    tail = _tail(out, 12)
    if ok:
        if "No renewals were attempted" in out or "not yet due" in out.lower():
            return "ℹ️ <b>证书尚未到期</b>，无需续期。\n" + pre(tail)
        return "✅ <b>证书已续期</b>（续期钩子会重载 5gpn-dns）。\n" + pre(tail)
    return "❌ <b>证书续期失败</b>\n" + pre(tail)


def op_restart(svc):
    if svc == "all":
        results = []
        for s in SERVICES:
            run(["systemctl", "restart", s], timeout=60)
            results.append("%s %s" % ("✅" if _is_active(s) == "active" else "❌", s))
        return "♻️ <b>全部服务已重启</b>\n" + "\n".join(results)
    if svc not in SERVICES:
        return "未知服务。"
    run(["systemctl", "restart", svc], timeout=60)
    state = _is_active(svc)
    icon = "✅" if state == "active" else "❌"
    return "%s <b>%s</b> 已重启（%s）" % (icon, html.escape(svc), html.escape(state))


def op_logs(svc):
    # Logs are the one place where the raw content IS the requested result.
    if svc not in SERVICES:
        return "未知服务。"
    ok, out = run(
        ["journalctl", "-u", svc, "-n", "50", "--no-pager", "-o", "short-iso"],
        timeout=30,
    )
    return "📜 <b>%s</b> 最近 50 行：\n%s" % (html.escape(svc), pre(out))


def _ios_host():
    """Host for the iOS profile URL — mirror install.sh's print_qr/regen_ios:
    prefer the client-facing gateway IP, then the public IP, then the domain.
    In NPN deployments GATEWAY_IP is the internal 172.22 address and the iOS
    responder (:8111) is firewall-restricted to 172.22.0.0/16; the bare domain
    resolves to the public IP and would be dropped there, so .gateway_ip wins.
    Non-NPN: .gateway_ip == .public_ip, so the URL is unchanged in practice."""
    return _read_file(GATEWAY_FILE) or _read_file(PUBLIC_IP_FILE) or _read_file(DOMAIN_FILE)


def op_ios():
    """Return the iOS profile URL plus an ANSI-UTF8 QR text block."""
    host = _ios_host()
    if not host:
        return "未找到网关地址（%s / %s / %s 均为空）。先在服务器上完成安装。" % (
            GATEWAY_FILE, PUBLIC_IP_FILE, DOMAIN_FILE
        )
    url = "http://%s:%s/ios-dot.mobileconfig" % (host, IOS_PORT)
    cap = (
        "📱 <b>iOS DoT 描述文件</b>\n用相机/浏览器打开下面的地址安装（仅蜂窝网生效）：\n"
        "<code>%s</code>" % html.escape(url)
    )
    ok, qr = run(["qrencode", "-t", "ANSIUTF8", "-m", "1", url], timeout=15)
    if ok and qr.strip():
        return cap + "\n\n<pre>" + html.escape(qr) + "</pre>"
    # qrencode missing / failed: the URL alone is still actionable.
    return cap


# --------------------------------------------------------------------------- #
# Keyboards
# --------------------------------------------------------------------------- #
def main_menu():
    return [
        [{"text": "📊 状态", "callback_data": "act:status"},
         {"text": "🎯 代理域名", "callback_data": "menu:domains"}],
        [{"text": "🔄 更新chnroute", "callback_data": "act:update_lists"},
         {"text": "🔐 续证书", "callback_data": "act:renew"}],
        [{"text": "♻️ 重启服务", "callback_data": "menu:restart"},
         {"text": "📜 日志", "callback_data": "menu:logs"}],
        [{"text": "📱 iOS二维码", "callback_data": "act:ios"}],
    ]


def domains_menu():
    return [
        [{"text": "➕ 加域名", "callback_data": "dom:add"},
         {"text": "🗑 删域名", "callback_data": "dom:del"}],
        [{"text": "« 返回", "callback_data": "menu:main"}],
    ]


def restart_menu():
    return [
        [{"text": "5gpn-dns", "callback_data": "restart:5gpn-dns"},
         {"text": "sing-box", "callback_data": "restart:sing-box"}],
        [{"text": "全部", "callback_data": "restart:all"}],
        [{"text": "« 返回", "callback_data": "menu:main"}],
    ]


def logs_menu():
    rows = [[{"text": s, "callback_data": "logs:" + s}] for s in SERVICES]
    rows.append([{"text": "« 返回", "callback_data": "menu:main"}])
    return rows


# --------------------------------------------------------------------------- #
# Update handling
# --------------------------------------------------------------------------- #
def authorized(uid):
    return uid in ADMIN_IDS


def handle_message(msg):
    chat_id = msg["chat"]["id"]
    uid = msg.get("from", {}).get("id")
    text = (msg.get("text") or "").strip()

    # /id is always allowed: it only reveals the caller's own id, needed to
    # bootstrap TGBOT_ADMINS / .tgbot_admins.
    if text.startswith("/id"):
        send(chat_id, "你的 Telegram 数字 ID：<code>%s</code>" % uid)
        return

    if not authorized(uid):
        send(chat_id, "⛔ 未授权。把你的 ID 加入 .tgbot_admins 后重试（发 /id 获取 ID）。")
        return

    if text == "/cancel":
        PENDING.pop(chat_id, None)
        send(chat_id, "已取消。", main_menu())
        return

    # Any slash command aborts an in-progress flow and opens the menu.
    if text.startswith("/"):
        PENDING.pop(chat_id, None)
        if text.startswith(("/start", "/menu", "/help")):
            send(chat_id, "<b>5gpn 控制台</b>\n选择一个操作：", main_menu())
        elif text.startswith("/status"):
            send(chat_id, op_status(), back_kb("menu:main"))
        else:
            send(chat_id, "未知命令。发送 /menu 打开操作面板。")
        return

    # Conversational flows: the admin's next message is the domain.
    state = PENDING.get(chat_id)
    if state and state.get("action") == "add_domain":
        PENDING.pop(chat_id, None)
        send(chat_id, "⏳ 正在添加并刷新名单…")
        send(chat_id, op_add_domain(text), domains_menu())
        return
    if state and state.get("action") == "del_domain":
        PENDING.pop(chat_id, None)
        send(chat_id, "⏳ 正在删除并刷新名单…")
        send(chat_id, op_del_domain(text), domains_menu())
        return

    send(chat_id, "发送 /menu 打开操作面板。", main_menu())


def handle_callback(cb):
    uid = cb.get("from", {}).get("id")
    chat_id = cb["message"]["chat"]["id"]
    data = cb.get("data", "")
    cb_id = cb["id"]

    if not authorized(uid):
        tg("answerCallbackQuery", callback_query_id=cb_id, text="⛔ 未授权", show_alert=True)
        return

    # Stop the button spinner immediately; long ops still run synchronously.
    tg("answerCallbackQuery", callback_query_id=cb_id)

    # ---- navigation ----
    if data == "menu:main":
        PENDING.pop(chat_id, None)
        edit(cb, "选择一个操作：", main_menu())
    elif data == "menu:domains":
        edit(cb, op_list_domains(), domains_menu())
    elif data == "menu:restart":
        edit(cb, "选择要重启的服务：", restart_menu())
    elif data == "menu:logs":
        edit(cb, "选择要查看日志的服务：", logs_menu())

    # ---- conversational starts ----
    elif data == "dom:add":
        PENDING[chat_id] = {"action": "add_domain"}
        edit(cb, "➕ 发送要加入<b>黑名单(强制代理)</b>的域名（如 <code>example.com</code>）。\n发送 /cancel 取消。")
    elif data == "dom:del":
        PENDING[chat_id] = {"action": "del_domain"}
        edit(cb, op_list_domains() + "\n\n🗑 发送要<b>删除</b>的域名，或 /cancel 取消。")

    # ---- views / actions (⏳ then result, all in one bubble) ----
    elif data == "act:status":
        edit(cb, op_status(), back_kb("menu:main"))
    elif data == "act:update_lists":
        edit(cb, "⏳ 正在更新 chnroute / 名单，请稍候（可能较久）…")
        edit(cb, op_update_lists(), back_kb("menu:main"))
    elif data == "act:renew":
        edit(cb, "⏳ 正在续期证书，请稍候…")
        edit(cb, op_renew_cert(), back_kb("menu:main"))
    elif data == "act:ios":
        edit(cb, "⏳ 正在生成 iOS 二维码…")
        edit(cb, op_ios(), back_kb("menu:main"))
    elif data.startswith("restart:"):
        svc = data[len("restart:"):]
        edit(cb, "⏳ 正在重启 <b>%s</b>…" % html.escape(svc))
        edit(cb, op_restart(svc), back_kb("menu:restart"))
    elif data.startswith("logs:"):
        svc = data[len("logs:"):]
        edit(cb, "📜 正在取 <b>%s</b> 日志…" % html.escape(svc))
        edit(cb, op_logs(svc), back_kb("menu:logs"))
    else:
        edit(cb, "未知操作。", back_kb("menu:main"))


# Quick command menu (the Telegram "Menu" button / typing "/").
BOT_COMMANDS = [
    ("menu", "打开操作面板"),
    ("status", "查看运行状态"),
    ("cancel", "取消当前操作"),
    ("id", "获取我的 Telegram ID"),
    ("help", "帮助说明"),
]


def set_commands():
    tg("setMyCommands", commands=[{"command": c, "description": d} for c, d in BOT_COMMANDS])
    tg("setChatMenuButton", menu_button={"type": "commands"})


# --------------------------------------------------------------------------- #
# Main long-poll loop
# --------------------------------------------------------------------------- #
def main():
    if not TOKEN:
        print("TGBOT_TOKEN is not set (env or %s/.tgbot_token)" % CONF_DIR, file=sys.stderr)
        sys.exit(1)
    if not ADMIN_IDS:
        print("[warn] no admin IDs; no one can operate. Use /id to find yours.", file=sys.stderr)

    set_commands()
    print("5gpn tgbot started; admins=%s" % sorted(ADMIN_IDS), file=sys.stderr)

    offset = None
    while True:
        params = {"timeout": 50}
        if offset is not None:
            params["offset"] = offset
        resp = tg("getUpdates", **params)
        if not resp.get("ok"):
            # Transient network / API hiccup: back off briefly and retry,
            # never let the poll loop die.
            time.sleep(3)
            continue
        for upd in resp.get("result", []):
            offset = upd["update_id"] + 1
            try:
                if "message" in upd:
                    handle_message(upd["message"])
                elif "callback_query" in upd:
                    handle_callback(upd["callback_query"])
            except Exception as e:  # one bad update must not kill the loop
                print("[err] handling update: %s" % e, file=sys.stderr)


if __name__ == "__main__":
    main()
