"""Pure-stdlib unit tests for tgbot.py (the sole control plane).

Covers the bot's testable logic with NO network / subprocess:
  * DOMAIN_RE — the canonical FQDN rule, kept in lockstep with install.sh's
    is_valid_domain (see tests/test_domain_validation.sh for the cross-check).
  * _ios_host / op_ios — the .gateway_ip > .public_ip > .domain preference that
    keeps the iOS profile URL reachable under the NPN (172.22-only :8111) firewall.
  * op_add_domain / op_del_domain — reject invalid input BEFORE shelling out.
  * authorization + callback routing — dispatch without touching Telegram.
  * small formatting helpers (pre/_chunks/_tail/_fmt_bytes).

Runs in CI (Linux + Python); the Windows dev box has no Python, so this is a
CI-only gate like test_gen_foreign_cidr.py.
"""

import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
import tgbot  # noqa: E402  (path set up above; import has no network side effects)


class TestDomainRe(unittest.TestCase):
    # Same table as tests/test_domain_validation.sh, asserted against the actual
    # compiled regex so tgbot and install.sh cannot silently drift apart.
    VALID = ["example.com", "sub.domain.example.com", "a-b.example.com",
             "1foo.example.co", "xn--fsq.com"]
    INVALID = ["", "example", "foo.c", "foo.123", "_dmarc.example.com",
               "foo_bar.com", "-foo.example.com", "foo-.example.com",
               "foo..com", "ex ample.com", "http://example.com", "example.com/x"]

    def test_valid(self):
        for d in self.VALID:
            self.assertTrue(tgbot.DOMAIN_RE.match(d), "should accept %r" % d)

    def test_invalid(self):
        for d in self.INVALID:
            self.assertFalse(tgbot.DOMAIN_RE.match(d), "should reject %r" % d)

    def test_uppercase_lowercased_by_caller(self):
        # DOMAIN_RE itself is lowercase-only; ops lowercase first (mirrors
        # install.sh's `tr A-Z a-z`). Verify both halves of that contract.
        self.assertFalse(tgbot.DOMAIN_RE.match("EXAMPLE.COM"))
        self.assertTrue(tgbot.DOMAIN_RE.match("EXAMPLE.COM".lower()))

    def test_over_length_rejected(self):
        too_long = ("a" * 60 + ".") * 5 + "com"  # > 253 chars
        self.assertFalse(tgbot.DOMAIN_RE.match(too_long))


class TestIosHost(unittest.TestCase):
    """_ios_host must prefer .gateway_ip, then .public_ip, then .domain."""

    def _with_files(self, gateway=None, public=None, domain=None):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: _rmtree(d))
        for name, val in ((".gateway_ip", gateway), (".public_ip", public),
                          (".domain", domain)):
            if val is not None:
                open(os.path.join(d, name), "w").write(val)
        self._patch("GATEWAY_FILE", os.path.join(d, ".gateway_ip"))
        self._patch("PUBLIC_IP_FILE", os.path.join(d, ".public_ip"))
        self._patch("DOMAIN_FILE", os.path.join(d, ".domain"))

    def _patch(self, attr, val):
        old = getattr(tgbot, attr)
        setattr(tgbot, attr, val)
        self.addCleanup(lambda: setattr(tgbot, attr, old))

    def test_prefers_gateway_ip(self):
        # NPN: internal gateway IP present -> it wins over the public domain.
        self._with_files(gateway="172.22.0.1", public="203.0.113.9",
                         domain="dns.example.com")
        self.assertEqual(tgbot._ios_host(), "172.22.0.1")

    def test_falls_back_to_public_ip(self):
        self._with_files(gateway=None, public="203.0.113.9",
                         domain="dns.example.com")
        self.assertEqual(tgbot._ios_host(), "203.0.113.9")

    def test_falls_back_to_domain(self):
        self._with_files(gateway=None, public=None, domain="dns.example.com")
        self.assertEqual(tgbot._ios_host(), "dns.example.com")

    def test_empty_when_nothing_set(self):
        self._with_files()
        self.assertEqual(tgbot._ios_host(), "")

    def test_op_ios_url_uses_gateway_not_domain(self):
        # The regression this guards: the QR/URL must point at the gateway host
        # (reachable on :8111), never the bare domain (dropped by the NPN firewall).
        self._with_files(gateway="172.22.0.1", public="203.0.113.9",
                         domain="dns.example.com")
        self._patch("run", lambda *a, **k: (False, ""))  # no qrencode
        out = tgbot.op_ios()
        self.assertIn("http://172.22.0.1:8111/ios-dot.mobileconfig", out)
        self.assertNotIn("dns.example.com", out)

    def test_op_ios_no_host(self):
        self._with_files()
        self._patch("run", lambda *a, **k: (False, ""))
        self.assertIn("未找到网关地址", tgbot.op_ios())


