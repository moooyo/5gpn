#!/usr/bin/env python3
"""
new-5gpn control-plane HTTP API (stdlib only).

Architecture this serves:  smartdns -> sniproxy -> DIRECT egress.
There is NO exit layer (no sing-box / wireguard / fwmark / routing tables), so
this control plane is deliberately small. It only manages:

  * forced-proxy domains   (/etc/smartdns/proxy-domains.txt)
  * chnroute refresh        (/opt/new-5gpn/scripts/update-lists.sh)
  * service status + host metrics
  * service restarts
  * config backup / restore

Auth:   every /api/* call needs  Authorization: Bearer <token>  matching the
        token in /etc/new-5gpn/.api_token (401 otherwise).
Transport: HTTPS on .api_port (default 8443), cert from /etc/smartdns/cert/.
CORS:   permissive ('*') so the static web UI can call it.

All config is read from files at startup (no env wiring needed); the service
refuses to start if the token file is missing/empty.
"""
import hmac
import io
import json
import os
import re
import ssl
import subprocess
import sys
import tarfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CFG_DIR = os.environ.get("CONF_DIR") or "/etc/new-5gpn"
SMARTDNS_DIR = "/etc/smartdns"
TOKEN_FILE = CFG_DIR + "/.api_token"
PORT_FILE = CFG_DIR + "/.api_port"
DOMAIN_FILE = CFG_DIR + "/.domain"
PUBLIC_IP_FILE = CFG_DIR + "/.public_ip"
PROXY_DOMAINS = SMARTDNS_DIR + "/proxy-domains.txt"
FOREIGN_CIDR = SMARTDNS_DIR + "/foreign-cidr.txt"
CERT = os.environ.get("API_TLS_CERT") or (SMARTDNS_DIR + "/cert/fullchain.pem")
KEY = os.environ.get("API_TLS_KEY") or (SMARTDNS_DIR + "/cert/privkey.pem")
UPDATE_LISTS = "/opt/new-5gpn/scripts/update-lists.sh"

# Extra files folded into a backup if they exist (overseas / cache settings).
EXTRA_BACKUP = [SMARTDNS_DIR + "/overseas.conf", SMARTDNS_DIR + "/cache.conf"]

BIND = os.environ.get("API_BIND") or "0.0.0.0"
DEFAULT_PORT = 8443
# systemctl unit names; ALL (in /api/restart) maps to every unit. QUIC/quic-proxy
# was removed: HTTP/3 is not proxied; UDP 443 is rejected at the firewall.
SERVICES = {"smartdns": "smartdns", "sniproxy": "sniproxy"}
RESTART_UNITS = {"smartdns": "smartdns", "sniproxy": "sniproxy"}

# Conservative domain check: labels of [a-z0-9-], a dot, a 2+ letter TLD. Lower-
# cased before matching. Rejects schemes, paths, spaces, leading/trailing dots.
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")

_domains_lock = threading.Lock()   # serialize proxy-domains.txt writers


# ----------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------
def read_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def run(argv, timeout=180, inp=None):
    """Shell out without a shell (no shell=True). Returns (ok, combined_output)."""
    try:
        p = subprocess.run(argv, input=inp, capture_output=True, text=True,
                           timeout=timeout)
        out = ((p.stdout or "") + (p.stderr or "")).strip()
        return p.returncode == 0, out
    except subprocess.TimeoutExpired:
        return False, "timed out"
    except FileNotFoundError:
        return False, "not found: %s" % argv[0]
    except Exception as e:  # noqa: BLE001
        return False, str(e)


def is_active(unit):
    # systemctl is-active prints active/inactive/failed/activating/... on stdout
    # and returns non-zero for anything but "active"; we want the word either way.
    try:
        p = subprocess.run(["systemctl", "is-active", unit],
                           capture_output=True, text=True, timeout=5)
        return (p.stdout or p.stderr or "unknown").strip() or "unknown"
    except Exception:  # noqa: BLE001
        return "unknown"


def restart_unit(unit):
    return run(["systemctl", "restart", unit], timeout=30)


def load_domains():
    """Return the list of forced-proxy domains (skipping comments/blank lines)."""
    out = []
    for line in read_file(PROXY_DOMAINS).splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            out.append(s)
    return out