class TestDomainOpsRejectBeforeShell(unittest.TestCase):
    """Invalid domains must be rejected without ever calling the control API."""

    def setUp(self):
        def _boom(*a, **k):
            raise AssertionError("api_call() must not be called for an invalid domain")
        old = tgbot.api_call
        tgbot.api_call = _boom
        self.addCleanup(lambda: setattr(tgbot, "api_call", old))

    def test_add_rejects_invalid(self):
        self.assertIn("无效", tgbot.op_add_domain("not a domain"))

    def test_del_rejects_invalid(self):
        self.assertIn("无效", tgbot.op_del_domain("_bad_"))

    def test_add_rejects_empty(self):
        self.assertIn("无效", tgbot.op_add_domain(""))


class TestApiOps(unittest.TestCase):
    """op_* domain/list functions must call the control API, not install.sh."""

    def setUp(self):
        self.calls = []
        old = tgbot.api_call
        self._old = old
        self.addCleanup(lambda: setattr(tgbot, "api_call", old))

    def _install(self, fn):
        tgbot.api_call = fn

    def test_add_domain_posts_blacklist(self):
        def fake(method, path, body=None, query=None):
            self.calls.append((method, path, body, query))
            return True, {"ok": True}
        self._install(fake)
        out = tgbot.op_add_domain("example.com")
        self.assertEqual(self.calls, [("POST", "/api/rules/blacklist", {"entry": "example.com"}, None)])
        self.assertIn("✅", out)
        self.assertIn("example.com", out)

    def test_add_domain_api_failure(self):
        self._install(lambda method, path, body=None, query=None: (False, "control API unreachable"))
        out = tgbot.op_add_domain("example.com")
        self.assertIn("❌", out)

    def test_del_domain_issues_delete(self):
        def fake(method, path, body=None, query=None):
            self.calls.append((method, path, body, query))
            return True, {"ok": True}
        self._install(fake)
        out = tgbot.op_del_domain("example.com")
        self.assertEqual(self.calls, [("DELETE", "/api/rules/blacklist", None, {"entry": "example.com"})])
        self.assertIn("✅", out)

    def test_del_domain_api_failure(self):
        self._install(lambda method, path, body=None, query=None: (False, "boom"))
        out = tgbot.op_del_domain("example.com")
        self.assertIn("❌", out)

    def test_list_domains_renders_fetched_list(self):
        self._install(lambda method, path, body=None, query=None: (True, ["a.com", "b.com"]))
        out = tgbot.op_list_domains()
        self.assertIn("a.com", out)
        self.assertIn("b.com", out)
        self.assertIn("2", out)

    def test_list_domains_empty(self):
        self._install(lambda method, path, body=None, query=None: (True, []))
        out = tgbot.op_list_domains()
        self.assertIn("列表为空", out)

    def test_list_domains_api_failure_shows_error_not_crash(self):
        self._install(lambda method, path, body=None, query=None: (False, "control API unreachable (https://127.0.0.1:9443)"))
        out = tgbot.op_list_domains()
        self.assertIn("control API unreachable", out)

    def test_update_lists_renders_summary(self):
        results = [
            {"id": "china-ip", "ok": True, "entries": 12345, "err": ""},
            {"id": "easylist-cn", "ok": False, "entries": 0, "err": "fetch timeout"},
        ]
        self._install(lambda method, path, body=None, query=None: (True, results))
        out = tgbot.op_update_lists()
        self.assertIn("✅", out)
        self.assertIn("china-ip", out)
        self.assertIn("12345", out)
        self.assertIn("easylist-cn", out)
        self.assertIn("fetch timeout", out)

    def test_update_lists_api_failure(self):
        self._install(lambda method, path, body=None, query=None: (False, "control API unreachable"))
        out = tgbot.op_update_lists()
        self.assertIn("❌", out)

    def test_status_includes_api_block_when_reachable(self):
        self._install(lambda method, path, body=None, query=None: (True, {
            "version": "0.3.0",
            "uptime_seconds": 3725,
            "stats": {"total": 100, "direct": 60, "proxy": 30, "block": 10,
                      "cache_entries": 42, "china_ok": 59, "china_err": 1,
                      "trust_ok": 29, "trust_err": 1},
        }))
        out = tgbot.op_status()
        self.assertIn("0.3.0", out)
        self.assertIn("100", out)

    def test_status_notes_api_down_without_crashing(self):
        self._install(lambda method, path, body=None, query=None: (False, "control API unreachable (https://127.0.0.1:9443)"))
        out = tgbot.op_status()
        self.assertIn("control API unreachable", out)


class TestApiCallToken(unittest.TestCase):
    """api_call must short-circuit with a clear message when no token is configured."""

    def test_no_token_short_circuits(self):
        old = tgbot.API_TOKEN
        tgbot.API_TOKEN = ""
        self.addCleanup(lambda: setattr(tgbot, "API_TOKEN", old))
        ok, data = tgbot.api_call("GET", "/api/status")
        self.assertFalse(ok)
        self.assertIn("DNS_API_TOKEN", data)


class TestLoadApiToken(unittest.TestCase):
    """_load_api_token prefers DNS_API_TOKEN env over dns.env file."""

    def test_env_wins_over_file(self):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: _rmtree(d))
        env_path = os.path.join(d, "dns.env")
        with open(env_path, "w") as f:
            f.write("DNS_API_TOKEN=from-file\n")
        old_conf_dir = tgbot.CONF_DIR
        tgbot.CONF_DIR = d
        self.addCleanup(lambda: setattr(tgbot, "CONF_DIR", old_conf_dir))
        old_environ = os.environ.get("DNS_API_TOKEN")
        os.environ["DNS_API_TOKEN"] = "from-env"
        self.addCleanup(lambda: (os.environ.pop("DNS_API_TOKEN", None)
                                  if old_environ is None
                                  else os.environ.__setitem__("DNS_API_TOKEN", old_environ)))
        self.assertEqual(tgbot._load_api_token(), "from-env")

    def test_falls_back_to_file(self):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: _rmtree(d))
        env_path = os.path.join(d, "dns.env")
        with open(env_path, "w") as f:
            f.write("# comment\nDNS_LISTEN_API=:9443\nDNS_API_TOKEN=from-file\nDNS_CACHE_SIZE=4096\n")
        old_conf_dir = tgbot.CONF_DIR
        tgbot.CONF_DIR = d
        self.addCleanup(lambda: setattr(tgbot, "CONF_DIR", old_conf_dir))
        old_environ = os.environ.get("DNS_API_TOKEN")
        os.environ.pop("DNS_API_TOKEN", None)
        self.addCleanup(lambda: (os.environ.pop("DNS_API_TOKEN", None)
                                  if old_environ is None
                                  else os.environ.__setitem__("DNS_API_TOKEN", old_environ)))
        self.assertEqual(tgbot._load_api_token(), "from-file")