def write_domains(comments, domains):
    """Atomically rewrite proxy-domains.txt: preserved comment header + domains."""
    body = "\n".join(comments + domains)
    if body and not body.endswith("\n"):
        body += "\n"
    tmp = PROXY_DOMAINS + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    os.replace(tmp, PROXY_DOMAINS)


def leading_comments():
    """The comment/blank header at the top of proxy-domains.txt, to keep on rewrite."""
    head = []
    for line in read_file(PROXY_DOMAINS).splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            break
        head.append(line)
    return head


# ----------------------------------------------------------------------------
# host metrics (from /proc, os.statvfs, files) — no third-party deps
# ----------------------------------------------------------------------------
def cpu_percent(window=0.2):
    def snap():
        f = [int(x) for x in read_file("/proc/stat").splitlines()[0].split()[1:]]
        idle = f[3] + (f[4] if len(f) > 4 else 0)   # idle + iowait
        return sum(f), idle
    try:
        t1, i1 = snap()
        time.sleep(window)
        t2, i2 = snap()
        dt, di = t2 - t1, i2 - i1
        return round((1 - di / dt) * 100, 1) if dt > 0 else 0.0
    except Exception:  # noqa: BLE001
        return 0.0


def mem_mb():
    info = {}
    for line in read_file("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        try:
            info[k.strip()] = int(v.strip().split()[0])  # kB
        except (ValueError, IndexError):
            pass
    total = info.get("MemTotal", 0) // 1024
    avail = info.get("MemAvailable", 0) // 1024
    return max(0, total - avail), total


def disk_pct():
    try:
        s = os.statvfs("/")
        total = s.f_blocks * s.f_frsize
        used = (s.f_blocks - s.f_bfree) * s.f_frsize
        return round(used * 100.0 / total, 1) if total else 0.0
    except Exception:  # noqa: BLE001
        return 0.0


def uptime_secs():
    try:
        return int(float(read_file("/proc/uptime").split()[0]))
    except Exception:  # noqa: BLE001
        return 0


def file_age_secs(path):
    try:
        return max(0, int(time.time() - os.path.getmtime(path)))
    except OSError:
        return -1   # missing -> -1 so the UI can show "never"


def count_lines(path):
    n = 0
    for line in read_file(path).splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            n += 1
    return n


def status():
    used, total = mem_mb()
    return {
        "services": {name: is_active(unit) for name, unit in SERVICES.items()},
        "cpu_pct": cpu_percent(),
        "mem_used_mb": used,
        "mem_total_mb": total,
        "disk_pct": disk_pct(),
        "uptime_secs": uptime_secs(),
        "public_ip": read_file(PUBLIC_IP_FILE).strip(),
        "domain": read_file(DOMAIN_FILE).strip(),
        "proxy_domains_count": len(load_domains()),
        "foreign_cidr_count": count_lines(FOREIGN_CIDR),
        "foreign_cidr_age_secs": file_age_secs(FOREIGN_CIDR),
    }


# ----------------------------------------------------------------------------
# backup / restore  (tar.gz over the few user-meaningful config files)
# ----------------------------------------------------------------------------
# Stored in the archive under stable arcnames; restore maps them back to abspaths.
BACKUP_MAP = {
    "proxy-domains.txt": PROXY_DOMAINS,
    "domain": DOMAIN_FILE,
}
for _p in EXTRA_BACKUP:
    BACKUP_MAP[os.path.basename(_p)] = _p


def make_backup():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for arc, full in BACKUP_MAP.items():
            if os.path.isfile(full):
                tf.add(full, arcname=arc)
    return buf.getvalue()


RESTORE_MEMBER_MAX = 4_000_000  # cap each restored file (decompression-bomb guard)


def restore_backup(raw):
    """Extract a backup archive back into place. Only known arcnames are honored;
    anything else (absolute paths, '..', unknown names) is ignored — so a hostile
    archive can't write outside the whitelisted config files."""
    restored = 0
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
        for m in tf.getmembers():
            if not m.isfile():
                continue
            dest = BACKUP_MAP.get(m.name.lstrip("./"))
            if not dest:
                continue
            if m.size > RESTORE_MEMBER_MAX:
                continue  # declared size too large; skip (decompression-bomb guard)
            src = tf.extractfile(m)
            if src is None:
                continue
            data = src.read(RESTORE_MEMBER_MAX + 1)
            if len(data) > RESTORE_MEMBER_MAX:
                continue  # header under-reported size; refuse this member
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            tmp = dest + ".tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, dest)
            restored += 1
    if not restored:
        raise ValueError("no recognizable config files in archive")
    return restored


# ----------------------------------------------------------------------------
# Auth-failure logging: rate-limited + sanitized. Unbounded per-request logging
# on the public port would let a flood swamp journald (which then rate-limits and
# DROPS real records) and lets attacker-controlled request fields inject terminal
# escapes into the log. Cap to ~1 line/sec with a suppressed-count, strip control
# bytes, and bound length.
# ----------------------------------------------------------------------------
_AUTH_LOG_LOCK = threading.Lock()
_AUTH_LOG = {"t": 0.0, "suppressed": 0}


def _san(s, n=128):
    return "".join(c if 32 <= ord(c) < 127 else "." for c in str(s)[:n])


def _log_auth_failure(src, command, path):
    now = time.monotonic()
    line = None
    with _AUTH_LOG_LOCK:
        _AUTH_LOG["suppressed"] += 1
        if now - _AUTH_LOG["t"] >= 1.0:
            extra = _AUTH_LOG["suppressed"] - 1
            _AUTH_LOG["t"] = now
            _AUTH_LOG["suppressed"] = 0
            line = "auth failure from %s: %s %s" % (_san(src, 64), _san(command, 16), _san(path))
            if extra > 0:
                line += " (+%d more suppressed)" % extra
    if line:
        sys.stderr.write(line + "\n")


# ----------------------------------------------------------------------------
# HTTP handler
# ----------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "new5gpn-api"
    protocol_version = "HTTP/1.1"
    timeout = 30  # bound per-connection reads (slowloris); applied by StreamRequestHandler.setup()

    def log_message(self, *a):   # keep the journal quiet
        pass

    # -- response helpers ----------------------------------------------------
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if code >= 400:
            # Close the connection on errors so an undrained request body can't
            # desync the next request on this keep-alive connection.
            self.close_connection = True
            self.send_header("Connection", "close")
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:  # noqa: BLE001
            pass

    def _bytes(self, code, data, ctype, filename=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if filename:
            self.send_header("Content-Disposition",
                             'attachment; filename="%s"' % filename)
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(data)
        except Exception:  # noqa: BLE001
            pass

    def _auth(self):
        h = self.headers.get("Authorization", "")
        ok = h.startswith("Bearer ") and hmac.compare_digest(h[7:], TOKEN)
        if not ok:
            src = self.client_address[0] if self.client_address else "?"
            _log_auth_failure(src, self.command, self.path)
        return ok

    def _read_body(self, limit=8_000_000):
        if self.headers.get("Transfer-Encoding"):
            # Chunked/unknown transfer-encodings aren't supported here; refuse
            # rather than risk request smuggling or a silently-truncated body.
            self.close_connection = True
            return b""
        try:
            n = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            self.close_connection = True
            return b""
        if n < 0 or n > limit:
            self.close_connection = True   # oversize/invalid: don't read, don't desync
            return b""
        if n == 0:
            return b""
        return self.rfile.read(n)

    def _json_body(self):
        try:
            obj = json.loads(self._read_body(2_000_000).decode("utf-8") or "{}")
            return obj if isinstance(obj, dict) else {}
        except Exception:  # noqa: BLE001
            return {}

    # -- methods -------------------------------------------------------------
    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if not self._auth():
            return self._json(401, {"error": "unauthorized"})
        if path == "/api/status":
            return self._json(200, status())
        if path == "/api/domains":
            return self._json(200, {"domains": load_domains()})
        if path == "/api/backup":
            try:
                return self._bytes(200, make_backup(), "application/gzip",
                                   "new5gpn-backup.tar.gz")
            except Exception as e:  # noqa: BLE001
                return self._json(500, {"error": str(e)})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if not self._auth():
            return self._json(401, {"error": "unauthorized"})

        if path == "/api/domains":
            return self._add_domain(self._json_body())

        if path == "/api/update-lists":
            ok, out = run(["bash", UPDATE_LISTS], timeout=400)
            tail = "\n".join(out.splitlines()[-40:])
            return self._json(200 if ok else 500, {"ok": ok, "output": tail})

        if path == "/api/restart":
            return self._restart(self._json_body())

        if path == "/api/restore":
            raw = self._read_body()
            if not raw:
                return self._json(400, {"error": "empty body"})
            try:
                n = restore_backup(raw)
            except Exception as e:  # noqa: BLE001
                return self._json(400, {"error": "restore failed: %s" % e})
            restart_unit("smartdns")
            return self._json(200, {"ok": True, "restored": n})

        return self._json(404, {"error": "not found"})

    def do_DELETE(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if not self._auth():
            return self._json(401, {"error": "unauthorized"})
        if path == "/api/domains":
            return self._del_domain(self._json_body())
        return self._json(404, {"error": "not found"})

    # -- handlers ------------------------------------------------------------
    def _add_domain(self, body):
        domain = str(body.get("domain", "")).strip().lower().rstrip(".")
        if not DOMAIN_RE.match(domain):
            return self._json(400, {"error": "invalid domain"})
        with _domains_lock:
            domains = load_domains()
            if domain not in domains:
                domains.append(domain)
                write_domains(leading_comments(), domains)
        restart_unit("smartdns")
        return self._json(200, {"ok": True, "domains": domains})

    def _del_domain(self, body):
        domain = str(body.get("domain", "")).strip().lower().rstrip(".")
        if not domain:
            return self._json(400, {"error": "missing domain"})
        with _domains_lock:
            domains = load_domains()
            if domain not in domains:
                return self._json(404, {"error": "domain not found"})
            domains = [d for d in domains if d != domain]
            write_domains(leading_comments(), domains)
        restart_unit("smartdns")
        return self._json(200, {"ok": True, "domains": domains})

    def _restart(self, body):
        svc = str(body.get("service", "")).strip()
        if svc == "all":
            results = {u: restart_unit(u)[0] for u in RESTART_UNITS.values()}
            ok = all(results.values())
            return self._json(200 if ok else 500, {"ok": ok, "results": results})
        unit = RESTART_UNITS.get(svc)
        if not unit:
            return self._json(400, {"error": "unknown service"})
        ok, out = restart_unit(unit)
        return self._json(200 if ok else 500, {"ok": ok, "output": out})


# ----------------------------------------------------------------------------
# TLS server: handshake PER CONNECTION inside the worker thread, NOT in the
# accept loop.  Wrapping the *listening* socket would run the TLS handshake
# inside accept(), so a single stalled client (e.g. a port scanner probing the
# public 8443) would wedge the whole listener.  Here accept() returns a plain
# socket and ssl wrap_socket() — with a short handshake timeout — happens in the
# per-request thread, so one slow/broken client can't block others.
# ----------------------------------------------------------------------------
class TLSServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64
    ssl_ctx = None
    _sem = threading.BoundedSemaphore(64)    # cap concurrent connections (DoS guard)

    def get_request(self):
        return self.socket.accept()          # plain accept; no TLS here

    def process_request(self, request, client_address):
        # Backpressure: cap in-flight connections so a flood on the public 8443
        # can't spawn unbounded worker threads; excess is dropped fast.
        if not self._sem.acquire(timeout=5):
            try:
                self.shutdown_request(request)
            except Exception:  # noqa: BLE001
                pass
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):  # in a thread
        try:
            try:
                request.settimeout(10)        # bound the handshake
                request = self.ssl_ctx.wrap_socket(request, server_side=True)
                request.settimeout(30)        # bound subsequent reads (slowloris)
            except Exception:  # noqa: BLE001
                try:
                    self.shutdown_request(request)
                except Exception:  # noqa: BLE001
                    pass
                return
            super().process_request_thread(request, client_address)
        finally:
            self._sem.release()


def main():
    global TOKEN, PORT
    TOKEN = (os.environ.get("API_TOKEN") or read_file(TOKEN_FILE)).strip()
    if not TOKEN:
        sys.stderr.write("API token missing/empty (env API_TOKEN or %s); refusing to start.\n" % TOKEN_FILE)
        sys.exit(1)
    try:
        PORT = int(re.sub(r"\D", "", (os.environ.get("API_PORT") or read_file(PORT_FILE))) or DEFAULT_PORT)
    except ValueError:
        PORT = DEFAULT_PORT

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    try:
        ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("TLS cert load failed (%s / %s): %s\n" % (CERT, KEY, e))
        sys.exit(1)

    httpd = TLSServer((BIND, PORT), Handler)
    httpd.ssl_ctx = ctx
    sys.stderr.write("new5gpn-api listening on %s:%d (TLS)\n" % (BIND, PORT))
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


TOKEN = ""
PORT = DEFAULT_PORT

if __name__ == "__main__":
    main()