class TestAuthAndRouting(unittest.TestCase):
    def setUp(self):
        # Record Telegram API calls instead of making them.
        self.calls = []
        old_tg = tgbot.tg
        tgbot.tg = lambda method, **p: (self.calls.append((method, p)) or {"ok": True})
        self.addCleanup(lambda: setattr(tgbot, "tg", old_tg))
        old_admins = tgbot.ADMIN_IDS
        tgbot.ADMIN_IDS = {123}
        self.addCleanup(lambda: setattr(tgbot, "ADMIN_IDS", old_admins))
        tgbot.PENDING.clear()
        self.addCleanup(tgbot.PENDING.clear)

    def _cb(self, uid, data):
        return {"id": "cb1", "from": {"id": uid}, "data": data,
                "message": {"chat": {"id": 999}, "message_id": 5}}

    def _methods(self):
        return [m for m, _ in self.calls]

    def test_authorized(self):
        self.assertTrue(tgbot.authorized(123))
        self.assertFalse(tgbot.authorized(456))

    def test_unauthorized_callback_alerts_and_stops(self):
        tgbot.handle_callback(self._cb(456, "menu:main"))
        # An unauthorized press gets a show_alert answerCallbackQuery and nothing else.
        self.assertEqual(self._methods(), ["answerCallbackQuery"])
        self.assertTrue(self.calls[0][1].get("show_alert"))

    def test_menu_main_edits_message(self):
        tgbot.handle_callback(self._cb(123, "menu:main"))
        # First clears the spinner, then edits the bubble to the main menu.
        self.assertEqual(self._methods()[0], "answerCallbackQuery")
        self.assertIn("editMessageText", self._methods())

    def test_dom_add_sets_pending_state(self):
        tgbot.handle_callback(self._cb(123, "dom:add"))
        self.assertEqual(tgbot.PENDING.get(999), {"action": "add_domain"})

    def test_unknown_callback_is_handled(self):
        tgbot.handle_callback(self._cb(123, "bogus:thing"))
        self.assertIn("editMessageText", self._methods())  # falls to "未知操作"

    def test_id_command_allowed_without_auth(self):
        sent = []
        old_send = tgbot.send
        tgbot.send = lambda chat_id, text, kb=None: sent.append(text)
        self.addCleanup(lambda: setattr(tgbot, "send", old_send))
        tgbot.handle_message({"chat": {"id": 1}, "from": {"id": 456}, "text": "/id"})
        self.assertEqual(len(sent), 1)
        self.assertIn("456", sent[0])


class TestFormattingHelpers(unittest.TestCase):
    def test_pre_strips_ansi_and_escapes(self):
        out = tgbot.pre("\x1b[31m<b>hi</b>\x1b[0m")
        self.assertNotIn("\x1b", out)
        self.assertIn("&lt;b&gt;hi&lt;/b&gt;", out)  # HTML-escaped, not interpreted

    def test_pre_empty(self):
        self.assertIn("无输出", tgbot.pre(""))

    def test_pre_truncates(self):
        self.assertIn("已截断", tgbot.pre("x" * 5000))

    def test_chunks_paginates(self):
        self.assertEqual(list(tgbot._chunks("abcdef", 2)), ["ab", "cd", "ef"])
        self.assertEqual(list(tgbot._chunks("", 2)), [""])

    def test_tail(self):
        self.assertEqual(tgbot._tail("a\nb\nc\nd", n=2), "c\nd")

    def test_fmt_bytes(self):
        self.assertEqual(tgbot._fmt_bytes(0), "0B")
        self.assertEqual(tgbot._fmt_bytes(1024), "1.0K")
        self.assertEqual(tgbot._fmt_bytes(1536), "1.5K")


def _rmtree(path):
    import shutil
    shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
